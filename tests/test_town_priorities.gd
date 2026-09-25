# Headless-тест каскадно-уточняющего размещения городков
# (scripts/town_manager.gd).
#   godot --headless --path "E:\The City" --script res://tools/test_town_priorities.gd
#
# Проверки (на синтетических картах — детерминированно, без случайной карты):
#   1. База = ВЫСШИЙ приоритет, у которого есть валидный гекс НА ВСЕЙ КАРТЕ:
#      пока на карте есть свободное место с 2+ ресурсами в окрестностях,
#      городок не встанет у воды (река / озеро / море — нижние приоритеты).
#   2. Переход к следующему приоритету — ТОЛЬКО когда текущий исчерпан на всей
#      карте (все ресурсные окрестности в стартовой запретной зоне → база-река).
#   3. Поиск базы идёт ПО ВСЕЙ КАРТЕ: единственный валидный гекс, затерянный
#      среди тысяч гексов-кандидатов, обязан быть найден (раньше перебор
#      обрывался на 50 случайных попытках и городок мог вообще не поставиться).
#   4. Каскадное уточнение: городок переезжает в пределах REFINEMENT_RADIUS,
#      «добирая» нижние приоритеты — вплоть до идеала «2+ ресурса И
#      стратегический ресурс И река И берег озера И морской пляж».
#   5. Неудача на одном приоритете не прерывает каскад: «стратегию» не нашли —
#      реку всё равно пробуем и зарабатываем.
#   6. Пустая карта (нет ни ресурсов, ни рек, ни озёр, ни пляжей) → городок
#      не размещается (пустой словарь).
#   7. generate_towns(): на синтетической карте с избытком ресурсов ставятся
#      ВСЕ num_towns городков, и каждый реально удовлетворяет базовому
#      приоритету (2+ разных ресурса в радиусе MAX_ATTRACTION_DISTANCE).
extends SceneTree

# Дублируем константу town_manager.gd — тест проверяет поведение независимо.
const MAX_ATTRACTION_DISTANCE := 3

var _tm = null
var _gdata = null
var _hex_utils = null

func _initialize():
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Автозагрузки берём через дерево сцены: в режиме --script имена
    # GameData/CityData недоступны на этапе компиляции этого файла.
    # new_game() заодно грузит все данные (ресурсы, terrain, city_names).
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    _gdata = get_root().get_node("GameData")
    # Глобальный класс тоже берём через load(): в --script-режиме имя
    # HexUtils не гарантировано на этапе компиляции теста.
    _hex_utils = load("res://scripts/HexUtils.gd")

    _tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(_tm)

    _test_resources_beat_water(state)
    _test_primary_exhausted_falls_through(state)
    _test_full_map_scan_finds_only_valid_hex(state)
    _test_and_chain_reaches_ideal(state)
    _test_skipped_tier_does_not_break_cascade(state)
    _test_empty_map_places_nothing(state)
    _test_generate_towns_places_all(state)

    get_root().remove_child(_tm)
    _tm.free()

    if state["failed"]:
        print("TOWN PRIORITIES TEST FAILED")
        quit(1)
    else:
        print("TOWN PRIORITIES TEST OK")
        quit(0)


# -------------------------------------------------------
# Карта и вызовы алгоритма
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
                "terrain_icon": "",
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


# Прямой вызов «попробовать поставить один городок» (как в основном проходе
# generate_towns: без «обязательной» области).
func _try_place(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int,
        exclusion_start_row: int = -1, exclusion_end_row: int = -1,
        exclusion_start_col: int = -1, exclusion_end_col: int = -1,
        require_start_row: int = -1, require_end_row: int = -1,
        require_start_col: int = -1, require_end_col: int = -1) -> Dictionary:
    return _tm._try_place_one_town(tile_data, rows, cols, city_row, city_col,
            exclusion_start_row, exclusion_end_row,
            exclusion_start_col, exclusion_end_col,
            require_start_row, require_end_row,
            require_start_col, require_end_col,
            false)


# Заливает карту «ковром» ресурсов (включая стратегический, если
# include_strategic): тогда маска приоритета «2+ ресурса в окрестностях»
# покрывает ВСЮ карту, а единственными валидными гексами остаются те, что
# пропущены в skip (у них нет своего ресурса, поэтому они не отбраковываются
# как «гексы-ресурсы»).
func _fill_resource_carpet(tile_data: Array, skip: Array, include_strategic: bool = true) -> void:
    for r in range(tile_data.size()):
        for c in range(tile_data[r].size()):
            if skip.has(Vector2i(r, c)):
                continue
            var res := "sheep"
            match (r + c) % 3:
                0:
                    res = "copper_deposit" if include_strategic else "sheep"
                1:
                    res = "cows"
            tile_data[r][c]["resource"] = res


