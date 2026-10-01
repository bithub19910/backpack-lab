extends CanvasLayer

const Snapshot = preload("res://BackpackLab/Snapshot.gd")
const LabCurve = preload("res://BackpackLab/Curve.gd")
const ShopPreview = preload("res://BackpackLab/ShopPreview.gd")
var pool = preload("res://BackpackLab/Pool.gd").new()
var toolbar
var panel
var panel_style
var status
var horizon
var duration_label
var count
var opacity
var advanced
var statistics_panel
var details
var metrics_select
var chart
var recovery_chart
var eye_button
var dummy_button
var shop_map
var metric_category
var metric_action
var mode_results = {"dummy": null, "opponent": null}
var mode_bests = {"dummy": null, "opponent": null}
var best_output_value
var best_recovery_value
var precision_footer
var output_value
var recovery_value
var win_value
var result_caption
var opponents_button
var shop_buttons = []
var large_values = []
var post_panel
var post_value
var post_detail
var post_result = null
var panel_hidden = false
var rules = {}
var directory = ""
var session_dir = ""
var worker_pid = -1
var poll_at = 0
var preview = false
var mode = "dummy"
var job = null
var job_kind = "shop"
var last_result = null
var last_opponent = null
var pending_battle = null
var best = null
var round_id = ""
var current_fingerprint = ""
var request_fingerprint = ""
var selected_shop = -1
var request_shop_signature = ""

func _ready():
	layer = 110
	pause_mode = Node.PAUSE_MODE_PROCESS
	call_deferred("boot")

func boot():
	rules = Snapshot.read_json("res://BackpackLab/rules.json")
	directory = OS.get_user_data_dir().plus_file("backpack-lab")
	Directory.new().make_dir_recursive(directory)
	var opponent = Snapshot.read_json(directory.plus_file("last-opponent.json"))
	if typeof(opponent) == TYPE_DICTIONARY and Snapshot.same_game_rules(opponent.get("rules"), rules) and opponent.get("run") == run_key():
		last_opponent = opponent.board
	make_ui()
	Game.undoStack.connect("lab_layout_saved", self, "layout_saved")
	Game.undoStack.connect("lab_layout_restored", self, "layout_restored")
	Game.connect("switching_to_combat", self, "capture_opponent")
	Game.connect("combat_end", self, "commit_opponent")
	Game.connect("fresh_run_started", self, "new_run")
	Game.connect("shop_opened", self, "enter_shop")
	start_worker()
	if Game.state == Game.State.Shop:
		enter_shop()

func run_key():
	return str(Game.getNumStartedRuns()) + ":" + str(Game.curMode) + ":" + str(Game.curClass)

func round_key():
	return run_key() + ":" + str(Game.curRound)

func style(color, radius = 12):
	var box = StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	box.content_margin_left = 14
	box.content_margin_right = 14
	box.content_margin_top = 10
	box.content_margin_bottom = 10
	return box

func button(parent, text, method, args = []):
	var control = Button.new()
	control.text = text
	control.focus_mode = Control.FOCUS_NONE
	control.rect_min_size.y = 40
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.connect("pressed", self, method, args)
	parent.add_child(control)
	return control

func label(parent, text):
	var control = Label.new()
	control.text = text
	control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(control)
	return control

func container(parent, vertical = true):
	var box = VBoxContainer.new() if vertical else HBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_constant_override("separation", 12)
	parent.add_child(box)
	return box

func number_card(parent, title, color):
	var box = container(parent)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label(box, title).add_color_override("font_color", color)
	var value = label(box, "—")
	large_values.append(value)
	return value

