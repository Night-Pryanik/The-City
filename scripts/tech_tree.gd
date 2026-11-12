# tech_tree.gd
# The visualization of the technology tree in the style of Civilization.
#
#
# Horizontal scrolling, the vertical columns = the layers of the dependencies.
# The root (farming) — the left column (column 0).
#
# The technologies without predecessors — column 1.
# The rest — column = max(col[prereq]) + 1.
#
# The buttons of the same width, with an icon and the wrapping of the text onto 2 lines
# (with an automatic decrease of the font, if it does not fit).
# LMB — start the research (through the signal research_requested).
# Hover — the built-in tooltip with the description of the technology.
extends Control

const UI_THEME = preload("res://scripts/ui_theme.gd")

# --- The dimensions ---
const COL_GAP: int = 80 # the horizontal gap between the columns
const COL_PADDING: int = 24 # the indent from the edge of _inner
const BUTTON_HEIGHT: int = 75 # the fixed height of the button
const BUTTON_VERTICAL_GAP: int = 16 # the vertical gap between the buttons in a column
const ICON_SIZE: int = 65 # the size of the icon of the technology
const UNLOCK_ICON_SIZE: int = 40 # the size of the icon of the unlocked content on the button of the technology
const UNLOCK_ICONS_MARGIN: int = 3 # the distance from the icons to the edges of the button
const UNLOCK_ICONS_SEPARATION: int = 4 # the gap between the icons of the unlocked content
const UNLOCK_ICONS_LEFT: int = 8 + ICON_SIZE + 8 # the row starts behind the icon of the technology
const UNLOCK_ICONS_VISIBLE: int = 4 # the number of slots the row has: for icons, and for arrows
const UNLOCK_ROW_SLOT: int = UNLOCK_ICON_SIZE + UNLOCK_ICONS_SEPARATION # the pitch of one slot: an icon, or an arrow
const UNLOCK_ARROW_SIZE: int = 22 # the side of the arrow that scrolls the row of unlocked icons

# The width of the strip while no arrow takes a slot: the button is as wide as the row it
# has to hold, so a technology that opens more than UNLOCK_ICONS_VISIBLE things scrolls the
# row instead of shrinking the icons, and the names of the technologies fit on one line.
const UNLOCK_ROW_PLAIN_WIDTH: int = (UNLOCK_ICONS_VISIBLE * UNLOCK_ICON_SIZE
        + (UNLOCK_ICONS_VISIBLE - 1) * UNLOCK_ICONS_SEPARATION)
const BUTTON_WIDTH: int = UNLOCK_ICONS_LEFT + UNLOCK_ROW_PLAIN_WIDTH + 8

const ICON_NEW_RECIPES := "new_recipe.png" # the badge of a technology that opens recipes
const ICON_ARROW_LEFT := "chevron_left.svg"
const ICON_ARROW_RIGHT := "chevron_right.svg"

# --- The separation by eras ---
# Each technology in the JSON contains the field "era" (the id of the era), and the human-readable
# names of the eras lie in data/eras.json (it is loaded into GameData.eras).
# The consecutive columns of one era are visually united: above them
# a heading with the name of the era is drawn, and between the groups of the eras — a thick
# vertical line-separator (see ERA_LABEL_HEIGHT, ERA_LINE_*).
const ERA_LABEL_HEIGHT: int = 64 # the height of the strip above the columns under the headings of the eras
const ERA_LABEL_WIDTH: int = 200 # the fixed width of the heading of the era
const ERA_LINE_WIDTH: float = 2.0 # the thickness of the vertical separator of the eras

# --- The external references (filled in in setup) ---
var current_label: Label # "Researching: ..." (the Label at the top of the panel)
var science_pool_label: Label # "Science: X/sec" (the rate of the research of the city)

# --- The tooltip of the breakdown of the science by sources (a panel in the style of the other tooltips) ---
var science_tooltip_panel: Panel = null
var science_tooltip_vbox: VBoxContainer = null

# --- The internal nodes ---
var _scroll: ScrollContainer
var _inner: Control # a large Control, the size = the whole area of the tree
var _columns: Array = [] # [Control, Control, ...] by the columns
var _tech_nodes: Dictionary = {} # tech_id -> {button, column, row}
var _arrows_layer: Control # the Control in which _draw draws the arrows
var _fonts_adjusted: bool = false # the deferred automatic selection of the font has already worked
var _hovered_tech_id: String = "" # the ID of the technology the cursor is over
# --- The cached layout ---
# _compute_layout() is a pure function of the static tech data (ids, prerequisites,
# eras). Completing a research does not change any of it, so the layout stays valid
# until the tech data itself changes (a new mod, a changed dependency, an era change).
var _cached_layout: Dictionary = {}
var _layout_valid: bool = false
# The dependency maps "parent -> [children]" and "child -> [parents]". A pure function
# of GameData.technologies: they are built once and invalidated when the static tech
# data changes (new mods, changed dependencies, an era change, a language reload).
# This avoids rebuilding the maps on every hover and every redraw of the arrows layer.
var _children_map: Dictionary = {} # parent_id -> [child_id, ...]
var _parents_map: Dictionary = {} # child_id -> [parent_id, ...]
var _relations_cache_valid: bool = false
var _related_techs: Dictionary = {} # tech_id -> bool, the related technologies for the highlighting

# --- The separation by eras ---
var _era_labels: Array = [] # the Label-headings of the eras (they are cleared in rebuild)
var _era_groups: Array = [] # [{era_id, era_name, col_start, col_end, x_center, x_boundary}]

# The icons of the technologies are taken from the common registry IconRegistry (autoload):
# the index of the file names is built there once per game.

signal research_requested(tech_id: String)

func setup(parent: Control, current_lbl: Label, science_lbl: Label = null):
    current_label = current_lbl
    science_pool_label = science_lbl
    # A new game / a new UI setup: the static tech data may have changed (a new mod set,
    # a language reload), so the cached layout and the dependency maps are no longer
    # trustworthy.
    _cached_layout = {}
    _layout_valid = false
    _relations_cache_valid = false
    _build_ui(parent)
    _setup_science_tooltip()

# Invalidates the cached layout. Call it when the static tech data changes
# (new mods, changed dependencies, a changed era assignment, a language reload),
# so that the next rebuild() recomputes _compute_layout() instead of reusing the cache.
func invalidate_layout_cache() -> void:
    _cached_layout = {}
    _layout_valid = false

# Builds the dependency maps once from GameData.technologies. Called lazily on the
# first hover / arrows draw after the cache has been invalidated.
func _build_relations_maps() -> void:
    _children_map = {}
    _parents_map = {}
    for tech in GameData.technologies:
        var tid: String = tech["id"]
        var prereqs = tech.get("prerequisites", [])
        for group in prereqs:
            for req in group:
                if not _children_map.has(req):
                    _children_map[req] = []
                _children_map[req].append(tid)
                if not _parents_map.has(tid):
                    _parents_map[tid] = []
                _parents_map[tid].append(req)
    _relations_cache_valid = true

# Ensures the dependency maps are up to date before they are used.
func _ensure_relations_maps() -> void:
    if not _relations_cache_valid:
        _build_relations_maps()

# Invalidates the cached dependency maps. Call it when the static tech data changes
# (new mods, changed dependencies, a changed era assignment, a language reload), so
# the maps are rebuilt from the current data on the next access.
func invalidate_relations_cache() -> void:
    _relations_cache_valid = false

# --- The tooltip of the breakdown of the science ("Science: X/sec") ---
# A panel in the style of the other tooltips of the project (mouse_filter IGNORE — it does not interfere with
# the input): it is shown on hover over the label of the rate of the science and displays
# what the final number consists of (the base + the buildings + the schools + the consumables bonus).
func _setup_science_tooltip():
    if science_pool_label == null:
        return
    # The default Label mouse_filter IGNORE — the hover over it is not caught.
    # PASS allows accepting mouse_entered/mouse_exited.
    science_pool_label.mouse_filter = Control.MOUSE_FILTER_PASS
    science_pool_label.mouse_entered.connect(_show_science_tooltip)
    science_pool_label.mouse_exited.connect(_hide_science_tooltip)

    science_tooltip_panel = Panel.new()
    science_tooltip_panel.visible = false
    science_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    # The default Label mouse_filter IGNORE — the hover over it is not caught.
    # PASS allows accepting mouse_entered/mouse_exited.
    science_tooltip_panel.z_index = 1100
    science_tooltip_panel.theme_type_variation = &"SurfaceTooltip"
    add_child(science_tooltip_panel)

    science_tooltip_vbox = VBoxContainer.new()
    science_tooltip_vbox.add_theme_constant_override("separation", 3)
    science_tooltip_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
    science_tooltip_panel.add_child(science_tooltip_vbox)

# --- The bullet-helpers of the science tooltip (after the pattern of buildings_tab._make_bullet*) ---
# The main item of the list: "• text".
func _make_bullet(symbol: String) -> Label:
    var bullet = Label.new()
    bullet.text = symbol
    bullet.add_theme_color_override("font_color", UI_THEME.color("text_secondary"))
    bullet.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return bullet

func _make_bullet_row(symbol: String, text: String) -> HBoxContainer:
    var row = HBoxContainer.new()
    row.add_theme_constant_override("separation", 6)
    row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(_make_bullet(symbol))
    var label = Label.new()
    label.text = text
    label.add_theme_color_override("font_color", UI_THEME.color("text_secondary"))
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(label)
    return row

# Over the technology tree (z_index as in group_tooltip in ui_helpers).
func _make_bullet_sub_row(text: String) -> HBoxContainer:
    var row = HBoxContainer.new()
    row.add_theme_constant_override("separation", 6)
    row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var indent = Control.new()
    indent.custom_minimum_size = Vector2(18, 0)
    row.add_child(indent)
    row.add_child(_make_bullet("◦"))
    var label = Label.new()
    label.text = text
    label.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(label)
    return row

