#include "../../src/native/collision_provider.hpp"
#include <cassert>
#include <limits>

int main()
{
    using namespace collision_provider;
    const auto floor = make_box({-256, -192, -16}, {256, 192, 0});
    assert((floor.origin == point{0, 0, -8}));
    assert((floor.half == point{256, 192, 8}));
    std::array<bool, 8> corners{};
    for (const auto& v : floor.vertices)
    {
        assert(std::abs(v.x) == 8 && std::abs(v.y) == 6 && std::abs(v.z) == 0.25f && v.w == 0);
        const auto index = (v.x > 0 ? 1 : 0) | (v.y > 0 ? 2 : 0) | (v.z > 0 ? 4 : 0);
        assert(!corners[index]);
        corners[index] = true;
        assert(floor.origin[0] + 32 * v.x == (v.x < 0 ? floor.minimum[0] : floor.maximum[0]));
        assert(floor.origin[1] + 32 * v.y == (v.y < 0 ? floor.minimum[1] : floor.maximum[1]));
        assert(floor.origin[2] + 32 * v.z == (v.z < 0 ? floor.minimum[2] : floor.maximum[2]));
    }
    for (const auto present : corners) assert(present);
    const auto moved = make_box({744, -1192, 240}, {1256, -808, 256});
    assert((moved.origin == point{1000, -1000, 248}));
    for (std::size_t i = 0; i < 8; ++i)
        assert(moved.vertices[i].x == floor.vertices[i].x && moved.vertices[i].y == floor.vertices[i].y && moved.vertices[i].z == floor.vertices[i].z);

    const auto rejects = [](point a, point b)
    {
        try { (void)make_box(a, b); return false; }
        catch (const std::invalid_argument&) { return true; }
    };
    for (std::size_t axis = 0; axis < 3; ++axis)
    {
        point a{0, 0, 0}, b{1, 1, 1};
        b[axis] = 0; assert(rejects(a, b));
        b[axis] = -1; assert(rejects(a, b));
        b[axis] = std::numeric_limits<float>::infinity(); assert(rejects(a, b));
        b[axis] = 1; a[axis] = std::numeric_limits<float>::quiet_NaN(); assert(rejects(a, b));
    }
    // A wide finite box must avoid overflow in the midpoint computation.
    const auto wide = make_box({-2e38f, -1, -1}, {2e38f, 1, 1});
    assert(wide.origin[0] == 0 && std::isfinite(wide.half[0]));
}
