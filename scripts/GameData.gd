@tool
extends Node

var terrains: Dictionary = {}
var covers: Dictionary = {}
var raw_resources: Dictionary = {}
var products: Dictionary = {}
var improvements: Dictionary = {}
var crafts: Array = []
var buildings: Array = []
var categories: Array = []
var technologies: Array = []
var groups: Array = []
var eras: Array = []
var product_groups: Dictionary = {}
var product_group_names: Dictionary = {}
var product_group_icons: Dictionary = {} # id -> имя файла иконки группы ("" — не задана)
var modifiers: Dictionary = {}
var price_modifiers: Dictionary = {} # resource_id -> { фактор: множитель цены }
var special_actions: Dictionary = {} # id -> данные спецдействия
var qualities: Dictionary = {} # данные о степенях качества ресурсов
var map_config: Dictionary = {} # конфигурация карты мира (data/map_config.json)
var professions: Dictionary = {} # id -> данные профессии (data/professions.json)
var consumption_rules: Array = [] # записи потребления (data/consumption.json)
var city_names: Array = [] # варианты названий города (data/city_names.json)
var game_balance: Dictionary = {} # игровой баланс (data/game_balance.json)
# Факт того, что данные уже загружены. Нужен, чтобы не читать data/*.json
# дважды подряд: главное меню проверяет данные валидатором
# (scripts/data_validator.gd) при входе, а новая партия грузит их снова.
# Аналог SaveManager.is_loaded.
var data_loaded: bool = false
# Откуда пришла каждая сущность: "коллекция:id" → { "file": String, "line": int }.
# Читает рантайм-валидатор (scripts/data_validator.gd), чтобы указывать проблему
# на конкретный файл и строку, а не заставлять искать опечатку вручную.
var entity_sources: Dictionary = {}

func load_all_data():
    var loader = load("res://scripts/data_loader.gd").new()
    loader.load_all_data()
    terrains = loader.terrains
    covers = loader.covers
    raw_resources = loader.raw_resources
    products = loader.products
    improvements = loader.improvements
    crafts = loader.crafts
    buildings = loader.buildings
    categories = loader.categories
    technologies = loader.technologies
    groups = loader.groups
    eras = loader.eras
    product_groups = loader.product_groups
    product_group_names = loader.product_group_names
    product_group_icons = loader.product_group_icons
    modifiers = loader.modifiers
    special_actions = loader.special_actions
    qualities = loader.qualities
    map_config = loader.map_config
    professions = loader.professions
    consumption_rules = loader.consumption_rules
    city_names = loader.city_names
    game_balance = loader.game_balance
    entity_sources = loader.entity_sources
    data_loaded = true

# Возвращает случайное название города из data/city_names.json.
# Если список пуст или не загрузился — возвращает нейтральное имя по умолчанию.
func get_random_city_name() -> String:
    if city_names.is_empty():
        return tr("City")
    return city_names[randi() % city_names.size()]

# Возвращает имя группы по её ключу (с символом "@" или без).
# Если ключ не является группой, возвращает пустую строку.
func get_product_group_name(key: String) -> String:
    var gkey = key.trim_prefix("@")
    if product_group_names.has(gkey):
        return product_group_names[gkey]
    return ""

# Иконка группы продуктов для карточки «Торговля» + источник этой иконки.
# Приоритет выбора:
#   1. собственное поле "icon" группы (data/product_groups.json) — автор
#      данных явно выбрал пиктограмму для группы;
#   2. иконка ПЕРВОГО члена группы, у которого иконка задана (старый порядок,
#      обратная совместимость для групп без своего "icon").
# Вторая ветка нужна, потому что первый член группы нередко не представитель
# группы: у «Алкоголя» это пиво, хотя группа — напитки из зерна.
#
# Возвращает { "icon": String, "source_pid": String, "own": bool }:
#   icon      — имя файла иконки ("" — иконки нет, вызывающая скрывает узел);
#   source_pid — id товара, чей icon использован ("" при своей иконке группы);
#   own       — true, если иконка задана самой группой. Карточка показывает
#               источник в тултипе: без него игрок не понимает, почему у
#               «Алкоголя» нарисован кувшин.
func get_product_group_icon_info(key: String) -> Dictionary:
    var gkey = key.trim_prefix("@")
    if not product_groups.has(gkey):
        return {"icon": "", "source_pid": "", "own": false}
    var own_icon: String = str(product_group_icons.get(gkey, ""))
    if not own_icon.is_empty():
        return {"icon": own_icon, "source_pid": "", "own": true}
    for pid in product_groups[gkey]:
        var icon: String = str(products.get(pid, {}).get("icon", ""))
        if not icon.is_empty():
            return {"icon": icon, "source_pid": str(pid), "own": false}
    return {"icon": "", "source_pid": "", "own": false}

