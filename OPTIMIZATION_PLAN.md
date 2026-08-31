# Performance & Scalability Optimization Plan

**Goal:** the app must ingest and display thousands of pending orders and serve hundreds of
thousands of users with zero friction. Stated budget (specs/004 plan.md): cold start < 2 s,
order book load < 3 s, 60 fps on mid-range mobile.

**Method:** the plan is split into phases. Every numbered item is one **atomic PR** — small,
self-contained, independently reviewable. Early phases are easy wins with **no prerequisites**;
later phases are structural changes that build on them. Each item lists the evidence
(file:line as of `main` @ 9465974), the fix, and how to verify it.

**Root cause found (context for the whole plan):** the order book lives in
`Arc<RwLock<Vec<OrderInfo>>>` (`rust/src/api/orders.rs:172-176`) and **every mutation clones
the entire vector and broadcasts it as a full snapshot** over the FRB bridge
(`orders.rs:209-219`). Bulk refetch ingests events one by one (`orders.rs:2745-2758`), so a
cold start with N orders does **O(N²)** clones and N full-book bridge emissions. On the Dart
side, `orderBookProvider` re-materializes every `OrderItem` per emission
(`lib/features/home/providers/home_order_providers.dart:144-163`) and `filteredOrdersProvider`
re-filters and re-sorts everything (`:165-219`). Meanwhile, per-trade 2-second polling loops
(`lib/features/order/providers/trade_state_provider.dart`) run underneath from the bottom nav
bar on every screen. Phases 1–2 remove constant per-event costs; Phase 3 replaces the
snapshot pipeline with deltas (the big lever); Phases 4–5 add persistence, web parity, and
regression protection.

---

## Phase 1 — Quick wins (no prerequisites, hours each)

Independent one-to-few-line fixes. Land in any order.

### PR 1.1 — Demote hot-path logging `fix(perf)`
- **Evidence:** `log::info!` per parsed 38383 event (`rust/src/api/orders.rs:3119-3124`, also
  `:3250`, `:2751`); `log::warn!` per trade-key cache miss (`orders.rs:71`) — misses happen for
  *every* stranger's order. Each record is formatted, secret-scrubbed, mutex-buffered and
  streamed to Dart (`rust/src/api/logging.rs:216-300`). Release default level is `Info`.
- **Fix:** demote per-event logs to `debug!`; log one summary per ingest batch
  ("ingested N orders"). Remove the per-miss `warn!`.
- **Verify:** `cargo test && cargo clippy`; manual: refresh order book, log stream shows one
  summary line instead of thousands.

### PR 1.2 — SQLite indexes for trade lookups `fix(db)`
- **Evidence:** `WHERE json_extract(data,'$.order.id') = ?` with no index —
  `rust/src/db/sqlite.rs:498-511` and 5 more sites (`:513-524`, `:526-542`, `:584-597`,
  `:612-626`, `:631-638`). Called from `local_trade_status` (`orders.rs:2246-2253`) for **every
  non-pending 38383 event**. The denormalized `status` column is also unindexed (used by the
  30-min stale sweep via full `list_trades`).
- **Fix:** migration adding
  `CREATE INDEX idx_trades_order_id ON trades(json_extract(data,'$.order.id'))` (SQLite
  expression index) and `CREATE INDEX idx_trades_status ON trades(status)`.
- **Verify:** `EXPLAIN QUERY PLAN` shows index usage; existing db tests pass.

### PR 1.3 — SQLite connection tuning `fix(db)`
- **Evidence:** `rust/src/db/sqlite.rs:17-22` — pool of 4, but `journal_mode=WAL` /
  `foreign_keys=ON` run once on one connection (`foreign_keys` is per-connection → effectively
  off on 3 of 4). No `synchronous=NORMAL`, so every write fsyncs on mobile flash.
- **Fix:** set pragmas via `SqliteConnectOptions` (applied to every pooled connection); add
  `synchronous=NORMAL`.
- **Verify:** `PRAGMA foreign_keys` returns 1 on all connections in a test; write-heavy test
  timing improves.

### PR 1.4 — O(1) daemon-message dedup `fix(perf)`
- **Evidence:** linear scan of up to 512 hex `String`s under a mutex per kind-14 event
  (`rust/src/api/orders.rs:319-337`, called at `:1249`, `:3043`).
