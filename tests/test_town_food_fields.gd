# Headless-тест: пищевые поля городков.
#   godot --headless --path . --script res://tests/test_town_food_fields.gd
#
# Предыстория. Городок, в кольце которого не оказалось пищевых ресурсов,
# получал 1-2 декоративные фермы — ГОЛЫЕ. Улучшение стоит, дорога к нему
# подведена, а выращивать нечего: ни ресурса на гексе, ни товара в пуле
# продажи. Игрок, разглядывающий территорию городка, справедливо
# спрашивает «как же они не голодают?».
#
# Теперь каждое поле засевается СВОЕЙ одомашненной пищевой культурой
# (crop_bred — ферма на пустом гексе это разведение, а не залежь), и все
# культуры попадают в пул продажи.
#
# Проверки (на синтетических картах):
#   1. Городок без пищевых ресурсов получает фермы с культурами из группы
#      food_plants; каждая разводима на своём гексе, качество проставлено, и
#      все культуры попадают в пул продажи (городок без ресурсов больше не
#      пуст).
#   2. Дикорсы (wild_food, группа "wild") пищевым растением НЕ считаются:
#      кольцо с одними дикорсами всё равно получает настоящие культуры, и
#      дикорсом культура городка быть не может.
#   3. Культура выбирается на КАЖДОЕ поле отдельно: два поля городка — это
#      два разных товара, а не однотипный клин.
#   4. Повторный проход (как при загрузке сейва) культуры НЕ меняет: ни одно
#      поле не пересеивается, пул продажи стабилен.
#   5. Городок, у которого в кольце УЖЕ есть пищевое растение, ничего не
#      меняет: своих ферм не получает, в пуле — его собственное растение.
#   6. Если мест для ферм нет (кольцо без свободных равнин) — городок остаётся
#      без еды, но ничего не ломается и культура не выдумывается.
#   7. Выбор случаен: у множества городков культуры различаются, а поля
#      одного городка почти всегда разные.
#   8. Живая карта (MainMap): ни одной голой фермы, пища у городков есть.
#   9. Старая партия: голые фермы дозасеваются, а не заменяются новыми.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Пищевое растение-эталон (группа food_plants) и дикорсы (группа wild).
const FOOD_PLANT := "wheat_field"
const WILD_FOOD := "wild_food"

var _tm = null
var _gdata = null
var _mh = null


func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()


func _run() -> void:
    var state = {"failed": false}

    # Автозагрузки берём через дерево сцены: в режиме --script имена
    # GameData/CityData недоступны на этапе компиляции этого файла.
    # new_game() заодно грузит все данные (ресурсы, улучшения, качества).
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    # Глобальные классы тоже берём через load(): в --script-режиме имя
    # MapHelpers не гарантировано на этапе компиляции теста.
    _mh = load("res://scripts/map_helpers.gd")

    _tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(_tm)

    _test_town_without_food_gets_field(state)
    _test_wild_food_is_not_a_field(state)
    _test_reload_keeps_the_same_crop(state)
    _test_crop_is_picked_per_field(state)
    _test_town_with_own_food_plant_unchanged(state)
    _test_town_without_plain_stays_foodless(state)
    _test_crops_vary_between_towns(state)
    _test_old_save_bare_farms_get_seeded(state)

    # Живая сцена — последней и отдельно: MainMap создаёт собственный
    # TownManager, держать рядом второй экземпляр незачем.
    get_root().remove_child(_tm)
    _tm.free()
    _tm = null

    await _test_live_scene(state)

    if state["failed"]:
        print("TOWN FOOD FIELDS TEST FAILED")
        quit(1)
    else:
        print("TOWN FOOD FIELDS TEST OK")
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


# Ставит городок и сразу строит его кольцо влияния — ровно так, как это делает
# игра: compute_all_town_influences -> _place_decorative_town_improvements.
func _add_town(tile_data: Array, rows: int, cols: int, row: int, col: int) -> Dictionary:
    var town: Dictionary = _tm._make_town_record(_tm.towns.size(), row, col, false)
    tile_data[row][col]["has_town"] = true
    _tm.towns.append(town)
    town["influence_hexes"] = _tm.compute_town_influence(tile_data, rows, cols, row, col, town)
    return town


