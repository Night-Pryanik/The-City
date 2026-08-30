# tech_tree.gd
# Визуализация дерева технологий в стиле Civilization.
#
# Горизонтальная прокрутка, вертикальные колонки = слои зависимостей.
# Корень (farming) — левая колонка (column 0).
# Технологии без предшественников — колонка 1.
# Остальные — column = max(col[prereq]) + 1.
#
# Кнопки одинаковой ширины, с иконкой и переносом текста на 2 строки
# (с автоуменьшением шрифта, если не влезает).
# ЛКМ — начать исследование (через сигнал research_requested).
# Hover — встроенный тултип с описанием технологии.
extends Control

# --- Размеры ---
const COL_GAP: int = 80 # горизонтальный зазор между колонками
const COL_PADDING: int = 24 # отступ от края _inner
const BUTTON_WIDTH: int = 200 # фиксированная ширина кнопки
const BUTTON_HEIGHT: int = 60 # фиксированная высота кнопки
const BUTTON_VERTICAL_GAP: int = 16 # вертикальный зазор между кнопками в колонке
const ICON_SIZE: int = 50 # размер иконки технологии
const UNLOCK_ICON_SIZE: int = 32 # размер иконки открываемого контента на кнопке технологии
const UNLOCK_ICONS_MARGIN: int = 3 # расстояние от иконок до границ кнопки

# --- Разделение по эпохам ---
# Каждая технология в JSON содержит поле "era" (id эпохи), а человекочитаемые
# названия эпох лежат в data/eras.json (загружается в GameData.eras).
# Последовательные колонки одной эпохи визуально объединяются: сверху над
# ними рисуется заголовок с названием эпохи, а между группами эпох — толстая
# вертикальная линия-разделитель (см. ERA_LABEL_HEIGHT, ERA_LINE_*).
const ERA_LABEL_HEIGHT: int = 64 # высота полосы над колонками под заголовки эпох
const ERA_LABEL_WIDTH: int = 200 # фиксированная ширина заголовка эпохи
const ERA_LINE_COLOR := Color(0.72, 0.72, 0.75, 1.0) # цвет вертикального разделителя эпох
const ERA_LINE_WIDTH: float = 2.0 # толщина вертикального разделителя эпох

# --- Внешние ссылки (заполняются в setup) ---
var current_label: Label # "Изучается: ..." (Label вверху панели)
var science_pool_label: Label # "Пул науки: ..." (общий пул наук)

# --- Внутренние узлы ---
var _scroll: ScrollContainer
var _inner: Control # большой Control, размер = вся площадь дерева
var _columns: Array = [] # [Control, Control, ...] по колонкам
var _tech_nodes: Dictionary = {} # tech_id -> {button, column, row}
var _arrows_layer: Control # Control, в котором _draw рисует стрелки
var _fonts_adjusted: bool = false # отложенный автоподбор шрифта уже отработал
var _hovered_tech_id: String = "" # ID технологии, на которую наведён курсор
var _related_techs: Dictionary = {} # tech_id -> bool, связанные технологии для подсветки

# --- Разделение по эпохам ---
var _era_labels: Array = [] # Label-заголовки эпох (очищаются в rebuild)
var _era_groups: Array = [] # [{era_id, era_name, col_start, col_end, x_center, x_boundary}]

# --- Кэш иконок технологий (рекурсивный обход res://icons, как в map_renderer) ---
var icon_paths: Dictionary = {} # имя файла -> полный путь
var icon_textures: Dictionary = {} # имя файла -> загруженная Texture2D

signal research_requested(tech_id: String)

func setup(parent: Control, current_lbl: Label, science_lbl: Label = null):
    current_label = current_lbl
    science_pool_label = science_lbl
    _build_tech_icon_index()
    _build_ui(parent)

func _build_ui(parent: Control):
    _scroll = ScrollContainer.new()
    _scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
    # Двусторонняя прокрутка нужна: при малом числе эпох по высоте скролл
    # не появляется, а при большом числе технологий в эпохе — появляется.
    _scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    _scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    parent.add_child(_scroll)

    _inner = Control.new()
    _inner.mouse_filter = Control.MOUSE_FILTER_PASS
    # custom_minimum_size выставляется в rebuild() под фактический размер дерева.
    _scroll.add_child(_inner)

func _compute_layout() -> Dictionary:
    # Возвращает:
    #   "columns"  : {col_index : [tech_id, ...]}
    #   "tech_col" : {tech_id   : col_index}
    #   "max_col_count" : int  (макс. число кнопок в одной колонке)
    var techs = GameData.technologies
    var col_for: Dictionary = {}

    # Корень (farming) — всегда колонка 0. Это явное правило ТЗ:
    # «открываемая со старта игры технология Растениеводство — у левого края».
    if _tech_exists("farming"):
        col_for["farming"] = 0

    # Итеративно: некоторые prerequisites могут ссылаться на технологии,
    # которые встретятся в JSON позже. Повторяем, пока раскладка не стабилизируется.
    for _it in range(20):
        var changed = false
        for tech in techs:
            var tid: String = tech["id"]
            if col_for.has(tid):
                continue
            var prereqs = tech.get("prerequisites", [])
            if prereqs.is_empty():
                col_for[tid] = 1
                changed = true
                continue
            var max_prereq_col := -1
            var all_known := true
            for group in prereqs:
                for req in group:
                    if not col_for.has(req):
                        all_known = false
                        break
                    max_prereq_col = max(max_prereq_col, col_for[req])
                if not all_known:
                    break
            if all_known:
                col_for[tid] = max_prereq_col + 1
                changed = true
        if not changed:
            break

    # Fallback: если остались без колонки (битая ссылка в prerequisites) —
    # кладём в колонку 1, чтобы не терять технологию из UI.
    for tech in techs:
        if not col_for.has(tech["id"]):
            col_for[tech["id"]] = 1

    # Нормализация по эпохам: сдвигаем технологии каждой эпохи вправо, чтобы
    # эпохи следовали по порядку (см. _normalize_era_columns). Это гарантирует,
    # что между группами эпох появится вертикальная линия-разделитель, даже
    # если поздняя технология раскладкой (по зависимостям) попала в колонку,
    # где большинство технологий — более ранней эпохи.
    if not GameData.eras.is_empty():
        col_for = _normalize_era_columns(col_for)

    # Раскладываем по колонкам.
    var columns: Dictionary = {}
    for tid in col_for:
        var c: int = col_for[tid]
        if not columns.has(c):
            columns[c] = []
        columns[c].append(tid)

    # Стартовая сортировка по id — детерминированный вход для barycenter,
    # чтобы результат не зависел от порядка в technologies.json.
    for c in columns:
        columns[c].sort()

    # --- «Умная» раскладка: barycenter heuristic (Sugiyama 1981) ---
    # Сортируем узлы в каждой колонке по **медиане** Y-позиций их соседей
    # (дети при down-sweep, родители при up-sweep). Это минимизирует
    # длину и количество пересечений стрелок: родитель и ребёнок
    # оказываются рядом по вертикали, а не разбросаны по всей колонке.
    #
    # Пример: animal_husbandry открывает plow, cheese_making, leatherworking.
    # Если их Y в колонке 2 оказывается в среднем около Y animal_husbandry
    # в колонке 1 — стрелки становятся короткими и не перекрываются.
    #
    # Медиана лучше среднего: среднее чувствительно к одному далёкому
    # выбросу, а медиана устойчива. Например, если у pottery 2 ребёнка
    # рядом и ещё 1 далеко внизу, среднее утащит pottery вниз, медиана — нет.
    var num_cols: int = 0
    for c in columns:
        if c + 1 > num_cols:
            num_cols = c + 1
    if num_cols > 1:
        var parents_map: Dictionary = _build_parents_map(techs)
        # Глобальный словарь Y-позиций: y_positions[node_id] = float(y).
        # ОБЯЗАТЕЛЬНО глобальный по ВСЕМ колонкам, иначе в down-sweep мы
        # не найдём родителей из предыдущих колонок, и related.is_empty()
        # для всех — barycenter = текущий индекс, сортировка ничего не меняет.
        # (Это и был баг в первой реализации: y_positions пересоздавался
        # на каждом вызове и содержал только текущую колонку.)
        var y_positions: Dictionary = {}
        for c in range(num_cols):
            for i in range(columns[c].size()):
                y_positions[columns[c][i]] = float(i)
        # Чередующиеся проходы down/up. 8 итераций — для 24 узлов хватает
        # сходиться; 4 иногда оставляет заметные пересечения.
        for _iter in range(8):
            for c in range(1, num_cols):
                _sort_column_by_barycenter(columns, c, parents_map, false, y_positions)
            for c in range(num_cols - 2, 0, -1):
                _sort_column_by_barycenter(columns, c, parents_map, true, y_positions)
        # Диагностический print — помогает понять, отработал ли алгоритм.
        # Видно в окне Output редактора Godot.
        print("[tech_tree] Layout result:")
        for c in range(num_cols):
            print("  col %d: %s" % [c, ", ".join(columns[c])])

    var max_col_count := 0
    for c in columns:
        if columns[c].size() > max_col_count:
            max_col_count = columns[c].size()

    return {
        "columns": columns,
        "tech_col": col_for,
        "max_col_count": max_col_count,
    }

