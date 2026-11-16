#include <cstdint>
#include <cstdio>
#include <unordered_map>

#include "../../src/native/paris_vm_filter.hpp"

// The opcode filter (a51): every replaced code position must read as possibly replaced (a miss would skip a replacefunc), and with no position marked
// every lookup must read as not replaced (the stub then skips the register save and the map lookup).
static_assert(sizeof(paris_vm_filter::table) == 0x10000, "the stub indexes 16 bits");

static int failures;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++failures; } } while (0)

int main() {
    // empty table: nothing can be replaced
    for (std::uintptr_t p = 0x140000000ull; p < 0x140000000ull + 0x30000; p += 7)
        CHECK(!paris_vm_filter::maybe_replaced(reinterpret_cast<const void*>(p)));

    // every marked position (script function entries are anywhere in the loaded script memory) reads as possibly replaced
    std::unordered_map<std::uintptr_t, std::uintptr_t> map;
    std::uint32_t seed = 12345;
    for (int i = 0; i < 400; ++i) {
        seed = seed * 1664525u + 1013904223u;
        const std::uintptr_t pos = 0x1500000000ull + (static_cast<std::uintptr_t>(seed) << 4) % 0x40000000ull;
        map[pos] = pos + 1;
        paris_vm_filter::mark(reinterpret_cast<const void*>(pos));
    }
    for (const auto& kv : map) CHECK(paris_vm_filter::maybe_replaced(reinterpret_cast<const void*>(kv.first)));

    // positions that are not replaced mostly read as such: the fast path is the common one (400 entries of 65,536 slots)
    int slow = 0, total = 0;
    for (std::uintptr_t p = 0x1500000000ull; p < 0x1500000000ull + 0x100000; p += 3) {
        if (map.count(p)) continue;
        ++total;
        if (paris_vm_filter::maybe_replaced(reinterpret_cast<const void*>(p))) ++slow;
    }
    CHECK(total > 100000);
    CHECK(slow * 100 < total);  // under 1 percent reach the slow path (400 of 65,536 slots = 0.6 percent)

    // the stub indexes the table with the low 16 bits of the position (movzx r15d, si)
    CHECK(paris_vm_filter::index_of(reinterpret_cast<const void*>(0x1234567800ABCDull)) == 0xABCD);

    // clear: back to nothing replaced (map change, script shutdown)
    paris_vm_filter::clear();
    for (const auto& kv : map) CHECK(!paris_vm_filter::maybe_replaced(reinterpret_cast<const void*>(kv.first)));

    if (failures) { std::printf("%d failure(s)\n", failures); return 1; }
    std::printf("vm filter test: ok\n");
    return 0;
}
