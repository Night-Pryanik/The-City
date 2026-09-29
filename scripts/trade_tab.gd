# trade_tab.gd
# Вкладка «Торговля». Слева — ВНУТРЕННЯЯ торговля, справа — ВНЕШНЯЯ
# (колонка-заглушка, сама внешняя торговля ещё не реализована).
#
# Левая колонка: по одной карточке на ресурс или группу ресурсов, которые
# город сейчас потребляет. Источник данных —
# worker_manager.get_population_consumption_map(): профессии рабочих и
# горожан + псевдо-профессия «Все жители», ключ строки — display_key.
#
# РАЗМЕТКА карточки живёт в сцене res://scenes/TradeResourceCard.tscn, а не
# в коде: скрипт инстанцирует её и подставляет только значения. Так любой
# элемент карточки можно передвинуть мышкой в редакторе сцены.
extends Node

# Сцена карточки одного ресурса (см. файл сцены — там же список узлов,
# к которым обращается этот скрипт).
const CARD_SCENE = preload("res://scenes/TradeResourceCard.tscn")

var internal_list: Node
var ui_helpers: Node
# WorkerManager прокидывается из main_map через city_ui.set_worker_manager.
var worker_manager: Node = null

# Кэш текущих данных карточек: display_key -> { узлы карточки, строка данных }.
var cards: Dictionary = {}
# Набор отображаемых ключей: подпись для сравнения «состав списка не изменился».
var _signature: String = ""
# Флаг синхронизации двух кнопок-тумблеров: без него программная установка
# button_pressed у CheckBox вызывала бы сигнал toggled и зациклила правку.
var _syncing_toggles: bool = false
# Активный тултип разбора качества — для обновления в реальном времени.
var _quality_key: String = ""

# Состояния цвета/текста карточки.
const COLOR_TITLE := Color(1, 1, 1, 1)
const COLOR_CAPTION := Color(0.75, 0.75, 0.75, 1)
const COLOR_PRICE := Color(1.0, 0.507, 0.0, 1)
const COLOR_CONSUMPTION := Color(0.9, 0.3, 0.3, 1)
const COLOR_DISABLED := Color(0.62, 0.62, 0.62, 1)
const COLOR_ON := Color(0, 0.8, 0, 1)
const COLOR_OFF := Color(0.8, 0.1, 0.1, 1)

func setup(list: Node, helpers: Node) -> void:
    internal_list = list
    ui_helpers = helpers

func set_worker_manager(wm: Node) -> void:
    worker_manager = wm

# Полная пересборка списка карточек: состав ресурсов определяется текущими
# профессиями и населением, поэтому он меняется структурно (назначили
# рабочего, построили здание). Вызывается при открытии вкладки и при
# расхождении подписи состава (см. update_values).
func refresh() -> void:
    if internal_list == null or not is_instance_valid(internal_list):
        return
    for child in internal_list.get_children():
        internal_list.remove_child(child)
        child.queue_free()
    cards.clear()
    _quality_key = ""
    _signature = ""

    var data: Dictionary = _collect_data()
    # Сортировка по названию — список читаем и предсказуем между тиками.
    var keys: Array = data.keys()
    keys.sort_custom(func(a, b): return str(data[a].get("name", a)) < str(data[b].get("name", b)))
    for key in keys:
        _create_card(str(key), data[key])
        _signature += str(key) + ";"
    if internal_list.get_child_count() == 0:
        var empty := Label.new()
        empty.text = "Пока никто ничего не потребляет"
        empty.add_theme_color_override("font_color", COLOR_CAPTION)
        internal_list.add_child(empty)

# Лёгкое обновление: меняются только тексты и состояния кнопок, узлы
# карточек переиспользуются (иначе мигали бы тултипы под курсором).
func update_values() -> void:
    if internal_list == null or not is_instance_valid(internal_list):
        return
    var data: Dictionary = _collect_data()
    var signature := ""
    for key in data:
        signature += str(key) + ";"
    if signature != _signature:
        # Состав списка изменился — нужна полная пересборка.
        refresh()
        return
    for key in cards:
        if data.has(key):
            _update_card(cards[key], data[key])

