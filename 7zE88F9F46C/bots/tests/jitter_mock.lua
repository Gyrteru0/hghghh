-- Jitter benchmark on the whole bot (mock API): the enemy SF dances on the edge of his far raze (800-1050 u),
-- creeps of both sides fight near him, the bot is healthy / mid / low. Counts the bot's direction reversals
-- (>120 deg turn between successive 0.133 s displacements, both > 12 u) per minute.
-- usage: lua5.1 tests/jitter_mock.lua [botRoot]   (botRoot defaults to /home/user/4.30; pass an unpacked v5.0 to compare)
local BOT = arg[1] or "/home/user/4.30"
local ROOT = "/tmp/sfroot_jit"
os.execute("rm -rf " .. ROOT .. " && mkdir -p " .. ROOT .. " && ln -sfn " .. BOT .. " " .. ROOT .. "/bots")
package.path = ROOT .. "/?.lua;" .. package.path
dofile("/home/user/4.30/tests/mock_dota.lua")
math.randomseed(777)
local function loadBot()
    local okLoad, e = pcall(dofile, BOT .. "/bot_nevermore.lua") -- fresh State per scenario
    if not okLoad then print("LOAD FAILED " .. tostring(e)); os.exit(1) end
end
local RAD_T1, DIRE_T1 = Vector(-1544, -1408, 0), Vector(524, 652, 0)
local totalRev, totalSec, totalHits, engagedSec = 0, 0, 0, 0
for sc = 1, 24 do
    MOCK.units = {}; MOCK.orders = {}
    MOCK.t = (MOCK.t or 100) + 60
    local t1 = MOCK.NewUnit({ name = "npc_dota_goodguys_tower1_mid", team = TEAM_RADIANT, loc = RAD_T1, hp = 1800, tower = true, range = 700, dmg = 70 }); t1._towerIdx = TOWER_MID_1
    local t2 = MOCK.NewUnit({ name = "npc_dota_badguys_tower1_mid", team = TEAM_DIRE, loc = DIRE_T1, hp = 1800, tower = true, range = 700, dmg = 70 }); t2._towerIdx = TOWER_MID_1
    local mid = RAD_T1 + (DIRE_T1 - RAD_T1) * (0.35 + 0.3 * math.random())
    local lvl = 4 + (sc % 4)
    local mhp = 560 + lvl * 50
    local hpFrac = ({ 0.9, 0.6, 0.35 })[(sc % 3) + 1]
    local bot = MOCK.NewSF(TEAM_DIRE, mid + Vector(420, 420, 0), { hp = math.floor(mhp * hpFrac), mhp = mhp, mp = 250, mmp = 360, lvl = lvl, raze = 3, souls = 8, facing = 225 })
    bot._isBot = true; bot._pid = 1; bot._gold = tonumber(os.getenv("JIT_GOLD") or "600")
    local en = MOCK.NewSF(TEAM_RADIANT, mid - Vector(220, 220, 0), { hp = mhp, mhp = mhp, mp = 300, mmp = 360, lvl = lvl, raze = 3, souls = 8, facing = 45 })
    en._pid = 0
    MOCK.bot, MOCK.enemy = bot, en
    for k = 1, 4 do
        MOCK.NewUnit({ name = (k == 4) and "npc_dota_creep_goodguys_ranged" or "npc_dota_creep_goodguys_melee", team = TEAM_RADIANT, creep = true,
            loc = mid + Vector(math.random(-120, 120), math.random(-120, 120), 0), hp = math.random(60, 400), mhp = 550, dmg = 21, range = 100 })
        MOCK.NewUnit({ name = (k == 4) and "npc_dota_creep_badguys_ranged" or "npc_dota_creep_badguys_melee", team = TEAM_DIRE, creep = true,
            loc = mid + Vector(math.random(-120, 120) + 90, math.random(-120, 120) + 90, 0), hp = math.random(60, 400), mhp = 550, dmg = 21, range = 100 })
    end
    loadBot()
    local D = package.loaded["bots/nevermore/duel"]; if D and D.Reset then D.Reset() end
    local last, lastV, rev, phase = nil, nil, 0, 0
    local N = 600 -- 20 s at 30 Hz
    for k = 1, N do
        -- dance: walk to 820 from the bot, then back to 1050, 0.8 s period
        if k % 24 == 0 then phase = 1 - phase end
        local want = phase == 0 and 820 or 1050
        local dir = (en:GetLocation() - bot:GetLocation()):Normalized()
        en._order = { kind = "move", a = bot:GetLocation() + dir * want }
        Think()
        MOCK.Step(0.033)
        local engaged = GetUnitToUnitDistance(bot, en) < 1300 and (bot:GetLocation() - mid):Length2D() < 1500
        if engaged then engagedSec = engagedSec + 0.033 end
        if k % 4 == 0 then
            local p = bot:GetLocation()
            if last then
                local v = p - last
                if v:Length2D() > 12 then
                    if lastV then
                        local c = (v.x * lastV.x + v.y * lastV.y) / (v:Length2D() * lastV:Length2D())
                        if c < -0.5 and engaged then rev = rev + 1 end
                    end
                    lastV = v
                end
            end
            last = p
        end
    end
    BY = BY or {}
    local key = string.format("hp%.0f%%", hpFrac * 100)
    BY[key] = BY[key] or { 0, 0 }
    BY[key][1] = BY[key][1] + rev; BY[key][2] = BY[key][2] + N * 0.033
    totalRev = totalRev + rev
    totalSec = totalSec + N * 0.033
end
print(string.format("%s: %.1f direction reversals per engaged minute; engaged %.0f of %.0f s (runtime errors %d)", BOT,
    totalRev / math.max(1, engagedSec) * 60, engagedSec, totalSec, _G.__SF_RUNTIME_ERRORS or 0))
for k, v in pairs(BY) do print(string.format("   %s: %.1f reversals/min", k, v[1] / v[2] * 60)) end
