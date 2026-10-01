"""Patch locally captured native scripts with common random-number streams.

Original game probabilities and balanced counters remain native. Streams are
keyed by sample/object/purpose; visual draws cannot consume combat samples.
No captured native source is distributed by this module.
"""
import re

ITEM_HELPERS = '''
var lab_seed = 0
var lab_identity = ""
var lab_streams = {}

func lab_stream(kind):
	if not lab_streams.has(kind):
		lab_streams[kind] = preload("res://BackpackLab/TrialRandom.gd").stream(lab_seed, lab_identity, kind)
	return lab_streams[kind]

func lab_reset_rng(value, identity):
	lab_seed = value
	lab_identity = identity
	lab_streams.clear()
	chanceRng.lab_rng = lab_stream("chance")
	damageRangeRng.lab_rng = lab_stream("damage")
	for i in getGems().size():
		var gem = getGems()[i]
		if gem != null:
			gem.lab_reset_rng(value, identity + ":gem:" + str(i))

func lab_shuffle(array):
	var random = lab_stream("shuffle")
	for i in range(array.size() - 1, 0, -1):
		var j = random.randi_range(0, i)
		var hold = array[i]
		array[i] = array[j]
		array[j] = hold

func lab_sortDict(dict, shuffleBeforeSort = false):
	var sorted = dict.keys()
	if shuffleBeforeSort:
		lab_shuffle(sorted)
	return Util.sortArrayByDict(sorted, dict)
'''


def method_text(source, name):
    found = re.search(rf'(?m)^func {re.escape(name)}\([^\n]*\n(?:[\t ].*\n|\n)*', source)
    if not found:
        raise ValueError('Missing native RNG method: ' + name)
    return found.group()


