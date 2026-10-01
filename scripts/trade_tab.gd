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
#
# ОБНОВЛЕНИЕ подчинено интервалу отображения ресурсов из настроек
# (CityData.resource_display_epoch, см. city_ui._refresh_light), как вкладка
# «Ресурсы». Раньше карточки пересчитывались каждый тик, из-за чего мигали
# числа и слетали тултипы, за которыми игрок водит мышью.
#
# ТУЛТИПЫ заполняются здесь же, при обновлении карточки, а НЕ по наведению.
# Причина — особенность движка: у Label по умолчанию mouse_filter = IGNORE,
# поэтому сигнал mouse_entered на такой узел не приходит вовсе, и подход
# «навели — собрали текст — присвоили tooltip_text» не срабатывал никогда
# (проверено на Godot 4.7). У узлов с тултипами в сцене стоит
# mouse_filter = 0 (STOP), а текст кладётся заранее — так тултип ещё и
# совпадает с числами на карточке: он собран из тех же данных того же окна.
# Единственное исключение — разбивка по качеству: это своя панель
# ui_helpers, и она по-прежнему вешается по наведению.
#
# ДОХОД в строке «Доход» — ФАКТ за окно отображения (столько монет в секунду
# рынок реально принёс казне), а не план «весь спрос × цена». План складом не
# ограничен и для полупустого склада давал фантастические 2730 монет/сек, чего
# в казне никогда не было; факт же сходится с числом в строке «Казна» HUD.
# План остался в тултипе строки — там он и место.
extends Node

# Сцена карточки одного ресурса (см. файл сцены — там же список узлов,
# к которым обращается этот скрипт).
const CARD_SCENE = preload("res://scenes/TradeResourceCard.tscn")
# Источник констант оформления (QUALITY_MARKER_COLOR) — тот же акцент
# интерфейса, что на вкладке «Ресурсы».
const UiHelpers = preload("res://scripts/ui_helpers.gd")

var internal_list: Node
var ui_helpers: Node
# WorkerManager прокидывается из main_map через city_ui.set_worker_manager.
var worker_manager: Node = null

# Кэш текущих данных карточек: display_key -> { узлы карточки, строка данных }.
var cards: Dictionary = {}
# Набор отображаемых ключей: подпись для сравнения «состав списка не изменился».
var _signature: String = ""
# Активный тултип разбора качества — для обновления в реальном времени.
var _quality_key: String = ""
# Узел с тултипом, на который сейчас наведён курсор: его текст не трогаем
# (см. _apply_tooltip). Отдельное поле, а не проверка узла: у Control в
# Godot 4 метода is_hovered() нет, а наведение честнее всего отслеживать
# сигналами mouse_entered/mouse_exited.
var _hovered_tip: Control = null

# Состояния цвета/текста карточки.
const COLOR_TITLE := Color(1, 1, 1, 1)
const COLOR_CAPTION := Color(0.75, 0.75, 0.75, 1)
const COLOR_PRICE := Color(1.0, 0.507, 0.0, 1)
const COLOR_CONSUMPTION := Color(0.9, 0.3, 0.3, 1)
# Доход — деньги, поэтому золотой, как цена (ui_helpers.PRICE_TEXT_COLOR):
# игрок видит «цена × расход = вот эти деньги» одним цветом.
const COLOR_INCOME := Color(1.0, 0.807, 0.2, 1)
const COLOR_DISABLED := Color(0.62, 0.62, 0.62, 1)

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
    _hovered_tip = null
    _signature = ""

    var data: Dictionary = _collect_data()
    # Сортировка по названию — список читаем и предсказуем между тиками.
    var keys: Array = data.keys()
    keys.sort_custom(func(a, b): return str(data[a].get("name", a)) < str(data[b].get("name", b)))
    for key in keys:
        _create_card(str(key), data[key])
    # Подпись ставится ПОСЛЕ сборки и той же функцией, что проверка в
    # update_values. Раньше refresh() склеивал подпись из отсортированных
    # ключей, а update_values() сравнивал её с подписью в порядке вставки
    # словаря — подписи не совпадали никогда, и КАЖДЫЙ ТИК список карточек
    # пересоздавался целиком. Вместе с карточками погибал открытый тултип и
    # мигали все числа.
    _signature = _signature_of(data)
    if internal_list.get_child_count() == 0:
        var empty := Label.new()
        empty.text = tr("Nobody consumes anything yet")
        empty.add_theme_color_override("font_color", COLOR_CAPTION)
        internal_list.add_child(empty)

