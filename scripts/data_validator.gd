# data_validator.gd
# Рантайм-валидатор перекрёстных ссылок в data/*.json.
#
# Запускается ПОСЛЕ загрузки данных и ДО начала игры (см. main_menu.gd),
# чтобы автор данных узнавал о битых ссылках не из консоли, а из окна с
# точным указанием проблемной сущности.
#
# Проверяются ССЫЛКИ между сущностями (не синтаксис JSON — этим занят
# tools/validate_json.py). Проблема хранится в двух слоях:
#
#   1) СТРУКТУРА — от языка не зависит: что не так, где и в каком поле.
#   2) ТЕКСТ — переводится (см. build_text ниже). Собирается ОТДЕЛЬНО от
#      проверки именно потому, что язык можно переключить, не прогоняя
#      проверку заново: localize_problems() пересобирает тексты на новом
#      языке по той же структуре.
#
#   {
#     "kind":        String,  # машинное имя проверки, напр. "produced_in"
#     "check_title": String,  # заголовок группы проверки для окна
#     "target_title":String,  # "Building" — вид искомой сущности
#     "ref_id":      String,  # искомый идентификатор ("x")
#     "source_kind": String,  # вид сущности-владельца ("recipe")
#     "source_name": String,  # её название из данных ("Grain Mill")
#     "source_id":   String,  # её идентификатор ("grind_grain_hand")
#     "field":       String,  # поле, в котором нашли ссылку
#     "file":        String,  # файл, в котором объявлен владелец ссылки
#     "line":        int,     # строка объявления в этом файле (0 — неизвестно)
#     "headline":    String,  # первая строка сообщения
#     "where":       String,  # вторая строка: где именно нашли ссылку
#     "location":    String,  # третья строка: "File: …, line N." ("" — нет)
#     "message":     String,  # все строки вместе (для логов и тестов)
#   }
#
# Проверки:
#   id_charset         — идентификатор вне ASCII (кириллица в id неотличима от латиницы)
#   id_lookalike       — идентификатор отличается от другого только похожими символами
#   produced_in        — рецепт ссылается на несуществующее здание
#   result             — рецепт (result / display_result) даёт несуществующий ресурс
#   improved_by        — ресурс улучшается несуществующим улучшением
#   unlock_improvement — продукт открывается несуществующим улучшением
#   unlock_tech        — здание/улучшение/продукт/рецепт → несуществующая технология
#   profession         — здание/улучшение → несуществующая профессия
#   category           — продукт → несуществующая категория
#   product_source     — продукт не производится НИ картой, НИ рецептом
#   group_member       — в @-группе несуществующий продукт
#   resource_group     — рецепт ссылается на несуществующую @-группу
#   resource           — рецепт требует несуществующий ресурс
#   consumption_resource— правило потребления → несуществующий продукт
#   consumption_group   — правило потребления → несуществующая @-группа
#   prerequisite       — технология требует несуществующую технологию
#   road_level         — у уровня дороги неверный или повторяющийся номер
#   road_max_speed     — у уровня дороги неположительная максимальная скорость
#   road_work_cost     — у уровня дороги отрицательная цена участка
#
# Класс НЕ зависит от автозагрузок: проверяемые данные передаются
# аргументом, поэтому валидатор гоняется headless-тестом на искусственных
# данных (tests/test_data_validation.gd).
extends RefCounted

# Служебный маркер produced_in: «рецепт производится в ЛЮБОМ здании».
# Обрабатывается в CityData.can_craft_in, поэтому это НЕ битая ссылка —
# пропускаем, иначе валидатор ругался бы на псевдорецепт "empty".
const ANY_BUILDING_MARKER := "*"

# --- ЛЕСНАЯ ДЕЛЯНКА: единственный производитель, которого НЕТ в produces ---
#
# Продукт «Древесина» не участвует ни в одном produces: её делает лесная
# делянка на ПУСТОМ лесном гексе, и выход берётся из поля wood_yield
# ПОКРОВА (data/covers.json), а не из ресурса на гексе:
#
#   main_map.gd, тик производства → CityData.add_to_storage("wood", …)
#   MapHelpers.get_cover_wood_yield(tile) — покров → wood_yield
#
# Связь «покров → делянка → продукт» зашита в код, поэтому из данных её
# не видно, и наивная сверка объявила бы древесину продуктом без
# источника. Здесь связь восстанавливается ЧИТАТЕЛЬНО: источник есть, если
# делянка объявлена И хотя бы у одного покрова wood_yield > 0. Если автор
# уберёт делянку или выход с покровов — валидатор честно скажет, что
# древесина недостижима (см. тест tests/test_data_validation.gd).
const LUMBERJACK_PRODUCT := "wood"
const LUMBERJACK_IMPROVEMENT := "lumberjack_hut"
const COVER_YIELD_FIELD := "wood_yield"

# --- ПРАВИЛА ИДЕНТИФИКАТОРОВ ---------------------------------------------
#
# Идентификаторы — это ключи, по которым данные сшиваются между файлами, и
# потому что автор ищет их глазами в редакторе. Оба свойства ломаются
# молча, поэтому проверяются отдельно.
#
# РАЗРЕШЁННЫЙ АЛФАВИТ: латинские буквы a-z, цифры и подчёркивание. Именно
# этот набор используется во всех 515 идентификаторах data/, поэтому строгое
# правило не даёт ни одного ложного срабатывания. Всё остальное — пробелы,
# дефисы, капс, кириллица — ошибка, и каждая из них опасна: автор не видит
# разницы между «carmine» и «сarmine» (кириллическая с) на глаз.
const IDENT_CHARS := "abcdefghijklmnopqrstuvwxyz0123456789_"
const IDENT_UPPER := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

# Символы, которые неотличимы от латинских на глаз → их латинский вид.
#
# Нужны для подсказки в сообщении: напечатать в тексте «с» бесполезно —
# автор прочитает её как «c» и решит, что всё в порядке. Поэтому в сообщение
# попадает КОД Unicode (U+0441) и подсказка «на латинице это c».
#
# Таблица НЕполная и НЕ является отображением всех похожих символов: она
# покрывает тот случай, который реально встречался (кириллица в русской
# раскладке при наборе латинских id). Если символа в таблице нет — подсказка
# просто не выводится, и это честнее, чем угадывать вид «на глаз».
const IDENT_LOOKALIKES := {
    "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h",
    "о": "o", "р": "p", "с": "c", "т": "t", "у": "y", "х": "x",
    "і": "i", "ј": "j", "ѕ": "s", "ԁ": "d", "һ": "h", "ӏ": "l",
    "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H",
    "О": "O", "Р": "P", "С": "C", "Т": "T", "У": "Y", "Х": "X",
}

