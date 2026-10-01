extends CanvasLayer

const Snapshot = preload("res://BackpackLab/Snapshot.gd")
const LabCurve = preload("res://BackpackLab/Curve.gd")
const ShopPreview = preload("res://BackpackLab/ShopPreview.gd")
# Stable sample batch for comparisons; this is not the live match's seed.
const COMPARISON_SEED = 1280266059
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
var best_records = {"dummy": {}, "opponent": {}}
var preview_result = null
var queued_preview = null
var round_id = ""
var current_fingerprint = ""
var request_fingerprint = ""
var selected_shop = -1
var request_shop_signature = ""
var graphs
var settings_row
var clear_cache_button
var main_body
var tail_scroll
var shop_title
var post_eye
var post_show = true
var post_ended = false
var post_manual_reveal = false
var opponent_saved = false

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
	main_body = body
	body.add_constant_override("separation", 16)
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
	graphs = container(body, false)
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
	tail_scroll = ScrollContainer.new()
	tail_scroll.scroll_horizontal_enabled = false
	tail_scroll.rect_min_size.y = 224
	tail_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	body.add_child(tail_scroll)
	var tail = container(tail_scroll)
	tail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tail.add_constant_override("separation", 16)
	var secondary = container(tail, false)
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
	shop_title = label(shop_map, "商店预演")
	shop_title.rect_position = Vector2(0, 6)
	for i in 5:
		var offer = button(shop_map, "商品", "calculate_shop", [i])
		offer.rect_min_size.y = 36
		offer.clip_text = true
		shop_buttons.append(offer)
	shop_map.connect("resized", self, "layout_shop_buttons")
	var settings_margin = MarginContainer.new()
	settings_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	settings_margin.add_constant_override("margin_top", 14)
	settings_margin.add_constant_override("margin_bottom", 6)
	tail.add_child(settings_margin)
	settings_row = container(settings_margin, false)
	button(settings_row, "设置", "toggle_advanced")
	button(settings_row, "详细统计", "toggle_statistics")
	button(settings_row, "保存曲线", "save_result")
	button(settings_row, "取消计算", "cancel")
	advanced = container(tail)
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
	clear_cache_button = button(appearance, "清除所有缓存", "clear_all_caches")
	clear_cache_button.hint_tooltip = "清除计算结果、最佳成绩与预热缓存，重启计算组件。保留当前背包、手动保存的曲线、设置和上个对手。"
	label(advanced, "图表空白处可直接购买 · 预演按首个空位放置")
	statistics_panel = container(tail)
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
	precision_footer = label(body, "空格重算 / 10次模拟")
	precision_footer.add_color_override("font_color", Color("93a6bf"))
	precision_footer.mouse_filter = Control.MOUSE_FILTER_PASS
	precision_footer.hint_tooltip = ""
	post_panel = PanelContainer.new()
	post_panel.rect_position = Vector2(16, 16)
	post_panel.rect_size = Vector2(490, 54)
	post_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	post_panel.add_stylebox_override("panel", style(Color("142237"), 16))
	add_child(post_panel)
	var post_body = container(post_panel)
	var post_header = container(post_body, false)
	post_value = label(post_header, "本场胜率 · 计算中")
	post_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	post_eye = preload("res://BackpackLab/EyeButton.gd").new()
	post_eye.rect_min_size = Vector2(32, 28)
	post_eye.focus_mode = Control.FOCUS_NONE
	post_eye.connect("pressed", self, "toggle_post")
	post_header.add_child(post_eye)
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
		for value in large_values:
			value.add_font_override("font", big)
		var small_number = font.duplicate()
		if small_number is DynamicFont: small_number.size = 24
		for value in [best_output_value, best_recovery_value]:
			value.add_font_override("font", small_number)
		var post_font = font.duplicate()
		if post_font is DynamicFont: post_font.size = 16
		post_value.add_font_override("font", post_font)
		post_detail.add_font_override("font", post_font)
	var preferences = Snapshot.read_json(directory.plus_file("preferences.json"))
	if typeof(preferences) == TYPE_DICTIONARY:
		post_show = preferences.get("post_show", true)
		opacity.value = clamp(preferences.get("opacity", 0.85), 0.1, 1.0)
		mode = preferences.get("mode", "dummy")
		if not mode in ["dummy", "opponent"]:
			mode = "dummy"
	opacity_changed(opacity.value)
	refresh_mode_buttons()
	layout_panel()

