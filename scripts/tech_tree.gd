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
const ICON_SIZE: int = 32 # размер иконки слева от названия

# --- Внешние ссылки (заполняются в setup) ---
var current_label: Label # "Изучается: ..." (Label вверху панели)
var progress_bar: ProgressBar # прогресс-бар текущего исследования

# --- Внутренние узлы ---
var _scroll: ScrollContainer
var _inner: Control # большой Control, размер = вся площадь дерева
var _columns: Array = [] # [Control, Control, ...] по колонкам
var _tech_nodes: Dictionary = {} # tech_id -> {button, column, row}
var _arrows_layer: Control # Control, в котором _draw рисует стрелки
var _fonts_adjusted: bool = false # отложенный автоподбор шрифта уже отработал
var _hovered_tech_id: String = "" # ID технологии, на которую наведён курсор
var _related_techs: Dictionary = {} # tech_id -> bool, связанные технологии для подсветки

# --- Плавная анимация прогресс-бара ---
# При обновлении на тике ставим _progress_target, а в _process догоняем
# progress_bar.value с фиксированной скоростью. Без этого прогресс-бар
# дёргается скачками раз в 2 секунды (PRODUCTION_INTERVAL).
var _progress_target: float = 0.0
const PROGRESS_INTERP_SPEED: float = 60.0 # единиц/сек (0..100)

signal research_requested(tech_id: String)