func _build_parents_map(techs: Array) -> Dictionary:
    # child_id -> [parent_id, ...]  (для каждой технологии — её предки)
    # Используем в barycenter: средний Y родителей даёт «целевую» Y ребёнка.
    var parents_map: Dictionary = {}
    for tech in techs:
        var tid: String = tech["id"]
        var prereqs = tech.get("prerequisites", [])
        for group in prereqs:
            for req in group:
                if not parents_map.has(tid):
                    parents_map[tid] = []
                parents_map[tid].append(req)
    return parents_map

func _sort_column_by_barycenter(columns: Dictionary, col: int, parents_map: Dictionary, look_at_children: bool, y_positions: Dictionary) -> void:
    # Пересортировывает узлы в колонке col, минимизируя расстояние до
    # связанных узлов в соседних колонках.
    #   look_at_children=false: down-sweep — сортируем по медиане Y-родителей.
    #   look_at_children=true : up-sweep   — сортируем по медиане Y-детей.
    # y_positions — ГЛОБАЛЬНЫЙ словарь {node_id: y} по всем колонкам,
    # актуализируется после каждой сортировки. Без этого down-sweep не видит
    # родителей в предыдущих колонках и barycenter вырождается в индекс.
    var col_nodes: Array = columns.get(col, [])
    if col_nodes.is_empty():
        return

    # Считаем barycenter (на самом деле median) для каждого узла.
    var barycenters: Dictionary = {}
    for node_id in col_nodes:
        var related: Array = []
        if look_at_children:
            # Ищем узлы справа от col, для которых node_id — родитель.
            for c2 in range(col + 1, columns.size()):
                for other in columns[c2]:
                    var p_list: Array = parents_map.get(other, [])
                    if node_id in p_list:
                        related.append(other)
        else:
            # Ищем родителей node_id в уже отсортированных колонках слева.
            for p_id in parents_map.get(node_id, []):
                if y_positions.has(p_id):
                    related.append(p_id)
        if related.is_empty():
            # Нет связанных узлов — оставляем на текущей Y.
            barycenters[node_id] = y_positions.get(node_id, 0.0)
        else:
            # Медиана Y-позиций связанных узлов.
            var ys: Array = []
            for r in related:
                ys.append(y_positions.get(r, 0.0))
            ys.sort()
            barycenters[node_id] = _median(ys)

    # Сортируем колонку. Без лямбд — через пары [bary, id], это надёжнее,
    # чем sort_custom с Callable в строгом парсере GDScript.
    # Тай-брейкер по id (лексикографически) обеспечивает стабильность
    # при повторных rebuild() и одинаковых barycenters.
    var pairs: Array = []
    for node_id in col_nodes:
        pairs.append([barycenters.get(node_id, 0.0), node_id])
    pairs.sort()
    # Пары сортируются по первому элементу (bary), потом по второму (id) —
    # потому что Array в GDScript сравнивается поэлементно.
    var new_order: Array = []
    for i in range(pairs.size()):
        var p: Array = pairs[i]
        var node_id: String = p[1]
        new_order.append(node_id)
        # Обновляем глобальные Y-позиции — на следующей итерации другие
        # колонки будут опираться на свежий порядок этой.
        y_positions[node_id] = float(i)
    columns[col] = new_order

func _median(values: Array) -> float:
    # Медиана массива чисел. values уже отсортирован (для эффективности).
    var n: int = values.size()
    if n == 0:
        return 0.0
    if n % 2 == 1:
        return float(values[n / 2])
    return (float(values[n / 2 - 1]) + float(values[n / 2])) * 0.5

func _tech_exists(tech_id: String) -> bool:
    for t in GameData.technologies:
        if t["id"] == tech_id:
            return true
    return false

