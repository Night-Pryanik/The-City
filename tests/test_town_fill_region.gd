# Headless test: the fill of town rings covers the ring ENTIRELY.
#   godot --headless --path . --script res://tests/test_town_fill_region.gd
#
# Regression test for a defect that made the fill look "drawn halfway"
# (especially at the left border of the Region): town rings were clipped by the START
# Region during generation, and as the Region grew (era change) the fill was forever
# left as a stub — only the part of the ring that fell into the new
# Region was drawn (measured loss — up to 18% of the fill hexes).
#
# Checked on live data of the real MainMap scene (new game):
#   1. In the data the ring equals the ring by radius from which exactly
#      two things are cut: the player's start area (Ring + Region of the 1st era —
#      town territory never extends there under ANY circumstances) and
#      hexes occupied by an earlier town. The in_town_influence flag is set
#      exactly on the hexes of rings and NEVER — on the hexes of the start area.
#   2. In the 1st era there is no fill at all — rings do not reveal another town.
#   3. After the era change the fill equals "ring minus fog": there is no loss.
#   4. A fill hex does not lie in the fog, and its full bbox is inside the fill
#      texture (the texture cannot cut a hex in half).
#   5. Scouting a fogged ring hex reveals its fill: the render cache is rebuilt by
#      _complete_scouting itself, otherwise the scouting would have no effect.
extends SceneTree

# Hang watchdog: without it a broken _run() coroutine looks from outside like eternal
# silence. Details are in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    get_root().get_node("SaveManager").new_game()
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    var tm = main_map.town_manager
    var r = main_map.map_renderer

    # --- 1: rings in the data = ring by radius minus what is cut ---
    # There are exactly two permissible differences from the "ring by radius":
    #   a) cutting of the player's start area (Ring + Region of the 1st era):
    #      town territory never extends onto it;
    #   b) inter-town clipping "first come, first served": a hex already
    #      occupied by an earlier town is thrown out of the ring.
    # Any other discrepancy is a defect.
    var ring_keys: Dictionary = {}
    var claimed: Dictionary = {}
    var player_area := _player_start_keys(main_map)
    for t in main_map.towns:
        var expected := _key_set(_full_ring(main_map, tm, t))
        for k in player_area.keys():
            expected.erase(k)
        for k in expected.keys():
            if claimed.has(k):
                expected.erase(k)
        var stored := _key_set(t.get("influence_hexes", []))
        check(expected == stored,
            "the ring of town (%d,%d) must match the ring by radius minus the player's start area minus the hexes occupied by neighbours; missing in data: %s, extra: %s"
                % [int(t.row), int(t.col), str(_keys_only_in(expected, stored)),
                    str(_keys_only_in(stored, expected))], state)
        for k in stored.keys():
            ring_keys[k] = true
            claimed[k] = true
    var stray: Array = []
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var tile = main_map.tile_data[row][col]
            if tile != null and bool(tile.get("in_town_influence", false)) \
                    and not ring_keys.has("%d,%d" % [row, col]):
                stray.append([row, col])
    check(stray.is_empty(),
        "the in_town_influence flag is set only on the hexes of rings (extra: %s)" % str(stray), state)

    # The hexes of the player's start area are his own: neither the ring flag nor
    # town improvements should be on them (otherwise a resource in the Ring of Influence
    # becomes unavailable: build_manager blocks by in_town_influence).
    check(not player_area.is_empty(),
        "on a live map the player's start area must be non-empty", state)
    var intruders: Array = []
    for k in player_area.keys():
        var parts: PackedStringArray = k.split(",")
        var tile = main_map.tile_data[int(parts[0])][int(parts[1])]
        if tile == null:
            continue
        if bool(tile.get("in_town_influence", false)) \
                or bool(tile.get("has_town", false)) \
                or bool(tile.get("decorative", false)):
            intruders.append([int(parts[0]), int(parts[1])])
    check(intruders.is_empty(),
        "there must be no towns and their territories on the player's start area (violators: %s)"
            % str(intruders), state)

    # --- 2: in the 1st era there is no fill ---
    r.invalidate_town_influence_cache()
    _rebuild(r)
    check(r.get_town_fill_hexes().is_empty(),
        "in the 1st era rings must not be drawn (otherwise another town is visible), hexes: %d"
            % r.get_town_fill_hexes().size(), state)

    # --- 3: after the era change the fill = ring minus fog, there is no loss ---
    var before := _key_set(r.get_town_fill_hexes())
    main_map.advance_to_next_era()
    await process_frame
    _rebuild(r)
    var after := _key_set(r.get_town_fill_hexes())
    var should_be: Dictionary = {}
    for t in main_map.towns:
        for h in _full_ring(main_map, tm, t):
            if main_map.start_region_start_row <= int(h.row) \
                    and int(h.row) <= main_map.start_region_end_row \
                    and main_map.start_region_start_col <= int(h.col) \
                    and int(h.col) <= main_map.start_region_end_col:
                continue
            if not main_map.is_hex_in_fog(int(h.row), int(h.col)):
                should_be["%d,%d" % [int(h.row), int(h.col)]] = true
    check(not should_be.is_empty(),
        "after the era change the fill must appear (checked on a live map)", state)
    check(_keys_only_in(should_be, after).is_empty(),
        "after the era change part of the fill is lost (not drawn: %s)"
            % str(_keys_only_in(should_be, after)), state)
    check(_keys_only_in(after, should_be).is_empty(),
        "after the era change extra fill is drawn (extra: %s)"
            % str(_keys_only_in(after, should_be)), state)
    check(after.size() >= before.size(),
        "the fill must not lose hexes on an era change (was %d, now %d)"
            % [before.size(), after.size()], state)

    # --- 3b: the outlines of the rings are built for the visible fill ---
    check(not r.get_town_border_hexes().is_empty(),
        "after the era change the outlines of the rings must be built", state)

    # --- 4: the fill fits entirely into the texture (its edge does not cut it) ---
    # The fill may extend beyond the Region — onto scouted hexes beyond it
    # (that is how scouting works), — so we check not the Region but the coverage
    # by the texture: it was its edge that gave the "half fill".
    var fog_left: Array = []
    for h in r.get_town_fill_hexes():
        if main_map.is_hex_in_fog(int(h.row), int(h.col)):
            fog_left.append([int(h.row), int(h.col)])
    check(fog_left.is_empty(),
        "fill hexes must not lie in the fog of war (violators: %s)" % str(fog_left), state)
    check(r._influence_fill_texture != null,
        "the fill texture must be built (otherwise a fallback is drawn)", state)
    if r._influence_fill_texture != null:
        _check_texture_covers_hexes(main_map, r, state)

    # --- 5: scouting a fogged ring hex reveals its fill and rebuilds the cache ---
    var fog_ring: Array = []
    for row in range(main_map.map_rows):
        for col in range(main_map.map_cols):
            var t = main_map.tile_data[row][col]
            if t != null and main_map.is_hex_in_fog(row, col) \
                    and bool(t.get("in_town_influence", false)):
                fog_ring.append({"row": row, "col": col})
    check(not fog_ring.is_empty(),
        "the live map must contain at least one town ring hex in the fog", state)
    if not fog_ring.is_empty():
        var h: Dictionary = fog_ring[0]
        # Scouting the normal way: a chunk of one hex. The fill cache must rebuild
        # BY ITSELF (see invalidate_town_influence_cache in _complete_scouting) — the
        # test does not touch it, otherwise it would prove nothing about the wiring.
        main_map.scouting_chunk = [h]
        main_map.is_scouting = true
        main_map._complete_scouting()
        _rebuild(r)
        check(not main_map.is_hex_in_fog(int(h.row), int(h.col)),
            "a scouted hex cannot be in the fog of war", state)
        check(_is_filled(r, int(h.row), int(h.col)),
            "after scouting the town fill must appear on the hex (%d,%d)"
                % [int(h.row), int(h.col)], state)

    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()
    if state["failed"]:
        print("TOWN FILL REGION TEST FAILED")
        quit(1)
    else:
        print("TOWN FILL REGION TEST OK")
        quit(0)

