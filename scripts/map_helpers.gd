class_name MapHelpers

## Возвращает фактическую стоимость труда для постройки улучшения imp_id на гексе (row, col).
## Стоимость зависит от базового work_cost улучшения, типа местности (move_cost) и
## расстояния от города. Возвращает словарь с итоговой стоимостью и деталями расчёта
## (для расширенного тултипа).
static func get_improvement_work_cost(
    imp_id: String,
    row: int,
    col: int,
    tile_data: Array,
    city_row: int,
    city_col: int
) -> Dictionary:
    # Спец-действия не являются улучшениями — используем их базовую стоимость из данных.
    var base_cost := 0.0
    if GameData.special_actions.has(imp_id):
        base_cost = float(GameData.special_actions[imp_id].get("work_cost", 0))
    else:
        var imp_data: Dictionary = GameData.improvements.get(imp_id, {})
        base_cost = float(imp_data.get("work_cost", 0))

    # Множитель от типа местности: чем выше move_cost, тем труднее строить.
    var terrain_id := "plain"
    if row >= 0 and row < tile_data.size() and col >= 0 and col < tile_data[row].size():
        terrain_id = tile_data[row][col].get("terrain", "plain")

    var move_cost := 1.0
    if GameData.terrains.has(terrain_id):
        move_cost = float(GameData.terrains[terrain_id].get("move_cost", 1))

    # Множитель сложности строительства. Если у террейна явно задан
    # work_cost_mult (например, у озёр с move_cost=999, где move_cost означает
    # «непроходимо» для юнитов, а не сложность стройки), используем его.
    # Иначе считаем по формуле на основе move_cost.
    var terrain_mult := 1.0 + (move_cost - 1.0) * 0.35
    if GameData.terrains.has(terrain_id):
        var work_cost_mult_override: float = GameData.terrains[terrain_id].get("work_cost_mult", -1.0)
        if work_cost_mult_override >= 0.0:
            terrain_mult = float(work_cost_mult_override)

    # Множитель от расстояния до города (в гексах).
    var distance := HexUtils.hex_distance(row, col, city_row, city_col)

    # Тех-модификаторы, влияющие на вклад расстояния в стоимость труда
    # (например, «Колесо» снижает его на 30%). См. data/modifiers.json,
    # блок "tech_modifiers", target = "improvement_distance_cost".
    var distance_tech_mult := 1.0
    for tm in GameData.modifiers.get("tech_modifiers", []):
        var tech_id = tm.get("tech_id", "")
        if tech_id == "" or not CityData.is_tech_unlocked(tech_id):
            continue
        for mod in tm.get("modifiers", []):
            if mod.get("target", "") != "improvement_distance_cost":
                continue
            var value = float(mod.get("value", 0))
            distance_tech_mult *= 1.0 + value / 100.0

    # Исходный множитель расстояния (без влияния технологий) и итоговый с учётом тех-модификаторов.
    var distance_mult_base := 1.0 + float(distance) * 0.25
    var distance_mult := 1.0 + float(distance) * 0.25 * distance_tech_mult

    var final_cost := int(ceil(base_cost * terrain_mult * distance_mult))

    return {
        "cost": final_cost,
        "base_cost": int(base_cost),
        "terrain_id": terrain_id,
        "terrain_name": GameData.terrains.get(terrain_id, {}).get("name", terrain_id),
        "move_cost": move_cost,
        "terrain_mult": terrain_mult,
        "distance": distance,
        "distance_mult_base": distance_mult_base,
        "distance_tech_mult": distance_tech_mult,
        "distance_mult": distance_mult
    }

## Возвращает индекс ребра гекса (row, col), которое является общим с
## соседом (neighbor_row, neighbor_col). Используется для проверки, касается ли река
## именно общего ребра между двумя гексами (например, при постройке канала).
##
## Гексы ориентированы точкой вверх (pointy-top), индексы рёбер (0..5) идут
## по часовой стрелке начиная с нижне-правого:
##   0 — нижне-правое, 1 — нижне-левое, 2 — левое,
##   3 — верхне-левое,  4 — верхне-правое, 5 — правое.
## Для pointy-top с offset odd-r соседи W/E дают рёбра 2/5, верхняя/нижняя
## диагонали (NW,NE,SW,SE) — рёбра 3,4,1,0 соответственно; направление
## определяется ГЕОМЕТРИЧЕСКИ (куда смещён сосед), а не именем в directions[].
##
## Возвращает -1, если (neighbor_row, neighbor_col) НЕ является соседом по
## сетке (например, в odd-r для чётной строки невалиден оффсет (-1, +1)).
static func get_shared_edge_index(row: int, col: int, neighbor_row: int, neighbor_col: int) -> int:
    var dr = neighbor_row - row
    var dc = neighbor_col - col
    if dr == 0 and dc == -1:
        return 2  # W
    if dr == 0 and dc == 1:
        return 5  # E
    var is_odd = (row % 2) == 1
    if dr == -1:
        # Верхний ряд: для чётной строки валидны dc=-1 (NW) и dc=0 (N),
        # для нечётной — dc=0 (N) и dc=+1 (NE). Остальные dc — не соседи.
        if is_odd:
            if dc == 0: return 3
            if dc == 1: return 4
        else:
            if dc == -1: return 3
            if dc == 0: return 4
        return -1
    if dr == 1:
        # Нижний ряд: для чётной строки валидны dc=-1 (SW) и dc=0 (S),
        # для нечётной — dc=0 (S) и dc=+1 (SE). Остальные dc — не соседи.
        if is_odd:
            if dc == 0: return 1
            if dc == 1: return 0
        else:
            if dc == -1: return 1
            if dc == 0: return 0
        return -1
    return -1

