@tool
extends "res://scripts/main_map/actions.gd"

# This link — the readouts over the map: the labels of the HUD, the clock, the frame rate
# counter, the research button, the tooltip of the treasury, the hex tooltip entry points and the
# settings of the interface that feed them.

func update_tooltip_text(row: int, col: int):
    # The insurance of the public entry point: for a hex in the fog of war the tooltip is not
    # filled in at all (the main gate is in InputHandler._handle_mouse_motion,
    # where the foggy hex does not become "hovered" at all). Otherwise after
    # the hover delay a tooltip with the contents of the previous hex would float up.
    if is_hex_in_fog(row, col):
        return
    map_tooltip.update_tooltip_text(row, col, tile_data, city_row, city_col)

# Returns the id of the improvement which can be built on the hex (row, col),
# or an empty string, if the construction is impossible.
func _get_buildable_improvement(row: int, col: int) -> String:
    return MapHelpers.get_buildable_improvement(tile_data[row][col])

# Returns true, if for the hex the extended tooltip has to be shown (the properties of
# the hex, the production, the consumption, the road level). The conditions are not listed
# here: they are asked of the same assembler, which builds the block itself, — see
# MapTooltip.has_extended_tooltip_info.
func has_extended_tooltip_info(row: int, col: int) -> bool:
    return map_tooltip.has_extended_tooltip_info(row, col, tile_data)

# Whether the tooltip on this hex must be refreshed while the mouse stays on it: the content
# changes over time (a growing resource or the delivery — see MapTooltip.has_live_content).
# The decision lives in MapTooltip, so the refresh and the block cannot drift apart.
func has_live_content(row: int, col: int) -> bool:
    return map_tooltip.has_live_content(row, col, tile_data)

func update_extended_tooltip(row: int, col: int):
    map_tooltip.update_extended_tooltip(row, col, tile_data, city_row, city_col)

# Resets the binding of the extended block of the tooltip to the hex (see
# MapTooltip.clear_extended_tooltip). It is called on a change of the hex and on the hiding of
# the tooltip — otherwise the return to the same hex would draw the extended block immediately,
# bypassing the hover delay.
func clear_extended_tooltip():
    map_tooltip.clear_extended_tooltip()

# Updates the HUD label that shows the era the player is currently in.
# The era name is read from GameData.eras and translated via tr(); no year is shown,
# since the game has no calendar mechanic yet.
func _update_era_label() -> void:
    var year_label = hud.get_node_or_null("VBoxContainer/YearLabel")
    if not year_label:
        return
    var era_index = CityData.current_era_index
    var era_name = ""
    if era_index >= 0 and era_index < GameData.eras.size():
        era_name = str(GameData.eras[era_index].get("name", ""))
    year_label.text = tr(era_name)

func _setup_research_hud():
    # We create the panel of the research: a button with the icon of the technology + a progress bar.
    # We place it between the label of the date and the "City" button.
    var vbox = hud.get_node("VBoxContainer")
    research_hbox = HBoxContainer.new()
    research_hbox.add_theme_constant_override("separation", 4)

    research_button = Button.new()
    research_button.custom_minimum_size = Vector2(36, 24)
    research_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    research_button.text = ""
    # We put the icon as a child TextureRect, and not through Button.icon.
    # The reason: a PNG 64×64 in a button 36×24 is stretched/crops, and in Godot
    # 4.7 there is neither icon_scale, nor icon_max_width, nor a normal way
    # to limit the size of Button.icon. Its own TextureRect with custom_minimum_size
    # = 24×24 solves the problem once and for all.
    var inner = HBoxContainer.new()
    inner.name = "InnerBox"
    inner.set_anchors_preset(Control.PRESET_FULL_RECT)
    inner.alignment = BoxContainer.ALIGNMENT_CENTER
    inner.add_theme_constant_override("separation", 2)
    inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
    research_button.add_child(inner)

    research_icon = TextureRect.new()
    research_icon.name = "TechIcon"
    research_icon.custom_minimum_size = Vector2(24, 24)
    research_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    research_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    research_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    research_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
    research_icon.visible = false
    inner.add_child(research_icon)

    research_label = Label.new()
    research_label.name = "TechLabel"
    research_label.text = "?"
    research_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    research_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    research_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    research_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
    research_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    inner.add_child(research_label)

    research_button.tooltip_text = tr("Select a technology to research")
    research_button.pressed.connect(_on_research_hud_button_pressed)
    research_hbox.add_child(research_button)

    research_progress_bar = ProgressBar.new()
    research_progress_bar.custom_minimum_size = Vector2(120, 12)
    research_progress_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    research_progress_bar.max_value = 100.0
    research_progress_bar.value = 0.0
    research_progress_bar.show_percentage = false
    research_hbox.add_child(research_progress_bar)

    # We insert after YearLabel (the date), before CityButton.
    var year_label = vbox.get_node("YearLabel")
    vbox.add_child(research_hbox)
    vbox.move_child(research_hbox, year_label.get_index() + 1)

    _update_research_progress()
    _update_era_label()

