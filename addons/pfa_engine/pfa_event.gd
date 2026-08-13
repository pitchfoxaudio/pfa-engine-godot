class_name PFAEvent
extends Node

## Human-readable breadcrumb for each transition/fade decision (entry_fade,
## terminal_fade, crossfade/fade_in/fade_out dispatch). Carries a Dictionary so
## new fields can be added without breaking subscribers. Bubbled up by PFA
## autoload as `PFA.transition_info(event_name, info)`.
signal transition_info(info: Dictionary)

## Fired when the node graph moves WITHOUT a navigate() call (auto-advance).
## Bubbled by the PFA autoload as `node_changed` — JS parity: web fires
## onNodeChanged from _executeAutoAdvance "same as navigate()".
signal auto_advanced(node_id: String, node_name: String)

## Runtime event — manages playback of tracks for one music/sfx event.
## Faithful port of JS PFAEvent (pfa-engine/js/src/index.js L1257-2351).
##
## Godot adaptations:
##   - No Web Audio gain chain → one AudioStreamPlayer per (track, level, variation).
##     That player's volume_db combines: level-gate × variation-gate × chance-gate × event-gain.
##   - Pre-start model: all (track, level, variation) streams play from t=0 at -80 dB.
##     Level changes = volume tweens only. Phase stays aligned forever.
##   - source.start(when, offset) has ~11ms jitter in Godot (AudioServer mix boundary).
##     We accept this; it's below perceptual threshold for long loops.
##   - Quantized scheduling uses SceneTreeTimer + create_tween.kill() for splicing.

# --- Config ---

var type: String = "music"                    # "music" or "sfx"
var volume: float = 1.0
var bpm: float = 120.0
var time_signature: Array = [4, 4]
var fade_duration: float = 2.0
var fade_curve: String = "equal_power"
var switch_quantization: String = "instant"  # "instant" | "bar" | "beat"
# Per-event Start (play) / Release (stop) fades — FMOD AHDSR-release / Wwise
# Stop-Action analog. DISTINCT from fade_duration above (that is the LEVEL
# crossfade). start_fade applies on start_playback()/entry — but a node-graph
# entry fade_in marker OVERRIDES it (node > event); release_fade applies on
# stop(), overridable by the stop() fade arg. { "duration": sec, "curve": str }.
# duration 0 = no musical fade (engine keeps its _MICRO_FADE_SEC 30ms anti-click floor).
var start_fade: Dictionary = {"duration": 0.0, "curve": "equal_power"}
var release_fade: Dictionary = {"duration": 0.0, "curve": "equal_power"}
# Per-event SPATIAL attenuation authored in the editor (config.json `spatial` block,
# snake_case). Read by the spatial path (PFASpatial) as the DEFAULT spatial "how"; a
# game-passed config still overrides. Empty/disabled ⇒ engine falls back to its spatial
# defaults (zero behaviour change). Mirrors JS PFAEvent.spatial.
# { enabled, mode, model, min_distance, max_distance, rolloff, panning_model, max_pan }.
var spatial: Dictionary = {}
# Per-event LOOP (SFX, editor-authored) — { enabled, mode: "seamless" | "smart" }. Turns a
# triggered / emitter spatial SFX into a sustained loop. seamless = native gapless loop of
# one variation; smart = re-trigger each clip cycle → switches variation + re-rolls
# randomization, crossfaded. Empty/absent ⇒ unchanged one-shot. Mirrors JS PFAEvent.loop.
var loop: Dictionary = {}
# Per-event REVERB send (T1 room ambience, editor-authored) — { enabled, send }. send 0..1 =
# how wet this event gets in the active reverb zone; 0/disabled means voices stay dry on "Master".
# The reverb CHARACTER (room size/decay/damping) is a project-level zone selected at runtime
# (PFA.set_reverb_zone). Mirrors JS PFAEvent.reverb.
var reverb: Dictionary = {}
# Per-event INTENSITY / velocity (editor-authored) — { enabled, vol_db:[a,b], vol_curve,
# pitch_st:[a,b], pitch_curve }. Per-trigger hit strength: the game passes a normalized
# intensity 0..1 to trigger()/trigger_spatial(); this authored curve maps it to a per-voice
# gain + pitch offset OVER the random variation. Empty/disabled ⇒ no scaling (a bare trigger
# = full strength). Mirrors JS PFAEvent.intensity. Read via PFATrack.intensity_gain_pitch.
var intensity: Dictionary = {}
# Audio bus EVERY voice of this event plays on. "Master" by default (dry); set to the global
# reverb bus (PFAReverb.GLOBAL_BUS) by the PFA autoload when the event opts into reverb
# (enabled + send>0 + the pack ships reverb_zones). Read at each AudioStreamPlayer creation site
# (music / sfx / sub-level / spatial). No zones means it stays "Master" = byte-identical to today.
var _voice_bus: String = "Master"
var cooldown_ms: float = 0.0
var max_instances: int = 8
var levels: Array = []                        # [String]
var tracks: Array = []                        # [PFATrack]

# --- Node Graph ---

var use_nodes: bool = false
var _node_graph_data: Dictionary = {}
var current_node: String = ""
var _auto_advance_timer: SceneTreeTimer = null
var _pending_level_switch: SceneTreeTimer = null
var _pending_node_transition: SceneTreeTimer = null
var _fade_out_timer: SceneTreeTimer = null
# Transition Kinds v2: fade_out → timer for deferred instant-switch to target
# after OLD finishes fading. Editor analogue: _pending_deferred_navigate in
# core/music_event.py:84. Gates auto-advance during the exit fade window.
var _pending_fade_out_switch: SceneTreeTimer = null

# Generation token guarding stop_playback()'s deferred player teardown against a
# start_playback() landing inside the 25 ms anti-click window (replay race).
# JS parity: PFAEvent._stopGen (fix cab3407). Mirrors the FMOD/Wwise per-voice
# lifecycle — a new voice supersedes the previous one's pending release.
var _stop_gen: int = 0

# Manual clip-window wrap driver for OGG/MP3 music voices whose file outruns the
# clip (encoder padding / authored region) — those formats have no loop-END API.
# player INSTANCE ID (int) → { anchor: float (wall-clock grid origin), len, offset,
# gen }. Keyed by id, not the object: freed-Object keys dangle, and a freed-Object
# capture in the tree-owned timer lambda prints "Lambda capture freed" at call time.
# JS parity: source.loopEnd = sourceOffset + sourcePlayLength.
var _clip_wrap_state: Dictionary = {}

# --- Sub-levels ---

var _sub_level_data: Dictionary = {}      # from config: { level_idx_str: [{ name, volume, tracks[] }] }
var _sub_level_tracks: Dictionary = {}    # "levelIdx_subName" -> { name, level_index, volume, tracks: [PFATrack] }
var _sub_level_states: Dictionary = {}    # subName -> { enabled, players[], tracks[] }

# --- Conductor (inline — mirrors JS _startConductor / _conductorTick) ---

var _conductor_loop_timer: SceneTreeTimer = null  # bar-interval timer
var _bar_counter: int = 0
var _bar_duration_sec: float = 2.0
## Per-track play_chance state, one verdict per LEVEL (fabric model — background
## levels keep rerolling while inactive; entry reads the target level's live verdict):
## { track_idx: { level(int): { playing, locked_until, next_reroll_bar } } }
var _track_chance_state: Dictionary = {}

# --- Runtime ---

var is_playing: bool = false
var current_level: int = 0
var _base_path: String = ""
var _master_volume: float = 1.0
var _group_volume: float = 1.0
var _group_mute: bool = false
var _bank_loader: PFABankLoader = null
var _samples_loaded: bool = false
var _play_start_time: float = 0.0
## −∞ epoch, NOT 0.0: ticks start at process launch, so a 0.0 init silently muted
## any event whose cooldown_ms exceeded the game's uptime at first trigger
## (uptime − 0 < cooldown). Found by the sess122 voice-stealing red suite.
var _last_trigger_time_ms: float = -1.0e12
var _active_sfx_count: int = 0

# --- Event Gain (anti-click, duck, fadeIn/fadeOut) ---
## _event_gain_amp ∈ [0,1]. All active-player volume_db gets this applied multiplicatively.
var _event_gain_amp: float = 0.0
var _event_gain_tween: Tween = null
var _duck_saved_volume: float = -1.0
var _duck_target_amp: float = -1.0   # absolute event-gain target while ducked; <0 = not ducked (spatial voices fold it)

# --- Continuous-playback storage ---
## _track_players[track.name][level_idx] = {
##   "players": Array[AudioStreamPlayer],  # one per variation
##   "active": int,                         # active variation index
## }
var _track_players: Dictionary = {}

## Per-(track, level) gain state for splice tweens.
## _track_level_state[track.name][level_idx] = {
##   "tween": Tween, "target_amp": float, "start_time": float, "end_time": float, "from_amp": float,
##   "curve": String
## }
## target_amp here is the pure "level gate" (track.volume if active else 0, pre-event-gain).
## from/start/end/curve describe the CURRENT fade's full trajectory — enough to hand a live
## fade over to another variation player (_resume_fade_tween) without restarting it.
var _track_level_state: Dictionary = {}

## Per-track "shared" stream state (always_play / level_conditional). { track.name: Dictionary }
## Shared tracks have ONE player at track-level (no per-level pre-start).
var _track_shared: Dictionary = {}

## Per-track variation bar counter { track.name: { level_key: int } } — level_key or "shared"
var _track_variation_counter: Dictionary = {}

## Per-level phase anchor override — used after restart_on_entry seeks variations to 0.
## Missing key → _calc_next_loop_boundary uses _play_start_time (global event clock).
## Present key → boundary math follows the restarted level's own phase.
## JS doesn't have this because its restart_on_entry is not yet ported; editor has equivalent via
## _apply_restart_on_entry → state._switch_position (music_event.py:572-609).
var _level_phase_anchors: Dictionary = {}

## Bumped on every state transition (_apply_node_transition + fade_out's deferred
## switch). Scheduled per-level timers (variation swap in _switch_variation,
## chance gain ramp in _apply_chance_gain) capture the current gen at schedule
## time; if it differs when the timer fires, the target state is stale and the
## timer is dropped. This is the "revert pending transition" pattern from Wwise
## Music Transition Rules and the spiritual equivalent of Web Audio's
## GainNode.cancelScheduledValues() used by the JS engine in activateLevel
## (pfa-engine/js/src/index.js activateLevel → cancelScheduledValues).
##
## Why needed: Godot's SceneTreeTimer + lambda model means a loop-boundary-bound
## schedule can fire AFTER navigate() has moved current_level to a different
## level. Without the gen check, an "unmute" chance_gain ramp for the OLD level
## raises it back to full volume on top of the NEW level (audible "ghost"
## track). Editor (core/multisample.py) avoids this by using per-tick state
## evaluation with no scheduled callbacks — a deeper refactor we defer.
var _transition_gen: int = 0

## SFX voice list for max_instances tracking: [AudioStreamPlayer]
var _sfx_voices: Array = []

## Spatial voices of THIS event (AudioStreamPlayer2D|3D), registered by
## PFASpatial._spawn_voice and unregistered by its _free_voice — so the
## max_instances cap sees ONE pool: flat + spatial together (JS parity with
## event._activeVoices, where spatial voices join through a stop/isActive shim).
var _spatial_voices: Array = []
## The spatial manager that spawned them (release path for a stolen spatial voice).
var _spatial_mgr = null

## Stinger bundles loaded on load_samples(). Keyed by `${src}::${tgt}` connection key.
## v2 shape: each bundle = { streams: [AudioStream], clips: [Dictionary], volume: float,
## play_chance: int, mode: String, state: { last_idx: int } }. JS parity: _stingerBundles.
var _stinger_bundles: Dictionary = {}


# ══════════════════════════════════════════════════════════════════════
# ── Public API ─────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## Start playing this music event (looped). JS: play()
func start_playback() -> void:
	if type != "music":
		return

	# A fresh play supersedes any pending deferred teardown scheduled by a recent
	# stop_playback() (see there): bump the generation so stop's 25 ms anti-click
	# timer — which re-reads the track's CURRENT players at fire time — won't kill
	# the players this start uses. Inside that window _prestart_track_level_specific /
	# _play_music_shared early-return on existing state, so the still-playing players
	# carry on as this start's own (nothing leaks when the stale teardown skips).
	# JS parity: play() (_stopGen, cab3407).
	_stop_gen += 1

	if not _samples_loaded:
		load_samples()

	var was_already_playing: bool = is_playing
	is_playing = true

	var entry_node_id: String = ""
	if use_nodes and not _node_graph_data.is_empty():
		entry_node_id = _node_graph_data.get("entry_node", "")

	if not was_already_playing:
		# Fresh start: anti-click event_gain ramp-up from silence (+ authored entry
		# fade if present). On a re-press of Play while already playing, we SKIP
		# this — resetting event_gain to 0 mid-playback creates an audible drop
		# while the active level tries to crossfade. Let the normal transition
		# path below handle the audible ramp instead.
		_play_start_time = _now()
		var entry_fade_dur: float = 0.02
		var entry_fade_curve: String = "equal_power"
		var node_owns_entry: bool = false
		if not entry_node_id.is_empty():
			var en: Dictionary = _node_graph_data.get("nodes", {}).get(entry_node_id, {})
			var ef: Dictionary = en.get("entry_fade", {})
			if not ef.is_empty():
				node_owns_entry = true
				entry_fade_dur = float(ef.get("fade_duration", 0.02))
				entry_fade_curve = str(ef.get("fade_curve", "equal_power"))
				print("[PFA] Entry fade-in: %.2fs (%s)" % [entry_fade_dur, entry_fade_curve])
				transition_info.emit({
					"phase": "entry_fade",
					"duration": entry_fade_dur,
					"curve": entry_fade_curve,
					"to_node": entry_node_id,
					"to_name": str(en.get("name", entry_node_id)),
				})
		# Per-event Start fade — Simple mode, or node mode with no entry fade_in
		# marker (node > event, mirrors editor `_event_start_fade_overridden`).
		if not node_owns_entry and float(start_fade.get("duration", 0.0)) > 0.0:
			entry_fade_dur = float(start_fade.get("duration", 0.0))
			entry_fade_curve = str(start_fade.get("curve", "equal_power"))
			print("[PFA] Start fade-in: %.2fs (%s)" % [entry_fade_dur, entry_fade_curve])
			transition_info.emit({
				"phase": "start_fade",
				"duration": entry_fade_dur,
				"curve": entry_fade_curve,
			})
		_set_event_gain_amp(0.0001)
		# _effective_event_amp(): a fresh start of a live-ducked event settles at
		# the duck level, not full (duck state survives stop()/start).
		_tween_event_gain(_effective_event_amp(), entry_fade_dur, entry_fade_curve)

	if use_nodes and not _node_graph_data.is_empty():
		if not entry_node_id.is_empty():
			# When re-pressing Play, look up the authored (current_node → entry)
			# connection so its fade/curve/quantize/kind are used — matches what
			# the composer set up in the editor. On fresh start, empty dict is
			# fine because _enter_node hits the first-node branch.
			var fs: Dictionary = {}
			if was_already_playing and not current_node.is_empty() and current_node != entry_node_id:
				fs = _find_connection_fade(current_node, entry_node_id)
			_enter_node(entry_node_id, fs)
	else:
		# Simple mode — pre-start level_specific, playMusic shared.
		for track in tracks:
			if track.level_behavior == "always_play" or track.level_behavior == "level_conditional":
				_play_music_shared(track, 0.0)
			else:
				_prestart_track_level_specific(track, 0.0)
				_activate_level(track, current_level, 0.0)

	# Start conductor for play_chance (music only) on fresh starts only —
	# conductor is already ticking if event was already playing.
	if type == "music" and not was_already_playing:
		_start_conductor()

