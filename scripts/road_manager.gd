# road_manager.gd
extends Node

# Уровень дороги по умолчанию: тропка. Участки без явного уровня (например,
# поднятые из старого сейва, где road_level ещё не было) считаются тропками —
# это самый слабый уровень, то есть безопасное по умолчанию.
const DEFAULT_ROAD_LEVEL := 1

# Эмитится, когда город впервые соединяется дорогой с городком: сегменты
# дорожной сети города дотянулись до дорожной сети этого городка. На этом
# событии в будущем будет открываться торговля (сейчас — только иконка
# над гексом городка и статус в его окне, см. town_manager.is_trade_available).
signal town_link_established(row: int, col: int)

# Храним дороги как Set строк в формате "row1,col1|row2,col2" (каноническое направление)
# Каноническое = с меньшей суммой row+col, или если равны, то с меньшим col
#
# ЗНАЧЕНИЕ — НЕ true, а УРОВЕНЬ участка (int, см. data/roads.json). Изначально
# здесь был Set, и это работало, пока все дороги были одинаковыми. С появлением
# уровней значение стало полезной нагрузкой: участок помнит, какого он уровня,
# и нигде не нужно отдельного списка «какой участок какого уровня» — который
# разошёлся бы с этим словарём при первом же изменении сети.
# Уровень по умолчанию — тропка (DEFAULT_ROAD_LEVEL), она же база цены: см.
# GameData.get_road_by_level.
var road_segments: Dictionary = {}

# Список "подключённых" гексов (те, к которым уже есть дорога)
var connected_hexes: Dictionary = {}
var city_row: int = 0
var city_col: int = 0

# Версия дорожной сети города. Растёт при ЛЮБОМ её изменении и по ней
# сбрасывается кэш планирования дорог (см. _plan_cache): панель управления
# спрашивает план на КАЖДЫЙ тик, а поиск пути — Дейкстра по всей карте, так
# что без кэша это была бы тяжёлая работа в игровом цикле.
var _network_version: int = 0
# Версия ЗНАНИЯ карты игроком: сколько раз менялось «что известно» (разведка
# завершилась, куплен чанк, сменилась эпоха, дебаг-открытие карты). План
# дороги зависит и от неё — трасса к городку идёт только по разведанной земле,
# — поэтому версия входит в ключ кэша наравне с версией сети дорог.
var _knowledge_version: int = 0
# Кэш планов: "версия сети:версия знаний:фильтр|row,col" ->
# { ok, reason, path, segments, is_town }.
var _plan_cache: Dictionary = {}

# === Сети дорог городков ===
# У каждого городка своя независимая сеть: от центра городка — к его
# улучшениям в кольце влияния (их расставляет
# town_manager._place_decorative_town_improvements). Сети НЕ склеиваются: ни с
# сетью города игрока, ни друг с другом. За это отвечает
# town_connected_hexes — у каждого городка свой набор подключённых гексов, и
# поиск дороги останавливается только на гексе СВОЕЙ сети. Иначе «дороги от
# городка» стали бы дорогами от города игрока, а все городки ещё и связались бы
# между собой одной паутиной дорог через него.
#
# town_road_segments — все сегменты дорог городков в одном плоском словаре
# (канонический ключ сегмента -> уровень): для отрисовки набор всё равно один,
# и совпавший с сегментом другого городка сегмент просто рисуется один раз.
# Автоматические дороги городков всегда тропки (DEFAULT_ROAD_LEVEL): их строит
# сам городок от своего центра, улучшать их нечем.
# town_connected_hexes ключуется координатами ЦЕНТРА городка ("row,col"), а не
# индексом в towns: такой ключ не «поедет», если городки в списке поменяются
# местами.
var town_road_segments: Dictionary = {}
var town_connected_hexes: Dictionary = {}

# === Дороги, которые строит игрок (спецдействие «Построить дорогу») ===
#
# Спецдействие build_road (action_type "road") строит участок дорожной СЕТИ
# ГОРОДА до указанного гекса — от ближайшей уже построенной дороги, обычным
# алгоритмом build_road_from. Сегменты попадают в road_segments, а их гексы —
# в connected_hexes, то есть новая дорога становится частью сети города и
# укорочивает все следующие трассы.
#
# town_link_segments — подмножество road_segments: те из них, что соединяют
# город с ДОРОЖНОЙ СЕТЬЮ ГОРОДКА (цель — ближайшая дорога в кольце влияния
# городка, а не сам его гекс). Хранятся отдельно только ради отрисовки:
# такая дорога может пройти по неисследованной территории, поэтому рисуется
# с теми же гейтами тумана, что и дороги городков (map_renderer.
# is_town_road_segment_visible) — иначе она выдавала бы содержимое тумана.
var town_link_segments: Dictionary = {}

# Кэш МАРШРУТОВ: "версия сети|row,col|town_row,town_col" -> маршрут
# (см. find_route_to_city). Панель управления спрашивает маршрут выбранного
# гекса при каждом обновлении, а поиск — обход всей сети, поэтому без кэша
# это была бы лишняя работа в игровом цикле. В отличие от _plan_cache ключ не
# включает версию знаний о карте: маршрут идёт по УЖЕ ПОСТРОЕННЫМ дорогам,
# а не по местности, поэтому от разведки не зависит.
var _route_cache: Dictionary = {}

# Инициализация после генерации карты
func initialize(new_city_row: int, new_city_col: int):
    self.city_row = new_city_row
    self.city_col = new_city_col
    # Полный сброс сетей: initialize() зовётся один раз на старте партии (и для
    # новой игры, и для загрузки), поэтому состояние всегда начинается с чистого
    # листа — иначе старые сети протекли бы в новую партию.
    road_segments.clear()
    connected_hexes.clear()
    clear_town_roads()
    town_link_segments.clear()
    _invalidate_plan_cache()
    var key = _hex_key(new_city_row, new_city_col)
    connected_hexes[key] = true

