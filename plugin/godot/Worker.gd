extends Node

var Snapshot
var Statistics
var ready_for_requests = false
var request = {}
var output_path = ""
var trials = []
var running = false
var finishing = false
var outcome = ""
var start_msec = 0
var started_msec = 0
var item_order = []
var inbox = ""
var last_job = ""
var polling_at = 0
var rules = {}
var terminal_time = -1.0
var parent_heartbeat = ""
var protocol_ready = false
var trial_started_msec = 0
var prepare_ms = 0
var log_path = "user://logs/godot.log"
var heartbeat_seen_msec = 0
var warm = preload("res://BackpackLab/WarmState.gd").new()
var warm_player = null
var warm_enemy = null
var warm_context = null
var allocation = {}
var warming = false
var warm_path = ""
const TrialRandom = preload("res://BackpackLab/TrialRandom.gd")


func _ready():
	process_priority = 10000
	print("LAB_AUTOLOAD_READY")
	call_deferred("boot")

func boot():
	if ready_for_requests:
		return
	ready_for_requests = true
	heartbeat_seen_msec = OS.get_ticks_msec()
	print("LAB_HELPERS_LOAD")
	Snapshot = load("res://BackpackLab/Snapshot.gd")
	Statistics = load("res://BackpackLab/Statistics.gd")
	rules = Snapshot.read_json("res://BackpackLab/rules.json")
	print("LAB_HELPERS_READY")
	if not "--lab-ui-preview" in OS.get_cmdline_args():
		VisualServer.set_render_loop_enabled(false)
	OS.low_processor_usage_mode = false
	OS.vsync_enabled = false
	Engine.target_fps = 0
	# Physics bodies are used for mouse dragging/storage, not native combat timers.
	Physics2DServer.set_active(false)
	Game.set_process(false)
	Game.set_physics_process(false)
	Game.instanceCharacter(Game.Classes.Ranger)
	# Background item prewarming and title decoration use the same RNG as combat.
	# They are unrelated to combat and must not run inside a seeded simulation.
	ItemBook.set_process(false)
	stop_decoration(Game.titleScreen)
	print("LAB_NATIVE_READY ", JSON.print({"version": Game.VERSION + Game.SUBVERSION,
		"items": ItemBook.descriptorList.size(), "user_data": OS.get_user_data_dir(),
		"steam_initialized": SteamHelper.is_init(), "physics_fps": Engine.iterations_per_second}))
	var input_path = ""
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--lab-log="):
			log_path = arg.trim_prefix("--lab-log=")
		if arg.begins_with("--lab-heartbeat="):
			parent_heartbeat = arg.trim_prefix("--lab-heartbeat=")
		if arg.begins_with("--lab-warm="):
			warm_path = arg.trim_prefix("--lab-warm=")
		if arg.begins_with("--lab-inbox="):
			inbox = arg.trim_prefix("--lab-inbox=")
		if arg.begins_with("--lab-request="):
			input_path = arg.trim_prefix("--lab-request=")
		if arg.begins_with("--lab-output="):
			output_path = arg.trim_prefix("--lab-output=")
	if "--lab-probe" in OS.get_cmdline_args():
		get_tree().quit()
		return
	if "--lab-ui-preview" in OS.get_cmdline_args():
		Game.splashScreenAnimation.play("FadeOut")
		Game.splashScreenAnimation.advance(5.0)
		var adapter = load("res://BackpackLab/Adapter.gd").new()
		get_tree().root.add_child(adapter)
		for _i in 30:
			yield(get_tree(), "idle_frame")
		var texture = get_viewport().get_texture().get_data()
		texture.flip_y()
		texture.save_png(output_path)
		print("LAB_UI_PREVIEW_READY")
		get_tree().quit()
		return
	if inbox != "":
		for _i in 12:
			yield(get_tree(), "idle_frame")
		OS.vsync_enabled = false
		VisualServer.set_render_loop_enabled(false)
		Snapshot.write_json(inbox + ".ready", {"status": "ready", "pid": OS.get_process_id()})
		idle()
		protocol_ready = true
		var previous = Snapshot.read_json(warm_path)
		if typeof(previous) == TYPE_DICTIONARY and Snapshot.same(previous.get("rules"), rules):
			request = previous
			output_path = inbox + ".warm"
			if validate_request() == "":
				warming = true
				running = true
				finishing = true
				Engine.target_fps = 0
				OS.low_processor_usage_mode = false
				call_deferred("begin_trial")
		return
	if "--lab-smoke" in OS.get_cmdline_args():
		Game.initStartInventory()
		yield(get_tree(), "idle_frame")
		if "--lab-hps-fixture" in OS.get_cmdline_args():
			for item in Game.PLAYER.INVENTORY.getItems().duplicate():
				if not item.isBag():
					Game.PLAYER.INVENTORY.removeItem(item)
					item.discard()
			for item_name in ["Leather Armor", "Banana", "Blood Amulet", "Healing Herbs"]:
				if not add_fixture_item(item_name):
					fail("测试物品无法摆放：" + item_name)
					return
		request = {"id": "smoke", "mode": "dummy", "horizon": 15.0, "runs": 1, "seed": 12345,
			"player": Snapshot.capture(Game.PLAYER), "context": {"mode": 0, "league": Game.Leagues.Master, "round": 1}}
		Snapshot.write_json(output_path + ".request.json", request)
	else:
		request = Snapshot.read_json(input_path)
	var invalid = validate_request()
	if invalid != "":
		fail(invalid)
		return
	started_msec = OS.get_ticks_msec()
	for _i in 12:
		yield(get_tree(), "idle_frame")
	OS.vsync_enabled = false
	OS.low_processor_usage_mode = false
	if VisualServer.has_method("set_render_loop_enabled"):
		VisualServer.set_render_loop_enabled(false)
	call_deferred("begin_trial")

