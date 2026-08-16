# map_renderer.gd
@tool
extends Node2D

const CITY_ICON_SIZE = 130
const TERRAIN_ICON_SIZE = 130
const RESOURCE_ICON_SIZE = 80
const IMPROVEMENT_ICON_SIZE = 32

var tile_data = []
var icon_textures = {}
var icon_paths = {}

# Ссылка на главный узел для доступа к offset_x, offset_y, scroll_offset, build_manager и CityData
var main_map: Node

func initialize(td, main_node):
    tile_data = td
    main_map = main_node

# Возвращает словарь с границами видимых гексов (инклюзивно),
# ограниченными границами региона. Используется для viewport culling:
# вместо итерации по всему региону рисуем только те гексы, которые
# пересекают прямоугольник экрана.
func _get_visible_hex_range() -> Dictionary:
    var viewport_size = Vector2(1152, 768)
    if not Engine.is_editor_hint():
        viewport_size = get_viewport_rect().size

    var offset_x = main_map.offset_x + main_map.scroll_offset.x
    var offset_y = main_map.offset_y + main_map.scroll_offset.y

    var radius = main_map.HEX_RADIUS
    var x_spacing = radius * sqrt(3.0)
    var y_spacing = radius * 1.5

    # Прямоугольник viewport в координатах карты (до offset).
    var world_left = - offset_x
    var world_top = - offset_y
    var world_right = world_left + viewport_size.x
    var world_bottom = world_top + viewport_size.y

    # Запас в 2 гекса, чтобы учесть смещение нечётных рядов
    # и частично видимые гексы на границах экрана.
    var margin = 2

    var col_start = int(floor(world_left / x_spacing)) - margin
    var col_end = int(ceil(world_right / x_spacing)) + margin
    var row_start = int(floor(world_top / y_spacing)) - margin
    var row_end = int(ceil(world_bottom / y_spacing)) + margin

    # Ограничиваем границами региона (Кольцо + Регион).
    col_start = max(col_start, main_map.region_start_col)
    col_end = min(col_end, main_map.region_end_col)
    row_start = max(row_start, main_map.region_start_row)
    row_end = min(row_end, main_map.region_end_row)

    return {
        "row_start": row_start,
        "row_end": row_end,
        "col_start": col_start,
        "col_end": col_end
    }

# Проверяет, пересекается ли прямоугольник (в экранных координатах) с viewport.
func _is_rect_visible(rect: Rect2) -> bool:
    var viewport_size = Vector2(1152, 768)
    if not Engine.is_editor_hint():
        viewport_size = get_viewport_rect().size
    var viewport_rect = Rect2(Vector2.ZERO, viewport_size)
    return rect.intersects(viewport_rect)

func build_icon_index():
    icon_paths.clear()
    _scan_folder("res://icons")

func _scan_folder(folder_path: String):
    var dir = DirAccess.open(folder_path)
    if dir == null: return
    dir.list_dir_begin()
    var file_name = dir.get_next()
    while file_name != "":
        if dir.current_is_dir():
            _scan_folder(folder_path.path_join(file_name))
        else:
            var full_path = folder_path.path_join(file_name)
            if icon_paths.has(file_name): print("Предупреждение: дубликат иконки ", file_name)
            icon_paths[file_name] = full_path
        file_name = dir.get_next()
    dir.list_dir_end()

func load_icons():
    icon_textures.clear()
    for res_id in GameData.raw_resources.keys():
        var res = GameData.raw_resources[res_id]
        if res.has("icon"):
            var file_name = res.icon
            if icon_paths.has(file_name):
                icon_textures[file_name] = load(icon_paths[file_name])
    for imp_id in GameData.improvements.keys():
        var imp = GameData.improvements[imp_id]
        if imp.has("icon"):
            var file_name = imp.icon
            if icon_paths.has(file_name):
                icon_textures[file_name] = load(icon_paths[file_name])
    for t_id in GameData.terrains.keys():
        var t = GameData.terrains[t_id]
        if t.has("icon"):
            var file_name = t.icon
            if icon_paths.has(file_name):
                icon_textures[file_name] = load(icon_paths[file_name])
        if t.has("icons"):
            for icon_name in t.icons:
                if icon_paths.has(icon_name):
                    icon_textures[icon_name] = load(icon_paths[icon_name])
    # Покров (cover): загружаем его иконки (оверлеи леса и т.п.)
    for c_id in GameData.covers.keys():
        var c = GameData.covers[c_id]
        if c.has("icons"):
            for icon_name in c.icons:
                if icon_paths.has(icon_name):
                    icon_textures[icon_name] = load(icon_paths[icon_name])
    if icon_paths.has("city.png"):
        icon_textures["city"] = load(icon_paths["city.png"])