func _update_research_progress():
    if research_button == null or research_progress_bar == null:
        return
    var tech_id = CityData.current_research_tech_id
    if tech_id == "":
        # Nothing is being researched — we attract the attention with red.
        # We must definitely hide the icon, otherwise the old technology sticks out on the button.
        if research_icon:
            research_icon.visible = false
            research_icon.texture = null
        if research_label:
            research_label.visible = true
            research_label.text = "!"
        research_button.tooltip_text = tr("No technology is being researched. Click to select a technology")
        research_progress_bar.value = 0.0
        research_progress_bar.modulate = Color.WHITE
        _apply_research_button_warning(true)
        _last_research_hud_tech = ""
        return

    # The technology is being researched — we show the icon (if there is one) and the progress.
    var tech_data = null
    for t in GameData.technologies:
        if t["id"] == tech_id:
            tech_data = t
            break
    if tech_data:
        research_button.tooltip_text = tr("Researching: %s") % tech_data.get("name", tech_id)
        var icon_name: String = tech_data.get("icon", "")
        if icon_name != "" and research_icon:
            var path = IconRegistry.icon_path(icon_name)
            if path != "":
                var tex = load(path)
                if tex:
                    research_icon.texture = tex
                    research_icon.visible = true
                    # We hide the Label, so that the HBox does not reserve a place for it.
                    # Otherwise the icon "sticks" to the left edge of the button,
                    # and on the right — an empty area under the hidden label.
                    if research_label:
                        research_label.visible = false
                else:
                    research_icon.visible = false
                    if research_label:
                        research_label.visible = true
                        research_label.text = "?"
            else:
                research_icon.visible = false
                if research_label:
                    research_label.visible = true
                    research_label.text = "?"
        else:
            if research_icon:
                research_icon.visible = false
            if research_label:
                research_label.visible = true
                research_label.text = "?"
    else:
        if research_icon:
            research_icon.visible = false
        if research_label:
            research_label.visible = true
            research_label.text = "?"
        research_button.tooltip_text = tr("A technology is being researched")
    _apply_research_button_warning(false)

    if CityData.current_research_science_cost > 0:
        research_progress_bar.value = CityData.research_progress * 100.0
    else:
        research_progress_bar.value = 0.0
    research_progress_bar.modulate = Color.WHITE
    _last_research_hud_tech = tech_id

func _apply_research_button_warning(warning: bool):
    # The red frame/highlighting in the absence of a research.
    var normal = StyleBoxFlat.new()
    normal.bg_color = UI_THEME.color("control_hover")
    normal.set_border_width_all(2)
    if warning:
        normal.border_color = UI_THEME.color("expense")
    else:
        normal.border_color = UI_THEME.color("panel_border")
    research_button.add_theme_stylebox_override("normal", normal)
    # We override hover/pressed/focus with the same style, so that on hover
    # the content margins do not change and the size of the button remains the same.
    research_button.add_theme_stylebox_override("hover", normal)
    research_button.add_theme_stylebox_override("pressed", normal)
    research_button.add_theme_stylebox_override("focus", normal)
    if warning:
        research_button.add_theme_color_override("font_color", UI_THEME.color("expense"))
    else:
        research_button.add_theme_color_override("font_color", UI_THEME.color("text"))

