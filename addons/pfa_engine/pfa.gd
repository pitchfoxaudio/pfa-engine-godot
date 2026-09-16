extends Node

## PFA Engine — PitchFox Audio Engine
## Adaptive music & SFX runtime for Godot.
##
## Usage:
##   PFA.load_pack("res://audio/config.json")
##   PFA.play("main_theme")
##   PFA.set_level("main_theme", 1)
##   PFA.trigger("coin_collect")
##   PFA.crossfade_to("boss_theme", 2.0)
##   PFA.set_event_volume("main_theme", 0.5)
##   PFA.set_group_volume("Music", 0.8)
##   PFA.load_group("Room1")
##   PFA.unload_group("Room1")

# --- Identity ---

## The addon's release, readable from any game script as `PFA.VERSION` — the
## twin of the web engine's `PFA.VERSION`. THE single literal: `plugin.cfg` is
## data Godot reads and `PFALive.ENGINE_VERSION` derives from this line, so the
## version announced over Live Connect can never fall behind the addon.
const VERSION := "0.11.10"

## Highest config-schema minor this addon implements (the "Versions &
## Compatibility" contract is schema v1.1). `_config_refusal` refuses a newer
## minor BEFORE any state commit — that is what keeps the README's "whatever was
## loaded before keeps playing" true for a config from a future Studio.
const _SCHEMA_MINOR_MAX := 1

# --- Signals ---

signal event_started(event_name: String)
signal event_stopped(event_name: String)
signal level_changed(event_name: String, level: int)
## Emitted on every SFX trigger. `played` is one dict per track that fired:
## { track, behavior, variation, variation_count, algo, sample } — lets a game show
## what played (variation / sample / algorithm) without reaching into engine internals.
## Spatial triggers emit an empty array (per-voice report is a follow-up).
signal sfx_triggered(event_name: String, played: Array)
signal node_changed(event_name: String, node_id: String, node_name: String)
signal sub_level_toggled(event_name: String, sub_name: String, enabled: bool)
## Human-readable breadcrumb for every fade/transition decision the engine makes.
## `info` carries `phase` (entry_fade / terminal_fade / fade_out_start / transition),
## `duration`, `curve`, and the node ids/names involved. Useful for debug overlays
## and test harnesses — not a feature flag, safe to ignore in production.
signal transition_info(event_name: String, info: Dictionary)

# --- Config ---

## Verbose runtime diagnostics (node entries, transitions, variation switches,
## stingers, pack/bank loads). Default OFF: a shipped game prints nothing during
## normal playback; errors and warnings always come through regardless.
var debug_logs: bool:
	set(value):
		PFAEvent.debug_logs = value
	get:
		return PFAEvent.debug_logs

var _config: Dictionary = {}
var pack_path: String = ""          # last load_pack path — Live Connect's reload re-reads it
var _events: Dictionary = {}        # event_name -> PFAEvent
var _groups: Dictionary = {}        # group_name -> PFAGroup
var _base_path: String = ""         # base directory for audio files
var _master_volume: float = 1.0
var _loaded: bool = false
var _bank_loader: PFABankLoader = null  # non-null when loaded via load_bank()
var _spatial: PFASpatial = null         # spatial audio manager (created on demand)
var _reverb: PFAReverb = null           # reverb-zone manager (created when a pack ships reverb_zones)

# --- Public API ---

## Structural intake gate — the ONE place a pack is accepted or refused. Returns
## "" when the config may become engine state, otherwise the human reason.
## It refuses input that is not a Studio pack at all (wrong shape, foreign or
## future schema) and stays deliberately tolerant about AUTHORING: a declared but
## empty pack is legal, and unknown extra keys are ignored as always. Without this
## gate every loader reported success for `{}` / `[]` / someone else's JSON, and
## the game only found out much later as missing or silently wrong playback.
## JS parity: PFA._configRefusal.
static func _config_refusal(data: Variant) -> String:
	if not (data is Dictionary):
		return "config is not a JSON object"
	var cfg: Dictionary = data
	if cfg.has("version"):
		var ver: String = str(cfg["version"])
		var parts: PackedStringArray = ver.split(".")
		if parts[0] != "1":
			return "config schema %s is not supported (this engine implements 1.x)" % ver
		# The major alone let a future 1.x minor through, and load_pack
		# then committed it over the working pack. JS parity: _configRefusal.
		if parts.size() > 1:
			var minor: String = parts[1]
			if not minor.is_valid_int():
				return "config schema %s is not supported (this engine implements 1.x)" % ver
			if minor.to_int() > _SCHEMA_MINOR_MAX:
				return "config schema %s is newer than this addon (supports up to 1.%d) — update the addon" % [ver, _SCHEMA_MINOR_MAX]
	elif not cfg.has("events"):
		return "not a PFA pack (neither \"version\" nor \"events\")"
	if cfg.has("events") and not (cfg["events"] is Dictionary):
		return "\"events\" is not an object"
	if cfg.has("groups") and not (cfg["groups"] is Array):
		return "\"groups\" is not an array"
	return ""

