@tool
extends "res://scripts/main_map/hud.gd"

# This link — the windows over the map: the city and the town interfaces, the trade they run, the
# journal and the pause menu with the saves.

# The width of the body of the window of a reward. A wrapping text asks no width of its own, so the
# window is given the one the news is read in.
const CHALLENGE_NEWS_WIDTH := 660
# The mark of a reward line, the same the tab of the challenges puts before what a task gives.
const REWARD_MARK := "• "

func open_city():
    city_ui.refresh()
    city_ui.show()
    city_ui.show_resources_tab()
    hud.hide()
    # The control panel of the hex is not needed while the interface of the city is open.
    control_panel.hide()

func _on_city_button_pressed():
    if pause_menu.visible:
        return
    city_button.disabled = false
    open_city()

func _on_city_ui_close():
    city_ui.hide()
    hud.show()
    # We return the control panel of the hex on the exit from the interface of the city.
    control_panel.show()
    _update_research_progress()

# Opens the interface of the town (the window of the trade) for the hex (row, col).
# It is called from the control panel (the action button on the hex of the town) and
# from InputHandler (a double click on the hex of the town).
#
# The access to the interface does NOT depend on the road: a scouted town can
# always be opened — there one can see what it has for sale and for purchase.
# The road gates only the trade (see town_manager.is_trade_available), and the window
# passes that availability on to its rows: without a road they are inert and the trade
# settings panel cannot be opened at all (town_ui._can_trade), while the status row
# under the name of the town says why.
func open_town_ui(row: int, col: int):
    var town = find_town_at(row, col)
    if town == null:
        return
    town_ui.open_town(town, town_manager.is_trade_available(town))
    # The HUD stays visible so the player can see the treasury while trading, but its
    # buttons are disabled (see _process). The control panel of the hex is not needed
    # while the interface of the town is open.
    control_panel.hide()

# The rows of the "Trade partners" column of the city interface: every town the player has
# discovered (its hex lies in the known territory or has been scouted, see
# town_manager.is_town_discovered), with the distance from the city in hexes and the state of
# the road link. A town without a road is NOT hidden: the road gates the trade itself
# (town_manager.is_trade_available), while the column shows what the player has already found.
func get_trade_partners() -> Array:
    var result: Array = []
    if town_manager == null:
        return result
    for town in town_manager.get_discovered_towns(tile_data):
        var row := int(town.get("row", -1))
        var col := int(town.get("col", -1))
        result.append({
            "id": str(town.get("id", "")),
            "name": str(town.get("name", "")),
            "row": row,
            "col": col,
            "color": town.get("border_color", []),
            "distance": HexUtils.hex_distance(city_row, city_col, row, col),
            "trade_available": town_manager.is_trade_available(town),
        })
    return result

# The rows of the "Trade deals" column of the city interface: the standing
# contracts with the towns (see town_trade_manager). The one-time purchases still on
# the road are a list of their own (get_town_deliveries): the two kinds of a deal
# differ in what the row can do, so the column asks for them separately and lays
# them out together.
func get_town_contracts() -> Array:
    if town_trade_manager == null:
        return []
    return town_trade_manager.get_contracts()

# The one-time purchases whose goods are still on the road (see
# town_trade_manager.get_deliveries): what the player bought and the road has not carried
# to the city yet. The column lists them beside the contracts, because the un-shipped part
# of such a deal can be cancelled from there.
func get_town_deliveries() -> Array:
    if town_trade_manager == null:
        return []
    return town_trade_manager.get_deliveries()

# Cancels a one-time purchase of a town (see town_trade_manager.cancel_delivery): the part
# that has not been shipped goes back into the warehouse of the town and its coins back into
# the treasury. The column calls this directly, the way it reads get_town_deliveries: it
# needs the answer to report it in the message row of the city interface — the HUD is hidden
# while the city interface is open.
func cancel_town_delivery(town_id: String, product_id: String) -> Dictionary:
    if town_trade_manager == null:
        return {"ok": false, "message": ""}
    return town_trade_manager.cancel_delivery(town_id, product_id)

# The standing contract of a town for a good, or an empty dictionary when there is none
# (see town_trade_manager.get_contract). The town window reads it to open the trade
# settings of a good that already carries a contract as an EDIT of that contract instead
# of a fresh signing — one town carries one contract per good.
func get_town_contract(town_id: String, product_id: String) -> Dictionary:
    if town_trade_manager == null:
        return {}
    return town_trade_manager.get_contract(town_id, product_id)

