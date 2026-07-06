class_name PFAGroup
extends RefCounted

## A group of events with shared volume control.
## Used for room-based loading and bus-style mixing.

var name: String = ""
var volume: float = 1.0
var mute: bool = false
var solo: bool = false
var event_names: Array = []
