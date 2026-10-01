# control_panel.gd
# Панель управления гексом в нижней части игровой карты.
#
# Логика:
#   - Панель видна всегда, но содержимое появляется по клику ЛКМ на гекс.
#   - Левая (большая) часть — полная информация о гексе (как в расширенном тултипе).
#   - Правая (меньшая) часть — кнопки действий (постройка улучшений, спец-действия,
#     управление рабочим, отмена стройки).
#   - Клик по кнопке действия открывает «превью»: расчёт производства с учётом
#     всех модификаторов + кнопки «Построить» и «Отменить».
#   - ESC или клик по другому гексу сбрасывают превью.
#   - Недоступные действия — серые, с тултипом причины («нужна технология»,
#     «нет труда», «нужна пристань» и т.п.).
#
# Панель реагирует на внешние изменения через сигналы (см. main_map.gd):
#   worker_manager.assignment_changed, build_manager.build_completed/build_cancelled,
#   CityData.city_updated, CityData.research_completed, expansion_manager.territory_expanded.
extends Panel

# id спецдействия «Построить дорогу» в data/special_actions.json. Единственное
# место, где панель знает про дорогу по имени: и кнопку на гексе городка, и
# особый блок цены в превью.
const ROAD_ACTION_ID := "build_road"

# Тип действия «Улучшить дорогу». Это НЕ спецдействие из data/special_actions.json:
# улучшение не меняет содержимое гекса и не имеет своей work_cost (цена участка
# берётся из уровня дороги, см. roads.json), поэтому оно живёт как отдельный
# тип действия панели, а не как ещё одна запись в общем списке.
const UPGRADE_ROAD_TYPE := "upgrade_road"

# Ссылки на узлы (заполняются из main_map.gd через initialize()).
var main_map: Node
var map_tooltip: MapTooltip
var worker_manager: Node
var build_manager: Node

func _ready():
    _setup_collapse_button()

# Клик ЛКМ по пустому месту панели (мимо кнопок и скроллов) снимает
# выделение гекса. Кнопки и прокручиваемые области поглощают клики сами,
# поэтому сюда событие доходит только для пустого фона панели.
func _gui_input(event: InputEvent):
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
            and not event.pressed:
        if has_selection():
            main_map.clear_selection()

# --- Сворачивание/разворачивание панели ---

# Высота свёрнутой панели = высота кнопки-переключателя.
const _COLLAPSED_HEIGHT := 28.0

var _toggle_btn: Button
var _collapsed := false
var _saved_offset_top := -1.0

# Создаёт кнопку-переключатель в правом верхнем углу панели.
# Кнопка привязана анкорами к правому верхнему углу, поэтому остаётся на месте
# при изменении размера окна/панели.
func _setup_collapse_button():
    _toggle_btn = Button.new()
    _toggle_btn.text = "▼"
    _toggle_btn.tooltip_text = tr("Collapse panel")
    _toggle_btn.focus_mode = Control.FOCUS_NONE
    _toggle_btn.flat = true
    _toggle_btn.custom_minimum_size = Vector2(28, 24)
    _toggle_btn.pressed.connect(_toggle_collapsed)
    # Анкоры: правый верхний угол панели с небольшим отступом.
    _toggle_btn.anchor_left = 1.0
    _toggle_btn.anchor_right = 1.0
    _toggle_btn.anchor_top = 0.0
    _toggle_btn.anchor_bottom = 0.0
    _toggle_btn.offset_left = -32.0
    _toggle_btn.offset_right = -4.0
    _toggle_btn.offset_top = 2.0
    _toggle_btn.offset_bottom = 26.0
    add_child(_toggle_btn)

# Переключает панель между свернутым и развернутым состоянием.
func _toggle_collapsed():
    _set_collapsed(not _collapsed)

func _set_collapsed(collapsed: bool):
    if _collapsed == collapsed:
        return
    _collapsed = collapsed

    if _collapsed:
        # Запоминаем текущую высоту и поднимаем верхний край панели так,
        # чтобы осталась полоска высотой с кнопку.
        # ВАЖНО: панель растянута по вертикали (anchor_top=0, anchor_bottom=1),
        # поэтому высота задаётся разницей offset_bottom - offset_top,
        # а не абсолютными координатами size.y.
        _saved_offset_top = offset_top
        offset_top = offset_bottom - _COLLAPSED_HEIGHT
        _set_content_visible(false)
        _toggle_btn.text = "▲"
        _toggle_btn.tooltip_text = tr("Expand panel")
    else:
        if _saved_offset_top >= 0.0:
            offset_top = _saved_offset_top
        _set_content_visible(true)
        _toggle_btn.text = "▼"
        _toggle_btn.tooltip_text = tr("Collapse panel")

# Скрывает/показывает содержимое панели (при сворачивании остаётся только кнопка).
func _set_content_visible(visible_now: bool):
    for node_path in ["SepInfoPreview", "SepPreviewActions", "PreviewContainer", "InfoVBox", "ActionsVBox"]:
        var child = get_node_or_null(NodePath(node_path))
        if child != null:
            child.visible = visible_now

# Текущее выделение и превью.
var _selected_hex = null # { "row": int, "col": int }
var _preview_action = null # { "type": String, "imp_id": String, "target_res_id": String, "label": String }
# Последняя «эпоха» отображения ресурсов (CityData.resource_display_interval):
# тиковый путь on_city_updated() перерисовывает инфо-колонку и превью только
# когда эпоха изменилась; событийный путь (refresh()/_refresh(), клик, действие)
# обновляется мгновенно и синхронизирует эпоху.
var _display_epoch: int = -1

# Ссылки на дочерние узлы UI.
var _info_label: RichTextLabel
var _products_container: VBoxContainer
var _actions_container: FlowContainer
var _preview_container: VBoxContainer
# Фиксированная строка заголовка превью (вне области прокрутки): подпись
# действия + кнопки «Начать»/«Отменить». Находится над PreviewScroll, поэтому
# всегда видна, даже когда содержимое колонки прокручено.
var _preview_header_container: VBoxContainer

# Снимок состояния кнопок действий, при котором их строили в последний раз.
# Используется, чтобы НЕ пересоздавать кнопки (и их ОС-тултипы) на каждом
# игровом тике: CityData.city_updated эмитится раз в SIMULATION_TICK из
# do_tick(), и без этого _build_actions() каждый тик уничтожал бы кнопки
# вместе с их тултипами «Нужна технология: ...», «Нет труда: ...» и т.п.
# (тот же паттерн, что и _last_panel_state в building_panel.gd /
# _needs_full_refresh в city_ui.gd).
# Формат: {"row": int, "col": int, "actions": Array}
var _last_actions_snapshot: Dictionary = {}

# Снимок состояния блока превью, при котором его построили в последний раз.
# Аналогично _last_actions_snapshot: не пересоздаём элементы превью (в т.ч.
# кнопки «Построить»/«Отменить» вместе с их ОС-тултипами) на каждом игровом
# тике, если выбор действия не менялся.
# Формат: {"row": int, "col": int, "type": String, "label": String, "imp_id": String,
#          "action_id": String, "target_res_id": Variant, "eff_res": String}
var _last_preview_snapshot: Dictionary = {}

func initialize(main_node: Node):
    main_map = main_node
    map_tooltip = main_node.map_tooltip
    worker_manager = main_node.worker_manager
    build_manager = main_node.build_manager

    _info_label = $InfoVBox/InfoScroll/InfoContent/InfoLabel
    _info_label.bbcode_enabled = true
    _products_container = $InfoVBox/InfoScroll/InfoContent/ProductsContainer
    _actions_container = $ActionsVBox/ActionsScroll/ActionsContent/ActionsContainer
    _preview_container = $PreviewContainer/PreviewScroll/PreviewContent
    _preview_header_container = $PreviewContainer/PreviewHeader

    # Панель видна всегда, но содержимое пустое, пока не выбран гекс.
    clear_selection()

# Вызывается при клике ЛКМ на гекс (row, col).
func select_hex(row: int, col: int):
    _selected_hex = {"row": row, "col": col}
    _preview_action = null
    _refresh()

# Снимает выделение и очищает панель.
func clear_selection():
    _selected_hex = null
    _preview_action = null
    _refresh()

# Сбрасывает только превью действия (ESC или клик по другому гексу).
func clear_preview():
    _preview_action = null
    _refresh()

# Возвращает true, если есть активное превью действия.
func has_preview() -> bool:
    return _preview_action != null

# Возвращает true, если есть выделенный гекс.
func has_selection() -> bool:
    return _selected_hex != null

# Возвращает выделенный гекс или null.
func get_selected_hex():
    return _selected_hex

# Тиковое обновление (CityData.city_updated, подключается в main_map._ready):
# левая колонка (местность, «Производит/Потребляет … за тик»), список
# продукции и превью действия обновляются с интервалом отображения ресурсов
# (CityData.resource_display_interval) — их числа раньше прыгали каждый тик.
# Кнопки действий при этом поддерживаются каждый тик, как раньше: их тултипы
# по дизайну не содержат значений, меняющихся каждый тик (см.
# комментарий в _build_actions), а снапшот _last_actions_snapshot не даёт
# пересоздать кнопки без реальных изменений.
func on_city_updated():
    if _selected_hex == null:
        _clear_ui()
        return
    var row = _selected_hex.row
    var col = _selected_hex.col
    if not main_map.is_hex_on_map(row, col):
        clear_selection()
        return
    if CityData.resource_display_due(_display_epoch):
        _refresh()
        return
    # Интервал ещё не прошёл: поддерживаем только доступность кнопок действий.
    var tile = main_map.get_tile_data(row, col)
    if tile == null:
        clear_selection()
        return
    _build_actions(row, col, tile)

# Обновляет панель. Вызывается при внешних изменениях (сигналы) и при
# выделении/сбросе. Если выделенного гекса больше нет на карте (например,
# загружен сейв с картой другого размера) — снимаем выделение.
# Проверка именно по границам КАРТЫ: выделять гексы вне Региона (туман войны,
# территория городков) теперь можно — там доступна разведка.
func refresh():
    if _selected_hex == null:
        _clear_ui()
        return
    var row = _selected_hex.row
    var col = _selected_hex.col
    if not main_map.is_hex_on_map(row, col):
        clear_selection()
        return
    _refresh()

func _refresh():
    # Событийное обновление (клик по гексу, действие, исследование, освоение):
    # всё рисуется сразу и синхронизирует эпоху отображения ресурсов — по
    # интервалу ждёт только тиковое обновление (см. on_city_updated).
    _display_epoch = CityData.resource_display_epoch
    if _selected_hex == null:
        _clear_ui()
        return
    var row = _selected_hex.row
    var col = _selected_hex.col
    var tile = main_map.get_tile_data(row, col)
    if tile == null:
        clear_selection()
        return

    # --- Левая часть: полная информация о гексе ---
    # Гекс в тумане войны: местность, ресурсы и улучшения игроку не известны —
    # вместо информации показываем заглушку. Действия справа (разведка)
    # остаются: они содержимое гекса не раскрывают (см. main_map.is_hex_in_fog).
    if main_map.is_hex_in_fog(row, col):
        _info_label.text = tr("Area not scouted — information unavailable.\n\nTerrain, resources and improvements become known after scouting.")
        map_tooltip.render_products([], _products_container, true)
    else:
        var info = map_tooltip.build_hex_info(row, col, main_map.tile_data, main_map.city_row, main_map.city_col)
        _info_label.text = info["text"]
        map_tooltip.render_products(info["products"], _products_container, true)
        # Маршрут до города показываем ОТДЕЛЬНОЙ строкой в том же блоке: он
        # относится не к свойствам гекса, а к его связи с городом. Без него
        # игрок на улучшении не видит ни длины маршрута, ни его скорости, а
        # именно по ним решается, стоит ли улучшать дорогу.
        _append_route_info(row, col)

    # --- Правая часть: кнопки действий ---
    _build_actions(row, col, tile)

    # --- Превью действия (если есть) ---
    if _preview_action != null:
        _build_preview(row, col, tile)
    else:
        # Превью нет (смена выделенного гекса, ESC и т.п.) — обязательно
        # очищаем контейнер, чтобы старое превью не оставалось в панели.
        for child in _preview_container.get_children():
            child.queue_free()
        for child in _preview_header_container.get_children():
            child.queue_free()
        # Сбрасываем снапшот: следующая открытая превью должна пересоздать
        # свой блок (даже если opens то же самое действие на том же гексе).
        _last_preview_snapshot = {}
    # Маршрут на карте приводим в соответствие с текущим превью: он появился,
    # сменился или исчез. Именно здесь, а не в _build_road_preview(), потому
    # что _build_preview выходит рано по снапшоту — превью того же действия на
    # том же гексе не перестраивается, и «призрачная» дорога застряла бы на
    # старом маршруте (например, после разведки пути к городку).
    _sync_road_preview_on_map()