- **Fix:** `HashSet<EventId>` + `VecDeque<EventId>` for eviction order; compare `EventId`
  bytes, not hex strings.
- **Verify:** existing dedup tests; add a unit test for eviction at capacity.

### PR 1.5 — Micro hot-path allocations `fix(perf)`
- **Evidence:** (a) whole `global_dm_keys` `HashMap<String,(Keys,u32)>` cloned per kind-14
  event (`orders.rs:3295`); (b) `lock_order` runs O(n) `retain` over the lock registry on
  every acquisition (`orders.rs:155`).
- **Fix:** (a) hold the read guard / extract the single matching key under the lock;
  (b) prune every Nth call or on release.
- **Verify:** `cargo test`; no behavior change.

### PR 1.6 — Bound the order-book relay filter `fix(nostr)`
- **Evidence:** `all_orders_filter` is kind + author only — no `limit`, no `since`
  (`rust/src/nostr/order_events.rs:217-221`); used by the live subscription (`orders.rs:2785`)
  and full refetch (`orders.rs:2744`). Unbounded replay grows with node age and is uncapped
  against a misbehaving relay.
- **Fix:** add `.limit(N)` (e.g. 2000) to both; `.since(now − retention_window)` on the
  refetch path.
- **Verify:** subscription still yields the full pending book against the live node; unit
  test on filter construction.

### PR 1.7 — Surface stream lag instead of swallowing it `fix(observability)`
- **Evidence:** `OrdersStream::next` silently swallows `broadcast::error::RecvError::Lagged`
  (`orders.rs:3506-3508`); channel capacity is 16 (`orders.rs:186`) so a startup burst lags
  every subscriber invisibly. (The trade stream logs it — `orders.rs:3481`.)
- **Fix:** log `Lagged(n)` at warn; raise capacity to 64. (Semantics stay snapshot-safe;
  becomes correctness-critical before Phase 3 deltas land — this PR is a prerequisite there.)
- **Verify:** unit test forcing lag observes the log.

### PR 1.8 — `autoDispose` the derived order providers `fix(ui)`
- **Evidence:** `filteredOrdersProvider` and `orderReasonsProvider` are plain `Provider`s
  (`lib/features/home/providers/home_order_providers.dart:169`,
  `lib/features/home/providers/order_reason_provider.dart:73`) watching the `autoDispose`
  stream — they pin the whole book pipeline alive, so full map+filter+sort runs on every relay
  event even while the user sits in Chat/Settings.
- **Fix:** mark both `.autoDispose`.
- **Verify:** `flutter analyze && flutter test`; DevTools shows the providers dispose when
  leaving Home.

### PR 1.9 — Cheap render wins on the order card `perf(ui)`
- **Evidence:** four `NumberFormat(...)` constructions per card per build
  (`lib/features/home/widgets/order_list_item.dart:62`, `:238`, `:252`, `:281`);
  `_relativeTime` recomputed per build (`:284`); `OrderItem` has no `==`/`hashCode`
  (`home_order_providers.dart:19`) and rows get no `ValueKey`
  (`lib/features/home/screens/home_screen.dart:83-96`) → Flutter can never skip a subtree.
- **Fix:** static per-locale `NumberFormat` cache; precompute derived strings in `OrderItem`;
  add value equality and `key: ValueKey(order.id)`.
- **Verify:** `flutter test`; DevTools rebuild counter shows unchanged rows skipped.

### PR 1.10 — Fixed item extent on hot lists `perf(ui)`
- **Evidence:** no `itemExtent`/`prototypeItem` anywhere; order cards are fixed-height by
  design (skeleton hard-codes 172 px, `lib/shared/widgets/order_list_skeleton.dart:39`).
  Lists: `home_screen.dart:83` and `:98`, `trades_screen.dart:95`, `chat_room_screen.dart:334`.
- **Fix:** `prototypeItem:` (or `itemExtent:`) on the order list and trades list.
- **Verify:** golden/widget tests unchanged; scroll of a 3k-item fixture stays at 60 fps.

