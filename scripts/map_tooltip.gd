class_name MapTooltip

var _tooltip_text_label: RichTextLabel
var _tooltip_products_container: VBoxContainer
var _map_renderer
var _worker_manager
# Ключ последнего отрисованного списка продукции тултипа (для сравнения
# при периодическом обновлении — чтобы не пересобирать UI без изменений).
var _last_products_key := ""
# Гекс, для которого расширенный блок (строка «Дорога: …», свойства гекса,
# производство с модификаторами) уже показан; -1 — блок не показан.
#
# Расширенный блок и базовый тултип живут в ОДНОМ контейнере, а render_products
# его чистит. Поэтому любой повторный вызов update_tooltip_text на том же гексе
# (например, периодический рефреш заполненности пастбища из InputHandler)
# без этого состояния стирал бы строку уровня дороги через секунду после её
# появления — и до ухода курсора она не возвращалась бы, потому что
# расширенный блок рисуется всего один раз за наведение.
var _extended_row: int = -1
var _extended_col: int = -1

# Форматирование скорости (шт./сек, ед./сек) живёт в общих помощниках:
# ConsumptionUi.format_rate — для строк профессионального потребления.
# Собственного форматировщика здесь больше нет: раньше он жил именно в этом
# файле, и новые места показа расхода копипастили бы его.

func _init(tooltip_text_label: RichTextLabel, tooltip_products_container: VBoxContainer, map_renderer, worker_manager):
    _tooltip_text_label = tooltip_text_label
    _tooltip_products_container = tooltip_products_container
    _map_renderer = map_renderer
    _worker_manager = worker_manager


# Собирает строки маркеров чужой территории для тултипа.
# Возвращает Array<String> в порядке:
#   1) «Территория города» — если гекс входит в кольцо влияния (in_town_influence);
#   2) «Город»            — если на гексе стоит городок (has_town).
# Оба маркера независимы: на гексе-центре кольца окажутся ОБА, на остальных
# гексах кольца — только первый. Каждая строка уже готова к выводу, без
# ведущего разделителя — вызывающий код добавляет \n по контексту.
# Используется во всех ветках _build_text (уникальная местность / неисследованная
# / исследованная), чтобы тултип был консистентным: голубое пятно вокруг
# городка всегда сопровождается пояснением «это чья-то территория».
func _town_name_for_hex(row: int, col: int) -> String:
    var main_map = _map_renderer.main_map if _map_renderer != null else null
    if main_map == null:
        return ""
    for town in main_map.towns:
        if int(town.get("row", -1)) == row and int(town.get("col", -1)) == col:
            return str(town.get("name", ""))
        for influence_hex in town.get("influence_hexes", []):
            if int(influence_hex.get("row", -1)) == row \
                    and int(influence_hex.get("col", -1)) == col:
                return str(town.get("name", ""))
    return ""


func _territory_lines_for(tile: Dictionary, row: int, col: int) -> Array:
    var lines: Array = []
    # Имя городка НЕ раскрывается на неразведанном гексе: в тумане войны игрок
    # видит только «что-то есть» (полупрозрачную иконку), а название узнаёт
    # после разведки. На раскрытых гексах (Кольцо или разведанные) — как было.
    var revealed: bool = bool(tile.get("in_influence", false)) \
            or bool(tile.get("is_explored", false))
    var town_name = _town_name_for_hex(row, col) if revealed else ""
    if bool(tile.get("in_town_influence", false)):
        lines.append(tr("Territory of the city %s") % town_name if town_name != "" else tr("City territory"))
    if bool(tile.get("has_town", false)):
        lines.append(tr("City %s") % town_name if town_name != "" else tr("City"))
    return lines


# Уровень дороги на гексе (0 — дороги нет). Берётся из СЕТИ
# (road_manager), а не из tile["road_level"]: поле на гексе описывает только
# участок, которым гекс подключили к сети.
#
# main_map достаётся так же, как в _town_name_for_hex: напрямую из рендерера,
# а сеть дорог берётся публичным полем. Отдельный параметр «сеть дорог» в
# конструкторе не добавляется: он нужен ровно здесь и в
# has_extended_tooltip_info, а MapTooltip и так работает с картой.
func _hex_road_level(row: int, col: int) -> int:
    var main_map = _map_renderer.main_map if _map_renderer != null else null
    if main_map == null:
        return 0
    var road_manager = main_map.road_manager
    if road_manager == null or not road_manager.has_method("get_hex_road_level"):
        return 0
    return int(road_manager.get_hex_road_level(row, col))