func add_fixture_item(item_name):
	if not ItemBook.items.has(item_name):
		return false
	var item = ItemBook.instantiateItem(item_name)
	item.ownerType = Item.Owner.PlayerInventory
	Game.playerNode.add_child(item)
	for face in 4:
		for cell in Game.PLAYER.INVENTORY.inventoryCells:
			Game.PLAYER.INVENTORY.orientItem(item, cell, face)
			if Game.PLAYER.INVENTORY.canAddItemOrBag(item):
				Game.PLAYER.INVENTORY.addItemByTopLeft(item, cell)
				return true
	item.queue_free()
	return false

func idle():
	running = false
	finishing = false
	Engine.target_fps = 10
	OS.low_processor_usage_mode = true

func stop_decoration(node):
	node.set_process(false)
	node.set_physics_process(false)
	if node is Timer:
		node.stop()
	elif node is AnimationPlayer:
		node.stop()
	for child in node.get_children():
		stop_decoration(child)

func _process(_delta):
	# Finish after physics AND idle timers have processed this frame's boundary.
	if running and not finishing:
		if outcome == "" and request.mode == "dummy" and Game.combatTimer.combatTime >= request.horizon - 0.00001:
			outcome = "horizon_reached"
		elif outcome == "" and Game.combatTimer.combatTime >= 300.0:
			outcome = "safety_limit"
		if outcome != "":
			finishing = true
			call_deferred("finish_trial")
		elif OS.get_ticks_msec() - start_msec > 60000:
			fail("单场模拟超过 60 秒实际计算预算")
	if inbox == "" or not protocol_ready or OS.get_ticks_msec() < polling_at:
		return
	polling_at = OS.get_ticks_msec() + 100
	var file = File.new()
	# Godot 3 only tracks its own child PIDs; use the UI heartbeat for parent liveness.
	if parent_heartbeat != "":
		# Atomic replacement briefly removes the old path. A missing file is not
		# proof that the parent died; allow the same grace period as a stale file.
		if file.file_exists(parent_heartbeat):
			var modified = file.get_modified_time(parent_heartbeat)
			if modified > 0 and OS.get_unix_time() - modified <= 30:
				heartbeat_seen_msec = OS.get_ticks_msec()
		if OS.get_ticks_msec() - heartbeat_seen_msec > 30000:
			print("LAB_PARENT_HEARTBEAT_EXPIRED")
			get_tree().quit()
			return
	if file.file_exists(inbox + ".stop"):
		get_tree().quit()
		return
	if running:
		if finishing:
			return
		if file.file_exists(output_path + ".cancel"):
			outcome = "cancelled"
			finishing = true
			call_deferred("finish_trial")
		return
	var job = Snapshot.read_json(inbox)
	if typeof(job) != TYPE_DICTIONARY or job.get("id", "") == last_job:
		return
	last_job = str(job.id)
	request = job.request
	output_path = str(job.output)
	var invalid = validate_request()
	if invalid != "":
		fail(invalid)
		return
	trials = []
	Engine.target_fps = 0
	OS.low_processor_usage_mode = false
	started_msec = OS.get_ticks_msec()
	# Mark busy during construction too; _physics_process waits until activation.
	running = true
	finishing = true
	call_deferred("begin_trial")

