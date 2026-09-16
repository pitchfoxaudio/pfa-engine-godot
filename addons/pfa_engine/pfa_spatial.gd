class_name PFASpatial
extends Node

## Spatial audio manager — 2D and 3D positional SFX + persistent emitters.
##
## DESIGN (idiomatic Godot; reference = Godot docs + FMOD's 3D model):
##   • Positional VOLUME + PANNING are done by Godot's built-in AudioStreamPlayer2D /
##     AudioStreamPlayer3D. Those nodes re-attenuate from their global_position vs the
##     current AudioListener EVERY mix frame — so a moving emitter just updates its players'
##     global_position; there is NO per-frame engine update loop (unlike the JS engine,
##     which does the distance/pan math by hand). This is the Godot-correct approach.
##   • The per-event PFA `spatial` config (authored in the editor; same snake_case block the
##     JS engine + exporter use) selects the attenuation MODEL + distances + panning. We map
##     it onto the node properties: model → attenuation_model, min_distance → unit_size
##     (3D) / falloff exponent (2D), max_distance → max_distance, etc.
##   • This is FEATURE parity with the JS engine (trigger_spatial / create_emitter / per-event
##     attenuation / loop modes / release-fade), NOT curve-for-curve parity. Godot has no
##     binaural HRTF, so 3D uses speaker panning (panning_model is informational only).
##
## Voice assembly (variation pick, switch_chance, pitch/rate/volume randomization, clip trim,
## combined gain) reuses the SAME public PFATrack / PFAEvent helpers as the non-spatial SFX
## path, so a spatial trigger behaves identically to trigger_sfx() apart from positioning.

# ── Config ────────────────────────────────────────────────────────────

## Engine defaults. Mirrors JS _SPATIAL_DEFAULTS (minDistance 1, maxDistance 50, inverse).
const _DEFAULTS := {
	"mode": "2D", "model": "inverse",
	"min_distance": 1.0, "max_distance": 50.0, "rolloff": 1.0,
	"panning_model": "equalpower", "max_pan": 1.0,
	"doppler": 0.0,
	# Distance LPF (3D) — knobs for Godot's NATIVE attenuation filter (a
	# highshelf at cutoff whose gain deepens toward lpf_db with distance).
	# SHARED flat keys; defaults = the AudioStreamPlayer3D node defaults, so
	# old configs keep Godot's long-standing audible behaviour. The web engine
	# mirrors the same semantics per voice (deliberate platform alignment).
	"lpf_enabled": true, "lpf_cutoff_hz": 5000.0, "lpf_db": -24.0,
}
const _CFG_KEYS := ["mode", "model", "min_distance", "max_distance", "rolloff", "panning_model", "max_pan", "doppler", "lpf_enabled", "lpf_cutoff_hz", "lpf_db"]
const _SILENCE_DB := -80.0          # Godot's effective silence floor; fade targets land here
const _SMART_CROSS := 0.08          # 80 ms crossfade seam on a smart re-loop (JS parity)
# Anti-click floor for voice release. volume_db moves per-FRAME (tween), so a sub-2-frame
# ramp collapses to a step = audible click when a LOOP is cut mid-wave (observed on a rolling-ball
# loop stopped mid-roll); one-shots end at a natural zero and never hit this.
# 0.030 = pfa_event._MICRO_FADE_SEC: ~2 frames @ 60 fps. Applies to EVERY
# release path — destroy(0) / stop_all_voices(0) / max_instances steal; clear_all()
# alone stays a hard teardown by design (scene-change bulk free).
const _STOP_FLOOR_SEC := 0.030

# ── Listener ──────────────────────────────────────────────────────────

var _world_scale: float = 1.0       # game units per audio meter (3D) / per audio unit (2D px)
var _listener_2d: AudioListener2D = null
var _listener_3d: AudioListener3D = null

# ── PFA reference (event lookup + per-event gain) ─────────────────────

var _pfa: Node = null

# ── Active voices / emitters ──────────────────────────────────────────

var _voices: Array = []             # all live AudioStreamPlayer2D/3D voices (for cleanup)
var _emitters: Array = []           # live PFASpatialEmitter instances
# EVERY live smart-loop controller, emitter-owned or not. The controller is what
# re-spawns audible voices each cycle, so every stop door must be able to reach
# it — before this registry, an emitter-less controller (plain trigger_spatial on
# a smart-loop event) was reachable by NOBODY: stop()/stop_all() faded the voice
# and the controller spawned the next one anyway (JS parity: the emitter-less
# re-loop chain is voice-owned there and dies inside voice.stop()).
var _smart_ctrls: Array = []


# ══════════════════════════════════════════════════════════════════════
# ── World scale + listener (coordinate-driven internal AudioListener) ─
# ══════════════════════════════════════════════════════════════════════

## Game units per audio meter. JS: setWorldScale. Example: 100 ⇒ 100 px = 1 audio unit.
func set_world_scale(units_per_meter: float) -> void:
	_world_scale = maxf(0.0001, units_per_meter)


## Set the 2D listener world position (pixels). Call every frame. Drives an internal
## AudioListener2D (created + made current on first call) so the engine owns the listener
## independent of any camera. JS: setListener2D(x, y).
func set_listener_2d(pos: Vector2) -> void:
	if _listener_2d == null or not is_instance_valid(_listener_2d):
		_listener_2d = AudioListener2D.new()
		_listener_2d.name = "PFAListener2D"
		add_child(_listener_2d)
		_listener_2d.make_current()
	_listener_2d.global_position = pos