# Только имя файла иконки группы — для мест, где источник иконки не нужен.
func get_product_group_icon(key: String) -> String:
    return str(get_product_group_icon_info(key).get("icon", ""))


# Возвращает список человекочитаемых названий продуктов, входящих в группу.
# Если ключ не является группой, возвращает пустой массив.
func get_product_group_member_names(key: String) -> Array:
    var gkey = key.trim_prefix("@")
    if not product_groups.has(gkey):
        return []
    var names = []
    for prod_id in product_groups[gkey]:
        names.append(products.get(prod_id, {}).get("name", prod_id))
    return names

# Является ли ресурсный ключ групповым (начинается с "@")?
func is_group_key(key: String) -> bool:
    return key.begins_with("@")

# Форматирует ресурсный вход рецепта: для групповых ключей возвращает
# "Имя группы - количество", иначе "Имя продукта - количество".
func format_resource_input(key: String, amount: float) -> String:
    if is_group_key(key):
        var group_name = get_product_group_name(key)
        if group_name != "":
            return "%s - %d" % [group_name, int(amount)]
        # Группа не найдена — показываем ключ без "@"
        return "%s - %d" % [key.trim_prefix("@"), int(amount)]
    return "%s - %d" % [products.get(key, {}).get("name", key), int(amount)]

# Форматирует название ресурса для отображения в интерфейсе (стоимости, запасы).
# Для групповых ресурсов возвращает только название группы (без списка членов).
func format_resource_name(key: String) -> String:
    if is_group_key(key):
        var group_name = get_product_group_name(key)
        if group_name != "":
            return group_name
        return key.trim_prefix("@")
    # В пуле продажи могут быть как продукты, так и сырьевые ресурсы.
    var resource_data := get_resource_data(key)
    return str(resource_data.get("name", key))

func get_special_yield(product_id: String) -> Dictionary:
    return products.get(product_id, {}).get("special_yield", {})

# --- ЦЕНЫ НА РЕСУРСЫ ---
# Базовая цена задана в JSON (поле "price" у ресурса/продукта). Итоговая цена
# может динамически меняться через множители: например, голод поднимает цены
# на еду, избыточное предложение или эрозия рынка — опускают. Множители
# перемножаются между собой, итог = база × произведение всех активных.
# Подробности — в docs.md, раздел «Цены на ресурсы».

# Возвращает данные ресурса/продукта (сырьё или продукция) по id.
func get_resource_data(res_id: String) -> Dictionary:
    if raw_resources.has(res_id):
        return raw_resources[res_id]
    if products.has(res_id):
        return products[res_id]
    return {}

# Базовая цена из JSON (поле "price"). Если поля нет — 0.
func get_base_price(res_id: String) -> float:
    return float(get_resource_data(res_id).get("price", 0.0))

# Произведение всех активных множителей цены ресурса (без активных — 1.0).
func get_price_multiplier(res_id: String) -> float:
    var total := 1.0
    var mods: Dictionary = price_modifiers.get(res_id, {})
    for factor in mods:
        total *= float(mods[factor])
    return total

# Итоговая цена ресурса на текущий момент: база × активные множители.
func get_price(res_id: String) -> float:
    return get_base_price(res_id) * get_price_multiplier(res_id)

# Включает множитель цены (factor — имя фактора, напр. "famine" или
# "market_glut"). Эффект применяется к конкретному ресурсу по его id; чтобы
# распространить его на группу, примените ко всем членам группы.
func apply_price_modifier(res_id: String, factor: String, multiplier: float):
    if not price_modifiers.has(res_id):
        price_modifiers[res_id] = {}
    price_modifiers[res_id][factor] = multiplier

