# Headless test of quality display: price, colour and level share
# (data/qualities.json: price_multiplier, color).
#   godot --headless --path . --script res://tests/test_quality_price.gd
#
# Quality affects the price with a multiplier: unit price = base × price_multiplier
# of the level, rounded to a whole number of coins. Checks:
#
#  1. Fields price_multiplier and color: the multiplier exists for every level and grows
#     along the quality scale (1.0 for common, and 1.0 for an unknown level too —
#     a soft default); colour is set for every level as an array [R, G, B] 0…255,
#     differs between levels, get_quality_color returns the colour from the data, and for
#     an unknown level — a light-grey default.
#  2. Level share in storage: get_quality_share_percent computes the percentage of the
#     TOTAL amount (not the share of the best level against the rest);
#     format_quality_share_text builds "(33%/67%)" — one percentage per
#     present level, from worst to best, each in its own colour
#     (BBCode). An empty breakdown — an empty string.
#  3. The price breakdown is integral and matches the multiplier on ALL goods
#     in the registry that have a price: total == round(base × multiplier) and
#     total >= base (quality does not make goods cheaper).
#  4. Level price line format — "★★ = x1.30 = 5": the multiplier with two
#     digits after x, the total integral, the line is built for ANY level of the scale,
#     including common ("★ = x1.00 = 4"). The line is glued from the level stars and
#     the tail " = x1.30 = 5" (format_quality_price_tail), because the tooltip
#     colours them differently. The reference example (goods with base price 4)
#     is compared against the exact line. For goods without a price (science), without id and for
#     a nonexistent level there is no line.
#  5. Domestic market: the unit price grows with quality, and the income for
#     a mixed storage is computed BY THE QUALITY of each written-off unit
#     (10 common + 5 fine is NOT equal to 15 × the common price), an empty
#     breakdown — income 0.
#  6. Average multiplier over storage (for planned income) — weighted by
#     the city_quality_detail breakdown; without a breakdown — 1.0.
#  7. Quality tooltip render (show_quality_tooltip): the header
#     "Resource quality levels: N", level rows "★★ Fine: 5 (30%)" with
#     the count and share, the stars in the level colour. There are no prices in it at all:
#     the full price list lives in the row tooltip.
#  8. ROW tooltip on the "Resources" tab (show_flow_tooltip): under the base
#     line "Base price: N" (gold) comes the ladder "★★ = x1.30 = 5" over ALL
#     levels that ACTUALLY sit in storage (the
#     city_quality_detail breakdown), from worst to best. The ladder line is TWO-COLOURED:
#     the stars — in their level colour (data/qualities.json), the price calculation —
#     the price colour of the palette (ui_helpers.price_text_color()); both parts match
#     format_quality_price_scale_rows and are not collapsed by width. For levels
#     that are not in storage (incl. with an empty breakdown), there are no lines — as
#     for goods without a price.
extends SceneTree

# Hang watchdog: without it a broken _run() coroutine looks like eternal
# silence from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

