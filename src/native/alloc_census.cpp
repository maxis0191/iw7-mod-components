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
#include <vector>
#pragma comment(lib, "psapi.lib")

// Allocation census (-alloc-census): who commits the big blocks of the process. ntdll!NtAllocateVirtualMemory is the one door of VirtualAlloc, of the NT
// heap's large blocks, of the CRT and of every DLL; each successful MEM_COMMIT of 1 MB or more records its size and the first three call frames outside
// ntdll/kernelbase/kernel32 in a fixed table (no allocation, no console in the hook). A thread prints the top of the table (by bytes) to the console
// log every 15 s when it changed, with module+offset, and the command `paris_alloc_census` prints it at once. LZ, 27 Nov 2026: the lazy commit A/B found
// 30 of about 500 big blocks going through the two allocator call sites; this says where the rest comes from.
namespace alloc_census {
namespace {
constexpr SIZE_T min_size = 1 << 20;
constexpr std::size_t slots = 4096;
struct entry { std::uintptr_t frame[3]; SIZE_T size; std::uint64_t count; };
entry table[slots];
std::atomic_flag guard = ATOMIC_FLAG_INIT;
std::atomic<std::uint64_t> version{}, dropped{};
std::uintptr_t system_lo[3], system_hi[3];
utils::hook::detour nt_hook;
std::atomic_bool running{true};

bool system_frame(std::uintptr_t a) {
    for (int i = 0; i < 3; ++i) if (a >= system_lo[i] && a < system_hi[i]) return true;
    return false;
}

using nt_alloc = LONG(NTAPI*)(HANDLE, PVOID*, ULONG_PTR, PSIZE_T, ULONG, ULONG);
LONG NTAPI nt_stub(HANDLE process, PVOID* base, ULONG_PTR zero_bits, PSIZE_T size, ULONG type, ULONG protect) {
    const auto status = nt_hook.invoke<LONG>(process, base, zero_bits, size, type, protect);
    if (status >= 0 && (type & MEM_COMMIT) && process == GetCurrentProcess() && size && *size >= min_size) {
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
            if (!e.count) { e = {{key[0], key[1], key[2]}, *size, 1}; stored = true; }
            else if (e.size == *size && e.frame[0] == key[0] && e.frame[1] == key[1] && e.frame[2] == key[2]) { ++e.count; stored = true; }
        }
        guard.clear(std::memory_order_release);
        if (stored) ++version; else ++dropped;
    }
    return status;
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

void report() {
    std::vector<entry> copy;
    while (guard.test_and_set(std::memory_order_acquire)) {}
    for (const auto& e : table) if (e.count) copy.push_back(e);
    guard.clear(std::memory_order_release);
    std::sort(copy.begin(), copy.end(), [](const entry& a, const entry& b) { return a.size * a.count > b.size * b.count; });
    double total = 0;
    for (const auto& e : copy) total += static_cast<double>(e.size) * static_cast<double>(e.count);
    console::info("[Alloc census] %zu sites, %.0f MB committed in blocks of 1 MB and more (dropped %llu)\n", copy.size(), total / 1048576.0, dropped.load());
    for (std::size_t i = 0; i < copy.size() && i < 30; ++i) {
        const auto& e = copy[i];
        console::info("[Alloc census] %7.1f MB = %5.2f MB x %-4llu  %s <- %s <- %s\n", static_cast<double>(e.size) * static_cast<double>(e.count) / 1048576.0,
            static_cast<double>(e.size) / 1048576.0, static_cast<unsigned long long>(e.count), where(e.frame[0]).c_str(), where(e.frame[1]).c_str(), where(e.frame[2]).c_str());
    }
}

DWORD WINAPI reporter(LPVOID) {
    std::uint64_t seen = 0;
    Sleep(5000);
    console::info("[Alloc census] ready: blocks of 1 MB and more committed since post_start are counted by caller\n");
    command::add("paris_alloc_census", [] { report(); });
    while (running) {
        Sleep(15000);
        const auto now = version.load();
        if (now != seen) { seen = now; report(); }
    }
    return 0;
}
}

class component final : public component_interface {
public:
    void post_start() override {   // the earliest hook point: every block the engine commits from here on is counted
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
        nt_hook.create(function, reinterpret_cast<void*>(&nt_stub));
        CreateThread(nullptr, 0, reporter, nullptr, 0, nullptr);
    }
};
}

REGISTER_COMPONENT(alloc_census::component)
