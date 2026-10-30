--[[
================================================================================
 WAR CORE v1.0 — a model-based predictive duel engine for Shadow Fiend 1v1 mid
================================================================================
 Pure Lua 5.1 module. No Dota API calls: it consumes a plain state table and
 returns plain decisions, so it can be unit-tested and replayed offline.

 The engine answers three questions every frame:

   1. THREAT  — how much damage can the enemy still put into me, right now,
                over the next N seconds (razes that are ready or come off
                cooldown, right-click DPS that can actually reach me, tower,
                creeps)?  -> "am I already dead and just walking around?"
   2. OUTCOME — for every candidate plan of mine and every plausible plan of
                his, what is the resulting HP of both heroes?  -> planned
                fights are decided by simulation, not by thresholds.
   3. DECISION— pick the plan with the best *worst case* under a lexicographic
                objective: never die > kill > win the exchange > farm.

 Measured/verified constants (7.41f, from replay telemetry):
   raze: 75 mana, 9 s cd per band, 0.55 s cast, bands 200/450/700, radius 250
         damage 90/160/230/300 (+50/60/70/80 per stack, +2 per soul), 25% MR
   tower: aggro 865, ~75 dmg each ~0.83 s, leash ~1100
   SF: 500 range, 0.5 attack point, 1200 projectile, BAT 1.6
================================================================================
]]

local WAR = {}

local C = {
    DT              = 1.0 / 30.0,

    RAZE_MANA       = 75,
    RAZE_CD         = 9.0,
    RAZE_CAST       = 0.55,
    RAZE_DIST       = { 200, 450, 700 },
    RAZE_RADIUS     = 250,
    RAZE_BASE       = { 90, 160, 230, 300 },
    RAZE_STACK      = { 50, 60, 70, 80 },
    RAZE_PER_SOUL   = 2,
    STACK_DURATION  = 8.0,
    MAX_STACKS      = 3,

    ATK_RANGE       = 500,
    ATK_POINT       = 0.50,
    PROJ_SPEED      = 1200,
    BAT             = 1.60,
    TURN_RATE       = 5.0,      -- rad/s while casting/attacking
    MAGIC_RESIST    = 0.25,

    -- ENGINE TRUTH: these four are overwritten at runtime from the live tower
    -- (see nevermore/engine_truth.lua); the values below are the 7.41f
    -- replay-measured fallbacks used when the accessors are unavailable.
    TOWER_RANGE     = 865,
    TOWER_LEASH     = 1100,
    -- KV-exact (npc_units.txt, npc_dota_badguys_tower1_mid, 7.41f):
    --   damage 88..92 (avg 90), seconds per attack 0.9*100/110 = 0.8182,
    --   AttackAnimationPoint 0.6 (wind-up before the projectile exists),
    --   ProjectileSpeed 750 (homing, so it always lands on the locked target)
    TOWER_DMG       = 90,
    TOWER_INTERVAL  = 0.8182,
    TOWER_WINDUP    = 0.60,
    TOWER_PROJECTILE= 750,
    TOWER_FIRST     = 0.35,

    HORIZON         = 4.0,
    -- time until damage that is already in the air lands (engine gives the
    -- projectile list, not its impact time; 0.18 s is the measured SF
    -- right-click flight time at lane distance)
    INCOMING_LAND   = 0.18,

    --[[ LANE CREEPS - exact values from npc_units.txt (7.41f). `dmg` is the
         average of the KV damage range, `bat` the KV AttackRate, `range` the
         KV AttackRange. HULL_PAD is the extra distance a unit can be hit from
         (attacker hull + target hull) and is why a "500 range" ranged creep
         touches a hero at ~545. ]]--
    CREEP = {
        melee  = { dmg = 21.0, bat = 1.0, range = 100, proj = 0,    hp = 550 },
        ranged = { dmg = 23.5, bat = 1.0, range = 500, proj = 900,  hp = 300 },
        siege  = { dmg = 40.5, bat = 3.0, range = 690, proj = 1100, hp = 935 },
        flag   = { dmg = 21.0, bat = 1.0, range = 100, proj = 0,    hp = 550 },
        HULL_PAD = 45,
    },

    -- objective weights (utility = my advantage at the horizon)
    W_HP            = 1.0,
    W_MANA          = 0.30,
    W_TOWER         = 0.0,
    W_STAND         = 0.45,     -- standing-HP-share pressure
    DEATH_COST      = 1.0e6,
    KILL_BONUS      = 3.0e5,
    SAFE_HP_ABS     = 110,
}
WAR.C = C

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function distance(ax, ay, bx, by) local dx, dy = ax - bx, ay - by return math.sqrt(dx * dx + dy * dy) end

WAR.clamp = clamp
WAR.dist = distance

--------------------------------------------------------------------------------
-- damage model
--------------------------------------------------------------------------------
function WAR.RazeDamage(level, stacks, souls)
    level = clamp(level or 1, 1, 4)
    local d = C.RAZE_BASE[level]
    d = d + (stacks or 0) * C.RAZE_STACK[level]
    d = d + (souls or 0) * C.RAZE_PER_SOUL
    return d
end

function WAR.RazeApplied(level, stacks, souls, mr)
    mr = mr or C.MAGIC_RESIST
    return WAR.RazeDamage(level, stacks, souls) * (1.0 - mr)
end

