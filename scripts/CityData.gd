# CityData.gd (Autoload)
@tool
extends Node

# Склад и производство
var city_storage: Dictionary = {}
# Детализация склада по качеству: product_id -> { "common": N, "fine": N, ... }
# Сумма по всем уровням качества всегда равна city_storage[product_id].
var city_quality_detail: Dictionary = {}
# Фактические счётчики производства/потребления за текущий тик симуляции.
# Нужны для определения голода (CityData._check_population_change сравнивает
# суммы по food_pool) и для TopBar'а (city_ui._update_food_label — метка
# «Еда: N [+Y / -Z]» с фактом за тик, fallback на плановый при нулевом
# факте). Детализация по источникам (production_sources / consumption_sources)
# убрана из тултипа вкладки «Ресурсы» (см. коммит 5790016), и сами
# источники больше не ведутся.
var production_rates: Dictionary = {}
var consumption_rates: Dictionary = {}
var city_food_pool: Dictionary = {}
var city_built_buildings: Array = []
var domesticated_animals: Array = []
var domesticated_plants: Array = []
var domesticated_resources: Array = []
# Казна города (монеты). Всегда целое число; пополняется за счёт потребления
# ресурсов на внутреннем рынке (см. add_treasury / get_internal_market_price и
# docs.md, «Казна города и внутренний рынок»).
var treasury: int = 0

# Стройка зданий: ключ -> данные
var building_construction: Dictionary = {}

# Технологии
var unlocked_technologies: Array = []
var current_research_tech_id: String = ""
var current_research_science_cost: int = 0
var research_progress: float = 0.0
var research_science_accumulated: float = 0.0

# --- ТЕКУЩАЯ ЭПОХА ---
# Индекс текущей эпохи в GameData.eras (см. data/eras.json).
# Источник истины для ограничения «изучать можно только технологии
# текущей и предыдущих эпох». Синхронизируется с main_map.current_era
# при переходе эпохи и загрузке сохранения.
var current_era_index: int = 0

# Сообщения для HUD после завершения исследования (о найденных ресурсах)
var last_research_messages: Array = []

# --- НАСЕЛЕНИЕ ---
var total_population: int = 1
var idle_population: int = 1 # свободные жители (не занятые нигде)
# Название города — выбирается игроком в диалоге при старте новой игры.
# Пустая строка = имя ещё не задано (на карте тогда не рисуется).
var city_name: String = ""
var food_for_new_settler: int = 1000
var food_per_citizen: int = 10
# Дебаг-переключатель: потребляет ли население еду. Управляется из
# дебаг-меню (пункт «Переключение потребления еды»), НЕ сохраняется в сейв —
# это рантайм-обходной тумблер для отладки, а не игровое состояние.
var food_consumption_enabled: bool = true
# Дебаг-переключатель: игнорировать требования технологий. Когда включён —
# изучение не проверяет prerequisites и ограничение по эпохам (можно изучать
# технологии следующих эпох). Тумблер из дебаг-меню, НЕ сохраняется в сейв.
# Изучается при этом только выбранная технология — предшественники не
# добавляются автоматически.
var ignore_tech_requirements: bool = false
# Дебаг-переключатель: игнорировать требования строительства. Когда включён —
# все здания в городе и все улучшения на карте строятся мгновенно (без очереди
# строек и без лимита одновременно строящихся объектов), а для зданий не
# проверяются дополнительные материалы (additional_cost) и дополнительные
# условия (additional_req). Тумблер из дебаг-меню, НЕ сохраняется в сейв.
var ignore_build_requirements: bool = false

# --- ТИК ИГРОВОЙ СИМУЛЯЦИИ ---
# Единый шаг всей игровой симуляции: производство улучшений и зданий (крафт
# слотов), потребление еды населением, профессиональное и городское потребление,
# корм пастбищ, базовый прирост науки и т.д. — всё тикает раз в SIMULATION_TICK
# секунд (шаг в main_map._process). Улучшения при этом выпускают продукцию по
# своему собственному интервалу — полю "production_interval" из
# data/improvements.json (см. get_improvement_production_interval).
const SIMULATION_TICK: float = 1.0

# --- ИНТЕРВАЛ ОТОБРАЖЕНИЯ РЕСУРСОВ (настройка «Настройки → Игра → Интервал
# обновления данных о ресурсах»). Симуляция тикает каждую SIMULATION_TICK
# секунды, а ОТОБРАЖЕНИЕ ресурсов (вкладка «Ресурсы», верхняя полоса города,
# тултип деталей здания, левая колонка панели управления, тултипы с ресурсами)
# обновляется не чаще resource_display_interval секунд.
#
# Механика — «эпоха отображения» (epoch): единый счётчик в autoload, который
# двигает main_map._process (на паузе дерева _process не идёт — интервал
# считается игровым временем). Каждое UI-место хранит последнюю увиденную
# эпоху и обновляется только когда она изменилась (resource_display_due) —
# так все места обновляются одновременно, одним «рывком» раз в интервал.
# Обновления по явным действиям игрока (открытие окна, клик по гексу, смена
# назначений, тумблер еды) эпоху НЕ ждут — они вызываются напрямую и после
# себя синхронизируют эпоху.
#
# Допустимые значения: 1..5 секунд с шагом 1: данные меняются только на
# тиках в 1 секунду, дробный интервал дал бы лишь неравномерный ритм
# обновлений (обновления попадали бы в разную фазу тиков) при неизменно
# корректных целых числах на экране.
var resource_display_interval: float = 1.0
var resource_display_epoch: int = 0
var _resource_display_accum: float = 0.0

# Устанавливает интервал отображения ресурсов (шаг 1, диапазон 1..5 сек).
# Смена значения сбрасывает накопитель и повышает эпоху — все места
# обновляются немедленно при ближайшей проверке. То же значение — no-op.
func set_resource_display_interval(value: float) -> void:
    var new_interval := clampf(roundf(value), 1.0, 5.0)
    if is_equal_approx(new_interval, resource_display_interval):
        return
    resource_display_interval = new_interval
    _resource_display_accum = 0.0
    resource_display_epoch += 1

# Накапливает игровое время и повышает эпоху, когда прошёл интервал.
# Вызывается из main_map._process каждый кадр.
func tick_resource_display(delta: float) -> void:
    if resource_display_interval <= 0.0:
        return
    _resource_display_accum += delta
    if _resource_display_accum >= resource_display_interval:
        # fmod удерживает фазу вместо копления бесконечного остатка: интервал
        # кратен шагу тика (1 сек), дробная часть почти не накапливается.
        _resource_display_accum = fmod(_resource_display_accum, resource_display_interval)
        resource_display_epoch += 1
        # Окно отображения разбивки казны обновляется своим ритмом
        # (treasury_window_length_sec, по умолчанию 3 сек — см.
        # DEFAULT_TREASURY_WINDOW_SEC). Привязка к эпохе ресурсов удобна
        # для UI (одной галочкой «обновились ресурсы → обновилась разбивка
        # казны»), но отрезок короче: эпоха тикает раз в
        # resource_display_interval (1..5 сек), а здесь считаем свои тики
        # тем же delta, что и ресурсная эпоха (ровный шаг 1 сек не нужен —
        # точность требует только «плюс-минус секунда»).
        _treasury_window_accum_sec += float(resource_display_interval)
        if _treasury_window_accum_sec >= treasury_window_length_sec:
            rotate_treasury_window()
            _treasury_window_accum_sec = 0.0

# Накопитель игрового времени для окна разбивки казны. Только здесь.
var _treasury_window_accum_sec: float = 0.0

# True, если место с последней проверки не обновляло отображение ресурсов.
# Вызывающий после обновления запоминает CityData.resource_display_epoch.
func resource_display_due(last_epoch: int) -> bool:
    return last_epoch != resource_display_epoch

# --- ЭПОХИ ---
# Возвращает индекс эпохи технологии в GameData.eras.
# Если технология не найдена или её era отсутствует в списке эпох — -1.
func get_tech_era_index(tech_id: String) -> int:
    var tech_data = _get_tech_data(tech_id)
    if tech_data == null:
        return -1
    var era_id: String = tech_data.get("era", "")
    for i in range(GameData.eras.size()):
        if GameData.eras[i].get("id", "") == era_id:
            return i
    return -1

# Разрешено ли изучать технологию по эпохам: можно только технологии
# текущей и предыдущих эпох. Технологии следующей эпохи недоступны,
# даже если все их prerequisites выполнены.
func is_tech_era_allowed(tech_id: String) -> bool:
    # Дебаг: при включённом «не учитывать требования» ограничение по эпохам
    # снимается — можно изучать технологии любой эпохи.
    if ignore_tech_requirements:
        return true
    var era_idx := get_tech_era_index(tech_id)
    # Технология без известной эпохи не блокируется (защита от некорректных данных).
    if era_idx < 0:
        return true
    return era_idx <= current_era_index

# Человекочитаемое имя эпохи по индексу; для некорректного индекса — пустая строка.
func _get_era_name_by_index(index: int) -> String:
    if index < 0 or index >= GameData.eras.size():
        return ""
    return GameData.eras[index].get("name", "")

# Переход в следующую эпоху. Вызывается из main_map.advance_to_next_era().
func advance_era() -> void:
    if current_era_index < GameData.eras.size() - 1:
        current_era_index += 1
    emit_signal("city_updated")

# --- НАУКА ---
# Базовый доход науки города (очков/сек). Город никогда не производит меньше
# этой скорости, даже без зданий науки — чтобы ранняя игра не блокировалась.
const BASE_SCIENCE_PER_SEC: float = 1.0
# Кэш вклада работающих зданий науки в скорость исследований (очков/сек).
# Пересчитывается с нуля раз в тик симуляции в do_tick(). Формула по зданию:
#   (additional_yield.science + средневзвешенный special_yield расходуемой
#    смеси основ) × бонус профессии учёного (перья/чернила, ×1.25).
# Ни required, ни craft_time рецепта «Наука» в скорость науки НЕ входят:
# рецепт — лишь «пропуск» (пока сырьё доступно, учёные работают), его вход
# задаёт только расход топлива. Скорость работы учёных определяется самим
# special_yield основ (см. docs.md, «Наука: производство и исследования»).
# Пула науки нет — произведённая наука не копится на складе, а напрямую
# складывается в скорость изучения технологий (см. get_science_rate_per_sec,
# tick_research_science_continuous).
var science_buildings_rate_per_sec: float = 0.0
# Кэш разбивки скорости науки по источникам (для тултипа на вкладке
# «Технологии»). Заполняется раз в тик в do_tick() рядом с
# science_buildings_rate_per_sec из тех же величин:
#   {
#     "base": 1.0,                  # BASE_SCIENCE_PER_SEC
#     "buildings": [                # по каждому работающему зданию науки
#       {
#         "name": "Скрипторий",
#         "fixed": 3.0,             # additional_yield.science, БЕЗ бонуса
#         "mediums": 2.0,           # средневзвешенный special_yield смеси, БЕЗ бонуса
#         "bonus": 1.25,            # множитель профессии (перья/чернила)
#         "mediums_names": ["Папирус"],        # что фактически расходуется
#         "bonus_names": ["Перья"],            # что даёт бонус потребления
#       }, ...
#     ],
#     "total": 7.5,                 # = get_science_rate_per_sec()
#   }
# Итог здания = (fixed + mediums) × bonus — собирается в тултипе.
# До первого тика — пустой словарь (тултип показывает только базу).
var science_breakdown: Dictionary = {}

# --- ТРУД ---
# Труд = скорость работы города. 1 житель = 1 труд/сек.
# НЕ накапливается, это скорость, не запас.
func get_total_labor() -> float:
    return float(total_population) * 1.0

signal city_updated()
signal research_completed(tech_id: String)
signal research_error(message: String)
signal population_changed(new_population: int)
# Казна изменилась: new_total — текущее целое число монет.
signal treasury_changed(new_total: int)
signal building_construction_started(building_id: String, build_key: String)
signal building_construction_completed(building_id: String, build_key: String)
# Апгрейд построенного здания запущен: idx — индекс здания в
# city_built_buildings, upgrade_to — id улучшенной версии.
signal building_upgrade_started(idx: int, upgrade_to: String, build_key: String)

func setup():
    city_storage.clear()
    city_quality_detail.clear()
    production_rates.clear()
    consumption_rates.clear()
    city_food_pool.clear()
    city_built_buildings.clear()
    improvement_planned_production.clear()
    improvement_planned_consumption.clear()
    building_construction.clear()
    domesticated_animals.clear()
    domesticated_plants.clear()
    domesticated_resources.clear()
    unlocked_technologies.clear()
# Растениеводство — всегда открыта при старте игры
    unlocked_technologies.append("farming")
    current_research_tech_id = ""
    current_research_science_cost = 0
    research_progress = 0.0
    research_science_accumulated = 0.0
    science_buildings_rate_per_sec = 0.0
    science_breakdown = {}
    current_era_index = 0
    last_research_messages = []
    city_name = ""

    # Стартовая казна — из data/game_balance.json (поле initial_treasury).
    treasury = int(GameData.game_balance.get("initial_treasury", 10))
    # Трекинг доходов/расходов для тултипа «Казна»: разовая транзакция при
    # старте игры невозможна, но снимки прошлого окна могли остаться от
    # предыдущей сессии/сейва — очищаем.
    treasury_income_accum.clear()
    treasury_income_product_accum.clear()
    treasury_expense_accum.clear()
    treasury_income_snapshot.clear()
    treasury_income_product_snapshot.clear()
    treasury_expense_snapshot.clear()
    treasury_window_length_sec = DEFAULT_TREASURY_WINDOW_SEC

    total_population = 1
    idle_population = 1 # один житель, пока нигде не занят

    for pid in GameData.products.keys():
        city_storage[pid] = 0
        city_quality_detail[pid] = {}
        production_rates[pid] = 0
        consumption_rates[pid] = 0
        if GameData.products[pid].get("category") == "food":
            city_food_pool[pid] = true

    if city_storage.has("meat"):
        city_storage["meat"] = 10
        # Стартовое мясо — обычного качества.
        if not city_quality_detail.has("meat"):
            city_quality_detail["meat"] = {}
        city_quality_detail["meat"]["common"] = city_quality_detail["meat"].get("common", 0) + 10

