"""Worker-only presentation gates; retain native scene structure and rule clocks.

Patch locally captured source, never the installed game. Explicit method lists
and checked edits fail on unsupported source changes instead of guessing that
every Animation/Timer/Tween is cosmetic. Electrical charge callbacks are rules.
"""
import json
import re

METHOD = re.compile(r'(?m)^func (\w+)\([^\n]*\n(?:[\t ].*\n|\n)*')


def split_method(method):
    lines = method.splitlines(True)
    for i, line in enumerate(lines):
        if line.rstrip().endswith(':'):
            return ''.join(lines[:i + 1]), ''.join(lines[i + 1:])
    raise ValueError('Unsupported native method signature')


def replace_method(source, name, body):
    match = next((m for m in METHOD.finditer(source) if m[1] == name), None)
    if match is None:
        raise ValueError('Missing presentation gate: ' + name)
    header, _ = split_method(match[0])
    return source[:match.start()] + header + body.rstrip() + '\n\n' + source[match.end():]


NOOP = {
    'Items/Item': ('playPickupSound', 'playDropSound', 'playActivationSound',
                   'playActivationAnimation', 'playActivationAnimation_Scale',
                   'playActivationAnimation_Jump', 'playActivationAnimation_JumpSquash',
                   'playAnimation', 'spawnLabel', 'spawnLabel_other',
                   'showCooldown', 'showCooldownSmooth', 'updateShadow', 'popIn', 'miniActivate'),
    'Core/Character': ('playAttackAnimation', 'playActivateAnimation', 'playSound',
                       'spawnLabel', 'playStunAnimation', 'playBattleRageAnimation',
                       'randAnimationSpeed', 'onSpriteClicked', 'lose', 'win', 'levelUp'),
    'Utility/Util': ('spawnNumberLabel', 'spawnLabelOnItem', 'spawnStatLabelOnItem',
                     'spawnBuffLabel', 'spawnBuffLabel_item', 'spawnMissLabel',
                     'spawnResistedLabel', 'spawnProtectedLabel', 'spawnReflectLabel'),
    'Utility/Sound': ('playSound', 'playSound_process', 'playRising', 'playLooping',
                      'playBGM', 'playBGM_loop', 'fadeOutBGM'),
    'Utility/AutoHideParticles': ('activate', 'deactivate', 'startTimer', 'instantClear'),
    'Utility/AutoHideCPUParticles': ('activate', 'deactivate', 'startTimer', 'instantClear'),
    'Utility/TimedParticles': ('activate', 'deactivate'),
    'Items/Animations/SquishySprite': ('_physics_process', 'addMomentum'),
    'Interface/Healthbar': ('onHealthChanged', 'updateBar', 'updateNumber'),
    'Interface/Staminabar': ('_process', 'updateNumber', 'onEnteringCombat'),
    'Interface/MaxStaminaLabel': ('updateText',),
    'Interface/StaminaGainCounter': ('updateText',),
    'Interface/Combat/StackHudWithAnimation': ('activate',),
    'Interface/Textbox': ('showText', 'playSound', '_physics_process'),
    'Interface/Shopkeeper': ('say',),
    'Core/CombatLog': ('addLogLine', 'updateIdle'),
}


def remove_particle_calls(method):
    """Remove audited one-shot particle calls and their display-only writes.

    Callers often dereference the returned node, so returning null at the pool
    would crash them. Reject unfamiliar uses instead of silently dropping code.
    A pass preserves otherwise-empty branches. Mechanical neighboring lines stay.
    """
    variables = set(re.findall(r'var (\w+) = ObjectPool\.particleOneShot', method))
    lines = method.splitlines(True)
    result = []
    continuation = False
    depth = 0
    for line in lines:
        stripped = line.strip()
        if continuation:
            depth += line.count('(') - line.count(')')
            continuation = depth > 0
            continue
        if 'ObjectPool.particleOneShot(' in line:
            if not re.match(r'(?:(?:var \w+ = )?ObjectPool\.particleOneShot\()', stripped):
                raise ValueError('Unreviewed particle call: ' + stripped)
            depth = line.count('(') - line.count(')')
            continuation = depth > 0
            result.append(line[:len(line) - len(line.lstrip())] + 'pass # worker: particle entry disabled\n')
            continue
        used = [v for v in variables if re.search(r'\b' + v + r'\b', line)]
        if used:
            allowed = any(re.match(re.escape(v) + r'\.(?:position|global_position|rotation_degrees|global_rotation|scale|modulate|self_modulate|amount|z_index|process_material)(?:\.\w+)* = ', stripped) or
                          re.fullmatch(r'move_child\(' + re.escape(v) + r', 0\)', stripped) for v in used)
            if not allowed:
                raise ValueError('Unreviewed particle node use: ' + stripped)
            result.append(line[:len(line) - len(line.lstrip())] + 'pass # worker: particle property disabled\n')
        else:
            result.append(line)
    if continuation:
        raise ValueError('Unterminated particle call')
    return ''.join(result)


