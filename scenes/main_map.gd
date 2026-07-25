@tool
extends Node2D

const HEX_RADIUS = 55
const GRID_ROWS = 9
const GRID_COLS = 11
const REGION_ROWS = 13
const REGION_COLS = 15
const CITY_ROW = REGION_ROWS / 2
const CITY_COL = REGION_COLS / 2
const INFLUENCE_START_ROW = 2
const INFLUENCE_END_ROW = 10
const INFLUENCE_START_COL = 2
const INFLUENCE_END_COL = 12

const CITY_ICON_SIZE = 130
const TERRAIN_ICON_SIZE = 130
const RESOURCE_ICON_SIZE = 60
const IMPROVEMENT_ICON_SIZE = 32
const TOOLTIP_DELAY = 0.5
const LOCK_ICON_SIZE = 24
const SCROLL_SPEED = 300.0
const SCROLL_MARGIN = 30
const PRODUCTION_INTERVAL = 2.0

var tile_data = []
var offset_x: float = 0.0
var offset_y: float = 0.0
var scroll_offset = Vector2.ZERO
var icon_textures = {}
var lock_texture = null
var icon_paths = {}

var _context_hex = null
var last_city_click_time = 0.0
var _hovered_hex = null
var _hover_start_time = 0.0
var _tooltip_visible = false
var production_timer = 0.0

var is_dragging = false
var drag_start_scroll_offset = Vector2.ZERO
var drag_start_mouse = Vector2.ZERO

@onready var popup_menu = $PopupMenu
@onready var city_ui = $CityUI
@onready var hex_tooltip = $HexTooltip
@onready var tooltip_label = $HexTooltip/Label
@onready var hud = $HUD
@onready var city_button = $HUD/VBoxContainer/CityButton
@onready var pause_menu = $PauseMenu
@onready var build_manager = $BuildManager

func _ready():
    _build_icon_index()
    if Engine.is_editor_hint():
        _initialize_map()
        queue_redraw()
        return

    if SaveManager.is_loaded:
        GameData.load_all_data()
        _load_icons()
        # Применяем загруженные данные к CityData (склад, технологии и т.д.)
        SaveManager.apply_loaded_data()

        # Восстанавливаем tile_data из сохранения
        tile_data = []
        var saved_tiles = SaveManager.saved_data.get("tile_data", [])
        for row in range(REGION_ROWS):
            var col_array = []
            for col in range(REGION_COLS):
                var tile = {"terrain": "plain", "resource": null, "improvement": null, "terrain_icon": "", "in_influence": false}
                if row < saved_tiles.size() and col < saved_tiles[row].size():
                    var saved = saved_tiles[row][col]
                    if not saved.is_empty():
                        tile["terrain"] = saved.get("terrain", "plain")
                        tile["resource"] = saved.get("resource")
                        tile["improvement"] = saved.get("improvement")
                        tile["terrain_icon"] = saved.get("terrain_icon", "")
                        tile["in_influence"] = saved.get("in_influence", false)
                col_array.append(tile)
            tile_data.append(col_array)

        SaveManager.is_loaded = false
        SaveManager.saved_data.clear()
    else:
        randomize()
        _initialize_map()

    _calc_offsets()
    queue_redraw()

    popup_menu.id_pressed.connect(_on_popup_menu_id_pressed)
    city_ui.closed.connect(_on_city_ui_close)
    city_button.pressed.connect(_on_city_button_pressed)
    city_ui.build_requested.connect(CityData.request_build)
    CityData.city_updated.connect(_on_city_data_updated)
    CityData.research_error.connect(_on_research_error)
    CityData.research_error.connect(hud.show_message)
    city_ui.research_requested.connect(CityData.start_research)
    CityData.research_completed.connect(_on_research_completed)
    city_button.gui_input.connect(_on_city_button_gui_input)

    if pause_menu:
        if not pause_menu.save_pressed.is_connected(_on_pause_save):
            pause_menu.save_pressed.connect(_on_pause_save)
        if not pause_menu.load_pressed.is_connected(_on_pause_load):
            pause_menu.load_pressed.connect(_on_pause_load)
        if not pause_menu.new_game_pressed.is_connected(_on_pause_new_game):
            pause_menu.new_game_pressed.connect(_on_pause_new_game)

    build_manager.build_message.connect(hud.show_message)
    build_manager.build_completed.connect(_on_build_completed)

