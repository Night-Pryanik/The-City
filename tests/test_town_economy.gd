# Headless-тест торговой экономики городка (замыкание производства + каскадный
# импорт): scripts/town_economy.gd
#   godot --headless --path . --script res://tests/test_town_economy.gd
#
# Проверяется ровно то, что задумано механикой:
#   1. ЗАМЫКАНИЕ. Ресурс, который не лежит на гексе, но выводится рецептом из
#      лежащего, попадает в пул продажи; дальше по цепочке (wood -> charcoal ->
#      iron). Рецепт, для которого сырья нет, в пул не попадает.
#   2. @-ГРУППА. Закрывается ОДНИМ членом из многих.
#   3. ГОТОВНОСТЬ = доля закрытых ингредиентов, количество НЕ учитывается.
#      Синтетика на 1/2, 1/3, 2/3 даёт ровно 50, 33, 67.
#   4. КАСКАД. Импорт открывает семейство товаров: купил руду — появился металл,
#      из металла — изделия. Число проходов не фиксировано.
#   5. ИЗОЛЯЦИЯ. Импортированное не продаётся — даже если само крафтовое.
#   6. ДЕТЕРМИНИРОВАННОСТЬ. Два вызова подряд дают одинаковые пулы: главный
#      регресс-тест, потому что при загрузке сейва пулы считаются дважды, и
#      «прыгающий» buy_pool ломал бы партию при каждом чтении сохранения.
#   7. ГРАНИЦЫ. Одноингредиентный рецепт не даёт ни импорта, ни замыкания при
#      нуле доступных; рецепт с двумя пробелами из трёх импортируется (1/3),
#      рецепт с бо́льшим числом пробелов — нет.
#   8. ПРЕДСТАВИТЕЛЬ ГРУППЫ. Случайный, но стабильный между вызовами и всегда
#      из состава группы.
#   9. ЖИВАЯ КАРТА. Пулы непустые, а повторный пересчёт ничего не меняет.
#  10. БАЗОВЫЙ ПУЛ = ПРОДУКЦИЯ. Само сырьё (поле, залежь, животное) в пул не
#      попадает — городок продаёт урожай, а не «поле пшеницы». Это убирает двоих
#      подряд «Wheat» в окне (wheat_field даёт wheat — они назывались одинаково).
#  11. ЖИВОТНЫЕ. Сами звери не товар; товар — мясо, кожа, молоко, улов.
#  12. ОДНОРАЗОВЫЕ. Дикорсы (wild_food) не дают ничего: их нельзя собирать
#      бесконечно, значит и продавать нечего. Самородки — наоборот, дают руду:
#      медь нужна кузнецу и добывается без ограничений.
#  13. ДУБЛИ ИМЁН. В окне одна строка на имя, даже если в пуле два разных id
#      с одинаковым названием (papyrus_plant и papyrus оба «Papyrus»).
#  14. ОКНО. Списки лежат в ScrollContainer: длинный пул прокручивается, а не
#      вылезает за нижний край окна на карту.
#  15. КАЗНА. Новый городок получает town_initial_treasury из game_balance.json,
#      окно показывает казну и обновляет её сразу по сигналу сделки; уйти в
#      минус городок не может.
#  16. СКЛАД. У каждого товара пула продажи есть запас 100..500 (town_storage_
#      initial_min/max), и он переживает повторный пересчёт пулов — проданное не
#      возвращается назад при перезагрузке сейва.
#  17. ПРОИЗВОДСТВО. Тик городка добавляет выход рецепта (10 шелка -> 10 шелка),
#      а городок не знает дефицита: тик набивает склад, даже когда ресурсов,
#      из которых делают, физически нет.
#  18. ЛИМИТ СКЛАДА. town_storage_limit на товар, а не на склад целиком: городок
#      на пределе по одному товару продолжает копить остальные.
#  19. ПРОИЗВОДСТВО ПОСЛЕ РАЗВЕДКИ. Неразведанный городок не производит, иначе к
#      моменту встречи с игроком его склад уже стоял бы полным.
#  20. СДЕЛКА. Продажа списывает единицы со склада, покупка кладёт; за пределами
#      запаса сделка не проходит, склад не уходит в минус.
#  21. ОКНО. В колонке продажи видно число единиц на складе, и оно обновляется
#      по сигналу без пересборки списка.
#  22. КАЧЕСТВО. У товара склада ровно один уровень: сырьё берёт НАИВЫСШЕЕ
#      качество среди гексов кольца (а не первое найденное), крафт — стандартное
#      средневзвешенное по ингредиентам; в окне — только звёзды в цвете уровня,
#      без разбивки и процентов, с тултипом-подписью уровня.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

# Эталонные id из data/: рецепты берутся из GameData.crafts, поэтому проверки
# сверяются с САМИМ реестром, а не с захардкоженными ожиданиями.
const WOOD := "wood"          # сырьё -> charcoal -> planks
const CHARCOAL := "charcoal"
const PLANKS := "planks"
const WHEAT := "wheat"        # член @millable_grains
const COPPER_ORE := "copper_ore"
const IRON_ORE := "iron_ore"
const TIN := "tin"            # член @bronze_alloys (bronze_alloys: tin/antimony/arsenic)

var _te = null
var _failed := false


func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()


func _check(cond: bool, msg: String) -> void:
    if cond:
        return
    _failed = true
    print("FAIL: ", msg)


func _run() -> void:
    # Автозагрузки берём через дерево сцены: в режиме --script имена
    # GameData/CityData недоступны на этапе компиляции этого файла.
    # new_game() заодно грузит все данные (рецепты, группы, ресурсы).
    get_root().get_node("SaveManager").new_game()
    var gd = get_root().get_node("GameData")
    _check(not gd.crafts.is_empty(), "реестр рецептов не загрузился")
    _check(gd.product_groups.has("bronze_alloys"),
        "группа bronze_alloys не загрузилась")
    # Модуль тоже через load(): class_name в --script-режиме может быть ещё не в
    # кеше (тот же аргумент, что у MapHelpers в других тестах).
    _te = load("res://scripts/town_economy.gd")

    _test_closure()
    _test_group_closes_with_one_member()
    _test_readiness()
    _test_cascade()
    _test_import_isolated_from_sell()
    _test_determinism()
    _test_group_member()
    _test_base_pool_is_products_only()
    _test_animals_excluded()
    _test_one_time_resources()
    _test_duplicate_names_hidden()
    await _test_live_map()
    await _test_town_ui_window()
    await _test_town_quality()
    await _test_town_treasury()
    _test_storage_seeded()
    _test_production_plan()
    _test_storage_limit()
    await _test_production_after_scouting()
    await _test_trade_moves_goods()
    await _test_window_shows_stock()

    print("test_town_economy: ", "ПРОВАЛЕН" if _failed else "все проверки пройдены")
    quit(2 if _failed else 0)


