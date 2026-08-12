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
var modifiers: Dictionary = {}
var special_actions: Dictionary = {} # id -> данные спецдействия
var qualities: Dictionary = {} # данные о степенях качества ресурсов

func load_all_data():
    var merged_data = _load_all_json_files("res://data")
    if merged_data == null:
        print("Ошибка: не удалось загрузить данные из папки data.")
        return

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
    for pg in merged_data.get("product_groups", []):
        if pg is Dictionary:
            var group_id = pg.get("id", "")
            if not group_id.is_empty():
                product_groups[group_id] = pg.get("products", [])
                product_group_names[group_id] = pg.get("name", group_id)

    # НОВОЕ: загружаем глобальные модификаторы
    modifiers = merged_data.get("modifiers", {})

    # НОВОЕ: загружаем спецдействия (вырубка леса, осушение болот и т.п.)
    special_actions = {}
    for sa in merged_data.get("special_actions", []):
        if sa is Dictionary:
            var sa_id = sa.get("id", "")
            if not sa_id.is_empty():
                special_actions[sa_id] = sa

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
                    _merge_dictionaries(result, data)
        file_name = dir.get_next()
    dir.list_dir_end()
    return result

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
