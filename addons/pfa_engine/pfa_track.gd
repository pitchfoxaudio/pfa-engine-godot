class_name PFATrack
extends RefCounted

## A track within an event. Faithful port of the JS engine's PFATrack.
##
## Data-only class in Godot — AudioStreamPlayer management lives in PFAEvent (because
## AudioStreamPlayer must be a Node, and PFATrack extends RefCounted for config-load simplicity).

# --- Config ---

var name: String = ""
var volume: float = 1.0
var level_behavior: String = "level_specific"          # "level_specific" | "always_play" | "level_conditional"
var randomization: Dictionary = {}                      # SFX randomization: { pitch, volume, delay, rate } consumed; a config's `pan` block is carried but not applied (no per-voice pan on a flat AudioStreamPlayer)
var repeat_count: int = 1                               # repeats of loop_bars before variation check
var chance_reroll_bars: int = 1                         # play_chance reroll interval multiplier
var randomization_algo: String = "random"               # "random" | "weighted" | "no_repeat"
var chance_fade_mode: String = "instant"                # "instant" | "fade"
var chance_fade_duration: float = 0.5                   # seconds (when chance_fade_mode == "fade")
var play_chance_mode: String = "true_random"            # "true_random" | "weighted_history" | "shuffle_bag"

# Per-level sample metadata (keyed by level_idx).
# { level_idx: { files, clips, loop_bars, switch_chance, play_chance, repeat_count,
#               randomization_algo, play_chance_mode, chance_reroll_bars } }
var level_samples: Dictionary = {}

# Shared (always_play / level_conditional) samples — JS: sharedSampleFiles + sharedClips.
var _shared_sample_files: Array = []                    # raw file paths from config
var _shared_clips_config: Array = []                    # [PFARegionClip] from config

# --- Runtime (set after load_streams) ---

var _streams: Dictionary = {}                           # level_idx -> Array[AudioStream]
var _clips: Dictionary = {}                             # level_idx -> Array[PFARegionClip]
var _shared_streams: Array = []                         # Array[AudioStream] for always_play
var _shared_clips: Array = []                           # Array[PFARegionClip] — alias to _shared_clips_config
var _samples_loaded: bool = false
var _bank_loader: PFABankLoader = null

# Per-pool variation rotation state, keyed "shared" or str(level) — editor parity:
# LevelState.current_variation_index + _variation_shuffle_bag in the editor,
# each level rotates its own variations independently. Pools of different sizes must
# never share one index/bag: a no_repeat bag minted on a 5-variation level pops
# out-of-range indices on a 2-variation level → the swap bails → variation sticks
# for a full extra loop per stale entry (observed on first entry to a level).
var _variation_state: Dictionary = {}                   # level_key -> {"current": int, "bag": Array}

# play_chance_mode state (JS: _chanceConsecutivePlays/_chanceConsecutiveSilences/_chanceShuffleBags).
var _chance_consecutive_plays: Dictionary = {}          # level -> int
var _chance_consecutive_silences: Dictionary = {}       # level -> int
var _chance_shuffle_bags: Dictionary = {}               # level -> Array[bool]
var _chance_shuffle_bag_size: int = 10


# ══════════════════════════════════════════════════════════════════════
# ── Sample Loading ────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## Load all audio streams (shared + per-level).
func load_streams(base_path: String) -> void:
	if _samples_loaded:
		return

	# Shared streams
	_shared_streams = []
	for file_path in _shared_sample_files:
		var s: AudioStream = _resolve_stream(base_path, file_path)
		if s:
			_shared_streams.append(s)
	_shared_clips = _shared_clips_config.duplicate()

	# Per-level streams
	for level_idx in level_samples:
		var level_data: Dictionary = level_samples[level_idx]
		var streams: Array = []
		var clips: Array = []
		# Clips
		for clip_data in level_data.get("clips", []):
			clips.append(PFARegionClip.from_dict(clip_data))
		# Files
		for file_path in level_data.get("files", []):
			var s2: AudioStream = _resolve_stream(base_path, file_path)
			if s2:
				streams.append(s2)
		_streams[level_idx] = streams
		_clips[level_idx] = clips

	_samples_loaded = true

## Unload all audio streams (free memory).
func unload_streams() -> void:
	_streams.clear()
	_clips.clear()
	_shared_streams.clear()
	_shared_clips.clear()
	_samples_loaded = false

## Variation-pool key for a level: shared behaviors rotate ONE pool, level_specific
## rotates one pool PER level (editor: Multisample._get_level_state()).
func variation_key(level: int) -> String:
	if level_behavior == "always_play" or level_behavior == "level_conditional":
		return "shared"
	return str(level)

