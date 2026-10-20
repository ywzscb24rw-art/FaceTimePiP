// FaceTime PiP — a menu bar app that appears while you're on a FaceTime call and
// can mirror the call into a small floating window on top of every app and Space.
//
// ScreenCaptureKit streams the FaceTime window's frames into an
// AVSampleBufferDisplayLayer shown in the floating window.

import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

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

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}


// MARK: - FaceTime controls

/// Presses FaceTime's own mute and end-call controls through the Accessibility API
/// (FaceTime has no scripting support for calls). Needs the Accessibility permission.
/// Matches FaceTime's English UI titles.
enum FaceTimeControls {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to the Accessibility settings.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Toggles FaceTime's Video → Mute menu item. Returns false if it couldn't.
    @discardableResult
    static func toggleMute() -> Bool {
        guard let item = muteMenuItem() else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// Whether a FaceTime call is in progress, or nil if that can't be read (no
    /// Accessibility permission). FaceTime only enables Video → Mute during a call.
    static func isInCall() -> Bool? {
        guard isTrusted else { return nil }
        guard let item = muteMenuItem() else { return false }
        let enabled: Bool? = attribute(item, kAXEnabledAttribute)
        return enabled ?? false
    }

    /// Whether FaceTime is muted (Video → Mute is checked), or nil if unknown.
    static func isMuted() -> Bool? {
        guard let item = muteMenuItem() else { return nil }
        if title(of: item) == "Unmute" { return true }
        let mark: String? = attribute(item, kAXMenuItemMarkCharAttribute)
        return !(mark ?? "").isEmpty
    }

    /// Ends the call: presses FaceTime's end-call button if it can find one,
    /// otherwise closes the call window. Returns false if it couldn't do either.
    @discardableResult
    static func hangUp() -> Bool {
        guard let app = faceTimeApp() else { return false }
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []

        let endTitles: Set<String> = ["end", "end call", "leave", "leave call", "hang up"]
        for window in windows {
            if let button = findElement(in: window, depth: 0, where: { element in
                guard role(of: element) == kAXButtonRole as String else { return false }
                let label = (title(of: element) ?? description(of: element) ?? "").lowercased()
                return endTitles.contains(label)
            }) {
                log("hang up: pressing end-call button")
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }

        // No end-call button exposed (FaceTime hides its controls until hovered):
        // close the largest window, which is the call.
        let callWindow = windows.max { area(of: $0) < area(of: $1) }
        if let callWindow, let close: AXUIElement = attribute(callWindow, kAXCloseButtonAttribute) {
            log("hang up: closing the call window")
            return AXUIElementPerformAction(close, kAXPressAction as CFString) == .success
        }
        return false
    }

    /// Whether any app is using the default microphone (fallback call detection).
    static func isMicrophoneInUse() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return false }
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    static var isFaceTimeRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: faceTimeBundleID).isEmpty
    }

    // MARK: Accessibility helpers

    private static func faceTimeApp() -> AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: faceTimeBundleID).first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private static func muteMenuItem() -> AXUIElement? {
        guard let app = faceTimeApp(),
              let menuBar: AXUIElement = attribute(app, kAXMenuBarAttribute),
              let videoMenu = children(of: menuBar).first(where: { title(of: $0) == "Video" }),
              let menu = children(of: videoMenu).first
        else { return nil }
        return children(of: menu).first { ["Mute", "Unmute"].contains(title(of: $0)) }
    }

    private static func findElement(in element: AXUIElement, depth: Int, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(element) { return element }
        guard depth < 12 else { return nil }
        for child in children(of: element) {
            if let found = findElement(in: child, depth: depth + 1, where: match) { return found }
        }
        return nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    private static func title(of element: AXUIElement) -> String? { attribute(element, kAXTitleAttribute) }
    private static func description(of element: AXUIElement) -> String? { attribute(element, kAXDescriptionAttribute) }
    private static func role(of element: AXUIElement) -> String? { attribute(element, kAXRoleAttribute) }

    private static func area(of window: AXUIElement) -> CGFloat {
        guard let value: AXValue = attribute(window, kAXSizeAttribute) else { return 0 }
        var size = CGSize.zero
        AXValueGetValue(value, .cgSize, &size)
        return size.width * size.height
    }
}

