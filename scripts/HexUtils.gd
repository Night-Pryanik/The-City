@tool
class_name HexUtils

static func hex_center(row: int, col: int, radius: float) -> Vector2:
    var x_spacing = radius * sqrt(3)
    var y_spacing = radius * 1.5
    var x = col * x_spacing
    var y = row * y_spacing
    if row % 2 == 1:
        x += x_spacing / 2.0
    return Vector2(x, y)

static func hex_vertices(center_x: float, center_y: float, radius: float) -> PackedVector2Array:
    var verts = PackedVector2Array()
    for i in range(6):
        var angle_deg = 60 * i + 30
        var angle_rad = deg_to_rad(angle_deg)
        var x = center_x + radius * cos(angle_rad)
        var y = center_y + radius * sin(angle_rad)
        verts.append(Vector2(x, y))
    return verts

static func point_in_polygon(x: float, y: float, poly: PackedVector2Array) -> bool:
    var n = poly.size()
    var inside = false
    var j = n - 1
    for i in range(n):
        var xi = poly[i].x
        var yi = poly[i].y
        var xj = poly[j].x
        var yj = poly[j].y
        if ((yi > y) != (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside

static func hex_distance(r1: int, c1: int, r2: int, c2: int) -> int:
    var q1 = c1 - (r1 - (r1 & 1)) / 2
    var q2 = c2 - (r2 - (r2 & 1)) / 2
    return (abs(q1 - q2) + abs(r1 - r2) + abs((q1 + r1) - (q2 + r2))) / 2
    
static func get_neighbors_odd_r(row: int, col: int, max_rows: int, max_cols: int) -> Array:
    var neighbors = []
    var directions = []
    if row % 2 == 0:
        directions = [
            {"r": 0, "c": - 1}, {"r": 0, "c": 1},
            {"r": - 1, "c": - 1}, {"r": - 1, "c": 0},
            {"r": 1, "c": - 1}, {"r": 1, "c": 0}
        ]
    else:
        directions = [
            {"r": 0, "c": - 1}, {"r": 0, "c": 1},
            {"r": - 1, "c": 0}, {"r": - 1, "c": 1},
            {"r": 1, "c": 0}, {"r": 1, "c": 1}
        ]
    for d in directions:
        var nr = row + d.r
        var nc = col + d.c
        if nr >= 0 and nr < max_rows and nc >= 0 and nc < max_cols:
            neighbors.append({"row": nr, "col": nc})
    return neighbors

static func hex_vertex(row: int, col: int, vidx: int, radius: float) -> Vector2:
    var center = hex_center(row, col, radius)
    var verts = hex_vertices(center.x, center.y, radius)
    return verts[vidx]

# Проверяет, выполнены ли дополнительные условия спавна ресурса (spawn_conditions).
# Формат: [ [ {type, chance}, ... ], ... ] — массив групп, объединённых ИЛИ;
# внутри каждой группы условия объединены И. Это аналогично prerequisites технологий.
# Для каждой группы сначала проверяется шанс активации (chance, 0-100):
# если шанс не выпал — группа не считается выполненной.
static func spawn_conditions_met(data: Dictionary) -> bool:
    var conditions: Array = data.get("spawn_conditions", [])
    if conditions.is_empty():
        return true
    for group in conditions:
        var group_met = true
        for cond in group:
            var chance = float(cond.get("chance", 100))
            if (randf() * 100.0) > chance:
                group_met = false
                break
        if group_met:
            return true
    return false

# Проверяет, подходит ли конкретный гекс (row, col) по геометрическим
# условиям spawn_conditions ресурса. Логика: массив групп — ИЛИ, внутри — И.
# Для каждого условия проверяется совместимость гекса.
static func is_hex_conditions_met(tile_data: Array, row: int, col: int, data: Dictionary) -> bool:
    var conditions: Array = data.get("spawn_conditions", [])
    if conditions.is_empty():
        return true
    for group in conditions:
        var group_met = true
        for cond in group:
            var cond_type = cond.get("type", "")
            var ok = true
            if cond_type == "near_river":
                # Гекс имеет общее ребро с рекой ⇔ у него есть river_edges.
                ok = tile_data[row][col].get("river_edges", []).size() > 0
            elif cond_type == "terrain":
                # Универсальное условие по типу местности: гекс должен иметь
                # terrain, совпадающий с terrain_id из условия. Используется,
                # например, ресурсом soda_deposit (см. data/resources/minerals.json),
                # который спавнится только на гексах содового озера (soda_lake).
                var required_terrain: String = cond.get("terrain_id", "")
                ok = required_terrain != "" and tile_data[row][col].get("terrain", "") == required_terrain
            else:
                # Неизвестное условие — считаем выполненным, чтобы не ломать спавн.
                ok = true
            if not ok:
                group_met = false
                break
        if group_met:
            return true
    return false