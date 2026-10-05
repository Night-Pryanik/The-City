class_name MapTooltip

var _tooltip_text_label: RichTextLabel
var _tooltip_products_container: VBoxContainer
var _map_renderer
var _worker_manager
# The key of the last drawn product list of the tooltip (for comparison
# on a periodic update — so as not to rebuild the UI without changes).
var _last_products_key := ""
# The hex for which the extended block (the "Road: …" row, the properties of the hex,
# the production with the modifiers) is already shown; -1 — the block is not shown.
#
# The extended block and the basic tooltip live in the SAME container, and render_products
# cleans it. Therefore any repeated call of update_tooltip_text on the same hex
# (for example, a periodic refresh of the pasture occupancy from InputHandler)
# without this state would erase the row of the road level a second after it
# appeared — and it would not return until the cursor leaves, because the
# extended block is drawn only once per hover.
var _extended_row: int = -1
var _extended_col: int = -1

# The formatting of the rate (pcs/sec, units/sec) lives in the common helpers:
# ConsumptionUi.format_rate — for the rows of the occupational consumption.
# There is no own formatter here any more: it used to live exactly in this
# file, and the new places showing the expense would copy-paste it.

func _init(tooltip_text_label: RichTextLabel, tooltip_products_container: VBoxContainer, map_renderer, worker_manager):
    _tooltip_text_label = tooltip_text_label
    _tooltip_products_container = tooltip_products_container
    _map_renderer = map_renderer
    _worker_manager = worker_manager


# Assembles the rows of the markers of someone else's territory for the tooltip.
# It returns an Array<String> in the order:
#   1) "Territory of a city" — if the hex is a part of the influence ring (in_town_influence);
#   2) "City"                — if there is a town on the hex (has_town).
# Both markers are independent: on the centre hex of the ring there will be BOTH, on the other
# hexes of the ring — only the first one. Each row is already ready for output, without
# a leading separator — the calling code adds \n depending on the context.
# It is used in all the branches of _build_text (a unique terrain / unexplored
# / explored), so that the tooltip is consistent: the blue patch around
# the town is always accompanied by an explanation "this is someone's territory".
func _town_name_for_hex(row: int, col: int) -> String:
    var main_map = _map_renderer.main_map if _map_renderer != null else null
    if main_map == null:
        return ""
    for town in main_map.towns:
        if int(town.get("row", -1)) == row and int(town.get("col", -1)) == col:
            return str(town.get("name", ""))
        for influence_hex in town.get("influence_hexes", []):
            if int(influence_hex.get("row", -1)) == row \
                    and int(influence_hex.get("col", -1)) == col:
                return str(town.get("name", ""))
    return ""


func _territory_lines_for(tile: Dictionary, row: int, col: int) -> Array:
    var lines: Array = []
    # The name of the town is NOT disclosed on an unexplored hex: in the fog of war the player
    # sees only "there is something here" (a semi-transparent icon), and learns the name
    # after the scouting. On the revealed hexes (the Ring or the scouted ones) — as it was.
    var revealed: bool = bool(tile.get("in_influence", false)) \
            or bool(tile.get("is_explored", false))
    var town_name = _town_name_for_hex(row, col) if revealed else ""
    if bool(tile.get("in_town_influence", false)):
        lines.append(tr("Territory of the city %s") % town_name if town_name != "" else tr("City territory"))
    if bool(tile.get("has_town", false)):
        lines.append(tr("City %s") % town_name if town_name != "" else tr("City"))
    return lines


# The road level on the hex (0 — there is no road). It is taken from the NETWORK
# (road_manager), and not from tile["road_level"]: the field on the hex describes only
# the segment by which the hex was connected to the network.
#
# main_map is obtained the same way as in _town_name_for_hex: directly from the renderer,
# and the road network is taken from the public field. A separate parameter "road network" in
# the constructor is not added: it is needed exactly here and in
# has_extended_tooltip_info, and MapTooltip works with the map anyway.
func _hex_road_level(row: int, col: int) -> int:
    var main_map = _map_renderer.main_map if _map_renderer != null else null
    if main_map == null:
        return 0
    var road_manager = main_map.road_manager
    if road_manager == null or not road_manager.has_method("get_hex_road_level"):
        return 0
    return int(road_manager.get_hex_road_level(row, col))

