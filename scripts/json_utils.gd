# json_utils.gd
#
# Reading of the project's JSON. The data files (res://data and the data folder of a mod)
# and the mod manifests allow // and /* */ comments, which JSON.parse_string does not
# accept, so the text is cleaned before parsing.
#
# The cleaning keeps the line breaks of the original: a problem in the data is reported
# by the line the author sees in the editor, and a stripped comment would shift it.
extends RefCounted

static func parse(text: String):
    return JSON.parse_string(strip_comments(text))

static func strip_comments(json_string: String) -> String:
    var result = ""
    var in_string = false
    var in_single_line_comment = false
    var in_multi_line_comment = false
    var i = 0
    while i < json_string.length():
        var c = json_string[i]
        var next_c = json_string[i + 1] if i + 1 < json_string.length() else ""
        var prev_c = json_string[i - 1] if i > 0 else ""

        if not in_string and not in_single_line_comment and not in_multi_line_comment:
            if c == '"':
                in_string = true
                result += c
                i += 1
                continue
            elif c == '/' and next_c == '/':
                in_single_line_comment = true
                i += 2
                continue
            elif c == '/' and next_c == '*':
                in_multi_line_comment = true
                i += 2
                continue

        if in_string:
            if c == '"' and prev_c != '\\':
                in_string = false
            result += c
            i += 1
            continue

        if in_single_line_comment:
            if c == '\n':
                in_single_line_comment = false
                result += c # we keep the line break
            i += 1
            continue

        if in_multi_line_comment:
            if c == '*' and next_c == '/':
                in_multi_line_comment = false
                i += 2
                continue
            i += 1
            continue

        result += c
        i += 1

    return result