# Отключает один фактор-множитель цены ресурса.
func remove_price_modifier(res_id: String, factor: String):
    if price_modifiers.has(res_id):
        price_modifiers[res_id].erase(factor)
        if price_modifiers[res_id].is_empty():
            price_modifiers.erase(res_id)

# Сбрасывает ВСЕ динамические множители цен (цены возвращаются к базовым).
func clear_price_modifiers():
    price_modifiers.clear()

func get_building_additional_yield(building_id: String) -> Dictionary:
    for building in buildings:
        if building.get("id", "") == building_id:
            return building.get("additional_yield", {})
    return {}

# Нормализует поле additional_cost в массив словарей {ресурс: количество}.
# Поддерживает две формы:
#   1) объект:        { "flour": 3.0, "wood": 10.0 }        → [ { "flour": 3.0, "wood": 10.0 } ]
#   2) массив пачек:  [ { "flour": 3.0 }, { "gold": 50.0 } ]  → как есть
# Логика AND-объединения пачек: нужны ресурсы из КАЖДОЙ пачки одновременно.
# Возвращает пустой массив для null/невалидных значений.
func parse_additional_cost(raw) -> Array:
    var result: Array = []
    if raw == null:
        return result
    if raw is Dictionary:
        if raw.is_empty():
            return result
        return [raw]
    if raw is Array:
        for item in raw:
            if item is Dictionary and not item.is_empty():
                result.append(item)
        return result
    return result

# Сколько единиц ресурса/группы есть в storage?
# Для обычного ключа (например, "flour") возвращает storage.get(key, 0).
# Для группового ключа (например, "@millable_grains") — сумму по всем членам
# группы из product_groups. Это «любой продукт из группы», как в recipes.
# Если группа не найдена — возвращает 0.
func get_storage_amount(key: String, storage: Dictionary) -> float:
    if is_group_key(key):
        var group_key = key.trim_prefix("@")
        var group_products = product_groups.get(group_key, [])
        if group_products.is_empty():
            return 0.0
        var total := 0.0
        for prod_id in group_products:
            total += float(storage.get(prod_id, 0))
        return total
    return float(storage.get(key, 0))

# --- ХЕЛПЕРЫ ДЛЯ РАБОТЫ С КАЧЕСТВОМ РЕСУРСОВ ---
# Данные загружаются из data/qualities.json в поле qualities.

# Возвращает список id уровней качества в порядке от худшего к лучшему.
func get_quality_levels() -> Array:
    var levels = []
    for q in qualities.get("quality_levels", []):
        if q is Dictionary and q.has("id"):
            levels.append(q["id"])
    return levels

# Возвращает данные уровня качества по id (или пустой словарь).
func get_quality_data(quality_id: String) -> Dictionary:
    for q in qualities.get("quality_levels", []):
        if q is Dictionary and q.get("id", "") == quality_id:
            return q
    return {}

# Возвращает человекочитаемое название уровня качества.
func get_quality_name(quality_id: String) -> String:
    return get_quality_data(quality_id).get("name", quality_id)

# Возвращает числовой вес уровня качества (для взвешенного среднего).
func get_quality_value(quality_id: String) -> int:
    return int(get_quality_data(quality_id).get("value", 1))

# Возвращает строку из звёзд для уровня качества (например, "★★★").
func get_quality_stars(quality_id: String) -> String:
    return get_quality_data(quality_id).get("stars", "")

# --- ЦВЕТ УРОВНЯ КАЧЕСТВА (data/qualities.json, поле color) ---
# Цвет задан массивом [R, G, B] в диапазоне 0…255 — та же форма записи, что у
# покрытий (data/covers.json), улучшений и ресурсов. Красит звёзды в тултипе
# разбора качества, строки лестницы цен в тултипе строки и проценты доли
# уровня в строке списка (resources_tab._update_quality_label).
# Мягкий дефолт: поля color нет (старые данные) или это не массив из трёх
# чисел — светло-серый, чтобы интерфейс не поехал на битых данных.
const QUALITY_COLOR_FALLBACK := Color(0.8, 0.8, 0.8)

func get_quality_color(quality_id: String) -> Color:
    var c = get_quality_data(quality_id).get("color", null)
    if c is Array and c.size() == 3:
        return Color(float(c[0]) / 255.0, float(c[1]) / 255.0, float(c[2]) / 255.0)
    return QUALITY_COLOR_FALLBACK

