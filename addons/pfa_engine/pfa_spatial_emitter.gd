class_name PFASpatialEmitter
extends RefCounted

## A long-lived spatial emitter for moving objects (enemies, vehicles, thrown bombs, a
## buzzing bee). Mirrors JS PFASpatialEmitter (FEATURE parity): it holds a world position;
## voices triggered on it FOLLOW that position (we write each player's global_position) and
## stop on destroy(). The game only sets position + triggers — the editor/engine own the HOW.
##
## Created via PFA.create_emitter_2d / create_emitter_3d. Mode (2D/3D) is fixed at creation.

var _spatial: PFASpatial = null
var _event_name: String = ""
## Raw game-passed spatial OVERRIDE (merged with the event's authored spatial at trigger time:
## defaults ← event.spatial ← this). Storing it raw (not pre-merged) means the event's
## authored attenuation still shows through where the game didn't override. JS parity.
var _cfg: Dictionary = {}
var _mode: String = "2D"                  # "2D" | "3D"
var _pos: Vector3 = Vector3.ZERO          # world position (z unused in 2D)
var _players: Array = []                  # active AudioStreamPlayer2D/3D voices following this emitter
var _smart_loops: Array = []              # active per-cycle smart-loop controllers (Dictionaries)
var _destroyed: bool = false


func _init(spatial: PFASpatial, event_name: String, mode: String, cfg: Dictionary = {}) -> void:
	_spatial = spatial
	_event_name = event_name
	_mode = mode
	_cfg = cfg if cfg != null else {}


## Update 2D position (game pixels). Live voices re-pan/attenuate from it automatically.
func set_position_2d(x: float, y: float) -> void:
	_pos = Vector3(x, y, 0.0)
	_sync_positions()


## Update 3D position (game world units). Live voices follow.
func set_position_3d(x: float, y: float, z: float) -> void:
	_pos = Vector3(x, y, z)
	_sync_positions()


func _sync_positions() -> void:
	if _spatial == null:
		return
	for p in _players:
		if is_instance_valid(p):
			_spatial._set_voice_position(p, _mode, _pos)


## Trigger this emitter's event (or an `event_name` override) at the current position.
## Returns the first voice player (or null). Multi-track events spawn one voice per track,
## all linked to this emitter.
func trigger(event_name: String = "") -> Object:
	if _destroyed or _spatial == null:
		return null
	var ev := event_name if event_name != "" else _event_name
	return _spatial._trigger_on_emitter(self, ev)


## Destroy the emitter: stop + free every voice it owns. With no `fade_ms` (or -1) each voice
## falls back to its event's authored release_fade (so a game passes no fade number). Mirrors
## JS emitter.destroy().
func destroy(fade_ms: float = -1.0) -> void:
	if _destroyed:
		return
	_destroyed = true
	# Stop any per-cycle smart-loop controllers first (cancel their next cycle).
	for ctrl in _smart_loops:
		ctrl["stopped"] = true
	_smart_loops.clear()
	if _spatial != null:
		for p in _players.duplicate():
			_spatial._release_voice(p, fade_ms)
		_spatial._forget_emitter(self)
	_players.clear()
