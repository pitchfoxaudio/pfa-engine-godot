class_name PFAReverb
extends Node

## PFA Reverb (Tier-1 room ambience) — Godot side.
##
## Model (parity with the web engine + FMOD/Wwise): reverb is BOTH a per-event SEND and a
## project-level named ZONE character.
##   • PER-EVENT  `reverb.send` (0..1) decides WHETHER an event's voices are wet (its voices
##     route to the global reverb bus instead of "Master"). Stamped onto PFAEvent._voice_bus
##     by the PFA autoload at load time.
##   • PER-ZONE   the reverb CHARACTER (room_size / damping / wet / predelay) is a named preset
##     from the pack's top-level `reverb_zones`. The game selects the active zone at runtime via
##     PFA.set_reverb_zone(name) → this manager reconfigures the bus + ramps `wet` click-free.
##
## Godot is bus-based (one bus per player, no native per-voice dual dry+wet send), so the GLOBAL
## path is whole-mix: an opted-in voice plays on the reverb bus (dry=1 + wet). Per-event `send`
## is therefore COARSE on the global path (participates yes/no) — true per-voice positional wet is
## the OPTIONAL Area3D path (create_zone_area), Godot's free native superpower. 2D never gets
## positional reverb (Area2D has no reverb_bus_amount) — flat global send only, documented.
##
## Engine-owned bus lifecycle: buses are created via AudioServer at load and FREED on every
## reload (free_all) on the same path that frees event nodes — no Live-Connect leak/duplication.

const GLOBAL_BUS := "PFA_Reverb"
const _ZONE_BUS_PREFIX := "PFA_RevZone_"

## Neutral descriptor defaults (platform-neutral acoustic params; mapped onto AudioEffectReverb).
const _REVERB_DEFAULTS := {
	"room_size": 0.7,
	"decay": 1.0,          # informs web IR length; Godot Freeverb has no explicit RT60 (room_size carries size)
	"damping": 0.5,
	"wet": 0.3,
	"dry": 1.0,
	"spread": 1.0,
	"hipass": 0.0,         # high-pass on the wet tail (0..1); Godot-native, thins low rumble
	"predelay_ms": 12.0,        # Web-only TRUE predelay; on Godot predelay is a feedback comb (see _apply_character_to_effect), kept here for schema parity
	"predelay_feedback": 0.0,   # Godot "predelay" is a FEEDBACK comb y[n]=x[n]+g·y[n-D]; g>0 => echo/comb-tone (f0=1/predelay), NOT a real predelay. Default 0 = clean.
}

var _zones: Dictionary = {}                  # zone name -> merged descriptor dict
var _default_zone: String = ""
var _active_zone: String = ""
var _global_effect: AudioEffectReverb = null # the AudioEffectReverb on GLOBAL_BUS
var _wet_tween: Tween = null
var _created_buses: Array = []               # bus names this manager created (for free_all)
var _zone_areas: Array = []                  # Area3D nodes from create_zone_area


## Parse the pack's top-level `reverb_zones` block + build the global reverb bus. Reload-safe:
## frees the prior generation's buses/areas first.
func configure(reverb_zones: Dictionary) -> void:
	free_all()
	var zones = reverb_zones.get("zones", {})
	if zones is Dictionary:
		for zname in zones:
			var z = zones[zname]
			if not (z is Dictionary):
				continue
			var d: Dictionary = _REVERB_DEFAULTS.duplicate()
			for k in d.keys():
				if z.has(k):
					d[k] = z[k]
			# Per-zone Godot override (raw AudioEffectReverb-flavoured) wins for character.
			var g = z.get("godot")
			if g is Dictionary:
				for k in g.keys():
					d[k] = g[k]
			_zones[str(zname)] = d
	var dz = reverb_zones.get("default_zone", null)
	_default_zone = str(dz) if dz != null else ""
	if _zones.is_empty():
		return
	_ensure_global_bus()
	if _default_zone != "" and _zones.has(_default_zone):
		_apply_zone_to_effect(_global_effect, _zones[_default_zone])
		_active_zone = _default_zone
	else:
		if _global_effect != null:
			_global_effect.wet = 0.0
		_active_zone = ""


func has_zones() -> bool:
	return not _zones.is_empty()


func get_active_zone() -> String:
	return _active_zone


func get_global_effect() -> AudioEffectReverb:
	return _global_effect


## Switch the active GLOBAL zone, ramping `wet` click-free over `fade` seconds. `name` null/""
## → dry (wet → 0). Room character (size/damping/predelay) is applied immediately; only wet ramps.
func set_active_zone(name, fade: float = 0.5) -> void:
	if _global_effect == null:
		return
	var target_wet := 0.0
	if name != null and str(name) != "" and _zones.has(str(name)):
		var d: Dictionary = _zones[str(name)]
		_apply_character_to_effect(_global_effect, d)   # size/damping/dry/spread/predelay now
		target_wet = clampf(float(d.get("wet", 0.3)), 0.0, 1.0)
		_active_zone = str(name)
	else:
		_active_zone = ""
	if _wet_tween != null and _wet_tween.is_valid():
		_wet_tween.kill()
	if fade <= 0.0 or not is_inside_tree():
		_global_effect.wet = target_wet
	else:
		_wet_tween = create_tween()
		_wet_tween.tween_property(_global_effect, "wet", target_wet, fade)


