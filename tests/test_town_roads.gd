# Headless-тест дорог городков (scripts/road_manager.gd, scripts/main_map.gd).
#   godot --headless --path . --script res://tests/test_town_roads.gd
#
# Проверки (на синтетических картах — детерминированно, без случайной карты):
#   1. У каждого городка дорога проложена к КАЖДОМУ его улучшению: гекс
#      улучшения оказывается в его сети (is_town_connected), и до центра
#      городка от него действительно идёт цепочка сегментов (BFS по
#      town_road_segments — проверка формы сети, а не только флага).
#   2. Сети городков изолированы: в сети города игрока подключён только его
#      гекс и нет ни одного сегмента (все улучшения на карте — городковые),
#      ни один сегмент городка не попадает в набор дорог города, а центры
#      городков — корни своих сетей. Логическая изоляция держится на том, что
#      поиск дороги останавливается только на гексах СВОЕГО городка.
#   3. Декоративные (городковые) улучшения НЕ попадают в сеть города игрока
#      при пересчёте из сейва: rebuild_roads_from_existing вызывается ДО
#      загрузки городков, а в tile_data улучшения лежат общие. Без этой
#      проверки дороги города разрастались бы к полям и лесным делянкам ВСЕХ
#      городков на карте.
#   4. Водное улучшение (рыбацкие лодки на озере) дороги не получает — так же,
#      как у города игрока.
#   5. На живой сцене MainMap (новая игра) проверяется ПРАВИЛО, а не исход:
#      улучшение соединено дорогой тогда и только тогда, когда до центра
#      городка есть путь по суше; плюс гейты видимости — эра 0 не видно,
#      с эры Античности видно, сегмент с концом в тумане скрыт, разведка его
#      открывает (те же гейты, что у заливки колец).
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _tm = null
var _rm = null
var _gdata = null
var _hex_utils = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Автозагрузки берём через дерево сцены: в режиме --script имена
    # GameData/CityData недоступны на этапе компиляции этого файла.
    # new_game() заодно грузит все данные (улучшения, ресурсы, city_names).
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _hex_utils = load("res://scripts/HexUtils.gd")

    _tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(_tm)
    _rm = load("res://scripts/road_manager.gd").new()
    get_root().add_child(_rm)

    _test_every_town_improvement_has_road(state)
    _test_networks_are_separate(state)
    _test_decorative_improvements_not_in_player_network(state)
    _test_water_improvement_has_no_road(state)

    # Живая сцена проверяется последней и отдельно освобождается: MainMap
    # создаёт собственные TownManager/RoadManager, и держать рядом вторые
    # экземпляры незачем.
    get_root().remove_child(_tm)
    _tm.free()
    get_root().remove_child(_rm)
    _rm.free()
    _tm = null
    _rm = null

    await _test_live_scene(state)

    if state["failed"]:
        print("TOWN ROADS TEST FAILED")
        quit(1)
    else:
        print("TOWN ROADS TEST OK")
        quit(0)


# -------------------------------------------------------
# Карта и расстановка (детерминированная синтетика)
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

# Заливает карту «ковром» ресурсов, кроме гексов из skip: тогда ВСЕ гексы
# удовлетворяют верхнему приоритету «2+ разных ресурса в окрестностях», а
# городки встают на оставшиеся свободные гексы. Ровно тот приём, что и в
# test_town_priorities.
func _fill_resource_carpet(tile_data: Array, skip: Array) -> void:
    for r in range(tile_data.size()):
        for c in range(tile_data[r].size()):
            if skip.has(Vector2i(r, c)):
                continue
            tile_data[r][c]["resource"] = "sheep" if (r + c) % 2 == 0 else "cows"