-- Damage a full volley of n razes does to a target that already has `stacks`.
function WAR.VolleyDamage(level, stacks, souls, n, mr)
    local total, st = 0, stacks or 0
    for _ = 1, (n or 0) do
        total = total + WAR.RazeApplied(level, st, souls, mr)
        st = math.min(C.MAX_STACKS, st + 1)
    end
    return total
end

--------------------------------------------------------------------------------
-- unit normalisation
--------------------------------------------------------------------------------
function WAR.Prep(u)
    u = u or {}
    u.hp = u.hp or 1
    u.hp_max = u.hp_max or u.hp
    u.mana = u.mana or 0
    u.dmg = u.dmg or 0
    u.souls = u.souls or 0
    u.raze_level = u.raze_level or 0
    u.raze_ready = u.raze_ready or { 0, 0, 0 }
    u.atk_ready = u.atk_ready or 0
    u.ms = u.ms or 305
    u.regen_hp = u.regen_hp or 0
    u.regen_mana = u.regen_mana or 0
    u.magic_resist = u.magic_resist or C.MAGIC_RESIST
    u.alive = (u.alive ~= false)
    u.stacks = u.stacks or 0
    u.stack_t = u.stack_t or -1e9
    u.facing = u.facing or 0
    u.cast_until = u.cast_until or -1
    u.aim_x, u.aim_y = u.aim_x, u.aim_y
    u.atk_until = u.atk_until or -1
    u.proj = {}
    -- damage already in flight towards this unit (engine truth, not a forecast)
    u.incoming = u.incoming or 0
    u.incoming_at = u.incoming_at or C.INCOMING_LAND
    u.pending_raze = nil
    u.stick_charges = u.stick_charges or 0
    u.mango = u.mango or 0
    u.mana_burst_used = false
    return u
end

local function clone_unit(u)
    local c = {}
    for k, v in pairs(u) do
        if k == "proj" or k == "pending_raze" or k == "pending_attack" then
            -- skip, re-initialised
        elseif type(v) == "table" then
            if k == "raze_ready" then c[k] = { v[1] or 0, v[2] or 0, v[3] or 0 }
            else local n = {} for kk, vv in pairs(v) do n[kk] = vv end c[k] = n end
        else
            c[k] = v
        end
    end
    c.proj = {}
    c.pending_raze = nil
    c.pending_attack = nil
    return c
end

local function clone_plan(p)
    local c = {}
    for k, v in pairs(p or {}) do c[k] = v end
    return c
end

--------------------------------------------------------------------------------
-- readiness
--------------------------------------------------------------------------------
--[[ v6.3: a raze that the mana cannot pay for is not "ready". The old count
     ignored mana, so `hisReady == 0` was true only on a full cooldown, and the
     bot traded into an opponent who was perfectly able to answer. Measured:
     every won exchange of the bot happened at his 18-111 mana, i.e. exactly
     when this count - with mana - is zero. ]]--
function WAR.ReadyCount(u, now)
    local n = 0
    for i = 1, 3 do if (u.raze_ready[i] or 0) <= now then n = n + 1 end end
    local budget = WAR.Affordable(u, now)
    if n > budget then n = budget end
    return n
end