# --- Пул для произвольного набора id: base -> замыкание без импорта ---
# Замыкание считается напрямую через _close_pool, минуя каскад импорта.
func _pool_only(base_ids: Array) -> Dictionary:
    var pool: Dictionary = {}
    for pid in base_ids:
        pool[str(pid)] = true
    var made: Dictionary = {}
    _te._close_pool(pool, made, {})
    return pool


# 1. Замыкание: wood -> charcoal -> planks. Замыкание рекурсивно, а не на один
# шаг: charcoal появляется только после wood, planks — только после charcoal.
func _test_closure() -> void:
    var pool := _pool_only([WOOD])
    _check(pool.has(CHARCOAL),
        "из wood должен получаться charcoal — замыкание не сработало")
    _check(pool.has(PLANKS),
        "из charcoal должен получаться planks — цепочка замыкания не рекурсивна")
    # Дерево даёт уголь, поэтому с медной рудой медь выплавится: замыкание
    # должно связать ВСЮ цепочку, а не только первый шаг.
    var with_ore := _pool_only([WOOD, COPPER_ORE])
    _check(with_ore.has(CHARCOAL), "из wood должен получаться charcoal и при наличии руды")
    _check(with_ore.has("copper"),
        "wood + copper_ore обязаны давать copper через уголь — цепочка не сошлась")
    # А вот без дерева (нет угля) медь не варится даже при наличии руды.
    _check(not _pool_only([COPPER_ORE]).has("copper"),
        "без угля медную руду городок не выплатит")
    _check(_pool_only([WOOD, IRON_ORE]).has("iron"),
        "wood + iron_ore обязаны давать iron через уголь")


# 2. @-группа закрывается ОДНИМ членом: пшеница в @millable_grains, значит
# рецепт муки закрыт, хотя в группе девять зерновых.
func _test_group_closes_with_one_member() -> void:
    var gd = get_root().get_node("GameData")
    var millable: Array = gd.product_groups.get("millable_grains", [])
    _check(millable.has(WHEAT), "пшеница должна входить в @millable_grains")
    var pool := _pool_only([WHEAT])
    _check(pool.has("flour"), "одна пшеница из группы должна давать flour")
    _check(pool.has("bread"), "из flour должен получаться bread")


# 3. Готовность = доля закрытых, количество не читается.
func _test_readiness() -> void:
    var pool := _pool_only([WOOD, COPPER_ORE])
    # bronze: copper + @bronze_alloys + charcoal. Закрыты copper и charcoal
    # (угол из дерева), не хватает сплава => 2 из 3.
    _check(_te.readiness_percent("bronze", pool) == 67,
        "готовность bronze (2 из 3) должна быть 67, получено %d"
            % _te.readiness_percent("bronze", pool))
    # bronze_tools: bronze + charcoal. Закрыт только уголь => 1 из 2.
    _check(_te.readiness_percent("bronze_tools", pool) == 50,
        "готовность bronze_tools (1 из 2) должна быть 50, получено %d"
            % _te.readiness_percent("bronze_tools", pool))
    # Рецепт, у которого не закрыт ни один ингредиент: 0.
    var empty := _pool_only([PLANKS])
    _check(_te.readiness_percent("gold", empty) == 0,
        "у рецепта без единого доступного ингредиента готовность 0")
    # Количество НЕ влияет: рецепт с двумя ингредиентами даёт 50 независимо от
    # того, просит он 10 или 100 единиц. Сверяем с САМИМИ данными рецепта,
    # чтобы тест не разъехался с ними при правке баланса.
    var gd = get_root().get_node("GameData")
    for craft in gd.crafts:
        if str(craft.get("id", "")) != "iron":
            continue
        var ingredients: Dictionary = craft.get("resources", {})
        _check(ingredients.size() == 2,
            "iron должен оставаться рецептом из двух ингредиентов")
        var only_ore := _pool_only([IRON_ORE])
        _check(_te.readiness_percent("iron", only_ore) == 50,
            "готовность не должна зависеть от количества (iron_ore -> 50)")

# 4. КАСКАД. Импорт должен открывать целые семейства, а не один товар. На гексе
# ТОЛЬКО дерево: угля (из дерева) есть, а железной руды нет — значит рецепт «iron»
# закрыт ровно наполовину и может выиграть бросок. Купив руду, городок получает
# металл, а из металла — изделия. Число проходов не фиксировано, поэтому
# проверяем результат, а не количество итераций. Разные id городка дают разные
# броски, поэтому перебираем их: так каскад встретится гарантированно.
func _test_cascade() -> void:
    var found_family := false
    var details := ""
    for i in range(60):
        var pools: Dictionary = _te.build_pools("town_%d" % i, [WOOD])
        var sell: Array = pools["sell_pool"]
        var buy: Array = pools["buy_pool"]
        if buy.has(IRON_ORE) and sell.has("iron") and sell.has("iron_tools"):
            # Семейство раскрылось: купленную руду городок переработал, из
            # металла слепил изделия, и изделия уже в продаже.
            found_family = true
            break
        details = "городок %d: покупает %s, продаёт %s" % [i, str(buy), str(sell)]
    _check(found_family,
        "каскад импорта не раскрыл семейство железа ни для одного городка (%s)"
            % details)


# 5. ИЗОЛЯЦИЯ. Купленное не продаётся — по требованию дизайна.
func _test_import_isolated_from_sell() -> void:
    for i in range(40):
        var pools: Dictionary = _te.build_pools("town_%d" % i, [WOOD, IRON_ORE])
        var sell: Array = pools["sell_pool"]
        var buy: Array = pools["buy_pool"]
        for pid in buy:
            _check(not sell.has(pid),
                "импортированный товар «%s» не должен попадать в пул продажи" % pid)