func _clear_ui():
    _info_label.text = tr("Select a hex on the map (LMB) to see information and available actions.")
    for child in _products_container.get_children():
        child.queue_free()
    for child in _actions_container.get_children():
        child.queue_free()
    for child in _preview_container.get_children():
        child.queue_free()
    for child in _preview_header_container.get_children():
        child.queue_free()
    # Сброс снимка: если контейнер кнопок очищен, но снимок совпадает с
    # прежним гексом, следующий _build_actions() иначе решил бы, что пересоздавать
    # ничего не нужно (и кнопки бы не появились).
    _last_actions_snapshot = {}
    _last_preview_snapshot = {}
    # Прекращаем показ маршрута и призрака: выделение снято, значит и превью нет.
    _set_map_road_preview({})
    _set_map_route_display({})

# Строка «Маршрут до города» в левой колонке панели: сколько участков,
# средняя скорость и самое узкое место. Показывается только когда маршрут
# есть; на гексе без дороги строки нет — писать «маршрута нет» на каждом
# пустом гексе значило бы засорять панель.
#
# Средняя скорость отвечает на вопрос «насколько быстро в среднем едет груз»,
# минимальная — «где именно он вязнет». Обе нужны: улучшать надо узкое
# место, а не среднее по маршруту.
func _append_route_info(row: int, col: int) -> void:
    if main_map == null or not main_map.has_method("get_route_to_city"):
        return
    # Уровень дороги на самом гексе идёт ПЕРЕД строкой маршрута: маршрут
    # читается как «куда едет груз», и уровень гекса — его начало. На гексе без
    # дороги уровня нет, но маршрут тоже пустой, так что обе строки пусты.
    var road_line: String = map_tooltip.road_level_line(row, col)
    if not road_line.is_empty():
        var road_label := Label.new()
        road_label.text = tr(" Road: %s") % road_line
        road_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        road_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
        _products_container.add_child(road_label)
    var route: Dictionary = main_map.get_route_to_city(row, col)
    if not route.get("ok", false):
        return
    var route_label := Label.new()
    route_label.text = tr(" Route to the city: %d sections, average %.1f units/sec (bottleneck %d)") % [int(route.get("length", 0)), float(route.get("avg_speed", 0.0)), int(route.get("min_speed", 0))]
    route_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    route_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _products_container.add_child(route_label)

# --- Построение кнопок действий ---
func _build_actions(row: int, col: int, tile: Dictionary):
    # Если состояние действий для этого гекса не изменилось с прошлого раза —
    # не пересоздаём кнопки. Это сохраняет открытые ОС-тултипы (иначе каждый
    # игровой тик пересоздание кнопок сбрасывало бы наведённый тултип).
    # ВАЖНО: поэтому в тултипы НЕЛЬЗЯ включать значения, меняющиеся каждый тик
    # (текущая казна, текущий запас еды и т.п.): тогда тултипы отличаются на
    # каждом тике, сравнение _actions_equal() не совпадает, кнопки пересоздаются
    # и тултип сбрасывается. Динамические значения игрок смотрит в HUD.
    var actions := _collect_actions(row, col, tile)
    var prev = _last_actions_snapshot
    if prev.get("row", -1) == row and prev.get("col", -1) == col \
            and _actions_equal(prev.get("actions", []), actions):
        return

    _last_actions_snapshot = {"row": row, "col": col, "actions": actions}

    for child in _actions_container.get_children():
        child.queue_free()

    for action in actions:
        var btn = Button.new()
        btn.custom_minimum_size = Vector2(40, 40) # маленькая квадратная кнопка
        # Тултип сохраняется — это единственный способ узнать, что делает кнопка.
        btn.tooltip_text = action.get("tooltip", "")
        btn.disabled = not action.get("enabled", true)
        # Иконка действия; если её нет или файл не найден — знак вопроса.
        var tex = _load_action_icon(action.get("icon", ""))
        if tex != null:
            btn.icon = tex
            btn.expand_icon = true
            btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
        else:
            btn.text = "?"
            if not action.get("enabled", true):
                btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
                btn.add_theme_color_override("font_disabled_color", Color(0.5, 0.5, 0.5))
        var action_data = action
        btn.pressed.connect(func():
            _on_action_pressed(action_data)
        )
        _actions_container.add_child(btn)

# Загружает Texture2D для имени файла иконки действия через общий реестр
# иконок IconRegistry (тот же, что используют тултип и отрисовка карты).
# Возвращает null, если имя пустое или файл не найден (тогда кнопка покажет «?»).
func _load_action_icon(icon_name: String) -> Texture2D:
    if icon_name.is_empty():
        return null
    return IconRegistry.get_texture(icon_name)

# Сравнивает два списка действий (по значимым полям, чтобы у неработающего
# поля type/imp_id не пересоздавались кнопки вхолостую).
func _actions_equal(a: Array, b: Array) -> bool:
    if a.size() != b.size():
        return false
    for i in range(a.size()):
        var x: Dictionary = a[i]
        var y: Dictionary = b[i]
        for key in ["type", "label", "enabled", "tooltip", "imp_id", "action_id", "target_res_id", "icon", "tech_id"]:
            if x.get(key, null) != y.get(key, null):
                return false
    return true

