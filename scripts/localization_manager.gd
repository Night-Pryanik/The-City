# localization_manager.gd (автозагрузка LocalizationManager)
#
# Держит выбранный язык игры и переключает его в TranslationServer.
#
# Порядок автозагрузок в project.godot важен: LocalizationManager идёт
# ПЕРВЫМ, чтобы язык был выбран до того, как GameData прочитает data/*.json
# и наложит на них перевод. Иначе первый кадр после старта рисует текст
# предыдущего (или исходного) языка, а нужный появляется только после
# первой перезагрузки данных.
#
# Язык исходников — английский: в коде, в сценах и в data/*.json лежит
# английский текст, и он служит ключом перевода. У каждого целевого языка
# свой каталог в locale/ (locale/<код>.po); ни один из них не особенный —
# исходный каталог messages.pot устроен точно так же.
extends Node

# Сигнал «язык сменился». Подписчики перерисовывают то, что строят в коде:
# текст, заданный прямо в сцене, Godot переводит сам (см. примечание выше
# про авто-перевод Control), а вот строки, собранные в GDScript, нужно
# пересобрать вручную.
signal locale_changed(locale: String)

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "interface"
const SETTINGS_KEY := "locale"

# Английский — язык по умолчанию (язык исходников).
const DEFAULT_LOCALE := "en"

# Псевдозначение настройки: брать язык из настроек операционной системы.
# Именно оно выбирается при самом первом запуске игры.
const SYSTEM_LOCALE := "system"

# Языки, доступные в игре. code — ISO 639-1, как его ждёт TranslationServer.
# Список расширяют здесь: чтобы добавить язык, достаточно дописать строку
# и положить рядом файл locale/<code>.po, зарегистрированный в project.godot.
const LANGUAGES := [
    {"code": "en", "name": "English"},
    {"code": "ru", "name": "Русский"},
]

# Текущий язык игры (код из LANGUAGES, всегда реальный, не SYSTEM_LOCALE).
var current_locale: String = DEFAULT_LOCALE

# Выбран ли в настройках пункт «язык системы» вместо конкретного языка.
var follow_system_locale: bool = false

# Последний применённый код — чтобы повторный выбор того же языка не
# запускал перезагрузку данных и перерисовку интерфейса зря.
var _applied_locale: String = ""


func _ready() -> void:
    _init_locale()


# Выбор языка при запуске игры: сохранённая настройка, а при её отсутствии
# (то есть при самом первом запуске) — язык операционной системы, а если он
# не поддерживается — английский по умолчанию. Выбранное значение сразу
# записывается в настройки, чтобы следующий запуск был предсказуемым.
func _init_locale() -> void:
    var config := ConfigFile.new()
    var stored: Variant = null
    if config.load(SETTINGS_PATH) == OK:
        stored = config.get_value(SETTINGS_SECTION, SETTINGS_KEY, null)

    var requested := str(stored) if stored != null else SYSTEM_LOCALE

    if requested == SYSTEM_LOCALE:
        follow_system_locale = true
        current_locale = resolve_system_locale()
    elif is_supported(requested):
        follow_system_locale = false
        current_locale = requested
    else:
        # Неизвестный или удалённый из игры код языка: не падаем, а берём
        # язык системы и переписываем настройку на следующем запуске.
        push_warning("Неизвестный язык в настройках: «%s» — берём язык системы." % requested)
        follow_system_locale = true
        current_locale = resolve_system_locale()

    _apply_locale(current_locale)
    _save_locale_setting(SYSTEM_LOCALE if follow_system_locale else current_locale)


# Переводит код языка операционной системы в код языма игры.
# ru_RU → ru. Если такого языка в игре нет — английский по умолчанию.
func resolve_system_locale() -> String:
    var short_code := short_language_code(OS.get_locale_language())
    if is_supported(short_code):
        return short_code
    return DEFAULT_LOCALE


# Отрезает страну от кода языка системы: "pt_BR" → "pt", "ru" → "ru".
# Вынесено отдельной функцией, чтобы правило можно было проверить в тестах
# без подмены локали операционной системы.
static func short_language_code(system_code: String) -> String:
    return system_code.to_lower().split("_")[0]


