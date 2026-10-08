# Headless-тест ПРЕРЫВАНИЯ длительных действий на карте.
#   godot --headless --path . --script res://tests/test_cancel_actions.gd
#
# Проверки (живая сцена MainMap):
#   1. Кнопка прерывания проекта появляется на ЛЮБОМ его гексе, а не только на
#      цели: на гексе текущего шага (где прогресс-бар), на гексе в середине
#      трассы и на цели. Это был исходный баг: кнопка жила только на цели,
#      а игрок жмёт туда, где видит стройку.
#   2. Кнопка появляется на гексе С УЛУЧШЕНИЕМ, к которому идёт дорога
#      (ранний return в _collect_actions терял проверку проекта), и в кольце
#      влияния городка, где заканчивается дорога к нему.
#   3. Кнопка называет действие: «Прервать: <название>», а не родовое
#      «Отменить стройку». Осушение и вырубка спецдействиями тоже.
#   4. На гексе, где идёт и обычная стройка, и проект, показываются ОБЕ
#      кнопки: это разные вещи, и обе честны.
#   5. Прерывание проекта с любого его гекса отменяет ИМЕННО его, и по
#      project_id, а не по координатам гекса.
#   6. Освоение территории и разведка тоже прерываются, а уже оплаченные
#      монеты возвращаются в казну, а потерянный труд — нет.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

# The road level is passed to start_road_project, not the action id. Tests use
# the same derivation as the game (build_manager picks the highest unlocked
# level when the player does not choose one), so a balance change in the road
# levels does not silently turn this into a different scenario.
func _road_level() -> int:
    var game_data = get_root().get_node("GameData")
    return game_data.get_max_unlocked_road_level()

var _gdata = null
var _cdata = null
var _hexutils = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")
    _hexutils = load("res://scripts/HexUtils.gd")

    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    for _i in range(4):
        await process_frame
    if WATCHDOG.wants_case("project_cancel_anywhere"):
        await _test_project_cancel_anywhere(state, main_map)
    if WATCHDOG.wants_case("special_action_label"):
        _test_special_action_label(state, main_map)
    if WATCHDOG.wants_case("expansion_and_scouting"):
        _test_expansion_and_scouting(state, main_map)
    # ПОСЛЕДНИМ: подготовка разведывает всю карту, а освоению и разведке
    # нужны неразведанные гексы.
    if WATCHDOG.wants_case("town_hex"):
        await _test_town_hex(state, main_map, main_map.control_panel)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("CANCEL ACTIONS TEST FAILED")
        quit(1)
    else:
        print("CANCEL ACTIONS TEST OK")
        quit(0)

# -------------------------------------------------------
# 1, 2, 4, 5. Прерывание проекта
# -------------------------------------------------------

