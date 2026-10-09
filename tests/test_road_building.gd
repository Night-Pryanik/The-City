# Headless-тест дорог, которые строит игрок (спецдействие «Построить
# дорогу», action_type "road"), и соединения города с городком.
#   godot --headless --path . --script res://tests/test_road_building.gd
#
# Проверки (на детерминированной синтемической карте + живая сцена MainMap):
#   1. Цена УЧАСТКА дороги = база × множитель местности × множитель дальности
#      (MapHelpers.get_road_step_work_cost). Дальше от города — дороже; в
#      трудной местности — дороже. Коэффициент дальности дороги берётся из
#      game_balance.json и ОТДЕЛЕН от коэффициента улучшений: множитель
#      дальности множится на длину трассы, и при 0.25 дорога к дальнему
#      городку становилась бы недоступной. Надбавки за длину трассы нет.
#   2. Планирование дороги ничего не меняет (план — чистый расчёт для
#      превью), а после build_road_to гекс подключён к сети города и до
#      города идёт цепочка сегментов (проверка формы сети, а не флага).
#   3. Дорога не строится там, где её быть не может: вода, уже подключённый
#      гекс, гекс, отрезанный водой от города.
#   4. Дорога до ГОРОДКА идёт ДО САМОГО ГОРОДКА (в его центр) и на выбранном
#      уровне, а не до ближайшей дороги в кольце влияния, где шоссе упиралось бы
#      в тропку городка; после постройки сети города и городка пересеклись
#      (is_town_linked_to_city), а сегменты связи помечены отдельно.
#   4a. Дорога, которую строит игрок, идёт ТОЛЬКО по известной территории
#      (в Кольце Влияния или разведано): разведанный городок без разведанного
#      пути к нему недостижим, причина зовёт разведчиков, а после разведки
#      коридора дорога появляется. Автоматические сети дорог фильтр не получают.
#   4b. Уровень дороги доходит ДО ГОРОДКА: каждый участок трассы (включая
#      входящий в кольцо) — выбранного уровня, и на гексе городка уровень тоже
#      выбранный. Раньше трасса обрывалась на дороге кольца, и последний
#      участок был тропкой городка.
#   5. Восстановление из сейва: флаг road_built на гексе и road_linked в
#      записи городка возвращают и дорогу, и связь (rebuild_player_roads),
#      а сериализация их записывает.
#   6. Торговля: гейт — одна функция town_manager.is_trade_available; окно
#      городка открывается БЕЗ дороги (доступ свободен), но торговля помечена
#      как недоступная и после постройки дороги становится доступной.
#   7. «Призрачная» дорога на карте: пока открыто превью «Построить дорогу»,
#      маршрут нарисован (только новые сегменты плана) и исчезает вместе с
#      превью; у городка маршрут целиком идёт по разведанной земле.
#   8. Уровни дороги (уровень выбран в превью, бесплатная тропка строится
#      сразу и не занимает очередь проекта). Собственные проверки уровней,
#      маршрута и улучшения — в tests/test_road_levels.gd.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как
# вечное молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const ROAD_ACTION_ID := "build_road"

var _rm = null
var _tm = null
# Автолоады берём узлами дерева сцены: в режиме --script имена GameData и
# CityData на этапе компиляции этого файла ещё недоступны.
var _gdata = null
var _cdata = null
# MapHelpers и HexUtils тоже НЕЛЬЗЯ упоминать по имени класса: MapHelpers
# обращается к автозагрузке GameData, и в режиме --script такая зависимость
# не компилируется (обход — load(), как в test_town_roads для HexUtils).
var _mh = null
var _hu = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Автолоады берём через дерево сцены: в режиме --script имена
    # GameData/CityData недоступны на этапе компиляции этого файла.
    # new_game() заодно грузит все данные (спецдействия в том числе).
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _mh = load("res://scripts/map_helpers.gd")
    _hu = load("res://scripts/HexUtils.gd")

    _rm = load("res://scripts/road_manager.gd").new()
    get_root().add_child(_rm)
    _tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(_tm)

    if WATCHDOG.wants_case("cost_per_hex"):
        _test_cost_per_hex(state)
    if WATCHDOG.wants_case("plan_and_build_hex"):
        _test_plan_and_build_hex(state)
    if WATCHDOG.wants_case("impossible_targets"):
        _test_impossible_targets(state)
    if WATCHDOG.wants_case("town_road_needs_known_territory"):
        _test_town_road_needs_known_territory(state)
    if WATCHDOG.wants_case("ghost_segments"):
        _test_ghost_segments(state)
    if WATCHDOG.wants_case("town_link"):
        _test_town_link(state)
    if WATCHDOG.wants_case("town_road_level"):
        _test_town_road_level(state)
    if WATCHDOG.wants_case("restore_from_save_flags"):
        _test_restore_from_save_flags(state)

    # Живая сцена проверяется последней и отдельно освобождается: MainMap
    # создаёт собственные TownManager/RoadManager.
    get_root().remove_child(_tm)
    _tm.free()
    get_root().remove_child(_rm)
    _rm.free()
    _tm = null
    _rm = null

    if WATCHDOG.wants_case("live_scene"):
        await _test_live_scene(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("ROAD BUILDING TEST FAILED")
        quit(1)
    else:
        print("ROAD BUILDING TEST OK")
        quit(0)

# -------------------------------------------------------
# Синтетическая карта: равнина без ресурсов, рек и улучшений
# -------------------------------------------------------

const ROWS := 20
const COLS := 20
const CITY_ROW := 10
const CITY_COL := 10
const TOWN_ROW := 4
const TOWN_COL := 4

# Первый уровень дороги с ненулевой ценой участка. Уровень 1 (тропка)
# бесплатен, а проверки формулы цены нуждаются в базе, которую можно
# умножать на множители. Если платных уровней в данных нет — тест падает
# здесь, а не молча проверяет нули.
func _first_paid_road_level(state: Dictionary) -> int:
    for level in _gdata.get_road_levels():
        if _gdata.get_road_work_cost(int(level)) > 0:
            return int(level)
    check(false, "в roads.json должен быть хотя бы один платный уровень дороги",
            state)
    return 1

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
                "in_town_influence": false, "road_built": false,
            })
        tile_data.append(row)
    return tile_data

# Кольцо влияния синтетического городка: все гексы на расстоянии <= 3.
func _make_town_ring() -> Array:
    var ring: Array = []
    for r in range(ROWS):
        for c in range(COLS):
            if _hu.hex_distance(r, c, TOWN_ROW, TOWN_COL) <= 3:
                ring.append({"row": r, "col": c})
    return ring

# Запись городка, достаточная для сетей дорог и торговли.
func _make_town() -> Dictionary:
    return {
        "id": "test_town", "row": TOWN_ROW, "col": TOWN_COL, "name": "Тестовый",
        "influence_radius": 3, "influence_hexes": _make_town_ring(),
        "sell_pool": [], "buy_pool": [], "road_linked": false,
    }

# -------------------------------------------------------
# 1. Цена УЧАСТКА дороги: база × местность × дальность
# -------------------------------------------------------