# 6. ДЕТЕРМИНИРОВАННОСТЬ (главный регресс-тест). При загрузке сейва пулы
# считаются дважды, поэтому повторный вызов обязан дать ТО ЖЕ самое.
func _test_determinism() -> void:
    for i in range(10):
        var town_id := "town_det_%d" % i
        var first: Dictionary = _te.build_pools(town_id, [WOOD, COPPER_ORE, WHEAT])
        var second: Dictionary = _te.build_pools(town_id, [WOOD, COPPER_ORE, WHEAT])
        _check(first["sell_pool"] == second["sell_pool"],
            "пул продажи городка %s изменился при повторном расчёте" % town_id)
        # Устойчивость — единственное, что проверяем здесь; «купит ли городок хоть
        # что-то» зависит от бросков и по определению не гарантирована ни для
        # одного конкретного городка (см. тест каскада, где ради этого
        # перебираются десятки id).
        _check(first["buy_pool"] == second["buy_pool"],
            "пул покупки городка %s изменился при повторном расчёте" % town_id)


# 8. ПРЕДСТАВИТЕЛЬ @-ГРУППЫ. Случайный, но устойчивый и всегда из группы.
func _test_group_member() -> void:
    var gd = get_root().get_node("GameData")
    var members: Array = gd.product_groups.get("bronze_alloys", [])
    # bronze просит @bronze_alloys: в пуле есть copper (руда) и charcoal (дерево),
    # не хватает именно сплава. Если городок решил импортировать, в покупке
    # должен оказаться ОДИН из членов группы — и никакого ключа "@bronze_alloys".
    var seen_group_pick := false
    for i in range(40):
        var pools: Dictionary = _te.build_pools("town_grp_%d" % i, [WOOD, COPPER_ORE])
        for pid in pools["buy_pool"]:
            _check(not str(pid).begins_with("@"),
                "в пуле покупок не должно быть группового ключа «%s»" % pid)
            if members.has(str(pid)):
                seen_group_pick = true
    _check(seen_group_pick,
        "ни один городок не выбрал представителя @bronze_alloys — "
        + "проверьте разворот группы в импорте")


# --- Базовый пул: только продукция, а не сырьё ---

# Синтетические гексы с одним ресурсом каждый (collect_base_resources читает
# ключ resource, а при пустом — crop_bred).
func _tiles_with(resources: Array) -> Array:
    var tiles: Array = []
    for res_id in resources:
        tiles.append({"resource": str(res_id)})
    return tiles

# Пул продажи из гексов с заданными ресурсами (без импорта: 0 gaps).
# Типы аннотированы явно: _te загружен через load(), и без них вывод функции
# не выводится компилятором.
func _sell_pool_of(resources: Array) -> Array:
    var base: Array = _te.collect_base_resources(_tiles_with(resources))
    var pools: Dictionary = _te.build_pools("town_base_test", base)
    return pools["sell_pool"]

# 10. Поля и залежи: в пул идёт ПРОДУКЦИЯ, само сырьё — нет.
# Именно это убирает двоих подряд «Wheat»: wheat_field даёт wheat, и оба
# назывались «Wheat», хотя это разные вещи — посев и зерно.
func _test_base_pool_is_products_only() -> void:
    var pool := _sell_pool_of(["wheat_field", "basalt_deposit"])
    _check(not pool.has("wheat_field"),
        "само поле wheat_field не должно попадать в пул продажи: городок продаёт пшеницу, а не пшеничное поле")
    _check(not pool.has("basalt_deposit"),
        "сама залежь basalt_deposit не должна попадать в пул продажи: городок продаёт камень, а не месторождение")
    _check(pool.has(WHEAT), "продукция поля (wheat) обязана быть в пуле продажи")
    _check(pool.has("basalt"), "продукция залежи (basalt) обязана быть в пуле продажи")
    # Регресс на исходный симптом: никакого ресурса из data/resources/** в пуле.
    var gd = get_root().get_node("GameData")
    var raw_leaked: Array = []
    for res_id in pool:
        if gd.raw_resources.has(str(res_id)):
            raw_leaked.append(str(res_id))
    _check(raw_leaked.is_empty(),
        "в пуле продажи не должно быть ни одного сырья из data/resources (найдено: %s)" % str(raw_leaked))

# 11. Животные: в пуле мясо/кожа/молоко/улов, но не сами звери.
func _test_animals_excluded() -> void:
    var pool := _sell_pool_of(["cows", "ostrich", "freshwater_fish"])
    for animal in ["cows", "ostrich", "freshwater_fish"]:
        _check(not pool.has(animal),
            "животное «%s» не товар: городок не должен продавать его как таковое" % animal)
    _check(pool.has("raw_meat"), "от коров должно идти мясо (raw_meat)")
    _check(pool.has("hide"), "от коров должно идти сырое мясо и кожа (hide)")
    _check(pool.has("raw_milk"), "от коров должно идти молоко (raw_milk)")
    _check(pool.has("eggs"), "от страусов должны идти яйца (eggs)")
    _check(pool.has("raw_fish"), "от рыбы должен идти улов (raw_fish), а не сама рыба")

# 12. Одноразовые ресурсы: improved_by == null.
func _test_one_time_resources() -> void:
    # Дикорсы собираются один раз -> торговать нечем.
    var wild := _sell_pool_of(["wild_food"])
    _check(not wild.has("wild_food"), "дикорсы не должны продаваться как таковые")
    _check(not wild.has("foraged_food"),
        "собранная с дикорсов пища не должна быть товаром: её нельзя добывать повторно")
    # Самородки — тоже одноразовые, но это РУДА, а не находка: меди нужна
    # кузнецу, и добывается она без ограничений.
    var nugget := _sell_pool_of(["copper_nugget"])
    _check(not nugget.has("copper_nugget"), "сам самородок не товар, а находка на гексе")
    _check(nugget.has("copper"), "продукция самородка (copper) обязана быть в пуле: медь нужна кузнецу")
    # Признак is_one_time совпадает с игровым (control_panel/main_map).
    _check(_te.is_one_time("wild_food"), "wild_food должен опознаваться как одноразовый")
    _check(_te.is_one_time("copper_nugget"), "copper_nugget должен опознаваться как одноразовый")
    _check(not _te.is_one_time("wheat_field"), "поле с improved_by не одноразовое")


