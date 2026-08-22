# Plan — Align Notees Flutter app with the Android product description

## Goal
Review the current Flutter mobile app against the provided product description and produce a concrete, phased plan to close the most important gaps. Deliver a shippable, more focused Android experience that matches the capture-first, task-first, three-tab vision.

## Current state — high-level
The app is a working first-class Flutter prototype with solid foundations (sync v2, offline queue, WorkManager, dynamic color, biometric guard, Quick Settings tiles, share receiver). However, its information architecture and several headline features diverge from the product description:

- **Navigation** is 5 tabs (Home/Journal/Tasks/Pages/Search) instead of the described 3 tabs (Inbox, Tasks, Library) plus a persistent Capture affordance.
- **Tasks** are a flat server-fetched list with no segments, sort, swipe gestures, detail sheet, or focus mode.
- **Capture** lacks the floating bubble, the sheet does not expose Task or Quick Journal types, and the share receiver only accepts text.
- **Page Reader** does not exist; the editor is always editable.
- **Library** is split across Journal/Pages/Search with no tag browser, alphabetical index, or pinned recent cards.
- **Search** is server-only with no offline FTS fallback.
- **Android-specific surfaces** are missing home-screen widgets, app shortcuts, and local reminders.
- **Onboarding** is minimal (splash → manual URL → login) with no welcome, QR scan, auto-discovery, quick-capture setup, widget offer, or first-capture coaching.
- **Biometric lock** does not encrypt the local DB at rest (product description says it should).
- **CI does not run tests** and test coverage is very narrow.

A previous audit (`docs/flutter-audit.md`) also lists critical crash/consistency bugs (`mounted` guards, hardcoded colors, sub-48dp touch targets, missing tooltips) that should be fixed in the same effort.

## Recommended approach
Do an **audit-first, phased implementation**:

1. Deliver a written gap report (this plan).
2. Land a **Phase 1** that fixes the existing critical bugs and restructures the core IA (navigation + capture + tasks) to match the product description.
3. Use subsequent phases for remaining Android-specific surfaces, reader/editor refinements, onboarding, and test coverage.

This balances immediate user-facing alignment with stability.

## Phase 1 — Core IA, capture, tasks, stability

### 1.1 Navigation & shell
- Rename/restructure bottom nav to the three destinations: **Inbox**, **Tasks**, **Library**.
- Add a persistent **center + Capture button** in `MainShellScreen` that opens `QuickCaptureSheet`.
- Remove first-class **Journal** and **Pages** tabs; fold them into Library (and Inbox recents).
- Keep Search reachable from the top app bar and the command palette, not as a bottom-nav tab.
- Files: `lib/core/routing/router.dart`, `lib/features/home/screens/main_shell_screen.dart`, `lib/features/home/screens/dashboard_screen.dart`, `lib/presentation/screens/pages_screen.dart`, `lib/presentation/screens/journal_screen.dart`, `lib/features/search/screens/search_screen.dart`.

### 1.2 Tasks redesign
- Replace the flat open-tasks list with segmented task views: **Today**, **Upcoming**, **Someday**, **Completed**.
- Add sort options (due date, priority, manual order, created date).
- Add swipe gestures: right to snooze/change due date, left to delete (with undo SnackBar).
- Add long-press multi-select for batch tag/due-date edits.
- Add a task detail bottom sheet (title, notes, due date/reminder, priority, tags, parent page link).
- Add a focus mode toggle that hides everything except today.
- Files: `lib/features/tasks/screens/tasks_screen.dart`, `lib/features/search/widgets/filter_bottom_sheet.dart`, `lib/domain/models/search_filters.dart`, `lib/data/repositories/node_repository.dart`.

### 1.3 Capture enhancements
- Extend `QuickCaptureSheet` to offer: **note**, **task**, **voice memo**, **photo**, **quick journal entry**.
- Wire the existing `/task` backend support in `QuickCaptureService`.
- Add a quick-journal destination that resolves to today’s daily journal.
- Keep Quick Settings tiles and share receiver; extend share receiver to accept images and URLs (not just text).
- Files: `lib/features/capture/widgets/quick_capture_sheet.dart`, `lib/domain/services/quick_capture.dart`, `lib/native/intent_receiver.dart`, `android/app/src/main/AndroidManifest.xml`, `android/app/src/main/kotlin/.../MainActivity.kt`.