## Resolve the authored fade settings on a graph connection, so a caller that
## navigates src → tgt can honor the composer's duration/curve/quantize/kind
## rather than falling back to the target node's defaults.
## Phase 3 chain fields (entry_fade_duration / entry_fade_curve) are also
## forwarded so fade_out transitions can chain into an entry fade on NEW.
func _find_connection_fade(src: String, tgt: String) -> Dictionary:
	if src.is_empty() or tgt.is_empty():
		return {}
	var connections: Array = _node_graph_data.get("connections", [])
	for c in connections:
		if c.get("source", "") == src and c.get("target", "") == tgt:
			var out: Dictionary = {
				"fade_duration": c.get("fade_duration", fade_duration),
				"fade_curve": c.get("fade_curve", fade_curve),
				"quantize": c.get("quantize", switch_quantization),
				"kind": c.get("kind", "crossfade"),
				"fade_direction": c.get("fade_direction", "both"),
				"stinger": c.get("stinger", null),
			}
			if c.has("entry_fade_duration"):
				out["entry_fade_duration"] = c["entry_fade_duration"]
				out["entry_fade_curve"] = c.get("entry_fade_curve", "equal_power")
			return out
	return {}

## Stop music playback. JS: stop()
func stop_playback() -> void:
	is_playing = false
	current_node = ""
	current_level = 0

	if _auto_advance_timer:
		_auto_advance_timer = null
	if _pending_level_switch:
		_pending_level_switch = null
	if _pending_node_transition:
		_pending_node_transition = null
	if _fade_out_timer:
		_fade_out_timer = null
	if _pending_fade_out_switch:
		_pending_fade_out_switch = null

	_stop_conductor()
	_level_phase_anchors.clear()

	# Anti-click fade-out, THEN free the sources — never the reverse. Godot writes
	# AudioStreamPlayer.volume_db once per game frame (~16.7ms @60fps), so a sub-2-frame
	# fade can't reach silence before a fixed teardown timer fires. The old 20ms fade /
	# 25ms timer (only +5ms margin) hard-cut p.stop() while the per-frame gain was still
	# ~-12dB (red-proven on the WAV pack), truncating a still-audible raw-PCM WAV
	# mid-waveform → broadband click. (OGG's decoder overlap-add masked the same residual;
	# raw WAV exposes it — hence it surfaced only after the OGG→WAV re-export.) Fix: a
	# >=2-frame fade so the ramp actually reaches -80dB, and a teardown timer sized to
	# fade + a render margin (audio output latency + a frame) so the source is cut only
	# after a silent block has been mixed. Mirrors the web engine's ramp-then-stop contract
	# (web is click-free via sample-accurate gain ramps; Godot's per-frame volume_db cannot
	# ramp per-sample, so it must WAIT for the ramp instead of racing it).
	var stop_fade: float = _MICRO_FADE_SEC
	_tween_event_gain(0.0, stop_fade)

	var tracks_ref := tracks
	# Capture the instance ID (int), not the object: the event can be freed inside the
	# teardown window (load_pack reload) and a freed Object capture makes Godot print
	# "Lambda capture freed" BEFORE the lambda even runs. An int can't free;
	# instance_from_id() returns null for the gone event — silent clean exit.
	var self_id := get_instance_id()
	_stop_gen += 1
	var stop_gen := _stop_gen
	var t := get_tree().create_timer(stop_fade + 0.04)
	t.timeout.connect(func():
		var ev = instance_from_id(self_id)
		if ev == null:
			return
		# Skip if a newer start_playback()/stop_playback() superseded this teardown.
		# Otherwise we'd kill the players a replay inside the window reuses — the event
		# would read is_playing=true yet be silent. The replay adopts those players as
		# its own, so nothing leaks when we skip here.
		if ev._stop_gen != stop_gen:
			return
		for track in tracks_ref:
			ev._stop_all_level_players(track)
			ev._stop_shared_player(track)
		ev._stop_all_sub_levels_immediate()
	)

## Trigger a SFX event (one-shot). Returns a played-report Array (one dict per track
## that fired): { track, behavior, variation, variation_count, algo, sample }. JS: trigger()
func trigger_sfx(options: Dictionary = {}) -> Array:
	if type != "sfx":
		return []
	if not _samples_loaded:
		load_samples()

	# Intensity / velocity → per-voice gain + pitch (over the random variation).
	# Resolved ONCE here (the event owns the curve config); every track voice for
	# this trigger gets the same offset. Neutral {1,0} when disabled/absent. A bare
	# trigger (no intensity key) ⇒ 1.0 (full-strength hit). Resolved BEFORE the cap
	# gate — the candidate's audibility score needs it (voice stealing, sess122).
	var iv: Dictionary = PFATrack.intensity_gain_pitch(float(options.get("intensity", 1.0)), intensity)

	if not _check_can_trigger(float(iv.get("gain_mult", 1.0)) * _max_track_volume(), 1.0, tracks.size()):
		return []

	# SFX: no event-gain anti-click ramp, just set active. _effective_event_amp()
	# (not raw volume) so a re-fired one-shot honors an active live duck.
	_set_event_gain_amp(_effective_event_amp())

	var played: Array = []
	for track in tracks:
		var report: Dictionary = _trigger_sfx_track(track, iv)
		if not report.is_empty():
			_sfx_voices.append(report["player"])
			report.erase("player")
			played.append(report)
	return played

## Set adaptive level (quantized or instant). JS: setLevel()
func set_level(level: int) -> void:
	if level < 0 or level >= levels.size():
		return
	if level == current_level:
		return

	if type == "music" and is_playing:
		var quantize: String = switch_quantization
		var boundary: float = _get_quantized_time(quantize)

		if boundary > 0.0:
			_schedule_level_switch(level, boundary)
		else:
			var old_level: int = current_level
			current_level = level
			_crossfade_level(old_level, level)
	else:
		current_level = level

## Navigate node graph via trigger. Returns true if transition matched. JS: navigate()
func navigate(trigger: String) -> bool:
	if not use_nodes or _node_graph_data.is_empty() or current_node.is_empty():
		push_warning("[PFA] Event \"%s\" not in node mode" % name)
		return false

	var connections: Array = _node_graph_data.get("connections", [])
	var nodes: Dictionary = _node_graph_data.get("nodes", {})

	# Find matching transitions from current node.
	var candidates: Array = []
	for c in connections:
		if c.get("source", "") == current_node \
				and c.get("conn_type", "transition") == "transition" \
				and c.get("trigger", "") == trigger:
			candidates.append(c)

	if candidates.is_empty():
		# Fallback: target node by trigger, use nearest outgoing fade.
		var target_id: String = ""
		for node_id in nodes:
			if nodes[node_id].get("trigger", "") == trigger:
				target_id = node_id
				break
		if target_id.is_empty():
			push_warning("[PFA] No transition with trigger \"%s\" from node \"%s\"" % [trigger, current_node])
			return false
		var outgoing: Array = []
		for c in connections:
			if c.get("source", "") == current_node and c.get("conn_type", "transition") == "transition":
				outgoing.append(c)
		var fallback_fade: Dictionary = {}
		if not outgoing.is_empty():
			fallback_fade = {
				"fade_duration": outgoing[0].get("fade_duration", fade_duration),
				"fade_curve": outgoing[0].get("fade_curve", fade_curve),
				"quantize": outgoing[0].get("quantize", switch_quantization),
				"kind": outgoing[0].get("kind", "crossfade"),
				"fade_direction": outgoing[0].get("fade_direction", "both"),
			}
			if outgoing[0].has("entry_fade_duration"):
				fallback_fade["entry_fade_duration"] = outgoing[0]["entry_fade_duration"]
				fallback_fade["entry_fade_curve"] = outgoing[0].get("entry_fade_curve", "equal_power")
		_enter_node(target_id, fallback_fade)
		return true

	# Sort by priority (highest first).
	candidates.sort_custom(func(a, b): return int(b.get("priority", 0)) - int(a.get("priority", 0)) > 0)

	# Filter by probability (take first passing).
	for conn in candidates:
		var prob: float = float(conn.get("probability", 100))
		if randf() * 100.0 <= prob:
			_execute_transition(conn)
			return true

	return false

## Toggle sub-level on/off with fade. JS: toggleSubLevel()
func toggle_sub_level(sub_name: String, enabled: bool, fade_dur: float = 0.5) -> void:
	if not is_playing:
		return
	var key: String = "%d_%s" % [current_level, sub_name]
	var sub: Dictionary = _sub_level_tracks.get(key, {})
	if sub.is_empty():
		push_warning("[PFA] Sub-level \"%s\" not found for level %d" % [sub_name, current_level])
		return

	if enabled:
		_enable_sub_level(sub, fade_dur)
	else:
		_disable_sub_level(sub, sub_name, fade_dur)

	if not _sub_level_states.has(sub_name):
		_sub_level_states[sub_name] = {}
	_sub_level_states[sub_name]["enabled"] = enabled

## Fade in (for crossfade between events). JS: fadeIn()
func fade_in(duration: float, curve: String = "equal_power") -> void:
	_set_event_gain_amp(0.0001)
	# _effective_event_amp(): fading in while live-ducked ramps to the duck level.
	_tween_event_gain(_effective_event_amp(), duration, curve)

## Fade out and stop, honoring the current node's terminal_fade if present (Transition
## Kinds v2 — dangling fade_out at graph end, flattened by the exporter as metadata on
## the source node). Returns true if a terminal fade was triggered; false means caller
## should fall back to stop() or fade_out().
func stop_with_terminal_fade() -> bool:
	if not is_playing or current_node.is_empty():
		return false
	var node: Dictionary = _node_graph_data.get("nodes", {}).get(current_node, {})
	var tf: Dictionary = node.get("terminal_fade", {})
	if tf.is_empty():
		return false
	var dur: float = float(tf.get("fade_duration", 2.0))
	var curve: String = str(tf.get("fade_curve", "equal_power"))
	print("[PFA] Terminal fade-out: %.2fs (%s, node=%s)" % [dur, curve, current_node])
	transition_info.emit({
		"phase": "terminal_fade",
		"duration": dur,
		"curve": curve,
		"from_node": current_node,
		"from_name": str(node.get("name", current_node)),
	})
	fade_out(dur, curve)
	return true

## Fade out and stop. JS: fadeOut()
func fade_out(duration: float, curve: String = "equal_power") -> void:
	_tween_event_gain(0.0, duration, curve)
	var fo_timer: SceneTreeTimer = get_tree().create_timer(duration)
	_fade_out_timer = fo_timer
	var self_id := get_instance_id()   # int capture — freed-object captures print errors
	fo_timer.timeout.connect(func():
		var ev = instance_from_id(self_id)
		if ev == null:
			return
		if ev._fade_out_timer != fo_timer:
			return  # superseded by a newer fade_out or cancelled by stop (JS clearTimeout parity; play() deliberately does NOT cancel — same as web)
		ev._fade_out_timer = null
		if ev.is_playing:
			ev.stop_playback()
	)

## Effective event amp honoring an active live duck (editor mute/solo ride duck):
## while ducked the duck target REPLACES the event volume. This is the
## combined_sfx_db fold hoisted into a single source, and the exact mirror of
## JS PFAEvent._eventGainTarget(). Every writer that re-applies the event gain
## (trigger_sfx / start_playback entry / fade_in) must target THIS, or a re-fired
## voice silently lifts a live mute — the web solo/mute regression, same class.
func _effective_event_amp() -> float:
	return _duck_target_amp if _duck_target_amp >= 0.0 else volume

## Duck event volume (remembers original). JS: duck()
func duck(to: float = 0.3, fade: float = 0.5) -> void:
	if _duck_saved_volume < 0:
		_duck_saved_volume = volume
	_duck_target_amp = to
	_tween_event_gain(to, fade)

## Restore event volume after duck. JS: unduck()
func unduck(fade: float = 0.5) -> void:
	if _duck_saved_volume < 0:
		return
	var target: float = _duck_saved_volume
	_duck_saved_volume = -1.0
	_duck_target_amp = -1.0
	_tween_event_gain(target, fade)

## Set volume (called by PFA.set_event_volume).
func set_volume(v: float) -> void:
	volume = v
	# JS parity (_updateGain): re-target the LIVE event gain. The audible chain
	# reads _event_gain_amp — `volume` is only baked in at play/trigger/fade_in
	# time, so a sustained music event must follow the mixer fader HERE (the
	# per-event fader was dead on playing music while the group fader — a live
	# _group_volume fold — worked). Kill any running event-gain tween first
	# (mirrors JS cancelScheduledValues) and honor an active live duck via
	# _effective_event_amp so a fader move can't lift a live mute.
	if _event_gain_tween and _event_gain_tween.is_valid():
		_event_gain_tween.kill()
	_set_event_gain_amp(_effective_event_amp())

## Get current node ID.
func get_current_node_id() -> String:
	return current_node

## Get current node name.
func get_current_node_name() -> String:
	if current_node.is_empty():
		return ""
	var nodes: Dictionary = _node_graph_data.get("nodes", {})
	return nodes.get(current_node, {}).get("name", "")


# ══════════════════════════════════════════════════════════════════════
# ── Node Graph Internals ──────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## JS: _enterNode(nodeId, fadeSettings)
func _enter_node(node_id: String, fade_settings: Dictionary) -> void:
	var nodes: Dictionary = _node_graph_data.get("nodes", {})
	if not nodes.has(node_id):
		push_warning("[PFA] Node not found: %s" % node_id)
		return

	var node: Dictionary = nodes[node_id]
	var old_node: String = current_node

	# level_index that this node maps to.
	var target_level: int = int(node.get("level_index", 0))

	# Cascade: connection → node → event defaults.
	var fd: float = float(fade_settings.get("fade_duration", node.get("fade_duration", fade_duration)))
	var fc: String = str(fade_settings.get("fade_curve", node.get("fade_curve", fade_curve)))
	var quantize: String = str(fade_settings.get("quantize", node.get("fade_quantize", switch_quantization)))

	if old_node.is_empty():
		# First node — no quantization, apply immediately.
		current_node = node_id
		current_level = target_level
		for track in tracks:
			if track.level_behavior == "always_play" or track.level_behavior == "level_conditional":
				_play_music_shared(track, 0.0)
			else:
				_prestart_track_level_specific(track, 0.0)
				_activate_level(track, target_level, 0.0)
		_stop_all_sub_levels_immediate()
		_sync_bar_duration_to_current_node()
		_schedule_auto_advance(node)
		print("[PFA] Entered node \"%s\" (%s), level=%d" % [node.get("name", ""), node_id, target_level])
	else:
		# Node transition — check quantization.
		var boundary: float = _get_quantized_time(quantize)
		if boundary > 0.0:
			_schedule_node_transition(node_id, node, target_level, fd, fc, fade_settings, boundary)
		else:
			_apply_node_transition(node_id, node, target_level, fd, fc, fade_settings)

## JS: _applyNodeTransition(...)
## Editor Phase 2 parity: dispatches on fade_settings.kind:
##   "crossfade" (default) — OLD and NEW overlap, two-way equal-power ramp over fd.
##   "fade_in"              — OLD hard-cut (anti-click floor), NEW fades 0→vol over fd.
##   "fade_out"             — OLD fades vol→0 over fd; at fade_end instant-switch to target.
##
## Not yet supported (needs exporter changes to emit terminal/chain metadata, see
## master plan): terminal fade_out (no outgoing edge in editor) and fade_out→fade_in
## chain. Those fall back to hard-switch semantics for now.
func _apply_node_transition(node_id: String, node: Dictionary, target_level: int,
		fd: float, fc: String, fade_settings: Dictionary) -> void:
	# Any in-flight fade_out deferred switch is superseded by this new transition.
	if _pending_fade_out_switch:
		_pending_fade_out_switch = null

	# Invalidate any pending per-level scheduled timers (variation swap, chance gain)
	# that were captured under the pre-transition state. Without this, an OLD-level
	# chance_gain timer firing after navigate would re-raise OLD level volume to 1.0
	# on top of the NEW level (observed leak: fx_voce from L2 audible on L1 after
	# 4s crossfade completes). See _transition_gen docs at top of file.
	_transition_gen += 1

	# Capture FROM before helpers mutate current_node — used by transition_info
	# telemetry so subscribers see full "A → B" context.
	var from_node_id: String = current_node

	var kind: String = str(fade_settings.get("kind", "crossfade"))
	match kind:
		"fade_in":
			_apply_transition_fade_in(node_id, node, target_level, fd, fade_settings, from_node_id)
		"fade_out":
			_apply_transition_fade_out(node_id, node, target_level, fd, fade_settings, from_node_id)
		_:
			_apply_transition_crossfade(node_id, node, target_level, fd, fade_settings, from_node_id)

