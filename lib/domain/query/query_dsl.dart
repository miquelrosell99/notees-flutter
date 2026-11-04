/// The Notees text query DSL — a compact, safe, injection-free language
/// that compiles to the versioned QueryAST (a strict Dart port of
/// `packages/query/src/dsl.ts`; the contract is the README "Text query
/// DSL" section). Every syntax/resolution error is a
/// [QueryLanguageError] with a useful message and the source position.
///
/// Grammar (fail loud):
///
///   query        := or
///   or           := and (OR and)*
///   and          := not ((AND)? not)*        -- juxtaposition = implicit AND
///   not          := NOT primary | primary
///   primary      := "(" or ")" | STRING | term
///   term         := bareWord                 -- content contains (substring)
///                 | field (op value)?        -- see fields below
///
///   Fields (word followed by an operator):
///     class:Name        class membership (resolved by NAME, hierarchy-aware
///                       at compile time);      "!=" negates
///     isClass:true|false     class identity bit; "!=" negates
///     isEmbedded:true|false  embedding flag for parented nodes (true =
///                            embedded in the parent's body — the Block
///                            role; false = standalone — the Page role);
///                            "!=" negates
///     text:term         content contains (value required)
///     name:term         title (the flattened content text) contains; bare
///                       ":" = title is non-empty (exists); ":="/"=" eq,
///                       "!=" neq — exact, case-sensitive
///     linked:Name       backlinksWithRollup to the named node; "!=" negates
///     `coverAsset:<ref>`  the cover wire node field (uuid or node NAME via
///     `bannerAsset:<ref>` the banner/alias twins): bare ":" = is set, "=" eq,
///     `aliasedNode:<ref>` "!=" neq — range/contains don't fit uuid references
///     `prop:name<op>val`  property condition on the schema called `name`;
///                       no value → exists
///     `<schema>:<op>val`  shorthand: a bare field that resolves to a property
///                       schema name is a property condition (year:>2010)
///
///   Operators: ":" (contains; bare ":" with no value → exists), ":=" /
///   "=" (eq), "!=" (neq), ":>" / ">" (gt), ":>=" / ">=" (gte), ":<" /
///   "<" (lt), ":<=" / "<=" (lte).
///
///   Values: numbers coerce to JSON numbers (numeric comparison), "quoted
///   strings" (phrase contains), or a bare run of non-space/non-paren text
///   (ISO dates, DOIs, URLs, citekeys — lexicographic comparison).
///
/// Name resolution is injected by the caller ([QueryLanguageResolvers])
/// because ids are workspace state the parser must not fetch: classes and
/// property schemas resolve by name, nodes by display name (for `linked:`).
/// Unknown fields and unresolvable names are hard errors, never silent text
/// search.
library;

import 'query_ast.dart';

/// Raised when a query string cannot be tokenized, parsed or resolved.
final class QueryLanguageError implements Exception {
  const QueryLanguageError(this.message, [this.position]);

  /// Human-readable description of the offending construct.
  final String message;

  /// Source position of the offending token, when known.
  final int? position;

  @override
  String toString() =>
      position == null ? message : '$message (at position $position)';
}

/// Name → id lookups the caller injects (all optional; missing → error).
/// The matching policy (e.g. case-insensitive) is the resolver's job.
final class QueryLanguageResolvers {
  const QueryLanguageResolvers({
    this.resolveClass,
    this.resolvePropertySchema,
    this.resolveNode,
  });

  /// Class name → class id.
  final String? Function(String name)? resolveClass;

  /// Property schema name → schema id.
  final String? Function(String name)? resolvePropertySchema;

  /// Node display name → node id (`linked:`).
  final String? Function(String name)? resolveNode;
}

/// The parse options: the emitted AST's [scope], the injected [resolvers]
/// and [knownFields] (extra known field names for the unknown-field error,
/// e.g. property schema names).
final class ParseQueryLanguageOptions {
  const ParseQueryLanguageOptions({
    this.scope,
    this.resolvers,
    this.knownFields,
  });