func save_preferences():
	Snapshot.write_json(directory.plus_file("preferences.json"), {"opacity": opacity.value, "mode": mode, "post_show": post_show})

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
	if tail_scroll != null:
		var desired = 224.0
		if advanced.visible: desired += advanced.get_combined_minimum_size().y + 16
		if statistics_panel.visible: desired += statistics_panel.get_combined_minimum_size().y + 16
		var other_minimum = main_body.get_combined_minimum_size().y - tail_scroll.rect_min_size.y
		tail_scroll.rect_min_size.y = min(desired, max(160, viewport.y - 58 - 20 - other_minimum))

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
		shop_buttons[i].rect_position = Vector2(round(pos.x) * (size.x + 12), round(pos.y * 2) * 48)
		shop_buttons[i].rect_size = size
	shop_title.rect_position = Vector2(0, (36 - shop_title.rect_size.y) / 2)

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

func comparison_key(request):
	var conditions = request.duplicate(true)
	for key in ["id", "player", "preview_item"]:
		conditions.erase(key)
	return JSON.print(conditions).sha256_text()

func comparable(a, b):
	return a != null and b != null and comparison_key(a.request) == comparison_key(b.request)

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
		best_records = {"dummy": {}, "opponent": {}}
		mode_results = {"dummy": null, "opponent": null}
		current_fingerprint = ""
		selected_shop = -1
		for target in ["dummy", "opponent"]:
			Game.undoStack.manualSnapshots[slot_for_mode(target)] = null
			var record = Snapshot.read_json(directory.plus_file("best-" + target + ".json"))
			if typeof(record) == TYPE_DICTIONARY and record.get("round") == round_id and Snapshot.same(record.get("rules"), rules) and record.get("result", {}).get("request", {}).get("mode") == target:
				best_records[target] = record.get("comparisons", {})
				if record.result.request.get("preview_item", "") == "":
					best_records[target][comparison_key(record.result.request)] = record.result
					mode_bests[target] = record.result
					mode_results[target] = record.result
		show_mode_result()
	status.text = "点击计算 · 商店预演不消耗金币"

func start_worker(prewarm = true):
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
	pool.start(executable, session_dir, min(4, max(1, OS.get_processor_count() / 2)), prewarm)
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
		post_value.text = "本场胜率 · 计算中"
	else:
		status.text = "正在计算 %d / %d 场…" % [job.done, job.request.runs]
	if typeof(data) == TYPE_DICTIONARY:
		var expected = job.id
		job = null
		if data.get("status") != "ok":
			if job_kind == "post":
				post_value.text = "本场胜率 · 未完成"
				post_detail.text = str(data.get("message", "请查看日志"))
				post_detail.show()
			else:
				status.text = "计算失败：" + str(data.get("message", "未知错误"))
		elif data.get("id") == expected:
			if job_kind == "post" and post_panel.visible:
				post_result = data
				refresh_post()
			elif job_kind == "shop" and current_fingerprint == request_fingerprint and data.request.mode == mode:
				accept_result(data)
				if queued_preview != null:
					var next = queued_preview
					queued_preview = null
					submit(next, "shop")
	elif OS.get_ticks_msec() - job.started > 180000:
		cancel()
		status.text = "计算超时，请重试"
		if job_kind == "post":
			post_value.text = "本场胜率 · 计算超时"
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
		precision_footer.text = "空格重算 / 10次模拟"
		details.text = ""

func calculate(new_mode):
	if mode != new_mode:
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
	if job != null and job_kind == "shop" and (pool.is_same_pending(request) or (queued_preview != null and pool.request_key(queued_preview) == pool.request_key(request))):
		return
	cancel()
	if candidate != "":
		var current = mode_results[mode]
		var actual = Snapshot.capture(Game.PLAYER)
		if current == null or not Snapshot.same(current.request.player, actual) or comparison_key(current.request) != comparison_key(request):
			queued_preview = request
			var base = make_request(actual, Snapshot.context(), int(count.value))
			base["preview_item"] = ""
			submit(base, "shop")
			return
	submit(request, "shop")