# Диапазоны Unicode-блоков, в которых ошибка правдоподобна. Имя блока НЕ
# хранится здесь: константа не может вызвать перевод, а сборщик каталога
# (tools/i18n_build_po.py) берёт msgid литералом прямо в вызове
# translate() — из словаря он его не достанет. Подписи лежат в
# _block_label() ниже, а здесь остаются только границы диапазонов.
const IDENT_BLOCKS := [
    {"from": 0x0400, "to": 0x04FF, "key": "cyrillic"},
    {"from": 0x0370, "to": 0x03FF, "key": "greek"},
    {"from": 0xFF10, "to": 0xFF19, "key": "fullwidth_latin"},
]

# Коллекции с идентификаторами: где искать объявления.
#
# Единый список для проверок id_charset / id_lookalike: они ортогональны
# остальным проверкам (тем важно ЗНАЧЕНИЕ ссылок, этим — сам текст id), и
# держать список в одном месте дешевле, чем добавлять по вызову в каждую из
# пятнадцати коллекций. Пары «поле GameData → вид сущности для сообщения»:
# второе нужно, чтобы в тексте проблемы было «Продукта», а не «Ресурса».
const IDENT_COLLECTIONS := [
    {"field": "products", "kind": "product"},
    {"field": "raw_resources", "kind": "product"},
    {"field": "improvements", "kind": "improvement"},
    {"field": "professions", "kind": "profession"},
    {"field": "product_groups", "kind": "group"},
    {"field": "qualities", "kind": "quality_level"},
    {"field": "special_actions", "kind": "special_action"},
    {"field": "terrains", "kind": "terrain"},
    {"field": "covers", "kind": "cover"},
    {"field": "crafts", "kind": "recipe"},
    {"field": "buildings", "kind": "building"},
    {"field": "technologies", "kind": "technology"},
    {"field": "categories", "kind": "category"},
    {"field": "eras", "kind": "era"},
    {"field": "roads", "kind": "road"},
]

# Уровни качества лежат не в словаре, а в массиве внутри словаря
# (data/qualities.json → "quality_levels": [...]), поэтому обрабатываются
# отдельно: обход коллекций выше проходит по полям GameData и такой вложенный
# список не увидит.
const QUALITY_LEVELS_FIELD := "quality_levels"

# Виды сущностей, встречающихся в тексте проблемы.
#
# Это список для подстановки запасного вида, а не источник подписей: сами
# подписи живут в entity_forms() ниже. Словарь с названиями стоял бы ровно
# затем, чтобы их значения не попали в каталог переводов — см. примечание
# к entity_forms() про то, как их читает сборщик.
const ENTITIES := [
    "building", "product", "improvement", "technology", "profession",
    "category", "group", "recipe", "road", "terrain", "cover", "era",
    "quality_level", "special_action", "consumption_rule",
]


# Названия вида сущности в трёх грамматических формах:
#   title  — родительный падеж («Здания с идентификатором «x» не существует»);
#   ref    — винительный падеж («Ссылка на это здание присутствует в…»);
#   source — предложный падеж («…присутствует в рецепте «…»»).
#
# Английский падежей не знает, поэтому три формы — это три разных msgid
# («Building», «this building», «building»), а по-русски им соответствуют
# «Здания», «это здание», «здании». msgctxt при этом не нужен: английские
# тексты и так разные, а различие уезжает в саму формулировку. Ровно тот же
# приём, что с множественными числами в consumption_ui.gd.
#
# Подписи перечислены ЯВНО, литералами прямо в вызовах translate(), а не
# взяты из словаря константы. Это требование сборщика каталога:
# tools/i18n_build_po.py разбирает код построчно и берёт msgid литералом в
# этом вызове. Словарь спрятал бы msgid от сканера, и в locale/<код>.po
# переводов этих подписей просто не оказалось бы — они остались бы
# английскими при любом языке.
#
# fallback — вид на случай неизвестного ключа: «product» для искомой
# сущности, «recipe» для владельца ссылки (см. _add).
static func entity_forms(kind: String, fallback: String = "product") -> Dictionary:
    if not ENTITIES.has(kind):
        kind = fallback
    match kind:
        "building":
            return {"title": TranslationServer.translate("Building", "validator_entity_title_building"),
                "ref": TranslationServer.translate("this building", "validator_entity_ref_building"),
                "source": TranslationServer.translate("building", "validator_entity_source_building")}
        "product":
            return {"title": TranslationServer.translate("Product", "validator_entity_title_product"),
                "ref": TranslationServer.translate("this product", "validator_entity_ref_product"),
                "source": TranslationServer.translate("product", "validator_entity_source_product")}
        "improvement":
            return {"title": TranslationServer.translate("Improvement", "validator_entity_title_improvement"),
                "ref": TranslationServer.translate("this improvement", "validator_entity_ref_improvement"),
                "source": TranslationServer.translate("improvement", "validator_entity_source_improvement")}
        "technology":
            return {"title": TranslationServer.translate("Technology", "validator_entity_title_technology"),
                "ref": TranslationServer.translate("this technology", "validator_entity_ref_technology"),
                "source": TranslationServer.translate("technology", "validator_entity_source_technology")}
        "profession":
            return {"title": TranslationServer.translate("Profession", "validator_entity_title_profession"),
                "ref": TranslationServer.translate("this profession", "validator_entity_ref_profession"),
                "source": TranslationServer.translate("profession", "validator_entity_source_profession")}
        "category":
            return {"title": TranslationServer.translate("Category", "validator_entity_title_category"),
                "ref": TranslationServer.translate("this category", "validator_entity_ref_category"),
                "source": TranslationServer.translate("category", "validator_entity_source_category")}
        "group":
            return {"title": TranslationServer.translate("Goods group", "validator_entity_title_group"),
                "ref": TranslationServer.translate("this goods group", "validator_entity_ref_group"),
                "source": TranslationServer.translate("goods group", "validator_entity_source_group")}
        "recipe":
            return {"title": TranslationServer.translate("Recipe", "validator_entity_title_recipe"),
                "ref": TranslationServer.translate("this recipe", "validator_entity_ref_recipe"),
                "source": TranslationServer.translate("recipe", "validator_entity_source_recipe")}
        "road":
            return {"title": TranslationServer.translate("Road level", "validator_entity_title_road"),
                "ref": TranslationServer.translate("this road level", "validator_entity_ref_road"),
                "source": TranslationServer.translate("road level", "validator_entity_source_road")}
        "terrain":
            return {"title": TranslationServer.translate("Terrain", "validator_entity_title_terrain"),
                "ref": TranslationServer.translate("this terrain", "validator_entity_ref_terrain"),
                "source": TranslationServer.translate("terrain", "validator_entity_source_terrain")}
        "cover":
            return {"title": TranslationServer.translate("Terrain cover", "validator_entity_title_cover"),
                "ref": TranslationServer.translate("this terrain cover", "validator_entity_ref_cover"),
                "source": TranslationServer.translate("terrain cover", "validator_entity_source_cover")}
        "era":
            return {"title": TranslationServer.translate("Era", "validator_entity_title_era"),
                "ref": TranslationServer.translate("this era", "validator_entity_ref_era"),
                "source": TranslationServer.translate("era", "validator_entity_source_era")}
        "quality_level":
            return {"title": TranslationServer.translate("Quality level", "validator_entity_title_quality_level"),
                "ref": TranslationServer.translate("this quality level", "validator_entity_ref_quality_level"),
                "source": TranslationServer.translate("quality level", "validator_entity_source_quality_level")}
        "consumption_rule":
            return {"title": TranslationServer.translate("Consumption rule", "validator_entity_title_consumption_rule"),
                "ref": TranslationServer.translate("this consumption rule", "validator_entity_ref_consumption_rule"),
                "source": TranslationServer.translate("consumption rule", "validator_entity_source_consumption_rule")}
        _:
            # Спецдействие замыкает список: неизвестный вид подставляет
            # fallback выше, сюда попасть можно только с опечаткой в коде.
            return {"title": TranslationServer.translate("Special action", "validator_entity_title_special_action"),
                "ref": TranslationServer.translate("this special action", "validator_entity_ref_special_action"),
                "source": TranslationServer.translate("special action", "validator_entity_source_special_action")}


