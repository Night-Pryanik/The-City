class_name MapTooltip

var _tooltip_text_label: Label
var _tooltip_products_container: VBoxContainer
var _map_renderer
var _worker_manager
# Ключ последнего отрисованного списка продукции тултипа (для сравнения
# при периодическом обновлении — чтобы не пересобирать UI без изменений).
var _last_products_key := ""

func _init(tooltip_text_label: Label, tooltip_products_container: VBoxContainer, map_renderer, worker_manager):
    _tooltip_text_label = tooltip_text_label
    _tooltip_products_container = tooltip_products_container
    _map_renderer = map_renderer
    _worker_manager = worker_manager


# --- Общий рендер списка продуктов ---
# products — массив словарей:
#   { "type": "header",  "text": String }
#   { "type": "product", "name": String, "amount": int, "icon_path": String }
#   { "type": "label",   "text": String, "color": Color }
# Используется и тултипом, и панелью управления (control_panel.gd), чтобы
# отображение производства не расходилось.
# wrap — включает перенос слов на следующую строку, если текст не помещается
# в одну строку (панель управления передаёт true, тултип — нет).
func render_products(products: Array, container: Node, wrap: bool = false):
    var wrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap else TextServer.AUTOWRAP_OFF
    for child in container.get_children():
        # free(), а не queue_free(): немедленное удаление исключает кадр, когда
        # в контейнере одновременно висят старые и новые элементы — иначе
        # высота списка прыгала на один кадр при каждом обновлении.
        child.free()
    for item in products:
        var type = item.get("type", "label")
        if type == "header":
            var label = Label.new()
            label.text = item.get("text", "")
            label.autowrap_mode = wrap_mode
            label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
            container.add_child(label)
        elif type == "product":
            var hbox = HBoxContainer.new()
            var icon_path = item.get("icon_path", "")
            if icon_path != "":
                var tex_rect = TextureRect.new()
                tex_rect.texture = load(icon_path)
                tex_rect.custom_minimum_size = Vector2(20, 20)
                tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                tex_rect.stretch_mode = TextureRect.STRETCH_SCALE
                hbox.add_child(tex_rect)
            var label_item = Label.new()
            # Если у элемента задан color — используем его (для подсветки
            # потребления, когда на складе не хватает ресурса). Иначе —
            # обычный белый. Если amount == 0, выводим только подпись
            # (используется для строк потребления, где важна не цифра, а текст).
            var amount_val = int(item.get("amount", 0))
            if amount_val > 0:
                label_item.text = "%s: %d" % [item.get("name", ""), amount_val]
            else:
                label_item.text = item.get("name", "")
            var item_color: Color = item.get("color", Color.WHITE)
            label_item.add_theme_color_override("font_color", item_color)
            hbox.add_child(label_item)
            container.add_child(hbox)
        else:
            var label = Label.new()
            label.text = item.get("text", "")
            label.autowrap_mode = wrap_mode
            label.add_theme_color_override("font_color", item.get("color", Color(0.8, 0.8, 0.8)))
            container.add_child(label)


# --- Полная информация о гексе для панели управления ---
# Возвращает { "text": String, "products": Array }.
# text — полный текст (как в тултипе), products — расширенное производство
# с модификаторами. Панель показывает всё сразу, без задержки наведения.
func build_hex_info(row: int, col: int, tile_data: Array, city_row: int = 0, city_col: int = 0) -> Dictionary:
    var text = _build_text(row, col, tile_data, city_row, city_col)
    var products = _collect_extended_production(row, col, tile_data)
    return {"text": text, "products": products}