func _draw():
    # Вычисляем видимый диапазон гексов (viewport culling): рисуем только те
    # гексы, которые пересекают прямоугольник экрана.
    var visible = _get_visible_hex_range()

    # ФАЗА 1: Рисуем ВИДИМОЕ окно (Кольцо + Регион). Гексы за его пределами
    # скрыты туманом войны (не отрисовываются вовсе).
    for row in range(visible.row_start, visible.row_end + 1):
        for col in range(visible.col_start, visible.col_end + 1):
            _draw_hex(row, col)

    # ФАЗА 1.5: Рисуем уникальную местность (например, содовое озеро soda_lake)
    # ЗА пределами видимого Региона, если она попадает в viewport. Такие гексы
    # отображаются затемнёнными (как неисследованный Регион), чтобы их было видно
    # на фоне тумана войны, но они не раскрывают ресурсы/улучшения.
    for hex_data in main_map.unique_terrain_hexes:
        _draw_unique_terrain_hex(hex_data.row, hex_data.col)

    # ФАЗА 2: Рисуем дороги (ПЕРЕД иконками ресурсов и улучшений)
    _draw_all_roads()

    # ФАЗА 2.75: Рисуем реки
    _draw_rivers()

    # ФАЗА 2.5: Рисуем подсветку для разведки и покупки (всегда активна)
    _draw_exploration_highlights()

    # ФАЗА 3: Рисуем иконки ресурсов, улучшений и другие оверлеи
    for row in range(visible.row_start, visible.row_end + 1):
        for col in range(visible.col_start, visible.col_end + 1):
            _draw_hex_overlays(row, col)

    # ФАЗА 4: Рисуем город в конце
    var offset_pos = Vector2(
        main_map.offset_x + main_map.scroll_offset.x,
        main_map.offset_y + main_map.scroll_offset.y
    )
    var city_center = HexUtils.hex_center(main_map.city_row, main_map.city_col, main_map.HEX_RADIUS) + offset_pos
    if icon_textures.has("city"):
        var tex = icon_textures["city"]
        var icon_rect = Rect2(
            city_center.x - CITY_ICON_SIZE / 2.0,
            city_center.y - CITY_ICON_SIZE / 2.0,
            CITY_ICON_SIZE,
            CITY_ICON_SIZE
        )
        draw_texture_rect(tex, icon_rect, false)
    else:
        var city_vertices = HexUtils.hex_vertices(
            city_center.x, city_center.y, main_map.HEX_RADIUS
        )
        draw_colored_polygon(city_vertices, Color.YELLOW)

    # ФАЗА 5: Рисуем прогресс-бары ПОВЕРХ всего (включая иконку города)
    for row in range(visible.row_start, visible.row_end + 1):
        for col in range(visible.col_start, visible.col_end + 1):
            _draw_progress_bars(row, col)

func _draw_hex(row: int, col: int):
    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    var offset_x = main_map.offset_x + main_map.scroll_offset.x
    var offset_y = main_map.offset_y + main_map.scroll_offset.y
    center.x += offset_x
    center.y += offset_y
    var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)

    var closed_vertices = PackedVector2Array()
    closed_vertices.append_array(vertices)
    closed_vertices.append(vertices[0])

    var tile = tile_data[row][col]
    var in_influence = tile.get("in_influence", false)

    var terrain_color = Color.BLACK
    var terrain = tile.terrain
    var terrain_icon_name = tile.get("terrain_icon", "")

    if row == main_map.city_row and col == main_map.city_col:
        if GameData.terrains.has(terrain):
            var t = GameData.terrains[terrain]
            var c = t.get("color", [0, 0, 0])
            terrain_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
        draw_colored_polygon(vertices, terrain_color)
        draw_polyline(closed_vertices, Color.WHITE, 2, true)
        return

    if terrain_icon_name != "" and icon_textures.has(terrain_icon_name):
        var tex = icon_textures[terrain_icon_name]
        var icon_rect = Rect2(
            center.x - TERRAIN_ICON_SIZE / 2.0,
            center.y - TERRAIN_ICON_SIZE / 2.0,
            TERRAIN_ICON_SIZE,
            TERRAIN_ICON_SIZE
        )
        draw_texture_rect(tex, icon_rect, false)
    else:
        if GameData.terrains.has(terrain):
            var t = GameData.terrains[terrain]
            var c = t.get("color", [0, 0, 0])
            terrain_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
        draw_colored_polygon(vertices, terrain_color)

    # --- Покров (cover): полупрозрачный оверлей поверх terrain ---
    _draw_cover_overlay(row, col, center, vertices)

    if not in_influence:
        draw_colored_polygon(vertices, Color(0, 0, 0, 0.5))

    if main_map.show_hex_borders:
        draw_polyline(closed_vertices, Color.WHITE, 2, true)

# Рисует уникальную местность (например, содовое озеро) ЗА пределами
# видимого Региона (туман войны). Рисуется только рельеф (цвет-заглушка),
# без ресурсов/улучшений/покрова, затемнённый как неисследованный Регион.
func _draw_unique_terrain_hex(row: int, col: int):
    # Если гекс уже входит в видимый Регион, его рисует основной проход
    # (_draw_hex) — здесь пропускаем, чтобы не рисовать дважды.
    if row >= main_map.region_start_row and row <= main_map.region_end_row \
            and col >= main_map.region_start_col and col <= main_map.region_end_col:
        return

    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    center.x += main_map.offset_x + main_map.scroll_offset.x
    center.y += main_map.offset_y + main_map.scroll_offset.y
    var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)

    # Viewport culling: пропускаем, если гекс не пересекает экран.
    if not _is_rect_visible(Rect2(
            center.x - main_map.HEX_RADIUS,
            center.y - main_map.HEX_RADIUS,
            main_map.HEX_RADIUS * 2,
            main_map.HEX_RADIUS * 2)):
        return

    var tile = tile_data[row][col]
    var terrain_id = tile.get("terrain", "plain")
    var terrain_color = Color.BLACK
    if GameData.terrains.has(terrain_id):
        var t = GameData.terrains[terrain_id]
        var c = t.get("color", [0, 0, 0])
        terrain_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)

    draw_colored_polygon(vertices, terrain_color)

    # Затемняем как неисследованный регион (туман войны).
    draw_colored_polygon(vertices, Color(0, 0, 0, 0.5))

    var closed_verts = PackedVector2Array()
    closed_verts.append_array(vertices)
    closed_verts.append(vertices[0])
    if main_map.show_hex_borders:
        draw_polyline(closed_verts, Color.WHITE, 2, true)

