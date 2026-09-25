# map_renderer.gd
@tool
extends Node2D

const CITY_ICON_SIZE = 130
const TERRAIN_ICON_SIZE = 130
const RESOURCE_ICON_SIZE = 75
const IMPROVEMENT_ICON_SIZE = 35
# Толщина контура границ кольца влияния городков (в пикселях).
const TOWN_INFLUENCE_BORDER_WIDTH = 3.0
# Прозрачность заливки территории городков.
const TOWN_INFLUENCE_FILL_ALPHA = 0.22

var tile_data = []
var icon_textures = {}
var icon_paths = {}

# Ссылка на главный узел для доступа к offset_x, offset_y, scroll_offset, build_manager и CityData
var main_map: Node

# Кэш сглаженных (меандровых) точек рек в МИРОВЫХ координатах (без offset).
# Сглаживание рек (_generate_natural_river + _chaikin_smooth) — дорогая операция,
# которая раньше выполнялась каждый кадр при прокрутке карты. Точки рек в мировых
# координатах не меняются при панорамировании, поэтому пересчёт нужен лишь один раз
# на реку. При прокрутке к сглаженным мировым точкам достаточно прибавить offset
# и выполнить клиппинг. Ключ кэша — компактная сериализация координат реки.
var _river_smooth_cache: Dictionary = {}

# --- Кэш рендера колец влияния городков (PHASE 1.7 / 1.7.1) ---
# Кольца городков статичны между спавном/загрузкой/сменой эпохи, но раньше
# пересчитывались И рисовались каждый кадр: сотни полупрозрачных
# draw_colored_polygon (по одному на гекс, с тригонометрией на каждый гекс
# и каждое ребро) + аллокация словарей membership на каждый городок. При
# пересечении колец общие гексы рисовались по N раз (N = число городков),
# что дополнительно усиливало прозрачность и повышало нагрузку.
#
# Теперь весь рендер-кэш строится один раз и пересобирается только при
# invalidate_town_influence_cache() либо при изменении видимого Региона
# (смена эпохи). За кадр остаётся: один draw_texture_rect для заливки и
# лёгкие кэшированные draw_line для границ.
var _town_cache_version: int = 0
var _town_cache_built_version: int = -1
# Регионные границы, для которых построен текущий кэш. Если кэш построен
# до смены эпохи (Регион расширился) — он невалиден и пересобирается.
var _cache_region_start_row: int = -1
var _cache_region_end_row: int = -1
var _cache_region_start_col: int = -1
var _cache_region_end_col: int = -1
# Уникальные гексы колец ВСЕХ городков (без дублей) в мировых координатах.
# Каждая запись — { "cx": float, "cy": float } — центр гекса без offset.
var _influence_fill_centers: Array = []
# Отрезки границ колец в мировых координатах (без offset). Каждая запись —
# { "p1": Vector2, "p2": Vector2, "color": Color, "row": int, "col": int }.
var _influence_border_segments: Array = []
# Шаг 2: пре-рендер заливки колец в ОДНУ RGBA-текстуру, покрывающую текущий
# Регион (Кольцо + Регион). Кадровый рендер заливки = один draw_texture_rect
# вместо сотен полупрозрачных полигонов. Пересоздаётся при инвалидации кэша.
var _influence_fill_texture: ImageTexture = null
var _influence_texture_origin: Vector2 = Vector2.ZERO
var _influence_texture_size: Vector2 = Vector2.ZERO

func initialize(td, main_node):
    tile_data = td
    main_map = main_node
    # Очищаем кэш рек при инициализации (новая игра / загрузка сохранения),
    # чтобы не держать устаревшие сглаженные точки от предыдущей карты.
    _river_smooth_cache.clear()
    # Кольца городков могли измениться (новая карта / загрузка сейва):
    # сбрасываем кэш их рендера — пересоберётся лениво со следующим кадром.
    invalidate_town_influence_cache()

# Возвращает размер viewport в пикселях. В редакторе get_viewport_rect()
# недоступен (нет окна игры) — используем запасное значение, как и раньше.
func _get_viewport_size() -> Vector2:
    if Engine.is_editor_hint():
        return Vector2(1152, 768)
    return get_viewport_rect().size

# Возвращает словарь с границами видимых гексов (инклюзивно),
# ограниченными областью, достижимой скроллом карты (scout_reach).
# Используется для viewport culling: вместо итерации по всей карте
# рисуем только те гексы, которые пересекают прямоугольник экрана.
#
# Область шире Региона — это нужно для двух сценариев:
#   1. После разведки гексы в тумане войны (вне Региона) должны
#      отрисовываться как обычные — туман «раскрывается», иначе
#      разведка не даёт визуального эффекта. За Регионом это возможно
#      только после изучения Картографии (см. main_map.is_hex_interactive).
#   2. Прогресс-бар разведки может лежать в тумане (стартовый гекс
#      чанка не обязан быть в Регионе) — это тоже доступно лишь
#      после Картографии.
# `_draw_hex` и `_draw_hex_overlays` сами решают, что рисовать:
# неисследованные гексы вне Региона — это настоящий туман войны, и
# для них функция просто выходит раньше времени.
func _get_visible_hex_range() -> Dictionary:
    var viewport_size = _get_viewport_size()

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

    # Ограничиваем областью, достижимой скроллом карты (scout_reach).
    var reach = main_map.get_scout_reach_bounds()
    col_start = max(col_start, reach.col_start)
    col_end = min(col_end, reach.col_end)
    row_start = max(row_start, reach.row_start)
    row_end = min(row_end, reach.row_end)

    return {
        "row_start": row_start,
        "row_end": row_end,
        "col_start": col_start,
        "col_end": col_end
    }

# Проверяет, пересекается ли прямоугольник (в экранных координатах) с viewport.
func _is_rect_visible(rect: Rect2) -> bool:
    var viewport_rect = Rect2(Vector2.ZERO, _get_viewport_size())
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
    for tech in GameData.technologies:
        if tech.has("icon"):
            var file_name = tech.icon
            if icon_paths.has(file_name):
                icon_textures[file_name] = load(icon_paths[file_name])
    # Покров (cover): загружаем его иконки (оверлеи леса и т.п.)
    for c_id in GameData.covers.keys():
        var c = GameData.covers[c_id]
        if c.has("icons"):
            for icon_name in c.icons:
                if icon_paths.has(icon_name):
                    icon_textures[icon_name] = load(icon_paths[icon_name])
    if icon_paths.has("city.png"):
        icon_textures["city"] = load(icon_paths["city.png"])
        # Ключ "city.png" нужен рендереру городков (town_manager.TOWN_ICON_NAME),
        # чтобы достать ту же текстуру по «полному» имени файла.
        icon_textures["city.png"] = icon_textures["city"]
    if icon_paths.has("lock.png"):
        icon_textures["lock.png"] = load(icon_paths["lock.png"])