### PR 1.11 — Trivial Dart hygiene `chore(ui)`
- **Evidence:** themes rebuilt on every `MostroApp.build` (`lib/core/app.dart:53-54`);
  `escrowModeProvider` infinite loop without null/close guard, non-autoDispose
  (`lib/features/settings/providers/escrow_mode_provider.dart:16-24`); three un-stored
  `.listen()` subscriptions in `push_notification_service.dart:79-93`.
- **Fix:** hoist themes to `static final`; add the null-break guard (mirror
  `home_order_providers.dart:159-162`); store and guard the listeners.
- **Verify:** `flutter analyze && flutter test`.

---

## Phase 2 — Targeted fixes (medium effort, still independent)

Each PR stands alone; none requires Phase 3's redesign.

### PR 2.1 — Batch bulk ingest: one broadcast per refetch `fix(perf)`
- **Evidence:** `refetch_active_node_orders` loops `ingest_order_event` per event
  (`orders.rs:2745-2758`); each upsert clones + broadcasts the whole book → **O(N²)** on cold
  start, node switch (`orders.rs:2872`) and every pull-to-refresh (`orders.rs:2720`). With
  2000 orders: ~2M struct clones and ~2000 full-book bridge emissions.
- **Fix:** ingest the batch into the book without broadcasting, then emit **one** snapshot
  (`set_orders`-style) at the end.
- **Verify:** Rust test: N-event refetch produces exactly 1 broadcast; pull-to-refresh with a
  large fixture no longer stalls.
- **Impact:** the single biggest defect fix in the plan. Do this first in Phase 2.

### PR 2.2 — Coalesce live broadcasts (debounce) `perf(bridge)`
- **Evidence:** one relay event ⇒ one full-book clone ⇒ one bridge emission
  (`orders.rs:3111` → `:3216` → `:209-219`). No throttling/batching exists anywhere in the
  bridge path.
- **Fix:** coalesce mutations in a ~200 ms window and emit at most one snapshot per tick
  (skip when nothing changed). Keeps snapshot semantics — safe before deltas exist.
- **Verify:** Rust test: 100 upserts within the window ⇒ 1 emission carrying the final state.

### PR 2.3 — Negative cache for trade-key lookups `perf(ingest)`
- **Evidence:** `get_trade_key_index` at `orders.rs:3137` misses for every stranger's order →
  one SQLite/IndexedDB round trip per relay event (`lookup_trade_key_index`,
  `orders.rs:79-100`); `local_trade_status` (`orders.rs:2246`) adds a second read for
  non-pending events.
- **Fix:** cache negative results for content keys (bounded set, invalidated when a new trade
  key is derived); memoize `local_trade_status` per (order, status) within an ingest pass.
- **Verify:** Rust test: second ingest of the same stranger's order does zero DB reads.

### PR 2.4 — Prune terminal orders; bound the book `fix(memory)`
- **Evidence:** nothing evicts canceled/expired/success orders from the `Vec`
  (`orders.rs:174`; only user-cancel paths remove, `:1113`, `:1483`). Non-pending entries
  inflate every clone and bridge payload forever; Dart filters them out per emission
  (`home_order_providers.dart:177`).
- **Fix:** drop hard-terminal orders (reuse `is_hard_terminal`) and expired-pending on ingest;
  cap total book size defensively.
- **Verify:** Rust test: ingest terminal status ⇒ order leaves the book; long-session memory
  stays flat.

### PR 2.5 — Fix the connection-state resubscribe storm `fix(relay)`
- **Evidence:** `relay_pool.rs:211-214` broadcasts on **any** relay status change even when the
  derived state is unchanged (`Online → Online`); each event drives a 10 s `fetch_events`, an
  outbox flush and full resubscribes (`rust/src/api/nostr.rs:51-69`). One flapping relay at
  the 2 s poll interval (`relay_pool.rs:22`) reproduces this indefinitely.
- **Fix:** only send when the derived `ConnectionState` actually changed; debounce the
  Online handler.
- **Verify:** Rust test with a mock flapping relay: exactly one resubscribe cycle.

