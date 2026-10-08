# Headless-тест ПОТРЕБЛЕНИЯ ЗДАНИЙ — и показа, и факта:
#   godot --headless --path . --script res://tests/test_building_consumption_ui.gd
#
# Проверяется:
#   1. ConsumptionUi.build_rows_for_building(): строки расхода профессии здания —
#      состав строк, скорость «шт./сек», бонус, умножение на число РАБОЧИХ зданий,
#      случай без рабочих зданий и здание без профессии (пустой список).
#   2. Тултип деталей здания (вкладка «Здания»): секция «Потребляет:» со
#      скоростью расхода — показывается до постройки, как «Стоимость».
#   3. Окно деталей здания: сумма по двум рабочим постройкам, затем пометка
#      «(рабочих зданий нет)», когда слоты здания пусты (здание простаивает и
#      расходники не тратит).
#   4. ФАКТИЧЕСКОЕ потребление: рабочее здание с профессией и ресурсом на складе
#      списывает ровно amount за interval; при пустом складе расхода нет, а
#      множитель производства падает к базовому (1.0); простаивающее здание
#      (нет горожанина либо все слоты пусты) не тратит ресурс.
#
# ВАЖНО ПРО ЗАВИСИМОСТЬ ОТ ДАННЫХ. Балансные числа (id расходника, amount,
# interval, production_bonus) живут в data/consumption.json и в
# data/buildings.json и МЕНЯЮТСЯ автором баланса. Тест НЕ должен их хардкодить:
# иначе правка джейсона роняет тест, хотя система работает верно. Поэтому все
# ожидания выводятся из тех же данных (GameData.get_profession_consumption /
# get_profession_for_building / products / product_groups), и проверяются
# ИНВАРИАНТЫ: «строка построена из данных», «списано ровно amount», «без
# ресурса бонуса нет» — а не конкретные цифры.
#
# ВАЖНО: скрипт компилируется ДО регистрации автозагрузок, поэтому берём их
# через дерево сцены, а общий помощник — load() по пути (тот же приём, что с
# HexUtils в test_territory_costs и с underlined_label в ui_helpers).
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Здание с профессией — предмет проверки. Само здание может смениться в данных,
# поэтому выбор делает helper _pick_profession_building(), а не константа.
const SIMULATION_TICK := 1.0

var _gdata = null
var _cdata = null
var _wm = null
var _tm = null
var _consumption_ui = null

func _initialize():
    WATCHDOG.arm(self)
    _run()


func _run() -> void:
    var state = {"failed": false}
    _consumption_ui = load("res://scripts/consumption_ui.gd")

    # --- Живая сцена: новая игра, город, интерфейс ---
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    main_map.open_city()
    await process_frame
    var city_ui = main_map.city_ui
    check(city_ui != null and city_ui.visible, "интерфейс города открыт", state)
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _wm = main_map.get_node("WorkerManager")
    _tm = main_map.get_node("TownsfolkManager")

    # Здание с профессией и его расходник — из данных, не из константы.
    var building_id := _pick_profession_building()
    check(not building_id.is_empty(),
        "в data/buildings.json должно найтись здание с профессией и потреблением", state)
    if building_id.is_empty():
        _finish(main_map, state)
        return

    if WATCHDOG.wants_case("ui_rows"):
        _test_ui_rows(state, building_id)
    if WATCHDOG.wants_case("details_tooltip"):
        _test_details_tooltip(state, city_ui, building_id)
    if WATCHDOG.wants_case("building_panel"):
        _test_building_panel(state, city_ui, building_id)
    if WATCHDOG.wants_case("actual_consumption"):
        _test_actual_consumption(state, building_id)

    _finish(main_map, state)


# -------------------------------------------------------
# 1. Строки расхода профессии здания (ConsumptionUi)
# -------------------------------------------------------

