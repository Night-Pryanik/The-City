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
# The shape of the roads. A road is drawn as a CHAIN of its connected segments: the turns are
# rounded and the runs are gently wandered, while the ends of a chain stay exactly at the hex
# centres, so the roads of different levels, networks and plans still meet. The wander is
# derived from the hex coordinates, so the same network always looks the same.
const ROAD_WANDER = 0.26        # the lateral drift of a bend, in hex radii
const ROAD_RUN_WAVE = 0.15      # the lateral wave of a run, in hex radii
const ROAD_TURN_RADIUS = 1.0    # the radius limit of a rounded turn, in hex radii
const ROAD_TURN_TRIM = 0.46     # the share of the shorter neighbouring run trimmed by a turn
const ROAD_SAMPLE_STEP = 24.0   # the distance between the samples of a run, px
const ROAD_SAMPLE_ANGLE = 12.0  # the turn between the samples of a curve, degrees
# At a junction the roads are continued into each other, the most opposite pair first. A pair
# whose directions are closer than this is not joined: two roads leaving the same hex almost
# in one direction have no turn between them, only a hairpin.
const ROAD_JUNCTION_MAX_DOT = 0.5
# A road that has no continuation through a junction is blended into the road it meets: the
# blend takes this share of the last run and leans towards the other road by this share of it.
const ROAD_MERGE_SHARE = 0.4
const ROAD_MERGE_STRENGTH = 0.55
# A road meeting the through road of a junction at a wider angle than this is not blended into
# it: such a merge would have to turn almost in place and reads as a squiggle. It ends at the
# junction centre, which the through road passes through, so the roads meet as a plain T.
const ROAD_MERGE_MIN_DOT = 0.5
# The level of a road set which has no levels: the network of a town is drawn with the default
# style (see _collect_road_draw_sets).
const NO_ROAD_LEVEL = -1
# The radius of the icon markers drawn on top of the hex: a drop of fresh water by
# an improvement and a trade icon over a connected town. It is set by ONE
# constant, so that both markers are guaranteed to be of the same size.
const MARKER_ICON_RADIUS = 6.0
# The colour of the markers on the hex (the drop of water and the trade icon).
const MARKER_ICON_COLOR = Color(0.45, 0.8, 1.0)
# The marker of an outpost — an improvement outside the Region (the technology "Emporia").
const OUTPOST_FLAG_ICON = "outpost_flag.svg"

# The row/col deltas of the odd-r neighbours (the same grid as HexUtils.get_neighbors_odd_r),
# inlined so that the fog test of a river point does not allocate a dictionary per neighbour.
const RIVER_HEX_EVEN_NEIGHBORS := [[0, -1], [0, 1], [-1, -1], [-1, 0], [1, -1], [1, 0]]
const RIVER_HEX_ODD_NEIGHBORS := [[0, -1], [0, 1], [-1, 0], [-1, 1], [1, 0], [1, 1]]

var tile_data = []
# A local texture cache for the drawing of the map (a hot path: an access for
# every hex on every frame). The paths and the loading are given by IconRegistry - it has
# no index of its own for the renderer any more.
var icon_textures = {}

# A reference to the main node for the access to build_manager, CityData, the map bounds
# and the camera (the drawn area depends on the scrollable range).
var main_map: Node

# The smoothed (meandering) points of the rivers in the world coordinates. The smoothing
# (_generate_natural_river + _chaikin_smooth) is expensive and the geometry does not depend on
# the view, so it is computed once per river. The cache key is a compact serialization of the
# coordinates of the river.
var _river_smooth_cache: Dictionary = {}

# The drawn runs of the rivers in the world coordinates, keyed by _river_index: the polylines
# clipped by the drawn area and split by the fog of war. The map is drawn in world coordinates
# and pans by the transform of this node, therefore the runs stay valid while the map is
# scrolled or zoomed. The cache is dropped when the fog of war changes
# (see invalidate_town_influence_cache) or when the drawn area outgrows _river_cache_rect
# (a zoom-out gesture, a wider Region).
var _river_frame_cache: Dictionary = {}
var _river_cache_rect: Rect2 = Rect2()
# Counts the actual rebuilds of the river geometry; the river rendering test relies on it.
var _river_frame_rebuilds: int = 0

# Counts the actual repaints of the map. The map is redrawn on demand, so a state change
# that is not followed by queue_redraw() stays on the screen until the next mouse move;
# the test of the road-capacity warning relies on this counter.
var draw_calls: int = 0

# The accumulators of the current row of the hex pass (see _draw). The fog fill is a
# triangle list and the hex borders are a segment list; both are flushed once per row.
var _row_fog_triangles := PackedVector2Array()
var _row_fog_indices := PackedInt32Array()
var _row_fog_colors := PackedColorArray()
var _row_border_points := PackedVector2Array()

const FOG_COLOR := Color(0, 0, 0, 0.5)

func _begin_hex_row() -> void:
    _row_fog_triangles.clear()
    _row_fog_indices.clear()
    _row_fog_colors.clear()
    _row_border_points.clear()

func _flush_hex_row() -> void:
    if not _row_fog_triangles.is_empty():
        RenderingServer.canvas_item_add_triangle_array(
            get_canvas_item(), _row_fog_indices, _row_fog_triangles, _row_fog_colors)
    if not _row_border_points.is_empty():
        draw_multiline(_row_border_points, Color.WHITE, 2.0, true)

# The fill of a hexagon as a triangle fan. The fan is appended to the row batch instead of
# being drawn on its own: one draw_colored_polygon per fogged hex costs ~30 us to record,
# while the batched triangle list of a whole row costs about the same.
func _append_hex_fill(vertices: PackedVector2Array, color: Color) -> void:
    var base := _row_fog_triangles.size()
    for k in range(1, vertices.size() - 1):
        _row_fog_indices.append(base)
        _row_fog_indices.append(base + k)
        _row_fog_indices.append(base + k + 1)
    _row_fog_triangles.append_array(vertices)
    for _i in vertices.size():
        _row_fog_colors.append(color)

func _append_hex_outline(vertices: PackedVector2Array) -> void:
    var count := vertices.size()
    for k in count:
        _row_border_points.append(vertices[k])
        _row_border_points.append(vertices[(k + 1) % count])

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
    # The rings of the towns could have changed (a new map / a load of a save):
    # we reset the cache of their render - it will be lazily rebuilt from the next frame.
    invalidate_town_influence_cache()

# Returns the size of the viewport in the pixels. In the editor get_viewport_rect()
# is unavailable (there is no window of the game) - we use a fallback value, as before.
func _get_viewport_size() -> Vector2:
    if Engine.is_editor_hint():
        return Vector2(1152, 768)
    return get_viewport_rect().size

# The hexes the map is drawn for. The drawing is recorded in world coordinates and the map
# pans and zooms by the transform of this node, so the range cannot follow the cursor: it
# has to cover every position the scroll clamp allows at the zoom the drawing was made for.
# That is exactly main_map.get_scout_reach_bounds() — the scrollable area of the map.
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
func _get_draw_hex_range() -> Dictionary:
    if main_map == null:
        return {"row_start": 0, "row_end": 0, "col_start": 0, "col_end": 0}
    return main_map.get_scout_reach_bounds()

# The rectangle of the world covered by the drawing: the hex range grown by the hex radius,
# used to cull the geometry which is not bound to the hex grid (the roads, the rivers).
func _get_draw_rect() -> Rect2:
    var hex_range: Dictionary = _get_draw_hex_range()
    var radius: float = main_map.HEX_RADIUS
    var x_spacing := radius * sqrt(3.0)
    var y_spacing := radius * 1.5
    var left: float = float(hex_range.col_start) * x_spacing - radius * 2.0
    var top: float = float(hex_range.row_start) * y_spacing - radius * 2.0
    var right: float = (float(hex_range.col_end) + 1.0) * x_spacing + radius * 2.0
    var bottom: float = (float(hex_range.row_end) + 1.0) * y_spacing + radius * 3.0
    return Rect2(left, top, right - left, bottom - top)

# The part of the world the screen currently shows, in world coordinates: the transform of
# this node maps it to the screen. Only the layers that are redrawn while the map moves
# (the progress bars) cull by it; the recorded layers have to cover the whole scrollable area.
func _get_screen_rect() -> Rect2:
    if main_map == null:
        return Rect2(Vector2.ZERO, _get_viewport_size())
    return main_map.get_draw_screen_rect(_get_viewport_size())