# Собирает список действий для гекса. Каждый элемент:
#   { "type": String, "label": String, "enabled": bool, "tooltip": String,
#     "imp_id": String, "target_res_id": String, "action_id": String }
# type: "build_improvement" | "build_breeding" | "special" |
#       "pause_improvement" | "resume_improvement" | "cancel_build" |
#       "research_tech"
func _collect_actions(row: int, col: int, tile: Dictionary) -> Array:
    var actions := []
    var in_influence = tile.get("in_influence", false)

    # На гексе города строить улучшения нельзя — никаких действий.
    if row == main_map.city_row and col == main_map.city_col:
        return actions

    # На гексе городка (мелкое поселение) нельзя строить улучшения и делать
    # спецдействия — по дизайну это «чужое» место. Действия здесь два:
    # переход в интерфейс городка и дорога от города ДО него (цель дороги —
    # не сам гекс городка, а ближайшая дорога в его кольце влияния, см.
    # road_manager.plan_road_to). Оба появляются по одиночному клику на гекс
    # городка; переход в интерфейс доступен также по двойному клику
    # (InputHandler). Только для РАСКРЫТОГО гекса: неразведанный городок в
    # тумане войны показывается лишь полупрозрачной иконкой, и взаимодействовать
    # с ним нельзя — такой гекс обрабатывается как обычный гекс разведки (ниже).
    if tile.get("has_town", false) \
            and (in_influence or tile.get("is_explored", false)):
        var town_rec = null
        if main_map.town_manager != null:
            town_rec = main_map.town_manager.find_town_at(row, col)
        var town_name = ""
        if town_rec != null:
            town_name = str(town_rec.get("name", ""))
        # Открыть интерфейс можно ВСЕГДА, независимо от дороги: там видно, что
        # у городка есть на продажу и на покупку. Дорога гейтит только саму
        # торговлю, и её состояние показывается в тултипе.
        var trade_available := true
        if town_rec != null:
            trade_available = main_map.town_manager.is_trade_available(town_rec)
        var town_action_label = tr("Open town")
        var town_action_tooltip = tr("Open the town interface")
        if town_name != "":
            town_action_label = tr("Open %s") % town_name
            town_action_tooltip = tr("Open the town interface \"%s\"") % town_name
        if not trade_available:
            town_action_tooltip += tr(" (trade unavailable: no road to the town)")

        # Дорога до городка — то же спецдействие «Построить дорогу», что и на
        # обычном гексе, но с другим текстом: здесь дорога не доходит до гекса
        # городка, а соединяет город с дорогами кольца влияния.
        if not main_map.road_manager.is_town_linked_to_city(row, col):
            # Пока идёт поэтапный проект к этому городку, кнопку строительства
            # не показываем — вместо неё прерывание уже начатой стройки, его
            # добавит общий помощник ниже. Ищем по ЦЕЛИ (has_project_at), а не
            # по гексу: здесь интересует именно проект, целящийся в городок.
            if not (main_map.project_manager != null \
                    and main_map.project_manager.has_project_at(row, col)):
                var road_sa: Dictionary = GameData.special_actions.get(ROAD_ACTION_ID, {})
                if not road_sa.is_empty():
                    _append_special_action(actions, ROAD_ACTION_ID, road_sa,
                            tr("Build a road from the city to the town%s — unlocks trade")
                                    % ((" «%s»" % town_name) if town_name != "" else ""))

        # Прерывание нужно и на гексе самого городка, и в его кольце влияния:
        # дорога к городку заканчивается участком ВНУТРИ кольца, так что без
        # этого вызова кнопка исчезала бы на последнем шаге дороги. Дубликата
        # с блоком выше уже нет — тот только прячет кнопку строительства.
        _append_cancel_actions(actions, row, col)

        actions.append({
            "type": "open_town",
            "label": town_action_label,
            "enabled": true,
            "tooltip": town_action_tooltip,
            "icon": TownManager.TOWN_ICON_NAME
        })
        return actions

    # Гекс вне Кольца Влияния — действия через панель управления:
    #   неисследованная область (в т.ч. туман войны и территория городков) →
    #     «Отправить разведчиков»: до изучения Картографии — только в
    #     неисследованной части Региона (в тумане войны чанк не собирается,
    #     см. expansion_manager.get_chunk_hexes); после Картографии — везде,
    #     куда можно проскроллить. В обоих случаях чанк обязан примыкать к
    #     известной территории (Кольцо Влияния или разведанные гексы) —
    #     см. main_map.is_chunk_adjacent_to_known;
    #   исследованная → «Освоить область» (покупка чанка за монеты из казны + труд).
    #     Покупка возможна только внутри Региона (см. _collect_region_actions).
    if not in_influence:
        return _collect_region_actions(row, col)

    # Гекс внутри Кольца Влияния, но в кольце чужого городка — строить
    # нельзя. Парный check к build_manager.start_build: панель не должна
    # показывать заведомо невозможные экшены.
    #
    # ИСКЛЮЧЕНИЕ — прерывание проекта: дорога к городку заканчивается
    # участком именно в его кольце влияния, и если кольцо «немое», дорогу к
    # городку нельзя ни достроить, ни прервать.
    if tile.get("in_town_influence", false):
        _append_cancel_actions(actions, row, col)
        return actions

    # Декоративные улучшения городка полностью недоступны игроку:
    # нельзя запускать, сносить или заменять их через панель.
    if bool(tile.get("decorative", false)):
        return actions
    # --- Улучшение уже построено ---
    if tile.improvement != null:
        var imp_name = GameData.improvements.get(tile.improvement, {}).get("name", tile.improvement)
        # Инфраструктурные улучшения (no_worker, например пристань) работают
        # без рабочего — кнопки запуска/паузы для них не показываем вообще.
        if not GameData.is_no_worker_improvement(tile.improvement):
            var has_worker = worker_manager.has_worker(row, col)
            if has_worker:
                actions.append({
                    "type": "pause_improvement",
                    "label": tr("Pause operation (%s)") % imp_name,
                    "enabled": true,
                    "tooltip": tr("Remove the worker from the improvement"),
                    "icon": "building_pause.png"
                })
            else:
                actions.append({
                    "type": "resume_improvement",
                    "label": tr("Start operation (%s)") % imp_name,
                    "enabled": CityData.idle_population > 0,
                    "tooltip": tr("Assign a worker to the improvement") if CityData.idle_population > 0 else tr("No free workers"),
                    "icon": "building_resume.png"
                })

        # Спец-действия, применимые к гексу с улучшением (например, снос).
        _add_special_actions(actions, row, col, tile)

        # Улучшение дороги до этого гекса: доступно, когда дорога уже есть и
        # её есть куда улучшать. Кнопка появляется на ЛЮБОМ гексе с маршрутом
        # до города — не только на улучшениях: игрок может улучшить дорогу и
        # до пустого гекса, если решит, что там будет улучшение.
        _append_upgrade_road_action(actions, row, col)

        # Прерывание стройки и/или проекта. Именно здесь проверка проекта
        # ТЕРЯЛАСЬ раньше: ветка гекса с улучшением делала return, не доходя
        # до общего блока отмены. А дорогу к гексу с улучшением построить можно
        # (кнопка «Построить дорогу» доступна, если улучшение не no_road), то
        # есть можно было запустить проект и нельзя было его прервать.
        _append_cancel_actions(actions, row, col)
        return actions

    # --- Гекс без улучшения ---
    # 1. Природный ресурс с improved_by.
    var eff_res = MapHelpers.get_effective_resource(tile)
    if tile.resource != null:
        var raw = GameData.raw_resources.get(tile.resource, {})
        if "improved_by" in raw and raw.improved_by != null and raw.improved_by != "":
            var imp_id = raw.improved_by
            var imp_data = GameData.improvements.get(imp_id, {})
            var imp_name = imp_data.get("name", imp_id)
            var enabled = true
            var tooltip = tr("Build %s") % imp_name
            # Проверка: ресурс скрыт tech_reveal-гейтом. Действие НЕ показываем
            # вовсе (ни кнопки, ни тултипа): игрок не должен знать, где
            # находится скрытый ресурс, пока не откроет соответствующую технологию.
            if not MapHelpers.is_resource_revealed(tile):
                # Скрытый ресурс: никаких действий и подсказок на этом гексе.
                pass
            else:
                # Кнопки изучения и постройки улучшения, заблокированного
                # технологией, показываем только если до открывающей технологии
                # улучшения осталось не более TECH_HOPS_MAX «хопов».
                var imp_unlock_tech = CityData.get_improvement_unlock_tech(imp_id)
                var imp_tech_blocked = not CityData.is_improvement_unlocked(imp_id)
                if imp_tech_blocked and CityData.get_tech_hops(imp_unlock_tech) > CityData.TECH_HOPS_MAX:
                    pass
                else:
                    # Кнопка «Изучить ...» предлагает СЛЕДУЮЩИЙ не изученный шаг
                    # технологической цепочки, которая открывает УЛУЧШЕНИЕ, позволяющее
                    # эксплуатировать этот ресурс. Цепочка строится по технологии
                    # улучшения (imp_unlock_tech), а НЕ по технологии появления
                    # самого ресурса (tech_required): видимые ресурсы открыты на
                    # старте, но добывать их можно только соответствующим
                    # улучшением. Например, кварцевый песок добывается каменоломней
                    # (открывается «Каменной кладкой»), хотя сам ресурс становится
                    # возможным перерабатывать в стекло лишь после изучения «Стеклоделия».
                    var chain = CityData.get_tech_study_chain(imp_unlock_tech)
                    if not chain.is_empty():
                        actions.append(_make_research_action(chain[0]))
                    # Тултип кнопки ПОСТРОЙКИ всегда указывает на НЕПОСРЕДСТВЕННОЕ
                    # требование для этой постройки (а не на текущий шаг цепочки
                    # изучения). Постройка улучшения гейтится ТОЛЬКО технологией
                    # самого улучшения (imp_unlock_tech) и прочими условиями
                    # (пристань, лимит труда). Технология появления ресурса
                    # (raw.tech_required) на постройку не влияет: раз ресурс уже
                    # на гексе, его tech_required выполнен. Например, кварцевый
                    # песок добывается каменоломней (нужна «Каменная кладка»),
                    # а не «Стеклоделием», позволяющим получать стекло из песка.
                    if not CityData.is_improvement_unlocked(imp_id):
                        var tech_name = _get_tech_name(imp_unlock_tech)
                        enabled = false
                        tooltip = tr("%s — requires technology: %s") % [imp_name, tech_name]
                    # Схема harbor_access: улучшения с requires_harbor (рыбацкие лодки)
                    # строятся только на водоёме, где есть пристань. BFS по воде от
                    # этого гекса ищет сушу с water_body_harbor-улучшением.
                    elif bool(imp_data.get("requires_harbor", false)) \
                            and not MapHelpers.has_harbor_access(main_map.tile_data, row, col, main_map.map_rows, main_map.map_cols):
                        enabled = false
                        tooltip = tr("%s — requires a Dock on the shore of this water body") % imp_name
                    # Проверка: лимит строек.
                    elif build_manager.get_total_active_builds() >= CityData.total_population:
                        enabled = false
                        tooltip = tr("No work available: construction limit (number of citizens) reached")
                    actions.append({
                        "type": "build_improvement",
                        "label": tr("Build %s") % imp_name,
                        "enabled": enabled,
                        "tooltip": tooltip,
                        "imp_id": imp_id,
                        "target_res_id": tile.resource,
                        "icon": GameData.improvements.get(imp_id, {}).get("icon", "")
                    })

    # 2. Пустой гекс: разведение одомашненных животных/растений.
    if tile.resource == null:
        var breeding_ids: Array = CityData.domesticated_resources.duplicate()
        var suitable_breeding_improvements: Dictionary = {}
        for resource_id in breeding_ids:
            var improvement_id = MapHelpers.get_breeding_improvement(resource_id)
            if improvement_id == "" or not MapHelpers.can_breed_resource_on_tile(resource_id, tile):
                continue
            suitable_breeding_improvements[improvement_id] = true
        for improvement_id in suitable_breeding_improvements:
            var imp_name = GameData.improvements.get(improvement_id, {}).get("name", improvement_id)
            var improvement_unlocked = CityData.is_improvement_unlocked(improvement_id)
            var action_enabled = improvement_unlocked
            var action_tooltip = tr("Build %s for breeding") % imp_name
            if not improvement_unlocked:
                var unlock_tech = CityData.get_improvement_unlock_tech(improvement_id)
                action_tooltip = tr("%s — requires technology: %s") % [imp_name, _get_tech_name(unlock_tech)]
            elif build_manager.get_total_active_builds() >= CityData.total_population:
                action_enabled = false
                action_tooltip = tr("No work available: construction limit (number of citizens) reached")
            actions.append({
                "type": "build_breeding",
                "label": tr("Build %s") % imp_name,
                "enabled": action_enabled,
                "tooltip": action_tooltip,
                "imp_id": improvement_id,
                "icon": GameData.improvements.get(improvement_id, {}).get("icon", "")
            })

    # 3. Пристань (схема harbor_access): открывает водные ресурсы конкретного
    #    водоёма. Предлагается на пустом прибрежном гексе (суша с соседом lake/sea,
    #    не гора). После постройки рыба этого водоёма становится доступной для
    #    рыбацких лодок (см. has_harbor_access в map_helpers.gd).
    #    Не хватает технологии — кнопка построения неактивна, а рядом добавляется
    #    кнопка «Изучить …» (как у канала и лесной делянки).
    var harbor_potential_tile = tile.resource == null and tile.get("crop_bred", null) == null \
            and tile.terrain != "mountain" and not MapHelpers.is_water_terrain(tile.terrain) \
            and MapHelpers.is_coastal_hex(main_map.tile_data, row, col, main_map.map_rows, main_map.map_cols)
    if harbor_potential_tile:
        var harbor_name = GameData.improvements.get("harbor", {}).get("name", tr("Harbor"))
        var harbor_tech_unlocked = CityData.is_improvement_unlocked("harbor")
        var harbor_unlock_tech = CityData.get_improvement_unlock_tech("harbor")
        var harbor_tooltip = tr("Build %s — unlocks the water resources of this water body") % harbor_name
        # Кнопки изучения и постройки пристани (заблокированной технологией)
        # показываем только если до открывающей технологии осталось не более
        # TECH_HOPS_MAX «хопов» (по аналогии с каналом и лесной делянкой).
        var show_harbor := false
        if harbor_tech_unlocked:
            show_harbor = true
            if build_manager.get_total_active_builds() >= CityData.total_population:
                harbor_tooltip = tr("%s — no work available: construction limit (number of citizens) reached") % harbor_name
        else:
            var harbor_tech_name = _get_tech_name(harbor_unlock_tech)
            harbor_tooltip = tr("%s — requires technology: %s") % [harbor_name, harbor_tech_name]
            if CityData.get_tech_hops(harbor_unlock_tech) <= CityData.TECH_HOPS_MAX:
                show_harbor = true
                var harbor_chain = CityData.get_tech_study_chain(harbor_unlock_tech)
                if not harbor_chain.is_empty():
                    actions.append(_make_research_action(harbor_chain[0], harbor_name))
        if show_harbor:
            actions.append({
                "type": "build_improvement",
                "label": tr("Build %s") % harbor_name,
                "enabled": harbor_tech_unlocked,
                "tooltip": harbor_tooltip,
                "imp_id": "harbor",
                "icon": GameData.improvements.get("harbor", {}).get("icon", "")
            })

    # 4. Ирригационный канал (схема water_access, расширение «Каналы»):
    #    инфраструктурное улучшение-проводник, раздающее пресную воду соседям.
    #    Можно строить только на пустом ровном сухом участке (plain/hill/beach
    #    и любые проходимые не-водные террейны) непосредственно рядом с
    #    источником пресной воды: река по общему ребру, озеро, ферма/плантация/
    #    канал с прямым доступом к воде. Полная валидация — в MapHelpers.can_build_canal.
    #
    #    Кнопка показывается только там, где канал МОЖНО построить при условии
    #    изучения технологии: подходящая местность + рядом источник воды.
    #    В пустыне кнопка не появляется — игроку не показывается заведомо
    #    невозможное действие (по аналогии с каменоломней, которая видна
    #    только на гексе с её ресурсом). Если не хватает технологии —
    #    рядом добавляется кнопка «Изучить …».
    var canal_potential_tile = tile.resource == null and tile.get("crop_bred", null) == null \
            and tile.improvement == null and not tile.get("has_town", false) \
            and not tile.get("in_town_influence", false) \
            and tile.terrain != "mountain" \
            and not MapHelpers.is_water_terrain(tile.terrain) \
            and tile.terrain != "swamp" and tile.terrain != "marsh" \
            and MapHelpers.would_canal_have_water(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
    if canal_potential_tile:
        var canal_name = GameData.improvements.get("irrigation_canal", {}).get("name", tr("Irrigation Canal"))
        var canal_icon = GameData.improvements.get("irrigation_canal", {}).get("icon", "")
        var canal_tech_unlocked = CityData.is_improvement_unlocked("irrigation_canal")
        var canal_unlock_tech = CityData.get_improvement_unlock_tech("irrigation_canal")
        var canal_tooltip = tr("Build %s — extends fresh water further") % canal_name
        # Кнопки изучения и постройки канала (заблокированного технологией «Каналы»)
        # показываем только если до открывающей технологии улучшения осталось
        # не более TECH_HOPS_MAX «хопов».
        var show_canal := false
        if canal_tech_unlocked:
            show_canal = true
            if build_manager.get_total_active_builds() >= CityData.total_population:
                canal_tooltip = tr("%s — no work available: construction limit (number of citizens) reached") % canal_name
        else:
            var tech_name = _get_tech_name(canal_unlock_tech)
            canal_tooltip = tr("%s — requires technology: %s") % [canal_name, tech_name]
            if CityData.get_tech_hops(canal_unlock_tech) <= CityData.TECH_HOPS_MAX:
                show_canal = true
                var chain = CityData.get_tech_study_chain(canal_unlock_tech)
                if not chain.is_empty():
                    actions.append(_make_research_action(chain[0], canal_name))
        if show_canal:
            actions.append({
                "type": "build_improvement",
                "label": tr("Build %s") % canal_name,
                "enabled": canal_tech_unlocked,
                "tooltip": canal_tooltip,
                "imp_id": "irrigation_canal",
                "icon": canal_icon
            })
            
    # 4b. Лесная делянка (lumberjack_hut). Строится на пустом СУХОМ гексе
    #     с лесным покровом (wood_yield > 0 в covers.json), аналогично каналу:
    #     кнопка видна только там, где делянку МОЖНО построить. Если не хватает
    #     технологии — рядом добавляется кнопка «Изучить …».
    if MapHelpers.can_build_lumberjack_hut(tile):
        var lj_name = GameData.improvements.get("lumberjack_hut", {}).get("name", tr("Woodcutter's Camp"))
        var lj_icon = GameData.improvements.get("lumberjack_hut", {}).get("icon", "")
        var lj_tech_unlocked = CityData.is_improvement_unlocked("lumberjack_hut")
        var lj_unlock_tech = CityData.get_improvement_unlock_tech("lumberjack_hut")
        var lj_tooltip = tr("Build %s — harvests timber from the forest cover") % lj_name
        var show_lj := false
        if lj_tech_unlocked:
            show_lj = true
            if build_manager.get_total_active_builds() >= CityData.total_population:
                lj_tooltip = tr("%s — no work available: construction limit (number of citizens) reached") % lj_name
        else:
            var lj_tech_name = _get_tech_name(lj_unlock_tech)
            lj_tooltip = tr("%s — requires technology: %s") % [lj_name, lj_tech_name]
            if CityData.get_tech_hops(lj_unlock_tech) <= CityData.TECH_HOPS_MAX:
                show_lj = true
                var lj_chain = CityData.get_tech_study_chain(lj_unlock_tech)
                if not lj_chain.is_empty():
                    actions.append(_make_research_action(lj_chain[0], lj_name))
        if show_lj:
            actions.append({
                "type": "build_improvement",
                "label": tr("Build %s") % lj_name,
                "enabled": lj_tech_unlocked,
                "tooltip": lj_tooltip,
                "imp_id": "lumberjack_hut",
                "icon": lj_icon
            })

    # 5. Спец-действия (вырубка леса, сбор дикоросов и т.п.).
    _add_special_actions(actions, row, col, tile)

    # 6. Прерывание того, что идёт на этом гексе: обычной стройки и/или
    # поэтапного проекта. Это ДВЕ независимые вещи (например, к гексу с
    # фермой идёт дорога, и на нём же можно строить что-то ещё), поэтому при
    # обоих показываются обе кнопки, а не одна.
    _append_cancel_actions(actions, row, col)

    return actions

# Добавляет кнопки прерывания для всего, что идёт на гексе (row, col).
#
# Единая точка для всех веток _collect_actions. Раньше проверка проекта жила
# только в двух местах — на пустом гексе и на гексе городка, — и терялась на
# ранних return: гекс с улучшением и гекс в кольце влияния городка. Дорогу к
# гексу с улучшением построить можно, но отменить её было нельзя; дорога к
# городку заканчивается в его кольце влияния, где кнопки тоже не было.
func _append_cancel_actions(actions: Array, row: int, col: int) -> void:
    # Обычная стройка: улучшения, спецдействия (осушение, вырубка, сбор,
    # снос). Имя действия берём из данных стройки, чтобы кнопка называла, что
    # именно прерывается: «Прервать: Осушение болот», а не «Отменить стройку» —
    # по кнопке игрок должен понимать, куда он нажал.
    if build_manager != null and build_manager.is_building(row, col):
        var prog: Dictionary = build_manager.get_progress(row, col)
        var action_name := str(prog.get("imp_name", tr("the construction")))
        actions.append({
            "type": "cancel_build",
            "label": tr("Stop: %s") % action_name,
            "enabled": true,
            "tooltip": tr("Stop \"%s\". Spent work will be lost") % action_name,
            "icon": "cross.svg"
        })

    # Поэтапный проект (дорога). Кнопка появляется на ЛЮБОМ его гексе, а не
    # только на цели: игрок жмёт туда, где видит стройку, — на прогресс-бар
    # текущего участка или на участок призрака.
    if main_map.project_manager == null:
        return
    var project: Dictionary = main_map.project_manager.get_project_at_hex(row, col)
    if project.is_empty():
        return
    actions.append(_make_project_cancel_action(project))

# Кнопка отмены идущего поэтапного проекта.
#
# Название берём у проекта («Дорога», «Дорога до городка «X»»), а не пишем
# родовым «Отменить стройку»: по кнопке должно быть видно, ЧТО прерывается.
# Число остатка — в кнопке, а не только в диалоге: игрок жмёт с гекса в
# середине трассы и должен ДО нажатия понимать, что отменяет всю дорогу целиком,
# а не один участок. Иначе нажатие на середине маршрута выглядит как отмена
# «вот этого кусочка», а отменяется всё.
func _make_project_cancel_action(project: Dictionary) -> Dictionary:
    var steps: Array = project.get("steps", [])
    var done := int(project.get("step_index", 0))
    var left := maxi(0, steps.size() - done)
    var title := str(project.get("title", tr("Construction")))
    var tooltip := tr("Stop \"%s\"") % title
    if left > 0:
        tooltip += tr(" — unfinished sections: %d") % left
    if done > 0:
        tooltip += tr(". Already built sections (%d) will remain") % done
    return {
        "type": "cancel_project",
        "label": tr("Stop: %s") % title,
        "enabled": true,
        "tooltip": tooltip,
        "project_id": str(project.get("id", "")),
        "icon": "cross.svg"
    }

# Кнопки прерывания для действий ВНЕ Кольца Влияния: разведки и освоения
# территории. Отдельная от _append_cancel_actions по причине: у них нет
# улучшения на гексе, и они не идут через build_manager.active_builds, а у
# разведки к тому же экспедиция одна на всё время (main_map.is_scouting).
func _append_long_action_cancel(actions: Array, row: int, col: int) -> void:
    if build_manager != null and build_manager.has_method("get_expansion_progress_for_hex"):
        var exp: Dictionary = build_manager.get_expansion_progress_for_hex(row, col)
        if not exp.is_empty():
            var chunk: Array = exp.get("chunk", [])
            actions.append({
                "type": "cancel_expansion",
                "label": tr("Stop: Claiming land"),
                "enabled": true,
                "tooltip": tr("Stop claiming land (%d tiles). Spent work will be lost, paid coins will be refunded") % chunk.size(),
                "icon": "cross.svg"
            })
    if main_map.is_scouting and not main_map.scouting_chunk.is_empty():
        var first = main_map.scouting_chunk[0]
        if first != null and int(first.row) == row and int(first.col) == col:
            actions.append({
                "type": "cancel_scouting",
                "label": tr("Stop: Scouting"),
                "enabled": true,
                "tooltip": tr("Recall the scouts. No hex will be surveyed, paid coins will be refunded"),
                "icon": "cross.svg"
            })

# Добавляет спец-действия (special_actions.json), применимые к гексу.
# Собирает действия для гекса вне Кольца Влияния:
#   неисследованная область — разведка чанка: до изучения Картографии
#     только в неисследованной части Региона, после — на всём, что
#     достижимо скроллом карты (включая туман войны и территорию городков);
#     и в том, и в другом случае чанк обязан примыкать к известной
#     территории (Кольцо Влияния или разведанные гексы) — иначе кнопка
#     разведки показывается неактивной с причиной
#     (см. main_map.is_chunk_adjacent_to_known);
#   исследованная область — покупка (освоение), но ТОЛЬКО в пределах Региона.
func _collect_region_actions(row: int, col: int) -> Array:
    var actions := []
    # Прерывание идёт ПЕРЕД всеми ранними return: разведка и освоение —
    # длительные действия, и кнопка отмены должна появляться на гексе чанка
    # независимо от того, разведан он уже или нет. Раньше здесь отмены не
    # было вовсе — экспедицию и освоение можно было только ждать.
    _append_long_action_cancel(actions, row, col)
    var tile = main_map.get_tile_data(row, col)
    if tile == null:
        return actions
    var chunk = main_map.expansion_manager.get_chunk_hexes(row, col)
    if chunk.is_empty():
        # Пустой чанк — действий нет, но игрок должен понимать ПОЧЕМУ.
        # Для исследованного гекса показываем неактивную кнопку освоения
        # с причиной; для неисследованного пустой чанк не встречается.
        if not bool(tile.get("is_explored", false)):
            return actions
        var reason := ""
        if bool(tile.get("in_town_influence", false)):
            reason = tr("Cannot claim: another town's territory")
        elif not main_map.is_valid_hex(row, col):
            reason = tr("Only areas within the Region can be claimed")
        if reason == "":
            return actions
        actions.append({
            "type": "buy_chunk",
            "label": tr("Claim the area"),
            "enabled": false,
            "tooltip": reason,
            "chunk": [],
            "money_cost": 0,
            "work_cost": 0,
            "icon": "check.svg"
        })
        return actions

    var unexplored_count := 0
    for hex in chunk:
        if not main_map.tile_data[hex.row][hex.col].get("is_explored", false):
            unexplored_count += 1

    if unexplored_count > 0:
        # Неисследованный чанк: отправить разведчиков. Экспедиция оплачивается
        # МОНЕТАМИ из казны: цена — сумма по гексам чанка (база
        # scouting_cost_per_hex и универсальный модификатор дальности
        # distance_cost_modifier_per_hex из data/game_balance.json, см.
        # expansion_manager.get_chunk_scout_cost).
        var cost = main_map.expansion_manager.get_chunk_scout_cost(chunk)
        var scout_time = main_map._get_scouting_time(unexplored_count)
        # Разведку можно отправить только в чанк, примыкающий к известной
        # территории (Кольцо Влияния или разведанные гексы) — см.
        # main_map.is_chunk_adjacent_to_known. Чанк при этом остаётся собранным:
        # подсветка и неактивная кнопка с причиной объясняют игроку
        # правило (тот же UX, что у освоения: Область не граничит с вашими
        # владениями» ниже).
        var known_neighbor: bool = main_map.is_chunk_adjacent_to_known(chunk)
        var tooltip: String
        if main_map.is_scouting:
            tooltip = tr("Scouting already in progress")
        elif not known_neighbor:
            tooltip = tr("The area does not border explored territory")
        elif CityData.ignore_build_requirements:
            # Дебаг: разведка бесплатна и мгновенна. Текст статичный (без
            # казны и времени), поэтому конвенция _build_actions не нарушается.
            tooltip = tr("Send scouts: instantly and free (debug)")
        else:
            # ВАЖНО: не включать в тултип значения, меняющиеся КАЖДЫЙ ТИК
            # (текущую казну, текущий запас еды). _build_actions() сравнивает
            # тултипы между тиками и пересоздаёт кнопки при любом отличии —
            # это сбрасывает наведённый тултип. Казну игрок всегда видит в HUD.
            tooltip = tr("Send scouts: %d coins from the treasury, time [%.0f sec.]") % [cost, scout_time]
        actions.append({
            "type": "scout_chunk",
            "label": tr("Send scouts"),
            "enabled": not main_map.is_scouting and known_neighbor,
            "tooltip": tooltip,
            "chunk": chunk,
            "cost": cost,
            "icon": "additional_info.png"
        })
        return actions

    # Исследованный чанк: покупка (освоение) за монеты из казны + труд.
    var has_neighbor = false
    for hex in chunk:
        for n in HexUtils.get_neighbors_odd_r(hex.row, hex.col, main_map.map_rows, main_map.map_cols):
            if main_map.tile_data[n.row][n.col].get("in_influence", false):
                has_neighbor = true
                break
        if has_neighbor:
            break
    var money_cost = main_map.expansion_manager.get_chunk_money_cost(chunk)
    var work_cost = main_map.expansion_manager.get_chunk_cost(chunk)
    var labor = CityData.get_total_labor()
    var buy_tooltip: String
    if not has_neighbor:
        buy_tooltip = tr("The area does not border your territory")
    elif CityData.ignore_build_requirements:
        # Дебаг: освоение бесплатно и мгновенно (см. start_scouting — тот же
        # принцип в разведке). Текст статичный, как и требует _build_actions.
        buy_tooltip = tr("Claim the area (%d tiles): instantly and free (debug)") % chunk.size()
    else:
        buy_tooltip = tr("Claim the area (%d tiles): %d coins from the treasury and %d work (%.0f sec.)") % [chunk.size(), money_cost, work_cost, work_cost / max(1.0, labor)]
    actions.append({
        "type": "buy_chunk",
        "label": tr("Claim the area"),
        "enabled": has_neighbor,
        "tooltip": buy_tooltip,
        "chunk": chunk,
        "money_cost": money_cost,
        "work_cost": work_cost,
        "icon": "check.svg"
    })
    return actions

func _add_special_actions(actions: Array, row: int, col: int, tile: Dictionary):
    for sa_id in GameData.special_actions:
        var sa = GameData.special_actions[sa_id]
        var action_type = sa.get("action_type", "terrain")
        var applicable = false
        if action_type == "terrain":
            # Террейн-действие. source_terrains — список типов местности 
            # (напр. осушение болота), либо один source_terrain (обратная 
            # совместимость).
            var terrain_list: Array = sa.get("source_terrains", [])
            if terrain_list.is_empty():
                terrain_list = [sa.get("source_terrain", "")]
            applicable = tile.terrain in terrain_list and tile.improvement == null
        elif action_type == "cover":
            var cover_id = tile.get("cover", "none")
            applicable = cover_id in sa.get("source_cover", []) and tile.improvement == null and tile.resource == null
        elif action_type == "forage":
            # Универсальное действие «Собрать ресурс» для одноразовых ресурсов
            # (дикоросы, самородки металлов и т.п.). Одноразовость определяется
            # флагом самого ресурса: improved_by == null (не разрабатывается
            # улучшением) и непустой produces (есть что собрать).
            var harvest_res_id: String = str(tile.get("resource", ""))
            if harvest_res_id != "" and MapHelpers.is_resource_revealed(tile):
                var harvest_data: Dictionary = GameData.raw_resources.get(harvest_res_id, {})
                var is_one_time: bool = harvest_data.get("improved_by", null) == null
                if is_one_time:
                    var harvest_produces: Dictionary = harvest_data.get("produces", {})
                    if not harvest_produces.is_empty():
                        applicable = true
        elif action_type == "demolish":
            applicable = tile.improvement != null
        elif action_type == "road":
            # Дорога, которую строит игрок. Кнопка показывается на гексе, к
            # которому дороги ещё нет. Проверки здесь только дешёвые (панель
            # пересобирает действия каждый тик): гекс сухой, улучшения с
            # флагом no_road нет (к ирригационному каналу дорога по дизайну
            # не строится — см. road_manager._find_connect_path), и гекс ещё
            # не подключён к сети дорог города.
            # Длину трассы и цену считает превью — main_map.get_road_plan.
            applicable = not MapHelpers.is_water_terrain(tile.get("terrain", "plain")) \
                    and not main_map.road_manager.is_hex_connected(row, col)
            if applicable and tile.get("improvement", null) != null:
                var tile_imp: Dictionary = GameData.improvements.get(tile.improvement, {})
                applicable = not bool(tile_imp.get("no_road", false))
            # Дорога к гексу уже строится (поэтапный проект): вторую очередь
            # на тот же маршрут не создаём, вместо кнопки — отмена проекта.
            if applicable and main_map.project_manager != null \
                    and main_map.project_manager.has_project_at(row, col):
                applicable = false
        if not applicable:
            continue

        if action_type == "road":
            # У города: цель — сам гекс. У городка цель другая (кольцо
            # влияния), там кнопку собирает ветка городка в _collect_actions.
            _append_special_action(actions, sa_id, sa,
                    tr("Build a road from the city to this hex"))
        else:
            _append_special_action(actions, sa_id, sa)

# Кнопка «Улучшить дорогу» для гекса (row, col).
#
# Показывается, только когда улучшать ЕСТЬ ЧТО: до гекса уже есть маршрут до
# города, и хотя бы один его участок ниже лучшего доступного уровня. Иначе
# кнопка с недостижимой целью — шум в колонке действий.
#
# Улучшается ВЕСЬ маршрут от города до гекса, а не только последний участок:
# скорость маршрута определяется самым узким участком (см.
# road_manager.find_route_to_city), поэтому улучшение одного конца ничего не
# даёт — игрок должен видеть это в тултипе.
func _append_upgrade_road_action(actions: Array, row: int, col: int) -> void:
    if main_map == null or not main_map.has_method("get_route_to_city"):
        return
    var route: Dictionary = main_map.get_route_to_city(row, col)
    if not route.get("ok", false):
        return
    var levels: Array = route.get("levels", [])
    if levels.is_empty():
        return
    var best_level := GameData.get_max_unlocked_road_level()
    # Улучшать имеет смысл, пока на маршруте есть хоть ОДИН участок ниже
    # лучшего уровня — то есть проверяется МИНИМУМ, а не максимум.
    # С максимумом кнопка пряталась на частично улучшенном маршруте: стоит
    # улучшить один участок из четырёх, максимум становится равен лучшему
    # уровню, и кнопка исчезает — хотя три тропки остаются и улучшать есть
    # что. Раньше это выглядело как «маршрут уже улучшен».
    var worst_level := 999
    for level in levels:
        worst_level = mini(worst_level, int(level))
    if worst_level >= best_level:
        return
    var min_speed := int(route.get("min_speed", 0))
    actions.append({
        "type": UPGRADE_ROAD_TYPE,
        "label": tr("Upgrade road"),
        "enabled": true,
        "tooltip": tr("Upgrade the road from this hex to the city to %s (%d units/sec per section, now the bottleneck is %d units/sec)")
                % [GameData.get_road_name(best_level),
                        GameData.get_road_max_speed(best_level), min_speed],
        "icon": "road.svg"
    })

# Собирает кнопку спецдействия в колонке действий: учитывает требование
# технологии и общий лимит строек. tooltip_override (если задан) заменяет
# название в тултипе — им пользуется дорога, у которой текст зависит от
# цели (обычный гекс или городок).
func _append_special_action(actions: Array, sa_id: String, sa: Dictionary, tooltip_override: String = "") -> void:
    var sa_name = sa.get("name", sa_id)
    var enabled = true
    var tooltip = tooltip_override if not tooltip_override.is_empty() else sa_name
    var unlock_tech = sa.get("unlock_tech", "")
    if unlock_tech != "" and not CityData.is_tech_unlocked(unlock_tech):
        enabled = false
        tooltip = tr("%s — requires technology: %s") % [sa_name, _get_tech_name(unlock_tech)]
        # Кнопка изучения СЛЕДУЮЩЕГО не изученного шага технологической
        # цепочки, необходимой для разблокировки спецдействия (аналог
        # механики для ресурсов/улучшений, см. _collect_actions).
        var chain = CityData.get_tech_study_chain(unlock_tech)
        if not chain.is_empty():
            actions.append(_make_research_action(chain[0], sa_name))
    elif not CityData.ignore_build_requirements \
            and build_manager.get_total_active_builds() >= CityData.total_population:
        enabled = false
        tooltip = tr("No work available: construction limit (number of citizens) reached")
    actions.append({
        "type": "special",
        "label": sa_name,
        "enabled": enabled,
        "tooltip": tooltip,
        "action_id": sa_id,
        # Иконка берётся из special_actions.json (имя файла в icons/).
        "icon": sa.get("icon", "")
    })

# Формирует действие «Изучить технологию» для колонки действий панели.
# for_what — причина изучения, подставляется в тултип (название ресурса/
# улучшения для ресурсов или название спецдействия для действий).
func _make_research_action(tech_id: String, for_what: String = "ресурса") -> Dictionary:
    var tech_name = _get_tech_name(tech_id)
    var tech_cost = 3
    for t in GameData.technologies:
        if t["id"] == tech_id:
            tech_cost = int(t.get("science_cost", 3))
            break
    return {
        "type": "research_tech",
        "label": tr("Research %s") % tech_name,
        "enabled": true,
        "tooltip": tr("Research %s (science: %d) to unlock %s") % [tech_name, tech_cost, for_what],
        "tech_id": tech_id,
        "icon": "lock.png"
    }

# --- Обработка нажатия на кнопку действия ---
func _on_action_pressed(action: Dictionary):
    var type = action.get("type", "")
    if type == "info":
        return
    if type == "open_town":
        # Переход в интерфейс городка (торговля). Сам переход выполняет
        # main_map.open_town_ui (спрячет HUD и панель управления).
        if _selected_hex != null:
            main_map.open_town_ui(_selected_hex.row, _selected_hex.col)
        return
    if type == "scout_chunk":
        # Разведка чанка: списываем монеты из казны и отправляем разведчиков
        # (время). Цена считается внутри start_scouting — единый источник истины.
        main_map.start_scouting(action.get("chunk", []))
        main_map.redraw_progress_layer()
        _refresh()
        return
    if type == "buy_chunk":
        # Покупка (освоение) чанка: монеты из казны сразу, труд накапливается
        # через стройку.
        var ok = main_map.expansion_manager.handle_action(
            action.get("chunk", []), action.get("money_cost", 0), action.get("work_cost", 0))
        if ok:
            main_map.map_renderer.queue_redraw()
            if main_map.city_ui.visible:
                main_map.city_ui.refresh()
        _refresh()
        return
    # Действия, которые выполняются сразу (без превью).
    if type == "pause_improvement":
        worker_manager.remove_worker(_selected_hex.row, _selected_hex.col)
        main_map.map_renderer.queue_redraw()
        _refresh()
        return
    if type == "resume_improvement":
        if not worker_manager.assign_worker(_selected_hex.row, _selected_hex.col):
            main_map.hud.show_message(tr("No free workers!"))
        main_map.map_renderer.queue_redraw()
        _refresh()
        return
    if type == "cancel_build":
        main_map.confirm_cancel_build(_selected_hex.row, _selected_hex.col)
        return
    if type == "cancel_project":
        # Проект передаётся по id, а не ищется по нажатому гексу: кнопка
        # появляется на ЛЮБОМ гексе трассы, а не только на цели.
        if main_map.project_manager != null:
            main_map.confirm_cancel_project(str(action.get("project_id", "")))
        return
    if type == "cancel_expansion":
        if _selected_hex != null:
            main_map.confirm_cancel_expansion(_selected_hex.row, _selected_hex.col)
        return
    if type == "cancel_scouting":
        if _selected_hex != null:
            main_map.confirm_cancel_scouting(_selected_hex.row, _selected_hex.col)
        return
    if type == "research_tech":
        # Аналог пункта «Изучить X» в контекстном меню (ПКМ): мгновенный старт
        # исследования. Ошибки (уже идёт исследование и т.п.) start_research
        # сообщает сама через сигнал research_error → hud.show_message.
        CityData.start_research(action.get("tech_id", ""))
        main_map.map_renderer.queue_redraw()
        _refresh()
        return

    # Повторное нажатие на кнопку действия, чьё превью уже открыто,
    # работает как «отмена» (закрывает превью).
    if _preview_action != null \
            and _preview_action.get("type", "") == type \
            and _preview_action.get("imp_id", "") == action.get("imp_id", "") \
            and _preview_action.get("action_id", "") == action.get("action_id", "") \
            and _preview_action.get("target_res_id", null) == action.get("target_res_id", null):
        clear_preview()
        return

    # Действия с превью (постройка улучшения, разведение, спец-действие,
    # улучшение дороги).
    var eff_res_for_preview = action.get("target_res_id", null)
    if eff_res_for_preview == null or eff_res_for_preview == "":
        eff_res_for_preview = MapHelpers.get_effective_resource(main_map.get_tile_data(_selected_hex.row, _selected_hex.col))
    _preview_action = {
        "type": type,
        "imp_id": action.get("imp_id", ""),
        "target_res_id": action.get("target_res_id", null),
        "action_id": action.get("action_id", ""),
        "label": action.get("label", ""),
        "eff_res": eff_res_for_preview,
        "selected_culture_id": null,
        # Уровень дороги по умолчанию — лучший доступный. Именно его
        # предлагает правило «по умолчанию предлагаются самые продвинутые
        # версии»; любой другой игрок выбирает кнопкой в превью.
        "road_level": GameData.get_max_unlocked_road_level(),
    }
    _refresh()

# --- Построение предпросмотра действия ---
func _build_preview(row: int, col: int, tile: Dictionary):
    var preview = _preview_action

    # Если предпросмор для этого гекса и этого действия уже построен — не
    # пересоздаём элементы (в т.ч. кнопки «Начать»/«Отменить» с их
    # ОС-тултипами). Иначе они сбрасывались бы каждый игровой тик.
    var snapshot = {
        "row": row,
        "col": col,
        "type": preview.get("type", ""),
        "label": preview.get("label", ""),
        "imp_id": preview.get("imp_id", ""),
        "action_id": preview.get("action_id", ""),
        "target_res_id": preview.get("target_res_id", null),
        "eff_res": preview.get("eff_res", ""),
        "selected_culture_id": preview.get("selected_culture_id", null),
        # Состояние дебаг-флага входит в снапшот: переключение «Игнорировать
        # требования строительства» меняет блок превью, и без этого поля он
        # остался бы старым до перевыбора гекса.
        "ignore_build": CityData.ignore_build_requirements,
        # Уровень дороги — ТОЖЕ входит в снапшот: смена уровня перестраивает
        # весь блок превью (цену, число участков, подпись), и без этого поля
        # превью осталось бы от предыдущего уровня — игрок бы увидел цену
        # тропки, а построил бы тележную дорогу.
        "road_level": int(preview.get("road_level", GameData.get_max_unlocked_road_level())),
    }
    if _preview_equal(_last_preview_snapshot, snapshot):
        return
    _last_preview_snapshot = snapshot

    for child in _preview_container.get_children():
        child.queue_free()
    for child in _preview_header_container.get_children():
        child.queue_free()

    var type = preview.get("type", "")
    var imp_id = preview.get("imp_id", "")
    var action_id = preview.get("action_id", "")
    var eff_res = preview.get("eff_res", "")

    # Для ферм/пастбищ эффективный ресурс — выбранная культура (растение/животное),
    # а не то, что лежит на гексе сейчас: на пустом гексе природного ресурса нет,
    # и без этого «Будет производить» в превью не показывалось.
    if type == "build_breeding":
        var imp_kind_cult = preview.get("imp_id", "")
        var cult_id = preview.get("selected_culture_id", null)
        if not _is_suitable_culture(row, col, cult_id, imp_kind_cult):
            cult_id = _first_suitable_culture(row, col, imp_kind_cult)
            preview["selected_culture_id"] = cult_id
        if cult_id != null:
            eff_res = cult_id

    # Строка заголовка превью: подпись + кнопки «Начать» и «Отменить» (40×40,
    # с иконками зелёной галочки / красного косого креста). Строится в
    # ОТДЕЛЬНОМ контейнере над PreviewScroll — вне прокручиваемой области,
    # поэтому видна всегда при любом положении скролла.
    var header = HBoxContainer.new()
    header.add_theme_constant_override("separation", 4)
    var header_label = Label.new()
    header_label.text = "%s" % preview.get("label", "")
    header_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    header_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5))
    header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    header.add_child(header_label)
    var build_btn = Button.new()
    build_btn.custom_minimum_size = Vector2(40, 40) # маленькая квадратная кнопка
    build_btn.tooltip_text = tr("Start")
    build_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    var check_tex = _load_action_icon("check.svg")
    if check_tex != null:
        build_btn.icon = check_tex
        build_btn.expand_icon = true
        build_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
    else:
        build_btn.text = "✓"
    build_btn.pressed.connect(func():
        _confirm_build()
    )
    header.add_child(build_btn)
    var cancel_btn = Button.new()
    cancel_btn.custom_minimum_size = Vector2(40, 40)
    cancel_btn.tooltip_text = tr("Cancel")
    cancel_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    var cross_tex = _load_action_icon("cross.svg")
    if cross_tex != null:
        cancel_btn.icon = cross_tex
        cancel_btn.expand_icon = true
        cancel_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
    else:
        cancel_btn.text = "✕"
    cancel_btn.pressed.connect(func():
        clear_preview()
    )
    header.add_child(cancel_btn)
    _preview_header_container.add_child(header)

    # --- Для разведения: выбор конкретной культуры ---
    # Блок размещён сразу под заголовком, до расчётов производства и стоимости:
    # выбранный вид виден первым и не теряется в конце длинного списка.
    # Если на гексе можно выращивать/разводить несколько одомашненных видов,
    # даём выбрать, под какую именно культуру строить. Иначе строится
    # единственная подходящая культура (текущее поведение).
    if type == "build_breeding":
        var imp_kind = preview.get("imp_id", "")
        var crops := _get_suitable_crops(row, col, imp_kind)
        if crops.size() > 1:
            # По умолчанию предвыбираем первую культуру из списка.
            var selected = preview.get("selected_culture_id", null)
            if selected == null:
                selected = crops[0].id
                preview["selected_culture_id"] = selected

            var cult_label = Label.new()
            cult_label.text = tr("Culture:")
            cult_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
            cult_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
            _preview_container.add_child(cult_label)

            # Кнопки культур идут горизонтальным рядом с переносом строк.
            var cult_flow = FlowContainer.new()
            cult_flow.add_theme_constant_override("h_separation", 4)
            cult_flow.add_theme_constant_override("v_separation", 4)
            _preview_container.add_child(cult_flow)

            for cult in crops:
                var cult_btn = Button.new()
                cult_btn.custom_minimum_size = Vector2(40, 40) # квадратная кнопка с иконкой
                # Тултип — название ресурса (иконка без подписи).
                cult_btn.tooltip_text = cult.get("name", cult.id)
                # Иконка одомашненного вида; если её нет — знак вопроса.
                var cult_icon = GameData.raw_resources.get(cult.id, {}).get("icon", "")
                var cult_tex = _load_action_icon(cult_icon)
                if cult_tex != null:
                    cult_btn.icon = cult_tex
                    cult_btn.expand_icon = true
                    cult_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
                else:
                    cult_btn.text = "?"
                cult_btn.toggle_mode = true
                cult_btn.set_pressed_no_signal(cult.id == selected)
                # Явная рамка у выбранной культуры.
                var pressed_style = StyleBoxFlat.new()
                pressed_style.set_border_width_all(2)
                pressed_style.border_color = Color(1.0, 0.85, 0.2) # жёлтая рамка
                cult_btn.add_theme_stylebox_override("pressed", pressed_style)
                cult_btn.add_theme_stylebox_override("hover_pressed", pressed_style)
                cult_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
                var cid = cult.id
                cult_btn.pressed.connect(func():
                    _select_preview_culture(cid)
                )
                cult_flow.add_child(cult_btn)

    # Для спец-действий стоимость считается по action_id, а не по imp_id.
    var cost_imp_id = imp_id
    if type == "special":
        cost_imp_id = action_id

    # Лесная делянка на пустом лесном гексе (eff_res == ""): показываем
    # выход древесины из покрова (wood_yield в covers.json). Будущие покровы
    # с wood_yield > 0 подхватятся автоматически.
    if type == "build_improvement" and imp_id == "lumberjack_hut" and eff_res == "":
        var lj_yield: float = MapHelpers.get_cover_wood_yield(tile)
        if lj_yield > 0.0:
            var lj_has_water = MapHelpers.is_hex_irrigated(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
            var lj_mult = CityData.get_improvement_production_multiplier(
                "lumberjack_hut", lj_has_water, tile.get("terrain", ""), "lumberjack_hut")
            var lj_amount = ceili(lj_yield * lj_mult)
            # Показ — посекундный: выпуск цикла, делённый на production_interval.
            var lj_interval := CityData.get_improvement_production_interval("lumberjack_hut")
            var lj_per_sec: float = float(lj_amount) / lj_interval
            var wood_data = GameData.products.get("wood", {})
            var wood_icon_path = ""
            if wood_data.has("icon"):
                wood_icon_path = IconRegistry.icon_path(wood_data["icon"])
            var lj_products := []
            lj_products.append({"type": "header", "text": tr("Will produce:")})
            var lj_base_str = str(int(lj_yield)) if lj_yield == floor(lj_yield) else "%.1f" % lj_yield
            var wood_label = wood_data.get("name", tr("Wood"))
            if lj_mult != 1.0:
                wood_label = tr("%s (base %s)") % [wood_label, lj_base_str]
            lj_products.append({"type": "product", "name": wood_label, "amount": lj_per_sec, "icon_path": wood_icon_path, "suffix": tr(" units/sec")})
            var lj_box = VBoxContainer.new()
            map_tooltip.render_products(lj_products, lj_box, true)
            _preview_container.add_child(lj_box)

    # Расчёт производства (для улучшений и разведения, кроме спец-действий).
    if type != "special" and eff_res != "":
        var res_data = GameData.raw_resources.get(eff_res, {})
        if res_data.has("produces"):
            # Множитель производства с учётом модификаторов (вода, местность, технологии).
            var has_water = MapHelpers.is_hex_irrigated(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
            var terrain_id = tile.get("terrain", "")
            var bonus_multiplier = CityData.get_improvement_production_multiplier(imp_id, has_water, terrain_id, eff_res)
            var modifiers = CityData.get_improvement_production_modifiers(imp_id, has_water, terrain_id, eff_res)
            # Показ — посекундный: выпуск цикла, делённый на production_interval
            # улучшения (поле в data/improvements.json).
            var prod_interval := CityData.get_improvement_production_interval(imp_id)

            var products := []
            products.append({"type": "header", "text": tr("Will produce:")})
            for prod_id in res_data["produces"]:
                # produces может быть числом или диапазоном [min, max] — в
                # превью показываем детерминированный минимум (см. RangeUtils).
                var base_amount = float(RangeUtils.get_min_value(res_data["produces"][prod_id], 1))
                var final_amount = ceili(base_amount * bonus_multiplier)
                var prod_name = GameData.products.get(prod_id, {}).get("name", prod_id)
                # При активных модификаторах база указывается у каждого продукта.
                if bonus_multiplier != 1.0:
                    var base_str = str(int(base_amount)) if base_amount == floor(base_amount) else "%.1f" % base_amount
                    prod_name = tr("%s (base %s)") % [prod_name, base_str]
                var icon_path = ""
                var prod_data = GameData.products.get(prod_id, {})
                if prod_data.has("icon"):
                    var icon_name = prod_data["icon"]
                    icon_path = IconRegistry.icon_path(icon_name)
                products.append({"type": "product", "name": prod_name, "amount": float(final_amount) / prod_interval, "icon_path": icon_path, "suffix": tr(" units/sec")})
            for mod in modifiers:
                products.append({"type": "label", "text": " %s" % mod.get("label", ""), "color": Color(0.7, 0.9, 0.7)})
            # Рендерим в ОТДЕЛЬНЫЙ бокс: render_products очищает переданный
            # контейнер, поэтому нельзя давать ему _preview_container напрямую —
            # иначе он стирает блок выбора культуры, добавленный выше.
            var products_box = VBoxContainer.new()
            map_tooltip.render_products(products, products_box, true)
            _preview_container.add_child(products_box)

    # Дорога (спецдействие «Построить дорогу») — свой блок вместо общего
    # разбора «местность/расстояние»: её цена зависит от длины новой
    # трассы, а эти множители к дороге не применяются.
    if type == "special" and _is_road_action(action_id):
        _build_road_level_selector(int(preview.get("road_level", 1)))
        if not _build_road_preview(row, col, action_id):
            # Трассы нет — подтверждать нечего, кнопка «Начать» блокируется.
            build_btn.disabled = true
        return

    # Улучшение дороги — свой блок: участки уже стоят, платится только
    # разница уровней, и показывается это по той же схеме, что и постройка.
    if type == UPGRADE_ROAD_TYPE:
        _build_road_level_selector(int(preview.get("road_level", 1)))
        if not _build_road_upgrade_preview(row, col):
            build_btn.disabled = true
        return

    # Улучшение: дорога к нему строится вместе с ним, поэтому её уровень —
    # такой же выбор, как у «Построить дорогу». Селектор ставим ДО расчёта
    # цены: цена ниже включает доплату за дорогу выбранного уровня, и без
    # кнопки игрок не видел бы, откуда взялась эта сумма.
    if type == "build_improvement" or type == "build_breeding":
        _build_road_level_selector(int(preview.get("road_level", 1)))

    # Стоимость труда: детальный расчёт (база, местность, расстояние).
    # Дорога к улучшению строится вместе с ним, поэтому её цена — часть
    # цены улучшения. Расчёт берём из main_map (тот же источник, что и в
    # build_manager), иначе превью показало бы цену улучшения БЕЗ дороги,
    # а списалось бы с дорогой.
    var road_level := int(preview.get("road_level", 1))
    var cost_data = main_map.get_improvement_work_cost(cost_imp_id, row, col, road_level)
    var road_cost := int(cost_data.get("road_cost", 0))
    var cost_label = Label.new()
    cost_label.text = tr("Cost: %d work") % cost_data["cost"]
    cost_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    cost_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(cost_label)

    # Доплата за дорогу к улучшению — отдельной строкой: игрок видит, что
    # часть цены относится не к самому улучшению. Тропка бесплатна, и тогда
    # строка не показывается вовсе — платить нечего.
    if road_cost > 0:
        var road_hint := Label.new()
        road_hint.text = tr(" Road to the city (%s): %d work") % [
            GameData.get_road_name(road_level), road_cost]
        road_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        road_hint.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
        _preview_container.add_child(road_hint)

    # Детализация стоимости (переехала сюда из расширенного тултипа).
    var base_label = Label.new()
    base_label.text = tr(" Base: %d work") % cost_data["base_cost"]
    base_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    base_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(base_label)

    var move_cost_text = tr("impassable") if cost_data["move_cost"] >= 999.0 else str(int(cost_data["move_cost"]))
    var terrain_label = Label.new()
    terrain_label.text = tr(" Terrain: %s (move cost: %s) ×%.2f") % [cost_data["terrain_name"], move_cost_text, cost_data["terrain_mult"]]
    terrain_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    terrain_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(terrain_label)

    var dist_label = Label.new()
    # Расчёт множителя расстояния: исходный (1 + гексов × УНИВЕРСАЛЬНЫЙ
    # модификатор дальности из data/game_balance.json) плюс влияние изученных
    # технологий (например, «Колесо» -30%).
    var dist_text: String = tr(" Distance to city: %d hex(es) → base ×%.2f") % [cost_data["distance"], cost_data["distance_mult_base"]]
    if cost_data.has("distance_tech_mult") and cost_data["distance_tech_mult"] != 1.0:
        dist_text += tr(", technology ×%.2f") % cost_data["distance_tech_mult"]
    dist_text += " = ×%.2f" % cost_data["distance_mult"]
    dist_label.text = dist_text
    dist_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    dist_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(dist_label)

    var const_label = Label.new()
    if cost_data.has("construction_tech_mult") and cost_data["construction_tech_mult"] != 1.0:
        const_label.text = tr(" Construction technologies: ×%.2f") % cost_data["construction_tech_mult"]
    else:
        const_label.text = tr(" Construction technologies: ×1.00")
    const_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    const_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(const_label)

    var total_label = Label.new()
    total_label.text = tr(" Total: %d work") % cost_data["cost"]
    total_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    total_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(total_label)

    # Дебаг «Игнорировать требования строительства»: цена выше остаётся
    # расчётом «как было бы без флага», а выполняться действие будет сразу и
    # бесплатно. Без этой строки игрок видел бы цену и не понимал, почему
    # прогресс-бар не появляется.
    if CityData.ignore_build_requirements:
        _add_instant_hint()

# Жёлтая строка «выполняется мгновенно» для блоков превью.
func _add_instant_hint() -> void:
    var hint := Label.new()
    hint.text = tr(" Debug: instant and free")
    hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    hint.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5))
    _preview_container.add_child(hint)