# Лёгкое обновление: меняются только тексты и состояния кнопок, узлы
# карточек переиспользуются (иначе мигали бы тултипы под курсором).
func update_values() -> void:
    if internal_list == null or not is_instance_valid(internal_list):
        return
    var data: Dictionary = _collect_data()
    if _signature_of(data) != _signature:
        # Состав списка изменился — нужна полная пересборка.
        refresh()
        return
    for key in cards:
        if data.has(key):
            _update_card(cards[key], data[key])

# Подпись состава списка карточек. Собирается из ОТСОРТИРОВАННЫХ ключей, и
# поэтому не зависит от порядка обхода словаря: иначе refresh() и
# update_values() считали бы разные подписи одного и того же состава.
func _signature_of(data: Dictionary) -> String:
    var keys: Array = data.keys()
    keys.sort()
    return ";".join(PackedStringArray(keys))

# Присваивает текст Label, только если он ИЗМЕНЯЕТСЯ. Побочный эффект
# присваивания одного и того же текста каждый раз — лишнее перерисовывание,
# а для RichTextLabel (метка качества) ещё и сброс позиции текста.
func _set_text(node: Label, text: String) -> void:
    if node != null and is_instance_valid(node) and node.text != text:
        node.text = text

# Присваивает тултип, только если он ИЗМЕНЯЕТСЯ. Это ключевое правило для
# тултипов: Godot сбрасывает показ тултипа при ЛЮБОМ присваивании
# tooltip_text, даже если строка не поменялась. Без проверки тултип,
# открытый наведением, закрывался бы при каждом обновлении экрана.
func _set_tooltip(node: Control, text: String) -> void:
    if node != null and is_instance_valid(node) and node.tooltip_text != text:
        node.tooltip_text = text

# Кладёт тултип в узел, но НЕ трогает узел под курсором. Присваивание
# tooltip_text снимает уже показанное окно (Control.set_tooltip удаляет
# активный тултип), поэтому наведённый узел пропускаем: игрок держит курсор,
# ждёт обновления и не должен видеть, как окно мигает. Уехав курсором, узел
# получит свежий текст при следующем обновлении.
func _apply_tooltip(node: Control, text: String) -> void:
    if node == null or not is_instance_valid(node) or node == _hovered_tip:
        return
    _set_tooltip(node, text)

# Курсор наведён на узел с тултипом. Сигналы приходят только при
# mouse_filter != IGNORE, то есть ровно у тех узлов, которым мы и хотим
# показывать тултип.
func _on_tip_enter(node: Control) -> void:
    _hovered_tip = node

func _on_tip_exit(node: Control) -> void:
    if _hovered_tip == node:
        _hovered_tip = null

# Данные всех карточек из worker_manager + склада. Формируется заново при
# каждом обновлении: он дешёвый (перебор профессий) и всегда актуален.
func _collect_data() -> Dictionary:
    var result: Dictionary = {}
    if worker_manager == null or not is_instance_valid(worker_manager) \
            or not worker_manager.has_method("get_population_consumption_map"):
        return result
    result = worker_manager.get_population_consumption_map()
    # План дохода по карточкам — уходит в тултип строки «Доход» («сколько
    # принесло бы, если бы склад не кончился»). Оба источника считаются ОДИН
    # раз на всех: методы внутри обходят план потребления, а вызывать их в
    # цикле по карточкам — лишняя работа.
    var income_map: Dictionary = {}
    if worker_manager.has_method("get_population_income_map"):
        income_map = worker_manager.get_population_income_map()
    # Факт дохода — то, что рынок реально принёс за окно. Именно это число
    # стоит в строке «Доход» и в строке «Казна» верхней полосы.
    var actual_income_map: Dictionary = {}
    if worker_manager.has_method("get_actual_market_income_map"):
        actual_income_map = worker_manager.get_actual_market_income_map()
    # Факт за окно отображения (CityData.get_market_consumption_per_sec) —
    # стабильная величина вместо тикового счётчика, который гаснет в
    # reset_counters() и на интервале 2–5 сек почти всегда оказывался пустым.
    var fact_map: Dictionary = CityData.get_market_consumption_per_sec()
    for key in result:
        result[key]["stock"] = _collect_stock(result[key].get("members", []))
        result[key]["price_text"] = _format_price(result[key])
        result[key]["planned_income"] = income_map.get(str(key), {})
        result[key]["actual_income"] = actual_income_map.get(str(key), {})
        result[key]["actual"] = _collect_actual(result[key].get("members", []), fact_map)
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

