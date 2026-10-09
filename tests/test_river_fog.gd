# Headless-тест обрезки рек по туману войны (map_renderer, ФАЗА 2.75):
#   godot --headless --path . --script res://tests/test_river_fog.gd
#
# Регрессия, которую ловит тест: реки рисовались сквозь туман войны. Гекс
# в тумане не отрисовывается вовсе (см. _draw_hex), поэтому река на нём
# висела в чёрной пустоте. Река должна обрываться по границе разведанной
# области.
#
# Проверяется на живой карте MainMap (новая игра):
#   1. Обрезка реально срабатывает: у хотя бы одной реки туман выбрасывает
#      часть сглаженных точек (иначе проверки ниже бессмысленны).
#   2. Все выжившие точки лежат над разведанной территорией. Проверка —
#      НЕЗАВИСИМАЯ от локального оценщика _nearest_hex: ближайший гекс
#      ищется полным перебором карты.
#   3. Точка в разведанной области видима, точка вдали от неё (в тумане) —
#      нет.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var r = main_map.map_renderer
    var river_manager = main_map.get_node("RiverManager")
    var radius: float = main_map.HEX_RADIUS
    var all_rivers: Array = river_manager.get_main_rivers() + river_manager.get_tributaries()

    # --- 1. Туман реально выбрасывает точки хотя бы у одной реки ---
    var dropped_total: int = 0
    var kept_total: int = 0
    for river in all_rivers:
        if river.size() < 2:
            continue
        var world_points = PackedVector2Array()
        for pt in river:
            world_points.append(Vector2(pt.x, pt.y))
        var smooth: PackedVector2Array = r._generate_natural_river(world_points, radius)
        var runs: Array = r._split_line_by_fog(smooth, radius)
        var kept: int = 0
        for run in runs:
            kept += run.size()
        dropped_total += smooth.size() - kept
        kept_total += kept
    check(dropped_total > 0,
        "туман войны должен выбрасывать часть точек рек (выброшено %d)" % dropped_total, state)
    check(kept_total > 0,
        "часть рек должна оставаться видимой (оставлено %d)" % kept_total, state)

    # --- 2. Выжившие точки — над разведанной территорией (независимая проверка) ---
    var sample_step: int = max(1, kept_total / 200)
    var checked: int = 0
    var violations: Array = []
    for river in all_rivers:
        if river.size() < 2:
            continue
        var world_points = PackedVector2Array()
        for pt in river:
            world_points.append(Vector2(pt.x, pt.y))
        var smooth: PackedVector2Array = r._generate_natural_river(world_points, radius)
        var runs: Array = r._split_line_by_fog(smooth, radius)
        var counter: int = 0
        for run in runs:
            for pt in run:
                counter += 1
                if counter % sample_step != 0:
                    continue
                checked += 1
                if not _over_explored(main_map, pt, radius):
                    violations.append(pt)
    check(checked > 0, "должно быть проверено хотя бы несколько точек", state)
    check(violations.is_empty(),
        "выжившие точки рек не должны лежать в тумане войны (нарушителей: %d из %d)"
            % [violations.size(), checked], state)

    # --- 3. Точка в разведанной области видима, точка в глубине тумана — нет ---
    var city_center: Vector2 = HexUtils.hex_center(main_map.city_row, main_map.city_col, radius)
    check(r._is_river_point_visible(city_center, radius),
        "точка в центре карты (в Регионе) должна быть видима", state)

    # Гекс в глубине тумана: сам в тумане и все соседи тоже (иначе точка на его
    # грани законно считалась бы видимой — река течёт по граням гексов).
    var deep_fog: Vector2i = Vector2i(-1, -1)
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            if not main_map.is_hex_in_fog(row, col):
                continue
            var all_fog: bool = true
            for n in HexUtils.get_neighbors_odd_r(row, col, main_map.map_rows, main_map.map_cols):
                if not main_map.is_hex_in_fog(n.row, n.col):
                    all_fog = false
                    break
            if all_fog:
                deep_fog = Vector2i(row, col)
                break
        if deep_fog.x >= 0:
            break
    check(deep_fog.x >= 0, "на карте должен найтись гекс в глубине тумана", state)
    if deep_fog.x >= 0:
        var fog_center: Vector2 = HexUtils.hex_center(deep_fog.x, deep_fog.y, radius)
        check(not r._is_river_point_visible(fog_center, radius),
            "точка в глубине тумана должна быть скрыта", state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("RIVER FOG TEST FAILED")
        quit(1)
    else:
        print("RIVER FOG TEST OK")
        quit(0)

# Независимая проверка «точка над разведанной территорией»: ближайший гекс
# ищется ПОЛНЫМ перебором карты (а не локальным _nearest_hex рендерера),
# затем проверяются сам гекс и его соседи — река течёт по граням гексов,
# поэтому видима, если касается хотя бы одного нарисованного гекса.
func _over_explored(main_map, pos: Vector2, radius: float) -> bool:
    var best_row: int = -1
    var best_col: int = -1
    var best_d: float = INF
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var d: float = HexUtils.hex_center(row, col, radius).distance_squared_to(pos)
            if d < best_d:
                best_d = d
                best_row = row
                best_col = col
    if not main_map.is_hex_in_fog(best_row, best_col):
        return true
    for n in HexUtils.get_neighbors_odd_r(best_row, best_col, main_map.map_rows, main_map.map_cols):
        if not main_map.is_hex_in_fog(n.row, n.col):
            return true
    return false

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)