# Ставит num_towns городков на свежей карте и возвращает её.
func _make_town_map(rows: int, cols: int, city_row: int, city_col: int,
        num_towns: int) -> Array:
    var tile_data := _make_map(rows, cols)
    # Свободные от ресурсов гексы — каждый второй по обеим осям: у каждого
    # есть 2+ РАЗНЫХ ресурса в окрестностях, а дистанций хватает на
    # рассредоточение городков.
    var free_hexes := []
    for r in range(rows):
        for c in range(cols):
            if r % 2 == 0 and c % 2 == 0:
                free_hexes.append(Vector2i(r, c))
    _fill_resource_carpet(tile_data, free_hexes)

    var map_config: Dictionary = _gdata.map_config
    var saved_num_towns = map_config.get("num_towns", 8)
    map_config["num_towns"] = num_towns
    # Запретная зона вокруг города — 3 гекса в каждую сторону, а не сам гекс
    # города. В настоящей игре городки исключены из стартовой области
    # (Кольцо + Регион), поэтому кольцо влияния городка (радиус 3) никогда не
    # накрывает гекс города. С одним лишь гексом города этого не получалось:
    # городок в 4 гексах от города ставился, и его кольцо доходило до гекса
    # города — тогда проверки про сеть города имитировали ситуацию, которой в
    # игре не бывает.
    _tm.generate_towns(tile_data, rows, cols, city_row, city_col,
            city_row - 3, city_row + 3, city_col - 3, city_col + 3,
            0, rows - 1, 0, cols - 1)                # «эра-2» = вся карта
    map_config["num_towns"] = saved_num_towns
    return tile_data

# Ставит улучшения в кольца городков — так же, как это делает сама игра
# (town_manager._place_decorative_town_improvements вызывается в самом конце
# generate_towns, а при загрузке сейва — отдельно в main_map).
func _place_town_improvements(tile_data: Array, rows: int, cols: int) -> void:
    _tm._place_decorative_town_improvements(tile_data, rows, cols)

# Гексы кольца городка, на которых стоит улучшение.
func _town_improvement_hexes(town: Dictionary, tile_data: Array) -> Array:
    var result: Array = []
    for h in town.get("influence_hexes", []):
        var row := int(h.get("row", -1))
        var col := int(h.get("col", -1))
        if row < 0 or col < 0 or row >= tile_data.size() or col >= tile_data[row].size():
            continue
        if tile_data[row][col] == null:
            continue
        if tile_data[row][col].get("improvement", null) == null:
            continue
        result.append({"row": row, "col": col})
    return result