## Set the 3D listener world position + orientation. Call every frame. Drives an internal
## AudioListener3D (created + made current on first call). Coordinate system matches JS:
## -Z forward, +Y up. JS: setListener3D(x,y,z, fwd, up).
func set_listener_3d(pos: Vector3, forward: Vector3 = Vector3(0, 0, -1), up: Vector3 = Vector3(0, 1, 0)) -> void:
	if _listener_3d == null or not is_instance_valid(_listener_3d):
		_listener_3d = AudioListener3D.new()
		_listener_3d.name = "PFAListener3D"
		add_child(_listener_3d)
		_listener_3d.make_current()
	var p: Vector3 = pos / _world_scale
	_listener_3d.global_position = p
	# Orient the listener: -Z toward `forward`. Guard a degenerate forward∥up (look_at fails).
	var fwd: Vector3 = forward.normalized() if forward.length() > 0.0001 else Vector3(0, 0, -1)
	var u: Vector3 = up.normalized() if up.length() > 0.0001 else Vector3(0, 1, 0)
	if absf(fwd.dot(u)) < 0.999:
		_listener_3d.look_at(p + fwd, u)


# ══════════════════════════════════════════════════════════════════════
# ── Public trigger API (called by PFA, which resolves the event) ──────
# ══════════════════════════════════════════════════════════════════════

## One-shot (or loop, per event.loop) spatial SFX at a 2D position. Returns the first voice.
func trigger_spatial_2d(event, x: float, y: float, config: Dictionary = {}) -> Object:
	return _trigger_oneshot(event, "2D", Vector3(x, y, 0.0), config)


## One-shot (or loop) spatial SFX at a 3D position. Returns the first voice.
func trigger_spatial_3d(event, x: float, y: float, z: float, config: Dictionary = {}) -> Object:
	return _trigger_oneshot(event, "3D", Vector3(x, y, z), config)


## Create a 2D emitter for the event. The game sets position + triggers; voices follow.
func create_emitter_2d(event_name: String, config: Dictionary = {}) -> PFASpatialEmitter:
	var e := PFASpatialEmitter.new(self, event_name, "2D", config)
	_emitters.append(e)
	return e


## Create a 3D emitter for the event.
func create_emitter_3d(event_name: String, config: Dictionary = {}) -> PFASpatialEmitter:
	var e := PFASpatialEmitter.new(self, event_name, "3D", config)
	_emitters.append(e)
	return e


# ══════════════════════════════════════════════════════════════════════
# ── Trigger orchestration ─────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

func _trigger_oneshot(event, mode: String, pos: Vector3, config: Dictionary) -> Object:
	if event == null:
		return null
	if not event._samples_loaded:
		event.load_samples()
	var cfg := _merge_cfg(_event_spatial(event), config)
	cfg["mode"] = mode
	# Per-trigger intensity / velocity: game passes config.intensity (0..1), the event's
	# authored curve maps it. Carried in cfg so every spawned/re-looped voice shares it.
	# Resolved BEFORE the cap gate — the candidate's audibility score needs it.
	cfg["_intensity"] = PFATrack.intensity_gain_pitch(float(config.get("intensity", 1.0)), event.intensity)
	var cand_amp: float = float(cfg["_intensity"].get("gain_mult", 1.0)) * event._max_track_volume()
	if not event._check_can_trigger(cand_amp, _att_at(mode, pos, cfg), event.tracks.size()):
		return null
	return _trigger_tracks(event, mode, pos, cfg, _release_ms_for(event), null)


## Called by PFASpatialEmitter.trigger().
func _trigger_on_emitter(emitter: PFASpatialEmitter, event_name: String) -> Object:
	var event = _get_event(event_name)
	if event == null:
		return null
	if not event._samples_loaded:
		event.load_samples()
	var cfg := _merge_cfg(_event_spatial(event), emitter._cfg)
	cfg["mode"] = emitter._mode      # emitter mode is fixed at creation
	cfg["_intensity"] = PFATrack.intensity_gain_pitch(float(emitter._cfg.get("intensity", 1.0)), event.intensity)
	var cand_amp: float = float(cfg["_intensity"].get("gain_mult", 1.0)) * event._max_track_volume()
	if not event._check_can_trigger(cand_amp, _att_at(emitter._mode, emitter._pos, cfg), event.tracks.size()):
		return null
	return _trigger_tracks(event, emitter._mode, emitter._pos, cfg, _release_ms_for(event), emitter)


# ══════════════════════════════════════════════════════════════════════
# ── Audibility scoring (voice stealing) ──────────────────────
# ══════════════════════════════════════════════════════════════════════
#
# The cap itself lives in PFAEvent._check_can_trigger — ONE pool per event, flat +
# spatial voices together (JS parity: the web engine keeps a single _activeVoices).
# This section only supplies the spatial half of the score: each voice's steady
# programmatic gain (meta pre_amp = track × clip × rand × intensity) shaded by the
# engine's OWN attenuation curve at the voice's current distance from the listener.
# Godot applies its native attenuation on playback; this curve is for RANKING only,
# so JS-formula parity (incl. the 10% boundary taper) is the right choice — both
# engines then rank identically from the same authored config.

## Full audibility score of a live spatial voice (meta written by _spawn_voice).
func _voice_score(p) -> float:
	return float(p.get_meta("pre_amp", 1.0)) * _distance_factor(p)


