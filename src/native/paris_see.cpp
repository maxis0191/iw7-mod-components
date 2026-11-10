#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include "directx.hpp"
#include "paris_debugger.hpp"
#include <utils/flags.hpp>
#include <utils/io.hpp>
#include <d3d11.h>
#include <wrl/client.h>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>

// Frame facts for isolated lab clients (-paris-isolated-lab, a client built with the debugger switch). With every frame
// capture it writes the exact camera of that frame, and on request the engine's own depth buffer of the same present,
// so that tools can answer "what is at this pixel" from numbers (ops/engine-map/iw7_see.py, docs/SEE.md).
//
//   capture_frame <name>       replaced in a lab client: the same colour frame (iw7-mod/screenshots/<name>.bmp), plus
//                              iw7-mod/paris-perf/see-<name>.json (schema iw7.see-camera/1)
//   paris_see_depth [all]      arm the next capture: also write the depth buffer as iw7-mod/screenshots/<name>__z.bmp
//                              (32-bit top-down BMP whose 4 bytes per pixel are one float: the raw device depth).
//                              "all" writes every depth candidate as <name>__z<k>.bmp (to find the right one)
//   paris_see_target <text>    choose the depth target by a part of its name ("auto" = the default choice)
//   paris_see_targets          write iw7-mod/paris-perf/see-targets.json: every engine render target (name, size, format)
//
// The colour copy, the depth copy and the camera read all happen in one present callback on the renderer thread, under
// the engine's render mutex, so the three belong to the same presented frame. The camera is also read when the capture
// is asked (main thread); a tool can see whether it moved in between. Nothing runs when no capture is pending except one
// atomic load per present.
namespace paris_see
{
    namespace
    {
        using Microsoft::WRL::ComPtr;

        constexpr std::uintptr_t render_target_pool = 0x149B3F248; // GfxImage of entry 0; entries are 288 bytes
        constexpr int render_target_count = 2048;
        constexpr std::size_t render_target_stride = 288;
        constexpr const char* camera_directory = "iw7-mod/paris-perf";
        constexpr const char* frame_directory = "iw7-mod/screenshots";

        struct camera
        {
            float tan_half_fov[2]{};
            float origin[3]{};
            float axis[9]{};
            float z_near{};
            float unknown[2]{};
            unsigned viewport[4]{};
            float view_offset[3]{};
        };

        struct probe
        {
            float world[3]{};
            float screen[2]{};
            int ok{};
        };

        struct request
        {
            std::string name;
            int depth{}; // 0 none, 1 the chosen target, 2 every candidate
            camera at_request{};
            probe probes[3]{};
            int probe_count{};
            LARGE_INTEGER asked{};
            std::uint64_t asked_present{};
        };

        struct target
        {
            int index{};
            std::string name;
            unsigned image_format{};
            D3D11_TEXTURE2D_DESC desc{};
            ID3D11Texture2D* texture{};
        };

        std::atomic<bool> pending{false};
        std::atomic<bool> want_targets{false};
        std::atomic<int> armed_depth{0};
        std::atomic<std::uint64_t> presents{0};
        std::mutex state_mutex;
        request current;
        std::string forced_target;

        bool readable(const void* pointer, const std::size_t size)
        {
            if (!pointer) return false;
            MEMORY_BASIC_INFORMATION info{};
            if (!VirtualQuery(pointer, &info, sizeof(info))) return false;
            if (info.State != MEM_COMMIT || (info.Protect & (PAGE_NOACCESS | PAGE_GUARD))) return false;
            const auto end = reinterpret_cast<std::uintptr_t>(info.BaseAddress) + info.RegionSize;
            return reinterpret_cast<std::uintptr_t>(pointer) + size <= end;
        }

        camera read_camera()
        {
            camera c{};
            const auto* cg = game::cg.get();
            const auto& r = cg->refdef;
            c.tan_half_fov[0] = r.view.tanHalfFovX;
            c.tan_half_fov[1] = r.view.tanHalfFovY;
            std::memcpy(c.origin, r.view.org, sizeof(c.origin));
            std::memcpy(c.axis, r.view.axis, sizeof(c.axis));
            c.z_near = r.view.zNear;
            c.unknown[0] = r.view.unk[0];
            c.unknown[1] = r.view.unk[1];
            c.viewport[0] = r.displayViewport.x;
            c.viewport[1] = r.displayViewport.y;
            c.viewport[2] = r.displayViewport.width;
            c.viewport[3] = r.displayViewport.height;
            std::memcpy(c.view_offset, r.viewOffset, sizeof(c.view_offset));
            return c;
        }