# Делает всю карту указанной местностью, кроме гексов из skip.
func _fill_terrain(tile_data: Array, terrain: String, skip: Array) -> void:
    for r in range(tile_data.size()):
        for c in range(tile_data[r].size()):
            if skip.has(Vector2i(r, c)):
                continue
            tile_data[r][c]["terrain"] = terrain


# -------------------------------------------------------
# Проверки условий приоритетов (считаются независимо от town_manager)
# -------------------------------------------------------

func _hexes_in_radius(tile_data: Array, row: int, col: int) -> Array:
    var result := []
    var rows: int = tile_data.size()
    var cols: int = tile_data[row].size()
    for r in range(maxi(0, row - MAX_ATTRACTION_DISTANCE),
            mini(rows, row + MAX_ATTRACTION_DISTANCE + 1)):
        for c in range(maxi(0, col - MAX_ATTRACTION_DISTANCE),
                mini(cols, col + MAX_ATTRACTION_DISTANCE + 1)):
            if _hex_utils.hex_distance(row, col, r, c) <= MAX_ATTRACTION_DISTANCE:
                result.append(Vector2i(r, c))
    return result


# Число РАЗНЫХ ресурсов в радиусе MAX_ATTRACTION_DISTANCE от гекса.
func _distinct_resources_near(tile_data: Array, row: int, col: int) -> int:
    var distinct := {}
    for p in _hexes_in_radius(tile_data, row, col):
        var res = tile_data[p.x][p.y].get("resource", null)
        if res != null and res != "":
            distinct[res] = true
    return distinct.size()


# Есть ли стратегический ресурс в радиусе MAX_ATTRACTION_DISTANCE от гекса.
func _has_strategic_near(tile_data: Array, row: int, col: int) -> bool:
    for p in _hexes_in_radius(tile_data, row, col):
        var res = tile_data[p.x][p.y].get("resource", null)
        if res == null or res == "":
            continue
        var res_data: Dictionary = _gdata.raw_resources.get(res, {})
        if bool(res_data.get("strategic", false)):
            return true
    return false


func _has_lake_neighbor(tile_data: Array, row: int, col: int) -> bool:
    var rows: int = tile_data.size()
    var cols: int = tile_data[row].size()
    for n in _hex_utils.get_neighbors_odd_r(row, col, rows, cols):
        if tile_data[n.row][n.col].get("terrain", "") == "lake":
            return true
    return false


func _has_river(tile_data: Array, row: int, col: int) -> bool:
    var edges: Array = tile_data[row][col].get("river_edges", [])
    return edges.size() > 0


func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true


# -------------------------------------------------------
# 1. Ресурсные окрестности перебивают воду (база — верхний приоритет)
# -------------------------------------------------------
func _test_resources_beat_water(state: Dictionary) -> void:
    var rows := 30
    var cols := 30
    var tile_data := _make_map(rows, cols)
    # Кучка ресурсов (2 разных) — верхний приоритет. Вода (река, озеро, пляж) —
    # нижние приоритеты, но заметно дальше. Если бы база выбиралась «по
    # удобству», городок мог бы встать на воде.
    tile_data[5][5]["resource"] = "cows"
    tile_data[6][6]["resource"] = "sheep"
    tile_data[25][10]["river_edges"] = [0]
    tile_data[25][25]["terrain"] = "lake"
    tile_data[24][25]["terrain"] = "beach"

    var placed = _try_place(tile_data, rows, cols, 0, 0)
    check(not placed.is_empty(),
            "городок должен быть размещён: есть ресурсные окрестности", state)
    if placed.is_empty():
        return
    var r: int = placed.row
    var c: int = placed.col
    check(_distinct_resources_near(tile_data, r, c) >= 2,
            ("база обязана быть ресурсной: ожидалось 2+ разных ресурса в радиусе %d, " +
                    "получено %d в (%d,%d)")
                    % [MAX_ATTRACTION_DISTANCE, _distinct_resources_near(tile_data, r, c), r, c],
            state)
    check(tile_data[r][c].get("terrain", "") != "beach",
            "городок не должен встать на морском пляже, пока есть ресурсные места", state)
    check(not _has_river(tile_data, r, c),
            "городок не должен встать на речном гексе, пока есть ресурсные места", state)
    check(not _has_lake_neighbor(tile_data, r, c),
            "городок не должен встать на берегу озера, пока есть ресурсные места", state)