## Distance shading for a live voice: 1.0 when no PFA listener exists (the game
## drives Godot's own camera/listener — distance unknown, rank on gain alone).
func _distance_factor(p) -> float:
	var att: Dictionary = p.get_meta("att", {})
	if att.is_empty():
		return 1.0
	if str(p.get_meta("spatial_mode", "2D")) == "3D":
		if _listener_3d == null or not is_instance_valid(_listener_3d) or not p.is_inside_tree():
			return 1.0
		return attenuation_gain(p.global_position.distance_to(_listener_3d.global_position), att)
	if _listener_2d == null or not is_instance_valid(_listener_2d) or not p.is_inside_tree():
		return 1.0
	var px: float = p.global_position.distance_to(_listener_2d.global_position)
	return attenuation_gain(px / _world_scale, att)


## Candidate score shading at a would-be spawn position (game units / pixels).
func _att_at(mode: String, pos: Vector3, cfg: Dictionary) -> float:
	var att := {"model": str(cfg.get("model", "inverse")),
		"min_distance": float(cfg.get("min_distance", 1.0)),
		"max_distance": float(cfg.get("max_distance", 50.0)),
		"rolloff": float(cfg.get("rolloff", 1.0))}
	if mode == "3D":
		if _listener_3d == null or not is_instance_valid(_listener_3d):
			return 1.0
		return attenuation_gain((pos / _world_scale).distance_to(_listener_3d.global_position), att)
	if _listener_2d == null or not is_instance_valid(_listener_2d):
		return 1.0
	var px: float = Vector2(pos.x, pos.y).distance_to(_listener_2d.global_position)
	return attenuation_gain(px / _world_scale, att)


## JS _computeDistanceAttenuation port (index.js) — distance in audio units.
## Inverse / linear / exponential + the web path's 10% boundary taper to 0 at
## max_distance. Pure function (static) — unit-tested directly.
static func attenuation_gain(distance: float, att: Dictionary) -> float:
	var min_d: float = maxf(0.0001, float(att.get("min_distance", 1.0)))
	var max_d: float = float(att.get("max_distance", 50.0))
	var rolloff: float = float(att.get("rolloff", 1.0))
	if distance <= min_d:
		return 1.0
	if max_d > 0.0 and distance >= max_d:
		return 0.0
	var gain: float
	match str(att.get("model", "inverse")):
		"linear":
			gain = 1.0 if max_d <= min_d else \
				maxf(0.0, 1.0 - rolloff * (distance - min_d) / (max_d - min_d))
		"exponential":
			gain = pow(distance / min_d, -rolloff)
		_:
			gain = min_d / (min_d + rolloff * (distance - min_d))
	if max_d > 0.0:
		var taper_start: float = max_d * 0.9
		if distance > taper_start:
			gain *= (max_d - distance) / (max_d - taper_start)
	return gain


## Spawn one voice per track (or, for smart loop, one controller per track). Returns the
## first voice for the caller's convenience.
func _trigger_tracks(event, mode: String, pos: Vector3, cfg: Dictionary, release_ms: float, emitter) -> Object:
	var loop_mode := _resolve_loop_mode(event)
	var first: Object = null
	for track in event.tracks:
		if loop_mode == "smart":
			var ctrl := _start_smart_loop(event, track, mode, pos, cfg, release_ms, emitter)
			var a = ctrl.get("active", null)
			if first == null and a != null:
				first = a
		else:
			var v = _spawn_voice(event, track, mode, pos, cfg, release_ms, emitter, loop_mode == "seamless", false)
			if v != null:
				if emitter != null:
					emitter._players.append(v)
				if first == null:
					first = v
	return first


## Resolve the loop mode for an event: explicit event.loop (SFX, editor-authored) wins;
## a music-type event loops seamlessly by nature; otherwise one-shot. JS: triggerSfxSpatial.
func _resolve_loop_mode(event) -> String:
	var lcfg: Dictionary = event.loop if event.loop != null else {}
	if not lcfg.is_empty() and bool(lcfg.get("enabled", false)):
		return "smart" if str(lcfg.get("mode", "seamless")) == "smart" else "seamless"
	if event.type == "music":
		return "seamless"
	return ""


# ══════════════════════════════════════════════════════════════════════
# ── Voice assembly (one positional player; reuses track/event helpers) ─
# ══════════════════════════════════════════════════════════════════════

