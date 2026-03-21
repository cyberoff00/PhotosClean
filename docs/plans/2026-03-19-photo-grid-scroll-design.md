# Photo Grid Scroll Stability Design

**Problem:** Some lower-version iOS users cannot scroll down inside the "To Delete" photo grid.

**Context:** `PhotoGridView` currently attaches a drag-selection gesture to the full scroll container at all times. Even when selection mode is off, the gesture still participates in SwiftUI gesture arbitration. Older iOS versions appear more likely to let that gesture interfere with vertical scrolling.

**Approaches considered:**

1. **Enable drag-selection only in selection mode**  
   Keep normal browsing as a plain `ScrollView`. Enter selection mode via long press, then attach the drag-selection gesture and auto-scroll logic. This gives the best stability on older iOS while preserving bulk selection once the user intentionally enters multi-select mode.

2. **Keep the gesture always mounted but raise thresholds / tweak priorities**  
   Smaller code change, but still relies on fragile SwiftUI gesture arbitration. This lowers risk slightly without removing the root cause.

3. **Rebuild selection using UIKit gesture recognizers**  
   Strong control over gesture priority and cancellation, but too heavy for this bug and unnecessary for the current app size.

**Recommended design:** Approach 1.

## Design

### Interaction model

- Normal mode:
  - The grid behaves like a normal `ScrollView`.
  - Taps open the selected photo.
  - Long press on a cell enters selection mode and selects that item.
- Selection mode:
  - The grid attaches drag-selection behavior.
  - Auto-scroll while dragging still works.
  - Exiting selection mode fully resets drag state so scroll never remains locked.

### Implementation notes

- Add a small view helper that conditionally applies the drag-selection gesture only when `isSelectionMode` is `true`.
- Keep `.scrollDisabled(isDragSelecting)` only as the transient lock while a drag-selection is actively running.
- Avoid changing delete filters, asset loading, or selection bookkeeping beyond what is required for the gesture mount point.

### Error handling and risk

- Main risk: selection mode could lose drag-selection entirely if the conditional gesture is attached incorrectly.
- Mitigation: keep the existing drag-selection logic untouched and only move when the gesture becomes active.

### Verification

- Build the app successfully.
- Manual checks:
  - Open "To Delete" and confirm normal vertical scrolling works before selection mode.
  - Long press a cell to enter selection mode.
  - Drag across cells to confirm range selection still works.
  - Exit selection mode and verify scrolling still works immediately afterward.