# Нормализация раскладки колонок по эпохам.
#
# Раскладка по зависимостям (см. _compute_layout) ставит технологию в колонку
# max(col[prereq]) + 1. При этом технология поздней эпохи может попасть в ту же
# колонку, что и технологии ранней эпохи — тогда по большинству колонка считается
# ранней, и группа поздней эпохи не образуется (нет разделителя).
#
# Здесь мы ПЕРЕРАСКЛДЫВАЕМ колонки так, чтобы все технологии каждой эпохи шли
# непрерывным блоком слева направо по порядку эпох (из GameData.eras). Внутри
# блока эпохи сохраняется относительный порядок колонок из исходной раскладки.
# Это гарантирует появление вертикальной линии-разделителя между эпохами.
#
# Возвращает новый словарь tech_id -> column.
func _normalize_era_columns(col_for: Dictionary) -> Dictionary:
    # Упорядоченный список id эпох (порядок из data/eras.json).
    var era_order: Array = []
    for era in GameData.eras:
        era_order.append(era.get("id", ""))

    # era_index для каждой технологии (0 — неизвестная/первая эпоха).
    var tech_era: Dictionary = {} # tech_id -> int
    for tid in col_for:
        var era_id: String = _get_tech_data(tid).get("era", "")
        var idx: int = era_order.find(era_id)
        tech_era[tid] = idx if idx >= 0 else 0

    # Собираем уникальные колонки каждой эпохи.
    var era_columns: Dictionary = {} # era_index -> [col, ...]
    for tid in col_for:
        var c: int = col_for[tid]
        var ei: int = tech_era[tid]
        if not era_columns.has(ei):
            era_columns[ei] = []
        if not era_columns[ei].has(c):
            era_columns[ei].append(c)

    # Перераскладка: каждая эпоха занимает непрерывный блок колонок.
    var sorted_era: Array = era_columns.keys()
    sorted_era.sort()
    var result: Dictionary = {}
    var global_col: int = 0
    for ei in sorted_era:
        var cols: Array = era_columns[ei]
        cols.sort()
        # old_col -> new_col внутри блока этой эпохи.
        var mapping: Dictionary = {}
        var target: int = global_col
        for old in cols:
            mapping[old] = target
            target += 1
        # Применяем ко всем технологиям этой эпохи.
        for tid in col_for:
            if tech_era[tid] == ei:
                result[tid] = mapping[col_for[tid]]
        global_col = target

    return result

# --- Разделение по эпохам: хелперы ---

# Возвращает человекочитаемое имя эпохи по её id (как в technologies_tab.gd).
# Источник — data/eras.json, загружается в GameData.eras.
# Если эпоха не найдена — возвращаем сам id (fallback).
func _get_era_name(era_id: String) -> String:
    if era_id.is_empty():
        return ""
    for era in GameData.eras:
        if era.get("id", "") == era_id:
            return era.get("name", era_id)
    return era_id

# Возвращает id эпохи, к которой относится колонка column_id.
# Колонка может содержать технологии разных эпох (редко, но бывает —
# например, древняя технология, открывающая античную). Тогда берём
# эпоху, которая встречается в колонке чаще всего. Если колонка пуста
# или эпохи не указаны — возвращаем "" (нет группы).
func _column_era(columns: Dictionary, column_id: int) -> String:
    var techs_in_col: Array = columns.get(column_id, [])
    if techs_in_col.is_empty():
        return ""
    var counts: Dictionary = {} # era_id -> количество
    for tid in techs_in_col:
        var era_id: String = _get_tech_data(tid).get("era", "")
        if era_id.is_empty():
            continue
        counts[era_id] = counts.get(era_id, 0) + 1
    if counts.is_empty():
        return ""
    var best: String = ""
    var best_count: int = 0
    for era_id in counts:
        if counts[era_id] > best_count:
            best = era_id
            best_count = counts[era_id]
    return best

# Вычисляет список групп эпох: последовательные колонки одной эпохи.
# Возвращает массив словарей:
#   {era_id, era_name, col_start, col_end, x_center, x_boundary}
# x_center  — X-центр группы (для заголовка-надписи).
# x_boundary — X границы группы: правая граница последней колонки группы
#              (по ней рисуется вертикальная линия-разделитель).
# x_boundary == -1 означает «крайняя правая группа» — линия не рисуется
# (справа за деревом нет следующей эпохи).
#
# ВАЖНО: эпоха колонки определяется ПОФАКТУ, по большинству технологий
# в колонке (см. _column_era). Благодаря нормализации в _normalize_era_columns
# все технологии каждой эпохи стоят непрерывным блоком слева направо, поэтому
# группы эпох получаются чистыми, а между ними рисуется вертикальный разделитель.
# Раскладка по зависимостям (barycenter) внутри каждой эпохи сохраняется.
func _compute_era_groups(columns: Dictionary, num_cols: int) -> Array:
    var groups: Array = []
    var current_era: String = ""
    var group_start: int = -1

    for c in range(num_cols):
        var era_id: String = _column_era(columns, c)
        if era_id == current_era:
            continue
        # Эпоха сменилась — закрываем предыдущую группу (если была).
        if current_era != "" and group_start >= 0:
            groups.append(_make_era_group(current_era, group_start, c - 1))
        current_era = era_id
        group_start = c

    # Последняя группа.
    if current_era != "" and group_start >= 0:
        groups.append(_make_era_group(current_era, group_start, num_cols - 1))

    return groups

# Создаёт словарь группы эпохи по диапазону колонок [col_start..col_end].
func _make_era_group(era_id: String, col_start: int, col_end: int) -> Dictionary:
    var first_x: float = _col_x(col_start) # левый край первой колонки группы
    var last_right: float = _col_x(col_end) + BUTTON_WIDTH + COL_GAP / 2 # середина между колонками
    return {
        "era_id": era_id,
        "era_name": _get_era_name(era_id),
        "col_start": col_start,
        "col_end": col_end,
        "x_center": (first_x + last_right) * 0.5,
        "x_boundary": last_right, # правая граница группы — там линия
    }

# X-координата левого края колонки c (в координатах _inner).
# Учитывает только горизонтальный отступ COL_PADDING, без сдвига вниз
# под заголовки эпох (вертикальное смещение колонок на высоту заголовков
# выполняется отдельно в rebuild() через _col_y()).
func _col_x(c: int) -> float:
    return float(COL_PADDING + c * (BUTTON_WIDTH + COL_GAP))

# Y-координата верха колонок с учётом полосы заголовков эпох.
# Колонки сдвигаются вниз на ERA_LABEL_HEIGHT, чтобы сверху осталось
# место под заголовки эпох.
func _col_y() -> float:
    return float(ERA_LABEL_HEIGHT + COL_PADDING)

# Создаёт Label-заголовки эпох над свежими колонками. Вызывается из rebuild().
# Заголовки добавляются в _inner, поэтому прокручиваются вместе с деревом.
func _create_era_labels(layout_columns: Dictionary, num_cols: int) -> void:
    # Сначала удаляем старые заголовки (если был пересбор).
    for l in _era_labels:
        if is_instance_valid(l):
            l.queue_free()
    _era_labels.clear()

    _era_groups = _compute_era_groups(layout_columns, num_cols)
    if _era_groups.is_empty():
        return

    # Высота полосы сверху — сверху (y=0) занимает полоса,
    # Label размещаем в середине полосы.
    for group in _era_groups:
        if group["era_id"] == "antiquity":
            _create_antiquity_era_label(group)
        else:
            var lab := Label.new()
            lab.name = "EraLabel"
            lab.text = group["era_name"]
            lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
            lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
            lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
            lab.size = Vector2(ERA_LABEL_WIDTH, ERA_LABEL_HEIGHT)
            lab.custom_minimum_size = Vector2(ERA_LABEL_WIDTH, ERA_LABEL_HEIGHT)
            lab.add_theme_font_size_override("font_size", 14)
            lab.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95, 1.0))
            lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
            lab.position = Vector2(group["x_center"] - ERA_LABEL_WIDTH * 0.5, 0.0)
            _inner.add_child(lab)
            _era_labels.append(lab)