# Фактическое потребление на внутреннем рынке за окно отображения, ед./сек:
# сумма по членам группы. fact_map — общий снимок
# (CityData.get_market_consumption_per_sec), посчитанный один раз на все
# карточки. Тиковый CityData.market_consumption_rates здесь больше не
# читается: он живёт ровно один тик и на интервале отображения > 1 сек
# успевает обнулиться.
func _collect_actual(members: Array, fact_map: Dictionary) -> float:
    var total := 0.0
    for pid in members:
        total += float(fact_map.get(str(pid), 0.0))
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
# (GameData.format_quality_share_text). Звёзда-маркер красится тем же
# акцентным цветом (ui_helpers.QUALITY_MARKER_COLOR): белый маркер читался
# как «уровень качества», хотя это всего лишь признак «разбивка есть».
func _format_quality(stock: Dictionary) -> String:
    var text := GameData.format_quality_share_text(stock.get("quality", {}))
    if text == "":
        return ""
    return "[color=#%s]★[/color] %s" % [
        UiHelpers.QUALITY_MARKER_COLOR.to_html(false), text]

# Норма потребления на ОДНОГО покупателя в исходном виде из
# data/consumption.json: «10 ед./1 сек», «10 ед./10 сек». Показывать
# пересчитанное «210/сек» нельзя — это уже сумма по городу, а игрок
# настраивает потребление в данных на ОДНОГО жителя: именно эти числа он
# и должен видеть, чтобы понимать, что произойдёт при росте населения.
func _format_unit_rate(amount: int, interval: float) -> String:
    if amount <= 0:
        return tr("0/sec")
    if interval <= 0.0:
        return tr("%d units/sec") % amount
    if is_equal_approx(interval, round(interval)):
        return tr("%d units/%d sec") % [amount, int(round(interval))]
    return tr("%d units/%.1f sec") % [amount, interval]

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
        "checkbox": card.get_node("Layout/Header/TradeCheckBox"),
        "stock": card.get_node("Layout/StockRow/StockValue"),
        "quality": card.get_node("Layout/StockRow/QualityLabel"),
        "price": card.get_node("Layout/DetailRow/PriceValue"),
        "consumers": card.get_node("Layout/DetailRow/ConsumersValue"),
        "consumption": card.get_node("Layout/DetailRow/ConsumptionValue"),
        "income": card.get_node("Layout/IncomeRow/IncomeValue"),
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
    # Тултип на иконке объясняет, ЧЕМ нарисована группа: без него игрок
    # видит у «Алкоголя» кувшин и не понимает, откуда он взялся.
    if texture != null:
        _set_icon_tooltip(icon, row, display_key)
    # Наведение на разбивку качества — тот же тултип, что на вкладке
    # «Ресурсы» (ui_helpers.show_quality_tooltip). Штатный tooltip_text у
    # метки НЕ ставится: рядом с этим тултипом он давал второй, пустой
    # («Разбивка склада по качеству»), и игрок видел два окна сразу.
    var quality: RichTextLabel = ctx["quality"]
    quality.mouse_entered.connect(_on_quality_hover.bind(display_key))
    quality.mouse_exited.connect(_on_quality_exit)
    # Тултипы цены, покупателей, расхода и дохода — штатные (их оформляет
    # теме в theme/) и заполняются в _update_card. Отслеживаем наведение
    # только ради _hovered_tip: показанное окно нельзя трогать. У этих
    # четырёх узлов в сцене обязан стоять mouse_filter = 0 (STOP) —
    # иначе сигналы наведения не придут (см. шапку файла).
    for node_key in ["price", "consumers", "consumption", "income"]:
     var tip_node: Control = ctx[node_key]
     tip_node.mouse_entered.connect(_on_tip_enter.bind(tip_node))
     tip_node.mouse_exited.connect(_on_tip_exit.bind(tip_node))
    # Приоритет потребления — тот же цикл, что у кнопки качества здания.
    var priority_btn: Button = ctx["priority_btn"]
    priority_btn.pressed.connect(_on_priority_pressed.bind(display_key))
    # Тумблер разрешения потребления на внутреннем рынке.
    var checkbox: CheckBox = ctx["checkbox"]
    checkbox.toggled.connect(_on_checkbox_toggled.bind(display_key))
    _update_card(ctx, row)