func _draw():
    # Вычисляем видимый диапазон гексов (viewport culling): рисуем только те
    # гексы, которые пересекают прямоугольник экрана.
    var visible = _get_visible_hex_range()

    # ФАЗА 1: Рисуем все гексы, попавшие на экран в пределах досягаемости
    # скролла. Гексы Региона — детально, неисследованные гексы за его
    # пределами (туман войны) не рисуются вовсе (см. _draw_hex). Разведанные
    # гексы вне Региона рисуются затемнёнными: их можно выделить и отправить
    # туда разведчиков — но только после изучения Картографии. Совсем за
    # пределами досягаемости скролла не рисуется ничего (см.
    # _get_visible_hex_range).
    for row in range(visible.row_start, visible.row_end + 1):
        for col in range(visible.col_start, visible.col_end + 1):
            _draw_hex(row, col)

    # ПРИМЕЧАНИЕ: гексы вне Региона (туман войны) рисует тот же проход
    # ФАЗЫ 1 — они затемнены в _draw_hex, а их содержимое (ресурсы,
    # улучшения, кольца городков) скрыто. Отдельные проходы для уникальной
    # местности и городков за пределами Региона больше не нужны: их
    # поведение перенесено в _draw_hex и _draw_hex_overlays (иконка городка
    # в тумане — полупрозрачная и без имени, и только с эпохи >= 1).

    # ФАЗА 1.7: Кольца влияния городков — полупрозрачная голубая заливка.
    # Рисуется ПОСЛЕ terrain (фаза 1), но ДО дорог, рек и иконок
    # (2/2.5/2.75/3) — чтобы заливка подсвечивала местность и не перекрывала
    # важные детали. По договорённости с пользователем кольца видны ТОЛЬКО
    # в пределах Региона (см. _get_region_visible_range): за туманом войны они
    # не рисуются, чтобы не «выдавать» содержимое неисследованной территории,
    # хотя сам туман войны теперь отрисовывается и доступен для разведки.
    _draw_town_influence(visible)
    # ФАЗА 1.7.1: границы колец городков — каждая своим цветом. Рисуются
    # сразу после заливки (поверх неё, поверх terrain), но до дорог/рек/
    # иконок: контур должен быть виден, не перекрывая содержимое гексов.
    _draw_town_influence_borders(visible)

    # ФАЗА 2: Рисуем дороги (ПЕРЕД иконками ресурсов и улучшений)
    _draw_all_roads()

    # ФАЗА 2.75: Рисуем реки
    _draw_rivers()

    # ФАЗА 2.5: Рисуем подсветку для разведки и покупки (всегда активна,
    # но до изучения Картографии — только в пределах Региона)
    _draw_exploration_highlights()

    # ФАЗА 3: Рисуем иконки ресурсов, улучшений и другие оверлеи
    for row in range(visible.row_start, visible.row_end + 1):
        for col in range(visible.col_start, visible.col_end + 1):
            _draw_hex_overlays(row, col)

    # ФАЗА 3.5: Рисуем подсветку выбранного гекса (клик ЛКМ, панель управления).
    # Рамка + лёгкая заливка, чтобы выделенный гекс был хорошо виден поверх
    # оверлеев, но не перекрывал иконку ресурса/улучшения.
    if main_map.control_panel and main_map.control_panel.has_selection():
        var sel = main_map.control_panel.get_selected_hex()
        if sel != null:
            # Заливка + рамка. Набор гексов считает
            # expansion_manager.get_highlight_hexes(): гекс в Кольце Влияния —
            # только он сам; вне Кольца — весь чанк разведки/покупки (тот же
            # чанк, с которым работают действия панели, см.
            # control_panel._collect_region_actions); если чанка нет
            # (исследованный гекс вне Региона или гекс в кольце влияния чужого
            # городка) — сам гекс, чтобы клик не был «молчаливым». Чанк может
            # включать гексы в Регионе и в тумане войны рядом.
            # Цвета — по типу чанка (разведка/освоение × можно/нельзя), см.
            # _get_highlight_style; стиль считается один раз на весь набор.
            var selected_hexes: Array = main_map.expansion_manager.get_highlight_hexes(sel.row, sel.col)
            var style: Dictionary = _get_highlight_style(selected_hexes, sel.row, sel.col, true)
            for highlight_hex in selected_hexes:
                _draw_selected_hex_highlight(highlight_hex.row, highlight_hex.col, style)

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

    # Рисуем прямоугольник с названием города немного выше гекса города
    if not CityData.city_name.is_empty():
        var font = ThemeDB.fallback_font
        if font != null:
            var font_size := 14
            var text = CityData.city_name
            var text_size = font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
            var text_center = Vector2(city_center.x, city_center.y - main_map.HEX_RADIUS - 10)
            var padding = Vector2(8, 4)
            var text_ascent = font.get_ascent(font_size)
            var text_descent = font.get_descent(font_size)
            var background_height = text_ascent + text_descent + padding.y * 2.0
            var background_rect = Rect2(
                text_center.x - text_size.x / 2.0 - padding.x,
                text_center.y - background_height / 2.0,
                text_size.x + padding.x * 2.0,
                background_height
            )
            draw_rect(background_rect, Color(0.2, 0.2, 0.2, 1.0), true, -1.0, true)
            draw_rect(background_rect, Color(0.6, 0.6, 0.6, 1.0), false, 1.0, true)
            var text_baseline = background_rect.position.y + padding.y + text_ascent
            var text_pos = Vector2(text_center.x - text_size.x / 2.0, text_baseline)
            draw_string(
                font, text_pos, text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE
            )

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
    var is_explored = tile.get("is_explored", false)

    # Настоящий туман войны: неисследованный гекс за пределами Региона
    # вообще не рисуем — виден только тёмный фон канваса. После разведки
    # (`is_explored = true`) гекс снова отрисовывается как обычный: туман
    # «раскрывается» и разведка даёт визуальный эффект.
    if not in_influence and not is_explored and not main_map.is_valid_hex(row, col):
        return

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