## Load-bearing numeric intake. A config carrying INF/NaN/negative where the engine
## multiplies gains or counts voices plays silently wrong instead of failing, so an
## out-of-contract value falls back to the documented default. JS parity: _saneAmp.
static func _sane_amp(value: Variant, fallback: float) -> float:
	if not (value is float or value is int):
		return fallback
	var f: float = float(value)
	if not is_finite(f) or f < 0.0:
		return fallback
	return f

## Load audio pack from config.json exported by PFA Studio.
func load_pack(config_path: String) -> bool:
	var file = FileAccess.open(config_path, FileAccess.READ)
	if file == null:
		push_error("[PFA] Cannot open config: %s" % config_path)
		return false

	var json = JSON.new()
	var err = json.parse(file.get_as_text())
	file.close()

	if err != OK:
		push_error("[PFA] JSON parse error in %s: %s" % [config_path, json.get_error_message()])
		return false

	# Gate BEFORE any engine state moves: a refused pack leaves the currently
	# loaded one playing untouched (a live game must not go silent because a
	# reload pointed at the wrong file).
	var refusal: String = _config_refusal(json.data)
	if refusal != "":
		push_error("[PFA] Refused pack %s: %s" % [config_path, refusal])
		return false

	_config = json.data
	_base_path = config_path.get_base_dir()
	pack_path = config_path
	# Loose pack ⇒ leave bank mode. A previous bank kept its whole buffer resident
	# and release_bank_buffer() would still be aiming at that dead generation.
	_bank_loader = null
	_master_volume = _sane_amp(_config.get("master_volume", 1.0), 1.0)

	# Parse groups
	_groups.clear()
	for group_data in _config.get("groups", []):
		var group = PFAGroup.new()
		group.name = group_data.get("name", "")
		group.volume = group_data.get("volume", 1.0)
		group.event_names = group_data.get("events", [])
		_groups[group.name] = group

	# The outgoing generation goes silent FIRST, spatial half included: spatial
	# voices and smart-loop controllers are standalone nodes under PFASpatial, not
	# children of the event nodes, so freeing the events alone left a seamless
	# spatial loop playing the OLD pack forever with no per-event door left to
	# reach it (stop matches by event object). Emitters survive — they belong to
	# game objects and re-resolve by name. JS parity: _applyConfig stopAll(0).
	if _spatial != null:
		_spatial.stop_all_voices(0.0)

	# Parse events. On a RE-load (Live Connect reload) free the previous
	# generation's event nodes — dict.clear() alone leaks them as children.
	for old in _events.values():
		if is_instance_valid(old):
			old.queue_free()
	_events.clear()
	var events_dict = _config.get("events", {})
	for event_name in events_dict:
		var event_data = events_dict[event_name]
		var event = _create_event(event_name, event_data)
		if event:
			_events[event_name] = event
			add_child(event)

	_setup_reverb()
	_loaded = true
	PFAEvent._dlog("[PFA] Loaded pack: %s (%d events, %d groups)" % [
		config_path, _events.size(), _groups.size()])
	return true