func _initialize_map():
    GameData.load_all_data()
    CityData.setup()
    _load_icons()

    var generator = load("res://scripts/map_generator.gd").new()
    var terrain_counts = {
        "plain": 4,
        "hill": 3,
        "forest": 3,
        "mountain": 2
    }
    tile_data = generator.generate_map(REGION_ROWS, REGION_COLS, CITY_ROW, CITY_COL, GameData.raw_resources, terrain_counts)
    print("Регион сгенерирован. Гексов: ", REGION_ROWS * REGION_COLS)

    for row in range(REGION_ROWS):
        for col in range(REGION_COLS):
            var tile = tile_data[row][col]
            tile["in_influence"] = (row >= INFLUENCE_START_ROW and row <= INFLUENCE_END_ROW and col >= INFLUENCE_START_COL and col <= INFLUENCE_END_COL)

    _ensure_minimum_resource("animals")
    _ensure_minimum_resource("plants")
    _ensure_minimum_resource("minerals")

    var influence_resource_types = {}
    for row in range(INFLUENCE_START_ROW, INFLUENCE_END_ROW + 1):
        for col in range(INFLUENCE_START_COL, INFLUENCE_END_COL + 1):
            var res = tile_data[row][col]["resource"]
            if res != null:
                influence_resource_types[res] = true

    for row in range(REGION_ROWS):
        for col in range(REGION_COLS):
            if not tile_data[row][col]["in_influence"]:
                var res = tile_data[row][col]["resource"]
                if res != null and influence_resource_types.has(res):
                    tile_data[row][col]["resource"] = null

    for row in range(REGION_ROWS):
        for col in range(REGION_COLS):
            var tile = tile_data[row][col]
            var terrain_id = tile.terrain
            if GameData.terrains.has(terrain_id):
                var t = GameData.terrains[terrain_id]
                if t.has("icons"):
                    var icons_array = t.icons
                    if icons_array.size() > 0:
                        seed(row * 1000 + col)
                        var idx = randi() % icons_array.size()
                        tile["terrain_icon"] = icons_array[idx]
                elif t.has("icon"):
                    tile["terrain_icon"] = t.icon
                else:
                    tile["terrain_icon"] = ""

func _ensure_minimum_resource(category: String):
    for row in range(INFLUENCE_START_ROW, INFLUENCE_END_ROW + 1):
        for col in range(INFLUENCE_START_COL, INFLUENCE_END_COL + 1):
            var res = tile_data[row][col]["resource"]
            if res != null and GameData.raw_resources[res].get("category", "") == category:
                return
    var possible = []
    for row in range(INFLUENCE_START_ROW, INFLUENCE_END_ROW + 1):
        for col in range(INFLUENCE_START_COL, INFLUENCE_END_COL + 1):
            if tile_data[row][col]["resource"] != null:
                continue
            var terrain_id = tile_data[row][col]["terrain"]
            for res_id in GameData.raw_resources:
                if GameData.raw_resources[res_id].get("category", "") != category:
                    continue
                if terrain_id in GameData.raw_resources[res_id].get("allowed_terrains", []):
                    possible.append({"row": row, "col": col, "id": res_id})
                    break
    if possible.size() > 0:
        var chosen = possible[randi() % possible.size()]
        tile_data[chosen.row][chosen.col]["resource"] = chosen.id

func _load_icons():
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

func _calc_offsets():
    var min_x = INF
    var max_x = -INF
    var min_y = INF
    var max_y = -INF
    for row in range(INFLUENCE_START_ROW, INFLUENCE_END_ROW + 1):
        for col in range(INFLUENCE_START_COL, INFLUENCE_END_COL + 1):
            var center = HexUtils.hex_center(row, col, HEX_RADIUS)
            min_x = min(min_x, center.x - HEX_RADIUS)
            max_x = max(max_x, center.x + HEX_RADIUS)
            min_y = min(min_y, center.y - HEX_RADIUS)
            max_y = max(max_y, center.y + HEX_RADIUS)
    var grid_width = max_x - min_x
    var grid_height = max_y - min_y
    var viewport_size = Vector2(1152, 768)
    if not Engine.is_editor_hint():
        viewport_size = get_viewport_rect().size
    offset_x = (viewport_size.x - grid_width) / 2.0 - min_x
    offset_y = (viewport_size.y - grid_height) / 2.0 - min_y