## Classic two-way crossfade (pre-existing semantic, curve-shaped amp-domain).
func _apply_transition_crossfade(node_id: String, node: Dictionary, target_level: int,
		fd: float, fade_settings: Dictionary, from_node_id: String) -> void:
	current_node = node_id
	current_level = target_level

	var curve: String = str(fade_settings.get("fade_curve", "equal_power"))
	for track in tracks:
		if track.level_behavior == "always_play" or track.level_behavior == "level_conditional":
			continue
		_activate_level(track, target_level, fd, curve)

	_post_transition_common(node_id, node, target_level, fade_settings, "crossfade", fd, from_node_id)

## Fade In: OLD hard-stops (anti-click floor absorbs the cut), NEW ramps 0→volume over fd.
## Editor reference: core/music_event.py calls track.start_entry_fade on the NEW tracks
## and _set_exit_for_level(skip_tail=True) on the OLD level. In Godot's per-level model
## we get the same shape by silencing all non-target levels instantly (with anti-click)
## and giving the target level the long ramp.
func _apply_transition_fade_in(node_id: String, node: Dictionary, target_level: int,
		fd: float, fade_settings: Dictionary, from_node_id: String) -> void:
	current_node = node_id
	current_level = target_level

	var curve: String = str(fade_settings.get("fade_curve", "equal_power"))
	for track in tracks:
		if track.level_behavior == "always_play" or track.level_behavior == "level_conditional":
			continue
		# Silence every level except the target. fd=0 goes through anti-click floor in
		# _ramp_level_gain — prevents click at the hard cut without smearing the intent.
		var level_map: Dictionary = _track_players.get(track.name, {})
		for lvl in level_map:
			if int(lvl) != target_level:
				_ramp_level_gain(track, int(lvl), 0.0, 0.0)
		# Bring target up from whatever its current amp is (usually 0 after pre-start)
		# to track.volume (or 0 if chance said "muted") over the full fade duration.
		var passed_chance: bool = _level_chance_verdict(tracks.find(track), target_level)
		var target_amp: float = track.volume if passed_chance else 0.0
		_ramp_level_gain(track, target_level, target_amp, fd, curve)

	_post_transition_common(node_id, node, target_level, fade_settings, "fade_in", fd, from_node_id)

## Fade Out: OLD fades vol→0 over fd. At fade_end, switch to target.
## Phase 3 chain support: if fade_settings carries `entry_fade_duration` /
## `entry_fade_curve` (exporter-flattened from `src → fade_out → fade_in → tgt`),
## NEW level ramps 0 → volume over entry_fade_duration after the switch instead of
## hard-cutting. No chain fields → hard-switch with anti-click (original behavior).
func _apply_transition_fade_out(node_id: String, node: Dictionary, target_level: int,
		fd: float, fade_settings: Dictionary, from_node_id: String) -> void:
	# Cancel any auto-advance scheduled for the OLD node — it would fire mid-fade.
	if _auto_advance_timer:
		_auto_advance_timer = null

	var exit_curve: String = str(fade_settings.get("fade_curve", "equal_power"))
	# Fade every currently-audible level on every per-level track down to 0 over fd.
	# We don't know which levels are actually audible, so fade them all; silent ones
	# stay silent (ramp has no effect) and the one(s) that were playing fade out.
	for track in tracks:
		if track.level_behavior == "always_play" or track.level_behavior == "level_conditional":
			continue
		var level_map: Dictionary = _track_players.get(track.name, {})
		for lvl in level_map:
			_ramp_level_gain(track, int(lvl), 0.0, fd, exit_curve)

	var captured_id := node_id
	var captured_node := node
	var captured_level := target_level
	var captured_fs := fade_settings
	var captured_from := from_node_id
	var entry_fd: float = float(fade_settings.get("entry_fade_duration", 0.0))
	var entry_curve: String = str(fade_settings.get("entry_fade_curve", "equal_power"))

	# Small buffer (5 ms) after fade_end to ensure the ramp fully resolved before we
	# retrigger gains. Matches editor's "fade_end then switch" pattern.
	var switch_timer: SceneTreeTimer = get_tree().create_timer(fd + 0.005)
	_pending_fade_out_switch = switch_timer
	var self_id := get_instance_id()   # int capture — freed-object captures print errors
	switch_timer.timeout.connect(func():
		var ev = instance_from_id(self_id)
		if ev == null:
			return
		if ev._pending_fade_out_switch != switch_timer:
			return  # cancelled OR superseded — a second fade_out re-arms the var, so a bare null-check let the stale switch through
		ev._pending_fade_out_switch = null
		if not ev.is_playing:
			return
		# Current_level is about to flip to target. Bump gen so any pending swap/
		# chance timers scheduled during the fade_out window (on OLD level) are
		# invalidated — they'd otherwise fire on a level that's now background.
		ev._transition_gen += 1
		# Perform the level switch. Anti-click floor still applies at entry_fd=0.
		ev.current_node = captured_id
		ev.current_level = captured_level
		for t in ev.tracks:
			if t.level_behavior == "always_play" or t.level_behavior == "level_conditional":
				continue
			ev._activate_level(t, captured_level, entry_fd, entry_curve)
		var label: String = "fade_out/fade_in" if entry_fd > 0.0 else "fade_out/switch"
		ev._post_transition_common(captured_id, captured_node, captured_level,
				captured_fs, label, entry_fd, captured_from)
	)

	var chain_suffix: String = (" + fade in %.2fs (%s)" % [entry_fd, entry_curve]) if entry_fd > 0.0 else ""
	print("[PFA] Fade Out \"%s\" → \"%s\" over %.2fs (%s)%s" % [
		from_node_id, node.get("name", ""), fd, exit_curve, chain_suffix])
	transition_info.emit({
		"phase": "fade_out_start",
		"duration": fd,
		"curve": exit_curve,
		"entry_fade_duration": entry_fd,
		"entry_fade_curve": entry_curve,
		"from_node": from_node_id,
		"from_name": _resolve_node_name(from_node_id),
		"to_node": node_id,
		"to_name": str(node.get("name", node_id)),
	})

## Shared tail of all three transition kinds: stinger trigger, restart_on_entry,
## sub-level cleanup, conductor bar-dur sync, auto-advance scheduling, log line.
func _post_transition_common(node_id: String, node: Dictionary, target_level: int,
		fade_settings: Dictionary, kind_label: String, fd: float,
		from_node_id: String) -> void:
	# v2: fade_settings["stinger"] is a Dictionary (or null/missing). Bundle was loaded
	# in load_samples() under the `${src}::${tgt}` key — recompute here.
	var stinger_data = fade_settings.get("stinger", null)
	if stinger_data is Dictionary and not (stinger_data as Dictionary).is_empty() and not from_node_id.is_empty():
		_play_stinger("%s::%s" % [from_node_id, node_id])

	if bool(node.get("restart_on_entry", false)):
		_restart_all_players_of_level(target_level)

	_stop_all_sub_levels_immediate()
	_sync_bar_duration_to_current_node()
	_schedule_auto_advance(node)

	var from_name: String = _resolve_node_name(from_node_id)
	var direction: String = str(fade_settings.get("fade_direction", "both"))
	print("[PFA] Entered node \"%s\" (%s), level=%d, bar_dur=%.3fs, kind=%s, dir=%s, fd=%.2fs, from=\"%s\"" % [
		node.get("name", ""), node_id, target_level, _bar_duration_sec, kind_label, direction, fd, from_name])
	transition_info.emit({
		"phase": "transition",
		"kind": kind_label,
		"direction": direction,
		"duration": fd,
		"curve": str(fade_settings.get("fade_curve", "equal_power")),
		"from_node": from_node_id,
		"from_name": from_name,
		"to_node": node_id,
		"to_name": str(node.get("name", node_id)),
		"level": target_level,
	})

## Look up a node's display name from the graph (falls back to id / "start" sentinel
## when the from-node is empty — first entry from play() has no predecessor).
func _resolve_node_name(node_id: String) -> String:
	if node_id.is_empty():
		return "(start)"
	var nodes: Dictionary = _node_graph_data.get("nodes", {})
	if nodes.has(node_id):
		return str(nodes[node_id].get("name", node_id))
	return node_id

## JS: _scheduleNodeTransition(...)
func _schedule_node_transition(node_id: String, node: Dictionary, target_level: int,
		fd: float, fc: String, fade_settings: Dictionary, when_time: float) -> void:
	var delay: float = max(0.0, when_time - _now())
	var nt_timer: SceneTreeTimer = get_tree().create_timer(delay)
	_pending_node_transition = nt_timer
	var captured_id := node_id
	var captured_node := node
	var captured_level := target_level
	var captured_fd := fd
	var captured_fc := fc
	var captured_fs := fade_settings
	var self_id := get_instance_id()   # int capture — freed-object captures print errors
	nt_timer.timeout.connect(func():
		var ev = instance_from_id(self_id)
		if ev == null:
			return
		if ev._pending_node_transition != nt_timer:
			return  # superseded or cancelled — SceneTreeTimers can't be aborted (stale-timer class)
		ev._pending_node_transition = null
		if not ev.is_playing: return
		ev._apply_node_transition(captured_id, captured_node, captured_level, captured_fd, captured_fc, captured_fs)
		print("[PFA] Quantized node transition applied")
	)

## JS: _executeTransition(connection)
func _execute_transition(connection: Dictionary) -> void:
	var fs: Dictionary = {
		"fade_duration": connection.get("fade_duration", fade_duration),
		"fade_curve": connection.get("fade_curve", fade_curve),
		"quantize": connection.get("quantize", switch_quantization),
		"stinger": connection.get("stinger", null),
		"kind": connection.get("kind", "crossfade"),
		"fade_direction": connection.get("fade_direction", "both"),
	}
	if connection.has("entry_fade_duration"):
		fs["entry_fade_duration"] = connection["entry_fade_duration"]
		fs["entry_fade_curve"] = connection.get("entry_fade_curve", "equal_power")
	_enter_node(connection.get("target", ""), fs)

## JS: _scheduleAutoAdvance(node) — extended to support free_tempo (editor-Phase-1.5 pattern).
## If no outgoing auto connection exists but the node carries `terminal_fade` metadata
## (exporter-flattened dangling fade_out), we fire the terminal fade instead — authored
## intent is "this node ends with that fade, play it then stop".
func _schedule_auto_advance(node: Dictionary) -> void:
	if _auto_advance_timer:
		_auto_advance_timer = null

	var loop_count: int = int(node.get("loop_count", 0))
	if loop_count <= 0:
		return  # infinite loop, no auto-advance

	# Any outgoing auto connection from current_node?
	var has_auto: bool = false
	var connections: Array = _node_graph_data.get("connections", [])
	for conn in connections:
		if conn.get("source", "") == current_node and conn.get("auto", false):
			has_auto = true
			break
	var has_terminal: bool = not (node.get("terminal_fade", {}) as Dictionary).is_empty()
	if not has_auto and not has_terminal:
		return

	var duration: float = -1.0
	var free_tempo: bool = bool(node.get("free_tempo", false))

	if free_tempo:
		# Editor Phase 1.5: no bar grid — total = clip length × loop_count.
		var clip_len: float = _get_current_clip_length_sec()
		if clip_len > 0.0:
			duration = clip_len * loop_count
	else:
		var bpm_node: float = float(node.get("bpm", bpm))
		var ts_node: Array = node.get("time_signature", time_signature)
		var beats_per_bar: int = int(ts_node[0]) if ts_node.size() > 0 else 4
		var bar_dur: float = (60.0 / bpm_node) * beats_per_bar if bpm_node > 0 else _bar_duration_sec
		var duration_bars: int = int(node.get("duration_bars", 0))
		if duration_bars > 0:
			duration = duration_bars * loop_count * bar_dur

	if duration <= 0.0:
		return

	print("[PFA] Auto-advance in %.3fs (node=%s, loop_count=%d, free=%s, terminal=%s)" % [
		duration, current_node, loop_count, str(free_tempo), str(has_terminal and not has_auto)])

	var aa_timer: SceneTreeTimer = get_tree().create_timer(duration)
	_auto_advance_timer = aa_timer
	var self_id := get_instance_id()   # int capture — freed-object captures print errors
	aa_timer.timeout.connect(func():
		var ev = instance_from_id(self_id)
		if ev == null:
			return
		# Identity guard = the real cancellation. A SceneTreeTimer cannot be aborted —
		# every `_auto_advance_timer = null` site (re-schedule on node entry, stop,
		# fade_out path) only dropped the reference; the stale timer still fired and
		# _execute_auto_advance re-resolved auto edges from whatever node is CURRENT.
		# With a dir=both auto edge (the exporter mirrors `auto` onto the reverse row)
		# a node_3 timer firing while standing in node_1 walked the edge BACKWARDS —
		# the eternal standing↔Loop2 ping-pong. JS cancels via clearTimeout on every
		# node entry (index.js _scheduleAutoAdvance); this guard is the Godot mirror.
		if ev._auto_advance_timer != aa_timer:
			return
		ev._auto_advance_timer = null
		if not ev.is_playing:
			return
		if has_auto:
			ev._execute_auto_advance()
		else:
			ev.stop_with_terminal_fade()
	)

## JS: _executeAutoAdvance()
func _execute_auto_advance() -> void:
	if current_node.is_empty() or _node_graph_data.is_empty():
		return
	var connections: Array = _node_graph_data.get("connections", [])
	var candidates: Array = []
	for c in connections:
		if c.get("source", "") == current_node \
				and c.get("conn_type", "transition") == "transition" \
				and c.get("auto", false):
			candidates.append(c)
	if candidates.is_empty():
		print("[PFA] No auto-advance from \"%s\"" % current_node)
		return
	candidates.sort_custom(func(a, b): return int(b.get("priority", 0)) - int(a.get("priority", 0)) > 0)
	for conn in candidates:
		var prob: float = float(conn.get("probability", 100))
		if randf() * 100.0 <= prob:
			print("[PFA] Auto-advance \"%s\" → \"%s\"" % [current_node, conn.get("target", "")])
			_execute_transition(conn)
			# JS parity (index.js _executeAutoAdvance): node_changed fires on
			# auto-advance too, not only on navigate() — games mirroring the
			# graph state (fox-run cave HUD) went stale without it.
			if not current_node.is_empty():
				auto_advanced.emit(current_node, get_current_node_name())
			return


# ══════════════════════════════════════════════════════════════════════
# ── Quantization Boundary Math (JS _calcNextX) ─────────────────────────
# ══════════════════════════════════════════════════════════════════════

## JS: _calcNextLoopBoundary(track, level)
## Uses per-level phase anchor (if restart_on_entry fired on this level) instead of the
## global event clock — so variation swaps land on the restarted loop's boundaries.
##
## Conductor ticks are phase-aligned with bar cadence, so when a counter hits
## switch_bars the tick lands ≈ AT the loop boundary we want to use. If we blindly
## return the "next" boundary via ceiling math, we snap past the current one and
## schedule the swap one loop late — observable as "switch every loop" playing
## each variation TWICE before moving on (JS had the same push-to-next guard).
##
## Fix: if we're within ~1 frame of the PREVIOUS boundary (typical tick jitter),
## use it — `_switch_variation` / `_apply_chance_gain` both treat a past boundary
## as "fire now", which is the authored intent ("at THIS loop end"). Otherwise
## return the proper next boundary.
func _calc_next_loop_boundary(track: PFATrack, level: int) -> float:
	var now: float = _now()
	var level_data: Dictionary = track.level_samples.get(level, {})
	var loop_bars: int = int(level_data.get("loop_bars", 4))
	var loop_duration: float = _bar_duration_sec * loop_bars
	if loop_duration <= 0.0:
		return now
	var anchor: float = _level_phase_anchors.get(level, _play_start_time)
	var elapsed: float = now - anchor
	var loops_so_far: int = int(ceil(elapsed / loop_duration))
	var boundary: float = anchor + loops_so_far * loop_duration
	var prev_boundary: float = boundary - loop_duration
	# ~33ms = ~2 Godot frames at 60fps. Tick jitter rarely exceeds this.
	if prev_boundary >= anchor - 0.001 and now - prev_boundary < 0.033:
		return prev_boundary
	return boundary

