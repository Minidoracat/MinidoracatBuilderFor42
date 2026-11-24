# -*- coding: utf-8 -*-
"""寫出地下室土牆的圖塊補丁檔 media/mdcbuilder_basement.patch.tiles（mod.info 的 tiledef=mdcbuilder_basement.patch 5886）。

用法：python scripts/gen_basement_tiles.py（scripts/verify_local.py 比對檔案內容＝build() 的輸出）

原版 underground_01_8／9／10 沒有任何屬性（newtiledefinitions.tiles），本 MOD 的土牆（Basement.DIRT）要它們是牆。
屬性和 Basement Building（Workshop 3806513504）的 aparosa_tiles.patch.tiles 那三格完全相同：兩個 MOD 一起裝，誰先載入結果都一樣。
格式照 IsoWorld.LoadTileDefinitions（42.22.2 IsoWorld.java:648-760）：檔名結尾 .patch.tiles 時只替已經存在的圖加屬性；
"tdef"＋int32 版本 1＋tileset 數；tileset＝name 行、image 行、int w、h、tileset 編號、格數；格＝int 屬性數＋（鍵行＋值行）×屬性數。
int 是 little-endian，行以 LF 結尾（CR 會丟錯）。
"""
import os
import struct

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "MOD", "MinidoracatBuilderFor42", "Contents", "mods", "MinidoracatBuilderFor42", "42", "media",
                   "mdcbuilder_basement.patch.tiles")

# tileset 名、圖、寬、高、編號照 BD 的檔（補丁檔只用名稱找圖；編號要在 1–512 內）
TILESET = ("underground_01", "underground_01.png", 8, 20, 253)
TILES = [{}] * 8 + [
    {"MaterialType": "Brick", "WallW": "", "wall": ""},
    {"MaterialType": "Brick", "WallN": "", "wall": ""},
    {"CornerNorthWall": "underground_01_9", "CornerWestWall": "underground_01_8", "MaterialType": "Brick", "WallNW": "",
     "wall": ""},
]


def _i(v):
    return struct.pack("<i", v)


def _line(s):
    return s.encode("ascii") + b"\n"


def build():
    name, image, w, h, number = TILESET
    out = b"tdef" + _i(1) + _i(1) + _line(name) + _line(image) + _i(w) + _i(h) + _i(number) + _i(len(TILES))
    for props in TILES:
        out += _i(len(props)) + b"".join(_line(k) + _line(v) for k, v in props.items())
    return out


if __name__ == "__main__":
    with open(OUT, "wb") as fh:
        fh.write(build())
    print(OUT)