## Build ONE spatial voice for `track` at `pos`. `seamless` ⇒ native gapless loop; otherwise
## a one-shot (also the per-cycle spawn for a smart loop, via the controller). Reuses the
## SAME variation pick / randomization / clip trim / gain as non-spatial SFX. Returns the
## player (AudioStreamPlayer2D|3D) or null when play_chance / pick fails. `skip_play_chance`
## is the smart re-loop (the controller already decided to play).
func _spawn_voice(event, track, mode: String, pos: Vector3, cfg: Dictionary, release_ms: float, emitter, seamless: bool, skip_play_chance: bool):
	var level: int = event.current_level
	var is_shared: bool = (track.level_behavior == "always_play" or track.level_behavior == "level_conditional")
	if not is_shared and track.level_samples.get(level, track.level_samples.get(0, {})).is_empty():
		return null
	if not skip_play_chance and not track.roll_play_chance(level):
		return null

	var pick: Dictionary = track.get_sfx_stream_and_clip(level, true)
	if pick.is_empty():
		return null
	var stream: AudioStream = pick["stream"]
	if stream == null:
		return null
	var clip = pick["clip"]   # PFARegionClip | null

	# A one_shot clip never loops, even if the event/seamless flag asked for it (JS parity).
	var clip_one_shot: bool = clip != null and clip.is_one_shot()
	var do_seamless: bool = seamless and not clip_one_shot

	# Gain: track.volume × clip.volume × volume-rand, folded with event × group × master.
	# Godot's node attenuation_model layers distance ON TOP of this base volume_db.
	var clip_vol: float = clip.volume if clip != null else 1.0
	var vol_rand: float = track.sfx_volume_rand_linear()
	# Intensity / velocity (carried in cfg by _trigger_oneshot/_trigger_on_emitter) folds
	# its gain over the base amp + its pitch offset into the pitch scale. {} ⇒ neutral.
	var iv: Dictionary = cfg.get("_intensity", {})
	var base_amp: float = track.volume * clip_vol * vol_rand * float(iv.get("gain_mult", 1.0))
	var base_db: float = event.combined_sfx_db(base_amp)

	var pitch: float = maxf(0.01, track.compute_sfx_pitch_scale(float(iv.get("pitch_st", 0.0))))
	var delay_ms: float = track.sfx_delay_ms()

	# Trim window [offset, offset + play_len). play_len 0 ⇒ full remaining after offset.
	var offset: float = clip.source_offset if clip != null else 0.0
	var has_window: bool = clip != null and clip.source_play_length > 0.0
	var play_len: float = clip.source_play_length if has_window else maxf(0.0, stream.get_length() - offset)
	var fade_in: float = clip.fade_in if clip != null else 0.0
	var fade_out: float = clip.fade_out if clip != null else 0.0

	# Seamless loop needs a per-voice stream copy so toggling `loop` doesn't mutate the shared
	# resource other one-shot voices reuse. The exporter bakes the trim into the asset, so a
	# whole-file loop IS the trim loop (Ogg/MP3 can't loop a sub-region — Godot docs).
	var play_stream: AudioStream = stream
	if do_seamless:
		play_stream = stream.duplicate()
		_set_stream_loop(play_stream, true, offset)

	# Create + configure the positional player.
	var player
	if mode == "3D":
		player = AudioStreamPlayer3D.new()
		player.bus = event._voice_bus
		player.stream = play_stream
		add_child(player)
		_configure_3d(player, cfg)
	else:
		player = AudioStreamPlayer2D.new()
		player.bus = event._voice_bus
		player.stream = play_stream
		add_child(player)
		_configure_2d(player, cfg)
	player.pitch_scale = pitch
	_set_voice_position(player, mode, pos)

	# Per-voice state for the smart re-loop + release fade. `event` + `pre_amp`
	# let refresh_event_voices re-bake the level on LIVE mixer moves; `pre_amp` is
	# also the gain half of the audibility score (voice stealing), shaded by `att`
	# (+ `spatial_mode`) at steal time. `spawn_us` is the age tie-break.
	player.set_meta("base_db", base_db)
	player.set_meta("event", event)
	player.set_meta("pre_amp", base_amp)
	player.set_meta("play_len", play_len)
	player.set_meta("release_ms", release_ms)
	player.set_meta("stopped", false)
	player.set_meta("spatial_mode", mode)
	player.set_meta("att", {"model": str(cfg.get("model", "inverse")),
		"min_distance": float(cfg.get("min_distance", 1.0)),
		"max_distance": float(cfg.get("max_distance", 50.0)),
		"rolloff": float(cfg.get("rolloff", 1.0))})
	player.set_meta("spawn_us", Time.get_ticks_usec())
	# The emitter this voice follows (none for a fixed-position trigger): _free_voice
	# takes the voice out of emitter._players again, so a long-lived emitter lists
	# what still plays instead of every handle it ever spawned (the list is what
	# every position update walks and what destroy() releases).
	if emitter != null:
		player.set_meta("emitter", emitter)
	# Register in the EVENT's unified voice pool (flat + spatial share one cap — JS
	# parity with event._activeVoices). _free_voice unregisters; a mid-release voice
	# is filtered out by its `stopped` meta.
	event._register_spatial_voice(player, self)

	# A windowed one-shot is freed by its stop timer ALONE (the finished handler below skips
	# it). Otherwise a natural stream-end frees the player first, and the stop timer's captured
	# `player` reference is then a freed instance → "lambda capture was freed" error each time
	# a trimmed spatial one-shot ends (surfaced by 2D footstep and breath one-shots).
	# Both lifecycle timers are Timer CHILDREN of the player (not tree-scoped
	# SceneTreeTimers): a child dies WITH the player, so an early free (emitter.destroy /
	# stop_all_voices / release mid-delay or mid-window) can never leave an orphan timeout
	# holding a freed `player` capture. Bonus: child timers pause in sync with the audio.
	var windowed_stop: bool = has_window and play_len > 0.0
	var start_cb := func() -> void:
		if not is_instance_valid(player):
			return
		player.play(offset)
		# The fades ride the wall clock the voice plays on: pitch stretches the
		# window (play_len / pitch is when the trim-stop fires below) and the
		# authored fades stretch with it — Studio's preview fades the clip and then
		# resamples it, so a 100 ms fade-out on a voice pitched an octave up lasts
		# 50 ms and still ends where the window ends. On the unscaled timeline a
		# voice pitched up ended before its fade-out began and a voice pitched
		# down went silent with half its sound still to play.
		var wall_len: float = play_len / pitch
		if do_seamless:
			_apply_fade(player, base_db, wall_len, fade_in / pitch, 0.0, true)   # no fade-out on a loop
		else:
			_apply_fade(player, base_db, wall_len, fade_in / pitch, fade_out / pitch, false)
			# One-shot: stop after the trim window (pitch stretches wall-clock).
			if windowed_stop:
				var stop_t := Timer.new()
				stop_t.one_shot = true
				stop_t.wait_time = play_len / pitch
				player.add_child(stop_t)
				stop_t.timeout.connect(func() -> void:
					if is_instance_valid(player) and not bool(player.get_meta("stopped", false)):
						player.stop()
						_free_voice(player)
				, CONNECT_ONE_SHOT)
				stop_t.start()

	if delay_ms > 0.0:
		var delay_t := Timer.new()
		delay_t.one_shot = true
		delay_t.wait_time = delay_ms / 1000.0
		player.add_child(delay_t)
		delay_t.timeout.connect(start_cb, CONNECT_ONE_SHOT)
		delay_t.start()
	else:
		start_cb.call()

	# Auto-free a finished one-shot (seamless loops + smart cycles are freed on stop/destroy).
	# A WINDOWED one-shot is freed by its stop timer instead — freeing here too would race that
	# timer to a freed `player` instance (the lambda-capture-freed error above).
	player.finished.connect(func() -> void:
		if not do_seamless and not windowed_stop:
			_free_voice(player)
	)

	_voices.append(player)
	return player