func rebuild_roads_from_existing(tile_data: Array, region_rows: int, region_cols: int):
    for row in range(region_rows):
        for col in range(region_cols):
            var tile = tile_data[row][col]
            # Декоративные улучшения (tile.decorative) принадлежат ГОРОДКАМ, а
            # не игроку: их дороги строит сам городок от своего центра
            # (build_town_road_from). Проверки раньше не было, и при загрузке
            # сейва сеть дорог ГОРОДА ИГРОКА прирастала дорогами ко всем полям,
            # лесным делянкам и карьерам всех городков на карте (вызов
            # rebuild_roads_from_existing идёт до загрузки городков, а в tile_data
            # сейва улучшения городков лежат вместе с улучшениями игрока).
            if tile != null and tile.get("improvement", null) != null \
                    and not bool(tile.get("decorative", false)):
                build_road_from(row, col, tile_data, region_rows, region_cols)

# Прокладывает дорогу от нового улучшения до ближайшего подключённого гекса
# в сети ГОРОДА ИГРОКА.
#
# road_level — уровень прокладываемой дороги. По умолчанию тропка: дорога,
# которая строится вместе с улучшением, бесплатна (см. work_cost уровня 1 в
# data/roads.json). Панель управления передаёт здесь уровень, выбранный
# игроком в превью постройки улучшения, поэтому дорога к улучшению может
# оказаться лучше тропки — и это уже оплачено в цене улучшения
# (main_map.get_improvement_work_cost).
func build_road_from(
    start_row: int,
    start_col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    road_level: int = DEFAULT_ROAD_LEVEL
):
    var start_key = _hex_key(start_row, start_col)
    if connected_hexes.has(start_key):
        return

    var best_path = _find_connect_path(start_row, start_col, connected_hexes,
            tile_data, region_rows, region_cols)
    if best_path.is_empty():
        return

    # Добавляем все сегменты дороги
    for i in range(best_path.size() - 1):
        var from_hex = best_path[i]
        var to_hex = best_path[i + 1]
        _add_road_segment(from_hex.row, from_hex.col, to_hex.row, to_hex.col, road_level)
        connected_hexes[_hex_key(from_hex.row, from_hex.col)] = true
        connected_hexes[_hex_key(to_hex.row, to_hex.col)] = true
    _invalidate_plan_cache()

# Общий для города и городков поиск пути от (start_row, start_col) до
# ближайшего гекса из `connected`. Возвращает путь (Array of {row, col}) от
# старта до найденной цели либо пустой массив, если пути нет.
#
# Правила одинаковые для обеих сетей, поэтому и живут здесь:
#   - водные улучшения (например, рыбацкие лодки) не прокладывают дорогу по
#     воде: доступ к водному ресурсу обеспечивает пристань (harbor), стоящая на
#     берегу, к которой дорога строится штатно как к обычному наземному
#     улучшению;
#   - улучшения с флагом no_road дороги не получают (ирригационные каналы —
#     инфраструктура, к которой дорогу прокладывать не нужно);
#   - путь обязан состоять из соседних гексов.
#
# Побочных эффектов нет: `connected` НЕ пополняется — это делает вызывающий код,
# и только для СВОЕЙ сети (у города — connected_hexes, у городка — набор из
# town_connected_hexes). Благодаря этому сети городков остаются независимыми,
# см. build_town_road_from.
func _find_connect_path(
    start_row: int,
    start_col: int,
    connected: Dictionary,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    hex_allowed: Callable = Callable()
) -> Array:
    if start_row >= 0 and start_row < tile_data.size() \
            and start_col >= 0 and start_col < tile_data[start_row].size():
        var start_tile = tile_data[start_row][start_col]
        if start_tile != null and MapHelpers.is_water_terrain(start_tile.get("terrain", "")):
            return []
        var start_imp_id = start_tile.get("improvement", null)
        if start_imp_id != null and GameData.improvements.has(start_imp_id) \
                and GameData.improvements[start_imp_id].get("no_road", false):
            return []

    var best_path = _find_path_between(
        {_hex_key(start_row, start_col): true}, connected,
        tile_data, region_rows, region_cols, hex_allowed
    )
    if best_path.is_empty():
        return []

    # Гарантируем, что путь состоит только из соседних гексов
    if not _validate_path(best_path):
        printerr("Ошибка: путь содержит несоседние гексы!")
        return []
    return best_path

# === Дороги городков ===

# Полный пересчёт дорог городков: для каждого городка строится дорога от его
# центра к каждому улучшению в его КОЛЬЦЕ ВЛИЯНИЯ. Вызывать надо ПОСЛЕ
# town_manager._place_decorative_town_improvements — до неё улучшений в кольце
# ещё нет, и строить будет нечего.
#
# В сейв дороги не пишутся — ровно как городские: входные данные (городки и их
# улучшения) в сейве уже есть, поэтому сеть каждый раз считается заново, и на
# экране всегда одна и та же картина. Каждый городок получает СВОЮ независимую
# сеть (см. town_connected_hexes).
func rebuild_town_roads(towns: Array, tile_data: Array,
        region_rows: int, region_cols: int) -> void:
    clear_town_roads()
    if towns == null:
        return
    for town in towns:
        var town_row := int(town.get("row", -1))
        var town_col := int(town.get("col", -1))
        if town_row < 0 or town_col < 0:
            continue
        # Центр городка — корень своей сети: к нему стягиваются все дороги.
        _town_connected(town_row, town_col)[_hex_key(town_row, town_col)] = true
        for h in town.get("influence_hexes", []):
            var row := int(h.get("row", -1))
            var col := int(h.get("col", -1))
            if row < 0 or col < 0 or row >= region_rows or col >= region_cols:
                continue
            var tile = tile_data[row][col]
            if tile == null or tile.get("improvement", null) == null:
                continue
            build_town_road_from(town_row, town_col, row, col,
                    tile_data, region_rows, region_cols)