# Checks whether the rectangle (in world coordinates) intersects the drawn area.
func _is_rect_visible(rect: Rect2) -> bool:
    return rect.intersects(_get_draw_rect())

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
    # The marker of an outpost is not referenced by any data file: the hex carries an ordinary
    # improvement, and the flag is drawn by the renderer alone.
    _cache_icon(OUTPOST_FLAG_ICON)
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
    draw_calls += 1
    # Nothing to draw yet: the node has not been initialized, or the world is still
    # being generated (the stages of the generation yield frames — a half-built map
    # must not flash behind the loading screen of a new game).
    if main_map == null or main_map.world_generating:
        return

    # The drawing is in WORLD coordinates; the view is applied by the transform of this node.
    # A scroll therefore does not re-record anything: the recorded commands are replayed
    # where the transform puts them. This is why the range is the whole scrollable area
    # (see _get_draw_hex_range) and not the screen rectangle.
    var visible_range = _get_draw_hex_range()

    # PHASE 1: The hexes of the drawn area. The hexes of the Region - in detail, the
    # unexplored hexes beyond its limits (the fog of war) are not drawn at all (see
    # _draw_hex). The scouted hexes outside the Region are drawn darkened: they can be
    # selected and scouts sent there - but only after the study of Cartography.
    #
    # The fog fill and the hex borders are uniform in colour and hex-shaped, so they are
    # batched PER ROW: the screen order stays row-major (a later row still covers the
    # overflow of the icons of the previous one), while the number of draw commands drops
    # from one per hex to two per row. This matters twice: the commands are replayed every
    # frame, and the whole map is re-recorded on structural changes.
    for row in range(visible_range.row_start, visible_range.row_end + 1):
        _begin_hex_row()
        for col in range(visible_range.col_start, visible_range.col_end + 1):
            _draw_hex(row, col)
        _flush_hex_row()

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
    _draw_town_influence(visible_range)
    # PHASE 1.7.1: The borders of the rings of the towns - each with its own colour. They are drawn
    # right after the fill (over it, over the terrain), but before the roads/rivers/
    # icons: the outline must be visible, without covering the contents of the hexes.
    _draw_town_influence_borders(visible_range)

    # PHASE 2: We draw the roads (BEFORE the icons of the resources and the improvements) - the networks of the city
    # of the player and the networks of the towns (see _draw_all_roads)
    _draw_all_roads()

    # PHASE 2.75: We draw the rivers
    _draw_rivers()

    # PHASE 2.5: The fill of the scouted hexes outside the Region. The chunk under the cursor
    # is a separate layer (see map_highlight_layer.gd): the hover changes far more often than
    # the rest of the map, and re-recording the whole map for it would stall the pan.
    _draw_exploration_highlights()

    # PHASE 3: We draw the icons of the resources, the improvements and the other overlays
    for row in range(visible_range.row_start, visible_range.row_end + 1):
        for col in range(visible_range.col_start, visible_range.col_end + 1):
            _draw_hex_overlays(row, col)

    # PHASE 4: We draw the city at the end
    var city_center = HexUtils.hex_center(main_map.city_row, main_map.city_col, main_map.HEX_RADIUS)
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
    var tile = tile_data[row][col]
    var in_influence = tile.get("in_influence", false)
    var is_explored = tile.get("is_explored", false)

    # A real fog of war: an unexplored hex beyond the limits of the Region
    # is not drawn at all - only the dark background of the canvas is visible. After the scouting
    # (`is_explored = true`) the hex is drawn as the ordinary one again: the fog
    # "opens up" and the scouting has a visual effect.
    #
    # The test comes BEFORE the geometry on purpose: a zoomed-out map spans far more hexes
    # than it draws, and building the vertices of every skipped one costs more than the
    # visible layer itself.
    if not in_influence and not is_explored and not main_map.is_valid_hex(row, col):
        return

    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)

    var terrain_color = Color.BLACK
    var terrain = tile.terrain
    var terrain_icon_name = tile.get("terrain_icon", "")
    if row == main_map.city_row and col == main_map.city_col:
        if GameData.terrains.has(terrain):
            var t = GameData.terrains[terrain]
            var c = t.get("color", [0, 0, 0])
            terrain_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
        draw_colored_polygon(vertices, terrain_color)
        if main_map.show_hex_borders:
            _append_hex_outline(vertices)
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
        _append_hex_fill(vertices, FOG_COLOR)

    if main_map.show_hex_borders:
        _append_hex_outline(vertices)

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
    # The river geometry is clipped by the fog of war (see _collect_river_segments), so a change
    # of the fog makes it stale too. This is the single hook of the fog changes (the scouting,
    # the claiming, the transition to the next era, the debug reveal), therefore the river cache
    # is dropped here instead of at every call site.
    _river_frame_cache.clear()
    # The highlighting depends on the fog as well (the chunk and its style), and it is a separate
    # layer that the redraw of the map does not touch.
    var layer := get_node_or_null("HighlightLayer")
    if layer:
        layer.queue_redraw()

func _ensure_town_influence_cache(_visible_range: Dictionary) -> void:
    if main_map == null:
        return
    # The Region expands on a change of the epoch - the cache for the old borders is invalid.
    var region_changed: bool = _cache_region_start_row != main_map.region_start_row \
            or _cache_region_end_row != main_map.region_end_row \
            or _cache_region_start_col != main_map.region_start_col \
            or _cache_region_end_col != main_map.region_end_col
    if _town_cache_built_version == _town_cache_version and not region_changed:
        return
    _town_cache_built_version = _town_cache_version
    _cache_region_start_row = main_map.region_start_row
    _cache_region_end_row = main_map.region_end_row
    _cache_region_start_col = main_map.region_start_col
    _cache_region_end_col = main_map.region_end_col

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
            var c: Vector2 = HexUtils.hex_center(row, col, radius)
            if not seen.has(key):
                seen[key] = true
                _influence_fill_centers.append({"cx": c.x, "cy": c.y,
                        "row": row, "col": col,
                    "cr": bc[0], "cg": bc[1], "cb": bc[2],
                    "ca": TOWN_INFLUENCE_FILL_ALPHA})
    # The border: the edges between the ring of a town and its surroundings.
            # The six vertices are computed ONCE for the hex: HexUtils.hex_vertex() recomputes
            # the centre and allocates the whole array on every call, and an edge needs eight
            # of them (six for the distances + two for the answer).
            var verts: PackedVector2Array = HexUtils.hex_vertices(c.x, c.y, radius)
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
                var near1 := 0
                var near2 := 1
                var dist1 := INF
                var dist2 := INF
                for vi in range(6):
                    var dist: float = verts[vi].distance_squared_to(nb_center)
                    if dist < dist1:
                        dist2 = dist1
                        near2 = near1
                        dist1 = dist
                        near1 = vi
                    elif dist < dist2:
                        dist2 = dist
                        near2 = vi
                var p1: Vector2 = verts[near1]
                var p2: Vector2 = verts[near2]
                _influence_border_segments.append({"p1x": p1.x, "p1y": p1.y,
                        "p2x": p2.x, "p2y": p2.y,
                        "cr": bc[0], "cg": bc[1], "cb": bc[2], "ca": bc[3],
                        "row": row, "col": col})

    # --- Step 2: a pre-render of the fill into one texture of the Region ---
    _build_town_fill_texture()

    # A pre-render of the fill of the influence rings into ONE RGBA texture, which covers the whole
    # area of the fill. The texture is built in the world pixels: the map itself is recorded in
    # world coordinates, so the fill is one draw_texture_rect at the recorded position. The Godot
    # class Image has no vector primitives (only fill/fill_rect/set_pixel), therefore the hexes
    # are filled row by row through fill_rect by the table of the half widths (a pointy-top hex
    # with the flat sides has vertical left and right borders).
    #
    # If the area of the fill is too large for one texture (the limit of 4096 px) -
    # we leave _influence_fill_texture = null, and _draw_town_influence draws
    # the fill by the cached polygons (without the duplicates and the trigonometry).
    
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
func _get_region_visible_range(visible_range: Dictionary) -> Dictionary:
    return {
        "row_start": max(visible_range.row_start, main_map.region_start_row),
        "row_end": min(visible_range.row_end, main_map.region_end_row),
        "col_start": max(visible_range.col_start, main_map.region_start_col),
        "col_end": min(visible_range.col_end, main_map.region_end_col)
    }

