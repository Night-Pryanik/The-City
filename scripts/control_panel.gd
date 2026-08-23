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

# Ссылки на узлы (заполняются из main_map.gd через initialize()).
var main_map: Node
var map_tooltip: MapTooltip
var worker_manager: Node
var build_manager: Node

func _ready():
	# Панель вложена в Node2D (MainMap), поэтому anchors у Control внутри
	# Node2D не работают (родитель не имеет rect). Задаём размер/позицию
	# вручную относительно viewport: высота 20% окна, внизу.
	_update_panel_geometry()
	get_viewport().size_changed.connect(_update_panel_geometry)

# Пересчитывает геометрию панели: нижние 20% окна.
func _update_panel_geometry():
	var vp = get_viewport_rect()
	position = Vector2(0, vp.size.y * 0.8)
	size = Vector2(vp.size.x, vp.size.y * 0.2)

# Текущее выделение и превью.
var _selected_hex = null # { "row": int, "col": int }
var _preview_action = null # { "type": String, "imp_id": String, "target_res_id": String, "label": String }

# Ссылки на дочерние узлы UI.
var _info_label: Label
var _products_container: VBoxContainer
var _actions_container: VBoxContainer
var _preview_container: VBoxContainer

# Снимок состояния кнопок действий, при котором их строили в последний раз.
# Используется, чтобы НЕ пересоздавать кнопки (и их ОС-тултипы) на каждом
# игровом тике: CityData.city_updated эмитится раз в PRODUCTION_INTERVAL из
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

	_info_label = $MarginContainer/HBox/InfoVBox/InfoLabel
	_products_container = $MarginContainer/HBox/InfoVBox/ProductsContainer
	_actions_container = $MarginContainer/HBox/ActionsVBox/ActionsContainer
	_preview_container = $MarginContainer/HBox/ActionsVBox/PreviewContainer

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

# Обновляет панель. Вызывается при внешних изменениях (сигналы) и при
# выделении/сбросе. Если выделенный гекс стал невалидным (например, после
# перехода в новую эпоху) — снимаем выделение.
func refresh():
	if _selected_hex == null:
		_clear_ui()
		return
	var row = _selected_hex.row
	var col = _selected_hex.col
	if not main_map.is_valid_hex(row, col):
		clear_selection()
		return
	_refresh()

func _refresh():
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
	var info = map_tooltip.build_hex_info(row, col, main_map.tile_data, main_map.city_row, main_map.city_col)
	_info_label.text = info["text"]
	map_tooltip.render_products(info["products"], _products_container)

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
		# Сбрасываем снапшот: следующая открытая превью должна пересоздать
		# свой блок (даже если opens то же самое действие на том же гексе).
		_last_preview_snapshot = {}

func _clear_ui():
	_info_label.text = "Выберите гекс на карте (ЛКМ), чтобы увидеть информацию и доступные действия."
	for child in _products_container.get_children():
		child.queue_free()
	for child in _actions_container.get_children():
		child.queue_free()
	for child in _preview_container.get_children():
		child.queue_free()
	# Сброс снимка: если контейнер кнопок очищен, но снимок совпадает с
	# прежним гексом, следующий _build_actions() иначе решил бы, что пересоздавать
	# ничего не нужно (и кнопки бы не появились).
	_last_actions_snapshot = {}
	_last_preview_snapshot = {}

# --- Построение кнопок действий ---
func _build_actions(row: int, col: int, tile: Dictionary):
	# Если состояние действий для этого гекса не изменилось с прошлого раза —
	# не пересоздаём кнопки. Это сохраняет открытые ОС-тултипы (иначе каждый
	# игровой тик пересоздание кнопок сбрасывало бы наведённый тултип).
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
		btn.text = action.get("label", "")
		btn.custom_minimum_size = Vector2(0, 28)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.disabled = not action.get("enabled", true)
		btn.tooltip_text = action.get("tooltip", "")
		if not action.get("enabled", true):
			# Серый цвет для недоступных действий.
			btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			btn.add_theme_color_override("font_disabled_color", Color(0.5, 0.5, 0.5))
		var action_data = action
		btn.pressed.connect(func():
			_on_action_pressed(action_data)
		)
		_actions_container.add_child(btn)