## JS: _calcNextBarBoundary()
func _calc_next_bar_boundary() -> float:
	var now: float = _now()
	if _bar_duration_sec <= 0.0:
		return now
	var elapsed: float = now - _play_start_time
	var bars_so_far: int = int(ceil(elapsed / _bar_duration_sec))
	var boundary: float = _play_start_time + bars_so_far * _bar_duration_sec
	if boundary - now < 0.01:
		boundary += _bar_duration_sec
	return boundary

## JS: _calcNextBeatBoundary()
func _calc_next_beat_boundary() -> float:
	var beats_per_bar: int = int(time_signature[0]) if time_signature.size() > 0 else 4
	var beat_dur: float = _bar_duration_sec / beats_per_bar
	if beat_dur <= 0.0:
		return _now()
	var now: float = _now()
	var elapsed: float = now - _play_start_time
	var beats_so_far: int = int(ceil(elapsed / beat_dur))
	var boundary: float = _play_start_time + beats_so_far * beat_dur
	if boundary - now < 0.01:
		boundary += beat_dur
	return boundary

## JS: _getQuantizedTime(quantize) — returns -1 (=null in JS) for instant.
## Editor Phase 1.5 parity: if current node has free_tempo, force instant —
## there's no bar/beat grid to snap to (editor: core/music_event.py:404-408 in
## _compute_scheduled_switch_position). Covers level switches, node transitions,
## and connection-level quantize overrides since they all route through here.
func _get_quantized_time(quantize: String) -> float:
	if _is_current_node_free_tempo():
		return -1.0
	if quantize == "bar":
		return _calc_next_bar_boundary()
	if quantize == "beat":
		return _calc_next_beat_boundary()
	return -1.0

func _is_current_node_free_tempo() -> bool:
	if not use_nodes or current_node.is_empty():
		return false
	var node: Dictionary = _node_graph_data.get("nodes", {}).get(current_node, {})
	return bool(node.get("free_tempo", false))


# ══════════════════════════════════════════════════════════════════════
# ── Conductor (inline) — mirrors JS _startConductor/_conductorTick ────
# ══════════════════════════════════════════════════════════════════════

## JS: _startConductor()
func _start_conductor() -> void:
	if _conductor_loop_timer != null:
		return  # already running
	var beats_per_bar: int = int(time_signature[0]) if time_signature.size() > 0 else 4
	_bar_duration_sec = (60.0 / bpm) * beats_per_bar if bpm > 0 else 2.0
	_bar_counter = 0
	_initial_play_chance_roll()
	# Sync bar duration to current node (may override event BPM via Tempo flatten).
	_sync_bar_duration_to_current_node()
	_schedule_next_bar_tick()

func _schedule_next_bar_tick() -> void:
	if not is_playing:
		return
	var bar_timer: SceneTreeTimer = get_tree().create_timer(_bar_duration_sec)
	_conductor_loop_timer = bar_timer
	# Int capture: the event can be freed mid-bar (load_pack reload) and a freed
	# OBJECT capture makes Godot print "Lambda capture freed" before the lambda runs.
	var self_id := get_instance_id()
	bar_timer.timeout.connect(func():
		var ev = instance_from_id(self_id)
		if ev == null:
			return
		# Identity guard (stale-SceneTreeTimer class): _stop_conductor only nulls
		# the ref. A stop→quick-replay armed a NEW chain while the old bar tick was
		# still pending; the stale tick saw is_playing=true (the REPLAY's) and
		# re-scheduled itself → TWO parallel conductor chains forever (_bar_counter
		# at 2× rate, play_chance rerolls + variation switches at double cadence).
		if ev._conductor_loop_timer != bar_timer:
			return
		if not ev.is_playing:
			ev._stop_conductor()
			return
		ev._bar_counter += 1
		ev._conductor_tick()
		ev._schedule_next_bar_tick()
	)

## JS: _stopConductor()
func _stop_conductor() -> void:
	_conductor_loop_timer = null
	_bar_counter = 0
	_track_chance_state.clear()

## JS: _initialPlayChanceRoll()
## Fabric model: EVERY level of a level_specific track gets its own verdict +
## reroll grid at start. Background levels keep rolling while inactive (editor
## reference: core/region.py _advance_level_state simulates exactly this), so
## entering a level at any moment catches its live chance texture.
func _initial_play_chance_roll() -> void:
	_track_chance_state.clear()
	for i in range(tracks.size()):
		var track: PFATrack = tracks[i]
		if track.level_behavior == "always_play" or track.level_behavior == "level_conditional":
			continue
		var levels_state: Dictionary = {}
		for lvl_key in track.level_samples:
			var lvl: int = int(lvl_key)
			var level_data: Dictionary = track.level_samples[lvl]
			var play_chance: float = float(level_data.get("play_chance", 100))

			if play_chance >= 100.0:
				levels_state[lvl] = {"playing": true, "locked_until": 0, "next_reroll_bar": INF}
				continue

			var passed: bool = track.roll_play_chance(lvl)
			var loop_bars: int = int(level_data.get("loop_bars", 4))
			var reroll_bars: int = int(track.chance_reroll_bars)
			var lock_duration: int = loop_bars * reroll_bars

			levels_state[lvl] = {
				"playing": passed, "locked_until": lock_duration,
				"next_reroll_bar": lock_duration,
			}
			if not passed and lvl == current_level:
				# Mute immediately — activate_level already ran before conductor started.
				_apply_chance_gain(track, lvl, false, -1.0)
		_track_chance_state[i] = levels_state

## JS: _conductorTick()
func _conductor_tick() -> void:
	var cur_level: int = current_level

	# ── play_chance evaluation ──
	# Fabric model: every level rerolls on ITS OWN grid, continuously — background
	# verdicts evolve while the level is inactive (bookkeeping only; gain ramps
	# apply to the current level alone). _activate_level reads the target level's
	# live verdict at entry, so no entry-time reroll exists anymore.
	for i in range(tracks.size()):
		if not _track_chance_state.has(i):
			continue
		var track: PFATrack = tracks[i]
		var levels_state: Dictionary = _track_chance_state[i]
		for lvl_key in levels_state:
			var lvl: int = int(lvl_key)
			var state: Dictionary = levels_state[lvl_key]

			# Still locked from previous roll — committed state.
			if _bar_counter < int(state["next_reroll_bar"]):
				continue

			var level_data: Dictionary = track.level_samples.get(lvl, {})
			var play_chance: float = float(level_data.get("play_chance", 100))
			if play_chance >= 100.0:
				# Init seeds 100%-levels with next_reroll_bar=INF — reachable only
				# if a runtime mutation dropped the chance below 100 and back.
				state["playing"] = true
				state["next_reroll_bar"] = INF
				continue

			# Reroll on this level's own grid.
			var passed: bool = track.roll_play_chance(lvl)
			var loop_bars: int = int(level_data.get("loop_bars", 4))
			var reroll_bars: int = int(track.chance_reroll_bars)
			var lock_duration: int = loop_bars * reroll_bars

			# Audible ramp only when the verdict CHANGED on the audible level;
			# background levels just remember the verdict for their next entry.
			if passed != bool(state["playing"]) and lvl == cur_level:
				var bnd: float = _calc_next_loop_boundary(track, lvl)
				_apply_chance_gain(track, lvl, passed, bnd)

			state["playing"] = passed
			state["locked_until"] = _bar_counter + lock_duration
			state["next_reroll_bar"] = _bar_counter + lock_duration

	# ── Variation switching (every bar, checks against loop_bars * repeat_count) ──
	# Fabric model: level_specific tracks tick EVERY level's pool, not just the
	# current one — background levels keep rotating while muted (editor reference
	# _advance_level_state; FMOD virtual-voice model). Counters stay aligned to
	# each level's own loop grid (all ticking since play start), so entering a
	# level mid-loop never restarts its "play N times before switching" count.
	for i in range(tracks.size()):
		var track: PFATrack = tracks[i]
		var is_shared: bool = (track.level_behavior == "always_play" or track.level_behavior == "level_conditional")

		if not _track_variation_counter.has(track.name):
			_track_variation_counter[track.name] = {}
		var counters: Dictionary = _track_variation_counter[track.name]

		if is_shared:
			var streams: Array = track._shared_streams
			if streams.size() <= 1:
				continue
			counters["shared"] = int(counters.get("shared", 0)) + 1
			var level_data: Dictionary = track.level_samples.get(cur_level, {})
			var loop_bars: int = int(level_data.get("loop_bars", 4))
			var switch_bars: int = loop_bars * int(track.repeat_count)
			if counters["shared"] >= switch_bars:
				counters["shared"] = 0
				var switch_chance: float = float(level_data.get("switch_chance", 100))
				if switch_chance > 0.0 and randf() * 100.0 <= switch_chance:
					var boundary: float = _calc_next_loop_boundary(track, cur_level)
					_switch_variation(track, cur_level, true, boundary)
			continue

		for lvl_key in track.level_samples:
			var lvl: int = int(lvl_key)
			var streams_l: Array = track._streams.get(lvl, [])
			if streams_l.size() <= 1:
				continue
			var pool_key: String = str(lvl)
			counters[pool_key] = int(counters.get(pool_key, 0)) + 1

			var level_data_l: Dictionary = track.level_samples.get(lvl, {})
			var loop_bars_l: int = int(level_data_l.get("loop_bars", 4))
			var switch_bars_l: int = loop_bars_l * int(track.repeat_count)

			if counters[pool_key] >= switch_bars_l:
				counters[pool_key] = 0
				var switch_chance_l: float = float(level_data_l.get("switch_chance", 100))
				if switch_chance_l > 0.0 and randf() * 100.0 <= switch_chance_l:
					var boundary_l: float = _calc_next_loop_boundary(track, lvl)
					_switch_variation(track, lvl, false, boundary_l)

## Live play_chance verdict for (track_idx, level). Fabric model: background
## levels reroll continuously on their own grid (conductor), so entry simply
## READS the target level's current verdict — no entry-time reroll (the old
## _roll_chance_for_new_level), no stale verdict inherited from the level left.
func _level_chance_verdict(track_idx: int, level: int) -> bool:
	if track_idx < 0 or not _track_chance_state.has(track_idx):
		return true
	var levels_state: Dictionary = _track_chance_state[track_idx]
	if not levels_state.has(level):
		return true
	return bool(levels_state[level]["playing"])

## JS: _applyChanceGain(track, level, playing, whenTime)
## Godot: when_time > 0 → schedule; else apply now.
func _apply_chance_gain(track: PFATrack, level: int, playing: bool, when_time: float) -> void:
	var now: float = _now()
	var t0: float = when_time if when_time > 0.0 else now
	var target_amp: float = track.volume if playing else 0.0
	var fade_sec: float = track.chance_fade_duration if track.chance_fade_mode == "fade" else 0.01

	if t0 > now + 0.005:
		# Future-scheduled: wait then apply.
		var delay: float = t0 - now
		var timer: SceneTreeTimer = get_tree().create_timer(delay)
		var captured_track := track
		var captured_level := level
		var captured_amp := target_amp
		var captured_fade := fade_sec
		# Snapshot the transition generation at schedule time. If navigate()
		# changes current_level before this boundary fires, _transition_gen will
		# have advanced and the gain ramp we were about to apply is now targeting
		# a level that's no longer active — applying it would leak audio from OLD
		# level on top of NEW (e.g. an "unmute" ramp from 0→1.0 over chance_fade
		# duration right after navigate). Drop the schedule if stale.
		var captured_gen := _transition_gen
		var self_id := get_instance_id()   # int capture — freed-object captures print errors
		timer.timeout.connect(func():
			var ev = instance_from_id(self_id)
			if ev == null: return
			if not ev.is_playing: return
			if captured_gen != ev._transition_gen: return
			if captured_level != ev.current_level: return
			ev._ramp_level_gain(captured_track, captured_level, captured_amp, captured_fade)
		)
	else:
		_ramp_level_gain(track, level, target_amp, fade_sec)


# ══════════════════════════════════════════════════════════════════════
# ── Variation Switching (JS _switchVariation, JIT micro-xfade) ────────
# ══════════════════════════════════════════════════════════════════════

## JS: _switchVariation(track, level, boundaryTime)
## Godot: pre-started variation players exist; we just xfade their volume_db.
##
## Why 30ms vs JS's 2ms: JS uses Web Audio's gain.linearRampToValueAtTime which runs in the
## audio thread at sample-accurate precision — 2ms of smooth interpolation is genuine.
## Godot's AudioStreamPlayer.volume_db is written once per game frame (~16.7ms @ 60fps), so
## any "fade" shorter than ~2 frames renders as a step change → audible click when variations
## have different waveform amplitudes at the splice point. 30ms spans ~2 frames reliably and
## lets the equal-power curve do its job. Still JIT-fast enough to sound like a seamless swap.
const _MICRO_FADE_SEC: float = 0.030

func _switch_variation(track: PFATrack, level: int, is_shared: bool, boundary_time: float) -> void:
	var delay: float = max(0.0, boundary_time - _now())
	var captured_track := track
	var captured_level := level
	var captured_shared := is_shared

	if delay > 0.005:
		var t: SceneTreeTimer = get_tree().create_timer(delay)
		# NOTE: no generation guard here (unlike _apply_chance_gain). A swap is
		# valid on ANY level under the fabric model: current level → audible
		# micro-xfade, background level → silent bookkeeping flip. The only
		# dangerous case (lane still audibly fading out after a level switch)
		# is vetoed inside _apply_variation_switch (editor freeze window).
		# A gen guard here once broke rapid navigate-and-return-before-boundary
		# (L2→L1→L2 within one loop): gen bumped twice → swap dropped → same
		# variation for another full cycle ("2x in a row").
		var self_id := get_instance_id()   # int capture — freed-object captures print errors
		t.timeout.connect(func():
			var ev = instance_from_id(self_id)
			if ev != null:
				ev._apply_variation_switch(captured_track, captured_level, captured_shared)
		)
	else:
		_apply_variation_switch(track, level, is_shared)