func _test_cost_per_hex(state: Dictionary) -> void:
    check(_gdata.special_actions.has(ROAD_ACTION_ID),
            "в data/special_actions.json должно быть спецдействие «Построить дорогу»",
            state)
    var sa: Dictionary = _gdata.special_actions.get(ROAD_ACTION_ID, {})
    check(str(sa.get("action_type", "")) == "road",
            "у спецдействия дороги должен быть action_type == \"road\"", state)
    check(not sa.has("work_cost"),
            "цену участка нельзя держать в спецдействии: она свойство уровня дороги",
            state)

    # База цены участка берётся из УРОВНЯ дороги (data/roads.json), а не из
    # спецдействия. Проверяем на базовом уровне 1 (тропка): он не бесплатный,
    # поэтому на нём есть и база, и множители. Дорога к улучшению стоит
    # ровно столько же — обнулять её ради постройки улучшения нельзя.
    var paid_level := _first_paid_road_level(state)
    var per_hex: int = _gdata.get_road_work_cost(paid_level)
    check(per_hex > 0, "цена за участок дороги должна быть задана в roads.json", state)
    check(_gdata.get_road_work_cost(1) > 0,
            "базовая тропка тоже должна быть платной: дорога к улучшению не бесплатна",
            state)

    # Коэффициент дальности участка — из game_balance.json и БЕЗ тех-модификаторов.
    var road_mod: float = float(_gdata.game_balance.get("road_distance_cost_modifier_per_hex", -1.0))
    check(road_mod > 0.0,
            "в game_balance.json должен быть road_distance_cost_modifier_per_hex", state)
    check(absf(_mh.get_road_distance_cost_modifier() - road_mod) < 0.0001,
            "MapHelpers должен брать коэффициент дальности дороги из данных", state)
    # Формула та же, что у улучшений, но со своим коэффициентом: 1 + d × знач.
    check(absf(_mh.get_road_distance_mult(0) - 1.0) < 0.0001,
            "множитель дальности на гексе самого города должен быть 1.0", state)
    check(absf(_mh.get_road_distance_mult(5) - (1.0 + 5.0 * road_mod)) < 0.0001,
            "множитель дальности участка должен быть 1 + расстояние × коэффициент", state)

    # Цена участка на равнине в 1 гексе от города: база × 1.0 (местность)
    # × множитель дальности. Никакой надбавки за длину трассы.
    var near_price: Dictionary = _mh.get_road_step_work_cost(
            paid_level, CITY_ROW, CITY_COL + 1, CITY_ROW, CITY_COL, "plain")
    var near_expected := int(ceil(per_hex * 1.0 * _mh.get_road_distance_mult(1) \
            * float(near_price.get("construction_tech_mult", 1.0))))
    check(int(near_price.get("cost", -1)) == near_expected,
            "цена участка рядом с городом = база × множитель дальности (ожидалось %d, получено %d)"
                    % [near_expected, int(near_price.get("cost", -1))], state)
    check(int(near_price.get("base_cost", -1)) == per_hex,
            "база в расчёте должна совпадать с work_cost уровня дороги", state)

    # Тропка тоже тарифицируется по общей формуле: множители на ненулевой базе
    # дают положительную цену даже в трудной местности. Раньше здесь стоял
    # maxi(1, …) и база была 0 — из-за этого дорога к улучшению была и
    # бесплатной, и мгновенной.
    var trail_price: Dictionary = _mh.get_road_step_work_cost(
            1, CITY_ROW, CITY_COL + 1, CITY_ROW, CITY_COL, "mountain")
    check(int(trail_price.get("cost", -1)) > 0,
            "участок тропки должен стоить труда даже в горах", state)

    # ДАЛЬШЕ ОТ ГОРОДА — ДОРОЖЕ, на той же местности.
    var far_price: Dictionary = _mh.get_road_step_work_cost(
            paid_level, CITY_ROW - 6, CITY_COL, CITY_ROW, CITY_COL, "plain")
    check(int(far_price.get("cost", 0)) > int(near_price.get("cost", 0)),
            "участок дальше от города должен стоить дороже на той же местности", state)

    # ТРУДНАЯ МЕСТНОСТЬ — ДОРОЖЕ, на том же расстоянии.
    var mountain_price: Dictionary = _mh.get_road_step_work_cost(
            paid_level, CITY_ROW, CITY_COL + 1, CITY_ROW, CITY_COL, "mountain")
    check(int(mountain_price.get("cost", 0)) > int(near_price.get("cost", 0)),
            "участок в горах должен стоить дороже участка на равнине", state)
    # Множитель местности — тот же work_cost_mult, что у улучшений.
    check(absf(float(mountain_price.get("terrain_mult", 0.0)) \
            - float(_gdata.terrains.get("mountain", {}).get("work_cost_mult", -1.0))) < 0.0001,
            "множитель местности участка должен браться из work_cost_mult в данных", state)
    check(absf(_mh.get_terrain_work_mult("plain") - 1.0) < 0.0001,
            "равнина должна стоить ровно базу", state)
    # Неизвестная местность не должна ломать расчёт.
    check(_mh.get_terrain_work_mult("no_such_terrain") == 1.0,
            "неизвестная местность должна давать нейтральный множитель", state)

    # «Колесо» снижает ВКЛАД расстояния — и в улучшениях, и в дороге. Формула
    # одна на оба случая, поэтому проверяем именно равенство результатов.
    check(absf(_mh.get_distance_tech_mult() - 1.0) < 0.0001,
            "без технологий множитель вклада расстояния должен быть 1.0", state)

# -------------------------------------------------------
# 2. Планирование не меняет сеть, постройка подключает гекс
# -------------------------------------------------------

func _test_plan_and_build_hex(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)
    check(_rm.is_hex_connected(CITY_ROW, CITY_COL),
            "после initialize гекс города должен быть корнем сети дорог", state)
    check(_rm.get_all_road_segments().is_empty(),
            "после initialize сегментов дорог быть не должно", state)

    var target := {"row": CITY_ROW - 4, "col": CITY_COL}
    var plan: Dictionary = _rm.plan_road_to(target.row, target.col,
            tile_data, ROWS, COLS)
    check(plan.get("ok", false), "до гекса в 4 гекса от города дорога строится: %s"
            % plan.get("reason", ""), state)
    check(int(plan.get("segments", 0)) > 0, "в плане должно быть число новых участков", state)
    check(not bool(plan.get("is_town", true)), "обычный гекс — не городок", state)
    check(not _rm.is_hex_connected(target.row, target.col),
            "планирование не должно менять сеть дорог", state)
    check(_rm.get_all_road_segments().is_empty(),
            "планирование не должно добавлять сегменты", state)

    # Повторный план даёт тот же результат: он кэшируется по версии сети.
    var plan2: Dictionary = _rm.plan_road_to(target.row, target.col,
            tile_data, ROWS, COLS)
    check(int(plan2.get("segments", -1)) == int(plan.get("segments", -2)),
            "повторное планирование должно давать ту же длину трассы", state)

    check(_rm.build_road_to(target.row, target.col, tile_data, ROWS, COLS),
            "дорога до гекса должна построиться", state)
    check(_rm.is_hex_connected(target.row, target.col),
            "после постройки гекс должен быть подключён к сети города", state)
    var segments: Dictionary = _rm.get_all_road_segments()
    check(segments.size() == int(plan.get("segments", -1)),
            "число сегментов должно совпадать с планом: план=%d, сегментов=%d"
                    % [int(plan.get("segments", -1)), segments.size()], state)
    # Форма сети, а не только флаг: от гекса должна идти цепочка до города.
    check(_has_segment_chain(segments, target.row, target.col, CITY_ROW, CITY_COL),
            "от гекса не идёт цепочка сегментов к городу", state)
    # Ни один сегмент не проходит по воде.
    for key in segments.keys():
        var s := _parse_segment(key)
        check(not _is_water(tile_data[s[0]][s[1]]) and not _is_water(tile_data[s[2]][s[3]]),
                "сегмент дороги не должен проходить по воде: %s" % key, state)
    # Уже подключённый гекс дороги повторно не получает.
    check(not _rm.plan_road_to(target.row, target.col, tile_data, ROWS, COLS).get("ok", true),
            "к гексу с дорогой повторно строить нечего", state)
    check(_rm.get_all_road_segments().size() == segments.size(),
            "повторное планирование не должно добавлять сегменты", state)

