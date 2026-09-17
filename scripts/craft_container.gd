# craft_container.gd
# Контейнер непрерывного (continuous) крафта для одного слота здания.
#
# Принцип: НЕ пакетная транзакция по завершении интервала, а постепенное
# заполнение ингредиентами с заданной скоростью (amount / time ед./сек)
# и завершение, когда ВСЕ ингредиенты накоплены И прошло craft_time секунд.
#
# При дефиците сырья контейнер «замерзает»: fractional/filled не растут,
# время не копит — крафт автоматически затягивается до появления сырья.
#
# Структура одного слота ингредиента:
#   {
#     "kind": "single" | "group",     # одиночный продукт или @-группа
#     "pid": "...",                   # id одиночного продукта
#     "group_key": "...",             # ключ @-группы (например "fruits")
#     "members": ["..."],             # id членов @-группы
#     "required": int,                # сколько единиц нужно набрать
#     "filled": int,                  # уже набрано (целое)
#     "fractional": float,            # дробный остаток за тик
#     "consumed": [{ qty: int, quality: String }],  # для качества результата
#   }
#
# Качество результата рассчитывается в момент завершения крафта как
# взвешенное среднее качеств всех «входов» (consumed) — это прямой аналог
# текущего поведения quality_from_breakdown().
#
# Состояние сериализуется через serialize()/deserialize() и сохраняется
# вместе с city_built_buildings (без отдельного ключа в сейве).
#
# Зависимости: CityData (autoload) для списания со склада и групповых
# определений. Контейнер рассчитан на то, что CityData уже загружен.

class_name CraftContainer
extends RefCounted

var recipe_id: String = ""
var craft_time: float = 1.0      # секунд на полный цикл (recipe.time)
var elapsed: float = 0.0          # секунд с момента последнего reset()
var ingredient_slots: Array = []  # массив словарей (см. шапку файла)
# Результат рецепта: { "pid": full_amount, ... }. Кэшируется при создании
# контейнера, чтобы tick() мог рассчитывать постепенный выпуск без повторного
# чтения рецепта каждый кадр.
var result_products: Dictionary = {}
# Sub-unit accumulator для выпуска результата: pid -> float. Хранит дробный
# остаток «сколько единиц продукта накопилось с прошлого фактического добавления
# на склад». На тике добавляем per_release = full_amount * SIMULATION_TICK /
# craft_time; когда накопится >= 1.0, выпускаем целую часть на склад и
# записываем как потребление/производство. Это согласует UI-метку «[+N≈]»
# с фактом на складе: 10/10 сек = +1 каждый тик (а не +10 раз в 10 сек).
var release_fractional: Dictionary = {}

# Конструирует контейнер по рецепту. Если передан slot_data — используется
# как восстановленное состояние (из сейва). Иначе — пустой контейнер.
#
# recipe — словарь рецепта из GameData.crafts:
#   {
#     "id": "...",
#     "time": 5.0,
#     "resources": { "pid_or_@group": amount, ... },
#     "result": { "pid": amount, ... }
#   }
func _init(recipe: Dictionary = {}, slot_data: Dictionary = {}):
    if not recipe.is_empty():
        recipe_id = str(recipe.get("id", ""))
        craft_time = _resolve_craft_time(recipe)
        if slot_data.is_empty():
            ingredient_slots = _build_slots_from_recipe(recipe)
        else:
            _restore_from_slot_data(recipe, slot_data)
        _init_release_state(recipe)
    elif not slot_data.is_empty():
        # Восстановление без рецепта (теоретически; обычно рецепт есть).
        recipe_id = str(slot_data.get("recipe_id", ""))
        craft_time = float(slot_data.get("craft_time", 1.0))
        elapsed = float(slot_data.get("elapsed", 0.0))
        ingredient_slots = slot_data.get("slots", [])
        # release_fractional восстанавливается по сохранённому dict.
        var saved_release = slot_data.get("release_fractional", {})
        release_fractional = saved_release if saved_release is Dictionary else {}

# Инициализирует кэш результата и sub-unit accumulator.
func _init_release_state(recipe: Dictionary):
    var prod: Dictionary = recipe.get("result", {})
    result_products = {}
    release_fractional = {}
    for pid in prod:
        var amt = int(prod[pid])
        if amt <= 0:
            continue
        result_products[pid] = amt
        release_fractional[pid] = 0.0