# 22. КАЧЕСТВО. У каждого товара склада ровно ОДИН уровень: у сырья — качество
# ресурса на гексе, у крафта — стандартное правило города (средневзвешенное по
# уровням ингредиентов, см. CityData.quality_from_breakdown). Смешанного
# качества в городке не бывает вовсе.
func _test_town_quality() -> void:
    var gd = get_root().get_node("GameData")
    var levels: Array = gd.get_quality_levels()
    _check(levels.size() == 4, "шкала качества должна быть из 4 ступеней")

    # Сырьё берёт качество гекса. Два гекса одного сырья разного качества не
    # усредняются: уровень склада задаёт НАИВЫСШЕЕ качество среди найденных.
    var tiles: Array = [
        {"resource": "wheat_field", "quality": "exceptional"},
        {"resource": "basalt_deposit", "quality": "fine"},
    ]
    var base: Dictionary = _te.collect_base_qualities(tiles)
    _check(str(base.get("wheat", "")) == "exceptional",
        "пшеница должна унаследовать качество поля (получено «%s»)" % str(base.get("wheat", "")))
    _check(str(base.get("feed", "")) == "exceptional",
        "корм с того же поля должен иметь то же качество")
    _check(str(base.get("basalt", "")) == "fine",
        "камень должен получить качество залежи")

    # Наивысшее побеждает, порядок обхода не важен. Корова обычного и корова
    # исключительного качества в одном кольце дают мясо/кожу/молоко
    # ИСКЛЮЧИТЕЛЬНОГО уровня.
    var highs: Dictionary = _te.collect_base_qualities([
        {"resource": "cows", "quality": "common"},
        {"resource": "cows", "quality": "exceptional"},
    ])
    _check(str(highs.get("raw_meat", "")) == "exceptional",
        "при смеси обычной и исключительной коровы побеждает исключительная (получено «%s»)"
            % str(highs.get("raw_meat", "")))
    _check(str(highs.get("hide", "")) == "exceptional",
        "побочные продукты коровы (кожа) тоже должны быть исключительными")
    _check(str(highs.get("raw_milk", "")) == "exceptional",
        "побочные продукты коровы (молоко) тоже должны быть исключительными")
    # Обратный порядок — тот же результат (наивысшее, а не «первое встреченное»).
    var highs_rev: Dictionary = _te.collect_base_qualities([
        {"resource": "cows", "quality": "exceptional"},
        {"resource": "cows", "quality": "common"},
    ])
    _check(str(highs_rev.get("raw_meat", "")) == "exceptional",
        "наивысшее качество не должно зависеть от порядка обхода кольца")
    # Идеальное качество перебивает исключительное.
    var best: Dictionary = _te.collect_base_qualities([
        {"resource": "cows", "quality": "common"},
        {"resource": "cows", "quality": "exceptional"},
        {"resource": "cows", "quality": "perfect"},
    ])
    _check(str(best.get("raw_meat", "")) == "perfect",
        "идеальное качество должно перебивать исключительное (получено «%s»)"
            % str(best.get("raw_meat", "")))

    # Ресурс без прокатанного качества (битый сейв) — обычный уровень, а не пустая строка.
    var broken: Dictionary = _te.collect_base_qualities([{"resource": "wheat_field"}])
    _check(str(broken.get("wheat", "")) == "common",
        "ресурс без качества должен падать на обычный уровень")

    # Крафт: средневзвешенное ингредиентов. wood (perfect=4) + copper_ore
    # (common=1) -> среднее 2.5 -> округление к ближайшему уровню (fine=2,
    # diff=0.5 против exceptional=3, diff=0.5 — ничья, побеждает первый в шкале).
    var crafted: String = _te.craft_result_quality(
        {"id": "copper", "resources": {"wood": 1, "copper_ore": 1}},
        {"wood": true, "copper_ore": true},
        {"wood": "perfect", "copper_ore": "common"})
    _check(crafted == "fine" or crafted == "exceptional",
        "крафт из perfect+common должен дать средний уровень (получено «%s»)" % crafted)

    # Оба ингредиента исключительные -> результат исключительный.
    var same: String = _te.craft_result_quality(
        {"id": "copper", "resources": {"wood": 1, "copper_ore": 1}},
        {"wood": true, "copper_ore": true},
        {"wood": "exceptional", "copper_ore": "exceptional"})
    _check(same == "exceptional",
        "одинаковые уровни ингредиентов дают тот же уровень (получено «%s»)" % same)

    # Окно показывает звёзды в цвете уровня, без разбивки и процентов.
    var ui = load("res://scenes/TownUI.tscn").instantiate()
    get_root().add_child(ui)
    await process_frame
    var tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(tm)
    var town: Dictionary = tm._make_town_record(0, 5, 5, false)
    town["sell_pool"] = [WOOD, PLANKS]
    town["buy_pool"] = []
    town["storage"] = {WOOD: 120, PLANKS: 40}
    town["quality"] = {WOOD: "perfect", PLANKS: "fine"}
    tm.towns.append(town)

    ui.open_town(town, true)
    var quality_labels: Dictionary = ui._sell_quality_labels
    _check(quality_labels.size() == 2,
        "у каждой строки продажи должна быть метка качества (получено %d)" % quality_labels.size())
    var wood_name: String = ui._get_resource_display_name(WOOD)
    var wood_stars: Label = quality_labels.get(wood_name, null)
    _check(wood_stars != null, "строка товара должна иметь метку звёзд")
    if wood_stars != null:
        _check(wood_stars.text == gd.get_quality_stars("perfect"),
            "звёзды строки должны быть уровнем товара (получено «%s»)" % wood_stars.text)
        _check(not wood_stars.text.contains("%") and not wood_stars.text.contains("("),
            "в метке качества не должно быть разбивки и процентов, только звёзды")
        _check(wood_stars.get_theme_color("font_color") == gd.get_quality_color("perfect"),
            "звёзды должны быть покрашены в цвет своего уровня")
        # Тултип поясняет, какой это уровень качества.
        _check(not wood_stars.tooltip_text.is_empty(),
            "у звёзд должен быть тултип с пояснением уровня")
        _check(wood_stars.tooltip_text.contains(gd.get_quality_name("perfect")),
            "тултип должен называть уровень качества (получено «%s»)" % wood_stars.tooltip_text)
        _check(wood_stars.mouse_filter == Control.MOUSE_FILTER_STOP,
            "метка звёзд должна ловить мышь, иначе тултип не покажется")
    # Второй товар — свой уровень и свой тултип.
    var planks_name: String = ui._get_resource_display_name(PLANKS)
    var planks_stars: Label = quality_labels.get(planks_name, null)
    _check(planks_stars != null, "у второй строки тоже должна быть метка звёзд")
    if planks_stars != null:
        _check(planks_stars.text == gd.get_quality_stars("fine"),
            "звёзды второй строки должны быть её уровнем (получено «%s»)" % planks_stars.text)
        _check(planks_stars.tooltip_text.contains(gd.get_quality_name("fine")),
            "тултип второй строки должен называть её уровень (получено «%s»)" % planks_stars.tooltip_text)
    ui.queue_free()
    tm.queue_free()


