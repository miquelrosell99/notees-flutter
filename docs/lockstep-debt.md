# Lockstep debt register

Known divergences from the Notees monorepo (the TS reference is the source
of truth; this app adapts to it — never the other way around). Entries are
removed when the corresponding lockstep slice ships. Newest first.

## 2026-11-03 — GTK asset-UI boundary follow-up (GTK repo owns its side)

Plan 05's Flutter slice ships the full asset channel against the shipped
server routes: `AssetRepository` posts `POST /api/assets` (declaring
`encrypted`/`mimeType`/`iv` on the sealed arm, `objectId` for the attach)
and downloads via `GET /api/assets/:id` with the `x-notees-asset-iv`
header → /info IV resolution, opening sealed bytes through the custody
cache's active workspace key. The GTK port has the matching transport
(`NoteesClient.post_asset`/`get_asset`/`get_asset_info`) and the
`seal_asset_if_keyed`/`open_asset_if_sealed` helpers, but no UI caller wires
them into GTK's asset upload/download surfaces yet — that boundary slice is
the GTK repo's own follow-up; this app tracks it here so the cross-client
contract stays visible.

## 2026-11-03 — Flutter locked-state UI is missing

Reloaded / 2FA-completed / API-key sessions have no master key and sync in
the locked semantic (remote `$e` envelopes skip with a counted `debugPrint`
warning — invisible in release builds; local writes stay plaintext). The
web client's W1 EncryptedLockedBanner + W2 unlock modal (the notees main
repo) are the reference design for the future Flutter banner/unlock slice,
which should also surface the skip counter the sync engine already counts.

## 2026-11-03 — Mention token model drifts from the TS reference

The monorepo's content grammar retired the mention token's captured-text
keys (`text`, `displayText`) in favor of the optional `customLabel` — the
link's visible text is computed at render time (`customLabel ??` the
target's current display name), so renames re-resolve and no stored text
can drift (`content-mark.ts` `mentionTokenSchema`, fixture
`mention-custom-label.json`). The Flutter `MentionToken` /
`AstBuilder.nodeLink` / the editor surfaces still model `text` /
`displayText`.

The 2026-11-03 E2EE fixture lockstep slice verified this drift does NOT
break the gate: contentAst tokens are not strictly validated at the payload
or applier boundary, so the new fixtures replay verbatim and the corpus
converges. The divergence is read-side: display-name / excerpt derivation
for custom-labeled mentions differs from the TS reference until the
content-grammar lockstep slice ports `customLabel` (and rejects the retired
keys) across `lib/domain/models/content/content_token.dart`,
`lib/core/utils/ast_builder.dart`, `lib/core/utils/ast_stringifier.dart`,
and the editor render surfaces.
