# town_manager.gd
# Менеджер городков (мелких поселений). На старте игры генерирует заданное
# число городков в случайных гексах рядом с точками тяготения, чтобы в
# дальнейшем их можно было использовать для торговли.
#
# --- Алгоритм размещения (каскадный, по ТЗ) ---
# Точки тяготения — четыре приоритета (именно в этом порядке):
#   1) гексы со стратегическими ресурсами (resource.strategic == true);
#   2) гексы, по которым текут реки (river_edges непустой);
#   3) морское побережье (terrain == "beach");
#   4) побережье озёр (гексы, соседние с terrain == "lake").
#
# Для каждого городка:
#   - Берётся ПЕРВЫЙ непустой приоритет как «основной». Если в нём есть
#     валидное место (в радиусе 3 гексов от любой точки приоритета и
#     удовлетворяющее всем ограничениям гекса) — городок ставится туда.
#   - Затем идут ШАГИ УТОЧНЕНИЯ: для каждого следующего непустого приоритета
#     ищем в небольшом радиусе (REFINEMENT_RADIUS) от текущей позиции
#     такой гекс, который одновременно:
#       (а) в радиусе 3 от какой-то точки уже «удовлетворённых» приоритетов;
#       (б) в радиусе 3 от какой-то точки НОВОГО приоритета.
#     Если нашли — городок переезжает в этот гекс и приоритет добавляется
#     в список удовлетворённых. Если не нашли — позиция остаётся прежней,
#     приоритет пропускается, идём к следующему.
#   - Итог: городок тяготеет к 1..4 приоритетам, причём на каждом шаге
#     мы ГАРАНТИРУЕМ, что все ранее «заработанные» тяготения сохраняются.
#
# Если ВСЕ четыре приоритета пустые (нет ни стратегических ресурсов, ни рек,
# ни моря, ни озёр) — этот городок не размещается, идём к следующему.
#
# --- Ограничения на гекс городка ---
#   - не вода и не горы/непроходимая местность;
#   - не пляж (на самом краю воды);
#   - не гекс города игрока;
#   - не гекс другого городка и не ближе MIN_DISTANCE_BETWEEN_TOWNS;
#   - не внутри стартовой видимой области (Кольцо + стартовый Регион —
#     иначе городок был бы виден с самого начала игры);
#   - опционально: гекс должен лежать в заданной «обязательной» области
#     (используется для гарантии «городок в эре-2»);
#   - на гексе ещё нет постройки.
#
# --- Гарантия «хотя бы 1 городок в области 2-й эпохи» ---
# После основного прохода проверяем, есть ли хоть один городок в
# эра-2-видимой области (Кольцо_2 + Регион_2). Если нет — пробуем
# разместить один дополнительный городок с теми же ограничениями, но
# «обязательная область» = эра-2-видимая. Исключение стартовой области
# сохраняется, так что новый городок попадает в новую «полосу» между
# эрой-1 и эрой-2 — то есть появится у игрока именно при переходе в эру 2.
#
# --- Конфигурация ---
#   data/map_config.json: "num_towns" — целевое число городков (умеренно 8
#   для карты 60x60). Если 0 или отрицательное — городки не генерируются.
#
# --- Сейв/лоад ---
# Список гексов сохраняется как [[row, col], ...] в SaveManager.saved_data["towns"]
# и восстанавливается в main_map._ready (после загрузки tile_data).
# В tile_data гексы помечаются флагом has_town для рендерера и панели управления.
@tool
class_name TownManager
extends Node