# Заголовок группы проверки для окна проблем. Порядок блоков задаёт
# CHECK_ORDER, а не этот список.
#
# Как и подписи сущностей, заголовки перечислены литералами прямо в вызовах
# translate() — иначе сборщик каталога их не увидит (см. entity_forms).
static func check_title(kind: String) -> String:
    match kind:
        "id_charset":
            return TranslationServer.translate("Disallowed characters in an identifier")
        "id_lookalike":
            return TranslationServer.translate("Identifier is indistinguishable from another by eye")
        "produced_in":
            return TranslationServer.translate("Recipe is produced in a nonexistent building")
        "result":
            return TranslationServer.translate("Recipe yields a nonexistent resource")
        "improved_by":
            return TranslationServer.translate("Resource is improved by a nonexistent improvement")
        "unlock_improvement":
            return TranslationServer.translate("Product is unlocked by a nonexistent improvement")
        "unlock_tech":
            return TranslationServer.translate("Reference to a nonexistent technology")
        "profession":
            return TranslationServer.translate("Reference to a nonexistent profession")
        "category":
            return TranslationServer.translate("Reference to a nonexistent category")
        "product_source":
            return TranslationServer.translate("Product has no source (neither the map nor a recipe produces it)")
        "group_member":
            return TranslationServer.translate("Nonexistent product in a goods group")
        "resource_group":
            return TranslationServer.translate("Recipe references a nonexistent goods group")
        "resource":
            return TranslationServer.translate("Recipe references a nonexistent resource")
        "consumption_resource":
            return TranslationServer.translate("Consumption rule references a nonexistent product")
        "consumption_group":
            return TranslationServer.translate("Consumption rule references a nonexistent goods group")
        "prerequisite":
            return TranslationServer.translate("Technology requires a nonexistent technology")
        "road_level":
            return TranslationServer.translate("Road level: wrong or duplicate number")
        "road_max_speed":
            return TranslationServer.translate("Road max speed must be greater than zero")
        "road_work_cost":
            return TranslationServer.translate("Road work cost cannot be negative")
        _:
            # Неизвестный вид проверки: показываем машинное имя — по нему видно,
            # чего не хватает в CHECK_ORDER, и оно переживает любой язык.
            return kind

# Индекс происхождения сущностей текущего прогона: "коллекция:id" → файл+строка.
# Заполняется в validate(), читается в _add(). Пустой, если данные пришли
# откуда-то без индекса (синтетические данные в тесте) — тогда проблема
# просто не получает строки с файлом, а не падает.
var _sources: Dictionary = {}

# Вид сущности-владельца → верхнеуровневая коллекция в data/*.json, в которой
# она объявлена. Нужна, чтобы найти её файл: ключ индекса происхождения
# собирается как "<коллекция>:<id>".
#
# Владелец «product» — это ресурс, а он лежит в общей коллекции "resources"
# (сырьё и продукты в одном списке, тип различает поле "type"). Поэтому
# SOURCE_COLLECTIONS отличается от ENTITIES: там "product" — это СУЩНОСТЬ
# (объект, на который ссылаются), здесь — вид ВЛАДЕЛЬЦА (объект, который
# ссылается).
const SOURCE_COLLECTIONS := {
    "recipe": "crafts",
    "building": "buildings",
    "improvement": "improvements",
    "technology": "technologies",
    "product": "resources",
    "group": "product_groups",
    "road": "roads",
    # Правило потребления не объявляет себя полем "id" (см. data_loader
    # _remember_consumption_sources), поэтому идентификатором записи в индексе
    # происхождения служит её "resource".
    "consumption_rule": "consumption",
    # Виды, нужные только проверкам идентификаторов: они объявляются в
    # своих коллекциях, но ни одна другая проверка на них не ссылается.
    "terrain": "terrains",
    "cover": "covers",
    "era": "eras",
    "quality_level": "quality_levels",
    "special_action": "special_actions",
}

# Порядок вывода блоков проблем в окне.
const CHECK_ORDER := [
    "id_charset",
    "id_lookalike",
    "produced_in",
    "result",
    "product_source",
    "improved_by",
    "unlock_improvement",
    "unlock_tech",
    "profession",
    "category",
    "group_member",
    "resource_group",
    "resource",
    "consumption_resource",
    "consumption_group",
    "prerequisite",
    "road_level",
    "road_max_speed",
    "road_work_cost",
]


# Главная точка входа. gd — любой объект с полями GameData
# (автозагрузка GameData или отдельный экземпляр в тесте).
# Возвращает массив записей проблем (см. шапку файла), пустой — если всё чисто.
func validate(gd: Object) -> Array:
    var problems: Array = []
    # Индекс происхождения сущностей (файл + строка объявления) нужен всем
    # проверкам сразу, а протягивать его через каждую функцию значило бы
    # добавить лишний параметр в десяток сигнатур. Поэтому он живёт на
    # экземпляре и заполняется один раз на прогон.
    _sources = _source_index(gd)

    var buildings := _index_by_id(gd.buildings)
    var technologies := _index_by_id(gd.technologies)
    var categories := _index_by_id(gd.categories)
    # Эти три в GameData уже словари id -> данные (data_loader.gd).
    var improvements: Dictionary = gd.improvements
    var professions: Dictionary = gd.professions
    var products: Dictionary = gd.products
    var raw_resources: Dictionary = gd.raw_resources
    var product_groups: Dictionary = gd.product_groups
    var group_names: Dictionary = gd.product_group_names
    # Сырьё и продукты в одном пространстве для ссылок на ресурсы:
    # рецепт вправе требовать и «clay» (сырьё), и «flour» (продукт).
    var all_resources: Dictionary = {}
    all_resources.merge(raw_resources)
    all_resources.merge(products)

    _validate_identifiers(gd, problems)
    _validate_crafts(gd.crafts, buildings, technologies, all_resources, product_groups, problems)
    _validate_buildings(gd.buildings, technologies, professions, problems)
    _validate_improvements(improvements, technologies, professions, problems)
    _validate_resources(products, raw_resources, categories, technologies, improvements, problems)
    _validate_product_sources(products, _produced_ids(gd, all_resources), problems)
    _validate_product_groups(product_groups, group_names, products, problems)
    _validate_consumption(gd.consumption_rules, products, product_groups, professions, problems)
    _validate_technologies(technologies, problems)
    _validate_roads(gd.roads, technologies, problems)

    _sort_problems(problems)
    return problems


