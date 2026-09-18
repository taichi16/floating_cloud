# 行雲_繁-A 安裝、輸入來源註冊與系統狀態說明

文件版本：草案 1.0  
適用專案：行雲_繁-A（Floating Cloud IME）  
文件性質：技術與使用者說明  
更新日期：2026-09-18

---

## 1. 文件目的

本文件說明行雲_繁-A 在 macOS 上的安裝、更新、反安裝、輸入來源註冊及系統狀態處理方式。

文件同時區分：

- 已由程式碼確認的行為
- 專案歷史中的修正方向
- 根據系統行為所作的技術推論
- 尚未透過實際 macOS 環境驗證的事項

本文件不將靜態程式碼分析或歷史 commit 訊息視為完整的實機驗收證明。

## 2. 專案背景

行雲_繁-A 源自 UnifyIME／UnifyIME_Extreme 的輸入法架構，後續針對以下項目進行整理與調整：

- 中英混合輸入
- 注音組字與候選選字
- InputMethodKit 整合
- TIS 輸入來源註冊
- LaunchServices 登錄
- 安裝與反安裝流程
- 候選視窗及偏好設定介面

專案演進期間曾處理輸入來源重複註冊、Bundle Identifier 變更、TIS 狀態不一致及系統快取未即時更新等風險。

## 3. 舊版安裝流程與垃圾桶備份

專案歷史中的部分安裝或更新流程曾將舊版 App 移至使用者的 `~/.Trash`，再安裝新版本。

此作法可能造成以下風險：

- LaunchServices 仍掃描垃圾桶中的 App。
- 舊 App 的 Bundle Identifier 或輸入來源註冊仍可能被系統保留。
- 系統設定中的輸入來源清單可能出現重複或過期項目。
- 多次更新後，可能需要額外清理系統註冊與快取。

後續版本已將主要清理方式改為直接刪除目標 App，例如：

```zsh
rm -rf "$TARGET"
```

這可避免安裝流程額外產生垃圾桶中的 App 副本，降低新的 LaunchServices 重複索引風險。

但是，直接刪除新 App 並不等於自動清除所有既有的：

- LaunchServices 註冊
- TIS 輸入來源狀態
- HIToolbox 偏好
- 系統設定快取
- 其他歷史版本留下的輸入來源資料

因此，「不再產生垃圾桶備份」與「所有既有幽靈項目已清除」是不同的事項。

## 4. 輸入來源註冊機制

安裝流程主要使用 macOS 公開的 Carbon TIS API 與 LaunchServices 工具，包括：

- `TISRegisterInputSource`
- `TISEnableInputSource`
- `TISSelectInputSource`
- `lsregister`

基本流程如下：

1. 複製 App 至目前使用者的輸入法目錄。
2. 對 App 執行必要的簽章或驗證。
3. 向 LaunchServices 註冊 App。
4. 取得 Parent Input Source 與 Input Mode。
5. 啟用主要輸入模式。
6. 選取主要輸入模式。
7. 重新載入相關輸入法服務。

需要注意，單一 API 呼叫成功不代表整個系統狀態已完成同步：

- `TISRegisterInputSource` 成功，不代表系統設定一定立即顯示。
- `TISEnableInputSource` 成功，不代表偏好資料一定已完整落地。
- `TISSelectInputSource` 成功，不代表所有前景 App 已建立新的輸入 session。
- `lsregister` 能找到 App，不代表 App 一定可在輸入來源選單中使用。

因此，安裝完成後仍需透過實際系統選單與文字 App 驗證。

## 5. 系統偏好設定處理

部分安裝與反安裝流程會維護 macOS 輸入來源相關狀態，例如：

```text
com.apple.HIToolbox
com.apple.inputsources
AppleEnabledInputSources
AppleSelectedInputSources
AppleInputSourceHistory
AppleEnabledThirdPartyInputSources
```

相關程式使用 Apple 公開的 Core Foundation 或 Carbon API；但上述偏好鍵屬於 macOS 輸入法系統所使用的內部狀態，Apple 未保證不同 macOS 版本之格式與行為完全一致。

因此，本專案不宣稱：

- 完全不修改系統輸入法偏好。
- 所有 macOS 版本都使用相同的偏好同步行為。
- 反安裝後必定不存在任何歷史註冊或快取殘留。

較準確的描述是：

> 本專案會以目前可用的 TIS 與 CFPreferences 機制，針對本專案的輸入來源項目進行處理，並盡量保留其他輸入法設定。不同 macOS 版本的系統快取與偏好同步結果仍需實際驗證。

## 6. 反安裝範圍

反安裝流程的處理目標包括：

- 停用本專案的 TIS 輸入來源。
- 移除本專案相關的輸入來源偏好項目。
- 取消本專案 App 的 LaunchServices 註冊。
- 刪除本專案安裝目錄中的 App。
- 重新整理輸入法相關服務。

