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
	adapter.post_show = true
	var before = adapter.Snapshot.capture(Game.PLAYER)
	var gold = Game.gold
	checks["default_open"] = adapter.panel.visible
	checks["default_10"] = adapter.count.value == 10
	checks["default_15s"] = adapter.horizon.value == 15
	var uncertainty = adapter.pool.Statistics.mean_interval([1.0, 3.0])
	checks["sampling_interval_known_pair"] = abs(uncertainty.mean - 2.0) < 0.001 and abs(uncertainty.half_width - 12.706) < 0.001
	checks["sampling_interval_one_is_unknown"] = adapter.pool.Statistics.mean_interval([1.0]).half_width == null
	checks["sampling_interval_zero_mean_is_unknown"] = adapter.pool.Statistics.mean_interval([0.0, 0.0]).relative == null
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
	checks["footer_has_no_error_claim"] = adapter.precision_footer.text == "空格重算 / 10次模拟" and adapter.precision_footer.hint_tooltip == ""
	checks["best_recorded"] = adapter.best != null and File.new().file_exists(adapter.directory.plus_file("slot-8.json"))
	checks["best_native_slot"] = Game.undoStack.manualSnapshots[8] != null
	checks["compact_best_keeps_source_statistics"] = adapter.best.trials.empty() and adapter.Snapshot.same(adapter.metric_rows(adapter.best, 0), adapter.metric_rows(adapter.last_result, 0))
	checks["two_separate_graphs"] = adapter.chart.metric == "damage" and adapter.recovery_chart.metric == "hps" and adapter.chart.result.id == adapter.recovery_chart.result.id
	checks["mode_latched"] = adapter.dummy_button.pressed and not adapter.opponents_button.pressed
	checks["mode_persisted"] = adapter.Snapshot.read_json(adapter.directory.plus_file("preferences.json")).mode == "dummy"
	checks["right_edge_full_height"] = adapter.panel.rect_position.x + adapter.panel.rect_size.x == get_viewport().get_visible_rect().size.x and adapter.panel.rect_position.y + adapter.panel.rect_size.y == get_viewport().get_visible_rect().size.y
	checks["shop_buttons_follow_native_slots"] = true
	for i in 5:
		for j in range(i + 1, 5):
			var native_delta = Game.shopSceneNode.slots[i].position - Game.shopSceneNode.slots[j].position
			var ui_delta = adapter.shop_buttons[i].rect_position - adapter.shop_buttons[j].rect_position
			checks.shop_buttons_follow_native_slots = checks.shop_buttons_follow_native_slots and (sign(native_delta.x) == sign(ui_delta.x) or ui_delta.x == 0) and (sign(native_delta.y) == sign(ui_delta.y) or ui_delta.y == 0) and not adapter.shop_buttons[i].get_rect().intersects(adapter.shop_buttons[j].get_rect())
	var first = adapter.last_result.duplicate(true)
	adapter.pool.result_cache.clear()
	adapter.recalculate()
	var active_id = adapter.job.id
	adapter.recalculate()
	checks["same_pending_job_shared"] = adapter.job.id == active_id
	yield(wait_job(), "completed")
	checks["fixed_batch_uncached_repeat"] = not adapter.last_result.get("cached", false) and adapter.Snapshot.same(first.sides, adapter.last_result.sides) and first.wins == adapter.last_result.wins
	checks["fixed_seed_requested"] = first.request.seed == adapter.last_result.request.seed and first.request.seed == adapter.COMPARISON_SEED
	var varied_seeds = {}
	for trial in adapter.last_result.trials:
		varied_seeds[trial.seed] = true
	checks["fixed_batch_contains_ten_distinct_seeds"] = varied_seeds.size() == 10
	adapter.recalculate()
	checks["same_input_uses_cache_without_dispatch"] = adapter.job.has("cached_result") and adapter.job.parts.empty()
	yield(wait_job(), "completed")
	checks["cache_keeps_curve_and_count"] = adapter.last_result.get("cached", false) and adapter.last_result.count == 10 and adapter.Snapshot.same(first.sides, adapter.last_result.sides)
	var key_base = adapter.make_request(before, adapter.Snapshot.context(), 10)
	var key_changed = key_base.duplicate(true)
	key_changed.horizon = 16
	checks["cache_isolates_horizon"] = adapter.pool.request_key(key_base) != adapter.pool.request_key(key_changed)
	key_changed = key_base.duplicate(true)
	key_changed.runs = 50
	checks["cache_isolates_count"] = adapter.pool.request_key(key_base) != adapter.pool.request_key(key_changed)
	checks["comparison_preconditions_isolated"] = true
	for field in ["mode", "context", "seed", "rules", "opponent"]:
		key_changed = key_base.duplicate(true)
		key_changed[field] = "changed-condition"
		checks.comparison_preconditions_isolated = checks.comparison_preconditions_isolated and adapter.comparison_key(key_base) != adapter.comparison_key(key_changed)
	adapter.count.value = 25
	adapter.recalculate()
	checks["prefix_append_only_missing"] = adapter.job.prefix.size() == 10
	yield(wait_job(), "completed")
	checks["prefix_combined_count"] = adapter.last_result.count == 25 and adapter.last_result.reused_runs == 10 and adapter.last_result.computed_runs == 15
	checks["quality_owns_best"] = adapter.best.count == 25
	var appended = adapter.last_result.duplicate(true)
	adapter.pool.result_cache.clear()
	adapter.recalculate()
	yield(wait_job(), "completed")
	checks["append_matches_fresh_batch"] = adapter.Snapshot.same(appended.sides, adapter.last_result.sides) and appended.wins == adapter.last_result.wins
	for i in appended.count:
		for field in ["seed", "outcome", "duration", "sides", "remaining_health"]:
			checks.append_matches_fresh_batch = checks.append_matches_fresh_batch and adapter.Snapshot.same(appended.trials[i][field], adapter.last_result.trials[i][field])
	var piece = {"id": first.id, "request": first.request}
	checks["valid_sample_structure"] = adapter.pool.validate_part(first, piece)
	var broken = first.duplicate(true)
	broken.trials[0].seed += 1
	checks["wrong_seed_rejected"] = not adapter.pool.validate_part(broken, piece)
	broken = first.duplicate(true)
	broken.trials[0].sides[0].damage.pop_back()
	checks["short_curve_rejected"] = not adapter.pool.validate_part(broken, piece)
	adapter.count.value = 10
	adapter.recalculate()
	yield(wait_job(), "completed")
	checks["smaller_count_uses_prefix"] = adapter.last_result.get("cached", false) and adapter.Snapshot.same(adapter.last_result.sides, first.sides)
	checks["quality_restores_own_best"] = adapter.best.count == 10
	adapter.horizon.value = 16
	adapter.recalculate()
	yield(wait_job(), "completed")
	checks["duration_owns_best"] = adapter.best.horizon == 16
	adapter.horizon.value = 15
	adapter.recalculate()
	yield(wait_job(), "completed")
	checks["duration_restores_own_best"] = adapter.best.horizon == 15
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
		adapter.recalculate()
		yield(wait_job(), "completed")
		var owned_best = adapter.mode_bests[adapter.mode].id
		var owned_result = adapter.mode_results[adapter.mode].id
		adapter.calculate_shop(i)
		yield(wait_job(), "completed")
		preview_ok = preview_ok and adapter.last_result.request.get("preview_item", "") != "" and adapter.last_result.request.player.items.size() == before.items.size() + 1
		checks["preview_preserves_owned_best"] = adapter.mode_bests[adapter.mode].id == owned_best
		checks["preview_preserves_actual_current"] = adapter.mode_results[adapter.mode].id == owned_result
		checks["preview_signed_delta"] = "较当前" in adapter.result_caption.text
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
	checks["space_hold_no_repeat"] = (adapter.job != null and adapter.job.id == space_id) or (adapter.job == null and adapter.last_result.id == space_id)
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
	var inferior = adapter.mode_results[adapter.mode].duplicate(true)
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
	checks["post_starts_at_combat_start"] = adapter.job != null and adapter.job_kind == "post" and adapter.job.request.runs == 25 and adapter.post_panel.visible
	checks["post_no_progress_numbers"] = adapter.post_value.text == "本场胜率 · 计算中" and not adapter.post_detail.visible
	checks["opponent_saved_at_combat_start"] = adapter.Snapshot.same(adapter.last_opponent, adapter.Snapshot.read_json(adapter.directory.plus_file("last-opponent.json")).board)
	var post_job_id = adapter.job.id
	yield(wait_job(), "completed")
	checks["post_waits_for_battle_end"] = adapter.post_result != null and not adapter.post_detail.visible and not "%" in adapter.post_value.text
	Game.emit_signal("combat_end", Game.RoundResult.Win)
	Game.curRound += 1
	checks["post_25_prebattle_snapshot"] = adapter.post_result.count == 25 and adapter.post_result.id == post_job_id and adapter.Snapshot.same(adapter.post_result.request.player, frozen) and adapter.job == null
	checks["post_summary_only"] = adapter.post_result != null and adapter.post_result.sides.empty() and adapter.post_result.trials[0].sides.empty()
	checks["post_survives_round_increment"] = adapter.post_panel.visible and adapter.post_result != null
	checks["post_winrate_and_average"] = adapter.post_result != null and adapter.post_result.win_rate != null and "平均战斗" in adapter.post_detail.text
	checks["post_left_small_saved_caption"] = adapter.post_panel.rect_position == Vector2(16, 16) and adapter.post_value.get_font("font").size == 16 and adapter.post_detail.text.ends_with("对手阵容已保存") and adapter.post_detail.visible
	adapter.post_eye.emit_signal("pressed")
	checks["post_hide_preference_saved"] = not adapter.post_detail.visible and not adapter.Snapshot.read_json(adapter.directory.plus_file("preferences.json")).post_show
	Game.OPPONENT.setMaxHealth(Game.OPPONENT.getBaseMaxHealth() + 1)
	Game.emit_signal("switching_to_combat")
	yield(wait_job(), "completed")
	Game.emit_signal("combat_end", Game.RoundResult.Win)
	checks["post_hide_preference_next_battle"] = not adapter.post_detail.visible
	checks["opponent_replaced_locally"] = adapter.Snapshot.read_json(adapter.directory.plus_file("last-opponent.json")).board.health == Game.OPPONENT.getBaseMaxHealth()
	adapter.post_eye.emit_signal("pressed")
	checks["post_eye_reveals_and_remembers"] = adapter.post_detail.visible and adapter.Snapshot.read_json(adapter.directory.plus_file("preferences.json")).post_show
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
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
	yield(get_tree().create_timer(0.3), "timeout")
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
	checks["charts_at_least_square"] = adapter.chart.rect_size.y >= adapter.chart.rect_size.x - 1 and adapter.recovery_chart.rect_size.y >= adapter.recovery_chart.rect_size.x - 1
	checks["bottom_buttons_unchanged"] = adapter.settings_row.get_child(0).rect_min_size.y == 40
	checks["bottom_row_spacing"] = adapter.settings_row.rect_global_position.y - (adapter.shop_map.rect_global_position.y + adapter.shop_map.rect_size.y) >= 28
	# Recovery button: clear during an active request, then compute afresh.
	adapter.save_result()
	var saved_curve = adapter.directory.plus_file("curve-" + adapter.last_result.id + ".json")
	var saved_hash = File.new().get_sha256(saved_curve)
	var saved_opponent = adapter.last_opponent.duplicate(true)
	var saved_preferences = adapter.Snapshot.read_json(adapter.directory.plus_file("preferences.json"))
	var saved_board = adapter.Snapshot.capture(Game.PLAYER)
	var saved_gold = Game.gold
	var manual_slot = Game.undoStack.manualSnapshots[3]
	var old_workers = adapter.pool.workers.duplicate(true)
	var old_session = adapter.session_dir
	adapter.count.value = 11
	adapter.recalculate()
	checks["clear_test_has_active_work"] = adapter.job != null and not adapter.job.parts.empty()
	adapter.clear_cache_button.emit_signal("pressed")
	yield(get_tree(), "idle_frame")
	checks["clear_cancels_work_and_empties_cache"] = adapter.job == null and adapter.queued_preview == null and adapter.pool.active_job == null and adapter.pool.result_cache.empty()
	checks["clear_removes_results_and_bests"] = adapter.last_result == null and adapter.best == null and adapter.mode_results.dummy == null and adapter.mode_results.opponent == null and adapter.mode_bests.dummy == null and adapter.mode_bests.opponent == null and adapter.best_records.dummy.empty() and adapter.best_records.opponent.empty() and adapter.preview_result == null and adapter.post_result == null
	checks["clear_removes_persisted_caches"] = true
	for name in ["last-worker-input.json", "best-dummy.json", "best-opponent.json", "slot-8.json", "slot-9.json"]:
		for suffix in ["", ".bak", ".tmp"]:
			checks.clear_removes_persisted_caches = checks.clear_removes_persisted_caches and not File.new().file_exists(adapter.directory.plus_file(name + suffix))
	checks["clear_preserves_user_state"] = Game.gold == saved_gold and adapter.Snapshot.same(saved_board, adapter.Snapshot.capture(Game.PLAYER)) and adapter.Snapshot.same(saved_opponent, adapter.last_opponent) and adapter.Snapshot.same(saved_preferences, adapter.Snapshot.read_json(adapter.directory.plus_file("preferences.json"))) and File.new().get_sha256(saved_curve) == saved_hash and Game.undoStack.manualSnapshots[3] == manual_slot
	checks["clear_resets_best_slots_only"] = Game.undoStack.manualSnapshots[8] == null and Game.undoStack.manualSnapshots[9] == null
	checks["clear_resets_display"] = adapter.chart.result == null and adapter.chart.baseline == null and adapter.recovery_chart.result == null and adapter.output_value.text == "—" and adapter.best_output_value.text == "—"
	var ready_deadline = OS.get_ticks_msec() + 90000
	while adapter.pool.ready_count() < adapter.pool.workers.size() and OS.get_ticks_msec() < ready_deadline:
		yield(get_tree(), "idle_frame")
	checks["clear_restarts_workers"] = adapter.session_dir != old_session and adapter.pool.ready_count() == old_workers.size()
	for worker in old_workers:
		checks.clear_restarts_workers = checks.clear_restarts_workers and not OS.is_process_running(worker.pid)
	checks["clear_does_not_automatically_simulate"] = adapter.job == null and adapter.last_result == null
	for worker in adapter.pool.workers:
		checks.clear_does_not_automatically_simulate = checks.clear_does_not_automatically_simulate and not File.new().file_exists(worker.inbox + ".warmed")
	adapter.round_id = ""
	adapter.enter_shop()
	checks["clear_old_best_cannot_reload"] = adapter.best == null
	adapter.count.value = 10
	adapter.recalculate()
	checks["clear_next_request_is_fresh"] = adapter.job.prefix.empty() and not adapter.job.has("cached_result")
	yield(wait_job(), "completed")
	checks["clear_recovery_calculation_succeeds"] = adapter.last_result != null and adapter.last_result.count == 10 and not adapter.last_result.get("cached", false)
	adapter.toggle_advanced()
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	checks["clear_button_visible_in_settings"] = adapter.clear_cache_button.is_visible_in_tree() and adapter.clear_cache_button.rect_size.y >= 40
	finish()

func finish():
	var image = get_viewport().get_texture().get_data()
	image.flip_y()
	image.save_png("user://frontend.png")
	adapter.Snapshot.write_json(OS.get_user_data_dir().plus_file("report.json"), checks)
	print("LAB_FRONTEND_CHECKS ", JSON.print(checks))
	get_tree().quit()
