#!/usr/bin/env python3
"""
Convert static trees from map .i3d to treePlant.xml savegame format.

This script:
1. Parses the map .i3d file to find all tree nodes
2. Extracts their positions, rotations, and tree types
3. Generates a treePlant.xml file for the savegame
4. Optionally removes the trees from the .i3d (creates backup first)

Tree types can be loaded from:
- Map-specific treeTypes.xml (auto-detected from map.xml)
- Game's default data/maps/maps_treeTypes.xml
- Custom treeTypes.xml specified via --tree-types

Usage:
    # Extract and preview (no changes to .i3d)
    python convert_static_trees.py map.i3d --preview

    # Extract to treePlant.xml only
    python convert_static_trees.py map.i3d --output treePlant.xml

    # Full conversion: extract AND remove from .i3d
    python convert_static_trees.py map.i3d --output treePlant.xml --remove-from-i3d

    # Specify which node contains trees
    python convert_static_trees.py map.i3d --tree-parent "trees" --output treePlant.xml

    # Use game data folder for default tree types
    python convert_static_trees.py map.i3d -o treePlant.xml --game-data /path/to/data

    # Use specific treeTypes.xml
    python convert_static_trees.py map.i3d -o treePlant.xml --tree-types config/treeTypes.xml
"""

import argparse
import re
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Optional, Dict, Tuple
from datetime import datetime
import math


@dataclass
class TreeTypeStage:
    """A growth stage for a tree type."""
    stage_index: int  # 1-based index
    variations: List[Dict[str, str]]  # List of {filename, name (optional)}


@dataclass
class TreeTypeDesc:
    """Tree type descriptor loaded from treeTypes.xml."""
    name: str
    split_type: str
    title: str
    stages: List[TreeTypeStage]

    @property
    def max_stage(self) -> int:
        return len(self.stages)

    def find_stage_by_filename(self, filename: str) -> Tuple[int, int]:
        """Find stage and variation index by matching filename.
        Returns (stage_index, variation_index) or (max_stage, 1) if not found."""
        # Extract just the base name without extension
        base_name = Path(filename).stem.lower()

        for stage in self.stages:
            for var_idx, variation in enumerate(stage.variations, 1):
                var_filename = variation.get('filename', '')
                var_base = Path(var_filename).stem.lower()
                if var_base == base_name or base_name in var_filename.lower():
                    return stage.stage_index, var_idx

        return self.max_stage, 1


@dataclass
class TreeInstance:
    """A single tree instance from the map."""
    node_name: str
    tree_type: str
    # World position
    x: float
    y: float
    z: float
    # Rotation in degrees
    rx: float
    ry: float
    rz: float
    # Scale (for reference)
    sx: float = 1.0
    sy: float = 1.0
    sz: float = 1.0
    # Growth info
    growth_state: int = 5  # Mature
    variation_index: int = 1
    # XML element reference (for removal)
    element: Optional[ET.Element] = field(default=None, repr=False)
    parent: Optional[ET.Element] = field(default=None, repr=False)