# Рисует оверлей покрова (cover) поверх relief.
# Если у покрова есть иконка — рисуем её (детерминированный выбор по seed),
# иначе — полупрозрачный цветной полигон (color + alpha).
func _draw_cover_overlay(row: int, col: int, center: Vector2, vertices: PackedVector2Array):
    var tile = tile_data[row][col]
    var cover_id = tile.get("cover", "none")
    if cover_id == "" or cover_id == "none":
        return
    var cover: Dictionary = GameData.covers.get(cover_id, {})
    if cover.is_empty():
        return

    # Иконка покрова (если есть) — детерминированный выбор, чтобы не мерцало.
    var icon_name = _pick_cover_icon(cover, row, col)
    if icon_name != "" and icon_textures.has(icon_name):
        var tex = icon_textures[icon_name]
        var icon_rect = Rect2(
            center.x - TERRAIN_ICON_SIZE / 2.0,
            center.y - TERRAIN_ICON_SIZE / 2.0,
            TERRAIN_ICON_SIZE,
            TERRAIN_ICON_SIZE
        )
        # Иконка леса обычно непрозрачная — применяем alpha для полупрозрачности.
        var alpha = float(cover.get("alpha", 0.45))
        draw_texture_rect(tex, icon_rect, false, Color(1, 1, 1, alpha))
    else:
        # Фолбек: полупрозрачный цветной полигон.
        var c = cover.get("color", [0, 0, 0])
        var alpha = float(cover.get("alpha", 0.45))
        draw_colored_polygon(vertices, Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0, alpha))

# Возвращает имя иконки покрова для гекса (row, col) — детерминированный выбор.
func _pick_cover_icon(cover: Dictionary, row: int, col: int) -> String:
    var icons: Array = cover.get("icons", [])
    if icons.is_empty():
        return ""
    var icon_rng = RandomNumberGenerator.new()
    icon_rng.seed = row * 1000 + col
    var idx = icon_rng.randi() % icons.size()
    return icons[idx]

# Ресурс виден игроку, если выполнены ОБА условия:
#   1) гекс входит в Кольцо Влияния (территория освоена) или область
#      была исследована разведкой;
#   2) у ресурса НЕТ tech_reveal, либо соответствующая технология уже изучена.
# Иначе ресурс скрыт: иконки нет, в тултипе не упоминается, разведчики
# его «не видят». Это касается подземных ископаемых вроде железа
# (tech_reveal = "mining") — пока mining не изучен, руда на карте есть,
# но игрок о ней не знает.
# Логика вынесена в MapHelpers, чтобы тултип и рендерер не расходились.
func _is_resource_revealed(tile: Dictionary) -> bool:
    return MapHelpers.is_resource_revealed(tile)

