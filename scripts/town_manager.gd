# town_manager.gd
# Менеджер городков (мелких поселений). На старте игры генерирует заданное
# число городков в случайных гексах рядом с точками тяготения, чтобы в
# дальнейшем их можно было использовать для торговли.
#
# --- Алгоритм размещения (каскадный, по ТЗ) ---
# Точки тяготения — четыре приоритета (именно в этом порядке):
#   1) гексы со стратегическими ресурсами (resource.strategic == true);
#      при этом один и тот же ресурс не притягивает несколько городков:
#      ресурс, в радиусе 3 от которого уже стоит городок, исключается
#      из списка точек притяжения для последующих городков;
#   2) гексы, по которым текут реки (river_edges непустой);
#   3) побережье озёр (гексы, соседние с terrain == "lake");
#   4) морское побережье (terrain == "beach").
#
# --- Вторичный приоритет: тип местности ---
# После первичного каскада позиция уточняется по предпочтительности
# terrain: равнина/песок(пляж) → холмы → болота/марши → горы. Первичные
# тяготения при этом сохраняются (гекс обязан удовлетворять им всем),
# поэтому водные правила остаются жёсткими. Если подходящий terrain
# не нашёлся рядом — городок остаётся на текущем валидном гексе.
#
# Водные приоритеты (река / озеро / море) — ЖЁСТКИЕ: если городок «решил»
# спавниться у воды, он ставится НЕПОСРЕДСТВЕННО на гекс точки тяготения
# (расстояние 0): на речной гекс, на берег озера или на пляж у моря —
# а не в пределах 3 гексов от воды.
#
# Для каждого городка:
#   - Берётся ПЕРВЫЙ непустой приоритет как «основной». Если в нём есть
#     валидное место (в радиусе приоритета: 0 для воды, 3 для стратегических
#     ресурсов; при 0 — строго на самой точке тяготения) — городок ставится
#     туда.
#   - Затем идут ШАГИ УТОЧНЕНИЯ: для каждого следующего непустого приоритета
#     ищем в небольшом радиусе (REFINEMENT_RADIUS) от текущей позиции
#     такой гекс, который одновременно:
#       (а) в радиусе приоритета от какой-то точки уже «удовлетворённых»
#           приоритетов (для воды — строго на её точке);
#       (б) в радиусе приоритета от какой-то точки НОВОГО приоритета.
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
#   - не гекс с ресурсом (в т.ч. стратегическим): к ресурсу тяготеем,
#     но встаём рядом, а не на нём; попадание на ресурс = реролл поиска;
#   - на прибрежном пляже у моря — можно (приоритет «морское побережье»);
#   - не гекс города игрока;
#   - не гекс другого городка и не ближе MIN_DISTANCE_BETWEEN_TOWNS, а
#     также не внутри чужого кольца влияния (эффективный минимум =
#     max(MIN_DISTANCE_BETWEEN_TOWNS, influence_radius соседа + 1));
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
# Радиус тяготения для водных приоритетов (река / озеро / море): 0 = городок
# ставится строго НА гексе точки тяготения (речной гекс / берег озера / пляж),
# а не в округе.
const WATER_ATTRACTION_RADIUS := 0
# Вторичный приоритет: уточнение по типам местности (в порядке предпочтения).
# Первичные приоритеты (ресурсы / река / озеро / море) остаются ОБЯЗАТЕЛЬНЫМИ;
# тип местности — мягкое уточнение поверх них: после основного каскада
# пробуем переехать на гекс с более предпочтительным terrain, не теряя
# заработанных первичных тяготений. Список: равнина + «песок» (пляж у моря),
# холмы, болота/марши, горы (последнее средство).
const TERRAIN_PREFERENCE: Array = [
    ["plain", "beach"],
    ["hill"],
    ["swamp", "marsh"],
    ["mountain"],
]
# Радиус поиска при «уточнении» позиции на следующем приоритете (в гексах).
# Уточнение ищет гекс в REFINEMENT_RADIUS от текущей позиции, который
# удовлетворяет ВСЕМ уже набранным приоритетам + новому.
const REFINEMENT_RADIUS := 2
# Базовая минимальная дистанция между двумя городками (рассредоточение).
# Фактический минимум в _is_valid_town_hex = МАКСИМУМ из этой константы и
# (influence_radius соседа + 1): центр нового городка не должен попадать
# в чужое кольцо влияния.
const MIN_DISTANCE_BETWEEN_TOWNS := 3
# Максимум попыток найти валидный гекс для одного городка в пределах
# одного шага (ищем другую опорную точку того же приоритета, если возле
# текущей опорной точки не нашлось подходящего гекса).
const MAX_TOWN_PLACEMENT_ATTEMPTS := 50