# Тултип иконки: для группы объясняет источник картинки, для одиночного
# ресурса — просто имя файла. Источник нужен, чтобы отличить «свою иконку
# группы» от «взяли у первого товара, у которого иконка есть».
func _set_icon_tooltip(icon: TextureRect, row: Dictionary, display_key: String) -> void:
    var icon_file := str(row.get("icon", ""))
    if not bool(row.get("is_group", false)):
        _set_tooltip(icon, tr("Icon: %s") % icon_file)
        return
    var info: Dictionary = GameData.get_product_group_icon_info(display_key)
    if bool(info.get("own", false)):
        _set_tooltip(icon, tr("Icon of group \"%s\": %s (set in data/product_groups.json)") % [
            _row_title(row, display_key), icon_file])
    else:
        var source_pid := str(info.get("source_pid", ""))
        var source_name := str(GameData.products.get(source_pid, {}).get("name", source_pid))
        _set_tooltip(icon, tr("Icon of group \"%s\" taken from goods \"%s\"") % [
            _row_title(row, display_key), source_name])

# Обновляет значения существующей карточки (без пересоздания узлов).
func _update_card(ctx: Dictionary, row: Dictionary) -> void:
    var display_key: String = str(ctx["key"])
    var enabled := bool(row.get("enabled", true))
    var title: String = str(row.get("name", display_key))
    if bool(row.get("is_group", false)):
        title += tr(" (group)")
    var name_label: Label = ctx["name"]
    _set_text(name_label, title)
    var stock: Dictionary = row.get("stock", {})
    var stock_label: Label = ctx["stock"]
    _set_text(stock_label, str(int(stock.get("total", 0))))
    var quality: RichTextLabel = ctx["quality"]
    var quality_text := _format_quality(stock)
    quality.text = quality_text
    quality.visible = quality_text != ""
    var price: Label = ctx["price"]
    _set_text(price, str(row.get("price_text", "—")))
    var consumers: Label = ctx["consumers"]
    _set_text(consumers, str(int(row.get("consumers_total", 0))))
    # Расход на 1: норма одного покупателя прямо из data/consumption.json
    # («10 ед./1 сек»), а не сумма по городу. У запрещённого ресурса расхода
    # нет вовсе.
    var consumption: Label = ctx["consumption"]
    if not enabled:
        _set_text(consumption, "—")
    else:
        _set_text(consumption, _format_unit_rate(
            int(row.get("per_consumer_amount", 0)),
            float(row.get("per_consumer_interval", 0.0))))
    # Доход: ФАКТ за окно отображения — столько монет в секунду внутренний
    # рынок реально принёс казне. Тот же источник данных, что у строки
    # «Казна: N [+X≈]» в верхней полосе, поэтому сумма строк «Доход» равна
    # фактической рыночной прибыли казны. План «весь спрос × цена» в строку
    # не годится: складом он не ограничен, и при полупустом складе карточка
    # показывала 2730 монет/сек, которых в казне никогда не было. План остался
    # в тултипе строки — там он и место.
    var income: Label = ctx["income"]
    var fact_income: Dictionary = row.get("actual_income", {})
    if not enabled:
        _set_text(income, "—")
    else:
        _set_text(income, tr("%s/sec") % _format_rate(float(fact_income.get("coins_per_sec", 0.0))))
    # Состояние приглушается у запрещённого ресурса: он остаётся в списке
    # (иначе его нельзя было бы включить обратно), но выглядит отключённым.
    var card: PanelContainer = ctx["card"]
    card.modulate = Color(1, 1, 1, 1) if enabled else COLOR_DISABLED
    name_label.add_theme_color_override("font_color", COLOR_TITLE if enabled else COLOR_DISABLED)
    price.add_theme_color_override("font_color", COLOR_PRICE if enabled else COLOR_DISABLED)
    consumption.add_theme_color_override("font_color", COLOR_CONSUMPTION if enabled else COLOR_DISABLED)
    income.add_theme_color_override("font_color", COLOR_INCOME if enabled else COLOR_DISABLED)
    _update_priority_button(ctx["priority_btn"], str(row.get("priority", "best")))
    _update_toggle(ctx["checkbox"], enabled)
    # Тултипы — из тех же данных того же окна, что и сами числа, поэтому
    # карточка и её тултип не могут описывать разные моменты времени.
    _apply_tooltip(price, _price_tooltip_text(row))
    _apply_tooltip(consumers, _consumers_tooltip_text(row))
    _apply_tooltip(consumption, _consumption_tooltip_text(row))
    _apply_tooltip(income, _income_tooltip_text(row))

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
    # Через _set_tooltip: присваивание tooltip_text сбрасывает открытый
    # тултип, даже если строка не изменилась.
    _set_tooltip(button, tr("Consumption priority: %s (click to switch)") \
        % GameData.get_quality_priority_name(priority))