## Per-pool rotation state accessor — auto-creates (editor: _get_level_state()).
func _var_state(level_key: String) -> Dictionary:
	if not _variation_state.has(level_key):
		_variation_state[level_key] = {"current": 0, "bag": []}
	return _variation_state[level_key]

## Current variation index of a pool (editor: LevelState.current_variation_index).
func current_variation(level_key: String) -> int:
	return int(_var_state(level_key)["current"])

## Set a pool's current variation (restart paths + tests).
func set_current_variation(level_key: String, idx: int) -> void:
	_var_state(level_key)["current"] = idx

## Get a single stream for the given level (current variation). Used by spatial audio path.
## Returns shared stream for always_play/level_conditional, level-specific otherwise.
func get_stream(level: int) -> AudioStream:
	var streams: Array
	if level_behavior == "always_play" or level_behavior == "level_conditional":
		streams = _shared_streams
	else:
		streams = _streams.get(level, _streams.get(0, []))
	if streams.is_empty():
		return null
	var idx: int = clampi(current_variation(variation_key(level)), 0, streams.size() - 1)
	return streams[idx]

## SFX stream + clip + variation report for one trigger. JS: _getBufferAndClip(level, true).
##
## Selects the shared pool for always_play / level_conditional, else the per-level pool.
## When `pick_variation` is true and there is more than one variation, rolls switch_chance
## (editor parity: its trigger() rolls switch_chance, then picks a variation;
## always_play has no level data → switch_chance defaults to 100 → re-pick every trigger).
## Music leaves _current_variation to the Conductor — it passes pick_variation = false.
## Returns {} when no stream is available, else
## { stream, clip, variation, variation_count, sample }.
func get_sfx_stream_and_clip(level: int, pick_variation: bool = false) -> Dictionary:
	var streams: Array
	var clips: Array
	var files: Array
	if level_behavior == "always_play" or level_behavior == "level_conditional":
		streams = _shared_streams
		clips = _shared_clips
		files = _shared_sample_files
	else:
		streams = _streams.get(level, _streams.get(0, []))
		clips = _clips.get(level, _clips.get(0, []))
		var ld_files: Dictionary = level_samples.get(level, level_samples.get(0, {}))
		files = ld_files.get("files", [])

	if streams.is_empty():
		return {}

	var pool_key: String = variation_key(level)
	if pick_variation and streams.size() > 1:
		# always_play has no level data → {}.get("switch_chance", 100) = 100 → re-pick.
		var ld: Dictionary = level_samples.get(level, level_samples.get(0, {}))
		var switch_chance: float = float(ld.get("switch_chance", 100))
		if switch_chance > 0.0 and randf() * 100.0 <= switch_chance:
			pick_next_variation_idx(streams, clips, pool_key)

	var idx: int = clampi(current_variation(pool_key), 0, streams.size() - 1)
	var stream: AudioStream = streams[idx]
	var clip: PFARegionClip = clips[idx] if idx < clips.size() else null
	var sample_name: String = String(files[idx]).get_file() if idx < files.size() else ""

	return {
		"stream": stream,
		"clip": clip,
		"variation": idx,
		"variation_count": streams.size(),
		"sample": sample_name,
	}


# ══════════════════════════════════════════════════════════════════════
# ── Variation Picking (JS _pickVariation) ─────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## Pick next variation index based on randomization_algo. Mirrors JS _pickVariation exactly.
## Rotation state (current index + no_repeat bag) lives per pool — `level_key` from
## variation_key(level) — and the pick COMMITS into that pool's "current".
## @param streams   Array of AudioStreams for the pool (level or shared).
## @param clips     Array of PFARegionClip (optional, for weighted mode).
## @param level_key Pool key: "shared" or str(level).
## @return new current index of the pool (0..streams.size-1).
func pick_next_variation_idx(streams: Array, clips: Array, level_key: String) -> int:
	var count: int = streams.size()
	var state: Dictionary = _var_state(level_key)
	if count <= 1:
		state["current"] = 0
		return 0
	var prev: int = int(state["current"])
	var picked: int = prev

	match randomization_algo:
		"weighted":
			picked = count - 1
			var weights: Array = []
			for i in range(count):
				var w: float = 1.0
				if i < clips.size() and clips[i] is PFARegionClip:
					w = clips[i].weight
				weights.append(w)
			var total: float = 0.0
			for w in weights:
				total += w
			if total <= 0.0:
				picked = randi() % count
			else:
				var rand_v: float = randf() * total
				for i in range(count):
					rand_v -= weights[i]
					if rand_v <= 0.0:
						picked = i
						break

		"no_repeat":
			var bag: Array = state["bag"]
			if bag.is_empty():
				bag = range(count)
				# Fisher-Yates
				for i in range(bag.size() - 1, 0, -1):
					var j := randi() % (i + 1)
					var tmp = bag[i]
					bag[i] = bag[j]
					bag[j] = tmp
				# Prevent repeat at bag boundary
				if bag[0] == prev and count > 1:
					bag.append(bag.pop_front())
				state["bag"] = bag
			picked = bag.pop_front()

		_:  # "random" or any unknown
			picked = randi() % count

	state["current"] = picked
	return picked