# Есть ли такой язык в игре. Пустое и неизвестное — false.
func is_supported(code: String) -> bool:
    if code.is_empty():
        return false
    for lang in LANGUAGES:
        if lang["code"] == code:
            return true
    return false


# Язык доступен для выбора, если он есть в LANGUAGES И его перевод реально
# загружен (иначе игрок выбрал бы язык, который игра всё равно не покажет).
func is_translation_loaded(code: String) -> bool:
    return TranslationServer.get_loaded_locales().has(code)


# Список для выпадающего списка настроек: первым «язык системы», дальше
# языки, чей перевод загружен. Если системный язык поддерживается, его
# подставляем и внизу списка — чтобы выбор был виден в обоих режимах.
func available_languages() -> Array:
    var result: Array = [{"code": SYSTEM_LOCALE, "name": tr("Language of the system")}]
    for lang in LANGUAGES:
        if lang["code"] == DEFAULT_LOCALE or is_translation_loaded(lang["code"]):
            result.append(lang.duplicate())
    return result


func get_locale() -> String:
    return current_locale


# Подпись языка для выпадающего списка: для «языка системы» показываем, что
# именно выбрала система, — иначе пункт выглядит неопределённым.
func get_language_label(code: String) -> String:
    if code == SYSTEM_LOCALE:
        return tr("Language of the system") + " (%s)" % language_display_name(resolve_system_locale())
    for lang in LANGUAGES:
        if lang["code"] == code:
            return str(lang["name"])
    return code


# Имя языка на его собственном языке ("English", "Русский") — так список
# читается одинаково, что бы игрок ни выбрал раньше.
func language_display_name(code: String) -> String:
    match code:
        "en":
            return "English"
        "ru":
            return "Русский"
        _:
            return code


# Точка входа из настроек. code — либо код языка, либо SYSTEM_LOCALE.
# Возвращает false, если такой язык выбрать нельзя.
func set_locale(code: String) -> bool:
    var resolved: String
    if code == SYSTEM_LOCALE:
        resolved = resolve_system_locale()
    else:
        if not is_supported(code):
            return false
        resolved = code

    follow_system_locale = (code == SYSTEM_LOCALE)
    current_locale = resolved

    if resolved == _applied_locale:
        # Язык не изменился: настройку всё равно пишем (игрок мог вернуться
        # на «язык системы»), но данные и интерфейс не трогаем.
        _save_locale_setting(code)
        return true

    _apply_locale(resolved)
    _save_locale_setting(code)
    return true


func _apply_locale(code: String) -> void:
    _applied_locale = code
    TranslationServer.set_locale(code)
    # Данные игры хранят английский исходный текст и накладывают перевод при
    # загрузке, поэтому после смены языка их нужно перечитать заново.
    # Данные уже загружены на момент смены языка из главного меню; при смене
    # из партии — тоже (CityData.setup вызывает GameData.load_all_data).
    if GameData.data_loaded:
        GameData.load_all_data()
    locale_changed.emit(code)


func _save_locale_setting(code: String) -> void:
    var config := ConfigFile.new()
    # Перечитываем файл: настройки пишут ещё и settings_menu.gd, и его
    # копия в памяти может не знать про только что записанный ключ.
    config.load(SETTINGS_PATH)
    config.set_value(SETTINGS_SECTION, SETTINGS_KEY, code)
    config.save(SETTINGS_PATH)


# Читает сохранённый выбор языка, не применяя его. Нужно настройкам, чтобы
# показать текущее значение пункта списка при открытии окна.
func get_stored_locale() -> String:
    var config := ConfigFile.new()
    if config.load(SETTINGS_PATH) != OK:
        return SYSTEM_LOCALE
    var stored: Variant = config.get_value(SETTINGS_SECTION, SETTINGS_KEY, null)
    if stored == null:
        return SYSTEM_LOCALE
    var code := str(stored)
    if code == SYSTEM_LOCALE or is_supported(code):
        return code
    return SYSTEM_LOCALE
