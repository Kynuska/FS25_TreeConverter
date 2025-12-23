# Converting Static Map Trees to Planted Trees

This guide explains how to convert static trees (placed in Giants Editor) to savegame planted tree data, enabling location-based growth and yield.

## Quick Start: Map Maker Workflow

When you're done placing trees in Giants Editor and ready to publish:

```bash
# 1. Preview what will be extracted
python convert_static_trees.py maps/map01/map.i3d --preview

# 2. Extract trees AND remove them from the i3d
python convert_static_trees.py maps/map01/map.i3d \
    --output defaultSavegame/treePlant.xml \
    --remove-from-i3d

# Creates:
#   - defaultSavegame/treePlant.xml (planted tree data)
#   - maps/map01/map.i3d.backup (original backup)
#   - Modified map.i3d (trees removed)
```

Then ship your map with the `defaultSavegame/` folder containing `treePlant.xml`.

## The Problem

Static map trees (placed in the map .i3d file) are:
- **Static rigid bodies** - they don't move or grow
- **Not tracked** by TreePlantManager
- **Cannot use** growth or yield modifiers
- **Just scenery** until cut down

Planted trees (via TreePlantManager) are:
- **Dynamic** - can grow through stages
- **Tracked** per-instance with growth timers
- **Support** location-based modifiers

## Can You Ship a Savegame With a Map?

**Short answer: Yes, but with caveats.**

### How It Works

When a player starts a new game with your map:
1. Game creates a new savegame folder
2. Copies default files from map (if provided)
3. Loads the map .i3d (including static trees)

The savegame `treePlant.xml` stores planted trees. If you provide one, it will be loaded **in addition to** the static map trees.

### The Problem: Duplicate Trees

If you:
1. Keep static trees in the .i3d
2. Ship a treePlant.xml with the same trees converted

You'll get **double trees** - both static and planted versions at the same locations!

### Solutions

**Solution 1: Remove static trees from .i3d, ship treePlant.xml**

1. In Giants Editor, delete all trees from the map
2. Export tree positions to a script
3. Generate treePlant.xml with those positions
4. Ship treePlant.xml with the map

**Pros**: Clean solution, all trees are dynamic
**Cons**: Lot of work, changes original map significantly

**Solution 2: Convert at first load via mod**

1. Keep static trees in .i3d
2. On first map load, scan for static trees
3. Delete them and plant dynamic replacements
4. Save immediately

**Pros**: Works with existing maps
**Cons**: One-time conversion lag, complexity

**Solution 3: Apply modifiers only to new plantings (Recommended)**

1. Keep static trees as-is
2. Location-based system only affects player-planted trees
3. Accept that original map trees are "legacy"

**Pros**: Simple, no conversion needed
**Cons**: Original trees don't benefit from system

## Savegame Tree Format

### File: `[savegame]/treePlant.xml`

```xml
<?xml version="1.0" encoding="utf-8" standalone="no"?>
<treePlant>
    <tree treeType="oak"
          position="123.4567 45.6789 234.5678"
          rotation="0 45 0"
          growthStateI="5"
          variationIndex="1"
          nextGrowthTargetHour="1234.5"
          isGrowing="true"
          splitShapeFileId="-1"/>

    <tree treeType="pine"
          position="200.0 50.0 300.0"
          rotation="0 90 0"
          growthStateI="6"
          variationIndex="2"
          isGrowing="false"
          splitShapeFileId="-1"/>

    <!-- More trees... -->
</treePlant>
```

### Attributes

| Attribute | Type | Description |
|-----------|------|-------------|
| treeType | string | Tree type name (e.g., "oak", "pine", "spruce") |
| position | string | "x y z" world coordinates |
| rotation | string | "rx ry rz" rotation in degrees |
| growthStateI | int | Growth stage index (0 = sapling, max = mature) |
| variationIndex | int | Visual variation (1-based, tree type dependent) |
| nextGrowthTargetHour | float | Game hour when tree grows to next stage |
| isGrowing | bool | Whether tree is still growing |
| splitShapeFileId | int | Internal ID for split shapes (-1 for whole trees) |

### Tree Type Names (Base Game)

From `dataS/maps/mapXX/map_treeTypes.xml`:

- americanElm
- aspen
- beech
- betulaErmanii
- birch
- boxelder
- cherry
- chineseElm
- downyServiceBerry
- goldenRain
- japaneseZelkova
- lodgepolePine
- maple
- northernCatalpa
- oak
- pinusSylvestris
- pinusTabuliformis
- poplar
- shagbarkHickory
- spruce
- tiliaAmurensis
- willow

