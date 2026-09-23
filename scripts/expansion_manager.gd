# expansion_manager.gd
extends Node

# Стоимости территории (разведка и освоение) — в МОНЕТАХ из казны города.
# Базовая цена одного гекса и универсальный модификатор дальности берутся из
# data/game_balance.json (см. get_scout_cost_per_hex / get_expansion_cost_per_hex
# и MapHelpers.get_distance_mult), то есть хардкода цен здесь нет.
# Освоение дополнительно требует ТРУД (см. expansion_cost в terrains.json),
# который накапливается через стройку в build_manager. Решение по балансу:
# труд остаётся ПЛОСКИМ и расстоянием НЕ масштабируется — дальше от города
# дорожает только денежная часть (логистика), а не сама работа.

var is_expansion_mode = false
var hexes_bought = 0
var current_chunk = [] # массив {"row": int, "col": int}
var current_hover_hex = null # {"row": int, "col": int}

signal expansion_mode_changed(active: bool)
signal territory_expanded(row: int, col: int, cost: int)
signal chunk_hovered(chunk: Array) # для оповещения рендерера

@onready var main_map = get_parent()

func toggle():
    is_expansion_mode = !is_expansion_mode
    current_chunk = []
    emit_signal("expansion_mode_changed", is_expansion_mode)
    return is_expansion_mode

func is_active() -> bool:
    return is_expansion_mode

# Возвращает стоимость ТРУДА для освоения одного гекса.
# Базовое значение берётся из expansion_cost террейна (теперь это труд).
# Множитель за количество купленных гексов убран: труд должен оставаться
# «умеренным» и не раздуваться с ростом города.
func get_hex_cost(row: int, col: int) -> int:
    var tile = main_map.tile_data[row][col]
    var terrain_id = tile.get("terrain", "plain")
    var base_cost = 2
    if GameData.terrains.has(terrain_id):
        base_cost = GameData.terrains[terrain_id].get("expansion_cost", 2)
    # Модификаторы технологий (target = "construction_cost", см. data/modifiers.json)
    # также снижают стоимость освоения территории (труд накапливается через стройку).
    return int(ceil(float(base_cost) * MapHelpers.get_construction_cost_mult()))

# Базовая цена разведки одного гекса в монетах казны (data/game_balance.json).
func get_scout_cost_per_hex() -> int:
    return int(GameData.game_balance.get("scouting_cost_per_hex", 3))

# Базовая цена освоения одного гекса в монетах казны (data/game_balance.json).
# Труд считается отдельно — см. get_hex_cost().
func get_expansion_cost_per_hex() -> int:
    return int(GameData.game_balance.get("expansion_cost_per_hex", 5))

# Цена РАЗВЕДКИ одного гекса: база × универсальный модификатор дальности
# (MapHelpers.get_distance_mult — значение из game_balance.json). По аналогии
# со строительством улучшений (MapHelpers.get_improvement_work_cost) дальние
# гексы дороже, но БЕЗ тех-модификаторов: «Колесо» — про перевозку грузов,
# разведчики же идут пешком или едут на лошадях.
func get_hex_scout_cost(row: int, col: int) -> int:
    var distance := HexUtils.hex_distance(row, col, main_map.city_row, main_map.city_col)
    return int(ceil(float(get_scout_cost_per_hex()) * MapHelpers.get_distance_mult(distance)))

# Цена ОСВОЕНИЯ одного гекса в монетах: база × универсальный модификатор
# дальности. Списывается сразу при старте освоения (труд — отдельно, см. get_hex_cost).
func get_hex_money_cost(row: int, col: int) -> int:
    var distance := HexUtils.hex_distance(row, col, main_map.city_row, main_map.city_col)
    return int(ceil(float(get_expansion_cost_per_hex()) * MapHelpers.get_distance_mult(distance)))

