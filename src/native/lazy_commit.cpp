#include <std_include.hpp>
#include "lazy_commit_policy.hpp"
#include "loader/component_loader.hpp"
#include "console/console.hpp"
#include "command.hpp"
#include "game/game.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <intrin.h>
#include <psapi.h>
#include <atomic>
#include <cstring>
#include <stdexcept>
#include <string>
#pragma comment(lib, "psapi.lib")

// Lazy commit of the engine allocator's segments (-lazy-commit). docs/LAZY-COMMIT.md has the design and the addresses.
//
// The engine's dlmalloc-style allocator asks Windows for each segment with VirtualAlloc(0, size, MEM_COMMIT|MEM_RESERVE, PAGE_READWRITE): at
// creation of an mspace (FUN_140eaba60, call at 0x140EABB2F) and when it grows one (FUN_140ead190, call at 0x140EAD20E). A lab client at ready
// commits ~8.3 GB of which ~4.8 GB is such segments never touched. Here those two calls reserve the segment (plus a 64 KB pad that keeps
// neighbours from being merged by the allocator) and commit only its head and its tail. The allocator carves from the top chunk, always in address
// order, and every carve writes the new top chunk's header at the end of what it hands out: that write is the first touch of a reserved page and
// faults; a vectored handler commits from the committed mark up to that address (rounded to 256 KB) and the instruction runs again. So all memory
// the allocator has handed out is committed before the caller sees it (a kernel write such as ReadFile into it cannot hit a reserved page), and
// only the never-carved rest of each segment stays reserved. A segment that is replaced by a new one (its top chunk retired to the bins) is
// committed whole first (FUN_140ead190 is wrapped to know the mspace), and its release (FUN_140eadcd0) is done here for registered blocks,
// because the stock one needs one uniformly committed region.
namespace lazy_commit {
namespace {
constexpr std::uintptr_t create_site = 0x140EABB2Full, grow_site = 0x140EAD20Eull;
constexpr std::uintptr_t grow_function = 0x140EAD190ull, release_function = 0x140EADCD0ull;
constexpr std::uintptr_t mstate_topsize = 0x10, mstate_top = 0x28;   // mstate fields: topsize, top
constexpr std::uintptr_t top_foot = 0x48;                            // fence posts after the top chunk

SRWLOCK lock = SRWLOCK_INIT;
iw7::lazy_commit::table blocks;
std::atomic<std::uint64_t> faults{}, failed_faults{}, retired{}, released{}, lazy_blocks{}, whole_blocks{}, table_full{};
std::atomic_bool active{};
thread_local std::uintptr_t growing_mstate{};
utils::hook::detour grow_hook, release_hook, valloc_hook;
thread_local bool inside{};
std::uintptr_t mod_lo{}, mod_hi{};
std::atomic<std::uint64_t> mod_blocks{};

// On by default in a client (LD, 27 Nov 2026; measured by LZ and the lead: commit at ready 8.295 -> 7.648 GB, working set unchanged). Off by -no-lazy-commit or
// IW7_LAZY_COMMIT=0. -lazy-commit stays accepted and also turns it on in a dedicated server, where it is off by default (the allocator of the server was not measured).
bool enabled() {
    if (utils::flags::has_flag("no-lazy-commit")) return false;
    wchar_t v[8]{};
    if (GetEnvironmentVariableW(L"IW7_LAZY_COMMIT", v, 8) && v[0] == L'0') return false;
    if (utils::flags::has_flag("lazy-commit")) return true;
    return !game::environment::is_dedi();
}

bool commit_pages(std::uintptr_t address, std::size_t bytes) {
    return VirtualAlloc(reinterpret_cast<void*>(address), bytes, MEM_COMMIT, PAGE_READWRITE) != nullptr;
}

// The replacement of the two VirtualAlloc calls (same signature; reached through a rip-relative slot).
LPVOID alloc_impl(LPVOID address, SIZE_T size, DWORD type, DWORD protect) {
    if (address || type != (MEM_COMMIT | MEM_RESERVE) || protect != PAGE_READWRITE) return VirtualAlloc(address, size, type, protect);
    const auto shape = iw7::lazy_commit::plan(size);
    AcquireSRWLockExclusive(&lock);
    const bool room = !blocks.full();
    ReleaseSRWLockExclusive(&lock);
    if (!shape.lazy || !room) {
        if (shape.lazy) ++table_full; else ++whole_blocks;
        return VirtualAlloc(nullptr, size, type, protect);
    }
    auto* memory = static_cast<std::uint8_t*>(VirtualAlloc(nullptr, shape.reserve, MEM_RESERVE, PAGE_READWRITE));
    if (!memory) return nullptr;
    const auto base = reinterpret_cast<std::uintptr_t>(memory);
    if (!commit_pages(base, shape.head) || !commit_pages(base + size - shape.tail, shape.tail)) {
        VirtualFree(memory, 0, MEM_RELEASE);
        return VirtualAlloc(nullptr, size, type, protect);
    }
    AcquireSRWLockExclusive(&lock);
    const bool added = blocks.add(base, size, shape) != nullptr;
    ReleaseSRWLockExclusive(&lock);
    if (!added) {   // lost the room meanwhile: commit the rest and keep the stock behaviour for this block
        if (commit_pages(base, size)) return memory;
        VirtualFree(memory, 0, MEM_RELEASE);
        return nullptr;
    }
    ++lazy_blocks;
    return memory;
}

LPVOID WINAPI alloc_stub(LPVOID address, SIZE_T size, DWORD type, DWORD protect) {
    const auto previous = inside;
    inside = true;
    const auto result = alloc_impl(address, size, type, protect);
    inside = previous;
    return result;
}

// kernelbase!VirtualAlloc, for the callers inside the mod's own executable: the big blocks the renderer commits whole (the umbra query arena, 64 MB per
// thread, 10 threads, 639 of 640 MB zero pages in the census of 27 Nov 2026; two pools of 8.4 MB) take the same lazy path. Memory the mod's code owns and
// writes in user mode only; nothing is read into it by the kernel.
LPVOID WINAPI valloc_stub(LPVOID address, SIZE_T size, DWORD type, DWORD protect) {
    if (!inside && !address && type == (MEM_COMMIT | MEM_RESERVE) && protect == PAGE_READWRITE && size >= 2 * 1024 * 1024) {
        const auto caller = reinterpret_cast<std::uintptr_t>(_ReturnAddress());
        if (caller >= mod_lo && caller < mod_hi) {
            const auto result = alloc_stub(address, size, type, protect);
            if (result) ++mod_blocks;
            return result;
        }
    }
    return valloc_hook.invoke<LPVOID>(address, size, type, protect);
}

// FUN_140ead190 (grow an mspace by a segment): the stock function with the mspace known to the VirtualAlloc replacement, so that the old top is
// committed whole before it is retired to the bins (a retired chunk can be handed out whole, without the header write that commits).
long long grow_stub(long long mstate, ULONGLONG request) {
    const auto previous = growing_mstate;
    growing_mstate = static_cast<std::uintptr_t>(mstate);
    const auto result = grow_hook.invoke<long long>(mstate, request);
    growing_mstate = previous;
    return result;
}

LPVOID WINAPI grow_alloc_stub(LPVOID address, SIZE_T size, DWORD type, DWORD protect) {
    if (const auto mstate = growing_mstate) {
        const auto top = *reinterpret_cast<const std::uintptr_t*>(mstate + mstate_top);
        const auto top_size = *reinterpret_cast<const std::uintptr_t*>(mstate + mstate_topsize);
        if (top) {
            AcquireSRWLockExclusive(&lock);
            if (auto* b = blocks.find(top)) {
                if (blocks.grow_to(*b, top + top_size + top_foot, commit_pages)) ++retired;
                else ++failed_faults;
            }
            ReleaseSRWLockExclusive(&lock);
        }
    }
    return alloc_stub(address, size, type, protect);
}

// FUN_140eadcd0(base, size): munmap of the allocator. A registered block is released whole (the stock one wants one uniformly committed region).
int release_stub(const void* base, ULONGLONG size) {
    AcquireSRWLockExclusive(&lock);
    auto* b = blocks.find_base(reinterpret_cast<std::uintptr_t>(base));
    if (b) {
        if (b->size != size) { ReleaseSRWLockExclusive(&lock); return -1; }   // the stock function refuses a size that is not the whole region
        const bool ok = VirtualFree(const_cast<void*>(base), 0, MEM_RELEASE) != FALSE;
        if (ok) { blocks.remove(b); ++released; }
        ReleaseSRWLockExclusive(&lock);
        return ok ? 0 : -1;
    }
    ReleaseSRWLockExclusive(&lock);
    return release_hook.invoke<int>(base, size);
}

LONG CALLBACK handler(EXCEPTION_POINTERS* info) {
    const auto* r = info->ExceptionRecord;
    if (r->ExceptionCode != EXCEPTION_ACCESS_VIOLATION || r->NumberParameters < 2 || r->ExceptionInformation[0] == 8) return EXCEPTION_CONTINUE_SEARCH;
    AcquireSRWLockExclusive(&lock);
    const auto result = blocks.fault(static_cast<std::uintptr_t>(r->ExceptionInformation[1]), commit_pages);
    ReleaseSRWLockExclusive(&lock);
    if (result == iw7::lazy_commit::fault_result::handled) { ++faults; return EXCEPTION_CONTINUE_EXECUTION; }
    if (result == iw7::lazy_commit::fault_result::failed) ++failed_faults;
    return EXCEPTION_CONTINUE_SEARCH;
}

bool is_virtual_alloc(const void* pointer) {
    for (const auto* name : {"kernel32.dll", "kernelbase.dll"}) {
        const auto module = GetModuleHandleA(name);
        if (module && GetProcAddress(module, "VirtualAlloc") == pointer) return true;
    }
    return false;
}

// `call qword ptr [rip + disp]` (FF 15 disp32, 6 bytes) to VirtualAlloc -> the same instruction through our slot (same length, one 4 byte write).
void check_call(std::uintptr_t site) {
    const auto* code = reinterpret_cast<const std::uint8_t*>(site);
    std::int32_t disp{};
    std::memcpy(&disp, code + 2, sizeof(disp));
    if (code[0] != 0xFF || code[1] != 0x15) throw std::runtime_error("lazy commit: no indirect call at " + std::to_string(site));
    const auto import_slot = reinterpret_cast<void* const*>(site + 6 + disp);
    if (!is_virtual_alloc(*import_slot)) throw std::runtime_error("lazy commit: the call at " + std::to_string(site) + " does not go to VirtualAlloc");
}
void patch_call(std::uintptr_t site, void** slot) {
    const auto delta = reinterpret_cast<std::intptr_t>(slot) - static_cast<std::intptr_t>(site + 6);
    if (delta != static_cast<std::int32_t>(delta)) throw std::runtime_error("lazy commit: slot out of reach");
    const auto value = static_cast<std::int32_t>(delta);
    DWORD old{};
    if (!VirtualProtect(reinterpret_cast<void*>(site + 2), 4, PAGE_EXECUTE_READWRITE, &old)) throw std::runtime_error("lazy commit: VirtualProtect");
    std::memcpy(reinterpret_cast<void*>(site + 2), &value, sizeof(value));
    FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<void*>(site), 6);
    DWORD ignored{};
    VirtualProtect(reinterpret_cast<void*>(site + 2), 4, old, &ignored);
}

void** make_slots() {   // two pointers within 2 GB of the image (above its end)
    for (unsigned attempt = 0; attempt < 4096; ++attempt) {
        const auto wanted = 0x1A0000000ull - static_cast<std::uintptr_t>(attempt) * 0x10000;
        if (auto* memory = VirtualAlloc(reinterpret_cast<void*>(wanted), 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE)) return static_cast<void**>(memory);
    }
    throw std::runtime_error("lazy commit: no slot memory within 2 GB of the image");
}

void print_stats() {
    AcquireSRWLockExclusive(&lock);
    const auto count = blocks.count();
    const auto committed = blocks.committed_bytes();
    const auto reserved = blocks.block_bytes();
    ReleaseSRWLockExclusive(&lock);
    console::info("[Lazy commit] lazy blocks created %llu (of them the mod's own %llu; live %zu), whole blocks %llu, table full %llu, faults %llu (failed %llu), tops committed on retire %llu, released %llu\n",
        lazy_blocks.load(), mod_blocks.load(), count, whole_blocks.load(), table_full.load(), faults.load(), failed_faults.load(), retired.load(), released.load());
    console::info("[Lazy commit] live lazy blocks: %.1f MB reserved by the allocator, %.1f MB committed (%.1f MB not committed)\n",
        reserved / 1048576.0, committed / 1048576.0, (reserved - committed) / 1048576.0);
}
}