# --- ЦЕНА ПО КАЧЕСТВУ (data/qualities.json, поле price_multiplier) ---
# Множитель умножается на цену единицы товара: лучшее качество дороже.
# Множитель, а не фиксированная прибавка в монетах, — чтобы наценка была
# пропорциональна на всей шкале цен (1…150), см. шапку qualities.json.

# Множитель цены уровня качества. Для "common", неизвестного id и любого
# уровня без поля — 1.0 (мягкий дефолт: качество не ломает цену, даже
# если поле забыли или данные старые).
func get_quality_price_multiplier(quality_id: String) -> float:
    var m = float(get_quality_data(quality_id).get("price_multiplier", 1.0))
    if m <= 0.0:
        return 1.0
    return m

# Текущая цена единицы товара с учётом качества: цена (база × динамические
# множители рынка) × множитель качества. Дробный результат — округление
# делает вызывающий (нужны ЦЕЛЫЕ монеты, см. get_price_breakdown_for_quality).
func get_price_for_quality(res_id: String, quality_id: String) -> float:
    return get_price(res_id) * get_quality_price_multiplier(quality_id)

# Разбивка цены единицы товара по качеству для тултипа:
#   { "base": int, "multiplier": float, "total": int }
# База (текущая цена с динамическими множителями рынка) округляется до
# целого ОДИН раз, итог — round(base × множитель качества). Все числа в
# тултипе целые, кроме самого множителя, — он и показывается отдельным
# слагаемым: «Цена: 4 * 1.30 (★★) = 5».
# У товара без цены (например, псевдоресурс science) — нули.
func get_price_breakdown_for_quality(res_id: String, quality_id: String) -> Dictionary:
    var mult := get_quality_price_multiplier(quality_id)
    var base := int(round(get_price(res_id)))
    if base <= 0:
        return {"base": 0, "multiplier": mult, "total": 0}
    return {"base": base, "multiplier": mult, "total": int(round(float(base) * mult))}

# Хвост строки цены уровня качества для тултипа строки вкладки «Ресурсы» —
#   " = x1.30 = 5", то есть всё, КРОМЕ звёзд.
# Звёзды отдаются отдельно не для красоты, а по требованию оформления: в
# тултипе строки звёзды красятся в цвет уровня (data/qualities.json, color), а
# сам расчёт цены — золотым (ui_helpers.PRICE_TEXT_COLOR), и одним Label с
# одним цветом на всю строку это не выразить.
# Пустая строка, если показывать нечего: у товара нет цены или уровня
# качества нет в шкале (без звёзд строку не из чего собрать).
func format_quality_price_tail(res_id: String, quality_id: String) -> String:
    if quality_id.is_empty() or not get_quality_levels().has(quality_id):
        return ""
    var d = get_price_breakdown_for_quality(res_id, quality_id)
    if int(d["total"]) <= 0:
        return ""
    return " = x%s = %d" % [
        "%.2f" % float(d["multiplier"]), int(d["total"])
    ]

# Строка цены уровня качества для тултипа строки вкладки «Ресурсы»:
#   "★★ = x1.30 = 5"
# Собирается из звёзд уровня и хвоста выше — обе части берутся из данных, так
# что текст строки и её части (звёзды отдельно, расчёт отдельно) не могут
# разойтись.
# Подпись «Цена:» в строке не нужна: уровень и так назван звёздами, а над
# блоком лестницы уже стоит базовая «Цена: N» того же товара.
# Строка собирается для ЛЮБОГО уровня шкалы, включая самый низкий
# («★ = x1.00 = 4»): лестница читается как одна таблица, где множитель виден
# для каждого уровня, а не начинается с середины. Раньше нижний уровень
# отбрасывался, и у склада, где лежит только обычное качество, блока не было
# вовсе — не было видно, что множитель 1.0 это тоже множитель.
# Пустая строка, если показывать нечего: у товара нет цены или уровня
# качества нет в шкале (без звёзд строку не из чего собрать).
func format_quality_price_line(res_id: String, quality_id: String) -> String:
    var tail := format_quality_price_tail(res_id, quality_id)
    if tail == "":
        return ""
    return get_quality_stars(quality_id) + tail

