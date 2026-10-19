#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "game/scripting/execution.hpp"
#include "gsc/script_extension.hpp"
#include "gsc/script_loading.hpp"
#include "command.hpp"
#include "party.hpp"
#include "scheduler.hpp"
#include "scripting.hpp"
#include "console/console.hpp"
#include "cutscene.hpp"
#include "cutscene_policy.hpp"
#include <utils/compression.hpp>
#include <utils/hook.hpp>
#include <utils/flags.hpp>
#if __has_include("paris_test_safety.hpp")
#include "paris_test_safety.hpp"
#define IW7_CUTSCENE_PRIVATE_TEST 1
#endif

namespace cutscene {
namespace {
using xsk::gsc::opcode;
struct rule { const char* file; const char* function; const char* movie; float seconds; };
const rule rules[] = {
    {"scripts/cp/maps/cp_rave/cp_rave_super_slasher_fight", "delay_try_drop_talisman", "zombies_cp_rave_outro",32},
    {"scripts/cp/maps/cp_rave/cp_rave_super_slasher_fight", "delay_resume_wave_progression", "zombies_cp_rave_outro",37},
    {"scripts/cp/maps/cp_disco/rat_king_fight", "sound_duck_end_bink", "zombies_cp_disco_outro",55},
    {"scripts/cp/maps/cp_disco/rat_king_fight", "delay_resume_wave_progression", "zombies_cp_disco_outro",60},
    {"scripts/cp/maps/cp_town/cp_town_crab_boss_bomb", "delay_resume_wave_progression", "sysmainunload",71.15f},
    {"scripts/cp/maps/cp_town/cp_town_crab_boss_bomb", "delay_drop_talisman", "sysmainunload",71.15f},
    {"scripts/cp/maps/cp_town/cp_town_crab_boss_bomb", "delay_give_rewards", "sysmainunload",71.15f},
    {"scripts/cp/maps/cp_final/cp_final_rhino_boss", "rhino_fight_over", "sysload_o1",106.5f},
    {"scripts/cp/maps/cp_final/cp_final_rhino_boss", "delay_give_rewards", "sysload_o1",34.15f},
    {"scripts/cp/maps/cp_final/cp_final_final_boss", "auto_start_boss_fight", "sysload_o2",86.5f},
    {"scripts/cp/maps/cp_final/cp_final_final_boss", "try_to_leave_bossfight", "sysload_o2",86.5f},
    {"scripts/cp/maps/cp_zmb/cp_zmb_ufo", "soul_key_pick_up_monitor", "sysload_o4",137},
    {"scripts/cp/maps/cp_disco/disco_mpq", "p2t3_0_missing_reel", "MissingReel",7},
    {"scripts/cp/maps/cp_disco/disco_mpq", "missing_reel_pickup_players", "MissingReel",6},
};
struct site { unsigned rule; const char* pos; std::array<unsigned char,20> code; };
std::vector<std::unique_ptr<site>> sites;
std::unordered_set<const game::ScriptFile*> observed;
std::array<unsigned, std::size(rules)> captured{};
struct sleeper { unsigned rule; unsigned epoch; int started; int deadline; };
std::unordered_map<unsigned, sleeper> waits;
unsigned epoch{};
int finish_time{};
bool active{}, enabled{};
std::string movie;
iw7::cutscene::ballot ballot;
struct remote_input { unsigned mask{}; std::uint64_t received{}; unsigned epoch{}; };
std::array<remote_input,4> inputs{};
std::array<unsigned,4> published_epoch{};
std::uint16_t begin_id{}, pending_id{};
std::array<bool,3> keys{};
unsigned key_epoch{};
#ifdef IW7_CUTSCENE_PRIVATE_TEST
bool test_keys{};
#endif
unsigned client_epoch() {
    const auto* setting=game::Dvar_FindVar("paris_cutscene_epoch");
    return setting && setting->type==game::DVAR_TYPE_INT && setting->current.integer>0 ? static_cast<unsigned>(setting->current.integer):0;
}
int clock() { return scripting::call<int>("gettime"); }
unsigned thread() { return game::scr_function_stack->localId; }
game::client_t* player(unsigned slot) {
    if (!game::environment::is_dedi() || !game::SV_Loaded() || !*game::svs_clients ||
        slot >= 4 || slot >= static_cast<unsigned>(*game::svs_numclients)) return nullptr;
    auto* c = *game::svs_clients + slot;
    return c->header.state == game::CS_ACTIVE && c->gentity == &game::g_entities[slot] && c->gentity->client ? c : nullptr;
}
void roster() {
    for(unsigned slot=0;slot<4;++slot) {
        auto* c=player(slot);
        std::string identity;
        if(c) identity=std::string(c->playerGuid,strnlen(c->playerGuid,sizeof(c->playerGuid)))+":"+
            std::to_string(c->remoteAddress.port)+":"+std::to_string(c->remoteAddress.ip[0])+":"+
            std::to_string(c->remoteAddress.ip[1])+":"+std::to_string(c->remoteAddress.ip[2])+":"+std::to_string(c->remoteAddress.ip[3]);
        if(ballot.players[slot].identity!=identity) {inputs[slot]={};published_epoch[slot]=0;}
        ballot.roster(slot,identity);
    }
}
bool ready(const std::string& name) {
    bool found{};
    for(unsigned i=0;i<std::size(rules);++i) if(name==rules[i].movie) {
        found=true;
        if(captured[i]!=1) return false;
    }
    return found;
}
void install() {
    for(auto& s:sites) {
        if(*s->pos!=0x79) throw std::runtime_error("Cutscene wait opcode changed");
        s->code=iw7::cutscene::wait_thunk(begin_id,pending_id);
        const auto* start=reinterpret_cast<const char*>(s->code.data());
        gsc::redirect_code(s->pos,start);
        gsc::redirect_code(start+19,s->pos+1);
    }
    console::info("[Paris cutscene] Installed %zu scoped retail wait continuations.\n",sites.size());
}
void tick() {
    if(!active || !enabled) return;
    roster();
    const auto now=GetTickCount64();
    for(unsigned slot=0;slot<4;++slot) if(player(slot)) {
        const scripting::entity p(game::scr_entref_t{static_cast<unsigned short>(slot),0});
        unsigned mask{};
        const auto& raw=inputs[slot];
        // Updated clients report the three physical keys. Older clients retain
        // native jump/fire support without a different protocol or forced mod.
        if(raw.epoch==epoch) {
            if(now>=raw.received && now-raw.received<=250) mask=raw.mask;
        } else {
            if(p.call("jumpbuttonpressed").as<int>())mask|=1;
            if(p.call("attackbuttonpressed").as<int>())mask|=4;
        }
        const bool voted=ballot.players[slot].voted;
        ballot.input(slot,mask,now);
        if(!voted && ballot.players[slot].voted)console::info("[Paris cutscene] Vote epoch=%u slot=%u total=%u/%u\n",epoch,slot,ballot.votes(),ballot.total());
        if(published_epoch[slot]!=epoch) {
            p.call("setclientdvar", {"paris_cutscene_epoch",static_cast<int>(epoch)});
            published_epoch[slot]=epoch;
        }
    }
}
void end() {
    const auto now=clock();
    const auto removed=enabled && ballot.unanimous() ? std::max(0,finish_time-now) : 0;
    for(auto& [id,w]:waits) if(w.epoch==epoch) w.deadline-=removed;
    active=false;
    for(unsigned slot=0;slot<4;++slot)if(player(slot))
        scripting::entity(game::scr_entref_t{static_cast<unsigned short>(slot),0}).call("setclientdvar",{"paris_cutscene_epoch",0});
    console::info("[Paris cutscene] Complete movie=%s epoch=%u removed_ms=%d votes=%u/%u\n",movie.c_str(),epoch,removed,ballot.votes(),ballot.total());
}
void client_tick() {
    static unsigned previous{};
    static std::uint64_t sent{};
    const auto current=client_epoch();
    if(!current || game::Com_GameMode_GetActiveGameMode()!=game::GAME_MODE_CP ||
        game::clientUIActives[0].connectionState!=game::CA_ACTIVE || game::Com_IsAnyLocalServerRunning()) {previous=0;keys={};key_epoch=0;return;}
    if(current!=key_epoch){keys={};key_epoch=current;}
    unsigned mask{};
    const auto foreground=GetForegroundWindow(); DWORD owner{};GetWindowThreadProcessId(foreground,&owner);
    bool focused=owner==GetCurrentProcessId();
#ifdef IW7_CUTSCENE_PRIVATE_TEST
    if(test_keys) focused=paris_test_fixture::client_protection_current(paris_test_fixture::client_protection(nullptr),GetTickCount64());
#endif
    if(focused && !(*game::keyCatchers & 1)) {
        for(unsigned i=0;i<keys.size();++i)if(keys[i])mask|=1u<<i;
    }else keys={};
    const auto now=GetTickCount64();
    if(current!=previous || now-sent>=100) {
        command::execute("cmd paris_cutscene_hold "+std::to_string(current)+" "+std::to_string(mask));
        previous=current;sent=now;
    }
}
}

bool key_event(int key,bool down) {
    const unsigned index=key==game::K_SPACE ? 0:key==game::K_ENTER ? 1:key==game::K_MOUSE1 ? 2:3;
    if(index==3)return false;
    const auto current=client_epoch();
    if(current!=key_epoch){keys={};key_epoch=current;}
    if(!down){keys[index]=false;return false;} // Always let retail release pre-video input.
    if(!current || game::environment::is_dedi() || (*game::keyCatchers & 1) ||
        game::Com_GameMode_GetActiveGameMode()!=game::GAME_MODE_CP ||
        game::clientUIActives[0].connectionState!=game::CA_ACTIVE || game::Com_IsAnyLocalServerRunning())return false;
    if(!keys[index])console::info("[Paris cutscene input] epoch=%u key=%u down=1\n",current,index);
    keys[index]=true;
    return true; // Enter cannot open chat while casting a cinematic vote.
}

void observe_script(const std::string& file,game::ScriptFile* script) {
    if(!game::environment::is_dedi() || !script || observed.contains(script))return;
    if(std::none_of(std::begin(rules),std::end(rules),[&](const rule& r){return file==r.file;}))return;
    observed.insert(script);
    try {
        if(script->compressedLen<=0 || script->bytecodeLen<=0)throw std::runtime_error("Expected original compressed ScriptFile");
        const auto stack=utils::compression::zlib::decompress({script->buffer,static_cast<std::size_t>(script->compressedLen)});
        auto assembly=gsc::gsc_ctx->disassembler().disassemble(reinterpret_cast<const unsigned char*>(script->bytecode),script->bytecodeLen,
            reinterpret_cast<const unsigned char*>(stack.data()),stack.size());
        for(unsigned row=0;row<std::size(rules);++row)if(file==rules[row].file)
            for(const auto& fn:assembly->functions)if(fn->name==rules[row].function)
                for(std::size_t i=1;i<fn->instructions.size();++i) {
                    const auto& op=*fn->instructions[i];const auto& before=*fn->instructions[i-1];
                    if(op.opcode!=opcode::OP_wait)continue;
                    bool match{};
                    if(row==11) match=true; // This function has exactly one variable-duration wait (137s).
                    else if((before.opcode==opcode::OP_GetFloat || before.opcode==opcode::OP_GetByte ||
                        before.opcode==opcode::OP_GetUnsignedShort || before.opcode==opcode::OP_GetInteger) && !before.data.empty())
                        match=std::abs(std::stof(before.data[0])-rules[row].seconds)<.002f;
                    if(!match)continue;
                    auto s=std::make_unique<site>();s->rule=row;s->pos=script->bytecode+op.index;
                    sites.push_back(std::move(s));++captured[row];
                }
        console::info("[Paris cutscene] Captured unlinked retail waits file=%s sites=%zu\n",file.c_str(),sites.size());
    }catch(const std::exception& e){console::warn("[Paris cutscene] Skip disabled for changed retail input: %s\n",e.what());}
}

class component final:public component_interface {
public:
void post_unpack() override {
    gsc::function::add("paris_cutscene_wait_begin",[](const gsc::function_args& args)->scripting::script_value {
        const auto value=args[0].get_raw();
        const float seconds=value.type==game::VAR_INTEGER ? static_cast<float>(value.u.intValue) : args[0].as<float>();
        const auto* return_pos=game::scr_function_stack->pos;
        const auto found=std::find_if(sites.begin(),sites.end(),[&](const auto& s){return return_pos==reinterpret_cast<const char*>(s->code.data())+3;});
        if(found==sites.end() || !std::isfinite(seconds) || seconds<0 || seconds>600)throw std::runtime_error("Invalid scoped cutscene wait");
        const auto index=(*found)->rule;const auto now=clock();
        waits[thread()]={index,active && movie==rules[index].movie ? epoch:0,now,now+static_cast<int>(std::ceil(seconds*1000))};
        return {};
    });
    begin_id=gsc::gsc_ctx->func_id("paris_cutscene_wait_begin");
    gsc::function::add("paris_cutscene_wait_pending",[](const gsc::function_args&)->scripting::script_value {
        const auto it=waits.find(thread());
        if(it==waits.end())throw std::runtime_error("Missing scoped cutscene wait");
        if(clock()<it->second.deadline)return 1;
        waits.erase(it);return 0;
    });
    pending_id=gsc::gsc_ctx->func_id("paris_cutscene_wait_pending");
    gsc::function::add("paris_cutscene_begin",[](const gsc::function_args& args)->scripting::script_value {
        if(active)throw std::runtime_error("Overlapping cutscene workers");
        movie=args[0].as<std::string>();const auto raw=args[1].get_raw();
        const auto duration=raw.type==game::VAR_INTEGER ? static_cast<float>(raw.u.intValue):args[1].as<float>();
        const auto now=clock();if(++epoch==0)++epoch;active=true;enabled=ready(movie);
        finish_time=now+static_cast<int>(duration*1000);ballot={};inputs={};published_epoch={};roster();
        for(auto& [id,w]:waits)if(!w.epoch && movie==rules[w.rule].movie && now-w.started>=0 && now-w.started<=2500)w.epoch=epoch;
        console::info("[Paris cutscene] Begin movie=%s epoch=%u enabled=%d seconds=%.2f\n",movie.c_str(),epoch,enabled,duration);
        return enabled ? 1:0;
    });
    gsc::function::add("paris_cutscene_pending",[](const gsc::function_args&)->scripting::script_value {
        return active && clock()<finish_time && !(enabled && ballot.unanimous()) ? 1:0;
    });
    gsc::function::add("paris_cutscene_text",[](const gsc::function_args&)->scripting::script_value {
        std::string text="Hold SPACE (2s) to skip";
        if(ballot.total()>1)text+="\n"+std::to_string(ballot.votes())+"/"+std::to_string(ballot.total())+" Voted to skip the cutscene";
        return text;
    });
    gsc::function::add("paris_cutscene_end",[](const gsc::function_args&)->scripting::script_value{end();return {};});
    scripting::on_shutdown([](bool,bool){active=false;waits.clear();sites.clear();observed.clear();captured={};inputs={};});
#ifdef IW7_CUTSCENE_PRIVATE_TEST
    gsc::method::add("paris_cutscene_test_hold",[](game::scr_entref_t ent,const gsc::function_args& args)->scripting::script_value{
        if(ent.classnum || ent.entnum>=4 || !active || !enabled || !utils::flags::has_flag("paris-isolated-lab"))return 0;
        const bool protected_bot=player(ent.entnum) && game::SV_BotIsBot(ent.entnum) &&
            (game::g_entities[ent.entnum].flags & 1) && paris_test_fixture::is_protected_player(0);
        if(!paris_test_fixture::is_protected_player(ent.entnum) && !protected_bot)return 0;
        const auto mask=args[0].as<int>();if(mask<0 || mask>7)return 0;
        inputs[ent.entnum]={static_cast<unsigned>(mask),GetTickCount64(),epoch};return 1;
    });
#endif
    scheduler::once([] {
        if(game::environment::is_dedi()) {
            command::add("paris_cutscene_install",install);
            command::add_sv("paris_cutscene_hold",[](int slot,const command::params_sv& args){
                if(!active || !enabled || slot<0 || slot>=4 || !player(slot) || args.size()!=3)return;
                const std::string a=args[1],b=args[2];
                if(a.empty() || a.size()>10 || a.find_first_not_of("0123456789")!=std::string::npos || b.size()!=1 || b[0]<'0' || b[0]>'7')return;
                if(std::strtoull(a.c_str(),nullptr,10)!=epoch)return;
                inputs[slot]={static_cast<unsigned>(b[0]-'0'),GetTickCount64(),epoch};
            });
            scheduler::loop([]{try{tick();}catch(const std::exception& e){console::warn("[Paris cutscene] Input state unavailable: %s\n",e.what());}},scheduler::pipeline::server,50ms);
        }else {
            game::Dvar_RegisterInt("paris_cutscene_epoch",0,0,INT_MAX,game::DVAR_FLAG_NONE,"Server cutscene input epoch");
            scheduler::loop(client_tick,scheduler::pipeline::main,25ms);
#ifdef IW7_CUTSCENE_PRIVATE_TEST
            command::add("paris_cutscene_test_key",[](const command::params& args){
                if(args.size()!=2 || !client_epoch() || !utils::flags::has_flag("paris-isolated-lab") ||
                    !paris_test_fixture::client_protection_current(paris_test_fixture::client_protection(nullptr),GetTickCount64()))return;
                const std::string action=args[1];
                const int key=action=="space" ? game::K_SPACE:action=="enter" ? game::K_ENTER:action=="mouse" ? game::K_MOUSE1:0;
                if(!key && action!="release")return;
                test_keys=true;
                for(const auto value:{game::K_SPACE,game::K_ENTER,game::K_MOUSE1})
                    utils::hook::invoke<void>(0x1409A7980,0,value,0);
                if(key)utils::hook::invoke<void>(0x1409A7980,0,key,1);
            });
#endif
        }
    },scheduler::pipeline::main);
}
};
}
REGISTER_COMPONENT(cutscene::component)
