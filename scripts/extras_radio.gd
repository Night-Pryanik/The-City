# The radio button of the addition list. The stock amount lives in its tooltip, and the
# warehouse changes on every tick of the simulation.
#
# The engine builds a tooltip once, when it appears, and does not repaint it afterwards: a text
# written into tooltip_text would stay frozen for as long as the tooltip is shown. The tooltip is
# therefore a label of its own, kept from the moment it is built, and the panel writes the new
# amount into it — an open tooltip follows the warehouse live.
extends CheckBox

var _tooltip_label: Label

func _make_custom_tooltip(_for_text: String) -> Object:
    var label := Label.new()
    label.theme_type_variation = &"TooltipLabel"
    label.text = tooltip_text
    _tooltip_label = label
    return label

func set_tooltip_amount(text: String) -> void:
    tooltip_text = text
    if not is_instance_valid(_tooltip_label):
        return
    _tooltip_label.text = text
    # The window of the tooltip is sized when it appears: the label does not grow it by itself.
    var tooltip_window := _tooltip_label.get_window()
    if tooltip_window and tooltip_window != get_window():
        tooltip_window.reset_size()