# «Тележная дорога (уровень 2, до 30 ед./сек на участок)» — ЛУЧШАЯ дорога,
# доходящая до гекса: уровень гекса = максимум по примыкающим участкам
# (road_manager.get_hex_road_level). На перекрёстке из двух тропок и одной
# тележной дороги показывается тележная дорога — так же, как гекс выглядит
# на карте.
#
# Формулировка «до N ед./сек на участок» важна: по гексу едет ЛУЧШАЯ дорога,
# а не всякий примыкающий участок. Средняя по маршруту считается отдельно
# (строка «Маршрут до города»), поэтому подпись не должна читаться как
# «вся дорога сюда везёт N».
#
# Номер уровня нужен не для красоты: игрок читает «уровень 2» в кнопке выбора
# и в подписи маршрута, и без него непонятно, какая кнопка соответствует
# строке на гексе.
func road_level_line(row: int, col: int) -> String:
    var level := _hex_road_level(row, col)
    if level <= 0:
        return ""
    return tr("%s (level %d, up to %d units/sec per section)") % [
            GameData.get_road_name(level), level,
            GameData.get_road_max_speed(level)]

func _format_resource_label_for_text(res_id: String, res_name: String) -> String:
    if res_id == "" or res_name == "":
        return res_name
    var icon_name = GameData.raw_resources.get(res_id, {}).get("icon", "")
    if icon_name == "":
        return res_name
    if _map_renderer == null:
        return res_name
    var icon_path = IconRegistry.icon_path(icon_name)
    if icon_path == "":
        return res_name
    return "[img=18]%s[/img] %s" % [icon_path, res_name]


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
            # amount может быть дробным (скорость «ед./сек»); suffix
            # дописывается после числа (например, « ед./сек»).
            var amount_val = float(item.get("amount", 0))
            if amount_val > 0:
                var amount_str = str(int(amount_val)) if amount_val == floor(amount_val) else "%.1f" % amount_val
                label_item.text = "%s: %s%s" % [item.get("name", ""), amount_str, str(item.get("suffix", ""))]
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
# text — ПОЛНЫЙ текст гекса: левая колонка панели показывает всё сразу, без
# задержки наведения, поэтому свойства гекса в ней остаются (в обычном тултипе
# их нет — см. _build_text с basic_only = true). products — расширенное
# производство с модификаторами.
func build_hex_info(row: int, col: int, tile_data: Array, city_row: int = 0, city_col: int = 0) -> Dictionary:
    var text = _build_text(row, col, tile_data, city_row, city_col)
    # На гексе города нельзя строить улучшения, поэтому потенциальный выход
    # продукции в левой колонке панели для него не показываем.
    var products = [] if row == city_row and col == city_col else _collect_extended_production(row, col, tile_data)
    return {"text": text, "products": products}


func update_tooltip_text(row: int, col: int, tile_data: Array, city_row: int = 0, city_col: int = 0):
    # basic_only = true: обычный тултип отвечает на вопрос «что на этом гексе» и
    # показывает только местность, ресурс и улучшение. Свойства гекса,
    # производство и потребление живут в расширенном блоке, который появляется
    # по задержке наведения. Своего блока «Once built, ... will give» у тултипа
    # больше нет: расширенный показывает то же самое, но с бонусами и
    # модификаторами.
    var text = _build_text(row, col, tile_data, city_row, city_col, true)

    var products: Array = []
    # Если для этого гекса уже показан расширенный блок, итоговый набор строк —
    # именно он. Иначе рефреш (подвижная заполненность пастбища) пересобрал бы
    # контейнер с нуля и все строки блока исчезли бы (см. комментарий
    # к _extended_row).
    if _extended_row == row and _extended_col == col:
        products = _collect_extended_block(row, col, tile_data)

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


