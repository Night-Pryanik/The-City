# map_renderer.gd
@tool
extends Node2D

const CITY_ICON_SIZE = 130
const TERRAIN_ICON_SIZE = 130
const RESOURCE_ICON_SIZE = 80
const IMPROVEMENT_ICON_SIZE = 32
const LOCK_ICON_SIZE = 32

var tile_data = []
var icon_textures = {}
var lock_texture = null
var icon_paths = {}

# Ссылка на главный узел для доступа к offset_x, offset_y, scroll_offset, build_manager и CityData
var main_map: Node

func initialize(td, main_node):
    tile_data = td
    main_map = main_node

func build_icon_index():
    icon_paths.clear()
    _scan_folder("res://icons")

func _scan_folder(folder_path: String):
    var dir = DirAccess.open(folder_path)
    if dir == null: return
    dir.list_dir_begin()
    var file_name = dir.get_next()
    while file_name != "":
        if dir.current_is_dir():
            _scan_folder(folder_path.path_join(file_name))
        else:
            var full_path = folder_path.path_join(file_name)
            if icon_paths.has(file_name): print("Предупреждение: дубликат иконки ", file_name)
            icon_paths[file_name] = full_path
        file_name = dir.get_next()
    dir.list_dir_end()

func load_icons():
    icon_textures.clear()
    for res_id in GameData.raw_resources.keys():
        var res = GameData.raw_resources[res_id]
        if res.has("icon"):
            var file_name = res.icon
            if icon_paths.has(file_name):
                icon_textures[file_name] = load(icon_paths[file_name])
    for imp_id in GameData.improvements.keys():
        var imp = GameData.improvements[imp_id]
        if imp.has("icon"):
            var file_name = imp.icon
            if icon_paths.has(file_name):
                icon_textures[file_name] = load(icon_paths[file_name])
    for t_id in GameData.terrains.keys():
        var t = GameData.terrains[t_id]
        if t.has("icon"):
            var file_name = t.icon
            if icon_paths.has(file_name):
                icon_textures[file_name] = load(icon_paths[file_name])
        if t.has("icons"):
            for icon_name in t.icons:
                if icon_paths.has(icon_name):
                    icon_textures[icon_name] = load(icon_paths[icon_name])
    if icon_paths.has("city.png"):
        icon_textures["city"] = load(icon_paths["city.png"])
    if icon_paths.has("lock.png"):
        lock_texture = load(icon_paths["lock.png"])
    else:
        printerr("ОШИБКА: Файл lock.png не найден в папке icons!")
        assert(false, "lock.png missing")

func _draw():
    # ФАЗА 1: Рисуем основные гексы с территориями
    for row in range(main_map.REGION_ROWS):
        for col in range(main_map.REGION_COLS):
            _draw_hex(row, col)

    # ФАЗА 2: Рисуем дороги (ПЕРЕД иконками ресурсов и улучшений)
    _draw_all_roads()

    # ФАЗА 2.5: Рисуем подсветку для разведки и покупки (всегда активна)
    _draw_exploration_highlights()

    # ФАЗА 3: Рисуем иконки ресурсов, улучшений и другие оверлеи
    for row in range(main_map.REGION_ROWS):
        for col in range(main_map.REGION_COLS):
            _draw_hex_overlays(row, col)

    # ФАЗА 4: Рисуем город в конце
    var offset_pos = Vector2(
        main_map.offset_x + main_map.scroll_offset.x,
        main_map.offset_y + main_map.scroll_offset.y
    )
    var city_center = HexUtils.hex_center(main_map.CITY_ROW, main_map.CITY_COL, main_map.HEX_RADIUS) + offset_pos
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

    var terrain_color = Color.BLACK
    var terrain = tile.terrain
    var terrain_icon_name = tile.get("terrain_icon", "")

    if row == main_map.CITY_ROW and col == main_map.CITY_COL:
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

    if not in_influence:
        draw_colored_polygon(vertices, Color(0, 0, 0, 0.5))

    if main_map.show_hex_borders:
        draw_polyline(closed_vertices, Color.WHITE, 2, true)

# Ресурс виден игроку, если гекс входит в Кольцо Влияния
# (территория освоена) или область была исследована разведкой.
func _is_resource_revealed(tile: Dictionary) -> bool:
    if tile.get("in_influence", false):
        return true
    return tile.get("is_explored", false)

