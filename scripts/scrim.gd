class_name Scrim
extends ColorRect

# The plate that darkens a screen behind something drawn over it: a modal window, the
# loading overlay. It is a ColorRect and not a stylebox because it covers everything and
# has neither border nor corners.
#
# The colour is the `scrim` token of the palette, re-read whenever the player changes the
# theme. How far a background has to be pushed back depends on how light it is to begin
# with, so a light theme dims with a lighter plate than a dark one.
#
# Whether the plate also swallows the mouse is left to the owner: a scrim that only marks
# a modal apart lets clicks through, one that stands in for the whole screen takes them.

func _ready() -> void:
    set_anchors_preset(Control.PRESET_FULL_RECT)
    _apply_scrim()
    # A node re-entering the tree runs _ready again; the signal of the autoload outlives it.
    if not ThemeManager.theme_applied.is_connected(_apply_scrim):
        ThemeManager.theme_applied.connect(_apply_scrim)

func _apply_scrim() -> void:
    color = UiTheme.color("scrim")