# Заголовок эпохи Античность с условием перехода: построен Рынок (0/1).
# Когда Рынок построен - (1/1) и зелёная галочка.
func _create_antiquity_era_label(group: Dictionary) -> void:
    var market_built := false
    for b in CityData.city_built_buildings:
        if b.get("id", "") == "market":
            market_built = true
            break
    var count_text: String = "1/1" if market_built else "0/1"
    var check: String = " [color=#4caf50]✔[/color]" if market_built else ""
    var icon_tag: String = ""
    if icon_paths.has("market.png"):
        icon_tag = "[img=18]" + icon_paths["market.png"] + "[/img] "
    var rtl := RichTextLabel.new()
    rtl.name = "EraLabel"
    rtl.bbcode_enabled = true
    rtl.fit_content = true
    rtl.scroll_active = false
    rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
    rtl.size = Vector2(ERA_LABEL_WIDTH, ERA_LABEL_HEIGHT)
    rtl.custom_minimum_size = Vector2(ERA_LABEL_WIDTH, ERA_LABEL_HEIGHT)
    rtl.add_theme_font_size_override("normal_font_size", 12)
    rtl.add_theme_color_override("default_color", Color(0.9, 0.9, 0.95, 1.0))
    rtl.position = Vector2(group["x_center"] - ERA_LABEL_WIDTH * 0.5, 0.0)
    rtl.text = "[center]" + group["era_name"] + "[/center]\n" + "[center][color=#c9c9c9]Условие для перехода:[/color] построен " + icon_tag + "Рынок (" + count_text + ")" + check + "[/center]"
    _inner.add_child(rtl)
    _era_labels.append(rtl)

func rebuild():
    # Полная перестройка: очищаем и создаём заново.
    # Вызывается при структурных изменениях (новое исследование, завершение и т.д.).
    for col in _columns:
        col.queue_free()
    _columns.clear()
    _tech_nodes.clear()

    if is_instance_valid(_arrows_layer):
        _arrows_layer.queue_free()
        _arrows_layer = null

    if GameData.technologies.is_empty():
        return

    var layout = _compute_layout()
    var columns: Dictionary = layout["columns"]
    var max_col_count: int = layout["max_col_count"]

    # Размер _inner под всё дерево.
    # Типы указываем явно: max() и .keys().max() возвращают Variant,
    # и := не сможет вывести тип из выражения, где они участвуют.
    var num_cols: int = 1
    if not columns.is_empty():
        num_cols = int(columns.keys().max()) + 1
    var col_height: int = max_col_count * (BUTTON_HEIGHT + BUTTON_VERTICAL_GAP) - BUTTON_VERTICAL_GAP
    var total_width: int = COL_PADDING * 2 + num_cols * BUTTON_WIDTH + max(0, num_cols - 1) * COL_GAP
    # Высота включает полосу заголовков эпох (ERA_LABEL_HEIGHT) — колонки
    # сдвигаются вниз на эту величину, а сверху остаётся место под заголовки.
    var total_height: int = ERA_LABEL_HEIGHT + COL_PADDING * 2 + max(col_height, BUTTON_HEIGHT)
    _inner.size = Vector2(total_width, total_height)
    _inner.custom_minimum_size = Vector2(total_width, total_height)

    # Создаём заголовки эпох (полоска сверху). Делаем это ДО колонок,
    # чтобы заголовки оказались под ними в z-порядке (стрелки рисуются
    # последним слоем поверх всего).
    _create_era_labels(columns, num_cols)

    # Колонки располагаем вручную внутри _inner (НЕ через HBoxContainer),
    # чтобы позиции были предсказуемы для рисования стрелок.
    for c in range(num_cols):
        var col_container := Control.new()
        col_container.position = Vector2(
            _col_x(c),
            _col_y() # сдвиг вниз на высоту полосы заголовков эпох
        )
        col_container.size = Vector2(BUTTON_WIDTH, max(col_height, BUTTON_HEIGHT))
        col_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
        _inner.add_child(col_container)
        _columns.append(col_container)

        var techs_in_col: Array = columns.get(c, [])
        var col_count: int = techs_in_col.size()
        for i in range(col_count):
            var tech_id: String = techs_in_col[i]
            var tech_data = _get_tech_data(tech_id)
            if tech_data.is_empty():
                continue

            var btn = _create_tech_button(tech_data)
            # Равномерное распределение по колонке; если колонка короче
            # самой высокой — центрируем по вертикали.
            var step := BUTTON_HEIGHT + BUTTON_VERTICAL_GAP
            var y_offset := 0.0
            if max_col_count > col_count:
                y_offset = (max_col_count - col_count) * step * 0.5
            btn.position = Vector2(0, y_offset + i * step)
            col_container.add_child(btn)
            _tech_nodes[tech_id] = {
                "button": btn,
                "column": c,
                "row": i,
            }

    # Слой со стрелками — поверх колонок. Без z_index: _arrows_layer
    # добавляется последним в _inner, поэтому по умолчанию рисуется
    # поверх колонок. z_index здесь ставить НЕЛЬЗЯ — иначе стрелки
    # поднимутся над всеми Control'ами в canvas layer, включая
    # tech_popup (окно сообщения об изученной технологии).
    _arrows_layer = Control.new()
    _arrows_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
    _arrows_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _inner.add_child(_arrows_layer)
    _arrows_layer.draw.connect(_on_arrows_draw)

    # Состояния (цвета, прогресс, тултипы) — поверх свежесозданных кнопок.
    _update_states()
    _arrows_layer.queue_redraw()
    _update_status_label()

    # Автоподбор шрифта требует, чтобы лейаут уже посчитался.
    # Делаем это на ближайшем кадре.
    _fonts_adjusted = false
    _adjust_fonts.call_deferred()

