-- Original IW7 adapter, not retail BO3 source/art. Private opt-in prototype.
-- Actual IW7 data models stay authoritative; no gameplay/model writes.
if rawget(_G, "BO3ZombiesHUD") then return end
local VERSION, DIAGNOSTIC_VERSION = "0.8.0", "0.7.0"
local state = { version = VERSION, diagnosticVersion = DIAGNOSTIC_VERSION, hooks = {}, failures = 0, closed = false, factoryApplied = 0 }
state.instance = (string.gsub(tostring(state), "[^%w]", "")):sub(1, 40)
state.roots = setmetatable({}, {__mode = "k"})
-- Values are weak too: each live owner's installed wrapper retains its hook.
-- In Lua5.1 a weak key alone would retain old roots through the hook closure.
state.refreshHooks = setmetatable({}, {__mode = "kv"})
state.cardCores = setmetatable({}, {__mode = "kv"})
state.cardDiagnostics = setmetatable({}, {__mode = "k"})
state.nextCardDiagnostic = 0
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
    emit("gate", "gate version=" .. DIAGNOSTIC_VERSION .. " profile=" .. (configured() and "1" or "0")
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
local function style_equipment(self)
    -- Keep the original ability, warning, datasource and independent quantity
    -- alpha/color callbacks. Put the two offhands beside, not over, ammo/cards.
    for i, prefix in ipairs({"Primary", "Secondary"}) do
        local ability, count = self[prefix .. "Ability"], self[prefix .. "AbilityQuantity"]
        local y = (i - 1) * 83
        if ability then
            ability:SetScale(-0.55, 0)
            rect(ability, 365, 495, y - 8, y + 117)
        end
        if count then
            count:SetFontSize(scale(24))
            rect(count, 462, 500, y + 31, y + 57)
        end
    end
    if self.muleWeaponIndicator then rect(self.muleWeaponIndicator, -72, -37, 32, 70) end
    if self.UnlimitedAmmoIcon then
        self.UnlimitedAmmoIcon:SetScale(0, 0)
        rect(self.UnlimitedAmmoIcon, 286, 350, 76, 108)
    end
    if self.CraftedWeapon then
        -- Keep crafted-image pulses and the original PC/controller/DLC4 glyph
        -- callbacks; the label gets its own lane to the left of the weapon name.
        self.CraftedWeapon:SetScale(0, 0)
        rect(self.CraftedWeapon, -72, -34, 84, 123)
        if self.CraftedWeapon.ButtonFont then
            self.CraftedWeapon.ButtonFont:SetFontSize(scale(18))
            rect(self.CraftedWeapon.ButtonFont, -272, 64, 44, 64)
        end
    end
end
local function reparent(leaf, parent)
    local previous = leaf:getParent()
    if previous == parent then return end
    if previous then previous:removeElement(leaf) end
    parent:addElement(leaf)
end
local function style_fan(self)
    assert(self and self.fanCard and self.fanOverlay, "Actual native fan surfaces required")
    if not self.__bo3FanBack then
        -- Authored dark card/rim, not BO3 retail art. Keep the original two
        -- image objects and native overlay depth tint/alpha. This inset stays
        -- inside their old quad; parent pose/count/selection remains native.
        self.fanCard:setImage(RegisterMaterial("white"), 0)
        self.fanCard:SetRGBFromInt(0x171713, 0)
        self.fanOverlay:setImage(RegisterMaterial("white"), 0)
        rect(self.fanCard, 20.5, 212.5, 80, 432)
        rect(self.fanOverlay, 20.5, 212.5, 80, 432)
        bar(self, "BO3FanTop", 20.5, 212.5, 80, 84, 0xA49E8B)
        bar(self, "BO3FanBottom", 20.5, 212.5, 428, 432, 0xA49E8B)
        bar(self, "BO3FanLeft", 20.5, 24.5, 84, 428, 0xA49E8B)
        bar(self, "BO3FanRight", 208.5, 212.5, 84, 428, 0xA49E8B)
        bar(self, "BO3FanRule", 76.5, 156.5, 254, 258, 0xA49E8B)
        self.__bo3FanBack = true
    end
    return self
end
local function card_feeds()
    local z = DataSources and DataSources.inGame and DataSources.inGame.CP and DataSources.inGame.CP.zombies
    if not z then return nil end
    return {remaining=z.consumablesRemaining, fill=z.dpadUpFillPercent,
        ready=z.consumableDeckSelectReady, boss=z.dlc4 and z.dlc4.mephBattle}
end
local function diagnostic_value(value)
    local kind = type(value)
    if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then return token(value) end
    return "unsupported"
end
local function card_values(self, feeds, index)
    local observed = {}
    if not feeds then return nil, "feeds_missing", observed end
    if not CONDITIONS or not CONDITIONS.IsDLC4 then return nil, "predicate_missing", observed end
    local ok, dlc4 = pcall(CONDITIONS.IsDLC4, self)
    observed.predicate = {kind=ok and type(dlc4) or "error", value=ok and diagnostic_value(dlc4) or "unavailable"}
    if not ok then return nil, "predicate_error", observed end
    if type(dlc4) ~= "boolean" then return nil, "predicate_type", observed end
    local function read(key)
        local model = feeds[key]
        if not model or not model.GetValue then
            observed[key] = {kind="missing_reader", value="unavailable"};return nil
        end
        local got, value = pcall(function() return model:GetValue(index) end)
        observed[key] = {kind=got and type(value) or "error", value=got and diagnostic_value(value) or "unavailable"}
        if got then return value end
    end
    local remaining, fill, ready = read("remaining"), read("fill"), read("ready")
    observed.boss = {kind=dlc4 and "not_read" or "not_required", value=dlc4 and "not_read" or "not_required"}
    if type(remaining) ~= "number" or remaining < 0 or remaining > 5 or remaining ~= math.floor(remaining) then
        return nil, "remaining_value", observed
    end
    if type(fill) ~= "number" or fill ~= fill or fill < 0 or fill > 1 then return nil, "fill_value", observed end
    if ready ~= 0 and ready ~= 1 then return nil, "ready_value", observed end
    local boss = 0
    if dlc4 then boss = read("boss") end
    if boss ~= 0 and boss ~= 1 then return nil, "boss_value", observed end
    return {remaining=remaining, ready=ready, boss=boss == 1, dlc4=dlc4}, nil, observed
end
local function card_trace(self, index, stage, reason, observed)
    if not self then return end
    local record = state.cardDiagnostics[self]
    if not record then
        state.nextCardDiagnostic = state.nextCardDiagnostic + 1
        record = {count=0, sequence=state.nextCardDiagnostic};state.cardDiagnostics[self] = record
    end
    local signature = stage .. ":" .. reason
    if record.signature == signature or record.count > 32 then return end
    record.signature = signature;record.count = record.count + 1
    -- At most32 branch transitions plus one suppression notice per widget.
    -- Values are snapshots on a reason change, never a per-frame feed stream.
    if record.count == 33 then stage, reason, observed = "suppressed", "transition_limit", nil end
    observed = observed or {}
    local message = "core version=" .. DIAGNOSTIC_VERSION .. " widget_seq=" .. token(record.sequence) .. " controller=" .. token(index)
        .. " stage=" .. token(stage) .. " reason=" .. token(reason)
    for _, key in ipairs({"predicate", "remaining", "fill", "ready", "boss"}) do
        local value = observed[key] or {kind="not_read", value="not_read"}
        message = message .. " " .. key .. "_type=" .. token(value.kind) .. " " .. key .. "_value=" .. token(value.value)
    end
    for _, key in ipairs({"shape", "parents", "pointer_key", "pointer_status", "mode"}) do
        message = message .. " " .. key .. "=" .. token(observed[key] or "not_checked")
    end
    -- This optional trace is ignored by the existing essential-bind parser.
    print("[BO3 HUD] " .. message .. " pixels=unverified instance=" .. state.instance)
end
local function native_card_core(owner)
    owner.mask:SetAlpha(1, 0);owner.view:SetAlpha(0, 0);owner.mode = "native_unknown"
end
local function style_card_core(self, index)
    if not (self and self.devilHead and self.devilJaw and self.sadDevil
        and self.radialAlphaLarge and self.radialAlphaLarge.circleFill) then
        local shape = ""
        for _, leaf in ipairs({"devilHead", "devilJaw", "sadDevil", "radialAlphaLarge"}) do
            shape = shape .. (self and self[leaf] and "1" or "0")
        end
        shape = shape .. (self and self.radialAlphaLarge and self.radialAlphaLarge.circleFill and "1" or "0")
        card_trace(self, index, "shape", "native_shape", {shape=shape});return self
    end
    local feeds, owner = card_feeds(), self.__bo3CardCore
    if owner then
        local same = feeds and owner.index == index
        if not same then owner.disabledReason = owner.index ~= index and "controller_changed" or "feeds_missing" end
        for _, key in ipairs(owner.required) do
            if same and owner.feeds[key] ~= feeds[key] then owner.disabledReason = "feed_changed_" .. key end
            same = same and owner.feeds[key] == feeds[key]
        end
        if not same then owner.disabled = true end
        owner.update();return self
    end
    -- Unknown feeds/predicate stay wholly native. Existing roots retry through
    -- their owned refresh; no model value is fabricated to force a new skin.
    local value, reason, observed = card_values(self, feeds, index)
    observed.shape = "11111"
    if not value then card_trace(self, index, "values", reason, observed);return self end
    local required = {"remaining", "fill", "ready"}
    if value.dlc4 then required[#required + 1] = "boss" end
    local pointers = {}
    for _, key in ipairs(required) do
        local model = feeds[key]
        observed.pointer_key = key
        if not model.GetModel then
            observed.pointer_status = "missing_reader";card_trace(self, index, "pointer", key, observed);return self
        end
        local ok, pointer = pcall(function() return model:GetModel(index) end)
        observed.pointer_status = ok and type(pointer) or "error"
        if not ok or not pointer then card_trace(self, index, "pointer", key, observed);return self end
        pointers[key] = pointer
    end
    local faces = {self.devilJaw, self.devilHead, self.sadDevil}
    observed.parents = ""
    for _, leaf in ipairs(faces) do
        observed.parents = observed.parents .. (leaf:getParent() == self and "1" or "0")
    end
    if observed.parents ~= "111" then card_trace(self, index, "parents", "native_parent", observed);return self end
    local mask = panel("BO3NativeCardFaces", 168, 173)
    mask:SetAnchorsAndPosition(0, 0, 0, 0, 0, 0, 0, 0);self:addElement(mask)
    for _, leaf in ipairs(faces) do reparent(leaf, mask) end
    local view = panel("BO3CardCore", 168, 173)
    view:SetAnchorsAndPosition(0, 0, 0, 0, 0, 0, 0, 0);self:addElement(view)
    local title = text(view, "BO3CardTitle", 28, 2.5, 166.5, -28, 2)
    local count = text(view, "BO3CardCount", 40, 34.5, 134.5, 58, 102)
    local status = text(view, "BO3CardStatus", 26, 2.5, 166.5, 174, 202)
    title:SetAlignment(LUI.Alignment.Center);count:SetAlignment(LUI.Alignment.Center);status:SetAlignment(LUI.Alignment.Center)
    owner = {mask=mask, view=view, index=index, feeds=feeds, required=required, dlc4=value.dlc4, title=title, count=count, status=status}
    owner.update = function()
        if state.closed or owner.disabled then
            card_trace(self, index, "owner", state.closed and "closed" or owner.disabledReason or "disabled", {mode="native"})
            native_card_core(owner);return
        end
        local value, reason, current = card_values(self, feeds, index)
        current.shape, current.parents = "11111", ""
        for _, leaf in ipairs(faces) do
            current.parents = current.parents .. (leaf:getParent() == mask and "1" or "0")
        end
        current.pointer_key, current.pointer_status = value and (value.dlc4 and "all4" or "all3") or "not_checked", "preflight_ok"
        if not value or value.dlc4 ~= owner.dlc4 then
            card_trace(self, index, "values", reason or "predicate_changed", current)
            native_card_core(owner);return
        end
        mask:SetAlpha(0, 0);view:SetAlpha(1, 0)
        title:setText(value.boss and "BOSS" or "CARDS")
        count:setText(tostring(value.remaining))
        status:setText(value.remaining == 0 and "EMPTY" or value.ready == 1 and "READY" or "CHARGING")
        owner.mode = value.boss and "boss" or "cards"
        current.mode = owner.mode
        card_trace(self, index, "custom", value.boss and "boss" or value.remaining == 0 and "empty" or value.ready == 1 and "ready" or "charging", current)
    end
    self.__bo3CardCore = owner;state.cardCores[self] = owner
    -- Native image references and animations remain alive under a same-canvas
    -- ancestor. Only their rendering is masked while equivalent data is known.
    for _, pointer in pairs(pointers) do view:SubscribeToModel(pointer, owner.update) end
    owner.update()
    return self
end
local function adapt_bottom(original, menu, args)
    local self = remember(original(menu, args))
    assert(self and self.ZomWeaponInfo, "Actual IW7 ammo container required")
    self.ZomWeaponInfo:SetYRotation(0, 0)
    self.ZomWeaponInfo:SetZRotation(0, 0)
    self.ZomWeaponInfo:SetAnchorsAndPosition(1, 0, 1, 0, scale(-560), scale(-182), scale(-210), scale(-48))
    style_equipment(self.ZomWeaponInfo)
    -- Compact the complete native deck, including charge, fan and selection
    -- feedback. Do not hide individual parts or shrink the active-card list.
    if self.FateCardWidget then
        self.FateCardWidget:SetYRotation(0, 0); self.FateCardWidget:SetZRotation(0, 0)
        -- SetScale is a delta from 1: retain 65% of the authored deck. Its fan
        -- extends to y588.5 beyond the declared 389 height; allow that overflow
        -- after the center-based scale, above ammo and left of active effects.
        self.FateCardWidget:SetScale(-0.35, 0)
        self.FateCardWidget:SetAnchorsAndPosition(1, 0, 1, 0, scale(-420), scale(-167), scale(-695), scale(-306))
        for i = 1, 4 do
            local fan = self.FateCardWidget["fanCard" .. i]
            if fan then style_fan(fan) end
        end
        if self.FateCardWidget.FateCardDevilWidget then
            style_card_core(self.FateCardWidget.FateCardDevilWidget, controller_index(self, args))
        end
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
local function style_powerup(self)
    assert(self and self.PowerupIcon, "Actual power-up image required")
    -- Alpha/Flash/FadeIn remain native, including the bitfield animation event.
    rect(self, 0, 52, 0, 52)
    rect(self.PowerupIcon, 4, 48, 4, 48)
    return self
end
local function style_status(root)
    if root.activePowerups then
        root.activePowerups:SetAnchorsAndPosition(1, 0, 0, 1, scale(-920), scale(-280), scale(48), scale(112))
        local list = assert(unwrap(root.activePowerups).ZomPowerupWidget, "Actual power-up list required")
        list:SetZRotation(0, 0)
        walk_leaves(list, function(child)
            if child.PowerupIcon then style_powerup(child) end
        end)
    end
    if root.powerupActivated then
        local popup = unwrap(root.powerupActivated)
        if popup.PowerUpName then popup.PowerUpName:SetFont(FONTS.GetFont(FONTS.MainBold.File)) end
        -- The message queue owns its icon/name, flight, scaling and completion.
    end
    if root.reviveBarContainer then
        local revive = unwrap(root.reviveBarContainer)
        assert(revive.Header and revive.Header.MessageText and revive.ProgressBar, "Actual revive elements required")
        root.reviveBarContainer:SetAnchorsAndPosition(0.5, 0.5, 0.5, 0.5, scale(-128), scale(128), scale(60), scale(124))
        revive.Header.MessageText:SetRGBFromInt(0xF5F1E7, 0)
        if revive.ProgressBar.Fill then revive.ProgressBar.Fill:SetRGBFromInt(0xA49E8B, 0) end
        -- Never resize the progress mask or override SetProgress/SetHeader,
        -- secureState/secureProgress or the native Show/Hide/Skeeball paths.
    end
    if root.lastStand then
        local timer = unwrap(root.lastStand)
        local count = timer:getFirstDescendentById("laststand_countdown")
        assert(count, "Actual downed countdown required")
        root.lastStand:SetAnchorsAndPosition(0.5, 0.5, 1, 0, scale(150), scale(350), scale(-500), scale(-300))
        count:SetFont(FONTS.GetFont(FONTS.MainBold.File));count:SetFontSize(scale(36))
        count:SetRGBFromInt(0xB83226, 0)
        rect(count, 0, 100, -12, 36)
        local icon = timer:getFirstDescendentById("laststand_icon")
        if icon then rect(icon, -44, -12, 0, 32) end
        -- The original omnvar handler still sets the real UICountdown end time
        -- and owns the parent's visible/default states, including late binds.
    end
    if root.afterlifeSelfReviveProgress then
        local afterlife = unwrap(root.afterlifeSelfReviveProgress)
        if afterlife.SoulPowerTitle then
            afterlife.SoulPowerTitle:SetFont(FONTS.GetFont(FONTS.MainBold.File))
            afterlife.SoulPowerTitle:SetRGBFromInt(0xF5F1E7, 0)
        end
        -- Full-width soul progress, token/arcade messages, glyphs and native
        -- Bootup/ShowTokenMessage animations keep their original geometry.
    end
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
    -- The remaining original group is map-specific quest/Rave/chi/element
    -- inventory. Moving it as a whole retains every child, mask and callback.
    info:SetYRotation(0, 0);info:SetZRotation(0, 0);info:SetScale(-0.25, 0)
    info:SetAnchorsAndPosition(0, 1, 1, 0, scale(650), scale(932), scale(-260), scale(-41))
    if info.elementName then
        info.elementName:SetFontSize(scale(28))
        rect(info.elementName, 200.5, 457.5, 152.94, 180.94)
    end
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
    adapt_bottom(function() return bottom end, nil, {controllerIndex=root.controllerIndex})
    style_ammo(bottom.ZomWeaponInfo.weaponinfoZM)
    style_status(root)
    -- Root's stock per-map visibility lists still own all these original fields.
    root.__bo3HudLayout = true
    emit("bind:" .. token(root.id) .. ":" .. token(root.controllerIndex), "bind version=" .. DIAGNOSTIC_VERSION
        .. " root=" .. token(root.id) .. " controller=" .. token(root.controllerIndex)
        .. " root_seq=" .. state.roots[root] .. " round=1 ammo=1 portrait=1 perks=" .. icons .. " pixels=unverified")
end
try_root = function(root)
    local ids = {ZMHUD=true, ZMHUDDLC1=true, ZMHUDDLC2=true, ZMHUDDLC3=true, ZMHUDDLC4=true}
    if not root or not ids[root.id] then return end
    gate_trace()
    if not opted_in() then return end
    if not state.roots[root] then state.nextRoot = state.nextRoot + 1; state.roots[root] = state.nextRoot end
    emit("root:" .. token(root.id) .. ":" .. token(root.controllerIndex), "root version=" .. DIAGNOSTIC_VERSION
        .. " id=" .. token(root.id) .. " controller=" .. token(root.controllerIndex) .. " root_seq=" .. state.roots[root])
    local ok, error = pcall(adapt_root, root)
    if ok then
        -- A later recurrence of the same failure must invalidate external bind
        -- evidence again, rather than be hidden by the state-change cache.
        state.messages["failure:" .. token(root.id)] = nil
    else
        state.messages["bind:" .. token(root.id) .. ":" .. token(root.controllerIndex)] = nil
        emit("failure:" .. token(root.id), "binding_failure version=" .. DIAGNOSTIC_VERSION
            .. " root=" .. token(root.id) .. " root_seq=" .. state.roots[root]
            .. " reason=" .. token(error) .. " retry=1 pixels=unverified")
    end
end
local replacements = {
    WaveNumber = function(_, menu, args) return build_wave(menu, args) end,
    weaponinfoZM = function(_, menu, args) return build_ammo(menu, args) end,
    CPPerkIcon = function(_, menu, args) return build_perk(menu, args) end,
    FateFanCard = function(original, menu, args) return style_fan(remember(original(menu, args))) end,
    FateCardDevilWidget = function(original, menu, args)
        local self = remember(original(menu, args))
        return style_card_core(self, controller_index(self, args))
    end,
    ZomPowerupIcon = function(original, menu, args) return style_powerup(remember(original(menu, args))) end,
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
            emit("factory:" .. key, "factory_applied version=" .. DIAGNOSTIC_VERSION .. " key=" .. token(key) .. " pixels=unverified")
            return result
        end
        for i = #created, 1, -1 do
            if created[i].close then pcall(function() created[i]:close() end) end
        end
        state.failures = state.failures + 1
        emit("factory_failure:" .. key, "factory_fallback version=" .. DIAGNOSTIC_VERSION .. " key=" .. token(key)
            .. " reason=" .. token(result) .. " retry=1 pixels=unverified")
        return original(key, args, ...)
    end
    hook.wrapper = wrapper
    state.hooks.dispatch = hook
    MenuBuilder.BuildRegisteredType = wrapper
    emit("hook:dispatch", "hook version=" .. DIAGNOSTIC_VERSION .. " kind=dispatch installed=1")
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
    emit("hook:hud", "hook version=" .. DIAGNOSTIC_VERSION .. " kind=create_hud installed=1")
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
    for _, owner in pairs(state.cardCores) do native_card_core(owner) end
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
print("[BO3 HUD] module version=" .. DIAGNOSTIC_VERSION .. " content_version=" .. VERSION .. " instance=" .. state.instance .. " initialized=1 pixels=unverified")
print("[BO3 HUD] source prototype loaded; opt-in/actual runtime and pixels pending")
-- Native loads our module after the retail VM. Install before another deferred
-- frame, and also visit existing HUD leaves after its normal construction.
gate_trace()
if configured() then install_dispatch(); install_hud_hook(); visit_root() end
scheduler.once(poll, 0)
