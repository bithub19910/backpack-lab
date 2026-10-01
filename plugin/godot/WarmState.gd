extends Reference

# Private worker objects only. Never captures nodes from the live game process.
# Save script state, including nested non-resource Reference objects (native
# balanced RNGs and damage sources). Shared static resources remain read-only.
var entries = []
var seen = {}

func copy_value(value):
	if typeof(value) in [TYPE_ARRAY, TYPE_DICTIONARY]:
		return value.duplicate(true)
	return value

func inspect_value(value):
	if typeof(value) == TYPE_ARRAY:
		for part in value:
			inspect_value(part)
	elif typeof(value) == TYPE_DICTIONARY:
		for key in value:
			inspect_value(value[key])
	elif value is Reference and not value is Resource and not value is FuncRef:
		capture_object(value)

func capture_object(object):
	if not is_instance_valid(object) or seen.has(object.get_instance_id()):
		return
	seen[object.get_instance_id()] = true
	var entry = {"object": object, "values": {}}
	entries.append(entry)
	for property in object.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var value = object.get(property.name)
			entry.values[property.name] = copy_value(value)
			if property.name != "descriptor":
				inspect_value(value)
	if object is AnimationPlayer:
		entry["animation"] = [object.is_playing(), object.current_animation, object.current_animation_position if object.current_animation != "" else 0.0, object.playback_speed]
	if object is Node2D:
		entry["transform"] = object.transform
	if object is Node:
		entry["process"] = object.is_processing()
		entry["physics"] = object.is_physics_processing()
		for child in object.get_children():
			capture_object(child)

func capture(roots):
	entries.clear()
	seen.clear()
	for root in roots:
		capture_object(root)

func restore():
	for entry in entries:
		if not is_instance_valid(entry.object):
			return false
	for entry in entries:
		var object = entry.object
		if object is AudioStreamPlayer or object is AudioStreamPlayer2D or object is AudioStreamPlayer3D:
			object.stop()
		if object is Timer:
			object.stop()
		elif object is AnimationPlayer:
			object.stop()
		for key in entry.values:
			object.set(key, copy_value(entry.values[key]))
		if object is AnimationPlayer and entry.animation[0] and entry.animation[1] != "":
			object.play(entry.animation[1])
			object.seek(entry.animation[2], false)
			object.playback_speed = entry.animation[3]
		if object is Node2D:
			object.transform = entry.transform
		if object is Node:
			object.set_process(entry.process)
			object.set_physics_process(entry.physics)
	return true
