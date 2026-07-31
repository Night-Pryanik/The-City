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
            {"r": 0, "c": -1}, {"r": 0, "c": 1},
            {"r": -1, "c": -1}, {"r": -1, "c": 0},
            {"r": 1, "c": -1}, {"r": 1, "c": 0}
        ]
    else:
        directions = [
            {"r": 0, "c": -1}, {"r": 0, "c": 1},
            {"r": -1, "c": 0}, {"r": -1, "c": 1},
            {"r": 1, "c": 0}, {"r": 1, "c": 1}
        ]
    for d in directions:
        var nr = row + d.r
        var nc = col + d.c
        if nr >= 0 and nr < max_rows and nc >= 0 and nc < max_cols:
            neighbors.append({"row": nr, "col": nc})
    return neighbors
