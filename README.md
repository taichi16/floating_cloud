# 行雲_繁-A (Floating Cloud IME)

專為 macOS 打造的高效、純淨、極致靈動的繁體中文注音輸入法。

![macOS Version](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)
[![Release](https://img.shields.io/github/v/release/taichi16/floating_cloud?color=brightgreen&label=下載最新%20DMG)](https://github.com/taichi16/floating_cloud/releases/latest)

> 💡 **一般使用者快速安裝**：
> 請至右側 👉 [**Releases 頁面**](https://github.com/taichi16/floating_cloud/releases/latest) 下載 **`行雲_繁-A_安裝磁碟.dmg`**，打開後雙擊「**安裝行雲_繁-A.command**」即可一鍵完成安裝！

---

## 專案緣起與更新來源

「**行雲_繁-A**」（Floating Cloud IME）源自 **UnifyIME / UnifyIME_Extreme** 專案的現代 Swift / C++ 混合架構。

原專案雖具備強大的中英混打與多模型架構，但隨著長期演進，其安裝流程、偏好設定寫入機制與歷史殘留邏輯，在現代 macOS（macOS 13 Ventura、14 Sonoma、15 Sequoia 及後續版本）上面臨了系統層級的嚴峻挑戰（包括 LaunchServices 幽靈項目索引、選單列顯示衝突、反安裝不完全等問題）。

為了提供使用者一個「**如行雲流水般輕快、安裝反安裝 100% 純淨無殘留**」的極致體驗，我們將核心獨立分流並進行全面深度重構，正式立項為全新的獨立專案 —— **「行雲_繁-A」（floating_cloud）**。

---

## 重大修改歷程 (Changelog & Architecture Evolution)

### 1. 徹底根除「幽靈重複項目」與系統偏好污染
- **消除垃圾桶備份導致的幽靈索引**：
  查明舊版安裝腳本習慣在更新時將舊 App 移至 `~/.Trash` 的歷史慣性。macOS LaunchServices 背景常駐程序會主動掃描垃圾桶內的合規 App，導致系統設定的鍵盤選單中累積多達數十個幽靈重複項目。新版安裝與卸載程式全面改為原生原地銷毀（`rm -rf`），杜絕垃圾桶產生幽靈備份。
- **全面廢除私有 API 篡改偏好設定**：
  徹底拔除過往私自調用非公開 API 直接強寫 `com.apple.HIToolbox.plist` 與 `com.apple.inputsources.plist` 的高風險「黑魔法」，回歸與 Apple 官方標準、知名開源專案（如 vChewing 唯音、McBopomofo 小麥注音）相同規格的標準系統 Input Method Kit 體系。

### 2. 單一模式架構重構（Parent / Child 模式分離）
- **根治輸入法項目重複雙胞胎**：
  在過往架構中，輸入法 App 本身與內部的 InputMode 容易被系統同時列出，造成選單列或系統設定中出現兩個同名項。
  - 頂層 Parent App 命名為 `XingYun`（顯示名為「行雲」），移除直接選取標記，作為純淨宿主容器。
  - 內部唯一的子輸入模式命名為 `com.vader.inputmethod.XingYunIME.Bopomofo`，顯示名稱為「**行雲_繁-A**」，專注提供唯一的繁體注音輸入。

### 3. 專屬安全安裝與卸載機制 (macOS 13+ ~ 15+ Sequoia 完全相容)
- **智慧精準啟用（解決系統設定「點擊完成卻未顯示」之問題）**：
  現代 macOS 系統設定介面常因只寫入第三方程式清單而延遲寫入 `AppleEnabledInputSources`，造成使用者在設定介面按「完成」後選單列依然找不到該輸入法。`安裝行雲_繁-A.command` 透過標準 CoreFoundation / TIS API 於部署時代碼簽名並精準啟用，使用者一鍵執行即可直接在右上角選單列現身使用。
- **100% 純淨安全反安裝**：
  `反安裝行雲_繁-A.command` 僅精準自系統偏好清單中剔除「行雲_繁-A」，**100% 絕不使用破壞性全域指令，絕不影響使用者的 ABC、唯音、小麥注音等其他現存輸入法**，隨後徹底註銷 LaunchServices 並刪除實體檔案，達成零幽靈、零殘留。

### 4. 視覺質感與選單圖標翻新
- **薄荷青（Mint Green）專屬識別**：
  全面更換預設視覺標識，採用清新通透的薄荷青主題，為選單列與候選視窗注入現代極簡美學。
- **Retina 最佳化向量渲染**：
  支援淺色、深色模式無縫切換，字體邊緣細緻平滑，視覺體驗高度契合 macOS 原生質感。

### 5. 一鍵式高壓縮 DMG 發布流程與專屬外觀圖標
- 提供自動化腳本 `打包DMG.command`，採用 UDZO 高壓縮格式，自動將編譯產物、一鍵安裝與一鍵反安裝程式封裝為發布映像檔。
- 支援磁碟 Volume 與 .dmg 檔案本身的自訂外觀圖標套用，呈現精緻圓角祥雲 LOGO。

### 6. Shift 首字母大寫中英混輸智慧識別
- **根治大寫首字母提前切斷問題**：
  徹底修復舊邏輯在按 `Shift + 字母` 時將大寫字母當作單獨字元提前 commit 上屏的缺陷。過往由於首字母被切斷，後續小寫輸入（如 `udget`）無法命中字典而退回注音解析噴出注音亂碼（如 `Bㄧㄎ尸ㄍ彳`、`A凹凹\`）。
- **全流程大小寫風格保留**：
  大寫字母完整納入組字緩衝區，後續小寫輸入連續組合成完整單字（如 `Budget`、`Marketing`、`Product`）。英文引擎以大小寫不敏感比對字典，並以原始輸入風格呈現與上屏。

### 7. 免編譯個人自訂詞庫熱載入（Hot-Reloadable User Lexicon）
- **專屬目錄**：`~/Library/Application Support/行雲_繁-A/CustomLexicon/`
- **雙純文字檔支援**：
  - `custom_words.txt`：自訂英文單字、商務縮寫或專有名詞（如 `KPIs`、`Paid`、`Over-budget`）。
  - `custom_phrases.txt`：自訂中文詞彙（格式如 `ㄒㄧㄥˊ ㄩㄣˊ 行雲`）。
- **存檔即刻生效**：
  輸入法背景自動監聽檔案修改時間，使用者隨時用文字編輯器存檔，輸入法自動熱載入快取，**完全免重新編譯、免重啟輸入法，存檔立即可用**！

---

## 專案特色

* 🚀 **輕靈迅捷**：原生 Swift 6 與高優化組字狀態機，敲擊按鍵毫秒級即時響應。
* 🔒 **極致純淨**：生命週期完整受控，安裝／反安裝來去無痕，絕不破壞其他輸入法設定。
* 💎 **現代相容**：深度調校並完美適配 macOS 13 Ventura、14 Sonoma、15 Sequoia 及後續最新架構。
* 📦 **中英混打與智慧選字**：傳承自 UnifyIME 優秀的詞庫架構與中英混合輸入辨識能力，輸入長句暢快自然。
* 🛡 **隱私至上**：所有輸入與組字完全在本地端完成，無需連網，捍衛個人資料安全。

---

## 安裝與建置說明

### 快速安裝 (使用者推薦)
1. 從發布頁面下載或自行產出 `行雲_繁-A_安裝磁碟.dmg`。
2. 開啟 DMG 磁碟映像檔。
3. 雙擊執行「**安裝行雲_繁-A.command**」，系統將自動完成部署、簽名與選單列啟用。

### 反安裝 (完全卸載)
- 雙擊執行「**反安裝行雲_繁-A.command**」，系統將自動安全清理相關登記並徹底移除應用程式。

### 從原始碼編譯
需先安裝 macOS 與 Xcode Command Line Tools：
```sh
# 編譯發布版本
zsh build.command --release

# 一鍵打包為 DMG 安裝磁碟
./打包DMG.command
```
產物將存放於 `dist/行雲_繁-A_安裝磁碟.dmg`。

---

## 授權與致謝

本專案在底層架構、詞庫與組字演算法上借鑑了以下開源社群的珍貴遺產：
- [UnifyIME](https://github.com/VaderChen/UnifyIME)
- [小麥注音（McBopomofo）](https://github.com/openvanilla/McBopomofo)
- [唯音輸入法（vChewing）](https://github.com/vChewing/vChewing-macOS)

本專案程式碼依 MIT License 授權開放。