# -------------------------------------------------------
# 1. К каждому улучшению городка проложена дорога от самого городка
# -------------------------------------------------------
func _test_every_town_improvement_has_road(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var city_row := 20
    var city_col := 20
    var tile_data := _make_town_map(rows, cols, city_row, city_col, 5)
    check(_tm.towns.size() == 5,
            "ожидалось 5 городков, размещено %d" % _tm.towns.size(), state)
    _place_town_improvements(tile_data, rows, cols)

    var improvements_total := 0
    for town in _tm.towns:
        improvements_total += _town_improvement_hexes(town, tile_data).size()
    check(improvements_total > 0,
            "на карте должно быть хотя бы одно улучшение городка (иначе проверять нечего)",
            state)

    # Сеть города игрока (гекс города) + сети городков.
    _rm.initialize(city_row, city_col)
    _rm.rebuild_town_roads(_tm.towns, tile_data, rows, cols)

    var town_segments: Dictionary = _rm.get_all_town_road_segments()
    for town in _tm.towns:
        var town_row := int(town.get("row", -1))
        var town_col := int(town.get("col", -1))
        for imp in _town_improvement_hexes(town, tile_data):
            check(_rm.is_town_connected(town_row, town_col, imp.row, imp.col),
                    "улучшение (%d,%d) городка (%d,%d) должно быть соединено с ним дорогой"
                            % [imp.row, imp.col, town_row, town_col], state)
            check(_has_segment_chain(town_segments, imp.row, imp.col, town_row, town_col),
                    "от улучшения (%d,%d) не идёт цепочка сегментов к городку (%d,%d)"
                            % [imp.row, imp.col, town_row, town_col], state)
            # Дорога по воде не строится: ни один конец сегмента у водного гекса
            # не может быть водным.
            for seg in _segments_touching(town_segments, imp.row, imp.col):
                check(not _is_water(tile_data[seg[0]][seg[1]])
                        and not _is_water(tile_data[seg[2]][seg[3]]),
                        "сегмент дороги городка идёт по воде: (%d,%d)-(%d,%d)"
                                % [seg[0], seg[1], seg[2], seg[3]], state)

# -------------------------------------------------------
# 2. Сети городков изолированы от сети города и друг от друга
# -------------------------------------------------------
func _test_networks_are_separate(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var city_row := 20
    var city_col := 20
    var tile_data := _make_town_map(rows, cols, city_row, city_col, 5)
    _place_town_improvements(tile_data, rows, cols)
    _rm.initialize(city_row, city_col)
    _rm.rebuild_town_roads(_tm.towns, tile_data, rows, cols)

    # Сеть города игрока: подключён только гекс города, сегментов нет — все
    # улучшения на этой карте принадлежат городкам.
    check(_rm.connected_hexes.size() == 1
            and _rm.connected_hexes.has("%d,%d" % [city_row, city_col]),
            "в сети города игрока должен быть только его гекс, а набралось гексов: %d"
                    % _rm.connected_hexes.size(), state)
    check(_rm.get_all_road_segments().is_empty(),
            "дороги города игрока не должны строиться к улучшениям городков", state)

    # Сегменты городков живут в СВОЕМ наборе: ни один из них не попадает в
    # сегменты города игрока. Заметим: геометрически дорога городка МОЖЕТ
    # пройти рядом с городом (дорога — физическая, путь ищется по всей карте,
    # как у города игрока), но логически она не присоединена к сети города:
    # connected_hexes города остался в одном гексе, а поиск дороги городка
    # останавливается только на гексах СВОЕГО городка. Поэтому проверяем
    # разделение наборов, а не «не касается гекса города».
    var town_segments: Dictionary = _rm.get_all_town_road_segments()
    check(not town_segments.is_empty(),
            "на карте с улучшениями городков должна строиться сеть дорог", state)
    for seg in town_segments.keys():
        check(not _rm.get_all_road_segments().has(seg),
                "сегмент дороги городка не должен попасть в набор дорог города: %s" % seg,
                state)

    # У каждого городка свой корень сети и свои улучшения, к которым дорога
    # строится ОТ СВОЕГО центра.
    #
    # Чего здесь сознательно нет: проверки «улучшение чужого городка не должно
    # попасть в сеть соседнего». Дорога — физическая: путь ищется по всей
    # карте, и трасса одного городка вполне может ПРОЙТИ через гекс с полем
    # соседа (гекс на трассе, как и гекс с постройкой на трассе города игрока,
    # просто соединён дорогой). Запрещать такое нельзя: кольцо может быть
    # срезано соседним городком, и тогда единственный обходной путь — мимо его
    # гексов. Логическая изоляция гарантирована и проверяется выше: поиск
    # останавливается только на гексах СВОЕГО городка, а чужой городок
    # подключается к своей сети только из своего центра.
    for town in _tm.towns:
        var town_row := int(town.get("row", -1))
        var town_col := int(town.get("col", -1))
        check(_rm.is_town_connected(town_row, town_col, town_row, town_col),
                "центр городка (%d,%d) должен быть корнем своей сети дорог"
                        % [town_row, town_col], state)

# -------------------------------------------------------
# 3. Декоративные улучшения не попадают в сеть города игрока
#    (регресс: пересчёт из сейва идёт ДО загрузки городков)
# -------------------------------------------------------
func _test_decorative_improvements_not_in_player_network(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var city_row := 20
    var city_col := 20
    var tile_data := _make_town_map(rows, cols, city_row, city_col, 5)
    _place_town_improvements(tile_data, rows, cols)

    # Улучшение ИГРОКА рядом с городом: в сеть города оно попасть обязательно —
    # иначе проверка «городковые не попадают» прошла бы на пустой сети. Гекс
    # берётся тот, где улучшений ещё нет и который не принадлежит кольцу
    # городка: иначе нашлось бы совпадение с улучшением городка, и проверка
    # «городковые не попадают в сеть города» падала бы на нём самом.
    var player_hex := _free_hex_near_city(city_row, city_col, rows, cols, tile_data)
    check(not player_hex.is_empty(),
            "рядом с городом должен найтись свободный гекс под улучшение игрока", state)
    if player_hex.is_empty():
        return
    tile_data[player_hex.row][player_hex.col]["improvement"] = "farm"
    tile_data[player_hex.row][player_hex.col]["decorative"] = false

    # Ровно то, что делает main_map при загрузке сейва: городки в этот момент
    # ещё не загружены, все улучшения лежат в общем tile_data.
    _rm.initialize(city_row, city_col)
    _rm.rebuild_roads_from_existing(tile_data, rows, cols)

    check(_rm.connected_hexes.has("%d,%d" % [int(player_hex.row), int(player_hex.col)]),
            "улучшение игрока должно быть подключено к сети города", state)
    for town in _tm.towns:
        for imp in _town_improvement_hexes(town, tile_data):
            check(not _rm.connected_hexes.has("%d,%d" % [imp.row, imp.col]),
                    "улучшение городка (%d,%d) не должно попадать в сеть города игрока"
                            % [imp.row, imp.col], state)
            check(not _has_segment_touching(_rm.get_all_road_segments(), imp.row, imp.col),
                    "дороги города игрока не должны доходить до улучшения городка (%d,%d)"
                            % [imp.row, imp.col], state)

# -------------------------------------------------------
# 4. Водное улучшение дороги не получает (как у города игрока)
# -------------------------------------------------------
func _test_water_improvement_has_no_road(state: Dictionary) -> void:
    var rows := 40
    var cols := 40
    var city_row := 20
    var city_col := 20
    var tile_data := _make_town_map(rows, cols, city_row, city_col, 5)
    _place_town_improvements(tile_data, rows, cols)

    # Озеро с рыбацкими лодками и наземное улучшение в кольце первого
    # городка: первое не должно получить дорогу, второе (контроль) — должно.
    var town: Dictionary = _tm.towns[0]
    var town_row := int(town.get("row", -1))
    var town_col := int(town.get("col", -1))
    var water_hex = _free_ring_hex(town, tile_data, 1)
    var land_hex = _free_ring_hex(town, tile_data, 1,
            ["%d,%d" % [int(water_hex.row), int(water_hex.col)]] if water_hex != null else [])
    check(water_hex != null and land_hex != null,
            "в кольце городка должны найтись свободные гексы под воду и под сушу", state)
    if water_hex == null or land_hex == null:
        return
    tile_data[water_hex.row][water_hex.col]["terrain"] = "lake"
    tile_data[water_hex.row][water_hex.col]["improvement"] = "fishing_boats"
    tile_data[water_hex.row][water_hex.col]["decorative"] = true
    tile_data[land_hex.row][land_hex.col]["improvement"] = "farm"
    tile_data[land_hex.row][land_hex.col]["decorative"] = true

    _rm.initialize(city_row, city_col)
    _rm.rebuild_town_roads(_tm.towns, tile_data, rows, cols)

    check(not _rm.is_town_connected(town_row, town_col, water_hex.row, water_hex.col),
            "рыбацкие лодки на озере не должны получать дорогу (вода)", state)
    check(_rm.is_town_connected(town_row, town_col, land_hex.row, land_hex.col),
            "наземное улучшение в кольце городка обязано получить дорогу (контроль)",
            state)

# -------------------------------------------------------
# 5. Живая сцена MainMap: сети построены, видны с эры Античности
#    и не заходят в туман войны
# -------------------------------------------------------
func _test_live_scene(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var rm = main_map.road_manager
    var r = main_map.map_renderer
    var towns: Array = main_map.towns

    # Правило, а не исход: дорога есть тогда и только тогда, когда от гекса
    # улучшения до центра городка есть путь ПО СУШЕ. На живой (случайной) карте
    # улучшения стоят и на водных гексах кольца (рыбные озёра), и на гексах,
    # отрезанных водой от городка, — такие дороги не получают, и это правильно
    # (вода непроходима, ровно как у города игрока). Проверять «у всех есть
    # дорога» здесь нельзя: половина таких гексов — вода.
    var improvements_total := 0
    var improvements_with_road := 0
    for town in towns:
        var town_row := int(town.get("row", -1))
        var town_col := int(town.get("col", -1))
        for imp in _town_improvement_hexes(town, main_map.tile_data):
            improvements_total += 1
            var tile = main_map.tile_data[imp.row][imp.col]
            var expected: bool = not _is_water(tile) and _land_path_exists(
                    main_map.tile_data, main_map.map_rows, main_map.map_cols,
                    imp.row, imp.col, town_row, town_col)
            var actual: bool = rm.is_town_connected(town_row, town_col, imp.row, imp.col)
            if actual:
                improvements_with_road += 1
            check(actual == expected,
                    "улучшение (%d,%d) городка (%d,%d): дорога %s, а ожидалась %s (вода: %s)"
                            % [imp.row, imp.col, town_row, town_col,
                                "есть" if actual else "нет",
                                "есть" if expected else "нет",
                                "да" if _is_water(tile) else "нет"], state)
    check(improvements_total > 0,
            "на живой карте у городков должны быть улучшения", state)
    check(improvements_with_road > 0,
            "на живой карте хотя бы часть улучшений городков должна получить дорогу",
            state)

    # --- Гейт эпохи: в 1-й эпохе дороги городков не рисуются ---
    check(main_map.current_era < 1,
            "тест начинается в 1-й эпохе, а эпоха=%d" % main_map.current_era, state)
    check(not r.are_town_roads_visible(),
            "в 1-й эпохе дороги городков не должны быть видны", state)
    main_map.advance_to_next_era()
    await process_frame
    check(r.are_town_roads_visible(),
            "с эры Античности дороги городков должны быть видны", state)

    # --- Гейт тумана: проверяется ПРАВИЛО на всех сегментах сразу, а не
    # «хоть один туманный найдётся, хоть один видимый найдётся»: на случайной
    # карте любой из двух может не встретиться (городки стоят вне Региона), и
    # такая проверка была бы флакующей. ---
    var checked_segments := 0
    for seg in rm.get_all_town_road_segments().keys():
        var s := _parse_segment(seg)
        var expected: bool = not main_map.is_hex_in_fog(s[0], s[1]) \
                and not main_map.is_hex_in_fog(s[2], s[3])
        check(r.is_town_road_segment_visible(s[0], s[1], s[2], s[3]) == expected,
                "видимость сегмента дороги городка не совпала с правилом тумана: %s" % seg,
                state)
        checked_segments += 1
    check(checked_segments > 0,
            "на живой карте должны быть сегменты дорог городков", state)

    # Разведка открывает дорогу так же, как заливку кольца: изученный гекс
    # перестаёт быть туманом, и сегмент с ним становится видимым; гекс, вернувшийся
    # в туман, снова прячет дорогу.
    var fog_pair: Array = _fog_segment(main_map, rm)
    if not fog_pair.is_empty():
        var p := _parse_segment(fog_pair[0])
        check(not r.is_town_road_segment_visible(p[0], p[1], p[2], p[3]),
                "сегмент дороги городка с концом в тумане войны не должен рисоваться: %s"
                        % fog_pair[0], state)
        var t1 = main_map.tile_data[p[0]][p[1]]
        var t2 = main_map.tile_data[p[2]][p[3]]
        t1["is_explored"] = true
        t2["is_explored"] = true
        check(r.is_town_road_segment_visible(p[0], p[1], p[2], p[3]),
                "после разведки сегмент дороги городка должен стать видимым: %s"
                        % fog_pair[0], state)
        t1["is_explored"] = false
        t2["is_explored"] = false
        check(not r.is_town_road_segment_visible(p[0], p[1], p[2], p[3]),
                "вернувшийся в туман сегмент дороги городка снова скрывается: %s"
                        % fog_pair[0], state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()

# -------------------------------------------------------
# Хелперы разбора сегментов
# -------------------------------------------------------

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

func _has_segment_touching(segments: Dictionary, row: int, col: int) -> bool:
    return not _segments_touching(segments, row, col).is_empty()

# Есть ли в наборе сегментов цепочка от (from_row, from_col) до
# (to_row, to_col). Это проверка ФОРМЫ сети, а не только флага is_town_connected:
# BFS по сегментам в обе стороны (дорога двусторонняя).
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

# Свободный гекс-сосед города: без улучшений и вне колец городков. Нужен под
# улучшение ИГРОКА, чтобы проверка «городковые улучшения не попадают в сеть
# города» не накрывала гекс, который сам является улучшением городка.
func _free_hex_near_city(city_row: int, city_col: int, rows: int, cols: int,
        tile_data: Array) -> Dictionary:
    for n in _hex_utils.get_neighbors_odd_r(city_row, city_col, rows, cols):
        var tile = tile_data[n.row][n.col]
        if tile == null:
            continue
        if tile.get("improvement", null) != null:
            continue
        if bool(tile.get("in_town_influence", false)):
            continue
        return {"row": int(n.row), "col": int(n.col)}
    return {}

# Свободный гекс кольца городка на расстоянии не меньше min_dist от центра
# (на самом центре стоит сам городок, его улучшением он не считается).
# exclude — уже занятые гексы ["row,col", ...]: нужны, когда из кольца нужно
# взять несколько РАЗНЫХ гексов под разные улучшения.
func _free_ring_hex(town: Dictionary, tile_data: Array, min_dist: int,
        exclude: Array = []):
    for h in town.get("influence_hexes", []):
        var row := int(h.get("row", -1))
        var col := int(h.get("col", -1))
        if row < 0 or col < 0 or row >= tile_data.size() or col >= tile_data[row].size():
            continue
        if bool(tile_data[row][col].get("has_town", false)):
            continue
        if exclude.has("%d,%d" % [row, col]):
            continue
        if _hex_utils.hex_distance(row, col, int(town.get("row", -1)),
                int(town.get("col", -1))) < min_dist:
            continue
        return {"row": row, "col": col}
    return null

func _is_water(tile) -> bool:
    if tile == null:
        return false
    return str(tile.get("terrain", "")) in ["lake", "sea"]

# Есть ли путь ПО СУШЕ между двумя гексами (вода непроходима). Это независимая
# проверка правила «дорога строится всегда, когда физически можно дойти», а не
# обращение к road_manager: так тест не повторяет сам себя.
func _land_path_exists(tile_data: Array, rows: int, cols: int,
        from_row: int, from_col: int, to_row: int, to_col: int) -> bool:
    var visited := {"%d,%d" % [from_row, from_col]: true}
    var queue: Array = [{"row": from_row, "col": from_col}]
    while not queue.is_empty():
        var cur: Dictionary = queue.pop_front()
        if int(cur.row) == to_row and int(cur.col) == to_col:
            return true
        for n in _hex_utils.get_neighbors_odd_r(int(cur.row), int(cur.col), rows, cols):
            var key := "%d,%d" % [int(n.row), int(n.col)]
            if visited.has(key):
                continue
            visited[key] = true
            if _is_water(tile_data[n.row][n.col]):
                continue
            queue.append({"row": int(n.row), "col": int(n.col)})
    return false

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true

# Сегмент дороги городка, у которого хотя бы один конец в тумане войны.
func _fog_segment(main_map, rm) -> Array:
    for seg in rm.get_all_town_road_segments().keys():
        var s := _parse_segment(seg)
        if main_map.is_hex_in_fog(s[0], s[1]) or main_map.is_hex_in_fog(s[2], s[3]):
            return [seg]
    return []
