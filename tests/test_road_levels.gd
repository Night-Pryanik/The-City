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
#   7. УРОВЕНЬ ДОРОГИ НА ГЕКСЕ. Правило «уровень гекса = максимум по
#      примыкающим участкам»: на перекрёстке из двух тропок и одной тележной
#      дороги гекс показывает тележную дорогу, а тропки остаются тропками.
#      Строка с уровнем показывается в расширенном тултипе и в левой колонке
#      панели управления; в обычном тултипе её нет.
#   8. КНОПКА УЛУЧШЕНИЯ. Остаётся на частично улучшенном маршруте: улучшен
#      один участок из нескольких — кнопка обязана быть, пока есть тропки.
#      Превью улучшения дороги не содержит блока производства: игрок нажал
#      кнопку ради дороги, и «Будет производить» к улучшению дороги
#      отношения не имеет (а блок вытеснял выбор уровня вниз).
#   9. РЕФРЕШ И РАСШИРЕННЫЙ БЛОК. Периодическое обновление содержимого (оно
#      идёт только по «растущим» ресурсам, то есть по пастбищам) не стирает
#      строку уровня дороги: расширенный блок живёт дольше одного вызова.
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
# HexUtils грузим через load(): имя класса в режиме --script на этапе
# компиляции ещё не в кеше (та же причина, по которой MapHelpers тоже
# берётся через load()).
var _hu = null

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
    _hu = load("res://scripts/HexUtils.gd")

    _rm = load("res://scripts/road_manager.gd").new()
    get_root().add_child(_rm)

    if WATCHDOG.wants_case("road_data"):
        _test_road_data(state)
    if WATCHDOG.wants_case("unlock_by_wheel"):
        _test_unlock_by_wheel(state)
    if WATCHDOG.wants_case("segment_level"):
        _test_segment_level(state)
    if WATCHDOG.wants_case("route_and_speeds"):
        _test_route_and_speeds(state)
    if WATCHDOG.wants_case("upgrade"):
        _test_upgrade(state)

    get_root().remove_child(_rm)
    _rm.free()
    _rm = null

    if WATCHDOG.wants_case("live_scene"):
        await _test_live_scene(state)

    WATCHDOG.report_skipped()
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

    # Тропка платная: дорога, строящаяся вместе с улучшением, стоит ровно
    # столько же, сколько такая же дорога, построенная отдельно. Раньше здесь
    # стояла проверка на 0 — из-за неё постройка улучшения на дальнем гексе
    # была бесплатной и неоплачиваемой, а дорога к нему не строилась поэтапно.
    check(_gdata.get_road_work_cost(1) > 0,
            "уровень 1 (тропка) должен быть платным", state)
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

    # Сплошная тропка: средняя равна скорости тропки.
    var trail_speed: int = _gdata.get_road_max_speed(1)
    var cart_speed: int = _gdata.get_road_max_speed(2)
    check(absf(float(route.get("avg_speed", 0.0)) - float(trail_speed)) < 0.01,
            "на маршруте из одной тропки средняя скорость равна скорости тропки",
            state)
    check(not route.has("min_speed"),
            "маршрут не должен содержать «узкое место»: скорость маршрута — средняя",
            state)

    # Смешанный маршрут: три тропки и одна тележная дорога. Среднее выше
    # скорости тропки — плохая ямка не должна ронять скорость всего хайвея.
    _rm.upgrade_road_segment(CITY_ROW + 3, CITY_COL, CITY_ROW + 4, CITY_COL, 2)
    var mixed: Dictionary = _rm.find_route_to_city(CITY_ROW + 4, CITY_COL)
    var expected_avg := (3.0 * float(trail_speed) + float(cart_speed)) / 4.0
    check(absf(float(mixed.get("avg_speed", 0.0)) - expected_avg) < 0.01,
            "средняя скорость = среднее max_speed по участкам (ожидалось %.2f, получено %.2f)"
                    % [expected_avg, float(mixed.get("avg_speed", 0.0))], state)
    check(float(mixed.get("avg_speed", 0.0)) > float(trail_speed),
            "одна тележная дорога должна поднимать среднюю, а не понижать её до минимума",
            state)

    # Ключевой пример автора: девять тележных дорог и одна тропка = 28 ед./сек,
    # а не 10. Отдельный экземпляр менеджера — иначе длинный маршрут перебил бы
    # сеть, на которой проверяются уровни и порядок сегментов выше.
    var rm2 = load("res://scripts/road_manager.gd").new()
    get_root().add_child(rm2)
    rm2.initialize(CITY_ROW, CITY_COL)
    for i in range(10):
        rm2.build_road_step(CITY_ROW + i, CITY_COL, CITY_ROW + i + 1, CITY_COL,
                false, 2)
    var long_route: Dictionary = rm2.find_route_to_city(CITY_ROW + 10, CITY_COL)
    check(long_route.get("ok", false),
            "маршрут длиной 10 участков должен находиться", state)
    check(int(long_route.get("length", 0)) == 10,
            "маршрут должен состоять из 10 участков (получено %d)"
                    % int(long_route.get("length", 0)), state)
    check(absf(float(long_route.get("avg_speed", 0.0)) - 30.0) < 0.01,
            "десять тележных дорог дают среднюю 30 ед./сек", state)

    # Одна тропка на десяти участках: (9*30 + 1*10)/10 = 28.
    #
    # Конфигурация строится сразу, а не понижением уровня: upgrade_road_segment
    # умеет только ПОВЫШАТЬ (участок не ниже уровня — false), поэтому собрать
    # смешанный маршрут понижением нельзя в принципе.
    var rm3 = load("res://scripts/road_manager.gd").new()
    get_root().add_child(rm3)
    rm3.initialize(CITY_ROW, CITY_COL)
    for i in range(9):
        rm3.build_road_step(CITY_ROW + i, CITY_COL, CITY_ROW + i + 1, CITY_COL,
                false, 2)
    rm3.build_road_step(CITY_ROW + 9, CITY_COL, CITY_ROW + 10, CITY_COL, false, 1)
    var mixed_long: Dictionary = rm3.find_route_to_city(CITY_ROW + 10, CITY_COL)
    check(int(mixed_long.get("length", 0)) == 10,
            "смешанный маршрут должен состоять из 10 участков", state)
    check(absf(float(mixed_long.get("avg_speed", 0.0)) - 28.0) < 0.01,
            "девять тележных дорог и одна тропка = (9*30 + 1*10)/10 = 28 ед./сек"
                    + " (получено %.2f)" % float(mixed_long.get("avg_speed", 0.0)), state)
    # Главное: это НЕ 10 ед./сек. Одна плохая ямка не роняет весь хайвей.
    check(float(mixed_long.get("avg_speed", 0.0)) > 25.0,
            "одна тропка не должна ронять маршрут до её скорости 10 ед./сек", state)
    get_root().remove_child(rm2)
    rm2.free()
    get_root().remove_child(rm3)
    rm3.free()

    # Уровни маршрута идут в том же порядке, что и участки: от улучшения к
    # городу. Улучшен был участок, примыкающий к улучшению, — он первый.
    var levels: Array = mixed.get("levels", [])
    check(levels.size() == 4, "у маршрута должен быть уровень каждого участка", state)
    check(int(levels[0]) == 2 and int(levels[3]) == 1,
            "уровни маршрута должны идти от улучшения к городу", state)

    # Скорость пересчитывается после улучшения участка: маршрут — это
    # производная от сети, и кэш обязан сбрасываться вместе с ней.
    # Две тележные дороги и две тропки: (2*30 + 2*10)/4 = 20.
    _rm.upgrade_road_segment(CITY_ROW + 2, CITY_COL, CITY_ROW + 3, CITY_COL, 2)
    var mixed2: Dictionary = _rm.find_route_to_city(CITY_ROW + 4, CITY_COL)
    check(absf(float(mixed2.get("avg_speed", 0.0)) - 20.0) < 0.01,
            "после улучшения средняя пересчиталась: (2*30 + 2*10)/4 = 20 ед./сек"
                    + " (получено %.2f)" % float(mixed2.get("avg_speed", 0.0)), state)

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
    check(absf(float(route.get("avg_speed", 0.0)) - float(_gdata.get_road_max_speed(1))) < 0.01,
            "изначально маршрут идёт по одним тропкам, и средняя равна их скорости",
            state)

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
    check(absf(float(after.get("avg_speed", 0.0)) - float(_gdata.get_road_max_speed(2))) < 0.01,
            "после улучшения средняя маршрута должна вырасти до скорости тележной дороги",
            state)

    # Повторное улучшение до того же уровня предлагать нечего.
    check(not _has_action(panel._collect_actions(row, col, main_map.tile_data[row][col]),
            panel.UPGRADE_ROAD_TYPE),
            "после улучшения кнопка «Улучшить дорогу» должна исчезнуть", state)
    check(not main_map.get_road_upgrade_breakdown(row, col, 2).get("ok", true),
            "улучшать маршрут до его текущего уровня нечего", state)

    # Уровень влияет на цену новой дороги: тропка дешевле тележной, но обе
    # стоят труда — включая ту, что строится вместе с улучшением.
    var road_target := _find_hex_without_road(main_map)
    if not road_target.is_empty():
        var r2 := int(road_target.row)
        var c2 := int(road_target.col)
        check(main_map.get_road_cost_breakdown(r2, c2, 1).get("cost", 0) > 0,
                "трасса тропки должна стоить труда", state)
        check(main_map.get_road_cost_breakdown(r2, c2, 2).get("cost", 0)
                > main_map.get_road_cost_breakdown(r2, c2, 1).get("cost", 0),
                "трасса тележной дороги должна стоить дороже тропки", state)

    if WATCHDOG.wants_case("road_level_in_hex_info"):
        await _test_road_level_in_hex_info(main_map, state)
    if WATCHDOG.wants_case("extended_tooltip_survives_refresh"):
        await _test_extended_tooltip_survives_refresh(main_map, state)
    if WATCHDOG.wants_case("upgrade_button_on_partial_route"):
        await _test_upgrade_button_on_partial_route(main_map, state)

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
    check(rm.get_hex_road_level(row, col) == 1,
            "дорога к гексу по умолчанию — тропка", state)
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

    # Перекрёсток из двух тропок и одной тележной дороги — ровно тот случай,
