# Headless test of the highlighting of the route on the map (map_renderer).
#   godot --headless --path . --script res://tests/test_route_highlight.gd
#
# The route goes along roads which are already drawn, and the highlight is a thin line on top
# of them: it has to lie on the road exactly. The geometry of the roads is built from the SET
# of the segments (a level of a network per set), and the shape of a set is decided by the
# direction the chain is walked in, by the pairing at the junctions and by where the level
# border cuts the chain. A highlight drawn from a set of its own drifts aside by the lateral
# wander of the hexes — that is what the checks below catch.
#
# Checks:
#   1. ON THE ROAD. Every point of the highlight of a route along a built road is within a
#      pixel of a drawn road line.
#   2. THE ORDER OF THE SEGMENTS. The same set given in the reverse order is drawn alike: the
#      road network and the route are two dictionaries of the same segments.
#   3. THE LEVEL BORDER. A route over a half-upgraded road lies on the roads of both levels.
extends SceneTree

# Hang watchdog: without it a break of the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# The highlight is a thin line over the road: a pixel of divergence is the width of the line
# itself, and the wander of a hex is 0.26 of the hex radius, so the limit is far below the
# error it catches.
const MAX_OFFSET := 1.0

var _main_map = null
var _renderer = null
var _radius := 55.0

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    _main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(_main_map)
    for _i in range(8):
        await process_frame
    var guard := 0
    while _main_map.world_generating and guard < 600:
        await process_frame
        guard += 1
    _main_map.use_edge_scrolling = false
    _main_map.debug_open_whole_map()
    for _i in range(4):
        await process_frame
    _renderer = _main_map.map_renderer
    _radius = _main_map.HEX_RADIUS

    _build_roads()
    var target := _find_route_target()
    check(target.x >= 0, "no road with a route to the city was built", state)

    if target.x >= 0:
        if WATCHDOG.wants_case("on_the_road"):
            _test_on_the_road(target, state)
        if WATCHDOG.wants_case("segment_order"):
            _test_segment_order(state)
        if WATCHDOG.wants_case("level_border"):
            _test_level_border(target, state)

    _finish(state)

# --- 1. The highlight lies on the road ---
func _test_on_the_road(target: Vector2i, state: Dictionary) -> void:
    _refresh_road_sets()
    var route: Dictionary = _main_map.get_route_to_city(target.x, target.y)
    check(bool(route.get("ok", false)), "the route to %s was not found" % str(target), state)
    _renderer.set_route_segments(_route_set(route))
    var highlight: Array = _renderer._route_polylines()
    check(not highlight.is_empty(), "the route is not highlighted at all", state)
    var offset := _max_offset(highlight, _road_polylines())
    check(offset <= MAX_OFFSET,
            "the highlight of the route leaves the road by %.2f px (limit %.1f)"
                    % [offset, MAX_OFFSET], state)

# --- 2. The drawing does not depend on the order of the segments ---
func _test_segment_order(state: Dictionary) -> void:
    _refresh_road_sets()
    var drawn: Array = _road_polylines()
    var straight := _first_road_set()
    var keys: Array = straight["segments"].keys()
    keys.reverse()
    var reversed_segments: Dictionary = {}
    for key in keys:
        reversed_segments[key] = true
    var reversed_lines: Array = _renderer._road_chain_polylines(reversed_segments,
            bool(straight["hide_in_fog"]), _radius)
    var offset := _max_offset(reversed_lines, drawn)
    check(offset <= MAX_OFFSET,
            "the same segments in the reverse order are drawn %.2f px aside (limit %.1f)"
                    % [offset, MAX_OFFSET], state)