# Каждый сценарий работает на своей карте и своём городке, поэтому менеджер
# перед ним пуст: иначе кольца и поля предыдущего сценария попали бы в
# выборку (городки во всех тестах ставятся в одну и ту же точку карты).
func _reset_towns() -> void:
    _tm.towns.clear()
    _tm.town_hexes = []
    _tm.town_influence_hexes = []
    _tm.set_player_start_area(-1, -1, -1, -1)


# Все гексы кольца городка (кандидаты декоративной расстановки).
func _ring_tiles(tile_data: Array, town: Dictionary) -> Array:
    var result := []
    for h in town.get("influence_hexes", []):
        var r := int(h.get("row", -1))
        var c := int(h.get("col", -1))
        if r < 0 or r >= tile_data.size() or c < 0 or c >= tile_data[r].size():
            continue
        if bool(tile_data[r][c].get("has_town", false)):
            continue
        result.append(tile_data[r][c])
    return result


# Декоративные фермы кольца, засеенные пищевой культурой.
func _cropped_farms(tile_data: Array, town: Dictionary) -> Array:
    var result := []
    for tile in _ring_tiles(tile_data, town):
        if str(tile.get("improvement", "")) != "farm":
            continue
        var crop = tile.get("crop_bred", null)
        if crop != null and crop != "":
            result.append(tile)
    return result


func _res_group(res_id) -> String:
    var data: Dictionary = _gdata.raw_resources.get(str(res_id), {})
    return str(data.get("group", ""))


# -------------------------------------------------------
# 1. Городок без пищевых ресурсов получает поля с культурой
# -------------------------------------------------------

