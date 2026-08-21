# map_generator.gd
@tool
extends Node

# Минимальное количество СВОБОДНЫХ (без ресурса) гексов каждого типа местности,
# которое должно оставаться внутри Кольца Влияния после размещения всех ресурсов.
# Гарантирует, что у игрока всегда будет достаточно места для постройки
# нескольких ферм/пастбищ одного ресурса (например, киноа растёт только
# в горах — нужно ≥2 свободных горных гекса, чтобы построить ≥2 фермы).
const FREE_TERRAIN_HEXES := 2

# Порог «избыточности» типа местности: если какого-то типа в Кольце Влияния
# больше этого значения, его свободные гексы можно конвертировать
# в недостающие типы.
const OVER_REP_THRESHOLD := 3

# Радиус «безопасного двора» вокруг города: все гексы в этом радиусе
# принудительно становятся равниной (plain). Покров генерируется как у
# обычной равнины (могут появиться леса), чтобы двор не выглядел голым.
# Гарантирует, что у города всегда есть свободное проходимое пространство
# для стартовой застройки и что город не «утонет» в озере. Применяется
# ПОСЛЕ размещения уникальных террейнов и ДО генерации покрова/ресурсов.
const PLAIN_ZONE_RADIUS := 2

# Радиус, в котором ЗАПРЕЩАЕТСЯ размещать центры Вороного непроходимых
# типов местности (move_cost >= 999, например озёра). Благодаря свойству
# диаграммы Вороного это математически гарантирует, что в этой области
# не может появиться непроходимый террейн («утопленный двор» вокруг города).
const CENTER_EXCLUSION_RADIUS := 6

# Возвращает список типов местности, которые участвуют в алгоритме Вороного
# (базовый рельеф). НЕ входят:
#   - уникальные типы (unique: true) — их размещает place_unique_terrains;
#   - типы, не перечисленные в terrain_config (марши) — они создаются
#     только пост-обработкой (_apply_marshes).
# Участие в Вороном теперь задаётся явно через конфиг: добавление нового
# типа в terrains.json больше не заставляет его автоматически расползаться
# по всей карте.
static func _get_base_terrain_ids() -> Array:
    var cfg: Dictionary = GameData.map_config.get("terrain_config", {})
    var ids: Array = []
    for tid in GameData.terrains.keys():
        var t: Dictionary = GameData.terrains[tid]
        if t.get("unique", false):
            continue
        if not cfg.has(tid):
            continue
        ids.append(tid)
    return ids

# Возвращает список уникальных типов местности (unique: true), которые
# размещаются универсальной функцией place_unique_terrains. Это позволяет
# добавлять новые уникальные типы местности в data/terrains.json без изменения
# этого кода — функция сама итерирует по всем таким типам.
static func _get_unique_terrain_ids() -> Array:
    var unique_ids = []
    for terrain_id in GameData.terrains.keys():
        var t: Dictionary = GameData.terrains[terrain_id]
        if t.get("unique", false):
            unique_ids.append(terrain_id)
    return unique_ids

# Вычисляет количество центров Вороного для каждого типа местности на основе
# конфигурации terrain_config (density + target_cluster) из data/map_config.json.
# density приоритетна; target_cluster — ограничение сверху (число центров не
# может быть больше area / target_cluster). Избыток total перераспределяется
# на типы без ограничения target_cluster пропорционально их density.
# Участвуют ТОЛЬКО типы, явно перечисленные в terrain_config (см.
# _get_base_terrain_ids): остальные (марши) создаются пост-обработкой.
func make_terrain_counts(rows: int, cols: int) -> Dictionary:
    var cfg: Dictionary = GameData.map_config
    var area := rows * cols

    # Глобальный target_cluster — запасное значение для total.
    var global_cluster: int = int(cfg.get("target_cluster", 22))
    var total := maxi(12, int(round(float(area) / global_cluster)))

    var terrain_config: Dictionary = cfg.get("terrain_config", {})
    var base_ids := _get_base_terrain_ids()

    var counts: Dictionary = {}
    var weights: Dictionary = {}
    var has_cluster: Dictionary = {}

    for terrain_id in base_ids:
        var tc: Dictionary = terrain_config.get(terrain_id, {})
        var w := float(tc.get("density", 0.0))
        if w <= 0.0:
            w = _default_density(terrain_id)

        var cluster_limit := -1 # -1 = ограничение не задано
        if tc.has("target_cluster"):
            cluster_limit = int(tc.get("target_cluster", 0))

        weights[terrain_id] = w

        # Нижняя граница «минимум 1 центр» — только для типов с положительной
        # плотностью: явный ноль не должен порождать центры-сироты.
        var count := int(round(total * w))
        if w > 0.0:
            count = maxi(1, count)

        if cluster_limit > 0:
            var limit := maxi(1, int(round(float(area) / cluster_limit)))
            count = mini(count, limit)
            has_cluster[terrain_id] = true
        else:
            has_cluster[terrain_id] = false
        counts[terrain_id] = count

    # Перераспределение избытка: если сумма < total, избыток распределяется
    # на типы БЕЗ ограничения target_cluster пропорционально их density.
    var sum_counts := 0
    for tid in counts.keys():
        sum_counts += counts[tid]
    if sum_counts < total:
        var deficit = total - sum_counts
        var free_types: Array = []
        var free_weight := 0.0
        for tid in base_ids:
            if not has_cluster[tid]:
                free_types.append(tid)
                free_weight += weights[tid]
        if free_weight > 0.0 and not free_types.is_empty():
            for tid in free_types:
                var add := int(round(deficit * (weights[tid] / free_weight)))
                counts[tid] += add
                deficit -= add
                if deficit <= 0:
                    break
            # Остаток распределяем по одному, пока не исчерпаем.
            var i := 0
            while deficit > 0:
                counts[free_types[i % free_types.size()]] += 1
                deficit -= 1
                i += 1

    return counts

# Дефолтная плотность для типов, не указанных в map_config.json.
func _default_density(terrain_id: String) -> float:
    match terrain_id:
        "plain":
            return 0.45
        "hill":
            return 0.25
        "lake":
            return 0.10
        "mountain":
            return 0.20
        "swamp":
            return 0.05
        _:
            return 0.05

# Пост-обработка после Вороного: превращает часть равнинных гексов вокруг
# озёр и морей в марши. Кольцо шириной в 1 гекс — перебираем только
# непосредственных соседей каждого озера/моря. Каждый такой сосед-равнина
# становится маршем с шансом 15% (MARSH_CHANCE). Гексы помечаются
# временным флагом _is_marsh, чтобы генерация покрова потом могла выставить им cover.
const MARSH_CHANCE := 0.15

# Возвращает конфигурацию моря из data/map_config.json (блок "sea").
func _sea_config() -> Dictionary:
    return GameData.map_config.get("sea", {})

# Возвращает true, если гекс (row, col) помечен как море (временный флаг _is_sea).
func _is_sea_hex(tile_data: Array, row: int, col: int) -> bool:
    return tile_data[row][col].get("_is_sea", false)