## Load audio pack from .pfabank binary bank (single file, all audio inside).
func load_bank(bank_path: String) -> bool:
	# Parse into a CANDIDATE, exactly like the loose path gates before it moves
	# any state: this used to assign the new loader to _bank_loader up front and
	# null it on refusal, so a damaged second bank evicted the working one. The
	# events keep their own reference and go on playing, which is what hid it —
	# but release_bank_buffer() is guarded by _bank_loader, so the documented way
	# to free the bank's memory silently died for the rest of the session.
	var candidate := PFABankLoader.new()
	if not candidate.load_bank(bank_path):
		return false

	# Same gate as the loose path — a bank whose container parsed fine can still
	# carry a foreign or empty config.
	var refusal: String = _config_refusal(candidate.config)
	if refusal != "":
		push_error("[PFA] Refused bank %s: %s" % [bank_path, refusal])
		return false

	_bank_loader = candidate
	_config = _bank_loader.config
	_base_path = ""  # not used in bank mode
	_master_volume = _sane_amp(_config.get("master_volume", 1.0), 1.0)

	# Parse groups
	_groups.clear()
	for group_data in _config.get("groups", []):
		var group = PFAGroup.new()
		group.name = group_data.get("name", "")
		group.volume = group_data.get("volume", 1.0)
		group.event_names = group_data.get("events", [])
		_groups[group.name] = group

	# Same commit order as load_pack: the outgoing generation's spatial half goes
	# silent before its event nodes are freed (emitters survive by design).
	if _spatial != null:
		_spatial.stop_all_voices(0.0)

	# Parse events. On a RE-load (Live Connect reload) free the previous
	# generation's event nodes — dict.clear() alone leaks them as children.
	for old in _events.values():
		if is_instance_valid(old):
			old.queue_free()
	_events.clear()
	var events_dict = _config.get("events", {})
	for event_name in events_dict:
		var event_data = events_dict[event_name]
		var event = _create_event(event_name, event_data)
		if event:
			event._bank_loader = _bank_loader
			_events[event_name] = event
			add_child(event)

	_setup_reverb()
	_loaded = true
	PFAEvent._dlog("[PFA] Loaded bank: %s (%d events, %d groups)" % [
		bank_path, _events.size(), _groups.size()])
	return true

## Release raw bank data after preloading (compressed bytes stay in AudioStreams).
func release_bank_buffer() -> void:
	if _bank_loader:
		_bank_loader.release_bank_buffer()

## Preload every event's samples up front (parity with the JS engine's preloadAll).
## Without this, an event loads ALL its variation streams synchronously on its FIRST
## trigger (lazy load). For a multi-variation WAV event that first-trigger load can stall
## the main thread long enough to underrun the audio mixer — heard as a CLICK on the first
## hits after launch, settling once every event is warm (OGG decodes ~10x smaller, so it
## rarely stalls — which is why re-exporting to OGG hid the click). Call once right after
## load_pack()/load_bank(). Safe to call again (load_samples() is idempotent per event).
func preload_all() -> void:
	for event_name in _events:
		var e = _events[event_name]
		if e != null:
			e.load_samples()

## Navigate node graph via trigger name. Returns true if transition matched.
func navigate(event_name: String, trigger: String) -> bool:
	var event = _get_event(event_name)
	if event == null:
		return false
	# node_changed is emitted from the event's node_applied signal at the moment
	# the move actually happens — on the bar/beat path that is LATER than this
	# call, and current_node still holds the old node here.
	return event.navigate(trigger)

## Toggle sub-level on/off with optional fade.
func toggle_sub_level(event_name: String, sub_name: String, enabled: bool, fade: float = 0.5) -> void:
	var event = _get_event(event_name)
	if event == null:
		return
	# Outcome signal: the delegate answers whether the toggle was
	# actually applied — a stopped event or an unknown sub-level is a no-op and
	# must not be announced as "toggled".
	if event.toggle_sub_level(sub_name, enabled, fade):
		sub_level_toggled.emit(event_name, sub_name, enabled)

## Get current node ID for a node-graph event.
func get_current_node(event_name: String) -> String:
	var event = _get_event(event_name)
	if event == null:
		return ""
	return event.get_current_node_id()

## Duck event volume (remembers original).
func duck(event_name: String, level: float = 0.3, fade: float = 0.5) -> void:
	var event = _get_event(event_name)
	if event == null:
		return
	event.duck(level, fade)
	_refresh_spatial(event, fade)

## Restore event volume after duck.
func unduck(event_name: String, fade: float = 0.5) -> void:
	var event = _get_event(event_name)
	if event == null:
		return
	event.unduck(fade)
	_refresh_spatial(event, fade)