class TreeTypeLoader:
    """Load tree type definitions from treeTypes.xml files."""

    def __init__(self):
        self.tree_types: Dict[str, TreeTypeDesc] = {}  # name (uppercase) -> TreeTypeDesc

    def load_from_xml(self, xml_path: Path, base_directory: Optional[Path] = None) -> int:
        """
        Load tree types from a treeTypes.xml file.
        New types are added, existing types may be extended/overridden.
        Returns number of types loaded.
        """
        if not xml_path.exists():
            print(f"Warning: treeTypes.xml not found: {xml_path}")
            return 0

        try:
            tree = ET.parse(xml_path)
            root = tree.getroot()
        except ET.ParseError as e:
            print(f"Error parsing {xml_path}: {e}")
            return 0

        count = 0
        # Find treeTypes element - could be root or child
        tree_types_elem = root.find('.//treeTypes')
        if tree_types_elem is None:
            tree_types_elem = root  # treeTypes might be under <map>

        for tree_type_elem in tree_types_elem.findall('treeType'):
            name = tree_type_elem.get('name', '')
            if not name:
                continue

            split_type = tree_type_elem.get('splitType', name.upper())
            title = tree_type_elem.get('title', name)

            # Parse stages
            stages = []
            stage_index = 1
            for stage_elem in tree_type_elem.findall('stage'):
                variations = []

                # Check if stage has direct filename attribute
                filename = stage_elem.get('filename')
                if filename:
                    # Resolve $data paths
                    if base_directory and filename.startswith('$data/'):
                        filename = str(base_directory / filename[6:])
                    variations.append({'filename': filename})
                else:
                    # Stage has variation children
                    for var_elem in stage_elem.findall('variation'):
                        var_filename = var_elem.get('filename', '')
                        if base_directory and var_filename.startswith('$data/'):
                            var_filename = str(base_directory / var_filename[6:])
                        var_name = var_elem.get('name', '')
                        variations.append({'filename': var_filename, 'name': var_name})

                if variations:
                    stages.append(TreeTypeStage(stage_index=stage_index, variations=variations))
                    stage_index += 1

            if stages:
                name_upper = name.upper()
                self.tree_types[name_upper] = TreeTypeDesc(
                    name=name,
                    split_type=split_type,
                    title=title,
                    stages=stages
                )
                count += 1

        return count

    def load_from_map(self, map_xml_path: Path, game_data_path: Optional[Path] = None) -> int:
        """
        Load tree types like the game does:
        1. Load base types from game data/maps/maps_treeTypes.xml
        2. Load map-specific types which extend the base

        Args:
            map_xml_path: Path to the map's map.xml file
            game_data_path: Path to game's data folder (for base types)

        Returns total number of types loaded.
        """
        total = 0
        map_dir = map_xml_path.parent

        # 1. Load base game tree types if game_data_path provided
        if game_data_path:
            base_types_path = game_data_path / 'maps' / 'maps_treeTypes.xml'
            if base_types_path.exists():
                loaded = self.load_from_xml(base_types_path, game_data_path)
                print(f"Loaded {loaded} base tree types from {base_types_path}")
                total += loaded

        # 2. Parse map.xml to find treeTypes filename
        try:
            tree = ET.parse(map_xml_path)
            root = tree.getroot()
            tree_types_elem = root.find('.//treeTypes')
            if tree_types_elem is not None:
                filename = tree_types_elem.get('filename', '')
                if filename:
                    # Try multiple path resolutions (FS25 paths can be tricky)
                    # 1. Direct relative to map directory
                    # 2. Strip leading "map/" if present (common in modDesc paths)
                    possible_paths = [
                        map_dir / filename,
                    ]
                    # If filename starts with "map/", try without that prefix too
                    if filename.startswith('map/'):
                        possible_paths.append(map_dir / filename[4:])

                    for map_tree_types_path in possible_paths:
                        if map_tree_types_path.exists():
                            loaded = self.load_from_xml(map_tree_types_path, map_dir)
                            print(f"Loaded {loaded} map tree types from {map_tree_types_path}")
                            total += loaded
                            break
                    else:
                        print(f"Warning: Map tree types not found at any of: {possible_paths}")
        except ET.ParseError as e:
            print(f"Error parsing map.xml: {e}")

        return total

    def get_type(self, name: str) -> Optional[TreeTypeDesc]:
        """Get tree type by name (case-insensitive)."""
        return self.tree_types.get(name.upper())

    def get_max_stage(self, name: str) -> int:
        """Get max stage for a tree type, falling back to hardcoded if not found."""
        tree_type = self.get_type(name)
        if tree_type:
            return tree_type.max_stage
        # Fallback to hardcoded
        return MAX_STAGES.get(name.upper(), 5)

    def find_stage_and_variation(self, tree_type_name: str, filename: str) -> Tuple[int, int]:
        """Find stage and variation for a filename. Returns (stage, variation)."""
        tree_type = self.get_type(tree_type_name)
        if tree_type:
            return tree_type.find_stage_by_filename(filename)
        # Fallback: try to extract from filename
        stage_match = re.search(r'stage[_]?(\d+)', filename.lower())
        var_match = re.search(r'var[_]?(\d+)', filename.lower())
        stage = int(stage_match.group(1)) if stage_match else self.get_max_stage(tree_type_name)
        variation = int(var_match.group(1)) if var_match else 1
        return stage, variation

    def list_types(self) -> List[str]:
        """List all loaded tree type names."""
        return [t.name for t in self.tree_types.values()]


