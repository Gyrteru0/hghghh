-- scripts/vscripts/bots/item_purchase_nevermore.lua

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local K = require("bots/nevermore/combat")

local P = require("bots/nevermore/positioning")

local PurchaseTable = {
    "item_ward_observer",
    "item_tango",
    "item_branches",
    "item_circlet",
    "item_circlet",
    "item_enchanted_mango",
    "item_faerie_fire",

    -- Immortal 1v1 SF Build (`v3.9.0`, `auto-20261022-2237` `-45 MS` & `-565g` Consumable Drain Fix):
    -- 1st Bracer (`+5 STR, +3 DMG, +1 HP/s` @ ~1:35) -> IMMEDIATE `Boots of Speed` (`350 MS` @ ~2:45 — eliminates
    -- the deadly `305 vs 350 MS` run-down death window & coil dodge failure!) -> `2nd Bracer` -> `Magic Stick` (`+15 HP/MP` per SF coil!)
    "item_gauntlets", "item_recipe_bracer",
    "item_boots",
    "item_gauntlets", "item_recipe_bracer",
    "item_magic_stick",

    -- Rush Power Treads with Belt of Strength FIRST (`+132 HP` in lane!) then Gloves of Haste
    "item_belt_of_strength",
    "item_gloves",

    "item_blade_of_alacrity", "item_belt_of_strength", "item_recipe_dragon_lance",

    "item_staff_of_wizardry", "item_robe", "item_recipe_kaya"
}

-- Per-bot purchase state (keyed by player ID)
local BotPurchaseState = {}


-- Gets or creates the purchase state for a specific bot
local function GetBotState(bot)
    local pid = bot:GetPlayerID()
    if pid == nil or pid < 0 then
        return nil
    end

    if not BotPurchaseState[pid] then
        BotPurchaseState[pid] = {
            currentItemIndex = 1,
            lastSalveBuyTime = -1000,
            extraMango = 0, extraSalve = 0,
            recoveryWindowAt = -1000, recoverySpent = 0, lastRecoveryBuy = -1000,
            lastShopAttempt = -1000,
            bought5MinWard = false,
            lastCourierCallTime = -1000,
            resolvedCourierSlot = nil,
            trySlotOffset = 0,
        }
    end

    return BotPurchaseState[pid]
end

function ItemPurchaseThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    local state = GetBotState(bot)
    if not state then return end
    if GameTime() < state.lastShopAttempt then
        state.lastShopAttempt = -1000
        state.lastCourierCallTime = -1000
        state.lastSalveBuyTime = -1000
        state.recoveryWindowAt = GameTime()
        state.resolvedCourierSlot = nil
        state.trySlotOffset = 0
    end
    if GameTime() - state.lastShopAttempt < 0.25 then return end
    state.lastShopAttempt = GameTime()
    local gold = bot:GetGold()

    -- 0. WARD AT 4:30 (270 seconds) — never buy a duplicate if starting ward is still in inventory!
    if DotaTime() >= 270 and not state.bought5MinWard then
        local alreadyHasWard = false
        for s = 0, 14 do
            local it = bot:GetItemInSlot(s)
            if it and it:GetName() == "item_ward_observer" then alreadyHasWard = true; break end
        end
        if alreadyHasWard then
            state.bought5MinWard = true
        else
            bot:ActionImmediate_PurchaseItem("item_ward_observer")
            state.bought5MinWard = true
        end
    end

    -- Inventory + stash + dedicated TP slot + team courier: do not duplicate an item in delivery.
    local function owns(name)
        if name == "item_tpscroll" or name == "item_teleport_scroll" then
            return U.HasAnyTPScroll(bot)
        end
        for i = 0, 20 do
            local ok, it = pcall(bot.GetItemInSlot, bot, i)
            if ok and it and it:GetName() == name then return true end
        end
        local nCour = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
        for i = 0, nCour - 1 do
            local courier = GetCourier(i)
            if courier and not courier:IsNull() then
                local cPid = courier.GetPlayerID and courier:GetPlayerID() or -1
                local mine = (cPid == bot:GetPlayerID())
                    or (state.resolvedCourierSlot ~= nil and i == state.resolvedCourierSlot)
                    or (nCour == 1 and (not courier.GetTeam or courier:GetTeam() == bot:GetTeam()))
                if mine then
                    for slot = 0, 8 do
                        local ok, it = pcall(courier.GetItemInSlot, courier, slot)
                        if ok and it and it:GetName() == name then return true end
                    end
                end
            end
        end
        return false
    end

    -- Unconditional Pro Lane Reset Priority:
    -- NEVER sit below 66% HP (`missingHP >= 320`) in lane without a Healing Salve just because the
    -- enemy hero died (e.g. post-First-Blood `104/1034 HP` with `238g`) or stepped into night fog!
    local now = GameTime()
    local cfg = C.CONSUMABLE_BUY or {}
    if now - state.recoveryWindowAt >= (cfg.RECOVERY_WINDOW or 150) then
        state.recoveryWindowAt = now
        state.recoverySpent = 0
    end
    local fntLoc = P.GetFountain(bot)
    local nearFountain = bot:HasModifier("modifier_fountain_aura_buff")
        or (fntLoc and GetUnitToLocationDistance(bot, fntLoc) <= 2000)
    local missingHP = bot:GetMaxHealth() - bot:GetHealth()
    local hpPctNow = bot:GetHealth() / math.max(1, bot:GetMaxHealth())

    local recoveryBought = false
    -- Never buy consumables in death agony (`auto-20261022-2237` `05:48.17` bug: bought `Flask #5` at `72 HP`
    -- `0.067s` before dying, starving Boots by `-100g` and sitting unused after fountain respawn!).
    local closeEnemy = nil
    local nearbyH = bot.GetNearbyHeroes and bot:GetNearbyHeroes(850, true, BOT_MODE_NONE) or nil
    if nearbyH and nearbyH[1] then closeEnemy = nearbyH[1] end
    -- v5.1: a salve bought into the stash is never wasted (the courier brings it after the danger, the respawn keeps
    -- it); only real death agony blocks a buy. v5.0 blocked at <=195 HP with ANY enemy within 850 - exactly the
    -- 4:49-5:45 G4 limbo where the human healed with salve+mango+bracer trick and the bot did not.
    local agonyHp = cfg.AGONY_HP or 110
    local incomingLethalOrDying = (bot:GetHealth() <= agonyHp
        and ((bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(1.5))
            or (bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.5))))
    local hasBootsOwned = owns("item_boots") or owns("item_power_treads")
    -- Unified time-scaled Salve cap (`A17` + `0050` `08:15` 60s walk-home fix):
    -- `<= 1` pre-Boots, `2` through 5:00, and `+1` every 3.5 minutes after 5:00 (max `4`) so SF NEVER abandons Mid T1 on foot!
    local dtimeNow = DotaTime()
    local maxExtraSalves = hasBootsOwned
        and math.min(6, 3 + math.floor(math.max(0, dtimeNow - 300) / 180))
        or (cfg.PRE_BOOTS_SALVES or 3)
    local maxExtraMangoes = hasBootsOwned
        and math.min(5, 3 + math.floor(math.max(0, dtimeNow - 360) / 200))
        or (cfg.PRE_BOOTS_MANGOES or 3)
    if dtimeNow > 0 and not nearFountain and not incomingLethalOrDying then
        -- Priority A: Disciplined Healing Salve (`<= 1` pre-Boots, time-scaled post-Boots)
        local salveCD = math.max(cfg.RECOVERY_COOLDOWN or 22, cfg.SALVE_CD or 35)
        if state.extraSalve < maxExtraSalves
            and (missingHP >= 340 or hpPctNow <= 0.48)
            and not bot:HasModifier("modifier_flask_healing")
            and not bot:HasModifier("modifier_tango_heal")
            and not owns("item_flask")
            and now - state.lastSalveBuyTime >= salveCD then
            local cost = GetItemCost("item_flask")
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_flask") > 0
            if inStock and gold >= cost then
                local result = bot:ActionImmediate_PurchaseItem("item_flask")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cost
                    state.lastRecoveryBuy = now
                    state.lastSalveBuyTime = now
                    state.extraSalve = state.extraSalve + 1
                    gold = bot:GetGold()
                end
            end
        end

        -- Priority B: Urgent Enchanted Mango replenishment (`<= 1` pre-Boots, `<= maxExtraMangoes` total!)
        -- v5.1: no build-index gate (the human ate 4 mangoes 5:43-7:46 while the bot sat at 10-64 mana and walked
        -- home because a TP needs 75); mana < 110 = less than one raze + TP reserve
        if not recoveryBought
            and state.extraMango < maxExtraMangoes
            and now - state.lastRecoveryBuy >= (cfg.MANGO_CD or 35)
            and (K.MyManaBudget(bot, true) < 125 or bot:GetMana() < 110)
            and (bot:GetMaxMana() - bot:GetMana()) >= 115
            and hpPctNow >= 0.30
            and not owns("item_enchanted_mango") then
            local cost = GetItemCost("item_enchanted_mango")
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_enchanted_mango") > 0
            if inStock and state.recoverySpent + cost <= (cfg.RECOVERY_BUDGET or 340) and gold >= cost then
                local result = bot:ActionImmediate_PurchaseItem("item_enchanted_mango")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cost
                    state.lastRecoveryBuy = now
                    state.extraMango = state.extraMango + 1
                    gold = bot:GetGold()
                end
            end
        end
    end

    -- Main build has priority, especially both bracers. Advance only on success.
    local nextItem = PurchaseTable[state.currentItemIndex]
    if nextItem and gold >= GetItemCost(nextItem) then
        local result = bot:ActionImmediate_PurchaseItem(nextItem)
        if result == (PURCHASE_ITEM_SUCCESS or 0) then
            state.currentItemIndex = state.currentItemIndex + 1
        end
        gold = bot:GetGold()
    end

    local early = state.currentItemIndex <= 11 -- both bracers not yet ordered
    local interval = early and 120 or 90
    if not recoveryBought and not incomingLethalOrDying and dtimeNow > 0 and GameTime() - state.lastSalveBuyTime >= interval
        and not bot:HasModifier("modifier_fountain_aura_buff") then
        local hp = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
        local name
        if hp < 0.35 and not bot:HasModifier("modifier_flask_healing")
            and state.extraSalve < maxExtraSalves then
            name = "item_flask"
        elseif bot:GetMana() < 75 and hp >= 0.50 and state.extraMango < maxExtraMangoes then
            name = "item_enchanted_mango"
        end
        local nextBuild = PurchaseTable[state.currentItemIndex]
        local reserve = math.max(210, nextBuild and GetItemCost(nextBuild) or 0)
        if name and not owns(name) and gold >= GetItemCost(name) + reserve then
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount(name) > 0
            if inStock then
                local result = bot:ActionImmediate_PurchaseItem(name)
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    state.lastSalveBuyTime = GameTime()
                    if name == "item_flask" then state.extraSalve = state.extraSalve + 1
                    else state.extraMango = state.extraMango + 1 end
                end
            end
        end
    end

    -- 3. SMART COURIER (Rolled back cleanly to `v3.9.0` pre-prestage behavior: ZERO custom spot pre-positioning,
    --    ZERO pre-horn movement, ONLY standard `COURIER_ACTION_TAKE_AND_TRANSFER_ITEMS` when Stash holds items!)
    if GameTime() - state.lastCourierCallTime > 0.35 then
        local pid = bot:GetPlayerID()
        if pid < 0 then return end

        local numCouriers = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
        if numCouriers <= 0 then return end

        local myCourier = nil
        for i = 0, numCouriers - 1 do
            local c = GetCourier(i)
            if c and not c:IsNull() and c:GetPlayerID() == pid then
                myCourier = c
                state.resolvedCourierSlot = i
                break
            end
        end

        -- When Source 2 `c:GetPlayerID()` is `-1`, check whether any courier already picked up our delivery first,
        -- otherwise start at our team player index (`0` in 1v1 / slot `k-1` in 5v5) and advance only if Stash remains full!
        if not myCourier then
            if state.resolvedCourierSlot == nil then
                for i = 0, numCouriers - 1 do
                    local c = GetCourier(i)
                    if c and not c:IsNull() and (not c.GetTeam or c:GetTeam() == bot:GetTeam()) then
                        if GetCourierState(c) == COURIER_STATE_DELIVERING_ITEMS then
                            state.resolvedCourierSlot = i
                            break
                        end
                    end
                end
            end
            if state.resolvedCourierSlot ~= nil and state.resolvedCourierSlot < numCouriers then
                local cr = GetCourier(state.resolvedCourierSlot)
                if cr and not cr:IsNull() then
                    myCourier = cr
                end
            end
        end

        if not myCourier then
            local baseIdx = 0
            if type(GetTeamPlayers) == "function" then
                local okT, teamPlayers = pcall(GetTeamPlayers, bot:GetTeam())
                if okT and type(teamPlayers) == "table" then
                    for index, id in pairs(teamPlayers) do
                        if id == pid then
                            baseIdx = index - 1
                            break
                        end
                    end
                end
            end
            local slotTry = (baseIdx + (state.trySlotOffset or 0)) % numCouriers
            local cTry = GetCourier(slotTry)
            if cTry and not cTry:IsNull() and (not cTry.GetTeam or cTry:GetTeam() == bot:GetTeam()) then
                myCourier = cTry
            end
            if not myCourier then
                local c0 = GetCourier(0)
                if c0 and not c0:IsNull() then myCourier = c0 end
            end
        end

        if myCourier and not myCourier:IsNull() then
            local state_c = GetCourierState(myCourier)
            local stashItemsCount = 0
            local onlyWardInStash = true
            local urgentCourier = false
            local stashHasFlask = false
            local courierHasFlask = false

            for i = 9, 14 do
                local item = bot:GetItemInSlot(i)
                if item then
                    stashItemsCount = stashItemsCount + 1
                    local nm = item:GetName()
                    if nm ~= "item_ward_observer" then
                        onlyWardInStash = false
                    end
                    if nm == "item_flask" then stashHasFlask = true end
                    if nm == "item_flask" or nm == "item_boots" or nm == "item_power_treads" or nm == "item_enchanted_mango" then
                        urgentCourier = true
                    end
                    if nm == "item_bracer" or nm == "item_boots" or nm == "item_power_treads" or nm == "item_magic_stick" then
                        stashHasFlask = true
                    end
                end
            end

            local courierItemsCount = 0
            for slot = 0, 8 do
                local okI, cItem = pcall(myCourier.GetItemInSlot, myCourier, slot)
                if okI and cItem then
                    courierItemsCount = courierItemsCount + 1
                    local nm = cItem:GetName()
                    if nm == "item_flask" then courierHasFlask = true end
                    if nm == "item_flask" or nm == "item_boots" or nm == "item_power_treads" or nm == "item_enchanted_mango" then
                        urgentCourier = true
                    end
                end
            end

            local hasStash = stashItemsCount > 0 or (bot.GetStashValue and (bot:GetStashValue() or 0) > 0)
            local hasOnCourier = courierItemsCount > 0 or (bot.GetCourierValue and (bot:GetCourierValue() or 0) > 0)
            local courierDistFnt = fntLoc and GetUnitToLocationDistance(myCourier, fntLoc) or math.huge
            local courierNearBase = courierDistFnt <= 2200
            local onlySoloGauntlets = (stashItemsCount == 1) and not urgentCourier and (DotaTime() < 360)
                and (bot:GetItemInSlot(9) and bot:GetItemInSlot(9):GetName() == "item_gauntlets")
            local holdBatch = (stashItemsCount == 1 and onlyWardInStash) or onlySoloGauntlets
            local needFlaskTurnback = stashHasFlask and not courierHasFlask
                and not U.HasItem(bot, "item_flask") and not bot:HasModifier("modifier_flask_healing")
                and courierDistFnt <= 4800
            local needShortBatchTurnback = courierNearBase and state_c == COURIER_STATE_DELIVERING_ITEMS
            if hasStash and not holdBatch then
                if state_c == COURIER_STATE_IDLE or state_c == COURIER_STATE_AT_BASE
                    or (state_c == COURIER_STATE_RETURNING_TO_BASE and courierNearBase)
                    or needFlaskTurnback or needShortBatchTurnback then
                    bot:ActionImmediate_Courier(myCourier, COURIER_ACTION_TAKE_AND_TRANSFER_ITEMS)
                    if urgentCourier and COURIER_ACTION_BURST then
                        pcall(bot.ActionImmediate_Courier, bot, myCourier, COURIER_ACTION_BURST)
                    end
                    if state.resolvedCourierSlot == nil and numCouriers > 1 then
                        state.trySlotOffset = ((state.trySlotOffset or 0) + 1) % numCouriers
                    end
                    state.lastCourierCallTime = GameTime()
                end
            elseif hasOnCourier and (state_c == COURIER_STATE_IDLE or state_c == COURIER_STATE_AT_BASE
                or state_c == COURIER_STATE_RETURNING_TO_BASE) then
                bot:ActionImmediate_Courier(myCourier, COURIER_ACTION_TRANSFER_ITEMS)
                if urgentCourier and COURIER_ACTION_BURST then
                    pcall(bot.ActionImmediate_Courier, bot, myCourier, COURIER_ACTION_BURST)
                end
                state.lastCourierCallTime = GameTime()
            end
        end
    end
end