# ══════════════════════════════════════════════════════════════════════
# ── Smart loop (re-trigger each cycle: switch variation + per-cycle chance) ─
# ══════════════════════════════════════════════════════════════════════

## Start a persistent smart-loop controller for one track. Each cycle rolls play_chance
## (pass ⇒ spawn the next, switched variation + crossfade in; fail ⇒ a SILENT slot). The
## FIRST cycle always plays. On an emitter, the controller follows the emitter + is killed by
## destroy(); without one it runs at a fixed `pos`. JS: _startSmartLoop / _scheduleSmartReloop.
func _start_smart_loop(event, track, mode: String, pos: Vector3, cfg: Dictionary, release_ms: float, emitter) -> Dictionary:
	# `event` lets stop_event_voices() kill just THIS event's controllers (PFA.stop parity).
	var ctrl := {"stopped": false, "active": null, "last_len": 1.0, "first": true, "pos": pos, "event": event}
	_smart_ctrls.append(ctrl)
	if emitter != null:
		emitter._smart_loops.append(ctrl)
	_smart_tick(ctrl, event, track, mode, cfg, release_ms, emitter)
	return ctrl


func _smart_tick(ctrl: Dictionary, event, track, mode: String, cfg: Dictionary, release_ms: float, emitter) -> void:
	# A dead controller unregisters itself on its final wake-up (SceneTreeTimers
	# can't be aborted). The validity guard is the load_pack/free class: a tick
	# must never touch an event the reload already freed — same contract as the
	# int-capture guards on PFAEvent's own timers.
	if ctrl.get("stopped", false) or (emitter != null and emitter._destroyed) \
			or not is_instance_valid(event):
		_smart_ctrls.erase(ctrl)
		return
	var level: int = event.current_level
	var play: bool = ctrl.get("first", true) or track.roll_play_chance(level)
	ctrl["first"] = false
	if play:
		var at: Vector3 = emitter._pos if emitter != null else ctrl.get("pos", Vector3.ZERO)
		var next = _spawn_voice(event, track, mode, at, cfg, release_ms, emitter, false, true)
		if next != null:
			if emitter != null:
				emitter._players.append(next)
			ctrl["last_len"] = maxf(0.05, float(next.get_meta("play_len", 1.0)) / maxf(0.01, next.pitch_scale))
			# Crossfade the new voice in; release the previous over the same seam.
			var nb: float = float(next.get_meta("base_db", 0.0))
			_set_voice_db(next, _SILENCE_DB)
			var tw: Tween = next.create_tween()
			tw.tween_method(func(db: float) -> void: _set_voice_db(next, db),
				_SILENCE_DB, nb, _SMART_CROSS)
			var prev = ctrl.get("active", null)
			if prev != null and is_instance_valid(prev) and prev.playing:
				_release_voice(prev, _SMART_CROSS * 1000.0)
			ctrl["active"] = next
	else:
		ctrl["active"] = null   # silent slot — the prior one-shot voice finishes out naturally
	# Re-arm the next slot (one clip length of the last PLAYED clip sets the rhythm).
	if not ctrl.get("stopped", false) and (emitter == null or not emitter._destroyed):
		var period: float = maxf(0.05, float(ctrl.get("last_len", 1.0)) - _SMART_CROSS)
		var t := get_tree().create_timer(period)
		# One-shot (see the note in pfa_event.stop_playback): this chain re-arms once
		# per clip length, so a connection that outlives its emit would strand one
		# SceneTreeTimer per tick for as long as the loop plays — the worst instance of
		# the class in the addon.
		t.timeout.connect(_smart_tick.bind(ctrl, event, track, mode, cfg, release_ms, emitter), CONNECT_ONE_SHOT)


# ══════════════════════════════════════════════════════════════════════
# ── Config merge + attenuation mapping (Godot-native) ─────────────────
# ══════════════════════════════════════════════════════════════════════

## merged = _DEFAULTS ← event.spatial (snake_case, only if enabled) ← user_cfg (game override).
## Mirrors JS _mergeSpatialConfig: only present keys override; both layers may be empty.
func _merge_cfg(event_spatial: Dictionary, user_cfg: Dictionary) -> Dictionary:
	var out := _DEFAULTS.duplicate(true)
	if event_spatial != null and not event_spatial.is_empty() and bool(event_spatial.get("enabled", false)):
		_overlay_cfg(out, event_spatial)
		# Per-platform: this IS the Godot engine, so a "godot" override sub-dict
		# (authored on the editor's Godot tab — Godot's native models, no rolloff
		# exponent / HRTF) wins over the flat (web) keys. Old configs lack it and
		# just use the flat keys above.
		var g = event_spatial.get("godot")
		if g is Dictionary:
			_overlay_cfg(out, g)
	if user_cfg != null and not user_cfg.is_empty():
		_overlay_cfg(out, user_cfg)
	return out