# -------------------------------------------------------
# 2. Приоритет исчерпан на ВСЕЙ карте → переход к следующему
# -------------------------------------------------------
func _test_primary_exhausted_falls_through(state: Dictionary) -> void:
    var rows := 30
    var cols := 30
    var tile_data := _make_map(rows, cols)
    # Ресурсы (в т.ч. стратегический) — только в верхней половине карты, которую
    # целиком накрывает стартовая запретная зона: ресурсные приоритеты
    # исчерпаны на ВСЕЙ карте, и только тогда генератор обязан спуститься ниже.
    tile_data[5][5]["resource"] = "cows"
    tile_data[6][6]["resource"] = "sheep"
    tile_data[7][7]["resource"] = "copper_deposit"
    # Ниже запретной зоны — единственный речной гекс.
    tile_data[25][10]["river_edges"] = [0]

    var placed = _try_place(tile_data, rows, cols, 0, 0, 0, 19, 0, cols - 1)
    check(not placed.is_empty(),
            "городок обязан перейти к следующему приоритету, а не потеряться", state)
    if placed.is_empty():
        return
    check(placed.row == 25 and placed.col == 10,
            "ожидалась база «река» на (25,10), получено (%d,%d)" % [placed.row, placed.col], state)
    check(_has_river(tile_data, placed.row, placed.col),
            "база обязана быть речным гексом", state)
    check(_distinct_resources_near(tile_data, placed.row, placed.col) == 0,
            "ресурсов рядом с базой быть не должно — они все в запретной зоне", state)
    check(not _has_strategic_near(tile_data, placed.row, placed.col),
            "стратегического ресурса рядом с базой быть не должно", state)