# Global tree type loader instance
_tree_type_loader: Optional[TreeTypeLoader] = None


def get_tree_type_loader() -> TreeTypeLoader:
    """Get or create the global tree type loader."""
    global _tree_type_loader
    if _tree_type_loader is None:
        _tree_type_loader = TreeTypeLoader()
    return _tree_type_loader


# Tree type detection patterns (fallback when treeTypes.xml not available)
# Pattern -> (tree_type_name, max_growth_stage)
# Max stages verified from $data/maps/trees/ folder contents
TREE_PATTERNS = {
    r'americanelm': ('americanElm', 5),
    r'aspen': ('aspen', 6),
    r'beech': ('beech', 6),
    r'betulaermanii|ermanii': ('betulaErmanii', 4),
    r'birch(?!.*ermanii)': ('birch', 5),
    r'boxelder': ('boxelder', 3),
    r'cherry': ('cherry', 4),
    r'chineseelm': ('chineseElm', 4),
    r'downyserviceberry|serviceberry': ('downyServiceBerry', 3),
    r'goldenrain': ('goldenRain', 4),
    r'japanesezelkova|zelkova': ('japaneseZelkova', 4),
    r'lodgepolepine': ('lodgepolePine', 3),
    r'maple': ('maple', 5),
    r'northerncatalpa|catalpa': ('northernCatalpa', 4),
    r'oak': ('oak', 5),
    r'pinussylvestris|scotspine|scots_pine': ('pinusSylvestris', 5),
    r'pinustabuliformis|chinesepine': ('pinusTabuliformis', 5),
    r'poplar': ('poplar', 5),
    r'shagbarkhickory|hickory': ('shagbarkHickory', 4),
    r'spruce': ('spruce', 5),
    r'tiliaamurensis|linden(?!.*station)|limetree': ('tiliaAmurensis', 4),
    r'willow': ('willow', 5),
    # Generic pine fallback
    r'pine(?!.*sylvestris)(?!.*tabuliformis)': ('lodgepolePine', 3),
}

# Direct lookup for max stages by tree type name (for quick access)
MAX_STAGES = {
    'AMERICANELM': 5,
    'ASPEN': 6,
    'BEECH': 6,
    'BETULAERMANII': 4,
    'BIRCH': 5,
    'BOXELDER': 3,
    'CHERRY': 4,
    'CHINESEELM': 4,
    'DOWNYSERVICEBERRY': 3,
    'GOLDENRAIN': 4,
    'JAPANESEZELKOVA': 4,
    'LODGEPOLEPINE': 3,
    'MAPLE': 5,
    'NORTHERNCATALPA': 4,
    'OAK': 5,
    'PINUSSYLVESTRIS': 5,
    'PINUSTABULIFORMIS': 5,
    'POPLAR': 5,
    'SHAGBARKHICKORY': 4,
    'SPRUCE': 5,
    'TILIAAMURENSIS': 4,
    'WILLOW': 5,
}


def detect_tree_type(name: str) -> Optional[Tuple[str, int]]:
    """Detect tree type from node name. Returns (type_name, max_growth_stage) or None."""
    name_lower = name.lower().replace('_', '').replace('-', '').replace(' ', '')

    for pattern, (tree_type, stages) in TREE_PATTERNS.items():
        if re.search(pattern, name_lower):
            return tree_type, stages

    return None


def parse_vector(value: str, default: Tuple[float, ...] = (0, 0, 0)) -> Tuple[float, ...]:
    """Parse space-separated vector string."""
    if not value:
        return default
    try:
        return tuple(float(v) for v in value.split())
    except ValueError:
        return default


