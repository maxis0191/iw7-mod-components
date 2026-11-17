#include <std_include.hpp>
#include "script_canonical.hpp"
#include "loader/component_loader.hpp"
#include "console/console.hpp"
#include "scheduler.hpp"
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <stdexcept>
#include <string>
#include <vector>

// See script_canonical.hpp. Every edit is checked against the shipped bytes first; one mismatch and nothing is written. The edited code is SL_GetCanonicalString
// (0x140BFD340, the client fork's detour sits on its first 5 bytes only) and the allocation of its block (FUN_140C03280). Sites and widths: docs/SCRIPT-CANONICAL.md.
namespace script_canonical {
namespace {
constexpr std::uintptr_t image_base = 0x140000000ull, image_end = 0x14C301400ull;
constexpr std::uintptr_t table_pointer = 0x1460B94F8ull;      // the block: hash first, names behind it (written by FUN_140C03280 only)
std::atomic<std::uint32_t> in_use{stock_names};
std::atomic_bool active{};

using bytes = std::vector<std::uint8_t>;
struct edit { std::uintptr_t at; bytes before, after; const char* what; };
std::vector<edit> plan;

bytes le32(std::uint32_t v) { return {static_cast<std::uint8_t>(v), static_cast<std::uint8_t>(v >> 8), static_cast<std::uint8_t>(v >> 16), static_cast<std::uint8_t>(v >> 24)}; }
bytes cat(std::initializer_list<bytes> parts) { bytes out; for (const auto& p : parts) out.insert(out.end(), p.begin(), p.end()); return out; }
bytes nops(std::size_t n) {
    // the recommended multi byte nops, longest first
    static const bytes forms[] = {{0x0F, 0x1F, 0x84, 0x00, 0, 0, 0, 0}, {0x0F, 0x1F, 0x80, 0, 0, 0, 0}, {0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00}, {0x0F, 0x1F, 0x44, 0x00, 0x00},
                                  {0x0F, 0x1F, 0x40, 0x00}, {0x0F, 0x1F, 0x00}, {0x66, 0x90}, {0x90}};
    bytes out;
    while (out.size() < n)
        for (const auto& f : forms)
            if (out.size() + f.size() <= n) { out.insert(out.end(), f.begin(), f.end()); break; }
    return out;
}

void readable(std::uintptr_t address, std::size_t width) {
    MEMORY_BASIC_INFORMATION info{};
    if (address < image_base || address + width > image_end || VirtualQuery(reinterpret_cast<void*>(address), &info, sizeof(info)) != sizeof(info) ||
        info.State != MEM_COMMIT || (info.Protect & PAGE_GUARD) || address + width > reinterpret_cast<std::uintptr_t>(info.BaseAddress) + info.RegionSize)
        throw std::runtime_error("script canonical: address not readable " + std::to_string(address));
}
void add(std::uintptr_t at, bytes before, bytes after, const char* what) {
    if (before.size() != after.size()) throw std::runtime_error("script canonical: an edit changes the length");
    readable(at, before.size());
    if (std::memcmp(reinterpret_cast<const void*>(at), before.data(), before.size())) {
        char text[200];
        sprintf_s(text, "script canonical: the shipped code differs at %llX (%s)", static_cast<unsigned long long>(at), what);
        throw std::runtime_error(text);
    }
    plan.push_back({at, std::move(before), std::move(after), what});
}
bool write(const edit& e, bool rollback) noexcept {
    DWORD previous{};
    auto address = reinterpret_cast<void*>(e.at);
    const auto& value = rollback ? e.before : e.after;
    if (!VirtualProtect(address, value.size(), PAGE_EXECUTE_READWRITE, &previous)) return false;
    std::memcpy(address, value.data(), value.size());
    const bool flushed = FlushInstructionCache(GetCurrentProcess(), address, value.size()) != FALSE;
    DWORD ignored{};
    return VirtualProtect(address, value.size(), previous, &ignored) && flushed && !std::memcmp(address, value.data(), value.size());
}

long option_value() {
    long requested = -1;
    int count{};
    if (auto args = CommandLineToArgvW(GetCommandLineW(), &count)) {
        for (int i = 0; i + 1 < count; ++i)
            if (!std::wcscmp(args[i], L"-script-canon-names")) {
                wchar_t* end{};
                requested = std::wcstol(args[i + 1], &end, 10);
                if (!end || *end) requested = 0;
            }
        LocalFree(args);
    }
    char env[16]{};
    if (requested < 0 && GetEnvironmentVariableA("IW7_SCRIPT_CANON_NAMES", env, sizeof(env)) && env[0]) {
        char* end{};
        requested = std::strtol(env, &end, 10);
        if (!end || *end) requested = 0;
    }
    return requested;
}

// The block of the table: allocated once, handed out by every script load (the engine clears it itself, FUN_140C03280). The shipped hunk it came from was exactly
// 0x20000 bytes (+ a page): nothing else may share it. One page more than the table, because the shipped name copy may write the byte after a full buffer.
std::uintptr_t block{};

void plan_edits(std::uint32_t names) {
    const auto hash = hash_bytes_for(names), name_bytes = name_bytes_for(names), total = block_bytes_for(names);
    // slot = hash % 4095 + 1  (mov eax,0x100101; mul ebx; ...; imul eax,eax,0xfff; sub ebx,eax; inc ebx)  ->  hash % names + 1; sub ebp,edi (the length) stays
    add(0x140BFD387, {0xB8, 0x01, 0x01, 0x10, 0x00, 0xF7, 0xE3, 0x8B, 0xC3, 0x2B, 0xEF, 0x2B, 0xC2, 0xD1, 0xE8, 0x03, 0xC2, 0xC1, 0xE8, 0x0B, 0x69, 0xC0, 0xFF, 0x0F, 0x00, 0x00, 0x2B, 0xD8, 0xFF, 0xC3},
        cat({{0x2B, 0xEF, 0x8B, 0xC3, 0x33, 0xD2, 0xB9}, le32(names), {0xF7, 0xF1, 0x8D, 0x5A, 0x01}, nops(14)}), "slot of the hash");
    // the probe step: slot + 1, 4095 wraps to 1  ->  names wraps to 1
    add(0x140BFD3DD, {0xB8, 0x01, 0x01, 0x10, 0x00, 0xB9, 0x01, 0x00, 0x00, 0x00, 0xF7, 0xE6, 0x8B, 0xC6, 0x2B, 0xC2, 0xD1, 0xE8, 0x03, 0xC2, 0xC1, 0xE8, 0x0B, 0x69, 0xC0, 0xFF, 0x0F, 0x00, 0x00, 0x2B, 0xC8, 0x03, 0xF1},
        cat({{0xFF, 0xC6, 0x81, 0xFE}, le32(names + 1), {0x75, 0x05, 0xBE, 0x01, 0x00, 0x00, 0x00}, nops(18)}), "probe wrap");
    add(0x140BFD3B5, le32(stock_hash_bytes), le32(hash), "name buffer offset (compare)");
    add(0x140BFD427, le32(stock_name_bytes), le32(name_bytes), "name buffer size");
    add(0x140BFD45E, le32(stock_hash_bytes), le32(hash), "name buffer offset (copy)");
    // FUN_140C03280: `mov rcx,[pool]; mov edx,0x20000; mov r8d,4; call hunk_alloc` -> `mov rax, block` (the pool is not used); the clear takes the whole block
    bytes pointer(8);
    std::memcpy(pointer.data(), &block, 8);
    add(0x140C03284, {0x48, 0x8B, 0x0D, 0xDD, 0x6E, 0xA5, 0x05, 0xBA, 0x00, 0x00, 0x02, 0x00, 0x41, 0xB8, 0x04, 0x00, 0x00, 0x00, 0xE8, 0x25, 0xDC, 0x90, 0xFF},
        cat({{0x48, 0xB8}, pointer, nops(13)}), "block allocation");
    add(0x140C032A6, le32(0x20000), le32(total), "block clear size");
}

class component final : public component_interface {
public:
    void post_unpack() override {
        const auto requested = option_value();
        if (requested < 0) {
            plan_and_apply(default_names);
        } else {
            if (requested < static_cast<long>(stock_names) || requested > static_cast<long>(max_names))
                throw std::runtime_error("script canonical: -script-canon-names takes " + std::to_string(stock_names) + " to " + std::to_string(max_names));
            plan_and_apply(static_cast<std::uint32_t>(requested));
        }
    }

private:
    static void plan_and_apply(std::uint32_t names) {
        if (names == stock_names) {
            scheduler::once([] { console::info("[script canonical] shipped table: %u names, %u name bytes\n", stock_names, stock_name_bytes); }, scheduler::main);
            return;
        }
        // a table that exists already is the shipped one: the code must not change under it
        if (*reinterpret_cast<const volatile std::uintptr_t*>(table_pointer) != 0) throw std::runtime_error("script canonical: the table exists already");
        const auto total = block_bytes_for(names);
        auto memory = VirtualAlloc(nullptr, static_cast<SIZE_T>(total) + 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (!memory) throw std::runtime_error("script canonical: no memory for the table");
        block = reinterpret_cast<std::uintptr_t>(memory);
        plan_edits(names);
        std::size_t applied{};
        for (; applied < plan.size(); ++applied)
            if (!write(plan[applied], false)) {
                bool restored = write(plan[applied], true);
                while (applied) restored = write(plan[--applied], true) && restored;
                if (!restored) std::terminate();
                throw std::runtime_error("script canonical: a code write failed; everything restored");
            }
        in_use = names;
        active = true;
        const auto patches = plan.size();
        scheduler::once([names, total, patches] {
            console::info("[script canonical] %u names (shipped %u): ids 0x%X to 0x%X, hash %u bytes, names %u bytes, block %p, %zu edits\n", names, stock_names, first_id + 1, first_id + names,
                          hash_bytes_for(names), name_bytes_for(names), reinterpret_cast<void*>(block), patches);
            (void)total;
        }, scheduler::main);
    }
};
}

bool installed() noexcept { return active; }
std::uint32_t names_in_use() noexcept { return in_use; }
}

REGISTER_COMPONENT(script_canonical::component)