func _apply_variation_switch(track: PFATrack, level: int, is_shared: bool) -> void:
	var streams: Array
	var players: Array
	var active: int

	if is_shared:
		var shared_state: Dictionary = _track_shared.get(track.name, {})
		streams = track._shared_streams
		players = shared_state.get("players", [])
		active = shared_state.get("active", 0)
	else:
		var state: Dictionary = _track_players.get(track.name, {}).get(level, {})
		streams = track._streams.get(level, track._streams.get(0, []))
		players = state.get("players", [])
		active = state.get("active", 0)

	if streams.size() <= 1 or players.size() <= 1:
		return

	# Fabric model: background (non-current) levels DO rotate — their swap is pure
	# bookkeeping on a muted lane. The editor's freeze survives only in its original
	# narrow sense ("OLD level during crossfade must not swap variation at loop
	# boundary — counters still advance but the swap itself is vetoed",
	# core/multisample.py:475-479): while the OUTGOING lane is still audibly fading,
	# swapping would kill the fade tween mid-ramp and click. Checked BEFORE the pick
	# so a vetoed boundary never consumes the rotation bag.
	var background: bool = (not is_shared) and level != current_level
	if background and active >= 0 and active < players.size():
		var audible_p: AudioStreamPlayer = players[active]
		# Veto in the LEVEL domain (JS parity: levelGain.value > 0.001), decoding the
		# player's combined volume_db back through _current_amp_of_player. The raw
		# `volume_db > -59` form folded event×group×master×duck into the reading, so
		# under a non-unity mix (quiet master, ducked group) a lane at FULL level amp
		# read below the threshold → veto missed → swap flipped `active` mid-fade —
		# the exact seam the veto exists to protect. 0.001 amp ≈ the old -59 dB intent.
		if is_instance_valid(audible_p) and _current_amp_of_player(audible_p) > 0.001:
			return

	var old_variation: int = active
	var clips: Array = []
	if is_shared:
		clips = track._shared_clips
	else:
		clips = track._clips.get(level, track._clips.get(0, []))
	var level_key: String = "shared" if is_shared else str(level)
	var new_variation: int = track.pick_next_variation_idx(streams, clips, level_key)

	if new_variation == old_variation:
		return  # same buffer — skip (JS does same at L2099)

	if new_variation < 0 or new_variation >= players.size():
		return  # safety net — per-pool rotation state can't mint an out-of-range index

	if background:
		# Muted lane: flip which player the next _ramp_level_gain will unmute.
		# No tweens — nothing audible is in flight on this level.
		_track_players[track.name][level]["active"] = new_variation
		return

	var old_player: AudioStreamPlayer = players[old_variation]
	var new_player: AudioStreamPlayer = players[new_variation]

	# Target amp for NEW variation = the level's current target_amp (active level full, else 0).
	var track_target_amp: float
	if is_shared:
		track_target_amp = track.volume
	else:
		var lvl_state: Dictionary = _track_level_state.get(track.name, {}).get(level, {})
		track_target_amp = float(lvl_state.get("target_amp", 0.0))

	var lvl_state_map: Dictionary = _track_level_state.get(track.name, {})
	var cur_lvl_state: Dictionary = lvl_state_map.get(level, {})
	var prev_tween: Tween = cur_lvl_state.get("tween", null)

	# A LIVE long fade on this lane (chance fade, long level fade) must SURVIVE the
	# swap — web parity: there the fade lives on a separate levelGain node the
	# variation crossfade never touches, so a switch mid-fade keeps ramping. Godot
	# folds both gates into one volume_db knob, so hand the fade over instead of
	# stomping it: the NEW player resumes the ORIGINAL trajectory (same from/target/
	# window/curve, stored in cur_lvl_state) under a 30 ms equal-power onset while
	# the OLD player micro-fades out. Gate on "remaining window > micro-xfade":
	# anything shorter is audibly identical to the plain swap, so the common settled
	# case (and the 30 ms stamps written by previous swaps) stays byte-identical.
	# Shared lanes never store level-fade state here (their dict is empty → no
	# valid prev_tween), so this branch is level_specific-only by construction.
	var now: float = _now()
	var fade_end: float = float(cur_lvl_state.get("end_time", 0.0))
	if not is_shared and prev_tween and prev_tween.is_valid() \
			and fade_end - now > _MICRO_FADE_SEC:
		var fade_start: float = float(cur_lvl_state.get("start_time", now))
		var fade_from: float = float(cur_lvl_state.get("from_amp", 0.0))
		var fade_target: float = float(cur_lvl_state.get("target_amp", track_target_amp))
		var fade_curve: String = str(cur_lvl_state.get("curve", "equal_power"))
		prev_tween.kill()
		_equal_power_tween_to_amp(old_player, 0.0, _MICRO_FADE_SEC)
		var resumed: Tween = _resume_fade_tween(new_player, fade_from, fade_target,
				fade_start, fade_end, fade_curve)
		_track_players[track.name][level]["active"] = new_variation
		lvl_state_map[level] = {
			"target_amp": fade_target, "tween": resumed,
			"start_time": fade_start, "end_time": fade_end, "from_amp": fade_from,
			"curve": fade_curve,
		}
		_track_level_state[track.name] = lvl_state_map
		print("[PFA] Variation switch: %s L%d: %d → %d (live fade handed over, %.2fs left)"
				% [track.name, level, old_variation, new_variation, fade_end - now])
		return

	# Kill any level tween still in flight — we're taking over both players' volume for MICRO_FADE.
	if prev_tween and prev_tween.is_valid():
		prev_tween.kill()

	# Equal-power crossfade: OLD → 0, NEW → track_target_amp.
	# sin/cos quadrant gives constant combined power through the splice → no volume dip.
	# Matches JS pattern (L2114-2143) which sets gain.setValueAtTime(0,t)+linearRamp(1,t+2ms)
	# on new variationGain and the reverse on old — constant-power when both are same signal.
	_equal_power_tween_to_amp(old_player, 0.0, _MICRO_FADE_SEC)
	var new_tween: Tween = _equal_power_tween_to_amp(new_player, track_target_amp, _MICRO_FADE_SEC)

	# Flip active index. Store NEW player's tween so subsequent level activations know what's live.
	if is_shared:
		_track_shared[track.name]["active"] = new_variation
	else:
		_track_players[track.name][level]["active"] = new_variation

	lvl_state_map[level] = {
		"target_amp": track_target_amp, "tween": new_tween,
		"start_time": _now(), "end_time": _now() + _MICRO_FADE_SEC, "from_amp": track_target_amp,
		"curve": "equal_power",
	}
	_track_level_state[track.name] = lvl_state_map
	print("[PFA] Variation switch: %s L%d: %d → %d" % [track.name, level, old_variation, new_variation])


# ══════════════════════════════════════════════════════════════════════
# ── Per-track pre-start / activate ────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## JS: PFATrack.prestartAllLevels(destination, offsetSeconds)
## Godot: create one AudioStreamPlayer per (level, variation), play(offset), volume_db=-80.
func _prestart_track_level_specific(track: PFATrack, offset_seconds: float) -> void:
	if _track_players.has(track.name):
		# Already pre-started.
		return
	var level_map: Dictionary = {}
	for level_idx in track.level_samples:
		var streams: Array = track._streams.get(level_idx, [])
		if streams.is_empty():
			continue
		var clips: Array = track._clips.get(level_idx, [])
		var players: Array = []
		for i in range(streams.size()):
			var stream: AudioStream = streams[i]
			if stream == null:
				continue
			var clip_i: PFARegionClip = _clip_at(clips, i)
			stream = _prepare_loop_stream(stream, clip_i)
			var player: AudioStreamPlayer = AudioStreamPlayer.new()
			player.bus = _voice_bus
			player.stream = stream
			_setup_loop(stream, clip_i)
			player.volume_db = -80.0
			add_child(player)
			var start_offset: float = _compute_initial_offset(stream, clips, i, offset_seconds)
			player.play(start_offset)
			_maybe_drive_clip_wrap(player, stream, clip_i,
				start_offset - (clip_i.source_offset if clip_i else 0.0))
			players.append(player)
		if not players.is_empty():
			var initial_active: int = clampi(track.current_variation(str(int(level_idx))), 0, players.size() - 1)
			level_map[int(level_idx)] = {"players": players, "active": initial_active}
			# Seed level state at amp=0.
			if not _track_level_state.has(track.name):
				_track_level_state[track.name] = {}
			_track_level_state[track.name][int(level_idx)] = {
				"target_amp": 0.0, "tween": null,
				"start_time": _now(), "end_time": _now(), "from_amp": 0.0,
				"curve": "equal_power",
			}
	_track_players[track.name] = level_map

## JS: PFATrack.playMusic(level, destination, offsetSeconds) — for shared (always_play / level_conditional).
func _play_music_shared(track: PFATrack, offset_seconds: float) -> void:
	if track._shared_streams.is_empty():
		return
	if _track_shared.has(track.name):
		return  # already started
	var players: Array = []
	for i in range(track._shared_streams.size()):
		var stream: AudioStream = track._shared_streams[i]
		if stream == null:
			continue
		var clips: Array = track._shared_clips
		var clip_i: PFARegionClip = _clip_at(clips, i)
		stream = _prepare_loop_stream(stream, clip_i)
		var player: AudioStreamPlayer = AudioStreamPlayer.new()
		player.bus = _voice_bus
		player.stream = stream
		_setup_loop(stream, clip_i)
		player.volume_db = -80.0
		add_child(player)
		var start_offset: float = _compute_initial_offset(stream, clips, i, offset_seconds)
		player.play(start_offset)
		_maybe_drive_clip_wrap(player, stream, clip_i,
			start_offset - (clip_i.source_offset if clip_i else 0.0))
		players.append(player)
	if players.is_empty():
		return
	var initial_active: int = clampi(track.current_variation("shared"), 0, players.size() - 1)
	_track_shared[track.name] = {"players": players, "active": initial_active}
	# Shared tracks always active at track.volume.
	var active_player: AudioStreamPlayer = players[initial_active]
	if is_instance_valid(active_player):
		_equal_power_tween_to_amp(active_player, track.volume, 0.02)

## JS: PFATrack.activateLevel(level, fadeDuration)
## Godot: per-level ramp via Tween. target_amp = track.volume if level matches AND chance passes.
## curve (editor parity): linear / equal_power / s_curve / exponential / logarithmic.
func _activate_level(track: PFATrack, target_level: int, fd: float,
		curve: String = "equal_power") -> void:
	# Fabric model: gate by the TARGET level's own live verdict (was: stale
	# per-track verdict inherited from the level being LEFT — entering a
	# 100%-chance level could stay silent until the next loop boundary).
	var passed_chance: bool = _level_chance_verdict(tracks.find(track), target_level)

	var level_map: Dictionary = _track_players.get(track.name, {})
	for lvl in level_map:
		var target_amp: float = 0.0
		if int(lvl) == target_level and passed_chance:
			target_amp = track.volume
		_ramp_level_gain(track, int(lvl), target_amp, fd, curve)

## Tween the active player of (track, level) to new target amp over fd seconds.
## Splice: read current volume_db, kill old tween, start new from actual current amp.
## `curve` shapes the ramp (editor parity). Default preserves prior equal_power behavior.
func _ramp_level_gain(track: PFATrack, level: int, target_amp: float, fd: float,
		curve: String = "equal_power") -> void:
	var level_map: Dictionary = _track_players.get(track.name, {})
	var state: Dictionary = level_map.get(level, {})
	if state.is_empty():
		return
	var players: Array = state.get("players", [])
	var active: int = state.get("active", 0)
	if active < 0 or active >= players.size():
		return
	var player: AudioStreamPlayer = players[active]
	if not is_instance_valid(player):
		return

	# Kill previous tween on this level.
	var lvl_state_map: Dictionary = _track_level_state.get(track.name, {})
	var prev_state: Dictionary = lvl_state_map.get(level, {})
	var prev_tween: Tween = prev_state.get("tween", null)
	if prev_tween and prev_tween.is_valid():
		prev_tween.kill()

	# Anti-click + Godot frame-rate floor: Godot writes volume_db once per game frame
	# (~16.7ms @ 60fps), so any fade shorter than ~2 frames renders as a step change →
	# audible click. Two cases handled here:
	#   (1) dur=0 ("instant" level change): JS/editor rely on sample-accurate ramps;
	#       Godot needs 30ms to span 2 frames. Matches editor's 10ms _anticlick_samples
	#       (core/track.py:102,389) scaled for Godot's frame limit.
	#   (2) dur small but non-zero (e.g. chance_fade_mode="instant" passes 0.01s, JS
	#       L2030): same physical constraint applies. Floor to _MICRO_FADE_SEC.
	# If the amp isn't actually changing, keep truly instant — no click to prevent.
	var current_amp_for_anticlick: float = _current_amp_of_player(player)
	var amp_changing: bool = absf(current_amp_for_anticlick - target_amp) > 0.001
	if fd < _MICRO_FADE_SEC:
		if amp_changing:
			fd = _MICRO_FADE_SEC
		else:
			player.volume_db = _combined_db_for_amp(target_amp)
			lvl_state_map[level] = {
				"target_amp": target_amp, "tween": null,
				"start_time": _now(), "end_time": _now(), "from_amp": target_amp,
				"curve": curve,
			}
			_track_level_state[track.name] = lvl_state_map
			return

	var start_amp: float = _current_amp_of_player(player)
	var tween: Tween = _equal_power_tween_to_amp(player, target_amp, fd, curve)
	lvl_state_map[level] = {
		"target_amp": target_amp, "tween": tween,
		"start_time": _now(), "end_time": _now() + fd, "from_amp": start_amp,
		"curve": curve,
	}
	_track_level_state[track.name] = lvl_state_map

## Fade-in curve shape 0→1 for given progress ∈ [0,1]. Editor parity:
## core/track.py::_get_fade_value. Callers use f(1-p) for fade-out semantics
## (so equal_power yields sin→cos decay as before; exp/log stay complementary).
func _eval_fade_in_curve(progress: float, curve: String) -> float:
	progress = clampf(progress, 0.0, 1.0)
	match curve:
		"linear":
			return progress
		"equal_power":
			return sin(progress * PI / 2.0)
		"s_curve":
			return progress * progress * (3.0 - 2.0 * progress)
		"exponential":
			return progress * progress
		"logarithmic":
			var inv: float = 1.0 - progress
			return 1.0 - inv * inv
		_:
			return progress

## Curve-shaped amplitude tween on one player's volume_db.
## fade-in: amp = start + (target-start) * f(t)
## fade-out: amp = target + (start-target) * f(1-t)  (symmetric to fade-in)
## Default curve "equal_power" preserves prior sin/cos behavior; exp/log/linear/s_curve
## also supported. Returns created Tween or null if already applied (duration<=0).
func _equal_power_tween_to_amp(player: AudioStreamPlayer, target_amp: float, duration: float,
		curve: String = "equal_power") -> Tween:
	if not is_instance_valid(player):
		return null
	if duration <= 0.0:
		player.volume_db = _combined_db_for_amp(target_amp)
		return null
	# Anti-click frame-rate floor (see _ramp_level_gain): catches direct callers passing a
	# raw sub-floor duration (e.g. shared-track activation) so the onset can't step → click.
	if duration < _MICRO_FADE_SEC:
		duration = _MICRO_FADE_SEC
	var start_amp: float = _current_amp_of_player(player)
	var is_fade_in: bool = target_amp > start_amp
	var curve_name: String = curve
	# Bound to the PLAYER, not this event node: the event outlives its players, so an
	# event-owned tween whose lambda captured `player` kept firing for the rest of its
	# duration after the player was freed (stop_all / variation cleanup / eviction) —
	# "Lambda capture at index 0 was freed" spam every tick (~300 per orphaned 5s fade).
	# A player-bound tween is killed WITH the player — the same ownership rule as
	# _apply_sfx_fade_to_player's sfx_tw. Callers only store + kill() the return.
	var tween: Tween = player.create_tween()
	tween.tween_method(func(t: float):
		if not is_instance_valid(player):
			return
		var shape: float
		if is_fade_in:
			shape = _eval_fade_in_curve(t, curve_name)
		else:
			shape = _eval_fade_in_curve(1.0 - t, curve_name)
		var amp: float
		if is_fade_in:
			amp = start_amp + (target_amp - start_amp) * shape
		else:
			amp = target_amp + (start_amp - target_amp) * shape
		var with_factor: float = amp * _event_group_master_factor()
		player.volume_db = _amp_to_db(with_factor)
	, 0.0, 1.0, duration)
	return tween

## Resume an in-flight level fade on ANOTHER player (variation handover).
## Replays the ORIGINAL trajectory — from_amp → target_amp over [start_time,
## end_time] with `curve` — picking it up at the current moment, so the fade
## completes on its original clock as if never interrupted (web parity: the
## levelGain keeps ramping under the variation crossfade). The first
## _MICRO_FADE_SEC multiplies in an equal-power sin onset: the destination
## player rises 0→trajectory while the outgoing player cos-decays to 0
## (_equal_power_tween_to_amp) — constant combined power, no step on either
## side. Same ownership rule as _equal_power_tween_to_amp: the tween is bound
## to the player so it dies with it; the caller stores + kills the return.
func _resume_fade_tween(player: AudioStreamPlayer, from_amp: float, target_amp: float,
		start_time: float, end_time: float, curve: String = "equal_power") -> Tween:
	if not is_instance_valid(player):
		return null
	var now: float = _now()
	var full: float = end_time - start_time
	var remaining: float = end_time - now
	if full <= 0.0 or remaining <= 0.0:
		return _equal_power_tween_to_amp(player, target_amp, _MICRO_FADE_SEC, curve)
	var is_fade_in: bool = target_amp > from_amp
	var p0: float = clampf((now - start_time) / full, 0.0, 1.0)
	var tween: Tween = player.create_tween()
	tween.tween_method(func(t: float):
		if not is_instance_valid(player):
			return
		# Continue the original parameterization: p spans [p0..1] over the remaining window.
		var p: float = p0 + (1.0 - p0) * t
		var shape: float
		if is_fade_in:
			shape = _eval_fade_in_curve(p, curve)
		else:
			shape = _eval_fade_in_curve(1.0 - p, curve)
		var amp: float
		if is_fade_in:
			amp = from_amp + (target_amp - from_amp) * shape
		else:
			amp = target_amp + (from_amp - target_amp) * shape
		var elapsed: float = t * remaining
		if elapsed < _MICRO_FADE_SEC:
			amp *= sin(elapsed / _MICRO_FADE_SEC * PI / 2.0)
		var with_factor: float = amp * _event_group_master_factor()
		player.volume_db = _amp_to_db(with_factor)
	, 0.0, 1.0, remaining)
	return tween

