# Тест рантайм-валидатора игровых данных (headless):
#   godot --headless --path . --script res://tests/test_data_validation.gd
#
# Проверяет пять вещей:
#   1) ДЕТЕКТОР (главное). На искусственных данных в каждый вид проверки
#      вносится ровно одна поломка, и тест требует найти каждую — с
#      правильным видом проверки, идентификатором и владельцем ссылки.
#      Данные синтетические намеренно: тест не должен сломаться, когда
#      автор починит настоящие data/*.json.
#   2) ЛОЖНЫЕ СРАБАТЫВАНИЯ. Пять мест, где валидатор обязан промолчать:
#      produced_in == "*" (служебный маркер «в любом здании», см.
#      CityData.can_craft_in), category у СЫРЬЯ (там это фильтр генерации
#      карты со своим набором значений — animals/plants/metals/minerals,
#      а не категории из data/categories.json), «продукт без источника»
#      у товара, который производится display_result'ом, produces'ом
#      ресурса карты либо лесной делянкой, кириллица в полях name/description
#      (в data/*.json они по-русски законно) и подчёркивание с цифрами в id.
#   3) ИСКЛЮЧЕНИЕ ЛЕСНОЙ ДЕЛЯНКИ вычисляется из данных, а не зашито
#      списком: снесли делянку или обнулили wood_yield — древесина
#      теряет источник, и валидатор обязан это заметить.
#   4) Настоящие data/*.json: валидатор не падает, проблемы корректно
#      указывают на продукт-владельца, а не-ASCII в идентификаторах
#      отсутствует (единственное исключение из правила «список проблем на
#      реальных данных не проверяется» — см. комментарий в _test_real_data).
#   5) Указание на файл и строку (см. _check_file_and_line).
#
# Реальные data/*.json прогоняются в конце на инварианты, а не на
# ожидаемый список: их автор починит, и тест упал бы на ровно том, ради
# чего валидатор написан. Их список проблем печатается для справки.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _initialize() выглядит снаружи
# как вечное молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const DataValidator = preload("res://scripts/data_validator.gd")