# Генерирует маску моря на карте ДО алгоритма Вороного.
# Возвращает 2D-массив bool: true = гекс является морем.
# Поддерживает два режима (см. data/map_config.json, блок "sea"):
#   - "noise" (вариант А): elevation = градиент от края + шум + city_bump;
#     суша = elevation > sea_level.
#   - "edge" (вариант Б): полоса моря у выбранных сторон, ширина — гладкий 1D-шум.
#   - "none": море не генерируется.
# Гексы моря помечаются временным флагом _is_sea, чтобы после Вороного
# маску можно было повторно применить поверх результата.
func _apply_sea(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int) -> Array:
    var cfg := _sea_config()
    var mode: String = cfg.get("mode", "none")
    var sea_mask: Array = []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        row_arr.fill(false)
        sea_mask.append(row_arr)

    if mode == "none":
        return sea_mask

    var max_sea_depth: int = int(cfg.get("max_sea_depth", 8))
    var beach_enabled: bool = cfg.get("beach", true)

    # sides — диапазон [min, max] количества случайно выбранных сторон света,
    # у которых будет море. [0,0] — море не генерируется.
    # Валидация: оба элемента должны быть числами, диапазон 0..4.
    # При некорректных данных море не генерируется (безопасное поведение).
    var sides_range: Array = cfg.get("sides", [])
    var sides: Array = []
    if sides_range is Array and sides_range.size() >= 2 \
            and (typeof(sides_range[0]) == TYPE_FLOAT or typeof(sides_range[0]) == TYPE_INT) \
            and (typeof(sides_range[1]) == TYPE_FLOAT or typeof(sides_range[1]) == TYPE_INT):
        var min_sides: int = clampi(int(sides_range[0]), 0, 4)
        var max_sides: int = clampi(int(sides_range[1]), 0, 4)
        if max_sides < min_sides:
            # Диапазон задан в обратном порядке — меняем местами.
            var tmp: int = min_sides
            min_sides = max_sides
            max_sides = tmp
        # Если минимум = 0 — море может не сгенерироваться вообще.
        if max_sides <= 0:
            return sea_mask
        var all_sides: Array = ["east", "west", "north", "south"]
        var count: int = randi_range(min_sides, max_sides)
        all_sides.shuffle()
        for i in range(count):
            sides.append(all_sides[i])
    else:
        # Некорректный sides (не массив, меньше 2 элементов или не числа) —
        # безопасно отключаем генерацию моря.
        print("map_generator: предупреждение — поле sea.sides задано некорректно, море не генерируется. Ожидается [min, max] (0..4).")
        return sea_mask

    if mode == "noise":
        _apply_sea_noise(sea_mask, rows, cols, city_row, city_col, cfg, max_sea_depth, sides)
    elif mode == "edge":
        _apply_sea_edge(sea_mask, rows, cols, cfg, max_sea_depth, sides)
        # Острова в морях — только для режима "edge". Размещаются ДО пометки
        # _is_sea и ДО _apply_beach, чтобы пляж потом корректно обвёл новые
        # острова (как и любую другую сушу рядом с морем).
        if bool(cfg.get("edge_islands_enabled", true)):
            _apply_sea_islands(sea_mask, rows, cols, cfg, city_row, city_col)

    # Помечаем гексы моря временным флагом _is_sea.
    for r in range(rows):
        for c in range(cols):
            if sea_mask[r][c]:
                tile_data[r][c]["_is_sea"] = true

    # Пляж: суша, соседняя с морем, становится пляжем (beach).
    if beach_enabled:
        _apply_beach(tile_data, sea_mask, rows, cols)

    return sea_mask

# Вариант А: elevation = градиент от края + шум + city_bump; суша = elevation > sea_level.
# sides — список сторон, у которых может быть море ("east", "west", "north", "south").
# Если sides пуст — море генерируется со всех сторон (поведение по умолчанию).
func _apply_sea_noise(sea_mask: Array, rows: int, cols: int,
        city_row: int, city_col: int, cfg: Dictionary, max_sea_depth: int, sides: Array) -> void:
    var sea_level: float = float(cfg.get("noise_sea_level", 0.0))
    var noise_strength: float = float(cfg.get("noise_strength", 0.35))
    var edge_gradient: float = float(cfg.get("noise_edge_gradient", 0.4))
    var city_bump: float = float(cfg.get("noise_city_bump", 0.5))
    var city_bump_radius: float = float(cfg.get("noise_city_bump_radius", 8))

    # Нормализованные координаты: 0 в центре карты, 1 на краю.
    var half_rows = float(rows - 1) / 2.0
    var half_cols = float(cols - 1) / 2.0

    for r in range(rows):
        for c in range(cols):
            # Расстояние до ближайшего края карты (в гексах).
            var edge_dist_hex = min(
                min(r, rows - 1 - r),
                min(c, cols - 1 - c)
            )
            # Ограничение ширины моря: гексы дальше max_sea_depth от края — суша.
            if edge_dist_hex > max_sea_depth:
                continue

            # Если заданы стороны — проверяем, что гекс находится у одной из них.
            # Иначе (sides пуст) — море со всех сторон.
            if not sides.is_empty():
                var near_allowed_side := false
                for side in sides:
                    var dist_to_side := -1
                    if side == "east":
                        dist_to_side = cols - 1 - c
                    elif side == "west":
                        dist_to_side = c
                    elif side == "north":
                        dist_to_side = r
                    elif side == "south":
                        dist_to_side = rows - 1 - r
                    # Гекс у выбранной стороны, если он в пределах max_sea_depth от неё.
                    if dist_to_side >= 0 and dist_to_side <= max_sea_depth:
                        near_allowed_side = true
                        break
                if not near_allowed_side:
                    continue

            # Нормализованное расстояние до края (0 на краю, 1 в центре).
            var edge_dist = min(
                min(float(r) / half_rows, float(rows - 1 - r) / half_rows),
                min(float(c) / half_cols, float(cols - 1 - c) / half_cols)
            )
            # Градиент: центрирован около 0. На краю (edge_dist=0) — отрицательный
            # (море), в центре (edge_dist=1) — положительный (суша).
            var gradient = (edge_dist - 0.5) * 2.0 * edge_gradient

            # Шум высот (детерминированный по координатам), центрирован около 0:
            # от -noise_strength до +noise_strength.
            var noise = (_hash_noise(r, c) * 2.0 - 1.0) * noise_strength

            # City bump: «холм» вокруг города, гарантирующий стартовый континент.
            var dist_to_city = HexUtils.hex_distance(r, c, city_row, city_col)
            var bump = 0.0
            if dist_to_city <= city_bump_radius:
                var t = 1.0 - float(dist_to_city) / city_bump_radius
                bump = city_bump * t * t

            var elevation = gradient + noise + bump
            if elevation <= sea_level:
                sea_mask[r][c] = true

# Вариант Б: полоса моря у выбранных сторон, ширина — гладкий 1D-шум.
func _apply_sea_edge(sea_mask: Array, rows: int, cols: int,
        cfg: Dictionary, max_sea_depth: int, sides: Array) -> void:
    if sides.is_empty():
        return

    var width_min: float = float(cfg.get("edge_width_min", 1))
    var width_max: float = float(cfg.get("edge_width_max", 7))
    var envelope_strength: float = float(cfg.get("edge_envelope_strength", 0.0))

    # Крупномасштабный 1D-шум для естественности берега
    var envelope_noise: FastNoiseLite = FastNoiseLite.new()
    envelope_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    envelope_noise.seed = randi()
    envelope_noise.frequency = 0.08

    for side in sides:
        var len: int = rows if (side == "east" or side == "west") else cols
        var arr: Array = []
        var seg: int = 8
        var i0: int = -1
        var v0: float = 0.0
        var v1: float = randf()
        
        # Центр стороны для параболической огибающей
        var center_pos: float = float(len) / 2.0
        var half_len: float = float(len) / 2.0

        for coord in range(len):
            if coord / seg != i0:
                i0 = coord / seg
                v0 = v1
                v1 = randf()
            var t: float = 0.5 - 0.5 * cos(float(coord % seg) / float(seg) * PI)
            var base_width: float = lerpf(width_min, width_max, lerpf(v0, v1, t))

            # Параболическая огибающая: 1 в центре, 0 на краях
            var dist_from_center: float = abs(float(coord) - center_pos)
            var parabola: float = 1.0 - pow(dist_from_center / half_len, 2.0)
            parabola = max(0.0, parabola)

            # Комбинируем параболу с шумом
            if envelope_strength > 0.0:
                var noise_val: float = 0.5 + 0.5 * envelope_noise.get_noise_1d(float(coord))
                var env: float = lerp(parabola, parabola * noise_val, envelope_strength)
                base_width *= env

            arr.append(int(round(base_width)))

        # Применяем ширину к гексам
        for coord in range(len):
            var width: int = arr[coord]
            if width <= 0:
                continue
            for depth in range(width):
                if depth >= max_sea_depth:
                    break
                var r: int = 0
                var c: int = 0
                match side:
                    "east": r = coord; c = cols - 1 - depth
                    "west": r = coord; c = depth
                    "south": r = rows - 1 - depth; c = coord
                    "north": r = depth; c = coord
                if r >= 0 and r < rows and c >= 0 and c < cols:
                    sea_mask[r][c] = true