func _on_research_hud_button_pressed():
    # The transition to the interface of the city on the tab "Technologies".
    if pause_menu.visible:
        return
    city_ui.refresh()
    city_ui.show_technologies_tab()
    city_ui.show()
    hud.hide()
    # The control panel of the hex is not needed while the interface of the city is open.
    control_panel.hide()

func _on_research_error(message: String, message_type: int = 1):
    if city_ui.visible:
        city_ui.set_message(message)
    else:
        hud.show_message(message, message_type)

# The tilesets replaced some icons: the map draws from its own copy of the textures, and the
# pause button is the one icon of the HUD that is set by hand.
func _on_icons_changed() -> void:
    map_renderer.load_icons()
    map_renderer.queue_redraw()
    _refresh_pause_button()

func _refresh_pause_button():
    # The button states the mode by its own name: the same button stops and resumes
    # the simulation, and the tooltip names the hotkey.
    pause_button.visible = not pause_menu.visible
    if active_pause == null:
        return
    # The icon shows what the click will DO: the bars while the simulation runs, the
    # triangle while it is stopped. It is the same button in both states.
    var stopped: bool = active_pause.is_active()
    pause_button.icon = IconRegistry.get_texture(
            "building_resume.png" if stopped else "building_pause.png")
    pause_button.tooltip_text = tr("Resume the simulation (SPACE)") if stopped \
            else tr("Stop the simulation. Your actions are queued until you resume it (SPACE)")

func _load_settings():
    var previous_show_hex_borders: bool = show_hex_borders
    var err = settings_config.load("user://settings.cfg")
    if err == OK:
        show_hex_borders = settings_config.get_value("interface", "show_hex_borders", true)
        use_edge_scrolling = settings_config.get_value("interface", "edge_scrolling", true)
        edge_scroll_speed = settings_config.get_value("interface", "edge_scroll_speed", 300.0)
        tooltip_delay = settings_config.get_value("interface", "tooltip_delay", 0.5)
        extended_tooltip_delay = settings_config.get_value("interface", "extended_tooltip_delay", 1.0)
        building_detail_delay = settings_config.get_value("interface", "building_detail_delay", 0.5)
        resource_display_interval = settings_config.get_value("game", "resource_display_interval", 1.0)
        hud_message_duration = settings_config.get_value("interface", "hud_message_duration", 3.0)
        show_clock = settings_config.get_value("interface", "show_clock", true)
        show_fps = settings_config.get_value("interface", "show_fps", true)
        set_zoom(settings_config.get_value("interface", "zoom", 1.0))
    else:
        show_hex_borders = true
        use_edge_scrolling = true
        edge_scroll_speed = 300.0
        tooltip_delay = 0.5
        extended_tooltip_delay = 1.0
        building_detail_delay = 0.5
        resource_display_interval = 1.0
        hud_message_duration = 3.0
        show_clock = true
        show_fps = true
        set_zoom(1.0)
    # The flag is baked into the recorded hex commands, and the map is redrawn on demand:
    # without a request the new value would only show up after an unrelated redraw.
    if show_hex_borders != previous_show_hex_borders and map_renderer != null:
        map_renderer.queue_redraw()

func apply_settings():
    _load_settings()
    input_handler.set_tooltip_delay(tooltip_delay)
    input_handler.set_extended_tooltip_delay(extended_tooltip_delay)
    input_handler.set_scroll_speed(edge_scroll_speed)
    city_ui.set_building_detail_delay(building_detail_delay)
    hud.set_message_duration(hud_message_duration)
    _apply_clock_visibility()
    _apply_fps_visibility()
    # set_resource_display_interval raises the era on a change of the value — we immediately
    # pick it up and update the HUD label of the treasury, so that the player sees the effect
    # of the new interval without waiting for the nearest city_updated.
    CityData.set_resource_display_interval(resource_display_interval)
    _treasury_display_epoch = CityData.resource_display_epoch
    _update_treasury_hud()