# Прокладывает дорогу от улучшения (start_row, start_col) до сети ЭТОГО
# городка — полный аналог build_road_from, но в сети городка. Путь ищется
# только до гексов, подключённых к ЭТОМУ городку, поэтому дорога городка
# логически не может стать частью дорог города игрока или другого городка.
# Геометрически трасса может пройти по гексам соседа (путь ищется по всей
# карте, вода непроходима) — набор сегментов для отрисовки у городов общий,
# и «общая трасса» просто рисуется один раз.
func build_town_road_from(
    town_row: int,
    town_col: int,
    start_row: int,
    start_col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int
) -> void:
    var connected := _town_connected(town_row, town_col)
    if connected.has(_hex_key(start_row, start_col)):
        return

    var best_path = _find_connect_path(start_row, start_col, connected,
            tile_data, region_rows, region_cols)
    if best_path.is_empty():
        return

    for i in range(best_path.size() - 1):
        var from_hex = best_path[i]
        var to_hex = best_path[i + 1]
        _add_town_road_segment(from_hex.row, from_hex.col, to_hex.row, to_hex.col)
        connected[_hex_key(from_hex.row, from_hex.col)] = true
        connected[_hex_key(to_hex.row, to_hex.col)] = true

# Набор подключённых гексов СЕТИ ГОРОДКА (создаётся на первый запрос).
func _town_connected(town_row: int, town_col: int) -> Dictionary:
    var key := _hex_key(town_row, town_col)
    if not town_connected_hexes.has(key):
        town_connected_hexes[key] = {}
    return town_connected_hexes[key]

# Сбрасывает все сети дорог городков (старт партии и полный пересчёт).
func clear_town_roads() -> void:
    town_road_segments.clear()
    town_connected_hexes.clear()
    _invalidate_plan_cache()

# Проверяет, соединён ли гекс дорогами с центром ЭТОГО городка.
func is_town_connected(town_row: int, town_col: int, row: int, col: int) -> bool:
    var connected = town_connected_hexes.get(_hex_key(town_row, town_col), null)
    if connected == null:
        return false
    return connected.has(_hex_key(row, col))

# Добавляет сегмент дороги городка в каноническом направлении (без дубликатов).
# Дороги городков — всегда тропки: их строит сам городок от своего центра,
# и уровень у них не выбирается (см. шапку файла).
func _add_town_road_segment(row1: int, col1: int, row2: int, col2: int):
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    town_road_segments[key] = DEFAULT_ROAD_LEVEL

# Все сегменты дорог городков (для отрисовки).
func get_all_town_road_segments() -> Dictionary:
    return town_road_segments.duplicate()

# === Дороги, которые строит игрок ===

# Сбрасывает кэш планов. Вызывается при ЛЮБОМ изменении сетей (см.
# _network_version), потому что план зависит от того, что уже подключено.
func _invalidate_plan_cache() -> void:
    _network_version += 1
    _plan_cache.clear()
    _route_cache.clear()

# Сообщает менеджеру, что на карте изменилось, что ИЗВЕСТНО игроку: завершилась
# разведка, куплен чанк, сменилась эпоха, открыта вся карта в дебаге. План
# дороги игрока строится по разведанной территории, поэтому без этой версии
# кэш отдавал бы устаревший маршрут (например, «дороги нет» сразу после того,
# как игрок разведал проход к городку).
# Вызывается из main_map — там, где меняется is_explored / in_influence.
func bump_map_knowledge() -> void:
    _knowledge_version += 1
    _plan_cache.clear()

# Подключён ли гекс к сети дорог ГОРОДА (по нему уже проложена дорога —
# либо он гекс города, либо через него прошла трасса). Это и есть проверка
# «на этом гексе дороги ещё нет» для кнопки спецдействия.
func is_hex_connected(row: int, col: int) -> bool:
    return connected_hexes.has(_hex_key(row, col))

# Соединён ли город с ЭТИМ городком дорогами. Проверка вычисляемая, а не
# сохранённая: сети города и городка соединились, если хотя бы один гекс
# сети городка подключён к сети города. Именно этот признак открывает
# торговлю (см. town_manager.is_trade_available) и рисует иконку над городком.
# Сохранённый флаг town["road_linked"] — другое: он помнит, что игрок ЭТО
# делал, и по нему связь восстанавливается из сейва (см. rebuild_player_roads).
func is_town_linked_to_city(town_row: int, town_col: int) -> bool:
    var town_net = town_connected_hexes.get(_hex_key(town_row, town_col), null)
    if town_net == null or town_net.is_empty():
        return false
    for key in town_net.keys():
        if connected_hexes.has(key):
            return true
    return false

# Гексы дорожной сети ГОРОДКА, лежащие в его кольце влияния, — именно они
# являются целью дороги «город → городок» («до ближайшей дороги в кольце
# влияния»). Сам гекс городка целью не является: в него дорога не ведётся.
# Кольцо влияния передаётся снаружи: road_manager о мире ничего не знает.
func _town_road_targets_in_ring(
    town_row: int, town_col: int, town_influence_hexes: Array) -> Dictionary:
    var targets: Dictionary = {}
    var town_net = town_connected_hexes.get(_hex_key(town_row, town_col), null)
    if town_net == null:
        return targets
    for h in town_influence_hexes:
        var key := _hex_key(int(h.get("row", -1)), int(h.get("col", -1)))
        if town_net.has(key):
            targets[key] = true
    return targets