func reset_counters():
    # Фактические счётчики производства/потребления за тик: используются для
    # определения голода (_check_population_change) и TopBar'а
    # (city_ui._update_food_label). Живут ровно один тик симуляции.
    production_rates.clear()
    consumption_rates.clear()
    # Плановые выпуск/потребление улучшений — кэш текущего тика (наполняется
    # из main_map.gd), живёт ровно один тик симуляции, как и фактические
    # счётчики.
    improvement_planned_production.clear()
    improvement_planned_consumption.clear()

# --- КАЗНА ГОРОДА ---
# Добавляет монеты в казну. Казна всегда целое число монет: amount должен быть
# целым (прибыль внутреннего рынка считается от округлённой цены единицы,
# см. get_internal_market_price). Эмитит treasury_changed для обновления UI.
func add_treasury(amount: int) -> void:
    if amount == 0:
        return
    treasury += amount
    emit_signal("treasury_changed", treasury)

# Списывает монеты из казны (оплата разведки, освоения чанка и т.п.).
# Возвращает false и НИЧЕГО не списывает, если монет не хватает: казна никогда
# не уходит в минус, а вызывающий сам показывает игроку причину отказа.
# Неположительная сумма — «бесплатное» действие: считаем его успешным.
func spend_treasury(amount: int) -> bool:
    if amount <= 0:
        return true
    if treasury < amount:
        return false
    treasury -= amount
    emit_signal("treasury_changed", treasury)
    return true

# --- НАЛОГИ ---
# Каждый житель платит в казну базовый налог за КАЖДЫЙ тик симуляции
# (значение — base_tax_per_citizen в data/game_balance.json). Единая точка
# сбора — collect_taxes(), её вызывает do_tick().
# В разбивке казны налог пока ОДИН, поэтому он не раскладывается по
# источникам/продуктам, а рисуется одной строкой под типом TAX_INCOME_TYPE
# (см. TREASURY_FLAT_TYPE_KEY и ui_helpers.show_treasury_tooltip).
const TAX_INCOME_TYPE: String = "Налоги"
# Источник налога в ПЛОСКОМ накопителе доходов (treasury_income_accum →
# treasury_income_snapshot, см. record_treasury_income). Отдельное имя — чтобы
# сбор налогов не смешивался с рыночным доходом от «Все жители» в плоском
# накопителе (иерархическая разбивка тултипа плоский снимок не читает).
const TAX_INCOME_SOURCE: String = "Подушный налог"

# Базовый налог с одного жителя за один тик симуляции
# (data/game_balance.json, поле base_tax_per_citizen).
func get_base_tax_per_citizen() -> int:
    return int(GameData.game_balance.get("base_tax_per_citizen", 2))

# Налоговое поступление за один тик симуляции: базовый налог × население.
# Единый источник истины для сбора (collect_taxes) и для строки «Налоги» в
# тултипе казны (worker_manager._fill_tax_income).
func get_tax_income_per_tick() -> int:
    return get_base_tax_per_citizen() * total_population

# Сбор налогов за тик: каждый житель платит базовый налог в казну.
# Возвращает фактически собранную сумму (0 — платить некому).
func collect_taxes() -> int:
    var amount: int = get_tax_income_per_tick()
    if amount <= 0:
        return 0
    add_treasury(amount)
    record_treasury_income(TAX_INCOME_SOURCE, amount)
    return amount

# --- РАЗБИВКА КАЗНЫ ПО ИСТОЧНИКАМ (для тултипа) ---
# Источники прибыли/расхода казны собираются в тултип при наведении на
# «Казна: N» в HUD карты и в верхней полосе интерфейса города
# (см. show_treasury_tooltip в ui_helpers.gd). Поведение отдельное для двух
# сторон баланса:
#
#   * Прибыль — непрерывный поток от потребления на внутреннем рынке
#     (worker_manager.get_planned_treasury_income_map): считается из
#     planned_consumption_map × internal_market_price. Аналог «Производство
#     (плановое)» на вкладке «Ресурсы» — равномерно и без мельтешения.
#
#   * Расходы — событийные транзакции игрока (разведка, освоение чанка, возврат
#     при отказе стройки). У автоматического расхода в казну нет запланированной
#     скорости — это разовые суммы по клику, поэтому в тултипе показывается
#     факт за ПОСЛЕДНЕЕ ОКНО отображения (по умолчанию — 3 секунды), а не
#     «/сек». Окно сбрасывается раз в `treasury_window_length_sec` рядом с
#     ресурсной эпохой (см. tick_resource_display), чтобы тултип был стабилен
#     и не мигал на каждом тике.
#
# Снимки (`treasury_*_snapshot`) хранят данные прошедшего окна, тултип читает
# их. Текущий тик (после очередной смены эпохи) — в `treasury_*_accum`, эти
# счётчики наполняются из record_treasury_income/_expense и сбрасываются в
# снимок при rotate_treasury_window().
var treasury_income_accum: Dictionary = {}
var treasury_income_product_accum: Dictionary = {}
var treasury_expense_accum: Dictionary = {}
var treasury_income_snapshot: Dictionary = {}
var treasury_income_product_snapshot: Dictionary = {}
var treasury_expense_snapshot: Dictionary = {}
var treasury_window_length_sec: float = 3.0

# Маркер «ПЛОСКОГО» типа дохода в разбивке казны. Обычный тип раскрывается
# тремя уровнями (тип → источник → продукт), а тип, у которого под этим ключом
# лежит { "rate": float, "label": String }, тултип рисует ОДНОЙ строкой:
#   • Налоги: 2 × 3 чел. = 6 / сек
# Нужен для доходов без товарной разбивки — сейчас это налоги (налог один,
# делить его по источникам/продуктам не на что). Саму скорость дописывает
# рендер (ui_helpers.show_treasury_tooltip), «label» — правая часть до «=».
const TREASURY_FLAT_TYPE_KEY: String = "@flat"

# Записывает доход казны по источнику (накапливается в текущем окне). Вызов
# рядом с add_treasury в местах фактического пополнения казны (см. callers).
# source_name — человекочитаемое имя источника («Рыбак», «Все жители» и т.п.).
func record_treasury_income(source_name: String, amount: int, product_id: String = "") -> void:
    if amount == 0 or source_name.is_empty():
        return
    treasury_income_accum[source_name] = int(treasury_income_accum.get(source_name, 0)) + amount
    if not product_id.is_empty():
        if not treasury_income_product_accum.has(source_name):
            treasury_income_product_accum[source_name] = {}
        var source_products: Dictionary = treasury_income_product_accum[source_name]
        source_products[product_id] = int(source_products.get(product_id, 0)) + amount

# Записывает расход казны по источнику (накапливается в текущем окне).
# Вызов рядом со spend_treasury в местах фактического списания. signed amount:
#   amount > 0 — gross расход (трата);
#   amount < 0 — возврат (refund) в ТОТ ЖЕ источник: ноттируется в накопленную
#                 сумму по этому источнику (отрицательная запись вычитается).
#                 См. expansion_manager.handle_action для примера: gross +
#                 refund в одной паре даёт net-расход в снапшоте.
#   amount == 0 — no-op (отбрасывается).
# Возврат ноттируется внутри источника потому, что возврат не вписывается
# ни в один тип дохода из иерархической разбивки (там только «Потребление
# населения» и будущие «Налоги»/«Торговля»). Если в снапшоте источник
# оказался с нетто <= 0 (только возвраты без компенсирующей траты), тултип
# его не показывает — для игрока это эквивалентно отсутствию расхода.
func record_treasury_expense(source_name: String, amount: int) -> void:
    if amount == 0 or source_name.is_empty():
        return
    treasury_expense_accum[source_name] = int(treasury_expense_accum.get(source_name, 0)) + amount

# Сбрасывает текущее окно в «прошлое» и обнуляет аккумуляторы. Вызывается раз
# в `treasury_window_length_sec` рядом со сменой эпохи отображения ресурсов
# (см. tick_resource_display). Тултип всегда читает snapshot — данные прошлого
# полного окна; так новые накопления текущего окна не «прыгают» на каждом тике
# при обновлении.
func rotate_treasury_window() -> void:
    treasury_income_snapshot = treasury_income_accum.duplicate()
    treasury_income_product_snapshot = treasury_income_product_accum.duplicate(true)
    treasury_expense_snapshot = treasury_expense_accum.duplicate()
    treasury_income_accum.clear()
    treasury_income_product_accum.clear()
    treasury_expense_accum.clear()

# Длительность окна в секундах. По умолчанию 3 сек — короче минимально возможного
# интервала отображения ресурсов (1 сек), но достаточно для захвата разовых
# транзакций разведки/освоения без размывания факта.
const DEFAULT_TREASURY_WINDOW_SEC: float = 3.0

# Возвращает цену, по которой внутренний рынок покупает у города единицу
# товара pid (в монетах казны). Это доля базовой цены товара (price из
# data/products/*.json), заданная множителем internal_market_price_multiplier
# в data/game_balance.json, с округлением
# до ближайшего целого. Для товаров без цены возвращает 0.
#
# quality_id — уровень качества СПИСЫВАЕМОЙ единицы (""/"common" — обычное):
# цена умножается на множитель качества (data/qualities.json,
# price_multiplier) и снова округляется до целого, поэтому монеты всегда
# целые, а хороший товар внутренний рынок покупает дороже.
func get_internal_market_price(pid: String, quality_id: String = "") -> int:
    var prod = GameData.products.get(pid, {})
    var base_price = float(prod.get("price", 0))
    if base_price <= 0.0:
        return 0
    var mult = float(GameData.game_balance.get("internal_market_price_multiplier", 1.0))
    var market_base := int(round(base_price * mult))
    return int(round(float(market_base) * GameData.get_quality_price_multiplier(quality_id)))

# Доход казны за фактически списанные единицы товара с учётом КАЧЕСТВА каждой
# единицы. consumed — разбивка {quality: count}, которую вернул
# remove_from_storage(): цена считается по каждому уровню отдельно, поэтому
# смешанный склад приносит больше, чем count × цена обычного качества.
# Пустая разбивка (списывать было нечего) — доход 0.
func get_internal_market_income(pid: String, consumed: Dictionary) -> int:
    var income := 0
    for qid in consumed:
        var count := int(consumed[qid])
        if count <= 0:
            continue
        income += get_internal_market_price(pid, str(qid)) * count
    return income

# Средний множитель цены по качеству, взвешенный по разбивке склада
# (city_quality_detail). Нужен там, где качество будущей сделки неизвестно —
# прежде всего для ПЛАНОВОГО дохода казны в тултипе: план по обычному
# качеству систематически занижал бы факт, если на складе есть хороший товар.
# Без разбивки (старый сейв, пустой склад) — 1.0.
func get_stock_quality_price_multiplier(pid: String) -> float:
    var detail: Dictionary = city_quality_detail.get(pid, {})
    var total := 0
    var weighted := 0.0
    for qid in detail:
        var count := int(detail[qid])
        if count <= 0:
            continue
        total += count
        weighted += float(count) * GameData.get_quality_price_multiplier(str(qid))
    if total <= 0:
        return 1.0
    return weighted / float(total)

# --- ЗАПИСЬ ФАКТА ЗА ТИК ---
# Эти хелперы обновляют фактические счётчики производства/потребления за тик
# (production_rates / consumption_rates). Используются для определения голода
# (_check_population_change) и TopBar'а (city_ui._update_food_label).
# Детализация по источникам (production_sources / consumption_sources) раньше
# показывалась в тултипе вкладки «Ресурсы», но после коммита 5790016
# тултип отображает только плановое производство/потребление, поэтому
# детализация больше не ведётся — остались только суммарные rate'ы.
#
# Параметр source_name сохранён в сигнатуре для совместимости с вызывающими
# (main_map.gd, worker_manager.gd); он никуда не записывается.

# Публичный хелпер записи ФАКТА производства за тик. Используется из
# main_map.gd и do_tick().
func record_production_source(pid: String, _source_name: String, amount: int):
    production_rates[pid] = production_rates.get(pid, 0) + amount

# Публичный хелпер записи ФАКТА потребления за тик. Используется из
# main_map.gd, worker_manager.gd и do_tick().
func record_consumption_source(pid: String, _source_name: String, amount: int):
    consumption_rates[pid] = consumption_rates.get(pid, 0) + amount

# --- ПЛАНОВЫЙ СПРОС ЗДАНИЙ (для «Потребление (плановое)» на вкладке «Ресурсы») ---
# Кэш ссылки на TownsfolkManager: нужен и do_tick(), и подсчёту спроса зданий.
# Ищется один раз и переиспользуется (is_instance_valid — на случай удаления узла).
var _townsfolk_ref: Node = null

func _get_townsfolk() -> Node:
    if _townsfolk_ref != null and is_instance_valid(_townsfolk_ref):
        return _townsfolk_ref
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map:
        _townsfolk_ref = main_map.get_node_or_null("TownsfolkManager")
    return _townsfolk_ref

# Кэш ссылки на WorkerManager: нужен плановому производству зданий (бонус
# профессии горожанина) и тику потребления — симметрично _get_townsfolk().
var _worker_manager_ref: Node = null

