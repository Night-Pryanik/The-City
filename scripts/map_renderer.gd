# map_renderer.gd
@tool
extends Node2D

const CITY_ICON_SIZE = 130
const TERRAIN_ICON_SIZE = 130
const RESOURCE_ICON_SIZE = 75
const IMPROVEMENT_ICON_SIZE = 35
# The thickness of the outline of the influence rings of the towns (in pixels).
const TOWN_INFLUENCE_BORDER_WIDTH = 3.0
# The opacity of the fill of the territory of the towns.
const TOWN_INFLUENCE_FILL_ALPHA = 0.22
# The style of the roads is common for the city of the player and the towns (only WHOSE
# roads they are differs, see _draw_all_roads).
const ROAD_COLOR = Color(0.55, 0.35, 0.15)
const ROAD_WIDTH = 6
# The style of the "ghost" road - the unbuilt route which the player is looking at
# right now in the preview. The main difference from a real road is the transparency: the route
# must read as a hint, and not as an already laid road, otherwise the player
# will decide that the road already exists. A halo + a line is drawn on top: thus the route
# is noticeable both on the light terrain and on the dark one.
const ROAD_PREVIEW_COLOR = Color(0.98, 0.86, 0.45, 0.8)
const ROAD_PREVIEW_WIDTH = 5
const ROAD_PREVIEW_HALO_COLOR = Color(0.98, 0.86, 0.45, 0.22)
const ROAD_PREVIEW_HALO_WIDTH = 12
# The style of the highlighting of the ROUTE - the roads along which the cargo is already going to the city.
# It differs from the ghost of the preview deliberately: the route consists of the EXISTING
# roads, and the transparency would say to the player "there is nothing here". Therefore
# this is a thin line on top of the road - it reads as "the path of the cargo", and not as
# "what will be built". Cyan was chosen because yellow is occupied
# by the ghost, and green by the highlighting of the hexes.
const ROUTE_COLOR = Color(0.35, 0.85, 0.95, 0.9)
const ROUTE_WIDTH = 3
# The radius of the icon markers drawn on top of the hex: a drop of fresh water by
# an improvement and a trade icon over a connected town. It is set by ONE
# constant, so that both markers are guaranteed to be of the same size.
const MARKER_ICON_RADIUS = 6.0
# The colour of the markers on the hex (the drop of water and the trade icon).
const MARKER_ICON_COLOR = Color(0.45, 0.8, 1.0)

var tile_data = []
# A local texture cache for the drawing of the map (a hot path: an access for
# every hex on every frame). The paths and the loading are given by IconRegistry - it has
# no index of its own for the renderer any more.
var icon_textures = {}

# A reference to the main node for the access to offset_x, offset_y, scroll_offset, build_manager and CityData
var main_map: Node

# A cache of the smoothed (meandering) points of the rivers in the WORLD coordinates (without the offset).
# The smoothing of the rivers (_generate_natural_river + _chaikin_smooth) is an expensive operation,
# which earlier was performed on every frame when the map was scrolled. The points of the rivers in the world
# coordinates do not change when panning, therefore the recalculation is needed only once
# per river. When scrolling it is enough to add the offset to the smoothed world points
# and perform the clipping. The key of the cache is a compact serialization of the coordinates of the river.
var _river_smooth_cache: Dictionary = {}

# The per-frame geometry of the rivers: the clipped screen-space polylines of every river that
# intersects the cached rectangle, keyed by _river_index. The key of validity is the offset the
# geometry was built for; within main_map.MAP_CACHE_MARGIN of it the entries are reused as they
# are (only _river_frame_offset moves), so panning does not re-clip anything.
var _river_frame_cache: Dictionary = {}
var _river_frame_cache_offset: Vector2 = Vector2.ZERO
# The current world -> screen offset, added at the drawing of the river polylines.
var _river_frame_offset: Vector2 = Vector2.ZERO
# Set by queue_redraw_for_scroll and consumed once per frame: the caches are re-checked lazily,
# so that several scroll steps within one frame do not rebuild them several times.
var _scroll_since_cache := false
# Counts the actual rebuilds of the geometry of the rivers. If the pan cache works, a continuous
# scroll of many frames must give far fewer rebuilds than frames - the test relies on it.
var _river_frame_rebuilds: int = 0

# --- The render cache of the influence rings of the towns (PHASE 1.7 / 1.7.1) ---
# The rings of the towns are static between the spawn/load/change of the epoch, but earlier
# they were recalculated AND drawn on every frame: hundreds of semi-transparent
# draw_colored_polygon (one per hex, with the trigonometry for each hex
# and each edge) + the allocation of the dictionaries membership for each town. When
# the rings intersected, the shared hexes were drawn N times (N = the number of towns),
# which additionally amplified the transparency and increased the load.
#
#
# Now the whole render cache is built once and is rebuilt only by
# invalidate_town_influence_cache() or when the visible Region
# changes (a change of the epoch). Per frame there remains: one draw_texture_rect for the fill and
# light cached draw_line for the borders.
var _town_cache_version: int = 0
var _town_cache_built_version: int = -1
# The world -> screen offset the fill texture of the rings was built for. It is reused while the
# map is scrolled within main_map.MAP_CACHE_MARGIN of it.
var _cache_built_offset: Vector2 = Vector2(INF, INF)
# The region borders for which the current cache is built. If the cache is built
# before a change of the epoch (the Region has expanded) - it is invalid and is rebuilt.
var _cache_region_start_row: int = -1
var _cache_region_end_row: int = -1
var _cache_region_start_col: int = -1
var _cache_region_end_col: int = -1
# The unique hexes of the rings of ALL the towns (without duplicates) in the world coordinates.
# Each record is { "cx": float, "cy": float } - the centre of the hex without the offset.
var _influence_fill_centers: Array = []
# The segments of the borders of the rings in the world coordinates (without the offset). Each record is
# { "p1": Vector2, "p2": Vector2, "color": Color, "row": int, "col": int }.
var _influence_border_segments: Array = []
# Step 2: a pre-render of the fill of the rings into ONE RGBA texture, which covers the current
# Region (the Ring + the Region). The frame render of the fill = one draw_texture_rect
# instead of hundreds of semi-transparent polygons. It is recreated on the invalidation of the cache.
var _influence_fill_texture: ImageTexture = null
var _influence_texture_origin: Vector2 = Vector2.ZERO
var _influence_texture_size: Vector2 = Vector2.ZERO

func initialize(td, main_node):
    tile_data = td
    main_map = main_node
    # We clear the cache of the rivers on the initialization (a new game / a load of a save),
    # so as not to keep the outdated smoothed points of the previous map.
    _river_smooth_cache.clear()
    _river_frame_cache.clear()
    _invalidate_screen_caches()
    # The rings of the towns could have changed (a new map / a load of a save):
    # we reset the cache of their render - it will be lazily rebuilt from the next frame.
    invalidate_town_influence_cache()

# Returns the size of the viewport in the pixels. In the editor get_viewport_rect()
# is unavailable (there is no window of the game) - we use a fallback value, as before.
func _get_viewport_size() -> Vector2:
    if Engine.is_editor_hint():
        return Vector2(1152, 768)
    return get_viewport_rect().size

# Returns a dictionary with the borders of the visible hexes (inclusive),
# limited by the area reachable by the scroll of the map (scout_reach).
# It is used for the viewport culling: instead of an iteration over the whole map
# we draw only those hexes which intersect the rectangle of the screen.
#
# The area is wider than the Region - this is needed for the two scenarios:
#   1. After the scouting, the hexes in the fog of war (outside the Region) must
#      be drawn as the ordinary ones - the fog "opens up", otherwise
#      the scouting has no visual effect. Beyond the Region this is possible
#      only after the study of Cartography (see main_map.is_hex_interactive).
#   2. The progress bar of the scouting can lie in the fog (the starting hex
#      of a chunk is not required to be in the Region) - this too is available only
#      after Cartography.
# `_draw_hex` and `_draw_hex_overlays` themselves decide what to draw:
# the unexplored hexes outside the Region are a real fog of war, and
# for them the function simply returns early.
func _get_visible_hex_range() -> Dictionary:
    var viewport_size = _get_viewport_size()

    var offset_x = main_map.offset_x + main_map.scroll_offset.x
    var offset_y = main_map.offset_y + main_map.scroll_offset.y

    var radius = main_map.HEX_RADIUS
    var x_spacing = radius * sqrt(3.0)
    var y_spacing = radius * 1.5

    # The rectangle of the viewport in the map coordinates (before the offset).
    var world_left = - offset_x
    var world_top = - offset_y
    var world_right = world_left + viewport_size.x
    var world_bottom = world_top + viewport_size.y

    # A margin of 2 hexes, to account for the offset of the odd rows
    # and the partially visible hexes at the edges of the screen.
    var margin = 2

    var col_start = int(floor(world_left / x_spacing)) - margin
    var col_end = int(ceil(world_right / x_spacing)) + margin
    var row_start = int(floor(world_top / y_spacing)) - margin
    var row_end = int(ceil(world_bottom / y_spacing)) + margin

    # We limit it by the area reachable by the scroll of the map (scout_reach).
    var reach = main_map.get_scout_reach_bounds()
    col_start = max(col_start, reach.col_start)
    col_end = min(col_end, reach.col_end)
    row_start = max(row_start, reach.row_start)
    row_end = min(row_end, reach.row_end)

    return {
        "row_start": row_start,
        "row_end": row_end,
        "col_start": col_start,
        "col_end": col_end
    }

# The screen rectangle in the SCREEN coordinates - the single source
# of truth both for the viewport culling and for the clipping of the rivers.
# The invariant: everything that we clip is already shifted by the offset (see
# _collect_river_segments), therefore the rectangle must be the screen one as well.
# `-offset_x / -offset_y` here would mean the WORLD coordinate system and
# would clip everything - exactly so the rivers once disappeared from the map.
func _get_screen_rect() -> Rect2:
    return Rect2(Vector2.ZERO, _get_viewport_size())

# Checks whether the rectangle (in the screen coordinates) intersects the viewport.
func _is_rect_visible(rect: Rect2) -> bool:
    return rect.intersects(_get_screen_rect())

func load_icons():
    icon_textures.clear()
    for res_id in GameData.raw_resources.keys():
        var res = GameData.raw_resources[res_id]
        if res.has("icon"):
            _cache_icon(res.icon)
    for imp_id in GameData.improvements.keys():
        var imp = GameData.improvements[imp_id]
        if imp.has("icon"):
            _cache_icon(imp.icon)
    for t_id in GameData.terrains.keys():
        var t = GameData.terrains[t_id]
        if t.has("icon"):
            _cache_icon(t.icon)
        if t.has("icons"):
            for icon_name in t.icons:
                _cache_icon(icon_name)
    for tech in GameData.technologies:
        if tech.has("icon"):
            _cache_icon(tech.icon)
    # The cover: we load its icons (the overlays of the forest and so on).
    for c_id in GameData.covers.keys():
        var c = GameData.covers[c_id]
        if c.has("icons"):
            for icon_name in c.icons:
                _cache_icon(icon_name)
    _cache_icon("city.png")
    # The key "city" is needed by the renderer of the towns (town_manager.TOWN_ICON_NAME),
    # in order to get the same texture by the "full" name of the file.
    if icon_textures.has("city.png"):
        icon_textures["city"] = icon_textures["city.png"]
    _cache_icon("lock.png")

# Puts the texture of the icon into the local cache of the drawing. The path is taken from
# IconRegistry, therefore the index of the icons in the project is one.
func _cache_icon(icon_name: String):
    if icon_name.is_empty():
        return
    var tex := IconRegistry.get_texture(icon_name)
    if tex != null:
        icon_textures[icon_name] = tex