# Все ожидания — из GameData.get_profession_consumption(profession), а не из
# чисел в consumption.json: смена баланса не должна ронять тест.
func _test_ui_rows(state: Dictionary, building_id: String) -> void:
    var prof: String = _gdata.get_profession_for_building(building_id)
    check(not prof.is_empty(),
        "у здания «%s» должна быть профессия (получено: «%s»)" % [building_id, prof], state)
    var entries: Array = _gdata.get_profession_consumption(prof)
    check(not entries.is_empty(),
        "у профессии «%s» должно быть потребление в consumption.json" % prof, state)
    if entries.is_empty():
        return

    var rows = _consumption_ui.build_rows_for_building(building_id)
    check(rows.size() == entries.size(),
        "число строк расхода должно совпасть с числом записей реестра (строк %d, записей %d)"
            % [rows.size(), entries.size()], state)

    # Сопоставляем каждую строку её записи реестра по display_key.
    for entry in entries:
        var key := str(entry.get("display_key", entry.get("product_id", "")))
        var row := _row_by_key(rows, key)
        check(not row.is_empty(), "нет строки расхода для «%s»" % key, state)
        if row.is_empty():
            continue
        var amount := int(entry.get("amount", 0))
        var interval := float(entry.get("interval", 0.0))
        var expected_per_sec := float(amount) if interval <= 0.0 else float(amount) / interval
        var expected_name := str(entry.get("product_name", entry.get("product_id", "")))
        var expected_bonus := float(entry.get("production_bonus", 0.0))

        check(str(row.get("name", "")) == expected_name,
            "имя расходника «%s» должно браться из данных (получено: «%s»)"
                % [expected_name, str(row.get("name", ""))], state)
        check(is_equal_approx(float(row.get("per_sec", 0.0)), expected_per_sec),
            "скорость «%s»: amount/interval = %s шт./сек (получено: %s)"
                % [key, str(expected_per_sec), str(row.get("per_sec", 0.0))], state)
        check(is_equal_approx(float(row.get("production_bonus", 0.0)), expected_bonus),
            "бонус «%s» должен совпасть с данными (получено: %s)"
                % [key, str(row.get("production_bonus", 0.0))], state)
        check(str(row.get("display_key", "")) == key,
            "display_key строки не совпал с записью реестра (получено: «%s»)"
                % str(row.get("display_key", "")), state)
        # Подпись = «Имя: rate_label», и rate_label сам собран из данных.
        check(str(row.get("label", "")) == "%s: %s" % [expected_name, str(row.get("rate_label", ""))],
            "подпись строки должна быть «Имя: rate_label» (получено: «%s»)"
                % str(row.get("label", "")), state)

    # Умножение на число РАБОЧИХ зданий: скорость = базовая × N, плюс пометка.
    var rows2 = _consumption_ui.build_rows_for_building(building_id, 2)
    for entry in entries:
        var key2 := str(entry.get("display_key", entry.get("product_id", "")))
        var row2 := _row_by_key(rows2, key2)
        if row2.is_empty():
            check(false, "при двух зданиях нет строки расхода для «%s»" % key2, state)
            continue
        var base_per_sec := _base_per_sec(entry)
        check(is_equal_approx(float(row2.get("per_sec", 0.0)), base_per_sec * 2.0),
            "два рабочих здания удваивают скорость «%s» (получено: %s)"
                % [key2, str(row2.get("per_sec", 0.0))], state)
        check(_has_text([str(row2.get("label", ""))], "2"),
            "в подписи двух зданий должна быть пометка с числом 2 (получено: «%s»)"
                % str(row2.get("label", "")), state)

    # Рабочих зданий нет: скорость остаётся «на одно здание», но подпись иная.
    var rows0 = _consumption_ui.build_rows_for_building(building_id, 0)
    for entry in entries:
        var key0 := str(entry.get("display_key", entry.get("product_id", "")))
        var row0 := _row_by_key(rows0, key0)
        if row0.is_empty():
            check(false, "без рабочих зданий нет строки расхода для «%s»" % key0, state)
            continue
        check(is_equal_approx(float(row0.get("per_sec", 0.0)), _base_per_sec(entry)),
            "без рабочих зданий скорость «%s» остаётся на одно здание (получено: %s)"
                % [key0, str(row0.get("per_sec", 0.0))], state)
        check(str(row0.get("label", "")) != str(_row_by_key(rows, key0).get("label", "")),
            "подпись без рабочих зданий должна отличаться от обычной («%s»)"
                % str(row0.get("label", "")), state)

    # Здание без профессии и пустой id: показывать нечего.
    check(_consumption_ui.build_rows_for_building("bakery").is_empty(),
        "у пекарни (без профессии) строк расхода нет", state)
    check(_consumption_ui.build_rows_for_building("").is_empty(),
        "для пустого id здания строк расхода нет", state)


