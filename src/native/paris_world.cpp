#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include <utils/flags.hpp>
#include <utils/io.hpp>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unordered_map>

// Live world editor for isolated lab clients (-paris-isolated-lab; -paris-world is accepted and not required, because a
// gamelab plan cannot add client flags). A client only: it reads the running map's placed props (the world's static
// models) straight from the game's memory and hides them inside a box, so a change to a map can be tried in seconds.
//
//   paris_world_stats                          map, props, surfaces, lights, hidden
//   paris_world_dump [collect]                 iw7-mod/paris-world/<map>-props.json (schema iw7.world-live/1);
//                                              "collect" writes iw7-mod/paris-perf/ instead, which session runners keep
//   paris_world_method <names>                 how to hide: cull, scale, axis, origin, bounds (joined with +), or all
//   paris_world_hide_box x1 y1 z1 x2 y2 z2     hide every prop whose origin is inside the box (corner order is free)
//   paris_world_hide_model <text> [x y z r]    hide props whose model name contains the text, optionally within r of a point
//   paris_world_restore                        put every hidden prop back, byte for byte
//
// Everything runs on the main thread from console commands, plus one light main-thread tick that notices a new map. A
// hidden prop keeps the original bytes of every field that was changed, so a restore is exact. When the world pointer
// changes (map unload or load) the saved state is dropped and nothing is written to the old memory.
namespace paris_world
{
    namespace
    {
        constexpr std::uint32_t max_props = 200000;
        constexpr std::uint32_t max_surfaces = 2000000;
        constexpr std::uint32_t max_lights = 100000;
        constexpr float hide_drop = 100000.0f;
        constexpr const char* output_directory = "iw7-mod/paris-world";
        constexpr const char* collect_directory = "iw7-mod/paris-perf";

        enum method_bits : unsigned
        {
            method_cull = 1,   // cullDist = 0
            method_scale = 2,  // placement.scale = 0
            method_axis = 4,   // placement.axis = 0
            method_origin = 8, // placement.origin.z -= 100000
            method_bounds = 16 // smodelInsts[i].bounds moved 100000 down and made empty
        };

        struct saved_prop
        {
            std::uint32_t index{};
            unsigned mask{};
            float origin[3]{};
            float axis[9]{};
            float scale{};
            std::uint16_t cull{};
            float bounds[6]{};
        };

        bool enabled{};
        unsigned method{method_cull};
        const void* tracked_world{};
        const void* tracked_insts{};
        std::uint32_t tracked_count{};
        std::uint32_t tracked_checksum{};
        std::vector<saved_prop> hidden;
        std::vector<std::uint8_t> is_hidden;

        game::GfxWorld* current_world() { return *game::g_world; }

        bool readable(const void* pointer, const std::size_t size)
        {
            if (!pointer) return false;
            auto at = reinterpret_cast<std::uintptr_t>(pointer);
            const auto end = at + size;
            while (at < end)
            {
                MEMORY_BASIC_INFORMATION info{};
                if (!VirtualQuery(reinterpret_cast<const void*>(at), &info, sizeof(info))) return false;
                if (info.State != MEM_COMMIT || (info.Protect & (PAGE_NOACCESS | PAGE_GUARD))) return false;
                at = reinterpret_cast<std::uintptr_t>(info.BaseAddress) + info.RegionSize;
            }
            return true;
        }

        // The page of a write may not be writable; make it so (the zone memory normally is).
        bool ensure_writable(void* pointer, const std::size_t size)
        {
            MEMORY_BASIC_INFORMATION info{};
            if (!VirtualQuery(pointer, &info, sizeof(info)) || info.State != MEM_COMMIT) return false;
            constexpr DWORD writable = PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
            if (info.Protect & writable) return true;
            DWORD old{};
            return VirtualProtect(pointer, size, PAGE_READWRITE, &old) != 0;
        }

