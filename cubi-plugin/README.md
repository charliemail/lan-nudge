# LAN Nudge 的 Cubi 套件（開發中）

給有裝 [Cubi](https://github.com/jc33654/cubi) 的人用的 LAN Nudge：互戳、浮層與音效改由 Cubi 呈現，區網收送沿用這個 repo 的原版程式。沒有 Cubi 的人繼續用 LAN Nudge App，兩者用同一個協定（`_lannudge._tcp`，`Wire.version` 1）互通。

**狀態：實驗中。** 需要支援套件 `service` 欄位的 Cubi，那一版還沒發佈；目前的輔助程式只會跟 Cubi 打招呼，還不碰網路。

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

- 啟動後 5 秒內沒有從 stdin 收到 Cubi 的 `{"type":"hello","protocol":1}`，就直接結束（exit 64），不開任何網路功能。所以從面板、hook 或終端機直接執行它都不會動作。
- stdin 關閉（Cubi 結束、套件關掉）時結束。
- 套件要的執行檔是 `lan-nudge/bin/lan-nudge-helper`。怎麼建置、怎麼放進去，下一步補上；在那之前 `cubi --validate-plugin cubi-plugin/lan-nudge` 會回報找不到執行檔。
- 依賴跟 App 相同：swift-certificates 1.21.1、swift-crypto 5.1.2、swift-asn1 1.7.4，用 exact 版本釘住；這個套件的 `Package.resolved` 不進 git。第三方授權見 `LANNudge/Licenses.txt`。
