# data_problems_window.gd
# Окно со списком проблем в игровых данных (res://data/*.json).
#
# Показывается в главном меню ДО начала партии (см. main_menu.gd), если
# scripts/data_validator.gd нашёл битые перекрёстные ссылки. Задача окна —
# показать автору данных не «что-то сломалось в логе», а конкретную
# проблемную сущность: какого идентификатора не хватает и в каком поле
# на него сослались.
#
# Содержимое собирается кодом (без .tscn) — по образцу tech_popup.gd:
# список проблем может быть любым, а верстка однотипная.
#
# Окно не мешает начать партию: игрок читает список и закрывает его кнопкой
# или Esc, после чего играется как обычно. Пока окно открыто, оно перехватывает
# клики по главному меню (корневой Control с MOUSE_FILTER_STOP накрывает
# экран целиком) — сначала прочитай ошибки, потом жми «Новая игра».
# Данные окно не патчатся — исправлять нужно файлы в папке data.
extends Control

# Константы проверок берём из самого валидатора (preload, а не автозагрузка):
# он не хранит состояния, а окну нужны только заголовки и порядок блоков.
# Так заголовок проверки и её позиция в окне не могут разойтись с
# data_validator.gd — они читаются из одного места.
const DataValidator = preload("res://scripts/data_validator.gd")

# Размер панели под четыре-пять проблем — типичный объём, при котором
# список виден целиком без скролла. Больше — появляется вертикальный
# скроллбар (он и раньше настроен), меньше — лишняя прокрутка на ровно
# половине экрана.
const PANEL_MIN_SIZE := Vector2(840, 680)
const TITLE_COLOR := Color(1.0, 0.55, 0.45)
const GROUP_COLOR := Color(0.6, 1.0, 0.6)
const REF_ID_COLOR := Color(1.0, 0.83, 0.47)
const WHERE_COLOR := Color(0.72, 0.72, 0.72)
# Путь к файлу с проблемой — свой цвет, чтобы взгляд сразу уходил на него,
# а не искал его в сплошном сером тексте второй строки.
const FILE_COLOR := Color(0.55, 0.78, 1.0)

# Заголовок окна и сводка — пересобираются под текущий список проблем.
var summary_label: Label
var problems_box: VBoxContainer

# Узлы, подписи которых меняются при смене языка. Запоминаем их явно:
# автоперевод Control покрывает только то, что задано в СЦЕНЕ, а это окно
# строится кодом, поэтому переподписать их придётся вручную (см.
# _on_locale_changed).
var title_label: Label
var copy_button: Button
var ok_button: Button

# Текущий список проблем: нужен кнопке «Скопировать список». Сама отрисовка
# его не хранит — содержимое лежит в узлах problems_box.
var all_problems: Array = []


func _ready():
    process_mode = Node.PROCESS_MODE_ALWAYS

    # Язык можно переключить прямо в главном меню, и окно проблем на экране
    # в этот момент. Текст в нём собран из данных валидатора на языке
    # запуска, поэтому без пересборки он остался бы на старом. Сами данные не
    # трогаем: проверка не перезапускается, пересобираются только формулировки.
    LocalizationManager.locale_changed.connect(_on_locale_changed)

    # Затемнение фона — окно читается как отдельный экран, а не как
    # всплывающая подсказка поверх меню.
    var dim = ColorRect.new()
    dim.color = Color(0, 0, 0, 0.5)
    dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(dim)

    var center = CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(center)

    var panel = Panel.new()
    panel.custom_minimum_size = PANEL_MIN_SIZE
    panel.add_theme_stylebox_override("panel", _make_panel_style())
    center.add_child(panel)

    var vbox = VBoxContainer.new()
    vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    vbox.offset_left = 24
    vbox.offset_top = 24
    vbox.offset_right = -24
    vbox.offset_bottom = -24
    vbox.add_theme_constant_override("separation", 10)
    panel.add_child(vbox)

    title_label = Label.new()
    title_label.text = tr("Errors in the game data")
    title_label.add_theme_font_size_override("font_size", 22)
    title_label.add_theme_color_override("font_color", TITLE_COLOR)
    vbox.add_child(title_label)

    summary_label = Label.new()
    summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    summary_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
    vbox.add_child(summary_label)

    # Проблем может быть много (одна опечатка в id даёт десятки строк),
    # поэтому список всегда в ScrollContainer, а кнопки прижаты к низу.
    var scroll = ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    vbox.add_child(scroll)

    problems_box = VBoxContainer.new()
    problems_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    problems_box.add_theme_constant_override("separation", 6)
    scroll.add_child(problems_box)

    var buttons = HBoxContainer.new()
    buttons.alignment = BoxContainer.ALIGNMENT_CENTER
    buttons.add_theme_constant_override("separation", 16)
    vbox.add_child(buttons)

    copy_button = Button.new()
    copy_button.text = tr("Copy the list")
    copy_button.custom_minimum_size = Vector2(200, 36)
    copy_button.pressed.connect(_on_copy_pressed)
    buttons.add_child(copy_button)

    ok_button = Button.new()
    ok_button.text = tr("Close")
    ok_button.custom_minimum_size = Vector2(160, 36)
    ok_button.pressed.connect(_on_ok_pressed)
    buttons.add_child(ok_button)

    # _ready() вызывается при add_child(), а список проблем приходит
    # отдельным вызовом — на время между ними окно невидимо.
    hide()