func _draw_hex_overlays(row: int, col: int):
    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    center.x += main_map.offset_x + main_map.scroll_offset.x
    center.y += main_map.offset_y + main_map.scroll_offset.y

    var tile = tile_data[row][col]
    var in_influence = tile.get("in_influence", false)

    if row == main_map.city_row and col == main_map.city_col:
        return

    # Ресурсы Региона вне Кольца Влияния скрыты, пока область не разведана.
    # (Прогресс-бары ниже отрисовываются независимо от видимости ресурса.)
    var is_resource_visible = _is_resource_revealed(tile)

    # Рисуем иконку как для природного (tile.resource), так и для разводимого
    # (tile.crop_bred) ресурса — эффективный ресурс берётся из MapHelpers.
    var eff_res = MapHelpers.get_effective_resource(tile)
    if eff_res != "" and is_resource_visible:
        var res_data = GameData.raw_resources.get(eff_res, {})
        var res_icon = res_data.get("icon", "")
        if res_icon != "" and icon_textures.has(res_icon):
            var tex = icon_textures[res_icon]
            var icon_rect = Rect2(center.x - RESOURCE_ICON_SIZE / 2.0, center.y - RESOURCE_ICON_SIZE / 2.0, RESOURCE_ICON_SIZE, RESOURCE_ICON_SIZE)
            draw_texture_rect(tex, icon_rect, false)
        else:
            if res_data.has("color"):
                var c = res_data["color"]
                var fallback_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
                draw_circle(center, RESOURCE_ICON_SIZE / 3.0, fallback_color)

    # Звёздочки качества ресурса — под иконкой, только если ресурс раскрыт
    # и на этом гексе уже построено улучшение, которое раскрывает качество.
    if eff_res != "" and is_resource_visible and tile.improvement != null:
        _draw_quality_stars(tile, center)

    if in_influence and tile.improvement != null:
        var has_worker = main_map.worker_manager.has_worker(row, col)
        var imp_data = GameData.improvements.get(tile.improvement, {})
        var imp_icon = imp_data.get("icon", "")
        var icon_pos = Vector2(center.x, center.y - main_map.HEX_RADIUS * 0.75)
        if imp_icon != "" and icon_textures.has(imp_icon):
            var tex = icon_textures[imp_icon]
            var icon_rect = Rect2(icon_pos.x - IMPROVEMENT_ICON_SIZE / 2.0, icon_pos.y - IMPROVEMENT_ICON_SIZE / 2.0, IMPROVEMENT_ICON_SIZE, IMPROVEMENT_ICON_SIZE)
            if not has_worker:
                draw_texture_rect(tex, icon_rect, false, Color(0.5, 0.5, 0.5))
            else:
                draw_texture_rect(tex, icon_rect, false)
        else:
            if imp_data.has("color"):
                var c = imp_data["color"]
                var fallback_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
                if not has_worker:
                    fallback_color = Color(0.5, 0.5, 0.5)
                draw_circle(icon_pos, IMPROVEMENT_ICON_SIZE / 2.5, fallback_color)

        if tile.improvement == "farm" and main_map._is_hex_irrigated(row, col):
            var drop_center = icon_pos + Vector2(IMPROVEMENT_ICON_SIZE * 0.5 + 6, 0)
            var drop_radius = 6.0
            var drop_points = [
                Vector2(0, -drop_radius),
                Vector2(-drop_radius * 0.7, -drop_radius * 0.2),
                Vector2(-drop_radius * 0.35, drop_radius * 0.8),
                Vector2(0, drop_radius),
                Vector2(drop_radius * 0.35, drop_radius * 0.8),
                Vector2(drop_radius * 0.7, -drop_radius * 0.2)
            ]
            for i in range(drop_points.size()):
                drop_points[i] += drop_center
            draw_polygon(drop_points, [Color(0.45, 0.8, 1.0, 1.0)])

    # --- Конфликт «tech_reveal-ресурс vs чужое улучшение» ---
    # Если на гексе стоит улучшение, а под ним нашли скрытый ресурс (tech_reveal
    # уже изучен, но ресурс не добывается из-за старого улучшения) — рисуем
    # красный треугольник с «!». Само улучшение не сносится: его производство
    # продолжается. Подробности см. в docs.md, «tech_reveal: скрытые ресурсы».
    # Показываем треугольник ТОЛЬКО когда ресурс уже видим (после tech_reveal),
    # иначе игрок не понимает, на что ругается значок.
    var conflict = MapHelpers.get_tech_reveal_conflict(tile)
    if not conflict.is_empty() and is_resource_visible:
        _draw_tech_reveal_warning(center)

# Рисует звёздочки качества ресурса под его иконкой.
# Только для раскрытых ресурсов после постройки улучшения. Если качество не задано
# или равно "common" — ничего не рисуем.
func _draw_quality_stars(tile: Dictionary, center: Vector2):
    var quality = tile.get("quality", "")
    if quality == "" or quality == null or quality == "common":
        return
    var levels = GameData.get_quality_levels()
    if levels.is_empty():
        return
    # Определяем индекс качества в списке уровней (от худшего к лучшему).
    var quality_index = levels.find(quality)
    if quality_index < 0:
        return
    # Количество «полных» звёзд = индекс + 1 (первый уровень = 1 звезда).
    var stars_count = quality_index + 1
    # Максимум звёзд = количество уровней качества.
    var max_stars = levels.size()

    var star_outer = 5.5
    var star_inner = 2.5
    var spacing = 11.0
    var start_x = center.x - (stars_count * spacing - spacing) / 2.0
    var star_y = center.y + RESOURCE_ICON_SIZE / 2.0 + 4

    for i in range(max_stars):
        var star_cx = start_x + i * spacing
        if i < stars_count:
            # Заполненная звезда — золотисто-жёлтая
            _draw_star(star_cx, star_y, star_outer, star_inner, Color(1.0, 0.85, 0.2, 0.9))
        else:
            # Пустая звезда — серо-белая
            _draw_star_outline(star_cx, star_y, star_outer, star_inner, Color(0.5, 0.5, 0.5, 0.6))

# Рисует красный треугольник с «!» в правом верхнем углу гекса — индикатор
# конфликта «tech_reveal-ресурс найден под чужим улучшением». Позиция
# специально выбрана так, чтобы не перекрывать иконку ресурса по центру
# и иконку улучшения сверху, но попадать в поле зрения.
# Сама фигура — залитый красный треугольник + белая обводка + «!»
# посередине (через draw_string). Без внешних ресурсов и шрифтов.
func _draw_tech_reveal_warning(center: Vector2):
    # Размеры треугольника в пикселях.
    var tri_size := 18.0
    # Центр треугольника — в правом верхнем углу гекса, чуть ближе к центру,
    # чтобы значок не вылезал за гекс и не терялся на фоне соседних.
    var cx = center.x + main_map.HEX_RADIUS * 0.55
    var cy = center.y - main_map.HEX_RADIUS * 0.55
    # Вершины равностороннего треугольника, направленного вверх.
    var pts = PackedVector2Array()
    pts.append(Vector2(cx, cy - tri_size * 0.6))
    pts.append(Vector2(cx - tri_size * 0.55, cy + tri_size * 0.45))
    pts.append(Vector2(cx + tri_size * 0.55, cy + tri_size * 0.45))
    draw_colored_polygon(pts, Color(0.85, 0.15, 0.15, 0.95))
    # Белая обводка по тому же контуру.
    var border = PackedVector2Array()
    border.append_array(pts)
    border.append(pts[0])
    draw_polyline(border, Color.WHITE, 1.5, true)
    # «!» — рисуем как короткий столбик и точку под ним. Используем
    # стандартный шрифт через draw_string, чтобы не зависеть от ассетов.
    var font = ThemeDB.fallback_font
    if font == null:
        return
    var font_size := 13
    var text := "!"
    var text_size = font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
    var text_pos = Vector2(cx - text_size.x / 2.0, cy + text_size.y / 2.0 - 1)
    draw_string(font, text_pos, text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE)

