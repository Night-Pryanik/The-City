# town_ui.gd
# Интерфейс городка (мелкого поселения) — окно торговли.
# Открывается из панели управления (кнопка действия на гексе городка)
# или двойным кликом по гексу городка на карте (см. InputHandler).
#
# Начальный этап: окно с заголовком (название городка) и двумя колонками
# «Покупка» и «Продажа». Окно не на весь экран — фиксированная раскладка
# задана прямо в сцене TownUI.tscn, без кода во время рантайма.
#
# Списки лежат внутри ScrollContainer (см. BuyScroll/SellScroll в сцене):
# пул продажи у городка — это десятки строк, и без прокрутки они вылезали
# за нижний край окна прямо на карту.
extends Control

signal closed()

# Минимальная высота строки списка. Равна высоте иконки (28 px): подпись с
# переносом строки не должна прижимать иконку и следующую строку.
const ROW_HEIGHT := 28

@onready var window_panel = $WindowPanel
@onready var title_label = $WindowPanel/TitleLabel
@onready var status_label = $WindowPanel/StatusLabel
@onready var close_button = $WindowPanel/CloseButton
@onready var buy_scroll = $WindowPanel/ColumnsHBox/BuyColumn/BuyScroll
@onready var sell_scroll = $WindowPanel/ColumnsHBox/SellColumn/SellScroll
@onready var buy_list = $WindowPanel/ColumnsHBox/BuyColumn/BuyScroll/BuyList
@onready var sell_list = $WindowPanel/ColumnsHBox/SellColumn/SellScroll/SellList
# Иконки ресурсов берутся из общего реестра IconRegistry (автозагрузка):
# индекс строится один раз за игру, а не в каждом открытии окна.
# Текущий городок (запись из town_manager.towns). null — окно закрыто.
var _town = null
# Доступна ли торговля с этим городком (town_manager.is_trade_available).
# Пока сама торговля не реализована, это только строка-статус под названием:
# окно открывается и без дороги — видно, что у городка есть на продажу и
# на покупку. Когда появится реальная торговля, этот флаг начнёт решать,
# можно ли покупать и продавать (см. town_manager.is_trade_available).
var _trade_available := true
func _ready():
    if close_button:
        close_button.pressed.connect(close_town)

# Открывает окно интерфейса для городка.
# town — запись городка из town_manager.towns (поля row, col, name, ...).
# trade_available — доступна ли торговля с ним (по умолчанию true: окно
# открывается всегда, см. поле _trade_available).
func open_town(town: Dictionary, trade_available: bool = true):
    _town = town
    _trade_available = trade_available
    _refresh()
    show()

# Обновляет содержимое окна по текущему городку.
func _refresh():
    if _town == null:
        return
    title_label.text = str(_town.get("name", tr("Town")))
    if status_label:
        # Статус торговли — пока только подпись. Пустая строка при доступной
        # торговле: «всё в порядке, ничего сообщать не нужно».
        status_label.text = "" if _trade_available \
                else tr("Trade unavailable: there is no road from the city to this town")
        status_label.visible = not status_label.text.is_empty()
    _fill_resource_list(buy_list, _town.get("buy_pool", []), tr("The town buys nothing"))
    _fill_resource_list(sell_list, _town.get("sell_pool", []), tr("No resources in the influence ring"))

# Заполняет колонку одной строкой на каждый ресурс торгового пула.
# Пул продажи содержит id ресурсов, поэтому имя берём из общего справочника.
#
# Строки с одинаковым отображаемым именем показываются один раз. Основная
# защита живёт в данных: пул строится из ПРОДУКЦИИ ресурсов (см.
# TownEconomy.collect_base_resources), поэтому «две пшеницы» из-за поля и
# зерна там уже невозможны. Но в данных есть ровно одна пара, где разные id
# называются одинаково: papyrus_plant (выращивается на papyrus_field) и
# papyrus (крафтится из него) оба зовутся «Papyrus» — и оба могут попасть в
# пул одного городка. Игроку дважды показать «Papyrus» нельзя.
func _fill_resource_list(container: VBoxContainer, pool, empty_text: String) -> void:
    if container == null:
        return
    for child in container.get_children():
        child.queue_free()
    if pool == null or pool.is_empty():
        var empty_label := Label.new()
        empty_label.text = empty_text
        empty_label.modulate = Color(0.65, 0.65, 0.65)
        container.add_child(empty_label)
        return
    var shown_names: Dictionary = {}
    for resource_id in pool:
        if resource_id == null:
            continue
        var id := str(resource_id).strip_edges()
        if id.is_empty() or id == "<null>":
            continue
        var display_name := _get_resource_display_name(id)
        if shown_names.has(display_name):
            continue
        shown_names[display_name] = true
        var resource_row := HBoxContainer.new()
        resource_row.add_theme_constant_override("separation", 6)
        # Строка не должна схлопываться, даже если подпись не влезла в одну
        # строку и перенеслась: без минимума по высоте строки наезжали друг на
        # друга (см. autowrap у resource_label ниже).
        resource_row.custom_minimum_size = Vector2(0, ROW_HEIGHT)
        var icon_name := _get_resource_icon_name(id)
        var icon_tex := IconRegistry.get_texture(icon_name)
        if icon_tex != null:
            var resource_icon := TextureRect.new()
            resource_icon.texture = icon_tex
            resource_icon.custom_minimum_size = Vector2(28, 28)
            resource_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
            resource_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
            resource_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
            resource_row.add_child(resource_icon)

        var resource_label := Label.new()
        resource_label.text = display_name
        resource_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        resource_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        resource_row.add_child(resource_label)
        container.add_child(resource_row)

func _get_resource_icon_name(resource_id: String) -> String:
    var resource_data := GameData.get_resource_data(resource_id)
    return str(resource_data.get("icon", ""))

func _get_resource_display_name(resource_id: String) -> String:
    var resource_data := GameData.get_resource_data(resource_id)
    var display_name := str(resource_data.get("name", ""))
    if not display_name.is_empty():
        return display_name
    # Защита для открытия окна в момент, когда общий загрузчик ещё не успел
    # заполнить GameData: всё равно показываем не ID, а доступное имя.
    var raw_data: Dictionary = GameData.raw_resources.get(resource_id, {})
    if not raw_data.is_empty():
        return str(raw_data.get("name", resource_id))
    var product_data: Dictionary = GameData.products.get(resource_id, {})
    return str(product_data.get("name", resource_id))

# Закрывает окно интерфейса городка. Эмитит closed — main_map вернёт
# HUD и панель управления (см. main_map._on_town_ui_close).
# Отображаемые имена строк, которые сейчас показаны в контейнере.
# Служебный доступ для тестов: проверка «двух одинаковых названий в списке»
# читает именно то, что видит игрок (см. tests/test_town_economy.gd).
func _visible_row_names(container: VBoxContainer) -> Array:
    var names: Array = []
    if container == null:
        return names
    for child in container.get_children():
        if child is HBoxContainer:
            for node in child.get_children():
                if node is Label:
                    names.append(node.text)
                    break
    return names

func close_town():
    if not visible:
        return
    _town = null
    hide()
    emit_signal("closed")