# resources_tab.gd
extends Node

# The "single source of truth" script for the styling constants. It is needed at the parsing stage
# for the const QUALITY_MARKER_COLOR below (in GDScript a constant does not see
# the variables declared later, but it does see the preloaded scripts).
const UiHelpers = preload("res://scripts/ui_helpers.gd")

# The blue star marker at the beginning of the quality label (see _update_quality_label).
# The colour is taken from ui_helpers.QUALITY_MARKER_COLOR — the same interface accent
# in the "Trade" cards: the marker must not look like a quality level,
# therefore it does not coincide with any of the colours of data/qualities.json.
const QUALITY_MARKER_COLOR := UiHelpers.QUALITY_MARKER_COLOR

var ui_helpers: Node
var products: Dictionary = {}
var categories: Array = []
var city_storage: Dictionary = {}
var city_quality_detail: Dictionary = {}
var production_rates: Dictionary = {}
var consumption_rates: Dictionary = {}
var city_food_pool: Dictionary = {}
var food_toggles: Dictionary = {}
var amount_labels: Dictionary = {}
var prod_labels: Dictionary = {}
var cons_labels: Dictionary = {}
var quality_labels: Dictionary = {}
var displayed_products: Dictionary = {}
var row_flow_labels: Dictionary = {}
var diversity_label: Label = null

# The active quality tooltip (product, name) — for the real-time update.
var active_quality_product: String = ""
var active_quality_name: String = ""
# The active tooltip of the sources of income/expense (product, name) — for the real-time update.
var active_flow_product: String = ""
var active_flow_name: String = ""

# A reference to WorkerManager (it is passed from main_map through city_ui.set_worker_manager).
# The planned consumption of the resources is computed by it (see _update_planned_consumption_map).
var worker_manager: Node = null
# The cache of the map of the planned consumption: product_id -> { "Source name" -> {...} }.
# It is recalculated on every update_data()/refresh() (once per tick with the city open).
var planned_consumption_map: Dictionary = {}
# The cache of the map of the planned production (the recipes of the buildings with a citizen + the improvements
# on the map with their production_interval): product_id ->
# { "Source name" -> { "amount": N, "interval": S, "count": M } }.
# It is recalculated in the same place.
var planned_production_map: Dictionary = {}

var resources_list: Node

func setup(res_list: Node, helpers: Node):
    resources_list = res_list
    ui_helpers = helpers

# A reference to WorkerManager is passed from main_map through
# city_ui.set_worker_manager() (it is called in the _ready of main_map — later than the _ready of
# city_ui, where the tab is created). Before it is passed, planned_consumption_map
# is empty: the tab works as before, only on the actual dynamics per tick.
func set_worker_manager(wm: Node):
    worker_manager = wm

func update_data(data: Dictionary):
    products = data.get("products", {})
    categories = data.get("categories", [])
    city_storage = data.get("city_storage", {})
    city_quality_detail = data.get("city_quality_detail", {})
    production_rates = data.get("production_rates", {})
    consumption_rates = data.get("consumption_rates", {})
    city_food_pool = data.get("city_food_pool", {})
    _update_planned_consumption_map()
    planned_production_map = CityData.get_planned_production_map()