# "Cart road (level 2, up to 30 units/sec per segment)" — the BEST road
# reaching the hex: the level of the hex = the maximum over the adjacent segments
# (road_manager.get_hex_road_level). At a crossroads of two trails and one
# cart road the cart road is shown — just as the hex looks
# on the map.
#
# The wording "up to N units/sec per segment" is important: the BEST road runs along the hex,
# and not every adjacent segment. The average along the route is counted separately
# (the "Route to the city" row), therefore the label must not read as
# "the whole road here brings N".
#
# The level number is not needed for the sake of beauty: the player reads "level 2" in the selection button
# and in the label of the route, and without it it is not clear which button corresponds to
# the row on the hex.
func road_level_line(row: int, col: int) -> String:
    var level := _hex_road_level(row, col)
    if level <= 0:
        return ""
    return tr("%s (level %d, up to %d units/sec per section)") % [
            GameData.get_road_name(level), level,
            GameData.get_road_max_speed(level)]

func _format_resource_label_for_text(res_id: String, res_name: String) -> String:
    if res_id == "" or res_name == "":
        return res_name
    var icon_name = GameData.raw_resources.get(res_id, {}).get("icon", "")
    if icon_name == "":
        return res_name
    if _map_renderer == null:
        return res_name
    var icon_path = IconRegistry.icon_path(icon_name)
    if icon_path == "":
        return res_name
    return "[img=18]%s[/img] %s" % [icon_path, res_name]


# --- The common rendering of the list of products ---
# products — an array of dictionaries:
#   { "type": "header",  "text": String }
#   { "type": "product", "name": String, "amount": int, "icon_path": String }
#   { "type": "label",   "text": String, "color": Color }
# It is used both by the tooltip and by the control panel (control_panel.gd), so that
# the display of the production does not diverge.
# wrap — enables the wrapping of the words to the next line, if the text does not fit
# into a single line (the control panel passes true, the tooltip — no).
func render_products(products: Array, container: Node, wrap: bool = false):
    var wrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap else TextServer.AUTOWRAP_OFF
    for child in container.get_children():
        # free(), and not queue_free(): the immediate removal excludes a frame when
        # the old and the new items hang in the container at the same time — otherwise
        # the height of the list jumped by one frame on every update.
        child.free()
    for item in products:
        var type = item.get("type", "label")
        if type == "header":
            var label = Label.new()
            label.text = item.get("text", "")
            label.autowrap_mode = wrap_mode
            label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
            container.add_child(label)
        elif type == "product":
            var hbox = HBoxContainer.new()
            var icon_path = item.get("icon_path", "")
            if icon_path != "":
                var tex_rect = TextureRect.new()
                tex_rect.texture = load(icon_path)
                tex_rect.custom_minimum_size = Vector2(20, 20)
                tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                tex_rect.stretch_mode = TextureRect.STRETCH_SCALE
                hbox.add_child(tex_rect)
            var label_item = Label.new()
            # If the item has a color set — we use it (for highlighting
            # the consumption, when there is not enough of the resource in the storage). Otherwise —
            # the ordinary white. If amount == 0, we output only the label
            # (it is used for the consumption rows, where the text matters, and not the number).
            # amount can be fractional (the rate "units/sec"); suffix
            # is appended after the number (for example, " units/sec").
            var amount_val = float(item.get("amount", 0))
            if amount_val > 0:
                var amount_str = str(int(amount_val)) if amount_val == floor(amount_val) else "%.1f" % amount_val
                label_item.text = "%s: %s%s" % [item.get("name", ""), amount_str, str(item.get("suffix", ""))]
            else:
                label_item.text = item.get("name", "")
            var item_color: Color = item.get("color", Color.WHITE)
            label_item.add_theme_color_override("font_color", item_color)
            hbox.add_child(label_item)
            container.add_child(hbox)
        else:
            var label = Label.new()
            label.text = item.get("text", "")
            label.autowrap_mode = wrap_mode
            label.add_theme_color_override("font_color", item.get("color", Color(0.8, 0.8, 0.8)))
            container.add_child(label)