func _overlay_cfg(out: Dictionary, layer: Dictionary) -> void:
	for k in _CFG_KEYS:
		if layer.has(k):
			out[k] = layer[k]


## Model name → Godot 3D attenuation model. The editor's GODOT platform authors Godot's NATIVE
## model names (inverse / inverse_square / logarithmic / disabled). Web-vocabulary names (old configs
## with only the flat keys) are accepted too: exponential → inverse-square, linear → ATTENUATION_DISABLED
## (no model curve — Godot's built-in `1 - dist/max` factor alone IS a true linear fade; see the
## branch below). (2D uses a single falloff exponent instead.)
func _model_to_3d_attenuation(model: String) -> int:
	match model:
		"inverse_square", "exponential":
			return AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE
		"logarithmic":
			return AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC
		"linear", "disabled":
			# No model curve → only Godot's built-in (1 - dist/max) factor applies =
			# a TRUE LINEAR fade to silence at max_distance (Godot source:
			# multiplier *= max(0, 1 - dist/max_distance)). So "linear" is honest here.
			return AudioStreamPlayer3D.ATTENUATION_DISABLED
		_:  # "inverse" + unknown
			return AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE


func _configure_2d(player: AudioStreamPlayer2D, cfg: Dictionary) -> void:
	# Godot 2D: multiplier = pow(1 - dist_px / max_distance_px, attenuation). max_distance is in
	# PIXELS, so convert the config's audio-unit max_distance via world_scale.
	player.max_distance = maxf(1.0, float(cfg["max_distance"]) * _world_scale)
	player.attenuation = maxf(0.0, float(cfg["rolloff"]))          # rolloff → falloff exponent
	# panning_strength — PARITY with the knob's meaning (mirrors the 3D normalization below):
	# Godot folds strength × project base (audio/general/2d_panning_strength, default 0.5) × a
	# hard 0.5 into the pan shift, whose full travel is ±0.5 — so a raw max_pan=1 capped the
	# shift at ±0.25 (channels never beyond 75/25; FULL pan unreachable from this knob). Divide
	# both bases out so max_pan IS the fraction of full pan: 1 → fully panned from half a
	# screen-width offset (source at the screen edge = hard pan). Reads the base at runtime so
	# any project setting stays honored (self-contained in the addon).
	var base_2d := maxf(0.01, float(ProjectSettings.get_setting("audio/general/2d_panning_strength", 0.5)))
	player.panning_strength = clampf(float(cfg["max_pan"]) / (base_2d * 0.5), 0.0, 100.0)


func _configure_3d(player: AudioStreamPlayer3D, cfg: Dictionary) -> void:
	var model := str(cfg["model"])
	player.attenuation_model = _model_to_3d_attenuation(model)
	# FMOD "min distance" ≈ Godot unit_size (the distance-falloff reference / full-volume scale).
	player.unit_size = maxf(0.001, float(cfg["min_distance"]))
	# max_distance — Godot's NATIVE audible radius: >0 = hard cutoff (silenced past it, also a CPU
	# saver), applied to ALL attenuation models. We honor the authored value directly — it IS the
	# user's radius control ("crank max → hear farther"). We previously zeroed it for inverse/
	# exponential to mimic Web Audio's infinite-tail inverse, but that fought Godot's own model and
	# left the knob inert; Godot is our primary target, so it drives the behaviour and the (more
	# flexible) web engine is the side that reconciles.
	player.max_distance = maxf(0.0, float(cfg["max_distance"]))
	# panning_strength — PARITY: Godot MULTIPLIES this by the project base audio/general/3d_panning_strength
	# (default 0.5, "tuned for headphones"); effective 1.0 = full L/R separation (mute the opposite channel
	# at hard left/right) = the MAX. The web's 3D PannerNode does FULL panning and ignores max_pan, so
	# feeding max_pan=1 straight in gave effective 0.5 = only HALF the web's spread. Divide the base out so
	# effective panning == max_pan: max_pan=1 → effective 1.0 (Godot's max, matching the web). Reads the base
	# at runtime so it's correct for any project setting (self-contained in the addon).
	var base_3d := maxf(0.01, float(ProjectSettings.get_setting("audio/general/3d_panning_strength", 0.5)))
	player.panning_strength = clampf(float(cfg["max_pan"]) / base_3d, 0.0, 100.0)
	# Doppler — opt-in (shared flat `spatial.doppler`, > 0 = on). Godot's doppler is
	# NATIVE + physical (no strength knob — the editor amount fine-tunes WEB only):
	# IDLE step derives velocity from per-frame global_position changes = exactly our
	# set_position_* emitter pattern; the LISTENER side is tracked too since 4.5
	# (AudioListener3D velocity fix, godotengine PR #108051 — we run 4.6.2).
	player.doppler_tracking = (
		AudioStreamPlayer3D.DOPPLER_TRACKING_IDLE_STEP if float(cfg.get("doppler", 0.0)) > 0.0
		else AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	)
	# Distance LPF — Godot's NATIVE attenuation filter (a highshelf at cutoff_hz
	# whose gain deepens toward attenuation_filter_db as the distance multiplier
	# falls: db = (1 - min(1, mult)) * filter_db — Godot source _update_panning).
	# Godot has ALWAYS run this (node defaults 5000 Hz / -24 dB); the SHARED flat
	# lpf_* keys just forward authored values, and the WEB engine now mirrors the
	# same semantics per voice (closes the heard platform difference). Disabled ⇒
	# filter_db = 0 (mathematically a no-op) + cutoff parked above hearing.
	if bool(cfg.get("lpf_enabled", true)) and float(cfg.get("lpf_db", -24.0)) < 0.0:
		player.attenuation_filter_cutoff_hz = clampf(float(cfg.get("lpf_cutoff_hz", 5000.0)), 1.0, 20500.0)
		player.attenuation_filter_db = float(cfg.get("lpf_db", -24.0))
	else:
		player.attenuation_filter_cutoff_hz = 20500.0
		player.attenuation_filter_db = 0.0
	# NOTE: Godot has no binaural HRTF; panning_model (equalpower/HRTF) is informational only. Also a
	# 3D point source localizes best as MONO — the engine derives L/R from position; a stereo source
	# carries its own L/R that fights positional panning (and hits Godot's weaker stereo-pan path).
	# Author/export spatial events as mono for crisp localization (true on web too).