# Recalculates the cache of the planned consumption by worker_manager. If the reference has not
# been passed yet (the early calls before the initialization of main_map) — the map is empty, the tab
# works as before (only the actual dynamics per tick).
func _update_planned_consumption_map():
    planned_consumption_map.clear()
    if worker_manager != null and is_instance_valid(worker_manager) \
            and worker_manager.has_method("get_planned_consumption_map"):
        planned_consumption_map = worker_manager.get_planned_consumption_map()
    # The planned consumption of the improvements (the pasture feed per cycle) lies in CityData:
    # worker_manager knows only about the professions, the city "all" and the demand of the buildings.
    var improvement_demand = CityData.get_improvement_planned_consumption()
    for pid in improvement_demand:
        for source_id in improvement_demand[pid]:
            var e: Dictionary = improvement_demand[pid][source_id]
            if not planned_consumption_map.has(pid):
                planned_consumption_map[pid] = {}
            var by_source: Dictionary = planned_consumption_map[pid]
            if not by_source.has(source_id):
                by_source[source_id] = {"amount": 0, "interval": float(e.get("interval", 0.0)), "count": 0, "is_group": false, "group_name": "", "is_population": false}
            var entry: Dictionary = by_source[source_id]
            entry["amount"] = int(entry.get("amount", 0)) + int(e.get("amount", 0))
            entry["count"] = int(entry.get("count", 0)) + int(e.get("count", 1))
            entry["interval"] = minf(float(entry.get("interval", 0.0)), float(e.get("interval", 0.0)))
    # The feeding of the population: it is added as the planned consumption for all the products
    # from city_food_pool. The total expense per second = (total_population - 1) ×
    # food_per_citizen (one citizen is the founder, he does not eat), the interval SIMULATION_TICK.
    # After the commit 5790016 the tooltip shows only the planned consumption —
    # therefore the actual "Feeding the population" is now present here as a
    # plan (consumption_sources is no longer maintained). count = the number of the eating
    # citizens, so that the tooltip of the UI shows "(N people)" next to the source.
    var eaters := int(max(0, CityData.total_population - 1))
    if eaters > 0:
        var pop_food_demand := eaters * int(CityData.food_per_citizen)
        for pid in CityData.city_food_pool:
            if not CityData.city_food_pool.get(pid, false):
                continue
            if not planned_consumption_map.has(pid):
                planned_consumption_map[pid] = {}
            var by_source_pop: Dictionary = planned_consumption_map[pid]
            by_source_pop[GameData.SRC_POP_FOOD] = {
                "amount": pop_food_demand,
                "interval": CityData.SIMULATION_TICK,
                "count": eaters,
                "is_group": false,
                "group_name": "",
                "is_population": true
            }

# The planned consumption of a particular resource: { "Source name" -> {...} }.
func _get_planned_for(prod_id: String) -> Dictionary:
    return planned_consumption_map.get(prod_id, {})

# The general rule of the resource list: the row is visible only when the player has
# a source of income — the stock in the storage, the production per tick or the planned
# production (an existing producer building with a citizen).
# The planned CONSUMPTION of the row does NOT add: the members of an @-group without their own income
# (figs and jujube when only grapes from "Fruits" are produced; millet
# when only wheat from "Grains" is extracted) do not
# appear in the list and do not show the plan label. The import, when it appears, will give
# the row an income through the production/stock and will work by the same rule.
# The single source of truth for the visibility of the row is this method (and refresh(),
# and update_values()).
func _is_displayable(prod_id: String) -> bool:
    var amount = city_storage.get(prod_id, 0)
    if amount > 0:
        return true
    var prod_val = production_rates.get(prod_id, 0)
    if prod_val > 0:
        return true
    return not planned_production_map.get(prod_id, {}).is_empty()

func _get_subgroup_name(subgroup_id: String) -> String:
    for g in GameData.groups:
        if g["id"] == subgroup_id:
            return g["name"]
    return subgroup_id

# Returns the array of the subgroups of the resource. It supports both a string and an array.
func _get_subgroups(data: Dictionary) -> Array:
    var subgroup = data.get("subgroup", "other")
    if subgroup is Array:
        return subgroup
    return [subgroup]

func _get_icon_texture(icon_file: String) -> Texture2D:
    return IconRegistry.get_texture(icon_file)

