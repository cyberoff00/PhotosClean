# Photo Grid Scroll Stability Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stop `PhotoGridView` from intercepting normal scrolling before the user explicitly enters multi-select mode.

**Architecture:** Keep the current selection and auto-scroll logic, but only mount the drag-selection gesture while `isSelectionMode` is active. This removes gesture competition during ordinary browsing without changing delete or filtering behavior.

**Tech Stack:** SwiftUI, Photos, Xcodebuild

---

### Task 1: Gate the drag-selection gesture by selection mode

**Files:**
- Modify: `PhotosClean/PhotoGridView.swift`

**Step 1: Write the failing test**

There is no existing automated UI test target in this project for SwiftUI gesture arbitration. Use a manual reproduction as the failing check:

- Open the app.
- Navigate to "To Delete".
- Try to scroll vertically without entering selection mode.
- Current failure on affected devices: the grid does not scroll reliably.

**Step 2: Verify the failure**

Run on an affected device or simulator path if available and confirm normal browsing can still be blocked before entering selection mode.

**Step 3: Write minimal implementation**

- Add a helper to conditionally apply `.simultaneousGesture(dragSelectGesture(...))`.
- Use the helper from the grid container so the gesture exists only in selection mode.

**Step 4: Verify the fix**

Run:

```bash
xcodebuild -project PhotosClean.xcodeproj -scheme PhotosClean -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

Expected: build succeeds.

Then manually verify:

- Normal mode scroll works.
- Long press still enters selection mode.
- Drag-select still works after entering selection mode.

**Step 5: Commit**

```bash
git add PhotosClean/PhotoGridView.swift docs/plans/2026-03-19-photo-grid-scroll-design.md docs/plans/2026-03-19-photo-grid-scroll-plan.md
git commit -m "fix: avoid intercepting grid scroll before selection mode"
```