# --- The full information about the hex for the control panel ---
# It returns { "text": String, "products": Array }.
# text is the FULL text of the hex: the left column of the panel shows everything at once, without
# waiting for a hover, therefore the properties of the hex remain in it (in the ordinary tooltip
# there are none — see _build_text with basic_only = true). products is the extended
# production with the modifiers.
func build_hex_info(row: int, col: int, tile_data: Array, city_row: int = 0, city_col: int = 0) -> Dictionary:
    var text = _build_text(row, col, tile_data, city_row, city_col)
    # It is impossible to build improvements on the hex of a city, therefore we do not show
    # the potential output of the product in the left column of the panel for it.
    var products = [] if row == city_row and col == city_col else _collect_extended_production(row, col, tile_data)
    return {"text": text, "products": products}


func update_tooltip_text(row: int, col: int, tile_data: Array, city_row: int = 0, city_col: int = 0):
    # basic_only = true: the ordinary tooltip answers the question "what is on this hex" and
    # shows only the terrain, the resource and the improvement. The properties of the hex,
    # the production and the consumption live in the extended block, which appears
    # after a hover delay. The tooltip does not have its own "Once built, ... will give" block
    # any more: the extended one shows the same thing, but with the bonuses and
    # the modifiers.
    var text = _build_text(row, col, tile_data, city_row, city_col, true)

    var products: Array = []
    # If the extended block is already shown for this hex, the final set of rows is
    # exactly it. Otherwise a refresh (the fluctuating occupancy of the pasture) would rebuild
    # the container from scratch and all the rows of the block would disappear (see the comment
    # to _extended_row).
    if _extended_row == row and _extended_col == col:
        products = _collect_extended_block(row, col, tile_data)

    # We update the UI only on a REAL change of the contents. A periodic
    # refresh (the occupancy of the pasture) calls this function several times
    # per second: a full rebuild of the container every time looked like jerks.
    var products_key = var_to_str(products)
    if text == _tooltip_text_label.text \
            and products_key == _last_products_key \
            and _tooltip_products_container.get_child_count() == products.size():
        return

    for child in _tooltip_products_container.get_children():
        # free(), and not queue_free(): the immediate removal excludes a frame
        # when the old and the new items hang in the container at the same time
        # (otherwise the size of the tooltip jumped by one frame).
        child.free()

    _tooltip_text_label.text = text
    render_products(products, _tooltip_products_container)
    _last_products_key = products_key


# Answers whether to show the extended block of the tooltip on this hex.
#
# The conditions are NOT listed here: the check asks the same assembler, which
# builds the block itself, and compares the result with an empty list. The list of conditions and
# the list of rows, written separately, will sooner or later diverge — and then
# the extended block either does not appear at all, or appears empty (see docs.md,
# the section "The ordinary and the extended hex tooltips").
func has_extended_tooltip_info(row: int, col: int, tile_data: Array) -> bool:
    return not _collect_extended_block(row, col, tile_data).is_empty()


func update_extended_tooltip(row: int, col: int, tile_data: Array, city_row: int, city_col: int):
    # We remember the hex: from this moment the repeated call of update_tooltip_text
    # (the refresh of the occupancy of the pasture) will redraw EXACTLY the extended block.
    _extended_row = row
    _extended_col = col

    _render_extra_products(_collect_extended_block(row, col, tile_data))