        struct view
        {
            game::GfxWorld* world{};
            game::GfxStaticModelDrawInst* insts{};
            game::GfxStaticModelInst* bounds{};
            std::uint32_t count{};
        };

        void forget(const char* why)
        {
            if (!hidden.empty()) console::info("[Paris world] %s: forgot %zu hidden props (nothing written)\n", why, hidden.size());
            hidden.clear();
            is_hidden.clear();
            tracked_world = nullptr;
            tracked_insts = nullptr;
            tracked_count = 0;
        }

        // A checked view of the current world's props; fills `why` when there is none. Drops the saved state when the world changed.
        bool get_view(view& out, const char** why)
        {
            auto* world = current_world();
            if (!world) { *why = "no world loaded"; if (tracked_world) forget("world unloaded"); return false; }
            if (!readable(world, sizeof(game::GfxWorld))) { *why = "world pointer not readable"; return false; }
            const auto count = world->dpvs.smodelCount;
            auto* insts = world->dpvs.smodelDrawInsts;
            if (count == 0 || count > max_props || !insts) { *why = "world has no props or an implausible count"; return false; }
            if (!readable(insts, static_cast<std::size_t>(count) * sizeof(game::GfxStaticModelDrawInst))) { *why = "prop array not readable"; return false; }
            if (tracked_world && (tracked_world != world || tracked_insts != insts || tracked_count != count || tracked_checksum != world->checksum))
                forget("another world");
            if (!tracked_world)
            {
                tracked_world = world;
                tracked_insts = insts;
                tracked_count = count;
                tracked_checksum = world->checksum;
                is_hidden.assign(count, 0);
            }
            out.world = world;
            out.insts = insts;
            out.count = count;
            auto* bounds = world->dpvs.smodelInsts;
            out.bounds = bounds && readable(bounds, static_cast<std::size_t>(count) * sizeof(game::GfxStaticModelInst)) ? bounds : nullptr;
            return true;
        }

        std::string map_name(const game::GfxWorld* world)
        {
            const char* names[2] = {world->baseName, world->name};
            for (const char* name : names)
            {
                if (!name || !readable(name, 1)) continue;
                std::string text(name, strnlen(name, 120));
                const auto slash = text.find_last_of("/\\");
                if (slash != std::string::npos) text = text.substr(slash + 1);
                const auto dot = text.find('.');
                if (dot != std::string::npos) text = text.substr(0, dot);
                if (!text.empty()) return text;
            }
            return "unknown";
        }

        std::string safe_file_part(std::string text)
        {
            for (auto& c : text) if (!std::isalnum(static_cast<unsigned char>(c)) && c != '_' && c != '-') c = '_';
            return text;
        }

        // Model names are cached by pointer (a map has a few hundred models for tens of thousands of props).
        const char* model_name(const game::XModel* model, std::unordered_map<const void*, const char*>& cache)
        {
            if (!model) return nullptr;
            const auto found = cache.find(model);
            if (found != cache.end()) return found->second;
            const char* name = nullptr;
            if (readable(model, sizeof(void*)))
            {
                const char* candidate = model->name;
                if (candidate && readable(candidate, 1) && strnlen(candidate, 200) < 200) name = candidate;
            }
            cache.emplace(model, name);
            return name;
        }

        void json_escape(std::string& out, const char* text)
        {
            for (; *text; ++text)
            {
                const auto c = static_cast<unsigned char>(*text);
                if (c == '"' || c == '\\') { out += '\\'; out += static_cast<char>(c); }
                else if (c < 0x20 || c >= 0x7F) { char buffer[8]; _snprintf_s(buffer, sizeof(buffer), _TRUNCATE, "\\u%04x", c); out += buffer; }
                else out += static_cast<char>(c);
            }
        }