// MARK: - Floating window

/// The edge or corner of the floating window under a point, where dragging resizes
/// instead of moves. Borderless windows resize but don't show resize cursors, so
/// the window draws its own using these zones.
enum ResizeZone {
    case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight

    static let edgeWidth: CGFloat = 6
    static let cornerSize: CGFloat = 10

    init?(point p: NSPoint, in bounds: NSRect) {
        let left = p.x - bounds.minX, right = bounds.maxX - p.x
        let bottom = p.y - bounds.minY, top = bounds.maxY - p.y
        let c = Self.cornerSize, e = Self.edgeWidth
        switch true {
        case top < c && left < c: self = .topLeft
        case top < c && right < c: self = .topRight
        case bottom < c && left < c: self = .bottomLeft
        case bottom < c && right < c: self = .bottomRight
        case top < e: self = .top
        case bottom < e: self = .bottom
        case left < e: self = .left
        case right < e: self = .right
        default: return nil
        }
    }

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch self {
            case .top: .top
            case .bottom: .bottom
            case .left: .left
            case .right: .right
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        switch self {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        default: return .crosshair  // no diagonal resize cursor before macOS 15
        }
    }
}

/// Tells the floating window when the pointer enters or leaves (to show its
/// controls) and shows resize cursors over its edges.
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
        updateCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    private func updateCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (ResizeZone(point: point, in: bounds)?.cursor ?? .arrow).set()
    }
}

/// A small rounded video window that floats above every app, on every Space,
/// without taking focus. Drag to move (it springs back on-screen if dropped past a
/// display edge), drag an edge to resize, double-click to jump to FaceTime, hover
/// for the close, mute and hang-up buttons.
final class FloatingVideoPanel: NSPanel {
    var onClose: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onHangUp: (() -> Void)?

    private let hoverView = HoverView()
    private let closeButton = NSButton()
    private let muteButton = FloatingVideoPanel.callButton(symbol: "mic.fill", color: NSColor(white: 0.2, alpha: 0.85))
    private let hangUpButton = FloatingVideoPanel.callButton(symbol: "phone.down.fill", color: .systemRed)
    /// The hover controls; clicks on them never start a drag.
    private var controls: [NSView] { [closeButton, muteButton, hangUpButton] }

