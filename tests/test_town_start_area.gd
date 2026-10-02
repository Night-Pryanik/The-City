# Headless-тест: территория городков НИКОГДА не заходит на стартовую область
# игрока (Кольцо Влияния + Регион 1-й эпохи).
#   godot --headless --path . --script res://tests/test_town_start_area.gd
#
# Инвариант проверяется с двух сторон:
#   А. Генерация — ресурсы игрока не являются точками притяжения. Раньше городок
#      вставал ради ресурсов стартовой области, а его кольцо (радиус 3) заходило
#      на землю игрока: ресурс в Кольце Влияния помечался in_town_influence,
#      build_manager блокировал его улучшение, а городок ставил там свою
#      декоративную постройку.
#   Б. Кольца — каждый гекс стартовой области вырезается из кольца влияния, у
#      всех городков без исключения (включая гарантийный городок 2-й эпохи).
#      Вырезанные гексы не получают флаг in_town_influence, не попадают в пул
#      продажи и под декоративные улучшения.
#
# Проверки (на синтетических картах — детерминированно):
#   1. Ресурсы, лежащие ТОЛЬКО в стартовой области, не дают гексу базового
#      приоритета «2+ ресурса в окрестностях»; те же ресурсы, положенные рядом
#      с гексом, но ВНЕ области, — дают (правило не «выключает» маску целиком).
#   2. Стратегический ресурс игрока не притягивает городков: маска «strategic»
#      не выходит за пределы стартовой области.
#   3. Кольцо городка у самой границы области вырезается; ресурс игрока рядом с
#      городком не попадает в пул продажи и под декоративные улучшения.
#   4. Городки, восстановленные из сейва (load_towns), вырезаются так же —
#      старые партии не должны загружаться с городками на земле игрока.
#   5. generate_towns() запоминает переданную exclusion-зону как стартовую
#      область игрока, и ни один городок на ней не стоит.
#   6. Живая сцена MainMap (новая игра): в стартовой области нет ни гексов
#      колец, ни городков, ни декоративных улучшений; после смены эпохи в
#      присвоенной игроку территории не остаётся «мёртвых зон»
#      (in_influence ∩ in_town_influence = ∅).
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Идентификаторы из data/resources: два разных обычных ресурса для приоритета
# «2+ разных ресурса» и один стратегический (metals.json, strategic: true).
const RES_A := "sheep"
const RES_B := "cows"
const RES_STRATEGIC := "hematite_deposit"

# Стартовая область игрока на синтетических картах: центральный квадрат 6x6.
const AREA_R0 := 9
const AREA_R1 := 14
const AREA_C0 := 9
const AREA_C1 := 14

var _tm = null
var _gdata = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(_tm)

    _test_player_resources_are_not_attraction(state)
    _test_player_strategic_is_not_attraction(state)
    _test_ring_is_clipped_by_player_area(state)
    _test_loaded_towns_are_clipped(state)
    _test_generate_towns_remembers_player_area(state)

    # Живая сцена — последней и отдельно: MainMap создаёт собственный
    # TownManager, держать рядом второй экземпляр незачем.
    get_root().remove_child(_tm)
    _tm.free()
    _tm = null

    await _test_live_scene(state)

    if state["failed"]:
        print("TOWN START AREA TEST FAILED")
        quit(1)
    else:
        print("TOWN START AREA TEST OK")
        quit(0)


# -------------------------------------------------------
# Синтетические карты
# -------------------------------------------------------

# Пустая карта: все гексы — равнина без ресурсов, рек, улучшений и городков.
func _make_map(rows: int, cols: int) -> Array:
    var tile_data := []
    for r in range(rows):
        var row := []
        for c in range(cols):
            row.append({
                "terrain": "plain",
                "cover": "none",
                "resource": null,
                "quality": "",
                "crop_bred": null,
                "improvement": null,
                "decorative": false,
                "fill_time": 0.0,
                "production_fractional_remainder": 0.0,
                "feed_fractional_remainder": 0.0,
                "has_town": false,
                "river_edges": [],
                "in_influence": false,
                "is_explored": false,
                "in_town_influence": false,
            })
        tile_data.append(row)
    return tile_data


# Кладёт два чередующихся вида ресурсов в стартовую область игрока.
func _fill_player_area_with_resources(tile_data: Array) -> void:
    for r in range(AREA_R0, AREA_R1 + 1):
        for c in range(AREA_C0, AREA_C1 + 1):
            tile_data[r][c]["resource"] = RES_A if (r + c) % 2 == 0 else RES_B


