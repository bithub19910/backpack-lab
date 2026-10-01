extends Node
var adapter
var checks = {}

func _ready():
	call_deferred("check_ui")

func wait_job():
	var deadline = OS.get_ticks_msec() + 90000
	while adapter.job != null and OS.get_ticks_msec() < deadline:
		yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")

func check_ui():
	yield(get_tree().create_timer(5.0), "timeout")
	Game.startFreshRun(Game.Mode.Unranked)
	yield(get_tree().create_timer(4.0), "timeout")
	adapter = get_node("/root/BackpackLab")
	var before = adapter.Snapshot.capture(Game.PLAYER)
	var gold = Game.gold
	checks["default_open"] = adapter.panel.visible
	checks["default_10"] = adapter.count.value == 10
	checks["default_15s"] = adapter.horizon.value == 15
	checks["native_geometry_matches"] = true
	for identifier in ["Wooden Sword", "Banana", "Leather Bag", "Ranger Bag"]:
		if not ItemBook.items.has(identifier):
			continue
		var probe = ItemBook.instantiateItem(identifier)
		probe.ownerType = Item.Owner.Shop
		Game.shopItemYSort.add_child(probe)
		for face in 4:
			probe.setFaceDirectionInstant(face)
			var location = adapter.ShopPreview.placement(probe, Game.PLAYER.INVENTORY)
			if location != null:
				Game.PLAYER.INVENTORY.orientItem(probe, Vector2(location.cell[0], location.cell[1]), location.face)
				checks["native_geometry_matches"] = checks.native_geometry_matches and Game.PLAYER.INVENTORY.canAddItemOrBag(probe)
		probe.queue_free()
	adapter.horizon.value = 16
	yield(get_tree().create_timer(0.8), "timeout")
	checks["settings_manual_only"] = adapter.job == null
	adapter.horizon.value = 15
	adapter.calculate("dummy")
	yield(wait_job(), "completed")
	checks["dummy_10"] = adapter.last_result != null and adapter.last_result.count == 10
	if adapter.last_result == null:
		finish()
		return
	checks["rate_units"] = adapter.output_value.text == "%.2f" % (adapter.last_result.sides[0].damage.back() / 15.0)
	checks["best_recorded"] = adapter.best != null and File.new().file_exists(adapter.directory.plus_file("slot-8.json"))
	checks["best_native_slot"] = Game.undoStack.manualSnapshots[8] != null
	checks["two_separate_graphs"] = adapter.chart.metric == "damage" and adapter.recovery_chart.metric == "hps" and adapter.chart.result.id == adapter.recovery_chart.result.id
	checks["mode_latched"] = adapter.dummy_button.pressed and not adapter.opponents_button.pressed
	checks["mode_persisted"] = adapter.Snapshot.read_json(adapter.directory.plus_file("preferences.json")).mode == "dummy"
	checks["right_edge_full_height"] = adapter.panel.rect_position.x + adapter.panel.rect_size.x == get_viewport().get_visible_rect().size.x and adapter.panel.rect_position.y + adapter.panel.rect_size.y == get_viewport().get_visible_rect().size.y
	checks["shop_buttons_follow_native_slots"] = true
	for i in 5:
		for j in range(i + 1, 5):
			var native_delta = Game.shopSceneNode.slots[i].position - Game.shopSceneNode.slots[j].position
			var ui_delta = adapter.shop_buttons[i].rect_position - adapter.shop_buttons[j].rect_position
			checks.shop_buttons_follow_native_slots = checks.shop_buttons_follow_native_slots and sign(native_delta.x) == sign(ui_delta.x) and sign(native_delta.y) == sign(ui_delta.y) and not adapter.shop_buttons[i].get_rect().intersects(adapter.shop_buttons[j].get_rect())
	var first = adapter.last_result.duplicate(true)
	var moving = null
	for item in Game.PLAYER.INVENTORY.getItems():
		if not item.isBag():
			moving = item
			break
	if moving != null:
		Game.PLAYER.INVENTORY.removeItem(moving)
		moving.addToStorageBox(false, false, true, Game.STORAGEBOX.center)
		yield(get_tree().create_timer(0.4), "timeout")
		checks["movement_manual_only"] = adapter.job == null
		Game.undoStack.makeManualSnapshot(3)
		checks["manual_slot_does_not_attach_stale_curve"] = adapter.Snapshot.read_json(adapter.directory.plus_file("slot-3.json")).result == null
		var key = InputEventKey.new()
		key.scancode = KEY_8
		key.alt = true
		key.pressed = true
		Input.parse_input_event(key)
		yield(get_tree(), "idle_frame")
		checks["alt8_restores_owned_board"] = adapter.Snapshot.same(before, adapter.Snapshot.capture(Game.PLAYER))
	adapter.count.value = 2
	var offers = Game.shopSceneNode.getItems()
	var preview_count = 0
	var preview_ok = true
	for i in 5:
		if offers[i] == null or adapter.ShopPreview.placement(offers[i], Game.PLAYER.INVENTORY) == null:
			continue
		adapter.calculate_shop(i)
		yield(wait_job(), "completed")
		preview_ok = preview_ok and adapter.last_result.request.get("preview_item", "") != "" and adapter.last_result.request.player.items.size() == before.items.size() + 1
		preview_count += 1
	checks["shop_candidates_native_simulated"] = preview_ok and preview_count > 0
	var space = InputEventKey.new()
	space.scancode = KEY_SPACE
	space.pressed = true
	Input.parse_input_event(space)
	yield(get_tree(), "idle_frame")
	checks["space_recalculates_actual_board"] = adapter.job != null and adapter.job.request.get("preview_item", "") == "" and adapter.Snapshot.same(adapter.job.request.player, before)
	var space_id = adapter.job.id
	space.echo = true
	Input.parse_input_event(space)
	yield(get_tree(), "idle_frame")
	checks["space_hold_no_repeat"] = adapter.job != null and adapter.job.id == space_id
	yield(wait_job(), "completed")
	checks["space_does_not_start_real_combat"] = Game.state == Game.State.Shop
	adapter.toggle_advanced()
	yield(get_tree(), "idle_frame")
	adapter.count.get_line_edit().grab_focus()
	checks["space_input_focus_setup"] = adapter.panel.get_focus_owner() == adapter.count.get_line_edit()
	space.echo = false
	Input.parse_input_event(space)
	yield(get_tree(), "idle_frame")
	checks["space_ignores_text_input"] = adapter.job == null
	adapter.count.get_line_edit().release_focus()
	adapter.toggle_advanced()
	checks["shop_preview_gold_unchanged"] = Game.gold == gold
	checks["shop_preview_board_unchanged"] = adapter.Snapshot.same(before, adapter.Snapshot.capture(Game.PLAYER))
	var filled = Game.PLAYER.INVENTORY.filledCells.duplicate()
	var bags = Game.PLAYER.INVENTORY.bagCells.duplicate()
	for cell in Game.PLAYER.INVENTORY.inventoryCells:
		Game.PLAYER.INVENTORY.filledCells[cell] = true
		Game.PLAYER.INVENTORY.bagCells[cell] = true
	adapter.calculate_shop(0)
	checks["no_space_no_calculation"] = adapter.job == null and adapter.status.text == "没有足够的预留空位"
	Game.PLAYER.INVENTORY.filledCells = filled
	Game.PLAYER.INVENTORY.bagCells = bags
	var actual_best = adapter.best
	var virtual_best = first.duplicate(true)
	virtual_best.request.player.items.append({"id": "__missing__", "data": null, "gems": [], "cell": [0,0], "face": 0})
	adapter.mode_bests[adapter.mode] = virtual_best
	adapter.restore_best()
	checks["unowned_best_restore_safe"] = adapter.Snapshot.same(before, adapter.Snapshot.capture(Game.PLAYER)) and "尚未拥有" in adapter.status.text
	adapter.mode_bests[adapter.mode] = actual_best
	var inferior = first.duplicate(true)
	inferior.id = "inferior-check"
	for side in inferior.sides:
		for series in side.values():
			for i in series.size():
				series[i] = 0.0
	var best_id = adapter.best.id
	adapter.accept_result(inferior)
	checks["inferior_preserves_best_and_compares"] = adapter.best.id == best_id and adapter.chart.baseline != null
	adapter.opacity.value = 0.3
	checks["opacity_persisted"] = abs(adapter.Snapshot.read_json(adapter.directory.plus_file("preferences.json")).opacity - 0.3) < 0.001
	checks["background_clickthrough"] = adapter.panel.mouse_filter == Control.MOUSE_FILTER_IGNORE and adapter.chart.mouse_filter == Control.MOUSE_FILTER_IGNORE
	adapter.toggle_panel()
	checks["manual_hide"] = not adapter.panel.visible and adapter.toolbar.visible and adapter.eye_button.collapsed
	adapter.toggle_panel()
	adapter.opacity.value = 0.85
	if Game.OPPONENT == null:
		Game.OPPONENT = Game.opponentScene.instance()
		Game.OPPONENT.playerId = Character.ID.OPPONENT
		Game.opponentNode.add_child(Game.OPPONENT)
		adapter.Snapshot.install(Game.OPPONENT, before, Item.Owner.Opponent)
	Game.set_process(false)
	Game.set_physics_process(false)
	Game.state = Game.State.Combat
	Game.emit_signal("switching_to_combat")
	var frozen = adapter.pending_battle.player.duplicate(true)
	Game.emit_signal("combat_end", Game.RoundResult.Win)
	Game.curRound += 1
	checks["post_25_prebattle_snapshot"] = adapter.job.request.runs == 25 and adapter.Snapshot.same(adapter.job.request.player, frozen)
	yield(wait_job(), "completed")
	checks["post_survives_round_increment"] = adapter.post_panel.visible and adapter.post_result != null
	checks["post_winrate_and_average"] = adapter.post_result != null and adapter.post_result.win_rate != null and "平均战斗" in adapter.post_detail.text
	var image = get_viewport().get_texture().get_data()
	image.flip_y()
	image.save_png("user://postbattle.png")
	Game.state = Game.State.Shop
	Game.emit_signal("shop_opened")
	yield(get_tree(), "idle_frame")
	checks["next_shop_hides_post_and_resets_best"] = not adapter.post_panel.visible and adapter.best == null
	adapter.count.value = 10
	adapter.calculate("opponent")
	checks["opponent_default_10"] = adapter.job.request.runs == 10
	yield(wait_job(), "completed")
	checks["opponent_result"] = adapter.last_result != null and adapter.last_result.request.mode == "opponent"
	var opponent_best = adapter.mode_bests.opponent.id
	var opponent_result = adapter.last_result
	adapter.calculate("dummy")
	yield(wait_job(), "completed")
	var dummy_best = adapter.mode_bests.dummy.id
	checks["two_mode_slots_independent"] = File.new().file_exists(adapter.directory.plus_file("slot-8.json")) and File.new().file_exists(adapter.directory.plus_file("slot-9.json")) and adapter.mode_bests.opponent.id == opponent_best and adapter.mode_bests.dummy.request.mode == "dummy" and adapter.mode_bests.opponent.request.mode == "opponent"
	adapter.calculate("opponent")
	checks["mode_switch_restores_matching_display"] = adapter.last_result.request.mode == "opponent" and adapter.chart.result.request.mode == "opponent" and adapter.recovery_chart.result.request.mode == "opponent"
	adapter.cancel()
	checks["switch_does_not_overwrite_other_best"] = adapter.mode_bests.dummy.id == dummy_best
	adapter.restore_best("opponent")
	checks["opponent_best_uses_slot9"] = Game.undoStack.manualSnapshots[9] != null
	adapter.last_opponent = null
	adapter.enter_shop()
	checks["opponent_reloads_on_resume"] = adapter.last_opponent != null
	adapter.recalculate()
	var cancelled = adapter.job
	adapter.cancel()
	checks["all_worker_parts_cancelled"] = true
	for part in cancelled.parts:
		checks.all_worker_parts_cancelled = checks.all_worker_parts_cancelled and File.new().file_exists(part.output + ".cancel")
	adapter.round_id = ""
	adapter.enter_shop()
	checks["best_reloads_same_round"] = adapter.best != null
	adapter.toggle_advanced()
	checks["time_label"] = adapter.duration_label.text == "对战时间 15 秒"
	adapter.toggle_statistics()
	adapter.change_metric_category(0)
	checks["combat_filter"] = adapter.metrics_select.get_item_count() == 5 and not adapter.metric_action.visible
	adapter.change_metric_category(1)
	checks["stamina_filter"] = adapter.metrics_select.get_item_count() == 3 and adapter.metrics_select.get_item_id(0) == 8 and not adapter.metric_action.visible
	adapter.change_metric_category(2)
	adapter.metrics_select.select(1)
	adapter.metric_action.select(2)
	adapter.show_metric(0)
	checks["third_level_status_filter"] = adapter.metrics_select.get_item_count() == 10 and adapter.metric_action.visible and "状态 / 再生 / 消耗" in adapter.details.text
	adapter.change_metric_category(0)
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	checks["panel_fits_canvas"] = adapter.panel.rect_position.y + adapter.panel.rect_size.y <= 1080
	finish()

func finish():
	var image = get_viewport().get_texture().get_data()
	image.flip_y()
	image.save_png("user://frontend.png")
	adapter.Snapshot.write_json(OS.get_user_data_dir().plus_file("report.json"), checks)
	print("LAB_FRONTEND_CHECKS ", JSON.print(checks))
	get_tree().quit()
