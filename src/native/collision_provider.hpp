#pragma once

#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>

namespace collision_provider
{
    using point = std::array<float, 3>;
    using usage_counts = std::array<int, 3>;

    inline bool manual_increment_permitted(const usage_counts& value)
    {
        return value[0] >= 0 && value[0] < std::numeric_limits<int>::max() &&
            value[1] >= 0 && value[2] >= 0;
    }

    inline bool usage_episode_restored(const usage_counts& baseline,
        const usage_counts& after_native_create, const usage_counts& after_increment,
        const usage_counts& before_destroy, const usage_counts& after_native_destroy,
        const usage_counts& after_decrement)
    {
        if (!manual_increment_permitted(baseline)) return false;
        auto contributed = baseline;
        ++contributed[0];
        // These are observed conditions, never instructions to restore a shared
        // engine counter. Native or external changes must remain visible.
        return after_native_create == baseline && after_increment == contributed &&
            before_destroy == contributed && after_native_destroy == contributed &&
            after_decrement == baseline;
    }

    inline bool manual_decrement_permitted(const usage_counts& before_destroy, const usage_counts& after_native_destroy)
    {
        return before_destroy == after_native_destroy && after_native_destroy[0] > 0 &&
            after_native_destroy[1] >= 0 && after_native_destroy[2] >= 0;
    }

    template <typename Destroy>
    inline void destroy_owned_once(bool& alive, bool& in_progress, Destroy destroy)
    {
        if (!alive) return;
        if (in_progress) throw std::runtime_error("Original native destroy is unresolved; do not retry its ID");
        in_progress = true;
        destroy();
        alive = false; // Commit before any fallible post-destroy observation.
        in_progress = false;
    }

    template <typename Quarantine, typename Action>
    inline void quarantine_on_failure(Quarantine& quarantine, Action action)
    {
        try { action(); }
        catch (...) { quarantine = true; throw; }
    }

    struct alignas(16) vertex
    {
        float x, y, z, w;
    };
    static_assert(sizeof(vertex) == 16);

    // hknp factory input observed in the existing capsule creator, not an HKX.
    struct strided_vertices
    {
        const vertex* data;
        std::int32_t count;
        std::int32_t stride;
    };
    static_assert(sizeof(strided_vertices) == 16);

    inline bool world_permitted(bool dedicated, int world)
    {
        // Remote-client privacy and pre-reset lifetime have not been qualified.
        return dedicated && (world == 0 || world == 1);
    }

    inline bool owner_solid_permitted(std::uint32_t contents, std::uint8_t linked,
        std::uint32_t producer_class, std::uint32_t sdk_class,
        std::uint32_t mask_2080_class, std::uint32_t no_change_class)
    {
        // Caller separately verifies the dedicated static script_model and
        // retail producer bindings. Preserve the existing bit1 admission.
        if (!linked) return false;
        if (contents & 1U) return true;
        // Probe B observed exactly this linked retail producer case. Other
        // nonzero masks, class IDs or unqualified runtime globals do not suffice.
        return linked == 1 && contents == 0x2080U && producer_class != 0 &&
            producer_class == sdk_class && producer_class == mask_2080_class && no_change_class != 0 &&
            mask_2080_class != no_change_class;
    }

    template <typename Resolve, typename Validate, typename Lookup>
    inline auto resolve_body_template(const char* name, Resolve resolve, Validate validate, Lookup lookup)
    {
        if (!name || !*name) throw std::invalid_argument("Readable nonempty retail template name required");
        auto* asset = resolve(name);
        if (!asset || !validate(asset)) throw std::runtime_error("Resolved retail body template is unavailable");
        if (!lookup(asset)) throw std::runtime_error("Resolved retail body template has no runtime context");
        return asset;
    }

    struct box
    {
        point minimum, maximum, origin, half;
        std::array<vertex, 8> vertices;
    };

    inline box make_box(const point& minimum, const point& maximum)
    {
        box result{minimum, maximum, {}, {}, {}};
        for (std::size_t axis = 0; axis < 3; ++axis)
        {
            if (!std::isfinite(minimum[axis]) || !std::isfinite(maximum[axis]) ||
                !(maximum[axis] > minimum[axis]))
                throw std::invalid_argument("Finite, strictly ordered box bounds required");
            result.origin[axis] = static_cast<float>((static_cast<double>(minimum[axis]) + maximum[axis]) * 0.5);
            result.half[axis] = static_cast<float>((static_cast<double>(maximum[axis]) - minimum[axis]) * 0.5);
            if (!std::isfinite(result.origin[axis]) || !std::isfinite(result.half[axis]) ||
                !(result.half[axis] * 0.03125f > 0))
                throw std::invalid_argument("Box cannot be represented by the native float geometry");
        }
        // IW7's instantiation wrapper converts game coordinates by exactly 1/32.
        for (std::size_t index = 0; index < result.vertices.size(); ++index)
        {
            result.vertices[index] = {
                result.half[0] * (index & 1 ? 0.03125f : -0.03125f),
                result.half[1] * (index & 2 ? 0.03125f : -0.03125f),
                result.half[2] * (index & 4 ? 0.03125f : -0.03125f), 0};
        }
        return result;
    }
}
