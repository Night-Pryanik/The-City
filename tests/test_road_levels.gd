# Headless-тест уровней дорог и маршрутов (data/roads.json, road_manager,
# main_map, control_panel, map_renderer).
#   godot --headless --path . --script res://tests/test_road_levels.gd
#
# Проверки:
#   1. ДАННЫЕ. Уровни идут подряд с 1, у каждого положительная
#      «максимальная скорость», уровень 1 бесплатен. «Колесо» открывает
#      ровно уровень 2, и у него max_speed = 30 (требование дизайна).
#   2. РАЗБЛОКИРОВКА. Без «Колеса» доступен только уровень 1; после
#      исследования — уровень 2, и он становится предлагаемым по умолчанию.
#   3. УРОВЕНЬ В СЕТИ. Построенный участок помнит свой уровень; соседний
#      участок от этого не меняется, а несуществующий даёт 0, а не тропку.
#   4. МАРШРУТ И СКОРОСТЬ. От улучшения до города находится маршрут по
#      дорогам; средняя скорость = среднее max_speed участков, минимальная =
#      самое узкое место. На смешанном маршруте обе величины считаются
#      по-разному — это ловит ошибку «взять минимум вместо среднего».
#   5. УЛУЧШЕНИЕ ДОРОГИ. Участок улучшается, но не понижается и не
#      улучшается повторно до того же уровня.
#   6. ЖИВАЯ СЦЕНА. На улучшении с дорогой есть кнопка «Улучшить дорогу»
#      и строка маршрута; клик подсвечивает маршрут на карте; превью
#      показывает призрак улучшаемых участков; уровень влияет на цену.
#   7. УРОВЕНЬ ДОРОГИ НА ГЕКСЕ. Строка с уровнем (и пропускной
#      способностью участка) показывается в расширенном тултипе и в левой
#      колонке панели управления; в обычном тултипе её нет.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const ROAD_ACTION_ID := "build_road"

const ROWS := 20
const COLS := 20
const CITY_ROW := 10
const CITY_COL := 10

var _rm = null
var _gdata = null
var _cdata = null
var _mh = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Автолоады берём узлами дерева сцены: в режиме --script имена GameData и
    # CityData на этапе компиляции этого файла ещё недоступны.
    # new_game() заодно грузит все данные, включая roads.json.
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _mh = load("res://scripts/map_helpers.gd")

    _rm = load("res://scripts/road_manager.gd").new()
    get_root().add_child(_rm)

    _test_road_data(state)
    _test_unlock_by_wheel(state)
    _test_segment_level(state)
    _test_route_and_speeds(state)
    _test_upgrade(state)

    get_root().remove_child(_rm)
    _rm.free()
    _rm = null

    await _test_live_scene(state)

    if state["failed"]:
        print("ROAD LEVELS TEST FAILED")
        quit(1)
    else:
        print("ROAD LEVELS TEST OK")
        quit(0)


# -------------------------------------------------------
# Синтетическая карта: равнина без ресурсов, рек и улучшений
# -------------------------------------------------------

func _make_map() -> Array:
    var tile_data := []
    for r in range(ROWS):
        var row := []
        for c in range(COLS):
            row.append({
                "terrain": "plain", "cover": "none", "resource": null,
                "quality": "", "crop_bred": null, "improvement": null,
                "decorative": false, "terrain_icon": "", "fill_time": 0.0,
                "production_fractional_remainder": 0.0, "has_town": false,
                "river_edges": [], "in_influence": true, "is_explored": true,
                "in_town_influence": false, "road_built": false, "road_level": 1,
            })
        tile_data.append(row)
    return tile_data

# Разблокировать технологию, открывающую уровень (сейчас это «Колесо»).
# Поле unlock_tech бывает null, поэтому null пропускаем явно: `null or ""`
# в GDScript не даёт пустую строку.
func _unlock_level(level: int) -> void:
    var raw = _gdata.get_road_by_level(level).get("unlock_tech", null)
    if not (raw is String) or str(raw).is_empty():
        return
    if str(raw) not in _cdata.unlocked_technologies:
        _cdata.unlocked_technologies.append(str(raw))

