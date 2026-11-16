#pragma once
// The avoidance solver's polygon clip with no 32 vertex bound (a75). Header only, no engine includes: tests/native/avoidance_clip_test.cpp runs it
// against the shipped function's recorded outputs.
//
// Shipped function FUN_1403E6B10 (poly, cap, count*, plane): Sutherland-Hodgman clip of the convex polygon poly[*count] (12 byte vertices) by ONE half-plane
// {a, b, c, d}: keep the points with b*y + a*x + c*z > d. For vertex i the edge to vertex (i + 1) % n emits the intersection when the two signed distances
// differ strictly in sign, then the end vertex when it is inside. The result goes into a 32 vertex local array under the stack cookie (the `cap` argument,
// 0x20, is never read) and is copied back, `*count` rewritten, only when it is not empty. Returns 1 when the result is not empty, 0 otherwise (poly and
// count untouched).
// The solver (FUN_1403E61B0) starts at 4 box corners and clips once per obstacle, so it needs 4 + obstacles vertices; stock has 24 + 4 + 4 sentients =
// 32 exactly. With a raised agent capacity (parked records at the origin, or a really dense crowd) the 33rd vertex ended on the cookie.
//
// Here the output goes to a workspace of the real maximum. Up to 32 vertices the caller's buffer holds the polygon exactly as the shipped function left it. Past 32
// the workspace holds the polygon (authoritative), the caller's buffer the first 32 vertices (memory safe) and `*count` the true count; a call with count > 32
// continues from the workspace when it is the polygon of that buffer with that count (a fresh polygon always starts at 4), and the consumer of the polygon
// (FUN_1403E51C0) is given the workspace through `view`. Nothing is dropped below `max_vertices`; above it the result is cut (never memory unsafe) and counted.
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

#ifdef _MSC_VER
#pragma float_control(precise, on, push)
#pragma fp_contract(off)
#endif

namespace avoidance {

constexpr int stock_vertices = 32;

struct stats {
    std::atomic<std::uint64_t> calls{};
    std::atomic<std::uint64_t> over_stock{};        // clips whose result passed 32 vertices (the shipped function would have overrun its array)
    std::atomic<std::uint64_t> truncated{};         // results cut at max_vertices
    std::atomic<std::uint64_t> inconsistent{};      // a call with count > 32 that is not the workspace's polygon (clamped to 32)
    std::atomic<std::uint32_t> max_vertices{};      // the largest result seen
    std::atomic<std::uint32_t> max_input{};         // the largest input polygon seen
    void note(std::uint32_t input, std::uint32_t result) {
        if (input > max_input.load(std::memory_order_relaxed)) max_input.store(input, std::memory_order_relaxed);
        if (result > max_vertices.load(std::memory_order_relaxed)) max_vertices.store(result, std::memory_order_relaxed);
    }
};

// FUN_1403E6A10: the point where the edge a -> b crosses the plane, when the signed distances strictly differ in sign
inline bool cross(const float* a, const float* b, const float* plane, float* out) {
    const float da = (plane[0] * a[0] + plane[1] * a[1] + plane[2] * a[2]) - plane[3];
    const float db = (b[0] * plane[0] + plane[1] * b[1] + plane[2] * b[2]) - plane[3];
    if (0.0f <= db * da) return false;
    const float t = da / (da - db);
    out[0] = (b[0] - a[0]) * t + a[0];
    out[1] = (b[1] - a[1]) * t + a[1];
    out[2] = (b[2] - a[2]) * t + a[2];
    return true;
}

class workspace {
public:
    // max_vertices: the most a polygon may hold (4 + clips). The scratch holds twice that: one clip emits at most two vertices an input vertex.
    explicit workspace(std::uint32_t max_vertices) : max_(max_vertices < stock_vertices ? stock_vertices : max_vertices),
        polygon_(3 * static_cast<std::size_t>(max_)), scratch_(6 * static_cast<std::size_t>(max_) + 6) {}
    std::uint32_t max_vertices() const { return max_; }

    // The shipped contract. `poly` is the caller's 32 vertex buffer.
    char clip(stats& st, float* poly, int* count, const float* plane) {
        int n = *count;
        if (n <= 0) return 0;
        const float* in = poly;
        if (n > stock_vertices) {
            if (big_ && owner_ == poly && big_count_ == n) in = polygon_.data();
            else { n = stock_vertices; st.inconsistent.fetch_add(1, std::memory_order_relaxed); }     // not ours: clamp, stay inside the buffer
        }
        st.calls.fetch_add(1, std::memory_order_relaxed);
        const float a = plane[0], b = plane[1], c = plane[2], d = plane[3];
        float* out = scratch_.data();
        std::uint32_t m = 0;
        for (int i = 0; i < n; ++i) {
            const float* p = in + 3 * static_cast<std::size_t>(i);
            const float* q = in + 3 * static_cast<std::size_t>((i + 1) % n);
            if (cross(p, q, plane, out + 3 * static_cast<std::size_t>(m))) ++m;
            if (d < b * q[1] + a * q[0] + c * q[2]) {
                float* o = out + 3 * static_cast<std::size_t>(m);
                o[0] = q[0]; o[1] = q[1]; o[2] = q[2];
                ++m;
            }
        }
        st.note(static_cast<std::uint32_t>(n), m);
        if (m == 0) return 0;
        if (m > static_cast<std::uint32_t>(stock_vertices)) st.over_stock.fetch_add(1, std::memory_order_relaxed);
        if (m > max_) { m = max_; st.truncated.fetch_add(1, std::memory_order_relaxed); }
        *count = static_cast<int>(m);
        if (m <= static_cast<std::uint32_t>(stock_vertices)) {
            std::memcpy(poly, out, 12u * m);
            big_ = false;
        } else {
            std::memcpy(polygon_.data(), out, 12u * m);                  // the workspace polygon is not `in` any more: out is a separate array
            std::memcpy(poly, out, 12u * stock_vertices);
            big_ = true; owner_ = poly; big_count_ = static_cast<int>(m);
        }
        return 1;
    }

    // The polygon a consumer of (poly, count) must read: `poly` itself up to 32 vertices, the workspace's copy for the polygon of that buffer past it,
    // nullptr when count > 32 and the workspace does not hold that polygon.
    const float* view(const float* poly, int count) const {
        if (count <= stock_vertices) return poly;
        return (big_ && owner_ == poly && big_count_ == count) ? polygon_.data() : nullptr;
    }

private:
    std::uint32_t max_;
    std::vector<float> polygon_, scratch_;
    const float* owner_ = nullptr;
    int big_count_ = 0;
    bool big_ = false;
};

}  // namespace avoidance

#ifdef _MSC_VER
#pragma float_control(pop)
#endif
