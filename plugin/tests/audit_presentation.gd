extends Node
# Local audit: enumerate native animation method tracks before disabling players.
var booted = false
var calls = {}
var paths = {}

func scan(node):
	if node is AnimationPlayer:
		for name in node.get_animation_list():
			var animation = node.get_animation(name)
			for i in animation.get_track_count():
				var type = animation.track_get_type(i)
				var path = str(animation.track_get_path(i))
				paths[str(type) + ":" + path] = true
				if type == Animation.TYPE_METHOD:
					for key in animation.track_get_key_count(i):
						var value = animation.track_get_key_value(i, key)
						calls[str(value.method)] = true
	for child in node.get_children(): scan(child)

func _ready():
	call_deferred("boot")

func boot():
	if booted: return
	booted = true
	Game.instanceCharacter(Game.Classes.Ranger)
	Game.set_process(false)
	Game.set_physics_process(false)
	ItemBook.set_process(false)
	for _i in 12: yield(get_tree(), "idle_frame")
	scan(Game.PLAYER)
	for descriptor in ItemBook.descriptorList:
		if descriptor.scene == null: continue
		var root = descriptor.scene.instance()
		scan(root)
		root.free()
	var file = File.new()
	file.open("user://animation-audit.json", File.WRITE)
	file.store_string(JSON.print({"calls": calls.keys(), "paths": paths.keys()}))
	file.close()
	print("LAB_ANIMATION_AUDIT ", calls.size(), " ", paths.size())
	get_tree().quit()
