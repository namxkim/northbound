"""Finds the right hazard speed for every section of every level.

For each section, searches for the fastest hazard speed (up to the level's
cap) at which tools/solver.gd still finds a way through from every start time
it tries, with hazards grown by the level's safety margin. Writes the result to
tools/level_dials.json and regenerates the levels.

Difficulty ramps up through the game:
- Room for error: x-1 levels need 0.5 m around every hazard, x-4 and x-5 0.35 m.
- Speed cap: 0.75x in 1-1, rising with each level and world, up to 1.4x.
Chasers aren't part of the search (they react to players); they're kept
slower than players instead.

Run from the project folder:  uv run --no-project tools/tune_levels.py
Optional: a list of levels to tune, like  w2_l3 w2_l4
"""

import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

TOOLS = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(TOOLS)
GODOT = r"C:\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe"
WORLDS, LEVELS_PER_WORLD = 7, 5
ALL_LEVELS = [f"w{w}_l{l}" for w in range(1, WORLDS + 1) for l in range(1, LEVELS_PER_WORLD + 1)]
SLOWEST = 0.5
ROUNDS = 6
PARALLEL = max(2, min(8, (os.cpu_count() or 4) - 2))


def margin_for(level):
    number = int(level.split("_l")[1])
    return [0.5, 0.45, 0.4, 0.35, 0.35][number - 1]


def cap_for(level):
    world, number = int(level[1]), int(level.split("_l")[1])
    return round(min(1.4, 0.75 + 0.13 * (number - 1) + 0.04 * (world - 1)), 3)


def load_dials():
    path = os.path.join(TOOLS, "level_dials.json")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as dials_in:
            return json.load(dials_in)
    return {}


def generate(dials):
    with open(os.path.join(TOOLS, "level_dials.json"), "w", encoding="utf-8") as out:
        json.dump(dials, out, indent=2, sort_keys=True)
    subprocess.run(["uv", "run", "--no-project", "--python", "3.12", os.path.join(TOOLS, "level_generator.py")],
                   cwd=PROJECT, check=True, capture_output=True)


def solve(level, margin=None):
    output = subprocess.run(
        [GODOT, "--headless", "--path", PROJECT, "-s", "tools/solver.gd", "--",
         f"level=res://levels/{level}.tscn", f"margin={margin or margin_for(level)}"],
        capture_output=True, text=True).stdout
    sections = [int(m.group(1)) == int(m.group(2)) for m in re.finditer(r"beatable from (\d+)/(\d+)", output)]
    spawn_safe = "spawn spots: all safe" in output
    return level, sections, spawn_safe, output


def solve_all(levels, margin=None):
    with ThreadPoolExecutor(PARALLEL) as pool:
        return {level: (sections, safe, text) for level, sections, safe, text in
                pool.map(lambda lv: solve(lv, margin), levels)}


def main():
    levels = sys.argv[1:] or ALL_LEVELS
    dials = load_dials()
    low = {level: [SLOWEST] * 4 for level in levels}
    high = {level: [cap_for(level)] * 4 for level in levels}
    for round_number in range(ROUNDS):
        for level in levels:
            dials[level] = [round((low[level][i] + high[level][i]) / 2, 3) for i in range(4)]
        generate(dials)
        results = solve_all(levels)
        for level in levels:
            for i, ok in enumerate(results[level][0]):
                (low if ok else high)[level][i] = dials[level][i]
        print(f"round {round_number + 1} done", flush=True)

    for level in levels:
        dials[level] = [round(v, 3) for v in low[level]]
    generate(dials)
    results = solve_all(levels)
    print("level  margin  cap   section speeds          beatable  spawns")
    problems = 0
    for level in levels:
        sections, safe, text = results[level]
        count = len(sections)
        ok = all(sections) and safe
        problems += 0 if ok else 1
        speeds = ", ".join(f"{d:.2f}" for d in dials[level][:count])
        print(f"{level}  {margin_for(level):.2f}   {cap_for(level):.2f}  {speeds:<22}  "
              f"{sum(sections)}/{count}       {'safe' if safe else 'NOT SAFE'}")
        if not ok:
            for line in text.splitlines():
                if "->" in line or "spawn" in line:
                    print("     " + line.strip())
    print(f"{problems} level(s) with problems")


if __name__ == "__main__":
    main()
