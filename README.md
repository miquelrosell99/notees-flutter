# Notees Mobile

A first-class Flutter companion app for [Notees](https://github.com/notees/notees) — your self-hosted notes, journals, and tasks.

## Features

- **Self-hosted first**: connect to any Notees server you control.
- **Biometric lock**: protect the app with fingerprint/face unlock.
- **Quick capture**: jot down notes or receive shared text from other apps.
- **Offline queue**: save quick notes locally and sync when connectivity returns.
- **WebView editor**: open the full Notees web app with a native bridge and a keyboard-snapped edit toolbar.
- **Bottom navigation**: Home, Tasks, Pages, and Search tabs.
- **Advanced search**: plain text search plus an Immich-style bottom-sheet filter for node type, task state, date range, and sort order.
- **Reusable node picker**: the same search/filter UI is available as a bottom-sheet picker for inserting links and selecting pages anywhere in the app.

## Build

```bash
cd mobile
flutter pub get
flutter build apk --release
```

## Edit toolbar

When editing a note, a native bottom toolbar snaps above the on-screen keyboard. It drives the web-based Lexical editor through `window.noteesMobileEditor`:

- `applyFormat("bold")` / `"italic"` / `"underline"` / `"strikethrough"` / `"code"`
- `insertLink()` — wraps selected text (or the word `link`) in a `[[...]]` wiki-link.
- `insertDate()` — inserts `[[YYYY-MM-DD]]` for today's date.

The editor reports focus changes via the `notees:editor-focus-changed` DOM event, which the Flutter shell forwards over `FlutterBridge` to show/hide the bar.

## Advanced search & node picker

The Search tab supports plain text search and advanced filters via a slide-up bottom sheet. Filters include node type, task state, date range, and sort order. The Flutter client calls the structured endpoint `POST /nodes/search`, which returns the same `SearchResponse` shape as the plain GET search.

The same UI powers `NodePicker`, a reusable bottom sheet for selecting a node anywhere in the app. It is currently used by the editor toolbar's link button so users pick an existing page instead of typing a placeholder wiki-link.

## Development

Run in debug mode:

```bash
flutter run
```

Lint and analyze:

```bash
flutter analyze
```