func _draw():
    # We compute the visible range of the hexes (the viewport culling): we draw only those
    # hexes which intersect the rectangle of the screen.
    var visible = _get_visible_hex_range()

    # PHASE 1: We draw all the hexes which got on the screen within the reach
    # of the scroll. The hexes of the Region - in detail, the unexplored hexes beyond
    # its limits (the fog of war) are not drawn at all (see _draw_hex). The scouted
    # hexes outside the Region are drawn darkened: they can be selected and scouts
    # sent there - but only after the study of Cartography. Beyond the
    # limits of the reach of the scroll nothing is drawn at all (see
    # _get_visible_hex_range).
    for row in range(visible.row_start, visible.row_end + 1):
        for col in range(visible.col_start, visible.col_end + 1):
            _draw_hex(row, col)

    # NOTE: the hexes outside the Region (the fog of war) are drawn by the same pass
    # of PHASE 1 - they are darkened in _draw_hex, and their contents (the resources,
    # the improvements, the rings of the towns) are hidden. The separate passes for the unique
    # terrain and the towns beyond the limits of the Region are not needed any more: their
    # behaviour has been moved into _draw_hex and _draw_hex_overlays (the icon of a town
    # in the fog is semi-transparent and without a name, and only from the epoch >= 1).

    # PHASE 1.7: The influence rings of the towns - a semi-transparent blue fill.
    # It is drawn AFTER the terrain (phase 1), but BEFORE the roads, the rivers and the icons
    # (2/2.5/2.75/3) - so that the fill highlights the terrain and does not cover
    # the important details. By the agreement with the user the rings are visible ONLY
    # within the limits of the Region (see _get_region_visible_range): behind the fog of war they
    # are not drawn, so as not to "give away" the contents of the unexplored territory,
    # although the fog of war itself is now drawn and is available for the scouting.
    _draw_town_influence(visible)
    # PHASE 1.7.1: The borders of the rings of the towns - each with its own colour. They are drawn
    # right after the fill (over it, over the terrain), but before the roads/rivers/
    # icons: the outline must be visible, without covering the contents of the hexes.
    _draw_town_influence_borders(visible)

    # PHASE 2: We draw the roads (BEFORE the icons of the resources and the improvements) - the networks of the city
    # of the player and the networks of the towns (see _draw_all_roads)
    _draw_all_roads()

    # PHASE 2.75: We draw the rivers
    _draw_rivers()

    # PHASE 2.5: We draw the highlighting for the scouting and the purchase (it is always active,
    # but before the study of Cartography - only within the limits of the Region)
    _draw_exploration_highlights()

    # PHASE 3: We draw the icons of the resources, the improvements and the other overlays
    for row in range(visible.row_start, visible.row_end + 1):
        for col in range(visible.col_start, visible.col_end + 1):
            _draw_hex_overlays(row, col)

    # PHASE 3.5: We draw the highlighting of the selected hex (a click with the LMB, the control panel).
    # A frame + a light fill, so that the selected hex is well visible over
    # the overlays, but does not cover the icon of the resource/improvement.
    if main_map.control_panel and main_map.control_panel.has_selection():
        var sel = main_map.control_panel.get_selected_hex()
        if sel != null:
            # The fill + the frame. The set of the hexes is computed by
            # expansion_manager.get_highlight_hexes(): a hex in the Influence Ring -
            # only the hex itself; outside the Ring - the whole chunk of the scouting/purchase (the same
            # chunk with which the actions of the panel work, see
            # control_panel._collect_region_actions); if there is no chunk
            # (a scouted hex outside the Region or a hex in the influence ring of a foreign
            # town) - the hex itself, so that the click is not "silent". The chunk can
            # include the hexes in the Region and in the fog of war nearby.
            # The colours are by the type of the chunk (the scouting/the claiming × possible/impossible), see
            # _get_highlight_style; the style is computed once for the whole set.
            var selected_hexes: Array = main_map.expansion_manager.get_highlight_hexes(sel.row, sel.col)
            var style: Dictionary = _get_highlight_style(selected_hexes, sel.row, sel.col, true)
            for highlight_hex in selected_hexes:
                _draw_selected_hex_highlight(highlight_hex.row, highlight_hex.col, style)

    # PHASE 4: We draw the city at the end
    var offset_pos = Vector2(
        main_map.offset_x + main_map.scroll_offset.x,
        main_map.offset_y + main_map.scroll_offset.y
    )
    var city_center = HexUtils.hex_center(main_map.city_row, main_map.city_col, main_map.HEX_RADIUS) + offset_pos
    if icon_textures.has("city"):
        var tex = icon_textures["city"]
        var icon_rect = Rect2(
            city_center.x - CITY_ICON_SIZE / 2.0,
            city_center.y - CITY_ICON_SIZE / 2.0,
            CITY_ICON_SIZE,
            CITY_ICON_SIZE
        )
        draw_texture_rect(tex, icon_rect, false)
    else:
        var city_vertices = HexUtils.hex_vertices(
            city_center.x, city_center.y, main_map.HEX_RADIUS
        )
        draw_colored_polygon(city_vertices, Color.YELLOW)

    # We draw a rectangle with the name of the city a little above the hex of the city
    if not CityData.city_name.is_empty():
        var font = ThemeDB.fallback_font
        if font != null:
            var font_size := 14
            var text = CityData.city_name
            var text_size = font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
            var text_center = Vector2(city_center.x, city_center.y - main_map.HEX_RADIUS - 10)
            var padding = Vector2(8, 4)
            var text_ascent = font.get_ascent(font_size)
            var text_descent = font.get_descent(font_size)
            var background_height = text_ascent + text_descent + padding.y * 2.0
            var background_rect = Rect2(
                text_center.x - text_size.x / 2.0 - padding.x,
                text_center.y - background_height / 2.0,
                text_size.x + padding.x * 2.0,
                background_height
            )
            draw_rect(background_rect, Color(0.2, 0.2, 0.2, 1.0), true, -1.0, true)
            draw_rect(background_rect, Color(0.6, 0.6, 0.6, 1.0), false, 1.0, true)
            var text_baseline = background_rect.position.y + padding.y + text_ascent
            var text_pos = Vector2(text_center.x - text_size.x / 2.0, text_baseline)
            draw_string(
                font, text_pos, text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE
            )

func _draw_hex(row: int, col: int):
    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    var offset_x = main_map.offset_x + main_map.scroll_offset.x
    var offset_y = main_map.offset_y + main_map.scroll_offset.y
    center.x += offset_x
    center.y += offset_y
    var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)

    var closed_vertices = PackedVector2Array()
    closed_vertices.append_array(vertices)
    closed_vertices.append(vertices[0])

    var tile = tile_data[row][col]
    var in_influence = tile.get("in_influence", false)
    var is_explored = tile.get("is_explored", false)

    # A real fog of war: an unexplored hex beyond the limits of the Region
    # is not drawn at all - only the dark background of the canvas is visible. After the scouting
    # (`is_explored = true`) the hex is drawn as the ordinary one again: the fog
    # "opens up" and the scouting has a visual effect.
    if not in_influence and not is_explored and not main_map.is_valid_hex(row, col):
        return

    var terrain_color = Color.BLACK
    var terrain = tile.terrain
    var terrain_icon_name = tile.get("terrain_icon", "")

    if row == main_map.city_row and col == main_map.city_col:
        if GameData.terrains.has(terrain):
            var t = GameData.terrains[terrain]
            var c = t.get("color", [0, 0, 0])
            terrain_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
        draw_colored_polygon(vertices, terrain_color)
        draw_polyline(closed_vertices, Color.WHITE, 2, true)
        return

    if terrain_icon_name != "" and icon_textures.has(terrain_icon_name):
        var tex = icon_textures[terrain_icon_name]
        var icon_rect = Rect2(
            center.x - TERRAIN_ICON_SIZE / 2.0,
            center.y - TERRAIN_ICON_SIZE / 2.0,
            TERRAIN_ICON_SIZE,
            TERRAIN_ICON_SIZE
        )
        draw_texture_rect(tex, icon_rect, false)
    else:
        if GameData.terrains.has(terrain):
            var t = GameData.terrains[terrain]
            var c = t.get("color", [0, 0, 0])
            terrain_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
        draw_colored_polygon(vertices, terrain_color)

    # --- The cover: a semi-transparent overlay over the terrain ---
    _draw_cover_overlay(row, col, center, vertices)

    if not in_influence:
        draw_colored_polygon(vertices, Color(0, 0, 0, 0.5))

    if main_map.show_hex_borders:
        draw_polyline(closed_vertices, Color.WHITE, 2, true)

    # --- The render cache of the influence rings of the towns (PHASE 1.7 / 1.7.1) ---
    # Earlier the rings were recalculated and drawn EVERY frame: for each hex
    # of the fill - a separate draw_colored_polygon with the alpha blending and the trigonometry
    # (hex_center + hex_vertices), and for each edge of the borders - a new allocation
    # of the dictionary membership, plus 6x cos/sin and sort_custom(). With 2+ towns nearby
    # the rings were additionally DUPLICATED: the shared hexes in the flat list
    # town_influence_hexes were one per each town - the fill was applied
    # 2-3 times, which amplified the darkening of the intersections and increased the load.

    #
    # The rings are static between the spawn/load/a change of the epoch, therefore now:
    #   Step 1 - the cache of the unique fill centres (without duplicates) and the world segments
    #            of the borders is built once in _ensure_town_influence_cache();
    #   Step 2 - the fill is pre-rendered into ONE RGBA texture for the whole Region
    #            (see _build_town_fill_texture), and per frame one
    #            draw_texture_rect is drawn instead of hundreds of semi-transparent polygons.
    # Per frame there remain: 1 blit of the fill + light draw_line of the borders without the trigonometry
    # and the allocations. The rebuild is only by invalidate_town_influence_cache()
    # (the initialization of the map / the load of a save / a change of the epoch) or when the Region changes.
    #
    #
    # WHAT EXACTLY THE PLAYER SEES (the only place where the visibility of the rings is decided;
    # the rings themselves in the data are full - see town_manager.compute_all_town_influences):
    #   1. the epoch - in the 1st epoch (current_era < 1) the rings are not drawn at all, as are
    #      the towns themselves: otherwise a ring which intrudes into the Region would give away
    #      a foreign town from the very start of the game. The exception is the deliberate debug
    #      reveal of the whole map (main_map.debug_whole_map_revealed): nothing left to hide;
    #   2. the fog of war - a hex in the fog does not get the fill (is_hex_in_fog).
    #      The reverse is also true: a scouted hex beyond the limits of the Region DOES get the fill
    #      (this is how the scouting works).
    # The borders of the fill texture are computed by the actual fill, and not by the Region
    # (see _build_town_fill_texture), therefore a hex is never cut off by the edge of the
    # texture - a "half fill" is impossible in principle.
    

    # Public access to the fill cache for the tests and debugging: the list of the hexes
    # of the fill in the form [{"row": int, "col": int}, ...]. The hexes filtered out by
    # the fog of war are not in the list at all. An empty list means that the cache is not
    # built yet: call invalidate_town_influence_cache() first.
func get_town_fill_hexes() -> Array:
    var out: Array = []
    for h in _influence_fill_centers:
        out.append({"row": int(h.row), "col": int(h.col)})
    return out

# A public access to the cache of the borders for the tests and the debugging: the list of the hexes through
# which the outline segments pass, in the same format as
func get_town_border_hexes() -> Array:
    var out: Array = []
    for seg in _influence_border_segments:
        out.append({"row": int(seg.row), "col": int(seg.col)})
    return out

func invalidate_town_influence_cache() -> void:
    # We reset the render cache: it will be lazily rebuilt on the next frame.
    # The old ImageTexture is released automatically (ref-count) on
    # the overwrite of the reference in _build_town_fill_texture().
    _town_cache_version += 1
    # The records of the built offset are dropped as well: they are written by the builder, and
    # with them stale the rebuild would keep reusing a screen-sized cache of the old offset.
    _cache_built_offset = Vector2(INF, INF)