# --- ИДЕНТИФИКАТОРЫ: АЛФАВИТ И ОМОГЛИФЫ ----------------------------------
#
# Проверяются ТОЛЬКО объявления (поле "id"), не ссылки на них. Это не
# упрощение, а следствие устройства остальных проверок: если ссылка
# содержит тот же не-ASCII символ, что и объявление, — проблему найдёт эта
# проверка; если указывает на латинский идентификатор — её найдёт любая из
# проверок битых ссылок. Отдельный проход по ссылкам не нашёл бы ни одного
# нового случая.
func _validate_identifiers(gd: Object, problems: Array) -> void:
    # Все объявленные идентификаторы: id → сведения об объявлении.
    # Заполняется одним проходом по коллекциям, потому что омоглифы ищутся
    # ПО ВСЕМ объявлениям сразу: «сarmine» сам по себе — опечатка в одной
    # строке, а рядом с уже существующим «carmine» — ещё и мёртвый дубль.
    var declared := {}

    for entry in IDENT_COLLECTIONS:
        var field := str(entry["field"])
        var kind := str(entry["kind"])
        var collection = gd.get(field)

        if collection is Dictionary:
            for key in collection:
                var entity = collection[key]
                # Ключ словаря — тот же id, что и в поле "id". Берём id из
                # данных, но если поле потерялось — ключ всё равно известен.
                var id := _as_id(entity.get("id", "")) if entity is Dictionary else ""
                if id.is_empty():
                    id = str(key)
                _collect_identifier(declared, problems, field, kind, id,
                        entity if entity is Dictionary else {})
            # Уровни качества лежат не в словаре, а в массиве ВНУТРИ него
            # (data/qualities.json → "quality_levels": [...]) — проход по
            # полям GameData такой вложенный список не увидит.
            _collect_quality_levels(declared, problems, collection)
        elif collection is Array:
            for entity in collection:
                if not (entity is Dictionary):
                    continue
                _collect_identifier(declared, problems, field, kind,
                        _as_id(entity.get("id", "")), entity)

    _check_lookalikes(declared, problems)


func _collect_quality_levels(declared: Dictionary, problems: Array,
        collection: Dictionary) -> void:
    var levels = collection.get(QUALITY_LEVELS_FIELD, null)
    if not (levels is Array):
        return
    for level in levels:
        if not (level is Dictionary):
            continue
        _collect_identifier(declared, problems, QUALITY_LEVELS_FIELD,
                "quality_level", _as_id(level.get("id", "")), level)


# Запоминает объявление и проверяет его алфавит.
func _collect_identifier(declared: Dictionary, problems: Array, collection: String,
        kind: String, id: String, entity: Dictionary) -> void:
    if id.is_empty():
        return
    declared[id] = {"collection": collection, "kind": kind, "entity": entity}
    _check_ident_charset(problems, id, kind, entity)


# Позиции символов вне разрешённого алфавита:
# [{ "pos": int, "char": String, "code": int, "block": String, "lookalike": String }, …]
#
# block — ИСХОДНОЕ имя блока (английский msgid), а не готовая подпись:
# переводом оно станет только при сборке текста (build_text), иначе смена
# языка не пересобрала бы уже собранное сообщение.
func _bad_ident_chars(id: String) -> Array:
    var bad: Array = []
    var index := 0
    for ch in id:
        if not IDENT_CHARS.contains(ch) and not IDENT_UPPER.contains(ch):
            bad.append({
                "pos": index,
                "char": ch,
                "code": ch.unicode_at(0),
                "block": _ident_block_name(ch.unicode_at(0)),
                "lookalike": str(IDENT_LOOKALIKES.get(ch, "")),
            })
        index += 1
    return bad


# Ключ блока Unicode, в который попал символ. Пустая строка — блок не
# перечислен: подписывать наугад нечестнее, чем не подписать вовсе.
func _ident_block_name(code: int) -> String:
    for block in IDENT_BLOCKS:
        if code >= int(block["from"]) and code <= int(block["to"]):
            return str(block["key"])
    return ""


# Название блока для сообщения: символу с кодом U+XXXX полезно сказать, из
# какого он блока — это вторая половина ценности подсказки (первая — сам
# код).
#
# msgid литералами прямо в вызовах — по той же причине, что и в
# entity_forms(): иначе сборщик каталога этих трёх слов не увидит.
static func _block_label(key: String) -> String:
    match key:
        "cyrillic":
            return TranslationServer.translate("Cyrillic")
        "greek":
            return TranslationServer.translate("Greek")
        "fullwidth_latin":
            return TranslationServer.translate("Fullwidth Latin")
        _:
            return ""


# Одна проблема на идентификатор со ВСЕМИ плохими символами сразу: в «cоal»
# их два, а чинить нужно одну строку — две строки в окне про одну и ту же
# правку только раздражают. Список плохих символов уходит в структуру
# проблемы ("bad_chars"), текст собирает build_text.
func _check_ident_charset(problems: Array, id: String, kind: String,
        entity: Dictionary) -> void:
    var bad := _bad_ident_chars(id)
    if bad.is_empty():
        return

    _push(problems, "id_charset", kind, id, kind,
            _entity_name(entity, id), id, "id", {"bad_chars": bad})