static func get_water_chain_length() -> int:
    var best := 0
    for tm in GameData.modifiers.get("tech_modifiers", []):
        if not (tm is Dictionary):
            continue
        var tech_id = tm.get("tech_id", "")
        if tech_id == "" or not CityData.is_tech_unlocked(tech_id):
            continue
        for mod in tm.get("modifiers", []):
            if not (mod is Dictionary):
                continue
            if mod.get("target", "") != "water_chain_length":
                continue
            var v = int(mod.get("value", 0))
            if v > best:
                best = v
    return best


## Будет ли у канала, построенного на гексе (row, col), доступ к
## пресной воде. Использует get_hex_water_access с phantom_conductor=true
## (BFS рассматривает гекс как проводник канала и ищет
## путь к прямому источнику — озеру или реке — через
## цепочку существующих проводников в пределах
## chain_length (irrigation=3, canals=4). Не зависит от технологии «Каналы».
## Используется в can_build_canal и в control_panel.gd.
static func would_canal_have_water(row: int, col: int, tile_data: Array, map_rows: int, map_cols: int) -> bool:
    return get_hex_water_access(row, col, tile_data, map_rows, map_cols, true) != ""

static func can_build_canal(row: int, col: int, tile_data: Array, map_rows: int, map_cols: int) -> Dictionary:
    if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
        return {"ok": false, "reason": "Гекс вне карты"}
    var tile = tile_data[row][col]
    if tile == null:
        return {"ok": false, "reason": "Гекс не существует"}
    if not tile.get("in_influence", false):
        return {"ok": false, "reason": "Гекс вне Кольца Влияния"}
    if tile.get("has_town", false):
        return {"ok": false, "reason": "Здесь стоит чужой городок"}
    if tile.get("improvement", null) != null:
        return {"ok": false, "reason": "Гекс уже занят улучшением"}
    if tile.get("resource", null) != null or tile.get("crop_bred", null) != null:
        return {"ok": false, "reason": "Гекс не пуст"}
    var terrain_id: String = tile.get("terrain", "plain")
    if is_water_terrain(terrain_id):
        return {"ok": false, "reason": "Нельзя строить на воде"}
    if terrain_id == "mountain":
        return {"ok": false, "reason": "Нельзя строить в горах"}
    if terrain_id == "swamp" or terrain_id == "marsh":
        return {"ok": false, "reason": "Нельзя строить на болоте/маршах"}
    # Запрет «непроходимых» кастомных террейнов: move_cost >= 999 — это уже
    # вода по move_cost-логике (is_water_terrain ловит sea/lake, но кастомные
    # озёра вроде asphalt_lake/salt_lake/soda_lake тоже непройдут по нему).
    var t_data: Dictionary = GameData.terrains.get(terrain_id, {})
    if int(t_data.get("move_cost", 1)) >= 999:
        return {"ok": false, "reason": "Нельзя строить на непроходимой местности"}
    if not CityData.is_improvement_unlocked("irrigation_canal"):
        return {"ok": false, "reason": "Нужна технология «Каналы»"}
    if not would_canal_have_water(row, col, tile_data, map_rows, map_cols):
        return {"ok": false, "reason": "Нет доступа к воде в зоне досягаемости цепочки (irrigation/canals: 3/4 хопа от реки/озера)"}
    return {"ok": true, "reason": ""}


## Является ли гекс (row, col) ПРЯМЫМ источником пресной воды:
## ТОЛЬКО сам гекс с водой — озеро (terrain == "lake") или река
## (river_edges на общих рёбрах). Никаких "сосед канала", "сосед озера",
## "сам канал" — передача воды в любую сторону идёт
## через chain-BFS и подчиняется лимиту дальности (irrigation/canals).
## Это база для схемы water_access: source-гекс (озеро/река) даёт
## "direct", всё остальное — "chain" или "".
static func _is_direct_water_source(row: int, col: int, tile_data: Array, map_rows: int, map_cols: int) -> bool:
    if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
        return false
    var tile = tile_data[row][col]
    if tile == null:
        return false
    if tile.get("terrain", "plain") == "lake":
        return true
    if tile.get("river_edges", []).size() > 0:
        return true
    return false


