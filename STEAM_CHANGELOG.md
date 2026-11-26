[h1]Minidoracat Build Anything for B42 42.22.2-1.5.0[/h1]
[i]2026-11-27[/i]

[b]English summary[/b]
[list]
[*] New (off by default): dig basements. An admin turns on Basements in the sandbox page "what can be built" or in the Manage panel. The Stairs & ramps tab then has a Basements kind.
[*] Place a South or East Basement Entrance on the ground floor, then use Dig Basement Tile on the level below. Digging needs only a shovel. One basement holds at most 400 tiles, and dug tiles cannot be filled back.
[*] Changed: switches placed in a basement now wire themselves to the lights in the same room. With Basement Building installed, you can replace the outer walls it made; the old wall is removed without a refund.
[*] Fixed: replacing an upstairs floor no longer drops whoever stands on it. The tile turns red until they move away.
[*] Fixed: wall overlays on a room's east or south wall can now be placed and removed from indoors, also on upper levels and in basements.
[*] Server and players must update together (placement rule version 26). New sandbox option: Basements.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]挖地下室[/b]（預設關）：服主在沙盒「Minidoracat 自由建造：能蓋的種類」或「管理」面板打開「地下室」後，建造工坊的「樓梯與坡道」頁多一個「地下室」種類。完整規則與已知限制見指南「各種東西的規則：地下室」
[list]
[*] [b]開入口[/b]：在一樓地面放「往南下的地下室入口」或「往東下的地下室入口」，會開出一座往下的木樓梯，和樓梯下去前方一塊 3×2 格的空間
[*] 樓梯上方 3 格原本的地板與草會拆掉（本工具鋪的地板照拆除退料）；上面有家具、地毯、地面覆蓋或掉在地上的東西時要先清掉
[*] [b]往外挖[/b]：站在地下一層用「地下室挖一格」，可以拖一片；角色要站在旁邊已經挖開的格子上，一格一格挖過去
[*] [b]花費[/b]：挖只要鏟子，鏟子會隨著挖掘磨損，不要求技能。入口另收一組木樓梯的材料，經驗也照木樓梯給；入口的樓梯之後可以照一般樓梯拆掉、退料
[*] [b]牆與房間[/b]：挖開的地方四周會長出土牆、算室內，外圍的土牆可以用建造工坊直接換成實牆。用牆和門隔開後每一間各算一個房間，每一間要各自裝開關或燈，沒有的那間是暗的
[*] [b]限制[/b]：只能挖到地下一層，一塊連通的地下室最多 400 格；挖開的地方不能填回，挖出的土也不會變成物品；地下室的三個項目不能記進藍圖
[*] 新入口不能貼著別的地下室，要接起來就從裡面挖過去；地圖原有的地下室、其他 MOD 的地下房間旁邊一格內不能挖
[*] 有裝 Basement Building 時這三項照樣列出但不能用，請用它挖
[/list]
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]裝了 Basement Building 時，它挖出來的地下室外牆可以直接換[/b]：選別的牆蓋在那條邊上，蓋好後原本那面牆就拆掉，[b]不退材料[/b]。以前它在外圍放的木牆、原木牆擋著，建造工坊蓋不上別的牆
[list]
[*] 轉角那面牆一件同時擋北、西兩邊：只換其中一邊時，另一邊會換成同款、同等級的單面牆留著（之前升級過的不會變回土牆）
[*] 外圍照舊只能蓋實牆，門框、窗框、牆框這類開口照舊不能蓋；和原本那面同一張圖的牆照舊提示「這格已經有同一張圖了」
[*] 玩家自己用建造工坊或原版建造蓋在外圍的牆不算它的牆，照一般規則處理
[/list]
[*] [b]地下室的開關會自動接燈[/b]：本工具挖的地下室、地圖原有的地下室和 Basement Building 挖的地下室，放開關時照一般房間自動接上同一間的燈（一間不超過 400 格）；其他沒有房間的地下格子照舊提示「不是封閉的房間」，要手動接線
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]隔著牆把東西放進隔壁那間時，角色不走過去、提示旁邊沒有空位[/b]（0.1.0 起）：現在會走到那一格旁邊再蓋。會遇到的情況：開關、家具這類東西貼著牆放在牆的另一邊，那一格的南邊或東邊又是牆或還沒挖的土，例如一格寬的地下室、窄走廊
[*] [b]換樓上的樓板時，站在上面的人會掉到樓下受傷[/b]（0.1.0 起）：現在樓上的樓板有人、殭屍、動物或車在上面時不能換，游標那格變紅、提示這格有人站著，等他走開再換
[list]
[*] 地下室正上方（含東、南外側一格）的一樓地板也一樣，換和拆都要等上面的人、殭屍、動物或車離開；「拆除一區」的游標會即時標出來
[*] 你自己站在要換的那一格照樣能放，角色會先走到旁邊再換。拆也一樣；一次復原或拆好幾塊時，旁邊沒地方站的那一塊跳過，其他照拆
[*] 開著建造作弊時角色不走開，要先自己走開。底下沒有地下室的一樓地板、地下室裡的地板不受影響
[/list]
[*] [b]從室內掛東牆、南牆的牆面疊圖，角色要繞到屋外；二樓以上和地下室掛不上[/b]（0.1.0 起）：現在和蓋牆一樣，站在牆的哪一側都能掛、能拆，角色走到牆的這一側動手
[list]
[*] 受影響的是地腳線、污垢、塗鴉這類貼在牆上的圖。以前二樓以上的外牆、地下室還沒挖開那一側的牆從室內掛不上，還會跳出錯誤
[*] 最遠距離、上下最多差一層、別人的安全屋照舊檢查；畫、招牌這類能撿起來的掛牆物和貼牆放的家具不變，照舊要走得到
[/list]
[/list]

[b]伺服器管理員[/b]：伺服器與玩家要一起更新（放置規則版本 26），版本不同時伺服器會拒絕放置並提示更新。新的沙盒選項「地下室」（預設關）：關掉後玩家看不到也挖不了，已經挖好的地下室照舊。挖過地下室的存檔，移除本 MOD 前先看指南「移除本 MOD 前」。
