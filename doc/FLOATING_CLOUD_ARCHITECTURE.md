# 行雲_繁-A (Floating Cloud IME) 架構設計與技術指南

## 1. 專案背景與定位

「**行雲_繁-A**」係以「全一_Extreme」架構為獨立基底，全面進行品牌識別革新、核心效能重構、物理鍵盤盲打容錯強化，以及現代 macOS 視覺質感重構之新世代注音輸入法。

- **工作目錄**：`/Users/taichi/AI/floating_cloud`
- **發布 Bundle**：`行雲_繁-A.app`
- **Bundle Identifier**：`com.vader.inputmethod.XingYun`
- **輸入模式識別**：`com.vader.inputmethod.XingYun.Bopomofo`
- **版本保護**：本專案為完全獨立之專案空間，不更動亦不污染「全一_Extreme」原始碼。未經指示不推送至任何既有遠端倉庫。

---

## 2. 品牌視覺設計 (Brand & Visual Identity)

- **主視覺代表色**：`#95D3CE` (RGB: 149, 211, 206 柔和薄荷青 / 雲水青)。
- **字型與排版**：中央白色微軟正黑體 (Microsoft JhengHei)「行雲」。
- **應用程式圖標 (AppIcon.icns)**：符合現代 macOS 1024x1024 Squircle 圓角曲率規範，柔和外發光與純淨薄荷青背景。
- **選單列狀態圖標 (Bopomofo.tiff)**：32x32 Retina 高對比微型圖標，清楚顯示「行雲」。
- **選單名稱與提示**：統一顯示為「`行雲_繁-A`」。
- **自動生成腳本**：`scripts/generate_xingyun_assets.swift`（支援全自動自給自足無依賴生成）。

---

## 3. 三大核心技術革新

### 3.1 鄰近鍵位盲打容錯引擎 (Fat-Finger Correction)
- **實作檔案**：`src/phoneticIME/Sources/FatFingerCorrector.swift`
- **問題痛點**：快速盲打注音時，手指經常偏擊相鄰鍵位（如欲按 `ㄍ` [e] 卻按成相鄰之 `ㄉ` [2]、`ㄖ` [r] 或 `ㄕ` [w]）。傳統注音輸入法直接中斷或跳出完全無關候選。
- **演算法機制**：
  1. 建立 QWERTY 大千式實體鍵盤之相鄰圖（同列左右相鄰給予最大權重）。
  2. 動態生成 1-距離變異體，並交由 `BopomofoCanonicalizer` 進行合法聲母、介音、韻母與聲調組合驗證。
  3. 優先確保合法拼音，並經由 `LexiconStore` 自動檢索。當使用者精確輸入無匹配候選時，自動補入相鄰鍵容錯推薦詞（標註高容錯權重補齊），大幅提升盲打打擊容錯率。

### 3.2 二進制預編譯詞庫 (Binary Mmap Zero-Copy Lexicon)
- **實作檔案**：
  - 編譯工具：`scripts/compile_lexicon_binary.swift`
  - 核心載入：`src/unifyIME/Sources/IME/Lexicon/LexiconStore.swift`
- **架構特點**：
  - 將 25 萬筆核心詞條與詞頻預編譯為二進制結構體陣列 `[Header (16B) | String Pool | Entry Array (16B)]`。
  - 啟動時透過 POSIX `mmap` (Memory-mapped File) 直接映射虛擬記憶體，達成零記憶體拷貝（Zero-copy）。
  - 冷啟動時間從傳統 TSV 解析的 120ms+ 驟降至 1~2ms 以內，記憶體開銷降至最低，按鍵即時反饋無卡頓。
  - 建置防呆：`src/unifyIME/build.sh` 具備自動感知機制，若二進制快取不存在會自動呼叫腳本編譯，原始碼倉庫無需收錄 38MB 二進制檔。

### 3.3 現代 macOS 毛玻璃介面與互動質感 (Liquid Glass UI)
- **實作檔案**：
  - 水平候選：`src/unifyIME/Sources/CandidateUI/HorizontalCandidateController.swift`
  - 垂直候選：`src/unifyIME/Sources/CandidateUI/VerticalCandidateController.swift`
- **視覺亮點**：
  - 全面導入 `NSVisualEffectView`（`.popover` 磨砂毛玻璃材質），與 macOS Sonoma / Sequoia 完美融為一體。
  - 視窗與選取項目採用 10pt 平滑連續圓角（Squircle curvature）。
  - 當前選中候選項採用品牌專屬薄荷青膠囊選取框（`#95D3CE` Accent Pill），文字自動呈現反白清晰對比，具備呼吸微投影質感。
  - 完美支援 Dark Mode / Light Mode 自適應切換。

---

## 4. 自動化建置與測試驗收

### 4.1 專案建置與部署指令
```bash
cd /Users/taichi/AI/floating_cloud

# 快速建置
./build.command

# 建置並直接部署到 ~/Library/Input Methods/
./build.command --deploy
```

### 4.2 自動化探針測試 (Probe Test Suite)
所有關鍵功能均配備指令列自動化探針測試：
- **注音正規化探針**：`bin/app/行雲_繁-A.app/Contents/MacOS/UnifyIME canonical-probe` (15/15 PASS)
- **盲打容錯探針**：`bin/app/行雲_繁-A.app/Contents/MacOS/UnifyIME fat-finger-probe` (3/3 PASS)
- **IMK 協定邊界探針**：`bin/app/行雲_繁-A.app/Contents/MacOS/UnifyIME imk-boundary-probe` (24/24 PASS)
- **符號與快捷鍵探針**：`bin/app/行雲_繁-A.app/Contents/MacOS/UnifyIME symbol-shortcut-probe` (17/17 PASS)

---

## 5. 後續 GitHub 遷移與維護備忘

本專案目錄為純淨之 Git 獨立儲存庫：
1. **絕不推送到既有之 UnifyIME 倉庫**。
2. 當使用者提供新 GitHub 倉庫 URL 時，只需執行：
   ```bash
   git remote add origin <NEW_GITHUB_REPO_URL>
   git push -u origin main
   ```
即可獨立維護與持續整合。