## Является ли гекс «проводником» пресной воды: у его улучшения стоит
## conducts_water = true (ферма, плантация), или это канал (is_canal),
## или гекс города, к которому реально подведена вода. Такие гексы способны
## распространять воду по цепочке (схема water_access: chain).
static func _is_water_conductor(
    row: int,
    col: int,
    tile_data: Array,
    map_rows: int,
    map_cols: int
) -> bool:
    if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
        return false
    var tile = tile_data[row][col]
    if tile == null:
        return false
    # City hex conducts water like a canal when it has water.
    if bool(tile.get("is_city", false)):
        return true
    var imp_id = tile.get("improvement", null)
    if imp_id == null or imp_id == "":
        return false
    var imp_data: Dictionary = GameData.improvements.get(imp_id, {})
    return bool(imp_data.get("conducts_water", false) or imp_data.get("is_canal", false))


## Возвращает тип доступа гекса (row, col) к пресной воде:
##   - "direct" — прямой доступ (озеро, река, канал-сосед, сосед-озеро);
##   - "chain"  — доступ через цепочку проводников (ферм/плантаций/каналов),
##                который срабатывает ТОЛЬКО после изучения технологии
##                «Орошение» (tech_id: "irrigation");
##   - ""       — доступа к пресной воде нет.
##
## ПРАВИЛА ЦЕПОЧКИ: вода передаётся ТОЛЬКО между проводниками (фермами/
## плантациями/каналами). Каждое промежуточное звено цепочки обязано быть
## проводником, а завершается цепочка проводником, у которого есть прямой
## доступ к воде. Пустые береговые гексы рек и озёр воду НЕ передают: раньше
## BFS «замыкался» на любом соседе, числящемся прямым источником (в т.ч. пустом
## берегу реки, где река течёт по ДРУГОМУ ребру), из-за чего ферма рядом с
## рекой, не касаясь речного ребра и без соседей-проводников, ошибочно
## получала бонус "по цепочке".
## Функция — единый источник истины для бонусов пресной воды, тултипов и
## отрисовки капелек. Длина цепочки берётся динамически из tech_modifiers
## (см. get_water_chain_length): «Ирригация» = 3, «Каналы» = 4. Без
## изученных технологий длина = 0 и цепочка не работает.
static func get_hex_water_access(
    row: int,
    col: int,
    tile_data: Array,
    map_rows: int,
    map_cols: int,
    phantom_conductor: bool = false
) -> String:
    if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
        return ""
    var tile = tile_data[row][col]
    if tile == null:
        return ""

    # Прямой доступ — только гекс с водой (озеро/река).
    if _is_direct_water_source(row, col, tile_data, map_rows, map_cols):
        return "direct"

    # Цепочка проводников: длина берётся из модификаторов технологий
    # (irrigation/canals). Без изученного «Орошения» длина = 0 и цепочка
    # не работает; phantom_conductor=true используется только валидацией
    # постройки канала (гекс ещё не имеет улучшения, но если бы канал
    # был построен, считалось бы, что он проводник).
    var chain_length = get_water_chain_length()
    if chain_length <= 0:
        return ""
    # Стартовый гекс кандидат, если он:
    #   - улучшение-проводник (farm/plantation/canal) — обычно;
    #   - phantom_conductor=true — валидация постройки канала (гекс ещё не имеет
    #     улучшения, но если бы канал был построен, считалось бы что он проводник);
    #   - city hex is a conductor like a canal: passes water onward
    #     when water is actually supplied (a source reachable through it).
    var start_tile = tile_data[row][col]
    var start_is_candidate = phantom_conductor \
            or _is_water_conductor(row, col, tile_data, map_rows, map_cols) \
            or bool(start_tile.get("is_city", false))
    if not start_is_candidate:
        return ""

    var visited := {}
    var queue = [ {"row": row, "col": col, "dist": 0} ]
    visited["%d_%d" % [row, col]] = true

    while queue.size() > 0:
        var item = queue.pop_front()
        var crow: int = item.row
        var ccol: int = item.col
        var dist: int = item.dist
        if dist >= chain_length:
            continue

        var neighbors_local = HexUtils.get_neighbors_odd_r(crow, ccol, map_rows, map_cols)
        for n in neighbors_local:
            var key = "%d_%d" % [n.row, n.col]
            if visited.has(key):
                continue
            var neighbor_tile = tile_data[n.row][n.col]
            if neighbor_tile == null:
                continue
            # Прямой источник — озеро (всегда) или река по ОБЩЕМУ ребру
            # (река должна течь именно по грани между текущим гексом и соседом;
            # река на «чужом» ребре соседа не даёт воду текущему гексу).
            if neighbor_tile.get("terrain", "") == "lake":
                return "chain"
            var n_edges: Array = neighbor_tile.get("river_edges", [])
            if n_edges.size() > 0:
                var shared_in_neighbor = get_shared_edge_index(n.row, n.col, crow, ccol)
                if shared_in_neighbor >= 0 and shared_in_neighbor in n_edges:
                    return "chain"
                # Река на другом ребре — не источник для текущего гекса,
                # но сосед всё ещё может быть проводником (ферма/канал/...).
            # City hex conducts water like a canal when it has water.
            if not _is_water_conductor(n.row, n.col, tile_data, map_rows, map_cols):
                continue
            visited[key] = true
            queue.append({"row": n.row, "col": n.col, "dist": dist + 1})
    return ""