# -------------------------------------------------------
# 2. Тултип деталей здания на вкладке «Здания»
# -------------------------------------------------------

func _test_details_tooltip(state: Dictionary, city_ui, building_id: String) -> void:
    var prof := str(_gdata.get_profession_for_building(building_id))
    if prof.is_empty():
        return
    var entries: Array = _gdata.get_profession_consumption(prof)
    if entries.is_empty():
        return

    var btab = city_ui.buildings_tab
    var building = null
    for b in btab.buildings_data:
        if b.get("id", "") == building_id:
            building = b
            break
    check(building != null,
        "данные здания «%s» есть во вкладке «Здания»" % building_id, state)
    if building == null:
        return

    btab._hovered_building_id = building_id
    btab._show_building_details(building)
    var tip_texts := _collect_texts(city_ui.ui_helpers.detail_tooltip_content)
    check(_has_line(tip_texts, "Потребляет:"),
        "в тултипе деталей есть заголовок «Потребляет:» (получено: %s)" % str(tip_texts), state)
    # Скорость и бонус в тултипе берём из данных, а не хардкодим.
    var entry: Dictionary = entries[0]
    var expected_per_sec := _base_per_sec(entry)
    check(_has_text(tip_texts, "%s шт./сек" % _consumption_ui.format_rate(expected_per_sec)),
        "в тултипе деталей есть скорость расхода «%s шт./сек» (получено: %s)"
            % [_consumption_ui.format_rate(expected_per_sec), str(tip_texts)], state)
    var bonus := float(entry.get("production_bonus", 0.0))
    if bonus > 0.0:
        check(_has_text(tip_texts, "+%d%% к производству" % int(round(bonus * 100.0))),
            "в тултипе деталей есть бонус «+%d%% к производству» (получено: %s)"
                % [int(round(bonus * 100.0)), str(tip_texts)], state)

    # У здания без профессии секции быть не должно.
    var bakery = null
    for b in btab.buildings_data:
        if b.get("id", "") == "bakery":
            bakery = b
            break
    if bakery != null:
        btab._show_building_details(bakery)
        var bakery_texts := _collect_texts(city_ui.ui_helpers.detail_tooltip_content)
        check(not _has_line(bakery_texts, "Потребляет:"),
            "у пекарни (без профессии) секции «Потребляет:» нет", state)


# -------------------------------------------------------
# 3. Окно деталей здания: сумма по рабочим зданиям
# -------------------------------------------------------

