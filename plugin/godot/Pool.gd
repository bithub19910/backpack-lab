extends Reference

const Snapshot = preload("res://BackpackLab/Snapshot.gd")
const Statistics = preload("res://BackpackLab/Statistics.gd")
var workers = []
var executable = ""
var directory = ""
var heartbeat_at = 0
var result_cache = []
var active_job = null

func request_key(request):
	var input = request.duplicate(true)
	input.erase("id")
	input.erase("preview_item")
	return JSON.print(input).sha256_text()

func sample_key(request):
	var input = request.duplicate(true)
	input.erase("runs")
	return request_key(input)

func is_same_pending(request):
	return active_job != null and not active_job.get("finished", false) and active_job.cache_key == request_key(request)

func remember(job, result):
	var key = sample_key(job.request)
	for i in range(result_cache.size() - 1, -1, -1):
		if result_cache[i].sample_key == key:
			if result_cache[i].result.count > result.count:
				return
			result_cache.remove(i)
	result_cache.push_front({"key": job.cache_key, "sample_key": key, "preview": job.request.get("preview_item", "") != "", "result": result.duplicate(true)})
	# Five offers cannot evict the current/best boards. Both groups are bounded.
	for preview_group in [true, false]:
		var kept = 0
		var limit = 5 if preview_group else 8
		var i = 0
		while i < result_cache.size():
			if result_cache[i].preview == preview_group:
				kept += 1
				if kept > limit:
					result_cache.remove(i)
					continue
			i += 1

func validate_part(result, part):
	if result.get("status") != "ok" or result.get("id") != part.id or result.get("count") != part.request.runs:
		return false
	var trials = result.get("trials", [])
	if trials.size() != int(part.request.runs):
		return false
	for i in trials.size():
		var trial = trials[i]
		if trial.get("index", -1) != i or trial.get("seed", -1) != int(part.request.seed) + i:
			return false
		var duration = trial.get("duration", -1)
		if not typeof(duration) in [TYPE_REAL, TYPE_INT] or is_nan(duration) or is_inf(duration) or duration < 0 or duration > 301:
			return false
		if not trial.get("outcome", "") in ["win", "loss", "horizon_reached", "safety_limit"]:
			return false
		if part.request.get("summary_only", false):
			continue
		if trial.get("sides", []).size() != 2:
			return false
		for side in trial.sides:
			for key in ["damage", "effective_heal", "overheal", "max_health", "armor"]:
				if side.get(key, []).size() != int(round(part.request.horizon / Statistics.STEP)) + 1:
					return false
				for value in side[key]:
					if typeof(value) != TYPE_REAL and typeof(value) != TYPE_INT:
						return false
					if is_nan(value) or is_inf(value):
						return false
	return true

func start(path, session, amount = 4, prewarm = true):
	executable = path
	directory = session
	for index in amount:
		var folder = session.plus_file("worker-" + str(index))
		Directory.new().make_dir_recursive(folder.plus_file("profile"))
		var inbox = folder.plus_file("inbox.json")
		Snapshot.write_json(inbox + ".alive", {"alive": true})
		# Each process needs its own log/config directory; the engine caches the
		# parent's user directory at startup, and children inherit this environment.
		var previous_appdata = OS.get_environment("APPDATA")
		var previous_local = OS.get_environment("LOCALAPPDATA")
		OS.set_environment("APPDATA", folder.plus_file("profile"))
		OS.set_environment("LOCALAPPDATA", folder.plus_file("profile"))
		var arguments = ["--no-window", "--audio-driver", "Dummy", "--fixed-fps", "60", "--lab-inbox=" + inbox, "--lab-heartbeat=" + inbox + ".alive"]
		if prewarm:
			arguments.append("--lab-warm=" + session.get_base_dir().plus_file("last-worker-input.json"))
		var pid = OS.execute(executable, arguments, false)
		OS.set_environment("APPDATA", previous_appdata)
		OS.set_environment("LOCALAPPDATA", previous_local)
		workers.append({"pid": pid, "inbox": inbox})

func heartbeat():
	if OS.get_ticks_msec() < heartbeat_at:
		return
	heartbeat_at = OS.get_ticks_msec() + 2000
	for worker in workers:
		Snapshot.write_json(worker.inbox + ".alive", {"alive": true})

func ready_count():
	var total = 0
	for worker in workers:
		if File.new().file_exists(worker.inbox + ".ready") and OS.is_process_running(worker.pid):
			total += 1
	return total

