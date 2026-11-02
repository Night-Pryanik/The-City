@tool
extends "res://scripts/main_map/builds.gd"

# This link — the long actions that occupy the map for a while: the scouting of a chunk and the
# cancellation of the scouting and of the claiming of the land.

func _get_scouting_time(hex_count: int) -> float:
    return hex_count * SCOUTING_TIME_PER_HEX

func start_scouting(chunk: Array):
    if is_scouting or (active_pause != null and active_pause.has_pending_key("scouting")):
        hud.show_message(tr("Scouting already in progress!"), GameData.HUD_MESSAGE_IMPORTANT)
        return
    # An empty chunk — there is nothing to scout. A control check for the public
    # entry point: otherwise the treasury would be "written off" for 0 coins, and is_scouting
    # would hang on an empty chunk (the bar of the scouting without hexes).
    if chunk.is_empty():
        return
    # A safety repetition of the rule: before the learning of the Cartography the scouting
    # is limited by the unexplored part of the Region. The chunk comes from
    # expansion_manager.get_chunk_hexes (it already observes this), but
    # start_scouting is a public entry point: the chunk can come here by another
    # way, and sending the scouts into the fog of war without the Cartography is not allowed.
    if not is_cartography_researched():
        for hex in chunk:
            if not is_valid_hex(hex.row, hex.col):
                hud.show_message(tr("Scouting beyond the Region requires the technology \"%s\"")
                        % get_cartography_tech_name(), GameData.HUD_MESSAGE_IMPORTANT)
                return
    # A safety repetition of the rule "the scouting only into a chunk, adjacent to
    # the known territory" (see is_chunk_adjacent_to_known). The UI does not activate such a button,
    # but the refusal must be here as well — BEFORE the write-off of the coins and the start of
    # the timer, so that the price and the actual action do not diverge.
    if not is_chunk_adjacent_to_known(chunk):
        hud.show_message(tr("The chunk does not border explored territory — scout the neighbouring hexes first"), GameData.HUD_MESSAGE_IMPORTANT)
        return
    # The expedition waits for the resume of the simulation while the active pause is
    # on. The intercept is placed BEFORE the write-off of the coins. The key is not
    # the hex: there is one expedition at a time in the whole world, so a second
    # "send the scouts" while the first one waits must be refused.
    if active_pause != null and active_pause.intercept({
            "key": "scouting",
            "label": tr("Send the scouts"),
            "row": chunk[0].row,
            "col": chunk[0].col,
            "bar_color": UI_THEME.color("info").darkened(0.2),
            "bar_offset": 16,
            "execute": func(): start_scouting(chunk),
    }):
        return
    # The price of the expedition is NOT accepted as a parameter: the single source of truth is
    # expansion_manager.get_chunk_scout_cost() (the base and the modifier of the distance
    # from data/game_balance.json). Otherwise the UI and the actual write-off could
    # diverge. The payment is by the coins of the treasury of the city, at once.
    # Debug: with "Ignore building requirements" enabled the scouting
    # is free and instant — the coins are not written off, the timer is not started,
    # the chunk is opened by the same _complete_scouting() as at an ordinary finish.
    var expedition_cost: int = expansion_manager.get_chunk_scout_cost(chunk)
    if not CityData.ignore_build_requirements:
        if not CityData.spend_treasury(expedition_cost):
            hud.show_message(tr("Not enough coins in the treasury! Need %d, treasury has %d")
                    % [expedition_cost, CityData.treasury], GameData.HUD_MESSAGE_IMPORTANT)
            return
        # The source of the expense for the tooltip "Treasury" (see show_treasury_tooltip).
        # The one-off costs of the scouting are event-based, they are not in the plan, therefore the breakdown
        # of the expenses shows the fact over the last display window.
        if expedition_cost > 0:
            CityData.record_treasury_expense(GameData.SRC_SCOUTING, expedition_cost)
    scouting_chunk = chunk
    scouting_timer = 0.0
    if CityData.ignore_build_requirements:
        # The instant finish: we do not even turn on is_scouting, otherwise for one frame
        # the progress bar of the scouting would flash, which the player does not have time to see.
        _complete_scouting()
        return
    is_scouting = true
    _redraw_progress_layer()
    hud.show_message(tr("Scouts sent... (%d coins paid from the treasury)") % expedition_cost, GameData.HUD_MESSAGE_NORMAL)

func _complete_scouting():
    for hex in scouting_chunk:
        tile_data[hex.row][hex.col]["is_explored"] = true
    # The scouting has opened the new hexes — the plans of the roads could have changed (the route to the
    # town goes only over the scouted land), therefore the cache of the plans is reset.
    road_manager.bump_map_knowledge()
    var info = _get_chunk_info(scouting_chunk)
    hud.show_message(tr("Scouting complete! %s") % info, GameData.HUD_MESSAGE_NORMAL)
    is_scouting = false
    scouting_chunk = []
    # The scouting removes the fog of war from the hexes, therefore the fill of the rings of the towns
    # on the opened territory must appear — the cache of the renderer is rebuilt.
    map_renderer.invalidate_town_influence_cache()
    map_renderer.queue_redraw()
    _redraw_progress_layer()