# Синхронизирует «призрачную» дорогу и подсветку МАРШРУТА на карте с текущим
# состоянием панели. Три случая, и порядок важен:
#   · открыто превью улучшения дороги — рисуем призрак улучшаемых участков
#     (тот же стиль, что и при постройке, — участки уже стоят, но игрок должен
#     видеть, какой из них улучшается);
#   · открыто превью «Построить дорогу» — рисуем новые сегменты плана;
#   · превью нет — рисуем СУЩЕСТВУЮЩИЙ маршрут выбранного гекса до города.
# Последнее и есть требование «при нажатии на улучшение показывать маршрут»:
# без открытого превью игрок видит, по каким именно дорогам едет его груз.
# Вызывается из _refresh(), поэтому покрывает и ESC, и клик по другому гексу,
# и подтверждение постройки.
func _sync_road_preview_on_map() -> void:
    if main_map == null or main_map.map_renderer == null or _selected_hex == null:
        _set_map_road_preview({})
        return
    var row := int(_selected_hex.row)
    var col := int(_selected_hex.col)
    var preview_type := ""
    var action_id := ""
    if _preview_action != null:
        preview_type = str(_preview_action.get("type", ""))
        action_id = str(_preview_action.get("action_id", ""))
        if action_id != "" and not _is_road_action(action_id):
            action_id = ""
    if preview_type == UPGRADE_ROAD_TYPE:
        _set_map_road_preview(_get_upgrade_preview_segments(row, col))
        return
    if action_id != "":
        var plan: Dictionary = main_map.get_road_plan(row, col)
        if not plan.get("ok", false):
            # Трассы нет (например, к городку не разведан путь) — показывать
            # нечего, панель об этом уже сказала строкой с причиной.
            _set_map_road_preview({})
            return
        _set_map_road_preview(main_map.road_manager.get_plan_new_segments(plan))
        return
    if preview_type != "":
        # Открыто превью другого действия: маршрут не показываем, чтобы две
        # подсветки не спорили за карту.
        _set_map_road_preview({})
        return
    # Превью закрыто: призрак снимаем ВСЕГДА (иначе он остался бы висеть
    # после ESC), и вместо него показываем существующий маршрут гекса.
    _set_map_road_preview({})
    _set_map_route_display(_get_route_display_segments(row, col))