def patch_native(rules, patched, item, character):
    sources = {('res://' + p.stem.replace('__', '/') + '.gd'): p.read_text(encoding='utf-8')
               for p in (rules / 'decompiled').glob('*.gd')}
    classes = {}
    for path, source in sources.items():
        match = re.search(r'(?m)^class_name (\w+)', source)
        if match: classes[match[1]] = path

    def is_item(path, seen=None):
        if path == 'res://Items/Item.gd': return True
        if path not in sources: return False
        seen = set() if seen is None else seen
        if path in seen: return False
        seen.add(path)
        match = re.search(r'(?m)^extends\s+([^\n]+)', sources[path])
        if not match: return False
        parent = match[1].strip().strip('"')
        return is_item(classes.get(parent, parent), seen)

    utility = sources['res://Utility/Util.gd']
    helpers = ['roll', 'flip', 'flipPercent', 'flipRound', 'flipWeighted',
               'pickRandomElement', 'randRange', 'randPitch', 'randInBox', 'randInCircle']
    added = ITEM_HELPERS
    for name in helpers:
        method = method_text(utility, name)
        method = re.sub(r'\brng\b', 'lab_stream("visual" )' if name in ['randPitch', 'randInBox', 'randInCircle'] else 'lab_stream("' + name + '")', method)
        for called in helpers:
            method = re.sub(r'\b' + called + r'\(', 'lab_' + called + '(', method)
        added += '\n' + method

    visual = {'playPickupSound', 'playDropSound', 'dropImpulse', 'popIn', 'unlock', 'lock',
              'playActivationSound', 'playChargeSound', 'getLabelPosition'}
    overrides = {}
    for path, source in sources.items():
        if not is_item(path): continue
        original = item if path == 'res://Items/Item.gd' else source
        result = original
        # Direct draws default to effect stream; cooldown/damage and cosmetic
        # methods have separate streams. Helper calls each get their own stream.
        result = result.replace('Util.rng', 'lab_stream("effect")')
        for name in helpers:
            result = result.replace('Util.' + name + '(', 'lab_' + name + '(')
        result = re.sub(r'([\w.]+)\.shuffle\(\)', r'lab_shuffle(\1)', result)
        result = result.replace('Util.sortDict(', 'lab_sortDict(')
        for match in list(re.finditer(r'(?m)^func (\w+)\([^\n]*\n(?:[\t ].*\n|\n)*', result))[::-1]:
            name = match[1]
            if name in visual or 'Sound' in name or name == 'adjustCooldown' or name == 'getDamage':
                purpose = 'cooldown' if name == 'adjustCooldown' else ('damage' if name == 'getDamage' else 'visual')
                result = result[:match.start()] + match.group().replace('lab_stream("effect")', 'lab_stream("' + purpose + '")') + result[match.end():]
        if path == 'res://Items/Item.gd': result += added
        if result != source:
            name = 'CRN_' + path[6:-3].replace('/', '__')
            (patched / (name + '.gd')).write_text(result, encoding='utf-8')
            overrides[path] = name

    for leaf in ['BalancedRandom', 'BalancedRange']:
        path = 'res://Utility/' + leaf + '.gd'
        source = sources[path] + '\nvar lab_rng = null\n'
        if leaf == 'BalancedRandom':
            # Construction happens before a trial. Keep the native constructor;
            # reset() and the existing balancing arithmetic are unchanged.
            source = source.replace('Util.flip(chance)', '(lab_rng.randf() <= chance if lab_rng != null else Util.flip(chance))')
            source = source.replace('Util.flip(accChance)', '(lab_rng.randf() <= accChance if lab_rng != null else Util.flip(accChance))')
        else:
            source = source.replace('Util.rng.randi_range', '(lab_rng if lab_rng != null else Util.rng).randi_range')
        (patched / (leaf + '.gd')).write_text(source, encoding='utf-8')
        overrides[path] = leaf
    # All direct RNG uses in Character are presentation-only. Accuracy, crit,
    # and resistance already go through native BalancedRng instances above.
    character = character.replace('Util.rng', 'lab_visual_rng')
    character = character.replace('battleRageItems.pick_random()', 'battleRageItems[lab_choice_rng.randi_range(0, battleRageItems.size() - 1)]')
    character += '\nvar lab_visual_rng = RandomNumberGenerator.new()\n'
    character += 'var lab_choice_rng = RandomNumberGenerator.new()\n'
    (patched / 'Character.gd').write_text(character, encoding='utf-8')
    # Stack resistance/reflection/cleanse protection are combat rolls too.
    # Their old global stream was also consumed by pooled label animations.
    buff = sources['res://Core/Buff.gd']
    for expression, purpose in [('totalResistChance', 'resist'), (' - totalResistChance', 'amplify'),
                                ('reflectChancePercent', 'reflect'),
                                ('cleanseProtectionChancePercent', 'protect'),
                                (' - cleanseProtectionChancePercent', 'unprotect')]:
        buff = buff.replace('Util.flipPercent(' + expression + ')',
                            'lab_flip(' + expression + ', item, "' + purpose + '")')
    buff += '''
var lab_seed = 0
var lab_streams = {}

func lab_reset_rng(value):
	lab_seed = value
	lab_streams.clear()

func lab_flip(chance, item, purpose):
	var source = str(item.get_meta("lab_rng_key")) if item is Item and item.has_meta("lab_rng_key") else "environment"
	var key = purpose + ":" + source
	if not lab_streams.has(key):
		lab_streams[key] = preload("res://BackpackLab/TrialRandom.gd").stream(lab_seed, "buff:" + str(character.playerId) + ":" + str(type), key)
	return lab_streams[key].randf() <= chance / 100.0
'''
    (patched / 'Buff.gd').write_text(buff, encoding='utf-8')
    overrides['res://Core/Buff.gd'] = 'Buff'
    from cosmetic_random import patch_cosmetics
    from presentation_free import patch_presentation
    overrides = patch_cosmetics(sources, patched, overrides)
    return patch_presentation(sources, patched, overrides)