        double number(const float value) { return std::isfinite(value) ? static_cast<double>(value) : 0.0; }

        void append(std::string& out, const char* format, ...)
        {
            char buffer[1024];
            va_list args;
            va_start(args, format);
            _vsnprintf_s(buffer, sizeof(buffer), _TRUNCATE, format, args);
            va_end(args);
            out += buffer;
        }

        void append_camera(std::string& out, const char* key, const camera& c)
        {
            append(out, "\"%s\":{\"tan_half_fov\":[%.9g,%.9g],\"origin\":[%.9g,%.9g,%.9g],", key, number(c.tan_half_fov[0]), number(c.tan_half_fov[1]),
                number(c.origin[0]), number(c.origin[1]), number(c.origin[2]));
            append(out, "\"axis\":[[%.9g,%.9g,%.9g],[%.9g,%.9g,%.9g],[%.9g,%.9g,%.9g]],", number(c.axis[0]), number(c.axis[1]), number(c.axis[2]),
                number(c.axis[3]), number(c.axis[4]), number(c.axis[5]), number(c.axis[6]), number(c.axis[7]), number(c.axis[8]));
            append(out, "\"z_near\":%.9g,\"unknown\":[%.9g,%.9g],\"viewport\":[%u,%u,%u,%u],\"view_offset\":[%.9g,%.9g,%.9g]}", number(c.z_near),
                number(c.unknown[0]), number(c.unknown[1]), c.viewport[0], c.viewport[1], c.viewport[2], c.viewport[3], number(c.view_offset[0]),
                number(c.view_offset[1]), number(c.view_offset[2]));
        }

        void append_name(std::string& out, const std::string& text)
        {
            for (const auto raw : text)
            {
                const auto c = static_cast<unsigned char>(raw);
                if (c == '"' || c == '\\') { out += '\\'; out += raw; }
                else if (c < 0x20 || c >= 0x7F) out += '?';
                else out += raw;
            }
        }

        // Every engine render target that is a plain 2D texture. Renderer thread only.
        std::vector<target> list_targets()
        {
            std::vector<target> out;
            for (int i = 0; i < render_target_count; ++i)
            {
                const auto* image = reinterpret_cast<const game::GfxImage*>(render_target_pool + render_target_stride * i);
                if (!image->name || !image->texture.map) continue;
                if (!readable(image->name, 1) || !readable(image->texture.map, sizeof(void*))) continue;
                auto* resource = reinterpret_cast<ID3D11Resource*>(image->texture.map);
                D3D11_RESOURCE_DIMENSION dimension{};
                resource->GetType(&dimension);
                if (dimension != D3D11_RESOURCE_DIMENSION_TEXTURE2D) continue;
                target t;
                t.index = i;
                t.name.assign(image->name, strnlen(image->name, 96));
                t.image_format = static_cast<unsigned>(image->imageFormat);
                t.texture = static_cast<ID3D11Texture2D*>(resource);
                t.texture->GetDesc(&t.desc);
                out.push_back(std::move(t));
            }
            return out;
        }

        int bytes_per_pixel(const DXGI_FORMAT format)
        {
            switch (format)
            {
            case DXGI_FORMAT_R32_TYPELESS: case DXGI_FORMAT_D32_FLOAT: case DXGI_FORMAT_R32_FLOAT: return 4;
            case DXGI_FORMAT_R32G8X24_TYPELESS: case DXGI_FORMAT_D32_FLOAT_S8X24_UINT: case DXGI_FORMAT_R32_FLOAT_X8X24_TYPELESS: return 8;
            case DXGI_FORMAT_R24G8_TYPELESS: case DXGI_FORMAT_D24_UNORM_S8_UINT: case DXGI_FORMAT_R24_UNORM_X8_TYPELESS: return 4;
            case DXGI_FORMAT_R16_TYPELESS: case DXGI_FORMAT_D16_UNORM: case DXGI_FORMAT_R16_UNORM: return 2;
            default: return 0;
            }
        }

