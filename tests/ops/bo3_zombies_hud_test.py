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
lua.execute(r'''
_1080p=1
config={}; frontend=true; pending={}; originals=0; nodes={}; models={}
Engine={GetDvarString=function(name) return config[name] or "" end,
 InFrontend=function() return frontend end, Localize=function(value) return value end}
scheduler={once=function(fn) pending[#pending+1]=fn end}
FONTS={MainBold={File="stock-bold"},GetFont=function(value) return value end}
RegisterMaterial=function(value) return value end
function node()
 local n={children={},alpha=1,closed=false}
 function n:SetAnchorsAndPosition(...) self.bounds={...} end
 function n:SetFont(value) self.font=value end
 function n:SetFontSize(value) self.size=value end
 function n:SetAlignment(value) end
 function n:SetRGBFromInt(value) self.color=value end
 function n:SetYRotation(value) end
 function n:SetZRotation(value) end
 function n:SetAlpha(value) self.alpha=value end
 function n:setText(value) self.text=value end
 function n:setImage(value) self.image=value end
 function n:addElement(child) self.children[#self.children+1]=child end
 function n:removeElement(child) child.detached=true end
 function n:getRootController() return 0 end
 function n:SubscribeToModel(model,fn) model.listeners[#model.listeners+1]=fn end
 function n:BindAlphaToModel(model) self:SubscribeToModel(model,function() self.alpha=model.value end); self.alpha=model.value end
 function n:GetDataSource() return self.data end
 function n:SubscribeToModelThroughElement(parent,key,fn) self.through=fn end
 function n:close() self.closed=true end
 nodes[#nodes+1]=n
 return n
end
LUI={UIElement={new=node},UIText={new=node},UIImage={new=node},Alignment={Left=0}}
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
  n.box=node(); n.dollarSign=node(); n.questFuse=node(); n:addElement(n.questFuse)
 end
 return n
end
MenuBuilder={BuildRegisteredType=original}
function tick() local fn=table.remove(pending,1); if fn then fn() end end
function child(n,id) for _,v in ipairs(n.children) do if v.id==id then return v end end end
''')
lua.execute(source)
checks = 0
def check(code):
    global checks
    lua.execute("assert(" + code + ")")
    checks += 1

lua.execute("tick()")
check("MenuBuilder.BuildRegisteredType==original")
lua.execute('config.bo3_zombies_hud_enable="1";config.bo3_zombies_hud_private="1";config.ui_gametype="zombie"; BO3ZombiesHUD.closed=false;')
lua.execute("tick()")
check("MenuBuilder.BuildRegisteredType~=original")
lua.execute("saved=MenuBuilder.BuildRegisteredType;queued=#pending")
lua.execute(source)
check("MenuBuilder.BuildRegisteredType==saved and #pending==queued")
lua.execute('w=MenuBuilder.BuildRegisteredType("WaveNumber",{controllerIndex=1})')
check('w.id=="stock:WaveNumber"')
lua.execute('frontend=false; config.ui_gametype="war";w=MenuBuilder.BuildRegisteredType("WaveNumber",{controllerIndex=1})')
check('w.id=="stock:WaveNumber"')
lua.execute('config.ui_gametype="zombie";model("inGame.CP.zombies.waveNumber",17);w=MenuBuilder.BuildRegisteredType("WaveNumber",{controllerIndex=1})')
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
model("inGame.player.currentWeapon.displayNameMultiline","ACTUAL PAP NAME")
model("inGame.player.currentWeapon.ammoInfoAlpha",1)
model("inGame.player.currentWeapon.ammoReserveAlpha",1)
model("inGame.player.currentWeapon.isDualWielding",false)
model("inGame.player.currentWeapon.isMeleeWeapon",false)
a=MenuBuilder.BuildRegisteredType("weaponinfoZM",{controllerIndex=1})
''')
check('child(a,"BO3ClipRight").text=="12" and child(a,"BO3Reserve").text=="48"')
check('child(a,"BO3WeaponName").text=="ACTUAL PAP NAME"')
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
lua.execute('config.bo3_zombies_hud_enable="0";r=MenuBuilder.BuildRegisteredType("WaveNumber",{controllerIndex=1})')
check('r.id=="stock:WaveNumber"')
lua.execute('BO3ZombiesHUD.shutdown()')
check('MenuBuilder.BuildRegisteredType==original')
lua.execute('config.bo3_zombies_hud_enable="1";r=saved("WaveNumber",{controllerIndex=1})')
check('r.id=="stock:WaveNumber"')
for forbidden in ("cg_draw2D", "SetDvar", ":SetValue(", "setweapon", "PlayerHealth"):
    assert forbidden not in source, forbidden
checks += 1
print(f"PASS {checks} authored Lua5.1 source controls; mocked UI/models only, no HKS/game/pixels")