# ради которого введено правило «уровень гекса = максимум»: гекс показывает
# тележную дорогу (уровень 2), как он и выглядит на карте, хотя две тропки
# через него проходят и остаются тропками.
    #
    # Схема (см. _test_crossroad_* ниже): гекс соединён с городом тропкой,
    # к нему же примыкают ещё два соседа — с тропкой и с тележной дорогой.
    var edge1 := _hex_in_direction(main_map, row, col)
    if not edge1.is_empty():
        # Сосед с тропкой: строим участок уровня 1.
        rm.build_road_step(row, col, int(edge1.row), int(edge1.col))
        var edge2 := _hex_in_direction(main_map, row, col, int(edge1.row), int(edge1.col))
        if not edge2.is_empty():
            # Сосед с тележной дорогой: тот же участок строится тропкой и
            # улучшается — так проверяется, что уровень гекса берётся по
            # максимуму, а не по «первому попавшемуся» участку.
            if rm.build_road_step(row, col, int(edge2.row), int(edge2.col)):
                rm.upgrade_road_segment(row, col, int(edge2.row), int(edge2.col), 2)
                check(rm.get_hex_road_level(row, col) == 2,
                        "на перекрёстке 2 тропки + тележная дорога уровень гекса должен быть 2",
                        state)
                # Тропки при этом остаются тропками: уровень гекса —
                # производная величина, а не распорка «поднять всё сразу».
                check(rm.get_segment_level(row, col, int(edge1.row), int(edge1.col)) == 1,
                        "участок-тропка через перекрёсток должен остаться тропкой",
                        state)
                var mixed_text: String = tooltip.road_level_line(row, col)
                check(mixed_text.contains("уровень 2") and mixed_text.contains("Тележная дорога"),
                        "строка уровня на перекрёстке должна называть тележную дорогу (получено: %s)"
                                % mixed_text, state)

    # Левая колонка панели собирается из того же текста — строка обязана быть
    # и там, а не только в тултипе под курсором.
    panel.select_hex(row, col)
    check(_collect_text(panel).contains("уровень"),
            "в левой колонке панели должен быть показан уровень дороги", state)

    # Превью улучшения дороги НЕ содержит блока производства: игрок нажал
    # кнопку улучшения дороги ради дороги, а «Будет производить» относится
    # к улучшению, которое он не строит. Блок к тому же вытеснял селектор
    # уровней дорог вниз и заставлял прокручивать превью.
    if _gdata.get_max_unlocked_road_level() <= 1:
        return
    panel._preview_action = {"type": panel.UPGRADE_ROAD_TYPE, "imp_id": "",
            "target_res_id": null, "action_id": "", "label": "Улучшить дорогу",
            "eff_res": "", "selected_culture_id": null, "road_level": 2}
    panel._refresh()
    var upgrade_preview_text := _collect_text(panel._preview_container)
    check(not upgrade_preview_text.contains("Будет производить"),
            "в превью улучшения дороги не должно быть блока производства (получено: %s)"
                    % upgrade_preview_text, state)
    check(upgrade_preview_text.contains("Уровень дороги:"),
            "в превью улучшения дороги должен быть выбор уровня (получено: %s)"
                    % upgrade_preview_text, state)
    check(upgrade_preview_text.contains("Стоимость"),
            "в превью улучшения дороги должна быть цена (получено: %s)"
                    % upgrade_preview_text, state)


