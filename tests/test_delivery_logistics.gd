# Headless-тест логистики доставки товаров (scripts/delivery_manager.gd).
#   godot --headless --path . --script res://tests/test_delivery_logistics.gd
#
# Две характеристики маршрута независимы: длина задаёт задержку доставки
# (длина × transit_time_per_hex), а уровни участков — интенсивность потока
# (средняя max_speed). Пропускная способность ограничивается ДЛЯ КАЖДОГО МАРШРУТА
# ОТДЕЛЬНО и делится между всеми партиями одного маршрута; разные маршруты не
# конкурируют. Излишек собственного производства не теряется, а ждёт отправки.
#
# Кейсы (фильтр --case=<подстрока>):
#   delay              — до истечения задержки товар не поступает, после — поступает;
#   flow_cap           — поступление не превышает интенсивность маршрута;
#   batch_size         — крупная партия доставляется дольше мелкой;
#   shared_route       — несколько партий на одном маршруте делят его лимит;
#   repeat_purchases   — повторные покупки не обходят ограничение;
#   simultaneous       — партии могут быть в пути одновременно;
#   independent_routes — разные маршруты независимы;
#   no_loss            — ни дублей, ни потерь;
#   save_load          — сохранение и загрузка очереди и груза в пути;
#   time_scale         — нулевая дельта не двигает доставку, крупная — двигает;
#   road_upgrade       — более быстрый маршрут отгружает быстрее;
#   length_scales_delay— более длинный маршрут доставляет дольше;
#   balance_driven     — коэффициент задержки берётся из game_balance;
#   production_queue   — производство улучшения уходит в очередь, а не на склад;
#   queue_only_backlog — очередь «ожидает отправки» показывает только реальный затор.
#
# Тесты не фиксируют балансные числа (10/30, 0.2): параметры маршрута задаются
# явно, а ожидания выводятся из них и из SHIP_STEP самого менеджера, поэтому
# правка data/game_balance.json и data/roads.json не ломает эти проверки.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")

var _gdata = null
var _cdata = null

# Заглушка карты: маршрут по ключу "row,col" -> {ok, length, avg_speed}. Позволяет
# гонять менеджер без сцены, дорог и генерации карты — быстро и детерминированно.
class FakeMap:
    var routes: Dictionary = {}
    func set_route(row: int, col: int, length: int, avg_speed: float) -> void:
        routes["%d,%d" % [row, col]] = {"ok": true, "length": length, "avg_speed": avg_speed}
    func clear_route(row: int, col: int) -> void:
        routes.erase("%d,%d" % [row, col])
    func get_route_to_city(row: int, col: int) -> Dictionary:
        return routes.get("%d,%d" % [row, col], {"ok": false})

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state := {"failed": false}
    get_root().get_node("SaveManager").new_game()
    _gdata = get_root().get_node("GameData")
    _cdata = get_root().get_node("CityData")

    if WATCHDOG.wants_case("delay"):
        _test_delay(state)
    if WATCHDOG.wants_case("flow_cap"):
        _test_flow_cap(state)
    if WATCHDOG.wants_case("batch_size"):
        _test_batch_size(state)
    if WATCHDOG.wants_case("shared_route"):
        _test_shared_route(state)
    if WATCHDOG.wants_case("repeat_purchases"):
        _test_repeat_purchases(state)
    if WATCHDOG.wants_case("simultaneous"):
        _test_simultaneous(state)
    if WATCHDOG.wants_case("independent_routes"):
        _test_independent_routes(state)
    if WATCHDOG.wants_case("no_loss"):
        _test_no_loss(state)
    if WATCHDOG.wants_case("save_load"):
        _test_save_load(state)
    if WATCHDOG.wants_case("time_scale"):
        _test_time_scale(state)
    if WATCHDOG.wants_case("road_upgrade"):
        _test_road_upgrade(state)
    if WATCHDOG.wants_case("length_scales_delay"):
        _test_length_scales_delay(state)
    if WATCHDOG.wants_case("balance_driven"):
        _test_balance_driven(state)
    if WATCHDOG.wants_case("production_queue"):
        await _test_production_queue(state)
    if WATCHDOG.wants_case("queue_only_backlog"):
        await _test_queue_only_backlog(state)

    WATCHDOG.report_skipped()
    if state["failed"]:
        print("DELIVERY LOGISTICS TEST FAILED")
        quit(1)
    else:
        print("DELIVERY LOGISTICS TEST OK")
        quit(0)


