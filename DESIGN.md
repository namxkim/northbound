# Northbound Together: design notes

The game's title is **Northbound Together**. The project folder and GitHub repository are named `northbound`.

## The game
- 2.5D: a 3D world seen from a fixed camera angled down. Players head north (-Z), like Crossy Road.
- Movement is smooth and free in any direction, with no grid. Players can only move (more abilities may come later).
- Terrain blocks paths. Enemies move in set patterns (back and forth, circling, waypoint loops).
- Touching an enemy kills you.
- Levels are designed by hand, each with a start, checkpoints and a finish at the north end.

## Players
- Solo or online co-op, up to 8 players. Each player controls one character.
- Online play is peer-to-peer: one player hosts and the others join. No separate server.

## Death and checkpoints
- **Solo:** dying sends you back to the last checkpoint you reached.
- **Co-op:** a dead player stays dead and watches the others. When a living player reaches a checkpoint, the dead players respawn there.
- **Co-op:** if everyone is dead, the round is lost and can be restarted from the start of the level.

## Build plan
1. Single-player core: movement, camera, terrain, enemy patterns, death, checkpoint, finish. **(done)**
2. Networking: Host / Join menu, one character per player, synced positions, tested with several copies on one PC. **(done)** Until step 3, every player respawns at their own last checkpoint, and the round ends when everyone has reached the finish.
3. Co-op round rules: watching teammates while dead, respawning at checkpoints, "round lost" when everyone is dead, host restarts.
4. Content: 3-5 levels, more enemy patterns, level select.
5. Real online play: Steam invites (GodotSteam) so friends can join over the internet.
6. Polish and release.

## Art
- Style: low-poly 3D from Kenney (kenney.nl), all CC0 (free for any use, credit optional). Each pack's license is in its folder under `assets/`.
- `assets/characters`: Mini Characters, 12 people with idle/walk/sprint/die animations. One per player in co-op.
- `assets/forest`: Mini Forest, trees, fences, rocks, tents and flags for the forest setting.
- Enemies: `scenes/enemy.tscn` is a walking archer, `scenes/boulder.tscn` is a rolling rock (built in code by `low_poly_rock.gd`). Both have a red ring on the ground to show danger.
- Each new setting (city, dungeon...) can use another Kenney pack in the same style.

## How the code is set up
- `GameClock` (autoload) holds the round time. Enemies calculate their position from it, so in online play every player's game can show enemies in the same place from one shared clock.
- `Network` (autoload) handles hosting, joining, the lobby's player list, starting rounds and syncing the clock (players who joined check the host's clock once a second). All network messages go through it, because it exists in every scene.
- Online flow: the main menu hosts or joins. In the lobby, the host presses Start, and everyone loads the level. When all players have loaded, the host starts the round clock for everyone.
- Each player's own computer moves their character, checks whether an enemy hit them and sends their position about 30 times a second. Deaths, respawns and finishes are sent as separate messages that always arrive.
- Port 24680 (ENet). Players on the same network join with the host's local address. Internet play needs port forwarding until Steam is added in step 5.
- To test online play on one PC: in the editor, open Debug > Customize Run Instances, turn on multiple instances (e.g. 3), then press F5. Host in one window, join 127.0.0.1 in the others.
- `Block` and `Zone` are custom node types. Add them with Add Node, then set the size, color and kind in the Inspector.
- Physics layers: 1 = world, 2 = players, 3 = enemies. Players don't block each other.
