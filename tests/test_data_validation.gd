# Runtime game-data validator test (headless):
#   godot --headless --path . --script res://tests/test_data_validation.gd
#
# Checks five things:
#   1) DETECTOR (main). On synthetic data, exactly one breakage is introduced
#      into each kind of check, and the test requires finding each one — with
#      the right kind of check, identifier and reference owner.
#      The data is synthetic on purpose: the test must not break when the
#      author fixes the real data/*.json.
#   2) FALSE POSITIVES. Five places where the validator must stay silent:
#      produced_in == "*" (the service marker "in any building", see
#      CityData.can_craft_in), category on a RAW RESOURCE (there it is a map
#      generation filter with its own set of values — animals/plants/metals/minerals,
#      not the categories from data/categories.json), "product without a source"
#      on a goods item that is produced by a display_result, by a map
#      resource's produces, or by a lumberjack hut, Cyrillic in the
#      name/description fields (the charset check applies only to id fields;
#      name/description are free-form and may contain any script, so a Cyrillic
#      name here is a deliberate fixture) and underscores with digits in an id.
#   3) THE LUMBERJACK HUT EXCEPTION is computed from the data, not hardcoded
#      as a list: remove the hut or zero out wood_yield — wood loses its
#      source, and the validator must notice this.
#   4) Real data/*.json: the validator does not crash, problems correctly
#      point at the owning product, and non-ASCII in identifiers is absent
#      (the only exception to the rule "the list of problems on real data is
#      not checked" — see the comment in _test_real_data).
#   5) File and line reference (see _check_file_and_line).
#
# Real data/*.json is run at the end against invariants, not against an
# expected list: its author will fix it, and the test would fail on exactly the
# thing the validator was written for. Its problem list is printed for reference.
extends SceneTree

# Hang watchdog: without it, an aborted _initialize() coroutine looks from the
# outside like eternal silence. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const DataValidator = preload("res://scripts/data_validator.gd")