# --- ТИК СИМУЛЯЦИИ ---
# Продвигает контейнер на delta секунд. is_active = false — контейнер
# заморожен (нет горожанина на здании): ничего не забираем и не копим время.
#
# quality_priority — "best" / "worst" / "random": приоритет качества при
# заборе со склада. Для @-групп всегда жадно по "best" внутри одного тика.
#
# Возвращает словарь:
#   {
#     "completed": bool,                       # true если контейнер полон И прошло craft_time
#     "consumed_breakdown": { pid: { quality: count } },  # разбивка по качествам (для расчёта качества результата)
#     "missing": [String],                     # ключи ингредиентов, которых не хватает (для UI/тултипа)
#     "releases": [{ "pid": "...", "amount": N, "quality": "..." }]  # что выпустить на склад в этот тик
#   }
func tick(delta: float, is_active: bool, quality_priority: String = "best") -> Dictionary:
    var result := {
        "completed": false,
        "consumed_breakdown": {},
        "missing": [],
        "releases": []
    }
    if not is_active:
        return result

    elapsed += delta
    var all_full := true
    for slot in ingredient_slots:
        var required_total = int(slot.get("required", 0))
        var filled_now = int(slot.get("filled", 0))
        if filled_now >= required_total:
            continue

        # Скорость потребления: required / craft_time единиц/сек
        var per_sec := 0.0
        if craft_time > 0.0:
            per_sec = float(required_total) / craft_time

        # Sub-unit accumulator: дробный остаток копится, чтобы средняя
        # скорость была точной (например, 21/5 = 4.2 → чередуем 4 и 5).
        var fractional = float(slot.get("fractional", 0.0))
        var to_take_total = per_sec * delta + fractional
        var to_take_int = int(floor(to_take_total))
        fractional = to_take_total - float(to_take_int)
        slot["fractional"] = fractional

        if to_take_int <= 0:
            all_full = false
            continue

        # Пытаемся забрать to_take_int со склада.
        var take_res := _take_from_storage(slot, to_take_int, quality_priority)
        var taken = int(take_res.get("taken", 0))
        var breakdown: Dictionary = take_res.get("breakdown", {})
        var taken_pids: Dictionary = take_res.get("pids", {})

        if taken <= 0:
            all_full = false
            result["missing"].append(_slot_display_key(slot))
            continue

        slot["filled"] = filled_now + taken

        # Записываем «входы» для последующего расчёта качества результата.
        var consumed_arr: Array = slot.get("consumed", [])
        for qid in breakdown:
            var cnt = int(breakdown[qid])
            if cnt <= 0:
                continue
            consumed_arr.append({"qty": cnt, "quality": str(qid)})
        slot["consumed"] = consumed_arr

        # Суммируем consumed_breakdown по pid.
        for consumed_pid in taken_pids:
            if not result["consumed_breakdown"].has(consumed_pid):
                result["consumed_breakdown"][consumed_pid] = {}
            var agg: Dictionary = result["consumed_breakdown"][consumed_pid]
            for qid in breakdown:
                agg[qid] = int(agg.get(qid, 0)) + int(breakdown[qid])

        if taken < to_take_int:
            all_full = false
            var key = _slot_display_key(slot)
            if not result["missing"].has(key):
                result["missing"].append(key)

    # --- ПОСТЕПЕННЫЙ ВЫПУСК РЕЗУЛЬТАТА ---
    # Каждый тик контейнер накапливает дробный остаток per_release = full_amount
    # × delta / craft_time для каждого pid в result_products. Когда
    # release_fractional[pid] >= 1.0, выпускаем целую часть на склад (с качеством,
    # рассчитанным из накопленного consumed на текущий момент).
    #
    # Качество выпуска пересчитывается каждый тик — оно зависит от того, сколько
    # сырья уже забрано. Если рецепт работает в полном объёме (все ингредиенты
    # доступны), качество сходится к финальному взвешенному среднему к концу
    # цикла. Если в каком-то тике контейнер «замёрз» из-за дефицита,
    # потребление тоже останавливается, и выпуск временно приостанавливается
    # (per_release копится, но release_fractional не растёт, потому что мы
    # выпускаем только когда elapsed растёт — а он растёт всегда при is_active).
    #
    # При completed добиваем остаток fractional, чтобы выпустить ровно full_amount.
    if craft_time > 0.0 and is_active and all_full:
        for pid in result_products:
            var full_amount: int = int(result_products[pid])
            if full_amount <= 0:
                continue
            var per_release: float = float(full_amount) * delta / craft_time
            var frac: float = float(release_fractional.get(pid, 0.0)) + per_release
            var floor_amount: int = int(floor(frac))
            frac = frac - float(floor_amount)
            release_fractional[pid] = frac
            if floor_amount > 0:
                var release_quality := _compute_quality_from_consumed()
                result["releases"].append({
                    "pid": pid,
                    "amount": floor_amount,
                    "quality": release_quality
                })

    # При completed добиваем остаток fractional (если осталось < 1.0 к концу цикла).
    var became_complete := all_full and elapsed >= craft_time
    if became_complete:
        for pid in result_products:
            var leftover: float = float(release_fractional.get(pid, 0.0))
            if leftover > 0.0:
                var release_quality := _compute_quality_from_consumed()
                result["releases"].append({
                    "pid": pid,
                    "amount": int(leftover),
                    "quality": release_quality
                })
                release_fractional[pid] = 0.0
        result["completed"] = true
    return result

