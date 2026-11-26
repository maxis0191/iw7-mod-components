#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "console/console.hpp"
#include "command.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <psapi.h>
#include <atomic>
#include <cstring>
#include <algorithm>
#include <map>
#include <vector>
#pragma comment(lib, "psapi.lib")

// Allocation census (-alloc-census): who reserves and commits the memory of the process, by caller. ntdll!NtAllocateVirtualMemory (and its Ex form) is the one
// door of VirtualAlloc, of the NT heap, of the CRT and of every DLL. Every successful call is recorded with the first three call frames outside
// ntdll/kernelbase/kernel32 in fixed tables (no allocation, no console in the hook), in three kinds:
//   reserve  : MEM_RESERVE only (a pool is reserved here, committed later in pieces),
//   new      : MEM_RESERVE | MEM_COMMIT (a block committed whole),
//   into     : MEM_COMMIT into memory reserved earlier (a pool growing, a heap segment growing), of any size.
// Every reservation of 1 MB or more is also kept (base, size, callers). `paris_alloc_zero` walks them: per caller, the bytes reserved, committed and the
// committed bytes that are zero pages (never written by the engine). A thread prints the top of the tables to the console log every 15 s when they
// changed, and `paris_alloc_census` prints them at once.
// LZ, 27 Nov 2026: the lazy commit A/B found 30 of about 500 big blocks at the allocator's two call sites; this says where the rest comes from.
namespace alloc_census {
namespace {
constexpr SIZE_T big = 1 << 20;
constexpr std::size_t slots = 8192, max_reservations = 32768;
struct entry { unsigned kind; std::uintptr_t frame[3]; SIZE_T bytes, largest; std::uint64_t count; };
struct reservation { std::uintptr_t base; SIZE_T size; std::uintptr_t frame[3]; };
entry table[slots];
reservation reservations[max_reservations];
std::size_t reservation_count{};
std::atomic_flag guard = ATOMIC_FLAG_INIT;
std::atomic<std::uint64_t> version{}, dropped{}, ex_count{};
std::uintptr_t system_lo[3], system_hi[3];
utils::hook::detour nt_hook, nt_ex_hook;
std::atomic_bool running{true};
double before_mb{};
unsigned before_blocks{};
const char* const kind_name[3] = {"reserve", "new", "into"};

bool system_frame(std::uintptr_t a) {
    for (int i = 0; i < 3; ++i) if (a >= system_lo[i] && a < system_hi[i]) return true;
    return false;
}

void record(ULONG type, bool existing, std::uintptr_t base, SIZE_T size) {
    unsigned kind;
    if (type & MEM_COMMIT) kind = (type & MEM_RESERVE) || !existing ? 1 : 2;
    else if (type & MEM_RESERVE) kind = 0;
    else return;
    void* frames[14]{};
    const auto got = RtlCaptureStackBackTrace(1, 14, frames, nullptr);
    std::uintptr_t key[3]{};
    unsigned have = 0;
    for (USHORT i = 0; i < got && have < 3; ++i) {
        const auto a = reinterpret_cast<std::uintptr_t>(frames[i]);
        if (have == 0 && system_frame(a)) continue;
        key[have++] = a;
    }
    while (guard.test_and_set(std::memory_order_acquire)) {}
    bool stored = false;
    for (std::size_t i = 0; i < slots && !stored; ++i) {
        auto& e = table[i];
        if (!e.count) { e = {kind, {key[0], key[1], key[2]}, size, size, 1}; stored = true; }
        else if (e.kind == kind && e.frame[0] == key[0] && e.frame[1] == key[1] && e.frame[2] == key[2]) { e.bytes += size; e.largest = (std::max)(e.largest, size); ++e.count; stored = true; }
    }
    if ((type & MEM_RESERVE) && size >= big && reservation_count < max_reservations)
        reservations[reservation_count++] = {base, size, {key[0], key[1], key[2]}};
    guard.clear(std::memory_order_release);
    if (stored) ++version; else ++dropped;
}

LONG NTAPI nt_stub(HANDLE process, PVOID* base, ULONG_PTR zero_bits, PSIZE_T size, ULONG type, ULONG protect) {
    const bool existing = base && *base;
    const auto status = nt_hook.invoke<LONG>(process, base, zero_bits, size, type, protect);
    if (status >= 0 && process == GetCurrentProcess() && size && base) record(type, existing, reinterpret_cast<std::uintptr_t>(*base), *size);
    return status;
}
// Windows 11: VirtualAlloc2, MapViewOfFile3 and some drivers use the Ex form.
LONG NTAPI nt_ex_stub(HANDLE process, PVOID* base, PSIZE_T size, ULONG type, ULONG protect, PVOID extended, ULONG count) {
    const bool existing = base && *base;
    const auto status = nt_ex_hook.invoke<LONG>(process, base, size, type, protect, extended, count);
    if (status >= 0 && process == GetCurrentProcess() && size && base) { ++ex_count; record(type, existing, reinterpret_cast<std::uintptr_t>(*base), *size); }
    return status;
}

// What was already committed when the hook went in (private blocks of 1 MB and more).
void before_hook() {
    std::uintptr_t address = 0;
    MEMORY_BASIC_INFORMATION m{};
    double total = 0;
    unsigned blocks = 0;
    while (VirtualQuery(reinterpret_cast<void*>(address), &m, sizeof(m)) == sizeof(m)) {
        if (m.State == MEM_COMMIT && m.Type == MEM_PRIVATE && m.RegionSize >= big) { total += static_cast<double>(m.RegionSize); ++blocks; }
        address = reinterpret_cast<std::uintptr_t>(m.BaseAddress) + m.RegionSize;
        if (address >= 0x7FFFFFFF0000ull) break;
    }
    before_mb = total / 1048576.0;
    before_blocks = blocks;
}

std::string where(std::uintptr_t a) {
    if (!a) return "-";
    HMODULE module{};
    char name[MAX_PATH]{};
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, reinterpret_cast<LPCSTR>(a), &module) &&
        GetModuleFileNameA(module, name, MAX_PATH)) {
        const char* base = std::strrchr(name, '\\');
        char text[160];
        sprintf_s(text, "%s+%llX", base ? base + 1 : name, static_cast<unsigned long long>(a - reinterpret_cast<std::uintptr_t>(module)));
        return text;
    }
    char text[40];
    sprintf_s(text, "%llX", static_cast<unsigned long long>(a));
    return text;
}
std::string callers(const std::uintptr_t* f) { return where(f[0]) + " <- " + where(f[1]) + " <- " + where(f[2]); }

