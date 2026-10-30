--[[
================================================================================
 WAR DIRECTOR — the bridge between WAR CORE (pure simulation) and the live game
================================================================================

 Responsibilities:
   * build the WAR state out of the live bot/enemy handles (damage numbers are
     the *applied* ones, cooldowns are absolute times, creep DPS is the real
     aggregate of the wave that is currently on top of each hero);
   * ask the engine for a decision at a bounded rate (default 8 Hz — one full
     plan search costs ~15 ms, which is affordable at that rate);
   * translate the chosen plan into exactly one order per tick, reusing the
     bot's existing executors (raze turn-then-cast, tower-safe movement,
     hero attack).

 The Director never decides alone: if the engine returns HOLD / POKE the
 Director stays out of the way and the legacy farming logic keeps the tick.
================================================================================
]]

local WAR = require("bots/nevermore/war_core")
-- ENGINE TRUTH: values read from the live engine (attack ranges, tower aggro
-- lock, damage already in the air) instead of replay-measured constants.
local ET  = require("bots/nevermore/engine_truth")
-- EXCHANGE TRUTH (v6.3): what an exchange is worth *before* it happens.
-- Pure arithmetic over the recorded/known quantities - calibrated on the
-- 24-episode ledger of replay 9066921447.
local XCH = require("bots/nevermore/exchange")

local D = {}