# Assembles the rows of the extended block of the tooltip. The single source of these rows:
# both the check "whether to show" (has_extended_tooltip_info), and the showing of the block
# (update_extended_tooltip), and its redrawing on a refresh (update_tooltip_text)
# take the result from here — otherwise the lists would diverge.
#
# The function is PURE: it draws nothing and does not change the labels. A side effect here
# would be twice as dangerous — it is called by the check from handle_process (InputHandler),
# that is, every frame until the block is shown.
func _collect_extended_block(row: int, col: int, tile_data: Array) -> Array:
    # The road level on the hex. It is added FIRST, before the checks below: on a hex with
    # a road, but without an improvement (for example, an empty hex under the road) all the earlier
    # exits would fire before, and the row would not appear at all — and that is exactly where
    # the player decides which road to upgrade.
    #
    # The rows ACCUMULATE and are rendered ONCE by the caller: render_products cleans
    # the container, and two calls in a row would erase the first one — on a hex with a road and
    # a natural resource (for example, with the wild plants) the level would silently disappear.
    var extra_products: Array = []
    var road_line := road_level_line(row, col)
    if not road_line.is_empty():
        extra_products.append({"type": "label", "text": tr("Road: %s") % road_line,
                "color": Color(0.7, 0.9, 0.7)})

    # The properties of the hex: the quality of the resource, the expense of the feed, the occupancy of the pasture,
    # the access to fresh water. They were moved here from the basic tooltip, where only
    # the terrain, the resource and the improvement remained.
    #
    # They are added BEFORE the early exits below: the access to the water exists also on a hex without
    # a resource, and in the influence ring of someone else's town — the gates on the feed and the occupancy
    # live inside _collect_hex_properties.
    for property_line in _collect_hex_properties(row, col, tile_data):
        extra_products.append({"type": "label", "text": property_line})

    var tile = tile_data[row][col]
    var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)
    if not is_revealed or bool(tile.get("in_town_influence", false)):
        return extra_products

    # The calculations of the construction cost (base/terrain/distance) were moved
    # to the Preview of the control panel — they are not shown here any more.

    var res_id = MapHelpers.get_effective_resource(tile)
    # We do not show a hidden resource — as if there were none on the hex.
    if res_id != "" and not MapHelpers.is_resource_revealed(tile):
        res_id = ""
    if res_id == "":
        return extra_products
    var res_data = GameData.raw_resources.get(res_id, {})
    if not res_data.has("produces"):
        return extra_products

    extra_products.append_array(_collect_extended_production(row, col, tile_data))
    return extra_products


# --- The properties of the hex: what has left the basic tooltip ---
#
# --- The properties of the hex: what has left the basic tooltip ---
func _collect_hex_properties(row: int, col: int, tile_data: Array) -> Array:
    var lines: Array = []
    var tile = tile_data[row][col]
    if tile == null:
        return lines
    # The quality of the resource, the expense of the feed, the occupancy of the pasture and the access to fresh
    # water. The ordinary tooltip answers the question "what is on this hex" (the terrain,
    # the resource, the improvement), therefore the properties are shown only in the extended block.
    #
    # The single source of the rows: both the extended block of the tooltip, and the full text of the hex
    # for the left column of the control panel. The rows are returned WITHOUT a leading line
    # break — the caller glues them itself: in the text it is a line break plus a row,
    # and in the container of the tooltip rows each has its own indent.
    var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)
    if not is_revealed:
        return lines

    # An unexplored hex: we do not disclose the properties. The basic tooltip for it is also
    # silent — there is only the terrain and a hint about the scouting.
    var tile_quality = tile.get("quality", "")
    if tile_quality != "" and tile.improvement != null:
        lines.append(tr("Quality: %s (%s)") % [
                GameData.get_quality_stars(tile_quality),
                GameData.get_quality_name(tile_quality)])

    var res_id = MapHelpers.get_effective_resource(tile)
    # The quality is a property of the improvement: without a built improvement it does not
    # exist on the hex yet.
    if res_id != "" and not MapHelpers.is_resource_revealed(tile):
        res_id = ""
    # A hidden resource (tech_reveal is not learned): the player must not know about it.
    if res_id != "" and not bool(tile.get("in_town_influence", false)):
        var res_data = GameData.raw_resources.get(res_id, {})
        var feed_consumption = res_data.get("feed_consumption", 0)
        if feed_consumption > 0:
            lines.append(tr("Feed consumption: %d per cycle") % feed_consumption)
        var time_to_mature = res_data.get("time_to_mature", 0)
        if time_to_mature > 0:
    # The feed and the occupancy of the herd are the economic indicators of the improvement. In the
    # influence ring of SOMEONE ELSE'S town we do not show them: the player does not control these hexes
    # (the same gate that was in the basic tooltip).
            if tile.improvement != null and _worker_manager.has_worker(row, col):
                var fill_frac = MapHelpers.get_fill_fraction(tile, res_data)
                if fill_frac >= 1.0:
                    lines.append(tr("Herd: full (100%)"))
                else:
                    var t_left = MapHelpers.get_time_to_full(tile, res_data)
                    lines.append(tr("Fill level: %d%% (full in %.0f sec)") % [
                            roundi(fill_frac * 100), ceilf(t_left)])
            else:
                lines.append(tr("Fill time: %.0f sec") % time_to_mature)

            # A growing resource (the animals on the pasture): the current occupancy and
            # the remaining time — if the improvement is already working.
    var water_access = MapHelpers.get_hex_water_access(
            row, col, tile_data, tile_data.size(), tile_data[0].size())
    if water_access == "direct":
        lines.append(tr("Fresh water access: direct"))
    elif water_access == "chain":
        lines.append(tr("Fresh water access: via chain"))

    return lines


    # We show the access to fresh water for ALL hexes.
    #
    # Resets the binding of the extended block to the hex. It is called by the owner of the tooltip
    # (InputHandler) on a change of the hex and on the hiding of the tooltip — there, where
    # its own flag "the block is already shown" is reset.
    #
    # Without the reset, the return to the same hex would draw the extended block immediately, bypassing
    # the hover delay: update_tooltip_text would see the old binding.
