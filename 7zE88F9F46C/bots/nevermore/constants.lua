
local C = {}

C.HERO = {
    PROJECTILE_SPEED = 1200,
    DAMAGE_HALF_RANGE = 3, -- SF 7.41f: base damage 16-22 -> half-spread 3 (see U.SFDamageRange)
}

C.ITEMS = {
    -- Magic Stick was a panic button at 10 % HP, i.e. it usually fired one creep hit too late.
    -- 0.26 fires it before the burst that actually kills us (measured on 120 games: networth
    -- +19, creep damage -9). Set to 0.10 to get the original behaviour back.
    STICK_USE_PCT = 0.26,
}

C.LASTHIT = {
    NET_LATENCY       = 0.05,
    DENY_HP_THRESHOLD = 0.50,
    CANCEL_WINDOW     = 0.08,
    COMMIT_HP_BUFFER  = 8,
    -- Contest a creep that MY tower is about to last-hit. The tower is the last-hitter and the
    -- bot never contested it (17.8 creeps per game go to our own tower); this handler takes the
    -- free ones on the lowest priority. false = the original behaviour.
    TOWER_STEAL_LH    = true,
    TOWER_STEAL_RANGE_PAD = 35,
    TOWER_STEAL_SHOTS = 2.2,
    -- Contested creep (an enemy hero within its attack radius): creep hits that are not determined
    -- are counted at the middle of the cycle (not the worst case) - otherwise a bot with MORE damage hit the creep
    -- at the same moment as the weaker enemy and lost it to the deny.
    CONTEST_SLACK     = 0.45,
    CONTEST_RANGE_PAD = 150,
}

C.RAZE = {
    COOLDOWN            = 9.0,  -- measured (all levels) in the three replays
    STACK_DURATION      = 6.0,  -- modifier_nevermore_shadowraze_debuff since 7.41e (was 8.0)
    BASE_DAMAGE         = { 85, 150, 215, 280 }, -- 7.41f
    STACK_DAMAGE        = { 35, 50, 65, 80 },    -- 7.41f
    NEAR_CENTER         = 200,
    -- Raze policy with 1 point (L1-L2): start only point blank / as a mirror / as a finish
    AGGRO_MIN_RAZE_LEVEL = 2, -- from this raze level (2 points, usually hero L3) - aggression without limits
    EARLY_CHAIN_DIST     = 360, -- enemy closer -> a chain can be started (near -> mid -> far)
    MIRROR_WINDOW        = 2.5, -- s: after his cast we answer with ours (mirror)
    NEAR_CHAIN_WINDOW    = 5.0, -- s: after the near punish, finishing razes go without a mana reserve
    MID_CENTER          = 450,
    FAR_CENTER          = 700,
    HIT_RADIUS          = 250,
    STRICT_RADIUS       = 190,
    CAST_POINT          = 0.55,
    PREDICT_DELAY       = 0.62,
    EXTEND_AT           = 3.05,
    HARASS_MARGIN    = 90, -- A harass raze only with a robust error <= 250-90=160 (a reacting enemy at the edge leaves the circle)
    MAX_ANGLE_TO_CAST   = 6, -- Cast only when facing the aim point (was 8 and was not checked in the main path)
    TURN_STEP           = 40, -- The "turn" step (u): shorter and the engine may not turn the hero
    MIRROR_INSTANT_SEC  = 0.7, -- His raze hit us no later than this - an instant answer with the same/any band
    MIRROR_MIN_HP_LEFT  = 110, -- No less HP may remain after his next raze
    -- v5.1 anti-bait: reachable-disc slack (seconds of his movement the coil must absorb), see U.RazeJukeOK
    JUKE = { SLACK_MOVING = 0.33, SLACK_STILL = 0.25, LETHAL_MULT = 0.5, HULL = 24, WINDOW = 12 },
    -- The raze lands slightly after the cast ends (animation + projectile): the hit check
    -- takes three points (now / middle of the cast / landing) instead of two.
    LAND_LEAD           = 0.08,
    ENEMY_THREAT_RANGE  = 930,
    RETREAT_MIN_REMAIN  = 0.35,
    MISS_DETECT_WINDOW  = 0.75,
    MISS_ADVANTAGE_TIME = 6.0,
    -- Robust aiming - the raze circle must cover the enemy both at the current and the predicted
    -- point (in case he "stops" / "starts walking"); the margin from the circle edge:
    ROBUST_MARGIN       = 30,
    -- Stack finish: the second/third raze immediately while the enemy is in reach (no waiting for EXTEND_AT),
    -- if he has a fresh stack with a remaining time of at least:
    FOLLOWUP_MIN_REMAIN = 1.2,
    -- Punishing an enemy that walked up close beats waiting for the last hit
    PUNISH_CLOSE_RANGE   = 520,
    PUNISH_MIN_POT_MANA  = 150, -- Mana for two razes (near + finishing)
}

