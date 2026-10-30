-- Minimal-but-permissive mock of the Dota 2 bot API (Lua 5.1) for smoke-testing bot_nevermore.lua outside the game.
-- Unknown unit/ability/item methods fall back to name-based defaults (Is*/Has*/Can* -> false, Get*Location -> Vector,
-- GetNearby* -> {}, other Get* -> 0) and are recorded in MOCK.missing so we know what the bot touches.
MOCK = { t = 0, missing = {}, orders = {}, units = {} }

---------------------------------------------------------------- Vector
local VMT = {}
VMT.__index = VMT
function Vector(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VMT) end
VMT.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
VMT.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
VMT.__mul = function(a, b)
    if type(a) == "number" then return Vector(b.x * a, b.y * a, b.z * a) end
    if type(b) == "number" then return Vector(a.x * b, a.y * b, a.z * b) end
    return a.x * b.x + a.y * b.y + a.z * b.z
end
VMT.__div = function(a, b) return Vector(a.x / b, a.y / b, a.z / b) end
VMT.__unm = function(a) return Vector(-a.x, -a.y, -a.z) end
VMT.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
VMT.__tostring = function(a) return string.format("V(%.0f,%.0f)", a.x, a.y) end
function VMT:Length() return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
function VMT:Length2D() return math.sqrt(self.x ^ 2 + self.y ^ 2) end
function VMT:Normalized()
    local l = self:Length2D(); if l < 1e-6 then return Vector(0, 0, 0) end
    return Vector(self.x / l, self.y / l, 0)
end
function VMT:Dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function VMT:Cross(b) return Vector(self.y * b.z - self.z * b.y, self.z * b.x - self.x * b.z, self.x * b.y - self.y * b.x) end

---------------------------------------------------------------- constants
TEAM_RADIANT, TEAM_DIRE, TEAM_NEUTRAL = 2, 3, 4
LANE_TOP, LANE_MID, LANE_BOT = 1, 2, 3
DAMAGE_TYPE_PHYSICAL, DAMAGE_TYPE_MAGICAL, DAMAGE_TYPE_PURE, DAMAGE_TYPE_ALL = 1, 2, 4, 7
ATTRIBUTE_STRENGTH, ATTRIBUTE_AGILITY, ATTRIBUTE_INTELLECT = 0, 1, 2
UNIT_LIST_ALL, UNIT_LIST_ENEMIES, UNIT_LIST_ALLIES = 0, 1, 2
TOWER_TOP_1, TOWER_MID_1, TOWER_BOT_1, TOWER_MID_2, TOWER_MID_3 = 0, 1, 2, 4, 7
BOT_ACTION_TYPE_NONE, BOT_ACTION_TYPE_IDLE, BOT_ACTION_TYPE_MOVE_TO, BOT_ACTION_TYPE_ATTACK, BOT_ACTION_TYPE_USE_ABILITY = 0, 1, 2, 4, 6
BOT_ACTION_TYPE_PICK_UP_ITEM, BOT_ACTION_TYPE_DROP_ITEM, BOT_ACTION_TYPE_DELAY = 10, 11, 13
ITEM_SLOT_TYPE_MAIN, ITEM_SLOT_TYPE_BACKPACK, ITEM_SLOT_TYPE_STASH = 0, 1, 2
COURIER_ACTION_BURST, COURIER_ACTION_ENEMY_SECRET_SHOP, COURIER_ACTION_RETURN, COURIER_ACTION_SECRET_SHOP = 0, 1, 2, 3
COURIER_ACTION_TAKE_STASH_ITEMS, COURIER_ACTION_TRANSFER_ITEMS, COURIER_ACTION_TAKE_AND_TRANSFER_ITEMS = 4, 5, 6
COURIER_ACTION_RETURN_STASH_ITEMS = 7
COURIER_STATE_IDLE, COURIER_STATE_AT_BASE, COURIER_STATE_MOVING, COURIER_STATE_DELIVERING_ITEMS = 0, 1, 2, 3
COURIER_STATE_RETURNING_TO_BASE, COURIER_STATE_DEAD = 4, 5
PURCHASE_ITEM_SUCCESS = -1
GAME_STATE_PRE_GAME, GAME_STATE_GAME_IN_PROGRESS = 4, 5
BOT_MODE_NONE, BOT_MODE_LANING, BOT_MODE_ATTACK, BOT_MODE_RETREAT = 0, 1, 2, 3
BOT_MODE_DESIRE_NONE, BOT_MODE_DESIRE_LOW, BOT_MODE_DESIRE_MODERATE, BOT_MODE_DESIRE_HIGH = 0, 0.25, 0.5, 0.75
BOT_MODE_DESIRE_VERYHIGH, BOT_MODE_DESIRE_ABSOLUTE = 0.9, 1.0
SHOP_HOME, SHOP_SIDE, SHOP_SECRET = 0, 1, 2
GLYPH_COOLDOWN = 300

