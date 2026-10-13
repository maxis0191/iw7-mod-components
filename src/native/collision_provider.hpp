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
