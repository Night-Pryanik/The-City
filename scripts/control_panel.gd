# control_panel.gd
# The control panel of the hex in the bottom part of the game map.
#
# The logic:
#   - The panel is visible always, but the contents appear on a click of the LMB on a hex.
#   - The left (larger) part is the full information about the hex (as in the extended tooltip).
#   - The right (smaller) part is the action buttons (the construction of the improvements, the special actions,
#     the management of the worker, the cancellation of the build).
#   - A click on an action button opens the "preview": the calculation of the production taking
#     all the modifiers into account + the buttons "Build" and "Cancel".
#   - ESC or a click on another hex resets the preview.
#   - The unavailable actions are greyed out, with a tooltip of the reason ("a technology is needed",
#     "there is no labour", "a harbor is needed" and so on).
#
# The panel reacts to the external changes through the signals (see main_map.gd):
#
# the id of the special action "Build a road" in data/special_actions.json. The only
# place, where the panel knows about the road by the name: both the button on the hex of the town, and
# the special block of the price in the preview.
#   worker_manager.assignment_changed, build_manager.build_completed/build_cancelled,
#   CityData.city_updated, CityData.research_completed, expansion_manager.territory_expanded.
extends Panel

# The kind of the action "Improve the road". This is NOT a special action from data/special_actions.json:
# the improvement does not change the contents of the hex and does not have its own work_cost (the price of a segment
# is taken from the road level, see roads.json), therefore it lives as a separate
# kind of the action of the panel, and not as one more record in the common list.
const ROAD_ACTION_ID := "build_road"

# The references to the nodes (filled in from main_map.gd through initialize()).
const UPGRADE_ROAD_TYPE := "upgrade_road"

# A click of the LMB on an empty place of the panel (past the buttons and the scrolls) removes
# the selection of the hex. The buttons and the scrollable areas absorb the clicks themselves,
# therefore the event reaches here only for the empty background of the panel.
var main_map: Node
var map_tooltip: MapTooltip
var worker_manager: Node
var build_manager: Node

func _ready():
    _setup_collapse_button()

# --- The collapsing/expanding of the panel ---
func _gui_input(event: InputEvent):
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
            and not event.pressed:
        if has_selection():
            main_map.clear_selection()

# The height of the collapsed panel = the height of the toggle button.

# Creates the toggle button in the top right corner of the panel.
# The button is bound by the anchors to the top right corner, therefore it remains in place
# on a change of the size of the window/panel.
const _COLLAPSED_HEIGHT := 28.0

var _toggle_btn: Button
var _collapsed := false
var _saved_offset_top := -1.0

    # The anchors: the top right corner of the panel with a small indent.
func _setup_collapse_button():
    _toggle_btn = Button.new()
    _toggle_btn.text = "▼"
    _toggle_btn.tooltip_text = tr("Collapse panel")
    _toggle_btn.focus_mode = Control.FOCUS_NONE
    _toggle_btn.flat = true
    _toggle_btn.custom_minimum_size = Vector2(28, 24)
    _toggle_btn.pressed.connect(_toggle_collapsed)
    # Switches the panel between the collapsed and the expanded state.
    _toggle_btn.anchor_left = 1.0
    _toggle_btn.anchor_right = 1.0
    _toggle_btn.anchor_top = 0.0
    _toggle_btn.anchor_bottom = 0.0
    _toggle_btn.offset_left = -32.0
    _toggle_btn.offset_right = -4.0
    _toggle_btn.offset_top = 2.0
    _toggle_btn.offset_bottom = 26.0
    add_child(_toggle_btn)

# Switches the panel between the collapsed and the expanded state.
func _toggle_collapsed():
    _set_collapsed(not _collapsed)

func _set_collapsed(collapsed: bool):
    if _collapsed == collapsed:
        return
    _collapsed = collapsed

    if _collapsed:
        # We remember the current height and raise the top edge of the panel so,
        # that a strip of the height of the button remains.
        # IMPORTANT: the panel is stretched vertically (anchor_top=0, anchor_bottom=1),
        # therefore the height is set by the difference offset_bottom - offset_top,
        # and not by the absolute coordinates size.y.
        _saved_offset_top = offset_top
        offset_top = offset_bottom - _COLLAPSED_HEIGHT
        _set_content_visible(false)
        _toggle_btn.text = "▲"
        _toggle_btn.tooltip_text = tr("Expand panel")
    else:
        if _saved_offset_top >= 0.0:
            offset_top = _saved_offset_top
        _set_content_visible(true)
        _toggle_btn.text = "▼"
        _toggle_btn.tooltip_text = tr("Collapse panel")

# Hides/shows the contents of the panel (when collapsed only the button remains).
func _set_content_visible(visible_now: bool):
    for node_path in ["SepInfoPreview", "SepPreviewActions", "PreviewContainer", "InfoVBox", "ActionsVBox"]:
        var child = get_node_or_null(NodePath(node_path))
        if child != null:
            child.visible = visible_now

# The current selection and the preview.
var _selected_hex = null # { "row": int, "col": int }
var _preview_action = null # { "type": String, "imp_id": String, "target_res_id": String, "label": String }
# The last "era" of the display of the resources (CityData.resource_display_interval):
# the tick path on_city_updated() redraws the info column and the preview only
# when the era has changed; the event path (refresh()/_refresh(), a click, an action)
# is updated instantly and synchronises the era.
var _display_epoch: int = -1

# The references to the child UI nodes.
var _info_label: RichTextLabel
var _products_container: VBoxContainer
var _actions_container: FlowContainer
var _preview_container: VBoxContainer
# A fixed row of the heading of the preview (outside the scroll area): the label of
# the action + the buttons "Start"/"Cancel". It is above PreviewScroll, therefore
# it is always visible, even when the contents of the column are scrolled.
var _preview_header_container: VBoxContainer

# A snapshot of the state of the action buttons at which they were built the last time.
# It is used, so as NOT to recreate the buttons (and their OS tooltips) on every
# game tick: CityData.city_updated is emitted once per SIMULATION_TICK from
# do_tick(), and without this _build_actions() would destroy the buttons
# together with their tooltips "A technology is needed: ...", "There is no labour: ..." and so on
# (the same pattern as _last_panel_state in building_panel.gd /
# _needs_full_refresh in city_ui.gd).
# The format: {"row": int, "col": int, "actions": Array}
var _last_actions_snapshot: Dictionary = {}

# A snapshot of the state of the preview block at which it was built the last time.
# Analogously to _last_actions_snapshot: we do not recreate the elements of the preview (incl.
# the buttons "Build"/"Cancel" together with their OS tooltips) on every game
# tick, if the choice of the action has not changed.
# The format: {"row": int, "col": int, "type": String, "label": String, "imp_id": String,
#          "action_id": String, "target_res_id": Variant, "eff_res": String}
var _last_preview_snapshot: Dictionary = {}

func initialize(main_node: Node):
    main_map = main_node
    map_tooltip = main_node.map_tooltip
    worker_manager = main_node.worker_manager
    build_manager = main_node.build_manager

    _info_label = $InfoVBox/InfoScroll/InfoContent/InfoLabel
    _info_label.bbcode_enabled = true
    _products_container = $InfoVBox/InfoScroll/InfoContent/ProductsContainer
    _actions_container = $ActionsVBox/ActionsScroll/ActionsContent/ActionsContainer
    _preview_container = $PreviewContainer/PreviewScroll/PreviewContent
    _preview_header_container = $PreviewContainer/PreviewHeader

    # The panel is visible always, but the contents are empty until a hex is selected.
    clear_selection()

# It is called on a click of the LMB on the hex (row, col).
func select_hex(row: int, col: int):
    _selected_hex = {"row": row, "col": col}
    _preview_action = null
    _refresh()

# Removes the selection and clears the panel.
func clear_selection():
    _selected_hex = null
    _preview_action = null
    _refresh()

# Resets only the preview of the action (ESC or a click on another hex).
func clear_preview():
    _preview_action = null
    _refresh()

# Returns true, if there is an active preview of an action.
func has_preview() -> bool:
    return _preview_action != null

# Returns true, if there is a selected hex.
func has_selection() -> bool:
    return _selected_hex != null

# Returns the selected hex or null.
func get_selected_hex():
    return _selected_hex

# The tick update (CityData.city_updated, connected in main_map._ready):
# the left column (the terrain, "Produces/Consumes ... per tick"), the list
# of the production and the preview of the action are updated with the display interval of the resources
# (CityData.resource_display_interval) — their numbers used to jump on every tick.
# The action buttons are at that time maintained on every tick, as before: their tooltips
# by design do not contain the values changing on every tick (see
# the comment in _build_actions), and the snapshot _last_actions_snapshot does not allow
# to recreate the buttons without the real changes.
func on_city_updated():
    if _selected_hex == null:
        _clear_ui()
        return
    var row = _selected_hex.row
    var col = _selected_hex.col
    if not main_map.is_hex_on_map(row, col):
        clear_selection()
        return
    if CityData.resource_display_due(_display_epoch):
        _refresh()
        return
    # The interval has not passed yet: we maintain only the availability of the action buttons.
    var tile = main_map.get_tile_data(row, col)
    if tile == null:
        clear_selection()
        return
    _build_actions(row, col, tile)

# Updates the panel. It is called on the external changes (the signals) and on
# the selection/reset. If the selected hex is no longer on the map (for example,
# a save with a map of a different size has been loaded) — we remove the selection.
# The check is exactly by the boundaries of the MAP: selecting the hexes outside the Region (the fog of war,
# the territory of the towns) is now possible — the scouting is available there.
func refresh():
    if _selected_hex == null:
        _clear_ui()
        return
    var row = _selected_hex.row
    var col = _selected_hex.col
    if not main_map.is_hex_on_map(row, col):
        clear_selection()
        return
    _refresh()

func _refresh():
    # The event update (a click on a hex, an action, a research, a claiming):
    # everything is drawn at once and synchronises the era of the display of the resources — only
    # the tick update waits for the interval (see on_city_updated).
    _display_epoch = CityData.resource_display_epoch
    if _selected_hex == null:
        _clear_ui()
        return
    var row = _selected_hex.row
    var col = _selected_hex.col
    var tile = main_map.get_tile_data(row, col)
    if tile == null:
        clear_selection()
        return

    # --- The left part: the full information about the hex ---
    # A hex in the fog of war: the terrain, the resources and the improvements are not known to the player —
    # instead of the information we show a stub. The actions on the right (the scouting)
    # remain: they do not disclose the contents of the hex (see main_map.is_hex_in_fog).
    if main_map.is_hex_in_fog(row, col):
        _info_label.text = tr("Area not scouted — information unavailable.\n\nTerrain, resources and improvements become known after scouting.")
        map_tooltip.render_products([], _products_container, true)
    else:
        var info = map_tooltip.build_hex_info(row, col, main_map.tile_data, main_map.city_row, main_map.city_col)
        _info_label.text = info["text"]
        map_tooltip.render_products(info["products"], _products_container, true)
        # We show the route to the city as a SEPARATE row in the same block: it
        # does not relate to the properties of the hex, but to its connection with the city. Without it
        # the player on an improvement sees neither the length of the route, nor its speed, and
        # it is exactly by them that it is decided whether to improve the road.
        _append_route_info(row, col)

    # --- The right part: the action buttons ---
    _build_actions(row, col, tile)

    # --- The preview of the action (if there is one) ---
    if _preview_action != null:
        _build_preview(row, col, tile)
    else:
        # There is no preview (a change of the selected hex, ESC and so on) — we must
        # clear the container, so that the old preview does not remain in the panel.
        for child in _preview_container.get_children():
            child.queue_free()
        for child in _preview_header_container.get_children():
            child.queue_free()
    # We reset the snapshot: the next opened preview must recreate
    # its block (even if it opens the same action on the same hex).
        _last_preview_snapshot = {}
    # We bring the route on the map in line with the current preview: it has appeared,
    # changed or disappeared. Exactly here, and not in _build_road_preview(), because
    # _build_preview exits early by the snapshot — the preview of the same action on
    # of the same hex is not rebuilt, and the "ghost" road would have got stuck on
    # the old route (for example, after the scouting of the path to the town).
    _sync_road_preview_on_map()

