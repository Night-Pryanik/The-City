# Headless-тест дороги, которая строится ВМЕСТЕ с улучшением.
#   godot --headless --path . --script res://tests/test_improvement_road.gd
#
# Проверки (живая сцена MainMap):
#   1. ЦЕПОЧКА. Подтверждение постройки улучшения запускает ОДИН поэтапный
#      проект и занимает ОДИН слот: сначала идут участки дороги, последним
#      шагом — сама постройка улучшения.
#   2. ПОЭТАПНОСТЬ И ЦЕНА. Участки дороги и улучшение оплачиваются каждый
#      отдельно, цена дороги не входит в цену улучшения (иначе труд списывался
#      бы дважды). Базовый уровень 1 (тропка) тоже платный.
#   3. ОДИН СЛОТ. Улучшение с дорогой помещается в лимит в одну постройку, и
#      гекс с идущей цепочкой нельзя занять второй постройкой.
#   4. ПРЕВЬЮ. Показывает и цену улучшения, и цену дороги (с её уровнем и
#      числом новых участков), и итог.
#   5. СЕЙВ. Пересчёт дорог по факту улучшения (rebuild_roads_from_existing)
#      пропускает гексы с road_staged — иначе недостроенную или отменённую
#      дорогу он достроил бы бесплатно.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как
# вечное молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Уровень дороги для всех проверок: базовая тропка. Именно она раньше была
# бесплатной, поэтому проверять надо на ней — платный уровень 2 и так
# тарифицируется, и на нём ошибка не проявилась бы.
const TRAIL_LEVEL := 1