# Два идентификатора, различающиеся только похожими символами («carmine» и
# «сarmine»), — для движка это ДВА разных ресурса. Ссылка на латинский
# «carmine» проходит любую проверку битых ссылок, потому что он существует,
# а кириллический лежит мёртвым грузом. Настоящие проверки ссылок такой
# случай пропускают целиком — поэтому он ловится здесь.
func _check_lookalikes(declared: Dictionary, problems: Array) -> void:
    # Нормализованный id → ВСЕ объявления, дающие такую форму.
    var groups := {}
    for id in declared:
        var key := _ascii_fold(id)
        if not groups.has(key):
            groups[key] = []
        (groups[key] as Array).append(id)

    for key in groups:
        var members: Array = groups[key]
        if members.size() < 2:
            # Одиночка. Если это кириллица, её поймал id_charset: сравнивать
            # не с чем.
            continue
        # В группе из двух и больше участников латинское написание есть
        # обязательно: два РАЗНЫХ чисто латинских id нормализоваться в одну
        # строку не могут (для латиницы fold — тождественное отображение).
        # Значит, все «лишние» — те, где fold что-то заменил.
        var latin := ""
        for id in members:
            if _ascii_fold(id) == id:
                latin = id
                break

        # Сообщаем по одной проблеме на группу: несколько участников —
        # это одна и та же опечатка, и перечислять её дважды незачем.
        for id in members:
            if id == latin:
                continue
            var info: Dictionary = declared[id]
            var latin_info: Dictionary = declared[latin]

            # Владелец проблемы — испорченное объявление (его и надо удалить),
            # поэтому в source_id оно, а не латинное написание. Тексты
            # собирает build_text по этой структуре.
            _push(problems, "id_lookalike", str(latin_info["kind"]), latin,
                    str(info["kind"]), _entity_name(info["entity"], id), id, "id",
                    {"latin": latin})


# Приводит символы, неотличимые от латинских, к латинскому виду. Служит
# ТОЛЬКО для сравнения id между собой, никогда — для правки данных.
func _ascii_fold(id: String) -> String:
    var result := ""
    for ch in id:
        result += str(IDENT_LOOKALIKES.get(ch, ch))
    return result
#
# Проверяются ссылка на технологию (общая с остальными сущностями) и сами
# числа уровня. Числа проверяем потому, что они бьют по геймплею молча:
# max_speed = 0 даст участок, который не везёт ничего, и это видно только в
# игре; work_cost с дробью округлится вверх и «съест» копейку без причины.
func _validate_roads(roads, technologies: Dictionary, problems: Array) -> void:
    if not (roads is Array):
        return
    var seen_levels := {}
    for road in roads:
        if not (road is Dictionary):
            continue
        var road_id := str(road.get("id", ""))
        var rname := _entity_name(road, road_id)

        _check_tech_ref(road.get("unlock_tech", null), technologies, problems,
                "road", rname, road_id, "unlock_tech")

        var level := int(road.get("level", 0))
        if level <= 0:
            _add(problems, "road_level", "road", road_id,
                    "road", rname, road_id, "level")
        elif seen_levels.has(level):
            _add(problems, "road_level", "road", road_id,
                    "road", rname, road_id, "level")
        else:
            seen_levels[level] = true

        if int(road.get("max_speed", 0)) <= 0:
            _add(problems, "road_max_speed", "road", road_id,
                    "road", rname, road_id, "max_speed")
        if int(road.get("work_cost", 0)) < 0:
            _add(problems, "road_work_cost", "road", road_id,
                    "road", rname, road_id, "work_cost")


# --- РЕЦЕПТЫ ---------------------------------------------------------------
# produced_in, result / display_result, ресурсы (в т.ч. @-группы), unlock_tech.
func _validate_crafts(crafts, buildings: Dictionary, technologies: Dictionary,
        all_resources: Dictionary, product_groups: Dictionary, problems: Array) -> void:
    for craft in crafts:
        if not (craft is Dictionary):
            continue
        var craft_id := str(craft.get("id", ""))
        var craft_name := _entity_name(craft, craft_id)

        # produced_in → здание. "*" — служебный маркер «в любом здании».
        for building_id in _as_string_list(craft.get("produced_in", [])):
            if building_id == ANY_BUILDING_MARKER:
                continue
            if not buildings.has(building_id):
                _add(problems, "produced_in", "building", building_id,
                        "recipe", craft_name, craft_id, "produced_in")

        # result (и его отображаемый вариант) → ресурс.
        for field in ["result", "display_result"]:
            for product_id in _as_dict(craft.get(field, {})).keys():
                if not all_resources.has(str(product_id)):
                    _add(problems, "result", "product", str(product_id),
                            "recipe", craft_name, craft_id, field)

        # resources → ресурс или @-группа продуктов.
        for key in _as_dict(craft.get("resources", {})).keys():
            var res_key := str(key)
            if res_key.begins_with("@"):
                if not product_groups.has(res_key.substr(1)):
                    _add(problems, "resource_group", "group", res_key,
                            "recipe", craft_name, craft_id, "resources")
            elif not all_resources.has(res_key):
                _add(problems, "resource", "product", res_key,
                        "recipe", craft_name, craft_id, "resources")

        # unlock_tech → технология.
        _check_tech_ref(craft.get("unlock_tech", ""), technologies, problems,
                "recipe", craft_name, craft_id, "unlock_tech")


# --- ЗДАНИЯ ---------------------------------------------------------------
# unlock_tech, profession.
func _validate_buildings(buildings, technologies: Dictionary, professions: Dictionary,
        problems: Array) -> void:
    for building in buildings:
        if not (building is Dictionary):
            continue
        var building_id := str(building.get("id", ""))
        var building_name := _entity_name(building, building_id)

        _check_tech_ref(building.get("unlock_tech", ""), technologies, problems,
                "building", building_name, building_id, "unlock_tech")
        _check_profession_ref(building.get("profession", ""), professions, problems,
                "building", building_name, building_id, "profession")


# --- УЛУЧШЕНИЯ ------------------------------------------------------------
# unlock_tech, profession.
func _validate_improvements(improvements: Dictionary, technologies: Dictionary,
        professions: Dictionary, problems: Array) -> void:
    for improvement_id in improvements:
        var improvement = improvements[improvement_id]
        if not (improvement is Dictionary):
            continue
        var imp_id := str(improvement_id)
        var imp_name := _entity_name(improvement, imp_id)

        _check_tech_ref(improvement.get("unlock_tech", ""), technologies, problems,
                "improvement", imp_name, imp_id, "unlock_tech")
        _check_profession_ref(improvement.get("profession", ""), professions, problems,
                "improvement", imp_name, imp_id, "profession")


# --- РЕСУРСЫ (сырьё + продукты) -------------------------------------------
# improved_by, unlock_improvement, unlock_tech, category.
func _validate_resources(products: Dictionary, raw_resources: Dictionary,
        categories: Dictionary, technologies: Dictionary, improvements: Dictionary,
        problems: Array) -> void:
    for res_id in products:
        _validate_resource(res_id, products[res_id], categories, technologies,
                improvements, problems, true)
    for res_id in raw_resources:
        _validate_resource(res_id, raw_resources[res_id], categories, technologies,
                improvements, problems, false)


