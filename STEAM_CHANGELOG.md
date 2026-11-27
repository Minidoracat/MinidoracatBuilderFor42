[h1]Minidoracat Build Anything for B42 42.22.2-1.5.1[/h1]
[i]2026-11-28[/i]

[b]English summary[/b]
[list]
[*] Basement digging now has a shovel in hand, a digging animation and digging sounds. While you drag, the cursor shows how many tiles the basement will have and the limit.
[*] Basement entries are easier to find: search "basement" or "dig" in the build window. Each entry has its own description.
[*] Fixed: basements dug in wilderness with no vanilla town nearby turned outdoors after you walked away or the server restarted (since 1.5.0).
[*] Fixed: the first switch in a basement sometimes did not light the room, and in single player a lit basement could turn dark after loading far away (since 1.5.0).
[*] Fixed: wrong quick bar icons for basement entries, and the eyedropper switching to basement entries (since 1.5.0).
[*] Server and players must update together (placement rule version 27). No new sandbox options.
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]地下室的三個項目更好找、說明更清楚[/b]
[list]
[*] 建造工坊搜尋「地下室」「挖」「basement」「dig」都找得到（以前搜不到）
[*] 「地下室」分頁固定照「往南下的入口、往東下的入口、地下室挖一格」排（以前順序不固定）
[*] 入口和「地下室挖一格」各有自己的說明，放在「挖開的地方不能填回」後面，預設視窗高度也看得完；工具那一行多一句「鏟子會隨著挖掘磨損」
[*] 拖著挖的時候，游標會寫這座地下室挖完後有幾格、上限幾格，不用等撞到上限才知道
[*] 在一樓地面拿著「地下室挖一格」時，游標只寫它自己該怎麼用（要在地下一層用，先放入口、下樓再挖），不再和入口的說明併成一句
[*] 挖的時候，游標與提示改用挖的說法（「左鍵 挖掘」「放開 挖 N 格」「分 N 批接著挖」「挖好 N／M 格後停下」「挖掘中斷」）；建造、挖掘都會遇到的拒絕提示改成兩邊通用的說法，提示標題從「無法建造」改成「無法動工」
[*] 裝了 Basement Building 時，「管理」面板的「種類」頁、建造視窗變窄時的詳情也會提醒「地下室請用它來挖」
[/list]
[*] [b]挖地下室時角色手上拿鏟子、做鏟土動作，有挖土的聲音[/b]（以前照建造的動作）
[*] [b]拖一大片挖地下室時游標比較順[/b]：實測游標預覽每次更新，多數時候從約 33 毫秒降到約 26 毫秒，最慢從約 37 毫秒降到約 29 毫秒
[*] [b]伺服器與玩家載入地圖時，本 MOD 對每一格做的檢查比較快[/b]：沒有門窗、家具的格子約快三成，有的約快一成（離線量測）
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]在地圖北邊沒有原版城鎮的荒野挖的地下室，走遠再回來、或專用伺服器重開後，會變成室外、開關打不亮[/b]（1.5.0 起）：要重進遊戲才恢復。現在走回來時會自動恢復成室內，伺服器重開後也是室內
[*] [b]地下室挖好後還沒裝開關就走遠再回來，或在離它比較遠的地方重新連線、讀檔，之後裝的第一個開關打開燈不亮[/b]（1.5.0 起）：現在裝第一個開關時會重新整理那一間，打開就會亮
[*] [b]單機在離地下室比較遠的地方讀檔，走回去時原本開著的燈變成關的[/b]（1.5.0 起）：要再按一次開關才亮。現在會照存檔前的狀態亮著。從 1.5.0 更新上來的存檔，更新後還沒按過的開關，之後在遠處讀檔時開著的燈還是會關一次，按一次開關之後就會記住
[*] [b]地下室挖新的一格之後，只裝了別的 MOD 牆上開關的房間會變暗[/b]（1.5.0 起）：開關還顯示開著。現在挖完會照開關的狀態補亮
[*] [b]快捷列上地下室項目的縮圖不對[/b]（1.5.0 起）：現在和建造視窗一樣，挖一格畫泥土地面、入口畫樓梯
[*] [b]地下室開著時，用吸管點到地下室借用的幾張原版圖，會切成地下室的項目[/b]（1.5.0 起）：現在吸管不會切到地下室的三個項目
[/list]

[b]伺服器管理員[/b]：伺服器與玩家要一起更新（放置規則版本 27），版本不同時伺服器會拒絕放置，玩家看到「建造設定已更新」的提示。沒有新的沙盒選項。
