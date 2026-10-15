"""Execute the authored Lua adapter with explicit mock UI/models, never a game."""
from pathlib import Path
import argparse
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--lua-runtime", type=Path, required=True)
args = parser.parse_args()
sys.path.insert(0, str(args.lua_runtime))
from lupa.lua51 import LuaRuntime

root = Path(__file__).resolve().parents[2]
source = (root / "src/ui_scripts/bo3_zombies_hud/__init__.lua").read_text(encoding="utf-8-sig")
lua = LuaRuntime()
setup = r'''
_1080p=1
config={}; frontend=true; aliens=false; profileText=""; ui_root=nil; pending={}; originals=0; nodes={}; models={}
Engine={GetDvarString=function(name) return config[name] or "" end,
 InFrontend=function() return frontend end, IsAliensMode=function() return aliens end,
 GetLuiRoot=function() return ui_root end, Localize=function(value) return value end}
profilePayload="set bo3_zombies_hud_enable 1\nset bo3_zombies_hud_private 1\n"
io={readfile=function(path) assert(path=="iw7-mod/bo3_zombies_hud_lab.cfg");return profileText end}
scheduler={once=function(fn) pending[#pending+1]=fn end}
FONTS={MainBold={File="stock-bold"},GetFont=function(value) return value end}
SWATCHES={HUD={warning={r=1,g=0.25,b=0}}}
RegisterMaterial=function(value) return value end
function node()
 local n={children={},alpha=1,closed=false}
 function n:SetAnchorsAndPosition(...) self.bounds={...} end
 function n:SetFont(value) self.font=value end
 function n:SetFontSize(value) self.size=value end
 function n:SetAlignment(value) end
 function n:SetRGBFromInt(value) self.color=value end
 function n:SetRGBFromTable(value) self.color=value end
 function n:SetYRotation(value) self.yrotation=value end
 function n:SetZRotation(value) self.zrotation=value end
 function n:SetScale(value) self.scale=value end
 function n:SetAlpha(value) self.alpha=value end
 function n:setText(value) self.text=value end
 function n:setImage(value) self.image=value end
 function n:setEndTime(value) self.endTime=value end
 function n:addElement(child) self.children[#self.children+1]=child;child.parent=self end
 function n:removeElement(child)
  child.detached=true;child.parent=nil
  for i,v in ipairs(self.children) do if v==child then table.remove(self.children,i);break end end
 end
 function n:getFirstChild() return self.children[1] end
 function n:getParent() return self.parent end
 function n:getNextSibling()
  if not self.parent then return nil end
  for i,v in ipairs(self.parent.children) do if v==self then return self.parent.children[i+1] end end
 end
 function n:getFirstDescendentById(id)
  for _,v in ipairs(self.children) do if v.id==id then return v end;local nested=v:getFirstDescendentById(id);if nested then return nested end end
 end
 function n:getRootController() return 0 end
 function n:SubscribeToModel(model,fn) model.listeners[#model.listeners+1]=fn end
 function n:BindAlphaToModel(model) self:SubscribeToModel(model,function() self.alpha=model.value end); self.alpha=model.value end
 function n:GetDataSource() return self.data end
 function n:SubscribeToModelThroughElement(parent,key,fn) self.through=fn end
 function n:close() self.closed=true end
 nodes[#nodes+1]=n
 return n
end
LUI={UIElement={new=node},UIText={new=node},UIImage={new=node},Alignment={Left=0},
 HudManager={CreateHud=function(self) self.activeHud=self.nextHud;return "retained",nil,7 end}}
function model(path,value)
 local m={value=value,listeners={},indices={}}
 function m:GetModel(index) return self end
 function m:GetValue(index) self.indices[#self.indices+1]=index; return self.value end
 function m:set(value) self.value=value; for _,fn in ipairs(self.listeners) do fn() end end
 local parts={}; for p in string.gmatch(path,"[^.]+") do parts[#parts+1]=p end
 local t=DataSources
 for i=1,#parts-1 do t[parts[i]]=t[parts[i]] or {}; t=t[parts[i]] end
 t[parts[#parts]]=m; models[path]=m; return m
end
DataSources={}
function original(key,args)
 originals=originals+1
 local n=node(); n.id="stock:"..key
 if string.find(key,"MainPlayerInfo") then
  n.PlayerIcon=node(); n.PlayerIcon.image="actual-iw7-character"; n.PlayerCash=node(); n.PlayerCash.text="4270"
  if models["inGame.CP.currentPlayerCash"] then
   n.PlayerCash:SubscribeToModel(models["inGame.CP.currentPlayerCash"],function() n.PlayerCash:setText(models["inGame.CP.currentPlayerCash"].value) end)
  end
  n.box=node(); n.dollarSign=node(); n.questFuse=node(); n:addElement(n.questFuse)
 end
 if key=="ZomPowerupIcon" then
  if badPowerupOnce then badPowerupOnce=false;partialPowerup=n;return n end
  n.PowerupIcon=node();n:addElement(n.PowerupIcon);n.PowerupIcon.image="retail-powerup";n.PowerupIcon.alpha=0
  n.NativeFlash=function() n.PowerupIcon:SetAlpha(0) end
 end
 if key=="FateFanCard" then
  n.fanCard=node();n.fanCard.image="zm_wc_card_fan";n:addElement(n.fanCard)
  n.fanOverlay=node();n.fanOverlay.image="zm_wc_card_fan_overlay";n.fanOverlay.color=0x263626;n.fanOverlay.alpha=0.6;n:addElement(n.fanOverlay)
 end
 return n
end
MenuBuilder={BuildRegisteredType=original}
function tick() local fn=table.remove(pending,1); if fn then fn() end end
function child(n,id) for _,v in ipairs(n.children) do if v.id==id then return v end end end
'''
lua.execute(setup)
lua.execute(source)
checks = 0
def check(code):
    global checks
    lua.execute("assert(" + code + ")")
    checks += 1

