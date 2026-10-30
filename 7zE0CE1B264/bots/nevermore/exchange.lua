--[[
 EXCHANGE — the truth about a Shadow Fiend mirror exchange, as a pure function.
 (v6.3 "exchange truth")

 The measured ledger of replay 9066921447 (24 exchange episodes, bot vs human)
 says where the bot lost the lane:

   * the bot TOOK 3470 raze damage and DEALT 3657 — the totals are equal, the
     *structure* was not: in five of the six worst episodes (t=344.5, 363.0,
     448.7, 485.6, 299.6) the bot had 274-423 mana and 2-3 razes off cooldown
     and still cast nothing, while the human landed one or two razes on it.
   * every single bot win came when the human was OUT of mana
     (22, 29, 63, 18, 111 mana) — the bot only ever fires at a target that
     physically cannot answer, because the old trade policy asked exactly that:
     `want = (hisReady == 0)`.

 This module replaces that question with the one a player asks:
 "if I open now, what do I put into him and what does he put into me?"
 Raze damage is computed per band with a graded hit probability and the
 per-stack escalation (measured 184 -> 230 = +25 % per extra stack).

 Pure Lua: no game API, so it can be replayed against a decoded demo.
]]

local X = {}

X.C = {
    BANDS        = { 200, 450, 700 },   -- KV: shadowraze radii along the facing
    RADIUS       = 250,
    CAST         = 0.55,                -- KV AbilityCastPoint
    CD           = 9.0,
    MANA         = 75,
    MS           = 305,
    WINDOW       = 2.2,                 -- s: the forecast horizon of one exchange
    REACH        = 950,                 -- band 3 outer edge: no raze reaches past it
    -- measured on 46 hero-hit razes of 9066921447: 132 -> 168 and 184 -> 230
    STACK_MUL    = 0.25,                -- +25 % raze damage per extra stack on the target
    -- s between right-clicks. Measured on 9066921447: median 1.13 s over the
    -- whole lane, but 0.69 s inside a committed kill window (8 swings in 5.5 s
    -- at 518.7 finished the bot from 622 HP). The forecast uses the *burst*
    -- cadence - an exchange is a burst, not a lane average.
    ATK_INTERVAL = 0.75,
    SUSTAIN      = 5.5,                 -- s: the horizon at which sustained DPS decides
    SUSTAIN_PAD  = 0.80,                -- we must survive his sustain with this reserve
    PANIC_HP     = 0.22,                -- below this share of HP nothing is an opening
    PANIC_HP_BRAWL = 0.35,              -- ... and in a manaless brawl, this one
    ATK_REACH    = 550,                 -- attack range + hull + a step during the window
    -- Our own T1 shooting HIM is free damage that the exchange must count, and
    -- his T1 shooting us is exactly the opposite. Measured (both replays of
    -- 2026-10-29): he took 822 tower damage diving our T1 and paid nothing for
    -- it, because the gate never looked at `own_tower`.
    TOWER_DPS    = 88,                  -- applied ~66-78 every 0.82 s
    TOWER_TRUST  = 0.70,                -- only the shots that can land inside the window
    -- Standing in his creep wave is damage too: 87 creep hits for 1046 damage in
    -- one 6-minute game is 25 % of everything the bot took.
    CREEP_TOL    = 0.16,                -- creeps alone may eat at most this share of HP per window
    -- when neither side can raze, the fight is right-clicks + creeps + towers
    BRAWL_EDGE   = 1.15,
    -- refuse an even exchange unless the net is at least this share of his burst
    -- Cross-validated on two replays (9066921447 and auto-20261029-1756): at
    -- 0.30 the gate opened one exchange that lost 138 HP, at 0.45 it refuses
    -- every losing exchange in both files. The price is 3 won exchanges left on
    -- the table (~740 damage of upside) - the asymmetry is deliberate: a lost
    -- exchange costs HP, position and often the lane, a skipped one costs farm.
    ENTER_MARGIN = 0.45,
    -- ... but when OUR tower is shooting him the bar drops: he is tanking a
    -- tower to fight us, and that pressure does not end with the window. The
    -- 2026-10-29 game was lost exactly here - he dived our T1 for 822 tower
    -- damage and the bot answered nothing.
    ENTER_MARGIN_TOWER = 0.10,
    MIN_P        = 0.10,               -- a raze below this hit chance is not worth the mana
    -- A player who *means* to trade closes the distance first (measured: the
    -- human started t=363.0 at 654 u and landed both razes from ~450). The
    -- forecast therefore also evaluates the exchange after he has walked in.
    CLOSE_STEP   = 175,                -- u closed per step of the forecast
    CLOSE_STEPS  = 2,
    -- below this share of HP a "trade" has to be a kill or nothing
    PANIC_HP_PCT = 0.30,
}