### PR 2.6 — Close relay-side subscriptions on task exit `fix(relay)`
- **Evidence:** `subscribe_daemon_messages` (`orders.rs:1203`) and `subscribe_single_order`
  (`orders.rs:2376`) open auto-ID relay subscriptions; the tasks exit after 30-min idle
  (`:1213`, `:2387`) but never `client.unsubscribe(...)`. Relays cap concurrent REQs
  (~10–20); overflow gets `CLOSED` (only logged, `orders.rs:3345-3357`) and can kill the
  order-book subscription itself.
- **Fix:** stable subscription IDs (`order-{id}`) + `unsubscribe` on task exit/timeout.
- **Verify:** Rust test asserting unsubscribe is issued; manual: relay REQ count stays bounded
  across many takes.

### PR 2.7 — Order-by-id index provider; kill O(N) scans in screens `perf(ui)`
- **Evidence:** `trade_detail_screen.dart:542-543` and `take_order_screen.dart:210` do
  `ref.watch(orderBookProvider)` + linear `where` scans of the whole book;
  `trade_state_header.dart:29-49` re-runs on every book emission and falls back to
  `getOrder()`+`listTrades()`.
- **Fix:** add `orderByIdProvider` (family) backed by a `Map<String, OrderItem>` index built
  once per emission; screens watch only their order.
- **Verify:** widget tests; DevTools: detail screens no longer rebuild on unrelated book
  events.

### PR 2.8 — Isolate the 1 Hz countdowns `perf(ui)`
- **Evidence:** `Timer.periodic(1 s) → setState` on the full 1332-line `TradeDetailScreen`
  (`trade_detail_screen.dart:161`) and on `take_order_screen.dart:92`; `_CountdownChip` never
  stops for non-expiring orders (`trade_state_header.dart:262-276`). Both screens also use
  eager `ListView(children:)` (`:571`, `:235`).
- **Fix:** move the ticking value into the existing leaf `CountdownTimer` widget /
  `ValueListenableBuilder`; cancel timers for non-expiring orders; keep the eager lists (they
  are short) but stop rebuilding them every second.
- **Verify:** DevTools: only the countdown leaf repaints per second.

### PR 2.9 — Notifications store: keyed records + single transaction `fix(storage)`
- **Evidence:** Sembast `intMapStoreFactory` with lookup-by-`Finder(Filter.equals('id',…))`
  per write (`lib/features/notifications/providers/notifications_provider.dart:80-89`, `:110`)
  → full-store scan per write; `markAllAsRead()` fires N independent saves → O(N²), N
  transactions, un-awaited (`:242-250`); state list grows forever (`:161`).
- **Fix:** `StoreRef<String, Map>` keyed by notification id; wrap `markAllAsRead` in one
  `db.transaction`; cap the retained list (mirror the log provider's 1000 cap,
  `log_provider.dart:9`).
- **Verify:** unit tests for upsert/markAll; time markAll on a 1k fixture.

### PR 2.10 — Chat-screen hot-path hygiene `perf(chat)`
- **Evidence:** `_messages.any(...)` O(N) dedupe per incoming message
  (`chat_room_screen.dart:145`), full sort at `:87`, `_markRead()` bridge call per message
  (`:148`), autoscroll animation per message (`:161`), unbounded `_messages` (`:48`).
- **Fix:** `Set<String>` of seen ids; debounce `_markRead`; autoscroll only when pinned to
  bottom; cap/paginate history.
- **Verify:** widget test replaying a 500-message burst stays responsive.

---

## Phase 3 — Structural: delta pipeline & push-based state (the big lever)

Ordered; 3.2 depends on 3.1, 3.3 on 3.2. Requires PR 1.7 (lag visibility) first.

### PR 3.1 — `feat(core): HashMap order book + delta broadcast type`
- **Evidence:** `Vec` + full-snapshot `broadcast::Sender<Vec<OrderInfo>>`
  (`orders.rs:172-186`); O(n) `find` per upsert (`:211`); a delta model already exists for
  trades (`TradeUpdate {order_id, status}`, `orders.rs:3472`) and is the pattern to copy.
- **Fix:** `HashMap<String, OrderInfo>` book; broadcast
  `enum OrderBookDelta { Upserted(OrderInfo), Removed(String), Snapshot }`. Internal only —
  the existing FRB stream keeps emitting snapshots (built from deltas) so nothing downstream
  changes yet. **Lagged now means "resync via `get_orders`"** — handle it explicitly.