func _create_tech_button(tech_data: Dictionary) -> Button:
    var btn := Button.new()
    btn.custom_minimum_size = Vector2(BUTTON_WIDTH, BUTTON_HEIGHT)
    btn.size = Vector2(BUTTON_WIDTH, BUTTON_HEIGHT)
    # Текст кнопки НЕ используем — он рисуется встроенным Label, и
    # его стиль зависит от Button, а нам нужен наш layout. Поэтому
    # просто оставляем text пустым и кладём внутрь свою структуру.
    btn.text = ""
    btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

    # MarginContainer вокруг содержимого — для отступов от бордюра кнопки.
    var margin := MarginContainer.new()
    margin.set_anchors_preset(Control.PRESET_FULL_RECT)
    margin.add_theme_constant_override("margin_left", 8)
    margin.add_theme_constant_override("margin_right", 8)
    margin.add_theme_constant_override("margin_top", 6)
    margin.add_theme_constant_override("margin_bottom", 6)
    margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
    btn.add_child(margin)

    # HBox: иконка + текст
    var hbox := HBoxContainer.new()
    hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
    hbox.add_theme_constant_override("separation", 8)
    hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
    margin.add_child(hbox)

    var icon_name: String = tech_data.get("icon", "")
    var icon_tex: Texture2D = _load_tech_icon(icon_name)
    var icon_rect := TextureRect.new()
    icon_rect.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
    icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    if icon_tex != null:
        icon_rect.texture = icon_tex
    hbox.add_child(icon_rect)

    var label := Label.new()
    label.name = "TechNameLabel"
    label.text = tech_data.get("name", tech_data["id"])
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    # Текст прижат к верхнему краю: внизу кнопки остаётся место под
    # маленькие иконки того, что открывает технология (_add_unlock_icons).
    label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    label.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
    # Базовый размер шрифта. Финальный подбирается в _adjust_fonts() на
    # следующем кадре, когда Godot уже рассчитал лейаут и знает
    # фактический get_line_count() / get_minimum_size().
    label.add_theme_font_size_override("font_size", 12)
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    hbox.add_child(label)

    # Прогресс-бар (виден только когда технология изучается) — узкая полоска
    # внизу кнопки. mouse_filter=ignore, чтобы не перехватывать клики.
    var progress := ProgressBar.new()
    progress.name = "TechProgress"
    progress.anchor_left = 0.0
    progress.anchor_right = 1.0
    progress.anchor_top = 1.0
    progress.anchor_bottom = 1.0
    progress.offset_top = -6
    progress.offset_bottom = 0
    progress.show_percentage = false
    progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
    progress.visible = false
    btn.add_child(progress)

    # Маленькие иконки внизу кнопки: всё, что открывает технология.
    _add_unlock_icons(btn, tech_data["id"])

    # Tooltip — встроенный механизм Godot. Покажется по наведению
    # после системной задержки (Project Settings → gui/timets/tooltip_delay_sec).
    var description: String = tech_data.get("description", "")
    if description.is_empty():
        description = "Описание отсутствует."
    var cost: int = int(tech_data.get("science_cost", 3))
    btn.tooltip_text = "%s\n\nНаука: %d" % [description, cost]

    # Клик — наверх, через сигнал.
    var tech_id: String = tech_data["id"]
    btn.pressed.connect(_on_tech_pressed.bind(tech_id))
    
    # Наведение — подсветка связанных технологий и стрелок.
    btn.mouse_entered.connect(_on_tech_button_mouse_entered.bind(tech_id))
    btn.mouse_exited.connect(_on_tech_button_mouse_exited.bind(tech_id))

    return btn

func _add_unlock_icons(btn: Button, tech_id: String):
    # Ряд маленьких иконок у нижнего края кнопки: всё, что открывает
    # технология (здания, улучшения, эффекты-модификаторы).
    # У каждой иконки свой tooltip_text — при наведении на иконку
    # показывается он, а не общий тултип технологии.
    var items: Array = _get_unlock_items(tech_id)
    if items.is_empty():
        return

    var row := HBoxContainer.new()
    row.name = "UnlockIconsRow"
    row.anchor_left = 0.25
    row.anchor_right = 1.0
    row.anchor_top = 1.0
    row.anchor_bottom = 1.0
    row.offset_top = - (UNLOCK_ICON_SIZE + UNLOCK_ICONS_MARGIN)
    row.offset_bottom = - UNLOCK_ICONS_MARGIN
    row.offset_left = 8
    row.offset_right = -8
    row.add_theme_constant_override("separation", 4)
    row.alignment = BoxContainer.ALIGNMENT_BEGIN
    row.mouse_filter = Control.MOUSE_FILTER_PASS
    btn.add_child(row)

    for item in items:
        var tex: Texture2D = _load_tech_icon(item.get("icon", ""))
        if tex == null:
            continue
        var icon := TextureRect.new()
        icon.custom_minimum_size = Vector2(UNLOCK_ICON_SIZE, UNLOCK_ICON_SIZE)
        icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
        icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        icon.texture = tex
        icon.tooltip_text = item.get("tip", "")
        icon.mouse_filter = Control.MOUSE_FILTER_PASS
        row.add_child(icon)

func _get_unlock_items(tech_id: String) -> Array:
    # Собирает список {"icon", "tip"} — всё, что открывается технологией.
    # Источники: здания (buildings.json), улучшения (improvements.json),
    # спецдействия (special_actions.json), эффекты-модификаторы
    # (modifiers.json, tech_modifiers с полями icon/name) и произвольный
    # список "unlock_effects": [ {"icon", "name"} ] в самой технологии.
    var result: Array = []
    var seen := {} # защита от дубликатов (одна и та же иконка+тултип)

    # Здания.
    for b in GameData.buildings:
        if b.get("unlock_tech", "") == tech_id:
            _add_unlock_item(result, seen, b.get("icon", ""), b.get("name", b.get("id", "")))

    # Улучшения (GameData.improvements — словарь id -> данные).
    for imp_id in GameData.improvements:
        var imp: Dictionary = GameData.improvements[imp_id]
        if imp.get("unlock_tech", "") == tech_id:
            _add_unlock_item(result, seen, imp.get("icon", ""), imp.get("name", imp_id))

    # Спецдействия (special_actions.json, поле unlock_tech).
    for sa_id in GameData.special_actions:
        var sa: Dictionary = GameData.special_actions[sa_id]
        if sa.get("unlock_tech", "") == tech_id:
            _add_unlock_item(result, seen, sa.get("icon", ""), sa.get("name", sa_id))

    # Эффекты-модификаторы технологии (modifiers.json -> tech_modifiers).
    var mods: Dictionary = GameData.modifiers
    for m in mods.get("tech_modifiers", []):
        if not (m is Dictionary):
            continue
        if m.get("tech_id", "") != tech_id:
            continue
        if m.has("icon"):
            var tip: String = m.get("name", "Эффект технологии")
            _add_unlock_item(result, seen, m["icon"], tip)

    # Произвольные эффекты, заданные прямо в технологии (technologies.json):
    # "unlock_effects": [ { "icon": "farm.png", "name": "Фермы: +50%" } ].
    var tech_data: Dictionary = _get_tech_data(tech_id)
    for eff in tech_data.get("unlock_effects", []):
        if eff is Dictionary:
            _add_unlock_item(result, seen, eff.get("icon", ""), eff.get("name", "Эффект технологии"))

    return result

func _add_unlock_item(result: Array, seen: Dictionary, icon_name: String, tip: String):
    if icon_name.is_empty():
        return
    var key := icon_name + "|" + tip
    if seen.has(key):
        return
    seen[key] = true
    result.append({"icon": icon_name, "tip": tip})