def multiply_matrices(m1: List[List[float]], m2: List[List[float]]) -> List[List[float]]:
    """Multiply two 4x4 matrices."""
    result = [[0.0] * 4 for _ in range(4)]
    for i in range(4):
        for j in range(4):
            for k in range(4):
                result[i][j] += m1[i][k] * m2[k][j]
    return result


def rotation_matrix(rx: float, ry: float, rz: float) -> List[List[float]]:
    """Create rotation matrix from Euler angles (degrees)."""
    # Convert to radians
    rx, ry, rz = math.radians(rx), math.radians(ry), math.radians(rz)

    # Rotation matrices
    cx, sx = math.cos(rx), math.sin(rx)
    cy, sy = math.cos(ry), math.sin(ry)
    cz, sz = math.cos(rz), math.sin(rz)

    # Combined rotation (ZYX order, typical for i3d)
    return [
        [cy*cz, -cy*sz, sy, 0],
        [sx*sy*cz + cx*sz, -sx*sy*sz + cx*cz, -sx*cy, 0],
        [-cx*sy*cz + sx*sz, cx*sy*sz + sx*cz, cx*cy, 0],
        [0, 0, 0, 1]
    ]


def transform_matrix(tx: float, ty: float, tz: float,
                     rx: float, ry: float, rz: float,
                     sx: float, sy: float, sz: float) -> List[List[float]]:
    """Create full transform matrix."""
    rot = rotation_matrix(rx, ry, rz)
    # Apply scale and translation
    rot[0] = [rot[0][j] * sx for j in range(4)]
    rot[1] = [rot[1][j] * sy for j in range(4)]
    rot[2] = [rot[2][j] * sz for j in range(4)]
    rot[0][3] = tx
    rot[1][3] = ty
    rot[2][3] = tz
    return rot


def extract_world_transform(matrix: List[List[float]]) -> Tuple[Tuple[float, float, float],
                                                                  Tuple[float, float, float]]:
    """Extract world position and rotation from transform matrix."""
    # Position is straightforward
    x, y, z = matrix[0][3], matrix[1][3], matrix[2][3]

    # Extract rotation (simplified - assumes no skew)
    sy = matrix[0][2]
    ry = math.asin(max(-1, min(1, sy)))

    if abs(math.cos(ry)) > 0.001:
        rx = math.atan2(-matrix[1][2], matrix[2][2])
        rz = math.atan2(-matrix[0][1], matrix[0][0])
    else:
        rx = math.atan2(matrix[2][1], matrix[1][1])
        rz = 0

    return (x, y, z), (math.degrees(rx), math.degrees(ry), math.degrees(rz))