# -------------------------------------------------------
# 1. Данные уровней
# -------------------------------------------------------

func _test_road_data(state: Dictionary) -> void:
    check(_gdata.get_road_levels().size() >= 2,
            "в roads.json должно быть минимум два уровня дороги", state)

    # Уровни идут подряд с 1: участок хранит номер уровня, и пропуск означал
    # бы, что часть номеров не соответствует ни одной записи.
    var levels: Array = _gdata.get_road_levels()
    for i in range(levels.size()):
        check(int(levels[i]) == i + 1,
                "уровни дороги должны идти подряд с 1 (ожидался %d, получен %d)"
                        % [i + 1, int(levels[i])], state)

    for level in levels:
        check(_gdata.get_road_max_speed(int(level)) > 0,
                "у уровня %d должна быть положительная максимальная скорость" % int(level),
                state)

    # Тропка бесплатна: дорога, строящаяся вместе с улучшением, не должна
    # стоить труда, иначе улучшение на дальнем гексе невозможно построить.
    check(_gdata.get_road_work_cost(1) == 0,
            "уровень 1 (тропка) должен быть бесплатным", state)
    check(_gdata.get_road_max_speed(1) > 0,
            "у тропки всё равно должна быть положительная скорость", state)


# -------------------------------------------------------
# 2. «Колесо» открывает второй уровень со скоростью 30
# -------------------------------------------------------

func _test_unlock_by_wheel(state: Dictionary) -> void:
    var level2: Dictionary = _gdata.get_road_by_level(2)
    check(not level2.is_empty(), "в roads.json должен быть уровень 2", state)
    check(str(level2.get("unlock_tech", "")) == "wheel",
            "уровень 2 должен открываться технологией «Колесо» (wheel)", state)
    # Значение из дизайна задания: тропка везёт 10 ед./сек, тележная дорога — 30.
    check(_gdata.get_road_max_speed(2) == 30,
            "максимальная скорость уровня 2 должна быть 30 ед./сек (получено %d)"
                    % _gdata.get_road_max_speed(2), state)

    check(_cdata.is_tech_unlocked("wheel") == false,
            "в начале партии «Колесо» не должно быть изучено", state)
    check(_gdata.is_road_level_unlocked(1), "тропка доступна без технологий", state)
    check(not _gdata.is_road_level_unlocked(2),
            "второй уровень недоступен до «Колеса»", state)
    check(_gdata.get_unlocked_road_levels() == [1],
            "до «Колеса» доступна только тропка", state)
    # По умолчанию предлагается ЛУЧШИЙ доступный уровень.
    check(_gdata.get_max_unlocked_road_level() == 1,
            "до «Колеса» по умолчанию предлагается тропка", state)

    _unlock_level(2)
    check(_gdata.is_road_level_unlocked(2),
            "после «Колеса» второй уровень должен быть доступен", state)
    check(_gdata.get_max_unlocked_road_level() == 2,
            "после «Колеса» по умолчанию предлагается второй уровень", state)
    # Тропка остаётся доступной: игрок может выбрать любой предыдущий уровень.
    check(_gdata.is_road_level_unlocked(1),
            "после «Колеса» тропка должна остаться доступной", state)


# -------------------------------------------------------
# 3. Участок помнит свой уровень
# -------------------------------------------------------