lua.execute("tick()")
check("MenuBuilder.BuildRegisteredType==original")
lua.execute('config.bo3_zombies_hud_enable="1";config.bo3_zombies_hud_private="1";config.ui_gametype="zombie";tick()')
check("MenuBuilder.BuildRegisteredType==original")
lua.execute('profileText=profilePayload.."extra";tick()')
check("MenuBuilder.BuildRegisteredType==original")
lua.execute('profileText=profilePayload')
lua.execute("tick()")
check("MenuBuilder.BuildRegisteredType~=original")
lua.execute("saved=MenuBuilder.BuildRegisteredType;queued=#pending")
lua.execute(source)
check("MenuBuilder.BuildRegisteredType==saved and #pending==queued")
lua.execute('w=MenuBuilder.BuildRegisteredType("WaveNumber",{controllerIndex=1})')
check('w.id=="stock:WaveNumber"')
lua.execute('frontend=false; config.ui_gametype="war";w=MenuBuilder.BuildRegisteredType("WaveNumber",{controllerIndex=1})')
check('w.id=="stock:WaveNumber"')
lua.execute('aliens=true;config.ui_gametype="zombie";model("inGame.CP.zombies.waveNumber",17);w=MenuBuilder.BuildRegisteredType("WaveNumber",{controllerIndex=1})')
check('w.__bo3HudReplacement=="WaveNumber"')
check('w.BO3RoundNumber.text=="17"')
check('models["inGame.CP.zombies.waveNumber"].indices[1]==1')
lua.execute('models["inGame.CP.zombies.waveNumber"]:set(18)')
check('w.BO3RoundNumber.text=="18"')
lua.execute('models["inGame.CP.zombies.waveNumber"]:set(nil)')
check('w.BO3RoundNumber.text==""')
lua.execute('w=MenuBuilder.BuildRegisteredType("weaponinfoZM",{controllerIndex=1})')
check('w.id=="stock:weaponinfoZM" and BO3ZombiesHUD.failures==1')
lua.execute('''
model("inGame.player.currentWeapon.clipAmmoRightDisplay","12")
model("inGame.player.currentWeapon.clipAmmoLeftDisplay","11")
model("inGame.player.currentWeapon.stockAmmoDisplay","48")
model("inGame.player.currentWeapon.stockAmmo",48)
model("inGame.player.currentWeapon.displayNameMultiline","ACTUAL PAP NAME")
model("inGame.player.currentWeapon.altModeDisplayName","ACTUAL ALT MODE")
model("inGame.player.currentWeapon.ammoInfoAlpha",1)
model("inGame.player.currentWeapon.ammoReserveAlpha",1)
model("inGame.player.currentWeapon.isDualWielding",false)
model("inGame.player.currentWeapon.isMeleeWeapon",false)
a=MenuBuilder.BuildRegisteredType("weaponinfoZM",{controllerIndex=1})
''')
check('child(a,"BO3ClipRight").text=="12" and child(a,"BO3Reserve").text=="48"')
check('child(a,"BO3WeaponName").text=="ACTUAL PAP NAME"')
check('child(a,"BO3AltMode").text=="ACTUAL ALT MODE"')
lua.execute('models["inGame.player.currentWeapon.altModeDisplayName"]:set("NEXT ALT MODE")')
check('child(a,"BO3AltMode").text=="NEXT ALT MODE"')
check('child(a,"BO3ClipLeft").alpha==0')
lua.execute('models["inGame.player.currentWeapon.isDualWielding"]:set(true)')
check('child(a,"BO3ClipLeft").alpha==1')
lua.execute('models["inGame.player.currentWeapon.isMeleeWeapon"]:set(nil)')
check('child(a,"BO3ClipLeft").alpha==0')
lua.execute('models["inGame.player.currentWeapon.isMeleeWeapon"]:set(false)')
check('child(a,"BO3ClipLeft").alpha==1')
lua.execute('models["inGame.player.currentWeapon.isDualWielding"]:set(nil)')
check('child(a,"BO3ClipLeft").alpha==0')
lua.execute('models["inGame.player.currentWeapon.isDualWielding"]:set(true)')
check('child(a,"BO3ClipLeft").alpha==1')
lua.execute('models["inGame.player.currentWeapon.isMeleeWeapon"]:set(true)')
check('child(a,"BO3ClipLeft").alpha==0')
lua.execute('models["inGame.player.currentWeapon.clipAmmoRightDisplay"]:set("0")')
check('child(a,"BO3ClipRight").text=="0"')
lua.execute('models["inGame.player.currentWeapon.ammoReserveAlpha"]:set(0)')
check('child(a,"BO3Reserve").alpha==0')
lua.execute('p=MenuBuilder.BuildRegisteredType("CPPerkIcon",{controllerIndex=1});p.data={icon={GetValue=function() return "actual_iw7_perk" end}};p.PerkIcon.through()')
check('p.PerkIcon.image=="actual_iw7_perk" and p.PerkIcon.alpha==1')
lua.execute('p.data={icon={GetValue=function() return nil end}};p.PerkIcon.through()')
check('p.PerkIcon.alpha==0')
lua.execute('p=MenuBuilder.BuildRegisteredType("MainPlayerInfo",{controllerIndex=1})')
check('p.PlayerIcon.image=="actual-iw7-character" and p.PlayerCash.text=="4270"')
check('p.questFuse and not p.questFuse.detached')
check('p.box.detached and p.dollarSign.detached')
lua.execute('before=originals;r=MenuBuilder.BuildRegisteredType("ReviveBarContainer",{controllerIndex=1})')
check('r.id=="stock:ReviveBarContainer" and originals==before+1')
lua.execute('profileText="set bo3_zombies_hud_enable 0\\nset bo3_zombies_hud_private 1\\n";r=MenuBuilder.BuildRegisteredType("WaveNumber",{controllerIndex=1})')
check('r.id=="stock:WaveNumber"')
lua.execute('BO3ZombiesHUD.shutdown()')
check('MenuBuilder.BuildRegisteredType==original')
lua.execute('config.bo3_zombies_hud_enable="1";r=saved("WaveNumber",{controllerIndex=1})')
check('r.id=="stock:WaveNumber"')
for forbidden in ("cg_draw2D", "SetDvar", ":SetValue(", "setweapon", "PlayerHealth"):
    assert forbidden not in source, forbidden