# Цены по уровням качества, которые РЕАЛЬНО лежат на складе, для тултипа строки
# вкладки «Ресурсы». Показываются только уровни, присутствующие в
# quality_breakdown ({quality_id: count} — разбивка склада из
# CityData.city_quality_detail, см. CityData.get_quality_breakdown): цену
# «превосходного» уровня, которого на складе нет, показывать незачем — это
# вводит в заблуждение.
# Уровни выводятся от худшего к лучшему (порядок data/qualities.json).
# Возвращается массив записей:
#   { "qid":   quality_id,
#     "stars": "★★",        ← звёзды уровня, красятся в его цвет
#     "tail":  " = x1.30 = 5" ← сам расчёт цены, красится золотым,
#     "text":  "★★ = x1.30 = 5" }
# Звёзды и хвост отдаются ОТДЕЛЬНО, потому что тултип строки красит их разными
# цветами (звёзды — цвет уровня из data/qualities.json, расчёт — золотой), а
# text остаётся готовой строкой целиком для тех, кому одного цвета хватает.
# qid нужен вызывающему, чтобы покрасить звёзды в цвет уровня
# (get_quality_color) — так текст строки и её цвет не могут разойтись.
# Пустой массив: у товара нет цены (например, science) или не задан id.
func format_quality_price_scale_rows(res_id: String, quality_breakdown: Dictionary = {}) -> Array:
    var rows: Array = []
    if res_id.is_empty() or get_base_price(res_id) <= 0.0:
        return rows
    for qid in get_quality_levels():
        # Уровня нет на складе — цена не показана (в т.ч. count == 0).
        if int(quality_breakdown.get(qid, 0)) <= 0:
            continue
        var tail := format_quality_price_tail(res_id, str(qid))
        if tail == "":
            continue
        var stars := get_quality_stars(str(qid))
        rows.append({"qid": str(qid), "stars": stars, "tail": tail, "text": stars + tail})
    return rows

# --- ДОЛЯ УРОВНЯ НА СКЛАДЕ (проценты в строке списка и в тултипе разбора) ---
# Процент count от суммы всей разбивки: доли считаются от ОБЩЕГО количества
# товара на складе, поэтому в сумме показывают ~100% (а не долю лучшего
# уровня от остальных — из-за чего строка «★ (67%)» читалась как «две трети
# склада хорошего»).
# Проценты округляются по отдельности, поэтому сумма может разойтись на
# единицу (33%/33%/33%): «допиливать» их до ровных 100% значило бы врать о
# дробных долях. При пустой или нулевой разбивке — 0.
func get_quality_share_percent(count: int, quality_breakdown: Dictionary) -> int:
    var total := 0
    for qid in quality_breakdown:
        total += int(quality_breakdown[qid])
    if total <= 0:
        return 0
    return int(round(float(count) / float(total) * 100.0))

# Разбивка склада строкой для строки списка ресурсов:
#   "(33%/67%)" — доля каждого уровня, реально лежащего на складе, в цвете
# этого уровня (data/qualities.json, color). Уровни от худшего к лучшему, как
# в data/qualities.json; уровни с нулевым количеством пропускаются.
# Возвращается BBCode (теги [color=…]) для Label с включённым bbcode_enabled:
# одним текстом видны все уровни, и каждый процент покрашен в цвет своего
# уровня. Пустая строка, если разбивка пуста или в ней только нули.
func format_quality_share_text(quality_breakdown: Dictionary) -> String:
    var parts: Array = []
    for qid in get_quality_levels():
        var count := int(quality_breakdown.get(qid, 0))
        if count <= 0:
            continue
        parts.append("[color=#%s]%d%%[/color]" % [
            get_quality_color(str(qid)).to_html(false),
            get_quality_share_percent(count, quality_breakdown)
        ])
    if parts.is_empty():
        return ""
    return "(" + "/".join(parts) + ")"

# Случайно выбирает уровень качества по весам spawn_weight.
func roll_quality() -> String:
    var levels = get_quality_levels()
    if levels.is_empty():
        return "common"
    var total := 0.0
    for qid in levels:
        total += float(get_quality_data(qid).get("spawn_weight", 1))
    if total <= 0.0:
        return levels[0]
    var roll = randf() * total
    var accum := 0.0
    var chosen: String = levels[levels.size() - 1]
    for qid in levels:
        accum += float(get_quality_data(qid).get("spawn_weight", 1))
        if roll < accum:
            chosen = qid
            break
    return chosen

