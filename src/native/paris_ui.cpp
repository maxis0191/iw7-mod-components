#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "game/ui_scripting/execution.hpp"
#include "scheduler.hpp"
#include "command.hpp"
#include "ui_scripting.hpp"
#include "console/console.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <utils/io.hpp>
#include <atomic>
#include <cctype>
#include <cstdio>
#include <cstring>

// The user interface as data, for isolated lab clients (-paris-isolated-lab). A client only.
//
//   paris_ui_dump [tag]     iw7-mod/paris-perf/ui-<tag>.json (schema iw7.ui-dump/1): every server-drawn HUD element the
//                           client drew in the next frame (the element as received, plus the rectangle, text, font and
//                           colour the game computed for it), and the Lua UI element tree from the root
//   paris_ui_lua <name>     runs iw7-mod/paris-ui/<name>.lua in the UI's Lua state and writes what it returns to
//                           iw7-mod/paris-perf/ui-lua-<name>.txt (a probe, or a test that plants elements)
//
// HUD elements: the game's own per-element draw function is observed for one frame. Nothing is recomputed here: the
// rectangle is the one the game's layout function returned for the element (alignment, scale, safe area and resolution
// applied by the game). Lua UI: a Lua walker runs in the UI's Lua state and returns the tree as JSON text. The walker
// is the text below; a file iw7-mod/paris-ui/walker.lua replaces it (to try a change without a build).
//
// When no dump is asked the three observers cost one predictable branch each and the frame tick one compare.
namespace paris_ui
{
    namespace
    {
        constexpr std::size_t hud_elem_size = 0xB8;       // hudelem_s: last field read by the game is the flags word at 0xB4
        constexpr std::size_t info_size = 0x844;          // the per-element layout record the game fills (time at 0x840)
        constexpr std::size_t max_hud_rows = 4096;
        constexpr std::size_t max_lua_bytes = 32u * 1024u * 1024u;
        constexpr int lui_wait_frames = 240;
        constexpr const char* output_directory = "iw7-mod/paris-perf";
        constexpr const char* script_directory = "iw7-mod/paris-ui";

