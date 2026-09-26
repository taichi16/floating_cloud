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

為了提供使用者一個「**如行雲流水般輕快、安裝與解除安裝生命週期清晰受控**」的良好體驗，我們將核心獨立分流並進行全面深度重構，正式立項為全新的獨立專案 —— **「行雲_繁-A」（floating_cloud）**。

---

## 重大修改歷程 (Changelog & Architecture Evolution)

### 0. v1.2.2 版本更新說明（長句處理、追蹤檔限制與安裝穩定性）
- **長句增量分詞**：重用前綴分詞結果並在可安全停止處沿用後續列，減少逐鍵輸入長句時重算整段內容。候選 Release App 的增量差異探針 248/248 與原始按鍵回歸 406/406 通過；此版本未重新量測原生輸入的 p95 延遲，不宣稱達成 p95 門檻。
- **追蹤檔大小限制**：單筆 trace 最多 256 KiB；trace 檔上限 10 MiB，輪替保留最多三份舊檔，避免長時間記錄無上限成長。
- **安裝／更新錯誤處理**：加強安裝來源與可執行檔檢查、部署失敗回復及 TIS readiness 確認；避免以廣泛終止共用輸入服務的方式刷新狀態。
- **實際安裝驗收範圍**：此候選包在一台開發機依「反安裝 → DMG 安裝 → 重開機」操作後，系統設定只顯示一筆行雲，TIS／輸入法偏好亦各一筆。LaunchServices 仍可見 Trash 舊路徑記錄，其觸發原因及與歷史重複列的關係尚未證明；此單機結果不代表跨帳號或其他 macOS 版本均已驗收。

### 0. v1.2.1 版本更新說明（候選字修正、Ranker 效能優化與啟動預熱）
- **候選字修正**：修復輸入「才剛踏進家門」時「踏」出現非預期候選字「大」的問題，移除不當硬式覆寫，使單字 `ㄊㄚˋ` 第一候選正確回歸「踏」，整句分詞正確。
- **Ranker 效能優化（消除越打越慢問題）**：重構 `HeuristicCandidateRanker`，將原先每次按鍵在各個 candidate span 實例化 88 維特徵向量編碼以讀取純漢字旗標的做法，替換為輕量級 `isPureHan` UnicodeScalar 檢查，維持排序邏輯完全一致的同時大幅降低每鍵計算開銷與打字延遲。
- **冷啟動預熱機制**：在背景啟動執行緒引入 `EnglishIMEEngine` 與 `UserFrequencyStore` 預熱機制，預載入英文詞庫與使用者詞頻快照，徹底消除首次中英混合輸入時的卡頓。
- **LaunchServices 註銷順序強化**：在 `打包DMG.command` 與 `反安裝行雲_繁-A.command` 中嚴格落實「先調用 `lsregister -u` 註銷路徑，再執行 `rm -rf` 刪除本體目錄」，避免系統資料庫因實體目錄已不存在而殘留幽靈記錄。

### 1. v1.2.0 版本更新說明（穩定性、解除安裝防護與系統邊界說明）
- **TIS 啟用防禦（降低重複調用風險）**：`InputSourceHelper` 與安裝腳本在調用 `TISEnableInputSource` 前先檢查啟用狀態，避免重複呼叫，降低狀態回傳不一致或輸入法選單短暫變動的風險。
- **解除安裝前切換輸入來源**：移除腳本執行初期若偵測到當前輸入來源為「行雲_繁-A」，會自動嘗試切換至系統其他可用輸入法（如 ABC），降低使用中解除安裝失敗的機率。
- **系統偏好設定精確比對與移除確認**：改採確切 Bundle ID（`com.vader.inputmethod.XingYunIME`）比對，避免模糊比對；移除腳本加入互動確認提示，降低誤觸風險。
- **詳實客觀的系統安全邊界指引**：新增 [《安裝與解除安裝操作指南》](doc/INSTALL_AND_UNINSTALL_GUIDE.md)，客觀說明在部分 macOS 版本與系統狀態下，直接修改偏好檔可能不會立即反映於「系統設定」介面，指引使用者透過 macOS 介面手動按「—」號完成最後移除。
- **DMG 封裝說明更新**：打包腳本產出之磁碟映像檔隨附最新操作說明，提供清晰客觀的操作與清理須知。

### 1. 關於輸入來源註冊與系統偏好狀態說明
本專案已移除早期更新流程中的垃圾桶 App 備份，並針對 TIS 輸入來源、LaunchServices 註冊及 Bundle Identifier 殘留風險進行整理，以降低重複輸入來源與系統狀態不一致的機率。