## Decode a player's current volume_db back to pre-event-gain amp (so tween continues smoothly).
func _current_amp_of_player(player: AudioStreamPlayer) -> float:
	var factor: float = max(0.0001, _event_group_master_factor())
	return _db_to_amp(player.volume_db) / factor

## JS: _crossfadeLevel(oldLevel, newLevel) — used by setLevel in simple mode.
func _crossfade_level(old_level: int, new_level: int) -> void:
	for track in tracks:
		if track.level_behavior == "always_play" or track.level_behavior == "level_conditional":
			continue
		# Honor the event's authored fade_curve (the editor's Curve dropdown). Without it this
		# defaulted to equal_power → a front-loaded ramp that sounds much faster than the set
		# duration even when the user picked Linear. Node-mode transitions already thread it.
		_activate_level(track, new_level, fade_duration, fade_curve)
	# restart_on_entry currently only a node-graph concept; simple-mode level setLevel doesn't carry it.

## Seek ALL variation players of this level to 0 AND set per-level phase anchor
## (used by restart_on_entry). Seeking every variation — not just the active one — keeps
## variations phase-aligned with each other, so a later variation swap at a loop boundary
## doesn't jump to a variation at a different stream position.
##
## The phase anchor replaces _play_start_time for this level in _calc_next_loop_boundary,
## so the first post-restart boundary lands at `anchor + loop_duration` (not somewhere
## inside the restarted loop). Editor equivalent: _apply_restart_on_entry's
## `state._switch_position = current_position` (core/music_event.py:608).
func _restart_all_players_of_level(level: int) -> void:
	_level_phase_anchors[level] = _now()
	for track in tracks:
		var state: Dictionary = _track_players.get(track.name, {}).get(level, {})
		var players: Array = state.get("players", [])
		for p in players:
			if is_instance_valid(p):
				var seek_to: float = 0.0
				if _clip_wrap_state.has(p.get_instance_id()):
					# Manual-wrap voices restart at the CLIP start and re-anchor their
					# wrap grid (a stale chain would seek to the old grid's phase).
					var st: Dictionary = _clip_wrap_state[p.get_instance_id()]
					seek_to = float(st["offset"])
					st["anchor"] = _now()
					st["gen"] = int(st["gen"]) + 1
					_schedule_clip_wrap(p.get_instance_id(), st)
				elif p.stream is AudioStreamWAV and (p.stream as AudioStreamWAV).loop_begin > 0:
					# Clip-windowed WAV: restart at the clip start, not the trimmed-away
					# file head (loop points carry the window — seek(0) would play
					# [0, offset) once before reaching the loop).
					var w: AudioStreamWAV = p.stream
					seek_to = float(w.loop_begin) / maxf(1.0, float(w.mix_rate))
				p.seek(seek_to)

## JS: _scheduleLevelSwitch(level, whenTime)
func _schedule_level_switch(level: int, when_time: float) -> void:
	var delay: float = max(0.0, when_time - _now())
	var ls_timer: SceneTreeTimer = get_tree().create_timer(delay)
	_pending_level_switch = ls_timer
	var captured_level := level
	var self_id := get_instance_id()   # int capture — freed-object captures print errors
	ls_timer.timeout.connect(func():
		var ev = instance_from_id(self_id)
		if ev == null:
			return
		if ev._pending_level_switch != ls_timer:
			return  # superseded or cancelled — SceneTreeTimers can't be aborted (stale-timer class)
		ev._pending_level_switch = null
		if not ev.is_playing: return
		var old_level: int = ev.current_level
		ev.current_level = captured_level
		ev._crossfade_level(old_level, captured_level)
		print("[PFA] Quantized setLevel: %d → %d" % [old_level, captured_level])
	)


# ══════════════════════════════════════════════════════════════════════
# ── Sub-levels ────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## JS: _enableSubLevel(sub, fadeDuration)
func _enable_sub_level(sub: Dictionary, fade_dur: float) -> void:
	var sub_name: String = sub.get("name", "")
	var sub_tracks: Array = sub.get("tracks", [])
	var sub_volume: float = float(sub.get("volume", 1.0))
	var sub_level: int = int(sub.get("level_index", current_level))

	var players: Array = []
	for track in sub_tracks:
		if not track._samples_loaded:
			track.load_streams(_base_path)
		var streams: Array
		var clips: Array
		var is_shared: bool = (track.level_behavior == "always_play" or track.level_behavior == "level_conditional")
		if is_shared:
			streams = track._shared_streams
			clips = track._shared_clips
		else:
			streams = track._streams.get(sub_level, track._streams.get(0, []))
			clips = track._clips.get(sub_level, track._clips.get(0, []))
		if streams.is_empty():
			continue
		var sub_pool_key: String = "shared" if is_shared else str(sub_level)
		var var_idx: int = clampi(track.current_variation(sub_pool_key), 0, streams.size() - 1)
		var stream: AudioStream = streams[var_idx]
		if stream == null:
			continue
		var clip_for_var: PFARegionClip = _clip_at(clips, var_idx)
		stream = _prepare_loop_stream(stream, clip_for_var)
		var player: AudioStreamPlayer = AudioStreamPlayer.new()
		player.bus = _voice_bus
		player.stream = stream
		_setup_loop(stream, clip_for_var)
		player.volume_db = -80.0
		add_child(player)
		# Phase-aligned start offset with main event clock.
		var elapsed: float = _now() - _play_start_time
		var start_offset: float = _compute_initial_offset(stream, clips, var_idx, elapsed)
		player.play(start_offset)
		_maybe_drive_clip_wrap(player, stream, clip_for_var,
			start_offset - (clip_for_var.source_offset if clip_for_var else 0.0))
		# Fade in from -80 → track × sub volume × event.
		var target_amp: float = track.volume * sub_volume
		_equal_power_tween_to_amp(player, target_amp, fade_dur)
		players.append(player)

	_sub_level_states[sub_name] = {
		"enabled": true, "players": players, "tracks": sub_tracks,
	}

## JS: _disableSubLevel(sub, subName, fadeDuration)
func _disable_sub_level(_sub: Dictionary, sub_name: String, fade_dur: float) -> void:
	var state: Dictionary = _sub_level_states.get(sub_name, {})
	if state.is_empty():
		return
	var players: Array = state.get("players", [])
	for p in players:
		if is_instance_valid(p):
			_equal_power_tween_to_amp(p, 0.0, fade_dur)
	# Teardown must OUTLAST the ramp (a5a350b contract): the tween floors a sub-floor
	# fade_dur to _MICRO_FADE_SEC internally, so size the timer from the EFFECTIVE fade
	# + the render margin — a raw fade_dur+0.01 fired mid-ramp at an audible level.
	var eff_fade: float = fade_dur
	if eff_fade > 0.0 and eff_fade < _MICRO_FADE_SEC:
		eff_fade = _MICRO_FADE_SEC
	var timer: SceneTreeTimer = get_tree().create_timer(eff_fade + 0.04)
	var captured_players := players
	var self_id := get_instance_id()   # int capture — freed-object captures print errors
	timer.timeout.connect(func():
		var ev = instance_from_id(self_id)
		for p in captured_players:
			if is_instance_valid(p):
				if ev != null:
					ev._clip_wrap_state.erase(p.get_instance_id())
				p.stop()
				p.queue_free()
	)
	state["players"] = []
	state["enabled"] = false

## Stop all sub-levels "immediately" = anti-click micro-fade, then free. Called on node
## entry (live event gain!) and from the stop-teardown. The old 20ms-ask/25ms-timer pair
## raced the tween's internal _MICRO_FADE_SEC floor — p.stop() fired ~1 frame before
## silence at an audible residual (the a5a350b race, missed in this sibling).
func _stop_all_sub_levels_immediate() -> void:
	for sub_name in _sub_level_states.keys():
		var state: Dictionary = _sub_level_states[sub_name]
		var players: Array = state.get("players", [])
		for p in players:
			if is_instance_valid(p):
				_equal_power_tween_to_amp(p, 0.0, _MICRO_FADE_SEC)
		var captured := players
		var timer: SceneTreeTimer = get_tree().create_timer(_MICRO_FADE_SEC + 0.04)
		var self_id := get_instance_id()   # int capture — freed-object captures print errors
		timer.timeout.connect(func():
			var ev = instance_from_id(self_id)
			for p in captured:
				if is_instance_valid(p):
					if ev != null:
						ev._clip_wrap_state.erase(p.get_instance_id())
					p.stop()
					p.queue_free()
		)
		state["players"] = []
		state["enabled"] = false


# ══════════════════════════════════════════════════════════════════════
# ── Stinger ───────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## Decode every sample for one stinger node into a bundle keyed by connection.
## stinger_data shape (from exported config.json):
##   { "samples": [path, ...], "clips": [{"volume", "weight", ...}],
##     "volume": float, "play_chance": int, "mode": String }
## JS parity: _loadStingerBundle(connectionKey, stingerData).
func _load_stinger_bundle(connection_key: String, stinger_data: Dictionary) -> void:
	var samples: Array = stinger_data.get("samples", [])
	if samples.is_empty():
		return
	var streams: Array = []
	for path in samples:
		var path_str: String = str(path)
		if path_str.is_empty():
			continue
		var stream: AudioStream = null
		if _bank_loader:
			stream = _bank_loader.get_audio_stream(path_str)
		elif not _base_path.is_empty():
			var full: String = _base_path + "/" + path_str
			var temp := PFATrack.new()
			stream = temp._load_audio_file(full)
		if stream:
			streams.append(stream)
	if streams.is_empty():
		return
	_stinger_bundles[connection_key] = {
		"streams": streams,
		"clips": stinger_data.get("clips", []),
		"volume": float(stinger_data.get("volume", 1.0)),
		"play_chance": int(stinger_data.get("play_chance", 100)),
		"mode": str(stinger_data.get("mode", "random")),
		"state": {"last_idx": -1},
	}

## Fire a one-shot stinger overlay on top of the music bed.
## Rolls play_chance, picks a variant per bundle.mode, scales by clip × bundle volume.
## JS parity: _playStinger(connectionKey).
func _play_stinger(connection_key: String) -> void:
	var bundle: Dictionary = _stinger_bundles.get(connection_key, {})
	if bundle.is_empty():
		return
	var streams: Array = bundle.get("streams", [])
	if streams.is_empty():
		return

	var chance: int = int(bundle.get("play_chance", 100))
	if chance <= 0:
		return
	if chance < 100 and randi_range(1, 100) > chance:
		return

	var idx: int = _pick_stinger_variant(bundle)
	if idx < 0 or idx >= streams.size():
		return

	var clips: Array = bundle.get("clips", [])
	var clip_vol: float = 1.0
	if idx < clips.size() and clips[idx] is Dictionary:
		clip_vol = float((clips[idx] as Dictionary).get("volume", 1.0))
	var bundle_vol: float = float(bundle.get("volume", 1.0))
	var final_amp: float = clip_vol * bundle_vol

	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.bus = _voice_bus
	player.stream = streams[idx]
	player.volume_db = _combined_db_for_amp(final_amp)
	add_child(player)
	player.play()
	player.finished.connect(func():
		if is_instance_valid(player): player.queue_free()
	)
	print("[PFA] Stinger fired (key=%s, idx=%d, mode=%s, vol=%.2f)" % [connection_key, idx, str(bundle.get("mode", "")), final_amp])

## Variant selection algorithm. Canonical mirror of core/stinger_picker.py.
## Modes: "random" | "weighted" | "no_repeat" (unknown → random).
## Mutates bundle.state.last_idx (used by no_repeat).
func _pick_stinger_variant(bundle: Dictionary) -> int:
	var streams: Array = bundle.get("streams", [])
	var n: int = streams.size()
	if n <= 0:
		return -1
	if not bundle.has("state") or not (bundle["state"] is Dictionary):
		bundle["state"] = {"last_idx": -1}
	var state: Dictionary = bundle["state"]
	if n == 1:
		state["last_idx"] = 0
		return 0
	var mode: String = str(bundle.get("mode", "random"))
	if mode == "weighted":
		var clips: Array = bundle.get("clips", [])
		if clips.size() != n:
			return randi_range(0, n - 1)
		var weights: Array = []
		for c in clips:
			var w: float = 1.0
			if c is Dictionary:
				w = float((c as Dictionary).get("weight", 1.0))
			weights.append(maxf(0.0, w))
		var total: float = 0.0
		for w in weights:
			total += w
		if total <= 0.0:
			return randi_range(0, n - 1)
		var rval: float = randf() * total
		var cum: float = 0.0
		for i in range(n):
			cum += weights[i]
			if rval < cum:
				return i
		return n - 1
	if mode == "no_repeat":
		var last: int = int(state.get("last_idx", -1))
		var choices: Array = []
		for i in range(n):
			if i != last:
				choices.append(i)
		var idx: int
		if choices.is_empty():
			idx = 0
		else:
			idx = int(choices[randi_range(0, choices.size() - 1)])
		state["last_idx"] = idx
		return idx
	return randi_range(0, n - 1)


# ══════════════════════════════════════════════════════════════════════
# ── SFX ───────────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## Cooldown + max_instances gate — voice stealing by AUDIBILITY (sess122; spawn-
## size steal sess124).
##
## ONE pool per event: flat (_sfx_voices) + spatial (_spatial_voices) count together.
## Score = pre_amp (track × clip × rand × intensity, spawn meta) × distance factor
## (spatial voices only — PFASpatial._voice_score; flat = gain alone). A trigger
## spawns ONE VOICE PER TRACK, so the gate frees room for the WHOLE spawn
## (`spawn_count`; the old single-victim gate grew the pool net +N−1 per trigger
## on multi-track events). At the cap:
##   • victims = the `spawn_count` least audible live voices (score asc, equal
##     scores → oldest by spawn_us — byte-parity with the age-only steal in
##     homogeneous scenes), clamped to the live pool;
##   • candidate strictly quieter than the LOUDEST would-be victim → REJECT (it
##     would be inaudible anyway, and must not kill a voice that isn't) — no
##     cooldown stamp, a rejected trigger is a non-event; with spawn_count 1 this
##     is exactly the old single-victim rule;
##   • otherwise every victim dies through an ANTI-CLICK seam (spatial: the
##     _STOP_FLOOR_SEC floor; flat: _release_sfx_voice silence ramp) — never the
##     authored release_fade. A steal is not an authored stop: borrowing the
##     authored fade kept slot-free voices audible ~574 ms past eviction, so
##     "audible ≤ cap" broke and a smaller cap could ring LOUDER than a bigger
##     one (sess125 defect B). Authored release stays on game stop()/destroy().
## cap <= 0 ⇒ uncapped (the documented spatial semantic, now unified).
## `candidate_amp/_dist` default to 1.0 — an optimistic candidate estimate (clip
## volume / rand unknown until the variation pick) so rejection stays conservative.
## JS: _checkCanTrigger (1f4fdd1).
func _check_can_trigger(candidate_amp: float = 1.0, candidate_dist: float = 1.0,
		spawn_count: int = 1) -> bool:
	var now_ms: float = Time.get_ticks_msec()
	if cooldown_ms > 0.0 and (now_ms - _last_trigger_time_ms) < cooldown_ms:
		return false
	_cleanup_sfx_voices()
	_cleanup_spatial_refs()
	var cap: int = int(max_instances)
	if cap > 0:
		var live: Array = []   # [ {score, spawn_us, i, player, spatial} ]
		for p in _sfx_voices:
			if is_instance_valid(p):
				live.append({"score": float(p.get_meta("pre_amp", 1.0)),
					"spawn_us": int(p.get_meta("spawn_us", 0)), "i": live.size(),
					"player": p, "spatial": false})
		for p in _spatial_voices:
			live.append({"score": _spatial_mgr._voice_score(p) if _spatial_mgr != null else \
				float(p.get_meta("pre_amp", 1.0)),
				"spawn_us": int(p.get_meta("spawn_us", 0)), "i": live.size(),
				"player": p, "spatial": true})
		var needed: int = mini(live.size() + spawn_count - cap, live.size())
		if needed > 0:
			live.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				if a["score"] != b["score"]:
					return a["score"] < b["score"]
				if a["spawn_us"] != b["spawn_us"]:
					return a["spawn_us"] < b["spawn_us"]
				return a["i"] < b["i"])
			if candidate_amp * candidate_dist < live[needed - 1]["score"]:
				return false   # honest rejection — no stamp, nothing dies
			for k in needed:
				var v: Dictionary = live[k]
				if v["spatial"]:
					# 0.0 = "as fast as click-free allows" (_STOP_FLOOR_SEC), NOT
					# -1.0 = the authored release_fade — that fade belongs to
					# game-driven stop()/destroy() only (sess125 defect B).
					_spatial_mgr._release_voice(v["player"], 0.0)
				else:
					_release_sfx_voice(v["player"])
	_last_trigger_time_ms = now_ms
	return true