func _ensure_town_influence_cache(visible: Dictionary) -> void:
    if main_map == null:
        return
    # The Region expands on a change of the epoch - the cache for the old borders is invalid.
    var region_changed: bool = _cache_region_start_row != main_map.region_start_row \
            or _cache_region_end_row != main_map.region_end_row \
            or _cache_region_start_col != main_map.region_start_col \
            or _cache_region_end_col != main_map.region_end_col
    # The fill of the rings is drawn in the screen coordinates (see _draw_town_influence), so the
    # pre-rendered texture is tied to the offset it was built for. It is reused while the map is
    # scrolled within the cached margin, otherwise the segments of the borders would lag behind
    # the fill - therefore a drift past that bound rebuilds the cache too.
    var offset = Vector2(
        main_map.offset_x + main_map.scroll_offset.x,
        main_map.offset_y + main_map.scroll_offset.y
    )
    var offset_drifted := true
    if not is_inf(_cache_built_offset.x):
        offset_drifted = maxf(absf(offset.x - _cache_built_offset.x),
                absf(offset.y - _cache_built_offset.y)) > main_map.MAP_CACHE_MARGIN
    if _town_cache_built_version == _town_cache_version and not region_changed and not offset_drifted:
        return
    _town_cache_built_version = _town_cache_version
    _cache_region_start_row = main_map.region_start_row
    _cache_region_end_row = main_map.region_end_row
    _cache_region_start_col = main_map.region_start_col
    _cache_region_end_col = main_map.region_end_col
    # The reference offset is remembered AFTER the expensive build below, because the build
    # itself goes through _draw_rivers -> _build_river_frame_cache, which needs a valid
    # _cache_built_offset to decide whether the river geometry can be reused. Writing it here
    # would make _flush_scroll_cache_invalidation see "no drift" and skip the invalidation of
    # the rivers, so their cache would never be dropped after a long pan.

    # --- Step 1: the unique hexes of the fill + the world segments of the borders ---
    _influence_fill_centers = []
    _influence_border_segments = []
    # The rings in the data are full (town_manager no longer clips them by the Region),
    # therefore IT IS DECIDED HERE what of them the player sees: in the 1st epoch (current_era
    # < 1) a foreign town is not shown at all - exactly as its icon (see _draw_hex_overlays),
    # therefore we do not draw the ring either - unless the whole map was revealed on purpose
    # by the debug action (main_map.debug_whole_map_revealed), where there is nothing left to
    # hide. Otherwise a ring which intrudes into the Region would "give away" the town from
    # the very start of the game.
    if main_map.current_era < 1 and not main_map.debug_whole_map_revealed:
        _build_town_fill_texture()
        return
    var seen: Dictionary = {}
    var radius: float = main_map.HEX_RADIUS
    var towns: Array = main_map.towns
    if towns == null:
        towns = []
    # The directions of the neighbours for the odd-r offset grid (like HexUtils.get_neighbors_odd_r).
    var even_dirs := [[0, -1], [0, 1], [-1, -1], [-1, 0], [1, -1], [1, 0]]
    var odd_dirs := [[0, -1], [0, 1], [-1, 0], [-1, 1], [1, 0], [1, 1]]
    for town_entry in towns:
        var ring: Array = town_entry.get("influence_hexes", [])
        if ring.is_empty():
            continue
        var bc: Array = town_entry.get("border_color", [1.0, 1.0, 1.0, 1.0])
    # The map of the membership "row,col" -> true for a quick check of "not in a ring".
        var members: Dictionary = {}
        for h in ring:
            members["%d,%d" % [int(h.row), int(h.col)]] = true
        for h in ring:
            var row: int = int(h.row)
            var col: int = int(h.col)
    # A hex under the fog of war (unknown to the player) does not get the fill:
    # otherwise the ring would "give away" the presence of a foreign town. The check goes
    # exactly by the fog, and not by the Region: a scouted hex BEYOND the limits of
    # the Region does get the fill (this is how the scouting works - see the commit
    # "the fill is not drawn on the hexes in the fog of war"). There is nothing to clip such
    # hexes with: the borders of the texture are computed by the fill itself
    # (_build_town_fill_texture), therefore each of its hexes fits into
    # the texture entirely.
            if main_map.is_hex_in_fog(row, col):
                continue
    # The fill: we draw a hex only once, even if it is in the rings of several
    # towns (earlier - N times with a "double" darkening of the intersections).
            var key := "%d,%d" % [row, col]
            if not seen.has(key):
                seen[key] = true
                var c: Vector2 = HexUtils.hex_center(row, col, radius)
                _influence_fill_centers.append({"cx": c.x, "cy": c.y,
                        "row": row, "col": col,
                    "cr": bc[0], "cg": bc[1], "cb": bc[2],
                    "ca": TOWN_INFLUENCE_FILL_ALPHA})
    # The border: the edges between the ring of a town and its surroundings.
            var dirs: Array = even_dirs if row % 2 == 0 else odd_dirs
            for d in dirs:
                var nr := row + int(d[0])
                var nc := col + int(d[1])
                if members.has("%d,%d" % [nr, nc]):
                    continue
    # There is no neighbour at the edge of the map - we do not draw the "correct" edge.
                if nr < 0 or nr >= main_map.map_rows or nc < 0 or nc >= main_map.map_cols:
                    continue
    # The edge goes into the fog of war - the outline is not drawn there.
                if main_map.is_hex_in_fog(nr, nc):
                    continue
    # The common rim: the two vertices of the current hex which are the closest to the centre
    # of the neighbour. For the pointy-top hexes this is the common edge.
                var nb_center: Vector2 = HexUtils.hex_center(nr, nc, radius)
                var dists: Array = []
                for vi in range(6):
                    var v: Vector2 = HexUtils.hex_vertex(row, col, vi, radius)
                    dists.append({"idx": vi, "d": v.distance_squared_to(nb_center)})
                dists.sort_custom(func(a, b): return a.d < b.d)
                var p1: Vector2 = HexUtils.hex_vertex(row, col, int(dists[0].idx), radius)
                var p2: Vector2 = HexUtils.hex_vertex(row, col, int(dists[1].idx), radius)
                _influence_border_segments.append({"p1x": p1.x, "p1y": p1.y,
                        "p2x": p2.x, "p2y": p2.y,
                        "cr": bc[0], "cg": bc[1], "cb": bc[2], "ca": bc[3],
                        "row": row, "col": col})

    # --- Step 2: a pre-render of the fill into one texture of the Region ---
    _build_town_fill_texture()

    # A pre-render of the fill of the influence rings into ONE RGBA texture, which covers the whole
    # area of the fill. The texture is built in the "world" pixels
    # (without the scroll offset): when scrolling, a frame only adds the offset and does one
    # draw_texture_rect. The Godot class Image has no vector primitives (only
    # fill/fill_rect/set_pixel), therefore the hexes are filled row by row through
    # fill_rect by the table of the half widths (a pointy-top hex with the flat sides
    # the left and right borders are vertical).
    #
    # If the area of the fill is too large for one texture (the limit of 4096 px) -
    # we leave _influence_fill_texture = null, and _draw_town_influence draws
    # the fill by the cached polygons (without the duplicates and the trigonometry per frame).
    
func _build_town_fill_texture() -> void:
    _influence_fill_texture = null
    if main_map == null or Engine.is_editor_hint():
        return
    if _influence_fill_centers.is_empty():
        return
    var radius: float = main_map.HEX_RADIUS
    # We compute the borders of the texture BY THE ACTUAL FILL, and not by the corners
    # of the Region.
    # of the Region. On the odd-r grid the odd rows are shifted by a half hex
    # (HexUtils.hex_center), therefore the corners of the Region are not the extreme points of the map:
    # the hexes of the edge columns in the even rows stick out beyond them by ~0.73 of the radius, and
    # the texture was cutting them off with its edge - the fill looked "drawn by half"
    # (more noticeably on the left: there the minimum is taken from a corner with an odd row). Hence
    # also a margin of 1 px beyond the dimensions of a hex - for the smoothing of the joints.
    var half_w: float = radius * sqrt(3.0) * 0.5 # the half width of the hex by X
    var min_x := INF
    var min_y := INF
    var max_x := -INF
    var max_y := -INF
    for h in _influence_fill_centers:
        var cx: float = float(h.cx)
        var cy: float = float(h.cy)
        min_x = minf(min_x, cx - half_w)
        max_x = maxf(max_x, cx + half_w)
        min_y = minf(min_y, cy - radius)
        max_y = maxf(max_y, cy + radius)
    min_x -= 1.0
    min_y -= 1.0
    max_x += 1.0
    max_y += 1.0
    var tex_w: int = int(ceil(max_x - min_x))
    var tex_h: int = int(ceil(max_y - min_y))
    if tex_w <= 0 or tex_h <= 0 or tex_w > 4096 or tex_h > 4096:
        return
    var img: Image = Image.create_empty(tex_w, tex_h, false, Image.FORMAT_RGBA8)
    if img == null:
        return
    img.fill(Color(0, 0, 0, 0))
    var half: float = radius * 0.5
    var rmax: int = int(ceil(radius)) + 1
    # The half widths (px) of a pointy-top hex by the offsets dy. +1px on each
    # side outward - it covers the thin AA seams at the joints of the hexes.
    var hw: Dictionary = {}
    for dy in range(-rmax, rmax + 1):
        var ya: float = float(dy)
        var w: float = radius * sqrt(3.0) * 0.5 # the flat width (|y| <= r/2)
        if ya > half:
            w = sqrt(3.0) * (radius - ya)
        elif ya < -half:
            w = sqrt(3.0) * (ya + radius)
        hw[dy] = w + 1.0
    for h in _influence_fill_centers:
        var cx: float = float(h.cx) - min_x
        var cy: float = float(h.cy) - min_y
        var fill_color := Color(h.cr, h.cg, h.cb, h.ca)
        var base_x: int = int(floor(cx))
        var base_y: int = int(floor(cy))
        for dy in range(-rmax, rmax + 1):
            var y: int = base_y + dy
            if y < 0 or y >= tex_h:
                continue
            var w: float = float(hw[dy])
            var x0: int = base_x - int(ceil(w))
            var x1: int = base_x + int(ceil(w))
            if x1 <= x0:
                continue
            img.fill_rect(Rect2i(x0, y, x1 - x0, 1), fill_color)
    _influence_fill_texture = ImageTexture.create_from_image(img)
    _influence_texture_origin = Vector2(min_x, min_y)
    _influence_texture_size = Vector2(float(tex_w), float(tex_h))

# Narrows the visible range of the hexes to the borders of the Region (the Ring + the Region).
# It is needed for the influence rings of the towns: the fog of war is now drawn and
# available for the scouting, but a foreign territory is not revealed in it -
# the fill and the borders of the rings are drawn only inside the Region.
func _get_region_visible_range(visible: Dictionary) -> Dictionary:
    return {
        "row_start": max(visible.row_start, main_map.region_start_row),
        "row_end": min(visible.row_end, main_map.region_end_row),
        "col_start": max(visible.col_start, main_map.region_start_col),
        "col_end": min(visible.col_end, main_map.region_end_col)
    }

# Draws the influence rings of all the towns (PHASE 1.7). By the agreement - only
# for the hexes inside the REGION (see _get_region_visible_range): behind the fog of war
# the rings are not drawn, so as not to "give away" the unexplored territory, although
# the fog itself is now drawn and is available for the scouting.
# One frame = one draw_texture_rect (the texture is cut by Ring+Region).
# The fallback to the polygons - only in the editor or with too large a Region.
func _draw_town_influence(visible: Dictionary) -> void:
    if main_map == null:
        return
    var radius: float = main_map.HEX_RADIUS
    var offset_x: float = main_map.offset_x + main_map.scroll_offset.x
    var offset_y: float = main_map.offset_y + main_map.scroll_offset.y
    _ensure_town_influence_cache(visible)
    if _influence_fill_texture != null:
        draw_texture_rect(_influence_fill_texture, Rect2(
                _influence_texture_origin.x + offset_x,
                _influence_texture_origin.y + offset_y,
                _influence_texture_size.x,
                _influence_texture_size.y), false, Color(1, 1, 1, 1))
        _cache_built_offset = Vector2(offset_x, offset_y)
        return
    # Fallback: the drawing by the hexes (the editor / the Region larger than 4096px).
    var region_visible = _get_region_visible_range(visible)
    for h in _influence_fill_centers:
        var row: int = int(h.row)
        var col: int = int(h.col)
        # The visibility (as before): only the Ring + the Region.
        if row < region_visible.row_start or row > region_visible.row_end \
                or col < region_visible.col_start or col > region_visible.col_end:
            continue
        var cx: float = float(h.cx) + offset_x
        var cy: float = float(h.cy) + offset_y
        if not _is_rect_visible(Rect2(cx - radius, cy - radius, radius * 2, radius * 2)):
            continue
        var vertices = HexUtils.hex_vertices(cx, cy, radius)
        var fill_color := Color(h.cr, h.cg, h.cb, h.ca)
        draw_colored_polygon(vertices, fill_color)
    _cache_built_offset = Vector2(offset_x, offset_y)

    # Draws the borders of the influence rings of EACH town with its own colour (PHASE 1.7.1).
    # It is drawn right after the fill of the rings (PHASE 1.7) and before the roads/rivers/icons.
    # The data are taken from main_map.towns (an array of the records of the towns): each
    # town has its own personal ring (town["influence_hexes"]) and its own colour of the borders
    # (town["border_color"], generated on the spawn and saved in the save). The rings
    # are completely independent - the colours of the neighbouring towns do not affect each other,
    # therefore a "foreign" territory is visually clearly delimited.
    #
    # The outline is drawn by the common edges between the hexes of the ring and the "surroundings"
    # (a hex which does NOT belong to the ring of this town). The internal edges (between two
    # hexes of one ring) are not drawn. Beyond the edge of the map the edges are not drawn -
    # there is no hex-neighbour there, and the ring simply ends.
    # The segments are computed ONCE in _ensure_town_influence_cache() and are stored in the
    # world coordinates (without the offset). Per frame - only the translation by the offset,
    # the viewport check and the draw_line: without the trigonometry and the allocations of the dictionaries.
    #
    # The visibility — the same as that of the fill: only the Ring + the Region. The clipping of the rings on
    # the starting Region is already applied to the data (in town_manager), so the foreign
    # towns in the 1st epoch do not reveal their outlines.
