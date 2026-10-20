# Frame: Screenme, capture-core

**Date:** 2026-10-20 · **Mode:** full · **Track:** product · **Cycle:** 1

## Ask, verbatim

> Voglio fare una copia di https://cleanshot.com/ per il mac. Iniziamo a capire cosa fare e come. Deve essere un software leggero, nativo e performante.

> q1: A + Non voglio pagare altri abbonamenti

`[doc:user-2026-10-20-screenme]`

## Problem

Mario's everyday screen captures are split across four separate capture products, each with its own shortcut, editor and license, so each capture starts with deciding where to go, and the one he uses for short video now only sells a recurring plan. `[doc:user-2026-10-20-screenme]`

Ladder, for the record: "a copy of CleanShot" (solution) → "one capture product instead of three or four, and no more subscriptions" (Mario's round 1 answer, Q1 A) `[doc:user-2026-10-20-screenme]` → the cost he bears: switching between products on every capture, and a recurring fee for one of them. The size of that switching cost is not measured. `[assumption:unvalidated]`

## Who

**Primary ICP:** Mario, a PM who builds with AI and captures daily for bug reports, demos and content · size 1 `[doc:user-2026-10-20-screenme]` · trigger: a capture he needs to hand to a person or an agent (Slack, Linear, Claude) `[doc:user-2026-10-20-screenme]` · signs: four capture products installed side by side `[doc:observed-2026-10-20-installed-tools]` · reachable via: himself, in session, any day.

**Secondary:** none. Distribution is a non-goal. `[doc:user-2026-10-20-screenme]`

Reachability holds by construction: the only user is the builder.

## Today

**Workaround:** Shottr, Xnapper, iScreen Shoter and Screen Studio are installed; CleanShot is not. `[doc:observed-2026-10-20-installed-tools]` The macOS built-in capture is also in use: its last saved setting is selection mode, saving to a file. `[doc:observed-2026-10-20-installed-tools]` Which product serves which of his three frequent flows is not recorded. `[assumption:unvalidated]`

His three most frequent flows, as he ranked them `[doc:user-2026-10-20-screenme]`:
- A. Area capture, then paste into Slack, Linear or Claude.
- B. Area capture, then annotate, then share.
- C. Short video or GIF.

**Cost:** two costs, both unquantified.
- Switching: choosing a product and its shortcut on each capture, and keeping four sets of habits. Frequency and time per capture are not measured. `[assumption:unvalidated]`
- Money: Mario does not want to pay further subscriptions. `[doc:user-2026-10-20-screenme]` Of the four products, only Screen Studio is subscription-only for new buyers; Shottr and Xnapper are listed as one-time purchases. `[doc:web-2026-10-20-prior-art-pricing]` Whether Mario currently pays any subscription for capture is not known. `[assumption:unvalidated]`

## Why now

Screen Studio removed its one-time license for new customers, reported on 2025-10-01; new buyers must take a subscription, listed in 2026 at $29 a month or about $108 a year. `[doc:web-2026-10-20-prior-art-pricing]` This is the dated external change behind "non voglio pagare altri abbonamenti": the product covering flow C moved to recurring pricing. `[doc:user-2026-10-20-screenme]`

Limit of this why-now: it touches flow C only. For the still-capture flows A and B no dated change is evidenced; the still products Mario has are one-time purchases. `[doc:web-2026-10-20-prior-art-pricing]` A candidate structural reason, that one builder with a coding agent can now produce a native macOS capture product at low cost, is a hypothesis with no dated line crossed. `[assumption:unvalidated]`

## Riskiest assumption

If Screenme handles flow A (area capture, then paste into Slack, Linear or Claude) at least as quickly as the product Mario uses for it today, Mario will take his daily still captures with Screenme and stop opening Shottr, Xnapper and iScreen Shoter for them. `[assumption:unvalidated]`

**Would be falsified by:** a capture log kept for the first 10 working days with a Screenme build that does flow A, showing Mario still starting flow A captures in another product on most days, or reporting that a missing step (annotation, a specific shortcut, a capture mode) sent him back. The 10-day window is a chosen test length. `[assumption:unvalidated]`

**Cheapest test, before building:** a capture diary for 5 working days. For every capture Mario notes one line: product used, flow (A, B, C or other), destination, and anything that annoyed him. This tells phase 1 which flow dominates, which product currently owns it, and what "good enough to switch" has to beat. The 5 and 10 day windows are chosen test lengths, not measured facts. `[assumption:unvalidated]`

Why this one: every later phase computes value from "Mario stops using the others". If he keeps reaching for Shottr out of habit, or because one step is missing, the fragmentation stays and Screenme becomes a fifth product. Confidence is low because no capture of his has been observed, and the collapse is total.

## Prior art

- **CleanShot X: solved well, adopted.** Covers capture, annotation, Quick Access overlay and recording in one product; sold as a $35 one-time license (CleanShot Basic, one year of updates, 1 GB cloud) or CleanShot Pro at $10/user/month billed annually. `[doc:web-2026-10-20-prior-art-pricing]` It would remove the fragmentation without a subscription, so it is the direct alternative to building. Mario named it as the reference and has not installed it. `[doc:user-2026-10-20-screenme]` `[doc:observed-2026-10-20-installed-tools]`
- **Shottr: solved well for still captures, adopted by Mario.** One-time purchase. `[doc:web-2026-10-20-prior-art-pricing]` `[doc:observed-2026-10-20-installed-tools]` Not a full replacement: Mario still keeps other products next to it, for reasons not recorded. `[assumption:unvalidated]`

Verdict on "do not proceed": CleanShot X is the case where the problem is already solved well and adopted by the market. For a personal product the reasons to proceed anyway are Mario's stated constraints (lightweight, native, no subscriptions) `[doc:user-2026-10-20-screenme]` and the value he may place on owning and shaping it, which is a preference, not evidence. Whether CleanShot X would end the fragmentation for him is untested. `[assumption:unvalidated]`

## Beliefs this frame requires

| Belief | Confidence | Collapse if wrong |
|--------|-----------|-------------------|
| Mario will switch his daily still captures to Screenme once flow A is good enough | low | total: Screenme becomes a fifth product |
| Flow A is the most frequent flow and the one to win first | medium (his own ranking, not observed) | high: the first build targets the wrong flow |
| Switching between products is a real daily cost, not a mild annoyance | low (not measured) | high: no problem worth the build |
| One-time products like CleanShot X do not already satisfy him | low (untried) | high: buying beats building |
| Flow C can wait without keeping Screen Studio, and its subscription, in the mix | medium (he moved the editor to Later) | medium: fragmentation persists for video |

## Open questions

| Question | Who can answer | Inherited by |
|----------|----------------|--------------|
| Which product does Mario use for each of flows A, B and C today, and how often per day? | Mario, via the 5-day capture diary | phase 1 |
| Does Mario currently pay a subscription for any capture product, Screen Studio included? | Mario | phase 1 |
| Would a CleanShot X trial end the fragmentation? If yes, is building still the choice, and why? | Mario | phase 1, before any build |
| Does flow C mean a plain screen recording or GIF (no editor), and is that enough to drop Screen Studio for short clips? | Mario | phase 1, then phase 4 scope |
| Why does Mario keep Xnapper and iScreen Shoter next to Shottr: which capability does each one cover? | Mario | phase 1 |

## Phase 1 research target

Validate or kill the riskiest assumption from Mario's own captures: run the 5-day capture diary, record product, flow, destination and friction for each capture, and from it name the flow Screenme must beat first and the bar it must clear. Decide in the same phase whether a CleanShot X trial runs as the buy-instead-of-build control.
