# Headless-тест универсальной системы ПОЭТАПНОГО строительства
# (scripts/project_manager.gd) и того, как дорога на ней построена.
#   godot --headless --path . --script res://tests/test_staged_projects.gd
#
# Проверки (менеджер в одиночку + живая сцена MainMap):
#   1. Проект разбирается по ОДНОМУ шагу за раз: сколько бы труда ни подали,
#      за кадр достраивается ровно один участок, следующий начинается, а бар
#      переезжает на его гекс.
#   2. Призрак = сегменты ещё не построенных шагов, и он уменьшается на один
#      участок с каждым достроенным шагом.
#   3. Менеджер НЕ знает, что такое дорога: тот же механизм проходит проект
#      другого вида (в тесте — «акведук») без единой правки кода менеджера.
#   4. Отмена: построенное остаётся, непостроенное исчезает из призрака.
#   5. Сейв/загрузка: очередь и позиция сохраняются, счётчик не пересекается.
#   6. Живая сцена: за один кадр добавляется ровно один сегмент, дорога идёт
#      от сети к цели, флаг road_built ставится на каждом подключённом гексе.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как
# вечное молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _pm = null
var _cdata = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

# The road level is what start_road_project takes as its third argument (the
# action id is not). The level is derived the way the game derives it when the
# player has not picked one, so a road-level balance change does not silently
# turn this into a different scenario.
func _road_level() -> int:
    var game_data = get_root().get_node("GameData")
    return game_data.get_max_unlocked_road_level()