## Проверяет, орошен ли гекс (row, col): имеет какой-либо доступ к пресной
## воде — прямой ("direct") или по цепочке ("chain"). Это обёртка над
## get_hex_water_access для совместимости: все прежние вызовы
## (бонусы производства, тултипы, отрисовка) продолжают работать.
static func is_hex_irrigated(row: int, col: int, tile_data: Array, map_rows: int, map_cols: int) -> bool:
    return get_hex_water_access(row, col, tile_data, map_rows, map_cols) != ""

## Возвращает имя иконки ландшафта для гекса (row, col) на основе его terrain.
## Использует детерминированный RNG (seed = row * 1000 + col) для стабильности
## между сохранениями/загрузками.
static func get_terrain_icon(row: int, col: int, tile_data: Array) -> String:
    var tile = tile_data[row][col]
    var terrain_id: String = tile.get("terrain", "plain")
    if not GameData.terrains.has(terrain_id):
        return ""
    var t: Dictionary = GameData.terrains[terrain_id]
    if t.has("icons"):
        var icons_array: Array = t.icons
        if icons_array.size() > 0:
            var icon_rng = RandomNumberGenerator.new()
            icon_rng.seed = row * 1000 + col
            var idx = icon_rng.randi() % icons_array.size()
            return icons_array[idx]
    elif t.has("icon"):
        return t.icon
    return ""


## Возвращает «эффективный» ресурс гекса: либо природный ресурс (tile.resource,
## заданный генератором карты или спавном по технологии), либо разводимый
## (tile.crop_bred, выставленный при постройке пастбища/фермы/пасеки на пустом
## гексе). Если оба поля пустые — возвращает пустую строку.
##
## Используется во всей игре: производство, тултипы, отрисовка, прогресс-бары
## исследования, наследование качества. Эти подсистемы должны «не знать»,
## природный ресурс на гексе или разводимый — им нужен только id.
static func get_effective_resource(tile: Dictionary) -> String:
    var r = tile.get("resource", null)
    if r != null and r != "":
        return r
    var b = tile.get("crop_bred", null)
    if b != null and b != "":
        return b
    return ""

## --- Разведение одомашненных видов (схема crop_bred) ---
## Разводить можно НЕ всех одомашненных видов: водные ресурсы (рыба и т.п.)
## живут только в своих водоёмах — поле tile.crop_bred для них не используется.
## Возможность разведения задаёт в JSON ресурса (data/resources/*.json) поле
## breedable; при отсутствии поля считается true. Проверка нужна во всех местах,
## где формируются варианты разведения на пустом гексе (пастбище/ферма).
static func can_breed_resource(res_id: String) -> bool:
    var raw = GameData.raw_resources.get(res_id, {})
    return bool(raw.get("breedable", true))

## --- Заполненность поголовья (time_to_mature) ---
## Ресурсы с time_to_mature > 0 (животные на пастбищах) набирают полную
## численность постепенно. Пока стадо не полное, выход ресурса пропорционален
## степени заполненности. Накопленное время хранится в tile.fill_time (сек).

## Возвращает true, если ресурс res_data «растущий» (есть time_to_mature > 0).
static func is_growing_resource(res_data: Dictionary) -> bool:
    return float(res_data.get("time_to_mature", 0)) > 0.0


## Степень заполненности стада: tile.fill_time / time_to_mature, зажатая в [0, 1].
## Для обычных (не растущих) ресурсов всегда 1.0 — выход не режется.
static func get_fill_fraction(tile: Dictionary, res_data: Dictionary) -> float:
    var ttm = float(res_data.get("time_to_mature", 0))
    if ttm <= 0.0:
        return 1.0
    return clampf(float(tile.get("fill_time", 0.0)) / ttm, 0.0, 1.0)


## Сколько секунд осталось до полного поголовья (0 — если уже полное).
static func get_time_to_full(tile: Dictionary, res_data: Dictionary) -> float:
    var ttm = float(res_data.get("time_to_mature", 0))
    if ttm <= 0.0:
        return 0.0
    return maxf(0.0, ttm - float(tile.get("fill_time", 0.0)))


## Ищет на карте уже одомашненный экземпляр ресурса res_id (гекс с этим ресурсом

## Ищет на карте уже одомашненный экземпляр ресурса res_id (гекс с этим ресурсом
## и построенным улучшением) и возвращает его качество.
## Поиск идёт по обоим полям — tile.resource (природный) и tile.crop_bred
## (разводимый): одомашненным считается любой гекс, где нужный ресурс уже
## обрабатывается улучшением.
## Если такого нет — возвращает пустую строку.
static func find_domesticated_quality(
    res_id: String,
    tile_data: Array,
    region_start_row: int,
    region_end_row: int,
    region_start_col: int,
    region_end_col: int
) -> String:
    for r in range(region_start_row, region_end_row + 1):
        for c in range(region_start_col, region_end_col + 1):
            var t = tile_data[r][c]
            if t.get("improvement") == null:
                continue
            var matches := false
            if t.get("resource", null) == res_id:
                matches = true
            elif t.get("crop_bred", null) == res_id:
                matches = true
            if not matches:
                continue
            var q = t.get("quality", "")
            if q != "" and q != null:
                return q
    return ""