func _test_segment_level(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)

    # Тропка от города: уровень по умолчанию — 1.
    _rm.build_road_step(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL)
    check(_rm.get_segment_level(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL) == 1,
            "участок без явного уровня должен быть тропкой", state)

    # Тележная дорога тем же вызовом, но с уровнем.
    _rm.build_road_step(CITY_ROW + 1, CITY_COL, CITY_ROW + 2, CITY_COL, false, 2)
    check(_rm.get_segment_level(CITY_ROW + 1, CITY_COL, CITY_ROW + 2, CITY_COL) == 2,
            "участок должен помнить выбранный уровень", state)
    # Соседний участок не должен меняться: уровень принадлежит участку,
    # а не «дороге вообще».
    check(_rm.get_segment_level(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL) == 1,
            "уровень соседнего участка не должен меняться", state)
    # Участка нет — 0, а не тропка: иначе несуществующий участок считался бы
    # дорогой с пропускной способностью.
    check(_rm.get_segment_level(CITY_ROW, CITY_COL, CITY_ROW + 9, CITY_COL) == 0,
            "несуществующий участок должен давать уровень 0", state)

    # Автоматическая дорога к улучшению — тропка. Проверяем ВСЕ её участки,
    # а не один конкретный: планировщик идёт по Дейкстре и может выбрать
    # обходной путь, и тогда «первый участок к городу» — не тот, что рядом
    # с гексом по прямой.
    _rm.initialize(CITY_ROW, CITY_COL)
    tile_data[CITY_ROW + 3][CITY_COL]["improvement"] = "farm"
    _rm.build_road_from(CITY_ROW + 3, CITY_COL, tile_data, ROWS, COLS)
    var trail_segments: Dictionary = _rm.get_all_road_segments()
    check(not trail_segments.is_empty(), "к улучшению должна быть проложена дорога", state)
    for key in trail_segments.keys():
        check(int(trail_segments[key]) == 1,
                "дорога к улучшению по умолчанию должна быть тропкой: %s" % key, state)

    # Явно выбранный уровень доходит до сети.
    _rm.initialize(CITY_ROW, CITY_COL)
    _rm.build_road_from(CITY_ROW + 4, CITY_COL, tile_data, ROWS, COLS, 2)
    var cart_segments: Dictionary = _rm.get_all_road_segments()
    check(not cart_segments.is_empty(), "к улучшению должна быть проложена дорога", state)
    for key in cart_segments.keys():
        check(int(cart_segments[key]) == 2,
                "выбранный уровень дороги к улучшению должен попасть в сеть: %s" % key,
                state)


# -------------------------------------------------------
# 4. Маршрут и скорость
# -------------------------------------------------------