func _get_worker_manager() -> Node:
    if _worker_manager_ref != null and is_instance_valid(_worker_manager_ref):
        return _worker_manager_ref
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map:
        _worker_manager_ref = main_map.get_node_or_null("WorkerManager")
    return _worker_manager_ref

# Число РАБОТАЮЩИХ горожан по профессиям: prof_id -> count. Профессия берётся
# у здания (поле "profession" в data/buildings.json). Учитываются только
# здания, где есть горожанин И хотя бы один непустой слот: простаивающее
# здание расходники не тратит, поэтому в план его расход не попадает
# (см. worker_manager.get_planned_consumption_map).
func get_townsfolk_professions_count() -> Dictionary:
    var result: Dictionary = {}
    var tm = _get_townsfolk()
    if tm == null:
        return result
    for i in range(city_built_buildings.size()):
        if not tm.has_townsfolk(i):
            continue
        if are_all_slots_empty(i):
            continue
        var prof: String = tm.get_profession(i)
        if prof.is_empty():
            continue
        result[prof] = int(result.get(prof, 0)) + 1
    return result

# Возвращает плановый спрос ПОСТРОЕННЫХ ЗДАНИЙ на ресурсы за один крафт
# рецепта. Рецепт в do_tick() исполняется раз в `time` секунд при назначенном
# горожанине и наличии ингредиентов, поэтому спрос идёт вместе с временем
# рецепта (interval, секунды). Формат результата:
#   product_id -> { "Имя здания" -> { "amount": N, "interval": float,
#                                     "count": M, "is_group": bool,
#                                     "group_name": String } }
#   amount   — суммарный спрос этого здания на ресурс за один крафт слотов;
#   interval — время крафта, секунды (при нескольких слотах здания с разным
#              time берётся минимальное — как у профессий в
#              worker_manager.get_planned_consumption_map); 0 — «за тик»
#              (рецепт без поля time);
#   count  — сколько слотов-рецептов дают этот спрос (для «хN» в тултипе);
#   is_group / group_name — спрос задан группой «@»: относится к ЛЮБОМУ члену
#   группы, в тултипе помечается именем группы.
# Спрос показывается независимо от наличия ингредиентов на складе — это
# плановое потребление (потребность), а не факт; факт считает do_tick().
func get_building_planned_consumption() -> Dictionary:
    var result: Dictionary = {}
    var tm = _get_townsfolk()
    for i in range(city_built_buildings.size()):
        var bld = city_built_buildings[i]
        var slots = bld.get("slots", [])
        if slots.is_empty():
            continue
        # Без горожанина здание не работает и ничего не потребляет.
        if tm == null or not tm.has_townsfolk(i):
            continue
        # Имя здания — источник спроса (совпадает с источником фактического
        # расхода в do_tick, чтобы в тултипе это был один и тот же субъект).
        var building_source = get_building_name(bld.get("id", ""))
        for recipe_id in slots:
            if recipe_id == "" or recipe_id == "empty":
                continue
            var recipe = get_craft_by_id(recipe_id)
            if recipe.is_empty():
                continue
            # Время крафта слота — единица измерения планового спроса.
            var craft_time := get_craft_time(recipe)
            var resources: Dictionary = recipe.get("resources", {})
            for res in resources:
                var amount_needed = int(resources[res])
                if amount_needed <= 0:
                    continue
                if res.begins_with("@"):
                    # Групповой ресурс: спрос относится к любому члену группы
                    # (резолв группы — как в do_tick: по id, затем по имени).
                    var group_key = res.trim_prefix("@")
                    var group_products = GameData.product_groups.get(group_key, [])
                    if group_products.is_empty():
                        group_products = GameData.product_groups.get(_get_group_id_by_name(group_key), [])
                    if group_products.is_empty():
                        continue
                    var group_name = GameData.get_product_group_name(res)
                    for prod in group_products:
                        _record_planned_demand(result, prod, building_source, amount_needed, true, group_name, craft_time)
                else:
                    _record_planned_demand(result, res, building_source, amount_needed, false, "", craft_time)
    return result

# Хелпер записи спроса здания на ресурс (см. get_building_planned_consumption).
# interval — время крафта рецепта, секунды (0 — «за тик»); при нескольких
# записях одного источника берётся минимальный — как у профессий в
# worker_manager._record_planned_entry.
func _record_planned_demand(result: Dictionary, pid: String, source_name: String, amount: int, is_group: bool, group_name: String, interval: float):
    if not result.has(pid):
        result[pid] = {}
    var by_source: Dictionary = result[pid]
    if not by_source.has(source_name):
        by_source[source_name] = {"amount": 0, "count": 0, "is_group": false, "group_name": "", "interval": interval}
    var entry: Dictionary = by_source[source_name]
    entry["amount"] = int(entry.get("amount", 0)) + amount
    entry["count"] = int(entry.get("count", 0)) + 1
    entry["interval"] = minf(float(entry.get("interval", interval)), interval)
    entry["is_group"] = bool(entry.get("is_group", false)) or is_group
    if str(entry.get("group_name", "")) == "":
        entry["group_name"] = group_name

# Возвращает плановое производство ПОСТРОЕННЫХ ЗДАНИЙ за один крафт рецепта
# (зеркально к спросу зданий: рецепт в do_tick() даёт result раз в `time`
# секунд при горожанине и наличии ингредиентов). Формат результата:
#   product_id -> { "Имя здания" -> { "amount": N, "interval": float, "count": M } }
#   amount   — суммарный выпуск этого здания за один крафт (по всем слотам);
#   interval — время крафта, секунды (min по слотам здания; 0 — «за тик»);
#   count    — сколько слотов-рецептов дают этот выпуск (для «хN» в тултипе).
# План показывается независимо от наличия ингредиентов — это способность
# производителя, а не факт; факт считает do_tick().
func get_building_planned_production() -> Dictionary:
    var result: Dictionary = {}
    var tm = _get_townsfolk()
    # Множитель профессии горожанина (worker_manager.get_building_production_bonus)
    # — чтобы плановая метка «≈» совпадала с фактическим выпуском.
    var wm = _get_worker_manager()
    for i in range(city_built_buildings.size()):
        var bld = city_built_buildings[i]
        var slots = bld.get("slots", [])
        if slots.is_empty():
            continue
        # Без горожанина здание не работает и ничего не производит.
        if tm == null or not tm.has_townsfolk(i):
            continue
        # Бонус профессии: 1.0 без профессии или без расходников, иначе
        # 1.0 + бонусы (см. worker_manager._aggregate_production_bonus).
        # Простаивающее здание (все слоты пусты) бонуса не получает.
        var prof_multiplier := 1.0
        if wm != null and not are_all_slots_empty(i):
            prof_multiplier = wm.get_building_production_bonus(i)
        # Имя здания — источник выпуска (совпадает с источником фактического
        # производства в do_tick, чтобы в тултипе это был один и тот же субъект).
        var building_source = get_building_name(bld.get("id", ""))
        for recipe_id in slots:
            if recipe_id == "" or recipe_id == "empty":
                continue
            var recipe = get_craft_by_id(recipe_id)
            if recipe.is_empty():
                continue
            # Время крафта слота — единица измерения планового выпуска.
            var craft_time := get_craft_time(recipe)
            var production: Dictionary = recipe.get("result", {})
            for res in production:
                var amount = int(production[res])
                if amount <= 0:
                    continue
                # Бонус профессии применяется к выпуску рецепта — как множитель
                # производства у улучшений на карте.
                if prof_multiplier != 1.0:
                    amount = int(round(float(amount) * prof_multiplier))
                    if amount <= 0:
                        continue
                _record_planned_supply(result, res, building_source, amount, craft_time)
    return result

# Хелпер записи выпуска здания (см. get_building_planned_production).
# interval — время крафта рецепта, секунды (0 — «за тик»); при нескольких
# записях одного источника берётся минимальный.
func _record_planned_supply(result: Dictionary, pid: String, source_name: String, amount: int, interval: float):
    if not result.has(pid):
        result[pid] = {}
    var by_source: Dictionary = result[pid]
    if not by_source.has(source_name):
        by_source[source_name] = {"amount": 0, "count": 0, "interval": interval}
    var entry: Dictionary = by_source[source_name]
    entry["amount"] = int(entry.get("amount", 0)) + amount
    entry["count"] = int(entry.get("count", 0)) + 1
    entry["interval"] = minf(float(entry.get("interval", interval)), interval)

# Точка входа планового производства: рецепты зданий (interval = time рецепта,
# 0 — «за тик») + улучшения на карте (interval = production_interval улучшения,
# см. get_improvement_production_interval). План нужен потому, что в
# непрерывной модели (см. main_map._emit_continuous_production и CraftContainer)
# выпуск идёт каждый тик по чуть-чуть, и метка динамики `[+N≈]` показывает
# средний per_sec — этого достаточно для UI вкладки «Ресурсы». Записи
# наполняются из main_map.gd на каждом тике симуляции.
func get_planned_production_map() -> Dictionary:
    var result := get_building_planned_production()
    for pid in improvement_planned_production:
        if not result.has(pid):
            result[pid] = {}
        var by_source: Dictionary = result[pid]
        for source_name in improvement_planned_production[pid]:
            var src: Dictionary = improvement_planned_production[pid][source_name]
            if not by_source.has(source_name):
                by_source[source_name] = {"amount": 0, "count": 0, "interval": float(src.get("interval", 0.0))}
            var entry: Dictionary = by_source[source_name]
            entry["amount"] = int(entry.get("amount", 0)) + int(src.get("amount", 0))
            entry["count"] = int(entry.get("count", 0)) + int(src.get("count", 1))
            entry["interval"] = minf(float(entry.get("interval", 0.0)), float(src.get("interval", 0.0)))
    return result

# --- ПЛАНОВОЕ ПРОИЗВОДСТВО УЛУЧШЕНИЙ НА КАРТЕ ---
# Кэш планового выпуска улучшений на текущий тик симуляции:
#   product_id -> { "Имя улучшения" -> { "amount": N, "interval": float, "count": M } }
#   amount   — суммарный выпуск улучшения за ОДИН цикл (по всем гексам);
#   interval — production_interval улучшения, секунды;
#   count    — сколько гексов с этим улучшением работают (для «хN» в тултипе).
# Наполняется из main_map.gd на каждом тике, чистится в reset_counters()
# вместе с фактическими счётчиками. Сейв не затрагивается — план всегда
# выводится из текущих данных.
var improvement_planned_production: Dictionary = {}

# Время одного цикла производства улучшения imp_id в секундах — поле
# "production_interval" из data/improvements.json. Поле отсутствует или <= 0 —
# улучшение выпускает продукцию каждый тик симуляции (старые данные).
func get_improvement_production_interval(imp_id: String) -> float:
    var interval: float = float(GameData.improvements.get(imp_id, {}).get("production_interval", 0.0))
    if interval <= 0.0:
        return SIMULATION_TICK
    return interval

# Запись планового выпуска улучшения за один цикл (вызывается из main_map.gd
# для каждого работающего улучшения на каждом тике симуляции).
func record_planned_improvement_production(pid: String, source_name: String, amount: int, interval: float):
    _record_cycle_entry(improvement_planned_production, pid, source_name, amount, interval)

# --- ПЛАНОВОЕ ПОТРЕБЛЕНИЕ УЛУЧШЕНИЙ НА КАРТЕ (корм пастбищ) ---
# Корм (feed_consumption ресурса) списывается непрерывно (см.
# main_map._consume_feed_continuous), и в плане указывается средний расход за
# цикл производства — для UI вкладки «Ресурсы» (зеркально к плановому
# выпуску). Наполняется из main_map.gd на каждом тике, чистится в
# reset_counters().
var improvement_planned_consumption: Dictionary = {}

# Запись планового потребления улучшения за один цикл (вызывается из main_map.gd).
func record_planned_improvement_consumption(pid: String, source_name: String, amount: int, interval: float):
    _record_cycle_entry(improvement_planned_consumption, pid, source_name, amount, interval)

# Кэш планового потребления улучшений для мерджа во вкладке «Ресурсы»
# (worker_manager.get_planned_consumption_map знает только профессии,
# городское «all» и спрос зданий).
func get_improvement_planned_consumption() -> Dictionary:
    return improvement_planned_consumption

# Общий хелпер записи цикловой записи (выпуск или потребление улучшения):
# amount суммируется, count — число гексов-источников, interval — минимальный.
func _record_cycle_entry(cache: Dictionary, pid: String, source_name: String, amount: int, interval: float):
    if pid.is_empty() or amount <= 0:
        return
    if not cache.has(pid):
        cache[pid] = {}
    var by_source: Dictionary = cache[pid]
    if not by_source.has(source_name):
        by_source[source_name] = {"amount": 0, "count": 0, "interval": interval}
    var entry: Dictionary = by_source[source_name]
    entry["amount"] = int(entry.get("amount", 0)) + amount
    entry["count"] = int(entry.get("count", 0)) + 1
    entry["interval"] = minf(float(entry.get("interval", interval)), interval)

# Возвращает человекочитаемое имя здания по его id (или сам id, если здание
# не найдено в реестре).
func get_building_name(building_id: String) -> String:
    for b in GameData.buildings:
        if b.get("id", "") == building_id:
            return b.get("name", building_id)
    return building_id

# --- ХЕЛПЕРЫ ДЛЯ РАБОТЫ С КАЧЕСТВОМ РЕСУРСОВ ---
# city_storage хранит общее количество, city_quality_detail — разбивку по качеству.
# Все операции добавления/списания должны идти через эти хелперы, чтобы
# сумма по деталям всегда совпадала с city_storage.