checks += 1
lua = LuaRuntime()
lua.execute(setup)
lua.execute(r'''
printed={};print=function(message) printed[#printed+1]=message end
frontend=false;aliens=true;profileText=profilePayload -- raw engine flags remain unregistered/empty
model("inGame.CP.zombies.waveNumber",21)
model("inGame.player.currentWeapon.clipAmmoRightDisplay","12")
model("inGame.player.currentWeapon.clipAmmoLeftDisplay","11")
model("inGame.player.currentWeapon.stockAmmoDisplay","48")
model("inGame.player.currentWeapon.stockAmmo",48)
model("inGame.player.currentWeapon.displayNameMultiline","REAL NAME")
model("inGame.player.currentWeapon.ammoInfoAlpha",1)
model("inGame.player.currentWeapon.ammoReserveAlpha",1)
model("inGame.player.currentWeapon.isDualWielding",false)
model("inGame.player.currentWeapon.isMeleeWeapon",false)
function stock_text(parent,id,path)
 local n=node();n.id=id;parent:addElement(n)
 local m=models[path];n:SubscribeToModel(m,function() n.text=tostring(m.value) end);n.text=tostring(m.value)
 return n
end
function stock_ability(parent,prefix,index)
 local ability=node();ability.AbilityIcon=node();ability.PlayerAbilityWarning=node()
 ability:addElement(ability.AbilityIcon);ability:addElement(ability.PlayerAbilityWarning)
 parent:addElement(ability);parent[prefix.."Ability"]=ability
 local quantity=node();parent:addElement(quantity);parent[prefix.."AbilityQuantity"]=quantity
 local path="inGame.player."..string.lower(prefix).."Power."
 local function update()
  ability.alpha=models[path.."iconAlpha"]:GetValue(index)
  ability.AbilityIcon.image=models[path.."icon"]:GetValue(index)
  quantity.text=models[path.."numCharges"]:GetValue(index)
  quantity.alpha=models[path.."numAlpha"]:GetValue(index)
  quantity.color=models[path.."color"]:GetValue(index)
 end
 for _,key in ipairs({"iconAlpha","icon","numCharges","numAlpha","color"}) do ability:SubscribeToModel(models[path..key],update) end
 update()
end
function stock_status(r,index)
 r.activePowerups=node();r.activePowerups._widget=node()
 r.activePowerups._widget.ZomPowerupWidget=node()
 r.powerupActivated=node();r.powerupActivated._widget=node()
 r.powerupActivated._widget.PowerUpName=node();r.powerupActivated._widget.PowerUpIcon=node()
 r.powerupActivated._widget.NativeMessage=function(name,image)
  r.powerupActivated._widget.PowerUpName.text=name;r.powerupActivated._widget.PowerUpIcon.image=image
 end
 r.reviveBarContainer=node();local revive=node();r.reviveBarContainer._widget=revive
 revive.Header=node();revive.Header.MessageText=node();revive.ProgressBar=node()
 revive.ProgressBar.Fill=node();revive.ProgressBar.Mask=node()
 revive.SetHeader=function(self,value) self.Header.MessageText:setText(value) end
 revive.ProgressBar.SetProgress=function(self,value) self.Mask:SetAnchorsAndPosition(0,1-value,0,0,0,0,0,0) end
 local function state()
  local value=models["inGame.CP.zombies.secureState"]:GetValue(index)
  revive.visible=value~=0;revive.alpha=revive.visible and 1 or 0
  revive:SetHeader(value==3 and "REVIVING" or value==21 and "SKEEBALL" or "")
 end
 revive:SubscribeToModel(models["inGame.CP.zombies.secureState"],state);state()
 revive.ProgressBar:SubscribeToModel(models["inGame.CP.zombies.secureProgress"],function()
  revive.ProgressBar:SetProgress(models["inGame.CP.zombies.secureProgress"]:GetValue(index))
 end)
 r.retainedSetHeader=revive.SetHeader;r.retainedSetProgress=revive.ProgressBar.SetProgress
 r.lastStand=node();r.lastStand._widget=node();local timerParent=node();timerParent.alpha=0
 r.lastStand._widget:addElement(timerParent)
 local countdown=node();countdown.id="laststand_countdown";timerParent:addElement(countdown)
 local icon=node();icon.id="laststand_icon";icon.image="alien_icon_laststand";timerParent:addElement(icon)
 r.omnvarHandlers={["zm_ui_laststand_end_milliseconds"]=function(value)
  if value>0 then countdown:setEndTime(value);timerParent.alpha=1 else timerParent.alpha=0 end
 end}
 r.nativeDownParent=timerParent;r.nativeCountdown=countdown
 r.afterlifeSelfReviveProgress=node();r.afterlifeSelfReviveProgress._widget=node()
 local afterlife=r.afterlifeSelfReviveProgress._widget
 afterlife.SoulPowerTitle=node();afterlife.ProgressBar=node();afterlife.ProgressBar.bounds={"full-width-native-progress"}
 afterlife.Message=node();afterlife.Message.MessageText=node()
 afterlife.NativeToken=function(value) afterlife.Message.MessageText:setText(value==1 and "NATIVE USE GLYPH" or "NATIVE SOUL POWER") end
 afterlife:SubscribeToModel(models["inGame.CP.zombies.afterlifeHasSelfReviveToken"],function() afterlife.NativeToken(models["inGame.CP.zombies.afterlifeHasSelfReviveToken"]:GetValue(index)) end)
end
function stock_hud(root_id,player_key,index)
 local r=node();r.id=root_id or "ZMHUD";r.controllerIndex=index or 1
 r.waveNumber=node();r.waveNumber.bounds={"full-screen-canvas"};r.waveNumber._widget=node()
 local wave=node();r.waveNumber._widget.WaveNumber=wave
 wave.waveNum=stock_text(wave,"waveNum","inGame.CP.zombies.waveNumber")
 wave.clapboard=node();wave:addElement(wave.clapboard);wave.Scene=node();wave:addElement(wave.Scene)
 r.activePerks=node();r.activePerks._widget={PerkList=node()}
 for i=1,2 do local icon=node();icon.PerkIcon=node();icon.PerkIcon.image="actual-perk-"..i;icon:addElement(icon.PerkIcon);r.activePerks._widget.PerkList:addElement(icon) end
 r.mainPlayerInfo=node();local player=node();r.mainPlayerInfo._widget=player
 local key=player_key or "MainPlayerInfo";local info=original(key,{controllerIndex=r.controllerIndex});player[key]=info;player:addElement(info)
 info:addElement(info.PlayerIcon);info:addElement(info.PlayerCash)
 local fuseKey=key=="MainPlayerInfoDLC3" and "FusesCopy" or key=="MainPlayerInfoDLC4" and "FusesCopyCopy0" or "Fuses"
 info[fuseKey]=node();info:addElement(info[fuseKey]);info[fuseKey].image="cp_zmb_sticker_fuse"
 info[fuseKey]:BindAlphaToModel(models["inGame.CP.zombies.quests.questFuseAlphaFilter"]);r.nativeFuse=info[fuseKey]
 if key=="MainPlayerInfoDLC1" or key=="MainPlayerInfoDLC3" or key=="MainPlayerInfoDLC4" then
  info.InventorySlot1=node();info:addElement(info.InventorySlot1)
  local icon=models["inGame.CP.zombies.HUDInventoryDLC1.hudInventory1Icon"]
  local function update() info.InventorySlot1.image=icon:GetValue(r.controllerIndex) end
  info.InventorySlot1:SubscribeToModel(icon,update);update()
  info.InventorySlot1:BindAlphaToModel(models["inGame.CP.zombies.HUDInventoryDLC1.hudInventory1Alpha"])
 end
 if key=="MainPlayerInfoDLC1" then
  info.RaveFill=node();info:addElement(info.RaveFill)
  info.RaveFill:SubscribeToModel(models["inGame.CP.zombies.dlc1.raveFill"],function() info.RaveFill.nativeBottom=models["inGame.CP.zombies.dlc1.raveFill"]:GetValue(r.controllerIndex) end)
 end
 if key=="MainPlayerInfo" then info.ZomTickets=node();info.ZomTickets.text="0";info:addElement(info.ZomTickets) end
 if key=="MainPlayerInfoDLC2" then info.chiStyle=node();info.chiStyle.image="native-chi-style";info:addElement(info.chiStyle) end
 if key=="MainPlayerInfoDLC3" then info.elementName=stock_text(info,"elementName","inGame.CP.zombies.dlc3.elementIndexNameFilter") end
 player.PlayerCash=node();player.PlayerCash.Players=node();player.PlayerCash:addElement(player.PlayerCash.Players);player:addElement(player.PlayerCash)
 function player.PlayerCash:RefreshRows()
  for _,shell in ipairs(self.Players.children) do
   local row=shell.children[1] or shell
   if row.RefreshRowContent then row:RefreshRowContent() end
  end
  return "rows",nil,9
 end
 r.retainedTeamRefresh=player.PlayerCash.RefreshRows
 r.wonderCard=node();local bottom=node();r.wonderCard._widget=bottom
 bottom.ZomWeaponInfo=node();local ammo=node();bottom.ZomWeaponInfo.weaponinfoZM=ammo
 ammo.TextRightClipAmmo=stock_text(ammo,"right","inGame.player.currentWeapon.clipAmmoRightDisplay")
 ammo.TextLeftClipAmmo=stock_text(ammo,"left","inGame.player.currentWeapon.clipAmmoLeftDisplay")
 ammo.TextStockAmmo=stock_text(ammo,"stock","inGame.player.currentWeapon.stockAmmoDisplay")
 ammo.TextStockAmmo:SubscribeToModel(models["inGame.player.currentWeapon.stockAmmo"],function()
  ammo.TextStockAmmo:SetRGBFromInt(models["inGame.player.currentWeapon.stockAmmo"].value<=0 and 0xFF8800 or 0x999999)
 end)
 ammo.box=node();ammo:addElement(ammo.box);ammo.bar=node();ammo:addElement(ammo.bar)
 ammo.weaponDescriptionZM=node();ammo.weaponDescriptionZM.TextWeaponName=node();ammo.weaponDescriptionZM.TextAltMode=node()
 ammo.weaponDescriptionZM.TextAltMode.text="actual-alt-mode"
 stock_ability(bottom.ZomWeaponInfo,"Primary",r.controllerIndex);stock_ability(bottom.ZomWeaponInfo,"Secondary",r.controllerIndex)
 bottom.ZomWeaponInfo.CraftedWeapon=node();bottom.ZomWeaponInfo.CraftedWeapon.ButtonFont=node();bottom.ZomWeaponInfo.CraftedWeapon:addElement(bottom.ZomWeaponInfo.CraftedWeapon.ButtonFont)
 bottom.ZomWeaponInfo.muleWeaponIndicator=node();bottom.ZomWeaponInfo.muleWeaponIndicator:BindAlphaToModel(models["inGame.CP.zombies.perks.muleMunchiesWeapIcon"])
 bottom.ZomWeaponInfo.UnlimitedAmmoIcon=node();bottom.ZomWeaponInfo.UnlimitedAmmoIcon:BindAlphaToModel(models["inGame.CP.ammo.unlimitedAlpha"])
 bottom.FateCardWidget=node()
 local deck=bottom.FateCardWidget
 for i=1,4 do deck["fanCard"..i]=original("FateFanCard",{controllerIndex=r.controllerIndex});deck:addElement(deck["fanCard"..i]) end
 deck.Fire=node();deck.upArrow=node();deck.FateCardOnDeck=node();deck.FateCardOnDeck.image="native-selected-card"
 deck:addElement(deck.Fire);deck:addElement(deck.upArrow);deck:addElement(deck.FateCardOnDeck)
 deck.nativeReadyCallback=function()
  local ready=models["inGame.CP.zombies.consumableDeckSelectReady"].value
  deck.Fire:SetAlpha(ready);deck.upArrow:SetAlpha(ready)
 end
 deck:SubscribeToModel(models["inGame.CP.zombies.consumableDeckSelectReady"],deck.nativeReadyCallback)
 deck.nativeReadyCallback()
 bottom.WonderCardFillWidget=node();bottom.WonderCardFillWidget.ToggleList0=node()
 bottom.WonderCardFillWidget.ToggleList0.image="native-active-card";bottom.WonderCardFillWidget:addElement(bottom.WonderCardFillWidget.ToggleList0)
 stock_status(r,r.controllerIndex)
 r.hints=node();r.cashEarned=node()
 return r
end
model("inGame.CP.currentPlayerCash",4270)
model("inGame.CP.zombies.consumableDeckSelectReady",0)
for _,prefix in ipairs({"primary","secondary"}) do
 local p="inGame.player."..prefix.."Power."
 model(p.."numCharges",4);model(p.."numAlpha",1);model(p.."iconAlpha",1);model(p.."icon","native-"..prefix);model(p.."color",0xFFAABB)
end
model("inGame.CP.zombies.secureState",0);model("inGame.CP.zombies.secureProgress",0)
model("inGame.CP.zombies.afterlifeHasSelfReviveToken",0)
model("inGame.CP.zombies.HUDInventoryDLC1.hudInventory1Icon","native-inventory")
model("inGame.CP.zombies.HUDInventoryDLC1.hudInventory1Alpha",0)
model("inGame.CP.zombies.quests.questFuseAlphaFilter",0)
model("inGame.CP.zombies.dlc1.raveFill",0);model("inGame.CP.zombies.dlc3.elementIndexNameFilter","NATIVE ELEMENT")
model("inGame.CP.zombies.perks.muleMunchiesWeapIcon",0);model("inGame.CP.ammo.unlimitedAlpha",0)
existing=stock_hud() -- created BEFORE custom Lua load, bypassing our dispatcher
ui_root=node();ui_root.hudManager={activeHud=existing}
''')
lua.execute(source)
check('existing.__bo3HudLayout==true')
check('existing.waveNumber.bounds[1]=="full-screen-canvas"')
check('existing.waveNumber._widget.WaveNumber.waveNum.color==0xB83226')
check('existing.waveNumber._widget.WaveNumber.Scene.detached==true')
check('existing.wonderCard._widget.ZomWeaponInfo.weaponinfoZM.TextRightClipAmmo.size==54')
check('existing.mainPlayerInfo._widget.MainPlayerInfo.PlayerIcon.image=="actual-iw7-character"')
check('not existing.mainPlayerInfo._widget.MainPlayerInfo.questFuse.detached')
check('existing.hints and existing.reviveBarContainer and existing.wonderCard._widget.FateCardWidget')
check('existing.activePerks._widget.PerkList.children[2].PerkIcon.image=="actual-perk-2"')
check('existing.wonderCard._widget.ZomWeaponInfo.weaponinfoZM.weaponDescriptionZM.TextAltMode.text=="actual-alt-mode"')
check('existing.mainPlayerInfo._widget.MainPlayerInfo.PlayerIcon:getParent()==existing.mainPlayerInfo._widget.BO3Hero')
check('existing.mainPlayerInfo._widget.MainPlayerInfo.PlayerCash:getParent()==existing.mainPlayerInfo._widget.BO3Hero')
check('existing.mainPlayerInfo._widget.MainPlayerInfo.PlayerIcon.scale==0')
check('existing.mainPlayerInfo._widget.BO3Hero.bounds[7]==-168 and existing.mainPlayerInfo._widget.BO3Hero.bounds[8]==-56')
lua.execute('deck=existing.wonderCard._widget.FateCardWidget;deckCenter=(deck.bounds[8]-deck.bounds[7])/2')
check('deck.bounds[7]+deckCenter+(588.5-deckCenter)*(1+deck.scale)<existing.wonderCard._widget.ZomWeaponInfo.bounds[7]')
check('existing.wonderCard._widget.ZomWeaponInfo.bounds[5]==-560')
lua.execute('nativeReadyCallback=deck.nativeReadyCallback;nativeChildren=#deck.children;deck:SetAlpha(0.6);models["inGame.CP.zombies.consumableDeckSelectReady"]:set(1);tick()')
check('deck.Fire.alpha==1 and deck.upArrow.alpha==1 and deck.alpha==0.6')
check('deck.nativeReadyCallback==nativeReadyCallback and #deck.children==nativeChildren and deck.FateCardOnDeck.image=="native-selected-card"')
lua.execute('fan=deck.fanCard1;fanChildren=#fan.children;nativeFanImage=fan.fanCard;nativeFanOverlay=fan.fanOverlay;fan:SetAlpha(0.4);fan:SetZRotation(-30);fan.fanOverlay:SetRGBFromInt(0x445566);tick();tick()')
check('fan.fanCard==nativeFanImage and fan.fanOverlay==nativeFanOverlay and fan.fanCard.image=="white" and fan.fanOverlay.image=="white"')
check('fan.alpha==0.4 and fan.zrotation==-30 and fan.fanOverlay.color==0x445566 and fan.fanOverlay.alpha==0.6 and #fan.children==fanChildren')
lua.execute('freshFan=MenuBuilder.BuildRegisteredType("FateFanCard",{controllerIndex=2});freshFan:SetAlpha(0);tick()')
check('freshFan.__bo3FanBack and freshFan.alpha==0 and freshFan.fanOverlay.alpha==0.6')
check('deck.FateCardOnDeck.image=="native-selected-card" and deck.Fire.alpha==1 and deck.upArrow.alpha==1')
lua.execute('models["inGame.CP.zombies.consumableDeckSelectReady"]:set(0);tick()')
check('deck.Fire.alpha==0 and deck.upArrow.alpha==0 and deck.alpha==0.6')
check('existing.wonderCard._widget.WonderCardFillWidget.ToggleList0.image=="native-active-card" and existing.wonderCard._widget.WonderCardFillWidget.scale==nil')
check('existing.waveNumber._widget.WaveNumber.bounds[5]>25+existing.mainPlayerInfo._widget.BO3Hero.bounds[6]')
lua.execute('models["inGame.CP.currentPlayerCash"]:set(37)')
check('existing.mainPlayerInfo._widget.MainPlayerInfo.PlayerCash.text==37')
lua.execute(r'''
equipment=existing.wonderCard._widget.ZomWeaponInfo
models["inGame.player.primaryPower.numCharges"]:set(2)
models["inGame.player.secondaryPower.numCharges"]:set(7)
models["inGame.player.primaryPower.color"]:set(0xFF0000)
models["inGame.player.primaryPower.icon"]:set("native-changed-primary")
tick()
''')
check('equipment.PrimaryAbilityQuantity.text==2 and equipment.SecondaryAbilityQuantity.text==7')
check('equipment.PrimaryAbilityQuantity.color==0xFF0000 and equipment.PrimaryAbility.AbilityIcon.image=="native-changed-primary"')
check('equipment.PrimaryAbilityQuantity.bounds[5]>378 and equipment.PrimaryAbility.PlayerAbilityWarning')
lua.execute('models["inGame.player.primaryPower.numAlpha"]:set(0);models["inGame.player.secondaryPower.iconAlpha"]:set(0);tick()')
check('equipment.PrimaryAbilityQuantity.alpha==0 and equipment.SecondaryAbility.alpha==0 and equipment.SecondaryAbilityQuantity.alpha==1')
lua.execute('equipment.CraftedWeapon.ButtonFont:setText("NATIVE CONTROLLER GLYPH");models["inGame.CP.ammo.unlimitedAlpha"]:set(1);models["inGame.CP.zombies.perks.muleMunchiesWeapIcon"]:set(1);tick()')
check('equipment.UnlimitedAmmoIcon.alpha==1 and equipment.muleWeaponIndicator.alpha==1')
check('equipment.CraftedWeapon.ButtonFont.text=="NATIVE CONTROLLER GLYPH" and equipment.CraftedWeapon.ButtonFont.bounds[6]<100')
lua.execute('models["inGame.CP.ammo.unlimitedAlpha"]:set(0);models["inGame.CP.zombies.perks.muleMunchiesWeapIcon"]:set(0);tick()')
check('equipment.UnlimitedAmmoIcon.alpha==0 and equipment.muleWeaponIndicator.alpha==0')
lua.execute(r'''
powerList=existing.activePowerups._widget.ZomPowerupWidget
power=original("ZomPowerupIcon",{controllerIndex=1});local shell=node();shell:addElement(power);powerList:addElement(shell)
power.PowerupIcon.image="native-double-points";power.PowerupIcon.alpha=1
existing.powerupActivated._widget.NativeMessage("NATIVE MAX AMMO","native-max-ammo")
tick()
''')
check('power.PowerupIcon.image=="native-double-points" and power.PowerupIcon.alpha==1 and powerList.zrotation==0')
check('existing.powerupActivated._widget.PowerUpName.text=="NATIVE MAX AMMO" and existing.powerupActivated._widget.PowerUpIcon.image=="native-max-ammo"')
lua.execute('nativeFlash=power.NativeFlash;power:NativeFlash();tick()')
check('power.PowerupIcon.alpha==0 and power.NativeFlash==nativeFlash')
lua.execute('powerList:removeElement(powerList.children[1]);tick()')
check('#powerList.children==0')
lua.execute('freshPower=MenuBuilder.BuildRegisteredType("ZomPowerupIcon",{controllerIndex=2})')
check('freshPower.PowerupIcon.image=="retail-powerup" and freshPower.PowerupIcon.alpha==0 and freshPower.bounds[6]==52 and freshPower.NativeFlash')
lua.execute('badPowerupOnce=true;fallbackPower=MenuBuilder.BuildRegisteredType("ZomPowerupIcon",{controllerIndex=2})')
check('partialPowerup.closed and fallbackPower.PowerupIcon and fallbackPower.bounds==nil')
lua.execute('recoveredPower=MenuBuilder.BuildRegisteredType("ZomPowerupIcon",{controllerIndex=2})')
check('recoveredPower.bounds[6]==52 and not recoveredPower.closed')
lua.execute('models["inGame.CP.zombies.secureState"]:set(3);models["inGame.CP.zombies.secureProgress"]:set(0.4);tick();revive=existing.reviveBarContainer._widget')
check('revive.visible and revive.alpha==1 and revive.Header.MessageText.text=="REVIVING"')
check('math.abs(revive.ProgressBar.Mask.bounds[2]-0.6)<0.0001 and revive.SetHeader==existing.retainedSetHeader and revive.ProgressBar.SetProgress==existing.retainedSetProgress')
lua.execute('models["inGame.CP.zombies.secureState"]:set(21);tick()')
check('revive.visible and revive.Header.MessageText.text=="SKEEBALL"')
lua.execute('models["inGame.CP.zombies.secureState"]:set(0);models["inGame.CP.zombies.secureProgress"]:set(0);tick()')
check('not revive.visible and revive.alpha==0 and revive.ProgressBar.Mask.bounds[2]==1')
lua.execute('existing.omnvarHandlers["zm_ui_laststand_end_milliseconds"](12345);tick()')
check('existing.nativeCountdown.endTime==12345 and existing.nativeDownParent.alpha==1 and existing.nativeCountdown.size==36')
lua.execute('existing.omnvarHandlers["zm_ui_laststand_end_milliseconds"](0);tick()')
check('existing.nativeDownParent.alpha==0 and existing.nativeCountdown.endTime==12345')
lua.execute('models["inGame.CP.zombies.afterlifeHasSelfReviveToken"]:set(1);tick()')
check('existing.afterlifeSelfReviveProgress._widget.Message.MessageText.text=="NATIVE USE GLYPH" and existing.afterlifeSelfReviveProgress._widget.ProgressBar.bounds[1]=="full-width-native-progress"')
lua.execute('models["inGame.CP.zombies.afterlifeHasSelfReviveToken"]:set(0);tick();info=existing.mainPlayerInfo._widget.MainPlayerInfo')
check('existing.afterlifeSelfReviveProgress._widget.Message.MessageText.text=="NATIVE SOUL POWER"')
check('info.ZomTickets:getParent()==info and info.bounds[5]>existing.mainPlayerInfo._widget.BO3Hero.bounds[6] and info.PlayerCash:getParent()==existing.mainPlayerInfo._widget.BO3Hero')
lua.execute(r'''
roster={
 {clientNum=0,name="Actual local",currency=25000,isMicOn=false,isMuted=false},
 {clientNum=2,name="Actual teammate",currency=875,isMicOn=true,isMuted=false}
}
Game={GetCPNumScoreboardPlayers=function() return #roster end,
 GetPlayerClientnum=function() return 0 end,IsSpectating=function() return false end,
 GetPlayerstateClientnum=function() return 0 end,
 GetCPScoreboardRowData=function(row,target,exclude)
  if exclude then local out={};for _,data in ipairs(roster) do if data.clientNum~=target then out[#out+1]=data end end;return out[row+1] end
  return roster[row+1]
 end}
teamRow=node();teamRow._row=0;teamRow._controllerIndex=1
teamRow.PlayerImage=node();teamRow.PlayerImage.image="actual-status-photo"
teamRow.PlayerName=node();teamRow.PlayerCash=node()
function teamRow:RefreshRowContent()
 local data=Game.GetCPScoreboardRowData(self._row,0,true)
 self._clientNum=data.clientNum;self.PlayerName:setText(data.name);self.PlayerCash:setText(data.currency)
end
teamRow:RefreshRowContent()
local grid=existing.mainPlayerInfo._widget.PlayerCash.Players
local shell=node();shell:addElement(teamRow);grid:addElement(shell) -- retail grids wrap rows
local list=existing.activePerks._widget.PerkList
local icon=list.children[1];list:removeElement(icon);local a=node();local b=node();b:addElement(icon);a:addElement(b);list:addElement(a)
tick()
''')
check('existing.mainPlayerInfo._widget.BO3Hero.BO3Name.text=="Actual local"')
check('teamRow.PlayerName.text=="Actual teammate" and teamRow.PlayerCash.text==875')
check('teamRow.PlayerImage.image=="actual-status-photo" and teamRow.BO3Speaker.alpha==1')
check('string.find(BO3ZombiesHUD.messages["bind:ZMHUD:1"],"perks=2",1,true)~=nil')
lua.execute('roster[2].name="Same client updated";roster[2].currency=90;roster[2].isMuted=true;existing.mainPlayerInfo._widget.PlayerCash:RefreshRows()')
check('teamRow.PlayerName.text=="Same client updated" and teamRow.PlayerCash.text==90')
check('teamRow.BO3Speaker.image=="scoreboard_mic_mute"')
lua.execute('hero=existing.mainPlayerInfo._widget.BO3Hero;oldChildren=#hero.children;tick();tick()')
check('#hero.children==oldChildren')
lua.execute(r'''
-- Three actual teammates are stock rows, never fabricated by the adapter.
roster[3]={clientNum=1,name="Joined third",currency=23,isMicOn=false,isMuted=false}
roster[4]={clientNum=3,name="Joined fourth",currency=44,isMicOn=false,isMuted=false}
function extra_row(index)
 local row=node();row._row=index;row.PlayerImage=node();row.PlayerImage.image="retail-status-"..index
 row.PlayerName=node();row.PlayerCash=node()
 function row:RefreshRowContent()
  local target=Game.IsSpectating() and Game.GetPlayerstateClientnum() or Game.GetPlayerClientnum()
  local data=Game.GetCPScoreboardRowData(self._row,target,true)
  self._clientNum=data.clientNum;self.PlayerName:setText(data.name);self.PlayerCash:setText(data.currency)
 end
 return row
end
grid=existing.mainPlayerInfo._widget.PlayerCash.Players
thirdRow=extra_row(1);fourthRow=extra_row(2);grid:addElement(thirdRow);grid:addElement(fourthRow)
originalRowRefresh=thirdRow.RefreshRowContent
firstReturn,secondReturn,thirdReturn=existing.mainPlayerInfo._widget.PlayerCash:RefreshRows()
''')
check('firstReturn=="rows" and secondReturn==nil and thirdReturn==9')
check('#grid.children==3 and thirdRow.PlayerName.text=="Joined third" and fourthRow.PlayerCash.text==44')
check('thirdRow.RefreshRowContent==originalRowRefresh and thirdRow.PlayerImage.image=="retail-status-1"')
check('grid.bounds[6]==165 and thirdRow.BO3Speaker.alpha==0')
lua.execute('grid:removeElement(fourthRow);table.remove(roster,4);existing.mainPlayerInfo._widget.PlayerCash:RefreshRows()')
check('#grid.children==2 and #roster==3')
lua.execute('roster[2].isMicOn=nil;existing.mainPlayerInfo._widget.PlayerCash:RefreshRows()')
check('teamRow.BO3Speaker.alpha==0')
lua.execute('Game.IsSpectating=function() return true end;Game.GetPlayerstateClientnum=function() return 1 end;tick()')
check('hero.BO3Name.text=="Joined third"')
lua.execute('Game.IsSpectating=function() return false end')
lua.execute('models["inGame.CP.zombies.waveNumber"]:set(22);models["inGame.player.currentWeapon.clipAmmoRightDisplay"]:set("11")')
check('existing.waveNumber._widget.WaveNumber.waveNum.text=="22"')
check('existing.wonderCard._widget.ZomWeaponInfo.weaponinfoZM.TextRightClipAmmo.text=="11"')
lua.execute('models["inGame.player.currentWeapon.stockAmmo"]:set(0);tick()')
check('existing.wonderCard._widget.ZomWeaponInfo.weaponinfoZM.TextStockAmmo.color==0xFF8800')
lua.execute('models["inGame.player.currentWeapon.stockAmmo"]:set(24);tick()')
check('existing.wonderCard._widget.ZomWeaponInfo.weaponinfoZM.TextStockAmmo.color==0x999999')
lua.execute('fresh=MenuBuilder.BuildRegisteredType("weaponinfoZM",{controllerIndex=1});existing.wonderCard._widget.ZomWeaponInfo.weaponinfoZM=fresh;models["inGame.player.currentWeapon.stockAmmo"]:set(0);tick()')
check('child(fresh,"BO3Reserve").color==SWATCHES.HUD.warning')
lua.execute('models["inGame.player.currentWeapon.stockAmmo"]:set(24);tick()')
check('child(fresh,"BO3Reserve").color==12566463')
lua.execute('before=#existing.waveNumber._widget.WaveNumber.children;tick();tick()')
check('#existing.waveNumber._widget.WaveNumber.children==before')
check('string.find(BO3ZombiesHUD.messages["bind:ZMHUD:1"],"perks=2",1,true)~=nil')
lua.execute('manager={nextHud=stock_hud()};first,second,third=LUI.HudManager.CreateHud(manager)')
check('first=="retained" and second==nil and third==7 and manager.activeHud.__bo3HudLayout==true')
check('BO3ZombiesHUD.roots[manager.activeHud]~=BO3ZombiesHUD.roots[existing]')
lua.execute('savedWave=manager.nextHud.waveNumber._widget.WaveNumber')
lua.execute('manager.nextHud.waveNumber._widget.WaveNumber=nil;LUI.HudManager.CreateHud(manager)')
check('string.find(BO3ZombiesHUD.messages["failure:ZMHUD"],"retry=1",1,true)~=nil')
check('BO3ZombiesHUD.messages["bind:ZMHUD:1"]==nil')
lua.execute('manager.nextHud.waveNumber._widget.WaveNumber=savedWave;LUI.HudManager.CreateHud(manager)')
check('BO3ZombiesHUD.messages["bind:ZMHUD:1"]~=nil')
lua.execute('manager.nextHud.waveNumber._widget.WaveNumber=nil;LUI.HudManager.CreateHud(manager)')
check('BO3ZombiesHUD.messages["bind:ZMHUD:1"]==nil')
lua.execute('failureCount=0;for _,message in ipairs(printed) do if string.find(message,"binding_failure",1,true) and string.find(message,"root_seq=2",1,true) then failureCount=failureCount+1 end end')
check('failureCount==2')
lua.execute(r'''
mapFixtures={}
for i,key in ipairs({"MainPlayerInfo","MainPlayerInfoDLC1","MainPlayerInfoDLC2","MainPlayerInfoDLC3","MainPlayerInfoDLC4"}) do
 local id=i==1 and "ZMHUD" or "ZMHUDDLC"..(i-1)
 local hud=stock_hud(id,key,(i-1)%4);local instance={nextHud=hud};LUI.HudManager.CreateHud(instance)
 mapFixtures[#mapFixtures+1]={root=hud,info=hud.mainPlayerInfo._widget[key],key=key}
end
models["inGame.CP.zombies.quests.questFuseAlphaFilter"]:set(1)
models["inGame.CP.zombies.HUDInventoryDLC1.hudInventory1Icon"]:set("native-recycled-inventory")
models["inGame.CP.zombies.HUDInventoryDLC1.hudInventory1Alpha"]:set(1)
models["inGame.CP.zombies.dlc1.raveFill"]:set(0.75)
models["inGame.CP.zombies.dlc3.elementIndexNameFilter"]:set("NATIVE CHANGED ELEMENT")
''')
check('#mapFixtures==5')
for i in range(1,6):
    check(f'mapFixtures[{i}].root.__bo3HudLayout and mapFixtures[{i}].root.nativeFuse.alpha==1 and mapFixtures[{i}].root.nativeFuse:getParent()==mapFixtures[{i}].info')
