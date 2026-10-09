# Headless-тест показа производства в расширенном тултипе:
#   godot --headless --path . --script res://tests/test_production_display.gd
#
# Правило, которое проверяется: строка продукции показывает ТОЛЬКО скорость в
# секунду, без базы за цикл. Игрок получает непрерывный поток (main_map
# добавляет на склад produces × множитель / production_interval каждый тик), а не
# пачки раз в интервал, поэтому значение из данных, приведённое к секунде, и есть
# то, что игрок реально получает. База за цикл — внутренняя величина, которую
# игрок никогда не видит отдельной суммой.
#
# Проверки:
#   1. НЕРАСТУЩИЙ РЕСУРС С ИНТЕРВАЛОМ != 1. Скорость равна base/interval
#      (известняк: 10 за цикл при интервале 2 сек → 5 ед./сек), а не значению
#      из данных; базы в строке нет.
#   2. РАСТУЩИЙ РЕСУРС БЕЗ УЛУЧШЕНИЯ. Подсказка «при постройке» показывает
#      ПОЛНУЮ скорость (base/interval), а не 0: поголовье начинает наполняться
#      только после постройки, поэтому нулевая доля не должна гасить подсказку.
#   3. ЕДИНЫЙ ФОРМАТ. У обоих ресурсов строка одной структуры — имя и скорость,
#      без базы.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

var _gdata = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    # Автолоады берём узлами дерева: в режиме --script имена GameData/CityData
    # на этапе компиляции этого файла ещё недоступны.
    _gdata = get_root().get_node("GameData")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    var tooltip = main_map.map_tooltip
    var spot := _find_free_hex(main_map)
    check(not spot.is_empty(), "нужен свободный гекс для проверки", state)
    if spot.is_empty():
        _finish(main_map, state)
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["quality"] = "common"

    # Интервалы берём из данных, а не хардкодим: проверка должна пережить
    # изменение баланса. Условие задачи — интервал больше 1 сек, иначе база и
    # скорость совпадают и различать их нечем.
    var quarry_interval: float = _production_interval("quarry")
    var pasture_interval: float = _production_interval("pasture")
    check(quarry_interval > 1.0,
            "для проверки интервал карьера должен быть больше 1 сек (получено %.1f)"
                    % quarry_interval, state)
    check(pasture_interval > 1.0,
            "для проверки интервал пастбища должен быть больше 1 сек (получено %.1f)"
                    % pasture_interval, state)

    # --- 1. Не растущий ресурс (карьер, интервал 2 сек) ---
    _gdata.raw_resources["test_stone"] = {
        "id": "test_stone", "name": "Test Stone", "type": "raw",
        "improved_by": "quarry", "produces": {"limestone": 10},
    }
    tile["resource"] = "test_stone"
    tile["improvement"] = null
    var stone_item := _product_item(tooltip, row, col, main_map, "limestone")
    check(not stone_item.is_empty(), "строка известняка должна быть в блоке производства", state)
    if not stone_item.is_empty():
        var stone_rate: float = 10.0 / quarry_interval
        check(absf(float(stone_item.get("amount", 0.0)) - stone_rate) < 0.001,
                "скорость известняка = база/интервал = %.1f ед./сек (получено %.1f)"
                        % [stone_rate, float(stone_item.get("amount", 0.0))], state)
        check(not _has_base_label(str(stone_item.get("name", ""))),
                "в строке известняка базы быть не должно (получено: %s)"
                        % stone_item.get("name", ""), state)

    # --- 2. Растущий ресурс без улучшения: подсказка = полная скорость ---
    _gdata.raw_resources["test_herd"] = {
        "id": "test_herd", "name": "Test Herd", "type": "raw",
        "improved_by": "pasture", "produces": {"raw_meat": 20},
        "feed_consumption": 50, "time_to_mature": 40.0,
    }
    tile["resource"] = "test_herd"
    tile["improvement"] = null
    tile["fill_time"] = 0.0
    var herd_item := _product_item(tooltip, row, col, main_map, "raw_meat")
    check(not herd_item.is_empty(), "строка мяса должна быть в подсказке производства", state)
    if not herd_item.is_empty():
        var herd_rate: float = 20.0 / pasture_interval
        check(float(herd_item.get("amount", 0.0)) > 0.0,
                "подсказка «при постройке» должна показывать полную скорость, а не 0 (получено %.1f)"
                        % float(herd_item.get("amount", 0.0)), state)
        check(absf(float(herd_item.get("amount", 0.0)) - herd_rate) < 0.001,
                "скорость мяса = база/интервал = %.1f ед./сек (получено %.1f)"
                        % [herd_rate, float(herd_item.get("amount", 0.0))], state)
        check(not _has_base_label(str(herd_item.get("name", ""))),
                "в строке мяса базы быть не должно (получено: %s)"
                        % herd_item.get("name", ""), state)

    # --- 3. Единый формат: ни у одного ресурса базы нет ---
    if not stone_item.is_empty() and not herd_item.is_empty():
        check(not _has_base_label(str(stone_item.get("name", "")))
                and not _has_base_label(str(herd_item.get("name", ""))),
                "оба ресурса должны показывать строку одного формата — без базы", state)

    _finish(main_map, state)

func _production_interval(imp_id: String) -> float:
    return float(_gdata.improvements.get(imp_id, {}).get("production_interval", 0.0))

# Строка продукта prod_id из блока «Производит:» / «При постройке … будет
# производить:» для гекса (row, col). Пустой словарь — строки нет.
func _product_item(tooltip, row: int, col: int, main_map, prod_id: String) -> Dictionary:
    var label := str(_gdata.products.get(prod_id, {}).get("name", prod_id))
    var products: Array = tooltip._collect_extended_production(row, col, main_map.tile_data)
    for item in products:
        if str(item.get("type", "")) != "product":
            continue
        if str(item.get("name", "")).begins_with(label):
            return item
    return {}

# В имени строки осталась подпись базы. Проверяем и русский перевод, и английский
# msgid: тест не должен зависеть от активной локали.
func _has_base_label(item_name: String) -> bool:
    return item_name.contains("база ") or item_name.contains("base ")

func _find_free_hex(main_map) -> Dictionary:
    for r in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for c in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[r][c]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if tile.get("has_town", false) or tile.get("in_town_influence", false):
                continue
            if r == main_map.city_row and c == main_map.city_col:
                continue
            return {"row": r, "col": c}
    return {}

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("PRODUCTION DISPLAY TEST FAILED")
        quit(1)
    else:
        print("PRODUCTION DISPLAY TEST OK")
        quit(0)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    print("FAILED: %s" % message)
    push_error("ASSERT: %s" % message)