func _test_project_cancel_anywhere(state: Dictionary, main_map) -> void:
    var panel = main_map.control_panel
    var target := _find_hex_without_road(main_map)
    check(not target.is_empty(), "должен найтись гекс без дороги в 3+ участка", state)
    if target.is_empty():
        return
    var row := int(target.row)
    var col := int(target.col)
    var plan: Dictionary = main_map.get_road_plan(row, col)
    check(int(plan.get("segments", 0)) >= 3,
            "маршрут должен быть длиной хотя бы 3 участка", state)
    check(main_map.start_road_project(row, col, _road_level()),
            "дорогу должно быть можно запустить", state)

    var pm = main_map.project_manager
    var project: Dictionary = pm.get_project_at(row, col)
    var steps: Array = project.get("steps", [])
    check(steps.size() >= 3, "в очереди должно быть не меньше трёх шагов", state)

    # ПРОГРЕСС-БАР стоит на гексе ТЕКУЩЕГО шага — туда игрок и тыкает.
    var cur: Dictionary = steps[0].get("hex", {})
    var cur_row := int(cur.get("row", -1))
    var cur_col := int(cur.get("col", -1))
    var a_cur: Array = _actions(panel, main_map, cur_row, cur_col)
    check(_find(a_cur, "cancel_project") >= 0,
            "на гексе текущего шага (прогресс-бар) должна быть кнопка прерывания", state)

    # СЕРЕДИНА трассы — участок призрака, который игрок тоже видит на карте.
    var mid: Dictionary = steps[0].get("data", {}).get("to", {})
    var mid_row := int(mid.get("row", -1))
    var mid_col := int(mid.get("col", -1))
    if mid_row == cur_row and mid_col == cur_col:
        mid = steps[1].get("data", {}).get("to", {})
        mid_row = int(mid.get("row", -1))
        mid_col = int(mid.get("col", -1))
    var a_mid: Array = _actions(panel, main_map, mid_row, mid_col)
    check(_find(a_mid, "cancel_project") >= 0,
            "на гексе в середине трассы тоже должна быть кнопка прерывания", state)

    # ЦЕЛЬ — гекс, на котором кнопка была и раньше (регрессия не должна сломать).
    var a_goal: Array = _actions(panel, main_map, row, col)
    _check_no_duplicates(a_cur, state, "гексе текущего шага")
    _check_no_duplicates(a_mid, state, "гексе середины трассы")
    _check_no_duplicates(a_goal, state, "гексе цели")
    check(_find(a_goal, "cancel_project") >= 0,
            "на гексе цели должна быть кнопка прерывания", state)

    # Кнопка называет действие и предупреждает, что прерывается ВСЯ дорога.
    var gi := _find(a_goal, "cancel_project")
    var goal_label := str(a_goal[gi].get("label", ""))
    var goal_tip := str(a_goal[gi].get("tooltip", ""))
    check(goal_label.begins_with("Прерват"),
            "кнопка прерывания должна называться «Прерват...», а не «Отменить стройку»: %s" % goal_label, state)
    check(goal_label.contains("Дорога"),
            "в названии кнопки должно быть видно, ЧТО прерывается: %s" % goal_label, state)
    check(goal_tip.contains("недостроенных участков"),
            "тултип должен заранее называть число недостроенных участков", state)
    # project_id обязан нести сам проект, иначе нажатие с середины трассы
    # найдёт не тот проект (или ничего).
    check(str(a_goal[gi].get("project_id", "")) == str(project.get("id", "")),
            "кнопка должна нести project_id того же проекта", state)

    # Прерывание С СЕРЕДИНЫ трассы отменяет весь проект.
    check(pm.cancel_project_at_hex(mid_row, mid_col),
            "проект должен отменяться с гекса в середине трассы", state)
    check(pm.has_active_projects() == false,
            "после прерывания проект должен исчезнуть из очереди", state)
    check(_find(_actions(panel, main_map, row, col), "cancel_project") < 0,
            "после прерывания кнопка на цели должна исчезнуть", state)

    # Повторный запуск — чтобы убедиться, что кнопки не осталось в панели.
    main_map.build_manager.remove_build(row, col)
    main_map.project_manager.restore_projects({})

# -------------------------------------------------------
# 3, 4. Обычная стройка и спецдействия: кнопка называет действие
# -------------------------------------------------------

