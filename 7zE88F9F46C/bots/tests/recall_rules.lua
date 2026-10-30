-- v5.1 recall rules on the mock API (G4 3:05 / 6:03 walks home):
--  A. enemy dead, bot 54/940 HP, 10 mana, gold 300  -> must NOT walk to the fountain (farm, salve via courier)
--  B. enemy dead, bot 54/940 HP, 10 mana, gold 0, no items -> walks home (nothing to heal with)
--  C. limbo (low HP, low mana, enemy alive) with gold 600 -> the Director reset waits for the salve <= 20 s, then fires
local ROOT = "/tmp/sfroot"
os.execute("mkdir -p " .. ROOT .. " && ln -sfn /home/user/4.30 " .. ROOT .. "/bots")
package.path = ROOT .. "/?.lua;" .. package.path
_G.__SF_TEST = true
dofile("/home/user/4.30/tests/mock_dota.lua")
dofile("/home/user/4.30/bot_nevermore.lua")
local D = package.loaded["bots/nevermore/duel"]
-- the real API reports a dead (invisible) enemy via IsHeroAlive(pid); the generic mock does not have it
function GetTeamPlayers(team) return { team == TEAM_RADIANT and 0 or 1 } end
function IsHeroAlive(pid) if pid == 0 and MOCK.enemy then return MOCK.enemy:IsAlive() end return true end
local S = _G.__SF_STATE
local RAD_T1, DIRE_T1 = Vector(-1544, -1408, 0), Vector(524, 652, 0)
local t1 = MOCK.NewUnit({ name = "t", team = TEAM_RADIANT, loc = RAD_T1, hp = 1800, tower = true }); t1._towerIdx = TOWER_MID_1
local t2 = MOCK.NewUnit({ name = "t2", team = TEAM_DIRE, loc = DIRE_T1, hp = 1800, tower = true }); t2._towerIdx = TOWER_MID_1
local fails = 0
local function scenario(name, o)
    MOCK.t = (MOCK.t or 0) + 400
    D.Reset()
    for _, k in ipairs({ "goingToFountain", "fountainReason", "resetWantedSince", "emergencyRetreat" }) do S[k] = nil end
    S.emergencyRetreatStartTime = 0
    local bot = MOCK.NewSF(TEAM_DIRE, Vector(150, 250, 0), { hp = o.hp, mhp = o.mhp, mp = o.mp, mmp = 330, lvl = 5, raze = 3, souls = 6 })
    bot._isBot = true; bot._pid = 1; bot._gold = o.gold
    local en = MOCK.NewSF(TEAM_RADIANT, Vector(-420, -330, 0), { hp = 820, mhp = 860, mp = 300, mmp = 330, lvl = 6, raze = 3, souls = 10 })
    if o.enemyDead then en._alive = false; en._hp = 0 end
    MOCK.bot, MOCK.enemy = bot, en
    local t0, firstGo, reason = MOCK.t, nil, nil
    for _ = 1, math.floor(o.secs / 0.033) do
        if not o.enemyDead then
            en._order = { kind = "move", a = bot:GetLocation() + (en:GetLocation() - bot:GetLocation()):Normalized() * 800 }
        end
        Think()
        local home = S.goingToFountain or S.emergencyRetreat == "FOUNTAIN"
        if home and not firstGo then firstGo = MOCK.t - t0; reason = S.fountainReason or ("emergency:" .. tostring(S.emergencyRetreat)) end
        MOCK.Step(0.033)
    end
    local ok = o.expect(firstGo, reason)
    if not ok then fails = fails + 1 end
    print(string.format("%s  %s: goingToFountain at %s (%s)", ok and "ok  " or "FAIL", name,
        firstGo and string.format("t+%.1f", firstGo) or "never", tostring(reason)))
end
scenario("A enemy dead, 54/940 HP, 10 mp, 300 g -> stay in lane", { hp = 54, mhp = 940, mp = 10, gold = 300, enemyDead = true, secs = 8,
    expect = function(t) return t == nil end })
scenario("B enemy dead, 54/940 HP, 10 mp, 0 g -> go home", { hp = 54, mhp = 940, mp = 10, gold = 0, enemyDead = true, secs = 8,
    expect = function(t) return t ~= nil end })
scenario("C limbo with 600 g -> DIRECTOR reset delayed for the salve, fires by ~t+27", { hp = 170, mhp = 760, mp = 60, gold = 600, secs = 32,
    expect = function(t, r) return t == nil or (t >= 20 and t <= 30) end })
print(string.format("recall rules: %d failures, runtime errors %d", fails, _G.__SF_RUNTIME_ERRORS or 0))
os.exit((fails == 0 and (_G.__SF_RUNTIME_ERRORS or 0) == 0) and 0 or 1)