func _process(delta):
    if Engine.is_editor_hint():
        return

    production_timer += delta
    if production_timer >= CityData.PRODUCTION_INTERVAL:
        production_timer -= CityData.PRODUCTION_INTERVAL
        CityData.reset_counters()
        for row in range(REGION_ROWS):
            for col in range(REGION_COLS):
                var tile = tile_data[row][col]
                if tile.improvement != null and tile.resource != null:
                    CityData.add_raw_production(tile.resource)
        CityData.do_tick()

    CityData.tick_research(delta)
    if CityData.current_research_tech_id != "":
        queue_redraw()
        
    # Перерисовка, если есть активные стройки (для анимации прогресс-бара)
    if build_manager.active_builds.size() > 0:
        queue_redraw()

    if city_ui.visible or popup_menu.visible or pause_menu.visible:
        _hide_tooltip()
        return

    # Скролл краями (только если не перетаскиваем)
    if not is_dragging:
        var mouse_pos = get_viewport().get_mouse_position()
        var viewport_size = get_viewport_rect().size
        var inside = mouse_pos.x >= 0 and mouse_pos.x <= viewport_size.x and mouse_pos.y >= 0 and mouse_pos.y <= viewport_size.y
        var scroll = Vector2.ZERO
        if inside:
            if mouse_pos.x < SCROLL_MARGIN:
                scroll.x = SCROLL_SPEED * delta
            elif mouse_pos.x > viewport_size.x - SCROLL_MARGIN:
                scroll.x = -SCROLL_SPEED * delta
            if mouse_pos.y < SCROLL_MARGIN:
                scroll.y = SCROLL_SPEED * delta
            elif mouse_pos.y > viewport_size.y - SCROLL_MARGIN:
                scroll.y = -SCROLL_SPEED * delta

        if scroll != Vector2.ZERO:
            scroll_offset += scroll
            queue_redraw()

    # Тултип
    if _hovered_hex != null:
        _hover_start_time += delta
        if _hover_start_time >= TOOLTIP_DELAY and not _tooltip_visible:
            _tooltip_visible = true
            hex_tooltip.visible = true
        if _tooltip_visible:
            var tip_pos = get_viewport().get_mouse_position() + Vector2(15, 15)
            var text_size = tooltip_label.get_minimum_size()
            hex_tooltip.size = text_size + Vector2(12, 8)
            tooltip_label.position = Vector2(6, 4)
            if tip_pos.x + hex_tooltip.size.x > get_viewport_rect().size.x:
                tip_pos.x = get_viewport().get_mouse_position().x - hex_tooltip.size.x - 15
            if tip_pos.y + hex_tooltip.size.y > get_viewport_rect().size.y:
                tip_pos.y = get_viewport().get_mouse_position().y - hex_tooltip.size.y - 15
            tip_pos.x = max(0, tip_pos.x)
            tip_pos.y = max(0, tip_pos.y)
            hex_tooltip.position = tip_pos
    else:
        _hide_tooltip()

func _on_city_button_gui_input(event: InputEvent):
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
        scroll_offset = - (HexUtils.hex_center(CITY_ROW, CITY_COL, HEX_RADIUS) + Vector2(offset_x, offset_y) - get_viewport_rect().size / 2.0)
        queue_redraw()