func setup(parent: Control, current_lbl: Label, progress: ProgressBar):
    current_label = current_lbl
    progress_bar = progress
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
    var total_height: int = COL_PADDING * 2 + max(col_height, BUTTON_HEIGHT)
    _inner.size = Vector2(total_width, total_height)
    _inner.custom_minimum_size = Vector2(total_width, total_height)

    # Колонки располагаем вручную внутри _inner (НЕ через HBoxContainer),
    # чтобы позиции были предсказуемы для рисования стрелок.
    for c in range(num_cols):
        var col_container := Control.new()
        col_container.position = Vector2(
            COL_PADDING + c * (BUTTON_WIDTH + COL_GAP),
            COL_PADDING
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
    label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    label.size_flags_vertical = Control.SIZE_EXPAND_FILL
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

func _load_tech_icon(icon_name: String) -> Texture2D:
    if icon_name.is_empty():
        return null
    # Иконки раскиданы по нескольким папкам. Ищем в порядке убывания
    # вероятности нахождения. .import для PNG идёт в комплекте — главное,
    # чтобы исходник был на диске.
    var candidates := [
        "res://icons/tech/" + icon_name,
        "res://icons/resources/raw/" + icon_name,
        "res://icons/resources/products/" + icon_name,
        "res://icons/" + icon_name,
    ]
    for path in candidates:
        if ResourceLoader.exists(path):
            var tex = load(path)
            if tex is Texture2D:
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
                var prereq: String = CityData.get_tech_prerequisites_text(tech_id)
                if not prereq.is_empty():
                    extra = "\n\n[Требуется: %s]" % prereq
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
    if current_label == null or progress_bar == null:
        return
    if CityData.current_research_tech_id != "":
        var tech_data = _get_tech_data(CityData.current_research_tech_id)
        if not tech_data.is_empty():
            var collected: float = CityData.get_research_science_collected()
            var cost: int = CityData.current_research_science_cost
            current_label.text = "Изучается: %s (наука: %.0f/%d)" % [tech_data["name"], collected, cost]
            # Не присваиваем progress_bar.value напрямую — иначе он дёргается
            # скачками раз в PRODUCTION_INTERVAL. Вместо этого задаём target,
            # а в _process догоняем с фиксированной скоростью.
            _progress_target = CityData.research_progress * 100.0
            return
        current_label.text = "Изучается: ???"
        _progress_target = 0.0
    else:
        current_label.text = "Нет текущего исследования"
        _progress_target = 0.0

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
    # Собираем все связанные технологии: прямые предки и потомки.
    _related_techs.clear()
    _related_techs[tech_id] = true # сама технология тоже подсвечивается

    # Прямые предки (родители)
    var parents_map: Dictionary = {}
    for tech in GameData.technologies:
        var tid: String = tech["id"]
        var prereqs = tech.get("prerequisites", [])
        for group in prereqs:
            for req in group:
                if not parents_map.has(tid):
                    parents_map[tid] = []
                parents_map[tid].append(req)

    if parents_map.has(tech_id):
        for parent_id in parents_map[tech_id]:
            _related_techs[parent_id] = true

    # Потомки (дети)
    for tech in GameData.technologies:
        var tid: String = tech["id"]
        var prereqs = tech.get("prerequisites", [])
        for group in prereqs:
            if tech_id in group:
                _related_techs[tid] = true
                break

func _update_hover_states():
    # Обновляем стили кнопок и перерисовываем стрелки.
    _update_states()
    if is_instance_valid(_arrows_layer):
        _arrows_layer.queue_redraw()

func _on_arrows_draw():
    # Рисуем стрелки от каждой технологии к её наследникам.
    # Координаты считаем в системе _arrows_layer (== _inner).
    if _arrows_layer == null:
        return

    var unlocked = CityData.unlocked_technologies
    var current_id: String = CityData.current_research_tech_id
    var color_unlocked := Color(0.6, 0.9, 0.6, 0.9)
    var color_active := Color(0.9, 0.85, 0.4, 0.9) # родитель изучен, ребёнок ещё нет
    var color_locked := Color(0.4, 0.4, 0.4, 0.5)
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

            # Определяем цвет стрелки
            var color: Color = color_active
            var parent_unlocked: bool = parent_id in unlocked
            var child_unlocked: bool = child_id in unlocked
            if parent_unlocked and child_unlocked:
                color = color_unlocked
            elif not parent_unlocked:
                color = color_locked
            
            # Если есть наведённая технология — подсвечиваем связанные стрелки.
            if not _hovered_tech_id.is_empty():
                var is_related: bool = (parent_id == _hovered_tech_id or child_id == _hovered_tech_id)
                if is_related:
                    color = color_hover
                else:
                    # Несвязанные стрелки затемняем.
                    color.a = 0.2

            # Зигзаг: горизонталь от родителя, вертикаль в середине, горизонталь к ребёнку.
            var mid_x: float = (parent_right.x + child_left.x) * 0.5
            var points := PackedVector2Array([
                parent_right,
                Vector2(mid_x, parent_right.y),
                Vector2(mid_x, child_left.y),
                child_left,
            ])
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

func _process(delta: float) -> void:
    # Плавная интерполяция прогресс-бара исследования. Без неё бар
    # дёргался скачками раз в PRODUCTION_INTERVAL (2 секунды).
    #
    # research_progress теперь растёт непрерывно (см. tick_research_science_continuous
    # в CityData), поэтому обновляем target каждый кадр, а не по тику —
    # иначе между тиками бар стоял бы на месте, а в момент тика прыгал.
    #
    # is_visible_in_tree() отсекает работу, когда city_ui скрыт — нечего
    # обновлять. Внутри активной вкладки _process работает каждый кадр,
    # но тело тривиальное (пара арифметических операций).
    if progress_bar == null:
        return
    if not is_visible_in_tree():
        return
    if CityData.current_research_tech_id != "":
        _progress_target = CityData.research_progress * 100.0
    else:
        _progress_target = 0.0
    var diff: float = _progress_target - progress_bar.value
    if absf(diff) < 0.1:
        if progress_bar.value != _progress_target:
            progress_bar.value = _progress_target
        return
    var step: float = signf(diff) * PROGRESS_INTERP_SPEED * delta
    if absf(step) >= absf(diff):
        progress_bar.value = _progress_target
    else:
        progress_bar.value += step