C.HARASS = {
    BASE_COOLDOWN          = 0.0,
    MISS_BONUS_COOLDOWN    = 0.0,
    APPROACH_DISTANCE      = 800,
    APPROACH_DISTANCE_MISS = 1100,
    MIN_HP_PCT             = 0.45,
    MIN_HP_PCT_MISS        = 0.35,
    INTERRUPT_APPROACH     = 1300,
}

-- 7.41f (npc_dota_hero_nevermore.txt): necromastery_damage_per_soul = 1, +0.8 every 6 hero levels
C.NECROMASTERY = {
    BASE_DMG_PER_SOUL         = 1.0,
    DMG_PER_SOUL_PER_6_LEVELS = 0.8,
    MAX_SOULS                 = 20,
}

C.TP = {
    RETURN_DISTANCE_FROM_T1 = 3200,
    FOUNTAIN_RADIUS         = 400,
    RETURN_HP_PCT           = 0.50,
}

C.POSITIONS = {
    MID_LANE_CENTER      = Vector(503.58, -1010.36, 1124.97),
    MIDLANE_CENTER       = Vector(503.58, -1010.36, 1124.97),
    MID_FOUNTAIN_RADIANT = Vector(-6848, -6336, 384),
    MID_FOUNTAIN_DIRE    = Vector(6656, 6080, 384),
    RADIANT_T1           = Vector(-1544.00, -1408.00, 256.00),
    RADIANT_T1_CLOSE     = Vector(-1395.50, -1259.50, 256.00), -- ~210 from true 7.41f Radiant Mid T1 toward river
    RADIANT_FLANK_TOP    = Vector(-1417.84, -1061.84, 1123.81),
    RADIANT_FLANK_BOT    = Vector(-591.38, -1812.09, 1138.51),
    WARD_RADIANT         = Vector(-620.00, -490.00, 256.00),
    DIRE_T1              = Vector(524.00, 652.00, 256.00),
    DIRE_T1_CLOSE        = Vector(375.50, 503.50, 256.00),     -- ~210 from true 7.41f Dire Mid T1 toward river
    DIRE_FLANK_TOP       = Vector(-425.08, -37.47, 1123.98),
    DIRE_FLANK_BOT       = Vector(423.34, -847.56, 1117.69),
    WARD_DIRE            = Vector(-165.00, 175.00, 256.00),
}

C.TANGO = {
    USE_HP_PCT     = 0.82,
    MIN_MISSING_HP = 115,
    SEARCH_RADIUS  = 1400,
    COMMIT_TIME    = 8.0,
    STUCK_TIME     = 3.5,
    TOWER_MIN_DIST = 1125,
    ENEMY_MIN_DIST = 650,
}

-- v5.1 regen economy copied from the human (G4: mango 5:43 / 6:18 / 7:01 / 7:46, salve 5:45 / 6:19 / 7:47 - a
-- salve+mango pair every ~35-40 s IN LANE, zero walks home; the bot walked home 3 times = ~100 s off the lane)
C.CONSUMABLE_BUY = {
    RECOVERY_WINDOW   = 150,
    RECOVERY_BUDGET   = 650,
    RECOVERY_COOLDOWN = 20,
    RECOVERY_RESERVE  = 0,
    SALVE_CD          = 35,   -- was 62
    MANGO_CD          = 35,   -- was 55
    PRE_BOOTS_SALVES  = 3,    -- was 1
    PRE_BOOTS_MANGOES = 3,    -- was 1
    AGONY_HP          = 110,  -- block buys only in real death agony (was 195 + any enemy within 850)
}

