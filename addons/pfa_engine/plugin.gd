@tool
extends EditorPlugin

## PFA Engine — PitchFox Audio Engine plugin for Godot.
## Registers PFA autoload singleton for adaptive music & SFX.

func _enter_tree() -> void:
	add_autoload_singleton("PFA", "res://addons/pfa_engine/pfa.gd")
	print("[PFA Engine] Plugin enabled")

func _exit_tree() -> void:
	remove_autoload_singleton("PFA")
	print("[PFA Engine] Plugin disabled")