# === Кольцо влияния городка ===
# Каждый городок имеет «кольцо влияния» — зону вокруг себя, внутри которой
# игрок не может ничего строить. Это отражает тот факт, что вокруг чужого
# поселения земля фактически «занята» (поля, выпасы, инфраструктура).
#
# Правила:
#   1. Базовый диск: все гексы на расстоянии 0..INFLUENCE_MAX_RADIUS от городка.
#   2. Асимметрия: чтобы кольцо не выглядело идеальным кругом, в одной
#      случайной «стороне» (из 6) отбрасываем 1-3 гекса на расстоянии 3
#      (формируем «выемку»). Сторона и набор гексов выбираются детерминированно
#      от координат городка — одинаковый результат между загрузками.
#   3. Если в радиусе INFLUENCE_MAX_RADIUS есть ресурс — кольцо ОБЯЗАНО
#      включать гекс с ресурсом И кратчайший путь от городка до ресурса.
#      Без этого «выемка» из шага 2 могла бы окружить ресурс, оставив его
#      крошечным «анклавом» доступной земли посреди запретной зоны.
#
# Кольцо пересчитывается из town_hexes при загрузке сейва, поэтому
# отдельно его в сейв НЕ сохраняем — входные данные (городки и ресурсы)
# уже там есть.
const INFLUENCE_MAX_RADIUS := 3
# Цвет заливки: светло-голубой с заметной, но не «глухой» прозрачностью.
# Подбирался так, чтобы быть видимым на любой местности, но не перекрывать
# иконки ресурсов/улучшений/городка.
const INFLUENCE_FILL_COLOR := Color(0.45, 0.75, 1.0, 0.22)
# Шанс того, что выемка на расстоянии 3 действительно «съест» гекс в
# выбранной стороне. 0.6 — в среднем ~2 гекса выпадают из диска, что
# даёт заметную, но не агрессивную асимметрию.
const INFLUENCE_NOTCH_PROBABILITY := 0.6
# Максимум гексов, которые можно отбросить в выемке на расстоянии 3.
# 3 — «съедаем» почти целый сектор из 6 гексов на краю.
const INFLUENCE_NOTCH_MAX_DROPS := 3

# ===== Структура данных: список городков =====
# ЕДИНЫЙ источник истины по городкам — массив записей `towns`. Каждая запись
# — Dictionary с полными данными:
#   id                  — уникальный стабильный id ("town_N");
#   row, col            — координаты гекса-центра;
#   name                — имя (пока пустое, генератор имён появится позже);
#   is_era2_guaranteed  — справочная метка «добавлен для гарантии видимости
#                         в эру-2»;
#   border_color        — [r, g, b, a] цвет границ кольца (генерируется
#                         детерминированно на спавне и СОХРАНЯЕТСЯ в сейв);
#   influence_radius    — радиус кольца влияния (число, а не константа:
#                         кольцо может расти/сжиматься у разных городков);
#   influence_hexes     — ЛИЧНОЕ кольцо городка: Array of {row, col};
#   sell_pool, buy_pool — (будущее) пулы торговли: что городок продаёт и
#                         что хочет купить.
#
# Запись целиком сохраняется в сейв (serialize_towns) и восстанавливается
# из него (load_towns), поэтому любые будущие поля городка просто добавляются
# в словарь без изменения форматов других сущностей.
var towns: Array = []

# Производные списки — плоские зеркала `towns` для обратной совместимости
# (рендерер и main_map). Напрямую не редактируются, пересобираются из `towns`.
#   town_hexes            — Array of {row, col};
#   town_influence_hexes  — плоский список гексов колец ВСЕХ городков.
var town_hexes: Array = []
var town_influence_hexes: Array = []


# Создаёт новую запись городка. Имя пока пустое (будущий генератор имён).
# Личное кольцо influence_hexes заполняется compute_all_town_influences().
func _make_town_record(town_index: int, row: int, col: int,
        is_era2_guaranteed: bool) -> Dictionary:
    return {
        "id": "town_%d" % town_index,
        "row": row,
        "col": col,
        "name": "",
        "is_era2_guaranteed": is_era2_guaranteed,
        "border_color": _make_border_color(town_index),
        "influence_radius": INFLUENCE_MAX_RADIUS,
        "influence_hexes": [],
        "sell_pool": [],
        "buy_pool": [],
    }


# Детерминированный цвет границ кольца городка по его индексу. Золотой угол
# (φ-1 ≈ 0.618) даёт равномерный разброс оттенков по кругу — даже соседние
# по индексу городки выглядят по-разному. Цвет записывается в запись города
# и сохраняется в сейв, поэтому не «поедет», если городок удалят/переставят.
# Округляем компоненты: 32-битный Color теряет точность при JSON round-trip,
# а округлённые до 3 знаков значения сериализуются и восстанавливаются
# бит-в-бит.
func _make_border_color(town_index: int) -> Array:
    var hue := fposmod(float(town_index) * 0.618033988749895, 1.0)
    var c := Color.from_hsv(hue, 0.85, 0.95, 1.0)
    return [snappedf(c.r, 0.001), snappedf(c.g, 0.001), snappedf(c.b, 0.001), 1.0]


# Пересобирает производный town_hexes из master-списка towns.
func _rebuild_derived_town_hexes() -> void:
    town_hexes = []
    for t in towns:
        town_hexes.append({
            "row": int(t.row),
            "col": int(t.col),
            "is_era2_guaranteed": bool(t.get("is_era2_guaranteed", false)),
        })