func refresh():
    _update_planned_consumption_map()
    
    for child in resources_list.get_children():
        child.queue_free()
    food_toggles.clear()
    amount_labels.clear()
    prod_labels.clear()
    cons_labels.clear()
    quality_labels.clear()
    displayed_products.clear()
    diversity_label = null
    row_flow_labels.clear()
    active_flow_product = ""
    active_flow_name = ""
    if ui_helpers and is_instance_valid(ui_helpers):
        ui_helpers.hide_flow_tooltip()

    # --- The domesticated resources by the subgroups ---
    if CityData.domesticated_resources.size() > 0:
        var title = Label.new()
        title.text = tr("Tamed resources:")
        title.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
        resources_list.add_child(title)

        var animal_subgroups = {}
        for resource_id in CityData.domesticated_resources:
            var data = GameData.raw_resources.get(resource_id, {})
            for subgroup in _get_subgroups(data):
                if not animal_subgroups.has(subgroup):
                    animal_subgroups[subgroup] = []
                animal_subgroups[subgroup].append({"id": resource_id, "name": data.get("name", resource_id), "icon": data.get("icon", "")})

        for subgroup in animal_subgroups.keys():
            var subgroup_label = Label.new()
            subgroup_label.text = tr("  Subgroup: ") + _get_subgroup_name(subgroup)
            subgroup_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
            resources_list.add_child(subgroup_label)

            for animal in animal_subgroups[subgroup]:
                var row = HBoxContainer.new()
                row.add_theme_constant_override("separation", 6) # the distance between the icon and the text
                # Hovering over the icon/name shows the price of the resource
                var animal_flow_labels: Array = []
                if not animal["icon"].is_empty():
                    var tex = _get_icon_texture(animal["icon"])
                    if tex:
                        var icon_rect = TextureRect.new()
                        icon_rect.texture = tex
                        icon_rect.custom_minimum_size = Vector2(40, 40)
                        icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                        icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
                        # The icon does not stretch along the height of the row: if the row somehow
                        # becomes taller than 40 px (for example, due to a neighbouring label), the icon
                        # stays 40×40 and is simply centred, and not stretched into a
                        # column. By default SIZE_FILL stretches the TextureRect to the whole
                        # height, and STRETCH_SCALE distorts the picture.
                        icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
                        icon_rect.mouse_filter = Control.MOUSE_FILTER_PASS
                        icon_rect.mouse_entered.connect(_on_flow_hover.bind(animal["id"], animal["name"]))
                        icon_rect.mouse_exited.connect(_on_flow_exit.bind(animal["id"]))
                        row.add_child(icon_rect)
                        animal_flow_labels.append(icon_rect)
                var animal_label = Label.new()
                animal_label.text = animal["name"]
                animal_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
                animal_label.mouse_filter = Control.MOUSE_FILTER_PASS
                animal_label.mouse_entered.connect(_on_flow_hover.bind(animal["id"], animal["name"]))
                animal_label.mouse_exited.connect(_on_flow_exit.bind(animal["id"]))
                row.add_child(animal_label)
                animal_flow_labels.append(animal_label)
                resources_list.add_child(row)
                row_flow_labels[animal["id"]] = animal_flow_labels

        var spacer = Label.new()
        spacer.text = ""
        resources_list.add_child(spacer)

    # --- The goods by the categories ---
    var grouped = {}
    for prod_id in city_storage:
        # Science is not shown on the "Resources" tab: it is not a stored good,
        # but the research rate (see docs.md).
        if prod_id == "science":
            continue
        # The general rule of the list — see _is_displayable: the resource is visible only when
        # there is a source of income (the stock in the storage, the production per tick
        # or an existing producer building). The planned CONSUMPTION of the row
        # does not add: the members of an @-group without their own income (figs and jujube when
        # only grapes from "Fruits" are produced) do not get into the list and
        # do not show the plan label.
        if not _is_displayable(prod_id):
            continue
        var pdata = products.get(prod_id, {})
        var cat = pdata.get("category", "other")
        if not grouped.has(cat):
            grouped[cat] = []
        grouped[cat].append(prod_id)

    var ordered_cats = []
    for cat_entry in categories:
        var cat_id = cat_entry["id"]
        if grouped.has(cat_id):
            ordered_cats.append({"id": cat_id, "name": cat_entry["name"]})
    for cat_id in grouped.keys():
        var already = false
        for entry in ordered_cats:
            if entry["id"] == cat_id:
                already = true
                break
        if not already:
            ordered_cats.append({"id": cat_id, "name": cat_id})

    for cat_info in ordered_cats:
        var cat_id = cat_info["id"]
        var items = grouped[cat_id]
        if items.is_empty():
            continue
        var cat_label = Label.new()
        cat_label.text = "--- " + cat_info["name"] + " ---"
        cat_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
        resources_list.add_child(cat_label)

        for prod_id in items:
            var amount = city_storage[prod_id]
            var pdata = products.get(prod_id, {})
            var product_name = pdata.get("name", prod_id)
            var is_food = pdata.get("category") == "food"
            var row = HBoxContainer.new()
            row.add_theme_constant_override("separation", 6)
            resources_list.add_child(row)

            # The checkbox (only for the food)
            if is_food:
                var toggle = ColorRect.new()
                toggle.custom_minimum_size = Vector2(14, 14)
                var enabled = city_food_pool.get(prod_id, true)
                toggle.color = Color.GREEN if enabled else Color.RED
                toggle.mouse_filter = Control.MOUSE_FILTER_STOP
                toggle.gui_input.connect(_on_food_toggle_input.bind(prod_id, toggle))
                row.add_child(toggle)
                food_toggles[prod_id] = toggle

            # The icon
            var icon_name = ""
            if GameData.raw_resources.has(prod_id):
                icon_name = GameData.raw_resources[prod_id].get("icon", "")
            elif GameData.products.has(prod_id):
                icon_name = GameData.products[prod_id].get("icon", "")
            if not icon_name.is_empty():
                var tex = _get_icon_texture(icon_name)
                if tex:
                    var icon_rect = TextureRect.new()
                    icon_rect.texture = tex
                    icon_rect.custom_minimum_size = Vector2(40, 40)
                    icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
                    icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
                    # It does not stretch along the height of the row (see the same icon in the section
                    # of the domesticated resources above): the icon is always 40×40.
                    icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
                    row.add_child(icon_rect)

            var name_label = Label.new()
            name_label.text = "%s: %d  " % [product_name, amount]
            name_label.add_theme_color_override("font_color", Color.WHITE)
            # An explicit MOUSE_FILTER_PASS — otherwise the Label is STOP by default, and on
            # dragging/scrolling of the parent container the mouse events
            # may be "swallowed" by the row, and mouse_entered will not fire.
            name_label.mouse_filter = Control.MOUSE_FILTER_PASS
            row.add_child(name_label)
            amount_labels[prod_id] = name_label

            # The dynamics shows only the planned indicators.
            var green_label = Label.new()
            green_label.text = _format_prod_label(prod_id)
            green_label.add_theme_color_override("font_color", Color.GREEN)
            green_label.mouse_filter = Control.MOUSE_FILTER_PASS
            row.add_child(green_label)
            prod_labels[prod_id] = green_label

            var slash_label = Label.new()
            slash_label.text = " / "
            slash_label.add_theme_color_override("font_color", Color.WHITE)
            slash_label.mouse_filter = Control.MOUSE_FILTER_PASS
            row.add_child(slash_label)

            var red_label = Label.new()
            red_label.text = _format_cons_label(prod_id)
            red_label.add_theme_color_override("font_color", Color.RED)
            red_label.mouse_filter = Control.MOUSE_FILTER_PASS
            row.add_child(red_label)
            cons_labels[prod_id] = red_label
            # Hovering over the name or the dynamics shows the tooltip of the sources
            var flow_row_labels_arr: Array = []
            for flow_lbl in [name_label, green_label, slash_label, red_label]:
                flow_lbl.mouse_entered.connect(_on_flow_hover.bind(prod_id, product_name))
                flow_lbl.mouse_exited.connect(_on_flow_exit.bind(prod_id))
                flow_row_labels_arr.append(flow_lbl)
            row_flow_labels[prod_id] = flow_row_labels_arr

            # The breakdown by quality for this product
            _add_quality_label(row, prod_id, product_name)

            displayed_products[prod_id] = true

    # --- The diversity bonuses (a stub) ---
    var animal_subgroups_count = 0
    var plant_subgroups_count = 0
    var animal_subgroup_map = {}
    for resource_id in CityData.domesticated_resources:
        var data = GameData.raw_resources.get(resource_id, {})
        for subgroup in _get_subgroups(data):
            animal_subgroup_map[subgroup] = true
    animal_subgroups_count = animal_subgroup_map.size()

    var plant_subgroup_map = {}
    plant_subgroups_count = plant_subgroup_map.size()

    var total_subgroups = animal_subgroups_count + plant_subgroups_count
    if total_subgroups > 0:
        var spacer = Label.new()
        spacer.text = ""
        resources_list.add_child(spacer)
        var div_label = Label.new()
        div_label.text = tr("Diversity: %d subgroups") % total_subgroups
        div_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))
        resources_list.add_child(div_label)
        diversity_label = div_label

        var bonus_label = Label.new()
        bonus_label.text = tr("Active bonuses: (coming later)")
        bonus_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.3))
        resources_list.add_child(bonus_label)

