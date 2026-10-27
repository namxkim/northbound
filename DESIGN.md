# Northbound Together: design notes

The game's title is **Northbound Together**. The project folder and GitHub repository are named `northbound`.

## The game
- 2.5D: a 3D world seen from a fixed camera angled down. Players head north (-Z), like Crossy Road.
- Movement is smooth and free in any direction, with no grid. Players can only move (more abilities may come later).
- Terrain blocks paths. Most enemies move in set patterns: back and forth, one-way traffic, circling, waypoint loops, stop-and-go, spinning arms, pendulums and pop-up spikes.
- **Wanderers** move randomly: each hop goes a random distance (up to 3.5-4 m) in a random direction at a random speed. Some hops are quick dashes, some ease in and out, others turn sharply, and they pause at random. The moves come from a seed and the round clock, so every player's game shows the same moves. Every level has 70-140 of them, including **swarm** sections packed with 25-35 roaming wide areas.
- Chasers (enemies that follow players) were tried and removed. The code is still in `scripts/chaser.gd` and `scenes/chaser.tscn` but no level uses them.
- Touching an enemy kills you.
- Each level has a start, a checkpoint after every second section (2 or 3 in all) and a finish at the north end. Levels are 135-225 m long.

## Worlds and levels
7 worlds of 5 levels, named 1-1 to 7-5 (35 levels). Levels unlock in order across worlds (1-5 unlocks 2-1). Progress is saved on each player's computer (`user://progress.cfg`). Play Solo shows a grid of worlds and levels; in co-op the host picks from the levels they've unlocked. After a win, Enter replays and N goes to the next level (solo or host).

| World | Enemies and hazards | |
|---|---|---|
| 1 Forest | Rolling boulders, archers, wandering knights, rock-wall zigzags | |
| 2 City | Traffic (some stop halfway), construction spinners and wrecking balls, wandering go-karts | |
| 3 Dungeon | Spike waves, spinners, pendulums, sliding boulders, orcs | |
| 4 Graveyard | Rolling pumpkins, zombies, wandering ghosts, iron-fence zigzags | |
| 5 Space Station | Cargo-ship traffic, meteors, spinners, pendulums, wandering aliens | |
| 6 Pirate Beach | Cannonballs, barrels drifting down water channels, skeleton pirates, crate zigzags | |
| 7 Snow | Snowballs, sleds on ice lanes, marching nutcrackers, wandering gingerbread people | |

Difficulty starts high and ramps up: x-1 levels are already demanding, x-5 levels are hardest, and later worlds are harder overall. Two things grow together:
- **How busy:** each section's hazard count scales from 0.85 (1-1) to 1.41 (7-5).
- **Length:** 6 sections in x-1 and x-2, 7 in x-3 and x-4, 8 in x-5, with a checkpoint every two sections.

All hazards currently run at their base speed. The levels have **not** been checked by the solver since they got longer and busier, so a stretch could turn out unfair or impossible; if one does, `tools/tune_levels.py` can tune just that level (for example `w3_l4`), or its recipe can be adjusted in the generator. When tuning, x-1 levels need a way through with 0.4 m around every hazard (down to 0.35 m in x-4 and x-5), with speeds capped from 1.0x in 1-1 up to 1.4x.

The list lives in `scripts/levels.gd`. To add a level by hand, make a scene with `level.gd` on the root, a `Start` marker, terrain, hazards and Zones, then add it to the list. The camera and on-screen text are added automatically.

### Level tools (`tools/`)
- `level_generator.py` writes all 35 level scenes. Each world has its own look and enemy models, and each level's recipe is picked from its world's section types (rollers, traffic, circles, patrols, zigzag, wanderers, spinners, pendulums, spikes, rams, construction), with a wanderer swarm as every third section. Running it **overwrites** `levels/w*_l*.tscn`, so changes made to those files in the editor are lost. Run: `uv run --no-project tools/level_generator.py`
- `solver.gd` proves each section can be beaten: it replays every hazard's exact movement and searches every position and moment for a way through, with hazards grown by a safety margin. It also checks no hazard ever touches a checkpoint's spawn spots. Run: `Godot_console.exe --headless --path . -s tools/solver.gd -- level=res://levels/w2_l3.tscn margin=0.35`
- `tune_levels.py` sets each checkpoint-to-checkpoint stretch's speed dial (in `level_dials.json`) to the fastest speed that's still beatable with that level's margin and under its cap, then regenerates the levels. Run: `uv run --no-project tools/tune_levels.py` for all levels, or name some, like `w2_l3 w2_l4`.

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
- Levels need checkpoints spread along the way, since they're the only way to bring teammates back. Every level has two or three.

## Build plan
1. Single-player core: movement, camera, terrain, enemy patterns, death, checkpoint, finish. **(done)**
2. Networking: Host / Join menu, one character per player, synced positions, tested with several copies on one PC. **(done)**
3. Co-op round rules: watching teammates while dead, respawning at checkpoints, "round lost" when everyone is dead, host restarts. **(done)**
4. Content: 3-5 levels, more enemy patterns, level select. **(done: 7 worlds, 35 levels, wanderers and swarms)**
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
