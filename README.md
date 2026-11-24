# LAN Nudge

macOS 選單列 App：同一區網內開著 LAN Nudge 的 Mac，可以互相送出「小人觸電」、「視窗震動」或「敲門」提醒，並附帶音效。規格見 `LAN-Nudge-Mac-MVP.md`（原始文件）。

目前版本：**0.4.0 (5)**。第一階段（本機動畫）與第二階段（區網）的程式都已完成，自動測試全部通過；**兩台實體 Mac 的人工驗收尚未執行**。

## 安裝（DMG）

1. 打開 `LANNudge-<版本>-<build>.dmg`，把「LAN Nudge」拖到右邊的「Applications」資料夾。
2. 第一次開啟會被 Gatekeeper 擋下：到「系統設定 → 隱私權與安全性」按「強制打開」。原因是 App 採 ad-hoc 簽章，沒有經過 Apple 公證，詳見「簽章與安裝」。
3. 輸入顯示名稱，接著依提示允許「區域網路」；系統詢問鑰匙圈時，選「永遠允許」。
4. 想要「視窗震動」能晃動你正在用的視窗，請在設定視窗開啟「輔助使用」權限。

DMG 裡的 `Licenses.txt` 是授權條款，同一份也放在 App 裡（設定視窗 →「授權條款」→「開啟…」）。

DMG 由 `scripts/package.sh` 產生，放在 `release/`。這個資料夾不進 git，要公開發佈請上傳到 GitHub Releases。

## 與原始規格的差異

**不做配對**（2026-11-23 產品決定）。原規格要求雙方交換 SHA-256 指紋、雙向確認後才能互戳；現在改成同一區網上開著 App 的人都能互戳。

| | 原規格 | 現在 |
|---|---|---|
| 誰能戳你 | 只有雙方都配對過的裝置 | 同一區網上任何開著 LAN Nudge 的人 |
| 發送者名稱 | 取自本機的配對紀錄，不能冒用 | 取自對方的 Bonjour 公告，**可以被冒用** |
| 連線加密 | 雙向 TLS | 雙向 TLS（保留） |
| 送到正確的機器 | 比對完整指紋 | 比對對方憑證指紋的前 16 碼（64 bits）。偽造的 Bonjour 公告無法把提醒導到別台 |
| 防止騷擾 | 不配對就不能戳 | 只能靠限流（同一發送者 5 秒一次，同時只播一個）和「暫停接收」 |

在公司 Wi-Fi 這類共用網路上，任何人都能戳你，也能用別人的名字戳你。想停止接收就勾選「暫停接收」。

其他與規格不同的地方：
- 提醒顯示 **2 秒**（規格寫約 1 秒）。原本 1.2 秒，小人觸電一下就不見，容易沒注意到。接收端可以在設定改成固定 2～15 秒。
- **提醒會排隊**（規格寫不排隊）。畫面正在顯示提醒時，新的提醒最多排 5 則、每人最多 1 則，依序顯示；送出端看到「已排隊」。只有 0.4.0 以後的送出端會被排隊，因為舊版看不懂 `queued` 回覆，會誤顯示成「未收到確認」；舊版送來的提醒仍回覆 `rateLimited`。螢幕鎖定、休眠或勾選「暫停接收」時，隊伍會被清空，已收到「已排隊」的送出端不會得知。
- **可以附帶一句訊息**（`message`，最多 60 字）。協定版本仍是 1：舊版接收端會忽略這個欄位，照常顯示提醒、不顯示文字。接收端會自己再清理一次文字（換行、控制字元、文字方向覆寫字元改成空白，超過 60 字截斷），只顯示純文字。訊息不存歷史紀錄、不寫進 log。
- 新增第三種效果**敲門**（`effect: "knock"`）。舊版收到敲門會回覆 `invalid`，送出端會顯示「版本不相容」，不會播放。
- **視窗震動會晃動你正在用的視窗**（類似 MSN 的震動），不再只晃提醒小窗。這要用到「輔助使用」權限，所以**關掉了 App Sandbox**，詳見下方「視窗震動與輔助使用權限」。
- 每種效果都有**音效**，由程式即時合成，不附帶音檔：觸電是電流嗡嗡聲加劈啪聲，震動是低沉的碰撞聲，敲門是三下「叩叩叩」。音效和動畫的節奏同步。音量跟隨系統音量，靜音時不會發出聲音。

## 系統需求