# Синхронизирует тумблер с состоянием рынка. Проверка на изменение значения
# обязательна: программная установка button_pressed вызывает сигнал toggled
# и зациклила бы правку, а без проверки Godot ещё и перерисовывал бы кнопку
# на каждом обновлении экрана.
func _update_toggle(checkbox: CheckBox, enabled: bool) -> void:
    if checkbox != null and is_instance_valid(checkbox) \
            and checkbox.button_pressed != enabled:
        checkbox.button_pressed = enabled

# --- ТУМБЛЕР РАЗРЕШЕНИЯ ПОТРЕБЛЕНИЯ ---
# Один CheckBox (раньше были две кнопки-варианта: ColorRect и CheckBox).
# Переключение пишет состояние в CityData и сразу обновляет карточку.

# Клик по чекбоксу.
func _on_checkbox_toggled(pressed: bool, display_key: String) -> void:
    _set_enabled(display_key, pressed)

# Общее переключение: пишем состояние в CityData и обновляем карточку.
func _set_enabled(display_key: String, enabled: bool) -> void:
    CityData.set_market_consumption_enabled(display_key, enabled)
    if not cards.has(display_key):
        return
    var ctx: Dictionary = cards[display_key]
    _update_toggle(ctx["checkbox"], enabled)
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
    _show_message(tr("%s: consumption priority — %s") % [
        _row_title(row, display_key), GameData.get_quality_priority_name(priority)])

# Заголовок карточки для сообщений (с пометкой группы, как в самой карточке).
func _row_title(row: Dictionary, display_key: String) -> String:
    var title := str(row.get("name", display_key))
    if bool(row.get("is_group", false)):
        title += tr(" (group)")
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
# Цены всех уровней одной строкой: «8 / 10 / 14 / 18» (от худшего к
# лучшему). Для членов группы, которых на складе нет, лестница в развёрнутом
# виде не нужна — хватает самой шкалы, чтобы увидеть разброс цены.
func _price_ladder_inline(member: String) -> String:
    var parts: Array = []
    for qid in GameData.get_quality_levels():
        var breakdown := GameData.get_price_breakdown_for_quality(member, str(qid))
        var total := int(breakdown.get("total", 0))
        if total > 0:
            parts.append(str(total))
    return " / ".join(parts)

