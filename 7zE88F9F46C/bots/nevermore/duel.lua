--
-- duel.lua — Combat Director for SF vs SF solo mid (v5.0).
--
-- WHY THIS EXISTS (see REPORT_RU.md):
--   The old architecture ran L.RunSacredCS before almost every trade / retaliation handler and returned whenever a
--   last hit was within a 1.8 s horizon. In a contested wave that is ~always, so the bot stood still last-hitting
--   while the human right-clicked and razed it for free (G2 2:30-2:50: 9 hero hits taken, 0 given, 448 -> 3 HP).
--   Kill windows were missed (G3 0:46 enemy at 42 HP, G1 6:25 enemy 260-286 HP vs our Q, G2 7:34 enemy 265 HP),
--   hopeless fights were started (G1 4:51), and retreats ended in the wrong place (G2 4:40, G3 7:00).
--
-- WHAT IT DOES:
--   1. Snapshot: both heroes (HP, mana, regen, physical damage after armor, attack timing, raze levels, cooldowns,
--      stacks, souls, Faerie Fire / Stick / Mango), towers (865 aggro radius, creep shield), creep aggro.
--   2. Rollout simulator (0.1 s steps, 8 s horizon): plays a pair of macro policies (one per hero) with the real
--      mechanics that decide early SF duels: raze cast point + facing + hit circle, raze stacks (6 s), mana, cooldowns,
--      right-click attack point / projectile / interval, kiting at equal speed, tower aggro and creep aggro,
--      Faerie Fire / Stick emergency heals.
--   3. Game-theoretic choice: every bot policy is scored against every enemy response (robust minimax:
--      0.7 * worst + 0.3 * average); the best policy is executed with hysteresis and a kill lock.
--   4. Execution: raze band positioning (centers 200/450/700, radius 250), facing, attack hero between last hits,
--      leash at enemy tower, retreat geometry (behind own tower or deep when a dive is lethal), spacing for the CS
--      layer (D.SpacingBlocks is consulted by lasthit.lua).
--
-- The core (D.Simulate / D.Evaluate) works on plain tables and pure math, so it is tested outside Dota
-- (tests/run_replay_cases.lua, tests/duel_sim.lua).

local D = {}
D.VERSION = "director-5.1"

-- 7.41f values (patch notes, verified against the three replays: L1 raze 63-64 after 25% resist = 85 raw,
-- 1-stack 88-92 = 120 raw). In game the API values (GetSpecialValueInt) take precedence.
D.P = {
    RAZE_CENTERS = { 200, 450, 700 },
    RAZE_RADIUS  = 250,
    RAZE_CAST    = 0.55,
    RAZE_MANA    = 75,
    RAZE_CD      = 9.0,   -- measured in all three replays at raze levels 1-3
    RAZE_BASE    = { 85, 150, 215, 280 },
    RAZE_STACK   = { 35, 50, 65, 80 },
    PER_SOUL     = 2,
    STACK_DUR    = 6.0,
    TOWER_AGGRO  = 865,   -- user-confirmed: the enemy tower starts shooting the bot from 865
    TOWER_HIT    = 76,    -- measured 60-81 per shot on L3-L7 SF (armor included)
    TOWER_INT    = 0.85,  -- measured median 0.75-0.87 s
    TOWER_FOCUS  = 2.0,   -- hitting an enemy hero under his tower draws the tower for ~2 s
    CREEP_AGGRO_R = 500,
    CREEP_AGGRO_T = 2.3,
    CREEP_HIT_MELEE = 13, -- measured vs SF
    CREEP_HIT_RANGED = 9.4,
    PROJ_SPEED   = 1200,
    DT           = 0.1,
    HORIZON      = 8.0,
    FF_HEAL      = 85,
    DODGE        = 35,    -- a human sidesteps ~35u during a raze cast point
    -- v5.2 lane economy (G5: human 52 LH + 21 DN vs bot 6 + 0 in 5:20 while the bot won both fights; the v5.1 value
    -- function had no notion of creeps, so "stand 1010 u from him" (KITE) always beat "stand at the wave" (FARM)).
    CS_LH        = 40,    -- HP-equivalent of one last hit (~40 gold + XP lead)
    CS_DN        = 20,    -- HP-equivalent of one deny (his lost gold + half XP)
    CS_REACH     = 45,    -- slack over attack range for a CS credit in the simulator
    CS_LOOK      = 4.0,
    DIP_LEAD     = 0.7,
    DIP_TICKS    = 12,    -- executor: allow the dip when the creep opens <= 0.4 s after our hit could land
    DIP_MAX_TICKS = 50,   -- ... and the hit (walk + turn + swing + flight) takes <= 1.67 s   -- v5.2 CS dip: enter his reach this long (+ walk time) before the creep opens, leave after   -- a farming hero walks to the CS spot that opens within this many seconds
    CS_FORECAST  = 16.0,  -- creeps opening after the horizon are credited by end-of-horizon position (x CS_LATE)
    CS_LATE      = 0.6,
    HP_SPARE_W   = 0.6,   -- weight of HP lost far above his kill-burst (it regenerates and changes no kill race)
}

local P = D.P
local sqrt, abs, max, min, floor = math.sqrt, math.abs, math.max, math.min, math.floor

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