# The common part of the dialogs of the cancellation: the pause for the time of the question, the localized button
# of the confirmation and the obligatory unpause, if the window was closed by the cross
# (an AcceptDialog has no signal canceled).
func _show_cancel_dialog(dialog: AcceptDialog, on_confirm: Callable) -> void:
    var was_paused = get_tree().paused
    get_tree().paused = true
    dialog.process_mode = Node.PROCESS_MODE_ALWAYS
    dialog.confirmed.connect(func():
        if not was_paused:
            get_tree().paused = false
        on_confirm.call()
    )
    add_child(dialog)
    dialog.popup_centered()
    dialog.visibility_changed.connect(func():
        if not dialog.visible and not was_paused:
            get_tree().paused = false
    )

# The cancellation of the claiming of the territory from the hex (row, col) — exactly that one, where
# the progress bar of the claiming is drawn (the first hex of the chunk). The coins written off at the start
# are returned: they paid for the joining of the chunk to the Influence Ring, and it did not
# happen. The labour is lost — that is the price of the refusal.
func confirm_cancel_expansion(row: int, col: int):
    if build_manager == null:
        return
    var data: Dictionary = build_manager.get_expansion_progress_for_hex(row, col)
    if data.is_empty():
        return
    var chunk: Array = data.get("chunk", [])
    var dialog = AcceptDialog.new()
    dialog.title = tr("Cancel claiming")
    var text := tr("Stop claiming land (%d tiles)?\n\n") % chunk.size()
    text += tr("Spent work (%.0f/%d) will be lost.") % [
        float(data.get("progress", 0.0)), int(data.get("work_cost", 0))]
    var money_cost := int(data.get("money_cost", 0))
    if money_cost > 0:
        text += tr("\n\nThe %d coins already paid will be returned to the treasury.") % money_cost
    else:
        text += tr("\n\nNo coins were deducted for the claim.")
    dialog.dialog_text = text
    dialog.get_ok_button().text = tr("Yes")
    _show_cancel_dialog(dialog, func():
        if build_manager.cancel_expansion_at_hex(row, col):
            _after_cancel_long_action())

# The cancellation of the scouting. The expedition in the game is one for the whole time (main_map.is_scouting),
# therefore the button appears on the hex of its chunk, and the timer itself is reset.
# As with the claiming: the money for the start is returned, the time of the expedition — no.
func confirm_cancel_scouting(row: int, col: int):
    if not is_scouting or scouting_chunk.is_empty():
        return
    var first = scouting_chunk[0]
    if first == null or int(first.row) != row or int(first.col) != col:
        return
    var chunk: Array = scouting_chunk
    var dialog = AcceptDialog.new()
    dialog.title = tr("Cancel scouting")
    var text := tr("Recall the scouts?\n\nNone of the %d tiles will be surveyed.") % chunk.size()
    if not CityData.ignore_build_requirements:
        text += tr("\n\nThe %d coins paid will be returned to the treasury.") % expansion_manager.get_chunk_scout_cost(chunk)
    dialog.dialog_text = text
    dialog.get_ok_button().text = tr("Yes")
    _show_cancel_dialog(dialog, func():
        cancel_scouting())

# Interrupts the scouting: the timer is zeroed, the chunk is forgotten, the money for the start
# is returned. The fog is NOT removed from the chunk — the scouting is applied entirely in
# _complete_scouting, it has no intermediate state.
func cancel_scouting() -> bool:
    if not is_scouting or scouting_chunk.is_empty():
        return false
    var chunk: Array = scouting_chunk.duplicate()
    is_scouting = false
    scouting_chunk = []
    scouting_timer = 0.0
    if not CityData.ignore_build_requirements:
        var cost: int = expansion_manager.get_chunk_scout_cost(chunk)
        if cost > 0:
            CityData.add_treasury(cost)
            CityData.record_treasury_expense(GameData.SRC_SCOUTING, -cost)
    hud.show_message(tr("Scouting cancelled"), GameData.HUD_MESSAGE_NORMAL)
    _after_cancel_long_action()
    return true

# The actions after the cancellation of the claiming/scouting: in both of them the progress bar disappears, and
# _process will no longer redraw the layer, if it was the last
# active build.
func _after_cancel_long_action() -> void:
    map_renderer.queue_redraw()
    _redraw_progress_layer()
    control_panel.refresh()

func _get_chunk_info(chunk: Array) -> String:
    return MapHelpers.get_chunk_info(chunk, tile_data)