func _validate_resource(res_id, resource, categories: Dictionary, technologies: Dictionary,
        improvements: Dictionary, problems: Array, is_product: bool) -> void:
    if not (resource is Dictionary):
        return
    var rid := str(res_id)
    var rname := _entity_name(resource, rid)

    # improved_by → улучшение (поле сырья: «каким улучшением выращивается»).
    var improved_by := _as_id(resource.get("improved_by", ""))
    if not improved_by.is_empty() and not improvements.has(improved_by):
        _add(problems, "improved_by", "improvement", improved_by,
                "product", rname, rid, "improved_by")

    # unlock_improvement → улучшение (обратная связь у продукта).
    var unlock_improvement := _as_id(resource.get("unlock_improvement", ""))
    if not unlock_improvement.is_empty() and not improvements.has(unlock_improvement):
        _add(problems, "unlock_improvement", "improvement", unlock_improvement,
                "product", rname, rid, "unlock_improvement")

    _check_tech_ref(resource.get("unlock_tech", ""), technologies, problems,
            "product", rname, rid, "unlock_tech")

    # category проверяется ТОЛЬКО у продуктов. У сырья поле category занято
    # другим делом: это фильтр генерации карты со своим набором значений
    # ("animals", "plants", "metals", "minerals" — см. MapHelpers
    # .ensure_minimum_resource и комментарии в data/resources/animals.json).
    # Сверять его с data/categories.json нельзя — там такого набора нет,
    # и валидатор сыпал бы ложными срабатываниями на каждом животном.
    var category := _as_id(resource.get("category", ""))
    if is_product and not category.is_empty() and not categories.has(category):
        _add(problems, "category", "category", category,
                "product", rname, rid, "category")


# --- ПРОДУКТЫ БЕЗ ИСТОЧНИКА ----------------------------------------------
#
# Каждый продукт обязан откуда-то появляться: его либо производит улучшение
# на карте, либо он выходит из рецепта. Продукт без источника недостижим:
# он не появится на складе ниоткуда, а рецепты, которые его требуют, будут
# вечно вставать «нет сырья» — и в игре это видно только как пустой склад,
# без единого слова «почему».
#
# Проверяются ТОЛЬКО продукты. Сырьё (gd.raw_resources) по определению
# берётся с карты генерацией, поэтому у него источник всегда есть; проверка
# сырья дала бы ложные срабатывания на каждом из 112 ресурсов.
func _validate_product_sources(products: Dictionary, produced_ids: Dictionary,
        problems: Array) -> void:
    for product_id in products:
        var pid := str(product_id)
        if produced_ids.has(pid):
            continue
        var product = products[product_id]
        if not (product is Dictionary):
            continue
        _add_missing_source(problems, _entity_name(product, pid), pid)


# Множество id, которые хоть где-то выпускаются.
#
# Четыре пути появления товара — все четыре нужны, иначе проверка шумит:
#   result рецепта        — обычный выход крафта;
#   display_result        — псевдо-выход: реального товара не создаёт, но
#                          рисуется как результат («Наука», science);
#   produces у ресурса    — производство улучшением на карте. Ресурс любой
#                          (сырьё или продукт): механизм один;
#   additional_yield      — фиксированный выход здания в секунду (наука у
#                          библиотеки и скриптория), т.е. такой же источник.
#
# Пятый путь — лесная делянка — из produces не виден вовсе и добавляется
# отдельно (см. константы LUMBERJACK_* в шапке файла).
func _produced_ids(gd: Object, all_resources: Dictionary) -> Dictionary:
    var produced := {}

    for craft in gd.crafts:
        if not (craft is Dictionary):
            continue
        for field in ["result", "display_result"]:
            for produced_id in _as_dict(craft.get(field, {})).keys():
                produced[str(produced_id)] = true

    for res_id in all_resources:
        var resource = all_resources[res_id]
        if not (resource is Dictionary):
            continue
        for produced_id in _as_dict(resource.get("produces", {})).keys():
            produced[str(produced_id)] = true

    for building in gd.buildings:
        if not (building is Dictionary):
            continue
        for produced_id in _as_dict(building.get("additional_yield", {})).keys():
            produced[str(produced_id)] = true

    if _lumberjack_produces(gd.improvements, gd.covers):
        produced[LUMBERJACK_PRODUCT] = true

    return produced


# Лесная делянка даёт древесину, только если ОБА условия из кода выполнены:
# улучшение объявлено И у покрова гекса есть выход. Условие не «декларация о
# намерении», а реальная достижимость: снесённая делянка или обнулённый
# wood_yield делают древесину недостижимой, и валидатор должен об этом сказать.
func _lumberjack_produces(improvements: Dictionary, covers: Dictionary) -> bool:
    if not improvements.has(LUMBERJACK_IMPROVEMENT):
        return false
    for cover_id in covers:
        var cover = covers[cover_id]
        if not (cover is Dictionary):
            continue
        if float(cover.get(COVER_YIELD_FIELD, 0.0)) > 0.0:
            return true
    return false


# --- ГРУППЫ ПРОДУКТОВ -----------------------------------------------------
# Члены @-группы → продукт. Именно эта проверка ловит «@oil_crops» с
# несуществующими sunflower / rapeseed / peanut.
func _validate_product_groups(product_groups: Dictionary, group_names: Dictionary,
        products: Dictionary, problems: Array) -> void:
    for group_id in product_groups:
        var members = product_groups[group_id]
        if not (members is Array):
            continue
        var gid := str(group_id)
        var gname := str(group_names.get(gid, gid))
        for member in members:
            var product_id := str(member)
            if not products.has(product_id):
                _add(problems, "group_member", "product", product_id,
                        "group", gname, gid, "products")


# --- ПРАВИЛА ПОТРЕБЛЕНИЯ (data/consumption.json) ---------------------------
#
# resource → продукт ИЛИ @-группа продуктов; profession → профессия.
#
# Проверка зеркалит РЕЗОЛВЕР GameData._build_consumption_entry, а не общие
# ссылки рецептов: ключ без "@" ищется именно в GameData.products. Потребление
# берёт товары со склада, а не сырьё с гекса, поэтому «сырьё» здесь не подходит.
#
# Самая частая поломка здесь — забытый "@": автор пишет id группы там, где нужен
# ресурс. До проверки такая запись не роняла ничего: резолвер подставлял
# products.get(id, {}) и подпись-идентификатор, а списать было нечего, поэтому
# строка потребления молча висела в интерфейсе и никогда не списывалась.
func _validate_consumption(rules, products: Dictionary, product_groups: Dictionary,
        professions: Dictionary, problems: Array) -> void:
    if not (rules is Array):
        return
    for rule in rules:
        if not (rule is Dictionary):
            continue
        var res_key := _as_id(rule.get("resource", ""))
        if res_key.is_empty():
            continue
        # Идентификатором правила служит его "resource" — им же помечена
        # строка объявления (см. SOURCE_COLLECTIONS и data_loader).
        if res_key.begins_with("@"):
            if not product_groups.has(res_key.substr(1)):
                _add(problems, "consumption_group", "group", res_key,
                        "consumption_rule", res_key, res_key, "resource")
        elif not products.has(res_key):
            _add(problems, "consumption_resource", "product", res_key,
                    "consumption_rule", res_key, res_key, "resource")

        # profession → профессия. Вид проверки общий с зданиями и улучшениями:
        # сообщение «ссылка на несуществующую профессию» одинаково верно здесь.
        _check_profession_ref(rule.get("profession", []), professions, problems,
                "consumption_rule", res_key, res_key, "profession")


