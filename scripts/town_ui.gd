# town_ui.gd
# Интерфейс городка (мелкого поселения) — окно торговли.
# Открывается из панели управления (кнопка действия на гексе городка)
# или двойным кликом по гексу городка на карте (см. InputHandler).
#
# Начальный этап: окно с заголовком (название городка) и двумя пустыми
# колонками «Покупка» и «Продажа». Окно не на весь экран — фиксированная
# раскладка задана прямо в сцене TownUI.tscn, без кода во время рантайма.
extends Control

signal closed()

@onready var window_panel = $WindowPanel
@onready var title_label = $WindowPanel/TitleLabel
@onready var close_button = $WindowPanel/CloseButton
@onready var buy_list = $WindowPanel/ColumnsHBox/BuyColumn/BuyList
@onready var sell_list = $WindowPanel/ColumnsHBox/SellColumn/SellList
# Индекс иконок строится рекурсивно: ресурсы распределены по подпапкам
# res://icons/ (как и в окне технологий и вкладке «Ресурсы»).
var icon_paths: Dictionary = {}
# Текущий городок (запись из town_manager.towns). null — окно закрыто.
var _town = null
func _ready():
    _build_icon_index()
    if close_button:
        close_button.pressed.connect(close_town)

# Открывает окно интерфейса для городка.
# town — запись городка из town_manager.towns (поля row, col, name, ...).
func open_town(town: Dictionary):
    _town = town
    _refresh()
    show()

# Обновляет содержимое окна по текущему городку.
func _refresh():
    if _town == null:
        return
    title_label.text = str(_town.get("name", "Городок"))
    _fill_resource_list(buy_list, _town.get("buy_pool", []), "Городок ничего не покупает")
    _fill_resource_list(sell_list, _town.get("sell_pool", []), "В кольце влияния нет ресурсов")

# Заполняет колонку одной строкой на каждый ресурс торгового пула.
# Пул продажи содержит id ресурсов, поэтому имя берём из общего справочника.
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
    for resource_id in pool:
        if resource_id == null:
            continue
        var id := str(resource_id).strip_edges()
        if id.is_empty() or id == "<null>":
            continue
        var resource_row := HBoxContainer.new()
        resource_row.add_theme_constant_override("separation", 6)
        var icon_name := _get_resource_icon_name(id)
        if icon_paths.has(icon_name):
            var resource_icon := TextureRect.new()
            resource_icon.texture = load(icon_paths[icon_name])
            resource_icon.custom_minimum_size = Vector2(28, 28)
            resource_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
            resource_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
            resource_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
            resource_row.add_child(resource_icon)

        var resource_label := Label.new()
        resource_label.text = _get_resource_display_name(id)
        resource_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        resource_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        resource_row.add_child(resource_label)
        container.add_child(resource_row)

func _get_resource_icon_name(resource_id: String) -> String:
    var resource_data := GameData.get_resource_data(resource_id)
    return str(resource_data.get("icon", ""))

# Собирает пути всех файлов в res://icons/ и его подпапках.
# В данных ресурсов хранится только имя файла, поэтому индексируется basename.
func _build_icon_index() -> void:
    icon_paths.clear()
    _scan_icon_folder("res://icons")

func _scan_icon_folder(folder_path: String) -> void:
    var dir := DirAccess.open(folder_path)
    if dir == null:
        return
    dir.list_dir_begin()
    var file_name := dir.get_next()
    while not file_name.is_empty():
        if dir.current_is_dir():
            _scan_icon_folder(folder_path.path_join(file_name))
        else:
            icon_paths[file_name] = folder_path.path_join(file_name)
        file_name = dir.get_next()
    dir.list_dir_end()

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
func close_town():
    if not visible:
        return
    _town = null
    hide()
    emit_signal("closed")