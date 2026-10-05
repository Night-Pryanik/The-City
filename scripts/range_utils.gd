# range_utils.gd
# Utilities for parsing values of the "a number or a range [min, max]" format
# from the configuration JSON (map_config.json, resources, etc.).
# A purely utility module: static functions, without any state of its own.
#
# Public API:
#   - parse_range(value) : Dictionary — { "ok": bool, "min": int, "max": int }
#
# Used by:
#   - scripts/map_generator.gd (_resolve_spawn_count — the spawn_count field of resources)
#   - scripts/sea_manager.gd   (apply_sea — the sea.sides field from map_config.json)
@tool
class_name RangeUtils


# Parses a value in the "a number" or "an array [min, max]" format.
#
# Acceptable input data:
#   * a number (int/float)        -> ok=true, min=max=the number;
#   * an array of exactly 2 numbers -> ok=true, min/max from the array;
#                                    if max < min — they are forcibly swapped;
#   anything else                 -> ok=false (the calling code decides which
#                                    safe default to use).
#
# Returns a dictionary:
#   { "ok": bool, "min": int, "max": int }
static func parse_range(value: Variant) -> Dictionary:
    var result := {"ok": false, "min": 0, "max": 0}
    if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
        result["ok"] = true
        result["min"] = int(value)
        result["max"] = int(value)
    elif value is Array and value.size() == 2:
        var first_is_number: bool = typeof(value[0]) == TYPE_INT or typeof(value[0]) == TYPE_FLOAT
        var second_is_number: bool = typeof(value[1]) == TYPE_INT or typeof(value[1]) == TYPE_FLOAT
        if first_is_number and second_is_number:
            result["ok"] = true
            result["min"] = int(value[0])
            result["max"] = int(value[1])
            if result["max"] < result["min"]:
                # The range is given in reverse order — we swap them.
                var tmp: int = result["min"]
                result["min"] = result["max"]
                result["max"] = tmp
    return result

# Returns a random integer for a value of the "a number or [min, max]" format:
#   * a number N           -> N;
#   * an array [min, max]  -> randi_range(min, max);
#   * invalid data (not a number / not an array of 2 numbers, negative
#     values) -> a warning to the console and default_value.
#
# Used for the `spawn_count` resource fields (how many specimens to spawn
# on the map) and `produces` (how much output a one-off resource gives when
# gathered) — see scripts/map_generator.gd and scripts/main_map.gd (the
# action_type "forage" branch).
static func roll_value(value: Variant, context_name: String = "value", default_value: int = 1) -> int:
    var parsed: Dictionary = parse_range(value)
    if not parsed.ok or parsed.min < 0 or parsed.max < 0:
        print("RangeUtils.roll_value: an invalid value for %s "
                + "(a number >= 0 or an array [min, max] of numbers >= 0 is expected, "
                + "using %d." % [context_name, default_value])
        return default_value
    return randi_range(parsed.min, parsed.max)

# Returns the minimum bound of a value of the "a number or [min, max]" format.
# It is needed for deterministic calculations and display (tooltips, previews),
# where it is not allowed to roll a random number every frame. With invalid data
# it returns default_value.
static func get_min_value(value: Variant, default_value: int = 1) -> int:
    var parsed: Dictionary = parse_range(value)
    if not parsed.ok or parsed.min < 0:
        return default_value
    return parsed.min
