# town_economy.gd
# Торговая экономика городка (мелкого поселения): что он умеет ПРОИЗВОДИТЬ сам
# и что он готов купить извне.
#
# Пулы торговли считаются в town_manager._refresh_sell_pools, но сама логика
# «что из чего можно сделать» — чистая арифметика по данным рецептов
# (GameData.crafts) и группам (GameData.product_groups). Она не зависит ни от
# карты, ни от колец влияния, ни от состояния города, поэтому живёт здесь, в
# чистых статических функциях — так её можно проверять headless-тестом без
# генерации карты (tests/test_town_economy.gd).
#
# --- ПУТЬ ОТ РЕСУРСОВ К ПРОДАЖЕ ---
#   1. Базовый пул — ПРОДУКЦИЯ ресурсов гексов кольца (поле produces). Сам
#      ресурс — поле, залежь, животное, дикоросы, самородок — в пул НЕ идёт:
#      это описание гекса, а не товар. Торгуются пшеница, корм, мясо, кожа и
#      руда, а не «поле пшеницы» и не «корова». Правило ровно одно, поэтому
#      отдельных исключений для животных и одноразовых находок не требуется
#      (см. collect_base_resources).
#   2. ЗАМЫКАНИЕ (fixpoint) — пока пул расширяется, каждый рецепт, все
#      ингредиенты которого уже доступны, добавляет свой result в пул.
#      Ингредиент «доступен», если он сам в пуле ЛИБО это @-группа, любой
#      член которой в пуле (семантика GameData.get_storage_amount: «любой
#      продукт из группы»).
#   3. Каскад импорта. Рецепты, которые не закрылись, но у которых есть хотя бы
#      ОДИН доступный ингредиент, — кандидаты на покупку. Вероятность покупки
#      = доля закрытых ингредиентов, количество ресурса НЕ учитывается:
#      городок ничего не добывает и не производит в зданиях, его экономика
#      виртуальна, поэтому для него «нужно железо и уголь» значит ровно то же,
#      что «нужно 30 железа и 20 угля». Объёмы из data/crafts для этой задачи
#      не читаются вовсе.
#   4. Каскад повторяется, пока новый импорт что-то открывает: купленная руда
#      даёт металл, металл — изделия, и так далее. Фиксированного числа
#      проходов нет; цикл идёт до раунда, в котором не появилось НИ ОДНОГО
#      нового импорта.
#   5. Импортированное в пул ПРОДАЖИ не идёт (требование дизайна): городок
#      покупает, чтобы организовать производство, а не чтобы перепродать
#      сырьё. В продажу попадает только то, что он произвёл сам.
#
# --- ЧТО НАМЕРЕННО НЕ ПРОВЕРЯЕТСЯ ---
#   - unlock_tech рецепта. У городка нет своего дерева технологий, и гейт по
#     технологиям ИГРОКА связал бы торговый пул с прогрессом игрока: городок у
#     края карты «застыл бы» на уровне эпохи, в которую игрок ещё не дорос.
#   - produced_in рецепта. Городок не строит городских зданий; кузница,
#     которой у него нет, — не причина отказывать ему в производстве меди.
#
# --- ДЕТЕРМИНИРОВАННОСТЬ ---
# Решение о покупке — бросок вероятности, поэтому оно обязано быть УСТОЙЧИВЫМ:
# _refresh_sell_pools зовётся дважды подряд (из compute_all_town_influences и
# из _place_decorative_town_improvements) и оба раза при загрузке сейва.
# Глобальный randi() здесь дал бы городку другой buy_pool при каждой загрузке,
# и «что он покупает» прыгало бы от сохранения к сохранению. Поэтому все броски
# и выбор представителя @-группы идут через локальные RandomNumberGenerator с
# seed из (id городка, id рецепта, индекс ингредиента). Тот же приём, что и в
# _make_border_color: значение выводится из идентификатора, а не из состояния
# генератора случайных чисел.
class_name TownEconomy
extends RefCounted

# Учитывать ли продукцию ресурса (поле produces в data/resources/*.json) при
# построении базового пула. По умолчанию — единственный способ получить что-то
# в пуле: само сырьё не продаётся (collect_base_resources). Флаг оставлен как
# аварийный переключатель для отладки: при false в пул попадают сами id
# ресурсов, которые задуманы как источник, а не как товар.
const INCLUDE_RESOURCE_YIELD := true

# Категория ресурса, для которого ОДНОРАЗОВОСТЬ не означает «продавать
# нечего». Самородок (copper_nugget и прочие) — это руда на гексе, а не
# находка: однажды подобрав самородок, городок не перестанет варить медь.
# Поэтому продукция одноразовых металлов в пул идёт, а продукция остальных
# одноразовых ресурсов (дикорсы wild_food -> foraged_food) — нет: собирать
# её каждый раз нельзя, и такой товар в торговле был бы выдумкой.
const ONE_TIME_YIELD_CATEGORY := "metals"