func _draw_town_influence_borders(visible: Dictionary) -> void:
    if main_map == null:
        return
    _ensure_town_influence_cache(visible)
    var region_visible = _get_region_visible_range(visible)
    var offset_x: float = main_map.offset_x + main_map.scroll_offset.x
    var offset_y: float = main_map.offset_y + main_map.scroll_offset.y
    for seg in _influence_border_segments:
        var row: int = int(seg.row)
        var col: int = int(seg.col)
        # The visibility (as in the fill): only the Ring + the Region.
        if row < region_visible.row_start or row > region_visible.row_end \
                or col < region_visible.col_start or col > region_visible.col_end:
            continue
        var p1 := Vector2(float(seg.p1x) + offset_x, float(seg.p1y) + offset_y)
        var p2 := Vector2(float(seg.p2x) + offset_x, float(seg.p2y) + offset_y)
        # The viewport culling of a segment by its bounding box.
        if not _is_rect_visible(Rect2(
                minf(p1.x, p2.x) - TOWN_INFLUENCE_BORDER_WIDTH,
                minf(p1.y, p2.y) - TOWN_INFLUENCE_BORDER_WIDTH,
                abs(p1.x - p2.x) + TOWN_INFLUENCE_BORDER_WIDTH * 2.0,
                abs(p1.y - p2.y) + TOWN_INFLUENCE_BORDER_WIDTH * 2.0)):
            continue
        var color := Color(seg.cr, seg.cg, seg.cb, seg.ca)
        draw_line(p1, p2, color, TOWN_INFLUENCE_BORDER_WIDTH, true)

    # Draws the overlay of the cover over the relief.
    # If the cover has an icon - we draw it (a deterministic choice by the seed),
    # otherwise - a semi-transparent coloured polygon (color + alpha).
func _draw_cover_overlay(row: int, col: int, center: Vector2, vertices: PackedVector2Array):
    var tile = tile_data[row][col]
    var cover_id = tile.get("cover", "none")
    if cover_id == "" or cover_id == "none":
        return
    var cover: Dictionary = GameData.covers.get(cover_id, {})
    if cover.is_empty():
        return

    # The icon of the cover (if there is one) - a deterministic choice, so that it does not flicker.
    var icon_name = _pick_cover_icon(cover, row, col)
    if icon_name != "" and icon_textures.has(icon_name):
        var tex = icon_textures[icon_name]
        var icon_rect = Rect2(
            center.x - TERRAIN_ICON_SIZE / 2.0,
            center.y - TERRAIN_ICON_SIZE / 2.0,
            TERRAIN_ICON_SIZE,
            TERRAIN_ICON_SIZE
        )
    # The icon of the forest is usually opaque - we apply the alpha for the semi-transparency.
        var alpha = float(cover.get("alpha", 0.45))
        draw_texture_rect(tex, icon_rect, false, Color(1, 1, 1, alpha))
    else:
    # The fallback: a semi-transparent coloured polygon.
        var c = cover.get("color", [0, 0, 0])
        var alpha = float(cover.get("alpha", 0.45))
        draw_colored_polygon(vertices, Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0, alpha))

    # Returns the name of the icon of the cover for the hex (row, col) - a deterministic choice.
func _pick_cover_icon(cover: Dictionary, row: int, col: int) -> String:
    var icons: Array = cover.get("icons", [])
    if icons.is_empty():
        return ""
    var icon_rng = RandomNumberGenerator.new()
    icon_rng.seed = row * 1000 + col
    var idx = icon_rng.randi() % icons.size()
    return icons[idx]

    # The resource is visible to the player if BOTH conditions are met:
    #   1) the hex belongs to the Influence Ring (the territory is claimed) or the area
    #      has been scouted;
    #   2) the resource has NO tech_reveal, or the corresponding technology is already learned.
    # Otherwise the resource is hidden: there is no icon, it is not mentioned in the tooltip, the scouts
    # do not "see" it. This concerns the underground minerals like iron
    # (tech_reveal = "mining") - while mining is not learned, the ore is on the map,
    # but the player does not know about it.
    # The logic is moved out into MapHelpers, so that the tooltip and the renderer do not diverge.
func _is_resource_revealed(tile: Dictionary) -> bool:
    return MapHelpers.is_resource_revealed(tile)

func _draw_hex_overlays(row: int, col: int):
    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    center.x += main_map.offset_x + main_map.scroll_offset.x
    center.y += main_map.offset_y + main_map.scroll_offset.y

    var tile = tile_data[row][col]
    var in_influence = tile.get("in_influence", false)
    var is_explored = tile.get("is_explored", false)

    if row == main_map.city_row and col == main_map.city_col:
        return

    # A real fog of war: an unexplored hex beyond the Region - no
    # overlays (the resources, the icons of the improvements, the towns, the conflicts of tech_reveal).
    # `_draw_hex` has already refused to draw it; here we also return, so as not to
    # accidentally "give away" the contents.
    if not in_influence and not is_explored and not main_map.is_valid_hex(row, col):
        return

    # The resources of the Region outside the Influence Ring are hidden until the area is scouted.
    # (The progress bars below are drawn regardless of the visibility of the resource.)
    var is_resource_visible = _is_resource_revealed(tile)

    # We draw the icon both for the natural (tile.resource) and for the bred
    # (tile.crop_bred) resource - the effective resource is taken from MapHelpers.
    var eff_res = MapHelpers.get_effective_resource(tile)
    # We check whether the resource is locked by a technology for the improvement.
    # The resources with tech_reveal are hidden completely (is_resource_visible = false).
    # A castle is gated by the technology of the IMPROVEMENT by which the resource is extracted
    # (imp_unlock_tech from improved_by), and NOT by the technology of the appearance of the resource
    # (tech_required). For example, the quartz sand is extracted by a quarry:
    # the castle is held until "Stone Masonry", although the resource is visible earlier. For
    # the stone resources (basalt/marble/...) this same lock is held until
    # "Stone Masonry", and does not disappear after "Mining".
    var is_resource_locked_by_tech = false
    if eff_res != "" and is_resource_visible:
        var res_data = GameData.raw_resources.get(eff_res, {})
        var improved_by = res_data.get("improved_by", "")
    # For a part of the resources (for example, the wild plants foraged_food) improved_by is set
    # as null - then .get() returns Nil, and not the default value.
        if improved_by == null:
            improved_by = ""
        if improved_by != "" and not CityData.is_improvement_unlocked(improved_by):
            is_resource_locked_by_tech = true

    if eff_res != "" and is_resource_visible:
        var res_data = GameData.raw_resources.get(eff_res, {})
        var res_icon = res_data.get("icon", "")
        if res_icon != "" and icon_textures.has(res_icon):
            var tex = icon_textures[res_icon]
            var icon_rect = Rect2(center.x - RESOURCE_ICON_SIZE / 2.0, center.y - RESOURCE_ICON_SIZE / 2.0, RESOURCE_ICON_SIZE, RESOURCE_ICON_SIZE)
            draw_texture_rect(tex, icon_rect, false)
        else:
            if res_data.has("color"):
                var c = res_data["color"]
                var fallback_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
                draw_circle(center, RESOURCE_ICON_SIZE / 3.0, fallback_color)

    # If the resource is visible, but the technology for the construction of the improvement is not learned -
    # we draw the icon of the castle over the resource. As soon as the technology is learned,
    # the castle disappears (is_resource_locked_by_tech becomes false).
    if is_resource_locked_by_tech and icon_textures.has("lock.png"):
        var lock_tex = icon_textures["lock.png"]
        var lock_size = RESOURCE_ICON_SIZE * 0.6
        var lock_rect = Rect2(
            center.x - lock_size / 2.0,
            center.y - lock_size / 2.0,
            lock_size,
            lock_size
        )
        draw_texture_rect(lock_tex, lock_rect, false)

    # The asterisks of the quality of the resource - under the icon, only if the resource is revealed
    # and an improvement which reveals the quality is already built on this hex.
    if eff_res != "" and is_resource_visible and tile.improvement != null:
        _draw_quality_stars(tile, center)

    if in_influence and tile.improvement != null:
        var has_worker = main_map.worker_manager.has_worker(row, col)
        var imp_data = GameData.improvements.get(tile.improvement, {})
        var imp_icon = imp_data.get("icon", "")
        # The infrastructure improvements (no_worker, for example a pier or a canal)
        # are not tied to a worker: we always draw them in the full colour, without the grey
        # darkening, even when has_worker == false.
        var is_infra = GameData.is_no_worker_improvement(tile.improvement)
        # The decorative improvements of the towns are always drawn in the full colour,
        # although they intentionally have no worker.
        var draw_active = has_worker or is_infra or bool(tile.get("decorative", false))
        # If there is no resource on the hex (neither natural nor bred) - the improvement
        # is the only "item" on the hex (an irrigation canal, a forest
        # plot on an empty forest hex, the decorative improvements of the towns on
        # empty hexes). We draw it in the centre of the hex LARGE - of the size of
        # the icon of the resource (RESOURCE_ICON_SIZE): in fact it replaces
        # the missing icon of the resource itself. If there is a resource - the icon of the improvement
        # remains a small marker (IMPROVEMENT_ICON_SIZE) above the top
        # edge, above the icon of the resource.
        var imp_icon_size: float = IMPROVEMENT_ICON_SIZE
        # The radius of the stub circle, if the texture of the icon is not found. For the large
        # icon we take the same formula as for the resource (RESOURCE_ICON_SIZE/3),
        # so that it looks like an ordinary stub icon of the resource.
        var imp_fallback_radius: float = IMPROVEMENT_ICON_SIZE / 2.5
        var icon_pos = Vector2(center.x, center.y)
        if eff_res != "":
            icon_pos = Vector2(center.x, center.y - main_map.HEX_RADIUS * 0.75)
        else:
            imp_icon_size = RESOURCE_ICON_SIZE
            imp_fallback_radius = RESOURCE_ICON_SIZE / 3.0
        if imp_icon != "" and icon_textures.has(imp_icon):
            var tex = icon_textures[imp_icon]
            var icon_rect = Rect2(icon_pos.x - imp_icon_size / 2.0, icon_pos.y - imp_icon_size / 2.0, imp_icon_size, imp_icon_size)
            if not draw_active:
                draw_texture_rect(tex, icon_rect, false, Color(0.5, 0.5, 0.5))
            else:
                draw_texture_rect(tex, icon_rect, false)
        else:
            if imp_data.has("color"):
                var c = imp_data["color"]
                var fallback_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
                if not draw_active:
                    fallback_color = Color(0.5, 0.5, 0.5)
                draw_circle(icon_pos, imp_fallback_radius, fallback_color)

        # A drop of fresh water next to the icon of the improvement. We show it for
        # any improvement which has access to the water (direct or chain).
        # The types differ visually:
        #   direct - a filled blue drop (as it was before for the farms);
        #   chain  - a contour (an outline) of a muted colour, the water by the chain.
        if tile.improvement != null:
            var water_access = MapHelpers.get_hex_water_access(row, col, tile_data, main_map.map_rows, main_map.map_cols)
            if water_access != "":
                # The position of the drop depends on the size of the icon of the improvement:
                #   small (32) - as before, to the right of the icon;
                #   large (RESOURCE_ICON_SIZE, a hex without a resource) - to the right
                #   the drop rests against the face of the hex (the half width of the hex is ~47.6px
                #   at HEX_RADIUS = 55), and below it the progress bars interfere, therefore
                #   we place it in the centre ABOVE the icon, in the upper part of the hex.
                var drop_offset := Vector2(imp_icon_size * 0.5 + 6, 0)
                if imp_icon_size > IMPROVEMENT_ICON_SIZE:
                    drop_offset = Vector2(0, - (imp_icon_size * 0.5 + 6))
                var drop_center = icon_pos + drop_offset
                var drop_radius = MARKER_ICON_RADIUS
                var drop_points = [
                    Vector2(0, -drop_radius),
                    Vector2(-drop_radius * 0.7, -drop_radius * 0.2),
                    Vector2(-drop_radius * 0.35, drop_radius * 0.8),
                    Vector2(0, drop_radius),
                    Vector2(drop_radius * 0.35, drop_radius * 0.8),
                    Vector2(drop_radius * 0.7, -drop_radius * 0.2)
                ]
                for i in range(drop_points.size()):
                    drop_points[i] += drop_center
                if water_access == "direct":
                    draw_polygon(drop_points, [MARKER_ICON_COLOR])
                else:
                    # chain: a contour drop of a muted colour.
                    var closed_points = PackedVector2Array()
                    closed_points.append_array(drop_points)
                    closed_points.append(drop_points[0])
                    draw_polyline(closed_points, Color(0.5, 0.7, 0.95, 0.9), 1.5)

    # --- The icon of the town ---
    # It is drawn AFTER all the other overlays (the resource/the improvement/the drop of water),
    # in order to be over them - it is the "main" object on the hex, as is the city
    # of the player itself. The size is taken from town_manager, so that if desired it could easily be
    # to tweak. We draw only if the hex is NOT the hex of a city (a city is a separate
    # case in PHASE 4).
    if tile.get("has_town", false) \
            and not (row == main_map.city_row and col == main_map.city_col) \
            and icon_textures.has(TownManager.TOWN_ICON_NAME):
        # Is the hex revealed: in the Influence Ring or scouted by the scouts.
        var town_revealed: bool = in_influence or bool(tile.get("is_explored", false))
        # A revealed town - a full icon + a name. An unscouted one (the fog of war)
        # is visible only by a hint: a semi-transparent icon without a name, and before the epoch
        # of the Antiquity (current_era < 1) it is not shown at all - as before
        # in a separate pass for the towns beyond the limits of the Region.
        if town_revealed or main_map.current_era >= 1:
            var town_tex = icon_textures[TownManager.TOWN_ICON_NAME]
            var town_rect = Rect2(
                center.x - TownManager.TOWN_ICON_SIZE / 2.0,
                center.y - TownManager.TOWN_ICON_SIZE / 2.0,
                TownManager.TOWN_ICON_SIZE,
                TownManager.TOWN_ICON_SIZE
            )
            if town_revealed:
                draw_texture_rect(town_tex, town_rect, false)
                _draw_town_name(row, col, center)
                # The trade badge over a town which is connected to the city.
                # It is drawn only for a revealed town (the same gate as
                # the icon itself): in the fog of war it would give away that which the player
                # has not reached yet.
                if _is_town_trade_connected(row, col):
                    # Over the icon of the town, but inside the hex: the label of the name
                    # of the town is moved out above the top face of the hex, and the badge
                    # would run into it.
                    _draw_trade_link_icon(
                        center + Vector2(0, -(TownManager.TOWN_ICON_SIZE * 0.5 + 8.0)))
            else:
                draw_texture_rect(town_tex, town_rect, false,
                        Color(1, 1, 1, TownManager.FOG_TOWN_ICON_ALPHA))

    # --- The conflict "a tech_reveal resource vs. a foreign improvement" ---
    # If an improvement stands on the hex, and under it a hidden resource was found (tech_reveal
    # is already learned, but the resource is not extracted because of the old improvement) - we draw
    # a red triangle with a "!". The improvement itself is not demolished: its production
    # continues. The details are in docs.md, "tech_reveal: the hidden resources".
    # We show the triangle ONLY when the resource is already visible (after tech_reveal),
    # otherwise the player does not understand what the badge is complaining about.
    var conflict = MapHelpers.get_tech_reveal_conflict(tile)
    if not conflict.is_empty() and is_resource_visible:
        _draw_tech_reveal_warning(center)

