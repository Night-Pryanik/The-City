# Headless-тест дебаг-переключателя «Игнорировать требования строительства»
# (CityData.ignore_build_requirements) на ВСЕХ действиях, тратящих время или
# ресурсы:
#   godot --headless --path . --script res://tests/test_ignore_build_requirements.gd
#
# Задача правки: флаг покрывал только здания города и улучшения на карте, а
# разведка, освоение территории и спецдействия (сбор дикоросов, осушение
# болот) жили по своим правилам. Теперь все они подчиняются переключателю.
#
# Проверки (живая сцена MainMap, новая игра, каждая — на своём гексе):
#   1. РАЗВЕДКА. Флаг выключен: экспедиция стартует, из казны списывается
#      ровно цена чанка. Флаг включён: чанк разведан В ТОМ ЖЕ вызове
#      (is_scouting == false, все гексы is_explored), казна не тронута.
#   2. ОСВОЕНИЕ. Флаг выключен: монеты списываются, стройка освоения попадает
#      в пул. Флаг включён: чанк присоединён к Кольцу Влияния сразу, казна
#      не тронута, активных строек освоения не осталось.
#   3. СБОР ДИКОРОСОВ (forage). Флаг выключен: действие встаёт в очередь
#      строек, ресурс остаётся на гексе. Флаг включён: ресурс собран и убран
#      с гекса в тот же вызов, продукция приходит на склад.
#   4. ОСУШЕНИЕ БОЛОТ (terrain). Флаг выключен: местность не меняется до
#      завершения стройки. Флаг включён: болото становится равниной сразу.
#   5. ГЕЙТ ЛИМИТА СТРОЕК. При исчерпанном лимите кнопка спецдействия
#      заблокирована; с включённым флагом — активна, потому что мгновенное
#      действие в очередь не встаёт.
#   6. СТРОЙКА, НАЧАТАЯ ДО ФЛАГА. Включение флага не оставляет уже начатые
#      стройки висеть до конца: _process доводит их до 100%, включая освоение
#      территории (раньше именно оно было исключением).
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как
# вечное молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const FORAGE_ACTION := "forage_resource"
const DRAIN_ACTION := "drain_water"
const BUILD_LIMIT_TOOLTIP := "Нет труда: лимит строек (число жителей) исчерпан"
const WILD_FOOD := "wild_food"
const FORAGED_FOOD := "foraged_food"

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Автолоады берём узлами дерева сцены: в режиме --script имена GameData и
    # CityData на этапе компиляции этого файла ещё недоступны.
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var city = get_root().get_node("CityData")
    var gdata = get_root().get_node("GameData")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    var em = main_map.expansion_manager
    var bm = main_map.build_manager
    var cp = main_map.control_panel

    check(main_map.tile_data.size() == main_map.map_rows,
            "карта не инициализирована (tile_data пуст)", state)
    check(not city.ignore_build_requirements,
            "переключатель по умолчанию должен быть выключен", state)

    _test_scouting(main_map, em, city, state)
    _test_expansion(main_map, em, bm, city, state)
    _test_forage(main_map, bm, city, state)
    _test_drain(main_map, bm, city, state)
    _test_build_limit_gate(main_map, bm, cp, city, gdata, state)
    _test_inflight_expansion(main_map, em, bm, city, state)

    _finish(main_map, state)

# --- 1. Разведка ---------------------------------------------------------