# Возвращает приоритет выбора сырья по умолчанию (из qualities.json).
func get_quality_priority_default() -> String:
    return qualities.get("priority_default", "best")

# Возвращает список доступных приоритетов выбора сырья.
func get_quality_priority_options() -> Array:
    return qualities.get("priority_options", ["best", "worst", "random"])

# Возвращает человекочитаемое название приоритета выбора сырья.
func get_quality_priority_name(priority: String) -> String:
    var names: Dictionary = qualities.get("priority_names", {})
    return names.get(priority, priority)

# --- ПРОФЕССИИ И ПОТРЕБЛЕНИЕ ---

# Возвращает данные профессии по id (или пустой словарь).
func get_profession(prof_id: String) -> Dictionary:
    return professions.get(prof_id, {})

# Возвращает имя профессии в именительном падеже («Фермер»).
# Если id не найден — возвращает сам id как fallback.
func get_profession_name(prof_id: String) -> String:
    if prof_id.is_empty():
        return ""
    return professions.get(prof_id, {}).get("name", prof_id)

# Возвращает профессию, связанную с улучшением (id из data/improvements.json).
# Если улучшение не задано или у него нет профессии — возвращает "".
# Метка производна от улучшения и отдельной строкой в интерфейсе не выводится:
# используется расчётом потребления и плановой картой вкладки «Ресурсы».
func get_profession_for_improvement(imp_id: String) -> String:
    if imp_id.is_empty() or imp_id == null:
        return ""
    return improvements.get(imp_id, {}).get("profession", "")

# Возвращает данные здания по id (или пустой словарь, если здание не найдено).
func get_building_data(building_id: String) -> Dictionary:
    if building_id.is_empty() or building_id == null:
        return {}
    for b in buildings:
        if b.get("id", "") == building_id:
            return b
    return {}

# Возвращает профессию горожанина, работающего в здании (поле "profession" в
# data/buildings.json). Пусто — у здания нет профессии: оно работает по общей
# модели слотов, без расхода расходников и без бонуса (см. docs.md,
# «Профессии и потребление ресурсов»).
func get_profession_for_building(building_id: String) -> String:
    return get_building_data(building_id).get("profession", "")

# Возвращает true, если улучшение инфраструктурное — не требует рабочего
# для выполнения своих функций. Флаг задаётся полем "no_worker": true в
# data/improvements.json (например, пристань, схема harbor_access).
# Используется worker_manager (исключение из автоназначения), панелью
# управления (без кнопок запуска/паузы) и тултипом (особый статус).
func is_no_worker_improvement(imp_id: String) -> bool:
    if imp_id.is_empty() or imp_id == null:
        return false
    return improvements.get(imp_id, {}).get("no_worker", false)

# Человекочитаемое имя улучшения по id (или сам id, если улучшения нет в
# реестре). Имя уже переведено загрузчиком данных (data_loader.
# _localize_display_fields), поэтому дополнительный tr() здесь не нужен.
func get_improvement_display_name(imp_id: String) -> String:
    if imp_id.is_empty():
        return ""
    return improvements.get(imp_id, {}).get("name", imp_id)

# Человекочитаемое имя здания по id (или сам id, если здания нет в реестре).
func get_building_display_name(building_id: String) -> String:
    if building_id.is_empty():
        return ""
    return get_building_data(building_id).get("name", building_id)