class I3DTreeExtractor:
    """Extract trees from i3d file."""

    def __init__(self, i3d_path: Path):
        self.i3d_path = i3d_path
        self.tree = ET.parse(i3d_path)
        self.root = self.tree.getroot()
        self.ns = self._get_namespace()
        self.trees: List[TreeInstance] = []
        self.tree_parents: List[ET.Element] = []
        self.file_id_to_tree_type: Dict[str, Tuple[str, int, int]] = {}  # fileId -> (type, stage, var)
        self.tree_type_loader: Optional[TreeTypeLoader] = None  # Set externally if available

    def _get_namespace(self) -> Dict[str, str]:
        """Extract XML namespace if present."""
        tag = self.root.tag
        if tag.startswith('{'):
            ns_uri = tag[1:tag.index('}')]
            return {'i3d': ns_uri}
        return {}

    def _find_element(self, tag: str) -> Optional[ET.Element]:
        """Find element by tag, handling namespace."""
        if self.ns:
            return self.root.find(f".//{{{self.ns['i3d']}}}{tag}")
        return self.root.find(f".//{tag}")

    def _iter_elements(self, tag: str):
        """Iterate over elements by tag, handling namespace."""
        if self.ns:
            yield from self.root.iter(f"{{{self.ns['i3d']}}}{tag}")
        else:
            yield from self.root.iter(tag)

    def _build_file_id_map(self):
        """Build mapping from fileId to tree type info from File elements."""
        self.file_id_to_tree_type = {}

        # Find Files section
        for elem in self.root.iter():
            tag = elem.tag
            if self.ns:
                tag = tag.replace(f"{{{self.ns['i3d']}}}", "")

            if tag == 'File':
                file_id = elem.get('fileId')
                filename = elem.get('filename', '')

                # Check if this is a tree file
                if '/trees/' in filename and filename.endswith('.i3d'):
                    # Parse tree type and stage from filename
                    # e.g., "$data/maps/trees/oak/oak_stage05.i3d"
                    basename = Path(filename).stem  # oak_stage05

                    # Detect tree type
                    tree_info = detect_tree_type(basename)
                    if tree_info:
                        tree_type, max_stage = tree_info

                        # Use tree type loader if available for more accurate stage/variation detection
                        if self.tree_type_loader:
                            stage, variation = self.tree_type_loader.find_stage_and_variation(tree_type, basename)
                        else:
                            # Fallback: extract stage number from filename
                            stage_match = re.search(r'stage[_]?(\d+)', basename.lower())
                            stage = int(stage_match.group(1)) if stage_match else max_stage

                            # Extract variation
                            var_match = re.search(r'var[_]?(\d+)', basename.lower())
                            variation = int(var_match.group(1)) if var_match else 1

                        self.file_id_to_tree_type[file_id] = (tree_type, stage, variation)

    def find_trees(self, parent_name: Optional[str] = None) -> List[TreeInstance]:
        """
        Find all tree nodes in the i3d.

        Trees are stored as ReferenceNode elements with referenceId pointing
        to File entries for tree .i3d files.

        Args:
            parent_name: If specified, only search under nodes with this name
        """
        # First build the file ID to tree type mapping
        self._build_file_id_map()

        if self.file_id_to_tree_type:
            print(f"Found {len(self.file_id_to_tree_type)} tree type definitions (ReferenceNode mode)")
        else:
            print("No tree file references found, scanning for inline tree nodes...")

        self.trees = []
        identity = [[1,0,0,0], [0,1,0,0], [0,0,1,0], [0,0,0,1]]

        def scan_node(elem: ET.Element, parent: Optional[ET.Element],
                      parent_matrix: List[List[float]], in_tree_parent: bool):
            """Recursively scan for tree nodes."""
            tag = elem.tag
            if self.ns:
                tag = tag.replace(f"{{{self.ns['i3d']}}}", "")

            name = elem.get('name', '')

            # Check if this is the tree parent we're looking for
            if parent_name and name.lower() == parent_name.lower():
                in_tree_parent = True
                if elem not in self.tree_parents:
                    self.tree_parents.append(elem)

            # Get local transform
            trans = parse_vector(elem.get('translation'), (0, 0, 0))
            rot = parse_vector(elem.get('rotation'), (0, 0, 0))
            scale = parse_vector(elem.get('scale'), (1, 1, 1))

            # Build local matrix and combine with parent
            local_matrix = transform_matrix(
                trans[0], trans[1], trans[2],
                rot[0], rot[1], rot[2],
                scale[0], scale[1], scale[2]
            )
            world_matrix = multiply_matrices(parent_matrix, local_matrix)

            # Check if this is a ReferenceNode pointing to a tree
            if tag == 'ReferenceNode':
                ref_id = elem.get('referenceId')
                if ref_id and ref_id in self.file_id_to_tree_type:
                    if not parent_name or in_tree_parent:
                        tree_type, stage, variation = self.file_id_to_tree_type[ref_id]
                        world_pos, world_rot = extract_world_transform(world_matrix)

                        self.trees.append(TreeInstance(
                            node_name=name,
                            tree_type=tree_type,
                            x=world_pos[0],
                            y=world_pos[1],
                            z=world_pos[2],
                            rx=world_rot[0],
                            ry=world_rot[1],
                            rz=world_rot[2],
                            sx=scale[0],
                            sy=scale[1],
                            sz=scale[2],
                            growth_state=stage,
                            variation_index=variation,
                            element=elem,
                            parent=parent
                        ))

            # Also check TransformGroup/Shape nodes with tree-like names (legacy support)
            elif tag in ('TransformGroup', 'Shape'):
                tree_info = detect_tree_type(name)
                if tree_info and (not parent_name or in_tree_parent):
                    tree_type, max_stage = tree_info
                    world_pos, world_rot = extract_world_transform(world_matrix)

                    # Detect growth stage from name if present
                    growth_state = max_stage
                    stage_match = re.search(r'stage[_]?(\d+)', name.lower())
                    if stage_match:
                        growth_state = int(stage_match.group(1))

                    # Detect variation from name if present
                    variation = 1
                    var_match = re.search(r'var[_]?(\d+)', name.lower())
                    if var_match:
                        variation = int(var_match.group(1))

                    self.trees.append(TreeInstance(
                        node_name=name,
                        tree_type=tree_type,
                        x=world_pos[0],
                        y=world_pos[1],
                        z=world_pos[2],
                        rx=world_rot[0],
                        ry=world_rot[1],
                        rz=world_rot[2],
                        sx=scale[0],
                        sy=scale[1],
                        sz=scale[2],
                        growth_state=growth_state,
                        variation_index=variation,
                        element=elem,
                        parent=parent
                    ))

            # Recurse into children for TransformGroups
            for child in elem:
                child_tag = child.tag
                if self.ns:
                    child_tag = child_tag.replace(f"{{{self.ns['i3d']}}}", "")
                if child_tag in ('TransformGroup', 'Shape', 'ReferenceNode'):
                    scan_node(child, elem, world_matrix, in_tree_parent)

        # Find Scene node and start scanning
        scene = self._find_element('Scene')
        if scene is None:
            print("Warning: No Scene element found in i3d")
            return []

        for child in scene:
            scan_node(child, scene, identity, parent_name is None)

        return self.trees

    def remove_trees(self) -> int:
        """Remove found trees from the XML tree. Returns count of removed."""
        removed = 0

        for tree in self.trees:
            if tree.element is not None and tree.parent is not None:
                try:
                    tree.parent.remove(tree.element)
                    removed += 1
                except ValueError:
                    pass  # Already removed

        return removed

    def save(self, output_path: Path):
        """Save modified i3d."""
        self.tree.write(output_path, encoding='utf-8', xml_declaration=True)