# ══════════════════════════════════════════════════════════════════════
# ── Play Chance (JS _rollPlayChance) ──────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## Decide play or silence based on play_chance_mode. Mirrors JS _rollPlayChance.
func roll_play_chance(level: int) -> bool:
	var level_data: Dictionary = level_samples.get(level, level_samples.get(0, {}))
	var play_chance: float = float(level_data.get("play_chance", 100))
	if play_chance >= 100.0:
		return true
	if play_chance <= 0.0:
		return false

	match play_chance_mode:
		"weighted_history":
			return _roll_weighted_history(level, play_chance)
		"shuffle_bag":
			return _roll_shuffle_bag(level, play_chance)
		_:  # true_random
			return randf() * 100.0 < play_chance

func _roll_weighted_history(level: int, play_chance: float) -> bool:
	var plays: int = _chance_consecutive_plays.get(level, 0)
	var silences: int = _chance_consecutive_silences.get(level, 0)
	var adjusted: float = play_chance

	# Balanced step sizes: p*stepDown == (1-p)*stepUp → E[adjusted] = playChance (no drift).
	var p: float = play_chance / 100.0
	var base_step: float = 5.0
	var max_up: float = 95.0 - play_chance
	var max_down: float = play_chance - 5.0
	var step_down: float
	var step_up: float

	if play_chance >= 50.0:
		step_down = base_step
		step_up = base_step * p / (1.0 - p) if p < 1.0 else base_step
		if step_up > max_up:
			step_up = max_up
			step_down = max_up * (1.0 - p) / p if p > 0.0 else base_step
	else:
		step_up = base_step
		step_down = base_step * (1.0 - p) / p if p > 0.0 else base_step
		if step_down > max_down:
			step_down = max_down
			step_up = max_down * p / (1.0 - p) if p < 1.0 else base_step

	if plays > 0:
		adjusted = play_chance - min(plays, 5) * step_down
	if silences > 0:
		adjusted = play_chance + min(silences, 5) * step_up
	adjusted = clampf(adjusted, 5.0, 95.0)

	var passed: bool = randf() * 100.0 < adjusted
	if passed:
		_chance_consecutive_plays[level] = plays + 1
		_chance_consecutive_silences[level] = 0
	else:
		_chance_consecutive_silences[level] = silences + 1
		_chance_consecutive_plays[level] = 0
	return passed

func _roll_shuffle_bag(level: int, play_chance: float) -> bool:
	var bag: Array = _chance_shuffle_bags.get(level, [])
	if bag.is_empty():
		bag = _refill_chance_shuffle_bag(level, play_chance)
	return bag.pop_front()

func _refill_chance_shuffle_bag(level: int, play_chance: float) -> Array:
	var size: int = _chance_shuffle_bag_size
	var num_plays: int = roundi(size * play_chance / 100.0)
	var bag: Array = []
	for i in range(num_plays):
		bag.append(true)
	for i in range(size - num_plays):
		bag.append(false)
	# Fisher-Yates
	for i in range(bag.size() - 1, 0, -1):
		var j := randi() % (i + 1)
		var tmp = bag[i]
		bag[i] = bag[j]
		bag[j] = tmp
	_chance_shuffle_bags[level] = bag
	return bag


# ══════════════════════════════════════════════════════════════════════
# ── SFX Randomization ─────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## Compute the SFX pitch_scale from pitch (semitones) + rate randomization. 1.0 if none.
## Value form shared by the non-spatial player path AND the spatial path (which needs the
## value before a 2D/3D player exists). JS: _applySfxPitchRate.
func compute_sfx_pitch_scale(iv_pitch_st: float = 0.0) -> float:
	var scale: float = 1.0
	if not randomization.is_empty():
		# Pitch (semitones -> playback rate)
		var pitch_data: Dictionary = randomization.get("pitch", {})
		if pitch_data.get("enabled", false):
			var min_st: float = float(pitch_data.get("min", -2.0))
			var max_st: float = float(pitch_data.get("max", 2.0))
			var semitones: float = randf_range(min_st, max_st)
			scale = pow(2.0, semitones / 12.0)
		# Rate (multiplier applied on top of pitch)
		var rate_data: Dictionary = randomization.get("rate", {})
		if rate_data.get("enabled", false):
			var min_r: float = float(rate_data.get("min", 0.9))
			var max_r: float = float(rate_data.get("max", 1.1))
			scale *= randf_range(min_r, max_r)
	# Intensity (velocity) pitch offset — semitones, summed OVER the random pitch
	# (JS _applySfxPitchRate folds iv.pitchSt the same way).
	if iv_pitch_st != 0.0:
		scale *= pow(2.0, iv_pitch_st / 12.0)
	return scale