  /// Scope of the emitted AST; defaults to the entire workspace.
  final Scope? scope;

  final QueryLanguageResolvers? resolvers;

  /// Extra known field names for the unknown-field error.
  final List<String>? knownFields;
}

/// Reserved field names; a bare word matching none of these must resolve
/// as a property schema. (The retired `presentasmain` stays in the list —
/// the known-fields error message names it, like the TS reference.)
const _reservedFields = [
  'class',
  'isclass',
  'presentasmain',
  'prop',
  'text',
  'name',
  'linked',
  'coverasset',
  'bannerasset',
  'aliasednode',
];

/// Canonical uuid shape — a node-field value that IS a uuid skips name
/// resolution.
final RegExp _uuidRe = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

// --- tokenizer ---------------------------------------------------------------

/// The operator token family (the wire comparator set the AST accepts).
typedef _Op = String;

/// Longest-first operator table (the scanner matches a prefix against it).
const _operators = <_Op>[
  ':>=',
  ':<=',
  ':=',
  ':>',
  ':<',
  '!=',
  '>=',
  '<=',
  ':',
  '=',
  '>',
  '<',
];

sealed class _Token {
  const _Token(this.start);

  final int start;
}

final class _RawToken extends _Token {
  const _RawToken(this.text, super.start);

  final String text;
}

final class _StringToken extends _Token {
  const _StringToken(this.text, super.start);

  final String text;
}

final class _OpToken extends _Token {
  const _OpToken(this.op, super.start);

  final _Op op;
}

final class _LParenToken extends _Token {
  const _LParenToken(super.start);
}

final class _RParenToken extends _Token {
  const _RParenToken(super.start);
}

final class _AndToken extends _Token {
  const _AndToken(super.start);
}

final class _OrToken extends _Token {
  const _OrToken(super.start);
}

final class _NotToken extends _Token {
  const _NotToken(super.start);
}

final class _EofToken extends _Token {
  const _EofToken(super.start);
}

bool _isWhitespace(String char) =>
    char == ' ' || char == '\t' || char == '\n' || char == '\r' || char == '\f' || char == '\v';

bool _isOpChar(String char) =>
    char == ':' || char == '=' || char == '!' || char == '<' || char == '>';

bool _isBoundary(String? char) =>
    char == null || _isWhitespace(char) || char == '(' || char == ')';

/// The character-level scanner; raw tokens stop before whitespace, parens
/// and operator chars.
final class _Scanner {
  _Scanner(this._text);

  final String _text;
  int pos = 0;

  int get _length => _text.length;

  _Token next() {
    while (pos < _length && _isWhitespace(_text[pos])) {
      pos += 1;
    }
    final start = pos;
    if (pos >= _length) return _EofToken(start);

    final char = _text[pos];
    if (char == '(') {
      pos += 1;
      return _LParenToken(start);
    }
    if (char == ')') {
      pos += 1;
      return _RParenToken(start);
    }
    if (char == '"' || char == "'") {
      return _readString(char, start);
    }
    if (_isOpChar(char)) {
      for (final op in _operators) {
        if (_text.startsWith(op, pos)) {
          pos += op.length;
          return _OpToken(op, start);
        }
      }
      throw QueryLanguageError(
          "unexpected character '$char' at position $start", start);
    }
    var end = pos;
    while (end < _length &&
        !_isBoundary(_text[end]) &&
        !_isOpChar(_text[end])) {
      end += 1;
    }
    if (end == pos) {
      throw QueryLanguageError(
          "unexpected character '$char' at position $start", start);
    }
    pos = end;
    final text = _text.substring(start, end);
    final upper = text.toUpperCase();
    if (upper == 'AND') return _AndToken(start);
    if (upper == 'OR') return _OrToken(start);
    if (upper == 'NOT') return _NotToken(start);
    return _RawToken(text, start);
  }

