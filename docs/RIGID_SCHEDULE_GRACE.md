# Rigid schedule + grace buffer (design)

**Date:** 2026-07-29  
**Status:** **Shipped in 1.0.3+4.** Per-entry auto Regular/OT via window ±15m + on-duty.

## Overview

Morning, Evening, and Night shift windows define session identity and schedule rotation anchors. To make shift classification seamless and precise, entries use roster windows with an automated grace buffer.

## Design Proposal

Stick to **rigid fixed roster windows**. Add a **grace buffer** before start and after end. Anything logged **outside** window ± grace counts as **Overtime**. Inside counts as **Regular** for that shift.

## Grace selection: **15 minutes** (chosen)

| Option | Pros | Cons |
|--------|------|------|
| 5 min | Tight OT boundary | Minor start/finish timing variances marked as OT |
| 10 min | Moderate window | Compact boundary |
| **15 min** | **Best default:** covers early arrival + flexible finish without obscuring OT | Slightly wider Regular band |
| 20 min | Forgives wider variance | 40 min total band |

**Decision: 15 minutes pre and post.**  
Effective shift windows:

| Shift | Official | With ±15m grace |
|-------|----------|-----------------|
| Morning | 07:00–15:00 | 06:45–15:15 |
| Evening | 15:00–23:00 | 14:45–23:15 |
| Night | 23:00–07:00 | 22:45–07:15 (crosses midnight) |

## Behavior implementation

1. User selects (or auto-detects) a shift label when logging.
2. On each ADD PALLET (or on session close):
   - If timestamp is inside **that shift's window ± 15m**: entry role defaults to **Regular** (unless manual Overtime chip selected).
   - If outside window: entry role defaults to **Overtime**.
3. Schedule predictor continues anchoring on **Regular** shifts to maintain cycle accuracy.

## Additional considerations

- 12h shifts use session work block rules to preserve shift identity.
- Pace calculations remain independent (items divided by active logged span).

## Pace interaction

Pace remains measured from first to last log + 30m buffer. Grace affects Regular vs Overtime classification and schedule rotation anchors.

## Implementation details

- `lib/models.dart`: `kRosterGrace`, `isWithinRosterWindow`, `suggestedRoleFromWindow`
- `lib/main.dart`: `_add` / `_roleForCurrentBlock`: per-entry role; override chip wins
- Tests: `test/roster_window_ot_test.dart`

## Settled points

- Auto-apply role classification on ADD PALLET
- Per-entry tags; session badge reflects majority shift type
- Manual Regular/Overtime chip override always available