check('mapFixtures[2].info.RaveFill.nativeBottom==0.75 and mapFixtures[2].info.InventorySlot1.image=="native-recycled-inventory"')
check('mapFixtures[3].info.chiStyle.image=="native-chi-style" and mapFixtures[4].info.elementName.text=="NATIVE CHANGED ELEMENT" and mapFixtures[4].info.elementName.size==28')
check('mapFixtures[5].info.InventorySlot1.image=="native-recycled-inventory" and mapFixtures[5].info.InventorySlot1.alpha==1')
lua.execute('models["inGame.CP.zombies.quests.questFuseAlphaFilter"]:set(0);models["inGame.CP.zombies.HUDInventoryDLC1.hudInventory1Alpha"]:set(0)')
check('mapFixtures[1].root.nativeFuse.alpha==0 and mapFixtures[5].info.InventorySlot1.alpha==0')
lua.execute('unrelated=stock_hud();unrelated.id="MPHUD";manager.nextHud=unrelated;LUI.HudManager.CreateHud(manager)')
check('not unrelated.__bo3HudLayout')
lua.execute('retired=MenuBuilder.BuildRegisteredType;MenuBuilder.BuildRegisteredType=original;tick()')
check('MenuBuilder.BuildRegisteredType~=original and MenuBuilder.BuildRegisteredType~=retired')
lua.execute('w=retired("WaveNumber",{controllerIndex=1})')
check('w.id=="stock:WaveNumber"')
lua.execute('for i=1,500 do tick() end;roster[1].name="Live beyond startup";roster[1].isMicOn=true;existing.mainPlayerInfo._widget.PlayerCash:RefreshRows()')
check('#pending==0 and hero.BO3Name.text=="Live beyond startup" and hero.BO3Speaker.alpha==1')
lua.execute('grid:removeElement(thirdRow);grid:removeElement(grid.children[1]);roster={roster[1]};existing.mainPlayerInfo._widget.PlayerCash:RefreshRows()')
check('#grid.children==0 and hero.BO3Name.text=="Live beyond startup"')
lua.execute('originalCount=Game.GetCPNumScoreboardPlayers;Game.GetCPNumScoreboardPlayers=function() return 1.5 end;existing.mainPlayerInfo._widget.PlayerCash:RefreshRows()')
check('hero.BO3Name.text=="" and hero.BO3Speaker.alpha==0')
lua.execute('Game.GetCPNumScoreboardPlayers=originalCount;existing.mainPlayerInfo._widget.PlayerCash:RefreshRows()')
lua.execute('otherRefresh=function() return "external" end;manager.activeHud.mainPlayerInfo._widget.PlayerCash.RefreshRows=otherRefresh;retiredTeam=existing.mainPlayerInfo._widget.PlayerCash.RefreshRows')
lua.execute('BO3ZombiesHUD.shutdown()')
check('MenuBuilder.BuildRegisteredType==original')
check('existing.mainPlayerInfo._widget.PlayerCash.RefreshRows==existing.retainedTeamRefresh')
check('manager.activeHud.mainPlayerInfo._widget.PlayerCash.RefreshRows==otherRefresh')
lua.execute('roster[1].name="After shutdown";retiredTeam(existing.mainPlayerInfo._widget.PlayerCash)')
check('hero.BO3Name.text=="Live beyond startup"')
print(f"PASS {checks} authored Lua5.1 source controls; mocked UI/models only, no HKS/game/pixels")