# --- Кэш рендера колец влияния городков (PHASE 1.7 / 1.7.1) ---
# Раньше кольца пересчитывались и рисовались КАЖДЫЙ кадр: на каждый гекс
# заливки — отдельный draw_colored_polygon с alpha-блендингом и тригонометрией
# (hex_center + hex_vertices), а на каждое ребро границ — заново аллокация
# словаря membership, ещё 6×cos/sin и sort_custom(). При 2+ городках рядом
# кольца дополнительно ДУБЛИРОВАЛИСЬ: общие гексы в плоском списке
# town_influence_hexes были по одному на каждый городок — заливка наносилась
# 2-3 раза, что усиливало затемнение пересечений и повышало нагрузку.
#
# Кольца статичны между спавном/загрузкой/сменой эпохи, поэтому теперь:
#   Шаг 1 — кэш уникальных центров заливки (без дублей) и мировых отрезков
#           границ строится один раз в _ensure_town_influence_cache();
#   Шаг 2 — заливка пре-рендерится в ОДНУ RGBA-текстуру на весь Регион
#           (см. _build_town_fill_texture), и за кадр рисуется один
#           draw_texture_rect вместо сотен полупрозрачных полигонов.
# За кадр остаются: 1 blit заливки + лёгкие draw_line границ без тригонометрии
# и аллокаций. Пересборка — только по invalidate_town_influence_cache()
# (инициализация карты / загрузка сейва) либо при смене Региона (эпоха).

func invalidate_town_influence_cache() -> void:
    # Сбрасываем кэш рендера: пересоберётся лениво на следующем кадре.
    # Старая ImageTexture освобождается автоматически (ref-count) при
    # перезаписи ссылки в _build_town_fill_texture().
    _town_cache_version += 1

func _ensure_town_influence_cache(visible: Dictionary) -> void:
    if main_map == null:
        return
    # Регион расширяется при смене эпохи — кэш под старые границы невалиден.
    var region_changed: bool = _cache_region_start_row != main_map.region_start_row \
            or _cache_region_end_row != main_map.region_end_row \
            or _cache_region_start_col != main_map.region_start_col \
            or _cache_region_end_col != main_map.region_end_col
    if _town_cache_built_version == _town_cache_version and not region_changed:
        return
    _town_cache_built_version = _town_cache_version
    _cache_region_start_row = main_map.region_start_row
    _cache_region_end_row = main_map.region_end_row
    _cache_region_start_col = main_map.region_start_col
    _cache_region_end_col = main_map.region_end_col

    # --- Шаг 1: уникальные гексы заливки + мировые отрезки границ ---
    _influence_fill_centers = []
    _influence_border_segments = []
    var seen: Dictionary = {}
    var radius: float = main_map.HEX_RADIUS
    var towns: Array = main_map.towns
    if towns == null:
        towns = []
    # Направления соседей для нечёт-r offset-сетки (как HexUtils.get_neighbors_odd_r).
    var even_dirs := [[0, -1], [0, 1], [-1, -1], [-1, 0], [1, -1], [1, 0]]
    var odd_dirs := [[0, -1], [0, 1], [-1, 0], [-1, 1], [1, 0], [1, 1]]
    for town_entry in towns:
        var ring: Array = town_entry.get("influence_hexes", [])
        if ring.is_empty():
            continue
        var bc: Array = town_entry.get("border_color", [1.0, 1.0, 1.0, 1.0])
        # Карта членства "row,col" -> true для быстрой проверки «не в кольце».
        var members: Dictionary = {}
        for h in ring:
            members["%d,%d" % [int(h.row), int(h.col)]] = true
        for h in ring:
            var row: int = int(h.row)
            var col: int = int(h.col)
            # Заливка: гекс рисуем один раз, даже если он в кольцах нескольких
            # городков (раньше — по N раз с «двойным» затемнением пересечений).
            var key := "%d,%d" % [row, col]
            if not seen.has(key):
                seen[key] = true
                var c: Vector2 = HexUtils.hex_center(row, col, radius)
                _influence_fill_centers.append({"cx": c.x, "cy": c.y,
                        "row": row, "col": col,
                    "cr": bc[0], "cg": bc[1], "cb": bc[2],
                    "ca": TOWN_INFLUENCE_FILL_ALPHA})
            # Граница: рёбра между кольцом городка и его окружением.
            var dirs: Array = even_dirs if row % 2 == 0 else odd_dirs
            for d in dirs:
                var nr := row + int(d[0])
                var nc := col + int(d[1])
                if members.has("%d,%d" % [nr, nc]):
                    continue
                # Соседа за краем карты нет — «правильный» край не рисуем.
                if nr < 0 or nr >= main_map.map_rows or nc < 0 or nc >= main_map.map_cols:
                    continue
                # Общая кромка: две вершины текущего гекса, ближайшие к центру
                # соседнего. Для pointy-top гексов это и есть общее ребро.
                var nb_center: Vector2 = HexUtils.hex_center(nr, nc, radius)
                var dists: Array = []
                for vi in range(6):
                    var v: Vector2 = HexUtils.hex_vertex(row, col, vi, radius)
                    dists.append({"idx": vi, "d": v.distance_squared_to(nb_center)})
                dists.sort_custom(func(a, b): return a.d < b.d)
                var p1: Vector2 = HexUtils.hex_vertex(row, col, int(dists[0].idx), radius)
                var p2: Vector2 = HexUtils.hex_vertex(row, col, int(dists[1].idx), radius)
                _influence_border_segments.append({"p1x": p1.x, "p1y": p1.y,
                        "p2x": p2.x, "p2y": p2.y,
                        "cr": bc[0], "cg": bc[1], "cb": bc[2], "ca": bc[3],
                        "row": row, "col": col})

    # --- Шаг 2: пре-рендер заливки в одну текстуру Региона ---
    _build_town_fill_texture()

