[h1]Minidoracat Build Anything for B42 42.22.2-1.4.0[/h1]
[i]2026-11-25[/i]

[b]English summary[/b]
[list]
[*] Changed: Build from blueprint now lays floors row by row, starting from the corner of the blueprint nearest to you. Walls, stairs, doors, roofs and furniture still go nearest first.
[*] New: in blueprint Edit, press Copy and then hold the left button and drag to drop a whole row of copies in one go. One Undo (Ctrl+Z) removes the row.
[*] New: Capture a building lists every level it read. Untick the levels you do not want and the blueprint keeps only the ticked ones.
[*] New option (Options > Mods > Build Anything): Show roofs on your level while building. Off by default; it only changes your own screen.
[*] Fixed: dragging a row of floors or roofs outward on an upper level stopped after one to three tiles (since 1.0.0). Half-tile (triangle) floors no longer leave the other half black: they are now a Floor overlay laid on the floor already on that tile. Placing switches and wiring below ground no longer throws errors; lights there are wired by hand in Wiring mode.
[*] Server and players must update together (placement rule version 21). No new sandbox options.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]框選現成房子可以只收某幾層[/b]：框到兩層以上有東西時，結果框會列出每一層讀到幾片，預設全勾。取消勾選後，收到的片數、收不到的原因馬上跟著變，存下來的藍圖只有勾著的那幾層，最低勾選的那層當成藍圖的第 1 層（例如只勾二樓，存下來就是一張一層的藍圖）。中間沒勾的層照樣留空，不會把上下層壓在一起。只勾樓上時，樓梯口那塊平台照一般地板收，樓梯口不會缺一塊
[*] [b]規劃時複製可以一次排好幾份[/b]：以前規劃裡選幾片按「複製」，一次只能放一份。現在按「複製」後，在要放的地方按住左鍵往旁邊拖，會沿著拖的方向（東西或南北，看哪邊拖得遠）一份接一份排開，間距是選到那幾片的寬度；提示會寫排了幾份、共幾片，每一份都有虛影。放開就一次放下，算一步，按一次「上一步」（Ctrl＋Z）整列拿掉。份數會自動限制在放得下的數量（每邊 64 格、整張 4,096 片）。只點一下照舊放一份；用手把時照舊一次一份
[*] [b]建造時可以看到同一層的屋簷[/b]：以前站在二樓房間裡拿著建造工坊的游標，窗外同一層的屋簷、門廊屋頂會變透明，看不清要接在哪裡。「選項 > 模組」的「自由建造」多了「建造時顯示同層屋頂」（預設關）：勾起來後，拿著游標時你這一層的屋頂照常畫出來，收起游標就恢復原本的透明。只管同一層，站在樓下時樓上照舊整層隱藏。只改你自己的畫面，不影響其他玩家，蓋下去的屋頂、材料、屋頂下補地板都和平常一樣
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]照圖蓋的地板改成一排一排蓋[/b]：以前地板是挑離你最近的先蓋，看起來從身邊一圈一圈往外鋪。現在從藍圖範圍離你最近的那個角開始，一排蓋完換下一排、來回蓋過去；藍圖剛擺好就按「照圖蓋」也是從角落開始。幾千片的大藍圖要整理比較久，超過 3 秒還沒整理完時會先蓋你身邊的一小段，再回到角落一排一排蓋（實測 64×64 的地板先蓋了身邊 3～14 片）。牆、樓梯、門、屋頂、家具的順序沒變，照舊挑離你最近的先蓋。樓上的地板要有東西撐著，照舊只能從撐得住的那一圈往外蓋。中途停下再按「照圖蓋」，會從你那時候最近的角重新開始排。同一格還有地毯、半格地板這類鋪在地板上的東西時，會等那格的地板蓋好才蓋；地板缺料或蓋不了時它們也先不蓋，結束時照那片地板的原因說明。同一排交錯鋪兩種地板（棋盤、條紋）時，角色會先把同一種蓋一趟、再回頭蓋另一種，比以前多走一些（實測 48 片多花約 17% 的時間）；只用一種地板時時間和以前一樣
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]在樓上往外拖一排地板或屋頂，角色蓋了一兩格就停下[/b]（1.0.0 起）：從二樓的地板邊往外拖一排新地板或屋頂，以前只蓋 1～3 格就提示「旁邊沒有空位」或「太遠了」，預覽卻整排都能蓋。現在輪到那一格、前一格已經蓋好時才找站的位置，可以一路蓋出去。多人遊戲會等前一格同步，最多約 2 秒。真的沒地方站、又離角色太遠的格子，照舊停在那一格並提示
[*] [b]在地下室放開關、接線時伺服器跳錯誤[/b]（0.1.0 起）：在地面以下放開關、按「接同一房間」、按開關或放燈時會跳一串錯誤。現在不再出錯。地下室沒有遊戲的房間資料，所以不會自動接燈，會提示「不是封閉的房間」；要接燈請右鍵開關選「接線...（建造工坊）」，在接線模式一盞一盞點
[*] [b]半格（三角形）地板蓋下去，另一半變黑[/b]（0.1.0 起）：人行道邊的三角磚這類只畫半格的地板，以前會把整格地板換掉，另一半就露出黑色。現在和地圖上原本的一樣疊在那格的地板上，另一半看得到下面的地板，所以那一格要先有地板。已經變黑的格子：先在那格鋪一整格地板，再放半格。更新前蓋的半格照舊能用「拆除（建造工坊）」拆掉，退的是當初付的地板材料。疊在地圖原有地板上的半格，之後把那格換成別款地板時會跟著舊地板消失、材料不退（和標線、污漬一樣），要再放一次
[/list]

[b]伺服器管理員[/b]：伺服器與玩家要一起更新（放置規則版本 21），版本不同時伺服器會拒絕放置並提示更新。原版有 76 張半格地板從「地板」改歸「地面覆蓋」：材料、工具、經驗不變；用沙盒關掉「地面覆蓋」種類時這幾張也不能蓋。沒有新的沙盒選項。