func _clear_ui():
    _info_label.text = tr("Select a hex on the map (LMB) to see information and available actions.")
    for child in _products_container.get_children():
        child.queue_free()
    for child in _actions_container.get_children():
        child.queue_free()
    for child in _preview_container.get_children():
        child.queue_free()
    for child in _preview_header_container.get_children():
        child.queue_free()
    # The reset of the snapshot: if the container of the buttons is cleared, but the snapshot coincides with
    # the previous hex, the next _build_actions() would otherwise decide that there is nothing
    # to recreate (and the buttons would not appear).
    _last_actions_snapshot = {}
    _last_preview_snapshot = {}
    # We stop the showing of the route and the ghost: the selection is removed, therefore there is no preview.
    _set_map_road_preview({})
    _set_map_route_display({})

# The row "Route to the city" in the left column of the panel: how many segments and
# the average speed over the route. It is shown only when the route exists; on
# a hex without a road there is no row — writing "there is no route" on every empty hex
# would mean cluttering the panel.
#
# The arithmetic average over the segments — deliberately, and not the minimum over the route:
# nine cart roads and one trail give 28 units/sec, and not 10. A separate
# row "the bottleneck" is not here (see road_manager.find_route_to_city).
func _append_route_info(row: int, col: int) -> void:
    if main_map == null or not main_map.has_method("get_route_to_city"):
        return
    # The road level on the hex itself goes BEFORE the row of the route: the route
    # is read as "where the cargo goes", and the level of the hex is its beginning. On a hex without
    # a road there is no level, but the route is empty too, so both rows are empty.
    var road_line: String = map_tooltip.road_level_line(row, col)
    if not road_line.is_empty():
        var road_label := Label.new()
        road_label.text = tr(" Road: %s") % road_line
        road_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        road_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
        _products_container.add_child(road_label)
    var route: Dictionary = main_map.get_route_to_city(row, col)
    if not route.get("ok", false):
        return
    var route_label := Label.new()
    route_label.text = tr(" Route to the city: %d sections, average %.1f units/sec") % [int(route.get("length", 0)), float(route.get("avg_speed", 0.0))]
    route_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    route_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _products_container.add_child(route_label)

# --- The building of the action buttons ---
func _build_actions(row: int, col: int, tile: Dictionary):
    # If the state of the actions for this hex has not changed since the last time —
    # we do not recreate the buttons. It preserves the open OS tooltips (otherwise on every
    # game tick the recreation of the buttons would reset the hovered tooltip).
    # IMPORTANT: therefore the values changing on every tick MUST NOT be included in the tooltips
    # (the current treasury, the current stock of the food and so on): then the tooltips differ on
    # every tick, the comparison _actions_equal() does not match, the buttons are recreated
    # and the tooltip is reset. The dynamic values the player looks at in the HUD.
    var actions := _collect_actions(row, col, tile)
    var prev = _last_actions_snapshot
    if prev.get("row", -1) == row and prev.get("col", -1) == col \
            and _actions_equal(prev.get("actions", []), actions):
        return

    _last_actions_snapshot = {"row": row, "col": col, "actions": actions}

    for child in _actions_container.get_children():
        child.queue_free()

    for action in actions:
        var btn = Button.new()
        btn.custom_minimum_size = Vector2(40, 40) # a small square button
        # The tooltip is preserved — it is the only way to know what the button does.
        btn.tooltip_text = action.get("tooltip", "")
        btn.disabled = not action.get("enabled", true)
        # The icon of the action; if there is none, or the file is not found — a question mark.
        var tex = _load_action_icon(action.get("icon", ""))
        if tex != null:
            btn.icon = tex
            btn.expand_icon = true
            btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
        else:
            btn.text = "?"
            if not action.get("enabled", true):
                btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
                btn.add_theme_color_override("font_disabled_color", Color(0.5, 0.5, 0.5))
        var action_data = action
        btn.pressed.connect(func():
            _on_action_pressed(action_data)
        )
        _actions_container.add_child(btn)

# Loads a Texture2D for the file name of the icon of the action through the common registry
# of the icons IconRegistry (the same one that the tooltip and the drawing of the map use).
# It returns null, if the name is empty or the file is not found (then the button will show "?").
func _load_action_icon(icon_name: String) -> Texture2D:
    if icon_name.is_empty():
        return null
    return IconRegistry.get_texture(icon_name)

# Compares two lists of actions (by the significant fields, so that of a non-working
# the fields type/imp_id did not recreate the buttons in vain).
func _actions_equal(a: Array, b: Array) -> bool:
    if a.size() != b.size():
        return false
    for i in range(a.size()):
        var x: Dictionary = a[i]
        var y: Dictionary = b[i]
        for key in ["type", "label", "enabled", "tooltip", "imp_id", "action_id", "target_res_id", "icon", "tech_id"]:
            if x.get(key, null) != y.get(key, null):
                return false
    return true

