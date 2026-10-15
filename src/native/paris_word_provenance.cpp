#include <std_include.hpp>
#include "paris_word_provenance.hpp"
#include "loader/component_loader.hpp"
#include <utils/flags.hpp>
#include <utils/cryptography.hpp>
#include <cstdio>
#include <cstring>

namespace paris_word_provenance {
namespace {
struct captured_record {
    record_kind kind{}; boundary phase{}; fault reason{};
    unsigned error{}, detail{}, tid{}, caller_tid{};
    std::uint64_t tick{}, qpc{}, creation{};
    bool has_context{}, stable{}, word_read{};
    CONTEXT context{};
    std::uint16_t previous{}, value{};
    region before{}, after{};
    std::array<std::uint8_t, window_bytes> first{}, second{};
};
struct retained_handle : retained_object<HANDLE> {
    bool close() noexcept { return close_with([](HANDLE h) { return CloseHandle(h) != FALSE; }); }
};
class scoped_lock {
    SRWLOCK* value_;
public:
    explicit scoped_lock(SRWLOCK& value) noexcept : value_(&value) { AcquireSRWLockExclusive(value_); }
    ~scoped_lock() noexcept { ReleaseSRWLockExclusive(value_); }
    scoped_lock(const scoped_lock&) = delete;
    scoped_lock& operator=(const scoped_lock&) = delete;
};
struct runtime {
    std::atomic<bool> active{false}, stopping{false}, helper_stop{false}, helper_inflight{false};
    std::atomic<bool> helper_exited{false}, debug_cleanup{false}, output_closed{false};
    std::atomic<bool> before_claimed{false}, after_claimed{false}, postload_claimed{false};
    std::array<std::atomic<bool>, max_snapshots> snapshot_claimed{};
    std::atomic<state> phase{state::empty};
    std::atomic<unsigned> tid{0}, loaded_tid{0}, ticket{0}, operation{0}, failures{0}, drops{0};
    std::atomic<unsigned> diagnostic_count{0}, diagnostic_drops{0}, writes{0};
    std::atomic<unsigned> resume_expected{1};
    std::array<std::atomic<unsigned>, static_cast<unsigned>(fault::count)> totals{}, last_error{};
    std::array<std::atomic<bool>, static_cast<unsigned>(fault::count)> diagnostic_seen{};
    std::atomic<std::uint64_t> expires{0}, started{0};
    std::atomic<bool> baseline_captured{false}, dr_attempted{false}, restore_readback{false};
    std::atomic<bool> ever_suspended{false}, own_suspend{false}, resume_confirmed{false}, thread_exited{false};
    std::atomic<bool> resume_anomaly{false};
    std::atomic<bool> canary_pass{false}, word_readback{false}, handler_removed{true};
    std::atomic<bool> history_valid{false}, output_failed{false};
    std::atomic<std::uint16_t> last_word{0};
    alignas(8) volatile LONG64 canary{};
    debug_registers saved{};
    std::uint64_t thread_creation{}, process_creation{}, frequency{};
    retained_handle target{}, done{}, signal{}, helper{}, output{};
    PVOID handler{};
    fixed_ring<captured_record> records;
    unsigned flushed{};
    char nonce[65]{}, review[65]{}, native[65]{};
    SRWLOCK barrier = SRWLOCK_INIT, closer = SRWLOCK_INIT;
};
runtime rt;
thread_local runtime* local_runtime = nullptr;

const char* name(fault f) noexcept {
    static constexpr const char* values[] = {
        "activation", "phase_order", "wrong_tid", "snapshot_query", "snapshot_read", "snapshot_changed",
        "identity", "thread_times", "thread_exit", "suspend", "preexisting_suspend", "resume",
        "get_context", "context_flags", "foreign_dr", "set_context", "readback", "canary",
        "ticket_expired", "deadline", "event_limit", "foreign_step", "unattributed_change",
        "handler_remove", "handle_close", "output", "registration"
    };
    static_assert(sizeof(values) / sizeof(values[0]) == static_cast<unsigned>(fault::count));
    return values[static_cast<unsigned>(f)];
}
std::uint64_t clock_qpc() noexcept {
    LARGE_INTEGER value{}; return QueryPerformanceCounter(&value) ? static_cast<std::uint64_t>(value.QuadPart) : 0;
}
captured_record stamp(record_kind kind) noexcept {
    captured_record r{}; r.kind = kind; r.caller_tid = GetCurrentThreadId();
    r.tid = rt.tid.load() ? rt.tid.load() : r.caller_tid;
    r.tick = GetTickCount64(); r.qpc = clock_qpc(); r.creation = rt.thread_creation; return r;
}
void stop_fault(fault f, DWORD error = ERROR_SUCCESS, unsigned detail = 0) noexcept {
    const auto index = static_cast<unsigned>(f);
    rt.failures.fetch_add(1); rt.totals[index].fetch_add(1); rt.last_error[index].store(error);
    rt.stopping.store(true, std::memory_order_release);
    bool expected = false;
    if (rt.diagnostic_seen[index].compare_exchange_strong(expected, true)) {
        if (rt.diagnostic_count.fetch_add(1) < max_diagnostics) {
            auto r = stamp(record_kind::failure); r.reason = f; r.error = error; r.detail = detail;
            if (!rt.records.append(r)) rt.drops.fetch_add(1);
        } else rt.diagnostic_drops.fetch_add(1);
    }
}
void append(captured_record& r) noexcept {
    if (!rt.records.append(r)) { rt.drops.fetch_add(1); stop_fault(fault::event_limit); }
    if (rt.records.reserved() >= max_records) stop_fault(fault::event_limit);
}
bool write_output(const char* text, unsigned bytes) noexcept {
    if (rt.output_failed.load()) return false;
    DWORD written{};
    if (!rt.output.value || !WriteFile(rt.output.value, text, bytes, &written, nullptr) || written != bytes) {
        const auto error = GetLastError(); rt.output_failed.store(true); stop_fault(fault::output, error); return false;
    }
    return true;
}
bool format_output(const char* line, int count, unsigned capacity) noexcept {
    if (count < 0 || static_cast<unsigned>(count) >= capacity) { stop_fault(fault::output, ERROR_INSUFFICIENT_BUFFER); return false; }
    return write_output(line, static_cast<unsigned>(count));
}
region convert(const MEMORY_BASIC_INFORMATION& m) noexcept {
    return {reinterpret_cast<std::uint64_t>(m.BaseAddress), reinterpret_cast<std::uint64_t>(m.AllocationBase),
        static_cast<std::uint64_t>(m.RegionSize), m.State, m.Type, m.Protect, m.AllocationProtect};
}
bool copy_window(std::uint8_t* destination, DWORD& exception) noexcept {
    __try {
        const auto* source = reinterpret_cast<volatile const std::uint8_t*>(window_start);
        for (unsigned i = 0; i < window_bytes; ++i) destination[i] = source[i];
        return true;
    }
    __except (exception = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool read_word(std::uint16_t& value, DWORD& exception) noexcept {
    __try { value = *reinterpret_cast<volatile std::uint16_t*>(target_word); return true; }
    __except (exception = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { return false; }
}
void snapshot(boundary phase) noexcept {
    const auto index = static_cast<unsigned>(phase);
    bool expected = false;
    if (!rt.snapshot_claimed[index].compare_exchange_strong(expected, true)) { stop_fault(fault::phase_order); return; }
    auto r = stamp(record_kind::snapshot); r.phase = phase;
    MEMORY_BASIC_INFORMATION a{}, b{};
    SetLastError(ERROR_SUCCESS);
    if (VirtualQuery(reinterpret_cast<void*>(window_start), &a, sizeof(a)) != sizeof(a) || !valid_window(convert(a))) {
        stop_fault(fault::snapshot_query, GetLastError(), index); return;
    }
    r.before = convert(a);
    DWORD exception{};
    if (!copy_window(r.first.data(), exception) || !copy_window(r.second.data(), exception)) { stop_fault(fault::snapshot_read, ERROR_SUCCESS, exception); return; }
    SetLastError(ERROR_SUCCESS);
    if (VirtualQuery(reinterpret_cast<void*>(window_start), &b, sizeof(b)) != sizeof(b) || !valid_window(convert(b))) {
        stop_fault(fault::snapshot_query, GetLastError(), index); return;
    }
    r.after = convert(b);
    r.stable = same_region(r.before, r.after) && r.first == r.second;
    std::memcpy(&r.value, r.second.data() + (target_word - window_start), sizeof(r.value)); r.word_read = true;
    if (!r.stable) stop_fault(fault::snapshot_changed, ERROR_SUCCESS, index);
    if (phase == boundary::after_post_load && r.stable) { rt.last_word.store(r.value); rt.history_valid.store(true); }
    if ((phase == boundary::before_post_unpack || phase == boundary::after_post_unpack) &&
        rt.history_valid.load() && r.value != rt.last_word.load()) stop_fault(fault::unattributed_change, ERROR_SUCCESS, index);
    append(r);
}
debug_registers registers(const CONTEXT& c) noexcept { return {c.Dr0, c.Dr1, c.Dr2, c.Dr3, c.Dr6, c.Dr7, c.EFlags}; }
void baseline_to(CONTEXT& c) noexcept {
    c.Dr0 = rt.saved.dr0; c.Dr1 = rt.saved.dr1; c.Dr2 = rt.saved.dr2;
    c.Dr3 = rt.saved.dr3; c.Dr6 = rt.saved.dr6; c.Dr7 = rt.saved.dr7;
}
bool get_context(CONTEXT& c) noexcept {
    constexpr DWORD needed = CONTEXT_CONTROL | CONTEXT_DEBUG_REGISTERS;
    c = {}; c.ContextFlags = needed;
    if (!GetThreadContext(rt.target.value, &c)) { stop_fault(fault::get_context, GetLastError()); return false; }
    if ((c.ContextFlags & needed) != needed) { stop_fault(fault::context_flags, ERROR_SUCCESS, c.ContextFlags); return false; }
    return true;
}
bool set_context(const CONTEXT& supplied) noexcept {
    auto c = supplied; c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    if (!SetThreadContext(rt.target.value, &c)) { stop_fault(fault::set_context, GetLastError()); return false; }
    return true;
}
LONG WINAPI observer(EXCEPTION_POINTERS* p) noexcept {
    if (local_runtime != &rt || GetCurrentThreadId() != rt.tid.load() || !p || !p->ContextRecord || !p->ExceptionRecord) return EXCEPTION_CONTINUE_SEARCH;
    auto& c = *p->ContextRecord;
    constexpr DWORD needed = CONTEXT_CONTROL | CONTEXT_DEBUG_REGISTERS;
    if (p->ExceptionRecord->ExceptionCode != EXCEPTION_SINGLE_STEP || (c.ContextFlags & needed) != needed || !(c.Dr6 & 1)) return EXCEPTION_CONTINUE_SEARCH;
    const auto phase = rt.phase.load();
    if (phase != state::canary && phase != state::word) return EXCEPTION_CONTINUE_SEARCH;
    if (!owned(registers(c), rt.saved, phase, reinterpret_cast<std::uint64_t>(&rt.canary))) {
        stop_fault(fault::foreign_dr); rt.phase.store(state::failed); return EXCEPTION_CONTINUE_SEARCH;
    }
    if ((c.Dr6 & (dr6_debug_causes & ~1ull)) || (c.EFlags & 0x100)) {
        stop_fault(fault::foreign_step); baseline_to(c); rt.phase.store(state::disarming); return EXCEPTION_CONTINUE_SEARCH;
    }
    if (elapsed(GetTickCount64(), rt.started.load(), duration_ms)) stop_fault(fault::deadline);
    if (rt.stopping.load()) {
        baseline_to(c); rt.phase.store(state::disarming); return EXCEPTION_CONTINUE_EXECUTION;
    }
    auto r = stamp(phase == state::canary ? record_kind::canary : record_kind::write);
    DWORD exception{};
    r.has_context = true; r.context = c; r.previous = rt.last_word.load(); r.word_read = read_word(r.value, exception);
    if (!r.word_read) stop_fault(fault::snapshot_read, ERROR_SUCCESS, exception);
    if (phase == state::canary) {
        if (rt.canary != 1) {
            stop_fault(fault::canary); baseline_to(c); rt.phase.store(state::disarming);
            return EXCEPTION_CONTINUE_EXECUTION;
        }
        rt.canary_pass.store(true); c.Dr0 = target_word; c.Dr6 = rt.saved.dr6; c.Dr7 = rt.saved.dr7 | word_dr7;
        rt.phase.store(state::word);
    } else {
        rt.writes.fetch_add(1);
        if (r.word_read) rt.last_word.store(r.value);
        c.Dr6 &= ~1ull;
    }
    append(r);
    if (rt.stopping.load()) { baseline_to(c); rt.phase.store(state::disarming); }
    return EXCEPTION_CONTINUE_EXECUTION;
}
bool target_identity() noexcept {
    if (!rt.target.value || GetThreadId(rt.target.value) != rt.tid.load() || rt.tid.load() == GetCurrentThreadId()) {
        stop_fault(fault::identity, GetLastError()); return false;
    }
    FILETIME a{}, b{}, c{}, d{}; DWORD code{};
    if (!GetThreadTimes(rt.target.value, &a, &b, &c, &d)) { stop_fault(fault::thread_times, GetLastError()); return false; }
    const auto created = (static_cast<std::uint64_t>(a.dwHighDateTime) << 32) | a.dwLowDateTime;
    if (created != rt.thread_creation) { stop_fault(fault::identity); return false; }
    if (!GetExitCodeThread(rt.target.value, &code)) { stop_fault(fault::thread_exit, GetLastError()); return false; }
    if (code != STILL_ACTIVE) { rt.thread_exited.store(true); rt.own_suspend.store(false); rt.phase.store(state::closed); return false; }
    return true;
}
bool resume_original() noexcept {
    if (!rt.own_suspend.load()) return true;
    const auto count = ResumeThread(rt.target.value);
    if (count == DWORD(-1)) { stop_fault(fault::resume, GetLastError(), count); return false; }
    rt.own_suspend.store(false);
    if (count != rt.resume_expected.load()) { rt.resume_anomaly.store(true); stop_fault(fault::resume, ERROR_SUCCESS, count); return false; }
    if (!rt.resume_anomaly.load()) rt.resume_confirmed.store(true);
    return true;
}
void service(unsigned op) noexcept {
    if (!target_identity()) return;
    const auto previous = SuspendThread(rt.target.value);
    if (previous == DWORD(-1)) { stop_fault(fault::suspend, GetLastError()); return; }
    rt.ever_suspended.store(true); rt.own_suspend.store(true); rt.resume_confirmed.store(false);
    rt.resume_expected.store(previous + 1);
    if (previous) {
        stop_fault(fault::preexisting_suspend, ERROR_SUCCESS, previous);
        unsigned attempts = 0;
        while (rt.own_suspend.load() && !resume_original()) { ++attempts; Sleep(attempts < 3 ? 20 : 30000); }
        return;
    }
    CONTEXT c{};
    if (get_context(c)) {
        if (op == 1) {
            if (rt.stopping.load() || rt.phase.load() != state::empty || GetTickCount64() >= rt.expires.load() ||
                elapsed(GetTickCount64(), rt.started.load(), duration_ms) || !clear_debug_state(registers(c))) {
                stop_fault(fault::foreign_dr); rt.phase.store(state::failed);
            } else {
                rt.saved = registers(c); rt.baseline_captured.store(true);
                auto r = stamp(record_kind::baseline); r.has_context = true; r.context = c; append(r);
                c.Dr0 = reinterpret_cast<DWORD64>(&rt.canary); c.Dr6 = rt.saved.dr6; c.Dr7 = rt.saved.dr7 | canary_dr7;
                rt.dr_attempted.store(true);
                if (set_context(c)) {
                    CONTEXT actual{};
                    if (get_context(actual) && owned(registers(actual), rt.saved, state::canary, reinterpret_cast<std::uint64_t>(&rt.canary)) &&
                        actual.Dr6 == c.Dr6 && GetTickCount64() < rt.expires.load()) rt.phase.store(state::canary);
                    else { stop_fault(fault::readback); rt.phase.store(state::failed); }
                } else rt.phase.store(state::failed);
            }
        } else if (op == 3) {
            if (rt.canary_pass.load() && rt.phase.load() == state::word &&
                owned(registers(c), rt.saved, state::word, reinterpret_cast<std::uint64_t>(&rt.canary)) &&
                !(c.Dr6 & dr6_debug_causes) && !(c.EFlags & 0x100) &&
                !rt.stopping.load() && GetTickCount64() < rt.expires.load()) rt.word_readback.store(true);
            else { stop_fault(fault::readback); rt.phase.store(state::failed); }
        } else if (op == 2) {
            if (!rt.dr_attempted.load()) rt.phase.store(state::closed);
            else if (exact_baseline(registers(c), rt.saved)) {
                // Clean DRs are safe to close, but an unexplained loss of an active point is not coverage proof.
                if (unexpected_baseline(rt.phase.load())) stop_fault(fault::foreign_dr, ERROR_SUCCESS, static_cast<unsigned>(rt.phase.load()));
                rt.restore_readback.store(true); rt.phase.store(state::closed);
            }
            else if (owned(registers(c), rt.saved, state::canary, reinterpret_cast<std::uint64_t>(&rt.canary)) ||
                owned(registers(c), rt.saved, state::word, reinterpret_cast<std::uint64_t>(&rt.canary))) {
                baseline_to(c);
                CONTEXT actual{};
                if (set_context(c) && get_context(actual) && exact_baseline(registers(actual), rt.saved)) {
                    rt.restore_readback.store(true); rt.phase.store(state::closed);
                    auto r = stamp(record_kind::restore); r.has_context = true; r.context = actual; append(r);
                } else { stop_fault(fault::readback); rt.phase.store(state::failed); }
            } else { stop_fault(fault::foreign_dr); rt.phase.store(state::failed); }
        }
    }
    unsigned attempts = 0;
    while (rt.own_suspend.load() && !resume_original()) {
        ++attempts; Sleep(attempts < 3 ? 20 : 30000);
    }
}
void hex(const std::array<std::uint8_t, window_bytes>& bytes, char* out) noexcept {
    static constexpr char alphabet[] = "0123456789ABCDEF";
    for (unsigned i = 0; i < window_bytes; ++i) { out[i * 2] = alphabet[bytes[i] >> 4]; out[i * 2 + 1] = alphabet[bytes[i] & 15]; }
    out[window_bytes * 2] = 0;
}
void flush_records() noexcept {
    captured_record r{};
    while (rt.records.read(rt.flushed, r)) {
        char line[4096]{}; int count{};
        if (r.kind == record_kind::snapshot) {
            char a[129]{}, b[129]{}; hex(r.first, a); hex(r.second, b);
            // Only this publisher allocates/hashes. No crypto or serialization in VEH.
            try {
                const auto hash = utils::cryptography::sha256::compute(r.second.data(), r.second.size(), true);
                count = std::snprintf(line, sizeof(line), "{\"type\":\"snapshot\",\"seq\":%u,\"phase\":%u,\"tid\":%u,\"caller_tid\":%u,\"tick_ms\":%llu,\"qpc\":%llu,\"window_address\":%llu,\"bytes\":64,\"read_calls\":2,\"read_bytes\":128,\"stable\":%s,\"word\":%u,\"first_hex\":\"%s\",\"second_hex\":\"%s\",\"window_sha256\":\"%s\",\"region_base_before\":%llu,\"region_base_after\":%llu,\"region_size_before\":%llu,\"region_size_after\":%llu,\"allocation_base_before\":%llu,\"allocation_base_after\":%llu,\"state_before\":%u,\"state_after\":%u,\"type_before\":%u,\"type_after\":%u,\"protection_before\":%u,\"protection_after\":%u,\"allocation_protection_before\":%u,\"allocation_protection_after\":%u}\n",
                    rt.flushed, static_cast<unsigned>(r.phase), r.tid, r.caller_tid, static_cast<unsigned long long>(r.tick), static_cast<unsigned long long>(r.qpc),
                    static_cast<unsigned long long>(window_start), r.stable ? "true" : "false", static_cast<unsigned>(r.value), a, b, hash.c_str(),
                    static_cast<unsigned long long>(r.before.base), static_cast<unsigned long long>(r.after.base),
                    static_cast<unsigned long long>(r.before.size), static_cast<unsigned long long>(r.after.size),
                    static_cast<unsigned long long>(r.before.allocation), static_cast<unsigned long long>(r.after.allocation),
                    r.before.state, r.after.state, r.before.type, r.after.type, r.before.protection, r.after.protection,
                    r.before.allocation_protection, r.after.allocation_protection);
            } catch (...) { stop_fault(fault::output, ERROR_UNHANDLED_EXCEPTION); }
        } else {
            const auto& c = r.context;
            count = std::snprintf(line, sizeof(line), "{\"type\":\"record\",\"seq\":%u,\"kind\":%u,\"tid\":%u,\"caller_tid\":%u,\"tick_ms\":%llu,\"qpc\":%llu,\"thread_creation_filetime\":%llu,\"reason\":\"%s\",\"win_error\":%u,\"detail\":%u,\"context_captured\":%s,\"context_flags\":%lu,\"integer_registers_valid\":%s,\"rip\":%llu,\"rsp\":%llu,\"rbp\":%llu,\"rax\":%llu,\"rbx\":%llu,\"rcx\":%llu,\"rdx\":%llu,\"rsi\":%llu,\"rdi\":%llu,\"r8\":%llu,\"r9\":%llu,\"r10\":%llu,\"r11\":%llu,\"r12\":%llu,\"r13\":%llu,\"r14\":%llu,\"r15\":%llu,\"dr0\":%llu,\"dr1\":%llu,\"dr2\":%llu,\"dr3\":%llu,\"dr6\":%llu,\"dr7\":%llu,\"eflags\":%lu,\"previous_sample\":%u,\"word\":%u,\"word_read\":%s,\"atomic_before_image\":false,\"stack_unwind_performed\":false}\n",
                rt.flushed, static_cast<unsigned>(r.kind), r.tid, r.caller_tid, static_cast<unsigned long long>(r.tick), static_cast<unsigned long long>(r.qpc),
                static_cast<unsigned long long>(r.creation), name(r.reason), r.error, r.detail, r.has_context ? "true" : "false", static_cast<unsigned long>(c.ContextFlags),
                r.has_context && (c.ContextFlags & CONTEXT_INTEGER) == CONTEXT_INTEGER ? "true" : "false",
                c.Rip, c.Rsp, c.Rbp, c.Rax, c.Rbx, c.Rcx, c.Rdx, c.Rsi, c.Rdi, c.R8, c.R9, c.R10, c.R11, c.R12, c.R13, c.R14, c.R15,
                c.Dr0, c.Dr1, c.Dr2, c.Dr3, c.Dr6, c.Dr7, static_cast<unsigned long>(c.EFlags), static_cast<unsigned>(r.previous), static_cast<unsigned>(r.value), r.word_read ? "true" : "false");
        }
        if (count > 0) format_output(line, count, sizeof(line));
        ++rt.flushed;
    }
}
bool close_retained(retained_handle& h, unsigned which) noexcept {
    if (h.close()) return true;
    stop_fault(fault::handle_close, GetLastError(), which); return false;
}
bool debug_resources_ready() noexcept {
    return rt.ticket.load() == 0 && !rt.helper_inflight.load() &&
        (!rt.dr_attempted.load() || rt.restore_readback.load() || rt.thread_exited.load()) &&
        !rt.own_suspend.load() && (!rt.ever_suspended.load() || rt.resume_confirmed.load() || rt.thread_exited.load());
}
bool final_debug_proof() noexcept {
    const closure_proof p{rt.dr_attempted.load(), rt.restore_readback.load(), rt.own_suspend.load(), rt.resume_confirmed.load(),
        rt.ever_suspended.load(), rt.thread_exited.load(), rt.ticket.load() == 0, rt.helper_inflight.load(),
        !rt.helper.acquired || rt.helper_exited.load(), rt.handler_removed.load(),
        handle_closed(rt.target.acquired, rt.target.status), handle_closed(rt.done.acquired, rt.done.status),
        handle_closed(rt.signal.acquired, rt.signal.status), handle_closed(rt.helper.acquired, rt.helper.status)};
    return debug_closed(p);
}
DWORD WINAPI helper_loop(void*) noexcept {
    while (!rt.helper_stop.load()) {
        WaitForSingleObject(rt.signal.value, 20);
        if (rt.started.load() && elapsed(GetTickCount64(), rt.started.load(), duration_ms) && !rt.stopping.load()) stop_fault(fault::deadline);
        unsigned expected = 1;
        if (rt.ticket.compare_exchange_strong(expected, 2)) {
            rt.helper_inflight.store(true); service(rt.operation.load());
            publish_completion(rt.ticket, rt.helper_inflight, [] {
                if (!SetEvent(rt.done.value)) stop_fault(fault::registration, GetLastError());
            });
        }
        flush_records();
        if (rt.stopping.load()) {
            scoped_lock lock(rt.barrier);
            if (rt.ticket.load() != 0 || rt.helper_inflight.load()) continue;
            if (rt.target.value && WaitForSingleObject(rt.target.value, 0) == WAIT_OBJECT_0) {
                rt.thread_exited.store(true); rt.own_suspend.store(false); rt.phase.store(state::closed);
            }
            if (debug_resources_ready()) {
                if (rt.handler && !RemoveVectoredExceptionHandler(rt.handler)) stop_fault(fault::handler_remove, GetLastError());
                else { rt.handler = nullptr; rt.handler_removed.store(true); }
                if (rt.handler_removed.load() && close_retained(rt.target, 1)) rt.helper_stop.store(true);
            }
        }
    }
    flush_records(); rt.helper_exited.store(true, std::memory_order_release); return 0;
}
bool checkpoint(unsigned op) noexcept {
    if (GetCurrentThreadId() != rt.tid.load()) { stop_fault(fault::wrong_tid); return false; }
    {
        scoped_lock lock(rt.barrier);
        if (rt.helper_stop.load() || !rt.helper.value || !rt.done.value || !rt.signal.value) return false;
        if (op == 2 && rt.phase.load() == state::closed) return true;
        if (op == 1 && operation(rt.phase.load(), rt.stopping.load(), rt.helper_stop.load()) != 1) return false;
        if (rt.ticket.load() != 0) { stop_fault(fault::phase_order); return false; }
        if (!ResetEvent(rt.done.value)) { stop_fault(fault::registration, GetLastError()); return false; }
        rt.operation.store(op); rt.expires.store(GetTickCount64() + checkpoint_ms);
        rt.ticket.store(1, std::memory_order_release);
        if (!SetEvent(rt.signal.value)) stop_fault(fault::registration, GetLastError());
    }
    while (rt.ticket.load(std::memory_order_acquire) != 3) {
        if (may_cancel(rt.ticket.load(), GetTickCount64(), rt.expires.load())) {
            unsigned waiting = 1;
            if (rt.ticket.compare_exchange_strong(waiting, 0)) { stop_fault(fault::ticket_expired); return false; }
        }
        // A claimed ticket cannot escape while the helper still owns a suspension.
        WaitForSingleObject(rt.done.value, 20);
    }
    rt.ticket.store(0, std::memory_order_release);
    return op == 1 ? rt.phase.load() == state::canary : (op == 3 ? rt.word_readback.load() : rt.phase.load() == state::closed);
}
void pending_stdout(unsigned attempt) noexcept {
    char line[256]{};
    const auto n = std::snprintf(line, sizeof(line), "{\"type\":\"word_provenance_closure_pending\",\"pid\":%lu,\"tid\":%u,\"attempt\":%u,\"same_original_objects\":true}\n",
        static_cast<unsigned long>(GetCurrentProcessId()), rt.tid.load(), attempt);
    if (n > 0 && static_cast<unsigned>(n) < sizeof(line)) { DWORD written{}; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), line, static_cast<DWORD>(n), &written, nullptr); }
}
void finish_debug() noexcept {
    scoped_lock sole_closer(rt.closer);
    unsigned attempt = 0;
    while (!rt.debug_cleanup.load()) {
        bool restore = false, unregistered = false;
        {
            scoped_lock lock(rt.barrier);
            restore = rt.target.value && rt.phase.load() != state::closed && GetCurrentThreadId() == rt.tid.load();
            unregistered = !rt.target.acquired && !rt.dr_attempted.load();
        }
        if (restore) checkpoint(2);
        if (unregistered) rt.phase.store(state::closed);
        if (rt.signal.value) SetEvent(rt.signal.value);
        if (rt.helper.value && WaitForSingleObject(rt.helper.value, 0) == WAIT_OBJECT_0 && rt.helper_exited.load()) {
            // The target acknowledged ticket0 before this event/handle closure.
            if (debug_resources_ready() && rt.handler_removed.load() && close_retained(rt.target, 1) &&
                close_retained(rt.done, 2) && close_retained(rt.signal, 3) && close_retained(rt.helper, 4) && final_debug_proof()) rt.debug_cleanup.store(true);
        } else if (!rt.helper.acquired && !rt.dr_attempted.load() && rt.handler_removed.load()) {
            if (close_retained(rt.target, 1) && close_retained(rt.done, 2) && close_retained(rt.signal, 3) && final_debug_proof()) rt.debug_cleanup.store(true);
        }
        if (!rt.debug_cleanup.load()) { if (attempt < 3) pending_stdout(attempt + 1); ++attempt; Sleep(attempt < 3 ? 20 : 30000); }
    }
}
bool environment_value(const char* key, char* out, DWORD capacity) noexcept {
    const auto size = GetEnvironmentVariableA(key, out, capacity); return size > 0 && size < capacity;
}
void initialize() noexcept {
    const launch_flags flags{utils::flags::has_flag("dedicated"), utils::flags::has_flag("paris-isolated-lab"),
        utils::flags::has_flag("paris-server-test"), utils::flags::has_flag("paris-debugger"),
        utils::flags::has_flag("paris-word-provenance-startup"), utils::flags::has_flag("paris-provenance-reviewed"),
        utils::flags::has_flag("paris-capacity-watch"), utils::flags::has_flag("paris-word-provenance-restart")};
    if (!permitted(flags)) {
        // An explicitly reviewed private request for the unsupported mode is refused, never reinterpreted as STARTUP.
        if (flags.dedicated && flags.lab && flags.server_test && flags.debugger && flags.reviewed && flags.restart) {
            static constexpr char refusal[] = "{\"type\":\"word_provenance_activation_refused\",\"reason\":\"restart_not_implemented\"}\n";
            DWORD written{}; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), refusal, sizeof(refusal) - 1, &written, nullptr);
        }
        return;
    }
    if (!environment_value("IW7_WORD_PROVENANCE_NONCE", rt.nonce, sizeof(rt.nonce)) || !valid_nonce(rt.nonce) ||
        !environment_value("IW7_WORD_PROVENANCE_REVIEW_SHA256", rt.review, sizeof(rt.review)) || !valid_hash(rt.review) ||
        !environment_value("IW7_WORD_PROVENANCE_NATIVE_SHA256", rt.native, sizeof(rt.native)) || !valid_hash(rt.native)) return;
    rt.active.store(true);
    FILETIME a{}, b{}, c{}, d{}; LARGE_INTEGER f{};
    if (!GetProcessTimes(GetCurrentProcess(), &a, &b, &c, &d) || !QueryPerformanceFrequency(&f) || f.QuadPart <= 0) { stop_fault(fault::identity, GetLastError()); return; }
    rt.process_creation = (static_cast<std::uint64_t>(a.dwHighDateTime) << 32) | a.dwLowDateTime; rt.frequency = static_cast<std::uint64_t>(f.QuadPart);
    char path[160]{};
    const auto count = std::snprintf(path, sizeof(path), "iw7-word-provenance-%lu-%s.jsonl", static_cast<unsigned long>(GetCurrentProcessId()), rt.nonce);
    if (count < 0 || static_cast<unsigned>(count) >= sizeof(path)) { stop_fault(fault::activation); return; }
    const auto output = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (output == INVALID_HANDLE_VALUE) { stop_fault(fault::output, GetLastError()); return; }
    rt.output.capture(output);
    char header[2048]{};
    const auto n = std::snprintf(header, sizeof(header), "{\"type\":\"header\",\"schema\":\"iw7.word-provenance-startup/1\",\"pid\":%lu,\"creation_filetime\":%llu,\"nonce\":\"%s\",\"review_sha256\":\"%s\",\"native_sha256_parent_binding\":\"%s\",\"native_hash_requires_parent_manifest\":true,\"qpc_frequency\":%llu,\"target_address\":%llu,\"target_bytes\":2,\"window_address\":%llu,\"window_bytes\":64,\"max_snapshots\":4,\"max_read_calls\":8,\"max_read_bytes\":512,\"max_word_reads\":64,\"max_word_read_bytes\":128,\"max_tids\":1,\"max_records\":64,\"duration_ms\":10000,\"checkpoint_ms\":200,\"restart_implemented\":false,\"stack_unwind_performed\":false,\"pristine_unpacked_claim\":false}\n",
        static_cast<unsigned long>(GetCurrentProcessId()), static_cast<unsigned long long>(rt.process_creation), rt.nonce, rt.review, rt.native,
        static_cast<unsigned long long>(rt.frequency), static_cast<unsigned long long>(target_word), static_cast<unsigned long long>(window_start));
    format_output(header, n, sizeof(header));
    const auto signal = CreateEventW(nullptr, FALSE, FALSE, nullptr); if (signal) rt.signal.capture(signal);
    const auto done = CreateEventW(nullptr, TRUE, FALSE, nullptr); if (done) rt.done.capture(done);
    if (!signal || !done || rt.output_failed.load()) { stop_fault(fault::registration, GetLastError()); return; }
    // post_start is BEFORE load_binary/load_tls: do not create a helper after retail TLS substitution.
    const auto helper = CreateThread(nullptr, 0, helper_loop, nullptr, 0, nullptr);
    if (!helper) { stop_fault(fault::registration, GetLastError()); return; }
    rt.helper.capture(helper);
}
void close_output() noexcept {
    scoped_lock sole_closer(rt.closer);
    unsigned attempt = 0;
    while (!close_retained(rt.output, 5)) { if (attempt < 3) pending_stdout(attempt + 1); ++attempt; Sleep(attempt < 3 ? 20 : 30000); }
    rt.output_closed.store(true);
}
class component final : public component_interface {
    void post_start() override { initialize(); }
    void pre_destroy() override {
        if (!rt.active.load()) return;
        rt.stopping.store(true); finish_debug();
        // No fabricated completed phase when exit preceded after_first_post_unpack.
        close_output();
    }
};
}