# --- The bullet-helpers of the science tooltip (after the pattern of buildings_tab._make_bullet*) ---
# The main item of the list: "• text".
func _rebuild_science_tooltip():
    if science_tooltip_vbox == null:
        return
    for child in science_tooltip_vbox.get_children():
        science_tooltip_vbox.remove_child(child)
        child.queue_free()

    var bd: Dictionary = CityData.get_science_breakdown()
    var base: float = float(bd.get("base", CityData.BASE_SCIENCE_PER_SEC))
    var total: float = CityData.get_science_rate_per_sec()

    science_tooltip_vbox.add_child(_make_bullet_row("•", tr("Base: %.1f/sec") % base))
    for bld_entry in bd.get("buildings", []):
        # name is the source identifier ("@bld:library"), the label is resolved at the drawing.
        var bld_name: String = GameData.get_source_display_name(str(bld_entry.get("name", "")))
        if bld_name.is_empty():
            bld_name = tr("Building")
        var fixed: float = float(bld_entry.get("fixed", 0.0))
        var mediums: float = float(bld_entry.get("mediums", 0.0))
        var bonus: float = float(bld_entry.get("bonus", 1.0))
        var bld_total := (fixed + mediums) * bonus
        science_tooltip_vbox.add_child(_make_bullet_row("•", tr("%s: %.1f/sec") % [bld_name, bld_total]))
        if fixed > 0.0:
            # The sub-item: the indent + "◦ text" (as the cost sub-items in the tooltip of a building).
            science_tooltip_vbox.add_child(_make_bullet_sub_row(tr("Building: %.1f/sec") % fixed))
        if mediums > 0.0:
            var names_str := _join_unique_names(bld_entry.get("mediums_names", []))
            # The pure weighted average of the special_yield of the mixture, without the bonuses.
            science_tooltip_vbox.add_child(_make_bullet_sub_row(tr("Scholarly materials: %.1f/sec%s") % [mediums, names_str]))
        if abs(bonus - 1.0) > 0.001:
            var bonus_str := "+%d%%" % int(round((bonus - 1.0) * 100.0))
            var bonus_names_str := _join_unique_names(bld_entry.get("bonus_names", []))
            science_tooltip_vbox.add_child(_make_bullet_sub_row(tr("Consumption bonus: %s%s") % [bonus_str, bonus_names_str]))
    # The specialization of the city multiplies the whole rate, so it stands as a line of its own
    # between the sources and the total.
    var spec_mult: float = float(bd.get("specialization", 1.0))
    if absf(spec_mult - 1.0) > 0.001:
        science_tooltip_vbox.add_child(_make_bullet_row("•",
                tr("Specialization: %s") % CityData.format_signed_percent(spec_mult - 1.0)))
    science_tooltip_vbox.add_child(_make_bullet_row("•", tr("Total: %.1f/sec") % total))

# Reassembles the contents of the tooltip from the cache CityData.science_breakdown:
# a bulleted list of the sources (the sub-items of the buildings — "◦"). The arithmetic of the
# tooltip coincides with the label: the total of a building = (Building + Writing materials) ×
# the Consumption bonus, "Total" = Base + the sums of the buildings.
func _join_unique_names(names: Array) -> String:
    if names.is_empty():
        return ""
    var seen := {}
    var uniq: Array = []
    for n in names:
        var s := str(n)
        if s == "" or seen.has(s):
            continue
        seen[s] = true
        uniq.append(s)
    if uniq.is_empty():
        return ""
    return " (" + ", ".join(uniq) + ")"

func _show_science_tooltip():
    if science_tooltip_panel == null or science_pool_label == null:
        return
    _rebuild_science_tooltip()
    science_tooltip_panel.visible = true
    _position_science_tooltip()

            # The pure value of additional_yield.science, without the bonuses.
            # tech_tree, because the panel is a child of tech_tree), with a shift, so as not to go beyond
            # the right edge of the viewport.
func _position_science_tooltip():
    if science_tooltip_panel == null or science_tooltip_vbox == null or science_pool_label == null:
        return
    var label_global := science_pool_label.get_global_rect()
    var local_pos := label_global.position - global_position + Vector2(0, label_global.size.y + 4)
    science_tooltip_panel.position = local_pos
    # The size by the contents of the vbox (as show_built_tooltip in ui_helpers):
    # a reset of the size, the minimum of the contents + the indents 6/6/4/4.
    science_tooltip_vbox.reset_size()
    science_tooltip_vbox.position = Vector2(6, 4)
    science_tooltip_panel.size = science_tooltip_vbox.get_minimum_size() + Vector2(12, 8)
    # Not to go beyond the right/bottom edge of the viewport.
    var vp_size := get_viewport_rect().size
    var panel_global := local_pos + global_position
    if panel_global.x + science_tooltip_panel.size.x > vp_size.x:
        science_tooltip_panel.position.x = vp_size.x - science_tooltip_panel.size.x - global_position.x - 4
    if panel_global.y + science_tooltip_panel.size.y > vp_size.y:
        science_tooltip_panel.position.y = vp_size.y - science_tooltip_panel.size.y - global_position.y - 4

func _hide_science_tooltip():
    if science_tooltip_panel != null:
        science_tooltip_panel.visible = false

func _build_ui(parent: Control):
    _scroll = ScrollContainer.new()
    _scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
    # The two-sided scrolling is needed: with a small number of eras there is no scroll
    # by the height, and with a large number of technologies in an era — there is.
    _scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    _scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    parent.add_child(_scroll)

    _inner = Control.new()
    _inner.mouse_filter = Control.MOUSE_FILTER_PASS
    # custom_minimum_size is set in rebuild() under the actual size of the tree.
    _scroll.add_child(_inner)

func _compute_layout() -> Dictionary:
    # It returns:
    #   "columns"  : {col_index : [tech_id, ...]}
    #   "tech_col" : {tech_id   : col_index}
    #   "max_col_count" : int  (the max. number of buttons in one column)
    var techs = GameData.technologies
    var col_for: Dictionary = {}

    # The root (farming) — always the column 0. This is an explicit rule of the spec:
    # "the technology Crop Farming that is unlocked at the start of the game — at the left edge".
    if _tech_exists("farming"):
        col_for["farming"] = 0

    # Iteratively: some prerequisites may refer to the technologies
    # which will be met later in the JSON. We repeat until the layout stabilises.
    for _it in range(20):
        var changed = false
        for tech in techs:
            var tid: String = tech["id"]
            if col_for.has(tid):
                continue
            var prereqs = tech.get("prerequisites", [])
            if prereqs.is_empty():
                col_for[tid] = 1
                changed = true
                continue
            var max_prereq_col := -1
            var all_known := true
            for group in prereqs:
                for req in group:
                    if not col_for.has(req):
                        all_known = false
                        break
                    max_prereq_col = max(max_prereq_col, col_for[req])
                if not all_known:
                    break
            if all_known:
                col_for[tid] = max_prereq_col + 1
                changed = true
        if not changed:
            break

    # The fallback: if something has been left without a column (a broken reference in prerequisites) —
    # we put it into the column 1, so as not to lose the technology from the UI.
    for tech in techs:
        if not col_for.has(tech["id"]):
            col_for[tech["id"]] = 1

    # The normalisation by eras: we shift the technologies of each era to the right, so that
    # the eras follow in order (see _normalize_era_columns). This guarantees
    # that a vertical line-separator will appear between the groups of the eras, even
    # if a later technology by the layout (by the dependencies) has got into a column,
    # where most of the technologies are of an earlier era.
    if not GameData.eras.is_empty():
        col_for = _normalize_era_columns(col_for)

    # We lay out by the columns.
    var columns: Dictionary = {}
    for tid in col_for:
        var c: int = col_for[tid]
        if not columns.has(c):
            columns[c] = []
        columns[c].append(tid)

    # The initial sorting by id — a deterministic input for barycenter,
    # so that the result does not depend on the order in technologies.json.
    for c in columns:
        columns[c].sort()

    # --- The "smart" layout: the barycenter heuristic (Sugiyama 1981) ---
    # We sort the nodes in each column by the **median** of the Y-positions of their neighbours
    # (the children on down-sweep, the parents on up-sweep). This minimises
    # the length and the number of the intersections of the arrows: the parent and the child
    # turn out to be close vertically, and not scattered over the whole column.
    #
    
    #
    # Example: animal_husbandry opens plow, cheese_making, leatherworking.
    # If their Y in column 2 turns out to be on average around the Y of animal_husbandry
    # in column 1 — the arrows become short and do not overlap.
    
    #
    # The median is better than the average: the average is sensitive to one far
    # outlier, and the median is robust. For example, if pottery has 2 children
    # close by and yet 1 far below, the average will pull pottery down, the median — will not.
    var num_cols: int = 0
    for c in columns:
        if c + 1 > num_cols:
            num_cols = c + 1
    if num_cols > 1:
        var parents_map: Dictionary = _build_parents_map(techs)
        # The global dictionary of the Y-positions: y_positions[node_id] = float(y).
        # NECESSARILY global over ALL the columns, otherwise on the down-sweep we
        # will not find the parents from the previous columns, and related.is_empty()
        # for all of them — barycenter = the current index, the sorting changes nothing.
        # (This was also the bug in the first implementation: y_positions was recreated
        # on every call and contained only the current column.)
        var y_positions: Dictionary = {}
        for c in range(num_cols):
            for i in range(columns[c].size()):
                y_positions[columns[c][i]] = float(i)
        # The alternating passes down/up. 8 iterations are enough to converge for 24 nodes;
        # 4 sometimes leaves noticeable intersections.
        for _iter in range(8):
            for c in range(1, num_cols):
                _sort_column_by_barycenter(columns, c, parents_map, false, y_positions)
            for c in range(num_cols - 2, 0, -1):
                _sort_column_by_barycenter(columns, c, parents_map, true, y_positions)
        # The alternating passes down/up. 8 iterations are enough to converge for 24 nodes;
        # 4 sometimes leaves noticeable intersections.

    var max_col_count := 0
    for c in columns:
        if columns[c].size() > max_col_count:
            max_col_count = columns[c].size()

    return {
        "columns": columns,
        "tech_col": col_for,
        "max_col_count": max_col_count,
    }