## Play a music event (looped). Only one music event plays at a time.
func play(event_name: String) -> void:
	var event = _get_event(event_name)
	if event == null:
		return

	if event.type != "music":
		push_warning("[PFA] Use trigger() for SFX events")
		trigger(event_name)
		return

	# Stop other music events
	for name in _events:
		var e = _events[name]
		if e.type == "music" and e.is_playing and name != event_name:
			e.stop_playback()
			event_stopped.emit(name)

	event.start_playback()
	event_started.emit(event_name)

## Crossfade from current music to another music event.
func crossfade_to(event_name: String, duration: float = 2.0) -> void:
	var new_event = _get_event(event_name)
	if new_event == null or new_event.type != "music":
		return

	# Find currently playing music
	var old_event: PFAEvent = null
	for name in _events:
		var e = _events[name]
		if e.type == "music" and e.is_playing and name != event_name:
			old_event = e
			break

	if old_event:
		old_event.fade_out(duration)

	# The explicit duration must own the fresh-start entry ramp: a plain
	# fade_in() tween would be killed by start_playback()'s own 20 ms
	# anti-click ramp, leaving the new side at full volume almost instantly.
	new_event._entry_fade_override = {"duration": duration, "curve": "equal_power"}
	new_event.start_playback()
	event_started.emit(event_name)

## Stop an event. The fade is resolved from the event's authored `release_fade`
## (FMOD AHDSR-release / Wwise Stop fade) unless `fade_time` is given (>= 0), in
## which case it is a per-call OVERRIDE (Wwise-style). Either way duration 0 → an
## immediate stop (the engine keeps its _MICRO_FADE_SEC 30ms anti-click floor). Back-compat: an
## event with no authored release_fade defaults to {0}, so stop(name) with the
## default -1 sentinel stops immediately exactly as before.
func stop(event_name: String, fade_time: float = -1.0) -> void:
	var event = _get_event(event_name)
	if event == null:
		return

	# Explicit fade_time >= 0 overrides; the -1 default falls back to release_fade.
	var dur: float = fade_time
	var curve: String = str(event.release_fade.get("curve", "equal_power"))
	if fade_time < 0.0:
		dur = float(event.release_fade.get("duration", 0.0))
	# SFX events have no looping music playback — they spawn one-shot voices via trigger(). A
	# stop() on one (a held flight / loop sound the game ends on a cue) must fade THOSE voices;
	# the web engine silences them through event._eventGain, Godot's standalone SFX players don't
	# route through a shared gain node, so it has to be explicit (JS↔Godot parity).
	if event.type == "sfx":
		event.stop_sfx_voices(dur, curve)
		# Spatial voices of this event (trigger_spatial / emitters) are standalone nodes
		# too — release them + their smart controllers. Web parity-of-outcome: there the
		# shared event gain silences spatial voices on the same stop(). Emitters survive.
		if _spatial != null:
			_spatial.stop_event_voices(event, maxf(dur, 0.02) * 1000.0)
	elif dur > 0.0:
		event.fade_out(dur, curve)
	else:
		event.stop_playback()
	event_stopped.emit(event_name)

## Stop honoring the current node's terminal_fade (Transition Kinds v2). Falls back
## to a plain stop() with `default_fade` if no terminal fade is authored on the node.
## Typical use: button bound to a "stop with fade-out" action that respects whatever
## the composer set up in the editor.
func stop_terminal(event_name: String, default_fade: float = 0.0) -> void:
	var event = _get_event(event_name)
	if event == null:
		return
	if event.stop_with_terminal_fade():
		event_stopped.emit(event_name)
	else:
		stop(event_name, default_fade)

## Live-mixer helper: re-bake an event's playing spatial voices (no-op without spatial).
func _refresh_spatial(event, fade: float = 0.05) -> void:
	if _spatial != null:
		_spatial.refresh_event_voices(event, fade)


## Stop all playing events — music AND spatial voices/smart-loops. Emitters
## SURVIVE (they belong to game objects); JS PFA.stopAll parity. The Live
## Connect reload path relies on this exact split.
func stop_all(fade_time: float = 0.0) -> void:
	for name in _events:
		stop(name, fade_time)
	if _spatial != null:
		_spatial.stop_all_voices(fade_time * 1000.0)