安裝與反安裝流程仍需維護部分 macOS 輸入來源偏好狀態；不同 macOS 版本的系統快取與同步行為可能不同。除自動化測試外，正式發布仍應透過實際系統設定及文字 App 進行驗收。

> 完整系統狀態架構、驗證邊界與 12 項驗收標準請參閱：[《行雲_繁-A 安裝、輸入來源註冊與系統狀態說明》](doc/SYSTEM_STATE_AND_INSTALLATION.md) 與 [《安裝與解除安裝操作指南》](doc/INSTALL_AND_UNINSTALL_GUIDE.md)

### 2. 單一模式架構重構（Parent / Child 模式分離）
- **根治輸入法項目重複雙胞胎**：
  在過往架構中，輸入法 App 本身與內部的 InputMode 容易被系統同時列出，造成選單列或系統設定中出現兩個同名項。
  - 頂層 Parent App 命名為 `XingYun`（顯示名為「行雲」），移除直接選取標記，作為純淨宿主容器。
  - 內部唯一的子輸入模式命名為 `com.vader.inputmethod.XingYunIME.Bopomofo`，顯示名稱為「**行雲_繁-A**」，專注提供唯一的繁體注音輸入。

### 3. 專屬安全安裝與卸載機制 (macOS 13+ ~ 15+ Sequoia 完全相容)
- **智慧精準啟用（解決系統設定「點擊完成卻未顯示」之問題）**：
  現代 macOS 系統設定介面常因只寫入第三方程式清單而延遲寫入 `AppleEnabledInputSources`，造成使用者在設定介面按「完成」後選單列依然找不到該輸入法。`安裝行雲_繁-A.command` 透過標準 CoreFoundation / TIS API 於部署時代碼簽名並精準啟用，使用者一鍵執行即可直接在右上角選單列現身使用。
- **安全解除安裝機制與系統防護邊界**：
  `反安裝行雲_繁-A.command` 在執行時會先主動嘗試將作用中輸入法切換至其他輸入來源（如 ABC），結束常駐背景程序並從 LaunchServices 註銷 App 記錄，隨後移除應用程式本體檔案（`~/Library/Input Methods/行雲_繁-A.app`）。同時嚴格遵循 macOS 系統邊界，不使用破壞性全域指令。詳細系統機制與手動清理說明請見 [《安裝與解除安裝操作指南》](doc/INSTALL_AND_UNINSTALL_GUIDE.md)。

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
* 🔒 **安全受控**：安裝與反安裝流程明確，生命週期完整受控，絕不破壞其他輸入法設定。
* 💎 **現代相容**：深度調校並完美適配 macOS 13 Ventura、14 Sonoma、15 Sequoia 及後續最新架構。
* 📦 **中英混打與智慧選字**：傳承自 UnifyIME 優秀的詞庫架構與中英混合輸入辨識能力，輸入長句暢快自然。
* 🛡 **隱私至上**：所有輸入與組字完全在本地端完成，無需連網，捍衛個人資料安全。

---

## 安裝與建置說明

### 快速安裝 (使用者推薦)
1. 從發布頁面下載或自行產出 `行雲_繁-A_安裝磁碟.dmg`。
2. 開啟 DMG 磁碟映像檔。
3. 雙擊執行「**安裝行雲_繁-A.command**」，系統將自動完成部署、簽名與選單列啟用。

### 解除安裝 (移除)
1. 雙擊執行「**反安裝行雲_繁-A.command**」：
   - 程式將結束常駐背景程序、自 LaunchServices 註銷索引、停用 TIS 輸入來源，並移除應用程式本體檔案（`~/Library/Input Methods/行雲_繁-A.app`）。
2. **macOS 系統設定「文字輸入方式」面板之手動清理說明**：
   - **系統偏好保護與快取**：在部分 macOS 版本與系統狀態下，直接透過腳本修改相關偏好檔可能不會立即反映於「系統設定」介面；因此建議使用者透過 macOS「系統設定」>「鍵盤」>「文字輸入方式」介面手動完成最後移除。
   - **手動清理步驟**：若執行移除腳本後，macOS「系統設定」>「鍵盤」>「文字輸入方式」（編輯）列表中仍顯示「行雲_繁-A」歷史圖示，只需**點選該項目並按左下角的「—」（減號）**即可移除。移除清單項目後，若 App 本體及相關輸入法套件已刪除，通常不會再被 macOS 列為可用輸入來源；若仍出現，請嘗試重新啟動系統設定或重新登入系統以重新整理輸入來源清單。

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