# Assembles the list of the actions for the hex. Each element:
#   { "type": String, "label": String, "enabled": bool, "tooltip": String,
#     "imp_id": String, "target_res_id": String, "action_id": String }
# type: "build_improvement" | "build_breeding" | "special" |
#       "pause_improvement" | "resume_improvement" | "cancel_build" |
#       "research_tech"
func _collect_actions(row: int, col: int, tile: Dictionary) -> Array:
    var actions := []
    var in_influence = tile.get("in_influence", false)

    # On the hex of the city the improvements cannot be built — there are no actions at all.
    if row == main_map.city_row and col == main_map.city_col:
        return actions

    # On the hex of a town (a small settlement) the improvements cannot be built and the
    # special actions cannot be done — by design it is a "foreign" place. There are two actions here:
    # the transition into the interface of the town and the road from the city TO it (the target of the road is
    # not the hex of the town itself, but the nearest road in its influence ring, see
    # road_manager.plan_road_to). Both appear on a single click on the hex
    # of the town; the transition into the interface is also available on a double click
    # (InputHandler). Only for a REVEALED hex: an unexplored town in
    # the fog of war is shown only by a semi-transparent icon, and interacting
    # with it is impossible — such a hex is handled as an ordinary scouting hex (below).
    if tile.get("has_town", false) \
            and (in_influence or tile.get("is_explored", false)):
        var town_rec = null
        if main_map.town_manager != null:
            town_rec = main_map.town_manager.find_town_at(row, col)
        var town_name = ""
        if town_rec != null:
            town_name = str(town_rec.get("name", ""))
        # The interface can be opened ALWAYS, regardless of the road: there one can see that
        # the town has something for sale and for purchase. The road gates only the
        # trade itself, and its state is shown in the tooltip.
        var trade_available := true
        if town_rec != null:
            trade_available = main_map.town_manager.is_trade_available(town_rec)
        var town_action_label = tr("Open town")
        var town_action_tooltip = tr("Open the town interface")
        if town_name != "":
            town_action_label = tr("Open %s") % town_name
            town_action_tooltip = tr("Open the town interface \"%s\"") % town_name
        if not trade_available:
            town_action_tooltip += tr(" (trade unavailable: no road to the town)")

        # The road to the town — the same special action "Build a road" as on an
        # ordinary hex, but with a different text: here the road does not reach the hex
        # of the town, but connects the city with the roads of its influence ring.
        if not main_map.road_manager.is_town_linked_to_city(row, col):
            # While a phased project to this town is going, we do not show the build button
            # — instead of it, the interruption of the already started build, which the
            # common helper below will add. We search by the TARGET (has_project_at), and not
            # by the hex: here we are interested exactly in the project aiming at the town.
            if not (main_map.project_manager != null \
                    and main_map.project_manager.has_project_at(row, col)):
                var road_sa: Dictionary = GameData.special_actions.get(ROAD_ACTION_ID, {})
                if not road_sa.is_empty():
                    _append_special_action(actions, ROAD_ACTION_ID, road_sa,
                            tr("Build a road from the city to the town%s — unlocks trade")
                                    % ((" «%s»" % town_name) if town_name != "" else ""))

        # The interruption is needed both on the hex of the town itself, and in its influence ring:
        # the road to the town ends with a segment INSIDE the ring, so without
        # this call the button would disappear on the last step of the road. The duplicate
        # with the block above is already gone — that one only hides the build button.
        _append_cancel_actions(actions, row, col)

        actions.append({
            "type": "open_town",
            "label": town_action_label,
            "enabled": true,
            "tooltip": town_action_tooltip,
            "icon": TownManager.TOWN_ICON_NAME
        })
        return actions

    # A hex outside the Influence Ring — the actions through the control panel:
    #   the unexplored area (incl. the fog of war and the territory of the towns) →
    #     "Send the scouts": before the learning of the Cartography — only into
    #     the unexplored part of the Region (in the fog of war the chunk is not gathered,
    #     see expansion_manager.get_chunk_hexes); after the Cartography — everywhere,
    #     where one can scroll. In both cases the chunk must border
    #     the known territory (the Influence Ring or the scouted hexes) —
    #     see main_map.is_chunk_adjacent_to_known;
    #   the scouted one → "Claim the area" (the purchase of a chunk for the coins from the treasury + the labour).
    #     The purchase is possible only inside the Region (see _collect_region_actions).
    if not in_influence:
        return _collect_region_actions(row, col)

    # A hex inside the Influence Ring, but in the ring of a foreign town — it cannot be built
    # on. It is the paired check to build_manager.start_build: the panel should not
    # show the knowingly impossible actions.
    #
    # The EXCEPTION — the interruption of a project: the road to the town ends with
    # a segment exactly in its influence ring, and if the ring is "mute", the road to the
    # town can neither be completed nor interrupted.
    if tile.get("in_town_influence", false):
        _append_cancel_actions(actions, row, col)
        return actions

    # The decorative improvements of the town are completely inaccessible to the player:
    # they cannot be started, demolished or replaced through the panel.
    if bool(tile.get("decorative", false)):
        return actions
    # --- AN ALREADY BUILT IMPROVEMENT ---
    if tile.improvement != null:
        var imp_name = GameData.improvements.get(tile.improvement, {}).get("name", tile.improvement)
        # The infrastructure improvements (no_worker, for example a harbor) work
        # without a worker — we do not show the start/pause buttons for them at all.
        if not GameData.is_no_worker_improvement(tile.improvement):
            var has_worker = worker_manager.has_worker(row, col)
            if has_worker:
                actions.append({
                    "type": "pause_improvement",
                    "label": tr("Pause operation (%s)") % imp_name,
                    "enabled": true,
                    "tooltip": tr("Remove the worker from the improvement"),
                    "icon": "building_pause.png"
                })
            else:
                actions.append({
                    "type": "resume_improvement",
                    "label": tr("Start operation (%s)") % imp_name,
                    "enabled": CityData.idle_population > 0,
                    "tooltip": tr("Assign a worker to the improvement") if CityData.idle_population > 0 else tr("No free workers"),
                    "icon": "building_resume.png"
                })

        # The special actions applicable to the hex with an improvement (for example, the demolition).
        _add_special_actions(actions, row, col, tile)

        # The improvement of the road to this hex: it is available when the road already exists and
        # there is something to improve it to. The button appears on ANY hex with a route
        # to the city — and not only on the improvements: the player can improve the road
        # even up to an empty hex, if he decides that there will be an improvement there.
        _append_upgrade_road_action(actions, row, col)

        # The interruption of a build and/or a project. It is exactly here that the check of the project
        # was LOST earlier: the branch of the hex with an improvement did a return, without reaching
        # the common block of the cancellation. And the road to a hex with an improvement can be built
        # (the "Build a road" button is available, if the improvement is not no_road), that is,
        # it was possible to start a project and impossible to interrupt it.
        _append_cancel_actions(actions, row, col)
        return actions

    # --- A HEX WITHOUT AN IMPROVEMENT ---
    # 1. A natural resource with improved_by.
    var eff_res = MapHelpers.get_effective_resource(tile)
    if tile.resource != null:
        var raw = GameData.raw_resources.get(tile.resource, {})
        if "improved_by" in raw and raw.improved_by != null and raw.improved_by != "":
            var imp_id = raw.improved_by
            var imp_data = GameData.improvements.get(imp_id, {})
            var imp_name = imp_data.get("name", imp_id)
            var enabled = true
            var tooltip = tr("Build %s") % imp_name
            # The check: the resource is hidden by the tech_reveal gate. We do not show the action
            # at all (neither the button nor the tooltip): the player must not know where
            # a hidden resource is, until he learns the corresponding technology.
            if not MapHelpers.is_resource_revealed(tile):
                # A hidden resource: there are no actions and no hints on this hex.
                pass
            else:
                # The buttons of the learning and of the construction of the improvement blocked by a
                # technology, we show only if there are at most TECH_HOPS_MAX "hops" left
                # to the unlocking technology of the improvement.
                var imp_unlock_tech = CityData.get_improvement_unlock_tech(imp_id)
                var imp_tech_blocked = not CityData.is_improvement_unlocked(imp_id)
                if imp_tech_blocked and CityData.get_tech_hops(imp_unlock_tech) > CityData.TECH_HOPS_MAX:
                    pass
                else:
                    # The "Learn ..." button offers the NEXT unlearned step of the
                    # technological chain, which unlocks an IMPROVEMENT allowing
                    # to exploit this resource. The chain is built by the technology of the
                    # improvement (imp_unlock_tech), and NOT by the technology of the appearance
                    # of the resource itself (tech_required): the visible resources are unlocked at
                    # the start, but they can be extracted only by the corresponding
                    # improvement. For example, the quartz sand is extracted by a quarry
                    # (unlocked by "Stone masonry"), although the resource itself becomes
                    # possible to process into glass only after the learning of "Glassmaking".
                    var chain = CityData.get_tech_study_chain(imp_unlock_tech)
                    if not chain.is_empty():
                        actions.append(_make_research_action(chain[0]))
                    # The tooltip of the CONSTRUCTION button always points to the IMMEDIATE
                    # requirement for this construction (and not to the current step of the chain
                    # of learning). The construction of an improvement is gated ONLY by the technology
                    # of the improvement itself (imp_unlock_tech) and by the other conditions
                    # (a harbor, the limit of the labour). The technology of the appearance of the resource
                    # (raw.tech_required) does not affect the construction: since the resource is already
                    # on the hex, its tech_required is met. For example, the quartz
                    # sand is extracted by a quarry ("Stone masonry" is needed),
                    # and not by "Glassmaking", which allows getting the glass from the sand.
                    if not CityData.is_improvement_unlocked(imp_id):
                        var tech_name = _get_tech_name(imp_unlock_tech)
                        enabled = false
                        tooltip = tr("%s — requires technology: %s") % [imp_name, tech_name]
                    # The harbor_access scheme: the improvements with requires_harbor (the fishing boats)
                    # are built only on the water body where there is a harbor. The BFS over the water from
                    # this hex looks for the land with a water_body_harbor improvement.
                    elif bool(imp_data.get("requires_harbor", false)) \
                            and not MapHelpers.has_harbor_access(main_map.tile_data, row, col, main_map.map_rows, main_map.map_cols):
                        enabled = false
                        tooltip = tr("%s — requires a Dock on the shore of this water body") % imp_name
    # The check: the limit of the builds.
                    elif build_manager.get_total_active_builds() >= CityData.total_population:
                        enabled = false
                        tooltip = tr("No work available: construction limit (number of citizens) reached")
                    actions.append({
                        "type": "build_improvement",
                        "label": tr("Build %s") % imp_name,
                        "enabled": enabled,
                        "tooltip": tooltip,
                        "imp_id": imp_id,
                        "target_res_id": tile.resource,
                        "icon": GameData.improvements.get(imp_id, {}).get("icon", "")
                    })

    # 2. An empty hex: the breeding of the domesticated animals/plants.
    if tile.resource == null:
        var breeding_ids: Array = CityData.domesticated_resources.duplicate()
        var suitable_breeding_improvements: Dictionary = {}
        for resource_id in breeding_ids:
            var improvement_id = MapHelpers.get_breeding_improvement(resource_id)
            if improvement_id == "" or not MapHelpers.can_breed_resource_on_tile(resource_id, tile):
                continue
            suitable_breeding_improvements[improvement_id] = true
        for improvement_id in suitable_breeding_improvements:
            var imp_name = GameData.improvements.get(improvement_id, {}).get("name", improvement_id)
            var improvement_unlocked = CityData.is_improvement_unlocked(improvement_id)
            var action_enabled = improvement_unlocked
            var action_tooltip = tr("Build %s for breeding") % imp_name
            if not improvement_unlocked:
                var unlock_tech = CityData.get_improvement_unlock_tech(improvement_id)
                action_tooltip = tr("%s — requires technology: %s") % [imp_name, _get_tech_name(unlock_tech)]
            elif build_manager.get_total_active_builds() >= CityData.total_population:
                action_enabled = false
                action_tooltip = tr("No work available: construction limit (number of citizens) reached")
            actions.append({
                "type": "build_breeding",
                "label": tr("Build %s") % imp_name,
                "enabled": action_enabled,
                "tooltip": action_tooltip,
                "imp_id": improvement_id,
                "icon": GameData.improvements.get(improvement_id, {}).get("icon", "")
            })

    # 3. A harbor (the harbor_access scheme): it opens the water resources of a specific
    #    water body. It is offered on an empty coastal hex (the land with a neighbour of lake/sea,
    #    not a mountain). After the construction the fish of this water body becomes available for
    #    the fishing boats (see has_harbor_access in map_helpers.gd).
    #    There is not enough technology — the construction button is inactive, and next to it there is added
    #    the "Learn ..." button (as for the channel and the forest plot).
    var harbor_potential_tile = tile.resource == null and tile.get("crop_bred", null) == null \
            and tile.terrain != "mountain" and not MapHelpers.is_water_terrain(tile.terrain) \
            and MapHelpers.is_coastal_hex(main_map.tile_data, row, col, main_map.map_rows, main_map.map_cols)
    if harbor_potential_tile:
        var harbor_name = GameData.improvements.get("harbor", {}).get("name", tr("Harbor"))
        var harbor_tech_unlocked = CityData.is_improvement_unlocked("harbor")
        var harbor_unlock_tech = CityData.get_improvement_unlock_tech("harbor")
        var harbor_tooltip = tr("Build %s — unlocks the water resources of this water body") % harbor_name
        # The buttons of the learning and of the construction of the harbor (blocked by a technology)
        # we show only if there are at most TECH_HOPS_MAX "hops" left to the unlocking
        # technology (by analogy with the channel and the forest plot).
        var show_harbor := false
        if harbor_tech_unlocked:
            show_harbor = true
            if build_manager.get_total_active_builds() >= CityData.total_population:
                harbor_tooltip = tr("%s — no work available: construction limit (number of citizens) reached") % harbor_name
        else:
            var harbor_tech_name = _get_tech_name(harbor_unlock_tech)
            harbor_tooltip = tr("%s — requires technology: %s") % [harbor_name, harbor_tech_name]
            if CityData.get_tech_hops(harbor_unlock_tech) <= CityData.TECH_HOPS_MAX:
                show_harbor = true
                var harbor_chain = CityData.get_tech_study_chain(harbor_unlock_tech)
                if not harbor_chain.is_empty():
                    actions.append(_make_research_action(harbor_chain[0], harbor_name))
        if show_harbor:
            actions.append({
                "type": "build_improvement",
                "label": tr("Build %s") % harbor_name,
                "enabled": harbor_tech_unlocked,
                "tooltip": harbor_tooltip,
                "imp_id": "harbor",
                "icon": GameData.improvements.get("harbor", {}).get("icon", "")
            })

    # 4. An irrigation channel (the water_access scheme, the extension "Canals"):
    #    an infrastructure improvement-conductor, distributing the fresh water to the neighbours.
    #    It can be built only on an empty flat dry plot (plain/hill/beach
    #    and any passable non-water terrain) directly next to
    #    a source of the fresh water: a river by a common edge, a lake, a farm/plantation/
    #    a channel with a direct access to the water. The full validation is in MapHelpers.can_build_canal.
    #
    #    The button is shown only where the channel CAN be built subject to the condition
    #    of learning the technology: a suitable terrain + a source of the water next to it.
    #    In the desert the button does not appear - the player is not shown a knowingly
    #    impossible action (by analogy with the quarry, which is visible
    #    only on the hex with its resource). If the technology is missing -
    #    the "Learn ..." button is added next to it.
    var canal_potential_tile = tile.resource == null and tile.get("crop_bred", null) == null \
            and tile.improvement == null and not tile.get("has_town", false) \
            and not tile.get("in_town_influence", false) \
            and tile.terrain != "mountain" \
            and not MapHelpers.is_water_terrain(tile.terrain) \
            and tile.terrain != "swamp" and tile.terrain != "marsh" \
            and MapHelpers.would_canal_have_water(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
    if canal_potential_tile:
        var canal_name = GameData.improvements.get("irrigation_canal", {}).get("name", tr("Irrigation Canal"))
        var canal_icon = GameData.improvements.get("irrigation_canal", {}).get("icon", "")
        var canal_tech_unlocked = CityData.is_improvement_unlocked("irrigation_canal")
        var canal_unlock_tech = CityData.get_improvement_unlock_tech("irrigation_canal")
        var canal_tooltip = tr("Build %s — extends fresh water further") % canal_name
        # The buttons of the learning and of the construction of the channel (blocked by the technology "Canals")
        # we show only if there are at most
        # TECH_HOPS_MAX "hops" left to the unlocking technology of the improvement.
        var show_canal := false
        if canal_tech_unlocked:
            show_canal = true
            if build_manager.get_total_active_builds() >= CityData.total_population:
                canal_tooltip = tr("%s — no work available: construction limit (number of citizens) reached") % canal_name
        else:
            var tech_name = _get_tech_name(canal_unlock_tech)
            canal_tooltip = tr("%s — requires technology: %s") % [canal_name, tech_name]
            if CityData.get_tech_hops(canal_unlock_tech) <= CityData.TECH_HOPS_MAX:
                show_canal = true
                var chain = CityData.get_tech_study_chain(canal_unlock_tech)
                if not chain.is_empty():
                    actions.append(_make_research_action(chain[0], canal_name))
        if show_canal:
            actions.append({
                "type": "build_improvement",
                "label": tr("Build %s") % canal_name,
                "enabled": canal_tech_unlocked,
                "tooltip": canal_tooltip,
                "imp_id": "irrigation_canal",
                "icon": canal_icon
            })
            
    # 4b. A forest plot (lumberjack_hut). It is built on an empty DRY hex
    #     with a forest cover (wood_yield > 0 in covers.json), analogously to the channel:
    #     the button is visible only where the plot CAN be built. If the technology is
    #     missing - the "Learn ..." button is added next to it.
    if MapHelpers.can_build_lumberjack_hut(tile):
        var lj_name = GameData.improvements.get("lumberjack_hut", {}).get("name", tr("Woodcutter's Camp"))
        var lj_icon = GameData.improvements.get("lumberjack_hut", {}).get("icon", "")
        var lj_tech_unlocked = CityData.is_improvement_unlocked("lumberjack_hut")
        var lj_unlock_tech = CityData.get_improvement_unlock_tech("lumberjack_hut")
        var lj_tooltip = tr("Build %s — harvests timber from the forest cover") % lj_name
        var show_lj := false
        if lj_tech_unlocked:
            show_lj = true
            if build_manager.get_total_active_builds() >= CityData.total_population:
                lj_tooltip = tr("%s — no work available: construction limit (number of citizens) reached") % lj_name
        else:
            var lj_tech_name = _get_tech_name(lj_unlock_tech)
            lj_tooltip = tr("%s — requires technology: %s") % [lj_name, lj_tech_name]
            if CityData.get_tech_hops(lj_unlock_tech) <= CityData.TECH_HOPS_MAX:
                show_lj = true
                var lj_chain = CityData.get_tech_study_chain(lj_unlock_tech)
                if not lj_chain.is_empty():
                    actions.append(_make_research_action(lj_chain[0], lj_name))
        if show_lj:
            actions.append({
                "type": "build_improvement",
                "label": tr("Build %s") % lj_name,
                "enabled": lj_tech_unlocked,
                "tooltip": lj_tooltip,
                "imp_id": "lumberjack_hut",
                "icon": lj_icon
            })

    # 5. The special actions (the felling of the forest, the gathering of the wild plants and so on).
    _add_special_actions(actions, row, col, tile)

    # 6. The interruption of whatever is going on this hex: an ordinary build and/or
    # a phased project. These are TWO independent things (for example, a road goes to the hex
    # with a farm, and something else can be built on it), therefore with
    # both of them both buttons are shown, and not one.
    _append_cancel_actions(actions, row, col)

    return actions

# Adds the interruption buttons for everything that is going on the hex (row, col).
#
# The single point for all the branches of _collect_actions. Previously the check of the project lived
# only in two places - on an empty hex and on the hex of a town, - and it was lost on
# the early returns: the hex with an improvement and the hex in the influence ring of a town. The road to
# a hex with an improvement can be built, but it could not be cancelled; the road to the
# town ends in its influence ring, where there was no button either.
func _append_cancel_actions(actions: Array, row: int, col: int) -> void:
    # An ordinary build: the improvements, the special actions (the drainage, the felling, the gathering,
    # the demolition). We take the name of the action from the data of the build, so that the button
    # names what exactly is being interrupted: "Interrupt: Drainage of the marshes", and not "Cancel the
    # build" - by the button the player must understand where he has clicked.
    if build_manager != null and build_manager.is_building(row, col):
        var prog: Dictionary = build_manager.get_progress(row, col)
        var action_name := str(prog.get("imp_name", tr("the construction")))
        actions.append({
            "type": "cancel_build",
            "label": tr("Stop: %s") % action_name,
            "enabled": true,
            "tooltip": tr("Stop \"%s\". Spent work will be lost") % action_name,
            "icon": "cross.svg"
        })

    # A phased project (a road). The button appears on ANY of its hexes, and not
    # only on the target: the player clicks where he sees the build, — on the progress bar of the
    # current segment or on a segment of the ghost.
    if main_map.project_manager == null:
        return
    var project: Dictionary = main_map.project_manager.get_project_at_hex(row, col)
    if project.is_empty():
        return
    actions.append(_make_project_cancel_action(project))

# The cancel button of the going phased project.
#
# We take the name from the project ("Road", "Road to the town "X""), and not write
# the generic "Cancel the build": by the button it must be visible WHAT is being interrupted.
# The number of the remainder is in the button, and not only in the dialog: the player clicks from a hex in the
# middle of the route and must understand BEFORE the click that he cancels the whole road,
# and not one segment. Otherwise the click in the middle of the route looks like a cancellation
# of "just this piece", while everything is cancelled.
func _make_project_cancel_action(project: Dictionary) -> Dictionary:
    var steps: Array = project.get("steps", [])
    var done := int(project.get("step_index", 0))
    var left := maxi(0, steps.size() - done)
    var title := str(project.get("title", tr("Construction")))
    var tooltip := tr("Stop \"%s\"") % title
    if left > 0:
        tooltip += tr(" — unfinished sections: %d") % left
    if done > 0:
        tooltip += tr(". Already built sections (%d) will remain") % done
    return {
        "type": "cancel_project",
        "label": tr("Stop: %s") % title,
        "enabled": true,
        "tooltip": tooltip,
        "project_id": str(project.get("id", "")),
        "icon": "cross.svg"
    }

# The interruption buttons for the actions OUTSIDE the Influence Ring: the scouting and the claiming of the
# territory. It is separate from _append_cancel_actions for a reason: they have no
# improvement on the hex, and they do not go through build_manager.active_builds, and for
# the scouting the expedition is one for the whole time (main_map.is_scouting).
func _append_long_action_cancel(actions: Array, row: int, col: int) -> void:
    if build_manager != null and build_manager.has_method("get_expansion_progress_for_hex"):
        var exp: Dictionary = build_manager.get_expansion_progress_for_hex(row, col)
        if not exp.is_empty():
            var chunk: Array = exp.get("chunk", [])
            actions.append({
                "type": "cancel_expansion",
                "label": tr("Stop: Claiming land"),
                "enabled": true,
                "tooltip": tr("Stop claiming land (%d tiles). Spent work will be lost, paid coins will be refunded") % chunk.size(),
                "icon": "cross.svg"
            })
    if main_map.is_scouting and not main_map.scouting_chunk.is_empty():
        var first = main_map.scouting_chunk[0]
        if first != null and int(first.row) == row and int(first.col) == col:
            actions.append({
                "type": "cancel_scouting",
                "label": tr("Stop: Scouting"),
                "enabled": true,
                "tooltip": tr("Recall the scouts. No hex will be surveyed, paid coins will be refunded"),
                "icon": "cross.svg"
            })

# Adds the special actions (special_actions.json) applicable to the hex.
# Assembles the actions for a hex outside the Influence Ring:
#   the unexplored area - the scouting of a chunk: before the learning of the Cartography
#     only in the unexplored part of the Region, after - on everything
#     reachable by the scrolling of the map (including the fog of war and the territory of the towns);
#     and in both cases the chunk must border the known
#     territory (the Influence Ring or the scouted hexes) - otherwise the button
#     of the scouting is shown inactive with the reason
#     (see main_map.is_chunk_adjacent_to_known);
#   the scouted area - the purchase (the claiming), but ONLY within the Region.
func _collect_region_actions(row: int, col: int) -> Array:
    var actions := []
    # The interruption goes BEFORE all the early returns: the scouting and the claiming are
    # long actions, and the cancel button must appear on the hex of the chunk
    # regardless of whether it is already scouted or not. Previously there was no
    # cancellation here at all - the expedition and the claiming could only be waited for.
    _append_long_action_cancel(actions, row, col)
    var tile = main_map.get_tile_data(row, col)
    if tile == null:
        return actions
    var chunk = main_map.expansion_manager.get_chunk_hexes(row, col)
    if chunk.is_empty():
        # An empty chunk - there are no actions, but the player must understand WHY.
        # For a scouted hex we show an inactive claiming button
        # with a reason; for an unexplored one an empty chunk does not occur.
        if not bool(tile.get("is_explored", false)):
            return actions
        var reason := ""
        if bool(tile.get("in_town_influence", false)):
            reason = tr("Cannot claim: another town's territory")
        elif not main_map.is_valid_hex(row, col):
            reason = tr("Only areas within the Region can be claimed")
        if reason == "":
            return actions
        actions.append({
            "type": "buy_chunk",
            "label": tr("Claim the area"),
            "enabled": false,
            "tooltip": reason,
            "chunk": [],
            "money_cost": 0,
            "work_cost": 0,
            "icon": "check.svg"
        })
        return actions

    var unexplored_count := 0
    for hex in chunk:
        if not main_map.tile_data[hex.row][hex.col].get("is_explored", false):
            unexplored_count += 1

    if unexplored_count > 0:
        # An unexplored chunk: send the scouts. The expedition is paid
        # with COINS from the treasury: the price is the sum over the hexes of the chunk (the base
        # scouting_cost_per_hex and the universal modifier of the distance
        # distance_cost_modifier_per_hex from data/game_balance.json, see
        # expansion_manager.get_chunk_scout_cost).
        var cost = main_map.expansion_manager.get_chunk_scout_cost(chunk)
        var scout_time = main_map._get_scouting_time(unexplored_count)
        # The scouting can be sent only into a chunk bordering the known
        # territory (the Influence Ring or the scouted hexes) - see
        # main_map.is_chunk_adjacent_to_known. The chunk remains assembled at that:
        # the highlighting and the inactive button with a reason explain to the player
        # the rule (the same UX as at the claiming: "The area does not border your
        # holdings" below).
        var known_neighbor: bool = main_map.is_chunk_adjacent_to_known(chunk)
        var tooltip: String
        if main_map.is_scouting:
            tooltip = tr("Scouting already in progress")
        elif not known_neighbor:
            tooltip = tr("The area does not border explored territory")
        elif CityData.ignore_build_requirements:
            # Debug: the scouting is free and instant. The text is static (without
            # the treasury and the time), therefore the convention of _build_actions is not violated.
            tooltip = tr("Send scouts: instantly and free (debug)")
        else:
            # IMPORTANT: do not include the values changing on EVERY TICK
            # (the current treasury, the current stock of the food) in the tooltip. _build_actions() compares
            # the tooltips between the ticks and recreates the buttons on any difference -
            # it resets the hovered tooltip. The treasury the player always sees in the HUD.
            tooltip = tr("Send scouts: %d coins from the treasury, time [%.0f sec.]") % [cost, scout_time]
        actions.append({
            "type": "scout_chunk",
            "label": tr("Send scouts"),
            "enabled": not main_map.is_scouting and known_neighbor,
            "tooltip": tooltip,
            "chunk": chunk,
            "cost": cost,
            "icon": "additional_info.png"
        })
        return actions

    # A scouted chunk: the purchase (the claiming) for the coins from the treasury + the labour.
    var has_neighbor = false
    for hex in chunk:
        for n in HexUtils.get_neighbors_odd_r(hex.row, hex.col, main_map.map_rows, main_map.map_cols):
            if main_map.tile_data[n.row][n.col].get("in_influence", false):
                has_neighbor = true
                break
        if has_neighbor:
            break
    var money_cost = main_map.expansion_manager.get_chunk_money_cost(chunk)
    var work_cost = main_map.expansion_manager.get_chunk_cost(chunk)
    var labor = CityData.get_total_labor()
    var buy_tooltip: String
    if not has_neighbor:
        buy_tooltip = tr("The area does not border your territory")
    elif CityData.ignore_build_requirements:
        # Debug: the claiming is free and instant (see start_scouting - the same
        # principle as in the scouting). The text is static, as _build_actions requires.
        buy_tooltip = tr("Claim the area (%d tiles): instantly and free (debug)") % chunk.size()
    else:
        buy_tooltip = tr("Claim the area (%d tiles): %d coins from the treasury and %d work (%.0f sec.)") % [chunk.size(), money_cost, work_cost, work_cost / max(1.0, labor)]
    actions.append({
        "type": "buy_chunk",
        "label": tr("Claim the area"),
        "enabled": has_neighbor,
        "tooltip": buy_tooltip,
        "chunk": chunk,
        "money_cost": money_cost,
        "work_cost": work_cost,
        "icon": "check.svg"
    })
    return actions

func _add_special_actions(actions: Array, row: int, col: int, tile: Dictionary):
    for sa_id in GameData.special_actions:
        var sa = GameData.special_actions[sa_id]
        var action_type = sa.get("action_type", "terrain")
        var applicable = false
        if action_type == "terrain":
            # A terrain action. source_terrains is a list of the types of the terrain
            # (for example, the drainage of a marsh), or a single source_terrain (the backward
            # compatibility).
            var terrain_list: Array = sa.get("source_terrains", [])
            if terrain_list.is_empty():
                terrain_list = [sa.get("source_terrain", "")]
            applicable = tile.terrain in terrain_list and tile.improvement == null
        elif action_type == "cover":
            var cover_id = tile.get("cover", "none")
            applicable = cover_id in sa.get("source_cover", []) and tile.improvement == null and tile.resource == null
        elif action_type == "forage":
            # The universal action "Gather the resource" for the one-off resources
            # (the wild plants, the metal nuggets and so on). The one-off nature is determined
            # by the flag of the resource itself: improved_by == null (it is not developed
            # by an improvement) and a non-empty produces (there is something to gather).
            var harvest_res_id: String = str(tile.get("resource", ""))
            if harvest_res_id != "" and MapHelpers.is_resource_revealed(tile):
                var harvest_data: Dictionary = GameData.raw_resources.get(harvest_res_id, {})
                var is_one_time: bool = harvest_data.get("improved_by", null) == null
                if is_one_time:
                    var harvest_produces: Dictionary = harvest_data.get("produces", {})
                    if not harvest_produces.is_empty():
                        applicable = true
        elif action_type == "demolish":
            applicable = tile.improvement != null
        elif action_type == "road":
            # The road, which the player builds. The button is shown on the hex to
            # to which there is still no road. The checks here are only the cheap ones (the panel
            # rebuilds the actions on every tick): the hex is dry, there is no improvement with
            # the flag no_road (a road is not built to the irrigation canal by design
            # - see road_manager._find_connect_path), and the hex is not
            # yet connected to the road network of the city.
            # The length of the route and the price are counted by the preview - main_map.get_road_plan.
            applicable = not MapHelpers.is_water_terrain(tile.get("terrain", "plain")) \
                    and not main_map.road_manager.is_hex_connected(row, col)
            if applicable and tile.get("improvement", null) != null:
                var tile_imp: Dictionary = GameData.improvements.get(tile.improvement, {})
                applicable = not bool(tile_imp.get("no_road", false))
            # The road to the hex is already being built (a phased project): we do not create a second
            # queue for the same route, instead of the button there is the cancellation of the project.
            if applicable and main_map.project_manager != null \
                    and main_map.project_manager.has_project_at(row, col):
                applicable = false
        if not applicable:
            continue

        if action_type == "road":
            # At the city: the target is the hex itself. At a town the target is different (the influence
            # ring), there the button is assembled by the branch of the town in _collect_actions.
            _append_special_action(actions, sa_id, sa,
                    tr("Build a road from the city to this hex"))
        else:
            _append_special_action(actions, sa_id, sa)

# The "Improve the road" button for the hex (row, col).
#
# It is shown only when there IS something to improve: there is already a route to the
# city up to the hex, and at least one of its segments is below the best available level. Otherwise
# a button with an unreachable target is a noise in the column of the actions.
#
# The WHOLE route from the city to the hex is improved, and not only the last segment:
# the speed of the route is determined by the narrowest segment (see
# road_manager.find_route_to_city), therefore the improvement of one end gives
# nothing - the player must see this in the tooltip.
func _append_upgrade_road_action(actions: Array, row: int, col: int) -> void:
    if main_map == null or not main_map.has_method("get_route_to_city"):
        return
    var route: Dictionary = main_map.get_route_to_city(row, col)
    if not route.get("ok", false):
        return
    var levels: Array = route.get("levels", [])
    if levels.is_empty():
        return
    var best_level := GameData.get_max_unlocked_road_level()
    # It makes sense to improve as long as there is at least ONE segment on the route below
    # the best level - that is, the MINIMUM is checked, and not the maximum.
    # With the maximum the button hid on a partially improved route: once
    # you improve one segment out of the four, the maximum becomes equal to the best
    # level, and the button disappears - although three trails remain and there is
    # something to improve. Previously it looked like "the route is already improved".
    var worst_level := 999
    for level in levels:
        worst_level = mini(worst_level, int(level))
    if worst_level >= best_level:
        return
    actions.append({
        "type": UPGRADE_ROAD_TYPE,
        "label": tr("Upgrade road"),
        "enabled": true,
        "tooltip": tr("Upgrade the road from this hex to the city to %s (%d units/sec per section)")
                % [GameData.get_road_name(best_level),
                        GameData.get_road_max_speed(best_level)],
        "icon": "road.svg"
    })

# Assembles the button of a special action into the column of the actions: it takes into account the requirement
# of the technology and the common limit of the builds. tooltip_override (if it is set) replaces
# the name in the tooltip - the road uses it, because its text depends on the
# target (an ordinary hex or a town).
func _append_special_action(actions: Array, sa_id: String, sa: Dictionary, tooltip_override: String = "") -> void:
    var sa_name = sa.get("name", sa_id)
    var enabled = true
    var tooltip = tooltip_override if not tooltip_override.is_empty() else sa_name
    var unlock_tech = sa.get("unlock_tech", "")
    if unlock_tech != "" and not CityData.is_tech_unlocked(unlock_tech):
        enabled = false
        tooltip = tr("%s — requires technology: %s") % [sa_name, _get_tech_name(unlock_tech)]
        # The button of the learning of the NEXT unlearned step of the technological
        # chain necessary to unlock the special action (an analogue of
        # the mechanics for the resources/improvements, see _collect_actions).
        var chain = CityData.get_tech_study_chain(unlock_tech)
        if not chain.is_empty():
            actions.append(_make_research_action(chain[0], sa_name))
    elif not CityData.ignore_build_requirements \
            and build_manager.get_total_active_builds() >= CityData.total_population:
        enabled = false
        tooltip = tr("No work available: construction limit (number of citizens) reached")
    actions.append({
        "type": "special",
        "label": sa_name,
        "enabled": enabled,
        "tooltip": tooltip,
        "action_id": sa_id,
        # The icon is taken from special_actions.json (the file name in icons/).
        "icon": sa.get("icon", "")
    })

# Assembles the action "Learn the technology" for the column of the actions of the panel.
# for_what is the reason of the learning, it is substituted into the tooltip (the name of the resource/
# improvement for the resources, or the name of the special action for the actions).
func _make_research_action(tech_id: String, for_what: String = "the resource") -> Dictionary:
    var tech_name = _get_tech_name(tech_id)
    var tech_cost = 3
    for t in GameData.technologies:
        if t["id"] == tech_id:
            tech_cost = int(t.get("science_cost", 3))
            break
    return {
        "type": "research_tech",
        "label": tr("Research %s") % tech_name,
        "enabled": true,
        "tooltip": tr("Research %s (science: %d) to unlock %s") % [tech_name, tech_cost, for_what],
        "tech_id": tech_id,
        "icon": "lock.png"
    }

# --- The handling of a click on an action button ---
func _on_action_pressed(action: Dictionary):
    var type = action.get("type", "")
    if type == "info":
        return
    if type == "open_town":
        # The transition into the interface of the town (the trade). The transition itself is done by
        # main_map.open_town_ui (it hides the HUD and the control panel).
        if _selected_hex != null:
            main_map.open_town_ui(_selected_hex.row, _selected_hex.col)
        return
    if type == "scout_chunk":
        # The scouting of a chunk: we write off the coins from the treasury and send the scouts
        # (the time). The price is counted inside start_scouting - the single source of truth.
        main_map.start_scouting(action.get("chunk", []))
        main_map.redraw_progress_layer()
        _refresh()
        return
    if type == "buy_chunk":
        # The purchase (the claiming) of a chunk: the coins from the treasury at once, the labour accumulates
        # through the build.
        var ok = main_map.expansion_manager.handle_action(
            action.get("chunk", []), action.get("money_cost", 0), action.get("work_cost", 0))
        if ok:
            main_map.map_renderer.queue_redraw()
            if main_map.city_ui.visible:
                main_map.city_ui.refresh()
        _refresh()
        return
    # The actions which are performed at once (without a preview).
    if type == "pause_improvement":
        worker_manager.remove_worker(_selected_hex.row, _selected_hex.col)
        main_map.map_renderer.queue_redraw()
        _refresh()
        return
    if type == "resume_improvement":
        if not worker_manager.assign_worker(_selected_hex.row, _selected_hex.col):
            main_map.hud.show_message(tr("No free workers!"))
        main_map.map_renderer.queue_redraw()
        _refresh()
        return
    if type == "cancel_build":
        main_map.confirm_cancel_build(_selected_hex.row, _selected_hex.col)
        return
    if type == "cancel_project":
        # The project is passed by the id, and not searched by the clicked hex: the button
        # appears on ANY hex of the route, and not only on the target.
        if main_map.project_manager != null:
            main_map.confirm_cancel_project(str(action.get("project_id", "")))
        return
    if type == "cancel_expansion":
        if _selected_hex != null:
            main_map.confirm_cancel_expansion(_selected_hex.row, _selected_hex.col)
        return
    if type == "cancel_scouting":
        if _selected_hex != null:
            main_map.confirm_cancel_scouting(_selected_hex.row, _selected_hex.col)
        return
    if type == "research_tech":
        # An analogue of the item "Learn X" in the context menu (the right click): the instant start
        # of the research. The errors (a research is already going and so on) start_research
        # reports itself through the signal research_error -> hud.show_message.
        CityData.start_research(action.get("tech_id", ""))
        main_map.map_renderer.queue_redraw()
        _refresh()
        return

    # A repeated click on the action button whose preview is already open
    # works as a "cancel" (it closes the preview).
    if _preview_action != null \
            and _preview_action.get("type", "") == type \
            and _preview_action.get("imp_id", "") == action.get("imp_id", "") \
            and _preview_action.get("action_id", "") == action.get("action_id", "") \
            and _preview_action.get("target_res_id", null) == action.get("target_res_id", null):
        clear_preview()
        return

    # The actions with a preview (the construction of an improvement, the breeding, a special action,
    # the improvement of the road).
    #
    # For the improvement of the road eff_res is NOT computed: it is the resource of the hex, which
    # has nothing to do with the improvement of the road. Previously it was substituted into the preview,
    # and the block of the production drew the output of an improvement which the player was not
    # going to build at all.
    var eff_res_for_preview = action.get("target_res_id", null)
    if eff_res_for_preview == null or eff_res_for_preview == "":
        if type != UPGRADE_ROAD_TYPE:
            eff_res_for_preview = MapHelpers.get_effective_resource(
                    main_map.get_tile_data(_selected_hex.row, _selected_hex.col))
    _preview_action = {
        "type": type,
        "imp_id": action.get("imp_id", ""),
        "target_res_id": action.get("target_res_id", null),
        "action_id": action.get("action_id", ""),
        "label": action.get("label", ""),
        "eff_res": eff_res_for_preview,
        "selected_culture_id": null,
        # The default road level is the best available. Exactly it is
        # offered by the rule "by default the most advanced versions are offered"; any other one
        # the player chooses by the button in the preview.
        "road_level": GameData.get_max_unlocked_road_level(),
    }
    _refresh()

# --- The building of the preview of the action ---
func _build_preview(row: int, col: int, tile: Dictionary):
    var preview = _preview_action

    # If the preview for this hex and this action is already built - we do
    # not recreate the elements (incl. the "Start"/"Cancel" buttons with their
    # OS tooltips). Otherwise they would be reset on every game tick.
    var snapshot = {
        "row": row,
        "col": col,
        "type": preview.get("type", ""),
        "label": preview.get("label", ""),
        "imp_id": preview.get("imp_id", ""),
        "action_id": preview.get("action_id", ""),
        "target_res_id": preview.get("target_res_id", null),
        "eff_res": preview.get("eff_res", ""),
        "selected_culture_id": preview.get("selected_culture_id", null),
        # The state of the debug flag enters the snapshot: the toggling of "Ignore
        # of the construction" changes the preview block, and without this field it
        # would have remained old until the reselection of a hex.
        # The road level enters the snapshot as well: a change of the level rebuilds
        # the whole preview block (the price, the number of the segments, the label), and without this field
        # the preview would have remained from the previous level - the player would have seen the price
        # of a trail, and built a cart road.
        "ignore_build": CityData.ignore_build_requirements,
        # The road level enters the snapshot as well: a change of the level rebuilds
        # the whole preview block (the price, the number of the segments, the label), and without this field
        # the preview would have remained from the previous level - the player would have seen the price
        # of a trail, and built a cart road.
        "road_level": int(preview.get("road_level", GameData.get_max_unlocked_road_level())),
    }
    if _preview_equal(_last_preview_snapshot, snapshot):
        return
    _last_preview_snapshot = snapshot

    for child in _preview_container.get_children():
        child.queue_free()
    for child in _preview_header_container.get_children():
        child.queue_free()

    var type = preview.get("type", "")
    var imp_id = preview.get("imp_id", "")
    var action_id = preview.get("action_id", "")
    var eff_res = preview.get("eff_res", "")

    # For the farms/pastures the effective resource is the chosen crop (a plant/animal),
    # and not what lies on the hex at the moment: on an empty hex there is no natural resource,
    # and without this "Will produce" was not shown in the preview.
    if type == "build_breeding":
        var imp_kind_cult = preview.get("imp_id", "")
        var cult_id = preview.get("selected_culture_id", null)
        if not _is_suitable_culture(row, col, cult_id, imp_kind_cult):
            cult_id = _first_suitable_culture(row, col, imp_kind_cult)
            preview["selected_culture_id"] = cult_id
        if cult_id != null:
            eff_res = cult_id

    # The heading row of the preview: the label + the buttons "Start" and "Cancel" (40x40,
    # with the icons of a green check mark / a red cross mark). It is built in a
    # SEPARATE container above PreviewScroll - outside the scrollable area,
    # therefore it is always visible at any position of the scroll.
    var header = HBoxContainer.new()
    header.add_theme_constant_override("separation", 4)
    var header_label = Label.new()
    header_label.text = "%s" % preview.get("label", "")
    header_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    header_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5))
    header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    header.add_child(header_label)
    var build_btn = Button.new()
    build_btn.custom_minimum_size = Vector2(40, 40) # a small square button
    build_btn.tooltip_text = tr("Start")
    build_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    var check_tex = _load_action_icon("check.svg")
    if check_tex != null:
        build_btn.icon = check_tex
        build_btn.expand_icon = true
        build_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
    else:
        build_btn.text = "✓"
    build_btn.pressed.connect(func():
        _confirm_build()
    )
    header.add_child(build_btn)
    var cancel_btn = Button.new()
    cancel_btn.custom_minimum_size = Vector2(40, 40)
    cancel_btn.tooltip_text = tr("Cancel")
    cancel_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    var cross_tex = _load_action_icon("cross.svg")
    if cross_tex != null:
        cancel_btn.icon = cross_tex
        cancel_btn.expand_icon = true
        cancel_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
    else:
        cancel_btn.text = "✕"
    cancel_btn.pressed.connect(func():
        clear_preview()
    )
    header.add_child(cancel_btn)
    _preview_header_container.add_child(header)

    # --- For the breeding: the choice of a specific crop ---
    # The block is placed right below the heading, before the calculations of the production and the cost:
    # the chosen kind is visible first and is not lost at the end of a long list.
    # If several domesticated kinds can be grown/bred on the hex,
    # we let one choose which crop to build for. Otherwise the only
    # suitable crop is built (the current behaviour).
    if type == "build_breeding":
        var imp_kind = preview.get("imp_id", "")
        var crops := _get_suitable_crops(row, col, imp_kind)
        if crops.size() > 1:
            # By default we preselect the first crop from the list.
            var selected = preview.get("selected_culture_id", null)
            if selected == null:
                selected = crops[0].id
                preview["selected_culture_id"] = selected

            var cult_label = Label.new()
            cult_label.text = tr("Culture:")
            cult_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
            cult_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
            _preview_container.add_child(cult_label)

            # The buttons of the crops go in a horizontal row with a wrapping of the rows.
            var cult_flow = FlowContainer.new()
            cult_flow.add_theme_constant_override("h_separation", 4)
            cult_flow.add_theme_constant_override("v_separation", 4)
            _preview_container.add_child(cult_flow)

            for cult in crops:
                var cult_btn = Button.new()
                cult_btn.custom_minimum_size = Vector2(40, 40) # a square button with an icon
                # The tooltip is the name of the resource (an icon without a label).
                cult_btn.tooltip_text = cult.get("name", cult.id)
                # The icon of the domesticated kind; if there is none - a question mark.
                var cult_icon = GameData.raw_resources.get(cult.id, {}).get("icon", "")
                var cult_tex = _load_action_icon(cult_icon)
                if cult_tex != null:
                    cult_btn.icon = cult_tex
                    cult_btn.expand_icon = true
                    cult_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
                else:
                    cult_btn.text = "?"
                cult_btn.toggle_mode = true
                cult_btn.set_pressed_no_signal(cult.id == selected)
                # An explicit frame around the chosen crop.
                var pressed_style = StyleBoxFlat.new()
                pressed_style.set_border_width_all(2)
                pressed_style.border_color = Color(1.0, 0.85, 0.2) # a yellow frame
                cult_btn.add_theme_stylebox_override("pressed", pressed_style)
                cult_btn.add_theme_stylebox_override("hover_pressed", pressed_style)
                cult_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
                var cid = cult.id
                cult_btn.pressed.connect(func():
                    _select_preview_culture(cid)
                )
                cult_flow.add_child(cult_btn)

    # For the special actions the cost is counted by action_id, and not by imp_id.
    var cost_imp_id = imp_id
    if type == "special":
        cost_imp_id = action_id

    # A forest plot on an empty forest hex (eff_res == ""): we show
    # the output of the wood from the cover (wood_yield in covers.json). The future covers
    # with wood_yield > 0 will be picked up automatically.
    if type == "build_improvement" and imp_id == "lumberjack_hut" and eff_res == "":
        var lj_yield: float = MapHelpers.get_cover_wood_yield(tile)
        if lj_yield > 0.0:
            var lj_has_water = MapHelpers.is_hex_irrigated(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
            var lj_mult = CityData.get_improvement_production_multiplier(
                "lumberjack_hut", lj_has_water, tile.get("terrain", ""), "lumberjack_hut")
            var lj_amount = ceili(lj_yield * lj_mult)
            # The display is per second: the output of the cycle, divided by production_interval.
            var lj_interval := CityData.get_improvement_production_interval("lumberjack_hut")
            var lj_per_sec: float = float(lj_amount) / lj_interval
            var wood_data = GameData.products.get("wood", {})
            var wood_icon_path = ""
            if wood_data.has("icon"):
                wood_icon_path = IconRegistry.icon_path(wood_data["icon"])
            var lj_products := []
            lj_products.append({"type": "header", "text": tr("Will produce:")})
            var lj_base_str = str(int(lj_yield)) if lj_yield == floor(lj_yield) else "%.1f" % lj_yield
            var wood_label = wood_data.get("name", tr("Wood"))
            if lj_mult != 1.0:
                wood_label = tr("%s (base %s)") % [wood_label, lj_base_str]
            lj_products.append({"type": "product", "name": wood_label, "amount": lj_per_sec, "icon_path": wood_icon_path, "suffix": " " + TranslationServer.translate("units/sec")})
            var lj_box = VBoxContainer.new()
            map_tooltip.render_products(lj_products, lj_box, true)
            _preview_container.add_child(lj_box)

    # The calculation of the production - only for the CONSTRUCTION of an improvement and the breeding.
    # The types are listed explicitly, and not "everything except the special actions": the improvement of the road
    # is also not special, and under such a condition it landed here and drew "Will
    # produce" on the hex where the improvement already stands. The player clicked the button
    # of the improvement of the road for the road, and the block of the production is a "future"
    # of an improvement which he is not going to build. It also pushed the selector of the road levels
    # down and forced the preview to be scrolled.
    if (type == "build_improvement" or type == "build_breeding") and eff_res != "":
        var res_data = GameData.raw_resources.get(eff_res, {})
        if res_data.has("produces"):
            # The multiplier of the production taking the modifiers into account (the water, the terrain, the technologies).
            var has_water = MapHelpers.is_hex_irrigated(row, col, main_map.tile_data, main_map.map_rows, main_map.map_cols)
            var terrain_id = tile.get("terrain", "")
            var bonus_multiplier = CityData.get_improvement_production_multiplier(imp_id, has_water, terrain_id, eff_res)
            var modifiers = CityData.get_improvement_production_modifiers(imp_id, has_water, terrain_id, eff_res)
            # The display is per second: the output of the cycle, divided by production_interval
            # of the improvement (the field in data/improvements.json).
            var prod_interval := CityData.get_improvement_production_interval(imp_id)

            var products := []
            products.append({"type": "header", "text": tr("Will produce:")})
            for prod_id in res_data["produces"]:
                # produces can be a number or a range [min, max] - in the
                # preview we show the deterministic minimum (see RangeUtils).
                var base_amount = float(RangeUtils.get_min_value(res_data["produces"][prod_id], 1))
                var final_amount = ceili(base_amount * bonus_multiplier)
                var prod_name = GameData.products.get(prod_id, {}).get("name", prod_id)
                # With the active modifiers the base is indicated for each product.
                if bonus_multiplier != 1.0:
                    var base_str = str(int(base_amount)) if base_amount == floor(base_amount) else "%.1f" % base_amount
                    prod_name = tr("%s (base %s)") % [prod_name, base_str]
                var icon_path = ""
                var prod_data = GameData.products.get(prod_id, {})
                if prod_data.has("icon"):
                    var icon_name = prod_data["icon"]
                    icon_path = IconRegistry.icon_path(icon_name)
                products.append({"type": "product", "name": prod_name, "amount": float(final_amount) / prod_interval, "icon_path": icon_path, "suffix": " " + TranslationServer.translate("units/sec")})
            for mod in modifiers:
                products.append({"type": "label", "text": " %s" % mod.get("label", ""), "color": Color(0.7, 0.9, 0.7)})
            # We render into a SEPARATE box: render_products cleans the passed
            # container, therefore we must not give it _preview_container directly -
            # otherwise it erases the block of the choice of the crop, added above.
            var products_box = VBoxContainer.new()
            map_tooltip.render_products(products, products_box, true)
            _preview_container.add_child(products_box)

    # The road (the special action "Build a road") - its own block instead of the common
    # parsing of "terrain/distance": its price depends on the length of the new
    # route, and these multipliers do not apply to the road.
    if type == "special" and _is_road_action(action_id):
        _build_road_level_selector(int(preview.get("road_level", 1)))
        if not _build_road_preview(row, col, action_id):
            # There is no route - there is nothing to confirm, the "Start" button is blocked.
            build_btn.disabled = true
        return

    # The improvement of the road - its own block: the segments already stand, only
    # the difference of the levels is paid, and it is shown by the same scheme as the construction.
    if type == UPGRADE_ROAD_TYPE:
        _build_road_level_selector(int(preview.get("road_level", 1)))
        if not _build_road_upgrade_preview(row, col):
            build_btn.disabled = true
        return

    # The improvement: the road to it is built together with it, therefore its level is
    # the same choice as for "Build a road". We place the selector BEFORE the calculation of the
    # price: the price below includes the surcharge for the road of the chosen level, and without
    # the button the player would not see where this sum came from.
    if type == "build_improvement" or type == "build_breeding":
        _build_road_level_selector(int(preview.get("road_level", 1)))

    # The cost of the labour: the detailed calculation (the base, the terrain, the distance).
    # We take the calculation from main_map - the same source as in build_manager, therefore
    # the preview and the start show one and the same price. The road to the improvement comes
    # from there as well and by separate numbers: it is not included in the price of the improvement itself.
    var road_level := int(preview.get("road_level", 1))
    var cost_data = main_map.get_improvement_work_cost(cost_imp_id, row, col, road_level)
    # The road to the hex is assumed ONLY for the IMPROVEMENT. The special actions (the gathering of the wild plants,
    # the felling of the forest, the drainage, the demolition of an improvement) are performed by an ordinary build and
    # build no roads at all, therefore main_map gives road_applicable =
    # false for them. Drawing the rows about the road for them would mean promising the player a construction
    # which will not happen, and a "Total" - a sum with its price.
    var road_applicable: bool = bool(cost_data.get("road_applicable", false))
    var road_cost := int(cost_data.get("road_cost", 0))
    var road_segments := int(cost_data.get("road_segments", 0))
    var cost_label = Label.new()
    cost_label.text = tr("Improvement: %d work") % cost_data["cost"]
    cost_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    cost_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(cost_label)

    # The road to the improvement is a separate row, always, when the road can be built
    # at all: the player must see how much the second half of the construction
    # will cost, and understand that it is not free (even the base trail). When
    # the road is not needed - the hex is already connected, the improvement with the flag no_road,
    # there is no land route - instead of a zero price we write that there will not be one:
    # "0 of labour" would be read as "for free".
    if road_applicable:
        var road_hint := Label.new()
        if road_segments > 0:
            road_hint.text = tr(" Road to the city (%s): %d work, %d new sections") % [
                    GameData.get_road_name(road_level), road_cost, road_segments]
        elif bool(cost_data.get("road_pending", false)):
            # The road to the hex is already going as a second project (the improvement was refused due to
            # the limit) - we must not show its price a second time, that queue
            # already pays for it.
            road_hint.text = tr(" Road to the city: already under construction")
        else:
            road_hint.text = tr(" Road to the city: not needed")
        road_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        road_hint.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
        _preview_container.add_child(road_hint)

        # The phased nature and the parallel start are visible only by the confirmation, and to talk
        # about them it is needed BEFORE it: otherwise the player waits for the finished road as a whole and does not
        # understand why it appears in pieces.
        if road_segments > 0:
            var road_steps_hint := Label.new()
            road_steps_hint.text = tr(" The road is built in sections, in parallel with the improvement")
            road_steps_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
            road_steps_hint.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
            _preview_container.add_child(road_steps_hint)

    # The details of the cost (it moved here from the extended tooltip).
    var base_label = Label.new()
    base_label.text = tr(" Base: %d work") % cost_data["base_cost"]
    base_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    base_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(base_label)

    var move_cost_text = tr("impassable") if cost_data["move_cost"] >= 999.0 else str(int(cost_data["move_cost"]))
    var terrain_label = Label.new()
    terrain_label.text = tr(" Terrain: %s (move cost: %s) ×%.2f") % [cost_data["terrain_name"], move_cost_text, cost_data["terrain_mult"]]
    terrain_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    terrain_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(terrain_label)

    var dist_label = Label.new()
    # The calculation of the multiplier of the distance: the initial (1 + hexes × the UNIVERSAL
    # modifier of the distance from data/game_balance.json) plus the influence of the learned
    # technologies (for example, "The Wheel" -30%).
    var dist_text: String = tr(" Distance to city: %d hex(es) → base ×%.2f") % [cost_data["distance"], cost_data["distance_mult_base"]]
    if cost_data.has("distance_tech_mult") and cost_data["distance_tech_mult"] != 1.0:
        dist_text += tr(", technology ×%.2f") % cost_data["distance_tech_mult"]
    dist_text += " = ×%.2f" % cost_data["distance_mult"]
    dist_label.text = dist_text
    dist_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    dist_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(dist_label)

    var const_label = Label.new()
    if cost_data.has("construction_tech_mult") and cost_data["construction_tech_mult"] != 1.0:
        const_label.text = tr(" Construction technologies: ×%.2f") % cost_data["construction_tech_mult"]
    else:
        const_label.text = tr(" Construction technologies: ×1.00")
    const_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    const_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(const_label)

    # The total is the improvement PLUS the road to it, therefore the row is only there where
    # the road really is built. Without it there is nothing to sum, and the "Total" would be
    # a copy of the price of the row above (for the special actions it came out exactly so).
    if road_applicable:
        var total_label = Label.new()
        total_label.text = tr(" Total: %d work") % cost_data["total_cost"]
        total_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        total_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
        _preview_container.add_child(total_label)

    # The debug "Ignore building requirements": the price above remains
    # the calculation of "how it would be without the flag", and the action will be performed at once and
    # for free. Without this row the player would see a price and not understand why
    # the progress bar does not appear.
    if CityData.ignore_build_requirements:
        _add_instant_hint()

# A yellow row "it is performed instantly" for the blocks of the preview.
func _add_instant_hint() -> void:
    var hint := Label.new()
    hint.text = tr(" Debug: instant and free")
    hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    hint.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5))
    _preview_container.add_child(hint)