# Is the city connected to this town by roads. The single source of truth is
# road_manager: the networks of the city and the town have intersected (see is_town_linked_to_city).
func _is_town_trade_connected(row: int, col: int) -> bool:
    if main_map == null or not main_map.has_node("RoadManager"):
        return false
    var road_manager = main_map.get_node("RoadManager")
    return road_manager.is_town_linked_to_city(row, col)

# The trade badge over the hex of a connected town: two curved arrows,
# directed towards each other. The size is exactly the same as that of a drop of fresh water
# (MARKER_ICON_RADIUS, the same constant), it is drawn procedurally, as is the drop:
# a separate icon of such a size would be unreadable.
# It is placed over the icon of the town, inside the upper part of the hex: the label of the name
# of the town is moved out above the top face of the hex, and the badge would run into it.
func _draw_trade_link_icon(center: Vector2) -> void:
    var r := MARKER_ICON_RADIUS
    var arc_radius := r * 0.65
    var arc_offset := r * 0.35
    var line_width := maxf(1.0, r * 0.22)
    var color := MARKER_ICON_COLOR
    # The upper arc: from left to right, the arrowhead looks down.
    var top_center := center + Vector2(0, -arc_offset)
    draw_arc(top_center, arc_radius, PI, TAU, 12, color, line_width, true)
    _draw_arrow_head(top_center + Vector2(arc_radius, 0), Vector2(0, 1), color, r)
    # The lower arc is mirrored: from right to left, the arrowhead looks up.
    var bottom_center := center + Vector2(0, arc_offset)
    draw_arc(bottom_center, arc_radius, 0, PI, 12, color, line_width, true)
    _draw_arrow_head(bottom_center + Vector2(-arc_radius, 0), Vector2(0, -1), color, r)

# The arrowhead of the arrow of the trade badge: a small triangle from the point tip
# in the direction dir.
func _draw_arrow_head(tip: Vector2, dir: Vector2, color: Color, size: float) -> void:
    var d := dir.normalized()
    var side := Vector2(-d.y, d.x)
    var points := PackedVector2Array([
        tip,
        tip - d * size * 0.75 + side * size * 0.42,
        tip - d * size * 0.75 - side * size * 0.42,
    ])
    draw_colored_polygon(points, color)

func _draw_town_name(row: int, col: int, center: Vector2) -> void:
    var town_name := ""
    for town in main_map.towns:
        if int(town.get("row", -1)) == row and int(town.get("col", -1)) == col:
            town_name = str(town.get("name", ""))
            break
    if town_name.is_empty():
        return

    var font = ThemeDB.fallback_font
    if font == null:
        return
    var font_size := 12
    var text_size = font.get_string_size(town_name, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
    var text_center = Vector2(center.x, center.y - main_map.HEX_RADIUS - 8)
    var padding = Vector2(6, 3)
    var text_ascent = font.get_ascent(font_size)
    var text_descent = font.get_descent(font_size)
    var background_height = text_ascent + text_descent + padding.y * 2.0
    var background_rect = Rect2(
        text_center.x - text_size.x / 2.0 - padding.x,
        text_center.y - background_height / 2.0,
        text_size.x + padding.x * 2.0,
        background_height
    )
    draw_rect(background_rect, Color(0.2, 0.2, 0.2, 1.0), true, -1.0, true)
    draw_rect(background_rect, Color(0.6, 0.6, 0.6, 1.0), false, 1.0, true)
    var text_baseline = background_rect.position.y + padding.y + text_ascent
    var text_pos = Vector2(text_center.x - text_size.x / 2.0, text_baseline)
    draw_string(font, text_pos, town_name, HORIZONTAL_ALIGNMENT_CENTER,
            -1, font_size, Color.WHITE)

# Draws the asterisks of the quality of the resource under its icon.
# Only for the revealed resources after the construction of an improvement. If the quality is not set
# or is equal to "common" - we draw nothing.
func _draw_quality_stars(tile: Dictionary, center: Vector2):
    var quality = tile.get("quality", "")
    if quality == "" or quality == null or quality == "common":
        return
    var levels = GameData.get_quality_levels()
    if levels.is_empty():
        return
    # We determine the index of the quality in the list of the levels (from the worst to the best).
    var quality_index = levels.find(quality)
    if quality_index < 0:
        return
    # The number of the "full" asterisks = the index + 1 (the first level = 1 asterisk).
    var stars_count = quality_index + 1
    # The maximum of the asterisks = the number of the levels of the quality.
    var max_stars = levels.size()

    var star_outer = 5.5
    var star_inner = 2.5
    var spacing = 11.0
    var start_x = center.x - (stars_count * spacing - spacing) / 2.0
    var star_y = center.y + RESOURCE_ICON_SIZE / 2.0 + 4

    for i in range(max_stars):
        var star_cx = start_x + i * spacing
        if i < stars_count:
            # A filled asterisk is a golden yellow
            _draw_star(star_cx, star_y, star_outer, star_inner, Color(1.0, 0.85, 0.2, 0.9))
        else:
            # An empty asterisk is a grey-white
            _draw_star_outline(star_cx, star_y, star_outer, star_inner, Color(0.5, 0.5, 0.5, 0.6))

# Draws a red triangle with a "!" in the upper right corner of the hex - an indicator
# of the conflict "a tech_reveal resource is found under a foreign improvement". The position
# is specially chosen so as not to cover the icon of the resource in the centre
# and the icon of the improvement at the top, but to fall into the field of view.
# The figure itself - a filled red triangle + a white outline + a "!"
# in the middle (through draw_string). Without the external resources and the fonts.
func _draw_tech_reveal_warning(center: Vector2):
    # The dimensions of the triangle in the pixels.
    var tri_size := 18.0
    # The centre of the triangle is in the upper right corner of the hex, a bit closer to the centre,
    # so that the badge does not stick out of the hex and is not lost on the background of the neighbours.
    var cx = center.x + main_map.HEX_RADIUS * 0.55
    var cy = center.y - main_map.HEX_RADIUS * 0.55
    # The vertices of an equilateral triangle directed up.
    var pts = PackedVector2Array()
    pts.append(Vector2(cx, cy - tri_size * 0.6))
    pts.append(Vector2(cx - tri_size * 0.55, cy + tri_size * 0.45))
    pts.append(Vector2(cx + tri_size * 0.55, cy + tri_size * 0.45))
    draw_colored_polygon(pts, Color(0.85, 0.15, 0.15, 0.95))
    # A white outline by the same contour.
    var border = PackedVector2Array()
    border.append_array(pts)
    border.append(pts[0])
    draw_polyline(border, Color.WHITE, 1.5, true)
    # The "!" - we draw it as a short column and a dot under it. We use
    # the standard font through draw_string, so as not to depend on the assets.
    var font = ThemeDB.fallback_font
    if font == null:
        return
    var font_size := 13
    var text := "!"
    var text_size = font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
    var text_pos = Vector2(cx - text_size.x / 2.0, cy + text_size.y / 2.0 - 1)
    draw_string(font, text_pos, text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE)

# Returns the style of the highlighting of the chunk - {"fill": Color, "border": Color,
# "width": float} - by the four types of the chunks. Two axes of the encoding:
#   - the tone encodes the type of the action (two mutually different tones - the scouting or
#     the claiming); a muted (desaturated) tone means that the action
#     is unavailable: the chunk does not adjoin the known territory or the purchase
#     is impossible (outside the Region / a foreign territory);
#   - the state of the input: hovering - a thin frame, a click - a thick one.
# anchor_row/anchor_col is the hex from which the selection was started (hovering/clicking):
# its status determines the type of the action (is_explored/in_influence -> the claiming,
# otherwise -> the scouting; the chunk is homogeneous in status, therefore there are no discrepancies).
# The availability is counted in the same way as in control_panel._collect_region_actions:
#   - the claiming: the chunk is non-empty, the hex is not in the ring of a foreign town, inside the Region
#     and at least one hex of the chunk adjoins in_influence (its own territory is
#     always "available");
#   - the scouting: main_map.is_chunk_adjacent_to_known (adjoining the known
#     world) - the same gate as that of the button "Send the scouts".
# The state is_scouting (an expedition is already going) is not taken into account: this is a temporary
# mode, and not a property of the chunk.
# The ONLY place of the highlighting system with the specific values of the colours:
# edit the palette only here - in the comments of the code and the documentation
# the specific colours are deliberately not duplicated, so that they do not become outdated.
func _get_highlight_style(chunk: Array, anchor_row: int, anchor_col: int, selected: bool) -> Dictionary:
    var tile = null
    if main_map.is_hex_on_map(anchor_row, anchor_col):
        tile = main_map.tile_data[anchor_row][anchor_col]
    var acquire: bool = tile != null \
            and (bool(tile.get("is_explored", false)) \
            or bool(tile.get("in_influence", false)))
    var available := false
    if acquire:
        if tile != null and bool(tile.get("in_influence", false)):
            available = true
        elif tile != null and not bool(tile.get("in_town_influence", false)) \
                and main_map.is_valid_hex(anchor_row, anchor_col):
            for hex in chunk:
                for n in HexUtils.get_neighbors_odd_r(hex.row, hex.col, main_map.map_rows, main_map.map_cols):
                    if bool(main_map.tile_data[n.row][n.col].get("in_influence", false)):
                        available = true
                        break
                if available:
                    break
    else:
        available = not chunk.is_empty() and main_map.is_chunk_adjacent_to_known(chunk)
    if acquire:
        if available:
            if selected:
                return {"fill": Color(1.0, 0.9, 0.3, 0.25), "border": Color(1.0, 0.85, 0.2, 0.95), "width": 3.0}
            return {"fill": Color(1.0, 1.0, 0.0, 0.3), "border": Color(1.0, 1.0, 0.0, 0.9), "width": 2.0}
        if selected:
            return {"fill": Color(0.66, 0.56, 0.66, 0.18), "border": Color(0.45, 0.38, 0.48, 0.85), "width": 3.0}
        return {"fill": Color(0.66, 0.56, 0.66, 0.24), "border": Color(0.48, 0.4, 0.5, 0.9), "width": 2.0}
    if available:
        if selected:
            return {"fill": Color(0.3, 0.72, 1.0, 0.25), "border": Color(0.2, 0.62, 1.0, 0.95), "width": 3.0}
        return {"fill": Color(0.35, 0.78, 1.0, 0.3), "border": Color(0.3, 0.72, 1.0, 0.9), "width": 2.0}
    if selected:
        return {"fill": Color(0.58, 0.68, 0.75, 0.18), "border": Color(0.5, 0.57, 0.63, 0.8), "width": 3.0}
    return {"fill": Color(0.58, 0.68, 0.75, 0.22), "border": Color(0.5, 0.57, 0.63, 0.85), "width": 2.0}

# Draws the highlighting of the selected hex: a semi-transparent fill + a bright frame.
# It is called both for a single hex in the Influence Ring, and for each
# hex of a SELECTED chunk (Phase 3.5). The colours are taken from style - see
# _get_highlight_style (the four types of the chunks: the scouting/the claiming × possible/
# impossible). The chunk can go beyond the limits of the Region - in this case a part of its
# hexes lies in the fog of war, and the highlighting must be visible there as well (identically
# to the Region). We do NOT filter by the visibility: the hexes are already limited either by the Influence
# Ring (the single call), or by `scout_reach_bounds` (the call from the chunk), and
# outside the viewport the canvas itself will cut the drawing.
func _draw_selected_hex_highlight(row: int, col: int, style: Dictionary):
    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    center.x += main_map.offset_x + main_map.scroll_offset.x
    center.y += main_map.offset_y + main_map.scroll_offset.y
    var vertices = PackedVector2Array()
    vertices.append_array(HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS))

    # A semi-transparent fill (over the terrain, but under the icons of the resources/the improvements).
    draw_colored_polygon(vertices, style.fill)

    # A bright frame.
    var closed_vertices = PackedVector2Array()
    closed_vertices.append_array(vertices)
    closed_vertices.append(vertices[0])
    draw_polyline(closed_vertices, style.border, style.width)