var _failed := false

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    # Autoloads are taken through the scene tree: in --script mode the names
    # GameData/CityData are unavailable at the compilation stage of this file.
    # new_game() brings up GameData.load_all_data() and CityData.setup().
    var save_manager = get_root().get_node("SaveManager")
    save_manager.new_game()
    var gd = get_root().get_node("GameData")
    var city = get_root().get_node("CityData")

    var levels: Array = gd.get_quality_levels()
    check(levels.size() == 4, "expected 4 quality levels, got %d" % levels.size())

    # --- 1. Field price_multiplier: exists for all, grows along the scale ---
    var prev_mult := 0.0
    for qid in levels:
        var qd: Dictionary = gd.get_quality_data(qid)
        check(qd.has("price_multiplier"),
            "level \"%s\" has no price_multiplier field" % qid)
        var m := float(qd.get("price_multiplier", 0.0))
        check(m > prev_mult,
            "the multiplier of level \"%s\" (%.2f) must be greater than the previous one (%.2f)"
            % [qid, m, prev_mult])
        prev_mult = m
    check(is_equal_approx(gd.get_quality_price_multiplier("common"), 1.0),
        "the common quality multiplier must be 1.0")
    check(is_equal_approx(gd.get_quality_price_multiplier("no_such_quality"), 1.0),
        "for an unknown level the multiplier must be 1.0 (soft default)")

    # Field color: set for all levels as an array [R, G, B] in the range
    # 0…255 (the same shape as for tiles/improvements/resources), the level colours
    # are pairwise different — otherwise breakdown lines and tooltips could not be told
    # apart, — and get_quality_color returns exactly the colour from the data.
    var seen_colors := {}
    for qid in levels:
        var qd_color = gd.get_quality_data(qid).get("color", null)
        check(qd_color is Array and qd_color.size() == 3,
            "level \"%s\" has no color field as an array [R, G, B]: %s" % [qid, str(qd_color)])
        if not (qd_color is Array and qd_color.size() == 3):
            continue
        for comp in qd_color:
            check(float(comp) >= 0.0 and float(comp) <= 255.0,
                "the colour component of level \"%s\" is out of the 0…255 range: %s" % [qid, str(comp)])
        var hex: String = gd.get_quality_color(qid).to_html(false)
        check(hex == "%02x%02x%02x" % [int(qd_color[0]), int(qd_color[1]), int(qd_color[2])],
            "get_quality_color must return the colour from the data of level \"%s\": %s instead of %02x%02x%02x"
            % [qid, hex, int(qd_color[0]), int(qd_color[1]), int(qd_color[2])])
        check(not seen_colors.has(hex),
            "the colour of level \"%s\" matched the colour of level \"%s\" (%s) — levels must differ in colour"
            % [qid, str(seen_colors.get(hex, "")), hex])
        seen_colors[hex] = qid
    # Soft default for a level without a color field: an unknown id and an empty string
    # are drawn light-grey (duplicated in GameData.QUALITY_COLOR_FALLBACK).
    check(gd.get_quality_color("no_such_quality") == Color(0.8, 0.8, 0.8),
        "for an unknown level the colour must be the light-grey default")
    check(gd.get_quality_color("") == Color(0.8, 0.8, 0.8),
        "for an empty level id the colour must be the light-grey default")

    # --- 2. Level share in storage: percentages and the breakdown string ---
    # Percentages are computed from the TOTAL amount of goods: a 30/10/60 breakdown gives
    # 30/10/60 percent, not "shares of the best level" (that would give
    # 100/33/200 — which is exactly what the list row showed before the rework).
    var share_breakdown := {"common": 30, "fine": 10, "perfect": 60}
    check(gd.get_quality_share_percent(30, share_breakdown) == 30,
        "the common level share (30 out of 100) must be 30 percent")
    check(gd.get_quality_share_percent(10, share_breakdown) == 10,
        "the fine level share (10 out of 100) must be 10 percent")
    check(gd.get_quality_share_percent(60, share_breakdown) == 60,
        "the perfect level share (60 out of 100) must be 60 percent")
    check(gd.get_quality_share_percent(5, {}) == 0,
        "on an empty breakdown the share must be 0")
    check(gd.get_quality_share_percent(0, {"common": 0}) == 0,
        "on a zero breakdown the share must be 0")
    # The sum of shares is about 100%: the percentages are rounded separately, and
    # "trimming" them to an even 100% would be a lie about fractional shares.
    var share_sum := 0
    for qid in share_breakdown:
        share_sum += gd.get_quality_share_percent(int(share_breakdown[qid]), share_breakdown)
    check(abs(share_sum - 100) <= 1,
        "the sum of shares over the breakdown must be about 100%%, got %d" % share_sum)

    # Breakdown string for the list row: one percentage per present
    # level, from worst to best, each wrapped in the BBCode colour of its
    # level: "(30%/10%/60%)" with "[color=#a0a0a0]30%[/color]" and so on.
    # We compare the whole string — this checks at once both the level order and their
    # percentages and colours. A regular expression is deliberately not used here:
    # a pattern with '#' inside (this is a BBCode colour tag) behaves
    # non-obviously in this Godot build, and an exact comparison checks strictly.
    var share_order := ["common", "fine", "perfect"]
    var share_parts: Array = []
    for qid in share_order:
        share_parts.append("[color=#%s]%d%%[/color]" % [
            gd.get_quality_color(qid).to_html(false),
            gd.get_quality_share_percent(int(share_breakdown[qid]), share_breakdown)])
    var share_text: String = gd.format_quality_share_text(share_breakdown)
    check(share_text == "(%s)" % "/".join(share_parts),
        "the breakdown string must be \"(%s)\", got \"%s\""
        % ["/".join(share_parts), share_text])
    # A level that is not in storage (exceptional) must not be in the string.
    check(not share_text.contains(gd.get_quality_color("exceptional").to_html(false)),
        "a level that is not in storage (exceptional) must not be in the breakdown string: \"%s\""
        % share_text)
    # Only common quality in storage — "(100%)"; an empty and a zero breakdown —
    # an empty string (the list label hides on it).
    var single_share: String = gd.format_quality_share_text({"common": 40})
    check(single_share.contains("100%"),
        "a breakdown of common quality only must give \"(100%%)\": \"%s\"" % single_share)
    check(gd.format_quality_share_text({}).is_empty(),
        "on an empty breakdown the breakdown string must be empty")
    check(gd.format_quality_share_text({"fine": 0}).is_empty(),
        "on a breakdown of zeros the breakdown string must be empty")

    # --- 3. The price breakdown is integral and matches on all goods ---
    var checked_prices := 0
    for pid in gd.products:
        if gd.get_base_price(pid) <= 0.0:
            continue
        checked_prices += 1
        for qid in levels:
            var d: Dictionary = gd.get_price_breakdown_for_quality(pid, qid)
            var base := int(d["base"])
            var total := int(d["total"])
            var mult := float(d["multiplier"])
            check(total == int(round(float(base) * mult)),
                "the total price %s/%s is not equal to round(base × multiplier)" % [pid, qid])
            # The unrounded helper and the tooltip breakdown must match
            # after rounding — otherwise the tooltip would show one price and the
            # domestic market would pay at another.
            check(int(round(gd.get_price_for_quality(pid, qid))) == total,
                "get_price_for_quality diverges from the price breakdown (%s/%s)" % [pid, qid])
            check(total >= base,
                "quality must not make goods cheaper (%s/%s: %d < %d)" % [pid, qid, total, base])
            if qid == "common":
                check(total == base,
                    "for common quality the total must match the base (%s)" % pid)
    check(checked_prices > 100,
        "too few goods with a price checked: %d" % checked_prices)


    # --- 4. Level price line format ---
    # Format: "★ = x1.00 = 4" / "★★ = x1.30 = 5" — the level stars, the multiplier with
    # two digits after x and an integral total. Built for ANY level of the scale,
    # including the lowest: it used to be dropped, and a storage holding
    # only common quality had no ladder at all.
    var line_re := RegEx.new()
    var err := line_re.compile("^★+ = x[0-9]+\\.[0-9]{2} = [0-9]+$")
    check(err == OK, "the line format check did not compile: %d" % err)
    # Reference goods with base price 4 (there are many such in the data).
    var sample_id := ""
    for pid in gd.products:
        if is_equal_approx(gd.get_base_price(pid), 4.0):
            sample_id = pid
            break
    check(sample_id != "", "there is no goods with base price 4 in the registry")
    for qid in levels:
        var line: String = gd.format_quality_price_line(sample_id, qid)
        var d: Dictionary = gd.get_price_breakdown_for_quality(sample_id, qid)
        check(line_re.search(line) != null,
            "the price line does not match the format \"★★ = x1.30 = 5\": \"%s\"" % line)
        check(line.begins_with(gd.get_quality_stars(qid) + " = "),
            "the line must begin with the level stars: \"%s\"" % line)
        check(line.contains("= x%s =" % "%.2f" % float(d["multiplier"])),
            "the line must contain the level multiplier: \"%s\"" % line)
        check(line.ends_with("= %d" % int(d["total"])),
            "the line must contain the total round(base × multiplier): \"%s\"" % line)
        # The lowest level of the scale is no exception: the 1.0 multiplier is shown too.
        check(line != "", "for level \"%s\" the price line must not be empty" % qid)
    # The line tail is everything EXCEPT the stars (" = x1.30 = 5"): it is what the row tooltip
    # colours gold, and the stars — in the level colour. The tail format is checked
    # separately, and the whole line must be assembled from the stars and the tail without
    # a single discrepancy — otherwise the coloured parts would drift from the text.
    var tail_re := RegEx.new()
    var tail_err := tail_re.compile("^ = x[0-9]+\\.[0-9]{2} = [0-9]+$")
    check(tail_err == OK, "the tail format check did not compile: %d" % tail_err)
    for qid in levels:
        var tail: String = gd.format_quality_price_tail(sample_id, qid)
        var q_line: String = gd.format_quality_price_line(sample_id, qid)
        check(tail_re.search(tail) != null,
            "the price line tail does not match the format \" = x1.30 = 5\": \"%s\"" % tail)
        check(q_line == gd.get_quality_stars(qid) + tail,
            "the line must be assembled from the stars and the tail: \"%s\" instead of \"%s%s\""
            % [q_line, gd.get_quality_stars(qid), tail])
    check(gd.format_quality_price_tail(sample_id, "fine") == " = x1.30 = 5",
        "reference example of the fine level tail: \"%s\""
        % gd.format_quality_price_tail(sample_id, "fine"))
    check(gd.format_quality_price_tail(sample_id, "exceptional") == " = x1.75 = 7",
        "reference example of the exceptional level tail (4 × 1.75 = 7): \"%s\""
        % gd.format_quality_price_tail(sample_id, "exceptional"))
    check(gd.format_quality_price_tail("science", "perfect") == "",
        "for goods without a price the tail is not shown")
    check(gd.format_quality_price_tail(sample_id, "no_such_quality") == "",
        "for a nonexistent level the tail is not shown")
    # Exact reference examples: price 4, common/fine/perfect.
    check(gd.format_quality_price_line(sample_id, "common") == "★ = x1.00 = 4",
        "reference example of the common level: expected \"★ = x1.00 = 4\", got \"%s\""
        % gd.format_quality_price_line(sample_id, "common"))
    check(gd.format_quality_price_line(sample_id, "fine") == "★★ = x1.30 = 5",
        "reference example of the fine level: expected \"★★ = x1.30 = 5\", got \"%s\""
        % gd.format_quality_price_line(sample_id, "fine"))
    check(gd.format_quality_price_line(sample_id, "perfect") == "★★★★ = x2.30 = 9",
        "reference example of the perfect level: expected \"★★★★ = x2.30 = 9\", got \"%s\""
        % gd.format_quality_price_line(sample_id, "perfect"))
    # Goods without a price (the science pseudo-resource) gives no line.
    check(gd.format_quality_price_line("science", "perfect") == "",
        "for goods without a price the price line is not shown")
    check(gd.format_quality_price_line("", "fine") == "",
        "without a goods id the price line is not shown")
    # The level is not in the scale — nothing to show: the line cannot be built without stars.
    check(gd.format_quality_price_line(sample_id, "no_such_quality") == "",
        "for a nonexistent level the price line is not shown")
    check(gd.format_quality_price_line(sample_id, "") == "",
        "for an empty level the price line is not shown")

    # --- 5. Domestic market: price and income by quality ---
    var base_market: int = city.get_internal_market_price(sample_id)
    check(base_market > 0, "the reference goods must have a market price")
    check(city.get_internal_market_price(sample_id, "common") == base_market,
        "common quality must not change the domestic market price")
    var fine_market: int = city.get_internal_market_price(sample_id, "fine")
    var perfect_market: int = city.get_internal_market_price(sample_id, "perfect")
    check(fine_market == int(round(float(base_market) * gd.get_quality_price_multiplier("fine"))),
        "the fine quality price is not equal to round(base market × multiplier)")
    check(perfect_market > fine_market and fine_market > base_market,
        "the domestic market price must grow with quality (%d / %d / %d)"
        % [base_market, fine_market, perfect_market])
    var mixed_income: int = city.get_internal_market_income(
        sample_id, {"common": 10, "fine": 5})
    check(mixed_income == 10 * base_market + 5 * fine_market,
        "the income for a mixed storage must be computed by the quality of each unit: %d" % mixed_income)
    check(mixed_income > 15 * base_market,
        "a mixed storage must yield more than 15 units of common quality")
    check(city.get_internal_market_income(sample_id, {}) == 0,
        "an empty breakdown of written-off — income 0")

    # --- 6. Average multiplier over storage (for planned income) ---
    city.city_quality_detail[sample_id] = {"common": 10, "fine": 5}
    var expected_avg := (10.0 + 5.0 * float(gd.get_quality_price_multiplier("fine"))) / 15.0
    check(is_equal_approx(city.get_stock_quality_price_multiplier(sample_id), expected_avg),
        "the average multiplier over storage must be weighted by the breakdown")
    city.city_quality_detail[sample_id] = {}
    check(is_equal_approx(city.get_stock_quality_price_multiplier(sample_id), 1.0),
        "without a quality breakdown the average multiplier must be 1.0")

    # --- 7. Quality tooltip render ---
    await _check_quality_tooltip_render(gd)

    # --- 8. Render of the row tooltip on the "Resources" tab ---
    await _check_flow_tooltip_price_render(gd, sample_id)

    if _failed:
        print("FAIL")
        quit(1)
    else:
        print("QUALITY PRICE TEST OK")
        quit(0)