# --- ТЕХНОЛОГИИ -----------------------------------------------------------
# prerequisites → технология. Формат допускает и плоский список, и список
# ИЛИ-групп: [[ "a", "b" ], [ "c" ]] — нужно исследовать любую из групп.
func _validate_technologies(technologies: Dictionary, problems: Array) -> void:
    for tech_id in technologies:
        var tech = technologies[tech_id]
        if not (tech is Dictionary):
            continue
        var tid := str(tech_id)
        var tname := _entity_name(tech, tid)
        for required in _flatten_prerequisites(tech.get("prerequisites", null)):
            if not technologies.has(required):
                _add(problems, "prerequisite", "technology", required,
                        "technology", tname, tid, "prerequisites")


# --- ПРОВЕРКИ ОДНОГО ЗНАЧЕНИЯ --------------------------------------------

func _check_tech_ref(value, technologies: Dictionary, problems: Array,
        source_kind: String, source_name: String, source_id: String, field: String) -> void:
    var tech_id := _as_id(value)
    if tech_id.is_empty() or technologies.has(tech_id):
        return
    _add(problems, "unlock_tech", "technology", tech_id,
            source_kind, source_name, source_id, field)


# profession бывает строкой («farmer») и, в некоторых данных, списком —
# принимаем оба формата.
func _check_profession_ref(value, professions: Dictionary, problems: Array,
        source_kind: String, source_name: String, source_id: String, field: String) -> void:
    for prof_id in _as_string_list(value):
        if professions.has(prof_id):
            continue
        _add(problems, "profession", "profession", prof_id,
                source_kind, source_name, source_id, field)


# --- СБОРКА ЗАПИСИ ПРОБЛЕМЫ ----------------------------------------------
#
# Здесь и дальше запись делится надвое:
#   * _add / _add_missing_source / _push — СТРУКТУРА (что, где, в каком поле);
#   * build_text — ТЕКСТ под текущий язык.
#
# Раньше формулировки жили в _add, и это было связано: смени язык — уже
# собранные сообщения остались на старом. Теперь текст собирается отдельно и
# пересобирается функцией localize_problems() (окно вызывает её по сигналу
# LocalizationManager.locale_changed), а проверка при этом НЕ перезапускается.

func _add(problems: Array, kind: String, target: String, ref_id: String,
        source_kind: String, source_name: String, source_id: String, field: String) -> void:
    _push(problems, kind, target, ref_id,
            source_kind, source_name, source_id, field)


# Проблема «продукт есть, а взять его неоткуда».
#
# Владелец проблемы — сам продукт, поэтому его id попадает и в ref_id (чтобы
# окно подсветило его, как и остальные идентификаторы), и в source_id (чтобы
# нашлась строка объявления в файле). Поле field пустое: указать нечего — нет
# поля, в котором стоило бы дописать источник.
func _add_missing_source(problems: Array, product_name: String, product_id: String) -> void:
    _push(problems, "product_source", "product", product_id,
            "product", product_name, product_id, "")


# Общая часть записи проблемы: словарь полей (см. шапку файла), поиск файла и
# строки объявления владельца. Вынесена отдельно от _add(), потому что
# формулировки проблем у разных проверок разные, а формат записи, наоборот,
# один: от него зависят и data_problems_window.gd, и тест.
#
# extra — данные, нужные только тексту конкретной проверки ("bad_chars" у
# id_charset, "latin" у id_lookalike). Это строительный материал для
# build_text, а не часть структуры проблемы.
func _push(problems: Array, kind: String, target: String, ref_id: String,
        source_kind: String, source_name: String, source_id: String, field: String,
        extra: Dictionary = {}) -> void:
    # Пустая строка, если происхождение неизвестно (данные без индекса) —
    # тогда строка с файлом просто ничего не добавляет.
    var file_path := ""
    var line := 0
    var source_key := "%s:%s" % [str(SOURCE_COLLECTIONS.get(source_kind, "")), source_id]
    var origin = _sources.get(source_key, null)
    if origin is Dictionary:
        file_path = str(origin.get("file", ""))
        line = int(origin.get("line", 0))

    var problem := {
        "kind": kind,
        "target": target,
        "ref_id": ref_id,
        "source_kind": source_kind,
        "source_name": source_name,
        "source_id": source_id,
        "field": field,
        "file": file_path,
        "line": line,
    }
    for key in extra:
        problem[key] = extra[key]

    build_text(problem)
    problems.append(problem)


# Пересобирает текстовые поля problems на ТЕКУЩЕМ языке.
#
# Проверка не перезапускается: структура проблемы от языка не зависит, текст
# выводится из неё. Нужна окну проблем — смена языка в настройках идёт, когда
# окно уже на экране, и без этого пересборки заголовки и описания остались бы
# на старом языке.
static func localize_problems(problems: Array) -> void:
    for problem in problems:
        if problem is Dictionary:
            build_text(problem)


