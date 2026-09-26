# Headless-тест «залипшего» скроллбара тултипов (детали здания, потоки ресурсов):
#   godot --headless --path . --script res://tests/test_detail_tooltip.gd
#
# Сценарий бага: тултип показан для «большого» здания (> 15 строк, со
# скроллбаром), затем контент пересобирается под «маленькое» здание (как при
# быстром переводе курсора между кнопками) и тултип показывается повторно —
# в тот же кадр (задержка = 0) и после скрытия (задержка > 0).
# Ожидание: размер панели пересчитывается под новый контент, скроллбар,
# который малому контенту не нужен, не остаётся.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание (именно так выглядел зависший прогон из-за вызова show_flow_tooltip с
# Dictionary вместо String). Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _failed := false

func _initialize():
	WATCHDOG.arm(self)
	_run()

func _run() -> void:
	await process_frame

	var holder := Control.new()
	root.add_child(holder)
	var ui = load("res://scripts/ui_helpers.gd").new()
	ui.setup(holder, Label.new())
	holder.add_child(ui)
	await process_frame
	await process_frame

	var panel: Panel = ui.detail_tooltip_panel
	var scroll: ScrollContainer = ui.detail_tooltip_scroll
	var max_h: float = ui.DETAIL_TOOLTIP_MAX_ROWS * ui.DETAIL_TOOLTIP_ROW_HEIGHT

	# --- 1. Большой контент: тултип со скроллбаром ---
	_fill_content(ui.detail_tooltip_content, 22)
	ui.show_building_detail_tooltip(Vector2(100, 100))
	await process_frame
	await process_frame
	check(panel.visible, "тултип большого здания виден")
	check(panel.size.y <= max_h + 8.0 + 0.5,
		"высота панели ограничена 15 строками (факт %.1f)" % panel.size.y)
	check(scroll.get_v_scroll_bar().visible, "у большого контента ожидается скроллбар")

	# --- 2. Быстрое переключение на «маленькое» здание: пересборка и
	# повторный показ в том же кадре (худший случай: задержка = 0) ---
	_fill_content(ui.detail_tooltip_content, 3)
	ui.show_building_detail_tooltip(Vector2(100, 100))
	await process_frame
	await process_frame
	check(panel.visible, "тултип малого здания виден")
	check(panel.size.y < max_h,
		"высота панели пересчитана под малый контент (факт %.1f)" % panel.size.y)
	check(not scroll.get_v_scroll_bar().visible,
		"скроллбар не должен оставаться у малого контента")

	# --- 3. Вариант с задержкой: тултип скрыт, контент пересобран, через
	# кадр показан заново (контент всё это время не проходил раскладку) ---
	_fill_content(ui.detail_tooltip_content, 22)
	ui.show_building_detail_tooltip(Vector2(100, 100))
	await process_frame
	_fill_content(ui.detail_tooltip_content, 3)
	ui.hide_building_detail_tooltip()
	await process_frame
	await process_frame
	ui.show_building_detail_tooltip(Vector2(100, 100))
	await process_frame
	await process_frame
	check(panel.visible, "повторно показанный тултип виден")
	check(panel.size.y < max_h,
		"после скрытия высота пересчитана (факт %.1f)" % panel.size.y)
	check(not scroll.get_v_scroll_bar().visible,
		"после скрытия скроллбар не должен возвращаться")

	# --- 3b. Кейс «контент пересобран под другое здание, пока панель ВИДНА, и
	# повторного вызова показа нет» сознательно НЕ проверяется. Размер панели
	# считается только внутри show_building_detail_tooltip (ui_helpers.gd),
	# покадрового пересчёта в ui_helpers нет — ждать сжатия панели без
	# повторного show() нечего. В игре это состояние и не наблюдается:
	# city_ui._process либо прячет тултип (курсор ушёл с кнопки), либо
	# показывает его заново (наведение на кнопку нового здания). ---

	# --- 4. Тот же сценарий для тултипа потоков (вкладка «Ресурсы») ---
	# Вызовы show_flow_tooltip идут с ПОЛНЫМ списком аргументов: у параметра
	# resource_id тип String, и Dictionary на его месте обрывает корутину
	# _run() — до quit() управление не доходит, и прогон зависает.
	var fpanel: Panel = ui.flow_tooltip_panel
	var fscroll: ScrollContainer = ui.flow_tooltip_scroll
	# special_yield в игре — это {id_продукта: количество} (GameData.
	# get_special_yield → data/products/*.json), поэтому и здесь значения —
	# числа, а не словари: иначе int(special_yield[id]) внутри
	# show_flow_tooltip споткнулся бы о тип.
	var sources := {}
	for i in 25:
		sources["Источник %d" % i] = 10 + i
	ui.show_flow_tooltip(Vector2(100, 100), "Ресурс", sources, "", {}, {})
	await process_frame
	await process_frame
	check(fpanel.visible, "большой тултип потоков виден")
	check(fscroll.get_v_scroll_bar().visible, "у большого потока ожидается скроллбар")
	var small := {"Один": 5}
	ui.show_flow_tooltip(Vector2(100, 100), "Ресурс", small, "", {}, {})
	await process_frame
	await process_frame
	check(fpanel.size.y < max_h,
		"высота тултипа потоков пересчитана (факт %.1f)" % fpanel.size.y)
	check(not fscroll.get_v_scroll_bar().visible,
		"скроллбар потока не должен оставаться у малого контента")

	if _failed:
		print("DETAIL TOOLTIP TEST FAILED")
		quit(1)
	else:
		print("DETAIL TOOLTIP TEST OK")
		quit(0)

# Имитация пересборки контента в _show_building_details (buildings_tab):
# заголовок + autowrap-описание фиксированной ширины (как в реальном тултипе)
# + строки списка.
func _fill_content(content: VBoxContainer, rows: int) -> void:
	for child in content.get_children():
		child.free()
	var title := Label.new()
	title.text = "Здание"
	title.add_theme_font_size_override("font_size", 18)
	content.add_child(title)
	var desc := Label.new()
	desc.text = "Описание здания: достаточно длинный текст, чтобы переноситься на несколько строк при фиксированной ширине тултипа."
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(420, 0)
	content.add_child(desc)
	for i in rows:
		var lbl := Label.new()
		lbl.text = "• Строка %d: стоимость, слоты производства, рецепты" % i
		content.add_child(lbl)

func check(cond: bool, msg: String) -> void:
	if cond:
		print("OK: ", msg)
	else:
		_failed = true
		push_error("ASSERT FAILED: " + msg)
		print("ASSERT FAILED: ", msg)