  _Token _readString(String quote, int start) {
    pos += 1; // opening quote
    final buffer = StringBuffer();
    while (pos < _length) {
      final char = _text[pos];
      if (char == quote) {
        pos += 1;
        return _StringToken(buffer.toString(), start);
      }
      if (char == '\\' && pos + 1 < _length) {
        buffer.write(_text[pos + 1]);
        pos += 2;
        continue;
      }
      buffer.write(char);
      pos += 1;
    }
    throw QueryLanguageError('unterminated string literal', start);
  }
}

// --- value coercion ------------------------------------------------------------

final RegExp _numberPattern = RegExp(r'^[+-]?\d+(\.\d+)?$');

/// The value read: numbers coerce to JSON numbers (numeric comparison),
/// everything else stays a string.
Object _coerceValue(String raw) {
  if (_numberPattern.hasMatch(raw)) {
    return raw.contains('.') ? double.parse(raw) : int.parse(raw);
  }
  return raw;
}

// --- parser --------------------------------------------------------------------

/// The recursive-descent parser over [_Scanner] tokens.
final class _Parser {
  _Parser(this._text, this._scanner, this._options) {
    _lookahead = _scanner.next();
  }

  final String _text;
  final _Scanner _scanner;
  final ParseQueryLanguageOptions _options;
  late _Token _lookahead;

  _Token _advance() {
    final token = _lookahead;
    _lookahead = _scanner.next();
    return token;
  }

  /// Advance past an operator token the caller has already peeked
  /// (internal invariant).
  _Op _advanceOp() {
    final token = _advance();
    if (token is! _OpToken) {
      throw QueryLanguageError(
          'parser internal error: expected an operator token', token.start);
    }
    return token.op;
  }

  QueryLanguageError _error(String message, [int? position]) =>
      QueryLanguageError(message, position ?? _lookahead.start);

  QueryAst parse() {
    if (_lookahead is _EofToken) {
      return QueryAst(
        scope: _scope(),
        root: const Group(logic: 'and', children: []),
      );
    }
    final node = _parseOr();
    final rest = _lookahead;
    if (rest is! _EofToken) {
      throw _error("unexpected '${_describe(rest)}'", rest.start);
    }
    final root = node is Group
        ? node
        : Group(logic: 'and', children: [node]);
    return QueryAst(scope: _scope(), root: root);
  }

  Scope _scope() => _options.scope ?? const EntireWorkspaceScope();

  // --- boolean layers (implicit-AND, OR-explicit, NOT prefix) ------------

  QueryAstChild _parseOr() {
    var left = _parseAnd();
    while (_lookahead is _OrToken) {
      _advance();
      final right = _parseAnd();
      left = left is Group && left.logic == 'or'
          ? Group(logic: 'or', children: [...left.children, right])
          : Group(logic: 'or', children: [left, right]);
    }
    return left;
  }

  QueryAstChild _parseAnd() {
    var left = _parseNot();
    while (_isOperandStart(_lookahead)) {
      if (_lookahead is _AndToken) _advance();
      final right = _parseNot();
      left = left is Group && left.logic == 'and'
          ? Group(logic: 'and', children: [...left.children, right])
          : Group(logic: 'and', children: [left, right]);
    }
    return left;
  }

  bool _isOperandStart(_Token token) => token is _AndToken ||
      token is _NotToken ||
      token is _RawToken ||
      token is _StringToken ||
      token is _LParenToken;

  QueryAstChild _parseNot() {
    if (_lookahead is _NotToken) {
      _advance();
      // NOT binds to one primary (the AST's Not wraps a Condition | Group).
      final child = _parsePrimary();
      if (child is Not) {
        throw _error('NOT cannot negate another NOT; write NOT (…) once');
      }
      return Not(child: child);
    }
    return _parsePrimary();
  }