func clear_extended_tooltip():
    _extended_row = -1
    _extended_col = -1

# The only point of the rendering of the extended block of the tooltip. An empty list is also
# a call: it cleans the container, and without it the rows of the previous hex
# would remain on a hex without the extended information.
#
# The key is updated HERE: further on it describes the already extended block, and not the basic
# set from update_tooltip_text. Otherwise the very first refresh after the showing of the block would see
# "it has changed" and would rebuild the container in vain (and after it the key would still
# become outdated — the comparison would go against what is not drawn).
func _render_extra_products(products: Array):
    render_products(products, _tooltip_products_container)
    _last_products_key = var_to_str(products)


# --- The building of the text of the hex ---
# It is moved out of update_tooltip_text, so that the control panel (control_panel.gd)
# shows the same information without duplicating the code.
#
#
# basic_only = true — the BASIC text of the ordinary tooltip: only the terrain, the resource and the
# improvement, that is, physically what lies on the hex. Everything else — the quality,
# the feed, the occupancy, the access to fresh water, the production, the consumption — lives
# in the extended block (see _collect_extended_block and _collect_hex_properties).
#
#
# basic_only = false (by default) — the FULL text for the left column of the control
# panel: there everything is shown at once, without a hover delay, therefore
# the properties of the hex remain in it (see build_hex_info).
func _build_text(row: int, col: int, tile_data: Array, city_row: int = 0, city_col: int = 0, basic_only: bool = false) -> String:
    var tile = tile_data[row][col]
    var terrain_name = GameData.terrains.get(tile.terrain, {}).get("name", tile.terrain)
    var cover_id = tile.get("cover", "none")

    var is_revealed = tile.get("in_influence", false) or tile.get("is_explored", false)
    # The effective resource: natural (tile.resource) or bred (tile.crop_bred).
    var res_id = MapHelpers.get_effective_resource(tile)
    # A hidden resource (tech_reveal is not learned): the player must not know about it —
    # we show the hex as empty (without the name of the resource, the improvement and the output).
    if res_id != "" and not MapHelpers.is_resource_revealed(tile):
        res_id = ""
    var res_name = tr("none")
    if res_id != "":
        res_name = GameData.raw_resources.get(res_id, {}).get("name", res_id)

    var cover_name_lower = ""
    if cover_id != "none":
        cover_name_lower = GameData.covers.get(cover_id, {}).get("name", cover_id).to_lower()
    var terrain_with_cover = terrain_name
    if cover_name_lower != "":
        terrain_with_cover = "%s, %s" % [terrain_name, cover_name_lower]

    var terrain_data = GameData.terrains.get(tile.terrain, {})
    if terrain_data.get("unique", false) and not is_revealed:
        # A unique terrain (for example, a soda lake) outside the visible
        # area: we show the name/description, plus the marker "Territory of a city" /
        # "City", if the hex has got into the ring or contains a town.
        var desc = terrain_data.get("description", "")
        var uniq_text: String = desc if desc != "" else terrain_name
        var uniq_terr: Array = _territory_lines_for(tile, row, col)
        if not uniq_terr.is_empty():
            uniq_text += "\n" + "\n".join(uniq_terr)
        return uniq_text

    if not is_revealed:
        # An unexplored hex (in the Region or in the fog of war): the standard
        # text with a hint about the scouting. The scouts can be sent to any
        # point reachable by scrolling, — including the territory of the towns, therefore
        # the hint is the same for all the unexplored hexes.
        var text: String = tr("Terrain: %s") % terrain_with_cover
        var terr: Array = _territory_lines_for(tile, row, col)
        if not terr.is_empty():
            text += "\n" + "\n".join(terr)
        text += tr("\nResource: unknown (send scouts)")
        return text

    var imp_name = GameData.improvements.get(tile.improvement, {}).get("name", tr("none")) if tile.improvement != null else tr("none")
    var text: String = tr("Terrain: %s") % terrain_with_cover
    # The markers of someone else's territory in the ring/at the place of a town: right after
    # "Terrain", so that the player sees "who is here" before reading
    # the rest of the tooltip. The "City" row is added ONLY when there really is
    # a town on the hex (i.e. in the centre of the ring), and "Territory of a
    # city" — on any hex of the ring, including the town itself.
    var terr: Array = _territory_lines_for(tile, row, col)
    if not terr.is_empty():
        text += "\n" + "\n".join(terr)
    var resource_text = _format_resource_label_for_text(res_id, res_name)
    text += tr("\nResource: %s") % resource_text

    var terrain_desc = terrain_data.get("description", "")
    if terrain_desc != "":
        text += "\n%s" % terrain_desc

    var in_town_influence = bool(tile.get("in_town_influence", false))
    var imp_status = ""
    if tile.improvement != null:
        if in_town_influence:
            imp_status = ""
        elif GameData.is_no_worker_improvement(tile.improvement):
            # An infrastructure improvement (no_worker, for example a harbor):
            # it functions on its own — the status "no worker" does not apply.
            imp_status = tr(" (infrastructure: no worker required)")
        else:
            var has_worker = _worker_manager.has_worker(row, col)
            if not has_worker:
                imp_status = tr(" (inactive: no worker)")
            else:
                imp_status = tr(" (working)")
    else:
        if res_id != "":
            var res_data = GameData.raw_resources.get(res_id, {})
            # There is nothing to build on a one-off resource (improved_by == null) —
            # we do not show the status "(not built)".
            if res_data.get("improved_by", null) != null and res_data.has("produces"):
                imp_status = tr(" (not built)")

    text += tr("\nImprovement: %s%s") % [imp_name, imp_status]

    # The properties of the hex (the quality, the feed, the occupancy, the access to fresh water) are
    # NOT shown in the ordinary tooltip — they live in the extended block. Here
    # they are appended only to the full text, that is, to the left column of the panel.
    if not basic_only:
        for property_line in _collect_hex_properties(row, col, tile_data):
            text += "\n" + property_line

    # --- The conflict "a tech_reveal resource under someone else's improvement" ---
    var conflict = MapHelpers.get_tech_reveal_conflict(tile)
    if not conflict.is_empty():
        var current_imp_name: String = GameData.improvements.get(tile.improvement, {}).get("name", tile.improvement)
        text += tr("\n\nFound here: %s") % conflict.get("res_name", "")
        text += tr("\nDemolish %s to build %s") % [current_imp_name, conflict.get("imp_name", "")]

    # The cost of the construction in the tooltip/left panel is not shown any more —
    # the calculations are moved to the Preview of the control panel.

    return text


