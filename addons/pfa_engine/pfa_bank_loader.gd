class_name PFABankLoader
extends RefCounted

## .pfabank binary format parser.
## Format v1.0: Header(64B) + SectionDir(2×32B) + JSON section + DATA section.
## Audio stored as-is (OGG/MP3/WAV) with 16-byte alignment.

const MAGIC = "PFABANK"  # 7-byte prefix; bank format pads to 8 bytes with 0x00
const HEADER_SIZE = 64
const SECTION_ENTRY_SIZE = 32

## Parsed config dictionary (from JSON section)
var config: Dictionary = {}

## Audio entries map: { "path/file.ogg": { "offset": int, "length": int, "codec": int } }
var audio_entries: Dictionary = {}

## Raw bank data (kept in memory for slicing audio on demand)
var _bank_data: PackedByteArray = PackedByteArray()

## Offset of DATA section within bank file
var _data_offset: int = 0


## Load and parse a .pfabank file. Returns true on success.
func load_bank(path: String) -> bool:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[PFA Bank] Cannot open: %s (error: %s)" % [path, FileAccess.get_open_error()])
		return false

	# Read entire file into memory
	_bank_data = file.get_buffer(file.get_length())
	file.close()

	if _bank_data.size() < HEADER_SIZE:
		push_error("[PFA Bank] File too small: %d bytes" % _bank_data.size())
		return false

	# Validate magic bytes
	var magic = _bank_data.slice(0, 8).get_string_from_ascii()
	if magic.substr(0, 7) != "PFABANK":
		push_error("[PFA Bank] Invalid magic: %s" % magic)
		return false

	# Parse header (little-endian)
	var view = StreamPeerBuffer.new()
	view.data_array = _bank_data

	view.seek(8)
	var ver_major = view.get_u16()
	var ver_minor = view.get_u16()
	var header_size = view.get_u32()
	var flags = view.get_u32()
	var bank_uid = view.get_u64()
	var build_uid = view.get_u64()
	var section_dir_off = view.get_u64()
	var section_count = view.get_u32()
	var section_entry_size = view.get_u32()
	var file_size = view.get_u64()

	PFAEvent._dlog("[PFA Bank] v%d.%d, %d sections, %d bytes" % [ver_major, ver_minor, section_count, file_size])

	# Parse section directory
	var json_offset: int = 0
	var json_length: int = 0
	var data_offset: int = 0
	var data_length: int = 0

	view.seek(section_dir_off)
	for i in range(section_count):
		var section_start = view.get_position()
		var section_type = _bank_data.slice(section_start, section_start + 4).get_string_from_ascii()
		view.seek(section_start + 4)
		var sec_flags = view.get_u32()
		var sec_offset = view.get_u64()
		var sec_length = view.get_u64()
		var sec_ver = view.get_u32()
		var sec_reserved = view.get_u32()

		if section_type == "JSON":
			json_offset = sec_offset
			json_length = sec_length
		elif section_type == "DATA":
			data_offset = sec_offset
			data_length = sec_length

		view.seek(section_start + section_entry_size)

	_data_offset = data_offset

	# Parse JSON section
	if json_length == 0:
		push_error("[PFA Bank] No JSON section found")
		return false

	var json_bytes = _bank_data.slice(json_offset, json_offset + json_length)
	var json_string = json_bytes.get_string_from_utf8()

	var json = JSON.new()
	var err = json.parse(json_string)
	if err != OK:
		push_error("[PFA Bank] JSON parse error: %s" % json.get_error_message())
		return false

	config = json.data

	# Extract audio entries map and remove from config
	audio_entries = config.get("_audio_entries", {})
	config.erase("_audio_entries")

	PFAEvent._dlog("[PFA Bank] Loaded: %d events, %d audio entries" % [
		config.get("events", {}).size(), audio_entries.size()])
	return true


