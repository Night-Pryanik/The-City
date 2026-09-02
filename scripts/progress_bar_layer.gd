# progress_bar_layer.gd
# Отдельный слой для отрисовки прогресс-баров на карте.
# Выносим их из map_renderer, чтобы перерисовка небольшого слоя баров
# не тянула за собой перерисовку всей тяжёлой карты (гексы, дороги, реки).
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

# Возвращает словарь с границами видимых гексов (инклюзивно),
# ограниченными границами региона. Используется для viewport culling.
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

    col_start = max(col_start, main_map.region_start_col)
    col_end = min(col_end, main_map.region_end_col)
    row_start = max(row_start, main_map.region_start_row)
    row_end = min(row_end, main_map.region_end_row)

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

    # --- Прогресс-бар заполенности пастбища (time_to_mature) ---
    # Показывается ТОЛЬКО пока стадо растёт (0% < заполненность < 100%)
    # и на улучшении есть рабочий. При полном поголовье бар исчезает.
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

    # Прогресс-бар исследования технологии, которая открывает:
    # 1) сам ресурс (tech_required), либо
    # 2) улучшение, которым добывается этот ресурс (improved_by → unlock_tech)
    var research_tech = CityData.current_research_tech_id
    var eff_res_for_bar = MapHelpers.get_effective_resource(tile)
    if research_tech != "" and eff_res_for_bar != "" and _is_resource_revealed(tile):
        var show_progress = false
        if _is_resource_locked(eff_res_for_bar):
            var imp_id = GameData.raw_resources.get(eff_res_for_bar, {}).get("improved_by", "")
            if imp_id != null and imp_id != "":
                var imp_unlock_tech = CityData.get_improvement_unlock_tech(imp_id)
                # Показываем прогресс-бар, пока изучается ЛЮБОЙ ещё не изученный
                # шаг цепочки, ведущей к технологии, открывающей улучшение,
                # которым добывается ресурс. Цепочку считаем по технологии
                # улучшения (imp_unlock_tech), а не по tech_required ресурса:
                # например, для кварцевого песка бар появляется и при изучении
                # «Горного дела», и при изучении «Каменной кладки».
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

    # --- Прогресс-бар освоения территории (покупка чанка за труд) ---
    # Показывается на первом гексе чанка, который осваивается.
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

    # --- Прогресс-бар разведки чанка ---
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
    # У части ресурсов (например, дикоросы foraged_food) improved_by задан
    # как null — тогда .get() возвращает Nil, а не значение по умолчанию.
    if imp_id == null:
        return false
    # Ресурс считается заблокированным, если ещё не открыто улучшение, которое
    # его добывает (improved_by), по его unlock_tech.
    return not CityData.is_improvement_unlocked(imp_id)