D.CFG = {
    ENABLED         = true,
    EVAL_INTERVAL   = 0.12,   -- s between full plan searches
    MAX_DIST        = 1500,   -- ignore the hero fight beyond this distance
    SEARCH_DT       = 1.0 / 20.0,
    SEARCH_HORIZON  = 2.6,
    VERIFY_HORIZON  = 3.2,
    -- safety: below this share of HP the Director keeps the fight logic even
    -- when the enemy is far away (that is exactly the situation the old bot
    -- lost: standing in lane at 15% HP)
    LOW_HP_PCT      = 0.34,
    -- strategic disengage (the layer above a 2.6 s horizon): when we are one
    -- volley away from death, or far behind on HP, we leave the lane instead
    -- of "standing at 20 % HP forever"
    RECOVER_BURST_PAD = 70,
    RECOVER_HP_PCT    = 0.34,
    RECOVER_HP_GAP    = 0.15,
    RECOVER_HOLD      = 2.4,     -- s of committed disengage
    RELEASE_DIST      = 1150,
    RELEASE_HP_PCT    = 0.55,
    -- never walk inside this radius of a live enemy T1 unless the plan says
    -- "kill is guaranteed"
    -- fallback only: the live radius comes from ET.TowerAggroRadius() and is
    -- written into CFG.TOWER_PAD at runtime (7.41f measured value: 865)
    TOWER_PAD       = 865,
    ENGINE_TRUTH    = true,   -- read ranges/aggro/in-flight damage from the engine
    INCOMING_MAX_LAND = 0.45, -- s: never charge an in-flight hit later than this
    TOWER_EXEC_SHOTS = 2.0,   -- tower shots that must be survivable while locked on
    -- log the distance at which the enemy T1 actually aggros on us (the same
    -- measurement the bot's tower radius is built on). One line per game.
    PROBE_TOWER_AGGRO = true,
    -- v6.3 EXCHANGE GATE: refuse an exchange whose arithmetic is not ours.
    -- The ledger of 9066921447: the bot took 3470 raze damage and dealt 3657,
    -- but in five of its six worst episodes it had 274-423 mana and 2-3 razes
    -- off cooldown and cast nothing - `pol="trade"` only fired when the enemy
    -- could not answer at all. This gate asks the opposite question: what does
    -- each side put into the other over the next 2.2 s.
    EXCHANGE_GATE   = true,
    EXCHANGE_LOG    = false,
    CREEP_MELEE_DPS = 15,
    CREEP_RANGE_DPS = 21,
    CREEP_REACH     = 420,
    DEBUG           = false,
}

local S = { lastEval = -100, last = nil, lastSig = "", evalCount = 0, mode = nil }

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------
local function loc2t(v) return { x = v.x, y = v.y } end

local function unit_dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function norm(x, y)
    local l = math.sqrt(x * x + y * y)
    if l < 1e-6 then return 0, 0 end
    return x / l, y / l
end

--[[ Aggregate DPS of a creep list against a hero standing at `loc`.
     KV-exact: the damage and the cadence of every lane creep come from
     npc_units.txt (melee 21 avg / 1.0 s, ranged 23.5 / 1.0 s in a 900 u/s
     projectile, siege 40.5 / 3.0 s). The old flat numbers (15 / 21 / 40) were
     wrong in both directions: siege creeps were feared 3x too much and ranged
     creeps 1.2x, so the bot walked out of waves it could have stood in and
     stood in waves it could not. Damage is scaled by the victim's armour. ]]--
local function creep_dps(creeps, loc, cfg, victim)
    if not creeps or not loc then return 0 end
    local KC = WAR.C.CREEP
    local armor = 0
    if victim and victim.GetPhysicalArmorValue then
        local ok, a = pcall(victim.GetPhysicalArmorValue, victim)
        if ok and type(a) == "number" then armor = a end
    end
    local mult = 1 - (0.06 * armor) / (1 + 0.06 * math.abs(armor))
    if mult < 0.05 then mult = 0.05 end
    local dps = 0
    local pad = KC.HULL_PAD or 45
    for _, c in pairs(creeps) do
        if c and c.GetLocation and c:IsAlive() then
            local nm = (c.GetUnitName and c:GetUnitName()) or ""
            local kind = "melee"
            if nm:find("siege") then kind = "siege"
            elseif nm:find("ranged") then kind = "ranged"
            elseif nm:find("flag") then kind = "flag" end
            local kv = KC[kind] or KC.melee
            local reach = (kv.range or 100) + pad
            if unit_dist(c:GetLocation(), loc) <= reach then
                dps = dps + (kv.dmg or 21) * mult / math.max(0.3, kv.bat or 1.0)
            end
        end
    end
    return dps
end

--------------------------------------------------------------------------------
-- engine truth (REA): the numbers the simulation runs on come from the game
--------------------------------------------------------------------------------
-- Applied damage of one T1 shot to an armoured hero: KV 90 x 0.735 (6 armour)
-- = 66. The raw 90 is what the tower *deals*; what the simulation needs is what
-- lands on the victim, and 66 is what the replays measured as well.
local C_TOWER_DMG, C_TOWER_INT = 66, 0.8182
local C_TOWER_KV_BASE = 700   -- AttackRange in npc_units.txt; the engine adds 165

--[[ Attach the engine's own view of one tower to the simulation entry:
       range   — the radius at which it starts shooting (was the 865 constant)
       dmg     — its true attack damage after our armour
       interval— seconds per attack
       aggro_me— the tower is *already locked on to us* (0.3-0.8 s of warning
                 before the first projectile even exists)
       next_shot — when its current cycle releases, not a fixed 0.35 s   ]]--
function D.ApplyTowerTruth(tw, victim, tower, cfg)
    if not tw or not cfg or not cfg.ENGINE_TRUTH then return end
    local f = ET.TowerFacts(victim, tower, 2, 1)
    if not f then return end
    tw.range = f.range
    tw.interval = f.interval or C_TOWER_INT
    -- the engine reports raw true damage; the simulation wants damage applied
    -- to *this* hero, so the victim's armour has to come off
    local raw = f.damage or C_TOWER_DMG
    local armour = 0
    if victim and victim.GetPhysicalArmorValue then
        local ok, a = pcall(victim.GetPhysicalArmorValue, victim)
        if ok and type(a) == "number" then armour = a end
    end
    local mult = 1 - (0.06 * armour) / (1 + 0.06 * math.abs(armour))
    if mult < 0.05 then mult = 0.05 end
    tw.dmg = raw * mult
    tw.raw_damage = raw
    tw.aggro_me = f.targeting_me and true or false
    -- KV: the tower winds up for AttackAnimationPoint before the projectile
    -- exists, and the shot is homing at ProjectileSpeed - a shot fired while we
    -- are inside the radius still lands after we have left it
    tw.windup = f.windup or ET.FALLBACK.TOWER_WINDUP
    tw.proj_speed = f.proj_speed or ET.FALLBACK.TOWER_PROJ
    tw.acquire = f.acquire or nil
    if f.next_shot_in then
        tw.next_shot = math.max(0.05, math.min(f.next_shot_in, tw.interval))
    end
    cfg.TOWER_PAD = tw.range
    -- PROBE: the first time the live tower locks on to us, print the distance.
    -- This is the controlled experiment "walk until it aggros" done in-game:
    -- the number must be the 865 the radius is built on.
    if cfg.PROBE_TOWER_AGGRO and f.targeting_me and not D.State.aggroLogged then
        D.State.aggroLogged = true
        local victim_loc = (victim and victim.GetLocation) and victim:GetLocation() or nil
        if victim_loc then
            local dx = victim_loc.x - tw.x
            local dy = victim_loc.y - tw.y
            local dist = math.sqrt(dx * dx + dy * dy)
            print(string.format("[WAR] T1 aggro probe: locked on at %.0f u (model %.0f u, KV base %s)",
                dist, tw.range, tostring((C_TOWER_KV_BASE) or "700")))
        end
    end
end

--[[ Fill `u.incoming` with the damage of every projectile already aimed at the
     hero. `dmg_of` resolves one projectile to damage; anything unresolvable
     makes the whole sum fall back to the worst known single hit, because an
     unknown projectile is a reason to be *more* careful, never less. ]]--
function D.ApplyIncoming(u, live, env)
    if not u or not live then return end
    local cfg = D.CFG
    if not cfg.ENGINE_TRUTH then return end
    local dmg_of = nil
    if env and env.projectileDamage then dmg_of = env.projectileDamage end
    local total, n = ET.IncomingDamage(live, dmg_of)
    if total == nil then
        -- one unknown projectile: charge the worst we know (his right-click)
        total = (env and env.enemyDamageVsMe) or 75
        n = n or 1
    end
    if total and total > 0 then
        u.incoming = total
        u.incoming_at = math.min(cfg.INCOMING_MAX_LAND, 0.18)
        u.incoming_n = n
    end
end

--------------------------------------------------------------------------------
-- state construction
--------------------------------------------------------------------------------
--[[
 env = {
   now = GameTime(),
   enemyDamageVsMe, myDamageVsHim,   -- applied right-click damage
   mySouls, hisSouls,
   myRazeLevel, hisRazeLevel,
   myRazeReady = {t1,t2,t3}, hisRazeReady = {t1,t2,t3},   -- absolute times
   myRegen, myManaRegen,
   enemyT1Loc, enemyT1Alive, ownT1Loc,
   enemyCreeps, allyCreeps,
 }
]]
--[[ Velocity of the enemy from the director's own position history: the
     engine does not expose it and FindShot needs it (`foe.vx/vy`), otherwise
     every raze is aimed at where he *is* instead of where he will be when the
     0.55 s cast ends.  Measured: 32 % of the bot's casts landed, 50 % of the
     human's - the whole gap is this prediction. ]]--
function D.TrackVelocity(loc, now)
    local T = S.track
    if not T then T = {}; S.track = T end
    if not T.t or now - T.t > 0.02 then
        T.px, T.py, T.pt = T.lx, T.ly, T.lt
        T.lx, T.ly, T.lt = loc.x, loc.y, now
        T.t = now
    end
    local dt = (T.lt or 0) - (T.pt or 0)
    if not T.px or dt <= 0.02 or dt > 1.2 then return 0, 0 end
    local vx = (T.lx - T.px) / dt
    local vy = (T.ly - T.py) / dt
    local sp = math.sqrt(vx * vx + vy * vy)
    if sp > 900 then return 0, 0 end          -- teleport / respawn spike
    return vx, vy
end

function D.BuildState(bot, s, env)
    local cfg = D.CFG
    local now = env.now or 0
    local me = {
        x = bot:GetLocation().x, y = bot:GetLocation().y,
        hp = bot:GetHealth(), hp_max = bot:GetMaxHealth(),
        mana = bot:GetMana(),
        dmg = env.myDamageVsHim or 0,
        souls = env.mySouls or 0,
        raze_level = env.myRazeLevel or 0,
        raze_ready = { 0, 0, 0 },
        ms = bot:GetCurrentMovementSpeed() or 305,
        regen_hp = env.myRegen or 1.0,
        regen_mana = env.myManaRegen or 1.0,
        magic_resist = 0.25,
        stick_charges = env.myStickCharges or 0,
        mango = env.myMango or false,
    }
    local e = s.enemy
    local el = e and e:GetLocation() or { x = 0, y = 0 }
    local him = {
        x = el.x, y = el.y,
        hp = e and e:GetHealth() or 1, hp_max = e and e:GetMaxHealth() or 1,
        mana = e and e:GetMana() or 0,
        dmg = env.enemyDamageVsMe or 0,
        souls = env.hisSouls or 0,
        raze_level = env.hisRazeLevel or 0,
        raze_ready = { 0, 0, 0 },
        ms = (e and e:GetCurrentMovementSpeed()) or 305,
        regen_hp = 1.0, regen_mana = 1.0,
        magic_resist = 0.25,
    }
    local function rel(t) local d = (t or 0) - now if d < 0 then d = 0 end return d end
    me.raze_ready = { rel((env.myRazeReady or {})[1]), rel((env.myRazeReady or {})[2]), rel((env.myRazeReady or {})[3]) }
    him.raze_ready = { rel((env.hisRazeReady or {})[1]), rel((env.hisRazeReady or {})[2]), rel((env.hisRazeReady or {})[3]) }
    -- engine-truth speed of both heroes for the exchange arithmetic
    me.ms = (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or me.ms or 305
    him.ms = (e and e.GetCurrentMovementSpeed and e:GetCurrentMovementSpeed()) or him.ms or 305
    -- his velocity from our own history, his cast lock from the raze tracker
    if e and e.GetLocation then
        local vx, vy = D.TrackVelocity(el, now)
        him.vx, him.vy = vx, vy
    end
    if env.hisCastLeft then him.cast_left = env.hisCastLeft end
    if env.hisCastBand then him.cast_band = env.hisCastBand end
    if bot.IsUsingAbility then
        local ok, cast = pcall(bot.IsUsingAbility, bot)
        if ok and cast then me.cast_left = 0.55 end
    end
    local st = {
        t = 0,
        me = me, him = him,
        dist = unit_dist(me, him),
        creep_dps_on_me = creep_dps(s.enemyCreeps, me, cfg, bot),
        creep_dps_on_him = creep_dps(s.allyCreeps, him, cfg, e),
        tower = nil,
        gt = now,
    }
    if env.enemyT1Alive and env.enemyT1Loc then
        st.tower = { x = env.enemyT1Loc.x, y = env.enemyT1Loc.y,
                     dmg = C_TOWER_DMG, interval = C_TOWER_INT }
        D.ApplyTowerTruth(st.tower, bot, env.enemyT1, cfg)
    end
    if env.ownT1Loc then
        st.own_tower = { x = env.ownT1Loc.x, y = env.ownT1Loc.y,
                         dmg = C_TOWER_DMG, interval = C_TOWER_INT }
        D.ApplyTowerTruth(st.own_tower, e, env.ownT1, cfg)
    end
    -- damage already flying at us: spent HP, not a forecast
    D.ApplyIncoming(me, bot, env)
    if e and e.GetLocation then D.ApplyIncoming(him, e, nil) end
    -- where HE runs when he is losing
    if env.enemyT1Alive and env.enemyT1Loc then
        st.his_flee = { x = env.enemyT1Loc.x, y = env.enemyT1Loc.y }
    else
        st.his_flee = nil
    end
    -- flee candidate: away from him, biased towards our own T1
    local ax, ay = norm(me.x - him.x, me.y - him.y)
    local bx, by = norm((env.ownT1Loc and env.ownT1Loc.x or me.x) - me.x,
                        (env.ownT1Loc and env.ownT1Loc.y or me.y) - me.y)
    local fx, fy = norm(ax * 0.75 + bx * 0.45, ay * 0.75 + by * 0.45)
    st.flee_points = { { x = me.x + fx * 700, y = me.y + fy * 700 },
                       { x = me.x + bx * 650, y = me.y + by * 650 } }
    -- EXCHANGE TRUTH: the arithmetic of the next 2.2 s
    if cfg.EXCHANGE_GATE then
        local xst = {
            dist = st.dist,
            locked = (him.cast_left and him.cast_left > 0.1) and him.cast_left or 0,
            me = { hp = me.hp, hp_max = me.hp_max, mana = me.mana,
                   mana_regen = me.regen_mana, ms = me.ms, dmg = me.dmg,
                   rlvl = me.raze_level, souls = me.souls,
                   cd = me.raze_ready, cast_left = me.cast_left },
            him = { hp = him.hp, hp_max = him.hp_max, mana = him.mana,
                    mana_regen = him.regen_mana, ms = him.ms, dmg = him.dmg,
                    rlvl = him.raze_level, souls = him.souls,
                    cd = him.raze_ready, cast_left = him.cast_left },
            creep_dps_on_me  = st.creep_dps_on_me,
            creep_dps_on_him = st.creep_dps_on_him,
            -- our own T1 shooting him / his T1 shooting us: both are part of the
            -- exchange arithmetic (measured: he took 822 free tower damage)
            tower_on_him = (st.own_tower and st.own_tower.aggro_me)
                and (st.own_tower.dmg or 66) / math.max(0.5, st.own_tower.interval or 0.82) or 0,
            tower_on_me  = (st.tower and st.tower.aggro_me)
                and (st.tower.dmg or 66) / math.max(0.5, st.tower.interval or 0.82) or 0,
        }
        st.exchange = XCH.Verdict(xst)
        -- his cast is a 0.55 s window with the circle already placed: answer it,
        -- step out of it, or at least trade swings - never stand still
        if him.cast_left and him.cast_left > 0 and him.cast_band then
            st.react_action, _, st.react_band = XCH.React(
                st.dist, him.cast_band, him.cast_left,
                { hp = me.hp, hp_max = me.hp_max, mana = me.mana, ms = me.ms,
                  dmg = me.dmg, rlvl = me.raze_level, souls = me.souls,
                  raze_dmg = nil, cd = me.raze_ready },
                { hp = him.hp, hp_max = him.hp_max, dmg = him.dmg, ms = him.ms,
                  raze_dmg = XCH.RazeDamage(him.raze_level or 0, him.souls or 0) })
            st.react_centre = nil
            if env.hisCastCentre then st.react_centre = env.hisCastCentre end
        end
        st.safe_dist = XCH.SafeDistance({ cd = him.raze_ready })
        if cfg.EXCHANGE_LOG and (not S.lastLog or now - S.lastLog > 1.0) then
            S.lastLog = now
            print(string.format("[XCH] %.2f %s | me %.0f/%d razes -> %.0f | him %.0f/%d -> %.0f | d=%.0f safe=%.0f",
                now, st.exchange.verdict, st.exchange.my_total, st.exchange.my_n,
                st.exchange.my_raze, st.exchange.his_raze, st.exchange.his_n,
                st.exchange.his_total, st.dist, st.safe_dist))
        end
    end
    return st
end

--------------------------------------------------------------------------------
-- decision (throttled)
--------------------------------------------------------------------------------
function D.Decide(st, now)
    local cfg = D.CFG
    if not cfg.ENABLED then return nil end
    if st.tower and false then end
    local sig = string.format("%d|%d|%d|%d|%d|%d|%d",
        math.floor(st.me.hp / 25), math.floor(st.him.hp / 25),
        math.floor(unit_dist(st.me, st.him) / 100),
        math.floor(st.me.mana / 50), math.floor(now * 2),
        (st.him.hp <= (st.me.dmg * 3) and 1 or 0),
        (st.me.hp <= (st.him.dmg * 3) and 1 or 0))
    if S.last and (now - S.lastEval) < cfg.EVAL_INTERVAL and sig == S.lastSig then
        return S.last
    end
    S.lastEval = now
    S.lastSig = sig
    S.evalCount = S.evalCount + 1
    local d = WAR.Evaluate(st, {
        dt = cfg.SEARCH_DT,
        horizon = cfg.SEARCH_HORIZON,
        flee_points = st.flee_points,
    })
    d = D.Override(st, d, now)
    S.last = d
    S.mode = d.mode
    return d
end

--------------------------------------------------------------------------------
-- execution
--------------------------------------------------------------------------------
local function attack_target_is_free(bot, s, myDmg)
    -- do not trade a last hit for a hero swing
    if s.enemyCreeps then
        for _, c in pairs(s.enemyCreeps) do
            if c and c.GetHealth and c:IsAlive() and c:GetHealth() <= myDmg + 25 then
                local l = c:GetLocation()
                if unit_dist(l, bot:GetLocation()) <= 620 then return false end
            end
        end
    end
    return true
end

--[[
 Execute the decision. `env` carries the executors:
   env.castRaze(bot, abilityIndex, aimLoc, enemy) -> bool
   env.moveTo(loc) -> bool
   env.attackHero() -> bool
   env.razeAbility(idx) -> ability handle
]]
function D.Execute(bot, s, dec, env)
    local cfg = D.CFG
    local st = env.state
    local e = s.enemy
    if not e or not e:IsAlive() then return false end
    local meLoc = bot:GetLocation()
    local eLoc = e:GetLocation()
    local dist = unit_dist(meLoc, eLoc)
    local plan = dec.plan or {}

    --[[ REACTION (v6.4). Replay 5: the bot stood COMPLETELY STILL through five of
         the human's razes (0-16 u of movement during a 0.55 s cast) and answered
         two of the episodes that killed it with nothing at all. The window of his
         cast is the single most valuable moment in the lane: he cannot move.

           ANSWER - our own raze at his current point (cannot be dodged by him)
           STEP   - shortest radial exit from the circle centre
           TRADE  - eat it, but throw a right-click back

         This runs before the plan because it is a reaction, not a plan; it
         yields to ESCAPE only when ESCAPE is running away from a tower. ]]--
    if st.react_action then
        if st.react_action == "answer" then
            local probeMe = {
                x = meLoc.x, y = meLoc.y, ms = st.me.ms, hp = st.me.hp, hp_max = st.me.hp_max,
                mana = st.me.mana, raze_level = st.me.raze_level,
                raze_ready = { st.me.raze_ready[1], st.me.raze_ready[2], st.me.raze_ready[3] },
                souls = st.me.souls, alive = true,
            }
            local probeHim = {
                x = eLoc.x, y = eLoc.y, ms = 0, hp = st.him.hp, hp_max = st.him.hp_max,
                mana = st.him.mana, raze_level = st.him.raze_level,
                raze_ready = { st.him.raze_ready[1], st.him.raze_ready[2], st.him.raze_ready[3] },
                souls = st.him.souls, alive = true,
                atk_until = (env.now or 0) + 0.6,
            }
            local shot = WAR.FindShot(probeMe, probeHim, 0, "poor")
            if shot and env.castRaze(bot, shot, eLoc, e) then return true end
        elseif st.react_action == "step" and st.react_centre then
            if dec.mode ~= "ESCAPE" then
                local need = XCH.C.RADIUS -
                    math.abs(st.dist - (XCH.C.BANDS[st.him.cast_band or 3] or 700))
                local px, py = XCH.ExitPoint(meLoc.x, meLoc.y, st.react_centre.x, st.react_centre.y,
                                             math.max(60, need), nil, 50)
                return env.moveTo({ x = px, y = py })
            end
        elseif st.react_action == "eat" and st.react_centre and dec.mode ~= "ESCAPE" then
            -- cannot clear the circle: walk the shortest radial way out anyway.
            -- The recorded death (replay 6, t = 263.2) ran ALONG the circle.
            local need = XCH.C.RADIUS -
                math.abs(st.dist - (XCH.C.BANDS[st.him.cast_band or 3] or 700))
            local step = (st.me.ms or 305) * 0.45
            local px, py = XCH.ExitPoint(meLoc.x, meLoc.y, st.react_centre.x, st.react_centre.y,
                                         math.max(40, math.min(need, step * 0.9)), nil, 20)
            return env.moveTo({ x = px, y = py })
        elseif st.react_action == "trade" then
            if dec.mode ~= "ESCAPE" and env.attackHero then return env.attackHero() end
        end
    end

    if dec.mode == "ESCAPE" then
        -- run along the lane towards our own T1, away from him
        local fp = st.flee_points and st.flee_points[2] or st.flee_points and st.flee_points[1]
        if not fp then return false end
        return env.moveTo(fp)
    end

    --[[ PUNISH: he is inside his own 0.55 s cast and cannot move. Our raze
         aimed at his current point cannot be dodged by him either. This is the
         reaction the ledger says was missing: 18 of the human's 28 casts went
         unanswered within 1.2 s on the big-ticket episodes. ]]--
    if dec.mode == "PUNISH" or (st.exchange and st.exchange.verdict == "PUNISH"
            and dec.mode ~= "ESCAPE") then
        local probeMe = {
            x = meLoc.x, y = meLoc.y, ms = st.me.ms, hp = st.me.hp, hp_max = st.me.hp_max,
            mana = st.me.mana, raze_level = st.me.raze_level,
            raze_ready = { st.me.raze_ready[1], st.me.raze_ready[2], st.me.raze_ready[3] },
            souls = st.me.souls, alive = true,
        }
        local probeHim = {
            x = eLoc.x, y = eLoc.y, ms = 0, hp = st.him.hp, hp_max = st.him.hp_max,
            mana = st.him.mana, raze_level = st.him.raze_level,
            raze_ready = { st.him.raze_ready[1], st.him.raze_ready[2], st.him.raze_ready[3] },
            souls = st.him.souls, alive = true,
            atk_until = (env.now or 0) + 0.6,   -- pinned: no escape while he casts
        }
        local shot = WAR.FindShot(probeMe, probeHim, 0, "poor")
        if shot then return env.castRaze(bot, shot, eLoc, e) end
    end

    --[[ BRAWL (exchange gate): nobody has mana, so the fight is right-clicks,
         creep aggro and towers. Close only as far as our own attack range and
         keep swinging - and do not stand inside his wave while doing it. ]]--
    if dec.mode == "BRAWL" then
        local reach = (bot.GetAttackRange and bot:GetAttackRange() or 500) + 20
        if dist > reach and not attack_target_is_free(bot, s, st.me.dmg) then
            local hold = math.min(reach - 40, 520)
            local dx, dy = norm(eLoc.x - meLoc.x, eLoc.y - meLoc.y)
            return env.moveTo({ x = meLoc.x + dx * math.min(300, dist - hold), y = meLoc.y + dy * math.min(300, dist - hold) })
        end
        if dist <= reach and env.attackHero then return env.attackHero() end
        return env.approach(e)
    end

    --[[ POKE (exchange gate, REFUSE): stay exactly outside the reach of his
         ready bands. Inside it we are a target; far outside it we are not
         farming the lane. ]]--
    if dec.mode == "POKE" then
        local hold = dec.plan and dec.plan.hold_dist or (st.safe_dist or 900)
        if dist < hold - 60 then
            local dx, dy = norm(meLoc.x - eLoc.x, meLoc.y - eLoc.y)
            return env.moveTo({ x = meLoc.x + dx * math.min(320, hold - dist + 60),
                                y = meLoc.y + dy * math.min(320, hold - dist + 60) })
        end
        return false
    end

    if dec.mode == "KILL" or dec.mode == "TRADE" then
        -- 1) a raze that can land right now?
        local probeMe = {
            x = meLoc.x, y = meLoc.y, ms = st.me.ms, hp = st.me.hp, hp_max = st.me.hp_max,
            mana = st.me.mana, raze_level = st.me.raze_level,
            raze_ready = { st.me.raze_ready[1], st.me.raze_ready[2], st.me.raze_ready[3] },
            souls = st.me.souls, alive = true,
        }
        local probeHim = {
            x = eLoc.x, y = eLoc.y, ms = st.him.ms, hp = st.him.hp, hp_max = st.him.hp_max,
            mana = st.him.mana, raze_level = st.him.raze_level,
            raze_ready = { st.him.raze_ready[1], st.him.raze_ready[2], st.him.raze_ready[3] },
            souls = st.him.souls, alive = true,
        }
        local shot = WAR.FindShot(probeMe, probeHim, 0, dec.mode == "KILL" and "poor" or "solid")
        if shot then
            return env.castRaze(bot, shot, eLoc, e)
        end
        -- 2) spacing
        local hold = plan.hold_dist or 430
        if dec.mode == "KILL" and dist > 480 then
            return env.approach(e)
        end
        if dist > hold + 70 then return env.approach(e) end
        if dist < hold - 120 then
            local dx, dy = norm(meLoc.x - eLoc.x, meLoc.y - eLoc.y)
            return env.moveTo({ x = meLoc.x + dx * (hold - dist + 40), y = meLoc.y + dy * (hold - dist + 40) })
        end
        -- 3) right click, if it does not cost a last hit
        if dist <= bot:GetAttackRange() + 20 and attack_target_is_free(bot, s, st.me.dmg) then
            return env.attackHero()
        end
    end

    --[[ FREE DAMAGE (v6.4). Replay 5: the human threw 31 hero right-clicks for
         2041 damage, the bot 6 for 346 - and both deaths came from exactly that
         channel (7 and 8 swings). A right-click costs no mana and does not
         cancel a raze that is not being cast, so on every path that is not a
         committed escape a swing at an in-range hero is free weight. ]]--
    if dec.mode ~= "ESCAPE" and st.exchange and XCH.ShouldAttack(st.me, st.him, dist) then
        if attack_target_is_free(bot, s, st.me.dmg) then
            if env.attackHero then return env.attackHero() end
        end
    end
    return false
end

--[[
 Strategic override, evaluated on top of the tactical plan:
   * a guaranteed kill always wins (that is the whole point of the engine);
   * otherwise, "one volley away from death" or "far behind on HP" forces a
     committed disengage for RECOVER_HOLD seconds. Without it the engine is
     indifferent between kiting at 720 and running home inside a 2.6 s
     horizon, and the bot keeps standing in lane at 15 % HP - exactly the
     behaviour that lost demo 2 (156 s below 30 % HP).
]]
function D.Override(st, dec, now)
    local S = D.State
    if dec and dec.mode == "KILL" then
        S.escapeUntil = 0
        return dec
    end
    local cfg = D.CFG
    local mePct = st.me.hp / math.max(1, st.me.hp_max)
    local hisPct = st.him.hp / math.max(1, st.him.hp_max)
    local hisBurst = WAR.Burst(st.him, st.me, 1.6, 0) + st.him.dmg * 1.2
    local oneVolleyFromDeath = st.me.hp <= hisBurst + cfg.RECOVER_BURST_PAD
    local farBehind = (mePct < cfg.RECOVER_HP_PCT) and (hisPct > mePct + cfg.RECOVER_HP_GAP)
    local tacticalDanger = dec and dec.mode == "ESCAPE"

    --[[ ENGINE TRUTH — tower execution check.
         The tower knows whom it is shooting before the projectile exists
         (GetAggroTarget / GetTowerAttackTarget). Combine that lock with the
         number of shots that can still land before we clear its live radius:
         if that total exceeds our *effective* HP (HP minus what is already in
         the air), staying is not a plan, it is a death. This is the exact
         failure of the measured replays - 12 + 11 + 3 tower hits eaten while
         the old logic believed it was 85-165 units outside the radius. ]]--
    local towerKill = false
    if st.tower then
        local radius = st.tower.range or cfg.TOWER_PAD
        local d = unit_dist(st.me, st.tower)
        local hpEff = st.me.hp - (st.me.incoming or 0)
        local shots = 0
        if st.tower.aggro_me then shots = shots + 1 end
        if d <= radius then
            local ms = math.max(200, st.me.ms or 305)
            -- Time until we are genuinely out of danger: walk out of the live
            -- radius + the tower's wind-up (a cycle started before we left
            -- still releases) + the homing projectile's flight to us. The KV
            -- says the shot lands anyway; walk-out time alone was optimistic.
            local exitT = (radius - d) / ms +
                           (st.tower.windup or 0.6) +
                           d / math.max(1, st.tower.proj_speed or 750)
            local per = math.max(0.5, st.tower.interval or 0.83)
            shots = shots + math.floor(exitT / per)
            if shots < 1 then shots = 1 end
        end
        local killDmg = shots * (st.tower.dmg or 90)
        if shots > 0 and hpEff <= killDmg * 0.85 then towerKill = true end
        st.tower.shots_to_die = shots
        st.tower.kill_dmg = killDmg
        st.tower.hp_eff = hpEff
    end

    if towerKill or oneVolleyFromDeath or farBehind or tacticalDanger then
        S.escapeUntil = math.max(S.escapeUntil or 0, now + cfg.RECOVER_HOLD)
        S.escapeFrom = { x = st.him.x, y = st.him.y }
    end
    if (S.escapeUntil or 0) > now then
        local dx, dy = unit_dist(st.me, st.him), nil
        if mePct >= cfg.RELEASE_HP_PCT and dx > cfg.RELEASE_DIST then
            S.escapeUntil = 0
        else
            return { mode = "ESCAPE", plan = { flee = true },
                     why = towerKill and "tower execution" or
                           (oneVolleyFromDeath and "one volley from death" or
                           (farBehind and "far behind on HP" or "tactical retreat")) }
        end
    end
    --[[ EXCHANGE GATE (v6.3).
         DISENGAGE - we cannot put a raze into him and he can put one into us:
                     walking out is the only move that is not a loss.
         REFUSE    - both sides can trade but his burst beats ours: keep the
                     distance at which his *ready* bands cannot reach, do not
                     open, wait for his cooldown / a lock / a mana window.
         PUNISH    - he is pinned in his own cast: cast at his current point.
         The gate sits BELOW the tower execution and the one-volley-from-death
         checks: those two answers are not negotiable, the exchange arithmetic
         only decides the trades that are still open. ]]--
    local x = st.exchange
    if x and cfg.EXCHANGE_GATE then
        if x.verdict == "DISENGAGE" then
            S.escapeUntil = math.max(S.escapeUntil or 0, now + cfg.RECOVER_HOLD)
            return { mode = "ESCAPE", plan = { flee = true },
                     why = "exchange: " .. tostring(x.why) }
        end
        --[[ ENTER used to fall through to the engine, and the engine is free to
             answer HOLD - i.e. the gate said "this trade is ours" and nothing
             happened. The verdict now produces the plan itself. ]]--
        if x.verdict == "ENTER" and dec and dec.mode ~= "KILL" then
            return { mode = "TRADE", plan = { name = "exchange_enter", hold_dist = st.safe_dist or 700,
                     raze_policy = "trade", raze_quality = "solid", engage = true, attack = true },
                     why = "exchange: " .. tostring(x.why), exchange = x }
        end
        if x.verdict == "BRAWL" and dec and dec.mode ~= "KILL" then
            return { mode = "BRAWL", plan = { name = "exchange_brawl", engage = true, attack = true },
                     why = "exchange: " .. tostring(x.why), exchange = x }
        end
        if x.verdict == "REFUSE" and dec and dec.mode ~= "KILL" then
            return { mode = "POKE", plan = { enforce = true, hold_dist = st.safe_dist,
                     raze_policy = "answer" }, why = "exchange: " .. tostring(x.why),
                     exchange = x }
        end
    end

    return dec
end

function D.Reset()
    S.lastEval = -100; S.last = nil; S.lastSig = ""
end

D.State = S

return D