func update_tooltip_text(row: int, col: int, tile_data: Array, city_row: int = 0, city_col: int = 0):
    var text = _build_text(row, col, tile_data, city_row, city_col)

    var tile = tile_data[row][col]
    var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)
    var terrain_data = GameData.terrains.get(tile.terrain, {})
    var products = []
    if terrain_data.get("unique", false) and not is_revealed:
        pass # products остаются пустыми — см. проверку ниже
    elif not is_revealed:
        pass
    else:
        var res_id = MapHelpers.get_effective_resource(tile)
        # Скрытый ресурс не показываем — как будто его на гексе нет.
        if res_id != "" and not MapHelpers.is_resource_revealed(tile):
            res_id = ""
        if tile.improvement != null:
            if res_id != "":
                var res_data = GameData.raw_resources.get(res_id, {})
                if res_data.has("produces"):
                    products = _collect_production(row, col, res_id, " Производит:", tile_data)
        else:
            if res_id != "":
                var res_data = GameData.raw_resources.get(res_id, {})
                if res_data.has("improved_by") and res_data.has("produces"):
                    var improvement_id = res_data["improved_by"]
                    var imp_data = GameData.improvements.get(improvement_id, {})
                    var imp_name_display = imp_data.get("name", improvement_id)
                    products = _collect_production(row, col, res_id, " При постройке %s будет давать:" % imp_name_display, tile_data)

    # Обновляем UI только при РЕАЛЬНОМ изменении содержимого. Периодический
    # рефреш (заполенность пастбища) вызывает эту функцию несколько раз в
    # секунду: полная пересборка контейнера каждый раз выглядела как рывки.
    var products_key = var_to_str(products)
    if text == _tooltip_text_label.text \
            and products_key == _last_products_key \
            and _tooltip_products_container.get_child_count() == products.size():
        return

    for child in _tooltip_products_container.get_children():
        # free(), а не queue_free(): немедленное удаление исключает кадр,
        # когда в контейнере одновременно висят старые и новые элементы
        # (иначе размер тултипа прыгал на один кадр).
        child.free()

    _tooltip_text_label.text = text
    render_products(products, _tooltip_products_container)
    _last_products_key = products_key


func has_extended_tooltip_info(row: int, col: int, tile_data: Array) -> bool:
    var tile = tile_data[row][col]
    var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)
    if not is_revealed:
        return false

    # Расширенный тултип показываем, если на гексе идёт активное производство:
    # улучшение построено, рабочий назначен, и на гексе есть «эффективный»
    # ресурс (природный или разводимый) с produces.
    var eff_res = MapHelpers.get_effective_resource(tile)
    # Скрытый ресурс не учитываем — информации о нём быть не должно.
    if eff_res != "" and not MapHelpers.is_resource_revealed(tile):
        eff_res = ""
    if tile.improvement != null and eff_res != "" and _worker_manager.has_worker(row, col):
        var res_data = GameData.raw_resources.get(eff_res, {})
        if res_data.has("produces"):
            var bonus_multiplier = CityData.get_improvement_production_multiplier(tile.improvement, MapHelpers.is_hex_irrigated(row, col, tile_data, tile_data.size(), tile_data[0].size()), tile.get("terrain", ""), eff_res)
            if bonus_multiplier > 1.0:
                return true

    # Показываем расширенный тултип и при наличии профессионального потребления
    # у работающего улучшения: рыбак тратит тростниковые лодки, шахтёр — патроны
    # и т.п. Эту инфу важно показать ДО того, как игрок начнёт замечать
    # «улучшение встало без видимых причин» в логах.
    if tile.improvement != null and _worker_manager.has_worker(row, col):
        var prof_id = GameData.get_profession_for_improvement(tile.improvement)
        if not prof_id.is_empty():
            if not GameData.get_profession_consumption(prof_id).is_empty():
                return true

    # Стоимость постройки в расширенном тултипе больше не показывается —
    # расчёты перенесены в Превью панели управления.

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

    # Расчёты стоимости постройки (база/местность/расстояние) перенесены
    # в Превью панели управления — здесь они больше не показываются.

    var res_id = MapHelpers.get_effective_resource(tile)
    # Скрытый ресурс не показываем — как будто его на гексе нет.
    if res_id != "" and not MapHelpers.is_resource_revealed(tile):
        res_id = ""
    if res_id == "":
        return
    var res_data = GameData.raw_resources.get(res_id, {})
    if not res_data.has("produces"):
        return

    render_products(_collect_extended_production(row, col, tile_data), _tooltip_products_container)


