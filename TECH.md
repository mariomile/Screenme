# TECH.md: Screenme

**Verified:** 2026-10-22 @ eb39dd1

## Stack
| Layer | Choice | Why | Decision |
|-------|--------|-----|----------|
| Language | Swift 6 | Native, fast, first-class Apple APIs | inherited `[doc:user-2026-10-20-screenme]` |
| UI | AppKit for overlays and panels, SwiftUI for editor and settings | AppKit controls borderless always-on-top windows; SwiftUI is faster to write | inherited |
| Capture | ScreenCaptureKit | Modern Apple capture API for stills and video | inherited |
| OCR | Vision | On-device, no dependency | inherited |
| Video | AVFoundation | System framework, no dependency | inherited |
| Video editor | Core Image on the GPU (`Recording/VideoCompositor.swift`), one renderer for preview and export | What the editor shows is what gets exported, no dependency | `[code:Sources/Screenme/Recording/VideoCompositor.swift]` |
| Command line and MCP | `screenme` tool in `Sources/ScreenmeCLI`, embedded in `Contents/Helpers`, no code shared with the app | Lets an agent take and read captures through `screenme://` links and the report folder | `[code:Sources/ScreenmeCLI/MCPServer.swift]` |
| Upload link | Own SigV4-signed PUT with CryptoKit to the user's S3-compatible bucket | No SDK dependency; no Screenme service holds captures | `[code:Sources/Screenme/Core/S3Upload.swift]` |
| Updates | `git pull` of the checkout it was installed from, then `scripts/install.sh` | Same local signing identity, so privacy permissions survive | `[code:Sources/Screenme/Core/Updater.swift]` |
| GIF | Own encoder, `Recording/GIFEncoder.swift` | ImageIO's GIF writer can't do what keeps screen GIFs small and clean: one palette shared by every frame (no colour flicker), frames that hold only the rectangle that changed, and unchanged pixels left transparent. | decided 2026-10-20 in the recording module review: keep it |
| Project | XcodeGen (`project.yml`), .xcodeproj gitignored | Readable, diffable project instead of a .pbxproj | inherited |
| Language mode | Swift 5 mode on the Swift 6.4 compiler | Avoids strict-concurrency churn around ScreenCaptureKit delegates | inherited |

## Verify
| Check | Command | Healthy output |
|-------|---------|----------------|
| Build | `xcodegen generate && xcodebuild -project Screenme.xcodeproj -scheme Screenme -configuration Release -derivedDataPath build/DerivedData build` | `** BUILD SUCCEEDED **`, 0 warnings in Sources/ |
| Test | `xcodegen generate && xcodebuild test -project Screenme.xcodeproj -scheme Screenme -destination 'platform=macOS' -derivedDataPath build/tests -skip-testing:ScreenmeUITests` | `** TEST SUCCEEDED **`, 0 failures |
| Test (unit only) | `xcodegen generate && xcodebuild test -project Screenme.xcodeproj -scheme Screenme -destination 'platform=macOS' -derivedDataPath build/test -only-testing:ScreenmeTests -only-testing:ScreenmeCLITests` | `** TEST SUCCEEDED **`, 0 failures |
| UI test | `./scripts/ui-test.sh` (drives the real app through `screenme://` links, no pointer; needs the Screen Recording grant from `scripts/install.sh`) | `** TEST EXECUTE SUCCEEDED **` |
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
- Installs go through `scripts/install.sh`, which signs with "Screenme Local Signing", a self-signed certificate in `~/Library/Keychains/screenme-signing.keychain-db` (2026-10-21). macOS ties Screen Recording to the designated requirement (`identifier` + certificate leaf), which stays the same across rebuilds, so the permission survives. The Xcode build itself stays ad-hoc.
- AppKit windows must be created on the main thread: an overlay built inside a non-MainActor `Task` crashed on the first shortcut (fixed by making UI types `@MainActor`, 2026-10-20).
- Shottr owns ⌘⇧1 by default; `RegisterEventHotKey` then fails silently. Screenme now shows an alert at launch when a shortcut is taken.