# Участки существующего маршрута выбранного гекса — для подсветки на карте.
# Пусто (не ошибка) у гексов без дороги, у самого города и у гексов вне
# влияния: там маршрута нет и показывать нечего.
func _get_route_display_segments(row: int, col: int) -> Dictionary:
    if not main_map.has_method("get_route_to_city"):
        return {}
    var route: Dictionary = main_map.get_route_to_city(row, col)
    if not route.get("ok", false):
        return {}
    var segments: Dictionary = {}
    for key in route.get("segments", []):
        segments[str(key)] = true
    return segments

# Участки, которые улучшит подтверждённое превью «Улучшить дорогу». Берём
# те же шаги, из которых потом стартует проект, — иначе подсветка и реальная
# стройка разошлись бы.
func _get_upgrade_preview_segments(row: int, col: int) -> Dictionary:
    var segments: Dictionary = {}
    var road_level := int(_preview_action.get("road_level", 1))
    var breakdown: Dictionary = main_map.get_road_upgrade_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        return segments
    for step in breakdown.get("steps", []):
        for key in step.get("ghost", {}).keys():
            segments[str(key)] = true
    return segments

func _set_map_road_preview(segments: Dictionary) -> void:
    if main_map == null or main_map.map_renderer == null:
        return
    main_map.map_renderer.set_road_preview_segments(segments)
    # Подсветка маршрута и призрак превью не должны гореть одновременно:
    # это разные смыслы (существующий маршрут vs. то, что будет построено).
    if not segments.is_empty():
        main_map.map_renderer.set_route_segments({})