# Данные всех карточек из worker_manager + склада. Формируется заново при
# каждом обновлении: он дешёвый (перебор профессий) и всегда актуален.
func _collect_data() -> Dictionary:
    var result: Dictionary = {}
    if worker_manager == null or not is_instance_valid(worker_manager) \
            or not worker_manager.has_method("get_population_consumption_map"):
        return result
    result = worker_manager.get_population_consumption_map()
    for key in result:
        result[key]["stock"] = _collect_stock(result[key].get("members", []))
        result[key]["price_text"] = _format_price(result[key])
        result[key]["actual"] = _collect_actual(result[key].get("members", []))
    return result

# Запас ресурса на складе: { "total": int, "quality": {qid: count} }.
# Для группы складывается по всем членам — они взаимозаменяемы, поэтому
# разбивка по качеству суммируется (уровни у всех членов общие).
func _collect_stock(members: Array) -> Dictionary:
    var total := 0
    var quality: Dictionary = {}
    for pid in members:
        total += CityData.get_storage_amount(str(pid))
        var detail: Dictionary = CityData.get_quality_breakdown(str(pid))
        for qid in detail:
            quality[str(qid)] = int(quality.get(str(qid), 0)) + int(detail[qid])
    return {"total": total, "quality": quality}

# Фактическое потребление на внутреннем рынке за последний тик: сумма по
# членам группы (CityData.market_consumption_rates — счётчик без
# производственных входов, в отличие от общего consumption_rates).
func _collect_actual(members: Array) -> int:
    var total := 0
    for pid in members:
        total += int(CityData.market_consumption_rates.get(str(pid), 0))
    return total

# Текст цены товара. Одиночный ресурс — цена внутреннего рынка для
# обычного качества (CityData.get_internal_market_price). Группа — диапазон
# «мин–макс» по членам с ценой: у членов группы цены разные, и одна
# усреднённая цифра ввела бы в заблуждение. Подробности — в тултипе.
func _format_price(row: Dictionary) -> String:
    var members: Array = row.get("members", [])
    if not bool(row.get("is_group", false)):
        return str(CityData.get_internal_market_price(str(members[0]) if members.size() > 0 else ""))
    var min_price := -1
    var max_price := -1
    for pid in members:
        var price: int = CityData.get_internal_market_price(str(pid))
        if price <= 0:
            continue
        if min_price < 0 or price < min_price:
            min_price = price
        if price > max_price:
            max_price = price
    if min_price < 0:
        return "—"
    if min_price == max_price:
        return str(min_price)
    return "%d–%d" % [min_price, max_price]

# Разбивка склада по качеству строкой с процентами в цветах уровней —
# тот же формат, что у метки качества на вкладке «Ресурсы»
# (GameData.format_quality_share_text). Пустая строка — разбивки нет.
func _format_quality(stock: Dictionary) -> String:
    var text := GameData.format_quality_share_text(stock.get("quality", {}))
    if text == "":
        return ""
    return "★ %s" % text

# Форматирование скорости: целые значения без дробной части, дробные — с
# одним знаком (та же конвенция, что в ui_helpers._format_rate).
func _format_rate(value: float) -> String:
    if is_equal_approx(value, roundf(value)):
        return str(int(roundf(value)))
    return "%.1f" % value