func _test_route_and_speeds(state: Dictionary) -> void:
    _rm.initialize(CITY_ROW, CITY_COL)
    # Маршрут длиной 4 участка: город -> 1 -> 2 -> 3 -> 4.
    _rm.build_road_step(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL)
    _rm.build_road_step(CITY_ROW + 1, CITY_COL, CITY_ROW + 2, CITY_COL)
    _rm.build_road_step(CITY_ROW + 2, CITY_COL, CITY_ROW + 3, CITY_COL)
    _rm.build_road_step(CITY_ROW + 3, CITY_COL, CITY_ROW + 4, CITY_COL)

    var route: Dictionary = _rm.find_route_to_city(CITY_ROW + 4, CITY_COL)
    check(route.get("ok", false),
            "маршрут от улучшения до города должен находиться", state)
    check(int(route.get("length", 0)) == 4,
            "маршрут должен состоять из 4 участков (получено %d)"
                    % int(route.get("length", 0)), state)
    check(route.get("path", []).size() == 5,
            "маршрут из 4 участков содержит 5 гексов", state)

    # Сплошная тропка: средняя = минимальная = её скорость.
    var trail_speed: int = _gdata.get_road_max_speed(1)
    check(absf(float(route.get("avg_speed", 0.0)) - float(trail_speed)) < 0.01,
            "на маршруте из одной тропки средняя скорость равна скорости тропки",
            state)
    check(int(route.get("min_speed", -1)) == trail_speed,
            "на маршруте из одной тропки минимум равен её скорости", state)

    # Смешанный маршрут: три тропки и одна тележная дорога. Среднее выше
    # минимума — именно поэтому показываются обе величины.
    _rm.upgrade_road_segment(CITY_ROW + 3, CITY_COL, CITY_ROW + 4, CITY_COL, 2)
    var mixed: Dictionary = _rm.find_route_to_city(CITY_ROW + 4, CITY_COL)
    var expected_avg := (3.0 * float(trail_speed) + float(_gdata.get_road_max_speed(2))) / 4.0
    check(absf(float(mixed.get("avg_speed", 0.0)) - expected_avg) < 0.01,
            "средняя скорость = среднее max_speed по участкам (ожидалось %.2f, получено %.2f)"
                    % [expected_avg, float(mixed.get("avg_speed", 0.0))], state)
    check(int(mixed.get("min_speed", -1)) == trail_speed,
            "минимальная скорость = самое узкое место маршрута", state)
    check(float(mixed.get("avg_speed", 0.0)) > float(mixed.get("min_speed", 0)),
            "на смешанном маршруте средняя скорость должна быть выше минимума", state)

    # Уровни маршрута идут в том же порядке, что и участки: от улучшения к
    # городу. Улучшен был участок, примыкающий к улучшению, — он первый.
    var levels: Array = mixed.get("levels", [])
    check(levels.size() == 4, "у маршрута должен быть уровень каждого участка", state)
    check(int(levels[0]) == 2 and int(levels[3]) == 1,
            "уровни маршрута должны идти от улучшения к городу", state)

    # Скорость пересчитывается после улучшения участка: маршрут — это
    # производная от сети, и кэш обязан сбрасываться вместе с ней.
    _rm.upgrade_road_segment(CITY_ROW + 2, CITY_COL, CITY_ROW + 3, CITY_COL, 2)
    var mixed2: Dictionary = _rm.find_route_to_city(CITY_ROW + 4, CITY_COL)
    check(int(mixed2.get("min_speed", 0)) == trail_speed,
            "узкое место осталось там, где участок ещё тропка", state)

    # Гекса без дороги маршрута не имеет; сам город маршрутом не считается.
    check(not _rm.find_route_to_city(CITY_ROW, CITY_COL - 3).get("ok", true),
            "у гекса без дороги маршрута до города быть не должно", state)
    check(not _rm.find_route_to_city(CITY_ROW, CITY_COL).get("ok", true),
            "сам город не должен считаться гексом с маршрутом", state)


# -------------------------------------------------------
# 5. Улучшение дороги
# -------------------------------------------------------

func _test_upgrade(state: Dictionary) -> void:
    _rm.initialize(CITY_ROW, CITY_COL)
    _rm.build_road_step(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL)

    # Улучшить несуществующий участок нельзя — вернётся false, и шага без
    # работы в проекте не будет.
    check(not _rm.upgrade_road_segment(CITY_ROW, CITY_COL, CITY_ROW + 5, CITY_COL, 2),
            "улучшение несуществующего участка должно возвращать false", state)
    check(_rm.upgrade_road_segment(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL, 2),
            "участок должен улучшаться", state)
    check(_rm.get_segment_level(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL) == 2,
            "после улучшения уровень участка должен быть 2", state)
    # Повторное улучшение до того же уровня — пустая работа.
    check(not _rm.upgrade_road_segment(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL, 2),
            "повторное улучшение до того же уровня должно возвращать false", state)
    # Понижать уровень нельзя: участок не должен деградировать по нажатию.
    check(not _rm.upgrade_road_segment(CITY_ROW, CITY_COL, CITY_ROW + 1, CITY_COL, 1),
            "уровень участка не должен понижаться", state)


# -------------------------------------------------------
# 6. Живая сцена: кнопка, строка маршрута, подсветка, выбор уровня
# -------------------------------------------------------