## Trigger a SFX event (one-shot). `options` may carry { intensity: 0..1 } — per-trigger
## hit strength (like a MIDI note's velocity); the event's authored intensity curve maps it
## to a per-voice gain + pitch offset. Omitted ⇒ full strength (1.0). Returns a played-report
## Array (one dict per track that fired: { track, behavior, variation, variation_count, algo,
## sample }). JS: PFA.trigger(eventName, { intensity }).
func trigger(event_name: String, options: Dictionary = {}) -> Array:
	var event = _get_event(event_name)
	if event == null:
		return []

	var played: Array = event.trigger_sfx(options)
	# Outcome signal: `sfx_triggered` means an SFX fired. A refused
	# trigger — cooldown, cap, every chance roll failed — is not an outcome: the
	# caller sees the [] and listeners hear nothing.
	if not played.is_empty():
		sfx_triggered.emit(event_name, played)
	return played

## Set the adaptive level for an event (e.g. calm=0, action=1).
func set_level(event_name: String, level: int) -> void:
	var event = _get_event(event_name)
	if event == null:
		return

	# level_changed is emitted from the event's level_applied signal at the moment
	# the switch actually happens (instant now; quantized at the boundary).
	event.set_level(level)

## Get current level of an event.
func get_level(event_name: String) -> int:
	var event = _get_event(event_name)
	if event == null:
		return 0
	return event.current_level

## Set event volume (0.0 - 1.0+).
func set_event_volume(event_name: String, volume: float) -> void:
	var event = _get_event(event_name)
	if event == null:
		return
	event.set_volume(volume)   # bare `event.volume = v` skipped the live re-apply
	_refresh_spatial(event)

## Set group volume (0.0 - 1.0+).
func set_group_volume(group_name: String, volume: float) -> void:
	if group_name in _groups:
		_groups[group_name].volume = volume
		# Apply to all events in group
		for event_name in _groups[group_name].event_names:
			var event = _get_event(event_name)
			if event:
				event._group_volume = volume
				event._apply_event_gain_to_all_active()
				_refresh_spatial(event)

## Mute/unmute a group.
func set_group_mute(group_name: String, mute: bool) -> void:
	if group_name in _groups:
		_groups[group_name].mute = mute
		for event_name in _groups[group_name].event_names:
			var event = _get_event(event_name)
			if event:
				event._group_mute = mute
				event._apply_event_gain_to_all_active()
				_refresh_spatial(event)

## Set master volume (0.0 - 1.0+).
func set_master_volume(volume: float) -> void:
	_master_volume = volume
	for name in _events:
		_events[name]._master_volume = volume
		_events[name]._apply_event_gain_to_all_active()
		_refresh_spatial(_events[name])

## Load only events belonging to a specific group (for room-based loading).
func load_group(group_name: String) -> void:
	if group_name not in _groups:
		push_warning("[PFA] Group not found: %s" % group_name)
		return

	for event_name in _groups[group_name].event_names:
		var event = _get_event(event_name)
		if event:
			event.load_samples()

## Unload samples for a group (free memory).
func unload_group(group_name: String) -> void:
	if group_name not in _groups:
		return

	for event_name in _groups[group_name].event_names:
		var event = _get_event(event_name)
		if event:
			event.unload_samples()

## Check if an event is currently playing.
func is_playing(event_name: String) -> bool:
	var event = _get_event(event_name)
	if event == null:
		return false
	return event.is_playing

## Get list of all event names.
func get_event_names() -> Array:
	return _events.keys()

## Get list of all group names.
func get_group_names() -> Array:
	return _groups.keys()

# --- Spatial Audio ---

## Set game world scale (game units per audio meter / per audio unit). JS: setWorldScale.
func set_world_scale(units: float) -> void:
	_ensure_spatial()
	_spatial.set_world_scale(units)

## Set the 2D listener world position (pixels). Call every frame. Drives an internal
## AudioListener2D — the engine owns the listener independent of any camera. JS: setListener2D.
func set_listener_2d(pos: Vector2) -> void:
	_ensure_spatial()
	_spatial.set_listener_2d(pos)

## Set the 3D listener world position + orientation (-Z forward, +Y up). Call every frame.
## JS: setListener3D.
func set_listener_3d(pos: Vector3, forward: Vector3 = Vector3(0, 0, -1), up: Vector3 = Vector3(0, 1, 0)) -> void:
	_ensure_spatial()
	_spatial.set_listener_3d(pos, forward, up)