C.ITEM_PRIORITY = {
    ["item_kaya"]              = 100,
    ["item_dragon_lance"]      = 90,
    ["item_power_treads"]      = 80,
    ["item_boots"]             = 76,
    ["item_staff_of_wizardry"] = 75,
    ["item_blade_of_alacrity"] = 74,
    ["item_belt_of_strength"]  = 73,
    ["item_robe"]              = 72,
    ["item_bracer"]            = 70,
    ["item_magic_wand"]        = 60,
    ["item_magic_stick"]       = 50,
    ["item_circlet"]           = 40,
    ["item_gauntlets"]         = 35,
    ["item_faerie_fire"]       = 30,
    ["item_enchanted_mango"]   = 25,
    ["item_flask"]             = 20,
    ["item_tango"]             = 15,
    ["item_branches"]          = 10,
    ["item_ward_observer"]     = 5,
}

C.EMERGENCY = {
    RAZE_KILL_FACTOR     = 1.15,
    SINGLE_RAZE_FACTOR   = 1.05,
    MIN_HP_ABSOLUTE      = 180,
    COURIER_SEARCH_RANGE = 3000,
    COURIER_MEET_RANGE   = 1500,
}

C.GLYPH = {
    AVAILABLE_AT        = 180,
    COOLDOWN            = 300,
    T1_HP_PCT_THRESHOLD = 0.30,
    T1_HP_ABS_THRESHOLD = 540,
    KILL_DIVE_RANGE     = 900,
    -- The glyph "for a dive" only during an ongoing finish (the burst right now kills, we are attacking/aiming)
    DIVE_REQUIRE_KILL_NOW = true,
}

C.T1_SAFETY = {
    LAST_CREEP_HP_LOSS_CHECK = true,
    RETREAT_BUFFER           = 250,
    CREEP_DRIFT_START        = 620,
    CREEP_DRIFT_HARD         = 700,
    CREEP_DRIFT_DELTA        = 22,
}

C.FORCED_SALVE = {
    HP_PCT_THRESHOLD = 0.66,
}

-- Free pressure (added 2026-10-20, replay-driven: the bot made 2 hero right-clicks in 9 minutes
-- against a human SF and never answered right-click pressure with a raze).
-- Both blocks only ADD an action where the bot previously did nothing at all; every gate below
-- is a hard veto, so a risky situation can never be created by them.
C.FREE_HIT = {
    ENABLED        = true,
    TOWER_CLEAR    = 900,  -- no enemy tower closer than this to us (same rule as short combat)
    SAFE_HP_ABS    = 90,   -- expected burst must leave at least this much HP
    SAFE_HP_FACTOR = 1.15, -- ... and at least this many enemy hits
    FINISH_HP_PCT  = 0.35, -- the only reason to hit an enemy who is NOT attacking us
    LASTHIT_PAD    = 120,  -- do not trade a last hit for a hero swing
    SETTLE_TIME    = 0.35, -- horizon used for the incoming-damage estimate
}

C.FREE_RAZE = {
    ENABLED      = true,
    REPLY_WINDOW = 0.8,   -- answer ANY enemy raze cast this recently, even if it missed us
    SURPLUS_MANA = 150,   -- a proactive raze (nobody is threatening us) must leave one cast in reserve
    MIN_HP_PCT   = 0.55,  -- proactive razes only from this HP share
    MIN_HP_PCT_ANSWER = 0.30, -- answers are allowed lower, but never below this
    MIN_HP_AFTER = 90,
    TOWER_CLEAR  = 900,
    SAFE_VS_ANSWER_PCT = 0.80, -- a proactive raze into a hero who can raze back needs this HP share
}


C.SAFE_DISTANCE = {
    MIN_DISTANCE_FROM_ENEMY = 750,
    MIN_DISTANCE_CRITICAL   = 950,
    CRITICAL_HP_FACTOR      = 1.05,
    KILL_THREAT_FACTOR      = 1.20,
    SINGLE_KILL_FACTOR      = 1.10,
}

C.FINISH = {
    MIN_STACKS_FOR_CLOSE = 2,
    CLOSE_APPROACH_RANGE = 600,
    MIN_HP_PCT_FOR_CLOSE = 0.30,
}

C.BOOT_FEAR = {
    MID_RAZE_RADIUS       = 220,
    RETREAT_DURATION      = 0.95,
    RETREAT_DISTANCE_BONUS = 140,
    TWO_RAZE_MANA_COST    = 150,
    STICK_CHARGES_THREAT  = 10,
}