# Цена: откуда берётся число и почему у группы диапазон.
# Раньше тултип показывал только лестницу цен по уровням, которые ЛЕЖАТ на
# складе, из-за чего на пустом складе он был вовсе пустым, а формула цены
# оставалась загадкой. Теперь сначала идёт объяснение, потом лестница по ВСЕМ
# уровням шкалы с пометкой количества на складе, и отдельной строкой — что
# наличие товара цену не меняет (цена за единицу ≠ выручка).
func _price_tooltip_text(row: Dictionary) -> String:
    if row.is_empty():
        return ""
    var lines: Array = []
    var market_mult := float(GameData.game_balance.get("internal_market_price_multiplier", 1.0))
    lines.append(tr("Price = base price of the goods ×%.2f (market) × quality multiplier") % market_mult)
    lines.append("")
    for pid in row.get("members", []):
        var member := str(pid)
        var member_name: String = str(GameData.products.get(member, {}).get("name", member))
        var base_price: float = GameData.get_base_price(member)
        if base_price <= 0.0:
            lines.append(tr("%s: goods without a price") % member_name)
            continue
        var stock_detail: Dictionary = CityData.get_quality_breakdown(member)
        var stock_total := 0
        for qid in stock_detail:
            stock_total += int(stock_detail[qid])
        # Полная лестница — только для товара, который ЛЕЖИТ на складе: он
        # единственный реально продаётся. Остальные члены группы одной
        # строкой. Без этого тултип группы из 13 товаров растягивался на
        # пол-экрана, и нужная строка тонула в общем списке.
        if stock_total <= 0:
            lines.append(tr("%s (base %d): %s") % [
                member_name, int(round(base_price)), _price_ladder_inline(member)])
            continue
        lines.append(tr("%s (base %d):") % [member_name, int(round(base_price))])
        for qid in GameData.get_quality_levels():
            var tail := GameData.format_quality_price_tail(member, str(qid))
            if tail == "":
                continue
            var stars := GameData.get_quality_stars(str(qid))
            var in_stock := int(stock_detail.get(str(qid), 0))
            # Количество на складе дописывается только когда уровень реально
            # лежит: иначе каждая строка лестницы несла бы «0» и тултип
            # превращался бы в таблицу нулей.
            var suffix := tr(" — in storage: %d") % in_stock if in_stock > 0 else ""
            lines.append("  %s%s%s" % [stars, tail, suffix])
    lines.append("")
    if bool(row.get("is_group", false)):
        lines.append(tr("A range is shown because the goods in the group have different base prices."))
    lines.append(tr("Price per unit: having it in storage does not change it. Storage affects income (the \"Income\" row)."))
    return "\n".join(lines)

# Покупатели: кто именно покупает ресурс и в каком количестве.
# Формат «Рыбак: 1», «Все жители: 21» — то, что игрок ищет, наводя мышь на
# «Покупателей: N»: не скорость потребления, а СОСТАВ покупателей. Имена
# берутся из data/professions.json, поэтому псевдо-профессия «Все жители»
# выглядит так же, как в остальном интерфейсе.
func _consumers_tooltip_text(row: Dictionary) -> String:
    if row.is_empty():
        return ""
    var lines: Array = [tr("Buyers of the resource:")]
    var sources: Dictionary = row.get("sources", {})
    var entries: Array = []
    for source_id in sources:
        var entry: Dictionary = sources[source_id]
        entries.append({"name": GameData.get_source_display_name(str(source_id)), "count": int(entry.get("count", 0))})
    # По убыванию числа покупателей: главный покупатель идёт первой строкой.
    entries.sort_custom(func(a, b): return int(a["count"]) > int(b["count"]))
    for item in entries:
        lines.append("%s: %d" % [str(item["name"]), int(item["count"])])
    if lines.size() <= 1:
        return ""
    return "\n".join(lines)

# Расход: норма на одного покупателя + во сколько раз она умножается на
# реальное число покупателей + факт за окно отображения.
func _consumption_tooltip_text(row: Dictionary) -> String:
    if row.is_empty():
        return ""
    var lines: Array = [tr("Expenses by buyers:")]
    var sources: Dictionary = row.get("sources", {})
    for source_id in sources:
        var entry: Dictionary = sources[source_id]
        var count := int(entry.get("count", 0))
        var amount := int(entry.get("unit_amount", 0))
        var interval := float(entry.get("interval", 0))
        if amount <= 0 or count <= 0:
            continue
        # «норма × число покупателей = всего»: так видно и своё число из
        # данных, и итог по городу, без двух одинаковых подряд «10 ед./1 сек».
        lines.append(tr("%s: %d units every %s per person × %d = %d per cycle") % [
            GameData.get_source_display_name(str(source_id)), amount,
            (tr("%d sec") % int(round(interval))) if interval > 0.0 else tr("sec"),
            count, amount * count])
    var plan_per_sec := float(row.get("per_sec", 0.0))
    if plan_per_sec > 0.0:
        lines.append("")
        lines.append(tr("City total (plan): %s units/sec") % _format_rate(plan_per_sec))
    var fact := float(row.get("actual", 0.0))
    if fact > 0.0:
        lines.append(tr("Actual over the window: %s units/sec — that is what was really bought") % _format_rate(fact))
    if lines.size() <= 1:
        return ""
    return "\n".join(lines)