func make_ui():
	toolbar = PanelContainer.new()
	toolbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toolbar.add_stylebox_override("panel", style(Color("152238"), 0))
	add_child(toolbar)
	var header = container(toolbar, false)
	var title = label(header, "背包实验室")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	eye_button = preload("res://BackpackLab/EyeButton.gd").new()
	eye_button.rect_min_size = Vector2(44, 38)
	eye_button.focus_mode = Control.FOCUS_NONE
	eye_button.collapsed = false
	eye_button.connect("pressed", self, "toggle_panel")
	header.add_child(eye_button)
	panel = PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel_style = style(Color(0.035, 0.055, 0.09, 0.85), 0)
	panel.add_stylebox_override("panel", panel_style)
	add_child(panel)
	var body = container(panel)
	var targets = container(body, false)
	var group = ButtonGroup.new()
	dummy_button = button(targets, "木桩对战", "calculate", ["dummy"])
	opponents_button = button(targets, "上一个对手对战", "calculate", ["opponent"])
	for control in [dummy_button, opponents_button]:
		control.toggle_mode = true
		control.group = group
	var numbers = container(body, false)
	output_value = number_card(numbers, "每秒输出", Color("ff8495"))
	recovery_value = number_card(numbers, "每秒回复", Color("63dec6"))
	win_value = number_card(numbers, "胜率", Color("e4cf93"))
	result_caption = label(body, "对战 15 秒 · 10 场均值")
	status = label(body, "后台准备中…")
	status.autowrap = true
	status.rect_min_size.y = 40
	var graphs = container(body, false)
	graphs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for kind in ["damage", "hps"]:
		var column = container(graphs)
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label(column, "输出曲线" if kind == "damage" else "回复曲线").add_color_override("font_color", Color("ff8495") if kind == "damage" else Color("63dec6"))
		var plot = LabCurve.new()
		plot.metric = kind
		plot.size_flags_vertical = Control.SIZE_EXPAND_FILL
		column.add_child(plot)
		if kind == "damage":
			chart = plot
		else:
			recovery_chart = plot
	var recalc_row = CenterContainer.new()
	recalc_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(recalc_row)
	var recalc = button(recalc_row, "重算", "recalculate")
	recalc.rect_min_size = Vector2(260, 48)
	recalc.add_stylebox_override("normal", style(Color("366d96"), 10))
	var secondary = container(body, false)
	var best_box = container(secondary)
	best_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	best_box.size_flags_stretch_ratio = 1
	label(best_box, "最佳摆盘")
	var best_rates = container(best_box, false)
	best_output_value = number_card(best_rates, "每秒输出", Color("ff8495"))
	best_recovery_value = number_card(best_rates, "每秒回复", Color("63dec6"))
	button(best_box, "恢复最佳摆盘", "restore_best").rect_min_size.y = 36
	shop_map = Control.new()
	shop_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shop_map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shop_map.size_flags_stretch_ratio = 1
	shop_map.rect_min_size = Vector2(0, 142)
	secondary.add_child(shop_map)
	var shop_title = label(shop_map, "商店预演")
	shop_title.rect_position = Vector2(8, 8)
	for i in 5:
		var offer = button(shop_map, "商品", "calculate_shop", [i])
		offer.rect_min_size.y = 36
		offer.clip_text = true
		shop_buttons.append(offer)
	shop_map.connect("resized", self, "layout_shop_buttons")
	var settings_row = container(body, false)
	button(settings_row, "设置", "toggle_advanced")
	button(settings_row, "详细统计", "toggle_statistics")
	button(settings_row, "保存曲线", "save_result")
	button(settings_row, "取消计算", "cancel")
	advanced = container(body)
	advanced.visible = false
	var controls = container(advanced, false)
	duration_label = label(controls, "对战时间 15 秒")
	horizon = HSlider.new()
	horizon.min_value = 1
	horizon.max_value = 60
	horizon.step = 1
	horizon.value = 15
	horizon.rect_min_size.x = 180
	horizon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_child(horizon)
	horizon.connect("value_changed", self, "duration_changed")
	label(controls, "次数")
	count = SpinBox.new()
	count.min_value = 1
	count.max_value = 100
	count.value = 10
	controls.add_child(count)
	var appearance = container(advanced, false)
	label(appearance, "不透明度")
	opacity = HSlider.new()
	opacity.min_value = 0.1
	opacity.max_value = 1.0
	opacity.step = 0.05
	opacity.value = 0.85
	opacity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	appearance.add_child(opacity)
	opacity.connect("value_changed", self, "opacity_changed")
	label(advanced, "图表空白处可直接购买 · 预演按首个空位放置")
	statistics_panel = container(body)
	statistics_panel.visible = false
	var filters = container(statistics_panel, false)
	metric_category = OptionButton.new()
	for category_title in ["战斗", "耐力", "状态"]:
		metric_category.add_item(category_title)
	metric_category.connect("item_selected", self, "change_metric_category")
	filters.add_child(metric_category)
	metrics_select = OptionButton.new()
	metrics_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	metrics_select.connect("item_selected", self, "show_metric")
	filters.add_child(metrics_select)
	metric_action = OptionButton.new()
	for entry in [["获得", 0], ["移除", 2], ["消耗", 4]]:
		metric_action.add_item(entry[0], entry[1])
	metric_action.connect("item_selected", self, "show_metric")
	filters.add_child(metric_action)
	change_metric_category(0)
	details = RichTextLabel.new()
	details.rect_min_size.y = 120
	details.selection_enabled = true
	statistics_panel.add_child(details)
	var precision = Snapshot.read_json("res://BackpackLab/precision.json")
	precision_footer = label(body, "空格重算/10次模拟计算误差约为%.1f%%" % precision.mean_error_percent)
	precision_footer.add_color_override("font_color", Color("93a6bf"))
	precision_footer.mouse_filter = Control.MOUSE_FILTER_PASS
	precision_footer.hint_tooltip = "默认15秒，6种历史阵容×2种模式，10次均值相对独立100次参考的平均偏差；只表示抽样波动，不是模拟器准确度或胜率误差。"
	post_panel = PanelContainer.new()
	post_panel.rect_position = Vector2(540, 22)
	post_panel.rect_size = Vector2(840, 145)
	post_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	post_panel.add_stylebox_override("panel", style(Color("142237"), 16))
	add_child(post_panel)
	var post_body = container(post_panel)
	post_value = label(post_body, "战后胜率 · 正在计算 25 场…")
	post_detail = label(post_body, "")
	post_panel.hide()
	var font = Game.PLAYER.nameLabel.get("custom_fonts/font").duplicate()
	if font:
		if font is DynamicFont:
			font.size = 18
			font.outline_size = 0
		var theme = Theme.new()
		theme.default_font = font
		for node in [toolbar, panel, post_panel]:
			node.theme = theme
		for state in ["normal", "hover", "pressed", "disabled"]:
			var tint = Color("24354c") if state == "normal" else Color("36516f")
			if state == "pressed":
				tint = Color("396487")
			if state == "disabled":
				tint = Color("192332")
			theme.set_stylebox(state, "Button", style(tint, 8))
		var big = font.duplicate()
		if big is DynamicFont:
			big.size = 36
		for value in large_values + [post_value]:
			value.add_font_override("font", big)
		var small_number = font.duplicate()
		if small_number is DynamicFont: small_number.size = 24
		for value in [best_output_value, best_recovery_value]:
			value.add_font_override("font", small_number)
	var preferences = Snapshot.read_json(directory.plus_file("preferences.json"))
	if typeof(preferences) == TYPE_DICTIONARY:
		opacity.value = clamp(preferences.get("opacity", 0.85), 0.1, 1.0)
		mode = preferences.get("mode", "dummy")
		if not mode in ["dummy", "opponent"]:
			mode = "dummy"
	opacity_changed(opacity.value)
	refresh_mode_buttons()
	layout_panel()

