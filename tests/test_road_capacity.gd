# Headless-тест пропускной способности дороги: маршрут до города ограничивает,
# сколько ресурсов улучшения доезжает до склада (road_manager.find_route_to_city,
# main_map._emit_continuous_production, map_tooltip, map_renderer).
#   godot --headless --path . --script res://tests/test_road_capacity.gd
#
# Проверки:
#   1. КЛАМП. _emit_continuous_production не пускает на склад больше средней
#      скорости маршрута; излишек теряется. Производительность, равная скорости
#      маршрута, проходит целиком; без маршрута (avg_speed < 0) ограничения нет.
#   2. ПО РЕСУРСАМ. У одного улучшения разные продукты ограничиваются
#      НЕЗАВИСИМО: при скорости маршрута 10 ед./сек продукт 10 ед./сек проходит,
#      а продукт 20 ед./сек — нет. Это тот случай, ради которого пометка
#      выводится отдельно для каждого продукта.
#   3. ФЛАГ И ТУЛТИП. У улучшения с перегрузкой маршрута tile.road_capacity_short
#      выставлен, а расширенный тултип и левая колонка панели показывают красную
#      пометку «(маршрут X ед./сек)» только у перегруженного продукта.
#   4. УЛУЧШЕНИЕ ДОРОГИ СНИМАЕТ ПЕРЕГРУЗКУ. После подъёма всего маршрута до
#      уровня 2 (30 ед./сек) пометка исчезает и флаг сбрасывается.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