- macOS 15.0 以上
- Xcode 26 以上（開發時使用 Xcode 26.6 / Swift 6.3）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：專案檔由 `project.yml` 產生（`brew install xcodegen`）
- 依賴（SPM 自動下載）：[apple/swift-certificates](https://github.com/apple/swift-certificates) 1.21.x，用來產生自簽憑證
- 打包用：[create-dmg](https://github.com/create-dmg/create-dmg)（`brew install create-dmg`）

## 建置與測試

```bash
xcodegen generate
```

```bash
xcodebuild -project LANNudge.xcodeproj -scheme LANNudge -destination 'platform=macOS' -derivedDataPath build/DerivedData.noindex test
```

產物：`build/DerivedData.noindex/Build/Products/Debug/LANNudge.app`。資料夾名稱以 `.noindex` 結尾，Spotlight 就不會把開發版列進搜尋結果，不會跟 `/Applications` 裡安裝的版本重複出現。修改 `project.yml` 或新增檔案後，要重新跑 `xcodegen generate`。

- 跑測試時會啟動一份 App 當作測試宿主，這份 App 不會啟動區網功能，所以不會干擾你正在使用的 LAN Nudge。
- `MutualTLSTests` 會在登入鑰匙圈建立兩組暫時身分（`LAN Nudge Test A/B`），測完就刪除。
- 重新建置後，正在執行的 LAN Nudge 仍是舊版；要結束後重新開啟才會用到新版。

## 打包 DMG

```bash
zsh scripts/package.sh
```

1. 重新產生專案檔並跑單元測試。測試沒過就停止，不會打包。
2. 用 Release 設定建置。Release 版不帶 `get-task-allow`，也就是不允許除錯器附加。
3. 用 `create-dmg` 做成拖曳安裝的 DMG：背景有箭頭，右邊放「Applications」捷徑。
4. 輸出到 `release/LANNudge-<版本>-<build>.dmg`，並刪掉 `release/` 裡較舊的 DMG。

為了避免公開的 DMG 透露打包者的家目錄路徑（例如 `/Users/<帳號>/...`），腳本會：
- 編譯時用 `-ffile-prefix-map` 把專案路徑改寫成 `.`。swift-crypto 的 C 程式碼會把原始檔路徑寫進執行檔。
- Release 建置時去掉除錯符號（`STRIP_STYLE=debugging`）。符號表裡記錄了物件檔和模組的絕對路徑；.dSYM 仍保留完整資訊，可以用來解讀當機紀錄。
- 在 `mktemp` 建立的隨機暫存資料夾裡製作 DMG，再搬到 `release/`。create-dmg 會把暫存映像檔的路徑寫進 DMG 的 `.DS_Store`。

發佈前可以這樣檢查：掛載 DMG 後，在磁碟區內用 `grep -rlaE "/Users/"` 搜尋，應該找不到任何結果。

版本號在 `project.yml` 的 `MARKETING_VERSION`（例如 0.2.0）和 `CURRENT_PROJECT_VERSION`（建置號），每次發佈前都要遞增。第一次執行時，`create-dmg` 會用 AppleScript 排列 Finder 視窗，系統可能會詢問是否允許 Finder 自動化。

DMG 裡的 App 叫「LAN Nudge.app」，跟開發用的 `build/DerivedData.noindex/.../LANNudge.app` 共用同一組鑰匙圈身分。**不要同時執行這兩份**，否則兩份會用同一個名稱在 Bonjour 上公告，互相衝突。

## App 圖示

原圖放在 `design/app-icon-source.webp`。換圖後執行：

```bash
zsh scripts/app-icon.sh
```

腳本會把原圖外圍的白色或透明背景去掉，依 macOS 圖示規格把主體縮放到 1024 畫布中的 824 × 824 範圍，再輸出 16～1024 各種尺寸到 `LANNudge/Assets.xcassets/AppIcon.appiconset`。

## 簽章與安裝

採 **ad-hoc 簽章**（Xcode 的 Sign to Run Locally），不使用 Apple Development／Developer ID。

- 自己從原始碼建置的 App 可以直接開啟。
- 傳到別台 Mac 的 App 第一次開啟會被 Gatekeeper 擋下：到「系統設定 → 隱私權與安全性」，按「強制打開」。
- 先把 App 移到 `/Applications` 再開啟，而且只保留一份。Apple 文件提到，同一個 App 裝了多個版本時，隱私權設定可能出現非預期的行為。
- 更新版本後，可能需要重新允許「區域網路」權限，也可能出現「LAN Nudge 想要使用鑰匙圈中的金鑰」：請輸入登入密碼並按「永遠允許」。**按「拒絕」不會產生新身分**，App 會顯示錯誤。

## 視窗震動與輔助使用權限

macOS 只允許 App 透過輔助使用（Accessibility）API 移動其他 App 的視窗，而沙盒內的 App 不能使用這個 API，所以 LAN Nudge **不使用 App Sandbox**。

- 開啟權限：設定視窗 →「震動真實視窗」→「開啟輔助使用權限…」，再到「系統設定 → 隱私權與安全性 → 輔助使用」打開 LAN Nudge。設定視窗約 1 秒內會變成「已允許」。
- 這個權限能控制其他 App，LAN Nudge 只用來讀取和移動「最前面 App 的目前視窗」位置，震完會放回原位。
- **重新建置或更新版本後，權限可能失效**（推論：ad-hoc 簽章每次建置都不同，系統認不出是同一個 App，待實測）。如果開關看起來是開的，但視窗不會震，請在清單中選取 LAN Nudge 按「−」移除，再重新加入。
- 沒有權限、全螢幕視窗、對方 App 拒絕移動，或開啟「減少動態效果」時，只晃動提醒小窗。
- 從沙盒版改成非沙盒版後，設定存放的位置不同，第一次開啟時要重新輸入顯示名稱。鑰匙圈的身分不受影響（可能會再問一次鑰匙圈權限）。

## 使用方式

### 首次啟動

1. 開啟 App，設定視窗會自動出現。輸入顯示名稱，按「儲存」。
2. 系統詢問區域網路存取時，按「允許」。如果按了拒絕，到「系統設定 → 隱私權與安全性 → 區域網路」把 LAN Nudge 打開。

### 送出與接收

- 選單列 ⚡︎ →「附近裝置」→ 選擇對方 →「小人觸電」、「視窗震動」或「敲門」。
- 想附一句話：選擇對方 →「附帶訊息…」，在小視窗選效果、輸入最多 60 字，按 Return 送出。對方使用 0.4.0 以前的版本時，只會看到提醒，看不到訊息。
- 送出後，選單會顯示結果：已觸發、已排隊、對方暫停接收、請稍後再試、對方目前無法顯示提醒、未收到確認。
- 「已觸發」代表對方的 Mac 已經把提醒顯示在畫面上，不代表對方本人有看到。
- App 開著時會一直接收提醒，不需要另外建立連線。每次送出都會自動建立一次短暫連線。
- 勾選「暫停接收」後，所有提醒都會回覆「對方暫停接收」。
- 設定 →「接收」：
  - 「顯示對方附帶的訊息」（預設開啟）：關掉後照樣會被戳，只是不顯示文字。
  - 「提醒顯示時間」：**自動**（預設）是沒附訊息時提醒小窗 2 秒、桌面寵物播一輪動畫；附訊息時 3 秒加上每 10 字 1 秒，最長 8 秒，動畫播完後文字繼續留著。**自訂**可選 2～15 秒，所有提醒都顯示這麼久（桌面寵物會重複播放動畫），按「還原預設」回到自動。顯示越久，後面的人排隊越久。
- 畫面正在顯示提醒時又有人戳你，新的提醒會排隊（最多 5 則、每人 1 則），提醒上會顯示「還有 N 則」。
- 附近有同名裝置時，名稱後面會加上識別碼的前 4 碼。

### 桌面寵物

- 預設開啟：桌面右下角會有一個待機角色，播放待機 GIF。
- 收到任何提醒（小人觸電、視窗震動、敲門）時，都只由角色反應：改播被電擊 GIF，下方標示是誰戳你，並播放電擊音效。播完一輪（1～5 秒）後回到待機。這時不會出現一般提醒小窗，也不會震動視窗。
- 可以用滑鼠把角色拖到別的位置，下次開啟會記得位置。圖片透明的地方，滑鼠點擊會穿過去，點到後面的視窗。
- 有開全螢幕 App 時角色不會出現，這時改用對方選的那種一般提醒，避免漏掉通知。關掉桌面寵物後，也會回到一般提醒。
- 設定視窗 →「桌面寵物」：可以開關角色，也可以「選擇 GIF…」換成自己的圖。換過的圖會複製到 `~/Library/Application Support/LAN Nudge/Pet/`，搬動或刪除原檔都不影響。按「還原預設」回到 App 內建的圖。
- 系統開啟「減少動態效果」時，GIF 只顯示第一格。
- 預設圖是 `LANNudge/Pet-idle.gif`（待機，240×372，20 格，2.8 秒）和 `LANNudge/Pet-shock.gif`（被電擊，232×360，10 格，1.4 秒，一般與 X 光骨架交替）。整理方式：待機圖把去背時被誤刪成透明的白色細節（眼睛、反光、項圈）補回；被電擊圖每一格都清掉閃電之間的黑色色塊和紅點，並從 640×993 縮小到 360 像素高。兩張都必須存在，角色才會出現。

### 單台 Mac 測試（兩個實例）

```bash
open -n build/DerivedData.noindex/Build/Products/Debug/LANNudge.app
```

```bash
open -n build/DerivedData.noindex/Build/Products/Debug/LANNudge.app --args -instance B
```

第二個實例會使用獨立的鑰匙圈身分（`LAN Nudge Identity B`）和設定，選單第一行會顯示「（實例 B）」。兩個實例在同一台 Mac 上，提醒會出現在同一個螢幕；看提醒上的名稱，就知道是誰戳誰。

## 區網與 VPN

做法沿用 `lan-listening-room` 的經驗：開著全通道 VPN 時，區網流量會被導進 VPN 通道，所以 Bonjour 找得到對方，但直接連對方的區網位址會連不上，連對方的 VPN 位址卻可以。

- Bonjour TXT 公告這些欄位：`fp`（指紋前 16 碼）、`name`、`port`、`addrs`（區網位址在前、VPN 位址在後，排除 `bridge`／`vmnet`）。
- 網路有變化（開關 VPN、換 Wi-Fi）或從睡眠喚醒時，會重新公告位址。
- 送出時，**同時連線所有候選位址**（Bonjour 位址加上 `addrs`）。第一個完成雙向 TLS、而且對方憑證符合 `fp` 的連線負責送出請求，其餘連線取消。整個流程限 5 秒。

搜尋不到對方時，依序檢查：兩端的 App 是否都在執行、區域網路權限、是否連在訪客 Wi-Fi、AP 隔離（裝置隔離）、防火牆。

## 測試紀錄

| 日期 | 項目 | 結果 |
|---|---|---|
| 2026-11-23 | `xcodebuild test`（macOS 26.5，Xcode 26.6） | 26 個測試全部通過（6 個 suite） |
| 2026-11-23 | ├ frame | 分段重組、一次讀到多個 frame、超過 4 KiB 時在收到內容前就拒絕、剛好 4 KiB、空 frame、編碼端上限 |
| 2026-11-23 | ├ 請求驗證 | 合法請求；未知版本、未知效果、錯誤 type 回覆 invalid（帶 ID）；ID 無法解析時不回覆 |
| 2026-11-23 | ├ 接收規則 | 同 ID 重送回傳原結果，而且只播一次；不同發送者使用同一個 ID 不會被去重；同發送者 5 秒內第二筆被限流；播放中其他人被限流；暫停接收；無法呈現；60 秒過期；256 筆上限 |
| 2026-11-23 | ├ 雙向 TLS（loopback，真實鑰匙圈身分） | 接收端取得發送端的憑證指紋；Bonjour 公告的 `fp` 與實際憑證不符時送出失敗，接收端不會收到請求；第一個位址不通（192.0.2.1）時，第二個位址在 2 秒內成功 |
| 2026-11-23 | ├ 音效 | 三種效果都有聲音（峰值 > 0.1）、沒有爆音（≤ 1），產生的 WAV 可以被 `AVAudioPlayer` 播放，長度正確且小於 2 秒 |
| 2026-11-23 | ├ 真實視窗震動 | 沒有自動測試（需要輔助使用權限和實際視窗） |
| 2026-11-23 | 真實視窗震動，人工操作（單台 Mac，已開輔助使用權限） | 視窗震動成功（使用者回報） |
| 2026-11-23 | `zsh scripts/package.sh` | 26 個測試通過 → Release 建置 → `release/LANNudge-0.2.0-2.dmg`（6.3 MB） |
| 2026-11-24 | `zsh scripts/package.sh`（0.2.1） | 26 個測試通過 → `release/LANNudge-0.2.1-3.dmg`（5.4 MB）；DMG 根目錄與 App Resources 都有 `Licenses.txt`，兩份內容與原始檔一致；整個磁碟區的隱私掃描乾淨；版本為 0.2.1 (3)；簽章驗證通過 |
| 2026-11-24 | `zsh scripts/package.sh`（0.3.0） | 28 個測試通過 → `release/LANNudge-0.3.0-4.dmg`（6.5 MB）；唯讀掛載確認：版本 0.3.0 (4)，App 內的 `Pet-idle.gif`、`Pet-shock.gif` 與 repo 檔案雜湊一致，`Licenses.txt` 與原始檔一致；`Signature=adhoc`、`codesign --verify --deep --strict` 通過，entitlements 只有 `app-sandbox`；整個磁碟區找不到 `/Users/` 或帳號名稱；SHA-256 `c183dcf1e73e7d3e8887373c2121cc159d032fa934a1605b7fe52e87338daf14` |
| 2026-11-23 | 隱私檢查（修正後重新打包） | 整個 DMG 磁碟區（App、`.DS_Store`、背景圖）都找不到 `/Users/` 或帳號名稱；DMG 5.3 MB，SHA-256 `fc6943c6e09d32841a1d790e68022161b9f65f6dd2ac7ec17f2b424ab03dcaed`；已發佈為 GitHub Release v0.2.0，下載後比對 SHA-256 一致 |
| 2026-11-23 | 唯讀掛載 DMG 檢查 | 內含「LAN Nudge.app」與 Applications 捷徑；版本 0.2.0 (2)；含 `AppIcon.icns`；`Signature=adhoc`，`codesign --verify --deep --strict` 通過；entitlements 只有 `app-sandbox = false`，沒有 `get-task-allow` |
| 2026-11-23 | ├ 身分 | 用同一個標籤重新載入，得到同一個指紋 |
| 2026-11-23 | `dns-sd -Z _lannudge._tcp` | 兩個實例都有公告，TXT 內有 `fp`、`name`、`port`、`addrs` |
| 2026-11-23 | `codesign -d --entitlements` | `Signature=adhoc`，`com.apple.security.app-sandbox = false` |
| 2026-11-23 | 單台 Mac 兩個實例（A、`-instance B`），人工操作 | 互相出現在「附近裝置」，互戳成功（使用者回報） |
| 2026-11-24 | `xcodebuild test`（加入桌面寵物） | 28 個測試全部通過（7 個 suite）；新增：GIF 播放長度計算（一輪 1.5 秒；過短補到 1 秒；過長截到 5 秒）、App 內建的待機圖可以讀取 |
| 2026-11-24 | 啟動 `-instance B`，列出視窗 | 桌面寵物視窗出現在主螢幕右下角，220×224，浮動層級 |
| 2026-11-24 | `xcodebuild test`（0.4.0：附帶訊息、排隊、顯示時間） | 38 個測試全部通過（8 個 suite）；新增：帶訊息與不帶訊息的請求、舊版格式（無 `message`、無 `acceptsQueued`）、接收端重新清理文字（換行、方向覆寫字元、60 字截斷、emoji 組合字不被拆開）、忙碌時只有新版送出端會排隊、排隊也計入 5 秒間隔、重送維持「已排隊」、隊伍滿了拒絕、隊伍上限 5 則與每人 1 則、自動與自訂顯示時間；loopback TLS 實際送出一則帶訊息的敲門，接收端收到相同文字 |

### 人工驗收（待執行）

| 項目 | 步驟 | 預期 |
|---|---|---|
| 三種動畫與音效 | 從選單分別預覽 | 右下角出現提醒並有音效，約 2 秒後消失；敲門的「叩」和聲音對得上 |
| 不搶焦點 | 在文字編輯器打字，同時從選單觸發預覽 | 游標與輸入仍留在編輯器 |
| 滑鼠穿透 | 提醒出現時，點擊它下方的視窗 | 點擊會傳到下方視窗 |
| 多螢幕 | 把滑鼠移到副螢幕再觸發 | 提醒出現在副螢幕右下角 |
| 其他 Space／全螢幕 | 切到另一個桌面，或在全螢幕 App 中觸發 | 記錄是否顯示 |
| 減少動態效果 | 開啟「系統設定 → 輔助使用 → 顯示器 → 減少動態效果」後觸發 | 顯示靜態提醒，不晃動、不閃爍 |
| 震動真實視窗 | 開啟輔助使用權限後，B 打開文字編輯器並在裡面打字，A 送「視窗震動」 | 文字編輯器視窗左右震動約 1 秒後回到原位，游標和輸入不受影響 |
| 震動退回小窗 | 沒有權限、全螢幕 App、開啟減少動態效果三種情況分別送「視窗震動」 | 只晃動提醒小窗，不會移動任何視窗 |
| 重建後的權限 | 重新建置 App 後再送「視窗震動」 | 記錄權限是否失效，以及移除再加入後是否恢復 |
| DMG 安裝 | 在另一台 Mac 打開 DMG，拖到 Applications 後開啟 | 視窗有背景箭頭，下方有 `Licenses.txt`；Gatekeeper 擋下後按「強制打開」可以執行；Dock 與 Finder 顯示新圖示 |
| 首次啟動 | 新使用者第一次開啟 | 設定視窗出現；儲存名稱後跳出區域網路權限詢問 |
| 區網權限被拒 | 權限詢問時按「不允許」 | 顯示前往系統設定的指引（macOS 27.2 之前無法重置權限，請用新的使用者帳號測） |
| 探索 | 兩台 Mac 都開啟 | 互相出現在「附近裝置」；關閉其中一台後，從列表消失 |
| 互戳 | A 戳 B、B 戳 A，三種效果都試 | 都顯示「已觸發」，提醒上的名稱正確 |
| 同時收送 | A 和 B 幾乎同時互戳 | 兩邊都能送出，也都能收到 |
| 暫停接收 | B 勾選「暫停接收」 | A 顯示「對方暫停接收」 |
| 限流 | A 在 5 秒內連送兩次 | 第二次顯示「請稍後再試」 |
| 鎖定／螢幕休眠 | B 鎖定螢幕後，A 送出 | A 顯示「對方目前無法顯示提醒」；B 解鎖後不會補播 |
| App 結束 | B 結束 App 後，A 送出 | B 從列表消失，或 A 顯示「未收到確認」 |
| VPN | 兩台都開全通道 VPN，A 送給 B | 5 秒內顯示「已觸發」（走 VPN 位址） |
| 換網／睡眠喚醒 | 換 Wi-Fi、開關 VPN、睡眠後喚醒，再互送 | 仍可送達 |
| 更新版本 | 換成新建置的 App 再開啟 | 記錄是否要重新允許區域網路與鑰匙圈 |

## 已知限制

- **沒有配對**：任何人都能戳你，名稱也可以被冒用。詳見「與原始規格的差異」。
- **已呈現的判定**：浮層已送到最前面，而且螢幕沒有鎖定、沒有休眠，就回覆 `displayed`。沒有逐像素檢查是否真的看得到。全螢幕 App 上能不能看到，要靠人工驗收記錄。
- **沒有手動位址**：所在網路不轉送 Bonjour 時（不同網段、VPN 不轉送 mDNS），兩台會互相看不到。
- `addrs` 只公告 IPv4 位址。
- 協定版本不同的裝置不會出現在列表中。
- 去重快取超過 256 筆後，最舊的一筆會被淘汰；如果剛好又被重送，可能再播一次。
- ad-hoc 簽章：更新版本後，可能要重新允許區域網路、鑰匙圈和輔助使用（見「簽章與安裝」與「視窗震動與輔助使用權限」）。
- 不使用 App Sandbox：App 被入侵時能存取的範圍比沙盒版大。

## 授權

本專案以 [MIT License](LICENSE) 授權。

App 內含以下第三方套件，授權皆為 Apache License 2.0。Apache-2.0 規定，散佈編譯後的程式時必須附上授權條款全文與 NOTICE，所以 [LANNudge/Licenses.txt](LANNudge/Licenses.txt) 收錄了本專案的 MIT 授權、各套件的版本與 NOTICE，以及 Apache License 2.0 全文。這份檔案會放進 App 的 Resources，打包時也會複製一份到 DMG。

| 套件 | 用途 |
|---|---|
| [apple/swift-certificates](https://github.com/apple/swift-certificates) | 產生自簽憑證 |
| [apple/swift-crypto](https://github.com/apple/swift-crypto)（內含 BoringSSL） | swift-certificates 的密碼學依賴 |
| [apple/swift-asn1](https://github.com/apple/swift-asn1) | swift-certificates 的 ASN.1 編碼依賴 |

更新依賴版本後，請重新產生授權檔（要先建置過一次，讓 SwiftPM 下載套件原始碼）：

```bash
zsh scripts/licenses.sh
```

App 圖示（`design/app-icon-source.webp` 與產生的各尺寸檔）、桌面寵物預設圖（`LANNudge/Pet-idle.gif`、`LANNudge/Pet-shock.gif`，作者自繪）、動畫角色與合成音效，跟程式碼一起以 MIT 授權。
