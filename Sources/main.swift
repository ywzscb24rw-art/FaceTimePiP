// FaceTime PiP — mirrors the FaceTime window into a small floating window that
// stays on top of every app and Space.
//
// ScreenCaptureKit streams the FaceTime window's frames into an
// AVSampleBufferDisplayLayer, shown either in the main window or in the floating one.

import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

let faceTimeBundleID = "com.apple.FaceTime"

/// Appends a line to ~/Library/Logs/FaceTimePiP.log for troubleshooting.
func log(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FaceTimePiP.log")
    let line = "\(Date()) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Capture

final class WindowCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let layer: AVSampleBufferDisplayLayer
    private let queue = DispatchQueue(label: "capture.frames")
    private var stream: SCStream?
    private var windowID: CGWindowID = 0
    private(set) var capturedSize: CGSize = .zero
    private var scale: CGFloat = 2
    private var resizeTimer: Timer?

    /// Called on the main queue when the stream ends (window closed, FaceTime quit, etc).
    var onStop: ((Error?) -> Void)?
    /// Called on the main queue once the first frame arrives.
    var onFirstFrame: (() -> Void)?
    private(set) var hasFrames = false

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    var isRunning: Bool { stream != nil }

    /// FaceTime's normal windows, best guess first: on-screen before off-screen
    /// (FaceTime keeps a hidden window around), then largest first.
    static func findFaceTimeWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.windows
            .filter {
                $0.owningApplication?.bundleIdentifier == faceTimeBundleID
                    && $0.windowLayer == 0
                    && $0.frame.width > 150 && $0.frame.height > 150
            }
            .sorted {
                if $0.isOnScreen != $1.isOnScreen { return $0.isOnScreen }
                return $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height
            }
    }

    func start(window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        scale = CGFloat(filter.pointPixelScale)
        windowID = window.windowID
        capturedSize = window.frame.size
        hasFrames = false

        let stream = SCStream(filter: filter, configuration: makeConfiguration(for: window.frame.size), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream

        await MainActor.run { startWatchingForResize() }
    }

    func stop() {
        resizeTimer?.invalidate()
        resizeTimer = nil
        stream?.stopCapture { _ in }
        stream = nil
    }

    private func makeConfiguration(for size: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(2, Int(size.width * scale))
        config.height = max(2, Int(size.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 5
        config.ignoreShadowsSingleWindow = true
        return config
    }

    /// Keeps the capture resolution matched to the FaceTime window when it's resized.
    private func startWatchingForResize() {
        resizeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let stream = self.stream,
                  let size = Self.currentSize(of: self.windowID),
                  abs(size.width - self.capturedSize.width) > 1 || abs(size.height - self.capturedSize.height) > 1
            else { return }
            self.capturedSize = size
            stream.updateConfiguration(self.makeConfiguration(for: size)) { _ in }
        }
    }

    private static func currentSize(of windowID: CGWindowID) -> CGSize? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return nil }
        return rect.size
    }

    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete
        else { return }

        // Live video: show each frame as soon as it arrives instead of scheduling by timestamp.
        if let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(array) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        renderer.enqueue(sampleBuffer)

        if !hasFrames {
            hasFrames = true
            DispatchQueue.main.async { [weak self] in self?.onFirstFrame?() }
        }
    }

    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stop()
            self.onStop?(error)
        }
    }
}

// MARK: - Video view

/// Hosts the display layer as a sublayer, kept sized to the view.
final class SampleBufferView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    // Dragging the video drags the floating window.
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}


// MARK: - Floating window

/// Tells the floating window when the pointer enters or leaves, to show its controls.
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// A small rounded video window that floats above every app, on every Space,
/// without taking focus. Drag to move, drag an edge to resize, double-click to
/// jump to FaceTime, hover for the close button.
final class FloatingVideoPanel: NSPanel {
    var onClose: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private let hoverView = HoverView()
    private let closeButton = NSButton()

    init(aspectRatio: CGSize) {
        let width: CGFloat = 320
        let height = (width * aspectRatio.height / max(aspectRatio.width, 1)).rounded()
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentAspectRatio = aspectRatio
        minSize = NSSize(width: 160, height: 100)

        hoverView.wantsLayer = true
        hoverView.layer?.cornerRadius = 12
        hoverView.layer?.cornerCurve = .continuous
        hoverView.layer?.masksToBounds = true
        hoverView.layer?.backgroundColor = NSColor.black.cgColor
        hoverView.onHover = { [weak self] inside in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self?.closeButton.animator().alphaValue = inside ? 1 : 0
            }
        }
        contentView = hoverView

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Return to window")
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        closeButton.toolTip = "Return to window"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.alphaValue = 0
        closeButton.frame = NSRect(x: 8, y: height - 30, width: 22, height: 22)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        hoverView.addSubview(closeButton)

