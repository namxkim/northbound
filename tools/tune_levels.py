"""Finds the hardest speed for every section that's still beatable.

For each section of each level, searches for the fastest hazard speed at which
tools/solver.gd still finds a way through from every start time it tries,
with hazards grown by a safety margin. Writes the result to
tools/level_dials.json and regenerates the levels.

Run from the project folder:  uv run --no-project tools/tune_levels.py
"""

import json
import os
import re
import subprocess
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(TOOLS)
GODOT = r"C:\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe"
LEVELS = ["level_01", "level_02", "level_03", "level_04"]
MARGIN = sys.argv[1] if len(sys.argv) > 1 else "0.35"
SLOWEST, FASTEST = 0.6, 1.4
ROUNDS = 6


def generate(dials):
    with open(os.path.join(TOOLS, "level_dials.json"), "w", encoding="utf-8") as out:
        json.dump(dials, out, indent=2)
    subprocess.run(["uv", "run", "--no-project", "--python", "3.12", os.path.join(TOOLS, "level_generator.py")],
                   cwd=PROJECT, check=True, capture_output=True)


def solve_all(margin):
    """Runs the solver on every level at once. Returns {level: [section beatable?]}."""
    runs = {}
    for level in LEVELS:
        runs[level] = subprocess.Popen(
            [GODOT, "--headless", "--path", PROJECT, "-s", "tools/solver.gd", "--",
             f"level=res://levels/{level}.tscn", f"margin={margin}"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    results = {}
    for level, run in runs.items():
        output, _ = run.communicate()
        results[level] = [int(m.group(1)) == int(m.group(2))
                          for m in re.finditer(r"beatable from (\d+)/(\d+)", output)]
        results[level + "_text"] = output
    return results


def main():
    low = {level: [SLOWEST] * 4 for level in LEVELS}
    high = {level: [FASTEST] * 4 for level in LEVELS}
    for round_number in range(ROUNDS):
        dials = {level: [round((low[level][i] + high[level][i]) / 2, 3) for i in range(4)] for level in LEVELS}
        generate(dials)
        results = solve_all(MARGIN)
        for level in LEVELS:
            for i, ok in enumerate(results[level]):
                if ok:
                    low[level][i] = dials[level][i]
                else:
                    high[level][i] = dials[level][i]
        print(f"round {round_number + 1}: " + "  ".join(
            f"{level}=" + ",".join(f"{d:.2f}{'+' if ok else '-'}" for d, ok in zip(dials[level], results[level]))
            for level in LEVELS), flush=True)

    final = {level: [round(v, 3) for v in low[level]] for level in LEVELS}
    generate(final)
    print("final dials:", json.dumps(final))
    for margin in [MARGIN, "0.5"]:
        results = solve_all(margin)
        print(f"--- check with margin {margin}")
        for level in LEVELS:
            for line in results[level + "_text"].splitlines():
                if "->" in line or "RESULT" in line:
                    print(f"{level}: {line.strip()}")


if __name__ == "__main__":
    main()