func _test_scouting(main_map, em, city, state: Dictionary) -> void:
    print("--- Разведка ---")
    city.ignore_build_requirements = false

    var hex = _find_region_hex_near_known(main_map)
    check(hex != null, "не найден неисследованный гекс Региона у границы Кольца", state)
    if hex == null:
        return
    var chunk: Array = em.get_chunk_hexes(hex.row, hex.col)
    check(chunk.size() > 0, "чанк разведки у границы Кольца не должен быть пустым", state)

    # Флаг ВЫКЛЮЧЕН: обычное поведение — деньги тратятся, экспедиция идёт.
    var cost: int = em.get_chunk_scout_cost(chunk)
    city.add_treasury(cost)
    var before: int = city.treasury
    main_map.start_scouting(chunk)
    check(main_map.is_scouting, "без флага разведка должна запускаться и идти по времени", state)
    check(city.treasury == before - cost,
            "без флага за разведку должно списываться ровно цена чанка (%d): было %d, стало %d"
                    % [cost, before, city.treasury], state)
    # Доводим экспедицию до конца вручную, чтобы готовить карту дальше.
    _force_finish_scouting(main_map, chunk)

    # Флаг ВКЛЮЧЁН: разведка мгновенная и бесплатная.
    city.ignore_build_requirements = true
    var hex2 = _find_region_hex_near_known(main_map)
    check(hex2 != null, "после первой разведки должен найтись следующий гекс Региона", state)
    if hex2 == null:
        return
    var chunk2: Array = em.get_chunk_hexes(hex2.row, hex2.col)
    check(chunk2.size() > 0, "чанк второй разведки не должен быть пустым", state)
    var before2: int = city.treasury
    main_map.start_scouting(chunk2)
    check(not main_map.is_scouting,
            "с флагом разведка не должна тянуться по времени (is_scouting)", state)
    check(main_map.scouting_chunk.is_empty(),
            "с флагом разведка должна закрыть чанк в том же вызове", state)
    check(_chunk_all_explored(main_map, chunk2),
            "с флагом все гексы чанка обязаны стать разведанными сразу", state)
    check(city.treasury == before2,
            "с флагом разведка должна быть бесплатной: было %d, стало %d"
                    % [before2, city.treasury], state)
    city.ignore_build_requirements = false

# --- 2. Освоение территории ---------------------------------------------

func _test_expansion(main_map, em, bm, city, state: Dictionary) -> void:
    print("--- Освоение территории ---")
    city.ignore_build_requirements = false

    var chunk: Array = _open_buy_chunk(main_map, em)
    check(chunk.size() > 0, "для освоения не нашлось гекса с непустым чанком покупки", state)
    if chunk.is_empty():
        return
    var work_cost: int = em.get_chunk_cost(chunk)
    check(work_cost > 0, "труд освоения чанка должен быть больше нуля", state)
    var money_cost: int = em.get_chunk_money_cost(chunk)

    city.add_treasury(money_cost)
    var before: int = city.treasury
    var ok: bool = em.handle_action(chunk, money_cost, work_cost)
    check(ok, "без флага освоение должно запускаться", state)
    check(city.treasury == before - money_cost,
            "без флага за освоение должно списываться ровно %d монет: было %d, стало %d"
                    % [money_cost, before, city.treasury], state)
    check(bm.active_expansion_builds.size() == 1,
            "без флага освоение должно ждать труд в пуле строек", state)
    # Завершаем вручную тем же путём, что и при накоплении труда.
    em.on_expansion_build_completed(chunk)
    check(_chunk_all_in_influence(main_map, chunk),
            "освоение должно присоединить чанк к Кольцу Влияния", state)
    # Запись из active_expansion_builds убирает сам build_manager в своём
    # _process. Тест идёт без await между шагами, кадров не проходит, а
    # следующим проверкам лимит строек мешал бы остаток — чистим пул явно.
    _reset_build_pool(bm)

    # Флаг ВКЛЮЧЁН: освоение мгновенное и бесплатное.
    city.ignore_build_requirements = true
    var chunk2: Array = _open_buy_chunk(main_map, em)
    check(chunk2.size() > 0, "для второго освоения не нашлось гекса с чанком покупки", state)
    if chunk2.is_empty():
        return
    var before2: int = city.treasury
    var ok2: bool = em.handle_action(chunk2,
            em.get_chunk_money_cost(chunk2), em.get_chunk_cost(chunk2))
    check(ok2, "с флагом освоение должно запускаться", state)
    check(_chunk_all_in_influence(main_map, chunk2),
            "с флагом чанк должен присоединиться к Кольцу Влияния сразу", state)
    check(bm.active_expansion_builds.is_empty(),
            "с флагом освоение не должно оставаться в пуле строек", state)
    check(city.treasury == before2,
            "с флагом освоение должно быть бесплатным: было %d, стало %d"
                    % [before2, city.treasury], state)
    city.ignore_build_requirements = false

# --- 3. Сбор дикоросов (спецдействие forage) -----------------------------