# Планирует дорогу от сети ГОРОДА до гекса (row, col) — БЕЗ побочных эффектов
# (сеть не меняется: это чистый расчёт для превью в панели управления).
#
# Два случая по типу гекса:
#   - обычный гекс — цель сам гекс, трасса ищется до ближайшего гекса сети
#     города обычным алгоритмом (_find_connect_path);
#   - гекс ГОРОДКА — цель ближайшая дорога в КОЛЬЦЕ ВЛИЯНИЯ городка
#     (см. _town_road_targets_in_ring), то есть соединяются две сети.
#
# hex_allowed (необязательный Callable) ограничивает трассу известной игроку
# территорией; его передаёт main_map.get_road_plan (is_hex_known). Признак
# фильтра входит в ключ кэша: план без фильтра и план с фильтром — разные
# маршруты, и путать их нельзя.
#
# Возвращает { ok, reason, path, segments, is_town }. segments — число сегментов
# ВСЕГО пути (path.size() − 1), включая уже построенные. Умножать на цену
# участка его нельзя: за уже проложенные участки платить не нужно, и фильтрует
# их main_map._build_road_steps. Цена дороги — это сумма цен её ШАГОВ
# (main_map.get_road_cost_breakdown), у каждого своя местность и дальность.
# Результат кэшируется по версиям сети дорог и знаний о карте: панель
# спрашивает план на каждом тике, а поиск пути — Дейкстра по карте.
func plan_road_to(
    row: int,
    col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    town_influence_hexes: Array = [],
    hex_allowed: Callable = Callable()
) -> Dictionary:
    var cache_key := "%d:%d:%d|%s" % [
        _network_version, _knowledge_version,
        int(hex_allowed.is_valid()), _hex_key(row, col)]
    if _plan_cache.has(cache_key):
        return _plan_cache[cache_key]
    var plan := _compute_road_plan(
        row, col, tile_data, region_rows, region_cols, town_influence_hexes, hex_allowed)
    _plan_cache[cache_key] = plan
    return plan

func _compute_road_plan(
    row: int,
    col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    town_influence_hexes: Array,
    hex_allowed: Callable
) -> Dictionary:
    if row < 0 or row >= tile_data.size() or col < 0 or col >= tile_data[row].size():
        return _road_plan(false, tr("Hex outside the map"), [], 0, false)
    var tile = tile_data[row][col]
    if tile == null:
        return _road_plan(false, tr("Hex outside the map"), [], 0, false)
    var is_town := bool(tile.get("has_town", false))

    # --- Гекс ГОРОДКА: соединяем с дорожной сетью городка в его кольце ---
    if is_town:
        if is_town_linked_to_city(row, col):
            return _road_plan(false, tr("The town is already connected by a road"), [], 0, true)
        var targets := _town_road_targets_in_ring(row, col, town_influence_hexes)
        if targets.is_empty():
            return _road_plan(false, tr("The town has no road inside the influence ring"), [], 0, true)
        # Многоточечный поиск: от всех дорог кольца — к ближайшей дороге города.
        # Трасса идёт ТОЛЬКО по известной территории (см. hex_allowed): к
        # городку нельзя даже подойти, не разведав дорогу до него.
        var town_path = _find_path_between(targets, connected_hexes,
                tile_data, region_rows, region_cols, hex_allowed)
        if town_path.is_empty():
            return _road_plan(false, _town_road_failure_reason(targets, tile_data,
                    region_rows, region_cols, hex_allowed), [], 0, true)
        if not _validate_path(town_path):
            printerr("Ошибка: путь дороги к городку содержит несоседние гексы!")
            return _road_plan(false, tr("Could not find a path to the town"), [], 0, true)
        return _road_plan(true, "", town_path, town_path.size() - 1, true)

    # --- Обычный гекс: дорога до него от ближайшей дороги города ---
    if is_hex_connected(row, col):
        return _road_plan(false, tr("A road to the hex already exists"), [], 0, false)
    if MapHelpers.is_water_terrain(tile.get("terrain", "plain")):
        return _road_plan(false, tr("Roads cannot be built over water"), [], 0, false)
    var hex_path = _find_connect_path(row, col, connected_hexes,
            tile_data, region_rows, region_cols, hex_allowed)
    if hex_path.is_empty():
        return _road_plan(false, tr("There is no land route from the city to this hex"), [], 0, false)
    return _road_plan(true, "", hex_path, hex_path.size() - 1, false)

# Почему не получилось дойти до городка, и что игроку с этим делать. Случая два,
# и советы должны быть разными:
#   - сухопутный путь ЕСТЬ, но идёт по неразведанной земле → нужен разведчик;
#     «городок виден, но подойти не через что»;
#   - сухопутного пути НЕТ вообще (городок за водой) → разведчики не помогут,
#     тут нужен другой городок (морская торговля в игре пока не заведена).
# Второй случай проверяется тем же поиском, но без ограничения по известности.
# Лишняя работа — один Дейкстра, и только на неудачном плане, а результат плана
# кэшируется, так что на каждый тик она не повторяется.
func _town_road_failure_reason(
        targets: Dictionary,
        tile_data: Array,
        region_rows: int,
        region_cols: int,
        hex_allowed: Callable) -> String:
    if not hex_allowed.is_valid():
        return tr("There is no land route from the city to the town")
    var any_path := _find_path_between(targets, connected_hexes,
            tile_data, region_rows, region_cols)
    if any_path.is_empty():
        return tr("There is no land route from the city to the town (the town is across water)")
    return tr("No scouted route from the city to the town — send scouts there")

func _road_plan(ok: bool, reason: String, path: Array, segments: int, is_town: bool) -> Dictionary:
    return {
        "ok": ok,
        "reason": reason,
        "path": path,
        "segments": segments,
        "is_town": is_town
    }