func _adjust_fonts() -> void:
    # Подбираем максимально крупный font_size, при котором название влезает
    # в 2 строки внутри кнопки. Запускаем отложенно, чтобы лейаут был готов.
    # Увеличиваем снизу вверх: стартуем с 10, пробуем 11, 12, 13, 14.
    if _fonts_adjusted:
        return
    if not is_inside_tree():
        return
    # Ждём один кадр, чтобы лейаут Label-ов посчитался.
    await get_tree().process_frame
    if not is_inside_tree():
        return
    for tech_id in _tech_nodes:
        var entry = _tech_nodes[tech_id]
        if not is_instance_valid(entry):
            continue
        var btn: Button = entry["button"]
        if not is_instance_valid(btn):
            continue
        var label: Label = _find_label_in_button(btn)
        if label == null or not is_instance_valid(label):
            continue
        var picked := 10
        for fs in [10, 11, 12, 13, 14]:
            if not is_instance_valid(label):
                return
            label.add_theme_font_size_override("font_size", fs)
            # Ждём ещё кадр, чтобы Label пересчитал get_line_count().
            await get_tree().process_frame
            if not is_inside_tree():
                return
            if not is_instance_valid(label):
                return
            if label.get_line_count() <= 2:
                picked = fs
            else:
                # Этот размер уже не влезает — откатываемся к предыдущему.
                break
        if is_instance_valid(label):
            label.add_theme_font_size_override("font_size", picked)
    _fonts_adjusted = true

func _find_label_in_button(btn: Button) -> Label:
    # В Godot 4 у Button есть встроенный label (btn.get_label_control() в 4.4+,
    # но мы добавляем свой под именем TechNameLabel).
    for child in btn.get_children():
        if child is MarginContainer:
            for c2 in child.get_children():
                if c2 is HBoxContainer:
                    for c3 in c2.get_children():
                        if c3 is Label and c3.name == "TechNameLabel":
                            return c3
    return null

# Строит индекс иконок рекурсивным обходом res://icons (как в map_renderer.gd:
# build_icon_index/_scan_folder), чтобы пути не хардкодились, а иконки
# находились по имени файла в любой подпапке.
func _build_tech_icon_index():
    icon_paths.clear()
    _scan_icon_folder("res://icons")

func _scan_icon_folder(folder_path: String):
    var dir = DirAccess.open(folder_path)
    if dir == null: return
    dir.list_dir_begin()
    var file_name = dir.get_next()
    while file_name != "":
        if dir.current_is_dir():
            _scan_icon_folder(folder_path.path_join(file_name))
        else:
            var full_path = folder_path.path_join(file_name)
            if icon_paths.has(file_name):
                print("Предупреждение: дубликат иконки ", file_name)
            icon_paths[file_name] = full_path
        file_name = dir.get_next()
    dir.list_dir_end()

func _load_tech_icon(icon_name: String) -> Texture2D:
    if icon_name.is_empty():
        return null
    if icon_textures.has(icon_name):
        return icon_textures[icon_name]
    if icon_paths.has(icon_name):
        var tex = load(icon_paths[icon_name])
        if tex is Texture2D:
            icon_textures[icon_name] = tex
            return tex
    return null

func _get_tech_data(tech_id: String) -> Dictionary:
    # Возвращаем пустой Dictionary вместо null, чтобы вызывающий код
    # мог свободно использовать subscript без проверок на null — Godot 4
    # в строгом режиме не любит `dict["key"]` на Variant-результате.
    for t in GameData.technologies:
        if t["id"] == tech_id:
            return t
    return {}

func _update_states():
    # Обновляем стили, прогресс и тултипы. Вызывается при лёгких изменениях
    # (тик, изменение состояния исследования) — без пересоздания кнопок.
    var unlocked = CityData.unlocked_technologies
    var current_id: String = CityData.current_research_tech_id

    for tech_id in _tech_nodes:
        var entry = _tech_nodes[tech_id]
        var btn: Button = entry["button"]
        var is_unlocked: bool = tech_id in unlocked
        var is_current: bool = tech_id == current_id
        var is_available: bool = CityData.is_tech_available(tech_id)

        _style_button(btn, is_unlocked, is_current, is_available, tech_id)

        # Прогресс-бар на кнопке (виден только у текущего исследования)
        var progress: ProgressBar = _find_progress_in_button(btn)
        if progress != null:
            if is_current:
                progress.visible = true
                progress.value = CityData.research_progress * 100.0
            else:
                progress.visible = false

        # Tooltip с актуальным состоянием
        var tech_data = _get_tech_data(tech_id)
        if not tech_data.is_empty():
            var desc: String = tech_data.get("description", "")
            if desc.is_empty():
                desc = "Описание отсутствует."
            var cost: int = int(tech_data.get("science_cost", 3))
            var extra := ""
            if is_unlocked:
                extra = "\n\n[Изучено]"
            elif is_current:
                extra = "\n\n[Изучается]"
            elif not is_available:
                if CityData.is_tech_era_allowed(tech_id):
                    var prereq: String = CityData.get_tech_prerequisites_text(tech_id)
                    if not prereq.is_empty():
                        extra = "\n\n[Требуется: %s]" % prereq
                else:
                    # Prereq могут быть выполнены, но эпоха технологии выше текущей.
                    var era_idx: int = CityData.get_tech_era_index(tech_id)
                    var era_name: String = ""
                    if era_idx >= 0 and era_idx < GameData.eras.size():
                        era_name = GameData.eras[era_idx].get("name", "")
                    if era_name.is_empty():
                        extra = "\n\n[Недоступно: требуется переход в следующую эпоху]"
                    else:
                        extra = "\n\n[Эпоха: %s — сначала перейдите в неё]" % era_name
            btn.tooltip_text = "%s\nНаука: %d%s" % [desc, cost, extra]
    
func _find_progress_in_button(btn: Button) -> ProgressBar:
    for child in btn.get_children():
        if child is ProgressBar and child.name == "TechProgress":
            return child
    return null

func _style_button(btn: Button, is_unlocked: bool, is_current: bool, is_available: bool, tech_id: String = ""):
    # Стили зависят от состояния. Все стили наследуют общие свойства
    # (бордюр, скругление), но отличаются фоном.
    var bg := Color(0.20, 0.20, 0.22)
    var hover := Color(0.25, 0.25, 0.27)
    var pressed := Color(0.18, 0.18, 0.20)
    var font_col := Color(0.6, 0.6, 0.6)
    var modulate := Color(0.75, 0.75, 0.75, 0.9)

    if is_unlocked:
        bg = Color(0.25, 0.45, 0.25)
        hover = Color(0.30, 0.55, 0.30)
        pressed = Color(0.20, 0.40, 0.20)
        font_col = Color(0.85, 1.0, 0.85)
        modulate = Color(1, 1, 1, 0.9)
    elif is_current:
        bg = Color(0.30, 0.40, 0.55)
        hover = Color(0.35, 0.45, 0.65)
        pressed = Color(0.25, 0.35, 0.50)
        font_col = Color(1.0, 1.0, 0.7)
        modulate = Color(1, 1, 1, 1)
    elif is_available:
        bg = Color(0.35, 0.35, 0.40)
        hover = Color(0.45, 0.45, 0.55)
        pressed = Color(0.30, 0.30, 0.35)
        font_col = Color.WHITE
        modulate = Color(1, 1, 1, 1)

    var style_normal := _make_button_stylebox(bg)
    var style_hover := _make_button_stylebox(hover)
    var style_pressed := _make_button_stylebox(pressed)
    var style_disabled := _make_button_stylebox(bg)

    btn.add_theme_stylebox_override("normal", style_normal)
    btn.add_theme_stylebox_override("hover", style_hover)
    btn.add_theme_stylebox_override("pressed", style_pressed)
    btn.add_theme_stylebox_override("disabled", style_disabled)
    btn.add_theme_color_override("font_color", font_col)
    btn.modulate = modulate
    
    # Подсветка рамки для связанных технологий при наведении.
    if not tech_id.is_empty() and _related_techs.has(tech_id):
        var border_color := Color(0.3, 0.7, 1.0, 1.0)
        style_normal.border_color = border_color
        style_hover.border_color = border_color
        style_pressed.border_color = border_color
        style_normal.set_border_width_all(3)
        style_hover.set_border_width_all(3)
        style_pressed.set_border_width_all(3)
        btn.add_theme_stylebox_override("normal", style_normal)
        btn.add_theme_stylebox_override("hover", style_hover)
        btn.add_theme_stylebox_override("pressed", style_pressed)
        btn.add_theme_stylebox_override("disabled", style_disabled)
    
    # Все кнопки остаются кликабельными — корректность старта исследования
    # проверяет CityData.start_research() и эмитит research_error в случае
    # конфликта (уже идёт другое, не выполнены требования и т.п.).
    btn.disabled = false

