class_name PFALive
extends Node

## PFA Live Connect — WebSocket bridge to PFA Studio for real-time tuning.
## Godot mirror of the web PFALiveConnect: same port, same
## JSON protocol v1.1.
##
## Usage in a game scene:
##   var live := PFALive.new()
##   add_child(live)
##   live.status_changed.connect(_on_live_status)   # optional
##   live.connect_to_editor()                       # ws://localhost:9264
##
## Debug-only by default: in a release export (`not OS.is_debug_build()`)
## connect_to_editor() is a no-op, so a scene shipped with Live wired costs
## nothing. Set `debug_only = false` to force (kiosk demo etc.).
##
## Unknown message types are IGNORED — a newer editor may talk to an older
## client (forward compatibility, both ends honor it).

signal status_changed(connected: bool)
signal log_message(msg: String)
## Emitted after a successful pack reload — the game re-triggers its looping
## ambiences / music here (stop_all killed the voices; emitters survived).
signal pack_reloaded

const ENGINE_VERSION := "0.11.3"
const DEFAULT_PORT := 9264
const RECONNECT_DELAY := 5.0       # JS parity: fixed 5 s retry
const RELOAD_SETTLE := 0.6         # JS parity: lets stop_all's 0.5 s fade ring out

var port: int = DEFAULT_PORT
var debug_only: bool = true
var connected: bool = false
## The engine the dispatch drives. Defaults to the PFA autoload; injectable
## (tests pass a spy, a tool could pass a second instance).
var pfa: Object = null

var _socket: WebSocketPeer = null
var _reconnect_left: float = 0.0
var _reloading: bool = false


func _ready() -> void:
	if pfa == null:
		pfa = get_node_or_null("/root/PFA")


## Open (or re-open) the editor connection. Safe to call any time.
func connect_to_editor(to_port: int = -1) -> void:
	if debug_only and not OS.is_debug_build():
		return
	if to_port > 0:
		port = to_port
	_reconnect_left = 0.0
	_open_socket()


func disconnect_from_editor() -> void:
	_reconnect_left = 0.0
	if _socket != null:
		_socket.close()
		_socket = null
	_set_connected(false)


func _open_socket() -> void:
	_socket = WebSocketPeer.new()
	if _socket.connect_to_url("ws://localhost:%d" % port) != OK:
		_socket = null
		_arm_reconnect()


func _process(delta: float) -> void:
	if _socket == null:
		if _reconnect_left > 0.0:
			_reconnect_left -= delta
			if _reconnect_left <= 0.0:
				_open_socket()
		return
	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not connected:
				_set_connected(true)
				_log("[PFA Live] Connected to editor")
				_send(_hello_payload())
			while _socket.get_available_packet_count() > 0:
				var msg = JSON.parse_string(_socket.get_packet().get_string_from_utf8())
				if msg is Dictionary:
					_handle_message(msg)
		WebSocketPeer.STATE_CLOSED:
			_socket = null
			_set_connected(false)
			_arm_reconnect()


func _arm_reconnect() -> void:
	_reconnect_left = RECONNECT_DELAY


func _set_connected(c: bool) -> void:
	if connected == c:
		return
	connected = c
	status_changed.emit(c)


## Client self-introduction — the editor lists connected platforms/versions.
func _hello_payload() -> Dictionary:
	var pack_name = null
	if pfa != null:
		var cfg = pfa.get("_config")
		if cfg is Dictionary:
			pack_name = cfg.get("project", null)
	return {"type": "hello", "platform": "godot", "engine": ENGINE_VERSION, "pack": pack_name}


func _send(data: Dictionary) -> void:
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(data))


func _log(msg: String) -> void:
	# Console print rides the global diagnostics gate; the signal always fires so a
	# game-side status overlay keeps working with debug_logs off.
	PFAEvent._dlog(msg)
	log_message.emit(msg)


## Dispatch an editor message onto the engine API — exact mirror of the JS
## client's switch; both engines' clients are locked by their own tests.
func _handle_message(msg: Dictionary) -> void:
	if pfa == null:
		return
	var ev = msg.get("event")
	match str(msg.get("type", "")):
		"reload":
			_reload_pack()
		"set_volume":
			if ev != null:
				pfa.set_event_volume(str(ev), float(msg.get("volume", 1.0)))
		"set_level":
			if ev != null:
				pfa.set_level(str(ev), int(msg.get("level", 0)))
		"play":
			if ev != null:
				pfa.play(str(ev))
		"stop":
			if ev != null:
				pfa.stop(str(ev), float(msg.get("fade", 0.0)))
		"trigger":
			if ev != null:
				pfa.trigger(str(ev))
		"set_group_volume":
			if msg.get("group") != null:
				pfa.set_group_volume(str(msg.get("group")), float(msg.get("volume", 1.0)))
		"set_master_volume":
			pfa.set_master_volume(float(msg.get("volume", 1.0)))
		"set_mute":
			if ev != null:
				if bool(msg.get("muted", false)):
					pfa.duck(str(ev), 0.0, 0.1)
				else:
					pfa.unduck(str(ev), 0.1)
		"duck":
			if ev != null:
				pfa.duck(str(ev), float(msg.get("level", 0.0)), float(msg.get("fade", 0.5)))
		"unduck":
			if ev != null:
				pfa.unduck(str(ev), float(msg.get("fade", 0.1)))
		"welcome":
			_log("[PFA Live] Server: %s v%s" % [str(msg.get("message", "")), str(msg.get("version", ""))])
			# Late-join master handshake: a client that connects after the editor's
			# master fader moved learns the current value (absent on old editors ⇒
			# no-op — the bare welcome stays a zero-call message). JS parity.
			if msg.has("master_volume"):
				pfa.set_master_volume(float(msg["master_volume"]))
		_:
			pass  # forward compat — ignore types we don't know


## Full pack reload: stop everything (spatial emitters survive), wait for the
## fade to ring out, re-read config + samples from disk. The engine frees the
## previous event nodes inside load_pack.
func _reload_pack() -> void:
	if _reloading:
		_log("[PFA Live] Reload already in progress, skipping")
		return
	var pp = pfa.get("pack_path")
	var path: String = pp if pp is String else ""
	if path == "":
		_log("[PFA Live] No pack loaded — nothing to reload")
		return
	_reloading = true
	_log("[PFA Live] Reloading audio pack...")
	pfa.stop_all(0.5)
	await get_tree().create_timer(RELOAD_SETTLE).timeout
	# A refused reload (Studio mid-write, wrong path) leaves the running pack
	# loaded — say so instead of announcing a reload that did not happen.
	if not pfa.load_pack(path):
		_reloading = false
		_log("[PFA Live] Reload refused — keeping the loaded pack")
		return
	_reloading = false
	_log("[PFA Live] Audio pack reloaded")
	pack_reloaded.emit()