# Имя файла иконки городка. По ТЗ используем ту же иконку, что у города
# игрока (icons/city.png), но рисуем меньшего размера.
const TOWN_ICON_NAME := "city.png"
# Размер иконки городка в пикселях. Город игрока рисуется 130, городок —
# мельче, чтобы визуально не конкурировать с городом.
const TOWN_ICON_SIZE := 60
# Прозрачность иконки городка за пределами видимого Региона (туман войны).
# Игрок должен видеть «что-то есть», но без деталей.
const FOG_TOWN_ICON_ALPHA := 0.55
# Максимальное расстояние от точки тяготения до гекса городка (в гексах).
const MAX_ATTRACTION_DISTANCE := 3
# Радиус поиска при «уточнении» позиции на следующем приоритете (в гексах).
# Уточнение ищет гекс в REFINEMENT_RADIUS от текущей позиции, который
# удовлетворяет ВСЕМ уже набранным приоритетам + новому.
const REFINEMENT_RADIUS := 2
# Минимальная дистанция между двумя городками (для рассредоточения).
const MIN_DISTANCE_BETWEEN_TOWNS := 3
# Максимум попыток найти валидный гекс для одного городка в пределах
# одного шага (ищем другую опорную точку того же приоритета, если возле
# текущей опорной точки не нашлось подходящего гекса).
const MAX_TOWN_PLACEMENT_ATTEMPTS := 50

# Гексы с городками: Array of {row: int, col: int}.
# Генерируется один раз при старте новой игры; на загруженном сейве
# восстанавливается из сохранения (load_towns).
var town_hexes: Array = []


# Генерирует городки. Вызывается из main_map._initialize_map ПОСЛЕ
# генерации рек (чтобы river_edges уже были проставлены в tile_data).
#
# Параметры:
#   tile_data            — 2D-массив гексов.
#   rows, cols           — размеры карты.
#   city_row, city_col   — координаты города игрока.
#
#   exclusion_start_row/col, exclusion_end_row/col — зона, ВНУТРИ которой
#                          городки НЕ размещаются. Это стартовая видимая
#                          область (Кольцо + стартовый Регион): иначе
#                          городки были бы видны с самого начала.
#
#   era2_region_start_row/col, era2_region_end_row/col — границы видимой
#                          области ВТОРОЙ эпохи (Кольцо_2 + Регион_2).
#                          Используется как «обязательная зона» для
#                          гарантии «хотя бы 1 городок в эре-2».
func generate_towns(tile_data: Array, rows: int, cols: int,
        city_row: int, city_col: int,
        exclusion_start_row: int, exclusion_end_row: int,
        exclusion_start_col: int, exclusion_end_col: int,
        era2_region_start_row: int, era2_region_end_row: int,
        era2_region_start_col: int, era2_region_end_col: int) -> void:
    # Очищаем предыдущее состояние (на случай повторного вызова) и
    # снимаем флаг has_town со всех гексов — повторная генерация не должна
    # «накапливать» старые пометки.
    town_hexes = []
    for r in range(rows):
        for c in range(cols):
            if tile_data[r][c] != null:
                tile_data[r][c]["has_town"] = false

    var num_towns: int = int(GameData.map_config.get("num_towns", 8))
    if num_towns <= 0:
        print("town_manager: num_towns=", num_towns, " — городки не генерируются")
        return
    if rows < 3 or cols < 3:
        print("town_manager: карта слишком мала для городков")
        return

    # --- Основной проход: размещаем num_towns городков каскадным алгоритмом ---
    for _i in range(num_towns):
        var placed = _try_place_one_town(tile_data, rows, cols,
                city_row, city_col,
                exclusion_start_row, exclusion_end_row,
                exclusion_start_col, exclusion_end_col,
                -1, -1, -1, -1,  # без «обязательной зоны» на основном проходе
                false)
        if placed.is_empty():
            print("town_manager: не удалось разместить городок #", town_hexes.size() + 1,
                    " (нет валидных мест ни в одном приоритете)")
            continue
        town_hexes.append(placed)
        tile_data[placed.row][placed.col]["has_town"] = true

    # --- Гарантия «≥1 городок в области 2-й эпохи» ---
    # Если среди размещённых городков нет ни одного в эра-2-области, делаем
    # ещё одну попытку — размещаем «гарантийный» городок с «обязательной
    # зоной» = эра-2-область. Исключение стартовой области сохраняется,
    # так что городок попадёт в новую полосу, видимую только в эре 2.
    var has_era2_town := false
    for h in town_hexes:
        if h.row >= era2_region_start_row and h.row <= era2_region_end_row \
                and h.col >= era2_region_start_col and h.col <= era2_region_end_col:
            has_era2_town = true
            break
    if not has_era2_town:
        var forced = _try_place_one_town(tile_data, rows, cols,
                city_row, city_col,
                exclusion_start_row, exclusion_end_row,
                exclusion_start_col, exclusion_end_col,
                era2_region_start_row, era2_region_end_row,
                era2_region_start_col, era2_region_end_col,
                false)
        if not forced.is_empty():
            town_hexes.append(forced)
            tile_data[forced.row][forced.col]["has_town"] = true
            print("town_manager: гарантия эры-2 — добавлен городок на (",
                    forced.row, ",", forced.col, ")")
        else:
            print("town_manager: гарантия эры-2 НЕ выполнена — нет валидного ",
                    "гекса в новой полосе (вероятно, всё вода/непроходимо)")

    print("town_manager: всего размещено городков=", town_hexes.size(),
            " (целевое=", num_towns, ")")


