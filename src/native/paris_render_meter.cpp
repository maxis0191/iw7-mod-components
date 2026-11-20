#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "console/console.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "paris_render_meter.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <utils/io.hpp>
#include <algorithm>
#include <array>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <intrin.h>
#include <dxgi1_4.h>
#include <psapi.h>

// Render meter for isolated lab clients: -paris-render-meter with -paris-isolated-lab (a90, 18 Nov 2026). Built with the Perf switch.
//
// Why: in the owner's playtests with 200 real zombies (16 and 18 Nov) zombies, brutes and parts of the map flicker, and nobody saw it without the owner. The renderer reports
// every pool overflow through one function and no ship build prints it. This meter counts them, reads the pools' high-water marks and records, frame by frame, which
// entities the client processed and which it handed to the renderer, so a flicker is a number the lab can read.
//
// 1. Renderer warnings. FUN_140E4B0B0(id, a, b, c) is the shared "pool full / draw refused" report (150 call sites, ids 0 to 0x9A: the four dynamic model lists 0x9A / 5 / 1 / 2,
//    the skinned cache 0xB, the frame data buffers 0x17, ...). The detour counts calls by id and keeps the last call site and the two first arguments. The template of the id
//    (the table at 0x141BD3440, a .data table of string pointers) is read at run time and written with the row. A throttle inside the function (a cooldown per id) decides
//    only whether the text is formatted; the count here is every call.
// 2. The skinned cache. r_SkinnedCacheSize (default 563,200) vertices of 32 bytes (and 4 bytes of tension data) a frame. FUN_140DDCE40 / FUN_140DDCFA0 / FUN_140DDD0F0 add the
//    demand to atomic counters at [[0x148F73088]+0x18F8] and +0x1900 and refuse (id 0xB) once it passes the size; the counter keeps growing, so its value at the end of the frame
//    (FUN_140E29C50, called by R_IssueRenderCommandsEnd, which also sets the flag DAT_148B9D66C when the demand passes size x r_SkinnedCacheThreshold) is the whole demand. The
//    wrapper of FUN_140E29C50 reads the demand, the size, the flag. A window keeps the mean and the maximum demand, the frames over the size, the frames with the flag.
// 3. Draw continuity. FUN_140E2D9D0 (the draw command of one dynamic model; argument 3 is the entity number, 12 bits in the sort key) and CG_ProcessEntity FUN_1407AA9E0
//    (localClient, entity number) set one bit each per entity in a frame bitmap (2,048 bits). At the end of a scene (FUN_140E328E0) the bitmaps are compared with the last two
//    frames, by class: players (0..17), agents (18..18+capacity-1) and the rest. A "vanish" is an entity drawn in the last frame, processed now, not drawn now; a "hole" is drawn,
//    not drawn, drawn again on three frames in a row; a "snapshot hole" is the same for the processed bit (the entity left the snapshot for one frame).
// 4. The lists (params, lights, draws, draws_other: peak and capacity) and the video memory of this process (DXGI QueryVideoMemoryInfo: budget and use of the local segment).
//
// Output: one JSON row every 10 s and one at exit in iw7-mod/paris-render-meter/render-meter.jsonl (kind config, window, final) and a [RenderMeter] line in the console.
// Every counter is lock free; the rows are made on the thread that finishes the scene.
namespace paris_render_meter
{
    namespace
    {
        constexpr std::uintptr_t scene_end_function = 0x140E328E0;
        constexpr std::uintptr_t warn_function = 0x140E4B0B0;
        constexpr std::uintptr_t draw_function = 0x140E2D9D0;
        constexpr std::uintptr_t render_end_function = 0x140E29C50;
        constexpr std::uintptr_t process_function = 0x1407AA9E0;
        constexpr std::uintptr_t warn_table = 0x141BD3440;
        constexpr std::uintptr_t frame_pointer = 0x148F73088;
        constexpr std::uintptr_t skin_flag = 0x148B9D66C;
        constexpr std::uintptr_t list_counter[4] = {0x149FF3E18, 0x149FFBE1C, 0x14A0B6634, 0x14A002E20};
        constexpr std::uint32_t list_capacity[4] = {1024, 1024, 1024, 512};
        constexpr const char* list_name[4] = {"params", "lights", "draws", "draws_other"};
        constexpr int warn_ids = 256;
        constexpr double window_seconds = 10.0;
        constexpr unsigned entity_words = 32; // 2,048 entities

        std::atomic<bool> enabled{false};
        std::int64_t qpc_hz{};
        std::int64_t start_qpc{};

        std::int64_t now()
        {
            LARGE_INTEGER value{};
            QueryPerformanceCounter(&value);
            return value.QuadPart;
        }

        // ---- scene end hook shared with the recorder ----
        utils::hook::detour scene_end_hook;
        bool scene_hook_created = false;
        scene_end_callback callbacks[4]{};
        std::atomic<int> callback_count{0};
        void scene_end_stub();

