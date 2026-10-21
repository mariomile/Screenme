# Screenme

A lightweight, native macOS capture tool. Capture, drop it where it goes, move on.

- **Capture area or window** (`⌘⇧1`): drag to select an area, or click to grab the highlighted window. The capture is copied to the clipboard right away.
- **Quick Access overlay**: every capture shows up bottom-left. Drag it into any app, or hover for Copy and Save.
- **Record area or window** (`⌘⇧2`, press again or click the red menu bar icon to stop): MP4 at 30 fps, with a native trim bar and GIF export from Quick Access.
- **Capture screen**: from the menu bar.

About 0.5 MB on disk, no dependencies, system frameworks only (ScreenCaptureKit, AVFoundation, AVKit, SwiftUI).

## Build

Requires macOS 15+, Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
./scripts/install.sh
```

The script builds a Release copy, signs it with a self-signed certificate kept in its own keychain (created on the first run), and installs it in `/Applications`. macOS ties Screen Recording to the app's signature, so a stable signature keeps the permission across rebuilds. An ad-hoc build loses it every time.

To update, choose **Check for Updates…** in the menu bar (or Settings › About). Screenme fetches this checkout's remote, lists the commits it does not have yet, and **Download and Install** runs `git pull --ff-only` plus the install script, then restarts. It refuses to update while the checkout has uncommitted changes. The output of the last update is in `~/Library/Logs/Screenme/update.log`.

On first launch, allow Screenme in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch. If an older Screenme is already in that list, remove it with the minus button first.

## Automation

Every action has a `screenme://` link, for Shortcuts, Raycast or scripts:

- `screenme://capture-fullscreen`, `screenme://capture-area`, `screenme://record-screen`, `screenme://open-history`, … (the action name in kebab case)
- `screenme://capture-area?x=100&y=100&width=640&height=400`: capture that rectangle without selecting (screen points, top-left origin). Works for area, text, translate, self-timer, scrolling and recording; a link-started recording starts at once with your saved settings, and the same link stops it.
- `screenme://capture-window?app=Safari`: the frontmost window of an app (name or bundle ID)
- `screenme://settings?tab=recording`: open Settings

## Where files go

Captures are kept in `~/Library/Application Support/Screenme/Captures` until you save them. Save copies to your save folder (the Desktop by default).

## License

MIT