# Пре-рендер заливки колец влияния в ОДНУ RGBA-текстуру, покрывающую весь
# видимый Регион (Кольцо + Регион). Текстура строится в «мировых» пикселях
# (без scroll-offset): при прокрутке кадр лишь прибавляет offset и делает один
# draw_texture_rect. В Godot-классе Image нет векторных примитивов (только
# fill/fill_rect/set_pixel), поэтому гексы заполняются построчно через
# fill_rect по таблице половинных ширин (pointy-top гекс с плоскими боковыми
# сторонами: левая и правая границы вертикальные).
#
# Если Регион слишком велик для одной текстуры (предел 4096 px) — оставляем
# _influence_fill_texture = null, и _draw_town_influence рисует заливку
# кэшированными полигонами (без дублей и тригонометрии за кадр).
func _build_town_fill_texture() -> void:
    _influence_fill_texture = null
    if main_map == null or Engine.is_editor_hint():
        return
    if _influence_fill_centers.is_empty():
        return
    var r0: int = main_map.region_start_row
    var r1: int = main_map.region_end_row
    var c0: int = main_map.region_start_col
    var c1: int = main_map.region_end_col
    if r1 < r0 or c1 < c0:
        return
    var radius: float = main_map.HEX_RADIUS
    var tl: Vector2 = HexUtils.hex_center(r0, c0, radius)
    var tr: Vector2 = HexUtils.hex_center(r0, c1, radius)
    var bl: Vector2 = HexUtils.hex_center(r1, c0, radius)
    var br: Vector2 = HexUtils.hex_center(r1, c1, radius)
    var min_x := minf(minf(tl.x, tr.x), minf(bl.x, br.x)) - radius
    var max_x := maxf(maxf(tl.x, tr.x), maxf(bl.x, br.x)) + radius
    var min_y := minf(minf(tl.y, tr.y), minf(bl.y, br.y)) - radius
    var max_y := maxf(maxf(tl.y, tr.y), maxf(bl.y, br.y)) + radius
    var tex_w: int = int(ceil(max_x - min_x))
    var tex_h: int = int(ceil(max_y - min_y))
    if tex_w <= 0 or tex_h <= 0 or tex_w > 4096 or tex_h > 4096:
        return
    var img: Image = Image.create_empty(tex_w, tex_h, false, Image.FORMAT_RGBA8)
    if img == null:
        return
    img.fill(Color(0, 0, 0, 0))
    var half: float = radius * 0.5
    var rmax: int = int(ceil(radius)) + 1
    # Половинные ширины (px) pointy-top гекса по смещениям dy. +1px на каждую
    # сторону наружу — закрывает тонкие AA-швы на стыках гексов.
    var hw: Dictionary = {}
    for dy in range(-rmax, rmax + 1):
        var ya: float = float(dy)
        var w: float = radius * sqrt(3.0) * 0.5 # плоская ширина (|y| <= r/2)
        if ya > half:
            w = sqrt(3.0) * (radius - ya)
        elif ya < -half:
            w = sqrt(3.0) * (ya + radius)
        hw[dy] = w + 1.0
    for h in _influence_fill_centers:
        var cx: float = float(h.cx) - min_x
        var cy: float = float(h.cy) - min_y
        var fill_color := Color(h.cr, h.cg, h.cb, h.ca)
        var base_x: int = int(floor(cx))
        var base_y: int = int(floor(cy))
        for dy in range(-rmax, rmax + 1):
            var y: int = base_y + dy
            if y < 0 or y >= tex_h:
                continue
            var w: float = float(hw[dy])
            var x0: int = base_x - int(ceil(w))
            var x1: int = base_x + int(ceil(w))
            if x1 <= x0:
                continue
            img.fill_rect(Rect2i(x0, y, x1 - x0, 1), fill_color)
    _influence_fill_texture = ImageTexture.create_from_image(img)
    _influence_texture_origin = Vector2(min_x, min_y)
    _influence_texture_size = Vector2(float(tex_w), float(tex_h))

# Сужает видимый диапазон гексов до границ Региона (Кольцо + Регион).
# Нужен для колец влияния городков: туман войны теперь отрисовывается и
# доступен для разведки, но чужая территория в нём не раскрывается —
# заливка и границы колец рисуются только внутри Региона.
func _get_region_visible_range(visible: Dictionary) -> Dictionary:
    return {
        "row_start": max(visible.row_start, main_map.region_start_row),
        "row_end": min(visible.row_end, main_map.region_end_row),
        "col_start": max(visible.col_start, main_map.region_start_col),
        "col_end": min(visible.col_end, main_map.region_end_col)
    }

# Рисует кольца влияния всех городков (PHASE 1.7). По договорённости — только
# для гексов внутри РЕГИОНА (см. _get_region_visible_range): за туманом войны
# кольца не рисуются, чтобы не «выдавать» неисследованную территорию, хотя
# сам туман теперь отрисовывается и доступен для разведки.
# Один кадр = один draw_texture_rect (текстура вырезана по Кольцо+Регион).
# Fallback на полигоны — только в редакторе или при слишком большом Регионе.
func _draw_town_influence(visible: Dictionary) -> void:
    if main_map == null:
        return
    var radius: float = main_map.HEX_RADIUS
    var offset_x: float = main_map.offset_x + main_map.scroll_offset.x
    var offset_y: float = main_map.offset_y + main_map.scroll_offset.y
    _ensure_town_influence_cache(visible)
    if _influence_fill_texture != null:
        draw_texture_rect(_influence_fill_texture, Rect2(
                _influence_texture_origin.x + offset_x,
                _influence_texture_origin.y + offset_y,
                _influence_texture_size.x,
                _influence_texture_size.y), false, Color(1, 1, 1, 1))
        return
    # Fallback: отрисовка гексами (редактор / Регион больше 4096px).
    var region_visible = _get_region_visible_range(visible)
    for h in _influence_fill_centers:
        var row: int = int(h.row)
        var col: int = int(h.col)
        # Видимость (как раньше): только Кольцо + Регион.
        if row < region_visible.row_start or row > region_visible.row_end \
                or col < region_visible.col_start or col > region_visible.col_end:
            continue
        var cx: float = float(h.cx) + offset_x
        var cy: float = float(h.cy) + offset_y
        if not _is_rect_visible(Rect2(cx - radius, cy - radius, radius * 2, radius * 2)):
            continue
        var vertices = HexUtils.hex_vertices(cx, cy, radius)
        var fill_color := Color(h.cr, h.cg, h.cb, h.ca)
        draw_colored_polygon(vertices, fill_color)