-- ===================================================================================================================
-- PURE CORE
-- ===================================================================================================================
-- Hero table (plain):
--   x,y hp mhp hpr mp mmp mpr dmg aint apt rng spd lvl rzLvl rzCd{3} rzBase rzStack souls perSoul magMult
--   st stRem (raze stacks ON THIS hero and remaining time) ff stick mango
--   towerX towerY towerShield (enemy tower that shoots this hero, shield = this hero's creeps tank it)
--   creepX creepY creepN creepDps (enemy creep cluster that aggroes this hero when it hits the enemy hero)
--   safeX safeY deepX deepY (own tower spot / deep retreat point)
--   human (bool) — dodges a bit, reacts with FF

local function copyHero(h)
    local c = {}
    for k, v in pairs(h) do c[k] = v end
    c.rzCd = { h.rzCd[1], h.rzCd[2], h.rzCd[3] }
    return c
end

-- raw raze damage that `a` deals to `b` right now (b's stacks), after b's magic resistance
local function razeDmg(a, b)
    if (a.rzLvl or 0) <= 0 then return 0 end
    local st = (b.stRem or 0) > 0 and (b.st or 0) or 0
    return (a.rzBase + st * a.rzStack + (a.souls or 0) * (a.perSoul or P.PER_SOUL)) * (b.magMult or 0.75)
end
D.RazeDmg = razeDmg

local function canRaze(a, i)
    return (a.rzLvl or 0) > 0 and a.rzCd[i] <= 0 and a.mp >= P.RAZE_MANA and not a.silenced
end

-- effective HP including emergency heals the hero will certainly use
local function effHp(h)
    local hp = h.hp
    if (h.hiddenMhp or 0) > 0 and h.mhp > 0 then hp = hp * (h.mhp + h.hiddenMhp) / h.mhp end
    return hp + (h.ff or 0) * P.FF_HEAL + (h.stick or 0) * 15
end
D.EffHp = effHp

-- ---------------------------------------------------------------------------------------------------------------
-- Policies. Each returns an intent: {kind="raze", i=idx} | {kind="atk"} | {kind="move", x=, y=} | {kind="stop"}
-- ---------------------------------------------------------------------------------------------------------------
local POL = {}

-- predicted distance from a to b after `dt` seconds given b's current velocity
local function predDist(a, b, dt)
    local bx = b.x + (b.vx or 0) * dt
    local by = b.y + (b.vy or 0) * dt
    return dist(a.x, a.y, bx, by), bx, by
end

local function bestRaze(a, b, tol)
    local d = predDist(a, b, P.RAZE_CAST)
    local bi, be = nil, 1e9
    for i = 1, 3 do
        if canRaze(a, i) then
            local e = abs(d - P.RAZE_CENTERS[i])
            if e < be then be, bi = e, i end
        end
    end
    return bi, be, d
end

local function moveToward(a, x, y, keep)
    return { kind = "move", x = x, y = y }
end

local function pointFrom(bx, by, ax, ay, r)
    -- point at distance r from b on the b->a ray
    local dx, dy = ax - bx, ay - by
    local l = sqrt(dx * dx + dy * dy)
    if l < 1 then dx, dy, l = 1, 0, 1 end
    return bx + dx / l * r, by + dy / l * r
end

local function inEnemyTower(h, x, y)
    if not h.towerX then return false end
    return dist(x or h.x, y or h.y, h.towerX, h.towerY) <= P.TOWER_AGGRO
end

local function allinCore(a, b, ctx, leash)
    if b.hp <= 0 then return { kind = "stop" } end
    local d = dist(a.x, a.y, b.x, b.y)
    local tol = P.RAZE_RADIUS - 90 - (b.human and P.DODGE or 0)
    local bi, be = bestRaze(a, b, tol)
    -- lethal right-click in range beats everything
    if d <= a.rng and a.atkReady <= 0 and b.hp <= a.dmg then return { kind = "atk" } end
    if bi and be <= tol then return { kind = "raze", i = bi } end
    -- dive exception only for an immediate kill: enemy inside a ready band (or in hand range) and dies to it
    local killWindow = (bi and be <= tol + 60 and effHp(b) <= razeDmg(a, b))
        or (d <= a.rng + 60 and b.hp <= a.dmg)
    local it
    if bi then
        -- move into the band of the best ready raze
        local c = P.RAZE_CENTERS[bi]
        if d <= a.rng and a.atkReady <= 0 and abs(d - c) < 120 then it = { kind = "atk" }
        else
            local tx, ty = pointFrom(b.x, b.y, a.x, a.y, c)
            it = { kind = "move", x = tx, y = ty }
        end
    elseif d <= a.rng then
        if a.atkReady <= 0 then it = { kind = "atk" }
        elseif d > a.rng * 0.8 then it = { kind = "move", x = b.x, y = b.y } -- stay glued to a runner
        else it = { kind = "stop" } end
    else
        it = { kind = "move", x = b.x, y = b.y }
    end
    -- Leash: attacking a hero while WE stand inside the enemy tower radius draws the tower regardless of creep shield
    -- (spells do not). Our own position never enters 865 unless the kill is immediate.
    if leash and not killWindow and a.towerX then
        local R = P.TOWER_AGGRO + 25
        local myD = dist(a.x, a.y, a.towerX, a.towerY)
        if myD <= R - 10 then
            local sx, sy = pointFrom(a.towerX, a.towerY, a.x, a.y, R + 50)
            return { kind = "move", x = sx, y = sy }
        end
        if it.kind == "move" then
            local dx, dy = it.x - a.x, it.y - a.y
            local l = sqrt(dx * dx + dy * dy)
            if l > 1 then
                local step = min(l, a.spd * P.DT)
                local nx, ny = a.x + dx / l * step, a.y + dy / l * step
                if dist(nx, ny, a.towerX, a.towerY) <= R then
                    if d <= a.rng and a.atkReady <= 0 then return { kind = "atk" } end
                    return { kind = "stop" }
                end
            end
        end
    end
    return it
end
POL.ALLIN = function(a, b, ctx) return allinCore(a, b, ctx, false) end
POL.ALLIN_LEASH = function(a, b, ctx) return allinCore(a, b, ctx, true) end

local pokeManaOK, kiteNeed -- v5.2 forward declarations (defined after threatRange)

-- v5.2: where a farming hero stands for the next creep that opens within CS_LOOK s: on his own side of it,
-- at attack range - 80. `need` (optional) keeps the spot outside a circle around the enemy (spaced farming).
-- ctx.cs entries: { t, x, y, k = "lh" (creep of B's team: A last-hits, B denies) | "dn" (A's creep) }
local function farmSpot(a, b, ctx, need)
    local cs = ctx.cs
    if not cs then return nil end
    local best, bt = nil, 1e9
    for _, e in ipairs(cs) do
        if not e.done and e.t >= ctx.t - 0.2 and e.t <= ctx.t + P.CS_LOOK then
            local mine = (a.side == "A") == (e.k == "lh")
            local key = e.t + (mine and 0 or 0.8) -- last hits before denies
            if key < bt then bt, best = key, e end
        end
    end
    if not best then return nil end
    local sx, sy = a.safeX or a.x, a.safeY or a.y
    local tx, ty = pointFrom(best.x, best.y, sx, sy, max(60, a.rng - 80))
    if dist(a.x, a.y, best.x, best.y) <= a.rng - 20 then tx, ty = a.x, a.y end
    if need and dist(tx, ty, b.x, b.y) < need then tx, ty = pointFrom(b.x, b.y, tx, ty, need) end
    if dist(a.x, a.y, tx, ty) < 30 then return nil end
    return tx, ty
end

-- v5.2: the creep a spaced farmer must dip for right now: opens within walk time + DIP_LEAD. Returns the attack spot,
-- false when already in range (hold still and hit), nil when no dip is due.
local function dipSpot(a, ctx)
    local cs = ctx.cs
    if not cs then return nil end
    local best, bk, bd = nil, 1e9, 0
    for _, e in ipairs(cs) do
        if not e.done and e.t >= ctx.t - 0.1 then
            local de = dist(a.x, a.y, e.x, e.y)
            local walk = max(0, de - (a.rng - 20)) / max(200, a.spd or 300)
            if e.t - ctx.t <= walk + P.DIP_LEAD and walk <= 1.5 then
                local mine = (a.side == "A") == (e.k == "lh")
                local key = e.t + (mine and 0 or 0.8)
                if key < bk then bk, best, bd = key, e, de end
            end
        end
    end
    if not best then return nil end
    if bd <= a.rng - 20 then return false end
    return pointFrom(best.x, best.y, a.x, a.y, a.rng - 40)
end
D.DipSpot = dipSpot

-- Hits back with razes only when the target sits well inside a band; otherwise farms (v5.2: walks to the wave).
local function farmReply(a, b, ctx, replyOnly)
    local tol = P.RAZE_RADIUS - 110 - (b.human and P.DODGE or 0)
    if not replyOnly or (ctx.t - (a.lastHitByEnemy or -99)) <= 1.2 then
        local bi, be = bestRaze(a, b, tol)
        if bi and be <= tol then return { kind = "raze", i = bi } end
    end
    -- answer right-clicks only when the enemy actively trades with hands and stands in range
    if a.replyHands and (ctx.t - (a.lastHitByEnemyAtk or -99)) <= 1.5 then
        local d = dist(a.x, a.y, b.x, b.y)
        if d <= a.rng and a.atkReady <= 0 then return { kind = "atk" } end
    end
    local fx, fy = farmSpot(a, b, ctx, nil)
    if fx then return { kind = "move", x = fx, y = fy } end
    return { kind = "stop" }
end

-- FARM is reactive (the director re-plans every 0.1 s): once the enemy commits on us (hit in the last 2 s while he is
-- close) we answer by kiting toward our side; until then we only reply to razes in band.
local function committedOn(a, b, ctx)
    local last = max(a.lastHitByEnemy or -99, a.lastHitByEnemyAtk or -99)
    return (ctx.t - last) <= 2.0 and dist(a.x, a.y, b.x, b.y) <= 1000
end

POL.FARM = function(a, b, ctx)
    if committedOn(a, b, ctx) then return POL.PULL(a, b, ctx) end
    return farmReply(a, b, ctx, true)
end

-- Fires every raze that fits now, then keeps farming (does not walk for bands).
POL.POKE = function(a, b, ctx)
    local tol = P.RAZE_RADIUS - 100 - (b.human and P.DODGE or 0)
    local bi, be = bestRaze(a, b, tol)
    if bi and be <= tol and pokeManaOK(a, b, (ctx.t - (a.lastHitByEnemy or -99)) <= 1.5) then return { kind = "raze", i = bi } end
    if committedOn(a, b, ctx) then return POL.PULL(a, b, ctx) end
    return farmReply(a, b, ctx, true)
end

local function threatRange(of)
    -- how far `of` can hurt within ~1 s
    local r = of.rng + 60
    if (of.rzLvl or 0) > 0 and of.mp >= P.RAZE_MANA then
        for i = 3, 1, -1 do
            if of.rzCd[i] <= 1.0 then r = max(r, P.RAZE_CENTERS[i] + P.RAZE_RADIUS + 40); break end
        end
    end
    return r
end
D.ThreatRange = threatRange

-- v5.2: reach of his SECOND farthest ready raze (his combo reach). With spare HP a single far raze (e, 118-138 at
-- L3-5) is an acceptable price for standing at the wave; two razes + hands are not.
local function comboRange(of)
    local r = of.rng + 60
    if (of.rzLvl or 0) > 0 and of.mp >= 2 * P.RAZE_MANA then
        local seen = 0
        for i = 3, 1, -1 do
            if of.rzCd[i] <= 1.0 then
                seen = seen + 1
                if seen == 2 then r = max(r, P.RAZE_CENTERS[i] + P.RAZE_RADIUS + 40); break end
            end
        end
    end
    return min(r, threatRange(of))
end
D.ComboRange = comboRange

local function burstOf(x, y)
    local n = min(3, floor((x.mp or 0) / P.RAZE_MANA))
    return n * razeDmg(x, y) + 2 * (x.dmg or 50)
end
D.BurstOf = burstOf

-- spacing radius used by KITE (simulator and executor): full threat when low or without spare HP, combo reach
-- when our HP minus his whole burst still leaves >= 250 (G5: 824-874/874 HP vs his 330+ mana, 3 minutes at 1000+ u)
kiteNeed = function(a, b)
    local lowHp = a.hp < razeDmg(b, a) * 2 + b.dmg * 2
    if lowHp then return threatRange(b) + 120, true end
    if a.hp - burstOf(b, a) >= 250 then return comboRange(b) + 20, false end
    return threatRange(b) + 20, false
end
D.KiteNeed = kiteNeed

-- v5.2 mana discipline for non-lethal pokes: keep one raze as a threat (legacy H.HarassManaOK did this, the Director
-- bypassed it: G5 the bot poked at 780-900 u, got the reply and sat at 10-90 mana while he farmed with 330+)
pokeManaOK = function(a, b, replying)
    if a.mp - P.RAZE_MANA >= ((a.lvl or 1) <= 2 and 150 or ((a.lvl or 1) <= 4 and 112 or 75)) then return true end
    if b.mp < 2 * P.RAZE_MANA then return true end            -- he cannot punish a dry bot with a combo
    if replying then return true end                           -- answering his raze keeps the HP parity
    if effHp(b) <= razeDmg(a, b) + a.dmg * 2 then return true end -- near-kill
    return false
end
D.PokeManaOK = pokeManaOK

POL.KEEPOUT = function(a, b, ctx)
    local d = dist(a.x, a.y, b.x, b.y)
    local need = threatRange(b)
    if d < need then
        local tx, ty = pointFrom(b.x, b.y, a.x, a.y, need + 80)
        -- bias toward own side
        if a.safeX then
            tx = tx * 0.6 + a.safeX * 0.4
            ty = ty * 0.6 + a.safeY * 0.4
        end
        return { kind = "move", x = tx, y = ty }
    end
    -- v5.2: outside his reach the CS layer keeps farming (same as the executor)
    local fx, fy = farmSpot(a, b, ctx, need + 60)
    if fx then return { kind = "move", x = fx, y = fy } end
    return { kind = "stop" }
end

-- Pull the fight to our side: walk toward our safe spot, turn for a raze when the chaser enters a band,
-- hit him when he is in hand range and our attack is ready. A chaser eats our creep/tower aggro.
-- (v5.2: this is the reaction of FARM/POKE to a commit; the KITE policy itself is "farm outside his reach".)
POL.PULL = function(a, b, ctx)
    local d = dist(a.x, a.y, b.x, b.y)
    local tol = P.RAZE_RADIUS - 100 - (b.human and P.DODGE or 0)
    local bi, be = bestRaze(a, b, tol)
    if bi and be <= tol then return { kind = "raze", i = bi } end
    if d <= a.rng - 30 and a.atkReady <= 0 then return { kind = "atk" } end
    local tx, ty = a.safeX or a.x, a.safeY or a.y
    if dist(a.x, a.y, tx, ty) < 60 then
        if d <= a.rng and a.atkReady <= 0 then return { kind = "atk" } end
        return { kind = "stop" }
    end
    return { kind = "move", x = tx, y = ty }
end

-- v5.2 KITE = exactly what the executor does: raze/hit when it fits, otherwise farm with the spacing radius
-- (his threat range + 20, + 120 when low) and step out when inside it. v5.0-5.1 simulated KITE as "walk to the tower",
-- which hid its real cost (no creeps) and its real risk.
POL.KITE = function(a, b, ctx)
    local d = dist(a.x, a.y, b.x, b.y)
    local tol = P.RAZE_RADIUS - 100 - (b.human and P.DODGE or 0)
    local bi, be = bestRaze(a, b, tol)
    if bi and be <= tol and pokeManaOK(a, b, (ctx.t - (a.lastHitByEnemy or -99)) <= 1.5) then return { kind = "raze", i = bi } end
    if d <= a.rng - 30 and a.atkReady <= 0 then return { kind = "atk" } end
    local need, lowHp = kiteNeed(a, b)
    -- v5.2 CS dip (G5: LH 6 vs 31 - the bot stood at 1000+ and never walked in): with spare HP the spaced farmer
    -- enters for a creep only when the hit has to start now and walks out right after it, the way the human does
    if not lowHp then
        local dx, dy = dipSpot(a, ctx)
        if dx then return { kind = "move", x = dx, y = dy } end
        if dx == false then return { kind = "stop" } end
    end
    if d < need - 10 then
        local tx, ty = pointFrom(b.x, b.y, a.x, a.y, need + 90)
        local w = lowHp and 0.6 or 0.4
        if a.safeX then tx = tx * (1 - w) + a.safeX * w; ty = ty * (1 - w) + a.safeY * w end
        return { kind = "move", x = tx, y = ty }
    end
    local fx, fy = farmSpot(a, b, ctx, need)
    if fx then return { kind = "move", x = fx, y = fy } end
    return { kind = "stop" }
end

POL.RETREAT = function(a, b, ctx)
    local tx, ty = a.safeX or a.x, a.safeY or a.y
    if a.deepX and ctx.deep then tx, ty = a.deepX, a.deepY end
    if dist(a.x, a.y, tx, ty) < 60 then return { kind = "stop" } end
    return { kind = "move", x = tx, y = ty }
end

D.POL = POL

-- ---------------------------------------------------------------------------------------------------------------
-- Simulator
-- ---------------------------------------------------------------------------------------------------------------
local function applyDamage(v, dmg, t, src)
    if dmg <= 0 or v.hp <= 0 then return end
    v.hp = v.hp - dmg
    if (v.hiddenMhp or 0) > 0 and v.hp > 0 and v.hp < v.mhp * 0.65 then
        -- G1 4:52: 453/758 -> 624/1078 when two Bracers came back from the backpack
        v.hp = v.hp * (v.mhp + v.hiddenMhp) / v.mhp
        v.mhp = v.mhp + v.hiddenMhp
        v.hiddenMhp = 0
    end
    v.flaskOn = false
    -- emergency heals (FF / stick) — both bots and humans use them at the last moment
    if v.hp > 0 and v.hp < (v.ffAt or 90) then
        if (v.ff or 0) > 0 then v.ff = v.ff - 1; v.hp = v.hp + P.FF_HEAL; v.used = (v.used or 0) + P.FF_HEAL
        elseif (v.stick or 0) > 0 then
            v.hp = v.hp + v.stick * 15; v.mp = min(v.mmp, v.mp + v.stick * 15)
            v.used = (v.used or 0) + v.stick * 15; v.stick = 0
        end
    end
    if v.hp <= 0 then v.hp = 0; v.deadAt = t end
end

local function stepHero(a, b, pol, ctx, dt, events)
    local t = ctx.t
    if a.hp <= 0 then return end
    -- timers
    a.atkReady = a.atkReady - dt
    for i = 1, 3 do if a.rzCd[i] > 0 then a.rzCd[i] = a.rzCd[i] - dt end end
    if a.stRem > 0 then a.stRem = a.stRem - dt; if a.stRem <= 0 then a.st = 0 end end
    a.hp = min(a.mhp, a.hp + a.hpr * dt)
    a.mp = min(a.mmp, a.mp + a.mpr * dt)
    a.vx, a.vy = 0, 0

    -- committed action
    if a.busy > 0 then
        a.busy = a.busy - dt
        if a.busy <= 1e-6 then
            if a.act == "raze" then
                local i = a.actI
                local c = P.RAZE_CENTERS[i]
                local cx, cy = a.x + a.fx * c, a.y + a.fy * c
                a.mp = a.mp - P.RAZE_MANA
                a.rzCd[i] = a.rzCdMax or P.RAZE_CD
                ctx.casts[a.side] = (ctx.casts[a.side] or 0) + 1
                local hitR = P.RAZE_RADIUS + 20 - (b.human and P.DODGE or 0)
                if b.hp > 0 and dist(cx, cy, b.x, b.y) <= hitR then
                    local dmg = razeDmg(a, b)
                    applyDamage(b, dmg, t, "raze")
                    b.st = min(10, (b.stRem > 0 and b.st or 0) + 1)
                    b.stRem = P.STACK_DUR
                    b.lastHitByEnemy = t
                    a.lastHeroHit = t
                    if events then events[#events + 1] = { t = t, who = a.side, what = "raze" .. i, dmg = dmg } end
                else
                    if events then events[#events + 1] = { t = t, who = a.side, what = "miss" .. i, dmg = 0 } end
                end
            elseif a.act == "atk" then
                -- launch projectile
                local d = dist(a.x, a.y, b.x, b.y)
                ctx.proj[#ctx.proj + 1] = { from = a, to = b, t = t + d / P.PROJ_SPEED, dmg = a.dmg }
                a.lastHeroHit = t
            end
            a.act = nil
        end
        return
    end

    local it = pol(a, b, ctx)
    if it.kind == "raze" then
        local d = dist(a.x, a.y, b.x, b.y)
        if d < 1 then d = 1 end
        a.fx, a.fy = (b.x - a.x) / d, (b.y - a.y) / d
        a.act, a.actI, a.busy = "raze", it.i, P.RAZE_CAST + (a.turnPenalty or 0.05)
    elseif it.kind == "atk" then
        a.act, a.busy = "atk", a.apt
        a.atkReady = a.aint
        a.lastAtkOrder = t
    elseif it.kind == "move" then
        local dx, dy = it.x - a.x, it.y - a.y
        local l = sqrt(dx * dx + dy * dy)
        if l > 1 then
            local s = min(l, a.spd * dt)
            a.vx, a.vy = dx / l * a.spd, dy / l * a.spd
            a.x, a.y = a.x + dx / l * s, a.y + dy / l * s
        end
    end
end

local function environment(h, foe, ctx, dt)
    if h.hp <= 0 then return end
    local t = ctx.t
    -- enemy tower
    if h.towerX and dist(h.x, h.y, h.towerX, h.towerY) <= P.TOWER_AGGRO then
        local focused = (t - (h.lastAtkOrder or -99)) <= P.TOWER_FOCUS
            and foe.hp > 0 and dist(foe.x, foe.y, h.towerX, h.towerY) <= P.TOWER_AGGRO + 300
        if focused or not h.towerShield then
            h.towerT = (h.towerT or (h.towerFirst or 0.35)) - dt
            if h.towerT <= 0 then
                h.towerT = P.TOWER_INT
                applyDamage(h, h.towerHit or P.TOWER_HIT, t, "tower")
            end
        else
            h.towerT = nil
        end
    else
        h.towerT = nil
    end
    -- enemy creeps aggro when h hits the enemy hero near them
    if (h.creepN or 0) > 0 and (t - (h.lastAtkOrder or -99)) <= P.CREEP_AGGRO_T
        and dist(h.x, h.y, h.creepX, h.creepY) <= P.CREEP_AGGRO_R + 150 then
        applyDamage(h, (h.creepDps or 0) * dt, t, "creep")
    elseif (h.passiveCreepDps or 0) > 0 and (h.creepN or 0) > 0 and dist(h.x, h.y, h.creepX, h.creepY) <= 260 then
        applyDamage(h, h.passiveCreepDps * dt, t, "creep")
    end
end

-- Simulate policy pair. Returns result table.
function D.Simulate(state, polA, polB, horizon, opts)
    local A = copyHero(state.me); A.side = "A"
    local B = copyHero(state.en); B.side = "B"
    for _, h in ipairs({ A, B }) do
        h.busy = h.busyInit or 0; h.act = h.actInit; h.actI = h.actIInit
        h.fx = h.fx or 1; h.fy = h.fy or 0
        h.atkReady = h.atkReady or 0
        h.st = h.st or 0; h.stRem = h.stRem or 0
        -- v5.2: a hit taken just before the evaluation counts for the reactions (FARM -> PULL when committed on)
        if h.hitAtkAgo then h.lastHitByEnemyAtk = -h.hitAtkAgo end
        if h.hitRazeAgo then h.lastHitByEnemy = -h.hitRazeAgo end
    end
    local ctx = { t = 0, proj = {}, casts = {}, deep = opts and opts.deep }
    -- v5.2 creep events (fresh copy per run: entries get consumed)
    local csN = { aLH = 0, aDN = 0, bLH = 0, bDN = 0 }
    if state.cs and #state.cs > 0 then
        ctx.cs = {}
        for i, e in ipairs(state.cs) do ctx.cs[i] = { t = e.t, x = e.x, y = e.y, k = e.k } end
    end
    local function reachCS(h, e)
        return h.hp > 0 and not (h.busy > 0 and h.act == "raze") and dist(h.x, h.y, e.x, e.y) <= h.rng + P.CS_REACH
    end
    local dt = P.DT
    local T = horizon or P.HORIZON
    local events = opts and opts.trace and {} or nil
    local a0, b0 = A.hp, B.hp
    local fA, fB = POL[polA], POL[polB]
    while ctx.t < T do
        ctx.t = ctx.t + dt
        stepHero(A, B, fA, ctx, dt, events)
        stepHero(B, A, fB, ctx, dt, events)
        -- projectiles
        local np = {}
        for _, p in ipairs(ctx.proj) do
            if p.t <= ctx.t then
                if p.to.hp > 0 and p.from.hp >= 0 then
                    applyDamage(p.to, p.dmg, ctx.t, "atk")
                    p.to.lastHitByEnemyAtk = ctx.t
                    if events then events[#events + 1] = { t = ctx.t, who = p.from.side, what = "atk", dmg = p.dmg } end
                end
            else
                np[#np + 1] = p
            end
        end
        ctx.proj = np
        environment(A, B, ctx, dt)
        environment(B, A, ctx, dt)
        if ctx.cs then
            for _, e in ipairs(ctx.cs) do
                if not e.done and e.t <= ctx.t then
                    e.done = true
                    local ra, rb = reachCS(A, e), reachCS(B, e)
                    local share = (ra and rb) and 0.5 or 1.0
                    if e.k == "lh" then
                        if ra then csN.aLH = csN.aLH + share end
                        if rb then csN.bDN = csN.bDN + share end
                    else
                        if ra then csN.aDN = csN.aDN + share end
                        if rb then csN.bLH = csN.bLH + share end
                    end
                end
            end
        end
        if A.hp <= 0 or B.hp <= 0 then break end
    end
    -- v5.2: creeps that open after the horizon go to whoever stands at the wave when it ends (wave control)
    if ctx.cs and A.hp > 0 and B.hp > 0 then
        for _, e in ipairs(ctx.cs) do
            if not e.done then
                local ra = dist(A.x, A.y, e.x, e.y) <= A.rng + 200
                local rb = dist(B.x, B.y, e.x, e.y) <= B.rng + 200
                local share = ((ra and rb) and 0.5 or 1.0) * P.CS_LATE
                if e.k == "lh" then
                    if ra then csN.aLH = csN.aLH + share end
                    if rb then csN.bDN = csN.bDN + share end
                else
                    if ra then csN.aDN = csN.aDN + share end
                    if rb then csN.bLH = csN.bLH + share end
                end
            end
        end
    end
    return {
        aDead = A.hp <= 0, bDead = B.hp <= 0, t = ctx.t,
        aHp = A.hp, bHp = B.hp, aMp = A.mp, bMp = B.mp,
        aLoss = a0 - A.hp + (A.used or 0), bLoss = b0 - B.hp + (B.used or 0),
        polB = polB,
        aX = A.x, aY = A.y, bX = B.x, bY = B.y,
        aRz = (A.rzCd[1] <= 0 and 1 or 0) + (A.rzCd[2] <= 0 and 1 or 0) + (A.rzCd[3] <= 0 and 1 or 0),
        bRz = (B.rzCd[1] <= 0 and 1 or 0) + (B.rzCd[2] <= 0 and 1 or 0) + (B.rzCd[3] <= 0 and 1 or 0),
        events = events,
        aLH = csN.aLH, aDN = csN.aDN, bLH = csN.bLH, bDN = csN.bDN,
    }
end

-- Value of a simulated outcome for the bot (A).
-- (v5.2: creeps are simulated explicitly now (CS_LH / CS_DN); this stays as the XP / lane-presence / wave-control
-- part - the values are unchanged so the fight verdicts calibrated on G1-G4 keep their margins)
local FARM_COST = { FARM = 0, POKE = 0, ALLIN = 0, ALLIN_LEASH = 0, KITE = 1.5, KEEPOUT = 2.5, RETREAT = 7.0 }
D.FARM_COST = FARM_COST

function D.Utility(state, r, polA)
    local me, en = state.me, state.en
    local u = 0
    if r.bDead then u = u + 900 + 12 * (D.P.HORIZON - r.t) end
    if r.aDead then u = u - 1000 - 12 * (D.P.HORIZON - r.t) end
    -- HP exchange, losses near zero HP weigh more (a 200 HP hit at 250 HP is not the same as at 1000 HP)
    local function riskW(hpEnd, mhp)
        local low = 320
        if hpEnd >= low then return 1.0 end
        return 1.0 + (low - hpEnd) / low * 0.9
    end
    -- v5.2: HP far above the opponent's kill burst is worth less (G5: the bot at 824-874/874 stood 1000 u away
    -- for 3 minutes to avoid a 111-HP raze while he took 31 last hits)
    local function spareW(hpEnd, burst)
        local over = hpEnd - burst
        if over <= 0 then return 1.0 end
        return 1.0 - (1.0 - P.HP_SPARE_W) * min(1, over / 250)
    end
    local wA = riskW(r.aHp, me.mhp)
    if wA <= 1.0 then wA = spareW(r.aHp, burstOf(en, me)) end
    local wB = riskW(r.bHp, en.mhp)
    if wB <= 1.0 then wB = spareW(r.bHp, burstOf(me, en)) end
    u = u + r.bLoss * wB - r.aLoss * wA
    -- "won with 3 HP" is not a plan: one more enemy hit or a creep shot kills us in reality (G1 6:30)
    if not r.aDead and r.aHp < en.dmg * 1.3 then u = u - 260 end
    -- resources left: ready razes the opponent can still use while in range after the horizon
    local myRaze = razeDmg(me, en) * 0.55
    local enRaze = razeDmg(en, me) * 0.55
    if not r.aDead and not r.bDead then
        local aR = min(r.aRz, floor(r.aMp / P.RAZE_MANA))
        local bR = min(r.bRz, floor(r.bMp / P.RAZE_MANA))
        local dEnd = dist(r.aX, r.aY, r.bX, r.bY)
        local close = dEnd <= 1050
        -- v5.2: smooth instead of a cliff at 1050 (spaced farming ends at ~1010 and was charged in full)
        local wClose = max(0, min(1, (1150 - dEnd) / 300))
        u = u + (aR * myRaze - bR * enRaze) * 0.5 * wClose
        -- lethal threat left on the table
        if close and r.aHp <= bR * enRaze + en.dmg then u = u - 120 end
        if close and r.bHp <= aR * myRaze + me.dmg then u = u + 80 end
    end
    -- v5.2 lane economy: creeps that died in the horizon and who got them
    u = u + P.CS_LH * ((r.aLH or 0) - (r.bLH or 0)) + P.CS_DN * ((r.aDN or 0) - (r.bDN or 0))
    u = u - (FARM_COST[polA] or 0) * (r.t)
    -- the enemy leaving the lane to escape costs him farm / XP as well
    u = u + (FARM_COST[r.polB] or 0) * (r.t) * 0.8
    return u
end

D.MY_POLICIES = { "FARM", "POKE", "ALLIN_LEASH", "ALLIN", "KITE", "KEEPOUT", "RETREAT" }
D.EN_POLICIES = { "ALLIN", "ALLIN_LEASH", "POKE", "FARM", "KITE", "RETREAT" }

-- Full evaluation: matrix of outcomes, robust choice.
-- Evaluation is split in three parts so the game adapter can time-slice it across frames
-- (D.Evaluate = Begin + all policies + Finish; used by the tests and the scanner).
function D.EvalBegin(state)
    local res = { scores = {}, worst = {}, avg = {}, matrix = {}, kill = {}, death = {}, worstQ = {} }
    if state.en.human and (state.en.ff or 0) > 0 then
        state.en.ffAt = max(state.en.ffAt or 95, razeDmg(state.me, state.en) + 25)
    end
    -- pessimistic copy: the enemy plays slightly better than measured, we slightly worse
    if not state._pess then
        local ps = { me = copyHero(state.me), en = copyHero(state.en), deep = state.deep, cs = state.cs, _pess = true }
        ps.en.dmg = ps.en.dmg * 1.08
        ps.me.dmg = ps.me.dmg * 0.95
        state = ps
    end
    res._state = state
    return res
end

function D.EvalPolicy(res, pa)
    local state = res._state
    local worst, sum, n = 1e9, 0, 0
    local killAll, dieAny = true, false
    local worstQ = nil
    res.matrix[pa] = {}
    for _, pb in ipairs(D.EN_POLICIES) do
        local r = D.Simulate(state, pa, pb, P.HORIZON, { deep = state.deep })
        local u = D.Utility(state, r, pa)
        res.matrix[pa][pb] = { u = u, r = r }
        if u < worst then worst = u; worstQ = pb end
        sum = sum + u; n = n + 1
        if not r.bDead then killAll = false end
        if r.aDead then dieAny = true end
    end
    res.worst[pa] = worst
    res.worstQ[pa] = worstQ
    res.avg[pa] = sum / n
    res.scores[pa] = 0.7 * worst + 0.3 * (sum / n)
    res.kill[pa] = killAll
    res.death[pa] = dieAny
end

function D.EvalFinish(res)
    local best, bestS = "FARM", res.scores.FARM
    for _, pa in ipairs(D.MY_POLICIES) do
        local dominatesFarm = res.worst[pa] > res.worst.FARM + 5 and res.scores[pa] > res.scores.FARM
        if res.scores[pa] > bestS + ((pa ~= "FARM") and 15 or 0)
            or (dominatesFarm and best == "FARM" and res.scores[pa] > bestS) then
            best, bestS = pa, res.scores[pa]
        end
    end
    -- a guaranteed kill (every enemy response dies, we survive all) always wins
    for _, pa in ipairs({ "ALLIN_LEASH", "ALLIN" }) do
        if res.kill[pa] and not res.death[pa] then
            if best ~= "ALLIN_LEASH" and best ~= "ALLIN" then best = pa end
            break
        end
    end
    -- v5.2: when he has just hit us (hands or a raze) and stands within 1000, the simulated FARM/POKE is "pull back
    -- and answer" (POL.PULL), not farming - the executor must do the same, so the verdict becomes KITE (whose executor
    -- razes / hits back when it fits and steps out of his reach). G2 2:33: the bot farmed inside his creeps while he
    -- right-clicked it 446 -> 204.
    local st = res._state
    if st and (best == "FARM" or best == "POKE") then
        local ago = min(st.me.hitAtkAgo or 99, st.me.hitRazeAgo or 99)
        if ago <= 2.0 and dist(st.me.x, st.me.y, st.en.x, st.en.y) <= 1000 then best = "KITE"; res.pulled = true end
    end
    res.best = best
    res.lost = true
    for _, pa in ipairs(D.MY_POLICIES) do
        if not (res.matrix[pa][res.worstQ[pa]].r.aDead) then res.lost = false; break end
    end
    res.verdict = (res.kill[best] and "KILL")
        or ((best == "ALLIN" or best == "ALLIN_LEASH") and "FIGHT")
        or (best == "POKE" and "POKE")
        or (best == "KITE" and "KITE")
        or (best == "KEEPOUT" and "SPACE")
        or (best == "RETREAT" and "RETREAT")
        or "FARM"
    res._state = nil
    return res
end

function D.Evaluate(state, opts)
    local res = D.EvalBegin(state)
    for _, pa in ipairs(D.MY_POLICIES) do D.EvalPolicy(res, pa) end
    return D.EvalFinish(res)
end

-- ===================================================================================================================
-- GAME ADAPTER (Dota bot API)
-- ===================================================================================================================
local function safe(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local RAZE_NAMES = { "nevermore_shadowraze1", "nevermore_shadowraze2", "nevermore_shadowraze3" }
D.RAZE_NAMES = RAZE_NAMES

local function modStack(unit, name)
    local n = safe(unit.NumModifiers, unit) or 0
    for i = 0, n - 1 do
        if safe(unit.GetModifierName, unit, i) == name then
            return safe(unit.GetModifierStackCount, unit, i) or 0, safe(unit.GetModifierRemainingDuration, unit, i) or 0
        end
    end
    return 0, 0
end

local function hasModifier(unit, name)
    local n = safe(unit.NumModifiers, unit) or 0
    for i = 0, n - 1 do
        if safe(unit.GetModifierName, unit, i) == name then return true end
    end
    return false
end

local function itemCount(unit, name)
    local c, charges = 0, 0
    for slot = 0, 8 do
        local it = safe(unit.GetItemInSlot, unit, slot)
        if it and safe(it.GetName, it) == name then
            c = c + 1
            charges = charges + (safe(it.GetCurrentCharges, it) or 0)
        end
    end
    return c, charges
end

-- reads one hero; `isMe` = our bot (exact cooldowns), else uses tracker K for enemy raze readiness
function D.ReadHero(unit, other, isMe, K)
    local h = {}
    local loc = unit:GetLocation()
    h.x, h.y = loc.x, loc.y
    h.hp = unit:GetHealth() or 0
    h.mhp = unit:GetMaxHealth() or 600
    h.hpr = safe(unit.GetHealthRegen, unit) or 1.5
    h.mp = unit:GetMana() or 0
    h.mmp = unit:GetMaxMana() or 300
    h.mpr = safe(unit.GetManaRegen, unit) or 0.8
    local raw = safe(unit.GetAttackDamage, unit) or 40
    local phys = raw
    if other and other.GetActualIncomingDamage then
        phys = safe(other.GetActualIncomingDamage, other, raw, DAMAGE_TYPE_PHYSICAL) or raw * 0.85
    end
    h.dmg = phys
    h.aint = safe(unit.GetSecondsPerAttack, unit) or 1.45
    h.apt = (safe(unit.GetAttackPoint, unit) or 0.5)
    if h.apt > 0.9 then h.apt = 0.5 end
    h.rng = (safe(unit.GetAttackRange, unit) or 500) + 40 -- hull radii
    h.spd = safe(unit.GetCurrentMovementSpeed, unit) or 305
    h.lvl = safe(unit.GetLevel, unit) or 1
    h.souls = modStack(unit, "modifier_nevermore_necromastery")
    h.perSoul = P.PER_SOUL
    h.rzCd = { 0, 0, 0 }
    h.rzLvl = 0
    local labels = { "near", "mid", "far" }
    for i = 1, 3 do
        local ab = safe(unit.GetAbilityByName, unit, RAZE_NAMES[i])
        if ab then
            local lv = safe(ab.GetLevel, ab) or 0
            if lv > h.rzLvl then h.rzLvl = lv end
            if lv > 0 then
                if isMe then
                    h.rzCd[i] = safe(ab.GetCooldownTimeRemaining, ab) or 0
                    local cdMax = safe(ab.GetCooldown, ab)
                    if cdMax and cdMax > 1 then h.rzCdMax = cdMax end
                elseif K and K.EnemyRazeReadyIn then
                    h.rzCd[i] = K.EnemyRazeReadyIn(labels[i]) or 0
                end
                local b = safe(ab.GetSpecialValueInt, ab, "shadowraze_damage")
                if b and b > 0 then h.rzBase = b end
                local sb = safe(ab.GetSpecialValueInt, ab, "stack_bonus_damage")
                if sb and sb > 0 then h.rzStack = sb end
                local ps = safe(ab.GetSpecialValueInt, ab, "damage_per_soul")
                if ps and ps > 0 then h.perSoul = ps end
            else
                h.rzCd[i] = 999
            end
        else
            h.rzCd[i] = 999
        end
    end
    local L = max(1, min(4, h.rzLvl))
    h.rzBase = h.rzBase or P.RAZE_BASE[L]
    h.rzStack = h.rzStack or P.RAZE_STACK[L]
    -- incoming magic multiplier of THIS hero (used by the opponent's razes)
    h.magMult = 0.75
    local probe = safe(unit.GetActualIncomingDamage, unit, 100, DAMAGE_TYPE_MAGICAL)
    if probe and probe > 0 then h.magMult = probe / 100 end
    h.st, h.stRem = modStack(unit, "modifier_nevermore_shadowraze_debuff")
    h.ff = select(1, itemCount(unit, "item_faerie_fire"))
    local anyItem = false
    for slot = 0, 5 do if safe(unit.GetItemInSlot, unit, slot) then anyItem = true; break end end
    if not isMe and not anyItem then
        -- inventory not readable: assume the usual laning Faerie Fire for the first 7 minutes (never overrate a kill)
        local dt = (DotaTime and safe(DotaTime)) or 0
        if dt < 420 then h.ff = 1 end
    end
    local sc, sch = itemCount(unit, "item_magic_stick")
    local wc, wch = itemCount(unit, "item_magic_wand")
    h.stick = sch + wch
    h.mango = select(1, itemCount(unit, "item_enchanted_mango"))
    h.silenced = safe(unit.IsSilenced, unit) or false
    -- velocity
    local v = safe(unit.GetVelocity, unit)
    if v and v.x then h.vx, h.vy = v.x, v.y else h.vx, h.vy = 0, 0 end
    -- in-progress raze cast
    for i = 1, 3 do
        local ab = safe(unit.GetAbilityByName, unit, RAZE_NAMES[i])
        if ab and safe(ab.IsInAbilityPhase, ab) then
            h.busyInit = 0.25
            h.actInit = "raze"
            h.actIInit = i
            local f = math.rad(safe(unit.GetFacing, unit) or 0)
            h.fx, h.fy = math.cos(f), math.sin(f)
        end
    end
    return h
end

local function centroid(list, ref, r)
    local sx, sy, n = 0, 0, 0
    for _, c in pairs(list or {}) do
        local ok, l = pcall(c.GetLocation, c)
        if ok and l and (not ref or dist(l.x, l.y, ref.x, ref.y) <= r) then
            sx, sy, n = sx + l.x, sy + l.y, n + 1
        end
    end
    if n == 0 then return nil end
    return sx / n, sy / n, n
end

local function creepDps(list, ref, r)
    local dps, n = 0, 0
    for _, c in pairs(list or {}) do
        local ok, l = pcall(c.GetLocation, c)
        if ok and l and dist(l.x, l.y, ref.x, ref.y) <= r then
            local nm = safe(c.GetUnitName, c) or ""
            if nm:find("ranged") then dps = dps + P.CREEP_HIT_RANGED
            elseif nm:find("siege") then dps = dps + 18
            else dps = dps + P.CREEP_HIT_MELEE end
            n = n + 1
            if n >= 4 then break end
        end
    end
    return dps, n
end

-- v5.2 creep HP tracker -> CS forecast. HP is sampled every call; damage per second is smoothed over ~1 s.
function D.CreepForecast(bot, s, me, en)
    local now = GameTime()
    local trk = D.mem.chp or {}
    local nt = {}
    local out = {}
    local bl = bot:GetLocation()
    local function scan(list, k, thr)
        for _, c in pairs(list or {}) do
            local okA, alive = pcall(c.IsAlive, c)
            if okA and alive then
                local hp = safe(c.GetHealth, c) or 0
                local l = safe(c.GetLocation, c)
                if l and hp > 0 and dist(l.x, l.y, bl.x, bl.y) <= 1600 then
                    local r = trk[c]
                    if r then
                        local dtc = now - r.t
                        if dtc >= 0.25 then
                            local inst = max(0, (r.hp - hp) / dtc)
                            r.dps = r.dps and (0.55 * r.dps + 0.45 * inst) or inst
                            r.hp, r.t = hp, now
                        end
                    else
                        r = { hp = hp, t = now, dps = nil }
                    end
                    nt[c] = r
                    local tt = nil
                    if hp <= thr then tt = 0
                    elseif r.dps and r.dps > 1 then tt = (hp - thr) / r.dps end
                    if tt and tt <= P.CS_FORECAST then out[#out + 1] = { t = tt, x = l.x, y = l.y, k = k } end
                end
            end
        end
    end
    scan(s.enemyCreeps, "lh", 0.95 * (me.dmg or 50))
    scan(s.allyCreeps, "dn", 0.95 * (en.dmg or 50))
    D.mem.chp = nt
    table.sort(out, function(a, b) return a.t < b.t end)
    while #out > 10 do out[#out] = nil end
    return out
end

-- Builds the plain state from the live game. U = utils, K = combat tracker, s = world snapshot.
function D.BuildState(bot, enemy, s, U, K, C)
    local state_cs
    local me = D.ReadHero(bot, enemy, true, nil)
    local en = D.ReadHero(enemy, bot, false, K)
    en.human = true
    me.ffAt = 95
    en.ffAt = 95
    me.replyHands = true
    en.replyHands = true

    local myTeam = bot:GetTeam()
    local radiant = (myTeam == (TEAM_RADIANT or 2))
    local posC = (C and C.POSITIONS) or {}
    local myT1 = s.allyT1 and s.allyT1:GetLocation() or (radiant and posC.RADIANT_T1 or posC.DIRE_T1)
    local enT1 = s.enemyT1Loc or (s.enemyT1 and s.enemyT1:GetLocation()) or (radiant and posC.DIRE_T1 or posC.RADIANT_T1)
    local fountain = radiant and posC.MID_FOUNTAIN_RADIANT or posC.MID_FOUNTAIN_DIRE
    local enFountain = radiant and posC.MID_FOUNTAIN_DIRE or posC.MID_FOUNTAIN_RADIANT

    -- tower that shoots me (enemy T1) and him (my T1)
    if enT1 and s.enemyT1Alive ~= false then
        me.towerX, me.towerY = enT1.x, enT1.y
        local _, _, nShield = centroid(s.allyCreeps, enT1, 700)
        me.towerShield = (nShield or 0) > 0
    end
    if myT1 and s.allyT1 then
        en.towerX, en.towerY = myT1.x, myT1.y
        local _, _, nShield = centroid(s.enemyCreeps, myT1, 700)
        en.towerShield = (nShield or 0) > 0
        local thp = safe(s.allyT1.GetAttackDamage, s.allyT1)
        if thp and thp > 0 then en.towerHit = safe(enemy.GetActualIncomingDamage, enemy, thp, DAMAGE_TYPE_PHYSICAL) end
    end
    if s.enemyT1 then
        local thp = safe(s.enemyT1.GetAttackDamage, s.enemyT1)
        if thp and thp > 0 then me.towerHit = safe(bot.GetActualIncomingDamage, bot, thp, DAMAGE_TYPE_PHYSICAL) end
    end
    -- creeps that would aggro on each hero
    local bl = bot:GetLocation()
    local el = enemy:GetLocation()
    local cx, cy, cn = centroid(s.enemyCreeps, bl, 800)
    if cx then
        me.creepX, me.creepY, me.creepN = cx, cy, cn
        me.creepDps = creepDps(s.enemyCreeps, bl, 800)
    end
    local ax, ay, an = centroid(s.allyCreeps, el, 800)
    if ax then
        en.creepX, en.creepY, en.creepN = ax, ay, an
        en.creepDps = creepDps(s.allyCreeps, el, 800)
    end
    -- v5.2 recent hand hits (they drive the FARM -> PULL reaction in the simulator)
    if safe(enemy.GetAttackTarget, enemy) == bot and bot.WasRecentlyDamagedByHero and safe(bot.WasRecentlyDamagedByHero, bot, enemy, 1.5) then
        me.hitAtkAgo = 0.7
    end
    if bot.WasRecentlyDamagedByHero and safe(bot.WasRecentlyDamagedByHero, bot, enemy, 1.5) then
        for i = 1, 3 do
            if (en.rzCd[i] or 0) >= (en.rzCdMax or P.RAZE_CD) - 1.5 and (en.rzCd[i] or 0) < 900 then me.hitRazeAgo = 0.7; break end
        end
    end
    if safe(bot.GetAttackTarget, bot) == enemy and enemy.WasRecentlyDamagedByHero and safe(enemy.WasRecentlyDamagedByHero, enemy, bot, 1.5) then
        en.hitAtkAgo = 0.7
    end
    -- v5.2 creep forecast for the lane economy (see P.CS_LH): HP trend per creep -> time until it drops under the
    -- last-hitter's damage. "lh" = enemy creep (we last-hit, he denies), "dn" = our creep (he last-hits, we deny).
    state_cs = D.CreepForecast(bot, s, me, en)
    -- retreat points: just behind own tower (toward fountain) and deep (half way to T2)
    local function behind(t1, f, d)
        if not t1 or not f then return nil end
        local dx, dy = f.x - t1.x, f.y - t1.y
        local l = sqrt(dx * dx + dy * dy)
        return t1.x + dx / l * d, t1.y + dy / l * d
    end
    if myT1 and fountain then
        me.safeX, me.safeY = behind(myT1, fountain, 250)
        me.deepX, me.deepY = behind(myT1, fountain, 1500)
    end
    if enT1 and enFountain then
        en.safeX, en.safeY = behind(enT1, enFountain, 250)
        en.deepX, en.deepY = behind(enT1, enFountain, 1500)
    end
    -- hidden max HP: enemy temporarily lowered max HP (bracers in backpack, treads off STR) -> it returns with HP%
    local mem = D.mem
    if mem.enLvl ~= en.lvl then mem.enLvl = en.lvl; mem.enMhpMax = en.mhp end
    mem.enMhpMax = max(mem.enMhpMax or en.mhp, en.mhp)
    if mem.enMhpMax - en.mhp >= 120 then en.hiddenMhp = mem.enMhpMax - en.mhp end
    local state = { me = me, en = en, cs = state_cs }
    -- a dive under our tower is lethal if his burst over ~4 s beats our effective HP: retreat deep
    local enBurst = 0
    local nR = min(3, floor((en.mp + (en.mango or 0) * 100) / P.RAZE_MANA))
    local enR = razeDmg(en, me)
    for k = 1, nR do enBurst = enBurst + enR + (k - 1) * en.rzStack * me.magMult end
    enBurst = enBurst + en.dmg * 2
    local towerTank = 5 * (en.towerHit or P.TOWER_HIT)
    state.deep = effHp(me) <= enBurst and en.hp > towerTank + 150
    return state
end

-- ===================================================================================================================
-- DIRECTOR (decision + execution with hysteresis)
-- ===================================================================================================================
D.mem = { lastEval = -99, res = nil, lockUntil = -99, lockPol = nil, spacing = nil, lastLog = -99 }

function D.Reset()
    D.mem = { lastEval = -99, res = nil, lockUntil = -99, lockPol = nil, spacing = nil, lastLog = -99 }
end

-- Is a candidate attack position too close to the enemy given the current spacing order?
function D.SpacingBlocks(loc, botLoc, kOpen, totalT)
    local sp = D.mem.spacing
    if not sp or not loc or GameTime() > sp.untilT then return false end
    local dl = dist(loc.x, loc.y, sp.ex, sp.ey)
    if dl >= sp.minDist then return false end
    -- v5.2 CS dip: a spaced (spare-HP) KITE lets the CS layer walk in for a creep whose hit must start now
    -- (opening tick - our ballistic ticks <= DIP_TICKS); KITE/ProjectOutOfSpacing stay off until the hit is done
    if sp.dip and kOpen and totalT and kOpen >= 0 and kOpen < 999 and totalT <= P.DIP_MAX_TICKS
        and kOpen - totalT <= P.DIP_TICKS then
        D.mem.dipUntil = GameTime() + min(2.0, max(0.6, kOpen / 30 + 0.6))
        D.mem.dipCount = (D.mem.dipCount or 0) + 1
        return false
    end
    -- v5.1: a last hit from (about) where we already stand is never worse than standing there idle - only a spot
    -- that takes us DEEPER into his threat circle is blocked (v5.0 blocked every CS once d < minDist: G4 8:05-8:08
    -- the bot stood 170-420 from a dying creep under its own tower and let the tower take it).
    if not botLoc and GetBot then
        local b = GetBot()
        botLoc = b and b.GetLocation and b:GetLocation()
    end
    if botLoc and dl >= dist(botLoc.x, botLoc.y, sp.ex, sp.ey) - 15 then return false end
    return true
end

local function facingErr(bot, x, y)
    local l = bot:GetLocation()
    local ang = math.deg(math.atan2(y - l.y, x - l.x))
    if ang < 0 then ang = ang + 360 end
    local f = bot:GetFacing() or 0
    local d = abs(f - ang)
    if d > 180 then d = 360 - d end
    return d
end

-- v5.1 anti-bait gate, same rule as U.RazeJukeOK: |dNow - c| + rho <= R + hull, rho = speed * slack
-- (adaptive: active for 12 s after one of our hero razes was S-cancelled; D.mem.lastCancel is set by the validator)
P.JUKE_SLACK_MOVING, P.JUKE_SLACK_STILL, P.JUKE_LETHAL_MULT, P.JUKE_HULL, P.JUKE_WINDOW = 0.33, 0.25, 0.5, 24, 12
local function jukeOK(me, en, i, dNow, force)
    if not force and not (D.mem and D.mem.lastCancel and GameTime() - D.mem.lastCancel < P.JUKE_WINDOW) then return true end
    if (en.busyInit or 0) > 0 or en.stunned or en.rooted then return true end
    local sp2 = (en.vx or 0) ^ 2 + (en.vy or 0) ^ 2
    local slack = sp2 > 1600 and P.JUKE_SLACK_MOVING or P.JUKE_SLACK_STILL
    if effHp(en) <= razeDmg(me, en) then slack = slack * P.JUKE_LETHAL_MULT end
    return abs(dNow - P.RAZE_CENTERS[i]) + (en.spd or 305) * slack <= P.RAZE_RADIUS + P.JUKE_HULL
end
D.JukeOK = jukeOK

-- v5.1 spacing radius with an approach margin: a human walking in at 305-350 u/s covers ~110 u before a 0.1 s
-- director tick + ~0.2 s turn let us react (G4 5:57.9-5:59.0: he closed 958 -> 676 in 1.1 s, the bot moved 50 u,
-- e landed in the centre). Exposed for tests.
local function spaceNeed(me, en, extra)
    local need = threatRange(en) + (extra or 0)
    local d = dist(me.x, me.y, en.x, en.y)
    if d > 1 then
        local closing = ((en.vx or 0) * (me.x - en.x) + (en.vy or 0) * (me.y - en.y)) / d
        if closing > 0 then need = need + closing * 0.35 end
    end
    return need
end
D.SpaceNeed = spaceNeed

-- v5.1 spacing step with hysteresis (the v5.0 10-unit band made KITE and the CS layer fight each other every tick:
-- 59 direction reversals/min in G4 vs 31-37 in G1-G3 and the human's 21-32). Returns a move point or nil.
local function spacingStep(me, en, need, safeW)
    local d = dist(me.x, me.y, en.x, en.y)
    local m = D.mem
    if m.spaceOut and d >= need + 40 then m.spaceOut = nil end
    if not m.spaceOut and d < need - 10 then m.spaceOut = true end
    if not m.spaceOut then return nil end
    local tx, ty = pointFrom(en.x, en.y, me.x, me.y, need + 90)
    if me.safeX then tx = tx * (1 - safeW) + me.safeX * safeW; ty = ty * (1 - safeW) + me.safeY * safeW end
    return tx, ty
end

-- v5.1: an enemy creep in hand range that our next hit kills (attack ready). G4: 21 of 40 creeps that died to his
-- creeps/tower did so with the bot inside 600 u and not hitting (8 of them during FIGHT verdicts).
local function freeLastHit(bot, me, state, hooks)
    if not state.creeps then return false end
    local la = bot.GetLastAttackTime and safe(bot.GetLastAttackTime, bot)
    if la and (la + (me.aint or 1.4)) - GameTime() > 0.05 then return false end
    local dmgType = DAMAGE_TYPE_PHYSICAL or 1
    for _, c in pairs(state.creeps) do
        if c and safe(c.IsAlive, c) then
            local cl = safe(c.GetLocation, c)
            if cl and dist(me.x, me.y, cl.x, cl.y) <= me.rng + 20 then
                local dmg = safe(c.GetActualIncomingDamage, c, me.dmg, dmgType) or me.dmg * 0.75
                local hp = safe(c.GetHealth, c) or 9999
                if hp > 0 and hp <= dmg * 0.92 - 4 then hooks.attack(c); return true end
            end
        end
    end
    return false
end

-- v5.2: a creep of ours (last hit or deny) opens within one attack cycle near us - a right-click on the hero now
-- would put the attack on cooldown exactly when the creep becomes killable (lane mock C: hero hit at 320.72,
-- creep opened at 320.76 and again at 321.7 -> the creep died to its own wave)
local function csImminent(me, state, horizon)
    local cs = state.cs
    if not cs then return false end
    horizon = horizon or ((me.aint or 1.6) + 0.35)
    for _, e in ipairs(cs) do
        if e.t <= horizon and dist(me.x, me.y, e.x, e.y) <= me.rng + 200 then return true end
    end
    return false
end
D.CsImminent = csImminent

-- hooks: { castRaze(ab, target, loc), move(loc), attack(unit), face(loc) }
function D.Execute(bot, enemy, state, pol, hooks, VectorF)
    local me, en = state.me, state.en
    local d = dist(me.x, me.y, en.x, en.y)
    local ePredX = en.x + (en.vx or 0) * P.RAZE_CAST
    local ePredY = en.y + (en.vy or 0) * P.RAZE_CAST
    local dPred = dist(me.x, me.y, ePredX, ePredY)

    local function tryRaze(tolExtra, poke)
        if poke and not pokeManaOK(me, en, (me.hitRazeAgo or 99) <= 1.5) then return false, nil, 1e9 end
        local bi, be = nil, 1e9
        for i = 1, 3 do
            if canRaze(me, i) then
                local e = abs(dPred - P.RAZE_CENTERS[i])
                if e < be then be, bi = e, i end
            end
        end
        local tol = P.RAZE_RADIUS - 95 + (tolExtra or 0)
        -- v5.1 anti-bait: the coil must also absorb the disc he can still reach after the cast starts
        -- (G4 6:54-7:00: four e started on an approaching human at 846..940, he reversed on the animation)
        if bi and be <= tol and not jukeOK(me, en, bi, d) then
            return false, bi, max(be, tol + 1)
        end
        if bi and be <= tol then
            local ab = bot:GetAbilityByName(RAZE_NAMES[bi])
            if ab and ab:IsFullyCastable() then
                local fe = facingErr(bot, ePredX, ePredY)
                if fe > 11 then
                    hooks.face(VectorF(ePredX, ePredY, 0))
                    return true, "face", be
                end
                hooks.castRaze(ab, enemy, VectorF(ePredX, ePredY, 0))
                return true, "raze" .. bi, be
            end
        end
        return false, bi, be
    end

    if pol == "ALLIN" or pol == "ALLIN_LEASH" then
        if d <= me.rng and en.hp <= me.dmg then hooks.attack(enemy); return true, "atk-kill" end
        local ok, info, be = tryRaze(0)
        if ok then return true, info end
        local bi = info
        local wantAtk, mvx, mvy = false, nil, nil
        if bi then
            local c = P.RAZE_CENTERS[bi]
            -- v5.1: close to the band centre measured on his CURRENT position (slightly inside) unless he is
            -- running away - a dancing human is caught only near the centre (see jukeOK)
            local away = 0
            if d > 1 then away = ((en.vx or 0) * (en.x - me.x) + (en.vy or 0) * (en.y - me.y)) / d end
            if d <= me.rng and abs(d - c) < 130 then wantAtk = true
            elseif away > 120 then mvx, mvy = pointFrom(ePredX, ePredY, me.x, me.y, c)
            else mvx, mvy = pointFrom(en.x, en.y, me.x, me.y, c - 40) end
        elseif d <= me.rng + 40 then
            wantAtk = true
        else
            mvx, mvy = ePredX, ePredY
        end
        local killNow = (bi and be <= P.RAZE_RADIUS - 95 + 60 and effHp(en) <= razeDmg(me, en))
            or (d <= me.rng + 60 and en.hp <= me.dmg)
        if pol == "ALLIN_LEASH" and me.towerX and not killNow then
            -- our own position never enters the enemy tower radius (865 + margin) to fight
            local R = P.TOWER_AGGRO + 25
            local myD = dist(me.x, me.y, me.towerX, me.towerY)
            if myD <= R - 10 then
                local sx, sy = pointFrom(me.towerX, me.towerY, me.x, me.y, R + 50)
                hooks.move(VectorF(sx, sy, 0)); return true, "leash-out"
            end
            if mvx then
                local dx, dy = mvx - me.x, mvy - me.y
                local l = sqrt(dx * dx + dy * dy)
                if l > 1 then
                    local nx, ny = me.x + dx / l * min(l, 60), me.y + dy / l * min(l, 60)
                    if dist(nx, ny, me.towerX, me.towerY) <= R then
                        if d <= me.rng then hooks.attack(enemy); return true, "atk-leash" end
                        local sx, sy = pointFrom(me.towerX, me.towerY, me.x, me.y, R + 30)
                        hooks.move(VectorF(sx, sy, 0)); return true, "leash-hold"
                    end
                end
            end
        end
        -- v5.1 free last hit on the way: a comfortable (non-kill) fight never walks past a creep that one hit kills.
        -- v5.2: also while trading hits in range (lane mock C: 2 s of hero right-clicks while a 38 -> 20 -> 2 HP
        -- creep died beside the bot) - one attack cycle for 40 gold, the next one goes to the hero again
        if pol == "ALLIN_LEASH" and not killNow and freeLastHit(bot, me, state, hooks) then
            return true, "free-lh"
        end
        -- ... and does not spend the attack on the hero just before a creep of ours opens (0.75 attack cycles)
        if wantAtk and pol == "ALLIN_LEASH" and not killNow and csImminent(me, state, (me.aint or 1.6) * 0.75) then
            return false, "hold-lh" -- the CS layer times the hit
        end
        if wantAtk then hooks.attack(enemy); return true, bi and "atk-band" or "atk" end
        hooks.move(VectorF(mvx, mvy, 0)); return true, bi and ("band" .. bi) or "chase"
    elseif pol == "POKE" then
        local ok, info = tryRaze(-10, true)
        if ok then return true, info end
        return false, "poke-none"
    elseif pol == "KEEPOUT" then
        local need = spaceNeed(me, en, 0)
        D.mem.spacing = { ex = en.x, ey = en.y, minDist = need, untilT = GameTime() + 0.6 }
        local tx, ty = spacingStep(me, en, need, 0.4)
        if tx then hooks.move(VectorF(tx, ty, 0)); return true, "keepout" end
        return false, "keepout-ok"
    elseif pol == "KITE" then
        local ok, info = tryRaze(-10, true)
        if ok then return true, info .. "-kite" end
        if d <= me.rng - 30 and not csImminent(me, state) then
            local atkReadyIn = 0
            local la = bot.GetLastAttackTime and safe(bot.GetLastAttackTime, bot)
            if la then atkReadyIn = (la + me.aint) - GameTime() end
            if atkReadyIn <= 0.05 then hooks.attack(enemy); return true, "atk-kite" end
        end
        -- v5.0: with a healthy HP pool KITE = farm at the edge of his threat range (the CS layer keeps working, but
        -- the spacing filter rejects every last-hit spot inside his reach). Only a low bot walks back to the tower.
        -- v5.1: a low bot no longer walks to the tower on every KITE tick (G4: 4:47-4:52 and 6:55-7:06 the bot left
        -- the wave and lost the creeps); it farms with a wider margin and backs off only when actually inside.
        local base, lowHp = kiteNeed(me, en)
        local need = spaceNeed(me, en, 0) - threatRange(en) + base -- base radius + approach margin
        D.mem.spacing = { ex = en.x, ey = en.y, minDist = need, untilT = GameTime() + 0.35, dip = not lowHp }
        -- v5.2: a CS dip approved by SpacingBlocks is in progress - let the CS layer finish the hit
        if not lowHp and GameTime() < (D.mem.dipUntil or 0) then return false, "kite-dip" end
        local tx, ty = spacingStep(me, en, need, lowHp and 0.6 or 0.4)
        if tx then hooks.move(VectorF(tx, ty, 0)); return true, lowHp and "kite-space-low" or "kite-space" end
        return false, "kite-farm"
    elseif pol == "RETREAT" then
        local tx, ty = me.safeX, me.safeY
        if state.deep and me.deepX then tx, ty = me.deepX, me.deepY end
        if not tx then return false, "no-safe" end
        D.mem.spacing = { ex = en.x, ey = en.y, minDist = threatRange(en) + 100, untilT = GameTime() + 1.0 }
        -- free reply while retreating: an enemy standing in a ready band gets hit (costs 0.55 s)
        if d > 300 and me.hp > razeDmg(en, me) * 1.2 then
            local ok, info = tryRaze(-40, true)
            if ok and info ~= "face" then return true, info .. "-retreat" end
        end
        hooks.move(VectorF(tx, ty, 0)); return true, state.deep and "retreat-deep" or "retreat"
    end
    return false, "farm"
end

-- Main entry from RealThink. Returns true if the Director issued an order.
function D.Think(bot, s, deps, hooks)
    local U, K, C = deps.U, deps.K, deps.C
    local enemy = s.enemy
    D.mem.spacing = (D.mem.spacing and GameTime() <= D.mem.spacing.untilT) and D.mem.spacing or nil
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then
        -- v5.1: a stale reset request must not survive his death (G4 3:05: he died at 3:03.7, the bot at 54/940 HP
        -- still walked 30 s home and was away 45 s while the lane was free)
        D.mem.wantReset = nil; D.mem.badSince = nil
        return false
    end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local now = GameTime()
    local d = GetUnitToUnitDistance(bot, enemy)
    if d > ((C.DIRECTOR and C.DIRECTOR.MAX_DIST) or 1500) then D.mem.res = nil; D.mem.job = nil; return false end

    local state = D.BuildState(bot, enemy, s, U, K, C)
    D.mem.lastState = state
    state.creeps = s.enemyCreeps
    local res = D.mem.res
    -- time-sliced evaluation: at most SLICE policies per frame; a full decision is assembled in 2-3 frames
    local interval = (C.DIRECTOR and C.DIRECTOR.EVAL_INTERVAL) or 0.10
    local SLICE = (C.DIRECTOR and C.DIRECTOR.SLICE) or 3
    local job = D.mem.job
    if not job and (not res or now - D.mem.lastEval >= interval) then
        job = { res = D.EvalBegin(state), i = 0, t0 = now }
        D.mem.job = job
    end
    if job then
        local pols = D.MY_POLICIES
        local stop = math.min(#pols, job.i + SLICE)
        for i = job.i + 1, stop do D.EvalPolicy(job.res, pols[i]) end
        job.i = stop
        if stop >= #pols then
            res = D.EvalFinish(job.res)
            D.mem.res = res
            D.mem.lastEval = job.t0
            D.mem.job = nil
        end
    end
    if not res then return false end
    local pol = res.best
    -- kill / fight lock: do not flip-flop out of a committed winning fight for 0.8 s unless it turns lethal for us
    if (res.verdict == "KILL" or res.verdict == "FIGHT") then
        D.mem.lockUntil = now + 0.8
        D.mem.lockPol = pol
    elseif now < D.mem.lockUntil and D.mem.lockPol then
        local lp = D.mem.lockPol
        if (res.scores[lp] or -1e9) > res.scores[pol] - 60 and not res.death[lp] then pol = lp end
    end
    -- v5.1 incumbent bonus: between near-equal peaceful lines keep the current one unless the new one is clearly
    -- better (offline over 4 replays: -15% policy flips for <1 score point given up per decision)
    local cur0 = D.mem.cur
    if cur0 and cur0 ~= pol and res.scores[cur0] and res.verdict ~= "KILL" and pol ~= "RETREAT"
        and not res.death[cur0] and res.scores[cur0] + 25 >= res.scores[pol] then
        pol = cur0
    end
    -- anti-jitter: a fresh non-critical switch must beat the current line clearly or wait 0.3 s
    local cur = D.mem.cur
    if cur and cur ~= pol and (now - (D.mem.curSince or 0)) < 0.3
        and res.verdict ~= "KILL" and pol ~= "RETREAT" and res.scores[cur]
        and res.scores[cur] > res.scores[pol] - 40 and not res.death[cur] then
        pol = cur
    end
    if pol ~= D.mem.cur then D.mem.cur = pol; D.mem.curSince = now end
    if pol ~= "KITE" and pol ~= "KEEPOUT" then D.mem.spaceOut = nil end
    if pol == "ALLIN" or pol == "ALLIN_LEASH" or pol == "POKE" then D.mem.spacing = nil end
    -- low-HP limbo detector (G3 4:20-5:11: 50 s at 107-285 HP inside the human's kill window, zero farm):
    -- a lost / retreat-only lane for RESET_SEC with no regen running -> ask the bot to reset at the fountain
    local hpPct = state.me.hp / math.max(1, state.me.mhp)
    local bad = (res.lost or res.verdict == "RETREAT") and hpPct < 0.45
    local stillBad = D.mem.badSince and (res.verdict == "RETREAT" or res.verdict == "SPACE" or res.verdict == "KITE" or res.lost) and hpPct < 0.5
    if bad and not D.mem.badSince then D.mem.badSince = now
    elseif not bad and not stillBad then D.mem.badSince = nil end
    local regenOn = bot:HasModifier("modifier_flask_healing") or bot:HasModifier("modifier_tango_heal")
    -- v5.1 human rule: reset only when BOTH pools are low - with mana for two razes the lane is still playable
    -- (the human never walked home with mana; G3 6:22 TP-out at 90 mp / 241 HP was his only voluntary reset)
    if state.me.mp >= 2 * P.RAZE_MANA and hpPct >= 0.22 then D.mem.badSince = nil end
    local resetSec = (C.DIRECTOR and C.DIRECTOR.RESET_SEC) or 6.0
    D.mem.wantReset = (D.mem.badSince ~= nil and now - D.mem.badSince >= resetSec and not regenOn) or nil
    _G.__directorDecision = { t = now, pol = pol, verdict = res.verdict, scores = res.scores }
    if pol == "FARM" then return false end
    local acted, info = D.Execute(bot, enemy, state, pol, hooks, Vector)
    _G.__directorDecision.info = info
    if U.DEBUG and now - D.mem.lastLog > 0.5 then
        D.mem.lastLog = now
        print(string.format("[SF-DIRECTOR] %.2f %s/%s %s acted=%s", now, res.verdict, pol, tostring(info), tostring(acted)))
    end
    return acted
end

return D
