# Headless-тест живого обновления расширенного тултипа гекса:
#   godot --headless --path . --script res://tests/test_tooltip_live_refresh.gd
#
# Правило, которое проверяется: расширенный тултип обязан обновляться БЕЗ движения
# мыши, пока на гексе есть то, что меняется со временем. Раньше периодический
# рефреш шёл только по растущим ресурсам (пастбищам), а строки доставки, добавленные
# в расширенный блок, обновления не получали — состояние доставки замирало на
# моменте появления тултипа. Решение «обновлять ли» принимает ЕДИНСТВЕННАЯ точка —
# map_tooltip.has_live_content (растущий ресурс ИЛИ груз на маршруте).
#
# Проверки:
#   1. ГЕКС БЕЗ ГРУЗА. Товара нет, ресурс не растущий → гекс не «живой», рефреша нет.
#   2. ГЕКС С ГРУЗОМ. Как только груз встал на маршрут, гекс становится «живым» —
#      ровно этого не хватало, и из-за этого тултип замирал (дефект).
#   3. ОБНОВЛЕНИЕ МЕНЯЕТ КАРТИНКУ. После шага доставки часть груза уходит в путь,
#      и повторный показ блока даёт другую картинку: к «ожидает отправки» добавляется
#      строка «в пути». Это и есть «актуальное состояние», которого не было.
#   4. ГРУЗ УШЁЛ. Когда маршрут пуст, гекс снова статичен — обновление прекращается.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

var _gdata = null
var _mh = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Автолоады берём узлами дерева: в режиме --script имена GameData и CityData
    # на этапе компиляции этого файла ещё недоступны.
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _mh = load("res://scripts/map_helpers.gd")

    await _test_live_refresh(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("TOOLTIP LIVE REFRESH TEST FAILED")
        quit(1)
    else:
        print("TOOLTIP LIVE REFRESH TEST OK")
        quit(0)


func _test_live_refresh(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var rm = main_map.road_manager
    var tooltip = main_map.map_tooltip
    var dm = main_map.delivery_manager

    # Синтетический НЕрастущий ресурс: у него нет time_to_mature, поэтому «живым»
    # гекс делает именно груз на маршруте, а не наполнение пастбища. Так проверка
    # не зависит от того, куда попал гекс, и от реальных бонусов за воду.
    _gdata.raw_resources["test_grain"] = {
        "id": "test_grain", "name": "Test Grain", "type": "raw",
        "improved_by": "farm", "produces": {"wheat": 10},
    }

    var spot := _find_hex_in_influence(main_map)
    check(not spot.is_empty(),
            "на живой карте должен найтись свободный гекс в влиянии с планом дороги", state)
    if spot.is_empty():
        _free(main_map)
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["resource"] = "test_grain"
    tile["improvement"] = "farm"
    rm.build_road_from(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)

    var route: Dictionary = main_map.get_route_to_city(row, col)
    check(route.get("ok", false), "у улучшения с дорогой должен быть маршрут", state)
    if not route.get("ok", false):
        _free(main_map)
        return

    # --- 1. Гекс без груза и без растущего ресурса — статичен. ---
    dm.clear()
    check(not dm.has_cargo(row, col), "маршрут должен быть пуст перед проверкой", state)
    check(not main_map.has_live_content(row, col),
            "гекс без груза и без растущего ресурса не должен считаться «живым»", state)

    # --- 2. Груз встал на маршрут — гекс обязан стать «живым». ---
    var queued: bool = dm.create_cargo(row, col, "wheat", "common", 20, "test_source")
    check(queued, "груз должен встать на маршрут", state)
    check(dm.has_cargo(row, col), "на маршруте должен появиться груз", state)
    check(main_map.has_live_content(row, col),
            "гекс с грузом на маршруте обязан считаться «живым» (иначе тултип замирает)", state)

    # Тултип показан: расширенный блок привязан к гексу (как после задержки наведения).
    main_map.update_extended_tooltip(row, col)
    var lines_shown: Array = tooltip.delivery_lines(row, col)
    check(lines_shown.size() == 2,
            "сразу после постановки груза ожидается 2 строки (заголовок + ожидание), получено %d"
                    % lines_shown.size(), state)
    var shown_before := _collect_text(tooltip._tooltip_products_container)

    # --- 3. Шаг доставки меняет состояние — и блок обязан это показать. ---
    var status_before: Dictionary = dm.get_route_status(row, col)
    check(int(status_before.get("pending", 0)) == 20,
            "весь груз должен ждать отправки (получено %d)"
                    % int(status_before.get("pending", 0)), state)

    dm.advance(1.0)
    dm.ship()

    var status_after: Dictionary = dm.get_route_status(row, col)
    check(int(status_after.get("pending", 0)) < 20 and int(status_after.get("in_transit", 0)) > 0,
            "после шага доставки груз должен частично уйти в путь (pending=%d, in_transit=%d)"
                    % [int(status_after.get("pending", 0)), int(status_after.get("in_transit", 0))],
            state)

    # Это ровно тот путь, которым пользуется InputHandler на периодическом рефреше.
    main_map.update_tooltip_text(row, col)
    var lines_after: Array = tooltip.delivery_lines(row, col)
    check(lines_after.size() == 3,
            "после отправки должна добавиться строка «в пути» (ожидается 3 строки, получено %d)"
                    % lines_after.size(), state)
    var shown_after := _collect_text(tooltip._tooltip_products_container)
    check(shown_after != shown_before,
            "показанный блок обязан измениться после шага доставки — иначе тултип замер на появлении",
            state)

    # --- 4. Груз убран — гекс снова статичен, рефреш прекращается. ---
    dm.clear()
    check(not dm.has_cargo(row, col), "после очистки маршрут должен быть пуст", state)
    check(not main_map.has_live_content(row, col),
            "после доставки всего груза гекс снова статичен — обновление прекращается", state)

    _free(main_map)


# -------------------------------------------------------
# Хелперы
# -------------------------------------------------------

# Первый свободный гекс в Кольце Влияния: сухой, известный, без улучшения,
# городка и дороги, БЕЗ доступа к пресной воде — И с достижимым планом дороги.
func _find_hex_in_influence(main_map) -> Dictionary:
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[row][col]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if tile.get("has_town", false) or tile.get("decorative", false):
                continue
            if tile.get("in_town_influence", false):
                continue
            if not main_map.is_hex_known(row, col):
                continue
            if _mh.is_water_terrain(tile.get("terrain", "plain")):
                continue
            if _mh.get_hex_water_access(row, col, main_map.tile_data,
                    main_map.map_rows, main_map.map_cols) != "":
                continue
            if main_map.road_manager.get_hex_road_level(row, col) > 0:
                continue
            var plan: Dictionary = main_map.get_road_plan(row, col)
            if not plan.get("ok", false):
                continue
            return {"row": row, "col": col}
    return {}


func _free(main_map) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()


func _collect_text(node: Node) -> String:
    if node == null:
        return ""
    var parts: Array[String] = []
    if node is Label:
        parts.append((node as Label).text)
    elif node is RichTextLabel:
        parts.append(str((node as RichTextLabel).text))
    for child in node.get_children():
        parts.append(_collect_text(child))
    return "\n".join(parts)


func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    print("FAILED: %s" % message)
    push_error("ASSERT: %s" % message)
