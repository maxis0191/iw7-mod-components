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
printed={};print=function(message) printed[#printed+1]=message end
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
CONDITIONS={IsDLC4=function(self) return self.nativeDlc4 or false end}
function node()
 local n={children={},alpha=1,closed=false}
 function n:SetAnchorsAndPosition(...) self.bounds={...} end
 function n:getLocalRect()
  if self.rectError then error("mock native geometry reader failed") end
  if self.rectOverride then return unpack(self.rectOverride) end
  if self.bounds then return self.bounds[5],self.bounds[7],self.bounds[6],self.bounds[8] end
 end
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
 function n:SetMask(value) self.mask=value end
 function n:setEndTime(value) self.endTime=value end
 function n:SetProgress(value) self.progress=value;self.progressWrites=(self.progressWrites or 0)+1 end
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
LUI={UIElement={new=node},UIText={new=node},UIImage={new=node},Alignment={Left=0,Center=1},
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
  n.fanCard=node();n.fanCard.id="fanCard";n.fanCard.image="zm_wc_card_fan";n:addElement(n.fanCard)
  n.fanOverlay=node();n.fanOverlay.id="fanOverlay";n.fanOverlay.image="zm_wc_card_fan_overlay";n.fanOverlay.color=0x263626;n.fanOverlay.alpha=0.6;n:addElement(n.fanOverlay)
  if nextFanShape then local mutate=nextFanShape;nextFanShape=nil;mutate(n) end
 end
 if key=="FateCardOnDeck" then
  n.cardBack=node();n.name=node();n.icon=node()
  n.name:SetFont("native-name-font");n.name:SetFontSize(20)
  n.name:SetAnchorsAndPosition(0,1,0,1,15.5,146.5,10.79,30.79)
  n.icon:SetAnchorsAndPosition(0,1,0,1,13.5,141.5,32.5,160.5)
  for _,leaf in ipairs({n.cardBack,n.name,n.icon}) do n:addElement(leaf) end
  n.nativeIdentityCallbacks={}
  for _,item in ipairs({{"consumableDeckSelectBacking",n.cardBack,"image"},{"consumableDeckSelectName",n.name,"text"},{"consumableDeckSelectIcon",n.icon,"image"}}) do
   local m=models["inGame.CP.zombies."..item[1]];local leaf=item[2];local property=item[3]
   local update=function() local value=m:GetValue(args.controllerIndex);if value~=nil then leaf[property]=value end end
   leaf:SubscribeToModel(m,update);update();n.nativeIdentityCallbacks[item[1]]=update
  end
  -- Finite native-like phases: the adapter must not override these writes.
  n.nativePhase=function(phase)
   if phase=="refill" then n:SetAlpha(0);n.name:SetAlpha(0);n.icon:SetAlpha(0);n.name:SetRGBFromInt(0)
   elseif phase=="refillDone" then n:SetAlpha(1)
   elseif phase=="cycle" or phase=="meterFull" then n:SetAlpha(1);n.name:SetAlpha(1);n.icon:SetAlpha(1);n.name:SetRGBFromInt(0xFFFFFF);n:SetAnchorsAndPosition(0,1,0,1,45.5,200.5,76.82,247.82)
   elseif phase=="noMoreCards" then n:SetAlpha(0) end
  end
  n.nativeChildMeterFull=function()
   n.name:SetAnchorsAndPosition(0,1,0,1,39.7,170.7,-35.45,-15.45)
   n.icon:SetAnchorsAndPosition(0,1,0,1,37.7,165.7,-22.45,105.55)
  end
  if nextSelectedShape then local mutate=nextSelectedShape;nextSelectedShape=nil;mutate(n) end
 end
 if key=="FateCardDevilWidget" then
  n.nativeDlc4=args and args.nativeDlc4 or false
  n.devilHead=node();n.devilJaw=node();n.sadDevil=node();n.Circle=node();n.blueGlow=node();n.innerRing=node();n.outerRing=node();n.glowRing=node()
  n.Circle.image="zm_wc_circle_bg";n.innerRing.image="zm_wc_red_hoop";n.outerRing.image="zm_wc_red_hoop"
  n.blueGlow.image="zm_powerup_glow_element";n.blueGlow.alpha=0;n.glowRing.image="zm_wc_card_glow_ring"
  n.radialAlphaLarge=node();n.radialAlphaLarge.circleFill=node();n.radialAlphaLarge:addElement(n.radialAlphaLarge.circleFill)
  for _,leaf in ipairs({n.Circle,n.blueGlow,n.radialAlphaLarge,n.innerRing,n.outerRing,n.glowRing,n.devilJaw,n.devilHead,n.sadDevil}) do n:addElement(leaf) end
  n.nativeUpdate=function()
   local count=models["inGame.CP.zombies.consumablesRemaining"]:GetValue(args.controllerIndex)
   local fill=models["inGame.CP.zombies.dpadUpFillPercent"]:GetValue(args.controllerIndex)
   local ready=models["inGame.CP.zombies.consumableDeckSelectReady"]:GetValue(args.controllerIndex)
   local boss=models["inGame.CP.zombies.dlc4.mephBattle"]:GetValue(args.controllerIndex)
   n.devilHead.image=n.nativeDlc4 and boss==1 and "cp_final_meph_head_full" or "zm_wc_devil_head_top"
   n.devilHead.alpha=count and count>0 and 1 or 0;n.devilJaw.alpha=n.devilHead.alpha;n.sadDevil.alpha=count==0 and 1 or 0
   n.Circle.alpha=n.devilHead.alpha;n.innerRing.alpha=n.devilHead.alpha;n.outerRing.alpha=n.devilHead.alpha;n.radialAlphaLarge.alpha=n.devilHead.alpha
   n.radialAlphaLarge.circleFill:SetProgress(fill);n.glowRing.alpha=ready==1 and 1 or 0
  end
  for _,path in ipairs({"consumablesRemaining","dpadUpFillPercent","consumableDeckSelectReady","dlc4.mephBattle"}) do
   n:SubscribeToModel(models["inGame.CP.zombies."..path],n.nativeUpdate)
  end
  n.nativeUpdate()
  n.nativeRefill=function(value) n.blueGlow:SetAlpha(value) end
  if nextCardShape then local mutate=nextCardShape;nextCardShape=nil;mutate(n) end
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

check('BO3ZombiesHUD.version=="0.16.0" and BO3ZombiesHUD.diagnosticVersion=="0.7.0" and string.find(printed[1],"module version=0.7.0 content_version=0.16.0",1,true)~=nil')
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
 r.reviveBarContainer=node();local revive=node();r.reviveBarContainer._widget=revive;r.reviveBarContainer:addElement(revive)
 -- Five source-derived schemas, not five names over the old two-field stub.
 local variant=tonumber(string.match(r.id,"DLC(%d)$")) or 0
 revive.id="ReviveBarContainer"..(variant==0 and "" or "DLC"..variant)
 local fills={"zm_revive_bar_fill","zm_revive_bar_fill_dlc1","zm_revive_bar_fill_dlc2","cp_town_revive_bar_fill","cp_final_revive_bar_fill"}
 revive.Accent=node();revive.Accent.image="authored-accent-token-"..variant;revive:addElement(revive.Accent)
 revive.Header=node();revive.Header.MessageText=node();revive:addElement(revive.Header)
 if variant==0 then
  revive.Header.Background=node();revive.Header:addElement(revive.Header.Background)
  revive.Background=node();revive:addElement(revive.Background)
 end
 revive.Header:addElement(revive.Header.MessageText)
 revive.Header.MessageText.font=variant==0 and "native-condensed" or "native-medium"
 revive.Header.MessageText.size=16
 revive.ProgressBar=node();revive:addElement(revive.ProgressBar)
 revive.ProgressBar.Fill=node();revive.ProgressBar.Mask=node()
 revive.ProgressBar:addElement(revive.ProgressBar.Fill);revive.ProgressBar:addElement(revive.ProgressBar.Mask)
 revive.ProgressBar.Fill:setImage(fills[variant+1]);revive.ProgressBar.Mask:setImage("devil_stencil_mask")
 revive.ProgressBar.Fill:SetMask(revive.ProgressBar.Mask)
 revive.ProgressBar.Fill:SetAnchorsAndPosition(0.5,0.5,0.5,0.5,variant==3 and -124 or -127,variant==3 and 126 or 129,-16,16)
 revive.SetHeader=function(self,value)
  -- Authored measuring stand-in; the unchanged native callback owns sizing.
  local upper=string.upper(value);self.Header:SetAnchorsAndPosition(0.5,0.5,0,1,-118,-118+#upper*8+26,-2,30,100)
  self.Header.MessageText:setText(upper)
 end
 revive.ProgressBar.SetProgress=function(self,value,duration)
  assert(type(value)=="number" and type(duration)=="number")
  self.Mask:SetAnchorsAndPosition(0,1-math.max(0,math.min(1,value)),0,0,0,0,0,0,duration)
 end
 local function state()
  local value=models["inGame.CP.zombies.secureState"]:GetValue(index)
  revive.visible=value~=0
  -- Endpoints of native Show/Hide. Container stays alpha1; each original
  -- leaf's animation controls visibility, including the accent underlay.
  revive.Accent.alpha=revive.visible and (variant==0 and 0.5 or 1) or 0
  revive.Header.alpha=revive.visible and 1 or 0;revive.ProgressBar.alpha=revive.Header.alpha
  if revive.Background then revive.Background.alpha=revive.Header.alpha end
  revive:SetHeader(value==3 and "REVIVING" or value==21 and "SKEEBALL" or "")
 end
 revive:SubscribeToModel(models["inGame.CP.zombies.secureState"],state);state()
 revive.ProgressBar:SubscribeToModel(models["inGame.CP.zombies.secureProgress"],function()
  revive.ProgressBar:SetProgress(models["inGame.CP.zombies.secureProgress"]:GetValue(index),0)
 end)
 r.retainedSetHeader=revive.SetHeader;r.retainedSetProgress=revive.ProgressBar.SetProgress
 r.retainedAction={accent=revive.Accent,header=revive.Header,label=revive.Header.MessageText,
  progress=revive.ProgressBar,fill=revive.ProgressBar.Fill,mask=revive.ProgressBar.Mask,
  fillImage=revive.ProgressBar.Fill.image,fillBounds=revive.ProgressBar.Fill.bounds,
  maskImage=revive.ProgressBar.Mask.image,state=state,stateListeners=#models["inGame.CP.zombies.secureState"].listeners,
  progressListeners=#models["inGame.CP.zombies.secureProgress"].listeners}
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
 deck.FateCardDevilWidget=original("FateCardDevilWidget",{controllerIndex=r.controllerIndex,nativeDlc4=r.id=="ZMHUDDLC4"});deck:addElement(deck.FateCardDevilWidget)
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
model("inGame.CP.zombies.consumablesRemaining",5);model("inGame.CP.zombies.dpadUpFillPercent",0.25);model("inGame.CP.zombies.dlc4.mephBattle",0)
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
lua.execute(r'''
function fanLine(stage,sequence)
 for i=#printed,1,-1 do
  local line=printed[i]
  if string.find(line,"[BO3 HUD] fan ",1,true) and string.find(line," widget_seq="..sequence.." ",1,true)
    and string.find(line," stage="..stage.." ",1,true) then return line end
 end
 return ""
end
function contains(line,fragment) return string.find(line,fragment,1,true)~=nil end
probeOwner=fan.__bo3FanBack;probeHooks=probeOwner.probe.hooks
''')
check('#probeHooks==7 and probeOwner.probe.active and contains(fanLine("applied",1),"reason=writes_returned") and contains(fanLine("applied",1),"alpha_intent=unknown") and contains(fanLine("applied",1),"image_read=unknown")')
check('contains(fanLine("deck",1),"slot=1") and contains(fanLine("deck",1),"slot_match=1") and contains(fanLine("deck",1),"root_seq_seen=1") and contains(fanLine("deck",1),"overlay_l=24.500") and contains(fanLine("deck",1),"overlay_r=32.500") and contains(fanLine("deck",1),"overlay_read=known")')
lua.execute('fan.fanOverlay.rectOverride={101,202,303,404};fan.fanOverlay:SetAnchorsAndPosition(0,1,0,1,24.5,42.5,84,428,37)')
check('contains(fanLine("overlay_rect",1),"intent_r=42.500") and contains(fanLine("overlay_rect",1),"overlay_l=101.000") and contains(fanLine("overlay_rect",1),"overlay_r=303.000") and contains(fanLine("overlay_rect",1),"reason=setter_returned") and contains(fanLine("overlay_rect",1),"origin=later_call") and fan.fanOverlay.bounds[9]==37')
lua.execute('fan.fanOverlay.rectOverride=nil;fan.fanOverlay.rectError=true;fan.fanOverlay:SetAnchorsAndPosition(0,1,0,1,24.5,32.5,84,428)')
check('contains(fanLine("overlay_rect",1),"overlay_read=unknown_error") and fan.fanOverlay.bounds[6]==32.5 and probeOwner.probe.active')
lua.execute('fan.fanOverlay.rectError=false;probeRectReader=fan.fanOverlay.getLocalRect;fan.fanOverlay.getLocalRect=nil;fan.fanOverlay:SetAnchorsAndPosition(0,1,0,1,24.5,32.5,84,428)')
check('contains(fanLine("overlay_rect",1),"overlay_read=unknown_missing") and probeOwner.probe.active')
lua.execute('fan.fanOverlay.getLocalRect=probeRectReader;fan.fanOverlay.rectOverride={0/0,0,1,1};fan.fanOverlay:SetAnchorsAndPosition(0,1,0,1,24.5,32.5,84,428)')
check('contains(fanLine("overlay_rect",1),"overlay_read=unknown_invalid_numeric") and not contains(fanLine("overlay_rect",1),"overlay_l=0.000")')
lua.execute('fan.fanOverlay.rectOverride={1e80,0,1,1};fan.fanOverlay:SetAnchorsAndPosition(0,1,0,1,24.5,32.5,84,428)')
check('contains(fanLine("overlay_rect",1),"overlay_read=unknown_invalid_numeric") and not contains(fanLine("overlay_rect",1),"overlay_l=100000")')
lua.execute('fan.fanOverlay.rectOverride=nil;fan.fanOverlay:setImage("mock-overwrite-material");fan.fanOverlay:SetRGBFromInt(0x445566);fan.fanOverlay:SetAlpha(0.6,17)')
check('fan.fanOverlay.image=="mock-overwrite-material" and contains(fanLine("overlay_image",1),"same_adapter_argument=0") and contains(fanLine("overlay_image",1),"image_read=unknown") and contains(fanLine("overlay_alpha",1),"overlay_alpha_intent=0.600") and contains(fanLine("overlay_rgb",1),"overlay_rgb_intent=4478310.000")')
lua.execute('fan.fanOverlay:setImage("white");fan:SetAlpha(0.4,29)')
check('contains(fanLine("overlay_image",1),"same_adapter_argument=1") and contains(fanLine("parent_alpha",1),"alpha_intent=0.400") and contains(fanLine("parent_alpha",1),"alpha_read=unknown") and contains(fanLine("parent_alpha",1),"duration=29.000")')
lua.execute(r'''
nextFanShape=function(f)
 f.nativeRectSetter=function(self,...) self.bounds={...};return "native-geometry",nil,19 end
 f.nativeAlphaSetter=function(self,value,...) if value==99 then error("native-alpha-failure") end;self.alpha=value;return "native-alpha",nil,23 end
 f.fanOverlay.SetAnchorsAndPosition=f.nativeRectSetter;f.SetAlpha=f.nativeAlphaSetter
end
returnFan=MenuBuilder.BuildRegisteredType("FateFanCard",{controllerIndex=2})
returnOwner=returnFan.__bo3FanBack
retRectA,retRectB,retRectC=returnFan.fanOverlay:SetAnchorsAndPosition(0,1,0,1,1,2,3,4,71,nil,73)
retAlphaA,retAlphaB,retAlphaC=returnFan:SetAlpha(0.2,83,nil,89)
errorOK,errorMessage=pcall(function() returnFan:SetAlpha(99) end)
borrowedTarget=node();borrowA,borrowB,borrowC=returnFan.SetAlpha(borrowedTarget,0.7)
''')
check('retRectA=="native-geometry" and retRectB==nil and retRectC==19 and returnFan.fanOverlay.bounds[9]==71 and returnFan.fanOverlay.bounds[10]==nil and returnFan.fanOverlay.bounds[11]==73')
check('retAlphaA=="native-alpha" and retAlphaB==nil and retAlphaC==23 and returnFan.alpha==0.2 and not errorOK and contains(errorMessage,"native-alpha-failure") and returnOwner.probe.alphaIntent==0.2')
check('borrowedTarget.alpha==0.7 and borrowA=="native-alpha" and borrowB==nil and borrowC==23 and returnOwner.probe.alphaIntent==0.2')
lua.execute('nextFanShape=function(f) f.nativeAlpha=f.SetAlpha;f.SetAlpha=nil end;failedProbeFan=MenuBuilder.BuildRegisteredType("FateFanCard",{controllerIndex=2});failedProbeOwner=failedProbeFan.__bo3FanBack')
check('failedProbeOwner and not failedProbeOwner.probe.active and failedProbeOwner.probe.stopReason=="install_error" and failedProbeFan.fanCard.setImage==failedProbeOwner.probe.hooks[1].original and failedProbeFan.fanOverlay.SetAnchorsAndPosition==failedProbeOwner.probe.hooks[4].original and failedProbeFan.SetAlpha==nil and failedProbeFan.fanCard.image=="white"')
lua.execute(r'''
callbackFan=deck.fanCard2;callbackOwner=callbackFan.__bo3FanBack;callbackNative=callbackOwner.probe.hooks[4].original
foreignFanSetter=function(self,...) return callbackNative(self,...) end
callbackFan.fanOverlay.SetAnchorsAndPosition=foreignFanSetter
existing.mainPlayerInfo._widget.PlayerCash:RefreshRows()
''')
check('not callbackOwner.probe.active and callbackOwner.probe.stopReason=="setter_replaced" and callbackFan.fanOverlay.SetAnchorsAndPosition==foreignFanSetter and callbackFan.SetAlpha==callbackOwner.probe.hooks[7].original and callbackFan.fanCard.setImage==callbackOwner.probe.hooks[1].original')
check('contains(fanLine("deck",2),"hook_stop=setter_replaced") and contains(fanLine("deck",2),"hooks=inactive") and not callbackOwner.retired')
lua.execute('probeLogCount=#printed;existing.mainPlayerInfo._widget.PlayerCash:RefreshRows();existing.mainPlayerInfo._widget.PlayerCash:RefreshRows()')
check('#printed==probeLogCount')
lua.execute('for i=1,45 do fan.fanOverlay:SetAnchorsAndPosition(0,1,0,1,24.5,32.5+i,84,428) end;fan.fanOverlay:SetAnchorsAndPosition(0,1,0,1,24.5,32.5,84,428);fanTraceCount=0;for _,line in ipairs(printed) do if contains(line,"[BO3 HUD] fan ") and contains(line," widget_seq=1 ") then fanTraceCount=fanTraceCount+1 end end')
check('fanTraceCount==33 and contains(fanLine("suppressed",1),"reason=transition_limit") and fan.fanOverlay.bounds[6]==32.5 and probeOwner.probe.active')
check('fan.fanOverlay.bounds[6]-fan.fanOverlay.bounds[5]==8 and fan.fanCard.bounds[6]-fan.fanCard.bounds[5]==192 and fan.children[1]==nativeFanImage and fan.children[2]==nativeFanOverlay and fan.children[3]==fan.__bo3FanBack.view')
lua.execute(r'''
fanOwner=fan.__bo3FanBack;nativeFanBounds=fan.bounds;fan:SetScale(-0.5)
-- Native count/selection poses retain authority, including empty/depth changes.
fan:SetAlpha(0);fan:SetZRotation(-25);fan.fanOverlay:SetAlpha(0.3)
existing.mainPlayerInfo._widget.PlayerCash:RefreshRows()
''')
check('fan.alpha==0 and fan.zrotation==-25 and fan.scale==-0.5 and fan.bounds==nativeFanBounds and fan.fanOverlay.alpha==0.3 and fan.fanOverlay.color==0x445566 and fan.__bo3FanBack==fanOwner')
lua.execute('fan:SetAlpha(1);fan.fanOverlay:SetRGBFromInt(0x263626);existing.mainPlayerInfo._widget.PlayerCash:RefreshRows()')
check('fan.alpha==1 and fan.fanOverlay.color==0x263626 and #fan.children==3 and #fanOwner.view.children==5')
lua.execute(r'''
foreignFanRoots={}
function fanRoot(mutate)
 local r=stock_hud();if mutate then mutate(r.wonderCard._widget.FateCardWidget.fanCard1) end
 LUI.HudManager.CreateHud({nextHud=r});foreignFanRoots[#foreignFanRoots+1]=r
 return r,r.wonderCard._widget.FateCardWidget.fanCard1
end
function refreshFan(r) r.mainPlayerInfo._widget.PlayerCash:RefreshRows() end
-- Added native/foreign children and field aliases are not an eligible schema.
unknownFanRoot,unknownFan=fanRoot(function(f) f.extra=node();f:addElement(f.extra);f.nativeAlpha=f.SetAlpha;f.nativeImage=f.fanCard.setImage end)
badFanRoot,badFan=fanRoot(function(f) f.fanOverlay=f.fanCard end)
''')
check('not unknownFan.__bo3FanBack and unknownFan.fanCard.image=="zm_wc_card_fan" and not unknownFan.extra.closed and unknownFanRoot.__bo3HudLayout and not badFan.__bo3FanBack and badFanRoot.__bo3HudLayout')
lua.execute('unknownShapeTrace="";for _,line in ipairs(printed) do if contains(line,"[BO3 HUD] fan ") and contains(line,"stage=skipped reason=extra_child") then unknownShapeTrace=line end end')
check('unknownFan.SetAlpha==unknownFan.nativeAlpha and unknownFan.fanCard.setImage==unknownFan.nativeImage and contains(unknownShapeTrace,"initial_writes_returned=0")')
lua.execute('unknownFan:removeElement(unknownFan.extra);refreshFan(unknownFanRoot)')
check('unknownFan.__bo3FanBack and unknownFan.fanCard.image=="white"')
lua.execute(r'''
-- A forged public marker is never cleanup authority, even after forced GC.
tagFanRoot,tagFan=fanRoot();tagFanView=tagFan.__bo3FanBack.view
fanForeignParent=node();fanForeignView=node();fanForeignView.alpha=0.47;fanForeignParent:addElement(fanForeignView)
fanForgedTag={view=fanForeignView,back=fanForeignView,overlay=fanForeignView,rims={fanForeignView}}
tagFan.__bo3FanBack=fanForgedTag;collectgarbage("collect");refreshFan(tagFanRoot)
''')
check('tagFan.fanCard.image=="zm_wc_card_fan" and tagFan.fanCard.color==0xFFFFFF and tagFan.fanOverlay.image=="zm_wc_card_fan_overlay" and tagFan.fanCard.bounds[5]==-11.5 and tagFan.fanCard.bounds[8]==512 and tagFan.fanOverlay.color==0x263626 and tagFan.fanOverlay.alpha==0.6')
check('tagFanView.closed and tagFanView:getParent()==nil and tagFanView.__bo3FanLifetime==nil and tagFan.__bo3FanBack==fanForgedTag and not fanForeignView.closed and fanForeignView.alpha==0.47 and fanForeignView:getParent()==fanForeignParent')
lua.execute('tagFan.__bo3FanBack=nil;collectgarbage("collect");refreshFan(tagFanRoot)')
check('tagFan.__bo3FanBack==nil and #tagFan.children==2 and tagFan.fanCard.image=="zm_wc_card_fan"')
lua.execute(r'''
preTagRoot,preTagFan=fanRoot(function(f) f.__bo3FanBack=fanForgedTag end)
nilFanRoot,nilFan=fanRoot();nilFanView=nilFan.__bo3FanBack.view;nilFan.__bo3FanBack=nil;collectgarbage("collect");refreshFan(nilFanRoot)
typeFanRoot,typeFan=fanRoot();typeFanView=typeFan.__bo3FanBack.view;typeFan.__bo3FanBack=true;refreshFan(typeFanRoot)
''')
check('preTagFan.__bo3FanBack==fanForgedTag and preTagFan.fanCard.image=="zm_wc_card_fan" and not fanForeignView.closed and nilFanView.closed and nilFan.__bo3FanBack==nil and typeFanView.closed and typeFan.__bo3FanBack==true')
lua.execute(r'''
changedFanRoot,changedFan=fanRoot();changedFanBack=changedFan.fanCard;changedFanView=changedFan.__bo3FanBack.view
replacementFanBack=node();replacementFanBack.image="foreign-back";replacementFanBack.alpha=0.42
changedFan.fanCard=replacementFanBack;refreshFan(changedFanRoot)
''')
check('changedFanView.closed and changedFan.fanCard==replacementFanBack and replacementFanBack.image=="foreign-back" and replacementFanBack.alpha==0.42 and not replacementFanBack.closed and changedFanBack.image=="white" and changedFan.fanOverlay.image=="zm_wc_card_fan_overlay"')
lua.execute(r'''
adoptedFanRoot,adoptedFan=fanRoot();adoptedOverlay=adoptedFan.fanOverlay;adoptedView=adoptedFan.__bo3FanBack.view
adoptedFan:removeElement(adoptedOverlay);fanForeignParent:addElement(adoptedOverlay);refreshFan(adoptedFanRoot)
extraFanRoot,extraFan=fanRoot();extraFanView=extraFan.__bo3FanBack.view
extraFanChild=node();extraFanChild.alpha=0.39;extraFanView:addElement(extraFanChild);refreshFan(extraFanRoot)
nestedFanRoot,nestedFan=fanRoot();nestedFanView=nestedFan.__bo3FanBack.view;nestedFanRim=nestedFanView.children[1]
nestedFanChild=node();nestedFanRim:addElement(nestedFanChild);refreshFan(nestedFanRoot)
''')
check('adoptedView.closed and adoptedOverlay:getParent()==fanForeignParent and adoptedOverlay.image=="white" and not adoptedOverlay.closed and adoptedFan.fanCard.image=="zm_wc_card_fan"')
check('not extraFanView.closed and extraFanView:getParent()==extraFan and extraFanChild:getParent()==extraFanView and not extraFanChild.closed and extraFanChild.alpha==0.39 and #extraFanView.children==1 and extraFan.fanCard.image=="zm_wc_card_fan"')
check('not nestedFanView.closed and nestedFanRim:getParent()==nestedFanView and not nestedFanRim.closed and nestedFanChild:getParent()==nestedFanRim and not nestedFanChild.closed and #nestedFanView.children==1')
lua.execute('movedFanRoot,movedFan=fanRoot();movedFanView=movedFan.__bo3FanBack.view;movedFan:removeElement(movedFanView);fanForeignParent:addElement(movedFanView);refreshFan(movedFanRoot)')
check('movedFanView:getParent()==fanForeignParent and not movedFanView.closed and #movedFanView.children==5 and movedFanView.__bo3FanLifetime==nil and movedFan.fanCard.image=="zm_wc_card_fan"')
lua.execute('indexFanRoot,indexFan=fanRoot();indexFanView=indexFan.__bo3FanBack.view;indexFanRoot.controllerIndex=2;refreshFan(indexFanRoot)')
check('indexFanView.closed and indexFan.fanCard.image=="zm_wc_card_fan" and indexFan.fanOverlay.image=="zm_wc_card_fan_overlay"')
lua.execute('nextFanShape=function(f) f.extra=node();f:addElement(f.extra) end;unknownFactoryFan=MenuBuilder.BuildRegisteredType("FateFanCard",{controllerIndex=2})')
check('not unknownFactoryFan.__bo3FanBack and unknownFactoryFan.fanCard.image=="zm_wc_card_fan" and not unknownFactoryFan.extra.closed')
lua.execute('fractionalFan=MenuBuilder.BuildRegisteredType("FateFanCard",{controllerIndex=1.5})')
check('not fractionalFan.__bo3FanBack and fractionalFan.fanCard.image=="zm_wc_card_fan" and freshFan.__bo3FanBack.index==2 and deck.fanCard2.__bo3FanBack.index==1 and deck.fanCard2.__bo3FanBack~=freshFan.__bo3FanBack')
check('deck.FateCardOnDeck.image=="native-selected-card" and deck.Fire.alpha==1 and deck.upArrow.alpha==1')
lua.execute('core=deck.FateCardDevilWidget;coreOwner=core.__bo3CardCore;nativeCoreUpdate=core.nativeUpdate;meter=core.radialAlphaLarge.circleFill;nativeMeterParent=meter:getParent()')
check('coreOwner.count.text=="5" and coreOwner.status.text=="READY" and coreOwner.title.text=="CARDS" and coreOwner.mask.alpha==0')
check('coreOwner.mask.children[1]==core.devilJaw and coreOwner.mask.children[2]==core.devilHead and coreOwner.mask.children[3]==core.sadDevil and meter:getParent()==nativeMeterParent')
lua.execute(r'''
gauge=coreOwner.gauge;nativeRefill=core.nativeRefill
function chargeFraction(g)
 local track=child(g.view,"BO3ChargeTrack")
 return (g.fill.bounds[6]-g.fill.bounds[5])/(track.bounds[6]-track.bounds[5])
end
function nativePainterOrder(widget,owner)
 local expected={widget.Circle,widget.blueGlow,widget.radialAlphaLarge,widget.innerRing,widget.outerRing,widget.glowRing,widget.devilJaw,widget.devilHead,widget.sadDevil}
 local found={}
 local function visit(parent)
  for _,leaf in ipairs(parent.children) do
   if leaf~=owner.view then
    local native=false
    for _,value in ipairs(expected) do if value==leaf then native=true;break end end
    if native then found[#found+1]=leaf else visit(leaf) end
   end
  end
 end
 visit(widget)
 if #found~=#expected then return false end
 for i,leaf in ipairs(expected) do if found[i]~=leaf then return false end end
 return true
end
''')
check('gauge and gauge.backing.alpha==0 and gauge.meter.alpha==0 and gauge.view.alpha==1 and nativePainterOrder(core,coreOwner)')
check('core.Circle.image=="zm_wc_circle_bg" and core.innerRing.image=="zm_wc_red_hoop" and core.outerRing.image=="zm_wc_red_hoop" and core.blueGlow.image=="zm_powerup_glow_element" and core.glowRing.image=="zm_wc_card_glow_ring"')
lua.execute('writesBefore=meter.progressWrites;models["inGame.CP.zombies.dpadUpFillPercent"]:set(0.5)')
check('math.abs(chargeFraction(gauge)-0.5)<0.000001 and gauge.fill.alpha==1 and meter.progress==0.5 and meter.progressWrites==writesBefore+1')
lua.execute('models["inGame.CP.zombies.dpadUpFillPercent"]:set(0);fractionAtZero=chargeFraction(gauge);alphaAtZero=gauge.fill.alpha;models["inGame.CP.zombies.dpadUpFillPercent"]:set(1)')
check('fractionAtZero==0 and alphaAtZero==0 and chargeFraction(gauge)==1 and gauge.fill.alpha==1')
lua.execute('core.nativeRefill(0.8);tick()')
check('core.nativeRefill==nativeRefill and core.blueGlow.alpha==0.8 and core.blueGlow:getParent()==gauge.canvas and gauge.canvas.alpha==1 and core.glowRing.alpha==1 and core.glowRing:getParent()==gauge.canvas')
lua.execute('models["inGame.CP.zombies.consumableDeckSelectReady"]:set(0);models["inGame.CP.zombies.dpadUpFillPercent"]:set(0.75);models["inGame.CP.zombies.consumablesRemaining"]:set(3);tick()')
check('coreOwner.count.text=="3" and coreOwner.status.text=="CHARGING" and meter.progress==0.75 and core.nativeUpdate==nativeCoreUpdate')
check('math.abs(chargeFraction(gauge)-0.75)<0.000001 and gauge.fill.color~=0xF5F1E7 and core.glowRing.alpha==0 and core.blueGlow.alpha==0.8')
lua.execute('models["inGame.CP.zombies.consumablesRemaining"]:set(0);tick()')
check('coreOwner.count.text=="0" and coreOwner.status.text=="EMPTY" and core.sadDevil.alpha==1 and coreOwner.mask.alpha==0')
check('gauge.fill.alpha==0 and gauge.view.alpha==1 and meter.progress==0.75 and math.abs(chargeFraction(gauge)-0.75)<0.000001')
lua.execute('models["inGame.CP.zombies.consumableDeckSelectReady"]:set(nil);tick()')
check('coreOwner.mask.alpha==1 and coreOwner.view.alpha==0 and core.sadDevil.alpha==1')
check('gauge.backing.alpha==1 and gauge.meter.alpha==1 and gauge.view.alpha==0 and nativePainterOrder(core,coreOwner)')
lua.execute('models["inGame.CP.zombies.consumablesRemaining"]:set(5);models["inGame.CP.zombies.consumableDeckSelectReady"]:set(1);tick();oldCoreChildren=#core.children;tick()')
check('coreOwner.count.text=="5" and coreOwner.status.text=="READY" and core.glowRing.alpha==1 and #core.children==oldCoreChildren')
check('gauge.backing.alpha==0 and gauge.meter.alpha==0 and gauge.view.alpha==1 and gauge.fill.color==0xF5F1E7 and nativePainterOrder(core,coreOwner)')
lua.execute('bossCore=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=2,nativeDlc4=true});models["inGame.CP.zombies.dlc4.mephBattle"]:set(1)')
check('bossCore.__bo3CardCore.title.text=="BOSS" and bossCore.__bo3CardCore.mode=="boss" and bossCore.devilHead.image=="cp_final_meph_head_full" and bossCore.__bo3CardCore.mask.alpha==0')
lua.execute('models["inGame.CP.zombies.dlc4.mephBattle"]:set(nil)')
check('bossCore.__bo3CardCore.mask.alpha==1 and bossCore.__bo3CardCore.view.alpha==0')
lua.execute('models["inGame.CP.zombies.dlc4.mephBattle"]:set(0);savedDLC=CONDITIONS.IsDLC4;CONDITIONS.IsDLC4=nil;models["inGame.CP.zombies.dpadUpFillPercent"]:set(0.5)')
check('coreOwner.mask.alpha==1 and coreOwner.view.alpha==0')
lua.execute('CONDITIONS.IsDLC4=savedDLC;models["inGame.CP.zombies.dpadUpFillPercent"]:set(0.25);core:SetAlpha(0.3);tick()')
check('coreOwner.mask.alpha==0 and coreOwner.view.alpha==1 and core.alpha==0.3')
check('gauge.view:getParent()==coreOwner.view and gauge.canvas:getParent()==core and gauge.canvas.alpha==1 and gauge.backing.alpha==0 and gauge.meter.alpha==0')
lua.execute(r'''
function gaugeFixture(mutate)
 nextCardShape=mutate
 local widget=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=1})
 return widget,widget.__bo3CardCore
end
extraCore,extraOwner=gaugeFixture(function(widget) widget.foreignBadge=node();widget:addElement(widget.foreignBadge) end)
reorderedCore,reorderedOwner=gaugeFixture(function(widget) widget:removeElement(widget.innerRing);widget:addElement(widget.innerRing) end)
foreignParent=node()
foreignCore,foreignOwner=gaugeFixture(function(widget) widget:removeElement(widget.innerRing);foreignParent:addElement(widget.innerRing) end)
''')
check('extraOwner and not extraOwner.gauge and extraCore.Circle:getParent()==extraCore and extraCore.radialAlphaLarge:getParent()==extraCore and extraCore.foreignBadge:getParent()==extraCore')
check('reorderedOwner and not reorderedOwner.gauge and reorderedCore.Circle:getParent()==reorderedCore and reorderedCore.innerRing:getParent()==reorderedCore')
check('foreignOwner and not foreignOwner.gauge and foreignCore.innerRing:getParent()==foreignParent and foreignCore.radialAlphaLarge:getParent()==foreignCore')
lua.execute(r'''
displacedCore,displacedOwner=gaugeFixture(function() end)
displacedGauge=displacedOwner.gauge;replacementParent=node()
displacedGauge.backing:removeElement(displacedCore.Circle);replacementParent:addElement(displacedCore.Circle)
models["inGame.CP.zombies.dpadUpFillPercent"]:set(0.6)
''')
check('displacedGauge.disabled and displacedGauge.view.alpha==0 and displacedGauge.backing.alpha==1 and displacedGauge.meter.alpha==1 and displacedCore.Circle:getParent()==replacementParent and displacedOwner.view.alpha==1')
lua.execute(r'''
models["inGame.CP.zombies.consumablesRemaining"]:set(0)
models["inGame.CP.zombies.dpadUpFillPercent"]:set(0)
models["inGame.CP.zombies.consumableDeckSelectReady"]:set(-1)
defaultReady=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=0})
defaultOwner=defaultReady.__bo3CardCore;defaultNativeCallback=defaultReady.nativeUpdate
for i=#printed,1,-1 do if string.find(printed[i],"[BO3 HUD] core ",1,true) then defaultTrace=printed[i];break end end
''')
check('defaultOwner and defaultOwner.count.text=="0" and defaultOwner.status.text=="EMPTY" and defaultOwner.mask.alpha==0 and defaultOwner.view.alpha==1 and models["inGame.CP.zombies.consumableDeckSelectReady"].value==-1 and string.find(defaultTrace,"ready_type=number ready_value=-1",1,true)')
lua.execute(r'''
observedEmpty=defaultOwner.gauge and defaultOwner.gauge.view.alpha==1 and defaultOwner.gauge.backing.alpha==0 and defaultOwner.gauge.meter.alpha==0 and defaultOwner.gauge.fill.alpha==0 and chargeFraction(defaultOwner.gauge)==0
models["inGame.CP.zombies.consumablesRemaining"]:set(5)
observedUnknown=defaultOwner.count.text=="5" and defaultOwner.status.text=="UNKNOWN" and defaultOwner.gauge.view.alpha==1 and defaultOwner.gauge.backing.alpha==0 and defaultOwner.gauge.meter.alpha==0 and defaultOwner.gauge.fill.alpha==0 and chargeFraction(defaultOwner.gauge)==0
''')
check('observedEmpty and observedUnknown and models["inGame.CP.zombies.dpadUpFillPercent"].value==0 and models["inGame.CP.zombies.consumableDeckSelectReady"].value==-1 and defaultReady.nativeUpdate==defaultNativeCallback')
lua.execute('models["inGame.CP.zombies.consumablesRemaining"]:set(3);models["inGame.CP.zombies.dpadUpFillPercent"]:set(0.25)')
check('defaultOwner.count.text=="3" and defaultOwner.status.text=="UNKNOWN" and defaultReady.radialAlphaLarge.circleFill.progress==0.25 and defaultReady.nativeUpdate==defaultNativeCallback')
check('defaultOwner.gauge and defaultOwner.gauge.view.alpha==1 and math.abs(chargeFraction(defaultOwner.gauge)-0.25)<0.000001 and models["inGame.CP.zombies.consumableDeckSelectReady"].value==-1')
lua.execute(r'''
models["inGame.CP.zombies.consumableDeckSelectReady"]:set(20)
refreshReady=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=0})
for i=#printed,1,-1 do if string.find(printed[i],"[BO3 HUD] core ",1,true) then refreshTrace=printed[i];break end end
models["inGame.CP.zombies.consumableDeckSelectReady"]:set(30)
''')
check('refreshReady.__bo3CardCore.status.text=="UNKNOWN" and defaultOwner.status.text=="UNKNOWN" and models["inGame.CP.zombies.consumableDeckSelectReady"].value==30 and string.find(refreshTrace,"ready_type=number ready_value=20",1,true) and string.find(refreshTrace,"reason=unknown",1,true)')
lua.execute('models["inGame.CP.zombies.consumableDeckSelectReady"]:set(0);notReadyText=defaultOwner.status.text;models["inGame.CP.zombies.consumableDeckSelectReady"]:set(1)')
check('notReadyText=="CHARGING" and defaultOwner.status.text=="READY" and defaultReady.nativeUpdate==defaultNativeCallback and defaultReady.glowRing.alpha==1')
lua.execute(r'''
invalidReadyRefused=true
for _,case in ipairs({{}, {value=false}, {value=true}, {value="1"}, {value={}}, {value=-2}, {value=31}, {value=0.5}, {value=0/0}, {value=math.huge}}) do
 models["inGame.CP.zombies.consumableDeckSelectReady"]:set(case.value)
 local widget=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=0})
 invalidReadyRefused=invalidReadyRefused and not widget.__bo3CardCore and BO3ZombiesHUD.cardDiagnostics[widget].signature=="values:ready_value"
end
models["inGame.CP.zombies.consumableDeckSelectReady"]:set(-1)
models["inGame.CP.zombies.consumablesRemaining"]:set(6)
badCount=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=0})
models["inGame.CP.zombies.consumablesRemaining"]:set(3)
models["inGame.CP.zombies.dpadUpFillPercent"]:set(0/0)
badFill=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=0})
models["inGame.CP.zombies.dpadUpFillPercent"]:set(0.25)
models["inGame.CP.zombies.dlc4.mephBattle"]:set(nil)
unknownBoss=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=0,nativeDlc4=true})
models["inGame.CP.zombies.dlc4.mephBattle"]:set(0)
models["inGame.CP.zombies.consumableDeckSelectReady"]:set(1)
''')
check('invalidReadyRefused')
check('not badCount.__bo3CardCore and BO3ZombiesHUD.cardDiagnostics[badCount].signature=="values:remaining_value" and not badFill.__bo3CardCore and BO3ZombiesHUD.cardDiagnostics[badFill].signature=="values:fill_value" and not unknownBoss.__bo3CardCore and BO3ZombiesHUD.cardDiagnostics[unknownBoss].signature=="values:boss_value"')
lua.execute(r'''
-- The native mock still owns its own model; only the adapter's public feed is absent.
savedBoss=DataSources.inGame.CP.zombies.dlc4.mephBattle
DataSources.inGame.CP.zombies.dlc4.mephBattle=nil
noBoss=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=0})
needsBoss=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=0,nativeDlc4=true})
''')
check('noBoss.__bo3CardCore and noBoss.__bo3CardCore.title.text=="CARDS" and not needsBoss.__bo3CardCore and BO3ZombiesHUD.cardDiagnostics[needsBoss].signature=="values:boss_value"')
lua.execute(r'''
DataSources.inGame.CP.zombies.dlc4.mephBattle=savedBoss
bossPointerCalls=0;savedBossPointer=savedBoss.GetModel
savedBoss.GetModel=function() bossPointerCalls=bossPointerCalls+1;return nil end
noBossPointer=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=0})
nonDLCPointerCalls=bossPointerCalls
needsBossPointer=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=0,nativeDlc4=true})
savedBoss.GetModel=savedBossPointer
''')
check('noBossPointer.__bo3CardCore and nonDLCPointerCalls==0 and bossPointerCalls==1 and not needsBossPointer.__bo3CardCore and BO3ZombiesHUD.cardDiagnostics[needsBossPointer].signature=="pointer:boss"')
lua.execute(r'''
models["inGame.CP.zombies.consumableDeckSelectReady"].value=false
falseReady=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=0})
falseReadyTrace=printed[#printed]
for i=#printed,1,-1 do if string.find(printed[i],"[BO3 HUD] core ",1,true) then falseReadyTrace=printed[i];break end end
models["inGame.CP.zombies.consumableDeckSelectReady"]:set(1)
''')
check('not falseReady.__bo3CardCore and string.find(falseReadyTrace,"reason=ready_value",1,true) and string.find(falseReadyTrace,"ready_type=boolean ready_value=false",1,true)')
lua.execute(r'''
bounded=MenuBuilder.BuildRegisteredType("FateCardDevilWidget",{controllerIndex=0})
boundedOwner=bounded.__bo3CardCore;boundedRecord=BO3ZombiesHUD.cardDiagnostics[bounded]
beforeSame=#printed
for i=1,10 do models["inGame.CP.zombies.dpadUpFillPercent"]:set(i/10) end
afterSame=#printed
for i=1,40 do models["inGame.CP.zombies.consumableDeckSelectReady"]:set(2);models["inGame.CP.zombies.consumableDeckSelectReady"]:set(1) end
boundedLines=0;boundedSuppression=0
for _,line in ipairs(printed) do
 if string.find(line,"[BO3 HUD] core version=0.7.0 widget_seq="..boundedRecord.sequence.." ",1,true) then
  boundedLines=boundedLines+1
  if string.find(line,"stage=suppressed reason=transition_limit",1,true) then boundedSuppression=boundedSuppression+1 end
 end
end
''')
check('beforeSame==afterSame and boundedLines==33 and boundedSuppression==1 and boundedRecord.count==33 and boundedOwner.mask.alpha==0 and boundedOwner.view.alpha==1')
lua.execute('compatibleVersions=true;for _,line in ipairs(printed) do if string.find(line,"[BO3 HUD] ",1,true) and string.find(line,"version=",1,true) and not string.find(line,"version=0.7.0",1,true) then compatibleVersions=false end end')
check('compatibleVersions')
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
check('not revive.visible and revive.Accent.alpha==0 and revive.Header.alpha==0 and revive.ProgressBar.Mask.bounds[2]==1')
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
lua.execute('failureRootSequence=BO3ZombiesHUD.roots[manager.activeHud]')
lua.execute('manager.nextHud.waveNumber._widget.WaveNumber=nil;LUI.HudManager.CreateHud(manager)')
check('string.find(BO3ZombiesHUD.messages["failure:ZMHUD"],"retry=1",1,true)~=nil')
check('BO3ZombiesHUD.messages["bind:ZMHUD:1"]==nil')
lua.execute('manager.nextHud.waveNumber._widget.WaveNumber=savedWave;LUI.HudManager.CreateHud(manager)')
check('BO3ZombiesHUD.messages["bind:ZMHUD:1"]~=nil')
lua.execute('manager.nextHud.waveNumber._widget.WaveNumber=nil;LUI.HudManager.CreateHud(manager)')
check('BO3ZombiesHUD.messages["bind:ZMHUD:1"]==nil')
lua.execute('failureCount=0;for _,message in ipairs(printed) do if string.find(message,"binding_failure",1,true) and string.find(message,"root_seq="..failureRootSequence.." ",1,true) then failureCount=failureCount+1 end end')
check('failureCount==2')
lua.execute(r'''
model("inGame.CP.zombies.consumableDeckSelectName","LOCALIZED IDENTITY NAME")
model("inGame.CP.zombies.consumableDeckSelectIcon","actual-selected-card-icon")
model("inGame.CP.zombies.consumableDeckSelectBacking","zm_wc_fate_card_base")
model("inGame.CP.zombies.consumableDeckSelectRarity","")
selected=MenuBuilder.BuildRegisteredType("FateCardOnDeck",{controllerIndex=2})
selectedOwner=selected.__bo3CardIdentity;selectedNativeName=selected.name;selectedNativeIcon=selected.icon;selectedNativeBacking=selected.cardBack
selectedCallbacks=selected.nativeIdentityCallbacks;selectedPhase=selected.nativePhase;selectedMeterFull=selected.nativeChildMeterFull
selectedInitialNameBounds=selected.name.bounds;selectedInitialIconBounds=selected.icon.bounds
''')
check('selectedOwner and selectedOwner.mode=="FATE" and selectedOwner.family.text=="FATE" and selectedOwner.rarity.text=="" and selectedOwner.rarity.alpha==0 and selectedOwner.mask.alpha==0 and selectedOwner.view.alpha==1')
check('selected.children[1]==selectedOwner.mask and selected.children[2]==selectedOwner.view and selected.children[3]==selectedNativeName and selected.children[4]==selectedNativeIcon and selectedNativeBacking:getParent()==selectedOwner.mask')
check('selected.name==selectedNativeName and selected.icon==selectedNativeIcon and selected.cardBack==selectedNativeBacking and selected.name.text=="LOCALIZED IDENTITY NAME" and selected.icon.image=="actual-selected-card-icon" and selected.cardBack.image=="zm_wc_fate_card_base" and selected.name.font=="native-name-font" and selected.name.size==20')
lua.execute('selected.nativePhase("refill");models["inGame.CP.zombies.consumableDeckSelectName"]:set("REFILL NAME");models["inGame.CP.zombies.consumableDeckSelectIcon"]:set("refill-native-icon");selected.nativePhase("refillDone")')
check('selected.alpha==1 and selected.name.alpha==0 and selected.icon.alpha==0 and selected.name.color==0 and selected.name.text=="REFILL NAME" and selected.icon.image=="refill-native-icon" and selectedOwner.view.alpha==1')
lua.execute('selected.nativePhase("cycle");selected.nativeChildMeterFull();models["inGame.CP.zombies.consumableDeckSelectName"]:set("NEW ACTUAL CARD");selectedParentBounds=selected.bounds;selectedChildNameBounds=selected.name.bounds;selectedChildIconBounds=selected.icon.bounds')
check('selected.name.alpha==1 and selected.icon.alpha==1 and selected.name.color==0xFFFFFF and selected.name.text=="NEW ACTUAL CARD" and selected.nativePhase==selectedPhase and selected.nativeChildMeterFull==selectedMeterFull and selected.nativeIdentityCallbacks==selectedCallbacks')
lua.execute(r'''
knownFortunes=true
models["inGame.CP.zombies.consumableDeckSelectBacking"]:set("zm_wc_fortune_card_base")
for _,rarity in ipairs({"common","rare","legendary","epic"}) do
 models["inGame.CP.zombies.consumableDeckSelectRarity"]:set(rarity)
 knownFortunes=knownFortunes and selectedOwner.mode=="FORTUNE" and selectedOwner.family.text=="FORTUNE" and selectedOwner.rarity.text==string.upper(rarity) and selectedOwner.rarity.alpha==1 and selectedOwner.mask.alpha==0 and selected.cardBack.image=="zm_wc_fortune_card_base"
end
''')
check('knownFortunes and selected.bounds==selectedParentBounds and selected.name.bounds==selectedChildNameBounds and selected.icon.bounds==selectedChildIconBounds')
lua.execute('models["inGame.CP.zombies.consumableDeckSelectRarity"]:set("unknown-future-rarity")')
check('selectedOwner.mode=="native" and selectedOwner.mask.alpha==1 and selectedOwner.view.alpha==0 and selected.name.alpha==1 and selected.icon.alpha==1')
lua.execute('models["inGame.CP.zombies.consumableDeckSelectBacking"]:set("future-card-backing");models["inGame.CP.zombies.consumableDeckSelectRarity"]:set("common")')
check('selectedOwner.mask.alpha==1 and selected.cardBack.image=="future-card-backing" and selected.name.text=="NEW ACTUAL CARD"')
lua.execute('models["inGame.CP.zombies.consumableDeckSelectBacking"]:set("zm_wc_fortune_card_base");models["inGame.CP.zombies.consumableDeckSelectName"]:set("")')
check('selectedOwner.mask.alpha==1 and selectedOwner.view.alpha==0 and selected.name.text=="" and selected.name.alpha==1')
lua.execute('models["inGame.CP.zombies.consumableDeckSelectName"]:set("RECOVERED ACTUAL NAME");models["inGame.CP.zombies.consumableDeckSelectIcon"]:set(nil)')
check('selectedOwner.mask.alpha==1 and selected.icon.image=="refill-native-icon"')
lua.execute('models["inGame.CP.zombies.consumableDeckSelectIcon"]:set("recovered-native-icon");selected.nativePhase("noMoreCards")')
check('selectedOwner.mask.alpha==0 and selectedOwner.view.alpha==1 and selected.alpha==0 and selected.name.text=="RECOVERED ACTUAL NAME" and selected.icon.image=="recovered-native-icon"')
lua.execute(r'''
function selectedFixture(mutate,index)
 nextSelectedShape=mutate
 local widget=MenuBuilder.BuildRegisteredType("FateCardOnDeck",{controllerIndex=index or 1})
 return widget,widget.__bo3CardIdentity
end
extraSelected,extraSelectedOwner=selectedFixture(function(widget) widget.foreign=node();widget:addElement(widget.foreign) end)
reorderedSelected,reorderedSelectedOwner=selectedFixture(function(widget) widget:removeElement(widget.name);widget:addElement(widget.name) end)
''')
check('not extraSelectedOwner and extraSelected.cardBack:getParent()==extraSelected and extraSelected.foreign:getParent()==extraSelected')
check('not reorderedSelectedOwner and reorderedSelected.name:getParent()==reorderedSelected and reorderedSelected.cardBack:getParent()==reorderedSelected')
lua.execute(r'''
savedSelectedRarity=DataSources.inGame.CP.zombies.consumableDeckSelectRarity
DataSources.inGame.CP.zombies.consumableDeckSelectRarity=nil
missingSelected,missingSelectedOwner=selectedFixture(function() end)
DataSources.inGame.CP.zombies.consumableDeckSelectRarity=savedSelectedRarity
savedSelectedPointer=savedSelectedRarity.GetModel;savedSelectedRarity.GetModel=function() return nil end
badPointerSelected,badPointerSelectedOwner=selectedFixture(function() end)
savedSelectedRarity.GetModel=savedSelectedPointer
''')
check('not missingSelectedOwner and missingSelected.cardBack:getParent()==missingSelected and not badPointerSelectedOwner and badPointerSelected.cardBack:getParent()==badPointerSelected')
lua.execute(r'''
selectedFailuresBefore=BO3ZombiesHUD.failures;malformedSelectedSafe=true
for _,value in ipairs({true,7}) do
 DataSources.inGame.CP.zombies.consumableDeckSelectRarity=value
 local widget,owner=selectedFixture(function() end)
 malformedSelectedSafe=malformedSelectedSafe and not owner and widget.cardBack:getParent()==widget
end
DataSources.inGame.CP.zombies.consumableDeckSelectRarity=savedSelectedRarity
savedSelectedReader=savedSelectedRarity.GetValue;savedSelectedRarity.GetValue=function() error("unavailable selected reader") end
throwReadSelected,throwReadOwner=selectedFixture(function() end)
savedSelectedRarity.GetValue=savedSelectedReader
savedSelectedRarity.GetModel=function() error("unavailable selected pointer") end
throwPointerSelected,throwPointerOwner=selectedFixture(function() end)
savedSelectedRarity.GetModel=savedSelectedPointer
''')
check('malformedSelectedSafe and not throwReadOwner and not throwPointerOwner and throwReadSelected.cardBack:getParent()==throwReadSelected and throwPointerSelected.cardBack:getParent()==throwPointerSelected and BO3ZombiesHUD.failures==selectedFailuresBefore')
lua.execute('foreignSelected,foreignSelectedOwner=selectedFixture(function() end);selectedForeignParent=node();foreignSelectedOwner.mask:removeElement(foreignSelected.cardBack);selectedForeignParent:addElement(foreignSelected.cardBack);models["inGame.CP.zombies.consumableDeckSelectRarity"]:set("rare")')
check('foreignSelectedOwner.disabled and foreignSelectedOwner.mask.alpha==1 and foreignSelectedOwner.view.alpha==0 and foreignSelected.cardBack:getParent()==selectedForeignParent and foreignSelected.name:getParent()==foreignSelected')
lua.execute(r'''
selectedRoot=stock_hud();rawSelected=original("FateCardOnDeck",{controllerIndex=1})
selectedRoot.wonderCard._widget.FateCardWidget.FateCardOnDeck=rawSelected
local fixtureManager={nextHud=selectedRoot};LUI.HudManager.CreateHud(fixtureManager)
rootSelectedOwner=rawSelected.__bo3CardIdentity;selectedChildren=#rawSelected.children
nameListeners=#models["inGame.CP.zombies.consumableDeckSelectName"].listeners
LUI.HudManager.CreateHud(fixtureManager);LUI.HudManager.CreateHud(fixtureManager)
''')
check('rootSelectedOwner and #rawSelected.children==selectedChildren and #models["inGame.CP.zombies.consumableDeckSelectName"].listeners==nameListeners')
lua.execute('selectedRoot.controllerIndex=3;LUI.HudManager.CreateHud({nextHud=selectedRoot})')
check('rootSelectedOwner.disabled and rootSelectedOwner.mask.alpha==1 and rootSelectedOwner.view.alpha==0 and rawSelected.name==rootSelectedOwner.leaves[2]')
lua.execute(r'''
sameModelSelected,sameModelOwner=selectedFixture(function() end,0)
model("inGame.CP.zombies.consumableDeckSelectRarity","rare")
models["inGame.CP.zombies.consumableDeckSelectName"]:set("MODEL IDENTITY CHANGE")
''')
check('sameModelOwner.disabled and sameModelOwner.mask.alpha==1 and sameModelOwner.view.alpha==0')
lua.execute(r'''
boundedSelected,boundedSelectedOwner=selectedFixture(function() end,0)
identityRecord=BO3ZombiesHUD.identityDiagnostics[boundedSelected]
for i=1,40 do models["inGame.CP.zombies.consumableDeckSelectRarity"]:set("epic");models["inGame.CP.zombies.consumableDeckSelectRarity"]:set("rare") end
identityLines=0;identitySuppression=0;identityNamesNotPrinted=true
for _,line in ipairs(printed) do
 if string.find(line,"[BO3 HUD] identity ",1,true) then
  identityNamesNotPrinted=identityNamesNotPrinted and not string.find(line,"LOCALIZED IDENTITY NAME",1,true) and not string.find(line,"MODEL IDENTITY CHANGE",1,true)
  if string.find(line,"widget_seq="..identityRecord.sequence.." ",1,true) then
   identityLines=identityLines+1
   if string.find(line,"stage=suppressed reason=transition_limit",1,true) then identitySuppression=identitySuppression+1 end
  end
 end
end
''')
check('identityRecord.count==33 and identityLines==33 and identitySuppression==1 and identityNamesNotPrinted and boundedSelectedOwner.view.alpha==1')
lua.execute(r'''
mapFixtures={}
for i,key in ipairs({"MainPlayerInfo","MainPlayerInfoDLC1","MainPlayerInfoDLC2","MainPlayerInfoDLC3","MainPlayerInfoDLC4"}) do
 local id=i==1 and "ZMHUD" or "ZMHUDDLC"..(i-1)
 local hud=stock_hud(id,key,(i-1)%4);local instance={nextHud=hud}
 local beforeState=#models["inGame.CP.zombies.secureState"].listeners
 local beforeProgress=#models["inGame.CP.zombies.secureProgress"].listeners
 LUI.HudManager.CreateHud(instance)
 mapFixtures[#mapFixtures+1]={root=hud,info=hud.mainPlayerInfo._widget[key],key=key,
  noActionSubscriptions=beforeState==#models["inGame.CP.zombies.secureState"].listeners and beforeProgress==#models["inGame.CP.zombies.secureProgress"].listeners}
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
lua.execute(r'''
function effectiveAlpha(leaf)
 local alpha=1
 while leaf do alpha=alpha*leaf.alpha;leaf=leaf:getParent() end
 return alpha
end
function nativeActionIntact(root)
 local a=root.reviveBarContainer._widget;local saved=root.retainedAction
 return a.Accent==saved.accent and a.Header==saved.header and a.Header.MessageText==saved.label
  and a.ProgressBar==saved.progress and a.ProgressBar.Fill==saved.fill and a.ProgressBar.Mask==saved.mask
  and a.SetHeader==root.retainedSetHeader and a.ProgressBar.SetProgress==root.retainedSetProgress
  and a.Accent:getParent()==a and a.Header:getParent()==a and a.ProgressBar:getParent()==a
  and a.Header.MessageText:getParent()==a.Header and a.ProgressBar.Fill:getParent()==a.ProgressBar
  and a.ProgressBar.Mask:getParent()==a.ProgressBar and a.ProgressBar.Fill.mask==saved.mask
  and a.ProgressBar.Fill.image==saved.fillImage and a.ProgressBar.Fill.bounds==saved.fillBounds
  and a.ProgressBar.Mask.image==saved.maskImage
end
''')
for i in range(1,6):
    check(f'nativeActionIntact(mapFixtures[{i}].root) and mapFixtures[{i}].noActionSubscriptions and mapFixtures[{i}].root.reviveBarContainer._widget.__bo3ActionView.view:getParent()==mapFixtures[{i}].root.retainedAction.accent')
lua.execute(r'''
action=mapFixtures[4].root.reviveBarContainer._widget;actionOwner=action.__bo3ActionView
actionChildren=#action.children;accentImage=action.Accent.image;nativeFont=action.Header.MessageText.font
models["inGame.CP.zombies.secureState"]:set(3);models["inGame.CP.zombies.secureProgress"]:set(0.4)
''')
check('action.visible and action.Header.MessageText.text=="REVIVING" and action.ProgressBar.Mask.bounds[2]==0.6 and effectiveAlpha(actionOwner.view)>0 and actionOwner.view.alpha==1')
lua.execute('action:SetHeader("A LONG ACTUAL LOCALIZED ACTION");measuredActionBounds=action.Header.bounds;LUI.HudManager.CreateHud({nextHud=mapFixtures[4].root})')
check('action.Header.MessageText.text=="A LONG ACTUAL LOCALIZED ACTION" and action.Header.bounds==measuredActionBounds and action.Header.MessageText.font==nativeFont and action.Header.MessageText.size==16 and action.Accent.image==accentImage and #action.children==actionChildren and #action.Accent.children==1')
lua.execute('action.ProgressBar:SetProgress(1.5,125)')
check('action.ProgressBar.Mask.bounds[2]==0 and action.ProgressBar.Mask.bounds[9]==125 and actionOwner.mask==action.ProgressBar.Mask')
lua.execute('models["inGame.CP.zombies.secureState"]:set(0);models["inGame.CP.zombies.secureProgress"]:set(0)')
check('not action.visible and action.alpha==1 and action.Accent.alpha==0 and effectiveAlpha(actionOwner.view)==0 and actionOwner.view.alpha==1 and not actionOwner.view.closed')
lua.execute('models["inGame.CP.zombies.secureState"]:set(21);models["inGame.CP.zombies.secureProgress"]:set(0.75)')
check('action.Header.MessageText.text=="SKEEBALL" and action.ProgressBar.Mask.bounds[2]==0.25 and effectiveAlpha(actionOwner.view)>0')
lua.execute('models["inGame.CP.zombies.secureState"]:set(22)')
check('action.visible and action.Header.MessageText.text=="" and actionOwner.view.alpha==1 and nativeActionIntact(mapFixtures[4].root)')
lua.execute(r'''
stateSource=models["inGame.CP.zombies.secureState"];progressSource=models["inGame.CP.zombies.secureProgress"]
nativeStateGetter=stateSource.GetValue;nativeProgressGetter=progressSource.GetValue
stateSource.GetValue=function(self,index) return index==2 and 3 or 0 end
progressSource.GetValue=function(self,index) return index==2 and 0.6 or 0 end
stateSource:set(0);progressSource:set(0)
''')
check('mapFixtures[3].root.retainedAction.label.text=="REVIVING" and mapFixtures[3].root.retainedAction.mask.bounds[2]==0.4 and not mapFixtures[1].root.reviveBarContainer._widget.visible and not mapFixtures[2].root.reviveBarContainer._widget.visible and not mapFixtures[4].root.reviveBarContainer._widget.visible and not mapFixtures[5].root.reviveBarContainer._widget.visible')
lua.execute('stateSource.GetValue=nativeStateGetter;progressSource.GetValue=nativeProgressGetter;stateSource:set(0);progressSource:set(0)')
lua.execute(r'''
malformedActionRoots={}
for _,fault in ipairs({"unknown","missing","primitive","order","foreign"}) do
 local r=stock_hud();local a=r.reviveBarContainer._widget
 if fault=="unknown" then a.id="ReviveBarContainerUnknown"
 elseif fault=="missing" then a.ProgressBar.Fill=nil
 elseif fault=="primitive" then a.Header=9
 elseif fault=="order" then local first=a.children[1];a.children[1]=a.children[2];a.children[2]=first
 else a.Accent:addElement(node()) end
 LUI.HudManager.CreateHud({nextHud=r});malformedActionRoots[#malformedActionRoots+1]=r
end
malformedActionsNative=true
for _,r in ipairs(malformedActionRoots) do
 malformedActionsNative=malformedActionsNative and r.__bo3HudLayout and r.reviveBarContainer._widget.__bo3ActionView==nil
end
''')
check('malformedActionsNative')
lua.execute(r'''
lateActionRoot=stock_hud();lateAction=lateActionRoot.reviveBarContainer._widget
savedLateMask=lateAction.ProgressBar.Mask;lateAction.ProgressBar.Mask=nil
LUI.HudManager.CreateHud({nextHud=lateActionRoot});lateHadNoView=lateAction.__bo3ActionView==nil
lateAction.ProgressBar.Mask=savedLateMask;LUI.HudManager.CreateHud({nextHud=lateActionRoot})
''')
check('lateHadNoView and lateAction.__bo3ActionView and nativeActionIntact(lateActionRoot)')
lua.execute(r'''
foreignActionRoot=stock_hud();LUI.HudManager.CreateHud({nextHud=foreignActionRoot})
foreignAction=foreignActionRoot.reviveBarContainer._widget;foreignActionOwner=foreignAction.__bo3ActionView
foreignActionParent=node();foreignAction.Accent:removeElement(foreignActionOwner.view);foreignActionParent:addElement(foreignActionOwner.view)
LUI.HudManager.CreateHud({nextHud=foreignActionRoot})
''')
check('foreignActionOwner.retired and foreignActionOwner.view.alpha==0 and foreignActionOwner.view:getParent()==foreignActionParent and not foreignActionOwner.view.closed and nativeActionIntact(foreignActionRoot)')
lua.execute(r'''
changedActionRoot=stock_hud();LUI.HudManager.CreateHud({nextHud=changedActionRoot})
changedAction=changedActionRoot.reviveBarContainer._widget;changedActionOwner=changedAction.__bo3ActionView
changedActionNativeHeader=changedAction.Header;changedAction.Header=7
LUI.HudManager.CreateHud({nextHud=changedActionRoot})
changedAction.Header=changedActionNativeHeader;LUI.HudManager.CreateHud({nextHud=changedActionRoot})
''')
check('changedActionOwner.retired and changedActionOwner.view.closed and changedActionOwner.view:getParent()==nil and #changedAction.Accent.children==0 and nativeActionIntact(changedActionRoot)')
lua.execute(r'''
foreignHookRoot=stock_hud();LUI.HudManager.CreateHud({nextHud=foreignHookRoot})
foreignHookAction=foreignHookRoot.reviveBarContainer._widget;foreignHookOwner=foreignHookAction.__bo3ActionView
foreignHeader=function(self,value) self.Header.MessageText:setText("FOREIGN "..value) end
foreignHookAction.SetHeader=foreignHeader;foreignActionChild=node();foreignHookAction.Accent:addElement(foreignActionChild)
LUI.HudManager.CreateHud({nextHud=foreignHookRoot})
''')
check('foreignHookOwner.retired and foreignHookOwner.view.closed and foreignHookAction.SetHeader==foreignHeader and foreignActionChild:getParent()==foreignHookAction.Accent and #foreignHookAction.Accent.children==1')
lua.execute(r'''
forgedRoot=stock_hud();LUI.HudManager.CreateHud({nextHud=forgedRoot})
forgedAction=forgedRoot.reviveBarContainer._widget;realOwnerBeforeForgery=forgedAction.__bo3ActionView
forgedParent=node();forgedView=node();forgedView.alpha=0.73;forgedParent:addElement(forgedView)
forgedTag={view=forgedView,accent=forgedParent,index=forgedRoot.controllerIndex}
forgedAction.__bo3ActionView=forgedTag;LUI.HudManager.CreateHud({nextHud=forgedRoot})
''')
check('forgedAction.__bo3ActionView==forgedTag and forgedView.alpha==0.73 and not forgedView.closed and forgedView:getParent()==forgedParent and realOwnerBeforeForgery.retired and realOwnerBeforeForgery.view.closed and nativeActionIntact(forgedRoot)')
lua.execute(r'''
tagReplacementCases={}
for _,kind in ipairs({"nil","number","boolean","object"}) do
 local r=stock_hud();LUI.HudManager.CreateHud({nextHud=r})
 local a=r.reviveBarContainer._widget;local owner=a.__bo3ActionView
 local entry={root=r,action=a,view=owner.view,weakOwner=setmetatable({owner},{__mode="v"})}
 if kind=="number" then entry.tag=17
 elseif kind=="boolean" then entry.tag=false
 elseif kind=="object" then
  entry.foreignParent=node();entry.foreignView=node();entry.foreignView.alpha=0.61;entry.foreignParent:addElement(entry.foreignView)
  entry.tag={view=entry.foreignView,accent=entry.foreignParent,index=r.controllerIndex}
 end
 a.__bo3ActionView=entry.tag;tagReplacementCases[#tagReplacementCases+1]=entry
end
collectgarbage("collect");collectgarbage("collect")
tagOwnersSurvived=true
for _,entry in ipairs(tagReplacementCases) do tagOwnersSurvived=tagOwnersSurvived and entry.weakOwner[1]~=nil and not entry.view.closed end
''')
check('tagOwnersSurvived')
lua.execute(r'''
tagReplacementProtected=true
for _,entry in ipairs(tagReplacementCases) do
 LUI.HudManager.CreateHud({nextHud=entry.root})
 tagReplacementProtected=tagReplacementProtected and entry.action.__bo3ActionView==entry.tag
  and entry.view.closed and entry.view:getParent()==nil and entry.view.__bo3ActionLifetime==nil
  and nativeActionIntact(entry.root)
 if entry.foreignView then tagReplacementProtected=tagReplacementProtected
  and entry.foreignView.alpha==0.61 and not entry.foreignView.closed and entry.foreignView:getParent()==entry.foreignParent end
end
''')
check('tagReplacementProtected')
lua.execute(r'''
collectgarbage("collect");collectgarbage("collect")
tagReplacementNotAdopted=true
for _,entry in ipairs(tagReplacementCases) do
 LUI.HudManager.CreateHud({nextHud=entry.root})
 tagReplacementNotAdopted=tagReplacementNotAdopted and entry.action.__bo3ActionView==entry.tag
  and #entry.action.Accent.children==0 and entry.view.closed
end
pretagRoot=stock_hud();pretagAction=pretagRoot.reviveBarContainer._widget
pretagParent=node();pretagView=node();pretagParent:addElement(pretagView)
pretag={view=pretagView,accent=pretagParent,index=pretagRoot.controllerIndex}
pretagAction.__bo3ActionView=pretag;LUI.HudManager.CreateHud({nextHud=pretagRoot})
''')
check('tagReplacementNotAdopted')
check('pretagAction.__bo3ActionView==pretag and not pretagView.closed and pretagView.alpha==1 and pretagView:getParent()==pretagParent and #pretagAction.Accent.children==0 and nativeActionIntact(pretagRoot)')
lua.execute('actionBeforeController=mapFixtures[2].root.reviveBarContainer._widget.__bo3ActionView')
lua.execute('changedController=mapFixtures[2].root;changedController.controllerIndex=3;LUI.HudManager.CreateHud({nextHud=changedController});changedCore=changedController.wonderCard._widget.FateCardWidget.FateCardDevilWidget.__bo3CardCore')
check('changedCore.mask.alpha==1 and changedCore.view.alpha==0 and changedCore.disabled')
check('changedCore.gauge.backing.alpha==1 and changedCore.gauge.meter.alpha==1 and changedCore.gauge.view.alpha==0')
check('actionBeforeController.retired and actionBeforeController.view.closed and nativeActionIntact(changedController)')
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
lua.execute(r'''
shutdownTagRoot=stock_hud();LUI.HudManager.CreateHud({nextHud=shutdownTagRoot})
shutdownTagAction=shutdownTagRoot.reviveBarContainer._widget;shutdownOwnedView=shutdownTagAction.__bo3ActionView.view
shutdownForeignParent=node();shutdownForeignView=node();shutdownForeignView.alpha=0.49;shutdownForeignParent:addElement(shutdownForeignView)
shutdownForeignTag={view=shutdownForeignView,accent=shutdownForeignParent,index=shutdownTagRoot.controllerIndex}
shutdownTagAction.__bo3ActionView=shutdownForeignTag;collectgarbage("collect")
shutdownFan=shutdownTagRoot.wonderCard._widget.FateCardWidget.fanCard1;shutdownFanView=shutdownFan.__bo3FanBack.view
shutdownFan.__bo3FanBack=fanForgedTag;collectgarbage("collect")
''')
lua.execute('BO3ZombiesHUD.shutdown()')
check('MenuBuilder.BuildRegisteredType==original')
check('existing.mainPlayerInfo._widget.PlayerCash.RefreshRows==existing.retainedTeamRefresh')
check('manager.activeHud.mainPlayerInfo._widget.PlayerCash.RefreshRows==otherRefresh')
check('coreOwner.mask.alpha==1 and coreOwner.view.alpha==0')
check('gauge.backing.alpha==1 and gauge.meter.alpha==1 and gauge.view.alpha==0 and nativePainterOrder(core,coreOwner) and core.nativeUpdate==nativeCoreUpdate and core.nativeRefill==nativeRefill')
check('selectedOwner.mask.alpha==1 and selectedOwner.view.alpha==0 and boundedSelectedOwner.mask.alpha==1 and boundedSelectedOwner.view.alpha==0 and selected.nativeIdentityCallbacks==selectedCallbacks and selected.name==selectedNativeName and selected.icon==selectedNativeIcon')
check('actionOwner.retired and actionOwner.view.closed and actionOwner.view:getParent()==nil and nativeActionIntact(mapFixtures[4].root) and foreignActionChild:getParent()==foreignHookAction.Accent and foreignHookAction.SetHeader==foreignHeader')
check('shutdownOwnedView.closed and shutdownOwnedView:getParent()==nil and shutdownOwnedView.__bo3ActionLifetime==nil and shutdownTagAction.__bo3ActionView==shutdownForeignTag and not shutdownForeignView.closed and shutdownForeignView.alpha==0.49 and shutdownForeignView:getParent()==shutdownForeignParent and nativeActionIntact(shutdownTagRoot)')
check('shutdownFanView.closed and shutdownFanView:getParent()==nil and shutdownFanView.__bo3FanLifetime==nil and shutdownFan.fanCard.image=="zm_wc_card_fan" and shutdownFan.fanOverlay.image=="zm_wc_card_fan_overlay" and shutdownFan.__bo3FanBack==fanForgedTag and not fanForeignView.closed and fanForeignView.alpha==0.47')
check('fanOwner.retired and fanOwner.view.closed and fan.fanCard==nativeFanImage and fan.fanOverlay==nativeFanOverlay and fan.alpha==1 and fan.zrotation==-25 and fan.scale==-0.5 and fan.fanOverlay.alpha==0.3 and fan.fanOverlay.color==0x263626 and #fan.children==2 and freshFan.alpha==0')
check('not probeOwner.probe.active and fan.SetAlpha==probeHooks[7].original and fan.fanOverlay.setImage==probeHooks[3].original and fan.fanOverlay.SetAnchorsAndPosition==probeHooks[4].original and returnFan.SetAlpha==returnFan.nativeAlphaSetter and returnFan.fanOverlay.SetAnchorsAndPosition==returnFan.nativeRectSetter and callbackFan.fanOverlay.SetAnchorsAndPosition==foreignFanSetter')
lua.execute('allFanRows=0;limitFanRows=0;for _,line in ipairs(printed) do if contains(line,"[BO3 HUD] fan ") then allFanRows=allFanRows+1;if contains(line,"reason=widget_limit") then limitFanRows=limitFanRows+1 end end end')
check('allFanRows<=529 and limitFanRows==1 and shutdownFan.__bo3FanBack==fanForgedTag')
lua.execute('roster[1].name="After shutdown";retiredTeam(existing.mainPlayerInfo._widget.PlayerCash)')
check('hero.BO3Name.text=="Live beyond startup"')

def capture_fan_wire(module_source, failed_sample=False, empty_discovery=False):
    """Run the authored module; capture actual print arguments outside Lua."""
    runtime = LuaRuntime()
    runtime.execute(setup)
    messages = []
    runtime.globals().print = messages.append
    runtime.globals().fail_sample = failed_sample
    runtime.globals().empty_discovery = empty_discovery
    runtime.execute(r'''
profileText=profilePayload;frontend=false;aliens=true;faultHits=0
if empty_discovery then
 local ordinaryPairs=pairs
 pairs=function(value)
  if type(value)=="table" and (rawget(value,"image_read")~=nil or rawget(value,"readback")~=nil) then
   faultHits=faultHits+1;return function() return nil end,value,nil
  end
  return ordinaryPairs(value)
 end
 for _ in pairs({image_read="unknown"}) do error("Boundary fault was not installed") end
end
nextFanShape=function(f)
 f.fanCard.getLocalRect=function() return 11,22,33,44 end
 f.fanOverlay.getLocalRect=function() return 51,52,53,54 end
 if fail_sample then f.getParent=function() error("controlled collection failure") end end
end
''')
    runtime.execute(module_source)
    runtime.execute('wireFan=MenuBuilder.BuildRegisteredType("FateFanCard",{controllerIndex=0});wireFan.fanOverlay:SetAnchorsAndPosition(0,1,0,1,301,302,303,304);wireFan:SetAlpha(0.35,18)')
    return runtime, messages


def assert_fan_wire_contract(module_source):
    """Empty-discovery is a boundary counterexample, not an HKS diagnosis.

    No copy of fan_trace or its formatter produces these captured messages.
    """
    expected = set("""sample_status readback slot root_seq_seen slot_match native_phase
        back_id overlay_id back_type overlay_type alpha_read image_read alpha_intent
        overlay_alpha_intent overlay_rgb_intent hooks hook_stop initial_writes_returned
        parent_read parent_l parent_t parent_r parent_b back_read back_l back_t back_r back_b
        overlay_read overlay_l overlay_t overlay_r overlay_b origin intent duration
        intent_l intent_r intent_t intent_b image_argument_type same_adapter_argument""".split())
    assert len(expected) == 42
    common = {"version", "widget_seq", "controller", "stage", "reason", "field_count", "pixels", "instance"}
    max_line_bytes = len("[BO3 HUD] fan ") + sum(len(key) + 1 + 40 + 1 for key in expected | common)
    assertions = 0
    for failed_sample, empty_discovery in [(False, False), (True, False), (False, True), (True, True)]:
        runtime, messages = capture_fan_wire(module_source, failed_sample, empty_discovery)
        emitted = []
        for message in messages:
            if message.startswith("[BO3 HUD] fan "):
                fields = dict(part.split("=", 1) for part in message.split()[3:])
                assert fields.get("field_count") == "42", "Fan print omitted the wire field count"
                assert expected <= fields.keys(), f"Fan print omitted fields: {expected - fields.keys()}"
                assert len(fields) == 50, "Fan print has missing, extra or duplicate wire fields"
                assert len(message.split()[3:]) == len(fields), "Fan print contains duplicate fields"
                emitted.append(fields)
                assertions += 4
        assert len(emitted) == 3, "The actual emitter must reach print for apply, geometry and alpha"
        assert emitted[0]["stage"] == "applied" and emitted[1]["stage"] == "overlay_rect" and emitted[2]["stage"] == "parent_alpha"
        assert all(row["image_read"] == "unknown" and row["alpha_read"] == "unknown" for row in emitted)
        assertions += 3
        assert all(len(value) <= 40 for row in emitted for value in row.values())
        assert all(len(message.encode("ascii")) + 1 <= max_line_bytes for message in messages if message.startswith("[BO3 HUD] fan "))
        assertions += 2
        if failed_sample:
            assert all(row["sample_status"] == "failed" and row["readback"] == "unknown_error" for row in emitted)
            assert all(row["back_read"] == "unknown" and row["back_l"] == "unknown" and row["root_seq_seen"] == "unknown" for row in emitted)
            assertions += 2
        else:
            assert all(row["sample_status"] == "complete" and row["back_read"] == "known" and row["overlay_read"] == "known" for row in emitted)
            assert emitted[1]["intent_l"] == "301.000" and emitted[1]["back_l"] == "11.000" and emitted[1]["overlay_l"] == "51.000"
            assert emitted[2]["alpha_intent"] == "0.350" and emitted[2]["native_phase"] == "unknown"
            assertions += 3
        if empty_discovery:
            assert runtime.globals().faultHits == 1, "The fixed emitter must not invoke dynamic sample-key discovery"
            assertions += 1
        runtime.execute('BO3ZombiesHUD.shutdown()')
    return assertions

wire_checks = assert_fan_wire_contract(source)
checks += wire_checks
print(f"PASS {checks} authored Lua5.1 source controls; mocked UI/models only, no HKS/game/pixels")