# Возвращает разбивку по качеству для продукта (словарь {quality: count}).
# Если разбивки нет (старый сейв), возвращает пустой словарь.
func get_quality_breakdown(pid: String) -> Dictionary:
    return city_quality_detail.get(pid, {})

# Возвращает общее количество продукта на складе.
func get_storage_amount(pid: String) -> int:
    return city_storage.get(pid, 0)

# Добавляет amount единиц продукта pid указанного качества.
# Синхронно обновляет city_storage и city_quality_detail.
func add_to_storage(pid: String, amount: int, quality: String = "common"):
    if amount <= 0:
        return
    city_storage[pid] = city_storage.get(pid, 0) + amount
    if not city_quality_detail.has(pid):
        city_quality_detail[pid] = {}
    var detail: Dictionary = city_quality_detail[pid]
    detail[quality] = detail.get(quality, 0) + amount

# Уменьшает общее количество продукта pid на amount единиц.
# Списывает по приоритету качества (best/worst/random) и возвращает
# разбивку фактически списанного: {quality: count}.
# Если приоритет не указан, используется "best".
func remove_from_storage(pid: String, amount: int, priority: String = "best") -> Dictionary:
    if amount <= 0:
        return {}
    var available = city_storage.get(pid, 0)
    var to_remove = min(amount, available)
    var consumed = _consume_quality_detail(pid, to_remove, priority)
    city_storage[pid] = available - to_remove
    return consumed

# Списывает amount единиц из разбивки по качеству согласно приоритету.
# Возвращает словарь {quality: count} фактически списанного.
func _consume_quality_detail(pid: String, amount: int, priority: String) -> Dictionary:
    var detail: Dictionary = city_quality_detail.get(pid, {})
    if detail.is_empty():
        # Нет разбивки (старый сейв) — считаем всё "common".
        return {"common": amount}

    var levels = GameData.get_quality_levels()
    if levels.is_empty():
        return {"common": amount}

    var consumed = {}
    var remaining = amount

    # Определяем порядок списания уровней качества.
    var order = []
    if priority == "worst":
        order = levels.duplicate() # от худшего к лучшему
    elif priority == "random":
        order = levels.duplicate()
        order.shuffle()
    else: # "best" и по умолчанию — от лучшего к худшему
        order = levels.duplicate()
        order.reverse()

    for qid in order:
        if remaining <= 0:
            break
        var available = detail.get(qid, 0)
        if available <= 0:
            continue
        var take = min(available, remaining)
        detail[qid] = available - take
        consumed[qid] = consumed.get(qid, 0) + take
        remaining -= take

    # Если осталось (например, разбивка неполная) — списываем как common.
    if remaining > 0:
        consumed["common"] = consumed.get("common", 0) + remaining

    return consumed

# Возвращает уровень качества, соответствующий взвешенному среднему
# по разбивке consumed (словарь {quality: count}).
# Используется при производстве: качество результата = взвешенное среднее
# качества потреблённого сырья, округлённое до ближайшего уровня.
# Собирает плоскую разбивку потреблённого сырья по качеству из контейнера
# крафта: для каждого слота ингредиента проходит по накопленным «входам»
# (consumed) и складывает в единый словарь {quality: count}.
# Используется при завершении крафта для расчёта качества результата —
# прямой аналог consumed_all в старой пакетной логике.
func _collect_container_quality(container: CraftContainer) -> Dictionary:
    var out := {}
    if container == null:
        return out
    for slot in container.ingredient_slots:
        for entry in slot.get("consumed", []):
            var qty = int(entry.get("qty", 0))
            var qid = str(entry.get("quality", "common"))
            if qty <= 0:
                continue
            out[qid] = int(out.get(qid, 0)) + qty
    return out

func quality_from_breakdown(consumed: Dictionary) -> String:
    var levels = GameData.get_quality_levels()
    if levels.is_empty():
        return "common"
    var total := 0
    var weighted := 0.0
    for qid in consumed:
        var count = int(consumed[qid])
        if count <= 0:
            continue
        total += count
        weighted += float(count) * float(GameData.get_quality_value(qid))
    if total <= 0:
        return "common"
    var avg = weighted / float(total)
    # Округляем до ближайшего уровня качества.
    var best_qid = levels[0]
    var best_diff = 1e9
    for qid in levels:
        var diff = abs(float(GameData.get_quality_value(qid)) - avg)
        if diff < best_diff:
            best_diff = diff
            best_qid = qid
    return best_qid

# DEPRECATED: после перехода на continuous-модель (см. main_map.gd,
# блок «НЕПРЕРЫВНОЕ ПРОИЗВОДСТВО УЛУЧШЕНИЯ») эта функция больше не вызывается
# из тика симуляции. Оставлена для обратной совместимости: если во внешнем
# коде где-то остался вызов (например, отладка, тесты), он продолжит работать.
# Удалить после проверки сейвов и UI на отсутствие ссылок.
func add_raw_production(raw_id: String, multiplier: float = 1.0, quality: String = "common", source_name: String = ""):
    if Engine.is_editor_hint():
        return
    var raw = GameData.raw_resources.get(raw_id, {})
    if raw.has("produces"):
        for pid in raw["produces"]:
            # produces может быть числом или диапазоном [min, max] — для
            # детерминированного непрерывного производства берём минимум
            # диапазона (см. RangeUtils).
            var amount = ceili(float(RangeUtils.get_min_value(raw["produces"][pid], 1)) * multiplier)
            # Проверяем, доступен ли этот продукт (по технологии)
            if not _is_product_available(pid):
                continue
            if amount <= 0:
                continue
            # Всегда добавляем в storage и записываем источник (раньше в первом
            # тике, когда продукта ещё не было в city_storage, источник
            # вообще не записывался — это и был баг «тултип пустой на новом
            # производстве»).
            add_to_storage(pid, amount, quality)
            if source_name != "":
                record_production_source(pid, source_name, amount)
            else:
                production_rates[pid] += amount

# --- ВРЕМЯ РЕЦЕПТА (time) ---
# Рецепт слота здания исполняется непрерывно: ингредиенты забираются
# со склада поштучно с рассчитанной скоростью (required / time ед./сек).
# Крафт считается завершённым, когда ВСЕ ингредиенты набраны и прошло
# craft_time секунд. Если сырья не хватает — контейнер «замерзает»
# (время не копит, ингредиенты не забираются), и крафт автоматически
# затягивается до появления сырья на складе.
#
# На каждый слот здания заводится CraftContainer (см. scripts/craft_container.gd),
# который хранит состояние заполнения и список «входов» с качествами для
# расчёта качества результата. Контейнеры сериализуются вместе с
# city_built_buildings под ключом "slot_containers".
#
# Шаг симуляции — SIMULATION_TICK (1 сек). Дробные остатки за тик
# копятся в контейнере (sub-unit accumulator), поэтому средняя скорость
# не дрейфует (21/5 = 4.2 → чередуем 4 и 5 единиц).

# Время одного крафта рецепта в секундах. Поле time отсутствует или <= 0 —
# рецепт ведёт себя как раньше: крафт каждый тик симуляции.
func get_craft_time(recipe: Dictionary) -> float:
    var t := float(recipe.get("time", 0.0))
    if t <= 0.0:
        return SIMULATION_TICK
    return t

# Возвращает данные рецепта по id (или пустой словарь, если рецепт не найден).
func get_craft_by_id(recipe_id: String) -> Dictionary:
    for c in GameData.crafts:
        if c.get("id", "") == recipe_id:
            return c
    return {}

# --- КОНТЕЙНЕРЫ СЛОТОВ (непрерывный крафт) ---
# На каждый слот здания — CraftContainer. Массив лениво создаётся и
# подгоняется под текущее число слотов. Старые сейвы без ключа
# "slot_containers" мигрируют при первом обращении (slot_progress →
# пустые контейнеры, см. _ensure_slot_containers).
func get_slot_containers(b_index: int) -> Array:
    if b_index < 0 or b_index >= city_built_buildings.size():
        return []
    var bld: Dictionary = city_built_buildings[b_index]
    var slots: Array = bld.get("slots", [])
    var containers = bld.get("slot_containers", null)
    if not (containers is Array):
        # Миграция со старого формата (slot_progress).
        containers = _migrate_slot_containers(b_index, slots)
        bld["slot_containers"] = containers
    # Подгоняем массив под текущее число слотов.
    while containers.size() < slots.size():
        containers.append(null)
    if containers.size() > slots.size():
        containers.resize(slots.size())
    # Ленивое восстановление сериализованных контейнеров из сейва:
    # SaveManager._serialize_buildings пишет плоские dict (JSON-совместимые),
    # поэтому после загрузки здесь лежат dict, а не объекты. При первом
    # обращении пересобираем CraftContainer по ТЕКУЩЕМУ рецепту слота;
    # несовместимость рецепта контейнер разруливает сам
    # (_restore_from_slot_data мерджит состояние по совпадающим ингредиентам).
    # Без этого типизированное присваивание в _ensure_slot_container падало бы
    # на dict после загрузки сейва.
    for i in range(mini(containers.size(), slots.size())):
        var c = containers[i]
        if c == null or c is CraftContainer:
            continue
        var recipe = get_craft_by_id(str(slots[i]))
        if recipe.is_empty():
            # Рецепт слота не разрешается — слот считается пустым
            # (та же семантика, что в _ensure_slot_container).
            containers[i] = null
            continue
        var saved: Dictionary = c if c is Dictionary else {}
        containers[i] = CraftContainer.new(recipe, saved)
    return containers

# Внутренняя: создаёт массив CraftContainer из старого slot_progress или
# с нуля. Прогресс старого таймера не переносим — это были просто секунды,
# не заполненность контейнера; корректный перевод невозможен без потери
# семантики. После миграции слот начинает крафт заново.
func _migrate_slot_containers(b_index: int, slots: Array) -> Array:
    var out: Array = []
    var bld: Dictionary = city_built_buildings[b_index]
    var old_progress = bld.get("slot_progress", [])
    for slot_idx in range(slots.size()):
        var recipe_id = str(slots[slot_idx])
        if recipe_id == "" or recipe_id == "empty":
            out.append(null)
            continue
        var recipe = get_craft_by_id(recipe_id)
        if recipe.is_empty():
            out.append(null)
            continue
        # Используем сохранённое состояние, если оно соответствует
        # текущему рецепту (для будущих сейвов в новом формате).
        var saved = null
        if slot_idx < old_progress.size() and old_progress[slot_idx] is Dictionary:
            saved = old_progress[slot_idx]
        out.append(CraftContainer.new(recipe, saved if saved != null else {}))
    # Чистим старый ключ, чтобы не таскать его в сейвах.
    bld.erase("slot_progress")
    return out

# Контейнер конкретного слота или null, если слот пуст / рецепт не найден.
func get_slot_container(b_index: int, slot_idx: int) -> CraftContainer:
    var containers := get_slot_containers(b_index)
    if slot_idx < 0 or slot_idx >= containers.size():
        return null
    var c = containers[slot_idx]
    if c is CraftContainer:
        return c
    return null

# Возвращает или создаёт контейнер слота, синхронизируя с текущим рецептом.
# Если рецепт в слоте изменился — пересоздаёт контейнер (сбрасывая прогресс).
func _ensure_slot_container(b_index: int, slot_idx: int) -> CraftContainer:
    var containers := get_slot_containers(b_index)
    if slot_idx < 0 or slot_idx >= containers.size():
        return null
    var slots: Array = city_built_buildings[b_index].get("slots", [])
    var recipe_id = str(slots[slot_idx])
    if recipe_id == "" or recipe_id == "empty":
        containers[slot_idx] = null
        return null
    var recipe = get_craft_by_id(recipe_id)
    if recipe.is_empty():
        containers[slot_idx] = null
        return null
    var existing: CraftContainer = containers[slot_idx]
    if existing != null and existing.recipe_id == recipe_id:
        return existing
    # Рецепт изменился — пересоздаём.
    var fresh = CraftContainer.new(recipe)
    containers[slot_idx] = fresh
    return fresh

# Время крафта рецепта в слоте здания (0, если слот пуст или рецепт не найден).
func get_slot_craft_time(b_index: int, slot_idx: int) -> float:
    if b_index < 0 or b_index >= city_built_buildings.size():
        return 0.0
    var slots: Array = city_built_buildings[b_index].get("slots", [])
    if slot_idx < 0 or slot_idx >= slots.size():
        return 0.0
    var recipe_id := str(slots[slot_idx])
    if recipe_id == "" or recipe_id == "empty":
        return 0.0
    var recipe = get_craft_by_id(recipe_id)
    if not (recipe is Dictionary) or recipe.is_empty():
        return 0.0
    return get_craft_time(recipe)

# --- LEGACY-СОВМЕСТИМОСТЬ: get_slot_progress/get_slot_progress_value ---
# Старый API возвращал секунды накопленного таймера. В новой модели
# аналога нет (контейнер заполняется, а не «копит время»). Эти функции
# оставлены только ради старого UI, который ещё не переведён на
# completion_ratio: возвращаем craft_time * completion_ratio, чтобы
# прогресс-бар до перевода на новый API вёл себя правдоподобно.
func get_slot_progress(b_index: int) -> Array:
    if b_index < 0 or b_index >= city_built_buildings.size():
        return []
    var slots: Array = city_built_buildings[b_index].get("slots", [])
    var out: Array = []
    for slot_idx in range(slots.size()):
        out.append(get_slot_progress_value(b_index, slot_idx))
    return out

func get_slot_progress_value(b_index: int, slot_idx: int) -> float:
    var c := get_slot_container(b_index, slot_idx)
    if c == null:
        return 0.0
    return c.completion_ratio() * get_slot_craft_time(b_index, slot_idx)