# Доход в казну. Разбивка на ДВА числа, потому что они отвечают на разные
# вопросы, и раньше их можно было спутать:
#   * ФАКТ — то, что рынок принёс за окно отображения. Именно это стоит в
#     строке «Доход» и в строке «Казна: N [+X≈]», и именно оно попадает в
#     казну по-настоящему.
#   * ПЛАН — «сколько принесло бы, если бы весь спрос удалось продать».
#     Он складом не ограничен: 21 житель × 10 ед./сек × 13 монет давали
#     2730 монет/сек, хотя на складе лежало 10 единиц. Как характеристика
#     потенциала спроса полезен, как «доход» — обман.
func _income_tooltip_text(row: Dictionary) -> String:
    if row.is_empty():
        return ""
    if not bool(row.get("enabled", true)):
        return tr("Consumption on the domestic market is disabled — no income.")
    var fact_row: Dictionary = row.get("actual_income", {})
    var plan_row: Dictionary = row.get("planned_income", {})
    var fact := float(fact_row.get("coins_per_sec", 0.0))
    var plan := float(plan_row.get("coins_per_sec", 0.0))
    var per_sec := float(row.get("per_sec", 0.0))
    if fact <= 0.0 and plan <= 0.0 and per_sec <= 0.0:
        return ""
    # Длина окна в первой строке: по ней игрок может сверить факт со строкой
    # «Казна: N [+X≈]» — она тоже считается за это окно.
    var lines: Array = [tr("Income to the treasury over %s sec: %s coins/sec") % [
        _format_rate(CityData.treasury_window_length_sec), _format_rate(fact)]]
    if plan > 0.0:
        lines.append(tr("Plan: demand %s units/sec × price %s = %s coins/sec") % [
            _format_rate(per_sec), str(row.get("price_text", "—")), _format_rate(plan)])
    # Нулевой факт при ненулевом спросе — это не ошибка, а отсутствие товара:
    # продавать нечего. Без этой строки игрок видит «0» и думает, что сломан
    # расчёт.
    if fact <= 0.0 and per_sec > 0.0:
        lines.append(tr("As long as the group has no goods in storage there is nothing to buy — no income."))
    elif fact > 0.0 and plan > fact * 1.5:
        lines.append(tr("Actual is below plan: buyers want more than what is in storage."))
    var by_source: Dictionary = fact_row.get("by_source", {})
    if by_source.size() > 0:
        lines.append("")
        lines.append(tr("By buyers (actual):"))
        var names: Array = by_source.keys()
        names.sort()
        for source_name in names:
            lines.append(tr("%s: %s coins/sec") % [
                str(source_name), _format_rate(float(by_source[source_name]))])
    return "\n".join(lines)

# Обновляет открытый тултип разбора качества на свежие данные. Вызывается из
# city_ui при смене эпохи отображения ресурсов, пока курсор на метке:
# тултип остаётся на месте (координаты берутся у мыши) и не мигает, но
# показывает актуальный склад.
func refresh_open_tooltip() -> void:
    if _quality_key.is_empty() or ui_helpers == null or not is_instance_valid(ui_helpers):
        return
    if ui_helpers.quality_tooltip_panel == null or not ui_helpers.quality_tooltip_panel.visible:
        return
    var row: Dictionary = _row_data(_quality_key)
    if row.is_empty():
        return
    var quality: Dictionary = row.get("stock", {}).get("quality", {})
    if quality.is_empty():
        return
    ui_helpers.show_quality_tooltip(
        get_viewport().get_mouse_position(),
        _row_title(row, _quality_key), quality)

# Строка данных карточки по ключу (или пустой словарь, если карточки нет).
func _row_data(display_key: String) -> Dictionary:
    return _collect_data().get(display_key, {})

# Сообщение в нижнюю панель города (ui_helpers.set_message).
func _show_message(text: String) -> void:
    if ui_helpers != null and is_instance_valid(ui_helpers):
        ui_helpers.set_message(text)

# --- ИКОНКИ ---
# Иконки берутся из общего реестра IconRegistry (автозагрузка): индекс имён
# файлов и кэш текстур там общие на весь проект, поэтому вкладке «Торговля»
# не нужен собственный обход res://icons и свой кэш.

func _get_icon_texture(icon_file: String) -> Texture2D:
    return IconRegistry.get_texture(icon_file)