# Draws the influence rings of all the towns (PHASE 1.7). By the agreement - only
# for the hexes inside the REGION (see _get_region_visible_range): behind the fog of war
# the rings are not drawn, so as not to "give away" the unexplored territory, although
# the fog itself is now drawn and is available for the scouting.
# One drawing = one draw_texture_rect (the texture is cut by Ring+Region).
# The fallback to the polygons - only in the editor or with too large a Region.
func _draw_town_influence(visible_range: Dictionary) -> void:
    if main_map == null:
        return
    var radius: float = main_map.HEX_RADIUS
    _ensure_town_influence_cache(visible_range)
    if _influence_fill_texture != null:
        draw_texture_rect(_influence_fill_texture, Rect2(
                _influence_texture_origin.x,
                _influence_texture_origin.y,
                _influence_texture_size.x,
                _influence_texture_size.y), false, Color(1, 1, 1, 1))
        return
    # Fallback: the drawing by the hexes (the editor / the Region larger than 4096px).
    var region_visible = _get_region_visible_range(visible_range)
    for h in _influence_fill_centers:
        var row: int = int(h.row)
        var col: int = int(h.col)
        # The visibility (as before): only the Ring + the Region.
        if row < region_visible.row_start or row > region_visible.row_end \
                or col < region_visible.col_start or col > region_visible.col_end:
            continue
        var cx: float = float(h.cx)
        var cy: float = float(h.cy)
        if not _is_rect_visible(Rect2(cx - radius, cy - radius, radius * 2, radius * 2)):
            continue
        var vertices = HexUtils.hex_vertices(cx, cy, radius)
        var fill_color := Color(h.cr, h.cg, h.cb, h.ca)
        draw_colored_polygon(vertices, fill_color)

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
    # world coordinates. The drawing only culls them by the drawn area and calls draw_line:
    # without the trigonometry and the allocations of the dictionaries.
    #
    # The visibility — the same as that of the fill: only the Ring + the Region. The clipping of the rings on
    # the starting Region is already applied to the data (in town_manager), so the foreign
    # towns in the 1st epoch do not reveal their outlines.
func _draw_town_influence_borders(visible_range: Dictionary) -> void:
    if main_map == null:
        return
    _ensure_town_influence_cache(visible_range)
    var region_visible = _get_region_visible_range(visible_range)
    for seg in _influence_border_segments:
        var row: int = int(seg.row)
        var col: int = int(seg.col)
        # The visibility (as in the fill): only the Ring + the Region.
        if row < region_visible.row_start or row > region_visible.row_end \
                or col < region_visible.col_start or col > region_visible.col_end:
            continue
        var p1 := Vector2(float(seg.p1x), float(seg.p1y))
        var p2 := Vector2(float(seg.p2x), float(seg.p2y))
        # The culling of a segment by its bounding box against the drawn area.
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
    var tile = tile_data[row][col]
    var in_influence = tile.get("in_influence", false)
    var is_explored = tile.get("is_explored", false)

    if row == main_map.city_row and col == main_map.city_col:
        return

    # A real fog of war: an unexplored hex beyond the Region - no
    # overlays (the resources, the icons of the improvements, the towns, the conflicts of tech_reveal).
    # `_draw_hex` has already refused to draw it; here we also return, so as not to
    # accidentally "give away" the contents.
    # The test comes before the geometry: see _draw_hex.
    if not in_influence and not is_explored and not main_map.is_valid_hex(row, col):
        return

    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)

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

    # An improvement is drawn inside the Influence Ring and on an outpost hex outside the
    # Region (the technology "Emporia") — the building itself looks the same, its flag below
    # tells them apart. The icon drawn here is always the inactive one: a worker on the hex
    # lights it up from improvement_state_layer.gd, so that an assignment repaints a handful
    # of icons instead of re-recording the whole map.
    var imp_icon: Dictionary = get_improvement_icon_geometry(row, col)
    if not imp_icon.is_empty():
        var imp_icon_size: float = imp_icon["size"]
        var icon_pos: Vector2 = imp_icon["pos"]
        # The infrastructure improvements (no_worker, for example a harbor or a canal)
        # are not tied to a worker, and the decorative improvements of the towns
        # intentionally have none: both are always drawn in the full colour.
        var draw_active: bool = GameData.is_no_worker_improvement(tile.improvement) \
                or bool(tile.get("decorative", false))
        draw_improvement_icon(self, imp_icon, draw_active)

        # A drop of fresh water next to the icon of the improvement. We show it for
        # any improvement which has access to the water (direct or chain).
        # The types differ visually:
        #   direct - a filled blue drop (as it was before for the farms);
        #   chain  - a contour (an outline) of a muted colour, the water by the chain.
        var water_access := MapHelpers.get_hex_water_access(row, col, tile_data, main_map.map_rows, main_map.map_cols)
        if water_access != "":
            # The position of the drop depends on the size of the icon of the improvement:
            #   small (IMPROVEMENT_ICON_SIZE) - to the right of the icon;
            #   large (RESOURCE_ICON_SIZE, a hex without a resource) - above the icon:
            #   to the right the drop rests against the face of the hex (the half width of the hex
            #   is ~47.6px at HEX_RADIUS = 55), and below it the progress bars interfere.
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

        # The road-capacity warning triangle is drawn by improvement_state_layer.gd too:
        # its flags flip in the production tick, far more often than the map itself changes.

        # The flag of an outpost: an improvement of the city on foreign land. It stands in the
        # upper LEFT corner of the hex — the upper right one is occupied by the warning
        # triangle of a tech_reveal conflict.
        if _is_outpost_hex(row, col):
            _draw_outpost_flag(center)

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

# The geometry of the icon of the improvement on the hex: the centre of the hex, the centre and
# the size of the icon, its texture or fallback colour. The gates that hide the icon entirely
# (no improvement, the city hex, the fog of war, a foreign hex) are applied here too, so the
# base pass and the state layer cannot disagree about what stands on the hex.
# Without a resource the improvement is the only "item" on the hex (an irrigation canal, a
# forest plot, a decorative improvement of a town): it takes the place and the size of the
# icon of the resource. With a resource it stays a small marker above the resource icon.
func get_improvement_icon_geometry(row: int, col: int) -> Dictionary:
    var tile = tile_data[row][col]
    if tile.improvement == null:
        return {}
    if row == main_map.city_row and col == main_map.city_col:
        return {}
    var in_influence: bool = tile.get("in_influence", false)
    if not in_influence and not _is_outpost_hex(row, col):
        return {}
    if not in_influence and not bool(tile.get("is_explored", false)) and not main_map.is_valid_hex(row, col):
        return {}
    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    var has_resource: bool = MapHelpers.get_effective_resource(tile) != ""
    var icon_pos = center
    var icon_size: float = IMPROVEMENT_ICON_SIZE
    # The radius of the stub circle, if the texture of the icon is not found. The large icon
    # takes the same formula as the stub of the resource, so the two look alike.
    var fallback_radius: float = IMPROVEMENT_ICON_SIZE / 2.5
    if has_resource:
        icon_pos = Vector2(center.x, center.y - main_map.HEX_RADIUS * 0.75)
    else:
        icon_size = RESOURCE_ICON_SIZE
        fallback_radius = RESOURCE_ICON_SIZE / 3.0
    var imp_data: Dictionary = GameData.improvements.get(tile.improvement, {})
    var texture: Texture2D = null
    var icon_name: String = imp_data.get("icon", "")
    if icon_name != "" and icon_textures.has(icon_name):
        texture = icon_textures[icon_name]
    var color := Color.WHITE
    var has_color := false
    if imp_data.has("color"):
        var c = imp_data["color"]
        color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
        has_color = true
    return {
        "center": center,
        "pos": icon_pos,
        "size": icon_size,
        "radius": fallback_radius,
        "texture": texture,
        "color": color,
        "has_color": has_color,
    }

# Draws the icon of an improvement by the geometry above into `target`: the base renderer or the
# state layer. An inactive icon (no worker on the hex) is dimmed; the active one keeps its colour.
static func draw_improvement_icon(target: CanvasItem, icon: Dictionary, active: bool) -> void:
    var pos: Vector2 = icon["pos"]
    var icon_size: float = icon["size"]
    var texture: Texture2D = icon["texture"]
    if texture != null:
        var modulate := Color.WHITE if active else Color(0.5, 0.5, 0.5)
        target.draw_texture_rect(
                texture,
                Rect2(pos.x - icon_size / 2.0, pos.y - icon_size / 2.0, icon_size, icon_size),
                false, modulate)
    elif icon["has_color"]:
        var color: Color = icon["color"] if active else Color(0.5, 0.5, 0.5)
        target.draw_circle(pos, icon["radius"], color)