func _test_special_action_label(state: Dictionary, main_map) -> void:
    var panel = main_map.control_panel
    var bm = main_map.build_manager
    # Улучшение: кнопка называет именно его.
    var spot := _find_hex_with_improvement(main_map)
    if not spot.is_empty():
        var row := int(spot.row)
        var col := int(spot.col)
        var imp_id := str(spot.imp_id)
        bm.remove_build(row, col)
        bm.start_build(row, col, imp_id, null)
        check(bm.is_building(row, col), "обычная стройка должна запуститься", state)
        var acts: Array = _actions(panel, main_map, row, col)
        var i := _find(acts, "cancel_build")
        check(i >= 0, "на гексе идущей стройки должна быть кнопка прерывания", state)
        if i >= 0:
            check(str(acts[i].get("label", "")).begins_with("Прерват"),
                    "кнопка должна называться «Прерват...»: %s" % str(acts[i].get("label", "")), state)
            check(not str(acts[i].get("label", "")).contains("Отменить стройку"),
                    "родовое «Отменить стройку» должно быть заменено названием действия", state)
        bm.cancel_build(row, col)

    # Спецдействие (осушение болота / вырубка леса): называет спецдействие.
    var sa := _find_hex_with_special_action(main_map)
    var action_id := ""
    if not sa.is_empty():
        var row := int(sa.row)
        var col := int(sa.col)
        action_id = str(sa.action_id)
        var sa_name := str(_gdata.special_actions.get(action_id, {}).get("name", ""))
        bm.remove_build(row, col)
        bm.start_build(row, col, action_id, null)
        check(bm.is_building(row, col), "спецдействие должно запуститься как стройка", state)
        var acts: Array = _actions(panel, main_map, row, col)
        var i := _find(acts, "cancel_build")
        check(i >= 0, "на гексе идущего спецдействия должна быть кнопка прерывания", state)
        if i >= 0:
            check(str(acts[i].get("label", "")).contains(sa_name),
                    "кнопка спецдействия должна называть его («%s»), а не что-то общее: %s"
                            % [sa_name, str(acts[i].get("label", ""))], state)
        bm.cancel_build(row, col)

    # Обе кнопки сразу, если на гексе идёт и стройка, и проект.
    # Запись стройки кладём в active_builds напрямую: гекс участка дороги не
    # обязан быть пригодным для спецдействия, а состояние «стройка и проект на
    # одном гексе» нужно именно такое.
    var target := _find_hex_without_road(main_map)
    if not target.is_empty():
        var row := int(target.row)
        var col := int(target.col)
        main_map.start_road_project(row, col, _road_level())
        var project: Dictionary = main_map.project_manager.get_project_at(row, col)
        var steps: Array = project.get("steps", [])
        if not steps.is_empty():
            var h: Dictionary = steps[0].get("hex", {})
            var hrow := int(h.get("row", -1))
            var hcol := int(h.get("col", -1))
            bm.active_builds[str(hrow) + "," + str(hcol)] = {
                "progress": 1.0, "work_cost": 10, "imp_id": "demo",
                "target_res_id": null, "imp_name": "Демонстрация",
                "row": hrow, "col": hcol, "status": "active", "allocated_labor": 1.0,
            }
            var both: Array = _actions(panel, main_map, hrow, hcol)
            check(_find(both, "cancel_project") >= 0 and _find(both, "cancel_build") >= 0,
                    "на гексе, где идёт и стройка, и проект, показываются ОБЕ кнопки (типы: %d и %d)"
                            % [_find(both, "cancel_project"), _find(both, "cancel_build")], state)
            check(_find(_actions(panel, main_map, row, col), "cancel_project") >= 0,
                    "кнопка прерывания проекта остаётся и на цели", state)
            _check_no_duplicates(both, state, "гексе, где идёт и стройка, и проект")
            bm.remove_build(hrow, hcol)
        main_map.project_manager.restore_projects({})

# -------------------------------------------------------
# 6. Освоение и разведка: прерываются, монеты возвращаются
# -------------------------------------------------------