var _gdata = null
var _cdata = null
var _mh = null
var _hu = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Автолоады берём узлами дерева: в режиме --script имена GameData и CityData
    # на этапе компиляции этого файла ещё недоступны.
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _mh = load("res://scripts/map_helpers.gd")
    _hu = load("res://scripts/HexUtils.gd")

    await _test_live_scene(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("ROAD CAPACITY TEST FAILED")
        quit(1)
    else:
        print("ROAD CAPACITY TEST OK")
        quit(0)


# -------------------------------------------------------
# 1. Кламп: скорость маршрута ограничивает выпуск
# -------------------------------------------------------

func _test_clamp(main_map, state: Dictionary) -> void:
    # 15 пшеницы и 5 клея в секунду по маршруту 10 ед./сек: пшеница обрезается до
    # 10, клей проходит целиком. Клей выбран потому, что он всегда доступен
    # (нет unlock_tech) — тест не зависит от изученных технологий.
    _cdata.city_storage["wheat"] = 0
    _cdata.city_storage["clay"] = 0
    var tile := {"production_fractional_remainder": 0.0}
    main_map._emit_continuous_production(tile, {"wheat": 15, "clay": 5}, 1.0, 1.0,
            "common", "test_source", 10.0)
    check(int(_cdata.city_storage.get("wheat", 0)) == 10,
            "по маршруту 10 ед./сек должно доехать 10 пшеницы из 15 (получено %d)"
                    % int(_cdata.city_storage.get("wheat", 0)), state)
    check(int(_cdata.city_storage.get("clay", 0)) == 5,
            "клей 5 ед./сек проходит по маршруту 10 ед./сек целиком (получено %d)"
                    % int(_cdata.city_storage.get("clay", 0)), state)

    # Равенство — не перегрузка: производительность, равная скорости маршрута,
    # доходит до города в полном объёме.
    _cdata.city_storage["wheat"] = 0
    var tile2 := {"production_fractional_remainder": 0.0}
    main_map._emit_continuous_production(tile2, {"wheat": 10}, 1.0, 1.0,
            "common", "test_source", 10.0)
    check(int(_cdata.city_storage.get("wheat", 0)) == 10,
            "производительность, равная скорости маршрута, должна доходить целиком", state)

    # Нет маршрута (avg_speed < 0) — ограничения нет: дорога ничего не везёт,
    # и ограничивать нечем.
    _cdata.city_storage["wheat"] = 0
    var tile3 := {"production_fractional_remainder": 0.0}
    main_map._emit_continuous_production(tile3, {"wheat": 15}, 1.0, 1.0,
            "common", "test_source", -1.0)
    check(int(_cdata.city_storage.get("wheat", 0)) == 15,
            "без маршрута ограничения быть не должно: все 15 пшеницы доходят", state)


# -------------------------------------------------------
# 2-4. Живая сцена: по ресурсам, флаг, тултип, улучшение дороги
# -------------------------------------------------------

func _test_live_scene(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    if WATCHDOG.wants_case("clamp"):
        _test_clamp(main_map, state)

    var rm = main_map.road_manager
    var wm = main_map.worker_manager
    # Тип не указываем: в режиме --script имя класса MapTooltip на этапе
    # компиляции ещё не в кеше.
    var tooltip = main_map.map_tooltip
    var panel = main_map.control_panel

    # Синтетический ресурс с управляемыми скоростями: реальные данные кладут
    # бонус за пресную воду на ферму (×1.5), и тест зависел бы от того, куда
    # попал гекс. Продукты — всегда доступные wheat и clay (без unlock_tech).
    _gdata.raw_resources["test_grain"] = {
        "id": "test_grain", "name": "Test Grain", "type": "raw",
        "improved_by": "farm", "produces": {"wheat": 10, "clay": 20},
    }

    var spot := _find_hex_in_influence(main_map)
    check(not spot.is_empty(),
            "на живой карте должен найтись свободный гекс в влиянии без воды", state)
    if spot.is_empty():
        _free(main_map)
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["resource"] = "test_grain"
    tile["improvement"] = "farm"
    rm.build_road_from(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
    check(rm.get_hex_road_level(row, col) == 1,
            "к улучшению должна быть проложена дорога-тропка", state)

    # Производство идёт только при работнике.
    _cdata.idle_population = maxi(_cdata.idle_population, 5)
    check(wm.assign_worker(row, col), "на улучшение должен встать работник", state)

    # Предусловие: множитель производства должен быть 1.0, иначе 10 и 20
    # сдвинутся относительно порога 10 и проверка «по ресурсам» станет нечёткой.
    var mult: float = _cdata.get_improvement_production_multiplier("farm",
            _mh.is_hex_irrigated(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols),
            tile.get("terrain", ""), "test_grain")
    check(absf(mult - 1.0) < 0.01,
            "для проверки нужен гекс без бонусов к производству (множитель %.2f)" % mult, state)
    if absf(mult - 1.0) >= 0.01:
        _free(main_map)
        return

    var route: Dictionary = main_map.get_route_to_city(row, col)
    check(route.get("ok", false), "у улучшения с дорогой должен быть маршрут", state)
    check(absf(float(route.get("avg_speed", 0.0)) - 10.0) < 0.01,
            "маршрут из тропок должен иметь среднюю скорость 10 ед./сек", state)

    # Скорости продуктов: пшеница 10, клей 20.
    var rates: Dictionary = tooltip.production_rates(row, col, main_map.tile_data)
    check(rates.has("wheat") and rates.has("clay"),
            "должны считаться скорости обоих продуктов (получено %s)" % str(rates.keys()), state)
    if rates.has("wheat") and rates.has("clay"):
        check(absf(float(rates["wheat"]["rate"]) - 10.0) < 0.01,
                "пшеница должна производиться со скоростью 10 ед./сек", state)
        check(absf(float(rates["clay"]["rate"]) - 20.0) < 0.01,
                "клей должен производиться со скоростью 20 ед./сек", state)

    # Перегрузка — ПО РЕСУРСАМ: клей (20 > 10) в перегрузке, пшеница (10 = 10) нет.
    var shortfall: Dictionary = tooltip.road_capacity_shortfall(row, col, main_map.tile_data)
    check(shortfall.has("clay"),
            "клей 20 ед./сек не проходит по тропке 10 ед./сек", state)
    check(not shortfall.has("wheat"),
            "пшеница 10 ед./сек проходит по тропке — в перегрузке её быть не должно", state)

    # Флаг для отрисовки треугольника ставится на производственном тике.
    _run_production_tick(main_map)
    check(bool(tile.get("road_capacity_short", false)),
            "у перегруженного улучшения должен быть выставлен флаг road_capacity_short", state)

    # Расширенный тултип: красная пометка маршрута только у перегруженного продукта.
    # Слово «маршрут» заменено иконкой дороги, поэтому у пометки проверяем и текст
    # (число + единица), и путь иконки.
    var products: Array = tooltip._collect_extended_production(row, col, main_map.tile_data)
    var clay_route := _route_text_for(products, "clay")
    var wheat_route := _route_text_for(products, "wheat")
    check(clay_route != "", "у перегруженного клея должна быть пометка маршрута", state)
    check(clay_route.contains("10"),
            "пометка маршрута должна называть среднюю скорость 10 ед./сек (получено: %s)"
                    % clay_route, state)
    check(wheat_route == "",
            "у пшеницы, которой хватает скорости, пометки быть не должно (получено: %s)"
                    % wheat_route, state)
    check(_route_icon_for(products, "clay") != "",
            "у пометки маршрута должна быть иконка дороги", state)
    check(_route_icon_for(products, "wheat") == "",
            "у пшеницы без пометки иконки дороги быть не должно", state)

    # Левая колонка панели строится из того же блока «Производит:» — пометка
    # обязана быть и там. Слово «маршрут» заменено иконкой, поэтому сверяем по
    # тексту самой пометки (число + единица измерения), а не по слову.
    panel.select_hex(row, col)
    var panel_text := _collect_text(panel)
    check(panel_text.contains(clay_route.strip_edges()),
            "в левой колонке панели должна быть пометка маршрута (получено: %s)" % panel_text,
            state)

    # Улучшение ВСЕГО маршрута до уровня 2 (30 ед./сек): клей 20 проходит,
    # перегрузка снимается, флаг сбрасывается.
    for seg_key in route.get("segments", []):
        var parts := str(seg_key).split("|")
        var a := parts[0].split(",")
        var b := parts[1].split(",")
        rm.upgrade_road_segment(int(a[0]), int(a[1]), int(b[0]), int(b[1]), 2)
    var after: Dictionary = main_map.get_route_to_city(row, col)
    check(absf(float(after.get("avg_speed", 0.0)) - 30.0) < 0.01,
            "после улучшения средняя скорость маршрута должна стать 30 ед./сек (получено %.2f)"
                    % float(after.get("avg_speed", 0.0)), state)
    var short_after: Dictionary = tooltip.road_capacity_shortfall(row, col, main_map.tile_data)
    check(short_after.is_empty(),
            "после улучшения дороги перегрузки быть не должно (получено %s)"
                    % str(short_after.keys()), state)

    _run_production_tick(main_map)
    check(not bool(tile.get("road_capacity_short", false)),
            "после улучшения дороги флаг перегрузки должен сбрасываться", state)

    # И сам выпуск больше не обрезается: 20 клея в секунду доходят целиком.
    _cdata.city_storage["clay"] = 0
    var full_tile := {"production_fractional_remainder": 0.0}
    main_map._emit_continuous_production(full_tile, {"clay": 20}, 1.0, 1.0,
            "common", "test_source", float(after.get("avg_speed", 0.0)))
    check(int(_cdata.city_storage.get("clay", 0)) == 20,
            "после улучшения дороги все 20 клея доходят до города (получено %d)"
                    % int(_cdata.city_storage.get("clay", 0)), state)

    _free(main_map)


# Прогоняет один тик симуляции: производственный цикл выставляет
# tile.road_capacity_short. Вызываем _process напрямую — в headless дельта
# кадров слишком мала, чтобы накопить SIMULATION_TICK сам по себе.
func _run_production_tick(main_map) -> void:
    for i in range(3):
        main_map._process(1.0)


# Пометка маршрута у продукта с данным id: "" если продукта нет или пометки нет.
func _route_text_for(products: Array, prod_id: String) -> String:
    var label := str(_gdata.products.get(prod_id, {}).get("name", prod_id))
    for item in products:
        if str(item.get("type", "")) != "product":
            continue
        if str(item.get("name", "")).begins_with(label):
            return str(item.get("route_text", ""))
    return ""


# Путь иконки дороги у пометки маршрута продукта с данным id: "" если пометки нет.
func _route_icon_for(products: Array, prod_id: String) -> String:
    var label := str(_gdata.products.get(prod_id, {}).get("name", prod_id))
    for item in products:
        if str(item.get("type", "")) != "product":
            continue
        if str(item.get("name", "")).begins_with(label):
            return str(item.get("route_icon_path", ""))
    return ""


# -------------------------------------------------------
# Хелперы
# -------------------------------------------------------

# Первый свободный гекс в Кольце Влияния: сухой, известный, без улучшения,
# городка и дороги, БЕЗ доступа к пресной воде (иначе ферма получает бонус ×1.5
# и порог перегрузки сдвигается) — И с достижимым планом дороги.
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