# Synchronises the "ghost" road and the highlighting of the ROUTE on the map with the current
# state of the panel. Three cases, and the order matters:
#   · the preview of the improvement of the road is open — we draw the ghost of the segments being improved
#     (the same style as during the construction, - the segments already stand, but the player must
#     see which one of them is being improved);
#   · the preview "Build a road" is open — we draw the new segments of the plan;
#   · there is no preview — we draw the EXISTING route of the chosen hex to the city.
# The last one is exactly the requirement "on a click on an improvement show the route":
# without an open preview the player sees by which roads exactly his cargo goes.
# It is called from _refresh(), therefore it covers both ESC, and a click on another hex,
# and the confirmation of the construction.
func _sync_road_preview_on_map() -> void:
    if main_map == null or main_map.map_renderer == null or _selected_hex == null:
        _set_map_road_preview({})
        return
    var row := int(_selected_hex.row)
    var col := int(_selected_hex.col)
    var preview_type := ""
    var action_id := ""
    if _preview_action != null:
        preview_type = str(_preview_action.get("type", ""))
        action_id = str(_preview_action.get("action_id", ""))
        if action_id != "" and not _is_road_action(action_id):
            action_id = ""
    if preview_type == UPGRADE_ROAD_TYPE:
        _set_map_road_preview(_get_upgrade_preview_segments(row, col))
        return
    if preview_type == "build_improvement" or preview_type == "build_breeding":
        # The preview of the improvement: we show the route of the road which will be built
        # together with it. The road is an independent phased construction with
        # a separate price, and without its route the row "Road to the city: N of labour"
        # would look inflated or reduced at random. The already built
        # segments do not enter the ghost - there is no need to pay for them.
        _set_map_road_preview(_get_new_road_segments(row, col))
        return
    if action_id != "":
        var plan: Dictionary = main_map.get_road_plan(row, col)
        if not plan.get("ok", false):
            # There is no route (for example, the path to a town is not scouted) - there is
            # nothing to show, the panel has already said this by a row with a reason.
            _set_map_road_preview({})
            return
        _set_map_road_preview(main_map.road_manager.get_plan_new_segments(plan))
        return
    if preview_type != "":
        # The preview of another action is open: we do not show the route, so that the two
        # highlightings do not argue for the map.
        _set_map_road_preview({})
        return
    # The preview is closed: we ALWAYS remove the ghost (otherwise it would hang
    # after ESC), and instead of it we show the existing route of the hex.
    _set_map_road_preview({})
    _set_map_route_display(_get_route_display_segments(row, col))