func _test_building_panel(state: Dictionary, city_ui, building_id: String) -> void:
    var prof := str(_gdata.get_profession_for_building(building_id))
    if prof.is_empty():
        return
    var entries: Array = _gdata.get_profession_consumption(prof)
    if entries.is_empty():
        return

    # Слот берём из самого здания в данных — какой рецепт считать рабочим.
    var slot := _default_slot_for_building(building_id)
    _cdata.city_built_buildings = [
        {"id": building_id, "slots": [slot], "quality_priority": "best"},
        {"id": building_id, "slots": [slot], "quality_priority": "best"},
    ]
    _cdata.idle_population = maxi(_cdata.idle_population, 4)
    check(_tm.assign_townsfolk(0), "горожанин назначен в первое здание", state)
    check(_tm.assign_townsfolk(1), "горожанин назначен во второе здание", state)
    city_ui._on_building_detail_requested(building_id)
    await process_frame
    var panel = city_ui.building_panel
    check(panel != null and panel.visible, "окно деталей здания открыто", state)
    if panel == null:
        return

    check(panel.consumption_box != null and panel.consumption_box.visible,
        "секция «Потребляет:» показана в окне здания", state)
    var entry: Dictionary = entries[0]
    var base_per_sec := _base_per_sec(entry)
    var panel_texts := _collect_texts(panel.consumption_box)
    check(_has_text(panel_texts, "%s шт./сек" % _consumption_ui.format_rate(base_per_sec * 2.0)),
        "окно здания показывает сумму по двум рабочим (получено: %s)" % str(panel_texts), state)
    var bonus := float(entry.get("production_bonus", 0.0))
    if bonus > 0.0:
        check(_has_text(panel_texts, "+%d%% к производству" % int(round(bonus * 100.0))),
            "окно здания показывает бонус к производству (получено: %s)" % str(panel_texts), state)

    # Одно здание простаивает (слоты пустые) — расходник не тратится.
    _cdata.city_built_buildings[1]["slots"] = ["empty"]
    panel._refresh()
    var idle_texts := _collect_texts(panel.consumption_box)
    check(_has_text(idle_texts, "%s шт./сек" % _consumption_ui.format_rate(base_per_sec)),
        "при простаивающем здании скорость — одно здание (получено: %s)" % str(idle_texts), state)
    check(not _has_text(idle_texts, "(2 здания)"),
        "простаивающее здание не попадает в сумму (получено: %s)" % str(idle_texts), state)

    # Оба здания без горожан — расхода нет, но скорость «на здание» видна.
    _tm.remove_townsfolk(0)
    _tm.remove_townsfolk(1)
    panel._refresh()
    var no_worker_texts := _collect_texts(panel.consumption_box)
    check(_has_text(no_worker_texts, "рабочих зданий нет"),
        "без горожан есть пометка «рабочих зданий нет» (получено: %s)" % str(no_worker_texts), state)

    # Здание без профессии: секция скрыта.
    _cdata.city_built_buildings = [{"id": "bakery", "slots": ["bread"], "quality_priority": "best"}]
    var bakery_data = city_ui.data_cache.duplicate()
    bakery_data["ui_helpers"] = city_ui.ui_helpers
    panel.open("bakery", bakery_data)
    check(panel.consumption_box.get_child_count() == 0 and not panel.consumption_box.visible,
        "у здания без профессии секция «Потребляет:» скрыта", state)


# -------------------------------------------------------
# 4. ФАКТИЧЕСКОЕ потребление зданием
# -------------------------------------------------------