func _input(event):
    if Engine.is_editor_hint():
        return

    # Esc
    if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
        if city_ui.visible:
            city_ui.close_city()
        elif pause_menu.visible:
            pause_menu.hide()
            city_button.disabled = false
        else:
            pause_menu.show()
            city_button.disabled = true
        return

    if city_ui.visible or pause_menu.visible: return

    if event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_LEFT:
            if event.pressed:
                drag_start_scroll_offset = scroll_offset
                drag_start_mouse = event.global_position
                is_dragging = false
            else:
                if is_dragging:
                    is_dragging = false
                    return

        if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
            if popup_menu.visible:
                popup_menu.hide()
                _hide_tooltip()
                return
            var mouse_pos = event.global_position
            var hex = pixel_to_hex(mouse_pos.x, mouse_pos.y)
            if hex != null and tile_data[hex.row][hex.col]["in_influence"]:
                _show_context_menu(hex.row, hex.col, mouse_pos)
                _hide_tooltip()

        if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
            if popup_menu.visible:
                popup_menu.hide()
                _hide_tooltip()
                return
            var mouse_pos = event.global_position
            var hex = pixel_to_hex(mouse_pos.x, mouse_pos.y)
            if hex != null and tile_data[hex.row][hex.col]["in_influence"]:
                if hex.row == CITY_ROW and hex.col == CITY_COL:
                    var cur_time = Time.get_ticks_msec() / 1000.0
                    if cur_time - last_city_click_time < 0.5:
                        _open_city()
                    last_city_click_time = cur_time

    if event is InputEventMouseMotion:
        if city_ui.visible or popup_menu.visible or pause_menu.visible:
            return

        # Перетаскивание левой кнопкой
        if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
            var mouse_pos = event.global_position
            if not is_dragging:
                if (mouse_pos - drag_start_mouse).length() > 1.0:
                    is_dragging = true
            if is_dragging:
                var delta = mouse_pos - drag_start_mouse
                scroll_offset = drag_start_scroll_offset + delta
                queue_redraw()
                return

        # Обычное движение мыши (тултип)
        var hex = pixel_to_hex(event.global_position.x, event.global_position.y)
        if hex != _hovered_hex:
            _hovered_hex = hex
            _hover_start_time = 0.0
            if _tooltip_visible:
                hex_tooltip.visible = false
                _tooltip_visible = false
            if hex != null:
                _update_tooltip_text(hex.row, hex.col)

func _update_tooltip_text(row: int, col: int):
    var tile = tile_data[row][col]
    var terrain_name = GameData.terrains.get(tile.terrain, {}).get("name", tile.terrain)
    var res_id = tile.resource
    var res_name = GameData.raw_resources.get(res_id, {}).get("name", "нет") if res_id != null else "нет"
    var imp_name = GameData.improvements.get(tile.improvement, {}).get("name", "нет") if tile.improvement != null else "нет"
    var locked = ""
    if res_id != null:
        var res_data = GameData.raw_resources.get(res_id, {})
        if res_data.has("tech_required") and not CityData.is_tech_unlocked(res_data["tech_required"]):
            locked = " (заблокировано)"
    tooltip_label.text = "Местность: %s\nРесурс: %s%s\nУлучшение: %s" % [terrain_name, res_name, locked, imp_name]

func _hide_tooltip():
    hex_tooltip.visible = false
    _tooltip_visible = false
    _hovered_hex = null
    _hover_start_time = 0.0

func _is_resource_locked(resource_id: String) -> bool:
    if resource_id == null or resource_id == "":
        return false
    var res_data = GameData.raw_resources.get(resource_id, {})
    if not res_data.has("tech_required"):
        return false
    return not CityData.is_tech_unlocked(res_data["tech_required"])