# Первый свободный гекс в Кольце Влияния на расстоянии не меньше min_dist
# от города. Нужен там, где важна ДЛИНА маршрута: маршрут из одного участка
# нельзя частично улучшить, и проверка «кнопка осталась» на нём бессмысленна.
func _find_hex_far_from_city(main_map, min_dist: int) -> Dictionary:
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[row][col]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if _hex_is_busy(main_map, row, col, tile):
                continue
            if main_map.road_manager.is_hex_connected(row, col):
                continue
            if _hu.hex_distance(row, col, main_map.city_row, main_map.city_col) < min_dist:
                continue
            return {"row": row, "col": col}
    return {}

# Свободный сосед гекса (row, col) в указанном направлении — для построения
# схемы перекрёстка. exclude уже использованного соседа нельзя: иначе второй
# участок может лечь на уже построенный, и build_road_step вернёт false.
func _hex_in_direction(main_map, row: int, col: int,
        exclude_row: int = -1, exclude_col: int = -1) -> Dictionary:
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
        if t_row == exclude_row and t_col == exclude_col:
            continue
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
# 8. Кнопка «Улучшить дорогу» на частично улучшенном маршруте
# -------------------------------------------------------
#
# Регрессия: кнопка проверяла МАКСИМУМ уровней маршрута, и стоило улучшить
# ОДИН участок из четырёх, как максимум становился равен лучшему уровню и
# кнопка исчезала — хотя три тропки оставались. Для игрока это выглядело как
# «маршрут уже улучшен», и дотянуть дорогу было нечем.
func _test_upgrade_button_on_partial_route(main_map, state: Dictionary) -> void:
    var panel = main_map.control_panel
    var rm = main_map.road_manager

    var spot := _find_hex_far_from_city(main_map, 4)
    check(not spot.is_empty(),
            "для проверки нужен гекс в удалении от города (маршрут из нескольких участков)",
            state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    main_map.tile_data[row][col]["improvement"] = "farm"
    rm.build_road_from(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
    if _gdata.get_max_unlocked_road_level() <= 1:
        # «Колесо» не изучено: улучшать некуда, кнопки нет — и это правильно.
        check(not _has_action(panel._collect_actions(row, col, main_map.tile_data[row][col]),
                panel.UPGRADE_ROAD_TYPE),
                "без исследованной технологии кнопки улучшения быть не должно", state)
        return
    check(_has_action(panel._collect_actions(row, col, main_map.tile_data[row][col]),
            panel.UPGRADE_ROAD_TYPE),
            "на маршруте из тропок кнопка улучшения должна быть", state)

    # Улучшаем ОДИН участок маршрута — не весь. Остальные участки остаются
    # тропками, и кнопка обязана остаться: маршрут ещё не доведён до конца.
    var route: Dictionary = main_map.get_route_to_city(row, col)
    var segments: Array = route.get("segments", [])
    check(segments.size() >= 2,
            "для проверки нужен маршрут хотя бы из двух участков (получено %d)"
                    % segments.size(), state)
    if segments.size() < 2:
        return
    var first: String = str(segments[0])
    var parts := first.split("|")
    var a := parts[0].split(",")
    var b := parts[1].split(",")
    check(rm.upgrade_road_segment(int(a[0]), int(a[1]), int(b[0]), int(b[1]), 2),
            "один участок маршрута должен улучшаться", state)

    var after: Dictionary = main_map.get_route_to_city(row, col)
    var still_trails := 0
    for level in after.get("levels", []):
        if int(level) < _gdata.get_max_unlocked_road_level():
            still_trails += 1
    check(still_trails > 0,
            "после улучшения одного участка маршрут не должен стать целиком лучшим", state)
    check(_has_action(panel._collect_actions(row, col, main_map.tile_data[row][col]),
            panel.UPGRADE_ROAD_TYPE),
            "на частично улучшенном маршруте кнопка улучшения обязана остаться", state)


# -------------------------------------------------------
# 9. Рефреш содержимого не стирает расширенный блок
# -------------------------------------------------------
#
# Регрессия: на гексе с пастбищем строка «Дорога: …» в расширенном тултипе
# жила ровно один тик. Расширенный блок рисуется один раз за наведение, но
# InputHandler с интервалом resource_display_interval зовёт update_tooltip_text
# для «растущих» ресурсов (time_to_mature > 0 — то есть только для пастбищ), а
# тот пересобирает контейнер с нуля и заменяет блок базовым списком. Строка
# исчезала и до ухода курсора не возвращалась. Фермы и лесные делянки не
# задеты: у них time_to_mature нет, рефреш не вызывается.
func _test_extended_tooltip_survives_refresh(main_map, state: Dictionary) -> void:
    var rm = main_map.road_manager
    # Тип не указываем — как в _test_road_level_in_hex_info: имя класса
    # MapTooltip на этапе компиляции этого файла ещё не в кеше.
    var tooltip = main_map.map_tooltip

    var res_id := _find_growing_resource_id()
    check(not res_id.is_empty(),
            "в данных нужен растущий ресурс (time_to_mature > 0) для проверки рефреша",
            state)
    if res_id.is_empty():
        return

    var spot := _find_hex_in_influence(main_map)
    check(not spot.is_empty(),
            "для проверки рефреша нужен гекс в влиянии", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["improvement"] = str(_gdata.raw_resources.get(res_id, {}).get("improved_by", "pasture"))
    tile["resource"] = res_id
    rm.build_road_from(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
    check(not tooltip.road_level_line(row, col).is_empty(),
            "к гексу с пастбищем должна быть проложена дорога", state)

    # Наведение: сначала базовый тултип, затем по задержке — расширенный блок.
    main_map.update_tooltip_text(row, col)
    check(tooltip.has_extended_tooltip_info(row, col, main_map.tile_data),
            "на гексе с дорогой расширенный тултип должен показываться", state)
    main_map.update_extended_tooltip(row, col)
    var extended_text := _collect_text(tooltip._tooltip_products_container)
    check(extended_text.contains("Дорога:"),
            "расширенный тултип должен содержать строку уровня дороги (получено: %s)"
                    % extended_text, state)

    # Рефреш. Меняем fill_time, чтобы текст заполненности действительно изменился:
    # иначе сработал бы ранний выход «ничего не изменилось», контейнер бы не
    # трогали — и проверка прошла бы, ничего не проверяя. Именно изменившийся
    # текст и запускает рефреш в игре.
    var ttm: float = float(_gdata.raw_resources.get(res_id, {}).get("time_to_mature", 60.0))
    tile["fill_time"] = ttm * 0.5
    main_map.update_tooltip_text(row, col)
    var after_refresh := _collect_text(tooltip._tooltip_products_container)
    check(after_refresh.contains("Дорога:"),
            "после рефреша содержимого строка уровня дороги обязана остаться (получено: %s)"
                    % after_refresh, state)
    # Ровно один раз: строка не должна ни задваиваться, ни теряться.
    check(_count_occurrences(after_refresh, "Дорога:") == 1,
            "строка уровня дороги должна быть ровно одна (получено: %s)" % after_refresh, state)

    # Второй тик подряд — на пастбище рефреш ходит каждый интервал, а не раз.
    tile["fill_time"] = ttm * 0.75
    main_map.update_tooltip_text(row, col)
    var after_second := _collect_text(tooltip._tooltip_products_container)
    check(after_second.contains("Дорога:"),
            "после второго рефреша строка уровня дороги обязана остаться (получено: %s)"
                    % after_second, state)

    # После сброса привязки (смена гекса / скрытие тултипа) расширенный блок
    # больше не рисуется: базовый тултип уровня дороги по-прежнему не показывает.
    main_map.clear_extended_tooltip()
    main_map.update_tooltip_text(row, col)
    var after_clear := _collect_text(tooltip._tooltip_products_container)
    check(not after_clear.contains("Дорога:"),
            "после сброса расширенного блока строка уровня дороги быть не должна (получено: %s)"
                    % after_clear, state)

# Id ресурса с time_to_mature > 0 (растущий — рефрешится на пастбищах).
# Берём из данных, а не хардкодим «cows»: проверка должна пережить переименование
# или замену ресурса в animals.json.
func _find_growing_resource_id() -> String:
    for id in _gdata.raw_resources.keys():
        var data: Dictionary = _gdata.raw_resources.get(id, {})
        if not data.has("produces"):
            continue
        if not _mh.is_growing_resource(data):
            continue
        if str(data.get("improved_by", "")) == "":
            continue
        return str(id)
    return ""


# -------------------------------------------------------
# Хелперы
# -------------------------------------------------------

# Сколько раз подстрока встречается в тексте — для проверки, что строка не
# задваивалась. Строки тултипа склеены по "\n", поэтому обычного contains()
# (проверка «есть ли хоть раз») для этого недостаточно.
func _count_occurrences(text: String, sub: String) -> int:
    if sub.is_empty():
        return 0
    var count := 0
    var pos := text.find(sub)
    while pos != -1:
        count += 1
        pos = text.find(sub, pos + sub.length())
    return count

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
# городка и дороги — И с дорогой, до которой реально можно дойти.
#
# Проверка плана обязательна: вызывающие потом строят к гексу дорогу, а на части
# случайно сгенерированных карт свободный гекс оказывается отрезан рекой, и
# дорога к нему не строится. Тогда проверка падала бы из-за карты, а не из-за
# правила. Если подходящего гекса нет вовсе — возвращаем пусто, и вызывающий
# честно сообщает, что сценарий пропущен.
func _find_hex_in_influence(main_map) -> Dictionary:
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[row][col]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if _hex_is_busy(main_map, row, col, tile):
                continue
            var plan: Dictionary = main_map.get_road_plan(row, col)
            if not plan.get("ok", false):
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
            # Уровень гекса, а не is_hex_connected: у гекса может не быть дороги
            # города, но через него может проходить дорога ГОРОДКА (её трасса
            # ищется по всей карте и может выйти за кольцо). Строка уровня
            # теперь описывает и её, поэтому «гекс без дороги» — это ровно
            # get_hex_road_level == 0.
            if main_map.road_manager.get_hex_road_level(row, col) > 0:
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