# A small "!" triangle over an improvement whose road cannot carry everything it produces, or
# which has no road at all: in both cases the goods do not reach the city. It is drawn to the
# right of the drop of water (or of where the drop would be), so the two marks are read
# together. The layer draws it, because the flags behind it flip in the production tick.
static func draw_road_warning(target: CanvasItem, icon: Dictionary) -> void:
    var icon_pos: Vector2 = icon["pos"]
    var icon_size: float = icon["size"]
    var drop_offset := Vector2(icon_size * 0.5 + 6, 0)
    if icon_size > IMPROVEMENT_ICON_SIZE:
        drop_offset = Vector2(0, -(icon_size * 0.5 + 6))
    var pos := icon_pos + drop_offset + Vector2(MARKER_ICON_RADIUS * 2.0 + 4.0, 0)
    draw_warning_triangle_on(target, pos, 13.0)

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
func _draw_tech_reveal_warning(center: Vector2):
    # The centre of the triangle is in the upper right corner of the hex, a bit closer to the centre,
    # so that the badge does not stick out of the hex and is not lost on the background of the neighbours.
    _draw_warning_triangle(
            Vector2(center.x + main_map.HEX_RADIUS * 0.55,
                    center.y - main_map.HEX_RADIUS * 0.55),
            18.0)

# A filled red triangle with a white outline and a "!" in the middle. It is shared by the
# tech_reveal conflict, the road-capacity warning and the state layer, so all badges look the
# same and cannot drift apart. Without external resources and fonts (draw_string on the
# fallback font).
static func draw_warning_triangle_on(target: CanvasItem, pos: Vector2, tri_size: float) -> void:
    # The vertices of an equilateral triangle directed up.
    var pts = PackedVector2Array()
    pts.append(Vector2(pos.x, pos.y - tri_size * 0.6))
    pts.append(Vector2(pos.x - tri_size * 0.55, pos.y + tri_size * 0.45))
    pts.append(Vector2(pos.x + tri_size * 0.55, pos.y + tri_size * 0.45))
    target.draw_colored_polygon(pts, Color(0.85, 0.15, 0.15, 0.95))
    # A white outline by the same contour.
    var border = PackedVector2Array()
    border.append_array(pts)
    border.append(pts[0])
    target.draw_polyline(border, Color.WHITE, 1.5, true)
    # The "!" - we draw it as a short column and a dot under it. We use
    # the standard font through draw_string, so as not to depend on the assets.
    var font = ThemeDB.fallback_font
    if font == null:
        return
    var font_size := int(round(tri_size * 0.72))
    var text := "!"
    var text_size = font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
    var text_pos = Vector2(pos.x - text_size.x / 2.0, pos.y + text_size.y / 2.0 - 1)
    target.draw_string(font, text_pos, text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE)

func _draw_warning_triangle(pos: Vector2, tri_size: float) -> void:
    draw_warning_triangle_on(self, pos, tri_size)

# An improvement outside the Region — an outpost of the city (the technology "Emporia").
# The status is derived from the tile by main_map, so that the renderer, the tooltip and the
# panel do not decide it three times in their own way.
func _is_outpost_hex(row: int, col: int) -> bool:
    if main_map == null or not main_map.has_method("is_outpost_improvement"):
        return false
    return main_map.is_outpost_improvement(row, col)

# The flag of an outpost, in the upper left corner of the hex — the upper right one is
# occupied by the warning triangle of a tech_reveal conflict. The marker is of the same class
# as the drop of water and the trade badge, but it is an icon and not a procedural drawing:
# the same flag stands in the list of the effects of the technology that opens outposts.
func _draw_outpost_flag(center: Vector2) -> void:
    if not icon_textures.has(OUTPOST_FLAG_ICON):
        return
    var size := MARKER_ICON_RADIUS * 2.6
    var pos := center + Vector2(-main_map.HEX_RADIUS * 0.55, -main_map.HEX_RADIUS * 0.55)
    draw_texture_rect(icon_textures[OUTPOST_FLAG_ICON],
            Rect2(pos.x - size / 2.0, pos.y - size / 2.0, size, size), false)

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
# The hexes where the drawn networks branch, collected over all of them at once. The roads
# belonging to the different networks, levels and plans meet there, so their guide points are
# kept exactly at the hex centre instead of being wandered aside.
var _road_junction_hexes: Dictionary = {}

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

# The sets the roads are drawn from, in the drawing order (see _collect_road_draw_sets).
var _road_draw_sets: Array = []

func _draw_all_roads():
    if main_map == null or not main_map.has_method("get"):
        return
    if not main_map.has_node("RoadManager"):
        return

    var road_manager = main_map.get_node("RoadManager")

    var city_segments: Dictionary = road_manager.get_all_road_segments()
    var link_segments: Dictionary = road_manager.get_all_town_link_segments()
    var town_segments: Dictionary = road_manager.get_all_town_road_segments()
    _road_junction_hexes = _collect_road_junction_hexes(city_segments, town_segments,
            link_segments)

    # PHASE 2a-2c: the roads of the networks of the city and of the towns, by levels
    # (see _collect_road_draw_sets). The sets are kept: the highlighting of the route is cut out
    # of the SAME lines - a subset of a road would be walked and paired differently than the
    # road itself.
    _road_draw_sets = _collect_road_draw_sets(city_segments, town_segments, link_segments,
            road_manager)
    for entry in _road_draw_sets:
        _draw_road_set(entry)

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
    for polyline in _route_polylines():
        draw_polyline(polyline, ROUTE_COLOR, ROUTE_WIDTH, true)

# The polylines of the highlighting of the route: the pieces of the ROAD's own lines which lie
# on the route, cut out of them by the spans they were drawn for. A line of its own would have
# to be walked, paired and split into the chains on its own as well, and a subset of a road is
# not walked, paired or split like the whole road: the highlight would drift aside by the
# lateral wander of the hexes, cut the corners at the junctions and run straight through the
# level borders the road breaks at.
func _route_polylines() -> Array:
    if _route_segments.is_empty():
        return []
    var visible_range: Dictionary = {}
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
            visible_range[segment_key] = true
    if visible_range.is_empty():
        return []
    var polylines: Array = []
    var road_manager = main_map.get_node("RoadManager")
    for entry in _road_draw_sets:
        for piece in _road_chain_pieces(entry["segments"], bool(entry["hide_in_fog"]),
                main_map.HEX_RADIUS):
            _append_route_slices(polylines, piece, visible_range, road_manager)
    return polylines

# The pieces of one drawn route which cover the segments of the highlight. The segments of the
# route run one after another, therefore its points are taken in one range per run of them.
func _append_route_slices(polylines: Array, piece: Dictionary, route: Dictionary,
        road_manager) -> void:
    var points: PackedVector2Array = piece["points"]
    var spans: PackedInt32Array = piece["spans"]
    var chain: Array = piece["chain"]
    var on_route: Array = []
    for i in range(chain.size() - 1):
        var a: Vector2i = chain[i]
        var b: Vector2i = chain[i + 1]
        on_route.append(route.has(road_manager.get_road_segment_key(a.x, a.y, b.x, b.y)))
    var start := -1
    var finish := -1
    for i in range(spans.size() + 1):
        var drawn := false
        if i < spans.size():
            var span := int(spans[i])
            if span >= 0 and span < on_route.size():
                drawn = bool(on_route[span])
        if drawn:
            if start < 0:
                start = i
            finish = i
        elif start >= 0:
            if finish > start:
                polylines.append(points.slice(start, finish + 1))
            start = -1

# The "ghost" of an unfinished project. A separate set of the segments, and not a common one with
# the preview: the preview lives while the panel is open, the ghost of the project - while the build
# is going, and it appears already AFTER the confirmation.
func _draw_project_ghost() -> void:
    if _project_ghost_segments.is_empty():
        return
    var visible_range: Dictionary = {}
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
            visible_range[segment_key] = true
    if visible_range.is_empty():
        return
    _draw_road_segments(visible_range, false, ROAD_PREVIEW_HALO_COLOR, ROAD_PREVIEW_HALO_WIDTH)
    _draw_road_segments(visible_range, false, ROAD_PREVIEW_COLOR, ROAD_PREVIEW_WIDTH)

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

