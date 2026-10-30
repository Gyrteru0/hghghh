-- Evaluate every scanned replay frame from both perspectives. usage: lua5.1 tests/scan_eval.lua <scan.lua> > out.tsv
package.path = "./?.lua;./nevermore/?.lua;" .. package.path
local D = dofile("nevermore/duel.lua")
local frames = dofile(arg[1])
local t0 = os.clock()
print("t\td\tbotVerdict\tbotBest\tbotLost\tbotFarmWorst\tbotFarmDeath\thumVerdict\thumBest\thumLost\thumFarmDeath\tbotScores")
for _, f in ipairs(frames) do
    local rb = D.Evaluate(f.state)
    local rh = D.Evaluate(f.mirror)
    local sc = {}
    for _, p in ipairs(D.MY_POLICIES) do
        sc[#sc + 1] = string.format("%s:%.0f:%.0f:%s:%s", p, rb.scores[p], rb.worst[p], rb.death[p] and 1 or 0, rb.kill[p] and 1 or 0)
    end
    print(string.format("%.2f\t%d\t%s\t%s\t%s\t%.0f\t%s\t%s\t%s\t%s\t%s\t%s", f.t, f.d, rb.verdict, rb.best, tostring(rb.lost),
        rb.worst.FARM, tostring(rb.death.FARM), rh.verdict, rh.best, tostring(rh.lost), tostring(rh.death.FARM), table.concat(sc, ",")))
end
io.stderr:write(string.format("%d frames, %.1f ms/eval\n", #frames, (os.clock() - t0) * 1000 / (2 * #frames)))