func _test_town_without_food_gets_field(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    var town := _add_town(tile_data, rows, cols, 10, 10)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    var farms := _cropped_farms(tile_data, town)
    check(not farms.is_empty(),
        "городок без пищевых ресурсов должен получить засеянные фермы, а не голые постройки", state)
    if farms.is_empty():
        return
    for tile in farms:
        var crop := str(tile.get("crop_bred"))
        check(_res_group(crop) == "food_plants",
            "культура городка должна быть пищевым растением (group food_plants), а не «%s» (group «%s»)"
                % [crop, _res_group(crop)], state)
        check(crop != WILD_FOOD,
            "дикорсы нельзя выращивать на ферме городка, но полю достался «%s»" % crop, state)
        check(_mh.can_breed_resource_on_tile(crop, tile),
            "культуру «%s» нельзя развести на её же гексе — правила фермы игрока и городка разошлись" % crop, state)
        check(str(tile.get("quality", "")) != "",
            "у засеянного поля должно быть качество (как у разведения игрока), а не пустая строка", state)
        check(bool(tile.get("decorative", false)),
            "поле городка остаётся декоративным: оно не должно давать игроку производство или рабочих", state)

    # Пул продажи: культура обязана попасть в продажу, иначе игрок по-прежнему
    # видит пустое окно городка.
    var pool: Array = town.get("sell_pool", [])
    var crop_ids := []
    for tile in farms:
        if not pool.has(str(tile.get("crop_bred"))):
            crop_ids.append(str(tile.get("crop_bred")))
    check(crop_ids.is_empty(),
        "культура поля должна попасть в пул продажи городка (не попали: %s, пул: %s)" % [str(crop_ids), str(pool)], state)


# -------------------------------------------------------
# 2. Дикорсы пищевым растением не считаются
# -------------------------------------------------------

func _test_wild_food_is_not_a_field(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    # Один гекс кольца — дикорсы. Они собираются спец-действием, улучшения не
    # требуют и фермой не становятся: «городок на дикорсах» ровно то, от чего
    # мы уходим.
    tile_data[10][12]["resource"] = WILD_FOOD
    var town := _add_town(tile_data, rows, cols, 10, 10)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    var farms := _cropped_farms(tile_data, town)
    check(not farms.is_empty(),
        "дикорсы в кольце не должны отменять пищевое поле: городок всё равно должен чем-то кормиться", state)
    for tile in farms:
        check(str(tile.get("crop_bred")) != WILD_FOOD,
            "дикорсы нельзя разводить на ферме (wild_food не проходит can_breed_resource_on_tile)", state)
    check(town.get("sell_pool", []).size() > 1,
        "в пуле продажи должны быть и дикорсы гекса, и культура поля (пул: %s)" % str(town.get("sell_pool", [])), state)


# -------------------------------------------------------
# 4. Повторный проход (загрузка сейва) культуры не меняют
# -------------------------------------------------------

func _test_reload_keeps_the_same_crop(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    var town := _add_town(tile_data, rows, cols, 10, 10)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)
    var first := _cropped_farms(tile_data, town)
    if first.is_empty():
        check(false, "первый проход должен был засеять поля городка", state)
        return
    # Порядок обхода кольца стабилен, поэтому наборы сравниваем поэлементно.
    var before: Array = []
    for tile in first:
        before.append(str(tile.get("crop_bred")))
    var first_pool: Array = (town.get("sell_pool", []) as Array).duplicate()

    # Именно так выглядит загрузка партии: кольца и улучшения восстановлены из
    # сейва, декоративная расстановка вызвана ещё раз.
    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    var after: Array = []
    for tile in _cropped_farms(tile_data, town):
        after.append(str(tile.get("crop_bred")))
    check(after == before,
        "повторный проход не должен ни пересеивать поля, ни ДОБАВЛЯТЬ новых (было %d полей %s, стало %d полей %s)"
            % [before.size(), str(before), after.size(), str(after)], state)
    check((town.get("sell_pool", []) as Array) == first_pool,
        "пул продажи после повторного прохода должен совпадать с прежним (был %s, стал %s)"
            % [str(first_pool), str(town.get("sell_pool", []))], state)


# -------------------------------------------------------
# 5. Культура выбирается на КАЖДОЕ поле отдельно
# -------------------------------------------------------

# Два поля подряд с разными культурами читаются как хозяйство, а не как
# однотипный клин, и дают городку два товара вместо одного. Проверяем сам
# выбор (надёжно: 30 бросков в один вид из ~20 — вероятность порядка 20^-30)
# и то, что обе культуры городка попадают в продажу.
func _test_crop_is_picked_per_field(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    var town := _add_town(tile_data, rows, cols, 10, 10)

    # Выбор сам по себе: много бросков — много разных культур.
    var picks := {}
    for i in range(30):
        picks[_tm._pick_town_field_crop(tile_data[10][11])] = true
    check(picks.size() > 1,
        "культура должна выбираться случайно для каждого поля, а не быть константой (30 бросков дали %d разных: %s)"
            % [picks.size(), str(picks.keys())], state)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)
    var farms := _cropped_farms(tile_data, town)
    check(farms.size() == 2,
        "на равнинной карте городок должен получить два поля (получено %d)" % farms.size(), state)
    if farms.size() != 2:
        return
    var pool: Array = town.get("sell_pool", [])
    for tile in farms:
        var crop := str(tile.get("crop_bred"))
        check(pool.has(crop),
            "культура «%s» должна попасть в пул продажи (пул: %s)" % [crop, str(pool)], state)


# -------------------------------------------------------
# 6. Городок со своим пищевым растением не меняется
# -------------------------------------------------------

func _test_town_with_own_food_plant_unchanged(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    tile_data[10][12]["resource"] = FOOD_PLANT
    var town := _add_town(tile_data, rows, cols, 10, 10)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    # Своих ферм он не получает (они и раньше не ставились) — поле не нужно,
    # еда уже есть.
    check(_cropped_farms(tile_data, town).is_empty(),
        "городок с пищевым растением в кольце не должен получать засеянных полей", state)
    check(town.get("sell_pool", []).has(FOOD_PLANT),
        "пищевое растение кольца должно продаваться (пул: %s)" % str(town.get("sell_pool", [])), state)
    # Соседние свободные равнины остались свободными: культура не выдумывается
    # там, где игрок может построить своё.
    var untouched_plains := 0
    for tile in _ring_tiles(tile_data, town):
        if tile.get("improvement", null) == null and str(tile.get("terrain", "")) == "plain":
            untouched_plains += 1
    check(untouched_plains > 0,
        "лишние фермы в кольце с пищевым растением ставить не нужно", state)


# -------------------------------------------------------
# 6. Нет мест под ферму — городок остаётся без еды, но не ломается
# -------------------------------------------------------

func _test_town_without_plain_stays_foodless(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    # Кольцо без свободных равнин: всё — холмы. Ферму ставить некуда, значит и
    # культуру выдумывать нельзя.
    var town := _add_town(tile_data, rows, cols, 10, 10)
    for tile in _ring_tiles(tile_data, town):
        tile["terrain"] = "hill"

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    check(_cropped_farms(tile_data, town).is_empty(),
        "без мест под ферму городок не должен получать полей", state)
    var pool: Array = town.get("sell_pool", [])
    var invented: Array = []
    for res_id in pool:
        if _res_group(res_id) == "food_plants":
            invented.append(res_id)
    check(invented.is_empty(),
        "пул продажи не должен пополняться выдуманной пищей (найдено: %s)" % str(invented), state)


# -------------------------------------------------------
# 7. Выбор случаен, поля одного городка разные
# -------------------------------------------------------

func _test_crops_vary_between_towns(state: Dictionary) -> void:
    # Много городков на одной карте (кольца не пересекаются) — смотрим, что
    # культура действительно выбирается случайно, а не зашита константой, и
    # что два поля одного городка получают РАЗНЫЕ культуры.
    # Шаг между городками (9-10 гексов) заведомо больше двух радиусов кольца,
    # поэтому ни одно поле не достаётся сразу двум городкам.
    _reset_towns()
    var rows := 100
    var cols := 100
    var tile_data := _make_map(rows, cols)
    var centers := []
    for i in range(40):
        var row := 5 + (i / 8) * 10
        var col := 5 + (i % 8) * 9
        centers.append(_add_town(tile_data, rows, cols, row, col))

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    var seen := {}
    var foodless := 0
    var two_field_towns := 0
    var differing_pairs := 0
    for town in centers:
        var farms := _cropped_farms(tile_data, town)
        if farms.is_empty():
            foodless += 1
            continue
        seen[str(farms[0].get("crop_bred"))] = true
        if farms.size() == 2:
            two_field_towns += 1
            if str(farms[0].get("crop_bred")) != str(farms[1].get("crop_bred")):
                differing_pairs += 1
    check(seen.size() > 1,
        "культуры городков должны различаться (получено %d разных на 40 городков: %s) — иначе вся карта урожай одной культуры"
            % [seen.size(), str(seen.keys())], state)
    check(foodless == 0,
        "каждый городок на равнинной карте должен получить пищевое поле (без поля: %d)" % foodless, state)
    check(two_field_towns > 0,
        "в выборке должны быть городки с двумя полями (нашлось: %d)" % two_field_towns, state)
    # Совпадение двух полей — редкий случай (1 вид из ~20), поэтому требование
    # «почти всегда разные» устойчиво, в отличие от «всегда разные».
    check(differing_pairs >= 20,
        "поля одного городка должны нести разные культуры, а не одинаковый клин: разных пар %d из %d городков с двумя полями"
            % [differing_pairs, two_field_towns], state)


# -------------------------------------------------------
# 8. Живая сцена MainMap (новая игра)
# -------------------------------------------------------

# Главная проверка на настоящей карте: генератор выдаёт смешанную местность,
# и городки без пищевых ресурсов там гарантированно есть. Смотрим, что после
# реальной генерации не осталось НИ ОДНОЙ голой фермы и что городки, которым
# нечем было кормиться, что-то продают.
func _test_live_scene(state: Dictionary) -> void:
    get_root().get_node("SaveManager").new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var tile_data = main_map.tile_data

    # 1. Голая ферма — постройка без ресурса и без культуры. Это и есть та
    #    витрина, из-за которой игрок спрашивает «как они не голодают?».
    var bare_farms: Array = []
    var seeded_fields: Array = []
    for r in range(tile_data.size()):
        for c in range(tile_data[r].size()):
            var tile = tile_data[r][c]
            if tile == null or str(tile.get("improvement", "")) != "farm":
                continue
            if not bool(tile.get("decorative", false)):
                continue
            var has_resource = tile.get("resource", null) != null and tile.get("resource") != ""
            var crop = tile.get("crop_bred", null)
            if crop != null and crop != "":
                seeded_fields.append([r, c, str(crop)])
            elif not has_resource:
                bare_farms.append([r, c])
    check(bare_farms.is_empty(),
        "на живой карте не должно остаться декоративных ферм без ресурса и без культуры (гексы: %s)" % str(bare_farms), state)
    check(not seeded_fields.is_empty(),
        "на живой карте хотя бы часть городков должна получить засеянные пищевые поля", state)

    # 2. Все засеянные поля — пищевые растения, и все они продаются своим
    #    городком (и только им: городки не делят кольца).
    var crops_ok := true
    for f in seeded_fields:
        if _res_group(str(f[2])) != "food_plants" or str(f[2]) == WILD_FOOD:
            crops_ok = false
    check(crops_ok,
        "все поля городков засеяны пищевыми растениями, а не дикорсами", state)

    var sold_somewhere := 0
    for t in main_map.towns:
        var sells_food := false
        for res_id in t.get("sell_pool", []):
            if _res_group(res_id) == "food_plants":
                sells_food = true
        if sells_food:
            sold_somewhere += 1
    check(sold_somewhere > 0,
        "хотя бы один городок на живой карте должен продавать пищу (городков с едой: %d из %d)"
            % [sold_somewhere, main_map.towns.size()], state)

    # 3. Культура не должна попасть в пул продажи городка, чьего кольца она не
    #    касается, — и не должна «приклеиться» к игроку: на гексе с полем
    #    игрок не может ни строить, ни покупать чанк.
    var leaks: Array = []
    for t in main_map.towns:
        for h in t.get("influence_hexes", []):
            var r := int(h.get("row", -1))
            var c := int(h.get("col", -1))
            if r < 0 or r >= tile_data.size() or c < 0 or c >= tile_data[r].size():
                continue
            var tile = tile_data[r][c]
            if tile == null:
                continue
            if tile.get("improvement", null) == null and tile.get("resource", null) == null \
                    and tile.get("crop_bred", null) == null:
                continue
            if not bool(tile.get("in_town_influence", false)):
                leaks.append([int(t.row), int(t.col), r, c])
    check(leaks.is_empty(),
        "улучшения и поля городков должны лежать только в его собственном кольце (нарушителей: %s)" % str(leaks), state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()


# -------------------------------------------------------
# 9. Старая партия: голые фермы, оставшиеся от прежних версий
# -------------------------------------------------------

# Партия, сохранённая до появления пищевых полей, уже содержит фермы без
# культуры. Новый проход должен засеять ИХ, а не поставить ещё ферм рядом:
# иначе у городка навсегда осталась бы часть пустых «витрин».
func _test_old_save_bare_farms_get_seeded(state: Dictionary) -> void:
    _reset_towns()
    var rows := 21
    var cols := 21
    var tile_data := _make_map(rows, cols)
    var town := _add_town(tile_data, rows, cols, 10, 10)

    # Имитируем старую партию: все свободные равнины кольца заняты фермами
    # без ресурса и без культуры (именно так их расставляла прошлая версия).
    var legacy_farms: Array = []
    for tile in _ring_tiles(tile_data, town):
        if tile.get("improvement", null) == null and tile.get("resource", null) == null \
                and str(tile.get("terrain", "")) == "plain" and str(tile.get("cover", "none")) == "none":
            _tm._set_decorative_improvement(tile, "farm")
            legacy_farms.append(tile)
    check(not legacy_farms.is_empty(), "тест должен был подготовить голые фермы старой партии", state)

    _tm._place_decorative_town_improvements(tile_data, rows, cols)

    var unseeded: Array = []
    for tile in legacy_farms:
        var crop = tile.get("crop_bred", null)
        if crop == null or crop == "":
            unseeded.append([int(tile.get("terrain", ""))])
    check(unseeded.is_empty(),
        "голые фермы старой партии должны быть засеяны при следующем проходе (осталось: %d)" % unseeded.size(), state)

    var seeded := _cropped_farms(tile_data, town)
    check(not seeded.is_empty(),
        "городок старой партии должен получить пищевое поле", state)
    for tile in seeded:
        if not town.get("sell_pool", []).has(str(tile.get("crop_bred"))):
            check(false, "культура «%s» должна попасть в пул продажи (пул: %s)"
                % [str(tile.get("crop_bred")), str(town.get("sell_pool", []))], state)
            break


func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: " + msg)
        state["failed"] = true