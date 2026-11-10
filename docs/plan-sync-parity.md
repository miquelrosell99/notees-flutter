# Plan — Sync parity: snapshot auto-upload, background assets, local rebuild

Owner-approved 2026-11-10: build all remaining sync-related parity gaps
(scope "everything sync-related"; auto-upload gated to unmetered by default
with a Settings selector, Android-convention style). Three slices, each
landed separately (own commit + changelog entry), sequential — they overlap
in `sync_v2_service.dart` / `background_sync.dart`.

Verified non-gaps (do not build): WS heartbeat and server-time offset exist
in neither client; realtime WS already exists on mobile (gap-analysis row 37
is stale — fix the doc as slices land); mobile outbox durability is ahead of
web. Web parity references: `notees-sync/packages/sync/src/sync-engine.ts`
(`maybeUploadSnapshot` :622-764, `resyncFromEpochChange` :576-609),
`transport.ts` (upload paths), `apps/server/src/routes-relay.ts`,
`assets.ts`.

## Slice A — snapshot auto-upload (the documented gap, gap-analysis :36)

Web uploads a checkpoint at the end of every successful `pull()`; mobile has
all transport plumbing (single PUT + multipart in `RelayClient`, AES-GCM seal
in `payload_crypto`, image builder in `node_cache_repository`) but only a
manual Settings tile. Build:

1. **Watermark gates** — after a successful pull, auto-upload only when
   local `receivedHlc` > server snapshot hlc (or server has none) AND >
   this device's durable `uploadedSnapshotHlc` watermark (persisted in the
   watermark store so a restarted app doesn't re-upload against a lagging
   server). Fix the current covering-HLC semantics: today's
   `uploadSnapshot()` gates on the *pushed* watermark; web gates on
   *received*.
2. **Quarantine gate** — never upload while the store holds quarantined
   envelopes. Mobile has no quarantine concept today (failed envelopes are
   left unrecorded for re-apply), so the gate is a documented hook that
   always passes; wire the check so a future quarantine list plugs in.
3. **Size rules (web constants)** — VACUUM-compact the image at ≥32 MiB raw
   before sealing; single PUT when sealed ≤48 MiB; 64 MiB multipart parts
   above; pre-flight skip at ≥256 MiB; 413 → report once per session, keep
   syncing.
4. **File-based pipeline** — replace the bytes-in-RAM upload path
   (`buildV2SnapshotBytes` + single-shot `encryptBytes`) with a file flow
   symmetric to the restore pipeline: build the image in a temp file →
   compact in place → `encryptBytesToFile` (new, mirrors
   `decryptBytesToFile`, zero-copy views) → stream the PUT / read multipart
   parts from disk → temp cleanup in `finally`. Target peak ~2× part size,
   not ~3× image size.
5. **Network gate + Settings selector** — auto-upload only on unmetered
   connections by default. New `ConnectivityProvider.unmetered` heuristic
   (wifi/ethernet = unmetered; mobile = metered; match the pinned
   connectivity_plus major). Settings → Sync: "Upload checkpoints on Wi-Fi
   only" toggle, default ON (persisted in SettingsProvider/prefs). The
   manual Settings tile bypasses the gate (explicit user action). The gate
   also applies inside the 15-min WorkManager pull (do NOT tighten the
   worker's NetworkType constraint — that would delay all background sync).

Tests: watermark gate matrix (server newer/older, watermark absent/stale,
keyless, quarantine hook), compact threshold, 48/64 MiB transport selection,
256 MiB skip, 413 report-once, file-pipeline round-trip + temp cleanup,
network-gate matrix, settings persistence. Update gap-analysis row 36.

## Slice B — background asset uploads (mobile goes beyond web)

> Landed 2026-11-10 (working tree; uncommitted): `pending_asset` queue (schema
> v45), capture-path enqueue on offline/failure with server caps at enqueue,
> drain after flush/before pull in the 15-min worker and OfflineSync,
> attach-4xx retry-next-round, 5xx exponential backoff, dead-letter after 6
> with a Settings → Sync surface, file-streamed uploads, defensive
> background custody (secure-storage-in-isolate unverified). Deviation from
> the plan's letter: sealing happens at DRAIN time (not enqueue), so the
> schema's `sealed`/`iv` columns stay reserved; backoff schedules via a
> `next_attempt_at` column added to the planned list.

Web uploads assets inline, one attempt, no queue (asset-transport.ts) — a
failed upload drops the file. Mobile matches that today
(`AssetRepository.uploadFile`, foreground inline; offline capture drops
files; only text queues). Build:

1. `pending_asset` table (app_database schema bump): local file path, target
   node/parent, mime, sealed flag + IV, retry count, last error, state.
2. Capture flow: on offline / upload failure, persist the file into the
   app-documents pending area + insert `pending_asset` instead of dropping;
   surface "will upload when online" in the capture sheet.
3. Drain in `background_sync.dart`'s 15-min worker (after flush, before
   pull): restore the master key from secure storage
   (`restoreMasterKeyFromStorage`) → `ensureWorkspaceKey` (fetch wrapped key)
   → upload + attach, retry-on-422 (the target node may not exist
   server-side yet — gate on node synced or retry next round). Mark done /
   bump retry with backoff; dead-letter after N attempts and surface in
   Settings → Sync.