func _make_button_stylebox(bg_color: Color, border_width: int = 1) -> StyleBoxFlat:
    var s := StyleBoxFlat.new()
    s.bg_color = bg_color
    s.set_border_width_all(border_width)
    s.border_color = Color(0.10, 0.10, 0.10)
    s.set_corner_radius_all(4)
    return s

func refresh():
    # Полное обновление. Используется при структурных изменениях
    # (новое/завершённое исследование).
    rebuild()

func update_values():
    # Лёгкое обновление: только стили/тултипы/прогресс.
    _update_states()
    if is_instance_valid(_arrows_layer):
        _arrows_layer.queue_redraw()
    _update_status_label()

func update_progress():
    # Лёгкое обновление: только метка текущего исследования.
    _update_status_label()

func _update_status_label():
    if current_label == null:
        return
    # Скорость науки города (база + вклад работающих зданий науки; видна
    # только здесь, на вкладке «Технологии»). Здания копят науку в пул,
    # а пул расходуется на исследование — это и даёт фактический вклад.
    if science_pool_label != null and is_instance_valid(science_pool_label):
        science_pool_label.text = "Наука за тик: %.1f" % CityData.get_science_rate_per_tick()
    if CityData.current_research_tech_id != "":
        var tech_data = _get_tech_data(CityData.current_research_tech_id)
        if not tech_data.is_empty():
            var collected: float = CityData.get_research_science_collected()
            var cost: int = CityData.current_research_science_cost
            current_label.text = "Изучается: %s (наука: %.0f/%d)" % [tech_data["name"], collected, cost]
            return
        current_label.text = "Изучается: ???"
    else:
        current_label.text = "Нет текущего исследования"
func _on_tech_pressed(tech_id: String):
    emit_signal("research_requested", tech_id)

func _on_tech_button_mouse_entered(tech_id: String):
    if _hovered_tech_id == tech_id:
        return
    _hovered_tech_id = tech_id
    _update_related_techs(tech_id)
    _update_hover_states()

func _on_tech_button_mouse_exited(tech_id: String):
    if _hovered_tech_id != tech_id:
        return
    _hovered_tech_id = ""
    _related_techs.clear()
    _update_hover_states()

func _update_related_techs(tech_id: String):
    # Собираем ВСЮ цепочку связей: все предки до корней и все потомки до листьев.
    _related_techs.clear()
    _related_techs[tech_id] = true # сама технология тоже подсвечивается

    # Карта «ребёнок -> [предки]» и «предок -> [потомки]».
    var parents_map: Dictionary = {}
    var children_map: Dictionary = {}
    for tech in GameData.technologies:
        var tid: String = tech["id"]
        var prereqs = tech.get("prerequisites", [])
        for group in prereqs:
            for req in group:
                if not parents_map.has(tid):
                    parents_map[tid] = []
                parents_map[tid].append(req)
                if not children_map.has(req):
                    children_map[req] = []
                children_map[req].append(tid)

    # Все предки (рекурсивно, до корней).
    _collect_ancestors(tech_id, parents_map, _related_techs)
    # Все потомки (рекурсивно, до листьев).
    _collect_descendants(tech_id, children_map, _related_techs)

func _collect_ancestors(tech_id: String, parents_map: Dictionary, result: Dictionary) -> void:
    # Добавляет в result всех предков tech_id по цепочке (до корней).
    if not parents_map.has(tech_id):
        return
    for parent_id in parents_map[tech_id]:
        if result.has(parent_id):
            continue
        result[parent_id] = true
        _collect_ancestors(parent_id, parents_map, result)

func _collect_descendants(tech_id: String, children_map: Dictionary, result: Dictionary) -> void:
    # Добавляет в result всех потомков tech_id по цепочке (до листьев).
    if not children_map.has(tech_id):
        return
    for child_id in children_map[tech_id]:
        if result.has(child_id):
            continue
        result[child_id] = true
        _collect_descendants(child_id, children_map, result)

func _update_hover_states():
    # Обновляем стили кнопок и перерисовываем стрелки.
    _update_states()
    if is_instance_valid(_arrows_layer):
        _arrows_layer.queue_redraw()

func _on_arrows_draw():
    # Рисуем вертикальные линии-разделители между эпохами и стрелки
    # зависимостей. Координаты считаем в системе _arrows_layer (== _inner).
    if _arrows_layer == null:
        return

    # --- Вертикальные линии между эпохами (рисуются ВСЕГДА, не только при hover) ---
    # Линия проводится по правой границе каждой группы эпох, кроме последней
    # (справа от неё нет следующей эпохи). Тянется от верха до низа дерева.
    for i in range(_era_groups.size() - 1):
        var group = _era_groups[i]
        var x: float = group["x_boundary"]
        var y_top: float = 0.0
        var y_bottom: float = _inner.size.y
        _arrows_layer.draw_line(
            Vector2(x, y_top),
            Vector2(x, y_bottom),
            ERA_LINE_COLOR,
            ERA_LINE_WIDTH
        )

    # Стрелки показываем только при наведении на технологию.
    if _hovered_tech_id.is_empty():
        return

    var color_hover := Color(0.3, 0.7, 1.0, 1.0) # ярко-голубой для подсвечиваемых связей

    # Строим карту «родитель → список детей» из prerequisites.
    var children_map: Dictionary = {}
    for tech in GameData.technologies:
        var tid: String = tech["id"]
        var prereqs = tech.get("prerequisites", [])
        for group in prereqs:
            for req in group:
                if not children_map.has(req):
                    children_map[req] = []
                children_map[req].append(tid)

    var line_width := 2.0
    for parent_id in children_map:
        if not _tech_nodes.has(parent_id):
            continue
        var parent_entry = _tech_nodes[parent_id]
        var parent_col: Control = _columns[parent_entry["column"]]
        var parent_btn: Button = parent_entry["button"]
        # Правый край кнопки-родителя (в координатах _inner)
        var parent_right: Vector2 = parent_col.position + Vector2(
            parent_btn.position.x + parent_btn.size.x,
            parent_btn.position.y + parent_btn.size.y * 0.5
        )

        for child_id in children_map[parent_id]:
            if not _tech_nodes.has(child_id):
                continue
            var child_entry = _tech_nodes[child_id]
            var child_col: Control = _columns[child_entry["column"]]
            var child_btn: Button = child_entry["button"]
            # Левый край кнопки-ребёнка
            var child_left: Vector2 = child_col.position + Vector2(
                child_btn.position.x,
                child_btn.position.y + child_btn.size.y * 0.5
            )

            # При наведении показываем стрелки, оба конца которых входят
            # в подсвеченную цепочку (родитель и ребёнок — часть пути).
            var is_related: bool = _related_techs.has(parent_id) and _related_techs.has(child_id)
            if not is_related:
                continue

            # Связанные стрелки подсвечиваем голубым.
            var color: Color = color_hover

            # Путь стрелки: для соседних колонок — простой зигзаг,
            # для дальних — через свободный Y-коридор, чтобы не рисовать
            # поверх кнопок промежуточных колонок.
            var points := _build_arrow_path(
                parent_right, child_left,
                parent_entry["column"], child_entry["column"]
            )
            _arrows_layer.draw_polyline(points, color, line_width, true)
            _draw_arrow_head(child_left, Vector2(-1, 0), color, line_width)

