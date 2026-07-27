# expansion_manager.gd
extends Node

var is_expansion_mode = false

signal expansion_mode_changed(active: bool)
signal territory_expanded(row: int, col: int, cost: int)

@onready var main_map = get_parent()

func toggle():
    is_expansion_mode = !is_expansion_mode
    emit_signal("expansion_mode_changed", is_expansion_mode)
    return is_expansion_mode

func is_active() -> bool:
    return is_expansion_mode

func show_context_menu(row: int, col: int, click_pos: Vector2):
    var cost = 100  # Позже можно будет менять
    main_map.popup_menu.clear()
    var label = "Освоить (%d еды)" % cost
    main_map.popup_menu.add_item(label)
    main_map.popup_menu.set_item_metadata(
        main_map.popup_menu.item_count - 1,
        {"action": "expand_territory", "row": row, "col": col, "cost": cost}
    )
    main_map.popup_menu.position = click_pos
    main_map.popup_menu.popup()

func handle_action(row: int, col: int, cost: int):
    if not is_expansion_mode:
        return
    if row >= 0 and row < main_map.REGION_ROWS and col >= 0 and col < main_map.REGION_COLS:
        main_map.tile_data[row][col]["in_influence"] = true
        emit_signal("territory_expanded", row, col, cost)
