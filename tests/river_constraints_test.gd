extends SceneTree

func _initialize() -> void:
    var rows := 24
    var cols := 24
    var radius := 20.0

    var tile_data := []
    for row in range(rows):
        var line := []
        for col in range(cols):
            line.append({"terrain": "plain", "river_edges": []})
        tile_data.append(line)

    for r in range(4, 10):
        for c in range(4, 10):
            tile_data[r][c]["terrain"] = "mountain"
    for r in range(14, 20):
        for c in range(14, 20):
            tile_data[r][c]["terrain"] = "hill"
    for r in range(9, 12):
        for c in range(12, 16):
            tile_data[r][c]["terrain"] = "lake"

    var river_manager = load("res://scripts/river_manager.gd").new()
    river_manager.generate_rivers(rows, cols, radius, tile_data, {
        "min_row": 8,
        "max_row": 16,
        "min_col": 8,
        "max_col": 16,
    })

    var rivers = river_manager.get_rivers()
    if rivers.is_empty():
        printerr("No rivers generated")
        quit(1)

    var visible_hit := false
    for river in rivers:
        var starts_in_supported := false
        var ends_in_lake := false
        for row in range(rows):
            for col in range(cols):
                var terrain = tile_data[row][col].get("terrain", "plain")
                if terrain == "mountain" or terrain == "hill":
                    if row >= 8 and row <= 16 and col >= 8 and col <= 16:
                        starts_in_supported = true
                if terrain == "lake":
                    if row >= 8 and row <= 16 and col >= 8 and col <= 16:
                        ends_in_lake = true
        if starts_in_supported and ends_in_lake:
            visible_hit = true

    if not visible_hit:
        printerr("No river crosses visible ring+region window")
        quit(1)

    print("River constraints check passed")
    quit(0)
