extends Reference

static func same_game_rules(left, right):
	if typeof(left) != TYPE_DICTIONARY or typeof(right) != TYPE_DICTIONARY:
		return false
	# Opponent snapshots are pure native boards. UI/worker updates don't change
	# their format; saved computed results still require full implementation ID.
	for key in ["schema", "game_version", "source_pck_sha256", "engine_sha256"]:
		if not left.has(key) or not right.has(key) or left[key] != right[key]:
			return false
	return true

static func same(left, right):
	# Godot 3 Dictionary equality compares identity, not JSON contents.
	if typeof(left) == TYPE_DICTIONARY and typeof(right) == TYPE_DICTIONARY:
		if left.size() != right.size():
			return false
		for key in left:
			if not right.has(key) or not same(left[key], right[key]):
				return false
		return true
	if typeof(left) == TYPE_ARRAY and typeof(right) == TYPE_ARRAY:
		if left.size() != right.size():
			return false
		for i in left.size():
			if not same(left[i], right[i]):
				return false
		return true
	return left == right

# Save pure JSON values, never references to the live board.
static func capture(character):
	var board = {"class": character.characterClass, "health": character.getBaseMaxHealth(),
		"base_stamina": character.getBaseMaxStamina(), "stamina": character.getMaxBaseStamina(), "items": []}
	for item in character.INVENTORY.getItems():
		var cell = item.getTopLeftCell()
		var row = {"id": item.getName(), "cell": [int(cell.x), int(cell.y)],
			"face": item.getFaceDirection(), "data": item.getData(), "gems": []}
		for gem in item.getGems():
			row.gems.append(null if gem == null else {"id": gem.getName(),
				"face": gem.getFaceDirection(), "data": gem.getData()})
		board.items.append(row)
	# Assign once per live object, so moving/rotating/reinserting does not change
	# its sample identity. Different item types cannot renumber existing objects.
	var counters = ItemBook.get_meta("lab_rng_counters") if ItemBook.has_meta("lab_rng_counters") else {}
	for i in board.items.size():
		var item = character.INVENTORY.getItems()[i]
		if not item.has_meta("lab_rng_key"):
			counters[item.getName()] = counters.get(item.getName(), 0) + 1
			item.set_meta("lab_rng_key", item.getName() + "#" + str(counters[item.getName()]))
		board.items[i]["rng_key"] = item.get_meta("lab_rng_key")
	ItemBook.set_meta("lab_rng_counters", counters)
	return normalize(board)

class RowOrder:
	static func less(a, b):
		return str(a.get("rng_key", a.id + str(a.cell))) < str(b.get("rng_key", b.id + str(b.cell)))

static func normalize(board):
	var copy = board.duplicate(true)
	copy.items.sort_custom(RowOrder, "less")
	var counts = {}
	for row in copy.items:
		counts[row.id] = counts.get(row.id, 0) + 1
		if not row.has("rng_key"):
			row["rng_key"] = row.id + "#" + str(counts[row.id])
	copy.items.sort_custom(RowOrder, "less")
	return copy

static func context():
	var rules = []
	for key in CustomRules.Rules.values():
		rules.append(CustomRules.values[key])
	return {"mode": Game.curMode, "round": Game.curRound, "league": Game.getLeague(Game.curClass),
		"custom_rules": rules, "custom_rules_active": CustomRules.customRulesActive}