func _build_parents_map(techs: Array) -> Dictionary:
        # The diagnostic print — it helps to understand whether the algorithm has worked.
        # It is visible in the Output window of the Godot editor.
    var parents_map: Dictionary = {}
    for tech in techs:
        var tid: String = tech["id"]
        var prereqs = tech.get("prerequisites", [])
        for group in prereqs:
            for req in group:
                if not parents_map.has(tid):
                    parents_map[tid] = []
                parents_map[tid].append(req)
    return parents_map

func _sort_column_by_barycenter(columns: Dictionary, col: int, parents_map: Dictionary, look_at_children: bool, y_positions: Dictionary) -> void:
    # Re-sorts the nodes in the column col, minimising the distance to
    # the related nodes in the neighbouring columns.
    #   look_at_children=false: down-sweep — we sort by the median Y of the parents.
    #   look_at_children=true : up-sweep   — we sort by the median Y of the children.
    # y_positions is the GLOBAL dictionary {node_id: y} over all the columns,
    # and is updated after each sorting. Without this the down-sweep does not see
    # the parents in the previous columns and the barycenter degenerates into the index.
    var col_nodes: Array = columns.get(col, [])
    if col_nodes.is_empty():
        return

    # child_id -> [parent_id, ...]  (for each technology — its ancestors)
    # We use it in barycenter: the average Y of the parents gives the "target" Y of the child.
    var barycenters: Dictionary = {}
    for node_id in col_nodes:
        var related: Array = []
        if look_at_children:
    # Re-sorts the nodes in the column col, minimising the distance to
    # the related nodes in the neighbouring columns.
    #   look_at_children=false: down-sweep — we sort by the median Y of the parents.
    #   look_at_children=true : up-sweep   — we sort by the median Y of the children.
    # y_positions is the GLOBAL dictionary {node_id: y} over all the columns,
    # and is updated after each sorting. Without this the down-sweep does not see
    # the parents in the previous columns and the barycenter degenerates into the index.
            for c2 in range(col + 1, columns.size()):
                for other in columns[c2]:
                    var p_list: Array = parents_map.get(other, [])
                    if node_id in p_list:
                        related.append(other)
        else:
            # We look for the parents of node_id in the already sorted columns to the left.
            for p_id in parents_map.get(node_id, []):
                if y_positions.has(p_id):
                    related.append(p_id)
        if related.is_empty():
            # We compute the barycenter (in fact, the median) for each node.
            barycenters[node_id] = y_positions.get(node_id, 0.0)
        else:
            # We look for the nodes to the right of col, for which node_id is a parent.
            var ys: Array = []
            for r in related:
                ys.append(y_positions.get(r, 0.0))
            ys.sort()
            barycenters[node_id] = _median(ys)

            # We look for the parents of node_id in the already sorted columns to the left.
    var pairs: Array = []
    for node_id in col_nodes:
        pairs.append([barycenters.get(node_id, 0.0), node_id])
    pairs.sort()
            # There are no related nodes — we leave it at the current Y.
    var new_order: Array = []
    for i in range(pairs.size()):
        var p: Array = pairs[i]
        var node_id: String = p[1]
        new_order.append(node_id)
            # The median of the Y-positions of the related nodes.
        y_positions[node_id] = float(i)
    columns[col] = new_order

func _median(values: Array) -> float:
    # We sort the column. Without a lambda — through the pairs [bary, id], this is more reliable
    # than sort_custom with a Callable in the strict parser of GDScript.
    # The tie-breaker by id (lexicographically) ensures the stability
    # on the repeated rebuild() and equal barycenters.
    var n: int = values.size()
    if n == 0:
        return 0.0
    if n % 2 == 1:
        return float(values[int(n / 2.0)])
    return (float(values[int(n / 2.0) - 1]) + float(values[int(n / 2.0)])) * 0.5

func _tech_exists(tech_id: String) -> bool:
    for t in GameData.technologies:
        if t["id"] == tech_id:
            return true
    return false

    # The pairs are sorted by the first element (bary), then by the second (id) —
    # because the Array in GDScript is compared element by element.
    #
    # The layout by the dependencies (see _compute_layout) puts the technology into the column
    # max(col[prereq]) + 1. At that time a technology of a later era may get into the same
    # column as the technologies of an earlier era — then by the majority the column is considered
    # earlier, and the group of the later era does not form (there is no separator).
    #
    # The layout by the dependencies (see _compute_layout) puts the technology into the column
    # max(col[prereq]) + 1. At that time a technology of a later era may get into the same
    # column as the technologies of an earlier era — then by the majority the column is considered
    # earlier, and the group of the later era does not form (there is no separator).
    #
    #
    # Here we RELAY OUT the columns so that all the technologies of each era go
    # in an uninterrupted block from left to right in the order of the eras (from GameData.eras). Inside
    # the block of an era the relative order of the columns from the original layout is preserved.
    # This guarantees the appearance of the vertical line-separator between the eras.
    #
    # It returns a new dictionary tech_id -> column.
func _normalize_era_columns(col_for: Dictionary) -> Dictionary:
    # The ordered list of the ids of the eras (the order from data/eras.json).
    var era_order: Array = []
    for era in GameData.eras:
        era_order.append(era.get("id", ""))

    # era_index for each technology (0 — an unknown/the first era).
    var tech_era: Dictionary = {} # tech_id -> int
    for tid in col_for:
        var era_id: String = _get_tech_data(tid).get("era", "")
        var idx: int = era_order.find(era_id)
        tech_era[tid] = idx if idx >= 0 else 0

    # We collect the unique columns of each era.
    var era_columns: Dictionary = {} # era_index -> [col, ...]
    for tid in col_for:
        var c: int = col_for[tid]
        var ei: int = tech_era[tid]
        if not era_columns.has(ei):
            era_columns[ei] = []
        if not era_columns[ei].has(c):
            era_columns[ei].append(c)

    # The relayout: each era occupies an uninterrupted block of columns.
    var sorted_era: Array = era_columns.keys()
    sorted_era.sort()
    var result: Dictionary = {}
    var global_col: int = 0
    for ei in sorted_era:
        var cols: Array = era_columns[ei]
        cols.sort()
        # old_col -> new_col inside the block of this era.
        var mapping: Dictionary = {}
        var target: int = global_col
        for old in cols:
            mapping[old] = target
            target += 1
        # We apply to all the technologies of this era.
        for tid in col_for:
            if tech_era[tid] == ei:
                result[tid] = mapping[col_for[tid]]
        global_col = target

    return result

# --- The separation by eras: the helpers ---

# Returns the human-readable name of the era by its id (as in technologies_tab.gd).
# The source is data/eras.json, it is loaded into GameData.eras.
# If the era is not found — we return the id itself (fallback).
func _get_era_name(era_id: String) -> String:
    if era_id.is_empty():
        return ""
    for era in GameData.eras:
        if era.get("id", "") == era_id:
            return era.get("name", era_id)
    return era_id

# Returns the id of the era to which the column column_id belongs.
# A column can contain the technologies of different eras (rare, but it happens —
# for example, an ancient technology opening an antique one). Then we take
# the era which occurs in the column most often. If the column is empty
# or the eras are not specified — we return "" (there is no group).
func _column_era(columns: Dictionary, column_id: int) -> String:
    var techs_in_col: Array = columns.get(column_id, [])
    if techs_in_col.is_empty():
        return ""
    var counts: Dictionary = {} # era_id -> the quantity
    for tid in techs_in_col:
        var era_id: String = _get_tech_data(tid).get("era", "")
        if era_id.is_empty():
            continue
        counts[era_id] = counts.get(era_id, 0) + 1
    if counts.is_empty():
        return ""
    var best: String = ""
    var best_count: int = 0
    for era_id in counts:
        if counts[era_id] > best_count:
            best = era_id
            best_count = counts[era_id]
    return best

#
# Computes the list of the groups of the eras: the consecutive columns of one era.
# It returns an array of dictionaries:
#   {era_id, era_name, col_start, col_end, x_center, x_boundary}
# all the technologies of each era stand in an uninterrupted block from left to right, therefore
# the groups of the eras come out clean, and between them a vertical separator is drawn.
# The layout by the dependencies (barycenter) inside each era is preserved.
func _compute_era_groups(columns: Dictionary, num_cols: int) -> Array:
    var groups: Array = []
    var current_era: String = ""
    var group_start: int = -1

    for c in range(num_cols):
        var era_id: String = _column_era(columns, c)
        if era_id == current_era:
            continue
        # The era has changed — we close the previous group (if there was one).
        if current_era != "" and group_start >= 0:
            groups.append(_make_era_group(current_era, group_start, c - 1))
        current_era = era_id
        group_start = c

    # The last group.
    if current_era != "" and group_start >= 0:
        groups.append(_make_era_group(current_era, group_start, num_cols - 1))

    return groups

# Creates the dictionary of the group of an era by the range of the columns [col_start..col_end].
func _make_era_group(era_id: String, col_start: int, col_end: int) -> Dictionary:
    var first_x: float = _col_x(col_start) # the left edge of the first column of the group
    var last_right: float = _col_x(col_end) + BUTTON_WIDTH + float(COL_GAP) / 2.0 # the middle between the columns
    return {
        "era_id": era_id,
        "era_name": _get_era_name(era_id),
        "col_start": col_start,
        "col_end": col_end,
        "x_center": (first_x + last_right) * 0.5,
        "x_boundary": last_right, # the right edge of the group — there is the line
    }

# The X-coordinate of the left edge of the column c (in the coordinates of _inner).
# It takes into account only the horizontal indent COL_PADDING, without the shift down
# under the headings of the eras (the vertical offset of the columns by the height of the headings
# is done separately in rebuild() through _col_y()).
func _col_x(c: int) -> float:
    return float(COL_PADDING + c * (BUTTON_WIDTH + COL_GAP))