        float decode(const unsigned char* pixel, const DXGI_FORMAT format)
        {
            switch (format)
            {
            case DXGI_FORMAT_R24G8_TYPELESS: case DXGI_FORMAT_D24_UNORM_S8_UINT: case DXGI_FORMAT_R24_UNORM_X8_TYPELESS:
            {
                std::uint32_t v; std::memcpy(&v, pixel, 4);
                return static_cast<float>(v & 0xFFFFFF) / 16777215.0f;
            }
            case DXGI_FORMAT_R16_TYPELESS: case DXGI_FORMAT_D16_UNORM: case DXGI_FORMAT_R16_UNORM:
            {
                std::uint16_t v; std::memcpy(&v, pixel, 2);
                return static_cast<float>(v) / 65535.0f;
            }
            default:
            {
                float v; std::memcpy(&v, pixel, 4);
                return v;
            }
            }
        }

        bool is_depth_candidate(const target& t)
        {
            return (t.desc.BindFlags & D3D11_BIND_DEPTH_STENCIL) && t.desc.SampleDesc.Count == 1 && t.desc.ArraySize == 1 && bytes_per_pixel(t.desc.Format) != 0;
        }

        void write_bmp_header(std::string& bytes, const unsigned width, const unsigned height)
        {
            BITMAPFILEHEADER file{};
            BITMAPINFOHEADER info{};
            file.bfType = 0x4D42;
            file.bfOffBits = sizeof(file) + sizeof(info);
            file.bfSize = file.bfOffBits + width * height * 4;
            info.biSize = sizeof(info);
            info.biWidth = static_cast<LONG>(width);
            info.biHeight = -static_cast<LONG>(height);
            info.biPlanes = 1;
            info.biBitCount = 32;
            info.biCompression = BI_RGB;
            bytes.assign(file.bfSize, '\0');
            std::memcpy(bytes.data(), &file, sizeof(file));
            std::memcpy(bytes.data() + sizeof(file), &info, sizeof(info));
        }

        // The depth texture as one float per pixel inside a 32-bit BMP. Fills the facts of the JSON row.
        bool write_depth(const target& t, const std::string& file, std::string& row)
        {
            auto desc = t.desc;
            desc.Usage = D3D11_USAGE_STAGING;
            desc.BindFlags = 0;
            desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            desc.MiscFlags = 0;
            ComPtr<ID3D11Texture2D> staging;
            if (FAILED(dx::device->CreateTexture2D(&desc, nullptr, &staging))) return false;
            dx::deviceContext->CopyResource(staging.Get(), t.texture);
            D3D11_MAPPED_SUBRESOURCE mapped{};
            if (FAILED(dx::deviceContext->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) return false;
            const int step = bytes_per_pixel(desc.Format);
            std::string bytes;
            write_bmp_header(bytes, desc.Width, desc.Height);
            auto* output = reinterpret_cast<float*>(bytes.data() + sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER));
            float lowest = 1e30f, highest = -1e30f;
            std::uint64_t zeros = 0, ones = 0;
            for (UINT y = 0; y < desc.Height; ++y)
            {
                const auto* line = static_cast<const unsigned char*>(mapped.pData) + static_cast<std::size_t>(y) * mapped.RowPitch;
                for (UINT x = 0; x < desc.Width; ++x)
                {
                    const float v = decode(line + static_cast<std::size_t>(x) * step, desc.Format);
                    output[static_cast<std::size_t>(y) * desc.Width + x] = v;
                    if (v == 0.0f) ++zeros;
                    else if (v == 1.0f) ++ones;
                    if (v < lowest) lowest = v;
                    if (v > highest) highest = v;
                }
            }
            dx::deviceContext->Unmap(staging.Get(), 0);
            if (!utils::io::write_file(std::string(frame_directory) + "/" + file, bytes)) return false;
            append(row, "{\"file\":\"%s\",\"target\":\"", file.c_str());
            append_name(row, t.name);
            append(row, "\",\"index\":%d,\"width\":%u,\"height\":%u,\"dxgi_format\":%u,\"image_format\":%u,\"min\":%.9g,\"max\":%.9g,\"zeros\":%llu,\"ones\":%llu,\"bytes\":%zu}",
                t.index, desc.Width, desc.Height, static_cast<unsigned>(desc.Format), t.image_format, number(lowest), number(highest), zeros, ones, bytes.size());
            return true;
        }