    /// Where a drag started: the pointer (screen coordinates) and the window origin.
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    /// Gap kept from the display edge after springing back.
    private let edgeMargin: CGFloat = 12

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
        isMovableByWindowBackground = false  // dragging is handled in sendEvent
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
                self?.controls.forEach { $0.animator().alphaValue = inside ? 1 : 0 }
            }
        }
        contentView = hoverView

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        closeButton.toolTip = "Close"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.alphaValue = 0
        closeButton.frame = NSRect(x: 8, y: height - 30, width: 22, height: 22)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        hoverView.addSubview(closeButton)

        // Mute and hang up, centered along the bottom.
        let size: CGFloat = 32, gap: CGFloat = 16
        muteButton.frame = NSRect(x: width / 2 - size - gap / 2, y: 10, width: size, height: size)
        hangUpButton.frame = NSRect(x: width / 2 + gap / 2, y: 10, width: size, height: size)
        muteButton.toolTip = "Mute"
        hangUpButton.toolTip = "End call"
        muteButton.target = self
        muteButton.action = #selector(muteClicked)
        hangUpButton.target = self
        hangUpButton.action = #selector(hangUpClicked)
        for button in [muteButton, hangUpButton] {
            button.alphaValue = 0
            button.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
            hoverView.addSubview(button)
        }

        // Start in the bottom-right corner of the main screen.
        if let visible = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.maxX - width - 20, y: visible.minY + 20))
        }

        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: self, queue: .main) { [weak self] _ in
            self?.moveBackOnScreen()
        }
    }

    // Lets the buttons work on the first click without activating the app.
    override var canBecomeKey: Bool { true }

    /// Shows FaceTime's mute state on the mute button (nil = unknown).
    func setMuted(_ muted: Bool?) {
        let symbol = muted == true ? "mic.slash.fill" : "mic.fill"
        muteButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: muted == true ? "Unmute" : "Mute")
        muteButton.toolTip = muted == true ? "Unmute" : "Mute"
        muteButton.layer?.backgroundColor = (muted == true ? NSColor.white : NSColor(white: 0.2, alpha: 0.85)).cgColor
        muteButton.contentTintColor = muted == true ? .black : .white
    }

    private static func callButton(symbol: String, color: NSColor) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        button.isBordered = false
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.cornerRadius = 16
        button.layer?.backgroundColor = color.cgColor
        return button
    }

    /// Shows `view` filling the window, under the controls.
    func host(_ view: NSView) {
        view.frame = hoverView.bounds
        view.autoresizingMask = [.width, .height]
        hoverView.addSubview(view, positioned: .below, relativeTo: closeButton)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if event.clickCount == 2 {
                onDoubleClick?()
                return
            }
            let point = event.locationInWindow
            // Edges and corners are left to the system, which resizes the window.
            if ResizeZone(point: point, in: hoverView.bounds) == nil, !controls.contains(where: { $0.frame.contains(point) }) {
                dragStart = (NSEvent.mouseLocation, frame.origin)
                return
            }
        case .leftMouseDragged:
            if let start = dragStart {
                let mouse = NSEvent.mouseLocation
                setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                       y: start.origin.y + mouse.y - start.mouse.y))
                return
            }
        case .leftMouseUp:
            if dragStart != nil {
                dragStart = nil
                moveBackOnScreen()
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    /// If any part of the window hangs past the edge of its display, slides it back
    /// against the nearest edge(s). Leaves it alone when it's fully on-screen.
    private func moveBackOnScreen() {
        guard let visible = displayForWindow()?.visibleFrame, !visible.contains(frame) else { return }

        let area = visible.insetBy(dx: edgeMargin, dy: edgeMargin)
        var target = frame
        target.origin.x = min(max(target.minX, area.minX), area.maxX - target.width)
        target.origin.y = min(max(target.minY, area.minY), area.maxY - target.height)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
        }
    }

    /// The display showing most of the window, or the one under the pointer if it's
    /// been dragged entirely off every display.
    private func displayForWindow() -> NSScreen? {
        let overlap = { (screen: NSScreen) -> CGFloat in
            let shared = screen.frame.intersection(self.frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        if let best = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 {
            return best
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    @objc private func closeClicked() {
        onClose?()
    }

    @objc private func muteClicked() {
        onToggleMute?()
    }

    @objc private func hangUpClicked() {
        onHangUp?()
    }
}

// MARK: - Microphone watcher

/// Calls `onChange` whenever the default microphone starts or stops being used by
/// any app, following changes of the default input device. Event-driven: costs
/// nothing between changes.
final class MicrophoneWatcher {
    private let onChange: () -> Void
    private var device = AudioDeviceID(0)
    private let queue = DispatchQueue.main

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private lazy var deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.watchDefaultDevice()
        self?.onChange()
    }
    private lazy var runningChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.onChange()
    }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, queue, deviceChanged)
        watchDefaultDevice()
    }

    private func watchDefaultDevice() {
        if device != 0 {
            AudioObjectRemovePropertyListenerBlock(device, &runningAddress, queue, runningChanged)
        }
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var newDevice = AudioDeviceID(0)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &newDevice) == noErr,
              newDevice != 0
        else { device = 0; return }
        device = newDevice
        AudioObjectAddPropertyListenerBlock(device, &runningAddress, queue, runningChanged)
    }
}

// MARK: - App

