"""Writes the four level scenes (levels/level_01.tscn to level_04.tscn).

Each level is described below as a list of sections from south (start) to
north (finish). Running this script OVERWRITES those four files, so any
changes made to them in the Godot editor are lost. Tweak the numbers here,
or stop using the script and edit the levels in the editor instead.

Run from the project folder:  uv run --no-project tools/level_generator.py
"""

import json
import math
import os
import random

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIALS_FILE = os.path.join(PROJECT, "tools", "level_dials.json")

# Speed dial for each section of each level (start, after checkpoint 1, 2, 3).
# tools/tune_levels.py finds these; 1.0 is the base speed written below.
DIALS = {}
if os.path.exists(DIALS_FILE):
    with open(DIALS_FILE, encoding="utf-8") as dials_in:
        DIALS = json.load(dials_in)

# Play area is x from -11 to 11. North is -z.
HALF_WIDTH = 11.0


def num(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    text = f"{value:.4f}".rstrip("0")
    return text + "0" if text.endswith(".") else text


def vec(x, y, z):
    return f"Vector3({num(float(x))}, {num(float(y))}, {num(float(z))})"


def color(r, g, b, a=1.0):
    return f"Color({num(float(r))}, {num(float(g))}, {num(float(b))}, {num(float(a))})"


def transform(x, y, z, yaw=0.0, scale=1.0):
    c = math.cos(math.radians(yaw)) * scale
    s = math.sin(math.radians(yaw)) * scale
    values = [c, 0.0, s, 0.0, scale, 0.0, -s, 0.0, c, x, y, z]
    return "Transform3D(" + ", ".join(num(float(v)) for v in values) + ")"


class Scene:
    def __init__(self, root_name):
        self.root_name = root_name
        self.resources = []  # (type, path, id)
        self.resource_ids = {}
        self.sub_resources = []
        self.nodes = []
        self.names = {}

    def res(self, path):
        if path not in self.resource_ids:
            kind = "Script" if path.endswith(".gd") else "PackedScene"
            base = os.path.splitext(os.path.basename(path))[0].replace("-", "_")
            rid = f"{len(self.resources) + 1}_{base}"
            self.resources.append((kind, path, rid))
            self.resource_ids[path] = rid
        return f'ExtResource("{self.resource_ids[path]}")'

    def sub(self, text):
        self.sub_resources.append(text)

    def unique(self, parent, name):
        key = (parent, name)
        self.names[key] = self.names.get(key, 0) + 1
        count = self.names[key]
        return name if count == 1 else f"{name}{count}"

    def node(self, name, parent=".", node_type=None, instance=None, **props):
        name = self.unique(parent, name)
        header = f'[node name="{name}"'
        if node_type:
            header += f' type="{node_type}"'
        if parent is not None:
            header += f' parent="{parent}"'
        if instance:
            header += f" instance={self.res(instance)}"
        lines = [header + "]"]
        for key, value in props.items():
            lines.append(f"{key} = {value}")
        self.nodes.append("\n".join(lines))
        return name

    def text(self):
        parts = ["[gd_scene format=3]", ""]
        for kind, path, rid in self.resources:
            parts.append(f'[ext_resource type="{kind}" path="{path}" id="{rid}"]')
        parts.append("")
        for block in self.sub_resources:
            parts.append(block)
            parts.append("")
        for block in self.nodes:
            parts.append(block)
            parts.append("")
        return "\n".join(parts)


BLOCK = "res://scripts/block.gd"
ZONE = "res://scripts/zone.gd"
ARM = "res://scripts/hazard_arm.gd"
SPIKES = "res://scripts/spike_field.gd"
WALKER = "res://scenes/enemy.tscn"
BOULDER = "res://scenes/boulder.tscn"
CAR = "res://scenes/car.tscn"
ORC = "res://assets/dungeon/character-orc.glb"


class Level:
    """Shared building helpers. Subclasses add the setting's look."""

    def __init__(self, root_name, finish_z, key=""):
        self.key = key
        self.s = Scene(root_name)
        self.finish_z = finish_z
        self.s.node(root_name, parent=None, node_type="Node3D", script=self.s.res("res://scripts/level.gd"))
        for group in ["Terrain", "Hazards", "Zones", "Decor"]:
            self.s.node(group, node_type="Node3D")
        # Difficulty dials. speed > 1 makes every hazard faster (all timings
        # are divided by it); extra_cars adds cars to every traffic lane.
        self.speed = 1.0
        self.extra_cars = 0

    def section(self, index):
        """Starts section index: its hazards use that section's speed dial."""
        self.speed = DIALS.get(self.key, [1.0] * 4)[index]

    def t(self, seconds):
        """A timing in seconds, adjusted by the level's speed dial."""
        return None if seconds is None else seconds / self.speed

    # --- basics ---

    def start(self, z=3.0):
        self.s.node("Start", node_type="Marker3D", transform=transform(0, 0, z))

    def block(self, name, x, y, z, size, parent="Terrain", **props):
        props = {k: (num(v) if isinstance(v, (bool, int, float)) else v) for k, v in props.items()}
        return self.s.node(name, parent, "StaticBody3D", transform=transform(x, y, z),
                           script=self.s.res(BLOCK), size=vec(*size), **props)

    def invisible_wall(self, x, z, size):
        self.block("Edge", x, 0, z, size, show_box=False)

    def checkpoint(self, z, width=20.0):
        props = {}
        if width != 20.0:
            props["size"] = vec(width, 2, 3)
        self.s.node("Checkpoint", "Zones", "Area3D", transform=transform(0, 0, z),
                    script=self.s.res(ZONE), **props)

    def finish(self, z, width=20.0):
        self.s.node("Finish", "Zones", "Area3D", transform=transform(0, 0, z),
                    script=self.s.res(ZONE), kind="1", size=vec(width, 2, 4))

    # --- hazards ---

    def boulder_row(self, z, period, count=2, from_left=True):
        """Boulders rolling back and forth across the whole width."""
        period = self.t(period)
        reach = HALF_WIDTH - 0.5
        x = -reach if from_left else reach
        for i in range(count):
            self.s.node("Boulder", "Hazards", instance=BOULDER, transform=transform(x, 0, z),
                        time_offset=num(period * i / count),
                        line_offset=vec(2 * reach if from_left else -2 * reach, 0, 0),
                        line_period=num(period))

    def walker_circle(self, cx, cz, radius, period, count, clockwise=True, model=None, offset=0.0):
        period, offset = self.t(period), self.t(offset)
        for i in range(count):
            props = dict(transform=transform(cx, 0, cz), pattern="1",
                         time_offset=num(offset + period * i / count),
                         circle_radius=num(radius), circle_period=num(period),
                         clockwise=num(clockwise))
            if model:
                props["model_scene"] = self.s.res(model)
            self.s.node("Walker", "Hazards", instance=WALKER, **props)

    def walker_line(self, x, z, dx, dz, period, count=1, model=None, offset=0.0,
                    move_time=None, pause_time=None):
        """Walks there and back. With move/pause times it stops at each end."""
        period, offset = self.t(period), self.t(offset)
        move_time, pause_time = self.t(move_time), self.t(pause_time)
        for i in range(count):
            props = dict(transform=transform(x, 0, z), line_offset=vec(dx, 0, dz))
            if move_time is not None:
                cycle = 2 * (move_time + pause_time)
                props.update(pattern="3", move_time=num(move_time), pause_time=num(pause_time),
                             time_offset=num(offset + cycle * i / count))
            else:
                props.update(line_period=num(period), time_offset=num(offset + period * i / count))
            if model:
                props["model_scene"] = self.s.res(model)
            self.s.node("Walker", "Hazards", instance=WALKER, **props)

    def ram(self, z, move_time, pause_time, from_left=True, offset=0.0):
        """A boulder that slides across, stops, and slides back."""
        move_time, pause_time, offset = self.t(move_time), self.t(pause_time), self.t(offset)
        reach = HALF_WIDTH - 0.5
        self.s.node("Ram", "Hazards", instance=BOULDER,
                    transform=transform(-reach if from_left else reach, 0, z), pattern="3",
                    line_offset=vec(2 * reach if from_left else -2 * reach, 0, 0),
                    move_time=num(move_time), pause_time=num(pause_time), time_offset=num(offset))

    def spinner(self, x, z, arms, balls, period, clockwise=True, offset=0.0, ball_color=None, yaw=0.0):
        period, offset = self.t(period), self.t(offset)
        props = dict(transform=transform(x, 0, z, yaw), script=self.s.res(ARM), period=num(period),
                     arms=num(arms), balls=num(balls), clockwise=num(clockwise), time_offset=num(offset))
        if ball_color:
            props["ball_color"] = color(*ball_color)
        self.s.node("Spinner", "Hazards", "Node3D", **props)

    def pendulum(self, x, z, pointing_east, balls, period, swing=60.0, offset=0.0,
                 first_ball=0.8, ball_radius=None, ball_color=None, spacing=None):
        period, offset = self.t(period), self.t(offset)
        props = dict(transform=transform(x, 0, z, 90.0 if pointing_east else -90.0),
                     script=self.s.res(ARM), mode="1", period=num(period), swing_angle=num(swing),
                     balls=num(balls), first_ball=num(first_ball), time_offset=num(offset))
        if spacing:
            props["spacing"] = num(spacing)
        if ball_radius:
            props["ball_radius"] = num(ball_radius)
        if ball_color:
            props["ball_color"] = color(*ball_color)
        self.s.node("Pendulum", "Hazards", "Node3D", **props)

    def spikes(self, x, z, columns, rows, period, up_time, wave=0.0, offset=0.0):
        period, up_time, wave, offset = self.t(period), self.t(up_time), self.t(wave), self.t(offset)
        self.s.node("Spikes", "Hazards", "Node3D", transform=transform(x, 0, z),
                    script=self.s.res(SPIKES), columns=num(columns), rows=num(rows),
                    period=num(period), up_time=num(up_time), wave_delay=num(wave),
                    time_offset=num(offset))

    def full_width_spikes(self, z, period, up_time, wave=0.0, offset=0.0):
        self.spikes(0, z, 18, 1, period, up_time, wave, offset)

    def write(self, file_name):
        path = os.path.join(PROJECT, "levels", file_name)
        with open(path, "w", encoding="utf-8", newline="\n") as out:
            out.write(self.s.text())
        print("wrote", path)


# --- Settings ---------------------------------------------------------------


def sky_environment(level, top=None, horizon=None):
    s = level.s
    sky_props = ""
    if top:
        sky_props += f"\nsky_top_color = {color(*top)}"
    if horizon:
        sky_props += f"\nsky_horizon_color = {color(*horizon)}"
    s.sub(f'[sub_resource type="ProceduralSkyMaterial" id="SkyMaterial_1"]{sky_props}')
    s.sub('[sub_resource type="Sky" id="Sky_1"]\nsky_material = SubResource("SkyMaterial_1")')
    s.sub('[sub_resource type="Environment" id="Environment_1"]\nbackground_mode = 2\n'
          'sky = SubResource("Sky_1")\nambient_light_source = 3\ntonemap_mode = 2')
    s.node("WorldEnvironment", node_type="WorldEnvironment", environment='SubResource("Environment_1")')


SUN = "Transform3D(1, 0, 0, 0, 0.5736, 0.8192, 0, -0.8192, 0.5736, 0, 10, 0)"


class Forest(Level):
    TREE_HIGH = "res://assets/forest/tree-high.glb"
    TREE = "res://assets/forest/tree.glb"
    FENCE = "res://assets/forest/fence.glb"
    ROCKS = "res://assets/forest/rocks-low.glb"
    TENT = "res://assets/forest/tent.glb"
    FLAG = "res://assets/forest/flag.glb"

    def __init__(self, root_name, finish_z, key):
        super().__init__(root_name, finish_z, key)
        sky_environment(self)
        self.s.node("Sun", node_type="DirectionalLight3D", transform=SUN, shadow_enabled="true")
        length = 12 - finish_z
        center = (8 + finish_z - 4) / 2
        self.block("Ground", 0, -1, center, (80, 1, length + 40), color=color(0.35, 0.6, 0.3))
        for x, tree in [(-11.5, self.TREE_HIGH), (11.5, self.TREE)]:
            self.block("Trees", x, 0, center, (1, 1.5, length), show_box=False,
                       decoration=self.s.res(tree), decoration_spacing=1.9)
        self.block("Trees", 0, 0, 7.5, (22, 1.5, 1), show_box=False,
                   decoration=self.s.res(self.TREE), decoration_spacing=1.9)
        self.block("Trees", 0, 0, finish_z - 4.5, (22, 1.5, 1), show_box=False,
                   decoration=self.s.res(self.TREE_HIGH), decoration_spacing=1.9)

    def wall(self, z, gap, kind="fence"):
        """A wall across the path with one gap (x_from, x_to)."""
        for x0, x1 in [(-HALF_WIDTH, gap[0]), (gap[1], HALF_WIDTH)]:
            if x1 - x0 < 0.5:
                continue
            if kind == "fence":
                self.block("Fence", (x0 + x1) / 2, 0, z, (x1 - x0, 1.2, 0.8), show_box=False,
                           decoration=self.s.res(self.FENCE), decoration_scale=1.6,
                           decoration_spacing=1.75, random_turn=False)
            else:
                self.block("Rocks", (x0 + x1) / 2, 0, z, (x1 - x0, 1.2, 1.0), show_box=False,
                           decoration=self.s.res(self.ROCKS), decoration_scale=1.1,
                           decoration_spacing=1.1)

    def tent(self, x, z):
        self.block("Tent", x, 0, z, (1.6, 1.2, 1.4), show_box=False,
                   decoration=self.s.res(self.TENT), decoration_scale=1.3, random_turn=False)

    def flags(self, z):
        for x in [-10, 10]:
            self.s.node("Flag", "Decor", instance=self.FLAG, transform=transform(x, 0, z, scale=2.0))

    def checkpoint(self, z, width=20.0):
        super().checkpoint(z, width)
        self.flags(z)

    def finish(self, z, width=20.0):
        super().finish(z, width)
        for x in [-9, -4.5, 0, 4.5, 9]:
            self.s.node("Flag", "Decor", instance=self.FLAG, transform=transform(x, 0, z - 1.6, scale=2.0))


class City(Level):
    ROAD = "res://assets/roads/road-straight.glb"
    LIGHT = "res://assets/roads/light-square.glb"
    TREE = "res://assets/suburban/tree-large.glb"
    HOUSES = [f"res://assets/suburban/building-type-{c}.glb" for c in "abcfgkmp"]
    CARS = [f"res://assets/cars/{c}.glb" for c in
            ["sedan", "taxi", "van", "suv", "police", "truck", "delivery", "garbage-truck", "hatchback-sports"]]
    LANE = 2.5

    def __init__(self, root_name, finish_z, key, seed, sky_top=None, sky_horizon=None):
        super().__init__(root_name, finish_z, key)
        self.rng = random.Random(seed)
        sky_environment(self, sky_top, sky_horizon)
        self.s.node("Sun", node_type="DirectionalLight3D", transform=SUN, shadow_enabled="true")
        self.s.node("Roads", node_type="Node3D")
        self.s.node("Buildings", node_type="Node3D")
        self.s.node("Traffic", node_type="Node3D")
        length = 12 - finish_z
        center = (8 + finish_z - 4) / 2
        self.block("Pavement", 0, -1, center, (80, 1, length + 40), color=color(0.7, 0.7, 0.68))
        for x in [-11.5, 11.5]:
            self.invisible_wall(x, center, (1, 3, length))
        self.invisible_wall(0, 6.5, (24, 3, 1))
        self.invisible_wall(0, finish_z - 3.5, (24, 3, 1))
        self.houses_row(10, south=True)
        self.houses_row(finish_z - 7, south=False)
        self.house_index = 0

    def houses_row(self, z, south):
        self.block("Row", 0, 0, z, (24, 0.1, 4), parent="Buildings", show_box=False, solid=False,
                   decoration=self.s.res(self.rng.choice(self.HOUSES)), decoration_scale=4.0,
                   decoration_spacing=6.0, random_turn=False, decoration_turn=180.0 if south else 0.0)

    def sidewalk(self, z_from, z_to, light=True):
        """Houses on both sides of a stretch of sidewalk (z_from > z_to)."""
        center = (z_from + z_to) / 2
        length = z_from - z_to
        for x, turn in [(-13.5, 0.0), (13.5, 180.0)]:
            self.block("Houses", x, 0, center, (4, 0.1, length), parent="Buildings", show_box=False,
                       solid=False, decoration=self.s.res(self.HOUSES[self.house_index % len(self.HOUSES)]),
                       decoration_scale=4.0, decoration_spacing=6.0, random_turn=False,
                       decoration_turn=turn)
            self.house_index += 3
        if light and length >= 4:
            self.s.node("Light", "Decor", instance=self.LIGHT, transform=transform(-10.5, 0, center, scale=3.5))
            self.s.node("Light", "Decor", instance=self.LIGHT, transform=transform(10.5, 0, center, 180, 3.5))

    def lane(self, z, eastbound, cars, period=None, move_time=None, pause_time=None):
        """One lane of one-way traffic. Cars drive across and loop back."""
        self.block("Road", 0, 0.005, z, (44, 0.1, self.LANE), parent="Roads", show_box=False,
                   solid=False, decoration=self.s.res(self.ROAD), decoration_scale=self.LANE,
                   decoration_spacing=self.LANE, random_turn=False)
        reach = 18.0
        x = -reach if eastbound else reach
        dx = 2 * reach if eastbound else -2 * reach
        period, move_time, pause_time = self.t(period), self.t(move_time), self.t(pause_time)
        cars = min(4, cars + self.extra_cars)
        if move_time is not None:
            cycle = 2 * move_time + pause_time
        else:
            cycle = period
        start = self.rng.random() * cycle
        for i in range(cars):
            props = dict(transform=transform(x, 0, z), line_offset=vec(dx, 0, 0),
                         time_offset=num(start + cycle * i / cars))
            model = self.rng.choice(self.CARS)
            if not model.endswith("sedan.glb"):
                props["model_scene"] = self.s.res(model)
            if move_time is not None:
                props.update(pattern="3", move_time=num(move_time), pause_time=num(pause_time))
            else:
                props["line_period"] = num(period)
            self.s.node("Car", "Traffic", instance=CAR, **props)

    def lanes(self, z_first, count, specs):
        """count lanes going north from z_first. specs: list of (cars, period) or
        (cars, "stop", move, pause), used in turn."""
        z = z_first
        for i in range(count):
            spec = specs[i % len(specs)]
            eastbound = i % 2 == 0
            if len(spec) == 2:
                self.lane(z, eastbound, spec[0], period=spec[1])
            else:
                self.lane(z, eastbound, spec[0], move_time=spec[2], pause_time=spec[3])
            z -= self.LANE
        return z + self.LANE  # last lane's z

    def tree(self, x, z):
        self.block("Tree", x, 0, z, (0.6, 2, 0.6), show_box=False,
                   decoration=self.s.res(self.TREE), decoration_scale=3.0)


class Dungeon(Level):
    FLOOR = "res://assets/dungeon/floor.glb"
    WALL = "res://assets/dungeon/wall.glb"
    BARREL = "res://assets/dungeon/barrel.glb"
    CHEST = "res://assets/dungeon/chest.glb"

    def __init__(self, root_name, finish_z, key):
        super().__init__(root_name, finish_z, key)
        s = self.s
        s.sub('[sub_resource type="Environment" id="Environment_1"]\nbackground_mode = 1\n'
              f'background_color = {color(0.04, 0.035, 0.045)}\nambient_light_source = 2\n'
              f'ambient_light_color = {color(0.6, 0.55, 0.55)}\nambient_light_energy = 0.55\ntonemap_mode = 2')
        s.node("WorldEnvironment", node_type="WorldEnvironment", environment='SubResource("Environment_1")')
        s.node("Moonlight", node_type="DirectionalLight3D", transform=SUN,
               light_color=color(0.85, 0.85, 1.0), light_energy="0.45", shadow_enabled="true")
        s.node("Torches", node_type="Node3D")
        length = 12 - finish_z
        center = (8 + finish_z - 4) / 2
        # Tiles are drawn 1% bigger than their spacing so no gaps show between them.
        self.block("Floor", 0, -1, center, (26, 1, length + 4), color=color(0.16, 0.15, 0.16),
                   decoration=s.res(self.FLOOR), decoration_scale=2.02, decoration_spacing=2.0,
                   random_turn=False, decoration_height=1.005)
        for x in [-12, 12]:
            self.block("Wall", x, 0, center, (2, 2.2, length + 4), show_box=False,
                       decoration=s.res(self.WALL), decoration_spacing=2.0, random_turn=False)
        self.block("Wall", 0, 0, 7, (22, 2.2, 2), show_box=False, decoration=s.res(self.WALL),
                   decoration_spacing=2.0, random_turn=False)
        self.block("Wall", 0, 0, finish_z - 4.5, (22, 2.2, 2), show_box=False,
                   decoration=s.res(self.WALL), decoration_spacing=2.0, random_turn=False)
        z = 0.0
        side = -1
        while z > finish_z:
            s.node("Torch", "Torches", "OmniLight3D", transform=transform(10.3 * side, 2.5, z),
                   light_color=color(1, 0.6, 0.3), light_energy="2.5", omni_range="9.0")
            z -= 10
            side = -side

    def gate(self, z, gaps):
        """A wall across the hall with openings at the given (x_from, x_to) gaps."""
        edges = [-HALF_WIDTH]
        for g in sorted(gaps):
            edges += [g[0], g[1]]
        edges.append(HALF_WIDTH)
        for i in range(0, len(edges), 2):
            x0, x1 = edges[i], edges[i + 1]
            if x1 - x0 < 0.5:
                continue
            self.block("Gate", (x0 + x1) / 2, 0, z, (x1 - x0, 2.2, 2), show_box=False,
                       decoration=self.s.res(self.WALL), decoration_spacing=2.0, random_turn=False)

    def prop(self, model, x, z):
        self.s.node("Prop", "Decor", instance=model, transform=transform(x, 0, z, scale=1.4))


# --- Level 1: Forest Path -----------------------------------------------------


def forest_path():
    L = Forest("Level01", finish_z=-111.5, key="level_01")
    L.start(3)
    L.section(0)

    # A: eight rows of rolling boulders.
    for i, period in enumerate([3.0, 2.7, 3.3, 2.5, 2.9, 2.6, 3.1, 2.4]):
        L.boulder_row(-5.0 - 2.1 * i, period, count=3 if i % 3 == 2 else 2, from_left=i % 2 == 0)
    L.wall(-22, gap=(-11.0, -7.5))

    # B: archers circling, guards pacing along both edges and across, two tents for cover.
    L.walker_circle(-5, -27, 2.2, 3.0, 3)
    L.walker_circle(4, -29.5, 2.6, 3.6, 3, clockwise=False)
    L.walker_circle(-2, -34, 2.2, 2.8, 3)
    L.walker_circle(6, -35, 1.6, 2.4, 2)
    L.walker_line(-9.5, -24, 0, -13, 3.4, count=2)
    L.walker_line(9.5, -37, 0, 13, 3.0, count=2)
    L.walker_line(-10.2, -37.6, 20.4, 0, 0, count=2, move_time=1.1, pause_time=0.5)
    L.tent(1.5, -25)
    L.tent(8, -31.5)
    L.checkpoint(-40.5)
    L.section(1)

    # C: zigzag through rock walls, boulders between them, archers guarding gaps.
    walls = [(-44, (7.5, 11.0)), (-50, (-11.0, -7.5)), (-56, (7.5, 11.0)), (-62, (-11.0, -7.5))]
    for z, gap in walls:
        L.wall(z, gap, kind="rocks")
        L.walker_circle((gap[0] + gap[1]) / 2, z, 1.3, 2.0, 1)
    for i, (z, period) in enumerate([(-46, 2.2), (-48.2, 2.6), (-52, 2.0), (-54.2, 2.4), (-58, 2.4), (-60.2, 2.1)]):
        L.boulder_row(z, period, count=2, from_left=i % 2 == 0)
    L.checkpoint(-66.5)
    L.section(2)

    # D: boulder rows with archers marching across between them.
    for i, (z, period, count) in enumerate([(-70.5, 2.2, 2), (-76, 2.0, 3), (-81.5, 2.4, 2), (-87, 2.1, 3)]):
        L.boulder_row(z, period, count, from_left=i % 2 == 1)
    L.walker_line(-10.2, -73.2, 20.4, 0, 3.0, count=2)
    L.walker_line(10.2, -78.7, -20.4, 0, 0, count=2, move_time=1.0, pause_time=0.6)
    L.walker_line(-10.2, -84.2, 20.4, 0, 2.6, count=2)
    L.checkpoint(-95)
    L.section(3)

    # E: a ring of archers between two fast boulder rows.
    L.boulder_row(-99, 1.9, 2)
    L.boulder_row(-101, 2.3, 2, from_left=False)
    L.boulder_row(-105.4, 2.1, 2)
    L.walker_circle(0, -103.2, 3.0, 2.6, 4)
    L.walker_circle(-7, -103.2, 1.6, 2.0, 2, clockwise=False)
    L.walker_circle(7, -103.2, 1.6, 2.0, 2, clockwise=False)
    L.boulder_row(-107.3, 2.0, 2, from_left=False)
    L.finish(-111.5)
    L.write("level_01.tscn")


# --- Level 2: City Crossing ----------------------------------------------------


def city_crossing():
    L = City("Level02", finish_z=-89, key="level_02", seed=2)
    L.extra_cars = 1
    L.start(3)
    L.section(0)
    L.sidewalk(7, -3)
    normal = [(2, 3.4), (3, 3.6), (2, 3.0), (2, "stop", 1.3, 1.1), (3, 3.8), (2, 2.8)]
    L.lanes(-4.25, 6, normal)
    L.sidewalk(-18, -23)
    L.checkpoint(-20.5)
    L.section(1)
    L.tree(-6, -20.5)
    L.tree(6, -20.5)
    harder = [(3, 3.2), (2, 2.6), (2, "stop", 1.1, 1.0), (3, 3.4), (2, 2.4), (3, 3.0), (2, "stop", 1.0, 0.9)]
    L.lanes(-24.25, 7, harder)
    L.sidewalk(-40.5, -45.5)
    L.checkpoint(-43)
    L.section(2)
    hardest = [(3, 2.8), (2, 2.2), (3, 3.0), (2, "stop", 0.9, 0.8), (3, 2.6), (2, 2.0), (3, 2.9)]
    L.lanes(-46.75, 7, hardest)
    L.sidewalk(-63, -68)
    L.checkpoint(-65.5)
    L.section(3)
    L.tree(-6, -65.5)
    L.tree(6, -65.5)
    final = [(3, 2.6), (3, "stop", 0.9, 0.7), (2, 2.0), (3, 2.7), (2, 1.9), (3, 2.5), (3, 2.8)]
    L.lanes(-69.25, 7, final)
    L.sidewalk(-85.5, -93, light=False)
    L.finish(-89)
    L.write("level_02.tscn")


# --- Level 3: Dungeon Halls ------------------------------------------------------


def dungeon_halls():
    L = Dungeon("Level03", finish_z=-104.5, key="level_03")
    L.start(3)
    L.section(0)

    # A: four rows of spikes rising in waves, then orcs pacing across.
    L.full_width_spikes(-5.0, 2.6, 1.2, wave=0.12)
    L.full_width_spikes(-7.0, 2.6, 1.2, wave=-0.12, offset=1.3)
    L.full_width_spikes(-9.0, 2.2, 1.0, wave=0.15, offset=0.6)
    L.full_width_spikes(-11.0, 2.4, 1.1, wave=-0.1, offset=1.8)
    L.full_width_spikes(-13.0, 2.0, 0.9, wave=0.2, offset=0.9)
    L.walker_line(-10.2, -15.4, 20.4, 0, 3.0, count=3, model=ORC)
    L.walker_line(10.2, -17.6, -20.4, 0, 2.6, count=3, model=ORC)
    L.gate(-20, [(-1.5, 1.5)])
    L.checkpoint(-23.5, width=12)
    L.section(1)

    # B: six spinners in two overlapping columns, orcs circling between them,
    # then orcs guarding the next gate.
    for row, z in enumerate([-30.2, -35.4, -40.6]):
        L.spinner(-5.5, z, 2 + row % 2, 6, 3.2 + 0.4 * row, clockwise=row % 2 == 0, offset=0.6 * row)
        L.spinner(5.5, z - 1.2, 3 - row % 2, 6, 3.6 - 0.3 * row, clockwise=row % 2 == 1, offset=0.3 + 0.5 * row)
    L.walker_circle(0, -33, 1.4, 2.4, 2, model=ORC)
    L.walker_circle(0, -38.4, 1.4, 2.2, 2, clockwise=False, model=ORC)
    L.walker_line(-10.2, -43.4, 20.4, 0, 2.8, count=3, model=ORC)
    L.gate(-46, [(-11.0, -8.0), (8.0, 11.0)])
    L.checkpoint(-49.5, width=12)
    L.section(2)

    # C: eight pendulums swinging from both walls, spikes down the middle.
    for i in range(8):
        z = -54.5 - 2.6 * i
        L.pendulum(-10.6 if i % 2 == 0 else 10.6, z, i % 2 == 0, 11, 2.8, swing=55, offset=0.37 * i)
    L.spikes(0, -63.6, 4, 16, 2.2, 1.0, wave=0.25)
    L.checkpoint(-79.5, width=12)
    L.section(3)

    # D: a four-armed spinner crossed by sliding boulders, small spinners and two last spike waves.
    L.spinner(0, -90, 4, 8, 5.0, clockwise=False)
    L.ram(-84, 0.8, 0.9)
    L.ram(-87.5, 0.7, 1.0, from_left=False, offset=0.4)
    L.ram(-92.5, 0.7, 1.0, offset=1.2)
    L.ram(-95.5, 0.8, 0.9, from_left=False, offset=0.85)
    L.spinner(-8.3, -97.8, 2, 3, 2.4)
    L.spinner(8.3, -97.8, 2, 3, 2.4, clockwise=False)
    L.spinner(-8.0, -86.5, 2, 4, 2.2, clockwise=False)
    L.spinner(8.0, -86.5, 2, 4, 2.2)
    L.full_width_spikes(-100.4, 2.4, 1.1, wave=0.1)
    L.full_width_spikes(-101.8, 2.4, 1.1, wave=-0.1, offset=1.2)
    L.finish(-104.5, width=12)

    L.prop(Dungeon.BARREL, -10, -23)
    L.prop(Dungeon.BARREL, 10, -50)
    L.prop(Dungeon.CHEST, 0, -107)
    L.write("level_03.tscn")


# --- Level 4: Rush Hour ------------------------------------------------------------


def rush_hour():
    L = City("Level04", finish_z=-108, key="level_04", seed=4, sky_top=(0.45, 0.5, 0.75), sky_horizon=(0.85, 0.7, 0.6))
    L.extra_cars = 1
    L.start(3)
    L.section(0)
    L.sidewalk(7, -3)
    fast = [(3, 2.6), (2, "stop", 0.9, 0.8), (3, 2.4), (2, 2.0), (3, 2.8), (2, "stop", 0.8, 0.7), (3, 2.5)]
    L.lanes(-4.25, 7, fast)
    L.sidewalk(-20.5, -47)
    L.checkpoint(-23)
    L.section(1)

    # Construction zone: six spinners in two columns that overlap in the middle,
    # and two wrecking-ball chains that sweep from the walls to the middle.
    orange = (0.95, 0.55, 0.1)
    steel = (0.3, 0.3, 0.32)
    for row, z in enumerate([-29.6, -34.0, -38.4]):
        L.spinner(-5.0, z, 2 + row % 2, 6, 3.0 + 0.4 * row, clockwise=row % 2 == 0, offset=0.5 * row,
                  ball_color=orange)
        L.spinner(5.0, z - 0.6, 3 - row % 2, 6, 3.4 - 0.3 * row, clockwise=row % 2 == 1, offset=0.2 + 0.6 * row,
                  ball_color=orange)
    L.pendulum(-10.6, -33, True, 3, 2.6, swing=50, first_ball=3.5, spacing=3.25, ball_radius=0.6, ball_color=steel)
    L.pendulum(10.6, -35.8, False, 3, 2.6, swing=50, first_ball=3.5, spacing=3.25, ball_radius=0.6,
               ball_color=steel, offset=1.3)
    L.checkpoint(-45.5)
    L.section(2)

    faster = [(3, 2.4), (2, 1.9), (3, "stop", 0.8, 0.6), (3, 2.6), (2, 2.0), (3, 2.3), (2, "stop", 0.8, 0.6),
              (3, 2.5), (2, 1.8)]
    L.lanes(-49.25, 9, faster)
    L.sidewalk(-70.5, -75.5)
    L.checkpoint(-73)
    L.section(3)

    final = [(3, 2.3), (2, 1.9), (3, 2.5), (2, "stop", 0.8, 0.6)]
    L.lanes(-76.75, 4, final)
    L.sidewalk(-85.5, -95, light=False)
    L.pendulum(10.6, -88, False, 1, 2.4, swing=55, first_ball=7.0, ball_radius=0.6, ball_color=(0.3, 0.3, 0.32))
    L.pendulum(-10.6, -92.5, True, 1, 2.4, swing=55, first_ball=7.0, ball_radius=0.6,
               ball_color=(0.3, 0.3, 0.32), offset=1.2)
    L.spinner(0, -90.2, 2, 4, 2.8, ball_color=orange)
    L.lanes(-96.25, 4, [(2, 2.0), (3, 2.4), (2, "stop", 0.8, 0.6), (3, 2.2)])
    L.sidewalk(-105.5, -112, light=False)
    L.finish(-108)
    L.write("level_04.tscn")


if __name__ == "__main__":
    forest_path()
    city_crossing()
    dungeon_halls()
    rush_hour()