# The rebuild of the interface after a change of the language.
#
#
# LocalizationManager has already translated the scenes by this moment (Godot does it itself
# on the notification of TranslationServer) and RE-READ the data of the game — therefore here
# it is enough to call the refresh() of each screen: they rebuild the nodes
# with their own text and take the names from the already translated data.
#
# The research button and the HUD labels assemble the text in the code, therefore they are updated
# explicitly. The panel of the hex and of the town know how to update even in the closed form.
func _on_locale_changed(_locale: String) -> void:
    if city_ui:
        city_ui.refresh()
    if control_panel:
        control_panel.refresh()
    if town_ui and town_ui.has_method("_refresh"):
        town_ui._refresh()
    if tech_popup and tech_popup.has_method("refresh"):
        tech_popup.refresh()
    if specialization_popup and specialization_popup.has_method("refresh"):
        specialization_popup.refresh()
    _update_research_progress()
    _update_population_hud()
    _update_treasury_hud()
    _update_era_label()
    map_renderer.queue_redraw()

func _on_population_changed(_new_pop: int):
    _update_population_hud()

func _on_famine_death(new_pop: int) -> void:
    if hud != null:
        hud.show_message(tr("A citizen has died of starvation. Population: %d") % new_pop, GameData.HUD_MESSAGE_IMPORTANT)

func _update_population_hud():
    var pop_label = hud.get_node_or_null("VBoxContainer/PopulationLabel")
    if pop_label:
        pop_label.text = tr("Population: %d") % CityData.total_population

# Updates the label of the treasury in the HUD (below the block of the game time). It is called
# from _ready (the start/loading), from apply_settings (a change of the interval) and from
# _on_city_data_updated (the tick path with the check of the era of the display).
# It captures CityData.treasury into _displayed_treasury — this same cache
# is used by the tooltip of the breakdown of the treasury (see _show_treasury_tooltip), so that
# the label and the tooltip show one value, without "running ahead" by 1+ ticks.
func _update_treasury_hud():
    _displayed_treasury = CityData.treasury
    var treasury_label = hud.get_node_or_null("VBoxContainer/TreasuryLabel")
    if treasury_label:
        # The dynamics of the profit/expense — the same fact as in the tooltip of the breakdown
        # (CityData.get_treasury_flow_text), but per second. It is counted at the same
        # rate of the update as the balance, — the numbers do not flicker every tick.
        treasury_label.text = tr("Treasury: %s %s") % [
            UiHelpers.money(str(_displayed_treasury)), CityData.get_treasury_flow_text()
        ]
        # The panel of the HUD in the scene is of a fixed width, and the row grows together with
        # balance — we recalculate the width under the new text, otherwise a long row
        # would crawl out onto the map and the hover on the "tail" would stop working.
        if hud.has_method("refresh_size"):
            hud.refresh_size()

# The wall clock in the top right corner of the HUD: the real local time, HH:MM.
# The visibility follows the setting "Interface → Show clock"; the text is set by the
# timer created in _setup_clock (it keeps ticking while the tree is paused).
func _setup_clock() -> void:
    _apply_clock_visibility()
    if _clock_timer != null and is_instance_valid(_clock_timer):
        return
    _clock_timer = Timer.new()
    _clock_timer.name = "ClockTimer"
    _clock_timer.process_mode = Node.PROCESS_MODE_ALWAYS
    _clock_timer.wait_time = 1.0
    _clock_timer.autostart = true
    _clock_timer.timeout.connect(_update_clock)
    add_child(_clock_timer)

func _apply_clock_visibility() -> void:
    if clock_label:
        clock_label.visible = show_clock
        if show_clock:
            # The label comes back with the text of the scene ("00:00"): the timer would
            # fix it within a second, but the player should see the real time at once.
            _update_clock()
    _fit_top_right_panel()