function WAR.ReadyLabels(u, now, horizon)
    local out = {}
    for i = 1, 3 do
        if (u.raze_ready[i] or 0) <= now + (horizon or 0) then out[#out + 1] = i end
    end
    return out
end

function WAR.Affordable(u, now)
    local mana = u.mana
    if not u.mana_burst_used then
        mana = mana + (u.stick_charges or 0) * 15 + (u.mango and 100 or 0)
    end
    -- mana regen over one second is worth one extra raze check in practice
    return math.floor((mana + (u.regen_mana or 0) * 1.0) / C.RAZE_MANA)
end

--[[
 Threat: damage the unit `attacker` can still push into `victim` within
 `horizon` seconds, counting only the razes that are ready in time, the mana
 that can pay for them, and right-clicks that can actually reach.
]]
function WAR.Burst(attacker, victim, horizon, now, opts)
    if not attacker or attacker.raze_level <= 0 then return 0, 0 end
    now = now or 0
    local n = 0
    for i = 1, 3 do
        if (attacker.raze_ready[i] or 0) <= now + horizon then n = n + 1 end
    end
    local budget = WAR.Affordable(attacker, now)
    if budget < n then n = budget end
    if n > 3 then n = 3 end
    if opts and opts.max and n > opts.max then n = opts.max end
    if not victim or n <= 0 then return 0, n end
    local total, st = 0, victim.stacks or 0
    local lvl = attacker.raze_level
    local mr = victim.magic_resist or C.MAGIC_RESIST
    for _ = 1, n do
        total = total + WAR.RazeApplied(lvl, st, attacker.souls, mr)
        st = st + 1
        if st > C.MAX_STACKS then st = C.MAX_STACKS end
    end
    return total, n
end

--------------------------------------------------------------------------------
-- the simulator
--------------------------------------------------------------------------------
--[[
 The core aiming question: can this raze actually land?

 A Shadowraze places a circle of radius 250 at 200/450/700 units along the
 caster's facing when the 0.55 s cast ENDS. The victim moves during the cast,
 so the circle must cover not just where he is, but where he can run to:

   landable  <=>  |predicted_dist - band| + enemy_escape <= RADIUS - margin

 where enemy_escape = his movement speed * CAST (168 units for a 305 hero), and
 a hero who is locked in an attack windup or in his own cast cannot move at all
 for the remaining windup — that is exactly the moment a good SF player razes.

 Returns band index, coverage (units of slack), quality flag.
]]
function WAR.FindShot(u, foe, now, minQuality)
    if u.raze_level <= 0 or not foe or not foe.alive then return nil end
    if u.mana < C.RAZE_MANA then return nil end
    local locked = (foe.atk_until and foe.atk_until > now) or (foe.cast_until and foe.cast_until > now)
    local lockTime = 0
    if foe.atk_until and foe.atk_until > now then lockTime = foe.atk_until - now end
    if foe.cast_until and foe.cast_until > now then lockTime = math.max(lockTime, foe.cast_until - now) end
    local escape
    if locked then
        -- he is pinned for lockTime; he can only run for the rest of the cast
        escape = math.max(0, (foe.ms or 305) * math.max(0, C.RAZE_CAST - lockTime))
    else
        escape = (foe.ms or 305) * C.RAZE_CAST
    end
    local tx = foe.x + (foe.vx or 0) * C.RAZE_CAST
    local ty = foe.y + (foe.vy or 0) * C.RAZE_CAST
    local dd = distance(u.x, u.y, tx, ty)

    local best, bestSlack = nil, -1e9
    for i = 1, 3 do
        if (u.raze_ready[i] or 0) <= now then
            local err = math.abs(dd - C.RAZE_DIST[i])
            local slack = (C.RAZE_RADIUS - 20) - err - escape
            if slack > bestSlack then
                best, bestSlack = i, slack
            end
        end
    end
    if not best then return nil end
    local quality = "poor"
    if locked and bestSlack > -200 then quality = "lock" end
    if bestSlack >= 0 then quality = locked and "lock" or "solid" end
    if bestSlack >= 60 then quality = "clean" end
    minQuality = minQuality or "solid"
    local rank = { poor = 0, solid = 1, lock = 2, clean = 3 }
    if rank[quality] < rank[minQuality] then return nil, bestSlack, quality end
    return best, bestSlack, quality
end

local function start_attack(u, tgt, now)
    local d = distance(u.x, u.y, tgt.x, tgt.y)
    if d > C.ATK_RANGE then return false end
    if u.atk_ready > now or u.cast_until > now then return false end
    if u.pending_attack then return false end
    u.atk_until = now + C.ATK_POINT
    u.pending_attack = { t = now + C.ATK_POINT, dmg = u.dmg, target = tgt, ready = now + math.max(C.BAT, C.ATK_POINT + 0.3) }
    return true
end

local function resolve_pending_attack(u, now)
    local a = u.pending_attack
    if not a or a.t > now then return end
    u.pending_attack = nil
    u.atk_ready = a.ready
    local t = a.target
    if not t or not t.alive then return end
    local d = distance(u.x, u.y, t.x, t.y)
    u.proj[#u.proj + 1] = { t = now + d / C.PROJ_SPEED, dmg = a.dmg, target = t }
end

-- cancel the swing before the damage is released (used by the reactive dodge)
local function cancel_attack(u)
    if u.pending_attack then
        u.pending_attack = nil
        u.atk_until = -1
        return true
    end
    return false
end

local function apply_projectiles(u, now)
    local keep = {}
    for i = 1, #u.proj do
        local p = u.proj[i]
        if p.t <= now then
            local t = p.target
            if t and t.alive then
                t.hp = t.hp - p.dmg
                t.hp_taken = (t.hp_taken or 0) + p.dmg
                if t.hp <= 0 then t.hp = 0; t.alive = false; t.died_at = now end
            end
        else
            keep[#keep + 1] = p
        end
    end
    u.proj = keep
end

local function resolve_raze(u, now)
    local p = u.pending_raze
    if not p or p.t > now then return end
    u.pending_raze = nil
    local tgt = p.target
    if not tgt or not tgt.alive then return end
    -- circle centre: along the *current* facing (the hero kept turning during
    -- the cast), at the band distance
    local d = C.RAZE_DIST[p.idx]
    local cx = u.x + math.cos(u.facing) * d
    local cy = u.y + math.sin(u.facing) * d
    if distance(cx, cy, tgt.x, tgt.y) <= C.RAZE_RADIUS then
        local dmg = p.dmg
        tgt.hp = tgt.hp - dmg
        tgt.hp_taken = (tgt.hp_taken or 0) + dmg
        if tgt.hp <= 0 then tgt.hp = 0; tgt.alive = false; tgt.died_at = now end
        tgt.stacks = math.min(C.MAX_STACKS, (tgt.stacks or 0) + 1)
        tgt.stack_t = now
        tgt.last_raze_hit_at = now
        tgt.hit_by_raze = (tgt.hit_by_raze or 0) + 1
    else
        u.raze_missed = (u.raze_missed or 0) + 1
    end
end

local function step_toward(u, gx, gy, dt, now)
    if not u.alive then return end
    if u.cast_until > now then return end
    if u.atk_until and u.atk_until > now then return end   -- committed to the swing
    local d = distance(u.x, u.y, gx, gy)
    if d < 2 then return end
    local step = math.min(d, u.ms * dt)
    local nx, ny = (gx - u.x) / d, (gy - u.y) / d
    u.x = u.x + nx * step
    u.y = u.y + ny * step
    u.vx, u.vy = nx * u.ms, ny * u.ms
    if u.atk_until <= now then u.facing = math.atan2(ny, nx) end
end

--[[
 The per-tick controller. `plan` is a policy; `foe` the opponent unit.
 Returns a short tag describing what the unit is doing (for diagnostics).
]]
local function control(u, foe, plan, now, dt)
    if not u.alive then return "dead" end

    -- 0) adaptive stance: a competent duellist always converts a kill.
    --    If the opponent is inside my burst+2 hits, I stop respecting my
    --    "hold distance" and go for the throat; if I am the one who is
    --    killable, I respect my own burst as the escape budget.
    local hold = plan.hold_dist or 430
    local pol = plan.raze_policy or "none"
    local attackOn = plan.attack ~= false
    if plan.adaptive and foe and foe.alive then
        local canFinish = (WAR.Burst(u, foe, 1.6, now) + u.dmg * 2) >= foe.hp
        local inDanger = (WAR.Burst(foe, u, 1.6, now) + foe.dmg * 2) >= u.hp
        if canFinish then
            hold = math.min(hold, 260)
            pol = "burst"
            attackOn = true
        elseif inDanger and plan.punish_danger ~= false then
            hold = math.max(hold, 620)
        end
    end

    -- 1) finish an ongoing cast: keep turning towards the aim point
    if u.cast_until > now then
        if u.aim_x and u.aim_y then
            local want = math.atan2(u.aim_y - u.y, u.aim_x - u.x)
            local diff = want - u.facing
            while diff > math.pi do diff = diff - 2 * math.pi end
            while diff < -math.pi do diff = diff + 2 * math.pi end
            local maxTurn = C.TURN_RATE * dt
            u.facing = u.facing + clamp(diff, -maxTurn, maxTurn)
        end
        return "casting"
    end

    local d = foe and foe.alive and distance(u.x, u.y, foe.x, foe.y) or 1e9

    -- 2) reaction dodge: the enemy is casting a raze and we can see it
    if plan.dodge ~= false and foe and foe.alive and foe.cast_until > now and foe.cast_label then
        if plan.cancel_dodge ~= false then cancel_attack(u) end
        -- strafe perpendicular to the enemy's line, towards the safer side
        local bx, by = u.x - foe.x, u.y - foe.y
        local bl = math.sqrt(bx * bx + by * by)
        if bl > 1 then
            local px, py = -by / bl, bx / bl
            -- pick the side that moves us away from the raze band centre
            local bandD = C.RAZE_DIST[foe.cast_label] or 450
            local cx = foe.x + math.cos(foe.facing) * bandD
            local cy = foe.y + math.sin(foe.facing) * bandD
            local lx = u.x + px * 120
            local ly = u.y + py * 120
            local rx = u.x - px * 120
            local ry = u.y - py * 120
            if distance(lx, ly, cx, cy) < distance(rx, ry, cx, cy) then
                step_toward(u, rx, ry, dt, now)
            else
                step_toward(u, lx, ly, dt, now)
            end
            return "dodge"
        end
    end

    -- 3) raze decision
    local want, quality = false, nil
    if pol == "burst" then
        want, quality = true, (plan.raze_quality or "solid")
    elseif pol == "single" then
        want, quality = (now - (u.last_volley_at or -1e9) > 2.0), (plan.raze_quality or "solid")
    elseif pol == "trade" then
        --[[ v6.3 EXCHANGE TRUTH.
             The old gate was `hisReady == 0` - fire only at a target that
             cannot answer at all. The ledger of 9066921447 shows what that
             costs: every one of the bot's 11 won exchanges came when the human
             had 18-111 mana left, and in five of its six worst losses it stood
             with 274-423 mana and 2-3 razes off cooldown while the human put
             two razes into it. A trade is worth taking whenever OUR burst is
             not smaller than his - not only when his is zero. ]]--
        local hisReady = (foe and WAR.ReadyCount(foe, now)) or 0
        local myBurst = WAR.Burst(u, foe, 2.2, now)
        local hisBurst = foe and WAR.Burst(foe, u, 2.2, now) or 0
        want = (hisReady == 0)
            or (myBurst >= 0.85 * hisBurst and myBurst > 0)
            or (foe and foe.hp < (plan.finish_hp or 260))
        if (foe and foe.cast_until and foe.cast_until > now) then want = true end
        quality = (hisReady == 0) and (plan.raze_quality or "solid") or "poor"
    elseif pol == "lethal" then
        want = foe and (WAR.Burst(u, foe, 1.8, now) >= foe.hp + 30)
        quality = "poor"
    elseif pol == "answer" then
        want = (foe and foe.last_raze_hit_at and now - foe.last_raze_hit_at <= 0.7) or false
        quality = "poor"
    end
    if want and foe and foe.alive then
        local idx, slack, q = WAR.FindShot(u, foe, now, quality)
        if idx and u.mana >= C.RAZE_MANA then
            local stacks = foe.stacks or 0
            local dmg = WAR.RazeApplied(u.raze_level, stacks, u.souls, foe.magic_resist)
            u.mana = u.mana - C.RAZE_MANA
            u.raze_ready[idx] = now + C.RAZE_CD
            u.cast_until = now + C.RAZE_CAST
            u.cast_label = idx
            u.razes_cast = (u.razes_cast or 0) + 1
            u.last_volley_at = now
            u.aim_x = foe.x + (foe.vx or 0) * C.RAZE_CAST
            u.aim_y = foe.y + (foe.vy or 0) * C.RAZE_CAST
            u.pending_raze = { t = now + C.RAZE_CAST, idx = idx, dmg = dmg, target = foe }
            return "raze"
        end
    end

    -- 4) movement policy
    if plan.flee then
        step_toward(u, plan.flee_x or u.x, plan.flee_y or u.y, dt, now)
        return "flee"
    end
    if foe and foe.alive then
        if plan.engage ~= false then
            if d > hold + 40 then
                local k = (d - hold) / d
                step_toward(u, u.x + (foe.x - u.x) * k, u.y + (foe.y - u.y) * k, dt, now)
            elseif d < hold - 120 then
                local k = (hold - d) / d
                step_toward(u, u.x - (foe.x - u.x) * k, u.y - (foe.y - u.y) * k, dt, now)
            end
        end
        if attackOn and d <= C.ATK_RANGE and u.atk_until <= now then
            if start_attack(u, foe, now) then return "attack" end
        end
    end
    return "hold"