        void stats()
        {
            view v;
            const char* why = "";
            auto* world = current_world();
            if (!world || !get_view(v, &why))
            {
                console::info("[Paris world] map=none props=0 surfaces=0 lights=0 hidden=0 (%s)\n", why);
                return;
            }
            const auto surfaces = world->surfaceCount;
            const auto lights = world->primaryLightCount;
            std::uint32_t com_lights = 0;
            if (world->name && readable(world->name, 1))
            {
                const auto header = game::DB_FindXAssetHeader(game::XAssetType::ASSET_TYPE_COMWORLD, world->name, 0).comWorld;
                if (header && readable(header, sizeof(game::ComWorld))) com_lights = header->primaryLightCount;
            }
            console::info("[Paris world] map=%s props=%u surfaces=%u lights=%u hidden=%zu static_surfaces=%u comworld_lights=%u method=0x%X\n",
                map_name(world).c_str(), v.count, surfaces > max_surfaces ? 0u : surfaces, lights > max_lights ? 0u : lights, hidden.size(),
                world->dpvs.staticSurfaceCount, com_lights, method);
        }

        void dump(const bool collect)
        {
            view v;
            const char* why = "";
            if (!get_view(v, &why)) { console::info("[Paris world] dump refused: %s\n", why); return; }
            std::unordered_map<const void*, const char*> names;
            const auto map = map_name(v.world);
            std::string out;
            out.reserve(static_cast<std::size_t>(v.count) * 230 + 256);
            char line[1024];
            _snprintf_s(line, sizeof(line), _TRUNCATE, "{\"schema\":\"iw7.world-live/1\",\"map\":\"%s\",\"count\":%u,\"fields\":\"i,model,origin,axis(3x3 as stored),scale,cull(u16),flags(u16),vl_flags(i32),bounds(mid3,half3)\",\"props\":[\n",
                safe_file_part(map).c_str(), v.count);
            out += line;
            for (std::uint32_t i = 0; i < v.count; ++i)
            {
                const auto& d = v.insts[i];
                const char* name = model_name(d.model, names);
                _snprintf_s(line, sizeof(line), _TRUNCATE, "%s{\"i\":%u,\"model\":\"", i ? ",\n" : "", i);
                out += line;
                if (name) json_escape(out, name);
                const auto& p = d.placement;
                _snprintf_s(line, sizeof(line), _TRUNCATE,
                    "\",\"origin\":[%.9g,%.9g,%.9g],\"axis\":[%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g],\"scale\":%.9g,\"cull\":%u,\"flags\":%u,\"vl_flags\":%d",
                    p.origin[0], p.origin[1], p.origin[2], p.axis[0][0], p.axis[0][1], p.axis[0][2], p.axis[1][0], p.axis[1][1], p.axis[1][2],
                    p.axis[2][0], p.axis[2][1], p.axis[2][2], p.scale, static_cast<unsigned>(d.cullDist), static_cast<unsigned>(d.flags), d.vertexLightingInfo.flags);
                out += line;
                if (v.bounds)
                {
                    const auto& b = v.bounds[i].bounds;
                    _snprintf_s(line, sizeof(line), _TRUNCATE, ",\"bounds\":[%.9g,%.9g,%.9g,%.9g,%.9g,%.9g]", b.midPoint[0], b.midPoint[1], b.midPoint[2],
                        b.halfSize[0], b.halfSize[1], b.halfSize[2]);
                    out += line;
                }
                out += '}';
            }
            out += "\n]}\n";
            const std::string file = std::string(collect ? collect_directory : output_directory) + "/" + safe_file_part(map) + "-props.json";
            const bool written = utils::io::write_file(file, out);
            console::info("[Paris world] dumped props=%u file=%s written=%d bytes=%zu\n", v.count, (safe_file_part(map) + "-props.json").c_str(),
                static_cast<int>(written), out.size());
        }