# Draws a filled (complex) asterisk.
func _draw_star(cx: float, cy: float, r_outer: float, r_inner: float, color: Color):
    var points = PackedVector2Array()
    for i in range(5):
        var angle = deg_to_rad(i * 72.0 - 90.0)
        var outer = Vector2(cx + cos(angle) * r_outer, cy + sin(angle) * r_outer)
        points.append(outer)
        var inner_angle = deg_to_rad(i * 72.0 + 36.0 - 90.0)
        var inner = Vector2(cx + cos(inner_angle) * r_inner, cy + sin(inner_angle) * r_inner)
        points.append(inner)
    draw_colored_polygon(points, color)

# Draws a contour of an asterisk (empty/unfilled).
func _draw_star_outline(cx: float, cy: float, r_outer: float, r_inner: float, color: Color):
    var points = PackedVector2Array()
    for i in range(5):
        var angle = deg_to_rad(i * 72.0 - 90.0)
        points.append(Vector2(cx + cos(angle) * r_outer, cy + sin(angle) * r_outer))
        var inner_angle = deg_to_rad(i * 72.0 + 36.0 - 90.0)
        points.append(Vector2(cx + cos(inner_angle) * r_inner, cy + sin(inner_angle) * r_inner))
    var closed = PackedVector2Array()
    closed.append_array(points)
    closed.append(points[0])
    draw_polyline(closed, color, 1.5)

func _is_resource_locked(resource_id: String) -> bool:
    if resource_id == null or resource_id == "":
        return false
    var res_data = GameData.raw_resources.get(resource_id, {})
    var imp_id = res_data.get("improved_by", "")
    # For a part of the resources (for example, the wild plants foraged_food) improved_by is set
    # as null - then .get() returns Nil, and not the default value.
    if imp_id == null:
        return false
    # The resource is considered blocked if the improvement which
    # extracts it (improved_by) is not yet unlocked by its unlock_tech.
    return not CityData.is_improvement_unlocked(imp_id)

func is_resource_locked(resource_id: String) -> bool:
    return _is_resource_locked(resource_id)

# --- The "ghost" road: the unbuilt route from the preview ---
# The control panel puts the NEW segments of the plan here (road_manager
# .get_plan_new_segments) for as long as the preview of the special action
# "Build a road" is open, and removes them as soon as the preview is closed. This is a hint,
# and not a road: it is semi-transparent and is drawn by the last pass.
var _road_preview_segments: Dictionary = {}
# The label of the set of the segments. The panel keeps the preview open between the ticks, and without
# a comparison the map would be redrawn in vain on every update of the panel.
var _road_preview_signature: String = ""

# Show the "ghost" road (an empty dictionary - hide). The redrawing only
# on a real change of the route.
func set_road_preview_segments(segments: Dictionary) -> void:
    var keys := segments.keys()
    keys.sort()
    var signature := str(keys)
    if signature == _road_preview_signature:
        return
    _road_preview_signature = signature
    _road_preview_segments = segments
    queue_redraw()

# The "ghost" of a going project: the segments of the queue segments which are NOT YET BUILT.
# Unlike the preview it lives not until the click of "Cancel", but until the end of the build -
# the player sees the whole route on the map all this time and understands that there is still
# something to come. A built segment disappears from the set by itself (the step has left the queue,
# the set is rebuilt on every event of the project), therefore a segment
# turns from a ghost into a real road.
# This is a common mechanism for any phased projects: the segments come from
# project_manager (get_pending_ghost_segments), and the style of the drawing of the road and of the
# future aqueduct will be its own - here it is common for both.
var _project_ghost_segments: Dictionary = {}
var _project_ghost_signature: String = ""

func set_project_ghost_segments(segments: Dictionary) -> void:
    var keys := segments.keys()
    keys.sort()
    var signature := str(keys)
    if signature == _project_ghost_signature:
        return
    _project_ghost_signature = signature
    _project_ghost_segments = segments
    queue_redraw()

# The highlighting of the ROUTE along which the cargo goes from the chosen hex to the city.
# A separate set from the preview: the preview is "what will be built", and here it is
# "what is already built and is working right now". The panel puts here the segments
# of the existing route (road_manager.find_route_to_city) and removes them on
# a change of the selection. As in the preview, it compares the label of the set: the panel keeps
# the route open between the ticks, and without a comparison the map would be redrawn
# in vain.
var _route_segments: Dictionary = {}
var _route_signature: String = ""

func set_route_segments(segments: Dictionary) -> void:
    var keys := segments.keys()
    keys.sort()
    var signature := str(keys)
    if signature == _route_signature:
        return
    _route_signature = signature
    _route_segments = segments
    queue_redraw()

func _draw_all_roads():
    if main_map == null or not main_map.has_method("get"):
        return
    if not main_map.has_node("RoadManager"):
        return

    var road_manager = main_map.get_node("RoadManager")

    # PHASE 2a: the roads of the CITY of the player. They have no visibility gates and never had:
    # they always lie on their own claimed territory, where there is no fog of war
    # at all. An exception is the roads CONNECTING the city with a town (PHASE 2c):
    # the player builds them over the scouted, but not claimed land.
    # The roads are drawn BY LEVELS: the segments of one level get the colour and the thickness
    # from data/roads.json, therefore an improved road is visible on the map at once, without
    # opening the panel. Earlier all the roads were of one colour and one thickness.
    _draw_road_segments_by_level(road_manager.get_all_road_segments(), false)

    # PHASE 2b: the roads of the TOWNS - a separate network, but it is drawn with the same style
    # (see road_manager.rebuild_town_roads: the network of each town goes from its
    # centre to the improvements in the influence ring and is not connected with the roads of the city).
    # The visibility is exactly the same as that of the fill of the rings: see are_town_roads_visible()
    # and is_town_road_segment_visible() below.
    if are_town_roads_visible():
        _draw_road_segments(road_manager.get_all_town_road_segments(), true)

    # PHASE 2c: the roads connecting the city with the towns (the special action
    # "Build a road", clicked on the hex of a town). These are the roads of the NETWORK of the CITY,
    # and they go over the scouted (but not claimed) land - therefore the visibility gates of
    # them are the same as those of the roads of the towns. Strictly speaking, it is impossible to build them through
    # an unexplored hex (see main_map.get_road_plan), so
    # this gate is an insurance for the future, if the rule "only over the scouted
    # land" is ever relaxed.
        _draw_road_segments(road_manager.get_all_town_link_segments(), true)

    # PHASE 2d: the "ghost" of a going project - the remainder of the route which is not
    # built yet. It lives until the end of the build, and not until the closing of the panel, and it is drawn
    # with the same style and in the same pass as the preview (that is, over the real
    # roads, but under the rivers and the icons). The gates of the era and of the fog are the same: this is a hint,
    # and not a construction, and it must not give away the unexplored.
    # It goes BEFORE the preview: the preview is what the player is looking at right now, and it
    # must lie on top. Both sets are open simultaneously rarely (one needs to
    # confirm a road and immediately start a new one), but when it happens, both
    # routes are visible, and the active one must not drown in the background.
    _draw_project_ghost()

    # PHASE 2e: the "ghost" road - the route from the open preview. It is drawn
    # by the last pass (over the roads and the ghost of the project), but before the rivers,
    # the highlightings and the icons, as all the other roads. It does NOT need a gate of the era: this is
    # a hint, and not a construction, and it is shown in any era, as the roads
    # of the city. The gate of the fog is checked just in case - the planning goes
    # only over the scouted land, so it cannot get into the fog, but
    # the possibility to "give away" the fog is excluded.
    _draw_road_preview()

    # PHASE 2f: the highlighting of the ROUTE of the chosen hex to the city. It goes after all
    # the road layers and over them: this is a thin line over the already drawn
    # roads, and it must be visible over them. It does not need a gate of the era, as does
    # the preview: the route goes along the roads which are drawn with the same gates.
    _draw_route()

# The highlighting of the route: its segments are already drawn as roads, therefore here
# only a thin line on top is drawn - by the same geometry as the road.
func _draw_route() -> void:
    if _route_segments.is_empty():
        return
    var visible: Dictionary = {}
    for segment_key in _route_segments.keys():
        var parts := str(segment_key).split("|")
        if parts.size() != 2:
            continue
        var start_parts = parts[0].split(",")
        var end_parts = parts[1].split(",")
        if start_parts.size() != 2 or end_parts.size() != 2:
            continue
        if _segment_clear_of_fog(int(start_parts[0]), int(start_parts[1]),
                int(end_parts[0]), int(end_parts[1])):
            visible[segment_key] = true
    if visible.is_empty():
        return
    _draw_road_segments(visible, false, ROUTE_COLOR, ROUTE_WIDTH)

# The "ghost" of an unfinished project. A separate set of the segments, and not a common one with
# the preview: the preview lives while the panel is open, the ghost of the project - while the build
# is going, and it appears already AFTER the confirmation.
func _draw_project_ghost() -> void:
    if _project_ghost_segments.is_empty():
        return
    var visible: Dictionary = {}
    for segment_key in _project_ghost_segments.keys():
        var parts := str(segment_key).split("|")
        if parts.size() != 2:
            continue
        var start_parts = parts[0].split(",")
        var end_parts = parts[1].split(",")
        if start_parts.size() != 2 or end_parts.size() != 2:
            continue
        if _segment_clear_of_fog(int(start_parts[0]), int(start_parts[1]),
                int(end_parts[0]), int(end_parts[1])):
            visible[segment_key] = true
    if visible.is_empty():
        return
    _draw_road_segments(visible, false, ROAD_PREVIEW_HALO_COLOR, ROAD_PREVIEW_HALO_WIDTH)
    _draw_road_segments(visible, false, ROAD_PREVIEW_COLOR, ROAD_PREVIEW_WIDTH)

# Are the roads of the towns shown. The same gate as that of the fill of the influence rings
# (_ensure_town_influence_cache): in the 1st epoch a foreign town is not shown
# at all, otherwise the road would give it away in the unexplored zone of the Region from the very
# beginning of the game - except when the whole map was revealed on purpose by the debug action.
func are_town_roads_visible() -> bool:
    if main_map == null:
        return false
    return main_map.current_era >= 1 or main_map.debug_whole_map_revealed

# Is a specific segment of the road of a town visible. A segment is not drawn if at least
# one of its ends lies in the fog of war: otherwise the road would "give away" the contents
# of the unexplored territory. A scouted hex beyond the limits of the Region shows the road
# (this is how the scouting works).
func is_town_road_segment_visible(row1: int, col1: int, row2: int, col2: int) -> bool:
    if not are_town_roads_visible():
        return false
    return _segment_clear_of_fog(row1, col1, row2, col2)

# Both ends of the segment are outside the fog of war - without the check of the era. It is moved out separately,
# because the "ghost" road does not need a gate of the era (it is not a construction), and the gate
# of the fog is needed.
func _segment_clear_of_fog(row1: int, col1: int, row2: int, col2: int) -> bool:
    return not (main_map.is_hex_in_fog(row1, col1) or main_map.is_hex_in_fog(row2, col2))