func _set_map_route_display(segments: Dictionary) -> void:
    if main_map == null or main_map.map_renderer == null:
        return
    main_map.map_renderer.set_route_segments(segments)

# Действие ли это дорога (спецдействие build_road)?
func _is_road_action(action_id: String) -> bool:
    if action_id != ROAD_ACTION_ID:
        return false
    return str(GameData.special_actions.get(action_id, {}).get("action_type", "")) == "road"

# --- Выбор уровня дороги ---
# По кнопке на каждый ИССЛЕДОВАННЫЙ уровень, от лучшего к худшему. Общий блок
# для трёх случаев — «Построить дорогу», постройка улучшения (дорога к нему
# строится вместе с ним) и «Улучшить дорогу»: правило выбора одно, поэтому и
# вид один.
#
# Кнопка показывает уровень ПРОСВЕЧЕННЫМ («free» у тропки), иначе игрок не
# понимает, почему её нажатие ничего не стоит.
func _build_road_level_selector(selected_level: int) -> void:
    var levels: Array = GameData.get_unlocked_road_levels()
    if levels.size() <= 1:
        # Выбирать нечего: доступен только базовый уровень. Молчаливый пропуск
        # лучше серой кнопки — игрок и так видит единственный вариант в цене.
        return

    var label := Label.new()
    label.text = tr("Road level:")
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(label)

    var flow := FlowContainer.new()
    flow.add_theme_constant_override("h_separation", 4)
    flow.add_theme_constant_override("v_separation", 4)
    _preview_container.add_child(flow)

    for i in range(levels.size() - 1, -1, -1):
        var level := int(levels[i])
        var level_name := GameData.get_road_name(level)
        var cost := GameData.get_road_work_cost(level)
        var speed := GameData.get_road_max_speed(level)
        var btn := Button.new()
        btn.toggle_mode = true
        btn.set_pressed_no_signal(level == selected_level)
        # Тултип несёт обе цифры уровня: цену участка и пропускную
        # способность. Без них кнопка «Cart Road» ничего не объясняет.
        btn.tooltip_text = tr("%s: up to %d units/sec per section, base %d work per section") % [level_name, speed, cost]
        var shown_name: String = level_name if cost > 0 \
                else tr("%s (free)") % level_name
        btn.text = shown_name
        # Явная рамка у выбранного уровня — по образцу выбора культуры.
        var pressed_style = StyleBoxFlat.new()
        pressed_style.set_border_width_all(2)
        pressed_style.border_color = Color(1.0, 0.85, 0.2)
        btn.add_theme_stylebox_override("pressed", pressed_style)
        btn.add_theme_stylebox_override("hover_pressed", pressed_style)
        btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
        var chosen := level
        btn.pressed.connect(func():
            _select_preview_road_level(chosen)
        )
        flow.add_child(btn)

