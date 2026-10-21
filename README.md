# Screenme

A lightweight, native macOS capture tool. Capture, drop it where it goes, move on.

- **Capture area or window** (`⌘⇧1`): drag to select an area, or click to grab the highlighted window. The capture is copied to the clipboard right away.
- **Quick Access overlay**: every capture shows up bottom-left. Drag it into any app, or hover for Copy and Save.
- **Before & After**: select two screenshots in History, or right-click a Quick Access card and choose Compare with Previous, to get one image labelled Before and After for PRs, bug reports and feedback.
- **Record area or window** (`⌘⇧2`, press again or click the red menu bar icon to stop): MP4 at 30 fps, with a native trim bar and GIF export from Quick Access.
- **Capture screen**: from the menu bar.
- **Hide sensitive info when sharing** (Settings > Screenshots, off by default): Copy for AI and Share send a copy with emails, phone numbers, cards, IBANs, keys, IP addresses and faces pixelated, and `[redacted]` in the copied text. The capture file is never changed. The editor's Redact Sensitive Info covers faces too.
- **Copy for AI** (Quick Access, History, pins, editor `⇧⌘C`): copies the image plus a text block for Claude, ChatGPT or Cursor: the app, window and browser page it came from, the text in it, and the notes you wrote on annotations in the editor (select an annotation, type in Note for AI). Paste into a chat for the image, or into a terminal for the text with the file path.

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

### Command line

`scripts/install.sh` links a `screenme` command into `/opt/homebrew/bin` (or `~/.local/bin`). It asks the running app for the capture through those links, without bringing Screenme forward, and prints the new file's path.

```bash
screenme capture fullscreen
screenme capture area 100 100 640 400    # x y width height, screen points, top-left origin
screenme capture window Safari           # app name or bundle ID
screenme latest                          # path of the newest capture
screenme list --limit 5                  # recent captures, newest first
```

`capture` waits up to 20 seconds for the file and exits with an error if none appears (Screenme not allowed to record the screen, another capture in progress, no such window). Your after-capture settings still apply: a capture is also copied, shown in Quick Access, and so on.

### MCP server for AI agents

`screenme mcp` is a standard MCP server over stdio, so any MCP client can use it: Claude Code, Claude Desktop, Cursor, Codex, VS Code, Windsurf, Zed and others. Use the full path, because apps started from the Dock do not see your shell's PATH:

```json
{
  "mcpServers": {
    "screenme": {
      "command": "/Applications/Screenme.app/Contents/Helpers/screenme",
      "args": ["mcp"]
    }
  }
}
```

That block goes in the client's MCP config (Claude Desktop: `~/Library/Application Support/Claude/claude_desktop_config.json`; Cursor: `~/.cursor/mcp.json`). In Claude Code: `claude mcp add screenme -- /Applications/Screenme.app/Contents/Helpers/screenme mcp`. In Codex: `codex mcp add screenme -- /Applications/Screenme.app/Contents/Helpers/screenme mcp`.

The agent then has three tools: `take_screenshot` (mode `fullscreen`, `area` with `x`, `y`, `width`, `height`, or `window` with `app`), `get_latest_capture` and `list_captures`. Screenshots come back as an image (scaled to at most 1568 pixels on the long side) plus the path of the full-size file.

## Where files go

Captures are kept in `~/Library/Application Support/Screenme/Captures` until you save them. Save copies to your save folder (the Desktop by default).

## License

MIT
