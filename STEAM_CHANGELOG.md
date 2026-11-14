[h1]Minidoracat Build Anything for B42 42.22.2-0.11.0[/h1]
[i]2026-11-14[/i]

[b]English summary[/b]
[list]
[*] Server side: the records this mod keeps to refund what you dismantle (floors and ponds, overlays, lights and appliances, circuits) are now stored in a compact format and split across several save files, so busy servers no longer approach the game's size limit for a single file. Nothing changes for players; everything already built keeps its refund and wiring.
[*] Admin panel: the Rules page now ends with a "Server records" section showing how many entries, files and how much space each record uses.
[*] Server admins: after this update, do not roll back to an older version of this mod, and when restoring a backup restore the whole save folder.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]管理面板看得到伺服器紀錄的大小[/b]：「規則」頁最下面多一段「伺服器紀錄」，列出地板與水面、地面覆蓋與牆面疊圖、燈與家電與樓梯平台、線路這四份紀錄各有幾筆、分成幾個檔、多大
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]伺服器記「蓋了什麼、拆了退什麼」的四份紀錄改成分開存檔、格式更省空間[/b]：蓋得多的伺服器，一樓地板的那一份以前全放在一個存檔裡，再多下去會碰到遊戲的單檔大小上限。現在四份紀錄都會自動分成好幾個檔，地板與疊圖的紀錄每一筆佔的空間也小很多。以前蓋的東西照舊能拆、退料不變、線路照舊；玩家與管理員都不用做任何事
[/list]

[h3]🛠️ 給服主[/h3]
[list]
[*] 存檔資料夾會多出 gos_MinidoracatBuilderFloors_1.bin、gos_MinidoracatBuilderOverlays_1.bin、gos_MinidoracatBuilder_1.bin、gos_MinidoracatBuilderCircuits_1.bin（用到才有；一個約 6 MiB 才開下一個）。更新後第一次開服把舊檔裡的紀錄複製過去；之後哪一次開服確認每一筆都讀得回來，才清掉舊檔裡的那一份
[*] 更新後請不要降回舊版：舊版讀不到分開存的紀錄，以前蓋的地板、疊圖、燈與家電會拆不了或不退料，線路會不見
[*] 還原備份時請把整個存檔資料夾一起換回去，不要只蓋回其中幾個檔
[*] 伺服器上所有 MOD 的全域物件系統合計到 100 個時，這個 MOD 不再開新的檔（log 會寫 cannot open another shard）
[/list]