4. Constraints honored: SQLCipher-enabled DBs skip background local-DB work
   today (background isolate lacks the key) — pending-asset drain follows
   the same skip, documented; WorkManager `NetworkType.connected` stands;
   server caps (50 MB media / 100 MB docs) enforced at enqueue time.
5. Foreground retry first (on connectivity restore / app start, drain
   pending assets in-process before delegating to the worker).

Tests: enqueue on failure/offline, drain order + 422 retry, backoff +
dead-letter, SQLCipher skip, cap enforcement. Update gap-analysis row 38.

## Slice C — local-first derived rebuild (gap-analysis :33/:259)

> Landed 2026-11-10 (working tree; uncommitted):
> `SyncV2Service.rebuildLocalDerivedState()` — offline replay of the durable
> `relay_operations` archive (HLC + rowid order, bounded batches) through the
> live appliers and the shared `_decryptForApply` E2EE chokepoint; watermarks
> preserved; no dedupe/re-record; StoreError skip mirrors live apply;
> mid-replay failure stays cleared and idempotent; `_flushInFlight` guard +
> pull guard refuse concurrent runs; Settings → Sync "Rebuild local data"
> tile with confirm sheet. Deviation from the plan's letter: the plan said
> "watermark reset" — preserved instead (they describe server cursors, and
> the archive is exactly the applied ops, so they stay correct; resetting
> would force a needless server re-fetch). No bulk window exists in the repo;
> replay rides per-envelope apply + indexing (per plan: no new subsystem).

Mobile keeps the full envelope log (`relay_operations`, apply-and-keep) but
has no replay driver; the only wipe+rebuild path is the restoreEpoch
server round-trip. Build:

1. `SyncV2Service.rebuildLocalDerivedState()` — `_cache.clear()` + replay
   local `relay_operations` (server + local, HLC-ordered) through the
   existing `RelayAppliers` (idempotent, LWW/first-create-wins) + watermark
   reset, all offline. `$e` payloads decrypt through the normal custody key
   path, same as live apply.
2. Trigger: Settings → Sync → "Rebuild local data" (confirm sheet; useful
   after applier bugs and for future applier upgrades). The restoreEpoch
   path stays server-replay (a wiped server must be re-fetched).
3. Out of scope, noted: `relay_operations` is unbounded — pruning ops
   covered by a durable snapshot watermark is a follow-up.

Tests: rebuild convergence (seed cache via ops → corrupt derived state →
rebuild → equals fresh-apply), offline behavior, keyless/E2EE arms, confirm
the epoch path is untouched. Update gap-analysis row 33.

## Landing order + gate

A → B → C, each: scoped analyze+tests, full `flutter test`, CHANGELOG
entry, one commit per slice. Push + one CI build at the end. Host gate
discipline: one suite at a time; both pub-cache patches after every
`pub get`.
