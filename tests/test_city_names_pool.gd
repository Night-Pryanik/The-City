# Headless test of the per-language pool of city names:
#   godot --headless --path . --script res://tests/test_city_names_pool.gd
#
# A city name is a name and not a translatable string, so every language owns a list of
# its own — locale/city_names_<code>.json — and the loader takes a single one of them by
# the game language. The lists are position-aligned: the i-th Latin name is the
# counterpart of the i-th Cyrillic one, and that is what lets a reviewer compare the two
# files line by line.
#
# Covers:
#   1. Every language of the game has a file, and it parses into a list of non-empty
#      names without duplicates inside.
#   2. The lists of the languages are of the same size, and the English one is plain
#      Latin — the alignment the data files promise.
#   3. The pool follows the game language; a language with no file of its own takes the
#      source one.
#   4. The pool is not in data/: the folder scan of the whole game contributes no second
#      copy of the names.
#   5. A mod's city_names array is appended to the pool of the current language.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const JsonUtils = preload("res://scripts/json_utils.gd")

const POOL_FOLDER := "res://locale"
const SOURCE_LOCALE := "en"
const UNKNOWN_LOCALE := "de"
const MOD_DIR := "user://test_city_names_pool"
const MOD_NAMES := ["Pellucid", "Vesper"]

func _initialize():
    WATCHDOG.arm(self)
    _run()


func _run() -> void:
    var state = {"failed": false}
    var localization = get_root().get_node("LocalizationManager")

    var pools := {}
    for lang in localization.LANGUAGES:
        var code := str(lang["code"])
        pools[code] = _read_pool_file(code)

    _test_files(state, pools)
    _test_alignment(state, pools)
    _test_loading(state, pools)
    _test_mod_names(state, pools)

    if state["failed"]:
        print("CITY NAMES POOL TEST FAILED")
        quit(1)
    else:
        print("CITY NAMES POOL TEST OK")
        quit(0)


# --- 1. The files themselves --------------------------------------------------------

func _test_files(state: Dictionary, pools: Dictionary) -> void:
    for code in pools:
        var names: Array = pools[code]
        check(not names.is_empty(), "the pool of \"%s\" is not empty" % code, state)
        check(names.size() == _count_distinct(names),
                "the pool of \"%s\" has no duplicate" % code, state)
        for name in names:
            if not (name is String) or str(name).strip_edges() == "":
                check(false, "the pool of \"%s\" holds only names" % code, state)
                break


# --- 2. Position alignment of the languages ------------------------------------------

func _test_alignment(state: Dictionary, pools: Dictionary) -> void:
    var sizes := {}
    for code in pools:
        sizes[code] = pools[code].size()
    var reference: int = sizes.get(SOURCE_LOCALE, -1)
    check(reference > 0, "the source pool is read", state)
    for code in sizes:
        check(sizes[code] == reference,
                "the pool of \"%s\" is aligned with the source one (%d vs %d)" % [code, sizes[code], reference],
                state)
    for name in pools.get(SOURCE_LOCALE, []):
        if not _is_latin(str(name)):
            check(false, "the source pool is written in Latin letters: \"%s\"" % name, state)
            break


# --- 3. The pool of the running language ----------------------------------------------

func _test_loading(state: Dictionary, pools: Dictionary) -> void:
    check(not FileAccess.file_exists("res://data/city_names.json"),
            "the pool is not a data/ file, so the folder scan cannot double it", state)
    for code in pools:
        var loaded := _pool_of_loaded_game(code)
        check(loaded == pools[code],
                "the game under \"%s\" names its cities from that language's file" % code, state)

    var fallback := _pool_of_loaded_game(UNKNOWN_LOCALE)
    check(fallback == pools.get(SOURCE_LOCALE, []),
            "a language with no pool of its own takes the source one", state)

    var game_data = get_root().get_node("GameData")
    TranslationServer.set_locale(SOURCE_LOCALE)
    game_data.load_all_data()
    check(game_data.city_names.has(game_data.get_random_city_name()),
            "a generated name comes from the pool of the current language", state)


# --- 4. The names a mod adds ----------------------------------------------------------

func _test_mod_names(state: Dictionary, pools: Dictionary) -> void:
    DirAccess.remove_absolute(MOD_DIR)
    var data_dir := MOD_DIR.path_join("data")
    DirAccess.make_dir_recursive_absolute(data_dir)
    var file := FileAccess.open(data_dir.path_join("city_names.json"), FileAccess.WRITE)
    check(file != null, "the data folder of the test mod is writable", state)
    if file == null:
        return
    file.store_string(JSON.stringify({"city_names": MOD_NAMES}))
    file.close()

    var loaded := _pool_of_loaded_game(SOURCE_LOCALE, [MOD_DIR])
    var vanilla: Array = pools.get(SOURCE_LOCALE, [])
    check(loaded.size() == vanilla.size() + MOD_NAMES.size(),
            "the names of a mod are added to the pool (%d over %d)" % [loaded.size(), vanilla.size()],
            state)
    var tail: Array = loaded.slice(loaded.size() - MOD_NAMES.size()) if loaded.size() >= MOD_NAMES.size() else []
    check(tail == MOD_NAMES, "the names of a mod stand at the end of the pool", state)

    DirAccess.remove_absolute(MOD_DIR)


# --- helpers --------------------------------------------------------------------------

# The pool a game reads with the given language and mods: exactly the path the game data
# takes, without the autoload state in between.
func _pool_of_loaded_game(locale: String, mod_dirs: Array = []) -> Array:
    TranslationServer.set_locale(locale)
    var loader = load("res://scripts/data_loader.gd").new()
    loader.load_all_data(mod_dirs)
    var names: Array = loader.city_names.duplicate()
    loader.free()
    return names

func _read_pool_file(code: String) -> Array:
    var path := "%s/city_names_%s.json" % [POOL_FOLDER, code]
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return []
    var data = JsonUtils.parse(file.get_as_text())
    if data is Dictionary and data.get("city_names") is Array:
        return data["city_names"]
    return []

func _count_distinct(names: Array) -> int:
    var seen := {}
    for name in names:
        seen[str(name)] = true
    return seen.size()

# Letters, the apostrophe of a glottal stop and the dash of a fused name: the source pool
# is derived from the Cyrillic one, so no other sign may reach it.
func _is_latin(name: String) -> bool:
    if name.is_empty():
        return false
    for i in name.length():
        var c := name[i]
        if c == "'" or c == "-":
            continue
        var lower := c.to_lower()
        if lower == c.to_upper():
            return false
        if lower < "a" or lower > "z":
            return false
    return true

func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        print("  ok: ", message)
    else:
        print("  FAIL: ", message)
        state["failed"] = true
