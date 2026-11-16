#pragma once
#include <atomic>
#include <cstdint>

// Where the engine's GSC variable tables are (a48). The client project's C++ accessors (scripting::array, scripting::entity field get / set,
// script_value type tests) used a fixed `scr_VarGlob` structure at the stock address; with -agent-capacity the tables are moved and
// grown (script_variables.cpp), so every access goes through this layout instead: stock values by default, the relocated ones once the
// script variables component has installed them. An id or index outside its table is refused (null), never read.
//
// Tables (docs/SCRIPT-VARIABLES.md): objects = parent entries of 8 bytes (ObjectVariableValue), object_children = 4 bytes an id
// (ObjectVariableChildren), children = `segments` (4, 8 or 16: a67) segments of child_entries entries of 0x18 bytes, a child of the parent P lives in segment (P & (segments - 1)).
namespace script_var_layout {

struct tables {
    std::uintptr_t objects, object_children, children;
    std::uint32_t parent_ids, child_entries;
    bool relocated;
    std::uint32_t segments = 4;
};

inline constexpr std::uint32_t child_bytes = 0x18, object_bytes = 8, object_children_bytes = 4, stock_segments = 4;
// The shipped tables (read from the engine's own initialiser, ops/gamelab/iw7_budgets.py script_var_layout): 0xDC00 parent ids, 0xA000 children a segment.
inline constexpr tables stock{0x146691180ull, 0x1466FF180ull, 0x146756180ull, 0xDC00, 0xA000, false};

inline tables& current() noexcept {
    static tables value = stock;
    return value;
}
inline std::atomic<unsigned>& refusals() noexcept {
    static std::atomic<unsigned> count{};
    return count;
}
// Set by the script variables component to print the first refusal; the header itself has no console.
using refusal_function = void (*)(const char*);
inline refusal_function& refusal_log() noexcept {
    static refusal_function hook = nullptr;
    return hook;
}
inline void install(const tables& relocated) noexcept { current() = relocated; }

inline void refuse(const char* what) noexcept {
    if (refusals().fetch_add(1) == 0 && refusal_log()) refusal_log()(what);
}

// Address of the parent entry / the object children entry of an id, 0 when the id is outside the table.
inline std::uintptr_t object_address(std::uint32_t id) noexcept {
    const auto& t = current();
    if (id >= t.parent_ids) { refuse("script variable parent id out of range"); return 0; }
    return t.objects + static_cast<std::uintptr_t>(id) * object_bytes;
}
inline std::uintptr_t object_children_address(std::uint32_t id) noexcept {
    const auto& t = current();
    if (id >= t.parent_ids) { refuse("script variable parent id out of range"); return 0; }
    return t.object_children + static_cast<std::uintptr_t>(id) * object_children_bytes;
}
// Address of child entry `variable_id` (1 .. child_entries - 1; entry 0 is the free list head) of a parent, 0 when outside.
inline std::uintptr_t child_address(std::uint32_t parent_id, std::uint32_t variable_id) noexcept {
    const auto& t = current();
    if (parent_id >= t.parent_ids || variable_id == 0 || variable_id >= t.child_entries) { refuse("script variable child index out of range"); return 0; }
    return t.children + (static_cast<std::uintptr_t>(parent_id & (t.segments - 1)) * t.child_entries + variable_id) * child_bytes;
}

template <typename T> T* object(std::uint32_t id) noexcept { return reinterpret_cast<T*>(object_address(id)); }
template <typename T> T* object_children(std::uint32_t id) noexcept { return reinterpret_cast<T*>(object_children_address(id)); }
template <typename T> T* child(std::uint32_t parent_id, std::uint32_t variable_id) noexcept { return reinterpret_cast<T*>(child_address(parent_id, variable_id)); }
}