end

--[[
 WAR.Simulate(state, myPlan, hisPlan, horizon) -> result

 state = {
   t, me, him,            -- unit tables (see WAR.Prep)
   me_stacks, him_stacks, -- optional overrides
   tower = {x,y,dmg,interval} or nil,
   creep_dps_on_me, creep_dps_on_him,
 }
]]
function WAR.Simulate(state, myPlan, hisPlan, horizon)
    horizon = horizon or C.HORIZON
    local t0 = state.t or 0
    local me = WAR.Prep(clone_unit(state.me))
    local him = WAR.Prep(clone_unit(state.him))
    if state.me_stacks then me.stacks = state.me_stacks; me.stack_t = t0 end
    if state.him_stacks then him.stacks = state.him_stacks; him.stack_t = t0 end

    --[[ ENGINE TRUTH — damage that is *already flying* is not a forecast: it
         lands whatever either side does next. Seeding it as a projectile with
         the observed arrival time means every candidate plan is charged for it,
         which is the difference between "I have 420 HP, I can trade" and
         "I have 420 HP and 141 of it is already gone". ]]--
    if (me.incoming or 0) > 0 then
        him.proj[#him.proj + 1] = { t = t0 + (me.incoming_at or C.INCOMING_LAND),
                                    dmg = me.incoming, target = me }
    end
    if (him.incoming or 0) > 0 then
        me.proj[#me.proj + 1] = { t = t0 + (him.incoming_at or C.INCOMING_LAND),
                                  dmg = him.incoming, target = him }
    end

    local mp = clone_plan(myPlan)
    local hp = clone_plan(hisPlan)
    local tower = state.tower          -- enemy T1: shoots ME
    local ownTower = state.own_tower   -- my T1: shoots HIM
    local me0, him0 = me.hp, him.hp
    local meMana0, himMana0 = me.mana, him.mana

    local dt = state.dt or C.DT
    local steps = math.floor(horizon / dt + 0.5)
    local aggroMe, aggroHim = false, false
    --[[ TOWER SHOTS ARE NOT INSTANT (KV truth).
         The tower winds up for `windup` seconds before the projectile exists,
         and the projectile is homing at `proj` speed, so the damage lands
         windup + distance/proj seconds after the cycle starts - even when the
         hero has already left the radius. Every shot is queued with its real
         impact time instead of being applied on the spot. ]]--
    local windup = (tower and tower.windup) or C.TOWER_WINDUP
    local projSpeed = (tower and tower.proj_speed) or C.TOWER_PROJECTILE
    local ownWindup = (ownTower and ownTower.windup) or C.TOWER_WINDUP
    local ownProjSpeed = (ownTower and ownTower.proj_speed) or C.TOWER_PROJECTILE
    local qMe, qHim = {}, {}
    local function queue_shot(q, fire_t, dmg, dist, wu, ps)
        q[#q + 1] = { t = fire_t + (wu or C.TOWER_WINDUP) + dist / math.max(1, ps or C.TOWER_PROJECTILE),
                      dmg = dmg }
    end
    local function apply_shots(q, t, victim)
        local keep = {}
        for i = 1, #q do
            local e = q[i]
            if e.t <= t then
                if victim.alive then
                    victim.hp = victim.hp - e.dmg
                    victim.tower_hits = (victim.tower_hits or 0) + 1
                    if victim.hp <= 0 then
                        victim.hp = 0; victim.alive = false; victim.died_at = t
                    end
                end
            else
                keep[#keep + 1] = e
            end
        end
        return keep
    end
    -- engine truth: when the tower is already locked on us (or already
    -- mid-cycle) the first shot arrives sooner than a fresh acquisition
    local tFirst = (tower and tower.next_shot) or C.TOWER_FIRST
    local nextMe, nextHim = t0 + tFirst, t0 + C.TOWER_FIRST
    local t = t0

    for i = 0, steps do
        t = t0 + i * dt
        if me.alive then me.hp = math.min(me.hp_max, me.hp + me.regen_hp * dt) end
        if him.alive then him.hp = math.min(him.hp_max, him.hp + him.regen_hp * dt) end

        if me.alive and him.alive then
            local a1 = control(me, him, mp, t, dt)
            local a2 = control(him, me, hp, t, dt)
            if state.trace and i % 3 == 0 then
                print(string.format("  t=%.2f me:%s (%.0f,%.0f) hp%.0f | him:%s (%.0f,%.0f) hp%.0f d=%.0f",
                    t - t0, a1, me.x, me.y, me.hp, a2, him.x, him.y, him.hp, distance(me.x, me.y, him.x, him.y)))
            end
        elseif me.alive then
            if mp.flee then step_toward(me, mp.flee_x or me.x, mp.flee_y or me.y, dt, t) end
        elseif him.alive then
            if hp.flee then step_toward(him, hp.flee_x or him.x, hp.flee_y or him.y, dt, t) end
        end

        qMe = apply_shots(qMe, t, me)
        qHim = apply_shots(qHim, t, him)
        resolve_pending_attack(me, t)
        resolve_pending_attack(him, t)
        resolve_raze(me, t)
        resolve_raze(him, t)
        apply_projectiles(me, t)
        apply_projectiles(him, t)

        if t - me.stack_t > C.STACK_DURATION then me.stacks = 0 end
        if t - him.stack_t > C.STACK_DURATION then him.stacks = 0 end

        if me.alive and (state.creep_dps_on_me or 0) > 0 then
            me.hp = me.hp - state.creep_dps_on_me * dt
            if me.hp <= 0 then me.hp = 0; me.alive = false; me.died_at = t end
        end
        if him.alive and (state.creep_dps_on_him or 0) > 0 then
            him.hp = him.hp - state.creep_dps_on_him * dt
            if him.hp <= 0 then him.hp = 0; him.alive = false; him.died_at = t end
        end

        if tower then
            if me.alive then
                local d = distance(me.x, me.y, tower.x, tower.y)
                if tower.aggro_me then aggroMe = true end    -- engine: locked on me
                if d <= (tower.range or C.TOWER_RANGE) then aggroMe = true end
                if aggroMe and d > C.TOWER_LEASH then aggroMe = false end
                if aggroMe and t >= nextMe then
                    nextMe = t + (tower.interval or C.TOWER_INTERVAL)
                    queue_shot(qMe, t, (tower.dmg or C.TOWER_DMG), d, windup, projSpeed)
                end
            end
        end
        if ownTower and him.alive then
            local d = distance(him.x, him.y, ownTower.x, ownTower.y)
            if ownTower.aggro_me then aggroHim = true end   -- our tower locked on HIM
            if d <= (ownTower.range or C.TOWER_RANGE) then aggroHim = true end
            if aggroHim and d > C.TOWER_LEASH then aggroHim = false end
            if aggroHim and t >= nextHim then
                nextHim = t + (ownTower.interval or C.TOWER_INTERVAL)
                queue_shot(qHim, t, (ownTower.dmg or C.TOWER_DMG), d, ownWindup, ownProjSpeed)
            end
        end

        if not me.alive or not him.alive then
            -- let the survivor keep moving (escape) for the rest of the horizon
            for j = i + 1, steps do
                t = t0 + j * dt
                if me.alive and mp.flee then step_toward(me, mp.flee_x or me.x, mp.flee_y or me.y, dt, t) end
                if him.alive and hp.flee then step_toward(him, hp.flee_x or him.x, hp.flee_y or him.y, dt, t) end
                if tower and me.alive then
                    local d = distance(me.x, me.y, tower.x, tower.y)
                    if tower.aggro_me then aggroMe = true end
                    if d <= (tower.range or C.TOWER_RANGE) then aggroMe = true end
                    if aggroMe and d > C.TOWER_LEASH then aggroMe = false end
                    if aggroMe and t >= nextMe then
                        nextMe = t + (tower.interval or C.TOWER_INTERVAL)
                        queue_shot(qMe, t, (tower.dmg or C.TOWER_DMG), d, windup, projSpeed)
                    end
                    qMe = apply_shots(qMe, t, me)
                    if not me.alive then break end
                end
            end
            break
        end
    end

    local res = {
        my_hp = me.hp, his_hp = him.hp,
        my_dead = not me.alive, his_dead = not him.alive,
        dealt = him0 - him.hp,
        taken = me0 - me.hp,
        mana_left = me.mana,
        razes_cast = me.razes_cast or 0,
        razes_hit = me.hit_by_raze and 0 or 0,
        my_x = me.x, my_y = me.y,
        his_x = him.x, his_y = him.y,
        t_end = t,
        horizon = horizon,
        tower_hits_taken = me.tower_hits or 0,
    }
    res.net = res.dealt - res.taken
    return res
end

--------------------------------------------------------------------------------
-- plan generation
--------------------------------------------------------------------------------
--[[
 A plan is a policy table. We generate a small, *meaningful* set:
   stance     : where to stand relative to him (hold distance)
   raze_policy: none / single / trade / answer / lethal / burst
   engage     : walk towards him or not
   flee       : run to a point
]]
function WAR.MyPlans(state, opts)
    opts = opts or {}
    local me, him = state.me, state.him
    local plans = {}
    local holds = opts.holds or { 260, 460, 720, 950 }
    local pols = opts.pols or { "burst", "trade", "none" }
    for _, h in ipairs(holds) do
        for _, p in ipairs(pols) do
            plans[#plans + 1] = {
                name = string.format("hold%d_%s", h, p),
                hold_dist = h, raze_policy = p, engage = true, attack = true,
            }
        end
    end
    -- escape plans
    if opts.flee_points then
        for i, fp in ipairs(opts.flee_points) do
            plans[#plans + 1] = {
                name = "flee" .. i, flee = true, flee_x = fp.x, flee_y = fp.y,
                raze_policy = opts.flee_pol or "lethal", attack = false, engage = false,
            }
        end
    end
    return plans
end

function WAR.HisPlans(state, opts)
    opts = opts or {}
    local plans = {
        { name = "aggressive", hold_dist = 330, raze_policy = "burst",  engage = true, attack = true, adaptive = true },
        { name = "reactive",   hold_dist = 430, raze_policy = "trade", engage = true, attack = true,
          adaptive = true, cancel_dodge = true, raze_quality = "lock" },
        { name = "passive",    hold_dist = 700, raze_policy = "none",  engage = false, attack = true },
    }
    -- he runs for his own tower (this is what a losing SF actually does, and
    -- without it the "guaranteed kill" verdict is far too optimistic)
    local hf = opts.his_flee or state.his_flee
    if hf then
        plans[#plans + 1] = { name = "retreat_tower", flee = true, flee_x = hf.x, flee_y = hf.y,
                              attack = false, engage = false, raze_policy = "lethal" }
    end
    return plans
end

--------------------------------------------------------------------------------
-- evaluation
--------------------------------------------------------------------------------
local function utility(state, res)
    local me, him = state.me, state.him
    local u = 0
    if res.my_dead then u = u - C.DEATH_COST end
    if res.his_dead then u = u + C.KILL_BONUS end
    -- HP swing measured on effective HP pools
    u = u + C.W_HP * ((him.hp - res.his_hp) - (me.hp - res.my_hp))
    u = u + C.W_MANA * (res.mana_left - me.mana)
    -- strategic term: the *standing* after the horizon matters, not just the
    -- swing. Standing at 20 % HP against a 90 % enemy loses the lane even if
    -- nothing happens for the next three seconds.
    local mePct = res.my_hp / math.max(1, me.hp_max)
    local himPct = res.his_hp / math.max(1, him.hp_max)
    u = u + C.W_STAND * (mePct - himPct) * math.max(me.hp_max, him.hp_max)
    return u
end
WAR.Utility = utility

--[[
 WAR.Evaluate(state, opts) -> decision

 decision = {
   mode   = "KILL" | "TRADE" | "POKE" | "HOLD" | "ESCAPE" | "FARM",
   plan   = chosen policy table,
   ev     = its simulated result against the most likely enemy plan,
   worst  = simulated result against the worst enemy plan,
   score  = number,
   why    = human-readable reason,
 }
]]
function WAR.Evaluate(state, opts)
    opts = opts or {}
    local now = state.t or 0
    local myPlans = WAR.MyPlans(state, opts)
    local hisPlans = WAR.HisPlans(state, opts)
    local horizon = opts.horizon or C.HORIZON
    state.dt = opts.dt or C.DT

    local scored = {}
    for _, mp in ipairs(myPlans) do
        local worst, best, sum, n = nil, nil, 0, 0
        local worstUtil = 1e18
        local dieCount = 0
        for _, hp in ipairs(hisPlans) do
            local r = WAR.Simulate(state, mp, hp, horizon)
            local u = utility(state, r)
            sum = sum + u; n = n + 1
            if u < worstUtil then worstUtil = u; worst = r; worstPlan = hp end
            if not best or u > utility(state, best) then best = r end
            if r.my_dead then dieCount = dieCount + 1 end
        end
        scored[#scored + 1] = {
            plan = mp,
            worstUtil = worstUtil,
            avgUtil = sum / n,
            worst = worst,
            best = best,
            dieCount = dieCount,
            dieProb = dieCount / n,
        }
    end

    -- 1) a plan that is safe (never dies) and guarantees a kill in every
    --    enemy response is the answer
    local killPlan
    for _, s in ipairs(scored) do
        if s.dieCount == 0 then
            local allKill = true
            for _, hp in ipairs(hisPlans) do
                local r = WAR.Simulate(state, s.plan, hp, horizon)
                if not r.his_dead then allKill = false break end
            end
            if allKill then killPlan = s break end
        end
    end
    if killPlan then
        return { mode = "KILL", plan = killPlan.plan, ev = killPlan.worst,
                 worst = killPlan.worst, score = killPlan.worstUtil,
                 why = "guaranteed kill under every enemy response" }
    end

    -- 2) among the plans with zero death risk pick the best worst case
    local bestSafe
    for _, s in ipairs(scored) do
        if s.dieCount == 0 and (not bestSafe or s.worstUtil > bestSafe.worstUtil) then bestSafe = s end
    end

    -- 3) if nothing is safe, pick the plan with the lowest death probability,
    --    then the best worst case among those
    if not bestSafe then
        local lowest = 1
        for _, s in ipairs(scored) do if s.dieProb < lowest then lowest = s.dieProb end end
        local cand
        for _, s in ipairs(scored) do
            if s.dieProb <= lowest + 1e-9 and (not cand or s.worstUtil > cand.worstUtil) then cand = s end
        end
        if cand and cand.dieProb > 0 then
            local mode = "ESCAPE"
            for _, s in ipairs(scored) do
                if s.plan.flee and not s.plan.engage and s.dieProb <= cand.dieProb then mode = "ESCAPE" break end
            end
            return { mode = mode, plan = cand.plan, ev = cand.worst, worst = cand.worst,
                     score = cand.worstUtil, danger = true,
                     why = "every plan can lose the trade: minimise the loss" }
        end
    end

    -- 4) safe plans exist: decide what they are worth
    local s = bestSafe
    local mode = "HOLD"
    if s.plan.raze_policy == "burst" or s.plan.raze_policy == "trade" or s.plan.raze_policy == "lethal" then
        mode = "TRADE"
    elseif s.plan.raze_policy == "answer" then
        mode = "POKE"
    end
    if s.plan.flee then mode = "ESCAPE" end

    -- a trade with a negative worst case is not a trade, it is farming while
    -- the opponent is allowed to hit us: hold instead
    if mode == "TRADE" and (s.worst.his_hp - s.worst.my_hp) <= 0 and (s.worst.net or 0) <= 0 then
        -- look for the best non-aggressive safe plan
        for _, c in ipairs(scored) do
            if c.dieCount == 0 and c.plan.raze_policy == "none"
                and c.worstUtil > s.worstUtil then
                s = c; mode = "HOLD" break
            end
        end
    end

    return { mode = mode, plan = s.plan, ev = s.worst, worst = s.worst,
             avg = s.avgUtil, score = s.worstUtil,
             why = "best worst-case safe plan" }