void report() {
    std::vector<entry> copy;
    while (guard.test_and_set(std::memory_order_acquire)) {}
    for (const auto& e : table) if (e.count) copy.push_back(e);
    guard.clear(std::memory_order_release);
    console::info("[Alloc census] before the hook: %.0f MB in %u private blocks of 1 MB and more; Ex form calls seen: %llu; table dropped %llu\n", before_mb, before_blocks,
        static_cast<unsigned long long>(ex_count.load()), static_cast<unsigned long long>(dropped.load()));
    for (unsigned kind = 0; kind < 3; ++kind) {
        std::vector<entry> rows;
        double total = 0;
        for (const auto& e : copy) if (e.kind == kind) { rows.push_back(e); total += static_cast<double>(e.bytes); }
        std::sort(rows.begin(), rows.end(), [](const entry& a, const entry& b) { return a.bytes > b.bytes; });
        console::info("[Alloc census] %s: %zu sites, %.0f MB\n", kind_name[kind], rows.size(), total / 1048576.0);
        for (std::size_t i = 0; i < rows.size() && i < 14; ++i)
            console::info("[Alloc census]   %s %8.1f MB = %llu calls, largest %.2f MB  %s\n", kind_name[kind], static_cast<double>(rows[i].bytes) / 1048576.0,
                static_cast<unsigned long long>(rows[i].count), static_cast<double>(rows[i].largest) / 1048576.0, callers(rows[i].frame).c_str());
    }
}

