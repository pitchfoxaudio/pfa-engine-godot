@tool
extends EditorExportPlugin

## Ships `.pfabank` files with the game.
##
## Godot only exports files it recognises: a resource, or something matched by the
## preset's "Filters to export non-resource files/folders". A Studio bank is neither —
## so a project that loads `res://audio/project.pfabank` runs in the editor and then
## fails in the exported build with "Cannot open", because the file never made it into
## the PCK. The loose pack survives on its own (`config.json` is a resource and the
## audio files are imported), which is exactly why the gap is easy to miss.
##
## This plugin closes it: every bank in the project is added to the export. Set the
## project setting `pfa_engine/export/include_pfabank = false` to opt out (a project
## that ships loose packs only, or one that lists banks in the export filter itself).

const SETTING := "pfa_engine/export/include_pfabank"
const BANK_EXT := PFAEvent.BANK_EXTENSION

## Directories that never hold a shippable bank — skipping them keeps the scan cheap
## on big projects and out of Godot's own import cache.
const SKIP_DIRS := [".godot", ".git", ".import"]


func _get_name() -> String:
	return "PFA Engine"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	if ProjectSettings.has_setting(SETTING) and not bool(ProjectSettings.get_setting(SETTING)):
		return
	var banks: Array[String] = []
	_collect_banks("res://", banks)
	if banks.is_empty():
		return

	# A bank the preset already handles must NOT be added again — Godot writes both
	# copies into the PCK and the build silently doubles the size of its largest asset.
	var include_globs: PackedStringArray = PackedStringArray()
	var exclude_globs: PackedStringArray = PackedStringArray()
	var preset: EditorExportPreset = get_export_preset()
	if preset != null:
		include_globs = _split_filter(preset.get_include_filter())
		exclude_globs = _split_filter(preset.get_exclude_filter())

	var added: int = 0
	var total: int = 0
	for bank_path in banks:
		if _matches_any(bank_path, exclude_globs):
			continue  # the author excluded it on purpose
		if _matches_any(bank_path, include_globs):
			continue  # the preset already ships it
		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(bank_path)
		if bytes.is_empty():
			push_warning("[PFA] Could not read bank for export: %s" % bank_path)
			continue
		add_file(bank_path, bytes, false)
		added += 1
		total += bytes.size()
	if added > 0:
		print("[PFA] Added %d .pfabank file(s) to the export, %.1f MB" % [added, total / 1048576.0])


## Export filters are one comma-separated glob list, the way the export dialog stores them.
static func _split_filter(raw: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for part in raw.split(",", false):
		var glob: String = part.strip_edges()
		if glob != "":
			out.append(glob)
	return out


## Godot matches filters against the project-relative path, so "*.pfabank" and
## "audio/*" both work — mirror that instead of matching the file name alone.
static func _matches_any(res_path: String, globs: PackedStringArray) -> bool:
	var rel: String = res_path.trim_prefix("res://")
	for glob in globs:
		if rel.matchn(glob) or rel.get_file().matchn(glob):
			return true
	return false


## Recursive scan for banks. Static and side-effect free so the test suite can run it
## against a scratch tree instead of trusting the export dialog.
static func _collect_banks(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for file_name in dir.get_files():
		if file_name.get_extension().to_lower() == BANK_EXT:
			out.append(dir_path.path_join(file_name))
	for sub in dir.get_directories():
		if sub in SKIP_DIRS or sub.begins_with("."):
			continue
		_collect_banks(dir_path.path_join(sub), out)