# Edits the amount of the standing contract of a town for a good from the "Trade deals"
# column of the city interface. The price of the deal stays frozen (see
# town_trade_manager.submit_order, which turns an order for a pair that already carries a
# contract into an edit of it). The column calls this directly, the way it reads
# get_town_contracts: it needs the answer to report it in the message row of the city
# interface — the HUD is hidden while the city interface is open.
func update_town_contract(town_id: String, product_id: String, amount: int) -> Dictionary:
    if town_trade_manager == null:
        return {"ok": false, "message": ""}
    # An amount edit only: the direction of the deal is a term of the contract and is not
    # an order of the window (see town_trade_manager.update_contract_amount).
    return town_trade_manager.update_contract_amount(town_id, product_id, amount)

# Closes the standing contract of a town from the "Trade deals" column (see
# town_trade_manager.close_contract). The good becomes free for a new deal.
func close_town_contract(contract_id: String) -> Dictionary:
    if town_trade_manager == null:
        return {"ok": false, "message": ""}
    return town_trade_manager.close_contract(contract_id)

func _on_town_ui_close():
    town_ui.hide()
    # The HUD buttons are re-enabled automatically (see _process): the flag
    # `town_ui.visible` becomes false, so `hud_blocked` clears on the next frame.
    # We return the control panel of the hex on the exit from the interface of the town.
    control_panel.show()

# The town window assembled a buy/sell order and handed it over (town_ui.
# trade_order_submitted). The order is a dictionary with town_id, town_name, row,
# col, side ("buy"/"sell"), product_id, product_name, amount, permanent (bool),
# route_capacity (units/sec) and unit_price (coins per unit, the number the row
# and the total of the panel showed) — see town_ui._on_confirm_pressed for the
# exact shape.
#
# This handler is the router: the mechanics live in town_trade_manager, and their
# answer is reported by the HUD. The trade panel of the window stays open over its
# row and says nothing about the outcome: the HUD is visible whether the window, the
# city interface or nothing at all is open, so a deal and a contract are announced in
# one place only.
func _on_town_trade_order(order: Dictionary) -> void:
    if town_trade_manager == null:
        return
    var result: Dictionary = town_trade_manager.submit_order(order)
    var message := str(result.get("message", ""))
    if not message.is_empty():
        var msg_type := GameData.HUD_MESSAGE_NORMAL if result.get("ok", false) else GameData.HUD_MESSAGE_IMPORTANT
        hud.show_message(message, msg_type)

# A standing contract with a town was torn (the treasury could not pay it, or the
# town ran out of the goods). The HUD is the channel that works whether the town
# window, the city interface or nothing at all is open.
func _on_town_trade_notice(message: String) -> void:
    if not message.is_empty():
        hud.show_message(message, GameData.HUD_MESSAGE_IMPORTANT)

# The town window asked to close the standing contract it is editing. The window hands the
# id over and claims nothing about the outcome: the mechanics live in town_trade_manager and
# the answer is reported by the HUD, exactly as the reply to an order is.
func _on_town_contract_close_requested(contract_id: String) -> void:
    if town_trade_manager == null:
        return
    var result: Dictionary = town_trade_manager.close_contract(contract_id)
    var message := str(result.get("message", ""))
    if not message.is_empty():
        var msg_type := GameData.HUD_MESSAGE_NORMAL if result.get("ok", false) else GameData.HUD_MESSAGE_IMPORTANT
        hud.show_message(message, msg_type)

func _on_town_delivery_cancel_requested(town_id: String, product_id: String) -> void:
    if town_trade_manager == null:
        return
    var result: Dictionary = town_trade_manager.cancel_delivery(town_id, product_id)
    var message := str(result.get("message", ""))
    if not message.is_empty():
        var msg_type := GameData.HUD_MESSAGE_NORMAL if result.get("ok", false) else GameData.HUD_MESSAGE_IMPORTANT
        hud.show_message(message, msg_type)

func _on_research_completed(tech_id: String):
    map_renderer.queue_redraw()
    # Cartography changes which hexes the highlighting may cover.
    highlight_layer.queue_redraw()
    _redraw_progress_layer()
    # We show the window of the learned technology and pause the game,
    # so that the player cannot interact with the map and the HUD while the window is open.
    if tech_popup and tech_popup.has_method("show_tech"):
        get_tree().paused = true
        tech_popup.show_tech(tech_id, CityData.last_research_messages)
    # The messages are passed into the popup — we clear them.
    CityData.last_research_messages = []