# Строит дорогу по плану от plan_road_to: сегменты и подключённые гексы
# добавляются в СЕТЬ ГОРОДА, поэтому новая дорога сразу укорачивает все
# следующие трассы. segments_to_build — сколько новых участков оплачено
# (-1 = вся трасса): см. вызов из main_map._on_build_completed.
func build_road_to(
    row: int,
    col: int,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    town_influence_hexes: Array = [],
    segments_to_build: int = -1,
    hex_allowed: Callable = Callable(),
    road_level: int = DEFAULT_ROAD_LEVEL
) -> bool:
    var plan := plan_road_to(row, col, tile_data, region_rows, region_cols,
            town_influence_hexes, hex_allowed)
    if not plan.get("ok", false):
        return false
    var is_town := bool(plan.get("is_town", false))
    var road_path: Array = plan.get("path", [])
    # Трасса может быть длиннее оплаченной части: недоплаченные участки
    # просто не строятся (стройка не завершится, пока труд не собран).
    var limit := road_path.size() - 1
    if segments_to_build >= 0:
        limit = mini(limit, segments_to_build)
    if limit <= 0:
        return false

    for i in range(mini(road_path.size() - 1, limit)):
        var from_hex = road_path[i]
        var to_hex = road_path[i + 1]
        _add_road_segment(from_hex.row, from_hex.col, to_hex.row, to_hex.col, road_level)
        connected_hexes[_hex_key(from_hex.row, from_hex.col)] = true
        connected_hexes[_hex_key(to_hex.row, to_hex.col)] = true
        if is_town:
            # Такая дорога соединяет город с городком — она рисуется с
            # гейтами тумана (см. town_link_segments), а при полной оплате
            # трассы эмитится сигнал открытия связи.
            town_link_segments[_get_canonical_road_key(
                from_hex.row, from_hex.col, to_hex.row, to_hex.col)] = true
    _invalidate_plan_cache()

    if is_town and limit >= road_path.size() - 1:
        emit_signal("town_link_established", row, col)
    return true

# Канонический ключ сегмента дороги — тот же формат, что у road_segments
# ("row1,col1|row2,col2" в каноническом направлении). Открытая обёртка над
# внутренним _get_canonical_road_key: ключи сегментов нужны не только самому
# road_manager, но и владельцу поэтапного проекта (main_map собирает из них
# «призрак» непостроенных участков на карте).
func get_road_segment_key(row1: int, col1: int, row2: int, col2: int) -> String:
    return _get_canonical_road_key(row1, col1, row2, col2)

# Строит ОДИН участок поэтапной дороги: сегмент уходит в сеть ГОРОДА, оба
# его гекса подключаются, кэш планов сбрасывается. Главное отличие от
# build_road_to, который прокладывает всю трассу одним вызовом, — здесь
# добавляется ровно один сегмент, потому что очередь шагов проекта
# (project_manager) разбирается по одному.
#
# is_town — трасса идёт к городку: такой сегмент дополнительно попадает в
# town_link_segments, чтобы рисоваться с гейтами тумана (см.
# get_all_town_link_segments). Событие открытия связи при этом НЕ эмитится:
# оно наступит, когда достроится ПОСЛЕДНИЙ участок, и его эмитит владелец
# проекта (main_map) — здесь такого знания ещё нет.
func build_road_step(
    from_row: int,
    from_col: int,
    to_row: int,
    to_col: int,
    is_town: bool = false,
    road_level: int = DEFAULT_ROAD_LEVEL
) -> bool:
    if has_road_between(from_row, from_col, to_row, to_col):
        return false
    _add_road_segment(from_row, from_col, to_row, to_col, road_level)
    connected_hexes[_hex_key(from_row, from_col)] = true
    connected_hexes[_hex_key(to_row, to_col)] = true
    if is_town:
        town_link_segments[_get_canonical_road_key(
                from_row, from_col, to_row, to_col)] = true
    _invalidate_plan_cache()
    return true

# Новые, ещё НЕ построенные сегменты трассы плана — в том же формате ключей,
# что и road_segments (см. _get_canonical_road_key), поэтому рендерер рисует их
# тем же кодом, что и настоящие дороги, но своим стилем. Побочных эффектов нет:
# план уже посчитан и закэширован, повторный поиск пути не выполняется. Уже
# существующие участки пропускаются — рисовать их в превью незачем, за них
# игрок не платит.
func get_plan_new_segments(plan: Dictionary) -> Dictionary:
    var segments: Dictionary = {}
    if not plan.get("ok", false):
        return segments
    var road_path: Array = plan.get("path", [])
    for i in range(maxi(road_path.size() - 1, 0)):
        var from_hex = road_path[i]
        var to_hex = road_path[i + 1]
        if has_road_between(from_hex.row, from_hex.col, to_hex.row, to_hex.col):
            continue
        segments[_get_canonical_road_key(
                from_hex.row, from_hex.col, to_hex.row, to_hex.col)] = true
    return segments

# Восстанавливает дороги, построенные игроком через спецдействие
# «Построить дорогу». Как и с дорогами к улучшениям, в сейв пишутся не
# сегменты, а входные данные: на гексе стоит флаг tile["road_built"], а у
# записи городка — флаг town["road_linked"]; сеть считается заново.
#
# Вызывать ПОСЛЕ rebuild_roads_from_existing (сеть города) и
# rebuild_town_roads (дорожные сети городков — они и есть цель дороги
# до городка). Для гекса городка цель не сам гекс, а кольцо влияния,
# поэтому towns нужен здесь: road_manager о нём ничего не знает.
# hex_allowed — тот же Callable «известна ли территория», что и при обычном
# планировании (его передаёт main_map): восстановленная дорога обязана идти
# по разведанной земле ровно так же, как строилась.
func rebuild_player_roads(
    towns: Array,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    hex_allowed: Callable = Callable()
) -> void:
    var ring_by_town: Dictionary = {}
    for town in towns:
        var t_row := int(town.get("row", -1))
        var t_col := int(town.get("col", -1))
        if t_row < 0 or t_col < 0:
            continue
        ring_by_town[_hex_key(t_row, t_col)] = town.get("influence_hexes", [])
    for row in range(region_rows):
        for col in range(region_cols):
            var tile = tile_data[row][col]
            if tile == null or not bool(tile.get("road_built", false)):
                continue
            var ring: Array = ring_by_town.get(_hex_key(row, col), [])
            build_road_to(row, col, tile_data, region_rows, region_cols, ring, -1,
                    hex_allowed, _tile_road_level(tile))

