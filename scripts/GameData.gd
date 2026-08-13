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
var modifiers: Dictionary = {}
var special_actions: Dictionary = {} # id -> данные спецдействия
var qualities: Dictionary = {} # данные о степенях качества ресурсов
var map_config: Dictionary = {} # конфигурация карты мира (data/map_config.json)

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
    modifiers = loader.modifiers
    special_actions = loader.special_actions
    qualities = loader.qualities
    map_config = loader.map_config

# Возвращает имя группы по её ключу (с символом "@" или без).
# Если ключ не является группой, возвращает пустую строку.
func get_product_group_name(key: String) -> String:
    var gkey = key.trim_prefix("@")
    if product_group_names.has(gkey):
        return product_group_names[gkey]
    return ""

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
    return products.get(key, {}).get("name", key)

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