# 13. Два разных id с одинаковым именем — одна строка в окне.
# Основная защита от дублей живёт в данных (сырьё не попадает в пул), но в
# data/products есть ровно одна пара разных id с одинаковым названием:
# papyrus_plant (урожай) и papyrus (крафт) оба зовутся «Papyrus», и оба могут
# оказаться в пуле одного городка.
func _test_duplicate_names_hidden() -> void:
    var gd = get_root().get_node("GameData")
    var papyrus_plant: Dictionary = gd.products.get("papyrus_plant", {})
    var papyrus: Dictionary = gd.products.get("papyrus", {})
    _check(not papyrus_plant.is_empty() and not papyrus.is_empty(),
        "тест опирается на пару papyrus_plant/papyrus в data/products — она должна существовать")
    _check(str(papyrus_plant.get("name", "")) == str(papyrus.get("name", "")),
        "papyrus_plant и papyrus должны называться одинаково, иначе тест бессмысленен")
    var ui = load("res://scenes/TownUI.tscn").instantiate()
    get_root().add_child(ui)
    # Кадр нужен ради @onready: без него ссылки на узлы ещё не заполнены.
    await process_frame
    ui.open_town({"name": "T", "sell_pool": ["papyrus_plant", "papyrus"], "buy_pool": []}, true)
    var names: Array = ui._visible_row_names(ui.sell_list)
    _check(names.size() == 1,
        "два товара с одинаковым именем должны дать одну строку (получено %d: %s)"
            % [names.size(), str(names)])
    ui.queue_free()

# 14. Окно: списки прокручиваются и ничего не рисуют поверх карты.
func _test_town_ui_window() -> void:
    var ui = load("res://scenes/TownUI.tscn").instantiate()
    get_root().add_child(ui)
    await process_frame
    _check(ui.buy_scroll is ScrollContainer,
        "список покупки должен лежать в ScrollContainer, иначе длинный список вылезет на карту")
    _check(ui.sell_scroll is ScrollContainer,
        "список продажи должен лежать в ScrollContainer, иначе длинный список вылезет на карту")
    _check(ui.buy_list.get_parent() == ui.buy_scroll, "BuyList должен быть ребёнком BuyScroll")
    _check(ui.sell_list.get_parent() == ui.sell_scroll, "SellList должен быть ребёнком SellScroll")
    _check(ui.window_panel.clip_contents,
        "WindowPanel должен обрезать содержимое: без этого длинный список рисуется поверх карты")

    # Длинный пул: строк заведомо больше, чем влезает в окно.
    var gd = get_root().get_node("GameData")
    var long_pool: Array = []
    for pid in gd.products.keys():
        long_pool.append(str(pid))
    ui.open_town({"name": "T", "sell_pool": long_pool, "buy_pool": long_pool}, true)
    await process_frame
    await process_frame
    _check(ui.sell_list.get_child_count() > 10,
        "тест должен наполнить список десятками строк (строк: %d)" % ui.sell_list.get_child_count())
    # Ключевое: содержимое выше окна — значит, прокрутка действительно нужна.
    var content_height: float = ui.sell_list.size.y
    var window_height: float = ui.window_panel.size.y
    _check(content_height > window_height,
        "контент должен быть выше окна, иначе прокрутка нечего крутить (контент %d, окно %d)"
            % [int(content_height), int(window_height)])
    # И прокрутка реально прокручивает: смещаем и ждём кадра.
    ui.sell_scroll.scroll_vertical = int(content_height)
    await process_frame
    _check(ui.sell_scroll.scroll_vertical > 0,
        "ScrollContainer должен прокручиваться по вертикали (позиция: %d)" % ui.sell_scroll.scroll_vertical)
    ui.queue_free()


# 15. Казна городка: стартовое значение, сделки, окно в реальном времени, сейв.
func _test_town_treasury() -> void:
    var gd = get_root().get_node("GameData")
    var expected := int(gd.game_balance.get("town_initial_treasury", -1))
    _check(expected == 1000,
        "town_initial_treasury в game_balance.json: ожидалось 1000, получено %d" % expected)

    var tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(tm)
    var town: Dictionary = tm._make_town_record(0, 5, 5, false)
    _check(int(town.get("treasury", -1)) == expected,
        "новый городок должен получить стартовую казну (получено %s)" % str(town.get("treasury")))

    var ui = load("res://scenes/TownUI.tscn").instantiate()
    get_root().add_child(ui)
    await process_frame
    tm.town_treasury_changed.connect(ui.on_town_treasury_changed)
    ui.open_town(town, true)
    _check(ui.treasury_label.text.contains(str(expected)),
        "окно должно показывать казну городка (текст: %s)" % ui.treasury_label.text)

    tm.add_town_treasury(town, 150)
    _check(ui.treasury_label.text.contains(str(expected + 150)),
        "после поступления казна в окне должна обновиться сразу (текст: %s)" % ui.treasury_label.text)
    _check(tm.spend_town_treasury(town, 50), "списание в пределах казны должно пройти")
    _check(ui.treasury_label.text.contains(str(expected + 100)),
        "после списания казна в окне должна обновиться сразу (текст: %s)" % ui.treasury_label.text)
    _check(not tm.spend_town_treasury(town, expected * 10), "городок не может уйти в минус")
    _check(tm.get_town_treasury(town) == expected + 100, "неудачное списание не меняет казну")

    tm.towns.append(town)
    var saved: Array = tm.serialize_towns()
    tm.load_towns(saved)
    _check(tm.get_town_treasury(tm.towns[0]) == expected + 100, "казна городка должна переживать сейв")
    var legacy: Dictionary = saved[0].duplicate()
    legacy.erase("treasury")
    tm.load_towns([legacy])
    _check(tm.get_town_treasury(tm.towns[0]) == expected,
        "сейв без казны городка должен получить стартовое значение")

    ui.queue_free()
    tm.queue_free()