# Доля готовности текущего крафта слота (0..1) — для UI панели здания.
func get_slot_progress_ratio(b_index: int, slot_idx: int) -> float:
    var c := get_slot_container(b_index, slot_idx)
    if c == null:
        return 0.0
    return c.completion_ratio()

# Текстовое состояние контейнера слота для UI панели здания.
# Пример: "8/20 (3.4 сек)" — заполненность первого ингредиента + время.
func get_slot_status_text(b_index: int, slot_idx: int) -> String:
    var c := get_slot_container(b_index, slot_idx)
    if c == null:
        return ""
    return c.status_text()

# Сбрасывает контейнер слота: после смены рецепта слот начинает
# отсчёт крафта заново.
func reset_slot_progress(b_index: int, slot_idx: int) -> void:
    var c := get_slot_container(b_index, slot_idx)
    if c != null:
        c.reset()

func do_tick():
    if Engine.is_editor_hint():
        return

    # Вклад зданий науки в скорость пересчитывается с нуля каждый тик
    # (см. блок «РЕЦЕПТ „НАУКА"» в цикле зданий ниже). Записи по зданиям
    # собираются в промежуточный список, после цикла из него собирается
    # science_breakdown.
    science_buildings_rate_per_sec = 0.0
    var science_breakdown_buildings: Array = []

    # --- Работа зданий (только если есть горожанин) ---
    var main_map = get_tree().root.find_child("MainMap", true, false)
    var tm = main_map.get_node("TownsfolkManager") if main_map else null
    # WorkerManager — потребление расходников профессией горожанина
    # (tick_building_consumption) и множитель производства от неё.
    var wm = main_map.get_node("WorkerManager") if main_map and main_map.has_node("WorkerManager") else null

    for i in range(city_built_buildings.size()):
        var bld = city_built_buildings[i]
        var slots = bld.get("slots", [])
        if slots.is_empty():
            continue
        # Имя здания — общий источник для прихода и расхода его рецептов
        # (показывает «Ручная мельница», «Дом варщика» в тултипе ресурсов).
        var building_source = get_building_name(bld.get("id", ""))

        # Проверяем, есть ли горожанин на этом здании
        var has_worker = false
        if tm:
            has_worker = tm.has_townsfolk(i)

        if not has_worker:
            continue # здание не работает

        # --- ПРОФЕССИЯ ГОРОЖАНИНА (поле "profession" в data/buildings.json) ---
        # Потребление расходников профессией и множитель её производства.
        # Тикает раз на здание за тик (не на слот!) и только у РАБОТАЮЩЕГО
        # здания: у простаивающего (все слоты пусты) расходники впустую не
        # тратятся. Множитель передаётся в CraftContainer ниже и применяется к
        # начислению науки за завершённый цикл. Бонусы одиночных записей
        # складываются, у групповых берётся лучший (см.
        # worker_manager._aggregate_production_bonus).
        var prof_multiplier := 1.0
        if wm != null and not are_all_slots_empty(i):
            prof_multiplier = wm.tick_building_consumption(i, SIMULATION_TICK)

        # --- НЕПРЕРЫВНЫЙ КРАФТ (CraftContainer) ---
        # Приоритет качества сырья: из здания или дефолт. Передаётся в контейнер
        # для списания и влияет на выбор качества внутри @-групп.
        var priority = bld.get("quality_priority", GameData.get_quality_priority_default())

        for slot_idx in range(slots.size()):
            var recipe_id = slots[slot_idx]
            if recipe_id == "" or recipe_id == "empty":
                continue

            var container: CraftContainer = _ensure_slot_container(i, slot_idx)
            if container == null:
                continue

            # Продвигаем контейнер на один тик. tick() сам списывает ингредиенты
            # со склада (через CityData.remove_from_storage) и возвращает:
            #   consumed_breakdown — разбивка по качествам для тултипа ресурсов
            #                          и расчёта качества science;
            #   releases — что выпустить на склад в этот тик (постепенный выпуск
            #              результата пропорционально прогрессу: full_amount /
            #              craft_time единиц/сек, с sub-unit accumulator для
            #              целочисленной точности). При completed добивается
            #              остаток fractional — выпускается ровно full_amount
            #              за весь цикл.
            #   completed — true если контейнер полон И прошло craft_time.
            var tick_res: Dictionary = container.tick(SIMULATION_TICK, has_worker, priority, prof_multiplier)

            # --- РЕГИСТРАЦИЯ РАСХОДА ЗА ТИК ---
            # Записываем consumption source для тултипа ресурсов и UI-метки
            # динамики. В continuous-модели потребление идёт каждый тик, и эта
            # запись — основной источник данных для красной метки [−N≈].
            var consumed_breakdown: Dictionary = tick_res.get("consumed_breakdown", {})
            for consumed_pid in consumed_breakdown:
                var total_consumed := 0
                for qid in consumed_breakdown[consumed_pid]:
                    total_consumed += int(consumed_breakdown[consumed_pid][qid])
                if total_consumed > 0:
                    record_consumption_source(consumed_pid, building_source, total_consumed)

            # --- РЕЦЕПТ «НАУКА»: прямой вклад в скорость исследований ---
            # Пула науки больше нет: наука зданий не копится на складе, а
            # напрямую складывается в скорость изучения технологий (см.
            # docs.md, «Наука: производство и исследования»). Формула
            # по зданию:
            #   * фиксированный выход здания (additional_yield.science —
            #     очков/сек у Библиотеки и Скриптория) — течёт, пока здание
            #     работает (есть горожанин и непустой слот), даже без основ;
            #   * наука от основ для письма — средневзвешенный special_yield
            #     смеси, которую здание фактически расходует (consumed_pids).
            #     Ни required, ни craft_time рецепта в скорость НЕ входят:
            #     рецепт — лишь «пропуск» (пока сырьё доступно — missing
            #     пуст — учёные работают), его вход задаёт только расход
            #     топлива со склада. Скорость работы учёных определяется
            #     самим special_yield основ (глин. таблички +1, папирус +2,
            #     пергамент +3, шёлк +3, бумага +5). Пока состава нет —
            #     вклад основ 0.
            #   * всё это умножается на бонус профессии учёного
            #     (перья/чернила): (fixed + mediums) × prof_multiplier.
            if recipe_id == "science":
                var missing: Array = tick_res.get("missing", [])
                var building_fixed := float(GameData.get_building_additional_yield(bld.get("id", "")).get("science", 0))
                var building_mediums := 0.0
                var mediums_names: Array = []
                if missing.is_empty():
                    for slot in container.ingredient_slots:
                        var required_total := int(slot.get("required", 0))
                        if required_total <= 0:
                            continue
                        # Средневзвешенный special_yield смеси основ, которую
                        # фактически расходует слот (consumed_pids копится по
                        # pid и переживает reset цикла). Это и есть вклад
                        # основ в скорость науки — без множителей.
                        var consumed_pids: Dictionary = slot.get("consumed_pids", {})
                        var yield_sum := 0.0
                        var qty_sum := 0
                        for consumed_pid in consumed_pids:
                            var consumed_qty := int(consumed_pids[consumed_pid])
                            if consumed_qty <= 0:
                                continue
                            var medium_science := float(GameData.get_special_yield(str(consumed_pid)).get("science", 0))
                            yield_sum += medium_science * float(consumed_qty)
                            qty_sum += consumed_qty
                            mediums_names.append(GameData.format_resource_name(str(consumed_pid)))
                        if qty_sum > 0:
                            building_mediums += yield_sum / float(qty_sum)
                var science_instant := (building_fixed + building_mediums) * prof_multiplier
                science_buildings_rate_per_sec += science_instant
                # Разбивка для тултипа: fixed/mediums пишутся БЕЗ бонуса —
                # множитель применяется к сумме при выводе. bonus_names —
                # продукты, чьё потребление даёт бонус профессии здания.
                var bonus_names: Array = []
                var bld_prof: String = str(bld.get("profession", ""))
                if bld_prof != "" and prof_multiplier > 1.001:
                    for cons_entry in GameData.get_profession_consumption(bld_prof):
                        if float(cons_entry.get("production_bonus", 0.0)) <= 0.0:
                            continue
                        bonus_names.append(str(cons_entry.get("product_name", "")))
                var science_bld_entry := {
                    "name": building_source,
                    "fixed": building_fixed,
                    "mediums": building_mediums,
                    "bonus": prof_multiplier,
                    "mediums_names": mediums_names,
                    "bonus_names": bonus_names
                }
                science_breakdown_buildings.append(science_bld_entry)

            # --- ПОСТЕПЕННЫЙ ВЫПУСК РЕЗУЛЬТАТА (каждый тик) ---
            # Каждая «порция» выпуска имеет качество, рассчитанное по
            # накопленному consumed на текущий момент (см. CraftContainer._compute_quality_from_consumed).
            # Это семантически согласуется с UI: метка [≈] показывает плановый
            # per_sec, а на склад фактически приходит +N за тик (в среднем).
            var releases: Array = tick_res.get("releases", [])
            for rel in releases:
                var rel_pid: String = str(rel.get("pid", ""))
                var rel_amount: int = int(rel.get("amount", 0))
                var rel_quality: String = str(rel.get("quality", "common"))
                if rel_amount <= 0 or rel_pid.is_empty():
                    continue
                add_to_storage(rel_pid, rel_amount, rel_quality)
                record_production_source(rel_pid, building_source, rel_amount)

            if not bool(tick_res.get("completed", false)):
                continue

            # --- КРАФТ ЗАВЕРШЁН ---
            # На этом этапе releases за тик уже включает «добивку» остатка
            # fractional — суммарно за цикл выпускается ровно full_amount для
            # каждого pid результата. Ничего дополнительно добавлять не нужно.
            # Особый случай рецепта «science» не нужен: его вклад в скорость
            # исследований начисляется каждый тик выше (блок «РЕЦЕПТ
            # „НАУКА"»), на склад наука не поступает.

            # --- СБРОС КОНТЕЙНЕРА ДЛЯ СЛЕДУЮЩЕГО КРАФТА ---
            container.reset()

    # --- РАЗБИВКА СКОРОСТИ НАУКИ ПО ИСТОЧНИКАМ (для тултипа) ---
    science_breakdown = {
        "base": BASE_SCIENCE_PER_SEC,
        "buildings": science_breakdown_buildings,
        "total": get_science_rate_per_sec()
    }

    # --- Потребление еды населением ---
    # Еда потребляется без учёта качества (качество — визуальная механика),
    # поэтому списываем по умолчанию "best" через хелпер, чтобы детализация
    # качества всегда оставалась консистентной.
    # Дебаг-переключатель: пока food_consumption_enabled == false жители
    # НЕ едят еду (тумблер в дебаг-меню). Рост/убыль населения при этом
    # считается как обычно — отключено только само списание еды со склада.
    if food_consumption_enabled:
        var food_needed = max(0, total_population - 1) * food_per_citizen
        var food_eaten = 0
        for pid in city_food_pool:
            if city_food_pool[pid] and city_storage.get(pid, 0) > 0:
                var available = city_storage[pid]
                var to_take = min(available, food_needed - food_eaten)
                remove_from_storage(pid, to_take, "best")
                record_consumption_source(pid, "Питание населения", to_take)
                food_eaten += to_take
                if food_eaten >= food_needed:
                    break

    # --- НАЛОГИ: каждый житель платит базовый налог в казну каждый тик ---
    # Порядок важен: сбор идёт ПОСЛЕ потребления еды и ДО
    # _check_population_change() — налог за тик платят те, кто жил в этом тике
    # (рост/убыль населения учтутся со следующего тика). Сумма и запись в
    # разбивку казны — внутри collect_taxes() (см. «Казна города и внутренний
    # рынок» в docs.md, раздел «Налоги»).
    collect_taxes()
    _check_population_change()
    emit_signal("city_updated")

# Возвращает id группы по её человекочитаемому имени (или сам ключ, если это id).
func _get_group_id_by_name(gname: String) -> String:
    for gid in GameData.product_group_names:
        if GameData.product_group_names[gid] == gname:
            return gid
    return gname