# -------------------------------------------------------
# 3. Дорога не строится там, где её быть не может
# -------------------------------------------------------

func _test_impossible_targets(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)

    # Водный гекс: дорога по воде не строится (как и к водным улучшениям).
    tile_data[CITY_ROW - 2][CITY_COL]["terrain"] = "lake"
    var water_plan: Dictionary = _rm.plan_road_to(CITY_ROW - 2, CITY_COL,
            tile_data, ROWS, COLS)
    check(not water_plan.get("ok", true),
            "на водный гекс дорога строиться не должна", state)

    # Гекс, отрезанный водой от города: пути по суше нет.
    var island := Vector2i(5, 5)
    for n in _hu.get_neighbors_odd_r(island.y, island.x, ROWS, COLS):
        tile_data[n.row][n.col]["terrain"] = "lake"
    var island_plan: Dictionary = _rm.plan_road_to(island.x, island.y,
            tile_data, ROWS, COLS)
    check(not island_plan.get("ok", true),
            "до гекса, отрезанного водой, дороги быть не может", state)
    check(not str(island_plan.get("reason", "")).is_empty(),
            "у невозможной дороги должна быть причина в подсказке", state)

    # Улучшение с флагом no_road (ирригационный канал) дороги не получает.
    var canal := {"row": CITY_ROW - 3, "col": CITY_COL}
    tile_data[canal.row][canal.col]["improvement"] = "irrigation_canal"
    var canal_plan: Dictionary = _rm.plan_road_to(canal.row, canal.col,
            tile_data, ROWS, COLS)
    check(not canal_plan.get("ok", true),
            "к ирригационному каналу дорога не строится (no_road)", state)

# -------------------------------------------------------
# 3b. Дорога к городку идёт только по разведанной территории
# -------------------------------------------------------

func _test_town_road_needs_known_territory(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)
    _setup_town(tile_data)

    # Без ограничения по известности трасса есть — это «старые» правила.
    var open_plan: Dictionary = _rm.plan_road_to(TOWN_ROW, TOWN_COL,
            tile_data, ROWS, COLS)
    check(open_plan.get("ok", false),
            "без ограничения по известности дорога до городка строится", state)

    # Правило игры: взаимодействовать с городком можно только на разведанном
    # гексе, и подойти к нему можно только по разведанной земле. Здесь игрок
    # разведал сам городок, но пути к нему ещё нет — режем «коридор» полосой
    # неразведанных гексов между городом и городком.
    _set_corridor_known(tile_data, false)
    var filtered: Dictionary = _rm.plan_road_to(TOWN_ROW, TOWN_COL,
            tile_data, ROWS, COLS, _known_hex_filter(tile_data))
    check(not filtered.get("ok", true),
            "через неразведанную территорию дорога к городку строиться не должна", state)
    # Причина — ПЕРЕВОДИМАЯ строка интерфейса, поэтому сверяем её с тем же
    # tr(), которым она построена в road_manager. Язык на момент этой
    # проверки может быть любым: LocalizationManager применяет его на первом
    # кадре, а этот блок _run() выполняется до первого await. Проверяем
    # ВЕТКУ (зовёт разведчиков), а не наличие русского слова в тексте.
    var scouting_reason := "No scouted route from the city to the town — send scouts there"
    check(str(filtered.get("reason", "")) == _rm.tr(scouting_reason),
            "причина должна звать разведчиков, а не говорить «пути нет вообще»: %s"
                    % filtered.get("reason", ""), state)

    # Как только игрок разведал проход — дорога появляется. Кэш плана при этом
    # обязан сбрасываться (bump_map_knowledge), иначе остался бы старый ответ.
    _set_corridor_known(tile_data, true)
    _rm.bump_map_knowledge()
    var after_scouting: Dictionary = _rm.plan_road_to(TOWN_ROW, TOWN_COL,
            tile_data, ROWS, COLS, _known_hex_filter(tile_data))
    check(after_scouting.get("ok", false),
            "после разведки прохода дорога к городку должна появиться: %s"
                    % after_scouting.get("reason", ""), state)
    check(_rm.build_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS, -1,
            _known_hex_filter(tile_data)),
            "дорога по разведанному пути строится", state)
    check(_rm.is_town_linked_to_city(TOWN_ROW, TOWN_COL),
            "городок соединён с городом", state)

# Полоса гексов строго между городом и городком: known=true делает её
# разведанной, false — неразведанной (коридор, которого ещё нет).
func _set_corridor_known(tile_data: Array, known: bool) -> void:
    for row in range(mini(TOWN_ROW, CITY_ROW) + 1, maxi(TOWN_ROW, CITY_ROW)):
        for col in range(COLS):
            tile_data[row][col]["in_influence"] = false
            tile_data[row][col]["is_explored"] = known

# Предикат «известен ли гекс игроку» — та же логика, что у main_map.is_hex_known.
func _known_hex_filter(tile_data: Array) -> Callable:
    return func(row: int, col: int) -> bool:
        var tile = tile_data[row][col]
        if tile == null:
            return false
        return bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false))

# -------------------------------------------------------
# 3c. Данные для «призрачной» дороги: новые сегменты плана
# -------------------------------------------------------

# Превью на карте рисует НОВЫЕ сегменты плана (road_manager
# .get_plan_new_segments). Проверяем ровно то, за что платит игрок: столько же
# сегментов, сколько в плане, каждый — между соседними гексами, ни один ещё не
# построен, а маршрут упирается в уже готовую сеть города.
func _test_ghost_segments(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)
    var target := {"row": CITY_ROW - 4, "col": CITY_COL}
    var plan: Dictionary = _rm.plan_road_to(target.row, target.col,
            tile_data, ROWS, COLS)
    check(plan.get("ok", false), "для проверки превью нужна успешная трасса: %s"
            % plan.get("reason", ""), state)

    var ghost: Dictionary = _rm.get_plan_new_segments(plan)
    check(not ghost.is_empty(), "у плана должны быть новые сегменты для превью", state)
    check(ghost.size() == int(plan.get("segments", -1)),
            "призрачная дорога показывает столько же сегментов, сколько их в плане: %d и %d"
                    % [ghost.size(), int(plan.get("segments", -1))], state)
    var built: Dictionary = _rm.get_all_road_segments()
    for key in ghost.keys():
        check(not built.has(key),
                "в превью не должно быть уже построенного сегмента: %s" % key, state)
        var s := _parse_segment(key)
        check(_hu.hex_distance(s[0], s[1], s[2], s[3]) == 1,
                "сегмент превью должен соединять соседние гексы: %s" % key, state)
    check(_ghost_reaches_network(ghost, _rm, target.row, target.col),
            "маршрут превью должен доходить до уже построенной сети города", state)
    # Превью ничего не строит — это чистая выборка из кэшированного плана.
    check(_rm.get_all_road_segments().is_empty(),
            "получение сегментов превью не должно строить дорогу", state)

    _rm.build_road_to(target.row, target.col, tile_data, ROWS, COLS)
    var after: Dictionary = _rm.plan_road_to(target.row, target.col, tile_data, ROWS, COLS)
    check(_rm.get_plan_new_segments(after).is_empty(),
            "после постройки показывать нечего: новых сегментов нет", state)