func update_values():
    # A light refresh: we do not recreate the nodes, but update the texts of the existing ones.
    # If the composition of the list has changed (a source of income appeared or the last
    # one disappeared) — we call the full refresh.
    for prod_id in city_storage:
        # Science is stored in city_storage, but hidden in the storage — it is displayed
        # as a separate pool on the "Technologies" tab (see docs.md).
        if prod_id == "science":
            continue
        # The general rule of the visibility of the row — see _is_displayable: the source
        # of income (the stock, the production per tick or the producer building).
        # The planned consumption of the row does not add.
        var should_show = _is_displayable(prod_id)
        # The composition of the list has changed (an income appeared or the last
        # source disappeared) — we rebuild the list, as we do when a new product appears.
        if should_show != displayed_products.has(prod_id):
            refresh()
            return
        if not should_show:
            continue
        var amount_label = amount_labels.get(prod_id)
        if amount_label != null and is_instance_valid(amount_label):
            var pdata = products.get(prod_id, {})
            var prod_name = pdata.get("name", prod_id)
            amount_label.text = "%s: %d  " % [prod_name, city_storage.get(prod_id, 0)]
        var prod_label = prod_labels.get(prod_id)
        if prod_label != null and is_instance_valid(prod_label):
            prod_label.text = _format_prod_label(prod_id)
        var cons_label = cons_labels.get(prod_id)
        if cons_label != null and is_instance_valid(cons_label):
            cons_label.text = _format_cons_label(prod_id)
        var toggle = food_toggles.get(prod_id)
        if toggle != null and is_instance_valid(toggle):
            var enabled = city_food_pool.get(prod_id, true)
            toggle.color = Color.GREEN if enabled else Color.RED
        var q_label = quality_labels.get(prod_id)
        if q_label != null and is_instance_valid(q_label):
            _update_quality_label(q_label, prod_id)

    if diversity_label != null and is_instance_valid(diversity_label):
        var animal_subgroup_map = {}
        for resource_id in CityData.domesticated_resources:
            var data = GameData.raw_resources.get(resource_id, {})
            for subgroup in _get_subgroups(data):
                animal_subgroup_map[subgroup] = true
        var plant_subgroup_map = {}
        var total_subgroups = animal_subgroup_map.size() + plant_subgroup_map.size()
        diversity_label.text = tr("Diversity: %d subgroups") % total_subgroups

    # We update the open quality tooltip with the fresh data (in real time).
    if active_quality_product != "" and ui_helpers and is_instance_valid(ui_helpers):
        if ui_helpers.quality_tooltip_panel.visible:
            var fresh_detail = city_quality_detail.get(active_quality_product, {})
            if fresh_detail.is_empty():
                ui_helpers.hide_quality_tooltip()
            else:
                ui_helpers.show_quality_tooltip(
                    get_viewport().get_mouse_position(),
                    active_quality_name,
                    fresh_detail
                )

    # We update the open tooltip of the sources of income/expense with the fresh data.
    # The planned consumption and production do not depend on the tick — they are taken from the caches
    # planned_consumption_map / planned_production_map. The actual production/
    # consumption in the tooltip is no longer shown (see the commit 5790016).
    if active_flow_product != "" and ui_helpers and is_instance_valid(ui_helpers):
        if ui_helpers.flow_tooltip_panel.visible:
            var special_yield = GameData.get_special_yield(active_flow_product)
            var fresh_planned = _get_planned_for(active_flow_product)
            var fresh_planned_prod = planned_production_map.get(active_flow_product, {})
            if special_yield.is_empty() and fresh_planned.is_empty() \
                    and fresh_planned_prod.is_empty() \
                    and GameData.get_price(active_flow_product) <= 0.0:
                ui_helpers.hide_flow_tooltip()
            else:
                ui_helpers.show_flow_tooltip(
                    get_viewport().get_mouse_position(),
                    active_flow_name,
                    special_yield,
                    active_flow_product,
                    fresh_planned,
                    fresh_planned_prod,
                    # The breakdown by quality — fresh: while the good is being written off,
                    # the levels in the tooltip must disappear together with the stock.
                    CityData.get_quality_breakdown(active_flow_product)
                )

