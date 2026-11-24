# -*- coding: utf-8 -*-
"""寫出地下室土牆與牆角柱的圖塊補丁檔 media/mdcbuilder_basement.patch.tiles（mod.info 的 tiledef=mdcbuilder_basement.patch 5886）。

用法：python scripts/gen_basement_tiles.py（scripts/verify_local.py 比對檔案內容＝build() 的輸出；遊戲路徑用環境變數 PZ_PATH 覆寫）

原版 underground_01_8／9／10／11 沒有任何屬性，本 MOD 的土牆（Basement.DIRT）與外凸轉角的牆角柱（Basement.POST）要它們是牆：
屬性取自原版磚牆 walls_exterior_house_02_96／97／98／99（西牆、北牆、西北角、轉角柱），角的參照改指 underground_01_8／9；
表頭沿用原版 underground_01 的。
格式照 IsoWorld.LoadTileDefinitions（42.22.2 IsoWorld.java:648-760）：檔名結尾 .patch.tiles 時只替已經存在的圖加屬性；
"tdef"＋int32 版本 1＋tileset 數；tileset＝name 行、image 行、int w、h、tileset 編號、格數；格＝int 屬性數＋（鍵行＋值行）×屬性數。
int 是 little-endian，行以 LF 結尾（CR 會丟錯）。
"""
import os
import struct

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "MOD", "MinidoracatBuilderFor42", "Contents", "mods", "MinidoracatBuilderFor42", "42", "media",
                   "mdcbuilder_basement.patch.tiles")
PZ_PATH = os.environ.get("PZ_PATH", r"D:\SteamLibrary\steamapps\common\ProjectZomboid")
VANILLA = os.path.join(PZ_PATH, "media", "tile_definitions", "newtiledefinitions.tiles")

DIRT, BRICK = "underground_01", "walls_exterior_house_02"
RENAME = {f"{BRICK}_96": f"{DIRT}_8", f"{BRICK}_97": f"{DIRT}_9"}


def _i(v):
    return struct.pack("<i", v)


def _line(s):
    return s.encode("latin-1") + b"\n"


def read_tilesets(path, names):
    """{name: (image, w, h, 編號, [[(鍵, 值), …] 每格一份])}，只收 names 裡的 tileset。"""
    with open(path, "rb") as fh:
        data = fh.read()
    pos = 0

    def num():
        nonlocal pos
        pos += 4
        return struct.unpack_from("<i", data, pos - 4)[0]

    def line():
        nonlocal pos
        end = data.index(b"\n", pos)
        s, pos = data[pos:end].decode("latin-1"), end + 1
        return s

    if data[:4] != b"tdef":
        raise ValueError(f"{path}: not tdef")
    pos = 4
    if num() != 1:
        raise ValueError(f"{path}: version != 1")
    found = {}
    for _ in range(num()):
        name, image = line().strip(), line()
        w, h, number, count = num(), num(), num(), num()
        tiles = [[(line(), line()) for _ in range(num())] for _ in range(count)]
        if name in names:
            found[name] = (image, w, h, number, tiles)
            if len(found) == len(names):
                return found
    raise ValueError(f"{path}: 缺 tileset {sorted(set(names) - set(found))}")


def build():
    sets = read_tilesets(VANILLA, {DIRT, BRICK})
    image, w, h, number, _ = sets[DIRT]
    tiles = [[]] * 8 + [[(k, RENAME.get(v, v)) for k, v in props] for props in sets[BRICK][4][96:100]]
    out = b"tdef" + _i(1) + _i(1) + _line(DIRT) + _line(image) + _i(w) + _i(h) + _i(number) + _i(len(tiles))
    for props in tiles:
        out += _i(len(props)) + b"".join(_line(k) + _line(v) for k, v in props)
    return out


if __name__ == "__main__":
    with open(OUT, "wb") as fh:
        fh.write(build())
    print(OUT)
