-- Original IW7 adapter, not retail BO3 source/art. Private opt-in prototype.
-- Actual IW7 data models stay authoritative; no gameplay/model writes.
if rawget(_G, "BO3ZombiesHUD") then return end
local state = { version = "0.3.0", hooks = {}, failures = 0, closed = false, factoryApplied = 0 }
state.instance = (string.gsub(tostring(state), "[^%w]", "")):sub(1, 40)
state.roots = setmetatable({}, {__mode = "k"})
-- Values are weak too: each live owner's installed wrapper retains its hook.
-- In Lua5.1 a weak key alone would retain old roots through the hook closure.
state.refreshHooks = setmetatable({}, {__mode = "kv"})
state.nextRoot = 0
BO3ZombiesHUD = state
local pending_nodes
local function remember(node)
    if pending_nodes then pending_nodes[#pending_nodes + 1] = node end
    return node
end
local scale = function(v) return v * (_1080p or 1) end
local profile_payload = "set bo3_zombies_hud_enable 1\nset bo3_zombies_hud_private 1\n"
local function configured()
    -- Native startup +set defers unknown dvars until registration. This exact
    -- recipient-owned, snapshotted file is the explicit private opt-in source.
    if not io or not io.readfile then return false end
    local ok, value = pcall(io.readfile, "iw7-mod/bo3_zombies_hud_lab.cfg")
    return ok and value == profile_payload
end
local function opted_in()
    return configured() and not Engine.InFrontend()
        and Engine.IsAliensMode and Engine.IsAliensMode()
end
local function token(value)
    local encoded = (string.gsub(tostring(value), "[^%w_.%-]", "?")):sub(1, 40)
    return encoded == "" and "empty" or encoded
end
local function emit(key, value)
    state.messages = state.messages or {}
    if state.messages[key] == value then return end
    state.messages[key] = value
    if not string.find(value, " pixels=", 1, true) then value = value .. " pixels=unverified" end
    print("[BO3 HUD] " .. value .. " instance=" .. state.instance)
end
local function gate_trace()
    local function raw(name)
        local ok, value = pcall(function() return Engine.GetDvarString(name) end)
        return ok and token(value) or "error", ok and type(value) or "error"
    end
    local enable, et = raw("bo3_zombies_hud_enable")
    local private, pt = raw("bo3_zombies_hud_private")
    emit("gate", "gate version=" .. state.version .. " profile=" .. (configured() and "1" or "0")
        .. " frontend=" .. (Engine.InFrontend() and "1" or "0")
        .. " cp=" .. (Engine.IsAliensMode and Engine.IsAliensMode() and "1" or "0")
        .. " enable=" .. enable .. " enable_type=" .. et .. " private=" .. private .. " private_type=" .. pt)
end
local function source(path)
    local value = DataSources
    for key in string.gmatch(path, "[^.]+") do
        value = value and value[key]
    end
    assert(value and value.GetModel and value.GetValue, "Missing IW7 model: " .. path)
    return value
end
local function controller_index(menu, args)
    local index = args and args.controllerIndex
    if index == nil and menu and menu.getRootController then index = menu:getRootController() end
    assert(type(index) == "number" and index >= 0 and index <= 3, "Actual local controller required")
    return index
end
local function rect(element, left, right, top, bottom)
    element:SetAnchorsAndPosition(0, 1, 0, 1, scale(left), scale(right), scale(top), scale(bottom))
end
local function panel(id, width, height)
    local result = remember(LUI.UIElement.new())
    result.id = id
    rect(result, 0, width, 0, height)
    return result
end
local function text(parent, id, size, left, right, top, bottom, color)
    local item = remember(LUI.UIText.new())
    item.id = id
    item:SetFont(FONTS.GetFont(FONTS.MainBold.File))
    item:SetFontSize(scale(size))
    item:SetAlignment(LUI.Alignment.Left)
    item:SetRGBFromInt(color or 0xF5F1E7, 0)
    rect(item, left, right, top, bottom)
    parent:addElement(item)
    return item
end
local function bar(parent, id, left, right, top, bottom, color)
    local item = remember(LUI.UIImage.new())
    item.id = id
    item:setImage(RegisterMaterial("white"), 0)
    item:SetRGBFromInt(color, 0)
    rect(item, left, right, top, bottom)
    parent:addElement(item)
    return item
end
local function bind_text(element, model, index, transform)
    local function update()
        local value = model:GetValue(index)
        element:setText(value == nil and "" or (transform and transform(value) or tostring(value)))
    end
    element:SubscribeToModel(model:GetModel(index), update)
    update()
end
local function build_wave(menu, args)
    local index = controller_index(menu, args)
    local model = source("inGame.CP.zombies.waveNumber")
    local self = panel("WaveNumber", 144, 110)
    self.__bo3HudReplacement = "WaveNumber"
    local number = text(self, "BO3RoundNumber", 60, 22, 144, 20, 84, 0xB83226)
    self.BO3RoundNumber = number
    bar(self, "BO3RoundRule", 0, 7, 24, 88, 0xB83226)
    bind_text(number, model, index)
    return self
end
local function build_ammo(menu, args)
    local index = controller_index(menu, args)
    local right = source("inGame.player.currentWeapon.clipAmmoRightDisplay")
    local left = source("inGame.player.currentWeapon.clipAmmoLeftDisplay")
    local reserve = source("inGame.player.currentWeapon.stockAmmoDisplay")
    local stock_ammo = source("inGame.player.currentWeapon.stockAmmo")
    local name = source("inGame.player.currentWeapon.displayNameMultiline")
    local ammo_alpha = source("inGame.player.currentWeapon.ammoInfoAlpha")
    local reserve_alpha = source("inGame.player.currentWeapon.ammoReserveAlpha")
    local dual = source("inGame.player.currentWeapon.isDualWielding")
    local melee = source("inGame.player.currentWeapon.isMeleeWeapon")
    local self = panel("weaponinfoZM", 340, 116)
    self.__bo3HudReplacement = "weaponinfoZM"
    local clip = text(self, "BO3ClipRight", 54, 122, 226, 12, 70)
    local clip_left = text(self, "BO3ClipLeft", 32, 20, 118, 26, 66)
    local stock = text(self, "BO3Reserve", 25, 248, 336, 36, 66)
    local title = text(self, "BO3WeaponName", 18, 20, 336, 82, 110)
    local divider = bar(self, "BO3AmmoRule", 234, 237, 24, 70, 0xA49E8B)
    clip:BindAlphaToModel(ammo_alpha:GetModel(index))
    stock:BindAlphaToModel(reserve_alpha:GetModel(index))
    divider:BindAlphaToModel(ammo_alpha:GetModel(index))
    bind_text(clip, right, index)
    bind_text(clip_left, left, index)
    bind_text(stock, reserve, index)
    assert(SWATCHES and SWATCHES.HUD and SWATCHES.HUD.warning, "Actual reserve warning color required")
    local function update_stock_color()
        local value = stock_ammo:GetValue(index)
        if type(value) ~= "number" then return end
        if value <= 0 then stock:SetRGBFromTable(SWATCHES.HUD.warning, 0)
        else stock:SetRGBFromInt(12566463, 0) end
    end
    stock:SubscribeToModel(stock_ammo:GetModel(index), update_stock_color)
    update_stock_color()
    bind_text(title, name, index, function(value) return Engine.Localize(value) end)
    local weapon = DataSources.inGame.player.currentWeapon
    if weapon.altModeDisplayName and weapon.altModeDisplayName.GetModel and weapon.altModeDisplayName.GetValue then
        local alt = text(self, "BO3AltMode", 14, 20, 336, 110, 130)
        bind_text(alt, weapon.altModeDisplayName, index)
    end
    local function update_left()
        -- An unresolved classification is not evidence of a usable akimbo gun.
        clip_left:SetAlpha(dual:GetValue(index) == true and melee:GetValue(index) == false and 1 or 0, 0)
    end
    self:SubscribeToModel(dual:GetModel(index), update_left)
    self:SubscribeToModel(melee:GetModel(index), update_left)
    update_left()
    -- Parent ZomWeaponInfo retains offhands, crafted weapon, unlimited ammo,
    -- Mule Munchies and their authoritative visibility/charge models.
    return self
end
local function build_perk(menu, args)
    local index = controller_index(menu, args)
    local self = panel("CPPerkIcon", 46, 46)
    self.__bo3HudReplacement = "CPPerkIcon"
    local icon = remember(LUI.UIImage.new())
    icon.id = "PerkIcon"
    rect(icon, 3, 43, 3, 43)
    icon:SubscribeToModelThroughElement(self, "icon", function()
        local data = self:GetDataSource()
        local value = data and data.icon and data.icon:GetValue(index)
        if value and value ~= "" then
            icon:setImage(RegisterMaterial(value), 0)
            icon:SetAlpha(1, 0)
        else icon:SetAlpha(0, 0) end
    end)
    self:addElement(icon)
    self.PerkIcon = icon
    return self
end
local function style_player(self)
    -- Keep original image/character/status, cash, Rave/quest/inventory callbacks.
    -- Never replace the complete player container and lose its quest children.
    assert(self and self.PlayerIcon and self.PlayerCash, "Actual IW7 player fields required")
    if not self.__bo3PortraitStyled then
        if self.box then self:removeElement(self.box) end
        if self.dollarSign then self:removeElement(self.dollarSign) end
        self.__bo3PortraitStyled = true
    end
    self.PlayerIcon:SetYRotation(0, 0)
    self.PlayerIcon:SetZRotation(0, 0)
    self.PlayerIcon:SetScale(0, 0)
    rect(self.PlayerIcon, 0, 72, 0, 110)
    self.PlayerCash:SetScale(0, 0)
    self.PlayerCash:SetYRotation(0, 0); self.PlayerCash:SetZRotation(0, 0)
    self.PlayerCash:SetFontSize(scale(38))
    self.PlayerCash:SetRGBFromInt(0xF5F1E7, 0)
    rect(self.PlayerCash, 92, 340, 40, 82)
    return self
end
local function adapt_player(original, menu, args)
    return style_player(remember(original(menu, args)))
end
local function adapt_bottom(original, menu, args)
    local self = remember(original(menu, args))
    assert(self and self.ZomWeaponInfo, "Actual IW7 ammo container required")
    self.ZomWeaponInfo:SetYRotation(0, 0)
    self.ZomWeaponInfo:SetZRotation(0, 0)
    self.ZomWeaponInfo:SetAnchorsAndPosition(1, 0, 1, 0, scale(-560), scale(-182), scale(-210), scale(-48))
    -- Retain card/charge/selection callbacks; give the entire deck a separate
    -- upper-right zone instead of letting its demon/fan cover ammo below.
    if self.FateCardWidget then
        self.FateCardWidget:SetYRotation(0, 0); self.FateCardWidget:SetZRotation(0, 0)
        -- The retail fan extends to 588.5, beyond its declared 389 height.
        self.FateCardWidget:SetAnchorsAndPosition(1, 0, 1, 0, scale(-530), scale(-277), scale(-860), scale(-471))
    end
    return self
end
local function unwrap(node) return node and (node._widget or node) end
local function style_ammo(self)
    if self.__bo3HudReplacement ~= "weaponinfoZM" then
        assert(self.TextRightClipAmmo and self.TextLeftClipAmmo and self.TextStockAmmo, "Actual ammo leaves required")
        for _, entry in ipairs({
            {self.TextRightClipAmmo, 54, 122, 226, 12, 70},
            {self.TextLeftClipAmmo, 32, 20, 118, 26, 66},
            {self.TextStockAmmo, 25, 248, 336, 36, 66}
        }) do
            entry[1]:SetFont(FONTS.GetFont(FONTS.MainBold.File))
            entry[1]:SetFontSize(scale(entry[2]))
            -- Retail NoStockAmmo/HasStockAmmo owns reserve warning colors.
            if entry[1] ~= self.TextStockAmmo then entry[1]:SetRGBFromInt(0xF5F1E7, 0) end
            rect(entry[1], entry[3], entry[4], entry[5], entry[6])
        end
        if not self.__bo3AmmoStyled then
            if self.box then self:removeElement(self.box) end
            if self.bar then self:removeElement(self.bar) end
            bar(self, "BO3AmmoRule", 234, 237, 24, 70, 0xA49E8B)
            self.__bo3AmmoStyled = true
        end
        local description = self.weaponDescriptionZM
        if description and description.TextWeaponName then
            rect(description, 20, 336, 82, 130)
            description.TextWeaponName:SetFontSize(scale(18))
            rect(description.TextWeaponName, 0, 316, 0, 28)
            if description.TextAltMode then
                description.TextAltMode:SetFontSize(scale(14))
                rect(description.TextAltMode, 0, 316, 28, 48)
            end
        end
    end
    -- Above this leaf, original ability/crafted/Mule/unlimited state stays live.
    rect(self, 20, 360, 44, 160)
end
local function style_wave(self)
    if self.__bo3HudReplacement ~= "WaveNumber" then
        assert(self.waveNum, "Actual round text required")
        if not self.__bo3RoundStyled then
            for _, key in ipairs({"clapboard", "clapboardExtention", "Scene"}) do
                if self[key] then self:removeElement(self[key]) end
            end
            bar(self, "BO3RoundRule", 0, 7, 24, 88, 0xB83226)
            self.__bo3RoundStyled = true
        end
        self.waveNum:SetRGBFromInt(0xB83226, 0)
        self.waveNum:SetFontSize(scale(60))
        rect(self.waveNum, 22, 144, 20, 84)
    end
    self:SetYRotation(0, 0); self:SetZRotation(0, 0)
    self:SetAnchorsAndPosition(0, 1, 1, 0, scale(420), scale(575), scale(-168), scale(-56))
end
local function walk_leaves(parent, apply)
    local visited = 0
    local function visit(node, depth)
        assert(depth <= 5 and visited < 128, "HUD leaf traversal exceeds its source bound")
        visited = visited + 1
        apply(node)
        if not node.getFirstChild then return end
        local child = node:getFirstChild()
        while child do
            local next_child = child:getNextSibling()
            visit(child, depth + 1); child = next_child
        end
    end
    visit(parent, 0)
end
local function style_perks(list)
    assert(list and list.getFirstChild, "Actual perk list required")
    local icons = 0
    walk_leaves(list, function(child)
        if child.PerkIcon then
            assert(icons < 16, "Perk icon count exceeds the stock player bound")
            rect(child, 0, 46, 0, 46); rect(child.PerkIcon, 3, 43, 3, 43)
            icons = icons + 1
        end
    end)
    return icons
end
local function reparent(leaf, parent)
    local previous = leaf:getParent()
    if previous == parent then return end
    if previous then previous:removeElement(leaf) end
    parent:addElement(leaf)
end
local function speaker(parent, id)
    local icon = LUI.UIImage.new(); icon.id = id; icon:SetAlpha(0, 0)
    parent:addElement(icon); return icon
end
local function mic(icon, data)
    if not data or type(data.isMicOn) ~= "boolean" or type(data.isMuted) ~= "boolean" then icon:SetAlpha(0, 0);return end
    icon:setImage(RegisterMaterial(data.isMuted and "scoreboard_mic_mute" or "scoreboard_mic_talk"), 0)
    icon:SetAlpha((data.isMicOn or data.isMuted) and 1 or 0, 0)
end
local function current_client()
    if not Game or type(Game.IsSpectating) ~= "function" then return nil end
    local ok, target = pcall(function()
        return Game.IsSpectating() and Game.GetPlayerstateClientnum() or Game.GetPlayerClientnum()
    end)
    return ok and target or nil
end
local function client_data(client)
    if client == nil or not Game or type(Game.GetCPNumScoreboardPlayers) ~= "function"
        or type(Game.GetCPScoreboardRowData) ~= "function" then return nil end
    local ok, count = pcall(Game.GetCPNumScoreboardPlayers)
    if not ok or type(count) ~= "number" or count < 0 or count > 4 or count ~= math.floor(count) then return nil end
    -- The complete scoreboard row owns mic flags; the filtered CP cash row
    -- remains untouched and owns its currency, portrait/status and identity.
    for i = 0, count - 1 do
        local got, data = pcall(Game.GetCPScoreboardRowData, i)
        if got and type(data) == "table" and data.clientNum == client then return data end
    end
end
local function style_teamrow(row)
    if not (row.PlayerImage and row.PlayerName and row.PlayerCash) then return end
    row:SetYRotation(0, 0); row:SetZRotation(0, 0)
    row.PlayerImage:SetScale(0, 0); rect(row.PlayerImage, 0, 40, 3, 47)
    row.PlayerName:SetScale(0, 0); row.PlayerName:SetFontSize(scale(18));row.PlayerName:SetAlpha(1, 0)
    row.PlayerName:SetRGBFromInt(0xF5F1E7, 0)
    rect(row.PlayerName, 52, 242, 0, 22)
    row.PlayerCash:SetScale(0, 0);row.PlayerCash:SetFontSize(scale(22));rect(row.PlayerCash, 52, 220, 24, 48)
    row.PlayerCash:SetRGBFromInt(0xF5F1E7, 0)
    if not row.__bo3TeamStyled then
        if row.BackingBox then row:removeElement(row.BackingBox) end
        if row.dollarSign then row:removeElement(row.dollarSign) end
        row.BO3Speaker = speaker(row, "BO3TeamSpeaker")
        row.__bo3TeamStyled = true
    end
    rect(row.BO3Speaker, 258, 280, 12, 34)
    mic(row.BO3Speaker, client_data(row._clientNum))
end
local try_root
local function hook_team_refresh(teammates, root)
    assert(type(teammates.RefreshRows) == "function", "Actual team refresh required")
    local prior = state.refreshHooks[teammates]
    if prior and teammates.RefreshRows == prior.wrapper then return end
    if prior then prior.retired = true end
    local hook = {original = teammates.RefreshRows}
    local function pack(...) return {n = select("#", ...), ...} end
    hook.wrapper = function(self, ...)
        local result = pack(hook.original(self, ...))
        if not hook.retired and not state.closed then try_root(root) end
        return unpack(result, 1, result.n)
    end
    state.refreshHooks[teammates] = hook
    teammates.RefreshRows = hook.wrapper
end
local function style_team(root, container, info)
    local hero = container.BO3Hero
    if not hero then
        hero = panel("BO3Hero", 344, 112);container:addElement(hero);container.BO3Hero = hero
        bar(hero, "BO3HeroRule", 82, 85, 4, 104, 0xA49E8B)
        hero.BO3Name = text(hero, "BO3HeroName", 19, 92, 304, 9, 33)
        hero.BO3Speaker = speaker(hero, "BO3HeroSpeaker")
    end
    hero:SetAnchorsAndPosition(0, 1, 1, 0, scale(24), scale(368), scale(-168), scale(-56))
    reparent(info.PlayerIcon, hero); reparent(info.PlayerCash, hero);style_player(info)
    rect(hero.BO3Speaker, 314, 336, 12, 34)
    local current = client_data(current_client())
    hero.BO3Name:setText(current and type(current.name) == "string" and current.name or "");mic(hero.BO3Speaker, current)
    local teammates = assert(container.PlayerCash, "Actual teammate container required")
    assert(teammates.Players, "Actual teammate grid required")
    teammates:SetYRotation(0, 0);teammates:SetZRotation(0, 0)
    teammates:SetAnchorsAndPosition(0, 1, 1, 0, scale(24), scale(344), scale(-336), scale(-180))
    -- Keep the native 165-column cell aligned at x0. Stencil is stock-disabled;
    -- its restyled children extend to x280 inside the wider 320 parent.
    rect(teammates.Players, 0, 165, 0, 156)
    walk_leaves(teammates.Players, style_teamrow)
    hook_team_refresh(teammates, root)
    -- Retail's existing one-second refresh also updates our hero after the
    -- bounded startup poll ends. No extra timer or synthetic roster is added.
    -- Earned/spent deltas keep their flight/fade, in a separate x lane.
    if root.cashEarned then
        root.cashEarned:SetAnchorsAndPosition(0, 1, 1, 0, scale(560), scale(560), scale(-370), scale(-370))
    end
end
local function adapt_root(root)
    assert(type(root.controllerIndex) == "number" and root.controllerIndex >= 0 and root.controllerIndex <= 3,
        "Actual HUD controller required")
    assert(root.waveNumber and root.activePerks and root.mainPlayerInfo, "Complete essentials root required")
    -- HUD.AddWidget returns a wrapper with _widget. The round wrapper contains
    -- a full-screen canvas: move its leaf, never shrink that canvas.
    local round = unwrap(root.waveNumber)
    style_wave(assert(round.WaveNumber, "Round container leaf required"))
    root.activePerks:SetAnchorsAndPosition(0, 1, 1, 0, scale(50), scale(690), scale(-416), scale(-352))
    local icons = style_perks(unwrap(root.activePerks).PerkList)
    local player = unwrap(root.mainPlayerInfo)
    local info = assert(player.MainPlayerInfo or player.MainPlayerInfoDLC1 or player.MainPlayerInfoDLC2
        or player.MainPlayerInfoDLC3 or player.MainPlayerInfoDLC4, "Player container leaf required")
    style_team(root, player, info)
    root.mainPlayerInfo:SetYRotation(0, 0)
    root.mainPlayerInfo:SetZRotation(0, 0)
    local bottom = unwrap(root.wonderCard)
    assert(bottom and bottom.ZomWeaponInfo and bottom.ZomWeaponInfo.weaponinfoZM, "Weapon container leaf required")
    adapt_bottom(function() return bottom end)
    style_ammo(bottom.ZomWeaponInfo.weaponinfoZM)
    -- Root's stock per-map visibility lists still own all these original fields.
    root.__bo3HudLayout = true
    emit("bind:" .. token(root.id) .. ":" .. token(root.controllerIndex), "bind version=" .. state.version
        .. " root=" .. token(root.id) .. " controller=" .. token(root.controllerIndex)
        .. " root_seq=" .. state.roots[root] .. " round=1 ammo=1 portrait=1 perks=" .. icons .. " pixels=unverified")
end
try_root = function(root)
    local ids = {ZMHUD=true, ZMHUDDLC1=true, ZMHUDDLC2=true, ZMHUDDLC3=true, ZMHUDDLC4=true}
    if not root or not ids[root.id] then return end
    gate_trace()
    if not opted_in() then return end
    if not state.roots[root] then state.nextRoot = state.nextRoot + 1; state.roots[root] = state.nextRoot end
    emit("root:" .. token(root.id) .. ":" .. token(root.controllerIndex), "root version=" .. state.version
        .. " id=" .. token(root.id) .. " controller=" .. token(root.controllerIndex) .. " root_seq=" .. state.roots[root])
    local ok, error = pcall(adapt_root, root)
    if ok then
        -- A later recurrence of the same failure must invalidate external bind
        -- evidence again, rather than be hidden by the state-change cache.
        state.messages["failure:" .. token(root.id)] = nil
    else
        state.messages["bind:" .. token(root.id) .. ":" .. token(root.controllerIndex)] = nil
        emit("failure:" .. token(root.id), "binding_failure version=" .. state.version
            .. " root=" .. token(root.id) .. " root_seq=" .. state.roots[root]
            .. " reason=" .. token(error) .. " retry=1 pixels=unverified")
    end
end
local replacements = {
    WaveNumber = function(_, menu, args) return build_wave(menu, args) end,
    weaponinfoZM = function(_, menu, args) return build_ammo(menu, args) end,
    CPPerkIcon = function(_, menu, args) return build_perk(menu, args) end,
    MainPlayerInfo = adapt_player,
    MainPlayerInfoDLC1 = adapt_player,
    MainPlayerInfoDLC2 = adapt_player,
    MainPlayerInfoDLC3 = adapt_player,
    MainPlayerInfoDLC4 = adapt_player,
    HudBottomRight = adapt_bottom,
    HudBottomRightDLC2 = adapt_bottom
}
local function install_dispatch()
    if not MenuBuilder or type(MenuBuilder.BuildRegisteredType) ~= "function" then return end
    local prior = state.hooks.dispatch
    if prior and prior.map == MenuBuilder and prior.map[prior.key] == prior.wrapper then return end
    if prior then prior.retired = true end
    local original = MenuBuilder.BuildRegisteredType
    local hook = { map = MenuBuilder, key = "BuildRegisteredType", original = original }
    local wrapper = function(key, args, ...)
        local apply = replacements[key]
        if hook.retired or state.closed or not opted_in() or not apply then return original(key, args, ...) end
        -- Dispatch catches lazy-loaded retail factories before their first call.
        -- Stock root classes and all unrelated constructors remain untouched.
        local fallback = function(_, supplied) return original(key, supplied) end
        local previous_nodes = pending_nodes
        local created = {}
        pending_nodes = created
        local ok, result = pcall(apply, fallback, nil, args)
        pending_nodes = previous_nodes
        if ok and result then
            state.factoryApplied = state.factoryApplied + 1
            emit("factory:" .. key, "factory_applied version=" .. state.version .. " key=" .. token(key) .. " pixels=unverified")
            return result
        end
        for i = #created, 1, -1 do
            if created[i].close then pcall(function() created[i]:close() end) end
        end
        state.failures = state.failures + 1
        emit("factory_failure:" .. key, "factory_fallback version=" .. state.version .. " key=" .. token(key)
            .. " reason=" .. token(result) .. " retry=1 pixels=unverified")
        return original(key, args, ...)
    end
    hook.wrapper = wrapper
    state.hooks.dispatch = hook
    MenuBuilder.BuildRegisteredType = wrapper
    emit("hook:dispatch", "hook version=" .. state.version .. " kind=dispatch installed=1")
end
local function install_hud_hook()
    local manager = LUI and LUI.HudManager
    if not manager or type(manager.CreateHud) ~= "function" then return end
    local prior = state.hooks.hud
    if prior and prior.map == manager and manager.CreateHud == prior.wrapper then return end
    if prior then prior.retired = true end
    local original = manager.CreateHud
    local hook = { map = manager, key = "CreateHud", original = original }
    local function pack(...) return { n = select("#", ...), ... } end
    hook.wrapper = function(self, ...)
        local values = pack(original(self, ...))
        if not hook.retired and not state.closed then try_root(self.activeHud) end
        return unpack(values, 1, values.n)
    end
    state.hooks.hud = hook
    manager.CreateHud = hook.wrapper
    emit("hook:hud", "hook version=" .. state.version .. " kind=create_hud installed=1")
end
local function visit_root()
    if not opted_in() or not Engine.GetLuiRoot then return end
    local tree = Engine.GetLuiRoot()
    if not tree then return end
    if tree.hudManager then try_root(tree.hudManager.activeHud) end
    if not tree.getFirstDescendentById then return end
    for _, id in ipairs({"ZMHUD", "ZMHUDDLC1", "ZMHUDDLC2", "ZMHUDDLC3", "ZMHUDDLC4"}) do
        local root = tree:getFirstDescendentById(id)
        if root then try_root(root) end
    end
end
function state.shutdown()
    state.closed = true
    for owner, hook in pairs(state.refreshHooks) do
        hook.retired = true
        if owner.RefreshRows == hook.wrapper then owner.RefreshRows = hook.original end
    end
    for key, hook in pairs(state.hooks) do
        hook.retired = true
        local field = hook.key or key
        if hook.map[field] == hook.wrapper then hook.map[field] = hook.original end
    end
    print("[BO3 HUD] factory hooks restored; existing HUD requires normal VM teardown")
end
local attempts = 0
local function poll()
    if state.closed then return end
    attempts = attempts + 1
    gate_trace()
    if configured() then install_dispatch(); install_hud_hook(); visit_root() end
    -- Bounded startup polling. Generation cancellation is provided by native77e.
    if attempts < 480 then scheduler.once(poll, 500) end
end
print("[BO3 HUD] module version=" .. state.version .. " instance=" .. state.instance .. " initialized=1 pixels=unverified")
print("[BO3 HUD] source prototype loaded; opt-in/actual runtime and pixels pending")
-- Native loads our module after the retail VM. Install before another deferred
-- frame, and also visit existing HUD leaves after its normal construction.
gate_trace()
if configured() then install_dispatch(); install_hud_hook(); visit_root() end
scheduler.once(poll, 0)