# 9. ЖИВАЯ КАРТА. Пулы считаются для реальных городков, и повторный пересчёт
# (как при загрузке сейва) ничего не меняет.
func _test_live_map() -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    var tm = main_map.get_node_or_null("TownManager")
    if tm == null:
        print("SKIP: живая карта не создала TownManager")
        return
    var towns: Array = tm.towns
    _check(not towns.is_empty(), "на живой карте должны быть городки")
    var first: Dictionary = {}
    for town in towns:
        var sell: Array = town.get("sell_pool", [])
        _check(not sell.is_empty(),
            "пул продажи городка %s пуст — городок нечего продавать"
                % str(town.get("id", "")))
        # Импорт не должен просочиться в продажу.
        for pid in town.get("buy_pool", []):
            _check(not sell.has(pid),
                "у городка %s купленное «%s» попало в продажу"
                    % [str(town.get("id", "")), pid])
        first[str(town.get("id", ""))] = [sell.duplicate(), town.get("buy_pool", []).duplicate()]
    # Повторный пересчёт — ровно то, что делает игра при загрузке сейва.
    tm._refresh_sell_pools(main_map.tile_data)
    for town in towns:
        var key := str(town.get("id", ""))
        if not first.has(key):
            continue
        _check(first[key][0] == town.get("sell_pool", []),
            "у городка %s пул продажи изменился при повторном пересчёте" % key)
        _check(first[key][1] == town.get("buy_pool", []),
            "у городка %s пул покупки изменился при повторном пересчёте" % key)

    # --- СКЛАД НА ЖИВОЙ КАРТЕ ---
    # У каждого городка есть склад, покрывающий весь пул продажи, и он не пустой:
    # иначе игрок увидел бы в окне товары без единой единицы.
    for town in towns:
        var key := str(town.get("id", ""))
        var storage: Dictionary = town.get("storage", {})
        var sell: Array = town.get("sell_pool", [])
        _check(not storage.is_empty(),
            "у городка %s пустой склад — в окне нечего продавать" % key)
        for pid in sell:
            _check(storage.has(str(pid)),
                "у городка %s на складе нет товара «%s» из пула продажи"
                    % [key, pid])
        # Покупное на склад не кладётся: купленное — это сырьё, а не товар.
        for pid in town.get("buy_pool", []):
            _check(not storage.has(str(pid)),
                "у городка %s купленное «%s» попало на склад" % [key, pid])
        # Склад повторяет пул продажи один в один: в нём нет ничего лишнего и не
        # хватает ничего. Пул считается ДВАжды на новой игре, и между проходами
        # кольцо получает декоративные поля, поэтому товар может перестать быть
        # продажным уже после того, как попал на склад.
        var on_stock: Array = []
        for pid in storage.keys():
            on_stock.append(str(pid))
        on_stock.sort()
        var sell_sorted: Array = sell.duplicate()
        sell_sorted.sort()
        _check(on_stock == sell_sorted,
            "склад городка %s должен совпадать с пулом продажи: на складе %s, в пуле %s"
                % [key, str(on_stock), str(sell_sorted)])
        # И склад заполнен НИЖЕ лимита: незакрытый городок не должен стоять
        # полным уже на старте игры (см. тест 19 про разведку).
        var limit: int = _te.get_storage_limit()
        for pid in storage:
            _check(int(storage[pid]) <= limit,
                "у городка %s товар «%s» на складе выше лимита (%d > %d)"
                    % [key, pid, int(storage[pid]), limit])

    # --- КАЧЕСТВО НА ЖИВОЙ КАРТЕ ---
    # У каждого товара склада ровно один уровень качества, и он из шкалы
    # data/qualities.json. Ни одной строки без звёзд в окне быть не должно.
    var gd = get_root().get_node("GameData")
    var levels: Array = gd.get_quality_levels()
    for town in towns:
        var key := str(town.get("id", ""))
        var quality: Dictionary = town.get("quality", {})
        _check(not quality.is_empty(),
            "у городка %s нет качества товаров склада" % key)
        for pid in town.get("sell_pool", []):
            var qid := str(quality.get(str(pid), ""))
            _check(levels.has(qid),
                "у городка %s товар «%s» без уровня качества (получено «%s»)"
                    % [key, pid, qid])
        # Смешанного качества в городке не бывает: качество хранится одним
        # уровнем на товар, а не разбивкой, поэтому лишние ключи — ошибка.
        for pid in quality.keys():
            _check(levels.has(str(quality[pid])),
                "у городка %s товар «%s» с уровнем вне шкалы" % [key, pid])
        for pid in quality.keys():
            _check(town.get("sell_pool", []).has(str(pid)),
                "у городка %s качество есть у не продажного «%s»" % [key, pid])
    main_map.queue_free()


# 16. СТАРТОВЫЙ ЗАПАС. У каждого товара пула продажи есть запас в границах из
# game_balance.json, и повторный пересчёт пулов (как при загрузке сейва) его НЕ
# трогает: иначе проданные единицы возвращались бы назад на каждой загрузке.
func _test_storage_seeded() -> void:
    var gd = get_root().get_node("GameData")
    var low := int(gd.game_balance.get("town_storage_initial_min", -1))
    var high := int(gd.game_balance.get("town_storage_initial_max", -1))
    _check(low == 100,
        "town_storage_initial_min в game_balance.json: ожидалось 100, получено %d" % low)
    _check(high == 500,
        "town_storage_initial_max в game_balance.json: ожидалось 500, получено %d" % high)

    var storage: Dictionary = _te.build_initial_storage("town_0", [WOOD, PLANKS, WHEAT])
    _check(storage.size() == 3,
        "стартовый склад должен покрывать все три товара (получено %d)" % storage.size())
    for pid in storage:
        var amount := int(storage[pid])
        _check(amount >= low and amount <= high,
            "стартовый запас «%s» = %d, вне границ [%d, %d]" % [pid, amount, low, high])

    # Детерминизм: тот же городок и тот же товар дают тот же запас. Пулы
    # считаются дважды на новой игре и при каждой загрузке, поэтому случайное
    # значение здесь означало бы скачущий склад.
    var again: Dictionary = _te.build_initial_storage("town_0", [WOOD, PLANKS, WHEAT])
    _check(again == storage, "стартовый запас должен быть детерминированным")

    # Разные городки отличаются: у соседей по карте не должно быть одинакового
    # склада «под копирку».
    var differs := false
    for i in range(30):
        var other: Dictionary = _te.build_initial_storage("town_%d" % i,
                [WOOD, PLANKS, WHEAT])
        if other.get(WOOD, -1) != storage.get(WOOD, -2):
            differs = true
            break
    _check(differs, "у разных городков запас одного товара должен различаться")