        // The back buffer as a 32-bit BMP, the file the game's own capture_frame writes.
        bool write_colour(IDXGISwapChain* swap_chain, const std::string& name, unsigned& width, unsigned& height, unsigned& format, const char*& why)
        {
            ComPtr<ID3D11Texture2D> source;
            if (FAILED(swap_chain->GetBuffer(0, IID_PPV_ARGS(&source)))) { why = "swap chain back buffer unavailable"; return false; }
            D3D11_TEXTURE2D_DESC desc{};
            source->GetDesc(&desc);
            width = desc.Width; height = desc.Height; format = static_cast<unsigned>(desc.Format);
            const bool rgba = desc.Format == DXGI_FORMAT_R8G8B8A8_UNORM || desc.Format == DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
            const bool bgra = desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM || desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
            if (!rgba && !bgra) { why = "unsupported back buffer format"; return false; }
            if (!desc.Width || !desc.Height || desc.Width > 8192 || desc.Height > 8192 || desc.ArraySize != 1) { why = "unsupported back buffer size"; return false; }
            auto copy = desc;
            copy.MipLevels = 1;
            copy.SampleDesc = {1, 0};
            copy.Usage = D3D11_USAGE_STAGING;
            copy.BindFlags = 0;
            copy.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            copy.MiscFlags = 0;
            ComPtr<ID3D11Texture2D> staging;
            if (FAILED(dx::device->CreateTexture2D(&copy, nullptr, &staging))) { why = "staging allocation failed"; return false; }
            if (desc.SampleDesc.Count > 1)
            {
                auto resolve = copy;
                resolve.Usage = D3D11_USAGE_DEFAULT;
                resolve.CPUAccessFlags = 0;
                ComPtr<ID3D11Texture2D> resolved;
                if (FAILED(dx::device->CreateTexture2D(&resolve, nullptr, &resolved))) { why = "resolve allocation failed"; return false; }
                dx::deviceContext->ResolveSubresource(resolved.Get(), 0, source.Get(), 0, desc.Format);
                dx::deviceContext->CopySubresourceRegion(staging.Get(), 0, 0, 0, 0, resolved.Get(), 0, nullptr);
            }
            else dx::deviceContext->CopySubresourceRegion(staging.Get(), 0, 0, 0, 0, source.Get(), 0, nullptr);
            D3D11_MAPPED_SUBRESOURCE mapped{};
            if (FAILED(dx::deviceContext->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) { why = "staging map failed"; return false; }
            std::string bytes;
            write_bmp_header(bytes, desc.Width, desc.Height);
            const auto first = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);
            for (UINT y = 0; y < desc.Height; ++y)
            {
                const auto* line = static_cast<const unsigned char*>(mapped.pData) + static_cast<std::size_t>(y) * mapped.RowPitch;
                auto* output = reinterpret_cast<unsigned char*>(bytes.data() + first + static_cast<std::size_t>(y) * desc.Width * 4);
                for (UINT x = 0; x < desc.Width; ++x)
                {
                    output[x * 4] = line[x * 4 + (rgba ? 2 : 0)];
                    output[x * 4 + 1] = line[x * 4 + 1];
                    output[x * 4 + 2] = line[x * 4 + (rgba ? 0 : 2)];
                    output[x * 4 + 3] = 255;
                }
            }
            dx::deviceContext->Unmap(staging.Get(), 0);
            if (!utils::io::write_file(std::string(frame_directory) + "/" + name + ".bmp", bytes)) { why = "BMP write failed"; return false; }
            return true;
        }

        double milliseconds(const LARGE_INTEGER from, const LARGE_INTEGER to)
        {
            LARGE_INTEGER frequency{};
            QueryPerformanceFrequency(&frequency);
            return static_cast<double>(to.QuadPart - from.QuadPart) * 1000.0 / static_cast<double>(frequency.QuadPart);
        }

        std::string lower(std::string text)
        {
            for (auto& c : text) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            return text;
        }

        void write_targets()
        {
            const auto targets = list_targets();
            std::string out = "{\"schema\":\"iw7.see-targets/1\",\"targets\":[\n";
            bool first = true;
            for (const auto& t : targets)
            {
                append(out, "%s{\"index\":%d,\"name\":\"", first ? "" : ",\n", t.index);
                append_name(out, t.name);
                append(out, "\",\"width\":%u,\"height\":%u,\"dxgi_format\":%u,\"image_format\":%u,\"bind\":%u,\"samples\":%u,\"array\":%u,\"mips\":%u}", t.desc.Width, t.desc.Height,
                    static_cast<unsigned>(t.desc.Format), t.image_format, t.desc.BindFlags, t.desc.SampleDesc.Count, t.desc.ArraySize, t.desc.MipLevels);
                first = false;
            }
            out += "\n]}\n";
            const bool written = utils::io::write_file(std::string(camera_directory) + "/see-targets.json", out);
            console::info("[Paris see] targets=%zu written=%d\n", targets.size(), static_cast<int>(written));
        }

