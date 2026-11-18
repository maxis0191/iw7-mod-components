// The replacement clip as a DLL for ops/engine/avoidance_clip.py compare (millions of cases against the shipped function). Not part of the product.
#include "../../src/native/avoidance_clip.hpp"
extern "C" __declspec(dllexport) int avoidance_clip_ref(float* poly, int* count, const float* plane) {
    static thread_local avoidance::workspace ws(64);
    static avoidance::stats st;
    return ws.clip(st, poly, count, plane);
}