// Per caller of the reservations of 1 MB and more: reserved, committed and zero bytes now.
DWORD WINAPI zero_scan(LPVOID) {
    struct total { double reserved{}, committed{}, zero{}; unsigned blocks{}; std::uintptr_t frame[3]{}; };
    std::vector<reservation> list;
    while (guard.test_and_set(std::memory_order_acquire)) {}
    list.assign(reservations, reservations + reservation_count);
    guard.clear(std::memory_order_release);
    std::map<std::string, total> by;
    static const std::uint8_t zero_page[4096]{};
    for (const auto& r : list) {
        MEMORY_BASIC_INFORMATION m{};
        if (VirtualQuery(reinterpret_cast<void*>(r.base), &m, sizeof(m)) != sizeof(m) || reinterpret_cast<std::uintptr_t>(m.AllocationBase) != r.base) continue;
        auto& t = by[callers(r.frame)];
        std::memcpy(t.frame, r.frame, sizeof(t.frame));
        ++t.blocks;
        std::uintptr_t a = r.base;
        const auto end = r.base + r.size;
        while (a < end && VirtualQuery(reinterpret_cast<void*>(a), &m, sizeof(m)) == sizeof(m) && reinterpret_cast<std::uintptr_t>(m.AllocationBase) == r.base) {
            t.reserved += static_cast<double>(m.RegionSize);
            if (m.State == MEM_COMMIT && m.Protect == PAGE_READWRITE) {
                t.committed += static_cast<double>(m.RegionSize);
                for (std::uintptr_t p = a; p + 4096 <= a + m.RegionSize; p += 4096)
                    if (!std::memcmp(reinterpret_cast<const void*>(p), zero_page, 4096)) t.zero += 4096;
            } else if (m.State == MEM_COMMIT) t.committed += static_cast<double>(m.RegionSize);
            a = reinterpret_cast<std::uintptr_t>(m.BaseAddress) + m.RegionSize;
        }
    }
    std::vector<std::pair<std::string, total>> rows(by.begin(), by.end());
    std::sort(rows.begin(), rows.end(), [](const auto& a, const auto& b) { return a.second.zero > b.second.zero; });
    double zero = 0, committed = 0;
    for (const auto& r : rows) { zero += r.second.zero; committed += r.second.committed; }
    console::info("[Alloc zero] reservations of 1 MB and more still alive: %zu callers, %.0f MB committed, %.0f MB zero pages\n", rows.size(), committed / 1048576.0, zero / 1048576.0);
    for (std::size_t i = 0; i < rows.size() && i < 25; ++i)
        console::info("[Alloc zero]   zero %8.1f MB of %8.1f MB committed (%8.1f MB reserved, %u blocks)  %s\n", rows[i].second.zero / 1048576.0, rows[i].second.committed / 1048576.0,
            rows[i].second.reserved / 1048576.0, rows[i].second.blocks, rows[i].first.c_str());
    return 0;
}

DWORD WINAPI reporter(LPVOID) {
    std::uint64_t seen = 0;
    Sleep(5000);
    console::info("[Alloc census] ready: every reservation and commit since post_start is counted by caller (paris_alloc_census, paris_alloc_zero)\n");
    command::add("paris_alloc_census", [] { report(); });
    command::add("paris_alloc_zero", [] { CreateThread(nullptr, 0, zero_scan, nullptr, 0, nullptr); });
    unsigned ticks = 0;
    while (running) {
        Sleep(15000);
        ++ticks;
        const auto now = version.load();
        if (now != seen) { seen = now; report(); }
        if (ticks == 6) zero_scan(nullptr);   // once, about 100 s after the start; later ones by the command
    }
    return 0;
}
}

class component final : public component_interface {
public:
    void post_start() override {   // the earliest hook point: every block the engine reserves or commits from here on is counted
        if (!utils::flags::has_flag("alloc-census")) return;
        const char* names[3] = {"ntdll.dll", "kernelbase.dll", "kernel32.dll"};
        for (int i = 0; i < 3; ++i) {
            MODULEINFO info{};
            const auto module = GetModuleHandleA(names[i]);
            if (!module || !GetModuleInformation(GetCurrentProcess(), module, &info, sizeof(info))) { console::error("[Alloc census] no %s\n", names[i]); return; }
            system_lo[i] = reinterpret_cast<std::uintptr_t>(info.lpBaseOfDll);
            system_hi[i] = system_lo[i] + info.SizeOfImage;
        }
        const auto function = reinterpret_cast<void*>(GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtAllocateVirtualMemory"));
        if (!function) { console::error("[Alloc census] NtAllocateVirtualMemory not found\n"); return; }
        before_hook();
        nt_hook.create(function, reinterpret_cast<void*>(&nt_stub));
        if (const auto ex = GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtAllocateVirtualMemoryEx")) nt_ex_hook.create(reinterpret_cast<void*>(ex), reinterpret_cast<void*>(&nt_ex_stub));
        CreateThread(nullptr, 0, reporter, nullptr, 0, nullptr);
    }
};
}

REGISTER_COMPONENT(alloc_census::component)
