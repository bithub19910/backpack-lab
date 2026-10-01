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
	return board

static func context():
	var rules = []
	for key in CustomRules.Rules.values():
		rules.append(CustomRules.values[key])
	return {"mode": Game.curMode, "round": Game.curRound, "league": Game.getLeague(Game.curClass),
		"custom_rules": rules, "custom_rules_active": CustomRules.customRulesActive}

static func install(character, board, owner):
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
	for row in ordered:
		var item = ItemBook.instantiateItem(row.id)
		var source_key = str(character.playerId) + ":" + str(row.id) + ":" + str(row.cell)
		item.set_meta("lab_source_key", source_key)
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
			gem.set_meta("lab_cell", row.cell)
			item.setGem(i, gem)
			gem.setFaceDirectionInstant(int(gem_row.face))
			if gem_row.get("data") != null:
				gem.setData(gem_row.data)
		if row.get("data") != null:
			item.setData(row.data)
	return ""

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
	file.close()
	var dir = Directory.new()
	if file.file_exists(path):
		dir.remove(path + ".bak")
		if dir.rename(path, path + ".bak") != OK:
			return false
	return dir.rename(path + ".tmp", path) == OK