func submit(request, output):
	if is_same_pending(request):
		return active_job
	var job = {"id": request.id, "request": request, "output": output,
		"started": OS.get_ticks_msec(), "parts": [], "done": 0, "prefix": [], "finished": false}
	job["cache_key"] = request_key(request)
	active_job = job
	if request.get("preview_item", "") == "" and not request.get("summary_only", false):
		Snapshot.write_json(directory.get_base_dir().plus_file("last-worker-input.json"), request)
	for index in result_cache.size():
		if result_cache[index].sample_key == sample_key(request):
			var cached = result_cache[index]
			result_cache.remove(index)
			result_cache.push_front(cached)
			if cached.result.count >= request.runs:
				job["cached_result"] = cached.result
				return job
			job.prefix = cached.result.trials.duplicate(true)
			break
	var offset = job.prefix.size()
	var missing = int(request.runs) - offset
	var amount = min(workers.size(), missing)
	job.done = offset
	for index in amount:
		var part = request.duplicate(true)
		part.id = request.id + "-" + str(index)
		part.runs = missing / amount + (1 if index < missing % amount else 0)
		part.seed = int(request.seed) + offset
		var entry = {"id": part.id, "request": part, "output": output + ".part-" + str(index), "worker": index, "offset": offset, "result": null}
		offset += part.runs
		job.parts.append(entry)
		if not Snapshot.write_json(workers[index].inbox, entry):
			cancel(job)
			return null
	return job

func poll(job):
	if job.has("cached_result"):
		var trials = job.cached_result.trials.slice(0, int(job.request.runs) - 1, 1, true)
		var cached = Statistics.aggregate(trials, job.request.mode, job.request.horizon, job.request.get("summary_only", false))
		cached.id = job.id
		cached["status"] = "ok"
		cached["request"] = job.request
		cached["elapsed_ms"] = OS.get_ticks_msec() - job.started
		cached["cached"] = true
		cached["reused_runs"] = cached.count
		cached["computed_runs"] = 0
		job.done = cached.count
		job.finished = true
		Snapshot.write_json(job.output, cached)
		return cached
	var done = job.prefix.size()
	var all_done = true
	for part in job.parts:
		if part.result == null:
			var result = Snapshot.read_json(part.output)
			if typeof(result) == TYPE_DICTIONARY:
				if not validate_part(result, part):
					cancel(job)
					return {"status": "error", "message": result.get("message", "计算分片不完整")}
				part.result = result
			elif not OS.is_process_running(workers[part.worker].pid):
				cancel(job)
				return {"status": "error", "message": "计算进程退出，请重算"}
		if part.result != null:
			done += int(part.result.count)
		else:
			all_done = false
			var progress = Snapshot.read_json(part.output + ".progress")
			if typeof(progress) == TYPE_DICTIONARY:
				done += int(progress.done)
	job.done = done
	if not all_done:
		return null
	var trials = job.prefix.duplicate(true)
	for part in job.parts:
		for trial in part.result.trials:
			trial.index = trials.size()
			trials.append(trial)
	var combined = Statistics.aggregate(trials, job.request.mode, job.request.horizon, job.request.get("summary_only", false))
	combined["id"] = job.id
	combined["status"] = "ok"
	combined["request"] = job.request
	combined["elapsed_ms"] = OS.get_ticks_msec() - job.started
	combined["parallel_workers"] = job.parts.size()
	combined["reused_runs"] = job.prefix.size()
	combined["computed_runs"] = trials.size() - job.prefix.size()
	Snapshot.write_json(job.output, combined)
	job.finished = true
	remember(job, combined)
	return combined

func cancel(job):
	job.finished = true
	Snapshot.write_json(job.output + ".cancel", {"cancel": true})
	for part in job.parts:
		Snapshot.write_json(part.output + ".cancel", {"cancel": true})

func stop(force = false):
	var stopped = true
	if active_job != null:
		active_job.finished = true
	for worker in workers:
		Snapshot.write_json(worker.inbox + ".stop", {"stop": true})
		# Recovery must also work when a worker cannot service its inbox.
		# Only PIDs launched and tracked by this pool are eligible.
		if force and OS.is_process_running(worker.pid):
			stopped = OS.kill(worker.pid) == OK and stopped
	workers.clear()
	return stopped

func clear_cache():
	var stopped = stop(true)
	result_cache.clear()
	active_job = null
	return stopped
