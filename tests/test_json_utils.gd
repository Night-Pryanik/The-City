# Headless test of the comment stripper (scripts/json_utils.gd):
#   godot --headless --path . --script res://tests/test_json_utils.gd
#
# Every data file of the game goes through it, so it must be exact about what a comment
# is: "//" inside a string is text, an escaped quote does not end the literal, and the
# cleaned text keeps the line breaks of the file (the validator reports the line the
# author sees in the editor).
#
# Covers:
#   1. Text without comments is returned unchanged.
#   2. "//" and "/* */" are removed, their line breaks are kept.
#   3. A comment marker inside a string literal is text, not a comment.
#   4. An escaped quote does not end the literal.
#   5. An unterminated block comment, and a comment at the very end of the file.
#   6. Every file of res://data: the cleaned text has as many lines as the original,
#      and it parses.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const JsonUtils = preload("res://scripts/json_utils.gd")

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}

    _test_plain(state)
    _test_comments(state)
    _test_strings(state)
    _test_escapes(state)
    _test_broken(state)
    _test_data_files(state)

    if state["failed"]:
        print("JSON UTILS TEST FAILED")
        quit(1)
    else:
        print("JSON UTILS TEST OK")
        quit(0)

# --- 1. Nothing to strip -----------------------------------------------------------

func _test_plain(state: Dictionary) -> void:
    var text := '{\n  "a": 1,\n  "b": [1, 2, 3]\n}'
    check(JsonUtils.strip_comments(text) == text, "a text without comments is untouched", state)
    var parsed = JsonUtils.parse(text)
    check(parsed is Dictionary and int(parsed["a"]) == 1, "a text without comments parses", state)

# --- 2. The two comment kinds ------------------------------------------------------

func _test_comments(state: Dictionary) -> void:
    var text := '{\n  "a": 1, // the first\n  "b": /* inline */ 2\n}'
    var stripped: String = JsonUtils.strip_comments(text)
    check(not stripped.contains("the first"), "a line comment is removed", state)
    check(not stripped.contains("inline"), "a block comment is removed", state)
    check(stripped.count("\n") == text.count("\n"), "the line breaks survive the stripping", state)

    var parsed = JsonUtils.parse(text)
    check(parsed is Dictionary, "the text parses after stripping", state)
    if parsed is Dictionary:
        check(int(parsed["a"]) == 1 and int(parsed["b"]) == 2, "the values survive the stripping", state)

    # A block comment that covers several lines keeps its breaks.
    var multi := '{\n/* one\n   two\n   three */\n  "a": 1\n}'
    var stripped_multi: String = JsonUtils.strip_comments(multi)
    check(stripped_multi.count("\n") == multi.count("\n"),
            "a multi-line comment keeps every line break", state)
    check(not stripped_multi.contains("two"), "a multi-line comment is removed", state)

# --- 3. A comment marker inside a string -------------------------------------------

func _test_strings(state: Dictionary) -> void:
    var text := '{\n  "url": "http://example.com/a",\n  "path": "a /* b */ c"\n}'
    var stripped: String = JsonUtils.strip_comments(text)
    check(stripped.contains("http://example.com/a"), "a // inside a string is text", state)
    check(stripped.contains("a /* b */ c"), "a /* inside a string is text", state)
    var parsed = JsonUtils.parse(text)
    check(parsed is Dictionary and str(parsed["url"]) == "http://example.com/a",
            "a string with // parses unchanged", state)

# --- 4. An escaped quote -----------------------------------------------------------

func _test_escapes(state: Dictionary) -> void:
    var text := '{\n  "q": "a \\" // b", // gone\n  "n": 1\n}'
    var parsed = JsonUtils.parse(text)
    check(parsed is Dictionary, "a string with an escaped quote parses", state)
    if parsed is Dictionary:
        check(str(parsed["q"]) == 'a " // b', "the escaped quote does not end the string", state)
        check(int(parsed["n"]) == 1, "the comment after an escaped quote is removed", state)

# --- 5. Broken input ---------------------------------------------------------------

func _test_broken(state: Dictionary) -> void:
    # An unterminated block comment swallows the rest: the file is broken, and the parse
    # reports it instead of the stripper inventing data.
    var text := '{"a": 1}\n/* never closed\n"b": 2'
    var stripped: String = JsonUtils.strip_comments(text)
    check(not stripped.contains("never closed"), "an unterminated comment is dropped", state)
    check(JsonUtils.parse(text) is Dictionary, "what is left of a broken file still parses", state)

    # A comment at the very end of the file, without a trailing break.
    var tail := '{"a": 1} // end'
    check(JsonUtils.parse(tail) is Dictionary, "a comment at the end of the file is removed", state)

# --- 6. The real data --------------------------------------------------------------

func _test_data_files(state: Dictionary) -> void:
    var files: Array = []
    _collect("res://data", files)
    check(files.size() > 0, "the data folder is found", state)

    var broken: Array = []
    var shifted: Array = []
    for path in files:
        var text := FileAccess.get_file_as_string(str(path))
        var stripped: String = JsonUtils.strip_comments(text)
        if stripped.count("\n") != text.count("\n"):
            shifted.append(path)
        if JsonUtils.parse(text) == null:
            broken.append(path)
    check(broken.is_empty(), "every data file parses (%s)" % str(broken), state)
    check(shifted.is_empty(), "no data file loses a line (%s)" % str(shifted), state)

func _collect(path: String, out: Array) -> void:
    var dir := DirAccess.open(path)
    if dir == null:
        return
    for name in dir.get_directories():
        _collect(path.path_join(name), out)
    for name in dir.get_files():
        if name.ends_with(".json"):
            out.append(path.path_join(name))

func check(cond: bool, msg: String, state: Dictionary) -> void:
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
