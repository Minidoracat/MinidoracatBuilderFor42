[h1]Minidoracat Build Anything for B42 42.22.2-1.1.0[/h1]
[i]2026-11-21[/i]

[b]English summary[/b]
[list]
[*] Fixed: pressing a key or releasing the right mouse button at the main menu or loading screen no longer throws errors (since 1.0.0).
[*] Fixed: containers you pick up and put down keep the "Container capacity multiplier" (ones you moved before are restored when you load in), and moved boxes and appliances stay protected by "Zombies can't break builds".
[*] Full-height windows can be installed: place the wall overlay with a full-height opening from the same set on that edge first; the two wider than a door go into a double-door frame wall. Curtains can't be hung on them yet.
[*] Blueprints: placing one draws an outline around the whole plan, ghosts keep their tile colours (the floor frame shows the status), and moving a plan brings you back to planning and the Build Anything window.
[*] New "Window opacity" setting under Options > Mods > Build Anything (100%, 75%, 50%), and a Durability line in the details panel.
[*] New cursor warnings: a window that doesn't match its frame, and a wall or window that would block the top of a ramp. Server and players need to update together.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]能裝全高窗（落地窗）[/b]：以前放不上去。現在先把同一套裡「整片開口」的那張牆面疊圖放在那條邊，就能裝窗；比門還寬的兩款裝進雙開門的門框牆。詳情會寫要先放哪一種。全高窗還掛不上窗簾。
[*] [b]放置時的兩種提醒[/b]（只提醒、照樣能蓋）：窗的形狀和框不合時，提醒「蓋好會露出後面的牆」；在坡道頂端出口那條邊蓋牆或窗時，提醒「會讓人走不上去」。
[*] [b]詳情多一行耐久[/b]：選牆、柵欄、家具、門、窗或建造配方時，寫出蓋好後的耐久；伺服器設成殭屍打不壞時會註明。
[*] [b]視窗可以調不透明度[/b]：「選項 > 模組 > 自由建造」多了「視窗不透明度」，有 100%、75%、50% 三檔。只有背景變淡，文字和圖示不變。
[*] [b]擺放藍圖時畫出整張的外框[/b]：片數多的藍圖以前只看得到滑鼠附近的片；現在多一圈外框標出整張的範圍，按旋轉會跟著轉。
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]藍圖的虛影改用圖塊原本的顏色[/b]：以前整片染成淡紫、黃或紅，看不出是哪一款；現在圖塊照原色畫，能蓋、缺料、蓋不了改看腳下那一格的框。
[*] [b]搬藍圖後回到原本的畫面[/b]：規劃中搬藍圖，放下或按右鍵取消後自動回到規劃，建造工坊視窗也會重新打開。
[*] [b]被其他 MOD 收起來的建造配方[/b]：搜尋完整圖塊名稱時，說明會寫出是哪個配方、被哪個 MOD 隱藏（例如 Neat Building 的牆面變體），請到那個 MOD 自己的建造介面蓋。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]主選單或載入畫面按鍵會跳出錯誤[/b]（1.0.0 起）：還沒進遊戲時按到快捷鍵或放開右鍵，右下角會跳紅色的錯誤數字；現在不會。
[*] [b]容器搬過後容量倍率失效[/b]（0.3.0 起）：用原版的「拿起」把容器搬走再放下，容量會回到原版值；現在放下當下就照伺服器的倍率，以前搬過的更新後進遊戲會補回來。整組當成一件物品搬的多格容器（少數幾款）還沒修。
[*] [b]搬過的箱子和家電，殭屍打不壞失效[/b]（0.3.0 起）：現在放下後照舊打不壞。燈，以及掛在牆上或擺在桌上卻會擋路的少數家具還沒修。
[*] [b]擺放藍圖時按旋轉，位置和放下的不一樣[/b]（1.0.0 起）：長方形的藍圖轉完會偏到旁邊；現在轉完就留在滑鼠的位置。
[/list]

[b]伺服器管理員[/b]：這版伺服器與玩家要一起更新，版本不同時伺服器會拒絕放置並提示更新。