/// Lives in the menu bar (no Dock icon). The menu bar icon shows only while a
/// FaceTime call is in progress, or briefly after the app is opened by hand.
///
/// Call detection is event-driven: microphone start/stop and FaceTime
/// launch/quit/activation trigger a check. Only during a call does it re-check on
/// a timer (to keep mute in sync and notice the call ending).
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let videoView = SampleBufferView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    private var capturer: WindowCapturer!
    private var panel: FloatingVideoPanel?
    private var isOpeningPanel = false
    private var micWatcher: MicrophoneWatcher?
    private var appsObservation: NSKeyValueObservation?
    private var faceTimeWasRunning = false
    private var callTimer: Timer?
    private var pendingChecks: [DispatchWorkItem] = []
    private var inCall = false
    /// Keeps the icon visible for a moment after a manual launch/reopen, so the
    /// menu (Launch at Login, Quit) is reachable outside a call.
    private var showIconUntil: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        capturer = WindowCapturer(layer: videoView.displayLayer)
        capturer.onStop = { [weak self] error in
            log("capture stopped: \(String(describing: error))")
            self?.closePanel()
            self?.scheduleChecks(reason: "capture stopped")
        }

        log("launched; screen capture: \(CGPreflightScreenCaptureAccess()), accessibility: \(FaceTimeControls.isTrusted)")
        if !FaceTimeControls.isTrusted { FaceTimeControls.requestTrust() }

        showIconBriefly()
        micWatcher = MicrophoneWatcher { [weak self] in self?.scheduleChecks(reason: "microphone") }
        // FaceTime launching or quitting (the workspace terminate notification isn't
        // reliable, so watch the running-apps list).
        faceTimeWasRunning = FaceTimeControls.isFaceTimeRunning
        appsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let running = FaceTimeControls.isFaceTimeRunning
                guard running != self.faceTimeWasRunning else { return }
                self.faceTimeWasRunning = running
                self.scheduleChecks(reason: running ? "FaceTime launched" : "FaceTime quit")
            }
        }
        // FaceTime coming to the front, e.g. after answering a call.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == faceTimeBundleID else { return }
            self?.scheduleChecks(reason: "FaceTime activated")
        }
        checkForCall()
    }

    /// The custom menu bar icon (Icons/MenuBarIcon.png, bundled as a template image so
    /// it follows light/dark menu bars), or a video symbol if none was provided.
    private static func menuBarIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            let height: CGFloat = 18
            let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
            image.size = NSSize(width: (height * aspect).rounded(), height: height)
            image.isTemplate = true
            image.accessibilityDescription = "FaceTime PiP"
            return image
        }
        return NSImage(systemSymbolName: "video.fill", accessibilityDescription: "FaceTime PiP")
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("terminating")
    }

    // Opening the app again (Finder, Spotlight) shows the icon for a moment.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showIconBriefly()
        return false
    }

    private func showIconBriefly() {
        showIconUntil = Date().addingTimeInterval(15)
        updateIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.1) { [weak self] in self?.updateIcon() }
    }

    // MARK: Call detection

    /// Checks now and again shortly after: FaceTime can take a moment to enable its
    /// Mute menu item once the microphone or app state changes.
    private func scheduleChecks(reason: String) {
        log("checking for call (\(reason))")
        pendingChecks.forEach { $0.cancel() }
        pendingChecks = [0, 1, 3].map { delay in
            let work = DispatchWorkItem { [weak self] in self?.checkForCall() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func checkForCall() {
        let call: Bool
        if let detected = FaceTimeControls.isInCall() {
            call = detected
        } else {
            call = FaceTimeControls.isFaceTimeRunning && FaceTimeControls.isMicrophoneInUse()
        }
        if call != inCall {
            inCall = call
            log(call ? "FaceTime call started" : "FaceTime call ended")
            if !call { closePanel() }
            // Re-check on a timer only while a call is in progress.
            callTimer?.invalidate()
            callTimer = call ? Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.checkForCall()
            } : nil
        }
        updateIcon()
        panel?.setMuted(FaceTimeControls.isTrusted ? FaceTimeControls.isMuted() : nil)
    }

    private func updateIcon() {
        let manual = showIconUntil.map { $0 > Date() } ?? false
        statusItem.isVisible = inCall || panel != nil || manual
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: inCall ? "FaceTime call in progress" : "No FaceTime call", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let float = item(panel == nil ? "Show Floating Video" : "Hide Floating Video", #selector(toggleFloating))
        float.isEnabled = (inCall || panel != nil) && !isOpeningPanel
        menu.addItem(float)

        let muted = FaceTimeControls.isTrusted ? FaceTimeControls.isMuted() : nil
        let mute = item("Mute", #selector(toggleMute))
        mute.state = muted == true ? .on : .off
        mute.isEnabled = inCall
        menu.addItem(mute)

        let end = item("End Call", #selector(hangUp))
        end.isEnabled = inCall
        menu.addItem(end)

        menu.addItem(.separator())
        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(item("Allow Screen Recording…", #selector(openScreenRecordingSettings)))
        }
        if !FaceTimeControls.isTrusted {
            menu.addItem(item("Allow Accessibility…", #selector(openAccessibilitySettings)))
        }
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit FaceTime PiP", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return item
    }

    // MARK: Actions

    @objc private func toggleFloating() {
        if panel != nil { closePanel() } else { openPanel() }
    }

    @objc private func toggleMute() {
        guard ensureAccessibility() else { return }
        if !FaceTimeControls.toggleMute() { log("mute: couldn't find FaceTime's Mute menu item") }
        panel?.setMuted(FaceTimeControls.isMuted())
    }

    @objc private func hangUp() {
        guard ensureAccessibility() else { return }
        if !FaceTimeControls.hangUp() { log("hang up: couldn't find a way to end the call") }
    }

    @objc private func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openAccessibilitySettings() {
        FaceTimeControls.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("launch at login: \(error.localizedDescription)")
        }
    }

    /// The call controls need the Accessibility permission; asks for it if missing.
    private func ensureAccessibility() -> Bool {
        if FaceTimeControls.isTrusted { return true }
        log("asking for Accessibility permission")
        FaceTimeControls.requestTrust()
        return false
    }

    // MARK: Floating window

    /// Starts capturing the FaceTime call window and shows it in the floating window.
    private func openPanel() {
        guard panel == nil, !isOpeningPanel else { return }
        guard CGPreflightScreenCaptureAccess() else {
            openScreenRecordingSettings()
            return
        }

        isOpeningPanel = true
        Task { @MainActor in
            defer { isOpeningPanel = false }
            do {
                // Try each FaceTime window until one actually delivers video.
                for ftWindow in try await WindowCapturer.findFaceTimeWindows() {
                    log("trying window \(ftWindow.windowID) \(ftWindow.title ?? "") \(ftWindow.frame) onScreen: \(ftWindow.isOnScreen)")
                    try await capturer.start(window: ftWindow)
                    for _ in 0..<30 where !capturer.hasFrames {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    if capturer.hasFrames {
                        showPanel()
                        return
                    }
                    log("no frames from window \(ftWindow.windowID)")
                    capturer.stop()
                }
                log("no FaceTime window to show")
            } catch {
                log("couldn't capture FaceTime: \(error.localizedDescription)")
                capturer.stop()
            }
        }
    }

    private func showPanel() {
        let size = capturer.capturedSize
        let panel = FloatingVideoPanel(aspectRatio: size.width > 0 && size.height > 0 ? size : CGSize(width: 16, height: 10))
        panel.onClose = { [weak self] in self?.closePanel() }
        panel.onDoubleClick = {
            NSRunningApplication.runningApplications(withBundleIdentifier: faceTimeBundleID).first?.activate()
        }
        panel.onToggleMute = { [weak self] in self?.toggleMute() }
        panel.onHangUp = { [weak self] in self?.hangUp() }
        panel.host(videoView)
        panel.setMuted(FaceTimeControls.isTrusted ? FaceTimeControls.isMuted() : nil)
        panel.orderFrontRegardless()
        self.panel = panel
        log("floating window shown")
        updateIcon()
    }

    private func closePanel() {
        capturer.stop()
        videoView.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        guard let panel else { return }
        panel.orderOut(nil)
        videoView.removeFromSuperview()
        self.panel = nil
        log("floating window closed")
        updateIcon()
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