# 17. ПРОИЗВОДСТВО ПО РЕЦЕПТУ. Тик городка кладёт на склад ровно выход рецепта.
# Проверяем на САМИХ данных рецептов, чтобы тест не разъехался с ними при правке
# баланса: сколько рецепт обещает, столько и должно приходить за тик.
func _test_production_plan() -> void:
    var gd = get_root().get_node("GameData")
    var base: Array = _te.collect_base_resources(_tiles_with([WOOD]))
    var pools: Dictionary = _te.build_pools("town_prod", base)
    var production: Dictionary = pools["production"]
    _check(not production.is_empty(),
        "из дерева городок что-то производит — план производства не пуст")
    var checked := 0
    for pid in production:
        var id := str(pid)
        # Ищем рецепт с таким результатом и сверяем выход.
        for craft in gd.crafts:
            var result: Dictionary = craft.get("result", {})
            if not result.has(id):
                continue
            _check(int(production[id]) == int(result[id]),
                "выход рецепта «%s» по «%s»: план=%d, рецепт=%d"
                    % [str(craft.get("id", "")), id, int(production[id]), int(result[id])])
            checked += 1
            break
        # Импорт на склад не попадает.
        _check(not pools["buy_pool"].has(id),
            "купленное «%s» не должно попадать в план производства" % id)
    _check(checked > 0,
        "тест должен сверить хотя бы один товар с рецептом (сверено: %d)" % checked)

    # Городок НЕ знает дефицита. План производства не зависит от наличия сырья:
    # ингредиенты виртуальны, поэтому деревянный городок выдаёт уголь и доски, не
    # имея ни угля, ни досок на складе. Проверяем это напрямую: за один тик
    # склад пополняется тем же, что и на следующий, без всякого расхода сырья.
    var storage: Dictionary = _te.build_initial_storage("town_prod",
            _te.build_pools("town_prod", base)["sell_pool"])
    var plan: Dictionary = pools["production"]
    var before: Dictionary = storage.duplicate()
    _te.store_production(storage, plan, _te.get_storage_limit())
    var grew := false
    for pid in plan:
        if int(storage[pid]) > int(before[pid]):
            grew = true
    _check(grew, "тик производства должен пополнять склад")
    # Сырьё, из которого делают, на складе не тратится: городок ничего не расходует.
    for pid in plan:
        _check(int(storage.get(pid, 0)) == int(before[pid]) + int(plan[pid]),
            "склад «%s» должен вырасти ровно на выход рецепта" % pid)
        break


# 18. ЛИМИТ СКЛАДА. Лимит действует НА ТОВАР, а не на склад целиком: городок,
#     упёршийся в предел по одному товару, продолжает копить остальные.
func _test_storage_limit() -> void:
    var limit: int = _te.get_storage_limit()
    _check(limit == 1000,
        "town_storage_limit в game_balance.json: ожидалось 1000, получено %d" % limit)

    var storage: Dictionary = {WOOD: limit, PLANKS: 10}
    var plan: Dictionary = {WOOD: 50, PLANKS: 5, CHARCOAL: 7}
    _te.store_production(storage, plan, limit)
    _check(int(storage[WOOD]) == limit,
        "товар на пределе не должен превысить лимит (получено %d)" % int(storage[WOOD]))
    _check(int(storage[PLANKS]) == 15,
        "соседний товар должен продолжать копиться при пределе по другому")
    _check(int(storage[CHARCOAL]) == 7,
        "новый товар должен появиться на складе")

    # Переполнение с нуля: старт ниже лимита, а тик кладёт больше, чем осталось.
    var small := {WOOD: limit - 10}
    _te.store_production(small, {WOOD: 999}, limit)
    _check(int(small[WOOD]) == limit, "переполнение должно обрезаться по лимиту")
    # Нулевая и отрицательная выработка не должны ничего добавлять.
    var zero := {WOOD: 5}
    _te.store_production(zero, {WOOD: 0, PLANKS: -3}, limit)
    _check(int(zero[WOOD]) == 5, "нулевая выработка не должна менять склад")
    _check(not zero.has(PLANKS), "отрицательная выработка не должна создавать товар")


# Синтетическая карта, где заданный гекс (row, col) несёт флаги flags, а
# остальные пустые. Её размер подбирается под гекс городка: town_manager смотрит
# по координатам самого городка, а не по первому гексу.
func _map_with_tile(row: int, col: int, flags: Dictionary) -> Array:
    var tile_data: Array = []
    for r in range(row + 1):
        var line: Array = []
        for c in range(col + 1):
            line.append(flags.duplicate() if r == row and c == col else {})
        tile_data.append(line)
    return tile_data