# Одноразов ли ресурс — то есть исчезает ли он с гекса после сбора.
# Признак ровно тот же, что использует остальная игра для спецдействия
# «Собрать ресурс» (control_panel.gd, main_map.gd): improved_by == null
# (не разрабатывается улучшением) и непустое produces (есть что собрать).
# На данных это ровно 5 ресурсов: четыре самородка (copper_nugget,
# gold_nugget, silver_nugget, meteorite_iron_nugget) и wild_food. Важно, что
# категория у wild_food — "plants", а не "metals": отсеивать надо по category,
# а не по группе "wild".
static func is_one_time(resource_id: String) -> bool:
    var data: Dictionary = GameData.raw_resources.get(resource_id, {})
    if data.get("improved_by", null) != null:
        return false
    return not data.get("produces", {}).is_empty()

# --- Базовый пул ---

# Строит базовый пул городка: id ПРОДУКЦИИ ресурсов, лежащих на его гексах.
# Ресурс на гексе — природный (resource) ИЛИ разводимый (crop_bred): пищевое
# поле городка тоже должно что-то давать, иначе окно городка выглядит пустым.
#
# Что и почему попадает в пул (см. шапку файла):
#   - обычное сырьё (wheat_field, basalt_deposit): только produces — зерно и
#     корм, камень. Само поле/залежь не товар;
#   - животные (cows, ostrich, freshwater_fish): только produces — мясо, кожа,
#     яйца, улов. «Рыба» и «Страусы» в списке продажи читались бы как «городок
#     продаёт рыбу из воды», хотя продаёт улов;
#   - одноразовые металлы (copper_nugget): produces — руда. Руда кузнецу нужна,
#     и добывать её можно неограниченно;
#   - одноразовое прочее (wild_food): ничего. Дикорсы собираются один раз, и
#     их «foraged_food» в торговле — выдумка;
#   - ресурс, которого НЕТ в реестре (битый сейв), добавляется как есть:
#     молча выбросить его из пула хуже, чем показать.
#
# Замыкание производства от этого не страдает: ни один id из
# data/resources/** не встречается ингредиентом рецептов в data/crafts/** —
# рецепты оперируют только продуктами (hide, raw_meat, wheat, copper_ore).
#
# Возвращает массив id в стабильном порядке (как обход кольца).
static func collect_base_resources(tiles: Array) -> Array:
    var result: Array = []
    var seen: Dictionary = {}
    for entry in tiles:
        var tile: Dictionary = entry if entry is Dictionary else {}
        if tile.is_empty():
            continue
        var resource_id := MapHelpers.get_effective_resource(tile).strip_edges()
        # Отсутствие ресурса в JSON/сейвах — это null, и str(null) дал бы
        # псевдоресурс "<null>", который попал бы в пул первым. Пустая строка и
        # "<null>" отбрасываются одинаково (как было в town_manager).
        if resource_id.is_empty() or resource_id == "<null>" or seen.has(resource_id):
            continue
        seen[resource_id] = true
        var data: Dictionary = GameData.raw_resources.get(resource_id, {})
        if data.is_empty():
            result.append(resource_id)
            continue
        if not INCLUDE_RESOURCE_YIELD:
            result.append(resource_id)
            continue
        var produces: Dictionary = data.get("produces", {})
        if produces.is_empty():
            # Урожая нет — продавать нечего, но и выбрасывать ресурс молча
            # нельзя: он всё равно что-то значит для городка.
            result.append(resource_id)
            continue
        if is_one_time(resource_id) \
                and str(data.get("category", "")) != ONE_TIME_YIELD_CATEGORY:
            continue
        # Продукция ресурса (cows -> raw_meat/hide, wheat_field -> wheat/feed):
        # то же хозяйство, только другой выход. Рецепты едят именно эти
        # продукты, а не самих животных и не сами поля.
        for pid in produces:
            var produced := str(pid)
            if produced.is_empty() or seen.has(produced):
                continue
            seen[produced] = true
            result.append(produced)
    return result

# --- Проверка доступности ингредиента ---

# Доступен ли ингредиент key для пула pool.
# Обычный ключ — сам в пуле. "@"-группа — в пуле ХОТЯ БЫ ОДИН её член: так же
# трактуются группы в остальной игре (GameData.get_storage_amount, CityData
# при списании потребления). Это же делает рецепт вроде «хлеб из
# @millable_grains» выполнимым, если есть хотя бы одна пшеница.
static func is_available(key: String, pool: Dictionary) -> bool:
    if pool.has(key):
        return true
    if not key.begins_with("@"):
        return false
    var members: Array = GameData.product_groups.get(key.substr(1), [])
    for member in members:
        if pool.has(str(member)):
            return true
    return false