# Генерирует острова внутри маски моря (режим "edge"): часть морских гексов
# превращается в сушу группами (BFS-рост из случайных seed-точек).
# Количество "умно" подстраивается под площадь моря: target = sea_area *
# edge_island_density, фактическое число — randi_range(0, target + 1). В
# маленьком море это часто даёт 0 островов, в большом — может дать много.
# Вызывается ДО _apply_beach, чтобы пляж корректно обвёл новые острова.
func _apply_sea_islands(sea_mask: Array, rows: int, cols: int,
        cfg: Dictionary, city_row: int, city_col: int) -> void:
    # --- Чтение параметров с дефолтами ---
    var size_range: Array = cfg.get("edge_island_size", [1, 5])
    var size_min: int = 1
    var size_max: int = 5
    if size_range is Array and size_range.size() >= 2:
        size_min = maxi(1, int(size_range[0]))
        size_max = maxi(size_min, int(size_range[1]))
    var density: float = float(cfg.get("edge_island_density", 0.003))
    var min_distance: int = maxi(0, int(cfg.get("edge_island_min_distance", 3)))
    var max_attempts: int = maxi(1, int(cfg.get("edge_island_max_attempts", 60)))

    # --- Считаем площадь моря и целевое количество островов ---
    var sea_area := 0
    for r in range(rows):
        for c in range(cols):
            if sea_mask[r][c]:
                sea_area += 1
    # Без моря (или совсем крошечное) — выходим, делать нечего.
    if sea_area < size_min:
        return

    var target: int = int(round(float(sea_area) * density))
    # Разброс: 0..target+1. Если target=0, даёт 0..1 (редкий одиночный остров);
    # если target=10, даёт 0..11. Это и есть «может быть, но не обязано».
    var actual_count: int = randi_range(0, target + 1)
    if actual_count <= 0:
        return

    # --- Список всех морских гексов (для быстрого случайного выбора seed) ---
    var sea_cells: Array = []
    for r in range(rows):
        for c in range(cols):
            if sea_mask[r][c]:
                sea_cells.append({"row": r, "col": c})
    if sea_cells.is_empty():
        return
    sea_cells.shuffle()

    # --- Занятые точки (центры уже размещённых островов) — для min_distance ---
    var occupied: Array = []

    var islands_placed := 0
    var island_index := 0
    while island_index < actual_count and not sea_cells.is_empty():
        # Размер конкретного острова в этом размещении.
        var island_size: int = randi_range(size_min, size_max)
        # Ищем seed-точку: перебираем sea_cells в случайном порядке, пока не
        # найдём подходящую (в море + не слишком близко к городу/другим островам).
        var seed_index := -1
        var attempts := 0
        while attempts < max_attempts and sea_cells.size() > 0:
            var idx: int = randi() % sea_cells.size()
            var candidate = sea_cells[idx]
            # Слишком близко к городу (стартовая зона) — пропускаем. 2 гекса —
            # потому что _ensure_plain_zone очищает радиус 2 вокруг города;
            # даже если остров на границе этого радиуса, его гексы уйдут в
            # равнину и он «исчезнет», что нарушит инвариант «остров в море».
            if HexUtils.hex_distance(candidate.row, candidate.col, city_row, city_col) <= 2:
                attempts += 1
                # Удаляем из пула, чтобы не перебирать вечно.
                sea_cells.remove_at(idx)
                continue
            # Слишком близко к другому острову — пропускаем.
            var too_close := false
            for occ in occupied:
                if HexUtils.hex_distance(candidate.row, candidate.col, occ.row, occ.col) < min_distance:
                    too_close = true
                    break
            if too_close:
                attempts += 1
                sea_cells.remove_at(idx)
                continue
            # Нашли подходящую seed-точку.
            seed_index = idx
            break
        if seed_index < 0:
            # Не нашли место за max_attempts попыток — выходим, оставшиеся
            # острова не размещаем (лучше меньше, чем бесконечный цикл).
            break
        var seed = sea_cells[seed_index]
        sea_cells.remove_at(seed_index)

        # --- BFS-рост кластера: добавляем соседей по одному, пока не наберём island_size ---
        var cluster: Array = [seed]
        var cluster_set := {}
        cluster_set["%d,%d" % [seed.row, seed.col]] = true
        var frontier: Array = [seed]
        while cluster.size() < island_size and not frontier.is_empty():
            var next_frontier: Array = []
            for cell in frontier:
                if cluster.size() >= island_size:
                    break
                var neighbors = HexUtils.get_neighbors_odd_r(cell.row, cell.col, rows, cols)
                neighbors.shuffle()
                for n in neighbors:
                    if cluster.size() >= island_size:
                        break
                    var nk := "%d,%d" % [n.row, n.col]
                    if cluster_set.has(nk):
                        continue
                    # Растём только по морю — не «прыгаем» на сушу/острова.
                    if not sea_mask[n.row][n.col]:
                        continue
                    cluster_set[nk] = true
                    cluster.append(n)
                    next_frontier.append(n)
                    if cluster.size() >= island_size:
                        break
            frontier = next_frontier
        if cluster.is_empty():
            continue

        # --- Превращаем гексы кластера из моря в сушу (сброс sea_mask) ---
        for cell in cluster:
            sea_mask[cell.row][cell.col] = false
        # Запоминаем seed как занятую точку для будущих min_distance проверок.
        occupied.append(seed)
        islands_placed += 1
        island_index += 1

    if islands_placed > 0:
        print("map_generator: размещено островов в море: %d (целевое количество было %d, площадь моря %d)" %
                [islands_placed, target, sea_area])

# Гладкая ширина полосы моря вдоль стороны (1D-шум).
func _smooth_width(row: int, col: int, side: String, width_min: int, width_max: int) -> float:
    var t := 0.0
    if side == "east" or side == "west":
        t = float(row) / 10.0
    else:
        t = float(col) / 10.0
    # Сумма синусоид даёт плавное изменение ширины вдоль берега.
    var v = 0.5 + 0.5 * sin(t * 6.283 + _hash_noise(row, col) * 6.283)
    return lerpf(float(width_min), float(width_max), v)

# Детерминированный псевдослучайный шум по координатам (0..1).
# Константа-смещение 1013904223 гарантирует, что для (0,0) шум не равен 0.0
# (иначе при sea_level = 0.0 гекс (0,0) всегда становился бы морем).
func _hash_noise(row: int, col: int) -> float:
    var h = row * 374761393 + col * 668265263 + 1013904223
    h = (h ^ (h >> 13)) * 1274126177
    h = h ^ (h >> 16)
    return float((h & 0x7fffffff) % 10000) / 10000.0

