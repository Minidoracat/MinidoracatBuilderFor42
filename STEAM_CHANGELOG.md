[h1]Minidoracat Build Anything for B42 42.22.2-1.1.1[/h1]
[i]2026-11-21[/i]

[b]English summary[/b]
[list]
[*] Fixed: ramp pieces built one at a time before 1.0.0 could not be dismantled when other ramp pieces surrounded them. The character tried to stand on the next ramp tile, and "Dismantle an area" stopped without removing anything (since 1.0.0). You now stand on flat ground next to them, and surrounded pieces wait until the one beside them is gone.
[*] To extend an old ramp: dismantle the old pieces in the way with "Dismantle an area" (each refunds its plank and nail), then place a full set.
[*] Fixed: the dismantle menu listed every old ramp piece under the same name (since 1.0.0). Each row now shows its own number.
[*] Still open: right-clicking a single old piece that is surrounded by ramp pieces still walks around to the bottom of the ramp (about 20 seconds). "Dismantle an area" avoids that.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]舊版一片一片蓋的坡道片拆不掉[/b]（1.0.0 起）：1.0.0 以前的坡道是一片一片蓋的，之後舊的那些片照地板拆。被其他坡道片圍在中間的舊片，角色會想站到隔壁的坡道格上去拆，得繞到坡底再爬上去；走不到時，「拆除一區」會一件都沒拆就停下來。現在改成站在旁邊的平地；四周都是坡道片的那幾片，等旁邊那片先拆平，再站過去拆。
[*] [b]舊坡道旁邊要接新的坡道[/b]：先用「拆除一區」把擋路的舊片框起來拆掉（每片照舊退木板與釘子），再放一整組。
[*] [b]拆除選單裡，舊的坡道片每一列都是同一個名字[/b]（1.0.0 起）：在斜面上按右鍵一次點到好幾片時，分不出哪一列是哪一片；現在各列寫各自的編號。
[*] [b]還沒修的[/b]：按右鍵只拆一片、而那一片四周都是坡道片時，角色仍會繞到坡底再爬上去（約 20 秒）；用「拆除一區」框起來拆就不會繞。
[/list]

[b]伺服器管理員[/b]：這版只改玩家端拆除時的走路與選單名稱，沒有新的沙盒選項。