# Выбор уровня дороги в превью. Уровень пишется в _preview_action, и превью
# перестраивается: снапшот включает road_level (см. _build_preview), поэтому
# блок не остаётся от прежнего уровня.
func _select_preview_road_level(level: int):
    if _preview_action == null:
        return
    _preview_action["road_level"] = level
    _refresh()

# Блок превью для улучшения дороги: какие участки и до какого уровня, и
# сколько это стоит. Возвращает false, если улучшать нечего — тогда кнопка
# «Начать» блокируется, и игрок видит причину.
func _build_road_upgrade_preview(row: int, col: int) -> bool:
    var road_level := int(_preview_action.get("road_level", 1))
    var breakdown: Dictionary = main_map.get_road_upgrade_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        var warn := Label.new()
        warn.text = " %s" % str(breakdown.get("reason", tr("Nothing to upgrade")))
        warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        warn.add_theme_color_override("font_color", Color(0.9, 0.6, 0.6))
        _preview_container.add_child(warn)
        return false

    var target_label := Label.new()
    target_label.text = tr(" Destination: from the city to this hex along the existing road")
    target_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    target_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(target_label)

    var cost_label := Label.new()
    cost_label.text = tr(" Cost: %d work") % int(breakdown.get("cost", 0))
    cost_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    cost_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(cost_label)

    var base_label := Label.new()
    base_label.text = tr(" Base: %d work per section") % GameData.get_road_work_cost(road_level)
    base_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    base_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(base_label)

    var sections_label := Label.new()
    sections_label.text = tr(" Sections to upgrade: %d") % int(breakdown.get("segments", 0))
    sections_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    sections_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(sections_label)

    # Что получится по скорости: узкое место маршрута после улучшения. Без
    # этой строки игрок видит только цену и не понимает, что именно он
    # покупает — ведь улучшается ради пропускной способности.
    var route: Dictionary = main_map.get_route_to_city(row, col)
    if route.get("ok", false):
        var speed_label := Label.new()
        speed_label.text = tr(" Bottleneck: %d → %d units/sec, average %d units/sec") % [
            int(route.get("min_speed", 0)),
            GameData.get_road_max_speed(road_level),
            int(ceil(float(GameData.get_road_max_speed(road_level)))),
        ]
        speed_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        speed_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
        _preview_container.add_child(speed_label)

    if CityData.ignore_build_requirements:
        _add_instant_hint()
    return true

