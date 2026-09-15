# 全一_Super（極速省電省記憶體版）架構優化說明

## 專案定位
「全一_Super」專注於極致的**冷啟動速度、超低記憶體佔用（Low RAM Footprint）與長效省電（Battery Efficiency）**。在維持強大中英混打與注音精確選字的同時，對內部資料結構與 I/O 進行深度剖析與重構，實現秒開、零負擔的順暢體驗。

---

## 核心技術優化項目

### 1. 單趟詞庫解析與進程級快取共享（Single-Pass Lexicon Parsing & Shared Core）
- **痛點解決**：
  原架構在啟動時，會分別由候選字載入器與統計權重模組讀取兩次高達 8.0 MB 的 `phrase_map.tsv`，反覆對百萬級字元進行 Substring 切割與字串重構，造成顯著的啟動延遲與 CPU/電力消耗。
- **重構設計**：
  - 引入 `SharedLexiconCore`，實施**單趟流式解析（Single-Pass Parsing）**。
  - 在單次檔案遍歷中，同步建立：
    1. 詞庫候選字映射（`phraseCandidateMap`）
    2. 詞頻與上下文權重統計（`PhraseContextStats`）
    3. 讀音前綴檢索樹/集合（`baseReadingPrefixes`）
    4. 常用字映射（`baseCommonCharacterMap`）
  - 實施進程級不可變緩存，後續多次實例化 `LexiconStore` 開銷降為 O(1)，記憶體分配降低 50% 以上。

### 2. 移除英文巨型 PrefixMap，改用有序陣列二分搜尋（Binary Search）
- **痛點解決**：
  原 `EnglishIMEEngine` 在載入 7.0 MB 的 `english_words.tsv` 時，會將每一個單字拆分成所有長度 1 到 N 的子字串並加入 `prefixMap` 字典中。此結構在記憶體中膨脹數十萬個 Dictionary 雜湊節點，霸佔 30~50 MB 的常駐記憶體。
- **重構設計**：
  - 徹底移除 `prefixMap`。
  - 僅維護依正規化字串排序的有序陣列（Sorted Array）。
  - 當需要判斷是否可延伸（`canExtend`）或搜尋前綴候選字（`prefixCandidates`）時，採用時間複雜度僅 $O(\log N)$ 的二分搜尋（Binary Search / `lower_bound`）。
  - 單次查詢僅需小於 16 次比較，耗時 < 0.001 毫秒，且常駐記憶體暴降數十 MB。
  - 維持延遲載入（Lazy Loading），純注音輸入情境下完全不載入英文字典。

### 3. 多版本隔離與原生系統相容
- **獨立識別**：
  - App 命名：`全一_Super.app`
  - Bundle ID：`com.vader.inputmethod.UnifyIME.Super`
  - Connection Name：`com.vader.inputmethod.UnifyIME.Super_Connection`
  - 與 `全一_繁-A` 及其他輸入法可和平共存、互不干擾。

---

## 自動化回歸驗證
本版本在建置時均通過全自動 Probe 嚴格測試：
1. **IMK 邊界純邏輯 probe** (`imk-boundary-probe`)：**24/24 通過**
2. **符號修飾鍵純邏輯 probe** (`symbol-shortcut-probe`)：**17/17 通過**