        void capture(IDXGISwapChain* swap_chain)
        {
            request r;
            std::string forced;
            {
                std::lock_guard lock(state_mutex);
                r = current;
                forced = forced_target;
            }
            LARGE_INTEGER t0{}, t1{}, t2{}, t3{};
            QueryPerformanceCounter(&t0);
            const auto at_present = read_camera();
            unsigned width = 0, height = 0, format = 0;
            const char* why = "";
            const bool colour = write_colour(swap_chain, r.name, width, height, format, why);
            QueryPerformanceCounter(&t1);

            std::string depth_rows, candidates;
            int depth_written = 0;
            const auto* vid = game::vidConfig.get();
            if (r.depth)
            {
                const auto targets = list_targets();
                const target* chosen = nullptr;
                int k = 0;
                for (const auto& t : targets)
                {
                    if (!is_depth_candidate(t)) continue;
                    append(candidates, "%s{\"k\":%d,\"index\":%d,\"name\":\"", candidates.empty() ? "" : ",", k, t.index);
                    append_name(candidates, t.name);
                    append(candidates, "\",\"width\":%u,\"height\":%u,\"dxgi_format\":%u}", t.desc.Width, t.desc.Height, static_cast<unsigned>(t.desc.Format));
                    const bool scene_sized = (t.desc.Width == vid->sceneWidth && t.desc.Height == vid->sceneHeight) || (t.desc.Width == width && t.desc.Height == height);
                    if (r.depth == 2)
                    {
                        std::string row;
                        if (write_depth(t, r.name + "__z" + std::to_string(k) + ".bmp", row)) { depth_rows += (depth_written ? "," : "") + row; ++depth_written; }
                    }
                    else if (forced.empty() ? (scene_sized && !chosen) : (lower(t.name).find(forced) != std::string::npos && (!chosen || scene_sized))) chosen = &t;
                    ++k;
                }
                if (r.depth == 1 && chosen)
                {
                    std::string row;
                    if (write_depth(*chosen, r.name + "__z.bmp", row)) { depth_rows = row; depth_written = 1; }
                }
            }
            QueryPerformanceCounter(&t2);

            std::string out = "{\"schema\":\"iw7.see-camera/1\",\"name\":\"";
            append_name(out, r.name);
            append(out, "\",\"frame\":{\"file\":\"%s.bmp\",\"written\":%s,\"width\":%u,\"height\":%u,\"dxgi_format\":%u},\n", r.name.c_str(), colour ? "true" : "false", width, height, format);
            append(out, "\"scene\":{\"width\":%u,\"height\":%u,\"display_width\":%u,\"display_height\":%u,\"scene_aspect\":%.9g,\"display_aspect\":%.9g},\n", vid->sceneWidth,
                vid->sceneHeight, vid->displayWidth, vid->displayHeight, number(vid->sceneAspectRatio), number(vid->displayAspectRatio));
            append_camera(out, "camera", at_present);
            out += ",\n";
            append_camera(out, "camera_at_request", r.at_request);
            out += ",\n\"probes\":[";
            for (int i = 0; i < r.probe_count; ++i)
                append(out, "%s{\"world\":[%.9g,%.9g,%.9g],\"screen\":[%.9g,%.9g],\"ok\":%d}", i ? "," : "", number(r.probes[i].world[0]), number(r.probes[i].world[1]),
                    number(r.probes[i].world[2]), number(r.probes[i].screen[0]), number(r.probes[i].screen[1]), r.probes[i].ok);
            append(out, "],\n\"depth_asked\":%d,\"depth\":[%s],\n\"depth_candidates\":[%s],\n", r.depth, depth_rows.c_str(), candidates.c_str());
            QueryPerformanceCounter(&t3);
            append(out, "\"presents\":{\"asked\":%llu,\"taken\":%llu},\"ms\":{\"asked_to_present\":%.3f,\"colour\":%.3f,\"depth\":%.3f},\n", r.asked_present, presents.load(),
                milliseconds(r.asked, t0), milliseconds(t0, t1), milliseconds(t1, t2));
            out += "\"conventions\":\"axis rows are forward, left, up in world space; depth files hold the raw device depth as one float per pixel, top row first\"}\n";
            const bool json = utils::io::write_file(std::string(camera_directory) + "/see-" + r.name + ".json", out);
            if (colour) console::info("[capture_frame] Saved %s/%s.bmp (%ux%u, format=%u).\n", frame_directory, r.name.c_str(), width, height, format);
            else console::error("[capture_frame] %s\n", why);
            console::info("[Paris see] frame=%s camera=%d depth=%d colour_ms=%.2f depth_ms=%.2f wait_ms=%.1f\n", r.name.c_str(), static_cast<int>(json), depth_written,
                milliseconds(t0, t1), milliseconds(t1, t2), milliseconds(r.asked, t0));
        }

