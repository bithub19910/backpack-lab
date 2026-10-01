extends Reference

const STEP = 0.1

# Approximate two-sided Student-t mean intervals. These describe sampling
# variability, not agreement with the real game or unobserved rare outcomes.
static func mean_interval(values):
	var n = values.size()
	if n < 2:
		return {"count": n, "relative": null, "half_width": null}
	var average = 0.0
	for value in values:
		average += value / n
	var squares = 0.0
	for value in values:
		squares += pow(value - average, 2)
	var df = n - 1
	var critical = [0.0, 12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262,
		2.228, 2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
		2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042]
	var t = critical[df] if df <= 30 else (2.042 if df < 60 else 2.001)
	var half = t * sqrt(squares / df / n)
	return {"count": n, "mean": average, "half_width": half,
		"relative": half / abs(average) if abs(average) > 0.000001 else null}

static func sampling_uncertainty(data):
	var output = []
	var recovery = []
	for trial in data.trials:
		var own = trial.sides[0]
		output.append(own.damage.back() / data.horizon)
		recovery.append((own.effective_heal.back() + own.overheal.back() + own.max_health.back() + own.armor.back()) / data.horizon)
	return {"output": mean_interval(output), "recovery": mean_interval(recovery)}

static func wilson(wins, count):
	if count <= 0:
		return null
	var p = float(wins) / count
	var z2 = 3.8414588206941254
	var divisor = 1.0 + z2 / count
	var center = (p + z2 / (2 * count)) / divisor
	var half = 1.959963984540054 * sqrt(p * (1 - p) / count + z2 / (4 * count * count)) / divisor
	return [max(0.0, center - half), min(1.0, center + half)]

static func metric_curve(logger, metric, horizon, positive_only = false):
	var count = int(round(horizon / STEP)) + 1
	var bins = []
	bins.resize(count)
	bins.fill(0.0)
	for history in logger.getStatHistoriesForMetric(metric).values():
		var previous = 0.0
		for j in history.values.size():
			var value = float(history.values[j])
			var delta = value - previous
			previous = value
			var event = int(history.eventNumbers[j])
			var t = Game.combatLog.getTimeOfEvent(event) if event < Game.combatLog.events.size() else Game.combatTimer.combatTime
			var index = int(ceil(max(0.0, t) / STEP - 0.00001))
			if index < count:
				bins[index] += max(0.0, delta) if positive_only else delta
	for i in range(1, count):
		bins[i] += bins[i - 1]
	return bins

static func extract(horizon):
	var output = []
	for side in 2:
		var logger = Game.combatLog.statLoggers[side]
		var damage = metric_curve(logger, Game.ItemMetrics.Damage, horizon)
		var heal = metric_curve(logger, Game.ItemMetrics.Heal, horizon)
		var over = metric_curve(logger, Game.ItemMetrics.Overheal, horizon)
		var health = metric_curve(logger, Game.ItemMetrics.MaxHealth, horizon, true)
		var armor_metric = Item.getStackMetricIndex(Item.StackChangeType.Added_Player + side, Game.EventType.Block)
		var armor = metric_curve(logger, armor_metric, horizon, true)
		var effective = []
		for i in heal.size():
			effective.append(max(0.0, heal[i] - over[i]))
		var totals = []
		for metric in Item.getNumItemMetrics():
			var sources = []
			var histories = logger.getStatHistoriesForMetric(metric)
			for source in histories:
				var value = histories[source].values.back()
				if value != 0:
					var label = source.getName() if source is Item else Game.eventTypeKeys[source]
					var entry = {"source": label, "key": "effect:" + label, "value": value}
					if source is Item:
						entry["key"] = source.get_meta("lab_source_key") if source.has_meta("lab_source_key") else label + ":" + str(source.getTopLeftCell())
						entry["cell"] = source.get_meta("lab_cell") if source.has_meta("lab_cell") else [source.getTopLeftCell().x, source.getTopLeftCell().y]
						entry["owner_side"] = source.character().playerId
					sources.append(entry)
			totals.append(sources)
		output.append({"damage": damage, "effective_heal": effective, "overheal": over,
			"max_health": health, "armor": armor, "metrics": totals})
	return output

static func aggregate(trials, mode, horizon, summary_only = false):
	var wins = 0
	var losses = 0
	var unresolved = 0
	var sides = []
	for side in (0 if summary_only else 2):
		var combined = {}
		for key in ["damage", "effective_heal", "overheal", "max_health", "armor"]:
			var values = []
			values.resize(int(round(horizon / STEP)) + 1)
			values.fill(0.0)
			for trial in trials:
				for i in values.size():
					values[i] += trial.sides[side][key][i] / trials.size()
			combined[key] = values
		sides.append(combined)
	for trial in trials:
		if trial.outcome == "win":
			wins += 1
		elif trial.outcome == "loss":
			losses += 1
		elif trial.outcome != "horizon_reached":
			unresolved += 1
	return {"count": trials.size(), "wins": wins, "losses": losses, "unresolved": unresolved,
		"win_rate": float(wins) / trials.size() if mode == "opponent" and unresolved == 0 else null,
		"interval95": wilson(wins, trials.size()) if mode == "opponent" and unresolved == 0 else null,
		"sides": sides, "step": STEP, "horizon": horizon, "trials": trials}
