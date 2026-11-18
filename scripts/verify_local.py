# -*- coding: utf-8 -*-
"""Builder 專屬的靜態檢查：scripts/verify_mod.py 第 19 項會呼叫；單獨跑 `python scripts/verify_local.py`。
兩項：管理面板規則頁的標籤寬（下面）、呼叫自己的 Lua 函式時固定參數傳齊（檔尾 check_args 的說明）。

管理面板規則頁的選項名稱放得下（client/MinidoracatBuilder/Admin.lua 的 Panel:buildRules，字型 UIFont.Small）：
  數字列（SliderRow）標籤寬 floor(cw*0.45)；下拉列 cw - floor(cw*0.45) - GAP；勾選列照 E2E admin-mp 的估計 cw - 28。
  cw＝規則頁捲動區內寬＝視窗寬 - 2*PAD - 捲軸槽 12（MinidoracatUIFor42 Widgets/ScrollPanel.lua 的 GUTTER）；
  視窗寬取 floor(560*s)，s＝Small 字高/16（Panel.new；頁籤比這寬時視窗跟著變寬，這裡不算，上限偏保守）。
  字寬用 ../pz-family-docs/scripts/i18n_width.py，原版字型與 CatLang（servertest_mdadparts、正式服）各量一次，16 個語言資料夾都量。
  對照 E2E admin-mp 2026-11-01：cw 與標籤寬逐一相同（CatLang：EN／DE／ES／FR／PT cw 672、CH／PL／RU 532），
  只有原版字型的 RU、PL 少算 1 px（210／211、173／174），所以留 1 px。
  實例：ES、PT 的「最遠建造距離」舊譯 336、348 px，上限 302，0.2.0 起被截，到 2026-11-01 跑 E2E 才看到。
"""
import importlib.util
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADMIN = os.path.join(REPO, "MOD", "MinidoracatBuilderFor42", "Contents", "mods", "MinidoracatBuilderFor42", "42",
                     "media", "lua", "client", "MinidoracatBuilder", "Admin.lua")
WIDTH = os.path.join(os.path.dirname(REPO), "pz-family-docs", "scripts", "i18n_width.py")
LANGS = ["EN", "CH", "CN", "JP", "KO", "RU", "ES", "AR", "ES_CL", "ES_MX", "PTBR", "PT", "TR", "FR", "PL", "DE"]
GUTTER = 12     # 捲軸槽：BAR_W 8＋間距 4
CHECKBOX = 28   # 勾選框＋間距（admin-mp 的估計）
TITLE = "管理面板規則頁的選項名稱放得下"