# The sets of the segments the roads of the map consist of, in the drawing order. Each set is
# drawn as a chain of its own, therefore the composition of the sets IS the road geometry: the
# level border and the border between the networks split a chain, and the pairing of the roads
# at a junction is looked for within one set. The highlighting of the route is drawn from the
# same sets, so a subset of a road bends exactly like the road.
#
# PHASE 2a: the roads of the CITY of the player, by levels. They have no visibility gates: they
# always lie on their own claimed territory, where there is no fog of war at all. An exception
# is the roads CONNECTING the city with a town (PHASE 2c): the player builds them over the
# scouted, but not claimed land, therefore here they are skipped and drawn only in PHASE 2c,
# where the fog gate applies. The colour and the thickness of a level come from
# data/roads.json (the fields color/width), so an improved road is visible on the map at once.
#
# PHASE 2b: the roads of the TOWNS - a separate network, drawn with the same style (see
# road_manager.rebuild_town_roads: the network of each town goes from its centre to the
# improvements in the influence ring and is not connected with the roads of the city). The
# visibility is exactly the same as that of the fill of the rings: see are_town_roads_visible().
# The segments already covered by the player's network are skipped: where the player's road to
# the town runs along the town's own trail, the road of the CHOSEN level is drawn, and the
# town's trail must not be drawn over the highway.
#
# PHASE 2c: the roads connecting the city with the towns (the special action "Build a road",
# clicked on the hex of a town). These are the roads of the NETWORK of the CITY, and they go
# over the scouted (but not claimed) land - therefore their visibility gates are the same as
# those of the roads of the towns. The level is taken from the network of the city:
# town_link_segments stores only the flag "this segment leads to a town", the level lives in
# road_segments.
func _collect_road_draw_sets(city_segments: Dictionary, town_segments: Dictionary,
        link_segments: Dictionary, road_manager) -> Array:
    var sets: Array = []

    var plain_city: Dictionary = {}
    for key in city_segments.keys():
        if not link_segments.has(key):
            plain_city[key] = city_segments[key]
    _append_road_level_sets(sets, plain_city, false)

    if are_town_roads_visible():
        var town_only: Dictionary = {}
        for key in town_segments.keys():
            if not city_segments.has(key):
                town_only[key] = true
        if not town_only.is_empty():
            sets.append({"segments": town_only, "hide_in_fog": true,
                    "level": NO_ROAD_LEVEL})

    var link_levels: Dictionary = {}
    for key in link_segments.keys():
        link_levels[key] = int(city_segments.get(key, road_manager.DEFAULT_ROAD_LEVEL))
    _append_road_level_sets(sets, link_levels, true)

    return sets

# The segments of one network split by level, in the order of the levels. The set of the
# segments stores the level BY VALUE (see road_manager.road_segments), therefore the grouping
# is one pass over the dictionary. A level which is not in the data is drawn with the default
# style: this is an error of the data, and not a reason to silently not draw the road.
func _append_road_level_sets(sets: Array, segments: Dictionary, hide_in_fog: bool) -> void:
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
        sets.append({"segments": by_level[level], "hide_in_fog": hide_in_fog, "level": int(level)})

# Draws one set of the roads with the style of its level.
func _draw_road_set(entry: Dictionary) -> void:
    var color := ROAD_COLOR
    var width := ROAD_WIDTH
    var level := int(entry.get("level", NO_ROAD_LEVEL))
    if level != NO_ROAD_LEVEL:
        var road: Dictionary = GameData.get_road_by_level(level)
        var rgb: Array = road.get("color", [])
        if rgb is Array and rgb.size() == 3:
            color = Color(float(rgb[0]) / 255.0, float(rgb[1]) / 255.0,
                    float(rgb[2]) / 255.0)
        width = int(road.get("width", ROAD_WIDTH))
    _draw_road_segments(entry["segments"], bool(entry["hide_in_fog"]), color, width)

# Draws a set of the segments of the roads.
# hide_in_fog is the gate for a segment at least one of whose ends lies in the fog
# of war: such a segment is not drawn (it would give away the contents of the unexplored
# territory). For the roads of the city of the player the gate is off.
# color / width is the style: by default a real road, for the preview its own
# values are passed (see ROAD_PREVIEW_*).
func _draw_road_segments(segments: Dictionary, hide_in_fog: bool,
        color: Color = ROAD_COLOR, width: int = ROAD_WIDTH) -> void:
    for polyline in _road_chain_polylines(segments, hide_in_fog, main_map.HEX_RADIUS):
        draw_polyline(polyline, color, width, true)

# The drawn polylines of a set of the segments: one per route, that is, per run of the segments
# continued into each other. Within the set the routes are continued through the junctions: at a
# hex where three or more segments meet the roads are paired and rounded through the centre, so
# the branches curve into each other instead of running straight into the same point. A route
# that has no continuation bends into the road it meets when it approaches it at a shallow angle
# and ends at the hex centre otherwise, which is what keeps the pieces of the different levels,
# networks and plans joined.
func _road_chain_polylines(segments: Dictionary, hide_in_fog: bool, radius: float) -> Array:
    var polylines: Array = []
    for piece in _road_chain_pieces(segments, hide_in_fog, radius):
        polylines.append(piece["points"])
    return polylines

# The drawn polylines of a set together with the hexes of each route and with the span of the
# route every point belongs to: a point carries the index of the pair (chain[i], chain[i + 1])
# it was drawn for, and the points of a turn between two spans are split between them at the
# hex centre. The highlighting of the route is cut out of these points (see _route_polylines),
# so it has to know which span every point comes from.
func _road_chain_pieces(segments: Dictionary, hide_in_fog: bool, radius: float) -> Array:
    var kept: Array = []
    var links: Dictionary = {}
    for segment_key in segments.keys():
        var ends := _road_segment_ends(segment_key)
        if ends.is_empty():
            continue
        var a: Vector2i = ends[0]
        var b: Vector2i = ends[1]
        if hide_in_fog and not is_town_road_segment_visible(a.x, a.y, b.x, b.y):
            continue
        # The culling of the segments outside the drawn area: they can never be seen,
        # because the scroll clamp does not let the screen there.
        if not _is_rect_visible(_road_segment_rect(a, b, radius)):
            continue
        var index := kept.size()
        kept.append([a, b])
        if not links.has(a):
            links[a] = []
        if not links.has(b):
            links[b] = []
        links[a].append(index)
        links[b].append(index)
    if kept.is_empty():
        return []

    var pairs := _road_junction_pairs(kept, links, radius)
    var merges := _road_junction_tangents(kept, pairs, radius)
    var used: Dictionary = {}
    var chains: Array = []
    for hex in links.keys():
        var at: Dictionary = pairs.get(hex, {})
        for index in links[hex]:
            if used.has(index) or at.has(index):
                continue
            chains.append(_walk_road_chain(kept, pairs, used, hex, int(index)))
    for index in range(kept.size()):
        # A ring of the roads without any junction: it is walked from an arbitrary segment
        # and closes on itself.
        if not used.has(index):
            chains.append(_walk_road_chain(kept, pairs, used, kept[index][0], index))

    var pieces: Array = []
    for chain in chains:
        if chain.size() < 2:
            continue
        var drawn := _road_chain_points(chain, radius, merges)
        pieces.append({"points": drawn["points"], "spans": drawn["spans"], "chain": chain})
    return pieces

func _road_segment_ends(segment_key) -> Array:
    var parts := str(segment_key).split("|")
    if parts.size() != 2:
        return []
    var start_parts := parts[0].split(",")
    var end_parts := parts[1].split(",")
    if start_parts.size() != 2 or end_parts.size() != 2:
        return []
    return [Vector2i(int(start_parts[0]), int(start_parts[1])),
            Vector2i(int(end_parts[0]), int(end_parts[1]))]