void loaded_boundary() noexcept {
    if (!rt.active.load()) return;
    if (rt.snapshot_claimed[0].load()) { stop_fault(fault::phase_order); return; }
    unsigned empty = 0;
    if (!rt.loaded_tid.compare_exchange_strong(empty, GetCurrentThreadId())) { stop_fault(fault::phase_order); return; }
    snapshot(boundary::loaded);
}
void after_all_post_load() noexcept {
    if (!rt.active.load()) return;
    if (rt.postload_claimed.exchange(true) || !rt.snapshot_claimed[0].load()) { stop_fault(fault::phase_order); return; }
    if (!same_bootstrap(rt.loaded_tid.load(), GetCurrentThreadId())) { stop_fault(fault::wrong_tid); return; }
    snapshot(boundary::after_post_load);
    if (rt.stopping.load() || !rt.helper.value) return;
    {
    scoped_lock lock(rt.barrier);
    if (rt.stopping.load() || rt.helper_stop.load()) return;
    rt.tid.store(GetCurrentThreadId()); local_runtime = &rt;
    const auto handle = OpenThread(THREAD_GET_CONTEXT | THREAD_SET_CONTEXT | THREAD_SUSPEND_RESUME | THREAD_QUERY_INFORMATION | SYNCHRONIZE, FALSE, rt.tid.load());
    if (!handle) { stop_fault(fault::registration, GetLastError()); return; }
    rt.target.capture(handle);
    FILETIME a{}, b{}, c{}, d{};
    if (GetThreadId(handle) != rt.tid.load() || !GetThreadTimes(handle, &a, &b, &c, &d)) { stop_fault(fault::identity, GetLastError()); return; }
    rt.thread_creation = (static_cast<std::uint64_t>(a.dwHighDateTime) << 32) | a.dwLowDateTime;
    rt.handler = AddVectoredExceptionHandler(1, observer);
    if (!rt.handler) { stop_fault(fault::registration, GetLastError()); return; }
    rt.handler_removed.store(false); rt.started.store(GetTickCount64());
    }
    if (checkpoint(1) && !rt.stopping.load()) {
        InterlockedExchange64(&rt.canary, 1);
        if (!rt.canary_pass.load()) stop_fault(fault::canary);
        else checkpoint(3); // A second real readback proves the word point after the VEH transition.
    }
    if (rt.stopping.load() || !rt.word_readback.load()) { rt.stopping.store(true); finish_debug(); }
}
void before_first_post_unpack() noexcept {
    if (!rt.active.load() || rt.before_claimed.exchange(true)) return;
    if (!rt.postload_claimed.load() || !same_bootstrap(rt.loaded_tid.load(), GetCurrentThreadId()) ||
        (rt.tid.load() && GetCurrentThreadId() != rt.tid.load())) stop_fault(fault::wrong_tid);
    if (rt.started.load() && elapsed(GetTickCount64(), rt.started.load(), duration_ms)) stop_fault(fault::deadline);
    snapshot(boundary::before_post_unpack);
    rt.stopping.store(true); finish_debug(); // Arxan's existing DR reset is reached only after our debug closure.
}
void after_first_post_unpack() noexcept {
    if (!rt.active.load() || rt.after_claimed.exchange(true)) return;
    if (!same_bootstrap(rt.loaded_tid.load(), GetCurrentThreadId())) { stop_fault(fault::wrong_tid); return; }
    if (!rt.before_claimed.load() || !rt.debug_cleanup.load()) { stop_fault(fault::phase_order); return; }
    snapshot(boundary::after_post_unpack);
    // Helper is proved exited. This boundary becomes the sole publisher, never concurrently.
    flush_records();
    for (unsigned i = 0; i < static_cast<unsigned>(fault::count); ++i) {
        char total[256]{};
        const auto count = std::snprintf(total, sizeof(total), "{\"type\":\"fault_total\",\"reason\":\"%s\",\"count\":%u,\"last_win_error\":%u,\"target_tid\":%u}\n",
            name(static_cast<fault>(i)), rt.totals[i].load(), rt.last_error[i].load(), rt.tid.load());
        format_output(total, count, sizeof(total));
    }
    char line[1024]{};
    const auto n = std::snprintf(line, sizeof(line), "{\"type\":\"complete\",\"failures\":%u,\"writes\":%u,\"records\":%u,\"published_records\":%u,\"drops\":%u,\"diagnostic_drops\":%u,\"canary_pass\":%s,\"word_readback\":%s,\"restore_readback\":%s,\"resume_confirmed\":%s,\"thread_exit_proven\":%s,\"debug_cleanup_confirmed\":%s,\"helper_acquired\":%s,\"helper_exited\":%s,\"handler_removed\":%s,\"target_disposition\":%u,\"done_disposition\":%u,\"signal_disposition\":%u,\"helper_disposition\":%u,\"output_close_pending\":true,\"coverage_complete\":%s,\"restart_implemented\":false,\"all_thread_coverage_claim\":false}\n",
        rt.failures.load(), rt.writes.load(), rt.records.reserved(), rt.flushed, rt.drops.load(), rt.diagnostic_drops.load(),
        rt.canary_pass.load() ? "true" : "false", rt.word_readback.load() ? "true" : "false", rt.restore_readback.load() ? "true" : "false",
        rt.resume_confirmed.load() ? "true" : "false", rt.thread_exited.load() ? "true" : "false", rt.debug_cleanup.load() ? "true" : "false",
        rt.helper.acquired ? "true" : "false", rt.helper_exited.load() ? "true" : "false", rt.handler_removed.load() ? "true" : "false",
        static_cast<unsigned>(rt.target.status), static_cast<unsigned>(rt.done.status), static_cast<unsigned>(rt.signal.status), static_cast<unsigned>(rt.helper.status),
        !rt.failures.load() && rt.canary_pass.load() && rt.word_readback.load() &&
        rt.restore_readback.load() && rt.resume_confirmed.load() && rt.flushed == rt.records.reserved() ? "true" : "false");
    format_output(line, n, sizeof(line));
    if (rt.output.value && !FlushFileBuffers(rt.output.value)) { rt.output_failed.store(true); stop_fault(fault::output, GetLastError()); }
    close_output();
    char status[256]{};
    const auto size = std::snprintf(status, sizeof(status), "{\"type\":\"word_provenance_output_closed\",\"pid\":%lu,\"creation_filetime\":%llu,\"nonce\":\"%s\",\"confirmed\":true,\"failures\":%u,\"output_failed\":%s}\n",
        static_cast<unsigned long>(GetCurrentProcessId()), static_cast<unsigned long long>(rt.process_creation), rt.nonce, rt.failures.load(), rt.output_failed.load() ? "true" : "false");
    if (size > 0 && static_cast<unsigned>(size) < sizeof(status)) { DWORD written{}; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), status, static_cast<DWORD>(size), &written, nullptr); }
}
bool cleanup_confirmed() noexcept { return !rt.active.load() || (rt.debug_cleanup.load() && rt.output_closed.load()); }
}
REGISTER_COMPONENT(paris_word_provenance::component)
