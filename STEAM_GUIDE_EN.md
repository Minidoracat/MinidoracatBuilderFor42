<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3830047545 -->
<!-- Steam guide source (English). The full description lives in this guide; the Workshop page only has a summary. Format and sync: pz-family-docs/release.md "完整說明：Steam 指南" -->
<!-- 標題：📖 Minidoracat Build Anything Mod Guide: Build Window, Materials, Wiring and Dismantling -->
<!-- 摘要：A picture guide to Minidoracat Build Anything: searching, tabs, sources and favorites in the build window, picking a tile with a right-click, placing and dragging rows, the rules for walls, posts, doors and windows, curtains, stairs, roofs, furniture, lights and containers, materials, tools and XP, switches and wiring, dismantling and gamepad controls, plus the admin panel, the sandbox options, how to turn off other mods' facilities, the API for mod authors, known limitations and what to do before removing the mod. -->
<!-- Screenshots: docs/screenshots/steam/en/ -->
=== 🚀 Quick start
[b]中文版：[/b] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3830047491]Minidoracat Build Anything MOD 完整說明[/url]
https://steamcommunity.com/sharedfiles/filedetails/?id=3830045886
Build with any loaded tile, including other mods' tile packs; you pay for what you build with materials.
{{img:01-overview-en.jpg}}
[olist]
[*] [b]Open the window[/b]: click the Build Anything button on the family toolbar (a hammer and a handsaw).
[*] [b]Find something[/b]: search by name, narrow it down with the tabs, kinds, tilesets and sources, or right-click the ground and choose Pick tile (Build Anything).
[*] [b]Check the details[/b]: select an item, and the right side lists materials, tools, XP and how it is removed.
[*] [b]Place it[/b]: press Build, then click the ground.
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
[*] [b]Other looks of a tile[/b]: an open door, a smashed window, a closed curtain, one square of a multi-square object and the like select the item they belong to.
[*] [b]Tiles you can't build[/b]: searching a full name tells you why, for example which build recipe it belongs to or which kind the admin turned off.
[*] [b]Tabs[/b]: All, Floors, Walls, Doors & windows, Roofs, Stairs, Furniture, Lights, Decor.
[*] [b]Left side[/b]: Mine (Favorites, Recently used), Kinds and Tilesets, with item counts in parentheses.
[*] [b]Only what I can build[/b]: lists only items you have the materials and tools for, counting your inventory, bags and items on the ground next to you.
[*] [b]One item per object[/b]: the facings of one object are one item.
[*] [b]Different objects with the same name[/b]: each is listed separately.
[*] [b]Order[/b]: items from the same tileset are sorted by number.
[*] [b]Nothing found[/b]: an empty list tells you why, for example try a shorter word, or switch to All sources and the All tab.
[*] [b]Kinds the admin turned off[/b]: you can't see or build them, the status line says the admin turned off N kinds, and a tab whose kinds are all off can't be selected.
[*] [b]When the admin changes settings[/b]: an open window follows within a few seconds, so there is no need to reopen it.
[/list]
[h3]Pick tile with a right-click[/h3]
{{img:15-pick-en.jpg}}
[list]
[*] [b]How[/b]: right-click the ground and choose Pick tile (Build Anything).
[*] [b]What it lists[/b]: every image on that square, including overlays on the floor and on walls.
[*] [b]Pick one[/b]: Build Anything opens with that item selected.
[*] [b]Tiles you can't build[/b]: shown in red, and hovering one tells you why.
[*] [b]Gamepad[/b]: works too.
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
[*] [b]Items you can't afford[/b]: the name is dimmed with a warning in the top right, and you can still select and build them.
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
[*] [b]Experience[/b]: which skill gets how much XP, or Experience: none.
[*] [b]Notes[/b]: kinds with extra rules, such as stairs, roofs, lights and curtains, get a note.
[*] [b]Scrolling[/b]: when the details are taller than the window, scroll with the mouse wheel or the scroll bar.
[*] [b]Admin shortcuts[/b]: see Admin panel.
[/list]
=== 🧰 Placing and dragging
{{img:04-cursor-en.jpg}}
[h3]The cursor[/h3]
[list]
[*] [b]After pressing Build[/b]: the window hides and a ghost appears on the ground.
[*] [b]Ghost colours[/b]: white means it can be built, red means it can't, with a warning on that square.
[*] [b]Multi-tile objects[/b]: when blocked, the square causing the problem gets a red frame and the others a grey one.
[*] [b]The box by the mouse[/b]: shows the name, facing, how many tiles you are dragging, why it can't be built and the key hints.
[*] [b]Rotate[/b]: press the Rotate Building key (R by default), which only cycles through the facings that object has.
[*] [b]Rebound keys[/b]: go by the key hints in the box by the mouse.
[*] [b]Clicking on the UI doesn't build[/b]: a click on the window or other UI never builds on the square underneath.
[*] [b]Keep building[/b]: the cursor stays after you build.
[*] [b]Cancel[/b]: right-click to cancel, and the window comes back.
[*] [b]Pick something else[/b]: while placing you can reopen the window from the toolbar.
[/list]
[h3]Dragging a row[/h3]
{{img:05-drag-en.jpg}}
[list]
[*] [b]What you can drag[/b]: floors, walls, posts, fences and roofs, by holding the left button, dragging, and releasing to queue them.
[*] [b]Summary in the box[/b]: N tiles: A buildable, B skipped.
[*] [b]When short[/b]: the box says what those tiles still need together.
[*] [b]Materials for only the first few[/b]: only the tiles you can afford are built, and the rest are skipped.
[*] [b]At most[/b]: 32 items per drag by default, and the admin can change it.
[/list]
{{img:06-queued-en.jpg}}
[list]
[*] [b]Queued tiles[/b]: after you release, tiles not built yet keep a faint ghost and a blue frame, one fewer each time a tile is done.
[*] [b]After closing the cursor[/b]: your character keeps building.
[*] [b]Dragging another row[/b]: cancels the tiles still queued from the last row, and before you release the box tells you how many.
[/list]
[h3]Distance and where you stand[/h3]
[list]
[*] [b]Maximum distance[/b]: 3 tiles by default, at most one level up or down, and the admin can change it.
[*] [b]Your character walks over[/b]: it walks next to each tile before building.
[*] [b]Things on a square's edge[/b]: walls, doors, windows and fences sit on the edge of a square and can be built from either side.
[*] [b]Places you can't reach[/b]: through a wall or a closed door or window, furniture and the like can't be placed.
[*] [b]Someone standing there[/b]: things that block movement are not placed on a square where a player or zombie stands.
[*] [b]When you can't build[/b]: in a vehicle or dead.
[/list]
[h3]Refusals and stops[/h3]
{{img:11-refused-en.jpg}}
[list]
[*] [b]The server tells you why[/b]: missing materials, a missing tool, too far, unreachable, blocked, or inside someone else's safehouse, with a notice saying what to do.
[*] [b]Stopping halfway[/b]: when interrupted or the way is blocked, a notice says how many tiles were built.
[*] [b]Tiles not built[/b]: used no materials, so drag again to continue.
[*] [b]No room to stand[/b]: when a tile has no free square beside it, the notice says which one.
[*] [b]Building settings have changed[/b]: the admin changed a sandbox option, so reopen the window, and no materials were used.
[*] [b]When you pay[/b]: the server checks everything before placing and takes the materials only once it is placed, so a failure costs nothing.
[/list]
=== 🧰 Rules for each kind
[h3]Walls, floors and fences[/h3]
[list]
[*] [b]Zombies can break them[/b]: walls, posts and window frames have 450 durability, fences 300.
[*] [b]Stair openings[/b]: walls, fences and door frames can't block the way onto or off stairs.
[*] [b]Ground floors[/b]: dismantling one turns the square back into dirt.
[*] [b]Posts[/b]: the Post kind on the Walls tab has corner posts from wall corners, fence posts, and the corner posts wall recipes use.
[*] [b]Posts and zombies[/b]: like the corner posts vanilla adds when you build walls, zombies don't attack a post as if it were a wall, and it blocks moving diagonally past that corner.
[*] [b]Corner posts built earlier[/b]: those built in 0.1.0 and 0.1.1 become the same as new posts when the save loads, and zombies still attack the walls on that square.
[*] [b]Railing ends[/b]: railing ends that block only one side of a square are not listed (zombies would not come to break them), and a search tells you why.
[*] [b]Floors from build recipes[/b]: floors and floor overlays used by build recipes from vanilla or other mods (Neat Building, for example) can be built too.
[*] [b]Other recipe pieces[/b]: walls, fences and anything else with its own functions are still built from the vanilla build menu or that mod's menu.
[/list]
[h3]Doors and windows[/h3]
[list]
[*] [b]Doors[/b]: only the closed tile is listed, and once placed it opens and closes as in vanilla.
[*] [b]Double doors and garage doors[/b]: not supported yet.
[*] [b]Windows[/b]: open, smashed and glass-removed tiles are not listed, so you always place a whole window.
[*] [b]Unbreakable windows[/b]: not in the catalog.
[*] [b]Permanently locked windows[/b]: listed, and the details say Permanently locked.
[*] [b]What permanently locked means[/b]: it can't be opened but can be smashed, so it works as a fixed window.
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
[*] [b]From the second floor up[/b]: needs a wall below, or a floor or roof beside it holding it up.
[*] [b]Above stairs[/b]: not allowed directly above stairs.
[*] [b]Which level[/b]: the cursor builds one level up at the same spot on screen by default.
[*] [b]Changing level[/b]: PgUp/PgDn switches between one level up and this level.
[*] [b]Dragging a row[/b]: start from the supported end, since each tile holds up the next.
[*] [b]Keeping rain out[/b]: once a rain-proof roof is built, the square below is no longer outdoors.
[*] [b]Counting as indoors (temperature)[/b]: the level above also needs a floor.
[*] [b]Roof pieces that let rain in[/b]: eaves and many roof pieces never kept rain out, and the details point them out.
[/list]
[h3]Furniture and containers[/h3]
[list]
[*] [b]Zombies can break them[/b]: everything that blocks movement can be broken, including furniture, crates, rocks, and blocking wall-mounted objects, rugs and tabletop items.
[*] [b]Ordinary furniture durability[/b]: the same as when moved and placed in vanilla, tougher the heavier it is and the harder its material.
[*] [b]Small blocking things[/b]: wall-mounted objects, rugs and tabletop items have 100 durability, and break more slowly when fewer than 8 zombies are attacking.
[*] [b]Things that don't block[/b]: zombies leave them alone.
[*] [b]Movable things[/b]: once placed, pick them up and move them as in vanilla.
[*] [b]Sinks, toilets and bathtubs[/b]: as when moved in vanilla, they need plumbing again to get water.
[*] [b]Containers[/b]: hold items right away.
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
=== 🧰 Materials, tools and XP
[h3]What it costs[/h3]
[list]
[*] [b]Tiles with vanilla dismantle materials[/b]: cost what dismantling them gives, never less than you could get back.
[*] [b]Tiles without[/b]: cost the same as the matching vanilla build, see the table below.
[*] [b]Electrical things[/b]: 1 extra Scrap Electronics (one per tile for multi-tile ones), which you don't get back when dismantling.
[*] [b]Movable lights[/b]: 1 extra Light Bulb (in vanilla you can take the bulb out).
[*] [b]Material multiplier[/b]: every amount is multiplied by the admin's multiplier and rounded up.
[*] [b]Exceptions below 1[/b]: tiles with dismantle materials, curtains, and the extra Light Bulb for movable lights still cost at least 1×.
[*] [b]Admins with the build cheat on[/b]: pay nothing.
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
[tr][td]Window[/td][td]4 Glass Pane + 2 Plank + 4 Nails[/td][td]As wood[/td][td]As wood[/td][/tr]
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
[/list]
[h3]Where to keep materials[/h3]
[list]
[*] [b]Bags or the ground next to you[/b]: your inventory, bags and the ground beside you all count.
[*] [b]Behind a wall[/b]: nothing there is taken.
[*] [b]Box of Nails[/b]: when you are short of nails, a Box of Nails in your inventory is opened and the leftovers go back into your inventory.
[/list]
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
[tr][td]Dirt, gravel and sand floors, curtains[/td][td]None[/td][/tr]
[/table]
[list]
[*] [b]The details decide[/b]: Tools (carry them) in the details lists exactly what to carry.
[*] [b]Furniture-style tiles[/b]: don't need the tools vanilla needs to move them.
[*] [b]Nothing wears out[/b]: tools only need to be on you.
[*] [b]Welding Torch[/b]: uses no fuel.
[/list]
[h3]XP[/h3]
[list]
[*] [b]No skill needed[/b]: nothing requires a skill level.
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
[*] [b]Click a light[/b]: adds or removes it.
[*] [b]Lights on another circuit[/b]: clicking one moves it over.
[*] [b]Click another switch[/b]: makes it two-way, and its whole circuit joins.
[*] [b]Click a wired switch[/b]: takes it off.
[*] [b]Several on one square[/b]: click again for the next one.
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
[*] [b]What it removes[/b]: walls, floors, roofs and stairs built with Build Anything, plus furniture and lights that can't be moved.
[*] [b]What it can't remove[/b]: things built in vanilla or other ways.
[*] [b]How[/b]: right-click and choose Dismantle (Build Anything), and your character walks over.
[*] [b]Tools[/b]: the same as for building.
[*] [b]Materials back[/b]: between 1 and all of each material, dropped at your feet.
[*] [b]XP[/b]: dismantling gives none.
[*] [b]Stairs[/b]: all three steps go together, and materials come back once.
[*] [b]Stair landing[/b]: the landing added with the stairs goes too, unless something is on it.
[*] [b]Multi-tile furniture[/b]: goes as one piece.
[*] [b]Ground floors[/b]: turn back into dirt.
[*] [b]Built with the build cheat[/b]: no materials back.
[/list]
[h3]Before you dismantle[/h3]
[list]
[*] [b]Containers[/b]: empty them, and pour the water out of rain collectors.
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
[*] [b]Roof level[/b]: X switches between one level up and this level.
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
[*] [b]Kinds[/b]: turn the 21 kinds on or off, such as floors, walls, posts and furniture.
[*] [b]Sources[/b]: turn all tiles from a mod on or off.
[*] [b]Tilesets[/b]: click a row to turn that tileset on or off, and filter the list with the box at the top.
[*] [b]Rules[/b]: the six rules from the sandbox page: Enable building, Who can build, Where players can build, Maximum build distance, Most items per drag and Material cost multiplier.
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
[tr][td]Most items per drag[/td][td]32[/td][td]1–64[/td][td]How many items one build request can place, for example a line of walls[/td][/tr]
[tr][td]Material cost multiplier[/td][td]1.0[/td][td]0–10[/td][td]Multiplies every material amount, rounded up. 0 = no ordinary materials, but tools are still needed. Tiles with dismantle materials, curtains and light bulbs never go below 1[/td][/tr]
[tr][td]Disabled sources (mod IDs)[/td][td]MinidoracatKnoxPassFor42;MinidoracatEconomyFor42;Machinery;Neat_Building;zodi_cisterns[/td][td]Mod IDs separated by semicolons[/td][td]Tiles from these mods can't be built. By default the Minidoracat family mods and mods whose tiles belong to their own build menus are off[/td][/tr]
[tr][td]Disabled tilesets[/td][td]Empty[/td][td]Tileset names separated by semicolons[/td][td]Tiles from these tilesets can't be built, for example walls_exterior_house_01[/td][/tr]
[/table]
The other page, Minidoracat Build Anything: what can be built, has 21 checkboxes, all on by default. A kind that is off can't be seen or built by players, and things already built stay and can still be dismantled.
[table]
[tr][th]Option[/th][th]Covers[/th][/tr]
[tr][td]Floor[/td][td]Floors, including flat roof floors[/td][/tr]
[tr][td]Floor overlay[/td][td]Rugs, road markings and other overlays laid on a floor[/td][/tr]
[tr][td]Wall[/td][td]Walls, including corner walls that cover two sides. Corner posts are under Post[/td][/tr]
[tr][td]Fence[/td][td]Fences and railings you can climb over[/td][/tr]
[tr][td]Post[/td][td]Corner posts and fence posts[/td][/tr]
[tr][td]Wall overlay[/td][td]Decorative pieces laid over a wall[/td][/tr]
[tr][td]Door[/td][td]Doors. They go into a door frame[/td][/tr]
[tr][td]Window[/td][td]Windows. They go into a window frame[/td][/tr]
[tr][td]Door frame[/td][td]Door frames[/td][/tr]
[tr][td]Window frame[/td][td]Window frames[/td][/tr]
[tr][td]Window fitting[/td][td]Blinds, shutters and other fittings hung on a window[/td][/tr]
[tr][td]Curtain[/td][td]Curtains hung on the indoor side of a window[/td][/tr]
[tr][td]Roof[/td][td]Roof pieces and eaves[/td][/tr]
[tr][td]Stairs[/td][td]Three-piece stairs[/td][/tr]
[tr][td]Furniture[/td][td]Furniture and objects that can be picked up[/td][/tr]
[tr][td]Container[/td][td]Containers you can store items in, such as cabinets, fridges and crates[/td][/tr]
[tr][td]Solid object[/td][td]Objects that block the whole square and can't be picked up[/td][/tr]
[tr][td]Light[/td][td]Lights, light switches, street lights and lit signs[/td][/tr]
[tr][td]Wall-mounted[/td][td]Things hung on a wall, such as pictures, shelves and signs[/td][/tr]
[tr][td]Attached object[/td][td]Objects attached to the side of a wall or to a ceiling[/td][/tr]
[tr][td]Overlay[/td][td]Other overlay pieces[/td][/tr]
[/table]
[list]
[*] [b]Build cheat[/b]: admins with the build cheat on never pay.
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
[/table]
These are not in the catalog either:
[list]
[*] [b]Tiles vanilla rewrites[/b]: tiles vanilla Lua changes when the map loads, for example feeding troughs and traps.
[*] [b]Vanilla build menu facilities[/b]: facility tiles meant to be built from the vanilla build menu.
[*] [b]Tiles that never run dry[/b]: natural water, wells and the like.
[*] [b]Others[/b]: unbreakable windows, stacked crate tiles (the game swaps them for another tile when a save loads), and the hidden floors and underground blocks the game uses internally.
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
[*] [b]Split screen[/b]: only the first player can open Build Anything.
[*] [b]Disassembling containers the vanilla way[/b]: vanilla Disassemble on a container that can't be moved loses what is inside, the same for vanilla-built ones.
[*] [b]Before removing a container[/b]: empty it first, or use Dismantle (Build Anything), which asks you to empty it.
[*] [b]After a server crash[/b]: lights that can't be moved and were built after the last save can't be dismantled with Build Anything, only smashed with a sledgehammer.
[/list]
=== ⚠️ Before removing this mod
You can add the mod mid-save. When you remove it, everything you built stays, but a few things change.
[h3]Do this first[/h3]
[olist]
[*] [b]Switch lights off[/b]: turn off the lights you want off. After removal in multiplayer, switches and immovable lights built with Build Anything inside houses you built yourself don't respond.
[*] [b]Street lights in singleplayer[/b]: switch off street lights and signs that are lit at night before you save, or after removal their heads keep looking lit (without giving light).
[*] [b]Remove ground floors[/b]: dismantle ground floors you don't want with Dismantle (Build Anything), since after removal neither vanilla Disassemble nor a sledgehammer can remove them.
[*] [b]Remove lights you don't want[/b]: immovable lights built with Build Anything can only be smashed with a sledgehammer after removal, for no materials.
[*] [b]Multiplayer server[/b]: shut the server down, back up the save, remove MinidoracatBuilderFor42 from Mods= and this mod's Workshop ID from WorkshopItems= in the server settings, then start it again.
[*] [b]Singleplayer[/b]: back up the save, remove this mod from that save's mod list, then load it.
[/olist]
[h3]What you built, after removal[/h3]
[list]
[*] [b]Walls, fences and stairs[/b]: walls still block, fences can be climbed over as in vanilla, and stairs can be climbed.
[*] [b]Zombies[/b]: can still break walls and fences.
[*] [b]Doors, windows and curtains[/b]: open and close as in vanilla.
[*] [b]Containers[/b]: the items inside are still there.
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
[*] [b]Immovable lights[/b]: only by smashing with a sledgehammer.
[*] [b]Ground floors[/b]: can't be removed.
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
[*] Search its full tile name, or right-click the ground and choose Pick tile (Build Anything). Tiles you can't build tell you why, for example the admin turned off their kind, source or tileset.
[*] Some things are never in the catalog, see For server admins: other mods' facilities.
[/list]
[h3]An item is dimmed. Can I still build it?[/h3]
[list]
[*] Yes, you can select and build it, and dimmed means you lack materials or tools.
[*] Materials (have / need) in the details shows how many.
[*] When dragging a row, only the tiles you can afford are built.
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
[*] Dismantle (Build Anything) only removes what Build Anything built, and everything else is picked up, disassembled or smashed as in vanilla.
[/list]
[h3]Can I add it to an existing save?[/h3]
[list]
[*] Yes, install it and it works in your existing save.
[/list]
[h3]What should I do before removing this mod?[/h3]
[list]
[*] Switch lights off, then dismantle ground floors and immovable lights you don't want, as Before removing this mod explains.
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
