extends Reference

const Snapshot = preload("res://BackpackLab/Snapshot.gd")
const Statistics = preload("res://BackpackLab/Statistics.gd")
var workers = []
var executable = ""
var directory = ""
var heartbeat_at = 0

func start(path, session, amount = 4):
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
		var pid = OS.execute(executable, ["--no-window", "--audio-driver", "Dummy", "--fixed-fps", "60", "--lab-inbox=" + inbox, "--lab-heartbeat=" + inbox + ".alive"], false)
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
	var job = {"id": request.id, "request": request, "output": output,
		"started": OS.get_ticks_msec(), "parts": [], "done": 0}
	var amount = min(workers.size(), int(request.runs))
	var offset = 0
	for index in amount:
		var part = request.duplicate(true)
		part.id = request.id + "-" + str(index)
		part.runs = int(request.runs) / amount + (1 if index < int(request.runs) % amount else 0)
		part.seed = int(request.seed) + offset
		var entry = {"id": part.id, "request": part, "output": output + ".part-" + str(index), "worker": index, "offset": offset, "result": null}
		offset += part.runs
		job.parts.append(entry)
		if not Snapshot.write_json(workers[index].inbox, entry):
			cancel(job)
			return null
	return job

func poll(job):
	var done = 0
	var all_done = true
	for part in job.parts:
		if part.result == null:
			var result = Snapshot.read_json(part.output)
			if typeof(result) == TYPE_DICTIONARY:
				if result.get("status") != "ok" or result.get("id") != part.id or result.get("count") != part.request.runs:
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
	var trials = []
	for part in job.parts:
		for trial in part.result.trials:
			trial.index = trials.size()
			trials.append(trial)
	var combined = Statistics.aggregate(trials, job.request.mode, job.request.horizon)
	combined["id"] = job.id
	combined["status"] = "ok"
	combined["request"] = job.request
	combined["elapsed_ms"] = OS.get_ticks_msec() - job.started
	combined["parallel_workers"] = job.parts.size()
	Snapshot.write_json(job.output, combined)
	return combined

func cancel(job):
	Snapshot.write_json(job.output + ".cancel", {"cancel": true})
	for part in job.parts:
		Snapshot.write_json(part.output + ".cancel", {"cancel": true})

func stop():
	for worker in workers:
		Snapshot.write_json(worker.inbox + ".stop", {"stop": true})
	workers.clear()