# The visibility of the frame rate counter follows the setting
# "Interface → Show FPS counter".
func _apply_fps_visibility() -> void:
    if fps_label:
        fps_label.visible = show_fps
    _fit_top_right_panel()

# The top right panel is anchored to the right edge and takes the size of its
# contents. A fixed width would either leave an empty strip over the map (the
# panel blocks the map hover under it) or cut the buttons off, as the font is a
# setting of the player.
func _fit_top_right_panel() -> void:
    if not top_right_box or not top_right_panel:
        return
    var content: Vector2 = top_right_box.get_combined_minimum_size()
    var panel_size := Vector2(
        ceilf(content.x), maxf(content.y, TOP_RIGHT_PANEL_MIN_HEIGHT))
    # The offsets are set directly: both anchors of the panel sit on the right edge,
    # and position is measured from the left of the viewport, not from the anchor.
    top_right_panel.offset_left = -TOP_RIGHT_MARGIN - panel_size.x
    top_right_panel.offset_right = -TOP_RIGHT_MARGIN
    top_right_panel.offset_bottom = panel_size.y

func _update_clock() -> void:
    if not clock_label or not clock_label.visible:
        return
    var now: Dictionary = Time.get_time_dict_from_system()
    clock_label.text = "%02d:%02d" % [now["hour"], now["minute"]]

# The standard tooltip instance of the map. The town window takes it for the group rows
# of its purchase column, so the composition of a group is shown by the same panel as
# everywhere else instead of a copy of its own (see town_ui._get_ui_helpers).
func get_ui_helpers() -> Node:
    return _map_ui_helpers

# Creates a CanvasLayer + the Control-host and instantiates ui_helpers for the
# HUD tooltips (the breakdown of the treasury and the future ones). It is added to the tree once in
# _ready; the repeated calls are a no-op. It is moved out into a separate method, so as not to
# overload _ready.
func _setup_hud_tooltip_layer():
    if _map_ui_helpers != null and is_instance_valid(_map_ui_helpers):
        return
    var layer := CanvasLayer.new()
    layer.name = "HUDTooltipLayer"
    layer.layer = 100 # over the HUD (the HUD as a Panel on the main scene)
    add_child(layer)
    var host := Control.new()
    host.name = "HUDTooltipHost"
    host.set_anchors_preset(Control.PRESET_FULL_RECT)
    host.mouse_filter = Control.MOUSE_FILTER_IGNORE
    layer.add_child(host)
    _map_ui_helpers = load("res://scripts/ui_helpers.gd").new()
    _map_ui_helpers.setup(host, null)
    layer.add_child(_map_ui_helpers)

# The cursor is now over the label of the treasury of the HUD — exactly and only this starts
# the hover timer of "sticking" the tooltip of the breakdown. If the HUD is hidden (the interface of the
# city is open), the label is not considered hovered, even if its rectangle coincided with
# the position of the cursor.
func _is_treasury_label_hovered(mouse_pos: Vector2) -> bool:
    if not (hud and is_instance_valid(hud)) or not hud.visible:
        return false
    var treasury_label = hud.get_node_or_null("VBoxContainer/TreasuryLabel")
    return is_instance_valid(treasury_label) \
        and treasury_label.get_global_rect().has_point(mouse_pos)

# Returns true, if the cursor is now over the label of the treasury or over the active
# (including "stuck") tooltip of the breakdown (this is needed, so that on the transition of the
# cursor from the label to the tooltip the tooltip does not blink — the leave fires only by
# grace).
func _is_treasury_hovered(mouse_pos: Vector2) -> bool:
    if _is_treasury_label_hovered(mouse_pos):
        return true
    if _map_ui_helpers and is_instance_valid(_map_ui_helpers) \
            and _map_ui_helpers.treasury_tooltip_panel \
            and _map_ui_helpers.treasury_tooltip_panel.visible \
            and _map_ui_helpers.treasury_tooltip_panel.get_global_rect().has_point(mouse_pos):
        return true
    return false