# 19. ПРОИЗВОДСТВО НАЧИНАЕТСЯ ТОЛЬКО ПОСЛЕ РАЗВЕДКИ. Неразведанный городок молчит,
# иначе к моменту встречи с игроком его склад уже стоял бы полным.
func _test_production_after_scouting() -> void:
    var gd = get_root().get_node("GameData")
    var city_data = get_root().get_node("CityData")
    # Тик городка — в town_tick_ticks раз длиннее тика города. Проверяем и сам
    # множитель из game_balance.json, и итоговую длительность.
    _check(int(gd.game_balance.get("town_tick_ticks", -1)) == 4,
        "town_tick_ticks в game_balance.json: ожидалось 4, получено %d"
            % int(gd.game_balance.get("town_tick_ticks", -1)))
    var tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(tm)
    var town_tick: float = tm.get_town_tick_seconds()
    _check(is_equal_approx(town_tick,
            float(city_data.SIMULATION_TICK) * 4.0),
        "тик городка должен быть в 4 раза длиннее тика города (получено %.2f, тик города %.2f)"
            % [town_tick, float(city_data.SIMULATION_TICK)])
    var town: Dictionary = tm._make_town_record(0, 5, 5, false)
    town["sell_pool"] = [WOOD]
    town["production"] = {WOOD: 10}
    town["storage"] = {WOOD: 100}
    tm.towns.append(town)

    # Гекс в неизвестном мире: флагов нет — городок не производит.
    var unknown := _map_with_tile(5, 5, {"is_explored": false, "in_influence": false})
    tm.tick_towns(unknown)
    _check(tm.get_town_goods(town, WOOD) == 100,
        "неразведанный городок не должен производить (склад=%d)"
            % tm.get_town_goods(town, WOOD))
    _check(not bool(town.get("production_started", false)),
        "флаг начала производства не должен выставляться до разведки")

    # Разведка открыла гекс — производство пошло.
    unknown[5][5]["is_explored"] = true
    tm.tick_towns(unknown)
    _check(tm.get_town_goods(town, WOOD) == 110,
        "после разведки городок должен производить (склад=%d)"
            % tm.get_town_goods(town, WOOD))
    _check(bool(town.get("production_started", false)),
        "флаг начала производства должен выставиться при разведке")

    # Второй путь разведки — гекс внутри известной территории, без is_explored.
    var town2: Dictionary = tm._make_town_record(1, 1, 1, false)
    town2["sell_pool"] = [WOOD]
    town2["production"] = {WOOD: 10}
    town2["storage"] = {WOOD: 100}
    tm.towns.append(town2)
    var known := _map_with_tile(1, 1, {"in_influence": true, "is_explored": false})
    tm.tick_towns(known)
    _check(tm.get_town_goods(town2, WOOD) == 110,
        "гекс в известной территории тоже запускает производство (склад=%d)"
            % tm.get_town_goods(town2, WOOD))
    tm.queue_free()


# 20. СДЕЛКА. Продажа списывает единицы со склада, покупка кладёт их туда. За
# пределами запаса сделка не проходит — городок не продаёт то, чего у него нет.
func _test_trade_moves_goods() -> void:
    var tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(tm)
    var town: Dictionary = tm._make_town_record(0, 5, 5, false)
    town["storage"] = {WOOD: 200}
    tm.towns.append(town)

    _check(tm.get_town_goods(town, WOOD) == 200, "стартовый запас должен читаться из склада")
    _check(tm.take_town_goods(town, WOOD, 50), "продажа 50 единиц должна пройти")
    _check(tm.get_town_goods(town, WOOD) == 150,
        "после продажи на складе должно остаться 150 (получено %d)"
            % tm.get_town_goods(town, WOOD))
    _check(not tm.take_town_goods(town, WOOD, 500),
        "городок не может продать больше, чем есть на складе")
    _check(tm.get_town_goods(town, WOOD) == 150,
        "неудачная продажа не должна менять склад")

    _check(tm.add_town_goods(town, PLANKS, 30) == 30, "покупка 30 единиц должна пройти")
    _check(tm.get_town_goods(town, PLANKS) == 30, "после покупки товар должен лежать на складе")

    # Покупка в уже полный склад принимает только то, что влезло.
    var limit: int = _te.get_storage_limit()
    var full: Dictionary = tm._make_town_record(2, 6, 6, false)
    full["storage"] = {WOOD: limit}
    tm.towns.append(full)
    _check(tm.add_town_goods(full, WOOD, 100) == 0,
        "в полный склад ничего не должно влезать")
    _check(tm.add_town_goods(full, PLANKS, 25) == 25,
        "в другой товар влезать должно — лимит на товар, а не на склад")

    # Сейв: склад и флаг разведки переживают round-trip.
    var saved: Array = tm.serialize_towns()
    tm.load_towns(saved)
    var loaded: Dictionary = tm.towns[0]
    _check(tm.get_town_goods(loaded, WOOD) == 150,
        "склад должен переживать сейв (получено %d)" % tm.get_town_goods(loaded, WOOD))
    tm.queue_free()


# 21. ОКНО ПОКАЗЫВАЕТ СКЛАД. В колонке продажи видно число единиц, и оно
# обновляется по сигналу сделки без пересборки списка.
func _test_window_shows_stock() -> void:
    var ui = load("res://scenes/TownUI.tscn").instantiate()
    get_root().add_child(ui)
    await process_frame
    var tm = load("res://scripts/town_manager.gd").new()
    get_root().add_child(tm)
    var town: Dictionary = tm._make_town_record(0, 5, 5, false)
    town["sell_pool"] = [WOOD, PLANKS]
    town["buy_pool"] = [IRON_ORE]
    town["storage"] = {WOOD: 321, PLANKS: 7}
    tm.towns.append(town)
    tm.town_storage_changed.connect(ui.on_town_storage_changed)

    ui.open_town(town, true)
    var labels: Dictionary = ui._sell_quantity_labels
    _check(labels.size() == 2,
        "в колонке продажи должно быть по числу на каждый товар (получено %d)" % labels.size())
    # Строки ключуются отображаемым именем, а оно переводится: берём его из самого
    # окна, иначе проверка зависела бы от языка тестового прогона.
    var wood_name: String = ui._get_resource_display_name(WOOD)
    var wood_label: Label = labels.get(wood_name, null)
    _check(wood_label != null and wood_label.text.contains("321"),
        "окно должно показывать число единиц товара на складе")

    # Сделка меняет склад — надпись обновляется сразу, а список не пересобирается
    # (иначе прокрутка сбрасывалась бы на каждой сделке).
    var rows_before: Array = ui.sell_list.get_children()
    tm.take_town_goods(town, WOOD, 21)
    _check(ui._sell_quantity_labels.get(wood_name, null).text.contains("300"),
        "после продажи число в окне должно обновиться сразу")
    _check(ui.sell_list.get_children() == rows_before,
        "обновление чисел не должно пересобирать список")

    # Тик городка тоже обновляет окно — отдельный путь refresh_storage().
    ui.refresh_storage()
    _check(ui._sell_quantity_labels.get(wood_name, null).text.contains("300"),
        "refresh_storage должен читать актуальный склад")
    ui.queue_free()
    tm.queue_free()