# Рисует границы колец влияния КАЖДОГО городка своим цветом (PHASE 1.7.1).
# Рисуется сразу после заливки колец (PHASE 1.7) и до дорог/рек/иконок.
#
# Данные берутся из main_map.towns (массив записей городков): у каждого
# городка своё личное кольцо (town["influence_hexes"]) и свой цвет границ
# (town["border_color"], сгенерирован на спавне и сохранён в сейв). Кольца
# полностью независимы — цвета соседних городков не влияют друг на друга,
# поэтому «чужая» территория визуально чётко разграничена.
#
# Контур рисуется по общим рёбрам между гексами кольца и «окружением»
# (гекс, НЕ входящий в кольцо этого городка). Внутренние рёбра (между двумя
# гексами одного кольца) не рисуются. За краем карты рёбра не рисуются —
# там нет гекса-соседа, и кольцо просто заканчивается.
#
# Отрезки считаются ОДИН раз в _ensure_town_influence_cache() и хранятся в
# мировых координатах (без offset). За кадр — только трансляция offset'ом,
# viewport-проверка и draw_line: без тригонометрии и аллокаций словарей.
#
# Видимость — та же, что у заливки: только Кольцо + Регион. Клип колец на
# стартовом Регионе уже применён к данным (в town_manager), так что чужие
# городки в 1-й эпохе контуры не раскрывают.
func _draw_town_influence_borders(visible: Dictionary) -> void:
    if main_map == null:
        return
    _ensure_town_influence_cache(visible)
    var region_visible = _get_region_visible_range(visible)
    var offset_x: float = main_map.offset_x + main_map.scroll_offset.x
    var offset_y: float = main_map.offset_y + main_map.scroll_offset.y
    for seg in _influence_border_segments:
        var row: int = int(seg.row)
        var col: int = int(seg.col)
        # Видимость (как в заливке): только Кольцо + Регион.
        if row < region_visible.row_start or row > region_visible.row_end \
                or col < region_visible.col_start or col > region_visible.col_end:
            continue
        var p1 := Vector2(float(seg.p1x) + offset_x, float(seg.p1y) + offset_y)
        var p2 := Vector2(float(seg.p2x) + offset_x, float(seg.p2y) + offset_y)
        # Viewport culling сегмента по его bounding-box.
        if not _is_rect_visible(Rect2(
                minf(p1.x, p2.x) - TOWN_INFLUENCE_BORDER_WIDTH,
                minf(p1.y, p2.y) - TOWN_INFLUENCE_BORDER_WIDTH,
                abs(p1.x - p2.x) + TOWN_INFLUENCE_BORDER_WIDTH * 2.0,
                abs(p1.y - p2.y) + TOWN_INFLUENCE_BORDER_WIDTH * 2.0)):
            continue
        var color := Color(seg.cr, seg.cg, seg.cb, seg.ca)
        draw_line(p1, p2, color, TOWN_INFLUENCE_BORDER_WIDTH, true)

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
    var is_explored = tile.get("is_explored", false)

    if row == main_map.city_row and col == main_map.city_col:
        return

    # Настоящий туман войны: неисследованный гекс за Регионом — никаких
    # оверлеев (ресурсы, иконки улучшений, городки, конфликты tech_reveal).
    # `_draw_hex` уже отказался его рисовать; тут тоже выходим, чтобы
    # случайно не «выдать» содержимое.
    if not in_influence and not is_explored and not main_map.is_valid_hex(row, col):
        return

    # Ресурсы Региона вне Кольца Влияния скрыты, пока область не разведана.
    # (Прогресс-бары ниже отрисовываются независимо от видимости ресурса.)
    var is_resource_visible = _is_resource_revealed(tile)

    # Рисуем иконку как для природного (tile.resource), так и для разводимого
    # (tile.crop_bred) ресурса — эффективный ресурс берётся из MapHelpers.
    var eff_res = MapHelpers.get_effective_resource(tile)
    # Проверяем, заблокирован ли ресурс технологией для улучшения.
    # Ресурсы с tech_reveal скрыты полностью (is_resource_visible = false).
    # Замок гейтится технологией УЛУЧШЕНИЯ, которым добывается ресурс
    # (imp_unlock_tech из improved_by), а НЕ технологией появления ресурса
    # (tech_required). Например, кварцевый песок добывается каменоломней:
    # замок держится до «Каменной кладки», хотя ресурс виден раньше. Для
    # каменных ресурсов (базальт/мрамор/…) этот же замок держится до
    # «Каменной кладки», а не пропадает после «Горного дела».
    var is_resource_locked_by_tech = false
    if eff_res != "" and is_resource_visible:
        var res_data = GameData.raw_resources.get(eff_res, {})
        var improved_by = res_data.get("improved_by", "")
        # У части ресурсов (например, дикоросы foraged_food) improved_by задан
        # как null — тогда .get() возвращает Nil, а не значение по умолчанию.
        if improved_by == null:
            improved_by = ""
        if improved_by != "" and not CityData.is_improvement_unlocked(improved_by):
            is_resource_locked_by_tech = true

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

    # Если ресурс виден, но технология для постройки улучшения не изучена —
    # рисуем иконку замка поверх ресурса. Как только технология изучена,
    # замок исчезает (is_resource_locked_by_tech становится false).
    if is_resource_locked_by_tech and icon_textures.has("lock.png"):
        var lock_tex = icon_textures["lock.png"]
        var lock_size = RESOURCE_ICON_SIZE * 0.6
        var lock_rect = Rect2(
            center.x - lock_size / 2.0,
            center.y - lock_size / 2.0,
            lock_size,
            lock_size
        )
        draw_texture_rect(lock_tex, lock_rect, false)

    # Звёздочки качества ресурса — под иконкой, только если ресурс раскрыт
    # и на этом гексе уже построено улучшение, которое раскрывает качество.
    if eff_res != "" and is_resource_visible and tile.improvement != null:
        _draw_quality_stars(tile, center)

    if in_influence and tile.improvement != null:
        var has_worker = main_map.worker_manager.has_worker(row, col)
        var imp_data = GameData.improvements.get(tile.improvement, {})
        var imp_icon = imp_data.get("icon", "")
        # Инфраструктурные улучшения (no_worker, например пристань или канал)
        # не привязаны к рабочему: рисуем их всегда в полный цвет, без серого
        # затемнения, даже когда has_worker == false.
        var is_infra = GameData.is_no_worker_improvement(tile.improvement)
        # Декоративные улучшения городков всегда рисуются полноцветными,
        # хотя рабочего у них намеренно нет.
        var draw_active = has_worker or is_infra or bool(tile.get("decorative", false))
        # Если на гексе нет ресурса (ни природного, ни разводимого) — улучшение
        # это единственный «предмет» на гексе (ирригационный канал, лесная
        # делянка на пустом лесном гексе, декоративные улучшения городков на
        # пустых гексах). Рисуем его по центру гекса КРУПНО — размером с
        # иконку ресурса (RESOURCE_ICON_SIZE): фактически оно заменяет собой
        # отсутствующую иконку ресурса. Если ресурс есть — иконка улучшения
        # остаётся маленьким маркером (IMPROVEMENT_ICON_SIZE) над верхним
        # краем, над иконкой ресурса.
        var imp_icon_size: float = IMPROVEMENT_ICON_SIZE
        # Радиус заглушки-круга, если текстура иконки не найдена. Для крупной
        # иконки берём ту же формулу, что и у ресурса (RESOURCE_ICON_SIZE/3),
        # чтобы выглядела как обычная иконка ресурса-заглушки.
        var imp_fallback_radius: float = IMPROVEMENT_ICON_SIZE / 2.5
        var icon_pos = Vector2(center.x, center.y)
        if eff_res != "":
            icon_pos = Vector2(center.x, center.y - main_map.HEX_RADIUS * 0.75)
        else:
            imp_icon_size = RESOURCE_ICON_SIZE
            imp_fallback_radius = RESOURCE_ICON_SIZE / 3.0
        if imp_icon != "" and icon_textures.has(imp_icon):
            var tex = icon_textures[imp_icon]
            var icon_rect = Rect2(icon_pos.x - imp_icon_size / 2.0, icon_pos.y - imp_icon_size / 2.0, imp_icon_size, imp_icon_size)
            if not draw_active:
                draw_texture_rect(tex, icon_rect, false, Color(0.5, 0.5, 0.5))
            else:
                draw_texture_rect(tex, icon_rect, false)
        else:
            if imp_data.has("color"):
                var c = imp_data["color"]
                var fallback_color = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
                if not draw_active:
                    fallback_color = Color(0.5, 0.5, 0.5)
                draw_circle(icon_pos, imp_fallback_radius, fallback_color)

        # Капелька пресной воды рядом с иконкой улучшения. Показываем для
        # любого улучшения, у которого есть доступ к воде (direct или chain).
        # Типы различаются визуально:
        #   direct — залитая голубая капля (как раньше у ферм);
        #   chain  — контурная (обводка) приглушённого цвета, вода по цепочке.
        if tile.improvement != null:
            var water_access = MapHelpers.get_hex_water_access(row, col, tile_data, main_map.map_rows, main_map.map_cols)
            if water_access != "":
                # Позиция капельки зависит от размера иконки улучшения:
                #   маленькая (32) — как раньше, справа от иконки;
                #   крупная (RESOURCE_ICON_SIZE, гекс без ресурса) — справа
                #   капелька упирается в грань гекса (полуширина гекса ≈ 47.6px
                #   при HEX_RADIUS = 55), а снизу мешают прогресс-бары, поэтому
                #   ставим её по центру НАД иконкой, в верхней части гекса.
                var drop_offset := Vector2(imp_icon_size * 0.5 + 6, 0)
                if imp_icon_size > IMPROVEMENT_ICON_SIZE:
                    drop_offset = Vector2(0, - (imp_icon_size * 0.5 + 6))
                var drop_center = icon_pos + drop_offset
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
                if water_access == "direct":
                    draw_polygon(drop_points, [Color(0.45, 0.8, 1.0, 1.0)])
                else:
                    # chain: контурная капля приглушённого цвета.
                    var closed_points = PackedVector2Array()
                    closed_points.append_array(drop_points)
                    closed_points.append(drop_points[0])
                    draw_polyline(closed_points, Color(0.5, 0.7, 0.95, 0.9), 1.5)

    # --- Иконка городка ---
    # Рисуется ПОСЛЕ всех остальных оверлеев (ресурс/улучшение/капля воды),
    # чтобы быть поверх них — это «главный» объект на гексе, как и сам город
    # игрока. Размер берётся из town_manager, чтобы при желании легко было
    # подкрутить. Рисуем только если гекс НЕ гекс города (город — отдельный
    # случай в ФАЗЕ 4).
    if tile.get("has_town", false) \
            and not (row == main_map.city_row and col == main_map.city_col) \
            and icon_textures.has(TownManager.TOWN_ICON_NAME):
        # Раскрыт ли гекс: в Кольце Влияния или разведан разведчиками.
        var town_revealed: bool = in_influence or bool(tile.get("is_explored", false))
        # Раскрытый городок — полная иконка + имя. Неразведанный (туман войны)
        # виден лишь намёком: полупрозрачная иконка без имени, а до эпохи
        # Античности (current_era < 1) не показывается вовсе — как и раньше
        # в отдельном проходе для городков за пределами Региона.
        if town_revealed or main_map.current_era >= 1:
            var town_tex = icon_textures[TownManager.TOWN_ICON_NAME]
            var town_rect = Rect2(
                center.x - TownManager.TOWN_ICON_SIZE / 2.0,
                center.y - TownManager.TOWN_ICON_SIZE / 2.0,
                TownManager.TOWN_ICON_SIZE,
                TownManager.TOWN_ICON_SIZE
            )
            if town_revealed:
                draw_texture_rect(town_tex, town_rect, false)
                _draw_town_name(row, col, center)
            else:
                draw_texture_rect(town_tex, town_rect, false,
                        Color(1, 1, 1, TownManager.FOG_TOWN_ICON_ALPHA))

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