## Проверяет, виден ли ресурс на гексе tile с точки зрения игрока.
## Учитывает:
##   1) in_influence / is_explored — гекс освоен или исследован;
##   2) tech_reveal ресурса — если он задан и технология не изучена, ресурс
##      скрыт даже в купленной зоне (см. docs.md, раздел «tech_reveal»).
## Возвращает true, если ресурс должен отображаться на карте и в тултипе.
## Если на гексе ничего нет (eff_res == "") — возвращает true по зоне:
## сам гекс может быть виден, а его «нет ресурса» — корректное отображение.
static func is_resource_revealed(tile: Dictionary) -> bool:
    var eff_res = get_effective_resource(tile)
    if eff_res != "":
        var res_data: Dictionary = GameData.raw_resources.get(eff_res, {})
        var reveal_tech: String = res_data.get("tech_reveal", "")
        if reveal_tech != "" and not CityData.is_tech_unlocked(reveal_tech):
            return false
    if tile.get("in_influence", false):
        return true
    return tile.get("is_explored", false)


## Возвращает информацию о конфликте «tech_reveal-ресурс под чужим улучшением»
## на гексе tile или {}, если конфликта нет.
##
## Конфликт есть, если выполнены ВСЕ условия:
##   - на гексе есть УЛУЧШЕНИЕ;
##   - на гексе есть природный ресурс с tech_reveal, чья технология уже изучена;
##   - стоящее улучшение НЕ соответствует improved_by этого ресурса.
## Дикоросы (improved_by == null) и уже-правильные улучшения (шахта на руде)
## конфликтом не считаются.
##
## Используется в map_renderer для отрисовки красного треугольника с «!» и
## в map_tooltip для соответствующего сообщения. Один источник истины.
##
## Формат результата:
##   { "res_id": ..., "res_name": ..., "improved_by": ..., "imp_name": ... }
static func get_tech_reveal_conflict(tile: Dictionary) -> Dictionary:
    if tile.get("improvement", null) == null:
        return {}
    var natural_res = tile.get("resource", null)
    if natural_res == null or natural_res == "":
        return {}
    var res_data: Dictionary = GameData.raw_resources.get(natural_res, {})
    if res_data.is_empty():
        return {}
    var reveal_tech: String = res_data.get("tech_reveal", "")
    if reveal_tech == "" or not CityData.is_tech_unlocked(reveal_tech):
        return {}
    var expected_imp: String = res_data.get("improved_by", "")
    if expected_imp == null or expected_imp == "":
        return {}
    if tile.get("improvement") == expected_imp:
        return {}
    var imp_name: String = GameData.improvements.get(expected_imp, {}).get("name", expected_imp)
    return {
        "res_id": natural_res,
        "res_name": res_data.get("name", natural_res),
        "improved_by": expected_imp,
        "imp_name": imp_name
    }


## Гарантирует, что город находится на разрешённой местности (равнина или холмы).
## Если город был сгенерирован/загружен на горе, озере, море или пляже —
## меняет на равнину.
static func ensure_city_valid_terrain(
    tile_data: Array,
    city_row: int,
    city_col: int,
    map_rows: int,
    map_cols: int
) -> void:
    if city_row < 0 or city_row >= map_rows or city_col < 0 or city_col >= map_cols:
        return
    var city_tile = tile_data[city_row][city_col]
    var current_terrain: String = city_tile.get("terrain", "plain")
    var allowed_terrains: Array[String] = ["plain", "hill"]
    if current_terrain not in allowed_terrains:
        city_tile["terrain"] = "plain"
        city_tile["cover"] = "none"
        city_tile["_is_sea"] = false
        city_tile["_is_beach"] = false
        city_tile["_is_marsh"] = false

## Хит-тест: какой гекс (row, col) находится под пиксельными координатами (mx, my).
## Итерирует только видимое окно (Кольцо + Регион) для производительности.
static func pixel_to_hex(
    mx: float, my: float,
    region_start_row: int, region_end_row: int,
    region_start_col: int, region_end_col: int,
    offset_x: float, offset_y: float,
    scroll_offset: Vector2,
    hex_radius: float
):
    for row in range(region_start_row, region_end_row + 1):
        for col in range(region_start_col, region_end_col + 1):
            var center = HexUtils.hex_center(row, col, hex_radius)
            center.x += offset_x + scroll_offset.x
            center.y += offset_y + scroll_offset.y
            var verts = HexUtils.hex_vertices(center.x, center.y, hex_radius)
            if HexUtils.point_in_polygon(mx, my, verts):
                return {"row": row, "col": col}
    return null