# Пытается разместить один городок каскадным алгоритмом (по ТЗ).
# Возвращает координаты {row, col} или пустой словарь {}, если место
# не нашлось ни в одном приоритете.
#
# Параметр require_in_region_* задаёт «обязательную зону» (например,
# эра-2-область для гарантийного городка): если задан, итоговый гекс
# должен лежать внутри неё. Если задан как -1 — ограничение отключено.
func _try_place_one_town(tile_data: Array, rows: int, cols: int,
        city_row: int, city_col: int,
        exclusion_start_row: int, exclusion_end_row: int,
        exclusion_start_col: int, exclusion_end_col: int,
        require_in_region_start_row: int, require_in_region_end_row: int,
        require_in_region_start_col: int, require_in_region_end_col: int,
        ignore_exclusion: bool) -> Dictionary:

    # Собираем все 4 приоритета один раз (дешевле, чем на каждый шаг).
    var strategic_points := _collect_strategic_attraction_points(tile_data, rows, cols)
    var river_points := _collect_river_attraction_points(tile_data, rows, cols)
    var sea_points := _collect_sea_coast_attraction_points(tile_data, rows, cols)
    var lake_points := _collect_lake_coast_attraction_points(tile_data, rows, cols)
    var tiers: Array = [strategic_points, river_points, sea_points, lake_points]
    var tier_names: Array = ["strategic", "river", "sea_coast", "lake_coast"]

    # Первый непустой приоритет — «основной». С него стартуем каскад.
    var primary_idx := -1
    for i in range(tiers.size()):
        if not tiers[i].is_empty():
            primary_idx = i
            break
    if primary_idx == -1:
        return {}

    # Шаг 1: ищем валидный гекс рядом с любой точкой основного приоритета.
    var best: Dictionary = _find_hex_near_tier(tile_data, rows, cols,
            tiers[primary_idx], city_row, city_col,
            exclusion_start_row, exclusion_end_row,
            exclusion_start_col, exclusion_end_col,
            require_in_region_start_row, require_in_region_end_row,
            require_in_region_start_col, require_in_region_end_col,
            ignore_exclusion)
    if best.is_empty():
        return {}

    # Список приоритетов, которые «заработаны» (текущий гекс лежит в
    # радиусе 3 хотя бы от одной точки каждого из них). На каждом шаге
    # уточнения новый приоритет добавляется в этот список.
    var satisfied_tiers: Array = [tiers[primary_idx]]
    var satisfied_names: Array = [tier_names[primary_idx]]

    # Шаги 2..N: для каждого следующего непустого приоритета пытаемся
    # уточнить позицию так, чтобы гекс одновременно лежал в радиусе 3 от
    # всех ранее заработанных приоритетов И от нового.
    for tier_idx in range(primary_idx + 1, tiers.size()):
        if tiers[tier_idx].is_empty():
            continue
        var new_points: Array = satisfied_tiers + [tiers[tier_idx]]
        var refined: Dictionary = _find_hex_in_radius_satisfying(tile_data, rows, cols,
                best, REFINEMENT_RADIUS, new_points,
                city_row, city_col,
                exclusion_start_row, exclusion_end_row,
                exclusion_start_col, exclusion_end_col,
                require_in_region_start_row, require_in_region_end_row,
                require_in_region_start_col, require_in_region_end_col,
                ignore_exclusion)
        if not refined.is_empty():
            best = refined
            satisfied_tiers.append(tiers[tier_idx])
            satisfied_names.append(tier_names[tier_idx])

    if satisfied_names.size() > 1:
        print("town_manager: городок (", best.row, ",", best.col, ") — каскад ",
                "приоритетов: ", ", ".join(satisfied_names))
    return best