# The city has earned a pick of a specialization (CityData.specialization_choice_offered): the
# window of the choice opens over everything and the simulation stops until the player picks. The
# window closes itself on the last pick of the queue and resumes the world through
# apply_pause_state.
func _on_specialization_choice_offered() -> void:
    if specialization_popup == null or specialization_popup.visible:
        return
    specialization_popup.open()

# The end of a task of the era stops the world only when the city has earned something: the reward
# was not promised in advance, and it arrives with the era. A lost task is news, not an
# interruption — the manager says it in the HUD and the journal, and the tab keeps the reason. The
# window is queued, because the closing of an era judges every live task at once.
func _on_era_challenge_completed(challenge: Dictionary) -> void:
    _queue_challenge_news(challenge)

func _queue_challenge_news(challenge: Dictionary) -> void:
    _challenge_news_queue.append({
        "title": tr("Challenge completed"),
        "record": challenge,
    })
    _show_next_challenge_news()

func _show_next_challenge_news() -> void:
    if challenge_news_dialog == null or challenge_news_dialog.visible:
        return
    if _challenge_news_queue.is_empty():
        return
    var news: Dictionary = _challenge_news_queue.pop_front()
    challenge_news_dialog.title = str(news.get("title", ""))
    _set_challenge_news_body(news.get("record", {}))
    challenge_news_dialog.popup_centered()
    apply_pause_state()

# The body reads as the plate of the tab that promised the task: the name of it in the colour of the
# text, what the task asked muted, and what the city earned as the bullet of a reward. The words come
# from the manager, the colours from the palette of the moment the window is filled.
func _set_challenge_news_body(record: Dictionary) -> void:
    _challenge_news_record = record
    var lines: Array[String] = []
    for line in challenge_manager.challenge_news_lines(record):
        lines.append(_challenge_news_line(str(line.get("kind", "")), str(line.get("text", ""))))
    challenge_news_body.text = "\n".join(lines)

# A palette chosen while the window stands open has to reach the lines it was filled with: the colour
# of a tag is the number of the palette of the moment the text was written.
func _refresh_challenge_news_body() -> void:
    if challenge_news_dialog != null and challenge_news_dialog.visible:
        _set_challenge_news_body(_challenge_news_record)

func _challenge_news_line(kind: String, text: String) -> String:
    match kind:
        "flavor":
            return _colored_news_line(text, UI_THEME.color("text_muted"))
        "reward":
            return _colored_news_line(REWARD_MARK + text, UI_THEME.color("income"))
        _:
            # The name of the task wears the colour of the text, as the name of a plate on the tab.
            return text

static func _colored_news_line(text: String, color: Color) -> String:
    return "[color=#%s]%s[/color]" % [color.to_html(false), text]

# The window hides before the queue is read again: the flag is recomputed for the world without it,
# and the next news stops it again if there is one left. The next window waits a frame — a popup
# opened in the same call that closed its predecessor finds the viewport of the game still active.
func _on_challenge_news_visibility_changed() -> void:
    if challenge_news_dialog.visible:
        return
    apply_pause_state()
    _show_next_challenge_news.call_deferred()

func _on_tech_popup_go_to_techs():
    # We unpause and open the interface of the city on the tab "Technologies"
    city_ui.refresh()
    city_ui.show_technologies_tab()
    city_ui.show()
    hud.hide()
    # The control panel of the hex is not needed while the interface of the city is open.
    control_panel.hide()

func _on_pause_save():
    # The menu stays open behind the window: the player picks the place and the name,
    # and comes back to the menu, not to the game.
    if save_load_window == null or save_load_window.visible:
        return
    save_load_window.open_save(CityData.city_name)

func _on_pause_menu_visibility_changed():
    var menu_visible = pause_menu.visible
    city_button.disabled = menu_visible
    expansion_button.disabled = menu_visible
    # The HUD buttons are disabled by _process while the tree is paused, but _process does
    # not run at all then — the menu has to close them by hand, like the two above.
    journal_button.disabled = menu_visible
    menu_button.visible = not menu_visible
    pause_button.visible = not menu_visible
    # The settings menu is shown by the pause menu over it: the button of the active
    # pause would stay visible without the mode being reachable through it.
    if active_pause != null and settings_menu and settings_menu.visible:
        pause_button.visible = false