        // Renderer thread, under the render mutex, at every present.
        void on_present(IDXGISwapChain* swap_chain)
        {
            presents.fetch_add(1, std::memory_order_relaxed);
            if (!pending.load(std::memory_order_acquire) && !want_targets.load(std::memory_order_acquire)) return;
            if (!dx::device || !dx::deviceContext) return;
            try
            {
                if (want_targets.exchange(false)) write_targets();
                if (pending.load(std::memory_order_acquire)) capture(swap_chain);
            }
            catch (...) {}
            pending.store(false, std::memory_order_release);
        }

        void ask(const command::params& args)
        {
            const std::string name = args.size() == 1 ? "frame" : args.get(1);
            if (args.size() > 2 || name.empty() || name.size() > 64 || name.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != std::string::npos)
            {
                console::error("Usage: capture_frame [filename containing letters, digits, _ or -]\n");
                return;
            }
            if (pending.load(std::memory_order_acquire)) { console::error("[capture_frame] Capture already pending.\n"); return; }
            request r;
            r.name = name;
            r.depth = armed_depth.exchange(0);
            r.at_request = read_camera();
            QueryPerformanceCounter(&r.asked);
            r.asked_present = presents.load();
            // The engine's own projection of three points in front of the camera: an independent check of the camera read.
            if (*game::g_world)
            {
                const auto& c = r.at_request;
                const float offsets[3][3] = {{300.0f, 0.0f, 0.0f}, {300.0f, 100.0f, 50.0f}, {500.0f, -150.0f, -80.0f}};
                for (int i = 0; i < 3; ++i)
                {
                    auto& p = r.probes[i];
                    for (int k = 0; k < 3; ++k) p.world[k] = c.origin[k] + offsets[i][0] * c.axis[k] + offsets[i][1] * c.axis[3 + k] + offsets[i][2] * c.axis[6 + k];
                    p.ok = game::CG_WorldPosToScreenPosReal(0, game::ScrPlace_GetActivePlacement(), p.world, p.screen) ? 1 : 0;
                }
                r.probe_count = 3;
            }
            {
                std::lock_guard lock(state_mutex);
                current = std::move(r);
            }
            pending.store(true, std::memory_order_release);
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (game::environment::is_dedi()) return;
            if (!utils::flags::has_flag("paris-isolated-lab")) return;
            paris_debugger::set_present_listener([](IDXGISwapChain* swap_chain) { on_present(swap_chain); });
            // After every component registered its commands: the lab client's capture_frame also writes the camera.
            scheduler::once([]
            {
                command::add("capture_frame", [](const command::params& args) { ask(args); });
            }, scheduler::main);
            command::add("paris_see_depth", [](const command::params& args)
            {
                armed_depth.store(args.size() > 1 && std::strcmp(args.get(1), "all") == 0 ? 2 : 1);
            });
            command::add("paris_see_target", [](const command::params& args)
            {
                std::lock_guard lock(state_mutex);
                forced_target = args.size() > 1 && std::strcmp(args.get(1), "auto") != 0 ? lower(args.get(1)) : std::string();
                console::info("[Paris see] target=%s\n", forced_target.empty() ? "auto" : forced_target.c_str());
            });
            command::add("paris_see_targets", [] { want_targets.store(true); });
            console::info("[Paris see] ready\n");
        }
    };
}

REGISTER_COMPONENT(paris_see::component)