func _initialize():
    WATCHDOG.arm(self)
    var state = {"failed": false}

    if WATCHDOG.wants_case("detector"):
        _test_detector(state)
    if WATCHDOG.wants_case("no_false_positives_on_synthetic"):
        _test_no_false_positives_on_synthetic(state)
    if WATCHDOG.wants_case("lumberjack_depends_on_data"):
        _test_lumberjack_depends_on_data(state)
    if WATCHDOG.wants_case("real_data"):
        _test_real_data(state)
    if WATCHDOG.wants_case("localization"):
        _test_localization(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("VALIDATION TEST FAILED")
        quit(1)
    else:
        print("VALIDATION TEST OK")
        quit(0)


# --- 1) Каждый вид проверки ловит свою поломку -----------------------------

func _test_detector(state: Dictionary):
    var gd = _make_data()

    # Ожидаемый набор поломок: вид проверки → [идентификатор, владелец].
    # Порядок и количество проверяются точно: лишняя или пропавшая проблема —
    # тоже баг валидатора.
    var expected := {
        "produced_in": [["ghost_mill", "bad_produced_in"]],
        "result": [["ghost_product", "bad_result"]],
        "improved_by": [["ghost_farm", "bad_improved_by"]],
        "unlock_improvement": [["ghost_farm", "bad_unlock_improvement"]],
        "unlock_tech": [
            ["ghost_tech", "bad_building_tech"],
            ["ghost_tech", "bad_improvement_tech"],
            ["ghost_tech", "bad_product_tech"],
            ["ghost_tech", "bad_craft_tech"],
        ],
        "profession": [
            ["ghost_prof", "bad_building_prof"],
            ["ghost_prof", "bad_improvement_prof"],
            ["ghost_prof", "wheat"],
        ],
        "category": [["ghost_category", "bad_category"]],
        "group_member": [["ghost_member", "bad_group"]],
        "resource_group": [["@ghost_group", "bad_group_ref"]],
        "resource": [["ghost_raw", "bad_resource_ref"]],
        # Правила потребления. Владелец ссылки — само правило, а оно
        # идентифицируется значением "resource" (см. data_validator
        # _validate_consumption), поэтому source_id совпадает с ref_id.
        "consumption_resource": [["ghost_product", "ghost_product"]],
        "consumption_group": [["@ghost_group", "@ghost_group"]],
        "prerequisite": [["ghost_tech", "bad_tech_prereq"]],
        # У проблемы «продукт без источника» нет недостающего идентификатора:
        # бит не в ссылке, а в её отсутствии. Поэтому ref_id и source_id —
        # оба id самого продукта-владельца.
        "product_source": [["no_source_product", "no_source_product"]],
        # Проблемы идентификаторов. У проблемы id_charset нет недостающей
        # ссылки (бит сам идентификатор), поэтому ref_id и source_id — оба
        # id испорченного объявления.
        #
        # Кириллический «сarmine» даёт СРАЗУ две проблемы разных видов: он
        # вне алфавита (id_charset) И неотличим от «carmine» (id_lookalike).
        # Это не дубль, а два разных утверждения об одном символе, и оба
        # полезны: первое говорит «замени на латиницу», второе — «у тебя
        # теперь два разных ресурса».
        "id_charset": [["сoal_typo", "сoal_typo"], ["сarmine", "сarmine"]],
        # У id_lookalike ref_id — латинский «двойник» (то, на что автор
        # думает, что ссылается), source_id — испорченное объявление.
        "id_lookalike": [["carmine", "сarmine"]],
    }

    var problems: Array = DataValidator.new().validate(gd)

    for kind in expected:
        for pair in expected[kind]:
            var ref_id: String = str(pair[0])
            var source_id: String = str(pair[1])
            var found := _find(problems, kind, ref_id, source_id)
            check(not found.is_empty(),
                "не найдена проблема: kind=%s, ref=%s, источник=%s" % [kind, ref_id, source_id],
                state)

    # Каждая поломка должна давать ровно одну проблему своего вида, а не
    # «соседнюю» — иначе сообщение указывает не на то поле.
    check(problems.size() == _expected_problem_count(expected),
        "ожидалось %d проблем, получено %d: %s" % [
            _expected_problem_count(expected), problems.size(),
            _str_messages(problems)], state)

    # Сообщение обязано называть и недостающий идентификатор, и владельца
    # ссылки — иначе игрок не поймёт, что чинить.
    var sample := _find(problems, "group_member", "ghost_member", "bad_group")
    check(sample.has("message"), "у проблемы нет поля message", state)
    check(str(sample.get("message", "")).contains("ghost_member"),
        "сообщение не содержит искомый идентификатор: %s" % str(sample.get("message", "")), state)
    check(str(sample.get("message", "")).contains("bad_group"),
        "сообщение не содержит id владельца ссылки: %s" % str(sample.get("message", "")), state)
    check(str(sample.get("where", "")).contains("bad_group"),
        "поле where не содержит id владельца ссылки: %s" % str(sample.get("where", "")), state)

    gd.free()


# --- 2) Два места, где валидатор обязан промолчать ------------------------

func _test_no_false_positives_on_synthetic(state: Dictionary):
    var gd = _make_data()
    var problems: Array = DataValidator.new().validate(gd)

    check(_find(problems, "produced_in", "*", "wildcard_recipe").is_empty(),
        "служебный маркер \"*\" в produced_in не должен считаться поломкой", state)
    check(_find(problems, "category", "animals", "wildcard_raw").is_empty(),
        "category у сырья («animals») не должен сверяться с data/categories.json", state)

    # --- Ложные срабатывания проверки «продукт без источника» ---
    #
    # Наивная версия этой проверки ругалась бы на три обычных способа
    # получить товар, каждый из которых встречается в настоящих data/.
    check(_find(problems, "product_source", "science", "science").is_empty(),
        "продукт только из display_result («Наука») не должен считаться без источника",
        state)
    check(_find(problems, "product_source", "wood", "wood").is_empty(),
        "продукт лесной делянки (wood_yield покрова) не должен считаться без источника",
        state)
    check(_find(problems, "product_source", "wheat", "wheat").is_empty(),
        "продукт из produces ресурса карты не должен считаться без источника", state)
    check(_find(problems, "product_source", "flour", "flour").is_empty(),
        "продукт из result рецепта не должен считаться без источника", state)
    # СЫРЬЁ (produces которого проверяется на наличие значений, а не на
    # «откуда оно») не должно попадать под проверку: оно берётся с карты
    # генерацией, источник у него по определению есть.
    check(_find(problems, "product_source", "wheat_field", "wheat_field").is_empty(),
        "сырьё не должно проверяться на наличие источника", state)

    # --- Ложные срабатывания проверок идентификаторов ---
    #
    # Проверяются ТОЛЬКО поля "id". Название и описание обязаны остаться
    # неприкосновенными: в data/*.json они по-русски, и это законно —
    # перевод накладывается по английскому тексту (data_loader,
    # DISPLAY_FIELDS). Если бы проверка шла по всем строкам записи, она бы
    # забраковала весь проект.
    check(_find(problems, "id_charset", "wildcard_raw", "wildcard_raw").is_empty(),
        "кириллица в name («Корова») не должна считаться ошибкой идентификатора",
        state)
    # Подчёркивание и цифры в id — норма проекта (wheat_field, bad_group_ref),
    # а не ошибка: правило разрешает a-z, 0-9 и «_».
    check(_find(problems, "id_charset", "wheat_field", "wheat_field").is_empty(),
        "подчёркивание в id не должно считаться недопустимым символом", state)
    check(_find(problems, "id_charset", "bad_group_ref", "bad_group_ref").is_empty(),
        "подчёркивание и цифры в id рецепта не должны считаться ошибкой", state)
    # Одиночный id без «кириллического двойника» — не пара, а обычное объявление.
    check(_find(problems, "id_lookalike", "wheat", "wheat").is_empty(),
        "одиночный id без пары-омоглифа не должен давать проблем", state)

    # --- Ложные срабатывания проверок правил потребления ---
    #
    # Правило реестра обязано уметь ссылаться и на одиночный продукт, и на
    # @-группу, и на псевдо-профессию. Здесь в наборе есть продукты, группы
    # и профессии, и все три ссылки верны — шуметь на них нельзя. Без этой
    # проверки наивная реализация искала бы «id» в GameData.professions и
    # ругалась бы на каждое правило сразу.
    check(_find(problems, "consumption_resource", "tools", "tools").is_empty(),
        "правило потребления существующего продукта не должно считаться поломкой",
        state)
    check(_find(problems, "consumption_group", "@jewelry", "@jewelry").is_empty(),
        "правило потребления существующей @-группы не должно считаться поломкой",
        state)

    # Явно пустые поля (null) — не ссылки. Ни одна из этих сущностей не
    # должна попасть в результат ни под каким видом проверки.
    for entity_id in ["null_fields", "null_product", "null_improvement", "null_building"]:
        for problem in problems:
            check(str(problem.get("source_id", "")) != entity_id,
                "явно пустое поле (null) у «%s» принято за битую ссылку: %s" % [
                    entity_id, str(problem.get("message", ""))], state)
            check(str(problem.get("ref_id", "")) != "<null>",
                "идентификатор «<null>» в сообщении — null не переведён в пустую строку", state)

    # Данные БЕЗ индекса происхождения (entity_sources пуст) — проблемы
    # всё равно находятся, просто остаются без указания файла. Отсутствие
    # индекса не должно ронять валидатор: это делает проверку годной для
    # любых данных с теми же полями.
    for problem in problems:
        check(str(problem.get("file", "")).is_empty(),
            "без индекса происхождения файл указываться не должен: %s" % [
                str(problem.get("message", ""))], state)
        check(int(problem.get("line", 0)) == 0,
            "без индекса происхождения строка не должна быть ненулевой", state)
        check(str(problem.get("location", "")).is_empty(),
            "без индекса происхождения location должен быть пустым", state)
        # Строка с файлом — это и есть location, и проверка выше уже
        # потребовала её пустоты. Здесь ловим другое: путь к файлу не должен
        # просочиться в message ни через какой-то другой шаблон. Проверяем
        # по САМОМУ пути, а не по словам «Файл:»/«File:»: слова принадлежат переводу
        # и меняются вместе с языком, а res://data/ — нет.
        check(not str(problem.get("message", "")).contains("res://data/"),
            "в сообщении не должно быть пути к файлу без индекса: %s" % [
                str(problem.get("message", ""))], state)

    gd.free()


# --- 3) Исключение лесной делянки вычисляется из данных -------------------
#
# «Древесина» — единственный продукт, у которого нет источника в produces.
# Связь «покров → делянка → продукт» зашита в коде, и её можно закрыть двояко:
# жёстким списком исключений в валидаторе (тогда о снятой делянке или
# обнулённом wood_yield он молчал бы вечно) или чтением данных. Тест требует
# второго: древесина обязана «терять источник», когда данные перестают её
# производить, — иначе проверка врала бы автору, что всё в порядке.
func _test_lumberjack_depends_on_data(state: Dictionary):
    # Обнулили выход с покрова — делянке нечего производить.
    var gd = _make_data()
    gd.covers["forest"]["wood_yield"] = 0
    var problems: Array = DataValidator.new().validate(gd)
    check(not _find(problems, "product_source", "wood", "wood").is_empty(),
        "после обнуления wood_yield у всех покровов древесина теряет источник, " +
        "и валидатор обязан это заметить", state)
    gd.free()

    # Снесли саму делянку — производства тоже нет.
    var gd2 = _make_data()
    gd2.improvements.erase("lumberjack_hut")
    var problems2: Array = DataValidator.new().validate(gd2)
    check(not _find(problems2, "product_source", "wood", "wood").is_empty(),
        "после удаления лесной делянки древесина теряет источник, " +
        "и валидатор обязан это заметить", state)
    gd2.free()

    # Обратная сторона: целые данные — источник есть, проблемы нет.
    var gd3 = _make_data()
    var problems3: Array = DataValidator.new().validate(gd3)
    check(_find(problems3, "product_source", "wood", "wood").is_empty(),
        "при целых данных (делянка есть, wood_yield > 0) древесина имеет источник", state)
    gd3.free()


# --- 4) Настоящие данные: валидатор не падает -----------------------------

func _test_real_data(state: Dictionary):
    var gd = load("res://scripts/GameData.gd").new()
    gd.load_all_data()

    check(gd.data_loaded, "GameData.load_all_data() не выставил data_loaded", state)

    var problems: Array = DataValidator.new().validate(gd)
    print("Проблем в res://data по проверке ссылок: %d" % problems.size())
    for problem in problems:
        print("  - ", str(problem.get("message", "")))

    # Конкретные id из настоящих данных не проверяем: их автор починит, и
    # тест упадёт на ровно том, ради чего валидатор написан. Проверяем
    # инварианты, которые должны держаться при любом содержимом данных.

    # ИСКЛЮЧЕНИЕ из правила выше: не-ASCII в id — ноль проблем на настоящих
    # данных, и это утверждение проверяется. Здесь оно безопасно, потому что
    # не про чужую поломку, которую надо чинить, а про регрессию самой
    # проверки: опечатка с кириллической «с» неотличима от латинской «c»
    # и не ломает ссылок, поэтому ничем другим не ловится. Если тест молчал
    # бы здесь, одна опечатка с такой «с» могла бы незамеченной уехать в релиз
    # и всплыть через месяц как «ресурс не находится».
    var non_ascii_problems: Array = []
    for problem in problems:
        var kind := str(problem.get("kind", ""))
        if kind == "id_charset" or kind == "id_lookalike":
            non_ascii_problems.append(problem)
    check(non_ascii_problems.is_empty(),
        "в идентификаторах res://data есть недопустимые символы или омоглифы: %s" \
                % _str_messages(non_ascii_problems), state)

    # produced_in == "*" у псевдорецепта "empty" (data/crafts/pseudo.json)
    # — не поломка.
    for problem in problems:
        check(not (problem.get("kind") == "produced_in" and problem.get("ref_id") == "*"),
            "валидатор ругается на \"*\" в produced_in", state)

    # Категория проверяется только у продуктов: у каждой проблемы вида
    # "category" владелец обязан быть продуктом, а не сырьём.
    var products: Dictionary = gd.products
    for problem in problems:
        if problem.get("kind") != "category":
            continue
        var owner_id := str(problem.get("source_id", ""))
        check(products.has(owner_id),
            "проблема category у не-продукта «%s» — сырьё сверяется с чужим набором категорий" % owner_id,
            state)

    # У каждой проблемы заполнены обе строки сообщения.
    for problem in problems:
        var msg := str(problem.get("message", ""))
        check(not msg.is_empty(), "проблема без текста сообщения", state)
        check(not str(problem.get("headline", "")).is_empty(),
            "проблема без headline", state)
        check(not str(problem.get("where", "")).is_empty(),
            "проблема без where", state)

    # Проблема «продукт без источника» указывает на сам продукт — значит, её
    # владелец обязан быть в GameData.products, а не сырьём и не зданием.
    for problem in problems:
        if problem.get("kind") != "product_source":
            continue
        var owner_id := str(problem.get("source_id", ""))
        check(products.has(owner_id),
            "проблема product_source у не-продукта «%s»" % owner_id, state)
        check(problem.get("target") == "product",
            "у product_source неверный target: %s" % str(problem.get("target", "")), state)

    _check_file_and_line(state, problems)

    # count_by_kind обязан согласовываться с самим списком.
    var counts := DataValidator.new().count_by_kind(problems)
    var total := 0
    for kind in counts:
        total += int(counts[kind])
    check(total == problems.size(),
        "count_by_kind разошёлся с числом проблем: %d != %d" % [total, problems.size()], state)

    gd.free()


# --- 5) Указание на файл и строку -----------------------------------------
#
# Проблема обязана называть не только сущность, но и ФАЙЛ, в котором сущность
# объявлена, и строку. Смысл такой строки — «здесь смотри», поэтому проверяется
# не сам номер, а то, что на этой строке действительно лежит объявление
# владельца: иначе номер был бы правдоподобным и неверным, и хуже, чем его
# отсутствие.
func _check_file_and_line(state: Dictionary, problems: Array):
    # Файлы из разных проблем читаем по одному разу.
    var lines_by_file := {}
    for problem in problems:
        var file_path := str(problem.get("file", ""))
        var line := int(problem.get("line", 0))
        var source_id := str(problem.get("source_id", ""))

        check(not file_path.is_empty(),
            "у проблемы %s не указан файл" % str(problem.get("message", "")), state)
        check(line > 0,
            "у проблемы %s не указана строка" % str(problem.get("message", "")), state)

        if file_path.is_empty() or line <= 0:
            continue

        check(file_path.begins_with("res://data/"),
            "файл проблемы вне папки data: %s" % file_path, state)
        var location := str(problem.get("location", ""))
        check(location.contains(file_path),
            "location не содержит путь к файлу: %s" % location, state)
        check(location.contains(str(line)),
            "location не содержит номер строки: %s" % location, state)
        check(str(problem.get("message", "")).contains(file_path),
            "message не содержит путь к файлу — пропадёт в логе", state)

        if not lines_by_file.has(file_path):
            lines_by_file[file_path] = _read_lines(file_path)
        var lines: Array = lines_by_file[file_path]
        check(line <= lines.size(),
            "строка %d за пределами файла %s (%d строк)" % [line, file_path, lines.size()], state)
        if line > lines.size():
            continue
        var decl := str(lines[line - 1])
        check(decl.contains("\"%s\"" % source_id),
            "строка %d файла %s — это не объявление «%s»: %s" % [
                line, file_path, source_id, decl.strip_edges()], state)


# --- 6) Локализация текстов проблем ----------------------------------------
#
# Формулировки проблемы переводятся (data_validator.gd → locale/<код>.po), и
# проверяется ровно то, что ради этого перевода сделано:
#   * на двух языках получаются РАЗНЫЕ тексты, а не английский везде;
#   * английский текст не содержит кириллицы (значит, каталог заполнен);
#   * localize_problems() пересобирает уже собранные тексты при смене языка,
#     НЕ прогоняя проверку заново: структура проблемы от языка не зависит.
#
# Идентификаторы (ghost_mill, produced_in) в тексте остаются как есть — это
# машинные имена, а не переводимые слова.
func _test_localization(state: Dictionary):
    var original := TranslationServer.get_locale()
    var gd = _make_data()
    var problems: Array = DataValidator.new().validate(gd)

    # Тексты собираются при validate() — на языке, который действовал в этот
    # момент. Поэтому язык переключаем ДО чтения, а localize_problems()
    # пересобирает уже собранные сообщения, не прогоняя проверку заново.
    TranslationServer.set_locale("en")
    DataValidator.localize_problems(problems)
    var en_sample := _find(problems, "produced_in", "ghost_mill", "bad_produced_in")
    check(not en_sample.is_empty(),
        "синтетические данные должны давать проблему produced_in", state)
    var en_message := str(en_sample.get("message", ""))
    var en_headline := str(en_sample.get("headline", ""))
    var en_title := DataValidator.check_title("produced_in")
    var en_forms := DataValidator.entity_forms("building")

    TranslationServer.set_locale("ru")
    DataValidator.localize_problems(problems)
    var ru_message := str(en_sample.get("message", ""))
    var ru_headline := str(en_sample.get("headline", ""))
    var ru_title := DataValidator.check_title("produced_in")
    var ru_forms := DataValidator.entity_forms("building")

    check(ru_message != en_message,
        "текст проблемы обязан отличаться между языками: en=%s ru=%s" % [
            en_message, ru_message], state)
    check(ru_headline != en_headline,
        "первая строка проблемы обязана переводиться: en=%s ru=%s" % [
            en_headline, ru_headline], state)
    check(ru_message.contains("не существует"),
        "в русском тексте нет ожидаемой формулировки: %s" % ru_message, state)

    # Кириллицы в английском тексте быть не должно. Проверяем headline, а не
    # message: в message попадает название сущности из данных, а оно в этом
    # тесте намеренно русское (см. _test_no_false_positives_on_synthetic —
    # кириллица в name законна и не должна считаться ошибкой id).
    check(not _has_cyrillic(en_headline),
        "в английском тексте не должно быть кириллицы: %s" % en_headline, state)

    # Заголовок группы проверки — тоже пользовательский текст.
    check(ru_title != en_title,
        "заголовок проверки обязан переводиться: en=%s ru=%s" % [
            en_title, ru_title], state)
    check(not _has_cyrillic(en_title),
        "в английском заголовке проверки не должно быть кириллицы: %s" % en_title,
        state)

    # Падежи: одна и та же сущность в трёх грамматических формах. По-русски
    # это «Здания» / «это здание» / «здании» — три разных слова.
    for role in ["title", "ref", "source"]:
        check(not _has_cyrillic(str(en_forms[role])),
            "английская форма %s не должна быть кириллицей: %s" % [
                role, str(en_forms[role])], state)
    check(str(ru_forms["ref"]) != str(ru_forms["source"]),
        "русские формы ref и source не должны совпадать: %s / %s" % [
            str(ru_forms["ref"]), str(ru_forms["source"])], state)

    TranslationServer.set_locale(original)
    gd.free()


# Кириллица в строке — признак того, что сообщение осталось русским там, где
# должен быть английский (или наоборот).
func _has_cyrillic(text: String) -> bool:
    var regex := RegEx.new()
    regex.compile("[\u0400-\u04FF]")
    return regex.search(text) != null


# --- ВСПОМОГАТЕЛЬНОЕ ------------------------------------------------------

# Синтетический набор данных: «хорошая» база + по одной поломке каждого вида.
# Создаётся отдельный экземпляр GameData (не автозагрузка) — ему доступны
# все публичные поля, которые читает валидатор.
func _make_data() -> Node:
    var gd = load("res://scripts/GameData.gd").new()

    gd.categories = [
        {"id": "food", "name": "Еда"},
        {"id": "other", "name": "Разное"},
    ]
    gd.professions = {
        "farmer": {"id": "farmer", "name": "Фермер"},
        "blacksmith": {"id": "blacksmith", "name": "Кузнец"},
    }
    gd.technologies = [
        {"id": "t_fire", "name": "Огонь"},
        {"id": "t_wheel", "name": "Колесо"},
        # Пререквизиты в обоих допустимых форматах: плоский список и
        # список ИЛИ-групп [[ "a", "b" ], [ "c" ]].
        {"id": "t_flat_prereq", "name": "Плоский", "prerequisites": ["t_fire"]},
        {"id": "t_group_prereq", "name": "Групповой", "prerequisites": [["t_fire", "t_wheel"]]},
    ]
    gd.improvements = {
        "farm": {"id": "farm", "name": "Ферма"},
        "quarry": {"id": "quarry", "name": "Карьер"},
        # Лесная делянка — производитель, которого нет ни в одном produces
        # (см. константы LUMBERJACK_* в data_validator.gd). Пока есть делянка
        # и покров с wood_yield, продукт «wood» имеет источник.
        "lumberjack_hut": {"id": "lumberjack_hut", "name": "Лесная делянка"},
    }
    gd.covers = {
        "forest": {"id": "forest", "name": "Лес", "wood_yield": 2},
        "plain": {"id": "plain", "name": "Равнина"},
    }
    gd.products = {
        "wheat": {"id": "wheat", "name": "Пшеница", "category": "food"},
        "flour": {"id": "flour", "name": "Мука", "category": "food"},
        "tools": {"id": "tools", "name": "Инструменты", "category": "other"},
        # Производится лесной делянкой из wood_yield покрова. Единственный
        # источник древесины в наборе: ни в produces, ни в рецептах её нет.
        "wood": {"id": "wood", "name": "Древесина", "category": "other"},
        # Псевдо-продукт: есть только в display_result, реального result нет.
        "science": {"id": "science", "name": "Наука", "category": "other"},
        # Продукт с тем же id, что и у сырья clay_deposit: так выглядит
        # обычная ситуация «сырьё добывают, продукт используют» — валидатор
        # обязан различать их по коллекциям, а не по id.
        "clay": {"id": "clay", "name": "Глина", "category": "other"},
    }
    gd.raw_resources = {
        "wheat_field": {"id": "wheat_field", "name": "Пшеничное поле", "type": "raw",
                "category": "plants", "improved_by": "farm",
                "produces": {"wheat": 10, "tools": 1}},
        "clay_deposit": {"id": "clay_deposit", "name": "Глина", "type": "raw",
                "category": "plants", "improved_by": "quarry", "produces": {"clay": 10}},
    }
    gd.product_groups = {
        "grains": ["wheat"],
        "food": ["wheat", "flour"],
        "jewelry": ["tools"],
    }
    gd.product_group_names = {
        "grains": "Злаки",
        "food": "Еда",
        "jewelry": "Украшения",
    }
    gd.buildings = [
        {"id": "bakery", "name": "Пекарня"},
    ]

    # --- поломки ---
    # Продукт с кириллической «с» в id: для глаза неотличим от латинского,
    # но не совпадает с ним побайтово. Латинского «coal_typo» в наборе нет,
    # поэтому это одиночная опечатка (id_charset), а не пара (id_lookalike).
    gd.products["сoal_typo"] = {"id": "сoal_typo", "name": "Опечатка",
            "category": "other"}
    # Пара-омоглиф: латинский «carmine» и кириллический «сarmine» объявлены
    # одновременно. Латинское написание ссылок исправно (оно и существует),
    # поэтому этот случай обычные проверки битых ссылок пропускают целиком.
    gd.products["carmine"] = {"id": "carmine", "name": "Кармин", "category": "other"}
    gd.products["сarmine"] = {"id": "сarmine", "name": "Кармин (опечатка)",
            "category": "other"}
    # produced_in → несуществующее здание
    gd.buildings.append({"id": "bad_building_tech", "name": "Дом", "unlock_tech": "ghost_tech"})
    # profession у здания
    gd.buildings.append({"id": "bad_building_prof", "name": "Мастерская",
            "profession": "ghost_prof"})
    # unlock_tech у улучшения
    gd.improvements["bad_improvement_tech"] = {"id": "bad_improvement_tech",
            "name": "Плохая яма", "unlock_tech": "ghost_tech"}
    # profession у улучшения
    gd.improvements["bad_improvement_prof"] = {"id": "bad_improvement_prof",
            "name": "Плохая пашня", "profession": "ghost_prof"}
    # improved_by у сырья
    gd.raw_resources["bad_improved_by"] = {"id": "bad_improved_by", "name": "Рожь",
            "type": "raw", "improved_by": "ghost_farm"}
    # unlock_improvement у продукта
    gd.products["bad_unlock_improvement"] = {"id": "bad_unlock_improvement",
            "name": "Зерно", "category": "food", "unlock_improvement": "ghost_farm"}
    # unlock_tech у продукта
    gd.products["bad_product_tech"] = {"id": "bad_product_tech", "name": "Соль",
            "category": "food", "unlock_tech": "ghost_tech"}
    # Продукт, который не производит НИ карта, НИ рецепт: ни в чьём produces,
    # ни в чьём result/display_result/additional_yield его нет. Единственная
    # поломка новой проверки product_source.
    gd.products["no_source_product"] = {"id": "no_source_product", "name": "Алхимия",
            "category": "other"}
    # category у продукта
    gd.products["bad_category"] = {"id": "bad_category", "name": "Мёд",
            "category": "ghost_category"}
    # несуществующий член @-группы
    gd.product_groups["bad_group"] = ["wheat", "ghost_member"]
    gd.product_group_names["bad_group"] = "Плохая группа"
    # prerequisites технологии (ИЛИ-группа с одним несуществующим id)
    gd.technologies.append({"id": "bad_tech_prereq", "name": "Плохая технология",
            "prerequisites": [["t_wheel", "ghost_tech"]]})
# Ловушки ложных срабатываний.
    gd.crafts = [
        # Корректные рецепты — на них валидатор молчит.
        {"id": "good_recipe", "name": "Хороший рецепт", "produced_in": ["bakery"],
                "resources": {"wood": 2, "@grains": 5}, "result": {"flour": 3},
                "unlock_tech": "t_fire"},
        # Псевдо-выход: result пуст, товар «появляется» только в
        # display_result — как «Наука» в data/crafts/pseudo.json.
        {"id": "pseudo_recipe", "name": "Псевдо-рецепт", "produced_in": ["bakery"],
                "resources": {}, "result": {}, "display_result": {"science": 1}},
        # "*" — служебный маркер «в любом здании».
        {"id": "wildcard_recipe", "name": "Пустой рецепт", "produced_in": ["*"],
                "resources": {}, "result": {}},
        # Ссылка на сырьё в result не считается поломкой (рецепт вправе
        # требовать и сырьё — «clay»), а вот несуществующее — да.
        {"id": "raw_result_ok", "name": "Рецепт с сырьём в result",
                "produced_in": ["bakery"], "resources": {}, "result": {"clay": 1}},
        {"id": "bad_produced_in", "name": "Рецепт в призрачном здании",
                "produced_in": ["ghost_mill"], "resources": {}, "result": {}},
        {"id": "bad_result", "name": "Рецепт с призрачным продуктом",
                "produced_in": ["bakery"], "resources": {}, "result": {"ghost_product": 1}},
        {"id": "bad_craft_tech", "name": "Рецепт за призрачной технологией",
                "produced_in": ["bakery"], "resources": {}, "result": {"flour": 1},
                "unlock_tech": "ghost_tech"},
        {"id": "bad_group_ref", "name": "Рецепт с призрачной группой",
                "produced_in": ["bakery"], "resources": {"@ghost_group": 5}, "result": {}},
        {"id": "bad_resource_ref", "name": "Рецепт с призрачным ресурсом",
                "produced_in": ["bakery"], "resources": {"ghost_raw": 5}, "result": {}},
        # Донор: даёт ВСЕ продукты с намеренными поломками в других полях
        # (улучшения / технологии / категории) и продукт с явно пустыми
        # полями. Без него каждая из этих записей попала бы в проблемы ещё и
        # по product_source, и одна намеренная поломка давала бы сразу две
        # проблемы — а тест требует ровно одну поломку каждого вида.
        {"id": "donor_recipe", "name": "Донор", "produced_in": ["bakery"],
                "resources": {}, "result": {
                    "bad_unlock_improvement": 1, "bad_product_tech": 1,
                    "bad_category": 1, "null_product": 1,
                    "сoal_typo": 1, "сarmine": 1, "carmine": 1}},
    ]
    # Категория "animals" у сырья — фильтр генерации карты, не категория
    # из categories.json. Проверяется у сырья отдельно ниже.
    gd.raw_resources["wildcard_raw"] = {"id": "wildcard_raw", "name": "Корова",
            "type": "raw", "category": "animals"}

    # --- Правила потребления (data/consumption.json) ---
    #
    # Хорошие записи обязаны молчать: продукт без "@", существующая @-группа,
    # настоящая профессия. Плохие — по одной на каждый новый вид проверки.
    # Реальный прообраз плохих записей — забытый "@": автор пишет id группы
    # там, где нужен ресурс (в data/consumption.json так было с "jewelry",
    # которого как продукта не существует, — есть только группа "@jewelry").
    gd.consumption_rules = [
        # Хорошие записи.
        {"resource": "tools", "profession": ["farmer"]},
        {"resource": "@jewelry", "profession": ["blacksmith"]},
        # Плохие: несуществующая @-группа, несуществующий продукт,
        # несуществующая профессия.
        {"resource": "@ghost_group", "profession": ["farmer"]},
        {"resource": "ghost_product", "profession": ["farmer"]},
        {"resource": "wheat", "profession": ["ghost_prof"]},
    ]

    # Явно пустые поля (null). В data/*.json так записаны, например,
    # "improved_by": null у самородков — это «улучшения нет», а не ссылка
    # на несуществующее улучшение. str(null) в GDScript даёт «<null>»,
    # поэтому без отдельной обработки валидатор ругался бы на каждое
    # пустое поле (регрессия, найденная этим же тестом).
    gd.raw_resources["null_fields"] = {"id": "null_fields", "name": "Пустое сырьё",
            "type": "raw", "improved_by": null, "unlock_tech": null, "category": null}
    gd.products["null_product"] = {"id": "null_product", "name": "Пустой продукт",
            "category": "food", "unlock_improvement": null, "unlock_tech": null}
    gd.improvements["null_improvement"] = {"id": "null_improvement",
            "name": "Пустое улучшение", "profession": null, "unlock_tech": null}
    gd.buildings.append({"id": "null_building", "name": "Пустое здание",
            "profession": null, "unlock_tech": null})

    return gd


func _find(problems: Array, kind: String, ref_id: String, source_id: String) -> Dictionary:
    for problem in problems:
        if str(problem.get("kind", "")) == kind \
                and str(problem.get("ref_id", "")) == ref_id \
                and str(problem.get("source_id", "")) == source_id:
            return problem
    return {}


# Строки файла данных как есть (с комментариями) — номера строк в сообщениях
# валидатора считаются по исходному тексту, а не по очищенному от комментариев.
func _read_lines(file_path: String) -> Array:
    var file := FileAccess.open(file_path, FileAccess.READ)
    if file == null:
        return []
    return Array(file.get_as_text().split("\n"))


func _expected_problem_count(expected: Dictionary) -> int:
    var total := 0
    for kind in expected:
        total += (expected[kind] as Array).size()
    return total


func _str_messages(problems: Array) -> String:
    var lines: Array = []
    for problem in problems:
        lines.append(str(problem.get("message", "")))
    return "; ".join(lines)


func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