# Отвечает, показывать ли расширенный блок тултипа на этом гексе.
#
# Условия перечислены НЕ здесь: проверка спрашивает у того же сборщика, который
# строит сам блок, и сравнивает результат с пустым списком. Список условий и
# список строк, написанные отдельно, рано или поздно расходятся — и тогда
# расширенный блок либо не покажется вовсе, либо покажется пустым (см. docs.md,
# раздел «Обычный и расширенный тултипы гекса»).
func has_extended_tooltip_info(row: int, col: int, tile_data: Array) -> bool:
    return not _collect_extended_block(row, col, tile_data).is_empty()


func update_extended_tooltip(row: int, col: int, tile_data: Array, city_row: int, city_col: int):
    # Запоминаем гекс: с этого момента повторный вызов update_tooltip_text
    # (рефреш заполненности пастбища) перерисует ИМЕННО расширенный блок.
    _extended_row = row
    _extended_col = col

    _render_extra_products(_collect_extended_block(row, col, tile_data))


# Собирает строки расширенного блока тултипа. Единственный источник этих строк:
# и проверка «показывать ли» (has_extended_tooltip_info), и показ блока
# (update_extended_tooltip), и его перерисовка при рефреше (update_tooltip_text)
# берут результат отсюда — иначе списки разъехались бы.
#
# Функция ЧИСТАЯ: ничего не рисует и не меняет подписи. Побочный эффект здесь
# был бы вдвойне опасен — её зовёт проверка из handle_process (InputHandler),
# то есть каждый кадр, пока блок не показан.
func _collect_extended_block(row: int, col: int, tile_data: Array) -> Array:
    # Уровень дороги на гексе. Добавляется ПЕРВЫМ, до проверок ниже: у гекса с
    # дорогой, но без улучшения (например, пустой гекс под дорогой) все ранние
    # выходы сработали бы раньше, и строка не появилась бы вовсе — а именно там
    # игрок и решает, какую дорогу ему улучшать.
    #
    # Строки КОПЯТСЯ и рендерятся ОДИН раз вызывающим: render_products чистит
    # контейнер, и два вызова подряд стёрли бы первый — на гексе с дорогой и
    # природным ресурсом (например, с дикоросами) уровень молча исчезал бы.
    var extra_products: Array = []
    var road_line := road_level_line(row, col)
    if not road_line.is_empty():
        extra_products.append({"type": "label", "text": tr("Road: %s") % road_line,
                "color": Color(0.7, 0.9, 0.7)})

    # Свойства гекса: качество ресурса, расход корма, заполненность пастбища,
    # доступ к пресной воде. Перенесены сюда из базового тултипа, где остались
    # только местность, ресурс и улучшение.
    #
    # Добавляются ДО ранних выходов ниже: доступ к воде есть и на гексе без
    # ресурса, и в кольце влияния чужого городка — гейты на корм и заполненность
    # живут внутри _collect_hex_properties.
    for property_line in _collect_hex_properties(row, col, tile_data):
        extra_products.append({"type": "label", "text": property_line})

    var tile = tile_data[row][col]
    var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)
    if not is_revealed or bool(tile.get("in_town_influence", false)):
        return extra_products

    # Расчёты стоимости постройки (база/местность/расстояние) перенесены
    # в Превью панели управления — здесь они больше не показываются.

    var res_id = MapHelpers.get_effective_resource(tile)
    # Скрытый ресурс не показываем — как будто его на гексе нет.
    if res_id != "" and not MapHelpers.is_resource_revealed(tile):
        res_id = ""
    if res_id == "":
        return extra_products
    var res_data = GameData.raw_resources.get(res_id, {})
    if not res_data.has("produces"):
        return extra_products

    extra_products.append_array(_collect_extended_production(row, col, tile_data))
    return extra_products


