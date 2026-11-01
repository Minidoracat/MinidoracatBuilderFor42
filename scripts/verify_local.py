# -*- coding: utf-8 -*-
"""Builder 專屬的靜態檢查：scripts/verify_mod.py 第 19 項會呼叫；單獨跑 `python scripts/verify_local.py`。

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


def main():
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
    sys.exit(main())
