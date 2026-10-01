extends Control

var result = null
var baseline = null
var background_alpha = 0.85
var palette = [Color("ff777e"), Color("52d3b1"), Color("62baff"), Color("f2c563"), Color("b39cff"), Color("bac8db")]
var metric = "damage"

func _ready():
	rect_min_size = Vector2(280, 230)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func points_for(data, key):
	var values = data.sides[0].get(key, [])
	if key == "hps":
		values = []
		for i in data.sides[0].effective_heal.size():
			values.append(data.sides[0].effective_heal[i] + data.sides[0].overheal[i] + data.sides[0].max_health[i] + data.sides[0].armor[i])
	# Histories already store the exact cumulative sum of native event amounts.
	# Integrating sampled per-second values would add discretization error.
	return values

func _draw():
	var font = get_font("font")
	draw_rect(Rect2(Vector2.ZERO, rect_size), Color(0.025, 0.045, 0.075, background_alpha))
	if result == null:
		draw_string(font, Vector2(24, 42), "等待计算", Color("bac8db"))
		return
	var keys = [metric]
	var lines = []
	var maximum = 1.0
	for key in keys:
		# HPS is a derived sum and has no stored array.
		var series = points_for(result, key)
		lines.append(series)
		for value in series:
			maximum = max(maximum, value)
	var base_lines = []
	if baseline != null:
		for key in [metric]:
			var series = points_for(baseline, key)
			base_lines.append(series)
			for value in series:
				maximum = max(maximum, value)
	maximum *= 1.1
	var time_max = max(result.horizon, baseline.horizon if baseline != null else result.horizon)
	var area = Rect2(48, 24, rect_size.x - 66, rect_size.y - 67)
	for j in 5:
		var y = area.end.y - area.size.y * j / 4.0
		draw_line(Vector2(area.position.x, y), Vector2(area.end.x, y), Color("2b3545"))
		var tick = ("%.1f" if maximum < 5 else "%.0f") % (maximum * j / 4.0)
		draw_string(font, Vector2(3, y + 4), tick, Color("8d9cae"))
	for j in 4:
		var x = area.position.x + area.size.x * j / 3.0
		var tick = "%.0fs" % (time_max * j / 3.0)
		var left = clamp(x - font.get_string_size(tick).x / 2, 0, rect_size.x - font.get_string_size(tick).x - 4)
		draw_string(font, Vector2(left, area.end.y + 22), tick, Color("8d9cae"))
	for pass_index in 2:
		var group = base_lines if pass_index == 0 else lines
		for j in group.size():
			var points = PoolVector2Array()
			for i in group[j].size():
				points.append(Vector2(area.position.x + area.size.x * i * result.step / time_max, area.end.y - area.size.y * group[j][i] / maximum))
			var color = palette[0 if metric == "damage" else 1]
			if pass_index == 0:
				color.a = 0.35
			draw_polyline(points, color, 2.0, true)