# Механика: CityData.do_tick() для каждого РАБОЧЕГО здания (есть горожанин и
# хотя бы один непустой слот) зовёт worker_manager.tick_building_consumption(i,
# SIMULATION_TICK). Здесь зовём его напрямую — детерминированно, без гонки тиков
# игры. Проверяем ИНВАРИАНТЫ, а не цифры: сколько в реестре amount, столько и
# спишется за interval; без ресурса бонуса нет.
func _test_actual_consumption(state: Dictionary, building_id: String) -> void:
    var prof := str(_gdata.get_profession_for_building(building_id))
    var entries: Array = _gdata.get_profession_consumption(prof)
    if entries.is_empty():
        return
    var entry: Dictionary = entries[0]
    var product_key := str(entry.get("display_key", entry.get("product_id", "")))
    var amount := int(entry.get("amount", 0))
    var interval := float(entry.get("interval", 0.0))
    var bonus := float(entry.get("production_bonus", 0.0))
    if amount <= 0 or interval <= 0.0:
        check(false, "у записи «%s» должны быть положительные amount/interval" % product_key, state)
        return

    # Свежий таймер: тест не должен зависеть от ранее накопленных долей.
    _wm.building_consumption_timers.clear()

    var slot := _default_slot_for_building(building_id)
    _cdata.city_built_buildings = [
        {"id": building_id, "slots": [slot], "quality_priority": "best"},
    ]
    _cdata.idle_population = maxi(_cdata.idle_population, 2)
    # Заводим горожанина ровно так, как это делает игра.
    _tm.assign_townsfolk(0)
    check(_tm.has_townsfolk(0), "горожанин должен быть назначен в здание", state)

    # Склад наполняем с запасом: списывать надо ровно amount за interval.
    var storage_before := _fill_storage(product_key, amount * 4)
    check(storage_before >= amount,
        "на складе «%s» должно быть не меньше одной порции amount=%d" % [product_key, amount], state)

    # Один интервал потребления: ожидаем списание ровно amount (плюс, возможно,
    # побочное потребление рецепта — поэтому сравниваем только по этому ресурсу
    # и с точностью «не больше amount», а отдельно проверяем, что бонус включён).
    var before := _storage_of(product_key)
    _tick_interval(interval)
    var after := _storage_of(product_key)
    var spent := before - after
    check(spent == amount,
        "за interval=%s рабочее здание должно списать ровно amount=%d «%s» (списано %d)"
            % [str(interval), amount, product_key, spent], state)

    # Пока ресурса хватало — множитель производства = 1 + bonus (бонус включён).
    if bonus > 0.0:
        var mult_with: float = _wm.tick_building_consumption(0, 0.0)
        check(is_equal_approx(mult_with, 1.0 + bonus),
            "при наличии ресурса множитель производства = 1+bonus (получено: %s, ожидалось %s)"
                % [str(mult_with), str(1.0 + bonus)], state)

    # Опустошаем склад: расхода нет, множитель падает к базовому.
    _clear_storage(product_key)
    # Небольшой прогон, чтобы таймер попытался списать при пустом складе.
    _tick_interval(interval)
    check(_storage_of(product_key) == 0,
        "на пустом складе ресурс «%s» не может уйти в минус" % product_key, state)
    var mult_without: float = _wm.tick_building_consumption(0, 0.0)
    check(is_equal_approx(mult_without, 1.0),
        "без ресурса множитель производства должен вернуться к 1.0 (получено: %s)"
            % str(mult_without), state)

    # Простаивающее здание: горожанина нет — расхода нет, даже если ресурс есть.
    _tm.remove_townsfolk(0)
    _wm.building_consumption_timers.clear()
    var restored := _fill_storage(product_key, amount * 2)
    _tick_interval(interval)
    check(_storage_of(product_key) == restored,
        "без горожанина здание не должно тратить «%s» (было %d, стало %d)"
            % [product_key, restored, _storage_of(product_key)], state)

    # Горожанин есть, но все слоты пусты: do_tick пропускает потребление.
    _tm.assign_townsfolk(0)
    _cdata.city_built_buildings[0]["slots"] = ["empty"]
    _wm.building_consumption_timers.clear()
    var restored2 := _fill_storage(product_key, amount * 2)
    _tick_interval(interval)
    check(_storage_of(product_key) == restored2,
        "при пустых слотах расход не производится (было %d, стало %d)"
            % [restored2, _storage_of(product_key)], state)


# Прогоняет потребление здания на длину интервала шагами SIMULATION_TICK —
# так же, как это делает игровой цикл (по одному тику за раз).
#
# ВАЖНО: сама tick_building_consumption() про горожанина/слоты не знает —
# условие «здание работает» проверяет вызывающий CityData.do_tick()
# (есть горожанин И не все слоты пусты). Здесь это условие воспроизводится,
# иначе тест звал бы потребление у простаивающего здания, чего в игре не бывает.
func _tick_interval(interval: float) -> void:
    if not _is_building_working(0):
        return
    var steps := maxi(1, int(ceil(interval / SIMULATION_TICK)))
    for _i in range(steps):
        _wm.tick_building_consumption(0, SIMULATION_TICK)


# То же условие «здание работает», что и в CityData.do_tick().
func _is_building_working(b_index: int) -> bool:
    if not _tm.has_townsfolk(b_index):
        return false
    return not _cdata.are_all_slots_empty(b_index)