func _show_context_menu(row: int, col: int, click_pos: Vector2):
    var tile = tile_data[row][col]
    if tile.improvement != null:
        return

    var available_food = 0
    if CityData:
        for pid in CityData.city_food_pool:
            if CityData.city_food_pool[pid]:
                available_food += CityData.city_storage.get(pid, 0)

    _context_hex = {"row": row, "col": col, "resource": tile.resource}
    popup_menu.clear()

    if tile.resource != null:
        var raw = GameData.raw_resources.get(tile.resource, {})
        if "improved_by" in raw:
            if _is_resource_locked(tile.resource):
                var tech_id = raw["tech_required"]
                var tech_name = tech_id
                var tech_cost = 0
                for tech in GameData.technologies:
                    if tech["id"] == tech_id:
                        tech_name = tech["name"]
                        tech_cost = tech.get("cost_food", 0)
                        break
                var label = "Изучить %s [еды: %d/%d]" % [tech_name, available_food, tech_cost]
                popup_menu.add_item(label)
                var last_idx = popup_menu.item_count - 1
                popup_menu.set_item_metadata(last_idx, {"action": "research_tech", "tech_id": tech_id})
            else:
                var imp_id = raw.improved_by
                var imp_data = GameData.improvements.get(imp_id, {})
                var imp_name = imp_data.get("name", imp_id)
                var cost = imp_data.get("cost_food", 0)
                var time = imp_data.get("build_time", 0)
                var label = "Построить %s (%s) [еды: %d/%d, %d сек.]" % [imp_name, raw.get("name", tile.resource), available_food, cost, int(time)]
                popup_menu.add_item(label)
                var last_idx = popup_menu.item_count - 1
                popup_menu.set_item_metadata(last_idx, {"action": "build_improvement", "imp_id": imp_id, "animal_id": tile.resource})

    if tile.resource == null and CityData:
        if CityData.domesticated_animals.size() > 0:
            for animal_id in CityData.domesticated_animals:
                var animal_data = GameData.raw_resources.get(animal_id, {})
                if tile.terrain in animal_data.get("allowed_terrains", []):
                    var animal_name = animal_data.get("name", animal_id)
                    var imp_data = GameData.improvements.get("pasture", {})
                    var cost = imp_data.get("cost_food", 0)
                    var time = imp_data.get("build_time", 0)
                    var label = "Построить пастбище (%s) [еды: %d/%d, %d сек.]" % [animal_name, available_food, cost, int(time)]
                    popup_menu.add_item(label)
                    var last_idx = popup_menu.item_count - 1
                    popup_menu.set_item_metadata(last_idx, {"action": "build_pasture", "animal_id": animal_id})
        if CityData.domesticated_plants.size() > 0:
            for plant_id in CityData.domesticated_plants:
                var plant_data = GameData.raw_resources.get(plant_id, {})
                if tile.terrain in plant_data.get("allowed_terrains", []):
                    var plant_name = plant_data.get("name", plant_id)
                    var imp_data = GameData.improvements.get("farm", {})
                    var cost = imp_data.get("cost_food", 0)
                    var time = imp_data.get("build_time", 0)
                    var label = "Построить ферму (%s) [еды: %d/%d, %d сек.]" % [plant_name, available_food, cost, int(time)]
                    popup_menu.add_item(label)
                    var last_idx = popup_menu.item_count - 1
                    popup_menu.set_item_metadata(last_idx, {"action": "build_farm", "plant_id": plant_id})

    if popup_menu.item_count > 0:
        popup_menu.position = click_pos
        popup_menu.popup()

func _on_popup_menu_id_pressed(id: int):
    if _context_hex == null:
        return
    var meta = popup_menu.get_item_metadata(id)
    var action = meta.get("action", "")
    var row = _context_hex.row
    var col = _context_hex.col

    if action == "build_improvement":
        var imp_id = meta.imp_id
        var animal_id = meta.get("animal_id", null)
        build_manager.start_build(row, col, imp_id, animal_id)
    elif action == "build_pasture":
        var animal_id = meta.animal_id
        build_manager.start_build(row, col, "pasture", animal_id)
    elif action == "build_farm":
        var plant_id = meta.plant_id
        build_manager.start_build(row, col, "farm", plant_id)
    elif action == "research_tech":
        var tech_id = meta.tech_id
        CityData.start_research(tech_id)

    _context_hex = null
    queue_redraw()

func _on_build_completed(row: int, col: int, imp_id: String, animal_id = null):
    var tile = tile_data[row][col]
    tile.improvement = imp_id
    if animal_id != null:
        tile.resource = animal_id
        if CityData:
            if GameData.raw_resources.has(animal_id) and GameData.raw_resources[animal_id].get("category") == "animals":
                CityData.add_animal(animal_id)
            elif GameData.raw_resources.has(animal_id) and GameData.raw_resources[animal_id].get("category") == "plants":
                CityData.add_plant(animal_id)
    build_manager.remove_build(row, col)
    queue_redraw()

func pixel_to_hex(mx: float, my: float):
    for row in range(REGION_ROWS):
        for col in range(REGION_COLS):
            var center = HexUtils.hex_center(row, col, HEX_RADIUS)
            center.x += offset_x + scroll_offset.x
            center.y += offset_y + scroll_offset.y
            var verts = HexUtils.hex_vertices(center.x, center.y, HEX_RADIUS)
            if HexUtils.point_in_polygon(mx, my, verts):
                return {"row": row, "col": col}
    return null