# Сравнивает два списка действий (по значимым полям, чтобы у неработающего
# поля type/imp_id не пересоздавались кнопки вхолостую).
func _actions_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		var x: Dictionary = a[i]
		var y: Dictionary = b[i]
		for key in ["type", "label", "enabled", "tooltip", "imp_id", "action_id", "target_res_id"]:
			if x.get(key, null) != y.get(key, null):
				return false
	return true

# Собирает список действий для гекса. Каждый элемент:
#   { "type": String, "label": String, "enabled": bool, "tooltip": String,
#     "imp_id": String, "target_res_id": String, "action_id": String }
# type: "build_improvement" | "build_pasture" | "build_farm" | "special" |
#       "pause_improvement" | "resume_improvement" | "cancel_build"
func _collect_actions(row: int, col: int, tile: Dictionary) -> Array:
	var actions := []
	var in_influence = tile.get("in_influence", false)

	# Действия доступны только в Кольце Влияния (территория освоена).
	if not in_influence:
		actions.append({
			"type": "info",
			"label": "Гекс вне Кольца Влияния",
			"enabled": false,
			"tooltip": "Освойте территорию (ПКМ по гексу → «Освоить»), чтобы строить здесь."
		})
		return actions

	# --- Улучшение уже построено ---
	if tile.improvement != null:
		var imp_name = GameData.improvements.get(tile.improvement, {}).get("name", tile.improvement)
		var has_worker = worker_manager.has_worker(row, col)
		if has_worker:
			actions.append({
				"type": "pause_improvement",
				"label": "Приостановить работу (%s)" % imp_name,
				"enabled": true,
				"tooltip": "Снять рабочего с улучшения"
			})
		else:
			actions.append({
				"type": "resume_improvement",
				"label": "Запустить работу (%s)" % imp_name,
				"enabled": CityData.idle_population > 0,
				"tooltip": "Назначить рабочего на улучшение" if CityData.idle_population > 0 else "Нет свободных рабочих"
			})

		# Спец-действия, применимые к гексу с улучшением (например, снос).
		_add_special_actions(actions, row, col, tile)

		# Если идёт строительство — добавляем опцию отмены.
		if build_manager.is_building(row, col):
			actions.append({
				"type": "cancel_build",
				"label": "Отменить стройку",
				"enabled": true,
				"tooltip": "Отменить текущее строительство на этом гексе"
			})
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
			var tooltip = "Построить %s" % imp_name
			# Проверка: ресурс скрыт tech_reveal-гейтом.
			if not MapHelpers.is_resource_revealed(tile):
				enabled = false
				tooltip = "Ресурс ещё не обнаружен (нужна разведка/технология)"
			# Проверка: технология для улучшения.
			elif not CityData.is_improvement_unlocked(imp_id):
				var unlock_tech = CityData.get_improvement_unlock_tech(imp_id)
				var tech_name = _get_tech_name(unlock_tech)
				enabled = false
				tooltip = "Нужна технология: %s" % tech_name
			# Проверка: ресурс требует технологию (tech_required).
			elif raw.get("tech_required", "") != "" and not CityData.is_tech_unlocked(raw["tech_required"]):
				var tech_name2 = _get_tech_name(raw["tech_required"])
				enabled = false
				tooltip = "Нужна технология: %s" % tech_name2
			# Проверка: лимит строек.
			elif build_manager.get_total_active_builds() >= CityData.total_population:
				enabled = false
				tooltip = "Нет труда: лимит строек (число жителей) исчерпан"
			actions.append({
				"type": "build_improvement",
				"label": "Построить %s" % imp_name,
				"enabled": enabled,
				"tooltip": tooltip,
				"imp_id": imp_id,
				"target_res_id": tile.resource
			})

	# 2. Пустой гекс: разведение одомашненных животных/растений.
	if tile.resource == null:
		# Пастбище.
		if CityData.domesticated_animals.size() > 0:
			var pasture_unlocked = CityData.is_improvement_unlocked("pasture")
			var pasture_enabled = pasture_unlocked
			var pasture_tooltip = "Построить пастбище для одомашненного животного"
			if not pasture_unlocked:
				var unlock_tech = CityData.get_improvement_unlock_tech("pasture")
				pasture_tooltip = "Нужна технология: %s" % _get_tech_name(unlock_tech)
			elif build_manager.get_total_active_builds() >= CityData.total_population:
				pasture_enabled = false
				pasture_tooltip = "Нет труда: лимит строек (число жителей) исчерпан"
			# Проверяем, есть ли подходящее животное для этого гекса.
			var has_suitable_animal = false
			for animal_id in CityData.domesticated_animals:
				var animal_data = GameData.raw_resources.get(animal_id, {})
				if tile.terrain in animal_data.get("allowed_terrain", []) and tile.get("cover", "none") in animal_data.get("allowed_cover", []):
					has_suitable_animal = true
					break
			if has_suitable_animal:
				actions.append({
					"type": "build_pasture",
					"label": "Построить пастбище",
					"enabled": pasture_enabled,
					"tooltip": pasture_tooltip,
					"imp_id": "pasture"
				})
		# Ферма.
		if CityData.domesticated_plants.size() > 0:
			var farm_unlocked = CityData.is_improvement_unlocked("farm")
			var farm_enabled = farm_unlocked
			var farm_tooltip = "Построить ферму для одомашненного растения"
			if not farm_unlocked:
				var unlock_tech = CityData.get_improvement_unlock_tech("farm")
				farm_tooltip = "Нужна технология: %s" % _get_tech_name(unlock_tech)
			elif build_manager.get_total_active_builds() >= CityData.total_population:
				farm_enabled = false
				farm_tooltip = "Нет труда: лимит строек (число жителей) исчерпан"
			var has_suitable_plant = false
			for plant_id in CityData.domesticated_plants:
				var plant_data = GameData.raw_resources.get(plant_id, {})
				if tile.terrain in plant_data.get("allowed_terrain", []) and tile.get("cover", "none") in plant_data.get("allowed_cover", []):
					has_suitable_plant = true
					break
			if has_suitable_plant:
				actions.append({
					"type": "build_farm",
					"label": "Построить ферму",
					"enabled": farm_enabled,
					"tooltip": farm_tooltip,
					"imp_id": "farm"
				})

	# 3. Спец-действия (вырубка леса, сбор дикоросов и т.п.).
	_add_special_actions(actions, row, col, tile)

	# 4. Если идёт стройка — отмена.
	if build_manager.is_building(row, col):
		actions.append({
			"type": "cancel_build",
			"label": "Отменить стройку",
			"enabled": true,
			"tooltip": "Отменить текущее строительство на этом гексе"
		})

	return actions