def patch_presentation(sources, patched, overrides):
    existing = {'res://Core/Game.gd': 'Game', 'res://Core/Character.gd': 'Character',
                'res://Utility/Util.gd': 'Util', 'res://Core/RunDatabase.gd': 'RunDatabase',
                'res://Items/Item.gd': 'Item',
                'res://Interface/CombatTimer/CombatTimer.gd': 'CombatTimer'}
    existing.update(overrides)
    audit = []
    for path, native in sources.items():
        leaf = path[6:-3]
        original = (patched / (existing[path] + '.gd')).read_text(encoding='utf-8') if path in existing else native
        result = original

        def gate(name, body='\tpass'):
            nonlocal result
            result = replace_method(result, name, body)
            audit.append({'script': path, 'method': name, 'change': 'entry gate'})

        def edit(old, new):
            nonlocal result
            if result.count(old) != 1:
                raise ValueError('Presentation boundary changed: ' + path + ' ' + old[:70])
            result = result.replace(old, new, 1)
            audit.append({'script': path, 'change': 'mixed method display block', 'anchor': old.splitlines()[0]})

        for name in NOOP.get(leaf, ()):
            gate(name)
        if leaf == 'Items/Item':
            gate('playOutOfStaminaAnimation', '\tif ownerType == Owner.PlayerInventory:\n\t\tGame.numTimesOutOfStamina += 1')
            method = next(m[0] for m in METHOD.finditer(result) if m[1] == 'activate')
            begin = method.index('\tif not isBag():\n\t\tz_index = 3')
            end = method.index('\treturn event', begin)
            edit(method[begin:end], '')
        if leaf == 'Core/Character':
            gate('playInvulnerableAnimation', '\tinvulBubbleVisible = invu')
            for name in ('randDmgNumberPos', 'randHealNumberPos', 'randDmgNumberDir', 'randBuffLabelPos'):
                gate(name, '\treturn Vector2.ZERO')
            result, count = re.subn(r'\t\tif damageAnimation.current_animation != "Poison":\n(?:\t\t\t[^\n]*\n|\t*\n)*', '', result)
            if count != 1:
                raise ValueError('Character hit animation boundary changed')
        if leaf == 'Interface/Combat/BlockHud':
            gate('updateHud', '\tprevValue = value')
        if leaf == 'Core/CombatLog':
            # events/statLoggers are consumed by Statistics; RichTextLabel rows
            # and their delayed UI queue are not. Never disable the logger.
            gate('logEvent', '\tif Game.fightEnded and not afterFightAllowed: return\n\teventsLogged += 1\n\tevents.push_back(event)')
            edit('\tObjectPool.prepare(logLineScene, 1000)\n', '')
        if leaf == 'Items/Animations/SquishySprite':
            gate('init', '\tset_physics_process(false)')
        if leaf in ('Items/FalconBlade', 'Items/RubyChonk'):
            method = next(m[0] for m in METHOD.finditer(result) if m[1] == 'doCooldownEffect')
            edit(method[method.index('\t\tvar ani = createAnimation()'):], '\n')
        if leaf == 'Items/ElectricalCharge':
            # The SceneTreeTween remains the native idle-clock scheduler. Keep
            # addition order and both half-step additions (float rounding too).
            gate('preset', '\tGame.connect("combat_end", self, "onCombatEnded")')
            gate('start', '''\tduration = _duration
\tcells = _cells
\temitterItem = _item
\ttween = Util.refreshTween(tween)
\ttween.set_parallel()
\tvar cellCenters = emitterItem.getGlobalPointsForCells(cells)
\tinventoryCells = emitterItem.inventory.getCellsForGlobalPositions(cellCenters)
\tvar halfCellDur = 0.5 * duration / (cells.size() - 1)
\tvar delay = 0.0
\tfor i in cells.size() - 1:
\t\tif i == 0 and not replaying:
\t\t\tonNewCellEntered(1)
\t\tdelay += halfCellDur
\t\tdelay += halfCellDur
\t\tif not replaying:
\t\t\ttween.tween_callback(self, "onNewCellEntered", [i + 2]).set_delay(delay)
\tif not replaying:
\t\ttween.tween_callback(self, "returnToObjectPool").set_delay(duration)''')
            gate('returnToObjectPool', '''\tUtil.killTween(tween)
\tlastChargedItem = null
\tcurChargedItem = null
\temitterItem = null
\tObjectPool.returnInstance(self)
\tchargedTileVisible = false''')
            for name in ('moveParticlesToCell', 'disappear', 'deactivateParticles'):
                gate(name)
        if leaf in ('Items/ElectricalCharge', 'Items/Exclusive/ThunderDrake'):
            result, count = re.subn(r'(?m)^(\t+)if (?:curChargedItem|item).hasOnChargeReceivedEffect:\n(?:\1\t[^\n]*\n|\s*\n)*', '', result)
            if count != 1:
                raise ValueError('Charge visual boundary changed: ' + leaf)
        if leaf == 'Items/Exclusive/TeslaCoil':
            edit('\t\t\tvar zap = ObjectPool.instance(Util.zapScene)\n\t\t\tget_parent().add_child(zap)\n\t\t\tzap.zap(specificDragParticles[0].global_position, item.global_position)\n', '')
        if leaf == 'Items/ManaOrb':
            edit('\t\tvar pulse = ObjectPool.instance(activationPulse)\n\t\tadd_child(pulse)\n\t\tvar ani = pulse.get_node("AnimationPlayer")\n\t\tani.play("Activate")\n', '')
        if leaf == 'Items/Exclusive/TimeDilator':
            edit('\tvar ani = ObjectPool.instance(timeDilatorAni)\n\tget_parent().add_child(ani)\n\tani.global_position = slowestItem.global_position\n\tani.z_index = z_index + 2\n', '')
        if leaf == 'Items/Exclusive/AmuletofAlchemy':
            edit('\t\tvar ani = ObjectPool.instance(triggerAnimation)\n\t\tget_parent().add_child(ani)\n\t\tani.global_position = global_position\n\t\tani.moveTo(potion.global_position, delay)\n', '')
        if leaf == 'Interface/CombatTimer/CombatTimer':
            gate('startFatigue', '\tfatigueCounter = 0\n\tfatigueTickTimer.start(3)')
            method = next(m[0] for m in METHOD.finditer(result) if m[1] == 'dealFatigueDamage')
            start = method.index('\tfatigueAnimation.play("Tick")')
            stop = method.index('\tfatigueTickTimer.start(1)', start)
            edit(method[start:stop], '')

        # All direct one-shot uses in item scripts were checked: the returned
        # particle only receives transform/color writes, never rule state.
        if leaf.startswith('Items/'):
            for match in list(METHOD.finditer(result))[::-1]:
                if 'ObjectPool.particleOneShot(' in match[0]:
                    changed = remove_particle_calls(match[0])
                    result = result[:match.start()] + changed + result[match.end():]
                    audit.append({'script': path, 'method': match[1], 'change': 'particle calls only'})
        if result != original:
            name = 'Quiet_' + leaf.replace('/', '__')
            (patched / (name + '.gd')).write_text(result, encoding='utf-8')
            overrides[path] = name
    (patched / 'presentation-gates-audit.json').write_text(json.dumps(audit, indent=2), encoding='utf-8')
    return overrides
