# Headless-тест отрисовки рек (map_renderer, ФАЗА 2.75):
#   godot --headless --path . --script res://tests/test_river_rendering.gd
#
# Регрессия, которую ловит тест: точки реки сдвигаются на offset и с этого
# момента живут в ЭКРАННЫХ координатах, а отсекались они по прямоугольнику
# Rect2(Vector2(-offset_x, -offset_y), ...), то есть по МИРОВОМУ окну. При
# центрировании карты (offset_x ~ -2280) окно уезжало далеко за экран, и
# _clip_river_to_rect возвращал [] для каждой реки — реки оставались в данных
# (river_edges, доступ к пресной воде), но не рисовались.
#
# Проверяется на живых данных реальной сцены MainMap (новая игра):
#   1. Данные рек целы: есть главные реки/притоки и гексы с river_edges.
#   2. Экранный прямоугольник начинается в нуле экранных координат — он и
#      должен быть в той же системе, что и сдвинутые точки.
#   3. На живой карте хотя бы одна река реально даёт непустые линии, и все
#      их точки лежат внутри экрана (обрезка по экрану, а не выбрасывание).
#   4. Прокрутка карты (scroll_offset) не «убивает» отрисовку: та же река
#      остаётся видимой.
#   5. Река целиком за экраном не рисуется (отсечение по-прежнему работает).
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

    # --- 1. Данные рек на месте (иначе проверки отрисовки бессмысленны) ---
    var main_rivers: Array = river_manager.get_main_rivers()
    var tributaries: Array = river_manager.get_tributaries()
    check(not main_rivers.is_empty(),
        "на живой карте должен быть хотя бы один главный поток", state)
    check(not main_rivers.is_empty() or not tributaries.is_empty(),
        "на живой карте должны быть реки", state)

    var edge_hexes: int = 0
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var tile = main_map.tile_data[row][col]
            if tile != null and not tile.get("river_edges", []).is_empty():
                edge_hexes += 1
    check(edge_hexes > 0,
        "реки должны оставлять river_edges в гексах (косвенный признак воды)", state)

    # --- 2. Экранный прямоугольник — в экранных координатах ---
    var screen_rect: Rect2 = r._get_screen_rect()
    check(screen_rect.position == Vector2.ZERO,
        "экранный прямоугольник должен начинаться в нуле экранных координат", state)
    check(screen_rect.size.x > 0.0 and screen_rect.size.y > 0.0,
        "размер экрана должен быть положительным (получено %s)" % str(screen_rect.size),
        state)

    # --- 3. Хотя бы одна река видна и обрезана по экрану ---
    # Экранный прямоугольник задан с запасом main_map.MAP_CACHE_MARGIN (как и кэш
    # отрисовки), поэтому цикл идёт по пробам сдвига, пока карта не встанет так,
    # что реки попадут в кадр.
    var all_rivers: Array = main_rivers + tributaries
    var visible_rivers: int = 0
    var outside: Array = []
    var probes: Array = _candidate_scrolls(main_map, all_rivers)
    for probe in probes:
        var visible_in_probe: int = 0
        var outside_in_probe: Array = []
        for river in all_rivers:
            var lines: Array = _lines(r, river, main_map, probe)
            if lines.is_empty():
                continue
            visible_in_probe += 1
            outside_in_probe.append_array(_points_outside(
                lines, screen_rect, main_map.MAP_CACHE_MARGIN))
        if visible_in_probe > visible_rivers:
            visible_rivers = visible_in_probe
            outside = outside_in_probe
    check(visible_rivers > 0,
        "хотя бы одна река должна пересекать экран (полилиний: %d)" % visible_rivers, state)
    check(outside.is_empty(),
        "точки отрисованной реки не должны выходить за экран (нарушителей: %s)"
            % str(outside), state)

    # --- 4. Прокрутка не ломает отрисовку ---
    # Штатный способ прокрутки в игре — ПКМ по кнопке города (центрирует
    # город); берём тот же сдвиг, что и main_map._on_city_button_gui_input.
    var scroll = - (HexUtils.hex_center(main_map.city_row, main_map.city_col, radius)
        + Vector2(main_map.offset_x, main_map.offset_y) - r._get_viewport_size() / 2.0)
    var visible_after_scroll: int = 0
    for river in all_rivers:
        if not _lines(r, river, main_map, scroll).is_empty():
            visible_after_scroll += 1
    check(visible_after_scroll > 0,
        "после прокрутки реки должны оставаться видимыми (полилиний: %d)"
            % visible_after_scroll, state)

    # --- 5. Отсечение по-прежнему работает ---
    # Река целиком за экраном (в мировых координатах далеко за правым краем)
    # не должна давать ни одной линии.
    var far_river: Array = []
    var far_x: float = screen_rect.size.x - main_map.offset_x + 5000.0
    for i in range(6):
        far_river.append(Vector2(far_x + i * 100.0, 500.0 + i * 40.0))
    check(_lines(r, far_river, main_map).is_empty(),
        "река целиком за экраном не должна рисоваться", state)

    # --- 6. Кэш геометрии не пересобирается на каждом кадре прокрутки ---
    # Пересборка кэша (сглаживание + обрезка) — самая дорогая часть отрисовки рек:
    # раньше она шла КАЖДЫЙ кадр прокрутки. Теперь геометрия живёт до тех пор, пока
    # карта не уедет от запомненного сдвига дальше, чем на MAP_CACHE_MARGIN.
    # Считаем настоящие пересборки по счётчику рендерера и сравниваем с числом
    # кадров: пересборок должно быть МНОГОКРАТНО меньше.
    main_map.scroll_offset = Vector2.ZERO
    r.queue_redraw_for_scroll()
    r._flush_scroll_cache_invalidation()
    r._build_river_frame_cache(radius)          # строим кэш для нулевого сдвига
    var rebuilds_before: int = r._river_frame_rebuilds
    # Шаг заведомо меньше запаса, кадров хватает на несколько запасов прокрутки:
    # без кэша пересборка была бы на КАЖДОМ кадре (= steps).
    var steps: int = 20
    var step_px: float = main_map.MAP_CACHE_MARGIN / 3.0
    for i in range(1, steps + 1):
        main_map.scroll_offset = Vector2(float(i) * step_px, 0.0)
        r.queue_redraw_for_scroll()
        r._flush_scroll_cache_invalidation()
        r._build_river_frame_cache(radius)
    var rebuilds: int = r._river_frame_rebuilds - rebuilds_before
    check(rebuilds < steps,
        "кэш геометрии рек не должен пересобираться на каждом кадре прокрутки (пересборок %d за %d кадров)"
            % [rebuilds, steps], state)
    # Прокрутка на несколько запасов вперёд обязана пересобирать кэш (иначе на новом
    # месте реки рисовались бы по старому, уже уехавшему прямоугольнику обрезки).
    var before_far: int = r._river_frame_rebuilds
    main_map.scroll_offset = Vector2(main_map.MAP_CACHE_MARGIN * 4.0, 0.0)
    r.queue_redraw_for_scroll()
    r._flush_scroll_cache_invalidation()
    r._build_river_frame_cache(radius)
    check(r._river_frame_rebuilds > before_far,
        "прокрутка за пределы запаса должна пересобирать геометрию рек", state)

    # --- 7. Точки кэша — мировые, сдвиг применяется на отрисовке ---
    # Иначе прокрутка внутри запаса показывала бы реку не там, где она есть.
    r._river_frame_cache.clear()
    main_map.scroll_offset = Vector2.ZERO
    r.queue_redraw_for_scroll()
    r._flush_scroll_cache_invalidation()
    r._build_river_frame_cache(radius)
    var cache_offset_zero = r._river_frame_cache_offset
    check(cache_offset_zero.x == main_map.offset_x and cache_offset_zero.y == main_map.offset_y,
        "кэш должен запоминать сдвиг, для которого построен (получено %s, ожидался %s)"
            % [str(cache_offset_zero), str(Vector2(main_map.offset_x, main_map.offset_y))],
        state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("RIVER RENDERING TEST FAILED")
        quit(1)
    else:
        print("RIVER RENDERING TEST OK")
        quit(0)

# Пробные сдвиги карты: центрируем камеру на середине каждой реки. Кэш отрисовки
# покрывает экран с запасом MAP_CACHE_MARGIN, а вне него реки рисуются только
# после пересборки — пробы дают гарантию, что хотя бы одна река попадёт в кадр.
func _candidate_scrolls(main_map, rivers: Array) -> Array:
    var out: Array = [Vector2.ZERO]
    for river in rivers:
        if river.is_empty():
            continue
        var mid: Vector2 = river[river.size() / 2]
        out.append(- (mid + Vector2(main_map.offset_x, main_map.offset_y)
            - main_map.map_renderer._get_viewport_size() / 2.0))
    return out

# Полилинии экрана для одной реки — ровно тот путь, который использует
# отрисовка (_draw_river_list -> _build_river_frame_cache. Результат приводится к
# экранным координатам того же сдвига, что и в тесте.
func _lines(r, river: Array, main_map, extra_scroll: Vector2 = Vector2.ZERO) -> Array:
    var offset_x: float = main_map.offset_x + main_map.scroll_offset.x + extra_scroll.x
    var offset_y: float = main_map.offset_y + main_map.scroll_offset.y + extra_scroll.y
    var segments: Array = r._collect_river_segments(river, offset_x, offset_y, main_map.HEX_RADIUS)
    var out: Array = []
    for seg in segments:
        var line: PackedVector2Array = seg["points"]
        var shifted := PackedVector2Array()
        shifted.resize(line.size())
        for i in range(line.size()):
            shifted[i] = line[i] + Vector2(offset_x, offset_y)
        out.append(shifted)
    return out

# Точки полилиний, вышедшие за пределы кэша отрисовки. Готовые линии реки
# обрезаны прямоугольником экрана С ЗАПАСОМ main_map.MAP_CACHE_MARGIN (кэш
# экранного размера), поэтому проверяется он, а не чистый экран. Допуск — ширина
# рисуемой линии: она рисуется с обводкой и мысленно чуть выходит за
# отсечённый прямоугольник.
func _points_outside(lines: Array, screen_rect: Rect2, cache_margin: float) -> Array:
    var margin: float = 16.0 + cache_margin
    var grown := Rect2(
        screen_rect.position - Vector2(margin, margin),
        screen_rect.size + Vector2(margin, margin) * 2.0
    )
    var bad: Array = []
    for line in lines:
        for pt in line:
            if not grown.has_point(pt):
                bad.append(pt)
    return bad

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        state["failed"] = true
        print("FAIL: ", message)