        bool hide_one(const view& v, const std::uint32_t index)
        {
            if (is_hidden[index]) return false;
            auto& d = v.insts[index];
            saved_prop s;
            s.index = index;
            s.mask = method;
            std::memcpy(s.origin, d.placement.origin, sizeof(s.origin));
            std::memcpy(s.axis, d.placement.axis, sizeof(s.axis));
            s.scale = d.placement.scale;
            s.cull = d.cullDist;
            if (v.bounds) std::memcpy(s.bounds, &v.bounds[index].bounds, sizeof(s.bounds));
            if (!ensure_writable(&d, sizeof(d))) return false;
            if (method & method_bounds)
            {
                if (!v.bounds || !ensure_writable(&v.bounds[index], sizeof(game::GfxStaticModelInst))) return false;
                auto& b = v.bounds[index].bounds;
                b.midPoint[2] -= hide_drop;
                b.halfSize[0] = b.halfSize[1] = b.halfSize[2] = 0.0f;
            }
            if (method & method_cull) d.cullDist = 0;
            if (method & method_scale) d.placement.scale = 0.0f;
            if (method & method_axis) std::memset(d.placement.axis, 0, sizeof(d.placement.axis));
            if (method & method_origin) d.placement.origin[2] -= hide_drop;
            hidden.push_back(s);
            is_hidden[index] = 1;
            return true;
        }

        bool parse_floats(const command::params& params, const int first, const int count, float* out)
        {
            for (int i = 0; i < count; ++i)
            {
                const char* text = params.get(first + i);
                char* end{};
                out[i] = std::strtof(text, &end);
                if (end == text || *end != '\0' || !std::isfinite(out[i])) return false;
            }
            return true;
        }

        void hide_box(const command::params& params)
        {
            float v6[6]{};
            if (params.size() != 7 || !parse_floats(params, 1, 6, v6))
            {
                console::info("[Paris world] usage: paris_world_hide_box x1 y1 z1 x2 y2 z2\n");
                return;
            }
            view v;
            const char* why = "";
            if (!get_view(v, &why)) { console::info("[Paris world] hide refused: %s\n", why); return; }
            float lo[3], hi[3];
            for (int k = 0; k < 3; ++k) { lo[k] = (std::min)(v6[k], v6[k + 3]); hi[k] = (std::max)(v6[k], v6[k + 3]); }
            std::uint32_t matched = 0;
            for (std::uint32_t i = 0; i < v.count; ++i)
            {
                const float* o = v.insts[i].placement.origin;
                if (o[0] < lo[0] || o[0] > hi[0] || o[1] < lo[1] || o[1] > hi[1] || o[2] < lo[2] || o[2] > hi[2]) continue;
                if (hide_one(v, i)) ++matched;
            }
            console::info("[Paris world] hide box=%g,%g,%g..%g,%g,%g matched=%u hidden_total=%zu method=0x%X\n", lo[0], lo[1], lo[2], hi[0], hi[1], hi[2], matched,
                hidden.size(), method);
        }

        bool contains_nocase(const char* hay, const std::string& needle)
        {
            if (needle.empty()) return true;
            const auto n = std::strlen(hay);
            for (std::size_t i = 0; i + needle.size() <= n; ++i)
            {
                std::size_t k = 0;
                while (k < needle.size() && std::tolower(static_cast<unsigned char>(hay[i + k])) == std::tolower(static_cast<unsigned char>(needle[k]))) ++k;
                if (k == needle.size()) return true;
            }
            return false;
        }

        void hide_model(const command::params& params)
        {
            float v4[4]{};
            const bool with_radius = params.size() == 6;
            if (params.size() != 2 && !(with_radius && parse_floats(params, 2, 4, v4)))
            {
                console::info("[Paris world] usage: paris_world_hide_model <name text> [x y z radius]\n");
                return;
            }
            view v;
            const char* why = "";
            if (!get_view(v, &why)) { console::info("[Paris world] hide refused: %s\n", why); return; }
            const std::string text = params.get(1);
            std::unordered_map<const void*, const char*> names;
            std::uint32_t matched = 0;
            for (std::uint32_t i = 0; i < v.count; ++i)
            {
                const char* name = model_name(v.insts[i].model, names);
                if (!name || !contains_nocase(name, text)) continue;
                if (with_radius)
                {
                    const float* o = v.insts[i].placement.origin;
                    const float dx = o[0] - v4[0], dy = o[1] - v4[1], dz = o[2] - v4[2];
                    if (dx * dx + dy * dy + dz * dz > v4[3] * v4[3]) continue;
                }
                if (hide_one(v, i)) ++matched;
            }
            console::info("[Paris world] hide model=%s matched=%u hidden_total=%zu method=0x%X\n", text.c_str(), matched, hidden.size(), method);
        }