# --- Свойства гекса: то, что уехало из базового тултипа ---
#
# Качество ресурса, расход корма, заполненность пастбища и доступ к пресной
# воде. Обычный тултип отвечает на вопрос «что на этом гексе» (местность,
# ресурс, улучшение), поэтому свойства показываются только в расширенном блоке.
#
# Единственный источник строк: и расширенный блок тултипа, и полный текст гекса
# для левой колонки панели управления. Строки возвращаются БЕЗ ведущего перевода
# строки — вызывающий склеивает их сам: в тексте это перевод строки плюс строка,
# а в контейнере строк тултипа у каждой строки свой отступ.
func _collect_hex_properties(row: int, col: int, tile_data: Array) -> Array:
    var lines: Array = []
    var tile = tile_data[row][col]
    if tile == null:
        return lines
    # Неисследованный гекс: свойств не раскрываем. Базовый тултип для него тоже
    # молчит — там только местность и подсказка про разведку.
    var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)
    if not is_revealed:
        return lines

    # Качество — свойство улучшения: без построенного улучшения его на гексе
    # ещё нет.
    var tile_quality = tile.get("quality", "")
    if tile_quality != "" and tile.improvement != null:
        lines.append(tr("Quality: %s (%s)") % [
                GameData.get_quality_stars(tile_quality),
                GameData.get_quality_name(tile_quality)])

    var res_id = MapHelpers.get_effective_resource(tile)
    # Скрытый ресурс (tech_reveal не изучен): о нём игроку знать нельзя.
    if res_id != "" and not MapHelpers.is_resource_revealed(tile):
        res_id = ""
    # Корм и заполненность стада — хозяйственные показатели улучшения. В кольце
    # влияния ЧУЖОГО городка их не показываем: игрок не управляет этими гексами
    # (тот же гейт, что был у базового тултипа).
    if res_id != "" and not bool(tile.get("in_town_influence", false)):
        var res_data = GameData.raw_resources.get(res_id, {})
        var feed_consumption = res_data.get("feed_consumption", 0)
        if feed_consumption > 0:
            lines.append(tr("Feed consumption: %d per cycle") % feed_consumption)
        var time_to_mature = res_data.get("time_to_mature", 0)
        if time_to_mature > 0:
            # Растущий ресурс (животные на пастбище): текущая заполненность и
            # остаток времени — если улучшение уже работает.
            if tile.improvement != null and _worker_manager.has_worker(row, col):
                var fill_frac = MapHelpers.get_fill_fraction(tile, res_data)
                if fill_frac >= 1.0:
                    lines.append(tr("Herd: full (100%)"))
                else:
                    var t_left = MapHelpers.get_time_to_full(tile, res_data)
                    lines.append(tr("Fill level: %d%% (full in %.0f sec)") % [
                            roundi(fill_frac * 100), ceilf(t_left)])
            else:
                lines.append(tr("Fill time: %.0f sec") % time_to_mature)

    # Доступ к пресной воде показываем для ВСЕХ гексов.
    var water_access = MapHelpers.get_hex_water_access(
            row, col, tile_data, tile_data.size(), tile_data[0].size())
    if water_access == "direct":
        lines.append(tr("Fresh water access: direct"))
    elif water_access == "chain":
        lines.append(tr("Fresh water access: via chain"))

    return lines


# Сбрасывает привязку расширенного блока к гексу. Вызывается владельцем тултипа
# (InputHandler) при смене гекса и при скрытии тултипа — там же, где сбрасывается
# его собственный флаг «блок уже показан».
#
# Без сброса возврат на тот же гекс нарисовал бы расширенный блок сразу, минуя
# задержку наведения: update_tooltip_text увидел бы старую привязку.
func clear_extended_tooltip():
    _extended_row = -1
    _extended_col = -1

# Единственная точка рендера расширенного блока тултипа. Пустой список — тоже
# вызов: он чистит контейнер, и без этого на гексе без расширенной информации
# остались бы строки от предыдущего гекса.
#
# Ключ обновляется ЗДЕСЬ: дальше он описывает уже расширенный блок, а не базовый
# набор из update_tooltip_text. Иначе первый же рефреш после показа блока видел
# бы «изменилось» и зря пересобирал контейнер (а после него ключ всё равно
# устаревал бы — сравнение шло бы не по тому, что нарисовано).
func _render_extra_products(products: Array):
    render_products(products, _tooltip_products_container)
    _last_products_key = var_to_str(products)