# Draws the roads, grouping the segments BY LEVEL: the colour and the thickness are taken from
# data/roads.json (the fields color/width). Thus the level of the road is visible on the map
# without opening the panel.
#
# The set of the segments stores the level BY VALUE (see road_manager.road_segments),
# therefore the grouping is free - it is one pass over the dictionary.
#
# hide_in_fog is the same gate as that of _draw_road_segments (for the roads of the towns).
# A level which is not in the data is drawn with the default style ROAD_COLOR:
# this is an error of the data, and not a reason to silently not draw the road.
func _draw_road_segments_by_level(segments: Dictionary, hide_in_fog: bool) -> void:
    if segments.is_empty():
        return
    var by_level: Dictionary = {}
    for segment_key in segments.keys():
        var level := int(segments[segment_key])
        if not by_level.has(level):
            by_level[level] = {}
        by_level[level][segment_key] = true
    var levels: Array = by_level.keys()
    levels.sort()
    for level in levels:
        var road: Dictionary = GameData.get_road_by_level(int(level))
        if road.is_empty():
            _draw_road_segments(by_level[level], hide_in_fog)
            continue
        var rgb: Array = road.get("color", [])
        var color := ROAD_COLOR
        if rgb is Array and rgb.size() == 3:
            color = Color(float(rgb[0]) / 255.0, float(rgb[1]) / 255.0,
                    float(rgb[2]) / 255.0)
        _draw_road_segments(by_level[level], hide_in_fog, color,
                int(road.get("width", ROAD_WIDTH)))

# Draws a set of the segments of the roads.
# hide_in_fog is the gate for a segment at least one of whose ends lies in the fog
# of war: such a segment is not drawn (it would give away the contents of the unexplored
# territory). For the roads of the city of the player the gate is off.
# color / width is the style: by default a real road, for the preview its own
# values are passed (see ROAD_PREVIEW_*).
func _draw_road_segments(segments: Dictionary, hide_in_fog: bool,
        color: Color = ROAD_COLOR, width: int = ROAD_WIDTH) -> void:
    if segments.is_empty():
        return
    
    for segment_key in segments.keys():
        var parts = segment_key.split("|")
        if parts.size() != 2:
            continue
        
        var start_parts = parts[0].split(",")
        var end_parts = parts[1].split(",")
        
        if start_parts.size() != 2 or end_parts.size() != 2:
            continue
        
        var row1 = int(start_parts[0])
        var col1 = int(start_parts[1])
        var row2 = int(end_parts[0])
        var col2 = int(end_parts[1])

        if hide_in_fog and not is_town_road_segment_visible(row1, col1, row2, col2):
            continue

        # The viewport culling: we skip the road segments which do not intersect the screen.
        var c1 = HexUtils.hex_center(row1, col1, main_map.HEX_RADIUS)
        c1.x += main_map.offset_x + main_map.scroll_offset.x
        c1.y += main_map.offset_y + main_map.scroll_offset.y
        var c2 = HexUtils.hex_center(row2, col2, main_map.HEX_RADIUS)
        c2.x += main_map.offset_x + main_map.scroll_offset.x
        c2.y += main_map.offset_y + main_map.scroll_offset.y
        var road_rect = Rect2(
            min(c1.x, c2.x) - main_map.HEX_RADIUS,
            min(c1.y, c2.y) - main_map.HEX_RADIUS,
            abs(c2.x - c1.x) + main_map.HEX_RADIUS * 2,
            abs(c2.y - c1.y) + main_map.HEX_RADIUS * 2
        )
        if not _is_rect_visible(road_rect):
            continue

        var points = _generate_natural_road(row1, col1, row2, col2, main_map.HEX_RADIUS)
        draw_polyline(points, color, width, true)

# The "ghost" road: the segments of the plan which is open in the preview. Two passes - a wide
# semi-transparent halo and a line on top: the route reads over the terrain, the rivers and
# the real roads.
func _draw_road_preview() -> void:
    if _road_preview_segments.is_empty():
        return
    # The segments at least one end of which is in the fog are never drawn
    # (see the comment to PHASE 2d in _draw_all_roads).
    var visible: Dictionary = {}
    for segment_key in _road_preview_segments.keys():
        var parts = str(segment_key).split("|")
        if parts.size() != 2:
            continue
        var start_parts = parts[0].split(",")
        var end_parts = parts[1].split(",")
        if start_parts.size() != 2 or end_parts.size() != 2:
            continue
        if _segment_clear_of_fog(int(start_parts[0]), int(start_parts[1]),
                int(end_parts[0]), int(end_parts[1])):
            visible[segment_key] = true
    if visible.is_empty():
        return
    _draw_road_segments(visible, false, ROAD_PREVIEW_HALO_COLOR, ROAD_PREVIEW_HALO_WIDTH)
    _draw_road_segments(visible, false, ROAD_PREVIEW_COLOR, ROAD_PREVIEW_WIDTH)

func _draw_rivers():
    if main_map == null:
        return
    if not main_map.has_node("RiverManager"):
        return
    _flush_scroll_cache_invalidation()
    var river_manager = main_map.get_node("RiverManager")
    var radius = main_map.HEX_RADIUS
    _build_river_frame_cache(radius)

    # The main rivers are thicker and darker.
    _draw_river_list(river_manager.get_main_rivers(),
            river_manager.RIVER_SHORE_COLOR, river_manager.RIVER_SHORE_WIDTH,
            river_manager.RIVER_COLOR, river_manager.RIVER_WIDTH,
            river_manager.RIVER_HIGHLIGHT_COLOR, river_manager.RIVER_HIGHLIGHT_WIDTH)

    # The tributaries are thinner and lighter, in order to be visually different from the main rivers.
    _draw_river_list(river_manager.get_tributaries(),
            river_manager.TRIBUTARY_SHORE_COLOR, river_manager.TRIBUTARY_SHORE_WIDTH,
            river_manager.TRIBUTARY_COLOR, river_manager.TRIBUTARY_WIDTH,
            river_manager.TRIBUTARY_HIGHLIGHT_COLOR, river_manager.TRIBUTARY_HIGHLIGHT_WIDTH)


# Draws the list of the rivers with the given style (the bank, the body, the highlight).
# All the geometry and the clipping of the invisible are in _build_river_frame_cache.
func _draw_river_list(river_list: Array,
        shore_color: Color, shore_width: float,
        body_color: Color, body_width: float,
        highlight_color: Color, highlight_width: float):
    # The rivers are drawn in segments, not as whole polylines: only the runs that actually
    # intersect the screen are shifted by the offset and handed to draw_polyline. The geometry
    # cached for the screen plus the pan margin contains far more points than the screen shows
    # (a lightly meandering river has ~50 points per hex), and shifting those per frame costs
    # more than the drawing itself.
    var screen: Rect2 = _get_screen_rect()
    var offset: Vector2 = _river_frame_offset
    for river in river_list:
        var entry = _river_frame_cache.get(_river_index(river))
        if entry == null:
            continue
        for seg in entry["segments"]:
            if not seg["rect"].intersects(screen):
                continue
            var run: PackedVector2Array = seg["points"]
            var out := PackedVector2Array()
            out.resize(run.size())
            for i in range(run.size()):
                out[i] = run[i] + offset
            draw_polyline(out, shore_color, shore_width, true)
            draw_polyline(out, body_color, body_width, true)
            draw_polyline(out, highlight_color, highlight_width, true)


# The identity of a river inside _river_frame_cache: a river is a plain Array, and arrays are
# compared by value, so a long river would be hashed on every lookup. The index inside the
# manager's list is stable and cheap.
func _river_index(river: Array) -> int:
    return river.size() * 1000003 + absi(_points_hash(river))


func _points_hash(river: Array) -> int:
    if river.is_empty():
        return 0
    var p: Vector2 = river[0]
    return roundi(p.x * 10.0) * 31 + roundi(p.y * 10.0)


# Rebuilds the per-frame geometry of the rivers: the viewport culling, the smoothing (cached),
# the clipping by the screen rectangle and the grouping of the visible points by the style.
# The caches are keyed by the current offset and are reused while the map is scrolled by no more
# than the cached margin - that is what removes the per-frame cost of the pan.
func _build_river_frame_cache(radius: float) -> void:
    var offset_x = main_map.offset_x + main_map.scroll_offset.x
    var offset_y = main_map.offset_y + main_map.scroll_offset.y
    _river_frame_offset = Vector2(offset_x, offset_y)
    var river_manager = main_map.get_node("RiverManager")
    var all_rivers: Array = river_manager.get_main_rivers() + river_manager.get_tributaries()

    if not _river_frame_cache.is_empty():
        var cached_offset: Vector2 = _river_frame_cache_offset
        var drift = absf(offset_x - cached_offset.x)
        drift = maxf(drift, absf(offset_y - cached_offset.y))
        if drift <= main_map.MAP_CACHE_MARGIN:
            # A new river (or a changed path) invalidates the cache: the list of the rivers is
            # the cache key, and on a loaded save it differs from the generated one.
            #
            # The check must NOT demand an entry for every river: _collect_river_segments stores
            # only the rivers intersecting the cached rectangle, so having just a few of them is
            # the normal state, and the old "cache size == river count" test therefore failed on
            # EVERY frame and destroyed the whole point of the cache. Instead we require that
            # every river present in the cache still exists in the current list.
            var fresh := true
            var rivers_by_index := {}
            for river in all_rivers:
                rivers_by_index[_river_index(river)] = true
            for key in _river_frame_cache.keys():
                if not rivers_by_index.has(key):
                    fresh = false
                    break
            if fresh:
                return

    _river_frame_cache.clear()
    _river_frame_cache_offset = Vector2(offset_x, offset_y)
    _river_frame_rebuilds += 1

    # The world -> screen offset of the cached geometry is the current one; the margin around the
    # screen makes the cache valid for the same pan distance in any direction.
    var screen_rect = Rect2(
        Vector2(-main_map.MAP_CACHE_MARGIN, -main_map.MAP_CACHE_MARGIN),
        _get_viewport_size() + Vector2(main_map.MAP_CACHE_MARGIN, main_map.MAP_CACHE_MARGIN) * 2.0
    )

    for river in all_rivers:
        if river.size() < 2:
            continue
        # The viewport culling: a river entirely outside the cached rectangle cannot appear
        # on the screen within the margin, therefore it costs nothing at the drawing.
        var min_x = INF
        var max_x = - INF
        var min_y = INF
        var max_y = - INF
        for pt in river:
            var px = pt.x + offset_x
            var py = pt.y + offset_y
            min_x = minf(min_x, px)
            max_x = maxf(max_x, px)
            min_y = minf(min_y, py)
            max_y = maxf(max_y, py)
        var river_rect = Rect2(
            min_x - radius,
            min_y - radius,
            (max_x - min_x) + radius * 2.0,
            (max_y - min_y) + radius * 2.0
        )
        if not river_rect.intersects(screen_rect):
            continue

        _river_frame_cache[_river_index(river)] = {
            "segments": _collect_river_segments(river, offset_x, offset_y, radius)
        }


# The visible runs of ONE river in the WORLD coordinates, together with the screen-space bounds
# of each run. The smoothed meanders are cached per river in the world coordinates, so a pan
# within the cached margin does not rebuild them.
func _collect_river_segments(river: Array, offset_x: float, offset_y: float,
        radius: float) -> Array:
    var segments: Array = []
    var cache_key = "%d|" % river.size() + _points_to_cache_key(river)
    var smooth_points: PackedVector2Array
    if _river_smooth_cache.has(cache_key):
        smooth_points = _river_smooth_cache[cache_key]
    else:
        var world_points = PackedVector2Array()
        for pt in river:
            world_points.append(Vector2(pt.x, pt.y))
        smooth_points = _generate_natural_river(world_points, radius)
        _river_smooth_cache[cache_key] = smooth_points

    # The points are in the world coordinates and the clipping happens in the screen ones: the
    # cache rectangle translated by the negated offset covers exactly the world points whose
    # screen position falls inside the cached rectangle.
    var clipped_lines = _clip_river_to_rect(
        river_points_with_offset(smooth_points, offset_x, offset_y),
        _get_cache_rect()
    )
    for line in clipped_lines:
        if line.size() < 2:
            continue
        # Back to the world coordinates, so that the drawing only has to add the current offset.
        var world := PackedVector2Array()
        world.resize(line.size())
        var min_x = INF
        var max_x = - INF
        var min_y = INF
        var max_y = - INF
        for i in range(line.size()):
            world[i] = line[i] - Vector2(offset_x, offset_y)
            min_x = minf(min_x, line[i].x)
            max_x = maxf(max_x, line[i].x)
            min_y = minf(min_y, line[i].y)
            max_y = maxf(max_y, line[i].y)
        var width = (max_x - min_x) + 2.0 * radius
        var height = (max_y - min_y) + 2.0 * radius
        segments.append({
            "points": world,
            "rect": Rect2(min_x - radius, min_y - radius, width, height)
        })
    return segments