func _draw_hex_overlays(row: int, col: int):
    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    center.x += main_map.offset_x + main_map.scroll_offset.x
    center.y += main_map.offset_y + main_map.scroll_offset.y

    var tile = tile_data[row][col]
    var in_influence = tile.get("in_influence", false)

    if row == main_map.CITY_ROW and col == main_map.CITY_COL:
        return

    # Ресурсы Региона вне Кольца Влияния скрыты, пока область не разведана.
    # (Прогресс-бары ниже отрисовываются независимо от видимости ресурса.)
    var is_resource_visible = _is_resource_revealed(tile)

    if tile.resource != null and is_resource_visible:
        var res_data = GameData.raw_resources.get(tile.resource, {})
        var res_icon = res_data.get("icon", "")
        var is_locked = _is_resource_locked(tile.resource)
        if res_icon != "" and icon_textures.has(res_icon):
            var tex = icon_textures[res_icon]
            var icon_rect = Rect2(center.x - RESOURCE_ICON_SIZE / 2.0, center.y - RESOURCE_ICON_SIZE / 2.0, RESOURCE_ICON_SIZE, RESOURCE_ICON_SIZE)
            draw_texture_rect(tex, icon_rect, false)
        else:
            if res_data.has("color"):
                var c = res_data["color"]
                var fallback_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
                draw_circle(center, RESOURCE_ICON_SIZE / 3.0, fallback_color)
        if is_locked and lock_texture:
            var lock_icon_pos = Vector2(center.x, center.y + main_map.HEX_RADIUS * 0.75)
            var lock_rect = Rect2(lock_icon_pos.x - LOCK_ICON_SIZE / 2.0, lock_icon_pos.y - LOCK_ICON_SIZE / 2.0, LOCK_ICON_SIZE, LOCK_ICON_SIZE)
            draw_texture_rect(lock_texture, lock_rect, false)

        # Прогресс-бар исследования технологии, которая открывает:
        # 1) сам ресурс (tech_required), либо
        # 2) улучшение, которым добывается этот ресурс (improved_by → unlock_tech)
        var research_tech = CityData.current_research_tech_id
        if research_tech != "" and tile.resource != null and _is_resource_revealed(tile):
            var show_progress = false
            if is_locked:
                var res_tech = res_data.get("tech_required", "")
                if res_tech == research_tech:
                    show_progress = true
            else:
                # Ресурс открыт, но улучшение для него ещё не изучено
                var imp_id = res_data.get("improved_by", "")
                if imp_id != null and imp_id != "" and not CityData.is_improvement_unlocked(imp_id):
                    var imp_unlock_tech = CityData.get_improvement_unlock_tech(imp_id)
                    if imp_unlock_tech == research_tech:
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
            var fill_width = bar_width * (progress_data["progress"] / progress_data["target_time"])
            draw_rect(Rect2(bar_x, bar_y, fill_width, bar_height), Color.YELLOW)
            draw_rect(Rect2(bar_x, bar_y, bar_width, bar_height), Color.WHITE, false)

    if in_influence and tile.improvement != null:
        var has_worker = main_map.worker_manager.has_worker(row, col)
        var imp_data = GameData.improvements.get(tile.improvement, {})
        var imp_icon = imp_data.get("icon", "")
        var icon_pos = Vector2(center.x, center.y - main_map.HEX_RADIUS * 0.75)
        if imp_icon != "" and icon_textures.has(imp_icon):
            var tex = icon_textures[imp_icon]
            var icon_rect = Rect2(icon_pos.x - IMPROVEMENT_ICON_SIZE / 2.0, icon_pos.y - IMPROVEMENT_ICON_SIZE / 2.0, IMPROVEMENT_ICON_SIZE, IMPROVEMENT_ICON_SIZE)
            if not has_worker:
                draw_texture_rect(tex, icon_rect, false, Color(0.5, 0.5, 0.5))
            else:
                draw_texture_rect(tex, icon_rect, false)
        else:
            if imp_data.has("color"):
                var c = imp_data["color"]
                var fallback_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
                if not has_worker:
                    fallback_color = Color(0.5, 0.5, 0.5)
                draw_circle(icon_pos, IMPROVEMENT_ICON_SIZE / 2.5, fallback_color)

    # --- Прогресс-бар для сбора дикоросов ---
    if main_map.is_foraging and main_map.foraging_hex.row == row and main_map.foraging_hex.col == col:
        var progress = main_map.foraging_timer / main_map.FORAGING_TIME
        var bar_width = RESOURCE_ICON_SIZE
        var bar_height = 6
        var bar_x = center.x - bar_width / 2.0
        var bar_y = center.y + RESOURCE_ICON_SIZE / 2.0 + 10 # под иконкой ресурса
        draw_rect(Rect2(bar_x, bar_y, bar_width, bar_height), Color(0.2, 0.2, 0.2))
        draw_rect(Rect2(bar_x, bar_y, bar_width * progress, bar_height), Color(0.5, 0.8, 0.2))
        draw_rect(Rect2(bar_x, bar_y, bar_width, bar_height), Color.WHITE, false)

    # --- Прогресс-бар разведки чанка ---
    # Рисуем только ОДИН бар на центральном гексе чанка (с которого началась разведка),
    # чтобы не перегружать карту избыточными барами на каждом гексе чанка.
    if main_map.is_scouting and not main_map.scouting_chunk.is_empty():
        var scout_center_hex = main_map.scouting_chunk[0]
        if scout_center_hex.row == row and scout_center_hex.col == col:
            var scout_progress = clamp(main_map.scouting_timer / (main_map.scouting_chunk.size() * main_map.SCOUTING_TIME_PER_HEX), 0.0, 1.0)
            var scout_bar_width = RESOURCE_ICON_SIZE
            var scout_bar_height = 6
            var scout_bar_x = center.x - scout_bar_width / 2.0
            var scout_bar_y = center.y + RESOURCE_ICON_SIZE / 2.0 + 16 # ниже бара сбора дикоросов
            draw_rect(Rect2(scout_bar_x, scout_bar_y, scout_bar_width, scout_bar_height), Color(0.2, 0.2, 0.2))
            draw_rect(Rect2(scout_bar_x, scout_bar_y, scout_bar_width * scout_progress, scout_bar_height), Color(0.2, 0.7, 0.9))
            draw_rect(Rect2(scout_bar_x, scout_bar_y, scout_bar_width, scout_bar_height), Color.WHITE, false)


