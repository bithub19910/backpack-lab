extends Node
const Snapshot = preload("res://BackpackLab/Snapshot.gd")
var pool = preload("res://BackpackLab/Pool.gd").new()
var result
var booted = false
var folder
var report = {"cases": [], "checks": {}}

func _ready():
	call_deferred("boot")

func run_case(request):
	yield(get_tree(), "idle_frame")
	pool.result_cache.clear()
	var job = pool.submit(request, folder.plus_file(request.id + ".json"))
	result = null
	if job == null:
		report.checks[request.id + "_submitted"] = false
		return
	while result == null and OS.get_ticks_msec() - job.started < 120000:
		pool.heartbeat()
		result = pool.poll(job)
		yield(get_tree(), "idle_frame")
	if result == null or result.get("status") != "ok":
		report.checks[request.id + "_completed"] = false
		pool.cancel(job)
		return
	var prepare = 0.0
	var reused = 0
	var created = 0
	for trial in result.trials:
		prepare += trial.timing_ms.prepare / float(result.count)
		reused += trial.allocation.reused
		created += trial.allocation.created
	report.cases.append({"name": request.id, "elapsed_ms": result.elapsed_ms, "prepare_ms": prepare, "reused": reused, "created": created})
	print("LAB_REUSE ", JSON.print(report.cases.back()))

func equal_trials(a, b):
	if a == null or b == null or a.get("status") != "ok" or b.get("status") != "ok":
		return false
	if a.count != b.count:
		return false
	for i in a.count:
		for key in ["seed", "outcome", "duration", "sides", "remaining_health"]:
			if not Snapshot.same(a.trials[i][key], b.trials[i][key]):
				print("LAB_REUSE_MISMATCH ", a.id, " ", b.id, " trial ", i, " ", key)
				return false
	return true

func boot():
	if booted: return
	booted = true
	Game.instanceCharacter(Game.Classes.Ranger)
	Game.set_process(false)
	Game.set_physics_process(false)
	ItemBook.set_process(false)
	for _i in 12:
		yield(get_tree(), "idle_frame")
	OS.vsync_enabled = false
	Engine.target_fps = 30
	VisualServer.set_render_loop_enabled(false)
	folder = OS.get_user_data_dir().plus_file("session-" + str(OS.get_process_id()))
	Directory.new().make_dir_recursive(folder)
	pool.start(OS.get_executable_path(), folder)
	var deadline = OS.get_ticks_msec() + 90000
	while pool.ready_count() < 4 and OS.get_ticks_msec() < deadline:
		pool.heartbeat()
		yield(get_tree(), "idle_frame")
	var cases = Snapshot.read_json("res://BackpackLab/reuse-cases.json")
	for spec in cases:
		var request = spec.duplicate(true)
		request.rules = Snapshot.read_json("res://BackpackLab/rules.json")
		request.runs = 10
		request.seed = 1280266059
		var name = request.id
		request.id = name + "-cold"
		request["reuse_objects"] = false
		yield(run_case(request.duplicate(true)), "completed")
		var cold = result
		request.id = name + "-warm"
		request.reuse_objects = true
		yield(run_case(request.duplicate(true)), "completed")
		report.checks[name + "_cold_warm_equal"] = equal_trials(cold, result)
		if not report.checks[name + "_cold_warm_equal"]:
			break
		request.id = name + "-warm-repeat"
		yield(run_case(request.duplicate(true)), "completed")
		report.checks[name + "_warm_repeat_equal"] = equal_trials(cold, result)
		if not report.checks[name + "_warm_repeat_equal"]:
			break
		# One changed item: unchanged objects must survive, with fresh combat state.
		for i in range(request.player.items.size() - 1, -1, -1):
			if not ItemBook.getDescriptor(request.player.items[i].id).hasType(Item.Type.Bag):
				request.player.items.remove(i)
				break
		request.id = name + "-delta-warm"
		yield(run_case(request.duplicate(true)), "completed")
		var delta = result
		var delta_board = request.player.duplicate(true)
		# Rebuild the missing item only, keeping its peers and native order.
		request.player = spec.player.duplicate(true)
		request.id = name + "-add-warm"
		yield(run_case(request.duplicate(true)), "completed")
		report.checks[name + "_add_equal"] = equal_trials(cold, result)
		if not report.checks[name + "_add_equal"]:
			break
		request.player = delta_board
		request.id = name + "-delta-cold"
		request.reuse_objects = false
		yield(run_case(request.duplicate(true)), "completed")
		report.checks[name + "_delta_equal"] = equal_trials(delta, result)
		if not report.checks[name + "_delta_equal"]:
			break
	# Startup prewarming uses persisted JSON only; no combat and no displayed result.
	pool.stop()
	# The normal persisted file includes rules; provide exactly that frozen input.
	var warm_input = cases[0].duplicate(true)
	warm_input.rules = Snapshot.read_json("res://BackpackLab/rules.json")
	Snapshot.write_json(folder.plus_file("last-worker-input.json"), warm_input)
	pool.start(OS.get_executable_path(), folder.plus_file("restart"), 1)
	deadline = OS.get_ticks_msec() + 90000
	while not File.new().file_exists(pool.workers[0].inbox + ".warmed") and OS.get_ticks_msec() < deadline:
		pool.heartbeat()
		yield(get_tree(), "idle_frame")
	report.checks["startup_warms_frozen_input"] = File.new().file_exists(pool.workers[0].inbox + ".warmed") and not File.new().file_exists(pool.workers[0].inbox + ".warm")
	Snapshot.write_json(OS.get_user_data_dir().plus_file("report.json"), report)
	pool.stop()
	get_tree().quit()