# Превращает сушу, соседнюю с морем, в пляж (beach).
func _apply_beach(tile_data: Array, sea_mask: Array, rows: int, cols: int) -> void:
    # Пляж формируется только на суше, связанной с краем карты. Замкнутые
    # морем участки сохраняют рельеф Вороного и не превращаются в марши.
    var edge_connected_land := []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        row_arr.fill(false)
        edge_connected_land.append(row_arr)

    var queue: Array = []
    for r in range(rows):
        for c in range(cols):
            if r != 0 and r != rows - 1 and c != 0 and c != cols - 1:
                continue
            if sea_mask[r][c] or edge_connected_land[r][c]:
                continue
            edge_connected_land[r][c] = true
            queue.append({"row": r, "col": c})

    var queue_index := 0
    while queue_index < queue.size():
        var current = queue[queue_index]
        queue_index += 1
        for n in HexUtils.get_neighbors_odd_r(current.row, current.col, rows, cols):
            if sea_mask[n.row][n.col] or edge_connected_land[n.row][n.col]:
                continue
            edge_connected_land[n.row][n.col] = true
            queue.append(n)

    for r in range(rows):
        for c in range(cols):
            if sea_mask[r][c] or not edge_connected_land[r][c]:
                continue
            # Гекс суши: проверяем, есть ли сосед-море.
            var has_sea_neighbor := false
            for n in HexUtils.get_neighbors_odd_r(r, c, rows, cols):
                if sea_mask[n.row][n.col]:
                    has_sea_neighbor = true
                    break
            if has_sea_neighbor:
                tile_data[r][c]["terrain"] = "beach"
                tile_data[r][c]["_is_beach"] = true

func _replace_island_lakes(tile_data: Array, sea_mask: Array, rows: int, cols: int) -> void:
    var edge_connected_land := []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        row_arr.fill(false)
        edge_connected_land.append(row_arr)

    var queue: Array = []
    for r in range(rows):
        for c in range(cols):
            if r != 0 and r != rows - 1 and c != 0 and c != cols - 1:
                continue
            if sea_mask[r][c] or edge_connected_land[r][c]:
                continue
            edge_connected_land[r][c] = true
            queue.append({"row": r, "col": c})

    var queue_index := 0
    while queue_index < queue.size():
        var current = queue[queue_index]
        queue_index += 1
        for n in HexUtils.get_neighbors_odd_r(current.row, current.col, rows, cols):
            if sea_mask[n.row][n.col] or edge_connected_land[n.row][n.col]:
                continue
            edge_connected_land[n.row][n.col] = true
            queue.append(n)

    for r in range(rows):
        for c in range(cols):
            if sea_mask[r][c] or edge_connected_land[r][c]:
                continue
            if tile_data[r][c].get("terrain", "plain") == "lake":
                tile_data[r][c]["terrain"] = "plain"
                tile_data[r][c]["cover"] = _roll_cover("plain")

func _apply_marshes(tile_data: Array, rows: int, cols: int) -> void:
    var lake_hexes: Array = []
    var sea_hexes: Array = []
    for r in range(rows):
        for c in range(cols):
            var terrain_id = tile_data[r][c].get("terrain", "plain")
            if terrain_id == "lake":
                lake_hexes.append({"row": r, "col": c})
            elif terrain_id == "sea":
                sea_hexes.append({"row": r, "col": c})

    # У озёр: марши образуются на окружающей равнине (кольцо вокруг озера).
    for water in lake_hexes:
        var neighbors = HexUtils.get_neighbors_odd_r(water.row, water.col, rows, cols)
        for n in neighbors:
            var t = tile_data[n.row][n.col]
            if t.get("terrain", "plain") != "plain":
                continue
            if randf() < MARSH_CHANCE:
                t["terrain"] = "marsh"
                t["_is_marsh"] = true

    # У морей: марши образуются ТОЛЬКО на побережье (пляже beach), а не на
    # внутренней суше островков. Пляж — прибрежная заболоченная зона.
    # Вызывается ПОСЛЕ применения маски моря/пляжа.
    for water in sea_hexes:
        var neighbors = HexUtils.get_neighbors_odd_r(water.row, water.col, rows, cols)
        for n in neighbors:
            var t = tile_data[n.row][n.col]
            if t.get("terrain", "plain") != "beach":
                continue
            if randf() < MARSH_CHANCE:
                t["terrain"] = "marsh"
                t["_is_marsh"] = true
                t["_is_beach"] = false

