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


def short_calls():
    """MOD 的 Lua 裡，傳的引數比定義的固定參數少的呼叫。回 [(key, 位置說明)]，key＝檔|函式|傳幾個<要幾個。
    只報確定少傳的：最後一個引數是呼叫或 ... 的（個數不定）不報；同名函式有好幾個定義時照最少的那個算。
    定義只認 `function A.b(…)`、`function A:b(…)`、`local function b(…)`、`A.b = function(…)`（表建構式裡的欄位不算）；
    沒前綴的呼叫只對同檔的 local 函式與全域函式；`pcall(f, …)` 當成呼叫 f。"""
    lua_root = os.path.dirname(os.path.dirname(os.path.dirname(ADMIN)))   # …/media/lua
    defs, texts, def_parens = {}, {}, set()
    name_re = r"[A-Za-z_]\w*"

    def fixed(params):
        return len([p for p in (q.strip() for q in params.split(",")) if p and p != "..."])

    def add(name, path, pos, form, params, local):
        defs.setdefault(name, []).append((path, texts[path].count("\n", 0, pos) + 1, form, fixed(params), local))

    for folder, _, names in os.walk(lua_root):
        for name in sorted(names):
            if not name.endswith(".lua"):
                continue
            path = os.path.join(folder, name)
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = texts[path] = lua_clean(fh.read())
            for m in re.finditer(rf"(local\s+)?\bfunction\s+({name_re}(?:\.{name_re})*)(?::({name_re}))?\s*\(([^)]*)\)", text):
                local, dotted, method, params = m.groups()
                def_parens.add((path, text.index("(", m.start(2))))
                if method:
                    add(method, path, m.start(), "colon", params, False)
                elif "." in dotted:
                    add(dotted.rsplit(".", 1)[1], path, m.start(), "dot", params, False)
                else:
                    add(dotted, path, m.start(), "bare", params, bool(local))
            for m in re.finditer(rf"^[ \t]*(local\s+)?({name_re}(?:\.{name_re})*)\s*=\s*function\s*\(([^)]*)\)", text, re.M):
                local, dotted, params = m.groups()
                if "." in dotted:
                    add(dotted.rsplit(".", 1)[1], path, m.start(), "dot", params, False)
                else:
                    add(dotted, path, m.start(), "bare", params, bool(local))

    keywords = {"if", "and", "or", "not", "return", "while", "until", "elseif", "in", "function", "for", "do", "then", "else", "end", "local"}
    hits = []
    for path, text in texts.items():
        rel = os.path.relpath(path, lua_root).replace(os.sep, "/")
        for m in re.finditer(rf"([.:]?)\b({name_re})\s*\(", text):
            sep, name = m.groups()
            open_at = m.end() - 1
            if name in keywords or (path, open_at) in def_parens:
                continue
            got = call_args(text, open_at)
            if not got:
                continue
            count, first, last = got
            if name == "pcall" and sep == "" and re.fullmatch(rf"{name_re}(?:\.{name_re})*", first or ""):
                sep, name, count = ("." if "." in first else ""), first.rsplit(".", 1)[-1], count - 1
            cands = defs.get(name, [])
            if sep == "":
                cands = [d for d in cands if d[2] == "bare" and (not d[4] or d[0] == path)]
            else:
                cands = [d for d in cands if d[2] != "bare"]
            if not cands or last.endswith(")") or last == "...":
                continue
            need = min(d[3] + (1 if sep == "." and d[2] == "colon" else -1 if sep == ":" and d[2] == "dot" else 0) for d in cands)
            if count < need:
                d = min(cands, key=lambda d: d[3])
                line = text.count("\n", 0, m.start()) + 1
                hits.append((f"{rel}|{name}|{count}<{need}",
                             f"{rel}:{line}  {name} 傳 {count} 個、定義 {need} 個（{os.path.basename(d[0])}:{d[1]}）"))
    return hits


ARGS_TITLE = "呼叫自己的 Lua 函式時固定參數傳齊（Kahlua 不補 nil）"
ARGS_BASE = os.path.join(REPO, "scripts", "kahlua_args_baseline.txt")


def check_args(rebase):
    """Kahlua 不替少傳的固定參數補 nil：OP_CALL 平常會把引數後面的堆疊清掉，但陣列建構式最後一項是呼叫或 ... 之後
    （OP_SETLIST 不還原堆疊頂端）到下一個呼叫回來之前不清，少傳的參數讀到舊值（KahluaThread.java:604-613,839-859、
    LuaCallFrame.java:96-109；家族 pitfalls「少傳的參數不保證是 nil」）。標準 Lua 的 harness 驗不到。
    實例：2026-10-31 宣傳片情境 cellsX(4, 8, 1) 的 z 收到 2；2026-11-19 L.saveFirst 加了選用的第三個固定參數、
    既有呼叫點只傳兩個（第二條審查線讀碼抓到）。
    既有的少傳記在 scripts/kahlua_args_baseline.txt（每行：次數、檔|函式|傳幾個<要幾個），只有比它多才 FAIL。"""
    hits = short_calls()
    now = {}
    for key, where in hits:
        now.setdefault(key, []).append(where)
    if rebase:
        with open(ARGS_BASE, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("# 既有的「固定參數少傳」呼叫（scripts/verify_local.py 的 check_args）。只會變少：改掉一處就重跑\n"
                     "# python scripts/verify_local.py --rebase-args。不要為了讓新的呼叫通過而重跑：少的補 nil 傳齊，\n"
                     "# 或把選用參數改成 ... 接。只有確定呼叫的是 Java 方法（例 ArrayList.new()）才加進來。\n")
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
    sys.exit(check_rules() | check_args("--rebase-args" in sys.argv))