# Рисует заполненную (сложную) звезду.
func _draw_star(cx: float, cy: float, r_outer: float, r_inner: float, color: Color):
    var points = PackedVector2Array()
    for i in range(5):
        var angle = deg_to_rad(i * 72.0 - 90.0)
        var outer = Vector2(cx + cos(angle) * r_outer, cy + sin(angle) * r_outer)
        points.append(outer)
        var inner_angle = deg_to_rad(i * 72.0 + 36.0 - 90.0)
        var inner = Vector2(cx + cos(inner_angle) * r_inner, cy + sin(inner_angle) * r_inner)
        points.append(inner)
    draw_colored_polygon(points, color)

# Рисует контур звезды (пустая/незаполненная).
func _draw_star_outline(cx: float, cy: float, r_outer: float, r_inner: float, color: Color):
    var points = PackedVector2Array()
    for i in range(5):
        var angle = deg_to_rad(i * 72.0 - 90.0)
        points.append(Vector2(cx + cos(angle) * r_outer, cy + sin(angle) * r_outer))
        var inner_angle = deg_to_rad(i * 72.0 + 36.0 - 90.0)
        points.append(Vector2(cx + cos(inner_angle) * r_inner, cy + sin(inner_angle) * r_inner))
    var closed = PackedVector2Array()
    closed.append_array(points)
    closed.append(points[0])
    draw_polyline(closed, color, 1.5)

func _draw_progress_bars(row: int, col: int):
    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    center.x += main_map.offset_x + main_map.scroll_offset.x
    center.y += main_map.offset_y + main_map.scroll_offset.y

    var tile = tile_data[row][col]

    # Прогресс-бар исследования технологии, которая открывает:
    # 1) сам ресурс (tech_required), либо
    # 2) улучшение, которым добывается этот ресурс (improved_by → unlock_tech)
    # Бар показываем и для природного ресурса, и для разводимого: если игрок
    # ещё не изучил нужную технологию, прогресс-бар на гексе подскажет,
    # какую из технологий имеет смысл качать.
    var research_tech = CityData.current_research_tech_id
    var eff_res_for_bar = MapHelpers.get_effective_resource(tile)
    if research_tech != "" and eff_res_for_bar != "" and _is_resource_revealed(tile):
        var show_progress = false
        if _is_resource_locked(eff_res_for_bar):
            var res_tech = GameData.raw_resources.get(eff_res_for_bar, {}).get("tech_required", "")
            if res_tech == research_tech:
                show_progress = true
        else:
            # Ресурс открыт, но улучшение для него ещё не изучено
            var imp_id = GameData.raw_resources.get(eff_res_for_bar, {}).get("improved_by", "")
            if imp_id != null and imp_id != "" and not CityData.is_improvement_unlocked(imp_id):
                var imp_unlock_tech = CityData.get_improvement_unlock_tech(imp_id)
                if imp_unlock_tech == research_tech:
                    show_progress = true
        if show_progress:
            var bar_width = RESOURCE_ICON_SIZE
            var bar_height = 6
            var bar_x = center.x - bar_width / 2.0
            var bar_y = center.y + RESOURCE_ICON_SIZE / 2.0 + 4
            draw_rect(Rect2(bar_x, bar_y, bar_width, bar_height), Color(0.2, 0.2, 0.2))
            var fill_width = bar_width * CityData.research_progress
            draw_rect(Rect2(bar_x, bar_y, fill_width, bar_height), Color.GREEN)
            draw_rect(Rect2(bar_x, bar_y, bar_width, bar_height), Color.WHITE, false)

    if main_map.build_manager.is_building(row, col):
        var progress_data = main_map.build_manager.get_progress(row, col)
        if not progress_data.is_empty():
            var bar_width = RESOURCE_ICON_SIZE
            var bar_height = 6
            var bar_x = center.x - bar_width / 2.0
            var bar_y = center.y + RESOURCE_ICON_SIZE / 2.0 + 10
            draw_rect(Rect2(bar_x, bar_y, bar_width, bar_height), Color(0.2, 0.2, 0.2))
            var work_cost = progress_data.get("work_cost", 1.0)
            var progress = progress_data.get("progress", 0.0)
            var fill_width = bar_width * clamp(progress / work_cost, 0.0, 1.0)
            draw_rect(Rect2(bar_x, bar_y, fill_width, bar_height), Color.YELLOW)
            draw_rect(Rect2(bar_x, bar_y, bar_width, bar_height), Color.WHITE, false)

    # --- Прогресс-бар разведки чанка ---
    # Рисуем только ОДИН бар на центральном гексе чанка (с которого началась разведка),
    # чтобы не перегружать карту избыточными барами на каждом гексе чанка.
    if main_map.is_scouting and not main_map.scouting_chunk.is_empty():
        var scout_center_hex = main_map.scouting_chunk[0]
        if scout_center_hex.row == row and scout_center_hex.col == col:
            var scout_progress = clamp(main_map.scouting_timer / (main_map.scouting_chunk.size() * main_map.SCOUTING_TIME_PER_HEX), 0.0, 1.0)
            var scout_bar_width = RESOURCE_ICON_SIZE
            var scout_bar_height = 6
            var scout_bar_x = center.x - scout_bar_width / 2.0
            var scout_bar_y = center.y + RESOURCE_ICON_SIZE / 2.0 + 16 # ниже бара сбора дикоросов
            draw_rect(Rect2(scout_bar_x, scout_bar_y, scout_bar_width, scout_bar_height), Color(0.2, 0.2, 0.2))
            draw_rect(Rect2(scout_bar_x, scout_bar_y, scout_bar_width * scout_progress, scout_bar_height), Color(0.2, 0.7, 0.9))
            draw_rect(Rect2(scout_bar_x, scout_bar_y, scout_bar_width, scout_bar_height), Color.WHITE, false)


