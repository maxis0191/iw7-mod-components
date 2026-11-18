#pragma once

// Render meter (-paris-render-meter, a90): the one owner of the detour on the scene-end function FUN_140E328E0, shared with the
// performance recorder (paris_perf.cpp). A second detour on the same address cannot exist, so the recorder subscribes a function here
// instead of creating its own hook.
namespace paris_render_meter
{
    using scene_end_callback = void (*)();
    // Runs the callback after the stock function, on the thread that built the scene, once a scene. Installs the hook when it is not
    // there yet. Returns false when the first bytes of the function are not the expected ones (nothing is hooked then).
    bool subscribe_scene_end(scene_end_callback callback);
}
