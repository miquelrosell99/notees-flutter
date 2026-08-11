# Gap Analysis — Notees Mobile (Flutter) vs. Web Client

**Date:** 2026-08-10  
**Scope:** Mobile app `lib/` vs. web client `frontend/src/` in the sibling `notees` repo.  
**Purpose:** Identify feature, UX, and protocol gaps so the mobile roadmap can be prioritized against the web source of truth.

---

## Executive summary

The Flutter app now matches the Android product description for a **capture-first, task-first, three-tab phone experience** (Inbox · Tasks · Library) and is aligned with the server's operation-relay sync protocol. The web client remains the richer, full-workspace surface. The biggest gaps are not in basic note/task capture but in **advanced view modes, analytic/exploratory surfaces, plugin ecosystem, administrative features, and deep editor power-user features** that are intentionally out of scope for a v1 mobile app.

| Category | Web | Mobile | Gap verdict |
|---|---|---|---|
| Core node model / sync protocol | ✅ Operation relay v2 | ✅ Operation relay v2 | **Parity** |
| Pages, blocks, journals, tasks | ✅ Full | ✅ Core subset | **Near parity** |
| Capture surfaces | Browser quick-add | QS tile, floating bubble, share sheet, shortcuts | **Mobile leads** |
| View modes | 10+ modes | List / Card / Reader / Journal continuous | **Large gap** |
| Search / queries | Saved queries, query builder, filters | Local + server search, basic filters | **Medium gap** |
| Collaboration / sharing | Shares, public views, comments | Comments partial, shares missing | **Medium gap** |
| Plugins / extensions | Flashcards, OPML export, plugin manager | None | **Large gap** |
| Settings / admin | Workspace admin, members, billing | Per-device settings only | **Large gap** |

---

## 1. Core data & sync parity

| Feature | Web | Mobile | Status | Notes |
|---|---|---|---|---|
| Operation-relay protocol (`/api/relay/*`) | ✅ | ✅ | Parity | Mobile rewritten to relay in `plan-sync-relay.md`. |
| HLC/version-vector conflict resolution | ✅ | ✅ | Parity | Implemented in `hlc_clock.dart`, `relay_models.dart`. |
| Offline outbox / background sync | Service worker + IndexedDB | WorkManager + SQLite | Parity in concept | Mobile background sync exists; asset uploads may still need foreground. |
| Local-first derived state rebuild | ✅ Full SQLite rebuild from op log | Partial (`node_cache` appliers) | Partial | Mobile appliers cover node CRUD, content, properties, class assign. Not a full derived rebuild. |
| Multi-workspace / server switching | ✅ | ✅ | Parity | Mobile supports multiple server profiles. |
| Restore-epoch detection | ✅ | ✅ | Parity | Implemented in sync service. |
| Snapshot upload | ✅ | ❌ | Missing | Mobile does not upload snapshots. |
| Real-time WebSocket sync | Experimental / optional | ❌ | Missing | Mobile is pull/push only. |
| Asset / attachment uploads | ✅ | Partial | Partial | Share receiver handles images; full asset block support unclear. |

**Verdict:** Sync is functionally aligned. The remaining gap is full derived-state rebuild and real-time presence, both of which are acceptable for a phone MVP.

---

## 2. Pages, blocks, and editor