func save_preferences():
	Snapshot.write_json(directory.plus_file("preferences.json"), {"opacity": opacity.value, "mode": mode})

func opacity_changed(value):
	panel_style.bg_color.a = value
	for plot in [chart, recovery_chart]:
		plot.background_alpha = value
		plot.update()
	save_preferences()

func layout_panel():
	var viewport = get_viewport().get_visible_rect().size
	var width = min(730, viewport.x)
	toolbar.rect_position = Vector2(viewport.x - width, 0)
	toolbar.rect_size = Vector2(width, 58)
	panel.rect_position = Vector2(viewport.x - width, 58)
	panel.rect_size = Vector2(width, viewport.y - 58)

func layout_shop_buttons():
	# Match the native offer node positions, not the array order.
	var minimum = Vector2(INF, INF)
	var maximum = Vector2(-INF, -INF)
	for slot in Game.shopSceneNode.slots:
		minimum.x = min(minimum.x, slot.position.x)
		minimum.y = min(minimum.y, slot.position.y)
		maximum.x = max(maximum.x, slot.position.x)
		maximum.y = max(maximum.y, slot.position.y)
	var size = Vector2((shop_map.rect_size.x - 12) / 2, 36)
	for i in shop_buttons.size():
		var pos = Game.shopSceneNode.slots[i].position - minimum
		pos.x /= max(1, maximum.x - minimum.x)
		pos.y /= max(1, maximum.y - minimum.y)
		shop_buttons[i].rect_position = pos * (shop_map.rect_size - size)
		shop_buttons[i].rect_size = size

