# The City — glossary for translators

## What this is

The project is written in **English as its source language**: the English text
lives directly in the code, in the scenes and in `data/*.json`, and is what the
`msgid` of every catalog entry is built from.

The game was originally authored in Russian, and the original wording is kept in
the table below as a **reference column**. It explains what a term was before
the English pass, and it is *not* a target language. Translators of any language
work from the English column; the reference column only helps when the intended
meaning of a term is unclear.

Each target language gets its own catalog in `locale/`:

```
locale/messages.pot   # template: every source message, empty msgstr
locale/<код>.po       # one file per target language
```

When a new language is added, drop in `locale/<код>.po` next to the others and
register it in `project.godot` under
`internationalization/locale/translations`. No code changes are needed.

## Rules for translating

1. **Placeholders are untouchable.** `%s`, `%d`, `%.0f`, `%05.2f`, `%%`, `%.2f`
   carry over verbatim, in the same number and the same order. Do not swap `%s`
   for `%v`, do not add placeholders, do not remove any.
2. **Keep every `\n`** exactly as it is, including leading and trailing
   newlines — they control line breaks and indentation inside tooltips.
3. No curly braces in the translated text.
4. Address the player in the second person, present tense: "Select a tile",
   "Not enough resources".
5. Short labels (buttons, tabs, headings) take no trailing period. Full
   sentences and hints take a period.
6. Capitalisation: ordinary labels in sentence case — `Resources`,
   `Built buildings`, `Cancel construction`. Imperative button commands are
   capitalised — `Build`, `Back`, `Trade`.
7. Do not invent UI that does not exist. If a string is a hint for an action,
   translate it as an instruction to the player.
8. Numbers and units: keep the original (`%d сек.` → `%d sec.`), but a decimal
   separator written with a comma in the original becomes a period in the
   translated text when it is part of the text rather than a value.
9. Units: `км` → `km`, `м` → `m`, `кг` → `kg`.
10. Quotes «…» become plain quotes, or no quotes if the meaning survives.

## Terminology

| Reference wording (original authoring) | English (source) |
|---|---|
| гекс, клетка | hex, tile |
| город | city |
| городок, поселение | town, settlement |
| житель, граждане, население | citizen, citizens, population |
| рабочий | worker |
| специалист | specialist |
| профессия | profession |
| здание | building |
| постройка, строительство | construction |
| слоты для производства | production slots |
| склад, запасы | storage, supplies |
| казна | treasury |
| доход | income |
| расход | expenses |
| баланс | balance |
| налог, налоги | tax, taxes |
| подушный налог | poll tax |
| торговля, торговец | trade, merchant |
| тариф | tariff |
| рынок, внутренний рынок | market, domestic market |
| цена | price |
| стоимость | cost |
| скидка, наценка | discount, markup |
| качество | quality |
| ресурс | resource |
| сырьё | raw resource |
| продукт, товар | goods |
| группа продуктов | goods group |
| рецепт | recipe |
| производство | production |
| потребление | consumption |
| запас | supply |
| технология | technology |
| исследование | research |
| наука | science |
| улучшение | improvement |
| территория | territory |
| границы, влияние города | borders, city influence |
| владение | control |
| разведка | scouting |
| разведчик, разведчики | scout, scouts |
| обследование | surveying |
| освоение территории | claiming land |
| освоить | claim |
| отменить | cancel |
| подтвердить | confirm |
| назад | back |
| закрыть | close |
| продолжить | continue |
| эпоха | era |
| переход в эпоху | advance to the next era |
| карта | map |
| река | river |
| дорога | road |
| мост | bridge |
| лес | forest |
| вырубка леса | clear forest |
| болото | marsh |
| осушение | drainage |
| горы | mountains |
| глина | clay |
| камень | stone |
| песок | sand |
| руда | ore |
| слиток | ingot |
| зерно | grain |
| мука | flour |
| ткань | cloth |
| пряжа | yarn |
| краситель | dye |
| кожа | leather |
| мёд | honey |
| вино | wine |
| пиво | beer |
| монета | coin |
| пастбище | pasture |
| ферма | farm |
| плантация | plantation |
| сад | orchard |
| мельница | mill |
| кузница | forge |
| пекарня | bakery |
| шахта | mine |
| лесопилка | sawmill |
| каменоломня | quarry |
| верфь | shipyard |
| амбар | granary |
| склад | warehouse |
| рынок | market |
| пристань | harbor |
| маяк | lighthouse |
| обсерватория | observatory |
| библиотека | library |
| школа | school |
| мастерская | workshop |

## Where the text comes from

* `scripts/*.gd` — user-visible strings are wrapped in `tr(...)`. Inside
  `static func` use `TranslationServer.translate(...)` instead: GDScript does
  not allow `tr()` in a static context, and it does exactly the same thing.
* `scenes/*.tscn` — the `text` / `tooltip_text` properties are translated by
  Godot itself, so the property value is the `msgid`. No `tr()` needed.
* `data/*.json` — the `name`, `description` and `flavor` fields are
  player-visible; the translation is applied when the files are read
  (`scripts/data_loader.gd`). The English text stays in the JSON.
* Invented proper nouns (the city names in `data/city_names.json`) are **not**
  translated — they are treated as names, not as text.
