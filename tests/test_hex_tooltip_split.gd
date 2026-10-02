# Headless-тест разделения тултипа гекса на базовый и расширенный:
#   godot --headless --path . --script res://tests/test_hex_tooltip_split.gd
#
# Правило, которое проверяется: обычный тултип отвечает на вопрос «что на этом
# гексе» (местность, ресурс, улучшение), а свойства гекса — качество, расход
# корма, заполненность пастбища, доступ к пресной воде — и всё производство
# живут в расширенном блоке, который появляется по задержке наведения. Левая
# колонка панели управления показывает всё сразу и потому свойства сохраняет.
#
# Проверки:
#   1. БАЗОВЫЙ ТУЛТИП. Есть местность, ресурс и улучшение; ни одного свойства.
#   2. ЛЕВАЯ КОЛОНКА ПАНЕЛИ. Те же свойства на месте — иначе правка обнулила бы
#      панель управления.
#   3. РАСШИРЕННЫЙ БЛОК. Те же свойства есть в нём, и в нём НЕТ удалённого
#      базового блока «При постройке ... будет давать».
#   4. ПРОВЕРКА «ПОКАЗЫВАТЬ ЛИ» совпадает с непустотой блока.
#   5. РЕФРЕШ. Периодическое обновление содержимого (оно идёт по пастбищам) не
#      стирает уже показанный расширенный блок и не дописывает свойства в базу.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Признаки строк-свойств в русском каталоге. Проверяем по переводу, а не по
# английскому msgid: тест проверяет то, что видит игрок.
const PROPERTY_MARKERS := ["Качество:", "Доступ к пресной воде", "Потребляет корма",
        "Заполненность", "Время заполнения", "Поголовье"]
# Заполненность пастбища: какая именно строка выйдет, зависит от наличия
# рабочего (стало полным / текущий процент / время до полного).
const FILL_MARKERS := ["Заполненность", "Время заполнения", "Поголовье"]

var _gdata = null
var _mh = null

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame

    # Автозагрузки (GameData/MapHelpers) в режиме --script недоступны на этапе
    # компиляции этого файла — берём их через дерево сцены и load().
    _gdata = get_root().get_node("GameData")
    _mh = load("res://scripts/map_helpers.gd")

    var res_id := _find_pasture_resource_id()
    check(not res_id.is_empty(),
            "в данных нужен ресурс с кормом и постепенным наполнением (пастбище)",
            state)
    if res_id.is_empty():
        _finish(main_map, state)
        return
    var res_data: Dictionary = _gdata.raw_resources.get(res_id, {})
    var quality_id := _pick_quality_id()

    # Гекс в Кольце Влияния: свойства показываются только на освоенной земле.
    # Сначала ищем гекс С водой: иначе строка воды не появилась бы, и проверять
    # её было бы нечем.
    var spot := _find_hex_in_influence(main_map, true)
    var has_water := not spot.is_empty()
    if spot.is_empty():
        # На этой карте гекса с водой в кольце нет: берём любой и честно
        # строку воды не проверяем.
        spot = _find_hex_in_influence(main_map)
    check(not spot.is_empty(), "для проверки нужен гекс в Кольце Влияния", state)
    if spot.is_empty():
        _finish(main_map, state)
        return
    var row := int(spot.row)
    var col := int(spot.col)

    # Сценарий задаём явно, а не ждём случайную карту: у гекса появляются
    # улучшение, ресурс и качество — то есть ровно тот случай, где раньше
    # базовый тултип разрастался до семи строк.
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["improvement"] = str(res_data.get("improved_by", "pasture"))
    tile["resource"] = res_id
    tile["quality"] = quality_id
    tile["fill_time"] = float(res_data.get("time_to_mature", 40.0)) * 0.5

    var tooltip = main_map.map_tooltip

    # --- 1. Базовый тултип: только местность, ресурс, улучшение ---
    main_map.update_tooltip_text(row, col)
    var tip_text: String = str(main_map.tooltip_text_label.text)
    check(tip_text.contains("Местность:") and tip_text.contains("Ресурс:")
            and tip_text.contains("Улучшение:"),
            "базовый тултип должен содержать местность, ресурс и улучшение (получено: %s)"
                    % tip_text, state)
    _check_no_properties(tip_text, "базовом тултипе", state)

    # --- 2. Левая колонка панели управления: всё сразу ---
    var panel_info: Dictionary = tooltip.build_hex_info(row, col, main_map.tile_data,
            main_map.city_row, main_map.city_col)
    var panel_text: String = str(panel_info.get("text", ""))
    check(panel_text.contains("Качество:"),
            "в левой колонке панели качество ресурса должно остаться (получено: %s)"
                    % panel_text, state)
    check(panel_text.contains("Потребляет корма"),
            "в левой колонке панели расход корма должен остаться (получено: %s)"
                    % panel_text, state)
    check(_has_any(panel_text, FILL_MARKERS),
            "в левой колонке панели должна быть заполненность пастбища (получено: %s)"
                    % panel_text, state)

    # --- 3. Расширенный блок: свойства переехали в него ---
    var rows: Array = tooltip._collect_extended_block(row, col, main_map.tile_data)
    var ext_text := _rows_text(rows)
    check(ext_text.contains("Качество:"),
            "в расширенном блоке должно быть качество ресурса (получено: %s)" % ext_text,
            state)
    check(ext_text.contains("Потребляет корма"),
            "в расширенном блоке должен быть расход корма (получено: %s)" % ext_text,
            state)
    check(_has_any(ext_text, FILL_MARKERS),
            "в расширенном блоке должна быть заполненность пастбища (получено: %s)"
                    % ext_text, state)
    if has_water:
        check(ext_text.contains("Доступ к пресной воде"),
                "в расширенном блоке должен быть доступ к пресной воде (получено: %s)"
                        % ext_text, state)
    else:
        print("NOTE: на гексе нет доступа к пресной воде — строка воды не проверялась")
    # Базовый блок производства удалён: перенос, а не копипаст.
    check(not ext_text.contains("будет давать"),
            "удалённый базовый блок «будет давать» не должен вернуться (получено: %s)"
                    % ext_text, state)

    # --- 4. Проверка «показывать ли» совпадает с непустотой блока ---
    check(tooltip.has_extended_tooltip_info(row, col, main_map.tile_data) == (not rows.is_empty()),
            "has_extended_tooltip_info должен совпадать с непустотой расширенного блока",
            state)

    # --- 5. Рефреш не стирает расширенный блок ---
    main_map.update_extended_tooltip(row, col)
    var shown := _collect_text(tooltip._tooltip_products_container)
    check(shown.contains("Качество:"),
            "после показа расширенный блок должен содержать качество (получено: %s)"
                    % shown, state)
    # Меняем качество: строка меняется, ключ содержимого меняется, контейнер
    # перерисовывается — ровно тот путь, который идёт по пастбищам в игре.
    # Без реального изменения сработал бы ранний выход «ничего не изменилось»,
    # и проверка прошла бы, ничего не проверив.
    tile["quality"] = _next_quality_id(quality_id)
    main_map.update_tooltip_text(row, col)
    var after_refresh := _collect_text(tooltip._tooltip_products_container)
    check(after_refresh.contains("Качество:"),
            "после рефреша расширенный блок обязан остаться (получено: %s)" % after_refresh,
            state)
    check(_count_occurrences(after_refresh, "Качество:") == 1,
            "строка качества должна быть ровно одна (получено: %s)" % after_refresh, state)
    _check_no_properties(str(main_map.tooltip_text_label.text),
            "базовом тултипе после рефреша", state)

    # Сброс привязки (смена гекса / скрытие тултипа) — блока больше нет.
    main_map.clear_extended_tooltip()
    main_map.update_tooltip_text(row, col)
    check(not _collect_text(tooltip._tooltip_products_container).contains("Качество:"),
            "после сброса расширенного блока строки свойств быть не должно", state)

    _finish(main_map, state)

