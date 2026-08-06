# technologies_tab.gd
extends Node

var tech_current_label: Label
var tech_progress_bar: ProgressBar
var tech_available_container: Node
var tech_unlocked_container: Node

signal research_requested(tech_id: String)

func setup(current_lbl: Label, progress: ProgressBar, available: Node, unlocked: Node):
    tech_current_label = current_lbl
    tech_progress_bar = progress
    tech_available_container = available
    tech_unlocked_container = unlocked

func refresh():
    _refresh_status_labels()
    _rebuild_lists()

func update_progress():
    # Лёгкое обновление: только прогресс исследования и текущая метка.
    _refresh_status_labels()

func _refresh_status_labels():
    if CityData.current_research_tech_id != "":
        var tech_data = null
        for t in GameData.technologies:
            if t["id"] == CityData.current_research_tech_id:
                tech_data = t
                break
        if tech_data:
            var remaining = CityData.current_research_time * (1.0 - CityData.research_progress)
            tech_current_label.text = "Изучается: %s (%.0f сек.)" % [tech_data["name"], remaining]
            tech_progress_bar.value = CityData.research_progress * 100.0
        else:
            tech_current_label.text = "Изучается: ???"
            tech_progress_bar.value = 0
    else:
        tech_current_label.text = "Нет текущего исследования"
        tech_progress_bar.value = 0

func _get_era_name(era_id: String) -> String:
    var eras = {
        "antiquity": "Античность"
    }
    return eras.get(era_id, era_id)

func _rebuild_lists():
    # --- Список доступных/недоступных технологий ---
    for child in tech_available_container.get_children():
        child.queue_free()

    for tech in GameData.technologies:
        var tech_id = tech["id"]
        var is_unlocked = tech_id in CityData.unlocked_technologies
        var is_current = tech_id == CityData.current_research_tech_id
        if is_unlocked or is_current:
            continue

        var is_available = CityData.is_tech_available(tech_id)
        var row = HBoxContainer.new()
        row.add_theme_constant_override("separation", 8)

        var era_str = _get_era_name(tech.get("era", ""))
        var name_label = Label.new()
        if is_available:
            name_label.text = "%s [%s] (еда: %d)" % [tech["name"], era_str, tech.get("cost_food", 0)]
            name_label.add_theme_color_override("font_color", Color.WHITE)
        else:
            var prereq_text = CityData.get_tech_prerequisites_text(tech_id)
            var req_str = ""
            if prereq_text != "":
                req_str = " | Требуется: " + prereq_text
            name_label.text = "%s [%s] (еда: %d)%s" % [tech["name"], era_str, tech.get("cost_food", 0), req_str]
            name_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
        row.add_child(name_label)

        if is_available:
            var btn = Button.new()
            btn.text = "Изучить"
            btn.pressed.connect(_on_research_button_pressed.bind(tech_id))
            row.add_child(btn)

        tech_available_container.add_child(row)

    # --- Список изученных технологий ---
    for child in tech_unlocked_container.get_children():
        child.queue_free()
    for tech_id in CityData.unlocked_technologies:
        var tech_data = null
        for t in GameData.technologies:
            if t["id"] == tech_id:
                tech_data = t
                break
        if tech_data:
            var era_str = _get_era_name(tech_data.get("era", ""))
            var lbl = Label.new()
            lbl.text = "%s [%s]" % [tech_data["name"], era_str]
            lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
            tech_unlocked_container.add_child(lbl)

func _on_research_button_pressed(tech_id: String):
    emit_signal("research_requested", tech_id)