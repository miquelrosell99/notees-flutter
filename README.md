# Notees Mobile

A first-class Flutter companion app for [Notees](https://github.com/notees/notees) — your self-hosted notes, journals, and tasks.

## Features

- **Self-hosted first**: connect to any Notees server you control.
- **Biometric lock**: protect the app with fingerprint/face unlock.
- **Quick capture**: jot down notes or receive shared text from other apps.
- **Offline queue**: save quick notes locally and sync when connectivity returns.
- **Native editor**: edit pages with a native block-based editor. Inline styles (bold, italic, strikethrough, code, highlight), node/class/tag links via a bottom-sheet picker, and a read-only properties panel are supported.
- **View modes**: browse nodes as a list, cards, or table. Toggle from Search and Pages; the choice is persisted locally.
- **Bottom navigation**: Home, Tasks, Pages, and Search tabs.
- **Advanced search**: plain text search plus an Immich-style bottom-sheet filter for node type, task state, date range, and sort order.
- **Reusable node picker**: the same search UI is available as a bottom sheet for inserting links and selecting pages anywhere in the app.

## Build

```bash
cd mobile
flutter pub get
flutter build apk --release
```

## Advanced search & node picker

The Search tab supports plain text search and advanced filters via a slide-up bottom sheet. Filters include node type, task state, date range, and sort order. The Flutter client calls the structured endpoint `POST /nodes/search`, which returns the same `SearchResponse` shape as the plain GET search.

The same UI powers `NodePicker`, a reusable bottom sheet for selecting a node anywhere in the app.

## Development

Run in debug mode:

```bash
flutter run
```

Lint and analyze:

```bash
flutter analyze
```