        bool ensure_scene_hook()
        {
            if (scene_hook_created) return true;
            static const unsigned char expected[] = {0x48, 0x83, 0xEC, 0x28, 0x8B, 0x05};
            if (std::memcmp(reinterpret_cast<const void*>(scene_end_function), expected, sizeof(expected)) != 0)
            {
                console::error("[RenderMeter] scene end at 0x%llX: code differs from the expected bytes, not hooked\n", static_cast<unsigned long long>(scene_end_function));
                return false;
            }
            scene_end_hook.create(scene_end_function, scene_end_stub);
            scene_hook_created = true;
            return true;
        }

        // ---- renderer warnings ----
        utils::hook::detour warn_hook;
        std::atomic<std::uint32_t> warn_total[warn_ids]{};
        std::atomic<std::uintptr_t> warn_site[warn_ids]{};
        std::atomic<std::uint64_t> warn_arg0[warn_ids]{}, warn_arg1[warn_ids]{};
        std::uint32_t warn_prev[warn_ids]{};
        // warning 0x29 (draw surface list full) names the function and the list (region) it was writing: counted by list
        std::atomic<std::uint32_t> drawsurf_full[32]{};
        std::atomic<std::uint64_t> drawsurf_full_name[32]{};
        void warn_stub(int id, std::uint64_t a, std::uint64_t b, std::uint64_t c)
        {
            if (static_cast<unsigned>(id) < static_cast<unsigned>(warn_ids))
            {
                warn_total[id].fetch_add(1, std::memory_order_relaxed);
                warn_site[id].store(reinterpret_cast<std::uintptr_t>(_ReturnAddress()), std::memory_order_relaxed);
                warn_arg0[id].store(a, std::memory_order_relaxed);
                warn_arg1[id].store(b, std::memory_order_relaxed);
                if (id == 0x29 && b < 32) { drawsurf_full[b].fetch_add(1, std::memory_order_relaxed); drawsurf_full_name[b].store(a, std::memory_order_relaxed); }
            }
            warn_hook.invoke<void>(id, a, b, c);
        }

        // iw7-mod's own renderer component (renderer.cpp) already detours FUN_140E4B0B0 (its stub logs the umbra and static model list warnings), and a second detour on one
        // address is refused with an error box that blocks the main thread of the client (first run of the meter, 18 Nov 2026). The meter therefore hooks what the
        // stock detour jumps to: the first bytes of the warning function are a relative jump (to a relay of the hook library, "jmp [rip+0]" and the absolute address), and the
        // function behind it takes the same four arguments. Done once at the first scene end, when every component has installed its hooks. A warning function that is not
        // detoured by anyone is hooked itself.
        bool warn_hook_tried = false;
        bool resolve_warn_target(std::uintptr_t& target)
        {
            __try
            {
                const auto* p = reinterpret_cast<const std::uint8_t*>(warn_function);
                if (p[0] != 0xE9) { target = warn_function; return std::memcmp(p, "\x48\x8B\xC4\x89\x48\x08\x48\x89\x50\x10", 10) == 0; }
                std::int32_t rel{};
                std::memcpy(&rel, p + 1, 4);
                std::uintptr_t at = warn_function + 5 + static_cast<std::intptr_t>(rel);
                for (int hop = 0; hop < 4; ++hop)
                {
                    const auto* t = reinterpret_cast<const std::uint8_t*>(at);
                    if (t[0] == 0xFF && t[1] == 0x25)
                    {
                        std::int32_t disp{};
                        std::memcpy(&disp, t + 2, 4);
                        at = *reinterpret_cast<const std::uintptr_t*>(at + 6 + static_cast<std::intptr_t>(disp));
                    }
                    else if (t[0] == 0xE9)
                    {
                        std::int32_t r2{};
                        std::memcpy(&r2, t + 1, 4);
                        at = at + 5 + static_cast<std::intptr_t>(r2);
                    }
                    else break;
                }
                target = at;
                return at != 0;
            }
            __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
        }
        void ensure_warn_hook()
        {
            if (warn_hook_tried) return;
            warn_hook_tried = true;
            std::uintptr_t target = 0;
            if (!resolve_warn_target(target))
            {
                console::error("[RenderMeter] warning function at 0x%llX: its first bytes are neither the stock ones nor a jump, warnings are not counted\n", static_cast<unsigned long long>(warn_function));
                return;
            }
            warn_hook.create(target, warn_stub);
            warn_hook.enable();   // a hook created after post_unpack is not always enabled by the queue (runs crowd-before and crowd-skin2 counted nothing)
            console::info("[RenderMeter] warning counter on 0x%llX (%s)\n", static_cast<unsigned long long>(target), target == warn_function ? "the function itself" : "behind the stock detour");
        }