# --- ИСТОЧНИКИ ПОТОКА: ИДЕНТИФИКАТОР → ПОДПИСЬ ---
#
# Источники прихода/расхода (профессии, здания, улучшения, служебные строки)
# адресуются в плановых картах и накопителях казны ИДЕНТИФИКАТОРОМ, а не
# именем. Имя — только подпись в интерфейсе, и оно резолвится здесь, в точке
# отрисовки. Так ключи не зависят от языка (LocalizationManager.set_locale
# перечитывает данные, но не сбрасывает накопители — смена языка посреди окна
# накопления не должна делить один источник надвое) и не сливаются при
# совпадении имён.
#
# Префикс разделяет пространства имён: id "smelter" есть и у профессии
# (data/professions.json), и у здания (data/buildings.json), а в плановых
# картах оба попадают в один словарь — без префикса строки слились бы.
#   "@prof:<id>" — профессия (включая псевдо-профессию "all");
#   "@bld:<id>"  — городское здание;
#   "@imp:<id>"  — улучшение на гексе;
#   "@pop_food"  — питание населения (отдельной сущности в данных нет);
#   "@scouting" / "@claim" — разовые траты казны (разведка, освоение чанка).
# Служебные источники хранят в ключе английский текст, как TAX_INCOME_TYPE:
# tr() нельзя вызвать в выражении константы, перевод накладывает резолвер.
const SRC_PREFIX_PROFESSION := "@prof:"
const SRC_PREFIX_BUILDING := "@bld:"
const SRC_PREFIX_IMPROVEMENT := "@imp:"
const SRC_POP_FOOD := "@pop_food"
const SRC_SCOUTING := "@scouting"
const SRC_CLAIMING := "@claim"

# Идентификатор источника для сущности данных. Пустой id даёт пустой ключ —
# запись без источника в планы не идёт (вызывающие проверяют это до записи).
func profession_source_id(prof_id: String) -> String:
    return SRC_PREFIX_PROFESSION + prof_id

func building_source_id(building_id: String) -> String:
    return SRC_PREFIX_BUILDING + building_id

func improvement_source_id(imp_id: String) -> String:
    return SRC_PREFIX_IMPROVEMENT + imp_id

# Подпись источника для интерфейса: идентификатор → человекочитаемое имя.
# Неизвестный источник отдаётся как есть — недостающая запись в данных
# должна быть видна как «smelter», а не молчать пустой строкой.
func get_source_display_name(source_id: String) -> String:
    if source_id.is_empty():
        return ""
    if source_id == SRC_POP_FOOD:
        return tr("Population food")
    if source_id == SRC_SCOUTING:
        return tr("Scouting")
    if source_id == SRC_CLAIMING:
        return tr("Claiming land chunks")
    if source_id.begins_with(SRC_PREFIX_PROFESSION):
        return get_profession_name(source_id.substr(SRC_PREFIX_PROFESSION.length()))
    if source_id.begins_with(SRC_PREFIX_BUILDING):
        return get_building_display_name(source_id.substr(SRC_PREFIX_BUILDING.length()))
    if source_id.begins_with(SRC_PREFIX_IMPROVEMENT):
        return get_improvement_display_name(source_id.substr(SRC_PREFIX_IMPROVEMENT.length()))
    return source_id

# Собирает запись о потреблении из правила data/consumption.json.
# res_key — поле "resource" правила ("ид_продукта" или "@ид_группы").
# Для группы члены резолвятся через product_groups; если группа не найдена
# или amount <= 0 — возвращается пустой словарь (запись пропускается).
func _build_consumption_entry(res_key: String, rule: Dictionary) -> Dictionary:
    var amount := int(rule.get("amount", 0))
    if amount <= 0:
        print("GameData: правило потребления без корректного amount пропущено: ", rule)
        return {}
    var entry := {
        "amount": amount,
        "interval": float(rule.get("interval", 0)),
        "production_bonus": float(rule.get("production_bonus", 0.0))
    }
    if is_group_key(res_key):
        var gkey = res_key.trim_prefix("@")
        # Ключ "@"-группы — всегда id из data/product_groups.json. Поиска по
        # человекочитаемому имени тут намеренно нет: такой fallback молча
        # подставлял бы данные по похожей группе и ломал бы адресацию.
        var members: Array = product_groups.get(gkey, [])
        if members.is_empty():
            print("GameData: группа '", res_key, "' из data/consumption.json не найдена — запись пропущена.")
            return {}
        entry["product_id"] = "" # групповая запись не привязана к продукту
        entry["product_name"] = get_product_group_name(res_key)
        entry["is_group"] = true
        entry["group_members"] = members.duplicate()
        entry["display_key"] = res_key
        # Иконка группы — своя, если она задана в data/product_groups.json,
        # иначе первая иконка среди членов (GameData.get_product_group_icon_info).
        # Раньше здесь был отдельный обход членов, дублировавший правило.
        entry["icon"] = get_product_group_icon(res_key)
    else:
        entry["product_id"] = res_key
        entry["product_name"] = products.get(res_key, {}).get("name", res_key)
        entry["is_group"] = false
        entry["group_members"] = []
        entry["display_key"] = res_key
        entry["icon"] = products.get(res_key, {}).get("icon", "")
    return entry

