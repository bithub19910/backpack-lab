extends Reference

# Common random numbers: independent streams per stable object and purpose.
# Does not change the native probabilities or balanced-roll counters.
static func stream(seed_value, identity, purpose):
	var rng = RandomNumberGenerator.new()
	rng.seed = ("0x" + (str(seed_value) + ":" + identity + ":" + purpose).sha256_text().substr(0, 15)).hex_to_int()
	return rng

class Order:
	static func less(a, b):
		if a.getTriggerPriority() != b.getTriggerPriority():
			return a.getTriggerPriority() > b.getTriggerPriority()
		return a.get_meta("lab_order") < b.get_meta("lab_order")

static func order(items, seed_value, side):
	for item in items:
		var identity = str(side) + ":" + str(item.get_meta("lab_rng_key"))
		item.lab_reset_rng(seed_value, identity)
		item.set_meta("lab_order", (str(seed_value) + ":" + identity).sha256_text())
	items.sort_custom(Order, "less")
	return items