# Наполняет склад ресурсом с запасом, возвращает итоговое количество.
func _fill_storage(product_key: String, wanted: int) -> int:
    if product_key.begins_with("@"):
        # Группа: наполняем первого ЧЛЕНА, чтобы списание прошло жадно.
        var members: Array = _gdata.product_groups.get(product_key.substr(1), [])
        if members.is_empty():
            return 0
        var pid := str(members[0])
        _cdata.add_to_storage(pid, wanted, "common")
        return _cdata.get_storage_amount(pid)
    _cdata.add_to_storage(product_key, wanted, "common")
    return _cdata.get_storage_amount(product_key)


func _clear_storage(product_key: String) -> void:
    if product_key.begins_with("@"):
        for m in _gdata.product_groups.get(product_key.substr(1), []):
            var amt: int = _cdata.get_storage_amount(str(m))
            if amt > 0:
                _cdata.remove_from_storage(str(m), amt, "best")
        return
    var amt2: int = _cdata.get_storage_amount(product_key)
    if amt2 > 0:
        _cdata.remove_from_storage(product_key, amt2, "best")


func _storage_of(product_key: String) -> int:
    if product_key.begins_with("@"):
        var members: Array = _gdata.product_groups.get(product_key.substr(1), [])
        if members.is_empty():
            return 0
        return _cdata.get_storage_amount(str(members[0]))
    return _cdata.get_storage_amount(product_key)


# -------------------------------------------------------
# Выбор данных для проверки
# -------------------------------------------------------

# Здание с профессией, у которой есть хотя бы одно правило потребления.
# Не хардкодим «library»: если состав зданий/профессий изменят, тест найдёт
# другое подходящее здание, а не упадёт.
func _pick_profession_building() -> String:
    for b in _gdata.buildings:
        var bld_id := str(b.get("id", ""))
        if bld_id.is_empty():
            continue
        var prof := str(_gdata.get_profession_for_building(bld_id))
        if prof.is_empty():
            continue
        if not _gdata.get_profession_consumption(prof).is_empty():
            return bld_id
    return ""


# Базовый рецепт здания (первый непустой слот из данных) — чтобы окно здания
# считало постройку рабочей, как в игре.
func _default_slot_for_building(building_id: String) -> String:
    var b: Dictionary = _gdata.get_building_data(building_id)
    var recipes: Array = b.get("default_recipes", [])
    if not recipes.is_empty():
        return str(recipes[0])
    return "empty"


# Скорость потребления записи без множителя: amount / interval (шт./сек).
func _base_per_sec(entry: Dictionary) -> float:
    var amount := int(entry.get("amount", 0))
    var interval := float(entry.get("interval", 0.0))
    return float(amount) if interval <= 0.0 else float(amount) / interval


# Строка расхода по ключу ресурса/группы.
func _row_by_key(rows: Array, key: String) -> Dictionary:
    for r in rows:
        if str(r.get("display_key", "")) == key:
            return r
    return {}


# -------------------------------------------------------
# Помощники
# -------------------------------------------------------

# Собирает тексты всех меток под узлом (Label и RichTextLabel на любой глубине).
func _collect_texts(node: Node) -> Array:
    var result: Array = []
    for child in node.get_children():
        if child is Label:
            result.append(str((child as Label).text))
        elif child is RichTextLabel:
            result.append(str((child as RichTextLabel).text))
        else:
            result.append_array(_collect_texts(child))
    return result

func _has_text(texts: Array, needle: String) -> bool:
    for t in texts:
        if str(t).contains(needle):
            return true
    return false

func _has_line(texts: Array, line: String) -> bool:
    for t in texts:
        if str(t) == line:
            return true
    return false

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    WATCHDOG.report_skipped()
    if state["failed"]:
        print("BUILDING CONSUMPTION TEST FAILED")
        quit(1)
    else:
        print("BUILDING CONSUMPTION TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
