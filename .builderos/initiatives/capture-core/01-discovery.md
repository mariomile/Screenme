# Discovery — Screenme

Written 2026-10-22, after the build. Phase 1 was never run as planned: the capture diary from `00-frame.md` was replaced by the test Mario chose on 2026-10-20, "build layer 1 now and use it for 10 working days as the test" `[doc:user-2026-10-20-screenme]`. This file records what that test left behind, and what it did not.

## Assumption under test
If Screenme handles flow A (area capture, then paste into Slack, Linear or Claude) at least as quickly as the product Mario uses for it today, Mario will take his daily still captures with Screenme and stop opening Shottr, Xnapper and iScreen Shoter for them. `[assumption:unvalidated]`
**Would be falsified by:** a capture log over the first 10 working days showing Mario still starting flow A captures in another product on most days, or a missing step sending him back.

## Method
No interviews, no capture diary, no capture log. One test, chosen by Mario: build and use for 10 working days. `[doc:user-2026-10-20-screenme]` Its result is one statement from Mario in this session: the product is in daily use. `[doc:user-2026-10-22-in-daily-use]`
**Saturation reached:** no. One source, one person, and it is the builder's own report.

## Participants
| Code | Role | Segment | Class |
|------|------|---------|-------|
| Mario | builder and only user | PM who builds with AI | paying-badly |

## Evidence
**Use.** Screenme is in daily use. `[doc:user-2026-10-22-in-daily-use]` Which flows, how often, and whether Shottr, Xnapper, iScreen Shoter or Screen Studio are still opened next to it is not recorded. `[assumption:unvalidated]`

**What exists to be used.** The code ships flow A (area selection, Quick Access with copy, save and drag), flow B (the annotation editor) and flow C (screen recording to MP4 or GIF, with a video editor), plus a Report for AI and a command line tool with an MCP server. `[code:Sources/Screenme/Capture/SelectionOverlay.swift]` `[code:Sources/Screenme/UI/QuickAccess/QuickAccess.swift]` `[code:Sources/Screenme/Editor/AnnotationEditor.swift]` `[code:Sources/Screenme/Recording/VideoEditorModel.swift]` `[code:Sources/Screenme/Recording/AIReporter.swift]` `[code:Sources/ScreenmeCLI/MCPServer.swift]` This shows the capabilities exist. It is not evidence that the problem is felt or that the capabilities replaced anything.

**Scope grew past the frame.** The frame covered the three flows. The Report for AI and the command line tool serve handing a capture to an agent, which the frame names only as a trigger. The video editor with auto zoom was put in Later on 2026-10-20 and shipped anyway. `[doc:user-2026-10-20-screenme]` `[code:Sources/Screenme/Recording/VideoEditorModel.swift]`

## Disconfirming evidence
**Sought:** a capture log or a count of captures per product, to see whether Mario kept going back to the other tools. Not looked for: no log was kept, and nothing was asked of Mario about it before this record.
**Found:** nothing either way. `[assumption:unvalidated]`

## JTBD
When I see something on screen I need to show a person or an agent, I want to grab it and send it from one place, so I can stop choosing between capture products. `[doc:user-2026-10-20-screenme]`

## Surprises
None observed, and none could be: there is no log to be surprised by.

## Verdict
**VALIDATED** — on one weak signal: the tool Mario built is in daily use. `[doc:user-2026-10-22-in-daily-use]` That the other tools were dropped, the part of the assumption that carries the value, is untested. `[assumption:unvalidated]` The gate's count of primary units passes only because code files count as units; they show what was built, not that the problem is felt, so the count says nothing about the verdict. Condition 1.5 fails: the disconfirming evidence was not sought. The gate is recorded as overridden for that reason. Mario to confirm or change this verdict.