  QueryAstChild _parsePrimary() {
    final token = _lookahead;
    if (token is _LParenToken) {
      _advance();
      final inner = _parseOr();
      if (_lookahead is! _RParenToken) {
        throw _error("expected ')'", _lookahead.start);
      }
      _advance();
      return inner;
    }
    if (token is _StringToken) {
      _advance();
      return _contentContains(token.text);
    }
    if (token is _RawToken) {
      if (_isReservedKeyword(token.text)) {
        throw _error(
          "'${token.text}' is a reserved word; use it between operands or quote it",
          token.start,
        );
      }
      _advance();
      if (_lookahead is _OpToken) {
        final op = _advanceOp();
        return _buildFieldCondition(token.text, op);
      }
      return _contentContains(token.text);
    }
    if (token is _EofToken) {
      throw _error('expected a term', token.start);
    }
    throw _error("unexpected '${_describe(token)}'", token.start);
  }

  bool _isReservedKeyword(String text) {
    final upper = text.toUpperCase();
    return upper == 'AND' || upper == 'OR' || upper == 'NOT';
  }

  String _describe(_Token token) => switch (token) {
        _RawToken() => token.text,
        _StringToken() => '"${token.text}"',
        _OpToken() => token.op,
        _LParenToken() => '(',
        _RParenToken() => ')',
        _AndToken() => 'AND',
        _OrToken() => 'OR',
        _NotToken() => 'NOT',
        _EofToken() => 'end of query',
      };

  // --- fields --------------------------------------------------------------

  QueryAstChild _buildFieldCondition(String field, _Op op) {
    switch (field.toLowerCase()) {
      case 'class':
        return _negatable(op, () {
          final name = _readValue('a class name', mode: 'token').toString();
          return MemberCondition(
            family: MemberFamilies.class_,
            op: 'in',
            target: IdsTarget(ids: [_resolveClass(name)]),
          );
        });
      case 'isclass':
        return _negatable(op, () {
          final value = _readBoolean('isClass') ? 'true' : 'false';
          return NodeFieldCondition(field: 'isClass', op: 'eq', value: value);
        });
      case 'isembedded':
        return _negatable(op, () {
          final value = _readBoolean('isEmbedded') ? 'true' : 'false';
          return NodeFieldCondition(
              field: 'isEmbedded', op: 'eq', value: value);
        });
      case 'text':
        _requireContainsOp(op, 'text');
        return _contentContains(_readValue('a text term').toString());
      case 'name':
        return _nameCondition(op);
      case 'linked':
        return _negatable(op, () {
          final name = _readValue('a node name', mode: 'token').toString();
          return MemberCondition(
            family: MemberFamilies.links,
            op: 'in',
            target: IdsTarget(ids: [_resolveNode(name)]),
          );
        });
      case 'coverasset':
        return _nodeFieldCondition(NodeFieldFields.coverAsset, op);
      case 'bannerasset':
        return _nodeFieldCondition(NodeFieldFields.bannerAsset, op);
      case 'aliasednode':
        return _nodeFieldCondition(NodeFieldFields.aliasedNode, op);
      case 'prop':
        // `prop` is a prefix, not a condition: the schema name follows the
        // first colon, and a second operator (`prop:year:>2010`) is the
        // real property operator. With no second operator the first one
        // applies (`prop:year:1950` = contains; `prop:year` = exists).
        final schemaName = _readSchemaName();
        final effectiveOp = _lookahead is _OpToken ? _advanceOp() : op;
        return _buildPropertyCondition(schemaName, effectiveOp);
      default:
        return _buildPropertyCondition(field, op);
    }
  }

  /// class/isClass/isEmbedded/linked support ":" and "=" (positive) and
  /// "!=" (wrapped in NOT).
  QueryAstChild _negatable(_Op op, Condition Function() build) {
    if (op == ':' || op == '=') return build();
    if (op == '!=') return Not(child: build());
    throw _error(
        "operator '$op' is not supported here (use ':', '=' or '!=')");
  }