# Checks the quality breakdown tooltip (show_quality_tooltip): the header
# "Resource quality levels: N", the level rows "★★ Fine: 5 (29%)" with
# the count and share, the stars in the level colour — and not a single price line:
# the full price list lives in the row tooltip (see _check_flow_tooltip_price_render).
func _check_quality_tooltip_render(gd) -> void:
    var holder := Control.new()
    get_root().add_child(holder)
    var ui = load("res://scripts/ui_helpers.gd").new()
    ui.setup(holder, Label.new())
    holder.add_child(ui)
    await process_frame
    await process_frame

    var breakdown := {"common": 10, "fine": 5, "perfect": 2}
    ui.show_quality_tooltip(Vector2(50, 50), "Goods", breakdown)
    await process_frame

    var header_text := ""
    var level_texts: Array = []
    var star_colors: Array = []
    var header_labels := 0
    for child in ui.quality_tooltip_vbox.get_children():
        # A quality level row is an HBoxContainer: the first child is the stars,
        # the second "Name: N (P%)". Apart from the header there must be no Label
        # rows in the tooltip: each level used to draw "  Price: …" under it.
        if child is HBoxContainer:
            var stars_label := child.get_child(0) as Label
            var name_label := child.get_child(1) as Label
            level_texts.append(str(name_label.text))
            star_colors.append(stars_label.get_theme_color("font_color"))
        elif child is Label:
            header_text = str((child as Label).text)
            header_labels += 1
    check(header_text == "Resource quality levels: Goods",
        "the quality tooltip header must be \"Resource quality levels: Goods\", got \"%s\""
        % header_text)
    check(header_labels == 1,
        "the quality tooltip must have only the header (Label rows: %d) — there are no prices in it"
        % header_labels)
    check(level_texts.size() == 3,
        "the tooltip must show 3 quality rows, shown %d" % level_texts.size())

    # The level rows go from worst to best: the count and share of the total
    # amount of goods (10 + 5 + 2 = 17 → 59% / 29% / 12%).
    var expected_order := ["common", "fine", "perfect"]
    for i in range(mini(level_texts.size(), expected_order.size())):
        var qid: String = expected_order[i]
        var count := int(breakdown[qid])
        var expected_text := "%s: %d (%d%%)" % [
            gd.get_quality_name(qid), count,
            gd.get_quality_share_percent(count, breakdown)]
        check(str(level_texts[i]) == expected_text,
            "level row #%d must be \"%s\", got \"%s\""
            % [i, expected_text, str(level_texts[i])])
        # The row stars are coloured in the level colour (data/qualities.json, color).
        check(star_colors[i] == gd.get_quality_color(qid),
            "the stars of level \"%s\" must be in its colour: %s instead of %s"
            % [qid, str(star_colors[i]), str(gd.get_quality_color(qid))])
    # The sum of the shown shares is about 100%: the shares are taken from the total amount,
    # not from the best level (that would give 100% / 29% / 12% + "more perfect
    # than all the rest").
    var pct_sum := 0
    for qid in breakdown:
        pct_sum += gd.get_quality_share_percent(int(breakdown[qid]), breakdown)
    check(abs(pct_sum - 100) <= 1,
        "the sum of shares in the tooltip must be about 100%%, got %d" % pct_sum)

    # An empty breakdown — only the header remains: there are no level rows.
    ui.show_quality_tooltip(Vector2(50, 50), "Goods", {})
    await process_frame
    var rows_empty := 0
    for child in ui.quality_tooltip_vbox.get_children():
        if child is HBoxContainer:
            rows_empty += 1
    check(rows_empty == 0,
        "with an empty breakdown there must be no level rows, shown %d" % rows_empty)

    holder.queue_free()