# Возвращает чанк (список гексов), который включает стартовый гекс.
# Чанк однороден по статусу исследования стартового гекса, и от этого
# статуса зависит его назначение:
#   - стартовый гекс НЕ исследован → чанк для РАЗВЕДКИ. Границы BFS зависят
#     от технологии «Картография»:
#       · Картография изучена → вся область, достижимая скроллом карты
#         (main_map.get_scout_reach_bounds), кольца влияния чужих городков
#         ПРОХОДИМЫ (разведчиков разрешено посылать в туман войны и на
#         территорию городков);
#       · Картография НЕ изучена → только Регион (main_map.get_region_bounds):
#         разведчиков можно посылать лишь в неисследованную часть Региона.
#     Кольцо Влияния игрока пропускается в обоих случаях.
#   - стартовый гекс исследован → чанк для ПОКУПКИ (освоения). BFS ограничен
#     Регионом (main_map.is_valid_hex), а гексы in_town_influence пропускаются:
#     осваивать можно только свою будущую территорию внутри Региона.
# Если стартовый гекс исследован и лежит в кольце влияния чужого городка или
# вне Региона — возвращается пустой массив: покупать там нечего, осваивать
# чужую территорию запрещено. Это согласуется с тем, что build_manager
# отклоняет строительство на гексах в кольце.
# Если стартовый гекс НЕ исследован и лежит вне Региона, а Картография ещё не
# изучена — тоже возвращается пустой массив: до Картографии туман войны
# недоступен для разведки (иначе чанк из одного стартового гекса дал бы
# подсветку в тумане и кнопку «Отправить разведчиков»).
# ВАЖНО: «примыкание к известной территории» (main_map.is_chunk_adjacent_to_known)
# здесь НЕ проверяется — чанк собирается всегда, чтобы игрок видел подсветку
# подсветку и неактивную кнопку «Отправить разведчиков» с причиной
# («Чанк не граничит с исследованной территорией»). Гейт применяют
# control_panel (enabled/tooltip) и main_map.start_scouting (страховка).
func get_chunk_hexes(start_row: int, start_col: int) -> Array:
    var chunk = []
    var start_tile = main_map.tile_data[start_row][start_col]
    if start_tile == null:
        return chunk
    var start_explored: bool = bool(start_tile.get("is_explored", false))
    # Покупка возможна только на исследованном гексе внутри Региона и не на
    # территории чужого городка. Проверки идут ДО BFS: иначе он добавил бы
    # стартовый гекс в чанк, и панель показала бы «Освоить область» там, где
    # осваивать нельзя. Для разведки (неисследованный гекс) действует своё
    # правило: внутри Региона — всегда, вне Региона — только с Картографией.
    if start_explored:
        if bool(start_tile.get("in_town_influence", false)):
            return chunk
        if not main_map.is_valid_hex(start_row, start_col):
            return chunk
    elif not main_map.is_valid_hex(start_row, start_col) \
            and not main_map.is_cartography_researched():
        return chunk
    var visited = {}
    var queue = [ {"row": start_row, "col": start_col}]
    var key = str(start_row) + "," + str(start_col)
    visited[key] = true
    # Границы области, в которой собирается чанк РАЗВЕДКИ:
    #   Картография изучена  → все гексы, достижимые скроллом карты
    #                          (границы уже обрезаны по краям карты);
    #   Картография не изучена → только Регион (неисследованная его часть).
    # Для чанка ПОКУПКИ ограничение — Регион (проверка через is_valid_hex ниже).
    var scout_reach: Dictionary = {}
    if not start_explored:
        if main_map.is_cartography_researched():
            scout_reach = main_map.get_scout_reach_bounds()
        else:
            scout_reach = main_map.get_region_bounds()

    while queue.size() > 0 and chunk.size() < 5:
        var current = queue.pop_front()
        chunk.append(current)
        var neighbors = _get_neighbors(current.row, current.col)
        for n in neighbors:
            var n_key = str(n.row) + "," + str(n.col)
            if visited.has(n_key):
                continue
            if start_explored:
                # Покупка (освоение): только Регион.
                if not main_map.is_valid_hex(n.row, n.col):
                    continue
            else:
                # Разведка: Регион (без Картографии) либо вся область,
                # достижимая скроллом карты (с Картографией).
                if n.row < scout_reach.row_start or n.row > scout_reach.row_end \
                        or n.col < scout_reach.col_start or n.col > scout_reach.col_end:
                    continue
            var tile = main_map.tile_data[n.row][n.col]
            if tile == null:
                continue
            if tile.get("in_influence", false):
                continue
            # Гексы в кольце влияния чужого городка НЕ входят в чанк покупки:
            # пропускаем так же, как in_influence выше. Ring-гексы становятся
            # «непроходимым барьером» для BFS, и чанк естественно ограничивается
            # границей кольца (но не «обходит» его с другой стороны, потому что
            # у BFS лимит 5 и нет обходных путей вокруг целого кольца).
            # Для РАЗВЕДКИ чужое кольцо проходимо: разведчиков можно послать
            # и на территорию городка.
            if start_explored and bool(tile.get("in_town_influence", false)):
                continue
            # Исключаем гексы с отличающимся статусом исследования,
            # чтобы не включать в чанк разведки уже исследованные гексы
            if bool(tile.get("is_explored", false)) != start_explored:
                continue
            visited[n_key] = true
            queue.append(n)
    return chunk

