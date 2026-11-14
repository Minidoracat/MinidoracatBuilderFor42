<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3830047545 -->
<!-- Steam guide source (English). The full description lives in this guide; the Workshop page only has a summary. Format and sync: pz-family-docs/release.md "完整說明：Steam 指南" -->
<!-- 標題：📖 Minidoracat Build Anything Mod Guide: Build Window, Materials, Wiring and Dismantling -->
<!-- 摘要：A picture guide to Minidoracat Build Anything: searching, tabs, sources and favorites in the build window, the eyedropper and picking a tile with a right-click, full sets, build recipes from vanilla and other mods, placing and dragging rows, the rules for walls, posts, doors and windows, curtains, stairs, roofs, furniture, lights and containers, materials, tools and XP, the hardcore options (skill levels and vanilla recipe materials), switches and wiring, dismantling and gamepad controls, plus the admin panel, the sandbox options, how to turn off other mods' facilities, the API for mod authors, known limitations and what to do before removing the mod. -->
<!-- Screenshots: docs/screenshots/steam/en/ -->
=== 🚀 Quick start
[b]中文版：[/b] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3830047491]Minidoracat Build Anything MOD 完整說明[/url]
https://steamcommunity.com/sharedfiles/filedetails/?id=3830045886
Build with any loaded tile, including other mods' tile packs; you pay for what you build with materials. Recipes from the vanilla build menu (rain collectors, forges and the like) are listed too and built with the vanilla recipe.
{{img:01-overview-en.jpg}}
[olist]
[*] [b]Open the window[/b]: click the Build Anything button on the family toolbar (a hammer and a handsaw).
[*] [b]Find something[/b]: search by name, narrow it down with the tabs, kinds, tilesets and sources, or use the eyedropper left of the search bar to click something in the world.
[*] [b]Check the details[/b]: select an item, and the right side lists materials, tools, XP and how it is removed.
[*] [b]Place it[/b]: press Build or double-click the item, then click the ground.
[*] [b]Drag a row[/b]: hold the left button and drag to build a row of walls, posts, floors, fences or roofs.
[*] [b]Pay for it[/b]: keep the materials in your bags or on the ground next to you, and your character walks over and builds.
[/olist]
[h3]Requirements[/h3]
[list]
[*] [b]Required[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library[/url]
[*] [b]Optional[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3819478078]Minidoracat Safehouse[/url], whose safehouse permissions decide where you can build.
[/list]
[h3]Where it works[/h3]
[list]
[*] [b]Singleplayer and multiplayer[/b]: in multiplayer the server must enable this mod.
[*] [b]The server decides[/b]: what can be built and what it costs are checked by the server.
[*] [b]Split screen[/b]: only the first player can open Build Anything.
[*] [b]Adding mid-save[/b]: fine.
[*] [b]Removing mid-save[/b]: everything you built stays, but a few things change, so read Before removing this mod first.
[/list]
[h3]Other ways to open the window[/h3]
[list]
[*] [b]Hotkey[/b]: none by default, so set Open or close the build window under Minidoracat Build Anything in OPTIONS > KEY BINDINGS.
[*] [b]Hide the toolbar button[/b]: untick Show toolbar button in OPTIONS > MODS > Build Anything, then use the hotkey.
[*] [b]First time[/b]: after you enter the game the tiles are cataloged and the window shows Cataloging tiles N%, but you can already search what is done so far.
[/list]
=== 🧰 The build window
{{img:02-search-en.jpg}}
[h3]Finding things[/h3]
[list]
[*] [b]Search[/b]: by name, tileset, source mod or full tile name.
[*] [b]Full tile names[/b]: search a full name (blends_street_01_101, for example), and if it is in the list, that item is selected.
[*] [b]Leaving a full-name search[/b]: switching to another tab, kind, tileset or source clears the full name from the search bar and lists by the new choice.
[*] [b]Other looks of a tile[/b]: an open door, a smashed window, a closed curtain, one square of a multi-square object and the like select the item they belong to.
[*] [b]Tiles you can't build[/b]: searching a full name tells you why, for example which build recipe it belongs to or which kind the admin turned off.
[*] [b]Tabs[/b]: All, Floors, Walls, Doors & windows, Roofs, Stairs, Furniture, Lights, Decor.
[*] [b]Left side[/b]: Mine (Favorites, Recently used), Kinds, Build recipes and Tilesets, with item counts in parentheses.
[*] [b]Sub-kinds[/b]: picking the Light, Furniture, Container, Plants or Floor overlay kind splits it one level further, again with item counts. Light: Light Switches, Lamps, Signs and Street Lights. Furniture: Wall Art and Posters, Rugs, Tables, Beds and Seating, Tabletop Items, Other. Container: by name (for example Cupboard, Shelves, Fridge), one row for each of the 8 largest groups and Other for the rest. Plants: Ornamental Plants, Grass and Wildflowers. Floor overlay: Curbs and Edging (curb stones and the edge strips where two ground types meet), Road Markings, Cracks and Grime, Other.
[*] [b]Finding light switches[/b]: Lights tab, pick Light on the left, then Light Switches; or just search "switch".
[*] [b]Only what I can build[/b]: lists only items you have the materials and tools for, counting your inventory, bags and items on the ground next to you.
[*] [b]Material[/b]: pick planks, metal, brick and stone, glass or logs to list only items whose cost includes that material; Other is everything that uses none of them, such as cloth or electronics. It doesn't look at what you carry, and it works together with Only what I can build. Hardware such as nails and screws doesn't count.
[*] [b]One item per object[/b]: the facings of one object are one item.
[*] [b]Different objects with the same name[/b]: each is listed separately.
[*] [b]Same name, one tile per facing[/b]: tiles in one tileset with the same name and exactly one tile per facing (some mods' photocopiers, for example) are listed separately, and you can rotate between them while placing.
[*] [b]Order[/b]: items from the same tileset are sorted by number.
[*] [b]Nothing found[/b]: an empty list tells you why, for example try a shorter word, or switch to All sources and the All tab.
[*] [b]Kinds the admin turned off[/b]: you can't see or build them, the status line says the admin turned off N kinds, and a tab whose kinds are all off can't be selected. Wells and Hand Pumps and Water are off by default and are not counted in N.
[*] [b]When the admin changes settings[/b]: an open window follows within a few seconds, so there is no need to reopen it.
[/list]
[h3]Eyedropper and Pick tile[/h3]
{{img:15-pick-en.jpg}}
[list]
[*] [b]Eyedropper[/b]: press the eyedropper button left of the search bar (Pick from the world), the window hides, and clicking something in the world selects it.
[*] [b]Tall things[/b]: click the image of a wall or a light to pick the square it stands on, with no need to find the ground at its foot.
[*] [b]Several images on one square[/b]: a list pops up to choose from.
[*] [b]Cancel the eyedropper[/b]: right-click, and the window comes back.
[*] [b]Pick tile with a right-click[/b]: right-click the ground and choose Pick tile (Build Anything).
[*] [b]What it lists[/b]: every image on that square, including overlays on the floor and on walls.
[*] [b]Pick one[/b]: Build Anything opens with that item selected.
[*] [b]Tiles you can't build[/b]: shown in red, and hovering one tells you why.
[*] [b]Gamepad[/b]: there is no eyedropper button, so use Pick tile from the right-click menu as before.
[/list]
[h3]Sources[/h3]
{{img:13-mods-en.jpg}}
[list]
[*] [b]Source menu[/b]: All sources, Vanilla, and every mod with tiles.
[*] [b]After picking a source[/b]: the kind counts and tilesets on the left only count that source.
[*] [b]Sources the admin turned off[/b]: not in the menu, and hovering the source menu shows which ones are off.
[/list]
[h3]The grid[/h3]
[list]
[*] [b]Tiles per row[/b]: the Per row slider under the search bar sets 2 to 10, saved on your computer.
[*] [b]Window size[/b]: widen the window and the cells widen with it.
[*] [b]Names[/b]: up to two lines, showing the tileset and number.
[*] [b]Double-click[/b]: double-clicking an item starts placing it, the same as selecting it and pressing Build; a single click only selects it and shows the details.
[*] [b]Items you can't afford[/b]: the name is dimmed with a warning in the top right, and you can still select and build them.
[*] [b]Items your skill is too low for[/b]: when the server turns on Require vanilla skill levels, they are dimmed with a warning too, and you can build them once you reach that level.
[*] [b]Favorites[/b]: select an item and press Add to favorites, saved on your computer and kept across servers.
[*] [b]Recently used[/b]: items you pressed Build on are listed under Recently used.
[/list]
[h3]Details[/h3]
{{img:03-detail-en.jpg}}
[list]
[*] [b]Source[/b]: Source: mod name (tileset), and a long tileset name wraps instead of being cut off.
[*] [b]Tile name[/b]: Tile: shows the full tile name, ready to copy when you report a problem or search.
[*] [b]Footprint[/b]: how many squares it covers and how many facings it has.
[*] [b]Flagged first[/b]: permanently locked windows and things that can only be smashed for no materials are listed before the materials, with a warning.
[*] [b]Removal[/b]: how it is removed later and what you get back, see Dismantling.
[*] [b]Materials (have / need)[/b]: how many of each material you have and need.
[*] [b]Tools (carry them)[/b]: tools you must carry while building, which don't wear out.
[*] [b]Skill[/b]: when the server turns on Require vanilla skill levels, an extra line such as Skill: Carpentry 2, with your level and a warning when it's too low.
[*] [b]Consumables[/b]: when the server turns on Vanilla recipe materials, clay cement, torch fuel and welding rods are shown as have / need uses.
[*] [b]Experience[/b]: which skill gets how much XP, or Experience: none.
[*] [b]Notes[/b]: kinds with extra rules, such as stairs, roofs, lights and curtains, get a note.
[*] [b]Scrolling[/b]: when the details are taller than the window, scroll with the mouse wheel or the scroll bar.
[*] [b]Admin shortcuts[/b]: see Admin panel.
[/list]
[h3]Full set[/h3]
{{img:16-set-en.jpg}}
[list]
[*] [b]How[/b]: select a wall, post, window frame or door frame, and press Full set above Build in the details.
[*] [b]What it lists[/b]: only the walls, posts, window frames and door frames of the same set.
[*] [b]Cells show the position[/b]: for example Wall W, Wall N, Corner, Post, Window W, Door N.
[*] [b]Back to your list[/b]: press the ✕ on the filter button above the search bar.
[*] [b]Changing tab, source or search[/b]: leaves the set.
[*] [b]Same tileset[/b]: when the tile sheet isn't laid out like vanilla walls, the button reads Same tileset and lists the walls, posts, frames, fences and wall overlays of that tileset.
[*] [b]When it can't be pressed[/b]: the item isn't a wall piece, or the set has fewer than two items.
[/list]
=== 🧰 Build recipes
[list]
[*] [b]What's listed[/b]: every recipe you can see in the vanilla build menu, including ones other mods add, for example rain collectors, forges, wooden walls and stairs.
[*] [b]Where[/b]: on the tab and kind that match their look, with Recipe in the bottom-left corner of the cell, listed after the tiles on that tab. Build recipes on the left lists them by the vanilla build menu's categories, for example Recipe: Carpentry.
[*] [b]Details[/b]: the source and the vanilla category, then materials, tools (kept) and skills, counted the same way as in the vanilla build menu.
[*] [b]Building[/b]: press Build or double-click the item to open the vanilla placing cursor. Materials, tools, skills and time all work as in vanilla.
[*] [b]Dragging a row[/b]: wall, fence and post recipes (and floor or roof recipes other mods add) drag like tiles of the same kind: hold the left button to drag a row, or drag diagonally for a rectangle. After you release, the squares are built one after another, each one a normal vanilla build. When materials only cover some squares, only those are white. If you're interrupted or can't get there, the row stops and a notice says how many were built; if you run out of materials, tools or skill it stops and says what's missing. Dragging another row cancels the squares the last one hadn't built, and the cursor tells you how many before you release. With a controller you place one at a time.
[*] [b]Wall paint, wallpaper and plaster[/b]: as in the vanilla build menu, the cursor doesn't open while materials, tools or skills are missing, and a notice says the details show what's missing.
[*] [b]After placing[/b]: the cursor stays so you can place another, and it blocks when you run out of materials. Right-click (B on a gamepad) to go back to Build Anything.
[*] [b]Recipes you haven't learned[/b]: they follow the vanilla sandbox option See Not Known Recipes. When it's on (the default) they're listed, and the cell and details say you haven't learned them yet; when it's off they appear once you learn them.
[*] [b]Too dark[/b]: as in vanilla, recipes can't be built in the dark; the cell is marked missing and the details say it's too dark. A lit flashlight or lamp held in your hands or attached to you is enough.
[*] [b]Recipes that change with skill[/b]: wooden walls and others that change with your skill level show only your tier, as in vanilla.
[*] [b]Admin switches[/b]: kinds the admin turned off hide their recipes too; source and tileset switches don't apply to recipes.
[*] [b]Recipe floors[/b]: still listed as tiles and built by this mod's rules, with no separate recipe item.
[*] [b]Removing what a recipe built[/b]: dismantle it the vanilla way; Dismantle (Build Anything) doesn't remove it.
[*] [b]Eyedropper and search[/b]: clicking with the eyedropper, Pick tile from the right-click menu, or searching a full tile name selects the recipe when the tile belongs to one.
[/list]
=== 🧰 Placing and dragging
{{img:04-cursor-en.jpg}}
[h3]The cursor[/h3]
[list]
[*] [b]After pressing Build[/b]: the window hides and a ghost appears on the ground.
[*] [b]Ghost colours[/b]: white means it can be built, red means it can't, with a warning on that square, and yellow with a swap mark means it replaces what is there.
[*] [b]Multi-tile objects[/b]: when blocked, the square causing the problem gets a red frame and the others a grey one.
[*] [b]The box by the mouse[/b]: shows the name, facing, how many tiles you are dragging, why it can't be built and the key hints; when stacking crates, which level it goes on; with Overlap on over an occupied tile, which piece it is on that tile; when your skill is too low, which skill and level you need.
[*] [b]Rotate[/b]: press the Rotate Building key (R by default), which only cycles through the facings that object has; tiles with the same name and one tile per facing rotate too (see Finding things).
[*] [b]Rebound keys[/b]: go by the key hints in the box by the mouse.
[*] [b]Clicking on the UI doesn't build[/b]: a click on the window or other UI never builds on the square underneath.
[*] [b]Keep building[/b]: the cursor stays after you build.
[*] [b]Cancel[/b]: right-click to cancel, and the window comes back.
[*] [b]Pick something else[/b]: while placing you can reopen the window from the toolbar.
[/list]
[h3]Dragging a row or an area[/h3]
{{img:05-drag-en.jpg}}
[list]
[*] [b]What you can drag[/b]: floors, floor overlays, water, walls, posts, fences and roofs: hold the left button, drag, and release to queue them. Recipe walls, fences and posts too.
[*] [b]Drag straight[/b]: builds a row.
[*] [b]Drag diagonally[/b]: makes a rectangle. Floors, floor overlays, water and roofs fill it; walls and fences go around its edges, using the piece for the right direction on each side; posts go on every square of the edges.
[*] [b]A ring missing two sides[/b]: when the tileset has no piece for the other direction, those two sides turn red and aren't built.
[*] [b]Summary in the box[/b]: N tiles: A buildable, B skipped, with one line per reason for the skipped ones.
[*] [b]When short[/b]: the box says what those tiles still need together.
[*] [b]Materials for only the first few[/b]: only the tiles you can afford are built, and the rest are skipped.
[*] [b]At most[/b]: 32 items at once by default, and the admin can change it; tiles over the limit turn red and aren't built.
[/list]
{{img:06-queued-en.jpg}}
[list]
[*] [b]Queued tiles[/b]: after you release, tiles not built yet keep a faint ghost and a blue frame, one fewer each time a tile is done.
[*] [b]After closing the cursor[/b]: your character keeps building.
[*] [b]Dragging another row[/b]: cancels the tiles still queued from the last row, and before you release the box tells you how many.
[/list]
[h3]Replacing in place[/h3]
[list]
[*] [b]How[/b]: build another style of the same kind over a floor, wall, fence, solid furniture or similar that you built with Build Anything, and it's replaced in place, with no need to dismantle first. Dragging a row or area works too; those tiles turn yellow.
[*] [b]What swaps with what[/b]: things of the same kind; walls, door frames and window frames also swap with each other, so you can put a window in a wall without taking the wall down. They must be on the same edge of the square.
[*] [b]Materials[/b]: you only pay what the new one needs beyond the old one; whatever the old one had left over comes back like dismantling, between 1 and all of each material, at your feet. Same materials means nothing extra. The box shows what you pay and what comes back.
[*] [b]XP[/b]: only for the materials you pay.
[*] [b]Durability[/b]: the new one keeps the old one's remaining durability, so swapping doesn't repair it.
[*] [b]Swapping floors[/b]: floor overlays you added with Build Anything, such as road markings, stay on the new floor.
[*] [b]Things that fit together[/b]: when both fit on the square, such as hangings facing different ways, they stay together and nothing is replaced.
[*] [b]Before replacing[/b]: empty containers, and take doors, windows or boards off frames.
[*] [b]Not replaced[/b]: lights, stairs, doors, windows, curtains, floor overlays, multi-tile furniture and anything movable.
[*] [b]Right-click Replace with... (Build Anything)[/b]: opens the build window showing only styles of the same kind that use the same materials and tools; click the filter above the search box to go back to the full catalog.
[/list]
[h3]Overlap[/h3]
[list]
[*] [b]What it's for[/b]: tile-pack pieces meant to share a tile with another piece, such as a cooktop on a counter, lockers drawn as bottom, middle and top, or a rack with clothes hanging on it.
[*] [b]Turning it on[/b]: select furniture, a container or a solid object, press Overlap below the details so it lights up, then press Build. It stays on until you turn it off.
[*] [b]When on[/b]: you can build on a tile that already holds something, and the box by the mouse shows "Overlap: 2 / 3 on this tile". Nothing is replaced in place.
[*] [b]When off[/b]: the usual rules apply: an occupied tile blocks the build, and building over your own piece replaces it.
[*] [b]Limit[/b]: up to 3 blocking objects and containers per tile; admins can change it (see Sandbox options).
[*] [b]Tiles you can't overlap on[/b]: no floor, stairs or a stair landing, water, someone standing there, or the same tile already there.
[*] [b]Still vanilla rules[/b]: small things that sit on tables and crates vanilla lets you stack (see Stacking crates) don't need Overlap; two table-like pieces can't share a tile through Overlap.
[*] [b]Removing the middle piece[/b]: each piece is drawn at its own height, so if you remove the one in the middle, the one above stays where it was.
[*] [b]Other kinds[/b]: walls, floors, lights and the rest have their own rules for sharing a tile, so the Overlap button is greyed out.
[/list]
[h3]Distance and where you stand[/h3]
[list]
[*] [b]Maximum distance[/b]: 3 tiles by default, at most one level up or down, and the admin can change it.
[*] [b]Your character walks over[/b]: it walks next to each tile before building.
[*] [b]Things on a square's edge[/b]: walls, doors, windows and fences sit on the edge of a square and can be built from either side.
[*] [b]Places you can't reach[/b]: through a wall or a closed door or window, furniture and the like can't be placed.
[*] [b]With the build cheat on[/b]: like vanilla, your character doesn't walk over. It builds and dismantles where it stands, at any distance, even places it can't reach. Actions still take their usual time. Things in an area dismantle that go through vanilla Disassemble are still walked to, as in vanilla.
[*] [b]Someone standing there[/b]: things that block movement are not placed on a square where a player or zombie stands.
[*] [b]When you can't build[/b]: in a vehicle or dead.
[/list]
[h3]Refusals and stops[/h3]
{{img:11-refused-en.jpg}}
[list]
[*] [b]The server tells you why[/b]: missing materials, a missing tool, too low a skill, too far, unreachable, blocked, or inside someone else's safehouse, with a notice saying what to do.
[*] [b]Stopping halfway[/b]: when interrupted or the way is blocked, a notice says how many tiles were built.
[*] [b]Tiles not built[/b]: used no materials, so drag again to continue.
[*] [b]No room to stand[/b]: when a tile has no free square beside it, the notice says which one.
[*] [b]Building settings have changed[/b]: the admin changed a sandbox option, so reopen the window, and no materials were used.
[*] [b]When you pay[/b]: the server checks everything before placing and takes the materials only once it is placed, so a failure costs nothing.
[/list]
=== 🧰 Rules for each kind: walls, floors and fences
[h3]Walls, floors and fences[/h3]
[list]
[*] [b]Zombies can break them[/b]: walls, posts and window frames have 450 durability, fences 300. Server owners can turn on Zombies can't break builds in the sandbox.
[*] [b]Stair openings[/b]: walls, fences, door frames and fence gates can't block the way onto or off stairs.
[*] [b]Ground floors[/b]: dismantling one turns the square back into dirt.
[*] [b]Floors one level up[/b]: while placing a floor, PgUp/PgDn switches between one level up and this level; it starts on this level.
[*] [b]What holds up a floor one level up[/b]: a wall right below it, or a floor beside it on the same level; when dragging a row, each tile holds up the next. Not allowed right above stairs. In basements it works as in vanilla and needs a floor beside it.
[*] [b]Posts[/b]: the Post kind on the Walls tab has corner posts from wall corners, fence posts, and the corner posts wall recipes use. After you wall off a rectangle, the south-east corner (the one lowest on screen) shows a gap between the two walls: put a post from the same set on the square just outside that corner. Select the wall and press Set to find it; the tool doesn't add it for you.
[*] [b]Posts and zombies[/b]: like the corner posts vanilla adds when you build walls, zombies don't attack a post as if it were a wall, and it blocks moving diagonally past that corner.
[*] [b]Corner posts built earlier[/b]: those built in 0.1.0 and 0.1.1 become the same as new posts when the save loads, and zombies still attack the walls on that square.
[*] [b]Railing ends[/b]: railing ends that block only one side of a square are not listed (zombies would not come to break them), and a search tells you why.
[*] [b]Fences that alternate[/b]: vanilla fences that come as a pair of tiles (the tall wooden fence with a slanted top, the low wooden fence, the black iron railing, the tall green barbed fence, construction fences and crowd barriers, both directions) alternate between their two tiles by square position (ABAB), as on the map. Fences from other mods' tile packs use the tile you picked.
[*] [b]How they alternate[/b]: dragging a row, going around a rectangle and placing a single square all go by position, so a square always gets the same tile, whichever of the two you pick.
[*] [b]Other fences[/b]: chain-link fences and tile-pack fences still use the tile you picked.
[*] [b]Mall shutters[/b]: on the Walls tab, and what you build is a regular wall. As in vanilla, a window on the same square can't be opened, closed or climbed through with the interact key.
[*] [b]Floors from build recipes[/b]: floors and floor overlays used by build recipes from vanilla or other mods (Neat Building, for example) can be built too. They are built as tiles by this mod's rules, with no separate recipe item.
[*] [b]Floor overlays[/b]: road markings, curbs, cracks, grime and other pictures on the ground are hung on that square's floor, the same way the map does it. The square needs a floor, and the same overlay can't go on the same floor twice (the map's own count too).
[*] [b]Replacing or dismantling a floor, digging the ground or fire[/b]: overlays on it go with it, without refund. Rugs, ground clutter and rocks are still separate things.
[*] [b]Wall overlays[/b]: baseboards, grime, graffiti and other pictures that go on a wall stick to the wall (or window, or garage door) on that side of the square, the same way the map does it; with no wall there they are placed on their own. Signs and pictures you can pick up are still normal objects.
[*] [b]When the wall is dismantled or destroyed[/b]: wall overlays on it go with it, without refund. Replacing the wall in place with Build Anything puts them on the new piece (tall wooden fences and other pieces with a wall edge hold them too); if the new piece can't hold them, such as a low fence, their materials are refunded in full. Vanilla Clean Graffiti and Clean Blood also wash them off, without refund.
[*] [b]Wall overlays placed on their own before[/b]: ones built with 0.8.0 or earlier move onto the wall when their area loads, if that side has a wall, and dismantling them with Build Anything still refunds what you paid; ones without a wall stay as they are. If you build a wall on that side later, the overlay moves onto it the next time the area loads.
[*] [b]Tile-pack rugs[/b]: some tile packs (UMCTP and Constown, for example) also mark their rugs as floors. These rugs are laid on top of the floor as in vanilla and don't replace it.
[*] [b]Where those rugs are listed[/b]: movable ones under Furniture, the others under Floor overlay.
[*] [b]Swapping the floor under them[/b]: those rugs stay.
[*] [b]Rugs built as floors in 0.5.0 or earlier[/b]: dismantle them like floors, with Dismantle (Build Anything).
[*] [b]Other recipe pieces[/b]: walls, fences and anything else with its own functions are the items marked Recipe, built with the vanilla recipe; see Build recipes.
[/list]
[h3]With Basement Building[/h3]
[list]
[*] [b]Walls on the dirt wall edge[/b]: with [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3806513504]Basement Building[/url] installed, you can build a wall on the edge of a basement's outer dirt wall.
[*] [b]Solid walls only[/b]: following that mod's rules, no windows, doors, fences, door frames, window frames, or walls with the same tile as the dirt wall.
[*] [b]Building and dismantling[/b]: the dirt wall on that edge is replaced when the wall is built, and comes back by itself when the wall is dismantled.
[/list]
=== 🧰 Rules for each kind: doors, windows, stairs and roofs
[h3]Doors and windows[/h3]
[list]
[*] [b]Doors[/b]: only the closed tile is listed, and once placed it opens and closes as in vanilla.
[*] [b]Fence gates[/b]: need no door frame and go on any empty edge; they can't go where there is already a wall, fence, door or window, so leave a gap first.
[*] [b]Double doors and garage doors[/b]: not supported yet.
[*] [b]Windows[/b]: open, smashed and glass-removed tiles are not listed, so you always place a whole window.
[*] [b]Unbreakable windows[/b]: not in the catalog, and neither are window frames, posts and wall overlays that make a window unbreakable (walls such as mall shutters are listed).
[*] [b]Permanently locked windows[/b]: listed, and the details say Permanently locked.
[*] [b]What permanently locked means[/b]: it can't be opened but can be smashed, so it works as a fixed window.
[*] [b]Windows drawn together with their frame[/b]: such as the large glass windows of shops and diners, go straight on an empty wall edge, with no window frame first.
[*] [b]When the edge is taken[/b]: they can't go where there is already a window frame, wall or window.
[*] [b]Locking[/b]: they are all permanently locked, so they can't be opened but can be smashed.
[*] [b]Their cost[/b]: a window frame plus a window, see Materials.
[*] [b]Removing and replacing[/b]: like windows, they can only be smashed, and they can't be replaced in place.
[*] [b]Ordinary windows[/b]: still go into a window frame.
[/list]
[h3]Curtains[/h3]
[list]
[*] [b]Where[/b]: on the indoor side of a window frame, and that square must be inside a house or have a roof.
[*] [b]In your own house[/b]: build the roof or the floor above first.
[*] [b]Cost[/b]: 1 sheet, 2 for long curtains, with no tools and no XP.
[*] [b]Use[/b]: opening, closing and taking them down for the sheet back all work as in vanilla.
[/list]
[h3]Stairs[/h3]
[list]
[*] [b]All three steps at once[/b]: one action builds the set, and you can go up and down right away.
[*] [b]Landing[/b]: if the level above has no floor at the top, one is added.
[*] [b]Where[/b]: all three steps need a floor under them (the ground on the first floor counts).
[*] [b]Where not[/b]: on water, tall grass, trees or anything that blocks, or below an existing floor.
[*] [b]Durability[/b]: 450 per step.
[*] [b]Dismantled or destroyed[/b]: any step removes the whole set, and materials come back only once.
[/list]
[h3]Roofs[/h3]
{{img:07-roof-en.jpg}}
[list]
[*] [b]On the ground floor too[/b]: eaves, roof trims and other roof pieces can go on the level of the walls, as on the vanilla map, with no support check. Not allowed in basements.
[*] [b]From the second floor up[/b]: needs a wall below, or a floor or roof beside it holding it up.
[*] [b]Above stairs[/b]: not allowed directly above stairs.
[*] [b]Which level[/b]: the cursor builds one level up at the same spot on screen by default.
[*] [b]Changing level[/b]: PgUp/PgDn switches between one level up and this level. If your keyboard has no such keys, rebind them under Options, Key Bindings, "Minidoracat Build Anything".
[*] [b]Dragging a row[/b]: start from the supported end, since each tile holds up the next.
[*] [b]Keeping rain out[/b]: once a rain-proof roof is built, the square below is no longer outdoors.
[*] [b]Counting as indoors (temperature)[/b]: the level above also needs a floor.
[*] [b]Roof pieces that let rain in[/b]: eaves and many roof pieces never kept rain out, and the details point them out.
[/list]
=== 🧰 Rules for each kind: furniture, containers and lights
[h3]Furniture and containers[/h3]
[list]
[*] [b]Zombies can break them[/b]: everything that blocks movement can be broken, including furniture, crates, rocks, and blocking wall-mounted objects, rugs and tabletop items. Server owners can turn on Zombies can't break builds in the sandbox.
[*] [b]Ordinary furniture durability[/b]: the same as when moved and placed in vanilla, tougher the heavier it is and the harder its material.
[*] [b]Small blocking things[/b]: wall-mounted objects, rugs and tabletop items have 100 durability, and break more slowly when fewer than 8 zombies are attacking.
[*] [b]Things that don't block[/b]: zombies leave them alone.
[*] [b]Movable things[/b]: once placed, pick them up and move them as in vanilla.
[*] [b]Cots and gurneys[/b]: listed under Furniture by their vanilla tile names, Cot and Single Bed with Green Metal Frame; once built they are ordinary beds.
[*] [b]Things that turn into a special item when picked up[/b]: tents, sleeping bags, radios, propane tanks and the like are still not listed.
[*] [b]Stacking crates[/b]: military crates, cardboard boxes, wooden crates and the other crates vanilla lets you stack go on top of other crates as in vanilla, the same crate included, up to the vanilla height limit; pick them up from the top as in vanilla. The details show the stacking limit in layers (3 for the military crate); if the piece below can't hold anything on top, the cursor says so.
[*] [b]Sinks, toilets and bathtubs[/b]: as when moved in vanilla, they have no running water. Plumb them inside a closed room with a pipe wrench, and they draw water from a rain collector barrel or other water container one floor up, right above or one square around.
[*] [b]Containers[/b]: hold items right away.
[*] [b]Wells and hand pumps[/b]: off by default; they appear in the Furniture tab once an admin turns them on in the sandbox page "what can be built" or in the Manage panel. The water never runs out, is clean, and keeps working after the water shuts off. A well costs 40 Stone + 8 Large Smooth Flat Stone + 1 Rope + 1 Bucket and needs a shovel or spade plus a Mason's Trowel; a hand pump costs 6 Iron Pipe + 4 Steel Sheet - Small + 6 Screws and needs a Welding Torch + Welder Mask. They block the square, zombies can break them, and they are as tough as a wall. Take them down with Dismantle (Build Anything).
[*] [b]Fireplaces[/b]: work like the ones on the map once built, so you can add fuel and light them; stoves, ovens and similar appliances from tile packs are built the way the map builds them too.
[*] [b]Fireplaces built in 0.6.1 or earlier[/b]: can't be lit; dismantle them with Dismantle (Build Anything) and build them again.
[*] [b]Rain collector barrels and metal drums[/b]: not listed as tiles, because built by this mod's rules they can't collect rain. For rain collectors, pick the item marked Recipe: it uses the vanilla recipe and collects rain. Ones built before this update can be picked up as in vanilla if they're movable; the immovable one can only be smashed with a sledgehammer, for no materials.
[*] [b]Container capacity[/b]: the same as the vanilla piece; server owners can set Container capacity multiplier in the sandbox, up to 100.
[/list]
[h3]Lights[/h3]
[list]
[*] [b]Power needed[/b]: lights that glow are switched on when built and, as in vanilla, only light up with power.
[*] [b]Your own houses are off the grid[/b]: hook up a generator.
[*] [b]Street lights and some signs[/b]: the ones whose details say only at night light up only at night, as in vanilla, and also run on a generator or solar power.
[*] [b]Switch them directly[/b]: lights built with Build Anything can be switched by hand even outside the map's own houses.
[*] [b]Movable lights[/b]: switch them, change the bulb or convert them to batteries as in vanilla.
[*] [b]Furniture, signs and floor lights with a built-in light[/b]: like lights, they only glow with power, but they have no switch.
[*] [b]Switches[/b]: a switch in a closed room tries to wire itself to the lights in that room, see Switches and wiring.
[/list]
[h3]Plants[/h3]
[list]
[*] [b]Where[/b]: the Plants kind in the Decor tab, split into Ornamental Plants and Grass and Wildflowers. All of it is decoration only: nothing grows and nothing can be harvested.
[*] [b]Ornamental plants[/b]: potted plants, hedges, flower beds and other plants vanilla lets you move. They cost what furniture costs, and you pick them up and move them the vanilla way.
[*] [b]Hedges, flower beds and bushes need natural ground[/b]: as in vanilla, they only go on grass, dirt and other squares without a built floor; on a built floor the cursor tells you why. Potted plants go anywhere.
[*] [b]Grass and wildflowers[/b]: 3 Grass Cuttings per square, no tools, no XP. They don't block the square and zombies ignore them.
[*] [b]Clearing grass[/b]: Dismantle (Build Anything) gives materials back; anyone can also use the vanilla right-click Remove Grass, which does not refund what you paid and gives Grass Cuttings the vanilla way.
[*] [b]Floors clear them[/b]: building a floor on a square with grass, a hedge or a bush removes them, as in vanilla, with no refund.
[*] [b]Not listed[/b]: crops, trees, and bushes that can be cut down.
[*] [b]Gravestones, road signs, mailboxes and the like[/b]: 0.9.0 and earlier treated them as plants and refused them; they are now listed as ordinary furniture or containers.
[/list]
[h3]Water[/h3]
[list]
[*] [b]Where[/b]: the Water kind in the Floors tab. Off by default; it shows up once an admin turns it on in the sandbox page "what can be built" or in the Manage panel.
[*] [b]Where you can dig[/b]: only on natural ground at ground level, meaning grass, dirt, sand and other squares without a built floor. Built floors, floors built with Build Anything and upper levels don't work, and the cursor tells you why.
[*] [b]What it costs[/b]: just carry a shovel or spade. No materials (the material multiplier doesn't change that), no XP and no skill.
[*] [b]What's on the square[/b]: wild grass, grass overlays and bushes are cleared with no refund. Squares with a tree, furniture, items on the ground or a corpse can't be dug; clear them first. Plants built with Build Anything and floor overlays you hung on the ground must be dismantled first too. Not with someone standing there or a vehicle on it either.
[*] [b]Dragging an area[/b]: digging starts at the square farthest from you and works back toward you, so the squares you need to stand on are not dug first. Drag from outside the area: if you are standing inside it, the whole area turns red and nothing is dug, so you can't end up surrounded by water. If you drag more squares than the per-drag limit, the ones left out are the squares nearest to you.
[*] [b]No regrowth[/b]: a square you dug no longer grows grass or plants on its own, even after you fill it back.
[*] [b]Once dug[/b]: like water on the map, it blocks people and zombies; you can take water from it (tainted, so boil or purify it before drinking) and fish there.
[*] [b]Filling it back[/b]: right-click Dismantle (Build Anything) with a shovel or spade. It fills back to the ground that was there before, with nothing refunded. Water with no record of the old ground fills back to dirt.
[*] [b]Building a floor on water[/b]: replaces it like any other floor and the water is gone; dismantling that floor later turns the square into dirt.
[*] [b]The map's own rivers and lakes[/b]: can't be filled with Build Anything.
[/list]
=== 🧰 Materials
[h3]What it costs[/h3]
[list]
[*] [b]Tiles with vanilla dismantle materials[/b]: cost what dismantling them gives, never less than you could get back.
[*] [b]Tiles without[/b]: cost the same as the matching vanilla build, see the table below.
[*] [b]Electrical things[/b]: 1 extra Scrap Electronics (one per tile for multi-tile ones), which you don't get back when dismantling.
[*] [b]Light bulbs[/b]: every light costs 1 extra Light Bulb, with no XP.
[*] [b]Street lights that can't be moved[/b]: 2 extra Iron Pipe (tilesets lighting_outdoor_01 and lighting_outdoor_tk_01).
[*] [b]Floor tiles and carpets you can pick up[/b]: the wooden subfloor under them costs 1 plank and 1 nail, plus an amount by material: 1 sheet for carpets and other fabric floors; 4 Clay Tile and a Mason's Trowel for ceramic and brick tiles; 1 more plank and 1 more nail for wooden floor tiles and the rest. The by-material part is not refunded, and the details list it as "Not returned on removal".
[*] [b]Material multiplier[/b]: every amount is multiplied by the admin's multiplier and rounded up.
[*] [b]Exceptions below 1[/b]: tiles with dismantle materials, curtains, light bulbs and the wooden subfloor of floor tiles and carpets you can pick up still cost at least 1×.
[*] [b]Build cheat[/b]: no materials and no tools. In multiplayer an admin turns on Build Cheat mode in Edit your Admin Powers; in singleplayer the Build Cheat switch in the debug menu and Enable Build Cheat Mode in the admin panel count too.
[*] [b]Consumables[/b]: when the server turns on Vanilla recipe materials, clay cement, torch fuel and welding rods are also used, see Hardcore options.
[*] [b]Exact amounts[/b]: Materials (have / need) in the details is what counts.
[/list]
Tiles without dismantle materials cost this, by material (multiplier 1):
[table]
[tr][th]Kind[/th][th]Wood[/th][th]Masonry[/th][th]Metal[/th][/tr]
[tr][td]Floor[/td][td]1 Plank + 1 Nails[/td][td]4 Ceramic Tile[/td][td]1 Steel Sheet - Small[/td][/tr]
[tr][td]Wall, post, window frame[/td][td]4 Plank + 6 Nails[/td][td]4 Brick[/td][td]3 Steel Rod + 3 Steel Sheet - Small[/td][/tr]
[tr][td]Door frame[/td][td]4 Plank + 4 Nails[/td][td]4 Brick[/td][td]4 Steel Rod[/td][/tr]
[tr][td]Fence[/td][td]2 Plank + 2 Nails[/td][td]2 Brick[/td][td]2 Steel Rod[/td][/tr]
[tr][td]Door[/td][td]4 Plank + 4 Nails + 2 Door Hinge + 1 Doorknob[/td][td]As wood[/td][td]3 Steel Sheet - Small + 2 Door Hinge + 1 Doorknob[/td][/tr]
[tr][td]Window[/td][td]4 Glass Pane + 2 Plank + 4 Nails. A window drawn together with its frame costs the frame plus the window: 4 Glass Pane + 6 Plank + 10 Nails in wood[/td][td]As wood[/td][td]As wood[/td][/tr]
[tr][td]Stairs (whole set)[/td][td]13 Plank + 8 Nails[/td][td]As wood[/td][td]4 Steel Rod + 6 Steel Sheet - Small[/td][/tr]
[tr][td]Roof[/td][td]1 Plank + 2 Nails per tile, eaves 1 + 1[/td][td]As wood[/td][td]As wood[/td][/tr]
[tr][td]Furniture, containers[/td][td]By vanilla carry weight: up to 2 kg 1 Plank + 1 Nails, up to 5 kg 2 + 2, heavier 4 + 4[/td][td]As wood[/td][td]2 Steel Sheet - Small[/td][/tr]
[tr][td]Solid objects[/td][td]2 Plank + 2 Nails[/td][td]2 Brick[/td][td]2 Steel Sheet - Small[/td][/tr]
[tr][td]Other small things (wall-mounted, window fittings, overlays and the like)[/td][td]1 Plank + 1 Nails[/td][td]As wood[/td][td]As wood[/td][/tr]
[/table]
[list]
[*] [b]Lights[/b]: 1 Scrap Electronics + 1 Electrical Wire.
[*] [b]Curtains[/b]: 1 Sheet, 2 for long curtains.
[*] [b]Dirt, gravel and sand floors[/b]: 1 Sack of Dirt, Sack of Gravel or Sack of Sand, no tools.
[*] [b]Grass and wildflowers[/b]: 3 Grass Cuttings, no tools; still 3 when the material multiplier is below 1.
[*] [b]Well[/b]: 40 Stone + 8 Large Smooth Flat Stone + 1 Rope + 1 Bucket (empty; a bucket with water in it doesn't count). [b]Hand pump[/b]: 6 Iron Pipe + 4 Steel Sheet - Small + 6 Screws.
[*] [b]Water[/b]: no materials, whatever the material multiplier.
[/list]
[h3]Material read from the tile name[/h3]
These tiles don't say what they are made of. They used to cost as wood, and now cost by the material their tile name shows (multiplier 1):
[table]
[tr][th]What[/th][th]Materials[/th][th]Tools[/th][th]Skill (when required)[/th][/tr]
[tr][td]Glass roofs: all of roofs_30_04, and the glass roofs in roofs_02 and roofs_shallow_01[/td][td]1 Glass Pane + 2 Nails per tile, eaves and the flat piece 1 Glass Pane + 1 Nails[/td][td]Hammer[/td][td]Carpentry 2[/td][/tr]
[tr][td]Street light poles: the 5 metal poles without a lamp in lighting_outdoor_01[/td][td]2 Steel Sheet - Small[/td][td]Welding Torch + Welder Mask[/td][td]Welding 3[/td][/tr]
[tr][td]Mall (location_shop_mall_01) glass railings[/td][td]1 Glass Pane + 1 Steel Rod[/td][td]Welding Torch + Welder Mask[/td][td]Welding 3[/td][/tr]
[tr][td]Mall brick low walls and planters[/td][td]2 Brick[/td][td]Mason's Trowel[/td][td]Masonry 5 for low walls, Masonry 3 for planters[/td][/tr]
[tr][td]Mall door frames[/td][td]4 Brick[/td][td]Mason's Trowel[/td][td]Masonry 2[/td][/tr]
[tr][td]Shopfront and escalator glass walls (30 tiles)[/td][td]3 Steel Rod + 4 Glass Pane[/td][td]Welding Torch + Welder Mask[/td][td]Welding 3[/td][/tr]
[tr][td]Log wall gables (36 tiles in walls_logs)[/td][td]4 Log[/td][td]Hammer[/td][td]None[/td][/tr]
[tr][td]All-metal railings (7 tiles in fixtures_railings_01)[/td][td]2 Steel Rod[/td][td]Welding Torch + Welder Mask[/td][td]Welding 3[/td][/tr]
[/table]
[list]
[*] [b]Unchanged[/b]: log window frames and door frames, wooden and painted railings, and posts such as railing posts and mall glass posts (costed as walls).
[*] [b]Already built[/b]: dismantling them also needs the new tools, a Welding Torch and Welder Mask for metal and a Mason's Trowel for brick; what comes back follows what was paid.
[/list]
[h3]Where to keep materials[/h3]
[list]
[*] [b]Bags or the ground next to you[/b]: your inventory, bags and the ground beside you all count.
[*] [b]Behind a wall[/b]: nothing there is taken.
[*] [b]Box of Nails[/b]: when you are short of nails, a Box of Nails in your inventory is opened and the leftovers go back into your inventory.
[/list]
=== 🧰 Tools and XP
[h3]Tools[/h3]
[list]
[*] [b]Tiles with dismantle materials[/b]: carry the main tool vanilla uses to dismantle the first material, for example a hammer for brick.
[*] [b]When that tool is the Welding Torch[/b]: you also need a Welder Mask.
[*] [b]Tiles without dismantle materials[/b]: see the table.
[/list]
[table]
[tr][th]Tiles without dismantle materials[/th][th]Tools to carry[/th][/tr]
[tr][td]Wood, and anything costed as wood[/td][td]Hammer[/td][/tr]
[tr][td]Brick, stone, concrete, ceramic and similar materials[/td][td]Mason's Trowel[/td][/tr]
[tr][td]Metal[/td][td]Welding Torch + Welder Mask[/td][/tr]
[tr][td]Lights[/td][td]Screwdriver[/td][/tr]
[tr][td]Well[/td][td]Shovel or spade + Mason's Trowel[/td][/tr]
[tr][td]Water[/td][td]Shovel or spade[/td][/tr]
[tr][td]Dirt, gravel and sand floors, curtains, grass and wildflowers[/td][td]None[/td][/tr]
[/table]
[list]
[*] [b]The details decide[/b]: Tools (carry them) in the details lists exactly what to carry.
[*] [b]Furniture-style tiles[/b]: don't need the tools vanilla needs to move them.
[*] [b]Nothing wears out[/b]: tools only need to be on you.
[*] [b]Welding Torch[/b]: uses no fuel, unless the server turns on Vanilla recipe materials.
[/list]
[h3]XP[/h3]
[list]
[*] [b]Skill levels[/b]: none needed by default; only when the server turns on Require vanilla skill levels, see Hardcore options.
[*] [b]5 XP per item[/b]: each material used gives 5 XP, then the vanilla XP multiplier applies.
[*] [b]Things that dismantle into parts[/b]: XP goes to the skill that decides in vanilla whether that material comes back.
[*] [b]Examples[/b]: Scrap Electronics and Electrical Wire give Electrical, Steel Sheet - Small gives Welding, Brick gives Masonry, Stone gives Strength, Plank and Nails give Carpentry.
[*] [b]Everything else goes by material[/b]: wood gives Carpentry, masonry gives Masonry, metal gives Welding.
[*] [b]Dirt, gravel and sand floors[/b]: no XP.
[*] [b]Higher skill, less XP[/b]: for things vanilla dismantling can give back, the higher your level in that skill, the better your chance of getting the material back, so building gives less XP, and none once you would always get everything back.
[*] [b]Things you dismantle with Build Anything[/b]: skill level doesn't matter, and XP follows the average number of items you don't get back.
[*] [b]How it's counted[/b]: paying N of a material gives 5×(N−1)÷2, and paying 1 gives none.
[*] [b]The extra Scrap Electronics for electrical things[/b]: never comes back, so it always gives XP.
[*] [b]Things that always come back in full[/b]: no XP, for example sandbag walls.
[*] [b]Materials two skills share[/b]: a material that two skills share in vanilla dismantling gives no XP.
[*] [b]Nothing paid[/b]: no XP for materials you didn't actually pay, for example with the build cheat on.
[/list]
=== 🧰 Hardcore options
Two sandbox options, both off by default, and you can turn on just one. Change them on the Minidoracat Build Anything page of the sandbox settings, or in game on the Rules page of the Manage panel.
[h3]Require vanilla skill levels[/h3]
[list]
[*] [b]Which level[/b]: each item needs the skill level of the matching vanilla recipe, see the table.
[*] [b]Which skill[/b]: follows the kind of material it is costed as, so anything costed as wood needs Carpentry.
[*] [b]No skill needed[/b]: wall-mounted objects, window fittings, overlays, curtains, lights, floor overlays and water.
[*] [b]Wells and hand pumps[/b]: a well needs Masonry 4, a hand pump Welding 5.
[*] [b]Skill too low[/b]: the cursor square turns red, and the box by the mouse and the notice say which skill and level you need.
[*] [b]Details[/b]: an extra line such as Skill: Carpentry 2, with your level and a warning when it's too low.
[*] [b]The grid[/b]: items your skill is too low for are dimmed with a warning, like items you can't afford.
[*] [b]Only what I can build[/b]: hides them too.
[*] [b]After you level up[/b]: the window updates, so there is no need to reopen it.
[*] [b]Build cheat[/b]: not affected.
[*] [b]Dismantling[/b]: still needs no skill.
[/list]
[table]
[tr][th]Kind[/th][th]Wood[/th][th]Masonry[/th][th]Metal[/th][/tr]
[tr][td]Floor[/td][td]Carpentry 1[/td][td]None[/td][td]None[/td][/tr]
[tr][td]Wall, post, window frame, door frame[/td][td]Carpentry 2[/td][td]Masonry 2[/td][td]Welding 3[/td][/tr]
[tr][td]Fence[/td][td]Carpentry 3[/td][td]Masonry 5[/td][td]Welding 3[/td][/tr]
[tr][td]Door[/td][td]Carpentry 3[/td][td]As wood[/td][td]Welding 3[/td][/tr]
[tr][td]Window[/td][td]Carpentry 5[/td][td]As wood[/td][td]As wood[/td][/tr]
[tr][td]Stairs (whole set)[/td][td]Carpentry 6[/td][td]As wood[/td][td]Welding 5[/td][/tr]
[tr][td]Roof[/td][td]Carpentry 2[/td][td]As wood[/td][td]As wood[/td][/tr]
[tr][td]Furniture, containers[/td][td]By carry weight: up to 2 kg Carpentry 1, up to 5 kg 3, heavier 5[/td][td]As wood[/td][td]Welding 3[/td][/tr]
[tr][td]Solid objects[/td][td]By carry weight, Carpentry 1, 3 or 5[/td][td]By carry weight, Masonry 1, 3 or 5[/td][td]Welding 3[/td][/tr]
[/table]
[h3]Vanilla recipe materials[/h3]
[list]
[*] [b]Extra consumables[/b]: items also use up the consumables of the matching vanilla recipe, counted in uses, see the table; wood needs none.
[*] [b]Masonry[/b]: clay cement or concrete, 4 uses per bucket.
[*] [b]Metal[/b]: Welding Torch fuel (10 uses per torch) and Welding Rods (20 uses per pack).
[*] [b]Stone walls[/b]: take Stone Block instead of Brick: 6 for a wall or post, 5 for a window frame, 4 for a door frame.
[*] [b]Where they come from[/b]: your inventory first, then the ground next to you.
[*] [b]Empty buckets[/b]: turn back into empty buckets as in vanilla.
[*] [b]Details[/b]: consumables are shown as have / need uses.
[*] [b]Material multiplier[/b]: applies to uses too, rounded up.
[*] [b]Not refunded[/b]: consumables don't come back when dismantled and give no extra XP.
[*] [b]Build cheat[/b]: nothing to pay.
[/list]
[table]
[tr][th]Kind[/th][th]Masonry: clay cement or concrete[/th][th]Metal: torch fuel + welding rods[/th][/tr]
[tr][td]Floor[/td][td]1 use[/td][td]1 + 1 uses[/td][/tr]
[tr][td]Wall, post[/td][td]2 uses[/td][td]5 + 6 uses[/td][/tr]
[tr][td]Window frame[/td][td]2 uses[/td][td]5 + 2 uses[/td][/tr]
[tr][td]Door frame[/td][td]2 uses[/td][td]4 + 4 uses[/td][/tr]
[tr][td]Fence[/td][td]1 use[/td][td]2 + 2 uses[/td][/tr]
[tr][td]Door[/td][td]None[/td][td]4 + 4 uses[/td][/tr]
[tr][td]Stairs (whole set)[/td][td]None[/td][td]4 + 4 uses[/td][/tr]
[tr][td]Shopfront and escalator glass walls[/td][td]None[/td][td]1 + 2 uses[/td][/tr]
[tr][td]Well[/td][td]4 uses[/td][td]None[/td][/tr]
[tr][td]Hand pump[/td][td]None[/td][td]4 + 4 uses[/td][/tr]
[/table]
=== 🧰 Switches and wiring
[h3]Automatic wiring[/h3]
[list]
[*] [b]A switch in a closed room[/b]: when the conditions are met it tries to wire the lights in that room, and a notice says how many.
[*] [b]Closed room[/b]: an enclosed area of at most 400 squares.
[*] [b]Which lights[/b]: lights on the same level within 16 tiles of the switch.
[*] [b]Two-way[/b]: place a second switch in the same room and the two share one circuit, so either one switches the whole row of lights.
[*] [b]Lights placed later[/b]: when the room has only one group of switches, lights placed in it later are wired too when possible.
[*] [b]When it doesn't wire[/b]: several groups of switches in the room, a full circuit, too far from the switch, or no permission, with a notice saying why.
[*] [b]Too big or not closed[/b]: placing a switch there gives a This isn't a closed room notice, so wire it by hand.
[*] [b]When there is no notice[/b]: a light placed somewhere not closed, or with no switch within 16 tiles on the same level, is not wired and no notice appears.
[*] [b]If it doesn't wire[/b]: wire it by hand, see the next section.
[/list]
[h3]Wiring by hand[/h3]
{{img:08-wiring-en.jpg}}
[list]
[*] [b]Open wiring mode[/b]: right-click the switch and choose Wiring... (Build Anything).
[*] [b]Outline colours[/b]: green is this switch, yellow a wired light, white a light you can wire, grey a light on another switch.
[*] [b]Which one is picked[/b]: point at the image of a light or switch (a lamp head or a wall light counts) to pick it, and its square lights up; when you aren't pointing at anything you can wire, the square under the mouse is grey.
[*] [b]Click a light[/b]: adds or removes it.
[*] [b]Lights on another circuit[/b]: clicking one moves it over.
[*] [b]Click another switch[/b]: makes it two-way, and its whole circuit joins.
[*] [b]Click a wired switch[/b]: takes it off.
[*] [b]Several on one square[/b]: when their images overlap, or you point at that square's floor, click again for the next one; the panel shows which one of how many.
[*] [b]Panel buttons[/b]: Wire this room, Unwire all, Done.
[*] [b]Leave[/b]: Esc or right-click.
[*] [b]Lights you can wire[/b]: lights built with Build Anything, and movable lights.
[*] [b]Switches you can wire[/b]: only those built with Build Anything.
[/list]
[h3]From the light's side[/h3]
{{img:09-light-menu-en.jpg}}
[list]
[*] [b]Right-click a light[/b]: choose Circuit (Build Anything), and the submenu says Switches controlling it: N or Not wired to a switch.
[*] [b]Which switches[/b]: hover Switches controlling it: N to outline them.
[*] [b]Unwire[/b]: the light switches on its own again.
[*] [b]Open wiring mode[/b]: also available in the submenu.
[/list]
[h3]Limits and permissions[/h3]
[list]
[*] [b]One circuit[/b]: up to 4 switches and 16 lights (a two-tile light counts as two).
[*] [b]Distance[/b]: switches and lights must be within 16 tiles across and 2 levels of each other.
[*] [b]Build permission[/b]: needed on every square the wiring touches, and if any square fails, nothing is wired.
[*] [b]Which squares count[/b]: each tile of a two-tile light, and the other switch's whole circuit when you join two switches.
[*] [b]Someone else's safehouse[/b]: lights there can't be wired or unwired.
[*] [b]A circuit with no switches left[/b]: is deleted, and its lights stay as they are.
[*] [b]With Enable building off[/b]: nobody can wire, but built lights and switches still work.
[*] [b]With Admins only[/b]: ordinary players can't wire, but admins can.
[/list]
=== 🧰 Dismantling
{{img:10-dismantle-en.jpg}}
[h3]Dismantle (Build Anything)[/h3]
[list]
[*] [b]What it removes[/b]: walls, floors, floor overlays, roofs and stairs built with Build Anything, plus furniture and lights that can't be moved; it also fills back water you dug.
[*] [b]What it can't remove[/b]: things built in vanilla or other ways, and what the map already had. It does not replace the vanilla sledgehammer: pick those up, disassemble them or smash them as in vanilla.
[*] [b]How[/b]: right-click and choose Dismantle (Build Anything): name. The piece lights up while you hover the option; your character walks over, and a notice says what came back.
[*] [b]Things for vanilla removal[/b]: things you built with Build Anything that vanilla picks up or disassembles still show in the menu, greyed out, and hovering says how to remove them.
[*] [b]Tools[/b]: the same as for building.
[*] [b]Materials back[/b]: between 1 and all of each material, dropped at your feet.
[*] [b]Consumables[/b]: clay cement, torch fuel and welding rods used by Vanilla recipe materials don't come back.
[*] [b]Skill[/b]: dismantling needs no skill, even with Require vanilla skill levels on.
[*] [b]XP[/b]: dismantling gives none.
[*] [b]Stairs[/b]: all three steps go together, and materials come back once.
[*] [b]Stair landing[/b]: the landing added with the stairs goes too, unless something is on it.
[*] [b]Multi-tile furniture[/b]: goes as one piece.
[*] [b]Ground floors[/b]: turn back into dirt.
[*] [b]Built with the build cheat[/b]: no materials back.
[*] [b]Light bulbs[/b]: dismantling an immovable light with Build Anything returns the bulb only if it is still in the light.
[*] [b]Lights built in 0.5.0 or earlier[/b]: no bulb was charged then, so none comes back.
[*] [b]Lights taken apart with vanilla Disassemble[/b]: as in vanilla, the bulb doesn't come back.
[/list]
[h3]Dismantle an area[/h3]
[list]
[*] [b]How[/b]: right-click and choose Dismantle an area... (Build Anything), hold the left button and drag a rectangle, then release to get a confirmation panel; right-click cancels.
[*] [b]Range[/b]: the level you stand on, plus the roof right above it.
[*] [b]Confirmation panel[/b]: lists how many of each kind, with boxes you can untick, how many will be skipped and why, how many go through vanilla Disassemble and how many need vanilla Pick Up. Nothing happens until you press Dismantle (N).
[*] [b]Vanilla Disassemble[/b]: things you built whose details say "Vanilla dismantle" are queued too, with vanilla tools and vanilla returns.
[*] [b]Order[/b]: hanging things and furniture first, then walls, then roofs and floors last.
[*] [b]At most[/b]: the same limit as building (32 by default); select again for the rest.
[*] [b]What can't be dismantled[/b]: is skipped and the next one goes ahead; the final notice says how many were dismantled, what came back and what was kept and why.
[*] [b]Stopping[/b]: walking away, pressing Esc or being interrupted stops it, and the notice says how many were done; select the area again to continue.
[/list]
[h3]Before you dismantle[/h3]
[list]
[*] [b]Containers[/b]: empty them first.
[*] [b]Door and window frames[/b]: take off the door, window or boards first.
[*] [b]Upper floors[/b]: move what is on them first.
[*] [b]A floor the stairs lead up to[/b]: dismantle the stairs first.
[*] [b]Safehouses[/b]: you can't dismantle in someone else's safehouse.
[/list]
[h3]Removal line in the details[/h3]
[table]
[tr][th]Details say[/th][th]How it comes off[/th][/tr]
[tr][td]Pick it up as usual (it can be moved)[/td][td]Pick it up as in vanilla[/td][/tr]
[tr][td]Vanilla dismantle, returns part of the materials[/td][td]Disassemble it as in vanilla[/td][/tr]
[tr][td]Right-click "Dismantle (Build Anything)", which returns between 1 and all of each material[/td][td]Dismantle it with Build Anything[/td][/tr]
[tr][td]Vanilla "Remove curtains", returns 1 sheet[/td][td]Take the curtain down as in vanilla[/td][/tr]
[tr][td]Only by smashing with a sledgehammer. No materials back.[/td][td]For example doors and windows that can't be moved[/td][/tr]
[/table]
=== 🧰 Gamepad
[h3]Build window[/h3]
[list]
[*] [b]Tabs[/b]: LB/RB.
[*] [b]Pick[/b]: move with the D-pad, A selects (the cell gets a yellow frame and a tick), A again starts building.
[*] [b]Favorite[/b]: Y adds it to favorites.
[*] [b]Scroll the details[/b]: right stick.
[*] [b]Close[/b]: B.
[/list]
[h3]Placing[/h3]
[list]
[*] [b]Rotate[/b]: LB/RB.
[*] [b]Build[/b]: A.
[*] [b]Cancel[/b]: B.
[*] [b]Roof and floor level[/b]: X switches between one level up and this level.
[*] [b]Rows, areas and Dismantle an area[/b]: mouse only; with a gamepad you build one tile and dismantle one piece at a time.
[/list]
[h3]Wiring mode[/h3]
[list]
[*] [b]Add or remove[/b]: A.
[*] [b]Wire this room[/b]: X.
[*] [b]Leave[/b]: B.
[/list]
=== ⚙️ Admin panel
{{img:14-admin-en.jpg}}
Players who can change sandbox options can turn what can be built on or off for every player in game. The panel changes the sandbox options in the next chapter.
[h3]Opening it[/h3]
[list]
[*] [b]Who sees it[/b]: players who can change sandbox options, that is admins in multiplayer and the host of a game hosted from the game, and you yourself in singleplayer.
[*] [b]Where[/b]: the Manage button at the right end of the Per row slider row in the Build Anything window.
[/list]
[h3]Four pages[/h3]
[list]
[*] [b]Kinds[/b]: turn the 24 kinds on or off, such as floors, walls, posts and furniture. Wells and Hand Pumps and Water are off by default; the others are on.
[*] [b]Sources[/b]: turn all tiles from a mod on or off.
[*] [b]Tilesets[/b]: click a row to turn that tileset on or off, and filter the list with the box at the top.
[*] [b]Rules[/b]: the twelve rules from the sandbox page: Enable building, Who can build, Where players can build, Maximum build distance, Most items at once, Most pieces per tile, Material cost multiplier, Require vanilla skill levels, Vanilla recipe materials, Zombies can't break builds, Zombies can't break doors and Container capacity multiplier.
[*] [b]Server records[/b]: at the bottom of the Rules page, how many entries, files and how much space each of the server's four records uses (floors and water, overlays, lights and appliances, circuits). When a file gets too big, the server moves on to the next one by itself.
[/list]
[h3]Applying[/h3]
[list]
[*] [b]Change, then apply[/b]: your changes stay in the panel until you press Apply, and Revert drops changes not applied yet.
[*] [b]After applying[/b]: the server saves them, and every player's Build Anything follows within a few seconds.
[*] [b]Changes by other admins[/b]: changes you have already received are kept; if two admins press Apply at almost the same time, the later one overwrites the earlier one.
[*] [b]If the server doesn't apply them[/b]: the panel says why, and Try again sends them again.
[*] [b]Kinds turned off[/b]: players can't see or build them, and things already built stay and can still be dismantled.
[*] [b]Sources and tilesets turned off[/b]: players can't see or build those tiles.
[*] [b]The base game[/b]: can't be turned off as a whole, so turn off its tilesets or kinds instead.
[/list]
[h3]Shortcuts in the details[/h3]
[list]
[*] [b]Where[/b]: when an admin selects an item, Turn off this tileset and Turn off this source appear above Build in the details.
[*] [b]Confirm first[/b]: a confirmation says how many items it turns off, and pressing Turn off applies it for every player.
[*] [b]Turning it back on[/b]: use the admin panel.
[*] [b]Narrow window[/b]: the two buttons are hidden.
[/list]
=== ⚙️ Sandbox options and defaults
{{img:12-sandbox-en.jpg}}
On the Minidoracat Build Anything page of the sandbox settings, or in game with the Manage panel.
[table]
[tr][th]Option[/th][th]Default[/th][th]Range[/th][th]What it does[/th][/tr]
[tr][td]Enable building[/td][td]On[/td][td]On/off[/td][td]When off, the server refuses every build request from this mod. Things already built stay[/td][/tr]
[tr][td]Who can build[/td][td]Everyone[/td][td]Everyone / Admins only[/td][td]Admins only: only players allowed to use the build cheat can build[/td][/tr]
[tr][td]Where players can build[/td][td]Like vanilla[/td][td]Like vanilla / Own safehouses only[/td][td]Like vanilla: unclaimed land and safehouses where the player may build. Own safehouses only: only inside safehouses where the player may build[/td][/tr]
[tr][td]Maximum build distance (tiles)[/td][td]3[/td][td]2–8[/td][td]From the player to the nearest square of the item, at most one floor above or below[/td][/tr]
[tr][td]Most items at once[/td][td]32[/td][td]1–64[/td][td]How many items one build or dismantle can take, for example dragging an area of floor or dismantling an area[/td][/tr]
[tr][td]Most pieces per tile[/td][td]3[/td][td]1–5[/td][td]With Overlap on, how many blocking objects and containers one tile can hold. 1 turns Overlap off. Only affects new builds; pieces already built stay[/td][/tr]
[tr][td]Material cost multiplier[/td][td]1.0[/td][td]0–10[/td][td]Multiplies every material amount, rounded up. 0 = no ordinary materials, but tools are still needed. Tiles with dismantle materials, curtains and light bulbs never go below 1[/td][/tr]
[tr][td]Require vanilla skill levels[/td][td]Off[/td][td]On/off[/td][td]Each item needs the skill level of the matching vanilla recipe, for example a wooden wall needs Carpentry 2, a wooden window Carpentry 5, wooden stairs Carpentry 6, a brick wall Masonry 2 and a metal wall Welding 3. Furniture and containers have no vanilla recipe, so they need Carpentry 1, 3 or 5 by carry weight, or Welding 3 if metal. Wall hangings, overlays, curtains and lights need no skill. The build cheat isn't affected, and dismantling still needs no skill. See Hardcore options[/td][/tr]
[tr][td]Vanilla recipe materials[/td][td]Off[/td][td]On/off[/td][td]Items also use up the consumables of the matching vanilla recipe: masonry uses clay cement or concrete (4 uses per bucket), metal uses Welding Torch fuel (10 uses per torch) and Welding Rods (20 uses per pack). Stone walls take Stone Block instead of Brick. Consumables come from your inventory and the ground next to you, aren't refunded when dismantled and give no extra XP. The material cost multiplier applies to uses too. See Hardcore options[/td][/tr]
[tr][td]Zombies can't break builds[/td][td]Off[/td][td]On/off[/td][td]Zombies don't attack walls, fences, posts, stairs, furniture, containers or blocking lights built with this mod, and don't path through them. Player weapons can't break them either; sledgehammers and dismantling still work. Zombies still climb over low fences like vanilla, and crawling zombies still bang on them but can't break them. Windows and boards nailed over them still break like vanilla. Things already built change only when their area loads again: restart the server in multiplayer, reload the save in singleplayer[/td][/tr]
[tr][td]Zombies can't break doors[/td][td]Off[/td][td]On/off[/td][td]Doors built with this mod get very high durability: zombies still bang on them but can't break them. Doors built before this option existed aren't recognized and break like vanilla. Doors already built change only when their area loads again: restart the server in multiplayer, reload the save in singleplayer[/td][/tr]
[tr][td]Container capacity multiplier[/td][td]1.0[/td][td]1–10[/td][td]Multiplies the capacity of containers built with this mod, rounded, up to 100 (the game's limit), fridge freezers too. When it goes down, the items inside stay, but no more fit. Containers already built change only when their area loads again: restart the server in multiplayer, reload the save in singleplayer[/td][/tr]
[tr][td]Disabled sources (mod IDs)[/td][td]MinidoracatKnoxPassFor42;MinidoracatEconomyFor42;Machinery;Neat_Building;zodi_cisterns;LifestyleHobbies[/td][td]Mod IDs separated by semicolons[/td][td]Tiles from these mods can't be built. By default the Minidoracat family mods, mods whose tiles belong to their own build menus, and Lifestyle: Hobbies, which gives hobby functions by tile name, are off. The default only applies to new worlds, and existing worlds keep the setting in their save[/td][/tr]
[tr][td]Disabled tilesets[/td][td]Empty[/td][td]Tileset names separated by semicolons[/td][td]Tiles from these tilesets can't be built, for example walls_exterior_house_01[/td][/tr]
[/table]
The other page, Minidoracat Build Anything: what can be built, has 24 checkboxes, all on by default except Wells and Hand Pumps and Water. A kind that is off can't be seen or built by players, and things already built stay and can still be dismantled.
[table]
[tr][th]Option[/th][th]Covers[/th][/tr]
[tr][td]Floor[/td][td]Floors, including flat roof floors[/td][/tr]
[tr][td]Floor overlay[/td][td]Rugs, road markings and other overlays laid on a floor[/td][/tr]
[tr][td]Water[/td][td]Water dug into natural ground at ground level, off by default[/td][/tr]
[tr][td]Wall[/td][td]Walls, including corner walls that cover two sides. Corner posts are under Post[/td][/tr]
[tr][td]Fence[/td][td]Fences and railings you can climb over[/td][/tr]
[tr][td]Post[/td][td]Corner posts and fence posts[/td][/tr]
[tr][td]Wall overlay[/td][td]Decorative pieces laid over a wall[/td][/tr]
[tr][td]Door[/td][td]Doors. They go into a door frame[/td][/tr]
[tr][td]Window[/td][td]Windows. They go into a window frame; windows drawn together with their frame go straight on a wall edge[/td][/tr]
[tr][td]Door frame[/td][td]Door frames[/td][/tr]
[tr][td]Window frame[/td][td]Window frames[/td][/tr]
[tr][td]Window fitting[/td][td]Blinds, shutters and other fittings hung on a window[/td][/tr]
[tr][td]Curtain[/td][td]Curtains hung on the indoor side of a window[/td][/tr]
[tr][td]Roof[/td][td]Roof pieces and eaves[/td][/tr]
[tr][td]Stairs[/td][td]Three-piece stairs[/td][/tr]
[tr][td]Furniture[/td][td]Furniture and objects that can be picked up[/td][/tr]
[tr][td]Container[/td][td]Containers you can store items in, such as cabinets, fridges and crates[/td][/tr]
[tr][td]Wells and Hand Pumps[/td][td]Wells and hand pumps with water that never runs out, off by default[/td][/tr]
[tr][td]Solid object[/td][td]Objects that block the whole square and can't be picked up[/td][/tr]
[tr][td]Light[/td][td]Lights, light switches, street lights and lit signs[/td][/tr]
[tr][td]Wall-mounted[/td][td]Things hung on a wall, such as pictures, shelves and signs[/td][/tr]
[tr][td]Attached object[/td][td]Objects attached to the side of a wall or to a ceiling[/td][/tr]
[tr][td]Overlay[/td][td]Other overlay pieces[/td][/tr]
[tr][td]Plants[/td][td]Ornamental plants you can move, grass and wildflowers. Decoration only[/td][/tr]
[/table]
[list]
[*] [b]Build cheat[/b]: with the build cheat on you never pay and need no tools, and like vanilla your character doesn't walk over and there is no distance limit. Multiplayer only counts Build Cheat mode in Edit your Admin Powers; in singleplayer the debug menu and admin panel switches count too (on by default in debug mode, as in vanilla).
[*] [b]After changing settings[/b]: the server checks the current settings on every placement.
[*] [b]Open windows[/b]: follow the new settings within a few seconds, so there is no need to reopen them.
[*] [b]With Enable building off[/b]: nobody can wire, but built lights and switches still work.
[*] [b]With Admins only[/b]: ordinary players can't wire, admins can, and lights and switches still work.
[*] [b]Safehouse[/b]: with Minidoracat Safehouse installed, every square follows its safehouse permissions.
[/list]
=== ⚙️ For server admins: other mods' facilities
Some mods give a tile its function by name (an ATM or a propane refill station, for example), so building one with Build Anything would hand out that facility. Those facilities are meant to be obtained the way their mod intends, so they are kept out of the catalog.
[h3]Already left out[/h3]
[table]
[tr][th]Facility[/th][th]Mod[/th][th]When left out[/th][/tr]
[tr][td]Solar panels and battery banks[/td][td]PSR, Immersive Solar Arrays[/td][td]Always[/td][/tr]
[tr][td]Propane refill stations[/td][td]Arcadia Refillable Propane Tanks[/td][td]When that mod is installed[/td][/tr]
[tr][td]ATMs[/td][td]Minidoracat Economy[/td][td]When that mod is installed[/td][/tr]
[tr][td]Elevators[/td][td]Elevators[/td][td]When that mod is installed[/td][/tr]
[tr][td]Hydraulic presses[/td][td]Machinery[/td][td]When that mod is installed[/td][/tr]
[tr][td]Hobby facilities: easels, carving stations, invention workbenches, over a thousand paintings and the like[/td][td]Lifestyle: Hobbies[/td][td]Off by default in new worlds[/td][/tr]
[/table]
[list]
[*] [b]Lifestyle: Hobbies[/b]: it gives hobby functions by tile name, so building those tiles directly would skip hobby progress. That's why Disabled sources (mod IDs) includes LifestyleHobbies by default in new worlds.
[*] [b]Existing worlds[/b]: keep the setting in their save, and admins can turn it on or off on the Sources page of the Manage panel.
[/list]
These are not in the catalog either:
[list]
[*] [b]Tiles vanilla rewrites[/b]: tiles vanilla Lua changes when the map loads, for example feeding troughs and traps.
[*] [b]Build recipe facilities[/b]: facility tiles meant to be built from a build recipe are not listed as tiles; they are listed as recipe items instead, see Build recipes.
[*] [b]Tiles that never run dry[/b]: natural water and the like. Wells and hand pumps are the exception: they are a separate kind that is off by default, see Furniture and containers. The natural water floor tiles are another exception, listed as Water, off by default and only dug into natural ground, see Water.
[*] [b]Others[/b]: unbreakable windows, stacked crate tiles (the game swaps them for another tile when a save loads), and the hidden floors and underground blocks the game uses internally.
[*] [b]Things that turn into a special item when picked up[/b]: tents, sleeping bags, radios, propane tanks and the like (cots and gurneys are the exception, listed under Furniture).
[/list]
[h3]When another mod on your server has such facilities[/h3]
[olist]
[*] [b]Find the tileset[/b]: select the facility in Build Anything, and the first line of the details reads Source: mod name (tileset).
[*] [b]Turn it off in game[/b]: with the facility selected, press Turn off this tileset or Turn off this source in the details, or turn it off on the Tilesets or Sources page of the Manage panel, see Admin panel.
[*] [b]Or in the sandbox: turn off the tileset[/b]: add the tileset name to the sandbox option Disabled tilesets, several separated by semicolons.
[*] [b]Or in the sandbox: turn off the whole mod[/b]: add its mod ID to Disabled sources (mod IDs), and none of its tiles can be built.
[*] [b]Keep the defaults[/b]: when editing Disabled sources (mod IDs), keep the default mod IDs.
[*] [b]On the players' side[/b]: the tiles you turned off can no longer be built, and open windows follow the change.
[/olist]
[list]
[*] [b]Only a few tiles[/b]: ask that mod's author to call the API in the next chapter.
[/list]
=== ⚙️ For mod authors
If your mod gives tiles a function by name and you don't want players building them with Build Anything, take them out of the catalog:
[code]
Events.OnGameBoot.Add(function()
    if MinidoracatBuilder and MinidoracatBuilder.Rules and MinidoracatBuilder.Rules.addLuaSprites then
        MinidoracatBuilder.Rules.addLuaSprites({ "mymod_tiles_01_0", "mymod_tiles_01_1" })
    end
end)
[/code]
[list]
[*] [b]Argument[/b]: an array of full tile names (tileset_number), listed one by one.
[*] [b]Items with several facings[/b]: list the tile for every facing. If you list only some, the item stays in the catalog and just can't be turned to the listed facings.
[*] [b]Put it in shared[/b]: the client catalog and the server's build check both read this list, so both sides must call it.
[*] [b]When to call it[/b]: Build Anything catalogs tiles when the game starts, and OnGameBoot fires before that.
[*] [b]Dedicated servers[/b]: OnGameBoot fires there too.
[*] [b]Without Build Anything[/b]: the check above skips the call.
[*] [b]A whole tileset[/b]: server admins can also turn it off in the Manage panel or the sandbox option Disabled tilesets.
[/list]
=== ⚠️ Known limitations
[list]
[*] [b]Lights in your own rooms go dark after a rebuild[/b]: building walls, doors, windows or floors in or next to a lit room you built darkens the room while the switch still shows on.
[*] [b]Fix[/b]: press the switch twice.
[*] [b]After loading a singleplayer save[/b]: your own rooms go dark the same way, and pressing the switch twice fixes it.
[*] [b]Your own houses are off the grid[/b]: as in vanilla, lights need a generator.
[*] [b]Vanilla lights that can't be moved[/b]: lights that can't be moved and weren't built with Build Anything can't be switched where there is no room (for example your own houses in multiplayer), as in vanilla.
[*] [b]Lights built with Build Anything[/b]: are not affected by the previous point.
[*] [b]Double doors and garage doors[/b]: not supported yet.
[*] [b]No dragging rows with a gamepad[/b]: a gamepad places one item at a time.
[*] [b]Some furniture can't rotate[/b]: when the game doesn't link the facings into one object, and the tiles share a name with several versions or are pieces the game doesn't group into one object (the vanilla office desk, for example), each tile is its own item with one facing; pick the item with the facing you want.
[*] [b]Split screen[/b]: only the first player can open Build Anything.
[*] [b]Disassembling containers the vanilla way[/b]: vanilla Disassemble on a container that can't be moved loses what is inside, the same for vanilla-built ones.
[*] [b]Before removing a container[/b]: empty it first, or use Dismantle (Build Anything), which asks you to empty it.
[*] [b]After a server crash[/b]: lights that can't be moved and were built after the last save can't be dismantled with Build Anything, only smashed with a sledgehammer.
[*] [b]Floor overlays after a server crash[/b]: overlays built after the last save, if still there, can't be dismantled with Build Anything; they go away when that square's floor is replaced. Wall overlays stuck to a wall behave the same: they go away when that wall is replaced or dismantled.
[/list]
=== ⚠️ Before removing this mod
You can add the mod mid-save. When you remove it, everything you built stays, but a few things change.
[h3]Do this first[/h3]
[olist]
[*] [b]Switch lights off[/b]: turn off the lights you want off. After removal in multiplayer, switches and immovable lights built with Build Anything inside houses you built yourself don't respond.
[*] [b]Street lights in singleplayer[/b]: switch off street lights and signs that are lit at night before you save, or after removal their heads keep looking lit (without giving light).
[*] [b]Remove ground floors[/b]: dismantle ground floors you don't want with Dismantle (Build Anything), since after removal neither vanilla Disassemble nor a sledgehammer can remove them.
[*] [b]Remove lights you don't want[/b]: immovable lights built with Build Anything can only be smashed with a sledgehammer after removal, for no materials.
[*] [b]Remove fireplaces and stoves you don't want[/b]: fireplaces and immovable stoves built with Build Anything can only be smashed with a sledgehammer after removal, for no materials.
[*] [b]Remove floor overlays and wall overlays you don't want[/b]: road markings, cracks, and baseboards or graffiti stuck to walls, built with Build Anything, can't be removed after removal.
[*] [b]Zombie-proof builds and container capacity[/b]: to turn what you built back to vanilla, switch off Zombies can't break builds and Zombies can't break doors, set Container capacity multiplier back to 1, restart the server (reload the save in singleplayer), then visit every place you built so the area loads again. This can't be changed after removal.
[*] [b]Multiplayer server[/b]: shut the server down, back up the save, remove MinidoracatBuilderFor42 from Mods= and this mod's Workshop ID from WorkshopItems= in the server settings, then start it again.
[*] [b]Singleplayer[/b]: back up the save, remove this mod from that save's mod list, then load it.
[/olist]
[h3]What you built, after removal[/h3]
[list]
[*] [b]Walls, fences and stairs[/b]: walls still block, fences can be climbed over as in vanilla, and stairs can be climbed.
[*] [b]Zombies[/b]: can still break walls and fences; what had become zombie-proof before removal stays that way.
[*] [b]Doors, windows and curtains[/b]: open and close as in vanilla.
[*] [b]Containers[/b]: the items inside are still there, and the capacity stays as it was before removal.
[*] [b]Movable lights[/b]: switch them on and off directly, or pick them up as in vanilla.
[*] [b]Loading[/b]: the save loads without errors.
[/list]
[h3]Switches and lights[/h3]
[list]
[*] [b]Your own house, singleplayer[/b]: a switch built with Build Anything works the vanilla way and switches all lights in its room together, movable ones included.
[*] [b]Your own house, multiplayer[/b]: switches and immovable lights built with Build Anything don't respond, and lights stay as they were when the game was saved.
[*] [b]Houses from the map[/b]: a switch built with Build Anything switches together with the room's own switch, the vanilla way, but the lights wired to it don't follow. Immovable lights built with Build Anything can be switched directly. Same in singleplayer and multiplayer.
[*] [b]What was tested[/b]: these results come from a small house built with Build Anything and a bedroom that came with the map.
[/list]
[h3]Removing things after removal[/h3]
[list]
[*] [b]Walls[/b]: vanilla Disassemble or a sledgehammer.
[*] [b]Immovable lights, fireplaces and immovable stoves[/b]: only by smashing with a sledgehammer.
[*] [b]Ground floors[/b]: can't be removed.
[*] [b]Floor overlays[/b]: can't be removed, like the map's own road markings; they go away when that square's floor is replaced. Wall overlays stuck to a wall can't be removed either; they go away when the wall is dismantled or sledgehammered.
[/list]
[h3]Adding the mod back[/h3]
[list]
[*] [b]Restored[/b]: wiring and Dismantle (Build Anything) work again.
[*] [b]Lights picked up while it was removed[/b]: are no longer wired.
[/list]
=== ❓ FAQ
[h3]I can't find what I want to build[/h3]
[list]
[*] Set the source back to All sources, the tab to All, and untick Only what I can build.
[*] Search its full tile name, use the eyedropper to click it in the world, or right-click the ground and choose Pick tile (Build Anything). Tiles you can't build tell you why, for example the admin turned off their kind, source or tileset.
[*] Some things are never in the catalog, such as tents, sleeping bags and other things that turn into a special item when picked up, and metal drums; Lifestyle: Hobbies tiles are off by default in new worlds. See For server admins: other mods' facilities. Rain collectors and other things from the vanilla build menu are the items marked Recipe.
[/list]
[h3]An item is dimmed. Can I still build it?[/h3]
[list]
[*] Yes, you can select and build it, and dimmed means you lack materials or tools.
[*] Materials (have / need) in the details shows how many.
[*] When the server turns on Require vanilla skill levels, a skill that's too low dims it too, and you can build it once you reach the level in the details.
[*] When dragging a row, only the tiles you can afford are built.
[/list]
[h3]My fireplace can't be lit[/h3]
[list]
[*] Fireplaces built with this mod in 0.6.1 or earlier can't be lit. Dismantle them with Dismantle (Build Anything) and build them again, and then you can add fuel and light them.
[/list]
[h3]Why doesn't my light turn on?[/h3]
[list]
[*] It needs power, and your own houses are off the grid, so hook up a generator.
[*] Street lights and some signs only light up at night; their details say so.
[*] If it is wired to a switch, check whether the switch is off.
[*] Right-click the light and choose Circuit (Build Anything) to see how many switches control it.
[/list]
[h3]Why didn't my switch wire the lights?[/h3]
[list]
[*] Automatic wiring only works in closed rooms of at most 400 squares, within the circuit limits and permissions.
[*] With several groups of switches in a room, lights placed later aren't wired automatically.
[*] If it doesn't wire, right-click the switch and choose Wiring... (Build Anything) to wire it by hand.
[/list]
[h3]Does my own house count as indoors?[/h3]
[list]
[*] Once a rain-proof roof is built, the square below is no longer outdoors.
[*] For the room to count as indoors (temperature), the level above also needs a floor.
[/list]
[h3]Why do I get little or no XP?[/h3]
[list]
[*] The higher your skill, the better your chance of getting the materials back when dismantling, so building gives less XP.
[*] Things that always come back in full give no XP.
[*] Dirt, gravel and sand floors, and materials you didn't actually pay, give no XP.
[/list]
[h3]Can I dismantle things built in vanilla or other ways?[/h3]
[list]
[*] No. Dismantle (Build Anything) and Dismantle an area only remove what Build Anything built and do not replace the vanilla sledgehammer: things built in vanilla or other ways, and what the map already had, are picked up, disassembled or smashed with a sledgehammer as in vanilla.
[/list]
[h3]Can I add it to an existing save?[/h3]
[list]
[*] Yes, install it and it works in your existing save.
[/list]
[h3]What should I do before removing this mod?[/h3]
[list]
[*] Switch lights off, then dismantle ground floors, floor overlays and immovable lights you don't want, as Before removing this mod explains.
[/list]
=== 💬 Reporting issues
[list]
[*] [b][url=https://github.com/Minidoracat/MinidoracatBuilderFor42/issues]GitHub Issues[/url][/b]
[*] [b][url=https://discord.gg/Gur2V67]Discord[/url][/b]: please include
[list]
[*] Game mode (singleplayer / multiplayer)
[*] What happened and the steps to reproduce it
[*] Error messages (if any)
[*] console.txt, when a notice asks for it
[/list]
[*] [b]Translations[/b]: please report translation issues.
[/list]