# The cursor is now over the shown ("stuck") tooltip of the breakdown of the treasury of the HUD layer.
# The tooltip covers the map, and the map under it must not react to the cursor:
# neither the tooltip of the hex, nor the highlighting of the chunk, nor the clicks/selection, nor the scrolling by the edges
# (see InputHandler.handle_input / handle_process). The treasury label is not
# checked here: it lies inside the HUD, and it is covered by the check "the cursor is over the HUD".
func is_mouse_over_treasury_tooltip(pos: Vector2) -> bool:
    if not (_map_ui_helpers and is_instance_valid(_map_ui_helpers)):
        return false
    var panel: Panel = _map_ui_helpers.treasury_tooltip_panel
    if not is_instance_valid(panel) or not panel.visible:
        return false
    return panel.get_global_rect().has_point(pos)

# Shows the tooltip of the breakdown of the treasury under the cursor (the HUD variant). The data is from
# worker_manager (the planned income by the sources) and CityData (a snapshot of the expenses
# over the window). It is analogous to the method in city_ui.gd (see _show_treasury_tooltip there).
# keep_position=true — the live-update of the already shown ("stuck") tooltip:
# the panel stays in place. It returns true if the tooltip is visible in the end
# (an empty breakdown hides the panel — then there is no "sticking").
func _show_treasury_tooltip(mouse_pos: Vector2, keep_position: bool = false) -> bool:
    if not worker_manager:
        return false
    var planned_income: Dictionary = {}
    if worker_manager.has_method("get_actual_treasury_income_map"):
        planned_income = worker_manager.get_actual_treasury_income_map()
    # We take _displayed_treasury (the cache of the label of the HUD), and not CityData.treasury —
    # otherwise in the tooltip the "fresh" value of the treasury would be visible, which gets ahead of
    # the label of the HUD by 1+ consumption ticks (see developer_diary, the regression
    # "runs ahead").
    _map_ui_helpers.show_treasury_tooltip(
        mouse_pos,
        _displayed_treasury,
        planned_income,
        CityData.treasury_expense_snapshot,
        CityData.treasury_window_length_sec,
        keep_position
    )
    var panel = _map_ui_helpers.treasury_tooltip_panel if is_instance_valid(_map_ui_helpers) else null
    return is_instance_valid(panel) and panel.visible

# The tick handler: it updates the label of the treasury in the HUD with the display interval of the
# resources. It is analogous to control_panel.on_city_updated and city_ui._refresh_light —
# everything is subordinated to one era (CityData.resource_display_epoch), so that all
# the resource places are updated simultaneously, by one "jerk" per interval.
func _on_city_data_updated():
    # The era of the player may have changed (advance_era() emits city_updated) —
    # refresh the era label on the HUD so that it always shows the current era.
    _update_era_label()

    if CityData.resource_display_due(_treasury_display_epoch):
        _treasury_display_epoch = CityData.resource_display_epoch
        _update_treasury_hud()
        # On a change of the era we update the open tooltip of the breakdown of the treasury with the fresh
        # data (the planned income is recalculated, the snapshot of the expenses is updated). This is
        # a "live" update — the player sees the actual numbers while the cursor is on the
        # label or on the tooltip. keep_position=true: the "stuck" panel
        # remains in place, and does not run away from the cursor.
        if _map_ui_helpers and is_instance_valid(_map_ui_helpers) \
                and _map_ui_helpers.treasury_tooltip_panel \
                and _map_ui_helpers.treasury_tooltip_panel.visible \
                and CityData.resource_display_due(_treasury_tooltip_display_epoch):
            _treasury_tooltip_display_epoch = CityData.resource_display_epoch
            _show_treasury_tooltip(get_viewport().get_mouse_position(), true)

func _on_assignment_changed():
    # An assignment only lights the icon of the improvement up or down: the map itself does
    # not change, so only the light state layer is re-recorded.
    improvement_state_layer.queue_redraw()
    if city_ui.visible:
        city_ui.refresh_light()

func _on_townsfolk_assignment_changed():
    if city_ui.visible:
        city_ui.refresh_light()
