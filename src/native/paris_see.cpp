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
// capture it records the exact camera of that frame, and on request the engine's own depth buffer of the same present,
// so that tools can answer "what is at this pixel" from numbers (the creator SDK's iw7_see.py; docs/SEE.md).
//
//   capture_frame <name>       replaced in a lab client: the same colour frame (iw7-mod/screenshots/<name>.bmp), plus
//                              iw7-mod/paris-perf/see-<name>.json (schema iw7.see-camera/2). When both are written the
//                              dvar paris_see_done holds <name>, so a script can wait for the frame
//   paris_see_depth            arm the next capture: also write the depth buffer as iw7-mod/screenshots/<name>__z.bmp
//                              (32-bit top-down BMP whose 4 bytes per pixel are one float: the raw device depth)
//   paris_see_target <text>    choose the depth target by a part of its name ("auto" = the default, "Frontend Depth")
//   paris_see_targets          write iw7-mod/paris-perf/see-targets.json: every engine render target (name, size, format)
//   paris_see_listen 0|1       measurement switch: take the present listener away and put it back
//
// The camera. The engine keeps the view of a frame in its client globals, and the pointer to those is stored encrypted
// (the engine decrypts it inline wherever it is used), so the view cannot be read as a structure. It is recorded
// instead through the engine's own projection routine, CG_WorldPosToScreenPosReal: a few hundred world points and the
// screen position the engine gives each of them. Those pairs determine the camera (position, axes, field of view)
// exactly; the tool solves it. The points are taken on the main thread when the capture is asked and again right after
// the frame was taken, so a tool can see whether the camera moved in between.
//
// The colour copy and the depth copy happen in one present callback on the renderer thread, under the engine's render
// mutex. Nothing runs when no capture is pending except one atomic increment and two atomic loads per present, and one
// atomic load per main-thread frame.
namespace paris_see
{
    namespace
    {
        using Microsoft::WRL::ComPtr;

        constexpr std::uintptr_t render_target_pool = 0x149B3F248; // GfxImage of entry 0; entries are 288 bytes
        constexpr int render_target_count = 2048;
        constexpr std::size_t render_target_stride = 288;
        constexpr const char* default_depth_target = "frontend depth";
        constexpr const char* camera_directory = "iw7-mod/paris-perf";
        constexpr const char* frame_directory = "iw7-mod/screenshots";
        constexpr std::size_t max_probes = 320;

        struct request
        {
            std::string name;
            int depth{};                   // 0 none, 1 the depth target
            std::vector<float> probes;     // x, y, z, screen x, screen y: the engine's projection when the capture was asked
            LARGE_INTEGER asked{};
            std::uint64_t asked_present{};
        };

        struct outcome
        {
            bool colour{};
            unsigned width{}, height{}, format{};
            std::string why;
            std::string depth_row;         // JSON object of the depth file, or empty
            std::string candidates;        // JSON objects of the scene-sized depth targets
            double wait_ms{}, colour_ms{}, depth_ms{};
            std::uint64_t taken_present{};
        };

        struct target
        {
            int index{};
            std::string name;
            unsigned image_format{};
            D3D11_TEXTURE2D_DESC desc{};
            ID3D11Texture2D* texture{};
        };

        std::atomic<bool> pending{false};     // a capture was asked and its files are not all written
        std::atomic<bool> taken{false};       // the renderer has copied the frame; the main thread finishes
        std::atomic<bool> want_targets{false};
        std::atomic<int> armed_depth{0};
        std::atomic<std::uint64_t> presents{0};
        std::mutex state_mutex;
        request current;
        outcome result;
        std::string forced_target;
        int depth_index{-1};                  // the pool entry used last time; renderer thread only

