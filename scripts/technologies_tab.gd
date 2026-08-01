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

    for child in tech_available_container.get_children():
        child.queue_free()
    for tech in GameData.technologies:
        if tech["id"] in CityData.unlocked_technologies or tech["id"] == CityData.current_research_tech_id:
            continue
        var row = HBoxContainer.new()
        var name_label = Label.new()
        name_label.text = "%s (еда: %d)  " % [tech["name"], tech.get("cost_food", 0)]
        name_label.add_theme_color_override("font_color", Color.WHITE)
        row.add_child(name_label)
        var btn = Button.new()
        btn.text = "Изучить"
        btn.pressed.connect(_on_research_button_pressed.bind(tech["id"]))
        row.add_child(btn)
        tech_available_container.add_child(row)

    for child in tech_unlocked_container.get_children():
        child.queue_free()
    for tech_id in CityData.unlocked_technologies:
        var tech_data = null
        for t in GameData.technologies:
            if t["id"] == tech_id:
                tech_data = t
                break
        if tech_data:
            var lbl = Label.new()
            lbl.text = tech_data["name"]
            lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
            tech_unlocked_container.add_child(lbl)

func _on_research_button_pressed(tech_id: String):
    emit_signal("research_requested", tech_id)