## Get audio bytes for a specific file path (slices from bank data).
func get_audio_bytes(rel_path: String) -> PackedByteArray:
	if rel_path not in audio_entries:
		push_warning("[PFA Bank] Audio entry not found: %s" % rel_path)
		return PackedByteArray()

	var entry = audio_entries[rel_path]
	var offset: int = _data_offset + int(entry["offset"])
	var length: int = int(entry["length"])

	if offset + length > _bank_data.size():
		push_error("[PFA Bank] Audio entry out of bounds: %s (offset=%d, length=%d, bank=%d)" % [
			rel_path, offset, length, _bank_data.size()])
		return PackedByteArray()

	return _bank_data.slice(offset, offset + length)


## Create AudioStream from bank entry. Returns null on failure.
func get_audio_stream(rel_path: String) -> AudioStream:
	var data = get_audio_bytes(rel_path)
	if data.is_empty():
		return null

	var codec: int = audio_entries[rel_path].get("codec", 0)

	match codec:
		1:  # OGG
			return AudioStreamOggVorbis.load_from_buffer(data)
		2:  # MP3
			var stream = AudioStreamMP3.new()
			stream.data = data
			return stream
		3:  # WAV
			return _parse_wav(data)
		_:
			# Try by extension
			if rel_path.ends_with(".ogg"):
				return AudioStreamOggVorbis.load_from_buffer(data)
			elif rel_path.ends_with(".mp3"):
				var stream = AudioStreamMP3.new()
				stream.data = data
				return stream
			elif rel_path.ends_with(".wav"):
				return _parse_wav(data)

	push_warning("[PFA Bank] Unknown codec %d for: %s" % [codec, rel_path])
	return null


## Release raw bank data (audio entries already sliced or streamed).
func release_bank_buffer() -> void:
	_bank_data = PackedByteArray()
	PFAEvent._dlog("[PFA Bank] Bank buffer released")


## Get base directory from config (empty for bank mode).
func get_base_path() -> String:
	return ""


## Parse WAV from raw bytes (same logic as pfa_track.gd).
func _parse_wav(data: PackedByteArray) -> AudioStream:
	if data.size() < 44:
		return null

	var view = StreamPeerBuffer.new()
	view.data_array = data

	# RIFF header
	var riff = data.slice(0, 4).get_string_from_ascii()
	if riff != "RIFF":
		return null
	view.seek(8)
	var wave = data.slice(8, 12).get_string_from_ascii()
	if wave != "WAVE":
		return null

	var stream = AudioStreamWAV.new()
	view.seek(12)

	# fmt precedes data; keep audio_format/bits so the data chunk can down-convert
	# 24-bit / 32-bit int / 32-bit float to the 16-bit PCM Godot supports (else white noise).
	var audio_format := 1   # 1 = PCM int, 3 = IEEE float
	var bits_per_sample := 16
	while view.get_position() < data.size() - 8:
		var chunk_pos = view.get_position()
		var chunk_id = data.slice(chunk_pos, chunk_pos + 4).get_string_from_ascii()
		view.seek(chunk_pos + 4)
		var chunk_size = view.get_u32()

		if chunk_id == "fmt ":
			audio_format = view.get_u16()
			var channels = view.get_u16()
			var sample_rate = view.get_u32()
			view.get_u32()  # byte rate
			view.get_u16()  # block align
			bits_per_sample = view.get_u16()

			stream.mix_rate = sample_rate
			stream.stereo = (channels == 2)

			if chunk_size > 16:
				view.seek(view.get_position() + chunk_size - 16)

		elif chunk_id == "data":
			var raw: PackedByteArray = data.slice(view.get_position(), view.get_position() + chunk_size)
			if not PFATrack._apply_wav_pcm(stream, raw, audio_format, bits_per_sample):
				push_warning("[PFA Bank] Unsupported WAV format (%d-bit, fmt %d) — skipped" % [bits_per_sample, audio_format])
				return null
			break
		else:
			view.seek(view.get_position() + chunk_size)

	return stream
