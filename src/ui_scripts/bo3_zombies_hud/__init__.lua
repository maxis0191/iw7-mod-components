-- Original IW7 adapter, not retail BO3 source/art. Private opt-in prototype.
-- Actual IW7 data models stay authoritative; no gameplay/model writes.
if rawget(_G, "BO3ZombiesHUD") then return end
local VERSION, DIAGNOSTIC_VERSION = "0.18.0", "0.7.0"
local state = { version = VERSION, diagnosticVersion = DIAGNOSTIC_VERSION, hooks = {}, failures = 0, closed = false, factoryApplied = 0 }
state.instance = (string.gsub(tostring(state), "[^%w]", "")):sub(1, 40)
state.roots = setmetatable({}, {__mode = "k"})
-- Values are weak too: each live owner's installed wrapper retains its hook.
-- In Lua5.1 a weak key alone would retain old roots through the hook closure.
state.refreshHooks = setmetatable({}, {__mode = "kv"})
state.cardCores = setmetatable({}, {__mode = "kv"})
state.cardIdentities = setmetatable({}, {__mode = "kv"})
local card_cores = setmetatable({}, {__mode = "kv"})
local card_decor = setmetatable({}, {__mode = "kv"})
local retired_decor = setmetatable({}, {__mode = "k"})
-- Local authority, independent of the replaceable widget marker. A live owned
-- view retains its own record; the weak registry cannot retain dead HUD trees.
local action_views = setmetatable({}, {__mode = "kv"})
local retired_actions = setmetatable({}, {__mode = "k"})
local fan_views = setmetatable({}, {__mode = "kv"})
local retired_fans = setmetatable({}, {__mode = "k"})
local fan_diagnostics = setmetatable({}, {__mode = "k"})
local fan_diagnostic_count = 0
local fan_diagnostic_limit = false
state.identityDiagnostics = setmetatable({}, {__mode = "k"})
state.nextIdentityDiagnostic = 0
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
-- A closed wire matrix, not discovered through pairs/sort on the sample table.
-- Every ordinary row publishes every key, including unknown/error samples.
local fan_wire_fields = {
    "sample_status", "readback", "slot", "root_seq_seen", "slot_match", "native_phase",
    "back_id", "overlay_id", "back_type", "overlay_type", "alpha_read", "image_read",
    "alpha_intent", "overlay_alpha_intent", "overlay_rgb_intent", "hooks", "hook_stop", "initial_writes_returned",
    "parent_read", "parent_l", "parent_t", "parent_r", "parent_b",
    "back_read", "back_l", "back_t", "back_r", "back_b",
    "overlay_read", "overlay_l", "overlay_t", "overlay_r", "overlay_b",
    "origin", "intent", "duration", "intent_l", "intent_r", "intent_t", "intent_b",
    "image_argument_type", "same_adapter_argument"
}
local function fan_trace(self, index, event, reason, fields)
    local record = fan_diagnostics[self]
    if not record then
        if fan_diagnostic_count >= 16 then
            if not fan_diagnostic_limit then
                fan_diagnostic_limit = true
                print("[BO3 HUD] fan version=" .. DIAGNOSTIC_VERSION .. " widget_seq=0 controller=unknown stage=suppressed"
                    .. " reason=widget_limit field_count=0 pixels=unverified instance=" .. state.instance)
            end
            return
        end
        fan_diagnostic_count = fan_diagnostic_count + 1
        record = {sequence=fan_diagnostic_count, count=0, signatures={}};fan_diagnostics[self] = record
    end
    fields = fields or {}
    local suffix, field_count = "", #fan_wire_fields
    for i=1,field_count do
        local key = fan_wire_fields[i]
        local value = fields[key]
        suffix = suffix .. " " .. key .. "=" .. token(value == nil and "unknown" or value)
    end
    local signature = reason .. suffix
    if record.signatures[event] == signature or record.count >= 33 then return end
    record.signatures[event] = signature;record.count = record.count + 1
    if record.count == 33 then event, reason, suffix, field_count = "suppressed", "transition_limit", "", 0 end
    print("[BO3 HUD] fan version=" .. DIAGNOSTIC_VERSION .. " widget_seq=" .. record.sequence
        .. " controller=" .. token(index) .. " stage=" .. event .. " reason=" .. reason .. " field_count=" .. field_count .. suffix
        .. " pixels=unverified instance=" .. state.instance)
end
local function fan_number(value)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return "unknown" end
    local result = string.format("%.3f", value)
    return #result <= 32 and result or "unknown"
end
local fan_phases = {initial=true, noMoreCards=true}
for count=1,5 do
    local suffix = count == 1 and "Card" or "Cards"
    for _, prefix in ipairs({"initial", "cardCycle", "meterFull"}) do fan_phases[prefix .. count .. suffix] = true end
end
local function fan_rect(node, fields, prefix)
    local status = "missing"
    local ok, left, top, right, bottom = pcall(function()
        if not node or not node.getLocalRect then return end
        status = "error";return node:getLocalRect()
    end)
    if ok and fan_number(left) ~= "unknown" and fan_number(top) ~= "unknown"
        and fan_number(right) ~= "unknown" and fan_number(bottom) ~= "unknown" then
        status = "known"
        fields[prefix .. "_l"], fields[prefix .. "_t"] = fan_number(left), fan_number(top)
        fields[prefix .. "_r"], fields[prefix .. "_b"] = fan_number(right), fan_number(bottom)
    elseif ok and status ~= "missing" then status = "invalid_numeric" end
    fields[prefix .. "_read"] = status == "known" and "known" or "unknown_" .. status