func _check_population_change():
    var available_food = 0
    for pid in city_food_pool:
        if city_food_pool[pid]:
            available_food += city_storage.get(pid, 0)

    # --- ДИНАМИКА ЕДЫ (для определения голода) ---
    var total_prod = 0
    var total_cons = 0
    for pid in city_food_pool:
        if city_food_pool[pid]:
            total_prod += production_rates.get(pid, 0)
            total_cons += consumption_rates.get(pid, 0)

    var main_map = get_tree().root.find_child("MainMap", true, false)

    # --- РОСТ НАСЕЛЕНИЯ ---
    if available_food >= food_for_new_settler and total_population > 0:
        total_population += 1
        idle_population += 1 # новый житель пока свободен

        # Пытаемся назначить его на работу (сначала на улучшение, потом в город)
        var assigned = false
        if main_map and main_map.has_node("WorkerManager"):
            var wm = main_map.get_node("WorkerManager")
            assigned = wm.assign_worker() # уменьшит idle_population при успехе

        if not assigned and main_map and main_map.has_node("TownsfolkManager"):
            var tm = main_map.get_node("TownsfolkManager")
            assigned = tm.assign_townsfolk()

        # Если никуда не назначился — остаётся в idle_population

        # Списываем еду за рождение
        var remaining = food_for_new_settler
        var active_food = []
        for pid in city_food_pool:
            if city_food_pool[pid] and city_storage.get(pid, 0) > 0:
                active_food.append(pid)
        while remaining > 0 and active_food.size() > 0:
            var pid = active_food[randi() % active_food.size()]
            remove_from_storage(pid, 1, "best")
            remaining -= 1
            if city_storage.get(pid, 0) <= 0:
                active_food.erase(pid)

        emit_signal("population_changed", total_population)
        print("Население выросло до ", total_population)

    # --- ГОЛОД (смерть от недостатка еды) ---
    elif available_food == 0 and total_cons > total_prod and total_population > 1:
        total_population -= 1

        # Убираем одного жителя с работы (сначала горожанина, потом рабочего).
        # Умерший НЕ переходит в категорию свободных, поэтому после снятия
        # с работы компенсируем увеличение idle_population.
        var removed = false
        if main_map and main_map.has_node("TownsfolkManager"):
            var tm = main_map.get_node("TownsfolkManager")
            for i in range(city_built_buildings.size()):
                if tm.has_townsfolk(i):
                    tm.remove_townsfolk(i) # увеличит idle_population
                    idle_population -= 1 # умерший не становится свободным
                    removed = true
                    break

        if not removed and main_map and main_map.has_node("WorkerManager"):
            var wm = main_map.get_node("WorkerManager")
            for key in wm.assigned_hexes.keys():
                var parts = key.split(",")
                if parts.size() == 2:
                    wm.remove_worker(int(parts[0]), int(parts[1])) # увеличит idle_population
                    idle_population -= 1 # умерший не становится свободным
                    removed = true
                    break

        # Если житель был свободен (не работал), просто уменьшаем idle_population
        if not removed and idle_population > 0:
            idle_population -= 1

        # Корректируем idle_population, чтобы он не превышал total_population
        if idle_population > total_population:
            idle_population = total_population

        emit_signal("population_changed", total_population)
        print("Население уменьшилось до ", total_population)

# --- ИССЛЕДОВАНИЯ ---
func start_research(tech_id: String) -> bool:
    if Engine.is_editor_hint():
        return false
    # Дебаг: при включённом «не учитывать требования» технология изучается
    # мгновенно — без постановки в очередь, проверки prereq/эпох и накопления
    # науки. Текущее исследование при этом не прерывается.
    if ignore_tech_requirements:
        return _complete_tech_instantly(tech_id)
    if current_research_tech_id != "":
        var current_tech_name = current_research_tech_id
        for t in GameData.technologies:
            if t["id"] == current_research_tech_id:
                current_tech_name = t["name"]
                break
        emit_signal("research_error", "Уже идёт исследование: " + current_tech_name)
        return false
    if tech_id in unlocked_technologies:
        var tech_name = tech_id
        for t in GameData.technologies:
            if t["id"] == tech_id:
                tech_name = t["name"]
                break
        emit_signal("research_error", "Технология уже изучена: " + tech_name)
        return false
    var tech_data = null
    for t in GameData.technologies:
        if t["id"] == tech_id:
            tech_data = t
            break
    if tech_data == null:
        emit_signal("research_error", "Технология не найдена: " + tech_id)
        return false
    if not are_prerequisites_met(tech_id):
        var prereq_text = get_tech_prerequisites_text(tech_id)
        emit_signal("research_error", "Не выполнены требования: " + prereq_text)
        return false
    if not is_tech_era_allowed(tech_id):
        var tech_name = tech_data.get("name", tech_id)
        var next_era_name = _get_era_name_by_index(current_era_index + 1)
        emit_signal("research_error", "«%s» относится к следующей эпохе. Сначала перейдите в эпоху %s." % [tech_name, next_era_name])
        return false
    # Исследование не требует еды — только очки науки.
    current_research_tech_id = tech_id
    current_research_science_cost = int(tech_data.get("science_cost", 3))
    research_progress = 0.0
    research_science_accumulated = 0.0
    print("Начато исследование: ", tech_data["name"])
    emit_signal("city_updated")
    return true

# Мгновенно разблокирует технологию — используется в дебаг-режиме
# «не учитывать требования технологий» (ignore_tech_requirements), когда
# изучение должно происходить сразу, без очереди и накопления науки.
# Изучается только выбранная технология: предшественники НЕ добавляются.
# Текущее исследование (current_research_tech_id) не трогается.
func _complete_tech_instantly(tech_id: String) -> bool:
    if tech_id in unlocked_technologies:
        var tech_name = tech_id
        for t in GameData.technologies:
            if t["id"] == tech_id:
                tech_name = t["name"]
                break
        emit_signal("research_error", "Технология уже изучена: " + tech_name)
        return false
    var tech_data = _get_tech_data(tech_id)
    if tech_data == null:
        emit_signal("research_error", "Технология не найдена: " + tech_id)
        return false
    unlocked_technologies.append(tech_id)
    # Технология может открывать новые виды ресурсов — спавним их на карте и
    # готовим сообщения для попапа (аналогично _complete_research).
    last_research_messages = spawn_resource_on_tech_research(tech_id)
    emit_signal("research_completed", tech_id)
    emit_signal("city_updated")
    print("Мгновенно изучена (дебаг): ", tech_data.get("name", tech_id))
    return true

# Фактическая скорость науки города (очков/сек) — прямая сумма источников:
# базовый доход (BASE_SCIENCE_PER_SEC) плюс вклад работающих зданий науки
# (кэш science_buildings_rate_per_sec, пересчитывается раз в тик в do_tick).
# Пула науки нет: произведённая наука не копится на складе, а сразу задаёт
# скорость изучения технологий (см. tick_research_science_continuous и
# docs.md, «Наука: производство и исследования»).
func get_science_rate_per_sec() -> float:
    return BASE_SCIENCE_PER_SEC + science_buildings_rate_per_sec

# Разбивка скорости науки по источникам (см. science_breakdown) — для тултипа
# на вкладке «Технологии». Кэш заполняется раз в тик в do_tick().
func get_science_breakdown() -> Dictionary:
    return science_breakdown

# Возвращает количество накопленных очков науки по текущему исследованию.
func get_research_science_collected() -> float:
    return research_science_accumulated

# Обновляет прогресс исследования непрерывно — вызывается каждый кадр
# из _process в main_map.gd. Скорость — прямая сумма всех источников науки
# (get_science_rate_per_sec: база + работающие здания науки), поэтому
# прогресс-бар растёт плавно покадрово. Наука НЕ копится: пока исследования
# нет, начисления не происходит, а выработка зданий «впустую» теряется
# (пул науки убран, см. docs.md, «Наука: производство и исследования»).
func tick_research_science_continuous(delta: float) -> void:
    if Engine.is_editor_hint():
        return
    if current_research_tech_id == "":
        return
    if current_research_science_cost <= 0:
        current_research_science_cost = 1
    research_science_accumulated += get_science_rate_per_sec() * delta
    research_progress = clamp(research_science_accumulated / float(current_research_science_cost), 0.0, 1.0)
    if research_science_accumulated >= current_research_science_cost:
        _complete_research()

func _complete_research():
    if current_research_tech_id == "":
        return
    var completed_tech_id = current_research_tech_id
    unlocked_technologies.append(current_research_tech_id)
    var tech_name = get_tech_name(current_research_tech_id)
    emit_signal("research_error", "Исследование завершено: " + tech_name)
    # Технология может открывать новые виды ресурсов — спавним их на карте.
    # Сообщения готовим ДО сигнала research_completed, чтобы попап
    # мог отобразить найденные ресурсы сразу.
    last_research_messages = spawn_resource_on_tech_research(completed_tech_id)
    emit_signal("research_completed", current_research_tech_id)
    # После завершения исследования очки науки сбрасываются на ноль.
    current_research_tech_id = ""
    current_research_science_cost = 0
    research_progress = 0.0
    research_science_accumulated = 0.0
    emit_signal("city_updated")

func is_tech_unlocked(tech_id: String) -> bool:
    return tech_id in unlocked_technologies

# Человекочитаемое название технологии по её id (для сообщений игроку и
# тултипов). Если технология не найдена — возвращается сам id, чтобы в
# сообщении не оказалось пустой строки.
func get_tech_name(tech_id: String) -> String:
    for t in GameData.technologies:
        if t.get("id", "") == tech_id:
            return str(t.get("name", tech_id))
    return tech_id

func _get_tech_data(tech_id: String):
    for t in GameData.technologies:
        if t["id"] == tech_id:
            return t
    return null

# Проверяет, выполнены ли prerequisites технологии.
# Формат: [ [A, B], [C] ] => (A И B) ИЛИ C
func are_prerequisites_met(tech_id: String) -> bool:
    # Дебаг: при включённом «не учитывать требования» prerequisites не
    # проверяются вовсе. Изучается только выбранная технология, предшественники
    # в unlocked_technologies не добавляются (см. _complete_research).
    if ignore_tech_requirements:
        return true
    var tech_data = _get_tech_data(tech_id)
    if tech_data == null:
        return false
    if not tech_data.has("prerequisites"):
        return true
    var prereqs: Array = tech_data.get("prerequisites", [])
    for group in prereqs:
        var all_met = true
        for req_id in group:
            if not (req_id in unlocked_technologies):
                all_met = false
                break
        if all_met:
            return true
    return false

# Возвращает человекочитаемый текст требований технологии.
func get_tech_prerequisites_text(tech_id: String) -> String:
    var tech_data = _get_tech_data(tech_id)
    if tech_data == null or not tech_data.has("prerequisites"):
        return ""
    var or_parts = []
    var prereqs: Array = tech_data.get("prerequisites", [])
    for group in prereqs:
        var and_names = []
        for req_id in group:
            var req_data = _get_tech_data(req_id)
            and_names.append(req_data.get("name", req_id) if req_data else req_id)
        or_parts.append(" и ".join(and_names))
    return " или ".join(or_parts)

# Доступна ли технология для изучения (prerequisites выполнены, не изучена,
# не в процессе, эпоха не выше текущей).
func is_tech_available(tech_id: String) -> bool:
    if tech_id in unlocked_technologies:
        return false
    if tech_id == current_research_tech_id:
        return false
    if not is_tech_era_allowed(tech_id):
        return false
    return are_prerequisites_met(tech_id)

# Возвращает список id технологий (в порядке их изучения — от корня до target),
# которые игроку ещё нужно изучить, чтобы стала доступной tech_id.
# Уже изученные технологии пропускаются; требования берутся из поля
# `prerequisites` (группы ИЛИ · элементов И — выбирается группа с наименьшим
# числом недостающих технологий). Исключаются циклы и дубликаты.
# Используется для кнопки «Изучить ...» в панели управления спецдействий.
func get_tech_study_chain(tech_id: String) -> Array:
    var chain: Array = []
    _collect_tech_chain(tech_id, chain, {})
    return chain

# Максимальное количество «хопов» — технологий, оставшихся до открытия целевой
# технологии (НЕ считая саму цель), — при котором панель управления показывает
# кнопки постройки улучшения, заблокированного технологией, и изучения этой
# технологии. Требование: кнопки видны только если хопов ≤ TECH_HOPS_MAX.
const TECH_HOPS_MAX := 2

# Сколько технологий осталось изучить, чтобы открыть tech_id (сама tech_id
# НЕ считается). Пример для «Каналов» (canals): на старте цепочка = 3
# («Ирригация», «Горное дело», «Каменная кладка») → 3 хопа; после изучения
# «Ирригации» → 2 хопа («Горное дело», «Каменная кладка»).
func get_tech_hops(tech_id: String) -> int:
    return maxi(0, get_tech_study_chain(tech_id).size() - 1)

func _collect_tech_chain(tech_id: String, chain: Array, visiting: Dictionary) -> void:
    if tech_id in visiting or tech_id in chain:
        return
    var data = _get_tech_data(tech_id)
    if data == null or is_tech_unlocked(tech_id):
        return
    # Технологии будущих эпох в цепочку не попадают: их нельзя изучать,
    # пока не совершён переход в соответствующую эпоху.
    if not is_tech_era_allowed(tech_id):
        return
    var prereqs: Array = data.get("prerequisites", [])
    if not prereqs.is_empty():
        # Выбираем группу предусловий с наименьшим числом недостающих технологий.
        var best_reqs: Array = []
        var best_missing := 1 << 30
        for group in prereqs:
            var missing: Array = []
            for req_id in group:
                if not is_tech_unlocked(req_id):
                    missing.append(req_id)
            if missing.size() < best_missing:
                best_missing = missing.size()
                best_reqs = missing
        visiting[tech_id] = true
        for req_id in best_reqs:
            _collect_tech_chain(req_id, chain, visiting)
        visiting.erase(tech_id)
    if tech_id not in chain:
        chain.append(tech_id)

# Открыто ли здание игроку (по полю unlock_tech самого здания).
func is_building_unlocked(building_id: String) -> bool:
    for b in GameData.buildings:
        if b["id"] == building_id:
            var required_tech = b.get("unlock_tech", "")
            if required_tech != "":
                return is_tech_unlocked(required_tech)
    return true

# Проверяет дополнительные условия строительства здания из buildings.json.
# Возвращает словарь {"ok": bool, "reason": String}, чтобы UI и фактический
# запуск строительства показывали одинаковую причину отказа.
func check_building_additional_req(building_id: String) -> Dictionary:
    # Дебаг: при включённом «Игнорировать требования строительства» любые
    # дополнительные условия (additional_req) считаются выполненными.
    if ignore_build_requirements:
        return {"ok": true, "reason": ""}
    var building_data = null
    for b in GameData.buildings:
        if b.get("id", "") == building_id:
            building_data = b
            break
    if building_data == null:
        return {"ok": false, "reason": "Здание не найдено"}

    var requirement = String(building_data.get("additional_req", ""))
    if requirement == "":
        return {"ok": true, "reason": ""}

    if requirement == "running_water":
        var main_map = get_tree().root.find_child("MainMap", true, false)
        if main_map == null or main_map.tile_data.is_empty():
            return {"ok": false, "reason": "Нет доступа к пресной воде"}
        var water_access = MapHelpers.get_hex_water_access(
            main_map.city_row,
            main_map.city_col,
            main_map.tile_data,
            main_map.map_rows,
            main_map.map_cols
        )
        if water_access != "":
            return {"ok": true, "reason": ""}
        return {"ok": false, "reason": "Нужен доступ города к пресной воде"}

    return {"ok": false, "reason": "Неизвестное условие строительства: %s" % requirement}

