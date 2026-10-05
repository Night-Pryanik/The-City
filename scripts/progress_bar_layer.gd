# progress_bar_layer.gd
# A separate layer for drawing progress bars on the map.
# We take them out of map_renderer so that redrawing a small layer of bars
# does not drag a redraw of the whole heavy map (hexes, roads, rivers) with it.
@tool
extends Node2D

const RESOURCE_ICON_SIZE = 80

var tile_data = []
var main_map: Node

func initialize(td, main_node):
    tile_data = td
    main_map = main_node

func _draw():
    if main_map == null or tile_data.is_empty():
        return

    var visible = _get_visible_hex_range()
    for row in range(visible.row_start, visible.row_end + 1):
        for col in range(visible.col_start, visible.col_end + 1):
            _draw_progress_bars(row, col)

# Returns a dictionary with the bounds of the visible hexes (inclusive),
# limited by the area reachable by scrolling the map (scout_reach).
# It is used for viewport culling. The bounds are wider than the Region: the
# starting hex of a scouting chunk may lie in the fog of war (beyond the Region) —
# this is only possible after researching Cartography — and the scouting
# progress bar must be visible there too.
func _get_visible_hex_range() -> Dictionary:
    var viewport_size = Vector2(1152, 768)
    if not Engine.is_editor_hint():
        viewport_size = get_viewport_rect().size

    var offset_x = main_map.offset_x + main_map.scroll_offset.x
    var offset_y = main_map.offset_y + main_map.scroll_offset.y

    var radius = main_map.HEX_RADIUS
    var x_spacing = radius * sqrt(3.0)
    var y_spacing = radius * 1.5

    var world_left = - offset_x
    var world_top = - offset_y
    var world_right = world_left + viewport_size.x
    var world_bottom = world_top + viewport_size.y

    var margin = 2

    var col_start = int(floor(world_left / x_spacing)) - margin
    var col_end = int(ceil(world_right / x_spacing)) + margin
    var row_start = int(floor(world_top / y_spacing)) - margin
    var row_end = int(ceil(world_bottom / y_spacing)) + margin

    # Limit by the area reachable by scrolling the map: the scouting
    # progress bar must be visible in the fog of war as well (the starting hex
    # of a chunk may lie beyond the Region).
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