func _draw_town_name(row: int, col: int, center: Vector2) -> void:
    var town_name := ""
    for town in main_map.towns:
        if int(town.get("row", -1)) == row and int(town.get("col", -1)) == col:
            town_name = str(town.get("name", ""))
            break
    if town_name.is_empty():
        return

    var font = ThemeDB.fallback_font
    if font == null:
        return
    var font_size := 12
    var text_size = font.get_string_size(town_name, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
    var text_center = Vector2(center.x, center.y - main_map.HEX_RADIUS - 8)
    var padding = Vector2(6, 3)
    var text_ascent = font.get_ascent(font_size)
    var text_descent = font.get_descent(font_size)
    var background_height = text_ascent + text_descent + padding.y * 2.0
    var background_rect = Rect2(
        text_center.x - text_size.x / 2.0 - padding.x,
        text_center.y - background_height / 2.0,
        text_size.x + padding.x * 2.0,
        background_height
    )
    draw_rect(background_rect, Color(0.2, 0.2, 0.2, 1.0), true, -1.0, true)
    draw_rect(background_rect, Color(0.6, 0.6, 0.6, 1.0), false, 1.0, true)
    var text_baseline = background_rect.position.y + padding.y + text_ascent
    var text_pos = Vector2(text_center.x - text_size.x / 2.0, text_baseline)
    draw_string(font, text_pos, town_name, HORIZONTAL_ALIGNMENT_CENTER,
            -1, font_size, Color.WHITE)

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

# Возвращает стиль подсветки чанка — {"fill": Color, "border": Color,
# "width": float} — по четырём типам чанков. Две оси кодирования:
#   - тон кодирует тип действия (два взаимно различных тона — разведка или
#     освоение); приглушённый (обесцвеченный) тон означает, что действие
#     недоступно: чанк не примыкает к известной территории либо покупка
#     невозможна (вне Региона / чужая территория);
#   - состояние ввода: наведение — тонкая рамка, клик — толстая.
# anchor_row/anchor_col — гекс, с которого начато выделение (наведение/клик):
# его статус определяет тип действия (is_explored/in_influence → освоение,
# иначе → разведка; чанк гомогенен по статусу, поэтому расхождений нет).
# Доступность считается так же, как в control_panel._collect_region_actions:
#   - освоение: чанк непуст, гекс не в кольце чужого городка, внутри Региона
#     и хотя бы один гекс чанка примыкает к in_influence (своя территория —
#     всегда «доступно»);
#   - разведка: main_map.is_chunk_adjacent_to_known (примыкание к известному
#     миру) — тот же гейт, что у кнопки «Отправить разведчиков».
# Состояние is_scouting (экспедиция уже идёт) не учитывается: это временный
# режим, а не свойство чанка.
# ЕДИНСТВЕННОЕ место системы подсветки с конкретными значениями цветов:
# правьте палитру только здесь — в комментариях кода и документации
# конкретные цвета намеренно не продублированы, чтобы они не устаревали.
func _get_highlight_style(chunk: Array, anchor_row: int, anchor_col: int, selected: bool) -> Dictionary:
    var tile = null
    if main_map.is_hex_on_map(anchor_row, anchor_col):
        tile = main_map.tile_data[anchor_row][anchor_col]
    var acquire: bool = tile != null \
            and (bool(tile.get("is_explored", false)) \
            or bool(tile.get("in_influence", false)))
    var available := false
    if acquire:
        if tile != null and bool(tile.get("in_influence", false)):
            available = true
        elif tile != null and not bool(tile.get("in_town_influence", false)) \
                and main_map.is_valid_hex(anchor_row, anchor_col):
            for hex in chunk:
                for n in HexUtils.get_neighbors_odd_r(hex.row, hex.col, main_map.map_rows, main_map.map_cols):
                    if bool(main_map.tile_data[n.row][n.col].get("in_influence", false)):
                        available = true
                        break
                if available:
                    break
    else:
        available = not chunk.is_empty() and main_map.is_chunk_adjacent_to_known(chunk)
    if acquire:
        if available:
            if selected:
                return {"fill": Color(1.0, 0.9, 0.3, 0.25), "border": Color(1.0, 0.85, 0.2, 0.95), "width": 3.0}
            return {"fill": Color(1.0, 1.0, 0.0, 0.3), "border": Color(1.0, 1.0, 0.0, 0.9), "width": 2.0}
        if selected:
            return {"fill": Color(0.66, 0.56, 0.66, 0.18), "border": Color(0.45, 0.38, 0.48, 0.85), "width": 3.0}
        return {"fill": Color(0.66, 0.56, 0.66, 0.24), "border": Color(0.48, 0.4, 0.5, 0.9), "width": 2.0}
    if available:
        if selected:
            return {"fill": Color(0.3, 0.72, 1.0, 0.25), "border": Color(0.2, 0.62, 1.0, 0.95), "width": 3.0}
        return {"fill": Color(0.35, 0.78, 1.0, 0.3), "border": Color(0.3, 0.72, 1.0, 0.9), "width": 2.0}
    if selected:
        return {"fill": Color(0.58, 0.68, 0.75, 0.18), "border": Color(0.5, 0.57, 0.63, 0.8), "width": 3.0}
    return {"fill": Color(0.58, 0.68, 0.75, 0.22), "border": Color(0.5, 0.57, 0.63, 0.85), "width": 2.0}

# Рисует подсветку выбранного гекса: полупрозрачная заливка + яркая рамка.
# Вызывается как для одиночного гекса в Кольце Влияния, так и для каждого
# гекса SELECTED чанка (Phase 3.5). Цвета берутся из style — см.
# _get_highlight_style (четыре типа чанков: разведка/освоение × можно/
# нельзя). Чанк может выходить за пределы Региона — в этом случае часть его
# гексов лежит в тумане войны, и подсветка должна быть видна и там (одинаково
# с Регионом). Видимостью НЕ фильтруем: гексы уже ограничены либо Кольцом
# Влияния (одиночный вызов), либо `scout_reach_bounds` (вызов из чанка), а
# вне viewport канвас сам обрежет отрисовку.
func _draw_selected_hex_highlight(row: int, col: int, style: Dictionary):
    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    center.x += main_map.offset_x + main_map.scroll_offset.x
    center.y += main_map.offset_y + main_map.scroll_offset.y
    var vertices = PackedVector2Array()
    vertices.append_array(HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS))

    # Полупрозрачная заливка (поверх terrain, но под иконками ресурсов/улучшений).
    draw_colored_polygon(vertices, style.fill)

    # Яркая рамка.
    var closed_vertices = PackedVector2Array()
    closed_vertices.append_array(vertices)
    closed_vertices.append(vertices[0])
    draw_polyline(closed_vertices, style.border, style.width)