class component final : public component_interface {
public:
    void post_start() override {   // before the mod's own components allocate: the renderer's umbra arena is made on its first use
        if (!enabled()) return;
        try {
            MODULEINFO info{};
            if (!GetModuleInformation(GetCurrentProcess(), GetModuleHandleW(nullptr), &info, sizeof(info))) throw std::runtime_error("lazy commit: module information");
            mod_lo = reinterpret_cast<std::uintptr_t>(info.lpBaseOfDll);
            mod_hi = mod_lo + info.SizeOfImage;
            const auto function = GetProcAddress(GetModuleHandleA("kernelbase.dll"), "VirtualAlloc");
            if (!function) throw std::runtime_error("lazy commit: kernelbase VirtualAlloc not found");
            AddVectoredExceptionHandler(1, handler);
            valloc_hook.create(reinterpret_cast<void*>(function), reinterpret_cast<void*>(&valloc_stub));
        } catch (const std::exception& error) {
            console::error("[Lazy commit] mod blocks not lazy: %s\n", error.what());
        }
    }
    void post_unpack() override {
        if (!enabled()) return;
        try {
            auto* slots = make_slots();
            slots[0] = reinterpret_cast<void*>(&alloc_stub);        // the mspace creation
            slots[1] = reinterpret_cast<void*>(&grow_alloc_stub);   // the segment growth
            // The wrappers first (no allocation is lazy before the calls are redirected), then the two calls.
            check_call(create_site);
            check_call(grow_site);
            grow_hook.create(static_cast<std::size_t>(grow_function), reinterpret_cast<void*>(&grow_stub));
            release_hook.create(static_cast<std::size_t>(release_function), reinterpret_cast<void*>(&release_stub));
            patch_call(create_site, &slots[0]);
            patch_call(grow_site, &slots[1]);
            active = true;
            command::add("paris_lazy_commit", [] { print_stats(); });
            console::info("[Lazy commit] ready: allocator segments of 2 MB and more commit their head and tail, the rest on first touch\n");
        } catch (const std::exception& error) {
            console::error("[Lazy commit] not active: %s\n", error.what());
        }
    }
};
}

REGISTER_COMPONENT(lazy_commit::component)
