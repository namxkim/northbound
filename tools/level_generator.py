"""Writes every level scene: levels/w1_l1.tscn (level 1-1) to w7_l5.tscn (7-5).

The game has 7 worlds of 5 levels. Each world has its own look and enemy
models. Each level is a recipe: a list of 12 to 16 section types (rolling
hazards, traffic, circling walkers, swarms of wanderers...), with a checkpoint
after every second section. Levels get busier from x-1 to x-5 and from world
to world.

Running this script OVERWRITES all those level files, so any changes made to
them in the Godot editor are lost. Tweak the recipes here instead.

Hazard speeds come from tools/level_dials.json, which tools/tune_levels.py
fills in so every section stays beatable.

Run from the project folder:  uv run --no-project tools/level_generator.py
"""

import json
import math
import os
import random

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIALS_FILE = os.path.join(PROJECT, "tools", "level_dials.json")

# Speed dial for each section of each level, by level key ("w1_l1").
DIALS = {}
if os.path.exists(DIALS_FILE):
    with open(DIALS_FILE, encoding="utf-8") as dials_in:
        DIALS = json.load(dials_in)

# Play area is x from -11 to 11. North is -z.
HALF_WIDTH = 11.0

# Edge gullies: along both side walls of most sections, hazards roll south in
# two lanes, so players can't just hug a wall to the finish. The lanes
# (rollers 0.36 m wide on each side of these x values) leave no gap a player
# (0.21 m radius) fits in from 8.94 m out to the wall.
GULLY_LANES = [9.3, 10.4]
# Solid outcrops at both ends of every section, from this x out to the wall.
# They hide where gully hazards appear and vanish, and push wall-huggers out.
GATE_FROM = 8.6
# Sections whose own layout already stops wall-hugging (or would clash with gullies).
NO_GULLY = {"zigzag"}