func _draw_progress_bars(row: int, col: int):
    if main_map == null:
        return
    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    center.x += main_map.offset_x + main_map.scroll_offset.x
    center.y += main_map.offset_y + main_map.scroll_offset.y

    var tile = tile_data[row][col]

    # --- The pasture fill progress bar (time_to_mature) ---
    # It is shown ONLY while the herd is growing (0% < fill < 100%)
    # and there is a worker on the improvement. At full headcount the bar disappears.
    var eff_res_fill = MapHelpers.get_effective_resource(tile)
    if eff_res_fill != "" and tile.get("improvement", null) != null \
            and main_map.worker_manager.has_worker(row, col):
        var res_data_fill = GameData.raw_resources.get(eff_res_fill, {})
        if MapHelpers.is_growing_resource(res_data_fill):
            var fill_frac = MapHelpers.get_fill_fraction(tile, res_data_fill)
            if fill_frac > 0.0 and fill_frac < 1.0:
                var pasture_bar_width = RESOURCE_ICON_SIZE
                var pasture_bar_height = 6
                var pasture_bar_x = center.x - pasture_bar_width / 2.0
                var pasture_bar_y = center.y + RESOURCE_ICON_SIZE / 2.0 + 4
                draw_rect(Rect2(pasture_bar_x, pasture_bar_y, pasture_bar_width, pasture_bar_height), Color(0.2, 0.2, 0.2))
                draw_rect(Rect2(pasture_bar_x, pasture_bar_y, pasture_bar_width * fill_frac, pasture_bar_height), Color(0.85, 0.55, 0.35))
                draw_rect(Rect2(pasture_bar_x, pasture_bar_y, pasture_bar_width, pasture_bar_height), Color.WHITE, false)

    # The progress bar of the technology research that unlocks:
    # 1) the resource itself (tech_required), or
    # 2) the improvement that extracts this resource (improved_by → unlock_tech)
    var research_tech = CityData.current_research_tech_id
    var eff_res_for_bar = MapHelpers.get_effective_resource(tile)
    if research_tech != "" and eff_res_for_bar != "" and _is_resource_revealed(tile):
        var show_progress = false
        if _is_resource_locked(eff_res_for_bar):
            var imp_id = GameData.raw_resources.get(eff_res_for_bar, {}).get("improved_by", "")
            if imp_id != null and imp_id != "":
                var imp_unlock_tech = CityData.get_improvement_unlock_tech(imp_id)
                # We show the progress bar while ANY not yet researched
                # step of the chain leading to the technology that unlocks the
                # improvement which extracts the resource is being researched.
                # We compute the chain by the technology of the
                # improvement (imp_unlock_tech), and not by the tech_required of the resource:
                # for example, for quartz sand the bar appears both when researching
                # "Mining" and when researching "Masonry".
                var chain = CityData.get_tech_study_chain(imp_unlock_tech)
                if research_tech in chain:
                    show_progress = true
        if show_progress:
            var bar_width = RESOURCE_ICON_SIZE
            var bar_height = 6
            var bar_x = center.x - bar_width / 2.0
            var bar_y = center.y + RESOURCE_ICON_SIZE / 2.0 + 4
            draw_rect(Rect2(bar_x, bar_y, bar_width, bar_height), Color(0.2, 0.2, 0.2))
            var fill_width = bar_width * CityData.research_progress
            draw_rect(Rect2(bar_x, bar_y, fill_width, bar_height), Color.GREEN)
            draw_rect(Rect2(bar_x, bar_y, bar_width, bar_height), Color.WHITE, false)

    if main_map.build_manager.is_building(row, col):
        var progress_data = main_map.build_manager.get_progress(row, col)
        if not progress_data.is_empty():
            var bar_width = RESOURCE_ICON_SIZE
            var bar_height = 6
            var bar_x = center.x - bar_width / 2.0
            var bar_y = center.y + RESOURCE_ICON_SIZE / 2.0 + 10
            draw_rect(Rect2(bar_x, bar_y, bar_width, bar_height), Color(0.2, 0.2, 0.2))
            var work_cost = progress_data.get("work_cost", 1.0)
            var progress = progress_data.get("progress", 0.0)
            var fill_width = bar_width * clamp(progress / work_cost, 0.0, 1.0)
            draw_rect(Rect2(bar_x, bar_y, fill_width, bar_height), Color.YELLOW)
            draw_rect(Rect2(bar_x, bar_y, bar_width, bar_height), Color.WHITE, false)

    # --- The progress bar of the current stage of a staged project (a road per hex) ---
    # It is drawn on the hex that the segment under construction connects to the
    # network. When the segment is finished, the project manager moves on to the next
    # one — and the bar itself moves to the next hex. The general mechanism: it will
    # suit any staged project (an aqueduct and so on), and not only a road.
    if main_map.project_manager != null:
        var project_progress = main_map.project_manager.get_step_progress_at(row, col)
        if not project_progress.is_empty():
            var proj_bar_width = RESOURCE_ICON_SIZE
            var proj_bar_height = 6
            var proj_bar_x = center.x - proj_bar_width / 2.0
            # Below the construction bar, so as not to overlap it: a hex can
            # have both an improvement being built and a road segment at once.
            var proj_bar_y = center.y + RESOURCE_ICON_SIZE / 2.0 + 16
            draw_rect(Rect2(proj_bar_x, proj_bar_y, proj_bar_width, proj_bar_height), Color(0.2, 0.2, 0.2))
            var p_work_cost = maxf(1.0, float(project_progress.get("work_cost", 1.0)))
            var p_progress = float(project_progress.get("progress", 0.0))
            var proj_fill_width = proj_bar_width * clamp(p_progress / p_work_cost, 0.0, 1.0)
            # The improvement stage in the "road → improvement" chain is painted yellow —
            # the same colour as an ordinary improvement build: the player must see
            # that an improvement is being built on the hex, and not a road segment.
            var proj_color := Color(0.45, 0.75, 1.0)
            if str(project_progress.get("step_type", "")) == "improvement":
                proj_color = Color(1.0, 0.85, 0.0)
            draw_rect(Rect2(proj_bar_x, proj_bar_y, proj_fill_width, proj_bar_height), proj_color)
            draw_rect(Rect2(proj_bar_x, proj_bar_y, proj_bar_width, proj_bar_height), Color.WHITE, false)

    # --- The territory claim progress bar (buying a chunk for labour) ---
    # It is shown on the first hex of the chunk being claimed.
    var expansion_progress = main_map.build_manager.get_expansion_progress_for_hex(row, col)
    if not expansion_progress.is_empty():
        var bar_width = RESOURCE_ICON_SIZE
        var bar_height = 6
        var bar_x = center.x - bar_width / 2.0
        var bar_y = center.y + RESOURCE_ICON_SIZE / 2.0 + 10
        draw_rect(Rect2(bar_x, bar_y, bar_width, bar_height), Color(0.2, 0.2, 0.2))
        var work_cost = expansion_progress.get("work_cost", 1.0)
        var progress = expansion_progress.get("progress", 0.0)
        var fill_width = bar_width * clamp(progress / work_cost, 0.0, 1.0)
        draw_rect(Rect2(bar_x, bar_y, fill_width, bar_height), Color(0.9, 0.6, 0.2))
        draw_rect(Rect2(bar_x, bar_y, bar_width, bar_height), Color.WHITE, false)

    # --- The chunk scouting progress bar ---
    if main_map.is_scouting and not main_map.scouting_chunk.is_empty():
        var scout_center_hex = main_map.scouting_chunk[0]
        if scout_center_hex.row == row and scout_center_hex.col == col:
            var scout_progress = clamp(main_map.scouting_timer / (main_map.scouting_chunk.size() * main_map.SCOUTING_TIME_PER_HEX), 0.0, 1.0)
            var scout_bar_width = RESOURCE_ICON_SIZE
            var scout_bar_height = 6
            var scout_bar_x = center.x - scout_bar_width / 2.0
            var scout_bar_y = center.y + RESOURCE_ICON_SIZE / 2.0 + 16
            draw_rect(Rect2(scout_bar_x, scout_bar_y, scout_bar_width, scout_bar_height), Color(0.2, 0.2, 0.2))
            draw_rect(Rect2(scout_bar_x, scout_bar_y, scout_bar_width * scout_progress, scout_bar_height), Color(0.2, 0.7, 0.9))
            draw_rect(Rect2(scout_bar_x, scout_bar_y, scout_bar_width, scout_bar_height), Color.WHITE, false)

func _is_resource_revealed(tile: Dictionary) -> bool:
    return MapHelpers.is_resource_revealed(tile)

func _is_resource_locked(resource_id: String) -> bool:
    if resource_id == null or resource_id == "":
        return false
    var res_data = GameData.raw_resources.get(resource_id, {})
    var imp_id = res_data.get("improved_by", "")
    # For some resources (for example, foraged_food wild plants) improved_by is set
    # as null — then .get() returns Nil, and not the default value.
    if imp_id == null:
        return false
    # A resource is considered locked if the improvement that
    # extracts it (improved_by) has not yet been unlocked by its unlock_tech.
    return not CityData.is_improvement_unlocked(imp_id)