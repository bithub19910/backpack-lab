"""Separate audited presentation draws in local worker scripts only.

Method allowlists deliberately keep shop rolls, loot, matchmaking and combat
probabilities out of the presentation stream. No native source is shipped.
"""
import json
import re

HELPERS = ('roll', 'flip', 'flipPercent', 'flipRound', 'flipWeighted',
           'pickRandomElement', 'randRange', 'randPitch', 'randInBox', 'randInCircle')
METHOD = re.compile(r'(?m)^func (\w+)\([^\n]*\n(?:[\t ].*\n|\n)*')

# All random calls in these scripts were individually reviewed as presentation.
WHOLE = {
    'CharacterClasses/CharacterClass', 'Interface/Shopkeeper', 'Interface/Textbox',
    'Interface/ShopOffer', 'Interface/Storagebox', 'Interface/TitleScreen',
    'Interface/BuildHistory/BuildHistory', 'Interface/PaintingCanvas',
    'Interface/Tooltips/BuildIntoRecipesTooltip', 'Items/ItemDescriptor',
    'Items/ItemPushZone', 'Items/Exclusive/Chess/ChessPiece',
    'Utility/ItemRain', 'Utility/ItemBoundChecker', 'Utility/ShardEmitter',
    'Utility/SkinBook', 'Utility/UndoStack', 'Core/Combat', 'Core/Inventory',
}
SELECTED = {
    'Core/Game': {'instanceCharacter', 'addLoadoutAni_jump', 'addLoadoutAni',
                  '_unhandled_input', 'playShopBGM', 'startRound', 'onItemBought',
                  '_notification', 'checkProcesses_cyclic'},
    'Core/Character': {'playAttackAnimation', 'playActivateAnimation', 'takeDamage',
                       'randDmgNumberPos', 'randHealNumberPos', 'randDmgNumberDir',
                       'randBuffLabelPos', 'makeInvulnerable', 'onSpriteClicked',
                       'randAnimationSpeed'},
    'Interface/Sellbox': {'eatGold', 'burp', 'chomp', 'close', '_gui_input'},
    'Core/RunDatabase': {'getPlayerName'},
    'Utility/Util': {'randBuffLabelDir'},
    'Items/Gems/Gem': {'_ready'},
}
ITEM_VISUAL = {'playPickupSound', 'playDropSound', 'dropImpulse', 'popIn',
               'playActivationSound', 'playChargeSound', 'getLabelPosition',
               'moveToFreeSpaceInStorage', 'rotateRight', 'respondToHover',
               'sendCharge', 'unlockCombining', 'lockCombining', 'showProgressLabel',
               'getTranslatedName', 'getNextFreeLabelPosition'}


def remap_calls(text, utility=False):
    text = text.replace('Util.rng', 'Util.lab_visual_rng')
    text = re.sub(r'lab_stream\("(?:effect|visual)"\)', 'Util.lab_visual_rng', text)
    if utility:
        text = re.sub(r'\brng\.', 'lab_visual_rng.', text)
    for name in HELPERS:
        text = text.replace('Util.' + name + '(', 'Util.lab_visual_' + name + '(')
        text = re.sub(r'(?<![\w.])lab_' + name + r'\(', 'Util.lab_visual_' + name + '(', text)
    text = re.sub(r'([\w.]+)\.shuffle\(\)', r'Util.lab_visual_shuffle(\1)', text)
    text = re.sub(r'([\w.]+)\.pick_random\(\)', r'Util.lab_visual_pickRandomElement(\1)', text)
    text = re.sub(r'(?<![\w.])rand_range\(', 'Util.lab_visual_rng.randf_range(', text)
    return text


def patch_cosmetics(sources, patched, overrides):
    # Preserve earlier worker safety/RNG changes when layering this patch.
    existing = {'res://Core/Game.gd': 'Game', 'res://Core/Character.gd': 'Character',
                'res://Utility/Util.gd': 'Util', 'res://Core/RunDatabase.gd': 'RunDatabase',
                'res://Items/Animations/FlickerAnimation.gd': 'FlickerAnimation'}
    existing.update(overrides)
    audit = []
    for path, native in sources.items():
        leaf = path[6:-3]
        original = (patched / (existing[path] + '.gd')).read_text(encoding='utf-8') if path in existing else native
        whole = leaf in WHOLE or leaf.startswith('Assets/Decoration/') or leaf.startswith('Items/Animations/')
        selected = SELECTED.get(leaf, set())
        result = original
        for match in list(METHOD.finditer(original))[::-1]:
            name = match[1]
            if not (whole or name in selected or (leaf.startswith('Items/') and name in ITEM_VISUAL)):
                continue
            method = remap_calls(match.group(), utility=leaf == 'Utility/Util')
            if method != match.group():
                result = result[:match.start()] + method + result[match.end():]
                audit.append({'script': path, 'method': name})
        # Mixed shop methods: these precise expressions are only pop-in/pitch.
        if leaf == 'Core/Shop':
            for expression in ('Util.rng.randf_range(0.8, 1.2)', 'Util.rng.randf_range(0.95, 1.05)'):
                result = result.replace(expression, expression.replace('Util.rng', 'Util.lab_visual_rng'))
            audit.append({'script': path, 'method': 'rollItems/reroll visual expressions only'})
        # Storage scatter is presentation; leave the selected item unchanged.
        if leaf in ('Utility/Recipe', 'Sheets/ItemBook'):
            result = result.replace('Util.randInBox(', 'Util.lab_visual_randInBox(')
        if leaf == 'Utility/Util':
            added = '\nvar lab_visual_rng = RandomNumberGenerator.new()\n'
            for name in HELPERS:
                method = next(m.group() for m in METHOD.finditer(native) if m[1] == name)
                method = re.sub(r'\brng\b', 'lab_visual_rng', method)
                for called in HELPERS:
                    method = re.sub(r'\b' + called + r'\(', 'lab_visual_' + called + '(', method)
                added += '\n' + method
            added += '''
func lab_visual_shuffle(array):
	for i in range(array.size() - 1, 0, -1):
		var j = lab_visual_rng.randi_range(0, i)
		var hold = array[i]
		array[i] = array[j]
		array[j] = hold
'''
            result += added
        if result != original:
            name = 'Cosmetic_' + leaf.replace('/', '__')
            (patched / (name + '.gd')).write_text(result, encoding='utf-8')
            overrides[path] = name
    (patched / 'cosmetic-random-audit.json').write_text(json.dumps(audit, indent=2), encoding='utf-8')
    return overrides