func _draw_arrow_head(pos: Vector2, dir: Vector2, color: Color, line_width: float):
    # Маленький треугольник-стрелка на конце линии.
    var head_size := 8.0
    var perp := Vector2(-dir.y, dir.x) * head_size * 0.5
    var base: Vector2 = pos + dir * head_size
    var p1: Vector2 = base + perp
    var p2: Vector2 = base - perp
    var points := PackedVector2Array([pos, p1, p2])
    _arrows_layer.draw_colored_polygon(points, color)

func _column_gap_x(c: int) -> float:
    # X-координата середины зазора между колонкой c и c+1 (в координатах _inner).
    # Зазор пуст — вертикальные сегменты стрелок проводятся именно здесь,
    # чтобы не пересекать кнопки соседних колонок.
    return COL_PADDING + c * (BUTTON_WIDTH + COL_GAP) + BUTTON_WIDTH + COL_GAP * 0.5

func _find_free_y_between(parent_col: int, child_col: int, target_y: float) -> float:
    # Ищет свободный Y-уровень, на котором во ВСЕХ промежуточных колонках
    # (parent_col+1 .. child_col-1) нет кнопок. Возвращает Y, ближайший к
    # target_y, или -1, если свободного уровня не существует.
    #
    # Горизонтальный сегмент стрелки, идущий от колонки parent_col к child_col,
    # физически пересекает промежуточные колонки. Чтобы не рисовать поверх
    # кнопок, он должен пройти на Y, свободном от кнопок во всех этих колонках.
    var occupied: Array = [] # [y_start, y_end] занятых интервалов
    for c in range(parent_col + 1, child_col):
        var col: Control = _columns[c]
        for tech_id in _tech_nodes:
            var entry = _tech_nodes[tech_id]
            if entry["column"] != c:
                continue
            var btn: Button = entry["button"]
            var y: float = col.position.y + btn.position.y
            occupied.append([y, y + BUTTON_HEIGHT])
    if occupied.is_empty():
        # Нет промежуточных колонок — любой Y свободен.
        return target_y

    # Сортируем по y_start.
    occupied.sort()

    # Запас на толщину линии (2px) + небольшой отступ, чтобы линия не
    # касалась кнопок вплотную.
    var margin: float = 4.0
    var best_y: float = -1.0
    var best_dist: float = INF
    var cursor: float = 0.0 # начало текущего свободного промежутка

    for interval in occupied:
        var y_start: float = interval[0]
        var y_end: float = interval[1]
        if y_start - cursor > margin * 2.0:
            # Свободный промежуток [cursor, y_start] достаточно широк.
            var free_y: float = (cursor + y_start) * 0.5
            var dist: float = absf(free_y - target_y)
            if dist < best_dist:
                best_dist = dist
                best_y = free_y
        cursor = max(cursor, y_end)

    # Промежуток после последнего занятого интервала — до конца дерева.
    if _inner.size.y - cursor > margin * 2.0:
        var free_y: float = (cursor + _inner.size.y) * 0.5
        var dist: float = absf(free_y - target_y)
        if dist < best_dist:
            best_y = free_y

    return best_y

func _build_arrow_path(parent_right: Vector2, child_left: Vector2, parent_col: int, child_col: int) -> PackedVector2Array:
    # Строит ломаную линию стрелки от правого края родителя до левого края ребёнка.
    #
    # Для соседних колонок (child_col - parent_col == 1) — простой зигзаг:
    # вертикальный сегмент лежит в пустом зазоре между колонками и не
    # пересекает кнопки.
    #
    # Для дальних колонок (child_col - parent_col > 1) — путь через свободный
    # Y-коридор: вертикальные сегменты в зазорах между колонками, горизонтальный
    # сегмент на Y, свободном от кнопок во всех промежуточных колонках.
    if child_col - parent_col <= 1:
        var mid_x: float = (parent_right.x + child_left.x) * 0.5
        return PackedVector2Array([
            parent_right,
            Vector2(mid_x, parent_right.y),
            Vector2(mid_x, child_left.y),
            child_left,
        ])

    var target_y: float = (parent_right.y + child_left.y) * 0.5
    var free_y: float = _find_free_y_between(parent_col, child_col, target_y)
    if free_y < 0.0:
        # Свободного коридора нет — fallback на простой зигзаг.
        var mid_x: float = (parent_right.x + child_left.x) * 0.5
        return PackedVector2Array([
            parent_right,
            Vector2(mid_x, parent_right.y),
            Vector2(mid_x, child_left.y),
            child_left,
        ])

    var gap1_x: float = _column_gap_x(parent_col)
    var gap2_x: float = _column_gap_x(child_col - 1)
    return PackedVector2Array([
        parent_right,
        Vector2(gap1_x, parent_right.y),
        Vector2(gap1_x, free_y),
        Vector2(gap2_x, free_y),
        Vector2(gap2_x, child_left.y),
        child_left,
    ])

func _process(_delta: float) -> void:
    # Покадровое обновление прогресс-бара на кнопке текущей технологии:
    # research_progress растёт непрерывно (tick_research_science_continuous),
    # а _update_states вызывается только по тикам/событиям — без этого бар
    # дёргался и отставал от реального прогресса.
    if not is_visible_in_tree():
        return
    if CityData.current_research_tech_id == "":
        return
    var entry = _tech_nodes.get(CityData.current_research_tech_id)
    if entry == null:
        return
    var progress: ProgressBar = _find_progress_in_button(entry["button"])
    if progress != null and progress.visible:
        progress.value = CityData.research_progress * 100.0