# --- The collection of the extended production (with the modifiers) ---
func _collect_extended_production(row: int, col: int, tile_data: Array) -> Array:
    var result = []
    var tile = tile_data[row][col]
    var eff_res = MapHelpers.get_effective_resource(tile)
    # A hidden resource (tech_reveal is not learned): we do not show the production —
    # otherwise the hint "Once built, X will give…" would disclose its presence.
    if eff_res != "" and not MapHelpers.is_resource_revealed(tile):
        eff_res = ""
    if eff_res == "":
        # A forest plot: the production of wood from the cover (wood_yield in
        # covers.json). We show it both for a built plot with a worker, and
        # as the hint "once built" on an empty forest hex. Any future
        # a cover with wood_yield > 0 is taken into account automatically.
        var lj_yield: float = MapHelpers.get_cover_wood_yield(tile)
        if lj_yield > 0.0 and tile.improvement == null \
                and CityData.is_product_available("wood"):
            var lj_name = GameData.improvements.get("lumberjack_hut", {}).get("name", "lumberjack_hut")
            var lj_interval0 := CityData.get_improvement_production_interval("lumberjack_hut")
            var lj_per_sec0: float = float(int(ceil(lj_yield))) / lj_interval0
            var wood_data0 = GameData.products.get("wood", {})
            var lj_icon_path0 = ""
            if wood_data0.has("icon"):
                lj_icon_path0 = IconRegistry.icon_path(wood_data0["icon"])
            result.append({"type": "header", "text": tr("Once built, %s will produce:") % lj_name})
            result.append({"type": "product", "name": wood_data0.get("name", tr("Wood")), "amount": lj_per_sec0, "icon_path": lj_icon_path0, "suffix": tr(" units/sec")})
        elif tile.improvement == "lumberjack_hut" and lj_yield > 0.0 \
                and _worker_manager.has_worker(row, col) \
                and CityData.is_product_available("wood"):
            var lj_mult2 = CityData.get_improvement_production_multiplier(
                "lumberjack_hut",
                MapHelpers.is_hex_irrigated(row, col, tile_data, tile_data.size(), tile_data[0].size()),
                tile.get("terrain", ""), "lumberjack_hut")
            var lj_interval2 := CityData.get_improvement_production_interval("lumberjack_hut")
            var lj_per_sec2: float = float(ceili(lj_yield * lj_mult2)) / lj_interval2
            var wood_data2 = GameData.products.get("wood", {})
            var lj_icon_path2 = ""
            if wood_data2.has("icon"):
                lj_icon_path2 = IconRegistry.icon_path(wood_data2["icon"])
            var lj_label = wood_data2.get("name", tr("Wood"))
            if lj_mult2 != 1.0:
                var lj_base_str = str(int(lj_yield)) if lj_yield == floor(lj_yield) else "%.1f" % lj_yield
                lj_label = tr("%s (base %s)") % [lj_label, lj_base_str]
            result.append({"type": "header", "text": tr("Produces:")})
            result.append({"type": "product", "name": lj_label, "amount": lj_per_sec2, "icon_path": lj_icon_path2, "suffix": tr(" units/sec")})
        return result
    var res_data = GameData.raw_resources.get(eff_res, {})
    if not res_data.has("produces"):
        return result

    # The one-off resources (improved_by == null — the wild plants, the metal nuggets) do not have
    # a continuous production: they are gathered by the special action action_type "forage",
    # after which the resource disappears from the map. In the extended summary ("Produces:…")
    # there is nothing to show for them, and the value of produces there is a "number or [min, max]"
    # (the output per one gathering), and not the base output per cycle of the improvement.
    if res_data.get("improved_by", null) == null:
        return result

    var modifiers := []
    var bonus_multiplier = 1.0
    # The interval of the production cycle: for a built improvement it is its own
    # production_interval, for the hint "once built" — the interval of the future
    # improvement (improved_by of the resource).
    var prod_interval: float = 1.0
    if tile.improvement != null and _worker_manager.has_worker(row, col):
        modifiers = CityData.get_improvement_production_modifiers(tile.improvement, MapHelpers.is_hex_irrigated(row, col, tile_data, tile_data.size(), tile_data[0].size()), tile.get("terrain", ""), eff_res)
        bonus_multiplier = CityData.get_improvement_production_multiplier(tile.improvement, MapHelpers.is_hex_irrigated(row, col, tile_data, tile_data.size(), tile_data[0].size()), tile.get("terrain", ""), eff_res)
        prod_interval = CityData.get_improvement_production_interval(tile.improvement)
    elif tile.improvement == null:
        prod_interval = CityData.get_improvement_production_interval(str(res_data.get("improved_by", "")))

    var available_products := {}
    for prod_id in res_data["produces"]:
        if tile.improvement == null or CityData.is_product_available(prod_id):
            available_products[prod_id] = res_data["produces"][prod_id]

    if available_products.is_empty():
        return result

    var header_text = tr("Produces:")
    if tile.improvement == null:
        var improvement_id = res_data.get("improved_by", "")
        var imp_name_display = GameData.improvements.get(improvement_id, {}).get("name", improvement_id)
        header_text = tr("Once built, %s will produce:") % imp_name_display
    result.append({"type": "header", "text": header_text})

    # The growing resources: while the pasture is filling up, the actual output
    # is proportional to the degree of the occupancy of the herd.
    var fill_frac = MapHelpers.get_fill_fraction(tile, res_data)

    var base_amount = 0.0
    var final_amount = 0
    for prod_id in available_products:
        # produces can be a number or a range [min, max] — in the summary
        # we show the deterministic minimum (see RangeUtils).
        base_amount = float(RangeUtils.get_min_value(available_products[prod_id], 1))
        final_amount = ceili(base_amount * bonus_multiplier * fill_frac)
        var prod_name = GameData.products.get(prod_id, {}).get("name", prod_id)
        # With the active modifiers we show the base for each product
        # (for different products it is its own, one common row "Base" was misleading).
        if bonus_multiplier != 1.0 or fill_frac != 1.0:
            var base_str = str(int(base_amount)) if base_amount == floor(base_amount) else "%.1f" % base_amount
            prod_name = tr("%s (base %s)") % [prod_name, base_str]
        var icon_path = ""
        var prod_data = GameData.products.get(prod_id, {})
        if prod_data.has("icon"):
            var icon_name = prod_data["icon"]
            icon_path = IconRegistry.icon_path(icon_name)
        # The display is per second: the output of the cycle, divided by production_interval.
        result.append({"type": "product", "name": prod_name, "amount": float(final_amount) / prod_interval, "icon_path": icon_path, "suffix": tr(" units/sec")})

    for mod in modifiers:
        result.append({"type": "label", "text": " %s" % mod.get("label", ""), "color": Color(0.7, 0.9, 0.7)})

    # --- The consumption of the profession ---
    # We show the list of the resources that the profession of the worker on this hex
    # spends from the storage. The source of the records is the registry data/consumption.json
    # (plus the deprecated consumption field of the products), see docs.md.
    # The section appears only if:
    #   1) the improvement is built,
    #   2) there is a worker on it,
    #   3) the improvement has a profession,
    #   4) this profession has at least one consumer.
    # The production of the improvement itself does NOT stop when there is not enough resource —
    # it rolls back to the base multiplier (without the bonus).
    if tile.improvement != null and _worker_manager.has_worker(row, col):
        # The rows of the display are assembled by the common ConsumptionUi: the same rows are drawn by
        # the tooltip of the building details (the "Buildings" tab) and by the window of the building details,
        # therefore the format of the expense is the same for all these places.
        var cons_rows = ConsumptionUi.build_rows(
            GameData.get_profession_for_improvement(tile.improvement))
        if not cons_rows.is_empty():
            result.append({"type": "header", "text": tr("Consumes:")})
            for cons in cons_rows:
                var cons_label: String = str(cons.get("label", ""))
                # The icon of the consumed resource; for a group the icon of
                # the first member with a picture is taken (GameData puts it in "icon").
                var cons_icon_path: String = IconRegistry.icon_path(
                    str(cons.get("icon", "")))
                if cons_icon_path != "":
                    result.append({
                        "type": "product",
                        "name": cons_label,
                        "amount": 0, # we do not output the number: the text label matters
                        "icon_path": cons_icon_path
                    })
                else:
                    result.append({"type": "label", "text": cons_label, "color": Color(0.85, 0.85, 0.85)})

    return result