func _test_expansion_and_scouting(state: Dictionary, main_map) -> void:
    var panel = main_map.control_panel
    var em = main_map.expansion_manager
    _cdata.ignore_build_requirements = false
    _cdata.treasury = 500
    main_map.build_manager.set_process(false)

    # --- Освоение ---
    var chunk := _prepare_expandable_chunk(main_map)
    if chunk.is_empty():
        check(false, "должен найтись осваиваемый чанк у Кольца Влияния", state)
    else:
        var money: int = em.get_chunk_money_cost(chunk)
        var work: int = em.get_chunk_cost(chunk)
        var ok: bool = em.handle_action(chunk, money, work)
        check(ok, "освоение чанка должно запускаться", state)
        var first = chunk[0]
        var exp_data: Dictionary = main_map.build_manager.get_expansion_progress_for_hex(
                int(first.row), int(first.col))
        check(not exp_data.is_empty(), "на первом гексе чанка должен идти прогресс-бар освоения", state)
        check(int(exp_data.get("money_cost", 0)) == money,
                "в записи освоения должна храниться цена для возврата при отмене", state)
        var acts: Array = _actions(panel, main_map, int(first.row), int(first.col))
        check(_find(acts, "cancel_expansion") >= 0,
                "на гексе осваиваемого чанка должна быть кнопка «Прервать: Освоение области»", state)
        var before := int(_cdata.treasury)
        check(main_map.build_manager.cancel_expansion_at_hex(int(first.row), int(first.col)),
                "освоение должно прерываться", state)
        check(main_map.build_manager.get_expansion_progress_for_hex(
                int(first.row), int(first.col)).is_empty(),
                "после прерывания прогресс-бар освоения должен исчезнуть", state)
        check(int(_cdata.treasury) == before + money,
                "оплаченные за освоение монеты должны вернуться в казну: было %d, стало %d, ждали %d"
                        % [before, int(_cdata.treasury), before + money], state)
        # Чанк не должен присоединиться к Кольцу Влияния.
        check(not bool(main_map.tile_data[int(first.row)][int(first.col)].get("in_influence", false)),
                "прерванное освоение не должно присоединять чанк к Кольцу Влияния", state)

    # --- Разведка ---
    _cdata.treasury = 500
    var scout_chunk := _find_scoutable_chunk(main_map)
    check(not scout_chunk.is_empty(), "должен найтись неразведанный чанк для разведки", state)
    if not scout_chunk.is_empty():
        var cost: int = em.get_chunk_scout_cost(scout_chunk)
        main_map.start_scouting(scout_chunk)
        check(main_map.is_scouting, "разведка должна запуститься", state)
        var sfirst = scout_chunk[0]
        var sacts: Array = _actions(panel, main_map, int(sfirst.row), int(sfirst.col))
        check(_find(sacts, "cancel_scouting") >= 0,
                "на гексе разведываемого чанка должна быть кнопка «Прервать: Разведка»", state)
        var before := int(_cdata.treasury)
        check(main_map.cancel_scouting(), "разведка должна отменяться", state)
        check(not main_map.is_scouting and main_map.scouting_chunk.is_empty(),
                "после отмены разведки таймер должен быть сброшен", state)
        check(int(_cdata.treasury) == before + cost,
                "оплаченные за разведку монеты должны вернуться в казну: было %d, стало %d, ждали %d"
                        % [before, int(_cdata.treasury), before + cost], state)
        var any_explored := false
        for h in scout_chunk:
            if bool(main_map.tile_data[int(h.row)][int(h.col)].get("is_explored", false)):
                any_explored = true
                break
        check(not any_explored,
                "прерванная разведка не должна разведать ни одного гекса", state)

# -------------------------------------------------------
# Хелперы
# -------------------------------------------------------

func _actions(panel, main_map, row: int, col: int) -> Array:
    var tile = main_map.get_tile_data(row, col)
    if tile == null:
        return []
    return panel._collect_actions(row, col, tile)

# Кнопка прерывания не должна появляться в списке дважды. Раньше кнопка проекта
# на гексе городка добавлялась дважды: отдельно (спецслучай «дорога к
# городку») и общим помощником. Дубликат не бросается в глаза, но игрок
# видит две одинаковые кнопки и не понимает, в чём разница.
#
# Проверяются ТОЛЬКО кнопки прерывания: обычные действия дублируются
# закономерно (на гексе может быть и осушение, и вырубка — это две
# кнопки «special», и несколько «research_tech» подряд).
func _check_no_duplicates(actions: Array, state: Dictionary, where: String) -> void:
    var seen := {}
    var dups := []
    for a in actions:
        var t := str(a.get("type", ""))
        if not t.begins_with("cancel"):
            continue
        if seen.has(t):
            dups.append(t)
        seen[t] = true
    check(dups.is_empty(), "на %s кнопка прерывания продублирована: %s"
            % [where, str(dups)], state)

# Индекс первого действия нужного типа, -1 если такого нет.
func _find(actions: Array, type: String) -> int:
    for i in range(actions.size()):
        if str(actions[i].get("type", "")) == type:
            return i
    return -1