| Feature | Web | Mobile | Status | Notes |
|---|---|---|---|---|
| Block-based notes | ✅ | ✅ | Parity | Headings, paragraphs, bullets, checkboxes, links. |
| Bidirectional links `[[...]]` | ✅ | ✅ | Parity | Mobile renders tappable sage pills. |
| Backlinks panel | ✅ Right sidebar | ❌ | Missing | Mobile has no backlink surface. |
| Inline node mentions (`@`, `[[`) | ✅ | ✅ | Parity | Mention picker exists. |
| Slash commands | Rich palette (`/task`, `/date`, `/link`, etc.) | Toolbar + limited slash | Partial | Mobile moving to bottom toolbar per user request. |
| Collapsible blocks | ✅ | ✅ | Parity | Respected in reader. |
| Tables | Full CRUD | Read-only / basic | Partial | Complex tables deferred per product description. |
| Whiteboard / canvas blocks | ✅ Full | WebView preview only | Partial | Mobile correctly treats whiteboard as web-only. |
| Code blocks / math / callouts | ✅ | ✅ Basic | Partial | Callouts exist but colors may be hardcoded. |
| Comments / annotations | ✅ Threaded | Partial | Partial | Mobile can read/append; no threaded UI. |
| Page templates | ✅ | ✅ | Parity | Templates exist in mobile. |
| Version history / page activity | ✅ | ❌ | Missing | No history view. |
| Focus mode (distraction-free read) | ✅ | Partial | Partial | Reader view exists; no dedicated focus toggle. |
| Presentation mode | ✅ | ❌ | Missing | N/A for phone v1. |
| Page properties / metadata editor | ✅ Full class/property editor | Partial | Partial | Mobile implements class-level property metadata recently. |

**Verdict:** The mobile editor covers ~70 % of web editor power. The intentional omissions (whiteboard full editing, complex tables, version history) match the product description.

---

## 3. Tasks

| Feature | Web | Mobile | Status | Notes |
|---|---|---|---|---|
| Task as a node class | ✅ | ✅ | Parity | Uses `SystemClassUuids.task`. |
| Status / deadline / scheduled / priority | ✅ | ✅ | Parity | Property-based. |
| Task views (Today / Upcoming / Someday / Completed) | ✅ Saved views | ✅ Segments | Near parity | Mobile now has these segments per user request. |
| All tasks / undated tasks modes | ✅ | ✅ Added | Near parity | Recently added. |
| Sort options | Multiple + saved | due/priority/manual/created | Partial | Missing saved sort presets. |
| Swipe gestures (complete / snooze / delete) | ✅ | ✅ Added | Near parity | Recently added. |
| Task detail sheet | ✅ | ✅ | Parity | Bottom sheet on mobile. |
| Recurring tasks | ✅ | ❌ | Missing | No recurrence UI or rule engine. |
| Task recurrence rule CRUD | ✅ | ❌ | Missing |  |
| Sub-tasks / task hierarchy | ✅ | Partial | Partial | Parent page link exists; nested task tree not exposed. |
| Calendar view for tasks | ✅ | Partial | Partial | Journal calendar exists; not a task-specific calendar. |

**Verdict:** Mobile task UX is now close to the web's common workflows. Recurrence is the largest missing piece.

---

## 4. Journals / daily notes

| Feature | Web | Mobile | Status | Notes |
|---|---|---|---|---|
| Daily journal page per date | ✅ | ✅ | Parity | Deterministic date UUIDs. |
| Continuous journal feed | ✅ | ❌ | Missing / in-progress | User asked to load pages directly as a continuous list. |
| Calendar navigation for dates | ✅ | Partial | Partial | Calendar bottom popup requested. |
| Highlighted days with entries | ✅ | Partial | Partial | Calendar popup should highlight existing date pages. |
| Date page titles read-only | ✅ | ❌ Fixed? | In progress | User requested non-editable date titles. |

**Verdict:** Journal view is being actively reshaped to match a continuous, date-centric reading experience.

---

## 5. Library, tags, classes, and browsing

| Feature | Web | Mobile | Status | Notes |
|---|---|---|---|---|
| Tag graph / class browser | ✅ | Replaced with Classes section | Near parity | Mobile now shows Classes instead of Tags per user request. |
| Alphabetical index | ✅ | Removed | N/A | User removed alphabetical section due to UUID sorting issues. |
| Recent pins as cards | ✅ | ✅ | Parity | Recently fixed blank-title bug. |
| All pages list | ✅ | ✅ | Near parity | Date pages now hidden from All Pages per user request. |
| Archive / trash management | ✅ | ✅ | Parity | Dedicated screens exist. |
| Saved queries / smart folders | ✅ | ❌ | Missing | Query builder removed from context menu; should be advanced-search popup. |
| Graph view (force-directed) | ✅ | ❌ Removed | N/A | Removed per user request. |
| Gantt / timeline / pivot / chart views | ✅ | ❌ Removed | N/A | Removed per user request (or never native). |
| Kanban / table views | ✅ | Partial | Partial | Native table/kanban not yet built; list/card only. |
| Calendar view | ✅ | Partial | Partial | Journal calendar only. |

