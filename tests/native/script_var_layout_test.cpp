#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "../../src/native/script_var_layout.hpp"
#include "../../src/native/script_variables.hpp"

// The accessor layout of the client project's script helpers (a48): stock addresses by default, the relocated tables after install, refusal outside.
// The stock row must be the engine's (script_variables.hpp, read from the shipped initialiser); the relocated row the component's own sizes.
static_assert(script_var_layout::stock.objects == script_variables::stock_p8);
static_assert(script_var_layout::stock.object_children == script_variables::stock_p4);
static_assert(script_var_layout::stock.children == script_variables::stock_ch);
static_assert(script_var_layout::stock.parent_ids == script_variables::stock_parent_ids);
static_assert(script_var_layout::stock.child_entries == script_variables::stock_child_entries);
static_assert(script_var_layout::child_bytes == script_variables::child_bytes_each);
static_assert(script_var_layout::segments == script_variables::segments);

static int failures;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++failures; } } while (0)

static std::vector<const char*> logged;
static void log_one(const char* what) { logged.push_back(what); }

int main() {
    using namespace script_var_layout;
    // stock: the formula of the shipped accessors, entry = id + 0xA000 * (parent & 3), 0x18 bytes
    CHECK(!current().relocated);
    for (std::uint32_t parent : {4u, 5u, 6u, 7u, 0x1234u, 0xDBFFu})
        for (std::uint32_t id : {1u, 2u, 0x9FFFu})
            CHECK(child_address(parent, id) == 0x146756180ull + (static_cast<std::uint64_t>(id) + 0xA000ull * (parent & 3)) * 0x18);
    CHECK(object_address(0) == 0x146691180ull);
    CHECK(object_address(0xDBFF) == 0x146691180ull + 0xDBFFull * 8);
    CHECK(object_children_address(0xDBFF) == 0x1466FF180ull + 0xDBFFull * 4);
    // stock refusals: ids at and over the table, child index 0 (the list head) and 0xA000
    CHECK(object_address(0xDC00) == 0 && object_children_address(0xDC00) == 0);
    CHECK(child_address(0xDC00, 1) == 0 && child_address(4, 0) == 0 && child_address(4, 0xA000) == 0 && child_address(4, 0xFFFF) == 0);
    CHECK(refusals().load() == 6);
    CHECK(logged.empty());  // no hook installed yet

    // relocated: 0x10000 parent ids, 0x10000 children a segment, tables elsewhere
    refusal_log() = log_one;
    refusals() = 0;
    std::vector<unsigned char> storage(1);
    const auto base = reinterpret_cast<std::uintptr_t>(storage.data());
    install({base + 0x1000, base + 0x400000, base + 0x800000, script_variables::parent_ids, script_variables::child_entries, true});
    CHECK(current().relocated);
    CHECK(object_address(0xFFFF) == base + 0x1000 + 0xFFFFull * 8);
    CHECK(object_children_address(0xFFFF) == base + 0x400000 + 0xFFFFull * 4);
    CHECK(child_address(4, 1) == base + 0x800000 + 1ull * 0x18);                                        // segment 0
    CHECK(child_address(5, 1) == base + 0x800000 + (0x10000ull + 1) * 0x18);                            // segment 1
    CHECK(child_address(0xFFFF, 0xFFFF) == base + 0x800000 + (3ull * 0x10000 + 0xFFFF) * 0x18);          // the last entry of the last segment
    CHECK(child_address(4, 0xA000) != 0);                                                                // valid now, refused on stock
    CHECK(object_address(0xDC00) != 0);
    // refusals: past 16 bits and the list head; the first one reaches the hook, once
    CHECK(object_address(0x10000) == 0 && child_address(0x10000, 1) == 0 && child_address(4, 0x10000) == 0 && child_address(4, 0) == 0);
    CHECK(refusals().load() == 4 && logged.size() == 1);
    // typed access
    struct entry { std::uint8_t bytes[0x18]; };
    CHECK(child<entry>(4, 2) == reinterpret_cast<entry*>(base + 0x800000 + 2 * 0x18));
    CHECK(child<entry>(4, 0) == nullptr && object<std::uint64_t>(0x10000) == nullptr);

    // a stock layout installed back (the component off): the shipped formula again
    install(stock);
    CHECK(child_address(7, 0x9FFF) == 0x146756180ull + (0x9FFFull + 0xA000ull * 3) * 0x18);

    if (failures) { std::printf("script_var_layout_test: %d failures\n", failures); return 1; }
    std::printf("script_var_layout_test: ok\n");
    return 0;
}
