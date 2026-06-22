<!-- 生成: tameo-architecture-design workflow (wf_de9a232a-c69, 2026-06-22). 6サブシステムを最新macOS 26 APIでリサーチ+設計し統合。 -->

# ⚠️ レビュー補正（必読 — 2026-06-22 敵対的レビュー結果, approved=False）

下記の統合設計（原文）は実SDK照合で誤りを含む。**M1実装は本文の一部をそのまま使わず、以下の補正を優先すること。**

- **検知API名の幻覚**: 本文の `detectedPatterns(for:)` / `detectedMetadata(for:)` / `detectedValues(for:)`（過去形）と `DetectedValues` 型・`\.links` 等のkeypathは**存在しない**。実SDK(MacOSX26.5 NSPasteboard.h)の正名は `detectPatterns(for:)` / `detectMetadata(for:)` / `detectValues(for:)`。引数は `Set<NSPasteboard.DetectionPattern>`（`.probableWebURL`/`.emailAddress`/`.link`/`.number` 等）、戻りは一致パターン集合・メタデータ辞書。`detectValues` は**内容を読み警告を出す**。→ **M1では検知APIを一切使わない**（M3で正名で再導入）。
- 検知APIは**先頭アイテムのみ**対象。per-item列挙の中に入れない。
- **SwiftData**: 既存の未バージョン化ストアへ「非Optional・デフォルト無し」フィールド追加や VersionedSchema 後付けは移行失敗。→ M1は `@Model` 名 `ClipboardItem` を維持し、追加フィールドは**全てデフォルト値付き**。`#Index` / `@Attribute(.unique)` / `propertiesToFetch` / `fetchCount` は **macOS 14 床では使用不可** ＝ M1で不使用。
- **並行性**: M1は単一の `@MainActor HistoryStore(modelContext: container.mainContext)`。`@ModelActor` バックグラウンド版は不採用（M3+）。**SWIFT_VERSION 5.0 + 明示 `@MainActor` + `Timer`** の一本に統一（app-architecture草案の Swift6既定分離・Task.sleepループは混ぜない）。
- `modelContext.delete(model:)` は `throws` → 必ず `try?`。
- `MenuBarExtraAccess` はM1で追加しない（M2で実機検証のうえ）。
- **要実機検証**: `item.string(forType:)` の背景ポーリング読みが macOS 26 で警告を出さないこと（enforcement は既定OFF／opt-in だが要確認）。単一チョークポイント（ClipboardMonitor内の1箇所）に隔離済み。
- **正しいと確認済み**: `changeCount` は Int・読んでも無警告 / per-item `item.types` 読みは無警告で除外マーカー判定の正面 / `Sauce.shared.keyCode(for: .v)` / KeyboardShortcuts 3.0.1 を固定（3.0.0 は実機クラッシュ、`default:`→`initial:` 改名）。

以下は統合設計の原文（M3以降の参照用。上記補正が優先する）。

---

# Tameo — Architecture

> Status: living document. Covers the full M1–M6 roadmap; M1 is the slice built first.
> Tameo is a **clean-room** clipboard manager for macOS — a successor to Clipy. We read Clipy's public repo for *feature behavior* only; we copy no code.

---

## 1. Guiding constraints

These four rules drive every structural decision below.

1. **Privacy chokepoint.** On macOS 15.4+ and macOS 26, reading pasteboard *contents* (`string(forType:)` / `data(forType:)` / `readObjects`) without a user paste gesture raises a system privacy notification. Reading `NSPasteboard.changeCount` (an `Int`) and reading per-item `types` (type identifiers, not bytes) do **not** alert. Full enforcement is currently opt-in via the per-bundle default `EnablePasteboardPrivacyDeveloperPreview` and is OFF by default through macOS 26. Tameo therefore routes **every content read through exactly one method** so that, when Apple flips enforcement, there is a single place to gate or move it behind selection-time consent.
2. **Signature-bound accessibility grant.** The M2 synthesized-paste accessibility permission is keyed to the app's *code-signature identity*. Ad-hoc signing changes identity each rebuild and silently drops the grant (the `seligj95/stash` failure). The project must carry a stable `DEVELOPMENT_TEAM` (ATI Developer ID) from day one even though paste lands in M2. Not sandboxed (App Store sandbox forbids accessibility + CGEvent paste).
3. **Single background toucher.** One `@MainActor` `ClipboardMonitor` is the only object that touches `NSPasteboard.general` during background operation. Nothing else polls.
4. **Menu shows metadata, reads contents on demand.** The history list is driven by SwiftData `@Query`; full bytes are read only when the user selects an item (paste) — never during idle polling.

---

## 2. Concurrency model

