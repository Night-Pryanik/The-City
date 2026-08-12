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
