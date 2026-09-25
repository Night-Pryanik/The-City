# Headless-тест правила «Гекс в тумане войны не выдаёт информацию»:
#   godot --headless --path "E:\The City" --script res://tools/test_fog_info.gd
#
# Проверяется на живых данных реальной сцены MainMap (новая игра):
#   1. main_map.is_hex_in_fog(): гекс города и разведанные гексы — не туман;
#      неисследованный гекс Региона — не туман (Регион виден на карте, там
#      известна местность, а ресурсы открывает разведка); неисследованный гекс
#      вне Региона — туман, и «Картография» сама по себе его не снимает.
#   2. Левая колонка панели управления для туманного гекса показывает заглушку
#      «Гекс не разведан» и НЕ показывает местность; после разведки информация
#      появляется.
#   3. main_map.update_tooltip_text() для туманного гекса ничего не пишет
#      (страховка публичной точки входа; основной гейт — в InputHandler).
extends SceneTree

func _initialize():
	_run()

func _run() -> void:
	var state = {"failed": false}
	var save_manager = get_root().get_node("SaveManager")
	save_manager.new_game()
	var city = get_root().get_node("CityData")
	var main_map = load("res://scenes/MainMap.tscn").instantiate()
	get_root().add_child(main_map)
	await process_frame
	await process_frame

	var cp = main_map.control_panel
	# Автозагрузки (GameData/CityData) в режиме --script недоступны на этапе
	# компиляции этого файла — берём их через дерево сцены в рантайме.
	var game_data = get_root().get_node("GameData")

	# --- 1. Предикат тумана ---
	check(not main_map.is_hex_in_fog(main_map.city_row, main_map.city_col),
		"гекс города не может быть в тумане войны", state)

	var region_hex = _find_hex(main_map, true)
	check(region_hex != null, "не найден неисследованный гекс Региона", state)
	if region_hex != null:
		check(not main_map.is_hex_in_fog(region_hex.row, region_hex.col),
			"неисследованный гекс Региона — не туман войны (Регион виден на карте)", state)

	var fog_hex = _find_hex(main_map, false)
	check(fog_hex != null, "не найден гекс тумана войны", state)
	if fog_hex == null:
		_finish(main_map, state)
		return

	check(main_map.is_hex_in_fog(fog_hex.row, fog_hex.col),
		"неисследованный гекс вне Региона должен быть туманом войны", state)
	city.unlocked_technologies.append("cartography")
	check(main_map.is_hex_in_fog(fog_hex.row, fog_hex.col),
		"«Картография» не должна снимать туман с гекса — его открывает разведка", state)

	# --- 2. Левая колонка панели: заглушка вместо информации ---
	main_map.select_hex(fog_hex.row, fog_hex.col)
	cp._refresh()
	var info_text: String = cp._info_label.text
	check(info_text.contains("не разведан"),
		"в левой колонке панели для туманного гекса должна быть заглушка (получено: %s)"
			% info_text, state)
	var tile: Dictionary = main_map.tile_data[fog_hex.row][fog_hex.col]
	var terrain_name: String = game_data.terrains.get(tile.terrain, {}).get("name", tile.terrain)
	check(not info_text.contains(terrain_name),
		"заглушка не должна раскрывать тип местности (%s)" % terrain_name, state)
	check(not info_text.contains("Местность:"),
		"заглушка не должна содержать строку «Местность:»", state)

	# Разведываем гекс — информация появляется.
	main_map.tile_data[fog_hex.row][fog_hex.col]["is_explored"] = true
	check(not main_map.is_hex_in_fog(fog_hex.row, fog_hex.col),
		"разведанный гекс не может быть в тумане войны", state)
	main_map.select_hex(fog_hex.row, fog_hex.col)
	cp._refresh()
	var revealed_text: String = cp._info_label.text
	check(revealed_text.contains("Местность:"),
		"после разведки левая колонка должна показывать местность", state)

	# --- 3. Страховка update_tooltip_text: для тумана ничего не пишет ---
	main_map.tile_data[fog_hex.row][fog_hex.col]["is_explored"] = false
	var tooltip_label = main_map.tooltip_text_label
	tooltip_label.text = "ПРОБА"
	main_map.update_tooltip_text(fog_hex.row, fog_hex.col)
	check(tooltip_label.text == "ПРОБА",
		"update_tooltip_text() не должен менять содержимое тултипа для туманного гекса", state)

	_finish(main_map, state)# Первый неисследованный гекс: в Регионе (in_region = true) или в тумане войны
# (in_region = false). Кольца влияния чужих городков пропускаем, чтобы взять
# «обычный» гекс.
func _find_hex(main_map, in_region: bool):
	for row in range(main_map.map_rows):
		for col in range(main_map.map_cols):
			var tile = main_map.tile_data[row][col]
			if tile == null:
				continue
			if bool(tile.get("in_influence", false)):
				continue
			if bool(tile.get("in_town_influence", false)):
				continue
			if bool(tile.get("is_explored", false)):
				continue
			if main_map.is_valid_hex(row, col) != in_region:
				continue
			return {"row": row, "col": col}
	return null

func _finish(main_map, state: Dictionary) -> void:
	if main_map != null and is_instance_valid(main_map):
		get_root().remove_child(main_map)
		main_map.free()
	if state["failed"]:
		print("FOG INFO TEST FAILED")
		quit(1)
	else:
		print("FOG INFO TEST OK")
		quit(0)

func check(cond: bool, msg: String, state: Dictionary):
	if not cond:
		push_error("ASSERT: " + msg)
		print("ASSERT FAILED: ", msg)
		state["failed"] = true