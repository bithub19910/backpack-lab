extends Reference

# Read native grid geometry without moving, cloning or purchasing shop objects.
static func placement(item, inventory):
	var occupied = item.getCollisionCells()
	var cells = item.getExtensionCells() if item.isBag() else occupied
	if occupied.empty() or cells.empty():
		return null
	for face in [item.getFaceDirection(), (item.getFaceDirection() + 1) % 4, (item.getFaceDirection() + 2) % 4, (item.getFaceDirection() + 3) % 4]:
		var minimum = Vector2(INF, INF)
		for cell in occupied:
			var rotated = cell.rotated(face * PI * 0.5).round()
			minimum.x = min(minimum.x, rotated.x)
			minimum.y = min(minimum.y, rotated.y)
		var offsets = []
		for cell in cells:
			offsets.append(cell.rotated(face * PI * 0.5).round() - minimum)
		for y in int(inventory.inventorySize.y):
			for x in int(inventory.inventorySize.x):
				var fits = true
				for offset in offsets:
					var cell = Vector2(x, y) + offset
					if not inventory.isInventoryCell(cell):
						fits = false
					elif item.isBag():
						if inventory.bagCells.has(cell):
							fits = false
					elif not inventory.bagCells.has(cell) or inventory.filledCells.has(cell):
						fits = false
					if not fits:
						break
				if fits:
					return {"cell": [x, y], "face": face}
	return null

static func row(item, location):
	var data = {"id": item.getName(), "cell": location.cell, "face": location.face, "data": item.getData(), "gems": []}
	for gem in item.getGems():
		data.gems.append(null if gem == null else {"id": gem.getName(), "face": gem.getFaceDirection(), "data": gem.getData()})
	return data