反安裝不應以其他輸入法的 App 或 Bundle Identifier 為刪除目標。

為使系統重新載入狀態，流程可能需要重啟下列共用服務：

- `UnifyIME`
- `TextInputMenuAgent`
- `TextInputSwitcher`
- `cfprefsd`

這些服務並非本專案獨有，因此重啟期間可能暫時影響輸入法選單或偏好同步。

較準確的說法是：

> 反安裝會以本專案的 Bundle Identifier、Input Source ID 及相關偏好項目為主要清理範圍，不會以其他輸入法的 App 為刪除目標；但可能重啟共用的 macOS 輸入法與偏好服務。

## 7. 幽靈項目與系統殘留的驗證界線

所謂「幽靈項目」可能出現在不同層次：

- App 實體檔案仍存在。
- LaunchServices 仍保留 App 註冊。
- TIS 清單仍保留 Parent 或 Input Mode。
- HIToolbox 偏好仍保留歷史項目。
- 系統設定介面尚未刷新。
- 前景 App 尚未建立新的 InputMethodKit session。

因此，以下結果不能單獨證明所有項目已清除：

- `rm -rf` 成功。
- `lsregister -u` 成功。
- `TISDisableInputSource` 成功。
- `CFPreferencesSynchronize` 成功。
- 系統設定暫時看不到該輸入法。

完整驗證至少應包含：

1. 系統設定輸入來源清單。
2. 選單列目前輸入法。
3. TIS 輸入來源狀態。
4. LaunchServices 登錄狀態。
5. 重新登入或重啟相關服務後的結果。
6. TextEdit、CotEditor 或其他實際文字 App 的輸入結果。

## 8. 已確認、推論與未知事項

### 已確認

- 目前流程使用 TIS 與 LaunchServices 相關 API。
- 目前主要清理流程使用直接刪除，而非將 App 移入垃圾桶。
- 專案歷史曾處理輸入來源重複註冊與 Bundle ID 殘留風險。
- 部分流程會維護 macOS 輸入來源相關偏好狀態。
- 安裝、反安裝及重載流程可能重啟共用系統服務。

### 技術推論

- 垃圾桶中的 App 可能增加 LaunchServices 重複索引的機會。
- Bundle Identifier 或 Input Source ID 變更可能留下歷史註冊狀態。
- 不同 macOS 版本的 TIS、HIToolbox 與系統設定同步行為可能不同。
- 只執行 CLI 或純邏輯測試，不能代表真實 App 間的輸入法相容性。

### 尚未驗證

- 歷史上是否曾實際累積數十個幽靈輸入法項目。
- 所有幽靈項目是否能由目前反安裝流程完全清除。
- TextEdit、CotEditor、瀏覽器及 Electron App 的完整相容性。
- 多次升級、降級、安裝及反安裝後的系統狀態。
- 不同 macOS 版本的實際偏好同步結果。

## 9. 建議驗收項目

正式發布前，建議執行下列測試：

1. 全新使用者首次安裝。
2. 相同版本重複安裝。
3. 舊版本更新至新版本。
4. 多次安裝與反安裝。
5. 系統設定中新增及移除輸入來源。
6. 登出／登入後確認輸入來源狀態。
7. TextEdit 或 CotEditor 中文輸入。
8. 瀏覽器或 Electron App 中文輸入。
9. 從其他輸入法切換至本專案，再切回其他輸入法。
10. 反安裝後確認其他輸入法仍可使用。
11. 檢查 LaunchServices 與 TIS 是否出現重複項目。
12. 記錄安裝前後的 Bundle ID、Input Source ID 及 App 路徑。

每次驗收應記錄：

- macOS 版本
- CPU 架構
- Git commit
- Bundle Identifier
- Input Source ID
- App 實際路徑
- 測試使用者
- 測試使用的文字 App
- 安裝前後輸入來源狀態
- 是否重啟系統服務
- 未執行或未通過的項目

## 10. 對外說明建議

對外文件建議使用以下表述：

> 本專案已移除早期更新流程中的垃圾桶 App 備份，並針對 TIS 輸入來源、LaunchServices 註冊及 Bundle Identifier 殘留風險進行整理，以降低重複輸入來源與系統狀態不一致的機率。
>
> 安裝與反安裝流程仍需維護部分 macOS 輸入來源偏好狀態；不同 macOS 版本的系統快取與同步行為可能不同。除自動化測試外，正式發布仍應透過實際系統設定及文字 App 進行驗收。

不建議使用以下尚未被完整證明的表述：

- 「100% 零殘留」
- 「徹底根除所有幽靈項目」
- 「完全不修改系統偏好」
- 「絕不影響任何系統服務」
- 「完全相容所有 macOS 版本」