- **Language mode: Swift 5 for M1** (matches the existing `project.yml`, lowest risk; Sauce and KeyboardShortcuts both import cleanly under Swift 5). Every service is nonetheless annotated **`@MainActor`** explicitly so the move to Swift 6 language mode (post-M1) is mechanical. Resolution of the inter-design split: we do *not* enable `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` in M1; we annotate by hand.
- **Everything that touches AppKit/SwiftData is on the main actor.** `NSPasteboard`, `NSWorkspace`, `ModelContext.mainContext`, `MenuBarExtra` content, and the `@Observable` services all live on `@MainActor`. The per-tick monitor work (one `changeCount` read + a per-item `types` scan + one optional text read + one SwiftData insert) is trivial, so pushing it off-main would only force actor hops back. **The monitor timer stays on the main actor — this is the race-safe *and* simpler choice.**
- **Timer, not async loop.** `Timer.scheduledTimer(withTimeInterval:repeats:)` on the main runloop. Its closure hops onto the actor via `MainActor.assumeIsolated`. Chosen over a `Task.sleep` loop because it is proven to fire while a `MenuBarExtra` menu is open and avoids Swift 6 data-race annotations on a detached task. Default cadence **0.4s** (Maccy parity; user-tunable 0.1–0.5s later).
- **SwiftData stays on the main context for M1.** A single `@MainActor` `ModelContext` is sufficient for M1 volumes. A background `@ModelActor` (`ClipboardStore`) is introduced when capture/dedup/prune volume warrants it (M3+). Model instances and `ModelContext` are never passed across actor boundaries (they are not `Sendable`).

---

## 3. Module / type layout

```
Tameo/
  TameoApp.swift              App entry: MenuBarExtra + Settings scenes; constructs services; starts monitor
  Models/
    ClipboardItem.swift       @Model: text record + forward-compat fields + mutable lastUsedAt sort key
    ClipKind.swift            String-backed kind enum (text now; rtf/image/url/color reserved)
  Services/
    ClipboardMonitor.swift    @MainActor @Observable: the ONLY background pasteboard toucher; changeCount poll
    HistoryStore.swift        @MainActor: insert/dedup/move-to-top/prune; owns the ONE content-read chokepoint seam
    PasteboardTypes.swift     nspasteboard.org marker constants (Concealed/Transient/AutoGenerated/source)
    PasteService.swift        M2 stub now: write-side copyToClipboard(); paste()/CGEvent deferred to M2
    AccessibilityAuthorization.swift  M2 stub now: AXIsProcessTrusted / prompt-once / openSettingsPane
    AppState.swift            @MainActor @Observable: ephemeral UI state (search, selection, popover presented); M2 hotkey owner
    Shortcuts.swift           M2 stub: KeyboardShortcuts.Name namespace
  Views/
    MenuBarContentView.swift  Popover root: search field + list + footer (Clear / Quit)
    HistoryListView.swift     Bounded @Query list, selection, rows
```

**Service ownership (constructed once in `TameoApp`, injected via `.environment`):**

- `ClipboardMonitor(store:)` — owns `lastChangeCount`, the `Timer`, `start()/stop()`. The single background toucher.
- `HistoryStore(modelContext:)` — owns insert/dedup/move-to-top/prune. Exposes `ingest(text:source:isConcealed:)` (capture seam) and `readTextForHistory(...)` (the **one** content-read chokepoint).
- `AppState` — ephemeral UI state only: `searchText`, `selectedItemID`, `isPopoverPresented`. **Never holds the history array** — that lives in SwiftData and surfaces through `@Query`. This split (Observable owns selection/search/presentation; @Query owns data) is what makes move-to-top and live re-sort automatic.
- `PasteService`, `AccessibilityAuthorization`, `Shortcuts`, `AppState`'s hotkey wiring — created as stubs in M1 so the wiring shape is final; bodies land in M2.

No DI framework — constructor injection + `.environment` is sufficient for a one-window app and avoids `Sendable` friction.

---

## 4. Data model

`ClipboardItem` (`@Model`, name kept from the existing repo to minimize churn to the existing `@Query` and container):

| field | type | role |
|---|---|---|
| `content` | `String` | text body (existing field, retained) |
| `createdAt` | `Date` | capture time (existing field, retained) |
| `lastUsedAt` | `Date` | **mutable** recency sort key; set to `.now` on paste → move-to-top (M2) |
| `kindRaw` | `String` (default `"text"`) | forward-compat kind; queried as String, exposed as `ClipKind` computed |
| `sourceBundleID` | `String?` | informational `org.nspasteboard.source` |
| `isConcealed` | `Bool` (default `false`) | forward-compat exclusion column (M5 broadens) |
| `byteSize` | `Int` | size accounting |