# Лежит ли гекс в синтетической стартовой области игрока.
func _in_player_area(row: int, col: int) -> bool:
    return row >= AREA_R0 and row <= AREA_R1 and col >= AREA_C0 and col <= AREA_C1


# То же для произвольных границ — нужна в проверке generate_towns, где
# стартовая область задаётся вызовом, а не константами карты.
func _in_area(row: int, col: int,
        r0: int, r1: int, c0: int, c1: int) -> bool:
    return row >= r0 and row <= r1 and col >= c0 and col <= c1


# -------------------------------------------------------
# 1. Ресурсы игрока не считаются точками притяжения
# -------------------------------------------------------
func _test_player_resources_are_not_attraction(state: Dictionary) -> void:
    var rows := 24
    var cols := 24
    var tile_data := _make_map(rows, cols)
    _tm.set_player_start_area(AREA_R0, AREA_R1, AREA_C0, AREA_C1)
    _fill_player_area_with_resources(tile_data)

    # Пробный гекс — сразу снаружи стартовой области (строка 9, колонка 15).
    # Все ресурсы в его окрестностях (радиус 3) лежат ВНУТРИ области игрока:
    # два разных вида, то есть без нового правила он получил бы базовый
    # приоритет «2+ разных ресурса в окрестностях».
    var probe := Vector2i(AREA_R0, AREA_C1 + 1)
    var mask: PackedByteArray = _tm._build_multi_resource_mask(tile_data, rows, cols)
    check(mask[probe.x * cols + probe.y] == 0,
        "ресурсы стартовой области игрока не должны давать базовый приоритет городку (гекс %s попал в маску multi_resource)" % str(probe), state)

    # Контроль: те же два вида, положенные СНАРУЖИ области, в окрестностях
    # пробного гекса, — приоритет выдают. Значит правило отсекает именно
    # территорию игрока, а не ломает саму маску.
    tile_data[probe.x][probe.y + 2]["resource"] = RES_A
    tile_data[probe.x + 1][probe.y + 2]["resource"] = RES_B
    mask = _tm._build_multi_resource_mask(tile_data, rows, cols)
    check(mask[probe.x * cols + probe.y] == 1,
        "ресурсы ВНЕ стартовой области должны по-прежнему притягивать городка (гекс %s не попал в маску multi_resource)" % str(probe), state)


# -------------------------------------------------------
# 2. Стратегический ресурс игрока не притягивает городков
# -------------------------------------------------------
func _test_player_strategic_is_not_attraction(state: Dictionary) -> void:
    var rows := 24
    var cols := 24
    var tile_data := _make_map(rows, cols)
    _tm.set_player_start_area(AREA_R0, AREA_R1, AREA_C0, AREA_C1)
    tile_data[AREA_R0][AREA_C0]["resource"] = RES_STRATEGIC

    var mask: PackedByteArray = _tm._build_strategic_mask(tile_data, rows, cols)
    var outside: Array = []
    for r in range(rows):
        for c in range(cols):
            if mask[r * cols + c] == 0:
                continue
            if not _in_player_area(r, c):
                outside.append([r, c])
    check(outside.is_empty(),
        "стратегический ресурс игрока не должен притягивать городков за пределы стартовой области (нарушителей: %s)" % str(outside), state)

    # Контроль: стратегический ресурс СНАРУЖИ области работает как раньше.
    var probe := Vector2i(AREA_R0, AREA_C1 + 1)
    tile_data[probe.x][probe.y + 1]["resource"] = RES_STRATEGIC
    mask = _tm._build_strategic_mask(tile_data, rows, cols)
    check(mask[probe.x * cols + probe.y] == 1,
        "стратегический ресурс вне стартовой области должен притягивать городка (гекс %s не попал в маску strategic)" % str(probe), state)


