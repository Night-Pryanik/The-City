# Headless-тест дополнительных мест разведения (`breeding`):
#   godot --headless --path "E:\The City" --script res://tests/test_breeding_terrains.gd
#
# Проверяет реальные JSON-данные и общий MapHelpers.can_breed_resource_on_tile:
# базовые места сохраняются, группы breeding работают по И/ИЛИ-семантике,
# ошибочные комбинации не проходят, breedable=false имеет приоритет, а
# get_buildable_improvement предлагает улучшение на дополнительном биоме.
extends SceneTree

# Сторож зависаний: без него обрыв корутины _run() выглядит снаружи как вечное
# молчание. Подробности — в tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    # new_game() загружает все реальные data/*.json и сбрасывает CityData.
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var gdata = get_root().get_node("GameData")
    var city = get_root().get_node("CityData")
    var map_helpers = load("res://scripts/map_helpers.gd")

    _test_base_locations(map_helpers, state)
    _test_oasis_resources(map_helpers, gdata, state)
    _test_animal_locations(map_helpers, state)
    _test_negative_and_invalid_cases(map_helpers, gdata, state)
    _test_buildable_improvement(map_helpers, city, state)

    if state["failed"]:
        print("BREEDING TERRAINS TEST FAILED")
        quit(1)
    else:
        print("BREEDING TERRAINS TEST OK")
        quit(0)

func _test_base_locations(map_helpers, state: Dictionary) -> void:
    check(map_helpers.can_breed_resource_on_tile("grapes_plant", _tile("plain", "none")),
            "grapes_plant должен по-прежнему разводиться на равнине без покрова", state)
    check(map_helpers.can_breed_resource_on_tile("cows", _tile("plain", "sparse_forest")),
            "cows должны по-прежнему разводиться на равнине с редколесьем", state)
    check(not map_helpers.can_breed_resource_on_tile("grapes_plant", _tile("plain", "forest")),
            "grapes_plant не должен разводиться на не разрешённом покрове", state)

func _test_oasis_resources(map_helpers, gdata, state: Dictionary) -> void:
    var oasis_resource_ids := [
        # Фрукты.
        "grapes_plant", "olives_plant", "fig_plant",
        # Пищевые растения.
        "wheat_field", "barley_field", "rice_field", "corn_field", "millet_field",
        "sorghum_field", "amaranth_field", "bean_field", "cowpea_field",
        "lentil_field", "chickpea_field"
    ]
    for res_id in oasis_resource_ids:
        var data: Dictionary = gdata.raw_resources.get(res_id, {})
        check(not data.is_empty(), "ресурс %s должен существовать в данных" % res_id, state)
        check(data.has("breeding"), "ресурс %s должен иметь поле breeding" % res_id, state)
        check(map_helpers.can_breed_resource_on_tile(res_id, _tile("sandy_desert", "oasis")),
                "%s должен разводиться в оазисе песчаной пустыни" % res_id, state)
        check(map_helpers.can_breed_resource_on_tile(res_id, _tile("rocky_desert", "oasis")),
                "%s должен разводиться в оазисе каменистой пустыни" % res_id, state)
        check(not map_helpers.can_breed_resource_on_tile(res_id, _tile("sandy_desert", "none")),
                "%s не должен автоматически разводиться на голой песчаной пустыне" % res_id, state)

func _test_negative_and_invalid_cases(map_helpers, gdata, state: Dictionary) -> void:
    check(not map_helpers.can_breed_resource_on_tile("grapes_plant", _tile("plain", "oasis")),
            "grapes_plant не должен разводиться на равнине с оазисным покровом", state)
    check(not map_helpers.can_breed_resource_on_tile("sheep", _tile("sandy_desert", "none")),
            "овцы не должны разводиться на голой песчаной пустыне", state)
    check(not map_helpers.can_breed_resource_on_tile("buffalo", _tile("swamp", "none")),
            "буйволы не должны автоматически разводиться на болоте без тростника", state)
    check(not map_helpers.can_breed_resource_on_tile("freshwater_fish", _tile("lake", "none")),
            "рыба с breedable=false не должна разводиться даже в подходящем водном биоме", state)

    # Проверяем строгую обработку повреждённых/неизвестных условий.
    var invalid_id := "__test_invalid_breeding_resource"
    var valid_data := {
        "id": invalid_id,
        "breedable": true,
        "improved_by": "pasture",
        "allowed_terrain": [],
        "allowed_cover": [],
        "breeding": [ [ { "terrain": "mountain" } ] ]
    }
    gdata.raw_resources[invalid_id] = valid_data
    check(map_helpers.can_breed_resource_on_tile(invalid_id, _tile("mountain", "forest")),
            "условие только по terrain должно работать", state)
    check(not map_helpers.can_breed_resource_on_tile(invalid_id, _tile("plain", "none")),
            "пустое базовое место не должно случайно разрешаться", state)

    var array_data := valid_data.duplicate(true)
    array_data["breeding"] = [ [ { "terrain": [ "mountain", "hill" ] },
                                 { "cover": [ "forest", "none" ] } ] ]
    gdata.raw_resources[invalid_id] = array_data
    check(map_helpers.can_breed_resource_on_tile(invalid_id, _tile("mountain", "forest")),
            "массивы terrain и cover должны поддерживаться одновременно", state)
    check(map_helpers.can_breed_resource_on_tile(invalid_id, _tile("hill", "none")),
            "второй вариант массивов terrain и cover должен совпадать", state)

    var invalid_type := valid_data.duplicate(true)
    invalid_type["breeding"] = [ [ { "terrain": 123 } ] ]
    gdata.raw_resources[invalid_id] = invalid_type
    check(not map_helpers.can_breed_resource_on_tile(invalid_id, _tile("mountain", "none")),
            "числовое значение условия breeding не должно совпадать", state)

    var invalid_empty := valid_data.duplicate(true)
    invalid_empty["breeding"] = [ [] ]
    gdata.raw_resources[invalid_id] = invalid_empty
    check(not map_helpers.can_breed_resource_on_tile(invalid_id, _tile("mountain", "none")),
            "пустая группа breeding не должна разрешать разведение", state)

    var invalid_unknown := valid_data.duplicate(true)
    invalid_unknown["breeding"] = [ [ { "unknown": "value" } ] ]
    gdata.raw_resources[invalid_id] = invalid_unknown
    check(not map_helpers.can_breed_resource_on_tile(invalid_id, _tile("mountain", "none")),
            "неизвестный ключ breeding не должен разрешать разведение", state)
    gdata.raw_resources.erase(invalid_id)