# --- Построение полного текста тултипа ---
# Вынесено из update_tooltip_text, чтобы панель управления (control_panel.gd)
# могла показывать ту же информацию без дублирования кода.
func _build_text(row: int, col: int, tile_data: Array, city_row: int = 0, city_col: int = 0) -> String:
    var tile = tile_data[row][col]
    var terrain_name = GameData.terrains.get(tile.terrain, {}).get("name", tile.terrain)
    var cover_id = tile.get("cover", "none")

    var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)
    # Эффективный ресурс: природный (tile.resource) или разводимый (tile.crop_bred).
    var res_id = MapHelpers.get_effective_resource(tile)
    # Скрытый ресурс (tech_reveal не изучен): игроку о нём знать нельзя —
    # показываем гекс как пустой (без названия ресурса, улучшения и выхода).
    if res_id != "" and not MapHelpers.is_resource_revealed(tile):
        res_id = ""
    var res_name = "нет"
    if res_id != "":
        res_name = GameData.raw_resources.get(res_id, {}).get("name", res_id)

    var cover_name_lower = ""
    if cover_id != "none":
        cover_name_lower = GameData.covers.get(cover_id, {}).get("name", cover_id).to_lower()
    var terrain_with_cover = terrain_name
    if cover_name_lower != "":
        terrain_with_cover = "%s, %s" % [terrain_name, cover_name_lower]

    var terrain_data = GameData.terrains.get(tile.terrain, {})
    if terrain_data.get("unique", false) and not is_revealed:
        var desc = terrain_data.get("description", "")
        return desc if desc != "" else terrain_name

    if not is_revealed:
        return "Местность: %s\nРесурс: неизвестно (проведите разведку)" % terrain_with_cover

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
    var prof_id := ""
    if tile.improvement != null:
        var has_worker = _worker_manager.has_worker(row, col)
        if not has_worker:
            imp_status = " (неактивно: нет рабочего)"
        else:
            imp_status = " (работает)"
            # Профессия рабочего: определяется улучшением, на которое он назначен.
            # Метка ставится автоматически при назначении и снимается при
            # увольнении (см. worker_manager.gd, assign_worker / remove_worker).
            # Игрок метками не управляет.
            prof_id = GameData.get_profession_for_improvement(tile.improvement)
    else:
        if res_id != "":
            var res_data = GameData.raw_resources.get(res_id, {})
            if res_data.has("improved_by") and res_data.has("produces"):
                imp_status = " (не построено)"

    if res_id != "":
        var res_data = GameData.raw_resources.get(res_id, {})
        var feed_consumption = res_data.get("feed_consumption", 0)
        if feed_consumption > 0:
            text += "\nПотребляет корма: %d за цикл" % feed_consumption
        var time_to_mature = res_data.get("time_to_mature", 0)
        if time_to_mature > 0:
            # Растущий ресурс (животные на пастбище): показываем текущую
            # заполенность и остаток времени, если улучшение уже работает.
            if tile.improvement != null and _worker_manager.has_worker(row, col):
                var fill_frac = MapHelpers.get_fill_fraction(tile, res_data)
                if fill_frac >= 1.0:
                    text += "\nПоголовье: полное (100%)"
                else:
                    var t_left = MapHelpers.get_time_to_full(tile, res_data)
                    text += "\nЗаполненность: %d%% (полное через %.0f сек)" % [roundi(fill_frac * 100), ceilf(t_left)]
            else:
                text += "\nВремя заполнения: %.0f сек" % time_to_mature

    text += "\nУлучшение: %s%s" % [imp_name, imp_status]

    # Профессия: показываем ТОЛЬКО если есть рабочий и у улучшения есть профессия.
    # Это и есть «метка», которую житель получает при назначении на работу.
    if not prof_id.is_empty():
        var prof_name = GameData.get_profession_name(prof_id)
        text += "\nПрофессия рабочего: %s" % prof_name

    # Доступ к пресной воде показываем для ВСЕХ гексов.
    var water_access = MapHelpers.get_hex_water_access(row, col, tile_data, tile_data.size(), tile_data[0].size())
    if water_access == "direct":
        text += "\nДоступ к пресной воде: прямой"
    elif water_access == "chain":
        text += "\nДоступ к пресной воде: по цепочке"

    # --- Конфликт «tech_reveal-ресурс под чужим улучшением» ---
    var conflict = MapHelpers.get_tech_reveal_conflict(tile)
    if not conflict.is_empty():
        var current_imp_name: String = GameData.improvements.get(tile.improvement, {}).get("name", tile.improvement)
        text += "\n\nЗдесь обнаружено: %s" % conflict.get("res_name", "")
        text += "\nСнесите %s, чтобы построить %s" % [current_imp_name, conflict.get("imp_name", "")]

    # Стоимость постройки в тултипе/левой панели больше не показывается —
    # расчёты перенесены в Превью панели управления.

    return text


# --- Сбор базового производства (для hover-тултипа) ---
func _collect_production(row: int, col: int, res_id: String, prefix: String, tile_data: Array) -> Array:
    var result = []
    if res_id == "":
        return result
    var res_data = GameData.raw_resources.get(res_id, {})
    if not res_data.has("produces"):
        return result

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
        return result

    result.append({"type": "header", "text": prefix})

    for prod_id in final_amounts:
        var amount = final_amounts[prod_id].final
        var prod_name = GameData.products.get(prod_id, {}).get("name", prod_id)
        var icon_path = ""
        var prod_data = GameData.products.get(prod_id, {})
        if prod_data.has("icon"):
            var icon_name = prod_data["icon"]
            icon_path = _map_renderer.get_icon_path(icon_name)
        result.append({"type": "product", "name": prod_name, "amount": amount, "icon_path": icon_path})

    return result