# -------------------------------------------------------
# 3. Кольцо вырезается по стартовой области (включая городок эры-2)
# -------------------------------------------------------
func _test_ring_is_clipped_by_player_area(state: Dictionary) -> void:
    var rows := 24
    var cols := 24
    var tile_data := _make_map(rows, cols)
    _tm.set_player_start_area(AREA_R0, AREA_R1, AREA_C0, AREA_C1)
    # Ресурс ИГРОКА в зоне кольца, но внутри стартовой области (гекс (12,14) —
    # ровно в 3 гексах от городка (12,17)): раньше он попадал и в кольцо, и в
    # пул продажи, и под декоративное улучшение, становясь недоступным игроку.
    tile_data[12][AREA_C1]["resource"] = RES_A

    # Два городка у самой границы: обычный и «гарантийный» для 2-й эпохи.
    # Правило обязано быть одинаковым — иначе гарантийный городок снова
    # окажется залезшим на стартовую территорию игрока.
    var town: Dictionary = _tm._make_town_record(0, 12, AREA_C1 + 3, false)
    var era2_town: Dictionary = _tm._make_town_record(1, 18, 12, true)
    _tm.towns.append(town)
    _tm.towns.append(era2_town)
    tile_data[12][AREA_C1 + 3]["has_town"] = true
    tile_data[18][12]["has_town"] = true

    _tm.compute_all_town_influences(tile_data, rows, cols)

    check(_tm.towns.size() == 2,
        "в тесте должно быть 2 городка (обычный и гарантийный эры-2)", state)
    for t in _tm.towns:
        var leaked: Array = []
        for h in t.get("influence_hexes", []):
            if _in_player_area(int(h.row), int(h.col)):
                leaked.append([int(h.row), int(h.col)])
        check(leaked.is_empty(),
            "кольцо городка (%d,%d) не должно содержать гексов стартовой области игрока (затерено: %s, is_era2_guaranteed=%s)"
                % [int(t.row), int(t.col), str(leaked), str(bool(t.get("is_era2_guaranteed", false)))], state)
        # Кольцо не вырождается в пустоту: центр и ближайшие гексы остаются.
        var keeps_center := false
        for h in t.get("influence_hexes", []):
            if int(h.row) == int(t.row) and int(h.col) == int(t.col):
                keeps_center = true
                break
        check(keeps_center,
            "после вырезки кольцо городка (%d,%d) должно сохранить хотя бы свой центр" % [int(t.row), int(t.col)], state)

    # Флаг in_town_influence на гексах игрока не выставлен.
    var flagged: Array = []
    for r in range(AREA_R0, AREA_R1 + 1):
        for c in range(AREA_C0, AREA_C1 + 1):
            if bool(tile_data[r][c].get("in_town_influence", false)):
                flagged.append([r, c])
    check(flagged.is_empty(),
        "на стартовой области игрока не должно быть флага in_town_influence (нарушителей: %s)" % str(flagged), state)

    # Ресурс игрока не попал в пул продажи городка.
    var sold_player_resource := false
    for t in _tm.towns:
        if t.get("sell_pool", []).has(RES_A):
            sold_player_resource = true
    check(not sold_player_resource,
        "городок не должен продавать ресурсы, лежащие в стартовой области игрока", state)

    # Декоративные улучшения не строятся на земле игрока.
    _tm._place_decorative_town_improvements(tile_data, rows, cols)
    var built_on_player_area: Array = []
    for r in range(AREA_R0, AREA_R1 + 1):
        for c in range(AREA_C0, AREA_C1 + 1):
            if tile_data[r][c].get("improvement", null) != null:
                built_on_player_area.append([r, c])
    check(built_on_player_area.is_empty(),
        "городок не должен ставить улучшения на стартовой области игрока (гексы: %s)" % str(built_on_player_area), state)




# -------------------------------------------------------
# 4. Загруженные из сейва городки вырезаются так же
# -------------------------------------------------------
# Ровно тот путь, который делает main_map при загрузке партии: городки
# восстанавливаются из записей сейва (load_towns), границы стартовой области
# игрока приходят из map_state (set_player_start_area), и только после этого
# кольца пересчитываются. Старая партия не должна загрузиться с городками,
# залезающими на землю игрока.
func _test_loaded_towns_are_clipped(state: Dictionary) -> void:
    var rows := 24
    var cols := 24
    var tile_data := _make_map(rows, cols)
    # Формат сейва [[row, col], ...] — кольца в нём нет, оно строится заново.
    _tm.load_towns([[12, AREA_C1 + 3], [18, 12]])
    _tm.set_player_start_area(AREA_R0, AREA_R1, AREA_C0, AREA_C1)
    _tm.compute_all_town_influences(tile_data, rows, cols)

    check(_tm.towns.size() == 2,
        "из сейва должны восстановиться оба городка, получено %d" % _tm.towns.size(), state)
    for t in _tm.towns:
        var leaked: Array = []
        for h in t.get("influence_hexes", []):
            if _in_player_area(int(h.row), int(h.col)):
                leaked.append([int(h.row), int(h.col)])
        check(leaked.is_empty(),
            "загруженный городок (%d,%d) не должен залезать кольцом на стартовую область игрока (гексы: %s)"
                % [int(t.row), int(t.col), str(leaked)], state)
    var flagged := 0
    for r in range(AREA_R0, AREA_R1 + 1):
        for c in range(AREA_C0, AREA_C1 + 1):
            if bool(tile_data[r][c].get("in_town_influence", false)):
                flagged += 1
    check(flagged == 0,
        "после загрузки на стартовой области игрока не должно остаться флага in_town_influence (гексов: %d)" % flagged, state)


