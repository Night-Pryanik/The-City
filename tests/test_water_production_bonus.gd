# Headless test of the fresh-water production bonus:
#   godot --headless --path . --script res://tests/test_water_production_bonus.gd
#
# The bonus is data-driven: data/modifiers.json -> fresh_water.production_multiplier
# maps an improvement id to a multiplier. CityData.get_improvement_production_modifiers
# turns that entry into a row for the preview panel and the hex tooltip, and
# get_improvement_production_multiplier multiplies it into the output.
#
# Checks:
#   1. Cultivated plants are irrigated: the farm and the plantation are both in
#      the table. Their multiplier is > 1 and stacks multiplicatively with the
#      other modifiers of the improvement.
#   2. A wet hex shows exactly one "Fresh water access" row, with the multiplier
#      from the data; a dry hex shows none.
#   3. For EVERY improvement in the game the data and the UI rows agree: only
#      the ids listed in the table get the row. Water is irrigation here, so a
#      mine, a quarry, a herd or infrastructure must not receive it.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

const WATER_LABEL := "Fresh water access"

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    # In --script mode the autoload names are unavailable at compile time.
    var gdata = get_root().get_node("GameData")
    var cdata = get_root().get_node("CityData")

    var multipliers: Dictionary = gdata.modifiers.get("fresh_water", {}).get(
            "production_multiplier", {})
    check(not multipliers.is_empty(), "the fresh-water bonus table must not be empty", state)

    # --- 1. Both kinds of cultivated plants are irrigated ---
    for imp_id in ["farm", "plantation"]:
        check(multipliers.has(imp_id),
                "the improvement \"%s\" must receive the irrigation bonus" % imp_id, state)
        if not multipliers.has(imp_id):
            continue
        var expected := float(multipliers[imp_id])
        check(expected > 1.0,
                "the irrigation bonus of \"%s\" must be greater than 1 (got %.2f)"
                        % [imp_id, expected], state)
        var dry: float = cdata.get_improvement_production_multiplier(imp_id, false)
        var wet: float = cdata.get_improvement_production_multiplier(imp_id, true)
        check(is_equal_approx(wet, dry * expected),
                "\"%s\": a wet hex multiplies the output by the data value (%.2f -> %.2f)"
                        % [imp_id, dry, wet], state)

    # --- 2/3. The row in the panel/tooltip matches the data for every improvement ---
    for imp_id in gdata.improvements.keys():
        var wet_rows: Array = cdata.get_improvement_production_modifiers(imp_id, true)
        var dry_rows: Array = cdata.get_improvement_production_modifiers(imp_id, false)
        var wet_water_rows := _water_rows(wet_rows)
        check(_water_rows(dry_rows).is_empty(),
                "\"%s\": a dry hex must not show a fresh-water row" % imp_id, state)
        if multipliers.has(imp_id):
            check(wet_water_rows.size() == 1,
                    "\"%s\": a wet hex must show exactly one fresh-water row (got %d)"
                            % [imp_id, wet_water_rows.size()], state)
            if not wet_water_rows.is_empty():
                check(is_equal_approx(float(wet_water_rows[0].get("multiplier", 0.0)),
                            float(multipliers[imp_id])),
                        "\"%s\": the row must carry the multiplier from the data" % imp_id,
                        state)
        else:
            check(wet_water_rows.is_empty(),
                    "\"%s\": an improvement outside the table must not get irrigation"
                            % imp_id, state)

    if state["failed"]:
        print("WATER PRODUCTION BONUS TEST FAILED")
        quit(1)
    else:
        print("WATER PRODUCTION BONUS TEST OK")
        quit(0)

func _water_rows(rows: Array) -> Array:
    var result: Array = []
    for row in rows:
        if str(row.get("label", "")).contains(WATER_LABEL):
            result.append(row)
    return result

func check(cond: bool, msg: String, state: Dictionary) -> void:
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
