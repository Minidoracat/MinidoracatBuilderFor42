# Minidoracat Build Anything

用任何已載入的圖塊建造，包含其他 MOD 的材質包；材料與放置由伺服器決定

Project Zomboid Build 42 MOD。

## 功能

- **所有圖塊都能蓋**：原版與材質包 MOD 的圖塊整理成一個目錄，牆、地板、柱子、門窗、樓梯、屋頂、家具和燈都行；可以搜尋名稱、圖塊組、來源 MOD 或完整圖塊名稱，也能在地上右鍵選「挑圖塊（建造工坊）」；用頁籤、種類和來源縮小範圍，也能加入最愛。
- **照原版付材料**：照原版拆解或同類原版建造會用到的材料收，材料放在背包或腳邊就好；不要求技能等級，用掉材料會給經驗。
- **建造游標**：地上的虛影顯示能不能蓋，原因和按鍵說明寫在滑鼠旁；按住左鍵拖可以蓋一排或一整片（牆、柵欄沿長方形圍一圈，地板、屋頂鋪滿），材料不夠的格子會跳過。原版能疊的箱子照原版疊。
- **原地替換**：在自己蓋的地板、牆、柵欄、實心家具這類東西上蓋同類的另一款，會原地換掉，只補新的比舊的多的料，多出來的照拆除規則退；牆和門框、窗框可以互換。燈、樓梯、門、窗、多格家具和能搬的東西不換。
- **開關與燈**：開關放進封好的房間會自動接上同一間的燈，再放一個就變成雙切；也能手動接線。和原版一樣要有電才會亮。
- **拆除**：右鍵選「拆除（建造工坊）」拆一件，或選「拆除一區...」拉一個長方形，一次拆掉用建造工坊蓋的東西，每種材料退回 1 件到全部。只拆用建造工坊蓋的東西，不能取代原版大鎚。
- **伺服器把關**：材料、距離、走不走得到和安全屋權限都由伺服器檢查；裝了 Minidoracat Safehouse 時照它的權限。
- **管理員設定**：在建造工坊的「管理」面板或沙盒設定開關能蓋的種類、MOD 與圖塊組，也能調誰能蓋、在哪裡蓋、最遠距離、一次拖曳最多幾項、材料倍率，以及蓋的東西殭屍打不打得壞、門敲不敲得破、容器容量倍率。

完整說明與常見問題見 Steam 指南：[繁體中文](https://steamcommunity.com/sharedfiles/filedetails/?id=3830047491)／[English](https://steamcommunity.com/sharedfiles/filedetails/?id=3830047545)（稿源 [STEAM_GUIDE.md](STEAM_GUIDE.md)、[STEAM_GUIDE_EN.md](STEAM_GUIDE_EN.md)）。

## 需要

- [Minidoracat UI Library](https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701)
- 選用：[Minidoracat Safehouse](https://steamcommunity.com/sharedfiles/filedetails/?id=3819478078)

## 安裝

- Steam Workshop：[Minidoracat Build Anything](https://steamcommunity.com/sharedfiles/filedetails/?id=3830045886)（ID 3830045886）
- 手動安裝：把 `MOD/MinidoracatBuilderFor42/Contents/mods/MinidoracatBuilderFor42` 整個資料夾複製到 `%USERPROFILE%\Zomboid\mods\`

## 開發

- `link_workshop.bat`：手動同步、唯讀狀態與歸檔卸載；MOD 以實體副本放入 `Zomboid\Workshop\` 與 `Zomboid\mods\`，不使用目錄連結
- `PZ_Test.bat`：暗色點選視窗，啟動前增量同步目前 MOD 與家族依賴；首次預設 no-Steam，之後記住各專案的選擇。需要換檔但遊戲仍在執行時拒絕同步與新啟動，不停止既有遊戲；完整驗證與資料邊界見 `../pz-family-docs/tools.md`
- `Publish_Workshop.bat`：發布到 Steam Workshop（需 Steam 用戶端已登入；可選擇只更新內容／封面／簡介；首發仍走遊戲內上傳器）

## 版本

版本號格式：`{PZ 版本}-{mod 版本}`（例 `42.21.0-0.1.0`），詳見 [CHANGELOG.md](CHANGELOG.md)。

## 作者

Minidoracat — [Discord](https://discord.gg/Gur2V67) | [Twitch](https://www.twitch.tv/minidoracat)