func _test_forage(main_map, bm, city, state: Dictionary) -> void:
    print("--- Сбор дикоросов ---")
    city.ignore_build_requirements = false

    var hex = _find_empty_influence_hex(main_map)
    check(hex != null, "не найден пустой гекс Кольца Влияния под сбор дикоросов", state)
    if hex == null:
        return
    var tile = main_map.tile_data[hex.row][hex.col]
    tile["resource"] = WILD_FOOD
    tile["quality"] = "common"

    var started: bool = bm.start_build(hex.row, hex.col, FORAGE_ACTION)
    check(started, "без флага сбор дикоросов должен запускаться", state)
    check(bm.is_building(hex.row, hex.col),
            "без флага сбор дикоросов должен ждать труд в пуле строек", state)
    check(str(tile.get("resource", "")) == WILD_FOOD,
            "без флага ресурс не должен исчезать до завершения стройки", state)
    bm.cancel_build(hex.row, hex.col)
    tile["resource"] = WILD_FOOD

    city.ignore_build_requirements = true
    var hex2 = _find_empty_influence_hex(main_map)
    check(hex2 != null, "не найден второй пустой гекс Кольца Влияния", state)
    if hex2 == null:
        return
    var tile2 = main_map.tile_data[hex2.row][hex2.col]
    tile2["resource"] = WILD_FOOD
    tile2["quality"] = "common"
    var food_before: int = _storage_amount(city, FORAGED_FOOD)

    var started2: bool = bm.start_build(hex2.row, hex2.col, FORAGE_ACTION)
    check(started2, "с флагом сбор дикоросов должен запускаться", state)
    check(not bm.is_building(hex2.row, hex2.col),
            "с флагом сбор дикоросов не должен вставать в очередь строек", state)
    check(tile2.get("resource", null) == null,
            "с флагом одноразовый ресурс должен исчезнуть с гекса сразу", state)
    check(_storage_amount(city, FORAGED_FOOD) > food_before,
            "с флагом собранные дикоросы должны сразу попасть на склад (%d -> %d)"
                    % [food_before, _storage_amount(city, FORAGED_FOOD)], state)
    city.ignore_build_requirements = false

# --- 4. Осушение болот (спецдействие terrain) ----------------------------

func _test_drain(main_map, bm, city, state: Dictionary) -> void:
    print("--- Осушение болот ---")
    city.ignore_build_requirements = false

    var hex = _find_empty_influence_hex(main_map)
    check(hex != null, "не найден пустой гекс Кольца Влияния под осушение", state)
    if hex == null:
        return
    var tile = main_map.tile_data[hex.row][hex.col]
    tile["terrain"] = "swamp"
    tile["cover"] = "none"
    tile["resource"] = null
    tile["improvement"] = null

    var started: bool = bm.start_build(hex.row, hex.col, DRAIN_ACTION)
    check(started, "без флага осушение должно запускаться", state)
    check(bm.is_building(hex.row, hex.col),
            "без флага осушение должно ждать труд в пуле строек", state)
    check(str(tile.get("terrain", "")) == "swamp",
            "без флага местность не должна меняться до завершения стройки", state)
    bm.cancel_build(hex.row, hex.col)

    city.ignore_build_requirements = true
    var hex2 = _find_empty_influence_hex(main_map)
    check(hex2 != null, "не найден второй пустой гекс Кольца Влияния", state)
    if hex2 == null:
        return
    var tile2 = main_map.tile_data[hex2.row][hex2.col]
    tile2["terrain"] = "swamp"
    tile2["cover"] = "none"
    tile2["resource"] = null
    tile2["improvement"] = null

    var started2: bool = bm.start_build(hex2.row, hex2.col, DRAIN_ACTION)
    check(started2, "с флагом осушение должно запускаться", state)
    check(not bm.is_building(hex2.row, hex2.col),
            "с флагом осушение не должно вставать в очередь строек", state)
    check(str(tile2.get("terrain", "")) == "plain",
            "с флагом болото должно стать равниной сразу (получено: «%s»)"
                    % str(tile2.get("terrain", "")), state)
    city.ignore_build_requirements = false

# --- 5. Гейт лимита одновременных строек ---------------------------------