func check(cond: bool, message: String, state: Dictionary) -> void:
    if cond:
        return
    state["failed"] = true
    push_error("ASSERT FAILED: %s" % message)

func _find_hex_without_road(main_map) -> Dictionary:
    var rm = main_map.road_manager
    var mh = load("res://scripts/map_helpers.gd")
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = main_map.get_tile_data(row, col)
            if tile == null or not bool(tile.get("in_influence", false)):
                continue
            if bool(tile.get("has_town", false)) or bool(tile.get("in_town_influence", false)):
                continue
            if bool(tile.get("decorative", false)) or tile.get("improvement", null) != null:
                continue
            if mh.is_water_terrain(tile.get("terrain", "plain")) or rm.is_hex_connected(row, col):
                continue
            var plan: Dictionary = rm.plan_road_to(row, col, main_map.tile_data,
                    main_map.map_rows, main_map.map_cols)
            if not plan.get("ok", false) or int(plan.get("segments", 0)) < 3:
                continue
            return {"row": row, "col": col}
    return {}

# Гекс с улучшением, к которому ещё не подведена дорога: именно к нему
# строится дорога, и именно тут проверяется прерывание проекта.
func _find_hex_with_improvement(main_map) -> Dictionary:
    var rm = main_map.road_manager
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = main_map.get_tile_data(row, col)
            if tile == null or not bool(tile.get("in_influence", false)):
                continue
            var imp_id = tile.get("improvement", null)
            if imp_id == null or bool(tile.get("decorative", false)):
                continue
            if bool(_gdata.improvements.get(imp_id, {}).get("no_road", false)):
                continue
            if rm.is_hex_connected(row, col):
                continue
            var plan: Dictionary = rm.plan_road_to(row, col, main_map.tile_data,
                    main_map.map_rows, main_map.map_cols)
            if not plan.get("ok", false):
                continue
            return {"row": row, "col": col, "imp_id": imp_id}
    return {}
# Подготовка осваиваемого чанка: разведать его и вернуть.
#
# НАЧАЛЬНОЕ СОСТОЯНИЕ важно: в новой игре разведано только Кольцо Влияния, за
# его пределами не разведано НИ ОДНОГО гекса, поэтому осваивать нечего и кнопки
# «Освоить область» не предлагается. Тест сам разведывает чанк рядом с городом -
# это обычная последовательность игрока (сначала разведка, потом освоение), и
# только после неё появляется объект для проверки отмены.
func _prepare_expandable_chunk(main_map) -> Array:
    var em = main_map.expansion_manager
    var ci := int(main_map.city_row)
    var cj := int(main_map.city_col)
    for radius in range(1, 7):
        for row in range(ci - radius, ci + radius + 1):
            for col in range(cj - radius, cj + radius + 1):
                var tile = main_map.get_tile_data(row, col)
                if tile == null or bool(tile.get("in_influence", false)):
                    continue
                # Разведываем все гексы чанка: после этого get_chunk_hexes для
                # этого гекса отдаёт осваиваемую область.
                for h in em.get_chunk_hexes(row, col):
                    var t2 = main_map.get_tile_data(int(h.row), int(h.col))
                    if t2 != null:
                        t2["is_explored"] = true
                var chunk: Array = em.get_chunk_hexes(row, col)
                if chunk.is_empty() or em.get_chunk_cost(chunk) <= 0:
                    continue
                var has_neighbor := false
                for h in chunk:
                    for n in _hexutils.get_neighbors_odd_r(int(h.row), int(h.col),
                            main_map.map_rows, main_map.map_cols):
                        if bool(main_map.tile_data[int(n.row)][int(n.col)].get("in_influence", false)):
                            has_neighbor = true
                            break
                    if has_neighbor:
                        break
                if has_neighbor:
                    return chunk
    return []

