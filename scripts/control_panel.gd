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
    pass

# Текущее выделение и превью.
var _selected_hex = null # { "row": int, "col": int }
var _preview_action = null # { "type": String, "imp_id": String, "target_res_id": String, "label": String }

# Ссылки на дочерние узлы UI.
var _info_label: Label
var _products_container: VBoxContainer
var _actions_container: FlowContainer
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

    _info_label = $InfoVBox/InfoScroll/InfoContent/InfoLabel
    _products_container = $InfoVBox/InfoScroll/InfoContent/ProductsContainer
    _actions_container = $ActionsVBox/ActionsScroll/ActionsContent/ActionsContainer
    _preview_container = $PreviewContainer/PreviewScroll/PreviewContent

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
        btn.custom_minimum_size = Vector2(32, 32) # маленькая квадратная кнопка
        # Тултип сохраняется — это единственный способ узнать, что делает кнопка.
        btn.tooltip_text = action.get("tooltip", "")
        btn.disabled = not action.get("enabled", true)
        # Иконка действия; если её нет или файл не найден — знак вопроса.
        var tex = _load_action_icon(action.get("icon", ""))
        if tex != null:
            btn.icon = tex
            btn.expand_icon = true
            btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
        else:
            btn.text = "?"
            if not action.get("enabled", true):
                btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
                btn.add_theme_color_override("font_disabled_color", Color(0.5, 0.5, 0.5))
        var action_data = action
        btn.pressed.connect(func():
            _on_action_pressed(action_data)
        )
        _actions_container.add_child(btn)

# Загружает Texture2D для имени файла иконки действия через индекс иконок
# map_renderer (тот же индекс, что используют тултип и отрисовка карты).
# Возвращает null, если имя пустое или файл не найден (тогда кнопка покажет «?»).
func _load_action_icon(icon_name: String) -> Texture2D:
    if icon_name.is_empty() or main_map == null or main_map.map_renderer == null:
        return null
    var path: String = main_map.map_renderer.get_icon_path(icon_name)
    if path.is_empty() or not FileAccess.file_exists(path):
        return null
    return load(path)

# Сравнивает два списка действий (по значимым полям, чтобы у неработающего
# поля type/imp_id не пересоздавались кнопки вхолостую).
func _actions_equal(a: Array, b: Array) -> bool:
    if a.size() != b.size():
        return false
    for i in range(a.size()):
        var x: Dictionary = a[i]
        var y: Dictionary = b[i]
        for key in ["type", "label", "enabled", "tooltip", "imp_id", "action_id", "target_res_id", "icon", "tech_id"]:
            if x.get(key, null) != y.get(key, null):
                return false
    return true