func _set_voice_position(player, mode: String, pos: Vector3) -> void:
	if not is_instance_valid(player):
		return
	if mode == "3D":
		player.global_position = pos / _world_scale     # game units → audio meters
	else:
		player.global_position = Vector2(pos.x, pos.y)   # pixels


# ══════════════════════════════════════════════════════════════════════
# ── Fades / release / cleanup ─────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## Single write path for a voice's level. 3D also pins max_db to the same value:
## Godot's INVERSE curve keeps GROWING inside unit_size (= min_distance) — e.g.
## min_distance 5 heard from 0.5 m = +20 dB OVER the authored level, capped only
## by max_db, which we never set → the node default (+3 dB ABSOLUTE) was the only
## ceiling. Web/industry semantics hold a PLATEAU at the authored volume inside
## min_distance instead (the JS engine clamps distance at minDistance; FMOD same).
## max_db == volume_db turns Godot's cap into exactly that plateau:
## total = min(volume_db + att, max_db) = volume_db + min(att, 0) — distance can
## only ever REDUCE a voice. Every volume_db write (spawn, clip fade, live
## re-bake, release ramp, smart seam) must go through here so the pair never
## splits. (2D needs none of this: pow(1 − d/max, exp) ≤ 1 by construction.)
func _set_voice_db(player, db: float) -> void:
	if not is_instance_valid(player):
		return
	player.volume_db = db
	if player is AudioStreamPlayer3D:
		player.max_db = db


## One-shot clip fade envelope on volume_db (dB-space ramp — Godot-idiomatic). fade_out is
## suppressed for a seamless loop (it would mute the loop after the first pass). JS analog:
## _applySfxFadeEnvelope. No fades ⇒ steady base_db.
func _apply_fade(player, base_db: float, play_len: float, fade_in: float, fade_out: float, seamless: bool) -> void:
	if fade_in <= 0.0 and (fade_out <= 0.0 or seamless):
		_set_voice_db(player, base_db)
		return
	# Clamp both fades to fit the window (preserve ratio). JS parity.
	if play_len > 0.0 and fade_in + fade_out > play_len:
		var sc: float = play_len / (fade_in + fade_out)
		fade_in *= sc
		fade_out *= sc
	# STANDARD = LINEAR AMPLITUDE (not a volume_db ramp). The JS clip fade (_applySfxFadeEnvelope)
	# and the non-spatial _apply_sfx_fade_to_player both ramp amplitude linearly (0↔steady); a
	# volume_db ramp from −80 dB is back-loaded (long quiet tail) → diverges from the web. Crossfades
	# (smart-loop seam, level crossfades) use equal-power separately; a single clip fade is linear-amp
	# per the web reference + FMOD ("linear = solid basic fade"). Mirrors _apply_sfx_fade_to_player.
	var steady_amp: float = db_to_linear(base_db)
	var setter := func(amp: float) -> void:
		_set_voice_db(player, linear_to_db(amp) if amp > 0.0001 else _SILENCE_DB)
	var tw: Tween = player.create_tween()
	var cursor: float = 0.0
	if fade_in > 0.0:
		_set_voice_db(player, _SILENCE_DB)
		tw.tween_method(setter, 0.0, steady_amp, fade_in)
		cursor = fade_in
	else:
		_set_voice_db(player, base_db)
	if fade_out > 0.0 and not seamless:
		var hold: float = maxf(0.0, play_len - fade_out - cursor)
		if hold > 0.0:
			tw.tween_interval(hold)
		tw.tween_method(setter, steady_amp, 0.0, fade_out)


## Stop a voice, fading volume_db → silence first. fade_ms < 0 ⇒ the voice's event
## release_fade (set at spawn); every stop is floored to _STOP_FLOOR_SEC — 0 means "as fast
## as click-free allows", not a hard cut (JS PFASpatialVoice.stop() parity). The player is
## kept alive through the ramp, then stopped + freed. Re-entry guarded via the "stopped"
## meta (a 2nd release mid-ramp would stack a competing volume_db tween).
func _release_voice(player, fade_ms: float) -> void:
	if not is_instance_valid(player):
		return
	if bool(player.get_meta("stopped", false)):
		return                          # already releasing — keep the first ramp
	player.set_meta("stopped", true)   # cancels a pending smart re-loop / one-shot stop timer
	var ms: float = fade_ms
	if ms < 0.0:
		ms = float(player.get_meta("release_ms", 0.0))
	ms = maxf(ms, _STOP_FLOOR_SEC * 1000.0)
	var tw: Tween = player.create_tween()
	tw.tween_method(func(db: float) -> void: _set_voice_db(player, db),
		player.volume_db, _SILENCE_DB, ms / 1000.0)
	tw.finished.connect(func() -> void:
		if is_instance_valid(player):
			player.stop()
		_free_voice(player)
	)