        bool readable(const void* pointer, const std::size_t size)
        {
            if (!pointer) return false;
            MEMORY_BASIC_INFORMATION info{};
            if (!VirtualQuery(pointer, &info, sizeof(info))) return false;
            if (info.State != MEM_COMMIT || (info.Protect & (PAGE_NOACCESS | PAGE_GUARD))) return false;
            const auto end = reinterpret_cast<std::uintptr_t>(info.BaseAddress) + info.RegionSize;
            return reinterpret_cast<std::uintptr_t>(pointer) + size <= end;
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

        // ---------------------------------------------------------------- the camera, through the engine's projection
        void probe_lattice(std::vector<float>& out, const float low[3], const float high[3], const int counts[3], float bounds_low[3], float bounds_high[3])
        {
            const auto* placement = game::ScrPlace_GetActivePlacement();
            for (int ix = 0; ix < counts[0]; ++ix)
            {
                for (int iy = 0; iy < counts[1]; ++iy)
                {
                    for (int iz = 0; iz < counts[2]; ++iz)
                    {
                        const int index[3] = {ix, iy, iz};
                        float world[3];
                        for (int k = 0; k < 3; ++k) world[k] = counts[k] > 1 ? low[k] + (high[k] - low[k]) * static_cast<float>(index[k]) / static_cast<float>(counts[k] - 1) : low[k];
                        float screen[2]{};
                        if (!game::CG_WorldPosToScreenPosReal(0, placement, world, screen)) continue;
                        if (!std::isfinite(screen[0]) || !std::isfinite(screen[1])) continue;
                        out.insert(out.end(), {world[0], world[1], world[2], screen[0], screen[1]});
                        for (int k = 0; k < 3; ++k)
                        {
                            if (world[k] < bounds_low[k]) bounds_low[k] = world[k];
                            if (world[k] > bounds_high[k]) bounds_high[k] = world[k];
                        }
                    }
                }
            }
        }

        // World points the engine says are on the screen, with where it puts them. A coarse lattice over the whole map,
        // then a finer one inside the box of the points that were on the screen (so near points are there too). Main thread.
        std::vector<float> take_probes()
        {
            std::vector<float> all;
            if (!*game::g_world) return all;
            const float low[3] = {-16384.0f, -16384.0f, -4096.0f};
            const float high[3] = {16384.0f, 16384.0f, 8192.0f};
            const int coarse[3] = {17, 17, 7};
            float seen_low[3] = {1e30f, 1e30f, 1e30f};
            float seen_high[3] = {-1e30f, -1e30f, -1e30f};
            probe_lattice(all, low, high, coarse, seen_low, seen_high);
            if (all.size() >= 5 * 4)
            {
                // a little inside the box, so the fine points do not repeat the coarse ones
                float fine_low[3], fine_high[3], unused_low[3] = {1e30f, 1e30f, 1e30f}, unused_high[3] = {-1e30f, -1e30f, -1e30f};
                for (int k = 0; k < 3; ++k)
                {
                    const float span = seen_high[k] - seen_low[k];
                    fine_low[k] = seen_low[k] + span * 0.031f + 13.0f;
                    fine_high[k] = seen_high[k] - span * 0.017f - 7.0f;
                }
                const int fine[3] = {13, 13, 9};
                probe_lattice(all, fine_low, fine_high, fine, unused_low, unused_high);
            }
            const std::size_t count = all.size() / 5;
            if (count <= max_probes) return all;
            std::vector<float> kept;
            kept.reserve(max_probes * 5);
            for (std::size_t i = 0; i < max_probes; ++i)
            {
                const std::size_t at = i * count / max_probes;
                kept.insert(kept.end(), all.begin() + static_cast<std::ptrdiff_t>(at * 5), all.begin() + static_cast<std::ptrdiff_t>(at * 5 + 5));
            }
            return kept;
        }

        void append_probes(std::string& out, const char* key, const std::vector<float>& probes)
        {
            out += "\"";
            out += key;
            out += "\":[";
            for (std::size_t i = 0; i + 4 < probes.size(); i += 5)
                append(out, "%s[%.9g,%.9g,%.9g,%.9g,%.9g]", i ? "," : "", number(probes[i]), number(probes[i + 1]), number(probes[i + 2]), number(probes[i + 3]), number(probes[i + 4]));
            out += "]";
        }

        // ---------------------------------------------------------------- render targets
        bool read_target(const int index, target& t)
        {
            const auto* image = reinterpret_cast<const game::GfxImage*>(render_target_pool + render_target_stride * index);
            if (!image->name || !image->texture.map) return false;
            if (!readable(image->name, 1) || !readable(image->texture.map, sizeof(void*))) return false;
            auto* resource = reinterpret_cast<ID3D11Resource*>(image->texture.map);
            D3D11_RESOURCE_DIMENSION dimension{};
            resource->GetType(&dimension);
            if (dimension != D3D11_RESOURCE_DIMENSION_TEXTURE2D) return false;
            t.index = index;
            t.name.assign(image->name, strnlen(image->name, 96));
            t.image_format = static_cast<unsigned>(image->imageFormat);
            t.texture = static_cast<ID3D11Texture2D*>(resource);
            t.texture->GetDesc(&t.desc);
            return true;
        }

        // Every engine render target that is a plain 2D texture. Renderer thread only. Slow (it asks the system about
        // every entry's memory): used for the listing and the first depth capture, then the entry is remembered.
        std::vector<target> list_targets()
        {
            std::vector<target> out;
            for (int i = 0; i < render_target_count; ++i)
            {
                target t;
                if (read_target(i, t)) out.push_back(std::move(t));
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

        bool is_depth_candidate(const target& t, const unsigned width, const unsigned height)
        {
            if (!(t.desc.BindFlags & D3D11_BIND_DEPTH_STENCIL) || t.desc.SampleDesc.Count != 1 || t.desc.ArraySize != 1 || bytes_per_pixel(t.desc.Format) == 0) return false;
            const auto* vid = game::vidConfig.get();
            return (t.desc.Width == vid->sceneWidth && t.desc.Height == vid->sceneHeight) || (t.desc.Width == width && t.desc.Height == height);
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
            LARGE_INTEGER t0{}, t1{}, t2{}, t3{};
            QueryPerformanceCounter(&t0);
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
            QueryPerformanceCounter(&t1);
            const int step = bytes_per_pixel(desc.Format);
            const bool plain = step == 8 || desc.Format == DXGI_FORMAT_R32_TYPELESS || desc.Format == DXGI_FORMAT_D32_FLOAT || desc.Format == DXGI_FORMAT_R32_FLOAT;
            std::string bytes;
            write_bmp_header(bytes, desc.Width, desc.Height);
            auto* output = reinterpret_cast<float*>(bytes.data() + sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER));
            float lowest = 1e30f, highest = -1e30f;
            std::uint64_t zeros = 0;
            for (UINT y = 0; y < desc.Height; ++y)
            {
                const auto* line = static_cast<const unsigned char*>(mapped.pData) + static_cast<std::size_t>(y) * mapped.RowPitch;
                auto* out_line = output + static_cast<std::size_t>(y) * desc.Width;
                for (UINT x = 0; x < desc.Width; ++x)
                {
                    float v;
                    if (plain) std::memcpy(&v, line + static_cast<std::size_t>(x) * step, 4);
                    else v = decode(line + static_cast<std::size_t>(x) * step, desc.Format);
                    out_line[x] = v;
                    if (v == 0.0f) ++zeros;
                    if (v < lowest) lowest = v;
                    if (v > highest) highest = v;
                }
            }
            dx::deviceContext->Unmap(staging.Get(), 0);
            QueryPerformanceCounter(&t2);
            if (!utils::io::write_file(std::string(frame_directory) + "/" + file, bytes)) return false;
            QueryPerformanceCounter(&t3);
            append(row, "{\"file\":\"%s\",\"target\":\"", file.c_str());
            append_name(row, t.name);
            append(row, "\",\"index\":%d,\"width\":%u,\"height\":%u,\"dxgi_format\":%u,\"image_format\":%u,\"min\":%.9g,\"max\":%.9g,\"zeros\":%llu,\"bytes\":%zu,",
                t.index, desc.Width, desc.Height, static_cast<unsigned>(desc.Format), t.image_format, number(lowest), number(highest), zeros, bytes.size());
            append(row, "\"ms\":{\"copy\":%.3f,\"convert\":%.3f,\"write\":%.3f}}", milliseconds(t0, t1), milliseconds(t1, t2), milliseconds(t2, t3));
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

        // The depth target: the entry used last time when it still fits, else the first scene-sized depth target whose
        // name contains the wanted text (default "Frontend Depth"), else, with no text given, the first scene-sized one.
        bool find_depth_target(const std::string& forced, const unsigned width, const unsigned height, target& chosen, std::string& candidates)
        {
            const std::string wanted = forced.empty() ? default_depth_target : forced;
            if (depth_index >= 0)
            {
                target t;
                if (read_target(depth_index, t) && is_depth_candidate(t, width, height) && lower(t.name).find(wanted) != std::string::npos)
                {
                    chosen = t;
                    return true;
                }
                depth_index = -1;
            }
            bool found = false, have_fallback = false;
            target fallback;
            for (const auto& t : list_targets())
            {
                if (!is_depth_candidate(t, width, height)) continue;
                candidates += candidates.empty() ? "{\"index\":" : ",{\"index\":";
                candidates += std::to_string(t.index) + ",\"name\":\"";
                append_name(candidates, t.name);
                candidates += "\",\"dxgi_format\":" + std::to_string(static_cast<unsigned>(t.desc.Format)) + "}";
                if (!have_fallback) { fallback = t; have_fallback = true; }
                if (!found && lower(t.name).find(wanted) != std::string::npos) { chosen = t; found = true; }
            }
            if (!found && forced.empty() && have_fallback) { chosen = fallback; found = true; }
            if (found) depth_index = chosen.index;
            return found;
        }

        // Renderer thread: copy the picture and, when asked, the depth. The main thread writes the camera file.
        void capture(IDXGISwapChain* swap_chain)
        {
            std::string name, forced;
            int depth = 0;
            LARGE_INTEGER asked{};
            {
                std::lock_guard lock(state_mutex);
                name = current.name;
                depth = current.depth;
                asked = current.asked;
                forced = forced_target;
            }
            outcome o;
            LARGE_INTEGER t0{}, t1{}, t2{};
            QueryPerformanceCounter(&t0);
            const char* why = "";
            o.colour = write_colour(swap_chain, name, o.width, o.height, o.format, why);
            o.why = why;
            QueryPerformanceCounter(&t1);
            if (depth)
            {
                target chosen;
                if (find_depth_target(forced, o.width, o.height, chosen, o.candidates)) write_depth(chosen, name + "__z.bmp", o.depth_row);
            }
            QueryPerformanceCounter(&t2);
            o.wait_ms = milliseconds(asked, t0);
            o.colour_ms = milliseconds(t0, t1);
            o.depth_ms = milliseconds(t1, t2);
            o.taken_present = presents.load();
            {
                std::lock_guard lock(state_mutex);
                result = std::move(o);
            }
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
                if (pending.load(std::memory_order_acquire) && !taken.load(std::memory_order_acquire))
                {
                    capture(swap_chain);
                    taken.store(true, std::memory_order_release);
                }
            }
            catch (...) {}
        }

        // Main thread, every frame: when the renderer has taken the frame, read the camera again, write the camera file
        // and tell scripts the frame is there.
        void finish()
        {
            if (!taken.load(std::memory_order_acquire)) return;
            request r;
            outcome o;
            {
                std::lock_guard lock(state_mutex);
                r = current;
                o = result;
            }
            const auto after = take_probes();
            const auto* vid = game::vidConfig.get();
            std::string out = "{\"schema\":\"iw7.see-camera/2\",\"name\":\"";
            append_name(out, r.name);
            append(out, "\",\"frame\":{\"file\":\"%s.bmp\",\"written\":%s,\"width\":%u,\"height\":%u,\"dxgi_format\":%u},\n", r.name.c_str(), o.colour ? "true" : "false", o.width, o.height, o.format);
            append(out, "\"scene\":{\"width\":%u,\"height\":%u,\"display_width\":%u,\"display_height\":%u,\"scene_aspect\":%.9g,\"display_aspect\":%.9g},\n", vid->sceneWidth,
                vid->sceneHeight, vid->displayWidth, vid->displayHeight, number(vid->sceneAspectRatio), number(vid->displayAspectRatio));
            out += "\"camera\":\"the engine's own projection (CG_WorldPosToScreenPosReal) of world points: [x, y, z, screen x, screen y], in frame pixels\",\n";
            append_probes(out, "projection_at_request", r.probes);
            out += ",\n";
            append_probes(out, "projection_after", after);
            out += ",\n\"depth_asked\":" + std::to_string(r.depth) + ",\"depth\":[" + o.depth_row + "],\n\"depth_candidates\":[" + o.candidates + "],\n";
            append(out, "\"presents\":{\"asked\":%llu,\"taken\":%llu},\"ms\":{\"asked_to_present\":%.3f,\"colour\":%.3f,\"depth\":%.3f},\n", r.asked_present, o.taken_present,
                o.wait_ms, o.colour_ms, o.depth_ms);
            out += "\"conventions\":\"depth files hold the raw device depth as one float per pixel, top row first\"}\n";
            const bool json = utils::io::write_file(std::string(camera_directory) + "/see-" + r.name + ".json", out);
            if (o.colour) console::info("[capture_frame] Saved %s/%s.bmp (%ux%u, format=%u).\n", frame_directory, r.name.c_str(), o.width, o.height, o.format);
            else console::error("[capture_frame] %s\n", o.why.c_str());
            console::info("[Paris see] frame=%s camera=%d points=%zu/%zu depth=%d colour_ms=%.2f depth_ms=%.2f wait_ms=%.1f\n", r.name.c_str(), static_cast<int>(json),
                r.probes.size() / 5, after.size() / 5, static_cast<int>(!o.depth_row.empty()), o.colour_ms, o.depth_ms, o.wait_ms);
            command::execute("set paris_see_done " + r.name, false);
            taken.store(false, std::memory_order_release);
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
            r.probes = take_probes();
            QueryPerformanceCounter(&r.asked);
            r.asked_present = presents.load();
            {
                std::lock_guard lock(state_mutex);
                current = std::move(r);
            }
            taken.store(false, std::memory_order_release);
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
            paris_debugger::set_present_listener(on_present);
            scheduler::loop(finish, scheduler::main);
            // After every component registered its commands: the lab client's capture_frame also records the camera.
            scheduler::once([]
            {
                command::add("capture_frame", [](const command::params& args) { ask(args); });
                command::execute("set paris_see_ready 1", false);
            }, scheduler::main);
            command::add("paris_see_depth", [] { armed_depth.store(1); });
            command::add("paris_see_target", [](const command::params& args)
            {
                std::lock_guard lock(state_mutex);
                forced_target = args.size() > 1 && std::strcmp(args.get(1), "auto") != 0 ? lower(args.get(1)) : std::string();
                console::info("[Paris see] target=%s\n", forced_target.empty() ? "auto" : forced_target.c_str());
            });
            command::add("paris_see_targets", [] { want_targets.store(true); });
            command::add("paris_see_listen", [](const command::params& args)
            {
                const bool on = args.size() < 2 || std::strcmp(args.get(1), "0") != 0;
                if (on) paris_debugger::set_present_listener(on_present);
                else paris_debugger::set_present_listener(nullptr);
                console::info("[Paris see] listen=%d\n", static_cast<int>(on));
            });
            console::info("[Paris see] ready\n");
        }
    };
}

REGISTER_COMPONENT(paris_see::component)
