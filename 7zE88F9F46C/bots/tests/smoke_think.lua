-- Smoke test: load the whole bot (all modules) against tests/mock_dota.lua and run Think() through many synthetic
-- lane situations. Fails if any Lua runtime error escapes into Think()'s pcall (in game that tick = idle hero).
-- usage: lua5.1 tests/smoke_think.lua [scenarios] [ticks]
local ROOT = "/tmp/sfroot"
os.execute("mkdir -p " .. ROOT .. " && ln -sfn /home/user/4.30 " .. ROOT .. "/bots")
package.path = ROOT .. "/?.lua;" .. package.path
dofile("/home/user/4.30/tests/mock_dota.lua")
math.randomseed(12345)

local NS = tonumber(arg[1]) or 60
local NT = tonumber(arg[2]) or 240

local RAD_T1, DIRE_T1 = Vector(-1544, -1408, 0), Vector(524, 652, 0)
local errors, verdicts, orders, ticks = {}, {}, {}, 0
resets = {}
local loadedOk, loadErr

local function reset()
    MOCK.units = {}; MOCK.orders = {}
    -- time must stay monotonic across scenarios (Think() throttles on GameTime deltas)
    MOCK.t = math.max(MOCK.t + 30, 90 + math.random() * 400)
    local t1 = MOCK.NewUnit({ name = "npc_dota_goodguys_tower1_mid", team = TEAM_RADIANT, loc = RAD_T1, hp = 1800, tower = true, range = 700, dmg = 70 }); t1._towerIdx = TOWER_MID_1
    local t2 = MOCK.NewUnit({ name = "npc_dota_badguys_tower1_mid", team = TEAM_DIRE, loc = DIRE_T1, hp = 1800, tower = true, range = 700, dmg = 70 }); t2._towerIdx = TOWER_MID_1
end

local function scenario(i)
    reset()
    -- lane point between the towers
    local a = math.random()
    local mid = RAD_T1 + (DIRE_T1 - RAD_T1) * (0.15 + 0.7 * a)
    local lvl = math.random(1, 7)
    local razeLvl = math.min(4, math.max(1, math.floor((lvl + 1) / 2)))
    local items = {}
    if math.random() < 0.7 then items[#items + 1] = { "item_faerie_fire", 1 } end
    if math.random() < 0.5 then items[#items + 1] = { "item_magic_stick", math.random(0, 6) } end
    if math.random() < 0.4 then items[#items + 1] = { "item_enchanted_mango", 1 } end
    if math.random() < 0.6 then items[#items + 1] = { "item_bracer", 0 } end
    local mhp = 560 + lvl * 50
    local bot = MOCK.NewSF(TEAM_DIRE, mid + Vector(150 + math.random(0, 500), 150 + math.random(0, 500), 0),
        { hp = math.random(60, mhp), mhp = mhp, mp = math.random(0, 360), mmp = 360, lvl = lvl, raze = razeLvl, items = items, souls = math.random(0, 14), facing = 225 })
    bot._isBot = true; bot._pid = 1
    local en = MOCK.NewSF(TEAM_RADIANT, mid - Vector(150 + math.random(0, 500), 150 + math.random(0, 500), 0),
        { hp = math.random(60, mhp), mhp = mhp, mp = math.random(0, 360), mmp = 360, lvl = lvl, raze = razeLvl, items = { { "item_faerie_fire", 1 } }, souls = math.random(0, 14), facing = 45 })
    en._pid = 0
    MOCK.bot, MOCK.enemy = bot, en
    -- creep waves
    local nAlly, nEnemy = math.random(0, 4), math.random(0, 4)
    for k = 1, nAlly do
        MOCK.NewUnit({ name = (k == 4) and "npc_dota_creep_badguys_ranged" or "npc_dota_creep_badguys_melee", team = TEAM_DIRE, creep = true, loc = mid + Vector(math.random(-150, 150), math.random(-150, 150), 0), hp = math.random(40, 550), mhp = 550, dmg = 21, range = 100 })
    end
    for k = 1, nEnemy do
        MOCK.NewUnit({ name = (k == 4) and "npc_dota_creep_goodguys_ranged" or "npc_dota_creep_goodguys_melee", team = TEAM_RADIANT, creep = true, loc = mid + Vector(math.random(-150, 150), math.random(-150, 150), 0), hp = math.random(40, 550), mhp = 550, dmg = 21, range = 100 })
    end
    return bot, en
end

local okLoad, e = pcall(dofile, "/home/user/4.30/bot_nevermore.lua")
if not okLoad then print("LOAD FAILED: " .. tostring(e)); os.exit(1) end

for i = 1, NS do
    local bot, en = scenario(i)
    local Dm0 = package.loaded["bots/nevermore/duel"]; if Dm0 and Dm0.Reset then Dm0.Reset() end
    _G.__SF_RUNTIME_ERRORS = 0
    for k = 1, NT do
        -- the enemy wanders toward / away from the bot, sometimes stands
        local r = math.random()
        if r < 0.45 then en._order = { kind = "move", a = bot:GetLocation() }
        elseif r < 0.7 then en._order = { kind = "move", a = RAD_T1 }
        end
        _G.__SF_LAST_RUNTIME_ERROR = nil
        local Dm = package.loaded["bots/nevermore/duel"]
        local wanted = Dm and Dm.mem and Dm.mem.wantReset
        Think()
        if wanted and Dm.mem.wantReset == nil then
            resets[#resets + 1] = string.format("s%d t%.1f hp %d/%d en %d d %.0f", i, MOCK.t, bot._hp, bot._mhp, en._hp, GetUnitToUnitDistance(bot, en))
        end
        ticks = ticks + 1
        if _G.__SF_LAST_RUNTIME_ERROR then
            local msg = _G.__SF_LAST_RUNTIME_ERROR
            errors[msg] = (errors[msg] or 0) + 1
        end
        local dd = _G.__directorDecision
        if dd and dd.t == MOCK.t then verdicts[dd.verdict or "?"] = (verdicts[dd.verdict or "?"] or 0) + 1 end
        local o = bot._order
        if o and o.t == MOCK.t then orders[o.kind] = (orders[o.kind] or 0) + 1 end
        MOCK.Step(0.033)
        -- crude damage so situations evolve: creeps and tower chip the bot when close
        if GetUnitToLocationDistance(bot, RAD_T1) < 865 and math.random() < 0.03 then bot._hp = bot._hp - 70 end
        if bot._hp <= 0 then break end
    end
end

print("director resets: " .. #resets); for k = 1, math.min(#resets, 12) do print("  " .. resets[k]) end
local nErr = 0
for msg, n in pairs(errors) do nErr = nErr + n; print(string.format("ERROR x%d: %s", n, msg)) end
local function dump(name, t)
    local ks = {}; for k, v in pairs(t) do ks[#ks + 1] = string.format("%s=%d", k, v) end
    table.sort(ks); print(name .. ": " .. table.concat(ks, " "))
end
dump("director verdicts", verdicts)
dump("bot orders", orders)
local miss = {}
for k, v in pairs(MOCK.missing) do miss[#miss + 1] = k end
table.sort(miss)
print("unmocked API touched (" .. #miss .. "): " .. table.concat(miss, ", "))
print(string.format("%d ticks, %d runtime errors", ticks, nErr))
os.exit(nErr == 0 and 0 or 1)