func toggle_panel():
	panel_hidden = not panel_hidden
	eye_button.collapsed = panel_hidden
	panel.visible = not panel_hidden and Game.state == Game.State.Shop

func toggle_advanced():
	advanced.visible = not advanced.visible
	if advanced.visible:
		statistics_panel.hide()
	layout_panel()

func toggle_statistics():
	statistics_panel.visible = not statistics_panel.visible
	if statistics_panel.visible:
		advanced.hide()
	layout_panel()

func duration_changed(value):
	duration_label.text = "对战时间 %.0f 秒" % value
	status.text = "设置已修改 · 点击按钮计算"

func enter_shop():
	# Title-screen mode/class can differ from the resumed run at boot.
	var opponent = Snapshot.read_json(directory.plus_file("last-opponent.json"))
	if typeof(opponent) == TYPE_DICTIONARY and Snapshot.same_game_rules(opponent.get("rules"), rules) and opponent.get("run") == run_key():
		last_opponent = opponent.board
	if job_kind == "post":
		cancel()
	post_panel.hide()
	post_result = null
	pending_battle = null
	if round_id != round_key():
		cancel()
		round_id = round_key()
		mode_bests = {"dummy": null, "opponent": null}
		mode_results = {"dummy": null, "opponent": null}
		current_fingerprint = ""
		selected_shop = -1
		for target in ["dummy", "opponent"]:
			Game.undoStack.manualSnapshots[slot_for_mode(target)] = null
			var record = Snapshot.read_json(directory.plus_file("best-" + target + ".json"))
			if typeof(record) == TYPE_DICTIONARY and record.get("round") == round_id and Snapshot.same(record.get("rules"), rules) and record.get("result", {}).get("request", {}).get("mode") == target:
				mode_bests[target] = record.result
				mode_results[target] = record.result
		show_mode_result()
	status.text = "点击计算 · 商店预演不消耗金币"

func start_worker():
	pool.stop()
	var executable = OS.get_executable_path().get_base_dir().plus_file("worker/BackpackLabWorker.exe")
	for argument in OS.get_cmdline_args():
		if argument.begins_with("--lab-worker="):
			executable = argument.trim_prefix("--lab-worker=")
	if not File.new().file_exists(executable):
		status.text = "计算组件缺失，请重新构建完整插件包。"
		return
	session_dir = directory.plus_file("session-" + str(OS.get_process_id()) + "-" + str(OS.get_ticks_msec()))
	Directory.new().make_dir_recursive(session_dir)
	pool.start(executable, session_dir, min(4, max(1, OS.get_processor_count() / 2)))
	worker_pid = pool.workers[0].pid