## Возвращает id улучшения, которое можно построить на гексе,
## или пустую строку, если постройка невозможна.
static func get_buildable_improvement(tile: Dictionary) -> String:
    if tile.improvement != null:
        return ""

    # Скрытый ресурс (tech_reveal не изучен): никакой подсказки о постройке —
    # иначе игрок узнал бы, что на гексе что-то есть.
    if tile.resource != null and not is_resource_revealed(tile):
        return ""

    if tile.resource != null:
        var raw: Dictionary = GameData.raw_resources.get(tile.resource, {})
        if "improved_by" in raw and raw.improved_by != null and raw.improved_by != "":
            var imp_id: String = raw.improved_by
            if CityData.is_improvement_unlocked(imp_id):
                return imp_id
        return ""

    # Пустой гекс: пастбище или ферма из одомашненных видов.
    var tile_cover: String = tile.get("cover", "none")
    if CityData.domesticated_animals.size() > 0 and CityData.is_improvement_unlocked("pasture"):
        for animal_id in CityData.domesticated_animals:
            var animal_data: Dictionary = GameData.raw_resources.get(animal_id, {})
            # breedable: false (напр. водные ресурсы) — разведение недоступно.
            if not can_breed_resource(animal_id):
                continue
            if tile.terrain in animal_data.get("allowed_terrain", []) and tile_cover in animal_data.get("allowed_cover", []):
                return "pasture"
    if CityData.domesticated_plants.size() > 0 and CityData.is_improvement_unlocked("farm"):
        for plant_id in CityData.domesticated_plants:
            var plant_data: Dictionary = GameData.raw_resources.get(plant_id, {})
            # breedable: false (напр. водные ресурсы) — разведение недоступно.
            if not can_breed_resource(plant_id):
                continue
            if tile.terrain in plant_data.get("allowed_terrain", []) and tile_cover in plant_data.get("allowed_cover", []):
                return "farm"
    return ""


## Формирует строку описания чанка после разведки.
static func get_chunk_info(chunk: Array, tile_data: Array) -> String:
    var terrain_types := {}
    var cover_forests := false
    var resources := []
    for hex in chunk:
        var tile = tile_data[hex.row][hex.col]
        var terrain: String = tile.get("terrain", "plain")
        terrain_types[terrain] = terrain_types.get(terrain, 0) + 1
        var cover_id: String = tile.get("cover", "none")
        if cover_id != "none":
            cover_forests = true
        # Разведчики не опознают tech_reveal-ресурсы, пока соответствующая
        # технология не изучена. Это фича, не баг: скрытая руда под копытами
        # лошади — нормально, если игрок ещё не умеет отличать руду от камня.
        # is_resource_revealed учитывает оба условия (зона + tech_reveal).
        if is_resource_revealed(tile):
            var eff_res = get_effective_resource(tile)
            if eff_res != "":
                var res_name: String = GameData.raw_resources.get(eff_res, {}).get("name", eff_res)
                resources.append(res_name)

    var terrain_names: Array[String] = []
    for terrain_id in terrain_types.keys():
        terrain_names.append(GameData.terrains.get(terrain_id, {}).get("name", terrain_id))
    var terrain_str := ", ".join(terrain_names)
    if cover_forests:
        terrain_str += ", лес"
    var resource_str := ", ".join(resources) if resources.size() > 0 else "нет"
    return "Ландшафт: %s. Ресурсы: %s" % [terrain_str, resource_str]

## Пересчитывает абсолютные границы Кольца Влияния и видимого окна
## (Кольцо + Регион) вокруг города.
static func recalculate_bounds(
    city_row: int, city_col: int,
    ring_rows: int, ring_cols: int,
    region_rows: int, region_cols: int,
    map_rows: int, map_cols: int
) -> Dictionary:
    var influence_start_row = city_row - ring_rows / 2
    var influence_end_row = influence_start_row + ring_rows - 1
    var influence_start_col = city_col - ring_cols / 2
    var influence_end_col = influence_start_col + ring_cols - 1

    var region_start_row = city_row - region_rows / 2
    var region_end_row = region_start_row + region_rows - 1
    var region_start_col = city_col - region_cols / 2
    var region_end_col = region_start_col + region_cols - 1

    region_start_row = max(0, region_start_row)
    region_end_row = min(map_rows - 1, region_end_row)
    region_start_col = max(0, region_start_col)
    region_end_col = min(map_cols - 1, region_end_col)

    return {
        "influence_start_row": influence_start_row,
        "influence_end_row": influence_end_row,
        "influence_start_col": influence_start_col,
        "influence_end_col": influence_end_col,
        "region_start_row": region_start_row,
        "region_end_row": region_end_row,
        "region_start_col": region_start_col,
        "region_end_col": region_end_col,
    }


## Вычисляет offset_x/offset_y для центрирования видимого окна карты в viewport.
static func calc_offsets(
    region_start_row: int, region_end_row: int,
    region_start_col: int, region_end_col: int,
    hex_radius: float,
    viewport_size: Vector2
) -> Vector2:
    var min_x = INF
    var max_x = - INF
    var min_y = INF
    var max_y = - INF
    for row in range(region_start_row, region_end_row + 1):
        for col in range(region_start_col, region_end_col + 1):
            var center = HexUtils.hex_center(row, col, hex_radius)
            min_x = min(min_x, center.x - hex_radius)
            max_x = max(max_x, center.x + hex_radius)
            min_y = min(min_y, center.y - hex_radius)
            max_y = max(max_y, center.y + hex_radius)
    var grid_width = max_x - min_x
    var grid_height = max_y - min_y
    var offset_x = (viewport_size.x - grid_width) / 2.0 - min_x
    var offset_y = (viewport_size.y - grid_height) / 2.0 - min_y
    return Vector2(offset_x, offset_y)

