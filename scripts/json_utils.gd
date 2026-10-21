# json_utils.gd
#
# Reading of the project's JSON. The data files (res://data and the data folder of a mod)
# and the mod manifests allow // and /* */ comments, which JSON.parse_string does not
# accept, so the text is cleaned before parsing.
#
# The cleaning keeps the line breaks of the original: a problem in the data is reported
# by the line the author sees in the editor, and a stripped comment would shift it.
#
# The scan jumps from one token to the next instead of walking the text character by
# character: the whole data set is cleaned on every load, and a per-character loop in
# GDScript costs hundreds of milliseconds for a quarter of a megabyte.
extends RefCounted

static func parse(text: String):
    return JSON.parse_string(strip_comments(text))

static func strip_comments(json_string: String) -> String:
    var parts := PackedStringArray()
    var length := json_string.length()
    var i := 0
    # The next position of every token kind. A position is searched again only after the
    # scan has passed it, so each character of the text is looked at once per kind.
    var next_quote := json_string.find("\"", 0)
    var next_line := json_string.find("//", 0)
    var next_block := json_string.find("/*", 0)

    while i < length:
        if next_quote != -1 and next_quote < i:
            next_quote = json_string.find("\"", i)
        if next_line != -1 and next_line < i:
            next_line = json_string.find("//", i)
        if next_block != -1 and next_block < i:
            next_block = json_string.find("/*", i)

        var token := length
        var kind := 0
        if next_quote != -1 and next_quote < token:
            token = next_quote
            kind = 1
        if next_line != -1 and next_line < token:
            token = next_line
            kind = 2
        if next_block != -1 and next_block < token:
            token = next_block
            kind = 3

        parts.append(json_string.substr(i, token - i))
        if kind == 0:
            break

        if kind == 1:
            # A string literal is copied as it is: "//" inside it is not a comment.
            var after_string := _string_end(json_string, token)
            parts.append(json_string.substr(token, after_string - token))
            i = after_string
        elif kind == 2:
            var line_end := json_string.find("\n", token)
            if line_end == -1:
                break
            parts.append("\n")
            i = line_end + 1
        else:
            var block_end := json_string.find("*/", token + 2)
            if block_end == -1:
                break
            # A block comment may cover several lines: its breaks are kept so that the
            # cleaned text stays line-for-line with the file.
            var skipped := json_string.substr(token, block_end + 2 - token)
            parts.append("\n".repeat(skipped.count("\n")))
            i = block_end + 2

    return "".join(parts)

# The index just past the closing quote of the literal that starts at `start`. A quote
# is escaped by an odd number of backslashes in front of it.
static func _string_end(text: String, start: int) -> int:
    var i := start + 1
    while i < text.length():
        var quote := text.find("\"", i)
        if quote == -1:
            return text.length()
        var backslashes := 0
        var j := quote - 1
        while j >= 0 and text[j] == "\\":
            backslashes += 1
            j -= 1
        if backslashes % 2 == 0:
            return quote + 1
        i = quote + 1
    return text.length()
