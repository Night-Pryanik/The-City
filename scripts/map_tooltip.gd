class_name MapTooltip

var _tooltip_text_label: Label
var _tooltip_products_container: VBoxContainer
var _map_renderer
var _worker_manager

func _init(tooltip_text_label: Label, tooltip_products_container: VBoxContainer, map_renderer, worker_manager):
	_tooltip_text_label = tooltip_text_label
	_tooltip_products_container = tooltip_products_container
	_map_renderer = map_renderer
	_worker_manager = worker_manager


func update_tooltip_text(row: int, col: int, tile_data: Array):
	for child in _tooltip_products_container.get_children():
		child.queue_free()

	var tile = tile_data[row][col]
	var terrain_name = GameData.terrains.get(tile.terrain, {}).get("name", tile.terrain)
	var cover_id = tile.get("cover", "none")

	var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)
	# Эффективный ресурс: природный (tile.resource) или разводимый (tile.crop_bred).
	# Это позволяет тултипу одинаково работать и для улучшения существующего
	# природного ресурса, и для разведения на пустом гексе.
	var res_id = MapHelpers.get_effective_resource(tile)
	var res_name = "нет"
	if res_id != "":
		res_name = GameData.raw_resources.get(res_id, {}).get("name", res_id)

	var cover_name_lower = ""
	if cover_id != "none":
		# Имя покрова берём из данных (covers.json)
		cover_name_lower = GameData.covers.get(cover_id, {}).get("name", cover_id).to_lower()
	var terrain_with_cover = terrain_name
	if cover_name_lower != "":
		terrain_with_cover = "%s, %s" % [terrain_name, cover_name_lower]

	var terrain_data = GameData.terrains.get(tile.terrain, {})
	if terrain_data.get("unique", false) and not is_revealed:
		var desc = terrain_data.get("description", "")
		_tooltip_text_label.text = desc if desc != "" else terrain_name
		return

	if not is_revealed:
		var unknown_text = "Местность: %s\nРесурс: неизвестно (проведите разведку)" % terrain_with_cover
		_tooltip_text_label.text = unknown_text
		return

	var imp_name = GameData.improvements.get(tile.improvement, {}).get("name", "нет") if tile.improvement != null else "нет"
	var text = "Местность: %s\nРесурс: %s" % [terrain_with_cover, res_name]

	var terrain_desc = terrain_data.get("description", "")
	if terrain_desc != "":
		text += "\n%s" % terrain_desc

	var tile_quality = tile.get("quality", "")
	if tile_quality != "" and tile.improvement != null:
		var q_stars = GameData.get_quality_stars(tile_quality)
		var q_name = GameData.get_quality_name(tile_quality)
		text += "\nКачество: %s (%s)" % [q_stars, q_name]

	var imp_status = ""
	if tile.improvement != null:
		var has_worker = _worker_manager.has_worker(row, col)
		if not has_worker:
			imp_status = " (неактивно: нет рабочего)"
		else:
			imp_status = " (работает)"
		if res_id != "":
			var res_data = GameData.raw_resources.get(res_id, {})
			if res_data.has("produces"):
				_add_production_info(row, col, res_id, " Производит:", tile_data)
	else:
		if res_id != "":
			var res_data = GameData.raw_resources.get(res_id, {})
			if res_data.has("improved_by") and res_data.has("produces"):
				var improvement_id = res_data["improved_by"]
				var imp_data = GameData.improvements.get(improvement_id, {})
				var imp_name_display = imp_data.get("name", improvement_id)
				_add_production_info(row, col, res_id, " При постройке %s будет давать:" % imp_name_display, tile_data)
				imp_status = " (не построено)"

	if res_id != "":
		var res_data = GameData.raw_resources.get(res_id, {})
		var feed_consumption = res_data.get("feed_consumption", 0)
		if feed_consumption > 0:
			text += "\nПотребляет корма: %d за цикл" % feed_consumption
		var time_to_mature = res_data.get("time_to_mature", 0)
		if time_to_mature > 0:
			text += "\nВремя заполнения: %.0f сек" % time_to_mature

	text += "\nУлучшение: %s%s" % [imp_name, imp_status]
	if tile.improvement == "farm" and MapHelpers.is_hex_irrigated(row, col, tile_data, tile_data.size(), tile_data[0].size()):
		text += "\nДоступ к пресной воде"

	# --- Конфликт «tech_reveal-ресурс под чужим улучшением» ---
	# Если на гексе уже стоит улучшение, а под ним нашли скрытый ресурс
	# (например, на горном холме с железом игрок поставил пастбище) —
	# добавляем поясняющие строки. Текст идёт в основную часть тултипа
	# (всегда виден), а не в расширенную — это важная информация, а не
	# детали производства. Имя нового улучшения берётся из данных ресурса
	# (поле improved_by), не хардкодится.
	# Подробности: docs.md, раздел «tech_reveal: скрытые ресурсы».
	var conflict = MapHelpers.get_tech_reveal_conflict(tile)
	if not conflict.is_empty():
		var current_imp_name: String = GameData.improvements.get(tile.improvement, {}).get("name", tile.improvement)
		text += "\n\nЗдесь обнаружено: %s" % conflict.get("res_name", "")
		text += "\nСнесите %s, чтобы построить %s" % [current_imp_name, conflict.get("imp_name", "")]

	if tile.improvement == null:
		var buildable_imp = MapHelpers.get_buildable_improvement(tile)
		if buildable_imp != "":
			var cost_data = MapHelpers.get_improvement_work_cost(buildable_imp, row, col, tile_data, 0, 0)
			var buildable_imp_name: String = GameData.improvements.get(buildable_imp, {}).get("name", buildable_imp)
			text += "\nСтроительство: %d труда (%s)" % [cost_data["cost"], buildable_imp_name]

	_tooltip_text_label.text = text