def line_height(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith("common "):
                return int(re.search(r"lineHeight=(\d+)", line).group(1))
    raise SystemExit(f"{path} 沒有 common lineHeight")


def lua_clean(src):
    """註解換成空白、字串內容換成底線（長度與換行不變），之後才能用樣式找呼叫。"""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        long_open = re.match(r"(--)?\[(=*)\[", src[i:]) if c in "-[" else None
        if long_open:
            end = src.find("]" + long_open.group(2) + "]", i)
            end = n if end < 0 else end + len(long_open.group(2)) + 2
            fill = " " if long_open.group(1) else "_"
            body = "".join("\n" if ch == "\n" else fill for ch in src[i:end])
            out.append(body if long_open.group(1) else '"' + body[1:-1] + '"')
            i = end
        elif src.startswith("--", i):
            end = src.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            out.append(c + "_" * (j - i - 1) + c)
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def call_args(text, open_at):
    """open_at 是呼叫的 '('。回 (引數個數, 第一個引數, 最後一個引數)；括號不成對回 None。巢狀函式本體裡的逗號不算。"""
    depth, block, count, start, first, i, n = 0, 0, 0, open_at + 1, None, open_at, len(text)
    while i < n:
        c = text[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                last = text[start:i].strip()
                if last or count:
                    count += 1
                return count, (last if first is None else first), last
        elif c == "," and depth == 1 and block == 0:
            if first is None:
                first = text[start:i].strip()
            count += 1
            start = i + 1
        elif c.isalpha() or c == "_":
            word = re.match(r"\w+", text[i:]).group(0)
            if word == "function" or (block > 0 and word in ("if", "do", "repeat")):
                block += 1
            elif block > 0 and word in ("end", "until"):
                block -= 1
            i += len(word)
            continue
        i += 1
    return None


def expands(arg):
    """引數是不是單獨一個呼叫（放在最後會展開成它全部的回傳值）。有運算子、或整個包在括號裡的只算一個值。"""
    if not arg.endswith(")"):
        return False
    depth, first_zero, i, n = 0, None, 0, len(arg)
    while i < n:
        c = arg[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0 and first_zero is None:
                first_zero = i
        elif depth == 0:
            if c in "+-*/%^#<>=~" or arg.startswith("..", i):
                return False
            if c.isalpha() or c == "_":
                word = re.match(r"\w+", arg[i:]).group(0)
                if word in ("and", "or", "not"):
                    return False
                i += len(word)
                continue
        i += 1
    return not (arg[0] == "(" and first_zero == n - 1)


def short_calls(extra=()):
    """MOD 的 Lua 裡，傳的引數比定義的固定參數少的呼叫。回 [(key, 位置說明)]，key＝檔|函式|傳幾個<要幾個。
    呼叫照「哪個模組的哪個函式」對定義：`Queue.cancel(`、`B.Queue.cancel(`、`local Q = B.Queue` 之後的 `Q.cancel(` 都對
    Queue.lua 的那一個（照名稱對、同名取最少的做法，別的模組有同名而參數較少的函式時會漏）。別名照呼叫的位置找：
    看得到、最近宣告的那個 `local 名稱 = …`（同一個檔裡 `local C = B.Check`、別的函式裡 `local C = B.Cursor` 各對各的），
    `local Plan, L = B.Plan, B.PlanLibrary` 這種平行指派也認。沒前綴的呼叫對同檔最近、還在範圍內的 local 函式，
    `local f = Check.safehouse` 這種別名跟著對；`self:f(` 對同檔的方法；認不出接收者的 `obj:f(` 照方法名對（同名取
    最少的），`x.f(` 不看（別人的表或欄位裡的函式：`ArrayList.new()`、`UI.Button.new`）。
    最後一個引數是 ... 的不報；是單獨一個呼叫的（會展開成好幾個值）當一個算、照報，key 的 < 換成 ~、後面接那個
    呼叫的函式名（換成別的函式就不算 baseline 裡那一筆）。
    定義只認 `function A.b(…)`、`function A:b(…)`、`local function b(…)`、`A.b = function(…)`（表建構式裡的欄位不算）；
    `pcall(f, …)` 當成呼叫 f。extra＝另外要看的目錄或檔（harness、E2E 情境）：只看裡面的呼叫。
    回的第三項：對到的定義是不是 MOD 的（extra 的檔自己的函式是 False）。"""
    lua_root = os.path.dirname(os.path.dirname(os.path.dirname(ADMIN)))   # …/media/lua
    name_re = r"[A-Za-z_]\w*"
    chain_re = rf"{name_re}(?:\.{name_re})*"
    texts, defs, def_parens, roots, mods, aliases, ours = {}, {}, set(), {}, {}, {}, set()

    def split_top(src):
        out, depth, cur = [], 0, ""
        for ch in src:
            depth += (ch in "({[") - (ch in ")}]")
            if ch == "," and depth == 0:
                out.append(cur.strip())
                cur = ""
            else:
                cur += ch
        return out + [cur.strip()]

    def fixed(params):
        return len([p for p in (q.strip() for q in params.split(",")) if p and p != "..."])

    def scope_end(text, pos):
        """local 函式看得到的範圍：到縮排比它淺的下一行（外層區塊收尾）為止；頂層的到檔尾。"""
        start = text.rfind("\n", 0, pos) + 1
        indent = len(text[start:pos]) - len(text[start:pos].lstrip())
        if indent:
            for m in re.finditer(r"\n([ \t]*)\S", text[pos:]):
                if len(m.group(1)) < indent:
                    return pos + m.start() + 1
        return len(text)

    def add(name, path, pos, table, form, params, local):
        text = texts[path]
        defs.setdefault(name, []).append({
            "path": path, "line": text.count("\n", 0, pos) + 1, "pos": pos, "table": table, "form": form,
            "need": fixed(params), "local": local, "end": scope_end(text, pos) if local else len(text)})

    def scan(path):
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = texts[path] = lua_clean(fh.read())
        # local a, b = e1, e2：（位置, 看得到的範圍結尾, 名稱, 運算式）
        aliases[path] = [(m.end(1), scope_end(text, m.end(1)), n.strip(), e)
                         for m in re.finditer(rf"^([ \t]*)local\s+({name_re}(?:\s*,\s*{name_re})*)\s*=\s*(.+)$", text, re.M)
                         for n, e in zip(m.group(2).split(","), split_top(m.group(3)))]
        roots[path] = {"MinidoracatBuilder"} | {a[2] for a in aliases[path] if a[3] == "MinidoracatBuilder"}
        root = "|".join(sorted(roots[path]))
        mods[path] = {t: x for x, t in re.findall(rf"^[ \t]*(?:{root})\.({name_re})\s*=\s*({name_re})[ \t]*$", text, re.M)}
        for m in re.finditer(rf"(local\s+)?\bfunction\s+({chain_re})(?::({name_re}))?\s*\(([^)]*)\)", text):
            local, dotted, method, params = m.groups()
            def_parens.add((path, text.index("(", m.start(2))))
            if method:
                add(method, path, m.start(), dotted, "colon", params, False)
            elif "." in dotted:
                add(dotted.rsplit(".", 1)[1], path, m.start(), dotted.rsplit(".", 1)[0], "dot", params, False)
            else:
                add(dotted, path, m.start(), None, "bare", params, bool(local))
        for m in re.finditer(rf"^[ \t]*(local\s+)?({chain_re})\s*=\s*function\s*\(([^)]*)\)", text, re.M):
            local, dotted, params = m.groups()
            if "." in dotted:
                add(dotted.rsplit(".", 1)[1], path, m.start(), dotted.rsplit(".", 1)[0], "dot", params, False)
            else:
                add(dotted, path, m.start(), None, "bare", params, bool(local))

    def lua_files(top):
        if os.path.isfile(top):
            return [top]
        return sorted(os.path.join(folder, name) for folder, _, names in os.walk(top) for name in names if name.endswith(".lua"))

    for path in lua_files(lua_root):
        scan(path)
        ours.add(path)
    for top in extra:
        for path in lua_files(os.path.abspath(top)):
            if path not in texts:
                scan(path)
    modkeys = {x for path in ours for x in mods[path].values()}

    def alias_of(path, name, at):
        """呼叫位置看得到、最近宣告的 `local name = 運算式` 的運算式；沒有回 None。"""
        seen = [a for a in aliases[path] if a[2] == name and a[0] < at < a[1]]
        return max(seen)[3] if seen else None

    def modkey(path, chain, at):
        """at 這個位置，a.b 這種接收者指的是哪個模組（MinidoracatBuilder.X 的 X）；認不出回 None。"""
        comps = chain.split(".")
        if len(comps) == 2 and comps[0] in roots[path]:
            return comps[1] if comps[1] in modkeys else None
        if len(comps) == 1:
            expr = alias_of(path, chain, at)
            m = expr and re.fullmatch(rf"({name_re})\.({name_re})(?:\s+or\s+\{{\s*\}})?", expr)
            if m and m.group(1) in roots[path]:
                return m.group(2) if m.group(2) in modkeys else None
            return mods[path].get(chain) or (chain if expr is None and chain in modkeys else None)
        return None

    def of_module(name, key):
        return [d for d in defs.get(name, []) if d["path"] in ours and d["form"] != "bare" and d["table"]
                and modkey(d["path"], d["table"], d["pos"]) == key]

    def receiver(text, at):
        """at 是呼叫名稱前面那個 . 或 : 的位置。回接收者（a.b 這種一串名字）；前面是運算式（x[i].f、g().f）回 None。"""
        head = text[max(0, at - 160):at]
        m = re.search(rf"({chain_re})\s*$", head)
        return None if not m or head[:m.start()].rstrip()[-1:] in (".", ":") else m.group(1)

    keywords = {"if", "and", "or", "not", "return", "while", "until", "elseif", "in", "function", "for", "do", "then", "else", "end", "local"}
    hits = []
    for path, text in texts.items():
        rel = os.path.relpath(path, lua_root if path in ours else REPO).replace(os.sep, "/")
        for m in re.finditer(rf"([.:]?)\b({name_re})\s*\(", text):
            sep, name = m.groups()
            open_at = m.end() - 1
            if name in keywords or (path, open_at) in def_parens:
                continue
            got = call_args(text, open_at)
            if not got:
                continue
            count, first, last = got
            chain = receiver(text, m.start()) if sep else None
            if name == "pcall" and sep == "" and re.fullmatch(chain_re, first or ""):
                chain, name, count = first.rpartition(".")[0] or None, first.rsplit(".", 1)[-1], count - 1
                sep = "." if chain else ""
            named = defs.get(name, [])
            if sep == "":
                here = [d for d in named if d["form"] == "bare" and d["path"] == path]
                scoped = [d for d in here if d["local"] and d["pos"] < m.start() < d["end"]]
                alias = alias_of(path, name, m.start())
                alias = alias if alias and re.fullmatch(rf"{name_re}(?:\.{name_re})+", alias) else None
                if scoped:
                    cands = [max(scoped, key=lambda d: d["pos"])]
                elif [d for d in here if not d["local"]]:   # 先宣告、後面才 `f = function` 的
                    cands = [d for d in here if not d["local"]]
                elif alias:
                    key = modkey(path, alias.rpartition(".")[0], m.start())
                    cands = of_module(alias.rsplit(".", 1)[1], key) if key else []
                    sep = "."
                else:
                    cands = [d for d in named if d["form"] == "bare" and not d["local"] and d["path"] in ours]
            else:
                key = chain and modkey(path, chain, m.start())
                mine = [d for d in named if d["form"] != "bare" and d["path"] == path]
                if key:
                    cands = of_module(name, key)
                elif chain == "self" and mine:
                    cands = mine
                elif chain and [d for d in mine if d["table"] == chain]:
                    cands = [d for d in mine if d["table"] == chain]
                elif sep == ":":   # 認不出是誰的方法呼叫：照方法名，同名取最少的
                    cands = [d for d in named if d["path"] in ours and d["form"] == "colon"]
                else:              # 別人的表或欄位裡的函式
                    cands = []
            if not cands or last == "...":
                continue
            need = min(d["need"] + (1 if sep == "." and d["form"] == "colon" else -1 if sep == ":" and d["form"] == "dot" else 0)
                       for d in cands)
            if count < need:
                d = min(cands, key=lambda d: d["need"])
                line = text.count("\n", 0, m.start()) + 1
                tail = expands(last)
                callee = re.match(rf"\s*({chain_re}(?::{name_re})?)\s*\(", last) if tail else None
                hits.append((f"{rel}|{name}|{count}{'~' if tail else '<'}{need}" + (f"|{callee.group(1) if callee else '?'}" if tail else ""),
                             f"{rel}:{line}  {name} 傳 {count} 個{'（最後一個是呼叫，它回幾個值要自己看）' if tail else ''}、"
                             f"定義 {need} 個（{os.path.basename(d['path'])}:{d['line']}）", d["path"] in ours))
    return hits


ARGS_TITLE = "呼叫自己的 Lua 函式時固定參數傳齊（Kahlua 不補 nil）"
ARGS_BASE = os.path.join(REPO, "scripts", "kahlua_args_baseline.txt")
ARGS_FIXTURE = os.path.join(REPO, "scripts", "kahlua_args_fixture.lua")


def check_args(rebase):
    """Kahlua 不替少傳的固定參數補 nil：OP_CALL 平常會把引數後面的堆疊清掉，但陣列建構式最後一項是呼叫或 ... 之後
    （OP_SETLIST 不還原堆疊頂端）到下一個呼叫回來之前不清，少傳的參數讀到舊值（KahluaThread.java:604-613,839-859、
    LuaCallFrame.java:96-109；家族 pitfalls「少傳的參數不保證是 nil」）。標準 Lua 的 harness 驗不到。
    實例：2026-10-31 宣傳片情境 cellsX(4, 8, 1) 的 z 收到 2；2026-11-19 L.saveFirst 加了選用的第三個固定參數、
    既有呼叫點只傳兩個（第二條審查線讀碼抓到）。
    既有的少傳記在 scripts/kahlua_args_baseline.txt（每行：次數、檔|函式|傳幾個<要幾個），只有比它多才 FAIL。
    每次先拿 scripts/kahlua_args_fixture.lua 驗檢查本身：標 --! 的行要報、其他行不報。"""
    hits = short_calls([ARGS_FIXTURE])
    fixture = os.path.relpath(ARGS_FIXTURE, REPO).replace(os.sep, "/")
    with open(ARGS_FIXTURE, encoding="utf-8") as fh:
        want = {i for i, line in enumerate(fh, 1) if "--!" in line}
    seen = {int(where.split("  ")[0].rsplit(":", 1)[1]) for key, where, _ in hits if key.startswith(fixture + "|")}
    if seen != want:
        print(f"  FAIL  {ARGS_TITLE}：檢查本身壞了（{fixture} 標 --! 的行 {sorted(want)}，實際報的行 {sorted(seen)}）")
        return 1
    hits = [h for h in hits if not h[0].startswith(fixture + "|")]
    now = {}
    for key, where, _ in hits:
        now.setdefault(key, []).append(where)
    if rebase:
        with open(ARGS_BASE, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("# 既有的「固定參數少傳」呼叫（scripts/verify_local.py 的 check_args）。只會變少：改掉一處就重跑\n"
                     "# python scripts/verify_local.py --rebase-args。不要為了讓新的呼叫通過而重跑：少的補 nil 傳齊，\n"
                     "# 或把選用參數改成 ... 接。只有確定呼叫的是 Java 方法，或最後一個引數的呼叫確定每條路都回夠多個值\n"
                     "# （key 裡是 ~，後面是那個呼叫的函式名）才加進來。\n")
            for key in sorted(now):
                fh.write(f"{len(now[key])}\t{key}\n")
        print(f"  note  {ARGS_TITLE}：baseline 重寫，{len(hits)} 處")
        return 0
    base = {}
    if os.path.isfile(ARGS_BASE):
        with open(ARGS_BASE, encoding="utf-8") as fh:
            for line in fh:
                if line.strip() and not line.startswith("#"):
                    n, key = line.rstrip("\n").split("\t", 1)
                    base[key] = int(n)
    bad = [f"{w}" + (f"（這個檔同樣的呼叫 baseline 只有 {base[key]} 處）" if key in base else "")
           for key in sorted(now) if len(now[key]) > base.get(key, 0) for w in now[key]]
    if bad:
        print(f"  FAIL  {ARGS_TITLE}")
        for b in bad:
            print(f"        {b}")
        print("        少的補 nil 傳齊，或把選用參數改成 ... 接（local a, b = ...；例 PlanLibrary.lua 的 L.saveFirst）。"
              "確定呼叫的是 Java 方法才 python scripts/verify_local.py --rebase-args")
        return 1
    print(f"  PASS  {ARGS_TITLE}（新增 0 處；既有 {len(hits)} 處記在 baseline）")
    return 0


def check_rules():
    if not os.path.isfile(WIDTH):
        print(f"  SKIP  {TITLE} — 找不到 {WIDTH}")
        return 0
    spec = importlib.util.spec_from_file_location("i18n_width", WIDTH)
    iw = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(iw)
    if not os.path.isdir(iw.FONTS):
        print(f"  SKIP  {TITLE} — 找不到遊戲字型 {iw.FONTS}（設定 PZ_PATH）")
        return 0
    with open(ADMIN, encoding="utf-8") as fh:
        src = fh.read()
    pad_gap = re.search(r"local PAD, GAP = (\d+), (\d+)", src)
    base = re.search(r"math\.max\(math\.floor\((\d+) \* s\)", src)
    frac = set(re.findall(r"math\.floor\(cw \* ([\d.]+)\)", src))
    rules = re.findall(r'\{ key = "(\w+)", kind = "(\w+)"', src.split("Admin.RULES = {", 1)[-1].split("\n}", 1)[0])
    if not (pad_gap and base and len(frac) == 1 and rules) or any(k not in ("bool", "enum", "number") for _, k in rules):
        print(f"  FAIL  {TITLE}\n        Admin.lua 的版面寫法改了（PAD／GAP、視窗寬、cw 比例或 Admin.RULES 認不出來）："
              "照新版面更新 scripts/verify_local.py")
        return 1
    pad, gap, frac = int(pad_gap[1]), int(pad_gap[2]), float(frac.pop())
    texts = {}
    for tdir in iw.translate_dirs(REPO):
        for lang in LANGS:
            path = os.path.join(tdir, lang, "Sandbox.json")
            if os.path.isfile(path):
                with open(path, encoding="utf-8") as fh:
                    texts.setdefault(lang, {}).update(json.load(fh))
    bad, n = [], 0
    for fonts, tag in (([], "原版字型"), ([iw.CATLANG_FONTS], "CatLang")):
        if fonts and not os.path.isdir(iw.CATLANG_FONTS):
            print(f"  note  {TITLE}：找不到 {iw.CATLANG_FONTS}，只量原版字型")
            continue
        iw.MOD_FONTS[:] = fonts
        iw._font_paths.clear()
        for lang, table in texts.items():
            cw = int(base[1]) * line_height(iw.font_file(lang, "Small")) // 16 - 2 * pad - GUTTER
            label_w = int(cw * frac)
            room = {"number": label_w, "enum": cw - label_w - gap, "bool": cw - CHECKBOX}
            for key, kind in rules:
                text = table.get("Sandbox_MinidoracatBuilder_" + key)
                if text is None:
                    continue   # 缺鍵歸 verify_mod 第 3 項
                w = iw.width(text, lang, "Small")
                n += 1
                if w + 1 > room[kind]:
                    bad.append(f"{lang}（{tag}）{key}：{w} px，放得下 {room[kind] - 1} px（cw {cw}，{kind}）「{text}」")
    if bad:
        print(f"  FAIL  {TITLE}")
        for b in bad:
            print(f"        {b}")
        print("        改短譯文；量字寬：python ../pz-family-docs/scripts/i18n_width.py [--catlang] keys <鍵>")
        return 1
    print(f"  PASS  {TITLE}（{n} 筆，原版字型與 CatLang）")
    return 0


if __name__ == "__main__":
    if "--args-also" in sys.argv:   # 盤點用：連 harness、E2E 情境裡的呼叫一起列（只列對到 MOD 定義的），只列不判
        found = short_calls(sys.argv[sys.argv.index("--args-also") + 1:])
        for _, where, mod in found:
            if mod:
                print(where)
        print(f"另有 {sum(1 for h in found if not h[2])} 處是這些檔自己的函式被少傳（沒列）")
        sys.exit(0)
    sys.exit(check_rules() | check_args("--rebase-args" in sys.argv))
