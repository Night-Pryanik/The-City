# journal.gd
#
# The journal of the important messages: every message the HUD shows as
# GameData.HUD_MESSAGE_IMPORTANT is copied here, stays in the list until the player
# deletes it, and stays marked "unread" until the player reads it.
#
# WHY THE HISTORY IS A NODE OF ITS OWN. The HUD (hud_message.gd) only shows a message
# for a few seconds and keeps no history; the window (journal_ui.gd) only draws. The
# entries belong to neither of them: this node is their single owner, and both sides
# work through it — the HUD pushes, the window reads and marks, the save writes out.
# Without one owner the window and the dot on the HUD button could disagree about
# what is unread.
#
# The entries are stored NEWEST FIRST. The window draws them in the order they lie
# here, so the message that has just arrived is on top and the unread ones — which are
# what the player opens the journal for — are the first thing in sight.
#
# The text is kept exactly as the HUD showed it: already translated and with the
# numbers substituted. The journal is a record of what the game told the player, not a
# template to be re-rendered later.
extends Node

## The list changed: an entry was added, read, deleted, or the whole list was cleared.
signal changed

# The cap of the history. The list only grows and the save file is rewritten whole,
# so it has to be bounded. On overflow the OLDEST entry is dropped, read or not: the
# journal is a record of the recent events, not an archive.
const MAX_ENTRIES := 200

# Newest first. A record: {"id": int, "text": String, "unread": bool}.
var entries: Array = []

# The id of the next entry. Ids are not reused within a game: the window addresses an
# entry by its id, and after a deletion the rows that are still on screen must keep
# acting on their own entries and not on their neighbours.
var _next_id: int = 1


func add_message(text: String) -> void:
    if text.strip_edges().is_empty():
        return
    entries.push_front({"id": _next_id, "text": text, "unread": true})
    _next_id += 1
    while entries.size() > MAX_ENTRIES:
        entries.pop_back()
    changed.emit()


func unread_count() -> int:
    var count := 0
    for entry in entries:
        if bool(entry["unread"]):
            count += 1
    return count


func is_unread(id: int) -> bool:
    var index := index_of(id)
    return index >= 0 and bool(entries[index]["unread"])


func index_of(id: int) -> int:
    for i in entries.size():
        if int(entries[i]["id"]) == id:
            return i
    return -1


# Returns true if the entry was unread and has become read.
func mark_read(id: int) -> bool:
    var index := index_of(id)
    if index < 0 or not bool(entries[index]["unread"]):
        return false
    entries[index]["unread"] = false
    changed.emit()
    return true


# Returns true if there was at least one unread entry.
func mark_all_read() -> bool:
    var touched := false
    for entry in entries:
        if bool(entry["unread"]):
            entry["unread"] = false
            touched = true
    if touched:
        changed.emit()
    return touched


func remove(id: int) -> bool:
    var index := index_of(id)
    if index < 0:
        return false
    entries.remove_at(index)
    changed.emit()
    return true


func clear() -> bool:
    if entries.is_empty():
        return false
    entries.clear()
    changed.emit()
    return true


# The list for the save file: plain dictionaries of JSON-safe values only.
func serialize() -> Array:
    var out: Array = []
    for entry in entries:
        out.append({
            "id": int(entry["id"]),
            "text": str(entry["text"]),
            "unread": bool(entry["unread"]),
        })
    return out


# The entries from the save file. JSON hands the numbers back as floats, therefore
# every field is coerced; a record without a usable id or text is skipped rather than
# restored as a broken row. The counter is moved past the restored ids, so a message
# that arrives after the load can never take the id of an entry that is already here.
func restore(data: Variant) -> void:
    entries.clear()
    var highest := 0
    if data is Array:
        for raw in data:
            if not (raw is Dictionary):
                continue
            var id := int(raw.get("id", 0))
            var text := str(raw.get("text", ""))
            if id <= 0 or text.strip_edges().is_empty():
                continue
            entries.append({
                "id": id,
                "text": text,
                "unread": bool(raw.get("unread", true)),
            })
            highest = maxi(highest, id)
    while entries.size() > MAX_ENTRIES:
        entries.pop_back()
    _next_id = highest + 1
    changed.emit()