# Доходит ли маршрут превью до уже построенной сети города: идём по сегментам
# превью от целевого гекса и ждём гекс, который сеть уже покрывает. Проверять
# цепочку до самого гекса города нельзя — последний участок к нему УЖЕ
# построен, и в превью его нет (это и есть разница превью и постройки).
func _ghost_reaches_network(ghost: Dictionary, rm, start_row: int, start_col: int) -> bool:
    if ghost.is_empty():
        return false
    var seen := {"%d,%d" % [start_row, start_col]: true}
    var queue: Array = [{"row": start_row, "col": start_col}]
    while not queue.is_empty():
        var cur: Dictionary = queue.pop_front()
        if (cur.row != start_row or cur.col != start_col) \
                and rm.is_hex_connected(int(cur.row), int(cur.col)):
            return true
        for key in ghost.keys():
            var s := _parse_segment(key)
            var other = null
            if s[0] == cur.row and s[1] == cur.col:
                other = {"row": s[2], "col": s[3]}
            elif s[2] == cur.row and s[3] == cur.col:
                other = {"row": s[0], "col": s[1]}
            if other == null:
                continue
            var k := "%d,%d" % [int(other.row), int(other.col)]
            if not seen.has(k):
                seen[k] = true
                queue.append(other)
    return false

# Все ли гексы маршрута превью известны игроку (в Кольце Влияния или разведаны).
func _ghost_is_known(main_map, ghost: Dictionary) -> bool:
    for key in ghost.keys():
        var s := _parse_segment(key)
        if not main_map.is_hex_known(s[0], s[1]) or not main_map.is_hex_known(s[2], s[3]):
            return false
    return true

# -------------------------------------------------------
# 4. Дорога до городка: до ближайшей дороги в кольце влияния
# -------------------------------------------------------

# Ставит городка с ОДНИМ улучшением в кольце влияния и строит его сеть дорог.
func _setup_town(tile_data: Array) -> Dictionary:
    var town := _make_town()
    for h in town["influence_hexes"]:
        tile_data[h.row][h.col]["in_town_influence"] = true
    tile_data[TOWN_ROW][TOWN_COL]["has_town"] = true
    # Улучшение на расстоянии 3 от центра — в кольце: у городка появляется
    # своя дорожная сеть, к которой и потянется дорога города.
    # decorative = true — обязательно: по этому флагу rebuild_roads_from_existing
    # отличает улучшения ГОРОДКА (их дороги строит сам городок) от улучшений
    # игрока (их дороги тянутся к городу).
    tile_data[TOWN_ROW][TOWN_COL + 3]["improvement"] = "farm"
    tile_data[TOWN_ROW][TOWN_COL + 3]["decorative"] = true
    _rm.rebuild_town_roads([town], tile_data, ROWS, COLS)
    return town

func _test_town_link(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)
    var town := _setup_town(tile_data)
    _tm.towns = [town]

    check(_rm.is_town_connected(TOWN_ROW, TOWN_COL, TOWN_ROW, TOWN_COL + 3),
            "у городка должна быть своя дорожная сеть (центр — улучшение)", state)
    check(not _rm.is_town_linked_to_city(TOWN_ROW, TOWN_COL),
            "изначально городок с городом не соединён", state)

    var plan: Dictionary = _rm.plan_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS)
    check(plan.get("ok", false), "до городка должна достраиваться дорога: %s"
            % plan.get("reason", ""), state)
    check(bool(plan.get("is_town", false)), "план дороги до городка помечен как городковый", state)
    check(int(plan.get("segments", 0)) > 0, "у дороги до городка есть новые участки", state)

    # Ключевое правило: трасса идёт ДО САМОГО ГОРОДКА (в его центр), а не
    # обрывается на ближайшей дороге кольца влияния, и заканчивается на дороге
    # сети ГОРОДА. Иначе выбранный уровень не дошёл бы до городка, и шоссе
    # превращалось бы в тропку на границе кольца.
    var road_path: Array = plan.get("path", [])
    check(road_path.size() >= 2, "в плане должен быть путь хотя бы из двух гексов", state)
    if road_path.size() >= 2:
        var town_side: Dictionary = road_path[0]
        var city_side: Dictionary = road_path[road_path.size() - 1]
        check(town_side.row == TOWN_ROW and town_side.col == TOWN_COL,
                "трасса должна начинаться в ЦЕНТРЕ городка (%d,%d), получено (%d,%d)"
                        % [TOWN_ROW, TOWN_COL, town_side.row, town_side.col], state)
        check(_rm.is_hex_connected(city_side.row, city_side.col),
                "трасса должна заканчиваться на дороге сети города (%d,%d)"
                        % [city_side.row, city_side.col], state)

    var linked := {"hit": false}
    _rm.town_link_established.connect(func(_r, _c):
        linked["hit"] = int(_r) == TOWN_ROW and int(_c) == TOWN_COL)
    check(_rm.build_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS),
            "дорога до городка должна построиться", state)
    check(bool(linked.get("hit", false)),
            "после постройки связи должен прийти сигнал town_link_established", state)
    check(_rm.is_town_linked_to_city(TOWN_ROW, TOWN_COL),
            "после постройки городок должен быть соединён с городом", state)

    # Сегменты связи помечены отдельно: по ним рисуется город с гейтами
    # тумана (дорога к городку может идти через неисследованные гексы).
    var link_segments: Dictionary = _rm.get_all_town_link_segments()
    check(not link_segments.is_empty(), "сегменты связи с городком должны быть помечены", state)
    for key in link_segments.keys():
        check(_rm.get_all_road_segments().has(key),
                "сегмент связи должен быть и в сети города: %s" % key, state)
        var s := _parse_segment(key)
        check(not _is_water(tile_data[s[0]][s[1]]) and not _is_water(tile_data[s[2]][s[3]]),
                "сегмент связи не должен проходить по воде: %s" % key, state)

    # Соединённый городок второй раз дороги не получает.
    check(not _rm.plan_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS).get("ok", true),
            "к соединённому городку дорогу повторно строить не нужно", state)

    # --- Гейт торговли: одна функция, общая для UI и будущей механики ---
    check(not _tm.is_trade_available(town),
            "без дороги торговля с городком недоступна", state)
    town["road_linked"] = true
    check(_tm.is_trade_available(town),
            "с дорогой торговля с городком доступна", state)

# -------------------------------------------------------
# 4b. Дорога до городка доходит на ВЫБРАННОМ уровне до самого городка
# -------------------------------------------------------