  /// A wire node-field predicate (coverAsset/bannerAsset/aliasedNode):
  /// bare ":" is the set/unset probe — no value (also before AND/OR/NOT)
  /// reads "is set", a value reads eq ("is unset" is `NOT coverAsset:`);
  /// "=" / ":=" eq and "!=" neq take a node reference — a uuid passes
  /// through, anything else resolves through the node-name resolver (the
  /// linked: precedent). Range/contains ops don't fit uuid references (the
  /// AST admits only eq/neq/exists).
  QueryAstChild _nodeFieldCondition(String field, _Op op) {
    String readRef() => _readNodeRef();
    if (op == ':') {
      if (_atConditionBoundary()) {
        return NodeFieldCondition(field: field, op: NodeFieldOps.exists);
      }
      return NodeFieldCondition(
          field: field, op: NodeFieldOps.eq, value: readRef());
    }
    if (op == '=' || op == ':=') {
      return NodeFieldCondition(
          field: field, op: NodeFieldOps.eq, value: readRef());
    }
    if (op == '!=') {
      return NodeFieldCondition(
          field: field, op: NodeFieldOps.neq, value: readRef());
    }
    throw _error(
        "operator '$op' is not supported here (use ':', '=', '!=')");
  }

  /// The lookahead sits at a condition boundary: end of input, a close
  /// paren, or a boolean keyword (the value slot is empty — the exists
  /// arm).
  bool _atConditionBoundary() =>
      _lookahead is _EofToken ||
      _lookahead is _RParenToken ||
      _lookahead is _AndToken ||
      _lookahead is _OrToken ||
      _lookahead is _NotToken;

  /// A node-field reference: uuid as-is, otherwise the display-name
  /// resolver.
  String _readNodeRef() {
    final raw = _readValue('a node name or uuid').toString();
    return _uuidRe.hasMatch(raw) ? raw : _resolveNode(raw);
  }

  void _requireContainsOp(_Op op, String field) {
    if (op != ':' && op != '=') {
      throw _error(
          "operator '$op' is not supported for $field (use ':')");
    }
  }

  /// The title field (title-is-content: the flattened content text, the
  /// sort-by-name expression): bare ":" with no value (also before AND/OR/
  /// NOT) reads "title is non-empty" (the prop: exists precedent); a value
  /// reads contains (LIKE, ASCII case-insensitive — the text: convention);
  /// ":="/"=" eq and "!=" neq are exact, case-sensitive (the prop: :=
  /// convention). Range ops don't fit titles.
  QueryAstChild _nameCondition(_Op op) {
    if (op == ':') {
      if (_atConditionBoundary()) {
        return const NameCondition(op: NameOps.exists);
      }
      return NameCondition(
          op: NameOps.contains,
          value: _readValue('a title').toString());
    }
    if (op == '=' || op == ':=' || op == '!=') {
      if (_lookahead is _EofToken || _lookahead is _RParenToken) {
        throw _error("operator '$op' requires a value");
      }
      return NameCondition(
        op: op == '!=' ? NameOps.neq : NameOps.eq,
        value: _readValue('a title').toString(),
      );
    }
    throw _error(
        "operator '$op' is not supported for name (use ':', ':=' or '!=')");
  }

  bool _readBoolean(String field) {
    final raw = _readValue('true or false', mode: 'token')
        .toString()
        .toLowerCase();
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    throw _error("unknown $field value '$raw' (expected true or false)");
  }

  QueryAstChild _buildPropertyCondition(String schemaName, _Op op) {
    final schemaId = _options.resolvers?.resolvePropertySchema?.call(schemaName);
    if (schemaId == null) throw _unknownField(schemaName);
    final propertyOp = _mapPropertyOp(op);
    if (propertyOp == PropertyOps.exists) {
      return PropertyCondition(schemaId: schemaId, op: PropertyOps.exists);
    }
    if (_lookahead is _EofToken || _lookahead is _RParenToken) {
      throw _error("operator '$op' requires a value");
    }
    return PropertyCondition(
      schemaId: schemaId,
      op: propertyOp,
      value: _readValue('a property value'),
    );
  }

  QueryLanguageError _unknownField(String field) {
    final known = [..._reservedFields, ...?_options.knownFields];
    return _error(
        "unknown field '$field' (known fields: ${known.join(', ')})");
  }