func _is_resource_locked(resource_id: String) -> bool:
    if resource_id == null or resource_id == "":
        return false
    var res_data = GameData.raw_resources.get(resource_id, {})
    if not res_data.has("tech_required"):
        return false
    return not CityData.is_tech_unlocked(res_data["tech_required"])

func is_resource_locked(resource_id: String) -> bool:
    return _is_resource_locked(resource_id)

func _draw_all_roads():
    if main_map == null or not main_map.has_method("get"):
        return
    if not main_map.has_node("RoadManager"):
        return

    var road_manager = main_map.get_node("RoadManager")
    var all_segments = road_manager.get_all_road_segments()
    
    if all_segments.is_empty():
        return
    
    for segment_key in all_segments.keys():
        var parts = segment_key.split("|")
        if parts.size() != 2:
            continue
        
        var start_parts = parts[0].split(",")
        var end_parts = parts[1].split(",")
        
        if start_parts.size() != 2 or end_parts.size() != 2:
            continue
        
        var row1 = int(start_parts[0])
        var col1 = int(start_parts[1])
        var row2 = int(end_parts[0])
        var col2 = int(end_parts[1])

        # Viewport culling: пропускаем сегменты дорог, которые не пересекают экран.
        var c1 = HexUtils.hex_center(row1, col1, main_map.HEX_RADIUS)
        c1.x += main_map.offset_x + main_map.scroll_offset.x
        c1.y += main_map.offset_y + main_map.scroll_offset.y
        var c2 = HexUtils.hex_center(row2, col2, main_map.HEX_RADIUS)
        c2.x += main_map.offset_x + main_map.scroll_offset.x
        c2.y += main_map.offset_y + main_map.scroll_offset.y
        var road_rect = Rect2(
            min(c1.x, c2.x) - main_map.HEX_RADIUS,
            min(c1.y, c2.y) - main_map.HEX_RADIUS,
            abs(c2.x - c1.x) + main_map.HEX_RADIUS * 2,
            abs(c2.y - c1.y) + main_map.HEX_RADIUS * 2
        )
        if not _is_rect_visible(road_rect):
            continue

        var points = _generate_natural_road(row1, col1, row2, col2, main_map.HEX_RADIUS)
        draw_polyline(points, Color(0.55, 0.35, 0.15), 6, true)

func _draw_rivers():
    if main_map == null:
        return
    if not main_map.has_node("RiverManager"):
        return
    var river_manager = main_map.get_node("RiverManager")
    var offset_x = main_map.offset_x + main_map.scroll_offset.x
    var offset_y = main_map.offset_y + main_map.scroll_offset.y
    var radius = main_map.HEX_RADIUS

    # Главные реки — толще и темнее.
    _draw_river_list(river_manager.get_main_rivers(), offset_x, offset_y, radius,
            river_manager.RIVER_SHORE_COLOR, river_manager.RIVER_SHORE_WIDTH,
            river_manager.RIVER_COLOR, river_manager.RIVER_WIDTH,
            river_manager.RIVER_HIGHLIGHT_COLOR, river_manager.RIVER_HIGHLIGHT_WIDTH)

    # Притоки — тоньше и светлее, чтобы визуально отличать от главных рек.
    _draw_river_list(river_manager.get_tributaries(), offset_x, offset_y, radius,
            river_manager.TRIBUTARY_SHORE_COLOR, river_manager.TRIBUTARY_SHORE_WIDTH,
            river_manager.TRIBUTARY_COLOR, river_manager.TRIBUTARY_WIDTH,
            river_manager.TRIBUTARY_HIGHLIGHT_COLOR, river_manager.TRIBUTARY_HIGHLIGHT_WIDTH)