# Ищет валидный гекс городка в радиусе MAX_ATTRACTION_DISTANCE от ЛЮБОЙ
# точки attraction_points. Никаких ограничений «near_hex» — это первичный
# поиск, не уточнение. Возвращает {row, col} или {} если ничего не нашлось.
func _find_hex_near_tier(tile_data: Array, rows: int, cols: int,
        attraction_points: Array,
        city_row: int, city_col: int,
        exclusion_start_row: int, exclusion_end_row: int,
        exclusion_start_col: int, exclusion_end_col: int,
        require_in_region_start_row: int, require_in_region_end_row: int,
        require_in_region_start_col: int, require_in_region_end_col: int,
        ignore_exclusion: bool) -> Dictionary:
    var points: Array = attraction_points.duplicate()
    points.shuffle()
    for _attempt in range(MAX_TOWN_PLACEMENT_ATTEMPTS):
        if points.is_empty():
            return {}
        var pick_idx: int = randi() % points.size()
        var anchor: Dictionary = points[pick_idx]
        # Случайный валидный гекс в квадрате 7x7 вокруг anchor, отфильтрованный
        # по гекс-расстоянию <= MAX_ATTRACTION_DISTANCE.
        var candidates: Array = []
        var r_min: int = maxi(0, anchor.row - MAX_ATTRACTION_DISTANCE)
        var r_max: int = mini(rows - 1, anchor.row + MAX_ATTRACTION_DISTANCE)
        var c_min: int = maxi(0, anchor.col - MAX_ATTRACTION_DISTANCE)
        var c_max: int = mini(cols - 1, anchor.col + MAX_ATTRACTION_DISTANCE)
        for r in range(r_min, r_max + 1):
            for c in range(c_min, c_max + 1):
                if HexUtils.hex_distance(r, c, anchor.row, anchor.col) > MAX_ATTRACTION_DISTANCE:
                    continue
                if not _is_valid_town_hex(tile_data, r, c, city_row, city_col,
                        exclusion_start_row, exclusion_end_row,
                        exclusion_start_col, exclusion_end_col,
                        require_in_region_start_row, require_in_region_end_row,
                        require_in_region_start_col, require_in_region_end_col,
                        ignore_exclusion):
                    continue
                candidates.append({"row": r, "col": c})
        if not candidates.is_empty():
            return candidates[randi() % candidates.size()]
        # Возле этой опорной точки ничего не нашлось — удаляем её и пробуем
        # следующую точку того же приоритета.
        points.remove_at(pick_idx)
    return {}