---------------------------------------------------------------- generic fallback objects
local function defaultFor(name, self)
    if name:match("^Is") or name:match("^Has") or name:match("^Can") or name:match("^Was") then return function() return false end end
    if name:match("Location$") or name:match("Position$") then return function(s) return (s and s._loc) or Vector(0, 0, 0) end end
    if name:match("^GetNearby") or name:match("^Get.*List$") or name:match("s$") and name:match("^Get") then return function() return {} end end
    if name:match("^Get") then return function() return 0 end end
    if name:match("^Action_") or name:match("^ActionPush_") or name:match("^ActionQueue_") then
        return function(s, ...) table.insert(MOCK.orders, { t = MOCK.t, unit = s and s._name, order = name, args = { ... } }); return true end
    end
    return function() return nil end
end
local function permissive(cls, label)
    return function(t, k)
        local v = rawget(cls, k)
        if v ~= nil then return v end
        if type(k) ~= "string" or k:sub(1, 1) == "_" then return nil end
        MOCK.missing[label .. ":" .. k] = (MOCK.missing[label .. ":" .. k] or 0) + 1
        return defaultFor(k, t)
    end
end

---------------------------------------------------------------- abilities / items
Ability = {}
local AMT = { __index = permissive(Ability, "ability") }
function MOCK.NewAbility(name, owner, lvl, extra)
    local a = setmetatable({ _name = name, _owner = owner, _lvl = lvl or 0, _cdEnd = -1, _charges = 0 }, AMT)
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end
function Ability:GetName() return self._name end
function Ability:GetLevel() return self._lvl end
function Ability:GetMaxLevel() return 4 end
function Ability:IsTrained() return self._lvl > 0 end
function Ability:IsHidden() return false end
function Ability:IsPassive() return self._name == "nevermore_necromastery" end
function Ability:IsCooldownReady() return MOCK.t >= self._cdEnd end
function Ability:GetCooldownTimeRemaining() return math.max(0, self._cdEnd - MOCK.t) end
function Ability:GetCooldown() return self._cd or 9.0 end
function Ability:GetManaCost() return self._mana or 75 end
function Ability:IsFullyCastable()
    if self._isItem then return MOCK.t >= self._cdEnd end
    return self._lvl > 0 and MOCK.t >= self._cdEnd and self._owner._mp >= (self._mana or 75)
end
function Ability:IsOwnersManaEnough() return self._owner._mp >= (self._mana or 75) end
function Ability:IsInAbilityPhase() return false end
function Ability:IsChanneling() return false end
function Ability:GetCastPoint() return self._castPoint or 0.55 end
function Ability:GetCastRange() return self._range or 0 end
function Ability:GetCurrentCharges() return self._charges end
function Ability:GetInitialCharges() return self._charges end
function Ability:GetSecondaryCharges() return 0 end
function Ability:GetCaster() return self._owner end
function Ability:GetSpecialValueInt(k) return math.floor(self:GetSpecialValueFor(k)) end
function Ability:GetSpecialValueFloat(k) return self:GetSpecialValueFor(k) end
function Ability:GetSpecialValueFor(k)
    local L = math.max(1, self._lvl)
    local n = self._name
    if n:find("shadowraze") then
        if k == "shadowraze_damage" then return ({ 85, 150, 215, 280 })[L] end
        if k == "stack_bonus_damage" then return ({ 35, 50, 65, 80 })[L] end
        if k == "shadowraze_radius" then return 250 end
        if k == "shadowraze_range" then return ({ nevermore_shadowraze1 = 200, nevermore_shadowraze2 = 450, nevermore_shadowraze3 = 700 })[n] end
        if k == "duration" then return 6 end
        if k == "souls_damage" or k == "damage_per_soul" then return 2 end
    end
    if n == "nevermore_necromastery" then
        if k == "necromastery_max_souls" then return 20 end
        if k == "necromastery_damage_per_soul" then return 1.3 end
    end
    return 0