# The Y-coordinate of the top of the columns taking into account the strip of the headings of the eras.
# The columns are shifted down by ERA_LABEL_HEIGHT, so that on the top there is
# a place for the headings of the eras.
func _col_y() -> float:
    return float(ERA_LABEL_HEIGHT + COL_PADDING)

# Creates the Label-headings of the eras above the fresh columns. It is called from rebuild().
# The headings are added to _inner, therefore they scroll together with the tree.
func _create_era_labels(layout_columns: Dictionary, num_cols: int) -> void:
    # First we remove the old headings (if there was a rebuild).
    for l in _era_labels:
        if is_instance_valid(l):
            l.queue_free()
    _era_labels.clear()

    _era_groups = _compute_era_groups(layout_columns, num_cols)
    if _era_groups.is_empty():
        return

    # The height of the strip on the top — the strip occupies the top (y=0),
    # we place the Label in the middle of the strip.
    for group in _era_groups:
        if group["era_id"] == "antiquity":
            _create_antiquity_era_label(group)
        else:
            var lab := Label.new()
            lab.name = "EraLabel"
            lab.text = group["era_name"]
            lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
            lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
            lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
            lab.size = Vector2(ERA_LABEL_WIDTH, ERA_LABEL_HEIGHT)
            lab.custom_minimum_size = Vector2(ERA_LABEL_WIDTH, ERA_LABEL_HEIGHT)
            lab.add_theme_font_size_override("font_size", 14)
            lab.add_theme_color_override("font_color", UI_THEME.color("text_secondary"))
            lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
            lab.position = Vector2(group["x_center"] - ERA_LABEL_WIDTH * 0.5, 0.0)
            _inner.add_child(lab)
            _era_labels.append(lab)

# The heading of the era Antiquity with the condition of the transition: the Market is built (0/1).
# When the Market is built — (1/1) and a green check mark.
func _create_antiquity_era_label(group: Dictionary) -> void:
    var market_built := false
    for b in CityData.city_built_buildings:
        if b.get("id", "") == "market":
            market_built = true
            break
    var count_text: String = "1/1" if market_built else "0/1"
    var check: String = " [color=#%s]✔[/color]" % UI_THEME.color("income").to_html(false) if market_built else ""
    var icon_tag: String = ""
    var market_icon_path := IconRegistry.icon_path("market.png")
    if not market_icon_path.is_empty():
        icon_tag = "[img=18]" + market_icon_path + "[/img] "
    var rtl := RichTextLabel.new()
    rtl.name = "EraLabel"
    rtl.bbcode_enabled = true
    rtl.fit_content = true
    rtl.scroll_active = false
    rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
    rtl.size = Vector2(ERA_LABEL_WIDTH, ERA_LABEL_HEIGHT)
    rtl.custom_minimum_size = Vector2(ERA_LABEL_WIDTH, ERA_LABEL_HEIGHT)
    rtl.add_theme_font_size_override("normal_font_size", 12)
    rtl.add_theme_color_override("default_color", UI_THEME.color("text_secondary"))
    rtl.position = Vector2(group["x_center"] - ERA_LABEL_WIDTH * 0.5, 0.0)
    # The colour of the hint is substituted after the translation, so that the text keeps
    # the translated message as its key.
    var hint: String = tr("[center][color=#c9c9c9]Advance requirement:[/color] build ")
    hint = hint.replace("#c9c9c9", "#" + UI_THEME.color("text_muted").to_html(false))
    rtl.text = "[center]" + group["era_name"] + "[/center]\n" + hint + icon_tag + tr("Market (") + count_text + ")" + check + "[/center]"
    _inner.add_child(rtl)
    _era_labels.append(rtl)

func rebuild():
    # A full rebuild: we clear and create from scratch.
    # It is called on the structural changes (a new research, a completion and so on).
    for col in _columns:
        col.queue_free()
    _columns.clear()
    _tech_nodes.clear()

    if is_instance_valid(_arrows_layer):
        _arrows_layer.queue_free()
        _arrows_layer = null

    if GameData.technologies.is_empty():
        return

    var layout: Dictionary
    if _layout_valid and not _cached_layout.is_empty():
        layout = _cached_layout
    else:
        layout = _compute_layout()
        _cached_layout = layout.duplicate(true)
        _layout_valid = true
    var columns: Dictionary = layout["columns"]
    var max_col_count: int = layout["max_col_count"]

    # The size of _inner for the whole tree.
    # We specify the types explicitly: max() and .keys().max() return a Variant,
    # and := will not be able to deduce the type from the expression where they take part.
    var num_cols: int = 1
    if not columns.is_empty():
        num_cols = int(columns.keys().max()) + 1
    var col_height: int = max_col_count * (BUTTON_HEIGHT + BUTTON_VERTICAL_GAP) - BUTTON_VERTICAL_GAP
    var total_width: int = COL_PADDING * 2 + num_cols * BUTTON_WIDTH + max(0, num_cols - 1) * COL_GAP
    # The height includes the strip of the headings of the eras (ERA_LABEL_HEIGHT) — the columns
    # are shifted down by this value, and on the top there is a place left for the headings.
    var total_height: int = ERA_LABEL_HEIGHT + COL_PADDING * 2 + max(col_height, BUTTON_HEIGHT)
    _inner.size = Vector2(total_width, total_height)
    _inner.custom_minimum_size = Vector2(total_width, total_height)
    # A ScrollContainer takes the range of its bars from a minimum-size query, and the anchored
    # TreeRoot above it never makes one. Without this query the bars keep the range of the
    # previous layout (and stay hidden) until something resizes the window.
    _scroll.get_combined_minimum_size()
    _scroll.queue_sort()

    # We create the headings of the eras (the strip on the top). We do this BEFORE the columns,
    # so that the headings end up under them in the z-order (the arrows are drawn
    # by the last layer over everything).
    _create_era_labels(columns, num_cols)

    # We place the columns manually inside _inner (and NOT through HBoxContainer),
    # so that the positions are predictable for the drawing of the arrows.
    for c in range(num_cols):
        var col_container := Control.new()
        col_container.position = Vector2(
            _col_x(c),
            _col_y() # the shift down by the height of the strip of the headings of the eras
        )
        col_container.size = Vector2(BUTTON_WIDTH, max(col_height, BUTTON_HEIGHT))
        col_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
        _inner.add_child(col_container)
        _columns.append(col_container)

        var techs_in_col: Array = columns.get(c, [])
        var col_count: int = techs_in_col.size()
        for i in range(col_count):
            var tech_id: String = techs_in_col[i]
            var tech_data = _get_tech_data(tech_id)
            if tech_data.is_empty():
                continue

            var btn = _create_tech_button(tech_data)
            # An even distribution over the column; if the column is shorter than
            # the tallest one — we centre it vertically.
            var step := BUTTON_HEIGHT + BUTTON_VERTICAL_GAP
            var y_offset := 0.0
            if max_col_count > col_count:
                y_offset = (max_col_count - col_count) * step * 0.5
            btn.position = Vector2(0, y_offset + i * step)
            col_container.add_child(btn)
            _tech_nodes[tech_id] = {
                "button": btn,
                "column": c,
                "row": i,
            }

    # The layer with the arrows — over the columns. Without z_index: _arrows_layer
    # is added last to _inner, therefore by default it is drawn
    # over the columns. z_index here must NOT be set — otherwise the arrows
    # will rise above all the Controls in the canvas layer, including
    # tech_popup (the message window of a learned technology).
    _arrows_layer = Control.new()
    _arrows_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
    _arrows_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _inner.add_child(_arrows_layer)
    _arrows_layer.draw.connect(_on_arrows_draw)

    # The states (the colours, the progress, the tooltips) — over the freshly created buttons.
    _update_states()
    _arrows_layer.queue_redraw()
    _update_status_label()

    # The automatic selection of the font requires the layout to have already been computed.
    # We do it on the nearest frame.
    _fonts_adjusted = false
    _adjust_fonts.call_deferred()

func _create_tech_button(tech_data: Dictionary) -> Button:
    var btn := Button.new()
    btn.custom_minimum_size = Vector2(BUTTON_WIDTH, BUTTON_HEIGHT)
    btn.size = Vector2(BUTTON_WIDTH, BUTTON_HEIGHT)
    # The text of the button is NOT used — it is drawn by the built-in Label, and
    # its style depends on the Button, and we need our own layout. Therefore
    # we simply leave text empty and put our own structure inside.
    btn.text = ""
    btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

    # The MarginContainer around the contents — for the indents from the border of the button.
    var margin := MarginContainer.new()
    margin.set_anchors_preset(Control.PRESET_FULL_RECT)
    margin.add_theme_constant_override("margin_left", 8)
    margin.add_theme_constant_override("margin_right", 8)
    margin.add_theme_constant_override("margin_top", 6)
    margin.add_theme_constant_override("margin_bottom", 6)
    margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
    btn.add_child(margin)

    # HBox: the icon + the text
    var hbox := HBoxContainer.new()
    hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
    hbox.add_theme_constant_override("separation", 8)
    hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
    margin.add_child(hbox)

    var icon_name: String = tech_data.get("icon", "")
    var icon_tex: Texture2D = _load_tech_icon(icon_name)
    var icon_rect := TextureRect.new()
    icon_rect.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
    icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    if icon_tex != null:
        icon_rect.texture = icon_tex
    hbox.add_child(icon_rect)

    var label := Label.new()
    label.name = "TechNameLabel"
    label.text = tech_data.get("name", tech_data["id"])
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    # The text is pressed to the top edge: at the bottom of the button there is a place left for
    # the small icons of what the technology opens (_add_unlock_icons).
    label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    label.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
    # The base size of the font. The final one is selected in _adjust_fonts() on
    # the next frame, when Godot has already computed the layout and knows
    # the actual get_line_count() / get_minimum_size().
    label.add_theme_font_size_override("font_size", 12)
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    hbox.add_child(label)

    # The progress bar (it is visible only when the technology is being researched) — a narrow strip
    # at the bottom of the button. mouse_filter=ignore, so as not to intercept the clicks.
    var progress := ProgressBar.new()
    progress.name = "TechProgress"
    progress.anchor_left = 0.0
    progress.anchor_right = 1.0
    progress.anchor_top = 1.0
    progress.anchor_bottom = 1.0
    progress.offset_top = -6
    progress.offset_bottom = 0
    progress.show_percentage = false
    progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
    progress.visible = false
    btn.add_child(progress)

    # The small icons at the bottom of the button: everything that the technology opens.
    _add_unlock_icons(btn, tech_data["id"])

    # Tooltip — the built-in mechanism of Godot, with the wrapping content of the
    # project: the engine draws the text of a tooltip in one line, and a long
    # description of a technology runs off the screen.
    _attach_tech_tooltip(btn, tech_data["id"])

    # The click — upwards, through the signal.
    var tech_id: String = tech_data["id"]
    btn.pressed.connect(_on_tech_pressed.bind(tech_id))
    
    # Hover — the highlighting of the related technologies and the arrows.
    btn.mouse_entered.connect(_on_tech_button_mouse_entered.bind(tech_id))
    btn.mouse_exited.connect(_on_tech_button_mouse_exited.bind(tech_id))

    return btn

