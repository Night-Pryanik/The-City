@tool
extends "res://scripts/main_map/view.gd"

# This link — what the player knows about the world: the fog of war, the scouted and the claimed
# hexes, the technologies that open the scouting beyond the Region and the outposts, and the
# interaction gates built on top of them.

# Is the technology "Cartography" learned. It opens the scouting beyond the
# Region: the fog of war and the territory of the towns. Before it the scouts can be
# sent only into the unexplored part of the Region, and the hexes outside the Region
# are inaccessible for the hover and the click (see is_hex_interactive).
func is_cartography_researched() -> bool:
    return CityData.is_tech_unlocked(CARTOGRAPHY_TECH_ID)

# The name of the technology "Cartography" for the messages to the player (the single source of
# the id — CARTOGRAPHY_TECH_ID; if the technology is renamed in the JSON, the message
# will update automatically).
func get_cartography_tech_name() -> String:
    return CityData.get_tech_name(CARTOGRAPHY_TECH_ID)

# Is the technology "Emporia" learned. It allows building improvements on scouted
# resource hexes outside the Region (outposts).
func is_emporia_researched() -> bool:
    return CityData.is_tech_unlocked(EMPORIA_TECH_ID)

# The name of the technology "Emporia" for the messages to the player.
func get_emporia_tech_name() -> String:
    return CityData.get_tech_name(EMPORIA_TECH_ID)

# Is the hex a place where an outpost improvement can be built: a scouted hex
# outside the Region with a revealed resource that has an ordinary improvement
# (the "improved_by" field) and no foreign or already built structure. The
# improvement itself still needs the "Emporia" technology — this check is only
# about the land and the resource.
func is_outpost_build_target(row: int, col: int) -> bool:
    if not is_hex_on_map(row, col) or is_valid_hex(row, col):
        return false
    var tile = tile_data[row][col]
    if tile == null:
        return false
    if not bool(tile.get("is_explored", false)):
        return false
    if bool(tile.get("in_influence", false)) or bool(tile.get("in_town_influence", false)) \
            or bool(tile.get("has_town", false)) or bool(tile.get("decorative", false)):
        return false
    if tile.get("improvement", null) != null:
        return false
    var res_id := MapHelpers.get_effective_resource(tile)
    if res_id == "" or not MapHelpers.is_resource_revealed(tile):
        return false
    var improved_by = GameData.raw_resources.get(res_id, {}).get("improved_by", null)
    if improved_by == null:
        return false
    return MapHelpers.improvement_needs_road(str(improved_by))

# A built improvement outside the Region — an outpost. The status is derived from
# the tile, so no separate save field is needed.
func is_outpost_improvement(row: int, col: int) -> bool:
    if not is_hex_on_map(row, col) or is_valid_hex(row, col):
        return false
    var tile = tile_data[row][col]
    if tile == null or tile.get("improvement", null) == null:
        return false
    return not bool(tile.get("in_influence", false)) \
            and not bool(tile.get("decorative", false)) \
            and not bool(tile.get("in_town_influence", false))

# The one-time fee in coins for building an outpost on this hex.
func get_outpost_fee(row: int, col: int) -> int:
    return MapHelpers.get_outpost_fee(row, col, city_row, city_col)

# Is the hex available for the interaction of the player: the tooltip on hover,
# the highlighting of the chunk of the scouting/purchase, the selection by a click of the LMB. The Region is available
# always (including its unexplored part — the scouting works there),
# the fog of war — only after the learning of the Cartography. The hexes beyond
# the edge of the map are unavailable always.
func is_hex_interactive(row: int, col: int) -> bool:
    if not is_hex_on_map(row, col):
        return false
    if is_valid_hex(row, col):
        return true
    return is_cartography_researched()

# Is the hex already known to the player: its own Influence Ring (in_influence) or
# a scouted hex (is_explored). This is the "border of the known world" — only from
# it the scouts can be sent further (see is_chunk_adjacent_to_known).
# The influence rings of the other towns do NOT enter here: their territory is not ours.
# The flag is_explored of the Influence Ring is deliberately not set (see
# _initialize_map: the whole world, including the Ring, starts with is_explored = false),
# therefore in_influence is checked separately — otherwise at the start of a new game
# there would be nothing to scout at all (a soft-lock).
func is_hex_known(row: int, col: int) -> bool:
    if not is_hex_on_map(row, col):
        return false
    var tile = tile_data[row][col]
    if tile == null:
        return false
    return bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false))

# Does the chunk have at least one hex bordering the territory known to the player
# (see is_hex_known). The scouting can be sent only into an
# "adjacent" chunk: otherwise the scouts would jump over the fog of war and
# uncover the islets far away from the border of the known world.
# The CHUNK is checked, and not the clicked hex: the BFS-chunk (up to 5 hexes), which has reached
# the border of the known world, is allowed, even if the click itself was made on a hex
# one step deeper. This agrees with the fact that the chunk is the unit of the action.
# The neighbours are taken through HexUtils.get_neighbors_odd_r (it also clips them by the edges of
# the map), that is, going out of the map is impossible here.
func is_chunk_adjacent_to_known(chunk: Array) -> bool:
    for hex in chunk:
        for n in HexUtils.get_neighbors_odd_r(hex.row, hex.col, map_rows, map_cols):
            if is_hex_known(n.row, n.col):
                return true
    return false

# Is the hex hidden by the fog of war: the information about it (the terrain, the resources,
# the improvements) is not known to the player, therefore the tooltip on hover and the left column
# of the control panel must not show it. The fog is a hex on the map which is NOT
# a part of the Influence Ring, is NOT scouted and lies outside the Region: the Ring+Region are visible
# on the map (there the player knows the terrain, and the resources are opened by the scouting —
# see map_tooltip._build_text), beyond them nothing is visible.
# The gate is used by the tooltip (InputHandler and update_tooltip_text) and by the left column
# of the panel (control_panel._refresh); the highlighting of the chunk and the button of the scouting remain —
# they do not disclose the contents of the hex.
func is_hex_in_fog(row: int, col: int) -> bool:
    if not is_hex_on_map(row, col):
        return false
    if is_valid_hex(row, col):
        return false
    var tile = tile_data[row][col]
    if tile == null:
        return false
    return not (bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)))
