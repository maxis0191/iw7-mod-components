#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "auto_capacity.hpp"
#include "auto_capacity_policy.hpp"
#include "paris_agent_capacity.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include "network.hpp"
#include "party.hpp"
#include "scheduler.hpp"
#include <utils/flags.hpp>
#include <utils/io.hpp>
#include <utils/cryptography.hpp>
#include <shellapi.h>

namespace auto_capacity {
namespace {
std::wstring image;
std::string image_hash;
std::vector<std::wstring> original;
std::wstring resume_target,required;
int resume_mode=3;
bool reconnect_pending{},switching{};
std::string executable_bytes() {
    auto h=CreateFileW(image.c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(h==INVALID_HANDLE_VALUE)throw std::runtime_error("Cannot read automatic-profile client");
    try {
        LARGE_INTEGER size{};
        if(!GetFileSizeEx(h,&size) || size.QuadPart<=0 || size.QuadPart>32*1024*1024)
            throw std::runtime_error("Invalid automatic-profile executable size");
        std::string bytes(static_cast<std::size_t>(size.QuadPart),'\0');
        std::size_t offset{};
        while(offset<bytes.size()) {
            DWORD read{};const auto remaining=static_cast<DWORD>(std::min<std::size_t>(1024*1024,bytes.size()-offset));
            if(!ReadFile(h,bytes.data()+offset,remaining,&read,nullptr) || !read)throw std::runtime_error("Incomplete client executable read");
            offset+=read;
        }
        const bool closed=CloseHandle(h)!=FALSE;h=nullptr;
        if(!closed)throw std::runtime_error("Client executable read handle did not close");
        return bytes;
    }catch(...) {if(h)CloseHandle(h);throw;}
}
void event(const char* name,const char* wire,unsigned child=0,ULONGLONG stamp=0) noexcept {
    try {
        const auto root=std::filesystem::current_path()/"iw7-mod"/"server-profiles";
        for(auto p=root;!p.empty();) {
            const auto attributes=GetFileAttributesW(p.c_str());
            if(attributes!=INVALID_FILE_ATTRIBUTES && (attributes&FILE_ATTRIBUTE_REPARSE_POINT))return;
            const auto parent=p.parent_path();if(parent==p)break;p=parent;
        }
        // Operational journal only: no address, password, name or player identity.
        std::filesystem::create_directories(root);
        const auto path=root/"auto-capacity.events.jsonl";
        if(std::filesystem::exists(path) && std::filesystem::file_size(path)>1024*1024)return;
        const auto line=std::string("{\"event\":\"")+name+"\",\"wire\":\""+wire+"\",\"pid\":"+
            std::to_string(GetCurrentProcessId())+",\"child\":"+std::to_string(child)+",\"child_creation\":"+std::to_string(stamp)+"}\n";
        const auto h=CreateFileW(path.c_str(),FILE_APPEND_DATA,FILE_SHARE_READ,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(h==INVALID_HANDLE_VALUE)return;
        DWORD written{};WriteFile(h,line.data(),static_cast<DWORD>(line.size()),&written,nullptr);CloseHandle(h);
    }catch(...) {}
}
std::wstring option(std::wstring_view prefix) {
    std::wstring result;unsigned count{};
    for(const auto& arg:original) if(arg.substr(0,prefix.size())==prefix) {result=arg.substr(prefix.size());++count;}
    if(count>1) throw std::runtime_error("Duplicate automatic profile argument");
    return result;
}
ULONGLONG creation(HANDLE handle) {
    FILETIME created{},exit{},kernel{},user{};
    if(!GetProcessTimes(handle,&created,&exit,&kernel,&user)) throw std::runtime_error("Cannot verify profile process identity");
    ULARGE_INTEGER value{};value.LowPart=created.dwLowDateTime;value.HighPart=created.dwHighDateTime;return value.QuadPart;
}
void wait_for_parent(const std::wstring& text) {
    if(text.empty())return;
    const auto colon=text.find(L':');
    if(colon==text.npos) throw std::runtime_error("Invalid profile parent identity");
    std::size_t a{},b{};
    const auto pid=std::stoul(text.substr(0,colon),&a);
    const auto stamp=std::stoull(text.substr(colon+1),&b);
    if(a!=colon || b!=text.size()-colon-1 || !pid || !stamp || pid==GetCurrentProcessId())
        throw std::runtime_error("Invalid profile parent identity");
    const auto handle=OpenProcess(SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
    if(!handle) {
        if(GetLastError()==ERROR_INVALID_PARAMETER) return; // original process already gone
        throw std::runtime_error("Cannot inspect original profile process");
    }
    try {
        // A reused PID cannot name the original process; do not wait on or stop it.
        if(creation(handle)==stamp && WaitForSingleObject(handle,45000)!=WAIT_OBJECT_0)
            throw std::runtime_error("Original client did not close; automatic reconnect cancelled");
    }catch(...) {CloseHandle(handle);throw;}
    CloseHandle(handle);
}
bool private_identity() {
    for(const auto& arg:original) if(arg==L"-dedicated" || arg==L"-paris-isolated-lab" ||
        arg==L"-paris-debugger" || arg==L"-paris-server-test" || arg==L"-paris-server-client-test") return true;
    return false;
}
void verify_profile_path() {
    const auto root=std::filesystem::current_path()/"iw7-mod"/"server-profiles"/"capacity64-v2";
    for(auto path=root;!path.empty();) {
        const auto attributes=GetFileAttributesW(path.c_str());
        if(attributes!=INVALID_FILE_ATTRIBUTES && (attributes&FILE_ATTRIBUTE_REPARSE_POINT))
            throw std::runtime_error("Redirected automatic profile folder refused");
        const auto parent=path.parent_path();if(parent==path)break;path=parent;
    }
    std::filesystem::create_directories(root/"players2");
    const auto manifest=root/"profile.json";
    const std::string expected="{\"schema\":\"iw7.auto-capacity-profile/1\",\"wire\":\"64-v2\",\"ordinary\":48,\"shared_special_slots\":16}\n";
    if(std::filesystem::exists(manifest)) {
        if(std::filesystem::file_size(manifest)!=expected.size())throw std::runtime_error("Automatic profile metadata size changed");
        std::ifstream input(manifest,std::ios::binary);std::string existing(expected.size(),'\0');
        input.read(existing.data(),static_cast<std::streamsize>(existing.size()));
        if(!input || existing!=expected) throw std::runtime_error("Automatic profile metadata changed; preserve the folder for diagnosis");
    } else {
        const auto h=CreateFileW(manifest.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(h==INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot create automatic profile metadata");
        DWORD bytes{};const bool ok=WriteFile(h,expected.data(),static_cast<DWORD>(expected.size()),&bytes,nullptr) && bytes==expected.size() && FlushFileBuffers(h);
        const bool closed=CloseHandle(h)!=FALSE;
        if(!ok || !closed) throw std::runtime_error("Automatic profile metadata write failed");
    }
}
void seed_settings() {
    verify_profile_path();
    const auto source=std::filesystem::current_path()/"iw7-mod"/"players2";
    const auto target=std::filesystem::current_path()/"iw7-mod"/"server-profiles"/"capacity64-v2"/"players2";
    // Copy only existing engine settings once; stats, identity and unlocks keep
    // their normal shared service paths. Never copy a game or overwrite a save.
    for(const auto* name:{L"config_mp.cfg",L"user_keys_mp_0.cfg",L"user_keys_sp_0.cfg"}) {
        const auto input=source/name,output=target/name;
        if(!std::filesystem::exists(input) || std::filesystem::exists(output))continue;
        const auto attributes=GetFileAttributesW(input.c_str());
        if((attributes&FILE_ATTRIBUTE_REPARSE_POINT) || std::filesystem::file_size(input)>1024*1024)
            throw std::runtime_error("Original engine settings cannot be safely copied to the new profile");
        std::filesystem::copy_file(input,output,std::filesystem::copy_options::none);
    }
}
void relaunch(const game::netadr_s& target,int mode,bool expanded) {
    if(switching) return;
    if(expanded)verify_profile_path();
    const auto bytes=executable_bytes();
    if(utils::cryptography::sha256::compute(bytes,true)!=image_hash)
        throw std::runtime_error("Client executable changed while running; automatic restart refused");
    const auto endpoint_text=network::address_to_string(target);
    const std::wstring endpoint_wide(endpoint_text.begin(),endpoint_text.end());
    const auto parent=std::to_wstring(GetCurrentProcessId())+L":"+std::to_wstring(creation(GetCurrentProcess()));
    auto args=arguments(original,endpoint_wide,mode,expanded,parent);
    if(utils::flags::has_flag("paris-auto-managed-data"))args.emplace_back(L"-paris-auto-managed-data");
    if(const auto password=game::Dvar_FindVar("password");password && password->type==game::DVAR_TYPE_STRING && password->current.string) {
        // Preserve a password entered through the normal UI as well as argv.
        args.emplace_back(L"+set");args.emplace_back(L"password");
        const std::string value=password->current.string;
        const auto count=MultiByteToWideChar(CP_ACP,0,value.data(),static_cast<int>(value.size()),nullptr,0);
        if(!value.empty() && !count)throw std::runtime_error("Could not preserve the entered server password");
        std::wstring wide(static_cast<std::size_t>(count),L'\0');
        if(count && !MultiByteToWideChar(CP_ACP,0,value.data(),static_cast<int>(value.size()),wide.data(),count))
            throw std::runtime_error("Could not preserve the entered server password");
        args.push_back(std::move(wide));
    }
    const auto roundtrip=option(L"-paris-auto-return=");
    if(expanded && !roundtrip.empty())args.emplace_back(L"-paris-auto-return="+roundtrip);
    std::wstring line=quote(image);
    for(const auto& arg:args)line+=L" "+quote(arg);
    STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION process{};
    const auto cwd=std::filesystem::current_path().wstring();
    // No shell or server-supplied executable/URL. The same reviewed client
    // contains both implementations, with capacity selected before allocation.
    if(!CreateProcessW(image.c_str(),line.data(),nullptr,nullptr,FALSE,CREATE_NEW_CONSOLE,nullptr,cwd.c_str(),&startup,&process))
        throw std::runtime_error("Could not restart the client for this server profile");
    event("handoff",expanded?"64-v2":"24",process.dwProcessId,creation(process.hProcess));
    CloseHandle(process.hThread);CloseHandle(process.hProcess);
    switching=true;
    console::info("[Automatic profile] switching %s -> %s; reconnect scheduled; no manual package\n",
        paris_agent_capacity::installed()?"64-v2":"24",expanded?"64-v2":"24");
    command::execute("quit",false);
}
}

const char* player_directory() noexcept {
    return paris_agent_capacity::installed() ? "iw7-mod/server-profiles/capacity64-v2/players2" : "iw7-mod/players2";
}
bool switch_for_server(const game::netadr_s& target,const utils::info_string& info) {
    if(private_identity() || info.get("gamename")!="IW7" || !network::is_connectable_address(target)) return false;
    const auto wire=info.get("paris_capacity");
    const auto mode_text=info.get("playmode");
    const auto mode=mode_text=="3"?3:mode_text=="2"?2:0;
    if(!switch_allowed(paris_agent_capacity::installed(),wire,mode)) return false;
    try {
        if(reconnect_pending && !required.empty()) throw std::runtime_error("Server profile changed during automatic reconnect. Retry from the server browser.");
        relaunch(target,mode,parse_wire(wire)==layout::expanded);
    }catch(const std::exception& e) {party::info_response_error(e.what());}
    return true;
}
class component final:public component_interface {
    void post_start() override {
        wchar_t path[32768]{};const auto size=GetModuleFileNameW(nullptr,path,32768);
        if(!size || size>=32768) throw std::runtime_error("Cannot locate automatic-profile client");
        image.assign(path,size);
        const auto bytes=executable_bytes();
        image_hash=utils::cryptography::sha256::compute(bytes,true);
        int count{};const auto argv=CommandLineToArgvW(GetCommandLineW(),&count);
        if(!argv) throw std::runtime_error("Cannot parse client arguments");
        for(int i=0;i<count;++i)original.emplace_back(argv[i]);LocalFree(argv);
        if(private_identity())return;
        wait_for_parent(option(L"-paris-auto-parent="));
        if(utils::flags::has_flag("paris-capacity-64"))seed_settings();
        resume_target=option(L"-paris-auto-target=");required=option(L"-paris-auto-required=");
        const auto mode=option(L"-paris-auto-mode=");
        if(!mode.empty() && mode!=L"2" && mode!=L"3") throw std::runtime_error("Invalid reconnect game mode");
        resume_mode=mode==L"2"?2:3;
        if(!resume_target.empty() && !endpoint(resume_target)) throw std::runtime_error("Invalid automatic reconnect endpoint");
        if(!required.empty() && required!=L"24" && required!=L"64-v2") throw std::runtime_error("Unknown automatic profile contract");
        const auto roundtrip=option(L"-paris-auto-return=");
        if(!roundtrip.empty() && (!endpoint(roundtrip) || roundtrip.substr(0,10)!=L"127.0.0.1:" ||
            std::stoul(roundtrip.substr(10))<27100 || std::stoul(roundtrip.substr(10))>27999))
            throw std::runtime_error("Qualification return requires a private loopback port");
        if(required==L"64-v2" && (!utils::flags::has_flag("paris-capacity-64") || resume_mode!=3))
            throw std::runtime_error("Expanded reconnect lost its startup profile");
        if(required==L"24" && utils::flags::has_flag("paris-capacity-64")) throw std::runtime_error("Standard reconnect retained expanded layout");
    }
    void post_unpack() override {
        if(private_identity())return;
        const auto deadline=GetTickCount64()+180000;
        reconnect_pending=!resume_target.empty();
        if(resume_target.empty() && utils::flags::has_flag("cpMode"))scheduler::loop([done=false]() mutable {
            if(done)return;
            if(game::Com_GameMode_GetActiveGameMode()==game::GAME_MODE_CP){done=true;return;}
            game::Com_GameMode_SetDesiredGameMode(game::GAME_MODE_CP);
        },scheduler::main,100ms);
        scheduler::loop([deadline,requested=false]() mutable {
            if(!reconnect_pending)return;
            if(requested && game::clientUIActives[0].connectionState==game::CA_ACTIVE && !game::clientUIActives[0].frontEndSceneState[0]) {
                reconnect_pending=false;
                event("active",paris_agent_capacity::installed()?"64-v2":"24");
                console::info("[Automatic profile] reconnect ACTIVE; layout=%s\n",paris_agent_capacity::installed()?"64-v2":"24");
                wchar_t qualify[2]{};
                if(!paris_agent_capacity::installed() && required==L"24" &&
                    GetEnvironmentVariableW(L"IW7_AUTO_QUALIFY",qualify,2)==1 && qualify[0]==L'1' &&
                    resume_target.substr(0,10)==L"127.0.0.1:" &&
                    std::stoul(resume_target.substr(10))>=27100 && std::stoul(resume_target.substr(10))<=27999)
                    scheduler::once([] {event("qualification_exit","24");command::execute("quit",false);},scheduler::main,15s);
                return;
            }
            if(GetTickCount64()>=deadline) {reconnect_pending=false;console::warn("[Automatic profile] reconnect timed out; use the server browser to retry\n");return;}
            if(requested)return;
            const auto mode=static_cast<game::GameModeType>(resume_mode);
            if(game::Com_GameMode_GetActiveGameMode()!=mode) {game::Com_GameMode_SetDesiredGameMode(mode);return;}
            if(game::Live_SyncOnlineDataFlags(0)!=0)return;
            const std::string text(resume_target.begin(),resume_target.end());
            const auto target=network::address_from_string(text);
            requested=true;party::connect(target);
            event("connect",paris_agent_capacity::installed()?"64-v2":"24");
            console::info("[Automatic profile] resuming connection; layout=%s\n",paris_agent_capacity::installed()?"64-v2":"24");
        },scheduler::main,100ms);
        const auto roundtrip=option(L"-paris-auto-return=");
        if(!roundtrip.empty())scheduler::loop([roundtrip,when=ULONGLONG{},done=false]() mutable {
            if(done || !paris_agent_capacity::installed() || reconnect_pending)return;
            if(!when) {when=GetTickCount64()+30000;return;}
            if(GetTickCount64()<when)return;
            done=true;const std::string target(roundtrip.begin(),roundtrip.end());
            party::connect(network::address_from_string(target));
        },scheduler::main,100ms);
        scheduler::once([] {
            event("ready",paris_agent_capacity::installed()?"64-v2":"24");
            console::info("[Automatic profile] ready; layout=%s; player_directory=%s\n",paris_agent_capacity::installed()?"64-v2":"24",player_directory());
        },scheduler::main);
    }
};
}
REGISTER_COMPONENT(auto_capacity::component)