# The continuations of the roads through the hexes of one set. At a hex with two segments the
# road simply goes on. At a junction the segments are paired by their directions, the most
# opposite pair first: the remaining segment of a junction of an odd degree has no continuation
# and the route ends at the hex centre. The pairing is greedy, so the segments of the junction
# are ordered by their hexes: the order of the dictionary of the segments says nothing about the
# geometry, and the same junction has to be paired alike in every order.
func _road_junction_pairs(kept: Array, links: Dictionary, radius: float) -> Dictionary:
    var pairs: Dictionary = {}
    for hex in links.keys():
        var incident: Array = links[hex]
        if incident.size() == 2:
            pairs[hex] = {int(incident[0]): int(incident[1]), int(incident[1]): int(incident[0])}
            continue
        if incident.size() < 3:
            continue
        incident = incident.duplicate()
        incident.sort_custom(func(x, y):
            return _road_hex_is_less(_road_other_end(kept[int(x)], hex),
                    _road_other_end(kept[int(y)], hex)))
        var directions: Array = []
        for index in incident:
            var other := _road_other_end(kept[int(index)], hex)
            directions.append((HexUtils.hex_center(other.x, other.y, radius)
                    - HexUtils.hex_center(hex.x, hex.y, radius)).normalized())
        var free: Array = range(incident.size())
        var at: Dictionary = {}
        while free.size() >= 2:
            var best_i := 0
            var best_j := 1
            var best_dot := 2.0
            for i in range(free.size()):
                for j in range(i + 1, free.size()):
                    var dot: float = directions[free[i]].dot(directions[free[j]])
                    if dot < best_dot:
                        best_dot = dot
                        best_i = i
                        best_j = j
            if best_dot > ROAD_JUNCTION_MAX_DOT:
                break
            var first := int(incident[free[best_i]])
            var second := int(incident[free[best_j]])
            at[first] = second
            at[second] = first
            free.remove_at(maxi(best_i, best_j))
            free.remove_at(mini(best_i, best_j))
        if not at.is_empty():
            pairs[hex] = at
    return pairs

# The directions of the through roads at the junctions: every paired road gives the direction of
# its continuation, and the other roads of the junction blend into it.
func _road_junction_tangents(kept: Array, pairs: Dictionary, radius: float) -> Dictionary:
    var merges: Dictionary = {}
    for hex in pairs.keys():
        var at: Dictionary = pairs[hex]
        var centre := HexUtils.hex_center(hex.x, hex.y, radius)
        var tangents: Array = []
        for index in at.keys():
            var other := int(at[index])
            if other < int(index):
                continue
            var ends_a: Array = kept[int(index)]
            var a: Vector2i = ends_a[1] if ends_a[0] == hex else ends_a[0]
            var ends_b: Array = kept[other]
            var b: Vector2i = ends_b[1] if ends_b[0] == hex else ends_b[0]
            tangents.append((HexUtils.hex_center(b.x, b.y, radius) - centre
                    - (HexUtils.hex_center(a.x, a.y, radius) - centre)).normalized())
        if not tangents.is_empty():
            merges[hex] = tangents
    return merges

# The through direction of the junction at the given hex that the road approaching along
# direction blends into best, or ZERO if the junction has no through road.
func _road_merge_tangent(merges: Dictionary, hex: Vector2i, direction: Vector2) -> Vector2:
    if not merges.has(hex):
        return Vector2.ZERO
    var best := Vector2.ZERO
    var best_alignment := -1.0
    for tangent in merges[hex]:
        var alignment: float = absf(tangent.dot(direction))
        if alignment > best_alignment:
            best_alignment = alignment
            best = tangent
    return best if best.dot(direction) >= 0.0 else -best

# The hexes where any of the drawn networks branches. The networks are looked at together,
# because their roads meet at the junctions of each other.
func _collect_road_junction_hexes(city_segments: Dictionary, town_segments: Dictionary,
        link_segments: Dictionary) -> Dictionary:
    var degree: Dictionary = {}
    _count_road_hexes(degree, city_segments)
    _count_road_hexes(degree, town_segments)
    _count_road_hexes(degree, link_segments)
    var junctions: Dictionary = {}
    for hex in degree.keys():
        if int(degree[hex]) >= 3:
            junctions[hex] = true
    return junctions

func _count_road_hexes(degree: Dictionary, segments: Dictionary) -> void:
    for segment_key in segments.keys():
        var ends := _road_segment_ends(segment_key)
        if ends.is_empty():
            continue
        for hex in ends:
            degree[hex] = int(degree.get(hex, 0)) + 1

func _road_segment_rect(a: Vector2i, b: Vector2i, radius: float) -> Rect2:
    var c1 := HexUtils.hex_center(a.x, a.y, radius)
    var c2 := HexUtils.hex_center(b.x, b.y, radius)
    return Rect2(
        min(c1.x, c2.x) - radius,
        min(c1.y, c2.y) - radius,
        abs(c2.x - c1.x) + radius * 2.0,
        abs(c2.y - c1.y) + radius * 2.0
    )

# The hexes of one route in the order of the walking. The walk goes through a hex along the
# continuation of the road and stops where the road has no continuation.
func _walk_road_chain(kept: Array, pairs: Dictionary, used: Dictionary,
        start: Vector2i, first: int) -> Array:
    var chain: Array = [start]
    var current := start
    var index := first
    while index >= 0:
        used[index] = true
        var ends: Array = kept[index]
        var next_hex: Vector2i = ends[1] if ends[0] == current else ends[0]
        chain.append(next_hex)
        var at: Dictionary = pairs.get(next_hex, {})
        var next_index := -1
        if at.has(index):
            next_index = int(at[index])
        current = next_hex
        index = -1 if next_index < 0 or used.has(next_index) else next_index
    return chain

# The polyline of one route: the runs between the hex centres carry a slight lateral wave,
# the turns are rounded arcs, and the bend of every hex is shifted aside a little. The first
# and the last point are the exact hex centres of the route ends, and so is every junction:
# the pieces of the other networks have to meet the road there. A route that ends at a junction
# bends and joins the road it meets along that road, unless it arrives at a wide angle — then it
# ends at the centre, and the junction reads as a plain T.
#
# The points come with the span of the route each of them was drawn for, so that a part of the
# line can be cut out of it by the segments it covers (see _append_route_slices).
func _road_chain_points(chain: Array, radius: float, merges: Dictionary) -> Dictionary:
    var last := chain.size() - 1
    var guide := PackedVector2Array()
    guide.resize(chain.size())
    for i in range(chain.size()):
        var hex: Vector2i = chain[i]
        var point := HexUtils.hex_center(hex.x, hex.y, radius)
        if i > 0 and i < last and not _road_junction_hexes.has(hex):
            var prev: Vector2i = chain[i - 1]
            var next_hex: Vector2i = chain[i + 1]
            var direction := (HexUtils.hex_center(next_hex.x, next_hex.y, radius)
                    - HexUtils.hex_center(prev.x, prev.y, radius)).normalized()
            point += _road_lateral(direction) * (
                    _road_hex_shift(hex.x, hex.y) * radius * ROAD_WANDER)
        guide[i] = point

    var trims := PackedFloat32Array()
    trims.resize(chain.size())
    for i in range(1, last):
        var shorter := minf(guide[i].distance_to(guide[i - 1]),
                guide[i].distance_to(guide[i + 1]))
        trims[i] = minf(shorter * ROAD_TURN_TRIM, radius * ROAD_TURN_RADIUS)

    var runs: Array = []
    for i in range(last):
        var direction := (guide[i + 1] - guide[i]).normalized()
        runs.append([
            guide[i] + direction * trims[i],
            guide[i + 1] - direction * trims[i + 1],
        ])

    var start_dir := (guide[1] - guide[0]).normalized()
    var end_dir := (guide[last] - guide[last - 1]).normalized()
    var start_tangent := _road_merge_tangent(merges, chain[0], start_dir)
    var end_tangent := _road_merge_tangent(merges, chain[last], end_dir)
    if absf(start_tangent.dot(start_dir)) < ROAD_MERGE_MIN_DOT:
        start_tangent = Vector2.ZERO
    if absf(end_tangent.dot(end_dir)) < ROAD_MERGE_MIN_DOT:
        end_tangent = Vector2.ZERO
    if start_tangent != Vector2.ZERO:
        runs[0][0] = guide[0] + start_dir * minf(
                guide[0].distance_to(guide[1]) * ROAD_MERGE_SHARE, radius * ROAD_TURN_RADIUS)
    if end_tangent != Vector2.ZERO:
        runs[runs.size() - 1][1] = guide[last] - end_dir * minf(
                guide[last].distance_to(guide[last - 1]) * ROAD_MERGE_SHARE,
                radius * ROAD_TURN_RADIUS)

    var points := PackedVector2Array()
    var spans := PackedInt32Array()
    if start_tangent != Vector2.ZERO:
        _append_road_blend(points, guide[0], start_tangent, runs[0][0], start_dir)
        _append_span_marks(spans, points.size(), 0)
    for i in range(runs.size()):
        _append_road_run(points, runs[i][0], runs[i][1], radius,
                _road_span_shift(chain[i], chain[i + 1]))
        _append_span_marks(spans, points.size(), i)
        if i + 1 < runs.size():
            var connector := points.size()
            if _road_junction_hexes.has(chain[i + 1]):
                _append_road_join(points, runs[i][1], guide[i + 1], runs[i + 1][0])
            else:
                _append_road_turn(points, runs[i][1], guide[i + 1], runs[i + 1][0])
            _append_connector_marks(spans, points, connector, i, guide[i + 1])
    if end_tangent != Vector2.ZERO:
        _append_road_blend(points, runs[runs.size() - 1][1], end_dir, guide[last], end_tangent)
        _append_span_marks(spans, points.size(), runs.size() - 1)
    return {"points": points, "spans": spans}