# Возвращает чанк ПОДСВЕТКИ (до 5 гексов) для ИССЛЕДОВАННОГО гекса, у которого
# нет чанка действий (вне Региона — покупка там невозможна). Строится BFS
# наружу от гекса под курсором (как чанки разведки/покупки — лимит 5), по
# разведанным гексам; in_influence и in_town_influence в чанк не входят.
# Результат сортируется канонически (row, col), поэтому один и тот же набор,
# построенный от разных гексов участка, даёт идентичный массив — детекция
# изменений в update_hovered_chunk не считает его новым чанком.
func _get_explored_chunk_hexes(start_row: int, start_col: int) -> Array:
    var chunk = []
    if not main_map.is_hex_on_map(start_row, start_col):
        return chunk
    var start_tile = main_map.tile_data[start_row][start_col]
    if start_tile == null or not bool(start_tile.get("is_explored", false)):
        return chunk
    var visited = {}
    var queue = [{"row": start_row, "col": start_col}]
    visited[str(start_row) + "," + str(start_col)] = true
    while queue.size() > 0 and chunk.size() < 5:
        var current = queue.pop_front()
        chunk.append(current)
        for n in _get_neighbors(current.row, current.col):
            var n_key = str(n.row) + "," + str(n.col)
            if visited.has(n_key):
                continue
            if not main_map.is_hex_on_map(n.row, n.col):
                continue
            var tile = main_map.tile_data[n.row][n.col]
            if tile == null:
                continue
            if not bool(tile.get("is_explored", false)):
                continue
            if bool(tile.get("in_influence", false)) \
                    or bool(tile.get("in_town_influence", false)):
                continue
            visited[n_key] = true
            queue.append(n)
    # Канонический порядок: подсветка одного участка не должна зависеть от
    # того, с какого его гекса начался BFS.
    chunk.sort_custom(func(a, b):
        if a.row != b.row:
            return a.row < b.row
        return a.col < b.col)
    return chunk

# Возвращает гексы, которые надо подсветить при наведении или выделении гекса
# (row, col) — единая точка правды для рендерера (ФАЗА 2.5 hover и ФАЗА 3.5
# выделение), чтобы подсветка не расходилась с чанком, с которым работают
# действия панели:
#   - гекс в Кольце Влияния → только он сам;
#   - иначе → чанк разведки/покупки (get_chunk_hexes);
#   - если чанка нет, а гекс ИССЛЕДОВАН (разведанная область вне Региона —
#     покупать там нельзя) → чанк подсветки до 5 гексов, построенный наружу
#     от гекса под курсором (_get_explored_chunk_hexes): наведение и клик не
#     должны быть «молчаливыми»;
#   - если чанка нет и гекс в кольце влияния чужого городка (или в тумане без
#     Картографии) → сам гекс.
func get_highlight_hexes(row: int, col: int) -> Array:
    var single := [{"row": row, "col": col}]
    if not main_map.is_hex_on_map(row, col):
        return []
    var tile = main_map.tile_data[row][col]
    if tile == null:
        return []
    if bool(tile.get("in_influence", false)):
        return single
    var chunk = get_chunk_hexes(row, col)
    if chunk.is_empty():
        # Исследованный гекс вне Региона → чанк подсветки. Гекс в кольце
        # чужого городка — исключение: там покупка запрещена всегда, и
        # подсвечиваем только сам гекс (BFS не должен «выходить» из кольца
        # на соседние разведанные гексы).
        if bool(tile.get("is_explored", false)) \
                and not bool(tile.get("in_town_influence", false)):
            return _get_explored_chunk_hexes(row, col)
        return single
    return chunk

# Обновляет текущий подсвеченный чанк. Детекция изменений и хранение идут по
# НАБОРУ ПОДСВЕТКИ (get_highlight_hexes), а не по чанку действий: у
# исследованных гексов вне Региона чанк действий всегда пуст, и сравнение
# [] == [] не давало сигнала — подсветка «застывала» на предыдущей позиции
# курсора при переходе между такими участками.
func update_hovered_chunk(row: int, col: int):
    current_hover_hex = {"row": row, "col": col}
    var highlight = get_highlight_hexes(row, col)
    if _chunk_equals(highlight, current_chunk):
        return
    current_chunk = highlight
    emit_signal("chunk_hovered", current_chunk)

func clear_hovered_chunk():
    current_hover_hex = null
    if current_chunk.is_empty():
        return
    current_chunk = []
    emit_signal("chunk_hovered", current_chunk)

# Стоимость ТРУДА всего чанка = сумма труда по гексам.
func get_chunk_cost(chunk: Array) -> int:
    var total = 0
    for hex in chunk:
        total += get_hex_cost(hex.row, hex.col)
    return total