# Уровень дороги гекса — входные данные для восстановления из сейва (сегменты
# с уровнями, как и сами сегменты, в сейв не пишутся). Старые сейвы поля не
# содержат — там тропка, то есть самый слабый уровень.
func _tile_road_level(tile: Dictionary) -> int:
    return int(tile.get("road_level", DEFAULT_ROAD_LEVEL))

# === МАРШРУТ ДО ГОРОДА И СКОРОСТЬ ===

# Ищет маршрут от гекса (row, col) до гекса города ПО УЖЕ ПОСТРОЕННЫМ дорогам
# и возвращает его вместе со скоростью.
#
# Отличие от plan_road_to принципиально: там ищется путь по МЕСТНОСТИ (куда
# можно проложить новую дорогу), здесь — по сети (как реально дойти). Поэтому
# поиск другой (обход сети, а не Дейкстра по карте) и фильтр известности не
# нужен: дорога уже стоит там, где её видно.
#
# town_row/town_col — если исходная точка принадлежит городку, маршрут идёт по
# сети ЭТОГО городка, потом по участку связи (town_link_segments) и дальше по
# сети города.
#
# ПРО avg_speed: это среднее арифметическое max_speed участков — «насколько
# быстро в среднем едет груз по этому маршруту». Отдельно отдаётся min_speed:
# физически узкое место ограничивает поток сильнее среднего (груз всё равно
# должен пройти через самый узкий участок), поэтому игроку показываются оба
# числа, и решение «улучшить дорогу» принимается по min_speed.
func find_route_to_city(
    row: int,
    col: int,
    town_row: int = -1,
    town_col: int = -1
) -> Dictionary:
    var cache_key := "%d|%d,%d|%d,%d" % [_network_version, row, col, town_row, town_col]
    if _route_cache.has(cache_key):
        return _route_cache[cache_key]
    var route := _compute_route_to_city(row, col, town_row, town_col)
    _route_cache[cache_key] = route
    return route

func _compute_route_to_city(
    row: int,
    col: int,
    town_row: int,
    town_col: int
) -> Dictionary:
    var start_key := _hex_key(row, col)
    var city_key := _hex_key(city_row, city_col)
    var no_route := tr("No road connects this hex to the city")
    if start_key == city_key:
        # Сам город: маршрут пустой. Скорость 0, а не «бесконечность»:
        # участков нет, делить на их количество нельзя, а показывать
        # игроку бесконечную скорость города нечестно — доставка начинается
        # на подходе к городу, а не на его гексе.
        return _route(false, tr("This is the city itself"), [], [], [], 0, 0.0, 0)

    # Сеть, по которой идём: участки города + (для городка) участки его
    # собственной сети. Сети городков не склеиваются между собой, поэтому
    # участки чужого городка в маршрут не попадают (см. шапку файла).
    var segments: Dictionary = {}
    for key in road_segments.keys():
        segments[key] = true
    if town_row >= 0 and town_col >= 0:
        var town_net = town_connected_hexes.get(_hex_key(town_row, town_col), null)
        if town_net != null:
            for key in town_road_segments.keys():
                segments[key] = true

    # Список смежности: "row,col" -> [{"key": String, "to": "row,col"}].
    var adjacency: Dictionary = {}
    for key in segments.keys():
        var ends := _parse_segment_key(key)
        if ends.is_empty():
            continue
        var a_key := _hex_key(int(ends[0]), int(ends[1]))
        var b_key := _hex_key(int(ends[2]), int(ends[3]))
        if not adjacency.has(a_key):
            adjacency[a_key] = []
        if not adjacency.has(b_key):
            adjacency[b_key] = []
        adjacency[a_key].append({"key": key, "to": b_key})
        adjacency[b_key].append({"key": key, "to": a_key})

    if not adjacency.has(start_key):
        return _route(false, no_route, [], [], [], 0, 0.0, 0)

    # Обход в ширину: маршрут с наименьшим числом участков. Все участки стоят
    # одинаково, поэтому взвешивать расстояния не нужно — их и нет.
    var parent: Dictionary = {start_key: null}
    var visited: Dictionary = {start_key: true}
    var queue: Array = [start_key]
    var found := false
    while not queue.is_empty():
        var current: String = queue.pop_front()
        if current == city_key:
            found = true
            break
        for edge in adjacency.get(current, []):
            var next_key: String = str(edge["to"])
            if visited.has(next_key):
                continue
            visited[next_key] = true
            parent[next_key] = {"from": current, "key": str(edge["key"])}
            queue.append(next_key)

    if not found:
        return _route(false, no_route, [], [], [], 0, 0.0, 0)

    # Восстанавливаем маршрут ОТ УЛУЧШЕНИЯ К ГОРОДУ. Обход шёл в обратную
    # сторону (от гекса к городу), поэтому восстановленный список разворачиваем
    # push_front-ом — так path, segments и levels идут в одном порядке.
    #
    # Инвариант порядка: segments[i] соединяет path[i] и path[i + 1]. От него
    # зависят и подсветка маршрута на карте, и очередь улучшения (шаги идут
    # в обратном порядке — от города к цели), поэтому «почти наоборот» здесь
    # недопустимо.
    var path: Array = []
    var segment_keys: Array = []
    var levels: Array = []
    var speed_sum := 0
    var min_speed := 0
    var current_key: String = city_key
    while current_key != start_key:
        var step = parent.get(current_key, null)
        if step == null:
            return _route(false, no_route, [], [], [], 0, 0.0, 0)
        var hex_parts := str(current_key).split(",")
        path.push_front({"row": int(hex_parts[0]), "col": int(hex_parts[1])})
        var seg_key: String = str(step["key"])
        segment_keys.push_front(seg_key)
        var level := _segment_level_by_key(seg_key)
        levels.push_front(level)
        var speed := GameData.get_road_max_speed(level)
        speed_sum += speed
        if min_speed == 0 or speed < min_speed:
            min_speed = speed
        current_key = str(step["from"])
    path.push_front({"row": row, "col": col})

    var length := segment_keys.size()
    var avg_speed := 0.0 if length == 0 else float(speed_sum) / float(length)
    return _route(true, "", path, segment_keys, levels, length, avg_speed, min_speed)