  /// ":" with no following value means exists; the rest map onto the
  /// operator family.
  String _mapPropertyOp(_Op op) {
    switch (op) {
      case ':':
        // A following boolean keyword ends the condition (the value slot
        // is empty): `prop:year AND …` / `prop:year NOT …` = year exists.
        return _atConditionBoundary()
            ? PropertyOps.exists
            : PropertyOps.contains;
      case '=':
      case ':=':
        return PropertyOps.eq;
      case '!=':
        return PropertyOps.neq;
      case '>':
      case ':>':
        return PropertyOps.gt;
      case '>=':
      case ':>=':
        return PropertyOps.gte;
      case '<':
      case ':<':
        return PropertyOps.lt;
      case '<=':
      case ':<=':
        return PropertyOps.lte;
      default:
        throw _error("operator '$op' is not supported here");
    }
  }

  // --- resolution + values --------------------------------------------------

  String _resolveClass(String name) {
    final id = _options.resolvers?.resolveClass?.call(name);
    if (id == null) throw _error("unknown class '$name'");
    return id;
  }

  String _resolveNode(String name) {
    final id = _options.resolvers?.resolveNode?.call(name);
    if (id == null) throw _error("unknown node '$name'");
    return id;
  }

  /// Schema names are single tokens: `prop:year:>2010` must stop the name
  /// before the second operator.
  String _readSchemaName() {
    final token = _lookahead;
    if (token is _EofToken ||
        token is _OpToken ||
        token is _LParenToken ||
        token is _RParenToken) {
      throw _error('expected a property schema name', token.start);
    }
    return _readValue('a property schema name', mode: 'token').toString();
  }

  /// Read a field value.
  ///
  /// "token" mode (names: class/type/linked/schema) stops the value at
  /// operator characters too, so a trailing operator surfaces as its own
  /// syntax error (`class:paper>3` complains about `>`, not about a class
  /// named "paper>3").
  ///
  /// "slice" mode (prop values, text terms) reads the raw source up to the
  /// next whitespace/paren, so URLs (`https://…`), DOIs (`10.2307/…`) and
  /// ISO dates survive intact. Numbers coerce to JSON numbers; everything
  /// else stays a string.
  Object _readValue(String what, {String mode = 'slice'}) {
    final token = _lookahead;
    if (token is _EofToken ||
        token is _RParenToken ||
        token is _OpToken ||
        token is _LParenToken) {
      throw _error('expected $what', token.start);
    }
    if (token is _StringToken) {
      _advance();
      return token.text;
    }
    final stopAtOp = mode == 'token';
    var end = token.start;
    while (end < _text.length) {
      final char = _text[end];
      if (_isWhitespace(char) ||
          char == '(' ||
          char == ')' ||
          (stopAtOp && _isOpChar(char))) {
        break;
      }
      end += 1;
    }
    _scanner.pos = end;
    _advance();
    return _coerceValue(_text.substring(token.start, end));
  }
}

Condition _contentContains(String value) =>
    ContentCondition(op: ContentOps.contains, value: value);

/// Parse a query-language string into a versioned [QueryAst]. Syntax
/// errors, unknown fields and unresolvable class/schema/node names all
/// throw [QueryLanguageError] with a position and a useful message.
QueryAst parseQueryLanguage(
  String text, [
  ParseQueryLanguageOptions options = const ParseQueryLanguageOptions(),
]) =>
    _Parser(text, _Scanner(text), options).parse();

/// Heuristic gate for search boxes deciding whether an input should go
/// through the DSL or plain text search: a `word:` field prefix (excluding
/// URL schemes like `http://`), standalone AND/OR/NOT keywords, or a
/// quoted phrase.
bool looksLikeQueryLanguage(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  if (RegExp(r'(?:^|\s)[A-Za-z_][\w.-]*:(?!\/\/)').hasMatch(trimmed)) {
    return true;
  }
  if (RegExp(r'(?:^|\s)(?:AND|OR|NOT)(?=\s|$)').hasMatch(trimmed)) {
    return true;
  }
  if (trimmed.contains('"')) return true;
  return false;
}
