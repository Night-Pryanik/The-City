# The City

> An economic simulator of a single city's development through historical eras.

**The City** is a game about how a small settlement gradually turns into a complex city, developing production, technology and infrastructure on a procedurally generated hexagonal map.

There is no army of thousands of units, no manual control over every citizen, and no need to build every house tile by tile.

The main character is the **city**.

---

## 🎮 About the project

The City combines elements of:

- an economic simulator;
- resource management;
- a soft 4X;
- a historical city-builder;
- procedural world generation.

The player explores the surrounding territory, gains access to new resources, builds production buildings, develops technologies and gradually expands the city's area of influence.

At the same time, most of the economy runs automatically. The player mostly makes decisions about **what to develop**, rather than doing constant micromanagement.

---

## 🌍 The world

Every new game starts with a procedurally created map.

The map consists of hexagons and contains:

- various terrain types;
- forests and other types of vegetation cover;
- rivers, lakes, marshes and seas;
- common and rare resources;
- one-time natural finds;
- territories of the city and towns;
- fog of war.

Resources may be visible before they can be used. Some of them require the corresponding technology to extract or process.

Other resources, such as underground metal deposits, may remain hidden until the corresponding technology is developed.

---

## 🏙️ The city

The city is the central element of the game.

Inside the city there are production buildings that form resource processing chains:

~~~text
natural resource
       ↓
   improvement
       ↓
     raw resource
       ↓
production building
       ↓
processed resource
       ↓
next production
~~~

Buildings have production slots and recipes.

As the city develops, buildings can be upgraded, yielding more advanced versions with additional capabilities.

For example:

~~~text
Hand mill
      ↓
Animal-driven mill
      ↓
...
~~~

Upgrading a building is an ordinary construction task and uses the same shared labour mechanism as construction.

---

## 👥 Population and labour

The city's residents are not individual characters that have to be controlled manually.

They represent the available workforce.

Every active production or construction action requires work time.

The number of simultaneous actions is limited by the city's population:

> one resident can take part in at most one action at a time.

If there are fewer active tasks than residents, the remaining residents are free.

If there are more tasks than available workforce, they are completed more slowly.

Labour is not a resource that can be stored in a warehouse.

---

## 🔬 Technologies

Technologies unlock new opportunities for the city:

- buildings;
- terrain improvements;
- resources;
- production methods;
- new game mechanics;
- production bonuses;
- new stages of development.

The technology tree consists of eras and dependency chains.

Some technologies have several mandatory predecessors.

For example, the development of writing materials gradually leads from early information carriers to more advanced ones:

~~~text
Clay tablets
       ↓
    Papyrus
       ↓
Wax tablets
       ↓
   Parchment
       ↓
     Silk
       ↓
     Paper
~~~

This is not necessarily a linear chain: different technologies and resources can exist in parallel.

---

## ⛏️ Resources

The City's economy is built around interconnected resource chains.

A single raw material can have several uses.

For example, malachite can be used in several directions at once:

~~~text
                    ┌→ pigment
Malachite ──────────┼→ jewellery
                    └→ copper
~~~

This approach creates real economic decisions:

> use a rare resource now, or save it for more valuable production?

The game also has one-time natural resources — an analogue of the foraging mechanic.

For example:

- wild plants;
- native copper;
- native gold;
- native silver;
- meteoritic iron.

After being gathered, such finds disappear.

---

## ⚒️ Metallurgy

Metals form a separate production branch.

Early technologies allow the use of native metals and meteoritic iron.

The next stage is full-fledged metallurgy:

~~~text
Ore deposit
        ↓
   Smelting furnace
        ↓
       metal
        ↓
      forge
        ↓
     product
~~~

This allows two fundamentally different operations to be separated:

**smelting** — obtaining metal from ore;

**forge production** — processing metal and making products.

Subsequently, this system develops into separate branches of iron, bronze, precious metals and other materials.

---

## 🎨 Production and quality

The City uses a data-driven approach.

Resources, buildings, technologies, recipes and terrain types are described by data, rather than by hard-coded logic for individual objects.

This makes it possible to create complex production chains without rewriting code for every new resource.

The game also develops a system of resource and product quality.

---

## ✨ Procedural products

One of the project's planned systems is procedurally generated production results.

Instead of creating a separate recipe for every combination of ingredients, a recipe defines a base product, and additional ingredients modify it.

For example:

~~~text
Woollen clothing
        +
      indigo
        +
   fur trim
        ↓
"Woollen clothing dyed with indigo,
with fur trim"
~~~

Similarly, a piece of jewellery will be able to receive several additional materials:

~~~text
Gold ornament
       +
     onyx
       +
     agate
       ↓