# --- СБРОС КОНТЕЙНЕРА ---
# Вызывается после успешного крафта или при смене рецепта в слоте.
func reset():
    elapsed = 0.0
    for slot in ingredient_slots:
        slot["filled"] = 0
        slot["fractional"] = 0.0
        slot["consumed"] = []
    for pid in release_fractional:
        release_fractional[pid] = 0.0

# Внутренний хелпер: качество результата = взвешенное среднее по всем
# «входам» контейнера (на момент вызова). Используется для определения
# качества каждой «порции» выпуска.
func _compute_quality_from_consumed() -> String:
    var breakdown := {}
    for slot in ingredient_slots:
        for entry in slot.get("consumed", []):
            var qty: int = int(entry.get("qty", 0))
            var qid: String = str(entry.get("quality", "common"))
            if qty <= 0:
                continue
            breakdown[qid] = int(breakdown.get(qid, 0)) + qty
    if breakdown.is_empty():
        return "common"
    return _quality_from_breakdown(breakdown)

# Локальная копия CityData.quality_from_breakdown — без обращения к autoload
# на каждом тике. Семантика 1-в-1: взвешенное среднее качеств с округлением
# до ближайшего уровня.
func _quality_from_breakdown(consumed: Dictionary) -> String:
    var levels: Array = []
    if is_instance_valid(GameData):
        levels = GameData.get_quality_levels()
    if levels.is_empty():
        return "common"
    var total: int = 0
    var weighted: float = 0.0
    for qid in consumed:
        var count: int = int(consumed[qid])
        if count <= 0:
            continue
        total += count
        weighted += float(count) * float(GameData.get_quality_value(qid))
    if total <= 0:
        return "common"
    var avg: float = weighted / float(total)
    var best_qid: String = str(levels[0])
    var best_diff: float = 1e9
    for qid in levels:
        var diff: float = abs(float(GameData.get_quality_value(qid)) - avg)
        if diff < best_diff:
            best_diff = diff
            best_qid = str(qid)
    return best_qid

# --- ПРОГРЕСС ДЛЯ UI (0..1) ---
# Степень готовности = min(заполненность_ингредиентов, время/craft_time).
# При дефиците сырья прогресс всё равно растёт, пока копится хотя бы
# время, — но не превышает 1.0.
func completion_ratio() -> float:
    if ingredient_slots.is_empty():
        return 0.0
    var min_fill := 1.0
    for slot in ingredient_slots:
        var req = float(slot.get("required", 1))
        if req <= 0.0:
            continue
        var fill: float = float(int(slot.get("filled", 0))) / req
        if fill < min_fill:
            min_fill = fill
    var time_ratio := 0.0
    if craft_time > 0.0:
        time_ratio = clampf(elapsed / craft_time, 0.0, 1.0)
    return clampf(minf(min_fill, time_ratio), 0.0, 1.0)

# Текстовое состояние контейнера для UI панели здания:
#   "8/20 (3.4 сек)"  — заполненность + сколько времени прошло.
func status_text() -> String:
    if ingredient_slots.is_empty():
        return ""
    var slot0: Dictionary = ingredient_slots[0]
    var filled = int(slot0.get("filled", 0))
    var required = int(slot0.get("required", 0))
    return "%d/%d (%.1f сек)" % [filled, required, elapsed]