# Checks the quality price ladder in the ROW tooltip of the "Resources" tab
# (ui_helpers.show_flow_tooltip): under the base "Base price: N" comes a line for every
# level that ACTUALLY sits in storage (the city_quality_detail breakdown), in
# the format "★★ = x1.30 = 5" and in its own level colour. For levels that are not
# in storage there must be no lines — there is no point showing the price of goods
# that are not in storage.
func _check_flow_tooltip_price_render(gd, sample_id: String) -> void:
    # The ladder line format is the same as format_quality_price_line.
    var line_re := RegEx.new()
    var err := line_re.compile("^★+ = x[0-9]+\\.[0-9]{2} = [0-9]+$")
    check(err == OK, "the line format check did not compile: %d" % err)

    # An empty breakdown (an old save or goods without quality) — not a single line.
    check(gd.format_quality_price_scale_rows(sample_id, {}).is_empty(),
        "with an empty breakdown there must be no quality price lines")
    check(gd.format_quality_price_scale_rows(sample_id).is_empty(),
        "without a breakdown (the default argument) there must be no lines")

    # Only common quality in storage: the line IS there ("★ = x1.00 = 4"). It used
    # to be that the lowest level of the scale was dropped, and such a storage had no block.
    var common_only: Array = gd.format_quality_price_scale_rows(sample_id, {"common": 40})
    check(common_only.size() == 1
            and str((common_only[0] as Dictionary)["qid"]) == "common",
        "with common quality only there must be exactly one common level row: %s"
        % str(common_only))

    # All three levels in storage: EXACTLY they are shown, the exceptional one (which
    # is not in storage) — not. The order is from worst to best.
    var breakdown := {"common": 40, "fine": 12, "perfect": 3}
    var rows: Array = gd.format_quality_price_scale_rows(sample_id, breakdown)
    check(rows.size() == 3,
        "there must be 3 rows (common, fine, perfect), shown %d: %s"
        % [rows.size(), str(rows)])
    var expected_order := ["common", "fine", "perfect"]
    for i in range(mini(rows.size(), expected_order.size())):
        var qid: String = expected_order[i]
        var row: Dictionary = rows[i]
        check(str(row["qid"]) == qid,
            "row #%d must be of level \"%s\", shown \"%s\"" % [i, qid, str(row["qid"])])
        # The line matches what format_quality_price_line gives: the block is
        # assembled by the same function, so we compare character by character.
        check(str(row["text"]) == gd.format_quality_price_line(sample_id, qid),
            "row #%d did not match the computed one: \"%s\" instead of \"%s\""
            % [i, str(row["text"]), gd.format_quality_price_line(sample_id, qid)])
        check(line_re.search(str(row["text"])) != null,
            "row #%d does not match the ladder format \"★★ = x1.30 = 5\": \"%s\"" % [i, str(row["text"])])
        # The line parts are returned SEPARATELY: the tooltip colours the stars in the level colour and
        # the calculation tail — gold, and both parts must match the
        # ready line exactly (otherwise the highlighted part would not match the text).
        check(str(row["stars"]) == gd.get_quality_stars(qid),
            "the stars of row #%d must be the stars of level \"%s\": \"%s\" instead of \"%s\""
            % [i, qid, str(row["stars"]), gd.get_quality_stars(qid)])
        check(str(row["tail"]) == gd.format_quality_price_tail(sample_id, qid),
            "the tail of row #%d did not match the computed one: \"%s\" instead of \"%s\""
            % [i, str(row["tail"]), gd.format_quality_price_tail(sample_id, qid)])
        check(str(row["text"]) == str(row["stars"]) + str(row["tail"]),
            "row #%d must be glued from the stars and the tail: \"%s\"" % [i, str(row["text"])])
    # The exceptional one (★★★) is not in storage. Checking by the stars substring is
    # not allowed: "★★★" is contained in "★★★★", so we compare the level id in the row.
    var has_exceptional := false
    for row in rows:
        if str((row as Dictionary)["qid"]) == "exceptional":
            has_exceptional = true
    check(not has_exceptional,
        "there must be no row of a level that is not in storage (exceptional): %s" % str(rows))
    # The level multipliers differ — otherwise comparing lines would be meaningless.
    var perfect_d: Dictionary = gd.get_price_breakdown_for_quality(sample_id, "perfect")
    check(perfect_d["multiplier"] != gd.get_quality_price_multiplier("fine"),
        "the level multipliers must differ — otherwise the line check is meaningless")

    # The count is zero — the level is considered absent (this is possible with
    # a desync between the breakdown and the supply in an old save).
    check(gd.format_quality_price_scale_rows(sample_id, {"fine": 0}).is_empty(),
        "with count == 0 the line must not be shown")

    # Render: the ladder rows are inserted into the row tooltip with a 2-space
    # indent; the stars in them — in their level colour, and the price calculation — gold.
    # Goods without a breakdown and without a price give not a single row.
    var holder := Control.new()
    get_root().add_child(holder)
    var ui = load("res://scripts/ui_helpers.gd").new()
    ui.setup(holder, Label.new())
    holder.add_child(ui)
    await process_frame
    await process_frame

    ui.show_flow_tooltip(Vector2(50, 50), "Goods", {}, sample_id, {}, {}, breakdown)
    await process_frame

    var base_line := ""
    var scale_stars: Array = []
    var scale_tails: Array = []
    for child in ui.flow_tooltip_vbox.get_children():
        if child is Label:
            var label := child as Label
            if label.text.begins_with("Base price: "):
                base_line = label.text
        elif child is HBoxContainer and child.get_child_count() == 2:
            # A ladder row is an HBox of two Labels: the stars in the level colour and
            # the gold tail of the price calculation.
            var stars_label := child.get_child(0) as Label
            var tail_label := child.get_child(1) as Label
            if stars_label == null or tail_label == null:
                continue
            if not str(stars_label.text).begins_with("  ★"):
                continue
            scale_stars.append({
                "text": str(stars_label.text),
                "color": stars_label.get_theme_color("font_color"),
                "width": stars_label.size.x,
            })
            scale_tails.append({
                "text": str(tail_label.text),
                "color": tail_label.get_theme_color("font_color"),
                "width": tail_label.size.x,
            })
    check(base_line == "Base price: %d" % int(round(gd.get_price(sample_id))),
        "the row tooltip must contain the base price, got \"%s\"" % base_line)
    check(scale_stars.size() == 3,
        "the row tooltip must have 3 rows (only levels from storage), shown %d: %s"
        % [scale_stars.size(), str(scale_stars)])
    # The row order and their text are as in format_quality_price_scale_rows. The stars
    # are coloured in THEIR OWN level colour (data/qualities.json), and the price calculation itself —
    # gold (ui_helpers.PRICE_TEXT_COLOR).
    for i in range(mini(scale_stars.size(), rows.size())):
        var qid: String = expected_order[i]
        var row: Dictionary = rows[i]
        var stars_cell: Dictionary = scale_stars[i]
        var tail_cell: Dictionary = scale_tails[i]
        check(str(stars_cell["text"]) == "  " + str(row["stars"]),
            "the stars of row #%d did not match the computed ones: \"%s\" instead of \"%s\""
            % [i, str(stars_cell["text"]), "  " + str(row["stars"])])
        check(str(tail_cell["text"]) == str(row["tail"]),
            "the price calculation of row #%d did not match the computed one: \"%s\" instead of \"%s\""
            % [i, str(tail_cell["text"]), str(row["tail"])])
        check(stars_cell["color"] == gd.get_quality_color(qid),
            "the stars of row #%d (\"%s\") must be in the colour of level \"%s\": %s instead of %s"
            % [i, str(stars_cell["text"]), qid, str(stars_cell["color"]),
                str(gd.get_quality_color(qid))])
        check(tail_cell["color"] == ui.price_text_color(),
            "the price calculation of row #%d (\"%s\") must be gold: %s instead of %s"
            % [i, str(tail_cell["text"]), str(tail_cell["color"]), str(ui.price_text_color())])
        # No part of the line has collapsed in width.
        check(float(stars_cell["width"]) > 5.0 and float(tail_cell["width"]) > 20.0,
            "row #%d collapsed in width (stars %s px, calculation %s px)"
            % [i, str(stars_cell["width"]), str(tail_cell["width"])])
    # The star colour and the gold calculation differ at least where it is visible to the eye:
    # otherwise "stars in the level colour" would mean nothing.
    var fine_stars: Dictionary = scale_stars[1] if scale_stars.size() > 1 else {}
    check(fine_stars.get("color", Color.BLACK) != ui.price_text_color(),
        "the level stars must not match in colour the gold price calculation")
    # The tooltip panel has not collapsed: its width is computed from the minimum size
    # of the content, so a narrow panel = narrow rows inside.
    check(ui.flow_tooltip_panel.size.x > 100.0,
        "the row tooltip panel collapsed in width: %s" % str(ui.flow_tooltip_panel.size))

    # An empty breakdown: there is no quality price block at all.
    ui.show_flow_tooltip(Vector2(50, 50), "Goods", {}, sample_id, {}, {}, {})
    await process_frame
    check(_count_scale_lines(ui) == 0,
        "with an empty breakdown there must be no quality rows in the tooltip")
    # A plain good has a single surcharge: its ladder row is the price, there is nothing to
    # decompose.
    check(_count_build_up_rows(ui) == 0,
        "a plain good must have no build-up rows in the tooltip")

    # A decorated good ("Wool Clothes (+Woad)") explains the price in STAGES: the base part at the
    # level of the base, the additions at the level of the additions, the synergy, and the total.
    # One block per quality KEY that lies in the storage, each row named, so that no row has to
    # mean two things at once.
    var decorated := _pick_decorated_good(gd)
    if decorated.is_empty():
        check(false, "the data has no recipe with additional ingredients to check the rows against")
    else:
        # The record of a generated good is created when its recipe is built (or when the good
        # first reaches the storage) — a good that does not exist has no price and no row.
        gd.get_craft(decorated)
        var levels: Array = gd.get_quality_levels()
        var low_level := str(levels[0])
        var stage_level := "fine" if levels.has("fine") else low_level
        # The key carries BOTH levels: a fine base with a common dye. The price is the sum of the
        # two parts, each at its own level — the whole point of the pair.
        var stage_key: String = gd.make_quality_key(stage_level, low_level)
        var stages: Dictionary = gd.get_price_stages(decorated, stage_key)
        check(not stages.is_empty(), "a decorated good must have price stages")
        if not stages.is_empty():
            # The price is a SUM of parts: the coefficients of the base part and of the additions
            # add up to the coefficient of their sum. They do not multiply — there is no chain of
            # surcharges, the material of the additions is paid for in full and nothing else.
            var parts_mult: float = float(stages["quality"]["mult"]) + float(stages["additions"]["mult"])
            var parts_price: float = float(stages["quality"]["price"]) + float(stages["additions"]["price"])
            check(is_equal_approx(parts_mult, parts_price / float(stages["base"])),
                "the coefficients of the parts must add up to the sum before the synergy: %s + %s ≠ %s"
                % [str(stages["quality"]["mult"]), str(stages["additions"]["mult"]),
                    str(parts_price / float(stages["base"]))])
            check(is_equal_approx(float(stages["quality"]["mult"]),
                    gd.get_quality_price_multiplier(stage_level)),
                "the quality stage must carry the declared multiplier (%s), got %s"
                % [str(gd.get_quality_price_multiplier(stage_level)),
                    str(stages["quality"]["mult"])])
            check(is_equal_approx(float(stages["additions"]["mult"]),
                    float(gd.get_decorated_extras_value(str(gd.parse_generated_id(decorated)["base"]),
                            gd.parse_generated_id(decorated)["extras"], low_level))
                        / float(stages["base"])),
                "the additions stage must carry the value of the additions at their own level")
            check(is_equal_approx(float(stages["synergy"]["mult"]),
                    gd.get_craft_extra_synergy_multiplier()),
                "the synergy stage must carry the declared coefficient (%s), got %s"
                % [str(gd.get_craft_extra_synergy_multiplier()), str(stages["synergy"]["mult"])])
            check(is_equal_approx(float(stages["total"]["mult"]),
                    parts_mult * gd.get_craft_extra_synergy_multiplier()),
                "the total must be the sum of the parts times the synergy")

        # The two levels are independent, and both are dearer than the plain good:
        #   fine base + common dye  <  fine base + fine dye
        #   plain fine              <  fine base + common dye
        #   (the plain good plus the dye, sold apart) < (the decorated good)
        var parsed: Dictionary = gd.parse_generated_id(decorated)
        var base_pid := str(parsed["base"])
        var fine_common := int(round(gd.get_price_for_quality(decorated, stage_key)))
        var fine_fine := int(round(gd.get_price_for_quality(decorated,
                gd.make_quality_key(stage_level, stage_level))))
        var plain_fine := int(round(gd.get_price_for_quality(base_pid, stage_level)))
        check(fine_fine > fine_common and fine_common > plain_fine,
            "the price must rise with the level of the additions and stay above the plain good "
            + "(plain %d, +common %d, +fine %d)" % [plain_fine, fine_common, fine_fine])
        var base_part: float = gd.get_price(base_pid) * gd.get_quality_price_multiplier(stage_level)
        var extra_part: float = gd.get_decorated_extras_value(base_pid, parsed["extras"], low_level)
        check(fine_common == int(round((base_part + extra_part)
                        * gd.get_craft_extra_synergy_multiplier())),
            "the price is the sum of the parts times the synergy (expected %d, got %d)"
            % [int(round((base_part + extra_part) * gd.get_craft_extra_synergy_multiplier())),
                fine_common])
        check(float(fine_common) > base_part + extra_part,
            "the synergy must make the decorated good dearer than its parts sold apart (%d vs %.1f)"
            % [fine_common, base_part + extra_part])

        # Two keys in the storage: the synergy row once, then three rows per key, in the order of
        # the levels.
        var decorated_breakdown := {stage_key: 3, low_level: 5}
        var expected: Array = gd.format_price_build_up_rows(decorated, decorated_breakdown)
        check(expected.size() == 7,
            "the build-up is the synergy row plus three rows (quality, additions, total) per "
            + "quality key in the storage, got %d" % expected.size())
        if not expected.is_empty():
            check(str(expected[0]["kind"]) == "synergy",
                "the first row of the build-up is the synergy coefficient")
            check(str(expected[0]["tail"]) == "x%.2f" % gd.get_craft_extra_synergy_multiplier(),
                "the synergy row carries the coefficient and no price, got \"%s\""
                % str(expected[0]["tail"]))
        ui.show_flow_tooltip(Vector2(50, 50), "Goods", {}, decorated, {}, {}, decorated_breakdown)
        await process_frame
        var cells := _build_up_cells(ui)
        check(cells.size() == expected.size(),
            "the tooltip must carry %d build-up rows, shown %d" % [expected.size(), cells.size()])
        for i in range(mini(cells.size(), expected.size())):
            var row: Dictionary = expected[i]
            check(str(cells[i]["marker"]) == "  " + str(row["marker"]),
                "the marker of row #%d must be \"%s\", got \"%s\""
                % [i, "  " + str(row["marker"]), str(cells[i]["marker"])])
            check(str(cells[i]["label"]) == _stage_label(str(row["kind"])),
                "the name of the stage of row #%d must be \"%s\", got \"%s\""
                % [i, _stage_label(str(row["kind"])), str(cells[i]["label"])])
            check(str(cells[i]["tail"]) == str(row["tail"]),
                "the calculation of row #%d must be \"%s\", got \"%s\""
                % [i, str(row["tail"]), str(cells[i]["tail"])])
            check(float(cells[i]["width"]) > 20.0,
                "row #%d collapsed in width (%s px)" % [i, str(cells[i]["width"])])
        # The chain starts at the price of the PLAIN base: the additions are a stage of their own.
        var plain_price := int(round(gd.get_price(base_pid)))
        var decorated_base_line := ""
        for child in ui.flow_tooltip_vbox.get_children():
            if child is Label and str(child.text).begins_with("Base price: "):
                decorated_base_line = str(child.text)
        check(decorated_base_line == "Base price: %d" % plain_price,
            "the base line of a decorated good must be the plain base (%d), got \"%s\""
            % [plain_price, decorated_base_line])
        # The last row is the total of the last key, and it carries the price the game really uses
        # for those units.
        if not expected.is_empty():
            var last: Dictionary = expected[expected.size() - 1]
            check(str(last["kind"]) == "total", "the last row of the build-up is the total")
            check(str(last["qid"]) == gd.quality_key_level(stage_key),
                "the total row carries the level of the good itself (%s), got \"%s\""
                % [gd.quality_key_level(stage_key), str(last["qid"])])
            var key_price := int(round(gd.get_price_for_quality(decorated, stage_key)))
            check(str(last["tail"]).ends_with(" = %d" % key_price),
                "the total row must end with the price of the key (%d): \"%s\""
                % [key_price, str(last["tail"])])

    # Goods without a price (science): there are no rows even with a non-empty breakdown.
    ui.show_flow_tooltip(Vector2(50, 50), "Science", {}, "science", {}, {},
        {"common": 10, "perfect": 2})
    await process_frame
    check(_count_scale_lines(ui) == 0,
        "for goods without a price there must be no quality rows")
    check(_count_build_up_rows(ui) == 0,
        "for goods without a price there must be no build-up rows")

    holder.queue_free()