# Текст проблемы под текущий язык. Пишет прямо в переданный словарь.
#
# Единая точка, где живут ВСЕ пользовательские формулировки валидатора: их
# видно списком, и переводчик находит их в каталоге как обычные сообщения.
# Сами проверки (выше по файлу) не содержат ни одного пользовательского
# текста — только структуру.
#
# Каждый вызов translate() занимает ОДНУ строку и содержит РОВНО один
# строковый литерал. Это не вкусовое требование, а требование сборщика
# каталога: tools/i18n_build_po.py разбирает код построчно, и многострочный
# вызов он не увидит. Второй литерал он принял бы за msgctxt, поэтому
# склеивать строки внутри вызова тоже нельзя — отсюда длинные строки.
static func build_text(problem: Dictionary) -> void:
    var kind := str(problem.get("kind", ""))
    var headline := ""
    var where := ""

    match kind:
        "id_charset":
            headline = TranslationServer.translate("Identifier \"%s\" contains disallowed characters.") % str(problem.get("ref_id", ""))
            where = TranslationServer.translate("Only Latin letters a-z, digits and \"_\" are allowed. Disallowed: %s Such characters are indistinguishable from Latin ones by eye — fix this identifier and ALL references to it at once.") % _bad_chars_text(problem.get("bad_chars", []))
        "id_lookalike":
            var latin := str(problem.get("latin", ""))
            headline = TranslationServer.translate("Identifier \"%s\" is indistinguishable from \"%s\" by eye.") % [str(problem.get("source_id", "")), latin]
            where = TranslationServer.translate("There is no difference in spelling, but for the game these are DIFFERENT identifiers: everything that references \"%s\" will not reach \"%s\" and vice versa. Note that a reference to \"%s\" does NOT break anything — it is declared and looks correct, so the regular broken-reference checks did not see this typo either. Keep one identifier and rename the other in all files.") % [latin, str(problem.get("source_id", "")), latin]
        "product_source":
            headline = TranslationServer.translate("Product \"%s\" is not produced anywhere.") % str(problem.get("ref_id", ""))
            where = TranslationServer.translate("Source not found: product \"%s\" (%s) appears neither in produces of any map resource, nor in result/display_result of any recipe, nor in additional_yield of any building. Add a data source or remove the product from the file.") % [str(problem.get("source_name", "")), str(problem.get("source_id", ""))]
        _:
            # Остальные проверки — битая ССЫЛКА: «X с идентификатором … не
            # существует» + где именно на неё сослались.
            var target_forms := entity_forms(str(problem.get("target", "")))
            var source_forms := entity_forms(str(problem.get("source_kind", "")), "recipe")
            headline = TranslationServer.translate("%s with the identifier \"%s\" does not exist.") % [str(target_forms["title"]), str(problem.get("ref_id", ""))]
            where = TranslationServer.translate("A reference to %s is present in %s %s, field %s.") % [str(target_forms["ref"]), str(source_forms["source"]), _quote_owner(str(problem.get("source_name", "")), str(problem.get("source_id", ""))), str(problem.get("field", ""))]

    # «File: res://data/crafts/crafts.json, line 7.»
    var location := ""
    var file_path := str(problem.get("file", ""))
    if not file_path.is_empty():
        location = TranslationServer.translate("File: %s") % file_path
        var line := int(problem.get("line", 0))
        if line > 0:
            location += TranslationServer.translate(", line %d") % line
        location += "."

    problem["check_title"] = check_title(kind)
    problem["target_title"] = str(entity_forms(str(problem.get("target", "")))["title"])
    problem["headline"] = headline
    problem["where"] = where
    problem["location"] = location
    problem["message"] = headline + " " + where + (
        " " + location if not location.is_empty() else "")


# Список плохих символов идентификатора одной строкой:
# «position 1: "с" (U+0441, Cyrillic), looks like "c" in Latin;».
#
# Имя блока переводится здесь, а не в _bad_ident_chars: там оно ещё msgid,
# и перевод должен применяться в момент сборки текста.
static func _bad_chars_text(bad) -> String:
    var parts: Array = []
    for item in bad:
        if not (item is Dictionary):
            continue
        var part := TranslationServer.translate("position %d: \"%s\" (U+%04X") % [int(item.get("pos", 0)) + 1, str(item.get("char", "")), int(item.get("code", 0))]
        var block := str(item.get("block", ""))
        if not block.is_empty():
            part += ", %s" % _block_label(block)
        part += ")"
        # На латинском этот символ выглядит так же. Без подсказки автор
        # прочитает «с» как «c» и не поймёт, в чём дело.
        var lookalike := str(item.get("lookalike", ""))
        if not lookalike.is_empty():
            part += TranslationServer.translate(", looks like \"%s\" in Latin") % lookalike
        parts.append(part + ";")
    return " ".join(parts)


# Владелец ссылки в скобках: «Молот зерна» (grind_grain_hand). Если имени
# нет — только идентификатор, чтобы строка не выглядела «в  (), поле …».
static func _quote_owner(source_name: String, source_id: String) -> String:
    if source_name.is_empty() or source_name == source_id:
        return "«%s»" % source_id
    return "«%s» (%s)" % [source_name, source_id]


# --- ВСПОМОГАТЕЛЬНОЕ ------------------------------------------------------

# Индекс происхождения из объекта с данными. Отсутствие поля не ошибка:
# валидатор должен работать и на данных без индекса (синтетические данные
# теста), просто тогда проблемы останутся без указания файла.
func _source_index(gd: Object) -> Dictionary:
    if gd == null:
        return {}
    var sources = gd.get("entity_sources")
    return sources if sources is Dictionary else {}


func _entity_name(data: Dictionary, fallback_id: String) -> String:
    var name := _as_id(data.get("name", ""))
    return name if not name.is_empty() else fallback_id


# Идентификатор из поля данных.
#
# Поле может быть ЯВНО пустым: в data/*.json встречается "improved_by": null —
# это «улучшения нет», а не «ссылка на несуществующее улучшение». Прямой
# str(null) в GDScript даёт строку «<null>», из-за чего валидатор объявлял бы
# битой ссылкой каждое пустое поле и сыпал ложные срабатывания. Поэтому
# null приводится к пустой строке — как и отсутствующее поле.
func _as_id(value) -> String:
    if value == null:
        return ""
    return str(value)


# Массив записей → словарь id -> запись (для проверок «существует ли»).
func _index_by_id(entries) -> Dictionary:
    var index := {}
    if not (entries is Array):
        return index
    for entry in entries:
        if not (entry is Dictionary):
            continue
        var id := str(entry.get("id", ""))
        if not id.is_empty():
            index[id] = entry
    return index


# Приводит поле-ссылку к списку строк: строка → [строка], массив → как есть.
# Пустые значения молча отбрасываются — незаполненное поле не ошибка.
func _as_string_list(value) -> Array:
    var result: Array = []
    if value == null:
        return result
    if value is String:
        var single := str(value)
        if not single.is_empty():
            result.append(single)
        return result
    if value is Array:
        for item in value:
            var item_str := str(item)
            if not item_str.is_empty():
                result.append(item_str)
    return result


func _as_dict(value) -> Dictionary:
    return value if value is Dictionary else {}


# prerequisites допускает [[ "a", "b" ], "c"] и [ "a", "b" ] — в обоих
# случаях нужен плоский список идентификаторов.
func _flatten_prerequisites(value) -> Array:
    var result: Array = []
    if value is String:
        if not str(value).is_empty():
            result.append(str(value))
        return result
    if value is Array:
        for entry in value:
            if entry is Array:
                for nested in entry:
                    result.append(str(nested))
            else:
                result.append(str(entry))
    return result


# Сортировка: сначала порядок блоков CHECK_ORDER, внутри — по владельцу
# ссылки и её id. Без неё список зависел бы от порядка обхода данных.
func _sort_problems(problems: Array) -> void:
    problems.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        var ka := str(a.get("kind", ""))
        var kb := str(b.get("kind", ""))
        var ia := CHECK_ORDER.find(ka)
        var ib := CHECK_ORDER.find(kb)
        if ia != ib:
            return ia < ib
        var sa := "%s|%s" % [str(a.get("source_id", "")), str(a.get("ref_id", ""))]
        var sb := "%s|%s" % [str(b.get("source_id", "")), str(b.get("ref_id", ""))]
        return sa < sb
    )


# Сколько проблем по каждому виду проверки — для заголовка окна и тестов.
func count_by_kind(problems: Array) -> Dictionary:
    var counts := {}
    for problem in problems:
        var kind := str(problem.get("kind", ""))
        counts[kind] = int(counts.get(kind, 0)) + 1
    return counts