end
local function fan_sample(self, index, owner, context, event, reason, extra)
    -- Diagnostics may fail independently; never turn a missing reader into
    -- evidence of zero alpha, default geometry or successful material state.
    local ok = pcall(function()
        local fields = extra or {}
        local probe = owner and owner.probe
        local slot = context and context.slot or probe and probe.slot
        local parent = self.getParent and self:getParent()
        fields.slot = slot or "unbound"
        fields.root_seq_seen = context and context.root_seq or probe and probe.root_seq or "unknown"
        fields.slot_match = slot and parent and parent["fanCard" .. slot] == self and "1" or slot and "0" or "unknown"
        local phase = parent and parent.cardAnimation
        fields.native_phase = type(phase) == "string" and fan_phases[phase] and phase or "unknown"
        fields.back_id = self.fanCard and self.fanCard.id == "fanCard" and "1" or "0"
        fields.overlay_id = self.fanOverlay and self.fanOverlay.id == "fanOverlay" and "1" or "0"
        fields.back_type, fields.overlay_type = type(self.fanCard), type(self.fanOverlay)
        fields.alpha_read, fields.image_read = "unknown", "unknown"
        fields.alpha_intent = probe and fan_number(probe.alphaIntent) or "unknown"
        fields.overlay_alpha_intent = probe and fan_number(probe.overlayAlphaIntent) or "unknown"
        fields.overlay_rgb_intent = probe and fan_number(probe.overlayRGBIntent) or "unknown"
        fields.hooks = probe and probe.active and "active" or "inactive"
        fields.hook_stop = probe and probe.stopReason or "none"
        fields.initial_writes_returned = owner and "1" or "0"
        fan_rect(self, fields, "parent")
        if fields.back_id == "1" and (not owner or self.fanCard == owner.back) then fan_rect(self.fanCard, fields, "back")
        else fields.back_read = "unknown_field" end
        if fields.overlay_id == "1" and (not owner or self.fanOverlay == owner.overlay) then fan_rect(self.fanOverlay, fields, "overlay")
        else fields.overlay_read = "unknown_field" end
        fields.sample_status = "complete"
        fan_trace(self, index, event, reason, fields)
    end)
    if not ok then pcall(fan_trace, self, index, event, reason, {sample_status="failed", readback="unknown_error"}) end
end
local function stop_fan_probe(owner, reason)
    local probe = owner.probe
    if not probe then return end
    probe.active = false
    probe.stopReason = probe.stopReason or reason
    for _, hook in ipairs(probe.hooks) do
        pcall(function() if hook.node[hook.key] == hook.wrapper then hook.node[hook.key] = hook.original end end)
    end