# Adds a label with the breakdown by quality to the resource row.
# Only if there is data about the quality for the product (city_quality_detail).
func _add_quality_label(row: HBoxContainer, prod_id: String, product_name: String):
    var detail = city_quality_detail.get(prod_id, {})
    var total = 0
    for qid in detail:
        total += int(detail[qid])
    if total <= 0:
        return

    # RichTextLabel, and not Label: BBCode (the [color=…] tags) exists only on it, and it is
    # needed so that each percentage in the breakdown is painted in the colour of its level.
    var quality_label := RichTextLabel.new()
    quality_label.bbcode_enabled = true
    quality_label.fit_content = true
    quality_label.scroll_active = false
    # The line wrapping inside the label MUST be turned off. While it is on,
    # RichTextLabel cannot report the width of the contents to the container:
    # get_minimum_size() = (1, 0), HBoxContainer gives the label exactly this 1 px,
    # and "★ (33%/67%)" stands in a column letter by letter. Because of this the row
    # sprawled to ~200 px in height, and the resource icon (STRETCH_SCALE +
    # vertical FILL) stretched to 40×200 — "broken" icons, and
    # the blue star marker was 1 pixel wide. With AUTOWRAP_OFF the label
    # reports the real width of the text (≈90 px), the row stays 40 px, the icon
    # 40×40. Verified by a headless probe and by an integration test
    # (tests/test_resource_display_interval.gd, point 3e).
    quality_label.autowrap_mode = TextServer.AUTOWRAP_OFF
    # The text in the middle of the row: RichTextLabel has its own theme, and without this the text
    # is pressed to the top, while the neighbouring Labels stand in the middle.
    quality_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    # We take the font size from the row itself: the theme configures the Label (font_size), while
    # RichTextLabel has its own theme (normal_font_size), and without this the text in the row
    # could differ from the neighbouring labels.
    quality_label.add_theme_font_size_override("normal_font_size", row.get_theme_font_size("font_size"))
    quality_label.add_theme_color_override("default_color", Color(1.0, 0.85, 0.2, 0.9))
    quality_label.mouse_filter = Control.MOUSE_FILTER_PASS # we pass the clicks to the parent button
    # Showing the stars on hover — the tooltip with the breakdown by quality
    quality_label.mouse_entered.connect(_on_quality_hover.bind(prod_id, product_name))
    quality_label.mouse_exited.connect(_on_quality_exit)
    _update_quality_label(quality_label, prod_id)
    row.add_child(quality_label)
    quality_labels[prod_id] = quality_label

