#pragma once

#include <array>
#include <cmath>
#include <cstdint>
#include <stdexcept>

namespace collision_provider
{
    using point = std::array<float, 3>;

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
        std::uint32_t producer_class, std::uint32_t mask_2080_class, std::uint32_t no_change_class)
    {
        // Caller separately verifies the dedicated static script_model and
        // retail producer bindings. Preserve the existing bit1 admission.
        if (!linked) return false;
        if (contents & 1U) return true;
        // Probe B observed exactly this linked retail producer case. Other
        // nonzero masks, class IDs or unqualified runtime globals do not suffice.
        return linked == 1 && contents == 0x2080U && producer_class != 0 &&
            producer_class == mask_2080_class && no_change_class != 0 &&
            mask_2080_class != no_change_class;
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
