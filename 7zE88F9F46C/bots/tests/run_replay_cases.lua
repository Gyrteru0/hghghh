-- Runs the Combat Director core on states extracted from the three replays.
-- usage (from repo root):  lua5.1 tests/run_replay_cases.lua [verbose]
package.path = "./?.lua;./nevermore/?.lua;" .. package.path
local D = dofile("nevermore/duel.lua")
local cases = dofile("tests/replay_cases.lua")
local verbose = arg and arg[1] == "verbose"

local function has(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end

local pass, total = 0, 0
local t0 = os.clock()
for _, c in ipairs(cases) do
    local res = D.Evaluate(c.state)
    total = total + 1
    local ok = has(c.ok, res.verdict)
    if ok then pass = pass + 1 end
    local me, en = c.state.me, c.state.en
    local d = math.sqrt((me.x - en.x) ^ 2 + (me.y - en.y) ^ 2)
    print(string.format("%s %-52s B %4d/%4d mp%3d | H %4d/%4d mp%3d | d=%4d -> %-7s (%s)%s",
        ok and "OK  " or "FAIL", c.label, me.hp, me.mhp, me.mp, en.hp, en.mhp, en.mp, d, res.verdict, res.best,
        (c.state.deep and " deep" or "") .. (res.lost and " LOST" or "")))
    if verbose or not ok then
        local line = "      scores:"
        for _, p in ipairs(D.MY_POLICIES) do
            line = line .. string.format(" %s=%.0f(w%.0f/%s%s)", p, res.scores[p], res.worst[p], res.worstQ[p],
                res.kill[p] and ",K" or (res.death[p] and ",D" or ""))
        end
        print(line)
        local r = D.Simulate(c.state, res.best, res.worstQ[res.best], D.P.HORIZON, { trace = true, deep = c.state.deep })
        local ev = "      trace vs " .. res.worstQ[res.best] .. ":"
        for _, e in ipairs(r.events) do ev = ev .. string.format(" %.1f%s:%s%s", e.t, e.who == "A" and "B" or "H", e.what, e.dmg > 0 and ("=" .. math.floor(e.dmg)) or "") end
        print(ev)
        print(string.format("      end: bot %d%s  human %d%s  t=%.1f", r.aHp, r.aDead and " DEAD" or "", r.bHp, r.bDead and " DEAD" or "", r.t))
    end
end
print(string.format("\n%d/%d cases match the expected verdict set; %.1f ms per evaluation", pass, total,
    (os.clock() - t0) * 1000 / total))
