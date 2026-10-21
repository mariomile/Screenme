---
name: screenme
description: Read and dig into a Screenme Report for AI, a screen recording where someone talked, clicked and drew red marks to show you a problem. Use whenever a message contains one (a summary starting "# Report:" with "#N [m:ss]" keyframe lines, a "Report <date>" folder path, a contact-sheet.png from one), when the user says "look at my report" or "my recording", or when you need the `screenme` command to zoom into a moment, pull frames or inspect a report.
---

# Screenme reports

Screenme records the screen, the user's voice, their clicks and the marks they draw, then writes a report folder for you. They send it to show you a problem instead of describing it, so the report is the bug report. Read it closely before you answer, and don't ask them to explain again what it already shows. If something is unclear, look closer with `screenme zoom` first.

## What a paste looks like

```text
# Report: The total on the checkout page is wrong

- App: Safari
- Window: Checkout
- Recording: 3024×1964 px, 0:33
...
Cropped to: Safari (full frames in frames-full/)

## Keyframes

- #1 [0:00] "So this is the checkout page."
  - 0:00 In Safari, window "Checkout"
- #2 [0:04] "Look at this total, it should be 42."
  - 0:04 Drew a red rectangle at the top right (612, 80, 200×60) (mark 1)
- #3 [0:09] (nothing said)
  - 0:09 Clicked button "Pay" at 412, 300
  - 0:09 Dropped pin 1 at the bottom (500, 610)

## For an AI agent
...
- Contact sheet: `/Users/me/Desktop/Report 2026-10-21 at 10.22.33/contact-sheet.png`
```

- Each `#N [m:ss]` line is a keyframe: what the user said while it was on screen, then what they did, each with its time.
- `(mark N)` is a drawing, numbered in the order it was drawn. `pin N` is a numbered red pin they dropped on purpose: a pin always has its own keyframe.
- Positions are points from the top-left corner of the recorded area.
- When you answer, refer to moments the same way, as "#3 (0:09)", so the user can find them on the contact sheet.

## Reading a report

1. Look at `contact-sheet.png` first (often attached already). It shows every keyframe in time order, left to right and top to bottom, each with its `#N` in a white chip, its time, and what was said under it.
2. Read the keyframe lines next to it. Speech recognition mishears names and code terms, so trust the screen when the two disagree.
3. Open `frames/frame-NN.png` for any keyframe you need at full size (`frame-03.png` is #3). When the summary says `Cropped to:`, each frame is cut down to the window the user was working in; the uncropped screens are in `frames-full/` and `contact-sheet-full.png`.

What the marks mean:

- Red (or yellow, green, blue) strokes, arrows, rectangles and highlights are the user's drawings. They point at the problem.
- Numbered red pins mark exact spots the user flagged on purpose.
- A yellow circle around the pointer is a click; a blue one is a right click.

Other files: `report.json` is the manifest (keyframes with time, file, crop, text and events; every word with its time in `transcript.words`; `marks`; `events`; `windows`, the windows on screen through the recording). `recording.mp4` is the video.

## The screenme command

`screenme` is the command line tool inside Screenme.app. If `command -v screenme` finds nothing, use `/Applications/Screenme.app/Contents/Helpers/screenme`. It runs only on the Mac where Screenme is installed; anywhere else, read `contact-sheet.png`, `frames/` and `report.json` directly. Every command takes a report folder or `latest`, the newest report (the default). Quote the path: it has spaces.

### Look closer at a moment

Use `zoom` when the problem is motion (an animation, a jump, a flicker), happens between keyframes, or you can't tell what a mark points at:

```sh
screenme zoom "<report>" --at 0:21               # a time, m:ss or seconds
screenme zoom "<report>" --phrase "the width changes"   # when the user said it
screenme zoom "<report>" --mark 2                # when mark 2 was drawn
screenme zoom "<report>" --at 0:21 --span 1 --grid 4x4
```

It prints the path of a PNG grid of frames around that moment, the time of each cell, and what was said then. Open the PNG and look at it before you act. `--span` is the seconds covered (default 2, a quarter of it before the moment) and `--grid` the columns and rows (default 3x3). The cells are numbered from #1 within the grid; those numbers are not keyframe numbers.

### Other commands

```sh
screenme inspect "<report>"            # summary.md
screenme inspect "<report>" --json     # report.json
screenme frames "<report>" --from 0:04 --to 0:06 [--fps 4]   # plain PNGs of a stretch; prints their paths
screenme skill                         # prints this guide
```

`zoom` and `frames` write into the report's `zoom/` folder; leave the rest of the folder as it is.

With the Screenme MCP server connected, the same is available as tools: `get_latest_report` (summary and contact sheet), `zoom_report` and `inspect_report`.
