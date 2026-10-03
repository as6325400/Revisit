# Revisit

讀取 Apple Watch 記錄在「健康」裡的運動，在地圖上用 3D 重播路線，並可匯出重播影片和 `.fit` 檔。原生 iOS（Swift／SwiftUI），最低 iOS 18。

規劃與進度：[docs/PLAN.md](docs/PLAN.md)

## 需要的東西

- Apple silicon 的 Mac，安裝 **Xcode 27** 以上，並同意授權條款：`sudo xcodebuild -license accept`
- 一支 iPhone，和用來記錄運動的 Apple Watch
- Apple ID（在 Xcode → Settings → Accounts 登入）。免費帳號也能裝到自己的手機，但每 7 天要重裝一次；付費的 Apple Developer Program 才能用 TestFlight 或上架。
- （選用）[Mapbox](https://account.mapbox.com) 帳號的 public token，給 3D 重播和影片匯出用。沒有的話重播會改用 Apple 地圖，也不能匯出影片。

## 第一次設定

1. 建立個人設定檔（不會進 git）：

   ```sh
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
   ```

   在裡面填：
   - `MAPBOX_ACCESS_TOKEN`：Mapbox public token（`pk.` 開頭）。
   - 如果你不是專案擁有者，還要填 `REVISIT_DEVELOPMENT_TEAM`（你的 Team ID）和 `REVISIT_BUNDLE_ID_PREFIX`（例如 `com.yourname`）。Bundle ID 在 Apple 是全球唯一的，不能沿用別人的。

2. iPhone 用線接上 Mac，在手機上按「信任」。
3. iPhone 開啟開發者模式：設定 → 隱私權與安全性 → 開發者模式。這個選項要先接過 Xcode 才會出現，開啟後手機會重新開機。
4. 第一次簽名要在 Xcode 裡做一次：打開 `Revisit.xcodeproj`，在最上方選你的 iPhone，按 ⌘R。之後就可以只用下面的 script。

## 安裝到手機

```sh
scripts/install.sh                 # 接著的那支 iPhone
scripts/install.sh "Jane's iPhone" # 接了好幾支時，用名稱或 UDID 指定
```

Script 會自動找手機、檢查信任和開發者模式、編譯簽名、安裝並打開 App。出錯時會說明原因，完整記錄在 `build/DerivedData/install.log`。

也可以不寫設定檔，直接用環境變數指定簽名：

```sh
REVISIT_DEVELOPMENT_TEAM=ABCDE12345 REVISIT_BUNDLE_ID_PREFIX=com.jane scripts/install.sh
```

第一次在新手機打開時，如果出現「不受信任的開發者」：到設定 → 一般 → VPN 與裝置管理 → 信任你的開發者帳號。

## 開發

單元測試：

```sh
xcodebuild -project Revisit.xcodeproj -scheme Revisit \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

模擬器沒有 Apple Watch，Debug 版有「示範模式」：會跳過「健康」，直接載入台灣的範例路線（跑步、健行、騎車、開放水域、跑步機、泳池）。在 Xcode 的 Scheme → Run → Arguments 加上啟動參數：

| 參數 | 作用 |
|---|---|
| `-demoData -onboardingCompleted YES` | 用範例資料、跳過首次設定 |
| `-openWorkout 1` | 直接打開第 2 新的一筆（`-openFirstWorkout` 是第 1 筆） |
| `-openReplay`、`-replayProgress 0.4` | 打開 3D 重播，並停在 40% 的位置 |
| `-openExport` | 打開重播並直接匯出 15 秒影片 |
| `-exportFIT` | 打開的那筆直接匯出 `.fit` |

要在模擬器測試真正的「健康」流程：設定 → 開發測試 →「寫入範例運動到『健康』」。