# The span of every point appended since the last call.
func _append_span_marks(spans: PackedInt32Array, size: int, span: int) -> void:
    while spans.size() < size:
        spans.append(span)

# A turn between two spans belongs to both: its points up to the hex centre are the tail of the
# incoming span, the rest is the head of the outgoing one. Thus a cut of the route at a hex
# reaches the centre from either side.
func _append_connector_marks(spans: PackedInt32Array, points: PackedVector2Array,
        from: int, span: int, corner: Vector2) -> void:
    var split := from
    var nearest := INF
    for i in range(from, points.size()):
        var distance := points[i].distance_to(corner)
        if distance < nearest:
            nearest = distance
            split = i
    while spans.size() < points.size():
        spans.append(span if spans.size() <= split else span + 1)

# The side of the road a wander is measured to. The direction is taken in a canonical
# orientation, so that the shape of a span does not depend on the end its chain was walked from:
# the order of the dictionary of the segments decides where a walk starts, and one road is drawn
# in more than one set - the level border and the border between the networks cut it, and the
# preview of an improvement repeats a part of it. All of them must bend alike.
func _road_lateral(direction: Vector2) -> Vector2:
    if direction.x < 0.0 or (direction.x == 0.0 and direction.y < 0.0):
        direction = -direction
    return Vector2(-direction.y, direction.x)

func _road_hex_is_less(a: Vector2i, b: Vector2i) -> bool:
    return a.x < b.x or (a.x == b.x and a.y < b.y)

func _road_other_end(ends: Array, hex: Vector2i) -> Vector2i:
    return ends[1] if ends[0] == hex else ends[0]

func _append_road_run(points: PackedVector2Array, from: Vector2, to: Vector2,
        radius: float, shift: float) -> void:
    var span := from.distance_to(to)
    if span <= 0.01:
        return
    var direction := (to - from) / span
    var normal := _road_lateral(direction)
    # A short run (the turns have eaten most of the span) must not bulge into a bubble.
    var amplitude := shift * minf(radius * ROAD_RUN_WAVE, span * 0.25)
    var steps := maxi(1, int(ceil(span / ROAD_SAMPLE_STEP)))
    for step in range(steps + 1):
        var t := float(step) / float(steps)
        # The wave is squared so that its slope is zero at both ends: the run then continues
        # into a turn or a blend without a kink.
        var wave := sin(PI * t)
        var point := from.lerp(to, t) + normal * (wave * wave * amplitude)
        if points.is_empty() or points[-1].distance_to(point) > 0.5:
            points.append(point)

# The rounded turn at a hex: a quadratic curve from the end of the incoming run to the start of
# the outgoing one, pulled towards the hex centre by the control point.
func _append_road_turn(points: PackedVector2Array, from: Vector2, corner: Vector2,
        to: Vector2) -> void:
    var turn := rad_to_deg(absf((corner - from).angle_to(to - corner)))
    var steps := maxi(2, int(ceil(from.distance_to(to) / ROAD_SAMPLE_STEP)))
    steps = maxi(steps, int(ceil(turn / ROAD_SAMPLE_ANGLE)))
    for step in range(1, steps + 1):
        var t := float(step) / float(steps)
        var point := from.lerp(corner, t).lerp(corner.lerp(to, t), t)
        if points.is_empty() or points[-1].distance_to(point) > 0.5:
            points.append(point)

# The turn through a junction hex centre. Unlike an ordinary hex, the centre of a junction is
# the point the routes of the other networks, levels and plans end at or pass through, so the
# road has to pass exactly through it. Two cubic halves meet there with a common tangent, so the
# bend is smooth instead of a corner at the point.
func _append_road_join(points: PackedVector2Array, from: Vector2, corner: Vector2,
        to: Vector2) -> void:
    var in_span := from.distance_to(corner)
    var out_span := to.distance_to(corner)
    if in_span <= 0.01 or out_span <= 0.01:
        return
    var in_dir := (corner - from) / in_span
    var out_dir := (to - corner) / out_span
    var middle := in_dir + out_dir
    if middle.length() > 0.01:
        middle = middle.normalized()
    else:
        middle = Vector2(-in_dir.y, in_dir.x)
    _append_road_cubic(points, from, from + in_dir * (in_span * 0.5),
            corner - middle * (in_span * 0.5), corner)
    _append_road_cubic(points, corner, corner + middle * (out_span * 0.5),
            to - out_dir * (out_span * 0.5), to)

# The blend of a road into the road it meets at a junction: a cubic curve that starts along
# one of the two directions and ends along the other.
func _append_road_blend(points: PackedVector2Array, from: Vector2, from_tangent: Vector2,
        to: Vector2, to_tangent: Vector2) -> void:
    var span := from.distance_to(to)
    if span <= 0.01:
        return
    var strength := span * ROAD_MERGE_STRENGTH
    _append_road_cubic(points, from, from + from_tangent * strength,
            to - to_tangent * strength, to)

func _append_road_cubic(points: PackedVector2Array, from: Vector2, control_a: Vector2,
        control_b: Vector2, to: Vector2) -> void:
    var span := from.distance_to(to)
    var turn := rad_to_deg(absf((control_a - from).angle_to(control_b - control_a))
            + absf((control_b - control_a).angle_to(to - control_b)))
    var steps := maxi(4, int(ceil(span / ROAD_SAMPLE_STEP)))
    steps = maxi(steps, int(ceil(turn / ROAD_SAMPLE_ANGLE)))
    for step in range(steps + 1):
        var t := float(step) / float(steps)
        var ab := from.lerp(control_a, t)
        var bc := control_a.lerp(control_b, t)
        var cd := control_b.lerp(to, t)
        var point := ab.lerp(bc, t).lerp(bc.lerp(cd, t), t)
        if points.is_empty() or points[-1].distance_to(point) > 0.5:
            points.append(point)

# A stable shift in [-1, 1] per hex and per span: the wander must not change between the
# frames, and the same cell must be bent alike in every network drawn over it. The span is
# hashed in the order of its two hexes, so the two ends of it give the same value.
func _road_hex_shift(row: int, col: int) -> float:
    var raw := (row * 73856093 + col * 19349663) & 0x7fffffff
    return float(raw) / float(0x7fffffff) * 2.0 - 1.0

func _road_span_shift(a: Vector2i, b: Vector2i) -> float:
    var low: Vector2i = a
    var high: Vector2i = b
    if _road_hex_is_less(high, low):
        low = b
        high = a
    var raw := (low.x * 73856093 + low.y * 19349663
            + high.x * 83492791 + high.y * 2971215073) & 0x7fffffff
    return float(raw) / float(0x7fffffff) * 2.0 - 1.0

# The "ghost" road: the segments of the plan which is open in the preview. Two passes - a wide
# semi-transparent halo and a line on top: the route reads over the terrain, the rivers and
# the real roads.
func _draw_road_preview() -> void:
    if _road_preview_segments.is_empty():
        return
    # The segments at least one end of which is in the fog are never drawn
    # (see the comment to PHASE 2d in _draw_all_roads).
    var visible_range: Dictionary = {}
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
            visible_range[segment_key] = true
    if visible_range.is_empty():
        return
    _draw_road_segments(visible_range, false, ROAD_PREVIEW_HALO_COLOR, ROAD_PREVIEW_HALO_WIDTH)
    _draw_road_segments(visible_range, false, ROAD_PREVIEW_COLOR, ROAD_PREVIEW_WIDTH)

func _draw_rivers():
    if main_map == null:
        return
    if not main_map.has_node("RiverManager"):
        return
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
    # The rivers are drawn in runs, not as whole polylines: a lightly meandering river
    # has ~50 points per hex, and the geometry of the drawn area is far larger than one screen.
    for river in river_list:
        var entry = _river_frame_cache.get(_river_index(river))
        if entry == null:
            continue
        for seg in entry["segments"]:
            var run: PackedVector2Array = seg["points"]
            draw_polyline(run, shore_color, shore_width, true)
            draw_polyline(run, body_color, body_width, true)
            draw_polyline(run, highlight_color, highlight_width, true)


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


