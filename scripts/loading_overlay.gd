class_name LoadingOverlay
extends CanvasLayer

# The loading screen of a world being built or restored: a full-screen plate, a caption,
# a progress bar and the name of the current stage. It lives on the ROOT, because the
# scene change frees the scene that asked for it while the work continues in the next
# one. The map finds it by name, advances the bar between the stages of its work and
# frees it when done (see main_map/world.gd).
#
# The high layer keeps the screen over the HUD layers MainMap draws while it loads.

static func present(tree: SceneTree, title: String) -> LoadingOverlay:
    var overlay := LoadingOverlay.new()
    overlay.name = "LoadingOverlay"
    overlay.layer = 128

    # The plate replaces the screen behind it instead of dimming it: the menu or the HUD
    # under a half-transparent scrim would show through the caption and the bar.
    var bg := ColorRect.new()
    bg.name = "Background"
    var plate := UiTheme.color("panel_bg")
    # The panel token keeps a little transparency for windows over the map; a screen
    # that replaces the whole view keeps none of it.
    plate.a = 1.0
    bg.color = plate
    # The overlay swallows the input of the whole screen while the world is built.
    bg.mouse_filter = Control.MOUSE_FILTER_STOP
    bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    overlay.add_child(bg)

    var vbox = VBoxContainer.new()
    vbox.name = "VBoxContainer"
    vbox.set_anchors_preset(Control.PRESET_CENTER)
    # The preset alone puts the top left corner at the centre of the screen and the box
    # would grow down and to the right of it. Growing around the anchor point is what
    # actually centres it.
    vbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
    vbox.grow_vertical = Control.GROW_DIRECTION_BOTH
    vbox.alignment = BoxContainer.ALIGNMENT_CENTER
    vbox.add_theme_constant_override("separation", 12)
    overlay.add_child(vbox)

    var title_label = Label.new()
    title_label.name = "TitleLabel"
    title_label.text = title
    title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title_label.add_theme_font_size_override("font_size", 28)
    vbox.add_child(title_label)

    var bar = ProgressBar.new()
    bar.name = "ProgressBar"
    bar.custom_minimum_size = Vector2(400, 24)
    bar.min_value = 0.0
    bar.max_value = 1.0
    bar.value = 0.0
    vbox.add_child(bar)

    var status = Label.new()
    status.name = "StatusLabel"
    status.text = TranslationServer.translate("Preparing...")
    status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    status.add_theme_font_size_override("font_size", 16)
    vbox.add_child(status)

    tree.root.add_child(overlay)
    return overlay

func set_status(text: String) -> void:
    $VBoxContainer/StatusLabel.text = text