- **Verify:** Rust unit tests for upsert/remove/lag-resync semantics.

### PR 3.2 — `feat(bridge): delta stream over FRB`
- **Fix:** new `on_order_deltas()` stream in `rust/src/api/orders.rs` emitting the delta enum;
  `get_orders()` stays as the initial-snapshot call. Run `./scripts/frb-generate.sh`. Keep the
  old snapshot stream one release for fallback, then remove.
- **Verify:** `--check` codegen clean; Dart integration test: initial snapshot + applied
  deltas ≡ Rust book state.

### PR 3.3 — `feat(ui): incremental order state in Dart`
- **Evidence:** full re-map per emission (`home_order_providers.dart:144-163`); full
  re-filter+re-sort (`:165-219`) including per-order `split(',')` set allocations
  (`:196-203`); Rust-side `OrderFilters` + filter/sort (`orders.rs:165-170`, `:235-278`) is
  **dead code** — every caller passes `filters: null`, and the two sides even sort differently
  (Rust: expiry asc; Dart: createdAt desc).
- **Fix:** `orderBookProvider` maintains `Map<String, OrderItem>` and applies deltas;
  `filteredOrdersProvider` updates incrementally (re-evaluate only the changed order except on
  filter changes); precompute the payment-method token set once per `OrderItem`. Decide one
  sort order and delete the dead Rust filter path (or wire it up — decide in review).
- **Verify:** provider unit tests; 3k-order fixture: one incoming event causes O(1) work.

### PR 3.4 — `feat(ui): replace per-trade polling with the push stream`
- **Evidence:** bottom nav (every screen) keeps N infinite 2 s `getOrder()` polls alive
  (`bottom_nav_bar.dart:33` → `trades_providers.dart:237-252` →
  `trade_state_provider.dart:17-52`); pay-invoice screen runs **two** full `listTrades()`
  reads per second (`trade_state_provider.dart:108`, `:130`). A push stream already exists
  (`on_trade_updated`, `orders.rs:3460`).
- **Fix:** derive `tradeStatusProvider`, the nav badge, and the invoice providers from
  `tradeUpdatesProvider`; keep one lazy `getOrder()` for initial value. Delete the polling
  loops.
- **Verify:** widget tests; bridge-call count during idle on Trades screen drops to ~0.

### PR 3.5 — `feat(core): chat room summaries in one call`
- **Evidence:** rooms hydration does 2 bridge calls per trade in an unbounded `Future.wait`,
  then filters full message history in Dart per room
  (`lib/features/chat/providers/chat_providers.dart:243-256`, `:206`, `:224`).
- **Fix:** Rust `list_chat_rooms()` returning `{trade_id, last_message, unread_count, nym}`
  per room in one bridge call. Regen bindings.
- **Verify:** Rust + widget tests; chat screen open with 100 trades = 1 bridge call.

### PR 3.6 — `fix(relay): bound the global DM filter & key derivation`
- **Evidence:** kind-14 `#p` filter carries one pubkey per lifetime trade and the whole REQ is
  re-sent to all relays on every newly derived key (`orders.rs:2934-2947`, `:2912-2922`);
  `build_trade_key_map` derives keys sequentially, awaiting each (`orders.rs:2981-2997`).
- **Fix:** cap coverage to keys of non-terminal trades (+ last K); debounce resubscribes;
  derive keys concurrently.
- **Verify:** Rust test: filter size bounded with 500 historical trades.

### PR 3.7 — `feat(ui): two-phase startup`
- **Evidence:** `runApp` is blocked by sequential awaits including relay-pool network init
  (`lib/core/app_bootstrap.dart:47-190`, esp. `nostr_api.initialize` at `:160`).
- **Fix:** first frame after `RustLib.init()` + prefs; relay init, identity and DB rehydrate
  move behind a post-first-frame loading state.
- **Verify:** cold-start trace: first frame well under the 2 s budget on a mid-range device.

---

## Phase 4 — Persistence & web parity (most work; depends on Phase 3 shape)

### PR 4.1 — `feat(db): persist the order book for instant cold start`
- **Evidence:** the book is memory-only on all platforms; a dead `orders` table + unused
  `save_order`/`list_orders` already exist (`rust/src/db/sqlite.rs:146-190`, zero callers).
  Every cold start refetches the entire book from relays (10 s timeout path,
  `orders.rs:2732`).