func _test_live_scene(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var panel = main_map.control_panel
    var rm = main_map.road_manager

    # Исследуем «Колесо»: без него кнопки улучшения дороги из тропки нет.
    if "wheel" not in _cdata.unlocked_technologies:
        _cdata.unlocked_technologies.append("wheel")
    check(_gdata.get_max_unlocked_road_level() == 2,
            "после «Колеса» по умолчанию должен предлагаться второй уровень", state)

    # Ставим улучшение на гексе в влиянии: к нему прокладывается дорога.
    var spot := _find_hex_in_influence(main_map)
    check(not spot.is_empty(), "на живой карте должен найтись гекс в влиянии", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    main_map.tile_data[row][col]["improvement"] = "farm"
    rm.build_road_from(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)

    # Маршрут есть, и он состоит из одних тропок.
    var route: Dictionary = main_map.get_route_to_city(row, col)
    check(route.get("ok", false), "у улучшения с дорогой должен быть маршрут", state)
    check(int(route.get("length", 0)) >= 1,
            "маршрут должен состоять хотя бы из одного участка", state)
    check(int(route.get("min_speed", 0)) == _gdata.get_road_max_speed(1),
            "изначально маршрут идёт по тропкам", state)

    # Клик по улучшению: в панели есть строка маршрута, на карте — подсветка
    # существующих участков маршрута.
    panel.select_hex(row, col)
    check(_collect_text(panel).contains("Маршрут до города"),
            "в панели должна быть строка маршрута до города", state)

    var route_segments: Dictionary = main_map.map_renderer._route_segments
    check(not route_segments.is_empty(),
            "после клика маршрут должен подсвечиваться на карте", state)
    check(route_segments.size() == int(route.get("length", 0)),
            "подсветка должна содержать все участки маршрута", state)

    # Кнопка «Улучшить дорогу» есть: маршрут из тропок, а уровень 2 открыт.
    var actions: Array = panel._collect_actions(row, col, main_map.tile_data[row][col])
    check(_has_action(actions, panel.UPGRADE_ROAD_TYPE),
            "на улучшении с дорогой должна быть кнопка «Улучшить дорогу»", state)

    # Превью улучшения: призрак улучшаемых участков и цена.
    panel._preview_action = {"type": panel.UPGRADE_ROAD_TYPE, "imp_id": "",
            "target_res_id": null, "action_id": "", "label": "Улучшить дорогу",
            "eff_res": "", "selected_culture_id": null, "road_level": 2}
    panel._refresh()
    check(_collect_text(panel._preview_container).contains("Стоимость"),
            "в превью улучшения должна показываться стоимость", state)
    check(main_map.map_renderer._road_preview_segments.size() == int(route.get("length", 0)),
            "призрак превью улучшения должен покрывать все участки маршрута", state)

    var breakdown: Dictionary = main_map.get_road_upgrade_breakdown(row, col, 2)
    check(breakdown.get("ok", false), "разбор улучшения должен быть доступен", state)
    check(int(breakdown.get("cost", 0)) > 0,
            "улучшение до платного уровня должно что-то стоить", state)
    check(int(breakdown.get("segments", 0)) == int(route.get("length", 0)),
            "улучшаться должны все участки маршрута", state)

    # Улучшаем маршрут: уровни участков вырастают, узкое место поднимается.
    check(main_map.start_road_upgrade_project(row, col, 2),
            "улучшение дороги должно запускаться", state)
    var project = main_map.project_manager.get_project_at(row, col)
    check(not project.is_empty(), "улучшение должно стать поэтапным проектом", state)
    await _finish_build(main_map, state)
    for key in rm.get_all_road_segments().keys():
        check(int(rm.road_segments[key]) == 2,
                "все участки маршрута должны стать второго уровня", state)
    var after: Dictionary = main_map.get_route_to_city(row, col)
    check(int(after.get("min_speed", 0)) == _gdata.get_road_max_speed(2),
            "после улучшения узкое место маршрута должно вырасти", state)

    # Повторное улучшение до того же уровня предлагать нечего.
    check(not _has_action(panel._collect_actions(row, col, main_map.tile_data[row][col]),
            panel.UPGRADE_ROAD_TYPE),
            "после улучшения кнопка «Улучшить дорогу» должна исчезнуть", state)
    check(not main_map.get_road_upgrade_breakdown(row, col, 2).get("ok", true),
            "улучшать маршрут до его текущего уровня нечего", state)

    # Уровень влияет на цену новой дороги: тропка бесплатна, тележная — нет.
    var road_target := _find_hex_without_road(main_map)
    if not road_target.is_empty():
        var r2 := int(road_target.row)
        var c2 := int(road_target.col)
        check(main_map.get_road_cost_breakdown(r2, c2, 1).get("cost", -1) == 0,
                "трасса тропки должна стоить 0 труда", state)
        check(main_map.get_road_cost_breakdown(r2, c2, 2).get("cost", 0) > 0,
                "трасса тележной дороги должна стоить труда", state)

    await _test_road_level_in_hex_info(main_map, state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()


# -------------------------------------------------------
# 7. Уровень дороги в тултипе и в левой колонке панели
# -------------------------------------------------------
#
# Обе точки берут ОДИН И ТОТ ЖЕ текст гекса (MapTooltip._build_text), поэтому
# проверяется и текст тултипа, и то, что из него собирается левая колонка.
func _test_road_level_in_hex_info(main_map, state: Dictionary) -> void:
    var rm = main_map.road_manager
    # Тип не указываем: в режиме --script имя класса MapTooltip на этапе
    # компиляции ещё не в кеше (та же причина, по которой в тестах не
    # упоминаются MapHelpers и GameData напрямую).
    var tooltip = main_map.map_tooltip
    var panel = main_map.control_panel

    # Гекс в влиянии, на который пока дороги нет: строки уровня быть не должно.
    var empty_hex := _find_hex_without_road(main_map)
    check(not empty_hex.is_empty(), "для проверки нужен гекс без дороги", state)
    if not empty_hex.is_empty():
        var e_row := int(empty_hex.row)
        var e_col := int(empty_hex.col)
        var empty_text: String = tooltip._build_text(e_row, e_col,
                main_map.tile_data, main_map.city_row, main_map.city_col)
        check(not empty_text.contains("Дорога"),
                "на гексе без дороги строки уровня быть не должно", state)

    # Гекс с тропкой: строка есть, и расширенный тултип на нём показывается.
    # Берём гекс БЕЗ дороги (а не первый свободный): к этому моменту тест уже
    # настроил сеть, и первый свободный гекс мог оказаться подключённым к
    # улучшенной дороге из предыдущих шагов — тогда проверялось бы не то.
    var spot := _find_hex_without_road(main_map)
    check(not spot.is_empty(), "для проверки нужен гекс без дороги", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    # build_road_from, а не build_road_step: он реально ПРОКЛАДЫВАЕТ путь до
    # сети, а build_road_step только помечает один участок — между городом и
    # гексом может быть несколько гексов, и участка «город → гекс» может не
    # существовать вовсе.
    rm.build_road_from(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
    var trail_levels: Array = rm.get_hex_road_levels(row, col)
    check(trail_levels == [1],
            "дорога к гексу по умолчанию — тропка (получено уровней: %s)" % [trail_levels],
            state)
    check(tooltip.has_extended_tooltip_info(row, col, main_map.tile_data),
            "на гексе с дорогой расширенный тултип должен показываться", state)

    # Расширенный тултип: строка уровня добавляется ДО ранних выходов
    # update_extended_tooltip, поэтому проверяем её на гексе без улучшения.
    tooltip.update_extended_tooltip(row, col, main_map.tile_data,
            main_map.city_row, main_map.city_col)
    var extended_text := _collect_text(tooltip._tooltip_products_container)
    check(extended_text.contains("Дорога: Тропка (уровень 1, до 10 ед./сек на участок)"),
            "в расширенном тултипе должен быть уровень дороги (получено: %s)" % extended_text,
            state)

    # Обычный тултип уровня дороги НЕ показывает: уровень — не свойство гекса,
    # а его связи с городом, и для этого есть расширенный блок и левая колонка.
    var text: String = tooltip._build_text(row, col, main_map.tile_data,
            main_map.city_row, main_map.city_col)
    check(not text.contains("Дорога"),
            "в обычном тултипе строки уровня дороги быть не должно (получено: %s)" % text,
            state)

    # Смешанный стык: тропка уходит от гекса, тележная дорога приходит.
    # Показываем оба уровня — выбрать один наугад значило бы соврать о второй
    # дороге. Стык строится явно: ещё один участок от гекса строится тропкой,
    # затем улучшается до тележной дороги.
    var edge := _hex_in_direction(main_map, row, col)
    if not edge.is_empty() \
            and rm.build_road_step(row, col, int(edge.row), int(edge.col)):
        check(rm.upgrade_road_segment(row, col, int(edge.row), int(edge.col), 2),
                "участок от гекса должен улучшаться", state)
        var mixed_levels: Array = rm.get_hex_road_levels(row, col)
        check(mixed_levels.size() >= 2 and mixed_levels.has(1) and mixed_levels.has(2),
                "на стыке должны быть собраны оба уровня (получено: %s)" % [mixed_levels],
                state)
        var mixed_text: String = tooltip.road_level_line(row, col)
        check(mixed_text.contains("уровень 1") and mixed_text.contains("уровень 2"),
                "на стыке строка уровня должна перечислять оба (получено: %s)" % mixed_text,
                state)

    # Левая колонка панели собирается из того же текста — строка обязана быть
    # и там, а не только в тултипе под курсором.
    panel.select_hex(row, col)
    check(_collect_text(panel).contains("уровень"),
            "в левой колонке панели должен быть показан уровень дороги", state)


# Соседний гекс в направлении от (row, col), через который можно протянуть
# второй участок (для проверки стыка уровней).
func _hex_in_direction(main_map, row: int, col: int) -> Dictionary:
    var main_map_ref = main_map
    var candidates := [
        {"row": row - 1, "col": col},
        {"row": row + 1, "col": col},
        {"row": row, "col": col - 1},
        {"row": row, "col": col + 1},
    ]
    for candidate in candidates:
        var t_row := int(candidate.row)
        var t_col := int(candidate.col)
        if t_row < 0 or t_col < 0 or t_row >= main_map_ref.map_rows \
                or t_col >= main_map_ref.map_cols:
            continue
        var tile = main_map_ref.tile_data[t_row][t_col]
        if tile == null or tile.get("has_town", false):
            continue
        if _mh.is_water_terrain(tile.get("terrain", "plain")):
            continue
        return {"row": t_row, "col": t_col}
    return {}


# -------------------------------------------------------
# Хелперы
# -------------------------------------------------------

func _has_action(actions: Array, type: String) -> bool:
    for action in actions:
        if str(action.get("type", "")) == type:
            return true
    return false

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

# Первый свободный гекс в Кольце Влияния: сухой, известный, без улучшения,
# городка и дороги.
func _find_hex_in_influence(main_map) -> Dictionary:
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[row][col]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if _hex_is_busy(main_map, row, col, tile):
                continue
            return {"row": row, "col": col}
    return {}

# Гекс в Кольце Влияния без дороги — цель спецдействия «Построить дорогу».
# Улучшений тут может быть сколько угодно: клетка с улучшением дорогу уже
# получила автоматически.
func _find_hex_without_road(main_map) -> Dictionary:
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[row][col]
            if tile == null or _hex_is_busy(main_map, row, col, tile):
                continue
            if main_map.road_manager.is_hex_connected(row, col):
                continue
            return {"row": row, "col": col}
    return {}

# Общие «гекс не годится» проверки: городок, чужая территория, туман, вода.
func _hex_is_busy(main_map, row: int, col: int, tile: Dictionary) -> bool:
    if tile.get("has_town", false) or tile.get("decorative", false):
        return true
    if tile.get("in_town_influence", false):
        return true
    if not main_map.is_hex_known(row, col):
        return true
    return _mh.is_water_terrain(tile.get("terrain", "plain"))

# Прогоняет труд до конца, чтобы проект завершился.
func _finish_build(main_map, state: Dictionary) -> void:
    var bm = main_map.build_manager
    var labor: float = maxf(1.0, float(_cdata.get_total_labor()))
    for i in range(400):
        bm._process(labor * 2.0)
        if main_map.project_manager.projects.is_empty():
            return
    check(false, "проект улучшения дороги не завершился за отведённое число кадров", state)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    print("FAILED: %s" % message)
    push_error("ASSERT: %s" % message)