func _add_unlock_icons(btn: Button, tech_id: String):
    # A row of the small icons at the bottom edge of the button: everything that the
    # technology opens (the buildings, the improvements, the recipes, the modifier effects).
    # Each icon has its own tooltip_text — on hover over the icon
    # it is shown, and not the common tooltip of the technology.
    var items: Array = _get_unlock_items(tech_id)
    if items.is_empty():
        return

    # The row is a strip: it shows UNLOCK_ICONS_VISIBLE slots and scrolls when there are more.
    # The bar itself is never drawn — the arrows and the mouse wheel do the scrolling,
    # and a bar inside a button would eat the height the icons need.
    var strip := ScrollContainer.new()
    strip.name = "UnlockIconsScroll"
    strip.anchor_left = 0.0
    strip.anchor_right = 1.0
    strip.anchor_top = 1.0
    strip.anchor_bottom = 1.0
    strip.offset_left = UNLOCK_ICONS_LEFT
    strip.offset_right = -8
    strip.offset_top = -(UNLOCK_ICON_SIZE + UNLOCK_ICONS_MARGIN)
    strip.offset_bottom = -UNLOCK_ICONS_MARGIN
    strip.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
    strip.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    # PASS, so that a click on the row still reaches the button and starts the research.
    strip.mouse_filter = Control.MOUSE_FILTER_PASS
    btn.add_child(strip)

    var row := HBoxContainer.new()
    row.name = "UnlockIconsRow"
    row.add_theme_constant_override("separation", UNLOCK_ICONS_SEPARATION)
    row.alignment = BoxContainer.ALIGNMENT_BEGIN
    row.mouse_filter = Control.MOUSE_FILTER_PASS
    strip.add_child(row)

    for item in items:
        var tex: Texture2D = _load_tech_icon(item.get("icon", ""))
        if tex == null:
            continue
        var icon := TextureRect.new()
        icon.custom_minimum_size = Vector2(UNLOCK_ICON_SIZE, UNLOCK_ICON_SIZE)
        icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
        icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        icon.texture = tex
        icon.tooltip_text = item.get("tip", "")
        icon.mouse_filter = Control.MOUSE_FILTER_PASS
        row.add_child(icon)

    _add_unlock_arrows(btn, strip, row)

# The wheel over the row scrolls it by one icon. Only a row that actually overflows takes
# the wheel: otherwise the gesture belongs to the tree, which is scrolled by the same wheel.
func _on_unlock_row_input(event: InputEvent, strip: ScrollContainer, row: HBoxContainer) -> void:
    if not (event is InputEventMouseButton):
        return
    var mb := event as InputEventMouseButton
    if not mb.pressed:
        return
    var direction := 0
    match mb.button_index:
        MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT:
            direction = -1
        MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_RIGHT:
            direction = 1
        _:
            return
    if not _unlock_row_overflows(row):
        return
    _unlock_scroll_by(strip, row, direction)
    strip.accept_event()

func _add_unlock_arrows(btn: Button, strip: ScrollContainer, row: HBoxContainer) -> void:
    # An arrow stands in a whole slot of the row rather than over an icon: while the row needs
    # arrows, the end slots belong to them and nothing of the unlocked content is ever covered.
    # A row that fits is left as plain icons.
    strip.gui_input.connect(_on_unlock_row_input.bind(strip, row))
    # The arrows follow three things: how far the row is scrolled, how wide the row is, and
    # how wide the strip became. The bar of a hidden row still holds the offset, and the row
    # is resized when an icon is added to it, so a change in either side refreshes the arrows.
    var bar := strip.get_h_scroll_bar()
    bar.value_changed.connect(func(_value): _refresh_unlock_arrows(btn, strip, row))
    strip.resized.connect(func(): _refresh_unlock_arrows(btn, strip, row))
    row.resized.connect(func(): _refresh_unlock_arrows(btn, strip, row))

    for direction in [-1, 1]:
        var arrow := Button.new()
        arrow.name = "UnlockArrowLeft" if direction < 0 else "UnlockArrowRight"
        arrow.focus_mode = Control.FOCUS_NONE
        arrow.expand_icon = true
        arrow.icon = IconRegistry.get_texture(ICON_ARROW_LEFT if direction < 0 else ICON_ARROW_RIGHT)
        arrow.custom_minimum_size = Vector2(UNLOCK_ARROW_SIZE, UNLOCK_ARROW_SIZE)
        arrow.anchor_left = 0.0 if direction < 0 else 1.0
        arrow.anchor_right = arrow.anchor_left
        arrow.anchor_top = 1.0
        arrow.anchor_bottom = 1.0
        arrow.offset_top = -((UNLOCK_ICON_SIZE + UNLOCK_ARROW_SIZE) * 0.5 + UNLOCK_ICONS_MARGIN)
        arrow.offset_bottom = arrow.offset_top + UNLOCK_ARROW_SIZE
        # The arrow is centred in the end slot of the row, where an icon would otherwise stand.
        var slot_padding := int((UNLOCK_ROW_SLOT - UNLOCK_ARROW_SIZE) * 0.5)
        if direction < 0:
            arrow.offset_left = UNLOCK_ICONS_LEFT + slot_padding
            arrow.offset_right = arrow.offset_left + UNLOCK_ARROW_SIZE
        else:
            arrow.offset_right = -(8 + slot_padding)
            arrow.offset_left = arrow.offset_right - UNLOCK_ARROW_SIZE
        # STOP: the arrow scrolls the row, it must not start the research of the technology.
        arrow.mouse_filter = Control.MOUSE_FILTER_STOP
        arrow.pressed.connect(_on_unlock_arrow_pressed.bind(strip, row, direction))
        _style_unlock_arrow(arrow)
        btn.add_child(arrow)

    _refresh_unlock_arrows(btn, strip, row)

# The plate under a scroll arrow: a plain chevron on the button is read as part of the panel,
# so the arrow gets the frame of a control. The frame also keeps it visible on both the dark
# and the lit shade of a technology button.
func _style_unlock_arrow(arrow: Button) -> void:
    var border := UI_THEME.color("control_border")
    arrow.flat = false
    arrow.add_theme_stylebox_override("normal",
            _unlock_arrow_plate(UI_THEME.color("control_bg"), border))
    arrow.add_theme_stylebox_override("hover",
            _unlock_arrow_plate(UI_THEME.color("control_hover"), border))
    arrow.add_theme_stylebox_override("pressed",
            _unlock_arrow_plate(UI_THEME.color("control_pressed"), border))
    arrow.add_theme_stylebox_override("focus",
            _unlock_arrow_plate(UI_THEME.color("control_bg"), border))

func _unlock_arrow_plate(bg: Color, border: Color) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = bg
    style.border_color = border
    style.set_border_width_all(1)
    style.set_corner_radius_all(3)
    # A 1 px frame and 2 px of padding are all the plate can afford: the chevron has to
    # stay readable inside a control that is itself only a little taller than an icon.
    UI_THEME.set_content_margins(style, 2.0)
    return style

func _on_unlock_arrow_pressed(strip: ScrollContainer, row: HBoxContainer, direction: int) -> void:
    _unlock_scroll_by(strip, row, direction)

func _get_unlock_row_offset(strip: ScrollContainer) -> float:
    return strip.get_h_scroll_bar().value

# The bar is the offset of the row even when it is not drawn: writing its value is what
# makes the container scroll, and the arrows are refreshed from the signal it emits.
func _set_unlock_row_offset(strip: ScrollContainer, value: float) -> void:
    strip.get_h_scroll_bar().value = value

func _unlock_row_content_width(row: HBoxContainer) -> float:
    var width := 0.0
    for child in row.get_children():
        if not (child is Control):
            continue
        width += child.custom_minimum_size.x + float(UNLOCK_ICONS_SEPARATION)
    if row.get_child_count() > 0:
        width -= float(UNLOCK_ICONS_SEPARATION)
    return width

# The row needs arrows as soon as its content is wider than the whole strip; the width of
# the strip itself is not the test, because the arrows take slots out of it.
func _unlock_row_overflows(row: HBoxContainer) -> bool:
    return _unlock_row_content_width(row) > float(UNLOCK_ROW_PLAIN_WIDTH) + 0.5

# Which of the two arrows stand at this position of the row.
func _unlock_arrows_at(content: float, offset: float) -> Array[bool]:
    var needs := content > float(UNLOCK_ROW_PLAIN_WIDTH) + 0.5
    var left := needs and offset > 0.5
    # The right arrow asks whether the end of the content is out of reach even when it does
    # not take a slot itself: giving it one only makes the answer more yes.
    var right := needs and offset + float(UNLOCK_ROW_PLAIN_WIDTH) \
            - (float(UNLOCK_ROW_SLOT) if left else 0.0) < content - 0.5
    return [left, right]