--------------------------------------------------------------------------------
-- hit probability of one raze on a target at `dist`
--------------------------------------------------------------------------------
--[[ A raze is a circle of radius 250 at 200/450/700 units along the facing when
     the cast ENDS (0.55 s). A target that is free to move covers ms*CAST = 168 u
     in that time; a target locked in its own attack windup or cast covers
     nothing. `slack` is what is left of the circle after his escape. ]]--
function X.Slack(dist, band, escape)
    return X.C.RADIUS - math.abs(dist - band) - escape
end

function X.HitProb(slack)
    if slack >= 60 then return 0.95 end
    if slack >= 0 then return 0.75 end
    if slack >= -80 then return 0.45 end
    if slack >= -160 then return 0.20 end
    return 0.03
end

--[[ Damage one full volley would put into the victim.
     u = {x,y,ms,rlvl,dmg,mana,mana_regen,cd={r1,r2,r3},souls}
     Returns expected damage, number of razes that can physically be cast,
     and the list of per-raze probabilities. ]]--
function X.Volley(u, v, dist, opts)
    opts = opts or {}
    local C = X.C
    if not u or not u.rlvl or u.rlvl <= 0 then return 0, 0, {} end
    local escape = opts.escape or math.max(0, (v.ms or C.MS) * C.CAST)
    local per = u.raze_dmg or X.RazeDamage(u.rlvl, v.souls or 0)
    local mana = (u.mana or 0) + (u.mana_regen or 0) * C.WINDOW
    local total, n, probs = 0, 0, {}
    local hit = 0
    for i = 1, 3 do
        local cd = (u.cd and u.cd[i]) or 0
        -- a band that cannot physically land is not cast, so it does not spend
        -- mana either: the caster picks the band, not the cooldown list
        local p = X.HitProb(X.Slack(dist, C.BANDS[i], escape))
        if cd <= C.WINDOW and mana >= C.MANA and p > C.MIN_P then
            mana = mana - C.MANA
            n = n + 1
            local d = per * math.pow(1 + C.STACK_MUL, hit)
            total = total + d * p
            hit = hit + 1
            probs[#probs + 1] = { band = i, p = p, dmg = d }
        end
    end
    return total, n, probs
end

--[[ KD/KV damage of one raze: 75/150/225/300 base + 2 per soul,
     25 % magic resistance. Calibrated against 46 recorded hero hits:
     L1 62-75, L2 128-138, L3 181-184, L4 230. ]]--
function X.RazeDamage(level, souls)
    local base = ({ 75, 150, 225, 300 })[level] or 75
    return (base + 2 * (souls or 0)) * 0.75
end

--------------------------------------------------------------------------------
-- the forecast
--------------------------------------------------------------------------------
--[[ st = {
       dist, locked (his cast/animation left, seconds),
       me  = { hp,hp_max,mana,mana_regen,ms,dmg,rlvl,raze_dmg,cd={..},souls },
       him = { ... same ... },
       creep_dps_on_me, creep_dps_on_him
     } ]]--
function X.Forecast(st)
    local C = X.C
    local me, him = st.me, st.him
    local dist = st.dist
    local escMe  = (me.cast_left and me.cast_left > 0.1) and 0 or
                   math.max(0, (me.ms or C.MS) * C.CAST)
    local escHim = (st.locked and st.locked > 0.1) and 0 or
                   math.max(0, (him.ms or C.MS) * C.CAST)

    local my_rz, my_n, my_p, my_d = 0, 0, {}, dist
    local his_rz, his_n, his_p, his_d = 0, 0, {}, dist
    for k = 0, C.CLOSE_STEPS do
        local d = math.max(C.BANDS[1], dist - k * C.CLOSE_STEP)
        local a, an, ap = X.Volley(me, him, d, { escape = escHim })
        if a > my_rz then my_rz, my_n, my_p, my_d = a, an, ap, d end
        local b, bn, bp = X.Volley(him, me, d, { escape = escMe })
        if b > his_rz then his_rz, his_n, his_p, his_d = b, bn, bp, d end
    end

    -- right clicks inside the window
    local atk_me, atk_him = 0, 0
    local swings = math.max(0, math.floor(C.WINDOW / C.ATK_INTERVAL))
    if dist <= C.ATK_REACH then
        atk_me  = (me.dmg or 0)  * swings * 0.72   -- ~6 armour and a miss now and then
        atk_him = (him.dmg or 0) * swings * 0.72
    end
    -- creeps shooting whoever is closer to them (they hit the aggressor)
    local cr_me  = (st.creep_dps_on_me or 0)  * C.WINDOW
    local cr_him = (st.creep_dps_on_him or 0) * C.WINDOW

    -- towers: our T1 hitting him is ours, his T1 hitting us is his
    local tw_him = ((st.tower_on_him or 0) * C.TOWER_TRUST) * C.WINDOW
    local tw_me  = ((st.tower_on_me or 0) * C.TOWER_TRUST) * C.WINDOW

    local my_total  = my_rz  + atk_me + tw_him
    local his_total = his_rz + atk_him + cr_me + tw_me

    local f = {
        my_raze = my_rz, his_raze = his_rz,
        my_atk = atk_me, his_atk = atk_him, creep_on_me = cr_me,
        my_n = my_n, his_n = his_n, my_probs = my_p, his_probs = his_p,
        my_at_dist = my_d, his_at_dist = his_d,
        my_total = my_total, his_total = his_total,
        net = my_total - his_total,
        my_hp = me.hp, his_hp = him.hp,
        locked = (st.locked or 0) > 0.1,
    }
    -- a raze that does not land is worth nothing; count the *effective* opening
    f.my_open = (my_n > 0 and my_total > 0)
    -- is his HP inside one volley of ours? then the arithmetic does not matter
    f.lethal = (my_n > 0) and (him.hp or 1e9) <= my_total + 25

    --[[ SUSTAIN. The two deaths of 9066921447 were not raze deaths: the bot was
         killed by 7 and 8 right-clicks (380 and 629 damage) while it stood in
         his face with 16 mana and with 1 raze. A 2.2 s window cannot see that,
         so the same numbers are compared over SUSTAIN seconds as well. ]]--
    --[[ A wave that is already shooting us is damage even if he is far away; the
         first version only counted it inside attack range, which is why the bot
         was allowed to tank 87 creep hits while "holding". ]]--
    local dps_him = ((him.dmg or 0) * 0.72) / C.ATK_INTERVAL + (st.creep_dps_on_me or 0)
        + ((st.tower_on_me or 0) * C.TOWER_TRUST)
    local dps_me  = ((me.dmg or 0) * 0.72) / C.ATK_INTERVAL + (st.creep_dps_on_him or 0)
        + ((st.tower_on_him or 0) * C.TOWER_TRUST)
    f.dps_me, f.dps_him = dps_me, dps_him
    f.tower_on_him, f.tower_on_me = tw_him, tw_me
    -- brawl pressure: who wins if nobody has mana (right-clicks + creeps + towers)
    f.pressure_me  = atk_me + tw_him
    f.pressure_him = atk_him + cr_me + tw_me
    f.creep_share  = (me.hp or 1) > 0 and (cr_me / me.hp) or 0
    f.his_sustain = dps_him * C.SUSTAIN
    f.my_sustain  = dist <= C.ATK_REACH and dps_me * C.SUSTAIN or 0
    f.loses_sustain = (f.his_sustain > 0) and
                      (me.hp < f.his_sustain * C.SUSTAIN_PAD) and
                      not ((him.hp or 1e9) <= f.my_sustain + f.my_raze)
    return f
end

--------------------------------------------------------------------------------
-- the verdict
--------------------------------------------------------------------------------
--[[ Verdicts:
      "ENTER"     — open the exchange, the arithmetic is ours
      "PUNISH"    — he is locked (his own cast/animation): aim now, he cannot move
      "ANSWER"    — he just put a raze into us and can still be answered in kind
      "REFUSE"    — his burst beats ours, do not start it
      "DISENGAGE" — we cannot answer at all and he can: walk out
      "HOLD"      — nobody can do anything: farm.
 ]]--
function X.Verdict(st)
    local C = X.C
    local f = X.Forecast(st)
    local me, him = st.me, st.him
    local hp_pct = (me.hp or 1) / math.max(1, me.hp_max or 1)
    local v, why

    -- survival first: a fight we cannot survive is not an opening, whatever
    -- the arithmetic of the next two seconds says
    if hp_pct <= C.PANIC_HP then
        v, why = "DISENGAGE", "below the panic HP line: nothing is an opening"
    elseif f.loses_sustain then
        v, why = "DISENGAGE", "we lose the sustained right-click fight"
    elseif f.my_n == 0 and f.his_n == 0 then
        --[[ Neither of us can raze. This is not "nothing happens": it is a
             right-click brawl, and the creeps are a participant. Replay
             auto-20261029-1756, t = 85-97: the human stood in the wave with 10
             mana at 333 HP and killed the bot at 566 HP with 7 right-clicks
             while 22 creep hits landed on it - the bot dealt 50 damage. ]]--
        if hp_pct <= C.PANIC_HP_BRAWL and f.pressure_him > f.pressure_me then
            v, why = "DISENGAGE", "manaless brawl, and the wave is on his side"
        elseif f.pressure_me > 0 and f.pressure_me >= C.BRAWL_EDGE * math.max(1, f.pressure_him) then
            v, why = "BRAWL", "no razes left: right-clicks + creeps + tower are ours"
        elseif st.dist and st.dist > C.ATK_REACH then
            v, why = "HOLD", "both out of mana and out of reach"
        else
            v, why = "REFUSE", "no razes, and the brawl arithmetic is his"
        end
    elseif f.my_n == 0 then
        if st.dist and st.dist >= C.REACH + 50 then
            v, why = "HOLD", "out of raze reach and unable to answer: keep farming"
        else
            v, why = "DISENGAGE", "no raze of ours can land, his can"
        end
    elseif f.creep_share > C.CREEP_TOL and f.my_raze < 0.8 * math.max(1, f.his_total) then
        v, why = "REFUSE", "we are standing in his wave and cannot out-damage it"
    elseif f.his_n == 0 then
        v, why = "ENTER", "he cannot answer within the window"
    elseif f.lethal then
        v, why = "ENTER", "his HP is inside one volley of ours"
    elseif f.locked and f.my_raze > 0 then
        v, why = "PUNISH", "he is pinned in his own cast/animation"
    elseif f.net >= (f.tower_on_him > 0 and C.ENTER_MARGIN_TOWER or C.ENTER_MARGIN)
                    * math.max(1, f.his_total) then
        v, why = "ENTER", "the exchange arithmetic is ours"
    else
        v, why = "REFUSE", "his burst beats ours"
    end
    f.verdict, f.why = v, why
    return f
end

--[[ The band to cast at `dist` right now (nil if none can land). ]]--
function X.BestBand(dist, u, v, opts)
    local C = X.C
    opts = opts or {}
    local escape = opts.escape or math.max(0, (v.ms or C.MS) * C.CAST)
    local best, bestP, bestSlack = nil, -1, nil
    local mana = u.mana or 0
    for i = 1, 3 do
        local cd = (u.cd and u.cd[i]) or 0
        if cd <= (opts.window or 0.2) and mana >= C.MANA then
            local s = X.Slack(dist, C.BANDS[i], escape)
            local p = X.HitProb(s)
            -- prefer the band that lands best; on a tie the closer band (it is
            -- the one that keeps us at melee range and does not need us to back off)
            if p > bestP then best, bestP, bestSlack = i, p, s end
        end
    end
    return best, bestP, bestSlack
end


--------------------------------------------------------------------------------
-- positioning: where not to stand
--------------------------------------------------------------------------------
--[[ A Shadowraze reaches 950 u (band 700 + radius 250) and the annuli overlap:
     inside 950 there is no distance that is out of every band. What a player
     does instead is stand where the *ready* bands cannot reach, and where a
     single 0.55 s step (168 u) exits the annulus of the band that is left.

     `him` needs only cd = {r1,r2,r3}. ]]--
function X.SafeDistance(him, opts)
    opts = opts or {}
    local C = X.C
    local reach = C.BANDS[1]
    for i = 3, 1, -1 do
        local cd = (him.cd and him.cd[i]) or 0
        if cd <= (opts.window or 1.2) then
            reach = C.BANDS[i]
            break
        end
    end
    return reach + C.RADIUS + (opts.pad or 70)
end

--------------------------------------------------------------------------------
-- the reaction: dodge, answer, or eat it
--------------------------------------------------------------------------------
--[[ He is 0.55 s into his own cast and cannot move. Two legal reactions:

       dodge  — step out of the annulus: needs (RADIUS - |d - band|) <= 0.55*ms
                radially, i.e. he must be near the edge of the circle;
       answer — cast our own band at his *current* point. He is pinned, so our
                circle cannot be dodged by him either: a guaranteed hit.

     When neither is possible (we are in the middle of the circle with no raze
     ready) the only correct play is to already have been somewhere else —
     which is what X.SafeDistance is for. ]]--
function X.Reaction(dist, band, me, him, opts)
    local C = X.C
    opts = opts or {}
    local centre = C.BANDS[band] or 450
    local need = C.RADIUS - math.abs(dist - centre)
    local step = (me.ms or C.MS) * C.CAST * (opts.efficiency or 0.85)
    -- Answering is preferred: he is pinned, so our circle cannot be dodged by
    -- him, and the ledger says the missing reflex was exactly this one. Only
    -- when no band can be cast do we spend the 0.55 s on a step.
    local idx, p = X.BestBand(dist, me, him, { escape = 0, window = 0.15 })
    if idx and p >= (opts.answer_p or 0.70) then return "answer", idx, p end
    if need <= step then return "dodge", nil, 0 end
    return "eat", nil, 0
end

--------------------------------------------------------------------------------
-- the reaction to *his* cast (v6.4)
--------------------------------------------------------------------------------
--[[ Replay 5 (`auto-20261029-1756`) measured on the human's 24 razes:

       * 5 of them hit the bot while it stood COMPLETELY STILL (it moved 0-16 u
         during the cast), i.e. not "dodged too late" - not dodged at all;
       * in the two episodes that killed it (t = 389.6 and t = 512.. no:
         t = 389.6 and 452.7) it answered with nothing and simply ate 415 and
         520 raze damage.

     A raze cast by the enemy is a 0.55 s window in which HE cannot move and the
     circle is already placed. There are exactly three legal answers, in this
     order of preference:

       1. ANSWER  - cast our own raze at his current point: he is pinned, the
                    circle cannot be dodged by him either (guaranteed hit);
       2. STEP    - leave the circle: need = RADIUS - |dist - band| <= ms * t;
       3. TRADE   - eat it, but attack him back (never stand still for free).

     `lose` in the table below is the HP we cannot pay: below it we run even if
     answering was possible. ]]--
function X.React(dist, band, remaining, me, him, opts)
    opts = opts or {}
    local C = X.C
    local centre = C.BANDS[band] or 450
    local need = C.RADIUS - math.abs(dist - centre)     -- > 0: we are inside
    if need <= 0 then return "clear", nil, 0 end
    local hp_pct = (me.hp or 1) / math.max(1, me.hp_max or 1)
    local panic = opts.panic or C.PANIC_HP
    local t = math.max(0, (remaining or C.CAST) - 0.06)
    local step = (me.ms or C.MS) * t * (opts.efficiency or 0.90)

    local idx, p = X.BestBand(dist, me, him, { escape = 0, window = 0.15 })
    local can_answer = (idx ~= nil) and (p or 0) >= 0.70
    -- survival: never trade into a burst we cannot pay for
    local his_hit = him and him.raze_dmg or 160
    local broke = (hp_pct <= panic) or ((me.hp or 0) <= his_hit * 1.25)

    --[[ v6.5 - "playing from behind". Replay 6, t = 263.2 was the textbook
         mistake: HP 296/648 (46 %), he cast raze2 at 601 u, the circle needed a
         99 u step and the budget was 134 u - i.e. it was FREE to leave - and the
         answer chosen was to raze back, stay inside, and eat 185 + 232 + 185 +
         120 = 722 damage for 0 dealt. Answering is a TRADE; a trade is only
         correct when our body can pay for it. So:

           * kill him with this raze                        -> answer
           * we are HP-dominant (>= 0.55) and can answer    -> answer (he is pinned)
           * we can step out for free                       -> step
           * we can answer and it will not kill us          -> answer
           * we can only right-click                        -> trade
           * nothing helps: at least keep moving RADIALLY   -> eat (never "run
             along" his circle, which is what the recorded death did). ]]--
    local can_step = need <= step
    local can_kill = him and (him.hp or 1e9) <=
        (X.RazeDamage and X.RazeDamage(me.rlvl or 0, me.souls or 0) or 160) * 0.92
    local dominant = hp_pct >= (opts.trade_hp or 0.55)
    if can_answer and not broke and (can_kill or dominant or not can_step) then
        return "answer", nil, idx
    end
    if can_step then return "step", nil, 0 end
    if can_answer and not broke then return "answer", nil, idx end
    if me.dmg and dist <= (opts.atk_reach or C.ATK_REACH) then return "trade", nil, 0 end
    return "eat", nil, 0
end

--[[ The point to run to when leaving his circle: the shortest radial exit from
     the circle centre, padded, and biased towards `safe` (our own tower) when
     two exits are equally short. Pure geometry - the caller supplies `safe`. ]]--
function X.ExitPoint(x, y, cx, cy, need, safe, pad)
    local dx, dy = x - cx, y - cy
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 1e-3 then dx, dy, l = 1, 0, 1 end
    local ux, uy = dx / l, dy / l
    local step = need + (pad or 40)
    local px, py = x + ux * step, y + uy * step
    if safe then
        -- among the two half-planes, prefer the one that ends closer to safety
        local sx, sy = px - safe.x, py - safe.y
        local mx, my = x - ux * step - safe.x, y - uy * step - safe.y
        if math.sqrt(mx * mx + my * my) < math.sqrt(sx * sx + sy * sy) - 60 then
            px, py = x - ux * step, y - uy * step
        end
    end
    return px, py
end

--[[ Should we throw a right-click at him right now?

     Replay 5, the deficit that decided the lane: the human threw 31 hero
     right-clicks (2041 damage), the bot threw 6 (346 damage). Two deaths
     followed the same script - the human stood in front of the bot and
     right-clicked it to death (7 and 8 hits) while the bot only cast razes.

     An attack is free weight: it does not cost mana, it does not cancel a raze
     that is not being cast, and it is the only damage that scales with the
     souls the hero already has. The only reasons not to attack are:
       * he is out of range;
       * we are so low that the swing (0.5 s of standing still) is death. ]]--
function X.ShouldAttack(me, him, dist, opts)
    opts = opts or {}
    if not me or not him then return false end
    if dist > (opts.reach or (C_ATK_REACH or X.C.ATK_REACH)) then return false end
    local hp_pct = (me.hp or 1) / math.max(1, me.hp_max or 1)
    if hp_pct <= (opts.panic or X.C.PANIC_HP) then return false end
    -- do not trade swings with a full-HP enemy while we are one hit from death
    if (me.hp or 0) <= (him.dmg or 60) * (opts.min_swings or 2.0) then return false end
    return true
end

return X
