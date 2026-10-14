-- Original IW7 adapter, not retail BO3 source/art. Private opt-in prototype.
-- Actual IW7 data models stay authoritative; no gameplay/model writes.
if rawget(_G, "BO3ZombiesHUD") then return end
local state = { version = "0.1.0", hooks = {}, failures = 0, closed = false }
BO3ZombiesHUD = state
local pending_nodes
local function remember(node)
    if pending_nodes then pending_nodes[#pending_nodes + 1] = node end
    return node
end
local scale = function(v) return v * (_1080p or 1) end
local function configured()
    return Engine and Engine.GetDvarString
        and Engine.GetDvarString("bo3_zombies_hud_enable") == "1"
        and Engine.GetDvarString("bo3_zombies_hud_private") == "1"
end
local function opted_in()
    return configured() and not Engine.InFrontend()
        and Engine.GetDvarString("ui_gametype") == "zombie"
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
    bind_text(title, name, index, function(value) return Engine.Localize(value) end)
    local function update_left()
        clip_left:SetAlpha(dual:GetValue(index) == true and melee:GetValue(index) ~= true and 1 or 0, 0)
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
local function adapt_player(original, menu, args)
    local self = remember(original(menu, args))
    -- Keep original image/character/status, cash, Rave/quest/inventory callbacks.
    -- Never replace the complete player container and lose its quest children.
    assert(self and self.PlayerIcon and self.PlayerCash, "Actual IW7 player fields required")
    if self.box then self:removeElement(self.box) end
    if self.dollarSign then self:removeElement(self.dollarSign) end
    self.PlayerIcon:SetYRotation(0, 0)
    self.PlayerIcon:SetZRotation(0, 0)
    rect(self.PlayerIcon, 0, 72, 104, 176)
    self.PlayerCash:SetFontSize(scale(34))
    self.PlayerCash:SetRGBFromInt(0xF5F1E7, 0)
    rect(self.PlayerCash, 86, 275, 127, 166)
    bar(self, "BO3PortraitTop", 0, 72, 100, 103, 0xA49E8B)
    bar(self, "BO3PortraitBottom", 0, 72, 177, 180, 0xA49E8B)
    return self
end
local function adapt_bottom(original, menu, args)
    local self = remember(original(menu, args))
    assert(self and self.ZomWeaponInfo, "Actual IW7 ammo container required")
    self.ZomWeaponInfo:SetYRotation(0, 0)
    self.ZomWeaponInfo:SetZRotation(0, 0)
    self.ZomWeaponInfo:SetAnchorsAndPosition(1, 0, 1, 0, scale(-454), scale(-76), scale(-168), scale(-48))
    return self
end
local function adapt_root(root)
    if root.__bo3HudLayout then return end
    assert(root.waveNumber and root.activePerks and root.mainPlayerInfo, "Complete essentials root required")
    root.waveNumber:SetAnchorsAndPosition(0, 1, 1, 0, scale(50), scale(205), scale(-328), scale(-216))
    root.activePerks:SetAnchorsAndPosition(0, 1, 1, 0, scale(50), scale(690), scale(-246), scale(-182))
    root.mainPlayerInfo:SetYRotation(0, 0)
    root.mainPlayerInfo:SetZRotation(0, 0)
    -- Root's stock per-map visibility lists still own all these original fields.
    root.__bo3HudLayout = true
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
    if state.hooks.dispatch or not MenuBuilder or type(MenuBuilder.BuildRegisteredType) ~= "function" then return end
    local original = MenuBuilder.BuildRegisteredType
    local wrapper = function(key, args, ...)
        local apply = replacements[key]
        if state.closed or not opted_in() or not apply then return original(key, args, ...) end
        -- Dispatch catches lazy-loaded retail factories before their first call.
        -- Stock root classes and all unrelated constructors remain untouched.
        local fallback = function(_, supplied) return original(key, supplied) end
        local previous_nodes = pending_nodes
        local created = {}
        pending_nodes = created
        local ok, result = pcall(apply, fallback, nil, args)
        pending_nodes = previous_nodes
        if ok and result then return result end
        for i = #created, 1, -1 do
            if created[i].close then pcall(function() created[i]:close() end) end
        end
        state.failures = state.failures + 1
        print("[BO3 HUD] source adapter refused " .. key .. "; stock fallback; pixels pending")
        return original(key, args, ...)
    end
    state.hooks.dispatch = { map = MenuBuilder, key = "BuildRegisteredType", original = original, wrapper = wrapper }
    MenuBuilder.BuildRegisteredType = wrapper
end
local function visit_root()
    if not opted_in() or not Engine.GetLuiRoot then return end
    local tree = Engine.GetLuiRoot()
    if not tree or not tree.getFirstDescendentById then return end
    for _, id in ipairs({"ZMHUD", "ZMHUDDLC1", "ZMHUDDLC2", "ZMHUDDLC3", "ZMHUDDLC4"}) do
        local root = tree:getFirstDescendentById(id)
        if root then pcall(adapt_root, root) end
    end
end
function state.shutdown()
    state.closed = true
    for key, hook in pairs(state.hooks) do
        local field = hook.key or key
        if hook.map[field] == hook.wrapper then hook.map[field] = hook.original end
    end
    print("[BO3 HUD] factory hooks restored; existing HUD requires normal VM teardown")
end
local attempts = 0
local function poll()
    if state.closed then return end
    attempts = attempts + 1
    if configured() then install_dispatch(); visit_root() end
    -- Bounded startup polling. Generation cancellation is provided by native77e.
    if attempts < 480 then scheduler.once(poll, 500) end
end
print("[BO3 HUD] source prototype loaded; opt-in/actual runtime and pixels pending")
scheduler.once(poll, 0)