func has_extended_tooltip_info(row: int, col: int, tile_data: Array) -> bool:
	var tile = tile_data[row][col]
	var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)
	if not is_revealed:
		return false

	# Расширенный тултип показываем, если на гексе идёт активное производство:
	# улучшение построено, рабочий назначен, и на гексе есть «эффективный»
	# ресурс (природный или разводимый) с produces.
	var eff_res = MapHelpers.get_effective_resource(tile)
	if tile.improvement != null and eff_res != "" and _worker_manager.has_worker(row, col):
		var res_data = GameData.raw_resources.get(eff_res, {})
		if res_data.has("produces"):
			var bonus_multiplier = CityData.get_improvement_production_multiplier(tile.improvement, MapHelpers.is_hex_irrigated(row, col, tile_data, tile_data.size(), tile_data[0].size()), tile.get("terrain", ""), eff_res)
			if bonus_multiplier > 1.0:
				return true

	if tile.improvement == null:
		if MapHelpers.get_buildable_improvement(tile) != "":
			return true

	return false


func update_extended_tooltip(row: int, col: int, tile_data: Array, city_row: int, city_col: int):
	for child in _tooltip_products_container.get_children():
		child.queue_free()

	var tooltip_lines = _tooltip_text_label.text.split("\n")
	var filtered_lines := []
	for line in tooltip_lines:
		if not line.begins_with("Строительство:"):
			filtered_lines.append(line)
	_tooltip_text_label.text = "\n".join(filtered_lines)

	var tile = tile_data[row][col]
	var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)
	if not is_revealed:
		return

	if tile.improvement == null:
		var buildable_imp = MapHelpers.get_buildable_improvement(tile)
		if buildable_imp != "":
			var cost_data = MapHelpers.get_improvement_work_cost(buildable_imp, row, col, tile_data, city_row, city_col)
			var imp_name = GameData.improvements.get(buildable_imp, {}).get("name", buildable_imp)

			var header = Label.new()
			header.text = "Строительство: %d труда (%s)" % [cost_data["cost"], imp_name]
			header.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5))
			_tooltip_products_container.add_child(header)

			var base_label = Label.new()
			base_label.text = " База: %d труда" % cost_data["base_cost"]
			base_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
			_tooltip_products_container.add_child(base_label)

			var terrain_label = Label.new()
			var move_cost_text = "непроходимо" if cost_data["move_cost"] >= 999.0 else str(int(cost_data["move_cost"]))
			terrain_label.text = " Местность: %s (стоимость передвижения: %s) ×%.2f" % [cost_data["terrain_name"], move_cost_text, cost_data["terrain_mult"]]
			terrain_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
			_tooltip_products_container.add_child(terrain_label)

			var dist_label = Label.new()
			dist_label.text = " Расстояние до города: %d → ×%.2f" % [cost_data["distance"], cost_data["distance_mult"]]
			dist_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
			_tooltip_products_container.add_child(dist_label)

			var total_label = Label.new()
			total_label.text = " Итого: %d труда" % cost_data["cost"]
			total_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
			_tooltip_products_container.add_child(total_label)

	var res_id = MapHelpers.get_effective_resource(tile)
	if res_id == "":
		return
	var res_data = GameData.raw_resources.get(res_id, {})
	if not res_data.has("produces"):
		return

	_add_extended_production_info(row, col, tile_data)