def generate_treeplant_xml(trees: List[TreeInstance], output_path: Path, loader: Optional[TreeTypeLoader] = None):
    """Generate treePlant.xml from extracted trees."""
    lines = ['<?xml version="1.0" encoding="utf-8" standalone="no"?>']
    lines.append('<treePlant>')

    final_stage_count = 0
    growing_count = 0

    for tree in trees:
        pos = f"{tree.x:.4f} {tree.y:.4f} {tree.z:.4f}"
        rot = f"{tree.rx:.4f} {tree.ry:.4f} {tree.rz:.4f}"

        attrs = [
            f'treeType="{tree.tree_type.upper()}"',
            f'position="{pos}"',
            f'rotation="{rot}"',
            f'growthStateI="{tree.growth_state}"',
        ]

        if tree.variation_index != 1:
            attrs.append(f'variationIndex="{tree.variation_index}"')

        # Determine if tree is at final stage (shouldn't grow)
        # Use loader for max stage if available
        if loader:
            max_stage = loader.get_max_stage(tree.tree_type)
        else:
            max_stage = MAX_STAGES.get(tree.tree_type.upper(), 5)
        is_at_final_stage = tree.growth_state >= max_stage

        if is_at_final_stage:
            attrs.append('isGrowing="false"')
            final_stage_count += 1
        else:
            attrs.append('isGrowing="true"')
            growing_count += 1

        attrs.append('splitShapeFileId="-1"')

        lines.append(f'    <tree {" ".join(attrs)}/>')

    lines.append('</treePlant>')

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    print(f"  Final stage (isGrowing=false): {final_stage_count}")
    print(f"  Growing (isGrowing=true): {growing_count}")