var _cdata = null
var _gdata = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # Автолоады берём узлами дерева сцены: в режиме --script имена GameData и
    # CityData на этапе компиляции этого файла ещё недоступны. new_game()
    # заодно грузит все данные, включая roads.json.
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    _test_chain(main_map, state)
    _test_single_slot(main_map, state)
    _test_instant_debug_flag(main_map, state)
    _test_preview(main_map, state)
    _test_save_restore(main_map, state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()

    if state["failed"]:
        print("IMPROVEMENT ROAD TEST FAILED")
        quit(1)
    else:
        print("IMPROVEMENT ROAD TEST OK")
        quit(0)
# -------------------------------------------------------
# 1, 2. Цепочка «дорога → улучшение»: порядок, поэтапность, раздельные цены
# -------------------------------------------------------

func _test_chain(main_map, state: Dictionary) -> void:
    var bm = main_map.build_manager
    var pm = main_map.project_manager
    var rm = main_map.road_manager
    # Запас слотов не нужен: вся цепочка занимает ровно один слот, поэтому
    # проверка идёт при лимите в один житель, как в новой партии.
    var spot := _find_hex_with_road_plan(main_map)
    check(not spot.is_empty(),
            "для проверки нужен гекс в влиянии, до которого тянется трасса", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var imp_id := _pick_improvement()
    check(not imp_id.is_empty(), "в данных должно быть улучшение без no_road", state)
    if imp_id.is_empty():
        return

    var plan: Dictionary = main_map.get_road_plan(row, col)
    var plan_segments := int(plan.get("segments", 0))
    var road_cost := int(main_map.get_road_cost_breakdown(
            row, col, TRAIL_LEVEL).get("cost", 0))

    # Тропка не бесплатна: раньше дорога к улучшению не тарифицировалась вовсе,
    # и постройка улучшения на дальнем гексе была «бесплатной с дорогой».
    check(road_cost > 0,
            "дорога к улучшению должна стоить труда даже на базовом уровне", state)
    check(main_map.get_road_cost_for_improvement(row, col, TRAIL_LEVEL) == road_cost,
            "цена дороги к улучшению должна совпадать с превью дороги", state)

    # Цена улучшения и цена дороги — разные числа.
    var cost_data: Dictionary = main_map.get_improvement_work_cost(
            imp_id, row, col, TRAIL_LEVEL)
    var imp_cost := int(cost_data.get("cost", 0))
    var cost_road := int(cost_data.get("road_cost", 0))
    var total := int(cost_data.get("total_cost", 0))
    check(imp_cost > 0, "у улучшения должна быть своя цена", state)
    check(cost_road == road_cost,
            "road_cost улучшения должен совпадать с ценой дороги", state)
    check(total == imp_cost + cost_road,
            "итог должен быть суммой улучшения и дороги", state)
    check(int(cost_data.get("road_segments", 0)) == plan_segments,
            "улучшение должно знать, сколько участков добавит дорога", state)

    # Одно подтверждение — одна цепочка и РОВНО один слот. Отдельной записи
    # стройки улучшения в build_manager быть не должно: улучшение стоит в
    # очереди проекта последним шагом, а не идёт параллельно дороге.
    check(bm.start_build(row, col, imp_id, null, TRAIL_LEVEL),
            "стройку улучшения должно быть можно запустить", state)
    check(not bm.is_building(row, col),
            "улучшение не должно быть отдельной стройкой — оно в очереди проекта",
            state)
    var project: Dictionary = pm.get_project_at(row, col)
    check(not project.is_empty(),
            "дорога к улучшению должна идти поэтапным проектом", state)
    var steps: Array = project.get("steps", [])
    check(steps.size() == plan_segments + 1,
            "в очереди должно быть участков дороги ПЛЮС шаг улучшения: %d и %d"
                    % [steps.size(), plan_segments + 1], state)
    check(bm.get_total_active_builds() == 1,
            "цепочка должна занимать ровно один слот (получено: %d)"
                    % bm.get_total_active_builds(), state)

    # Последний шаг — улучшение, и его цена равна цене улучшения из превью.
    var last_step: Dictionary = steps[steps.size() - 1]
    var last_data: Dictionary = last_step.get("data", {})
    check(str(last_data.get("step_type", "")) == "improvement",
            "последним шагом цепочки должен идти улучшение", state)
    check(str(last_data.get("improvement", "")) == imp_id,
            "шаг улучшения должен нести id улучшения", state)
    check(int(last_step.get("work_cost", 0)) == imp_cost,
            "шаг улучшения должен стоить ровно цену улучшения: %d и %d"
                    % [int(last_step.get("work_cost", 0)), imp_cost], state)
    var step_sum := 0
    for step in steps:
        step_sum += int(step.get("work_cost", 0))
    check(step_sum == total,
            "сумма шагов цепочки должна совпадать с итогом превью: %d и %d"
                    % [step_sum, total], state)

    # Гекс ещё без дороги и без улучшения: дорога впереди, по участкам.
    check(not rm.is_hex_connected(row, col),
            "гекс не должен получить дорогу мгновенно", state)
    check(main_map.tile_data[row][col].get("improvement", null) == null,
            "улучшение не должно появиться раньше дороги", state)
    check(bool(main_map.tile_data[row][col].get("road_staged", false)),
            "на гексе должен стоять флаг road_staged (входные данные для сейва)", state)

    # Один кадр труда — ровно один участок дороги, и улучшение ещё не начато:
    # дорога и постройка идут ПОСЛЕДОВАТЕЛЬНО. Ставку берём ту же, что раздаёт
    # build_manager: доля одного из всех активных строек, а не весь труд города.
    var step_cost := float(steps[0].get("work_cost", 1.0))
    var labor: float = maxf(0.001, _cdata.get_total_labor())
    var labor_per_build: float = labor / maxf(1.0, float(bm.get_total_active_builds()))
    bm._process(step_cost * 1.5 / labor_per_build)
    check(rm.get_all_road_segments().size() == 1,
            "за один кадр должен достроиться ровно один участок дороги", state)
    check(main_map.tile_data[row][col].get("improvement", null) == null,
            "пока дорога строится, улучшение не ставится", state)
    # Бар на гексе улучшения принадлежит участку дороги, а не постройке: пока
    # дорога впереди, текущий шаг — участок.
    check(str(pm.get_step_progress_at(row, col).get("step_type", "")) != "improvement",
            "на гексе улучшения бар должен принадлежать участку дороги", state)

    # Добиваем очередь: после последнего участка должен отработать шаг улучшения.
    # Ставку под текущий шаг, а не под первый участок: цена улучшения может быть
    # больше цены участка, и кадр, рассчитанный на участок, не закрыл бы шаг.
    var guard := 0
    while not pm.get_project_at(row, col).is_empty() and guard < 400:
        var cur: Dictionary = pm.get_project_at(row, col)
        var cur_steps: Array = cur.get("steps", [])
        var idx := int(cur.get("step_index", 0))
        var cur_cost := 1.0
        if idx >= 0 and idx < cur_steps.size():
            cur_cost = maxf(1.0, float((cur_steps[idx] as Dictionary).get("work_cost", 1.0)))
        bm._process(cur_cost * 2.0 / labor_per_build)
        guard += 1
    check(guard < 400, "очередь должна достраиваться за разумное число кадров", state)
    check(rm.is_hex_connected(row, col),
            "после достройки очереди гекс должен получить дорогу", state)
    check(str(main_map.tile_data[row][col].get("improvement", "")) == imp_id,
            "после дороги должно достроиться и улучшение", state)
    check(pm.get_project_at(row, col).is_empty(),
            "после улучшения очередь должна быть пуста", state)
    check(bool(main_map.tile_data[row][col].get("road_built", false)),
            "на целевом гексе должен стоять флаг road_built", state)

# -------------------------------------------------------
# 3. Цепочка помещается в один слот, а занятый гекс не переиспользуется
# -------------------------------------------------------

func _test_single_slot(main_map, state: Dictionary) -> void:
    var bm = main_map.build_manager
    var pm = main_map.project_manager
    var spot := _find_hex_with_road_plan(main_map)
    check(not spot.is_empty(), "для проверки лимита нужен гекс без дороги", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var imp_id := _pick_improvement()
    if imp_id.is_empty():
        return

    # Лимит в одну постройку — как в новой партии (один житель). Раньше цепочка
    # «улучшение + дорога» занимала ДВА слота и в такое ограничение не
    # помещалась: приходилось приоритет отдавать дороге и отказывать
    # улучшению. Теперь очередь одна, и одного слота хватает на всё.
    var previous_population := int(_cdata.total_population)
    _cdata.total_population = 1
    var started: bool = bm.start_build(row, col, imp_id, null, TRAIL_LEVEL)

    check(started, "улучшение с дорогой должно помещаться в один слот", state)
    check(bm.get_total_active_builds() == 1,
            "цепочка должна занять единственный слот (получено: %d)"
                    % bm.get_total_active_builds(), state)
    check(not pm.get_project_at(row, col).is_empty(),
            "на гексе должна идти цепочка дороги с улучшением", state)

    # Гекс, занятый цепочкой, нельзя занять повторно: улучшение в очереди не
    # лежит в active_builds, и без этой проверки на гексе стартовала бы вторая
    # постройка.
    check(not bm.start_build(row, col, imp_id, null, TRAIL_LEVEL),
            "на гексе с идущей цепочкой вторая постройка не должна запускаться", state)

    pm.cancel_project_at(row, col)
    _cdata.total_population = previous_population

# -------------------------------------------------------
# 4. Дебаг-флаг «мгновенно» разбирает всю цепочку целиком
# -------------------------------------------------------

func _test_instant_debug_flag(main_map, state: Dictionary) -> void:
    var bm = main_map.build_manager
    var rm = main_map.road_manager
    var spot := _find_hex_with_road_plan(main_map)
    check(not spot.is_empty(), "для проверки флага нужен гекс без дороги", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var imp_id := _pick_improvement()
    if imp_id.is_empty():
        return

    var previous := bool(_cdata.ignore_build_requirements)
    _cdata.ignore_build_requirements = true
    check(bm.start_build(row, col, imp_id, null, TRAIL_LEVEL),
            "с флагом цепочка должна запускаться", state)
    # Один кадр раздачи труда: receive_labor(instant) разбирает очередь целиком,
    # поэтому и дорога, и улучшение должны появиться сразу.
    bm._process(0.1)
    check(rm.is_hex_connected(row, col),
            "с флагом дорога должна быть проложена сразу", state)
    check(str(main_map.tile_data[row][col].get("improvement", "")) == imp_id,
            "с флагом улучшение должно быть построено сразу", state)
    _cdata.ignore_build_requirements = previous

# -------------------------------------------------------
# 5. Превью показывает обе цены
# -------------------------------------------------------

func _test_preview(main_map, state: Dictionary) -> void:
    var panel = main_map.control_panel
    var spot := _find_hex_with_road_plan(main_map)
    check(not spot.is_empty(), "для превью нужен гекс без дороги", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var imp_id := _pick_improvement()
    if imp_id.is_empty():
        return

    var cost_data: Dictionary = main_map.get_improvement_work_cost(
            imp_id, row, col, TRAIL_LEVEL)
    var imp_cost := int(cost_data.get("cost", 0))
    var road_cost := int(cost_data.get("road_cost", 0))
    var total := int(cost_data.get("total_cost", 0))
    var segments := int(cost_data.get("road_segments", 0))
    check(road_cost > 0 and segments > 0,
            "превью должно считать дорогу к улучшению", state)
    if road_cost <= 0:
        return

    panel.select_hex(row, col)
    panel._preview_action = {
        "type": "build_improvement", "imp_id": imp_id, "action_id": "",
        "target_res_id": null, "label": imp_id, "eff_res": "",
        "selected_culture_id": null, "road_level": TRAIL_LEVEL,
    }
    panel._refresh()
    var text: String = _collect_text(panel._preview_container)
    check(text.contains(str(imp_cost)),
            "в превью должна быть цена улучшения (%d)" % imp_cost, state)
    check(text.contains(str(road_cost)),
            "в превью должна быть цена дороги (%d)" % road_cost, state)
    check(text.contains(str(total)),
            "в превью должен быть итог цены улучшения и дороги (%d)" % total, state)
    check(text.contains(str(segments)),
            "в превью должно быть число новых участков дороги (%d)" % segments, state)
    # Название уровня приходит из данных и переводится, поэтому ищется в любом
    # языке: строка дороги обязана называть уровень, по которому посчитана.
    check(text.contains(str(_gdata.get_road_name(TRAIL_LEVEL))),
            "строка дороги должна называть выбранный уровень дороги", state)
    panel.clear_preview()

# -------------------------------------------------------
# 5. Восстановление: гекс с road_staged не достраивается бесплатно
# -------------------------------------------------------

func _test_save_restore(main_map, state: Dictionary) -> void:
    var rm = main_map.road_manager
    var spot := _find_hex_with_road_plan(main_map)
    check(not spot.is_empty(), "для проверки сейва нужен гекс без дороги", state)
    if spot.is_empty():
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    check(not rm.is_hex_connected(row, col),
            "исходный гекс должен быть без дороги", state)

    tile["improvement"] = "farm"
    tile["road_staged"] = true
    check(bool(main_map._skip_improvement_road_restore(row, col)),
            "гекс с road_staged обязан пропускаться при пересчёте сети", state)
    rm.rebuild_roads_from_existing(main_map.tile_data, main_map.map_rows,
            main_map.map_cols, Callable(main_map, "_skip_improvement_road_restore"))
    check(not rm.is_hex_connected(row, col),
            "пересчёт не должен достраивать поэтапную дорогу бесплатно", state)

    # Старый сейв: флага нет — дорога восстанавливается, как раньше.
    tile["road_staged"] = false
    check(not bool(main_map._skip_improvement_road_restore(row, col)),
            "гекс без road_staged пересчитывается как раньше", state)
    rm.rebuild_roads_from_existing(main_map.tile_data, main_map.map_rows,
            main_map.map_cols, Callable(main_map, "_skip_improvement_road_restore"))
    check(rm.is_hex_connected(row, col),
            "улучшение старого сейва должно снова получить дорогу", state)
    tile["improvement"] = null

# -------------------------------------------------------
# Хелперы
# -------------------------------------------------------

# Первое улучшение, которому полагается дорога: с no_road (ирригационный
# канал, лодки) дороги нет по правилам, такой id для проверки не годится.
func _pick_improvement() -> String:
    for id in _gdata.improvements.keys():
        if not bool(_gdata.improvements[id].get("no_road", false)):
            return str(id)
    return ""

# Гекс Кольца Влияния, к которому тянется трасса: так ищем гекс, который ещё
# можно занять и к которому действительно есть дорога.
#
# Сначала ищем гекс с трассой в 2+ участка (на нём видно, что цепочка идёт
# по участкам), а если такого на карте нет — берём любой гекс с хотя бы одним
# участком. Требовать два участка нельзя: кольцо влияния на части карт не
# достигает города дальше чем на гекс, и проверка падала бы не из-за правила,
# а из-за случайно сгенерированной карты.
func _find_hex_with_road_plan(main_map) -> Dictionary:
    var rm = main_map.road_manager
    var mh = load("res://scripts/map_helpers.gd")
    var fallback := {}
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = main_map.get_tile_data(row, col)
            if tile == null or not bool(tile.get("in_influence", false)):
                continue
            if bool(tile.get("has_town", false)) or bool(tile.get("in_town_influence", false)):
                continue
            if bool(tile.get("decorative", false)) or tile.get("improvement", null) != null:
                continue
            if mh.is_water_terrain(tile.get("terrain", "plain")):
                continue
            if main_map.build_manager.is_building(row, col):
                continue
            if not main_map.project_manager.get_project_at(row, col).is_empty():
                continue
            if rm.is_hex_connected(row, col):
                continue
            var plan: Dictionary = main_map.get_road_plan(row, col)
            if not plan.get("ok", false):
                continue
            if int(plan.get("segments", 0)) >= 2:
                return {"row": row, "col": col}
            if fallback.is_empty():
                fallback = {"row": row, "col": col}
    return fallback

func _collect_text(node: Node) -> String:
    var out: String = ""
    if node == null:
        return out
    if node is Label or node is RichTextLabel:
        out += str(node.get("text")) + "\n"
    for child in node.get_children():
        out += _collect_text(child)
    return out

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    push_error("ASSERT FAILED: %s" % message)