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
var professions: Dictionary = {} # id -> данные профессии (data/professions.json)
var consumption_rules: Array = [] # записи потребления (data/consumption.json)

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
    professions = loader.professions
    consumption_rules = loader.consumption_rules

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
# Используется для отображения «Профессия: ...» в тултипе и панели.
func get_profession_for_improvement(imp_id: String) -> String:
    if imp_id.is_empty() or imp_id == null:
        return ""
    return improvements.get(imp_id, {}).get("profession", "")

# Возвращает true, если улучшение инфраструктурное — не требует рабочего
# для выполнения своих функций. Флаг задаётся полем "no_worker": true в
# data/improvements.json (например, пристань, схема harbor_access).
# Используется worker_manager (исключение из автоназначения), панелью
# управления (без кнопок запуска/паузы) и тултипом (особый статус).
func is_no_worker_improvement(imp_id: String) -> bool:
    if imp_id.is_empty() or imp_id == null:
        return false
    return improvements.get(imp_id, {}).get("no_worker", false)

# Ищет id группы продуктов по человекочитаемому имени.
# Используется как fallback при разборе "@"-ключей реестра потребления
# (по аналогии с разбором групповых рецептов в CityData). Если группа не
# найдена — пустая строка.
func _find_group_id_by_name(group_name: String) -> String:
    for gid in product_group_names:
        if product_group_names[gid] == group_name:
            return gid
    return ""

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
        var members: Array = product_groups.get(gkey, [])
        if members.is_empty():
            # Fallback: поиск группы по человекочитаемому имени (как в рецептах).
            var gid_by_name = _find_group_id_by_name(gkey)
            if not gid_by_name.is_empty():
                members = product_groups.get(gid_by_name, [])
        if members.is_empty():
            print("GameData: группа '", res_key, "' из data/consumption.json не найдена — запись пропущена.")
            return {}
        entry["product_id"] = "" # групповая запись не привязана к продукту
        entry["product_name"] = get_product_group_name(res_key)
        entry["is_group"] = true
        entry["group_members"] = members.duplicate()
        entry["display_key"] = res_key
        # Иконка группы: первый член, у которого иконка задана.
        var icon_name := ""
        for mid in members:
            var mdata: Dictionary = products.get(mid, {})
            if mdata.has("icon"):
                icon_name = mdata["icon"]
                break
        entry["icon"] = icon_name
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