# The rectangle of the cached river geometry: the screen grown by the pan margin on each side.
func _get_cache_rect() -> Rect2:
    return Rect2(
        Vector2(-main_map.MAP_CACHE_MARGIN, -main_map.MAP_CACHE_MARGIN),
        _get_viewport_size() + Vector2(main_map.MAP_CACHE_MARGIN, main_map.MAP_CACHE_MARGIN) * 2.0
    )


func river_points_with_offset(points: PackedVector2Array, dx: float, dy: float) -> PackedVector2Array:
    var shifted := PackedVector2Array()
    shifted.resize(points.size())
    for i in range(points.size()):
        shifted[i] = Vector2(points[i].x + dx, points[i].y + dy)
    return shifted


# Called by the input handler after every change of the scroll offset. The screen-sized caches of
# the map (the influence rings of the towns, the river geometry) are built for a concrete offset;
# they stay valid while the map is scrolled by no more than the cached margin. The redraw itself
# must still be requested, so this only records that the staleness has to be re-checked.
func queue_redraw_for_scroll() -> void:
    _scroll_since_cache = true
    queue_redraw()


# Re-checks the validity of the caches at the beginning of a frame: once the pan has left the
# cached margin, the screen-sized caches are rebuilt for the new offset.
func _flush_scroll_cache_invalidation() -> void:
    if not _scroll_since_cache:
        return
    _scroll_since_cache = false
    var offset = Vector2(
        main_map.offset_x + main_map.scroll_offset.x,
        main_map.offset_y + main_map.scroll_offset.y
    )
    if is_inf(_cache_built_offset.x):
        return
    var drift = maxf(absf(offset.x - _cache_built_offset.x),
            absf(offset.y - _cache_built_offset.y))
    if drift > main_map.MAP_CACHE_MARGIN:
        _invalidate_screen_caches()


# Drops the screen-sized caches of the map, so that they are rebuilt for the current offset
# on the next frame.
func _invalidate_screen_caches() -> void:
    _river_frame_cache.clear()
    invalidate_town_influence_cache()


# Clips the segment (start -> end) by the rectangle rect (the Liang-Barsky algorithm).
# Returns [Vector2, Vector2] for the visible part, or [] if the segment is outside the rect.
func _clip_segment_to_rect(start: Vector2, end: Vector2, rect: Rect2) -> Array:
    var t0 = 0.0
    var t1 = 1.0
    var dx = end.x - start.x
    var dy = end.y - start.y
    var p = [-dx, dx, -dy, dy]
    var q = [
        start.x - rect.position.x,
        rect.position.x + rect.size.x - start.x,
        start.y - rect.position.y,
        rect.position.y + rect.size.y - start.y
    ]
    for i in range(4):
        if abs(p[i]) < 1e-9:
            if q[i] < 0.0:
                return []
        else:
            var r = q[i] / p[i]
            if p[i] < 0.0:
                if r > t1:
                    return []
                if r > t0:
                    t0 = r
            else:
                if r < t0:
                    return []
                if r < t1:
                    t1 = r
    return [start + (end - start) * t0, start + (end - start) * t1]


# Clips a polyline by the rectangle rect. Returns an array of the clipped
# polylines (each is a PackedVector2Array), combining the adjacent segments into
# continuous lines.
func _clip_river_to_rect(points: PackedVector2Array, rect: Rect2) -> Array:
    if points.size() < 2:
        return []
    var segments: Array = []
    for i in range(points.size() - 1):
        var clipped = _clip_segment_to_rect(points[i], points[i + 1], rect)
        if clipped.size() == 2:
            segments.append(clipped)
    if segments.is_empty():
        return []

    var polylines: Array = []
    var current = PackedVector2Array()
    current.append(segments[0][0])
    current.append(segments[0][1])
    for i in range(1, segments.size()):
        var seg = segments[i]
        if current[-1].distance_to(seg[0]) < 0.01:
            current.append(seg[1])
        else:
            polylines.append(current)
            current = PackedVector2Array()
            current.append(seg[0])
            current.append(seg[1])
    polylines.append(current)
    return polylines

func _draw_roads(_row: int, _col: int):
    pass

func _generate_natural_road(
    row1: int,
    col1: int,
    row2: int,
    col2: int,
    radius: float
) -> Array:
    var segments = 3
    var points = []
    var main = get_parent()
    var center1 = HexUtils.hex_center(row1, col1, radius)
    center1.x += main.offset_x + main.scroll_offset.x
    center1.y += main.offset_y + main.scroll_offset.y
    var center2 = HexUtils.hex_center(row2, col2, radius)
    center2.x += main.offset_x + main.scroll_offset.x
    center2.y += main.offset_y + main.scroll_offset.y
    
    points.append(center1)
    for i in range(1, segments):
        var t = float(i) / segments
        var mid = center1.lerp(center2, t)
        var dir = (center2 - center1).normalized()
        var perp = Vector2(-dir.y, dir.x)
        var hash_input = (
            row1 * 73856093 + col1 * 19349663 + row2 * 83492791
        ) & 0x7fffffff
        var hash_val = float(hash_input) / 0x7fffffff
        var offset = (hash_val - 0.5) * radius * 0.5
        mid += perp * offset
        points.append(mid)
    points.append(center2)
    return points

func _generate_natural_river(river_points: PackedVector2Array, radius: float) -> PackedVector2Array:
    if river_points.size() < 2:
        return river_points

    # The sample step sets the point count of the meanders, and that count is what the frame
    # pays for: every point is shifted by the scroll offset and handed to draw_polyline. The
    # wave period is 2*PI/frequency ~= 7 * sample_step, so a step larger than a quarter of the
    # wavelength stops improving the shape (the Chaikin pass below rounds what is left).
    var sample_step = max(radius * 0.35, 14.0)
    var amplitude = max(radius * 0.16, 7.0)
    var frequency = 0.9 / max(sample_step, 1.0)
    var phase = 0.45 + float(river_points.size()) * 0.12

    var curved_points = PackedVector2Array()
    var total_length = 0.0
    var segment_lengths: Array = []

    for i in range(river_points.size() - 1):
        var seg_len = river_points[i].distance_to(river_points[i + 1])
        segment_lengths.append(seg_len)
        total_length += seg_len

    if total_length <= 0.0:
        return river_points

    var distance_along = 0.0
    for i in range(river_points.size() - 1):
        var start = river_points[i]
        var end = river_points[i + 1]
        var segment_dir = end - start
        var segment_len = segment_dir.length()
        if segment_len <= 0.0001:
            continue

        segment_dir = segment_dir.normalized()
        var normal = Vector2(-segment_dir.y, segment_dir.x)

        var step_count = max(1, int(ceil(segment_len / sample_step)))
        for step in range(step_count + 1):
            var t = float(step) / float(step_count)
            var base_point = start.lerp(end, t)
            var local_distance = distance_along + segment_len * t

            var offset = Vector2.ZERO
            if step != 0 and step != step_count:
                var meander = sin(local_distance * frequency + phase) * amplitude
                var secondary = sin(local_distance * frequency * 0.55 + phase * 1.7) * amplitude * 0.35
                var bend = 0.0
                if i > 0 and i + 1 < river_points.size() - 1:
                    var prev_dir = (start - river_points[i - 1]).normalized()
                    var next_dir = (river_points[i + 2] - end).normalized()
                    var turn_strength = clamp(1.0 - prev_dir.dot(next_dir), 0.0, 1.0)
                    var turn_sign = sign(prev_dir.cross(next_dir))
                    if turn_sign == 0:
                        turn_sign = 1.0
                    bend = turn_strength * amplitude * 0.18 * turn_sign

                offset = normal * (meander + secondary + bend)

            var point = base_point + offset
            if curved_points.is_empty() or curved_points[-1].distance_to(point) > 0.5:
                curved_points.append(point)

        distance_along += segment_len

    if curved_points.size() < 2:
        return river_points

    # We apply 1-2 iterations of the smoothing - it is enough to remove the sharp
    # corners, but to preserve the general shape and the meandering. The implementation
    # is moved out into a separate function below.
    return _chaikin_smooth(curved_points, 2)

func _draw_exploration_highlights():
    var main = get_parent()
    var expansion_manager = main.get_node("ExpansionManager")
    if not expansion_manager:
        return

    var visible = _get_visible_hex_range()

    # --- 1. The highlighting of the scouted hexes (only in the visible area) ---
    # Outside the visible area (the fog of war) the terrain is not drawn by the renderer, therefore
    # a fill for the scouted hexes is not needed there.
    for row in range(visible.row_start, visible.row_end + 1):
        for col in range(visible.col_start, visible.col_end + 1):
            var tile = tile_data[row][col]
            if tile.get("in_influence", false):
                continue
            var is_explored = tile.get("is_explored", false)
            if not is_explored:
                continue
            var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
            center.x += main.offset_x + main.scroll_offset.x
            center.y += main.offset_y + main.scroll_offset.y
            var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)
            # Scouted: only the fill - there is deliberately no white frame here
            # it merged with the grid of the hexes and visually "inflated"
            # the scouted area. The frame is drawn only by the hover/the selection of the chunk
            # (see _draw_selected_hex_highlight).
            draw_colored_polygon(vertices, Color(0.652, 0.855, 0.652, 0.25))

    # --- 2. The highlighting of the selected chunk (the Region + the fog of war) ---
    # The chunk can include the hexes in the fog of war (the scouting) - the highlighting is drawn
    # FOR EACH hex of the chunk, without a filter by the visible area. Otherwise in the fog
    # the player does not see which exactly the area is selected now and where the
    # scouts will go. The colour depends on the type of the chunk (the scouting/the claiming × possible/
    # impossible - see _get_highlight_style): the tone of the action and its mutedness.
    #
    # Before the study of Cartography the highlighting does NOT go beyond the limits of the Region: there
    # the scouting is unavailable, and the highlighting on the dark canvas of the fog would only
    # confuse the player (see main_map.is_cartography_researched). The chunks
    # collected by expansion_manager already comply with this rule - the filter below is
    # an insurance (for example, an outdated current_chunk after the load of a save).
    var chunk: Array = expansion_manager.current_chunk
    var anchor = expansion_manager.current_hover_hex
    if chunk.is_empty():
        # There is no chunk under the cursor (a scouted hex outside the Region or a hex in the
        # influence ring of a foreign town): we highlight the hex under the cursor itself -
        # with the same colour as that of the chunk. Otherwise the hovering would be "silent", and a
        # click on such a hex already gives the highlighting (see PHASE 3.5 and
        # expansion_manager.get_highlight_hexes).
        if anchor == null:
            return
        chunk = expansion_manager.get_highlight_hexes(anchor.row, anchor.col)
    if anchor == null:
        # An outdated current_chunk without a hex under the cursor (an insurance):
        # we take the first hex of the chunk as the reference point for the classification.
        anchor = chunk[0]
    var style: Dictionary = _get_highlight_style(chunk, anchor.row, anchor.col, false)

    var cartography: bool = main_map.is_cartography_researched()
    for hex in chunk:
        if not cartography and not main_map.is_valid_hex(hex.row, hex.col):
            continue
        var center = HexUtils.hex_center(hex.row, hex.col, main_map.HEX_RADIUS)
        center.x += main.offset_x + main.scroll_offset.x
        center.y += main.offset_y + main.scroll_offset.y
        var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)
        draw_colored_polygon(vertices, style.fill)
        var closed_verts = PackedVector2Array()
        closed_verts.append_array(vertices)
        closed_verts.append(vertices[0])
        draw_polyline(closed_verts, style.border, style.width)

# Returns a compact string key for the cache of the smoothed river.
# It serializes the coordinates of the points of the river (the world ones, without the offset). It is used by
# _draw_river_list for the identification of which river is already computed and cached.
func _points_to_cache_key(points: Array) -> String:
    var sb := PackedStringArray()
    sb.resize(points.size())
    for i in range(points.size()):
        var p = points[i]
        # We round to 0.1, so that the key is stable and compact - the initial
        # vertices of the rivers are deterministic, therefore there will be no re-smoothing.
        sb[i] = "%d_%d" % [roundi(p.x * 10.0), roundi(p.y * 10.0)]
    return "^".join(sb)

func _chaikin_smooth(points: PackedVector2Array, iterations: int) -> PackedVector2Array:
    if points.size() < 2:
        return points
    var current = points
    for _it in range(iterations):
        var next_pts = PackedVector2Array()
        next_pts.append(current[0])
        for j in range(current.size() - 1):
            var p0 = current[j]
            var p1 = current[j + 1]
            var q = p0 * 0.75 + p1 * 0.25
            var r = p0 * 0.25 + p1 * 0.75
            next_pts.append(q)
            next_pts.append(r)
        next_pts.append(current[-1])
        current = next_pts
    return current
