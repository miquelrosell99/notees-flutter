# Screenshots

Per-screen captures of the real app for visual review (sonarly's
`scripts/screenshots` pattern, ported to Flutter).

`run.sh` drives `integration_test/screenshots_test.dart`, which pumps the real
`NoteesApp` with a seeded local workspace (ffi SQLite, `loginLocally`
session, ~12 nodes: a daily note with children, favorites, recents, inbox
items, tasks) and captures: Home, Tasks, Journal, the calendar sheet, Library,
the node editor, the command palette, and Settings.

## Prerequisites

- Flutter SDK on `PATH` (e.g. `export PATH=/root/flutter-sdk/bin:$PATH`).
- A connected Android/iOS device or emulator for actual PNG capture
  (`flutter devices`). On the host tester or a desktop target the flow still
  runs green, but `takeScreenshot` is unsupported there and no images are
  produced.

## Run

```bash
./scripts/screenshots/run.sh                    # first connected device
DEVICE_ID=emulator-5554 ./scripts/screenshots/run.sh
```

## Output

Images land in `docs/img/screenshots/` (created on demand; the directory is
gitignored — do not commit binaries). Review flow: run → eyeball the PNGs.