## Гарантирует наличие хотя бы одного ресурса из food_plants в заданной области.
## Если нет — добавляет принудительно на подходящий пустой гекс.
## city_row / city_col (опционально) — координаты города: гекс города и его
## соседи (3×3) исключаются из поиска, чтобы ресурс не заспавнился на городе.
## Это согласуется с исключением в _build_hex_index / _place_resources.
static func ensure_food_plant(
    tile_data: Array,
    min_row: int, max_row: int,
    min_col: int, max_col: int,
    city_row: int = -1, city_col: int = -1
) -> void:
    for row in range(min_row, max_row + 1):
        for col in range(min_col, max_col + 1):
            if city_row >= 0 and abs(row - city_row) <= 1 and abs(col - city_col) <= 1:
                continue
            var res = tile_data[row][col]["resource"]
            if res != null:
                var res_data: Dictionary = GameData.raw_resources.get(res, {})
                if res_data.get("group") == "food_plants":
                    return
    var possible := []
    for row in range(min_row, max_row + 1):
        for col in range(min_col, max_col + 1):
            if city_row >= 0 and abs(row - city_row) <= 1 and abs(col - city_col) <= 1:
                continue
            if tile_data[row][col]["resource"] != null:
                continue
            var terrain: String = tile_data[row][col]["terrain"]
            var cover: String = tile_data[row][col].get("cover", "none")
            for res_id in GameData.raw_resources:
                var res: Dictionary = GameData.raw_resources[res_id]
                if res.get("group") != "food_plants":
                    continue
                if not (terrain in res.get("allowed_terrain", []) and cover in res.get("allowed_cover", [])):
                    continue
                var tech_required: String = res.get("tech_required", "")
                if tech_required != "" and not CityData.is_tech_unlocked(tech_required):
                    continue
                possible.append({"row": row, "col": col, "id": res_id})
    if possible.size() > 0:
        var chosen = possible[randi() % possible.size()]
        tile_data[chosen.row][chosen.col]["resource"] = chosen.id
        tile_data[chosen.row][chosen.col]["quality"] = GameData.roll_quality()


## Гарантирует наличие хотя бы одного ресурса, удовлетворяющего фильтру,
## в указанной прямоугольной области (например, стартовое «Кольцо + Регион»).
##
## `filter` — словарь с полями для матча по данным ресурса (все совпадения
## проверяются по равенству). Обязательно поле `category`. Поля `group`
## и `subgroup` — необязательные дополнительные фильтры для подробных
## категорий (бонусы за разнообразие). Примеры:
##
##   { "category": "metals" }                                          — любой металл
##   { "category": "animals", "group": "meat_animals" }                — мясные животные
##   { "category": "minerals", "subgroup": "construction_materials" }  — стройматериалы
##   { "category": "plants", "group": "food_plants" }                 — пищевые растения
##
## Поведение:
##   1. Если в области уже есть ресурс, удовлетворяющий фильтру — выходим.
##   2. Иначе выбираем **один** случайный id из доступных, удовлетворяющих
##      фильтру и spawn_conditions (шанс и геометрия). Не каждый тип сразу —
##      иначе добавление новых металлов/ископаемых в будущем превратилось бы
##      в обязательный спавн всех подходящих сразу.
##   3. Спавним его на подходящий пустой гекс с учётом allowed_terrain,
##      allowed_cover и геометрических spawn_conditions.
##
## Параметры `min_row..max_row` / `min_col..max_col` — инклюзивные границы.
## `city_row` / `city_col` — координаты города (на нём ресурс не ставим).
static func ensure_minimum_resource(
    tile_data: Array,
    filter: Dictionary,
    min_row: int, max_row: int,
    min_col: int, max_col: int,
    city_row: int = -1, city_col: int = -1
) -> void:
    var required_category: String = filter.get("category", "")
    if required_category == "":
        # Без категории фильтр бессмысленен — выходим без действий.
        return
    var required_group: String = filter.get("group", "")
    var required_subgroup: String = filter.get("subgroup", "")

    # Helper: данные ресурса подходят под фильтр?
    var matches_filter = func(rdata: Dictionary) -> bool:
        if rdata.get("category", "") != required_category:
            return false
        if required_group != "" and rdata.get("group", "") != required_group:
            return false
        if required_subgroup != "" and rdata.get("subgroup", "") != required_subgroup:
            return false
        return true

    # 1. Уже есть подходящий ресурс в области — ничего не делаем.
    for row in range(min_row, max_row + 1):
        for col in range(min_col, max_col + 1):
            if row < 0 or row >= tile_data.size():
                continue
            if col < 0 or col >= tile_data[row].size():
                continue
            var res = tile_data[row][col].get("resource", null)
            if res != null and GameData.raw_resources.has(res):
                if matches_filter.call(GameData.raw_resources[res]):
                    return

    # 2. Собираем id ресурсов, удовлетворяющих фильтру и spawn_conditions.
    #    Доступность = шанс в spawn_conditions выполнился.
    var candidates := []
    for res_id in GameData.raw_resources:
        var rdata: Dictionary = GameData.raw_resources[res_id]
        if not matches_filter.call(rdata):
            continue
        if not HexUtils.spawn_conditions_met(rdata):
            continue
        candidates.append(res_id)
    if candidates.is_empty():
        return
    var chosen_id: String = candidates[randi() % candidates.size()]
    var chosen_data: Dictionary = GameData.raw_resources[chosen_id]

    # 3. Ищем подходящий пустой гекс в границах.
    var allowed_terrain: Array = chosen_data.get("allowed_terrain", [])
    var allowed_cover: Array = chosen_data.get("allowed_cover", [])
    var possible := []
    for row in range(min_row, max_row + 1):
        for col in range(min_col, max_col + 1):
            if row < 0 or row >= tile_data.size():
                continue
            if col < 0 or col >= tile_data[row].size():
                continue
            if row == city_row and col == city_col:
                continue
            var t = tile_data[row][col]
            if t.get("resource", null) != null:
                continue
            if t.get("improvement", null) != null:
                continue
            var terrain_id: String = t.get("terrain", "plain")
            var cover_id: String = t.get("cover", "none")
            if not (terrain_id in allowed_terrain and cover_id in allowed_cover):
                continue
            # Геометрические условия spawn_conditions (например, «у реки»).
            if not HexUtils.is_hex_conditions_met(tile_data, row, col, chosen_data):
                continue
            possible.append({"row": row, "col": col})
    if possible.is_empty():
        return
    var hex = possible[randi() % possible.size()]
    tile_data[hex.row][hex.col]["resource"] = chosen_id
    tile_data[hex.row][hex.col]["quality"] = GameData.roll_quality()