# Требование: выбранный в превью уровень обязан дойти до городка, а не
# обрываться на ближайшей дороге кольца влияния, где шоссе упиралось бы в
# собственную тропку городка. Проверяем на синтетике: строим дорогу до городка
# уровнем выше тропки и убеждаемся, что КАЖДЫЙ участок трассы (включая тот,
# что входит в кольцо и ведёт к центру) — этого уровня, а на гексе городка
# уровень дороги равен выбранному. До правки последний участок был бы тропкой
# городка (уровень 1).
func _test_town_road_level(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)
    _setup_town(tile_data)

    var level := _highest_road_level()
    check(level > 1,
            "в roads.json должен быть уровень выше тропки, иначе проверять нечего", state)
    if level <= 1:
        return

    var plan: Dictionary = _rm.plan_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS)
    check(plan.get("ok", false), "для проверки уровня нужна успешная трасса: %s"
            % plan.get("reason", ""), state)
    if not plan.get("ok", false):
        return

    check(_rm.build_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS, -1,
            Callable(), level),
            "дорога до городка должна построиться на выбранном уровне", state)

    var road_path: Array = plan.get("path", [])
    for i in range(road_path.size() - 1):
        var a: Dictionary = road_path[i]
        var b: Dictionary = road_path[i + 1]
        check(_rm.get_segment_level(a.row, a.col, b.row, b.col) == level,
                "участок (%d,%d)-(%d,%d) дороги до городка должен быть уровня %d"
                        % [a.row, a.col, b.row, b.col, level], state)

    # Уровень дороги на гексе — максимум по примыкающим участкам обеих сетей:
    # на гексе городка рядом и участок игрока (выбранного уровня), и участок
    # сети городка (тропка). Максимум обязан быть выбранным уровнем — иначе
    # шоссе визуально и по маршруту превращалось бы в тропку у самого городка.
    var hex_level: int = _rm.get_hex_road_level(TOWN_ROW, TOWN_COL)
    check(hex_level == level,
            "у гекса городка уровень дороги должен быть %d (выбранный), получено %d"
                    % [level, hex_level], state)

# Наибольший уровень дороги в данных. Нужен там, где проверке нужен уровень,
# ОТЛИЧНЫЙ от уровня дорог городка (тропка, 1): разблокировка по технологиям в
# headless-прогоне не гарантирована, а планирование и постройка уровень не
# проверяют.
func _highest_road_level() -> int:
    var level := 0
    for l in _gdata.get_road_levels():
        level = maxi(level, int(l))
    return level

# -------------------------------------------------------
# 5. Восстановление дорог по флагам сейва
# -------------------------------------------------------

func _test_restore_from_save_flags(state: Dictionary) -> void:
    var tile_data := _make_map()
    _rm.initialize(CITY_ROW, CITY_COL)
    var town := _setup_town(tile_data)
    _tm.towns = [town]

    # Строим дорогу до обычного гекса и до городка и ставим флаги — ровно то,
    # что делает main_map._mark_road_built.
    var plain := {"row": CITY_ROW - 4, "col": CITY_COL}
    _rm.build_road_to(plain.row, plain.col, tile_data, ROWS, COLS)
    tile_data[plain.row][plain.col]["road_built"] = true
    _rm.build_road_to(TOWN_ROW, TOWN_COL, tile_data, ROWS, COLS)
    tile_data[TOWN_ROW][TOWN_COL]["road_built"] = true
    town["road_linked"] = true
    check(_rm.is_town_linked_to_city(TOWN_ROW, TOWN_COL), "подготовка: городок соединён", state)

    # Запись городка сериализует флаг связи, и загрузка его читает — в том
    # числе старый сейв, где такого поля нет.
    var serialized: Array = _tm.serialize_towns()
    check(serialized.size() == 1 and bool(serialized[0].get("road_linked", false)),
            "флаг road_linked должен попадать в сейв городков", state)
    _tm.towns.clear()
    _tm.load_towns(serialized)
    check(_tm.towns.size() == 1 and bool(_tm.towns[0].get("road_linked", false)),
            "флаг road_linked должен восстанавливаться из сейва", state)
    _tm.load_towns([{"row": TOWN_ROW, "col": TOWN_COL, "name": "Старый"}])
    check(not bool(_tm.towns[0].get("road_linked", true)),
            "у старого сейва без флага связи должно быть false", state)

    # Пересчёт сетей с нуля — ровно как при загрузке партии.
    _rm.initialize(CITY_ROW, CITY_COL)
    check(_rm.get_all_road_segments().is_empty(),
            "после пересчёта сеть дорог начинается пустой", state)
    _rm.rebuild_roads_from_existing(tile_data, ROWS, COLS)
    _rm.rebuild_town_roads([town], tile_data, ROWS, COLS)
    check(not _rm.is_town_linked_to_city(TOWN_ROW, TOWN_COL),
            "дороги, построенные игроком, не восстанавливаются сами по улучшениям", state)
    _rm.rebuild_player_roads(tile_data, ROWS, COLS)
    check(_rm.is_hex_connected(plain.row, plain.col),
            "дорога до обычного гекса должна восстановиться по флагу road_built", state)
    check(_rm.is_town_linked_to_city(TOWN_ROW, TOWN_COL),
            "дорога до городка должна восстановиться по флагам", state)
    check(not _rm.get_all_town_link_segments().is_empty(),
            "сегменты связи должны восстановиться вместе с дорогой", state)

# -------------------------------------------------------
# 6. Живая сцена: кнопка, полный цикл стройки, окно городка, сейв
# -------------------------------------------------------

