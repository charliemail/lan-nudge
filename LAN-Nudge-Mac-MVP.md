# LAN Nudge macOS App｜AI 實作規格

## 1. 任務與範圍

在目前專案內實作可從 Xcode 建置的 macOS 選單列 App，暫名 **LAN Nudge**。兩台 Mac 在可互通的區網內執行 App 時，使用者可以找到對方、完成配對，再選擇「小人觸電」或「視窗震動」提醒對方。App 在背景也能接收，接收端能暫停提醒和解除配對。

預設以 macOS 15+ 為目標，使用 Swift、SwiftUI、AppKit 和 Network.framework。介面使用繁體中文。使用本機直連，不設雲端服務、帳號、聊天、離線補送或開機自動啟動。先讀取現有專案規範，新專案則建立一個 App target 和測試 target。

## 2. 使用流程

1. 首次啟動填寫顯示名稱，允許 macOS 的區域網路存取。選單列顯示附近裝置，區分「未配對」、「已配對」與「離線」。名稱重複時顯示識別碼短尾，名稱只供辨識。
2. 兩端各自從 App 複製裝置憑證的完整 SHA-256 指紋，透過當面或可信管道交換，再於各自 App 中選擇目標與貼上對方指紋。雙方都確認後才能互戳。提供「預覽動畫」，單台 Mac 就能測試效果。
3. 選擇對方，點選效果。接收端顯示發送者名稱並播放約一秒。發送端顯示「已觸發」、「對方暫停接收」、「請稍後再試」或「未收到確認」。畫面播出代表接收端已呈現提醒，無法判定對方本人是否看到。

## 3. 技術設計

### 區網與信任

- 使用 Bonjour 服務類型 `_lannudge._tcp`。用 `NWListener` 公告服務、`NWBrowser` 探索、`NWConnection` 傳輸。處理重複或移除的探索結果、睡眠喚醒和網路切換。Bonjour 資料僅供探索，收到連線後以 TLS 驗證的裝置身分決定權限。
- 每台 Mac 建立並在 Keychain 保存獨立 TLS 身分。使用雙向 TLS，兩端各比對對端憑證 DER 的 SHA-256 與已確認的指紋。可使用受維護的函式庫處理自簽憑證的建立與匯入，禁止共用私鑰或無條件接受憑證。保存已信任指紋與本機暱稱，重啟後維持配對。解除配對時清除信任並關閉該裝置的現有連線。
- 設定 `NSLocalNetworkUsageDescription` 與 `NSBonjourServices`。若啟用 App Sandbox，設定 client/server 網路權限。區網被拒絕時引導到「系統設定 → 隱私權與安全性 → 區域網路」。搜尋不到時提示檢查兩端 App 是否執行，以及訪客 Wi-Fi、AP 隔離或防火牆。

### 訊息與接收規則

- 採短連線，一次傳送一筆請求及一筆回覆。每個 frame 用 4-byte big-endian 長度加 UTF-8 JSON，payload 最多 4 KiB。處理 TCP 分段，先驗證長度再讀取 payload。連線、收送及回覆的總期限為 5 秒。
- 請求使用 `version: 1`、`type: "nudge"`、UUID `id`、`effect: "cartoonShock" | "shake"`。回覆使用同一版本和 ID、`type: "ack"` 及 `status: "displayed" | "muted" | "rateLimited" | "unavailable" | "invalid"`。不認得版本或效果時回覆 invalid（能解析 ID 時）並且不播放。顯示的發送者名稱由本機配對紀錄取得。
- 由接收端序列化判斷，以已驗證的裝置身分加 UUID 做去重，短期保留有上限的處理結果（預設 60 秒、最多 256 筆）。相同事件重送回傳原結果，最多播放一次。不同事件同一發送者預設間隔 5 秒，全域一次只播一個，不排隊。發送逾時不自動重送；先前訊息可能已播放。
- 只有浮層已呈現才回覆 displayed。暫停接收回覆 muted。顯示器休眠、鎖定或目前無法呈現時，不排隊也不在解鎖後補播。對未授權連線在握手時拒絕。

### 動畫與視窗

- SwiftUI 管理選單、設定和動畫內容。AppKit 在主執行緒管理透明、無邊框、非啟用的浮層，忽略滑鼠事件且不搶鍵盤焦點。動畫結束即清除視窗與計時工作，避免長時間殘留。
- 小人觸電採原創卡通角色和局部電光，避免全畫面閃白。震動效果使用顯示發送者的提醒小窗左右晃動。兩種效果共用浮層，支援接收端開啟「減少動態效果」時改成靜態提醒。
- 預設只在滑鼠所在顯示器右下角顯示，無法定位時用主顯示器；使用可視範圍避開 Dock。測試桌面、不同 Space 及全螢幕。全螢幕若無法顯示，回覆 unavailable。記錄實測支援情況。

## 4. 實作順序與驗收

| 階段 | 完成條件 |
|---|---|
| 本機動畫 | Xcode 建置成功；兩種動畫能從選單預覽並自動消失。切到另一個 App 時，鍵盤焦點和滑鼠操作維持正常。 |
| 區網與授權 | 兩台實體 Mac 可互相探索、配對和雙向發送兩種效果。未配對、錯誤指紋或解除配對後皆無法觸發。重啟保留配對。 |
| 例外與回歸 | 單元測試覆蓋 frame 分段、長度上限、無效版本／效果、同 ID 重送與兩筆並行請求的限流。人工測試暫停接收、App 結束、區網權限拒絕、換網或睡眠喚醒、多螢幕、全螢幕和減少動態效果。 |

交付可建置的 Xcode 專案、原始碼、測試及 README。README 要列出最低系統版本、建置方式、兩台 Mac 的配對與操作步驟、已知限制，以及實際執行的測試和結果。輸出建置與測試指令及結果。若環境缺少 Xcode 或第二台 Mac，標示未驗證的項目及重現步驟，待有實機再完成驗收。

## Apple 技術參考

- [區域網路隱私與 Bonjour 設定](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [視窗讓滑鼠事件穿透](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents)
- [全螢幕輔助視窗](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)