func _route(ok: bool, reason: String, path: Array, segments: Array, levels: Array,
        length: int, avg_speed: float, min_speed: int) -> Dictionary:
    return {
        "ok": ok,
        "reason": reason,
        "path": path,
        "segments": segments,
        "levels": levels,
        "length": length,
        "avg_speed": avg_speed,
        "min_speed": min_speed
    }

# Уровень участка по его строковому ключу. Участка в сети города нет — 0 не
# возвращаем: участок может принадлежать сети городка (town_road_segments), и
# для маршрута от городка такой участок — обычная тропка.
func _segment_level_by_key(key: String) -> int:
    if road_segments.has(key):
        return int(road_segments[key])
    return DEFAULT_ROAD_LEVEL

# Разбирает ключ участка "row1,col1|row2,col2" в [row1, col1, row2, col2].
# Пустой массив — ключ повреждён; вызывающий его пропускает, потому что
# нарисовать или тарифицировать такой участок всё равно нельзя.
func _parse_segment_key(key: String) -> Array:
    var ends := key.split("|")
    if ends.size() != 2:
        return []
    var a := ends[0].split(",")
    var b := ends[1].split(",")
    if a.size() != 2 or b.size() != 2:
        return []
    if not (a[0].is_valid_int() and a[1].is_valid_int()
            and b[0].is_valid_int() and b[1].is_valid_int()):
        return []
    return [int(a[0]), int(a[1]), int(b[0]), int(b[1])]

# Сегменты дорог, соединяющих город с городками (для отрисовки с гейтами
# тумана — см. town_link_segments).
func get_all_town_link_segments() -> Dictionary:
    return town_link_segments.duplicate()

# Ключ гекса "row,col" — единый формат ключей во всех словарях менеджера.
func _hex_key(row: int, col: int) -> String:
    return str(row) + "," + str(col)

# Добавляет сегмент дороги в каноническом направлении (без дубликатов).
# Уровень передаётся явно: участок помнит свой уровень (см. шапку файла).
func _add_road_segment(row1: int, col1: int, row2: int, col2: int,
        road_level: int = DEFAULT_ROAD_LEVEL):
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    road_segments[key] = road_level

# Уровень дороги на гексе = МАКСИМУМ по примыкающим участкам.
# 0 — к гексу не примыкает ни один участок, то есть дороги нет.
#
# Это ПРОИЗВОДНАЯ величина, а не хранимая. Хранится уровень УЧАСТКА
# (road_segments: "row,col|row,col" -> level), и он остаётся единственным
# источником правды: у гекса своего уровня просто нет.
#
# Именно поэтому правило читается как «у гекса одна дорога», а не как
# «у всех участков гекса один уровень». Разница существенная: если бы мы
# хранили уровень гекса и требовали, чтобы все примыкающие участки были
# его уровня, то повышение одного участка требовало бы поднять все
# остальные, примыкающие к тому же гексу, а те — все примыкающие к ним,
# и так далее: уровень расползёлся бы на всю связную сеть дорог, а
# avg_speed стал бы тождественен min_speed. Правило максимума не требует
# ничего подобного: оранжевая тропка через перекрёсток остаётся тропкой,
# а показывается лучшая дорога, до гекса доходящая.
#
# Участки сетей ГОРОДКОВ здесь не учитываются: их уровень всегда 1, они не
# принадлежат игроку и не улучшаются.
func get_hex_road_level(row: int, col: int) -> int:
    var best := 0
    for neighbor in _get_neighbors(row, col, 999, 999):
        # 0 — участка нет: считать его дорогой нельзя.
        best = maxi(best, get_segment_level(row, col,
                int(neighbor.row), int(neighbor.col)))
    return best

# Уровень участка дороги. Участка нет — 0 (не тропка!): вызывающий должен
# отличать «участка нет» от «участок-тропка», иначе несуществующий участок
# молча посчитался бы дорогой с пропускной способностью.
func get_segment_level(row1: int, col1: int, row2: int, col2: int) -> int:
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    if not road_segments.has(key):
        return 0
    return int(road_segments[key])

# Повышает уровень уже построенного участка (спецдействие «Улучшить дорогу»).
# Возвращает false, если участка нет или он уже не ниже уровня: улучшать
# нечего, и пустой шаг проекта был бы шагом без работы.
func upgrade_road_segment(row1: int, col1: int, row2: int, col2: int,
        road_level: int) -> bool:
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    if not road_segments.has(key):
        return false
    if int(road_segments[key]) >= road_level:
        return false
    road_segments[key] = road_level
    # Сеть изменилась по составу уровней: маршруты и их средняя скорость
    # теперь другие, кэш маршрутов сбрасываем.
    _invalidate_plan_cache()
    return true

# Получает канонический ключ для пары гексов
func _get_canonical_road_key(row1: int, col1: int, row2: int, col2: int) -> String:
    var sum1 = row1 + col1
    var sum2 = row2 + col2
    if sum1 < sum2 or (sum1 == sum2 and col1 < col2):
        return "%d,%d|%d,%d" % [row1, col1, row2, col2]
    return "%d,%d|%d,%d" % [row2, col2, row1, col1]

# Валидирует, что все соседние элементы в пути являются соседями
func _validate_path(path: Array) -> bool:
    for i in range(path.size() - 1):
        var curr = path[i]
        var next = path[i + 1]
        if not _are_neighbors(curr.row, curr.col, next.row, next.col):
            return false
    return true