# --- Замыкание ---

# Рекурсивно дополняет pool всем, что можно произвести из уже известного.
#
# made — Dictionary-множество: сюда складываются id, ПРОИЗВЕДЁННЫЕ крафтом (в
# отличие от базового пула, куда входят и природные ресурсы).
#
# Фикс-точка безопасна: пул только растёт, а множество возможных id конечно,
# поэтому цикл завершается. Страховочный счётчик проходов — на случай
# зацикливания из-за ошибки в данных: лучше остановиться с неполным пулом, чем
# зависнуть на старте партии.
static func _close_pool(pool: Dictionary, made: Dictionary) -> void:
    var guard := 0
    while guard < 1000:
        guard += 1
        var grew := false
        for craft in GameData.crafts:
            var result: Dictionary = craft.get("result", {})
            # Псевдо-рецепты (empty, science) результата не имеют — в пуле им
            # нечего добавлять, а их ингредиенты не описывают производство.
            if result.is_empty():
                continue
            var ingredients: Dictionary = craft.get("resources", {})
            var ready := true
            for key in ingredients:
                if not is_available(str(key), pool):
                    ready = false
                    break
            if not ready:
                continue
            for pid in result:
                var produced := str(pid)
                if pool.has(produced):
                    continue
                pool[produced] = true
                made[produced] = true
                grew = true
        if not grew:
            return

# --- Готовность и бросок ---

# Доля закрытых ингредиентов в процентах: насколько рецепт «почти собран».
# Количество ресурса в расчёт НЕ входит намеренно (см. шапку файла). Значения
# для рецептов из 2–3 ингредиентов: 1 из 2 -> 50, 1 из 3 -> 33, 2 из 3 -> 67.
#
# Именно ОКРУГЛЕНИЕ, а не целочисленное деление: 2/3 = 66.67 -> 67, а при
# отбрасывании дробной части вышло бы 66, и «два из трёх» читалось бы хуже,
# чем «один из двух» (50), хотя закрыто больше. Вероятность покупки обязана быть
# не меньше у более готового рецепта.
static func readiness_percent(recipe_id: String, pool: Dictionary) -> int:
    for craft in GameData.crafts:
        if str(craft.get("id", "")) != recipe_id:
            continue
        return _readiness_of(craft, pool)
    return 0

static func _readiness_of(craft: Dictionary, pool: Dictionary) -> int:
    var ingredients: Dictionary = craft.get("resources", {})
    var total := ingredients.size()
    if total == 0:
        return 0
    var available := 0
    for key in ingredients:
        if is_available(str(key), pool):
            available += 1
    return roundi(float(available) * 100.0 / float(total))

# Бросок делается ОДИН раз за рецепт (результат запоминается в rolls) — «городок
# решил», а не «городок бросает кости на каждом раунде заново». Рецепт может
# встретиться в нескольких раундах каскада, и перебрасывать его каждый раз
# означало бы лотерею с неограниченным числом попыток.
static func _roll_import(town_id: String, recipe_id: String, percent: int,
        rolls: Dictionary) -> bool:
    if rolls.has(recipe_id):
        return bool(rolls[recipe_id])
    var rng := RandomNumberGenerator.new()
    rng.seed = _seed_for(town_id, recipe_id)
    var success := rng.randi_range(1, 100) <= percent
    rolls[recipe_id] = success
    return success

# Представитель @-группы: СЛУЧАЙНЫЙ член (цена не важна — экономика виртуальная).
# Детерминирован по той же причине, что и бросок: выбор обязан быть устойчив к
# перезагрузке сейва, иначе пул покупок пересматривался бы при каждом чтении.
static func _pick_group_member(town_id: String, recipe_id: String,
        index: int, group_key: String) -> String:
    var members: Array = GameData.product_groups.get(group_key, [])
    if members.is_empty():
        return ""
    var rng := RandomNumberGenerator.new()
    rng.seed = _seed_for(town_id, recipe_id) + index
    return str(members[rng.randi_range(0, members.size() - 1)])

# Устойчивый seed из строки. Нам не нужен конкретный алгоритм хеша — только
# чтобы разные (городок, рецепт, индекс) давали разные числа, а одинаковые —
# одинаковые.
static func _seed_for(town_id: String, recipe_id: String) -> int:
    var raw := "%s|%s" % [town_id, recipe_id]
    var h := 17
    for i in range(raw.length()):
        h = (h * 31 + raw.unicode_at(i)) & 0x7FFFFFFF
    return h

