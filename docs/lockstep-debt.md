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

## 2026-11-05 — Flutter unlock re-prompt UI is missing

The fail-loud ruling ships (2026-11-05 lockstep slice): a keyed workspace
refuses to open keyless — `resolveWorkspaceKey` (the
`apps/web/src/ui/app/store-connection.ts` port) reports locked, the open
throws `EncryptedWorkspaceLockedError` BEFORE any selection is persisted,
and the workspace management view surfaces the refusal banner ("sign in
with your password") plus lock badges from the listing's `encrypted` flag.
Password sign-in unlocks (the login kdf derives the master key; the next
open fetch-or-ensures the workspace key).

What remains: the web client's W2 unlock MODAL — an in-session re-prompt
that re-derives the master key without a full sign-out. Flutter has no
re-login-without-logout flow, so a reloaded / 2FA-completed session must
sign out and back in to unlock; that re-prompt UX (and its
`account_locked` rate-limit surface) is the remaining locked-UI port. The
TS engine's locked-skip cursor rewind (`firstSkippedSeq`, self-heal on
unlock) is likewise still unported — moot while locked workspaces refuse
to open, but it becomes relevant again the day an unlock path exists.

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