Notes:
- **Sort by `lastUsedAt` (reverse).** Move-to-top is just `item.lastUsedAt = .now`; `@Query` re-sorts automatically. This is why the sort key must be mutable and baked into M1 even though the behavior ships in M2.
- **No `#Index` macro in M1.** `#Index`/`#Unique`/`propertiesToFetch`/`fetchCount` require macOS 15. Confirmed stack pins macOS 14, so M1 omits them (acceptable at M1 history sizes; full table scan on a few hundred rows is negligible). Raising the floor to 15 to enable on-disk indexes is a documented open decision (§9).
- **Dedup is manual, never `@Attribute(.unique)` upsert.** On capture, fetch the most-recent item; if `content` matches, bump `lastUsedAt` (move-to-top) and return; else insert. This sidesteps the documented SwiftData unique-upsert crash history.
- **Detached-payload design (M3).** When non-text types arrive, large bytes move to a separate `@Relationship(deleteRule: .cascade) ClipPayload` child carrying `@Attribute(.externalStorage)` — never on the *listed* `ClipboardItem`, to avoid the confirmed eager-load regression where fetching a row materializes its external blob. M1 stores text inline (SwiftData stores long `String` inline, no external file) so M1 needs no `ClipPayload`.
- **Versioned schema from day one.** `TameoSchemaV1: VersionedSchema` + `TameoMigrationPlan: SchemaMigrationPlan` (empty stages) wired into `ModelContainer(for:migrationPlan:)` so M3/M5 additions are lightweight stages, not a forced custom migration. (Optional polish for M1 — see m1Steps; the migration plan can be deferred one milestone if we want the absolute-minimum M1, but wiring it now is cheap.)

---

## 5. End-to-end data flow: copy → detect → store → display → select → paste

```
[user copies in any app]
        │
        ▼
ClipboardMonitor.tick()  (Timer, 0.4s, @MainActor)
  1. let cc = pasteboard.changeCount          ← Int read, NO alert
  2. guard cc != lastChangeCount; lastChangeCount = cc   ← store synchronously
  3. for item in pasteboard.pasteboardItems:
       let types = Set(item.types)            ← per-item type IDs, NO alert
       if types ∩ {Concealed,Transient,AutoGenerated} ≠ ∅ → SKIP whole change
  4. (optional, macOS 15.4+ behind #available) detectedPatterns(for:) ← KINDS, NO content, NO alert
        │
        ▼
HistoryStore.ingest(...)  ← the ONE content read: item.string(forType: .string)
  • capture org.nspasteboard.source bundle id (informational)
  • dedup vs current top: if identical → bump lastUsedAt, return
  • else insert ClipboardItem(content, sourceBundleID, lastUsedAt=now, ...)
  • prune to maxHistory (default 200), delete oldest
        │
        ▼
SwiftData modelContext.save()
        │
        ▼
MenuBarContentView → HistoryListView
  @Query(sort: \.lastUsedAt, order: .reverse) [bounded fetchLimit later]
  renders item.content (truncated) — metadata only, no re-read of pasteboard
        │
        ▼  [M2: user selects an item / presses number key]
AppState.selectedItemID set
  → PasteService.copyToClipboard(item.content)   ← write side, NO alert
  → set AppState.isPopoverPresented = false        ← close popover FIRST
  → next runloop tick: reactivate previously-frontmost app
  → AccessibilityAuthorization.isTrusted ? else openSettingsPane()
  → CGEvent Cmd+V via Sauce.shared.keyCode(for: .v), post(.cgSessionEventTap)
  → HistoryStore.markUsed: item.lastUsedAt = .now  ← move-to-top
```

**Why close-before-paste matters:** the synthesized Cmd+V lands in whatever app is frontmost. Tameo must resign key and let the previously-frontmost app regain focus *before* posting, or the paste goes nowhere. The popover-close binding (MenuBarExtraAccess) is plumbed in M2 because `@Environment(\.dismiss)` does not close a `.window`-style `MenuBarExtra`.

---

## 6. Privacy-aware monitoring (the load-bearing detail)