func _initialize():
    WATCHDOG.arm(self)
    var state = {"failed": false}

    if WATCHDOG.wants_case("detector"):
        _test_detector(state)
    if WATCHDOG.wants_case("no_false_positives_on_synthetic"):
        _test_no_false_positives_on_synthetic(state)
    if WATCHDOG.wants_case("lumberjack_depends_on_data"):
        _test_lumberjack_depends_on_data(state)
    if WATCHDOG.wants_case("real_data"):
        _test_real_data(state)
    if WATCHDOG.wants_case("localization"):
        _test_localization(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("VALIDATION TEST FAILED")
        quit(1)
    else:
        print("VALIDATION TEST OK")
        quit(0)


# --- 1) Each kind of check catches its own breakage -----------------------

func _test_detector(state: Dictionary):
    var gd = _make_data()

    # Expected set of breakages: kind of check → [identifier, owner].
    # Order and count are checked exactly: an extra or missing problem is
    # also a validator bug.
    var expected := {
        "produced_in": [["ghost_mill", "bad_produced_in"]],
        "result": [["ghost_product", "bad_result"]],
        "improved_by": [["ghost_farm", "bad_improved_by"]],
        "unlock_improvement": [["ghost_farm", "bad_unlock_improvement"]],
        "unlock_tech": [
            ["ghost_tech", "bad_building_tech"],
            ["ghost_tech", "bad_improvement_tech"],
            ["ghost_tech", "bad_product_tech"],
            ["ghost_tech", "bad_craft_tech"],
        ],
        "profession": [
            ["ghost_prof", "bad_building_prof"],
            ["ghost_prof", "bad_improvement_prof"],
            ["ghost_prof", "wheat"],
        ],
        "category": [["ghost_category", "bad_category"]],
        "group_member": [["ghost_member", "bad_group"]],
        "resource_group": [["@ghost_group", "bad_group_ref"]],
        "resource": [["ghost_raw", "bad_resource_ref"]],
        # Consumption rules. The reference owner is the rule itself, and it is
        # identified by the value "resource" (see data_validator
        # _validate_consumption), so source_id equals ref_id.
        "consumption_resource": [["ghost_product", "ghost_product"]],
        "consumption_group": [["@ghost_group", "@ghost_group"]],
        "prerequisite": [["ghost_tech", "bad_tech_prereq"]],
        # The "product without a source" problem has no missing identifier:
        # the fault is not in a reference but in its absence. So ref_id and
        # source_id are both the id of the owning product itself.
        "product_source": [["no_source_product", "no_source_product"]],
        # Identifier problems. The id_charset problem has no missing
        # reference (the identifier itself is at fault), so ref_id and
        # source_id are both the id of the corrupted declaration.
        #
        # The Cyrillic "сarmine" gives TWO problems of different kinds at once:
        # it is outside the alphabet (id_charset) AND indistinguishable from
        # "carmine" (id_lookalike).
        # This is not a duplicate but two different statements about one
        # character, and both are useful: the first says "replace it with
        # Latin", the second — "you now have two different resources".
        "id_charset": [["сoal_typo", "сoal_typo"], ["сarmine", "сarmine"]],
        # For id_lookalike, ref_id is the Latin "twin" (what the author
        # thinks they are referring to), source_id is the corrupted declaration.
        "id_lookalike": [["carmine", "сarmine"]],
    }

    var problems: Array = DataValidator.new().validate(gd)

    for kind in expected:
        for pair in expected[kind]:
            var ref_id: String = str(pair[0])
            var source_id: String = str(pair[1])
            var found := _find(problems, kind, ref_id, source_id)
            check(not found.is_empty(),
                "problem not found: kind=%s, ref=%s, source=%s" % [kind, ref_id, source_id],
                state)

    # Each breakage must produce exactly one problem of its own kind, not a
    # "neighboring" one — otherwise the message points at the wrong field.
    check(problems.size() == _expected_problem_count(expected),
        "expected %d problems, got %d: %s" % [
            _expected_problem_count(expected), problems.size(),
            _str_messages(problems)], state)

    # The message must name both the missing identifier and the reference
    # owner — otherwise the player will not understand what to fix.
    var sample := _find(problems, "group_member", "ghost_member", "bad_group")
    check(sample.has("message"), "the problem has no message field", state)
    check(str(sample.get("message", "")).contains("ghost_member"),
        "the message does not contain the sought identifier: %s" % str(sample.get("message", "")), state)
    check(str(sample.get("message", "")).contains("bad_group"),
        "the message does not contain the reference owner's id: %s" % str(sample.get("message", "")), state)
    check(str(sample.get("where", "")).contains("bad_group"),
        "the where field does not contain the reference owner's id: %s" % str(sample.get("where", "")), state)

    gd.free()


# --- 2) Two places where the validator must stay silent -------------------

func _test_no_false_positives_on_synthetic(state: Dictionary):
    var gd = _make_data()
    var problems: Array = DataValidator.new().validate(gd)

    check(_find(problems, "produced_in", "*", "wildcard_recipe").is_empty(),
        "the service marker \"*\" in produced_in must not be considered a breakage", state)
    check(_find(problems, "category", "animals", "wildcard_raw").is_empty(),
        "a raw resource's category (\"animals\") must not be checked against data/categories.json", state)

    # --- False positives of the "product without a source" check ---
    #
    # A naive version of this check would complain about three ordinary ways
    # to obtain a goods item, each of which occurs in the real data/.
    check(_find(problems, "product_source", "science", "science").is_empty(),
        "a product only from display_result (\"Science\") must not be considered without a source",
        state)
    check(_find(problems, "product_source", "wood", "wood").is_empty(),
        "a lumberjack hut product (a cover's wood_yield) must not be considered without a source",
        state)
    check(_find(problems, "product_source", "wheat", "wheat").is_empty(),
        "a product from a map resource's produces must not be considered without a source", state)
    check(_find(problems, "product_source", "flour", "flour").is_empty(),
        "a product from a recipe's result must not be considered without a source", state)
    # A RAW RESOURCE (whose produces is checked for values, not for
    # "where it comes from") must not fall under the check: it is taken from
    # the map by generation, so it has a source by definition.
    check(_find(problems, "product_source", "wheat_field", "wheat_field").is_empty(),
        "a raw resource must not be checked for having a source", state)

    # --- False positives of the identifier checks ---
    #
    # ONLY the "id" fields are checked. Name and description must stay
    # untouched: the charset check applies only to id fields, while
    # name/description are free-form and may contain any script — a Cyrillic
    # name here is a deliberate fixture. Translation is applied on top of the
    # English text (data_loader, DISPLAY_FIELDS). If the check ran over every
    # string in a record, it would reject the whole project.
    check(_find(problems, "id_charset", "wildcard_raw", "wildcard_raw").is_empty(),
        "Cyrillic in a name (\"Корова\") must not be considered an identifier error",
        state)
    # Underscores and digits in an id are the project norm (wheat_field,
    # bad_group_ref), not an error: the rule allows a-z, 0-9 and "_".
    check(_find(problems, "id_charset", "wheat_field", "wheat_field").is_empty(),
        "an underscore in an id must not be considered an invalid character", state)
    check(_find(problems, "id_charset", "bad_group_ref", "bad_group_ref").is_empty(),
        "underscores and digits in a recipe's id must not be considered an error", state)
    # A lone id without a "Cyrillic twin" is not a pair but an ordinary declaration.
    check(_find(problems, "id_lookalike", "wheat", "wheat").is_empty(),
        "a lone id without a homoglyph pair must not produce problems", state)

    # --- False positives of the consumption rule checks ---
    #
    # A registry rule must be able to reference both a single product and an
    # @-group and a pseudo-profession. Here the set has products, groups and
    # professions, and all three references are valid — the validator must not
    # be noisy about them. Without this check, a naive implementation would
    # look for an "id" in GameData.professions and complain about every rule
    # at once.
    check(_find(problems, "consumption_resource", "tools", "tools").is_empty(),
        "a consumption rule for an existing product must not be considered a breakage",
        state)
    check(_find(problems, "consumption_group", "@jewelry", "@jewelry").is_empty(),
        "a consumption rule for an existing @-group must not be considered a breakage",
        state)

    # Explicitly empty fields (null) are not references. None of these entities
    # must end up in the result under any kind of check.
    for entity_id in ["null_fields", "null_product", "null_improvement", "null_building"]:
        for problem in problems:
            check(str(problem.get("source_id", "")) != entity_id,
                "an explicitly empty field (null) on \"%s\" is taken for a broken reference: %s" % [
                    entity_id, str(problem.get("message", ""))], state)
            check(str(problem.get("ref_id", "")) != "<null>",
                "the identifier \"<null>\" in the message — null was not converted to an empty string", state)

    # Data WITHOUT a source index (entity_sources empty) — problems are still
    # found, they just stay without a file reference. The absence of the
    # index must not crash the validator: this makes the check usable for
    # any data with the same fields.
    for problem in problems:
        check(str(problem.get("file", "")).is_empty(),
            "without a source index, no file must be specified: %s" % [
                str(problem.get("message", ""))], state)
        check(int(problem.get("line", 0)) == 0,
            "without a source index, the line must not be non-zero", state)
        check(str(problem.get("location", "")).is_empty(),
            "without a source index, location must be empty", state)
        # The file-and-line string is location itself, and the check above
        # already required it to be empty. Here we catch something else: the
        # file path must not leak into message through some other template.
        # We check against the PATH itself, not against words like "File:": the
        # words belong to the translation and change with the language, while
        # res://data/ does not.
        check(not str(problem.get("message", "")).contains("res://data/"),
            "the message must not contain a file path without an index: %s" % [
                str(problem.get("message", ""))], state)

    gd.free()


# --- 3) The lumberjack hut exception is computed from the data -------------
#
# "Wood" is the only product with no source in produces. The link
# "cover → hut → product" is hardwired in the code, and it can be closed in
# two ways: a hardcoded list of exceptions in the validator (then it would
# stay silent forever about a removed hut or a zeroed wood_yield) or by
# reading the data. The test requires the latter: wood must "lose its source"
# when the data stops producing it — otherwise the check would lie to the
# author that everything is fine.
func _test_lumberjack_depends_on_data(state: Dictionary):
    # Zeroed the cover's yield — the hut has nothing to produce.
    var gd = _make_data()
    gd.covers["forest"]["wood_yield"] = 0
    var problems: Array = DataValidator.new().validate(gd)
    check(not _find(problems, "product_source", "wood", "wood").is_empty(),
        "after zeroing wood_yield on all covers, wood loses its source, " +
        "and the validator must notice this", state)
    gd.free()

    # Removed the hut itself — production is gone too.
    var gd2 = _make_data()
    gd2.improvements.erase("lumberjack_hut")
    var problems2: Array = DataValidator.new().validate(gd2)
    check(not _find(problems2, "product_source", "wood", "wood").is_empty(),
        "after removing the lumberjack hut, wood loses its source, " +
        "and the validator must notice this", state)
    gd2.free()

    # The other side: intact data — the source exists, there is no problem.
    var gd3 = _make_data()
    var problems3: Array = DataValidator.new().validate(gd3)
    check(_find(problems3, "product_source", "wood", "wood").is_empty(),
        "with intact data (the hut exists, wood_yield > 0) wood has a source", state)
    gd3.free()


# --- 4) Real data: the validator does not crash ---------------------------

func _test_real_data(state: Dictionary):
    var gd = load("res://scripts/GameData.gd").new()
    gd.load_all_data()

    check(gd.data_loaded, "GameData.load_all_data() did not set data_loaded", state)

    var problems: Array = DataValidator.new().validate(gd)
    print("Problems in res://data from the reference check: %d" % problems.size())
    for problem in problems:
        print("  - ", str(problem.get("message", "")))

    # We do not check specific ids from the real data: its author will fix
    # them, and the test would fail on exactly the thing the validator was
    # written for. We check invariants that must hold for any data content.

    # EXCEPTION to the rule above: non-ASCII in an id means zero problems on
    # the real data, and this statement is checked. It is safe here because it
    # is not about someone else's breakage that needs fixing, but about a
    # regression of the check itself: an id typo that uses a Cyrillic homoglyph
    # of "c" is indistinguishable from the Latin "c" and does not break
    # references, so nothing else catches it. If the test stayed silent here, a
    # single typo with such a homoglyph could slip into a release unnoticed and
    # surface a month later as "resource not found".
    var non_ascii_problems: Array = []
    for problem in problems:
        var kind := str(problem.get("kind", ""))
        if kind == "id_charset" or kind == "id_lookalike":
            non_ascii_problems.append(problem)
    check(non_ascii_problems.is_empty(),
        "res://data identifiers contain invalid characters or homoglyphs: %s" \
                % _str_messages(non_ascii_problems), state)

    # produced_in == "*" on the pseudo-recipe "empty" (data/crafts/pseudo.json)
    # is not a breakage.
    for problem in problems:
        check(not (problem.get("kind") == "produced_in" and problem.get("ref_id") == "*"),
            "the validator complains about \"*\" in produced_in", state)

    # The category is checked only on products: for every problem of kind
    # "category" the owner must be a product, not a raw resource.
    var products: Dictionary = gd.products
    for problem in problems:
        if problem.get("kind") != "category":
            continue
        var owner_id := str(problem.get("source_id", ""))
        check(products.has(owner_id),
            "a category problem on a non-product \"%s\" — a raw resource is being checked against a foreign set of categories" % owner_id,
            state)

    # Both message strings are filled in for every problem.
    for problem in problems:
        var msg := str(problem.get("message", ""))
        check(not msg.is_empty(), "a problem without message text", state)
        check(not str(problem.get("headline", "")).is_empty(),
            "a problem without headline", state)
        check(not str(problem.get("where", "")).is_empty(),
            "a problem without where", state)

    # The "product without a source" problem points at the product itself —
    # so its owner must be in GameData.products, not a raw resource or a building.
    for problem in problems:
        if problem.get("kind") != "product_source":
            continue
        var owner_id := str(problem.get("source_id", ""))
        check(products.has(owner_id),
            "a product_source problem on a non-product \"%s\"" % owner_id, state)
        check(problem.get("target") == "product",
            "product_source has a wrong target: %s" % str(problem.get("target", "")), state)

    _check_file_and_line(state, problems)

    # count_by_kind must be consistent with the list itself.
    var counts := DataValidator.new().count_by_kind(problems)
    var total := 0
    for kind in counts:
        total += int(counts[kind])
    check(total == problems.size(),
        "count_by_kind disagrees with the number of problems: %d != %d" % [total, problems.size()], state)

    gd.free()


# --- 5) File and line reference -------------------------------------------
#
# A problem must name not only the entity but also the FILE in which the
# entity is declared, and the line. The meaning of such a line is "look here",
# so what is checked is not the number itself but that the owner's declaration
# really lies on that line: otherwise the number would be plausible and wrong,
# and worse than its absence.
func _check_file_and_line(state: Dictionary, problems: Array):
    # We read each file from different problems only once.
    var lines_by_file := {}
    for problem in problems:
        var file_path := str(problem.get("file", ""))
        var line := int(problem.get("line", 0))
        var source_id := str(problem.get("source_id", ""))

        check(not file_path.is_empty(),
            "the problem %s has no file specified" % str(problem.get("message", "")), state)
        check(line > 0,
            "the problem %s has no line specified" % str(problem.get("message", "")), state)

        if file_path.is_empty() or line <= 0:
            continue

        check(file_path.begins_with("res://data/"),
            "the problem's file is outside the data folder: %s" % file_path, state)
        var location := str(problem.get("location", ""))
        check(location.contains(file_path),
            "location does not contain the file path: %s" % location, state)
        check(location.contains(str(line)),
            "location does not contain the line number: %s" % location, state)
        check(str(problem.get("message", "")).contains(file_path),
            "message does not contain the file path — it will be lost in the log", state)

        if not lines_by_file.has(file_path):
            lines_by_file[file_path] = _read_lines(file_path)
        var lines: Array = lines_by_file[file_path]
        check(line <= lines.size(),
            "line %d is beyond the end of file %s (%d lines)" % [line, file_path, lines.size()], state)
        if line > lines.size():
            continue
        var decl := str(lines[line - 1])
        check(decl.contains("\"%s\"" % source_id),
            "line %d of file %s is not the declaration of \"%s\": %s" % [
                line, file_path, source_id, decl.strip_edges()], state)


# --- 6) Localization of problem texts -------------------------------------
#
# The problem wording is translated (data_validator.gd → locale/<code>.po), and
# exactly what was done for that translation is checked:
#   * the two languages produce DIFFERENT texts, not English everywhere;
#   * the English text contains no Cyrillic (so the catalog is filled in);
#   * localize_problems() rebuilds already-collected texts when the language
#     changes, WITHOUT re-running the check: the problem structure does not
#     depend on the language.
#
# Identifiers (ghost_mill, produced_in) stay as-is in the text — they are
# machine names, not translatable words.
func _test_localization(state: Dictionary):
    var original := TranslationServer.get_locale()
    var gd = _make_data()
    var problems: Array = DataValidator.new().validate(gd)

    # Texts are collected during validate() — in the language active at that
    # moment. So we switch the language BEFORE reading, and localize_problems()
    # rebuilds the already-collected messages without re-running the check.
    TranslationServer.set_locale("en")
    DataValidator.localize_problems(problems)
    var en_sample := _find(problems, "produced_in", "ghost_mill", "bad_produced_in")
    check(not en_sample.is_empty(),
        "the synthetic data must produce a produced_in problem", state)
    var en_message := str(en_sample.get("message", ""))
    var en_headline := str(en_sample.get("headline", ""))
    var en_title := DataValidator.check_title("produced_in")
    var en_forms := DataValidator.entity_forms("building")

    TranslationServer.set_locale("ru")
    DataValidator.localize_problems(problems)
    var ru_message := str(en_sample.get("message", ""))
    var ru_headline := str(en_sample.get("headline", ""))
    var ru_title := DataValidator.check_title("produced_in")
    var ru_forms := DataValidator.entity_forms("building")

    check(ru_message != en_message,
        "the problem text must differ between languages: en=%s ru=%s" % [
            en_message, ru_message], state)
    check(ru_headline != en_headline,
        "the first line of the problem must be translated: en=%s ru=%s" % [
            en_headline, ru_headline], state)
    check(ru_message.contains("не существует"),
        "the Russian text does not contain the expected wording: %s" % ru_message, state)

    # There must be no Cyrillic in the English text. We check headline, not
    # message: message gets the entity name from the data, and in this test it
    # is deliberately Russian (see _test_no_false_positives_on_synthetic —
    # Cyrillic in a name is legitimate and must not be considered an id error).
    check(not _has_cyrillic(en_headline),
        "the English text must not contain Cyrillic: %s" % en_headline, state)

    # The check group title is also user-facing text.
    check(ru_title != en_title,
        "the check title must be translated: en=%s ru=%s" % [
            en_title, ru_title], state)
    check(not _has_cyrillic(en_title),
        "the English check title must not contain Cyrillic: %s" % en_title,
        state)

    # Cases: the same entity in three grammatical forms. In Russian these are
    # three different words, whereas English uses a single form.
    for role in ["title", "ref", "source"]:
        check(not _has_cyrillic(str(en_forms[role])),
            "the English form %s must not be Cyrillic: %s" % [
                role, str(en_forms[role])], state)
    check(str(ru_forms["ref"]) != str(ru_forms["source"]),
        "the Russian ref and source forms must not coincide: %s / %s" % [
            str(ru_forms["ref"]), str(ru_forms["source"])], state)

    TranslationServer.set_locale(original)
    gd.free()


# Cyrillic in a string is a sign that the message stayed Russian where it
# should be English (or vice versa).
func _has_cyrillic(text: String) -> bool:
    var regex := RegEx.new()
    regex.compile("[\u0400-\u04FF]")
    return regex.search(text) != null


# --- HELPERS --------------------------------------------------------------

# Synthetic data set: a "good" base + one breakage of each kind.
# A separate GameData instance is created (not the autoload) — all public
# fields the validator reads are accessible on it.
func _make_data() -> Node:
    var gd = load("res://scripts/GameData.gd").new()

    gd.categories = [
        {"id": "food", "name": "Food"},
        {"id": "other", "name": "Other"},
    ]
    gd.professions = {
        "farmer": {"id": "farmer", "name": "Farmer"},
        "blacksmith": {"id": "blacksmith", "name": "Blacksmith"},
    }
    gd.technologies = [
        {"id": "t_fire", "name": "Fire"},
        {"id": "t_wheel", "name": "Wheel"},
        # Prerequisites in both allowed formats: a flat list and a
        # list of OR-groups [[ "a", "b" ], [ "c" ]].
        {"id": "t_flat_prereq", "name": "Flat", "prerequisites": ["t_fire"]},
        {"id": "t_group_prereq", "name": "Grouped", "prerequisites": [["t_fire", "t_wheel"]]},
    ]
    gd.improvements = {
        "farm": {"id": "farm", "name": "Farm"},
        "quarry": {"id": "quarry", "name": "Quarry"},
        # The lumberjack hut is a producer that is in no produces
        # (see the LUMBERJACK_* constants in data_validator.gd). As long as the
        # hut and a cover with wood_yield exist, the product "wood" has a source.
        "lumberjack_hut": {"id": "lumberjack_hut", "name": "Lumberjack Hut"},
    }
    gd.covers = {
        "forest": {"id": "forest", "name": "Forest", "wood_yield": 2},
        "plain": {"id": "plain", "name": "Plain"},
    }
    gd.products = {
        "wheat": {"id": "wheat", "name": "Wheat", "category": "food"},
        "flour": {"id": "flour", "name": "Flour", "category": "food"},
        "tools": {"id": "tools", "name": "Tools", "category": "other"},
        # Produced by the lumberjack hut from a cover's wood_yield. The only
        # source of wood in the set: it is in neither produces nor recipes.
        "wood": {"id": "wood", "name": "Wood", "category": "other"},
        # Pseudo-product: exists only in display_result, there is no real result.
        "science": {"id": "science", "name": "Science", "category": "other"},
        # A product with the same id as the raw resource clay_deposit: this is
        # the ordinary situation "a raw resource is extracted, a product is
        # used" — the validator must tell them apart by collection, not by id.
        "clay": {"id": "clay", "name": "Clay", "category": "other"},
    }
    gd.raw_resources = {
        "wheat_field": {"id": "wheat_field", "name": "Wheat Field", "type": "raw",
                "category": "plants", "improved_by": "farm",
                "produces": {"wheat": 10, "tools": 1}},
        "clay_deposit": {"id": "clay_deposit", "name": "Clay", "type": "raw",
                "category": "plants", "improved_by": "quarry", "produces": {"clay": 10}},
    }
    gd.product_groups = {
        "grains": ["wheat"],
        "food": ["wheat", "flour"],
        "jewelry": ["tools"],
    }
    gd.product_group_names = {
        "grains": "Grains",
        "food": "Food",
        "jewelry": "Jewelry",
    }
    gd.buildings = [
        {"id": "bakery", "name": "Bakery"},
    ]

    # --- breakages ---
    # A product whose id uses a Cyrillic homoglyph of "c": visually
    # indistinguishable from the Latin one, but not byte-identical to it. There
    # is no Latin "coal_typo" in the set, so this is a lone typo (id_charset),
    # not a pair (id_lookalike).
    gd.products["сoal_typo"] = {"id": "сoal_typo", "name": "Typo",
            "category": "other"}
    # Homoglyph pair: the Latin "carmine" and the Cyrillic "сarmine" are
    # declared at the same time. The Latin spelling of references is fine (it
    # is the one that exists), so the ordinary broken-reference checks skip this
    # case entirely.
    gd.products["carmine"] = {"id": "carmine", "name": "Carmine", "category": "other"}
    gd.products["сarmine"] = {"id": "сarmine", "name": "Carmine (typo)",
            "category": "other"}
    # produced_in → a non-existent building
    gd.buildings.append({"id": "bad_building_tech", "name": "House", "unlock_tech": "ghost_tech"})
    # profession on a building
    gd.buildings.append({"id": "bad_building_prof", "name": "Workshop",
            "profession": "ghost_prof"})
    # unlock_tech on an improvement
    gd.improvements["bad_improvement_tech"] = {"id": "bad_improvement_tech",
            "name": "Bad Pit", "unlock_tech": "ghost_tech"}
    # profession on an improvement
    gd.improvements["bad_improvement_prof"] = {"id": "bad_improvement_prof",
            "name": "Bad Ploughland", "profession": "ghost_prof"}
    # improved_by on a raw resource
    gd.raw_resources["bad_improved_by"] = {"id": "bad_improved_by", "name": "Rye",
            "type": "raw", "improved_by": "ghost_farm"}
    # unlock_improvement on a product
    gd.products["bad_unlock_improvement"] = {"id": "bad_unlock_improvement",
            "name": "Grain", "category": "food", "unlock_improvement": "ghost_farm"}
    # unlock_tech on a product
    gd.products["bad_product_tech"] = {"id": "bad_product_tech", "name": "Salt",
            "category": "food", "unlock_tech": "ghost_tech"}
    # A product that NEITHER the map NOR a recipe produces: it is in no one's
    # produces, no one's result/display_result/additional_yield. The only
    # breakage of the new product_source check.
    gd.products["no_source_product"] = {"id": "no_source_product", "name": "Alchemy",
            "category": "other"}
    # category on a product
    gd.products["bad_category"] = {"id": "bad_category", "name": "Honey",
            "category": "ghost_category"}
    # a non-existent member of an @-group
    gd.product_groups["bad_group"] = ["wheat", "ghost_member"]
    gd.product_group_names["bad_group"] = "Bad Group"
    # technology prerequisites (an OR-group with one non-existent id)
    gd.technologies.append({"id": "bad_tech_prereq", "name": "Bad Technology",
            "prerequisites": [["t_wheel", "ghost_tech"]]})
# False-positive traps.
    gd.crafts = [
        # Valid recipes — the validator stays silent about them.
        {"id": "good_recipe", "name": "Good Recipe", "produced_in": ["bakery"],
                "resources": {"wood": 2, "@grains": 5}, "result": {"flour": 3},
                "unlock_tech": "t_fire"},
        # Pseudo-output: result is empty, the goods item "appears" only in
        # display_result — like "Science" in data/crafts/pseudo.json.
        {"id": "pseudo_recipe", "name": "Pseudo Recipe", "produced_in": ["bakery"],
                "resources": {}, "result": {}, "display_result": {"science": 1}},
        # "*" is the service marker "in any building".
        {"id": "wildcard_recipe", "name": "Empty Recipe", "produced_in": ["*"],
                "resources": {}, "result": {}},
        # A reference to a raw resource in result is not considered a breakage
        # (a recipe may also require a raw resource — "clay"), but a
        # non-existent one is.
        {"id": "raw_result_ok", "name": "Recipe with a raw resource in result",
                "produced_in": ["bakery"], "resources": {}, "result": {"clay": 1}},
        {"id": "bad_produced_in", "name": "Recipe in a ghost building",
                "produced_in": ["ghost_mill"], "resources": {}, "result": {}},
        {"id": "bad_result", "name": "Recipe with a ghost product",
                "produced_in": ["bakery"], "resources": {}, "result": {"ghost_product": 1}},
        {"id": "bad_craft_tech", "name": "Recipe behind a ghost technology",
                "produced_in": ["bakery"], "resources": {}, "result": {"flour": 1},
                "unlock_tech": "ghost_tech"},
        {"id": "bad_group_ref", "name": "Recipe with a ghost group",
                "produced_in": ["bakery"], "resources": {"@ghost_group": 5}, "result": {}},
        {"id": "bad_resource_ref", "name": "Recipe with a ghost resource",
                "produced_in": ["bakery"], "resources": {"ghost_raw": 5}, "result": {}},
        # Donor: provides ALL the products with deliberate breakages in other
        # fields (improvements / technologies / categories) and a product with
        # explicitly empty fields. Without it, each of those records would also
        # land in the product_source problems, and one deliberate breakage
        # would give two problems at once — but the test requires exactly one
        # breakage of each kind.
        {"id": "donor_recipe", "name": "Donor", "produced_in": ["bakery"],
                "resources": {}, "result": {
                    "bad_unlock_improvement": 1, "bad_product_tech": 1,
                    "bad_category": 1, "null_product": 1,
                    "сoal_typo": 1, "сarmine": 1, "carmine": 1}},
    ]
    # The "animals" category on a raw resource is a map generation filter, not
    # a category from categories.json. It is checked on a raw resource below.
    gd.raw_resources["wildcard_raw"] = {"id": "wildcard_raw", "name": "Корова",
            "type": "raw", "category": "animals"}

    # --- Consumption rules (data/consumption.json) ---
    #
    # Good records must stay silent: a product without "@", an existing
    # @-group, a real profession. Bad ones — one per each new kind of check.
    # The real prototype of the bad records is a forgotten "@": the author
    # writes a group id where a resource is needed (in data/consumption.json
    # this once happened with "jewelry", which does not exist as a product —
    # only the group "@jewelry" does).
    gd.consumption_rules = [
        # Good records.
        {"resource": "tools", "profession": ["farmer"]},
        {"resource": "@jewelry", "profession": ["blacksmith"]},
        # Bad: a non-existent @-group, a non-existent product,
        # a non-existent profession.
        {"resource": "@ghost_group", "profession": ["farmer"]},
        {"resource": "ghost_product", "profession": ["farmer"]},
        {"resource": "wheat", "profession": ["ghost_prof"]},
    ]

    # Explicitly empty fields (null). In data/*.json, for example,
    # "improved_by": null is written this way on nuggets — it means "no
    # improvement", not a reference to a non-existent improvement. str(null)
    # in GDScript gives "<null>", so without separate handling the validator
    # would complain about every empty field (a regression found by this very
    # test).
    gd.raw_resources["null_fields"] = {"id": "null_fields", "name": "Empty Raw Resource",
            "type": "raw", "improved_by": null, "unlock_tech": null, "category": null}
    gd.products["null_product"] = {"id": "null_product", "name": "Empty Product",
            "category": "food", "unlock_improvement": null, "unlock_tech": null}
    gd.improvements["null_improvement"] = {"id": "null_improvement",
            "name": "Empty Improvement", "profession": null, "unlock_tech": null}
    gd.buildings.append({"id": "null_building", "name": "Empty Building",
            "profession": null, "unlock_tech": null})

    return gd


func _find(problems: Array, kind: String, ref_id: String, source_id: String) -> Dictionary:
    for problem in problems:
        if str(problem.get("kind", "")) == kind \
                and str(problem.get("ref_id", "")) == ref_id \
                and str(problem.get("source_id", "")) == source_id:
            return problem
    return {}


# The data file's lines as-is (with comments) — line numbers in the validator's
# messages are counted against the source text, not one stripped of comments.
func _read_lines(file_path: String) -> Array:
    var file := FileAccess.open(file_path, FileAccess.READ)
    if file == null:
        return []
    return Array(file.get_as_text().split("\n"))


func _expected_problem_count(expected: Dictionary) -> int:
    var total := 0
    for kind in expected:
        total += (expected[kind] as Array).size()
    return total


func _str_messages(problems: Array) -> String:
    var lines: Array = []
    for problem in problems:
        lines.append(str(problem.get("message", "")))
    return "; ".join(lines)


func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
