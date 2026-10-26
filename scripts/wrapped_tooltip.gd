# wrapped_tooltip.gd
# A tooltip that WRAPS. The engine's built-in tooltip draws its text in ONE line and
# never breaks it, so a long hint runs off the edge of the window.
#
# There is nothing to configure in the theme: the width of a built-in tooltip is the
# width of the label the engine builds for it, and the project theme
# (theme/tooltips_theme.tres) styles only the panel of the popup. The text has to come
# from our own node, which means overriding Control._make_custom_tooltip.
#
# The engine calls _make_custom_tooltip on the control that OWNS the tooltip text and
# puts the returned node INSIDE its popup, next to the panel background: the popup is a
# PopupPanel holding the themed Panel and the content label, so a custom tooltip replaces
# the TEXT and keeps the frame (see docs.md, "Tooltips").
#
# The owner of the text is usually an engine node (Label, Button, CheckBox) or a node
# carrying a script of its own (warning_badge.gd), so there is nowhere to put the
# override. Therefore the wrapping rides on a CHILD control laid over the control being
# described — see attach(). The carrier lies on top, so the engine picks IT as the owner
# of the text and asks it for the content, while the mouse events still reach the control
# below, because the carrier's mouse_filter is PASS.
#
# Usage — instead of `control.tooltip_text = tr("...")`:
#     WrappedTooltip.attach(control, tr("..."))
class_name WrappedTooltip
extends Control

# The width the text wraps at. The popup is sized by the minimum size of the content,
# so this is both the wrap width and the width of the widest tooltip.
const DEFAULT_MAX_WIDTH: float = 360.0

# The name of the carrier among the children of the control it describes. It is fixed so
# that attach() can find its own carrier again on a rebuild instead of piling up copies.
const CARRIER_NAME: String = "WrappedTooltipCarrier"

# The wrap width of this carrier. A caller with a narrower place (a column of a panel)
# passes its own value to attach().
var tooltip_max_width: float = DEFAULT_MAX_WIDTH


func _init() -> void:
	# PASS, and not STOP: the carrier must be picked as the owner of the tooltip, but a
	# click must still reach the button it covers. STOP would swallow it.
	mouse_filter = Control.MOUSE_FILTER_PASS


func _make_custom_tooltip(for_text: String) -> Object:
	return build(for_text, tooltip_max_width)


# --- The mechanism -------------------------------------------------------------

# Makes `text` the tooltip of `control`, wrapping at `max_width`.
#
# This is the single entry point: a control that explains itself in a long hint is not
# given a tooltip_text directly any more, it is handed to attach(). Short tooltips may
# keep using tooltip_text — they have nothing to wrap.
#
# The call is IDEMPOTENT: a control whose hint is rebuilt on every change (the route
# warning follows the amount) keeps ONE carrier, and only its text is replaced.
static func attach(control: Control, text: String,
		max_width: float = DEFAULT_MAX_WIDTH) -> WrappedTooltip:
	# A tooltip is shown only for a control the hover reaches, and a plain Label catches
	# nothing (MOUSE_FILTER_IGNORE). The carrier catches the mouse on its own, but the
	# described control is lifted as well, so that the rule of the project — "a control
	# with a tooltip catches the mouse" — holds for it too (see docs.md, "Tooltips").
	if control.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		control.mouse_filter = Control.MOUSE_FILTER_STOP
	var carrier := find_carrier(control)
	if carrier == null:
		carrier = WrappedTooltip.new()
		carrier.name = CARRIER_NAME
		# The cursor must not change just because the mouse is over the carrier.
		carrier.mouse_default_cursor_shape = control.mouse_default_cursor_shape
		control.add_child(carrier)
		# Over the whole control, and it follows it on every resize: the carrier is a
		# child of the control itself, so the containers around that control never lay
		# it out and its anchors stay its own.
		carrier.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	carrier.tooltip_max_width = max_width
	carrier.tooltip_text = text
	return carrier


# The carrier already laid over `control`, or null.
static func find_carrier(control: Control) -> WrappedTooltip:
	for child in control.get_children():
		if child is WrappedTooltip:
			return child
	return null


# The content of a wrapping tooltip: a Label that breaks `for_text` at `max_width`.
#
# The width is always given explicitly: a wrapping label reports the width of a single
# character as its minimum size, so a popup left to itself collapses into a column one
# letter wide. The text keeps its natural width up to the limit, and the limit only
# constrains the hints that do not fit in one line.
static func build(for_text: String, max_width: float = DEFAULT_MAX_WIDTH) -> Label:
	var label := Label.new()
	label.text = for_text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# The content of a tooltip needs no mouse of its own: the text belongs to the carrier.
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.custom_minimum_size = Vector2(minf(natural_width(label, for_text), max_width), 0.0)
	return label


# The width the text would take in ONE line — over its widest line, because the text may
# carry line breaks of its own. It is the width the built-in tooltip would have had.
static func natural_width(label: Label, for_text: String) -> float:
	var font: Font = label.get_theme_font("font")
	if font == null:
		# Without a font the width cannot be measured; it is safer to constrain the text
		# than to let it run off the window.
		return INF
	var font_size: int = label.get_theme_font_size("font_size")
	var widest := 0.0
	for line in for_text.split("\n"):
		widest = maxf(widest, font.get_string_size(
				line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	return widest