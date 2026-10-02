# data_loader.gd
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
var product_groups: Dictionary = {} # id -> products
var product_group_names: Dictionary = {} # id -> human-readable name
var product_group_icons: Dictionary = {} # id -> имя файла иконки ("" — не задана)
var modifiers: Dictionary = {}
var special_actions: Dictionary = {} # id -> данные спецдействия
var qualities: Dictionary = {} # данные о степенях качества ресурсов
var map_config: Dictionary = {} # конфигурация карты мира (data/map_config.json)
var professions: Dictionary = {} # id -> данные профессии (data/professions.json)
var consumption_rules: Array = [] # записи потребления из data/consumption.json
var city_names: Array = [] # варианты названий города (data/city_names.json)
var game_balance: Dictionary = {} # игровой баланс (data/game_balance.json)
# Уровни дорог (data/roads.json). roads_by_level — уровень -> данные уровня:
# участок сети дорог хранит номер уровня, поэтому нужен именно такой индекс.
var roads: Array = []
var roads_by_level: Dictionary = {}

# Откуда пришла каждая сущность: "коллекция:id" → { "file": String, "line": int }.
# Заполняется при чтении файлов (_remember_sources), потому что после слияния
# файлов в один словарь происхождение уже не восстановить. Нужен рантайм-валидатору
# (scripts/data_validator.gd), чтобы указывать проблему на конкретный файл и
# строку. Подробности — в шапке _remember_sources.
var entity_sources: Dictionary = {}

# Поля данных, значение которых видит игрок. В data/*.json лежит английский
# исходный текст, а перевод накладывается здесь, при чтении файлов: ключом
# перевода служит сам английский текст. Благодаря этому остальному коду не
# нужно знать про локализацию — он по-прежнему читает "name"/"description".
const DISPLAY_FIELDS := ["name", "description", "flavor"]

# Поля-словари, где подпись для игрока лежит в ЗНАЧЕНИИ, а ключ — служебный
# идентификатор (см. _localize_display_fields).
const VALUE_MAP_FIELDS := ["priority_names"]

# Верхнеуровневые ключи, у элементов которых есть "id" — по ним и ищем
# объявление сущности. Порядок и состав повторяют то, что разбирает load_all_data.
const SOURCE_COLLECTIONS := [
    "resources",
    "crafts",
    "buildings",
    "improvements",
    "technologies",
    "categories",
    "professions",
    "product_groups",
    "roads",
    # Коллекции, на которые не ссылается ни одна проверка битых ссылок, но
    # чьи идентификаторы проверяет data_validator.gd на алфавит и омоглифы.
    # Без них проблема «carmine с кириллической с» указала бы на сущность без
    # файла и строки — а файл и строка здесь и есть главная ценность.
    "terrains",
    "covers",
    "eras",
    "groups",
    "quality_levels",
    "special_actions",
]

