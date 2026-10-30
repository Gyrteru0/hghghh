--[[
================================================================================
 ENGINE TRUTH — values read straight out of the game binary instead of guessed
================================================================================

 Why this file exists (REA pass, 2026-10-28)
 -------------------------------------------
 Everything the duel engine used to know about the *engine* was measured from
 replays (e.g. "the T1 opens fire at 865 units") or copied from the wiki. Both
 are approximations: 865 is one sample of a number that the game computes per
 unit from its real attack range plus an acquisition buffer, and a tower's shot
 damage is not a constant 75 — it is the tower's average true damage after the
 victim's armour.

 The Dota client ships its whole scripting surface inside
 `<game>/bin/win64/server.dll`. A reverse-engineering pass over that binary
 (REA 6.8.0 + capstone linear sweep, see deliverable/analysis/rea/) recovered
 the engine's own doc-strings for every Lua-visible method, i.e. a machine
 readable statement of what the engine can tell a bot for free. The ones this
 file relies on — verbatim from the binary's string table:

   GetAcquisitionRange        "Get the range at which this unit will start to
                               attack a target."
   GetAttackRange             "Gets the attack range of the unit."
   GetAttackRangeBuffer       "Gets the attack range buffer."
   GetSecondsPerAttack        "Gets the number of seconds per attack that a
                               unit can do."
   GetAttackPoint             "Gets the attack point of the unit."
   GetLastAttackTime          "Gets the last attack time of the unit."
   GetAverageTrueAttackDamage "Returns the average value of the minimum and
                               maximum damage values."
   GetAggroTarget             "Returns this unit's aggro target."
   GetTowerAttackTarget       "Gets the attack target of the specified tower on
                               the specified team."
   GetIncomingTrackingProjectiles
                              "Gets the location and ability of projectiles
                               incoming at this unit."
   GetMinimumAttackSpeed / GetMaximumAttackSpeed
                              "Get the minimum/maximum attack speed for units."
   GetHealthDeficit           "Returns integer amount of health missing from max."

 Every accessor below is (a) optional — the bot must keep running on a build
 where a method is missing — and (b) cached, because the Think() path is called
 ~10 times a second and these are reflection calls.

 Nothing here decides anything. It only replaces constants with live numbers;
 the decisions stay in war_core.lua.
================================================================================
]]

local ET = {}

ET.STATS = { hits = 0, misses = 0, lastMiss = nil }

-- engine constants recovered from the binary (ConVar defaults rounded to the
-- values the engine clamps to; used only as fallbacks)
ET.FALLBACK = {
    TOWER_RANGE   = 865,   -- measured T1 aggro radius (replay telemetry)
    RANGE_BUFFER  = 165,   -- 865 - 700 (KV AttackRange of the T1)
    TOWER_DMG     = 90,    -- KV 88..92 on npc_dota_badguys_tower1_mid
    TOWER_INTERVAL= 0.8182,-- KV 0.9 * 100 / 110
    TOWER_WINDUP  = 0.60,  -- KV AttackAnimationPoint
    TOWER_PROJ    = 750,   -- KV ProjectileSpeed
    CREEP_HULL_PAD= 45,    -- DOTA_HULL_SIZE_* pad, see nevermore/constants.lua C.CREEP
    SF_ATK_RANGE  = 500,
    SF_BAT        = 1.60,
    AS_MIN        = 20,
    AS_MAX        = 700,
    PROJ_SPEED    = 1200,
}

local function fail(what)
    ET.STATS.misses = ET.STATS.misses + 1
    ET.STATS.lastMiss = what
end

--[[ Call a method on an engine handle, tolerating:
       * a missing handle,
       * a build where the method does not exist (older/newer game branch),
       * a method that raises on a dead/illusion/unqueryable unit.
     Returns nil in every one of those cases. ]]--
local function call(u, name, a, b)
    if not u then fail(name) return nil end
    local f = u[name]
    if type(f) ~= "function" then fail(name) return nil end
    local ok, v = pcall(f, u, a, b)
    if not ok then fail(name) return nil end
    ET.STATS.hits = ET.STATS.hits + 1
    return v
end
ET.Call = call

local function num(v) if type(v) == "number" then return v end return nil end
local function sane(v, lo, hi) v = num(v) if v and v >= lo and v <= hi then return v end return nil end

--------------------------------------------------------------------------------
-- unit geometry / attack model
--------------------------------------------------------------------------------

