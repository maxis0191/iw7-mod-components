#define _CRT_SECURE_NO_WARNINGS
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../../src/native/avoidance_clip.hpp"

// The avoidance polygon clip (a75): byte identical to the shipped function FUN_1403E6B10 for the recorded cases (tests/fixtures/avoidance_clip_stock.b64.txt, made by
// ops/engine/avoidance_clip.py from the shipped code), and a polygon past 32 vertices stays whole, convex, inside every plane, with the caller's buffer written for 32 vertices only.
static int failures;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++failures; } } while (0)

static std::string fixture_path() {
    std::string here = __FILE__;
    const auto cut = here.find_last_of("/\\");
    here = here.substr(0, cut);
    return here + "/../fixtures/avoidance_clip_stock.b64.txt";
}

struct guarded_buffer {                     // the caller's 32 vertex buffer with canaries on both sides
    std::uint32_t before[8];
    float v[96];
    std::uint32_t after[8];
    guarded_buffer() { std::memset(before, 0xA7, sizeof before); std::memset(after, 0xA7, sizeof after); std::memset(v, 0, sizeof v); }
    bool intact() const {
        for (auto b : before) if (b != 0xA7A7A7A7u) return false;
        for (auto a : after) if (a != 0xA7A7A7A7u) return false;
        return true;
    }
};

static std::vector<unsigned char> decode_base64(const std::string& text) {
    std::vector<unsigned char> out;
    unsigned buffer = 0;
    int bits = 0;
    for (const char ch : text) {
        int v;
        if (ch >= 'A' && ch <= 'Z') v = ch - 'A';
        else if (ch >= 'a' && ch <= 'z') v = ch - 'a' + 26;
        else if (ch >= '0' && ch <= '9') v = ch - '0' + 52;
        else if (ch == '+') v = 62;
        else if (ch == '/') v = 63;
        else continue;                       // '=' and line ends
        buffer = (buffer << 6) | static_cast<unsigned>(v);
        bits += 6;
        if (bits >= 8) { bits -= 8; out.push_back(static_cast<unsigned char>((buffer >> bits) & 0xFF)); }
    }
    return out;
}

struct reader {
    const std::vector<unsigned char>& data;
    std::size_t at = 0;
    bool take(void* to, std::size_t bytes) {
        if (at + bytes > data.size()) return false;
        std::memcpy(to, data.data() + at, bytes);
        at += bytes;
        return true;
    }
};

static void recorded_cases() {
    FILE* f = std::fopen(fixture_path().c_str(), "rb");
    if (!f) { std::printf("FAIL: no fixture at %s\n", fixture_path().c_str()); ++failures; return; }
    std::string text;
    char chunk[4096];
    std::size_t got;
    while ((got = std::fread(chunk, 1, sizeof chunk, f)) > 0) text.append(chunk, got);
    std::fclose(f);
    const auto bytes = decode_base64(text);
    reader rd{bytes};
    char magic[4];
    std::uint32_t total{};
    CHECK(rd.take(magic, 4) && std::memcmp(magic, "AVC1", 4) == 0);
    CHECK(rd.take(&total, 4));
    avoidance::workspace ws(64);
    avoidance::stats st;
    std::uint32_t nonempty = 0, mismatches = 0, read = 0;
    for (std::uint32_t k = 0; k < total; ++k) {
        std::uint32_t n{};
        if (!rd.take(&n, 4) || n > 32) break;
        float in[96]{}, plane[4];
        if (!rd.take(in, 12u * n) || !rd.take(plane, 16)) break;
        std::uint32_t ret{}, outn{};
        if (!rd.take(&ret, 4) || !rd.take(&outn, 4) || outn > 32) break;
        float expect[96]{};
        if (outn && !rd.take(expect, 12u * outn)) break;
        ++read;
        guarded_buffer buf;
        std::memcpy(buf.v, in, 12u * n);
        int count = static_cast<int>(n);
        const char r = ws.clip(st, buf.v, &count, plane);
        const bool same = (r != 0) == (ret != 0) &&
            (ret ? (count == static_cast<int>(outn) && std::memcmp(buf.v, expect, 12u * outn) == 0) : (count == static_cast<int>(n) && std::memcmp(buf.v, in, 12u * n) == 0));
        if (!same) ++mismatches;
        if (ret) ++nonempty;
        if (!buf.intact()) ++mismatches;
    }
    std::printf("recorded cases: %u read, %u non-empty, %u mismatches\n", read, nonempty, mismatches);
    CHECK(read == total && read > 5000);
    CHECK(mismatches == 0);
}

// a box clipped by `planes` tangents of a circle: every plane adds a vertex until the box is gone, so the polygon grows to about `planes` vertices
static int tangent_polygon(avoidance::workspace& ws, avoidance::stats& st, guarded_buffer& buf, int planes, float radius, bool& all_ok, std::vector<float>& plane_list) {
    const float r = 299.7f;
    const float box[12] = {-r, -r, 0, r, -r, 0, r, r, 0, -r, r, 0};
    std::memcpy(buf.v, box, sizeof box);
    int count = 4;
    all_ok = true;
    for (int i = 0; i < planes; ++i) {
        const float t = 6.2831853f * static_cast<float>(i) / static_cast<float>(planes);
        const float plane[4] = {-std::cos(t), -std::sin(t), 0.0f, -radius};     // keep dot > d: the inside of the circle's tangent
        plane_list.insert(plane_list.end(), plane, plane + 4);
        if (!ws.clip(st, buf.v, &count, plane)) { all_ok = false; break; }
    }
    return count;
}