end

--------------------------------------------------------------------------------
-- threat ledger (cheap, called every frame by the glue)
--------------------------------------------------------------------------------
--[[
 WAR.Threat(state) -> {
   his_burst_now, his_burst_cd, his_reach,        -- what he can do to me now
   my_burst_now, my_burst_cd, my_reach,
   lethal_if_close,   -- true when his ready burst >= my HP
   safe_distance,     -- the closest distance at which I survive his burst
   kill_distance,     -- the distance inside which I can finish him
   tt_his_dps, tt_my_dps,
 }
]]
function WAR.Threat(state)
    local now = state.t or 0
    local me, him = state.me, state.him
    local out = {}

    out.his_burst_now, out.his_n = WAR.Burst(him, me, 0.2, now)
    out.his_burst_cd, out.his_n_cd = WAR.Burst(him, me, C.RAZE_CD, now)
    out.my_burst_now, out.my_n = WAR.Burst(me, him, 0.2, now)
    out.my_burst_cd, out.my_n_cd = WAR.Burst(me, him, C.RAZE_CD, now)

    -- his razes reach at most FAR + radius from him
    out.his_reach = C.RAZE_DIST[3] + C.RAZE_RADIUS
    out.my_reach = C.RAZE_DIST[3] + C.RAZE_RADIUS

    -- right-click DPS that can actually reach me
    out.his_rc_dps = him.dmg / math.max(0.6, C.BAT)
    out.my_rc_dps = me.dmg / math.max(0.6, C.BAT)

    local creep = (state.creep_dps_on_me or 0)
    -- ENGINE TRUTH: damage in the air is already spent HP, not a forecast
    local incoming = (me.incoming or 0)
    out.incoming = incoming
    out.hp_eff = me.hp - incoming
    out.lethal_now = (out.his_burst_now + him.dmg * 2 + creep * 1.5 + incoming) >= me.hp
    out.lethal_soon = (out.his_burst_cd + him.dmg * 3 + creep * 2.5 + incoming) >= me.hp

    -- distance at which his *ready* burst alone cannot kill me
    local d = 0
    while d <= 1000 do
        local hits = 0
        if d <= C.RAZE_DIST[1] + C.RAZE_RADIUS then hits = hits + 1 end
        if d <= C.RAZE_DIST[2] + C.RAZE_RADIUS then hits = hits + 1 end
        if d <= C.RAZE_DIST[3] + C.RAZE_RADIUS then hits = hits + 1 end
        local reachDmg = 0
        local st = me.stacks or 0
        for i = 1, math.min(hits, out.his_n or 0) do
            reachDmg = reachDmg + WAR.RazeApplied(him.raze_level, st, him.souls, me.magic_resist)
            st = math.min(C.MAX_STACKS, st + 1)
        end
        if reachDmg + him.dmg * 2 + incoming < me.hp - C.SAFE_HP_ABS then out.safe_distance = d break end
        d = d + 25
    end
    out.safe_distance = out.safe_distance or 0

    -- can I finish him right now from where I am?
    out.can_kill_now = out.my_burst_now >= him.hp
    out.can_kill_soon = out.my_burst_cd + me.dmg * 2 >= him.hp
    return out