# Создаёт карточку по шаблону сцены и подписывает её сигналы. Сама разметка
# — в res://scenes/TradeResourceCard.tscn; здесь только поиск узлов по именам
# и подстановка значений.
func _create_card(display_key: String, row: Dictionary) -> void:
    var card: PanelContainer = CARD_SCENE.instantiate()
    internal_list.add_child(card)
    var ctx := {
        "key": display_key,
        "card": card,
        "icon": card.get_node("Layout/Header/Icon"),
        "name": card.get_node("Layout/Header/NameLabel"),
        "priority_btn": card.get_node("Layout/Header/PriorityButton"),
        "toggle_rect": card.get_node("Layout/Header/TradeToggleRect"),
        "checkbox": card.get_node("Layout/Header/TradeCheckBox"),
        "stock": card.get_node("Layout/StockRow/StockValue"),
        "quality": card.get_node("Layout/StockRow/QualityLabel"),
        "price": card.get_node("Layout/DetailRow/PriceValue"),
        "consumers": card.get_node("Layout/DetailRow/ConsumersValue"),
        "consumption": card.get_node("Layout/DetailRow/ConsumptionValue"),
    }
    cards[display_key] = ctx
    var icon: TextureRect = ctx["icon"]
    var texture := _get_icon_texture(str(row.get("icon", "")))
    if texture != null:
        icon.texture = texture
    else:
        # Иконки нет (например, у группы без иконок у членов) — прячем узел,
        # чтобы в заголовке не зияла пустота 32×32.
        icon.hide()
    # Наведение на разбивку качества — тот же тултип, что на вкладке
    # «Ресурсы» (ui_helpers.show_quality_tooltip).
    var quality: RichTextLabel = ctx["quality"]
    quality.mouse_entered.connect(_on_quality_hover.bind(display_key))
    quality.mouse_exited.connect(_on_quality_exit)
    # Тултипы цены и покупателей — штатные (их оформляет тема в theme/).
    var price: Label = ctx["price"]
    price.mouse_entered.connect(_on_price_hover.bind(display_key))
    price.mouse_exited.connect(_on_price_exit)
    var consumers: Label = ctx["consumers"]
    consumers.mouse_entered.connect(_on_consumers_hover.bind(display_key))
    consumers.mouse_exited.connect(_on_consumers_exit)
    # Приоритет потребления — тот же цикл, что у кнопки качества здания.
    var priority_btn: Button = ctx["priority_btn"]
    priority_btn.pressed.connect(_on_priority_pressed.bind(display_key))
    # Две кнопки одного тумблера: прямоугольник (как тумблер еды на
    # вкладке «Ресурсы») и стандартный CheckBox. Функционал один и тот же —
    # выбрать можно любой, они показывают одно состояние.
    var toggle_rect: ColorRect = ctx["toggle_rect"]
    toggle_rect.mouse_filter = Control.MOUSE_FILTER_STOP
    toggle_rect.gui_input.connect(_on_toggle_rect_input.bind(display_key))
    var checkbox: CheckBox = ctx["checkbox"]
    checkbox.toggled.connect(_on_checkbox_toggled.bind(display_key))
    _update_card(ctx, row)

# Обновляет значения существующей карточки (без пересоздания узлов).
func _update_card(ctx: Dictionary, row: Dictionary) -> void:
    var display_key: String = str(ctx["key"])
    var enabled := bool(row.get("enabled", true))
    var title: String = str(row.get("name", display_key))
    if bool(row.get("is_group", false)):
        title += " (группа)"
    var name_label: Label = ctx["name"]
    name_label.text = title
    var stock: Dictionary = row.get("stock", {})
    var stock_label: Label = ctx["stock"]
    stock_label.text = str(int(stock.get("total", 0)))
    var quality: RichTextLabel = ctx["quality"]
    var quality_text := _format_quality(stock)
    quality.text = quality_text
    quality.tooltip_text = "" if quality_text == "" else "Разбивка склада по качеству"
    quality.visible = quality_text != ""
    var price: Label = ctx["price"]
    price.text = str(row.get("price_text", "—"))
    var consumers: Label = ctx["consumers"]
    consumers.text = str(int(row.get("consumers_total", 0)))
    # Расход: факт за последний тик, а при его отсутствии — план с
    # маркером «≈» (та же договорённость, что у метки динамики вкладки
    # «Ресурсы»). У запрещённого ресурса расхода нет вовсе.
    var consumption: Label = ctx["consumption"]
    var per_sec := float(row.get("per_sec", 0.0))
    var actual := int(row.get("actual", 0))
    if not enabled:
        consumption.text = "—"
    elif actual > 0:
        consumption.text = "%s/сек" % _format_rate(float(actual))
    elif per_sec > 0.0:
        consumption.text = "≈%s/сек" % _format_rate(per_sec)
    else:
        consumption.text = "0/сек"
    # Состояние приглушается у запрещённого ресурса: он остаётся в списке
    # (иначе его нельзя было бы включить обратно), но выглядит отключённым.
    var card: PanelContainer = ctx["card"]
    card.modulate = Color(1, 1, 1, 1) if enabled else COLOR_DISABLED
    name_label.add_theme_color_override("font_color", COLOR_TITLE if enabled else COLOR_DISABLED)
    price.add_theme_color_override("font_color", COLOR_PRICE if enabled else COLOR_DISABLED)
    consumption.add_theme_color_override("font_color", COLOR_CONSUMPTION if enabled else COLOR_DISABLED)
    _update_priority_button(ctx["priority_btn"], str(row.get("priority", "best")))
    _update_toggles(ctx, enabled)

