# map_highlight_layer.gd
# The highlighting of the chunk under the cursor and of the selected hex. It lives in a separate
# child of MapRenderer, which inherits its transform: the map itself is recorded once per fog change
# and then only panned by the transform, so re-recording the whole map for the highlighting would
# stall the pan.
@tool
extends Node2D

var main_map: Node
var map_renderer: Node

func initialize(main_map_node: Node):
    main_map = main_map_node
    map_renderer = get_parent()
    queue_redraw()

func _draw():
    if main_map == null or not main_map.has_node("ExpansionManager"):
        return
    var expansion_manager = main_map.get_node("ExpansionManager")

    # The chunk can include the hexes in the fog of war (the scouting) - the highlighting is drawn
    # FOR EACH hex of the chunk, without a filter by the visible area. Otherwise in the fog
    # the player does not see which exactly the area is selected now and where the
    # scouts will go. The colour depends on the type of the chunk (the scouting/the claiming × possible/
    # impossible - see map_renderer._get_highlight_style): the tone of the action and its mutedness.
    #
    # Before the study of Cartography the highlighting does NOT go beyond the limits of the Region: there
    # the scouting is unavailable, and the highlighting on the dark canvas of the fog would only
    # confuse the player (see main_map.is_cartography_researched). The chunks
    # collected by expansion_manager already comply with this rule - the filter below is
    # an insurance (for example, an outdated current_chunk after the load of a save).
    var chunk: Array = expansion_manager.current_chunk
    var anchor = expansion_manager.current_hover_hex
    if chunk.is_empty() and anchor != null:
        # There is no chunk under the cursor (a scouted hex outside the Region or a hex in the
        # influence ring of a foreign town): we highlight the hex under the cursor itself -
        # with the same colour as that of the chunk. Otherwise the hovering would be "silent", and a
        # click on such a hex already gives the highlighting (see _draw_selection
        # and expansion_manager.get_highlight_hexes).
        chunk = expansion_manager.get_highlight_hexes(anchor.row, anchor.col)
    if not chunk.is_empty():
        if anchor == null:
            # An outdated current_chunk without a hex under the cursor (an insurance):
            # we take the first hex of the chunk as the reference point for the classification.
            anchor = chunk[0]
        var style: Dictionary = map_renderer._get_highlight_style(chunk, anchor.row, anchor.col, false)
        var cartography: bool = main_map.is_cartography_researched()
        for hex in chunk:
            if not cartography and not main_map.is_valid_hex(hex.row, hex.col):
                continue
            _draw_hex(hex.row, hex.col, style)

    _draw_selection()

# The selected hex is highlighted after the chunk under the cursor, so that the click is visible
# even over the hover. The set of the hexes is the same as the one the control panel acts on: a hex
# in the Influence Ring is highlighted alone, a hex outside the Ring brings the whole chunk of the
# scouting/purchase, and a hex with no chunk (a scouted hex outside the Region or a hex in the
# influence ring of a foreign town) is highlighted alone, so that the click is not "silent".
# The chunk can include the hexes in the Region and in the fog of war nearby.
func _draw_selection():
    if main_map.control_panel == null or not main_map.control_panel.has_selection():
        return
    var selected = main_map.control_panel.get_selected_hex()
    if selected == null:
        return
    var selected_hexes: Array = main_map.expansion_manager.get_highlight_hexes(selected.row, selected.col)
    var style: Dictionary = map_renderer._get_highlight_style(selected_hexes, selected.row, selected.col, true)
    for hex in selected_hexes:
        _draw_hex(hex.row, hex.col, style)

func _draw_hex(row: int, col: int, style: Dictionary):
    var center = HexUtils.hex_center(row, col, main_map.HEX_RADIUS)
    var vertices = HexUtils.hex_vertices(center.x, center.y, main_map.HEX_RADIUS)
    draw_colored_polygon(vertices, style.fill)
    var closed_verts = PackedVector2Array()
    closed_verts.append_array(vertices)
    closed_verts.append(vertices[0])
    draw_polyline(closed_verts, style.border, style.width)