## Apply pitch + rate randomization (+ optional intensity semitone offset) to an SFX
## player's pitch_scale. JS: _applySfxPitchRate.
func apply_sfx_pitch_rate(player: AudioStreamPlayer, iv_pitch_st: float = 0.0) -> void:
	player.pitch_scale = compute_sfx_pitch_scale(iv_pitch_st)

## Linear gain multiplier from the (dB) volume randomization param. 1.0 if disabled.
## JS: _volumeRandLinear. Returned as a factor (not applied directly) so the caller
## can fold it into the per-voice fade target instead of clobbering volume_db.
func sfx_volume_rand_linear() -> float:
	if randomization.is_empty():
		return 1.0
	var vol_data: Dictionary = randomization.get("volume", {})
	if vol_data.get("enabled", false):
		var min_db: float = float(vol_data.get("min", -3.0))
		var max_db: float = float(vol_data.get("max", 3.0))
		return db_to_linear(randf_range(min_db, max_db))
	return 1.0

## Intensity (velocity) curve shape — IDENTICAL to the JS engine (_intensityShape)
## and the design doc. t in [0,1]; every shape maps 0->0 and 1->1.
static func intensity_shape(curve: String, t: float) -> float:
	match curve:
		"exponential": return t * t                 # slow->fast (perceptual loudness)
		"logarithmic": return t * (2.0 - t)         # = 2t - t^2; fast->slow
		"s_curve":     return t * t * (3.0 - 2.0 * t)  # smoothstep; eased both ends
		_:             return t                     # linear

## Map a normalized intensity (0..1, default 1.0) through an event's authored
## `intensity` config -> { gain_mult, pitch_st }. Disabled / empty ⇒ the neutral
## { 1.0, 0.0 } (zero behaviour change). IDENTICAL math to the JS engine
## (_intensityToGainPitch) — see doc «Intensity (velocity) feature — design + curve
## reference». vol_db / pitch_st are [value at intensity 0, at intensity 1].
static func intensity_gain_pitch(intensity: float, cfg: Dictionary) -> Dictionary:
	if cfg.is_empty() or not bool(cfg.get("enabled", false)):
		return {"gain_mult": 1.0, "pitch_st": 0.0}
	var t: float = clampf(intensity, 0.0, 1.0)
	var vd: Array = cfg.get("vol_db", [0.0, 0.0])
	var ps: Array = cfg.get("pitch_st", [0.0, 0.0])
	var vol_db: float = float(vd[0]) + (float(vd[1]) - float(vd[0])) * intensity_shape(str(cfg.get("vol_curve", "linear")), t)
	var pitch_st: float = float(ps[0]) + (float(ps[1]) - float(ps[0])) * intensity_shape(str(cfg.get("pitch_curve", "linear")), t)
	return {"gain_mult": db_to_linear(vol_db), "pitch_st": pitch_st}

## Random one-shot delay in ms (0 if disabled). JS: _getRandomParam('delay').
func sfx_delay_ms() -> float:
	if randomization.is_empty():
		return 0.0
	var delay_data: Dictionary = randomization.get("delay", {})
	if delay_data.get("enabled", false):
		var min_ms: float = float(delay_data.get("min", 0))
		var max_ms: float = float(delay_data.get("max", 30))
		return randf_range(min_ms, max_ms)
	return 0.0


# ══════════════════════════════════════════════════════════════════════
# ── Audio File Loading (format dispatch) ──────────────────────────────
# ══════════════════════════════════════════════════════════════════════

## Resolve stream from file_path — via bank loader, resource, or raw file.
func _resolve_stream(base_path: String, file_path: String) -> AudioStream:
	if _bank_loader:
		return _bank_loader.get_audio_stream(file_path)
	if base_path.is_empty():
		return _load_audio_file(file_path)
	return _load_audio_file(base_path + "/" + file_path)