func validate_request():
	if typeof(request) != TYPE_DICTIONARY or not request.has("player") or output_path == "":
		return "模拟请求无效"
	for key in ["id", "mode", "horizon", "runs", "seed", "context"]:
		if not request.has(key):
			return "请求字段缺失：" + key
	if not request.mode in ["dummy", "opponent"] or request.horizon < 1 or request.horizon > 60 or request.runs < 1 or request.runs > 100:
		return "模拟参数超出范围"
	if request.has("rules") and not Snapshot.same(request.rules, rules):
		return "规则版本不匹配，请重新构建插件"
	var boards = [request.player]
	if request.mode == "opponent":
		boards.append(request.get("opponent", {}))
	for board in boards:
		for key in ["class", "health", "base_stamina", "stamina", "items"]:
			if not board.has(key):
				return "阵容字段缺失：" + key
		if board["class"] < 0 or board["class"] >= Game.getNumClasses() or board.health <= 0 or board.items.size() > 128:
			return "阵容参数无效"
	request["rules"] = rules
	request.player = Snapshot.normalize(request.player)
	if request.mode == "opponent":
		request.opponent = Snapshot.normalize(request.opponent)
	return ""

func begin_trial():
	trial_started_msec = OS.get_ticks_msec()
	print("LAB_TRIAL_RESET ", trials.size())
	outcome = ""
	terminal_time = -1.0
	Game.fightEnded = true
	Game.combatLog.clear()
	EventBus.disconnectAll()
	EventBus.signalQueue.clear()
	# Global delayed callbacks can hold old particle/item nodes in their binds.
	# Cancel them before freeing a trial, including its still-running visuals.
	Util.lab_clear_delayed_calls()
	for tween in get_tree().get_processed_tweens():
		tween.kill()
	Game.ropeSpeedups.clear()
	Game.cubeAdvanced.clear()
	Game.sandbagActive = false
	var enemy = request.get("opponent", {})
	if request.mode == "dummy":
		enemy = {"class": 0, "health": 10000.0, "base_stamina": 5.0, "stamina": 5.0, "items": []}
	var reuse = request.get("reuse_objects", true) and warm_player != null and warm_context != null and Snapshot.same(warm_context, request.context) and warm_player["class"] == request.player["class"] and warm_enemy["class"] == enemy["class"]
	if reuse:
		reuse = warm.restore()
	var unchanged = reuse and Snapshot.same(warm_player, request.player) and Snapshot.same(warm_enemy, enemy)
	allocation = {"reused": 0, "created": 0, "warm": reuse}
	if not reuse:
		warm.entries.clear()
		warm.seen.clear()
		if Game.OPPONENT:
			Game.freeOpponent()
		if Game.PLAYER:
			Game.PLAYER.INVENTORY.deleteItems()
			Game.PLAYER.INVENTORY.queue_free()
			Game.PLAYER.queue_free()
			Game.PLAYER = null
		yield(get_tree(), "idle_frame")
	Game.lab_context = request.context
	Game.curMode = int(request.context.get("mode", 0))
	Game.curRound = int(request.context.get("round", 1))
	for i in request.context.get("custom_rules", []).size():
		CustomRules.values[i] = request.context.custom_rules[i]
	CustomRules.customRulesActive = request.context.get("custom_rules_active", false)
	if not reuse:
		Game.instanceCharacter(int(request.player["class"]))
		Game.OPPONENT = Game.opponentScene.instance()
		Game.OPPONENT.playerId = Character.ID.OPPONENT
		Game.opponentNode.add_child(Game.OPPONENT)
		Game.OPPONENT.connect("character_died", Game, "endCombat")
	Game.PLAYER.setOpponent(Game.OPPONENT)
	Game.OPPONENT.setOpponent(Game.PLAYER)
	var error = ""
	for side in 2:
		var character = Game.PLAYER if side == 0 else Game.OPPONENT
		var board = request.player if side == 0 else enemy
		var owner = Item.Owner.PlayerInventory if side == 0 else Item.Owner.Opponent
		if unchanged:
			allocation.reused += board.items.size()
		elif reuse:
			var changed = Snapshot.reconcile(character, warm_player if side == 0 else warm_enemy, board, owner)
			error = changed.error
			allocation.reused += changed.reused
			allocation.created += changed.created
		else:
			error = Snapshot.install(character, board, owner)
			allocation.created += board.items.size()
		if error != "":
			warm_player = null
			fail(error)
			return
	if not unchanged:
		yield(get_tree(), "idle_frame")
		if request.get("reuse_objects", true) or warming:
			warm_player = request.player.duplicate(true)
			warm_enemy = enemy.duplicate(true)
			warm_context = request.context.duplicate(true)
			# Freeze clean objects before any preparation, shuffle or combat mutation.
			warm.capture([Game.PLAYER, Game.PLAYER.INVENTORY, Game.OPPONENT, Game.OPPONENT.INVENTORY] + Game.PLAYER.INVENTORY.getItems() + Game.OPPONENT.INVENTORY.getItems())
		else:
			warm_player = null
	if warming:
		warming = false
		Snapshot.write_json(inbox + ".warmed", {"status": "ok", "created": allocation.created})
		idle()
		return
	Game.PLAYER.setMaxStamina(float(request.player.stamina))
	Game.OPPONENT.setMaxStamina(float(enemy.stamina))
	Game.PLAYER.cleanse()
	Game.OPPONENT.cleanse()
	# Reset native streams after visual construction, before shuffle and preparation.
	var trial_seed = int(request.seed) + trials.size()
	seed(trial_seed)
	Util.rng.seed = trial_seed
	Game.fightEnded = false
	Game.numTimesOutOfStamina = 0
	Game.state = Game.State.Combat
	Game.combatTimer.combatTime = 0.0
	Game.combatTimer.timeAdvance = 0.0
	Game.combatTimer.fatigueCounter = 0
	Game.emit_signal("shop_closed")
	Game.emit_signal("switching_to_combat")
	Game.PLAYER.shopToCombat()
	var ours = Game.PLAYER.INVENTORY.getItems().duplicate()
	var theirs = Game.OPPONENT.INVENTORY.getItems().duplicate()
	ours = TrialRandom.order(ours, trial_seed, 0)
	theirs = TrialRandom.order(theirs, trial_seed, 1)
	for character in [Game.PLAYER, Game.OPPONENT]:
		character.lab_choice_rng = TrialRandom.stream(trial_seed, "character:" + str(character.playerId), "choice")
		for buff in character.buffs.values():
			buff.lab_reset_rng(trial_seed)
		for key in ["accuracyRng", "critRng", "critResistanceRng", "stunResistanceRng"]:
			character.get(key).lab_rng = TrialRandom.stream(trial_seed, "character:" + str(character.playerId), key)
	item_order = ours + theirs
	Game.call_deferred("prepareItems", item_order)
	Util.callDelayed(self, "activate_trial", Game.COMBAT_DELAY)