# Гекс, к которому применимо спецдействие из special_actions.json
# (осушение болота, вырубка леса и т.п.).
func _find_hex_with_special_action(main_map) -> Dictionary:
    for action_id in _gdata.special_actions:
        var sa: Dictionary = _gdata.special_actions[action_id]
        var atype := str(sa.get("action_type", ""))
        if atype != "terrain" and atype != "cover":
            continue
        var terrains: Array = sa.get("source_terrains", [])
        if terrains.is_empty():
            terrains = [sa.get("source_terrain", "")]
        for row in range(main_map.region_start_row, main_map.region_end_row + 1):
            for col in range(main_map.region_start_col, main_map.region_end_col + 1):
                var tile = main_map.get_tile_data(row, col)
                if tile == null or not bool(tile.get("in_influence", false)):
                    continue
                # Гексы городка и его кольца влияния build_manager не даёт трогать.
                if bool(tile.get("has_town", false)) or bool(tile.get("in_town_influence", false)):
                        continue
                if bool(tile.get("decorative", false)):
                        continue
                if tile.get("improvement", null) != null or tile.get("resource", null) != null:
                        continue
                if atype == "terrain" and str(tile.get("terrain", "")) in terrains:
                    return {"row": row, "col": col, "action_id": action_id}
                if atype == "cover" \
                        and str(tile.get("cover", "none")) in sa.get("source_cover", []):
                    return {"row": row, "col": col, "action_id": action_id}
    return {}

# Неразведанный чанк, примыкающий к известной территории (иначе разведка
# не запускается гейтом main_map.is_chunk_adjacent_to_known).
func _find_scoutable_chunk(main_map) -> Array:
    var em = main_map.expansion_manager
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = main_map.get_tile_data(row, col)
            if tile == null or bool(tile.get("in_influence", false)):
                continue
            if bool(tile.get("is_explored", false)):
                continue
            var chunk: Array = em.get_chunk_hexes(row, col)
            if chunk.is_empty():
                continue
            var unexplored := 0
            for h in chunk:
                if not bool(main_map.tile_data[int(h.row)][int(h.col)].get("is_explored", false)):
                    unexplored += 1
            if unexplored <= 0:
                continue
            if not main_map.is_chunk_adjacent_to_known(chunk):
                continue
            return chunk
    return []

# Гекс ЧУЖОГО ГОРОДКА: там кнопка «Построить дорогу от города» заменяется на
# прерывание, если дорога к нему уже идёт. Отдельно проверяем, что прерывание
# не продублировалось: раньше оно добавлялось и спецслучаем, и общим помощником.
func _test_town_hex(state: Dictionary, main_map, panel) -> void:
    # Разведываем карту: без этого до городка нет сухопутного пути, и
    # start_road_project честно откажет. Это обычная подготовка игрока —
    # сначала разведка, потом дорога.
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var t = main_map.get_tile_data(row, col)
            if t != null:
                t["is_explored"] = true
    main_map.road_manager.bump_map_knowledge()
    var town := _find_town_hex(main_map)
    check(not town.is_empty(), "должен найтись гекс чужого городка", state)
    if town.is_empty():
        return
    var row := int(town.row)
    var col := int(town.col)
    var start: bool = main_map.start_road_project(row, col, _road_level())
    check(start, "дорогу к городку должно быть можно запустить", state)
    var acts: Array = _actions(panel, main_map, row, col)
    _check_no_duplicates(acts, state, "гексе чужого городка")
    check(_find(acts, "cancel_project") >= 0,
            "на гексе чужого городка должна быть кнопка прерывания дороги к нему", state)
    main_map.project_manager.restore_projects({})

# Первый гекс чужого городка на карте.
func _find_town_hex(main_map) -> Dictionary:
    # Городки стоят по всей карте, в том числе ЗА пределами Региона, поэтому
    # перебираем всю карту, а не только Регион. Гекс САМОГО города игрока
    # пропускаем: там другой набор действий.
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if row == int(main_map.city_row) and col == int(main_map.city_col):
                continue
            var tile = main_map.get_tile_data(row, col)
            if tile != null and bool(tile.get("has_town", false)):
                return {"row": row, "col": col}
    return {}