func make_request(board, context, runs):
	var request = {"id": str(OS.get_ticks_usec()), "mode": mode, "player": board, "context": context,
		"seed": COMPARISON_SEED, "runs": runs, "horizon": horizon.value, "rules": rules}
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
			post_value.text = "本场胜率计算启动失败"
			post_detail.text = status.text
	else:
		status.text = "正在计算…"

func cancel():
	queued_preview = null
	if job != null:
		pool.cancel(job)
		job = null

func clear_all_caches():
	cancel()
	var cleared = pool.clear_cache()
	# Delete only derived recovery state, never saves, opponent snapshots,
	# preferences, manually exported curves or session logs used for diagnosis.
	var cache_dir = Directory.new()
	for name in ["last-worker-input.json", "best-dummy.json", "best-opponent.json", "slot-8.json", "slot-9.json"]:
		for suffix in ["", ".bak", ".tmp"]:
			var path = directory.plus_file(name + suffix)
			if File.new().file_exists(path):
				cleared = cache_dir.remove(path) == OK and cleared
	mode_results = {"dummy": null, "opponent": null}
	mode_bests = {"dummy": null, "opponent": null}
	best_records = {"dummy": {}, "opponent": {}}
	preview_result = null
	post_result = null
	pending_battle = null
	post_panel.hide()
	selected_shop = -1
	request_shop_signature = ""
	current_fingerprint = ""
	request_fingerprint = ""
	job_kind = "shop"
	for slot in [8, 9]:
		Game.undoStack.manualSnapshots[slot] = null
	show_mode_result()
	# Bypass prewarming even if a locked disk cache could not be removed.
	start_worker(false)
	if pool.workers.empty():
		return
	status.text = "缓存已清除 · 点击重算" if cleared else "计算缓存已重置，部分缓存未清除 · 可再次尝试"

func capture_opponent():
	cancel()
	post_panel.hide()
	pending_battle = null
	if Game.curMode != Game.Mode.History and Game.OPPONENT != null:
		pending_battle = {"player": Snapshot.capture(Game.PLAYER), "opponent": Snapshot.capture(Game.OPPONENT), "context": Snapshot.context()}
	if pending_battle == null:
		return
	last_opponent = pending_battle.opponent
	opponent_saved = Snapshot.write_json(directory.plus_file("last-opponent.json"), {"board": last_opponent, "run": run_key(), "rules": rules})
	var request = make_request(pending_battle.player, pending_battle.context, 25)
	request.mode = "opponent"
	request["summary_only"] = true
	request["opponent"] = pending_battle.opponent
	post_result = null
	post_ended = false
	post_manual_reveal = false
	post_panel.show()
	submit(request, "post")
	refresh_post()

func commit_opponent(_result):
	if pending_battle == null:
		return
	post_ended = true
	refresh_post()

func toggle_post():
	var showing = post_show and (post_ended or post_manual_reveal)
	post_show = not showing
	post_manual_reveal = post_show
	save_preferences()
	refresh_post()

func refresh_post():
	var reveal = post_show and (post_ended or post_manual_reveal)
	post_eye.collapsed = not reveal
	post_eye.hint_tooltip = "隐藏结果" if reveal else "显示结果"
	post_detail.visible = reveal and post_result != null
	post_value.text = "本场胜率 · 计算中" if post_result == null else "本场胜率"
	if reveal and post_result != null:
		var seconds = 0.0
		for trial in post_result.trials:
			seconds += trial.duration / post_result.count
		post_value.text += "  %.0f%%" % (post_result.win_rate * 100) if post_result.win_rate != null else "  —"
		post_detail.text = "25 场 · %d 胜 / %d 负 · 平均战斗 %.1f 秒\n%s" % [post_result.wins, post_result.losses, seconds, "对手阵容已保存" if opponent_saved else "对手阵容保存失败"]
	post_panel.rect_size = Vector2(490, 0)

func new_run():
	last_opponent = null
	pending_battle = null
	best = null
	mode_bests = {"dummy": null, "opponent": null}
	best_records = {"dummy": {}, "opponent": {}}
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