## Trigger a spatial SFX at a 2D position — one-shot, or a loop per the event's authored
## `loop`. Attenuation/panning come from the event's `spatial` config; a game `config`
## overrides it. Returns the first voice, or null. JS: triggerSpatial.
func trigger_spatial(event_name: String, x: float, y: float, config: Dictionary = {}) -> Object:
	_ensure_spatial()
	var event = _get_event(event_name)
	if event == null:
		return null
	var voice = _spatial.trigger_spatial_2d(event, x, y, config)
	# Emits only when a voice actually spawned. The payload stays
	# `[]` — spatial voices carry no report (the round-05 parity shape).
	if voice != null:
		sfx_triggered.emit(event_name, [])
	return voice

## Trigger a spatial SFX at a 3D position. Returns the first voice, or null.
func trigger_spatial_3d(event_name: String, x: float, y: float, z: float, config: Dictionary = {}) -> Object:
	_ensure_spatial()
	var event = _get_event(event_name)
	if event == null:
		return null
	var voice = _spatial.trigger_spatial_3d(event, x, y, z, config)
	if voice != null:
		sfx_triggered.emit(event_name, [])
	return voice

## Create a persistent 2D spatial emitter for a moving object: set its position + trigger it,
## and its voices follow. Returns a PFASpatialEmitter (null if the event is unknown). JS:
## createEmitter. The game passes only POSITION — attenuation/loop/release live on the event.
func create_emitter_2d(event_name: String, config: Dictionary = {}) -> PFASpatialEmitter:
	_ensure_spatial()
	if _get_event(event_name) == null:
		return null
	return _spatial.create_emitter_2d(event_name, config)

## Create a persistent 3D spatial emitter.
func create_emitter_3d(event_name: String, config: Dictionary = {}) -> PFASpatialEmitter:
	_ensure_spatial()
	if _get_event(event_name) == null:
		return null
	return _spatial.create_emitter_3d(event_name, config)

# --- Reverb (T1 room ambience) ---

## Switch the active GLOBAL reverb zone. `name` = a zone from the pack's `reverb_zones`
## (room / hall / cave / …); null or "" → dry. Ramps the wet level click-free over `fade`
## seconds. No-op when the pack ships no reverb zones. JS parity: setReverbZone.
func set_reverb_zone(name, fade: float = 0.5) -> void:
	if _reverb == null or not _reverb.has_zones():
		return
	_reverb.set_active_zone(name, fade)

## Optional POSITIONAL 3D reverb (Godot-only superpower): build an Area3D bound to a per-zone
## reverb bus. 3D spatial voices physically inside it get positionally wet, auto-crossfaded
## across overlapping zones, with zero per-frame engine code. Parent + position the returned
## Area3D in your scene. null if the zone is unknown or the pack has no reverb.
func create_reverb_zone(name: String, extent: Vector3, position: Vector3 = Vector3.ZERO, amount: float = 0.8, uniformity: float = 0.5) -> Area3D:
	if _reverb == null or not _reverb.has_zones():
		return null
	return _reverb.create_zone_area(name, extent, position, amount, uniformity)

## Currently active global reverb zone name ("" = dry). Mostly for debug/tests.
func get_reverb_zone() -> String:
	if _reverb == null:
		return ""
	return _reverb.get_active_zone()

func _ensure_spatial() -> void:
	if _spatial == null:
		_spatial = PFASpatial.new()
		_spatial.name = "PFASpatial"
		_spatial._pfa = self
		add_child(_spatial)

# --- Internal ---

func _get_event(event_name: String) -> PFAEvent:
	if event_name not in _events:
		push_warning("[PFA] Event not found: %s" % event_name)
		return null
	return _events[event_name]

func _ensure_reverb() -> void:
	if _reverb == null:
		_reverb = PFAReverb.new()
		_reverb.name = "PFAReverb"
		add_child(_reverb)

## Reverb (T1): build AudioServer reverb buses from the pack's `reverb_zones` and route
## opted-in event voices to the global reverb bus. No zones ⇒ tear down any prior buses and
## leave every voice on "Master" (byte-identical to a pack without reverb). Called from both
## load paths AFTER events are created (routing needs each event's `reverb` block).
func _setup_reverb() -> void:
	var rz = _config.get("reverb_zones", {})
	var zones = rz.get("zones", {}) if rz is Dictionary else {}
	var has_zones: bool = zones is Dictionary and not zones.is_empty()
	if has_zones:
		_ensure_reverb()
		_reverb.configure(rz)        # configure() frees the prior generation first (reload-safe)
		_apply_reverb_routing()
	elif _reverb != null:
		_reverb.free_all()           # a reload that dropped reverb: clear old buses
		for name in _events:
			_events[name]._voice_bus = "Master"