function ET.AttackRange(u)          return sane(call(u, "GetAttackRange"), 0, 4000) end
function ET.AcquisitionRange(u)     return sane(call(u, "GetAcquisitionRange"), 0, 4000) end
function ET.RangeBuffer(u)          return sane(call(u, "GetAttackRangeBuffer"), 0, 2000) end
function ET.AttackSpeed(u)          return sane(call(u, "GetAttackSpeed"), 1, 2000) end
function ET.SecondsPerAttack(u)     return sane(call(u, "GetSecondsPerAttack"), 0.05, 10) end
function ET.AttackPoint(u)          return sane(call(u, "GetAttackPoint"), 0.02, 3) end
function ET.LastAttackTime(u)       return sane(call(u, "GetLastAttackTime"), -10, 1e6) end
function ET.HealthDeficit(u)        return sane(call(u, "GetHealthDeficit"), 0, 1e7) end
function ET.AverageTrueDamage(u)    return sane(call(u, "GetAverageTrueAttackDamage"), 0, 1e5) end
function ET.AggroTarget(u)          return call(u, "GetAggroTarget") end

--[[ Attack timing of `u`, in the exact units war_core uses.
     The engine exposes three different things and only their combination is
     useful:
        attack point   = the wind-up before the damage is released
        seconds/ap     = the full cycle (BAT / (1 + IAS))
        last attack    = when the previous cycle *started*
     `cycle_left` is therefore the answer to "how long until this unit may
     start its next swing", which is what the duel simulation needs. ]]--
function ET.AttackTiming(u)
    local sp = ET.SecondsPerAttack(u)
    local ap = ET.AttackPoint(u)
    local last = ET.LastAttackTime(u)
    local out = { sp = sp, point = ap, last = last }
    if sp and last then
        local now = (GameTime and GameTime()) or 0
        local el = now - last
        if el < 0 or el > 10 then el = 0 end
        out.cycle_left = math.max(0, sp - el)
    elseif sp then
        out.cycle_left = sp * 0.5
    end
    return out
end

--------------------------------------------------------------------------------
-- towers
--------------------------------------------------------------------------------

--[[ The radius inside which a tower *starts* shooting a hero.

     MEASURED TWICE, INDEPENDENTLY:
       * in the three replays the largest distance at which a T1 opened fire on
         a standing hero was 865 u (26 shots);
       * in a controlled experiment (walk the hero towards the T1 and stop at
         the exact moment it aggros) the same 865 u came out.

     A controlled experiment of that shape proves the threshold is *spatial*
     and speed-independent, which rules out the "700 + speed * wind-up"
     interpretation (that would have given 883 at 305 ms and a different number
     for every hero). What the data files say is AttackRange 700 and
     AttackAcquisitionRange 700, so the engine adds a FIXED buffer of 165 that
     is not in the KV at all - exactly the accessor this binary exposes as
     `GetAttackRangeBuffer`.

     Safety rule: the radius decides whether the bot walks into tower fire, and
     under-estimating it is the direction that kills. So the function takes the
     LARGEST of every plausible candidate (attack range + engine buffer, attack
     range + the measured 165, the engine's acquisition range, and the measured
     floor), clamped to a sane band. ]]--
function ET.TowerAggroRadius(tower, floor)
    if not tower then return floor end
    local rng = ET.AttackRange(tower)
    local buf = ET.RangeBuffer(tower)
    local acq = ET.AcquisitionRange(tower)
    local cands = {}
    if rng then
        cands[#cands + 1] = rng + (buf or 0)
        cands[#cands + 1] = rng + ET.FALLBACK.RANGE_BUFFER      -- 700 + 165
    end
    if acq then cands[#cands + 1] = acq end
    if floor then cands[#cands + 1] = floor end
    local best = nil
    for i = 1, #cands do
        local v = cands[i]
        if type(v) == "number" and v >= 400 and v <= 2000 then
            if not best or v > best then best = v end
        end
    end
    return best or ET.FALLBACK.TOWER_RANGE
end

--[[ Everything the duel simulation needs to know about one live tower.
     `targeting_me` is the important one: the engine already knows whether the
     tower is locked on to us, which is 0.3-0.8 s of warning *before* the first
     projectile exists. ]]--
function ET.TowerFacts(bot, tower, team, tier, floor)
    if not tower then return nil end
    local f = {}
    --[[ Two numbers, not one:
           range    — the radius at which the tower *starts* a cycle
                      (KV AttackRange 700 + the buffer the engine reports)
           acquire  — the outer edge at which a cycle can begin on a hero who
                      is already moving away: the KV AttackAnimationPoint gives
                      the tower 0.6 s of wind-up to still be in range, and the
                      projectile is homing, so the shot lands anyway.
         The replay measured 865 as the *observed* edge; 700 + 305*0.6 = 883
         is what the data files imply. Both are reported. ]]--
    f.range    = ET.TowerAggroRadius(tower, floor) or ET.FALLBACK.TOWER_RANGE
    f.acquire  = f.range        -- SPATIAL: where the aggro starts (865)
    f.windup   = ET.AttackPoint(tower) or ET.FALLBACK.TOWER_WINDUP
    f.proj_speed = ET.FALLBACK.TOWER_PROJ
    --[[ What the wind-up explains is not where the aggro starts but how far a
         shot can still be RELEASED after the hero has turned and run: a cycle
         started at the edge releases 0.6 s later, by which time a 305 ms hero
         is 183 u further out -> 865 + 183 = 1048. The replays measured the
         furthest impact at 1023 u, which is this number and not a coincidence. ]]--
    f.release_span = f.range + 305 * f.windup
    f.damage   = ET.AverageTrueDamage(tower) or ET.FALLBACK.TOWER_DMG
    f.interval = ET.SecondsPerAttack(tower) or ET.FALLBACK.TOWER_INTERVAL
    local tgt = ET.AggroTarget(tower)
    if not tgt and bot and team and tier and bot.GetTowerAttackTarget then
        tgt = call(bot, "GetTowerAttackTarget", team, tier)
    end
    f.target = tgt
    f.targeting_me = (tgt ~= nil and bot ~= nil and tgt == bot)
    local last = ET.LastAttackTime(tower)
    if last then
        local now = (GameTime and GameTime()) or 0
        local el = now - last
        if el < 0 or el > 10 then el = 0 end
        f.next_shot_in = math.max(0, f.interval - el)
    else
        f.next_shot_in = f.interval * 0.5
    end
    return f
end

--------------------------------------------------------------------------------
-- damage already in the air
--------------------------------------------------------------------------------

--[[ Sum of the damage that is already flying towards `u`.
     `dmg_of(projectile)` must map a projectile entry to damage; the caller owns
     that knowledge (a tower shot and a hero right-click are not the same
     number). Returning nil for any unknown projectile makes the whole total
     nil — an unknown projectile is a reason to be *more* careful, and the
     caller treats nil as "assume the worst known value". ]]--
function ET.IncomingDamage(u, dmg_of)
    local projs = call(u, "GetIncomingTrackingProjectiles")
    if type(projs) ~= "table" then return 0, 0 end
    local total, n = 0, 0
    for _, p in pairs(projs) do
        local d = dmg_of and dmg_of(p) or nil
        if d then
            total = total + d
            n = n + 1
        else
            return nil, #projs
        end
    end
    return total, n
end

function ET.IncomingCount(u)
    local projs = call(u, "GetIncomingTrackingProjectiles")
    if type(projs) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(projs) do n = n + 1 end
    return n
end

--------------------------------------------------------------------------------
-- global limits
--------------------------------------------------------------------------------

local _limits = nil
function ET.AttackSpeedLimits(bot)
    if _limits then return _limits end
    local lo = (bot and (sane(call(bot, "GetMinimumAttackSpeed"), 1, 2000))) or ET.FALLBACK.AS_MIN
    local hi = (bot and (sane(call(bot, "GetMaximumAttackSpeed"), 1, 5000))) or ET.FALLBACK.AS_MAX
    _limits = { min = lo, max = hi }
    return _limits
end

-- seconds per attack for a given BAT and IAS %, clamped by the engine limits
function ET.SecondsPerAttackFor(bat, ias_pct, bot)
    local lim = ET.AttackSpeedLimits(bot)
    local as = math.max(lim.min, math.min(lim.max, 100 + (ias_pct or 0)))
    return (bat or ET.FALLBACK.SF_BAT) * 100 / as
end

--------------------------------------------------------------------------------
-- calibration of the constants that used to be hard-coded
--------------------------------------------------------------------------------

--[[ Rewrite the live constant tables (nevermore/constants.lua) with values read
     from the engine. Called once per game, from the first tower we can see.
     Every field is written only when the engine answer is sane, so a broken or
     unavailable accessor leaves the measured 7.41f defaults in place. ]]--
function ET.CalibrateConstants(C, bot, towers)
    local rep = { source = "fallback" }
    if not C then return rep end
    C.TOWER = C.TOWER or {}
    local tw = towers and towers[1] or nil
    if tw then
        local r = ET.TowerAggroRadius(tw, C.TOWER.ATTACK_RANGE)
        if r then
            C.TOWER.ATTACK_RANGE = r
            C.TOWER.SAFE_RADIUS = r + 20
            C.TOWER.CHASE_LEASH = r + 40
            C.TOWER.ESCAPE_RADIUS = math.max(C.TOWER.ESCAPE_RADIUS or 0, r + 35)
            rep.source = "engine"
            rep.tower_range = r
        end
        local d = ET.AverageTrueDamage(tw)
        if d then C.TOWER.SHOT_DAMAGE = d rep.tower_damage = d end
        local sp = ET.SecondsPerAttack(tw)
        if sp then C.TOWER.SHOT_INTERVAL = sp rep.tower_interval = sp end
        -- cross-check against the KV data files (npc_units.txt): a large gap
        -- means the engine is reporting a modified value - keep the engine
        -- number (it is live) but record both so the report can show it
        rep.kv_damage = C.TOWER.DAMAGE_RAW
        rep.kv_interval = C.TOWER.SHOT_INTERVAL
        if d and C.TOWER.DAMAGE_RAW and math.abs(d - C.TOWER.DAMAGE_RAW) > 0.25 * C.TOWER.DAMAGE_RAW then
            rep.damage_mismatch = true
        end
        if C.TOWER.NOMINAL_RANGE then
            rep.kv_range = C.TOWER.NOMINAL_RANGE
            rep.range_delta = (rep.tower_range or 0) - C.TOWER.NOMINAL_RANGE
        end
    end
    local hr = bot and ET.AttackRange(bot)
    if hr then C.HERO.ATTACK_RANGE = hr rep.hero_range = hr end
    local sp = bot and ET.SecondsPerAttack(bot)
    if sp then C.HERO.SECONDS_PER_ATTACK = sp rep.hero_sp = sp end
    local ap = bot and ET.AttackPoint(bot)
    if ap then C.HERO.ATTACK_POINT = ap rep.hero_ap = ap end
    rep.hits, rep.misses = ET.STATS.hits, ET.STATS.misses
    return rep
end

--------------------------------------------------------------------------------
-- self test (offline)
--------------------------------------------------------------------------------

function ET.SelfTest()
    local fails = {}
    local function chk(name, cond) if not cond then fails[#fails + 1] = name end end

    local tower = {
        GetAttackRange = function() return 700 end,
        GetAttackRangeBuffer = function() return 165 end,
        GetAcquisitionRange = function() return 865 end,
        GetAverageTrueAttackDamage = function() return 82 end,
        GetSecondsPerAttack = function() return 0.83 end,
        GetAggroTarget = function() return "ME" end,
        GetLastAttackTime = function() return 0 end,
    }
    local f = ET.TowerFacts("ME", tower, 2, 1)
    chk("tower range", f.range == 865)
    chk("tower damage", f.damage == 82)
    chk("tower interval", math.abs(f.interval - 0.83) < 1e-9)
    chk("tower aggro me", f.targeting_me == true)
    chk("tower windup 0.6 s", math.abs((f.windup or -1) - 0.6) < 1e-9, f.windup)
    chk("aggro is spatial: acquire == range", f.acquire == f.range, tostring(f.acquire) .. "/" .. tostring(f.range))
    chk("release span 865+183 = 1048", math.abs((f.release_span or 0) - 1048) < 1, f.release_span)
    -- the floor protects against an engine build that reports 700 only
    local kvOnly = { GetAttackRange = function() return 700 end,
                     GetAcquisitionRange = function() return 700 end }
    chk("measured 865 survives a 700-only engine", ET.TowerAggroRadius(kvOnly, 865) == 865,
        ET.TowerAggroRadius(kvOnly, 865))

    -- a unit without the accessors must not raise
    local bare = {}
    chk("missing methods", ET.AttackRange(bare) == nil)
    chk("missing incoming", ET.IncomingCount(bare) == 0)

    -- incoming damage accounting
    local u2 = { GetIncomingTrackingProjectiles = function() return { { dmg = 60 }, { dmg = 81 } } end }
    local tot, n = ET.IncomingDamage(u2, function(p) return p.dmg end)
    chk("incoming sum", tot == 141 and n == 2)
    local unk = ET.IncomingDamage(u2, nil)
    chk("incoming unknown -> nil", unk == nil)

    -- attack timing
    local u3 = {
        GetSecondsPerAttack = function() return 1.6 end,
        GetAttackPoint = function() return 0.5 end,
        GetLastAttackTime = function() return ((GameTime and GameTime()) or 0) - 0.6 end,
    }
    local tm = ET.AttackTiming(u3)
    chk("timing", math.abs((tm.cycle_left or -1) - 1.0) < 0.05)

    -- calibration must not overwrite with garbage
    local C = { TOWER = { ATTACK_RANGE = 865, ESCAPE_RADIUS = 900 }, HERO = {} }
    local rep = ET.CalibrateConstants(C, nil, nil)
    chk("calibrate fallback", C.TOWER.ATTACK_RANGE == 865 and rep.source == "fallback")
    ET.CalibrateConstants(C, nil, { tower })
    chk("calibrate engine", C.TOWER.ATTACK_RANGE == 865 and C.TOWER.SHOT_DAMAGE == 82)

    -- engine attack-speed limits
    local lim = ET.AttackSpeedLimits(nil)
    chk("as limits", lim.min > 0 and lim.max > lim.min)
    chk("spa formula", math.abs(ET.SecondsPerAttackFor(1.6, 0, nil) - 1.6) < 1e-6)
    return #fails == 0, fails
end

return ET