func _test_build_limit_gate(main_map, bm, cp, city, gdata, state: Dictionary) -> void:
    print("--- Гейт лимита строек для спецдействий ---")
    var sa: Dictionary = gdata.special_actions.get(FORAGE_ACTION, {})
    check(not sa.is_empty(), "спецдействие «%s» должно быть в данных" % FORAGE_ACTION, state)
    if sa.is_empty():
        return

    var hex = _find_empty_influence_hex(main_map)
    check(hex != null, "не найден гекс для проверки гейта лимита", state)
    if hex == null:
        return
    var tile = main_map.tile_data[hex.row][hex.col]
    tile["resource"] = WILD_FOOD
    tile["quality"] = "common"

    # Занимаем слот строящегося действия: население = 1, значит лимит в одну
    # стройку. Стройка остаётся АКТИВНОЙ на время обеих проверок — гейт
    # срабатывает именно когда лимит исчерпан, а не когда стройка отменена.
    _reset_build_pool(bm)
    city.total_population = 1
    var queued: bool = bm.start_build(hex.row, hex.col, FORAGE_ACTION)
    check(queued, "для проверки гейта лимита стройка должна запуститься", state)
    check(bm.get_total_active_builds() >= city.total_population,
            "лимит строек должен быть исчерпан (в пуле %d, лимит %d)"
                    % [bm.get_total_active_builds(), city.total_population], state)

    city.ignore_build_requirements = false
    var actions_off := []
    cp._append_special_action(actions_off, FORAGE_ACTION, sa)
    var off_action = _find_action(actions_off, FORAGE_ACTION)
    check(off_action != null, "без флага кнопка спецдействия должна собираться", state)
    if off_action != null:
        check(not off_action.get("enabled", true),
                "без флага исчерпанный лимит строек должен блокировать спецдействие", state)
        check(str(off_action.get("tooltip", "")) == BUILD_LIMIT_TOOLTIP,
                "тултип должен объяснять блокировку лимитом (получено: «%s»)"
                        % str(off_action.get("tooltip", "")), state)

    city.ignore_build_requirements = true
    var actions_on := []
    cp._append_special_action(actions_on, FORAGE_ACTION, sa)
    var on_action = _find_action(actions_on, FORAGE_ACTION)
    check(on_action != null, "с флагом кнопка спецдействия должна собираться", state)
    if on_action != null:
        check(on_action.get("enabled", false),
                "с флагом лимит строек не должен блокировать мгновенное спецдействие", state)
        check(str(on_action.get("tooltip", "")) != BUILD_LIMIT_TOOLTIP,
                "с флагом тултип о лимите строек показываться не должен", state)

    city.ignore_build_requirements = false
    city.total_population = 1
    tile["resource"] = null
    _reset_build_pool(bm)

# --- 6. Стройка, начатая до включения флага ------------------------------

func _test_inflight_expansion(main_map, em, bm, city, state: Dictionary) -> void:
    print("--- Стройка, начатая до включения флага ---")
    city.ignore_build_requirements = false

    var chunk: Array = _open_buy_chunk(main_map, em)
    check(chunk.size() > 0, "для проверки не нашлось гекса с чанком покупки", state)
    if chunk.is_empty():
        return
    var work_cost: int = em.get_chunk_cost(chunk)
    check(work_cost > 0, "труд освоения должен быть больше нуля", state)
    city.add_treasury(em.get_chunk_money_cost(chunk))
    var ok: bool = em.handle_action(chunk, em.get_chunk_money_cost(chunk), work_cost)
    check(ok, "освоение должно запуститься до включения флага", state)
    check(bm.active_expansion_builds.size() == 1,
            "освоение должно ждать в пуле строек", state)
    check(not _chunk_all_in_influence(main_map, chunk),
            "до включения флага чанк не должен быть освоен", state)

    # Включаем флаг на ходу: начатая стройка обязана завершиться в том же
    # кадре — раньше освоение было единственным исключением.
    city.ignore_build_requirements = true
    bm._process(0.05)
    check(bm.active_expansion_builds.is_empty(),
            "с флагом уже начатое освоение должно завершиться сразу", state)
    check(_chunk_all_in_influence(main_map, chunk),
            "с флагом уже начатое освоение должно присоединить чанк", state)
    city.ignore_build_requirements = false

# --- Хелперы ------------------------------------------------------------

# Первый неисследованный гекс Региона, у которого есть известный сосед.
func _find_region_hex_near_known(main_map):
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if not main_map.is_valid_hex(row, col):
                continue
            var tile = main_map.tile_data[row][col]
            if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
                continue
            for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
                if main_map.is_hex_known(n.row, n.col):
                    return {"row": row, "col": col}
    return null