func _run() -> void:
    var state = {"failed": false}

    # Автолоады берём узлами дерева сцены: в режиме --script имена GameData и
    # CityData на этапе компиляции этого файла ещё недоступны. new_game()
    # заодно грузит все данные.
    get_root().get_node("SaveManager").new_game()
    _cdata = get_root().get_node("CityData")

    _pm = load("res://scripts/project_manager.gd").new()
    get_root().add_child(_pm)

    if WATCHDOG.wants_case("one_step_at_a_time"):
        _test_one_step_at_a_time(state)
    if WATCHDOG.wants_case("ghost_shrinks"):
        _test_ghost_shrinks(state)
    if WATCHDOG.wants_case("other_project_kind"):
        _test_other_project_kind(state)
    if WATCHDOG.wants_case("cancel"):
        _test_cancel(state)
    if WATCHDOG.wants_case("save_restore"):
        _test_save_restore(state)

    get_root().remove_child(_pm)
    _pm.free()
    _pm = null

    if WATCHDOG.wants_case("live_road"):
        await _test_live_road(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("STAGED PROJECTS TEST FAILED")
        quit(1)
    else:
        print("STAGED PROJECTS TEST OK")
        quit(0)

# -------------------------------------------------------
# Хелперы
# -------------------------------------------------------

# Собирает шаг очереди: гекс (row, col) — где рисуется прогресс-бар и над каким
# сегментом призрака этот шаг «отвечает».
func _make_step(row: int, col: int, work_cost: float, seg: String) -> Dictionary:
    return {
        "label": "Участок %d,%d" % [row, col],
        "work_cost": work_cost,
        "hex": {"row": row, "col": col},
        "ghost": {seg: true},
        "data": {"row": row, "col": col, "segment": seg},
    }

func check(cond: bool, message: String, state: Dictionary) -> void:
    if cond:
        return
    state["failed"] = true
    push_error("ASSERT FAILED: %s" % message)


# -------------------------------------------------------
# 1. По одному шагу за раз
# -------------------------------------------------------

func _test_one_step_at_a_time(state: Dictionary) -> void:
    var steps := [
        _make_step(1, 1, 10.0, "1,1|1,2"),
        _make_step(1, 2, 10.0, "1,2|1,3"),
        _make_step(1, 3, 10.0, "1,3|1,4"),
    ]
    var completed: Array = []
    var started: Array = []
    _pm.step_completed.connect(func(_id, _kind, step):
        completed.append(step.get("label", "")))
    _pm.step_started.connect(func(_id, _kind, step):
        started.append(step.get("label", "")))

    var pid: String = _pm.start_project("demo", "Демо", 1, 4, steps)
    check(pid != "", "проект должен запуститься", state)
    check(_pm.get_active_step_count() == 1,
            "активный проект занимает ровно один слот в пуле труда", state)
    check(started.size() == 1 and str(started[0]) == "Участок 1,1",
            "первый шаг должен стартовать сразу", state)

    # Подаём труд ЗНАЧИТЕЛЬНО больше стоимости шага: за один вызов всё равно
    # должен достроиться РОВНО ОДИН участок, а не вся очередь.
    _pm.receive_labor(10000.0, 1.0)
    check(completed.size() == 1,
            "за один кадр достраивается ровно один участок, а не вся очередь", state)
    check(str(completed[0]) == "Участок 1,1",
            "достроен должен быть именно текущий, первый участок", state)
    check(started.size() == 2 and str(started[1]) == "Участок 1,2",
            "после первого участка должен начаться второй", state)

    # Прогресс-бар переехал на гекс второго участка, и на первом его больше нет.
    check(_pm.get_step_progress_at(1, 1).is_empty(),
            "на гексе достроенного участка прогресс-бара быть уже не должно", state)
    var bar: Dictionary = _pm.get_step_progress_at(1, 2)
    check(not bar.is_empty(), "на гексе второго участка должен быть прогресс-бар", state)
    check(int(bar.get("step_index", -1)) == 1,
            "прогресс-бар должен соответствовать второму шагу", state)
    check(int(bar.get("steps_left", 0)) == 2,
            "в прогрессе должно оставаться два участка", state)

    # Труд копится, а не тратится: половины шага недостаточно для завершения.
    _pm.receive_labor(3.0, 1.0)
    check(completed.size() == 1, "недобранный шаг не должен достраиваться", state)
    var bar_after: Dictionary = _pm.get_step_progress_at(1, 2)
    check(float(bar_after.get("progress", 0.0)) > 0.0,
            "прогресс текущего шага должен копиться", state)

    # Добор до конца: шаг достраивается, и так до последнего.
    for _i in range(3):
        _pm.receive_labor(1000.0, 1.0)
    check(completed.size() == 3, "все три участка должны быть достроены", state)
    check(_pm.get_active_step_count() == 0,
            "после последнего шага проект больше не занимает слот", state)
    check(_pm.get_project(pid).is_empty(),
            "завершённый проект должен исчезнуть из очереди", state)
    check(_pm.get_step_progress_at(1, 2).is_empty(),
            "после завершения прогресс-бар исчезает", state)

# -------------------------------------------------------
# 2. Призрак уменьшается на каждый достроенный участок
# -------------------------------------------------------

func _test_ghost_shrinks(state: Dictionary) -> void:
    check(_pm.get_pending_ghost_segments().is_empty(),
            "завершённые проекты не оставляют призрака", state)
    var steps := [
        _make_step(2, 1, 5.0, "2,1|2,2"),
        _make_step(2, 2, 5.0, "2,2|2,3"),
    ]
    var pid: String = _pm.start_project("demo", "Призрак", 2, 3, steps)
    var ghost: Dictionary = _pm.get_pending_ghost_segments()
    check(ghost.size() == 2,
            "призрак нового проекта равен числу непостроенных участков", state)
    check(ghost.has("2,1|2,2") and ghost.has("2,2|2,3"),
            "призрак содержит сегменты обоих участков", state)

    _pm.receive_labor(1000.0, 1.0)
    ghost = _pm.get_pending_ghost_segments()
    check(ghost.size() == 1,
            "после достройки участка призрак должен уменьшиться на один", state)
    check(not ghost.has("2,1|2,2"),
            "построенный участок должен исчезнуть из призрака", state)
    check(ghost.has("2,2|2,3"),
            "непостроенный участок должен остаться в призраке", state)

    _pm.receive_labor(1000.0, 1.0)
    check(_pm.get_pending_ghost_segments().is_empty(),
            "после конца проекта призрак должен исчезнуть совсем", state)
    _pm.cancel_project(pid)


# -------------------------------------------------------
# 3. Универсальность: тот же менеджер — другой вид проекта
# -------------------------------------------------------

func _test_other_project_kind(state: Dictionary) -> void:
    # Тот же менеджер, тот же порядок вызовов — но проект другого вида. Если бы
    # менеджер был написан под дорогу, шаг «акведука» не доехал бы.
    var aqueduct_steps := [
        _make_step(5, 5, 20.0, "5,5|5,6"),
        _make_step(5, 6, 20.0, "5,6|5,7"),
    ]
    var done: Array = []
    _pm.step_completed.connect(func(_id, kind, _step):
        if kind == "aqueduct":
            done.append(kind))
    var pid: String = _pm.start_project("aqueduct", "Акведук от горы", 5, 7,
            aqueduct_steps)
    check(pid != "", "проект другого вида должен запускаться тем же способом", state)
    check(str(_pm.get_step_progress_at(5, 5).get("kind", "")) == "aqueduct",
            "прогресс-бар должен знать вид проекта", state)
    _pm.receive_labor(1000.0, 1.0)
    check(done.size() == 1,
            "шаг другого вида проекта так же достраивается по одному", state)
    _pm.receive_labor(1000.0, 1.0)
    check(_pm.get_active_step_count() == 0, "проект другого вида тоже завершается", state)

# -------------------------------------------------------
# 4. Отмена: построенное остаётся, непостроенное — нет
# -------------------------------------------------------

func _test_cancel(state: Dictionary) -> void:
    var steps := [
        _make_step(7, 1, 5.0, "7,1|7,2"),
        _make_step(7, 2, 5.0, "7,2|7,3"),
        _make_step(7, 3, 5.0, "7,3|7,4"),
    ]
    var pid: String = _pm.start_project("demo", "К отмене", 7, 4, steps)
    _pm.receive_labor(1000.0, 1.0)
    check(_pm.get_pending_ghost_segments().size() == 2,
            "перед отменой в призраке два участка", state)

    var cancelled := {"hit": 0}
    _pm.project_cancelled.connect(func(_id, _kind, _meta):
        cancelled["hit"] = int(cancelled["hit"]) + 1)
    check(_pm.cancel_project(pid), "отмена активного проекта должна сработать", state)
    check(int(cancelled["hit"]) == 1, "отмена должна эмитить project_cancelled", state)
    check(_pm.get_project(pid).is_empty(), "отменённый проект исчезает из очереди", state)
    check(_pm.get_active_step_count() == 0,
            "отменённый проект больше не занимает слот в пуле труда", state)
    check(_pm.get_pending_ghost_segments().is_empty(),
            "после отмены непостроенные участки исчезают из призрака", state)
    check(not _pm.cancel_project(pid), "повторная отмена ничего не делает", state)

# -------------------------------------------------------
# 5. Сохранение и загрузка очереди
# -------------------------------------------------------

func _test_save_restore(state: Dictionary) -> void:
    var steps := [
        _make_step(9, 1, 5.0, "9,1|9,2"),
        _make_step(9, 2, 5.0, "9,2|9,3"),
        _make_step(9, 3, 5.0, "9,3|9,4"),
    ]
    var pid: String = _pm.start_project("demo", "В сейв", 9, 4, steps)
    _pm.receive_labor(1000.0, 1.0)
    var saved: Dictionary = _pm.serialize_projects()
    check(saved.has(pid), "в сейв должна попасть очередь проекта", state)
    check(int(saved[pid].get("step_index", -1)) == 1,
            "в сейв пишется позиция очереди: первый участок уже построен", state)

    _pm.cancel_project(pid)
    _pm.restore_projects(saved)
    var restored: Dictionary = _pm.get_project(pid)
    check(not restored.is_empty(), "проект должен восстановиться из сейва", state)
    check(int(restored.get("step_index", -1)) == 1,
            "после загрузки очередь продолжается с того же места", state)
    check(_pm.get_pending_ghost_segments().size() == 2,
            "после загрузки в призраке только недостроенные участки", state)
    check(not _pm.get_step_progress_at(9, 2).is_empty(),
            "после загрузки прогресс-бар стоит на текущем шаге", state)
    check(_pm.get_step_progress_at(9, 1).is_empty(),
            "на достроенном до загрузки участке бара быть не должно", state)

    # Новый проект после загрузки не должен получить занятый ключ.
    var next_id: String = _pm.start_project("demo", "После загрузки", 9, 6, [
        _make_step(9, 6, 5.0, "9,6|9,7")])
    check(next_id != pid, "новый проект после загрузки получает свободный ключ", state)
    _pm.restore_projects({})
    check(_pm.get_active_step_count() == 0,
            "восстановление пустого сейва очищает очередь", state)

# -------------------------------------------------------
# 6. Живая сцена: дорога строится по одному гексу
# -------------------------------------------------------

func _test_live_road(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var rm = main_map.road_manager
    var pm = main_map.project_manager
    # Ручной разбор кадров вместо автоматического: иначе между стартом дороги
    # и проверками движок успеет прогнать несколько кадров сам, и «за один кадр
    # достроился один участок» нельзя будет проверить вовсе.
    main_map.build_manager.set_process(false)

    # Гекс Кольца Влияния, до которого реально можно дотянуть дорогу длиной
    # больше одного участка (иначе проверять поэтапность не на чем).
    var target := _find_hex_without_road(main_map)
    check(not target.is_empty(),
            "на живой карте должен найтись гекс без дороги в 2+ участка", state)
    if target.is_empty():
        get_root().remove_child(main_map)
        main_map.free()
        return
    var row := int(target.row)
    var col := int(target.col)

    var plan: Dictionary = main_map.get_road_plan(row, col)
    check(plan.get("ok", false), "до выбранного гекса должна быть трасса: %s"
            % plan.get("reason", ""), state)
    var total_segments := int(plan.get("segments", 0))

    var previous_flag: bool = bool(_cdata.ignore_build_requirements)
    _cdata.ignore_build_requirements = false
    check(main_map.start_road_project(row, col, _road_level()),
            "дорогу на живой сцене должно быть можно запустить", state)
    var project: Dictionary = pm.get_project_at(row, col)
    var step_count: int = project.get("steps", []).size()
    check(step_count == total_segments,
            "в очереди должно быть столько же шагов, сколько новых участков: %d и %d"
                    % [step_count, total_segments], state)
    check(pm.get_pending_ghost_segments().size() == step_count,
            "призрак проекта равен всей очереди", state)

    # Один кадр раздачи труда — и РОВНО ОДИН сегмент дороги. Дельта подбирается
    # под цену шага: в headless население = 1 житель, то есть труд идёт со
    # скоростью 1 единица в секунду, а участок дороги стоит 3. Подаём с запасом
    # на ОДИН участок, но заведомо меньше двух — иначе «по одному гексу» и не
    # проверить.
    var first_cost: float = float(project.get("steps", [{}])[0].get("work_cost", 1.0))
    var labor_per_build: float = maxf(0.001, _cdata.get_total_labor())
    var delta: float = first_cost * 1.5 / labor_per_build
    main_map.build_manager._process(delta)
    var built: Dictionary = rm.get_all_road_segments()
    check(built.size() == 1,
            "за один кадр должен достроиться ровно один участок дороги", state)
    var ghost_after: Dictionary = pm.get_pending_ghost_segments()
    check(ghost_after.size() == step_count - 1,
            "после достройки участка призрак должен уменьшиться на один", state)
    check(int(pm.get_project_at(row, col).get("step_index", -1)) == 1,
            "очередь должна сдвинуться на второй участок", state)

    # Флаг road_built ставится на гекс, который участок ПРИСОЕДИНЯЕТ к сети:
    # по этим флагам сеть восстанавливается из сейва, поэтому полупостроенная
    # дорога не теряется. Первый шаг соединяет уже дорожный гекс города (у
    # него флага нет — там дорога от улучшения), поэтому помечен ровно один.
    var flagged := 0
    for key in built.keys():
        for endpoint in str(key).split("|"):
            var xy := str(endpoint).split(",")
            if xy.size() == 2 \
                    and bool(main_map.tile_data[int(xy[0])][int(xy[1])].get("road_built", false)):
                flagged += 1
    check(flagged == 1,
            "гекс, присоединённый участком, должен быть помечен road_built", state)
    var first_step: Dictionary = project.get("steps", [{}])[0]
    var joined: Dictionary = first_step.get("data", {}).get("to", {})
    check(bool(main_map.tile_data[int(joined.get("row", 0))][int(joined.get("col", 0))]
            .get("road_built", false)),
            "road_built должен стоять на гексе, к которому пришла дорога", state)

    # Добиваем остаток по одному участку за кадр.
    for _i in range(step_count + 2):
        if not pm.has_active_projects():
            break
        main_map.build_manager._process(delta)
    check(rm.is_hex_connected(row, col),
            "после достройки всей очереди гекс должен получить дорогу", state)
    check(bool(main_map.tile_data[row][col].get("road_built", false)),
            "на целевом гексе должен стоять флаг road_built", state)
    check(pm.get_pending_ghost_segments().is_empty(),
            "после завершения проекта призрак должен исчезнуть", state)
    check(main_map.map_renderer._project_ghost_segments.is_empty(),
            "рендерер тоже должен снять призрак проекта", state)

    _cdata.ignore_build_requirements = previous_flag
    get_root().remove_child(main_map)
    main_map.free()

# Гекс Кольца Влияния без дороги, до которого тянется маршрут в 2+ участка.
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
            if mh.is_water_terrain(tile.get("terrain", "plain")):
                continue
            if rm.is_hex_connected(row, col):
                continue
            var plan: Dictionary = rm.plan_road_to(row, col, main_map.tile_data,
                    main_map.map_rows, main_map.map_cols)
            if not plan.get("ok", false) or int(plan.get("segments", 0)) < 2:
                continue
            return {"row": row, "col": col}
    return {}