func generate_map(rows: int, cols: int, city_row: int, city_col: int, raw_res: Dictionary, terrain_counts: Dictionary) -> Array:
    var t0 = Time.get_ticks_msec()
    var tile_data = []
    for row in range(rows):
        var col_array = []
        for col in range(cols):
            col_array.append({"terrain": "plain", "cover": "none", "resource": null, "improvement": null})
        tile_data.append(col_array)

    # --- МОРЯ (маска ДО Вороного) ---
    # Море не участвует в алгоритме Вороного (не входит в terrain_config).
    # Маска моря генерируется здесь и запоминается во временном флаге _is_sea,
    # а после Вороного повторно применяется поверх результата (см. ниже),
    # чтобы Вороной не перезаписал море/пляж.
    var sea_mask = _apply_sea(tile_data, rows, cols, city_row, city_col)

    # Генерируем центры для Вороного. Для непроходимых типов местности
    # (озёра и т.п., move_cost >= 999) центры НЕ должны попадать в радиус
    # CENTER_EXCLUSION_RADIUS вокруг города: благодаря свойству диаграммы
    # Вороного это математически гарантирует, что в этой области не
    # появится непроходимый террейн (город не окажется на острове).
    var centers = []
    for terrain_id in terrain_counts.keys():
        var count = terrain_counts[terrain_id]
        var exclude_center = _is_impassable_terrain_id(terrain_id)
        for _i in range(count):
            var r = randi() % rows
            var c = randi() % cols
            if exclude_center and HexUtils.hex_distance(r, c, city_row, city_col) <= CENTER_EXCLUSION_RADIUS:
                # Перебираем позиции, пока не найдём место за пределами зоны
                # исключения (или не исчерпаем попытки — тогда оставляем как есть).
                for _try in range(50):
                    r = randi() % rows
                    c = randi() % cols
                    if HexUtils.hex_distance(r, c, city_row, city_col) > CENTER_EXCLUSION_RADIUS:
                        break
            centers.append({"r": r, "c": c, "terrain": terrain_id})

    # Jump Flood Algorithm (JFA): строим диаграмму Вороного за O(n log n)
    # вместо наивного O(n * centers). Для карты 200x200 это ~2.5 млн операций
    # вместо ~73 млн, что ускоряет генерацию рельефа в десятки раз.
    var t_jfa = Time.get_ticks_msec()
    var voronoi = _jump_flood_voronoi(rows, cols, centers)
    print("этап JFA: ", Time.get_ticks_msec() - t_jfa, " ms")
    for row in range(rows):
        for col in range(cols):
            tile_data[row][col]["terrain"] = voronoi[row][col]

    # --- ПОВТОРНОЕ ПРИМЕНЕНИЕ МАСКИ МОРЯ/ПЛЯЖА ---
    # Вороной заполнил всю карту своим рельефом, поэтому поверх него
    # заново накладываем море (по флагу _is_sea) и пляж (по флагу _is_beach),
    # чтобы они не были перезаписаны.
    for row in range(rows):
        for col in range(cols):
            var tile = tile_data[row][col]
            if tile.get("_is_sea", false):
                tile["terrain"] = "sea"
                tile["cover"] = "none"
            elif tile.get("_is_beach", false):
                tile["terrain"] = "beach"
                tile["cover"] = "none"

    # Морские острова не должны состоять из озёр: заменяем озёра в замкнутых
    # морем land-компонентах на равнину до проверки минимального числа озёр.
    _replace_island_lakes(tile_data, sea_mask, rows, cols)

    # Гарантируем минимальный объём озёр на карте: озеро не должно исчезать
    # в слишком маленьких картах или при редких случайностях генерации центров.
    var lake_tiles := 0
    for row in range(rows):
        for col in range(cols):
            if tile_data[row][col]["terrain"] == "lake":
                lake_tiles += 1
    if lake_tiles < 3:
        for row in range(rows):
            for col in range(cols):
                if lake_tiles >= 3:
                    break
                if tile_data[row][col]["resource"] != null:
                    continue
                if tile_data[row][col]["terrain"] == "lake":
                    continue
                tile_data[row][col]["terrain"] = "lake"
                tile_data[row][col]["cover"] = "none"
                lake_tiles += 1
            if lake_tiles >= 3:
                break

    # --- МАРШИ (пост-обработка после Вороного) ---
    # Вокруг каждого озера с шансом ~40-50% соседние равнинные гексы
    # превращаются в марши — кольцо шириной в 1 гекс. Такие гексы
    # помечаются временным флагом _is_marsh, чтобы при генерации покрова
    # получить cover.
    _apply_marshes(tile_data, rows, cols)

    # --- УНИКАЛЬНЫЕ ТИПЫ МЕСТНОСТИ ---
    # Размещаются ПОСЛЕ Вороного, но ДО генерации покрова и ресурсов.
    # Универсальная функция place_unique_terrains сама итерирует по всем
    # уникальным типам местности (unique: true) из data/terrains.json и читает
    # для каждого максимальный размер кластера (cluster_size). Каждый тип
    # размещается один раз, кластером 1..cluster_size гексов, за пределами
    # стартового Кольца Влияния. Добавление нового уникального типа в
    # terrains.json не требует изменения этого кода.
    place_unique_terrains(tile_data, rows, cols, city_row, city_col)

    # --- БЕЗОПАСНЫЙ ДВОР ВОКРУГ ГОРОДА ---
    # Принудительно превращаем гексы в радиусе PLAIN_ZONE_RADIUS вокруг города
    # в равнину; покров генерируется как у обычной равнины. Это гарантирует
    # свободное проходимое пространство для стартовой застройки и перекрывает
    # возможные марши/уникальные озёра, которые могли попасть в эту зону.
    # Выполняется ПОСЛЕ размещения уникальных террейнов и ДО генерации покрова
    # и ресурсов.
    _ensure_plain_zone(tile_data, rows, cols, city_row, city_col, PLAIN_ZONE_RADIUS)

    var t_cover = Time.get_ticks_msec()
    for row in range(rows):
        for col in range(cols):
            var terrain_id = tile_data[row][col]["terrain"]
            tile_data[row][col]["cover"] = _roll_cover(terrain_id)

    # Мультиииндекс свободных гексов по (terrain, cover) — для быстрого
    # размещения ресурсов без полного сканирования карты на каждый ресурс.
    var hex_index = _build_hex_index(tile_data, rows, cols, city_row, city_col)
    print("этап cover + hex_index: ", Time.get_ticks_msec() - t_cover, " ms")

    # --- Животные ---
    var animal_resources = {}
    for rid in raw_res.keys():
        var r = raw_res[rid]
        if r.get("category", "") == "animals":
            animal_resources[rid] = r
    _place_resources(tile_data, animal_resources, rows, cols, city_row, city_col, hex_index)

    # --- Растения ---
    var plant_resources = {}
    for rid in raw_res.keys():
        var r = raw_res[rid]
        if r.get("category", "") == "plants":
            plant_resources[rid] = r
    _place_resources(tile_data, plant_resources, rows, cols, city_row, city_col, hex_index)

    # --- Минералы ---
    var mineral_resources = {}
    for rid in raw_res.keys():
        var r = raw_res[rid]
        if r.get("category", "") == "minerals":
            mineral_resources[rid] = r
    _place_resources(tile_data, mineral_resources, rows, cols, city_row, city_col, hex_index)

    # --- Все ресурсы спавнятся на старте, включая tech_required и tech_reveal ---
    # Раньше ресурсы с tech_required фильтровались здесь и спавнились
    # лениво через CityData.spawn_resource_on_tech_research. Теперь они
    # появляются сразу на карте, а видимость/добыча регулируется полями
    # tech_reveal (видимость) и tech_required (постройка улучшения).
    # См. docs.md, раздел «tech_reveal: скрытые ресурсы».

    # --- ГАРАНТИЯ ВЫХОДА НАРУЖУ ---
    # Страховочная проверка: если несмотря на запрет центров озер город всё же
    # оказался изолирован непроходимым террейном, прокладываем коридор в равнину
    # к внешнему миру. Выполняется в самом конце, чтобы учесть все уже
    # размещённые марши и уникальные озёра.
    _ensure_outward_corridor(tile_data, rows, cols, city_row, city_col)

    print("этап generate_map: ", Time.get_ticks_msec() - t0, " ms")
    return tile_data

# Универсальная функция размещения всех уникальных типов местности на карте.
# Итерирует по всем типам с "unique": true в data/terrains.json и для каждого
# размещает ОДИН сомкнутный кластер размером 1..cluster_size гексов за
# пределами стартового Кольца Влияния. Максимальный размер кластера читается
# из поля "cluster_size" данных террейна (дефолт 3, если поле не задано).
# Добавление нового уникального типа в terrains.json не требует изменения кода.
func place_unique_terrains(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int) -> void:
    # Границы стартового Кольца Влияния из конфигурации.
    var cfg: Dictionary = GameData.map_config
    var ring_rows: int = int(cfg.get("start_ring_rows", 5))
    var ring_cols: int = int(cfg.get("start_ring_cols", 7))
    var inf_start_row: int = int(floor(city_row - ring_rows / 2.0))
    var inf_end_row: int = inf_start_row + ring_rows - 1
    var inf_start_col: int = int(floor(city_col - ring_cols / 2.0))
    var inf_end_col: int = inf_start_col + ring_cols - 1

    # Собираем все гексы вне Кольца, не занятые городом.
    var candidates: Array = []
    for r in range(rows):
        for c in range(cols):
            if r >= inf_start_row and r <= inf_end_row and c >= inf_start_col and c <= inf_end_col:
                continue
            if r == city_row and c == city_col:
                continue
            candidates.append({"row": r, "col": c})
    if candidates.is_empty():
        print("ОШИБКА place_unique_terrains: нет гексов за пределами Кольца Влияния!")
        return

    for terrain_type in _get_unique_terrain_ids():
        var t: Dictionary = GameData.terrains[terrain_type]
        var max_cluster_size: int = int(t.get("cluster_size", 3))

        # Случайный размер кластера от 1 до max_cluster_size.
        var cluster_size: int = randi_range(1, maxi(1, max_cluster_size))

        # Случайная точка старта в пределах допустимой области.
        var start = candidates[randi() % candidates.size()]

        # BFS: строим связный кластер из cluster_size гексов, прилегающих к старту.
        var cluster: Array = [start]
        var visited := {}
        visited["%d,%d" % [start.row, start.col]] = true
        var frontier: Array = [start]
        while cluster.size() < cluster_size and frontier.size() > 0:
            var next_frontier: Array = []
            for hex in frontier:
                var neighbors = HexUtils.get_neighbors_odd_r(hex.row, hex.col, rows, cols)
                neighbors.shuffle()
                for n in neighbors:
                    var key = "%d,%d" % [n.row, n.col]
                    if visited.has(key):
                        continue
                    if n.row >= inf_start_row and n.row <= inf_end_row and n.col >= inf_start_col and n.col <= inf_end_col:
                        continue
                    if n.row == city_row and n.col == city_col:
                        continue
                    visited[key] = true
                    cluster.append(n)
                    next_frontier.append(n)
                    if cluster.size() >= cluster_size:
                        break
                if cluster.size() >= cluster_size:
                    break
            frontier = next_frontier

        # Меняем террайн на уникальный для выбранных гексов (только если там нет улучшения).
        for hex in cluster:
            var tile = tile_data[hex.row][hex.col]
            if tile.get("improvement", null) == null:
                tile["terrain"] = terrain_type
                tile["cover"] = _roll_cover(terrain_type)

        print("Уникальный тип местности %s размещён: %d гексов" % [terrain_type, cluster.size()])