# Рисует список рек с заданным стилем (берег, тело, блик).
# Реки обрезаются по границе видимой области (Кольцо + Регион), чтобы не
# отрисовываться сквозь туман войны за её пределами.
func _draw_river_list(river_list: Array, offset_x: float, offset_y: float, radius: float,
        shore_color: Color, shore_width: float,
        body_color: Color, body_width: float,
        highlight_color: Color, highlight_width: float):
    for river in river_list:
        if river.size() < 2:
            continue

        # Viewport culling: пропускаем реки, которые не пересекают экран.
        var min_x = INF
        var max_x = - INF
        var min_y = INF
        var max_y = - INF
        for pt in river:
            var px = pt.x + offset_x
            var py = pt.y + offset_y
            min_x = min(min_x, px)
            max_x = max(max_x, px)
            min_y = min(min_y, py)
            max_y = max(max_y, py)
        var river_rect = Rect2(
            min_x - radius,
            min_y - radius,
            (max_x - min_x) + radius * 2,
            (max_y - min_y) + radius * 2
        )
        if not _is_rect_visible(river_rect):
            continue

        # Собираем точки реки в экранных координатах.
        var points = PackedVector2Array()
        for pt in river:
            points.append(Vector2(pt.x + offset_x, pt.y + offset_y))

        # Сначала строим естественные меандры по полной реке, затем обрезаем
        # сглаженную линию по видимой области. Так волны остаются непрерывными
        # на границе, а за ней река не рисуется (скрыта туманом войны).
        var smooth_points = _generate_natural_river(points, radius)
        var region_rect = _get_region_world_rect()
        region_rect.position += Vector2(offset_x, offset_y)
        var clipped_lines = _clip_river_to_rect(smooth_points, region_rect)
        if clipped_lines.is_empty():
            continue

        for line in clipped_lines:
            if line.size() < 2:
                continue
            draw_polyline(line, shore_color, shore_width, true)
            draw_polyline(line, body_color, body_width, true)
            draw_polyline(line, highlight_color, highlight_width, true)


# Возвращает прямоугольник видимой области (Кольцо + Регион) в world-координатах
# (без учёта offset). Строится по центрам крайних гексов региона с запасом на
# пол-гекса, чтобы клиппинг рек совпадал с видимой границей.
func _get_region_world_rect() -> Rect2:
    var radius = main_map.HEX_RADIUS
    var c_tl = HexUtils.hex_center(main_map.region_start_row, main_map.region_start_col, radius)
    var c_tr = HexUtils.hex_center(main_map.region_start_row, main_map.region_end_col, radius)
    var c_bl = HexUtils.hex_center(main_map.region_end_row, main_map.region_start_col, radius)
    var c_br = HexUtils.hex_center(main_map.region_end_row, main_map.region_end_col, radius)
    var left = min(c_tl.x, c_bl.x) - radius
    var right = max(c_tr.x, c_br.x) + radius
    var top = min(c_tl.y, c_tr.y) - radius
    var bottom = max(c_bl.y, c_br.y) + radius
    return Rect2(left, top, right - left, bottom - top)


# Обрезает отрезок (start -> end) по прямоугольнику rect (алгоритм Лиан–Барски).
# Возвращает [Vector2, Vector2] для видимой части или [] если отрезок вне rect.
func _clip_segment_to_rect(start: Vector2, end: Vector2, rect: Rect2) -> Array:
    var t0 = 0.0
    var t1 = 1.0
    var dx = end.x - start.x
    var dy = end.y - start.y
    var p = [-dx, dx, -dy, dy]
    var q = [
        start.x - rect.position.x,
        rect.position.x + rect.size.x - start.x,
        start.y - rect.position.y,
        rect.position.y + rect.size.y - start.y
    ]
    for i in range(4):
        if abs(p[i]) < 1e-9:
            if q[i] < 0.0:
                return []
        else:
            var r = q[i] / p[i]
            if p[i] < 0.0:
                if r > t1:
                    return []
                if r > t0:
                    t0 = r
            else:
                if r < t0:
                    return []
                if r < t1:
                    t1 = r
    return [start + (end - start) * t0, start + (end - start) * t1]


# Обрезает полилинию по прямоугольнику rect. Возвращает массив обрезанных
# полилиний (каждая — PackedVector2Array), объединяя смежные сегменты в
# непрерывные линии.
func _clip_river_to_rect(points: PackedVector2Array, rect: Rect2) -> Array:
    if points.size() < 2:
        return []
    var segments: Array = []
    for i in range(points.size() - 1):
        var clipped = _clip_segment_to_rect(points[i], points[i + 1], rect)
        if clipped.size() == 2:
            segments.append(clipped)
    if segments.is_empty():
        return []

    var polylines: Array = []
    var current = PackedVector2Array()
    current.append(segments[0][0])
    current.append(segments[0][1])
    for i in range(1, segments.size()):
        var seg = segments[i]
        if current[-1].distance_to(seg[0]) < 0.01:
            current.append(seg[1])
        else:
            polylines.append(current)
            current = PackedVector2Array()
            current.append(seg[0])
            current.append(seg[1])
    polylines.append(current)
    return polylines

func _draw_roads(_row: int, _col: int):
    pass

func _generate_natural_road(
    row1: int,
    col1: int,
    row2: int,
    col2: int,
    radius: float
) -> Array:
    var segments = 3
    var points = []
    var main = get_parent()
    var center1 = HexUtils.hex_center(row1, col1, radius)
    center1.x += main.offset_x + main.scroll_offset.x
    center1.y += main.offset_y + main.scroll_offset.y
    var center2 = HexUtils.hex_center(row2, col2, radius)
    center2.x += main.offset_x + main.scroll_offset.x
    center2.y += main.offset_y + main.scroll_offset.y
    
    points.append(center1)
    for i in range(1, segments):
        var t = float(i) / segments
        var mid = center1.lerp(center2, t)
        var dir = (center2 - center1).normalized()
        var perp = Vector2(-dir.y, dir.x)
        var hash_input = (
            row1 * 73856093 + col1 * 19349663 + row2 * 83492791
        ) & 0x7fffffff
        var hash_val = float(hash_input) / 0x7fffffff
        var offset = (hash_val - 0.5) * radius * 0.5
        mid += perp * offset
        points.append(mid)
    points.append(center2)
    return points