# A town ring by its radius — the reference "how it should be" (town_manager
# builds rings exactly like this; cutting of the start area and clipping by neighbours are done
# when parsing the result, not inside compute_town_influence).
func _full_ring(main_map, tm, t) -> Array:
    return tm.compute_town_influence(
            main_map.tile_data, main_map.map_rows, main_map.map_cols,
            int(t.row), int(t.col), t,
            int(t.get("influence_radius", 3)))

# The set of "row,col" keys of the player's start area (Ring + Region of the 1st
# era). Town territory is always cut from it — this is the invariant
# that the test checks.
func _player_start_keys(main_map) -> Dictionary:
    var out: Dictionary = {}
    for row in range(main_map.start_region_start_row, main_map.start_region_end_row + 1):
        for col in range(main_map.start_region_start_col, main_map.start_region_end_col + 1):
            if row < 0 or row >= main_map.map_rows or col < 0 or col >= main_map.map_cols:
                continue
            out["%d,%d" % [row, col]] = true
    return out

# The texture must cover a fill hex ENTIRELY: a hex cut by its edge
# — that is the "half fill". We check that the texture contains the exact
# bounding box of the hex (radius vertically, 0.866 of the radius horizontally) with a tolerance
# of 0.01 px for float error. The 1 px margin that _build_town_fill_texture
# gives beyond the bounding box, for smoothing the joints, is not part of the tolerance: it is not
# mandatory. A real cut is tens of pixels.
func _check_texture_covers_hexes(main_map, r, state: Dictionary) -> void:
    var radius: float = main_map.HEX_RADIUS
    var half_w: float = radius * sqrt(3.0) * 0.5
    var tol := 0.01
    var cut: Array = []
    for h in r.get_town_fill_hexes():
        var c: Vector2 = HexUtils.hex_center(int(h.row), int(h.col), radius)
        if c.x - half_w - tol < r._influence_texture_origin.x \
                or c.x + half_w + tol > r._influence_texture_origin.x + r._influence_texture_size.x \
                or c.y - radius - tol < r._influence_texture_origin.y \
                or c.y + radius + tol > r._influence_texture_origin.y + r._influence_texture_size.y:
            cut.append([int(h.row), int(h.col)])
    check(cut.is_empty(),
        "the fill texture must not cut a hex in half (cut: %s)" % str(cut), state)

# Forcefully rebuilds the render cache (as the draw frame does).
func _rebuild(r) -> void:
    r._ensure_town_influence_cache(r._get_draw_hex_range())

func _is_filled(r, row: int, col: int) -> bool:
    for h in r.get_town_fill_hexes():
        if int(h.row) == row and int(h.col) == col:
            return true
    return false

func _key_set(hexes: Array) -> Dictionary:
    var out: Dictionary = {}
    for h in hexes:
        out["%d,%d" % [int(h.row), int(h.col)]] = true
    return out

# Keys that exist only in a.
func _keys_only_in(a: Dictionary, b: Dictionary) -> Array:
    var out: Array = []
    for k in a.keys():
        if not b.has(k):
            out.append(k)
    return out

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
