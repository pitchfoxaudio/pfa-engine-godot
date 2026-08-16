@tool
extends EditorPlugin

## PFA Engine — PitchFox Audio Engine plugin for Godot.
## Registers PFA autoload singleton for adaptive music & SFX, and makes sure `.pfabank`
## files reach the exported build (Godot skips unknown extensions — see pfa_export_plugin.gd).

const PFAExportPlugin := preload("res://addons/pfa_engine/pfa_export_plugin.gd")

var _export_plugin: EditorExportPlugin = null


func _enter_tree() -> void:
	add_autoload_singleton("PFA", "res://addons/pfa_engine/pfa.gd")
	_export_plugin = PFAExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	remove_autoload_singleton("PFA")
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