func _test_live_scene(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var rm = main_map.road_manager
    var panel = main_map.control_panel
    var bm = main_map.build_manager

    # Исследуем технологии всех уровней дороги (сейчас это «Колесо»).
    # Проверяемая ниже постройка — ПОЭТАПНАЯ, а поэтапность имеет смысл
    # только у платного уровня: тропка (work_cost = 0) строится сразу и в
    # очередь проекта не встаёт. Без технологии лучший доступный уровень —
    # тропка, и весь сценарий ниже проверял бы мгновенную постройку вместо
    # очереди участков.
    for level in _gdata.get_road_levels():
        var raw = _gdata.get_road_by_level(int(level)).get("unlock_tech", null)
        # Поле бывает null (у тропки технологии нет), а `null or ""` в
        # GDScript НЕ даёт пустую строку — без этой проверки в список
        # технологий попала бы строка "<null>" и цикл сломался бы.
        if not (raw is String) or str(raw).is_empty():
            continue
        if not _cdata.is_tech_unlocked(str(raw)):
            _cdata.unlocked_technologies.append(str(raw))
    var default_level: int = _gdata.get_max_unlocked_road_level()
    check(_gdata.get_road_work_cost(default_level) > 0,
            "после исследования технологии лучший уровень дороги должен быть платным",
            state)

    # --- Базовая тропка: платная и поэтапная, как любая дорога ---
# Раньше уровень 1 был бесплатным, и тогда у него не могло быть «шага,
# который копит труд»: такой шаг не накопил бы труд и держал бы слот вечно.
# Теперь база есть и у тропки, поэтому она идёт обычной очередью проекта.
    var trail_target := _find_hex_without_road(main_map)
    if not trail_target.is_empty():
        var t_row2 := int(trail_target.row)
        var t_col2 := int(trail_target.col)
        var trail_breakdown: Dictionary = main_map.get_road_cost_breakdown(
                t_row2, t_col2, 1)
        if trail_breakdown.get("ok", false):
            check(int(trail_breakdown.get("cost", 0)) > 0,
                    "трасса тропки должна что-то стоить", state)
            check(bm.start_build(t_row2, t_col2, ROAD_ACTION_ID, null, 1),
                    "тропку должно быть можно построить", state)
            check(not main_map.project_manager.get_project_at(t_row2, t_col2).is_empty(),
                    "тропка должна встать в очередь проекта, а не строиться мгновенно",
                    state)
            check(not rm.is_hex_connected(t_row2, t_col2),
                    "до постройки гекс не должен быть подключён к сети", state)
            main_map.project_manager.cancel_project_at(t_row2, t_col2)

    # --- Кнопка «Построить дорогу» на гексе, где дороги ещё нет ---
    var target := _find_hex_without_road(main_map)
    check(not target.is_empty(), "на живой карте должен найтись гекс без дороги", state)
    if not target.is_empty():
        var row := int(target.row)
        var col := int(target.col)
        var actions: Array = panel._collect_actions(row, col, main_map.tile_data[row][col])
        check(_has_action(actions, "special", ROAD_ACTION_ID),
                "на гексе без дороги должна быть кнопка «Построить дорогу»", state)

        # Цена превью и цена реальной стройки — один и тот же расчёт, из
        # ЕДИНОГО источника шагов. Главное здесь — инвариант: сумма цен шагов
        # равна показанной цене. Раньше это держалось на «последний шаг добирает
        # остаток», а теперь выполняется по построению.
        var plan: Dictionary = main_map.get_road_plan(row, col)
        check(plan.get("ok", false), "до гекса без дороги должна быть трасса: %s"
                % plan.get("reason", ""), state)
        # Разбор цены считаем для ПЛАТНОГО уровня: у тропки все шаги стоят 0,
        # и инвариант «сумма шагов = цена» проверялся бы на нулях, не замечая
        # ошибки округления. Платный уровень выбираем явно, а не «по умолчанию»:
        # в живой партии «Колесо» может быть и не изучено, и тогда лучший
        # доступный уровень — бесплатная тропка.
        var paid_level := _first_paid_road_level(state)
        var breakdown: Dictionary = main_map.get_road_cost_breakdown(row, col, paid_level)
        check(breakdown.get("ok", false), "разбор цены дороги должен быть доступен", state)
        var steps: Array = breakdown.get("steps", [])
        check(steps.size() > 0, "у дороги должен быть хотя бы один шаг", state)
        var sum_steps := 0
        for step in steps:
            sum_steps += int(step.get("work_cost", 0))
        check(sum_steps == int(breakdown.get("cost", -1)),
                "цена дороги должна быть ТОЧНОЙ суммой цен её шагов (сумма %d, цена %d)"
                        % [sum_steps, int(breakdown.get("cost", -1))], state)
        # Шагов ровно столько, сколько новых участков на карте: уже
        # построенные сегменты в очередь не попадают и не тарифицируются.
        check(steps.size() == main_map.road_manager.get_plan_new_segments(plan).size(),
                "шагов должно быть ровно столько же, сколько новых участков на карте",
                state)
        # Каждый шаг стоит не меньше базы и учитывает свою дальность.
        for step in steps:
            var w: int = int(step.get("work_cost", 0))
            var price: Dictionary = step.get("price", {})
            check(w >= int(price.get("base_cost", 0)) and w > 0,
                    "цена шага не может быть нулевой или меньше базы", state)

        # То же самое через get_improvement_work_cost — им пользуется
        # build_manager для проверки «цена > 0».
        var cost: Dictionary = main_map.get_improvement_work_cost(ROAD_ACTION_ID, row, col, paid_level)
        check(int(cost.get("cost", -1)) == int(breakdown.get("cost", -2)) \
                and int(cost.get("cost", 0)) > 0,
                "build_manager должен видеть ту же цену, что и превью", state)

        # Превью в колонке предпросмотра: цена дороги и длина трассы.
        panel.select_hex(row, col)
        panel._preview_action = {"type": "special", "action_id": ROAD_ACTION_ID,
                "imp_id": "", "target_res_id": null, "label": "Построить дорогу",
                "eff_res": "", "selected_culture_id": null,
                "road_level": paid_level}
        panel._refresh()
        var preview_text := _collect_text(panel._preview_container)
        check(preview_text.contains("Стоимость: %d труда" % int(breakdown.get("cost", 0))),
                "в превью должна показываться итоговая стоимость дороги", state)
        check(preview_text.contains("За участок"),
                "в превью должна показываться цена за участок", state)
        check(preview_text.contains("Расстояние до города"),
                "в превью должно показываться, как дальность влияет на цену", state)
        check(preview_text.contains("Местность на трассе"),
                "в превью должно показываться, как местность влияет на цену", state)
        check(preview_text.contains("Новых участков трассы: %d" % steps.size()),
                "в превью должно показываться число новых участков трассы", state)

        # «Призрачная» дорога: пока превью открыто, маршрут нарисован на карте,
        # и уже построенных сегментов в нём нет (рисовать их незачем).
        var ghost: Dictionary = main_map.map_renderer._road_preview_segments
        check(not ghost.is_empty() and ghost.size() == int(plan.get("segments", -1)),
                "превью должно рисовать маршрут из стольких же сегментов, сколько в плане: %d и %d"
                        % [ghost.size(), int(plan.get("segments", -1))], state)
        var built_now: Dictionary = rm.get_all_road_segments()
        for key in ghost.keys():
            check(not built_now.has(key),
                    "в маршруте превью не должно быть уже построенных сегментов: %s" % key, state)
        panel.clear_preview()
        check(main_map.map_renderer._road_preview_segments.is_empty(),
                "после закрытия превью маршрут должен исчезнуть с карты", state)

        # Полный цикл: кнопка -> ПОЭТАПНЫЙ проект -> сегменты дороги на карте.
        # Дорога больше не обычная стройка на этом гексе, а очередь участков,
        # поэтому идёт проект, а не запись в active_builds.
        check(bm.start_build(row, col, ROAD_ACTION_ID, null, paid_level),
                "стройку дороги должно быть можно запустить", state)
        var project = main_map.project_manager.get_project_at(row, col)
        check(not project.is_empty(),
                "после запуска на гексе должен идти поэтапный проект дороги", state)
        var step_count: int = project.get("steps", []).size()
        check(step_count > 0, "в проекте должен быть хотя бы один участок", state)
        check(not bm.is_building(row, col),
                "участки дороги не должны быть обычной стройкой на гексе", state)

        # Призрак проекта живёт на карте до конца стройки и равен числу
        # непостроенных участков.
        var ghost_during: Dictionary = main_map.map_renderer._project_ghost_segments
        check(ghost_during.size() == step_count,
                "призрак проекта должен показывать все непостроенные участки: %d и %d"
                        % [ghost_during.size(), step_count], state)
        check(not rm.is_hex_connected(row, col),
                "до завершения проекта дороги до цели ещё нет", state)

        # Кнопка «Построить дорогу» на гексе стройки не показывается — вместо
        # неё предлагается отмена проекта.
        var during_actions: Array = panel._collect_actions(row, col, main_map.tile_data[row][col])
        check(not _has_action(during_actions, "special", ROAD_ACTION_ID),
                "на гексе идущей стройки кнопка «Построить дорогу» не показывается", state)
        check(_has_action(during_actions, "cancel_project", ""),
                "на гексе идущей стройки должна быть кнопка отмены проекта", state)

        await _finish_build(state)
        check(main_map.project_manager.get_project_at(row, col).is_empty(),
                "после завершения проекта он должен исчезнуть из очереди", state)
        check(rm.is_hex_connected(row, col),
                "после завершения стройки гекс должен получить дорогу", state)
        check(main_map.map_renderer._project_ghost_segments.is_empty(),
                "после завершения проекта призрак маршрута должен исчезнуть", state)
        check(bool(main_map.tile_data[row][col].get("road_built", false)),
                "на гексе должен стоять флаг road_built (входные данные для сейва)", state)
        check(not _has_action(panel._collect_actions(row, col, main_map.tile_data[row][col]),
                "special", ROAD_ACTION_ID),
                "к гексу с дорогой кнопка «Построить дорогу» повторно не показывается", state)

    # --- Дорога до городка полным циклом, торговля и её гейт ---
    var town = _find_unlinked_town(main_map)
    check(town != null, "на живой карте должен быть ещё не соединённый городок", state)
    if town != null:
        var t_row := int(town.get("row", -1))
        var t_col := int(town.get("col", -1))
        # Разведка открыла САМ городок, но не путь к нему: коридора ещё нет.
        main_map.tile_data[t_row][t_col]["is_explored"] = true
        main_map.road_manager.bump_map_knowledge()
        var tile = main_map.tile_data[t_row][t_col]

        # Окно городка открывается БЕЗ дороги: доступ свободен, гейтится
        # только торговля.
        check(not main_map.town_manager.is_trade_available(town),
                "городок без дороги: торговля недоступна", state)
        main_map.open_town_ui(t_row, t_col)
        check(main_map.town_ui.visible, "разведанный городок открывается и без дороги", state)
        check(not main_map.town_ui.status_label.text.is_empty(),
                "в окне без дороги должна быть подпись о недоступной торговле", state)
        main_map.town_ui.close_town()

        var town_actions: Array = panel._collect_actions(t_row, t_col, tile)
        check(_has_action(town_actions, "special", ROAD_ACTION_ID),
                "на гексе городка должна быть кнопка «Построить дорогу»", state)
        var open_action := _find_action(town_actions, "open_town")
        check(not open_action.is_empty() and bool(open_action.get("enabled", false)),
                "кнопка «Открыть городок» активна и без дороги", state)

        await _test_town_road_cycle(main_map, bm, panel, town, state)

    # --- Флаг дороги попадает в сейв ---
    var save_manager = get_root().get_node("SaveManager")
    var serialized_tiles: Array = save_manager._serialize_tile_data(main_map)
    var saved_roads := 0
    for r in range(serialized_tiles.size()):
        for c in range(serialized_tiles[r].size()):
            if not serialized_tiles[r][c].is_empty() \
                    and bool(serialized_tiles[r][c].get("road_built", false)):
                saved_roads += 1
    check(saved_roads > 0, "флаги построенных дорог должны попадать в сейв гексов", state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()

# -------------------------------------------------------
# 6b. Сценарий дороги до городка на живой сцене
# -------------------------------------------------------

# Полный цикл: сначала дороги НЕТ (городок разведан, а пути к нему нет), затем
# разведка открывает коридор, затем дорога строится и связывает городки.
# Отдельная функция, потому что сценарий асинхронный (await) и должен уметь
# выйти досрочно: городок, вообще не связанный с городом сушей (остров), — не
# баг механики, и такой случай честнее пропустить, чем подгонять карту.
func _test_town_road_cycle(main_map, bm, panel, town, state: Dictionary) -> void:
    var rm = main_map.road_manager
    var t_row := int(town.get("row", -1))
    var t_col := int(town.get("col", -1))
    var tile = main_map.tile_data[t_row][t_col]

    # Проверка «есть ли вообще сухопутный путь» — план БЕЗ ограничения по
    # известности (его не делает сам игровой код, но для выбора сценария он
    # годится: никаких побочных эффектов у plan_road_to нет).
    var open_plan: Dictionary = rm.plan_road_to(t_row, t_col, main_map.tile_data,
            main_map.map_rows, main_map.map_cols)
    if not open_plan.get("ok", false):
        print("ПРОПУЩЕНО: выбранный городок не связан с городом сушей")
        return

    # Пока к городку нет разведанного пути, дороги не будет: известен только
    # сам городок, а идти к нему не через что. Это главное правило — раньше
    # трасса шла напрямую через неисследованную землю.
    var no_route: Dictionary = main_map.get_road_plan(t_row, t_col)
    check(not no_route.get("ok", true),
            "без разведанного пути дорога до городка строиться не должна", state)
    check(str(no_route.get("reason", "")).contains("разведан"),
            "причина должна звать разведчиков: %s" % no_route.get("reason", ""), state)
    check(not bm.start_build(t_row, t_col, ROAD_ACTION_ID),
            "стройка дороги без разведанного пути должна быть отклонена", state)

    # Разведчик доходит по суше от городка до города — открыт коридор.
    var opened := _explore_corridor(main_map, t_row, t_col)
    check(opened > 0, "разведка должна открыть коридор к городку", state)
    var town_plan: Dictionary = main_map.get_road_plan(t_row, t_col)
    check(town_plan.get("ok", false), "после разведки пути дорога доступна: %s"
            % town_plan.get("reason", ""), state)
    check(_path_is_known(main_map, town_plan.get("path", [])),
            "ни один гекс трассы не должен быть неразведанным", state)

    # Превью дороги к городку рисует весь маршрут — и весь он по разведанной
    # земле (об этом предупреждает подпись в панели: высокая цена не из-за сбоя,
    # а из-за крюка по разведанной территории).
    panel.select_hex(t_row, t_col)
    panel._preview_action = {"type": "special", "action_id": ROAD_ACTION_ID,
            "imp_id": "", "target_res_id": null, "label": "Построить дорогу",
            "eff_res": "", "selected_culture_id": null}
    panel._refresh()
    var ghost: Dictionary = main_map.map_renderer._road_preview_segments
    check(not ghost.is_empty(), "превью дороги к городку должно рисовать маршрут", state)
    check(_ghost_is_known(main_map, ghost),
            "в маршруте к городку не должно быть неразведанных гексов", state)
    panel.clear_preview()
    check(main_map.map_renderer._road_preview_segments.is_empty(),
            "после закрытия превью маршрут к городку должен исчезнуть", state)

    # Стройка дороги на гексе городка разрешена: запреты «здесь городок» и
    # «здесь кольцо влияния» её не касаются (см. build_manager.start_build).
    check(bm.start_build(t_row, t_col, ROAD_ACTION_ID),
            "дорогу до городка должно быть можно построить", state)
    await _finish_build(state)
    check(rm.is_town_linked_to_city(t_row, t_col),
            "после стройки городок должен быть соединён с городом", state)
    check(bool(town.get("road_linked", false)),
            "в записи городка должен стоять флаг road_linked", state)
    check(main_map.town_manager.is_trade_available(town),
            "с дорогой торговля с городком доступна", state)
    check(not _has_action(panel._collect_actions(t_row, t_col, tile),
            "special", ROAD_ACTION_ID),
            "к соединённому городку кнопка дороги больше не показывается", state)
    main_map.open_town_ui(t_row, t_col)
    check(main_map.town_ui.visible, "окно городка открывается и с дорогой", state)
    check(main_map.town_ui.status_label.text.is_empty(),
            "с дорогой подпись о недоступной торговле исчезает", state)
    main_map.town_ui.close_town()

    # Значок торговли рисуется только у соединённого и раскрытого городка.
    check(main_map.map_renderer._is_town_trade_connected(t_row, t_col),
            "рендерер должен считать городок соединённым", state)
    # Сегменты связи рисуются с теми же гейтами, что и дороги городков:
    # сначала эры, потом тумана.
    var link_segments: Dictionary = rm.get_all_town_link_segments()
    check(not link_segments.is_empty(), "у построенной связи должны быть сегменты", state)
    check(not main_map.map_renderer.are_town_roads_visible(),
            "в 1-й эпохе дороги к городкам не рисуются", state)
    for key in link_segments.keys():
        check(not main_map.map_renderer.is_town_road_segment_visible(
                _parse_segment(key)[0], _parse_segment(key)[1],
                _parse_segment(key)[2], _parse_segment(key)[3]),
                "в 1-й эпохе сегмент связи не должен рисоваться: %s" % key, state)
    # С эры Античности связь видна, но по-прежнему не выдаёт туман.
    main_map.advance_to_next_era()
    await process_frame
    for key in link_segments.keys():
        var s := _parse_segment(key)
        var visible_by_rule: bool = not main_map.is_hex_in_fog(s[0], s[1]) \
                and not main_map.is_hex_in_fog(s[2], s[3])
        check(main_map.map_renderer.is_town_road_segment_visible(s[0], s[1], s[2], s[3])
                == visible_by_rule,
                "видимость сегмента связи не совпала с правилом тумана: %s" % key, state)

# -------------------------------------------------------
# Хелперы
# -------------------------------------------------------

# Дожидается завершения всех активных строек: в тесте труд копится в игровом
# времени, поэтому используется дебаг-режим «Игнорировать требования
# строительства» — он доводит стройки до 100% за кадр.
func _finish_build(state: Dictionary) -> void:
    var previous: bool = _cdata.ignore_build_requirements
    _cdata.ignore_build_requirements = true
    for _i in range(6):
        await process_frame
    _cdata.ignore_build_requirements = previous

# "r1,c1|r2,c2" -> [r1, c1, r2, c2]
func _parse_segment(key: String) -> Array:
    var parts := key.split("|")
    if parts.size() != 2:
        return [-1, -1, -1, -1]
    var a := parts[0].split(",")
    var b := parts[1].split(",")
    if a.size() != 2 or b.size() != 2:
        return [-1, -1, -1, -1]
    return [int(a[0]), int(a[1]), int(b[0]), int(b[1])]

# Все сегменты, у которых хоть один конец — указанный гекс.
func _segments_touching(segments: Dictionary, row: int, col: int) -> Array:
    var result: Array = []
    for key in segments.keys():
        var s := _parse_segment(key)
        if (s[0] == row and s[1] == col) or (s[2] == row and s[3] == col):
            result.append(s)
    return result

# Есть ли в наборе сегментов цепочка от одного гекса до другого (BFS в обе
# стороны: дорога двусторонняя). Проверяет ФОРМУ сети, а не только флаги.
func _has_segment_chain(segments: Dictionary, from_row: int, from_col: int,
        to_row: int, to_col: int) -> bool:
    var visited := {"%d,%d" % [from_row, from_col]: true}
    var queue: Array = [{"row": from_row, "col": from_col}]
    while not queue.is_empty():
        var cur: Dictionary = queue.pop_front()
        if int(cur.row) == to_row and int(cur.col) == to_col:
            return true
        for seg in _segments_touching(segments, int(cur.row), int(cur.col)):
            var other := [seg[2], seg[3]] if (seg[0] == int(cur.row) and seg[1] == int(cur.col)) \
                    else [seg[0], seg[1]]
            var key := "%d,%d" % [int(other[0]), int(other[1])]
            if visited.has(key):
                continue
            visited[key] = true
            queue.append({"row": int(other[0]), "col": int(other[1])})
    return false

func _is_water(tile: Dictionary) -> bool:
    return _mh.is_water_terrain(str(tile.get("terrain", "plain")))

# Весь текст из контейнера превью — одной строкой (для проверок содержимого).
func _collect_text(node: Node) -> String:
    var text := ""
    for child in node.get_children():
        if child is Label:
            text += str((child as Label).text) + "\n"
        text += _collect_text(child)
    return text

# Есть ли в списке действий панели действие типа type с id action_id.
func _has_action(actions: Array, type: String, action_id: String) -> bool:
    return not _find_action(actions, type, action_id).is_empty()

func _find_action(actions: Array, type: String, action_id: String = "") -> Dictionary:
    for a in actions:
        if not a is Dictionary:
            continue
        if str(a.get("type", "")) != type:
            continue
        if action_id == "" or str(a.get("action_id", "")) == action_id:
            return a
    return {}

# Гекс Кольца Влияния, к которому дороги ещё нет (суша, без улучшения).
func _find_hex_without_road(main_map) -> Dictionary:
    var rm = main_map.road_manager
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = main_map.get_tile_data(row, col)
            if tile == null or not bool(tile.get("in_influence", false)):
                continue
            if bool(tile.get("has_town", false)) or bool(tile.get("in_town_influence", false)):
                continue
            if bool(tile.get("decorative", false)) or tile.get("improvement", null) != null:
                continue
            if _is_water(tile) or rm.is_hex_connected(row, col):
                continue
            if not rm.plan_road_to(row, col, main_map.tile_data,
                    main_map.map_rows, main_map.map_cols).get("ok", false):
                continue
            return {"row": row, "col": col}
    return {}

# Первый городок, ещё не соединённый с городом дорогами.
func _find_unlinked_town(main_map):
    var rm = main_map.road_manager
    for town in main_map.town_manager.towns:
        if not rm.is_town_linked_to_city(int(town.get("row", -1)), int(town.get("col", -1))):
            return town
    return null

# Имитирует разведку пути от городка к городу: игрок открывает гексы по
# сухопутному пути, пока не встретит уже известную землю. Так выглядит
# разведанный коридор в настоящей игре — чанки разведки всегда примыкают к
# известной территории. Возвращает число открытых гексов.
func _explore_corridor(main_map, from_row: int, from_col: int) -> int:
    var queue: Array = [{"row": from_row, "col": from_col}]
    var visited := {"%d,%d" % [from_row, from_col]: true}
    var opened := 0
    # Разведка идёт ОТ городка, который уже разведан, поэтому первый гекс
    # разведку не останавливает — исключение делается только для него.
    var first := true
    while not queue.is_empty():
        var cur: Dictionary = queue.pop_front()
        if not first and main_map.is_hex_known(int(cur.row), int(cur.col)):
            continue
        first = false
        main_map.tile_data[cur.row][cur.col]["is_explored"] = true
        opened += 1
        for n in _hu.get_neighbors_odd_r(int(cur.row), int(cur.col),
                main_map.map_rows, main_map.map_cols):
            var key := "%d,%d" % [n.row, n.col]
            if visited.has(key):
                continue
            visited[key] = true
            if _is_water(main_map.tile_data[n.row][n.col]):
                continue
            queue.append({"row": n.row, "col": n.col})
    main_map.road_manager.bump_map_knowledge()
    return opened

# Все ли гексы трассы известны игроку (в Кольце Влияния или разведаны).
func _path_is_known(main_map, path: Array) -> bool:
    for hex in path:
        if not main_map.is_hex_known(int(hex.row), int(hex.col)):
            return false
    return true

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true