func _process(_delta):
	if toolbar == null or OS.get_ticks_msec() < poll_at:
		return
	poll_at = OS.get_ticks_msec() + 150
	var in_shop = Game.state == Game.State.Shop
	layout_panel()
	toolbar.visible = in_shop
	panel.visible = in_shop and not panel_hidden
	opponents_button.disabled = last_opponent == null
	pool.heartbeat()
	if in_shop:
		var offers = Game.shopSceneNode.getItems()
		for i in 5:
			shop_buttons[i].disabled = offers[i] == null
			var name = "空货架" if offers[i] == null else offers[i].getTranslatedName()
			shop_buttons[i].hint_tooltip = name
			shop_buttons[i].text = name
		if Game.draggedItem == null:
			var fingerprint = JSON.print(Snapshot.capture(Game.PLAYER)).sha256_text()
			if current_fingerprint != "" and fingerprint != current_fingerprint:
				if job_kind == "shop":
					cancel()
				status.text = "摆盘已变化 · 点击计算"
			current_fingerprint = fingerprint
		if job != null and job_kind == "shop" and selected_shop >= 0 and shop_signature(selected_shop) != request_shop_signature:
			cancel()
			status.text = "商店已刷新 · 点击重新预演"
	if job == null:
		return
	var data = pool.poll(job)
	if job_kind == "post":
		post_value.text = "战后胜率 · %d / 25 场" % job.done
	else:
		status.text = "正在计算 %d / %d 场…" % [job.done, job.request.runs]
	if typeof(data) == TYPE_DICTIONARY:
		var expected = job.id
		job = null
		if data.get("status") != "ok":
			if job_kind == "post":
				post_value.text = "战后计算未完成"
				post_detail.text = str(data.get("message", "请查看日志"))
			else:
				status.text = "计算失败：" + str(data.get("message", "未知错误"))
		elif data.get("id") == expected:
			if job_kind == "post" and post_panel.visible:
				post_result = data
				post_value.text = "战后胜率  %.0f%%" % (data.win_rate * 100) if data.win_rate != null else "战后胜率  —"
				var seconds = 0.0
				for trial in data.trials:
					seconds += trial.duration / data.count
				post_detail.text = "25 场  ·  %d 胜 / %d 负 / %d 未完成  ·  平均战斗 %.1f 秒  ·  计算 %.2f 秒" % [data.wins, data.losses, data.unresolved, seconds, data.elapsed_ms / 1000.0]
			elif job_kind == "shop" and current_fingerprint == request_fingerprint and data.request.mode == mode:
				accept_result(data)
	elif OS.get_ticks_msec() - job.started > 180000:
		cancel()
		status.text = "计算超时，请重试"
		if job_kind == "post":
			post_value.text = "战后计算超时"
			post_detail.text = "未显示不完整胜率"

func slot_for_mode(target):
	return 8 if target == "dummy" else 9

func refresh_mode_buttons():
	dummy_button.set_pressed_no_signal(mode == "dummy")
	opponents_button.set_pressed_no_signal(mode == "opponent")

func show_mode_result():
	best = mode_bests[mode]
	update_best_values()
	last_result = mode_results[mode]
	refresh_mode_buttons()
	if last_result != null:
		accept_result(last_result, false)
	else:
		for plot in [chart, recovery_chart]:
			plot.result = null
			plot.baseline = null
			plot.update()
		for value in [output_value, recovery_value, win_value]:
			value.text = "—"
		result_caption.text = "对战 %.0f 秒 · %d 场均值" % [horizon.value, count.value]
		details.text = ""

func calculate(new_mode):
	cancel()
	mode = new_mode
	selected_shop = -1
	save_preferences()
	show_mode_result()
	recalculate()

func calculate_shop(index):
	calculate_board(index)