# Текст и подсказка кнопки приоритета. Индикация — та же, что в окне
# деталей здания (building_panel._update_quality_button): звёзды лучшего
# уровня для «best», худшего — для «worst», кубик для «random».
func _update_priority_button(button: Button, priority: String) -> void:
    var levels: Array = GameData.get_quality_levels()
    if priority == "worst" and levels.size() > 0:
        button.text = GameData.get_quality_stars(levels.front())
    elif priority == "best" and levels.size() > 0:
        button.text = GameData.get_quality_stars(levels.back())
    elif priority == "random":
        button.text = "🎲"
    else:
        button.text = "★"
    button.tooltip_text = "Приоритет потребления: %s (нажмите чтобы переключить)" \
        % GameData.get_quality_priority_name(priority)

# Синхронизирует ОБЕ кнопки-тумблера с состоянием. Флаг _syncing_toggles
# гасит обратный вызов: программная установка button_pressed иначе сама
# вызвала бы toggled и зациклила правку.
func _update_toggles(ctx: Dictionary, enabled: bool) -> void:
    _syncing_toggles = true
    var toggle_rect: ColorRect = ctx["toggle_rect"]
    toggle_rect.color = COLOR_ON if enabled else COLOR_OFF
    var checkbox: CheckBox = ctx["checkbox"]
    checkbox.button_pressed = enabled
    _syncing_toggles = false

# --- ДВЕ КНОПКИ-ТУМБЛЕРА ОДНОГО ПЕРЕКЛЮЧАТЕЛЯ ---
# Обработчики обоих вызывают общий _set_enabled: состояние одно, различается
# только внешний вид (прямоугольник против CheckBox). Выбор варианта — за
# игроком, функционально они эквивалентны.

# Клик по прямоугольнику (вариант «как тумблер еды на вкладке „Ресурсы"»).
func _on_toggle_rect_input(event: InputEvent, display_key: String) -> void:
    if event is InputEventMouseButton \
            and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        _set_enabled(display_key, not CityData.is_market_consumption_enabled(display_key))

# Клик по стандартному чекбоксу.
func _on_checkbox_toggled(pressed: bool, display_key: String) -> void:
    if _syncing_toggles:
        return # программная синхронизация — не пользовательское действие
    _set_enabled(display_key, pressed)

# Общее переключение: пишем состояние в CityData и обновляем карточку.
func _set_enabled(display_key: String, enabled: bool) -> void:
    CityData.set_market_consumption_enabled(display_key, enabled)
    if not cards.has(display_key):
        return
    var ctx: Dictionary = cards[display_key]
    _update_toggles(ctx, enabled)
    # Расход и приглушение считаются из данных — обновляем карточку целиком.
    var data: Dictionary = _collect_data()
    if data.has(display_key):
        _update_card(ctx, data[display_key])

# --- КНОПКА ПРИОРИТЕТА ПОТРЕБЛЕНИЯ ---
# Цикл best → worst → random → best (порядок из data/qualities.json).
func _on_priority_pressed(display_key: String) -> void:
    var priority := CityData.cycle_consumption_priority(display_key)
    if not cards.has(display_key):
        return
    var ctx: Dictionary = cards[display_key]
    _update_priority_button(ctx["priority_btn"], priority)
    var row: Dictionary = _collect_data().get(display_key, {})
    _show_message("%s: приоритет потребления — %s" % [
        _row_title(row, display_key), GameData.get_quality_priority_name(priority)])

# Заголовок карточки для сообщений (с пометкой группы, как в самой карточке).
func _row_title(row: Dictionary, display_key: String) -> String:
    var title := str(row.get("name", display_key))
    if bool(row.get("is_group", false)):
        title += " (группа)"
    return title

# --- ТУЛТИПЫ ---
# Разбор склада по качеству — тот же тултип, что у метки качества на
# вкладке «Ресурсы» (ui_helpers.show_quality_tooltip). Для группы
# показывается объединённая разбивка по всем членам.
func _on_quality_hover(display_key: String) -> void:
    _quality_key = display_key
    var row: Dictionary = _row_data(display_key)
    if row.is_empty() or ui_helpers == null or not is_instance_valid(ui_helpers):
        return
    var quality: Dictionary = row.get("stock", {}).get("quality", {})
    if quality.is_empty():
        return
    ui_helpers.show_quality_tooltip(
        get_viewport().get_mouse_position(),
        _row_title(row, display_key), quality)