# --- 3. A level border cuts the chains of the road, and the highlight follows both halves ---
func _test_level_border(target: Vector2i, state: Dictionary) -> void:
    var route: Dictionary = _main_map.get_route_to_city(target.x, target.y)
    if not bool(route.get("ok", false)):
        return
    var segments: Array = route.get("segments", [])
    if segments.size() < 3:
        return
    var middle: String = str(segments[segments.size() / 2])
    var ends: Array = _renderer._road_segment_ends(middle)
    check(not ends.is_empty(), "the middle segment of the route is not readable", state)
    if ends.is_empty():
        return
    var a: Vector2i = ends[0]
    var b: Vector2i = ends[1]
    check(_main_map.road_manager.upgrade_road_segment(a.x, a.y, b.x, b.y, 2),
            "the middle segment of the route was not upgraded", state)

    _refresh_road_sets()
    check(_renderer._road_draw_sets.size() >= 2,
            "the levels of the road did not split into the sets of their own", state)
    _renderer.set_route_segments(_route_set(route))
    var highlight: Array = _renderer._route_polylines()
    check(not highlight.is_empty(), "the route over two levels is not highlighted", state)
    var offset := _max_offset(highlight, _road_polylines())
    check(offset <= MAX_OFFSET,
            "the highlight of the route leaves the road by %.2f px at a level border"
                    % offset, state)

# --- The roads of the test ---
func _build_roads() -> void:
    for ring in [6, 9]:
        for angle in range(0, 360, 45):
            var rad := deg_to_rad(float(angle))
            var row := int(_main_map.city_row + round(sin(rad) * ring))
            var col := int(_main_map.city_col + round(cos(rad) * ring))
            if not _main_map.is_hex_on_map(row, col):
                continue
            if not _main_map.get_road_plan(row, col).get("ok", false):
                continue
            _main_map.road_manager.build_road_to(row, col, _main_map.tile_data,
                    _main_map.region_rows, _main_map.region_cols, -1,
                    _main_map._road_hex_allowed())

func _find_route_target() -> Vector2i:
    for key in _main_map.road_manager.get_all_road_segments().keys():
        var ends: Array = _renderer._road_segment_ends(key)
        if ends.is_empty():
            continue
        var hex: Vector2i = ends[1]
        if HexUtils.hex_distance(_main_map.city_row, _main_map.city_col, hex.x, hex.y) < 6:
            continue
        if bool(_main_map.get_route_to_city(hex.x, hex.y).get("ok", false)):
            return hex
    return Vector2i(-1, -1)

# The sets of the road segments and the junction hexes, as _draw_all_roads collects them.
func _refresh_road_sets() -> void:
    var road_manager = _main_map.road_manager
    var city: Dictionary = road_manager.get_all_road_segments()
    var town: Dictionary = road_manager.get_all_town_road_segments()
    var link: Dictionary = road_manager.get_all_town_link_segments()
    _renderer._road_junction_hexes = _renderer._collect_road_junction_hexes(city, town, link)
    _renderer._road_draw_sets = _renderer._collect_road_draw_sets(city, town, link,
            road_manager)

func _road_polylines() -> Array:
    var polylines: Array = []
    for entry in _renderer._road_draw_sets:
        polylines.append_array(_renderer._road_chain_polylines(entry["segments"],
                bool(entry["hide_in_fog"]), _radius))
    return polylines

func _first_road_set() -> Dictionary:
    return _renderer._road_draw_sets[0]

func _route_set(route: Dictionary) -> Dictionary:
    var segments: Dictionary = {}
    for key in route.get("segments", []):
        segments[str(key)] = true
    return segments

# The farthest point of the lines from the nearest road line.
func _max_offset(lines: Array, road_lines: Array) -> float:
    var worst := 0.0
    for line in lines:
        for point in line:
            var best := INF
            for road in road_lines:
                for i in range(road.size() - 1):
                    best = minf(best, _point_segment_distance(point, road[i], road[i + 1]))
            worst = maxf(worst, best)
    return worst

func _point_segment_distance(point: Vector2, a: Vector2, b: Vector2) -> float:
    var ab := b - a
    var length_sq := ab.length_squared()
    if length_sq <= 0.0001:
        return point.distance_to(a)
    var t := clampf((point - a).dot(ab) / length_sq, 0.0, 1.0)
    return point.distance_to(a + ab * t)

func _finish(state: Dictionary) -> void:
    if _main_map != null and is_instance_valid(_main_map):
        get_root().remove_child(_main_map)
        _main_map.free()
    if state["failed"]:
        print("ROUTE HIGHLIGHT TEST FAILED")
        quit(1)
    else:
        print("ROUTE HIGHLIGHT TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