- **Fix:** persist deltas (batched, one transaction per coalesce tick from PR 2.2); on start,
  render from disk immediately and reconcile with the relay refetch. **Design note:** this
  intentionally revisits the "order book is sourced only from daemon events" rule — the relay
  stays the source of truth; disk is a cache. Needs a short design proposal before code
  (repo working agreement).
- **Verify:** cold start with 3k cached orders renders instantly offline; reconcile test.

### PR 4.2 — `feat(web): real IndexedDB backend` (issue #233)
- **Evidence:** `rust/src/db/indexeddb.rs` opens the DB per operation (`:55-72`), stubs
  trades/identity (`:140-239`), and `list_messages` full-scans + JSON-parses the entire store
  (`:157-167`).
- **Fix:** cache the DB handle; implement the trades store; index messages by `trade_id`;
  batch writes. Split into 2–3 PRs if large.
- **Verify:** web smoke test (`test/web/smoke/smoke.mjs`) + new wasm-target unit tests.

### PR 4.3 — `perf(ingest): parse events in one tag pass`
- **Evidence:** `parse_order_event` does a linear tag scan per field (~10 fields × ~15 tags,
  `rust/src/nostr/order_events.rs:27-33`, `:56-74`); rating tag JSON-parsed per event (`:88`).
- **Fix:** single pass over `event.tags` into a builder; parse rating JSON only when present.
- **Verify:** existing parser tests + a micro-benchmark (Phase 5 harness).

### PR 4.4 — `fix(memory): prune long-lived global stores`
- **Evidence:** `RATING_STORE` (`reputation.rs:34`), `TRADE_KEY_MAP` (`orders.rs:35`),
  `GLOBAL_DM_KEYS` (`orders.rs:2899`), `PENDING_REQUESTS` (`mostro/pending.rs:133`) grow for
  the process lifetime; `hydrate_mine_from_db` runs per `get_rating_for_trade` with no
  negative caching (`reputation.rs:137-161`, `:311`).
- **Fix:** bounded sizes / TTL eviction tied to terminal-trade cleanup; cache "not rated".
- **Verify:** long-session memory profile flat.

---

## Phase 5 — Scale validation & regression protection

### PR 5.1 — `test(bench): Rust benchmark harness + large fixtures`
- Criterion benches for: ingest of 5k-event batch, upsert into a 5k book, event parsing.
  Shared fixture generator for realistic 38383 events. No perf tests exist today anywhere.

### PR 5.2 — `test(ui): large-book widget & scroll tests`
- Widget tests driving `orderBookProvider` with 3k–10k orders; assert frame budget with
  `flutter test --profile` timeline / `flutter_driver` scroll test; provider unit tests
  asserting O(1) work per delta (locks in Phase 3).

### PR 5.3 — `ci: perf smoke gates`
- Wire 5.1 benches (threshold-based, not absolute) and the 5.2 timeline test into `ci.yml`;
  extend the web smoke test with a large-book scenario so wasm-boundary regressions surface.

---

## Suggested sequencing & expected effect

| Milestone | After | User-visible effect |
|---|---|---|
| M1 | Phase 1 | Log/DB/alloc overhead gone; smoother lists; fewer wasted rebuilds |
| M2 | PR 2.1 + 2.2 | Cold start / refresh / node-switch stalls eliminated (O(N²) → O(N)) |
| M3 | Phase 2 done | No resubscribe storms, no relay REQ leaks, chat/notifications snappy |
| M4 | Phase 3 done | Per-event cost O(1); idle bridge traffic ~0; scales to 10k+ orders |
| M5 | Phase 4 done | Instant cold start; web on par with native |
| M6 | Phase 5 done | Scale regressions blocked in CI |

**Review guidance per PR:** conventional commits, one concern per PR, branch
`perf/`-or-`fix/`+kebab, PR to `main` via gh + CodeRabbit. Rust PRs: `cargo test && cargo
clippy` (+ `./scripts/frb-generate.sh` when `rust/src/api/` changes). Dart PRs:
`flutter analyze && flutter test`. Web-touching PRs: run the web smoke test.