- **Change detection:** poll `NSPasteboard.general.changeCount`. There is no notification/KVO for the pasteboard; polling is mandatory. `changeCount` is documented purely as an ownership counter — reading it never alerts.
- **Kind detection without content:** iterate `pasteboard.pasteboardItems` and read **per-item** `item.types`. Read per-item, never the aggregate `pasteboard.types` (the aggregate reports every available type even ones absent on a given item — the Concealed marker lives on the item; the aggregate misclassifies; this exact bug bit Maccy).
- **Exclusion markers (skip recording):** `org.nspasteboard.ConcealedType` (password managers), `org.nspasteboard.TransientType`, `org.nspasteboard.AutoGeneratedType`. `org.nspasteboard.source` is *informational*, not an exclusion flag.
- **The one M1 content read:** to have a text clipboard manager at all, M1 must read the string. This is isolated behind `HistoryStore.readTextForHistory(...)` with a prominent comment. It is unalerted today (enforcement opt-in/off through macOS 26). When Apple flips enforcement, this single method is where we gate it or move it behind selection-time consent.
- **macOS 15.4+ detection APIs (optional in M1, load-bearing in M3):** `detectedPatterns(for:)` / `detectedMetadata(for:)` are `async throws`, guarded `if #available(macOS 15.4, *)`, and enrich kind-flags with no content read. Never use `detectedValues(for:)` in the monitor — it reads content and alerts.
- **`accessBehavior` (15.4+):** surface in diagnostics only (M5/M6) so that if the OS ever flips Tameo to `.ask`, we can guide the user to "always allow" in System Settings.

---

## 7. UI shell

- `MenuBarExtra("Tameo", systemImage:)` with **`.menuBarExtraStyle(.window)`** — `.menu` (NSMenu) cannot host a search field, thumbnails, or color swatches, so it is a non-starter for a clipboard manager.
- `LSUIElement=YES` (already set via `INFOPLIST_KEY_LSUIElement`) — menu-bar resident, no Dock icon.
- History list uses SwiftUI `List(selection:)` (NSTableView-backed, recycles rows) — never `LazyVStack`-in-`ScrollView` (which never releases created views and degrades badly at thousands of clips). M1's existing `ForEach` is acceptable at M1 sizes; the `List(selection:)` upgrade comes with selection/number-key support in M2.
- **M2 adds MenuBarExtraAccess** (`github.com/orchetect/MenuBarExtraAccess`, MIT) for the programmatic `isPresented` close binding + `NSStatusItem` access + `introspectMenuBarExtraWindow` (needed for the close-before-paste sequence and the macOS 26 Tahoe focus fix: `NSApp.activate(ignoringOtherApps:)` + `window.makeKey()` + `@FocusState`).

---

## 8. Milestone → architecture mapping

| Milestone | What lands | Touches |
|---|---|---|
| **M1 foundation** | privacy-aware monitoring → text history → menu-bar list | `ClipboardMonitor`, `HistoryStore`, `PasteboardTypes`, `ClipboardItem` (extended), `MenuBarContentView`/`HistoryListView`. PasteService/AppState/Shortcuts as stubs. No SPM deps exercised. |
| **M2 usable** | global hotkey opens history; paste selected into frontmost app (CGEvent Cmd+V via Sauce + accessibility); number-key quick-select; move-to-top | Activate Sauce + KeyboardShortcuts + MenuBarExtraAccess deps. `PasteService.paste()`, `AccessibilityAuthorization`, `AppState` hotkey + `Shortcuts.Name`, close-before-paste, `HistoryStore.markUsed`. |
| **M3 types** | RTF/RTFD/PDF/image/filename/URL/color; per-type toggles; thumbnails + swatches | `ClipPayload` cascade child + `@Attribute(.externalStorage)`; `kindRaw` populated; `detectedPatterns`/`detectedMetadata` become load-bearing; lightweight migration stage. |
| **M4 snippets** | folders + snippets CRUD, editor window, per-folder hotkeys, XML import/export | New snippet models; dynamic `KeyboardShortcuts.Name("snippetFolder-…")` registry (sanitize dots). |
| **M5 exclusions** | per-app (bundle id) exclusion + concealed-data exclusion | `isConcealed` column already present; per-app exclusion list; `accessBehavior` diagnostics. |
| **M6 settings** | General/Menu/Shortcuts/ExcludeApp/Type panels; menu customization | `Settings` scene panels; `KeyboardShortcuts.Recorder`; poll-interval/maxHistory settings; SMAppService launch-at-login. |

---

## 9. Open decisions carried in the architecture

- **macOS floor 14 vs 15.** Confirmed stack says 14 (no `#Index`). Raising to 15 unlocks on-disk indexes/`fetchCount`/partial fetch — worth it before scale; revisit at M3.
- **Swift 5 → Swift 6 language mode.** Stay on 5 through M1 (explicit `@MainActor` everywhere); flip to 6 while the codebase is small.
- **Default global hotkey.** ⌘⇧V proposed; lock before M2 seeds it (don't pass `initial:` — seed once behind a UserDefaults flag so a user-cleared binding stays cleared).
- **Poll cadence / maxHistory.** 0.4s / 200 defaults; expose as settings in M6.
- **MenuBarExtra `.window` vs NSStatusItem+NSPanel for the hotkey-opened palette.** Decide at M2 start; isolate the popover behind a thin seam now.