func recalculate():
	# The primary action always evaluates the real current board, even after a preview.
	calculate_board(-1)

func shop_signature(index):
	var item = Game.shopSceneNode.getItems()[index]
	return "" if item == null else str(item.get_instance_id()) + ":" + JSON.print(item.getData())

func calculate_board(shop_index):
	if Game.state != Game.State.Shop or Game.draggedItem != null:
		return
	if mode == "opponent" and last_opponent == null:
		status.text = "尚无上一个对手"
		return
	cancel()
	selected_shop = shop_index
	var board = Snapshot.capture(Game.PLAYER)
	current_fingerprint = JSON.print(board).sha256_text()
	request_fingerprint = current_fingerprint
	var candidate = ""
	if selected_shop >= 0:
		var item = Game.shopSceneNode.getItems()[selected_shop]
		if item == null:
			status.text = "这个货架没有物品"
			return
		var location = ShopPreview.placement(item, Game.PLAYER.INVENTORY)
		if location == null:
			status.text = "没有足够的预留空位"
			return
		board.items.append(ShopPreview.row(item, location))
		candidate = item.getTranslatedName()
		request_shop_signature = shop_signature(selected_shop)
	var request = make_request(board, Snapshot.context(), int(count.value))
	request["preview_item"] = candidate
	submit(request, "shop")

func make_request(board, context, runs):
	var request = {"id": str(OS.get_ticks_usec()), "mode": mode, "player": board, "context": context,
		"seed": int((OS.get_ticks_usec() + OS.get_process_id()) % 2147483647), "runs": runs, "horizon": horizon.value, "rules": rules}
	if mode == "opponent":
		request["opponent"] = last_opponent
	return request

func submit(request, kind):
	var restart = pool.workers.empty()
	for worker in pool.workers:
		if not OS.is_process_running(worker.pid):
			restart = true
	if restart:
		start_worker()
	job_kind = kind
	job = pool.submit(request, session_dir.plus_file(request.id + ".json"))
	if job == null:
		status.text = "无法写入模拟请求"
		if kind == "post":
			post_value.text = "战后计算启动失败"
			post_detail.text = status.text
	else:
		status.text = "正在计算…"

func cancel():
	if job != null:
		pool.cancel(job)
		job = null

func capture_opponent():
	cancel()
	post_panel.hide()
	pending_battle = null
	if Game.curMode != Game.Mode.History and Game.OPPONENT != null:
		pending_battle = {"player": Snapshot.capture(Game.PLAYER), "opponent": Snapshot.capture(Game.OPPONENT), "context": Snapshot.context()}

func commit_opponent(_result):
	if pending_battle == null:
		return
	last_opponent = pending_battle.opponent
	Snapshot.write_json(directory.plus_file("last-opponent.json"), {"board": last_opponent, "run": run_key(), "rules": rules})
	cancel()
	var request = make_request(pending_battle.player, pending_battle.context, 25)
	request.mode = "opponent"
	request["opponent"] = pending_battle.opponent
	pending_battle = null
	post_result = null
	post_panel.show()
	post_value.text = "战后胜率 · 正在计算 25 场…"
	post_detail.text = "使用本场开战前的双方阵容"
	submit(request, "post")

func new_run():
	last_opponent = null
	pending_battle = null
	best = null
	mode_bests = {"dummy": null, "opponent": null}
	mode_results = {"dummy": null, "opponent": null}
	round_id = ""
	post_panel.hide()
	cancel()
	Snapshot.write_json(directory.plus_file("last-opponent.json"), {})
	for target in ["dummy", "opponent"]:
		Snapshot.write_json(directory.plus_file("best-" + target + ".json"), {})

func recovery(data):
	var own = data.sides[0]
	return own.effective_heal.back() + own.overheal.back() + own.max_health.back() + own.armor.back()

func score(data):
	return (data.sides[0].damage.back() + recovery(data)) / data.horizon