# The new road segments to the hex - from the plan, by the same way as in the preview
# "Build a road". Empty (and not an error), when the road is not needed: the hex is already
# connected, the improvement with the flag no_road, or there is no land route.
func _get_new_road_segments(row: int, col: int) -> Dictionary:
    if main_map == null or not main_map.has_method("get_road_plan"):
        return {}
    var plan: Dictionary = main_map.get_road_plan(row, col)
    if not plan.get("ok", false):
        return {}
    return main_map.road_manager.get_plan_new_segments(plan)

# The segments of the existing route of the chosen hex - for the highlighting on the map.
# Empty (and not an error) at the hexes without a road, at the city itself, and at the hexes outside
# the influence: there is no route and nothing to show.
func _get_route_display_segments(row: int, col: int) -> Dictionary:
    if not main_map.has_method("get_route_to_city"):
        return {}
    var route: Dictionary = main_map.get_route_to_city(row, col)
    if not route.get("ok", false):
        return {}
    var segments: Dictionary = {}
    for key in route.get("segments", []):
        segments[str(key)] = true
    return segments

# The segments which the confirmed preview "Improve the road" will improve. We take
# the same steps from which the project will then start, - otherwise the highlighting and the real
# build would diverge.
func _get_upgrade_preview_segments(row: int, col: int) -> Dictionary:
    var segments: Dictionary = {}
    var road_level := int(_preview_action.get("road_level", 1))
    var breakdown: Dictionary = main_map.get_road_upgrade_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        return segments
    for step in breakdown.get("steps", []):
        for key in step.get("ghost", {}).keys():
            segments[str(key)] = true
    return segments

