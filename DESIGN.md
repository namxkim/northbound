# Northbound Together: design notes

The game's title is **Northbound Together**. The project folder and GitHub repository are named `northbound`.

## The game
- 2.5D: a 3D world seen from a fixed camera angled down. Players head north (-Z), like Crossy Road.
- Movement is smooth and free in any direction, with no grid. Players can only move (more abilities may come later).
- Terrain blocks paths. Enemies move in set patterns: back and forth, one-way traffic, circling, waypoint loops, stop-and-go, spinning arms, pendulums and pop-up spikes.
- Touching an enemy kills you.
- Levels are designed by hand, each with a start, checkpoints and a finish at the north end.

## Levels
Winning a level unlocks the next. Progress is saved on each player's computer (`user://progress.cfg`). In co-op the host picks the level from the ones they've unlocked. After a win, Enter replays and N goes to the next level (solo or host).

| # | Name | Setting | Length | What's in it |
|---|---|---|---|---|
| 1 | Forest Path | Forest | 115 m | 22 boulder rows (48 boulders), 35 archers circling, pacing and marching, a zigzag through rock walls |
| 2 | City Crossing | City | 92 m | 27 lanes of traffic (95 cars), some stop halfway |
| 3 | Dungeon Halls | Dungeon | 108 m | 7 rows of pop-up spikes plus a 4x16 spike field, 19 spinning and swinging arms, 13 orcs, 4 sliding boulders |
| 4 | Rush Hour | City | 111 m | 24 lanes (85 cars), a construction zone with 6 spinners and 2 wrecking-ball chains, 2 more wrecking balls and a spinner near the finish |

Every level has 3 checkpoints. The levels are meant to take real effort: every section is tuned so a perfect player can get through with about 0.35 m to spare around each hazard, but not 0.5 m.

The list lives in `scripts/levels.gd`. To add a level by hand, make a scene with `level.gd` on the root, a `Start` marker, terrain, hazards and Zones, then add it to the list. The camera and on-screen text are added automatically.

### Level tools (`tools/`)
- `level_generator.py` writes the four level scenes from a short description of each section. Running it **overwrites** `levels/level_01-04.tscn`, so changes made to those files in the editor are lost. Run: `uv run --no-project tools/level_generator.py`
- `solver.gd` proves each section can be beaten: it replays every hazard's exact movement and searches every position and moment for a way through, with hazards grown by a safety margin. It also checks no hazard ever touches a checkpoint's spawn spots. Run: `Godot_console.exe --headless --path . -s tools/solver.gd -- level=res://levels/level_02.tscn margin=0.35`
- `tune_levels.py` sets each section's speed dial (in `level_dials.json`) to the fastest speed that's still beatable, capped at 1.4x, then regenerates the levels. Run: `uv run --no-project tools/tune_levels.py 0.35` (takes about 7 minutes).

## Sizes and speed
Players and enemies are small (about 60% of the original size) so more hazards fit on the 22 m-wide map; scenery (trees, walls, houses) is full size. Player top speed is 5 m/s. Hitboxes: player 0.21 m radius, walkers 0.27 m, boulders 0.36 m, cars 1.05 x 1.9 m, spiked balls 0.28 m (wrecking balls 0.6 m), spikes 0.85 m square. City lanes are 2.5 m wide.

## Players
- Solo or online co-op, up to 8 players. Each player controls one character.
- Online play is peer-to-peer: one player hosts and the others join. No separate server.

## Death, checkpoints and winning
- **Solo** (one player in the round, including hosting alone): dying sends you back to the last checkpoint you reached.
- **Co-op** (two or more players): a player who is hit stays down and watches a teammate who's still alive (A / D switches who).
- **Co-op:** when a living player reaches a checkpoint the team hasn't reached yet, every dead player comes back there. Walking back to an old checkpoint does nothing.
- **Co-op:** if everyone is down, the round is lost. The host restarts it from the start of the level.
- **Co-op:** the first player across the finish wins the round for the whole team.
- The host's game makes every team decision (checkpoints, win, loss) and tells everyone, so all the games agree even when two things happen at once.
- Levels need checkpoints spread along the way, since they're the only way to bring teammates back. Every level has three.

## Build plan
1. Single-player core: movement, camera, terrain, enemy patterns, death, checkpoint, finish. **(done)**
2. Networking: Host / Join menu, one character per player, synced positions, tested with several copies on one PC. **(done)**
3. Co-op round rules: watching teammates while dead, respawning at checkpoints, "round lost" when everyone is dead, host restarts. **(done)**
4. Content: 3-5 levels, more enemy patterns, level select. **(done: 4 levels)**
5. Real online play: Steam invites (GodotSteam) so friends can join over the internet.
6. Polish and release.

## Art
- Style: low-poly 3D from Kenney (kenney.nl), all CC0 (free for any use, credit optional). Each pack's license is in its folder under `assets/`.
- `assets/characters`: Mini Characters, 12 people with idle/walk/sprint/die animations. One per player in co-op.
- `assets/forest`: Mini Forest, trees, fences, rocks, tents and flags for the forest setting.
- `assets/dungeon`: Mini Dungeon, walls, floors, spike traps, orcs, barrels.
- `assets/roads`, `assets/suburban`, `assets/cars`: City Kit Roads, City Kit Suburban and Car Kit for the city levels.
- Enemies: `scenes/enemy.tscn` is a walker (archer by default; set Model Scene to use another character, like the orc). `scenes/boulder.tscn` is a rolling rock (built in code by `low_poly_rock.gd`). `scenes/car.tscn` is traffic (set Model Scene to pick the vehicle). All have red markings on the ground to show danger.
- Each new setting can use another Kenney pack in the same style.

## How the code is set up
- `GameClock` (autoload) holds the round time. Enemies calculate their position from it, so in online play every player's game can show enemies in the same place from one shared clock.
- `Network` (autoload) handles hosting, joining, the lobby's player list, starting rounds and syncing the clock (players who joined check the host's clock once a second). All network messages go through it, because it exists in every scene.
- Online flow: the main menu hosts or joins. In the lobby, the host presses Start, and everyone loads the level. When all players have loaded, the host starts the round clock for everyone.
- Each player's own computer moves their character, checks whether an enemy hit them and sends their position about 30 times a second. Deaths, respawns and finishes are sent as separate messages that always arrive.
- Port 24680 (ENet). Players on the same network join with the host's local address. Internet play needs port forwarding until Steam is added in step 5.
- To test online play on one PC: in the editor, open Debug > Customize Run Instances, turn on multiple instances (e.g. 3), then press F5. Host in one window, join 127.0.0.1 in the others.
- Custom node types for building levels (add them with Add Node, then set them up in the Inspector):
  - `Block`: terrain. Can repeat a decoration model across itself (trees, walls, floor tiles, houses). Turn off Solid for walk-over decoration like roads.
  - `Zone`: checkpoint or finish.
  - `HazardArm`: a post with spiked arms that spin, or one arm that swings like a pendulum.
  - `SpikeField`: a grid of pop-up spikes with a warning glow; Wave Delay makes them rise in a wave.
- `Levels` (autoload) holds the level list and saved progress.
- Physics layers: 1 = world, 2 = players, 3 = enemies. Players don't block each other.