        bool read_text(std::uintptr_t pointer, char* out, std::size_t size)
        {
            if (pointer < 0x140000000ull || pointer > 0x14C000000ull) return false;
            __try
            {
                std::size_t i = 0;
                for (; i + 1 < size; ++i)
                {
                    const char c = *reinterpret_cast<const char*>(pointer + i);
                    if (!c) break;
                    out[i] = (c == '"' || c == '\\' || static_cast<unsigned char>(c) < 32) ? ' ' : c;
                }
                out[i] = 0;
                return true;
            }
            __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
        }
        bool read_ring(std::uintptr_t rec, std::int32_t& entry, std::int32_t& bytes, std::int32_t& slots)
        {
            __try { entry = *reinterpret_cast<const volatile std::int32_t*>(rec + 0x14); bytes = *reinterpret_cast<const volatile std::int32_t*>(rec + 0x20); slots = *reinterpret_cast<const volatile std::int32_t*>(rec + 0x24); return true; }
            __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
        }
std::uintptr_t read_pointer(std::uintptr_t address)
        {
            __try { return *reinterpret_cast<const volatile std::uintptr_t*>(address); }
            __except (EXCEPTION_EXECUTE_HANDLER) { return 0; }
        }

        // ---- draw and entity bitmaps ----
        utils::hook::detour draw_hook, process_hook;
        std::atomic<std::uint64_t> drawn_now[entity_words]{}, processed_now[entity_words]{};
        std::atomic<DWORD> draw_tid{0}, process_tid{0}, scene_tid{0}, render_tid{0};
        std::atomic<std::uint32_t> draw_tid_other{0}, process_tid_other{0};
        std::atomic<std::uint64_t> draw_calls{0}, process_calls{0};
        void draw_stub(void* p1, void* p2, std::uint32_t entity, std::uint32_t p4, void* p5, void* p6, float p7)
        {
            const std::uint32_t n = entity & 0xFFF;
            if (n < entity_words * 64) drawn_now[n >> 6].fetch_or(1ull << (n & 63), std::memory_order_relaxed);
            draw_calls.fetch_add(1, std::memory_order_relaxed);
            const DWORD tid = GetCurrentThreadId();
            DWORD seen = draw_tid.load(std::memory_order_relaxed);
            if (!seen) draw_tid.compare_exchange_strong(seen, tid);
            else if (seen != tid) draw_tid_other.fetch_add(1, std::memory_order_relaxed);
            draw_hook.invoke<void>(p1, p2, entity, p4, p5, p6, p7);
        }
        std::uint64_t process_stub(int local_client, int entity)
        {
            if (local_client == 0 && static_cast<unsigned>(entity) < entity_words * 64)
                processed_now[static_cast<unsigned>(entity) >> 6].fetch_or(1ull << (static_cast<unsigned>(entity) & 63), std::memory_order_relaxed);
            process_calls.fetch_add(1, std::memory_order_relaxed);
            const DWORD tid = GetCurrentThreadId();
            DWORD seen = process_tid.load(std::memory_order_relaxed);
            if (!seen) process_tid.compare_exchange_strong(seen, tid);
            else if (seen != tid) process_tid_other.fetch_add(1, std::memory_order_relaxed);
            return process_hook.invoke<std::uint64_t>(local_client, entity);
        }

        // ---- the skinned cache at the end of the render frame ----
        utils::hook::detour render_end_hook;
        std::atomic<std::uint64_t> skin_frames{0}, skin_demand_sum{0}, skin_demand_max{0}, skin_over_cap{0}, skin_over_flag{0}, skin_tension_max{0}, skin_tension_over{0}, skin_cap_seen{0};
        std::atomic<std::uint64_t> skin_demand_last{0};
        std::atomic<int> skin_reads_failed{0};
        bool read_skin(std::uint32_t& used, std::uint32_t& tension, std::uint32_t& flag)
        {
            __try
            {
                const auto frame = *reinterpret_cast<const volatile std::uintptr_t*>(frame_pointer);
                if (!frame) return false;
                const auto* a = *reinterpret_cast<std::uint32_t* const volatile*>(frame + 0x18F8);
                const auto* b = *reinterpret_cast<std::uint32_t* const volatile*>(frame + 0x1900);
                if (!a || !b) return false;
                used = *a;
                tension = *b;
                flag = *reinterpret_cast<const volatile std::uint8_t*>(skin_flag);
                return true;
            }
            __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
        }
        const game::dvar_t* skin_size_dvar = nullptr;
        const game::dvar_t* skin_threshold_dvar = nullptr;
        const game::dvar_t* skin_compute_dvar = nullptr;
        void find_dvars()
        {
            if (!skin_size_dvar) skin_size_dvar = game::Dvar_FindVar("r_SkinnedCacheSize");
            if (!skin_threshold_dvar) skin_threshold_dvar = game::Dvar_FindVar("r_SkinnedCacheThreshold");
            if (!skin_compute_dvar) skin_compute_dvar = game::Dvar_FindVar("r_useComputeSkinning");
        }
        std::uint32_t skin_cap_now()
        {
            find_dvars();
            return (skin_size_dvar && skin_size_dvar->type == game::DVAR_TYPE_INT) ? static_cast<std::uint32_t>(skin_size_dvar->current.integer) : 0;
        }
        void render_end_stub()
        {
            render_end_hook.invoke<void>();
            std::uint32_t used = 0, tension = 0, flag = 0;
            DWORD tid = render_tid.load(std::memory_order_relaxed);
            if (!tid) render_tid.compare_exchange_strong(tid, GetCurrentThreadId());
            if (!read_skin(used, tension, flag)) { skin_reads_failed.fetch_add(1, std::memory_order_relaxed); return; }
            const std::uint64_t demand = used >> 5;   // 32 byte vertices
            const std::uint64_t tension_units = tension >> 2;
            skin_frames.fetch_add(1, std::memory_order_relaxed);
            skin_demand_sum.fetch_add(demand, std::memory_order_relaxed);
            skin_demand_last.store(demand, std::memory_order_relaxed);
            auto seen = skin_demand_max.load(std::memory_order_relaxed);
            while (demand > seen && !skin_demand_max.compare_exchange_weak(seen, demand)) {}
            seen = skin_tension_max.load(std::memory_order_relaxed);
            while (tension_units > seen && !skin_tension_max.compare_exchange_weak(seen, tension_units)) {}
            const auto cap = skin_cap_seen.load(std::memory_order_relaxed);
            if (cap)
            {
                if (demand > cap) skin_over_cap.fetch_add(1, std::memory_order_relaxed);
                if (tension_units > cap) skin_tension_over.fetch_add(1, std::memory_order_relaxed);
            }
            if (flag & 1) skin_over_flag.fetch_add(1, std::memory_order_relaxed);
        }