func _add_production_info(row: int, col: int, res_id: String, prefix: String, tile_data: Array):
	if res_id == "":
		return
	var res_data = GameData.raw_resources.get(res_id, {})
	if not res_data.has("produces"):
		return

	var tile = tile_data[row][col]
	var has_worker = _worker_manager.has_worker(row, col)

	var bonus_multiplier = 1.0
	if tile.improvement != null and has_worker:
		bonus_multiplier = CityData.get_improvement_production_multiplier(tile.improvement, MapHelpers.is_hex_irrigated(row, col, tile_data, tile_data.size(), tile_data[0].size()), tile.get("terrain", ""), res_id)

	var final_amounts := {}
	for prod_id in res_data["produces"]:
		if not CityData.is_product_available(prod_id):
			continue
		var base_amount = float(res_data["produces"][prod_id])
		var final_amount = ceili(base_amount * bonus_multiplier)
		final_amounts[prod_id] = {"base": base_amount, "final": final_amount}

	if final_amounts.is_empty():
		return

	var label = Label.new()
	label.text = prefix
	label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	_tooltip_products_container.add_child(label)

	for prod_id in final_amounts:
		var amount = final_amounts[prod_id].final
		var prod_name = GameData.products.get(prod_id, {}).get("name", prod_id)
		var icon_path = ""
		var prod_data = GameData.products.get(prod_id, {})
		if prod_data.has("icon"):
			var icon_name = prod_data["icon"]
			icon_path = _map_renderer.get_icon_path(icon_name)

		var hbox = HBoxContainer.new()
		if icon_path != "":
			var tex_rect = TextureRect.new()
			tex_rect.texture = load(icon_path)
			tex_rect.custom_minimum_size = Vector2(20, 20)
			tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex_rect.stretch_mode = TextureRect.STRETCH_SCALE
			hbox.add_child(tex_rect)
		var label_item = Label.new()
		label_item.text = "%s: %d" % [prod_name, amount]
		label_item.add_theme_color_override("font_color", Color.WHITE)
		hbox.add_child(label_item)
		_tooltip_products_container.add_child(hbox)


func _add_extended_production_info(row: int, col: int, tile_data: Array):
	var tile = tile_data[row][col]
	# И снова: интересует эффективный ресурс (природный или разводимый).
	var eff_res = MapHelpers.get_effective_resource(tile)
	if eff_res == "":
		return
	var res_data = GameData.raw_resources.get(eff_res, {})
	if not res_data.has("produces"):
		return

	var modifiers := []
	var bonus_multiplier = 1.0
	if tile.improvement != null and _worker_manager.has_worker(row, col):
		modifiers = CityData.get_improvement_production_modifiers(tile.improvement, MapHelpers.is_hex_irrigated(row, col, tile_data, tile_data.size(), tile_data[0].size()), tile.get("terrain", ""), eff_res)
		bonus_multiplier = CityData.get_improvement_production_multiplier(tile.improvement, MapHelpers.is_hex_irrigated(row, col, tile_data, tile_data.size(), tile_data[0].size()), tile.get("terrain", ""), eff_res)

	var available_products := {}
	for prod_id in res_data["produces"]:
		if CityData.is_product_available(prod_id):
			available_products[prod_id] = res_data["produces"][prod_id]

	if available_products.is_empty():
		return

	var header_label = Label.new()
	if tile.improvement != null:
		header_label.text = "Производит:"
	else:
		var improvement_id = res_data.get("improved_by", "")
		var imp_name_display = GameData.improvements.get(improvement_id, {}).get("name", improvement_id)
		header_label.text = "При постройке %s будет давать:" % imp_name_display
	header_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	_tooltip_products_container.add_child(header_label)

	var base_amount = 0.0
	var final_amount = 0
	for prod_id in available_products:
		base_amount = float(available_products[prod_id])
		final_amount = ceili(base_amount * bonus_multiplier)
		var prod_name = GameData.products.get(prod_id, {}).get("name", prod_id)
		var icon_path = ""
		var prod_data = GameData.products.get(prod_id, {})
		if prod_data.has("icon"):
			var icon_name = prod_data["icon"]
			icon_path = _map_renderer.get_icon_path(icon_name)

		var hbox = HBoxContainer.new()
		if icon_path != "":
			var tex_rect = TextureRect.new()
			tex_rect.texture = load(icon_path)
			tex_rect.custom_minimum_size = Vector2(20, 20)
			tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex_rect.stretch_mode = TextureRect.STRETCH_SCALE
			hbox.add_child(tex_rect)
		var label_item = Label.new()
		label_item.text = "%s: %d" % [prod_name, final_amount]
		label_item.add_theme_color_override("font_color", Color.WHITE)
		hbox.add_child(label_item)
		_tooltip_products_container.add_child(hbox)

	if modifiers.size() > 0:
		var base_label = Label.new()
		base_label.text = " База: %d" % int(base_amount)
		base_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
		_tooltip_products_container.add_child(base_label)
		for mod in modifiers:
			var mod_label = Label.new()
			mod_label.text = " %s" % mod.get("label", "")
			mod_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
			_tooltip_products_container.add_child(mod_label)
		var total_label = Label.new()
		total_label.text = " Итого: %.1f → %d" % [base_amount * bonus_multiplier, final_amount]
		total_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
		_tooltip_products_container.add_child(total_label)