# Блок превью для дороги: куда пойдёт трасса, из скольких участков она
# состоит и сколько это труда. Возвращает false, если трассы нет — тогда
# кнопка «Начать» блокируется, а игрок видит причину.
func _build_road_preview(row: int, col: int, action_id: String) -> bool:
    var road_level := int(_preview_action.get("road_level", 1))
    var plan: Dictionary = main_map.get_road_plan(row, col)
    if not plan.get("ok", false):
        var warn := Label.new()
        warn.text = " %s" % str(plan.get("reason", tr("Cannot build a road")))
        warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        warn.add_theme_color_override("font_color", Color(0.9, 0.6, 0.6))
        _preview_container.add_child(warn)
        return false

    # Куда пойдёт дорога. У городка цель — не сам его гекс, а дороги его
    # кольца влияния (см. road_manager.plan_road_to).
    var target_label := Label.new()
    if bool(plan.get("is_town", false)):
        var town = null
        if main_map.town_manager != null:
            town = main_map.town_manager.find_town_at(row, col)
        var town_name := str(town.get("name", tr("the town"))) if town != null else tr("the town")
        target_label.text = tr(" Destination: the nearest road in the town \"%s\" influence ring") % town_name
        # Маршрут может оказаться длиннее, чем «прямая» дорога: он идёт только
        # по разведанной территории — ровно тем путём, которым игрок дошёл до
        # городка. Без этой строки цена в 2–3 раза выше ожидаемой выглядит
        # ошибкой.
        target_label.text += tr(" (only across scouted territory)")
    else:
        target_label.text = tr(" Destination: from the city's nearest road to this hex")
    target_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    target_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(target_label)

    # Цена и шаги — из ЕДИНОГО источника (main_map.get_road_cost_breakdown),
    # из которого потом стартует проект. Итог здесь равен сумме цен участков
    # по построению, а не пересчитывается отдельно.
    # Тип указан явно: main_map в панели не типизирован, а без подсказки
    # Godot не может вывести тип возврата динамического вызова.
    var breakdown: Dictionary = main_map.get_road_cost_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        var warn2 := Label.new()
        warn2.text = " %s" % str(breakdown.get("reason", tr("Cannot build a road")))
        warn2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        warn2.add_theme_color_override("font_color", Color(0.9, 0.6, 0.6))
        _preview_container.add_child(warn2)
        return false

    var cost_label := Label.new()
    cost_label.text = tr(" Cost: %d work") % int(breakdown.get("cost", 0))
    cost_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    cost_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(cost_label)

    # Цены участков РАЗНЫЕ: у каждого своя местность и своя дальность от
    # города. Поэтому показываем диапазон, а не одну цифу — иначе игрок видит
    # на карте участки с очень разными прогресс-барами и не понимает почему.
    var min_step := int(breakdown.get("min_step_cost", 0))
    var max_step := int(breakdown.get("max_step_cost", 0))
    var step_text := tr(" Per section: %d work") % min_step
    if max_step != min_step:
        step_text = tr(" Per section: %d to %d work") % [min_step, max_step]
    step_text += tr(" (base %d)") % GameData.get_road_work_cost(road_level)
    var step_label := Label.new()
    step_label.text = step_text
    step_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    step_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(step_label)

    var segments_label := Label.new()
    segments_label.text = tr(" New route sections: %d") % int(breakdown.get("segments", 0))
    segments_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    segments_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(segments_label)

    # Дальность: тащить материалы до дальних гексов дороже. Диапазон по
    # трассе, потому что участки идут от сети к цели и удаляются от города.
    var min_dist := int(breakdown.get("min_distance", 0))
    var max_dist := int(breakdown.get("max_distance", 0))
    var dist_label := Label.new()
    var dist_text := tr(" Distance to city: %d hex(es)") % min_dist
    if max_dist != min_dist:
        dist_text = tr(" Distance to city: %d to %d hex(es)") % [min_dist, max_dist]
    dist_text += tr(" → base ×%.2f…×%.2f") % [
        MapHelpers.get_road_distance_mult(min_dist),
        MapHelpers.get_road_distance_mult(max_dist)]
    dist_label.text = dist_text
    dist_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    dist_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(dist_label)

    # Местности на трассе с множителями: объясняет вторую половину цены.
    # Без этой строки «почему так дорого» остаётся без ответа, когда трасса
    # идёт через болото или горы.
    var terrain_ids: Array = breakdown.get("terrains", [])
    if not terrain_ids.is_empty():
        var parts: Array[String] = []
        for tid in terrain_ids:
            var tname: String = str(GameData.terrains.get(tid, {}).get("name", tid))
            parts.append("%s ×%.2f" % [tname, MapHelpers.get_terrain_work_mult(tid)])
        var terr_label := Label.new()
        terr_label.text = tr(" Terrain on the route: %s") % ", ".join(parts)
        terr_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        terr_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
        _preview_container.add_child(terr_label)

    # Как именно пойдёт стройка: дорога строится ПО УЧАСТКАМ — по одному гексу,
    # с прогресс-баром на текущем участке. Без этой строки игрок ждёт готовую
    # дорогу целиком и не понимает, почему она появляется по кускам.
    var steps_hint := Label.new()
    steps_hint.text = tr(" Will be built in sections: one hex at a time")
    steps_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    steps_hint.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
    _preview_container.add_child(steps_hint)

    # Дебаг «Игнорировать требования строительства» — та же строка, что и в
    # обычном превью: трасса прокладывается целиком и без ожидания.
    if CityData.ignore_build_requirements:
        _add_instant_hint()
    return true

# Сравнивает два снапшота блока превью по значимым полям.
func _preview_equal(a: Dictionary, b: Dictionary) -> bool:
    return a.get("row", -1) == b.get("row", -1) \
        and a.get("col", -1) == b.get("col", -1) \
        and a.get("type", "") == b.get("type", "") \
        and a.get("label", "") == b.get("label", "") \
        and a.get("imp_id", "") == b.get("imp_id", "") \
        and a.get("action_id", "") == b.get("action_id", "") \
        and a.get("target_res_id", null) == b.get("target_res_id", null) \
        and a.get("eff_res", "") == b.get("eff_res", "") \
        and a.get("selected_culture_id", null) == b.get("selected_culture_id", null) \
        and int(a.get("road_level", 1)) == int(b.get("road_level", 1)) \
        and a.get("ignore_build", false) == b.get("ignore_build", false)

# Подтверждение постройки из превью.
func _confirm_build():
    if _selected_hex == null or _preview_action == null:
        return
    var row = _selected_hex.row
    var col = _selected_hex.col
    var preview = _preview_action
    var type = preview.get("type", "")
    var imp_id = preview.get("imp_id", "")
    var target_res_id = preview.get("target_res_id", null)
    var action_id = preview.get("action_id", "")
    var road_level = int(preview.get("road_level", GameData.get_max_unlocked_road_level()))

    if type == "build_improvement":
        build_manager.start_build(row, col, imp_id, target_res_id, road_level)
    elif type == "build_breeding":
        # Строим выбранное улучшение под культуру; если культура не задана или
        # не подходит, берём первую подходящую.
        var breeding_imp = preview.get("imp_id", "")
        var chosen_animal = preview.get("selected_culture_id", null)
        if not _is_suitable_culture(row, col, chosen_animal, breeding_imp):
            chosen_animal = _first_suitable_culture(row, col, breeding_imp)
        if chosen_animal != null:
            build_manager.start_build(row, col, breeding_imp, chosen_animal, road_level)
    elif type == UPGRADE_ROAD_TYPE:
        main_map.start_road_upgrade_project(row, col, road_level)
    elif type == "special":
        build_manager.start_build(row, col, action_id, null, road_level)

    # После подтверждения сбрасываем превью, но оставляем выделение.
    _preview_action = null
    main_map.map_renderer.queue_redraw()
    main_map.redraw_progress_layer()
    _refresh()

# --- Хелперы ---
# Название технологии по id — единый источник в CityData (см. get_tech_name).
func _get_tech_name(tech_id: String) -> String:
    return CityData.get_tech_name(tech_id)

# Возвращает список одомашненных культур, которые можно разводить через
# указанное улучшение на гексе (row, col).
# Каждый элемент: { "id": String, "name": String }.
func _get_suitable_crops(row: int, col: int, imp_kind: String) -> Array:
    var tile = main_map.get_tile_data(row, col)
    var ids: Array
    ids = CityData.domesticated_resources.duplicate()
    var out := []
    for id in ids:
        var data = GameData.raw_resources.get(id, {})
        # breedable и биом разведения проверяются единым хелпером; в частности,
        # он учитывает дополнительные условия поля resource.breeding.
        if not MapHelpers.can_breed_resource_by(id, imp_kind):
            continue
        if not MapHelpers.can_breed_resource_on_tile(id, tile):
            continue
        out.append({"id": id, "name": data.get("name", id)})
    return out

# Возвращает true, если культура (растение/животное) подходит для гекса (row, col)
# и входит в одомашненные виды, разрешённые указанным улучшением.
func _is_suitable_culture(row: int, col: int, id, imp_kind: String) -> bool:
    if id == null or id == "":
        return false
    var tile = main_map.get_tile_data(row, col)
    var data = GameData.raw_resources.get(id, {})
    if data.is_empty():
        return false
    var ids: Array = CityData.domesticated_resources.duplicate()
    # breedable: false (напр. рыба) — прямое подтверждение разведения невозможно.
    if not MapHelpers.can_breed_resource_by(id, imp_kind):
        return false
    if not (id in ids):
        return false
    return MapHelpers.can_breed_resource_on_tile(id, tile)

# Возвращает id первого одомашненного вида, подходящего для гекса, или null.
func _first_suitable_culture(row: int, col: int, imp_kind: String):
    var crops := _get_suitable_crops(row, col, imp_kind)
    if crops.is_empty():
        return null
    return crops[0].id

# Выбирает культуру в активном превью (ферма/пастбище) и пересобирает блок,
# чтобы подсветка выбранной кнопки обновилась.
func _select_preview_culture(id: String):
    if _preview_action != null:
        _preview_action["selected_culture_id"] = id
        # Синхронизируем эффективный ресурс, чтобы блок «Будет производить»
        # в превью пересчитался под новую культуру.
        var t = _preview_action.get("type", "")
        if t == "build_breeding":
            _preview_action["eff_res"] = id
    _refresh()