# Jump Flood Algorithm (JFA) для построения диаграммы Вороного на
# гексагональной сетке (odd-r). Сложность O(rows * cols * log2(max(rows, cols)))
# вместо наивного O(rows * cols * centers.size()).
# Возвращает 2D-массив terrain_id для каждой клетки.
func _jump_flood_voronoi(rows: int, cols: int, centers: Array) -> Array:
    # Сетка индексов ближайших центров (-1 = пусто).
    var grid = []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        row_arr.fill(-1)
        grid.append(row_arr)

    # Предвычисляем q-координаты центров (для быстрой hex_distance).
    var center_q = []
    for ci in range(centers.size()):
        var center = centers[ci]
        center_q.append(center.c - ((center.r - (center.r & 1)) >> 1))

    # Размещаем центры в сетке.
    for ci in range(centers.size()):
        var center = centers[ci]
        grid[center.r][center.c] = ci

    # Начальный шаг: наибольшая степень двойки, не превосходящая max(rows, cols).
    var max_dim = maxi(rows, cols)
    var step = 1
    while step * 2 <= max_dim:
        step *= 2

    # 8 направлений JFA (прямоугольный шаблон).
    var dirs = [
        Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(-1, 1),
        Vector2i(0, -1), Vector2i(0, 1),
        Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1)
    ]

    # Двойная буферизация (ping-pong), чтобы информация распространялась
    # ровно на один "прыжок" за итерацию.
    var read_grid = grid
    var write_grid = []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        row_arr.fill(-1)
        write_grid.append(row_arr)

    while step >= 1:
        for r in range(rows):
            var q_base = (r - (r & 1)) >> 1
            for c in range(cols):
                var q = c - q_base
                var best_ci = read_grid[r][c]
                var best_dist = INF
                if best_ci >= 0:
                    var cr = centers[best_ci].r
                    var cq = center_q[best_ci]
                    best_dist = (abs(q - cq) + abs(r - cr) + abs((q + r) - (cq + cr))) >> 1
                for d in dirs:
                    var nr = r + d.x * step
                    var nc = c + d.y * step
                    if nr < 0 or nr >= rows or nc < 0 or nc >= cols:
                        continue
                    var neighbor_ci = read_grid[nr][nc]
                    if neighbor_ci < 0:
                        continue
                    var ncr = centers[neighbor_ci].r
                    var ncq = center_q[neighbor_ci]
                    var dist3 = (abs(q - ncq) + abs(r - ncr) + abs((q + r) - (ncq + ncr))) >> 1
                    if dist3 < best_dist:
                        best_dist = dist3
                        best_ci = neighbor_ci
                write_grid[r][c] = best_ci
        # Меняем буферы местами.
        var tmp = read_grid
        read_grid = write_grid
        write_grid = tmp
        step >>= 1

    # Финальный проход по 6 гексагональным соседям: убирает артефакты
    # прямоугольного шаблона JFA и доводит границы до гексагональной метрики.
    var even_dirs = [
        Vector2i(0, -1), Vector2i(0, 1),
        Vector2i(-1, -1), Vector2i(-1, 0),
        Vector2i(1, -1), Vector2i(1, 0)
    ]
    var odd_dirs = [
        Vector2i(0, -1), Vector2i(0, 1),
        Vector2i(-1, 0), Vector2i(-1, 1),
        Vector2i(1, 0), Vector2i(1, 1)
    ]
    for r in range(rows):
        var rdirs = even_dirs if r % 2 == 0 else odd_dirs
        var q_base = (r - (r & 1)) >> 1
        for c in range(cols):
            var q = c - q_base
            var best_ci = read_grid[r][c]
            var best_dist = INF
            if best_ci >= 0:
                var cr = centers[best_ci].r
                var cq = center_q[best_ci]
                best_dist = (abs(q - cq) + abs(r - cr) + abs((q + r) - (cq + cr))) >> 1
            for d in rdirs:
                var nr = r + d.x
                var nc = c + d.y
                if nr < 0 or nr >= rows or nc < 0 or nc >= cols:
                    continue
                var nb_ci = read_grid[nr][nc]
                if nb_ci < 0:
                    continue
                var nc_r = centers[nb_ci].r
                var nc_q = center_q[nb_ci]
                var dist4 = (abs(q - nc_q) + abs(r - nc_r) + abs((q + r) - (nc_q + nc_r))) >> 1
                if dist4 < best_dist:
                    best_dist = dist4
                    best_ci = nb_ci
            read_grid[r][c] = best_ci

    # Превращаем индексы центров в terrain_id.
    var result = []
    for r in range(rows):
        var row_arr = []
        row_arr.resize(cols)
        for c in range(cols):
            var ci = read_grid[r][c]
            row_arr[c] = centers[ci].terrain if ci >= 0 else "plain"
        result.append(row_arr)
    return result

# Возвращает true, если тип местности непроходим (move_cost >= 999).
# Такие типы (озёра: lake, soda_lake, asphalt_lake, salt_lake) блокируют
# перемещение города наружу.
func _is_impassable_terrain_id(terrain_id: String) -> bool:
    var t: Dictionary = GameData.terrains.get(terrain_id, {})
    return int(t.get("move_cost", 1)) >= 999

# Возвращает true, если гекс (row, col) непроходим.
func _is_impassable_hex(tile_data: Array, row: int, col: int) -> bool:
    var terrain_id = tile_data[row][col].get("terrain", "plain")
    return _is_impassable_terrain_id(terrain_id)

# Принудительно превращает все гексы в радиусе `radius` вокруг города
# в равнину (plain) без покрова. Сбрасывает временный флаг _is_marsh.
# Вызывается ПОСЛЕ размещения уникальных террейнов и ДО генерации покрова
# и ресурсов, чтобы зона была полностью «чистой».
func _ensure_plain_zone(tile_data: Array, rows: int, cols: int,
        city_row: int, city_col: int, radius: int) -> void:
    for r in range(rows):
        for c in range(cols):
            if HexUtils.hex_distance(r, c, city_row, city_col) <= radius:
                var tile = tile_data[r][c]
                tile["terrain"] = "plain"
                # Покров генерируется как у обычной равнины (могут появиться
                # леса), чтобы безопасный двор не выглядел голым.
                tile["cover"] = _roll_cover("plain")
                tile["_is_marsh"] = false
                tile["_is_sea"] = false
                tile["_is_beach"] = false