C.NEAR_REPLY = {
    WAIT_AFTER_HIT   = 1.0,
    HOLD_DISTANCE    = 215,
    HOLD_MIN_DISTANCE = 150,
    HOLD_MAX_DISTANCE = 250,
    HOLD_TOLERANCE    = 25,
}

C.FORCE_EXTEND = {
    PREFER_MID_WITH_BOOTS = true,
    FAR_DOWNGRADE_TO_MID  = true,
    FAR_CANCEL_TOLERANCE  = 60,
}

C.PUSH = {
    PUSH_ATTACK_RANGE     = 700,
    T1_ATTACK_RANGE       = 900,
    MIN_CREEPS_TO_TANK    = 2,
    MIN_HP_PCT_TO_PUSH    = 0.50,
    TOWER_SAFE_CREEP_HP   = 200,
    -- The tower is nearly down - finish it despite the shield/HP/burn (breaking the T1 wins)
    TOWER_FINISH_HITS     = 3,
    TOWER_FINISH_MIN_HP   = 0.22,
}

C.REGEN = {
    ENEMY_SAFE_DISTANCE = 1100,
    FLASK_SAFE_DISTANCE = 1150,
    -- A consumable bought with a FULL inventory lands in the backpack (slots 6-8). The original
    -- U.ManageInventorySlots promotes backpack items by C.ITEM_PRIORITY, and the flask sits at 20 -
    -- below every build item, so it could never come back. Measured in probe_flask.lua: the bot
    -- stood at 40 % HP for 25 s next to an unusable flask and drank nothing. While HP is below this
    -- fraction the flask is pulled into the inventory (displacing the least valuable item).
    FLASK_PULL_HP_PCT   = 0.60,
}

C.FOUNTAIN = {
    GO_HP_CRITICAL_PCT  = 0.15,
    GO_HP_WITH_MANA_PCT = 0.0,
    GO_MANA_WITH_HP_PCT = 0.0,
    STICK_CHARGES_ENOUGH = 10,
    WAIT_FULL_HP_PCT    = 0.98,
    WAIT_FULL_MANA_PCT  = 0.98,
    AT_FOUNTAIN_RADIUS  = 500,
    -- The enemy has exactly as few resources as we do - walking to the fountain simply hands
    -- the lane. Do not leave, keep the distance and regen. Exception - very low HP.
    SYMMETRIC_ENABLE    = true,
    SYMMETRIC_HP_GAP    = 0.10, -- his HP% is not above ours + this much (or lower)
    SYMMETRIC_FLOOR_PCT = 0.12, -- below this HP we leave regardless
    SYMMETRIC_MIN_HP    = 110, -- absolute floor (below MIN_HP_ABSOLUTE the rule would be dead)
}

C.STACK_NEAR_FEAR = {
    MIN_DISTANCE   = 470,
    RETREAT_BUFFER = 60,
}

-- World / combat / intents (world.lua, combat.lua, lane.lua, intent.lua)
C.RAZE.COOLDOWN                     = 9.0 -- 7.41f: all three razes
C.RAZE.DAMAGE_PER_SOUL              = 2 -- +2 raze damage per soul
C.RAZE.SINGLE_TRADE_LEVEL_TOLERANCE = 1
C.RAZE.SECOND_STACK_AVOID_RADIUS    = 190

C.LASTHIT.ALLY_DPS_FACTOR = 0.70 -- Only the fallback averaged model (attackers without data)
C.LASTHIT.IMPACT_LEAD = 0.0 -- Exact 30Hz tick phase-lock handles intra-tick projectile vs melee order directly
C.LASTHIT.PREHIT_ANYWHERE = false -- Tower prep handled by exact discrete multi-shot solver in lasthit.lua