end

--------------------------------------------------------------------------------
-- self-test (run offline: WAR.SelfTest())
--------------------------------------------------------------------------------
function WAR.SelfTest()
    local fails = {}
    local function check(name, got, want, tol)
        tol = tol or 1e-6
        if math.abs(got - want) > tol then fails[#fails + 1] = string.format("%s: got %.3f want %.3f", name, got, want) end
    end
    -- raze damage: level 1, 0 stacks, 0 souls -> 90 raw, 67.5 applied
    check("raze L1 base", WAR.RazeApplied(1, 0, 0, 0.25), 67.5)
    -- level 4, 2 stacks, 10 souls -> 300 + 160 + 20 = 480 raw
    check("raze L4 stacked", WAR.RazeApplied(4, 2, 10, 0.25), 360.0)
    -- volley of 3 at level 3 (230/70), target with 0 stacks, 8 souls:
    --   (230+16) + (230+70+16) + (230+140+16) = 246+316+386 = 948 raw * 0.75
    check("volley3", WAR.VolleyDamage(3, 0, 8, 3, 0.25), 948 * 0.75)
    -- a unit with 600 HP must die to a 3-raze volley of level 3 with 8 souls
    if WAR.VolleyDamage(3, 0, 8, 3, 0.25) < 600 then fails[#fails+1] = "volley must kill 600hp" end
    return #fails == 0, fails
end

return WAR