# Добавляет спец-действия (special_actions.json), применимые к гексу.
func _add_special_actions(actions: Array, row: int, col: int, tile: Dictionary):
	for sa_id in GameData.special_actions:
		var sa = GameData.special_actions[sa_id]
		var action_type = sa.get("action_type", "terrain")
		var applicable = false
		if action_type == "terrain":
			applicable = tile.terrain == sa.get("source_terrain", "") and tile.improvement == null
		elif action_type == "cover":
			var cover_id = tile.get("cover", "none")
			applicable = cover_id in sa.get("source_cover", []) and tile.improvement == null and tile.resource == null
		elif action_type == "forage":
			applicable = tile.resource == sa.get("target_resource", "")
		elif action_type == "demolish":
			applicable = tile.improvement != null
		if not applicable:
			continue

		var sa_name = sa.get("name", sa_id)
		var enabled = true
		var tooltip = sa_name
		var unlock_tech = sa.get("unlock_tech", "")
		if unlock_tech != "" and not CityData.is_tech_unlocked(unlock_tech):
			enabled = false
			tooltip = "Нужна технология: %s" % _get_tech_name(unlock_tech)
		elif build_manager.get_total_active_builds() >= CityData.total_population:
			enabled = false
			tooltip = "Нет труда: лимит строек (число жителей) исчерпан"
		actions.append({
			"type": "special",
			"label": sa_name,
			"enabled": enabled,
			"tooltip": tooltip,
			"action_id": sa_id
		})