-- Exact 30.000 Hz Source 2 Ballistic CS & Phase-Lock Configuration (calibrated on .dem telemetry)
C.BALLISTIC = {
    TICK_RATE            = 30.0,
    TICK_DT              = 1.0 / 30.0,
    HORIZON_TICKS        = 120,   -- 4.000 s exact integer tick forecast horizon
    SF_BAT               = 1.60,  -- Shadow Fiend Base Attack Time (7.41f)
    SF_BASE_AP           = 0.50,  -- Unscaled KV m_flAttackAnimationPoint
    SF_TURN_RATE         = 0.90,  -- Radians per 0.03 s tick interval
    ATTACK_FACING_CONE   = 11.5,  -- Degrees within which Source 2 starts attack windup without extra turn tick
    DEFAULT_HIT_RADIUS   = 12.0,  -- Exact CProjectileManager collision half-hull (24 * 0.5 = 12.0u)
    CLOSE_STAND_DIST     = 175.0, -- Close ballistic stance (~4-5 flight ticks = 0.133-0.167 s) when safe
    SAFE_STAND_DIST      = 360.0, -- Balanced stance when enemy hero threatens close range
    MAX_STAND_DIST       = 495.0, -- Safe max-range stance inside 525 attack range
    PRESWING_BUFFER_TICKS= 9,     -- Start pre-swing early to lock 0.0 deg facing before S-cancel phase lock
    RAZE_CAST_TICKS      = 17,    -- 0.55 s Shadowraze cast point = ceil(0.55 * 30) = 17 server ticks
    SACRED_CS_WINDOW_S   = 1.35,  -- Lock out non-lethal poke/fear/retreat while securable CS is within 1.35 s
}

-- Skill build (without Feast of Souls / nevermore_frenzy - the lobby rules forbid it entirely).
-- Index = hero level; the value is an ability name or a list of names (talents cost no points,
-- so at 10/15/20/25 the talent is taken TOGETHER with the next point).
-- Talents 7.41f: 10 = +30 damage per raze stack (special_bonus_unique_nevermore_7),
-- 15 = -1.5 armour from Presence (_3), 20 = +5 souls (_1), 25 = razes proc attacks (_raze_procsattacks).
-- Raze and the passive are maxed by level 8, so from level 9 every point goes into "+2 all attributes"
-- (attribute_bonus, 7 levels max).
C.SKILL = {
    ALLOW_FRENZY = false,
    ORDER = {
        [1]  = "nevermore_shadowraze1",
        [2]  = "nevermore_dark_lord",
        [3]  = "nevermore_shadowraze1",
        [4]  = "nevermore_dark_lord",
        [5]  = "nevermore_shadowraze1",
        [6]  = "nevermore_dark_lord",
        [7]  = "nevermore_shadowraze1",
        [8]  = "nevermore_dark_lord",
        [9]  = "attribute_bonus",
        [10] = { "special_bonus_unique_nevermore_7", "attribute_bonus" },
        [11] = "attribute_bonus",
        [12] = "attribute_bonus",
        [13] = "attribute_bonus",
        [14] = "attribute_bonus",
        [15] = { "special_bonus_unique_nevermore_3", "attribute_bonus" },
        [20] = "special_bonus_unique_nevermore_1",
        [25] = "special_bonus_unique_nevermore_raze_procsattacks",
    },
}

-- Power Treads: 0 = strength, 1 = agility, 2 = intelligence (the engine Attributes enum).
-- In-game switch order: strength -> intelligence -> agility -> strength.
C.TREADS = {
    STRENGTH        = 0,
    AGILITY         = 1,
    INTELLIGENCE    = 2,
    SWITCH_COOLDOWN = 0.35, -- emergency switch (strength while surviving) - no more often than this
    MODE_HOLD       = 1.0, -- the normal mode (agility while attacking / intelligence while idle) is held for this long
    SURVIVE_HP_PCT  = 0.30, -- below this HP we stay on strength
}

-- v5.0 Combat Director (nevermore/duel.lua): rollout simulation of both heroes' macro policies, robust minimax choice.
C.DIRECTOR = {
    ENABLED       = true,
    EVAL_INTERVAL = 0.10, -- seconds between full evaluations (~12 ms each in Lua 5.1)
    MAX_DIST      = 1500, -- the enemy hero farther than this -> the Director stays idle
    RESET_SEC     = 6.0,  -- lost / retreat-only lane this long (HP < 45%, no regen running) -> walk to the fountain
    SLICE         = 3,    -- policies evaluated per frame (7 total -> a full decision every 3 frames, <= ~5 ms/frame)
}