## --- Водные ресурсы и пристани (схема harbor_access) ---
##
## Водные ресурсы (пресноводная и морская рыба) доступны для эксплуатации
## ТОЛЬКО после постройки улучшения «Пристань» (harbor, см. improvements.json,
## флаг water_body_harbor) на прибрежном гексе конкретного водоёма. Каждый
## водоём (связная область воды одного типа — lake или sea) требует СВОЮ
## пристань: доступ вычисляется flood-fill'ом (BFS) по воде от гекса ресурса.

# Типы местности, считающиеся водой для схемы harbor_access.
const WATER_TERRAINS := ["lake", "sea"]

## Является ли тип местности водным (озеро/море).
static func is_water_terrain(terrain_id: String) -> bool:
    return terrain_id in WATER_TERRAINS

## Есть ли у гекса (row, col) сосед-вода (lake/sea). Гекс сам может быть любым:
## проверка типа гекса — забота вызывающего кода.
static func is_coastal_hex(tile_data: Array, row: int, col: int, map_rows: int, map_cols: int) -> bool:
    if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
        return false
    for n in HexUtils.get_neighbors_odd_r(row, col, map_rows, map_cols):
        var nt = tile_data[n.row][n.col]
        if nt == null:
            continue
        if is_water_terrain(nt.get("terrain", "")):
            return true
    return false

## Есть ли у водного ресурса на гексе (row, col) доступ до пристани ЕГО водоёма.
## Логика: BFS/flood-fill от гекса ресурса по связным водным гексам ТОГО ЖЕ
## типа (озеро не соединяется с морем — это разные водоёмы). Если среди соседей
## любого посещённого водного гекса найдется суша с улучшением-пристанью
## (water_body_harbor == true в improvements.json) — путь есть, ресурс доступен.
## Вычисляется динамически, без кэша: снос пристани мгновенно закрывает доступ,
## инвалидация состояния не требуется.
static func has_harbor_access(tile_data: Array, row: int, col: int, map_rows: int, map_cols: int) -> bool:
    if row < 0 or row >= map_rows or col < 0 or col >= map_cols:
        return false
    var start = tile_data[row][col]
    if start == null:
        return false
    var terrain_id: String = start.get("terrain", "")
    # Работаем только от водных гексов (рыба лежит на lake/sea).
    if not is_water_terrain(terrain_id):
        return false

    var visited := {}
    var queue := [{"row": row, "col": col}]
    visited[row * map_cols + col] = true
    while not queue.is_empty():
        var cur = queue.pop_front()
        for n in HexUtils.get_neighbors_odd_r(cur.row, cur.col, map_rows, map_cols):
            var key: int = n.row * map_cols + n.col
            if visited.has(key):
                continue
            var nt = tile_data[n.row][n.col]
            if nt == null:
                continue
            if is_water_terrain(nt.get("terrain", "")):
                # Тот же водоём продолжается — идём дальше только если тип совпадает
                # (не перетекаем из озера в море).
                if nt.get("terrain", "") == terrain_id:
                    visited[key] = true
                    queue.push_back(n)
                continue
            # Суша: проверяем, стоит ли на ней пристань этого водоёма.
            var imp_id = nt.get("improvement", null)
            if imp_id != null and imp_id != "":
                var imp_data: Dictionary = GameData.improvements.get(imp_id, {})
                if bool(imp_data.get("water_body_harbor", false)):
                    return true
    return false
