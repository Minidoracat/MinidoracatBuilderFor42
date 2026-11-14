[h1]Minidoracat Build Anything for B42 42.22.2-0.12.0[/h1]
[i]2026-11-15[/i]

[b]English summary[/b]
[list]
[*] While placing, the Rotate Building key (R by default) now switches walls, fences, door frames, window frames and stairs to the other side of the same set, so you no longer go back to the window to pick the other tile.
[*] Sloped roof pieces switch to the mirrored piece the same way. About half of the vanilla roof pieces have one; flat and symmetric pieces stay as they are.
[*] Items you can rotate show a rotate icon on their tile, and the tooltip and details say so.
[*] The 8 vanilla light switches are now named by wall and position (for example "N wall, east") instead of all being "Light Switch".
[*] Fixed: after you built or removed a wall in a house you built, other rooms went dark while their switches still showed on. Rooms now relight within a second; the same fix covers dim rooms after loading a single-player save.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]牆、柵欄、門框、窗框、樓梯放置時可以按旋轉鍵換到另一面[/b]：這幾種在清單裡北面、西面各是一項，以前挑了哪一張就只能蓋那一面，要換方向得回視窗找另一張。現在放置時按旋轉鍵（預設 R，手把 LB／RB）就換到同一組的另一面，再按一次換回來；樓梯是往西、往北兩組互換。找不到另一面的圖（例如只畫了一面的圖塊）照舊只有一面；門和窗照舊各挑各的
[*] [b]屋頂放置時可以按旋轉鍵換成另一個坡向[/b]：斜屋頂的兩個坡向在清單裡各是一項，以前要回視窗找另一張。現在放置時按旋轉鍵就換成左右相反的那一片，蓋在哪一層不變。原版約一半的屋頂片配得到；平頂、四角錐這類左右對稱的，以及找不到相反那一片的，照舊只有一張
[*] [b]放置時能旋轉的項目有標記[/b]：建造工坊視窗的方格左上角多一個旋轉圖示，滑鼠停上去的提示與右邊的詳情會寫「放置時按 R 旋轉」。沒有圖示的項目只有畫面上那一面
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]電燈開關的名稱寫出牆面與位置[/b]：原版的電燈開關有 8 張圖（4 面牆、每面 2 個位置），以前名稱都叫「電燈開關」、縮圖又小，看起來像只有 4 個方向。現在名稱後面接「北牆 · 靠東」這類說明，方格的第二行也寫
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]在自己蓋的房子裡拆牆、蓋牆後，其他房間變暗、開關卻顯示開著[/b]：以前要把每個開關各按兩次才會亮回來。現在一秒內自動照開關的狀態亮回來。單機讀檔後房間偏暗、第一次按開關像沒反應，也是同一個原因，一起修了
[/list]
