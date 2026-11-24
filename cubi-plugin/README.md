# LAN Nudge 的 Cubi 套件（開發中）

給有裝 [Cubi](https://github.com/jc33654/cubi) 的人用的 LAN Nudge：互戳、浮層與音效改由 Cubi 呈現，區網收送沿用這個 repo 的原版程式。沒有 Cubi 的人繼續用 LAN Nudge App，兩者用同一個協定（`_lannudge._tcp`，`Wire.version` 1）互通。

**狀態：實驗中。** 需要支援套件 `service` 欄位的 Cubi，那一版還沒發佈。目前收得到別人戳你（Cubi 畫浮層）；從 Cubi 面板戳別人，要等 Cubi 的面板接上輔助程式。

## 結構

| 路徑 | 內容 |
|---|---|
| `lan-nudge/` | 套件本身（`manifest.json`、面板 `index.html`），安裝時整個資料夾放進 Cubi 的 plugins 資料夾 |
| `helper/` | 輔助程式（SwiftPM）。Cubi 啟動它、從 stdin 送 `hello`，它從 stdout 回報事件 |
| `helper/Sources/LanNudgeHelper/{Protocol,Identity,PeerNetwork,ReceiveGate}.swift` | 指向 `../LANNudge/` 原版檔的符號連結，不是複本：App 改了，輔助程式下次建置就跟著改 |
| `scripts/check.sh` | 建置並測試輔助程式 |

## 對原版 App 的影響

沒有。`project.yml` 只收 `LANNudge/` 與 `LANNudgeTests/`，`scripts/package.sh` 只建 `LANNudge.xcodeproj`，這個資料夾不會進 App 或 DMG。

改 `LANNudge/` 裡上面那 4 個檔之後，請跑一次：

```bash
zsh cubi-plugin/scripts/check.sh
```

## 輔助程式

- 啟動後 5 秒內沒有從 stdin 收到 Cubi 的 `{"type":"hello","protocol":1}`，就直接結束（exit 64），不開任何網路功能。所以從面板、hook 或終端機直接執行它都不會動作。收到的是別的 protocol 版本時，在 stderr 說明後以 0 結束，Cubi 不會一直重開它。
- 要先有顯示名稱才開始，跟 App 第一次開啟時一樣：沒有名稱時不監聽、不公告、不瀏覽，也不碰鑰匙圈，`state` 回 `needsName: true`。名稱由套件面板經 Cubi 傳進來（`call` 動作 `setName`，參數 `name`），拿掉控制字元後最多 40 字，存在輔助程式自己的偏好設定（`dev.lannudge.cubi-helper` 的 `displayName`）。不會拿這台 Mac 的電腦名稱來用，因為那常常是使用者的真名。
- 身分存在登入鑰匙圈，標籤是 `Cubi LAN Nudge Identity`，跟 App 的 `LAN Nudge Identity` 分開：同一台 Mac 上的 App 與套件版，在別人的清單上是兩台裝置。第一次設定名稱時才建立。
- 收：請求照 App 的 `ReceiveGate` 規則（暫停接收、限流、去重）判斷，通過了就請 Cubi 畫浮層（`present`，附帶訊息時一起帶上，`seconds` 是要顯示幾秒），等 Cubi 回答（最多 1.5 秒）才回對方 ack。顯示時間由 helper 決定，Cubi 照 `seconds` 顯示，helper 也照同一個數字排下一則。所以「已觸發」跟 App 一樣代表畫面上真的出現了。
- 排隊（App 0.4.0）：Cubi 正在顯示一則時，0.4.0 以後的送出者排進 App 的 `NudgeQueue`（最多 5 則、每人 1 則），對方看到「已排隊」；顯示時間（加 App 的 0.3 秒間隔）到了才送下一則；在那之前來的都排在後面，不會插隊。顯示時間照 App：沒訊息 2 秒，有訊息 3 秒加每 10 字 1 秒、最多 8 秒。下一則 Cubi 顯示不出來（鎖定、休眠）就清掉整個佇列，跟 App 一樣。舊版送出端讀不懂「已排隊」，照舊回「請稍後再試」。
- Cubi 回「忙碌」（另一個套件的浮層還在）時：那一則回對方「對方目前無法顯示提醒」，佇列保留，2 秒後再試，連續 5 次都忙碌才清掉；這段時間新來的照樣排隊。
- Cubi 顯示不出來（例如鎖定畫面，或 1.5 秒內沒回答）之後 2 秒內，再來的請求回「請稍後再試」、不排隊也不再問 Cubi，讓 `present` 不會快過 Cubi 能收的速度。所以鎖定畫面時，只有第一個送出者收到「對方目前無法顯示提醒」。
- 暫停接收：`call` 動作 `setMuted`，參數 `muted` 是 `"true"` 或 `"false"`，存在輔助程式自己的偏好設定；開著時每個請求都回「對方暫停接收」，佇列清空。
- 預覽（Cubi 的 `--render-panel --with-service`，環境有 `CUBI_RENDER=1`）：讀已存的名稱與暫停接收，但不寫回、不上網路、不碰鑰匙圈；`state` 的 `problem` 說明是預覽。
- 狀態：以 `state` 交給 Cubi，最多每秒一次、最後一次變化一定送出：`{"needsName","name","muted","problem","peers":[{"id","name"}]}`。`peers` 最多 50 台，id 超過 64 bytes 的不列；名稱拿掉控制字元、最多 40 字，同名時加上指紋的前 4 個十六進位字；整行超過 Cubi 的 16384 bytes 時從尾端少列幾台。
- 送：Cubi 的 `call`，動作 `send`，參數 `peer`（清單裡的 id）、`effect`（`knock`、`zap`、`shake`）與選填的 `message`（照 App 清理、最多 60 字），回覆 `out.result` 是 App 的結果文字；「已觸發」與「已排隊」的 `ok` 是 true。還沒設定名稱時回錯誤。
- 對方的名稱來自對方的 Bonjour 公告，可以被冒用，跟 App 一樣；送給 Cubi 前會拿掉控制字元、換行與文字方向字元，並限制長度。
- stdin 關閉（Cubi 結束、套件關掉）時結束。
- 套件要的執行檔是 `lan-nudge/bin/lan-nudge-helper`。怎麼建置、怎麼放進去，下一步補上；在那之前 `cubi --validate-plugin cubi-plugin/lan-nudge` 會回報找不到執行檔。
- 依賴跟 App 相同：swift-certificates 1.21.1、swift-crypto 5.1.2、swift-asn1 1.7.4，用 exact 版本釘住；這個套件的 `Package.resolved` 不進 git。第三方授權見 `LANNudge/Licenses.txt`。