# Возвращает массив записей о потреблении для профессии. Источники (в порядке
# приоритета):
#   1) реестр data/consumption.json — записи вида
#      { "resource": "<id>|@<группа>", "profession": ["<id>"],
#        "amount": N, "interval": S, "production_bonus": B }.
#      Поддерживает группы продуктов: потребляется любой подходящий продукт
#      из группы (см. worker_manager.tick_consumption()).
#   2) устаревшая схема «от ресурса»: поле consumption у продукта в
#      data/products/*.json (оставлено для одиночных случаев — когда у ресурса
#      нет аналогов для группы). Инфраструктура не изменена.
# Дубликаты отсекаются по display_key: один и тот же ресурс не попадёт в
# результат дважды (приоритет у записи из реестра). Каждая запись:
#   { "product_id": String, "product_name": String,
#     "amount": int, "interval": float, "production_bonus": float,
#     "is_group": bool, "group_members": Array[String],
#     "display_key": String, "icon": String }
# product_id пуст для групповых записей; product_name — имя группы.
# production_bonus — прибавка к множителю производства, пока ресурс есть
# на складе (0.5 = +50%, то есть множитель x1.5). 0 = без бонуса.
# Если профессия неизвестна или не имеет потребителей — пустой массив.
func get_profession_consumption(prof_id: String) -> Array:
    var result: Array = []
    if prof_id.is_empty():
        return result
    # Источник 1: реестр data/consumption.json.
    var covered := {} # display_key -> true (защита от двойного списания)
    for rule in consumption_rules:
        if not (rule is Dictionary):
            continue
        var target_list: Array = rule.get("profession", [])
        if not (prof_id in target_list):
            continue
        var res_key = str(rule.get("resource", ""))
        if res_key.is_empty():
            continue
        var entry = _build_consumption_entry(res_key, rule)
        if entry.is_empty():
            continue
        if covered.has(entry["display_key"]):
            continue
        covered[entry["display_key"]] = true
        result.append(entry)
    # Источник 2: потребление «от ресурса» (products[*].consumption).
    # Записи, уже покрытые реестром, пропускаются, чтобы ресурс
    # не списывался дважды одной профессией.
    for pid in products:
        var prod = products[pid]
        if not prod.has("consumption"):
            continue
        if covered.has(pid):
            continue
        var cons: Dictionary = prod["consumption"]
        var target_list: Array = cons.get("profession", [])
        if not (prof_id in target_list):
            continue
        result.append({
            "product_id": pid,
            "product_name": prod.get("name", pid),
            "amount": int(cons.get("amount", 0)),
            "interval": float(cons.get("interval", 0)),
            "production_bonus": float(cons.get("production_bonus", 0.0)),
            "is_group": false,
            "group_members": [],
            "display_key": pid,
            "icon": prod.get("icon", "")
        })
    return result

# Возвращает все ресурсы, которые потребляются профессией (без деталей по
# amount/interval) — используется для подсчёта «сколько какой профессии
# нужно таких-то ресурсов» в сводных тултипах.
# Возвращает словарь: display_key -> { "name": String, "is_group": bool,
#   "group_members": Array, "amount": int, "interval": float,
#   "production_bonus": float }.
# Ключ одиночного продукта — его id; группового ресурса — "@<id_группы>".
# Если разные ресурсы требуются с разной частотой, берётся первая встреченная.
func get_profession_consumption_summary(prof_id: String) -> Dictionary:
    var result: Dictionary = {}
    for entry in get_profession_consumption(prof_id):
        var dkey = entry.get("display_key", entry.get("product_id", ""))
        if result.has(dkey):
            continue
        result[dkey] = {
            "name": entry.get("product_name", ""),
            "is_group": bool(entry.get("is_group", false)),
            "group_members": entry.get("group_members", []),
            "amount": int(entry.get("amount", 0)),
            "interval": float(entry.get("interval", 0)),
            "production_bonus": float(entry.get("production_bonus", 0.0))
        }
    return result