func _is_resource_locked(resource_id: String) -> bool:
    if resource_id == null or resource_id == "":
        return false
    var res_data = GameData.raw_resources.get(resource_id, {})
    if not res_data.has("tech_required"):
        return false
    return not CityData.is_tech_unlocked(res_data["tech_required"])

func is_resource_locked(resource_id: String) -> bool:
    return _is_resource_locked(resource_id)

func _draw_all_roads():
    if main_map == null or not main_map.has_method("get"):
        return
    if not main_map.has_node("RoadManager"):
        return

    var road_manager = main_map.get_node("RoadManager")
    var all_segments = road_manager.get_all_road_segments()
    
    if all_segments.is_empty():
        return
    
    for segment_key in all_segments.keys():
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
        
        var points = _generate_natural_road(row1, col1, row2, col2, main_map.HEX_RADIUS)
        draw_polyline(points, Color(0.55, 0.35, 0.15), 6, true)

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

func _draw_exploration_highlights():
    var main = get_parent()
    var expansion_manager = main.get_node("ExpansionManager")
    if not expansion_manager:
        return

    # --- 1. Рисуем слои: не исследован / исследован (всегда) ---
    for row in range(main_map.REGION_ROWS):
        for col in range(main_map.REGION_COLS):
            var tile = tile_data[row][col]
            if tile.get("in_influence", false):
                continue

            var is_explored = tile.get("is_explored", false)

            var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
            center.x += main.offset_x + main.scroll_offset.x
            center.y += main.offset_y + main.scroll_offset.y
            var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)

            if is_explored:
                # Исследован: светло-зелёный + белая рамка
                draw_colored_polygon(vertices, Color(0.652, 0.855, 0.652, 0.25))
                var closed_verts = PackedVector2Array()
                closed_verts.append_array(vertices)
                closed_verts.append(vertices[0])
                draw_polyline(closed_verts, Color.WHITE, 1.5)

    # --- 2. Жёлтая подсветка чанка под мышью (поверх всего) ---
    var chunk = expansion_manager.current_chunk
    if chunk.is_empty():
        return

    for hex in chunk:
        var center = HexUtils.hex_center(hex.row, hex.col, main_map.HEX_RADIUS)
        center.x += main.offset_x + main.scroll_offset.x
        center.y += main.offset_y + main.scroll_offset.y
        var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)
        draw_colored_polygon(vertices, Color(1.0, 1.0, 0.0, 0.3))
        var closed_verts = PackedVector2Array()
        closed_verts.append_array(vertices)
        closed_verts.append(vertices[0])
        draw_polyline(closed_verts, Color.YELLOW, 2.0)

func get_icon_path(icon_name: String) -> String:
    if icon_paths.has(icon_name):
        return icon_paths[icon_name]
    return ""
