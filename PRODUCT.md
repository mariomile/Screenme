# PRODUCT.md: Screenme

**Stage:** in use
**Last amended:** 2026-10-21
**Amendment count:** 4

## Purpose

A lightweight, native macOS capture tool that gives Mario the CleanShot workflow (capture, annotate, share by drag) without the weight he does not use. `[doc:user-2026-10-20-screenme]`

## The Problem

Mario's everyday screen captures are split across four separate capture products, each with its own shortcut, editor and license, so each capture starts with deciding where to go, and the one he uses for short video now only sells a recurring plan. `[doc:user-2026-10-20-screenme]` `[doc:web-2026-10-20-prior-art-pricing]` How much time the switching costs is not measured. `[assumption:unvalidated]`

**Who has it:** Mario, the only user. `[doc:user-2026-10-20-screenme]`
**How they solve it today:** a mix of Shottr, Xnapper, iScreen Shoter and Screen Studio, plus the macOS built-in capture; no CleanShot. `[doc:observed-2026-10-20-installed-tools]` Which product serves which flow is not recorded. `[assumption:unvalidated]`
**What that costs them:** switching between products on each capture (unmeasured) `[assumption:unvalidated]`, and a recurring fee he does not want to pay: Screen Studio is subscription-only for new buyers since 2025-10. `[doc:user-2026-10-20-screenme]` `[doc:web-2026-10-20-prior-art-pricing]`

## ICP

| | Primary | Secondary |
|---|---------|-----------|
| **Segment** | Mario (PM who builds with AI, captures daily for bug reports, demos, content) | none |
| **Size** | 1 `[doc:user-2026-10-20-screenme]` | |
| **Trigger** | `[assumption:unvalidated]` | |
| **Buying power** | n/a, personal tool | |
| **Where they are** | n/a | |

## Jobs To Be Done

When I see something on screen I need to show someone or an agent, I want to grab an area and paste it into Slack, Linear or Claude from one place, so I don't stop to pick which capture product to use. `[doc:user-2026-10-20-screenme]`

When the capture needs context, I want to mark it up before I share it, without moving it to a second product. `[doc:user-2026-10-20-screenme]`

When a still is not enough, I want a short video or GIF from the same place, without a subscription. `[doc:user-2026-10-20-screenme]`

Order is Mario's stated frequency ranking (A, B, C), not an observed one. `[assumption:unvalidated]`

## Non-Goals

- A shared cloud service, teams, SSO: because it is a personal tool. `[doc:user-2026-10-20-screenme]` Upload & Copy Link to the user's own S3-compatible bucket is not this: it shipped on 2026-10-21 (see the amendment log).
- Selling it, or shaping the roadmap around other users: Mario is the primary user; the code is open source so others can use and fork it as is. `[doc:user-2026-10-20-screenme]`
- Cross-platform (Windows, Linux, web): because native macOS is the requirement. `[doc:user-2026-10-20-screenme]`
- Feature parity with CleanShot: because "leggero" beats complete; each capability enters only when used.
- Screen Studio-style video editor with auto-zoom: Later, useful but not needed now. `[doc:user-2026-10-20-screenme]`

## Constraints

| Type | Constraint | Source |
|------|-----------|--------|
| Technical | Native, lightweight, performant: no Electron, no web runtime | `[doc:user-2026-10-20-screenme]` |
| Regulatory | none (local only, no data leaves the Mac) | `[doc:user-2026-10-20-screenme]` |
| Resource | One builder (Mario + Claude Code) | `[doc:user-2026-10-20-screenme]` |
| Distribution | Open source on GitHub; local build on Mario's Mac; no App Store | `[doc:user-2026-10-20-screenme]` |

## Voice

- Quiet, not invisible: the UI appears only when needed, but always confirms the capture.
- Fast, not hasty: no confirmation dialogs, but nothing lost by accident.

## Language

| Term | Means | Not to be confused with |
|------|-------|------------------------|
| Capture | One screenshot or recording taken by the user | Export (the file written to disk) |
| Quick Access | The small overlay shown after a capture, with copy, save, drag, annotate | The editor |

## Success

**North Star:** not yet selected (phase 2). Candidate: share of Mario's daily captures done with Screenme instead of other tools. `[assumption:unvalidated]`
**Current baseline:** 0 (pre-build)

## Data Sources

| Source | Status | What it answers |
|--------|--------|-----------------|
| Mario | direct | everything, single user |

## Amendment Log

| Date | What changed | Why | Evidence |
|------|-------------|-----|----------|
| 2026-10-20 | Created | n/a | n/a |
| 2026-10-20 | The Problem, How they solve it today, What that costs them, Jobs To Be Done rewritten; non-goal added for a Screen Studio-style video editor (Later) | Phase 0 round 1 answers settle the problem (fragmentation plus no further subscriptions), the three frequent flows, and the video editor deferral | `[doc:user-2026-10-20-screenme]` `[doc:observed-2026-10-20-installed-tools]` `[doc:web-2026-10-20-prior-art-pricing]` |
| 2026-10-20 | Non-goal on distribution replaced: open source on GitHub, still not sold | Mario: "è un tool che io voglio costruire e rendere opensource" | `[doc:user-2026-10-20-screenme]` |
| 2026-10-21 | Stage set from idea to in use. Non-goal "Cloud upload, share links" superseded: Upload & Copy Link to the user's own S3-compatible bucket (R2, B2, AWS) shipped on 2026-10-21; a shared cloud service, teams and SSO remain non-goals | Screenme is built and in daily use; the upload goes to a bucket the user owns, so no Screenme service holds anyone's captures | `[observed:2026-10-21-git-41147d5]` |