func load_all_data():
    var merged_data = _load_all_json_files("res://data")
    if merged_data == null:
        print("Ошибка: не удалось загрузить данные из папки data.")
        return

    # Перевод накладывается ДО сборки сущностей в словари: дальше все, кто
    # читает GameData.products[id]["name"], получают уже готовый к показу
    # текст на текущем языке. Смена языка перечитывает данные заново
    # (LocalizationManager.set_locale → GameData.load_all_data).
    _localize_display_fields(merged_data)

    terrains = {}
    for t in merged_data.get("terrains", []):
        terrains[t["id"]] = t

    covers = {}
    for c in merged_data.get("covers", []):
        covers[c["id"]] = c

    raw_resources = {}
    products = {}
    for r in merged_data.get("resources", []):
        var res_type = r.get("type", "")
        if res_type == "raw":
            raw_resources[r["id"]] = r
        elif res_type == "product":
            products[r["id"]] = r

    improvements = {}
    for i in merged_data.get("improvements", []):
        improvements[i["id"]] = i

    crafts = merged_data.get("crafts", [])
    buildings = merged_data.get("buildings", [])
    categories = merged_data.get("categories", [])
    technologies = merged_data.get("technologies", [])
    groups = merged_data.get("groups", [])
    eras = merged_data.get("eras", [])

    # НОВОЕ: загружаем группы товаров
    product_groups = {}
    product_group_names = {}
    product_group_icons = {}
    for pg in merged_data.get("product_groups", []):
        if pg is Dictionary:
            var group_id = pg.get("id", "")
            if not group_id.is_empty():
                product_groups[group_id] = pg.get("products", [])
                product_group_names[group_id] = pg.get("name", group_id)
                # Необязательное поле "icon": своя иконка группы. Пустая строка
                # — иконка не задана, тогда GameData возьмёт иконку первого
                # члена с иконкой (см. GameData.get_product_group_icon).
                product_group_icons[group_id] = str(pg.get("icon", ""))

    # НОВОЕ: загружаем глобальные модификаторы
    modifiers = merged_data.get("modifiers", {})

    # НОВОЕ: загружаем спецдействия (вырубка леса, осушение болот и т.п.)
    special_actions = {}
    for sa in merged_data.get("special_actions", []):
        if sa is Dictionary:
            var sa_id = sa.get("id", "")
            if not sa_id.is_empty():
                special_actions[sa_id] = sa

    # Названия городов: в файле это объект { "city_names": [...] }.
    var cn = merged_data.get("city_names", [])
    if cn is Array:
        city_names = cn

    # НОВОЕ: загружаем уровни дорог (data/roads.json). roads_by_level нужен
    # участку сети дорог: он хранит номер уровня, а не id.
    roads = []
    roads_by_level = {}
    for road in merged_data.get("roads", []):
        if road is Dictionary:
            roads.append(road)
            roads_by_level[int(road.get("level", 0))] = road

    # НОВОЕ: загружаем данные о степенях качества ресурсов.
    # В data/qualities.json ключи лежат на верхнем уровне (quality_levels,
    # priority_default и т.д.), поэтому собираем их вручную. Дополнительно
    # поддерживаем вариант с вложенным словарём "qualities".
    qualities = {}
    var nested_qualities = merged_data.get("qualities", {})
    if nested_qualities is Dictionary:
        for key in nested_qualities.keys():
            qualities[key] = nested_qualities[key]
    for key in ["quality_levels", "priority_default", "priority_options", "priority_names"]:
        if merged_data.has(key):
            qualities[key] = merged_data[key]

    # НОВОЕ: загружаем конфигурацию карты мира (размеры, стартовое кольцо, регион).
    # Файл data/map_config.json содержит ключ "map_config" с параметрами:
    # map_rows / map_cols / start_ring_rows / start_ring_cols / region_width.
    map_config = merged_data.get("map_config", {})

    # НОВОЕ: загружаем профессии рабочих на улучшениях (data/professions.json).
    # Поля профессии:
    #   id          — строковый идентификатор (snake_case);
    #   name        — именительный падеж, ед.ч. («Фермер»);
    #   icon        — имя файла иконки;
    #   description — короткое описание.
    # Подробности схемы потребления ресурсов профессией — в docs.md, раздел
    # «Профессии и потребление».
    professions = {}
    for p in merged_data.get("professions", []):
        if p is Dictionary:
            var pid = p.get("id", "")
            if not pid.is_empty():
                professions[pid] = p

    # НОВОЕ: загружаем реестр профессионального потребления
    # (data/consumption.json). Каждая запись:
    #   resource          — id продукта ИЛИ "@<id>" группы из product_groups.json;
    #   profession        — массив id профессий-потребителей;
    #   amount/interval/production_bonus — параметры тика потребления.
    # Группы позволяют профессии потреблять любой подходящий продукт из
    # набора (например, "@boats" — «Лодки»). Подробности — в docs.md,
    # раздел «Профессии и потребление ресурсов».
    consumption_rules = []
    for cr in merged_data.get("consumption", []):
        if cr is Dictionary and not str(cr.get("resource", "")).is_empty():
            consumption_rules.append(cr)

    # НОВОЕ: загружаем игровой баланс (data/game_balance.json).
    # Числовые константы игры: стартовая казна города, множитель цены
    # внутреннего рынка и т.п. Ключ "game_balance" лежит на верхнем уровне.
    game_balance = merged_data.get("game_balance", {})