## Stamp each event's _voice_bus: the global reverb bus when it opts in (enabled + send>0),
## else "Master" (dry). Voices read this at every AudioStreamPlayer creation site.
func _apply_reverb_routing() -> void:
	if _reverb == null or not _reverb.has_zones():
		return
	for name in _events:
		var ev = _events[name]
		var rv = ev.reverb
		if rv is Dictionary and bool(rv.get("enabled", false)) and float(rv.get("send", 0.0)) > 0.0:
			ev._voice_bus = PFAReverb.GLOBAL_BUS
		else:
			ev._voice_bus = "Master"

func _create_event(event_name: String, data: Dictionary) -> PFAEvent:
	var event = PFAEvent.new()
	event.name = event_name
	event.type = data.get("type", "music")
	event.volume = _sane_amp(data.get("volume", 1.0), 1.0)
	event._master_volume = _master_volume
	event._base_path = _base_path

	# Bubble transition_info up with event_name attached so subscribers don't need
	# a per-event connection.
	event.transition_info.connect(func(info: Dictionary):
		transition_info.emit(event_name, info)
	)

	# node_changed / level_changed bubble from the APPLY-point signals, so
	# subscribers always see the post-change state — never a scheduled move
	# (navigate/auto/fade_out all funnel through node_applied), and never a
	# level number the event hasn't reached yet.
	event.node_applied.connect(func(node_id: String, node_name: String):
		node_changed.emit(event_name, node_id, node_name)
	)
	event.level_applied.connect(func(level: int):
		level_changed.emit(event_name, level)
	)

	# Find group volume
	for group_name in _groups:
		if event_name in _groups[group_name].event_names:
			event._group_volume = _groups[group_name].volume
			break

	# Per-event Start (play) / Release (stop) fades — both event types (common path).
	event.start_fade = data.get("start_fade", {"duration": 0.0, "curve": "equal_power"})
	event.release_fade = data.get("release_fade", {"duration": 0.0, "curve": "equal_power"})

	# Per-event spatial attenuation + loop (editor-authored). Same plumbing as the fades:
	# read here, consumed by the spatial path (PFASpatial). Both event types (opt-in).
	event.spatial = data.get("spatial", {})
	event.loop = data.get("loop", {})
	# Per-event reverb send (T1). Routing (which bus this event's voices play on) is stamped
	# later by _setup_reverb() once the reverb bus exists. { enabled, send }.
	event.reverb = data.get("reverb", {})
	# Per-event intensity / velocity (editor-authored). Per-trigger hit strength mapped
	# by an authored curve. Read by trigger()/spatial via PFATrack.intensity_gain_pitch.
	event.intensity = data.get("intensity", {})

	# Music-specific
	if event.type == "music":
		event.bpm = data.get("bpm", 120)
		event.time_signature = data.get("time_signature", [4, 4])
		event.fade_duration = data.get("fade_duration", 2.0)
		event.fade_curve = data.get("fade_curve", "equal_power")
		event.switch_quantization = data.get("switch_quantization", "bar")

	# SFX-specific
	if event.type == "sfx":
		event.cooldown_ms = _sane_amp(data.get("cooldown_ms", 0.0), 0.0)
		# 0 stays 0 — the documented "uncapped" value; only INF/NaN/negative
		# (which would silently uncap an authored ceiling) fall back to the default.
		event.max_instances = int(_sane_amp(data.get("max_instances", 8), 8.0))

	# Levels
	event.levels = []
	for level_data in data.get("levels", []):
		event.levels.append(level_data.get("name", "Level"))

	# Tracks — populated through event to reuse single populate routine (also used for sub-levels).
	for track_data in data.get("tracks", []):
		var track := PFATrack.new()
		event._populate_track_from_data(track, track_data)
		event.tracks.append(track)

	# Node graph
	if data.get("use_nodes", false):
		event.use_nodes = true
		event._node_graph_data = data.get("node_graph", {})

	# Sub-levels (parses sub-level tracks into _sub_level_tracks dict).
	if "sub_levels" in data:
		event.parse_sub_levels(data)

	return event
