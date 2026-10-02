# project_manager.gd
# Универсальная система ПОЭТАПНОГО строительства.
#
# Проект — это упорядоченная очередь ШАГОВ, и они строятся по одному: пока
# текущий шаг не достроен, следующий не начинается. Менеджер ничего не знает
# ни про дороги, ни про акведуки: он умеет только крутить очередь, капать в
# текущий шаг труд и сообщать о событиях. Что означает шаг и что происходит
# при его завершении — решает владелец проекта (main_map) по сигналу
# step_completed. Поэтому новый вид проекта (например, акведук от горы к
# городу) — это новый обработчик шагов, а не правка этого файла.
#
# Труд сюда НЕ придумается: ставку раздаёт build_manager (см.
# receive_labor), потому что она одна на все стройки города — инвариант
# «суммарный объём работы в единицу времени равен размеру города» живёт
# ровно в одном месте.
#
# Менеджер намеренно НЕ ссылается на автозагрузки (CityData): флаг дебага
# «Игнорировать требования строительства» приходит аргументом. Благодаря
# этому файл можно грузить в headless-тесте через load() — такой обход
# описан в шапке tests/test_road_building.gd.
extends Node

## Проект начат: первый шаг поставлен в работу.
signal project_started(project_id: String, kind: String, title: String)
## Шаг достроен. Владелец применяет его эффект к миру (например, прокладывает
## участок дороги). Сигнал летит ДО начала следующего шага — так порядок
## «построили участок → показали его на карте → начали следующий» гарантирован.
signal step_completed(project_id: String, kind: String, step: Dictionary)
## Начался следующий шаг. На его гексе показывается новый прогресс-бар.
signal step_started(project_id: String, kind: String, step: Dictionary)
## Очередь проекта пуста — всё построено.
signal project_completed(project_id: String, kind: String, meta: Dictionary)
## Проект отменён игроком: уже построенное остаётся, недостроенное — нет.
signal project_cancelled(project_id: String, kind: String, meta: Dictionary)
## Сообщение для HUD. Отдельный сигнал (а не общий с build_manager), чтобы
## менеджер не тянул за собой интерфейс.

# Активные проекты: project_id -> запись проекта.
var projects: Dictionary = {}

# Счётчик для ключей. Ключ строковый — он попадает в сейв как ключ словаря,
# а не как индекс, поэтому переживает перестановку проектов при загрузке.
var _next_id: int = 0

## Ставит проект в очередь. Возвращает project_id, либо "" — если очередь
## пуста (строить нечего).
##
## steps — массив шагов, каждый:
##   {
##     "label": String,                 # подпись шага (HUD, отмена)
##     "work_cost": float,              # сколько труда нужно на шаг
##     "progress": float,               # накопленный труд (заполняется здесь)
##     "status": "active",
##     "allocated_labor": float,
##     "hex": {"row": int, "col": int}, # гекс, НАД которым рисуется прогресс-бар
##     "ghost": Dictionary,             # сегменты-призраки этого шага
##     "data": Dictionary,              # полезная нагрузка для обработчика
##   }
## meta — данные проекта, нужные владельцу при завершении (например, является
## ли цель городком). Шаги обязаны быть непустым массивом словарей.
func start_project(
        kind: String,
        title: String,
        target_row: int,
        target_col: int,
        steps: Array,
        meta: Dictionary = {}) -> String:
    if steps.is_empty():
        return ""
    _next_id += 1
    var project_id := "%s_%d" % [kind, _next_id]
    for step in steps:
        step["progress"] = 0.0
        step["status"] = "active"
        step["allocated_labor"] = 0.0
    projects[project_id] = {
        "id": project_id,
        "kind": kind,
        "title": title,
        "target_row": target_row,
        "target_col": target_col,
        "steps": steps,
        "step_index": 0,
        "status": "active",
        "meta": meta
    }
    project_started.emit(project_id, kind, title)
    step_started.emit(project_id, kind, steps[0])
    return project_id

## Отменяет проект. Уже построенные шаги никуда не деваются — отмена дороги
## не откатывает проложенную часть, как и отмена стройки улучшения.
func cancel_project(project_id: String) -> bool:
    if not projects.has(project_id):
        return false
    var project: Dictionary = projects[project_id]
    projects.erase(project_id)
    project_cancelled.emit(project_id, str(project.get("kind", "")),
            project.get("meta", {}))
    return true

## Отменяет проект, цель которого — гекс (row, col).
func cancel_project_at(row: int, col: int) -> bool:
    var project := get_project_at(row, col)
    if project.is_empty():
        return false
    return cancel_project(str(project.get("id", "")))

## Отменяет проект, ЗАНИМАЮЩИЙ гекс (row, col) — любой его гекс, не только
## цель. Парный к get_project_at_hex: прервать можно с гекса, который видит
## игрок, а не только с того, который был нажат при запуске.
func cancel_project_at_hex(row: int, col: int) -> bool:
    var project := get_project_at_hex(row, col)
    if project.is_empty():
        return false
    return cancel_project(str(project.get("id", "")))

