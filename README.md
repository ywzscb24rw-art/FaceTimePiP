# FaceTime PiP

A small macOS app that mirrors your FaceTime call into a floating window that stays on top of every app and Space, like Zoom's mini video window.

## How it works

ScreenCaptureKit captures the FaceTime window and streams its frames into an `AVSampleBufferDisplayLayer`, shown either in the app's main window or in a borderless floating panel.

## Build

Requires macOS 14+ and Xcode's command-line tools.

```bash
./build.sh
open "build/FaceTime PiP.app"
```

On first launch, allow **Screen Recording** for FaceTime PiP in System Settings → Privacy & Security, then reopen the app.

`build.sh` signs with a local certificate named "FaceTime PiP Local Signing" if one is in your keychain, so the Screen Recording permission survives rebuilds. Without it the app is ad-hoc signed and you'll need to re-grant the permission after each build.

## Using it

- **Pop Out** moves the video into the floating window.
- Drag the video to move it; drag an edge to resize.
- Double-click the video to jump to FaceTime.
- Hover and click **×** (or click the Dock icon) to return the video to the main window.
- Hover for **mute** and **hang up** buttons. These press FaceTime's own controls through the Accessibility API, so the app asks for **Accessibility** permission the first time you use them.

Keep FaceTime's window open (not minimized) — the capture can't see minimized windows. It's video only; call audio stays in FaceTime.

Logs go to `~/Library/Logs/FaceTimePiP.log`.