# Цена РАЗВЕДКИ всего чанка в монетах казны = сумма цен по гексам (каждый гекс
# со своим модификатором дальности от города).
func get_chunk_scout_cost(chunk: Array) -> int:
    var total = 0
    for hex in chunk:
        total += get_hex_scout_cost(hex.row, hex.col)
    return total

# Цена ОСВОЕНИЯ всего чанка в монетах казны = сумма цен по гексам.
# Труд чанка считается отдельно — get_chunk_cost().
func get_chunk_money_cost(chunk: Array) -> int:
    var total = 0
    for hex in chunk:
        total += get_hex_money_cost(hex.row, hex.col)
    return total

# Запускает освоение чанка. Монеты (цена чанка, см. get_chunk_money_cost)
# списываются сразу из казны, а труд накапливается через стройку в
# build_manager (прогресс во времени).
func handle_action(chunk: Array, money_cost: int, work_cost: int) -> bool:
    # --- Защитный повтор: чанк не должен содержать гексов из кольца влияния
    # чужого городка. get_chunk_hexes этого не допускает, но handle_action —
    # публичная точка входа: сюда могут приходить чанки из других путей
    # (например, из теста или из будущего UI). Отказываем молча: логика
    # «купить нельзя» уже объяснена в control_panel (нет actions).
    for hex in chunk:
        if hex.row < 0 or hex.row >= main_map.map_rows or hex.col < 0 or hex.col >= main_map.map_cols:
            return false
        var h_tile = main_map.tile_data[hex.row][hex.col]
        if h_tile == null:
            return false
        if bool(h_tile.get("in_town_influence", false)):
            main_map.hud.show_message("Чанк пересекается с кольцом влияния чужого городка — покупка невозможна")
            return false

    # --- Проверка и списание монет из казны ---
    if not CityData.spend_treasury(money_cost):
        main_map.hud.show_message("Недостаточно монет в казне! Нужно %d, в казне %d"
                % [money_cost, CityData.treasury])
        return false
    # Источник расхода для тултипа «Казна» (см. show_treasury_tooltip).
    # Разовые траты на освоение чанка — событийные, в плане их нет, поэтому
    # разбивка расходов показывает факт за последнее окно отображения.
    if money_cost > 0:
        CityData.record_treasury_expense("Освоение чанков", money_cost)

    # --- Запуск стройки освоения (труд накапливается во времени) ---
    var bm = main_map.build_manager
    if bm and bm.has_method("start_expansion_build"):
        if bm.start_expansion_build(chunk, work_cost):
            return true
        # Стройка не запустилась (например, исчерпан лимит одновременных
        # строек) — возвращаем монеты, чтобы они не пропали.
        CityData.add_treasury(money_cost)
        if money_cost > 0:
            # Возврат идёт в ТОТ ЖЕ источник расходов «Освоение чанков»
            # отрицательной записью: record_treasury_expense принимает
            # signed amount, отрицательное число вычитается из накопленного
            # расхода по этому источнику. Нетто за окно сходится с фактом
            # изменения казны (платил Y → получил Y назад → 0 за окно).
            # Раньше возврат шёл отдельным источником дохода «… (возврат)»,
            # но при иерархической разбивке казны он не ложится ни в один
            # тип («Потребление населения» — это не возврат), поэтому
            # ноттируем внутри расхода.
            CityData.record_treasury_expense("Освоение чанков", -money_cost)
        return false
    # Fallback: если build_manager недоступен — осваиваем мгновенно.
    _complete_expansion(chunk)
    return true

# Обработчик завершения стройки освоения: труд накоплен — присоединяем чанк.
# Подключён в main_map._ready() на сигнал build_manager.expansion_build_completed.
func on_expansion_build_completed(chunk: Array):
    _complete_expansion(chunk)

# Завершает освоение чанка: помечает гексы как принадлежащие Кольцу Влияния.
func _complete_expansion(chunk: Array):
    for hex in chunk:
        if hex.row >= 0 and hex.row < main_map.map_rows and hex.col >= 0 and hex.col < main_map.map_cols:
            main_map.tile_data[hex.row][hex.col]["in_influence"] = true
            hexes_bought += 1
    current_chunk = []
    emit_signal("territory_expanded", chunk[0].row, chunk[0].col, get_chunk_cost(chunk))

func _chunk_equals(a: Array, b: Array) -> bool:
    if a.size() != b.size():
        return false
    for i in range(a.size()):
        if a[i].row != b[i].row or a[i].col != b[i].col:
            return false
    return true

func _get_neighbors(row: int, col: int) -> Array:
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
        neighbors.append({"row": row + d.r, "col": col + d.c})
    return neighbors

func is_hovering_region() -> bool:
    return current_hover_hex != null