# How much of the row the icons get at this position: the whole strip, minus the slots
# the arrows stand in.
func _unlock_row_window(content: float, offset: float) -> float:
    var arrows := _unlock_arrows_at(content, offset)
    return float(UNLOCK_ROW_PLAIN_WIDTH) \
            - (float(UNLOCK_ROW_SLOT) if arrows[0] else 0.0) \
            - (float(UNLOCK_ROW_SLOT) if arrows[1] else 0.0)

func _unlock_row_max_offset(content: float, offset: float) -> float:
    return maxf(0.0, content - _unlock_row_window(content, offset))

# The positions the row is allowed to rest in. A position that hides less than one slot of
# content behind the left arrow is not worth that slot: the hidden icon fits into it, so the
# row belongs at the beginning of the content instead, where the icon is drawn.
func _unlock_canonical_offset(content: float, offset: float) -> float:
    if offset > 0.5 and offset <= float(UNLOCK_ROW_SLOT) + 0.5:
        return 0.0
    return offset

# One step of the wheel or of an arrow. A step is not always one slot of the bar: the arrow
# that appears on that step takes a slot of its own, so the step goes on until it really
# brings a new icon in.
func _unlock_scroll_by(strip: ScrollContainer, row: HBoxContainer, direction: int) -> void:
    var content := _unlock_row_content_width(row)
    var offset := _unlock_canonical_offset(content, _get_unlock_row_offset(strip))
    var edge := offset + _unlock_row_window(content, offset)
    var target := offset + direction * float(UNLOCK_ROW_SLOT)
    while direction > 0 \
            and target < _unlock_row_max_offset(content, target) - 0.5 \
            and target + _unlock_row_window(content, target) <= edge + 0.5:
        target += float(UNLOCK_ROW_SLOT)
    target = _unlock_canonical_offset(content, target)
    _set_unlock_row_offset(strip, clampf(target, 0.0, _unlock_row_max_offset(content, target)))

func _refresh_unlock_arrows(btn: Button, strip: ScrollContainer, row: HBoxContainer) -> void:
    if btn == null or not is_instance_valid(btn):
        return
    var content := _unlock_row_content_width(row)
    var offset := _get_unlock_row_offset(strip)
    var canonical := _unlock_canonical_offset(content, offset)
    if not is_equal_approx(canonical, offset):
        # The bar clamps the row to its own idea of the end, which can be one of the positions
        # an arrow is not worth; the position decides the arrows, so it is corrected first.
        _set_unlock_row_offset(strip, canonical)
        return
    var arrows := _unlock_arrows_at(content, offset)
    # The strip gives up the slots the arrows stand in, so the icons scroll past a free
    # gutter instead of sliding under a button.
    strip.offset_left = UNLOCK_ICONS_LEFT + (UNLOCK_ROW_SLOT if arrows[0] else 0)
    strip.offset_right = -(8 + (UNLOCK_ROW_SLOT if arrows[1] else 0))
    var left_arrow := btn.get_node_or_null("UnlockArrowLeft")
    var right_arrow := btn.get_node_or_null("UnlockArrowRight")
    if left_arrow != null:
        left_arrow.visible = arrows[0]
    if right_arrow != null:
        right_arrow.visible = arrows[1]

func _get_unlock_items(tech_id: String) -> Array:
    # Assembles the list of {"icon", "tip"} — everything that the technology opens.
    # The sources: the buildings (buildings.json), the improvements (improvements.json),
    # the special actions (special_actions.json), the modifier effects
    # (modifiers.json, tech_modifiers with the fields icon/name), an arbitrary
    # list "unlock_effects": [ {"icon", "name"} ] in the technology itself and the
    # production slots the technology grants (tech_modifiers, "building_production_slots").
    var result: Array = []
    var seen := {} # protection from the duplicates (the same icon+tooltip)

    # The buildings.
    for b in GameData.buildings:
        if b.get("unlock_tech", "") == tech_id:
            _add_unlock_item(result, seen, b.get("icon", ""), b.get("name", b.get("id", "")))

    # The improvements (GameData.improvements is a dictionary id -> data).
    for imp_id in GameData.improvements:
        var imp: Dictionary = GameData.improvements[imp_id]
        if imp.get("unlock_tech", "") == tech_id:
            _add_unlock_item(result, seen, imp.get("icon", ""), imp.get("name", imp_id))

    # The special actions (special_actions.json, the field unlock_tech).
    for sa_id in GameData.special_actions:
        var sa: Dictionary = GameData.special_actions[sa_id]
        if sa.get("unlock_tech", "") == tech_id:
            _add_unlock_item(result, seen, sa.get("icon", ""), sa.get("name", sa_id))

    # The road levels (data/roads.json, the field unlock_tech). Without them the tree would not show
    # that the technology opens anything, apart from what has already been added into the technology
    # unlock_effects: the icons of the road levels in the tree are more useful — by them one can immediately
    # see how much more passable the road will become.
    for road in GameData.roads:
        if road is Dictionary and str(road.get("unlock_tech", "")) == tech_id:
            _add_unlock_item(result, seen, "road.svg",
                    tr("%s: up to %d units/sec per section") % [str(road.get("name", "")),
                            int(road.get("max_speed", 0))])

    # The recipes (data/crafts/*.json, the field unlock_tech). Unlike the buildings, they are
    # not drawn one by one: one technology opens up to fourteen of them, and the row has room
    # for four icons of content of any kind. One badge stands for the whole set, and the list
    # of what it opens belongs to its tooltip.
    # A premium recipe joins the list only when the rung of the brand has granted the good: before
    # that the research opens the ordinary recipe alone, and the name of the city is not yet earned.
    # The lines speak the names the workshop slots speak (GameData.get_craft_display_name), so the
    # brand good is announced by the city, not by the title written in the data.
    var recipe_names: Array[String] = []
    for craft in GameData.crafts:
        if craft.get("unlock_tech", "") != tech_id:
            continue
        if not CityData.is_craft_fame_granted(craft):
            continue
        recipe_names.append(GameData.get_craft_display_name(craft))
    if not recipe_names.is_empty():
        recipe_names.sort()
        var recipe_tip := tr("Unlocks recipes:")
        for recipe_name in recipe_names:
            recipe_tip += "\n- " + recipe_name
        _add_unlock_item(result, seen, ICON_NEW_RECIPES, recipe_tip)

    # The modifier effects of the technology (modifiers.json -> tech_modifiers).
    var mods: Dictionary = GameData.modifiers
    for m in mods.get("tech_modifiers", []):
        if not (m is Dictionary):
            continue
        if m.get("tech_id", "") != tech_id:
            continue
        if m.has("icon"):
            var tip: String = m.get("name", tr("Technology effect"))
            _add_unlock_item(result, seen, m["icon"], tip)

    # The arbitrary effects, specified directly in the technology (technologies.json):
    # "unlock_effects": [ { "icon": "farm.png", "name": "Farms: +50%" } ].
    var tech_data: Dictionary = _get_tech_data(tech_id)
    for eff in tech_data.get("unlock_effects", []):
        if eff is Dictionary:
            _add_unlock_item(result, seen, eff.get("icon", ""), eff.get("name", tr("Technology effect")))

    var slot_lines: Array[String] = []
    for m in mods.get("tech_modifiers", []):
        if not (m is Dictionary) or m.get("tech_id", "") != tech_id:
            continue
        var grants: Dictionary = m.get("building_production_slots", {})
        for building_id in grants:
            if GameData.get_building_data(str(building_id)).is_empty():
                continue
            slot_lines.append("%s: %s" % [
                    GameData.get_building_display_name(str(building_id)),
                    tr("+%d production slot") % int(grants[building_id])])
    if not slot_lines.is_empty():
        slot_lines.sort()
        var slot_tip := tr("Extra production slots:")
        for line in slot_lines:
            slot_tip += "\n- " + line
        _add_unlock_item(result, seen, CityData.ICON_PRODUCTION_SLOT, slot_tip)

    return result

func _add_unlock_item(result: Array, seen: Dictionary, icon_name: String, tip: String):
    if icon_name.is_empty():
        return
    var key := icon_name + "|" + tip
    if seen.has(key):
        return
    seen[key] = true
    result.append({"icon": icon_name, "tip": tip})

func _adjust_fonts() -> void:
    # We select the largest font_size at which the name fits into 2 lines inside
    # the button. Deferred, so that the layout is ready. The size is measured
    # analytically through TextServer for all labels at once, without changing
    # font_size per iteration — so the whole pass costs a single frame, not
    # (sizes x technologies) frames.
    if _fonts_adjusted:
        return
    if not is_inside_tree():
        return
    await get_tree().process_frame
    if not is_inside_tree():
        return
    var font := get_theme_font("font", "Label")
    if font == null:
        font = ThemeDB.fallback_font
    for tech_id in _tech_nodes:
        var entry = _tech_nodes[tech_id]
        if not is_instance_valid(entry):
            continue
        var btn: Button = entry["button"]
        if not is_instance_valid(btn):
            continue
        var label: Label = _find_label_in_button(btn)
        if label == null or not is_instance_valid(label):
            continue
        # The usable text width is the label width minus the autowrap padding.
        var text_width: float = maxf(label.size.x - 2.0, 1.0)
        var picked := 10
        for fs in [10, 11, 12, 13, 14]:
            var lines: int = _wrapped_line_count(font, fs, label.text, text_width)
            if lines <= 2:
                picked = fs
            else:
                # This size already does not fit — stop: sizes grow from smaller to larger.
                break
        label.add_theme_font_size_override("font_size", picked)
    _fonts_adjusted = true

func _wrapped_line_count(font: Font, font_size: int, text: String, width: float) -> int:
    # Mirrors the word-smart autowrap of the Label. TextParagraph measures the
    # wrap analytically, without touching the label — this is what keeps the
    # whole font-selection pass to a single frame. (Font.get_wrap_width is not
    # available in this Godot version.)
    var paragraph := TextParagraph.new()
    paragraph.add_string(text, font, font_size, "", "")
    paragraph.width = width
    return paragraph.get_line_count()

