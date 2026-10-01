# icon_registry.gd (автозагрузка IconRegistry)
#
# ЕДИНСТВЕННЫЙ источник истины по иконкам: индекс имён файлов из res://icons
# строится ОДИН раз за игру, а не в каждом модуле отдельно.
#
# ПОЧЕМУ ТАК. Раньше рекурсивный обход res://icons был продублирован в восьми
# местах (map_renderer, resources_tab, buildings_tab — дважды в одном файле,
# building_panel, tech_tree, town_ui, trade_tab). Правила индексации при этом
# расходились: где-то дубль перезаписывал путь, где-то игнорировался, где-то
# печаталось предупреждение, а где-то нет; и половина индекса — это 288
# файлов *.import, которые в индексе бесполезны. Хуже всего buildings_tab
# собирал локальный индекс внутри _show_building_details, то есть обходил 576
# файлов при каждом наведении на здание.
#
# @tool обязателен: map_renderer.gd и main_map.gd помечены @tool и обращаются
# к иконкам из редактора, а автозагрузка без @tool в дерево редактора не
# попадает — сцена падала бы с «Identifier not found».
@tool
extends Node

# Корень, в котором ищутся иконки. В данных (data/*.json) хранится только имя
# файла, поэтому индексируется basename, а не путь.
const ROOT := "res://icons"

# Служебные файлы, попадающие в res://icons при обходе, но не являющиеся
# иконками: *.import лежит рядом с картинкой, *.remap появляется в сборке.
# Раньше они занимали половину индекса (288 из 576 записей).
const SKIP_SUFFIXES := [".import", ".remap"]

# Имя файла (basename) -> полный res://-путь.
var paths: Dictionary = {}
# Имя файла -> загруженная Texture2D. Общий кэш на весь проект: раньше
# одинаковые словари-кэши текстур жили в шести модулях.
var _textures: Dictionary = {}
# Индекс уже построен — защита от повторного обхода (ленивая постройка).
var _built := false

func _ready() -> void:
    _ensure_built()

# Ленивая постройка: страхует от обращения к реестру раньше _ready
# (например, из @tool-сцены в редакторе или из headless-теста).
func _ensure_built() -> void:
    if _built:
        return
    build()

# Перестраивает индекс с нуля. Идемпотентен: повторный вызов даёт тот же
# результат (проверяется тестом). Нужен и для починки, и для теста.
func build() -> void:
    paths.clear()
    var duplicates: Array = []
    _scan_folder(ROOT, duplicates)
    _built = true
    if not duplicates.is_empty():
        # Одно предупреждение на все дубликаты: раньше каждая из восьми копий
        # обхода печатала своё, а три из них молчали.
        push_warning("IconRegistry: дубликаты имён иконок (первый путь оставлен): %s"
            % ", ".join(PackedStringArray(duplicates)))

func _scan_folder(folder_path: String, duplicates: Array) -> void:
    var dir := DirAccess.open(folder_path)
    if dir == null:
        return
    dir.list_dir_begin()
    var file_name := dir.get_next()
    while not file_name.is_empty():
        if dir.current_is_dir():
            _scan_folder(folder_path.path_join(file_name), duplicates)
        else:
            var key := _index_key(file_name)
            if not key.is_empty():
                if paths.has(key):
                    # Дубль НЕ перезаписывает первый путь: иначе картинка из
                    # вложенной папки молча подменяла бы ту же, что в корне.
                    duplicates.append(key)
                else:
                    paths[key] = folder_path.path_join(file_name)
        file_name = dir.get_next()
    dir.list_dir_end()

# Имя, под которым файл попадает в индекс; "" — файл служебный, иконкой не
# является. В данных хранится только имя файла, поэтому индексируется basename.
func _index_key(file_name: String) -> String:
    if file_name.begins_with("."):
        return ""
    for suffix in SKIP_SUFFIXES:
        if file_name.ends_with(suffix):
            return ""
    return file_name

# Есть ли иконка с таким именем файла.
func has(icon_name: String) -> bool:
    return paths.has(icon_name)

# Полный res://-путь иконки; "" если файла нет. Нужен там, где движок ждёт
# путь, а не текстуру: тег [img=…] в BBCode.
# Имя НЕ get_path(): у Node этот метод уже занят возвратом NodePath.
func icon_path(icon_name: String) -> String:
    _ensure_built()
    return paths.get(icon_name, "")

# Текстура иконки с общим кэшем; null если имя пустое или файла нет
# (тогда иконка просто не ставится).
func get_texture(icon_name: String) -> Texture2D:
    if icon_name.is_empty():
        return null
    _ensure_built()
    if _textures.has(icon_name):
        return _textures[icon_name]
    var path: String = paths.get(icon_name, "")
    if path.is_empty():
        return null
    var tex: Texture2D = load(path)
    if tex == null:
        return null
    _textures[icon_name] = tex
    return tex

# Сколько иконок в индексе — для теста.
func count() -> int:
    _ensure_built()
    return paths.size()