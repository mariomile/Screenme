# Screenme

A lightweight, native macOS capture tool. Capture, drop it where it goes, move on.

- **Capture area or window** (`⇧⌘4`): drag to select an area, or click to grab the highlighted window. The capture is copied to the clipboard right away.
- **Quick Access overlay**: every capture shows up bottom-left. Drag it into any app, or hover for Copy and Save.
- **Annotations stay editable**: reopen a capture from History or Quick Access and everything is still there.
- **Before & After**: select two screenshots in History, or right-click a Quick Access card and choose Before & After (it pairs the card with the previous screenshot), to get one image labelled Before and After for PRs, bug reports and feedback.
- **Nudge the selection with the arrow keys**: while you drag an area, hold the button and press the arrows to move it by 1 pt (`⇧` for 10 pt), `⌥` with an arrow to resize it from the bottom and right edges, and `Return` to capture; the size pill updates as you go. Before you start dragging, the arrows still move the pointer.
- **Repeat capture**: in the All-in-One bar (`R` or the Repeat tile), turn on Repeat and pick Area. The picker stays open after each shot and keeps the selection: `Return` shoots the same area again, the arrows adjust it, a new drag picks another, `Esc` closes. Each shot goes through the normal after-capture actions. Repeat is for the next Area capture only, and the screen is not frozen.
- **Search History by the text in a screenshot**: type a word in the History search box and cards whose image contains it show up, next to the date, kind and file name matches (case and accents ignored). A Text badge marks them; hover it for the matching line. Screenshots are read on this Mac with Vision, in the background, when they are captured, when the editor saves over them, and one at a time, about a second apart, for older ones.
- **Record area or window** (`⇧⌘5`, press again or click the red menu bar icon to stop): MP4 at 30 fps, with a native trim bar and GIF export from Quick Access.
- **Video editor polish**: put a recording on a gradient, color, wallpaper or image background with padding, rounded corners, shadow and an aspect ratio (16:9, 9:16, 1:1, 4:3); Auto zoom in on your clicks, following the cursor, or add zooms by hand on the timeline; speed the clip up to 3x; export H.264 or HEVC, or a GIF with its own width and frame rate. With Settings > Recording > Smooth cursor, videos are filmed without the cursor and the editor draws a smooth one with click highlights, resizable, and hidden when idle if you like. One GPU pass: a 30 s 1080p export takes about 4 seconds on an Apple Silicon Mac, and the preview is the export.
- **Capture screen** (`⇧⌘3`, or from the menu bar): the whole screen the pointer is on.
- **Hide sensitive info when sharing** (Settings > Screenshots, off by default): Copy for AI and Share send a copy with emails, phone numbers, cards, IBANs, keys, IP addresses and faces pixelated, and `[redacted]` in the copied text. The capture file is never changed. The editor's Redact Sensitive Info covers faces too.
- **Copy for AI** (Quick Access, History, pins, editor `⇧⌘C`): copies the image plus a text block for Claude, ChatGPT or Cursor: the app, window and browser page it came from, the text in it, and the notes you wrote on annotations in the editor (select an annotation, type in Note for AI). Paste into a chat for the image, or into a terminal for the text with the file path.
- **Draw while recording** (`⌥⌘D` or the pencil in the recording controls): pen, arrow, rectangle or highlighter in red, yellow, green or blue, drawn on the screen and filmed into the video. Each drawing fades out 3 seconds after you finish it; turn on Keep in the palette to keep them until Clear. **Pins**: the Pin tool, or `⇧`-click with any tool, drops a numbered red pin that stays until the recording ends (Clear leaves pins). Esc or the pencil goes back to clicking your apps. The palette is never in the video.
- **Report for AI** (recordings, from Quick Access, History or the video editor, or on its own after every recording with Settings > Recording > Create report for AI): record the screen, talk, click and draw, then pick Report for AI. Screenme transcribes what you said on this Mac, picks the keyframes and writes a `Report` folder in your save folder. The summary and the contact sheet are copied together: paste into a chat for the sheet, into Claude Code, Cursor, GitHub or Linear for the text with absolute paths. See [Report for AI](#report-for-ai) below.

Default shortcuts: `⇧⌘1` All-in-One, `⇧⌘2` Capture Text (OCR), `⇧⌘3` Capture Fullscreen, `⇧⌘4` Capture Area, `⇧⌘5` Record Screen. Every other action starts without a shortcut. macOS uses `⇧⌘3`, `⇧⌘4` and `⇧⌘5` for its own screenshots until you choose Use Screenme for ⇧⌘3, ⇧⌘4, ⇧⌘5 in Settings > Shortcuts (Restore macOS shortcuts gives them back), where you can also change any shortcut.

## Report for AI

A report folder holds:

- `contact-sheet.png`: every keyframe in one picture, three to a row, each with a big `#N`, its time and what you said under it. An agent reads the whole recording at a glance.
- `frames/frame-01.png`…: the keyframes (`frame-03.png` is #3). With auto-crop, `frames-full/` and `contact-sheet-full.png` keep the whole screens.
- `recording.mp4`: the video.
- `summary.md`: the environment (app, window, browser page, macOS, screen), a `Cropped to:` line when auto-crop applied, then `#N [m:ss]` for each keyframe with what you said while it was on screen and what you did then (clicks with the button or field clicked when Accessibility is allowed, drags, scrolls, shortcuts but never plain typing, app and window switches, drawings as numbered marks, pins), then what an agent should do, with absolute paths.
- `report.json`: the manifest: environment, keyframes with time, file, crop, text and events, every word with its time, marks, events and the windows on screen through the recording.

**Keyframes** are cut where something happened, not every few seconds: when a drawing is finished or a pin dropped, after a click, drag or scroll, after an app or window switch, when the screen settles after a real change (the video is sampled twice a second at 64 pixels and compared), and when you say "now", "here", "look", "watch" (or "qui", "guarda", "ora", "vedi"), where "this", "that" or "questo" count only with a screen change. Pauses never cut, and a screen change or a spoken cue adds a keyframe only when its picture differs from every keyframe already chosen. Each keyframe owns what you said from its moment until the next one. At most 24, drawings and pins first.

**Auto-crop** (Settings > Recording > Auto-crop frames, on by default): screen and area recordings note the windows on screen about once a second, and every recording follows the pointer. Each keyframe is cropped to the window where you were working at that moment (ink, pins, clicks, drags and scrolls first, then where the pointer rested), with 24 points around it and at least 480 points wide. Neighbouring crops that mostly overlap become one, and a crop that would cover most of the screen is skipped. Window recordings are not cropped.

## Share links (S3-compatible storage)

**Upload & Copy Link** (Quick Access menu, History, pins) uploads a screenshot, GIF or recording to your own bucket and copies a public link. With Hide sensitive info when sharing on, images go up as the redacted copy. No Screenme server is involved: you bring the bucket. Cloudflare R2 and Backblaze B2 both have a 10 GB free tier; AWS S3 and any S3-compatible server work too. Links use a random 24-character name, so they cannot be guessed.

Settings > Upload takes Endpoint URL, Region (`auto` for R2), Bucket, Access Key ID, Secret Access Key (kept in the Keychain) and Public URL. **Test Connection** uploads a tiny file and deletes it.

**Cloudflare R2**
1. In the Cloudflare dashboard, R2 > Create bucket.
2. Open the bucket > Settings > Public Development URL > Enable (r2.dev), or connect a custom domain. That URL is the Public URL.
3. R2 > Manage API Tokens > Create API token, permission Object Read & Write, limited to that bucket.
4. Endpoint `https://<accountID>.r2.cloudflarestorage.com`, Region `auto`, then the token's Access Key ID and Secret Access Key.

**Backblaze B2**
1. Create a bucket and set it to Public.
2. Create an Application Key limited to that bucket.
3. Endpoint is the bucket's S3 endpoint (e.g. `https://s3.us-west-004.backblazeb2.com`), Region the part after `s3.` (e.g. `us-west-004`).
4. Public URL `https://f00X.backblazeb2.com/file/<bucket>`, or the bucket's friendly URL.

About 20 MB on disk (one app for Apple silicon and Intel Macs), no dependencies, system frameworks only (ScreenCaptureKit, AVFoundation, AVKit, SwiftUI).

## Changes in this version

- The video editor's remembered choices (background, auto zoom, cursor, codec, GIF settings) reset to the defaults once.
- A GIF recording, when it stops, uses the video editor's GIF settings: its max width and frame rate.
- `Report` folders made before this version must be made again (Report for AI on the recording) before `screenme` can read them.
- Smooth cursor recordings made before this version keep the cursor they were saved with: the video editor cannot restyle it.

## Build

Requires macOS 15+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and, for the first install, OpenSSL 3 or later (`brew install openssl@3`; the `openssl` in macOS is LibreSSL, which cannot make the signing certificate).

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

For Reports for AI (a report folder, or `latest` for the newest one in your save folder, the default):

```bash
screenme zoom latest --at 0:21                 # a 3x3 grid of frames around 0:21, a quarter of 2 s before it
screenme zoom latest --phrase "the width"      # around when you said it
screenme zoom latest --mark 2 --span 1 --grid 4x4
screenme frames latest --from 0:04 --to 0:06 --fps 4   # plain PNG frames of a stretch
screenme inspect latest [--json]               # summary.md, or report.json
screenme skill                                 # the agent skill, below
```

`zoom` and `frames` write into the report's `zoom/` folder and print the paths; `zoom` also prints the time of each cell and what was said.

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

The agent then has six tools: `take_screenshot` (mode `fullscreen`, `area` with `x`, `y`, `width`, `height`, or `window` with `app`), `get_latest_capture`, `get_latest_report` (the newest Report for AI in your save folder: `summary.md` and the contact sheet), `zoom_report` (`at`, `phrase` or `mark`, with `span` and `grid`: the zoom grid as an image), `inspect_report` (`summary.md` and the contact sheet, or `report.json` with `json`) and `list_captures` (one path per line). Screenshots come back as an image (scaled to at most 1568 pixels on the long side) plus the path of the full-size file.

### Agent skill

`skills/screenme/SKILL.md` teaches an agent (Claude Code, Codex, OpenCode and others that read skills) how to read a Report for AI: the contact sheet first, then the keyframes, frames by number, what the red marks and pins mean, and when to run `screenme zoom`. The app carries a copy, so `screenme skill` prints it without the repo. To install it for Claude Code:

```bash
mkdir -p ~/.claude/skills/screenme
screenme skill > ~/.claude/skills/screenme/SKILL.md
```

or copy `skills/screenme` from this checkout into `~/.claude/skills/` (or a project's `.claude/skills/`). Other agents take the same folder in their own skills directory.

## Where files go

Captures are kept in `~/Library/Application Support/Screenme/Captures` until you save them. Save copies to your save folder (the Desktop by default).

## License

MIT
