-- v5.1 creep-tank drop: 3 enemy creeps hitting the bot, no allied creeps, enemy hero far away (G4 5:30-5:45).
-- Expect the bot to step back toward its T1 within 1 s; and NOT to step back when a creep is killable right now.
local ROOT = "/tmp/sfroot"
os.execute("mkdir -p " .. ROOT .. " && ln -sfn /home/user/4.30 " .. ROOT .. "/bots")
package.path = ROOT .. "/?.lua;" .. package.path
dofile("/home/user/4.30/tests/mock_dota.lua")
dofile("/home/user/4.30/bot_nevermore.lua")
local RAD_T1, DIRE_T1 = Vector(-1544, -1408, 0), Vector(524, 652, 0)
local fails = 0
local function run(name, creepHp, expectRetreat)
    MOCK.units = {}; MOCK.orders = {}; MOCK.t = (MOCK.t or 100) + 100
    local t1 = MOCK.NewUnit({ name = "npc_dota_goodguys_tower1_mid", team = TEAM_RADIANT, loc = RAD_T1, hp = 1800, tower = true, range = 700, dmg = 70 }); t1._towerIdx = TOWER_MID_1
    local t2 = MOCK.NewUnit({ name = "npc_dota_badguys_tower1_mid", team = TEAM_DIRE, loc = DIRE_T1, hp = 1800, tower = true, range = 700, dmg = 70 }); t2._towerIdx = TOWER_MID_1
    local p0 = Vector(-300, -250, 0)
    local bot = MOCK.NewSF(TEAM_DIRE, p0, { hp = 500, mhp = 900, mp = 250, mmp = 360, lvl = 5, raze = 3, souls = 6, facing = 225 })
    bot._isBot = true; bot._pid = 1
    local en = MOCK.NewSF(TEAM_RADIANT, Vector(-2400, -2200, 0), { hp = 900, mhp = 900, mp = 300, mmp = 360, lvl = 5, raze = 3, souls = 6 })
    en._pid = 0
    MOCK.bot, MOCK.enemy = bot, en
    for k = 1, 3 do
        local c = MOCK.NewUnit({ name = "npc_dota_creep_goodguys_melee", team = TEAM_RADIANT, creep = true, loc = p0 + Vector(-90 + 60 * k, -110, 0), hp = creepHp, mhp = 550, dmg = 21, range = 100 })
        c._atkTarget = bot
    end
    local D = package.loaded["bots/nevermore/duel"]; if D and D.Reset then D.Reset() end
    local d0 = (bot:GetLocation() - DIRE_T1):Length2D()
    for _ = 1, 30 do Think(); MOCK.Step(0.033) end
    local d1 = (bot:GetLocation() - DIRE_T1):Length2D()
    local retreated = d1 < d0 - 120
    local ok = retreated == expectRetreat
    if not ok then fails = fails + 1 end
    print(string.format("%s  %s: distance to own T1 %.0f -> %.0f", ok and "ok  " or "FAIL", name, d0, d1))
end
run("3 creeps tanking, nothing to last-hit -> step back to T1", 450, true)
run("3 creeps tanking but one is killable now -> keep hitting", 30, false)
print(string.format("creep tank: %d failures, runtime errors %d", fails, _G.__SF_RUNTIME_ERRORS or 0))
os.exit((fails == 0 and (_G.__SF_RUNTIME_ERRORS or 0) == 0) and 0 or 1)
