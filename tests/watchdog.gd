# Hang watchdog for the headless tests (tests/*.gd).
#
# A test is a SceneTree script in its own process (`godot --headless
# --path . --script res://tests/<name>.gd`; the command is run FROM THE ROOT
# of the repository: `--path .` means "the current directory", so the result
# does not depend on where exactly the clone is placed).
#
# After a FRESH clone, run `godot --headless --path . --import` once: without
# it there is no .godot/ directory and no .godot/uid_cache.bin cache, so the
# autoloads (GameData/CityData/SaveManager) are not instantiated and
# `get_root().get_node("CityData")` returns null. The test then fails not on
# the substance but with code 2 from the watchdog below, and the message does
# not make it clear that the cause is an unimported project. For a project
# already open in the editor the import has been done and the step is not needed.
#
# A runtime error inside the `_run()` coroutine (for example, a call with an
# argument of the wrong type) BREAKS the coroutine: control never reaches
# `quit()`, the tree keeps running, and from the outside it looks like a silent
# hang — the process lives forever and prints nothing. That is exactly how
# test_detail_tooltip behaved with a call to show_flow_tooltip that was passed a
# Dictionary instead of a String in resource_id.
#
# `arm()` raises a timer for the whole run. If a test does not reach the end
# (a broken coroutine, a forgotten `quit()`, a real hang on `await`), it prints
# the test label and exits with code 2. The timer does not need to be disarmed:
# a successful test calls `quit()` itself, and the timer simply does not get a
# chance to fire. The flip side: a forgotten `quit()` at the end of a test is
# caught too — such a test is "hung" by itself.
#
# It is attached by path rather than through class_name: when launched with
# --script the global class names may not be in the cache yet (the same argument
# as for underlined_label in ui_helpers.gd), and preload is reliable in any mode.
#
# The usual exit from _initialize():
#     const WATCHDOG = preload("res://tests/watchdog.gd")
#     func _initialize() -> void:
#         WATCHDOG.arm(self)
#         _run()
extends RefCounted

# The margin is large: the longest test currently takes ~10 s (map generation),
# and 120 s is roughly a twelvefold margin for a slow machine. A test that needs
# its own limit passes it explicitly: WATCHDOG.arm(self, 30.0).
const DEFAULT_TIMEOUT: float = 120.0

# The timer is raised once per process: a repeated arm() (for example, from
# _initialize and from the first _process) changes nothing.
static var _armed := false

static func arm(tree: SceneTree, timeout: float = DEFAULT_TIMEOUT) -> void:
    if _armed:
        return
    _armed = true
    _pin_source_locale(tree)
    var label := _label(tree)
    tree.create_timer(timeout, true, false, true).timeout.connect(
        func() -> void:
            var msg := "WATCHDOG [%s]: the test did not finish in %.0f s — it hung or broke inside _run()" % [label, timeout]
            push_error(msg)
            print(msg)
            print("WATCHDOG [%s] HUNG" % label)
            tree.quit(2)
    )

# Tests assert the strings of the source language (English), so the language of
# a run must not depend on the machine: with a Russian system locale the game
# would otherwise start in Russian and the assertions would not match.
# Nothing is written to user://settings.cfg — the machine's language setting is
# left alone.
#
# LocalizationManager chooses the language in its own _ready(), which runs on the
# first frame — after _initialize() and after arm(). It picks the machine's system
# language and, because the game data is already loaded by then, re-reads the data
# in that language as well. So the pin happens twice: immediately, for a test that
# reads something before the first frame, and again on the first process_frame,
# where both the locale and the already loaded data are switched to the source
# language once the autoload has done its work.
static func _pin_source_locale(tree: SceneTree) -> void:
    TranslationServer.set_locale("en")
    tree.process_frame.connect(
        func() -> void: _apply_source_locale(tree), CONNECT_ONE_SHOT)

static func _apply_source_locale(tree: SceneTree) -> void:
    TranslationServer.set_locale("en")
    var game_data := tree.root.get_node_or_null("GameData")
    if game_data != null and game_data.data_loaded:
        game_data.load_all_data()

# The label for the message — the test file name without the path and extension.
static func _label(tree: SceneTree) -> String:
    var script := tree.get_script() as Script
    if script == null or script.resource_path == "":
        return "unnamed"
    return script.resource_path.get_file().get_basename()

# --- Selecting individual cases ---------------------------------------------
#
# Running a 25-case test entirely for the sake of one case is the main cost when
# editing a single mechanic. The filter arrives the standard Godot way: after the
# `--` separator the engine does not parse the arguments and hands them to the
# application.
#
#     godot --headless --path . --script res://tests/test_town_economy.gd \
#         -- --case=readiness --case=trade_comfort_from_data
#
# It lives here, and not in each test, for the same reason as the watchdog: it is
# a shared helper that every test already preloads (in --script mode class_name
# may not be in the cache yet, so a preload by path is more reliable).
const CASE_PREFIX := "--case="

static func requested_cases() -> PackedStringArray:
    var wanted := PackedStringArray()
    for arg in OS.get_cmdline_user_args():
        if arg.begins_with(CASE_PREFIX):
            var value := arg.substr(CASE_PREFIX.length()).strip_edges()
            if value != "":
                wanted.append(value)
    return wanted

# Whether to run the case with this name. Without a filter — all.
#
# The comparison is a case-insensitive substring: the case names are long
# (`trade_comfort_from_data`), and there is no need to type them out in full every
# time, while there are no tests in the project where one substring would cover
# two different cases.
static func wants(name: String) -> bool:
    var wanted := requested_cases()
    if wanted.is_empty():
        return true
    for filter in wanted:
        if name.to_lower().contains(filter.to_lower()):
            return true
    return false

# A wrapper over a case call.
#
# Returns false if the case is filtered out, and true if it must be run.
# The caller writes:
#
#     if WATCHDOG.wants_case("readiness"):
#         _test_readiness()
#     if WATCHDOG.wants_case("live_map"):
#         await _test_live_map()
#
# It is exactly "ask first, then call directly", and not "pass the case as a
# closure": a coroutine call through Callable.call() is broken by the engine with
# "Trying to call an async function without await", while `await callable.call()`
# is taken by the engine as an ordinary value (await on a non-signal simply
# unwraps), so the coroutine does not run to the end. A direct call in the body of
# the test is the only form that works both for ordinary cases and for coroutines.
static func wants_case(name: String) -> bool:
    if wants(name):
        return true
    _skipped.append(name)
    return false

static var _skipped := PackedStringArray()

# Printed by the test before the verdict. The skipped cases must be visible:
# otherwise a filtered run is indistinguishable from a full one by the single
# "TEST OK" line.
static func report_skipped() -> void:
    if _skipped.is_empty():
        return
    print("SKIPPED (--case): ", ", ".join(_skipped))