# Собирает список действий для гекса. Каждый элемент:
#   { "type": String, "label": String, "enabled": bool, "tooltip": String,
#     "imp_id": String, "target_res_id": String, "action_id": String }
# type: "build_improvement" | "build_pasture" | "build_farm" | "special" |
#       "pause_improvement" | "resume_improvement" | "cancel_build" |
#       "research_tech"
func _collect_actions(row: int, col: int, tile: Dictionary) -> Array:
    var actions := []
    var in_influence = tile.get("in_influence", false)

    # На гексе города строить улучшения нельзя — никаких действий.
    if row == main_map.city_row and col == main_map.city_col:
        return actions

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
                "tooltip": "Снять рабочего с улучшения",
                "icon": "building_pause.png"
            })
        else:
            actions.append({
                "type": "resume_improvement",
                "label": "Запустить работу (%s)" % imp_name,
                "enabled": CityData.idle_population > 0,
                "tooltip": "Назначить рабочего на улучшение" if CityData.idle_population > 0 else "Нет свободных рабочих",
                "icon": "building_resume.png"
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
            # Проверка: ресурс скрыт tech_reveal-гейтом. Действие НЕ показываем
            # вовсе (ни кнопки, ни тултипа): игрок не должен знать, где
            # находится скрытый ресурс, пока не откроет соответствующую технологию.
            if not MapHelpers.is_resource_revealed(tile):
                # Скрытый ресурс: никаких действий и подсказок на этом гексе.
                pass
            else:
                # Проверка: технология для улучшения.
                if not CityData.is_improvement_unlocked(imp_id):
                    var unlock_tech = CityData.get_improvement_unlock_tech(imp_id)
                    var tech_name = _get_tech_name(unlock_tech)
                    enabled = false
                    tooltip = "%s — нужна технология: %s" % [imp_name, tech_name]
                    # Кнопка изучения технологии (аналог пункта «Изучить X»
                    # в контекстном меню по ПКМ).
                    actions.append(_make_research_action(unlock_tech))
                # Проверка: ресурс требует технологию (tech_required).
                elif raw.get("tech_required", "") != "" and not CityData.is_tech_unlocked(raw["tech_required"]):
                    var raw_name = raw.get("name", tile.resource)
                    var tech_name2 = _get_tech_name(raw["tech_required"])
                    enabled = false
                    tooltip = "%s (%s) — нужна технология: %s" % [imp_name, raw_name, tech_name2]
                    actions.append(_make_research_action(raw["tech_required"]))
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
                    "target_res_id": tile.resource,
                    "icon": GameData.improvements.get(imp_id, {}).get("icon", "")
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
                pasture_tooltip = "Пастбище — нужна технология: %s" % _get_tech_name(unlock_tech)
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
                    "imp_id": "pasture",
                    "icon": GameData.improvements.get("pasture", {}).get("icon", "")
                })
        # Ферма.
        if CityData.domesticated_plants.size() > 0:
            var farm_unlocked = CityData.is_improvement_unlocked("farm")
            var farm_enabled = farm_unlocked
            var farm_tooltip = "Построить ферму для одомашненного растения"
            if not farm_unlocked:
                var unlock_tech = CityData.get_improvement_unlock_tech("farm")
                farm_tooltip = "Ферма — нужна технология: %s" % _get_tech_name(unlock_tech)
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
                    "imp_id": "farm",
                    "icon": GameData.improvements.get("farm", {}).get("icon", "")
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
            tooltip = "%s — нужна технология: %s" % [sa_name, _get_tech_name(unlock_tech)]
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

# Формирует действие «Изучить технологию» для колонки действий панели.
func _make_research_action(tech_id: String) -> Dictionary:
    var tech_name = _get_tech_name(tech_id)
    var tech_cost = 3
    for t in GameData.technologies:
        if t["id"] == tech_id:
            tech_cost = int(t.get("science_cost", 3))
            break
    return {
        "type": "research_tech",
        "label": "Изучить %s" % tech_name,
        "enabled": true,
        "tooltip": "Изучить %s (наука: %d)" % [tech_name, tech_cost],
        "tech_id": tech_id,
        "icon": "lock.png"
    }

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
    if type == "research_tech":
        # Аналог пункта «Изучить X» в контекстном меню (ПКМ): мгновенный старт
        # исследования. Ошибки (уже идёт исследование и т.п.) start_research
        # сообщает сама через сигнал research_error → hud.show_message.
        CityData.start_research(action.get("tech_id", ""))
        main_map.map_renderer.queue_redraw()
        _refresh()
        return

    # Повторное нажатие на кнопку действия, чьё превью уже открыто,
    # работает как «отмена» (закрывает превью).
    if _preview_action != null \
            and _preview_action.get("type", "") == type \
            and _preview_action.get("imp_id", "") == action.get("imp_id", "") \
            and _preview_action.get("action_id", "") == action.get("action_id", "") \
            and _preview_action.get("target_res_id", null) == action.get("target_res_id", null):
        clear_preview()
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
        "eff_res": eff_res_for_preview,
        "selected_culture_id": null
    }
    _refresh()