# Показывает список проблем. problems — массив записей из
# DataValidator.validate() (см. шапка scripts/data_validator.gd).
func show_problems(problems: Array):
    all_problems = problems
    _build_content(problems)

    # Оверлей растягивается по родителю. Родителем обязан быть корень
    # окна (get_tree().root), а не Control главного меню: у того якоря
    # заданы не по краям экрана (см. scenes/main_menu.tscn), и оверлей
    # накрыл бы только часть экрана.
    #
    # Именно set_anchors_and_offsets_preset, а не set_anchors_preset:
    # второй меняет якоря, но сохраняет текущий прямоугольник (подгоняет
    # отступы), и оверлей оставался бы размером со свою панель. Первый
    # обнуляет отступы, и PRESET_FULL_RECT растягивает Control по
    # родителю при любом разрешении и режиме растяжения.
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    show()
    move_to_front()


# Пересобирает содержимое окна на новом языке.
#
# Два независимых источника текста, и оба зависят от языка:
#   * формулировки проблем — лежат в самих записях, их пересобирает
#     DataValidator.localize_problems() (проверка при этом не перезапускается);
#   * заголовок, сводка и подписи кнопок — наши собственные, их Godot
#     переводит сам, потому что заданы через tr() на узлах.
func _on_locale_changed(_locale: String) -> void:
    DataValidator.localize_problems(all_problems)
    _build_content(all_problems)
    title_label.text = tr("Errors in the game data")
    copy_button.text = tr("Copy the list")
    ok_button.text = tr("Close")


func _build_content(problems: Array):
    for child in problems_box.get_children():
        problems_box.remove_child(child)
        child.queue_free()

    # Сводка: сколько всего и сколько по видам проверок.
    var counts := _count_by_kind(problems)
    var summary := tr("Found %d problems. Some recipes, resources and technologies may work incorrectly — check the files in the res://data folder.") % problems.size()
    var details: Array = []
    for kind in _kinds_in_display_order(counts.keys()):
        details.append("  • %s — %d" % [_check_title(kind), int(counts[kind])])
    if not details.is_empty():
        summary += "\n" + "\n".join(details)
    summary_label.text = summary

    # Проблемы идут блоками по виду проверки: заголовок блока объясняет,
    # ЧТО сломалось, строки под ним — где именно.
    var current_kind := ""
    for problem in problems:
        var kind := str(problem.get("kind", ""))
        if kind != current_kind:
            current_kind = kind
            var header := Label.new()
            header.text = _check_title(kind)
            header.add_theme_font_size_override("font_size", 16)
            header.add_theme_color_override("font_color", GROUP_COLOR)
            problems_box.add_child(header)
        problems_box.add_child(_make_problem_label(problem))


# Строка одной проблемы: первая строка — чего не хватает (id подсвечен),
# вторая — в каком поле на него сослались.
#
# RichTextLabel, а не Label: разметка собрана BBCode-строками (жирный,
# цвета), а у Label тегов нет — игрок увидел бы «[color=#…]» как обычный
# текст (та же причина, по которой в resources_tab.gd для разбивки по
# качеству взят RichTextLabel).
func _make_problem_label(problem: Dictionary) -> RichTextLabel:
    var ref_id := str(problem.get("ref_id", ""))
    var headline := str(problem.get("headline", ""))
    # Подсвечиваем сам идентификатор, чтобы он читался с одного взгляда.
    var marked_headline := _highlight_id(headline, ref_id)

    var label := RichTextLabel.new()
    label.bbcode_enabled = true
    label.fit_content = true
    label.scroll_active = false
    # Сообщения длинные и должны переноситься. Ширину здесь задаёт
    # контейнер (ScrollContainer по ширине панели), поэтому в отличие от
    # строки в HBoxContainer у resources_tab.gd перенос включать можно:
    # метка не просит у контейнера «свою» ширину, а берёт готовую.
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    # У RichTextLabel своя тема: без явных размеров и цвета текст был бы
    # мельче и бледнее соседних Label.
    label.add_theme_font_size_override("normal_font_size",
            problems_box.get_theme_font_size("font_size"))
    label.add_theme_color_override("default_color", Color.WHITE)
    # Метка не должна мешать тянуть список мышью.
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE

    # Три строки: чего не хватает, где нашли ссылку и в каком файле.
    # Путь к файлу — то самое, ради чего окно и делается: с ним ошибку
    # видно и исправляется, не открывая все файлы data/ подряд.
    var text := "• [b]%s[/b]\n   [color=#%s]%s[/color]" % [
        marked_headline,
        WHERE_COLOR.to_html(false),
        str(problem.get("where", "")),
    ]
    var location := str(problem.get("location", ""))
    if not location.is_empty():
        text += "\n   [color=#%s]%s[/color]" % [FILE_COLOR.to_html(false), location]
    label.text = text
    return label