func _set_map_road_preview(segments: Dictionary) -> void:
    if main_map == null or main_map.map_renderer == null:
        return
    main_map.map_renderer.set_road_preview_segments(segments)
    # The highlighting of the route and the ghost of the preview must not burn simultaneously:
    # these are different meanings (the existing route vs. what will be built).
    if not segments.is_empty():
        main_map.map_renderer.set_route_segments({})

func _set_map_route_display(segments: Dictionary) -> void:
    if main_map == null or main_map.map_renderer == null:
        return
    main_map.map_renderer.set_route_segments(segments)

# Is this action a road (the special action build_road)?
func _is_road_action(action_id: String) -> bool:
    if action_id != ROAD_ACTION_ID:
        return false
    return str(GameData.special_actions.get(action_id, {}).get("action_type", "")) == "road"

# --- The choice of the road level ---
# One button per RESEARCHED level, from the best to the worst. A common block
# for the three cases - "Build a road", the construction of an improvement (the road to it
# is built together with it) and "Improve the road": the rule of the choice is the same one, and therefore
# the look is the same as well.
#
# The button shows the level CLEARLY (the trail has "free"), otherwise the player does not
# understand why its click costs nothing.
func _build_road_level_selector(selected_level: int) -> void:
    var levels: Array = GameData.get_unlocked_road_levels()
    if levels.size() <= 1:
        # There is nothing to choose: only the base level is available. A silent skip
        # is better than a greyed-out button - the player sees the only option in the price anyway.
        return

    var label := Label.new()
    label.text = tr("Road level:")
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(label)

    var flow := FlowContainer.new()
    flow.add_theme_constant_override("h_separation", 4)
    flow.add_theme_constant_override("v_separation", 4)
    _preview_container.add_child(flow)

    for i in range(levels.size() - 1, -1, -1):
        var level := int(levels[i])
        var level_name := GameData.get_road_name(level)
        var cost := GameData.get_road_work_cost(level)
        var speed := GameData.get_road_max_speed(level)
        var btn := Button.new()
        btn.toggle_mode = true
        btn.set_pressed_no_signal(level == selected_level)
        # The tooltip carries both figures of the level: the price of a segment and the throughput
        # capacity. Without them the "Cart Road" button explains nothing.
        btn.tooltip_text = tr("%s: up to %d units/sec per section, base %d work per section") % [level_name, speed, cost]
        var shown_name: String = level_name if cost > 0 \
                else tr("%s (free)") % level_name
        btn.text = shown_name
        # An explicit frame around the chosen level - after the pattern of the choice of the crop.
        var pressed_style = StyleBoxFlat.new()
        pressed_style.set_border_width_all(2)
        pressed_style.border_color = Color(1.0, 0.85, 0.2)
        btn.add_theme_stylebox_override("pressed", pressed_style)
        btn.add_theme_stylebox_override("hover_pressed", pressed_style)
        btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
        var chosen := level
        btn.pressed.connect(func():
            _select_preview_road_level(chosen)
        )
        flow.add_child(btn)