func _free_voice(player) -> void:
	_voices.erase(player)
	if is_instance_valid(player):
		var ev = player.get_meta("event", null)
		if ev != null and is_instance_valid(ev):
			ev._unregister_spatial_voice(player)
		# A plain trigger_spatial() one-shot carries no emitter, and get_meta with a
		# null default logs a Godot error for a missing key — ask has_meta first.
		var em = player.get_meta("emitter") if player.has_meta("emitter") else null
		if em != null and is_instance_valid(em):
			em._players.erase(player)
		player.queue_free()


func _forget_emitter(emitter: PFASpatialEmitter) -> void:
	_emitters.erase(emitter)


## Re-bake the volume of an event's PLAYING voices from its CURRENT event/group/
## master/duck state — the live-mixer path (editor volume drag, mute/solo via
## duck). JS needs none of this: its voices route through event._eventGain. A
## short tween avoids clicks; voices mid-release (stopped) keep their ramp.
func refresh_event_voices(event, fade_sec: float = 0.05) -> void:
	for p in _voices:
		if not is_instance_valid(p) or p.get_meta("stopped", false):
			continue
		if p.get_meta("event", null) != event:
			continue
		var nb: float = event.combined_sfx_db(float(p.get_meta("pre_amp", 1.0)))
		p.set_meta("base_db", nb)
		if p.has_meta("vol_tw"):
			var old = p.get_meta("vol_tw")
			if old != null and is_instance_valid(old):
				old.kill()
		var tw: Tween = p.create_tween()
		tw.tween_method(func(db: float) -> void: _set_voice_db(p, db),
			p.volume_db, nb, maxf(0.01, fade_sec))
		p.set_meta("vol_tw", tw)


## Stop every active voice + smart-loop controller but KEEP the emitters — they
## belong to game objects, which hold the references and re-trigger later.
## JS PFA.stopAll parity (smart controllers must die here or their timers
## resurrect the OLD pack across a Live Connect reload — the JS zombie bug).
func stop_all_voices(fade_ms: float = 0.0) -> void:
	# The registry reaches EVERY controller — the emitter lists below only hold
	# the emitter-owned subset (an emitter-less trigger_spatial chain lives in the
	# registry alone).
	for ctrl in _smart_ctrls:
		ctrl["stopped"] = true
	_smart_ctrls.clear()
	for e in _emitters:
		e._smart_loops.clear()
		e._players.clear()
	for p in _voices.duplicate():
		_release_voice(p, fade_ms)


## Stop the active voices + smart-loop controllers of ONE event (the PFA.stop(name) path
## for a spatial SFX). Emitters survive — they belong to game objects. Outcome parity with
## the web engine, which silences these voices through event._eventGain on stop(); Godot
## voices are standalone nodes, so each gets its own release ramp, and the event's smart
## controllers must stop too — a live controller would re-spawn an AUDIBLE voice next
## cycle (in JS a re-spawn enters the silenced event gain instead).
func stop_event_voices(event, fade_ms: float = 0.0) -> void:
	var keep_ctrls: Array = []
	for ctrl in _smart_ctrls:
		if ctrl.get("event", null) == event:
			ctrl["stopped"] = true
		else:
			keep_ctrls.append(ctrl)
	_smart_ctrls = keep_ctrls
	for e in _emitters:
		var keep: Array = []
		for ctrl in e._smart_loops:
			if not ctrl.get("stopped", false):
				keep.append(ctrl)
		e._smart_loops = keep
	for p in _voices.duplicate():
		if is_instance_valid(p) and p.get_meta("event", null) == event:
			_release_voice(p, fade_ms)


## Stop + free every active spatial voice and emitter (e.g. scene change). This is the ONE
## deliberately HARD teardown: the _free_voice sweep below kills any release ramp the
## destroy(0.0) pass just started (tween dies with its player). Click-safety on a scene
## swap is the game's job — fade to black / let stops finish BEFORE change_scene.
func clear_all() -> void:
	for ctrl in _smart_ctrls:
		ctrl["stopped"] = true
	_smart_ctrls.clear()
	for e in _emitters.duplicate():
		e.destroy(0.0)
	for p in _voices.duplicate():
		_free_voice(p)
	_voices.clear()


# ══════════════════════════════════════════════════════════════════════
# ── Helpers ───────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

func _event_spatial(event) -> Dictionary:
	return event.spatial if event.spatial != null else {}


func _release_ms_for(event) -> float:
	var rf: Dictionary = event.release_fade if event.release_fade != null else {}
	var d: float = float(rf.get("duration", 0.0))
	return d * 1000.0 if d > 0.0 else 0.0


func _get_event(event_name: String):
	if _pfa == null:
		return null
	return _pfa._get_event(event_name)


## Set per-format loop flags. Ogg/MP3 loop loop_offset→end (sub-region not supported — the
## exporter bakes the trim into the asset). WAV supports a true forward loop.
func _set_stream_loop(stream, enabled: bool, loop_offset: float = 0.0) -> void:
	if stream is AudioStreamOggVorbis:
		stream.loop = enabled
		stream.loop_offset = loop_offset
	elif stream is AudioStreamMP3:
		stream.loop = enabled
		stream.loop_offset = loop_offset
	elif stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD if enabled else AudioStreamWAV.LOOP_DISABLED
		if enabled:
			# Same degenerate-loop trap as PFAEvent._setup_loop: a fresh WAV
			# carries loop_end = 0 → loop region [0,0] → voice stuck at pos 0.
			stream.loop_begin = 0
			stream.loop_end = PFAEvent._wav_frames(stream)
