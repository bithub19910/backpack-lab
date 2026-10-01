extends Node
const Snapshot = preload("res://BackpackLab/Snapshot.gd")
var pool = preload("res://BackpackLab/Pool.gd").new()
var started = false

func _ready():
	call_deferred("boot")

func boot():
	if started: return
	started = true
	Game.instanceCharacter(Game.Classes.Ranger)
	Game.set_process(false)
	Game.set_physics_process(false)
	ItemBook.set_process(false)
	for _i in 12: yield(get_tree(), "idle_frame")
	OS.vsync_enabled = false
	Engine.target_fps = 30
	VisualServer.set_render_loop_enabled(false)
	var directory = OS.get_user_data_dir().plus_file("session-" + str(OS.get_process_id()))
	Directory.new().make_dir_recursive(directory)
	pool.start(OS.get_executable_path(), directory)
	var start = OS.get_ticks_msec()
	while pool.ready_count() < 4 and OS.get_ticks_msec() - start < 90000:
		pool.heartbeat()
		yield(get_tree(), "idle_frame")
	var report = {"cases": [], "failures": [], "rules": Snapshot.read_json("res://BackpackLab/rules.json")}
	var specs = Snapshot.read_json("res://BackpackLab/precision-cases.json")
	for spec in specs:
		var decoded = RunData.deserializeItems(spec.code, spec.version)
		if decoded == null:
			report.failures.append(spec.name + ": decode failed")
			continue
		var board = {"class": spec.character_class, "health": decoded.health, "base_stamina": 5, "stamina": decoded.stamina, "items": []}
		for tuple in decoded.items:
			var gems = []
			for gem in tuple.get("g", []):
				gems.append(null if gem == RunDatabase.emptySocketId else {"id": ItemBook.getGemForIndex(gem).getName(), "face": 0, "data": null})
			board.items.append({"id": tuple.d.getName(), "cell": [tuple.c.x, tuple.c.y], "face": tuple.f, "data": tuple.get("pd"), "gems": gems})
		for mode in ["dummy", "opponent"]:
			var entry = {"name": spec.name, "mode": mode, "class": spec.character_class, "round": spec.round, "samples": [], "elapsed_ms": []}
			for group in 2:
				var request = {"id": spec.name + "-" + mode + "-" + str(group), "mode": mode, "player": board, "opponent": board, "runs": 100, "horizon": 15, "seed": 100000 + specs.find(spec) * 10000 + group * 1000 + (500 if mode == "opponent" else 0), "rules": report.rules, "context": {"mode": 1, "round": spec.round, "league": Game.Leagues.Master}}
				var job = pool.submit(request, directory.plus_file(request.id + ".json"))
				var result = null
				while result == null and OS.get_ticks_msec() - job.started < 240000:
					pool.heartbeat()
					result = pool.poll(job)
					yield(get_tree(), "idle_frame")
				if result == null or result.get("status") != "ok" or result.get("unresolved", 0) > 0:
					report.failures.append({"case": request.id, "error": result.get("message", "unresolved") if result != null else "timeout"})
					pool.cancel(job)
					break
				var samples = []
				for trial in result.trials:
					var own = trial.sides[0]
					samples.append([own.damage.back() / 15.0, (own.effective_heal.back() + own.overheal.back() + own.max_health.back() + own.armor.back()) / 15.0])
				entry.samples.append(samples)
				entry.elapsed_ms.append(result.elapsed_ms)
				print("LAB_PRECISION ", request.id, " ", result.elapsed_ms)
			if entry.samples.size() == 2: report.cases.append(entry)
			Snapshot.write_json(OS.get_user_data_dir().plus_file("report.json"), report)
	pool.stop()
	get_tree().quit()