func _draw():
    for row in range(REGION_ROWS):
        for col in range(REGION_COLS):
            _draw_hex(row, col)

    var city_center = HexUtils.hex_center(CITY_ROW, CITY_COL, HEX_RADIUS) + Vector2(offset_x + scroll_offset.x, offset_y + scroll_offset.y)
    if icon_textures.has("city"):
        var tex = icon_textures["city"]
        var icon_rect = Rect2(city_center.x - CITY_ICON_SIZE/2.0, city_center.y - CITY_ICON_SIZE/2.0, CITY_ICON_SIZE, CITY_ICON_SIZE)
        draw_texture_rect(tex, icon_rect, false)
    else:
        draw_colored_polygon(HexUtils.hex_vertices(city_center.x, city_center.y, HEX_RADIUS), Color.YELLOW)

func _draw_hex(row: int, col: int):
    var center = HexUtils.hex_center(row, col, HEX_RADIUS)
    center.x += offset_x + scroll_offset.x
    center.y += offset_y + scroll_offset.y
    var vertices = HexUtils.hex_vertices(center.x, center.y, HEX_RADIUS)

    var closed_vertices = PackedVector2Array()
    closed_vertices.append_array(vertices)
    closed_vertices.append(vertices[0])

    var tile = tile_data[row][col]
    var in_influence = tile.get("in_influence", false)

    if row == CITY_ROW and col == CITY_COL:
        var terrain_color = Color.BLACK
        var terrain = tile.terrain
        if GameData.terrains.has(terrain):
            var t = GameData.terrains[terrain]
            var c = t.get("color", [0, 0, 0])
            terrain_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
        draw_colored_polygon(vertices, terrain_color)
        draw_polyline(closed_vertices, Color.WHITE, 2, true)
        return

    var terrain_color = Color.BLACK
    var terrain = tile.terrain
    var terrain_icon_name = tile.get("terrain_icon", "")
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

    if build_manager.is_building(row, col):
        var progress_data = build_manager.get_progress(row, col)
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

func _open_city():
    city_ui.update_data(CityData.city_storage, CityData.production_rates, CityData.consumption_rates, CityData.city_food_pool, GameData.buildings, GameData.crafts, CityData.city_built_buildings, GameData.products, GameData.categories)
    city_ui.show()
    city_ui.show_resources_tab()
    hud.hide()

func _on_city_button_pressed():
    if pause_menu.visible:
        return
    city_button.disabled = false
    _open_city()

func _on_city_ui_close():
    city_ui.hide()
    hud.show()

func _on_city_data_updated():
    if city_ui.visible:
        city_ui.update_data(CityData.city_storage, CityData.production_rates, CityData.consumption_rates, CityData.city_food_pool, GameData.buildings, GameData.crafts, CityData.city_built_buildings, GameData.products, GameData.categories)

func _on_research_error(message: String):
    if city_ui.visible:
        city_ui.set_message(message)
    else:
        hud.show_message(message)

func _on_research_completed(_tech_id: String):
    if city_ui.visible:
        city_ui.update_data(CityData.city_storage, CityData.production_rates, CityData.consumption_rates, CityData.city_food_pool, GameData.buildings, GameData.crafts, CityData.city_built_buildings, GameData.products, GameData.categories)
    queue_redraw()

func _on_pause_save():
    SaveManager.save_game()

func _on_pause_load():
    if SaveManager.load_game():
        get_tree().reload_current_scene()
    else:
        print("Ошибка загрузки сохранения")

func _on_pause_new_game():
    SaveManager.new_game()
    get_tree().change_scene_to_file("res://scenes/MainMap.tscn")

func get_tile_data(row: int, col: int):
    if row >= 0 and row < tile_data.size() and col >= 0 and col < tile_data[row].size():
        return tile_data[row][col]
    return null

func _build_icon_index():
    icon_paths.clear()
    _scan_folder("res://icons")

func _scan_folder(folder_path: String):
    var dir = DirAccess.open(folder_path)
    if dir == null:
        return
    dir.list_dir_begin()
    var file_name = dir.get_next()
    while file_name != "":
        if dir.current_is_dir():
            _scan_folder(folder_path.path_join(file_name))
        else:
            var full_path = folder_path.path_join(file_name)
            if icon_paths.has(file_name):
                print("Предупреждение: дубликат иконки ", file_name, " – ", full_path)
            icon_paths[file_name] = full_path
        file_name = dir.get_next()
    dir.list_dir_end()