# Rebuilds the geometry of the rivers: the culling by the drawn area, the smoothing (cached),
# the clipping by the drawn area and by the fog of war. The geometry is in world coordinates
# and does not depend on the view, therefore it is rebuilt only when the fog of war or the
# river list changes - never on a scroll.
func _build_river_frame_cache(radius: float) -> void:
    var river_manager = main_map.get_node("RiverManager")
    var all_rivers: Array = river_manager.get_main_rivers() + river_manager.get_tributaries()
    var draw_rect: Rect2 = _get_draw_rect()

    if not _river_frame_cache.is_empty() and _river_cache_rect.encloses(draw_rect):
        # A new river (or a changed path) invalidates the cache: the list of the rivers is
        # the cache key, and on a loaded save it differs from the generated one.
        #
        # The check must NOT demand an entry for every river: _collect_river_segments stores
        # only the rivers intersecting the drawn area, so having just a few of them is
        # the normal state. Instead we require that every river present in the cache still
        # exists in the current list.
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
    _river_frame_rebuilds += 1
    _river_cache_rect = draw_rect

    for river in all_rivers:
        if river.size() < 2:
            continue
        # A river entirely outside the drawn area can never be seen (the scroll clamp does not
        # let the screen there), therefore it costs nothing at the drawing.
        var min_x = INF
        var max_x = - INF
        var min_y = INF
        var max_y = - INF
        for pt in river:
            min_x = minf(min_x, pt.x)
            max_x = maxf(max_x, pt.x)
            min_y = minf(min_y, pt.y)
            max_y = maxf(max_y, pt.y)
        var river_rect = Rect2(
            min_x - radius,
            min_y - radius,
            (max_x - min_x) + radius * 2.0,
            (max_y - min_y) + radius * 2.0
        )
        if not river_rect.intersects(draw_rect):
            continue

        _river_frame_cache[_river_index(river)] = {
            "segments": _collect_river_segments(river, radius)
        }


# The visible runs of ONE river in the world coordinates, together with the world-space bounds
# of each run. The smoothed meanders are cached per river in the world coordinates.
func _collect_river_segments(river: Array, radius: float) -> Array:
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

    # The runs hidden by the fog of war are dropped: the terrain of an unexplored hex is not
    # drawn at all (see _draw_hex), so a river drawn there would float over the black void.
    # The clipping by the drawn area comes first, so the fog of war is tested only for
    # the points that can actually be seen.
    for line in _clip_river_to_rect(smooth_points, _get_draw_rect()):
        if line.size() < 2:
            continue
        for run in _split_line_by_fog(line, radius):
            var min_x = INF
            var max_x = - INF
            var min_y = INF
            var max_y = - INF
            for pt in run:
                min_x = minf(min_x, pt.x)
                max_x = maxf(max_x, pt.x)
                min_y = minf(min_y, pt.y)
                max_y = maxf(max_y, pt.y)
            var width = (max_x - min_x) + 2.0 * radius
            var height = (max_y - min_y) + 2.0 * radius
            segments.append({
                "points": run,
                "rect": Rect2(min_x - radius, min_y - radius, width, height)
            })
    return segments


# The runs of a world-space polyline that lie over the explored (drawn) part of the map. A run
# shorter than two points cannot be drawn and is dropped.
func _split_line_by_fog(points: PackedVector2Array, radius: float) -> Array:
    var runs: Array = []
    var current := PackedVector2Array()
    for pt in points:
        if _is_river_point_visible(pt, radius):
            current.append(pt)
        else:
            if current.size() >= 2:
                runs.append(current)
            current = PackedVector2Array()
    if current.size() >= 2:
        runs.append(current)
    return runs


# Whether a point of a river is over the explored part of the map. A river flows along the sides
# of the hexes, therefore it is visible exactly where it touches a drawn hex: the point is
# visible if any of the three hexes nearest to it is not in the fog of war. The two nearest hexes
# share the side under the point; the third one covers a point near a vertex, where three hexes
# meet. A point surrounded by fog has all three nearest hexes fogged and is dropped, so the river
# breaks off at the border of the explored area. Testing the three nearest hexes (rather than
# just the one whose centre is closest) also keeps a river running exactly along the border
# continuous instead of dashing: a side shared by an explored and an unexplored hex stays visible.
func _is_river_point_visible(pos: Vector2, radius: float) -> bool:
    var base := _nearest_hex(pos, radius)
    # The common case: the nearest hex is explored, so the point is deep inside the known area
    # and no neighbour has to be examined.
    if main_map.is_hex_on_map(base.x, base.y) and not main_map.is_hex_in_fog(base.x, base.y):
        return true
    var rows := PackedInt32Array([base.x])
    var cols := PackedInt32Array([base.y])
    var dists := PackedFloat32Array([HexUtils.hex_center(base.x, base.y, radius).distance_squared_to(pos)])
    var deltas: Array = RIVER_HEX_ODD_NEIGHBORS if base.x % 2 != 0 else RIVER_HEX_EVEN_NEIGHBORS
    for d in deltas:
        var r: int = base.x + int(d[0])
        var c: int = base.y + int(d[1])
        rows.append(r)
        cols.append(c)
        dists.append(HexUtils.hex_center(r, c, radius).distance_squared_to(pos))
    # The three nearest of the seven (the rest cannot be among them).
    for _pick in range(3):
        var best_i := -1
        var best_d := INF
        for i in range(dists.size()):
            if dists[i] < best_d:
                best_d = dists[i]
                best_i = i
        if best_i == -1:
            break
        # A hex outside the map is not drawn either, so it must not make the point visible.
        # is_hex_in_fog alone would return false there (the fog is only defined on the map).
        var r: int = rows[best_i]
        var c: int = cols[best_i]
        if main_map.is_hex_on_map(r, c) and not main_map.is_hex_in_fog(r, c):
            return true
        dists[best_i] = INF
    return false


# The hex whose centre is the closest to the world point. The grid is pointy-top odd-r
# (see HexUtils.hex_center): the row is estimated from y, the column from x with the half-hex
# shift of the odd rows, and the estimate is refined over the 3x3 neighbourhood (the closest
# hex is always adjacent to the estimate).
func _nearest_hex(pos: Vector2, radius: float) -> Vector2i:
    var x_spacing := radius * sqrt(3.0)
    var y_spacing := radius * 1.5
    var row_est := roundi(pos.y / y_spacing)
    var best := Vector2i(row_est, 0)
    var best_dist := INF
    for dr in range(-1, 2):
        var row := row_est + dr
        # The same parity rule as HexUtils.hex_center (an odd row is shifted by a half hex).
        var row_shift := x_spacing * 0.5 if row % 2 == 1 else 0.0
        var col_est := roundi((pos.x - row_shift) / x_spacing)
        for dc in range(-1, 2):
            var col := col_est + dc
            var d := HexUtils.hex_center(row, col, radius).distance_squared_to(pos)
            if d < best_dist:
                best_dist = d
                best = Vector2i(row, col)
    return best


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

func _generate_natural_river(river_points: PackedVector2Array, radius: float) -> PackedVector2Array:
    if river_points.size() < 2:
        return river_points

    # The sample step sets the point count of the meanders, and that count is what the frame
    # pays for: the smoothed run is cached in the world coordinates and replayed by draw_polyline
    # on every pan. The wave period is 2*PI/frequency ~= 7 * sample_step, so a step larger than
    # a quarter of the wavelength stops improving the shape (the Chaikin pass below rounds what
    # is left).
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
    var visible_range = _get_draw_hex_range()

    # The highlighting of the scouted hexes. The chunk under the cursor is drawn by a separate
    # layer (see map_highlight_layer.gd): the hover changes far more often than the map, and
    # re-recording the whole map for it would stall the pan.
    for row in range(visible_range["row_start"], visible_range["row_end"] + 1):
        for col in range(visible_range["col_start"], visible_range["col_end"] + 1):
            var tile = tile_data[row][col]
            if tile.get("in_influence", false):
                continue
            var is_explored = tile.get("is_explored", false)
            if not is_explored:
                continue
            var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
            var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)
            # Scouted: only the fill - there is deliberately no white frame here
            # it merged with the grid of the hexes and visually "inflated"
            # the scouted area. The frame is drawn only by the hover/the selection of the chunk
            # (see map_highlight_layer.gd).
            draw_colored_polygon(vertices, Color(0.652, 0.855, 0.652, 0.25))

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