# Ищет валидный гекс городка в радиусе max_dist_from_near от near_hex
# (для уточнения на следующем приоритете), который одновременно лежит
# в радиусе MAX_ATTRACTION_DISTANCE хотя бы от одной точки КАЖДОГО из
# attraction_point_sets (накопленные приоритеты + новый).
# Возвращает {row, col} или {} если ничего не нашлось.
func _find_hex_in_radius_satisfying(tile_data: Array, rows: int, cols: int,
        near_hex: Dictionary, max_dist_from_near: int,
        attraction_point_sets: Array,
        city_row: int, city_col: int,
        exclusion_start_row: int, exclusion_end_row: int,
        exclusion_start_col: int, exclusion_end_col: int,
        require_in_region_start_row: int, require_in_region_end_row: int,
        require_in_region_start_col: int, require_in_region_end_col: int,
        ignore_exclusion: bool) -> Dictionary:
    var candidates: Array = []
    var r_min: int = maxi(0, near_hex.row - max_dist_from_near)
    var r_max: int = mini(rows - 1, near_hex.row + max_dist_from_near)
    var c_min: int = maxi(0, near_hex.col - max_dist_from_near)
    var c_max: int = mini(cols - 1, near_hex.col + max_dist_from_near)
    for r in range(r_min, r_max + 1):
        for c in range(c_min, c_max + 1):
            if HexUtils.hex_distance(r, c, near_hex.row, near_hex.col) > max_dist_from_near:
                continue
            # Гекс должен быть в радиусе 3 хотя бы от одной точки КАЖДОГО
            # набора приоритетов. Это «AND» по наборам, «OR» внутри набора.
            var all_satisfied: bool = true
            for points in attraction_point_sets:
                var any_close: bool = false
                for p in points:
                    if HexUtils.hex_distance(r, c, p.row, p.col) <= MAX_ATTRACTION_DISTANCE:
                        any_close = true
                        break
                if not any_close:
                    all_satisfied = false
                    break
            if not all_satisfied:
                continue
            if not _is_valid_town_hex(tile_data, r, c, city_row, city_col,
                    exclusion_start_row, exclusion_end_row,
                    exclusion_start_col, exclusion_end_col,
                    require_in_region_start_row, require_in_region_end_row,
                    require_in_region_start_col, require_in_region_end_col,
                    ignore_exclusion):
                continue
            candidates.append({"row": r, "col": c})
    if candidates.is_empty():
        return {}
    return candidates[randi() % candidates.size()]


# Проверяет, подходит ли гекс (row, col) для размещения городка.
# Аргументы exclude_* — прямоугольник «нельзя ставить» (стартовая область);
# require_in_region_* — прямоугольник «обязательно должно лежать в» (для
# гарантии эры-2). Если exclude задан как start>end — пропускается.
# Аналогично для require_in_region: -1 — ограничение отключено.
# ignore_exclusion=true пропускает проверку exclude (для аварийных случаев,
# сейчас не используется, оставлен «на будущее»).
func _is_valid_town_hex(tile_data: Array, row: int, col: int,
        city_row: int, city_col: int,
        exclusion_start_row: int, exclusion_end_row: int,
        exclusion_start_col: int, exclusion_end_col: int,
        require_in_region_start_row: int, require_in_region_end_row: int,
        require_in_region_start_col: int, require_in_region_end_col: int,
        ignore_exclusion: bool) -> bool:
    if row < 0 or row >= tile_data.size():
        return false
    if col < 0 or col >= tile_data[row].size():
        return false
    var tile = tile_data[row][col]
    if tile == null:
        return false

    # Гекс города игрока — никогда.
    if row == city_row and col == city_col:
        return false

    var terrain: String = tile.get("terrain", "plain")
    # Непроходимые типы местности (море, озёра, содовое/соляное/асфальтовое
    # озеро) — городок там не поставишь.
    if _is_impassable_terrain(terrain):
        return false
    # Пляж — «на самом краю воды», там логично не селиться.
    if terrain == "beach":
        return false

    # Уже есть постройка (от другой системы) — нельзя.
    if tile.get("improvement", null) != null:
        return false
    # Уже стоит городок (на всякий случай — флаг мог остаться).
    if tile.get("has_town", false):
        return false

    # Стартовая область (Кольцо + стартовый Регион) — нельзя. Иначе
    # городок был бы виден с самого начала, и теряется смысл «маленьких
    # неизвестных поселений на краю».
    if not ignore_exclusion \
            and exclusion_start_row <= exclusion_end_row \
            and exclusion_start_col <= exclusion_end_col \
            and row >= exclusion_start_row and row <= exclusion_end_row \
            and col >= exclusion_start_col and col <= exclusion_end_col:
        return false

    # Обязательная зона (если задана) — гекс должен лежать внутри неё.
    if require_in_region_start_row >= 0 and require_in_region_end_row >= 0 \
            and require_in_region_start_col >= 0 and require_in_region_end_col >= 0:
        if not (row >= require_in_region_start_row and row <= require_in_region_end_row \
                and col >= require_in_region_start_col and col <= require_in_region_end_col):
            return false

    # Слишком близко к другому городку — не рассредоточено.
    for h in town_hexes:
        if HexUtils.hex_distance(row, col, h.row, h.col) < MIN_DISTANCE_BETWEEN_TOWNS:
            return false
    return true