func _test_buildable_improvement(map_helpers, city, state: Dictionary) -> void:
    var old_domesticated: Array = city.domesticated_resources.duplicate()
    var old_unlocked: Array = city.unlocked_technologies.duplicate()
    city.domesticated_resources = ["grapes_plant"]
    city.unlocked_technologies.append("winegrowing")

    var oasis_tile := _tile("sandy_desert", "oasis")
    var plain_tile := _tile("plain", "none")
    var wrong_tile := _tile("sandy_desert", "none")
    check(map_helpers.get_buildable_improvement(oasis_tile) == "vineyard",
            "на оазисе должен предлагаться виноградник для разведения винограда", state)
    check(map_helpers.get_buildable_improvement(plain_tile) == "vineyard",
            "на равнине должно сохраняться обычное предложение виноградника", state)
    check(map_helpers.get_buildable_improvement(wrong_tile) == "",
            "на неподходящем биоме не должно предлагаться улучшение", state)

    city.domesticated_resources = old_domesticated
    city.unlocked_technologies = old_unlocked

func _tile(terrain: String, cover: String) -> Dictionary:
    return {
        "terrain": terrain,
        "cover": cover,
        "resource": null,
        "crop_bred": null,
        "improvement": null
    }

func check(condition: bool, message: String, state: Dictionary) -> void:
    if not condition:
        push_error("ASSERT: " + message)
        print("ASSERT FAILED: ", message)
        state["failed"] = true

func _test_animal_locations(map_helpers, state: Dictionary) -> void:
    # Горы — дополнительное место для овец и коз.
    check(map_helpers.can_breed_resource_on_tile("sheep", _tile("mountain", "none")),
            "овцы должны разводиться в горах", state)
    check(map_helpers.can_breed_resource_on_tile("goats", _tile("mountain", "forest")),
            "козы должны разводиться в горах", state)

    # Оазисы — дополнительные места для овец, коз и пчёл.
    check(map_helpers.can_breed_resource_on_tile("sheep", _tile("sandy_desert", "oasis")),
            "овцы должны разводиться в оазисе", state)
    check(map_helpers.can_breed_resource_on_tile("goats", _tile("rocky_desert", "oasis")),
            "козы должны разводиться в оазисе", state)
    check(map_helpers.can_breed_resource_on_tile("bee", _tile("sandy_desert", "oasis")),
            "пчёлы должны разводиться в оазисе", state)

    # Пустынная и болотная дополнительные группы.
    check(map_helpers.can_breed_resource_on_tile("ostrich", _tile("sandy_desert", "none")),
            "страусы должны разводиться на песчаной пустыне", state)
    check(map_helpers.can_breed_resource_on_tile("buffalo", _tile("swamp", "reeds")),
            "буйволы должны разводиться в болоте с тростником", state)
    check(map_helpers.can_breed_resource_on_tile("duck", _tile("marsh", "reeds")),
            "утки должны разводиться на марше с тростником", state)
    check(map_helpers.can_breed_resource_on_tile("goose", _tile("swamp", "reeds")),
            "гуси должны разводиться в болоте с тростником", state)
    check(map_helpers.can_breed_resource_on_tile("goose", _tile("swamp", "none")),
            "массив cover должен разрешать гусям болото без тростника", state)
    check(map_helpers.can_breed_resource_on_tile("goose", _tile("marsh", "none")),
            "массив cover должен разрешать гусям марш без тростника", state)