## Load AudioStream from absolute path (OGG / WAV / MP3).
func _load_audio_file(path: String) -> AudioStream:
	if ResourceLoader.exists(path):
		return ResourceLoader.load(path)

	if not FileAccess.file_exists(path):
		push_warning("[PFA] Cannot load audio: %s%s" % [
			path, PFAEvent._export_missing_hint(path, ERR_FILE_NOT_FOUND)])
		return null

	if path.ends_with(".ogg"):
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file:
			var data := file.get_buffer(file.get_length())
			file.close()
			return AudioStreamOggVorbis.load_from_buffer(data)
	elif path.ends_with(".wav"):
		return _load_wav(path)
	elif path.ends_with(".mp3"):
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file:
			var data := file.get_buffer(file.get_length())
			file.close()
			var stream := AudioStreamMP3.new()
			stream.data = data
			return stream

	push_warning("[PFA] Unsupported audio format: %s" % path)
	return null

## Parse RIFF WAV into AudioStreamWAV.
func _load_wav(path: String) -> AudioStream:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null

	var stream: AudioStreamWAV = AudioStreamWAV.new()
	var riff: String = file.get_buffer(4).get_string_from_ascii()
	if riff != "RIFF":
		file.close()
		return null
	file.get_32()  # file size
	var wave: String = file.get_buffer(4).get_string_from_ascii()
	if wave != "WAVE":
		file.close()
		return null

	# fmt precedes data; keep audio_format/bps so the data chunk can down-convert
	# 24-bit / 32-bit int / 32-bit float to the 16-bit PCM Godot actually supports.
	var audio_format: int = 1   # 1 = PCM int, 3 = IEEE float
	var bps: int = 16
	while file.get_position() < file.get_length():
		var chunk_id: String = file.get_buffer(4).get_string_from_ascii()
		var chunk_size: int = file.get_32()
		if chunk_id == "fmt ":
			audio_format = file.get_16()
			var channels := file.get_16()
			var sample_rate := file.get_32()
			file.get_32()  # byte rate
			file.get_16()  # block align
			bps = file.get_16()
			stream.mix_rate = sample_rate
			stream.stereo = (channels == 2)
			if chunk_size > 16:
				file.get_buffer(chunk_size - 16)
		elif chunk_id == "data":
			if not PFATrack._apply_wav_pcm(stream, file.get_buffer(chunk_size), audio_format, bps):
				push_error("[PFA] Unsupported WAV format (%d-bit, fmt %d): %s — re-export as 16-bit PCM" % [bps, audio_format, path])
				file.close()
				return null
			break
		else:
			file.get_buffer(chunk_size)

	file.close()
	return stream

## Set AudioStreamWAV.format + data from raw WAV sample bytes. Godot's AudioStreamWAV only
## supports 8/16-bit PCM (plus ADPCM/QOA) — 24-bit, 32-bit int and 32-bit float are read as
## 8-bit garbage (white noise) if handed over raw, so down-convert them to signed 16-bit PCM
## here. audio_format: 1 = PCM int, 3 = IEEE float. Returns false if unrepresentable (caller
## skips the sample rather than playing noise). Shared by pfa_bank_loader._parse_wav.
static func _apply_wav_pcm(stream: AudioStreamWAV, raw: PackedByteArray, audio_format: int, bits: int) -> bool:
	if audio_format == 1 and bits == 16:
		stream.format = AudioStreamWAV.FORMAT_16_BITS
		stream.data = raw
		return true
	if audio_format == 1 and bits == 8:
		stream.format = AudioStreamWAV.FORMAT_8_BITS
		stream.data = raw
		return true
	var out := PackedByteArray()
	if audio_format == 3 and bits == 32:
		# 32-bit float in [-1,1] → signed 16-bit
		var n: int = raw.size() / 4
		out.resize(n * 2)
		for i in n:
			out.encode_s16(i * 2, int(round(clampf(raw.decode_float(i * 4), -1.0, 1.0) * 32767.0)))
	elif audio_format == 1 and bits == 24:
		# 24-bit LE signed → keep the high 16 bits (bytes 1,2 of each 3-byte sample)
		var n: int = raw.size() / 3
		out.resize(n * 2)
		for i in n:
			out[i * 2] = raw[i * 3 + 1]
			out[i * 2 + 1] = raw[i * 3 + 2]
	elif audio_format == 1 and bits == 32:
		# 32-bit int → high 16 bits (bytes 2,3 of each 4-byte sample)
		var n: int = raw.size() / 4
		out.resize(n * 2)
		for i in n:
			out[i * 2] = raw[i * 4 + 2]
			out[i * 2 + 1] = raw[i * 4 + 3]
	else:
		return false
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.data = out
	return true