func metric_rows(data, index):
	if data.has("metric_averages"):
		return data.metric_averages[index]
	var combined = {}
	for trial in data.trials:
		for row in trial.sides[0].metrics[index]:
			if row.get("owner_side", 0) != 0:
				continue
			var key = row.get("key", row.source)
			if not combined.has(key):
				combined[key] = row.duplicate(true)
				combined[key].value = 0.0
			combined[key].value += row.value / data.count
	return combined.values()

func compact_best(data):
	# Best records need mean curves and source statistics, not every trial's curves.
	var saved = data.duplicate(false)
	saved["metric_averages"] = []
	for index in Item.getNumItemMetrics():
		saved.metric_averages.append(metric_rows(data, index))
	saved["trials"] = []
	return saved.duplicate(true)

func accept_result(data, update_best = true):
	if data.request.mode != mode:
		return
	var candidate = data.request.get("preview_item", "")
	var previous = mode_results[mode]
	last_result = data
	if candidate == "":
		mode_results[mode] = data
		preview_result = null
	else:
		preview_result = data
	var key = comparison_key(data.request)
	if mode_bests[mode] != null and comparable(data, mode_bests[mode]) and mode_bests[mode].request.get("preview_item", "") == "":
		best_records[mode][key] = mode_bests[mode]
	best = best_records[mode].get(key)
	var save_failed = false
	if candidate == "" and update_best and (best == null or score(data) > score(best)):
		best = compact_best(data)
		best_records[mode][key] = best
		# Bound history without changing the selected condition's winner.
		while best_records[mode].size() > 16:
			best_records[mode].erase(best_records[mode].keys()[0])
	if candidate == "" and update_best and best != null:
		var history = best_records[mode].duplicate(false)
		history.erase(key)
		var record = {"round": round_id, "rules": rules, "board": best.request.player, "context": best.request.context, "result": best, "comparisons": history}
		var written = Snapshot.write_json(directory.plus_file("best-" + mode + ".json"), record)
		written = Snapshot.write_json(directory.plus_file("slot-" + str(slot_for_mode(mode)) + ".json"), record) and written
		Game.undoStack.manualSnapshots[slot_for_mode(mode)] = state_for_board(best.request.player)
		save_failed = not written
	if candidate == "":
		mode_bests[mode] = best
	update_best_values()
	for plot in [chart, recovery_chart]:
		plot.result = data
		plot.baseline = previous if candidate != "" and comparable(data, previous) else (best if best != null and best.id != data.id else null)
		plot.update()
	output_value.text = "%.2f" % (data.sides[0].damage.back() / data.horizon)
	recovery_value.text = "%.2f" % (recovery(data) / data.horizon)
	win_value.text = "—" if data.win_rate == null else "%.0f%%" % (data.win_rate * 100)
	var target = "木桩" if data.request.mode == "dummy" else "上个对手"
	result_caption.text = "%s · 对战 %.0f 秒 · %d 场 · 耗时 %.2f 秒%s" % [target, data.horizon, data.count, data.elapsed_ms / 1000.0, " · 预购" if candidate != "" else ""]
	if comparable(data, previous):
		result_caption.text += "\n%s：输出 %+.2f / 秒 · 回复 %+.2f / 秒" % ["较当前" if candidate != "" else "较上次", (data.sides[0].damage.back() - previous.sides[0].damage.back()) / data.horizon, (recovery(data) - recovery(previous)) / data.horizon]
	status.text = "阵容未变，已复用结果" if data.get("cached", false) else "计算完成"
	if data.get("reused_runs", 0) > 0 and not data.get("cached", false):
		status.text = "计算完成 · 复用 %d 场，追加 %d 场" % [data.reused_runs, data.computed_runs]
	if candidate != "":
		var cell = data.request.player.items.back().cell
		status.text = "预购 %s · 第 %d 列，第 %d 行" % [candidate, cell[0] + 1, cell[1] + 1]
	if save_failed:
		status.text = "最佳摆盘写入磁盘失败"
	show_metric(metrics_select.selected)
	update_footer(data)

func update_footer(data):
	precision_footer.text = "空格重算 / %d次模拟" % data.count
	precision_footer.hint_tooltip = ""

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
			if row.has("rng_key") and item.has_meta("lab_rng_key") and item.get_meta("lab_rng_key") != row.rng_key:
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
	for row in metric_rows(last_result, index):
		var key = row.get("key", row.source)
		totals[key] = row.value
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