        // Start in the bottom-right corner of the main screen.
        if let visible = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.maxX - width - 20, y: visible.minY + 20))
        }
    }

    // Lets the close button work on the first click without activating the app.
    override var canBecomeKey: Bool { true }

    /// Shows `view` filling the window, under the controls.
    func host(_ view: NSView) {
        view.frame = hoverView.bounds
        view.autoresizingMask = [.width, .height]
        hoverView.addSubview(view, positioned: .below, relativeTo: closeButton)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.sendEvent(event)
    }

    @objc private func closeClicked() {
        onClose?()
    }
}

// MARK: - App

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: NSWindow!
    private let videoContainer = NSView()
    private let videoView = SampleBufferView(frame: NSRect(x: 0, y: 0, width: 396, height: 270))
    private var capturer: WindowCapturer!
    private var panel: FloatingVideoPanel?

    private let popButton = NSButton(title: "Pop Out", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect to FaceTime", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    private var isPoppedOut: Bool { panel != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        buildMenu()

        capturer = WindowCapturer(layer: videoView.displayLayer)
        capturer.onStop = { [weak self] error in
            log("capture stopped: \(String(describing: error))")
            self?.captureEnded()
        }
        capturer.onFirstFrame = { [weak self] in
            log("first frame received")
            self?.refreshButtons()
        }

        log("launched; screen capture access: \(CGPreflightScreenCaptureAccess())")
        NSApp.activate(ignoringOtherApps: true)
        connect()
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("terminating")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !isPoppedOut
    }

    // Clicking the Dock icon brings the video back to the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if isPoppedOut { returnToWindow() } else { window.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: UI

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 330),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "FaceTime PiP"
        window.minSize = NSSize(width: 320, height: 260)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView()
        window.contentView = content

        let video = videoContainer
        video.wantsLayer = true
        video.layer?.backgroundColor = NSColor.black.cgColor
        video.layer?.cornerRadius = 8
        video.layer?.masksToBounds = true
        hostVideoInWindow()

        popButton.target = self
        popButton.action = #selector(togglePopOut)
        popButton.bezelStyle = .rounded
        popButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.bezelStyle = .rounded

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        let buttons = NSStackView(views: [connectButton, popButton])
        buttons.spacing = 8

        for view in [video, buttons, statusLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            video.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            video.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            video.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: video.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func hostVideoInWindow() {
        videoView.removeFromSuperview()
        videoView.frame = videoContainer.bounds
        videoView.autoresizingMask = [.width, .height]
        videoContainer.addSubview(videoView)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit FaceTime PiP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    private func setStatus(_ text: String) {
        log("status: \(text)")
        statusLabel.stringValue = text
    }

    private func refreshButtons() {
        popButton.title = isPoppedOut ? "Return to Window" : "Pop Out"
        popButton.isEnabled = isPoppedOut || (capturer.isRunning && capturer.hasFrames)
        connectButton.isHidden = capturer.isRunning
    }

    // MARK: Actions

    @objc private func connect() {
        guard !capturer.isRunning else { return }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            setStatus("Allow Screen Recording for FaceTime PiP in System Settings → Privacy & Security, then reopen the app.")
            refreshButtons()
            return
        }

        setStatus("Looking for FaceTime…")
        Task { @MainActor in
            do {
                let candidates = try await WindowCapturer.findFaceTimeWindows()
                // Try each window until one actually delivers video.
                for ftWindow in candidates {
                    log("trying window \(ftWindow.windowID) \(ftWindow.title ?? "") \(ftWindow.frame) onScreen: \(ftWindow.isOnScreen)")
                    try await capturer.start(window: ftWindow)
                    for _ in 0..<30 where !capturer.hasFrames {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    if capturer.hasFrames {
                        setStatus("Mirroring FaceTime. Click Pop Out for a floating window.")
                        refreshButtons()
                        return
                    }
                    log("no frames from window \(ftWindow.windowID)")
                    capturer.stop()
                }
                setStatus("Open FaceTime (and don't minimize its window), then click Connect.")
            } catch {
                setStatus("Couldn't capture FaceTime: \(error.localizedDescription)")
            }
            refreshButtons()
        }
    }

    @objc private func togglePopOut() {
        if isPoppedOut { returnToWindow() } else { popOut() }
    }

    private func popOut() {
        let size = capturer.capturedSize
        let panel = FloatingVideoPanel(aspectRatio: size.width > 0 && size.height > 0 ? size : CGSize(width: 16, height: 10))
        panel.onClose = { [weak self] in self?.returnToWindow() }
        panel.onDoubleClick = {
            NSRunningApplication.runningApplications(withBundleIdentifier: faceTimeBundleID).first?.activate()
        }
        videoView.removeFromSuperview()
        panel.host(videoView)
        panel.orderFrontRegardless()
        self.panel = panel

        window.orderOut(nil)
        log("popped out")
        setStatus("Showing in the floating window.")
        refreshButtons()
    }

    private func returnToWindow() {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        hostVideoInWindow()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log("returned to window")
        setStatus(capturer.isRunning ? "Mirroring FaceTime. Click Pop Out for a floating window." : statusLabel.stringValue)
        refreshButtons()
    }

    private func captureEnded() {
        videoView.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        returnToWindow()
        setStatus("FaceTime window went away. Click Connect to try again.")
        refreshButtons()
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