### Growth Stages

Most trees have 5-7 growth stages:
- Stage 0: Just planted (sapling)
- Stage 1-4: Growing
- Stage 5-6: Mature (no more growth)

## Using convert_static_trees.py

The `convert_static_trees.py` script handles the full workflow:

### Basic Usage

```bash
# List top-level nodes to find where trees are
python convert_static_trees.py map.i3d --list-nodes

# Preview what would be extracted (no changes)
python convert_static_trees.py map.i3d --preview

# Extract only trees under a specific parent node
python convert_static_trees.py map.i3d --tree-parent "trees" --preview

# Generate treePlant.xml
python convert_static_trees.py map.i3d --output treePlant.xml

# Full conversion: extract AND remove from i3d
python convert_static_trees.py map.i3d --output treePlant.xml --remove-from-i3d
```

### What It Does

1. **Parses the .i3d** - Finds all nodes with tree-like names
2. **Calculates world transforms** - Handles nested transforms correctly
3. **Detects tree types** - Maps node names to FS25 tree type names
4. **Extracts growth stage** - Parses `stage05`, `var02` etc from names
5. **Generates treePlant.xml** - Valid savegame format
6. **Optionally removes trees** - Modifies i3d (with backup)

### Supported Tree Types

The script recognizes these patterns in node names:

| Pattern | Maps To |
|---------|---------|
| oak | oak |
| pine, lodgepolepine | lodgepolePine |
| spruce | spruce |
| birch | birch |
| maple | maple |
| aspen | aspen |
| beech | beech |
| willow | willow |
| poplar | poplar |
| elm, americanelm | americanElm |
| cherry | cherry |
| zelkova, japanesezelkova | japaneseZelkova |
| scotspine, pinussylvestris | pinusSylvestris |
| hickory, shagbarkhickory | shagbarkHickory |
| ... | (see script for full list) |

## Runtime Conversion Mod

For converting static trees to planted trees at runtime on any map, use the [Tree Converter](https://www.farming-simulator.com/mod.php?mod_id=344891) mod. It adds a "Trees" option to the in-game map where you can view tree locations by type and convert selected types to planted trees that persist in savegames.

## Using TreePlantLoader.lua (Recommended)

The easiest way to ship pre-planted trees with your map is to use the `TreePlantLoader.lua` script. This script hooks `TreePlantManager:loadFromXMLFile` to load trees from your map's `defaultSavegame/treePlant.xml` on first game start.

### Setup

1. **Generate treePlant.xml** using `convert_static_trees.py`:

```bash
python convert_static_trees.py maps/map01/map.i3d \
    --output defaultSavegame/treePlant.xml \
    --remove-from-i3d
```

2. **Copy TreePlantLoader.lua** to your map's scripts folder

3. **Update your modDesc.xml** to include the script:

```xml
<extraSourceFiles>
    <sourceFile filename="scripts/TreePlantLoader.lua"/>
</extraSourceFiles>
```

4. **Final map structure**:

```
YourMap/
├── modDesc.xml
├── map/
│   ├── map.i3d              ← Trees removed
│   └── map.xml
├── defaultSavegame/
│   └── treePlant.xml        ← Generated tree data
└── scripts/
    └── TreePlantLoader.lua  ← Loader script
```

### How It Works

The script hooks `TreePlantManager:loadFromXMLFile` to intercept tree loading:

1. **New game** (xmlFilename is nil): Loads `defaultSavegame/treePlant.xml` from the map
2. **Existing savegame with trees**: Loads normally from savegame
3. **Existing savegame with empty treePlant.xml**: Falls back to map defaults

This approach integrates cleanly with the game's existing tree loading pipeline.

### Why This Approach?

The game's `defaultSavegame/` folder approach doesn't work for `treePlant.xml` because:

1. The game only supports `defaultVehiclesXMLFilename`, `defaultPlaceablesXMLFilename`, etc. in modDesc.xml
2. There is no `defaultTreePlantXMLFilename` attribute
3. For new savegames, `treePlantXMLLoad` is explicitly set to `nil`

TreePlantLoader hooks the loading function to work around this limitation.

## Recommendations

1. **For new maps**: Use `convert_static_trees.py` + `TreePlantLoader.lua` (recommended)
2. **For existing maps**: Use the "apply to new plantings only" approach
3. **For runtime conversion**: Use the `FS25_TreeConverter` mod

The cleanest solution depends on your specific needs and how much you want to modify the original map structure.