# Открыто ли улучшение игроку (по полю unlock_tech самого улучшения).
func is_improvement_unlocked(imp_id: String) -> bool:
    if imp_id == null or imp_id == "":
        return true
    var imp_data = GameData.improvements.get(imp_id, {})
    var required_tech = imp_data.get("unlock_tech", "")
    if required_tech != "":
        return is_tech_unlocked(required_tech)
    return true

# Возвращает id технологии, открывающей указанное улучшение (для контекстного меню).
func get_improvement_unlock_tech(imp_id: String) -> String:
    var imp_data = GameData.improvements.get(imp_id, {})
    return imp_data.get("unlock_tech", "")

# Формирует сообщения о ресурсах, раскрываемых изученной технологией.
# Вызывается после завершения исследования технологии.
#
# Новая модель (см. docs.md, «tech_reveal: скрытые ресурсы»):
#   - Все ресурсы спавнятся на карте с самого старта (map_generator.gd).
#   - tech_required гейтит постройку улучшения (как и раньше).
#   - tech_reveal гейтит видимость самого ресурса на карте.
#   - Эта функция перечисляет ресурсы, у которых tech_reveal == tech_id,
#     и для каждого формирует сообщение:
#       * ресурс есть на карте          → "Учёные оценили: найдено <X>."
#       * ресурса на карте нет          → "Похоже, в вашем регионе <X> отсутствует."
#   - Размещением на карте функция НЕ занимается: все ресурсы уже там
#     с момента генерации карты.
#
# Гарантия «1 металл в стартовом Кольце + Регионе» обеспечивается отдельно
# в main_map._initialize_map через MapHelpers.ensure_minimum_resource.
# Возвращает массив сообщений для попапа технологии.
func spawn_resource_on_tech_research(tech_id: String) -> Array:
    var messages = []
    if Engine.is_editor_hint():
        return messages
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map == null:
        return messages
    var tile_data = main_map.tile_data

    # Собираем виды ресурсов, РАСКРЫВАЕМЫХ этой технологией (tech_reveal).
    # Если у ресурса нет tech_reveal — он виден сразу и эта функция его
    # не упоминает; если tech_reveal есть, но не совпадает с tech_id,
    # ресурс ещё скрыт и о нём мы тоже не сообщаем.
    for res_id in GameData.raw_resources:
        var data = GameData.raw_resources[res_id]
        var reveal_tech: String = data.get("tech_reveal", "")
        if reveal_tech != tech_id:
            continue
        var res_name: String = data.get("name", res_id)
        if _is_resource_on_map(tile_data, res_id):
            messages.append("Учёные оценили: в вашем регионе можно найти %s." % res_name)
        else:
            messages.append("Похоже, в вашем регионе %s отсутствует." % res_name)
    return messages

# Проверяет, есть ли на карте хотя бы один гекс с указанным ресурсом.
func _is_resource_on_map(tile_data: Array, res_id: String) -> bool:
    for row in tile_data:
        for tile in row:
            if tile.get("resource", null) == res_id:
                return true
    return false

# Проверяет, присутствует ли на карте хотя бы один ресурс, РАСКРЫВАЕМЫЙ
# указанной технологией (tech_reveal == tech_id).
func _tech_has_resource_on_map(tile_data: Array, tech_id: String) -> bool:
    for row in tile_data:
        for tile in row:
            var res_id = tile.get("resource", null)
            if res_id == null:
                continue
            var data = GameData.raw_resources.get(res_id, {})
            if data.get("tech_reveal", "") == tech_id:
                return true
    return false

# Вызывается при загрузке сохранения: для уже изученных технологий
# гарантирует, что открытые ими ресурсы корректно отображаются.
# В новой модели (все ресурсы уже на карте) это, по сути, no-op: если
# ресурс с tech_reveal == tech_id на карте есть (а он там есть в норме),
# функция ничего не делает. Если сейв старый и ресурс на карте отсутствует,
# нового спавна тоже не делаем — старые сохранения с повреждённой картой
# пользователь чинит сам (или стартует новую партию).
func ensure_tech_resources_spawned():
    if Engine.is_editor_hint():
        return
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map == null:
        return
    var tile_data = main_map.tile_data
    for tech_id in unlocked_technologies:
        # На карте уже есть ресурс, раскрываемый этой технологией — ок.
        if _tech_has_resource_on_map(tile_data, tech_id):
            continue
        # На всякий случай прогоняем функцию (сформирует «отсутствует»
        # сообщения, но в HUD они не пойдут — мы их тут же отбрасываем).
        spawn_resource_on_tech_research(tech_id)

# Проверяет доступность продукта (включая технологии, улучшения и здания).
func _is_product_available(product_id: String) -> bool:
    var product_data = GameData.products.get(product_id, {})
    # Проверка технологии
    var required_tech = product_data.get("unlock_tech", "")
    if required_tech != "" and not is_tech_unlocked(required_tech):
        return false

    # Проверка улучшения (на карте)
    var required_improvement = product_data.get("unlock_improvement", "")
    if required_improvement != "" and not _has_improvement(required_improvement):
        return false

    # Проверка здания (в городе)
    var required_building = product_data.get("unlock_building", "")
    if required_building != "" and not _has_building(required_building):
        return false

    return true

func _has_improvement(improvement_id: String) -> bool:
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if not main_map:
        return false
    for row in range(main_map.region_start_row, main_map.region_end_row + 1):
        for col in range(main_map.region_start_col, main_map.region_end_col + 1):
            var tile = main_map.get_tile_data(row, col)
            if tile and tile.get("improvement") == improvement_id:
                return true
    return false

func _has_building(building_id: String) -> bool:
    for bld in city_built_buildings:
        if bld.get("id") == building_id:
            return true
    return false

# --- АПГРЕЙД ЗДАНИЙ ---
# Здание может иметь улучшенную версию: поле "upgrades_into" в buildings.json
# (например, hand_mill -> animal_mill). Апгрейд — обычная стройка в общем пуле
# труда (build_manager), но во время неё здание продолжает работать как обычно,
# а по завершении заменяется на улучшенную версию с переносом настроек
# (рецепты слотов, приоритет качества; работник остаётся привязан к индексу
# здания, поэтому состояние «работает/приостановлено» переносится само).

# Возвращает id улучшенной версии здания (поле "upgrades_into") или пустую
# строку, если у здания нет улучшения.
func get_building_upgrade_target(building_id: String) -> String:
    for b in GameData.buildings:
        if b.get("id", "") == building_id:
            return String(b.get("upgrades_into", ""))
    return ""

# Возвращает данные идущего апгрейда здания по его индексу в городе
# (пустой словарь, если апгрейд не идёт). Проксирует запрос в build_manager,
# где хранятся все активные стройки.
func get_building_upgrade_data(idx: int) -> Dictionary:
    if Engine.is_editor_hint():
        return {}
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map == null or not main_map.has_node("BuildManager"):
        return {}
    var bm = main_map.get_node("BuildManager")
    return bm.get_building_upgrade_by_index(idx)

# Можно ли начать апгрейд здания под индексом idx:
# - у здания есть поле upgrades_into;
# - улучшенная версия открыта технологией (её unlock_tech изучен);
# - апгрейд этого здания ещё не идёт.
func can_upgrade_building(idx: int) -> bool:
    if idx < 0 or idx >= city_built_buildings.size():
        return false
    var from_id: String = city_built_buildings[idx].get("id", "")
    if from_id == "":
        return false
    var upgrade_to: String = get_building_upgrade_target(from_id)
    if upgrade_to == "":
        return false
    if not is_building_unlocked(upgrade_to):
        return false
    if not get_building_upgrade_data(idx).is_empty():
        return false
    return true

# Запускает апгрейд здания под индексом idx в его улучшенную версию.
# Атомарно списывает additional_cost улучшенной версии и регистрирует стройку
# апгрейда в build_manager (либо завершает апгрейд мгновенно, если у улучшенной
# версии work_cost == 0 или включён дебаг-флаг «Игнорировать требования
# строительства»). Возвращает { "ok": bool, "reason": String } для UI.
func start_building_upgrade(idx: int) -> Dictionary:
    if idx < 0 or idx >= city_built_buildings.size():
        return {"ok": false, "reason": "Здание не найдено"}
    var from_id: String = city_built_buildings[idx].get("id", "")
    var upgrade_to: String = get_building_upgrade_target(from_id)
    if upgrade_to == "":
        return {"ok": false, "reason": "У этого здания нет улучшенной версии"}

    var upgrade_data = null
    for b in GameData.buildings:
        if b.get("id", "") == upgrade_to:
            upgrade_data = b
            break
    if upgrade_data == null:
        return {"ok": false, "reason": "Улучшенная версия здания не найдена"}

    # Улучшенная версия должна быть открыта технологией.
    if not is_building_unlocked(upgrade_to):
        return {"ok": false, "reason": "Сначала изучите технологию, открывающую «%s»" % upgrade_data.get("name", upgrade_to)}

    # Дополнительные условия улучшенной версии (additional_req).
    var additional_req_check = check_building_additional_req(upgrade_to)
    if not additional_req_check["ok"]:
        return {"ok": false, "reason": additional_req_check["reason"]}

    var main_map = get_tree().root.find_child("MainMap", true, false)
    var bm = main_map.get_node("BuildManager") if main_map and main_map.has_node("BuildManager") else null
    if bm == null:
        return {"ok": false, "reason": "Менеджер строительства недоступен"}

    # Апгрейд этого здания уже идёт — повторный запуск невозможен.
    if not bm.get_building_upgrade_by_index(idx).is_empty():
        return {"ok": false, "reason": "Улучшение этого здания уже идёт"}

    # Общий лимит одновременных строек (здания + улучшения + апгрейды) равен
    # числу жителей. Проверяем ДО списания материалов.
    var work_cost = upgrade_data.get("work_cost", 0)
    if work_cost > 0 and not ignore_build_requirements:
        if bm.get_total_active_builds() >= total_population:
            return {"ok": false, "reason": "Можно строить не более %d зданий или улучшений одновременно (лимит = число жителей)" % total_population}

    # Атомарно списываем additional_cost улучшенной версии (при включённом
    # дебаг-флаге материалы не проверяются и не списываются).
    var cost_check = consume_additional_cost(upgrade_data)
    if not cost_check["ok"]:
        var missing_names = []
        for m in cost_check.get("missing", []):
            missing_names.append(str(m))
        return {"ok": false, "reason": "Не хватает: " + ", ".join(missing_names)}

    var build_key = bm.start_building_upgrade(idx, from_id, upgrade_to)
    if build_key == "":
        # Мгновенное завершение (work_cost == 0 / дебаг-флаг): сигнал
        # building_upgrade_completed уже эмитнут, main_map обработает его
        # и вызовет complete_building_upgrade.
        emit_signal("city_updated")
        return {"ok": true, "reason": ""}

    emit_signal("building_upgrade_started", idx, upgrade_to, build_key)
    emit_signal("city_updated")
    return {"ok": true, "reason": ""}

# Завершает апгрейд: заменяет здание под индексом idx на улучшенную версию
# с переносом настроек. Вызывается из main_map._on_building_upgrade_completed
# (сигнал build_manager.building_upgrade_completed) или напрямую при
# мгновенном апгрейде. Возвращает true при успехе.
func complete_building_upgrade(idx: int, upgrade_to: String) -> bool:
    if idx < 0 or idx >= city_built_buildings.size():
        return false
    var old_bld = city_built_buildings[idx]
    var from_id: String = old_bld.get("id", "")
    if from_id == "" or get_building_upgrade_target(from_id) != upgrade_to:
        return false

    # Настройки старой версии: выбранные рецепты слотов и приоритет качества.
    var old_slots: Array = old_bld.get("slots", [])
    var priority: String = old_bld.get("quality_priority", GameData.get_quality_priority_default())

    # Данные улучшенной версии: число слотов и дефолтные рецепты.
    var new_bdata = null
    for b in GameData.buildings:
        if b.get("id", "") == upgrade_to:
            new_bdata = b
            break
    var slot_count := 1
    var default_recipes: Array = []
    if new_bdata:
        slot_count = int(new_bdata.get("production_slots", 1))
        default_recipes = new_bdata.get("default_recipes", [])

    # Перенос рецептов: рецепт, исполняемый и в новой версии, сохраняется;
    # непригодные (например, ручной помол зерна при апгрейде в мельницу с
    # животной тягой) заменяются дефолтным рецептом новой версии или «Пусто».
    var new_slots: Array = []
    for i in range(slot_count):
        var selected_id: String = old_slots[i] if i < old_slots.size() else ""
        if selected_id == "" or selected_id == "empty":
            # Пустой слот остаётся пустым — выбор игрока сохраняется.
            new_slots.append("empty")
        elif can_craft_in(selected_id, upgrade_to):
            new_slots.append(selected_id)
        else:
            if i < default_recipes.size():
                new_slots.append(default_recipes[i])
            else:
                new_slots.append("empty")

    # Состояние «работает/приостановлено» переносится само: работник привязан
    # к индексу здания (townsfolk_manager), а индекс не меняется.
    city_built_buildings[idx] = {
        "id": upgrade_to,
        "slots": new_slots,
        "quality_priority": priority
    }
    emit_signal("city_updated")
    return true