        void restore()
        {
            view v;
            const char* why = "";
            if (!get_view(v, &why)) { console::info("[Paris world] restored=0 (%s)\n", why); return; }
            std::uint32_t restored = 0;
            for (const auto& s : hidden)
            {
                if (s.index >= v.count) continue;
                auto& d = v.insts[s.index];
                if (!ensure_writable(&d, sizeof(d))) continue;
                if (s.mask & method_cull) d.cullDist = s.cull;
                if (s.mask & method_scale) d.placement.scale = s.scale;
                if (s.mask & method_axis) std::memcpy(d.placement.axis, s.axis, sizeof(s.axis));
                if (s.mask & method_origin) std::memcpy(d.placement.origin, s.origin, sizeof(s.origin));
                if ((s.mask & method_bounds) && v.bounds && ensure_writable(&v.bounds[s.index], sizeof(game::GfxStaticModelInst)))
                    std::memcpy(&v.bounds[s.index].bounds, s.bounds, sizeof(s.bounds));
                ++restored;
            }
            hidden.clear();
            std::fill(is_hidden.begin(), is_hidden.end(), static_cast<std::uint8_t>(0));
            console::info("[Paris world] restored=%u\n", restored);
        }

        void set_method(const command::params& params)
        {
            if (params.size() != 2)
            {
                console::info("[Paris world] method=0x%X usage: paris_world_method cull|scale|axis|origin|bounds (join with +) | all\n", method);
                return;
            }
            std::string text = params.get(1);
            unsigned bits = 0;
            std::size_t at = 0;
            while (at <= text.size())
            {
                auto plus = text.find('+', at);
                if (plus == std::string::npos) plus = text.size();
                const auto word = text.substr(at, plus - at);
                at = plus + 1;
                if (word == "cull") bits |= method_cull;
                else if (word == "scale") bits |= method_scale;
                else if (word == "axis") bits |= method_axis;
                else if (word == "origin") bits |= method_origin;
                else if (word == "bounds") bits |= method_bounds;
                else if (word == "all") bits |= method_cull | method_scale | method_axis | method_origin | method_bounds;
                else { console::info("[Paris world] unknown method '%s'\n", word.c_str()); return; }
            }
            method = bits;
            console::info("[Paris world] method=0x%X\n", method);
        }

        // Main-thread tick: the world pointer is compared and nothing behind it is read.
        void tick()
        {
            if (!tracked_world) return;
            if (static_cast<const void*>(current_world()) != tracked_world) forget("world changed");
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (game::environment::is_dedi()) return;
            if (!utils::flags::has_flag("paris-isolated-lab")) return;
            enabled = true;
            scheduler::loop(tick, scheduler::main);
            command::add("paris_world_stats", [] { stats(); });
            command::add("paris_world_dump", [](const command::params& params) { dump(params.size() > 1 && std::strcmp(params.get(1), "collect") == 0); });
            command::add("paris_world_method", [](const command::params& params) { set_method(params); });
            command::add("paris_world_hide_box", [](const command::params& params) { hide_box(params); });
            command::add("paris_world_hide_model", [](const command::params& params) { hide_model(params); });
            command::add("paris_world_restore", [] { restore(); });
            console::info("[Paris world] ready\n");
        }
    };
}

REGISTER_COMPONENT(paris_world::component)
