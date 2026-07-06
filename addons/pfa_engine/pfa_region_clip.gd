class_name PFARegionClip
extends RefCounted

## Non-destructive clip data — defines WHAT portion of audio plays and HOW.
## Parsed from config.json "clips" array. Audio windowing is NOT applied in Godot
## (Godot's AudioStreamPlayer handles loop natively) — this stores metadata
## for the engine to set loopStart/loopEnd and volume correctly.

## Where in the audio playback begins (seconds)
var source_offset: float = 0.0

## How much audio to play (seconds, 0 = full remaining after offset)
var source_play_length: float = 0.0

## "one_shot" | "loop_source" | "loop_region"
var loop_mode: String = "loop_source"

## Fade in/out length (seconds)
var fade_in: float = 0.0
var fade_out: float = 0.0

## Clip volume multiplier (0.0 - 2.0)
var volume: float = 1.0

## Randomization weight
var weight: float = 1.0

## Parse from config.json clip dict (times already in seconds from exporter)
static func from_dict(data: Dictionary) -> PFARegionClip:
	var clip = PFARegionClip.new()
	clip.source_offset = data.get("source_offset", 0.0)
	clip.source_play_length = data.get("source_play_length", 0.0)
	clip.loop_mode = data.get("loop_mode", "loop_source")
	clip.fade_in = data.get("fade_in", 0.0)
	clip.fade_out = data.get("fade_out", 0.0)
	clip.volume = data.get("volume", 1.0)
	clip.weight = data.get("weight", 1.0)
	return clip

## Check if this clip is a one-shot (no loop)
func is_one_shot() -> bool:
	return loop_mode == "one_shot"

## Check if clip has any trim/fade applied
func has_windowing() -> bool:
	return source_offset > 0.0 or source_play_length > 0.0 or fade_in > 0.0 or fade_out > 0.0