static func install(character, board, owner, reusable = null):
	if reusable == null:
		character.setClass(int(board["class"]), false)
	character.setMaxHealth(float(board.health))
	character.baseMaxStamina = float(board.base_stamina)
	character.setMaxStamina(float(board.stamina))
	var ordered = []
	for want_bags in [true, false]:
		for row in board.items:
			if not ItemBook.items.has(row.id):
				return "未知物品：" + str(row.id)
			if ItemBook.getDescriptor(row.id).hasType(Item.Type.Bag) == want_bags:
				ordered.append(row)
	var final_order = []
	for row in ordered:
		var item = null
		if reusable != null:
			for entry in reusable:
				if same(entry.row, row):
					item = entry.item
					reusable.erase(entry)
					break
		if item != null:
			final_order.append(item)
			continue
		item = ItemBook.instantiateItem(row.id)
		final_order.append(item)
		var source_key = str(character.playerId) + ":" + str(row.id) + ":" + str(row.cell)
		item.set_meta("lab_source_key", source_key)
		item.set_meta("lab_rng_key", row.get("rng_key", row.id + str(row.cell)))
		item.set_meta("lab_cell", row.cell)
		item.ownerType = owner
		character.INVENTORY.itemNode.add_child(item)
		var cell = Vector2(row.cell[0], row.cell[1])
		character.INVENTORY.orientItem(item, cell, int(row.face))
		if not character.INVENTORY.canAddItemOrBag(item):
			item.queue_free()
			return "摆放位置无效：" + str(row.id)
		character.INVENTORY.addItemByTopLeft(item, cell)
		for i in row.get("gems", []).size():
			var gem_row = row.gems[i]
			if gem_row == null:
				continue
			if i >= item.sockets.size() or not ItemBook.items.has(gem_row.id):
				return "宝石槽数据无效"
			var gem = ItemBook.instantiateItem(gem_row.id)
			gem.set_meta("lab_source_key", source_key + ":gem:" + str(i))
			gem.set_meta("lab_rng_key", item.get_meta("lab_rng_key") + ":gem:" + str(i))
			gem.set_meta("lab_cell", row.cell)
			item.setGem(i, gem)
			gem.setFaceDirectionInstant(int(gem_row.face))
			if gem_row.get("data") != null:
				gem.setData(gem_row.data)
		if row.get("data") != null:
			item.setData(row.data)
	character.INVENTORY.items = final_order
	# Physics callbacks follow scene-tree order. Reconciliation must not leave
	# a reinserted item at the end and silently change same-frame attack order.
	for i in final_order.size():
		character.INVENTORY.itemNode.move_child(final_order[i], i)
	return ""

static func reconcile(character, before, board, owner):
	var reusable = []
	var remaining = board.items.duplicate(true)
	for item in character.INVENTORY.getItems().duplicate():
		var row = null
		for candidate in before.items:
			if candidate.id == item.getName() and Vector2(candidate.cell[0], candidate.cell[1]) == item.getTopLeftCell():
				row = candidate
				break
		var found = -1
		for i in remaining.size():
			if same(row, remaining[i]):
				found = i
				break
		if found >= 0:
			reusable.append({"row": row, "item": item})
			remaining.remove(found)
		else:
			character.INVENTORY.removeItem(item)
			item.discard()
	var reused = reusable.size()
	var error = install(character, board, owner, reusable)
	return {"error": error, "reused": reused, "created": board.items.size() - reused}

static func read_json(path):
	var file = File.new()
	if file.open(path, File.READ) != OK:
		return null
	if file.get_len() > 16777216:
		file.close()
		return null
	var parsed = JSON.parse(file.get_as_text())
	file.close()
	return parsed.result if parsed.error == OK else null

static func write_json(path, value):
	var file = File.new()
	if file.open(path + ".tmp", File.WRITE) != OK:
		return false
	file.store_string(JSON.print(value))
	var written = file.get_error() == OK
	file.close()
	if not written:
		return false
	var dir = Directory.new()
	if file.file_exists(path):
		dir.remove(path + ".bak")
		if not rename_retry(dir, path, path + ".bak"):
			return false
	return rename_retry(dir, path + ".tmp", path)

static func rename_retry(dir, from, to):
	# Windows may hold an inbox open briefly while a worker reads it.
	for attempt in 6:
		if dir.rename(from, to) == OK:
			return true
		if attempt < 5:
			OS.delay_msec(2)
	return false