# Dijkstra с приоритетной очередью для поиска кратчайшего пути
# от ЛЮБОГО гекса из `sources` до ближайшего гекса из `targets`.
# Оба множества — словари "row,col" -> true, поэтому один и тот же поиск
# обслуживает и обычную дорогу (sources = {старт}, targets = connected_hexes
# города), и соединение с дорожной сетью городка (sources = кольцо влияния,
# targets = connected_hexes) — см. plan_road_to.
#
# hex_allowed (необязательный) — Callable(row, col) -> bool: какие гексы вообще
# можно использовать в трассе. Им ограничиваются ТОЛЬКО дороги, которые строит
# игрок: они идут по известной игроку территории (main_map.is_hex_known —
# в Кольце Влияния или разведано), потому что взаимодействовать с городком
# можно только на разведанном гексе, и дорога к нему обязана идти тем же
# разведанным путём. Автоматические сети (дороги к улучшениям города и
# городков) фильтр не передают и ведут себя как раньше: улучшения стоят в
# Кольце Влияния, а городок разведывает окрестности сам.
#
# Исходный гекс сам по себе целью не считается (как раньше, до обобщения):
# если источник уже лежит в targets, дорога не строится «сама в себя».
func _find_path_between(
    sources: Dictionary,
    targets: Dictionary,
    tile_data: Array,
    region_rows: int,
    region_cols: int,
    hex_allowed: Callable = Callable()
) -> Array:
    var visited = {}
    var parent = {}
    var cost_so_far = {}

    # Инициализация: все источники стартуют с нулевой стоимости. Источники,
    # которым запрещено прохождение (туман войны), отбрасываются: иначе трасса
    # начиналась бы с гекса, которого игрок не знает, и первый же сегмент уходил
    # бы в неисследованную землю.
    for source_key in sources.keys():
        if hex_allowed.is_valid() \
                and not bool(hex_allowed.call(
                        int(source_key.split(",")[0]), int(source_key.split(",")[1]))):
            continue
        cost_so_far[source_key] = 0
        parent[source_key] = null
    if cost_so_far.is_empty():
        return []

    var current_key = _cheapest_open_node(cost_so_far, visited)

    while true:
        # Достигли цели — восстанавливаем путь от источника до неё
        if targets.has(current_key) and not sources.has(current_key):
            return _reconstruct_path(current_key, parent)

        visited[current_key] = true

        var cur_row = int(current_key.split(",")[0])
        var cur_col = int(current_key.split(",")[1])

        var neighbors = _get_neighbors(cur_row, cur_col, region_rows, region_cols)
        for n in neighbors:
            var n_key = _hex_key(n.row, n.col)

            if visited.has(n_key):
                continue

            var tile = tile_data[n.row][n.col]
            if tile == null or MapHelpers.is_water_terrain(tile.get("terrain", "plain")):
                continue
            # Территория, по которой дорога строить нельзя (туман войны):
            # проверяется ДО подсчёта стоимости, чтобы такие гексы вообще не
            # попадали в поиск.
            if hex_allowed.is_valid() and not bool(hex_allowed.call(n.row, n.col)):
                continue
            var terrain_id = tile.get("terrain", "plain")
            var move_cost = 1
            if GameData.terrains.has(terrain_id):
                move_cost = GameData.terrains[terrain_id].get("move_cost", 1)

            var new_cost = cost_so_far[current_key] + move_cost
            if not cost_so_far.has(n_key) or new_cost < cost_so_far[n_key]:
                cost_so_far[n_key] = new_cost
                parent[n_key] = current_key

        current_key = _cheapest_open_node(cost_so_far, visited)
        if current_key == null:
            # Путь не найден
            return []

    # Никогда не должны достичь этой точки
    return []

# Возвращает ключ ещё не посещённого гекса с минимальной накопленной
# стоимостью (или null, если таких больше нет).
func _cheapest_open_node(cost_so_far: Dictionary, visited: Dictionary):
    var min_cost = INF
    var next_key = null
    for key in cost_so_far.keys():
        if not visited.has(key) and cost_so_far[key] < min_cost:
            min_cost = cost_so_far[key]
            next_key = key
    return next_key

# Восстанавливает путь от конца к началу
func _reconstruct_path(end_key: String, parent: Dictionary) -> Array:
    var path = []
    var current_key = end_key
    
    while current_key != null:
        var parts = current_key.split(",")
        path.push_front({"row": int(parts[0]), "col": int(parts[1])})
        current_key = parent.get(current_key, null)
    
    return path

# Проверяет, являются ли два гекса соседями
func _are_neighbors(row1: int, col1: int, row2: int, col2: int) -> bool:
    var neighbors = _get_neighbors(row1, col1, 999, 999)
    for n in neighbors:
        if n.row == row2 and n.col == col2:
            return true
    return false

# Получение соседей для odd-r гексагональной сетки
func _get_neighbors(row: int, col: int, max_rows: int, max_cols: int) -> Array:
    var neighbors = []
    var directions = []
    
    # Для even rows (row % 2 == 0)
    if row % 2 == 0:
        directions = [
            {"r": 0, "c": - 1}, # W
            {"r": 0, "c": 1}, # E
            {"r": - 1, "c": - 1}, # NW
            {"r": - 1, "c": 0}, # NE
            {"r": 1, "c": - 1}, # SW
            {"r": 1, "c": 0} # SE
        ]
    else:
        # Для odd rows (row % 2 == 1)
        directions = [
            {"r": 0, "c": - 1}, # W
            {"r": 0, "c": 1}, # E
            {"r": - 1, "c": 0}, # NW
            {"r": - 1, "c": 1}, # NE
            {"r": 1, "c": 0}, # SW
            {"r": 1, "c": 1} # SE
        ]

    for d in directions:
        var nr = row + d.r
        var nc = col + d.c
        if nr >= 0 and nr < max_rows and nc >= 0 and nc < max_cols:
            neighbors.append({"row": nr, "col": nc})
    return neighbors

# Проверка, есть ли дорога между двумя гексами
func has_road_between(row1: int, col1: int, row2: int, col2: int) -> bool:
    var key = _get_canonical_road_key(row1, col1, row2, col2)
    return road_segments.has(key)

# Получить все сегменты дорог (для отладки)
func get_all_road_segments() -> Dictionary:
    return road_segments.duplicate()