# Гарантирует, что у города есть путь к краю карты (к «внешнему миру»).
# Если город оказался изолирован непроходимым террейном (озером или морем),
# функция BFS по непроходимым гексам прокладывает кратчайший коридор от
# достижимой области города к ближайшему внешнему проходимому гексу и
# превращает этот коридор в равнину. Море — не препятствие для пробивки
# (как и озеро), а побережье (beach, move_cost: 1) — валидный выход.
# Повторяется до тех пор, пока город не получит выход к краю карты
# (или не упрётся в лимит итераций).
func _ensure_outward_corridor(tile_data: Array, rows: int, cols: int,
        city_row: int, city_col: int) -> void:
    for _iter in range(10):
        # 1) Достижимая из города область по проходимым гексам.
        var reachable := {}
        var key_city = "%d,%d" % [city_row, city_col]
        reachable[key_city] = true
        var queue: Array = [ {"row": city_row, "col": city_col}]
        while queue.size() > 0:
            var cur = queue.pop_front()
            for n in HexUtils.get_neighbors_odd_r(cur.row, cur.col, rows, cols):
                var nk = "%d,%d" % [n.row, n.col]
                if reachable.has(nk):
                    continue
                if _is_impassable_hex(tile_data, n.row, n.col):
                    continue
                reachable[nk] = true
                queue.append(n)

        # 2) Если город достиг проходимого края карты — выход есть.
        if _has_exit_to_edge(reachable, rows, cols):
            return

        # 3) Ищем водный путь от достижимой области к ближайшему внешнему
        #    проходимому гексу. BFS стартует со всех непроходимых соседей A.
        var from := {}
        var water_queue: Array = []
        for key in reachable:
            var parts = key.split(",")
            var r = int(parts[0])
            var c = int(parts[1])
            for n in HexUtils.get_neighbors_odd_r(r, c, rows, cols):
                var nk = "%d,%d" % [n.row, n.col]
                if reachable.has(nk):
                    continue
                if not _is_impassable_hex(tile_data, n.row, n.col):
                    continue
                if not from.has(nk):
                    from[nk] = key
                    water_queue.append({"row": n.row, "col": n.col})

        var target_key := ""
        var qi := 0
        while qi < water_queue.size() and target_key == "":
            var cur = water_queue[qi]
            qi += 1
            var ck = "%d,%d" % [cur.row, cur.col]
            for n in HexUtils.get_neighbors_odd_r(cur.row, cur.col, rows, cols):
                var nk = "%d,%d" % [n.row, n.col]
                if from.has(nk):
                    continue
                if _is_impassable_hex(tile_data, n.row, n.col):
                    from[nk] = ck
                    water_queue.append({"row": n.row, "col": n.col})
                else:
                    if not reachable.has(nk):
                        target_key = nk
                        from[nk] = ck
                        break

        if target_key == "":
            # Не нашли внешний проходимый гекс (весь мир — вода/острова).
            # Пробиваем коридор напрямую к краю карты сквозь воду.
            if not _punch_corridor_to_edge(tile_data, rows, cols, city_row, city_col, reachable):
                return

        # 4) Восстанавливаем путь: непроходимые гексы превращаем в равнину.
        if target_key != "":
            var step = target_key
            while true:
                var prev = from.get(step, "")
                if prev == "":
                    break
                if reachable.has(prev):
                    break
                _punch_hex(tile_data, prev)
                step = prev

# Возвращает true, если хоть один гекс достижимой области лежит на краю карты.
func _has_exit_to_edge(reachable: Dictionary, rows: int, cols: int) -> bool:
    for r in [0, rows - 1]:
        for c in range(cols):
            if reachable.has("%d,%d" % [r, c]):
                return true
    for c in [0, cols - 1]:
        for r in range(rows):
            if reachable.has("%d,%d" % [r, c]):
                return true
    return false

# Превращает гекс (key "r,c") в равнину без покрова.
# Используется для пробивки коридора выхода сквозь непроходимые гексы
# (озёра и моря). Сбрасывает временные флаги _is_marsh и _is_sea.
func _punch_hex(tile_data: Array, key: String) -> void:
    var parts = key.split(",")
    var r = int(parts[0])
    var c = int(parts[1])
    var tile = tile_data[r][c]
    tile["terrain"] = "plain"
    # Покров генерируется как у обычной равнины для естественного вида.
    tile["cover"] = _roll_cover("plain")
    tile["_is_marsh"] = false
    tile["_is_sea"] = false

# Пробивает коридор от достижимой области напрямую к краю карты через
# непроходимые гексы. Возвращает true, если коридор удалось проложить.
func _punch_corridor_to_edge(tile_data: Array, rows: int, cols: int,
        city_row: int, city_col: int, reachable: Dictionary) -> bool:
    var from := {}
    var queue: Array = []
    for key in reachable:
        var parts = key.split(",")
        var r = int(parts[0])
        var c = int(parts[1])
        for n in HexUtils.get_neighbors_odd_r(r, c, rows, cols):
            var nk = "%d,%d" % [n.row, n.col]
            if reachable.has(nk):
                continue
            if not _is_impassable_hex(tile_data, n.row, n.col):
                continue
            if not from.has(nk):
                from[nk] = key
                queue.append({"row": n.row, "col": n.col})
    var qi := 0
    var target_key := ""
    while qi < queue.size() and target_key == "":
        var cur = queue[qi]
        qi += 1
        var ck = "%d,%d" % [cur.row, cur.col]
        if cur.row == 0 or cur.row == rows - 1 or cur.col == 0 or cur.col == cols - 1:
            target_key = ck
            break
        for n in HexUtils.get_neighbors_odd_r(cur.row, cur.col, rows, cols):
            var nk = "%d,%d" % [n.row, n.col]
            if from.has(nk):
                continue
            if not _is_impassable_hex(tile_data, n.row, n.col):
                continue
            from[nk] = ck
            queue.append({"row": n.row, "col": n.col})
    if target_key == "":
        return false
    # Пробиваем путь от целевой краевой непроходимой клетки обратно к A.
    var step = target_key
    while true:
        _punch_hex(tile_data, step)
        var prev = from.get(step, "")
        if prev == "" or reachable.has(prev):
            break
        step = prev
    return true

# Выбирает покоры (cover) для гекса с указанным типом местности по весам
# из terrains.json (cover_chance). Если поле отсутствует или пустое —
# возвращает "none".
func _roll_cover(terrain_type: String) -> String:
    var t: Dictionary = GameData.terrains.get(terrain_type, {})
    var chances: Dictionary = t.get("cover_chance", {})
    if chances.is_empty():
        return "none"
    var total := 0.0
    total = 0.0
    for cid in chances.keys():
        total += float(chances[cid])
    if total <= 0.0:
        return "none"
    var roll = randf() * total
    var accum := 0.0
    for cid in chances.keys():
        accum += float(chances[cid])
        if roll < accum:
            return cid
    return "none"

# Строит мультиииндекс свободных гексов по (terrain, cover).
# Ключ: "terrain|cover" -> Array словарей {"row", "col"}.
# Гексы рядом с городом (abs <= 1) исключаются, чтобы не мешать
# стартовому строительству (как в исходном _place_resources).
func _build_hex_index(tile_data: Array, rows: int, cols: int, city_row: int, city_col: int) -> Dictionary:
    var index: Dictionary = {}
    for r in range(rows):
        for c in range(cols):
            if abs(r - city_row) <= 1 and abs(c - city_col) <= 1:
                continue
            var tile = tile_data[r][c]
            if tile.get("resource", null) != null:
                continue
            var terrain_id = tile.get("terrain", "plain")
            var cover_id = tile.get("cover", "none")
            var key = "%s|%s" % [terrain_id, cover_id]
            if not index.has(key):
                index[key] = []
            index[key].append({"row": r, "col": c})
    return index

# Удалявляет гекс из мультиииндекса после занятия его ресурсом.
func _remove_hex_from_index(hex_index: Dictionary, row: int, col: int, terrain_id: String, cover_id: String) -> void:
    var key = "%s|%s" % [terrain_id, cover_id]
    if not hex_index.has(key):
        return
    var arr: Array = hex_index[key]
    for i in range(arr.size()):
        if arr[i].row == row and arr[i].col == col:
            arr.remove_at(i)
            break
    if arr.is_empty():
        hex_index.erase(key)