end
function Ability:GetAbilityDamage() return self:GetSpecialValueFor("shadowraze_damage") end
function Ability:GetToggleState() return false end
function Ability:GetAutoCastState() return false end
function Ability:GetBehavior() return 0 end
function Ability:GetTargetTeam() return 0 end
function Ability:GetTargetType() return 0 end
function Ability:GetHeroLevelRequiredToUpgrade() return 1 end
function Ability:CanAbilityBeUpgraded() return self._lvl < 4 end
function Ability:GetDuration() return 0 end
function Ability:GetCastTime() return 0 end

---------------------------------------------------------------- units
Unit = {}
local UMT = { __index = permissive(Unit, "unit") }
local nextId = 1
function MOCK.NewUnit(o)
    local u = setmetatable({}, UMT)
    u._id = nextId; nextId = nextId + 1
    u._name = o.name or "npc_dota_creep"
    u._team = o.team or TEAM_DIRE
    u._loc = o.loc or Vector(0, 0, 0)
    u._hp = o.hp or 550; u._mhp = o.mhp or u._hp
    u._mp = o.mp or 0; u._mmp = o.mmp or u._mp
    u._lvl = o.lvl or 1
    u._hero = o.hero or false
    u._tower = o.tower or false
    u._creep = o.creep or false
    u._facing = o.facing or 0
    u._speed = o.speed or 305
    u._range = o.range or 500
    u._dmg = o.dmg or 50
    u._abilities = {}
    u._items = {}
    u._mods = {}
    u._alive = true
    u._lastAttack = -100
    u._vel = Vector(0, 0, 0)
    MOCK.units[#MOCK.units + 1] = u
    return u
end
function Unit:GetUnitName() return self._name end
function Unit:GetPlayerID() return self._pid or -1 end
function Unit:GetTeam() return self._team end
function Unit:GetLocation() return Vector(self._loc.x, self._loc.y, 0) end
function Unit:GetHealth() return self._hp end
function Unit:GetMaxHealth() return self._mhp end
function Unit:GetMana() return self._mp end
function Unit:GetMaxMana() return self._mmp end
function Unit:GetLevel() return self._lvl end
function Unit:GetHealthRegen() return self._hero and 2.5 or 0.5 end
function Unit:GetManaRegen() return self._hero and 1.2 or 0 end
function Unit:IsAlive() return self._alive and self._hp > 0 end
function Unit:IsHero() return self._hero end
function Unit:IsRealHero() return self._hero end
function Unit:IsIllusion() return false end
function Unit:IsTower() return self._tower end
function Unit:IsBuilding() return self._tower end
function Unit:IsCreep() return self._creep end
function Unit:IsBot() return self._isBot or false end
function Unit:IsCourier() return false end
function Unit:IsAncientCreep() return false end
function Unit:IsInvulnerable() return false end
function Unit:IsAttackImmune() return false end
function Unit:IsMagicImmune() return false end
function Unit:IsStunned() return false end
function Unit:IsRooted() return false end
function Unit:IsSilenced() return false end
function Unit:IsMuted() return false end
function Unit:IsDisarmed() return false end
function Unit:IsHexed() return false end
function Unit:IsNightmared() return false end
function Unit:IsUsingAbility() return false end
function Unit:IsChanneling() return false end
function Unit:IsCastingAbility() return false end
function Unit:IsFacingLocation(loc, deg)
    local d = loc - self._loc; local a = math.deg(math.atan2(d.y, d.x)) % 360
    local df = math.abs(((a - self._facing) + 180) % 360 - 180); return df <= deg
end
function Unit:CanBeSeen() return true end
function Unit:GetFacing() return self._facing end
function Unit:GetVelocity() return self._vel end
function Unit:GetCurrentMovementSpeed() return self._speed end
function Unit:GetBaseMovementSpeed() return self._speed end
function Unit:GetAttackRange() return self._range end
function Unit:GetAttackDamage() return self._dmg end
function Unit:GetBaseDamage() return self._dmg end
function Unit:GetAttackSpeed() return 100 end
function Unit:GetSecondsPerAttack() return self._hero and 1.6 or 1.0 end
function Unit:GetAttackPoint() return 0.5 end
function Unit:GetAttackProjectileSpeed() return 1200 end
function Unit:GetLastAttackTime() return self._lastAttack end
function Unit:GetAttackTarget() return self._atkTarget end
function Unit:GetArmor() return 2 end
function Unit:GetMagicResist() return 0.25 end
function Unit:GetBoundingRadius() return self._tower and 144 or 24 end
function Unit:GetActualIncomingDamage(v, typ)
    if typ == DAMAGE_TYPE_MAGICAL then return v * 0.75 end
    if typ == DAMAGE_TYPE_PHYSICAL then return v * 0.9 end
    return v
end
function Unit:GetAbilityByName(n) return self._abilities[n] end
function Unit:GetAbilityInSlot(i) return self._abilSlots and self._abilSlots[i] end
function Unit:GetItemInSlot(i) return self._items[i] end
function Unit:FindItemSlot(n) for i = 0, 16 do if self._items[i] and self._items[i]._name == n then return i end end return -1 end
function Unit:GetItemSlotType(i) if i <= 5 then return ITEM_SLOT_TYPE_MAIN elseif i <= 8 then return ITEM_SLOT_TYPE_BACKPACK end return ITEM_SLOT_TYPE_STASH end
function Unit:HasModifier(n) return self._mods[n] ~= nil end
function Unit:GetModifierByName(n) return self._mods[n] and self._mods[n].idx or -1 end
function Unit:GetModifierStackCount(i) for _, m in pairs(self._mods) do if m.idx == i then return m.stacks or 1 end end return 0 end
function Unit:GetModifierRemainingDuration(i) for _, m in pairs(self._mods) do if m.idx == i then return math.max(0, (m.until_ or 0) - MOCK.t) end end return 0 end
function Unit:NumModifiers() return 0 end
function Unit:GetGold() return self._gold or 600 end
function Unit:GetNetWorth() return 1000 end
function Unit:GetLastHits() return 0 end
function Unit:GetDenies() return 0 end
function Unit:GetCurrentActiveAbility() return nil end
function Unit:GetActiveMode() return BOT_MODE_LANING end
function Unit:GetActiveModeDesire() return 0.5 end
function Unit:GetCurrentActionType() return BOT_ACTION_TYPE_NONE end
function Unit:NumQueuedActions() return 0 end
function Unit:GetAbilityPoints() return 0 end
function Unit:GetRespawnTime() return 0 end
function Unit:TimeSinceDamagedByAnyHero() return 100 end
function Unit:TimeSinceDamagedByHero() return 100 end
function Unit:TimeSinceDamagedByCreep() return 100 end
function Unit:TimeSinceDamagedByTower() return 100 end
function Unit:WasRecentlyDamagedByHero() return false end
function Unit:WasRecentlyDamagedByCreep() return false end
function Unit:WasRecentlyDamagedByTower() return false end
function Unit:WasRecentlyDamagedByAnyHero() return false end
function Unit:GetCourierValue() return 0 end
function Unit:GetStashValue() return 0 end
function Unit:DistanceFromFountain() return 3000 end
function Unit:DistanceFromSideShop() return 5000 end
function Unit:DistanceFromSecretShop() return 5000 end
function Unit:GetPrimaryAttribute() return ATTRIBUTE_AGILITY end
function Unit:GetAttributeValue() return 20 end
function Unit:GetExtrapolatedLocation(dt) return self:GetLocation() + self._vel * dt end
function Unit:GetMovementDirectionStability() return 1 end
function Unit:GetEstimatedDamageToTarget(_, dur, tgt, typ) return self._dmg * dur end
function Unit:GetIncomingTrackingProjectiles() return {} end
function Unit:GetTarget() return nil end
function Unit:SetTarget() end
function Unit:GetNearbyHeroes(r, enemy, mode)
    local out = {}
    for _, u in ipairs(MOCK.units) do
        if u ~= self and u._hero and u:IsAlive() and ((u._team ~= self._team) == (enemy == true)) and GetUnitToUnitDistance(self, u) <= math.min(r, 1600) then out[#out + 1] = u end
    end
    return out
end
local function nearbyOf(self, r, enemy, pred)
    local out = {}
    for _, u in ipairs(MOCK.units) do
        if u ~= self and pred(u) and u:IsAlive() and ((u._team ~= self._team) == (enemy == true)) and GetUnitToUnitDistance(self, u) <= math.min(r, 1600) then out[#out + 1] = u end
    end
    return out
end
function Unit:GetNearbyCreeps(r, enemy) return nearbyOf(self, r, enemy, function(u) return u._creep end) end
function Unit:GetNearbyLaneCreeps(r, enemy) return nearbyOf(self, r, enemy, function(u) return u._creep end) end
function Unit:GetNearbyNeutralCreeps() return {} end
function Unit:GetNearbyTowers(r, enemy) return nearbyOf(self, r, enemy, function(u) return u._tower end) end
function Unit:GetNearbyBarracks() return {} end
function Unit:GetNearbyShrines() return {} end
function Unit:GetNearbyFillers() return {} end
function Unit:GetNearbyTrees() return {} end
function Unit:GetPlayer() return self._pid end
-- orders: recorded and applied by the stepper
local function rec(self, order, a, b)
    table.insert(MOCK.orders, { t = MOCK.t, unit = self._name, order = order, a = a, b = b })
    self._order = { kind = order, a = a, b = b, t = MOCK.t }
end
function Unit:Action_MoveToLocation(l) rec(self, "move", l); self._atkTarget = nil end
function Unit:Action_MoveDirectly(l) rec(self, "move", l); self._atkTarget = nil end
function Unit:Action_MovePath(p) rec(self, "move", p[#p]); self._atkTarget = nil end
function Unit:Action_AttackUnit(u, once) rec(self, "attack", u, once); self._atkTarget = u end
function Unit:Action_AttackMove(l) rec(self, "move", l); self._atkTarget = nil end
function Unit:Action_UseAbility(ab) rec(self, "cast", ab); self._atkTarget = nil end
function Unit:Action_UseAbilityOnEntity(ab, u) rec(self, "castT", ab, u) end
function Unit:Action_UseAbilityOnLocation(ab, l) rec(self, "castL", ab, l) end
function Unit:Action_UseAbilityOnTree(ab, t) rec(self, "castTree", ab, t) end
function Unit:Action_ClearActions() rec(self, "clear"); self._atkTarget = nil end
function Unit:Action_Delay() end
function Unit:Action_PurchaseItem(n) rec(self, "buy", n); return PURCHASE_ITEM_SUCCESS end
function Unit:ActionImmediate_PurchaseItem(n) rec(self, "buy", n); return PURCHASE_ITEM_SUCCESS end
function Unit:ActionImmediate_SwapItems(a, b) local x = self._items[a]; self._items[a] = self._items[b]; self._items[b] = x end
function Unit:ActionImmediate_SellItem() end
function Unit:ActionImmediate_DisassembleItem() end
function Unit:ActionImmediate_SetItemCombineLock() end
function Unit:ActionImmediate_Glyph() rec(self, "glyph") end
function Unit:ActionImmediate_Chat() end
function Unit:ActionImmediate_Ping() end
function Unit:ActionImmediate_Courier() return true end
function Unit:ActionImmediate_LevelAbility(n) local a = self._abilities[n]; if a then a._lvl = a._lvl + 1 end end
function Unit:ActionImmediate_Buyback() end
function Unit:Action_PickUpRune() end
function Unit:Action_PickUpItem() end
function Unit:Action_DropItem() end
function Unit:ActionPush_MoveToLocation(l) self:Action_MoveToLocation(l) end
function Unit:ActionQueue_MoveToLocation(l) self:Action_MoveToLocation(l) end
function Unit:ActionPush_UseAbility(a) self:Action_UseAbility(a) end
function Unit:ActionQueue_UseAbility(a) self:Action_UseAbility(a) end

---------------------------------------------------------------- globals
function GameTime() return MOCK.t end
function DotaTime() return MOCK.t - 90 end
function RealTime() return MOCK.t end
function GetGameState() return GAME_STATE_GAME_IN_PROGRESS end
function GetGameMode() return 11 end
function GetBot() return MOCK.bot end
function GetTeam() return MOCK.bot and MOCK.bot._team or TEAM_DIRE end
function GetOpposingTeam() return GetTeam() == TEAM_RADIANT and TEAM_DIRE or TEAM_RADIANT end
function GetUnitToUnitDistance(a, b) return (a._loc - b._loc):Length2D() end
function GetUnitToLocationDistance(a, l) return (a._loc - l):Length2D() end
function GetUnitToLocationDistanceSqr(a, l) local d = (a._loc - l):Length2D(); return d * d end
function RandomInt(a, b) return math.random(a, b) end
function RandomFloat(a, b) return a + (b - a) * math.random() end
function RandomVector(l) local a = math.random() * 2 * math.pi; return Vector(math.cos(a) * l, math.sin(a) * l, 0) end
function Clamp(x, a, b) return math.max(a, math.min(b, x)) end
function RemapVal(v, a, b, c, d) return c + (v - a) * (d - c) / (b - a) end
function RemapValClamped(v, a, b, c, d) return Clamp(RemapVal(v, a, b, c, d), math.min(c, d), math.max(c, d)) end
function GetTower(team, idx)
    for _, u in ipairs(MOCK.units) do if u._tower and u._team == team and u._towerIdx == idx and u:IsAlive() then return u end end
    return nil
end
function GetBarracks() return nil end
function GetAncient(team) return MOCK.NewUnit and nil end
function GetTeamPlayers(team) if team == GetTeam() then return { 1 } end return { 0 } end
function GetTeamMember(i) if i == 1 then return MOCK.bot end return nil end
function GetSelectedHeroName() return "npc_dota_hero_nevermore" end
function IsPlayerBot(pid) return pid == 1 end
function IsHeroAlive(pid) return true end
function GetHeroLevel(pid) return MOCK.bot and MOCK.bot._lvl or 1 end
function GetHeroKills() return 0 end
function GetHeroDeaths() return 0 end
function GetHeroLastSeenInfo(pid)
    local e = MOCK.enemy; if not e then return {} end
    return { { location = e:GetLocation(), time_since_seen = 0 } }
end
function GetUnitList(kind)
    local out = {}
    for _, u in ipairs(MOCK.units) do
        if u:IsAlive() and (kind == UNIT_LIST_ALL or (kind == UNIT_LIST_ENEMIES and u._team ~= GetTeam()) or (kind == UNIT_LIST_ALLIES and u._team == GetTeam())) then out[#out + 1] = u end
    end
    return out
end
function GetItemCost(n) return 100 end
function IsItemPurchasedFromSecretShop() return false end
function IsItemPurchasedFromSideShop() return false end
function GetItemStockCount() return 5 end
function GetNumCouriers() return 1 end
function GetCourier() return MOCK.courier end
function IsCourierAvailable() return true end
function GetCourierState() return COURIER_STATE_AT_BASE end
function GetGlyphCooldown() return 0 end
function GetLaneFrontLocation(team, lane, d) return Vector(-300, -300, 0) end
function GetLaneFrontAmount() return 0.5 end
function GetLocationAlongLane(lane, a) return Vector(-6000 + 12000 * a, -6000 + 12000 * a, 0) end
function GetAmountAlongLane() return { amount = 0.5, distance = 0 } end
function GetShopLocation(team, shop) return team == TEAM_RADIANT and Vector(-7000, -6500, 0) or Vector(7000, 6400, 0) end
function GetRuneSpawnLocation() return Vector(0, 0, 0) end
function GetRuneStatus() return 0 end
function GetTreeLocation() return Vector(5000, 5000, 0) end
function IsLocationPassable() return true end
function IsLocationVisible() return true end
function GetHeightLevel() return 1 end
function GetLinearProjectiles() return {} end
function GetIncomingTeleports() return {} end
function GetDroppedItemList() return {} end
function GetNeutralSpawners() return {} end
function GetAvoidanceZones() return {} end
function GetScriptDirectory() return "bots" end
function GetWorldBounds() return { -8000, -8000, 8000, 8000 } end
function DebugDrawText() end
function DebugDrawLine() end
function DebugDrawCircle() end
function GetHeroPickState() return 0 end
function GetPushLaneDesire() return 0 end
function GetDefendLaneDesire() return 0 end
function GetFarmLaneDesire() return 0 end
function GetRoamDesire() return 0 end
function GetRoshanDesire() return 0 end
function GetGameTime() return MOCK.t end
function GetLaneFrontLocationAbsolute() return Vector(0, 0, 0) end

---------------------------------------------------------------- world builder / stepper
local SF_ABILS = { "nevermore_shadowraze1", "nevermore_shadowraze2", "nevermore_shadowraze3", "nevermore_necromastery", "nevermore_dark_lord", "nevermore_requiem" }
function MOCK.NewSF(team, loc, o)
    o = o or {}
    local u = MOCK.NewUnit({ name = "npc_dota_hero_nevermore", team = team, loc = loc, hp = o.hp or 640, mhp = o.mhp or 640, mp = o.mp or 300, mmp = o.mmp or 300, lvl = o.lvl or 3, hero = true, range = 500, dmg = o.dmg or 55, facing = o.facing or 0 })
    u._abilSlots = {}
    for i, n in ipairs(SF_ABILS) do
        local lvl = (i <= 3) and (o.raze or 1) or ((i == 4) and (o.necro or 1) or 0)
        local a = MOCK.NewAbility(n, u, lvl, { _range = 0 })
        u._abilities[n] = a; u._abilSlots[i - 1] = a
    end
    local slot = 0
    for _, it in ipairs(o.items or {}) do
        local a = MOCK.NewAbility(it[1], u, 1, { _isItem = true, _charges = it[2] or 0, _mana = 0 })
        u._items[slot] = a; slot = slot + 1
    end
    u._mods.modifier_nevermore_necromastery = { idx = 1, stacks = o.souls or 6, until_ = 1e9 }
    return u
end
function MOCK.Step(dt)
    MOCK.t = MOCK.t + dt
    for _, u in ipairs(MOCK.units) do
        local o = u._order
        if not (o and o.kind == "attack") then u._swingStart = nil end
        if u:IsAlive() and o then
            if o.kind == "move" and o.a then
                local d = o.a - u._loc
                local l = d:Length2D()
                if l > 1 then
                    local st = math.min(l, u._speed * dt)
                    u._vel = d:Normalized() * u._speed
                    u._loc = u._loc + d:Normalized() * st
                    u._facing = math.deg(math.atan2(d.y, d.x)) % 360
                else u._vel = Vector(0, 0, 0) end
            elseif o.kind == "cast" and o.a then
                local a = o.a
                if a._owner == u and MOCK.t >= a._cdEnd then
                    a._cdEnd = MOCK.t + (a._isItem and 1 or 9); u._mp = math.max(0, u._mp - (a._mana or 75))
                end
                u._order = nil
            elseif o.kind == "attack" and o.a then
                -- like the engine: an out-of-range attack order walks to the target first (range + ~50 hull slack)
                local d = o.a._loc - u._loc
                local l = d:Length2D()
                local r = (u.GetAttackRange and u:GetAttackRange() or 100) + 50
                if l > r then
                    local st = math.min(l - r + 1, u._speed * dt)
                    u._vel = d:Normalized() * u._speed
                    u._loc = u._loc + d:Normalized() * st
                    u._facing = math.deg(math.atan2(d.y, d.x)) % 360
                else
                    -- engine semantics: the swing starts once the attack is off cooldown, GetLastAttackTime is
                    -- stamped at the launch (attack point later); a swing interrupted by another order is lost
                    u._vel = Vector(0, 0, 0)
                    local spa, ap = u:GetSecondsPerAttack(), u:GetAttackPoint()
                    if not u._swingStart or u._swingTarget ~= o.a then
                        if MOCK.t >= u._lastAttack + spa - ap then u._swingStart = MOCK.t; u._swingTarget = o.a end
                    elseif MOCK.t >= u._swingStart + ap - 1e-6 then
                        u._lastAttack = MOCK.t; u._swingStart = nil
                        if MOCK.onLaunch then MOCK.onLaunch(u, o.a) end
                    end
                end
            end
        end
    end
end
return MOCK