func _find_label_in_button(btn: Button) -> Label:
    # In Godot 4 the Button has a built-in label (btn.get_label_control() in 4.4+,
    # but we add our own under the name TechNameLabel).
    for child in btn.get_children():
        if child is MarginContainer:
            for c2 in child.get_children():
                if c2 is HBoxContainer:
                    for c3 in c2.get_children():
                        if c3 is Label and c3.name == "TechNameLabel":
                            return c3
    return null

func _load_tech_icon(icon_name: String) -> Texture2D:
    return IconRegistry.get_texture(icon_name)

func _get_tech_data(tech_id: String) -> Dictionary:
            # The pure weighted average of the special_yield of the mixture, without the bonuses.
    for t in GameData.technologies:
        if t["id"] == tech_id:
            return t
    return {}

func _update_states():
    # " (Name1, Name2)" by the unique names in the order of the first appearance; for
    # an empty list — an empty string.
    var unlocked = CityData.unlocked_technologies
    var current_id: String = CityData.current_research_tech_id

    for tech_id in _tech_nodes:
        var entry = _tech_nodes[tech_id]
        var btn: Button = entry["button"]
        var is_unlocked: bool = tech_id in unlocked
        var is_current: bool = tech_id == current_id
        var is_available: bool = CityData.is_tech_available(tech_id)

        _style_button(btn, is_unlocked, is_current, is_available, tech_id)

        # The position: under the label (the global rect of the label minus the global position
        var progress: ProgressBar = _find_progress_in_button(btn)
        if progress != null:
            if is_current:
                progress.visible = true
                progress.value = CityData.research_progress * 100.0
            else:
                progress.visible = false

        # The tooltip with the actual state
        _update_tech_tooltip(btn, tech_id)
    
func _attach_tech_tooltip(btn: Button, tech_id: String) -> void:
    # The wrapping tooltip of the project: the built-in tooltip of the engine draws
    # its text in one line, and the description of a technology does not fit in one.
    # The carrier is laid over the button, but it stops above the row of the unlock
    # icons: those icons have their own tooltips, and the row needs the mouse for
    # the wheel that scrolls it.
    var carrier := WrappedTooltip.attach(btn, _tech_tooltip_text(tech_id))
    if btn.get_node_or_null("UnlockIconsScroll") != null:
        carrier.offset_bottom = -(UNLOCK_ICON_SIZE + UNLOCK_ICONS_MARGIN)

func _update_tech_tooltip(btn: Button, tech_id: String) -> void:
    # The text of the tooltip follows the state of the technology. A repeated
    # assignment takes the open tooltip down, so the text is only replaced when it
    # has really changed (the same rule as in trade_tab._set_tooltip).
    var carrier := WrappedTooltip.find_carrier(btn)
    if carrier == null:
        return
    var text := _tech_tooltip_text(tech_id)
    if carrier.tooltip_text == text:
        return
    carrier.tooltip_text = text

func _tech_tooltip_text(tech_id: String) -> String:
    # The text of the tooltip of the technology: the description, the cost of the
    # research and the state of the technology.
    var tech_data := _get_tech_data(tech_id)
    if tech_data.is_empty():
        return ""
    var desc: String = tech_data.get("description", "")
    if desc.is_empty():
        desc = tr("No description available.")
    var cost: int = int(tech_data.get("science_cost", 3))
    return tr("%s\nScience: %d%s") % [desc, cost, _tech_state_text(tech_id)]

# The state of the technology, as it is shown at the end of the tooltip.
func _tech_state_text(tech_id: String) -> String:
    if tech_id in CityData.unlocked_technologies:
        return tr("\n\n[Researched]")
    if tech_id == CityData.current_research_tech_id:
        return tr("\n\n[Researching]")
    if CityData.is_tech_available(tech_id):
        return ""
    if CityData.is_tech_era_allowed(tech_id):
        var prereq: String = CityData.get_tech_prerequisites_text(tech_id)
        if not prereq.is_empty():
            return tr("\n\n[Required: %s]") % prereq
        return ""
    # The prerequisites are met, but the era of the technology is above the current one.
    var era_idx: int = CityData.get_tech_era_index(tech_id)
    var era_name: String = ""
    if era_idx >= 0 and era_idx < GameData.eras.size():
        era_name = GameData.eras[era_idx].get("name", "")
    if era_name.is_empty():
        return tr("\n\n[Unavailable: requires advancing to the next era]")
    return tr("\n\n[Era: %s — advance to it first]") % era_name

func _find_progress_in_button(btn: Button) -> ProgressBar:
    for child in btn.get_children():
        if child is ProgressBar and child.name == "TechProgress":
            return child
    return null

func _style_button(btn: Button, is_unlocked: bool, is_current: bool, is_available: bool, tech_id: String = ""):
    # The styles depend on the state. All the styles inherit the common properties
    # (the border, the rounding), but differ in the background.
    var bg := UI_THEME.color("control_bg")
    var hover := UI_THEME.color("control_hover").darkened(0.15)
    var pressed := UI_THEME.color("control_bg").darkened(0.08)
    var font_col := UI_THEME.color("text_muted")
    # A locked technology fades by the same dim the inert rows of the trade screens use.
    var modulate_col := UI_THEME.color("row_dim")
    modulate_col.a = 0.9

    if is_unlocked:
        bg = UI_THEME.color("income").darkened(0.45)
        hover = UI_THEME.color("income").darkened(0.35)
        pressed = UI_THEME.color("income").darkened(0.5)
        font_col = UI_THEME.color("income").lightened(0.6)
        modulate_col = Color(1, 1, 1, 0.9)
    elif is_current:
        bg = UI_THEME.color("fill").darkened(0.2)
        hover = UI_THEME.color("fill").darkened(0.1)
        pressed = UI_THEME.color("fill").darkened(0.35)
        font_col = UI_THEME.color("warning").lightened(0.2)
        modulate_col = Color.WHITE
    elif is_available:
        bg = UI_THEME.color("control_hover").lightened(0.05)
        hover = UI_THEME.color("control_hover").lightened(0.2)
        pressed = UI_THEME.color("control_pressed").lightened(0.2)
        font_col = UI_THEME.color("text")
        modulate_col = Color.WHITE

    var style_normal := _make_button_stylebox(bg)
    var style_hover := _make_button_stylebox(hover)
    var style_pressed := _make_button_stylebox(pressed)
    var style_disabled := _make_button_stylebox(bg)

    btn.add_theme_stylebox_override("normal", style_normal)
    btn.add_theme_stylebox_override("hover", style_hover)
    btn.add_theme_stylebox_override("pressed", style_pressed)
    btn.add_theme_stylebox_override("disabled", style_disabled)
    btn.add_theme_color_override("font_color", font_col)
    btn.modulate = modulate_col
    
    # The highlighting of the frame for the related technologies on hover.
    if not tech_id.is_empty() and _related_techs.has(tech_id):
        var border_color := UI_THEME.color("info")
        style_normal.border_color = border_color
        style_hover.border_color = border_color
        style_pressed.border_color = border_color
        style_normal.set_border_width_all(3)
        style_hover.set_border_width_all(3)
        style_pressed.set_border_width_all(3)
        btn.add_theme_stylebox_override("normal", style_normal)
        btn.add_theme_stylebox_override("hover", style_hover)
        btn.add_theme_stylebox_override("pressed", style_pressed)
        btn.add_theme_stylebox_override("disabled", style_disabled)
    
    # All the buttons remain clickable — the correctness of the start of the research
    # is checked by CityData.start_research() and it emits research_error in case of
    # a conflict (another one is already going, the requirements are not met, and so on).
    btn.disabled = false

func _make_button_stylebox(bg_color: Color, border_width: int = 1) -> StyleBoxFlat:
    var s := StyleBoxFlat.new()
    s.bg_color = bg_color
    s.set_border_width_all(border_width)
    s.border_color = UI_THEME.color("panel_bg").darkened(0.4)
    s.set_corner_radius_all(int(UI_THEME.metric("panel_radius")))
    return s

func refresh():
    # A full update. It is used on the structural changes
    # (a new/completed research).
    rebuild()

func update_values():
    # A light update: only the styles/tooltips/progress.
    _update_states()
    if is_instance_valid(_arrows_layer):
        _arrows_layer.queue_redraw()
    _update_status_label()

func update_progress():
    # A light update: only the label of the current research.
    _update_status_label()
    # The science tooltip is alive: while the cursor is on the label, the contents are updated every
    # tick (the breakdown is reassembled from the cache CityData.science_breakdown).
    if science_tooltip_panel != null and science_tooltip_panel.visible:
        _rebuild_science_tooltip()
        _position_science_tooltip()

func _update_status_label():
    if current_label == null:
        return
    # The rate of the science of the city — a direct sum of the sources: the base + the contribution of the working
    # science buildings (it is visible only here, on the "Technologies" tab). There is no pool of science:
    # this same rate is directly credited to the progress of the research
    # (CityData.tick_research_science_continuous).
    if science_pool_label != null and is_instance_valid(science_pool_label):
        science_pool_label.text = tr("Science: %.1f/sec") % CityData.get_science_rate_per_sec()
    if CityData.current_research_tech_id != "":
        var tech_data = _get_tech_data(CityData.current_research_tech_id)
        if not tech_data.is_empty():
            var collected: float = CityData.get_research_science_collected()
            var cost: int = CityData.current_research_science_cost
            current_label.text = tr("Researching: %s (science: %.0f/%d)") % [tech_data["name"], collected, cost]
            return
        current_label.text = tr("Researching: ???")
    else:
        current_label.text = tr("No current research")
func _on_tech_pressed(tech_id: String):
    emit_signal("research_requested", tech_id)

func _on_tech_button_mouse_entered(tech_id: String):
    if _hovered_tech_id == tech_id:
        return
    _hovered_tech_id = tech_id
    _update_related_techs(tech_id)
    _update_hover_states()

func _on_tech_button_mouse_exited(tech_id: String):
    if _hovered_tech_id != tech_id:
        return
    _hovered_tech_id = ""
    _related_techs.clear()
    _update_hover_states()

