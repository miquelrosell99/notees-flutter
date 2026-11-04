// Golden generator — runs the query-golden corpus against the TS reference
// (packages/query over better-sqlite3 with the TS store schema) and fills
// the expected ids/count/aggregate per case. The matches pins in the author
// file are ASSERTED (semantic pins), not generated.
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

// Usage: node scripts/query/gen-golden.mjs <author.json> <output.json>
//   [monorepoRoot]   (monorepoRoot defaults to the `notees` sibling clone —
//                     the AGENTS.md server-reference convention; it must
//                     carry packages/query built + packages/store's
//                     better-sqlite3 in node_modules)
const defaultRoot = fileURLToPath(new URL('../../../notees', import.meta.url));
const [authorPath, outputPath, monorepoRoot = defaultRoot] = process.argv.slice(2);
if (!authorPath || !outputPath) {
  console.error('usage: gen-golden.mjs <author.json> <output.json> [monorepoRoot]');
  process.exit(2);
}
const require = createRequire(import.meta.url);
const Database = require(`${monorepoRoot}/packages/store/node_modules/better-sqlite3`);
const {
  parseQueryAst,
  runQuery,
  runAggregate,
  countQuery,
  matches,
} = require(`${monorepoRoot}/packages/query/dist/index.js`);

const golden = JSON.parse(readFileSync(authorPath, 'utf8'));
const seed = golden.seed;

const db = new Database(':memory:');
db.exec(`
CREATE TABLE node (
  id TEXT PRIMARY KEY,
  parent_id TEXT,
  content TEXT,
  created_at TEXT,
  updated_at TEXT,
  is_class INTEGER NOT NULL DEFAULT 0,
  is_embedded INTEGER NOT NULL DEFAULT 1,
  is_active INTEGER NOT NULL DEFAULT 1,
  class_ids TEXT NOT NULL DEFAULT '[]',
  tag_ids TEXT NOT NULL DEFAULT '[]',
  cover_asset_id TEXT,
  banner_asset_id TEXT,
  aliased_node_id TEXT,
  position TEXT,
  parentless_role TEXT
);
CREATE TABLE edge (source_id TEXT NOT NULL, target_id TEXT);
CREATE TABLE class_hierarchy (class_id TEXT NOT NULL, ancestor_id TEXT NOT NULL);
CREATE TABLE class_member_set (
  node_id TEXT NOT NULL, class_id TEXT NOT NULL, present INTEGER NOT NULL,
  hlc_physical INTEGER NOT NULL DEFAULT 0, hlc_logical INTEGER NOT NULL DEFAULT 0, actor_id TEXT
);
CREATE TABLE class_property (
  class_id TEXT NOT NULL, property_schema_id TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1,
  pinned INTEGER NOT NULL DEFAULT 0,
  hlc_physical INTEGER NOT NULL DEFAULT 0, hlc_logical INTEGER NOT NULL DEFAULT 0, actor_id TEXT
);
CREATE TABLE property_schema (
  id TEXT PRIMARY KEY, type TEXT NOT NULL DEFAULT 'text',
  default_value TEXT, options TEXT NOT NULL DEFAULT '[]'
);
CREATE TABLE property_value (
  id TEXT PRIMARY KEY, node_id TEXT NOT NULL, property_schema_id TEXT NOT NULL,
  value TEXT NOT NULL, idx INTEGER NOT NULL DEFAULT 0,
  hlc_physical INTEGER NOT NULL DEFAULT 0, hlc_logical INTEGER NOT NULL DEFAULT 0, actor_id TEXT
);
CREATE TABLE property_value_tombstone (
  node_id TEXT NOT NULL, property_schema_id TEXT NOT NULL, idx INTEGER NOT NULL DEFAULT 0,
  hlc_physical INTEGER NOT NULL DEFAULT 0, hlc_logical INTEGER NOT NULL DEFAULT 0, actor_id TEXT
);
CREATE TABLE property_value_element_tombstone (
  element_id TEXT PRIMARY KEY, node_id TEXT NOT NULL, property_schema_id TEXT NOT NULL,
  hlc_physical INTEGER NOT NULL DEFAULT 0, hlc_logical INTEGER NOT NULL DEFAULT 0, actor_id TEXT
);
CREATE VIRTUAL TABLE search_index USING fts5(content, tokenize='unicode61');
CREATE TABLE search_index_docid (node_id TEXT PRIMARY KEY, docid INTEGER NOT NULL);
`);