# --- Сбор расширенного производства (с модификаторами) ---
func _collect_extended_production(row: int, col: int, tile_data: Array) -> Array:
    var result = []
    var tile = tile_data[row][col]
    var eff_res = MapHelpers.get_effective_resource(tile)
    # Скрытый ресурс (tech_reveal не изучен): производства не показываем —
    # иначе подсказка «При постройке X будет давать…» выдала бы его наличие.
    if eff_res != "" and not MapHelpers.is_resource_revealed(tile):
        eff_res = ""
    if eff_res == "":
        return result
    var res_data = GameData.raw_resources.get(eff_res, {})
    if not res_data.has("produces"):
        return result

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
        return result

    var header_text = "Производит:"
    if tile.improvement == null:
        var improvement_id = res_data.get("improved_by", "")
        var imp_name_display = GameData.improvements.get(improvement_id, {}).get("name", improvement_id)
        header_text = "При постройке %s будет производить:" % imp_name_display
    result.append({"type": "header", "text": header_text})

    # Растущие ресурсы: пока пастбище заполняется, фактический выход
    # пропорционален степени заполненности стада.
    var fill_frac = MapHelpers.get_fill_fraction(tile, res_data)

    var base_amount = 0.0
    var final_amount = 0
    for prod_id in available_products:
        base_amount = float(available_products[prod_id])
        final_amount = ceili(base_amount * bonus_multiplier * fill_frac)
        var prod_name = GameData.products.get(prod_id, {}).get("name", prod_id)
        # При активных модификаторах показываем базу у каждого продукта
        # (у разных продуктов она своя, одна общая строка «База» вводила в заблуждение).
        if bonus_multiplier != 1.0 or fill_frac != 1.0:
            var base_str = str(int(base_amount)) if base_amount == floor(base_amount) else "%.1f" % base_amount
            prod_name = "%s (база %s)" % [prod_name, base_str]
        var icon_path = ""
        var prod_data = GameData.products.get(prod_id, {})
        if prod_data.has("icon"):
            var icon_name = prod_data["icon"]
            icon_path = _map_renderer.get_icon_path(icon_name)
        result.append({"type": "product", "name": prod_name, "amount": final_amount, "icon_path": icon_path})

    for mod in modifiers:
        result.append({"type": "label", "text": " %s" % mod.get("label", ""), "color": Color(0.7, 0.9, 0.7)})

    # --- Потребление профессии ---
    # Показываем список ресурсов, которые профессия рабочего на этом гексе
    # расходует со склада. Источник: поле consumption у продуктов (см. docs.md).
    # Секция появляется только если:
    #   1) улучшение построено,
    #   2) на нём есть рабочий,
    #   3) улучшение имеет профессию,
    #   4) у этой профессии есть хотя бы один потребитель.
    # Само производство улучшения при нехватке ресурса НЕ останавливается —
    # оно откатывается к базовому множителю (без бонуса).
    if tile.improvement != null and _worker_manager.has_worker(row, col):
        var prof_id = GameData.get_profession_for_improvement(tile.improvement)
        if not prof_id.is_empty():
            var cons_list = GameData.get_profession_consumption(prof_id)
            if not cons_list.is_empty():
                result.append({"type": "header", "text": "Потребляет:"})
                for entry in cons_list:
                    var cons_pid = entry.get("product_id", "")
                    var cons_name = entry.get("product_name", cons_pid)
                    var cons_amount = int(entry.get("amount", 0))
                    var cons_interval = float(entry.get("interval", 0))
                    # Подпись строки потребления: «<имя>: <N> шт./<S> сек».
                    # Если задан production_bonus — добавляем «+N% к производству»,
                    # чтобы игрок видел, зачем профессии этот расходник.
                    var cons_bonus: float = float(entry.get("production_bonus", 0.0))
                    var cons_label := "%s: %d шт./%d сек" % [
                        cons_name, cons_amount, int(round(cons_interval))
                    ]
                    if cons_bonus > 0.0:
                        var bonus_pct := int(round(cons_bonus * 100.0))
                        cons_label += " (+%d%% к производству)" % bonus_pct
                    # Иконка потребляемого продукта (если есть).
                    var cons_icon_path := ""
                    var cons_prod_data = GameData.products.get(cons_pid, {})
                    if cons_prod_data.has("icon"):
                        cons_icon_path = _map_renderer.get_icon_path(cons_prod_data["icon"])
                    if cons_icon_path != "":
                        result.append({
                            "type": "product",
                            "name": cons_label,
                            "amount": 0, # число не выводим: важна текстовая подпись
                            "icon_path": cons_icon_path
                        })
                    else:
                        result.append({"type": "label", "text": cons_label, "color": Color(0.85, 0.85, 0.85)})

    return result
