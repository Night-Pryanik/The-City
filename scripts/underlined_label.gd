# underlined_label.gd
# Label с подчёркнутой частью текста (например, названием группы продуктов).
# Используется в ui_helpers.make_resource_entry(), чтобы строки групп выглядели
# как кликабельные ссылки, хотя на самом деле по ним лишь показывается тултип
# состава группы. Группа — это НЕ настоящая ссылка и никуда не ведёт.
class_name UnderlinedLabel
extends Label

# Часть текста, которую нужно подчеркнуть (остаток строки — обычным начертанием).
var underline_text: String = "":
	set(value):
		underline_text = value
		queue_redraw()

func _draw() -> void:
	if underline_text.is_empty():
		return
	var f: Font = get_theme_font("font")
	if f == null:
		return
	var fs: int = get_theme_font_size("font_size")
	var width: float = f.get_string_size(
		underline_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	if width <= 0.0:
		return
	# Линия проходит по нижней границе основного начертания шрифта
	# (верхняя граница спуска — descent), под текстом.
	var y: float = get_size().y - f.get_descent(fs)
	var line_color := get_theme_color("font_color")
	line_color.a = 0.75
	# Пунктирная линия: штрих и пробел по 2 px (dash=2). Параметр aligned=true
	# выравнивает фазу так, чтобы линия начиналась со штриха (не с пробела).
	draw_dashed_line(Vector2(0.0, y + 2), Vector2(width, y + 2), line_color, 1.0, 2.0, true, true)