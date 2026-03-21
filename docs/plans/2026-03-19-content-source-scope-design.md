# Content Source Scope Design

**Problem:** The main sorting view currently supports only two top-level source modes: `Today` and `Random`, where `Today` always means a single day and `Random` ends on a generic empty state. The user wants `Today` to expose `Day / Week / Month`, while `Random` remains day-based and offers a clear "再来一组" continuation when the current random day is exhausted.

## Approved interaction design

### Top-level source switch

- Keep the first row as `Today / Random`.
- When `Today` is selected, show a second row with `Day / Week / Month`.
- When `Random` is selected, hide the second row and keep the existing random date label behavior.

### Today sub-scopes

- `Day`: current behavior, using only today’s photos.
- `Week`: current calendar week.
- `Month`: current calendar month.

All three scopes should reuse the same card stack, swipe actions, note behavior, undo flow, and filmstrip behavior. The only difference is the source date interval that feeds `todayAssets`.

### Random continuation

- `Random` remains "random day", not random week/month.
- When the current random day has no remaining unmarked photos, the stage empty state should show a centered primary CTA: `再来一组`.
- Tapping that CTA should pick another random day and immediately reload the stack.
- No automatic jump is required in this version; the button is explicit and predictable.

## Data-flow design

### Source state

Introduce two related concepts:

- A top-level source mode: `today` or `random`
- A today sub-scope: `day`, `week`, or `month`

The current `selectedSourceDay` helper becomes a source interval helper that returns a date range:

- `today + day` -> start of day to next day
- `today + week` -> start of week to next week
- `today + month` -> start of month to next month
- `random` -> start of random picked day to next day

The existing fetch pipeline can stay largely intact if it is generalized from `rebuildSource(for day:)` to `rebuildSource(for range:)`.

### Empty state behavior

- Existing empty/loading stage layout stays in place.
- Add a variant for random empty state with:
  - title describing the random day is finished
  - primary action button for `再来一组`
- Non-random empty states remain passive informational states.

## Risks and mitigations

- Risk: expanding from one-day fetches to week/month ranges could affect stack ordering or filmstrip consistency.
  - Mitigation: keep existing descending creation-date fetch and reuse `todayOrderByID`.
- Risk: random empty CTA could appear at the wrong time during loading transitions.
  - Mitigation: gate it on the existing `shouldShowStageEmptyState` and `dateSourceMode == .random`.
- Risk: widget count semantics may change subtly because it currently tracks the active source bucket.
  - Mitigation: keep current counting behavior tied to the active source until product semantics are revisited separately.

## Verification

- `Today -> Day` still behaves exactly like today.
- `Today -> Week` loads current-week photos and supports swiping, undo, and notes.
- `Today -> Month` loads current-month photos and supports the same flows.
- `Random` still picks a random day.
- Finishing a random day shows a central `再来一组` CTA and loads another random day when tapped.
