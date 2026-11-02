# improvement_state_layer.gd
# The tick-to-tick state of the improvements on the map: a worker on the hex lights its icon
# up, a road flag puts a warning triangle over it. Both change far more often than the map
# itself, so they are drawn in a layer of their own: an assignment repaints a handful of
# icons instead of re-recording every hex, road and river.
@tool
extends Node2D

var tile_data = []
var main_map: Node
var map_renderer: Node

var _map_draw_calls: int = -1
var draw_calls: int = 0

func initialize(td, main_node, renderer) -> void:
    tile_data = td
    main_map = main_node
    map_renderer = renderer
    _map_draw_calls = -1
    queue_redraw()

func _process(_delta: float) -> void:
    if main_map == null or map_renderer == null or tile_data.is_empty():
        return
    # The map re-recorded its commands, so the geometry under this layer may have changed:
    # an improvement was built or removed, the Influence Ring was redrawn.
    if _map_draw_calls == map_renderer.draw_calls:
        return
    _map_draw_calls = map_renderer.draw_calls
    queue_redraw()

func _draw() -> void:
    draw_calls += 1
    if main_map == null or map_renderer == null or tile_data.is_empty():
        return
    if main_map.world_generating:
        return
    var visible_range: Dictionary = map_renderer._get_draw_hex_range()
    for row in range(visible_range.row_start, visible_range.row_end + 1):
        for col in range(visible_range.col_start, visible_range.col_end + 1):
            _draw_hex_state(row, col)

func _draw_hex_state(row: int, col: int) -> void:
    var tile = tile_data[row][col]
    if tile.improvement == null:
        return
    var icon: Dictionary = map_renderer.get_improvement_icon_geometry(row, col)
    if icon.is_empty():
        return
    if main_map.worker_manager.has_worker(row, col):
        map_renderer.draw_improvement_icon(self, icon, true)
    if bool(tile.get("road_capacity_short", false)) \
            or bool(tile.get("road_missing", false)):
        map_renderer.draw_road_warning(self, icon)