# --- Обработка нажатия на кнопку действия ---
func _on_action_pressed(action: Dictionary):
	var type = action.get("type", "")
	if type == "info":
		return
	# Действия, которые выполняются сразу (без превью).
	if type == "pause_improvement":
		worker_manager.remove_worker(_selected_hex.row, _selected_hex.col)
		main_map.map_renderer.queue_redraw()
		_refresh()
		return
	if type == "resume_improvement":
		if not worker_manager.assign_worker(_selected_hex.row, _selected_hex.col):
			main_map.hud.show_message("Нет свободных рабочих!")
		main_map.map_renderer.queue_redraw()
		_refresh()
		return
	if type == "cancel_build":
		main_map.confirm_cancel_build(_selected_hex.row, _selected_hex.col)
		return

	# Действия с превью (постройка улучшения, пастбища, фермы, спец-действие).
	var eff_res_for_preview = action.get("target_res_id", null)
	if eff_res_for_preview == null or eff_res_for_preview == "":
		eff_res_for_preview = MapHelpers.get_effective_resource(main_map.get_tile_data(_selected_hex.row, _selected_hex.col))
	_preview_action = {
		"type": type,
		"imp_id": action.get("imp_id", ""),
		"target_res_id": action.get("target_res_id", null),
		"action_id": action.get("action_id", ""),
		"label": action.get("label", ""),
		"eff_res": eff_res_for_preview
	}
	_refresh()