func _update_related_techs(tech_id: String):
    # We assemble the WHOLE chain of the relations: all the ancestors up to the roots and all the descendants up to the leaves.
    _related_techs.clear()
    _related_techs[tech_id] = true # the technology itself is also highlighted

    # The dependency maps "child -> [parents]" and "parent -> [children]". Built once
    # and reused on every hover; invalidated when the static tech data changes.
    _ensure_relations_maps()

    # All the ancestors (recursively, up to the roots).
    _collect_ancestors(tech_id, _parents_map, _related_techs)
    # All the descendants (recursively, up to the leaves).
    _collect_descendants(tech_id, _children_map, _related_techs)

func _collect_ancestors(tech_id: String, parents_map: Dictionary, result: Dictionary) -> void:
    # Adds all the ancestors of tech_id to result along the chain (up to the roots).
    if not parents_map.has(tech_id):
        return
    for parent_id in parents_map[tech_id]:
        if result.has(parent_id):
            continue
        result[parent_id] = true
        _collect_ancestors(parent_id, parents_map, result)

func _collect_descendants(tech_id: String, children_map: Dictionary, result: Dictionary) -> void:
    # Adds all the descendants of tech_id to result along the chain (up to the leaves).
    if not children_map.has(tech_id):
        return
    for child_id in children_map[tech_id]:
        if result.has(child_id):
            continue
        result[child_id] = true
        _collect_descendants(child_id, children_map, result)

func _update_hover_states():
    # We update the styles of the buttons and redraw the arrows.
    _update_states()
    if is_instance_valid(_arrows_layer):
        _arrows_layer.queue_redraw()

func _on_arrows_draw():
    # We draw the vertical line-separators between the eras and the arrows
    # of the dependencies. The coordinates are counted in the system of _arrows_layer (== _inner).
    if _arrows_layer == null:
        return

    # --- The vertical lines between the eras (they are drawn ALWAYS, not only on hover) ---
    # The line is drawn along the right edge of each group of the eras, except for the last one
    # (there is no next era to the right of it). It stretches from the top to the bottom of the tree.
    for i in range(_era_groups.size() - 1):
        var group = _era_groups[i]
        var x: float = group["x_boundary"]
        var y_top: float = 0.0
        var y_bottom: float = _inner.size.y
        _arrows_layer.draw_line(
            Vector2(x, y_top),
            Vector2(x, y_bottom),
            UI_THEME.color("hairline"),
            ERA_LINE_WIDTH
        )

    # We show the arrows only on hover over a technology.
    if _hovered_tech_id.is_empty():
        return

    var color_hover := UI_THEME.color("info") # a bright accent for the highlighted relations

    # The dependency maps "parent -> [children]" / "child -> [parents]". Built once and
    # reused on every redraw; invalidated when the static tech data changes.
    _ensure_relations_maps()

    var line_width := 2.0
    for parent_id in _children_map:
        if not _tech_nodes.has(parent_id):
            continue
        var parent_entry = _tech_nodes[parent_id]
        var parent_col: Control = _columns[parent_entry["column"]]
        var parent_btn: Button = parent_entry["button"]
        # The right edge of the button of the parent (in the coordinates of _inner)
        var parent_right: Vector2 = parent_col.position + Vector2(
            parent_btn.position.x + parent_btn.size.x,
            parent_btn.position.y + parent_btn.size.y * 0.5
        )

        for child_id in _children_map[parent_id]:
            if not _tech_nodes.has(child_id):
                continue
            var child_entry = _tech_nodes[child_id]
            var child_col: Control = _columns[child_entry["column"]]
            var child_btn: Button = child_entry["button"]
            # The left edge of the button of the child
            var child_left: Vector2 = child_col.position + Vector2(
                child_btn.position.x,
                child_btn.position.y + child_btn.size.y * 0.5
            )

            # On hover we show the arrows, both ends of which enter
            # the highlighted chain (the parent and the child are a part of the path).
            var is_related: bool = _related_techs.has(parent_id) and _related_techs.has(child_id)
            if not is_related:
                continue

            # We highlight the related arrows with blue.
            var color: Color = color_hover

            # The path of the arrow: for the neighbouring columns — a simple zigzag,
            # for the distant ones — through a free Y-corridor, so as not to draw
            # over the buttons of the intermediate columns.
            var points := _build_arrow_path(
                parent_right, child_left,
                parent_entry["column"], child_entry["column"]
            )
            _arrows_layer.draw_polyline(points, color, line_width, true)
            _draw_arrow_head(child_left, Vector2(-1, 0), color, line_width)

func _draw_arrow_head(pos: Vector2, dir: Vector2, color: Color, _line_width: float):
    # A small triangle-arrow at the end of the line.
    var head_size := 8.0
    var perp := Vector2(-dir.y, dir.x) * head_size * 0.5
    var base: Vector2 = pos + dir * head_size
    var p1: Vector2 = base + perp
    var p2: Vector2 = base - perp
    var points := PackedVector2Array([pos, p1, p2])
    _arrows_layer.draw_colored_polygon(points, color)

func _column_gap_x(c: int) -> float:
    # The X-coordinate of the middle of the gap between the column c and c+1 (in the coordinates of _inner).
    # The gap is empty — the vertical segments of the arrows are drawn exactly here,
    # so as not to intersect the buttons of the neighbouring columns.
    return COL_PADDING + c * (BUTTON_WIDTH + COL_GAP) + BUTTON_WIDTH + COL_GAP * 0.5

func _find_free_y_between(parent_col: int, child_col: int, target_y: float) -> float:
    # Looks for a free Y-level at which there are no buttons in ALL the intermediate columns
    # (parent_col+1 .. child_col-1). It returns the Y closest to
    # target_y, or -1, if there is no free level.
    #
    # The horizontal segment of the arrow, going from the column parent_col to child_col,
    # physically intersects the intermediate columns. So as not to draw over
    # the buttons, it must pass at a Y free from the buttons in all these columns.
    # The horizontal segment of the arrow, going from the column parent_col to child_col,
    # physically intersects the intermediate columns. So as not to draw over
    # the buttons, it must pass at a Y free from the buttons in all these columns.
    var occupied: Array = [] # [y_start, y_end] of the occupied intervals
    for c in range(parent_col + 1, child_col):
        var col: Control = _columns[c]
        for tech_id in _tech_nodes:
            var entry = _tech_nodes[tech_id]
            if entry["column"] != c:
                continue
            var btn: Button = entry["button"]
            var y: float = col.position.y + btn.position.y
            occupied.append([y, y + BUTTON_HEIGHT])
    if occupied.is_empty():
        # There are no intermediate columns — any Y is free.
        return target_y

    # We sort by y_start.
    occupied.sort()

    # The margin for the thickness of the line (2px) + a small indent, so that the line does not
    # touch the buttons closely.
    var margin: float = 4.0
    var best_y: float = -1.0
    var best_dist: float = INF
    var cursor: float = 0.0 # the beginning of the current free gap

    for interval in occupied:
        var y_start: float = interval[0]
        var y_end: float = interval[1]
        if y_start - cursor > margin * 2.0:
            # The free gap [cursor, y_start] is wide enough.
            var free_y: float = (cursor + y_start) * 0.5
            var dist: float = absf(free_y - target_y)
            if dist < best_dist:
                best_dist = dist
                best_y = free_y
        cursor = max(cursor, y_end)

    # The gap after the last occupied interval — to the end of the tree.
    if _inner.size.y - cursor > margin * 2.0:
        var free_y: float = (cursor + _inner.size.y) * 0.5
        var dist: float = absf(free_y - target_y)
        if dist < best_dist:
            best_y = free_y

    return best_y

func _build_arrow_path(parent_right: Vector2, child_left: Vector2, parent_col: int, child_col: int) -> PackedVector2Array:
    # Builds the polyline of the arrow from the right edge of the parent to the left edge of the child.
    #
    # For the neighbouring columns (child_col - parent_col == 1) — a simple zigzag:
    # the vertical segment lies in the empty gap between the columns and does not
    # intersect the buttons.
    #
    
    #
    # For the distant columns (child_col - parent_col > 1) — a path through the free
    # Y-corridor: the vertical segments in the gaps between the columns, the horizontal
    # segment at a Y free from the buttons in all the intermediate columns.
    #
    # There is no free corridor — a fallback to the simple zigzag.
    if child_col - parent_col <= 1:
        var mid_x: float = (parent_right.x + child_left.x) * 0.5
        return PackedVector2Array([
            parent_right,
            Vector2(mid_x, parent_right.y),
            Vector2(mid_x, child_left.y),
            child_left,
        ])

    var target_y: float = (parent_right.y + child_left.y) * 0.5
    var free_y: float = _find_free_y_between(parent_col, child_col, target_y)
    if free_y < 0.0:
        # There is no free corridor — a fallback to the simple zigzag.
        var mid_x: float = (parent_right.x + child_left.x) * 0.5
        return PackedVector2Array([
            parent_right,
            Vector2(mid_x, parent_right.y),
            Vector2(mid_x, child_left.y),
            child_left,
        ])

    var gap1_x: float = _column_gap_x(parent_col)
    var gap2_x: float = _column_gap_x(child_col - 1)
    return PackedVector2Array([
        parent_right,
        Vector2(gap1_x, parent_right.y),
        Vector2(gap1_x, free_y),
        Vector2(gap2_x, free_y),
        Vector2(gap2_x, child_left.y),
        child_left,
    ])

func _process(_delta: float) -> void:
    # The per-frame update of the progress bar on the button of the current technology:
    # research_progress grows continuously (tick_research_science_continuous),
    # and _update_states is called only on the ticks/events — without this the bar
    # jerked and lagged behind the actual progress.
    if not is_visible_in_tree():
        return
    if CityData.current_research_tech_id == "":
        return
    var entry = _tech_nodes.get(CityData.current_research_tech_id)
    if entry == null:
        return
    var progress: ProgressBar = _find_progress_in_button(entry["button"])
    if progress != null and progress.visible:
        progress.value = CityData.research_progress * 100.0
