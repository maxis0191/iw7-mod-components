#pragma once
#include <cstddef>
#include <cstdint>
#include <windows.h>

// Stack capture shared by the lab diagnostics that sample a thread of the game (paris_perf.cpp, paris_hang.cpp).
// Include std_include.hpp first, as every component does.
//
// Everything here is inline: the header works in a translation unit that is compiled only with -Perf and in one that
// is always compiled. The state (function table, text range) is shared through inline variables: one copy per process.
//
// Sampler rule: capture() is called between SuspendThread and ResumeThread. It touches no heap, no file and no lock.
// A suspended thread may hold any of them. Function entries of the game image come from its own exception directory,
// read once by read_image().
namespace paris_stack
{
    inline constexpr std::uintptr_t image_base = 0x140000000;
    inline constexpr std::size_t max_depth = 16;
    inline constexpr std::size_t max_scan = 6;

    struct raw_sample
    {
        std::uint32_t depth{};
        std::uint32_t scanned{};
        std::uint64_t pc[max_depth]{};
        std::uint64_t scan[max_scan]{};
    };

    inline const RUNTIME_FUNCTION* function_table{};
    inline std::size_t function_count{};
    inline std::uintptr_t text_begin{0x140001000}, text_end{0x141428000};
    inline bool unwind_ready{};

    inline bool readable(const void* address, const std::size_t size)
    {
        MEMORY_BASIC_INFORMATION info{};
        if (!VirtualQuery(address, &info, sizeof(info)) || info.State != MEM_COMMIT) return false;
        if (info.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return false;
        const auto end = reinterpret_cast<std::uintptr_t>(info.BaseAddress) + info.RegionSize;
        return reinterpret_cast<std::uintptr_t>(address) + size <= end;
    }

    // Reads the game image's exception directory once. Safe to call again: it does nothing when the table is ready.
    inline void read_image()
    {
        if (unwind_ready) return;
        // The game image is mapped at its preferred base. Trust its headers only after checking each field.
        const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(image_base);
        if (!readable(dos, sizeof(*dos)) || dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 || dos->e_lfanew > 0x1000) return;
        const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(image_base + dos->e_lfanew);
        if (!readable(nt, sizeof(*nt)) || nt->Signature != IMAGE_NT_SIGNATURE || nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64) return;
        const auto& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
        const std::size_t count = dir.Size / sizeof(RUNTIME_FUNCTION);
        const auto* table = reinterpret_cast<const RUNTIME_FUNCTION*>(image_base + dir.VirtualAddress);
        if (!dir.VirtualAddress || count < 1000 || count > 400000 || !readable(table, 64)) return;
        // The whole table must be readable and sorted where we look.
        for (std::size_t offset = 0; offset < dir.Size; offset += 0x1000)
            if (!readable(reinterpret_cast<const char*>(table) + offset, 1)) return;
        for (std::size_t i = 1; i < count; i += 257)
            if (table[i].BeginAddress < table[i - 1].BeginAddress) return;
        function_table = table;
        function_count = count;
        unwind_ready = true;
    }

    inline const RUNTIME_FUNCTION* find_entry(const std::uint64_t pc)
    {
        if (!unwind_ready || pc < image_base) return nullptr;
        const auto rva = static_cast<std::uint64_t>(pc - image_base);
        std::size_t low = 0, high = function_count;
        while (low < high)
        {
            const auto middle = (low + high) / 2;
            if (rva < function_table[middle].BeginAddress) high = middle;
            else if (rva >= function_table[middle].EndAddress) low = middle + 1;
            else return &function_table[middle];
        }
        return nullptr;
    }

    inline bool in_text(const std::uint64_t pc) { return pc >= text_begin && pc < text_end; }

    // POD only: SEH guards the reads of the suspended thread's stack.
    __declspec(noinline) inline bool capture(const HANDLE thread, raw_sample& out)
    {
        CONTEXT context{};
        context.ContextFlags = CONTEXT_FULL;
        if (!GetThreadContext(thread, &context)) return false;
        out.depth = 0;
        out.scanned = 0;
        __try
        {
            out.pc[out.depth++] = context.Rip;
            if (!in_text(context.Rip))
            {
                // Outside the game image (driver, system): keep the first words of the stack that point into game
                // code. The offline tool keeps those that follow a call instruction.
                const auto* stack = reinterpret_cast<const std::uint64_t*>(context.Rsp);
                for (std::size_t i = 0; i < 96 && out.scanned < max_scan; ++i)
                    if (in_text(stack[i])) out.scan[out.scanned++] = stack[i];
                return true;
            }
            while (out.depth < max_depth)
            {
                const auto* entry = find_entry(context.Rip);
                if (entry)
                {
                    void* handler_data{};
                    DWORD64 establisher{};
                    RtlVirtualUnwind(UNW_FLAG_NHANDLER, image_base, context.Rip, const_cast<PRUNTIME_FUNCTION>(entry), &context, &handler_data, &establisher, nullptr);
                }
                else
                {
                    context.Rip = *reinterpret_cast<const std::uint64_t*>(context.Rsp); // leaf: the return address is on top
                    context.Rsp += 8;
                }
                if (!in_text(context.Rip)) break;
                out.pc[out.depth++] = context.Rip;
            }
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            // A stack that could not be read: keep what was captured.
        }
        return true;
    }
}