func get_project(project_id: String) -> Dictionary:
    return projects.get(project_id, {})

## Идёт ли сейчас проект к этому гексу (по гексу ЦЕЛИ). Панель управления
## спрашивает это, чтобы не показать «Построить дорогу» повторно на гексе,
## к которому дорога уже строится.
func has_project_at(row: int, col: int) -> bool:
    return not get_project_at(row, col).is_empty()

func get_project_at(row: int, col: int) -> Dictionary:
    for project_id in projects.keys():
        var project: Dictionary = projects[project_id]
        if int(project.get("target_row", -1)) == row \
                and int(project.get("target_col", -1)) == col:
            return project
    return {}

## Проект, ЗАНИМАЮЩИЙ этот гекс — любой его шаг, а не только цель.
##
## Зачем два разных вопроса. has_project_at() (по цели) нужен, чтобы прятать
## кнопку «Построить дорогу» на гексе, к которому дорога УЖЕ идёт. А вот кнопка
## отмены должна появляться на ЛЮБОМ гексе проекта: игрок видит дорогу как
## призрак на десятке гексов и прогресс-бар на текущем участке, и жмёт туда,
## где видит стройку. Кнопка, спрятанная на дальнем конце маршрута (возможно,
## за пределами экрана), не находится — это и был исходный баг.
##
## Гекс шага известен из двух мест, и оба нужны:
##   · "hex" — гекс, на котором рисуется прогресс-бар (участок, который
##     присоединяется к сети);
##   · "data".from / "data".to — оба конца участка. Гекс from уже присоединён
##     предыдущим шагом, но игрок видит на нём дорогу, и кликать он будет
##     именно по нему.
func get_project_at_hex(row: int, col: int) -> Dictionary:
    for project_id in projects.keys():
        var project: Dictionary = projects[project_id]
        if _project_touches_hex(project, row, col):
            return project
    return {}

func has_project_at_hex(row: int, col: int) -> bool:
    return not get_project_at_hex(row, col).is_empty()

## Принадлежит ли гекс проекту. Цель проверяется отдельно от шагов: у
## уже начатого проекта target равен гексу последнего шага, но полагаться на
## это равенство нельзя — порядок шагов меняли и ещё поменяем.
func _project_touches_hex(project: Dictionary, row: int, col: int) -> bool:
    if int(project.get("target_row", -1)) == row \
            and int(project.get("target_col", -1)) == col:
        return true
    var steps: Array = project.get("steps", [])
    # Уже построенные шаги тоже учитываем намеренно: они стали настоящей
    # дорогой на карте, и игрок кликает по ней — отмена должна работать.
    for step in steps:
        var bar_hex: Dictionary = step.get("hex", {})
        if int(bar_hex.get("row", -1)) == row and int(bar_hex.get("col", -1)) == col:
            return true
        var data: Dictionary = step.get("data", {})
        for key in ["from", "to"]:
            var h: Dictionary = data.get(key, {})
            if int(h.get("row", -1)) == row and int(h.get("col", -1)) == col:
                return true
    return false

func has_active_projects() -> bool:
    return not projects.is_empty()

## Сколько «строек» сейчас идёт. Каждый активный проект занимает ровно ОДИН
## слот в пуле труда: одновременно строится только текущий шаг. Это значение
## build_manager складывает со своими стройками, чтобы ставка труда досталась
## проектам по тому же правилу, что и улучшениям, зданиям и освоению.
func get_active_step_count() -> int:
    return projects.size()



## Капает труд в текущий шаг каждого активного проекта. Вызывает
## build_manager — ставка labor_per_step одна на всех и уже поделена.
##
## instant — дебаг «Игнорировать требования строительства»: очередь
## разбирается целиком за один кадр, ровно как обычные стройки. Флаг передаётся
## аргументом, а не читается из CityData, чтобы файл оставался свободным от
## автозагрузок (см. шапку).
func receive_labor(labor_per_step: float, delta: float, instant: bool = false) -> void:
    if projects.is_empty():
        return
    # Ключи копируем: эмиты сигналов могут изменить projects (отмена проекта
    # из обработчика шага), и итерация по словарю тогда ведёт себя непредсказуемо.
    for project_id in projects.keys():
        if not projects.has(project_id):
            continue
        var project: Dictionary = projects[project_id]
        if str(project.get("status", "active")) != "active":
            continue
        _advance(project, labor_per_step, delta, instant)

## Прогресс текущего шага на гексе (row, col) — для отрисовки прогресс-бара.
## Пустой словарь, если на гексе сейчас ничего не строится.
func get_step_progress_at(row: int, col: int) -> Dictionary:
    for project_id in projects.keys():
        var project: Dictionary = projects[project_id]
        var step := _current_step(project)
        if step.is_empty():
            continue
        var hex: Dictionary = step.get("hex", {})
        if int(hex.get("row", -1)) == row and int(hex.get("col", -1)) == col:
            return {
                "project_id": project_id,
                "kind": str(project.get("kind", "")),
                # Тип ШАГА, а не проекта: в цепочке «дорога → улучшение» шаги
                # разные, и слой прогресс-баров красит шаг улучшения в жёлтый
                # (цвет стройки улучшения), а участок дороги — в синий.
                "step_type": str(step.get("data", {}).get("step_type", "")),
                "title": str(project.get("title", "")),
                "label": str(step.get("label", "")),
                "progress": float(step.get("progress", 0.0)),
                "work_cost": float(step.get("work_cost", 0.0)),
                "step_index": int(project.get("step_index", 0)),
                "steps_left": _steps_left(project),
            }
    return {}

