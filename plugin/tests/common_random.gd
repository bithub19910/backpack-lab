extends Node
const Snapshot = preload("res://BackpackLab/Snapshot.gd")
var pool = preload("res://BackpackLab/Pool.gd").new()
var checks = {}
var folder
var result
var booted = false
var before

func _ready():
	call_deferred("boot")

func add_item(name):
	var item = ItemBook.instantiateItem(name)
	item.ownerType = Item.Owner.PlayerInventory
	Game.PLAYER.INVENTORY.itemNode.add_child(item)
	for face in 4:
		for cell in Game.PLAYER.INVENTORY.inventoryCells:
			Game.PLAYER.INVENTORY.orientItem(item, cell, face)
			if Game.PLAYER.INVENTORY.canAddItemOrBag(item):
				Game.PLAYER.INVENTORY.addItemByTopLeft(item, cell)
				return item
	item.queue_free()
	return null

func compute(board, name, noise = false):
	yield(get_tree(), "idle_frame")
	pool.result_cache.clear()
	var request = {"id": name, "player": board, "context": {"mode": 0, "round": 1, "league": 5}, "mode": "dummy", "runs": 10, "seed": 1280266059, "horizon": 15, "rules": Snapshot.read_json("res://BackpackLab/rules.json")}
	request["test_cosmetic_noise"] = noise
	var job = pool.submit(request, folder.plus_file(name + ".json"))
	result = null
	var deadline = OS.get_ticks_msec() + 90000
	while result == null and job != null and OS.get_ticks_msec() < deadline:
		pool.heartbeat()
		result = pool.poll(job)
		yield(get_tree(), "idle_frame")
	checks[name + "_completed"] = result != null and result.get("status") == "ok"
	print("LAB_CRN ", name, " ", checks[name + "_completed"])

func same_curves(a, b):
	if a == null or b == null or a.get("status") != "ok" or b.get("status") != "ok" or not Snapshot.same(a.sides, b.sides):
		return false
	for i in a.count:
		for side in 2:
			for key in ["damage", "effective_heal", "overheal", "max_health", "armor"]:
				if not Snapshot.same(a.trials[i].sides[side][key], b.trials[i].sides[side][key]):
					return false
	return true

func boot():
	if booted: return
	booted = true
	Game.instanceCharacter(Game.Classes.Ranger)
	Game.set_process(false)
	Game.set_physics_process(false)
	ItemBook.set_process(false)
	for _i in 12: yield(get_tree(), "idle_frame")
	Game.initStartInventory()
	for item in Game.PLAYER.INVENTORY.getItems().duplicate():
		if not item.isBag():
			Game.PLAYER.INVENTORY.removeItem(item)
			item.discard()
	for _i in 3: add_item("Leather Bag")
	add_item("Wooden Sword")
	add_item("Wooden Sword")
	var stamina_before = Game.numTimesOutOfStamina
	Game.PLAYER.INVENTORY.getItems().back().playOutOfStaminaAnimation()
	checks["disabled_stamina_animation_keeps_counter"] = Game.numTimesOutOfStamina == stamina_before + 1
	# Execute actual native presentation entry points, checking both RNG APIs.
	var random_state = Util.rng.state
	seed(73129)
	var expected_global = randi()
	seed(73129)
	Game.shopKeeper.randNum(7)
	Game.speechBubble.shutUp()
	Game.shopKeeper.onSell(Game.PLAYER.INVENTORY.getItems().back())
	Game.classResources[Game.Classes.Ranger].getBuySound()
	Game.PLAYER.onSpriteClicked()
	ItemBook.getDescriptor("Piggybank").getFlavorText()
	Game.shopSceneNode.slots[0].addSpecialShopParticles()
	Game.shopSceneNode.slots[0].playSaleSound()
	Util.randBuffLabelDir()
	checks["native_dialogue_particles_sounds_preserve_combat_rng"] = Util.rng.state == random_state and randi() == expected_global
	before = Snapshot.capture(Game.PLAYER)
	var pig = add_item("Piggybank")
	assert(pig != null)
	var pig_board = Snapshot.capture(Game.PLAYER)
	var original_cell = pig.getTopLeftCell()
	var original_face = pig.getFaceDirection()
	Game.PLAYER.INVENTORY.removeItem(pig)
	Game.PLAYER.INVENTORY.orientItem(pig, original_cell, original_face)
	Game.PLAYER.INVENTORY.addItemByTopLeft(pig, original_cell)
	var reinserted = Snapshot.capture(Game.PLAYER)
	checks["same_board_after_reinsert"] = Snapshot.same(pig_board, reinserted)
	var variants = []
	Game.PLAYER.INVENTORY.removeItem(pig)
	for face in 4:
		for cell in Game.PLAYER.INVENTORY.inventoryCells:
			Game.PLAYER.INVENTORY.orientItem(pig, cell, face)
			if Game.PLAYER.INVENTORY.canAddItemOrBag(pig) and (cell != original_cell or face != original_face):
				Game.PLAYER.INVENTORY.addItemByTopLeft(pig, cell)
				variants.append(Snapshot.capture(Game.PLAYER))
				Game.PLAYER.INVENTORY.removeItem(pig)
				break
	pig.discard()
	var armor = add_item("Protective Purse")
	assert(armor != null)
	var armor_board = Snapshot.capture(Game.PLAYER)
	folder = OS.get_user_data_dir().plus_file("session-" + str(OS.get_process_id()))
	Directory.new().make_dir_recursive(folder)
	pool.start(OS.get_executable_path(), folder)
	OS.vsync_enabled = false
	Engine.target_fps = 30
	VisualServer.set_render_loop_enabled(false)
	yield(compute(before, "baseline"), "completed")
	var baseline = result
	checks["ten_distinct_seeds_keep_random_outcomes"] = false
	for i in range(1, 10):
		checks.ten_distinct_seeds_keep_random_outcomes = checks.ten_distinct_seeds_keep_random_outcomes or not Snapshot.same(baseline.trials[0].sides[0].damage, baseline.trials[i].sides[0].damage)
	yield(compute(before, "cosmetic-noise", true), "completed")
	checks["cosmetic_noise_during_combat_keeps_every_sample"] = same_curves(baseline, result)
	yield(compute(pig_board, "pig"), "completed")
	var pig_result = result
	checks["inert_pig_does_not_change_curves"] = same_curves(baseline, pig_result)
	yield(compute(reinserted, "reinserted"), "completed")
	checks["reinsert_uncached_identical"] = same_curves(pig_result, result)
	for i in variants.size():
		yield(compute(variants[i], "move-rotate-" + str(i)), "completed")
		checks["move_rotate_unchanged_" + str(i)] = same_curves(pig_result, result)
	yield(compute(armor_board, "armor"), "completed")
	checks["armor_keeps_damage"] = Snapshot.same(baseline.sides[0].damage, result.sides[0].damage)
	checks["armor_adds_exact_15_each_sample"] = true
	for i in 10:
		checks.armor_adds_exact_15_each_sample = checks.armor_adds_exact_15_each_sample and abs(result.trials[i].sides[0].armor.back() - baseline.trials[i].sides[0].armor.back() - 15) < 0.00001 and Snapshot.same(result.trials[i].sides[0].damage, baseline.trials[i].sides[0].damage)
	Snapshot.write_json(OS.get_user_data_dir().plus_file("report.json"), checks)
	print("LAB_CRN_CHECKS ", JSON.print(checks))
	pool.stop()
	get_tree().quit()
