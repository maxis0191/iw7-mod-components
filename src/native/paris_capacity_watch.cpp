#include <std_include.hpp>
#include "paris_capacity_watch.hpp"
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "command.hpp"
#include <utils/flags.hpp>
#include <fstream>
#include <cstring>

namespace paris_capacity_watch {
namespace {
constexpr DWORD arm_exception=0xE0574801, close_exception=0xE0574802, verify_exception=0xE0574803;
struct capture { observation event{}; CONTEXT context{}; };
struct thread_record {
    std::atomic<DWORD> tid{0}; std::atomic<unsigned> roles{0};
    std::atomic<phase> state{phase::empty}; std::atomic<bool> canary_pass{false};
    alignas(8) volatile LONG64 canary{};
    DWORD64 saved_dr[6]{}; write_history history{};
    std::atomic<HANDLE> handle{nullptr}; std::atomic<std::uint64_t> creation{0};
};
thread_record records[2];
thread_local thread_record* local_record=nullptr;
fixed_ring<capture> events;
std::atomic<bool> requested{false}, stopping{false}, confirmed{true}, handler_removed{true};
std::atomic<std::uint64_t> start_ms{0}, vacant_since{0}, vacancy_checked{0};
PVOID handler=nullptr;
std::mutex output_mutex, registry_mutex;
std::ofstream output;
std::string nonce;
unsigned flushed=0; bool armed_written=false, complete_written=false;
std::uint64_t qpc_frequency{}, process_creation{};
std::atomic<unsigned> failure_count{0};

bool private_flags() {
    return game::environment::is_dedi() && utils::flags::has_flag("paris-capacity-watch") &&
        utils::flags::has_flag("paris-isolated-lab") && utils::flags::has_flag("paris-server-test") &&
        utils::flags::has_flag("paris-debugger");
}
bool private_vacant() {
    if (!private_flags() || game::Com_GameMode_GetActiveGameMode()!=game::GAME_MODE_CP) return false;
    const auto* port=game::Dvar_FindVar("net_port");
    const auto* map=game::Dvar_FindVar("mapname");
    if (!game::SV_Loaded() || !port || port->type!=game::DVAR_TYPE_INT ||
        port->current.integer<27100 || port->current.integer>27999 || !map ||
        map->type!=game::DVAR_TYPE_STRING || !map->current.string || std::strcmp(map->current.string,"cp_zmb")) return false;
    const auto* password=game::Dvar_FindVar("g_password");
    const auto* clients=*game::svs_clients;
    const auto count=*game::svs_numclients;
    if (!password || password->type!=game::DVAR_TYPE_STRING || !password->current.string ||
        !*password->current.string || !clients || count<1 || count>4) return false;
    // Include connecting clients; vacant must never mean merely no active player.
    for (unsigned i=0;i<count;++i) if (clients[i].header.state!=game::CS_FREE) return false;
    return true;
}
bool read_pair(std::uint64_t& a, std::uint64_t& b) noexcept {
    __try {
        a=*reinterpret_cast<volatile std::uint64_t*>(field_b8);
        b=*reinterpret_cast<volatile std::uint64_t*>(field_c0); return true;
    } __except(EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool valid_fields() {
    for (const auto address : {field_b8,field_c0}) {
        MEMORY_BASIC_INFORMATION m{};
        if (VirtualQuery(reinterpret_cast<void*>(address),&m,sizeof(m))!=sizeof(m) ||
            m.State!=MEM_COMMIT || m.AllocationBase!=reinterpret_cast<void*>(0x140000000ull) ||
            (m.Protect&PAGE_GUARD)) return false;
        const auto p=m.Protect&0xff;
        if (p!=PAGE_READWRITE && p!=PAGE_WRITECOPY && p!=PAGE_EXECUTE_READWRITE && p!=PAGE_EXECUTE_WRITECOPY) return false;
        const auto base=reinterpret_cast<std::uintptr_t>(m.BaseAddress);
        if (address<base || m.RegionSize<8 || address-base>m.RegionSize-8) return false;
    }
    return true;
}
void restore_registers(CONTEXT& c, thread_record& t) noexcept {
    c.Dr0=t.saved_dr[0]; c.Dr1=t.saved_dr[1]; c.Dr2=t.saved_dr[2]; c.Dr3=t.saved_dr[3];
    c.Dr6=t.saved_dr[4]; c.Dr7=t.saved_dr[5];
}
bool owned_registers(const CONTEXT& c,const thread_record& t,phase state) noexcept {
    if(c.Dr2!=t.saved_dr[2] || c.Dr3!=t.saved_dr[3])return false;
    if(state==phase::canary)return c.Dr0==reinterpret_cast<DWORD64>(&t.canary) && c.Dr1==0 && c.Dr7==(t.saved_dr[5]|canary_dr7);
    if(state==phase::data)return c.Dr0==field_b8 && c.Dr1==field_c0 && c.Dr7==(t.saved_dr[5]|data_dr7);
    return false;
}
bool restored(const CONTEXT& c,const thread_record& t) noexcept {
    // DR6 is status, not coverage; low triggered bits must not remain set.
    return c.Dr0==t.saved_dr[0] && c.Dr1==t.saved_dr[1] && c.Dr2==t.saved_dr[2] &&
        c.Dr3==t.saved_dr[3] && c.Dr7==t.saved_dr[5] && !(c.Dr6&15);
}
void record_event(kind type, thread_record& t, const CONTEXT& c, unsigned bits=0) noexcept {
    capture e{}; e.context=c;
    e.event.tid=GetCurrentThreadId(); e.event.roles=t.roles.load(std::memory_order_relaxed);
    e.event.type=type; e.event.slot_bits=bits; e.event.tick_ms=GetTickCount64();
    LARGE_INTEGER clock{}; QueryPerformanceCounter(&clock); e.event.qpc=clock.QuadPart;
    e.event.rip=c.Rip; e.event.previous_b8=t.history.b8; e.event.previous_c0=t.history.c0;
    e.event.b8=t.history.b8; e.event.c0=t.history.c0;
    if (type==kind::write) {
        if (!read_pair(e.event.b8,e.event.c0)) { e.event.type=kind::failure; ++failure_count; stopping.store(true); }
        else t.history.observe(bits,e.event.b8,e.event.c0);
    }
    e.event.zero_seen=t.history.zero_seen; e.event.first_nonzero=t.history.first_nonzero;
    if (!events.append(e) || events.reserved()>=max_events) stopping.store(true,std::memory_order_release);
}
LONG WINAPI observe_exception(EXCEPTION_POINTERS* p) noexcept {
    auto* t=local_record;
    if (!p || !p->ContextRecord || !p->ExceptionRecord || !t || t->tid.load()!=GetCurrentThreadId()) return EXCEPTION_CONTINUE_SEARCH;
    auto& c=*p->ContextRecord; const auto code=p->ExceptionRecord->ExceptionCode;
    if (code==arm_exception || code==close_exception || code==verify_exception) {
        if (p->ExceptionRecord->NumberParameters!=1 || p->ExceptionRecord->ExceptionInformation[0]!=reinterpret_cast<ULONG_PTR>(t)) return EXCEPTION_CONTINUE_SEARCH;
        if ((c.ContextFlags&CONTEXT_DEBUG_REGISTERS)!=CONTEXT_DEBUG_REGISTERS) {
            ++failure_count; stopping.store(true);record_event(kind::failure,*t,c);
            t->state.store(code==arm_exception && t->state.load()==phase::empty ? phase::closed : phase::failed);
            return EXCEPTION_CONTINUE_EXECUTION;
        }
        if (code==arm_exception) {
            // Do not replace any existing breakpoint/TF, active or inactive.
            if (t->state.load()!=phase::empty || !clear_debug_state(c.Dr0,c.Dr1,c.Dr2,c.Dr3,c.Dr6,c.Dr7,c.EFlags)) {
                ++failure_count; stopping.store(true); record_event(kind::failure,*t,c);t->state.store(phase::closed);
                return EXCEPTION_CONTINUE_EXECUTION;
            }
            t->saved_dr[0]=c.Dr0;t->saved_dr[1]=c.Dr1;t->saved_dr[2]=c.Dr2;
            t->saved_dr[3]=c.Dr3;t->saved_dr[4]=c.Dr6;t->saved_dr[5]=c.Dr7;
            c.Dr0=reinterpret_cast<DWORD64>(&t->canary);c.Dr1=0;c.Dr6=0;
            c.Dr7=t->saved_dr[5]|canary_dr7;t->state.store(phase::canary);
        } else if (code==close_exception) {
            const auto phase_now=t->state.load();
            if (phase_now==phase::canary || phase_now==phase::data || phase_now==phase::disarming) {
                if(owned_registers(c,*t,phase_now) || (phase_now==phase::disarming && restored(c,*t))) {
                    restore_registers(c,*t);t->state.store(phase::disarming);
                } else {++failure_count;stopping.store(true);record_event(kind::failure,*t,c);t->state.store(phase::failed);}
            }
        } else if (t->state.load()==phase::disarming) {
            if (restored(c,*t)) {record_event(kind::disarmed,*t,c);t->state.store(phase::closed);}
            else {++failure_count;stopping.store(true);record_event(kind::failure,*t,c);}
        }
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (code!=EXCEPTION_SINGLE_STEP || !((c.Dr6&3)!=0)) return EXCEPTION_CONTINUE_SEARCH;
    const auto phase_now=t->state.load();
    if (phase_now!=phase::canary && phase_now!=phase::data) return EXCEPTION_CONTINUE_SEARCH;
    if(!owned_registers(c,*t,phase_now)) {
        ++failure_count;stopping.store(true);record_event(kind::failure,*t,c);t->state.store(phase::failed);
        return EXCEPTION_CONTINUE_SEARCH; // Never overwrite newly foreign DR state.
    }
    // Foreign single-step/slots remain somebody else's exception. Refuse coverage.
    if ((c.Dr6&0xC) || (c.Dr6&(1ull<<14)) || (c.EFlags&0x100)) {
        ++failure_count; stopping.store(true);restore_registers(c,*t);t->state.store(phase::disarming);
        record_event(kind::failure,*t,c);return EXCEPTION_CONTINUE_SEARCH;
    }
    if(stopping.load() || elapsed(GetTickCount64(),start_ms.load(),duration_ms)) {
        stopping.store(true);restore_registers(c,*t);t->state.store(phase::disarming);
        return EXCEPTION_CONTINUE_EXECUTION; // No write evidence after deadline.
    }
    const auto bits=static_cast<unsigned>(c.Dr6&3);
    if (phase_now==phase::canary) {
        if (!matching_canary(bits,c.Dr0,c.Dr7,reinterpret_cast<DWORD64>(&t->canary),t->saved_dr[5])) {
            ++failure_count;stopping.store(true);restore_registers(c,*t);t->state.store(phase::disarming);
            record_event(kind::failure,*t,c);
        } else {
            t->canary_pass.store(true);record_event(kind::canary_pass,*t,c);
            c.Dr0=field_b8;c.Dr1=field_c0;c.Dr6=0;c.Dr7=t->saved_dr[5]|data_dr7;t->state.store(phase::data);
        }
    } else {
        if (c.Dr0!=field_b8 || c.Dr1!=field_c0 || c.Dr7!=(t->saved_dr[5]|data_dr7)) {
            ++failure_count;stopping.store(true);record_event(kind::failure,*t,c);
        } else record_event(kind::write,*t,c,bits);
        c.Dr6&=~3ull;
    }
    if (stopping.load() || elapsed(GetTickCount64(),start_ms.load(),duration_ms)) {
        stopping.store(true);restore_registers(c,*t);t->state.store(phase::disarming);
    }
    return EXCEPTION_CONTINUE_EXECUTION;
}
void raise_owned(DWORD code,thread_record& t) {
    const ULONG_PTR arg=reinterpret_cast<ULONG_PTR>(&t);RaiseException(code,0,1,&arg);
}
thread_record* current_record(unsigned role) {
    const auto tid=GetCurrentThreadId();
    for (auto& t:records) if (t.tid.load()==tid) { t.roles.fetch_or(role);return &t; }
    for (auto& t:records) {
        DWORD unused=0;
        if (!t.tid.compare_exchange_strong(unused,tid)) continue;
        t.roles.store(role);t.handle.store(OpenThread(THREAD_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,tid));
        FILETIME created{},exit{},kernel{},user{};
        if (!t.handle.load() || !GetThreadTimes(t.handle.load(),&created,&exit,&kernel,&user)) {
            ++failure_count;t.state.store(phase::closed);stopping.store(true);return &t;
        }
        t.creation.store((static_cast<std::uint64_t>(created.dwHighDateTime)<<32)|created.dwLowDateTime);return &t;
    }
    ++failure_count;stopping.store(true);return nullptr; // Unexpected third scheduler thread.
}
void thread_tick(unsigned role) {
    const auto now=GetTickCount64();
    if (role==1) {
        vacancy_checked.store(now);
        if (!private_vacant()) {vacant_since.store(0);if(requested.load())stopping.store(true);}
        else if (!vacant_since.load()) vacant_since.store(now);
    }
    // Serialize callback registration/handle publication with async removal.
    // The VEH does not acquire this mutex; no target thread is suspended.
    std::lock_guard<std::mutex> registry_lock(registry_mutex);
    if (!requested.load() || handler_removed.load()) return;
    if (elapsed(now,start_ms.load(),duration_ms) || !private_flags()) stopping.store(true);
    auto* t=current_record(role);if (!t)return;
    local_record=t;
    if (stopping.load()) {
        if(t->state.load()==phase::canary || t->state.load()==phase::data || t->state.load()==phase::disarming) {
            raise_owned(close_exception,*t);raise_owned(verify_exception,*t);
        } else if(t->state.load()==phase::empty)t->state.store(phase::closed);
        return;
    }
    if (t->state.load()!=phase::empty) return;
    if (!valid_fields() || !read_pair(t->history.b8,t->history.c0)) {
        ++failure_count;stopping.store(true);t->state.store(phase::closed);return;
    }
    raise_owned(arm_exception,*t);
    if(t->state.load()==phase::canary) {
        InterlockedExchange64(&t->canary,t->canary+1);
        if(!t->canary_pass.load()) {++failure_count;stopping.store(true);raise_owned(close_exception,*t);raise_owned(verify_exception,*t);}
    }
}
void write_context_hex(const CONTEXT& c) {
    constexpr char alphabet[]="0123456789abcdef";
    const auto* bytes=reinterpret_cast<const unsigned char*>(&c);
    for(std::size_t i=0;i<sizeof(c);++i){output.put(alphabet[bytes[i]>>4]);output.put(alphabet[bytes[i]&15]);}
}
void flush() {
    if(!requested.load())return;
    if(elapsed(GetTickCount64(),start_ms.load(),duration_ms))stopping.store(true);
    std::lock_guard<std::mutex> lock(output_mutex);
    while(const auto* c=events.get(flushed)) {
        const auto& e=c->event;
        output<<"{\"type\":\"event\",\"seq\":"<<flushed<<",\"kind\":"<<static_cast<unsigned>(e.type)
            <<",\"tid\":"<<e.tid<<",\"roles\":"<<e.roles<<",\"tick_ms\":"<<e.tick_ms<<",\"qpc\":"<<e.qpc
            <<",\"rip_after_write\":"<<e.rip<<",\"slots\":"<<e.slot_bits<<",\"b8\":"<<e.b8<<",\"c0\":"<<e.c0
            <<",\"previous_b8\":"<<e.previous_b8<<",\"previous_c0\":"<<e.previous_c0
            <<",\"zero_seen\":"<<e.zero_seen<<",\"first_nonzero\":"<<e.first_nonzero<<",\"context_hex\":\"";
        write_context_hex(c->context);output<<"\"}\n";++flushed;
    }
    std::lock_guard<std::mutex> registry_lock(registry_mutex);
    bool all_closed=true;unsigned covered=0;
    for(auto& t:records) {
        if(!t.tid.load())continue;
        if(t.state.load()!=phase::closed && t.handle.load() && WaitForSingleObject(t.handle.load(),0)==WAIT_OBJECT_0)t.state.store(phase::closed);
        if(t.state.load()!=phase::closed)all_closed=false;
        if(t.canary_pass.load())covered|=t.roles.load();
    }
    if(!stopping.load() && covered==3 && !failure_count.load() && !armed_written) {
        bool data=true;
        for(auto& t:records) if(t.tid.load() && t.state.load()!=phase::data)data=false;
        if(data) {
            output<<"{\"type\":\"armed\",\"nonce\":\""<<nonce<<"\",\"tick_ms\":"<<GetTickCount64()<<",\"threads\":[";
            bool first=true;
            for(auto& t:records) if(t.tid.load()) {
                if(!first)output<<',';first=false;
                output<<"{\"tid\":"<<t.tid.load()<<",\"creation_filetime\":"<<t.creation.load()<<",\"roles\":"<<t.roles.load()<<",\"canary_pass\":true}";
            }
            output<<"],\"all_init_threads_covered\":false}\n";armed_written=true;
        }
    }
    if(stopping.load() && all_closed && !complete_written) {
        if(handler && RemoveVectoredExceptionHandler(handler)) {handler=nullptr;handler_removed.store(true);}
        bool handles_closed=true;
        if(handler_removed.load())for(auto& t:records) {
            const auto h=t.handle.load();
            if(h) {if(CloseHandle(h))t.handle.store(nullptr);else handles_closed=false;}
        }
        if(handler_removed.load() && handles_closed) {
            confirmed.store(true);complete_written=true;
            output<<"{\"type\":\"complete\",\"cleanup_confirmed\":true,\"covered_roles\":"<<covered
                <<",\"failures\":"<<failure_count.load()<<",\"canary_prerequisite_satisfied\":"
                <<((covered==3 && !failure_count.load())?"true":"false")
                <<",\"event_limit_reached\":"<<(events.reserved()>=max_events?"true":"false")
                <<",\"all_init_threads_covered\":false,\"patch_ready\":false}\n";
        }
    }
    if(!output)stopping.store(true);
    output.flush();
}
void arm(const command::params& args) {
    const auto now=GetTickCount64();
    if(args.size()!=2 || !valid_nonce(args[1]) || !private_vacant() || requested.load() ||
        !vacant_since.load() || !elapsed(now,vacant_since.load(),30000) ||
        !vacancy_checked.load() || elapsed(now,vacancy_checked.load(),500) || !valid_fields())return;
    std::lock_guard<std::mutex> lock(output_mutex);
    nonce=args[1];LARGE_INTEGER frequency{};if(!QueryPerformanceFrequency(&frequency) || frequency.QuadPart<=0)return;qpc_frequency=frequency.QuadPart;
    FILETIME created{},exit{},kernel{},user{};if(!GetProcessTimes(GetCurrentProcess(),&created,&exit,&kernel,&user))return;
    process_creation=(static_cast<std::uint64_t>(created.dwHighDateTime)<<32)|created.dwLowDateTime;
    const auto name="iw7-capacity-watch-"+std::to_string(GetCurrentProcessId())+"-"+nonce+".jsonl";
    // Claim a fresh filename atomically; never overwrite retained evidence.
    const auto file=CreateFileA(name.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE)return;CloseHandle(file);
    output.open(name,std::ios::binary|std::ios::app);if(!output)return;
    output<<"{\"type\":\"header\",\"schema\":\"iw7.capacity-watch/1\",\"pid\":"<<GetCurrentProcessId()
        <<",\"creation_filetime\":"<<process_creation<<",\"nonce\":\""<<nonce<<"\",\"qpc_frequency\":"<<qpc_frequency
        <<",\"b8_address\":"<<field_b8<<",\"c0_address\":"<<field_c0
        <<",\"max_events\":64,\"duration_ms\":10000,\"native_hash_requires_parent_manifest\":true,\"pristine\":false}\n";
    output.flush();confirmed.store(false);handler_removed.store(false);
    handler=AddVectoredExceptionHandler(1,observe_exception);
    if(!handler){handler_removed.store(true);confirmed.store(true);output<<"{\"type\":\"failed\",\"reason\":\"handler_install\",\"no_evidence\":true,\"cleanup_confirmed\":true}\n";output.flush();return;}
    start_ms.store(now);requested.store(true);
}
class component final:public component_interface {
    void post_unpack() override {
        if(!private_flags())return;
        command::add("paris_capacity_arm",arm);
        command::add("paris_capacity_stop",[]{request_stop();});
        scheduler::loop([]{thread_tick(1);},scheduler::server,10ms);
        scheduler::loop([]{thread_tick(2);},scheduler::main,10ms);
        scheduler::loop(flush,scheduler::async,50ms);
    }
    void pre_destroy() override {
        if(!private_flags())return;
        request_stop();flush();
        // Never remove a live handler while another thread still has our DRs.
        // If cooperative callbacks stopped, cleanup remains false. Runner must
        // retain lease/transactions, or independently prove owned process exit.
    }
};
}
bool cleanup_confirmed() noexcept { return confirmed.load(std::memory_order_acquire); }
void request_stop() noexcept { stopping.store(true,std::memory_order_release); }
}
REGISTER_COMPONENT(paris_capacity_watch::component)