# --- СЕРИАЛИЗАЦИЯ ---
# Формат:
#   {
#     "recipe_id": "...",
#     "craft_time": float,
#     "elapsed": float,
#     "slots": [ { ... per-slot state ... } ],
#     "release_fractional": { pid: float }
#   }
func serialize() -> Dictionary:
    return {
        "recipe_id": recipe_id,
        "craft_time": craft_time,
        "elapsed": elapsed,
        "slots": ingredient_slots.duplicate(true),
        "release_fractional": release_fractional.duplicate(true)
    }

# Восстановление состояния из ранее сериализованных данных. При несоответствии
# рецепта (например, рецепт изменился в JSON) контейнер пересоздаётся с нуля,
# но с сохранёнными значениями для совместимых ингредиентов.
func _restore_from_slot_data(recipe: Dictionary, slot_data: Dictionary):
    recipe_id = str(recipe.get("id", slot_data.get("recipe_id", "")))
    craft_time = _resolve_craft_time(recipe)
    elapsed = float(slot_data.get("elapsed", 0.0))
    var saved_slots: Array = slot_data.get("slots", [])
    ingredient_slots = _build_slots_from_recipe(recipe)
    # Мердж сохранённых значений по совпадающим ключам ингредиента.
    for i in range(ingredient_slots.size()):
        if i >= saved_slots.size():
            break
        var fresh: Dictionary = ingredient_slots[i]
        var saved: Dictionary = saved_slots[i]
        if str(saved.get("kind", "")) == str(fresh.get("kind", "")) \
                and str(saved.get("pid", "")) == str(fresh.get("pid", "")) \
                and str(saved.get("group_key", "")) == str(fresh.get("group_key", "")) \
                and int(saved.get("required", 0)) == int(fresh.get("required", 0)):
            fresh["filled"] = int(saved.get("filled", 0))
            fresh["fractional"] = float(saved.get("fractional", 0.0))
            fresh["consumed"] = saved.get("consumed", [])
        # Иначе остаётся свежий пустой слот (рецепт изменился).
    # release_fractional восстанавливается, если сохранён в актуальном виде.
    var saved_release = slot_data.get("release_fractional", null)
    if saved_release is Dictionary:
        # Мердж по pid — оставляем только известные result_products.
        for pid in result_products:
            release_fractional[pid] = float(saved_release.get(pid, 0.0))
    else:
        # Старый сейв (без release_fractional) — инициализируем нулями.
        for pid in result_products:
            release_fractional[pid] = 0.0

# --- СБОРКА СЛОТОВ ИЗ РЕЦЕПТА ---
# resources — { "pid_or_@group": amount, ... }. Для @-групп резолвим членов.
func _build_slots_from_recipe(recipe: Dictionary) -> Array:
    var out: Array = []
    var resources: Dictionary = recipe.get("resources", {})
    for res_key in resources.keys():
        var amt = int(resources[res_key])
        if amt <= 0:
            continue
        var slot := {
            "kind": "single",
            "pid": "",
            "group_key": "",
            "members": [],
            "required": amt,
            "filled": 0,
            "fractional": 0.0,
            "consumed": []
        }
        if str(res_key).begins_with("@"):
            var group_key = str(res_key).trim_prefix("@")
            var members = _resolve_group_members(group_key)
            slot["kind"] = "group"
            slot["group_key"] = group_key
            slot["members"] = members
        else:
            slot["pid"] = str(res_key)
        out.append(slot)
    return out

func _resolve_group_members(group_key: String) -> Array:
    # Резолв @-группы по id или по человекочитаемому имени.
    if not is_instance_valid(GameData):
        return []
    var members: Array = GameData.product_groups.get(group_key, [])
    if members.is_empty() and GameData.product_group_names.has(group_key):
        # Обратный путь: ключ — человекочитаемое имя, нужен id группы.
        for gid in GameData.product_group_names:
            if str(GameData.product_group_names[gid]) == group_key:
                members = GameData.product_groups.get(gid, [])
                break
    return members