# Ресурс, у которого есть И корм, И постепенное наполнение, И улучшение.
# Берём из данных, а не хардкодим «cows»: проверка должна пережить переименование.
func _find_pasture_resource_id() -> String:
    for id in _gdata.raw_resources.keys():
        var data: Dictionary = _gdata.raw_resources.get(id, {})
        if not data.has("produces"):
            continue
        if str(data.get("improved_by", "")) == "":
            continue
        if not _mh.is_growing_resource(data):
            continue
        if int(data.get("feed_consumption", 0)) <= 0:
            continue
        # Скрытый за технологией ресурс не годится: игрок его не видит.
        if str(data.get("tech_reveal", "")) != "":
            continue
        return str(id)
    return ""

func _pick_quality_id() -> String:
    var levels: Array = _gdata.get_quality_levels()
    if levels.is_empty():
        return ""
    return str(levels[levels.size() - 1])

func _next_quality_id(current: String) -> String:
    var levels: Array = _gdata.get_quality_levels()
    for i in range(levels.size()):
        if str(levels[i]) == current:
            return str(levels[(i + levels.size() - 1) % levels.size()])
    return str(levels[0])

# Первый свободный гекс в Кольце Влияния: сухой, известный, без улучшения,
# городка и чужой территории.
func _find_hex_in_influence(main_map, prefer_water: bool = false) -> Dictionary:
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[row][col]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if prefer_water and str(_mh.get_hex_water_access(row, col,
                    main_map.tile_data, main_map.map_rows, main_map.map_cols)) == "":
                continue
            if tile.get("has_town", false) or tile.get("in_town_influence", false):
                continue
            if not main_map.is_hex_known(row, col):
                continue
            if _mh.is_water_terrain(tile.get("terrain", "plain")):
                continue
            if row == main_map.city_row and col == main_map.city_col:
                continue
            return {"row": row, "col": col}
    return {}

func _rows_text(rows: Array) -> String:
    var parts: Array[String] = []
    for item in rows:
        if not (item is Dictionary):
            continue
        if item.has("text"):
            parts.append(str(item["text"]))
        if item.has("name"):
            parts.append(str(item["name"]))
    return "\n".join(parts)

func _collect_text(node: Node) -> String:
    if node == null:
        return ""
    var parts: Array[String] = []
    if node is Label:
        parts.append((node as Label).text)
    elif node is RichTextLabel:
        parts.append(str((node as RichTextLabel).text))
    for child in node.get_children():
        parts.append(_collect_text(child))
    return "\n".join(parts)

func _check_no_properties(text: String, where: String, state: Dictionary) -> void:
    for marker in PROPERTY_MARKERS:
        check(not text.contains(marker),
                "в %s не должно быть строки-свойства «%s» (получено: %s)"
                        % [where, marker, text], state)

func _has_any(text: String, markers: Array) -> bool:
    for marker in markers:
        if text.contains(marker):
            return true
    return false

func _count_occurrences(text: String, sub: String) -> int:
    if sub.is_empty():
        return 0
    var count := 0
    var pos := text.find(sub)
    while pos != -1:
        count += 1
        pos = text.find(sub, pos + sub.length())
    return count

func _finish(main_map, state: Dictionary) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("HEX TOOLTIP SPLIT TEST FAILED")
        quit(1)
    else:
        print("HEX TOOLTIP SPLIT TEST OK")
        quit(0)

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    print("FAILED: %s" % message)
    push_error("ASSERT: %s" % message)
