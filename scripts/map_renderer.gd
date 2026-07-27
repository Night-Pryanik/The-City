# map_renderer.gd
@tool
extends Node2D

const HEX_RADIUS = 55
const REGION_ROWS = 13
const REGION_COLS = 15
const CITY_ROW = REGION_ROWS / 2
const CITY_COL = REGION_COLS / 2
const CITY_ICON_SIZE = 130
const TERRAIN_ICON_SIZE = 130
const RESOURCE_ICON_SIZE = 60
const IMPROVEMENT_ICON_SIZE = 32
const LOCK_ICON_SIZE = 24

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
    for row in range(REGION_ROWS):
        for col in range(REGION_COLS):
            _draw_hex(row, col)

    var city_center = HexUtils.hex_center(CITY_ROW, CITY_COL, HEX_RADIUS) + Vector2(main_map.offset_x + main_map.scroll_offset.x, main_map.offset_y + main_map.scroll_offset.y)
    if icon_textures.has("city"):
        var tex = icon_textures["city"]
        var icon_rect = Rect2(city_center.x - CITY_ICON_SIZE/2.0, city_center.y - CITY_ICON_SIZE/2.0, CITY_ICON_SIZE, CITY_ICON_SIZE)
        draw_texture_rect(tex, icon_rect, false)
    else:
        draw_colored_polygon(HexUtils.hex_vertices(city_center.x, city_center.y, HEX_RADIUS), Color.YELLOW)

func _draw_hex(row: int, col: int):
    var center = HexUtils.hex_center(row, col, HEX_RADIUS)
    center.x += main_map.offset_x + main_map.scroll_offset.x
    center.y += main_map.offset_y + main_map.scroll_offset.y
    var vertices = HexUtils.hex_vertices(center.x, center.y, HEX_RADIUS)

    var closed_vertices = PackedVector2Array()
    closed_vertices.append_array(vertices)
    closed_vertices.append(vertices[0])

    var tile = tile_data[row][col]
    var in_influence = tile.get("in_influence", false)

    var terrain_color = Color.BLACK
    var terrain = tile.terrain
    var terrain_icon_name = tile.get("terrain_icon", "")

    if row == CITY_ROW and col == CITY_COL:
        if GameData.terrains.has(terrain):
            var t = GameData.terrains[terrain]
            var c = t.get("color", [0, 0, 0])
            terrain_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
        draw_colored_polygon(vertices, terrain_color)
        draw_polyline(closed_vertices, Color.WHITE, 2, true)
        return

    if terrain_icon_name != "" and icon_textures.has(terrain_icon_name):
        var tex = icon_textures[terrain_icon_name]
        var icon_rect = Rect2(center.x - TERRAIN_ICON_SIZE/2.0, center.y - TERRAIN_ICON_SIZE/2.0, TERRAIN_ICON_SIZE, TERRAIN_ICON_SIZE)
        draw_texture_rect(tex, icon_rect, false)
    else:
        if GameData.terrains.has(terrain):
            var t = GameData.terrains[terrain]
            var c = t.get("color", [0, 0, 0])
            terrain_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
        draw_colored_polygon(vertices, terrain_color)

    if not in_influence:
        draw_colored_polygon(vertices, Color(0, 0, 0, 0.5))

    if tile.resource != null:
        var res_data = GameData.raw_resources.get(tile.resource, {})
        var res_icon = res_data.get("icon", "")
        var is_locked = _is_resource_locked(tile.resource)
        if res_icon != "" and icon_textures.has(res_icon):
            var tex = icon_textures[res_icon]
            var icon_rect = Rect2(center.x - RESOURCE_ICON_SIZE/2.0, center.y - RESOURCE_ICON_SIZE/2.0, RESOURCE_ICON_SIZE, RESOURCE_ICON_SIZE)
            draw_texture_rect(tex, icon_rect, false)
        else:
            if res_data.has("color"):
                var c = res_data["color"]
                var fallback_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
                draw_circle(center, RESOURCE_ICON_SIZE / 3.0, fallback_color)
        if is_locked and lock_texture:
            var lock_pos = Vector2(center.x + RESOURCE_ICON_SIZE/2.0 - LOCK_ICON_SIZE/2.0, center.y - RESOURCE_ICON_SIZE/2.0 + LOCK_ICON_SIZE/2.0)
            var lock_rect = Rect2(lock_pos.x, lock_pos.y, LOCK_ICON_SIZE, LOCK_ICON_SIZE)
            draw_texture_rect(lock_texture, lock_rect, false)

        if is_locked and CityData.current_research_tech_id != "":
            var res_tech = res_data.get("tech_required", "")
            if res_tech == CityData.current_research_tech_id:
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
        var imp_data = GameData.improvements.get(tile.improvement, {})
        var imp_icon = imp_data.get("icon", "")
        var small_size = min(IMPROVEMENT_ICON_SIZE * 0.7, 24)
        var icon_pos = Vector2(center.x + HEX_RADIUS / 3.0, center.y - HEX_RADIUS / 2.0)
        if imp_icon != "" and icon_textures.has(imp_icon):
            var tex = icon_textures[imp_icon]
            var icon_rect = Rect2(icon_pos.x, icon_pos.y, small_size, small_size)
            draw_texture_rect(tex, icon_rect, false)
        else:
            if imp_data.has("color"):
                var c = imp_data["color"]
                var fallback_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
                draw_circle(icon_pos + Vector2(small_size/2, small_size/2), small_size / 2.5, fallback_color)

    draw_polyline(closed_vertices, Color.WHITE, 2, true)

func _is_resource_locked(resource_id: String) -> bool:
    if resource_id == null or resource_id == "":
        return false
    var res_data = GameData.raw_resources.get(resource_id, {})
    if not res_data.has("tech_required"):
        return false
    return not CityData.is_tech_unlocked(res_data["tech_required"])

func is_resource_locked(resource_id: String) -> bool:
    return _is_resource_locked(resource_id)