# Updates the text of the quality label: one blue star as the sign that
# the good has a quality, and the breakdown of the storage by levels — "★ (33%/67%)", where each
# percentage is painted in the colour of its level.
# Previously there were the stars of the BEST level and its share of the rest
# ("★★★★ (67%)" for a storage of 3147 common and 6365 exceptional), and the row read
# as "two thirds of the storage is exceptional" instead of "two thirds of the common is exceptional".
# Now all the levels are visible at once, and the percentages honestly add up to 100%.
func _update_quality_label(label: RichTextLabel, prod_id: String):
    var detail = city_quality_detail.get(prod_id, {})
    var share_text: String = GameData.format_quality_share_text(detail)
    if share_text == "":
        label.hide()
        return
    label.show()
    # The star marker is always one and always blue (the interface accent): it is
    # the sign of "the good has a breakdown by quality", and not a quality level —
    # the levels are shown as the percentages on the right, each in its own colour.
    label.text = "[color=#%s]★[/color] %s" % [
        QUALITY_MARKER_COLOR.to_html(false), share_text]

# Shows the tooltip with the breakdown by quality on hover.
func _on_quality_hover(prod_id: String, product_name: String):
    var detail = city_quality_detail.get(prod_id, {})
    if detail.is_empty():
        return
    active_quality_product = prod_id
    active_quality_name = product_name
    if ui_helpers and is_instance_valid(ui_helpers):
        ui_helpers.show_quality_tooltip(
            get_viewport().get_mouse_position(), product_name, detail)

# Hides the quality tooltip.
func _on_quality_exit():
    active_quality_product = ""
    active_quality_name = ""
    if ui_helpers and is_instance_valid(ui_helpers):
        ui_helpers.hide_quality_tooltip()