func _on_quality_exit() -> void:
    _quality_key = ""
    if ui_helpers != null and is_instance_valid(ui_helpers):
        ui_helpers.hide_quality_tooltip()

# Цена: лестница цен по уровням качества, которые реально лежат на складе
# (GameData.format_quality_price_scale_rows). У группы — цена каждого
# члена, потому что у членов группы цены разные.
func _on_price_hover(display_key: String) -> void:
    var row: Dictionary = _row_data(display_key)
    if row.is_empty():
        return
    var stock_quality: Dictionary = row.get("stock", {}).get("quality", {})
    var lines: Array = []
    for pid in row.get("members", []):
        var member := str(pid)
        var price_rows: Array = GameData.format_quality_price_scale_rows(member, stock_quality)
        var member_name: String = str(GameData.products.get(member, {}).get("name", member))
        if price_rows.is_empty():
            lines.append("%s: %s" % [member_name, str(CityData.get_internal_market_price(member))])
        else:
            for price_row in price_rows:
                lines.append("%s %s" % [member_name, str(price_row["text"])])
    if lines.is_empty():
        return
    var node: Label = cards[display_key]["price"]
    node.tooltip_text = "\n".join(lines)

func _on_price_exit() -> void:
    _clear_tooltip("price")

# Покупатели: кто именно потребляет ресурс и с какой скоростью.
func _on_consumers_hover(display_key: String) -> void:
    var row: Dictionary = _row_data(display_key)
    if row.is_empty():
        return
    var lines: Array = []
    var sources: Dictionary = row.get("sources", {})
    for source_name in sources:
        var entry: Dictionary = sources[source_name]
        var amount := float(entry.get("amount", 0))
        var interval := float(entry.get("interval", 0))
        var per_sec: float = amount * CityData.SIMULATION_TICK / interval \
            if interval > 0.0 else amount * CityData.SIMULATION_TICK
        var count := int(entry.get("count", 0))
        var suffix := ""
        if bool(entry.get("is_population", false)):
            suffix = " (%d чел.)" % count
        elif count > 1:
            suffix = " х%d" % count
        lines.append("%s%s: %s/сек" % [source_name, suffix, _format_rate(per_sec)])
    if lines.is_empty():
        return
    lines.sort()
    var node: Label = cards[display_key]["consumers"]
    node.tooltip_text = "\n".join(lines)

func _on_consumers_exit() -> void:
    _clear_tooltip("consumers")

# Снимает штатный тултип с узла карточки по его ключу в ctx.
func _clear_tooltip(node_key: String) -> void:
    for key in cards:
        var node = cards[key].get(node_key, null)
        if node != null and is_instance_valid(node):
            node.tooltip_text = ""

# Строка данных карточки по ключу (или пустой словарь, если карточки нет).
func _row_data(display_key: String) -> Dictionary:
    return _collect_data().get(display_key, {})

# Сообщение в нижнюю панель города (ui_helpers.set_message).
func _show_message(text: String) -> void:
    if ui_helpers != null and is_instance_valid(ui_helpers):
        ui_helpers.set_message(text)

# --- ИКОНКИ ---
# Индекс иконок строится один раз и кэшируется: обход res://icons на
# каждый кадр был бы лишней работой (тот же приём, что в resources_tab).
var _icon_paths: Dictionary = {}
var _icon_textures: Dictionary = {}

func _get_icon_texture(icon_file: String) -> Texture2D:
    if icon_file.is_empty():
        return null
    if _icon_textures.has(icon_file):
        return _icon_textures[icon_file]
    if _icon_paths.is_empty():
        _scan_icons("res://icons")
    if _icon_paths.has(icon_file):
        var texture: Texture2D = load(_icon_paths[icon_file])
        _icon_textures[icon_file] = texture
        return texture
    return null

func _scan_icons(folder_path: String) -> void:
    var dir := DirAccess.open(folder_path)
    if dir == null:
        return
    dir.list_dir_begin()
    var file_name := dir.get_next()
    while file_name != "":
        if dir.current_is_dir():
            _scan_icons(folder_path.path_join(file_name))
        else:
            _icon_paths[file_name] = folder_path.path_join(file_name)
        file_name = dir.get_next()
    dir.list_dir_end()
