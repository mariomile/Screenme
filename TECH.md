# TECH.md: Screenme

**Verified:** 2026-10-20 @ first commit

## Stack
| Layer | Choice | Why | Decision |
|-------|--------|-----|----------|
| Language | Swift 6 | Native, fast, first-class Apple APIs | inherited `[doc:user-2026-10-20-screenme]` |
| UI | AppKit for overlays and panels, SwiftUI for editor and settings | AppKit controls borderless always-on-top windows; SwiftUI is faster to write | inherited |
| Capture | ScreenCaptureKit | Modern Apple capture API for stills and video | inherited |
| OCR | Vision | On-device, no dependency | inherited |
| Video | AVFoundation | System framework, no dependency | inherited |
| GIF | Own encoder, `Recording/GIFEncoder.swift` | ImageIO's GIF writer can't do what keeps screen GIFs small and clean: one palette shared by every frame (no colour flicker), frames that hold only the rectangle that changed, and unchanged pixels left transparent. | decided 2026-10-20 in the recording module review: keep it |
| Project | XcodeGen (`project.yml`), .xcodeproj gitignored | Readable, diffable project instead of a .pbxproj | inherited |
| Language mode | Swift 5 mode on the Swift 6.4 compiler | Avoids strict-concurrency churn around ScreenCaptureKit delegates | inherited |

## Verify
| Check | Command | Healthy output |
|-------|---------|----------------|
| Build | `xcodegen generate && xcodebuild -project Screenme.xcodeproj -scheme Screenme -configuration Release -derivedDataPath build/DerivedData build` | `** BUILD SUCCEEDED **`, 0 warnings in Sources/ |
| Test | none yet: no test target | |
| Lint | none yet | |

## Technical constraints
- Native only, no web runtime. `[doc:user-2026-10-20-screenme]` No deterministic check yet.
- Toolchain on this Mac: Xcode 27.1, Swift 6.4, macOS 27.0.1, xcodegen installed. `[observed:2026-10-20-toolchain]`

## Conventions
- Deployment target macOS 15 (needed for `SCRecordingOutput`).
- Menu bar only app (`LSUIElement`). Global shortcuts via Carbon hot keys: no Accessibility permission.
- Screenme's own windows are excluded from every capture through the content filter.
- Captures live in `~/Library/Application Support/Screenme/Captures`; Save copies to the chosen save folder (Desktop by default).

## Known traps
- Builds are ad-hoc signed (no signing identity on this Mac, 2026-10-20). macOS ties the Screen Recording permission to the code signature, so a rebuild can drop the permission: re-enable Screenme in System Settings after rebuilding. Fix: sign with a stable certificate.
- AppKit windows must be created on the main thread: an overlay built inside a non-MainActor `Task` crashed on the first shortcut (fixed by making UI types `@MainActor`, 2026-10-20).
- Shottr owns ⌘⇧1 by default; `RegisterEventHotKey` then fails silently. Screenme now shows an alert at launch when a shortcut is taken.