func _is_impassable_terrain(terrain_id: String) -> bool:
    var t: Dictionary = GameData.terrains.get(terrain_id, {})
    return int(t.get("move_cost", 1)) >= 999


# --- Сбор точек тяготения по приоритетам ---

# Приоритет 1: гексы со стратегическими ресурсами (resource.strategic == true).
func _collect_strategic_attraction_points(tile_data: Array, rows: int, cols: int) -> Array:
    var result: Array = []
    for r in range(rows):
        for c in range(cols):
            var res = tile_data[r][c].get("resource", null)
            if res == null or res == "":
                continue
            var res_data: Dictionary = GameData.raw_resources.get(res, {})
            if bool(res_data.get("strategic", false)):
                result.append({"row": r, "col": c})
    return result


# Приоритет 2: гексы, через которые текут реки (river_edges непустой).
func _collect_river_attraction_points(tile_data: Array, rows: int, cols: int) -> Array:
    var result: Array = []
    for r in range(rows):
        for c in range(cols):
            var edges: Array = tile_data[r][c].get("river_edges", [])
            if edges.size() > 0:
                result.append({"row": r, "col": c})
    return result


# Приоритет 3: морское побережье. Пляжные гексы — это суша рядом с морем
# (см. SeaManager._apply_beach), ровно то, что нам нужно.
func _collect_sea_coast_attraction_points(tile_data: Array, rows: int, cols: int) -> Array:
    var result: Array = []
    for r in range(rows):
        for c in range(cols):
            if tile_data[r][c].get("terrain", "") == "beach":
                result.append({"row": r, "col": c})
    return result


# Приоритет 4: побережье озёр. Озёра окружены сушей, и нам нужны именно
# сухопутные гексы, соседние с озером. Каждый подходящий гекс добавляется
# один раз (через seen).
func _collect_lake_coast_attraction_points(tile_data: Array, rows: int, cols: int) -> Array:
    var result: Array = []
    var seen := {}
    for r in range(rows):
        for c in range(cols):
            if tile_data[r][c].get("terrain", "") != "lake":
                continue
            for n in HexUtils.get_neighbors_odd_r(r, c, rows, cols):
                var n_tile = tile_data[n.row][n.col]
                if n_tile == null:
                    continue
                if n_tile.get("terrain", "") == "lake":
                    continue
                if _is_impassable_terrain(n_tile.get("terrain", "")):
                    continue
                var key := "%d,%d" % [n.row, n.col]
                if seen.has(key):
                    continue
                seen[key] = true
                result.append({"row": n.row, "col": n.col})
    return result


# --- Сейв/лоад ---
# Формат сериализации: [[row, col], [row, col], ...] — компактнее, чем
# словари, и совместимо с JSON без лишних телодвижений.

func serialize_towns() -> Array:
    var result: Array = []
    for h in town_hexes:
        result.append([int(h.row), int(h.col)])
    return result


# Восстанавливает town_hexes из сейва. Если данных нет (новая игра) —
# оставляет текущее значение town_hexes (обычно уже заполненное
# generate_towns, вызванным из _initialize_map).
func load_towns(data) -> void:
    if data == null:
        return
    if not (data is Array):
        return
    if data.is_empty():
        return
    town_hexes = []
    for entry in data:
        if entry is Array and entry.size() >= 2:
            town_hexes.append({"row": int(entry[0]), "col": int(entry[1])})