# Переводит значения полей, которые видит игрок (DISPLAY_FIELDS), на текущий
# язык игры. Обход рекурсивный: одна функция покрывает и плоские списки
# сущностей, и вложенные (technologies[].unlock_effects[].name).
#
# Отдельный случай — qualities.json: там "priority_names" это словарь
# {код_приоритета: подпись для игрока}, то есть подпись лежит в ЗНАЧЕНИИ, а
# ключ остаётся служебным. Такие словари перечислены в VALUE_MAP_FIELDS.
func _localize_display_fields(node: Variant) -> void:
    if node is Dictionary:
        for key in node.keys():
            var value: Variant = node[key]
            if DISPLAY_FIELDS.has(key) and value is String:
                node[key] = tr(str(value))
            elif VALUE_MAP_FIELDS.has(key) and value is Dictionary:
                for option_key in value.keys():
                    if value[option_key] is String:
                        value[option_key] = tr(str(value[option_key]))
            else:
                _localize_display_fields(value)
    elif node is Array:
        for item in node:
            _localize_display_fields(item)


func _load_all_json_files(folder_path: String) -> Dictionary:
    var result = {}
    var dir = DirAccess.open(folder_path)
    if dir == null:
        print("Ошибка: не удалось открыть папку ", folder_path)
        return result

    dir.list_dir_begin()
    var file_name = dir.get_next()
    while file_name != "":
        if dir.current_is_dir():
            var sub_result = _load_all_json_files(folder_path.path_join(file_name))
            _merge_dictionaries(result, sub_result)
        elif file_name.ends_with(".json"):
            var file_path = folder_path.path_join(file_name)
            var file = FileAccess.open(file_path, FileAccess.READ)
            if file == null:
                print("Ошибка: не удалось открыть файл ", file_path)
            else:
                var text = file.get_as_text()
                # Очищаем текст от комментариев
                var cleaned = _strip_json_comments(text)
                var data = JSON.parse_string(cleaned)
                if data == null:
                    print("Ошибка: не удалось распарсить JSON из ", file_path)
                else:
                    _remember_sources(file_path, text, data)
                    _merge_dictionaries(result, data)
        file_name = dir.get_next()
    dir.list_dir_end()
    return result

# --- ПРОИСХОЖДЕНИЕ СУЩНОСТЕЙ (файл + строка) -------------------------------
#
# _merge_dictionaries сливает файлы в один словарь и место каждой сущности
# стирает: после загрузки не сказать, объявлена ли «Пшеница» в
# data/products/food.json или в data/products/products.json. Рантайм-валидатор
# (scripts/data_validator.gd) на этом и спотыкается: он умеет назвать проблему
# («Продукта «sunflower» не существует»), но без файла автору пришлось бы искать
# опечатку вручную по всем файлам data/.
#
# Поэтому параллельно со слиянием записывается индекс: "коллекция:id" → файл и
# строка объявления. Именно объявления, а не упоминания: id может встретиться
# в файле и как член группы, и как результат рецепта, и номер строки тогда
# указал бы не туда.
func _remember_sources(file_path: String, raw_text: String, data: Dictionary):
    if not (data is Dictionary):
        return
    for collection in SOURCE_COLLECTIONS:
        var entries = data.get(collection, null)
        if not (entries is Array):
            continue
        for entry in entries:
            if not (entry is Dictionary):
                continue
            var id := str(entry.get("id", ""))
            if id.is_empty():
                continue
            entity_sources["%s:%s" % [collection, id]] = {
                "file": file_path,
                "line": _find_decl_line(raw_text, id),
            }
    _remember_consumption_sources(file_path, raw_text, data)


# Правила потребления (data/consumption.json) идентификатора в себе не имеют:
# запись объявляется полями resource/profession/amount/interval, а поля "id" в
# ней нет, поэтому общий проход выше их пропускает. Без отдельного прохода
# проблема «ресурс не существует» осталась бы без указания файла — а файл и
# строка здесь и есть главная ценность сообщения.
#
# Ключом служит само значение "resource" (с "@" для групп). Так ключ индекса
# совпадает с тем, что валидатор передаёт как source_id
# (data_validator._validate_consumption), и обе стороны сходятся.
#
# Совпадение ключа у двух правил с одинаковым ресурром невозможно: реестр это
# запрещает (GameData.get_profession_consumption отбрасывает дубль по
# display_key), поэтому перезапись индекса тут не случается.
func _remember_consumption_sources(file_path: String, raw_text: String, data: Dictionary):
    var rules = data.get("consumption", null)
    if not (rules is Array):
        return
    for rule in rules:
        if not (rule is Dictionary):
            continue
        var res_key := str(rule.get("resource", ""))
        if res_key.is_empty():
            continue
        entity_sources["consumption:%s" % res_key] = {
            "file": file_path,
            "line": _find_resource_decl_line(raw_text, res_key),
        }


