# Content Source Scope Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `Day / Week / Month` sub-scopes under `Today` and show a `再来一组` continuation CTA when a random day is exhausted.

**Architecture:** Extend `ContentView` source selection from a single day-vs-random toggle to a two-level state machine: top-level source mode plus a `Today` sub-scope. Reuse the existing card stack and fetch pipeline by generalizing the source rebuild logic from a day to a date interval, then branch the empty state UI when random mode finishes.

**Tech Stack:** SwiftUI, Photos, SwiftData, WidgetKit

---

### Task 1: Model source scope state in `ContentView`

**Files:**
- Modify: `PhotosClean/ContentView.swift`

**Step 1: Write the failing test**

Manual failing check:
- Open the main tab.
- Observe that only `Today / Random` exists and no `Day / Week / Month` scope selector is available.

**Step 2: Verify the failure**

Run the app and confirm the current header has no secondary scope control for `Today`.

**Step 3: Write minimal implementation**

- Add a `TodayScope` enum with `day`, `week`, and `month`.
- Keep `DateSourceMode` as `today` or `random`.
- Add state and helpers that compute the active fetch interval from these two pieces of state.

**Step 4: Run verification**

Build the app and confirm the code compiles.

**Step 5: Commit**

```bash
git add PhotosClean/ContentView.swift
git commit -m "feat: add today source scope state"
```

### Task 2: Generalize source loading from day to range

**Files:**
- Modify: `PhotosClean/ContentView.swift`

**Step 1: Write the failing test**

Manual failing check:
- Attempt to conceptually switch `Today` to `Week` or `Month`.
- Current source fetch logic only supports one day.

**Step 2: Verify the failure**

Inspect `rebuildSource(for day:)` and confirm it always uses start-of-day to next-day bounds.

**Step 3: Write minimal implementation**

- Replace the day-only source rebuild helper with a range-based helper.
- Keep asset sort order and `todayOrderByID` behavior unchanged.
- Update `rebuildCurrentSource()` and related callers to use the new interval helper.

**Step 4: Run verification**

Build the app and manually verify:
- `Today -> Day`
- `Today -> Week`
- `Today -> Month`

all load content without breaking swiping or undo.

**Step 5: Commit**

```bash
git add PhotosClean/ContentView.swift
git commit -m "feat: load content source by interval"
```

### Task 3: Update the header UI for Today scopes

**Files:**
- Modify: `PhotosClean/ContentView.swift`
- Modify: `PhotosClean/zh-Hans.lproj/Localizable.strings`
- Modify: `PhotosClean/en.lproj/Localizable.strings`

**Step 1: Write the failing test**

Manual failing check:
- The header does not show `Day / Week / Month` below `Today`.

**Step 2: Verify the failure**

Open the main tab and confirm the header exposes only first-level controls.

**Step 3: Write minimal implementation**

- Add a second-row segmented/capsule control shown only when `dateSourceMode == .today`.
- Add localization keys for `Day`, `Week`, and `Month`.

**Step 4: Run verification**

Build and verify:
- second row appears only in `Today`
- changing scope reloads the stack
- switching to `Random` hides the second row

**Step 5: Commit**

```bash
git add PhotosClean/ContentView.swift PhotosClean/zh-Hans.lproj/Localizable.strings PhotosClean/en.lproj/Localizable.strings
git commit -m "feat: add today scope controls"
```

### Task 4: Add random empty-state continuation CTA

**Files:**
- Modify: `PhotosClean/ContentView.swift`
- Modify: `PhotosClean/zh-Hans.lproj/Localizable.strings`
- Modify: `PhotosClean/en.lproj/Localizable.strings`

**Step 1: Write the failing test**

Manual failing check:
- In random mode, when the chosen day is exhausted, the stage shows only the generic empty state and offers no direct continuation.

**Step 2: Verify the failure**

Run random mode until it empties and confirm there is no `再来一组` CTA.

**Step 3: Write minimal implementation**

- Add a random-specific empty state overlay/button inside the fixed card stage.
- Reuse the existing random pick workflow when the button is tapped.
- Keep non-random empty state unchanged.

**Step 4: Run verification**

Build and manually verify:
- random empty state shows `再来一组`
- tapping it loads a new random day
- normal empty state for `Today` scopes remains informational

**Step 5: Commit**

```bash
git add PhotosClean/ContentView.swift PhotosClean/zh-Hans.lproj/Localizable.strings PhotosClean/en.lproj/Localizable.strings
git commit -m "feat: add random continue action"
```

### Task 5: Full verification

**Files:**
- Modify: none

**Step 1: Run build verification**

Run:

```bash
xcodebuild -project PhotosClean.xcodeproj -scheme PhotosClean -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

Expected: `BUILD SUCCEEDED`

**Step 2: Manual flow verification**

- `Today -> Day`: swipe, undo, note, share
- `Today -> Week`: swipe through multiple cards
- `Today -> Month`: verify source changes and stack remains stable
- `Random`: pick a day, exhaust it, tap `再来一组`

**Step 3: Commit**

```bash
git add .
git commit -m "feat: add today scopes and random continuation"
```