## Build a per-zone reverb bus + an Area3D bound to it for POSITIONAL 3D reverb (optional
## designer hook). 3D spatial voices physically inside the area (matching area_mask) get
## positionally wet, auto-crossfaded across overlapping zones — Godot-native, zero per-frame
## code. Parent + position the returned Area3D in your scene. null if the zone is unknown.
func create_zone_area(name: String, extent: Vector3, position: Vector3 = Vector3.ZERO, amount: float = 0.8, uniformity: float = 0.5) -> Area3D:
	if not _zones.has(name):
		return null
	var bus_name := _ZONE_BUS_PREFIX + name
	var idx := _ensure_bus(bus_name)
	if AudioServer.get_bus_effect_count(idx) == 0:
		var eff := AudioEffectReverb.new()
		_apply_zone_to_effect(eff, _zones[name])
		AudioServer.add_bus_effect(idx, eff)
	var area := Area3D.new()
	area.reverb_bus_enabled = true
	area.reverb_bus_name = bus_name
	area.reverb_bus_amount = clampf(amount, 0.0, 1.0)
	area.reverb_bus_uniformity = clampf(uniformity, 0.0, 1.0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = extent
	shape.shape = box
	area.add_child(shape)
	area.position = position
	_zone_areas.append(area)
	return area


## Remove every engine-created reverb bus + zone area. Called on each reload BEFORE re-parsing,
## so reverb buses never leak or duplicate across pack generations (mirrors the event free loop).
func free_all() -> void:
	for a in _zone_areas:
		if is_instance_valid(a):
			a.queue_free()
	_zone_areas.clear()
	if _wet_tween != null and _wet_tween.is_valid():
		_wet_tween.kill()
	_wet_tween = null
	# Remove buses by name (index shifts as buses are removed → re-query each time). Never
	# touch Master (index 0).
	for bus_name in _created_buses:
		var idx := AudioServer.get_bus_index(bus_name)
		if idx > 0:
			AudioServer.remove_bus(idx)
	_created_buses.clear()
	_global_effect = null
	_active_zone = ""
	_zones.clear()


# --- internal ---

func _ensure_global_bus() -> void:
	var idx := _ensure_bus(GLOBAL_BUS)
	if _global_effect == null:
		_global_effect = AudioEffectReverb.new()
		AudioServer.add_bus_effect(idx, _global_effect)


func _ensure_bus(bus_name: String) -> int:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		AudioServer.add_bus()
		idx = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")
		_created_buses.append(bus_name)
	return idx


## Full apply (character + wet) — used at load for the default zone + on per-zone Area buses.
func _apply_zone_to_effect(effect: AudioEffectReverb, d: Dictionary) -> void:
	if effect == null:
		return
	_apply_character_to_effect(effect, d)
	effect.wet = clampf(float(d.get("wet", 0.3)), 0.0, 1.0)


## Apply everything EXCEPT wet (so the live global path can ramp wet separately).
func _apply_character_to_effect(effect: AudioEffectReverb, d: Dictionary) -> void:
	if effect == null:
		return
	effect.room_size = clampf(float(d.get("room_size", 0.7)), 0.0, 1.0)
	# Godot's native `damping` is INVERTED vs the acoustic/DAW convention: a higher
	# native value sets a HIGHER comb low-pass cutoff = BRIGHTER tail (verified in
	# reverb_filter.cpp:290 + empirically). Our neutral `damping` follows every DAW
	# reverb (and the web Freeverb): higher = darker tail (gradual HF cut). So we
	# FLIP it on apply, and both platforms agree on the key's meaning.
	effect.damping = clampf(1.0 - float(d.get("damping", 0.5)), 0.0, 1.0)
	effect.dry = clampf(float(d.get("dry", 1.0)), 0.0, 1.0)
	effect.spread = clampf(float(d.get("spread", 1.0)), 0.0, 1.0)
	effect.hipass = clampf(float(d.get("hipass", 0.0)), 0.0, 1.0)
	# Predelay is a WEB-ONLY concept. Godot's predelay is a FEEDBACK comb, not a true
	# predelay (reverb_filter.cpp:79: predelay_feedback>0 regenerates the delay =>
	# comb-tone at f0=1/predelay), so we force it FULLY OFF on Godot — never applied,
	# regardless of what the config or any `godot` override carries. (`predelay_ms`
	# from the neutral descriptor drives the web engine's true predelay instead.)
	effect.predelay_msec = 0.0
	effect.predelay_feedback = 0.0