# Первый гекс Кольца Влияния, на котором ещё ничего не стоит и ничего не
# растёт: подходит и под сбор дикоросов, и под осушение.
func _find_empty_influence_hex(main_map):
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if not main_map.is_valid_hex(row, col):
                continue
            if row == main_map.city_row and col == main_map.city_col:
                continue
            var tile = main_map.tile_data[row][col]
            if not bool(tile.get("in_influence", false)):
                continue
            if bool(tile.get("has_town", false)) or bool(tile.get("decorative", false)):
                continue
            if bool(tile.get("in_town_influence", false)):
                continue
            if tile.get("resource", null) != null or tile.get("improvement", null) != null:
                continue
            return {"row": row, "col": col}
    return null

func _chunk_all_explored(main_map, chunk: Array) -> bool:
    for hex in chunk:
        if not bool(main_map.tile_data[hex.row][hex.col].get("is_explored", false)):
            return false
    return true

func _chunk_all_in_influence(main_map, chunk: Array) -> bool:
    for hex in chunk:
        if not bool(main_map.tile_data[hex.row][hex.col].get("in_influence", false)):
            return false
    return true

func _mark_explored(main_map, chunk: Array) -> void:
    for hex in chunk:
        main_map.tile_data[hex.row][hex.col]["is_explored"] = true

# Полностью очищает пул строек. Нужно между проверками: тест идёт без await,
# поэтому build_manager._process (он и снимает завершённые записи) не успевает
# отработать, и остаток стройки сдвинул бы лимит в следующей проверке.
func _reset_build_pool(bm) -> void:
    bm.active_builds.clear()
    bm.active_building_builds.clear()
    bm.active_expansion_builds.clear()
    bm._recount_active_builds()

# Открывает гекс и его чанк разведки, после чего возвращает ЧАНК ПОКУПКИ.
# Порядок важен: get_chunk_hexes для неисследованного гекса строит BFS
# разведки (в него попадает и кольцо влияния городка, и уже освоенные гексы),
# а для разведанного — BFS покупки. handle_action отказывает на чанке, который
# пересекает кольцо городка, поэтому пересобирать чанк после разведки
# обязательно — ровно это делает панель управления в игре.
func _open_and_get_buy_chunk(main_map, em, row: int, col: int) -> Array:
    var scout_chunk: Array = em.get_chunk_hexes(row, col)
    _mark_explored(main_map, scout_chunk)
    return em.get_chunk_hexes(row, col)

# Находит НЕПУСТОЙ чанк покупки: перебирает гексы Региона у известной
# территории и берёт первый, чей чанк действительно собирается. Один
# `_find_region_hex_near_known` для этой цели недостаточно — гекс у границы
# Кольца может оказаться в кольце влияния городка, и тогда BFS покупки пуст.
# Кандидаты, чей чанк не собрался, просто остаются разведанными: карта от
# этого не ломается, следующая проверка ищет свой чанк сама.
func _open_buy_chunk(main_map, em) -> Array:
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if not main_map.is_valid_hex(row, col):
                continue
            var tile = main_map.tile_data[row][col]
            if bool(tile.get("in_influence", false)) or bool(tile.get("is_explored", false)):
                continue
            if bool(tile.get("in_town_influence", false)):
                continue
            if not _hex_has_influence_neighbor(main_map, row, col):
                continue
            var chunk: Array = _open_and_get_buy_chunk(main_map, em, row, col)
            if not chunk.is_empty() and em.get_chunk_cost(chunk) > 0:
                return chunk
    return []

# Есть ли у гекса сосед в Кольце Влияния — условие покупки чанка (см.
# control_panel._collect_region_actions, has_neighbor).
func _hex_has_influence_neighbor(main_map, row: int, col: int) -> bool:
    for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
        if bool(main_map.tile_data[n.row][n.col].get("in_influence", false)):
            return true
    return false

# Доводит разведку до конца вручную: в headless-тесте ждать реальные секунды
# игрового времени нельзя.
func _force_finish_scouting(main_map, chunk: Array) -> void:
    main_map.scouting_chunk = chunk
    main_map._complete_scouting()

func _storage_amount(city, product_id: String) -> int:
    return int(city.city_storage.get(product_id, 0))

func _find_action(actions: Array, action_id: String):
    for action in actions:
        if action.get("action_id", "") == action_id:
            return action
    return null

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("IGNORE BUILD REQUIREMENTS TEST FAILED")
        quit(1)
    else:
        print("IGNORE BUILD REQUIREMENTS TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