def print_summary(trees: List[TreeInstance], loader: Optional[TreeTypeLoader] = None):
    """Print summary of found trees."""
    print(f"\nFound {len(trees)} trees:")

    # Group by type
    by_type: Dict[str, List[TreeInstance]] = {}
    for tree in trees:
        if tree.tree_type not in by_type:
            by_type[tree.tree_type] = []
        by_type[tree.tree_type].append(tree)

    total_final = 0
    total_growing = 0

    for tree_type in sorted(by_type.keys()):
        tree_list = by_type[tree_type]
        # Use loader for max stage if available, otherwise fallback
        if loader:
            max_stage = loader.get_max_stage(tree_type)
        else:
            max_stage = MAX_STAGES.get(tree_type.upper(), 5)
        final_count = sum(1 for t in tree_list if t.growth_state >= max_stage)
        growing_count = len(tree_list) - final_count
        total_final += final_count
        total_growing += growing_count

        print(f"  {tree_type}: {len(tree_list)} (max stage: {max_stage})")

        # Show growth state distribution
        stages = {}
        for t in tree_list:
            stages[t.growth_state] = stages.get(t.growth_state, 0) + 1
        if len(stages) > 1:
            stage_str = ", ".join(f"stage {s}: {c}" for s, c in sorted(stages.items()))
            print(f"    ({stage_str})")
        print(f"    → {final_count} final stage, {growing_count} growing")

    # Summary
    print(f"\nGrowth status summary:")
    print(f"  Final stage (isGrowing=false): {total_final} ({100*total_final/len(trees):.1f}%)")
    print(f"  Growing (isGrowing=true): {total_growing} ({100*total_growing/len(trees):.1f}%)")

    # Bounding box
    if trees:
        min_x = min(t.x for t in trees)
        max_x = max(t.x for t in trees)
        min_z = min(t.z for t in trees)
        max_z = max(t.z for t in trees)
        print(f"\nBounding box: X [{min_x:.1f}, {max_x:.1f}], Z [{min_z:.1f}, {max_z:.1f}]")