### 1.4 Critical bug fixes from `docs/flutter-audit.md`
- Add `mounted` guards after every async gap in the listed screens.
- Remove hardcoded accent/callout colors; pull from `Theme.of(context).colorScheme`.
- Enlarge sub-48dp touch targets and add missing icon-button tooltips.
- Make dynamic/accent colors unable to tint monochrome surfaces.
- Add undo after swipe-to-delete/archive.
- Respect reduced-motion settings.

### 1.5 Theme/typography hardening
- Configure explicit text roles (Display serif for page titles, Inter/Roboto for UI/body, tighter task/metadata line height).
- Ensure `surfaceTintColor: Colors.transparent` on cards.
- Fix `FilterBottomSheet` radius to 28 and add consistent drag handles.

## Phase 2 — Reader/editor, search, library

### 2.1 Page Reader
- Add a read-first Page Reader mode for pages (serif headline, warm paper background, comfortable line length).
- Tap a block to enter edit mode; otherwise scroll cleanly.
- Render bidirectional links as sage pills.
- Respect collapsible blocks.
- Add floating bottom bar: add block, add task, share, favorite.
- Files: `lib/features/editor/screens/node_editor_screen.dart`, `lib/features/editor/widgets/block_tree_editor.dart`, `lib/features/editor/widgets/ast_rich_text.dart`.

### 2.2 Block Editor alignment
- Add missing slash commands: `/date`, `/bullet`, `/heading`.
- Make `/task` create a real task node/checkbox block, not just Markdown text.
- Ensure formatting toolbar appears above keyboard.
- Auto-save via local operation-log append.

### 2.3 Search
- Build local FTS index over cached node titles/block text/task names.
- Search offline-first, with server-side fallback when online.
- Keep global reachability from top bar.

### 2.4 Library
- Create a unified Library tab with tag browser, recent pins as large cards, alphabetical index.
- Long-press page → pin, archive, focus mode.
- Move Journal and Pages browsing into Library sub-views.

## Phase 3 — Android-specific surfaces

### 3.1 Home-screen widgets
- Add resizable task widgets: compact (2×1), medium (4×2), large (4×4).
- Implement `AppWidgetProvider`, widget XML, and update logic tied to task completion/sync.

### 3.2 App shortcuts
- Add static shortcuts: New Note, New Task, New Journal Entry, Search.

### 3.3 Local reminders
- Add `flutter_local_notifications` and alarm permission handling.
- Schedule exact local reminders for task due dates/times with snooze options (15 min, 1 hour, tomorrow).

### 3.4 Floating capture bubble
- Implement an optional accessibility-style floating bubble (overlay permission, drag reposition, tap to expand capture sheet).

### 3.5 Material You dynamic icon
- Add Android 13 themed/monochrome launcher icon layer.

## Phase 4 — Onboarding & quality

### 4.1 Onboarding
- Welcome screen with privacy promise.
- Server setup with QR scan, URL entry, and local auto-discovery.
- Quick-capture setup (overlay permission, default tile type).
- Widget offer after first sync.
- Guided first capture.

### 4.2 Biometric lock + DB encryption
- Tie biometric lock to SQLCipher encryption at rest (or clarify in the product description that they are separate; current code makes them separate).

### 4.3 Testing & CI
- Add `flutter test` to `.github/workflows/android.yml`.
- Add unit/widget tests for Phase 1–3 features: navigation, capture, tasks, search FTS, sync outbox.
- Add `mocktail` or `mockito` to `dev_dependencies`.

## Verification
- `flutter analyze` passes.
- `flutter test` passes and CI runs it.
- Manual smoke tests: navigation, capture sheet, task segments/swipes, share from another app, Quick Settings tile, offline create + online sync.