        // Default walker. It returns one JSON object. Every engine call is protected: a method the element type does not
        // have gives no field, never an error. Rectangles are what the engine reports, in screen pixels.
        const char* const default_walker = R"LUA(
local out, n = {}, 0
local function put(s) n = n + 1; out[n] = s end
local function esc(s)
    s = tostring(s)
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == '\\' then return '\\\\' end
        return string.format('\\u%04x', c:byte())
    end)
    return s
end
local function num(v)
    if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then return 'null' end
    if v == math.floor(v) and v > -1e9 and v < 1e9 then return string.format('%d', v) end
    return string.format('%.3f', v)
end
local function call(e, name, ...)
    local f = e[name]
    if type(f) ~= 'function' then return nil end
    local r = { pcall(f, e, ...) }
    if not r[1] then return nil end
    table.remove(r, 1)
    return r
end
local function list(r, want)
    if not r or #r < want then return nil end
    local t = {}
    for i = 1, want do t[i] = num(r[i]) end
    return '[' .. table.concat(t, ',') .. ']'
end
local root = Engine.GetLuiRoot and Engine.GetLuiRoot() or nil
local count, limit, truncated = 0, 20000, false
local function walk(e, parent, depth)
    if count >= limit then truncated = true; return end
    local me = count
    count = count + 1
    local f = { '"i":' .. me, '"p":' .. parent, '"d":' .. depth }
    local id = e.id
    if id ~= nil then f[#f + 1] = '"id":"' .. esc(id) .. '"' end
    local rect = list(call(e, 'getRect'), 4)
    if rect then f[#f + 1] = '"rect":' .. rect end
    local lr = list(call(e, 'getLocalRect'), 4)
    if lr then f[#f + 1] = '"local":' .. lr end
    local a = call(e, 'GetAlpha') or call(e, 'getAlpha')
    if a and type(a[1]) == 'number' then f[#f + 1] = '"alpha":' .. num(a[1]) end
    local t = call(e, 'getText') or call(e, 'GetText')
    if t and t[1] ~= nil then f[#f + 1] = '"text":"' .. esc(t[1]) .. '"' end
    local c = call(e, 'getFirstChild')
    put((me > 0 and ',\n' or '') .. '{' .. table.concat(f, ',') .. '}')
    local child = c and c[1] or nil
    while child do
        walk(child, me, depth + 1)
        local nx = call(child, 'getNextSibling')
        child = nx and nx[1] or nil
    end
end
put('{"walker":"default/1","elements":[\n')
if root then walk(root, -1, 0) end
put('\n],"count":' .. count .. ',"truncated":' .. tostring(truncated) .. ',"root":' .. tostring(root ~= nil) .. '}')
return table.concat(out)
)LUA";

        struct hud_row
        {
            std::uintptr_t address{};
            std::uint8_t raw[hud_elem_size]{};
            bool has_info{};
            std::uint8_t info_head[0x14]{}; // x, y, z, width, height
            std::string label;
            std::string text;
            float label_width{};
            float text_width{};
            std::string font;
            int font_pixel_height{};
            float font_scale{};
            float font_height{};
            float color[4]{};
            int time{};
            std::string material;
            unsigned draws{};
        };

        enum class phase { idle, armed, capturing, wait_lui, write };

        utils::hook::detour draw_single_hook;
        utils::hook::detour element_info_hook;
        utils::hook::detour material_hook;

        std::atomic_bool capturing{};
        DWORD capture_thread{};
        int current_row{-1};
        std::vector<hud_row> rows;
        bool rows_overflow{};

        phase state{phase::idle};
        std::string pending_tag;
        std::string lui_json;
        std::string lui_error;
        std::atomic_bool lui_done{};
        int waited_frames{};
        std::int64_t t_request{};
        std::int64_t t_capture_end{};
        std::int64_t lui_walk_us{};
        std::uint64_t dump_serial{};

        std::int64_t now_us()
        {
            LARGE_INTEGER f{}, c{};
            QueryPerformanceFrequency(&f);
            QueryPerformanceCounter(&c);
            return static_cast<std::int64_t>(c.QuadPart * 1000000ll / f.QuadPart);
        }

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

        std::string bounded_string(const char* text, const std::size_t limit)
        {
            if (!text || !readable(text, 1)) return {};
            std::size_t length = 0;
            while (length < limit && text[length]) ++length;
            return std::string(text, length);
        }

        // JSON string body. Control bytes and bytes above 0x7F become \u00XX (a dump is plain ASCII and always valid).
        // Anything shaped like an IPv4 address is replaced: a dump must not carry a network address.
        void json_escape(std::string& out, const std::string& text)
        {
            std::size_t i = 0;
            while (i < text.size())
            {
                if (std::isdigit(static_cast<unsigned char>(text[i])) && (i == 0 || !std::isdigit(static_cast<unsigned char>(text[i - 1]))))
                {
                    std::size_t at = i;
                    int groups = 0;
                    while (groups < 4)
                    {
                        std::size_t digits = 0;
                        while (at < text.size() && digits < 3 && std::isdigit(static_cast<unsigned char>(text[at]))) { ++at; ++digits; }
                        if (!digits) break;
                        ++groups;
                        if (groups < 4) { if (at < text.size() && text[at] == '.') ++at; else break; }
                    }
                    if (groups == 4 && (at >= text.size() || !std::isdigit(static_cast<unsigned char>(text[at]))))
                    {
                        out += "<address>";
                        i = at;
                        continue;
                    }
                }
                const auto c = static_cast<unsigned char>(text[i++]);
                if (c == '"') out += "\\\"";
                else if (c == '\\') out += "\\\\";
                else if (c < 0x20 || c >= 0x7F)
                {
                    char code[8];
                    _snprintf_s(code, sizeof(code), _TRUNCATE, "\\u%04x", static_cast<unsigned>(c));
                    out += code;
                }
                else out += static_cast<char>(c);
            }
        }

        std::string safe_file_part(const std::string& text)
        {
            std::string out;
            for (const auto c : text)
            {
                if (std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '-') out += c;
                if (out.size() >= 48) break;
            }
            return out;
        }

        float read_float(const std::uint8_t* at) { float v; std::memcpy(&v, at, sizeof(v)); return v; }
        int read_int(const std::uint8_t* at) { int v; std::memcpy(&v, at, sizeof(v)); return v; }

        bool on_capture_thread() { return capturing.load(std::memory_order_relaxed) && GetCurrentThreadId() == capture_thread; }

        // The game's per-element draw: (local client, element). Every element the client draws this frame passes here.
        void draw_single_stub(const int local_client, const std::uint8_t* element)
        {
            if (!on_capture_thread() || !element)
            {
                draw_single_hook.invoke<void>(local_client, element);
                return;
            }
            const auto address = reinterpret_cast<std::uintptr_t>(element);
            int index = -1;
            for (std::size_t i = 0; i < rows.size(); ++i) if (rows[i].address == address) { index = static_cast<int>(i); break; }
            if (index < 0)
            {
                if (rows.size() >= max_hud_rows) rows_overflow = true;
                else
                {
                    hud_row row;
                    row.address = address;
                    std::memcpy(row.raw, element, hud_elem_size);
                    rows.push_back(std::move(row));
                    index = static_cast<int>(rows.size() - 1);
                }
            }
            if (index >= 0) ++rows[index].draws;
            current_row = index;
            draw_single_hook.invoke<void>(local_client, element);
            current_row = -1;
        }

        // The game's layout of one element: fills the record with position, size, label, text, font and time. Called by the
        // draw above only for an element that passes the game's own visibility test.
        void element_info_stub(const int local_client, const std::uint8_t* element, std::uint8_t* info, char* scratch)
        {
            element_info_hook.invoke<void>(local_client, element, info, scratch);
            if (!on_capture_thread() || current_row < 0 || !info) return;
            auto& row = rows[current_row];
            if (row.has_info) return;
            row.has_info = true;
            std::memcpy(row.info_head, info, sizeof(row.info_head));
            row.label = bounded_string(reinterpret_cast<const char*>(info + 0x14), 0x3FF);
            row.label_width = read_float(info + 0x414);
            row.text = bounded_string(reinterpret_cast<const char*>(info + 0x418), 0x3FF);
            row.text_width = read_float(info + 0x818);
            game::GfxFont* font{};
            std::memcpy(&font, info + 0x820, sizeof(font));
            if (font && readable(font, sizeof(game::GfxFont)))
            {
                row.font = bounded_string(font->fontName, 96);
                row.font_pixel_height = font->pixelHeight;
            }
            row.font_scale = read_float(info + 0x828);
            row.font_height = read_float(info + 0x82C);
            for (int i = 0; i < 4; ++i) row.color[i] = read_float(info + 0x830 + i * 4);
            row.time = read_int(info + 0x840);
        }

        game::Material* material_stub(const char* name, const int track)
        {
            if (on_capture_thread() && current_row >= 0 && name && rows[current_row].material.empty())
                rows[current_row].material = bounded_string(name, 96);
            return material_hook.invoke<game::Material*>(name, track);
        }

        std::string dvar_string(const char* name)
        {
            const auto* dvar = game::Dvar_FindVar(name);
            if (!dvar || dvar->type != game::DVAR_TYPE_STRING || !dvar->current.string) return {};
            return bounded_string(dvar->current.string, 64);
        }

        void run_lua(const std::string& code, const char* chunk, std::string& result, std::string& error)
        {
            try
            {
                if (!ui_scripting::lui_running()) { error = "the UI's Lua state is not running"; return; }
                const auto lua = ui_scripting::get_globals();
                const auto loaded = lua["loadstring"](code, std::string(chunk));
                if (!loaded[0].is<ui_scripting::function>())
                {
                    error = loaded.size() > 1 && loaded[1].is<std::string>() ? loaded[1].as<std::string>() : "the script did not compile";
                    return;
                }
                const auto results = lua["pcall"](loaded);
                if (!results[0].as<bool>())
                {
                    error = results.size() > 1 && results[1].is<std::string>() ? results[1].as<std::string>() : "the script failed";
                    return;
                }
                if (results.size() > 1 && results[1].is<std::string>()) result = results[1].as<std::string>();
                else error = "the script returned no text";
                if (result.size() > max_lua_bytes) { result.clear(); error = "the script returned too much text"; }
            }
            catch (const std::exception& e)
            {
                error = e.what();
            }
        }

        void write_dump()
        {
            const auto t_build = now_us();
            std::string out;
            out.reserve(rows.size() * 900 + lui_json.size() + 2048);
            char line[1024];
            const auto& vid = *game::vidConfig;
            out += "{\"schema\":\"iw7.ui-dump/1\",\"tag\":\"";
            json_escape(out, pending_tag);
            out += "\",\"map\":\"";
            json_escape(out, dvar_string("mapname"));
            _snprintf_s(line, sizeof(line), _TRUNCATE, "\",\"serial\":%llu,\"time_ms\":%d,\"screen\":{\"width\":%u,\"height\":%u,\"scene_width\":%u,\"scene_height\":%u,\"aspect\":%.6g},\n",
                static_cast<unsigned long long>(dump_serial), game::Sys_Milliseconds(), vid.displayWidth, vid.displayHeight, vid.sceneWidth, vid.sceneHeight, vid.displayAspectRatio);
            out += line;
            const auto* placement = game::ScrPlace_GetViewPlacement();
            if (placement && readable(placement, sizeof(game::ScreenPlacement)))
            {
                const auto* p = placement;
                _snprintf_s(line, sizeof(line), _TRUNCATE,
                    "\"placement\":{\"virtual_to_real\":[%.6g,%.6g],\"virtual_to_full\":[%.6g,%.6g],\"real_to_virtual\":[%.6g,%.6g],\"real_viewport_position\":[%.6g,%.6g],\"real_viewport_size\":[%.6g,%.6g],"
                    "\"virtual_viewable_min\":[%.6g,%.6g],\"virtual_viewable_max\":[%.6g,%.6g],\"real_viewable_min\":[%.6g,%.6g],\"real_viewable_max\":[%.6g,%.6g],"
                    "\"virtual_adjustable_min\":[%.6g,%.6g],\"virtual_adjustable_max\":[%.6g,%.6g],\"real_adjustable_min\":[%.6g,%.6g],\"real_adjustable_max\":[%.6g,%.6g]},\n",
                    p->scaleVirtualToReal[0], p->scaleVirtualToReal[1], p->scaleVirtualToFull[0], p->scaleVirtualToFull[1], p->scaleRealToVirtual[0], p->scaleRealToVirtual[1],
                    p->realViewportPosition[0], p->realViewportPosition[1], p->realViewportSize[0], p->realViewportSize[1],
                    p->virtualViewableMin[0], p->virtualViewableMin[1], p->virtualViewableMax[0], p->virtualViewableMax[1],
                    p->realViewableMin[0], p->realViewableMin[1], p->realViewableMax[0], p->realViewableMax[1],
                    p->virtualAdjustableMin[0], p->virtualAdjustableMin[1], p->virtualAdjustableMax[0], p->virtualAdjustableMax[1],
                    p->realAdjustableMin[0], p->realAdjustableMin[1], p->realAdjustableMax[0], p->realAdjustableMax[1]);
                out += line;
            }
            _snprintf_s(line, sizeof(line), _TRUNCATE, "\"hud\":{\"count\":%zu,\"element_bytes\":%zu,\"overflow\":%s,\"elements\":[", rows.size(), hud_elem_size, rows_overflow ? "true" : "false");
            out += line;
            for (std::size_t i = 0; i < rows.size(); ++i)
            {
                const auto& r = rows[i];
                _snprintf_s(line, sizeof(line), _TRUNCATE, "%s\n{\"i\":%zu,\"address\":\"0x%llX\",\"type\":%d,\"drawn\":%s,\"draws\":%u", i ? "," : "", i,
                    static_cast<unsigned long long>(r.address), read_int(r.raw), r.has_info ? "true" : "false", r.draws);
                out += line;
                if (r.has_info)
                {
                    _snprintf_s(line, sizeof(line), _TRUNCATE, ",\"rect\":[%.6g,%.6g,%.6g,%.6g],\"z\":%.6g,\"label_width\":%.6g,\"text_width\":%.6g,\"font_scale\":%.6g,\"font_height\":%.6g,\"font_pixels\":%d,\"color\":[%.6g,%.6g,%.6g,%.6g],\"time\":%d",
                        read_float(r.info_head), read_float(r.info_head + 4), read_float(r.info_head + 0xC), read_float(r.info_head + 0x10), read_float(r.info_head + 8),
                        r.label_width, r.text_width, r.font_scale, r.font_height, r.font_pixel_height, r.color[0], r.color[1], r.color[2], r.color[3], r.time);
                    out += line;
                    out += ",\"label\":\""; json_escape(out, r.label);
                    out += "\",\"text\":\""; json_escape(out, r.text);
                    out += "\",\"font\":\""; json_escape(out, r.font);
                    out += "\"";
                }
                if (!r.material.empty()) { out += ",\"material\":\""; json_escape(out, r.material); out += "\""; }
                out += ",\"raw\":\"";
                for (const auto byte : r.raw)
                {
                    char hex[4];
                    _snprintf_s(hex, sizeof(hex), _TRUNCATE, "%02x", static_cast<unsigned>(byte));
                    out += hex;
                }
                out += "\"}";
            }
            out += "\n]},\n\"lui\":";
            const bool lui_ok = lui_error.empty() && lui_json.size() > 1 && lui_json.front() == '{' && lui_json.back() == '}';
            if (lui_ok) out += lui_json;
            else
            {
                out += "{\"error\":\"";
                json_escape(out, lui_error.empty() ? std::string("the walker did not return a JSON object") : lui_error);
                out += "\"}";
            }
            const auto t_end = now_us();
            _snprintf_s(line, sizeof(line), _TRUNCATE, ",\n\"cost\":{\"request_to_capture_ms\":%.3f,\"lui_walk_ms\":%.3f,\"build_ms\":%.3f,\"request_to_file_ms\":%.3f}}\n",
                (t_capture_end - t_request) / 1000.0, lui_walk_us / 1000.0, (t_end - t_build) / 1000.0, (t_end - t_request) / 1000.0);
            out += line;
            const auto name = std::string("ui-") + (pending_tag.empty() ? std::string("dump") : pending_tag) + ".json";
            const bool written = utils::io::write_file(std::string(output_directory) + "/" + name, out);
            console::info("[Paris ui] dump %s hud=%zu lui=%s bytes=%zu walk_ms=%.2f total_ms=%.2f %s\n", name.c_str(), rows.size(), lui_ok ? "ok" : "error", out.size(),
                lui_walk_us / 1000.0, (now_us() - t_request) / 1000.0, written ? "written" : "NOT WRITTEN");
            rows.clear();
            lui_json.clear();
            lui_error.clear();
        }

        std::string walker_code()
        {
            std::string file;
            if (utils::io::read_file(std::string(script_directory) + "/walker.lua", &file) && !file.empty()) return file;
            return default_walker;
        }

        // Main-thread tick, once per frame. The capture is exactly the drawing between two consecutive ticks.
        void tick()
        {
            switch (state)
            {
            case phase::idle:
                return;
            case phase::armed:
                rows.clear();
                rows_overflow = false;
                current_row = -1;
                capture_thread = GetCurrentThreadId();
                capturing = true;
                state = phase::capturing;
                return;
            case phase::capturing:
            {
                capturing = false;
                current_row = -1;
                t_capture_end = now_us();
                lui_done = false;
                waited_frames = 0;
                const auto serial = dump_serial;
                scheduler::once([serial]
                {
                    if (serial != dump_serial || state != phase::wait_lui || lui_done) return;
                    const auto start = now_us();
                    run_lua(walker_code(), "paris_ui_walker", lui_json, lui_error);
                    lui_walk_us = now_us() - start;
                    lui_done = true;
                }, scheduler::lui);
                state = phase::wait_lui;
                return;
            }
            case phase::wait_lui:
                if (!lui_done && ++waited_frames < lui_wait_frames) return;
                if (!lui_done) { lui_done = true; lui_error = "the UI's Lua context did not run within the wait"; lui_walk_us = 0; }
                state = phase::write;
                return;
            case phase::write:
                write_dump();
                state = phase::idle;
                return;
            }
        }

        void request_dump(const command::params& params)
        {
            if (state != phase::idle) { console::info("[Paris ui] dump refused: another dump is in progress\n"); return; }
            pending_tag = params.size() > 1 ? safe_file_part(params.get(1)) : std::string();
            ++dump_serial;
            t_request = now_us();
            state = phase::armed;
        }

        void request_lua(const command::params& params)
        {
            if (params.size() != 2) { console::info("[Paris ui] usage: paris_ui_lua <name>  (runs %s/<name>.lua)\n", script_directory); return; }
            const auto name = safe_file_part(params.get(1));
            std::string code;
            if (name.empty() || !utils::io::read_file(std::string(script_directory) + "/" + name + ".lua", &code) || code.empty())
            {
                console::info("[Paris ui] lua refused: no script %s/%s.lua\n", script_directory, name.c_str());
                return;
            }
            scheduler::once([name, code]
            {
                std::string result, error;
                const auto start = now_us();
                run_lua(code, "paris_ui_lua", result, error);
                const auto ms = (now_us() - start) / 1000.0;
                const auto text = error.empty() ? result : std::string("ERROR: ") + error + "\n";
                const bool written = utils::io::write_file(std::string(output_directory) + "/ui-lua-" + name + ".txt", text);
                console::info("[Paris ui] lua %s %s bytes=%zu ms=%.2f %s\n", name.c_str(), error.empty() ? "ok" : "error", text.size(), ms, written ? "written" : "NOT WRITTEN");
            }, scheduler::lui);
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (game::environment::is_dedi()) return;
            if (!utils::flags::has_flag("paris-isolated-lab")) return;
            draw_single_hook.create(0x1407E3BD0, draw_single_stub);
            element_info_hook.create(0x1407E3D50, element_info_stub);
            material_hook.create(game::Material_RegisterHandle, material_stub);
            scheduler::loop(tick, scheduler::main);
            command::add("paris_ui_dump", [](const command::params& params) { request_dump(params); });
            command::add("paris_ui_lua", [](const command::params& params) { request_lua(params); });
            console::info("[Paris ui] ready\n");
        }
    };
}

REGISTER_COMPONENT(paris_ui::component)
