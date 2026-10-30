-- v5.1 unit checks: anti-bait raze gate, spacing hysteresis / projection (anti-jitter), approach margin.
-- usage: lua5.1 tests/v51_units.lua
package.path = "./?.lua;./nevermore/?.lua;" .. package.path
_G.GameTime = function() return _G.__T or 0 end
local D = dofile("nevermore/duel.lua")
local fails, total = 0, 0
local function check(name, cond)
    total = total + 1
    if not cond then fails = fails + 1; print("FAIL  " .. name) else print("ok    " .. name) end
end

local function hero(x, y, o)
    local h = { x = x, y = y, hp = 600, mhp = 1100, mp = 300, dmg = 70, rng = 540, spd = 305, vx = 0, vy = 0,
        rzLvl = 3, rzCd = { 0, 0, 0 }, rzBase = 215, rzStack = 65, souls = 10, perSoul = 2, magMult = 0.75 }
    for k, v in pairs(o or {}) do h[k] = v end
    return h
end

-- 1. anti-bait gate on the real G4 frames (bot e started, human reversed, cast S-cancelled)
local me = hero(-504, -323)
-- 6:54.33: d=879, human approaching at ~349 u/s
local ang = math.atan2(-323 - (-942), -504 - (-1456))
local function humanAt(d, closing, o)
    local x = me.x - math.cos(ang) * d
    local y = me.y - math.sin(ang) * d
    local h = hero(x, y, o)
    h.vx, h.vy = math.cos(ang) * closing, math.sin(ang) * closing
    h.hp = (o and o.hp) or 200
    return h
end
check("G4 6:54.33 e on approaching dancer at 879 is refused", not D.JukeOK(me, humanAt(879, 349), 3, 879, true))
check("G4 6:57.27 e at 940 refused", not D.JukeOK(me, humanAt(940, 0), 3, 940, true))
check("e at 900 on a mover refused (after a cancel)", not D.JukeOK(me, humanAt(900, 300), 3, 900, true))
D.mem.lastCancel = nil
check("no recent cancel -> gate open (keeps the 82 replay hits)", D.JukeOK(me, humanAt(900, 349), 3, 900))
_G.__T = 100; D.mem.lastCancel = 95
check("5 s after a cancel the gate is active", not D.JukeOK(me, humanAt(900, 349), 3, 900))
_G.__T = 0
check("e at 760 on a mover is allowed (band centre)", D.JukeOK(me, humanAt(760, 349), 3, 760, true))
check("e at 820 on a standing target is allowed", D.JukeOK(me, humanAt(820, 0), 3, 820, true))
check("e at 900 on a target locked in his own cast is allowed", D.JukeOK(me, humanAt(900, 0, { busyInit = 0.25 }), 3, 900, true))
check("lethal e at 850 on a mover is allowed (coin flip worth it)", D.JukeOK(me, humanAt(850, 300, { hp = 60 }), 3, 850, true))

-- 2. approach margin: a walking-in human enlarges the keep-out radius
local en = humanAt(950, 0)
local n0 = D.SpaceNeed(me, en, 0)
local n1 = D.SpaceNeed(me, humanAt(950, 330), 0)
check(string.format("approach margin grows need %.0f -> %.0f (>= +100)", n0, n1), n1 - n0 >= 100)

-- 3. anti-jitter toy: enemy at origin, last-hit spot 800 from him (inside his 990 e threat), bot speed 300.
--    old = 10-unit release + unprojected CS moves; new = hysteresis + projection onto the circle edge.
local function run(new)
    local x, dir, rev, t = 1100, 0, 0, 0
    local spaceOut = false
    local need = 990
    for _ = 1, 100 do -- 10 s at 0.1 s director ticks
        local target
        if new then
            if spaceOut and x >= need + 40 then spaceOut = false end
            if not spaceOut and x < need - 10 then spaceOut = true end
            if spaceOut then target = need + 90 else target = math.max(800, need + 10) end
        else
            if x < need - 10 then target = need + 60 else target = 800 end
        end
        local step = math.max(-30, math.min(30, target - x))
        local nd = (step > 0.5 and 1) or (step < -0.5 and -1) or 0
        if nd ~= 0 and dir ~= 0 and nd ~= dir then rev = rev + 1 end
        if nd ~= 0 then dir = nd end
        x = x + step
    end
    return rev
end
local rOld, rNew = run(false), run(true)
check(string.format("toy KITE-vs-CS reversals per 10 s: v5.0 %d -> v5.1 %d", rOld, rNew), rNew <= 2 and rOld >= 10)

print(string.format("%d/%d v5.1 unit checks passed", total - fails, total))
os.exit(fails == 0 and 0 or 1)