# TODO: временная миграция старых сейвов (формат "recipe"). Удалить после того,
#	   как все старые сохранения перестанут использоваться.
# Конвертирует старые записи зданий {"id": ..., "recipe": ...} в новый формат {"id": ..., "slots": [...]}.
func migrate_old_save_format():
    for bld in city_built_buildings:
        if not bld.has("slots"):
            bld["slots"] = _slots_from_legacy(bld)
            bld.erase("recipe")

# TODO: временная миграция. Удалить вместе с migrate_old_save_format().
func _slots_from_legacy(bld: Dictionary) -> Array:
    var building_id = bld.get("id", "")
    var slots = _auto_assign_slots(building_id)
    var legacy_recipe = bld.get("recipe", "")
    # Если в старом сейве был конкретный рецепт — ставим его в первый слот
    if legacy_recipe != "" and legacy_recipe != "empty":
        if slots.size() > 0:
            slots[0] = legacy_recipe
        else:
            slots.append(legacy_recipe)
    return slots

# Списывает additional_cost здания со склада. Поддерживает обе формы поля
# (объект и массив пачек с AND-логикой) и групповые ключи (@xxx) — для них
# списание распределяется по членам группы, как в рецептах.
# Атомарно: если хотя бы одной пачки не хватает — НИЧЕГО не списывается.
# Возвращает { "ok": true } при успехе или { "ok": false, "missing": [имена...] }.
func consume_additional_cost(bdata: Dictionary) -> Dictionary:
    # Дебаг: при включённом «Игнорировать требования строительства»
    # дополнительные материалы не проверяются и не списываются.
    if ignore_build_requirements:
        return {"ok": true}
    if not bdata.has("additional_cost"):
        return {"ok": true}
    var bundles = GameData.parse_additional_cost(bdata["additional_cost"])
    if bundles.is_empty():
        return {"ok": true}

    # Первый проход: проверяем, что всего хватает, и собираем план списания
    # [{ "prod_id": amount, ... }, ...] — по плану на каждую пачку.
    var plan: Array = []
    var missing: Array = []
    for bundle in bundles:
        var bundle_plan: Dictionary = {}
        for res_id in bundle:
            var required: int = int(bundle[res_id])
            if required <= 0:
                continue
            if GameData.is_group_key(res_id):
                var group_key = res_id.trim_prefix("@")
                var group_products = GameData.product_groups.get(group_key, [])
                if group_products.is_empty():
                    group_products = GameData.product_groups.get(_get_group_id_by_name(group_key), [])
                if group_products.is_empty():
                    missing.append(res_id)
                    continue
                var total_available := 0
                for prod in group_products:
                    total_available += city_storage.get(prod, 0)
                if total_available < required:
                    missing.append(res_id)
                    continue
                # Собираем сколько откуда брать (жадно по списку группы)
                var remaining = required
                for prod in group_products:
                    var available = city_storage.get(prod, 0)
                    if available <= 0:
                        continue
                    var take = min(available, remaining)
                    if take > 0:
                        bundle_plan[prod] = bundle_plan.get(prod, 0) + take
                        remaining -= take
                        if remaining <= 0:
                            break
            else:
                if city_storage.get(res_id, 0) < required:
                    missing.append(res_id)
                    continue
                bundle_plan[res_id] = bundle_plan.get(res_id, 0) + required
        plan.append(bundle_plan)

    if not missing.is_empty():
        return {"ok": false, "missing": missing}

    # Второй проход: всё проверено — списываем. Приоритет качества — как
    # в рецептах (по умолчанию «лучшее»).
    var priority = GameData.get_quality_priority_default()
    for bundle_plan in plan:
        for prod in bundle_plan:
            var amount: int = int(bundle_plan[prod])
            remove_from_storage(prod, amount, priority)
            consumption_rates[prod] = consumption_rates.get(prod, 0) + amount
    return {"ok": true}

func request_build(building_id: String) -> bool:
    if Engine.is_editor_hint():
        return false
    var bdata = null
    for b in GameData.buildings:
        if b["id"] == building_id:
            bdata = b
            break
    if not bdata:
        return false
    # Здание должно быть открыто изученной технологией
    if not is_building_unlocked(building_id):
        print("Здание недоступно: ", bdata.get("name", building_id))
        return false
    var additional_req_check = check_building_additional_req(building_id)
    if not additional_req_check["ok"]:
        print("Не выполнено условие для постройки ",
            bdata.get("name", building_id), ": ", additional_req_check["reason"])
        return false
    # Списываем additional_cost (если есть) — атомарно, до старта стройки.
    # Поддерживает массив пачек (AND-логика) и групповые ключи (@xxx).
    var cost_check = consume_additional_cost(bdata)
    if not cost_check["ok"]:
        print("Не хватает ресурсов для постройки ", bdata.get("name", building_id), ": ", cost_check.get("missing", []))
        return false
    var work_cost = bdata.get("work_cost", 0)
    # Общий лимит одновременных строек (здания + улучшения) равен общему числу жителей.
    # При включённом «Игнорировать требования строительства» лимит не применяется —
    # здания строятся мгновенно и не попадают в очередь строек.
    if work_cost > 0 and not ignore_build_requirements:
        var main_map = get_tree().root.find_child("MainMap", true, false)
        var bm = main_map.get_node("BuildManager") if main_map and main_map.has_node("BuildManager") else null
        var total_active = building_construction.size()
        if bm:
            total_active = bm.get_total_active_builds()
        if total_active >= total_population:
            print("Можно строить не более %d зданий или улучшений одновременно (лимит = число жителей)" % total_population)
            return false
    # Строительство зданий теперь требует труд, а не еду. При включённом
    # «Игнорировать требования строительства» даже здания с work_cost > 0
    # строятся мгновенно (флаг CityData.ignore_build_requirements).
    if work_cost <= 0 or ignore_build_requirements:
        # Если стоимость 0 (например, ручная мельница), строим мгновенно
        city_built_buildings.append({"id": building_id, "slots": _auto_assign_slots(building_id)})

        # Автоматически назначаем горожанина на новое здание, если есть свободные
        var townsfolk_map = get_tree().root.find_child("MainMap", true, false)
        if townsfolk_map and townsfolk_map.has_node("TownsfolkManager"):
            var tm = townsfolk_map.get_node("TownsfolkManager")
            tm.assign_townsfolk()

        emit_signal("city_updated")
        return true

    # Для зданий с work_cost > 0 запускаем стройку через build_manager
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map and main_map.has_node("BuildManager"):
        var bm = main_map.get_node("BuildManager")
        var build_key = bm.start_building_build(building_id)
        if build_key != "":
            # Сохраняем стройку в отдельный словарь, здание появится в городе только после завершения
            building_construction[build_key] = {
                "building_id": building_id,
                "build_key": build_key,
                "slots": _auto_assign_slots(building_id)
            }
            emit_signal("building_construction_started", building_id, build_key)
            emit_signal("city_updated")
            return true
        return false

    # Если build_manager недоступен, строим мгновенно (fallback)
    city_built_buildings.append({"id": building_id, "slots": _auto_assign_slots(building_id)})
    if main_map and main_map.has_node("TownsfolkManager"):
        var tm2 = main_map.get_node("TownsfolkManager")
        tm2.assign_townsfolk()
    emit_signal("city_updated")
    return true

# Автоназначение рецептов на слоты при постройке здания:
# 1. Берём default_recipes здания
# 2. Назначаем на слоты по порядку, без повторения
# 3. Если слотов больше, чем рецептов — остальные получают "empty"
# 4. Если рецептов больше, чем слотов — лишние просто не помещаются
func _auto_assign_slots(building_id: String) -> Array:
    var result = []
    var bdata = null
    for b in GameData.buildings:
        if b["id"] == building_id:
            bdata = b
            break
    if not bdata:
        return result

    var slot_count = int(bdata.get("production_slots", 1))
    var default_recipes = bdata.get("default_recipes", [])

    for i in range(slot_count):
        if i < default_recipes.size():
            result.append(default_recipes[i])
        else:
            result.append("empty")
    return result

# Возвращает true, если все слоты здания пусты (рецепт "Пусто" или "").
# Используется для отображения статуса "простаивает".
func are_all_slots_empty(b_index: int) -> bool:
    if b_index < 0 or b_index >= city_built_buildings.size():
        return false
    var bld = city_built_buildings[b_index]
    var slots = bld.get("slots", [])
    if slots.is_empty():
        return false
    for recipe_id in slots:
        if recipe_id != "" and recipe_id != "empty":
            return false
    return true

# Проверяет, может ли рецепт исполняться в указанном здании.
# produced_in поддерживает массив значений; "*" означает "в любом здании" (пустой рецепт).
func can_craft_in(craft_id: String, building_id: String) -> bool:
    var recipe = null
    for c in GameData.crafts:
        if c["id"] == craft_id:
            recipe = c
            break
    if not recipe:
        return false

    var produced_in = recipe.get("produced_in", [])
    # Обратная совместимость: если produced_in — строка, приводим к массиву
    if produced_in is String:
        produced_in = [produced_in]

    if building_id in produced_in:
        return true
    if "*" in produced_in:
        return true
    return false

func add_animal(animal_id: String):
    if Engine.is_editor_hint():
        return
    register_domesticated_resource(animal_id)

func register_domesticated_resource(res_id: String):
    if Engine.is_editor_hint() or not GameData.raw_resources.has(res_id):
        return
    if not MapHelpers.can_breed_resource(res_id):
        return
    if MapHelpers.get_breeding_improvement(res_id).is_empty():
        return
    if not (res_id in domesticated_resources):
        domesticated_resources.append(res_id)

func add_plant(plant_id: String):
    if Engine.is_editor_hint():
        return
    register_domesticated_resource(plant_id)

func is_product_available(product_id: String) -> bool:
    return _is_product_available(product_id)

# Возвращает итоговый множитель производства для улучшения imp_id.
# has_fresh_water — есть ли доступ к пресной проточной воде на гексе.
# terrain_id — тип местности гекса (для модификаторов по местности,
#   например, асфальтовое озеро даёт x2 к битуму).
# resource_id — id ресурса на гексе (для модификаторов по местности).
func get_improvement_production_multiplier(imp_id: String, has_fresh_water: bool,
        terrain_id: String = "", resource_id: String = "") -> float:
    var multiplier = 1.0
    for mod in get_improvement_production_modifiers(imp_id, has_fresh_water, terrain_id, resource_id):
        multiplier *= mod.get("multiplier", 1.0)
    return multiplier

# Возвращает список активных модификаторов производства для улучшения imp_id.
# Каждый элемент: { "label": String, "multiplier": float }
# terrain_id — тип местности гекса (для модификаторов по местности).
# resource_id — id ресурса на гексе (для модификаторов по местности).
func get_improvement_production_modifiers(imp_id: String, has_fresh_water: bool,
        terrain_id: String = "", resource_id: String = "") -> Array:
    var result = []
    if imp_id == null or imp_id == "":
        return result

    # Модификатор доступа к пресной проточной воде
    if has_fresh_water:
        var fw = GameData.modifiers.get("fresh_water", {})
        var multipliers = fw.get("production_multiplier", {})
        if multipliers.has(imp_id):
            var m = float(multipliers[imp_id])
            if m != 1.0:
                result.append({
                    "label": "+%d%% (Доступ к пресной воде)" % int(round((m - 1.0) * 100.0)),
                    "multiplier": m
                })

    # Модификаторы по типу местности (terrain_modifiers).
    # Применяются, когда на гексе с указанным terrain_id добывается
    # указанный resource_id (через улучшение). Например, битум на
    # асфальтовом озере (asphalt_lake) даёт x2 к производству.
    # См. data/modifiers.json, блок "terrain_modifiers".
    if terrain_id != "" and resource_id != "":
        for tm in GameData.modifiers.get("terrain_modifiers", []):
            if tm.get("terrain_id", "") != terrain_id:
                continue
            if tm.get("resource_id", "") != resource_id:
                continue
            var m = float(tm.get("production_multiplier", 1.0))
            if m != 1.0:
                var terrain_name: String = GameData.terrains.get(terrain_id, {}).get("name", terrain_id)
                result.append({
                    "label": "x%.1f (%s)" % [m, terrain_name],
                    "multiplier": m
                })

    # Модификаторы от изученных технологий
    for tm in GameData.modifiers.get("tech_modifiers", []):
        var tech_id = tm.get("tech_id", "")
        if tech_id == "" or not is_tech_unlocked(tech_id):
            continue
        var tech_name = tech_id
        for t in GameData.technologies:
            if t["id"] == tech_id:
                tech_name = t["name"]
                break

        # Универсальный формат: "production_multiplier": { "<imp_id>": 1.05 }
        # (по аналогии с бонусом от пресной воды).
        var multipliers = tm.get("production_multiplier", {})
        if multipliers.has(imp_id):
            var m = float(multipliers[imp_id])
            if m != 1.0:
                result.append({
                    "label": "+%d%% (%s)" % [int(round((m - 1.0) * 100.0)), tech_name],
                    "multiplier": m
                })

        # Старый формат с полем "modifiers" (target == "<imp_id>_production").
        for mod in tm.get("modifiers", []):
            var target = mod.get("target", "")
            if target != imp_id + "_production":
                continue
            var mod_type = mod.get("type", "percent")
            var value = float(mod.get("value", 0))
            var multiplier = 1.0
            if mod_type == "percent":
                multiplier = 1.0 + value / 100.0
            else:
                multiplier = value
            result.append({
                "label": "+%d%% (%s)" % [int(value), tech_name],
                "multiplier": multiplier
            })
    return result