static void past_stock() {
    avoidance::workspace ws(512);
    avoidance::stats st;
    guarded_buffer buf;
    bool ok = false;
    std::vector<float> planes;
    const int count = tangent_polygon(ws, st, buf, 90, 100.0f, ok, planes);
    CHECK(ok);
    CHECK(count > 80 && count <= 94);                         // 90 tangents of a circle inside the box: about 90 vertices (more than the 32 of the stock array)
    CHECK(st.over_stock > 0 && st.truncated == 0 && st.inconsistent == 0);
    CHECK(st.max_vertices.load() == static_cast<unsigned>(count));
    CHECK(buf.intact());                                      // the caller's buffer took 32 vertices and not one more
    const float* whole = ws.view(buf.v, count);
    CHECK(whole != nullptr && whole != buf.v);
    CHECK(ws.view(buf.v, count + 1) == nullptr);              // a different count is not that polygon
    CHECK(std::memcmp(whole, buf.v, 12u * 32) == 0);          // the caller sees the first 32 vertices
    // every vertex is inside every plane (within float noise), consecutive vertices differ: nothing was dropped or duplicated
    for (int v = 0; whole && v < count; ++v) {
        for (std::size_t p = 0; p + 3 < planes.size(); p += 4) {
            const float dot = planes[p] * whole[3 * v] + planes[p + 1] * whole[3 * v + 1] + planes[p + 2] * whole[3 * v + 2];
            CHECK(dot >= planes[p + 3] - 0.01f);
        }
        const int w = (v + 1) % count;
        CHECK(whole[3 * v] != whole[3 * w] || whole[3 * v + 1] != whole[3 * w + 1]);
    }
    // the polygon is the tangent polygon of the circle: every vertex at the distance radius / cos(pi / n) from the centre, within 1 percent
    for (int v = 0; whole && v < count; ++v) {
        const float d = std::sqrt(whole[3 * v] * whole[3 * v] + whole[3 * v + 1] * whole[3 * v + 1]);
        CHECK(d >= 99.9f && d <= 101.0f);
    }
}

static void identical_planes() {                              // the a72 case: a box, then the same plane 200 times
    avoidance::workspace ws(512);
    avoidance::stats st;
    guarded_buffer buf;
    const float r = 299.7f, box[12] = {-r, -r, 0, r, -r, 0, r, r, 0, -r, r, 0};
    std::memcpy(buf.v, box, sizeof box);
    int count = 4;
    const float plane[4] = {0.995f, -0.096f, 0.0f, -4.169f};
    for (int i = 0; i < 200; ++i) {
        const char r2 = ws.clip(st, buf.v, &count, plane);
        if (!r2) break;
        CHECK(count <= static_cast<int>(ws.max_vertices()));
        CHECK(buf.intact());
    }
    CHECK(buf.intact());
    CHECK(st.max_vertices.load() <= ws.max_vertices());
}

static void cut_and_clamp() {
    // a workspace of 40 vertices: the 90 tangent polygon is cut at 40 (counted), nothing written out of bounds
    avoidance::workspace small(40);
    avoidance::stats st;
    guarded_buffer buf;
    bool ok = false;
    std::vector<float> planes;
    const int count = tangent_polygon(small, st, buf, 90, 100.0f, ok, planes);
    CHECK(count <= 40);
    CHECK(st.truncated > 0);
    CHECK(buf.intact());
    // a count above 32 that is not the workspace's polygon is clamped to 32 vertices (no read past the buffer), counted
    avoidance::workspace ws(64);
    avoidance::stats st2;
    guarded_buffer b2;
    for (int i = 0; i < 96; ++i) b2.v[i] = static_cast<float>(i % 7);
    int n = 40;
    const float plane[4] = {1, 0, 0, -1000.0f};
    const char r = ws.clip(st2, b2.v, &n, plane);
    CHECK(r == 1 && n == 32 && st2.inconsistent == 1);
    CHECK(b2.intact());
    // a fresh polygon (count 4) after a big one never continues from the workspace
    guarded_buffer b3;
    bool ok3 = false;
    std::vector<float> planes3;
    avoidance::workspace w3(512);
    avoidance::stats st3;
    tangent_polygon(w3, st3, b3, 90, 100.0f, ok3, planes3);
    const float r4 = 50.0f, box[12] = {-r4, -r4, 0, r4, -r4, 0, r4, r4, 0, -r4, r4, 0};
    std::memcpy(b3.v, box, sizeof box);
    int c3 = 4;
    const float p3[4] = {1.0f, 0.0f, 0.0f, 0.0f};
    CHECK(w3.clip(st3, b3.v, &c3, p3) == 1 && c3 == 4);
    CHECK(w3.view(b3.v, 4) == b3.v);
    CHECK(b3.v[0] == 0.0f || b3.v[3] == 0.0f);                // clipped at x = 0: the left corners moved to the plane
}

static void empty_and_zero() {
    avoidance::workspace ws(64);
    avoidance::stats st;
    guarded_buffer buf;
    int zero = 0;
    const float plane[4] = {1, 0, 0, 0};
    CHECK(ws.clip(st, buf.v, &zero, plane) == 0 && zero == 0);
    const float tri[9] = {-1, -1, 0, 1, -1, 0, 0, 1, 0};
    std::memcpy(buf.v, tri, sizeof tri);
    int three = 3;
    const float far_plane[4] = {1, 0, 0, 100.0f};              // everything is outside: empty, polygon and count unchanged
    CHECK(ws.clip(st, buf.v, &three, far_plane) == 0 && three == 3 && std::memcmp(buf.v, tri, sizeof tri) == 0);
}

int main() {
    recorded_cases();
    past_stock();
    identical_planes();
    cut_and_clamp();
    empty_and_zero();
    if (failures) { std::printf("avoidance_clip_test: %d failure(s)\n", failures); return 1; }
    std::printf("avoidance_clip_test passed\n");
    return 0;
}