# -------------------------------------------------------
# 1. Задержка: до истечения — пусто, после — приходит
# -------------------------------------------------------

func _test_delay(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    fake.set_route(5, 5, 10, 10.0)
    check(dm.create_cargo(5, 5, "clay", "common", 5, "@imp:farm"),
            "груз с маршрутом должен приниматься в очередь", state)

    # Первый шаг отгружает груз (он на дороге), но на склад он не попадает.
    _step(dm)
    check(_delivered("clay") == 0,
            "товар не должен поступать до окончания задержки (получено %d)"
                    % _delivered("clay"), state)

    # Груз отгружен на предыдущем шаге. Прокручиваем чуть меньше задержки после
    # отправки — на складе по-прежнему пусто.
    var delay: float = 10.0 * dm.get_transit_time_per_hex()
    _advance(dm, delay - dm.SHIP_STEP)
    check(_delivered("clay") == 0,
            "товар не должен поступать до окончания задержки (получено %d)"
                    % _delivered("clay"), state)

    # Остаток задержки — и весь груз на складе.
    _advance(dm, dm.SHIP_STEP + 0.001)
    check(_delivered("clay") == 5,
            "после задержки весь груз должен прийти (получено %d)" % _delivered("clay"), state)

    # Нет маршрута — груз не принимается (некуда везти).
    check(not dm.create_cargo(1, 1, "clay", "common", 5, "@imp:farm"),
            "без маршрута груз не должен приниматься", state)
    dm.free()


# -------------------------------------------------------
# 2. Поступление не превышает интенсивность маршрута
# -------------------------------------------------------

func _test_flow_cap(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    var flow := 10.0
    fake.set_route(5, 5, 3, flow)
    dm.create_cargo(5, 5, "clay", "common", 25, "@imp:farm")

    var prev := 0
    var steps := 0
    var worst := 0
    while _delivered("clay") < 25 and steps < 200:
        _step(dm)
        var now := _delivered("clay")
        worst = maxi(worst, now - prev)
        prev = now
        steps += 1
    check(_delivered("clay") == 25,
            "вся партия должна дойти (получено %d)" % _delivered("clay"), state)
    check(float(worst) <= flow + 0.001,
            "поступление за шаг не должно превышать интенсивность маршрута %.1f (получено %d)"
                    % [flow, worst], state)
    dm.free()


# -------------------------------------------------------
# 3. Крупная партия доставляется дольше мелкой
# -------------------------------------------------------

func _test_batch_size(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    # Одинаковый маршрут, разный размер партии: крупная едет дольше.
    var small := _time_to_deliver(fake, 10, 10, 10.0)
    var big := _time_to_deliver(fake, 100, 10, 10.0)
    check(small > 0.0 and big > small,
            "крупная партия должна доставляться дольше мелкой (%.1f против %.1f)" % [big, small],
            state)
    dm.free()


# -------------------------------------------------------
# 4-5. Общий лимит маршрута: партии и повторные покупки
# -------------------------------------------------------

func _test_shared_route(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    var flow := 10.0
    fake.set_route(5, 5, 3, flow)
    # Две партии на одном маршруте, вторая оформлена через секунду после первой.
    dm.create_cargo(5, 5, "clay", "common", 100, "@imp:farm")
    _step(dm)
    dm.create_cargo(5, 5, "clay", "common", 100, "@imp:farm")

    var prev := 0
    var steps := 0
    var worst := 0
    while _delivered("clay") < 200 and steps < 500:
        _step(dm)
        var now := _delivered("clay")
        worst = maxi(worst, now - prev)
        prev = now
        steps += 1
    check(_delivered("clay") == 200,
            "обе партии должны дойти целиком (получено %d)" % _delivered("clay"), state)
    check(float(worst) <= flow + 0.001,
            "партии одного маршрута делят его лимит %.1f (пик поступления %d)"
                    % [flow, worst], state)
    dm.free()


func _test_repeat_purchases(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    var flow := 8.0
    fake.set_route(5, 5, 3, flow)
    # Много мелких партий подряд: ни одна не должна обойти общий лимит маршрута.
    var created := 0
    var prev := 0
    var worst := 0
    for i in range(40):
        dm.create_cargo(5, 5, "clay", "common", 5, "@imp:farm")
        created += 5
        _step(dm)
        var now := _delivered("clay")
        worst = maxi(worst, now - prev)
        prev = now
    check(float(worst) <= flow + 0.001,
            "повторные покупки не должны обходить лимит %.1f (пик поступления %d)"
                    % [flow, worst], state)
    dm.free()


# -------------------------------------------------------
# 6. Партии могут быть в пути одновременно
# -------------------------------------------------------

func _test_simultaneous(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    _reset_storage("wheat")
    # Маршрут подлиннее: задержка больше шага, поэтому первая партия ещё на дороге,
    # когда отправляется вторая.
    fake.set_route(5, 5, 20, 10.0)
    dm.create_cargo(5, 5, "clay", "common", 5, "@imp:farm")
    _step(dm)
    # Вторая партия другого товара оформлена, пока первая ещё на дороге.
    dm.create_cargo(5, 5, "wheat", "common", 5, "@imp:farm")
    _step(dm)
    var products := _in_transit_products(dm, 5, 5)
    check(products.has("clay") and products.has("wheat"),
            "обе партии должны быть в пути одновременно (в пути: %s)" % str(products), state)
    dm.free()


# -------------------------------------------------------
# 7. Разные маршруты независимы
# -------------------------------------------------------

func _test_independent_routes(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    _reset_storage("wheat")
    fake.set_route(5, 5, 3, 10.0)
    fake.set_route(9, 9, 3, 30.0)
    dm.create_cargo(5, 5, "clay", "common", 100, "@imp:farm")
    dm.create_cargo(9, 9, "wheat", "common", 100, "@imp:farm")
    for i in range(5):
        _step(dm)
    check(_delivered("wheat") > _delivered("clay"),
            "быстрый маршрут должен обгонять медленный (%d против %d)"
                    % [_delivered("wheat"), _delivered("clay")], state)
    check(_delivered("clay") <= 10 * 5,
            "медленный маршрут не должен получать больше своего лимита (получено %d)"
                    % _delivered("clay"), state)
    check(_delivered("wheat") <= 30 * 5,
            "быстрый маршрут не должен получать больше своего лимита (получено %d)"
                    % _delivered("wheat"), state)
    dm.free()


# -------------------------------------------------------
# 9. Ни дублей, ни потерь
# -------------------------------------------------------

func _test_no_loss(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    fake.set_route(5, 5, 4, 7.0)
    dm.create_cargo(5, 5, "clay", "common", 100, "@imp:farm")
    var steps := 0
    var peak := 0
    while _delivered("clay") < 100 and steps < 500:
        _step(dm)
        peak = maxi(peak, _delivered("clay"))
        steps += 1
    check(_delivered("clay") == 100,
            "ровно 100 единиц должны дойти, без потерь (получено %d)" % _delivered("clay"), state)
    check(peak <= 100,
            "дублей быть не должно: на складе не больше созданного (пик %d)" % peak, state)
    check(int(dm.get_route_status(5, 5).get("pending", 0)) == 0
            and int(dm.get_route_status(5, 5).get("in_transit", 0)) == 0,
            "после доставки маршрут должен опустеть", state)
    dm.free()


# -------------------------------------------------------
# 10. Сохранение и загрузка очереди и груза в пути
# -------------------------------------------------------

func _test_save_load(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    fake.set_route(5, 5, 4, 7.0)
    dm.create_cargo(5, 5, "clay", "common", 100, "@imp:farm")
    for i in range(5):
        _step(dm)

    var before: Dictionary = dm.get_route_status(5, 5)
    var data: Dictionary = dm.serialize()

    var dm2 = load("res://scripts/delivery_manager.gd").new()
    dm2.initialize(fake)
    dm2.deserialize(data)
    var after: Dictionary = dm2.get_route_status(5, 5)
    check(int(after.get("pending", 0)) == int(before.get("pending", 0)),
            "очередь ожидания должна пережить загрузку (%d -> %d)"
                    % [int(before.get("pending", 0)), int(after.get("pending", 0))], state)
    check(int(after.get("in_transit", 0)) == int(before.get("in_transit", 0)),
            "груз в пути должен пережить загрузку (%d -> %d)"
                    % [int(before.get("in_transit", 0)), int(after.get("in_transit", 0))], state)

    # После загрузки груз доезжает до конца — ровно 100, без дублей и потерь.
    var steps := 0
    while _delivered("clay") < 100 and steps < 500:
        _step(dm2)
        steps += 1
    check(_delivered("clay") == 100,
            "после загрузки весь груз должен дойти без дублей и потерь (получено %d)"
                    % _delivered("clay"), state)
    dm.free()
    dm2.free()


# -------------------------------------------------------
# 10. Пауза и масштаб времени
# -------------------------------------------------------

func _test_time_scale(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    fake.set_route(5, 5, 3, 10.0)
    dm.create_cargo(5, 5, "clay", "common", 5, "@imp:farm")

    # Нулевая дельта (пауза) ничего не двигает.
    dm.advance(0.0)
    check(_delivered("clay") == 0,
            "нулевая дельта не должна двигать доставку (получено %d)" % _delivered("clay"), state)

    # Отгружаем и доставляем одним крупным шагом — время идёт, доставка идёт.
    _step(dm)
    var delay: float = 3.0 * dm.get_transit_time_per_hex()
    dm.advance(delay + 0.001)
    check(_delivered("clay") == 5,
            "крупная дельта должна продвинуть доставку (получено %d)" % _delivered("clay"), state)
    dm.free()


# -------------------------------------------------------
# 11. Улучшение дороги ускоряет отгрузку
# -------------------------------------------------------

func _test_road_upgrade(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    fake.set_route(5, 5, 3, 10.0)
    dm.create_cargo(5, 5, "clay", "common", 100, "@imp:farm")
    _step(dm)
    var pending_slow := int(dm.get_route_status(5, 5).get("pending", 0))

    # Улучшаем маршрут: та же длина, выше интенсивность потока.
    fake.set_route(5, 5, 3, 30.0)
    _step(dm)
    var pending_fast := int(dm.get_route_status(5, 5).get("pending", 0))

    var shipped_slow := 100 - pending_slow
    var shipped_fast := pending_slow - pending_fast
    check(shipped_fast > shipped_slow,
            "после улучшения дороги за шаг должно отгружаться больше (%d против %d)"
                    % [shipped_fast, shipped_slow], state)
    dm.free()


# -------------------------------------------------------
# 12. Длина маршрута задаёт задержку (независимо от коэффициента)
# -------------------------------------------------------

func _test_length_scales_delay(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    _reset_storage("clay")
    # Одинаковый груз и поток, разная длина: длинный маршрут доставляет дольше.
    var short_time := _time_to_deliver(fake, 5, 3, 10.0)
    var long_time := _time_to_deliver(fake, 5, 30, 10.0)
    check(long_time > short_time,
            "более длинный маршрут должен доставлять дольше (%.1f против %.1f)"
                    % [long_time, short_time], state)
    dm.free()


# -------------------------------------------------------
# 12. Коэффициент задержки централизован в данных
# -------------------------------------------------------

func _test_balance_driven(state: Dictionary) -> void:
    var pair := _new_manager()
    var dm = pair[0]
    var fake: FakeMap = pair[1]
    var value: float = dm.get_transit_time_per_hex()
    check(value > 0.0, "коэффициент задержки должен быть положительным (получено %.3f)" % value, state)

    # Значение берётся из game_balance: подмена в данных меняет задержку маршрута.
    _gdata.game_balance["transit_time_per_hex"] = value * 2.0
    check(absf(dm.get_transit_time_per_hex() - value * 2.0) < 0.0001,
            "коэффициент должен читаться из game_balance", state)
    _gdata.game_balance["transit_time_per_hex"] = value
    dm.free()


# -------------------------------------------------------
# 3-4 (живая сцена). Производство уходит в очередь, а не на склад
# -------------------------------------------------------

func _test_production_queue(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    # Синтетический ресурс с управляемой скоростью: 15 единиц в секунду через
    # ферму (интервал 1). Продукт clay — всегда доступен и городом не потребляется,
    # поэтому склад не «худеет» от do_tick и баланс сходится точно.
    _gdata.raw_resources["test_clay"] = {
        "id": "test_clay", "name": "Test Clay", "type": "raw",
        "improved_by": "farm", "produces": {"clay": 15},
    }

    var spot := _find_hex_in_influence(main_map)
    check(not spot.is_empty(), "на живой карте должен найтись свободный гекс в влиянии", state)
    if spot.is_empty():
        _free(main_map)
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["resource"] = "test_clay"
    tile["improvement"] = "farm"
    main_map.road_manager.build_road_from(row, col, main_map.tile_data,
            main_map.map_rows, main_map.map_cols)
    check(main_map.road_manager.get_hex_road_level(row, col) == 1,
            "к улучшению должна быть проложена дорога", state)

    _cdata.idle_population = maxi(_cdata.idle_population, 5)
    check(main_map.worker_manager.assign_worker(row, col),
            "на улучшение должен встать работник", state)
    _cdata.city_storage["clay"] = 0
    main_map.delivery_manager.clear()

    # Один тик производства: товар уходит в очередь доставки, а не на склад.
    main_map._process(1.0)
    var status: Dictionary = main_map.delivery_manager.get_route_status(row, col)
    var queued := int(status.get("pending", 0)) + int(status.get("in_transit", 0))
    check(int(_cdata.city_storage.get("clay", 0)) == 0,
            "товар с маршрутом не должен появляться на складе мгновенно (получено %d)"
                    % int(_cdata.city_storage.get("clay", 0)), state)
    check(queued == 15,
            "все 15 произведённых единиц должны встать в очередь (получено %d)" % queued, state)

    # Останавливаем производство и даём логистике довезти груз до конца.
    main_map.worker_manager.remove_worker(row, col)
    for i in range(40):
        _step(main_map.delivery_manager)
    check(int(_cdata.city_storage.get("clay", 0)) == 15,
            "весь произведённый товар должен дойти до склада (получено %d)"
                    % int(_cdata.city_storage.get("clay", 0)), state)

    _free(main_map)


# -------------------------------------------------------
# 5. Очередь «ожидает отправки» показывает только реальный затор
# -------------------------------------------------------

# Регрессия: панель управления читает очередь ВНУТРИ тика (do_tick испускает
# city_updated), поэтому отгрузка тика обязана произойти ДО этого чтения. Иначе
# свежая продукция секунды висит как «ожидает отправки» даже на дороге, которая
# везёт всё. Здесь проверяются оба конца: при потоке не ниже производства очередь
# пуста, при производстве выше потока очередь — реальный затор.
func _test_queue_only_backlog(state: Dictionary) -> void:
    var main_map = load("res://scenes/MainMap.tscn").instantiate()
    get_root().add_child(main_map)
    await process_frame
    await process_frame
    await process_frame

    # Синтетический ресурс с малой скоростью (1 ед./сек через ферму): заведомо
    # ниже потока любой дороги, поэтому очередь не должна появляться вовсе.
    _gdata.raw_resources["test_clay"] = {
        "id": "test_clay", "name": "Test Clay", "type": "raw",
        "improved_by": "farm", "produces": {"clay": 1},
    }

    var spot := _find_hex_in_influence(main_map)
    check(not spot.is_empty(), "на живой карте должен найтись свободный гекс в влиянии", state)
    if spot.is_empty():
        _free(main_map)
        return
    var row := int(spot.row)
    var col := int(spot.col)
    var tile: Dictionary = main_map.tile_data[row][col]
    tile["resource"] = "test_clay"
    tile["improvement"] = "farm"
    main_map.road_manager.build_road_from(row, col, main_map.tile_data,
            main_map.map_rows, main_map.map_cols)
    check(main_map.road_manager.get_hex_road_level(row, col) == 1,
            "к улучшению должна быть проложена дорога", state)

    _cdata.idle_population = maxi(_cdata.idle_population, 5)
    main_map.worker_manager.assign_worker(row, col)
    _cdata.city_storage["clay"] = 0
    main_map.delivery_manager.clear()

    var flow := float(main_map.get_route_to_city(row, col).get("avg_speed", 0.0))
    check(flow > 1.0, "маршрут должен нести хотя бы 1 ед./сек (получено %.1f)" % flow, state)

    # Ключевой момент: панель и тултип читают очередь ВНУТРИ тика — на сигнал
    # city_updated, который do_tick испускает ПОСЛЕ производства. Поэтому снимок
    # очереди берётся здесь же, в обработчике сигнала, а не после _process: иначе
    # тест увидел бы уже отгруженное состояние и не поймал бы порядок.
    var capture := {"pending": -1}
    var capture_pending := func():
        var st: Dictionary = main_map.delivery_manager.get_route_status(row, col)
        capture["pending"] = int(st.get("pending", 0))
    _cdata.city_updated.connect(capture_pending)

    # Один тик: произведено не больше потока — очереди быть не должно.
    main_map._process(1.0)
    _cdata.city_updated.disconnect(capture_pending)

    var status: Dictionary = main_map.delivery_manager.get_route_status(row, col)
    var produced := int(_cdata.city_storage.get("clay", 0)) \
            + int(status.get("pending", 0)) + int(status.get("in_transit", 0))
    check(float(produced) <= flow,
            "тестовый тик должен произвести не больше потока %.1f (произведено %d)"
                    % [flow, produced], state)
    check(int(capture["pending"]) == 0,
            "очередь, которую читает интерфейс на тике, должна быть пуста при потоке %.1f (получено %d)"
                    % [flow, int(capture["pending"])], state)

    # Резко поднимаем производство выше потока: теперь очередь — реальный затор.
    _gdata.raw_resources["test_clay"]["produces"]["clay"] = int(flow) * 20 + 100
    main_map._process(1.0)
    status = main_map.delivery_manager.get_route_status(row, col)
    check(int(status.get("pending", 0)) > 0,
            "при производстве выше потока очередь должна расти (получено %d)"
                    % int(status.get("pending", 0)), state)

    _free(main_map)


# -------------------------------------------------------
# Хелперы
# -------------------------------------------------------

# Новый менеджер логистики на свежей заглушке карты: [менеджер, заглушка].
func _new_manager() -> Array:
    var fake := FakeMap.new()
    var dm = load("res://scripts/delivery_manager.gd").new()
    dm.initialize(fake)
    return [dm, fake]


# Один шаг игрового времени: приёмка (кадровая) + одна отгрузка (тиковая) — тот же
# порядок, что и в main_map._process. Отгрузка вызывается ПОСЛЕ приёмки, как и в игре.
func _step(dm) -> void:
    dm.advance(dm.SHIP_STEP)
    dm.ship()


# Время (в секундах игрового времени) до полной доставки amount единиц по маршруту
# с заданной длиной и интенсивностью. Гоняет СВОЙ менеджер, чтобы остаток
# аккумулятора предыдущего кейса не сдвигал отсчёт.
func _time_to_deliver(fake: FakeMap, amount: int, length: int, flow: float) -> float:
    var dm = load("res://scripts/delivery_manager.gd").new()
    dm.initialize(fake)
    _reset_storage("clay")
    fake.set_route(5, 5, length, flow)
    dm.create_cargo(5, 5, "clay", "common", amount, "@imp:farm")
    var elapsed := 0.0
    var steps := 0
    while _delivered("clay") < amount and steps < 1000:
        _step(dm)
        elapsed += dm.SHIP_STEP
        steps += 1
    dm.free()
    return elapsed


# Прокрутка только приёмки на seconds игрового времени шагами по SHIP_STEP:
# отгрузка НЕ вызывается — так проверяется, что груз доезжает сам по отсчёту времени.
func _advance(dm, seconds: float) -> void:
    var left := seconds
    while left > 0.0001:
        var step: float = minf(dm.SHIP_STEP, left)
        dm.advance(step)
        left -= step


func _in_transit_products(dm, row: int, col: int) -> Array:
    var key := "%d,%d" % [row, col]
    var out: Array = []
    if not dm._routes.has(key):
        return out
    for entry in dm._routes[key]["in_transit"]:
        out.append(str(entry["product"]))
    return out


func _delivered(pid: String) -> int:
    return int(_cdata.city_storage.get(pid, 0))


func _reset_storage(pid: String) -> void:
    _cdata.city_storage[pid] = 0
    _cdata.city_quality_detail[pid] = {}


# Первый свободный гекс в Кольце Влияния: сухой, известный, без улучшения,
# городка и дороги, без доступа к пресной воде (иначе множитель производства
# сдвинется) — И с достижимым планом дороги.
func _find_hex_in_influence(main_map) -> Dictionary:
    var mh = load("res://scripts/map_helpers.gd")
    for row in range(main_map.influence_start_row, main_map.influence_end_row + 1):
        for col in range(main_map.influence_start_col, main_map.influence_end_col + 1):
            var tile = main_map.tile_data[row][col]
            if tile == null or tile.get("improvement", null) != null:
                continue
            if tile.get("has_town", false) or tile.get("decorative", false):
                continue
            if tile.get("in_town_influence", false):
                continue
            if not main_map.is_hex_known(row, col):
                continue
            if mh.is_water_terrain(tile.get("terrain", "plain")):
                continue
            if mh.get_hex_water_access(row, col, main_map.tile_data,
                    main_map.map_rows, main_map.map_cols) != "":
                continue
            if main_map.road_manager.get_hex_road_level(row, col) > 0:
                continue
            var plan: Dictionary = main_map.get_road_plan(row, col)
            if not plan.get("ok", false):
                continue
            return {"row": row, "col": col}
    return {}


func _free(main_map) -> void:
    if main_map != null and is_instance_valid(main_map):
        get_root().remove_child(main_map)
        main_map.free()


func check(condition: bool, message: String, state: Dictionary) -> void:
    if condition:
        return
    state["failed"] = true
    print("FAILED: %s" % message)
    push_error("ASSERT: %s" % message)