# Подсвечивает идентификатор в тексте проблемы.
#
# Ищет его как отдельное СЛОВО, а не по кавычкам вокруг. Раньше подстановка
# искала «%s» вместе с кавычками-ёлочками, и это работало только пока текст
# был русским: кавычки принадлежат переводу, и в другом языке (или если
# переводчик их снимет) подсветка просто пропадала бы молча.
#
# Проверка границ — чтобы «wood» не подсветился внутри «wood_field»: соседние
# символы не должны быть частью идентификатора. Границы считаются по
# Unicode-кодам, а не сравнением строк, иначе кириллический «с» прошёл бы
# мимо проверки.
func _highlight_id(text: String, id: String) -> String:
    if id.is_empty():
        return text
    var at := text.find(id)
    while at >= 0:
        var before := "" if at == 0 else text.substr(at - 1, 1)
        var after_at := at + id.length()
        var after := "" if after_at >= text.length() else text.substr(after_at, 1)
        if not _is_ident_char(before) and not _is_ident_char(after):
            return text.substr(0, at) + "[color=#%s]%s[/color]" % [
                REF_ID_COLOR.to_html(false), id] + text.substr(after_at)
        at = text.find(id, at + 1)
    return text


# Символ, который мог бы быть частью идентификатора: буква (латинская или
# кириллическая), цифра или подчёркивание. Зеркалит IDENT_CHARS/IDENT_UPPER
# из data_validator.gd — тот же набор, который валидатор считает допустимым.
func _is_ident_char(ch: String) -> bool:
    if ch.length() != 1:
        return false
    var code := ch.unicode_at(0)
    return (code >= 0x30 and code <= 0x39) \
        or (code >= 0x41 and code <= 0x5A) \
        or (code >= 0x61 and code <= 0x7A) \
        or (code >= 0x410 and code <= 0x44F) \
        or ch == "_"


func _on_copy_pressed():
    # Список копируется целиком — удобно приложить к задаче или сразу
    # пойти править JSON.
    var lines: Array = []
    for problem in all_problems:
        lines.append(str(problem.get("message", "")))
    DisplayServer.clipboard_set("\n".join(lines))


func _on_ok_pressed():
    # Окно живёт в корне дерева сцены, а не в главном меню, поэтому само
    # себя не убирает — закрытие это queue_free(). Иначе после ухода в
    # партию и возвращения в меню накопилос бы по скрытому оверлею на
    # каждое посещение.
    queue_free()


func _input(event):
    # Esc закрывает окно, но только пока оно видно: скрытый оверлей иначе
    # перехватил бы Esc у главного меню.
    if not is_visible_in_tree():
        return
    if event.is_action_pressed("ui_cancel"):
        _on_ok_pressed()
        get_viewport().set_input_as_handled()


# Порядок блоков совпадает с порядком проверок в data_validator.gd,
# поэтому окно читается сверху вниз в том же порядке, в каком идут данные.
func _kinds_in_display_order(kinds) -> Array:
    var order: Array = []
    for kind in DataValidator.CHECK_ORDER:
        if kinds.has(kind):
            order.append(kind)
    # Виды, которых нет в списке порядка (если проверка добавится и туда
    # не попадёт), показываем в конце, а не теряем.
    for kind in kinds:
        if not order.has(kind):
            order.append(kind)
    return order


func _check_title(kind: String) -> String:
    return DataValidator.check_title(kind)


func _count_by_kind(problems: Array) -> Dictionary:
    var counts := {}
    for problem in problems:
        var kind := str(problem.get("kind", ""))
        counts[kind] = int(counts.get(kind, 0)) + 1
    return counts


func _make_panel_style() -> StyleBoxFlat:
    var style = StyleBoxFlat.new()
    style.bg_color = Color(0.13, 0.13, 0.13, 1.0)
    style.set_border_width_all(2)
    style.border_color = Color(0.4, 0.4, 0.4, 1.0)
    style.set_corner_radius_all(4)
    return style