        // ---- video memory ----
        struct vram_info { std::uint64_t budget{}, usage{}, available{}, remote_budget{}, remote_usage{}; bool ok{}; };
        IDXGIAdapter3* adapter = nullptr;
        bool adapter_tried = false;
        vram_info read_vram()
        {
            vram_info v;
            if (!adapter_tried)
            {
                adapter_tried = true;
                const HMODULE dxgi = LoadLibraryW(L"dxgi.dll");
                using create_t = HRESULT(WINAPI*)(REFIID, void**);
                const auto create = dxgi ? reinterpret_cast<create_t>(GetProcAddress(dxgi, "CreateDXGIFactory1")) : nullptr;
                IDXGIFactory1* factory = nullptr;
                if (create && SUCCEEDED(create(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&factory))) && factory)
                {
                    SIZE_T best = 0;
                    IDXGIAdapter1* chosen = nullptr;
                    IDXGIAdapter1* candidate = nullptr;
                    for (UINT i = 0; factory->EnumAdapters1(i, &candidate) != DXGI_ERROR_NOT_FOUND; ++i)
                    {
                        DXGI_ADAPTER_DESC1 desc{};
                        candidate->GetDesc1(&desc);
                        if (!(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) && desc.DedicatedVideoMemory >= best)
                        {
                            if (chosen) chosen->Release();
                            chosen = candidate;
                            best = desc.DedicatedVideoMemory;
                        }
                        else candidate->Release();
                    }
                    if (chosen)
                    {
                        chosen->QueryInterface(__uuidof(IDXGIAdapter3), reinterpret_cast<void**>(&adapter));
                        chosen->Release();
                    }
                    factory->Release();
                }
            }
            if (!adapter) return v;
            DXGI_QUERY_VIDEO_MEMORY_INFO local{}, remote{};
            if (SUCCEEDED(adapter->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &local)))
            {
                v.budget = local.Budget; v.usage = local.CurrentUsage; v.available = local.AvailableForReservation; v.ok = true;
            }
            if (SUCCEEDED(adapter->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, &remote)))
            {
                v.remote_budget = remote.Budget; v.remote_usage = remote.CurrentUsage;
            }
            return v;
        }

        // ---- the window ----
        struct class_sum
        {
            std::uint64_t drawn{}, processed{}, unseen{}, vanish{}, hole{}, snapshot_hole{}, vanish_max{}, hole_max{}, drawn_min{~0ull}, drawn_max{}, processed_min{~0ull}, processed_max{};
        };
        class_sum classes[3]; // players, agents, rest
        constexpr const char* class_name[3] = {"players", "agents", "world"};
        std::uint64_t history_drawn[2][entity_words]{}, history_processed[2][entity_words]{};
        std::uint64_t frames_total{}, frames_window{}, lists_sum[4]{}, lists_peak[4]{}, lists_total_peak[4]{};
        std::int64_t window_start_qpc{}, last_scene_qpc{};
        double frame_ms_sum{}, frame_ms_max{};
        std::uint64_t frame_over_50{}, history_frames{};
        std::uint32_t agents_capacity = 24;
        bool config_written = false;
        const std::string output_path = "iw7-mod/paris-render-meter/render-meter.jsonl";
        std::uint64_t final_skin_frames_seen{};

        unsigned agent_lo() { return 18; }
        unsigned agent_hi() { return 18 + agents_capacity; }
        int class_of(unsigned n) { return n < 18 ? 0 : (n < agent_hi() ? 1 : 2); }

        std::string hex(std::uint64_t v)
        {
            char b[32];
            std::snprintf(b, sizeof(b), "0x%llX", static_cast<unsigned long long>(v));
            return b;
        }

        std::string warn_rows()
        {
            std::string out;
            char line[640];
            for (int id = 0; id < warn_ids; ++id)
            {
                const std::uint32_t total = warn_total[id].load(std::memory_order_relaxed);
                if (!total) continue;
                const std::uint32_t delta = total - warn_prev[id];
                warn_prev[id] = total;
                char msg[160] = {};
                const auto pointer = read_pointer(warn_table + static_cast<std::uintptr_t>(id) * 8);
                if (!pointer || !read_text(pointer, msg, sizeof(msg))) msg[0] = 0;
                std::snprintf(line, sizeof(line), "%s{\"id\":%d,\"id_hex\":\"0x%X\",\"total\":%u,\"window\":%u,\"site\":\"0x%llX\",\"a0\":%llu,\"a1\":%llu,\"msg\":\"%s\"}", out.empty() ? "" : ",", id, id, total, delta,
                    static_cast<unsigned long long>(warn_site[id].load(std::memory_order_relaxed)), static_cast<unsigned long long>(warn_arg0[id].load(std::memory_order_relaxed)),
                    static_cast<unsigned long long>(warn_arg1[id].load(std::memory_order_relaxed)), msg);
                out += line;
            }
            return out;
        }

        void write_row(const char* kind)
        {
            find_dvars();
            const auto cap = skin_cap_now();
            if (cap) skin_cap_seen.store(cap, std::memory_order_relaxed);
            const double t = static_cast<double>(now() - start_qpc) / static_cast<double>(qpc_hz);
            const double span = static_cast<double>(now() - window_start_qpc) / static_cast<double>(qpc_hz);
            const auto vram = read_vram();
            const auto skin_n = skin_frames.exchange(0, std::memory_order_relaxed);
            const auto skin_sum = skin_demand_sum.exchange(0, std::memory_order_relaxed);
            const auto skin_max = skin_demand_max.exchange(0, std::memory_order_relaxed);
            const auto skin_over = skin_over_cap.exchange(0, std::memory_order_relaxed);
            const auto skin_flag_n = skin_over_flag.exchange(0, std::memory_order_relaxed);
            const auto tension_max = skin_tension_max.exchange(0, std::memory_order_relaxed);
            const auto tension_over = skin_tension_over.exchange(0, std::memory_order_relaxed);
            const float threshold = (skin_threshold_dvar && skin_threshold_dvar->type == game::DVAR_TYPE_FLOAT) ? skin_threshold_dvar->current.value : -1.0f;
            const int compute = (skin_compute_dvar) ? static_cast<int>(skin_compute_dvar->current.enabled) : -1;
            std::string row;
            char buf[1024];
            std::snprintf(buf, sizeof(buf), "{\"kind\":\"%s\",\"t\":%.2f,\"seconds\":%.2f,\"scenes\":%llu,\"scene_ms_mean\":%.3f,\"scene_ms_max\":%.3f,\"scene_over_50ms\":%llu,\"agents_capacity\":%u,"
                "\"skin\":{\"cap_units\":%u,\"threshold\":%.3f,\"compute\":%d,\"frames\":%llu,\"demand_mean\":%.0f,\"demand_max\":%llu,\"frames_over_cap\":%llu,\"frames_over_threshold_flag\":%llu,\"tension_max\":%llu,\"tension_over\":%llu,\"reads_failed\":%d},",
                kind, t, span, static_cast<unsigned long long>(frames_window), frames_window ? frame_ms_sum / static_cast<double>(frames_window) : 0.0, frame_ms_max, static_cast<unsigned long long>(frame_over_50), agents_capacity,
                cap, threshold, compute, static_cast<unsigned long long>(skin_n), skin_n ? static_cast<double>(skin_sum) / static_cast<double>(skin_n) : 0.0, static_cast<unsigned long long>(skin_max),
                static_cast<unsigned long long>(skin_over), static_cast<unsigned long long>(skin_flag_n), static_cast<unsigned long long>(tension_max), static_cast<unsigned long long>(tension_over), skin_reads_failed.load());
            row += buf;
            row += "\"lists\":{";
            for (int i = 0; i < 4; ++i)
            {
                std::snprintf(buf, sizeof(buf), "%s\"%s\":{\"mean\":%.1f,\"peak\":%llu,\"cap\":%u}", i ? "," : "", list_name[i], frames_window ? static_cast<double>(lists_sum[i]) / static_cast<double>(frames_window) : 0.0,
                    static_cast<unsigned long long>(lists_peak[i]), list_capacity[i]);
                row += buf;
                lists_sum[i] = 0; lists_peak[i] = 0;
            }
            row += "},\"draw\":{";
            const double agents_drawn_mean = frames_window ? static_cast<double>(classes[1].drawn) / static_cast<double>(frames_window) : 0.0;
            const double agents_processed_mean = frames_window ? static_cast<double>(classes[1].processed) / static_cast<double>(frames_window) : 0.0;
            for (int c = 0; c < 3; ++c)
            {
                const auto& k = classes[c];
                const double f = frames_window ? static_cast<double>(frames_window) : 1.0;
                std::snprintf(buf, sizeof(buf), "%s\"%s\":{\"drawn_mean\":%.2f,\"drawn_min\":%llu,\"drawn_max\":%llu,\"processed_mean\":%.2f,\"processed_min\":%llu,\"processed_max\":%llu,\"unseen_mean\":%.2f,\"vanish\":%llu,\"vanish_max_frame\":%llu,\"hole\":%llu,\"hole_max_frame\":%llu,\"snapshot_hole\":%llu}",
                    c ? "," : "", class_name[c], static_cast<double>(k.drawn) / f, static_cast<unsigned long long>(k.drawn_min == ~0ull ? 0 : k.drawn_min), static_cast<unsigned long long>(k.drawn_max),
                    static_cast<double>(k.processed) / f, static_cast<unsigned long long>(k.processed_min == ~0ull ? 0 : k.processed_min), static_cast<unsigned long long>(k.processed_max), static_cast<double>(k.unseen) / f,
                    static_cast<unsigned long long>(k.vanish), static_cast<unsigned long long>(k.vanish_max), static_cast<unsigned long long>(k.hole), static_cast<unsigned long long>(k.hole_max),
                    static_cast<unsigned long long>(k.snapshot_hole));
                row += buf;
                classes[c] = class_sum{};
            }
            std::snprintf(buf, sizeof(buf), "},\"threads\":{\"draw\":%lu,\"draw_other\":%u,\"process\":%lu,\"process_other\":%u,\"scene\":%lu,\"render\":%lu,\"draw_calls\":%llu,\"process_calls\":%llu},",
                draw_tid.load(), draw_tid_other.load(), process_tid.load(), process_tid_other.load(), scene_tid.load(), render_tid.load(),
                static_cast<unsigned long long>(draw_calls.load()), static_cast<unsigned long long>(process_calls.load()));
            row += buf;
            std::snprintf(buf, sizeof(buf), "\"vram\":{\"ok\":%d,\"budget_mb\":%llu,\"usage_mb\":%llu,\"available_mb\":%llu,\"shared_budget_mb\":%llu,\"shared_usage_mb\":%llu},",
                vram.ok ? 1 : 0, static_cast<unsigned long long>(vram.budget >> 20), static_cast<unsigned long long>(vram.usage >> 20), static_cast<unsigned long long>(vram.available >> 20),
                static_cast<unsigned long long>(vram.remote_budget >> 20), static_cast<unsigned long long>(vram.remote_usage >> 20));
            row += buf;
            PROCESS_MEMORY_COUNTERS_EX pmc{};
            pmc.cb = sizeof(pmc);
            GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&pmc), sizeof(pmc));
            std::snprintf(buf, sizeof(buf), "\"process_mb\":{\"working_set\":%llu,\"private\":%llu,\"peak_working_set\":%llu},", static_cast<unsigned long long>(pmc.WorkingSetSize >> 20),
                static_cast<unsigned long long>(pmc.PrivateUsage >> 20), static_cast<unsigned long long>(pmc.PeakWorkingSetSize >> 20));
            row += buf;
            row += "\"rings\":[";
            for (unsigned k = 0, n = 0; k < 64; ++k)
            {
                const auto name_pointer = read_pointer(0x141BD3930ull + 8ull * k);
                char who[48] = {};
                if (!name_pointer || !read_text(name_pointer, who, sizeof(who))) continue;
                const std::uintptr_t rec = 0x14ABC8600ull + 0x80ull * k;
                std::int32_t entry{}, bytes{}, slots{};
                if (!read_ring(rec, entry, bytes, slots)) continue;
                if (bytes <= 0) continue;
                std::snprintf(buf, sizeof(buf), "%s{\"kind\":%u,\"name\":\"%s\",\"entry\":%d,\"bytes\":%d,\"slots\":%d}", n++ ? "," : "", k, who, entry, bytes, slots);
                row += buf;
            }
            row += "],";
            row += "\"drawsurf_full\":[";
            for (unsigned r = 0, k = 0; r < 32; ++r)
            {
                const auto n = drawsurf_full[r].load(std::memory_order_relaxed);
                if (!n) continue;
                char who[64] = {};
                if (!read_text(static_cast<std::uintptr_t>(drawsurf_full_name[r].load(std::memory_order_relaxed)), who, sizeof(who))) who[0] = 0;
                std::snprintf(buf, sizeof(buf), "%s{\"list\":%u,\"total\":%u,\"by\":\"%s\"}", k++ ? "," : "", r, n, who);
                row += buf;
            }
            row += "],";
            row += "\"warnings\":[" + warn_rows() + "]}\n";
            utils::io::write_file(output_path, row, true);
            const std::uint64_t warns_now = [] { std::uint64_t n = 0; for (int i = 0; i < warn_ids; ++i) n += warn_total[i].load(std::memory_order_relaxed); return n; }();
            console::info("[RenderMeter] %s t=%.0f scenes=%llu skin demand mean=%.0f max=%llu cap=%u over_cap=%llu flag=%llu agents drawn=%.1f processed=%.1f vram=%lluMB/%lluMB warnings_total=%llu\n", kind, t,
                static_cast<unsigned long long>(frames_window), skin_n ? static_cast<double>(skin_sum) / static_cast<double>(skin_n) : 0.0, static_cast<unsigned long long>(skin_max), cap,
                static_cast<unsigned long long>(skin_over), static_cast<unsigned long long>(skin_flag_n), agents_drawn_mean, agents_processed_mean, static_cast<unsigned long long>(vram.usage >> 20), static_cast<unsigned long long>(vram.budget >> 20),
                static_cast<unsigned long long>(warns_now));
            frames_window = 0; frame_ms_sum = 0; frame_ms_max = 0; frame_over_50 = 0;
            window_start_qpc = now();
        }

        void write_table()
        {
            // every id the engine has a text for (the table is .data, read here once): the census of what the renderer can report
            std::string row = "{\"kind\":\"warn_table\",\"ids\":[";
            char line[320];
            bool first = true;
            for (int id = 0; id < 0xA0; ++id)
            {
                char msg[200] = {};
                const auto pointer = read_pointer(warn_table + static_cast<std::uintptr_t>(id) * 8);
                if (!pointer || !read_text(pointer, msg, sizeof(msg))) continue;
                std::snprintf(line, sizeof(line), "%s{\"id\":%d,\"msg\":\"%s\"}", first ? "" : ",", id, msg);
                row += line;
                first = false;
            }
            row += "]}\n";
            utils::io::write_file(output_path, row, true);
        }

        void write_config()
        {
            config_written = true;
            write_table();
            char buf[512];
            std::snprintf(buf, sizeof(buf), "{\"kind\":\"config\",\"agents_capacity\":%u,\"window_seconds\":%.0f,\"hooks\":{\"scene_end\":%d,\"warn\":%d,\"draw\":%d,\"process\":%d,\"render_end\":%d}}\n", agents_capacity,
                window_seconds, scene_hook_created ? 1 : 0, 1, 1, 1, 1);
            utils::io::write_file(output_path, buf, true);
        }

        void finish_scene()
        {
            ensure_warn_hook();
            const auto stamp = now();
            if (!scene_tid.load(std::memory_order_relaxed)) scene_tid = GetCurrentThreadId();
            if (last_scene_qpc)
            {
                const double ms = static_cast<double>(stamp - last_scene_qpc) * 1000.0 / static_cast<double>(qpc_hz);
                if (ms < 2000.0) { frame_ms_sum += ms; frame_ms_max = std::max(frame_ms_max, ms); if (ms > 50.0) ++frame_over_50; }
            }
            last_scene_qpc = stamp;
            std::uint64_t drawn[entity_words], processed[entity_words];
            for (unsigned w = 0; w < entity_words; ++w)
            {
                drawn[w] = drawn_now[w].exchange(0, std::memory_order_relaxed);
                processed[w] = processed_now[w].exchange(0, std::memory_order_relaxed);
            }
            std::uint64_t d_count[3]{}, p_count[3]{}, unseen[3]{}, vanish[3]{}, hole[3]{}, shole[3]{};
            const unsigned lo = agent_lo(), hi = agent_hi();
            for (unsigned w = 0; w < entity_words; ++w)
            {
                const std::uint64_t d1 = history_drawn[0][w], d2 = history_drawn[1][w], p1 = history_processed[0][w], p2 = history_processed[1][w];
                const std::uint64_t vanish_bits = d1 & ~drawn[w] & processed[w];
                const std::uint64_t hole_bits = d2 & ~d1 & drawn[w];
                const std::uint64_t shole_bits = p2 & ~p1 & processed[w];
                const std::uint64_t unseen_bits = processed[w] & ~drawn[w];
                for (int c = 0; c < 3; ++c)
                {
                    std::uint64_t mask;
                    const unsigned base = w * 64;
                    // the bits of this word that belong to class c
                    auto range_mask = [&](unsigned from, unsigned to) -> std::uint64_t
                    {
                        if (to <= base || from >= base + 64) return 0;
                        const unsigned a = from > base ? from - base : 0;
                        const unsigned b = to < base + 64 ? to - base : 64;
                        const std::uint64_t upper = b >= 64 ? ~0ull : ((1ull << b) - 1);
                        return upper & ~((1ull << a) - 1);
                    };
                    mask = c == 0 ? range_mask(0, lo) : c == 1 ? range_mask(lo, hi) : range_mask(hi, entity_words * 64);
                    if (!mask) continue;
                    d_count[c] += static_cast<std::uint64_t>(__popcnt64(drawn[w] & mask));
                    p_count[c] += static_cast<std::uint64_t>(__popcnt64(processed[w] & mask));
                    unseen[c] += static_cast<std::uint64_t>(__popcnt64(unseen_bits & mask));
                    vanish[c] += static_cast<std::uint64_t>(__popcnt64(vanish_bits & mask));
                    hole[c] += static_cast<std::uint64_t>(__popcnt64(hole_bits & mask));
                    shole[c] += static_cast<std::uint64_t>(__popcnt64(shole_bits & mask));
                }
                history_drawn[1][w] = d1; history_drawn[0][w] = drawn[w];
                history_processed[1][w] = p1; history_processed[0][w] = processed[w];
            }
            ++history_frames;
            ++frames_total;
            ++frames_window;
            for (int c = 0; c < 3; ++c)
            {
                auto& k = classes[c];
                k.drawn += d_count[c]; k.processed += p_count[c]; k.unseen += unseen[c];
                k.drawn_min = std::min(k.drawn_min, d_count[c]); k.drawn_max = std::max(k.drawn_max, d_count[c]);
                k.processed_min = std::min(k.processed_min, p_count[c]); k.processed_max = std::max(k.processed_max, p_count[c]);
                if (history_frames > 2)
                {
                    k.vanish += vanish[c]; k.hole += hole[c]; k.snapshot_hole += shole[c];
                    k.vanish_max = std::max(k.vanish_max, vanish[c]); k.hole_max = std::max(k.hole_max, hole[c]);
                }
            }
            for (int i = 0; i < 4; ++i)
            {
                const std::uint64_t v = *reinterpret_cast<const volatile std::uint32_t*>(list_counter[i]);
                lists_sum[i] += v; lists_peak[i] = std::max(lists_peak[i], v);
            }
            if (!config_written) write_config();
            if (static_cast<double>(stamp - window_start_qpc) / static_cast<double>(qpc_hz) >= window_seconds) write_row("window");
        }

        void scene_end_stub()
        {
            scene_end_hook.invoke<void>();
            const int n = callback_count.load(std::memory_order_acquire);
            for (int i = 0; i < n; ++i) if (callbacks[i]) callbacks[i]();
        }
    }

    bool subscribe_scene_end(scene_end_callback callback)
    {
        if (!ensure_scene_hook()) return false;
        const int n = callback_count.load();
        if (n >= 4) return false;
        callbacks[n] = callback;
        callback_count.store(n + 1, std::memory_order_release);
        return true;
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (game::environment::is_dedi() || !utils::flags::has_flag("paris-render-meter") || !utils::flags::has_flag("paris-isolated-lab")) return;
            LARGE_INTEGER frequency{};
            QueryPerformanceFrequency(&frequency);
            qpc_hz = frequency.QuadPart;
            start_qpc = window_start_qpc = now();
            int argc = 0;
            if (LPWSTR* args = CommandLineToArgvW(GetCommandLineW(), &argc))
            {
                for (int i = 0; i + 1 < argc; ++i) if (std::wstring(args[i]) == L"-agent-capacity") agents_capacity = static_cast<std::uint32_t>(_wtoi(args[i + 1]));
                LocalFree(args);
            }
            static const unsigned char draw_code[] = {0x40, 0x53, 0x55, 0x56, 0x57, 0x41, 0x54, 0x41, 0x55, 0x48, 0x83, 0xEC, 0x68};
            static const unsigned char render_end_code[] = {0x48, 0x83, 0xEC, 0x28, 0x48, 0x8B, 0x05};
            static const unsigned char process_code[] = {0x48, 0x89, 0x5C, 0x24, 0x10, 0x48, 0x89, 0x6C, 0x24, 0x18, 0x48, 0x89, 0x74, 0x24, 0x20, 0x41, 0x56};
            const auto matches = [](std::uintptr_t at, const unsigned char* code, std::size_t size) { return std::memcmp(reinterpret_cast<const void*>(at), code, size) == 0; };
            if (matches(draw_function, draw_code, sizeof(draw_code))) draw_hook.create(draw_function, draw_stub);
            else console::error("[RenderMeter] draw command at 0x%llX: code differs, drawn entities are not recorded\n", static_cast<unsigned long long>(draw_function));
            if (matches(process_function, process_code, sizeof(process_code))) process_hook.create(process_function, process_stub);
            else console::error("[RenderMeter] CG_ProcessEntity at 0x%llX: code differs, processed entities are not recorded\n", static_cast<unsigned long long>(process_function));
            if (matches(render_end_function, render_end_code, sizeof(render_end_code))) render_end_hook.create(render_end_function, render_end_stub);
            else console::error("[RenderMeter] render end at 0x%llX: code differs, the skinned cache is not read\n", static_cast<unsigned long long>(render_end_function));
            if (ensure_scene_hook()) subscribe_scene_end(finish_scene);
            enabled = true;
            console::info("[RenderMeter] ready agents=%u window=%.0fs output=%s\n", agents_capacity, window_seconds, output_path.c_str());
        }
        void pre_destroy() override
        {
            if (enabled.load()) write_row("final");
        }
    };
}

REGISTER_COMPONENT(paris_render_meter::component)
