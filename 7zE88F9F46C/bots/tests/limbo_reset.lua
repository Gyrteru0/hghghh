-- Targeted test of the Director reset (G3 4:20-5:11 limbo): bot at low HP, healthy enemy with razes nearby,
-- no regen items. Expect: Director reset fires within ~6-8 s and the bot walks toward its fountain without aborting.
local ROOT = "/tmp/sfroot"
os.execute("mkdir -p " .. ROOT .. " && ln -sfn /home/user/4.30 " .. ROOT .. "/bots")
package.path = ROOT .. "/?.lua;" .. package.path
dofile("/home/user/4.30/tests/mock_dota.lua")
dofile("/home/user/4.30/bot_nevermore.lua")
local D = package.loaded["bots/nevermore/duel"]
local RAD_T1, DIRE_T1 = Vector(-1544, -1408, 0), Vector(524, 652, 0)
local t1 = MOCK.NewUnit({ name = "t", team = TEAM_RADIANT, loc = RAD_T1, hp = 1800, tower = true }); t1._towerIdx = TOWER_MID_1
local t2 = MOCK.NewUnit({ name = "t2", team = TEAM_DIRE, loc = DIRE_T1, hp = 1800, tower = true }); t2._towerIdx = TOWER_MID_1
MOCK.t = 350
local bot = MOCK.NewSF(TEAM_DIRE, Vector(150, 250, 0), { hp = 170, mhp = 760, mp = 120, mmp = 330, lvl = 5, raze = 3, souls = 6 })
bot._isBot = true; bot._pid = 1
local en = MOCK.NewSF(TEAM_RADIANT, Vector(-420, -330, 0), { hp = 820, mhp = 860, mp = 300, mmp = 330, lvl = 6, raze = 3, souls = 10, items = { { "item_faerie_fire", 1 } } })
MOCK.bot, MOCK.enemy = bot, en
local fountain = Vector(7000, 6400, 0)
local firedAt, d0 = nil, (bot._loc - fountain):Length2D()
local origThink = D.Think
D.Think = function(...)
    local r = origThink(...)
    if D.mem.wantReset and not firedAt then firedAt = MOCK.t end
    return r
end
local lastPrint = 0
for k = 1, 900 do                                     -- 30 s
    en._order = { kind = "move", a = bot:GetLocation() + (en:GetLocation() - bot:GetLocation()):Normalized() * 800 }
    Think()
    if MOCK.t - lastPrint >= 2 then
        lastPrint = MOCK.t
        local dd = _G.__directorDecision
        print(string.format("t+%4.1f d=%4.0f toFountain=%4.0f verdict=%s badSince=%s", MOCK.t - 350, GetUnitToUnitDistance(bot, en),
            (bot._loc - fountain):Length2D(), dd and dd.verdict or "-", tostring(D.mem.badSince and (D.mem.badSince - 350))))
    end
    MOCK.Step(0.033)
end
local d1 = (bot._loc - fountain):Length2D()
print(string.format("reset order toward fountain at t+%.1f s; distance to fountain %.0f -> %.0f; runtime errors %d",
    firedAt and (firedAt - 350) or -1, d0, d1, _G.__SF_RUNTIME_ERRORS or 0))
os.exit((firedAt and d1 < d0 - 3000 and (_G.__SF_RUNTIME_ERRORS or 0) == 0) and 0 or 1)