# --- Построение превью действия ---
func _build_preview(row: int, col: int, tile: Dictionary):
	var preview = _preview_action

	# Если превью для этого гекса и этого действия уже построено — не
	# пересоздаём элементы (в т.ч. кнопки «Построить»/«Отменить» с их
	# ОС-тултипами). Иначе они сбрасывались бы каждый игровой тик.
	var snapshot = {
		"row": row,
		"col": col,
		"type": preview.get("type", ""),
		"label": preview.get("label", ""),
		"imp_id": preview.get("imp_id", ""),
		"action_id": preview.get("action_id", ""),
		"target_res_id": preview.get("target_res_id", null),
		"eff_res": preview.get("eff_res", "")
	}
	if _preview_equal(_last_preview_snapshot, snapshot):
		return
	_last_preview_snapshot = snapshot

	for child in _preview_container.get_children():
		child.queue_free()

	var type = preview.get("type", "")
	var imp_id = preview.get("imp_id", "")
	var action_id = preview.get("action_id", "")
	var eff_res = preview.get("eff_res", "")

	# Заголовок превью.
	var header = Label.new()
	header.text = "Превью: %s" % preview.get("label", "")
	header.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5))
	_preview_container.add_child(header)

	# Для спец-действий стоимость считается по action_id, а не по imp_id.
	var cost_imp_id = imp_id
	if type == "special":
		cost_imp_id = action_id

	# Расчёт производства (для улучшений и разведения, кроме спец-действий).
	if type != "special" and eff_res != "":
		var res_data = GameData.raw_resources.get(eff_res, {})
		if res_data.has("produces"):
			# Множитель производства с учётом модификаторов (вода, местность, технологии).
			var has_water = MapHelpers.is_hex_irrigated(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
			var terrain_id = tile.get("terrain", "")
			var bonus_multiplier = CityData.get_improvement_production_multiplier(imp_id, has_water, terrain_id, eff_res)
			var modifiers = CityData.get_improvement_production_modifiers(imp_id, has_water, terrain_id, eff_res)

			var products := []
			products.append({"type": "header", "text": "Будет производить:"})
			for prod_id in res_data["produces"]:
				if not CityData.is_product_available(prod_id):
					continue
				var base_amount = float(res_data["produces"][prod_id])
				var final_amount = ceili(base_amount * bonus_multiplier)
				var prod_name = GameData.products.get(prod_id, {}).get("name", prod_id)
				var icon_path = ""
				var prod_data = GameData.products.get(prod_id, {})
				if prod_data.has("icon"):
					var icon_name = prod_data["icon"]
					icon_path = main_map.map_renderer.get_icon_path(icon_name)
				products.append({"type": "product", "name": prod_name, "amount": final_amount, "icon_path": icon_path})
			if modifiers.size() > 0:
				# База — первый продукт в списке produces (как в тултипе).
				var first_base = 0.0
				for pid in res_data["produces"]:
					first_base = float(res_data["produces"][pid])
					break
				products.append({"type": "label", "text": " База: %d" % int(first_base), "color": Color(0.8, 0.8, 0.8)})
				for mod in modifiers:
					products.append({"type": "label", "text": " %s" % mod.get("label", ""), "color": Color(0.7, 0.9, 0.7)})
			map_tooltip.render_products(products, _preview_container)

	# Стоимость труда.
	var cost_data = MapHelpers.get_improvement_work_cost(cost_imp_id, row, col, main_map.tile_data, main_map.city_row, main_map.city_col)
	var cost_label = Label.new()
	cost_label.text = "Стоимость: %d труда" % cost_data["cost"]
	cost_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	_preview_container.add_child(cost_label)

	# Кнопки «Построить» и «Отменить».
	var hbox = HBoxContainer.new()
	var build_btn = Button.new()
	build_btn.text = "Построить"
	build_btn.custom_minimum_size = Vector2(0, 28)
	build_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	build_btn.tooltip_text = preview.get("label", "Подтвердить постройку")
	build_btn.pressed.connect(func():
		_confirm_build()
	)
	hbox.add_child(build_btn)
	var cancel_btn = Button.new()
	cancel_btn.text = "Отменить"
	cancel_btn.custom_minimum_size = Vector2(0, 28)
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.tooltip_text = "Закрыть превью без постройки"
	cancel_btn.pressed.connect(func():
		clear_preview()
	)
	hbox.add_child(cancel_btn)
	_preview_container.add_child(hbox)

# Сравнивает два снапшота блока превью по значимым полям.
func _preview_equal(a: Dictionary, b: Dictionary) -> bool:
	return a.get("row", -1) == b.get("row", -1) \
		and a.get("col", -1) == b.get("col", -1) \
		and a.get("type", "") == b.get("type", "") \
		and a.get("label", "") == b.get("label", "") \
		and a.get("imp_id", "") == b.get("imp_id", "") \
		and a.get("action_id", "") == b.get("action_id", "") \
		and a.get("target_res_id", null) == b.get("target_res_id", null) \
		and a.get("eff_res", "") == b.get("eff_res", "")

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

	if type == "build_improvement":
		build_manager.start_build(row, col, imp_id, target_res_id)
	elif type == "build_pasture":
		# Выбираем первое подходящее животное.
		var tile = main_map.get_tile_data(row, col)
		for animal_id in CityData.domesticated_animals:
			var animal_data = GameData.raw_resources.get(animal_id, {})
			if tile.terrain in animal_data.get("allowed_terrain", []) and tile.get("cover", "none") in animal_data.get("allowed_cover", []):
				build_manager.start_build(row, col, "pasture", animal_id)
				break
	elif type == "build_farm":
		var tile2 = main_map.get_tile_data(row, col)
		for plant_id in CityData.domesticated_plants:
			var plant_data = GameData.raw_resources.get(plant_id, {})
			if tile2.terrain in plant_data.get("allowed_terrain", []) and tile2.get("cover", "none") in plant_data.get("allowed_cover", []):
				build_manager.start_build(row, col, "farm", plant_id)
				break
	elif type == "special":
		build_manager.start_build(row, col, action_id)

	# После подтверждения сбрасываем превью, но оставляем выделение.
	_preview_action = null
	main_map.map_renderer.queue_redraw()
	main_map.redraw_progress_layer()
	_refresh()

# --- Хелперы ---
func _get_tech_name(tech_id: String) -> String:
	for tech in GameData.technologies:
		if tech["id"] == tech_id:
			return tech.get("name", tech_id)
	return tech_id