end
local function install_fan_probe(self, owner)
    local probe = {active=true, hooks={}};owner.probe = probe
    local function pack(...) return {n=select("#", ...), ...} end
    local ok = pcall(function()
        for _, spec in ipairs({{owner.back,"setImage","back_image"},{owner.back,"SetAnchorsAndPosition","back_rect"},
            {owner.overlay,"setImage","overlay_image"},{owner.overlay,"SetAnchorsAndPosition","overlay_rect"},
            {owner.overlay,"SetRGBFromInt","overlay_rgb"},{owner.overlay,"SetAlpha","overlay_alpha"},
            {self,"SetAlpha","parent_alpha"}}) do
            local node, key, event = spec[1], spec[2], spec[3]
            local original = node[key];assert(original, "Probe setter missing")
            local hook = {node=node, key=key, original=original}
            hook.wrapper = function(target, ...)
                local args = pack(...)
                local results = pack(original(target, ...))
                if probe.active and target == node then
                    pcall(function()
                        local fields = {origin="later_call"}
                        if event == "parent_alpha" or event == "overlay_alpha" then
                            if event == "parent_alpha" then probe.alphaIntent = args[1] else probe.overlayAlphaIntent = args[1] end
                            fields.intent, fields.duration = fan_number(args[1]), fan_number(args[2])
                        elseif event == "overlay_rgb" then probe.overlayRGBIntent = args[1];fields.intent = fan_number(args[1])
                        elseif key == "SetAnchorsAndPosition" then
                            fields.intent_l, fields.intent_r = fan_number(args[5]), fan_number(args[6])
                            fields.intent_t, fields.intent_b = fan_number(args[7]), fan_number(args[8])
                        else
                            fields.image_argument_type = type(args[1])
                            fields.same_adapter_argument = args[1] == (node == owner.back and owner.backMaterial or owner.overlayMaterial) and "1" or "0"
                        end
                        fan_sample(self, owner.index, owner, nil, event, "setter_returned", fields)
                    end)
                end
                return unpack(results, 1, results.n)
            end
            probe.hooks[#probe.hooks + 1] = hook;node[key] = hook.wrapper
        end
    end)
    if not ok then stop_fan_probe(owner, "install_error") end
    return ok
end
local function fan_shape(self, owner)
    local back, overlay = self.fanCard, self.fanOverlay
    if not back or not overlay or back == overlay then return false, "fields" end
    if back.id ~= "fanCard" or overlay.id ~= "fanOverlay" then return false, "leaf_ids" end
    if not self.getFirstChild or not back.getParent or not overlay.getParent
        or not back.getNextSibling or not overlay.getNextSibling
        or not back.getFirstChild or not overlay.getFirstChild then return false, "tree_api" end
    if back:getParent() ~= self or overlay:getParent() ~= self then return false, "leaf_parent" end
    if self:getFirstChild() ~= back or back:getNextSibling() ~= overlay then return false, "leaf_order" end
    if back:getFirstChild() or overlay:getFirstChild() then return false, "leaf_children" end
    if not owner then return overlay:getNextSibling() == nil, "extra_child" end
    if back ~= owner.back or overlay ~= owner.overlay or overlay:getNextSibling() ~= owner.view
        or owner.view:getParent() ~= self or owner.view:getNextSibling() then return false, "view_ownership" end
    local child = owner.view:getFirstChild()
    for _, leaf in ipairs(owner.rims) do
        if child ~= leaf or leaf:getParent() ~= owner.view or leaf:getFirstChild() then return false, "rim_ownership" end
        child = child:getNextSibling()
    end
    return child == nil, "extra_rim"
end
local function retire_fan(self, owner, reason)
    if fan_views[self] ~= owner or owner.retired then return end
    stop_fan_probe(owner, reason or "closed")
    owner.retired = true;retired_fans[self] = true
    -- Restore only captured native leaves still held by this exact widget.
    -- Never alter a replacement field or a leaf adopted by another parent.
    if self.fanCard == owner.back and owner.back:getParent() == self then
        owner.back:setImage(RegisterMaterial("zm_wc_card_fan"), 0)
        owner.back:SetRGBFromInt(0xFFFFFF, 0)
        rect(owner.back, -11.5, 244.5, 0, 512)
    end
    if self.fanOverlay == owner.overlay and owner.overlay:getParent() == self then
        owner.overlay:setImage(RegisterMaterial("zm_wc_card_fan_overlay"), 0)
        rect(owner.overlay, -11.5, 244.5, 0, 512)
    end
    if owner.view:getParent() == self then
        -- A foreign child inserted into our view is retained with its parent.
        -- Dispose only our captured empty rectangles and an empty view.
        for _, leaf in ipairs(owner.rims) do
            if leaf:getParent() == owner.view and not leaf:getFirstChild() then
                owner.view:removeElement(leaf);leaf:close()
            end
        end
        if not owner.view:getFirstChild() then self:removeElement(owner.view);owner.view:close() end
    end
    owner.view.__bo3FanLifetime = nil
    fan_sample(self, owner.index, owner, nil, "retired", reason or "closed")
end
local function style_fan(self, index, context)
    if not self then return self end
    local owner = fan_views[self]
    if owner then
        if owner.retired then return self end
        local ok, intact, reason = pcall(fan_shape, self, owner)
        if state.closed or self.__bo3FanBack ~= owner or owner.index ~= index or not ok or not intact then
            retire_fan(self, owner, state.closed and "closed" or self.__bo3FanBack ~= owner and "marker"
                or owner.index ~= index and "controller" or not ok and "shape_error" or reason)
        else
            if owner.probe then
                owner.probe.slot = context and context.slot or owner.probe.slot
                owner.probe.root_seq = context and context.root_seq or owner.probe.root_seq
                for _, hook in ipairs(owner.probe.hooks) do
                    if hook.node[hook.key] ~= hook.wrapper then stop_fan_probe(owner, "setter_replaced");break end
                end
            end
            fan_sample(self, index, owner, context, context and context.stage or "refresh", "owned")
        end
        return self
    end
    local ok, intact, reason = pcall(fan_shape, self)
    local valid_index = type(index) == "number" and index >= 0 and index <= 3 and index == math.floor(index)
    if state.closed or retired_fans[self] or self.__bo3FanBack ~= nil
        or not valid_index or not ok or not intact then
        reason = state.closed and "closed" or retired_fans[self] and "retired" or self.__bo3FanBack ~= nil and "foreign_marker"
            or not valid_index and "controller" or not ok and "shape_error" or reason
        fan_sample(self, index, nil, context, "skipped", reason);return self
    end
    local view = panel("BO3FanRim", 237, 332)
    -- Keep the lifetime/ownership anchor, but create no decorative contour.
    -- Five pale bars per fan used to sit above both original images, so an
    -- overlay-width change could never alter those contours. Native backs,
    -- depth tint and every parent pose/count/selection sequence remain live.
    local rims = {}
    local back_material, overlay_material = RegisterMaterial("white"), RegisterMaterial("white")
    self.fanCard:setImage(back_material, 0)
    self.fanCard:SetRGBFromInt(0x171713, 0)
    self.fanOverlay:setImage(overlay_material, 0)
    rect(self.fanCard, 20.5, 212.5, 80, 432)
    -- Keep native depth tint/alpha on a narrow inset, rather than washing the
    -- entire dark back gray. All count/selection/empty poses stay on the parent.
    rect(self.fanOverlay, 24.5, 32.5, 84, 428)
    self:addElement(view)
    owner = {view=view, rims=rims, back=self.fanCard, overlay=self.fanOverlay, index=index,
        backMaterial=back_material, overlayMaterial=overlay_material}
    view.__bo3FanLifetime = owner
    self.__bo3FanBack = owner;fan_views[self] = owner
    local hooked
    if fan_diagnostics[self] or fan_diagnostic_count < 16 then hooked = install_fan_probe(self, owner) end
    if owner.probe then owner.probe.slot = context and context.slot;owner.probe.root_seq = context and context.root_seq end
    fan_sample(self, index, owner, context, "applied", hooked and "writes_returned" or owner.probe and "probe_hook_error" or "probe_limit")
    return self
end
local identity_keys = {"name", "icon", "backing", "rarity"}
local function selected_card_models()
    local z = DataSources and DataSources.inGame and DataSources.inGame.CP and DataSources.inGame.CP.zombies
    if not z then return nil end
    return {name=z.consumableDeckSelectName, icon=z.consumableDeckSelectIcon,
        backing=z.consumableDeckSelectBacking, rarity=z.consumableDeckSelectRarity}
end
local function selected_card_value(models, index)
    if not models then return nil, "models_missing" end
    local values = {}
    for _, key in ipairs(identity_keys) do
        local model = models[key]
        if not model then return nil, key .. "_reader" end
        local ok, value = pcall(function() return model.GetValue and model:GetValue(index) end)
        if not ok or type(value) ~= "string" then return nil, key .. "_value" end
        values[key] = value
    end
    if values.name == "" or values.icon == "" then return nil, "identity_empty" end
    -- Exact CardBacking/CardRarity pairs in the pinned retail loot master.
    -- A backing class is not the selected card's name, effect or readiness.
    if values.backing == "zm_wc_fate_card_base" and values.rarity == "" then
        values.family = "FATE"
    elseif values.backing == "zm_wc_fortune_card_base" and
        (values.rarity == "common" or values.rarity == "rare" or values.rarity == "legendary" or values.rarity == "epic") then
        values.family = "FORTUNE"
    else return nil, "backing_rarity_pair" end
    return values
end
local function identity_trace(self, index, stage, reason, value)
    local record = state.identityDiagnostics[self]
    if not record then
        state.nextIdentityDiagnostic = state.nextIdentityDiagnostic + 1
        record = {sequence=state.nextIdentityDiagnostic, count=0};state.identityDiagnostics[self] = record
    end
    local signature = stage .. ":" .. reason .. ":" .. (value and value.family or "unknown") .. ":" .. (value and value.rarity or "unknown")
    if record.signature == signature or record.count > 32 then return end
    record.signature = signature;record.count = record.count + 1
    if record.count == 33 then stage, reason, value = "suppressed", "transition_limit", nil end
    -- Optional, bounded branch evidence. No raw name/icon, native render ID,
    -- sampled alpha or claim that the native name/icon are currently visible.
    print("[BO3 HUD] identity version=" .. DIAGNOSTIC_VERSION .. " widget_seq=" .. record.sequence
        .. " controller=" .. token(index) .. " stage=" .. stage .. " reason=" .. reason
        .. " family=" .. (value and value.family or "unknown") .. " rarity=" .. token(value and value.rarity or "unknown")
        .. " pixels=unverified instance=" .. state.instance)
end
local function native_card_identity(owner)
    owner.mask:SetAlpha(1, 0);owner.view:SetAlpha(0, 0);owner.mode = "native"
end
local function style_card_identity(self, index)
    if not self then return self end
    local models, owner = selected_card_models(), self.__bo3CardIdentity
    if owner then
        if owner.index ~= index then owner.disabled = true end
        owner.update();return self
    end
    if type(index) ~= "number" or index < 0 or index > 3 or index ~= math.floor(index) then
        identity_trace(self, index, "native", "controller");return self
    end
    local leaves = {self.cardBack, self.name, self.icon}
    local child = self.getFirstChild and self:getFirstChild()
    for i=1,3 do
        if not child or child ~= leaves[i] or not child.getParent or not child.getNextSibling or child:getParent() ~= self then
            identity_trace(self, index, "native", "shape");return self
        end
        child = child:getNextSibling()
    end
    if child then identity_trace(self, index, "native", "shape");return self end
    local value, reason = selected_card_value(models, index)
    if not value then identity_trace(self, index, "native", reason);return self end
    local pointers = {}
    for _, key in ipairs(identity_keys) do
        local ok, pointer = pcall(function() return models[key].GetModel and models[key]:GetModel(index) end)
        if not ok or not pointer then identity_trace(self, index, "native", key .. "_pointer");return self end
        pointers[key] = pointer
    end
    local mask, view = panel("BO3NativeSelectedBacking", 155, 203), panel("BO3SelectedIdentity", 155, 203)
    mask:SetAnchorsAndPosition(0, 0, 0, 0, 0, 0, 0, 0);view:SetAnchorsAndPosition(0, 0, 0, 0, 0, 0, 0, 0)
    bar(view, "BO3SelectedSurface", 0, 177, -75, -37, 0x171713)
    bar(view, "BO3SelectedTop", 0, 177, -75, -73, 0xA49E8B)
    bar(view, "BO3SelectedBottom", 0, 177, -39, -37, 0xA49E8B)
    local family = text(view, "BO3SelectedFamily", 20, 8, 96, -68, -44)
    local rarity = text(view, "BO3SelectedRarity", 14, 100, 169, -65, -47, 0xA49E8B)
    family:SetAlignment(LUI.Alignment.Center);rarity:SetAlignment(LUI.Alignment.Center)
    -- The new header is outside both native name/icon position variants.
    -- Keep their objects, fonts, bounds, alpha/color sequences and field refs.
    reparent(self.cardBack, mask)
    self:removeElement(self.name);self:removeElement(self.icon)
    self:addElement(mask);self:addElement(view);self:addElement(self.name);self:addElement(self.icon)
    owner = {mask=mask, view=view, family=family, rarity=rarity, index=index, models=models, leaves=leaves}
    owner.update = function()
        local current_models = selected_card_models()
        local same = current_models and mask:getParent() == self and view:getParent() == self
            and self.cardBack == leaves[1] and leaves[1]:getParent() == mask
            and self.name == leaves[2] and leaves[2]:getParent() == self and self.icon == leaves[3] and leaves[3]:getParent() == self
        for _, key in ipairs(identity_keys) do same = same and current_models[key] == models[key] end
        if not same then owner.disabled = true end
        if state.closed or owner.disabled then
            identity_trace(self, index, "native", state.closed and "closed" or "ownership");native_card_identity(owner);return
        end
        local value, reason = selected_card_value(models, index)
        if not value then identity_trace(self, index, "native", reason);native_card_identity(owner);return end
        family:setText(value.family);rarity:setText(string.upper(value.rarity));rarity:SetAlpha(value.rarity == "" and 0 or 1, 0)
        mask:SetAlpha(0, 0);view:SetAlpha(1, 0);owner.mode = value.family
        identity_trace(self, index, "custom", "known_pair", value)
    end
    self.__bo3CardIdentity = owner;state.cardIdentities[self] = owner
    for _, pointer in pairs(pointers) do view:SubscribeToModel(pointer, owner.update) end
    owner.update()
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
    -- Retail initializes this integer to-1 and pulses20 during HUD refresh.
    -- Only0/1 have known ready-state meaning; other legal integers are local
    -- UNKNOWN status, not a veto on the independently known count/boss view.
    if type(ready) ~= "number" or ready < -1 or ready > 30 or ready ~= math.floor(ready) then
        return nil, "ready_value", observed
    end
    local boss = 0
    if dlc4 then boss = read("boss") end
    if boss ~= 0 and boss ~= 1 then return nil, "boss_value", observed end
    return {remaining=remaining, fill=fill, ready=ready, boss=boss == 1, dlc4=dlc4}, nil, observed
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
local function card_canvas(id)
    local result = panel(id, 168, 173)
    result:SetAnchorsAndPosition(0, 0, 0, 0, 0, 0, 0, 0)
    return result
end
local card_native_order = {"Circle", "blueGlow", "radialAlphaLarge", "innerRing", "outerRing", "glowRing", "devilJaw", "devilHead", "sadDevil"}
local function card_gauge_shape(self)
    if not self.getFirstChild then return false end
    -- One fixed canvas schema, not a descendant search. Unknown/additional or
    -- reordered children keep their original gauge and sibling relationships.
    local child = self:getFirstChild()
    for _, key in ipairs(card_native_order) do
        if not child or child ~= self[key] or not child.getParent or not child.getNextSibling
            or child:getParent() ~= self then return false end
        child = child:getNextSibling()
    end
    return child == nil
end
local function build_card_layers(self, faces, view)
    local mask = card_canvas("BO3NativeCardFaces")
    local face_parent, gauge = self, nil
    if card_gauge_shape(self) then
        local canvas = card_canvas("BO3NativeCardCanvas")
        local backing = card_canvas("BO3NativeCardBacking")
        local meter = card_canvas("BO3NativeCardMeter")
        local presentation = card_canvas("BO3CardGauge")
        view:addElement(presentation)
        -- Original angular frame/rail, made from the existing white material.
        -- Native ready/refill glows remain visible; no opaque cover is added.
        bar(presentation, "BO3GaugeTopLeft", -19.5, 20.5, -8, -5, 0xA49E8B)
        bar(presentation, "BO3GaugeTopRight", 148.5, 188.5, -8, -5, 0xA49E8B)
        bar(presentation, "BO3GaugeLeft", -19.5, -16.5, -5, 137, 0xA49E8B)
        bar(presentation, "BO3GaugeRight", 185.5, 188.5, -5, 137, 0xA49E8B)
        bar(presentation, "BO3GaugeBottom", -19.5, 188.5, 137, 140, 0xA49E8B)
        bar(presentation, "BO3ChargeTrack", 2.5, 166.5, 116, 124, 0x35352F)
        local fill = bar(presentation, "BO3ChargeFill", 2.5, 2.5, 116, 124, 0xA49E8B)
        presentation:SetAlpha(0, 0)
        gauge = {canvas=canvas, backing=backing, meter=meter, view=presentation, fill=fill, leaves={}}
        for _, key in ipairs(card_native_order) do gauge.leaves[key] = self[key] end
        -- Keep the exact native painter order and original field/animation
        -- references, including both unmasked native feedback objects.
        self:addElement(canvas)
        canvas:addElement(backing);reparent(self.Circle, backing)
        reparent(self.blueGlow, canvas)
        canvas:addElement(meter)
        for _, key in ipairs({"radialAlphaLarge", "innerRing", "outerRing"}) do reparent(self[key], meter) end
        reparent(self.glowRing, canvas)
        face_parent = canvas
    end
    face_parent:addElement(mask)
    for _, leaf in ipairs(faces) do reparent(leaf, mask) end
    return mask, gauge
end
local function native_card_gauge(owner)
    local gauge = owner.gauge
    if not gauge then return end
    gauge.backing:SetAlpha(1, 0);gauge.meter:SetAlpha(1, 0);gauge.view:SetAlpha(0, 0)
end
local function update_card_gauge(self, owner, value)
    local gauge = owner.gauge
    if not gauge then return end
    local same = gauge.canvas:getParent() == self and gauge.backing:getParent() == gauge.canvas
        and gauge.meter:getParent() == gauge.canvas and owner.mask:getParent() == gauge.canvas
        and gauge.view:getParent() == owner.view
    for _, key in ipairs(card_native_order) do
        local parent = key == "Circle" and gauge.backing
            or (key == "radialAlphaLarge" or key == "innerRing" or key == "outerRing") and gauge.meter
            or (key == "devilJaw" or key == "devilHead" or key == "sadDevil") and owner.mask or gauge.canvas
        same = same and self[key] == gauge.leaves[key] and gauge.leaves[key]:getParent() == parent
    end
    if not same then gauge.disabled = true end
    if gauge.disabled then native_card_gauge(owner);return end
    -- Read the same validated fill/controller as the native radial callback.
    -- Never SetProgress on the native object, write a model or infer readiness.
    rect(gauge.fill, 2.5, 2.5 + 164 * value.fill, 116, 124)
    gauge.fill:SetAlpha(value.remaining > 0 and value.fill > 0 and 1 or 0, 0)
    gauge.fill:SetRGBFromInt(value.ready == 1 and 0xF5F1E7 or 0xA49E8B, 0)
    gauge.backing:SetAlpha(0, 0);gauge.meter:SetAlpha(0, 0);gauge.view:SetAlpha(1, 0)
end
local update_card_decor
local function native_card_core(owner)
    owner.mask:SetAlpha(1, 0);owner.view:SetAlpha(0, 0);owner.mode = "native_unknown"
    native_card_gauge(owner)
    if update_card_decor then update_card_decor(owner, false) end
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
    local feeds, owner = card_feeds(), card_cores[self]
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
    if self.__bo3CardCore then return self end
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
    local view = card_canvas("BO3CardCore")
    local title = text(view, "BO3CardTitle", 20, 2.5, 166.5, 2, 26)
    local count = text(view, "BO3CardCount", 40, 34.5, 134.5, 32, 76)
    -- This is readiness metadata, never the selected card's name/effect.
    local status = text(view, "BO3CardStatus", 14, -9.5, 178.5, 84, 104, 0xA49E8B)
    title:SetAlignment(LUI.Alignment.Center);count:SetAlignment(LUI.Alignment.Center);status:SetAlignment(LUI.Alignment.Center)
    local mask, gauge = build_card_layers(self, faces, view)
    self:addElement(view)
    owner = {widget=self, mask=mask, view=view, gauge=gauge, index=index, feeds=feeds, required=required, dlc4=value.dlc4, title=title, count=count, status=status}
    owner.update = function()
        if self.__bo3CardCore ~= owner then owner.disabled = true;owner.disabledReason = "marker" end
        local current_feeds = card_feeds()
        for _, key in ipairs(required) do
            if not current_feeds or current_feeds[key] ~= feeds[key] then
                owner.disabled = true;owner.disabledReason = "feed_changed_" .. key
            end
        end
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
        status:setText(value.remaining == 0 and "EMPTY" or value.ready == 1 and "READY"
            or value.ready == 0 and "CHARGING" or "STATUS UNAVAILABLE")
        update_card_gauge(self, owner, value)
        owner.mode = value.boss and "boss" or "cards"
        if update_card_decor then update_card_decor(owner, true) end
        current.mode = owner.mode
        card_trace(self, index, "custom", value.boss and "boss" or value.remaining == 0 and "empty"
            or value.ready == 1 and "ready" or value.ready == 0 and "charging" or "unknown", current)
    end
    self.__bo3CardCore = owner;state.cardCores[self] = owner;card_cores[self] = owner
    view.__bo3CoreLifetime = owner
    -- Native image references and animations remain alive under a same-canvas
    -- ancestor. Only their rendering is masked while equivalent data is known.
    for _, pointer in pairs(pointers) do view:SubscribeToModel(pointer, owner.update) end
    owner.update()
    return self
end
local deck_order = {"Fire", "fanCard4", "fanCard3", "fanCard2", "fanCard1", "FateCardOnDeck", "Triangle", "FateCardDevilWidget", "upArrow", "downArrow"}
local function decor_shape(self, owner)
    local child = self.getFirstChild and self:getFirstChild()
    for _, key in ipairs(deck_order) do
        local leaf = self[key]
        local expected = owner and key == "Triangle" and owner.mask or leaf
        if not child or child ~= expected or not child.getParent or not child.getNextSibling
            or child:getParent() ~= self then return false end
        if owner and owner.leaves[key] ~= leaf then return false end
        child = child:getNextSibling()
    end
    local triangle = self.Triangle
    if child or not triangle or triangle.id ~= "Triangle" or not triangle.getFirstChild
        or triangle:getFirstChild() then return false end
    if owner then
        return triangle == owner.triangle and triangle:getParent() == owner.mask
            and owner.mask:getFirstChild() == triangle and not triangle:getNextSibling()
    end
    return triangle:getParent() == self
end
local function retire_card_decor(owner)
    if card_decor[owner.core] ~= owner or owner.retired then return end
    owner.retired = true;retired_decor[owner.widget] = true
    -- Only the captured mask still in our original canvas can be restored.
    -- A foreign parent/descendant is retained; no foreign tag is authority.
    if owner.mask:getParent() == owner.widget then
        owner.mask:SetAlpha(1, 0)
        if owner.widget.Triangle == owner.triangle and owner.triangle:getParent() == owner.mask then
            owner.mask:removeElement(owner.triangle);owner.triangle:addElementBefore(owner.mask)
        end
        if not owner.mask:getFirstChild() then owner.widget:removeElement(owner.mask);owner.mask:close() end
    end
    owner.mask.__bo3DecorLifetime = nil
end
update_card_decor = function(core, custom)
    local owner = card_decor[core]
    if not owner or owner.retired then return end
    if state.closed or owner.widget.__bo3CardDecor ~= owner or not decor_shape(owner.widget, owner)
        or card_cores[core.widget] ~= core or core.widget.__bo3CardCore ~= core
        or core.view:getParent() ~= core.widget then
        retire_card_decor(owner);return
    end
    owner.mask:SetAlpha(custom and not core.disabled and core.gauge and not core.gauge.disabled and 0 or 1, 0)
end
local function style_card_decor(self)
    if not self or retired_decor[self] then return end
    local core = self.FateCardDevilWidget and card_cores[self.FateCardDevilWidget]
    if not core then return end
    if card_decor[core] then update_card_decor(core, core.mode == "cards" or core.mode == "boss");return end
    if self.__bo3CardDecor or not core.gauge or core.gauge.disabled or core.disabled
        or not decor_shape(self) or not self.Triangle.addElementBefore then return end
    local mask = panel("BO3NativeCardDecor", 253, 389)
    mask:SetAnchorsAndPosition(0, 0, 0, 0, 0, 0, 0, 0)
    if not mask.addElementBefore then mask:close();return end
    local owner = {widget=self, core=core, mask=mask, triangle=self.Triangle, leaves={}}
    for _, key in ipairs(deck_order) do owner.leaves[key] = self[key] end
    mask:addElementBefore(self.Triangle);reparent(self.Triangle, mask)
    card_decor[core] = owner;self.__bo3CardDecor = owner;mask.__bo3DecorLifetime = owner
    update_card_decor(core, core.mode == "cards" or core.mode == "boss")
end
local function adapt_bottom(original, menu, args, root_context)
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
            if fan then style_fan(fan, controller_index(self, args), {stage="deck", slot=i, root_seq=root_context and root_context.root_seq}) end
        end
        if self.FateCardWidget.FateCardOnDeck then
            style_card_identity(self.FateCardWidget.FateCardOnDeck, controller_index(self, args))
        end
        if self.FateCardWidget.FateCardDevilWidget then
            style_card_core(self.FateCardWidget.FateCardDevilWidget, controller_index(self, args))
        end
        style_card_decor(self.FateCardWidget)
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
local action_shapes = {
    ReviveBarContainer = true,
    ReviveBarContainerDLC1 = false,
    ReviveBarContainerDLC2 = false,
    ReviveBarContainerDLC3 = false,
    ReviveBarContainerDLC4 = false
}
local function action_shape(self, owner)
    local background = self and action_shapes[self.id]
    if background == nil or not (self.Accent and self.Header and self.Header.MessageText
        and self.ProgressBar and self.ProgressBar.Fill and self.ProgressBar.Mask)
        or type(self.SetHeader) ~= "function" or type(self.ProgressBar.SetProgress) ~= "function" then return false end
    -- Pinned outer order differs on the base map. The original accent is
    -- already behind the native label/bar: an owned child needs no native
    -- reparenting, unproven insert/depth API or replacement progress feed.
    local expected = {self.Accent, self.Header}
    if background then
        if not self.Background or not self.Header.Background then return false end
        expected[#expected + 1] = self.Background
    end
    expected[#expected + 1] = self.ProgressBar
    local child = self:getFirstChild()
    for _, leaf in ipairs(expected) do
        if child ~= leaf or leaf:getParent() ~= self then return false end
        child = child:getNextSibling()
    end
    if child then return false end
    local header_children = background and {self.Header.Background, self.Header.MessageText} or {self.Header.MessageText}
    child = self.Header:getFirstChild()
    for _, leaf in ipairs(header_children) do
        if child ~= leaf or leaf:getParent() ~= self.Header then return false end
        child = child:getNextSibling()
    end
    if child or self.ProgressBar:getFirstChild() ~= self.ProgressBar.Fill
        or self.ProgressBar.Fill:getParent() ~= self.ProgressBar
        or self.ProgressBar.Fill:getNextSibling() ~= self.ProgressBar.Mask
        or self.ProgressBar.Mask:getParent() ~= self.ProgressBar
        or self.ProgressBar.Mask:getNextSibling() then return false end
    child = self.Accent:getFirstChild()
    return owner and child == owner.view and child:getNextSibling() == nil or not owner and child == nil
end
local function retire_action(self, owner)
    if action_views[self] ~= owner then return end
    retired_actions[self] = true
    owner.retired = true
    owner.view:SetAlpha(0, 0)
    -- A foreign parent/child is never moved back or removed. Only our view
    -- under the captured accent is disposed; all native fields stay intact.
    if owner.view:getParent() == owner.accent then
        owner.accent:removeElement(owner.view)
        owner.view:close()
    end
    owner.view.__bo3ActionLifetime = nil
end
local function style_action(self, index)
    if not self then return end
    local owner = action_views[self]
    if owner then
        if owner.retired then return end
        local ok, intact = pcall(function()
            return self.id == owner.id and self.Accent == owner.accent
                and self.Header == owner.header and self.Header.MessageText == owner.label
                and self.ProgressBar == owner.progress and self.ProgressBar.Fill == owner.fill
                and self.ProgressBar.Mask == owner.mask and self.SetHeader == owner.setHeader
                and self.ProgressBar.SetProgress == owner.setProgress and action_shape(self, owner)
        end)
        if state.closed or self.__bo3ActionView ~= owner or owner.index ~= index or not ok or not intact then
            retire_action(self, owner)
        end
        return not owner.retired
    end
    local ok, shape = pcall(action_shape, self)
    if state.closed or retired_actions[self] or self.__bo3ActionView ~= nil
        or type(index) ~= "number" or index < 0 or index > 3 or index ~= math.floor(index)
        or not ok or not shape then return end
    local view = panel("BO3ActionView", 256, 64)
    view:SetAnchorsAndPosition(0, 0, 0, 0, 0, 0, 0, 0)
    local surface = bar(view, "BO3ActionSurface", 0, 0, 0, 0, 0x171713)
    surface:SetAnchorsAndPosition(0, 0, 0, 0, 0, 0, 0, 0)
    local top = bar(view, "BO3ActionTop", 0, 0, 0, 2, 0xA49E8B)
    top:SetAnchorsAndPosition(0, 0, 0, 1, 0, 0, 0, scale(2))
    local bottom = bar(view, "BO3ActionBottom", 0, 0, -2, 0, 0xA49E8B)
    bottom:SetAnchorsAndPosition(0, 0, 1, 0, 0, 0, scale(-2), 0)
    local left = bar(view, "BO3ActionLeft", 0, 3, 0, 0, 0xA49E8B)
    left:SetAnchorsAndPosition(0, 1, 0, 0, 0, scale(3), 0, 0)
    self.Accent:addElement(view)
    owner = {id=self.id, view=view, accent=self.Accent, header=self.Header, label=self.Header.MessageText,
        progress=self.ProgressBar, fill=self.ProgressBar.Fill, mask=self.ProgressBar.Mask,
        setHeader=self.SetHeader, setProgress=self.ProgressBar.SetProgress, index=index}
    view.__bo3ActionLifetime = owner
    self.__bo3ActionView = owner;action_views[self] = owner
    -- Native Accent alpha/Show/Hide owns the entire underlay. Keep the actual
    -- label, measured header, fill material/geometry/stencil, state/progress
    -- callbacks and original child order. No copied title, %, target or clock.
    return true
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
        if style_action(revive, root.controllerIndex) then
            root.reviveBarContainer:SetAnchorsAndPosition(0.5, 0.5, 0.5, 0.5, scale(-128), scale(128), scale(60), scale(124))
            revive.Header.MessageText:SetRGBFromInt(0xF5F1E7, 0)
            revive.ProgressBar.Fill:SetRGBFromInt(0xA49E8B, 0)
        end
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
    adapt_bottom(function() return bottom end, nil, {controllerIndex=root.controllerIndex}, {root_seq=state.roots[root]})
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
    FateFanCard = function(original, menu, args)
        return style_fan(remember(original(menu, args)), controller_index(menu, args), {stage="factory"})
    end,
    FateCardOnDeck = function(original, menu, args)
        local self = remember(original(menu, args))
        return style_card_identity(self, controller_index(self, args))
    end,
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
    for self, owner in pairs(fan_views) do retire_fan(self, owner) end
    for self, owner in pairs(action_views) do retire_action(self, owner) end
    for _, owner in pairs(card_cores) do native_card_core(owner) end
    for _, owner in pairs(card_decor) do retire_card_decor(owner) end
    for _, owner in pairs(state.cardIdentities) do native_card_identity(owner) end
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