# --- Построение текста гекса ---
# Вынесено из update_tooltip_text, чтобы панель управления (control_panel.gd)
# показывала ту же информацию без дублирования кода.
#
# basic_only = true — БАЗОВЫЙ текст обычного тултипа: только местность, ресурс и
# улучшение, то есть физически то, что лежит на гексе. Всё прочее — качество,
# корм, заполненность, доступ к пресной воде, производство, потребление — живёт
# в расширенном блоке (см. _collect_extended_block и _collect_hex_properties).
#
# basic_only = false (по умолчанию) — ПОЛНЫЙ текст для левой колонки панели
# управления: там показывается всё сразу, без задержки наведения, поэтому
# свойства гекса в ней остаются (см. build_hex_info).
func _build_text(row: int, col: int, tile_data: Array, city_row: int = 0, city_col: int = 0, basic_only: bool = false) -> String:
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
    var res_name = tr("none")
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
        # Уникальная местность (например, содовое озеро) за пределами видимой
        # области: показываем имя/описание, плюс маркер «Территория города» /
        # «Город», если гекс попал в кольцо или содержит городок.
        var desc = terrain_data.get("description", "")
        var uniq_text: String = desc if desc != "" else terrain_name
        var uniq_terr: Array = _territory_lines_for(tile, row, col)
        if not uniq_terr.is_empty():
            uniq_text += "\n" + "\n".join(uniq_terr)
        return uniq_text

    if not is_revealed:
        # Неисследованный гекс (в Регионе или в тумане войны): стандартный
        # текст с подсказкой про разведку. Разведчиков можно послать в любую
        # точку, достижимую скроллом, — включая территорию городков, поэтому
        # подсказка одинакова для всех неисследованных гексов.
        var text: String = tr("Terrain: %s") % terrain_with_cover
        var terr: Array = _territory_lines_for(tile, row, col)
        if not terr.is_empty():
            text += "\n" + "\n".join(terr)
        text += tr("\nResource: unknown (send scouts)")
        return text

    var imp_name = GameData.improvements.get(tile.improvement, {}).get("name", tr("none")) if tile.improvement != null else tr("none")
    var text: String = tr("Terrain: %s") % terrain_with_cover
    # Маркеры чужой территории в кольце/на месте городка: сразу после
    # «Местность», чтобы игрок видел «кто здесь» прежде, чем читать
    # остальной тултип. Строка «Город» добавляется ТОЛЬКО когда на гексе
    # действительно стоит городок (т.е. в центре кольца), а «Территория
    # города» — на любом гексе кольца, включая сам городок.
    var terr: Array = _territory_lines_for(tile, row, col)
    if not terr.is_empty():
        text += "\n" + "\n".join(terr)
    var resource_text = _format_resource_label_for_text(res_id, res_name)
    text += tr("\nResource: %s") % resource_text

    var terrain_desc = terrain_data.get("description", "")
    if terrain_desc != "":
        text += "\n%s" % terrain_desc

    var in_town_influence = bool(tile.get("in_town_influence", false))
    var imp_status = ""
    if tile.improvement != null:
        if in_town_influence:
            imp_status = ""
        elif GameData.is_no_worker_improvement(tile.improvement):
            # Инфраструктурное улучшение (no_worker, например пристань):
            # функционирует само по себе — статус «нет рабочего» неприменим.
            imp_status = tr(" (infrastructure: no worker required)")
        else:
            var has_worker = _worker_manager.has_worker(row, col)
            if not has_worker:
                imp_status = tr(" (inactive: no worker)")
            else:
                imp_status = tr(" (working)")
    else:
        if res_id != "":
            var res_data = GameData.raw_resources.get(res_id, {})
            # У одноразового ресурса (improved_by == null) нечего строить —
            # статус «(не построено)» не показываем.
            if res_data.get("improved_by", null) != null and res_data.has("produces"):
                imp_status = tr(" (not built)")

    text += tr("\nImprovement: %s%s") % [imp_name, imp_status]

    # Свойства гекса (качество, корм, заполненность, доступ к пресной воде) в
    # обычном тултипе НЕ показываются — они живут в расширенном блоке. Здесь
    # они дописываются только к полному тексту, то есть к левой колонке панели.
    if not basic_only:
        for property_line in _collect_hex_properties(row, col, tile_data):
            text += "\n" + property_line

    # --- Конфликт «tech_reveal-ресурс под чужим улучшением» ---
    var conflict = MapHelpers.get_tech_reveal_conflict(tile)
    if not conflict.is_empty():
        var current_imp_name: String = GameData.improvements.get(tile.improvement, {}).get("name", tile.improvement)
        text += tr("\n\nFound here: %s") % conflict.get("res_name", "")
        text += tr("\nDemolish %s to build %s") % [current_imp_name, conflict.get("imp_name", "")]

    # Стоимость постройки в тултипе/левой панели больше не показывается —
    # расчёты перенесены в Превью панели управления.

    return text


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
        # Лесная делянка: производство древесины из покрова (wood_yield в
        # covers.json). Показываем и для построенной делянки с рабочим, и
        # как подсказку «при постройке» на пустом лесном гексе. Любой будущий
        # покров с wood_yield > 0 учитывается автоматически.
        var lj_yield: float = MapHelpers.get_cover_wood_yield(tile)
        if lj_yield > 0.0 and tile.improvement == null \
                and CityData.is_product_available("wood"):
            var lj_name = GameData.improvements.get("lumberjack_hut", {}).get("name", "lumberjack_hut")
            var lj_interval0 := CityData.get_improvement_production_interval("lumberjack_hut")
            var lj_per_sec0: float = float(int(ceil(lj_yield))) / lj_interval0
            var wood_data0 = GameData.products.get("wood", {})
            var lj_icon_path0 = ""
            if wood_data0.has("icon"):
                lj_icon_path0 = IconRegistry.icon_path(wood_data0["icon"])
            result.append({"type": "header", "text": tr("Once built, %s will produce:") % lj_name})
            result.append({"type": "product", "name": wood_data0.get("name", tr("Wood")), "amount": lj_per_sec0, "icon_path": lj_icon_path0, "suffix": tr(" units/sec")})
        elif tile.improvement == "lumberjack_hut" and lj_yield > 0.0 \
                and _worker_manager.has_worker(row, col) \
                and CityData.is_product_available("wood"):
            var lj_mult2 = CityData.get_improvement_production_multiplier(
                "lumberjack_hut",
                MapHelpers.is_hex_irrigated(row, col, tile_data, tile_data.size(), tile_data[0].size()),
                tile.get("terrain", ""), "lumberjack_hut")
            var lj_interval2 := CityData.get_improvement_production_interval("lumberjack_hut")
            var lj_per_sec2: float = float(ceili(lj_yield * lj_mult2)) / lj_interval2
            var wood_data2 = GameData.products.get("wood", {})
            var lj_icon_path2 = ""
            if wood_data2.has("icon"):
                lj_icon_path2 = IconRegistry.icon_path(wood_data2["icon"])
            var lj_label = wood_data2.get("name", tr("Wood"))
            if lj_mult2 != 1.0:
                var lj_base_str = str(int(lj_yield)) if lj_yield == floor(lj_yield) else "%.1f" % lj_yield
                lj_label = tr("%s (base %s)") % [lj_label, lj_base_str]
            result.append({"type": "header", "text": tr("Produces:")})
            result.append({"type": "product", "name": lj_label, "amount": lj_per_sec2, "icon_path": lj_icon_path2, "suffix": tr(" units/sec")})
        return result
    var res_data = GameData.raw_resources.get(eff_res, {})
    if not res_data.has("produces"):
        return result

    # Одноразовые ресурсы (improved_by == null — дикоросы, самородки) не имеют
    # непрерывного производства: их собирают спец-действием action_type "forage",
    # после чего ресурс исчезает с карты. В расширенной сводке («Производит:…»)
    # показывать для них нечего, а значение produces там — «число или [min, max]»
    # (выход за один сбор), не базовый выход за цикл улучшения.
    if res_data.get("improved_by", null) == null:
        return result

    var modifiers := []
    var bonus_multiplier = 1.0
    # Интервал цикла производства: у построенного улучшения — своё
    # production_interval, у подсказки «при постройке» — интервал будущего
    # улучшения (improved_by ресурса).
    var prod_interval: float = 1.0
    if tile.improvement != null and _worker_manager.has_worker(row, col):
        modifiers = CityData.get_improvement_production_modifiers(tile.improvement, MapHelpers.is_hex_irrigated(row, col, tile_data, tile_data.size(), tile_data[0].size()), tile.get("terrain", ""), eff_res)
        bonus_multiplier = CityData.get_improvement_production_multiplier(tile.improvement, MapHelpers.is_hex_irrigated(row, col, tile_data, tile_data.size(), tile_data[0].size()), tile.get("terrain", ""), eff_res)
        prod_interval = CityData.get_improvement_production_interval(tile.improvement)
    elif tile.improvement == null:
        prod_interval = CityData.get_improvement_production_interval(str(res_data.get("improved_by", "")))

    var available_products := {}
    for prod_id in res_data["produces"]:
        if tile.improvement == null or CityData.is_product_available(prod_id):
            available_products[prod_id] = res_data["produces"][prod_id]

    if available_products.is_empty():
        return result

    var header_text = tr("Produces:")
    if tile.improvement == null:
        var improvement_id = res_data.get("improved_by", "")
        var imp_name_display = GameData.improvements.get(improvement_id, {}).get("name", improvement_id)
        header_text = tr("Once built, %s will produce:") % imp_name_display
    result.append({"type": "header", "text": header_text})

    # Растущие ресурсы: пока пастбище заполняется, фактический выход
    # пропорционален степени заполненности стада.
    var fill_frac = MapHelpers.get_fill_fraction(tile, res_data)

    var base_amount = 0.0
    var final_amount = 0
    for prod_id in available_products:
        # produces может быть числом или диапазоном [min, max] — в сводке
        # показываем детерминированный минимум (см. RangeUtils).
        base_amount = float(RangeUtils.get_min_value(available_products[prod_id], 1))
        final_amount = ceili(base_amount * bonus_multiplier * fill_frac)
        var prod_name = GameData.products.get(prod_id, {}).get("name", prod_id)
        # При активных модификаторах показываем базу у каждого продукта
        # (у разных продуктов она своя, одна общая строка «База» вводила в заблуждение).
        if bonus_multiplier != 1.0 or fill_frac != 1.0:
            var base_str = str(int(base_amount)) if base_amount == floor(base_amount) else "%.1f" % base_amount
            prod_name = tr("%s (base %s)") % [prod_name, base_str]
        var icon_path = ""
        var prod_data = GameData.products.get(prod_id, {})
        if prod_data.has("icon"):
            var icon_name = prod_data["icon"]
            icon_path = IconRegistry.icon_path(icon_name)
        # Показ — посекундный: выпуск цикла, делённый на production_interval.
        result.append({"type": "product", "name": prod_name, "amount": float(final_amount) / prod_interval, "icon_path": icon_path, "suffix": tr(" units/sec")})

    for mod in modifiers:
        result.append({"type": "label", "text": " %s" % mod.get("label", ""), "color": Color(0.7, 0.9, 0.7)})

    # --- Потребление профессии ---
    # Показываем список ресурсов, которые профессия рабочего на этом гексе
    # расходует со склада. Источник записей — реестр data/consumption.json
    # (плюс устаревшее поле consumption у продуктов), см. docs.md.
    # Секция появляется только если:
    #   1) улучшение построено,
    #   2) на нём есть рабочий,
    #   3) улучшение имеет профессию,
    #   4) у этой профессии есть хотя бы один потребитель.
    # Само производство улучшения при нехватке ресурса НЕ останавливается —
    # оно откатывается к базовому множителю (без бонуса).
    if tile.improvement != null and _worker_manager.has_worker(row, col):
        # Строки показа собирает общий ConsumptionUi: те же строки рисует
        # тултип деталей здания (вкладка «Здания») и окно деталей здания,
        # поэтому формат расхода один на все эти места.
        var cons_rows = ConsumptionUi.build_rows(
            GameData.get_profession_for_improvement(tile.improvement))
        if not cons_rows.is_empty():
            result.append({"type": "header", "text": tr("Consumes:")})
            for cons in cons_rows:
                var cons_label: String = str(cons.get("label", ""))
                # Иконка потребляемого ресурса; у группы берётся иконка
                # первого члена с картинкой (её кладёт GameData в "icon").
                var cons_icon_path: String = IconRegistry.icon_path(
                    str(cons.get("icon", "")))
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