# The choice of the road level in the preview. The level is written into _preview_action, and the preview
# is rebuilt: the snapshot includes road_level (see _build_preview), therefore
# the block does not remain from the previous level.
func _select_preview_road_level(level: int):
    if _preview_action == null:
        return
    _preview_action["road_level"] = level
    _refresh()

# The preview block for the improvement of the road: which segments and up to which level, and
# how much it costs. It returns false if there is nothing to improve - then the
# "Start" button is blocked, and the player sees the reason.
func _build_road_upgrade_preview(row: int, col: int) -> bool:
    var road_level := int(_preview_action.get("road_level", 1))
    var breakdown: Dictionary = main_map.get_road_upgrade_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        var warn := Label.new()
        warn.text = " %s" % str(breakdown.get("reason", tr("Nothing to upgrade")))
        warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        warn.add_theme_color_override("font_color", Color(0.9, 0.6, 0.6))
        _preview_container.add_child(warn)
        return false

    var target_label := Label.new()
    target_label.text = tr(" Destination: from the city to this hex along the existing road")
    target_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    target_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(target_label)

    var cost_label := Label.new()
    cost_label.text = tr(" Cost: %d work") % int(breakdown.get("cost", 0))
    cost_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    cost_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(cost_label)

    var base_label := Label.new()
    base_label.text = tr(" Base: %d work per section") % GameData.get_road_work_cost(road_level)
    base_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    base_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(base_label)

    var sections_label := Label.new()
    sections_label.text = tr(" Sections to upgrade: %d") % int(breakdown.get("segments", 0))
    sections_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    sections_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(sections_label)

    if CityData.ignore_build_requirements:
        _add_instant_hint()
    return true