## Drop dead / mid-release spatial registrations (the release ramp owns those voices;
## they no longer hold a cap slot). _free_voice unregisters on the normal lifecycle.
func _cleanup_spatial_refs() -> void:
	var alive: Array = []
	for p in _spatial_voices:
		if is_instance_valid(p) and not bool(p.get_meta("stopped", false)):
			alive.append(p)
	_spatial_voices = alive


func _register_spatial_voice(p, mgr) -> void:
	_spatial_mgr = mgr
	_spatial_voices.append(p)


func _unregister_spatial_voice(p) -> void:
	_spatial_voices.erase(p)


## Optimistic candidate loudness base: the loudest track this trigger could spawn.
func _max_track_volume() -> float:
	var m: float = 0.0
	for t in tracks:
		m = maxf(m, float(t.volume))
	return m if m > 0.0 else 1.0


## Click-free steal of a FLAT voice — the stop_sfx_voices pattern scaled to one
## player: leave the pool at once (the slot frees now), ramp to the −80 floor over
## an anti-click seam, and let the voice's OWN trim-stop / finished handler free it
## (single-owner rule — no extra freer that could race a captured player). A voice
## still waiting on its delay timer has made no sound — free it outright.
func _release_sfx_voice(player) -> void:
	_sfx_voices.erase(player)
	if not is_instance_valid(player):
		return
	if not bool(player.get_meta("sfx_started", false)):
		player.queue_free()
		return
	player.set_meta("stopped", true)
	if player.has_meta("sfx_tw"):
		var old = player.get_meta("sfx_tw")
		if old != null and is_instance_valid(old):
			old.kill()
	var start_amp: float = db_to_linear(player.volume_db)
	var setter := func(t: float) -> void:
		if not is_instance_valid(player):
			return
		var amp: float = start_amp * (1.0 - t)
		player.volume_db = maxf(linear_to_db(maxf(amp, 0.000001)), -80.0)
	var tw: Tween = player.create_tween()
	player.set_meta("sfx_tw", tw)
	tw.tween_method(setter, 0.0, 1.0, 0.02)   # 20 ms anti-click seam (JS parity)

## Trigger one SFX voice for a track. Returns a play-report dict carrying the player
## ({ player, track, behavior, variation, variation_count, algo, sample }) or {} when the
## track did not fire. JS: PFATrack.triggerSfx.
func _trigger_sfx_track(track: PFATrack, iv: Dictionary = {}) -> Dictionary:
	# always_play / level_conditional keep their samples in the shared pool, so
	# level_samples is empty for them — only gate level_specific on missing level data.
	var is_shared: bool = (track.level_behavior == "always_play" or track.level_behavior == "level_conditional")
	if not is_shared and track.level_samples.get(current_level, track.level_samples.get(0, {})).is_empty():
		return {}

	# play_chance roll
	if not track.roll_play_chance(current_level):
		return {}

	# Fresh variation per trigger (switch_chance-gated), shared vs per-level pool.
	var pick: Dictionary = track.get_sfx_stream_and_clip(current_level, true)
	if pick.is_empty():
		return {}
	var stream: AudioStream = pick["stream"]
	if stream == null:
		return {}
	var clip: PFARegionClip = pick["clip"]

	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.bus = _voice_bus
	player.stream = stream
	add_child(player)

	# Pitch + rate randomization on the player; volume randomization folds into the
	# per-voice fade target (NOT volume_db +=, which would fight the fade tween).
	track.apply_sfx_pitch_rate(player, float(iv.get("pitch_st", 0.0)))
	var vol_rand: float = track.sfx_volume_rand_linear()
	var clip_vol: float = clip.volume if clip != null else 1.0
	var steady_amp: float = track.volume * clip_vol * vol_rand * float(iv.get("gain_mult", 1.0))
	# Audibility-score meta (voice stealing): the steady programmatic gain + the age
	# tie-break. Flat voices have no distance factor — the gain IS the score.
	player.set_meta("pre_amp", steady_amp)
	player.set_meta("spawn_us", Time.get_ticks_usec())

	# Trim window [offset, offset + play_len). play_len 0 → full remaining after offset.
	var offset: float = clip.source_offset if clip != null else 0.0
	var has_window: bool = clip != null and clip.source_play_length > 0.0
	var play_len: float = clip.source_play_length if has_window else maxf(0.0, stream.get_length() - offset)
	var fade_in: float = clip.fade_in if clip != null else 0.0
	var fade_out: float = clip.fade_out if clip != null else 0.0

	# pitch_scale stretches wall-clock duration → divide the trim-stop so we cut after
	# play_len of BUFFER time (Web Audio parity). Fades keep play_len as their timeline
	# (mirrors JS positioning fade_out at startTime + playLen).
	var pitch: float = maxf(0.01, player.pitch_scale)
	var delay_ms: float = track.sfx_delay_ms()

	# Voice lifecycle timers are Timer CHILDREN of the player, not tree-scoped
	# SceneTreeTimers: a child dies WITH the player, so no timeout lambda can ever fire
	# with a freed `player` capture ("Lambda capture at index 0 was freed" — the race
	# fixed in pfa_spatial 238d8ab; HERE max_instances eviction frees a voice while its
	# trim-stop/delay timer is still pending, which made the error deterministic).
	# Bonus: child timers pause in sync with the audio they control (SceneTreeTimers
	# default to process_always and would cut a paused voice mid-pause).
	var windowed_stop: bool = has_window and play_len > 0.0
	var start_cb := func():
		if not is_instance_valid(player):
			return
		player.set_meta("sfx_started", true)
		player.play(offset)
		_apply_sfx_fade_to_player(player, steady_amp, play_len, fade_in, fade_out)
		if windowed_stop:
			var stop_t := Timer.new()
			stop_t.one_shot = true
			stop_t.wait_time = play_len / pitch
			player.add_child(stop_t)
			stop_t.timeout.connect(func():
				if is_instance_valid(player):
					player.stop()
					player.queue_free()
				_sfx_voices.erase(player)
			)
			stop_t.start()

	if delay_ms > 0.0:
		var delay_t := Timer.new()
		delay_t.one_shot = true
		delay_t.wait_time = delay_ms / 1000.0
		player.add_child(delay_t)
		delay_t.timeout.connect(start_cb)
		delay_t.start()
	else:
		start_cb.call()

	# A WINDOWED voice is freed by its stop timer ALONE (single owner — mirrors
	# pfa_spatial): if the stream ends naturally before the window elapses, freeing
	# here too would leave the (player-scoped, but already counting) stop timer to
	# double-free. Non-windowed voices are freed on natural end as before.
	player.finished.connect(func():
		if windowed_stop:
			return
		if is_instance_valid(player): player.queue_free()
		_sfx_voices.erase(player)
	)

	return {
		"player": player,
		"track": track.name,
		"behavior": track.level_behavior,
		"variation": pick["variation"],
		"variation_count": pick["variation_count"],
		"algo": track.randomization_algo,
		"sample": pick.get("sample", ""),
	}

## Apply a one-shot SFX fade envelope to a player's volume_db, mirroring the editor's
## RegionClip._apply_fades + JS _applySfxFadeEnvelope: LINEAR-amplitude ramps (not linear-dB).
## We tween the voice amplitude and route it through _combined_db_for_amp every frame, so the
## perceived ramp is linear in amplitude AND the event/group/master gain still applies. fade_out
## fires only for the one-shot window. No fades → steady volume_db at `steady_amp`.
func _apply_sfx_fade_to_player(player: AudioStreamPlayer, steady_amp: float, play_len: float, fade_in: float, fade_out: float) -> void:
	if fade_in <= 0.0 and fade_out <= 0.0:
		player.volume_db = _combined_db_for_amp(steady_amp)
		return

	# Clamp so both fades fit inside the window (preserve their ratio). JS parity.
	if play_len > 0.0 and fade_in + fade_out > play_len:
		var scale: float = play_len / (fade_in + fade_out)
		fade_in *= scale
		fade_out *= scale

	var setter := func(amp: float):
		if is_instance_valid(player):
			player.volume_db = _combined_db_for_amp(amp)

	if player.has_meta("sfx_tw"):
		var old = player.get_meta("sfx_tw")
		if old != null and is_instance_valid(old):
			old.kill()   # never two tweens fighting volume_db on one voice
	var tw: Tween = player.create_tween()
	player.set_meta("sfx_tw", tw)   # tracked so stop_sfx_voices() can kill it (no fighting curves)
	var cursor: float = 0.0
	if fade_in > 0.0:
		player.volume_db = _combined_db_for_amp(0.0)  # start silent
		tw.tween_method(setter, 0.0, steady_amp, fade_in)
		cursor = fade_in
	else:
		player.volume_db = _combined_db_for_amp(steady_amp)

	if fade_out > 0.0:
		var hold: float = maxf(0.0, play_len - fade_out - cursor)
		if hold > 0.0:
			tw.tween_interval(hold)
		tw.tween_method(setter, steady_amp, 0.0, fade_out)

func _cleanup_sfx_voices() -> void:
	var alive: Array = []
	for p in _sfx_voices:
		# Keep voices that are audible OR still waiting on their delay timer (not yet
		# started) — pruning a delayed voice would hide it from eviction and stop().
		if is_instance_valid(p) and (p.playing or not bool(p.get_meta("sfx_started", false))):
			alive.append(p)
	_sfx_voices = alive


## Stop the active one-shot SFX voices (the trigger() voices) over `dur`, shaping the ramp
## with the release-fade `curve` (same _eval_fade_in_curve family as every other fade —
## the web engine shapes this fade through event._eventGain, so the curve is honored on
## both platforms). We only SILENCE (ramp the voice amplitude → −80 dB floor); each voice's
## own trim-stop / finished handler still frees it, so we add NO extra freer that could
## race a captured player to a freed instance. A voice still waiting on its delay timer
## has made no sound yet — free it outright (its child timers die with it, so the delayed
## start can never fire afterwards).
func stop_sfx_voices(dur: float, curve: String = "equal_power") -> void:
	_cleanup_sfx_voices()
	var fade: float = maxf(dur, 0.02)   # ≥ 20 ms anti-click
	for player in _sfx_voices.duplicate():
		if not is_instance_valid(player):
			continue
		if not bool(player.get_meta("sfx_started", false)):
			_sfx_voices.erase(player)
			player.queue_free()
			continue
		if player.has_meta("sfx_tw"):
			var old = player.get_meta("sfx_tw")
			if old != null and is_instance_valid(old):
				old.kill()
		# Fade-out shape = f(1−t), symmetric to fade-in (the _equal_power_tween_to_amp
		# convention). Amplitude-domain so the curve means the same thing as everywhere
		# else; the −80 dB floor is Godot's effective silence.
		var start_amp: float = db_to_linear(player.volume_db)
		var curve_name: String = curve
		var setter := func(t: float):
			if not is_instance_valid(player):
				return
			var amp: float = start_amp * _eval_fade_in_curve(1.0 - t, curve_name)
			player.volume_db = maxf(linear_to_db(maxf(amp, 0.000001)), -80.0)
		var tw: Tween = player.create_tween()
		player.set_meta("sfx_tw", tw)
		tw.tween_method(setter, 0.0, 1.0, fade)


# ══════════════════════════════════════════════════════════════════════
# ── Event Gain (anti-click, duck, fadeIn/Out) ─────────────────────────
# ══════════════════════════════════════════════════════════════════════

## Set event-gain amp immediately and apply to all active players.
func _set_event_gain_amp(amp: float) -> void:
	_event_gain_amp = amp
	_apply_event_gain_to_all_active()

## Tween event gain to target over duration. Kills previous tween.
## `curve` (editor parity): linear / equal_power / s_curve / exponential / logarithmic.
func _tween_event_gain(target: float, duration: float, curve: String = "equal_power") -> void:
	if _event_gain_tween and _event_gain_tween.is_valid():
		_event_gain_tween.kill()
	if duration <= 0.0:
		_set_event_gain_amp(target)
		return
	# Anti-click frame-rate floor: Godot writes volume_db once per game frame (~16.7ms),
	# so a sub-2-frame fade renders as a step → click. Mirrors _ramp_level_gain's floor.
	if duration < _MICRO_FADE_SEC:
		duration = _MICRO_FADE_SEC
	var start_amp: float = _event_gain_amp
	var is_fade_in: bool = target > start_amp
	var curve_name: String = curve
	_event_gain_tween = create_tween()
	_event_gain_tween.tween_method(func(t: float):
		var shape: float
		if is_fade_in:
			shape = _eval_fade_in_curve(t, curve_name)
		else:
			shape = _eval_fade_in_curve(1.0 - t, curve_name)
		var v: float
		if is_fade_in:
			v = start_amp + (target - start_amp) * shape
		else:
			v = target + (start_amp - target) * shape
		_event_gain_amp = v
		_apply_event_gain_to_all_active()
	, 0.0, 1.0, duration)

## Walk every active per-(track, level) and shared player — update volume_db with new event gain.
## This does NOT kill level tweens; it instead scales the tween's own output by updating
## _event_gain_amp which is read inside level tween methods. But we also need to apply to
## players whose level tween is NOT running (e.g. sub-levels, stinger). Walk all.
func _apply_event_gain_to_all_active() -> void:
	for track_name in _track_players.keys():
		var level_map: Dictionary = _track_players[track_name]
		for lvl in level_map:
			var data: Dictionary = level_map[lvl]
			var players: Array = data.get("players", [])
			var active: int = data.get("active", 0)
			if active < 0 or active >= players.size():
				continue
			var p: AudioStreamPlayer = players[active]
			if not is_instance_valid(p):
				continue
			# Only touch if NO active level tween — otherwise the tween is in charge.
			var lvl_state: Dictionary = _track_level_state.get(track_name, {}).get(lvl, {})
			var lvl_tween: Tween = lvl_state.get("tween", null)
			if lvl_tween and lvl_tween.is_valid():
				continue  # tween will handle event gain on each frame
			var target_amp: float = float(lvl_state.get("target_amp", 0.0))
			p.volume_db = _combined_db_for_amp(target_amp)
	# Shared players
	for track_name in _track_shared.keys():
		var shared: Dictionary = _track_shared[track_name]
		var players: Array = shared.get("players", [])
		var active: int = shared.get("active", 0)
		if active < 0 or active >= players.size():
			continue
		var p: AudioStreamPlayer = players[active]
		if is_instance_valid(p):
			var track := _find_track_by_name(track_name)
			if track:
				p.volume_db = _combined_db_for_amp(track.volume)
	# Sub-level players
	for sub_name in _sub_level_states.keys():
		var st: Dictionary = _sub_level_states[sub_name]
		for p in st.get("players", []):
			if is_instance_valid(p):
				# We don't track per-sub target; leave to disable-fade tween.
				pass


# ══════════════════════════════════════════════════════════════════════
# ── Helpers (volume / loop / offset) ──────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## Combine pre-event-gain amp with all global factors and return db.
func _combined_db_for_amp(pre_amp: float) -> float:
	var f: float = _event_group_master_factor()
	var effective: float = pre_amp * f
	if effective <= 0.0001 or _group_mute:
		return -80.0
	return _amp_to_db(effective)