# Рисует заполненный (сложную) звезду.
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

func _is_resource_locked(resource_id: String) -> bool:
    if resource_id == null or resource_id == "":
        return false
    var res_data = GameData.raw_resources.get(resource_id, {})
    var imp_id = res_data.get("improved_by", "")
    # У части ресурсов (например, дикоросы foraged_food) improved_by задан
    # как null — тогда .get() возвращает Nil, а не значение по умолчанию.
    if imp_id == null:
        return false
    # Ресурс считается заблокированным, если ещё не открыто улучшение, которое
    # его добывает (improved_by), по его unlock_tech.
    return not CityData.is_improvement_unlocked(imp_id)

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
# Реки обрезаются по прямоугольнику экрана: за его пределами они не видны,
# а внутри (в том числе в тумане войны, который теперь отрисовывается
# затемнённым) рисуются полностью.
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

        # Сглаженные меандровые точки реки в МИРОВЫХ координатах (без offset).
        # Вычисляем их один раз на реку и кэшируем: сглаживание (_generate_natural_river
        # + _chaikin_smooth) — дорогая операция, а точки рек не меняются при прокрутке,
        # поэтому пересчёт каждый кадр избыточен. Ключ кэша — компактная сериализация
        # исходных точек реки (с уникальным хэшем количества точек).
        var cache_key = "%d|" % river.size() + _points_to_cache_key(river)
        var smooth_points: PackedVector2Array
        if _river_smooth_cache.has(cache_key):
            smooth_points = _river_smooth_cache[cache_key]
        else:
            # Строим естественные меандры по полной реке в МИРОВЫХ координатах,
            # затем при отрисовке к ним добавится offset. Так волны остаются
            # непрерывными на границе, а за ней река не рисуется (туман войны).
            var world_points = PackedVector2Array()
            for pt in river:
                world_points.append(Vector2(pt.x, pt.y))
            smooth_points = _generate_natural_river(world_points, radius)
            _river_smooth_cache[cache_key] = smooth_points

        # Смещаем сглаженные мировые точки на текущий offset (прокрутка/центр).
        var shifted_points = PackedVector2Array()
        shifted_points.resize(smooth_points.size())
        for i in range(smooth_points.size()):
            shifted_points[i] = Vector2(
                smooth_points[i].x + offset_x,
                smooth_points[i].y + offset_y
            )

        # Обрезаем сглаженную линию по прямоугольнику экрана. Раньше клип шёл
        # по Региону (туман войны не отрисовывался вовсе), но теперь гексы в
        # достижимой скроллом полосе рисуются затемнёнными — реки не должны
        # обрываться на границе Региона.
        var screen_rect = Rect2(Vector2(-offset_x, -offset_y), _get_viewport_size())
        var clipped_lines = _clip_river_to_rect(shifted_points, screen_rect)
        if clipped_lines.is_empty():
            continue

        for line in clipped_lines:
            if line.size() < 2:
                continue
            draw_polyline(line, shore_color, shore_width, true)
            draw_polyline(line, body_color, body_width, true)
            draw_polyline(line, highlight_color, highlight_width, true)


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

    var visible = _get_visible_hex_range()

    # --- 1. Подсветка исследованных гексов (только в видимой области) ---
    # Вне видимой области (туман войны) terrain не рисуется рендерером, поэтому
    # заливка для исследованных гексов там не нужна.
    for row in range(visible.row_start, visible.row_end + 1):
        for col in range(visible.col_start, visible.col_end + 1):
            var tile = tile_data[row][col]
            if tile.get("in_influence", false):
                continue
            var is_explored = tile.get("is_explored", false)
            if not is_explored:
                continue
            var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
            center.x += main.offset_x + main.scroll_offset.x
            center.y += main.offset_y + main.scroll_offset.y
            var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)
            # Исследован: только заливка — белой рамки здесь нет
            # намеренно: она сливалась с сеткой гексов и визуально «раздувала»
            # разведанную область. Рамку рисуют только hover/выделение чанка
            # (см. _draw_selected_hex_highlight).
            draw_colored_polygon(vertices, Color(0.652, 0.855, 0.652, 0.25))

    # --- 2. Подсветка выделенного чанка (Регион + туман войны) ---
    # Чанк может включать гексы в тумане войны (разведка) — подсветка рисуется
    # ДЛЯ КАЖДОГО гекса чанка, без фильтра по видимой области. Иначе в тумане
    # игрок не видит, какой именно участок сейчас выделен и куда полетят
    # разведчики. Цвет зависит от типа чанка (разведка/освоение × можно/
    # нельзя — см. _get_highlight_style): тон действия и его приглушённость.
    #
    # До изучения Картографии подсветка НЕ выходит за пределы Региона: там
    # разведка недоступна, и подсветка на тёмном канвасе тумана только
    # путала бы игрока (см. main_map.is_cartography_researched). Чанки,
    # собранные expansion_manager, это правило уже соблюдают — фильтр ниже
    # страховочный (например, устаревший current_chunk после загрузки сейва).
    var chunk: Array = expansion_manager.current_chunk
    var anchor = expansion_manager.current_hover_hex
    if chunk.is_empty():
        # Чанка под курсором нет (исследованный гекс вне Региона или гекс в
        # кольце влияния чужого городка): подсвечиваем сам гекс под курсором —
        # тем же цветом, что и чанк. Иначе наведение было бы «молчаливым», а
        # клик по такому гексу подсветку уже даёт (см. ФАЗУ 3.5 и
        # expansion_manager.get_highlight_hexes).
        if anchor == null:
            return
        chunk = expansion_manager.get_highlight_hexes(anchor.row, anchor.col)
    if anchor == null:
        # Устаревший current_chunk без гекса под курсором (страховка):
        # берём первый гекс чанка как точку отсчёта для классификации.
        anchor = chunk[0]
    var style: Dictionary = _get_highlight_style(chunk, anchor.row, anchor.col, false)

    var cartography: bool = main_map.is_cartography_researched()
    for hex in chunk:
        if not cartography and not main_map.is_valid_hex(hex.row, hex.col):
            continue
        var center = HexUtils.hex_center(hex.row, hex.col, main_map.HEX_RADIUS)
        center.x += main.offset_x + main.scroll_offset.x
        center.y += main.offset_y + main.scroll_offset.y
        var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)
        draw_colored_polygon(vertices, style.fill)
        var closed_verts = PackedVector2Array()
        closed_verts.append_array(vertices)
        closed_verts.append(vertices[0])
        draw_polyline(closed_verts, style.border, style.width)

func get_icon_path(icon_name: String) -> String:
    if icon_paths.has(icon_name):
        return icon_paths[icon_name]
    return ""


# Возвращает компактную строку-ключ для кэша сглаженной реки.
# Сериализует координаты точек реки (мировые, без offset). Используется
# _draw_river_list для идентификации, какая река уже посчитана и закэширована.
func _points_to_cache_key(points: Array) -> String:
    var sb := PackedStringArray()
    sb.resize(points.size())
    for i in range(points.size()):
        var p = points[i]
        # Округляем до 0.1, чтобы ключ был стабилен и компактен — исходные
        # вершины рек детерминированы, поэтому повторного сглаживания не будет.
        sb[i] = "%d_%d" % [roundi(p.x * 10.0), roundi(p.y * 10.0)]
    return "^".join(sb)

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
