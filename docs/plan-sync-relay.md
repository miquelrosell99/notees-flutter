# Plan — Migrate Flutter sync to server operation-relay protocol

## Discovery

The server (`../notees`) has moved to a local-first, operation-log architecture:
- Sync endpoints: `POST /api/relay/batch`, `POST /api/relay/catch-up`, `GET /api/relay/snapshot`
- Legacy endpoints removed: `/api/nodes/*`, `/api/properties/*`, `/api/sync/*`
- Operation envelope: `{id, workspaceId, actorId, hlc:{physical,logical}, affectedNodeIds[], opType, payload}`
- Derived SQLite state is rebuilt client-side from the immutable operation log.
- Tasks are plain nodes whose `classIds` contain `SystemClassUuids.task`, with status/deadline/scheduled/priority set via `property.set` operations.
- Daily journals use deterministic date UUIDs and `node.create`/`node.updateContent` operations.

The Flutter app currently uses a custom vector-clock v2 protocol over `/sync/batch` and `/sync`, with no HLC, no operation envelope, no local operation log, and no derived-state rebuild. It will not work against the current server.

## Objective

Align the Flutter app with the server's operation-relay protocol so offline capture, task edits, journal entries, and background sync work end-to-end.

## Scope

Minimum viable migration that keeps the existing UI and tests green:
1. Add relay models and HLC clock.
2. Add `RelayClient` for `/api/relay/*`.
3. Replace the internal sync v2 protocol in `SyncV2Service` with the relay protocol (keep the public `enqueue`/`flush`/`pull` surface for callers).
4. Add minimal operation appliers that update the existing `node_cache` from relay operations so the UI keeps working during the transition.
5. Adapt node/task/journal creation to emit relay operations with the correct class/property payloads.
6. Add tests for new models and sync logic; keep `flutter analyze` and `flutter test` passing.

## Non-scope (future work)

- Full client-side derived SQLite rebuild (operation log + appliers for every table).
- CRDT text/tree state (Yjs) — the mobile MVP will use plain `content` arrays and simple child ordering.
- Real-time WebSocket sync.
- Snapshot upload.
- Semantic conflict UI.

## Phases

### Phase A — Models & clock
- `lib/domain/models/relay/hlc.dart`
- `lib/domain/models/relay/operation_envelope.dart`
- `lib/domain/models/relay/relay_requests.dart`
- `lib/domain/models/relay/operation_payloads.dart` (node.create, node.updateContent, property.set, etc.)
- `lib/core/utils/uuid7.dart` generator for operation ids.
- `lib/domain/services/hlc_clock.dart`

### Phase B — Relay client
- `lib/data/repositories/relay_client.dart`
  - `pushBatch(envelopes)` → `POST /api/relay/batch`
  - `catchUp(workspaceId, hlc, {afterId, limit})` → `POST /api/relay/catch-up`
  - `latestSnapshot(workspaceId)` → `GET /api/relay/snapshot`

### Phase C — Sync service rewrite
- Rewrite `lib/domain/services/sync_v2_service.dart` to:
  - Convert `OperationIntent` into relay `OperationEnvelope` on `enqueue`.
  - Persist envelopes in a new `relay_outbox` table (keep old `sync_outbox` for downgrade safety during dev; migrate on first open).
  - Push via `RelayClient` and update `sync_push_watermark`.
  - Pull via catch-up, apply remote envelopes through appliers, and update `sync_watermark`.
  - Detect restore-epoch changes and reset local state when needed.

### Phase D — Minimal appliers for node_cache
- `lib/domain/services/relay_appliers.dart`
  - `node.create` → insert `Node` into `node_cache`.
  - `node.updateContent` → update `name`/`displayName`.
  - `node.delete`/`node.archive` → mark `isDeleted`.
  - `node.move` → update `parentUuid`.
  - `property.set`/`property.unset` → update `properties` map.
  - `class.assign`/`class.unassign` → update `classesUuid` and derived booleans (`isTask`, etc.).

### Phase E — Adapt callers
- `NodeRepository` and editor/task/capture flows that emit `OperationIntent` must set `classUuids`/`properties` correctly:
  - Tasks: `classUuids: [SystemClassUuids.task]` + `property.set` for status/deadline/scheduled/priority.
  - Daily journal: deterministic UUIDs + `SystemClassUuids.day`/`month`/`year`.
  - Pages: `kind: 'page'` and `isPage: true` (no system class UUID).

### Phase F — Tests & validation
- Unit tests for HLC clock, envelope serialization, appliers.
- Updated sync service tests.
- `flutter analyze` and `flutter test` must pass.

## Verification

```bash
flutter analyze
flutter test
```

Longer term, the app must be manually smoke-tested against a running server:
1. Sign in.
2. Create a note offline → go online → sync.
3. Create a task with a due date.
4. Open the task on the web and confirm it appears.
5. Edit a task on the web → pull on mobile → see the change.
6. Add a journal entry for today.