# The text of the red dynamics label. When there is a write-off per tick — the fact ("-10]")
# (the simulation tick = SIMULATION_TICK = 1 sec, therefore the fact per tick IS the
# expense per second); otherwise, if there is a planned consumption, — the average expense
# recalculated PER SECOND with the "≈" marker ("-1≈]"):
# amount × SIMULATION_TICK / interval for the interval entries and amount as is
# for the "per tick" ones (the recipes of the buildings). The reduction honestly shows the average
# expense: 10 units/100 sec = 0.1 units/sec.
func _format_cons_label(prod_id: String) -> String:
    var planned = _get_planned_for(prod_id)
    if planned.is_empty():
        return "-0]"
    var per_sec := 0.0
    for source_id in planned:
        var entry: Dictionary = planned[source_id]
        var amount = float(entry.get("amount", 0))
        var interval = float(entry.get("interval", 0))
        if interval > 0.0:
            per_sec += amount * CityData.SIMULATION_TICK / interval
        else:
            per_sec += amount
    if per_sec <= 0.0:
        return "-0]"
    var rate_text = str(int(round(per_sec))) if is_equal_approx(per_sec, round(per_sec)) else "%.1f" % per_sec
    return "-%s≈]" % rate_text

# The text of the green dynamics label. When there is a production per tick — the fact
# ("[+10") (the simulation tick = SIMULATION_TICK = 1 sec, the fact per tick IS the
# output per second); otherwise, if there is a planned production, — the average output
# recalculated PER SECOND with the "≈" sign: the recipes of the buildings are executed once per `time`
# seconds (see CityData.get_craft_time), the improvements — once per production_interval,
# therefore amount × SIMULATION_TICK / interval (an entry without an interval — "per
# tick", interval = 0 → amount).
func _format_prod_label(prod_id: String) -> String:
    var planned = planned_production_map.get(prod_id, {})
    if planned.is_empty():
        return "[+0"
    var per_sec := 0.0
    for source_id in planned:
        var entry: Dictionary = planned[source_id]
        var amount = float(entry.get("amount", 0))
        var interval = float(entry.get("interval", 0))
        if interval > 0.0:
            per_sec += amount * CityData.SIMULATION_TICK / interval
        else:
            per_sec += amount
    if per_sec <= 0.0:
        return "[+0"
    var rate_text = str(int(round(per_sec))) if is_equal_approx(per_sec, round(per_sec)) else "%.1f" % per_sec
    return "[+%s≈" % rate_text

# Shows the tooltip of the resource (the price + the sources of income/expense + the planned
# consumption) on hovering over the name or the dynamics on the "Resources" tab.
func _on_flow_hover(prod_id: String, product_name: String):
    var special_yield = GameData.get_special_yield(prod_id)
    var planned = _get_planned_for(prod_id)
    var planned_prod = planned_production_map.get(prod_id, {})
    active_flow_product = prod_id
    active_flow_name = product_name
    if ui_helpers and is_instance_valid(ui_helpers):
        ui_helpers.show_flow_tooltip(
            get_viewport().get_mouse_position(), product_name,
            special_yield, prod_id, planned, planned_prod,
            CityData.get_quality_breakdown(prod_id))

# Hides the tooltip of the sources; when moving to another label of the same row it does not flicker.
func _on_flow_exit(prod_id: String):
    var mouse_pos = get_viewport().get_mouse_position()
    var labels: Array = row_flow_labels.get(prod_id, [])
    for lbl in labels:
        if is_instance_valid(lbl) and lbl.get_global_rect().has_point(mouse_pos):
            return
    active_flow_product = ""
    active_flow_name = ""
    if ui_helpers and is_instance_valid(ui_helpers):
        ui_helpers.hide_flow_tooltip()

func _on_food_toggle_input(event, prod_id, toggle):
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        city_food_pool[prod_id] = not city_food_pool.get(prod_id, true)
        toggle.color = Color.GREEN if city_food_pool[prod_id] else Color.RED
        if get_parent().has_method("update_food_label"):
            get_parent().update_food_label()

func get_food_pool() -> Dictionary:
    return city_food_pool

func get_food_toggles() -> Dictionary:
    return food_toggles

func get_production_rates() -> Dictionary:
    return production_rates

func get_consumption_rates() -> Dictionary:
    return consumption_rates