# --- Сборка пулов ---

# Полный расчёт торговых пулов городка.
#
# town_id   — идентификатор городка ("town_3"); входит в seed всех бросков.
# base_ids  — базовый пул из collect_base_resources.
# max_gaps  — сколько разных ингредиентов допустимо докупить (из
#             data/game_balance.json, max_import_gaps). Рецепт с одним
#             недостающим проходит, с двумя — если повезло с броском, с тремя —
#             никогда: закупка трёх разных товаров ради одного изделия городку
#             не по карману.
#
# Возвращает { "sell_pool": Array, "buy_pool": Array }; оба массива
# отсортированы, чтобы одинаковое состояние давало одинаковый результат при
# печати и в тестах.
static func build_pools(town_id: String, base_ids: Array, max_gaps: int = 2) -> Dictionary:
    var made: Dictionary = {}
    var imports: Dictionary = {}
    # Базовый пул — простое множество: id -> true. Повторы схлопываются.
    var pool: Dictionary = {}
    for base_id in base_ids:
        var id := str(base_id)
        if id.is_empty():
            continue
        pool[id] = true
    _close_pool(pool, made)

    # Каскад импорта: раунд за раундом, пока новый импорт что-то открывает.
    var rolls: Dictionary = {}
    var guard := 0
    while guard < 200:
        guard += 1
        var bought: Dictionary = {}
        for craft in GameData.crafts:
            var recipe_id := str(craft.get("id", ""))
            if recipe_id.is_empty():
                continue
            var ingredients: Dictionary = craft.get("resources", {})
            # Рецепт без ингредиентов и псевдо-рецепты без результата в покупке
            # не участвуют: нечего покупать либо нечего производить.
            if ingredients.is_empty() or craft.get("result", {}).is_empty():
                continue
            var missing: Array = []
            for key in ingredients:
                if not is_available(str(key), pool):
                    missing.append(str(key))
            # Полностью закрытый рецепт не кандидат. Рецепт без единого
            # доступного ингредиента — тоже: покупать ВСЁ сразу бессмысленно,
            # городок заинтересован в производстве, а не в перепродаже сырья.
            if missing.is_empty() or missing.size() == ingredients.size():
                continue
            if missing.size() > max_gaps:
                continue
            if not _roll_import(town_id, recipe_id, _readiness_of(craft, pool), rolls):
                continue
            var index := 0
            for key in missing:
                var missing_key := str(key)
                var concrete := missing_key
                if missing_key.begins_with("@"):
                    concrete = _pick_group_member(town_id, recipe_id, index,
                            missing_key.substr(1))
                index += 1
                if concrete.is_empty() or imports.has(concrete):
                    continue
                imports[concrete] = true
                bought[concrete] = true
        if bought.is_empty():
            break
        for id in bought:
            pool[id] = true
        _close_pool(pool, made)

    # Пул продажи: базовые ресурсы + всё произведённое, МИНУС импортированное.
    # Импорт сюда не попадает намеренно (шапка файла, пункт 5). Подмножество
    # «импортированное, что при этом оказалось крафтовым» на реальных данных
    # пусто, но правило зафиксировано явно: купленное не продаётся.
    var sell: Dictionary = {}
    for id in pool:
        if imports.has(id):
            continue
        sell[id] = true
    var sell_ids: Array = sell.keys()
    sell_ids.sort()
    var buy_ids: Array = imports.keys()
    buy_ids.sort()
    return {"sell_pool": sell_ids, "buy_pool": buy_ids}

# --- Пересчёт по кольцам влияния ---

# Пересобирает торговые пулы ВСЕХ городков. Вынесено из town_manager, чтобы
# тот занимался размещением и кольцами, а пулы считались здесь.
static func refresh_all_towns(town_list: Array, tile_data: Array) -> void:
    for town in town_list:
        refresh_town(town, tile_data)

static func refresh_town(town: Dictionary, tile_data: Array) -> void:
    var town_id := str(town.get("id", ""))
    var tiles: Array = []
    for hex in town.get("influence_hexes", []):
        var row := int(hex.get("row", -1))
        var col := int(hex.get("col", -1))
        if row < 0 or row >= tile_data.size() or tile_data[row] == null \
                or col >= tile_data[row].size():
            continue
        var tile = tile_data[row][col]
        if tile == null:
            continue
        tiles.append(tile)
    var base_ids := collect_base_resources(tiles)
    var pools := build_pools(town_id, base_ids,
            int(GameData.game_balance.get("max_import_gaps", 2)))
    town["sell_pool"] = pools["sell_pool"]
    town["buy_pool"] = pools["buy_pool"]
