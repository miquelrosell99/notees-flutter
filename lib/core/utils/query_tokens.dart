/// Query-token content helpers — the read/write surface the query node's
/// section uses for working with `query` content tokens on a block's
/// contentAst. A faithful port of the web's `apps/web/src/ui/queryTokens.ts`:
/// all writes go through the normal content update path (`object.update` on
/// the node's contentAst, token splice by index — the caller enqueues the
/// `update_content` op, see the editor's commit seam), so a query's AST
/// syncs like any other content. The block itself is MARKED by the query
/// system class; the token is payload.
library;

/// The index of the FIRST `query` token in [tokens], -1 when none.
int firstQueryTokenIndex(List<Map<String, dynamic>> tokens) {
  for (var i = 0; i < tokens.length; i += 1) {
    if (tokens[i]['type'] == 'query') return i;
  }
  return -1;
}

/// The preserved `query` tokens of a content stream (the payloads the
/// editor's text-form round-trip carries by its `[query]` placeholder
/// label — see [AstBuilder.parseInlinePreservingQuery]).
List<Map<String, dynamic>> queryTokensOf(
  List<Map<String, dynamic>> tokens,
) => [for (final token in tokens) if (token['type'] == 'query') token];

/// Rewrite the token's queryAst at [index] (the builder's commit — the
/// web's updateQueryTokenAst). The other tokens ride verbatim.
List<Map<String, dynamic>> withQueryTokenAst(
  List<Map<String, dynamic>> tokens,
  int index,
  Object? queryAst,
) => [
      for (var i = 0; i < tokens.length; i += 1)
        if (i == index)
          {...tokens[i], 'queryAst': queryAst}
        else
          tokens[i],
    ];

/// Append a new query token (a query-classed block's first commit, which
/// creates the payload — the web's appendQueryToken).
List<Map<String, dynamic>> appendQueryToken(
  List<Map<String, dynamic>> tokens,
  Object? queryAst,
) => [
      ...tokens,
      {'type': 'query', 'queryAst': queryAst},
    ];