func activate_trial():
	Engine.time_scale = 1.0
	running = true
	finishing = false
	outcome = ""
	start_msec = OS.get_ticks_msec()
	prepare_ms = start_msec - trial_started_msec
	Game.activateItems(item_order)
	print("LAB_TRIAL_STARTED ", trials.size())

func native_end(won):
	if outcome == "":
		outcome = "win" if won else "loss"
		terminal_time = Game.combatTimer.combatTime

func finish_trial():
	running = false
	Game.fightEnded = true
	var duration = terminal_time if terminal_time >= 0.0 else Game.combatTimer.combatTime
	var combat_ms = OS.get_ticks_msec() - start_msec
	var extract_started = OS.get_ticks_msec()
	var sides = [] if request.get("summary_only", false) else Statistics.extract(float(request.horizon))
	trials.append({"index": trials.size(), "seed": int(request.seed) + trials.size(),
		"allocation": allocation.duplicate(true),
		"timing_ms": {"prepare": prepare_ms, "combat": combat_ms, "extract": OS.get_ticks_msec() - extract_started},
		"outcome": outcome, "duration": duration, "sides": sides,
		"remaining_health": [Game.PLAYER.curHealth, Game.OPPONENT.curHealth]})
	EventBus.disconnectAll()
	Game.PLAYER.combatEnd()
	Game.OPPONENT.combatEnd()
	Game.combatTimer.combatEnd()
	for item in item_order:
		if is_instance_valid(item):
			item.combatEnd()
	print("LAB_TRIAL_DONE ", trials.size(), " ", duration, " ", outcome)
	Snapshot.write_json(output_path + ".progress", {"done": trials.size(), "total": request.runs})
	if outcome == "cancelled":
		fail("已取消")
	elif trials.size() < int(request.runs):
		running = true
		finishing = true
		call_deferred("begin_trial")
	else:
		var log_file = File.new()
		if log_file.open(log_path, File.READ) == OK:
			var native_log = log_file.get_as_text()
			log_file.close()
			if "SCRIPT ERROR:" in native_log:
				fail("原版脚本报告异常；本次结果未通过完整性检查")
				return
		var result = Statistics.aggregate(trials, request.mode, float(request.horizon), request.get("summary_only", false))
		result["id"] = request.id
		result["status"] = "ok"
		result["elapsed_ms"] = OS.get_ticks_msec() - started_msec
		result["request"] = request
		if not Snapshot.write_json(output_path, result):
			print("LAB_FAILURE 无法保存结果")
		if inbox == "":
			get_tree().quit()
		else:
			idle()

func fail(message):
	warm_player = null
	warming = false
	print("LAB_FAILURE ", message)
	if output_path != "":
		Snapshot.write_json(output_path, {"status": "error", "message": message})
	if inbox == "":
		get_tree().quit(1)
	else:
		Game.fightEnded = true
		idle()