const insertNode = db.prepare(`INSERT INTO node (
  id, parent_id, content, created_at, updated_at, is_class, is_embedded, is_active,
  class_ids, tag_ids, cover_asset_id, banner_asset_id, aliased_node_id
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
const insertEdge = db.prepare('INSERT INTO edge (source_id, target_id) VALUES (?, ?)');
const insertHierarchy = db.prepare('INSERT INTO class_hierarchy (class_id, ancestor_id) VALUES (?, ?)');
const insertMember = db.prepare('INSERT INTO class_member_set (node_id, class_id, present, hlc_physical, hlc_logical) VALUES (?, ?, ?, ?, ?)');
const insertBinding = db.prepare('INSERT INTO class_property (class_id, property_schema_id, active, pinned, hlc_physical, hlc_logical) VALUES (?, ?, ?, ?, ?, ?)');
const insertSchema = db.prepare('INSERT INTO property_schema (id, type, default_value, options) VALUES (?, ?, ?, ?)');
const insertValue = db.prepare('INSERT INTO property_value (id, node_id, property_schema_id, value, idx, hlc_physical, hlc_logical) VALUES (?, ?, ?, ?, ?, ?, ?)');
const insertTombstone = db.prepare('INSERT INTO property_value_tombstone (node_id, property_schema_id, idx, hlc_physical, hlc_logical) VALUES (?, ?, ?, ?, ?)');
const insertFts = db.prepare('INSERT INTO search_index (content) VALUES (?)');
const insertDocid = db.prepare('INSERT INTO search_index_docid (node_id, docid) VALUES (?, ?)');

db.transaction(() => {
  for (const n of seed.nodes) {
    insertNode.run(
      n.id, n.parent_id ?? null,
      JSON.stringify([{ type: 'text', text: n.title }]),
      n.created_at, n.updated_at, n.is_class, n.is_embedded, n.is_active,
      JSON.stringify(n.class_ids), JSON.stringify(n.tag_ids),
      n.cover_asset_id ?? null, n.banner_asset_id ?? null, n.aliased_node_id ?? null,
    );
    const docid = insertFts.run(n.search_text).lastInsertRowid;
    insertDocid.run(n.id, docid);
  }
  for (const e of seed.edges) insertEdge.run(e.source_id, e.target_id);
  for (const r of seed.class_hierarchy) insertHierarchy.run(r.class_id, r.ancestor_id);
  for (const r of seed.class_member_set) insertMember.run(r.node_id, r.class_id, r.present, r.hlc_physical, r.hlc_logical);
  for (const r of seed.class_property) insertBinding.run(r.class_id, r.property_schema_id, r.active, r.pinned, r.hlc_physical, r.hlc_logical);
  for (const r of seed.property_schema) insertSchema.run(r.id, r.type, r.default_value, r.options);
  for (const r of seed.property_value) insertValue.run(r.id, r.node_id, r.property_schema_id, r.value, r.idx, r.hlc_physical, r.hlc_logical);
  for (const r of seed.property_value_tombstone) insertTombstone.run(r.node_id, r.property_schema_id, r.idx, r.hlc_physical, r.hlc_logical);
})();

const store = {
  database: {
    prepare(sql) {
      const stmt = db.prepare(sql);
      return {
        all: (...params) => stmt.all(...params),
        get: (...params) => stmt.get(...params),
      };
    },
  },
};

const failures = [];
for (const testCase of golden.cases) {
  const ast = parseQueryAst(testCase.ast);
  const options = {};
  if (testCase.options?.now) options.now = new Date(testCase.options.now);
  if (testCase.options?.selfNodeId) options.selfNodeId = testCase.options.selfNodeId;

  try {
    if (testCase.aggregate) {
      const result = runAggregate(store, ast, options);
      testCase.expectedColumns = result.columns;
      testCase.expectedRows = result.rows;
      testCase.expectedCount = result.rows.length;
    } else if (testCase.matches) {
      for (const [nodeId, expected] of Object.entries(testCase.matches)) {
        const actual = matches(store, nodeId, ast, options);
        if (actual !== expected) {
          failures.push(`${testCase.name}: matches(${nodeId}) expected ${expected} got ${actual}`);
        }
      }
      testCase.expectedIds = null;
      testCase.expectedCount = countQuery(store, ast, options);
    } else {
      const result = runQuery(store, ast, options);
      const ids = result.ids;
      testCase.expectedCount = ids.length;
      testCase.expectedIds = testCase.orderedIds ? ids : [...ids].sort();
    }
  } catch (error) {
    failures.push(`${testCase.name}: ${error.message}`);
  }
}

// Sanity: the SQL compiles for every case (parse+compile is part of the gate).
if (failures.length > 0) {
  console.error('FAILURES:');
  for (const f of failures) console.error(' -', f);
  process.exit(1);
}

writeFileSync(outputPath, JSON.stringify(golden, null, 2) + '\n');
console.log(`filled ${golden.cases.length} cases`);
for (const c of golden.cases) {
  console.log(
    ` - ${c.name}: ${c.aggregate ? JSON.stringify(c.expectedRows) : JSON.stringify(c.expectedIds)} (count ${c.expectedCount})`,
  );
}
