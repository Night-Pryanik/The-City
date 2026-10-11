# Smoke test of the treasury breakdown by sources (headless):
#   godot --headless --path . --script res://tests/test_treasury_breakdown.gd
# Checks the state machine of CityData.record_treasury_* / rotate_treasury_window and
# the dynamics of the "Treasury: N [+X≈ / -Y≈]" row (CityData.get_treasury_flow_per_sec /
# get_treasury_flow_text: the fact over the window, recalculated per second).
# Does not use the autoload-dependent API (the GameData/CityData of the game),
# because in `--script` mode the autoload chain does not come up (see
# developer_diary, "Bugfix: ..."): an integration check needs a
# real scene launch (a full headless pass was already done manually and in a
# short headless run over 240 frames — there are no parse errors and no SCRIPT ERROR).
extends SceneTree

# Watchdog against hangs: without it, an aborted _run() coroutine looks like an endless
# silence from the outside. See tests/watchdog.gd for details.
const WATCHDOG = preload("res://tests/watchdog.gd")

func _initialize():
    WATCHDOG.arm(self)
    var state: Dictionary = {"failed": false}

    var cd = load("res://scripts/CityData.gd").new()
    cd.treasury = 0

    # ---- 1) Accumulation in the current window ----
    cd.record_treasury_income("Fisherman", 5)
    cd.record_treasury_income("Fisherman", 3)
    cd.record_treasury_income("All Citizens", 7)
    cd.record_treasury_expense("Scouting", 12)

    check(int(cd.treasury_income_accum.get("Fisherman", 0)) == 8,
        "accum Fisherman: expected 8, got %d" % int(cd.treasury_income_accum.get("Fisherman", 0)), state)
    check(int(cd.treasury_income_accum.get("All Citizens", 0)) == 7,
        "accum All Citizens: expected 7, got %d" % int(cd.treasury_income_accum.get("All Citizens", 0)), state)
    check(int(cd.treasury_expense_accum.get("Scouting", 0)) == 12,
        "accum Scouting: expected 12, got %d" % int(cd.treasury_expense_accum.get("Scouting", 0)), state)
    check(cd.treasury_income_snapshot.is_empty(),
        "the snapshot before rotate must be empty", state)

    # ---- 2) rotate_treasury_window: snapshot + zeroing ----
    cd.rotate_treasury_window()
    check(int(cd.treasury_income_snapshot.get("Fisherman", 0)) == 8,
        "snapshot Fisherman after rotate: expected 8, got %d" % int(cd.treasury_income_snapshot.get("Fisherman", 0)), state)
    check(int(cd.treasury_income_snapshot.get("All Citizens", 0)) == 7,
        "snapshot All Citizens after rotate: expected 7, got %d" % int(cd.treasury_income_snapshot.get("All Citizens", 0)), state)
    check(int(cd.treasury_expense_snapshot.get("Scouting", 0)) == 12,
        "snapshot Scouting after rotate: expected 12, got %d" % int(cd.treasury_expense_snapshot.get("Scouting", 0)), state)
    check(cd.treasury_income_accum.is_empty(),
        "accum after rotate must be empty", state)
    check(cd.treasury_expense_accum.is_empty(),
        "expense accum after rotate must be empty", state)

    # ---- 3) Additional accumulation after rotate — the snapshot is not touched ----
    cd.record_treasury_income("Blacksmith", 11)
    cd.record_treasury_expense("Scouting", 4)
    check(int(cd.treasury_income_accum.get("Blacksmith", 0)) == 11,
        "the new Blacksmith accum is not written", state)
    check(int(cd.treasury_income_snapshot.get("Blacksmith", 0)) == 0,
        "the snapshot must not update without rotate", state)
    check(int(cd.treasury_expense_snapshot.get("Scouting", 0)) == 12,
        "the expense snapshot must not update without rotate", state)

    # ---- 4) Empty / zero-amount calls — no-op ----
    var income_before: Dictionary = cd.treasury_income_accum.duplicate()
    var expense_before: Dictionary = cd.treasury_expense_accum.duplicate()
    cd.record_treasury_income("", 5) # empty name — ignore
    cd.record_treasury_income("X", 0) # 0 — ignore
    cd.record_treasury_expense("", 5)
    cd.record_treasury_expense("Y", 0)
    check(cd.treasury_income_accum == income_before,
        "after the no-op calls income_accum must not change", state)
    check(cd.treasury_expense_accum == expense_before,
        "after the no-op calls expense_accum must not change", state)

    # ---- 5) DEFAULT_TREASURY_WINDOW_SEC ----
    check(cd.DEFAULT_TREASURY_WINDOW_SEC == 3.0,
        "DEFAULT_TREASURY_WINDOW_SEC: expected 3.0, got %s" % str(cd.DEFAULT_TREASURY_WINDOW_SEC), state)

    # ---- 6) A refund is netted inside the expense source ----
    # In the hierarchical breakdown of the treasury the refund of a chunk claim is not
    # a separate income source (there it is only "Population consumption"), but is
    # subtracted from the gross expense of "Claiming land chunks". The tooltip shows
    # the net sum with a "−" sign, the refund does not appear as a separate row.
    var cd2 = load("res://scripts/CityData.gd").new()
    cd2.treasury = 0
    cd2.record_treasury_expense("Claiming land chunks", 25)  # paid
    cd2.record_treasury_expense("Claiming land chunks", -10) # the construction did not start → refund
    cd2.rotate_treasury_window()
    var net_expansion := int(cd2.treasury_expense_snapshot.get("Claiming land chunks", 0))
    check(net_expansion == 15,
        "net expense after the refund: expected 15, got %d" % net_expansion, state)
    # A "pure" refund without a compensating spending does not crash either: a record with
    # amount < 0 goes into the same source, after which rotate fixes a
    # snapshot with a negative value; in the tooltip such sources are hidden,
    # because the player has no expense anyway — this is visible from the fact itself.
    var cd3 = load("res://scripts/CityData.gd").new()
    cd3.record_treasury_expense("Claiming land chunks", -10)
    cd3.rotate_treasury_window()
    check(int(cd3.treasury_expense_snapshot.get("Claiming land chunks", 0)) == -10,
        "pure refund without spending: expected -10, got %d" % int(cd3.treasury_expense_snapshot.get("Claiming land chunks", 0)), state)

    # ---- 7. The dynamics of the "Treasury: N [+X / -Y]" row (the fact per second) ----
    # It is counted from the same window snapshots as the breakdown tooltip: the sum over the window
    # divided by its length (treasury_window_length_sec = 3.0).
    var cd4 = load("res://scripts/CityData.gd").new()
    cd4.record_treasury_income("Fisherman", 30) # 30 coins per window = 10 / sec
    cd4.record_treasury_income("Poll tax", 6) # another 2 / sec
    cd4.record_treasury_expense("Scouting", 9) # 9 per window = 3 / sec
    var flow_before_rotate: Dictionary = cd4.get_treasury_flow_per_sec()
    check(is_equal_approx(float(flow_before_rotate.get("income", 0.0)), 12.0),
        "before the first rotation the window accumulator is used: expected 12.0 / sec, got %s"
            % str(flow_before_rotate.get("income", 0.0)), state)
    check(is_equal_approx(float(flow_before_rotate.get("expense", 0.0)), 3.0),
        "expense before the rotation: expected 3.0 / sec, got %s"
            % str(flow_before_rotate.get("expense", 0.0)), state)
    check(cd4.get_treasury_flow_text() == "[+12≈ / -3≈]",
        "the dynamics text before the rotation, got \"%s\"" % cd4.get_treasury_flow_text(), state)

    cd4.rotate_treasury_window()
    var flow_after_rotate: Dictionary = cd4.get_treasury_flow_per_sec()
    check(is_equal_approx(float(flow_after_rotate.get("income", 0.0)), 12.0),
        "after the rotation the income is taken from the snapshot: expected 12.0 / sec, got %s"
            % str(flow_after_rotate.get("income", 0.0)), state)
    check(is_equal_approx(float(flow_after_rotate.get("expense", 0.0)), 3.0),
        "after the rotation the expense is taken from the snapshot: expected 3.0 / sec, got %s"
            % str(flow_after_rotate.get("expense", 0.0)), state)
    # The snapshot does NOT empty together with the accumulators: it keeps what got into
    # the window — the dynamics in the row do not collapse to zero on the next window.
    check(cd4.get_treasury_flow_text() == "[+12≈ / -3≈]",
        "the dynamics text after the rotation, got \"%s\"" % cd4.get_treasury_flow_text(), state)

    # A fractional rate: 1 coin per 3 sec window = 0.3 / sec — we do not round to zero,
    # the format is the same as ui_helpers._format_rate (one tenth).
    var cd5 = load("res://scripts/CityData.gd").new()
    cd5.record_treasury_income("Fisherman", 1)
    check(cd5.get_treasury_flow_text() == "[+0.3≈ / -0≈]",
        "fractional income rate: got \"%s\"" % cd5.get_treasury_flow_text(), state)

    # Pure refunds (amount < 0 without a compensating spending) do not go into the row's
    # expense — just as the breakdown tooltip hides them (see record_treasury_expense).
    var cd6 = load("res://scripts/CityData.gd").new()
    cd6.record_treasury_expense("Claiming land chunks", -12)
    cd6.rotate_treasury_window()
    check(is_equal_approx(float(cd6.get_treasury_flow_per_sec().get("expense", -1.0)), 0.0),
        "a pure refund must not produce an expense in the row", state)
    # But the net expense after the refund is an ordinary expense: 25 − 10 = 15 per window.
    var cd7 = load("res://scripts/CityData.gd").new()
    cd7.record_treasury_expense("Claiming land chunks", 25)
    cd7.record_treasury_expense("Claiming land chunks", -10)
    cd7.rotate_treasury_window()
    check(cd7.get_treasury_flow_text() == "[+0≈ / -5≈]",
        "net expense 15 per 3 sec window = 5 / sec, got \"%s\""
            % cd7.get_treasury_flow_text(), state)

    # A zero-length window (a safeguard against division by zero) — zeros, not NaN/inf.
    var cd8 = load("res://scripts/CityData.gd").new()
    cd8.record_treasury_income("Fisherman", 30)
    cd8.treasury_window_length_sec = 0.0
    var zero_window: Dictionary = cd8.get_treasury_flow_per_sec()
    check(is_equal_approx(float(zero_window.get("income", -1.0)), 0.0)
            and is_equal_approx(float(zero_window.get("expense", -1.0)), 0.0),
        "zero-length window: the rates must be zero, got %s"
            % str(zero_window), state)

    if state.failed:
        print("FAIL")
        quit(1)
    else:
        print("TREASURY BREAKDOWN TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if cond:
        return
    state.failed = true
    print("FAIL: %s" % msg)
