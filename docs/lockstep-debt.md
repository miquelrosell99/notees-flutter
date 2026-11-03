# Lockstep debt register

Known divergences from the Notees monorepo (the TS reference is the source
of truth; this app adapts to it — never the other way around). Entries are
removed when the corresponding lockstep slice ships. Newest first.

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
