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
@onready var expansion_button = $HUD/VBoxContainer/ExpansionButton
@onready var pause_menu = $PauseMenu
@onready var build_manager = $BuildManager
@onready var map_renderer = $MapRenderer
@onready var road_manager = $RoadManager
@onready var expansion_manager = $ExpansionManager

func _ready():
    if Engine.is_editor_hint():
        _initialize_map()
        map_renderer.initialize(tile_data, self)
        map_renderer.queue_redraw()
        return

    if SaveManager.is_loaded:
        GameData.load_all_data()
        map_renderer.build_icon_index()
        map_renderer.load_icons()
        SaveManager.apply_loaded_data()

        tile_data = []
        road_manager.initialize(CITY_ROW, CITY_COL)
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
        
        road_manager.rebuild_roads_from_existing(tile_data, REGION_ROWS, REGION_COLS)

        SaveManager.is_loaded = false
        SaveManager.saved_data.clear()
        map_renderer.initialize(tile_data, self)
    else:
        randomize()
        _initialize_map()
        road_manager.initialize(CITY_ROW, CITY_COL)
        map_renderer.initialize(tile_data, self)

    _calc_offsets()
    map_renderer.queue_redraw()

    popup_menu.id_pressed.connect(_on_popup_menu_id_pressed)
    city_ui.closed.connect(_on_city_ui_close)
    city_button.pressed.connect(_on_city_button_pressed)
    expansion_button.pressed.connect(_on_expansion_button_pressed)
    city_ui.build_requested.connect(CityData.request_build)
    CityData.city_updated.connect(_on_city_data_updated)
    CityData.research_error.connect(_on_research_error)
    CityData.research_error.connect(hud.show_message)
    city_ui.research_requested.connect(CityData.start_research)
    CityData.research_completed.connect(_on_research_completed)

    if pause_menu:
        if not pause_menu.save_pressed.is_connected(_on_pause_save):
            pause_menu.save_pressed.connect(_on_pause_save)
        if not pause_menu.load_pressed.is_connected(_on_pause_load):
            pause_menu.load_pressed.connect(_on_pause_load)
        if not pause_menu.new_game_pressed.is_connected(_on_pause_new_game):
            pause_menu.new_game_pressed.connect(_on_pause_new_game)

    build_manager.build_message.connect(hud.show_message)
    build_manager.build_completed.connect(_on_build_completed)
    city_button.gui_input.connect(_on_city_button_gui_input)

    # Сигналы от ExpansionManager
    expansion_manager.expansion_mode_changed.connect(_on_expansion_mode_changed)
    expansion_manager.territory_expanded.connect(_on_territory_expanded)

func _initialize_map():
    GameData.load_all_data()
    CityData.setup()
    map_renderer.build_icon_index()
    map_renderer.load_icons()

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
    if CityData.current_research_tech_id != "" or build_manager.active_builds.size() > 0:
        map_renderer.queue_redraw()

    if city_ui.visible or popup_menu.visible or pause_menu.visible:
        _hide_tooltip()
        return

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
            var max_scroll_x = (REGION_COLS * HEX_RADIUS)
            var max_scroll_y = (REGION_ROWS * HEX_RADIUS)
            scroll_offset.x = clamp(scroll_offset.x, -max_scroll_x, max_scroll_x)
            scroll_offset.y = clamp(scroll_offset.y, -max_scroll_y, max_scroll_y)
            map_renderer.queue_redraw()

    if hud.get_global_rect().has_point(get_global_mouse_position()):
        _hide_tooltip()
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

func _input(event):
    if Engine.is_editor_hint():
        return

    if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
        if city_ui.visible:
            city_ui.close_city()
        elif pause_menu.visible:
            pause_menu.hide()
            city_button.disabled = false
            expansion_button.disabled = false
        elif expansion_manager.is_active():
            expansion_manager.toggle()
            return
        else:
            pause_menu.show()
            city_button.disabled = true
            expansion_button.disabled = true
        return

    if city_ui.visible or pause_menu.visible:
        return

    if expansion_manager.is_active():
        if event is InputEventMouseButton:
            if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
                if popup_menu.visible:
                    popup_menu.hide()
                    return
                var mouse_pos = event.global_position
                var hex = pixel_to_hex(mouse_pos.x, mouse_pos.y)
                if hex != null and not tile_data[hex.row][hex.col]["in_influence"]:
                    # Вычисляем доступную еду для отображения в меню
                    var available_food = 0
                    if CityData:
                        for pid in CityData.city_food_pool:
                            if CityData.city_food_pool[pid]:
                                available_food += CityData.city_storage.get(pid, 0)
                    expansion_manager.show_context_menu(hex.row, hex.col, mouse_pos, available_food)
                    return

            if event.button_index == MOUSE_BUTTON_LEFT:
                if event.pressed:
                    drag_start_scroll_offset = scroll_offset
                    drag_start_mouse = event.global_position
                    is_dragging = false
                else:
                    if is_dragging:
                        is_dragging = false
                return

        if event is InputEventMouseMotion:
            if _tooltip_visible:
                _hide_tooltip()

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

        if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
            var mouse_pos = event.global_position
            if not is_dragging:
                if (mouse_pos - drag_start_mouse).length() > 1.0:
                    is_dragging = true
            if is_dragging:
                var delta = mouse_pos - drag_start_mouse
                scroll_offset = drag_start_scroll_offset + delta
                var max_scroll_x = (REGION_COLS * HEX_RADIUS)
                var max_scroll_y = (REGION_ROWS * HEX_RADIUS)
                scroll_offset.x = clamp(scroll_offset.x, -max_scroll_x, max_scroll_x)
                scroll_offset.y = clamp(scroll_offset.y, -max_scroll_y, max_scroll_y)
                map_renderer.queue_redraw()
                return

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
            if map_renderer.is_resource_locked(tile.resource):
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
    var meta = popup_menu.get_item_metadata(id)
    var action = meta.get("action", "")

    if action == "expand_territory":
        var success = expansion_manager.handle_action(meta["row"], meta["col"], meta["cost"])
        if success:
            map_renderer.queue_redraw()
        return

    if _context_hex == null:
        return
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
    map_renderer.queue_redraw()

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
    
    road_manager.build_road_from(row, col, tile_data, REGION_ROWS, REGION_COLS)
    
    map_renderer.queue_redraw()

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
    map_renderer.queue_redraw()

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

func _on_city_button_gui_input(event: InputEvent):
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
        scroll_offset = - (HexUtils.hex_center(CITY_ROW, CITY_COL, HEX_RADIUS) + Vector2(offset_x, offset_y) - get_viewport_rect().size / 2.0)
        map_renderer.queue_redraw()

func _on_expansion_button_pressed():
    var active = expansion_manager.toggle()
    if active:
        hud.show_message("Режим освоения включён. ПКМ по гексу для покупки.")
    else:
        hud.show_message("Режим освоения выключен.")

func _on_expansion_mode_changed(active: bool):
    map_renderer.queue_redraw()

func _on_territory_expanded(row: int, col: int, cost: int):
    hud.show_message("Территория расширена! (%d еды)" % cost)
    map_renderer.queue_redraw()
    # Также обновим интерфейс города, если он открыт
    if city_ui.visible:
        city_ui.update_data(CityData.city_storage, CityData.production_rates, CityData.consumption_rates, CityData.city_food_pool, GameData.buildings, GameData.crafts, CityData.city_built_buildings, GameData.products, GameData.categories)

func is_expansion_mode_active() -> bool:
    return expansion_manager.is_active()