func _place_resources(tile_data: Array, res_dict: Dictionary, rows: int, cols: int, city_row: int, city_col: int, hex_index: Dictionary):
    if res_dict.size() == 0:
        return
    # Спавним ВСЕ ресурсы категории на карте, а не 1-3 случайных (как было
    # раньше). Ресурс размещается на случайном подходящем гексе, если
    # выполняются:
    #   * tech_required (если есть) — на старте все уже считаются доступными,
    #     т.к. это поле гейтит только постройку улучшения, а не появление;
    #   * spawn_conditions — шанс активации и геометрические условия
    #     (например, «у реки», «на содовом озере»); если не выпал/не подходит —
    #     ресурс пропускается;
    #   * allowed_terrain / allowed_cover — обычные биомные ограничения.
    #
    # Если у ресурса есть tech_reveal (подземные ископаемые) — он появляется
    # на карте СРАЗУ, но скрыт от игрока до изучения соответствующей технологии.
    # См. docs.md, раздел «tech_reveal: скрытые ресурсы».
    #
    # Перемешиваем ключи, чтобы порядок размещения был случайным — иначе
    # первые в словаре всегда занимают лучшие гексы, а последние рискуют
    # не найти подходящего места.
    var ids = res_dict.keys()
    ids.shuffle()
    for res_id in ids:
        var data = res_dict[res_id]
        if not HexUtils.spawn_conditions_met(data):
            continue
        var possible = []
        for terrain_id in data.get("allowed_terrain", []):
            for cover_id in data.get("allowed_cover", []):
                var key = "%s|%s" % [terrain_id, cover_id]
                if not hex_index.has(key):
                    continue
                var arr: Array = hex_index[key]
                for hex in arr:
                    if HexUtils.is_hex_conditions_met(tile_data, hex.row, hex.col, data):
                        possible.append(hex)
        if possible.size() > 0:
            var hex = possible[randi() % possible.size()]
            tile_data[hex.row][hex.col]["resource"] = res_id
            tile_data[hex.row][hex.col]["quality"] = GameData.roll_quality()
            _remove_hex_from_index(hex_index, hex.row, hex.col,
                    tile_data[hex.row][hex.col]["terrain"], tile_data[hex.row][hex.col].get("cover", "none"))

# Размещает дикоросы ТОЛЬКО внутри стартового Кольца Влияния.
func place_wild_food(tile_data: Array, min_row: int, max_row: int, min_col: int, max_col: int, city_row: int, city_col: int):
    var count = randi_range(2, 4)
    var wild_id = "wild_food"
    if not GameData.raw_resources.has(wild_id):
        return
    var wild_data = GameData.raw_resources[wild_id]
    var possible = []
    for r in range(min_row, max_row + 1):
        for c in range(min_col, max_col + 1):
            if abs(r - city_row) <= 2 and abs(c - city_col) <= 2:
                continue
            if tile_data[r][c]["resource"] != null:
                continue
            var terrain_id = tile_data[r][c]["terrain"]
            var cover_id = tile_data[r][c].get("cover", "none")
            if terrain_id in wild_data.get("allowed_terrain", []) and cover_id in wild_data.get("allowed_cover", []):
                possible.append({"row": r, "col": c})
    possible.shuffle()
    for i in range(min(count, possible.size())):
        var hex = possible[i]
        tile_data[hex.row][hex.col]["resource"] = wild_id
        tile_data[hex.row][hex.col]["quality"] = GameData.roll_quality()

func ensure_free_terrain_hexes(tile_data: Array, terrain_counts: Dictionary,
        min_row: int, max_row: int, min_col: int, max_col: int,
        city_row: int = -1, city_col: int = -1) -> void:
    var free_count: Dictionary = {}
    for terrain_id in terrain_counts.keys():
        free_count[terrain_id] = 0
    for r in range(min_row, max_row + 1):
        for c in range(min_col, max_col + 1):
            # Гекс города и его соседи (3×3) исключаются из подсчёта и
            # конвертации — террейн города не должен меняться после
            # _ensure_city_valid_terrain, а соседи нужны для стартового строительства.
            if city_row >= 0 and abs(r - city_row) <= 1 and abs(c - city_col) <= 1:
                continue
            var tile = tile_data[r][c]
            if tile.get("resource", null) != null:
                continue
            var terrain_id = tile.get("terrain", "plain")
            if free_count.has(terrain_id):
                free_count[terrain_id] += 1

    for terrain_id in terrain_counts.keys():
        var deficit = FREE_TERRAIN_HEXES - free_count.get(terrain_id, 0)
        if deficit <= 0:
            continue
        var converted = _convert_free_terrain_near_cluster(tile_data, terrain_id, deficit,
                min_row, max_row, min_col, max_col, free_count, terrain_counts,
                city_row, city_col)
        free_count[terrain_id] += converted

func _convert_free_terrain_near_cluster(tile_data: Array, terrain_id: String, deficit: int,
        min_row: int, max_row: int, min_col: int, max_col: int,
        free_count: Dictionary, terrain_counts: Dictionary,
        city_row: int = -1, city_col: int = -1) -> int:
    var converted = 0
    var cluster: Array = []
    var visited := {}
    for r in range(min_row, max_row + 1):
        for c in range(min_col, max_col + 1):
            # Гекс города и его соседи (3×3) не входят в кластер и не
            # конвертируются — террейн города фиксирован.
            if city_row >= 0 and abs(r - city_row) <= 1 and abs(c - city_col) <= 1:
                continue
            var tile = tile_data[r][c]
            if tile.get("resource", null) != null:
                continue
            if tile.get("terrain", "plain") == terrain_id:
                cluster.append({"row": r, "col": c})
                visited["%d_%d" % [r, c]] = true

    var candidates: Array = []
    var frontier = cluster.duplicate()
    var distance = 0
    var max_distance = (max_row - min_row + 1) + (max_col - min_col + 1)
    while frontier.size() > 0 and distance < max_distance:
        distance += 1
        var next_frontier: Array = []
        for hex in frontier:
            var neighbors = HexUtils.get_neighbors_odd_r(hex.row, hex.col, max_row + 1, max_col + 1)
            for n in neighbors:
                if n.row < min_row or n.row > max_row or n.col < min_col or n.col > max_col:
                    continue
                # Гекс города и его соседи не посещаются и не становятся кандидатами.
                if city_row >= 0 and abs(n.row - city_row) <= 1 and abs(n.col - city_col) <= 1:
                    continue
                var key = "%d_%d" % [n.row, n.col]
                if visited.has(key):
                    continue
                visited[key] = true
                if tile_data[n.row][n.col].get("resource", null) != null:
                    continue
                var n_terrain = tile_data[n.row][n.col].get("terrain", "plain")
                if n_terrain == terrain_id:
                    next_frontier.append(n)
                else:
                    candidates.append({"row": n.row, "col": n.col, "terrain": n_terrain, "dist": distance})
        frontier = next_frontier

    if cluster.size() == 0 and candidates.size() == 0:
        for r in range(min_row, max_row + 1):
            for c in range(min_col, max_col + 1):
                if city_row >= 0 and abs(r - city_row) <= 1 and abs(c - city_col) <= 1:
                    continue
                if tile_data[r][c].get("resource", null) != null:
                    continue
                if tile_data[r][c].get("terrain", "plain") != terrain_id:
                    candidates.append({"row": r, "col": c,
                            "terrain": tile_data[r][c].get("terrain", "plain"), "dist": 0})

    candidates.sort_custom(func(a, b):
        var a_over = free_count.get(a.terrain, 0) > OVER_REP_THRESHOLD
        var b_over = free_count.get(b.terrain, 0) > OVER_REP_THRESHOLD
        if a.dist != b.dist:
            return a.dist < b.dist
        if a_over != b_over:
            return a_over and not b_over
        return a.terrain < b.terrain)

    for cand in candidates:
        if converted >= deficit:
            break
        # Гекс города и его соседи не конвертируются террейном.
        if city_row >= 0 and abs(cand.row - city_row) <= 1 and abs(cand.col - city_col) <= 1:
            continue
        var old_terrain = cand.terrain
        var row = cand.row
        var col = cand.col
        var tile = tile_data[row][col]
        if tile.get("terrain", "plain") != old_terrain:
            continue
        if tile.get("resource", null) != null:
            continue
        var donor_min = FREE_TERRAIN_HEXES
        if cluster.size() == 0:
            donor_min = FREE_TERRAIN_HEXES - 1
        if free_count.get(old_terrain, 0) <= donor_min:
            continue
        tile["terrain"] = terrain_id
        tile["cover"] = _roll_cover(terrain_id)
        if free_count.has(old_terrain):
            free_count[old_terrain] = max(0, free_count[old_terrain] - 1)
        free_count[terrain_id] = free_count.get(terrain_id, 0) + 1
        converted += 1

    return converted
