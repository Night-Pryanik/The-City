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

# Текущий городок (запись из town_manager.towns). null — окно закрыто.
var _town = null

func _ready():
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
    # Колонки «Покупка» / «Продажа» пока пустые: наполнение (из полей
    # buy_pool / sell_pool городка) появится на следующих этапах.

# Закрывает окно интерфейса городка. Эмитит closed — main_map вернёт
# HUD и панель управления (см. main_map._on_town_ui_close).
func close_town():
    if not visible:
        return
    _town = null
    hide()
    emit_signal("closed")