Gold ornament with onyx and agate
~~~

This makes it possible to create a large number of product variants without a combinatorial explosion in the number of recipes and individual items.

---

## 🗺️ Territory expansion

The city starts with a limited area of influence.

As it develops, it gains the ability to expand its influence and explore the surrounding region.

Scouts can be sent to any point on the map that the screen can be scrolled to — including the territory of towns and the unexplored fog of war. But only after researching the **Cartography** technology: before that, scouting is limited to the unexplored part of the Region, and hexes in the fog of war cannot be hovered over or clicked. Claiming (buying) new hexes, however, remains possible only within the Region — the strips around the Ring of Influence.

Both scouting and claiming work **only from the border of the known world**: a chunk must border the Ring of Influence or already explored hexes. Scouts do not jump over unexplored land — the border of the known world expands forward chunk by chunk, and "pockets" in the fog of war cannot be scouted. For a chunk that does not adjoin, the action button is greyed out and explains the reason. A hex in the fog of war reveals no information: neither the tooltip on hover nor the left column of the panel shows terrain and resources until the hex is explored.

Scouting and claiming are paid for with **coins from the city treasury**: the price is calculated per hex of the chunk and grows with distance from the city (base values are in `data/game_balance.json`, see docs.md, "Cost of scouting (coins from the treasury)"). Claiming additionally requires labour: it accumulates over time, as in construction.

Exploring and claiming territory make it possible to discover new resources and opportunities.

When advancing to the next stage of development, the area of influence expands in a jump, opening a new scale of city development.

---

## 🏘️ Towns

Besides the main city, the map may contain small settlements — **towns**.

They have:

- their own names;
- their own area of influence;
- a separate visual border design;
- colour-coded territory.

The names of cities and towns are procedurally chosen from a large set of invented toponyms.

The world is deliberately not tied to a single historical culture.

You can encounter:

- conventionally Northern European names;
- Mesopotamian;
- Egyptian;
- Indian;
- Chinese;
- Japanese;
- African;
- Middle Eastern;
- South American;
- Polynesian;

as well as deliberate cultural hybrids.

This is part of the world's artistic design.

---

## 🧠 Design principles

The City follows several important principles.

### 95/5

About 95% of the economy should run automatically.

The player intervenes where a decision is genuinely required.

### The city is the main character

Residents are first and foremost workforce.

The game does not try to turn every resident into a separately simulated NPC.

### Data-driven

Resources, buildings, recipes, technologies and other game elements should be defined by data wherever possible.

This simplifies the project's development and opens up the possibility of mods.

### Minimum micromanagement

The player should manage the city's economy, not constantly press buttons to keep it running.

### Economy matters more than the amount of content

A new resource or building should create an interesting connection with the existing economy, rather than simply lengthening the list of items.

---

## 🛠️ Technologies

The project is developed in **Godot**.

The main game data is stored in JSON.

Approximate structure:

~~~text
data/
├── buildings.json
├── crafts/
├── products/
├── resources/
├── technologies/
├── terrains/
└── ...

scripts/
├── map_generator.gd
├── CityData.gd
├── BuildManager.gd
└── ...

city_ui/
└── ...
~~~

The exact project structure continues to evolve with development.

---

## 🚧 Project status

The City is in active development.

Already implemented and being tested:

- procedural hexagonal map;
- the city and towns;
- area of influence;
- fog of war;
- resources and deposits;
- terrain improvements;
- production;
- workforce;
- construction;
- building upgrades;
- production slots;
- technologies;
- several historical eras;
- roads with levels and routes from improvements to the city;
- one-time natural resources;
- native metals;
- the metallurgy chain;
- writing materials;
- paper;
- dyes;
- jewellery production;
- names of cities and towns.

Many systems are in the stage of active balancing and polishing.

---

## 🧪 Testing

The project is at the stage of active testing.

Particular attention is paid to:

- economic balance;
- production chains;
- UI clarity;
- technology progression;
- procedural generation;
- how the economy behaves on different maps;
- the absence of dead-end resource chains;
- performance on large maps.

---

## 📌 Development philosophy

The City does not try to be a maximally realistic historical reconstruction.

History is used as a source of:

- technologies;
- materials;
- production processes;
- cultural images;
- ideas for the economy.

But the ultimate goal is to create a self-contained game system.

If a historical detail makes the economy more interesting, it may appear in the game.

If it only adds micromanagement or creates a useless resource, it can be dropped.

---

## 📖 Documentation

The main principles and the current structure of the project are described in:

`design_doc.md`

When key game systems change, the documentation must be updated together with the code.

---

## 📜 License

The project is in development.

License information will be added separately.