func accept_result(data, update_best = true):
	if data.request.mode != mode:
		return
	last_result = data
	mode_results[mode] = data
	best = mode_bests[mode]
	var save_failed = false
	if update_best and (best == null or score(data) > score(best)):
		best = data.duplicate(true)
		mode_bests[mode] = best
		var record = {"round": round_id, "rules": rules, "board": best.request.player, "context": best.request.context, "result": best}
		var written = Snapshot.write_json(directory.plus_file("best-" + mode + ".json"), record)
		written = Snapshot.write_json(directory.plus_file("slot-" + str(slot_for_mode(mode)) + ".json"), record) and written
		var state = state_for_board(best.request.player)
		Game.undoStack.manualSnapshots[slot_for_mode(mode)] = state
		save_failed = not written
	update_best_values()
	for plot in [chart, recovery_chart]:
		plot.result = data
		plot.baseline = best if best != null and best.id != data.id else null
		plot.update()
	output_value.text = "%.2f" % (data.sides[0].damage.back() / data.horizon)
	recovery_value.text = "%.2f" % (recovery(data) / data.horizon)
	win_value.text = "—" if data.win_rate == null else "%.0f%%" % (data.win_rate * 100)
	var target = "木桩" if data.request.mode == "dummy" else "上个对手"
	var candidate = data.request.get("preview_item", "")
	result_caption.text = "%s · 对战 %.0f 秒 · %d 场 · 耗时 %.2f 秒%s" % [target, data.horizon, data.count, data.elapsed_ms / 1000.0, " · 预购" if candidate != "" else ""]
	status.text = "计算完成"
	if candidate != "":
		var cell = data.request.player.items.back().cell
		status.text = "预购 %s · 第 %d 列，第 %d 行" % [candidate, cell[0] + 1, cell[1] + 1]
	if save_failed:
		status.text = "最佳摆盘写入磁盘失败"
	show_metric(metrics_select.selected)

func update_best_values():
	best_output_value.text = "—" if best == null else "%.2f" % (best.sides[0].damage.back() / best.horizon)
	best_recovery_value.text = "—" if best == null else "%.2f" % (recovery(best) / best.horizon)

func state_for_board(board):
	# Native snapshots restore only existing owned objects. Match all items before
	# changing anything, including persisted slot 9 and hypothetical purchases.
	var candidates = Game.PLAYER.INVENTORY.getItems().duplicate() + Game.STORAGEBOX.getItems().duplicate()
	var selected = []
	for row in board.items:
		var match_item = null
		for item in candidates:
			if item.getName() != row.id or not Snapshot.same(item.getData(), row.get("data")):
				continue
			var gems = ShopPreview.row(item, {"cell": [0, 0], "face": 0}).gems
			if not Snapshot.same(gems, row.get("gems", [])):
				continue
			match_item = item
			break
		if match_item == null:
			return null
		candidates.erase(match_item)
		selected.append(match_item)
	var state = Game.undoStack.lab_capture_snapshot()
	state.bags.clear()
	state.items.clear()
	state.editMode = Game.InventoryEditMode.Default
	for i in selected.size():
		var item = selected[i]
		var row = board.items[i]
		var positions = state.bags if item.isBag() else state.items
		positions[item] = [Vector2(row.cell[0], row.cell[1]), int(row.face)]
		state.storageItems.erase(item)
	return state

func restore_best(target = ""):
	if Game.state != Game.State.Shop or Game.draggedItem != null or InputBlocker.isActive():
		return
	if target == "":
		target = mode
	var record = mode_bests[target]
	if record == null or round_id != round_key():
		status.text = "本回合还没有最佳摆盘"
		return
	var state = state_for_board(record.request.player)
	if state == null:
		status.text = "尚未拥有所需物品，或物品已合成 / 出售"
		return
	cancel()
	var slot = slot_for_mode(target)
	Game.undoStack.manualSnapshots[slot] = state
	Game.undoStack.restoreSnapshop(slot)
	current_fingerprint = JSON.print(Snapshot.capture(Game.PLAYER)).sha256_text()
	status.text = "已恢复最佳摆盘 · 空格重算"