# Counts the quality price ladder rows in the row tooltip. The 2-space indent
# distinguishes them from the base "Base price: N", which has no indent.
func _count_scale_lines(ui) -> int:
    var result := 0
    for child in ui.flow_tooltip_vbox.get_children():
        # A ladder row is an HBox of two Labels, the first of them "  ★…" (the second —
        # the gold calculation tail). The 2-space indent distinguishes the ladder from
        # the base "Base price: N", which has no indent.
        if not (child is HBoxContainer) or child.get_child_count() != 2:
            continue
        var stars_label := child.get_child(0) as Label
        if stars_label != null and str(stars_label.text).begins_with("  ★"):
            result += 1
    return result

# The rows of the price build-up in the row tooltip: an HBox of THREE Labels — the marker (the
# stars of the level, or the plus of the additions), the name of the stage and the gold
# calculation. Three children is what tells them apart from a plain ladder row, which has two.
func _build_up_cells(ui) -> Array:
    var cells: Array = []
    for child in ui.flow_tooltip_vbox.get_children():
        if not (child is HBoxContainer) or child.get_child_count() != 3:
            continue
        var marker := child.get_child(0) as Label
        var stage := child.get_child(1) as Label
        var tail := child.get_child(2) as Label
        if marker == null or stage == null or tail == null:
            continue
        cells.append({
            "marker": str(marker.text),
            "label": str(stage.text),
            "tail": str(tail.text),
            "width": tail.size.x,
        })
    return cells

func _count_build_up_rows(ui) -> int:
    return _build_up_cells(ui).size()

# The name of a stage of the price build-up (the test pins the locale to "en").
func _stage_label(kind: String) -> String:
    match kind:
        "quality":
            return "Quality: "
        "additions":
            return "Additions: "
        "synergy":
            return "Synergy: "
        "total":
            return "Total: "
    return ""

# The first good of the data that is generated from a base recipe and an additional ingredient —
# taken from the data, so that a re-balanced registry does not break the test.
func _pick_decorated_good(gd) -> String:
    for recipe in gd.crafts:
        var kinds: Array = recipe.get("extra_kinds", [])
        var result: Dictionary = recipe.get("result", {})
        if kinds.is_empty() or result.is_empty():
            continue
        var base_pid := str(result.keys()[0])
        for extra_id in gd.craft_extras:
            if str(gd.craft_extras[extra_id].get("kind", "")) in kinds:
                return gd.make_generated_id(base_pid, [str(extra_id)])
    return ""

func check(cond: bool, msg: String):
    if cond:
        return
    _failed = true
    print("FAIL: %s" % msg)
