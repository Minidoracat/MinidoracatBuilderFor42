[h1]Minidoracat Build Anything for B42 42.22.2-1.2.0[/h1]
[i]2026-11-23[/i]

[b]English summary[/b]
[list]
[*] New: sliding glass doors can be installed under a wall-top trim piece instead of a door frame (the wall overlay that is only a strip along the top, e.g. search walls_exterior_house_06_15). No frame wall shows behind the glass and the room still counts as indoors. Installing them in a door frame still works.
[*] New: walls, fences, posts, door frames, window frames, doors and windows can be built one level up with PgUp / PgDn (controller X), like floors and roofs. You can build the second-floor walls while standing downstairs.
[*] Fixed: blueprints with walls, doors or windows on the upper level built nothing while that level had no floor yet (since 1.0.0).
[*] Fixed (1.1.2): with a Knox Pass door set to "count as indoors" standing on a floor built with this tool, the room stopped counting as indoors for about a second every time the area loaded.
[*] Fixed (1.1.2): a door left open while the area reloaded could stop counting as a wall after you closed it.
[*] Server and players must update together (placement rule version 20). No new sandbox options.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]滑動玻璃門可以裝在牆頂橫條底下[/b]：以前滑動玻璃門一定要先蓋門框，門框牆會從玻璃後面露出來；把門框拆掉，房間又不算室內。現在那條邊先放一片牆頂橫條（「牆面疊圖」裡只有頂上一條的那款，例如搜尋 walls_exterior_house_06_15），就能直接裝滑動玻璃門，玻璃後面是空的，房間照樣算室內。放進門框的做法照舊能用。門還在的時候，建造工坊不讓拆這片橫條，也拆不了滑動玻璃門（和其他搬不動的門一樣）：先把門砸掉（建造工坊不退料），再拆橫條。朝西的橫條和牆角柱在同一格、或門會切開多格家具時裝不上。選滑動玻璃門時，詳情會寫這個做法。
[*] [b]牆也能往上一層蓋[/b]：以前只有地板和屋頂能按 PgUp／PgDn（手把 X）換到上一層蓋。現在牆、柵欄、柱子、門框、窗框、門、窗也可以，預設照舊蓋在這一層。站在樓下就能蓋二樓的牆，角色會走到正下方那條邊旁邊施工；剛蓋的要復原（Ctrl＋Z）或拆掉，也是在樓下走到同一個位置。上一層靠什麼撐沒有變：牆要腳下有地板、正下方同一條邊有牆，或兩側同一層有屋頂片；柵欄、柱子、門框、窗框要這一格或那條邊另一側的格子有地板；門、窗照舊要裝在框裡。建造配方的牆照原版，不能換層。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]照圖蓋上一層的牆、門窗時，樓上那格還沒有地板就一片都不蓋[/b]（1.0.0 起）：人在樓下、藍圖裡有上一層貼著格邊的東西時，會提示旁邊沒有空位。現在會走到正下方那條邊旁邊蓋。
[*] [b]Knox Pass 的門勾了「算室內」、門下又鋪著本工具的地板時，每次回到那一帶屋內會有約 1 秒不算室內[/b]（1.1.2）：1.1.2 加的檢查每次那一帶重新載入，都把門那一排改記成沒有牆，Knox Pass 約 1 秒後再改回來；這段時間屋內照室外算，伺服器也跟著多存檔、多送資料給附近的玩家。現在這個檢查只補遊戲漏記的，遊戲已經記成牆的不動。
[*] [b]門開著的時候離開再回來，關上門後那扇門可能不算牆[/b]（1.1.2）：雙開門這類門開著時那一帶重新載入，1.1.2 會把門那一排記成沒有牆，之後關門也不會記回來，房間可能不算室內，要再離開、回來一次才恢復。現在不動它。
[/list]

[b]伺服器管理員[/b]：伺服器與玩家要一起更新，版本不同時伺服器會拒絕放置並提示更新。沒有新的沙盒選項。