# THE OWNER of the flag of the pause of the tree. Five independent things stop the
# simulation: the pause menu, the active pause, the journal window, the choice of a specialization
# and the news of a task of the era, and any of them may be on while the others are not. The menu
# therefore must not switch the flag off on its own — closing it over a stopped world has to leave
# the world stopped.
func apply_pause_state():
    get_tree().paused = (active_pause != null and active_pause.is_active()) \
            or pause_menu.visible or journal_ui.visible \
            or (specialization_popup != null and specialization_popup.visible) \
            or (challenge_news_dialog != null and challenge_news_dialog.visible)

# The journal is a window over the map: opening it stops the simulation, because the
# player is reading, not playing. The pause flag itself is recomputed, not written: the
# active pause may be on as well, and closing the journal must not resume a world the
# player has stopped on purpose.
func open_journal():
    if journal_ui == null or journal_ui.visible:
        return
    journal_ui.open_journal()
    apply_pause_state()

func close_journal():
    if journal_ui == null or not journal_ui.visible:
        return
    journal_ui.close_journal()

func _on_journal_closed():
    apply_pause_state()

func open_pause_menu():
    pause_menu.show()
    city_button.disabled = true
    expansion_button.disabled = true
    journal_button.disabled = true
    # We pause the game while the menu of the pause is open
    apply_pause_state()

func toggle_active_pause():
    # The button and the space bar call exactly this one function. The mode is a
    # mode and nothing else: it does not close the opened windows and does not open
    # the pause menu.
    if active_pause == null:
        return
    active_pause.set_active(not active_pause.is_active())

func _on_active_pause_changed(_active: bool):
    _refresh_pause_button()
    if pause_menu.visible:
        # The mode is hidden together with the menu button — while the pause menu
        # is open, the player leaves the mode by ESC.
        pause_button.visible = false
        return
    if active_pause.is_active():
        hud.show_message(tr("The simulation is stopped. Your actions are queued until you resume it."), GameData.HUD_MESSAGE_NORMAL)
    else:
        var queued: Array = active_pause.labels()
        if queued.is_empty():
            hud.show_message(tr("The simulation resumed."), GameData.HUD_MESSAGE_NORMAL)
        else:
            hud.show_message(tr("The simulation resumed. Starting: %s") % ", ".join(queued), GameData.HUD_MESSAGE_NORMAL)

func _on_menu_button_pressed():
    if pause_menu.visible:
        return
    open_pause_menu()

func _on_pause_load():
    # The pause is lifted only when the player has chosen a save and the scene is about
    # to reload: cancelling the window returns to the menu, not to the running game.
    if save_load_window == null or save_load_window.visible:
        return
    save_load_window.open_load()

func _on_save_requested(slot_id: String, save_name: String):
    if not SaveManager.save_game(slot_id, save_name):
        hud.show_message(tr("Could not save the game."), GameData.HUD_MESSAGE_IMPORTANT)
        return
    save_load_window.close()
    hud.show_message(tr("Game saved."), GameData.HUD_MESSAGE_NORMAL)

func _on_load_requested(slot_id: String):
    if not SaveManager.load_game(slot_id):
        hud.show_message(tr("Could not load the game."), GameData.HUD_MESSAGE_IMPORTANT)
        return
    save_load_window.close()
    # The scene is replaced right away: the menu must not keep the tree stopped.
    pause_menu.hide()
    get_tree().paused = false
    get_tree().reload_current_scene()

func _on_pause_new_game():
    # The item of the menu of the pause does not create a new game, but returns to the main menu.
    get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

# The jump from the "Trade partners" column of the city interface: the city window is closed, the
# map is centered on the town and the window of that town is opened right away — the player asked
# to go to the town in order to trade with it, so landing next to it without the interface would
# only make them look for the hex again. The closing goes through the ordinary path
# (city_ui.close_city), so the HUD, the panel of the hex and the tooltips return exactly as on
# the "X" button; open_town_ui then hides the control panel of the hex, as on any other opening of
# the town window.
func _on_town_focus_requested(row: int, col: int) -> void:
    city_ui.close_city()
    center_on_hex(row, col)
    open_town_ui(row, col)

func _on_expansion_button_pressed():
    # The "Development" button no longer has any functionality
    pass

func _on_expansion_mode_changed(_active: bool):
    # Toggling the mode drops current_chunk without emitting chunk_hovered.
    highlight_layer.queue_redraw()
    map_renderer.queue_redraw()