## Призрак проекта: объединение сегментов ВСЕХ ещё не построенных шагов всех
## активных проектов. Именно этим набором рисуется маршрут на карте, пока
## стройка идёт: построенный участок из призрака исчезает сам, потому что его
## шаг ушёл из очереди.
func get_pending_ghost_segments() -> Dictionary:
    var ghost: Dictionary = {}
    for project_id in projects.keys():
        var project: Dictionary = projects[project_id]
        var steps: Array = project.get("steps", [])
        for i in range(int(project.get("step_index", 0)), steps.size()):
            for key in steps[i].get("ghost", {}).keys():
                ghost[key] = true
    return ghost

## Данные проектов для сейва. Сегменты дорог, как и всегда, не пишутся:
## сохраняется очередь шагов, а сеть пересчитывается по флагам гексов.
func serialize_projects() -> Dictionary:
    var out: Dictionary = {}
    for project_id in projects.keys():
        out[project_id] = (projects[project_id] as Dictionary).duplicate(true)
    return out

## Восстанавливает проекты из сейва. Пустой словарь — обычная новая партия.
func restore_projects(data: Dictionary) -> void:
    projects.clear()
    if data.is_empty():
        return
    for project_id in data.keys():
        var project = data[project_id]
        if not (project is Dictionary):
            continue
        var steps: Array = project.get("steps", [])
        # Без шагов проект незачем восстанавливать, а без kind нечем
        # определить, кто будет обрабатывать его шаги.
        if steps.is_empty() or str(project.get("kind", "")) == "":
            continue
        projects[String(project_id)] = project.duplicate(true)
        # Счётчик продолжается с максимального уже занятого номера, чтобы
        # новый проект не получил ключ, совпадающий с восстановленным.
        var suffix := String(project_id).rfind("_")
        if suffix >= 0:
            _next_id = maxi(_next_id, int(String(project_id).substr(suffix + 1)))
    # Сигналы при восстановлении НЕ эмитим: мир уже восстановлен целиком, и
    # владелец дорисует призраки сам по итоговому состоянию очереди.

# -------------------------------------------------------
# Внутреннее
# -------------------------------------------------------

func _current_step(project: Dictionary) -> Dictionary:
    var steps: Array = project.get("steps", [])
    var index := int(project.get("step_index", 0))
    if index < 0 or index >= steps.size():
        return {}
    return steps[index]

func _steps_left(project: Dictionary) -> int:
    var steps: Array = project.get("steps", [])
    return maxi(0, steps.size() - int(project.get("step_index", 0)))

# Капает труд в текущий шаг и, если он наполнился, достраивает его.
func _advance(project: Dictionary, labor_per_step: float, delta: float,
        instant: bool) -> void:
    var step := _current_step(project)
    if step.is_empty():
        return
    if instant:
        step["progress"] = float(step.get("work_cost", 0.0))
    else:
        step["progress"] = float(step.get("progress", 0.0)) + labor_per_step * delta
    step["allocated_labor"] = labor_per_step
    if float(step["progress"]) < float(step.get("work_cost", 0.0)):
        return
    # Шагов в очереди может быть много, а кадр один. Без дебаг-флага за кадр
    # достраивается ровно один шаг — иначе поэтапности не было бы видно.
    while true:
        _complete_current_step(project)
        if not instant or not projects.has(str(project.get("id", ""))):
            return
        var next_step := _current_step(project)
        if next_step.is_empty():
            return
        next_step["progress"] = float(next_step.get("work_cost", 0.0))

# Достраивает текущий шаг и сдвигает очередь. При завершении последнего шага
# проект выбрасывается из projects и эмитится project_completed.
func _complete_current_step(project: Dictionary) -> void:
    var project_id := str(project.get("id", ""))
    var kind := str(project.get("kind", ""))
    var steps: Array = project.get("steps", [])
    var index := int(project.get("step_index", 0))
    if index < 0 or index >= steps.size():
        return
    var step: Dictionary = steps[index]
    project["step_index"] = index + 1
    # Порядок эмитов значим: сначала владелец применяет эффект шага (участок
    # дороги появляется на карте), и только потом стартует следующий шаг с его
    # новым прогресс-баром.
    step_completed.emit(project_id, kind, step)
    if project_id in projects and int(project["step_index"]) < steps.size():
        step_started.emit(project_id, kind, steps[int(project["step_index"])])
        return
    if project_id in projects:
        var meta: Dictionary = project.get("meta", {})
        projects.erase(project_id)
        project_completed.emit(project_id, kind, meta)