# --- Построение предпросмотра действия ---
func _build_preview(row: int, col: int, tile: Dictionary):
    var preview = _preview_action

    # Если предпросмор для этого гекса и этого действия уже построен — не
    # пересоздаём элементы (в т.ч. кнопки «Начать»/«Отменить» с их
    # ОС-тултипами). Иначе они сбрасывались бы каждый игровой тик.
    var snapshot = {
        "row": row,
        "col": col,
        "type": preview.get("type", ""),
        "label": preview.get("label", ""),
        "imp_id": preview.get("imp_id", ""),
        "action_id": preview.get("action_id", ""),
        "target_res_id": preview.get("target_res_id", null),
        "eff_res": preview.get("eff_res", ""),
        "selected_culture_id": preview.get("selected_culture_id", null)
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

    # Заголовок предпросмотра.
    var header = Label.new()
    header.text = "%s" % preview.get("label", "")
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
                # При активных модификаторах база указывается у каждого продукта.
                if bonus_multiplier != 1.0:
                    var base_str = str(int(base_amount)) if base_amount == floor(base_amount) else "%.1f" % base_amount
                    prod_name = "%s (база %s)" % [prod_name, base_str]
                var icon_path = ""
                var prod_data = GameData.products.get(prod_id, {})
                if prod_data.has("icon"):
                    var icon_name = prod_data["icon"]
                    icon_path = main_map.map_renderer.get_icon_path(icon_name)
                products.append({"type": "product", "name": prod_name, "amount": final_amount, "icon_path": icon_path})
            for mod in modifiers:
                products.append({"type": "label", "text": " %s" % mod.get("label", ""), "color": Color(0.7, 0.9, 0.7)})
            map_tooltip.render_products(products, _preview_container)

    # Стоимость труда: детальный расчёт (база, местность, расстояние).
    var cost_data = MapHelpers.get_improvement_work_cost(cost_imp_id, row, col, main_map.tile_data, main_map.city_row, main_map.city_col)
    var cost_label = Label.new()
    cost_label.text = "Стоимость: %d труда" % cost_data["cost"]
    cost_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(cost_label)

    # Детализация стоимости (переехала сюда из расширенного тултипа).
    var base_label = Label.new()
    base_label.text = " База: %d труда" % cost_data["base_cost"]
    base_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(base_label)

    var move_cost_text = "непроходимо" if cost_data["move_cost"] >= 999.0 else str(int(cost_data["move_cost"]))
    var terrain_label = Label.new()
    terrain_label.text = " Местность: %s (стоимость передвижения: %s) ×%.2f" % [cost_data["terrain_name"], move_cost_text, cost_data["terrain_mult"]]
    terrain_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(terrain_label)

    var dist_label = Label.new()
    # Расчёт множителя расстояния: исходный (1 + гексов × 0.25) плюс
    # влияние изученных технологий (например, «Колесо» -30%).
    var dist_text: String = " Расстояние до города: %d гекс(а) → база ×%.2f" % [cost_data["distance"], cost_data["distance_mult_base"]]
    if cost_data.has("distance_tech_mult") and cost_data["distance_tech_mult"] != 1.0:
        dist_text += ", технологии ×%.2f" % cost_data["distance_tech_mult"]
    dist_text += " = ×%.2f" % cost_data["distance_mult"]
    dist_label.text = dist_text
    dist_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(dist_label)

    var total_label = Label.new()
    total_label.text = " Итого: %d труда" % cost_data["cost"]
    total_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(total_label)

    # --- Для ферм/пастбищ: выбор конкретной культуры ---
    # Если на гексе можно выращивать/разводить несколько одомашненных видов,
    # даём выбрать, под какую именно культуру строить. Иначе строится
    # единственная подходящая культура (текущее поведение).
    if type == "build_farm" or type == "build_pasture":
        var imp_kind = "farm" if type == "build_farm" else "pasture"
        var crops := _get_suitable_crops(row, col, imp_kind)
        if crops.size() > 1:
            # По умолчанию предвыбираем первую культуру из списка.
            var selected = preview.get("selected_culture_id", null)
            if selected == null:
                selected = crops[0].id
                preview["selected_culture_id"] = selected

            var cult_label = Label.new()
            cult_label.text = "Культура:"
            cult_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
            _preview_container.add_child(cult_label)

            # Кнопки культур идут горизонтальным рядом с переносом строк.
            var cult_flow = FlowContainer.new()
            cult_flow.add_theme_constant_override("h_separation", 4)
            cult_flow.add_theme_constant_override("v_separation", 4)
            _preview_container.add_child(cult_flow)

            for cult in crops:
                var cult_btn = Button.new()
                cult_btn.custom_minimum_size = Vector2(32, 32) # квадратная кнопка с иконкой
                # Тултип — название ресурса (иконка без подписи).
                cult_btn.tooltip_text = cult.get("name", cult.id)
                # Иконка одомашненного вида; если её нет — знак вопроса.
                var cult_icon = GameData.raw_resources.get(cult.id, {}).get("icon", "")
                var cult_tex = _load_action_icon(cult_icon)
                if cult_tex != null:
                    cult_btn.icon = cult_tex
                    cult_btn.expand_icon = true
                    cult_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
                else:
                    cult_btn.text = "?"
                cult_btn.toggle_mode = true
                cult_btn.set_pressed_no_signal(cult.id == selected)
                # Явная рамка у выбранной культуры.
                var pressed_style = StyleBoxFlat.new()
                pressed_style.set_border_width_all(2)
                pressed_style.border_color = Color(1.0, 0.85, 0.2) # жёлтая рамка
                cult_btn.add_theme_stylebox_override("pressed", pressed_style)
                cult_btn.add_theme_stylebox_override("hover_pressed", pressed_style)
                cult_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
                var cid = cult.id
                cult_btn.pressed.connect(func():
                    _select_preview_culture(cid)
                )
                cult_flow.add_child(cult_btn)

    # Кнопки «Начать» и «Отменить».
    var hbox = HBoxContainer.new()
    var build_btn = Button.new()
    build_btn.text = "Начать"
    build_btn.custom_minimum_size = Vector2(0, 28)
    build_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    build_btn.pressed.connect(func():
        _confirm_build()
    )
    hbox.add_child(build_btn)
    var cancel_btn = Button.new()
    cancel_btn.text = "Отменить"
    cancel_btn.custom_minimum_size = Vector2(0, 28)
    cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
        and a.get("eff_res", "") == b.get("eff_res", "") \
        and a.get("selected_culture_id", null) == b.get("selected_culture_id", null)

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
        # Строим пастбище под выбранное животное; если оно не задано/не подходит —
        # берём первое подходящее.
        var chosen_animal = preview.get("selected_culture_id", null)
        if not _is_suitable_culture(row, col, chosen_animal, "pasture"):
            chosen_animal = _first_suitable_culture(row, col, "pasture")
        if chosen_animal != null:
            build_manager.start_build(row, col, "pasture", chosen_animal)
    elif type == "build_farm":
        var chosen_plant = preview.get("selected_culture_id", null)
        if not _is_suitable_culture(row, col, chosen_plant, "farm"):
            chosen_plant = _first_suitable_culture(row, col, "farm")
        if chosen_plant != null:
            build_manager.start_build(row, col, "farm", chosen_plant)
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

# Возвращает список одомашненных культур (растений для ферм или животных для
# пастбищ), которые можно выращивать/разводить на гексе (row, col).
# Каждый элемент: { "id": String, "name": String }.
func _get_suitable_crops(row: int, col: int, imp_kind: String) -> Array:
    var tile = main_map.get_tile_data(row, col)
    var tile_cover = tile.get("cover", "none")
    var ids: Array
    if imp_kind == "farm":
        ids = CityData.domesticated_plants
    else:
        ids = CityData.domesticated_animals
    var out := []
    for id in ids:
        var data = GameData.raw_resources.get(id, {})
        if tile.terrain in data.get("allowed_terrain", []) and tile_cover in data.get("allowed_cover", []):
            out.append({"id": id, "name": data.get("name", id)})
    return out

# Возвращает true, если культура (растение/животное) подходит для гекса (row, col)
# и входит в одомашненные виды указанного типа (farm/pasture).
func _is_suitable_culture(row: int, col: int, id, imp_kind: String) -> bool:
    if id == null or id == "":
        return false
    var tile = main_map.get_tile_data(row, col)
    var tile_cover = tile.get("cover", "none")
    var data = GameData.raw_resources.get(id, {})
    if data.is_empty():
        return false
    var ids: Array
    if imp_kind == "farm":
        ids = CityData.domesticated_plants
    else:
        ids = CityData.domesticated_animals
    if not (id in ids):
        return false
    return tile.terrain in data.get("allowed_terrain", []) and tile_cover in data.get("allowed_cover", [])

# Возвращает id первого одомашненного вида, подходящего для гекса, или null.
func _first_suitable_culture(row: int, col: int, imp_kind: String):
    var crops := _get_suitable_crops(row, col, imp_kind)
    if crops.is_empty():
        return null
    return crops[0].id

# Выбирает культуру в активном превью (ферма/пастбище) и пересобирает блок,
# чтобы подсветка выбранной кнопки обновилась.
func _select_preview_culture(id: String):
    if _preview_action != null:
        _preview_action["selected_culture_id"] = id
    _refresh()
