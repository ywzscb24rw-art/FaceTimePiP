# FaceTime PiP

A small macOS menu bar app that appears while you're on a FaceTime call and can mirror the call into a floating window that stays on top of every app and Space, like Zoom's mini video window.

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

The app has no Dock icon or main window. While a FaceTime call is in progress, a video icon shows in the menu bar with:

- **Show Floating Video** — opens the floating window.
- **Mute** / **End Call** — press FaceTime's own controls.
- **Launch at Login** — start the app automatically.
- **Quit FaceTime PiP**

Outside a call the icon is hidden; opening the app again (Finder, Spotlight) shows it for 15 seconds so you can reach the menu.

In the floating window:

- Drag the video to move it; if you drop it past a display edge it springs back on-screen.
- Drag an edge or corner to resize.
- Double-click the video to jump to FaceTime.
- Hover for **×** (close), **mute** and **hang up** buttons.

Call detection doesn't poll: microphone start/stop and FaceTime launching, quitting or coming to the front trigger a check. Call detection, mute and hang up use the Accessibility API, so the app asks for **Accessibility** permission on first launch. Without it, it falls back to treating "FaceTime is running and the microphone is in use" as a call.

Keep FaceTime's window open (not minimized) — the capture can't see minimized windows. It's video only; call audio stays in FaceTime.

Logs go to `~/Library/Logs/FaceTimePiP.log`.