# Восстанавливает список гексов кольца из формата [[row, col], ...].
func _restore_hex_list(entries: Array) -> Array:
    var result: Array = []
    for e in entries:
        if e is Array and e.size() >= 2:
            result.append({"row": int(e[0]), "col": int(e[1])})
    return result


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
    # «накапливать» старые пометки. Сбрасываем и master-список towns, и
    # производные зеркала. ПРИМЕЧАНИЕ: используем clear(), а не `=` — так
    # ссылка main_map.towns на этот массив не рвётся при повторной генерации.
    towns.clear()
    town_hexes = []
    town_influence_hexes = []
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
            print("town_manager: не удалось разместить городок #", towns.size() + 1,
                    " (нет валидных мест ни в одном приоритете)")
            continue
        var new_town := _make_town_record(towns.size(), placed.row, placed.col, false)
        towns.append(new_town)
        town_hexes.append({"row": placed.row, "col": placed.col})
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
            # Флаг is_era2_guaranteed — справочная метадата («этот городок
            # был добавлен специально для гарантии видимости в эре 2»).
            # В compute_town_influence сейчас не используется: клип на
            # стартовом Регионе применяется ко ВСЕМ городкам одинаково.
            # Флаг сохранён в сейве и в записи городка на случай будущих
            # механик, которым понадобится различать «обычные» и
            # «гарантийные» городки.
            var forced_town := _make_town_record(towns.size(), forced.row, forced.col, true)
            towns.append(forced_town)
            town_hexes.append({"row": forced.row, "col": forced.col, "is_era2_guaranteed": true})
            tile_data[forced.row][forced.col]["has_town"] = true
            print("town_manager: гарантия эры-2 — добавлен городок на (",
                    forced.row, ",", forced.col, ")")
        else:
            print("town_manager: гарантия эры-2 НЕ выполнена — нет валидного ",
                    "гекса в новой полосе (вероятно, всё вода/непроходимо)")

    # Кольца влияния строятся ПОСЛЕ размещения всех городков (включая
    # гарантийный для эры-2), потому что при обходе ресурсов в радиусе 3
    # от каждого городка нужны финальные позиции И все ресурсы уже на карте.
    # Границы стартового Региона (exclusion_*) нужны для клипа колец всех
    # городков — иначе кольца, залезающие в Регион, «выдают» чужой городок
    # в неисследованной зоне в 1-й эпохе.
    compute_all_town_influences(tile_data, rows, cols,
            exclusion_start_row, exclusion_end_row,
            exclusion_start_col, exclusion_end_col)

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

    # Собираем все приоритеты один раз (дешевле, чем на каждый шаг).
    # Каждый приоритет — словарь {name, points, radius}:
    #   radius — максимальное гекс-расстояние от точки тяготения до гекса
    #   городка. Для воды (река/озеро/море) радиус 0: спавн строго на самой
    #   точке (речной гекс, берег озера, пляж у моря).
    var tiers: Array = [
        {"name": "strategic", "points": _collect_strategic_attraction_points(tile_data, rows, cols), "radius": MAX_ATTRACTION_DISTANCE},
        {"name": "river", "points": _collect_river_attraction_points(tile_data, rows, cols), "radius": WATER_ATTRACTION_RADIUS},
        {"name": "lake_coast", "points": _collect_lake_coast_attraction_points(tile_data, rows, cols), "radius": WATER_ATTRACTION_RADIUS},
        {"name": "sea_coast", "points": _collect_sea_coast_attraction_points(tile_data, rows, cols), "radius": WATER_ATTRACTION_RADIUS},
    ]

    # Первый непустой приоритет — «основной». С него стартуем каскад.
    var primary_idx := -1
    for i in range(tiers.size()):
        if not tiers[i]["points"].is_empty():
            primary_idx = i
            break
    if primary_idx == -1:
        return {}

    # Шаг 1: ищем валидный гекс в радиусе приоритета от его точки.
    var best: Dictionary = _find_hex_near_tier(tile_data, rows, cols,
            tiers[primary_idx]["points"], tiers[primary_idx]["radius"],
            city_row, city_col,
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
    var satisfied_names: Array = [tiers[primary_idx]["name"]]

    # Шаги 2..N: для каждого следующего непустого приоритета пытаемся
    # уточнить позицию так, чтобы гекс одновременно лежал в радиусе 3 от
    # всех ранее заработанных приоритетов И от нового.
    for tier_idx in range(primary_idx + 1, tiers.size()):
        if tiers[tier_idx]["points"].is_empty():
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
            satisfied_names.append(tiers[tier_idx]["name"])

    # --- Вторичный приоритет: уточнение по типам местности ---
    # Первичные тяготения уже «заработаны» и должны сохраниться: ищем гекс
    # с более предпочтительным terrain, который по-прежнему удовлетворяет
    # ВСЕМ первичным приоритетам. Группы перебираем по порядку предпочтения;
    # если ни одна не подошла — остаёмся на текущем (валидном) гексе.
    var cur_terrain: String = tile_data[best.row][best.col].get("terrain", "")
    for group in TERRAIN_PREFERENCE:
        if group.has(cur_terrain):
            satisfied_names.append("terrain:" + str(group[0]))
            break
        var moved: Dictionary = _find_hex_in_radius_satisfying(tile_data, rows, cols,
                best, REFINEMENT_RADIUS, satisfied_tiers,
                city_row, city_col,
                exclusion_start_row, exclusion_end_row,
                exclusion_start_col, exclusion_end_col,
                require_in_region_start_row, require_in_region_end_row,
                require_in_region_start_col, require_in_region_end_col,
                ignore_exclusion,
                group)
        if not moved.is_empty():
            best = moved
            satisfied_names.append("terrain:" + str(group[0]))
            break

    if satisfied_names.size() > 1:
        print("town_manager: городок (", best.row, ",", best.col, ") — каскад ",
                "приоритетов: ", ", ".join(satisfied_names))
    return best


# Ищет валидный гекс городка в радиусе max_dist от ЛЮБОЙ точки
# attraction_points (max_dist == 0 — строго на самой точке). Никаких
# ограничений «near_hex» — это первичный поиск, не уточнение.
# Возвращает {row, col} или {} если ничего не нашлось.
func _find_hex_near_tier(tile_data: Array, rows: int, cols: int,
        attraction_points: Array, max_dist: int,
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
        # Случайный валидный гекс вокруг anchor, отфильтрованный
        # по гекс-расстоянию <= max_dist (0 — только сам anchor).
        var candidates: Array = []
        var r_min: int = maxi(0, anchor.row - max_dist)
        var r_max: int = mini(rows - 1, anchor.row + max_dist)
        var c_min: int = maxi(0, anchor.col - max_dist)
        var c_max: int = mini(cols - 1, anchor.col + max_dist)
        for r in range(r_min, r_max + 1):
            for c in range(c_min, c_max + 1):
                if HexUtils.hex_distance(r, c, anchor.row, anchor.col) > max_dist:
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
# в радиусе (radius) хотя бы от одной точки КАЖДОГО из
# attraction_point_sets (накопленные приоритеты + новый; каждый набор —
# словарь {points, radius}). Возвращает {row, col} или {} если ничего
# не нашлось.
func _find_hex_in_radius_satisfying(tile_data: Array, rows: int, cols: int,
        near_hex: Dictionary, max_dist_from_near: int,
        attraction_point_sets: Array,
        city_row: int, city_col: int,
        exclusion_start_row: int, exclusion_end_row: int,
        exclusion_start_col: int, exclusion_end_col: int,
        require_in_region_start_row: int, require_in_region_end_row: int,
        require_in_region_start_col: int, require_in_region_end_col: int,
        ignore_exclusion: bool,
        allowed_terrains: Array = []) -> Dictionary:
    var candidates: Array = []
    var r_min: int = maxi(0, near_hex.row - max_dist_from_near)
    var r_max: int = mini(rows - 1, near_hex.row + max_dist_from_near)
    var c_min: int = maxi(0, near_hex.col - max_dist_from_near)
    var c_max: int = mini(cols - 1, near_hex.col + max_dist_from_near)
    for r in range(r_min, r_max + 1):
        for c in range(c_min, c_max + 1):
            if HexUtils.hex_distance(r, c, near_hex.row, near_hex.col) > max_dist_from_near:
                continue
            # Гекс должен быть в радиусе приоритета хотя бы от одной точки
            # КАЖДОГО набора приоритетов. Это «AND» по наборам, «OR» внутри
            # набора. Для водных приоритетов radius == 0 — строго на точке.
            var all_satisfied: bool = true
            for tier in attraction_point_sets:
                var any_close: bool = false
                for p in tier["points"]:
                    if HexUtils.hex_distance(r, c, p.row, p.col) <= int(tier.get("radius", MAX_ATTRACTION_DISTANCE)):
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
            # Вторичный фильтр по типу местности (пустой список = любой).
            if not allowed_terrains.is_empty():
                var terr: String = tile_data[r][c].get("terrain", "")
                if not allowed_terrains.has(terr):
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
    # Пляж разрешён: приоритет «морское побережье» требует ставить городок
    # НЕПОСРЕДСТВЕННО на прибрежном гексе (terrain == "beach"), а не вглубь.

    # Уже есть постройка (от другой системы) — нельзя.
    if tile.get("improvement", null) != null:
        return false
    # Гекс с ресурсом — нельзя: городок не должен занимать ресурс напрямую
    # (в т.ч. стратегический — к нему тяготеем, но встаём РЯДОМ, в радиусе
    # MAX_ATTRACTION_DISTANCE, а не на самом гексе). Если поиск привёл на
    # такой гекс — он отбраковывается здесь, и поиск «рероллится»:
    # _find_hex_near_tier пробует другую точку того же приоритета, а если
    # валидных мест нет вовсе — приоритет пропускается.
    var res = tile.get("resource", null)
    if res != null and res != "":
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

    # Центр нового городка не должен попадать в чужое кольцо влияния:
    # минимальная дистанция = радиус влияния соседа + 1. Базовое
    # рассредоточение MIN_DISTANCE_BETWEEN_TOWNS тоже остаётся в силе —
    # берём МАКСИМУМ из двух ограничений. Обходим towns (master-список
    # с influence_radius), а не производное town_hexes: при будущих
    # механиках роста/сжатия колец правило подстроится автоматически.
    for t in towns:
        var eff_min: int = maxi(MIN_DISTANCE_BETWEEN_TOWNS,
                int(t.get("influence_radius", INFLUENCE_MAX_RADIUS)) + 1)
        if HexUtils.hex_distance(row, col, int(t.row), int(t.col)) < eff_min:
            return false
    return true


func _is_impassable_terrain(terrain_id: String) -> bool:
    var t: Dictionary = GameData.terrains.get(terrain_id, {})
    return int(t.get("move_cost", 1)) >= 999


# --- Сбор точек тяготения по приоритетам ---

# Приоритет 1: гексы со стратегическими ресурсами (resource.strategic == true).
# Ресурс, в радиусе MAX_ATTRACTION_DISTANCE от которого УЖЕ стоит городок,
# исключается: один и тот же заспавнившийся ресурс не должен притягивать
# несколько городков одновременно. town_hexes пополняется по мере размещения,
# поэтому фильтр работает автоматически для каждого следующего городка
# (включая гарантийный городок эры-2).
func _collect_strategic_attraction_points(tile_data: Array, rows: int, cols: int) -> Array:
    var result: Array = []
    for r in range(rows):
        for c in range(cols):
            var res = tile_data[r][c].get("resource", null)
            if res == null or res == "":
                continue
            var res_data: Dictionary = GameData.raw_resources.get(res, {})
            if not bool(res_data.get("strategic", false)):
                continue
            var claimed := false
            for h in town_hexes:
                if HexUtils.hex_distance(r, c, h.row, h.col) <= MAX_ATTRACTION_DISTANCE:
                    claimed = true
                    break
            if not claimed:
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
# Городки сериализуются как массив словарей — по одной записи towns на
# городок. Так в сейв попадают ВСЕ данные городка: id, имя, цвет границ,
# радиус и личное кольцо влияния, пулы торговли. Словарь сохраняется в JSON
# напрямую (борщи Color не хранится — для цвета используем массив [r,g,b,a]).
# Благодаря полной записи будущие поля городка добавляются в serialize/load
# симметрично, без изменения форматов других сущностей.

func serialize_towns() -> Array:
    var result: Array = []
    for t in towns:
        var hexes: Array = []
        for h in t.get("influence_hexes", []):
            hexes.append([int(h.row), int(h.col)])
        result.append({
            "id": str(t.get("id", "")),
            "row": int(t.row),
            "col": int(t.col),
            "name": str(t.get("name", "")),
            "is_era2_guaranteed": bool(t.get("is_era2_guaranteed", false)),
            "border_color": t.get("border_color", [1.0, 1.0, 1.0, 1.0]),
            "influence_radius": int(t.get("influence_radius", INFLUENCE_MAX_RADIUS)),
            "influence_hexes": hexes,
            "sell_pool": t.get("sell_pool", []),
            "buy_pool": t.get("buy_pool", []),
        })
    return result


# Восстанавливает towns из сейва. Понимает два формата:
#   - НОВЫЙ: словарь записи города (id, имя, радиус, личное кольцо, цвет…);
#   - СТАРЫЙ: [row, col] / [row, col, is_era2_guaranteed] — эпоха кольца
#     неизвестна, поэтому при миграции радиус берётся по умолчанию,
#     личное кольцо пересчитается в compute_all_town_influences().
# Если данных нет / массив пуст (новая игра) — towns не трогаем (обычно уже
# заполнен generate_towns, вызванным из _initialize_map).
func load_towns(data) -> void:
    if data == null:
        return
    if not (data is Array):
        return
    if data.is_empty():
        return

    towns.clear()
    town_hexes = []
    town_influence_hexes = []
    for entry in data:
        if entry is Dictionary:
            # Новый формат: полная запись городка.
            var t := {
                "id": str(entry.get("id", "")),
                "row": int(entry.get("row", 0)),
                "col": int(entry.get("col", 0)),
                "name": str(entry.get("name", "")),
                "is_era2_guaranteed": bool(entry.get("is_era2_guaranteed", false)),
                "border_color": entry.get("border_color", [1.0, 1.0, 1.0, 1.0]),
                "influence_radius": int(entry.get("influence_radius", INFLUENCE_MAX_RADIUS)),
                # Личное кольцо из сейва — источник истины для загружаемой
                # партии (кольцо могло быть изменено механиками).
                "influence_hexes": _restore_hex_list(entry.get("influence_hexes", [])),
                "sell_pool": entry.get("sell_pool", []),
                "buy_pool": entry.get("buy_pool", []),
            }
            towns.append(t)
        elif entry is Array and entry.size() >= 2:
            # Миграция старого формата: [row, col] / [row, col, flag].
            # Кольца нет — вычислится в compute_all_town_influences.
            var is_era2_guaranteed: bool = entry.size() >= 3 and bool(entry[2])
            var t := _make_town_record(towns.size(), int(entry[0]), int(entry[1]),
                    is_era2_guaranteed)
            towns.append(t)
        else:
            printerr("town_manager: пропущена битая запись городка в сейве: ", entry)
    _rebuild_derived_town_hexes()
    print("town_manager: из сейва восстановлено городков=", towns.size())


# === Кольцо влияния городка ===

# Вычисляет кольцо влияния для ВСЕХ размещённых городков. Заполняет
# town_influence_hexes (плоское зеркало) и ЛИЧНОЕ кольцо каждого городка
# (town["influence_hexes"]). Вызывается:
#   - из generate_towns после размещения всех городков (включая гарантийный
#     для эры-2) — старт новой игры;
#   - из main_map при загрузке сейва — кольца восстанавливаются.
#
# Личное кольцо городка, ВОССТАНОВЛЕННОЕ из сейва, является источником истины:
# оно может отличаться от «расчёта по радиусу» (кольцо меняется механиками),
# поэтому для загруженной партии используем сохранённый список as-is. Если
# кольца нет (новая игра либо мигрированный старый сейв) — считаем заново
# по текущему радиусу городка через compute_town_influence(). На тайлы при
# любом варианте проставляется флаг in_town_influence.
#
# Кольца разных городков НЕ пересекаются. Городки обрабатываются в порядке
# массива towns (порядок размещения; для сейва — порядок записей): гекс, уже
# вошедший в кольцо более раннего городка, исключается из кольца текущего —
# принцип «кто первый встал, того и тапки». У «опоздавшего» городка остаётся
# кольцо, срезанное со стороны соседа. Обрезанный состав кольца сохраняется
# в запись городка (и в сейв), поэтому повторный пересчёт идемпотентен.
#
# Параметры start_region_* задают границы стартового Региона игрока
# (видимая область в 1-й эпохе: Кольцо + Регион). Используются для клипа
# колец при расчёте (и для новых игр, и для мигрированных сейвов): иначе
# любое кольцо, залезающее в Регион, «выдаёт» чужой городок в неисследованной
# зоне в 1-й эпохе. Если передано -1 (или start > end), клип отключён.
func compute_all_town_influences(tile_data: Array, map_rows: int, map_cols: int,
        start_region_start_row: int = -1, start_region_end_row: int = -1,
        start_region_start_col: int = -1, start_region_end_col: int = -1) -> void:
    # Перед пересчётом снимаем старые флаги in_town_influence со ВСЕХ гексов —
    # иначе при изменении состава городков (например, удалении/добавлении)
    # старые пометки останутся на гексах, которые больше не входят ни в одно
    # кольцо. Флаг has_town НЕ трогаем — он управляется в generate_towns.
    for r in range(map_rows):
        for c in range(map_cols):
            if tile_data[r] != null and c < tile_data[r].size() \
                    and tile_data[r][c] != null:
                tile_data[r][c]["in_town_influence"] = false

    town_influence_hexes = []
    # Таблица «заявленных» гексов: ключ "r,c" -> true. Городки обходятся в
    # порядке массива towns (порядок размещения; для сейва — порядок записей),
    # поэтому гекс, впервые заявленный одним городком, не может попасть в
    # кольцо другого. Это принцип «кто первый встал, того и тапки»: кольца
    # НИКОГДА не пересекаются, а у более позднего городка кольцо просто
    # срезается со стороны соседа.
    var claimed: Dictionary = {}
    for t in towns:
        var ring: Array = t.get("influence_hexes", [])
        if ring.is_empty():
            # Личного кольца ещё нет (новая игра / старый сейв) — считаем
            # по радиусу этого городка и сохраняем в его запись.
            ring = compute_town_influence(tile_data, map_rows, map_cols,
                    int(t.row), int(t.col), t,
                    start_region_start_row, start_region_end_row,
                    start_region_start_col, start_region_end_col,
                    int(t.get("influence_radius", INFLUENCE_MAX_RADIUS)))
        # Клип личного кольца: гексы, уже заявленные более ранним городком,
        # отбрасываем и НЕ записываем в кольцо этого городка. Заливка и
        # границы (рендерер строит их по influence_hexes) у разных городков
        # поэтому гарантированно не пересекаются. Обрезанное кольцо попадает
        # в запись городка и затем в сейв (serialize_towns).
        var clipped: Array = []
        for rh in ring:
            var key := "%d,%d" % [int(rh.row), int(rh.col)]
            if claimed.has(key):
                continue
            claimed[key] = true
            clipped.append(rh)
            # Проставляем флаг на тайле — build_manager и валидаторы читают
            # его напрямую, без поиска по списку.
            if rh.row >= 0 and rh.row < map_rows \
                    and rh.col >= 0 and rh.col < map_cols \
                    and tile_data[rh.row] != null and rh.col < tile_data[rh.row].size() \
                    and tile_data[rh.row][rh.col] != null:
                tile_data[rh.row][rh.col]["in_town_influence"] = true
            town_influence_hexes.append(rh)
        t["influence_hexes"] = clipped
    print("town_manager: всего гексов в кольцах влияния=", town_influence_hexes.size(),
            " (городков=", towns.size(), ")")

# Вычисляет кольцо влияния для ОДНОГО городка. Возвращает Array of
# {row, col} — список гексов в кольце. Подробности алгоритма (база,
# асимметрия, пути до ресурсов) — в комментарии к INFLUENCE_MAX_RADIUS.
#
# Параметры:
#   tile_data — 2D-массив гексов. Нужен для проверки tile.resource (шаг 3).
#   map_rows, map_cols — размеры карты (для обхода соседей в path-функции).
#   town_row, town_col — координаты городка, вокруг которого строится кольцо.
#   town_dict — запись города (словарь) из towns. Сейчас на клип НЕ влияет:
#     клип применяется ко всем городкам одинаково. Параметр оставлен для
#     будущих механик, которым понадобится различать городки.
#   start_region_* — границы стартового Региона. Передаются из main_map,
#     чтобы не лазить в GameData из town_manager (town_manager не знает,
#     где Регион лежит на карте). Используются для клипа колец.
#   radius — радиус кольца для ЭТОГО городка (per-town). По умолчанию
#     INFLUENCE_MAX_RADIUS; будущие механики роста/сжатия кольца передают
#     сюда радиус из записи города.
func compute_town_influence(tile_data: Array, map_rows: int, map_cols: int,
        town_row: int, town_col: int, town_dict: Dictionary = {},
        start_region_start_row: int = -1, start_region_end_row: int = -1,
        start_region_start_col: int = -1, start_region_end_col: int = -1,
        radius: int = INFLUENCE_MAX_RADIUS) -> Array:
    var ring: Dictionary = {}  # ключ "r,c" -> true для быстрой проверки членства
    var rng := RandomNumberGenerator.new()
    # Стабильный seed: каждая комбинация (row, col) даёт уникальный,
    # но воспроизводимый между сессиями сид. Простые простые числа — чтобы
    # соседние по карте городки получали максимально разные выемки.
    rng.seed = town_row * 1009 + town_col * 7919

    # --- Шаг 1: базовый диск (расстояние 0..radius) ---
    var r_min: int = maxi(0, town_row - radius)
    var r_max: int = mini(map_rows - 1, town_row + radius)
    var c_min: int = maxi(0, town_col - radius)
    var c_max: int = mini(map_cols - 1, town_col + radius)
    for r in range(r_min, r_max + 1):
        for c in range(c_min, c_max + 1):
            if HexUtils.hex_distance(r, c, town_row, town_col) <= radius:
                ring["%d,%d" % [r, c]] = true

    # --- Шаг 2: асимметрия — отбрасываем 1-3 гекса на расстоянии 3
    # в одной «стороне» (из 6). Сторона выбирается случайно, но
    # детерминированно от seed.
    var notch_side: int = rng.randi_range(0, 5)
    var outer_dropped: int = 0
    for r in range(r_min, r_max + 1):
        for c in range(c_min, c_max + 1):
            if outer_dropped >= INFLUENCE_NOTCH_MAX_DROPS:
                break
            if not ring.has("%d,%d" % [r, c]):
                continue
            var d: int = HexUtils.hex_distance(r, c, town_row, town_col)
            if d != radius:
                continue
            if _hex_side(town_row, town_col, r, c) != notch_side:
                continue
            if rng.randf() < INFLUENCE_NOTCH_PROBABILITY:
                ring.erase("%d,%d" % [r, c])
                outer_dropped += 1
        if outer_dropped >= INFLUENCE_NOTCH_MAX_DROPS:
            break

    # --- Шаг 3: для каждого ресурса в радиусе radius
    # добавляем гекс с ресурсом и кратчайший путь от городка.
    # Защита от «анклавов»: если выемка из шага 2 окружила ресурс, игрок
    # мог бы получить маленький «островок» доступной земли посреди
    # запретной зоны. Путь «пришивает» ресурс обратно к кольцу.
    for r in range(r_min, r_max + 1):
        for c in range(c_min, c_max + 1):
            if HexUtils.hex_distance(r, c, town_row, town_col) > radius:
                continue
            var tile = tile_data[r][c]
            if tile == null:
                continue
            var res = tile.get("resource", null)
            if res == null or res == "":
                continue
            # crop_bred НЕ учитываем: одомашненный ресурс появляется ПОСЛЕ
            # того, как игрок построил ферму/пастбище, и в этой точке кольцо
            # уже давно вычислено. Учитываем только «природные» ресурсы.
            var path: Array = _path_between(town_row, town_col, r, c, map_rows, map_cols)
            for ph in path:
                ring["%d,%d" % [ph.row, ph.col]] = true

    # --- Шаг 4: клип кольца на стартовом Регионе.
    # В 1-й эпохе игрок не должен видеть «чужую территорию» в своём
    # неисследованном Регионе: и сами городки, и их кольца должны быть
    # невидимы. Сами городки скрыты через current_era-проверку в рендерере
    # (PHASE 1.6), но кольца рисуются в видимой области по данным
    # town_influence_hexes — без клипа любое кольцо, залезающее в Регион,
    # «выдаёт» присутствие чужого городка. Клип применяется ко ВСЕМ
    # городкам (а не только к гарантийному эры-2): случайные городки тоже
    # могут оказаться у границы Региона, особенно на маленьких картах,
    # и без клипа их кольца подсвечивали бы часть неисследованной зоны.
    if start_region_start_row >= 0 and start_region_end_row >= 0 \
            and start_region_start_col >= 0 and start_region_end_col >= 0 \
            and start_region_start_row <= start_region_end_row \
            and start_region_start_col <= start_region_end_col:
        var keys_to_remove: Array = []
        for key in ring.keys():
            var parts: PackedStringArray = key.split(",")
            var rr: int = int(parts[0])
            var cc: int = int(parts[1])
            if rr >= start_region_start_row and rr <= start_region_end_row \
                    and cc >= start_region_start_col and cc <= start_region_end_col:
                keys_to_remove.append(key)
        for key in keys_to_remove:
            ring.erase(key)
        if keys_to_remove.size() > 0:
            print("town_manager: кольцо городка (", town_row, ",", town_col,
                    ") обрезано на ", keys_to_remove.size(),
                    " гекс(ов) стартового Региона")

    # --- Конвертация словаря в Array of {row, col} ---
    var result: Array = []
    for key in ring.keys():
        var parts: PackedStringArray = key.split(",")
        result.append({"row": int(parts[0]), "col": int(parts[1])})
    return result


# Возвращает «сторону» (0..5) гекса (r, c) относительно центра (tr, tc).
# Используется для группировки гексов вокруг городка в 6 секторов по 60°,
# чтобы асимметричная выемка из compute_town_influence «съедала» гексы
# в ОДНОМ направлении, а не вразброс.
#
# Стороны нумеруются по часовой стрелке от «востока» (0=E, 1=SE, 2=S,
# 3=W, 4=NW, 5=NE). Соседние стороны различаются на 60°, что совпадает
# с углами между соседями гекса — поэтому гексы одного сектора лежат
# «примерно» в одном направлении от центра.
func _hex_side(tr: int, tc: int, r: int, c: int) -> int:
    var tr_pos: Vector2 = HexUtils.hex_center(tr, tc, 1.0)
    var h_pos: Vector2 = HexUtils.hex_center(r, c, 1.0)
    # atan2 в Godot: Y растёт вниз, поэтому стандартные «математические» углы
    # отсчитываются ПРОТИВ часовой стрелки от востока. Это нас устраивает —
    # нам важен не знак поворота, а разбиение плоскости на 6 равных секторов.
    var angle_rad: float = atan2(h_pos.y - tr_pos.y, h_pos.x - tr_pos.x)
    var angle_deg: float = rad_to_deg(angle_rad)
    if angle_deg < 0.0:
        angle_deg += 360.0
    # +30° сдвигает границы секторов так, что «восток» (angle ≈ 0)
    # попадает ровно в центр сектора 0, а не на его границу.
    return int((angle_deg + 30.0) / 60.0) % 6


# Возвращает кратчайший «жадный» путь от (fr, fc) к (tr, tc) через
# шестиугольных соседей, ВКЛЮЧАЯ обе конечные точки.
#
# Алгоритм: на каждом шаге выбираем соседа с минимальным hex_distance
# до цели (тай-брейк — порядок из get_neighbors_odd_r, т.е. детерминирован).
# Это даёт ОДИН ИЗ кратчайших путей; его длина == hex_distance + 1,
# что для расстояний ≤ 3 (радиус нашего кольца) не выходит за пределы
# диска. Если карта маленькая и путь «упирается» в край, get_neighbors_odd_r
# вернёт меньше 6 соседей и цикл остановится (safety на 16 шагов —
# страховка от вырожденного случая, в нормальной ситуации не срабатывает).
func _path_between(fr: int, fc: int, tr: int, tc: int,
        map_rows: int, map_cols: int) -> Array:
    var path: Array = [{"row": fr, "col": fc}]
    var cur_r: int = fr
    var cur_c: int = fc
    var safety: int = 0
    while (cur_r != tr or cur_c != tc) and safety < 16:
        safety += 1
        var neighbors: Array = HexUtils.get_neighbors_odd_r(cur_r, cur_c, map_rows, map_cols)
        var best: Dictionary = {}
        var best_dist: int = 999999
        for n in neighbors:
            var d: int = HexUtils.hex_distance(n.row, n.col, tr, tc)
            if d < best_dist:
                best_dist = d
                best = n
        if best.is_empty():
            break
        cur_r = int(best.row)
        cur_c = int(best.col)
        path.append({"row": cur_r, "col": cur_c})
    return path

