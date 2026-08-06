# data_loader.gd
@tool
extends Node

var terrains: Dictionary = {}
var raw_resources: Dictionary = {}
var products: Dictionary = {}
var improvements: Dictionary = {}
var crafts: Array = []
var buildings: Array = []
var categories: Array = []
var technologies: Array = []
var groups: Array = []
var product_groups: Dictionary = {} # id -> products
var product_group_names: Dictionary = {} # id -> human-readable name

func load_all_data():
    var merged_data = _load_all_json_files("res://data")
    if merged_data == null:
        print("Ошибка: не удалось загрузить данные из папки data.")
        return

    terrains = {}
    for t in merged_data.get("terrains", []):
        terrains[t["id"]] = t

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

    # НОВОЕ: загружаем группы товаров
    product_groups = {}
    product_group_names = {}
    for pg in merged_data.get("product_groups", []):
        product_groups[pg["id"]] = pg["products"]
        product_group_names[pg["id"]] = pg.get("name", pg["id"])

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
                var data = JSON.parse_string(text)
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