func _input(event):
	if not event is InputEventKey or Game.state != Game.State.Shop or panel == null:
		return
	if InputBlocker.isActive() or Game.draggedItem != null:
		return
	var focus = panel.get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if event.scancode == KEY_SPACE and not event.alt and not event.control and not event.meta:
		get_tree().set_input_as_handled()
		if event.pressed and not event.echo:
			recalculate()
	elif event.pressed and not event.echo and event.alt and event.scancode in [KEY_8, KEY_9]:
		restore_best("dummy" if event.scancode == KEY_8 else "opponent")
		get_tree().set_input_as_handled()

func layout_saved(slot):
	if slot in [8, 9]:
		var record = mode_bests["dummy" if slot == 8 else "opponent"]
		Game.undoStack.manualSnapshots[slot] = state_for_board(record.request.player) if record != null else null
		return
	var board = Snapshot.capture(Game.PLAYER)
	var result = null
	if last_result != null and Snapshot.same(last_result.request.player, board) and Snapshot.same(last_result.request.context, Snapshot.context()):
		result = last_result
	Snapshot.write_json(directory.plus_file("slot-" + str(slot) + ".json"), {"rules": rules, "board": board, "context": Snapshot.context(), "result": result})

func layout_restored(_slot):
	cancel()
	status.text = "摆盘已恢复 · 点击计算"

func save_result():
	if last_result == null:
		return
	var written = Snapshot.write_json(directory.plus_file("curve-" + last_result.id + ".json"), last_result)
	status.text = "曲线已保存" if written else "保存失败，请检查剩余磁盘空间"

func change_metric_category(index):
	metric_category.select(index)
	metrics_select.clear()
	metric_action.visible = index == 2
	if index == 0:
		for entry in [[0, "输出"], [3, "未命中"], [4, "触发次数"], [5, "格挡伤害"], [7, "耐力不足"]]:
			metrics_select.add_item(entry[1], entry[0])
	elif index == 1:
		for entry in [[8, "获得"], [10, "移除"], [12, "消耗"]]:
			metrics_select.add_item(entry[1], entry[0])
	else:
		var stacks = ["幸运", "再生", "吸血", "尖刺", "法力", "力量", "热量", "中毒", "致盲", "寒冷"]
		for i in stacks.size():
			metrics_select.add_item(stacks[i], i + 1)
	metrics_select.select(0)
	metric_action.select(0)
	if details != null:
		show_metric(0)

func metric_name(_index):
	var name = metric_category.get_item_text(metric_category.selected) + " / " + metrics_select.get_item_text(metrics_select.selected)
	if metric_action.visible:
		name += " / " + metric_action.get_item_text(metric_action.selected)
	return name

func show_metric(_selection):
	var index = metrics_select.get_item_id(metrics_select.selected)
	if metric_category.selected == 2:
		index = 14 + metric_action.get_item_id(metric_action.selected) * 11 + index
	if last_result == null:
		return
	var totals = {}
	var labels = {}
	for trial in last_result.trials:
		for row in trial.sides[0].metrics[index]:
			if row.get("owner_side", 0) != 0:
				continue
			var key = row.get("key", row.source)
			totals[key] = totals.get(key, 0.0) + row.value / last_result.count
			var name = ItemBook.items[row.source].getTranslatedName() if ItemBook.items.has(row.source) else str(row.source)
			if row.has("cell"):
				name += " [%d,%d]" % [row.cell[0] + 1, row.cell[1] + 1]
			labels[key] = name
	details.text = "各来源每场平均 · " + metric_name(index) + "\n"
	for key in totals:
		details.text += "%s：%.2f\n" % [labels[key], totals[key]]
	if totals.empty():
		details.text += "本次没有记录。"

func _exit_tree():
	pool.stop()