# -------------------------------------------------------
# 3. Поиск базы — ПО ВСЕЙ КАРТЕ (без обрыва на N случайных попытках)
# -------------------------------------------------------
func _test_full_map_scan_finds_only_valid_hex(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var tile_data := _make_map(rows, cols)
    # Ресурсный «ковёр» по всей карте: маска верхнего приоритета покрывает ВСЮ
    # карту, а валидным остаётся единственный гекс (35,35) — в нём нет своего
    # ресурса, поэтому он не отбраковывается как «гекс-ресурс».
    _fill_resource_carpet(tile_data, [Vector2i(35, 35)])

    var placed = _try_place(tile_data, rows, cols, 0, 0)
    check(not placed.is_empty(),
            "единственный валидный гекс на карте обязан быть найден (обход всей карты)", state)
    if placed.is_empty():
        return
    check(placed.row == 35 and placed.col == 35,
            "ожидался (35,35), получено (%d,%d)" % [placed.row, placed.col], state)
    check(_distinct_resources_near(tile_data, placed.row, placed.col) >= 2,
            "найденный гекс обязан удовлетворять верхнему приоритету", state)


# -------------------------------------------------------
# 4. Каскадное уточнение добирает ВСЮ цепочку приоритетов
# -------------------------------------------------------
func _test_and_chain_reaches_ideal(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var tile_data := _make_map(rows, cols)
    var base_r := 20
    var base_c := 20
    var hero_r := 20
    var hero_c := 21
    # Вся карта — озеро (непроходимо), кроме двух валидных гексов:
    #   base — «просто ресурсный» гекс;
    #   hero — идеал: 2+ ресурса И стратегический ресурс И река И берег озера
    #          И морской пляж. Он в 1 гексе от base, то есть внутри радиуса
    #          уточнения REFINEMENT_RADIUS.
    _fill_terrain(tile_data, "lake", [Vector2i(base_r, base_c), Vector2i(hero_r, hero_c)])
    _fill_resource_carpet(tile_data, [Vector2i(base_r, base_c), Vector2i(hero_r, hero_c)])
    tile_data[hero_r][hero_c]["terrain"] = "beach"
    tile_data[hero_r][hero_c]["river_edges"] = [0]

    check(_distinct_resources_near(tile_data, hero_r, hero_c) >= 2,
            "идеальный гекс обязан иметь 2+ ресурса в окрестностях", state)
    check(_has_strategic_near(tile_data, hero_r, hero_c),
            "идеальный гекс обязан иметь стратегический ресурс в окрестностях", state)
    check(_has_lake_neighbor(tile_data, hero_r, hero_c),
            "идеальный гекс обязан быть на берегу озера", state)

    # База выбирается случайно из двух валидных гексов, поэтому прогоняем
    # несколько раз — проверяются оба пути (база уже идеальна и переезд к идеалу).
    for _i in range(25):
        var placed = _try_place(tile_data, rows, cols, 0, 0)
        if placed.is_empty():
            check(false, "городок должен быть размещён (на карте есть валидные гексы)", state)
            return
        check(placed.row == hero_r and placed.col == hero_c,
                "каскад обязан добрать всю цепочку: ожидался (%d,%d), получено (%d,%d)"
                        % [hero_r, hero_c, placed.row, placed.col],
                state)
        check(_distinct_resources_near(tile_data, placed.row, placed.col) >= 2,
                "финальный гекс обязан иметь 2+ ресурса в окрестностях", state)
        check(_has_strategic_near(tile_data, placed.row, placed.col),
                "финальный гекс обязан иметь стратегический ресурс в окрестностях", state)
        check(_has_river(tile_data, placed.row, placed.col),
                "финальный гекс обязан стоять на реке", state)
        check(tile_data[placed.row][placed.col].get("terrain", "") == "beach",
                "финальный гекс обязан быть на морском берегу", state)


# -------------------------------------------------------
# 5. Провал приоритета не прерывает каскад
# -------------------------------------------------------
func _test_skipped_tier_does_not_break_cascade(state: Dictionary) -> void:
    var rows := 36
    var cols := 36
    var tile_data := _make_map(rows, cols)
    var base_r := 18
    var base_c := 18
    var river_r := 18
    var river_c := 19
    # Вся карта — озеро, кроме base и речного гекса рядом. «Ковёр» — только из
    # НЕстратегических ресурсов, а единственный стратегический ресурс лежит в
    # дальнем углу среди непроходимой воды: маска стратегического приоритета
    # непустая, но достижимого валидного гекса у неё нет.
    _fill_terrain(tile_data, "lake", [Vector2i(base_r, base_c), Vector2i(river_r, river_c)])
    _fill_resource_carpet(tile_data, [Vector2i(base_r, base_c), Vector2i(river_r, river_c)], false)
    tile_data[2][2]["resource"] = "copper_deposit"
    tile_data[river_r][river_c]["river_edges"] = [0]

    for _i in range(25):
        var placed = _try_place(tile_data, rows, cols, 0, 0)
        if placed.is_empty():
            check(false, "городок должен быть размещён обязательно", state)
            return
        check(placed.row == river_r and placed.col == river_c,
                ("каскад обязан продолжиться после пропуска приоритета: " +
                        "ожидался (%d,%d), получено (%d,%d)")
                        % [river_r, river_c, placed.row, placed.col],
                state)
        check(_has_river(tile_data, placed.row, placed.col),
                "заработанный приоритет «река» обязан сохраниться", state)
        check(_distinct_resources_near(tile_data, placed.row, placed.col) >= 2,
                "базовый приоритет «2+ ресурса» обязан сохраниться", state)
        check(not _has_strategic_near(tile_data, placed.row, placed.col),
                "пропущенный стратегический приоритет не должен появиться", state)


# -------------------------------------------------------
# 6. Пустая карта → городок не размещается
# -------------------------------------------------------
func _test_empty_map_places_nothing(state: Dictionary) -> void:
    var rows := 20
    var cols := 20
    var tile_data := _make_map(rows, cols)
    var placed = _try_place(tile_data, rows, cols, 0, 0)
    check(placed.is_empty(),
            "на карте без ресурсов, рек, озёр и пляжей городок ставить негде", state)


# -------------------------------------------------------
# 7. generate_towns(): все городки поставлены, база у каждого ресурсная
# -------------------------------------------------------
func _test_generate_towns_places_all(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var tile_data := _make_map(rows, cols)
    # Свободные от ресурсов гексы — каждый второй по обеим осям: вокруг каждого
    # есть 2+ разных ресурса, а дистанций хватает на рассредоточение городков.
    var free_hexes := []
    for r in range(rows):
        for c in range(cols):
            if r % 2 == 0 and c % 2 == 0:
                free_hexes.append(Vector2i(r, c))
    _fill_resource_carpet(tile_data, free_hexes)

    var map_config: Dictionary = _gdata.map_config
    var saved_num_towns = map_config.get("num_towns", 8)
    map_config["num_towns"] = 5
    _tm.generate_towns(tile_data, rows, cols, 20, 20,
            0, 0, 0, 0,                # стартовая запретная зона (гекс города)
            0, rows - 1, 0, cols - 1)  # «эра-2» = вся карта: лишний городок не нужен
    map_config["num_towns"] = saved_num_towns

    check(_tm.town_hexes.size() == 5,
            "ожидалось 5 городков, размещено %d" % _tm.town_hexes.size(), state)
    for h in _tm.town_hexes:
        check(_distinct_resources_near(tile_data, h.row, h.col) >= 2,
                "городок (%d,%d) обязан иметь 2+ ресурса в окрестностях"
                        % [h.row, h.col],
                state)
    for i in range(_tm.town_hexes.size()):
        for j in range(i + 1, _tm.town_hexes.size()):
            var a: Dictionary = _tm.town_hexes[i]
            var b: Dictionary = _tm.town_hexes[j]
            check(_hex_utils.hex_distance(a.row, a.col, b.row, b.col) >= 3,
                    "городки (%d,%d) и (%d,%d) стоят слишком близко"
                            % [a.row, a.col, b.row, b.col],
                    state)