# Забирает amount единиц со склада для слота. Для одиночного — напрямую;
# для @-группы — жадно по членам с приоритетом "best" внутри тика.
#
# Возвращает:
#   {
#     "taken": int,                       # фактически забранное количество
#     "breakdown": { quality: count },    # разбивка по качествам
#     "pids": { pid: count }              # разбивка по pid (для @-группы — несколько)
#   }
func _take_from_storage(slot: Dictionary, amount: int, priority: String) -> Dictionary:
    var out := {"taken": 0, "breakdown": {}, "pids": {}}
    if amount <= 0:
        return out
    var kind = str(slot.get("kind", "single"))
    if kind == "single":
        var pid = str(slot.get("pid", ""))
        if pid == "":
            return out
        return _take_single(pid, amount, priority)
    # --- @-группа: жадно по членам с приоритетом "best" ---
    var members: Array = slot.get("members", [])
    if members.is_empty():
        return out
    var remaining = amount
    var ordered := _order_group_members_by_priority(members, priority)
    for pid in ordered:
        if remaining <= 0:
            break
        var avail = int(CityData.city_storage.get(pid, 0))
        if avail <= 0:
            continue
        # Списываем жадно у этого pid в пределах remaining.
        var take = mini(avail, remaining)
        var breakdown = CityData.remove_from_storage(pid, take, priority)
        # Объединяем breakdown.
        for qid in breakdown:
            out["breakdown"][qid] = int(out["breakdown"].get(qid, 0)) + int(breakdown[qid])
        out["taken"] = int(out["taken"]) + take
        out["pids"][pid] = int(out["pids"].get(pid, 0)) + take
        remaining -= take
    return out

# Списание одного продукта с учётом приоритета качества. Делегирует в
# CityData.remove_from_storage() — он сам корректно обновит city_storage
# и city_quality_detail и вернёт разбивку по качествам.
func _take_single(pid: String, amount: int, priority: String) -> Dictionary:
    var avail = int(CityData.city_storage.get(pid, 0))
    if avail <= 0:
        return {"taken": 0, "breakdown": {}, "pids": {}}
    var take = mini(avail, amount)
    var breakdown = CityData.remove_from_storage(pid, take, priority)
    return {
        "taken": take,
        "breakdown": breakdown,
        "pids": {pid: take}
    }

# Упорядочивает членов @-группы по приоритету качества.
# - "best"  — сначала члены с БОЛЬШИМ количеством ЛУЧШЕГО качества на складе;
#             при равенстве — член с большим общим запасом.
# - "worst" — наоборот.
# - прочее   — порядок как в массиве (без перестановок).
# Это соглашение с пользователем: «жадно из лучшего качества» при групповом
# потреблении. Если лучших запасов нет — член всё равно участвует (ниже в
# порядке), чтобы цикл не зависал в ожидании идеального источника.
func _order_group_members_by_priority(members: Array, priority: String) -> Array:
    var out: Array = []
    out.append_array(members)
    if priority != "best" and priority != "worst":
        return out
    if not is_instance_valid(GameData):
        return out
    var quality_levels: Array = GameData.get_quality_levels()
    if quality_levels.is_empty():
        return out
    # Лучшее качество — последнее в порядке levels (GameData отдаёт от худшего
    # к лучшему, см. комментарий в _consume_quality_detail в CityData).
    var best_qid: String = str(quality_levels[quality_levels.size() - 1])
    var sign: int = -1 if priority == "best" else 1
    out.sort_custom(func(a, b):
        var a_best: int = int(CityData.city_quality_detail.get(a, {}).get(best_qid, 0))
        var b_best: int = int(CityData.city_quality_detail.get(b, {}).get(best_qid, 0))
        if a_best != b_best:
            return sign * a_best < sign * b_best
        # При равенстве «лучших» запасов — сортируем по общему количеству.
        var a_total: int = int(CityData.city_storage.get(a, 0))
        var b_total: int = int(CityData.city_storage.get(b, 0))
        return sign * a_total < sign * b_total)
    return out

# --- ВНУТРЕННЕЕ ---
func _resolve_craft_time(recipe: Dictionary) -> float:
    var t := float(recipe.get("time", 0.0))
    if t <= 0.0:
        # Историческое поведение: time=0 → крафт каждый тик (1 сек).
        return 1.0
    return t

func _slot_display_key(slot: Dictionary) -> String:
    if str(slot.get("kind", "")) == "group":
        return "@" + str(slot.get("group_key", ""))
    return str(slot.get("pid", ""))
