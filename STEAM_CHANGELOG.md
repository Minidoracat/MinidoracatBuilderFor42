[h1]Minidoracat Build Anything for B42 42.22.2-1.1.2[/h1]
[i]2026-11-23[/i]

[b]English summary[/b]
[list]
[*] Fixed: houses that were enclosed and roofed sometimes still didn't count as indoors (mostly ones built before 1.0.0), so things like body temperature treated them as outside. A missing upper floor did the same to the room right below it.
[*] Old builds now fix themselves: after updating, floors and walls built with this tool are checked as the game loads them, and the ones the game missed are recorded again. No need to dismantle and rebuild.
[*] If a room still doesn't count as indoors after updating (for example around ramps, or the tile left behind after dismantling stairs), dismantle and rebuild that one floor or wall piece, and let us know.
[*] Server admins: no new sandbox options. The server log gets a few extra lines the first time old bases are loaded; that is expected.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]圍好了、有屋頂的房子有時還是不算室內[/b]（多半是 1.0.0 以前蓋的）：以前蓋地板、牆的時候，遊戲偶爾沒把那一格記進它算室內用的資料，圍好、有屋頂的房子就照室外算（例如體溫）；二樓地板漏掉時，正下方那間也一樣。1.0.0 起新蓋的遇到的機會低很多，但以前漏掉的還留在存檔裡。現在不管哪一版蓋的，更新後重新進遊戲、回到那棟房子時會檢查本工具蓋的地板、牆，漏掉的重新補記，不用拆掉重蓋。
[*] [b]更新後還是不算室內的房子[/b]：少數情況這版檢查不到（例如坡道，或樓梯拆掉後留下的那一格）。把那一格的地板或牆拆掉重蓋一次就會記上，也歡迎回報。
[/list]

[b]伺服器管理員[/b]：沒有新的沙盒選項。更新後伺服器第一次讀到舊基地時會自動補記，紀錄檔會多幾行補記的紀錄，屬正常。