func _generate_natural_river(river_points: PackedVector2Array, radius: float) -> PackedVector2Array:
    if river_points.size() < 2:
        return river_points

    var sample_step = max(radius * 0.22, 8.0)
    var amplitude = max(radius * 0.16, 7.0)
    var frequency = 0.9 / max(sample_step, 1.0)
    var phase = 0.45 + float(river_points.size()) * 0.12

    var curved_points = PackedVector2Array()
    var total_length = 0.0
    var segment_lengths: Array = []

    for i in range(river_points.size() - 1):
        var seg_len = river_points[i].distance_to(river_points[i + 1])
        segment_lengths.append(seg_len)
        total_length += seg_len

    if total_length <= 0.0:
        return river_points

    var distance_along = 0.0
    for i in range(river_points.size() - 1):
        var start = river_points[i]
        var end = river_points[i + 1]
        var segment_dir = end - start
        var segment_len = segment_dir.length()
        if segment_len <= 0.0001:
            continue

        segment_dir = segment_dir.normalized()
        var normal = Vector2(-segment_dir.y, segment_dir.x)

        var step_count = max(1, int(ceil(segment_len / sample_step)))
        for step in range(step_count + 1):
            var t = float(step) / float(step_count)
            var base_point = start.lerp(end, t)
            var local_distance = distance_along + segment_len * t

            var offset = Vector2.ZERO
            if step != 0 and step != step_count:
                var meander = sin(local_distance * frequency + phase) * amplitude
                var secondary = sin(local_distance * frequency * 0.55 + phase * 1.7) * amplitude * 0.35
                var bend = 0.0
                if i > 0 and i + 1 < river_points.size() - 1:
                    var prev_dir = (start - river_points[i - 1]).normalized()
                    var next_dir = (river_points[i + 2] - end).normalized()
                    var turn_strength = clamp(1.0 - prev_dir.dot(next_dir), 0.0, 1.0)
                    var turn_sign = sign(prev_dir.cross(next_dir))
                    if turn_sign == 0:
                        turn_sign = 1.0
                    bend = turn_strength * amplitude * 0.18 * turn_sign

                offset = normal * (meander + secondary + bend)

            var point = base_point + offset
            if curved_points.is_empty() or curved_points[-1].distance_to(point) > 0.5:
                curved_points.append(point)

        distance_along += segment_len

    if curved_points.size() < 2:
        return river_points

    # Применяем 1-2 итерации сглаживания — достаточно, чтобы убрать острые
    # углы, но сохранить общую форму и меандрирование. Реализация
    # вынесена в отдельную функцию ниже.
    return _chaikin_smooth(curved_points, 2)

func _draw_exploration_highlights():
    var main = get_parent()
    var expansion_manager = main.get_node("ExpansionManager")
    if not expansion_manager:
        return

    # --- 1. Рисуем слои: не исследован / исследован (всегда) ---
    var visible = _get_visible_hex_range()
    for row in range(visible.row_start, visible.row_end + 1):
        for col in range(visible.col_start, visible.col_end + 1):
            var tile = tile_data[row][col]
            if tile.get("in_influence", false):
                continue

            var is_explored = tile.get("is_explored", false)

            var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
            center.x += main.offset_x + main.scroll_offset.x
            center.y += main.offset_y + main.scroll_offset.y
            var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)

            if is_explored:
                # Исследован: светло-зелёный + белая рамка
                draw_colored_polygon(vertices, Color(0.652, 0.855, 0.652, 0.25))
                var closed_verts = PackedVector2Array()
                closed_verts.append_array(vertices)
                closed_verts.append(vertices[0])
                draw_polyline(closed_verts, Color.WHITE, 1.5)

    # --- 2. Жёлтая подсветка чанка под мышью (поверх всего) ---
    var chunk = expansion_manager.current_chunk
    if chunk.is_empty():
        return

    for hex in chunk:
        var center = HexUtils.hex_center(hex.row, hex.col, main_map.HEX_RADIUS)
        center.x += main.offset_x + main.scroll_offset.x
        center.y += main.offset_y + main.scroll_offset.y
        var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)
        draw_colored_polygon(vertices, Color(1.0, 1.0, 0.0, 0.3))
        var closed_verts = PackedVector2Array()
        closed_verts.append_array(vertices)
        closed_verts.append(vertices[0])
        draw_polyline(closed_verts, Color.YELLOW, 2.0)

func get_icon_path(icon_name: String) -> String:
    if icon_paths.has(icon_name):
        return icon_paths[icon_name]
    return ""


func _chaikin_smooth(points: PackedVector2Array, iterations: int) -> PackedVector2Array:
    if points.size() < 2:
        return points
    var current = points
    for _it in range(iterations):
        var next_pts = PackedVector2Array()
        next_pts.append(current[0])
        for j in range(current.size() - 1):
            var p0 = current[j]
            var p1 = current[j + 1]
            var q = p0 * 0.75 + p1 * 0.25
            var r = p0 * 0.25 + p1 * 0.75
            next_pts.append(q)
            next_pts.append(r)
        next_pts.append(current[-1])
        current = next_pts
    return current