# The preview block for the road: where the route will go, how many segments it
# consists of, and how much labour it is. It returns false if there is no route - then
# the "Start" button is blocked, and the player sees the reason.
func _build_road_preview(row: int, col: int, action_id: String) -> bool:
    var road_level := int(_preview_action.get("road_level", 1))
    var plan: Dictionary = main_map.get_road_plan(row, col)
    if not plan.get("ok", false):
        var warn := Label.new()
        warn.text = " %s" % str(plan.get("reason", tr("Cannot build a road")))
        warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        warn.add_theme_color_override("font_color", Color(0.9, 0.6, 0.6))
        _preview_container.add_child(warn)
        return false

    # Where the road will go. At a town the target is not its hex itself, but the roads of its
    # influence ring (see road_manager.plan_road_to).
    var target_label := Label.new()
    if bool(plan.get("is_town", false)):
        var town = null
        if main_map.town_manager != null:
            town = main_map.town_manager.find_town_at(row, col)
        var town_name := str(town.get("name", tr("the town"))) if town != null else tr("the town")
        target_label.text = tr(" Destination: the nearest road in the town \"%s\" influence ring") % town_name
        # The route may turn out to be longer than a "direct" road: it goes only
        # over the scouted territory - exactly by the way the player got to
        # the town. Without this row a price 2-3 times higher than the expected one looks like
        # an error.
        target_label.text += tr(" (only across scouted territory)")
    else:
        target_label.text = tr(" Destination: from the city's nearest road to this hex")
    target_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    target_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(target_label)

    # The prices and the steps are from the SINGLE source (main_map.get_road_cost_breakdown),
    # from which the project will then start. The total here is equal to the sum of the prices of the segments
    # by construction, and it is not recalculated separately.
    # The type is specified explicitly: main_map in the panel is not typed, and without the hint
    # Godot cannot deduce the type of the return of a dynamic call.
    var breakdown: Dictionary = main_map.get_road_cost_breakdown(row, col, road_level)
    if not breakdown.get("ok", false):
        var warn2 := Label.new()
        warn2.text = " %s" % str(breakdown.get("reason", tr("Cannot build a road")))
        warn2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        warn2.add_theme_color_override("font_color", Color(0.9, 0.6, 0.6))
        _preview_container.add_child(warn2)
        return false

    var cost_label := Label.new()
    cost_label.text = tr(" Cost: %d work") % int(breakdown.get("cost", 0))
    cost_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    cost_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(cost_label)

    # The prices of the segments are DIFFERENT: each has its own terrain and its own distance from
    # the city. Therefore we show a range, and not a single number - otherwise the player sees
    # on the map segments with very different progress bars and does not understand why.
    var min_step := int(breakdown.get("min_step_cost", 0))
    var max_step := int(breakdown.get("max_step_cost", 0))
    var step_text := tr(" Per section: %d work") % min_step
    if max_step != min_step:
        step_text = tr(" Per section: %d to %d work") % [min_step, max_step]
    step_text += tr(" (base %d)") % GameData.get_road_work_cost(road_level)
    var step_label := Label.new()
    step_label.text = step_text
    step_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    step_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(step_label)

    var segments_label := Label.new()
    segments_label.text = tr(" New route sections: %d") % int(breakdown.get("segments", 0))
    segments_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    segments_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
    _preview_container.add_child(segments_label)

    # The distance: carrying the materials to the distant hexes is more expensive. A range by the
    # route, because the segments go from the network to the target and get further from the city.
    var min_dist := int(breakdown.get("min_distance", 0))
    var max_dist := int(breakdown.get("max_distance", 0))
    var dist_label := Label.new()
    var dist_text := tr(" Distance to city: %d hex(es)") % min_dist
    if max_dist != min_dist:
        dist_text = tr(" Distance to city: %d to %d hex(es)") % [min_dist, max_dist]
    dist_text += tr(" → base ×%.2f…×%.2f") % [
        MapHelpers.get_road_distance_mult(min_dist),
        MapHelpers.get_road_distance_mult(max_dist)]
    dist_label.text = dist_text
    dist_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    dist_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
    _preview_container.add_child(dist_label)

    # The terrains on the route with the multipliers: it explains the second half of the price.
    # Without this row "why is it so expensive" remains unanswered, when the route
    # goes through a marsh or the mountains.
    var terrain_ids: Array = breakdown.get("terrains", [])
    if not terrain_ids.is_empty():
        var parts: Array[String] = []
        for tid in terrain_ids:
            var tname: String = str(GameData.terrains.get(tid, {}).get("name", tid))
            parts.append("%s ×%.2f" % [tname, MapHelpers.get_terrain_work_mult(tid)])
        var terr_label := Label.new()
        terr_label.text = tr(" Terrain on the route: %s") % ", ".join(parts)
        terr_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        terr_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
        _preview_container.add_child(terr_label)

    # How exactly the construction will go: the road is built BY SEGMENTS - one hex at a time,
    # with a progress bar on the current segment. Without this row the player waits for the finished
    # road as a whole and does not understand, why it appears in pieces.
    var steps_hint := Label.new()
    steps_hint.text = tr(" Will be built in sections: one hex at a time")
    steps_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    steps_hint.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
    _preview_container.add_child(steps_hint)

    # The debug "Ignore building requirements" - the same row as in the
    # ordinary preview: the route is laid entirely and without waiting.
    if CityData.ignore_build_requirements:
        _add_instant_hint()
    return true

# Compares two snapshots of the preview block by the significant fields.
func _preview_equal(a: Dictionary, b: Dictionary) -> bool:
    return a.get("row", -1) == b.get("row", -1) \
        and a.get("col", -1) == b.get("col", -1) \
        and a.get("type", "") == b.get("type", "") \
        and a.get("label", "") == b.get("label", "") \
        and a.get("imp_id", "") == b.get("imp_id", "") \
        and a.get("action_id", "") == b.get("action_id", "") \
        and a.get("target_res_id", null) == b.get("target_res_id", null) \
        and a.get("eff_res", "") == b.get("eff_res", "") \
        and a.get("selected_culture_id", null) == b.get("selected_culture_id", null) \
        and int(a.get("road_level", 1)) == int(b.get("road_level", 1)) \
        and a.get("ignore_build", false) == b.get("ignore_build", false)

# The confirmation of the construction from the preview.
func _confirm_build():
    if _selected_hex == null or _preview_action == null:
        return
    var row = _selected_hex.row
    var col = _selected_hex.col
    var preview = _preview_action
    var type = preview.get("type", "")
    var imp_id = preview.get("imp_id", "")
    var target_res_id = preview.get("target_res_id", null)
    var action_id = preview.get("action_id", "")
    var road_level = int(preview.get("road_level", GameData.get_max_unlocked_road_level()))

    if type == "build_improvement":
        build_manager.start_build(row, col, imp_id, target_res_id, road_level)
    elif type == "build_breeding":
        # We build the chosen improvement for the crop; if the crop is not set or
        # does not fit, we take the first suitable one.
        var breeding_imp = preview.get("imp_id", "")
        var chosen_animal = preview.get("selected_culture_id", null)
        if not _is_suitable_culture(row, col, chosen_animal, breeding_imp):
            chosen_animal = _first_suitable_culture(row, col, breeding_imp)
        if chosen_animal != null:
            build_manager.start_build(row, col, breeding_imp, chosen_animal, road_level)
    elif type == UPGRADE_ROAD_TYPE:
        main_map.start_road_upgrade_project(row, col, road_level)
    elif type == "special":
        build_manager.start_build(row, col, action_id, null, road_level)

    # After the confirmation we reset the preview, but we keep the selection.
    _preview_action = null
    main_map.map_renderer.queue_redraw()
    main_map.redraw_progress_layer()
    _refresh()

# --- The helpers ---
# The name of the technology by id - the single source in CityData (see get_tech_name).
func _get_tech_name(tech_id: String) -> String:
    return CityData.get_tech_name(tech_id)

# Returns the list of the domesticated crops which can be bred through
# the specified improvement on the hex (row, col).
# Each element: { "id": String, "name": String }.
func _get_suitable_crops(row: int, col: int, imp_kind: String) -> Array:
    var tile = main_map.get_tile_data(row, col)
    var ids: Array
    ids = CityData.domesticated_resources.duplicate()
    var out := []
    for id in ids:
        var data = GameData.raw_resources.get(id, {})
        # breedable and the biome of the breeding are checked by a single helper; in particular,
        # it takes into account the additional conditions of the field resource.breeding.
        if not MapHelpers.can_breed_resource_by(id, imp_kind):
            continue
        if not MapHelpers.can_breed_resource_on_tile(id, tile):
            continue
        out.append({"id": id, "name": data.get("name", id)})
    return out

# Returns true, if the crop (a plant/animal) fits the hex (row, col)
# and is a part of the domesticated kinds allowed by the specified improvement.
func _is_suitable_culture(row: int, col: int, id, imp_kind: String) -> bool:
    if id == null or id == "":
        return false
    var tile = main_map.get_tile_data(row, col)
    var data = GameData.raw_resources.get(id, {})
    if data.is_empty():
        return false
    var ids: Array = CityData.domesticated_resources.duplicate()
    # breedable: false (for example, the fish) - the direct confirmation of the breeding is impossible.
    if not MapHelpers.can_breed_resource_by(id, imp_kind):
        return false
    if not (id in ids):
        return false
    return MapHelpers.can_breed_resource_on_tile(id, tile)

# Returns the id of the first domesticated kind that fits the hex, or null.
func _first_suitable_culture(row: int, col: int, imp_kind: String):
    var crops := _get_suitable_crops(row, col, imp_kind)
    if crops.is_empty():
        return null
    return crops[0].id

# Selects the crop in the active preview (a farm/pasture) and rebuilds the block,
# so that the highlighting of the chosen button is updated.
func _select_preview_culture(id: String):
    if _preview_action != null:
        _preview_action["selected_culture_id"] = id
        # We synchronise the effective resource, so that the block "Will produce"
        # in the preview is recalculated under the new crop.
        var t = _preview_action.get("type", "")
        if t == "build_breeding":
            _preview_action["eff_res"] = id
    _refresh()