## Combined dB for a SPATIAL SFX voice's base amplitude — folds event volume × group ×
## master (a freshly-triggered SFX's event gain == its volume, mirroring trigger_sfx's
## _set_event_gain_amp(volume)). Godot's node attenuation_model layers distance ON TOP of
## this base volume_db. -80 dB on mute / silence. PFASpatial reads this for each voice.
func combined_sfx_db(pre_amp: float) -> float:
	if _group_mute:
		return -80.0
	# While ducked, the duck target REPLACES the event volume (mirrors the music
	# gain, which duck tweens to that absolute level) — live mute/solo from the
	# editor ride duck, so spatial voices must fold it too.
	var ev_amp: float = _effective_event_amp()
	return _amp_to_db(pre_amp * ev_amp * _group_volume * _master_volume)

func _event_group_master_factor() -> float:
	if _group_mute:
		return 0.0
	return _event_gain_amp * _group_volume * _master_volume

func _amp_to_db(amp: float) -> float:
	if amp <= 0.0001:
		return -80.0
	return 20.0 * (log(amp) / log(10.0))

func _db_to_amp(db: float) -> float:
	if db <= -79.9:
		return 0.0
	return pow(10.0, db / 20.0)

## Wall-clock seconds. In Godot there's no AudioServer equivalent to Web Audio ctx.currentTime;
## Tween + SceneTreeTimer operate on frame-step wall-clock so we use the same domain.
func _now() -> float:
	return float(Time.get_ticks_usec()) / 1_000_000.0

## Set loop flags per-format (JS: loopStart/loopEnd = the CLIP window on the source).
## WAV expresses the clip window natively (loop points are frames). OGG/MP3 have no
## loop-END property — the stream wraps at its natural FILE end, which is NOT the clip
## boundary when the file carries encoder padding (china bass: +2048 samples = +42.7ms
## of drift per wrap vs the sample-exact drums) or an authored region. For those,
## _maybe_drive_clip_wrap() drives the wrap manually.
func _setup_loop(stream: AudioStream, clip: PFARegionClip = null) -> void:
	if stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		var total: int = _wav_frames(stream)
		var begin: int = 0
		var end: int = total
		if clip != null and clip.source_play_length > 0.0:
			begin = clampi(int(round(clip.source_offset * stream.mix_rate)), 0, total)
			end = clampi(int(round((clip.source_offset + clip.source_play_length) * stream.mix_rate)), 0, total)
			if end <= begin:
				begin = 0
				end = total
		stream.loop_begin = begin
		stream.loop_end = end
	elif stream is AudioStreamOggVorbis:
		stream.loop = true
		if clip != null and clip.source_offset > 0.0:
			# Fallback wrap point if the manual driver ever misses: restart at the
			# clip start, not file start.
			stream.loop_offset = clip.source_offset
	elif stream is AudioStreamMP3:
		stream.loop = true

## Resolve the PFARegionClip for variation `var_idx` (null when absent/foreign).
static func _clip_at(clips: Array, var_idx: int) -> PFARegionClip:
	if var_idx < clips.size() and clips[var_idx] is PFARegionClip:
		return clips[var_idx]
	return null

## Return the stream a clip-windowed voice should play. ResourceLoader.load()
## CACHES — every (event, track, level, variation) referencing the same file gets
## the same stream object, so writing clip-specific loop points onto it is
## last-writer-wins (two regions of one file would share one window). Duplicate
## before mutating, exactly like PFASpatial does (pfa_spatial.gd). Duplication is
## shallow — the sample data PackedByteArray is shared copy-on-write, so it's cheap.
## Full-file voices (clip == null / no window) keep the shared instance: the values
## _setup_loop writes for them are identical for every user of the file.
static func _prepare_loop_stream(stream: AudioStream, clip: PFARegionClip) -> AudioStream:
	if clip == null or clip.source_play_length <= 0.0:
		return stream
	var writes_clip_values: bool = (stream is AudioStreamWAV) \
			or (stream is AudioStreamOggVorbis and clip.source_offset > 0.0)
	if writes_clip_values:
		return stream.duplicate()
	return stream

## OGG/MP3 cannot express a loop END, so when a looping music clip's window is
## shorter than its file the stream wraps LATE every cycle and nothing ever
## resyncs (china bass: +2048 padding samples = +42.7ms/wrap drift against the
## sample-exact 8s drums; web is immune via loopEnd = offset + sourcePlayLength).
## Drive the wrap manually: a timer chain on the SAME wall-clock grid the
## conductor's boundary math uses (_play_start_time domain) re-seeks the voice to
## the grid-true position each clip cycle. Error per wrap = timer lateness
## (≤ ~1 frame, plays a sliver of padding at the seam) and does NOT accumulate —
## every seek re-locks phase to the grid. Sample-exact files (cave, advanced_music)
## never enter here: the natural stream wrap already IS the clip window.
func _maybe_drive_clip_wrap(player: AudioStreamPlayer, stream: AudioStream, clip: PFARegionClip,
		start_phase: float = 0.0) -> void:
	if stream is AudioStreamWAV:
		return  # native loop points carry the window sample-exactly
	if clip == null or clip.source_play_length <= 0.05 or clip.is_one_shot():
		return  # 50ms floor mirrors the smart-loop's — no high-rate seek chains
	var stream_len: float = stream.get_length() if stream.has_method("get_length") else 0.0
	var clip_end: float = clip.source_offset + clip.source_play_length
	if clip.source_offset <= 0.002 and (stream_len <= 0.0 or absf(stream_len - clip_end) <= 0.002):
		return  # file matches the clip — natural loop is correct
	var state: Dictionary = {
		# Phase origin: a voice may start mid-clip (sub-levels join phase-aligned to
		# the event clock) — boundaries live at anchor + k×len in AUDIO phase, so
		# back-date the anchor by the start phase.
		"anchor": _now() - fmod(maxf(start_phase, 0.0), clip.source_play_length),
		"len": clip.source_play_length,
		"offset": clip.source_offset, "gen": 0,
	}
	_clip_wrap_state[player.get_instance_id()] = state
	_schedule_clip_wrap(player.get_instance_id(), state)

func _schedule_clip_wrap(player_id: int, state: Dictionary) -> void:
	var len_s: float = float(state["len"])
	if len_s <= 0.0:
		return
	var now: float = _now()
	var k: int = int(floor((now - float(state["anchor"])) / len_s)) + 1
	var delay: float = maxf(0.001, float(state["anchor"]) + k * len_s - now)
	var captured_gen: int = int(state["gen"])
	var wrap_timer: SceneTreeTimer = get_tree().create_timer(delay)
	# Both captures are INTS — the event or the voice can be freed while the chain
	# is pending (stop teardown, load_pack reload); a freed Object capture makes
	# Godot print "Lambda capture freed" before the guard even runs.
	var self_id := get_instance_id()
	wrap_timer.timeout.connect(func():
		var ev = instance_from_id(self_id)
		if ev == null:
			return
		var player = instance_from_id(player_id)
		if player == null or not (player is AudioStreamPlayer):
			ev._clip_wrap_state.erase(player_id)
			return
		if not ev._clip_wrap_state.has(player_id):
			return  # torn down
		var st: Dictionary = ev._clip_wrap_state[player_id]
		if int(st["gen"]) != captured_gen:
			return  # re-anchored (restart_on_entry) — a fresh chain owns the grid
		if player.playing:
			var pos_in_clip: float = fmod(ev._now() - float(st["anchor"]), float(st["len"]))
			player.seek(float(st["offset"]) + pos_in_clip)
		ev._schedule_clip_wrap(player_id, st)
	)

## Total frame count of a WAV stream — the correct LOOP_FORWARD loop_end.
## AudioStreamWAV loop points are in FRAMES; loop_end = 0 is NOT "end of data"
## (a prior comment here claimed it was): it makes a degenerate [0,0] loop that
## pins the voice at position 0 until the mixer kills it (verified on Godot
## 4.6.2 with both a real file and a synthetic stream). The pre-v1.9.3 formula
## `data.size()/2` overshot on stereo (samples ≠ frames) — divide by channels.
static func _wav_frames(stream: AudioStreamWAV) -> int:
	var bytes_per_sample: int
	match stream.format:
		AudioStreamWAV.FORMAT_16_BITS:
			bytes_per_sample = 2
		AudioStreamWAV.FORMAT_8_BITS:
			bytes_per_sample = 1
		_:
			# Compressed formats (IMA-ADPCM / QOA): byte math doesn't apply —
			# derive frames from the decoded length instead.
			return int(round(stream.get_length() * stream.mix_rate))
	var channels: int = 2 if stream.stereo else 1
	@warning_ignore("integer_division")   # frame math is integral by definition
	return stream.data.size() / (bytes_per_sample * channels)

## Compute initial playback offset for a new source — mirrors JS source.start(now, offset) semantics.
func _compute_initial_offset(stream: AudioStream, clips: Array, var_idx: int, offset_seconds: float) -> float:
	if var_idx < clips.size() and clips[var_idx] is PFARegionClip:
		var clip: PFARegionClip = clips[var_idx]
		if clip and clip.source_play_length > 0.0:
			var clip_dur: float = clip.source_play_length
			var loop_offset: float = fmod(offset_seconds, clip_dur) if clip_dur > 0 else 0.0
			# Godot play(pos) takes absolute position in the stream; JS offset is added to sourceOffset.
			return clip.source_offset + loop_offset
	var length: float = stream.get_length() if stream and stream.has_method("get_length") else 0.0
	if length <= 0.0:
		return 0.0
	return fmod(offset_seconds, length)

## Get length (sec) of first available audio stream at current level — for free_tempo auto-advance.
func _get_current_clip_length_sec() -> float:
	for track in tracks:
		var streams: Array = track._streams.get(current_level, [])
		if streams.is_empty():
			continue
		var s: AudioStream = streams[0]
		if s and s.has_method("get_length"):
			var ln: float = s.get_length()
			if ln > 0.0:
				return ln
	return 0.0

## Update _bar_duration_sec from current node's BPM/TS (Tempo flatten).
func _sync_bar_duration_to_current_node() -> void:
	if current_node.is_empty():
		return
	var node: Dictionary = _node_graph_data.get("nodes", {}).get(current_node, {})
	if node.is_empty():
		return
	var node_bpm: float = float(node.get("bpm", bpm))
	var node_ts: Array = node.get("time_signature", time_signature)
	var beats_per_bar: int = int(node_ts[0]) if node_ts.size() > 0 else 4
	if node_bpm > 0.0 and beats_per_bar > 0:
		_bar_duration_sec = (60.0 / node_bpm) * beats_per_bar

## Stop all per-level pre-started players for a track.
func _stop_all_level_players(track: PFATrack) -> void:
	var level_map: Dictionary = _track_players.get(track.name, {})
	for lvl in level_map:
		var data: Dictionary = level_map[lvl]
		for p in data.get("players", []):
			if is_instance_valid(p):
				_clip_wrap_state.erase(p.get_instance_id())
				p.stop()
				p.queue_free()
	_track_players.erase(track.name)
	_track_level_state.erase(track.name)
	_track_variation_counter.erase(track.name)

## Stop shared-track player.
func _stop_shared_player(track: PFATrack) -> void:
	var shared: Dictionary = _track_shared.get(track.name, {})
	for p in shared.get("players", []):
		if is_instance_valid(p):
			_clip_wrap_state.erase(p.get_instance_id())
			p.stop()
			p.queue_free()
	_track_shared.erase(track.name)

func _find_track_by_name(n: String) -> PFATrack:
	for t in tracks:
		if t.name == n:
			return t
	return null


# ══════════════════════════════════════════════════════════════════════
# ── Sample Loading ────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## Load audio streams for all tracks + sub-level tracks + stingers.
func load_samples() -> void:
	if _samples_loaded:
		return
	for track in tracks:
		if _bank_loader:
			track._bank_loader = _bank_loader
		track.load_streams(_base_path)
	# Sub-level tracks
	for key in _sub_level_tracks:
		var sub: Dictionary = _sub_level_tracks[key]
		for track in sub.get("tracks", []):
			if _bank_loader:
				track._bank_loader = _bank_loader
			track.load_streams(_base_path)
	# Stinger bundles from node graph (v2: connection.stinger is a Dictionary).
	# Bundles keyed by `${src}::${tgt}` so 1:N reuse keeps independent state.
	if not _node_graph_data.is_empty():
		var connections: Array = _node_graph_data.get("connections", [])
		for conn in connections:
			var stinger_data = conn.get("stinger", null)
			if not (stinger_data is Dictionary):
				continue
			var stinger_dict: Dictionary = stinger_data
			if (stinger_dict.get("samples", []) as Array).is_empty():
				continue
			var key: String = "%s::%s" % [str(conn.get("source", "")), str(conn.get("target", ""))]
			if _stinger_bundles.has(key):
				continue
			_load_stinger_bundle(key, stinger_dict)
	_samples_loaded = true

## Unload audio streams (free memory).
func unload_samples() -> void:
	stop_playback()
	for track in tracks:
		track.unload_streams()
	for key in _sub_level_tracks:
		var sub: Dictionary = _sub_level_tracks[key]
		for track in sub.get("tracks", []):
			track.unload_streams()
	_stinger_bundles.clear()
	_samples_loaded = false


# ══════════════════════════════════════════════════════════════════════
# ── Parse sub-levels from config (called by PFA._create_event) ────────
# ══════════════════════════════════════════════════════════════════════

## Parse sub-level tracks (creates PFATrack instances, owned by event).
func parse_sub_levels(data: Dictionary) -> void:
	_sub_level_data = data.get("sub_levels", {})
	for level_idx_key in _sub_level_data:
		var subs: Array = _sub_level_data[level_idx_key]
		for sub in subs:
			var key: String = "%s_%s" % [level_idx_key, sub.get("name", "")]
			var sub_tracks: Array = []
			for track_data in sub.get("tracks", []):
				var t := PFATrack.new()
				_populate_track_from_data(t, track_data)
				sub_tracks.append(t)
			_sub_level_tracks[key] = {
				"name": sub.get("name", ""),
				"level_index": int(level_idx_key),
				"volume": float(sub.get("volume", 1.0)),
				"tracks": sub_tracks,
			}

## Populate a PFATrack from config data — used for main tracks AND sub-level tracks.
## Public so PFA._create_event can reuse (but conventionally private).
func _populate_track_from_data(t: PFATrack, d: Dictionary) -> void:
	t.name = d.get("name", "Track")
	t.volume = float(d.get("volume", 1.0))
	t.level_behavior = d.get("level_behavior", "level_specific")
	t.repeat_count = int(d.get("repeat_count", 1))
	t.chance_reroll_bars = int(d.get("chance_reroll_bars", 1))
	t.randomization_algo = d.get("randomization_algo", "random")
	t.chance_fade_mode = d.get("chance_fade_mode", "instant")
	t.chance_fade_duration = float(d.get("chance_fade_duration", 0.5))
	t.play_chance_mode = d.get("play_chance_mode", "true_random")
	t.randomization = d.get("randomization", {})

	# Shared (always_play / level_conditional) samples
	t._shared_sample_files = d.get("samples", [])
	var shared_clips_data: Array = d.get("clips", [])
	var shared_clips: Array = []
	for cd in shared_clips_data:
		shared_clips.append(PFARegionClip.from_dict(cd))
	t._shared_clips_config = shared_clips

	# Per-level info
	var levels_data: Dictionary = d.get("levels", {})
	for level_key in levels_data:
		var info: Dictionary = levels_data[level_key]
		var lvl: int = int(level_key)
		t.level_samples[lvl] = {
			"files": info.get("samples", []),
			"clips": info.get("clips", []),
			"loop_bars": int(info.get("loop_bars", 4)),
			"switch_chance": float(info.get("switch_chance", 100)),
			"play_chance": float(info.get("play_chance", 100)),
			"repeat_count": int(info.get("repeat_count", 1)),
			"randomization_algo": info.get("randomization_algo", "no_repeat"),
			"play_chance_mode": info.get("play_chance_mode", "true_random"),
			"chance_reroll_bars": int(info.get("chance_reroll_bars", 1)),
		}