# Строка объявления правила потребления — та, где стоит поле "resource" с этим
# значением.
#
# Свой _find_decl_line здесь не годится: он ищет первое вхождение значения в
# СЫРОМ тексте, комментарии не вырезает, и объявление опережает любой комментарий
# вида // ... "resource" со значением, о котором автор пишет пояснение. Указание
# тогда указывает на пояснение, а не на правило, — ровно то, ради чего индекс
# происхождения и затевался.
func _find_resource_decl_line(raw_text: String, res_key: String) -> int:
    var needle := "\"%s\"" % res_key
    var lines := raw_text.split("\n")
    for i in lines.size():
        var line: String = lines[i]
        # Имя поля и значение в одной строке — компактная запись
        # { "resource": "@boats", ... }. Многострочная запись не встречается,
        # но и в этом случае вернётся 0, а не укажет на чужую строку.
        if line.contains("\"resource\"") and line.contains(needle):
            return i + 1
    return 0

# Строка, на которой сущность с таким id ОБЪЯВЛЕНА, — или 0, если не нашлась.
#
# Ищем в ИСХОДНОМ тексте файла, а не в очищенном от комментариев: _strip_json_comments
# выбрасывает переносы строк внутри /* … */, поэтому нумерация строк очищенного
# текста не совпала бы с тем, что автор видит в редакторе (у data/improvements.json
# шапка-комментарий занимает полэкрана).
#
# Сначала ищем строку, где id стоит рядом с "id" (компактная запись
# { "id": "salt", "price": 6 }) — это и есть объявление. Если такой нет, берём
# первую строку, где id вообще встречается: у многострочных записей вроде
# product_groups.json (id в одной строке, "products" — в следующих) это всё
# равно приводит к строке объявления.
func _find_decl_line(raw_text: String, id: String) -> int:
    var needle := "\"%s\"" % id
    var lines := raw_text.split("\n")
    var fallback := 0
    for i in lines.size():
        var line: String = lines[i]
        if not line.contains(needle):
            continue
        if line.contains("\"id\""):
            return i + 1
        if fallback == 0:
            fallback = i + 1
    return fallback

func _merge_dictionaries(target: Dictionary, source: Dictionary):
    for key in source.keys():
        if target.has(key) and typeof(target[key]) == TYPE_ARRAY and typeof(source[key]) == TYPE_ARRAY:
            target[key].append_array(source[key])
        elif target.has(key) and typeof(target[key]) == TYPE_DICTIONARY and typeof(source[key]) == TYPE_DICTIONARY:
            for subkey in source[key]:
                target[key][subkey] = source[key][subkey]
        else:
            target[key] = source[key]

func _strip_json_comments(json_string: String) -> String:
    var result = ""
    var in_string = false
    var in_single_line_comment = false
    var in_multi_line_comment = false
    var i = 0
    while i < json_string.length():
        var c = json_string[i]
        var next_c = json_string[i + 1] if i + 1 < json_string.length() else ""
        var prev_c = json_string[i - 1] if i > 0 else ""

        if not in_string and not in_single_line_comment and not in_multi_line_comment:
            if c == '"':
                in_string = true
                result += c
                i += 1
                continue
            elif c == '/' and next_c == '/':
                in_single_line_comment = true
                i += 2
                continue
            elif c == '/' and next_c == '*':
                in_multi_line_comment = true
                i += 2
                continue

        if in_string:
            if c == '"' and prev_c != '\\':
                in_string = false
            result += c
            i += 1
            continue

        if in_single_line_comment:
            if c == '\n':
                in_single_line_comment = false
                result += c # оставляем перенос строки
            i += 1
            continue

        if in_multi_line_comment:
            if c == '*' and next_c == '/':
                in_multi_line_comment = false
                i += 2
                continue
            i += 1
            continue

        result += c
        i += 1

    return result