def main():
    parser = argparse.ArgumentParser(
        description='Convert static trees from i3d to treePlant.xml',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Preview what would be extracted
  %(prog)s map.i3d --preview

  # Extract trees to treePlant.xml
  %(prog)s map.i3d -o treePlant.xml

  # Extract and remove from i3d (creates backup)
  %(prog)s map.i3d -o treePlant.xml --remove-from-i3d

  # Only extract trees under "trees" node
  %(prog)s map.i3d -o treePlant.xml --tree-parent trees

  # Load tree types from map.xml (auto-detects treeTypes.xml reference)
  %(prog)s map.i3d -o treePlant.xml --map-xml path/to/map.xml

  # Also load base game tree types
  %(prog)s map.i3d -o treePlant.xml --map-xml map.xml --game-data /path/to/data

  # Use specific treeTypes.xml directly
  %(prog)s map.i3d -o treePlant.xml --tree-types config/treeTypes.xml

  # List loaded tree types
  %(prog)s map.i3d --map-xml map.xml --list-tree-types
"""
    )

    parser.add_argument('i3d', type=Path, help='Input map .i3d file')
    parser.add_argument('-o', '--output', type=Path, help='Output treePlant.xml path')
    parser.add_argument('--preview', action='store_true',
                       help='Preview found trees without writing files')
    parser.add_argument('--remove-from-i3d', action='store_true',
                       help='Remove trees from i3d (creates .i3d.backup)')
    parser.add_argument('--tree-parent', metavar='NAME',
                       help='Only extract trees under this parent node name')
    parser.add_argument('--list-nodes', action='store_true',
                       help='List all top-level node names (for finding tree parent)')

    # Tree type loading options
    parser.add_argument('--map-xml', type=Path, metavar='FILE',
                       help='Path to map.xml to auto-detect treeTypes.xml')
    parser.add_argument('--game-data', type=Path, metavar='DIR',
                       help='Path to game data folder (for base tree types)')
    parser.add_argument('--tree-types', type=Path, metavar='FILE',
                       help='Path to specific treeTypes.xml file')
    parser.add_argument('--list-tree-types', action='store_true',
                       help='List all loaded tree types and exit')

    args = parser.parse_args()

    if not args.i3d.exists():
        print(f"Error: File not found: {args.i3d}")
        return 1

    # Load tree types if specified
    loader = get_tree_type_loader()
    tree_types_loaded = False

    if args.tree_types:
        # Direct tree types file
        if args.tree_types.exists():
            base_dir = args.tree_types.parent
            loaded = loader.load_from_xml(args.tree_types, base_dir)
            print(f"Loaded {loaded} tree types from {args.tree_types}")
            tree_types_loaded = loaded > 0
        else:
            print(f"Warning: Tree types file not found: {args.tree_types}")

    if args.map_xml:
        # Load from map.xml (with optional game data for base types)
        if args.map_xml.exists():
            loaded = loader.load_from_map(args.map_xml, args.game_data)
            tree_types_loaded = loaded > 0
        else:
            print(f"Warning: Map XML not found: {args.map_xml}")

    if args.list_tree_types:
        if not tree_types_loaded:
            print("No tree types loaded. Use --map-xml or --tree-types to load tree type definitions.")
        else:
            print(f"\nLoaded {len(loader.tree_types)} tree types:")
            for name in sorted(loader.list_types()):
                tree_type = loader.get_type(name)
                if tree_type:
                    print(f"  {tree_type.name} ({tree_type.split_type}): {tree_type.max_stage} stages")
                    for stage in tree_type.stages:
                        var_info = ", ".join(Path(v['filename']).stem for v in stage.variations if v.get('filename'))
                        print(f"    Stage {stage.stage_index}: {var_info}")
        return 0

    print(f"Parsing {args.i3d}...")
    extractor = I3DTreeExtractor(args.i3d)

    # Pass tree type loader to extractor if loaded
    if tree_types_loaded:
        extractor.tree_type_loader = loader

    if args.list_nodes:
        # Just list top-level nodes
        scene = extractor._find_element('Scene')
        if scene:
            print("\nTop-level nodes in Scene:")
            for child in scene:
                name = child.get('name', '(unnamed)')
                tag = child.tag
                if extractor.ns:
                    tag = tag.replace(f"{{{extractor.ns['i3d']}}}", "")
                print(f"  {name} ({tag})")
        return 0

    # Find trees
    trees = extractor.find_trees(parent_name=args.tree_parent)

    if not trees:
        print("No trees found!")
        if args.tree_parent:
            print(f"  (searched only under '{args.tree_parent}' nodes)")
        print("  Try --list-nodes to see available parent nodes")
        return 1

    # Pass loader to print_summary if we have tree types loaded
    print_summary(trees, loader if tree_types_loaded else None)

    if args.preview:
        print("\n[Preview mode - no files modified]")
        return 0

    # Generate treePlant.xml
    if args.output:
        generate_treeplant_xml(trees, args.output, loader if tree_types_loaded else None)
        print(f"\nGenerated: {args.output}")

    # Remove from i3d if requested
    if args.remove_from_i3d:
        if not args.output:
            print("Error: --remove-from-i3d requires --output")
            return 1

        # Create backup
        backup_path = args.i3d.with_suffix('.i3d.backup')
        if not backup_path.exists():
            shutil.copy2(args.i3d, backup_path)
            print(f"Created backup: {backup_path}")
        else:
            # Create timestamped backup
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            backup_path = args.i3d.with_suffix(f'.i3d.backup_{timestamp}')
            shutil.copy2(args.i3d, backup_path)
            print(f"Created backup: {backup_path}")

        # Remove trees
        removed = extractor.remove_trees()
        extractor.save(args.i3d)
        print(f"Removed {removed} tree nodes from {args.i3d}")

    print("\nDone!")
    return 0


if __name__ == '__main__':
    exit(main())