C.TOWER = {
    -- v5.0: the enemy T1 starts shooting the bot from 865 (center to center, user-measured); every tower threshold is
    -- derived from it. The old 700/780/820 let the bot right-click the hero from 790-865 and eat tower shots.
    AGGRO_RADIUS      = 865,
    ATTACK_RANGE      = 865, -- effective T1 reach (700 attack range + hull radii)
    SAFE_RADIUS       = 890, -- the radius inside which we consider ourselves "under the tower"
    CHASE_LEASH       = 900, -- do not chase to a point closer than this to the enemy T1 without a creep shield
    MIN_SHIELD_TO_HIT = 2, -- minimum own creeps under the tower to hit the T1
    DIVE_MAX_TIME     = 1.0, -- Maximum time in a row inside the T1 radius "for the hero" (chasing/razing him)
    BURN_SEC          = 2.5, -- After leaving the T1, this many seconds with no dives and no tower attacks
    BURN_REPEAT_SEC   = 6.0, -- Leaving the T1 again within REPEAT_WINDOW s -> a longer burn
    REPEAT_WINDOW     = 10,
    -- Leaving the enemy T1 is a hard commitment (no other orders
    -- until we are out), otherwise the handlers overrode each other and the bot "jittered" in place.
    ESCAPE_RADIUS     = 960, -- we leave past this radius from the tower
    ESCAPE_MIN_STEP   = 240, -- the escape order must take us at least this far
    ESCAPE_COMMIT_SEC = 3.0, -- maximum time for a single escape commitment
}

C.INTENT = {
    ENEMY_ABSENT_SEC = 5.0, -- the enemy is dead / unseen for longer -> PUSH
    PUSH_EDGE        = 260, -- burst (absolute HP) advantage for PUSH with a live enemy
    ZONE_EDGE        = 70, -- advantage for ZONE
    TRADE_EDGE       = -30, -- allowed deficit for TRADE
    LOW_HP_PCT       = 0.22,
    PUSH_MIN_HP_PCT  = 0.55,
    PUSH_KEEP_HP_PCT = 0.45,
    ZONE_WAVE_DIST   = 900, -- the enemy is closer than this to the wave -> there is someone to zone
    -- "Hunt": a large absolute HP edge and the enemy is killable by my burst within
    -- HUNT_HORIZON (razes that will be ready + mango/stick + 1 hit) -> ALLIN even at low mana
    HUNT_HP_EDGE     = 250, -- my HP - his HP no less than
    HUNT_MIN_HP_PCT  = 0.40,
    HUNT_HORIZON     = 4.0, -- s: razes with a cooldown remaining of no more than this count as available
    HUNT_MAX_DIST    = 1100,
    HUNT_SAFETY_HP   = 80, -- his burst from mid-band distance must leave me >= this
}

C.ZONE = {
    HOLD_DIST        = 520, -- Stay at right-click distance, no closer than minSafeDist
    MAX_FROM_WAVE    = 520, -- do not move further from the wave than this for zoning
    ATTACK_RANGE_PAD = 40,
}

C.MANA = {
    RESERVE_FOR_PRESSURE = 75,
    EARLY_RESERVE_L2 = 150,
    EARLY_RESERVE_L4 = 112,
    EARLY_LEVEL_L2   = 2,
    EARLY_LEVEL_L4   = 4,
    FOLLOWUP_KEEP    = 60,
    FOLLOWUP_KEEP_L2 = 130,
    PARITY_ENABLE    = true,
    PARITY_MIN_ENEMY = 2,
    PARITY_GAP       = 1,
    PARITY_LEVEL_DIFF = 1,
    PARITY_ITEM_DIFF  = 0.35,
}

-- Defensive stance "I am weaker": auto attacks + burst + both HP pools (see K.Race).
C.DEFENSE = {
    WEAKER_EDGE      = 120, -- the 6 s trade projection is worse by this much absolute HP -> I am weaker
    EXIT_EDGE        = 40, -- leaving defence: the projection is better than -40 (hysteresis)
    MIN_HOLD_SEC     = 2.0,
    KITE_PAD         = 140, -- back off past his attack radius + this much
    SUPPORT_CREEPS   = 2, -- this many of my creeps hit him -> we may answer even while defending
    CONTEST_PAD      = 80, -- defence: do not take a last hit if the hit position is within his attack radius + this
    SUSTAINED_TTK_RATIO = 0.8, -- "Weaker in the long run": he kills me with right clicks faster than I kill him, by 1/0.8 times
}

return C
