# PFA Engine — Godot Addon

**PitchFox Audio Engine** — adaptive music & SFX runtime for Godot 4.x.

It plays audio projects authored in **PFA Studio** (the desktop editor): Studio exports a `config.json` + audio files (or a single `.pfabank`), the addon loads and performs them — adaptive music levels, node-graph transitions, randomized SFX, spatial voices, reverb zones. The same export drives the [JavaScript engine](https://github.com/pitchfoxaudio/pfa-engine-js); design once, ship on both.

- Addon version **0.11.x** · config schema **v1.1** · pure GDScript, no GDExtension · MIT
- Requires **Godot 4.x** (developed and tested on 4.6–4.7)
- Part of the **PFA suite** — all components: [github.com/pitchfoxaudio](https://github.com/pitchfoxaudio)
- Authoring is documented in the **PFA Studio manual**; this README covers the runtime API.

## Installation

1. Copy `addons/pfa_engine/` into your Godot project's `addons/` folder
2. Enable the plugin: Project → Project Settings → Plugins → **PFA Engine** → Enable
3. The plugin registers **`PFA`** as an autoload singleton — use it directly from any script
4. Put your exported audio pack anywhere the game can read (`res://audio/`, or next to the project for shared exports)

## Quick Start

```gdscript
func _ready():
    PFA.load_pack("res://audio/config.json")
    PFA.preload_all()                    # warm all events (small game — see Loading)
    PFA.play("main_theme")

func _on_enemy_spotted():
    PFA.set_level("main_theme", 1)       # calm → action

func _on_safe_zone():
    PFA.set_level("main_theme", 0)

func _on_coin_collected():
    PFA.trigger("coin")                  # one-shot SFX

func _on_ball_hit(pos: Vector3, speed: float):
    PFA.trigger_spatial_3d("ball_hit", pos.x, pos.y, pos.z,
                           {"intensity": clampf(speed / 5.0, 0.0, 1.0)})
```

Event names come from your Studio project (lowercase, `_` for spaces); `PFA.get_event_names()` lists everything the pack loaded.

---

## Loading & Memory

`load_pack()` / `load_bank()` parse events and groups but load **no audio** (lazy). An event's samples load synchronously on its first trigger — for a multi-variation WAV event that first-trigger stall can audibly click. Pick a strategy:

- **Small game / demo / pack — `preload_all()`.** Warm every event right after `load_pack()`. Zero first-hit latency, idempotent (the Live-reload path re-warms cheaply). Comparable to FMOD's `Bank.loadSampleData()`.
- **Many-room game — groups.** Author events into **groups per area/room** in Studio, keep a small "common" group resident (UI, player, footsteps), and:

```gdscript
PFA.load_group("forest")     # on room enter
PFA.unload_group("forest")   # on room exit — frees the streams
```

Memory on Godot is **manual by design**: the game controls it by which groups it keeps loaded (no auto-eviction; the JS engine differs — it has an automatic LRU budget).

- **Binary bank — `.pfabank`.** Studio can export the whole project as one binary file; useful when you ship a single pack:

```gdscript
PFA.load_bank("res://audio/project.pfabank")
PFA.preload_all()
PFA.release_bank_buffer()    # free the raw bank bytes; audio stays in AudioStreams
```

---

## API Reference

### Loading

| Method | Description |
|--------|-------------|
| `PFA.load_pack(config_path) → bool` | Load `config.json` and parse events (no audio yet). Sets `PFA.pack_path` (used by Live reload) |
| `PFA.load_bank(bank_path) → bool` | Load a `.pfabank` binary bank — same API after load |
| `PFA.release_bank_buffer()` | Free the raw bank bytes after preloading |
| `PFA.preload_all()` | Load every event's samples (idempotent) |
| `PFA.load_group(group)` / `PFA.unload_group(group)` | Room-based loading / freeing |

### Music (Simple Mode)

| Method | Description |
|--------|-------------|
| `PFA.play(event)` | Play a music event (anti-click fade-in, stops other music) |
| `PFA.stop(event, fade_time := -1.0)` | Stop. Default `-1` ⇒ the event's authored `release_fade`; `>= 0` overrides it |
| `PFA.stop_terminal(event, default_fade := 0.0)` | Stop honoring the current node's `terminal_fade`, falling back to `default_fade` |
| `PFA.stop_all(fade_time := 0.0)` | Stop every event + spatial voice (emitters survive — they belong to the game) |
| `PFA.crossfade_to(event, duration := 2.0)` | Crossfade from current music to another event |
| `PFA.set_level(event, level)` | Set adaptive level — crossfades per the event's quantization settings |
| `PFA.get_level(event) → int` | Current level index |
| `PFA.is_playing(event) → bool` | Whether the event is playing |
| `PFA.get_event_names()` / `PFA.get_group_names()` | Loaded event / group names |

### Node Graph (Advanced Mode)

| Method | Description |
|--------|-------------|
| `PFA.navigate(event, trigger) → bool` | Fire a transition by trigger name — `true` if one matched |
| `PFA.get_current_node(event) → String` | Current node ID (`""` if none) |
| `PFA.toggle_sub_level(event, sub_name, enabled, fade := 0.5)` | Toggle a sub-level layer on/off with a fade |

Node graph activates when the config has `use_nodes: true`. The engine enters the entry node on `play()` (honoring `entry_fade`), auto-advances after `duration_bars × loop_count` when a transition has `auto: true`, falls back to a node's `terminal_fade` when there's no auto transition, fires stingers at transition start, and quantizes per cascade `connection.quantize → node.fade_quantize → event.switchQuantization`.

### SFX

| Method | Description |
|--------|-------------|
| `PFA.trigger(event, options := {}) → Array` | Trigger a one-shot SFX. `options` may carry `{"intensity": 0..1}` — per-trigger hit strength (see Intensity). Returns `played` — one Dictionary per track that fired: `{ track, behavior, variation, variation_count, algo, sample }` |

Cooldown (`cooldown_ms`) and voice cap (`max_instances`, least-audible voice released — see Voice management) are authored per event in Studio and enforced by the engine. `always_play` layers fire on every level; each fired layer picks a fresh sample variation (switch_chance-gated) with clip trim + fades applied.

### Volume & Ducking

| Method | Description |
|--------|-------------|
| `PFA.set_event_volume(event, vol)` | Event volume (linear, 1.0 = unity) — re-bakes playing voices live |
| `PFA.set_group_volume(group, vol)` | Group volume |
| `PFA.set_group_mute(group, mute)` | Mute / unmute a group |
| `PFA.set_master_volume(vol)` | Master volume |
| `PFA.duck(event, level := 0.3, fade := 0.5)` | Duck an event (remembers its volume) |
| `PFA.unduck(event, fade := 0.5)` | Restore after duck |

Volume chain: `clip × track × event × group × master` — all linear, each stage independent.

### Signals

| Signal | Description |
|--------|-------------|
| `event_started(event_name)` | Music event started |
| `event_stopped(event_name)` | Event stopped |
| `level_changed(event_name, level)` | Adaptive level changed |
| `sfx_triggered(event_name, played)` | SFX fired — `played` as returned by `trigger()` (empty for spatial one-shots) |
| `node_changed(event_name, node_id, node_name)` | Active node changed |
| `sub_level_toggled(event_name, sub_name, enabled)` | Sub-level toggled |
| `transition_info(event_name, info)` | Per-phase transition diagnostics — see Transition Info |

```gdscript
PFA.event_started.connect(func(name): print("Started: ", name))
PFA.transition_info.connect(_on_transition_info)
```

---

## Spatial Audio

The model: **the editor authors how an event behaves in space; the game only passes positions.** Studio writes a per-event `spatial` block into the config (with an optional `godot {}` override authored on the Godot tab — Godot-native attenuation models); at runtime the engine merges, in order:

```
engine defaults ← event.spatial ← event.spatial.godot ← per-call config (game override)
```

so most game code never touches spatial parameters at all.

### Setup

```gdscript
PFA.set_world_scale(1.0)     # game units per audio meter (100.0 for a pixel game)

func _process(_dt):          # each frame
    # 2D:
    PFA.set_listener_2d(player.global_position)
    # 3D (position + forward + up, e.g. from the camera):
    var xf := camera.global_transform
    PFA.set_listener_3d(xf.origin, -xf.basis.z, xf.basis.y)
```

The engine owns an internal `AudioListener2D`/`AudioListener3D` (made current on first use) — you feed it positions; it stays independent of your camera setup.

### One-shots at a position

```gdscript
PFA.trigger_spatial("coin", pos.x, pos.y)                                # 2D
PFA.trigger_spatial_3d("ball_hit", pos.x, pos.y, pos.z)                  # 3D
PFA.trigger_spatial_3d("ball_hit", pos.x, pos.y, pos.z, {"intensity": 0.8})
```

Returns the first spawned voice (`AudioStreamPlayer2D`/`3D`) or `null`. Multi-track events spawn one voice per track.

### Emitters — voices that follow a game object

```gdscript
var em: PFASpatialEmitter = PFA.create_emitter_3d("ball_roll")   # optional config dict
em.set_position_3d(ball.x, ball.y, ball.z)    # or set_position_2d — update each frame
em.trigger()                                  # fire the bound event (loops keep sounding)

# when the object stops / dies:
em.destroy()        # stops its voices via the event's authored release_fade
em.destroy(0.0)     # "as fast as click-free allows" (30 ms floor), not a hard cut
```

A looping event (authored `loop {enabled, mode}` in Studio) keeps sounding until `destroy()` — `"seamless"` is a native gapless loop, `"smart"` re-triggers per cycle with fresh variation picks and play-chance rolls, crossfaded over 80 ms.

### Config keys (authored block and per-call override use the same names)

```gdscript
{
  "mode": "2D" | "3D",
  "model": "inverse" | "inverse_square" | "logarithmic" | "linear" | "disabled",
  "min_distance": 1.0,       # reference distance for full volume (3D unit_size)
  "max_distance": 50.0,      # audible radius
  "rolloff": 1.0,            # falloff exponent (2D attenuation / 3D slope)
  "max_pan": 1.0,            # 0..1 — cap on stereo separation
  "doppler": 0.0,            # 0 = off, > 0 = on (physics-interpolated)
  "lpf_enabled": true, "lpf_cutoff_hz": 5000.0, "lpf_db": -24.0,
  "intensity": 1.0,          # not spatial config — per-trigger velocity, see below
}
```

- **Distance models** map to Godot's native `AudioStreamPlayer3D` attenuation models; the web vocabulary (`exponential` etc.) is accepted too, so one authored config drives both engines.
- **2D panning** is normalized against the project's `audio/general/2d_panning_strength`, so `max_pan: 1.0` means truly full L/R regardless of project defaults.
- **Distance LPF** = Godot's native attenuation filter (air absorption), on by default at Godot's own defaults (5000 Hz / −24 dB). The web engine deliberately matches this.
- Godot has no built-in binaural HRTF — `panning_model` is informational here (the web engine uses it). **Author spatial events as MONO samples**; a stereo file can't be truly positioned.

### Voice management & stopping

- **`max_instances`** (authored per event, default 8): ONE pool per event — flat `trigger()` voices and spatial voices count together. At the cap the **least audible** voice is stolen (score = per-voice gain incl. intensity × distance attenuation at the listener; equal scores → oldest dies), released through its normal click-free path. A candidate quieter than every live voice is **rejected** — it doesn't start and kills nothing (a rejected trigger also doesn't stamp the cooldown clock). So a full-strength hit is never cut by weak follow-ups, and `max_instances` can be lowered for performance without eating the loudest voices.
- **Stopping is never a hard cut**: every spatial voice release — `destroy(0.0)`, `stop_all(0.0)`, voice steal — is floored to **30 ms** (`_STOP_FLOOR_SEC`). A loop cut mid-wave is a step discontinuity (an audible click); one-shots simply end and never hit this path.
- **`release_fade`** (authored per event): the default stop fade wherever no explicit fade is passed. *How* an event ends lives in the editor, not in game code.
- **`PFA._spatial.clear_all()`** exists for scene teardown: it hard-frees every voice and emitter with **no fade by design** — fade before `change_scene` if you need it silent.

### Intensity (per-trigger velocity)

A normalized 0..1 "how hard was the hit" — like a MIDI note's velocity:

```gdscript
PFA.trigger("coin", {"intensity": 0.4})
PFA.trigger_spatial_3d("ball_hit", p.x, p.y, p.z, {"intensity": clampf(rel_speed / 5.0, 0.0, 1.0)})
```

The mapping is **authored in Studio** (the event's `intensity` block: `vol_db` / `pitch_st` ranges + curves) and applied per voice on top of the random variation. Events without an intensity block ignore the value — the game can always pass it. Identical math in the JS engine.

Real-world example (the billiards demo, `games/04_billiards/godot/`): 5 events — cue strike, ball hit, cushion, pocket, rolling loop — where every trigger passes `clampf(speed / max_speed, 0, 1)` and one `create_emitter_3d("ball_roll")` per rolling ball follows it with `set_position_3d` until `destroy()` on stop.

---

## Reverb Zones

Studio can author named **reverb zones** (room, cave, hall…) at project level plus a per-event **send**. On Godot the engine builds them from native audio buses:

- One global bus **`PFA_Reverb`** with an `AudioEffectReverb`, configured from the active zone. Events with an authored `reverb: { enabled, send > 0 }` route their voices to it; everything else stays on Master (dry).
- `default_zone` from the config is applied automatically at load — a fully editor-driven game never calls the API at all.

| Method | Description |
|--------|-------------|
| `PFA.set_reverb_zone(name, fade := 0.5)` | Switch zones: room character snaps, wet ramps click-free over `fade`. `null`/`""` ⇒ dry |
| `PFA.get_reverb_zone() → String` | Active zone name (`""` = dry) |
| `PFA.create_reverb_zone(name, extent, position := Vector3.ZERO, amount := 0.8, uniformity := 0.5) → Area3D` | **Positional 3D reverb** (Godot-only superpower): creates a per-zone bus + `Area3D` box; you parent and place it — 3D spatial voices physically inside get positionally wet, auto-crossfaded by Godot |

### Honest caveats (know before you mix)

- **Freeverb coloration.** Godot's `AudioEffectReverb` is classic Freeverb; its tail has an inherent ringy/metallic tint that grows with big + bright rooms (cave/hangar/arena presets). Not a PFA bug, not fixable from the outside. Designer levers, in order of effectiveness: **lower the zone's `wet`** (cave 0.5 → 0.3 ≈ −5 dB of the effect); cap `room_size` around 0.9 and nudge `damping` up; do **not** reflex-"shrink + darken" — a smaller room *raises* the tonal ringing. Fix the *level*, not the *size*.
- **No RT60 on Godot** — the tail length rides `room_size` (the web engine's `decay` seconds don't apply here). The zone's `godot {}` override block in Studio exists exactly for this: tune the Godot character separately when needed.
- **Predelay is forced to 0** on Godot: the engine's native "predelay" is a feedback comb (it would add a comb tone), not a true predelay. Real predelay is web-only.
- **`damping` is aligned in meaning** across platforms (higher = darker): the addon flips Godot's inverted native parameter for you.
- **Per-event send is on/off routing** on the global path (a player can sit on one bus only); continuous positional wet is what `create_reverb_zone` (Area3D) is for. There is **no 2D positional reverb** (Godot's `Area2D` has no reverb send) — 2D games get the flat global send.
- **Zone switching is click-free**: the character snap only changes bounded scalars, never reallocates delay buffers; only `wet` ramps.

---

## Audio Formats (one Godot-specific trap)

OGG is the safe default for everything — Studio exports it out of the box.

**Don't ship seamless-looping WAVs on Godot**: native WAV looping has a one-frame overread bug ([godotengine/godot#119778](https://github.com/godotengine/godot/issues/119778)) that clicks at the loop seam no matter how clean the file is. The engine's loops are safe as exported (OGG); Studio's **"SFX → WAV"** export toggle is for **one-shot** latency (WAV decodes cheapest) and deliberately leaves looping SFX in OGG. If you hand-convert files, keep that rule.

---

## Live Connect

Real-time tuning from PFA Studio over WebSocket (port **9264**, Studio's Live server). `PFALive` is a node you add — no autoload:

```gdscript
var _live: PFALive

func _ready():
    _live = PFALive.new()
    add_child(_live)
    _live.status_changed.connect(func(c): print("editor: ", c))
    _live.pack_reloaded.connect(_on_pack_reloaded)
    _live.connect_to_editor()          # auto-reconnects every 5 s

func _on_pack_reloaded():
    # config was re-read from disk (after Studio's Sync) — rebuild what you own:
    for em in roll_emitters: em.destroy(0.0)
    roll_emitters.clear()
    PFA.preload_all()
```

- **`debug_only = true` by default** — in a release export `PFALive` is a no-op, so you can leave the wiring in shipping code.
- Handled editor commands: `reload`, `set_volume`, `set_level`, `play`, `stop`, `trigger`, `set_group_volume`, `set_master_volume`, `set_mute`, `duck`, `unduck`.
- Reload flow: `stop_all(0.5)` → 0.6 s settle → `load_pack(PFA.pack_path)` → `pack_reloaded`. If you loaded from a bank, set `PFA.pack_path` to the loose `config.json` so Sync reloads pick up fresh exports.

---

## Musical Timing & Transitions

How the engine performs music (all authored in Studio; nothing here needs game code):

- **Pre-start layers** (FMOD/Wwise pattern): on `play()` all level layers start phase-locked at silence; level switching only ramps player volumes — no `AudioStreamPlayer` creation at runtime.
- **Conductor**: a chained per-event bar tick (`SceneTreeTimer`) from `play()` to `stop()`; each tick reads the current bar duration, so per-node BPM changes apply on the next tick. It drives **play chance** (per-track probability rolled at bar boundaries, committed for N bars — rapid `navigate()` can't pump amplitudes; modes `true_random` / `weighted_history` / `shuffle_bag`), **sample variation switching** at loop boundaries (30 ms equal-power micro-crossfade; algorithms `random` / `weighted` / `no_repeat`), and **quantized transitions** (bar/beat; a new transition cancels a pending one).
- **Transition kinds**: per-connection `kind` — `crossfade` (default), `fade_in` (silence others, ramp target from 0), `fade_out` (ramp all to silence, then a deferred switch; superseding transitions cancel it). Exporter-flattened `fade_out → fade_in` chains carry `entry_fade_duration/curve`, and the engine ramps the new level from 0 instead of hard-cutting.
- **Fade curves**: `linear`, `equal_power` (default), `s_curve`, `exponential`, `logarithmic` — one shared curve implementation across every fade path, same math as the JS engine.
- **Tempo & phase**: per-node `bpm` / `time_signature` update the conductor on entry; `free_tempo` nodes disable quantization (auto-advance falls back to `clip_length × loop_count`); `restart_on_entry: true` resets phase on entry via `seek(0)` (variation pick preserved).
- **Stingers**: a one-shot bundle on a transition, fired at the **start** of the fade (t=0 — covering transients short crossfades would eat), picker `random` / `weighted` / `no_repeat` with independent history per connection. No separate API — a side effect of transitions.

### Transition Info

The `transition_info(event_name, info)` signal fires per phase — `info.phase` is one of:

| Phase | When |
|-------|------|
| `entry_fade` | entry node fade-in started (on `play()`) |
| `start_fade` | event-level authored `start_fade` applied |
| `transition` | a transition dispatched (`kind`, `direction`, from/to nodes, duration, curve) |
| `fade_out_start` | a `fade_out`-kind transition began its fade-out portion |
| `terminal_fade` | terminal fade-out started (manual `stop_terminal()` or auto-fired) |

Useful for debug overlays and parity test harnesses.

---

## Anti-Click Protection

Every start/stop/switch path has a floor — `0` always means "as fast as click-free allows", never a hard cut:

| Path | Protection |
|------|-----------|
| Level ramps / variation switch | 30 ms floor (`_MICRO_FADE_SEC`) |
| Spatial voice release (incl. `destroy(0)`, voice steal) | 30 ms floor (`_STOP_FLOOR_SEC`) |
| Non-spatial SFX voice stop | 20 ms floor |
| Smart-loop cycle seam | 80 ms crossfade |

The JS engine's floors are shorter (10–20 ms) because Web Audio schedules sample-accurately; Godot's frame-based timing needs the wider window (~2 frames at 60 fps).

---

## Versions & Compatibility

This addon versions independently from the rest of the suite (Studio 0.9.x, JS engine 1.15.x — the numbers are not aligned by design). The compatibility contract is the **config schema v1.1**: any PFA Studio 0.9.x export plays on this addon.

## License

**This addon is MIT** — free for commercial and personal use, no attribution required.

It plays packs authored in **PFA Studio**, a separate desktop application with its own license (free to use during the public beta). The pack format is plain JSON — the addon reads a `config.json`, whatever produced it.

- Website: [pitchfoxaudio.com](https://pitchfoxaudio.com)
- Support the project: [Buy Me a Coffee](https://buymeacoffee.com/pitchfoxaudio)