def num(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    text = f"{value:.4f}".rstrip("0")
    return text + "0" if text.endswith(".") else text


def vec(x, y, z):
    return f"Vector3({num(float(x))}, {num(float(y))}, {num(float(z))})"


def vec2(x, y):
    return f"Vector2({num(float(x))}, {num(float(y))})"


def color(r, g, b, a=1.0):
    return f"Color({num(float(r))}, {num(float(g))}, {num(float(b))}, {num(float(a))})"


def transform(x, y, z, yaw=0.0, scale=1.0):
    c = math.cos(math.radians(yaw)) * scale
    s = math.sin(math.radians(yaw)) * scale
    values = [c, 0.0, s, 0.0, scale, 0.0, -s, 0.0, c, x, y, z]
    return "Transform3D(" + ", ".join(num(float(v)) for v in values) + ")"


def fmt(value):
    return num(value) if isinstance(value, (bool, int, float)) else value


class Scene:
    def __init__(self):
        self.resources = []
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

    def node(self, name, parent=".", node_type=None, instance=None, **props):
        key = (parent, name)
        self.names[key] = self.names.get(key, 0) + 1
        if self.names[key] > 1:
            name = f"{name}{self.names[key]}"
        header = f'[node name="{name}"'
        if node_type:
            header += f' type="{node_type}"'
        if parent is not None:
            header += f' parent="{parent}"'
        if instance:
            header += f" instance={self.res(instance)}"
        lines = [header + "]"] + [f"{k} = {fmt(v)}" for k, v in props.items()]
        self.nodes.append("\n".join(lines))
        return name if parent in (None, ".") else f"{parent}/{name}"

    def text(self):
        parts = ["[gd_scene format=3]", ""]
        for kind, path, rid in self.resources:
            parts.append(f'[ext_resource type="{kind}" path="{path}" id="{rid}"]')
        parts.append("")
        for block in self.sub_resources + self.nodes:
            parts += [block, ""]
        return "\n".join(parts)


BLOCK = "res://scripts/block.gd"
ZONE = "res://scripts/zone.gd"
ARM = "res://scripts/hazard_arm.gd"
SPIKES = "res://scripts/spike_field.gd"
WALKER = "res://scenes/enemy.tscn"
BOULDER = "res://scenes/boulder.tscn"
CAR = "res://scenes/car.tscn"
SUN = "Transform3D(1, 0, 0, 0, 0.5736, 0.8192, 0, -0.8192, 0.5736, 0, 10, 0)"


def A(pack, name):
    return f"res://assets/{pack}/{name}.glb"


# --- The level being built ------------------------------------------------------


class Level:
    def __init__(self, world, number, recipe):
        self.world = world
        self.number = number
        self.key = f"w{world.index}_l{number}"
        self.rng = random.Random(world.index * 100 + number)
        # How busy the level is: 0.85 for 1-1, up to 1.41 for 7-5.
        self.intensity = 0.85 + 0.08 * (number - 1) + 0.04 * (world.index - 1)
        self.recipe = recipe
        self.speed = 1.0
        self.s = Scene()
        self.s.node(f"W{world.index}L{number}", parent=None, node_type="Node3D",
                    script=self.s.res("res://scripts/level.gd"))
        for group in ["Terrain", "Hazards", "Zones", "Decor"]:
            self.s.node(group, node_type="Node3D")
        self.walls = []  # (z_from, z_to) stretches with something built across them
        self.lanes = []  # z of every traffic lane
        self.seed_counter = 0

    # --- timing ---

    def section(self, index):
        """Starts section `index`. Sections come in pairs between checkpoints, and
        each pair (one checkpoint-to-checkpoint stretch) shares a speed dial."""
        dials = DIALS.get(self.key, [])
        stretch = index // 2
        self.speed = dials[stretch] if stretch < len(dials) else 1.0

    def t(self, seconds):
        return None if seconds is None else seconds / self.speed

    def uniform(self, low, high):
        return self.rng.uniform(low, high)

    # --- basic pieces ---

    def block(self, name, x, y, z, size, parent="Terrain", **props):
        return self.s.node(name, parent, "StaticBody3D", transform=transform(x, y, z),
                           script=self.s.res(BLOCK), size=vec(*size), **props)

    def decorated(self, name, x, z, size, model, scale, spacing, solid=True, turn=0.0, random_turn=False,
                  parent="Terrain", height=0.0):
        props = dict(show_box=False, decoration=self.s.res(model), decoration_scale=scale,
                     decoration_spacing=spacing, random_turn=random_turn)
        if not solid:
            props["solid"] = False
        if turn:
            props["decoration_turn"] = turn
        if height:
            props["decoration_height"] = height
        return self.block(name, x, 0, z, size, parent=parent, **props)

    def checkpoint(self, z):
        self.s.node("Checkpoint", "Zones", "Area3D", transform=transform(0, 0, z),
                    script=self.s.res(ZONE), size=vec(14, 2, 3))

    def finish(self, z):
        self.s.node("Finish", "Zones", "Area3D", transform=transform(0, 0, z),
                    script=self.s.res(ZONE), kind=1, size=vec(20, 2, 4))

    # --- hazards ---

    def roller(self, x, z, dx, period, offset=0.0, pattern=None, move=None, pause=None, one_way=False, dz=0.0):
        skin = self.world.roller
        props = dict(transform=transform(x, 0, z), line_offset=vec(dx, 0, dz), time_offset=self.t(offset))
        if pattern == "stop":
            props.update(pattern=3, move_time=self.t(move), pause_time=self.t(pause))
        else:
            props["line_period"] = self.t(period)
        if one_way:
            props["one_way"] = True
        if skin.get("model"):
            props["model_scene"] = self.s.res(skin["model"])
            props["model_scale"] = skin["scale"]
        path = self.s.node("Roller", "Hazards", instance=BOULDER, **props)
        if skin.get("model"):
            self.s.node("Rock", f"{path}/Model", visible=False)
        elif skin.get("color"):
            self.s.node("Rock", f"{path}/Model", color=color(*skin["color"]))

    def walker(self, x, z, model=None, scale=1.3, hit=None, **props):
        props = {k: fmt(v) for k, v in props.items()}
        if model:
            props["model_scene"] = self.s.res(model)
            props["model_scale"] = scale
        if hit:
            props["hit_radius"] = hit
        self.s.node("Walker", "Hazards", instance=WALKER, transform=transform(x, 0, z), **props)

    def walker_circle(self, cx, cz, radius, period, count, clockwise=True):
        period = self.t(period)
        skin = self.world.walker
        for i in range(count):
            self.walker(cx, cz, skin["model"], skin["scale"], skin.get("hit"), pattern=1,
                        time_offset=period * i / count, circle_radius=radius,
                        circle_period=period, clockwise=clockwise)

    def walker_line(self, x, z, dx, dz, period, count, stop=None):
        skin = self.world.walker
        for i in range(count):
            props = dict(line_offset=vec(dx, 0, dz))
            if stop:
                move, pause = self.t(stop[0]), self.t(stop[1])
                props.update(pattern=3, move_time=move, pause_time=pause,
                             time_offset=2 * (move + pause) * i / count)
            else:
                p = self.t(period)
                props.update(line_period=p, time_offset=p * i / count)
            self.walker(x, z, skin["model"], skin["scale"], skin.get("hit"), **props)

    def roamers(self, count, z_top, z_bottom, hop=4.5):
        """Wanderers that roam the whole section: the full width of the map and
        all but a meter at each end. Each starts at its own random spot in it."""
        for _ in range(count):
            self.wanderer(0.0, (z_top + z_bottom) / 2, 2 * HALF_WIDTH - 1.6, (z_top - z_bottom) - 2.0, hop)

    def wanderer(self, x, z, area_x, area_z, hop=3.5):
        """An enemy hopping around randomly inside an area centered on (x, z)."""
        skin = self.world.wanderer
        self.seed_counter += 1
        # Each wanderer has its own pace: slow drifters, normal walkers and fast runners.
        pace = self.rng.random()
        if pace < 0.3:
            step, hop_scale = self.uniform(1.4, 2.0), 0.8  # About 2 m/s.
        elif pace < 0.75:
            step, hop_scale = self.uniform(0.8, 1.2), 1.0  # About 3 m/s.
        else:
            step, hop_scale = self.uniform(0.45, 0.65), 1.0  # About 5-6 m/s.
        self.walker(x, z, skin["model"], skin["scale"], skin.get("hit"), pattern=4,
                    wander_area=vec2(area_x, area_z), wander_step=self.t(step),
                    wander_variation=0.7, wander_hop=hop * hop_scale, wander_pause_chance=self.uniform(0.1, 0.3),
                    wander_seed=self.world.index * 10000 + self.number * 1000 + self.seed_counter)

    def arm(self, x, z, yaw=0.0, **props):
        props = {k: fmt(v) for k, v in props.items()}
        self.s.node("Arm", "Hazards", "Node3D", transform=transform(x, 0, z, yaw), script=self.s.res(ARM),
                    ball_color=color(*self.world.arm_color), **props)

    def spinner(self, x, z, arms, balls, period, clockwise=True, offset=0.0):
        self.arm(x, z, period=self.t(period), arms=arms, balls=balls, clockwise=clockwise,
                 time_offset=self.t(offset))

    def pendulum(self, from_west, z, balls, period, swing=55.0, offset=0.0, first_ball=0.8, spacing=None,
                 radius=None):
        # The post sits in the side wall (out of the edge gully). The first ball
        # is moved out by the same amount, so the balls are where they were.
        tuck = 0.6
        props = dict(mode=1, period=self.t(period), swing_angle=swing, balls=balls, first_ball=first_ball + tuck,
                     time_offset=self.t(offset))
        if spacing:
            props["spacing"] = spacing
        if radius:
            props["ball_radius"] = radius
        pivot = 10.6 + tuck
        self.arm(-pivot if from_west else pivot, z, 90.0 if from_west else -90.0, **props)

    def spike_row(self, z, columns, rows, period, up_time, wave=0.0, offset=0.0, x=0.0):
        self.s.node("Spikes", "Hazards", "Node3D", transform=transform(x, 0, z), script=self.s.res(SPIKES),
                    columns=columns, rows=rows, period=self.t(period), up_time=self.t(up_time),
                    wave_delay=self.t(wave), time_offset=self.t(offset))

    def vehicle_lane(self, z, eastbound, cars, period=None, move=None, pause=None):
        """One lane of one-way traffic. Vehicles cross and loop back."""
        self.lanes.append(z)
        self.world.lane_surface(self, z)
        reach = 18.0
        x = -reach if eastbound else reach
        dx = 2 * reach if eastbound else -2 * reach
        period, move, pause = self.t(period), self.t(move), self.t(pause)
        cycle = 2 * move + pause if move is not None else period
        start = self.rng.random() * cycle
        for i in range(cars):
            offset = start + cycle * i / cars
            if self.world.vehicle_rolls:
                self.roller(x, z, dx, None if move else period * self.speed, offset * self.speed,
                            pattern="stop" if move else None,
                            move=move * self.speed if move else None,
                            pause=pause * self.speed if move else None, one_way=True)
                continue
            props = dict(transform=transform(x, 0, z), line_offset=vec(dx, 0, 0), time_offset=offset)
            props["model_scene"] = self.s.res(self.rng.choice(self.world.vehicles))
            props["model_scale"] = self.world.vehicle_scale
            if move is not None:
                props.update(pattern=3, move_time=move, pause_time=pause)
            else:
                props["line_period"] = period
            self.s.node("Vehicle", "Hazards", instance=CAR, **props)

    def obstacle(self, x, z):
        model, scale, size = self.rng.choice(self.world.obstacles)
        self.decorated("Cover", x, z, size, model, scale, 10.0, random_turn=True)

    def gully(self, z_south, z_north):
        """Hazards rolling south down both edges, from the outcrop at z_north to the
        one at z_south, then starting again. Two lanes per side, staggered, so a
        player hugging a wall keeps meeting them head-on."""
        i = self.intensity
        length = z_south - z_north
        speed = 3.4 + 1.2 * (i - 0.85) / 0.56  # 3.4 m/s in 1-1, up to 4.6 m/s in 7-5.
        spacing = 5.0 - 1.0 * (i - 0.85) / 0.56  # 5 m apart in 1-1, down to 4 m in 7-5.
        count = max(2, round(length / spacing))
        period = length / speed
        for side in (-1, 1):
            for lane, x in enumerate(GULLY_LANES):
                # Each lane and side gets its own phase, so the gaps never line up.
                phase = (0.5 * lane + 0.25 * (side > 0) + 0.13 * len(self.walls)) % 1.0
                for c in range(count):
                    self.roller(side * x, z_north, 0, period, period * ((c + phase) / count) % period,
                                one_way=True, dz=length)

    def gate(self, z):
        """Solid outcrops sticking out from both side walls at z."""
        width = HALF_WIDTH - GATE_FROM
        for side in (-1, 1):
            self.world.wall(self, side * (GATE_FROM + width / 2), z, width)

    # --- sections: each fills the stretch going north from z_top and returns where it ends ---

    def rollers(self, z_top):
        i = self.intensity
        rows = round(3 + 4 * i)
        for r in range(rows):
            z = z_top - 1.3 - 2.2 * r
            count = 3 if (i > 0.8 and r % 3 == 2) else 2
            period = self.uniform(2.4, 3.4)
            from_left = r % 2 == 0
            reach = HALF_WIDTH - 0.5
            for c in range(count):
                self.roller(-reach if from_left else reach, z, 2 * reach if from_left else -2 * reach,
                            period, period * c / count)
        return z_top - 1.3 - 2.2 * (rows - 1) - 1.3

    def traffic(self, z_top):
        i = self.intensity
        lanes = round(3 + 4 * i)
        for n in range(lanes):
            z = z_top - 1.5 - 2.5 * n
            if self.rng.random() < 0.25:
                cars = 2 if i < 0.9 else 3
                self.vehicle_lane(z, n % 2 == 0, cars, move=self.uniform(0.9, 1.3), pause=self.uniform(0.7, 1.1))
            else:
                cars = 3 if self.rng.random() < i - 0.45 else 2
                self.vehicle_lane(z, n % 2 == 0, cars, period=self.uniform(2.6, 3.8))
        return z_top - 1.5 - 2.5 * (lanes - 1) - 1.5

    def circles(self, z_top):
        i = self.intensity
        length = 14 + 4 * i
        z_bottom = z_top - length
        clusters = round(2 + 3 * i)
        spots = []
        for c in range(clusters):
            for _ in range(30):
                radius = self.uniform(1.4, 2.4)
                x = self.uniform(-8.0 + radius, 8.0 - radius)
                z = self.uniform(z_bottom + radius + 0.8, z_top - radius - 0.8)
                if all(math.hypot(x - sx, z - sz) > radius + sr + 0.6 for sx, sz, sr in spots):
                    spots.append((x, z, radius))
                    self.walker_circle(x, z, radius, self.uniform(2.4, 3.6), 2 if self.rng.random() < 0.5 else 3,
                                       clockwise=self.rng.random() < 0.5)
                    break
        if i > 0.7:
            self.walker_line(-9.8, z_top - 1.0, 0, -(length - 2), self.uniform(3.0, 3.8), 2)
            self.walker_line(9.8, z_bottom + 1.0, 0, length - 2, self.uniform(3.0, 3.8), 2)
        self.roamers(round(4 + 4 * i), z_top, z_bottom)
        for _ in range(2):
            self.obstacle(self.uniform(-7.5, 7.5), self.uniform(z_bottom + 2, z_top - 2))
        return z_bottom

    def patrols(self, z_top):
        i = self.intensity
        rows = round(3 + 3 * i)
        for r in range(rows):
            z = z_top - 1.5 - 2.6 * r
            from_left = r % 2 == 0
            x, dx = (-10.2, 20.4) if from_left else (10.2, -20.4)
            count = 3 if i > 1.0 else 2
            if self.rng.random() < 0.3:
                self.walker_line(x, z, dx, 0, None, count, stop=(self.uniform(0.9, 1.3), self.uniform(0.4, 0.8)))
            else:
                self.walker_line(x, z, dx, 0, self.uniform(2.6, 3.6), count)
        z_bottom = z_top - 1.5 - 2.6 * (rows - 1) - 1.5
        self.roamers(round(4 + 4 * i), z_top, z_bottom)
        return z_bottom

    def zigzag(self, z_top):
        i = self.intensity
        walls = 3 + round(i * 2)
        rows = 2 if i > 0.8 else 1
        # Two rows need more room: 2.6 m apart leaves a safe strip to stand in between them.
        spacing = 7.4 if rows == 2 else 5.5
        for w in range(walls):
            z = z_top - 2.0 - spacing * w
            # The gap is 4 m wide but stops 2.4 m short of the side wall, so the
            # way through is never along the wall itself.
            gap = (4.6, 8.6) if w % 2 == 0 else (-8.6, -4.6)
            for solid in [(-HALF_WIDTH, gap[0]), (gap[1], HALF_WIDTH)]:
                self.world.wall(self, (solid[0] + solid[1]) / 2, z, solid[1] - solid[0])
            self.walker_circle((gap[0] + gap[1]) / 2, z, 1.3, 2.0, 1)
            if w < walls - 1:
                for r in range(rows):
                    zr = z - spacing / 2 + (r - (rows - 1) / 2) * 2.6
                    period = self.uniform(2.0, 2.8)
                    reach = HALF_WIDTH - 0.5
                    for c in range(2):
                        self.roller(-reach if r % 2 == 0 else reach, zr, 2 * reach if r % 2 == 0 else -2 * reach,
                                    period, period * c / 2)
        return z_top - 2.0 - spacing * (walls - 1) - 2.5

    def wanderers(self, z_top):
        i = self.intensity
        length = 20.0
        z_bottom = z_top - length
        self.roamers(round(14 + 16 * i), z_top, z_bottom)
        for _ in range(3):
            self.obstacle(self.uniform(-7.5, 7.5), self.uniform(z_bottom + 2.5, z_top - 2.5))
        return z_bottom

    def swarm(self, z_top):
        """A big field packed with wanderers roaming wide areas."""
        i = self.intensity
        length = 24.0
        z_bottom = z_top - length
        self.roamers(round(22 + 20 * i), z_top, z_bottom, hop=5.0)
        for _ in range(4):
            self.obstacle(self.uniform(-7.5, 7.5), self.uniform(z_bottom + 3.0, z_top - 3.0))
        return z_bottom

    def spinners(self, z_top):
        i = self.intensity
        rows = round(2 + 1.5 * i)
        for r in range(rows):
            z = z_top - 5.2 - 5.2 * r
            # Side spinners sit close enough to the middle that their arms sweep
            # across it, so there's no straight lane down the center.
            self.spinner(-4.4, z, 2 + r % 2, 6, self.uniform(3.0, 4.2), clockwise=r % 2 == 0, offset=0.6 * r)
            self.spinner(4.4, z - 1.2, 3 - r % 2, 6, self.uniform(3.0, 4.2), clockwise=r % 2 == 1, offset=0.3 + 0.5 * r)
            if r < rows - 1:
                # A small spinner in the middle between rows.
                self.spinner(0.0, z - 3.2, 2, 3, 2.6 + 0.3 * r, clockwise=r % 2 == 1, offset=0.9 * r)
        return z_top - 5.2 - 5.2 * (rows - 1) - 1.2 - 5.2

    def pendulums(self, z_top):
        i = self.intensity
        count = round(4 + 4 * i)
        first = z_top - 7.4
        for p in range(count):
            self.pendulum(p % 2 == 0, first - 2.6 * p, 11, self.uniform(2.6, 3.2), offset=0.37 * p)
        last = first - 2.6 * (count - 1)
        middle = (first + last) / 2
        if self.world.spike_traps:
            self.spike_row(middle, 4, round((first - last) / 1.2) + 1, 2.2, 1.0, wave=0.25)
        else:
            for _ in range(2 + round(i)):
                self.wanderer(self.uniform(-1.0, 1.0), self.uniform(last + 1, first - 1), 2.5, first - last - 2)
            # The pendulums' tips stop 2 m short of the middle, so small spinners
            # guard the center lane too.
            for n in range(round((first - last) / 5.2) + 1):
                self.spinner(0.0, first - 1.3 - 5.2 * n, 2, 2, 2.4 + 0.2 * n, clockwise=n % 2 == 0, offset=0.7 * n)
        return last - 7.4

    def spikes(self, z_top):
        i = self.intensity
        rows = round(3 + 3 * i)
        for r in range(rows):
            self.spike_row(z_top - 1.5 - 2.0 * r, 18, 1, self.uniform(2.0, 2.6), self.uniform(0.9, 1.2),
                           wave=self.uniform(0.1, 0.25) * (1 if r % 2 == 0 else -1), offset=self.uniform(0, 2))
        z = z_top - 1.5 - 2.0 * (rows - 1) - 2.6
        self.walker_line(-10.2, z, 20.4, 0, self.uniform(2.6, 3.2), 2 if i < 1 else 3)
        self.walker_line(10.2, z - 2.4, -20.4, 0, self.uniform(2.6, 3.2), 2 if i < 1 else 3)
        return z - 2.4 - 1.5

    def rams(self, z_top):
        i = self.intensity
        rows = round(3 + 3 * i)
        reach = HALF_WIDTH - 0.5
        for r in range(rows):
            z = z_top - 1.5 - 2.6 * r
            from_left = r % 2 == 0
            self.roller(-reach if from_left else reach, z, 2 * reach if from_left else -2 * reach, None,
                        self.uniform(0, 1.5), pattern="stop", move=self.uniform(0.7, 0.9), pause=self.uniform(0.8, 1.1))
        if i > 0.8:
            mid = z_top - 1.5 - 2.6 * (rows - 1) / 2
            self.spinner(0, mid, 2, 3, 2.6)
        return z_top - 1.5 - 2.6 * (rows - 1) - 1.5

    def construction(self, z_top):
        i = self.intensity
        rows = round(2 + i)
        for r in range(rows):
            z = z_top - 5.0 - 4.4 * r
            # Close enough to the middle that their arms sweep across it.
            self.spinner(-4.2, z, 2 + r % 2, 6, self.uniform(2.9, 3.8), clockwise=r % 2 == 0, offset=0.5 * r)
            self.spinner(4.2, z - 0.6, 3 - r % 2, 6, self.uniform(2.9, 3.8), clockwise=r % 2 == 1, offset=0.2 + 0.6 * r)
        last = z_top - 5.0 - 4.4 * (rows - 1) - 0.6
        middle = (z_top + last - 5.0) / 2
        self.pendulum(True, middle + 1.4, 3, 2.6, swing=45, first_ball=3.5, spacing=3.25, radius=0.6)
        self.pendulum(False, middle - 1.4, 3, 2.6, swing=45, first_ball=3.5, spacing=3.25, radius=0.6, offset=1.3)
        return last - 5.0

    # --- putting it together ---

    def build(self):
        self.s.node("Start", node_type="Marker3D", transform=transform(0, 0, 3))
        z = 0.5
        for n, section_name in enumerate(self.recipe):
            self.section(n)
            z_bottom = getattr(self, section_name)(z)
            # Outcrops 1 m beyond each end of the section (in the 2 m gap between
            # sections, or either side of a checkpoint), and edge gullies between them.
            if n % 2 == 0:
                self.gate(z + 1.0)
            self.gate(z_bottom - 1.0)
            if section_name not in NO_GULLY:
                self.gully(z + 1.0, z_bottom - 1.0)
            self.walls.append((z, z_bottom, section_name))
            if n == len(self.recipe) - 1:
                self.finish(z_bottom - 3.0)
                self.finish_z = z_bottom - 3.0
            elif n % 2 == 1:
                # A checkpoint after every second section.
                self.checkpoint(z_bottom - 2.5)
                z = z_bottom - 5.0
            else:
                z = z_bottom - 2.0
        self.world.dress(self, 7.0, self.finish_z - 4.5)

    def write(self):
        path = os.path.join(PROJECT, "levels", f"{self.key}.tscn")
        with open(path, "w", encoding="utf-8", newline="\n") as out:
            out.write(self.s.text())
        return path


# --- Worlds ------------------------------------------------------------------------


def sky(level, top=None, horizon=None, ground=None, energy=1.0):
    extra = ""
    if top:
        extra += f"\nsky_top_color = {color(*top)}"
    if horizon:
        extra += f"\nsky_horizon_color = {color(*horizon)}\nground_horizon_color = {color(*horizon)}"
    if ground:
        extra += f"\nground_bottom_color = {color(*ground)}"
    level.s.sub(f'[sub_resource type="ProceduralSkyMaterial" id="SkyMaterial_1"]{extra}')
    level.s.sub('[sub_resource type="Sky" id="Sky_1"]\nsky_material = SubResource("SkyMaterial_1")')
    level.s.sub('[sub_resource type="Environment" id="Environment_1"]\nbackground_mode = 2\nsky = SubResource("Sky_1")\n'
                f'ambient_light_source = 3\nambient_light_energy = {num(energy)}\ntonemap_mode = 2')
    level.s.node("WorldEnvironment", node_type="WorldEnvironment", environment='SubResource("Environment_1")')


def dark(level, background, ambient, energy):
    level.s.sub('[sub_resource type="Environment" id="Environment_1"]\nbackground_mode = 1\n'
                f'background_color = {color(*background)}\nambient_light_source = 2\n'
                f'ambient_light_color = {color(*ambient)}\nambient_light_energy = {num(energy)}\ntonemap_mode = 2')
    level.s.node("WorldEnvironment", node_type="WorldEnvironment", environment='SubResource("Environment_1")')


def sun(level, light=(1, 1, 1), energy=1.0):
    level.s.node("Sun", node_type="DirectionalLight3D", transform=SUN, light_color=color(*light),
                 light_energy=energy, shadow_enabled=True)


def ground(level, z_from, z_to, rgb, width=80.0):
    level.block("Ground", 0, -1, (z_from + z_to) / 2, (width, 1, z_from - z_to + 40), color=color(*rgb))


def edges(level, z_from, z_to):
    center, length = (z_from + z_to) / 2, z_from - z_to
    for x in [-11.5, 11.5]:
        level.block("Edge", x, 0, center, (1, 3, length), show_box=False)
    level.block("Edge", 0, 0, z_from - 0.5, (24, 3, 1), show_box=False)
    level.block("Edge", 0, 0, z_to + 0.5, (24, 3, 1), show_box=False)


def colored_strip(level, z, rgb, width=2.5):
    level.block("Lane", 0, 0.005, z, (44, 0.02, width - 0.1), solid=False, color=color(*rgb))


class World:
    index = 0
    spike_traps = False
    vehicle_rolls = False
    vehicles = []
    vehicle_scale = 0.72
    arm_color = (0.35, 0.3, 0.33)
    obstacles = []

    def wall(self, level, x, z, width):
        model, scale, spacing = self.wall_model
        level.decorated("Wall", x, z, (width, 1.2, 1.0), model, scale, spacing)


class Forest(World):
    index = 1
    roller = {"color": None}
    walker = {"model": A("forest", "character-archer"), "scale": 1.3}
    wanderer = {"model": A("dungeon", "character-human"), "scale": 1.3}
    wall_model = (A("forest", "rocks-low"), 1.1, 1.1)
    obstacles = [(A("forest", "tent"), 1.3, (1.6, 1.2, 1.4)), (A("forest", "rocks-low"), 1.4, (1.2, 1.0, 1.2))]

    def dress(self, level, z_from, z_to):
        sky(level)
        sun(level)
        ground(level, z_from, z_to, (0.35, 0.6, 0.3))
        center, length = (z_from + z_to) / 2, z_from - z_to
        level.decorated("Trees", -11.5, center, (1, 1.5, length), A("forest", "tree-high"), 2.0, 1.9, random_turn=True)
        level.decorated("Trees", 11.5, center, (1, 1.5, length), A("forest", "tree"), 2.0, 1.9, random_turn=True)
        level.decorated("Trees", 0, z_from + 0.5, (22, 1.5, 1), A("forest", "tree"), 2.0, 1.9, random_turn=True)
        level.decorated("Trees", 0, z_to - 0.5, (22, 1.5, 1), A("forest", "tree-high"), 2.0, 1.9, random_turn=True)


class City(World):
    index = 2
    roller = {"color": (0.55, 0.55, 0.58)}
    walker = {"model": A("characters", "character-male-e"), "scale": 1.3}
    wanderer = {"model": A("cars", "kart-oobi"), "scale": 1.0, "hit": 0.45}
    vehicles = [A("cars", c) for c in ["sedan", "taxi", "van", "suv", "police", "truck", "delivery", "hatchback-sports"]]
    arm_color = (0.95, 0.55, 0.1)
    wall_model = (A("roads", "construction-barrier"), 6.0, 1.0)
    obstacles = [(A("suburban", "tree-large"), 3.0, (0.6, 2, 0.6)), (A("suburban", "planter"), 3.0, (1.2, 0.6, 0.9))]
    HOUSES = [A("suburban", f"building-type-{c}") for c in "abcfgkmp"]

    def lane_surface(self, level, z):
        level.decorated("Road", 0, z, (44, 0.1, 2.5), A("roads", "road-straight"), 2.5, 2.5, solid=False,
                        parent="Terrain")

    def dress(self, level, z_from, z_to):
        sky(level)
        sun(level)
        ground(level, z_from, z_to, (0.7, 0.7, 0.68))
        edges(level, z_from, z_to)
        # Houses along every stretch without a road through it.
        busy = sorted(level.lanes, reverse=True)
        stretches, top = [], z_from
        for lane in busy:
            if top - (lane + 1.25) >= 3.0:
                stretches.append((top, lane + 1.25))
            top = min(top, lane - 1.25)
        if top - z_to >= 3.0:
            stretches.append((top, z_to))
        for n, (a, b) in enumerate(stretches):
            for x, turn in [(-13.5, 0.0), (13.5, 180.0)]:
                level.decorated("Houses", x, (a + b) / 2, (4, 0.1, a - b), self.HOUSES[(n * 3 + (x > 0)) % 8],
                                4.0, 6.0, solid=False, turn=turn)
        level.decorated("Houses", 0, z_from + 3.0, (24, 0.1, 4), self.HOUSES[0], 4.0, 6.0, solid=False, turn=180.0)
        level.decorated("Houses", 0, z_to - 2.5, (24, 0.1, 4), self.HOUSES[5], 4.0, 6.0, solid=False)


class Dungeon(World):
    index = 3
    spike_traps = True
    roller = {"color": (0.45, 0.42, 0.42)}
    walker = {"model": A("dungeon", "character-orc"), "scale": 1.3}
    wanderer = {"model": A("dungeon", "character-orc"), "scale": 1.3}
    wall_model = (A("dungeon", "wall"), 2.0, 2.0)
    obstacles = [(A("dungeon", "barrel"), 1.4, (0.8, 1.0, 0.8)), (A("dungeon", "column"), 2.0, (1.0, 2.0, 1.0))]

    def wall(self, level, x, z, width):
        level.decorated("Wall", x, z, (width, 2.2, 2.0), A("dungeon", "wall"), 2.0, 2.0)

    def dress(self, level, z_from, z_to):
        dark(level, (0.04, 0.035, 0.045), (0.6, 0.55, 0.55), 0.55)
        level.s.node("Moonlight", node_type="DirectionalLight3D", transform=SUN, light_color=color(0.85, 0.85, 1),
                     light_energy=0.45, shadow_enabled=True)
        center, length = (z_from + z_to) / 2, z_from - z_to + 4
        level.block("Floor", 0, -1, center, (26, 1, length), color=color(0.16, 0.15, 0.16),
                    decoration=level.s.res(A("dungeon", "floor")), decoration_scale=2.02, decoration_spacing=2.0,
                    random_turn=False, decoration_height=1.005)
        for x in [-12, 12]:
            level.decorated("Wall", x, center, (2, 2.2, length), A("dungeon", "wall"), 2.0, 2.0)
        level.decorated("Wall", 0, z_from + 0.5, (22, 2.2, 2), A("dungeon", "wall"), 2.0, 2.0)
        level.decorated("Wall", 0, z_to - 0.5, (22, 2.2, 2), A("dungeon", "wall"), 2.0, 2.0)
        torches(level, z_from, z_to, (1, 0.6, 0.3))


def torches(level, z_from, z_to, rgb, x=10.3, height=2.5, energy=2.5):
    level.s.node("Lights", node_type="Node3D")
    z, side = z_from - 4, -1
    while z > z_to:
        level.s.node("Light", "Lights", "OmniLight3D", transform=transform(x * side, height, z),
                     light_color=color(*rgb), light_energy=energy, omni_range=9.0)
        z -= 10
        side = -side


class Graveyard(World):
    index = 4
    roller = {"model": A("graveyard", "pumpkin-carved"), "scale": 1.9}
    walker = {"model": A("graveyard", "character-zombie"), "scale": 1.3}
    wanderer = {"model": A("graveyard", "character-ghost"), "scale": 1.3}
    arm_color = (0.3, 0.3, 0.35)
    obstacles = [(A("graveyard", "crypt"), 1.6, (1.2, 1.2, 1.8)), (A("graveyard", "gravestone-cross"), 1.6, (0.7, 1.4, 0.5)),
                 (A("graveyard", "gravestone-round"), 1.8, (0.8, 1.0, 0.5))]

    def wall(self, level, x, z, width):
        level.decorated("Fence", x, z, (width, 1.4, 0.6), A("graveyard", "iron-fence"), 2.0, 2.0)

    def dress(self, level, z_from, z_to):
        dark(level, (0.05, 0.06, 0.12), (0.55, 0.6, 0.85), 0.7)
        level.s.node("Moonlight", node_type="DirectionalLight3D", transform=SUN, light_color=color(0.7, 0.75, 1),
                     light_energy=0.6, shadow_enabled=True)
        ground(level, z_from, z_to, (0.24, 0.3, 0.25))
        edges(level, z_from, z_to)
        center, length = (z_from + z_to) / 2, z_from - z_to
        for x in [-11.4, 11.4]:
            level.decorated("Fence", x, center, (0.4, 0.1, length), A("graveyard", "iron-fence"), 2.0, 2.0, solid=False)
            level.decorated("Pines", x * 1.22, center, (2, 0.1, length), A("graveyard", "pine"), 1.8, 3.0,
                            solid=False, random_turn=True)
            level.decorated("Graves", x * 1.12, center, (1, 0.1, length), A("graveyard", "gravestone-round"), 1.6,
                            4.5, solid=False, random_turn=True)
        level.decorated("Pines", 0, z_from + 1.5, (24, 0.1, 2), A("graveyard", "pine"), 1.8, 3.0, solid=False, random_turn=True)
        level.decorated("Pines", 0, z_to - 1.5, (24, 0.1, 2), A("graveyard", "pine-crooked"), 1.8, 3.0, solid=False, random_turn=True)
        torches(level, z_from, z_to, (1, 0.75, 0.45), x=10.6, height=2.0, energy=2.0)


class SpaceStation(World):
    index = 5
    roller = {"model": A("space", "meteor"), "scale": 0.85}
    walker = {"model": A("space", "alien"), "scale": 1.3}
    wanderer = {"model": A("space", "alien"), "scale": 1.3}
    vehicles = [A("space", "craft_cargoA"), A("space", "craft_cargoB"), A("space", "craft_miner")]
    vehicle_scale = 0.75
    arm_color = (0.3, 0.55, 0.95)
    obstacles = [(A("spacestation", "container-tall"), 1.6, (1.0, 1.4, 1.0)), (A("spacestation", "container-wide"), 1.6, (1.4, 1.0, 1.0))]

    def wall(self, level, x, z, width):
        level.decorated("Barrier", x, z, (width, 1.6, 1.0), A("spacestation", "structure-barrier"), 1.0, 1.1)

    def lane_surface(self, level, z):
        colored_strip(level, z, (0.12, 0.22, 0.42))

    def dress(self, level, z_from, z_to):
        dark(level, (0.0, 0.0, 0.02), (0.6, 0.65, 0.85), 0.3)
        level.s.node("Light", node_type="DirectionalLight3D", transform=SUN, light_color=color(0.85, 0.9, 1),
                     light_energy=0.45, shadow_enabled=True)
        center, length = (z_from + z_to) / 2, z_from - z_to + 4
        level.block("Floor", 0, -1, center, (26, 1, length), color=color(0.3, 0.32, 0.36),
                    decoration=level.s.res(A("spacestation", "floor")), decoration_scale=2.02, decoration_spacing=2.0,
                    random_turn=False, decoration_height=0.4)
        for x in [-12, 12]:
            level.decorated("Wall", x, center, (2, 2.0, length), A("spacestation", "wall"), 2.0, 2.0,
                            turn=0.0 if x < 0 else 180.0)
        level.decorated("Wall", 0, z_from + 0.5, (22, 2.0, 2), A("spacestation", "wall"), 2.0, 2.0)
        level.decorated("Wall", 0, z_to - 0.5, (22, 2.0, 2), A("spacestation", "wall"), 2.0, 2.0)
        torches(level, z_from, z_to, (0.6, 0.8, 1.0), x=10.5, height=2.2, energy=2.0)


class PirateBeach(World):
    index = 6
    roller = {"model": A("pirate", "cannon-ball"), "scale": 1.1}
    walker = {"model": A("graveyard", "character-skeleton"), "scale": 1.3}
    wanderer = {"model": A("graveyard", "character-skeleton"), "scale": 1.3}
    vehicle_rolls = True  # Barrels drifting down water channels.
    arm_color = (0.25, 0.22, 0.2)
    obstacles = [(A("pirate", "crate"), 1.0, (1.1, 0.8, 1.3)), (A("pirate", "barrel"), 0.7, (0.95, 0.9, 0.95))]

    def __init__(self):
        self.roller = dict(PirateBeach.roller)

    def wall(self, level, x, z, width):
        level.decorated("Crates", x, z, (width, 1.0, 1.2), A("pirate", "crate"), 1.0, 1.1)

    def lane_surface(self, level, z):
        colored_strip(level, z, (0.2, 0.5, 0.8))

    def dress(self, level, z_from, z_to):
        sky(level, top=(0.3, 0.55, 0.95), horizon=(0.75, 0.9, 1.0))
        sun(level, (1, 0.97, 0.9), 1.1)
        ground(level, z_from, z_to, (0.93, 0.85, 0.6), width=30)
        level.block("Sea", 0, -1.05, (z_from + z_to) / 2, (300, 1, z_from - z_to + 300), color=color(0.15, 0.45, 0.75))
        edges(level, z_from, z_to)
        center, length = (z_from + z_to) / 2, z_from - z_to
        for x in [-12.5, 12.5]:
            level.decorated("Palms", x, center, (2, 0.1, length), A("pirate", "palm-straight"), 0.8, 4.0,
                            solid=False, random_turn=True)
        level.decorated("Rocks", 0, z_from + 1.5, (24, 0.1, 2), A("pirate", "rocks-sand-a"), 0.5, 3.0, solid=False, random_turn=True)
        level.decorated("Rocks", 0, z_to - 1.5, (24, 0.1, 2), A("pirate", "rocks-sand-b"), 0.5, 3.0, solid=False, random_turn=True)


class Snow(World):
    index = 7
    roller = {"color": (0.95, 0.97, 1.0)}
    walker = {"model": A("holiday", "nutcracker"), "scale": 1.0}
    wanderer = {"model": A("holiday", "gingerbread-man"), "scale": 2.4}
    vehicles = [A("holiday", "sled"), A("holiday", "sled-long")]
    vehicle_scale = 1.6
    arm_color = (0.85, 0.15, 0.15)
    obstacles = [(A("holiday", "present-a-cube"), 1.8, (0.8, 1.0, 0.8)), (A("holiday", "rocks-medium"), 0.6, (1.2, 0.6, 1.0))]

    def wall(self, level, x, z, width):
        level.decorated("Rocks", x, z, (width, 1.0, 1.2), A("holiday", "rocks-medium"), 0.65, 1.2, random_turn=True)

    def lane_surface(self, level, z):
        colored_strip(level, z, (0.7, 0.85, 0.95))

    def dress(self, level, z_from, z_to):
        sky(level, top=(0.55, 0.65, 0.85), horizon=(0.9, 0.93, 0.97), energy=1.1)
        sun(level, (1, 0.97, 0.95), 0.9)
        ground(level, z_from, z_to, (0.92, 0.94, 0.97))
        center, length = (z_from + z_to) / 2, z_from - z_to
        level.decorated("Trees", -11.5, center, (1, 1.5, length), A("holiday", "tree-snow-a"), 1.7, 1.9, random_turn=True)
        level.decorated("Trees", 11.5, center, (1, 1.5, length), A("holiday", "tree-snow-b"), 1.7, 1.9, random_turn=True)
        level.decorated("Trees", 0, z_from + 0.5, (22, 1.5, 1), A("holiday", "tree-snow-c"), 1.7, 1.9, random_turn=True)
        level.decorated("Trees", 0, z_to - 0.5, (22, 1.5, 1), A("holiday", "tree-snow-a"), 1.7, 1.9, random_turn=True)


# --- Recipes: the sections of every level, south to north -------------------------

# The section types each world uses. Every level also gets a "swarm" section
# (a field packed with wanderers) as every third section.
PALETTES = {
    Forest: ["rollers", "circles", "patrols", "zigzag", "wanderers"],
    City: ["traffic", "construction", "wanderers", "traffic"],
    Dungeon: ["spikes", "spinners", "pendulums", "rams", "patrols", "wanderers"],
    Graveyard: ["rollers", "circles", "zigzag", "patrols", "wanderers"],
    SpaceStation: ["traffic", "rollers", "spinners", "pendulums", "wanderers"],
    PirateBeach: ["rollers", "traffic", "patrols", "zigzag", "rams", "wanderers"],
    Snow: ["rollers", "traffic", "patrols", "circles", "spinners", "wanderers"],
}


def recipe_for(world_class, number):
    """12 sections for x-1 and x-2, 14 for x-3 and x-4, 16 for x-5."""
    rng = random.Random(world_class.index * 31 + number * 7)
    palette = list(PALETTES[world_class])
    rng.shuffle(palette)
    recipe, next_type = [], 0
    for n in range(2 * (6 + (number - 1) // 2)):
        if n % 3 == 1:
            recipe.append("swarm")
        else:
            recipe.append(palette[next_type % len(palette)])
            next_type += 1
    return recipe


def all_levels():
    for world_class in PALETTES:
        for number in range(1, 6):
            yield world_class(), number, recipe_for(world_class, number)


def main():
    count = 0
    for world, number, recipe in all_levels():
        level = Level(world, number, recipe)
        level.build()
        level.write()
        count += 1
    print(f"wrote {count} levels")


if __name__ == "__main__":
    main()