# -------------------------------------------------------
# 5. generate_towns() запоминает стартовую область
# -------------------------------------------------------
func _test_generate_towns_remembers_player_area(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var tile_data := _make_map(rows, cols)
    # Ресурсный ковёр, кроме свободных гексов — как в test_town_priorities:
    # тогда верхний приоритет доступен везде и городки расставляются.
    for r in range(rows):
        for c in range(cols):
            if r % 2 == 0 and c % 2 == 0:
                continue
            tile_data[r][c]["resource"] = RES_A if (r + c) % 2 == 0 else RES_B

    var map_config: Dictionary = _gdata.map_config
    var saved_num_towns = map_config.get("num_towns", 8)
    map_config["num_towns"] = 4
    # Стартовая область — центральные 13x13 гексов, «эра-2» — вся карта.
    _tm.generate_towns(tile_data, rows, cols, 20, 20,
            14, 26, 14, 26,
            0, rows - 1, 0, cols - 1)
    map_config["num_towns"] = saved_num_towns

    check(_tm.player_start_area == {
            "start_row": 14, "end_row": 26, "start_col": 14, "end_col": 26},
        "generate_towns должен запомнить exclusion-зону как стартовую область игрока, получено: %s" % str(_tm.player_start_area), state)
    check(_tm.towns.size() > 0,
        "на этой карте городки должны расставиться (иначе проверять нечего)", state)
    for t in _tm.towns:
        check(not _in_area(int(t.row), int(t.col), 14, 26, 14, 26),
            "центр городка не должен стоять в стартовой области игрока (%d,%d)" % [int(t.row), int(t.col)], state)
        for h in t.get("influence_hexes", []):
            if _in_area(int(h.row), int(h.col), 14, 26, 14, 26):
                check(false,
                    "кольцо городка (%d,%d) заходит на стартовую область игрока в (%d,%d)"
                        % [int(t.row), int(t.col), int(h.row), int(h.col)], state)
                break


# -------------------------------------------------------
# 6. Живая сцена MainMap (новая игра)
# -------------------------------------------------------
func _test_live_scene(state: Dictionary) -> void:
    get_root().get_node("SaveManager").new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var tile_data = main_map.tile_data
    # 1. На стартовой области игрока нет ни колец, ни городков, ни их улучшений.
    var intruders: Array = []
    for row in range(main_map.start_region_start_row, main_map.start_region_end_row + 1):
        for col in range(main_map.start_region_start_col, main_map.start_region_end_col + 1):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            if bool(tile.get("in_town_influence", false)) \
                    or bool(tile.get("has_town", false)) \
                    or bool(tile.get("decorative", false)):
                intruders.append([row, col])
    check(intruders.is_empty(),
        "на живой карте стартовая область игрока свободна от городков и их территорий (нарушителей: %s)" % str(intruders), state)

    # 2. Ни одно личное кольцо (в т.ч. гарантийного городка эры-2) не содержит
    #    гексов стартовой области.
    var ring_leaks: Array = []
    for t in main_map.towns:
        for h in t.get("influence_hexes", []):
            if _in_main_map_start_area(main_map, int(h.row), int(h.col)):
                ring_leaks.append([int(t.row), int(t.col), int(h.row), int(h.col)])
    check(ring_leaks.is_empty(),
        "кольца городков не должны содержать гексов стартовой области игрока (нарушителей: %s)" % str(ring_leaks), state)

    # 3. После смены эпохи присвоенная игроку территория не содержит «мёртвых
    #    зон»: присвоенный гекс не может одновременно принадлежать городку.
    main_map.advance_to_next_era()
    await process_frame
    var dead_zones: Array = []
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = tile_data[row][col]
            if tile == null:
                continue
            if bool(tile.get("in_influence", false)) \
                    and bool(tile.get("in_town_influence", false)):
                dead_zones.append([row, col])
    check(dead_zones.is_empty(),
        "после смены эпохи в Кольце Влияния игрока не должно остаться гексов городков (мертвых зон: %s)" % str(dead_zones), state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()


func _in_main_map_start_area(main_map, row: int, col: int) -> bool:
    return row >= main_map.start_region_start_row \
        and row <= main_map.start_region_end_row \
        and col >= main_map.start_region_start_col \
        and col <= main_map.start_region_end_col


func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: " + msg)
        state["failed"] = true