**Verdict:** Mobile library is intentionally simplified. The remaining work is wiring the query builder as an advanced search popup and deciding whether to port native kanban/table later.

---

## 6. Search

| Feature | Web | Mobile | Status | Notes |
|---|---|---|---|---|
| Full-text offline search | ✅ IndexedDB FTS | ✅ Local SQLite search | Parity in concept | Performance target: <200 ms / 10k nodes. |
| Server-side search fallback | ✅ | ✅ | Parity |  |
| Search page titles, blocks, tasks | ✅ | ✅ | Parity |  |
| Saved searches / query builder | ✅ | ❌ | Missing | Should be reachable from top search bar per user request. |
| Filters (date, class, tag, status) | ✅ | Basic | Partial | Pre-built filters exist; custom filters view-only. |
| Search suggestions / recent | ✅ | Partial | Partial |  |

**Verdict:** Core search works. Saved/custom queries are the next level of parity.

---

## 7. Capture surfaces & Android-specific features

| Feature | Web | Mobile | Status | Notes |
|---|---|---|---|---|
| Quick Settings tile | N/A | ✅ | Mobile-only |  |
| Floating capture bubble | N/A | ✅ | Mobile-only |  |
| Share receiver (text / URL / image) | Browser share target limited | ✅ | Mobile leads |  |
| App shortcuts | N/A | ✅ Added | Mobile-only | New note / task / journal / search. |
| Home-screen widget (today's tasks) | N/A | ✅ | Mobile-only |  |
| Local due-date reminders | Browser notifications | ✅ | Mobile-only | Exact alarms + snooze. |
| Biometric lock + secure storage | N/A | ✅ | Mobile-only | DB encryption claim needs verification. |
| Audio / voice memo capture | N/A | ✅ | Mobile-only | Audio recorder exists. |
| Photo capture | N/A | Partial | Partial | Share handles images; in-app camera capture unclear. |
| Material You dynamic icons | N/A | Partial | Partial | Dynamic color supported; themed launcher icon layer may need completion. |

**Verdict:** Mobile exceeds the web in capture surfaces, which is exactly the product positioning.

---

## 8. Collaboration, sharing, and social features

| Feature | Web | Mobile | Status | Notes |
|---|---|---|---|---|
| Comments / annotations | ✅ Threaded | Partial | Partial | `GET /comment-count` error reported; endpoint mismatch. |
| Shares (workspace-internal) | ✅ | ❌ | Missing | No shares list / bottom sheet. |
| Public share links | ✅ | ❌ | Missing |  |
| Public share read view | ✅ | ❌ | Missing |  |
| Collaborative cursors / presence | ✅ | ❌ | Missing | Product description says not in v1. |
| Mentions / notifications | ✅ | Partial | Partial | Notifications screen exists. |

**Verdict:** Collaboration is largely absent on mobile. Comments need the endpoint fix; shares/public views are entirely missing.

---

## 9. Plugins & extensions

| Feature | Web | Mobile | Status | Notes |
|---|---|---|---|---|
| Plugin manager / runtime | ✅ | ❌ | Missing | N/A for v1. |
| Flashcards plugin | ✅ | ❌ | Missing |  |
| OPML import/export | ✅ | ❌ | Missing |  |
| Custom importers / exporters | ✅ | ❌ | Missing |  |
| Command palette extensions | ✅ | ❌ | Missing |  |

**Verdict:** Plugins are correctly out of scope for v1 per product description.

---

## 10. Settings, admin, and workspace management

| Feature | Web | Mobile | Status | Notes |
|---|---|---|---|---|
| User profile / password / API keys | ✅ | ✅ | Parity |  |
| Workspace members / roles | ✅ | ❌ | Missing |  |
| Workspace billing / plans | ✅ | ❌ | Missing |  |
| Server management | ✅ | ✅ | Parity | Multiple server profiles. |
| Appearance (theme/accent/OLED) | ✅ | ✅ | Parity |  |
| Quick-capture settings | N/A | ✅ | Mobile-only |  |
| Notification preferences | ✅ | Partial | Partial |  |
| Import / export workspace | ✅ | ❌ | Missing |  |
| Backup / restore | ✅ | ❌ | Missing |  |

**Verdict:** Per-device settings are complete. Workspace administration is missing, which is expected for a phone client.

---

## 11. UX / design-system gaps

These come from `docs/flutter-audit.md` and ongoing user feedback:

| Issue | Severity | Status |
|---|---|---|
| Missing `mounted` guards after async gaps | Critical | Partially fixed; sweep remaining. |
| Hardcoded colors / dynamic color tinting surfaces | Critical | Partially fixed. |
| Sub-48 dp touch targets | Critical | Partially fixed. |
| Missing tooltips on icon buttons | High | Partially fixed. |
| Bottom-sheet drag handle inconsistency | Medium | In progress; user requested all popups get drag pill. |
| Reduced motion not respected | Medium | Partially fixed. |
| No undo after swipe delete/archive | High | Partially fixed. |
| Empty-state copy still references paper plane | Medium | User requested update. |
| Card borders in list/reader views | Medium | User requested hairline separators instead. |
| Page titles editable inline | Medium | User requested read-only titles with rename action. |
| Journal titles showing "Untitled" | High | Recently fixed. |
| Recent pages still appearing in Inbox | High | User requested removal. |
| Date pages appearing in Library / All Pages | High | User requested hiding. |

---

## 12. API / backend endpoint mismatches

Reported runtime errors:

| Endpoint | Error | Likely cause | Fix |
|---|---|---|---|
| `GET /comment-count` | 404 Not Found | Server removed or renamed endpoint; mobile still calls it. | Remove call or align with server's comments API. |
| `GET /bad cache node not found in local cache` | Client-side | Node referenced in local cache was deleted/epoch-reset; applier needs graceful fallback. | Improve applier error handling and cache invalidation. |
| `dioerror bad response` | Generic | Likely during sync against legacy endpoints before relay migration. | Verify all callers use `RelayClient`. |

---

## 13. Recommendations by impact

### Phase 1 — Stability & core IA (highest impact)
1. Fix remaining `mounted` guards, hardcoded colors, touch targets, and tooltips.
2. Remove `GET /comment-count` call or align endpoint.
3. Ensure date-page titles are read-only and hidden from Library / All Pages.
4. Remove recent pages from Inbox; keep Inbox as captures + today only.
5. Add consistent drag handles to all bottom sheets/popups.
6. Update empty-state copy and remove paper-plane reference.

### Phase 2 — Reader/editor & search (high impact)
1. Make page titles read-only in reader; context menu rename when allowed.
2. Use shared node-view implementations across list/card/reader.
3. Replace slash commands with a bottom toolbar above the keyboard.
4. Wire query builder as an advanced-search bottom popup from the top bar.
5. Implement continuous journal feed with calendar navigation.

### Phase 3 — Collaboration & tasks (medium impact)
1. Add shares/public shares read-only views.
2. Add task recurrence rule editor.
3. Add native table/kanban views (optional; can remain deferred).

### Phase 4 — Quality & parity polish (lower impact)
1. Full derived-state rebuild from operation log.
2. WebSocket real-time sync.
3. Plugin runtime.
4. Workspace admin features.

---

## 14. Conclusion

The Flutter app is no longer misaligned with the web's **data model or sync protocol**, and it has a superior mobile capture layer. The remaining gaps are mostly **intentional v1 omissions** (graph, timeline, plugins, admin) and **UX polish** (drag handles, empty states, title editing, sheet consistency). The next most valuable work is closing the stability/UX items in Phase 1 and Phase 2, then adding shares/comments parity, rather than chasing feature-for-feature web parity.
