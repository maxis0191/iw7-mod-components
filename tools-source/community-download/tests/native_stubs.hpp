#pragma once
#define NOMINMAX
#include <Windows.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
using namespace std::chrono_literals;

namespace scheduler
{
    enum pipeline { async, renderer, server, main, lui, count };
    inline constexpr bool cond_continue = false, cond_end = true;
    inline pipeline executing = main;
    inline std::deque<std::function<void()>> queues[count];
    inline bool reject_queue = false;
    inline void once(const std::function<void()>& callback, pipeline type = async, std::chrono::milliseconds = 0ms)
    {
        if (reject_queue) throw std::bad_alloc();
        queues[type].push_back(callback);
    }
    inline void schedule(const std::function<bool()>& callback, pipeline type = async, std::chrono::milliseconds = 0ms)
    {
        once([=] { if (!callback()) schedule(callback, type); }, type);
    }
    inline bool tick(pipeline type)
    {
        if (queues[type].empty()) return false;
        auto cb = std::move(queues[type].front()); queues[type].pop_front();
        const auto previous = executing; executing = type;
        try { cb(); } catch (...) { executing = previous; throw; }
        executing = previous;
        return true;
    }
}

namespace fake
{
    inline void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
    inline std::string fault;
    inline unsigned close_calls = 0, move_calls = 0, http_calls = 0, connect_calls = 0;
    inline std::vector<std::string> errors, events;
    inline std::function<void()> during_http, during_write, during_read, before_move;

    inline HANDLE create(const wchar_t* name, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES sa, DWORD action, DWORD flags, HANDLE templ)
    {
        if ((fault == "create" && action == CREATE_NEW) || (fault == "reopen" && action == OPEN_EXISTING))
        { SetLastError(ERROR_ACCESS_DENIED); return INVALID_HANDLE_VALUE; }
        return ::CreateFileW(name, access, share, sa, action, flags, templ);
    }
    inline BOOL write(HANDLE h, LPCVOID buffer, DWORD size, LPDWORD written, LPOVERLAPPED overlap)
    {
        if (during_write) during_write();
        if (fault == "write") { *written = 0; SetLastError(ERROR_DISK_FULL); return FALSE; }
        return ::WriteFile(h, buffer, fault == "short_write" ? size / 2 : size, written, overlap);
    }
    inline BOOL flush(HANDLE h) { return fault == "flush" ? FALSE : ::FlushFileBuffers(h); }
    inline BOOL close(HANDLE h)
    {
        ++close_calls;
        if ((fault == "close_write" && close_calls == 1) || (fault == "close_read" && close_calls == 2)) return FALSE;
        return ::CloseHandle(h);
    }
    inline BOOL read(HANDLE h, LPVOID buffer, DWORD size, LPDWORD count, LPOVERLAPPED overlap)
    {
        if (during_read) during_read();
        if (fault == "read") return FALSE;
        const auto result = ::ReadFile(h, buffer, fault == "short_read" ? size / 2 : size, count, overlap);
        if (result && *count && fault == "corrupt_read") static_cast<char*>(buffer)[0] ^= 1;
        return result;
    }
    inline BOOL file_size(HANDLE h, PLARGE_INTEGER size)
    {
        if (fault == "size") return FALSE;
        const auto result = ::GetFileSizeEx(h, size);
        if (fault == "wrong_size") ++size->QuadPart;
        return result;
    }
    inline BOOL move(const wchar_t* from, const wchar_t* to, DWORD flags)
    {
        ++move_calls;
        require((flags & MOVEFILE_COPY_ALLOWED) == 0, "copy fallback forbidden");
        require(std::filesystem::path(from).parent_path() == std::filesystem::path(to).parent_path(), "different-volume staging");
        if (before_move) before_move();
        if (fault == "replace") return FALSE;
        return ::MoveFileExW(from, to, flags);
    }
}

namespace game
{
    struct netadr_s { int id = 1; };
    namespace shared
    {
        inline void menu_error(const std::string& message)
        { fake::require(scheduler::executing == scheduler::main, "error UI outside main"); fake::errors.push_back(message); }
    }
}
namespace party
{
    inline void connect(const game::netadr_s&)
    { fake::require(scheduler::executing == scheduler::main, "connect outside main"); ++fake::connect_calls; }
}
namespace ui_scripting
{
    struct table { void set(const char*, const char*) const {} };
    struct value { value(float) {} value(const table&) {} };
    inline void notify(const std::string& name, const std::map<std::string, value>&)
    { fake::require(scheduler::executing == scheduler::lui, "HKS notify outside LUI"); fake::events.push_back(name); }
}
namespace utils
{
    struct info_string { std::string base = "https://invalid.test"; std::string get(const char*) const { return base; } };
    namespace concurrency
    {
        template <typename T> struct container
        {
            T state{}; std::mutex mutex;
            template <typename R = void, typename F> R access(F&& f)
            { std::lock_guard<std::mutex> lock(mutex); return f(state); }
        };
    }
    namespace hash
    {
        // Independent IEEE CRC32, with the exact pin's little-endian hex encoding.
        inline std::string get_buffer_hash(std::string& bytes, const std::string&)
        {
            uint32_t crc = 0xffffffff;
            for (unsigned char ch : bytes)
            {
                crc ^= ch;
                for (int bit = 0; bit != 8; ++bit) crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
            }
            crc ^= 0xffffffff;
            constexpr char hex[] = "0123456789ABCDEF";
            std::string result;
            for (int shift = 0; shift != 32; shift += 8)
            { const auto byte = (crc >> shift) & 255; result += hex[byte >> 4]; result += hex[byte & 15]; }
            return result;
        }
    }
    namespace http
    {
        struct result { int code = 0; unsigned int response_code = 200; std::string buffer; };
        inline std::optional<result> response;
        inline std::optional<result> get_data(const std::string&, const std::string&, const std::map<std::string, std::string>&,
            const std::function<int(size_t, size_t)>& cb)
        {
            ++fake::http_calls;
            fake::require(scheduler::executing == scheduler::async, "HTTP outside worker");
            if (fake::during_http) fake::during_http();
            if (fake::fault == "http_throw") throw std::runtime_error("private URL/details must not reach UI");
            if (fake::fault == "http_nonstd") throw 42;
            if (response && cb(response->buffer.size(), response->buffer.size()) == -1) return result{42, 0, {}};
            return response;
        }
    }
}
inline constexpr int CURLE_OK = 0;
namespace download { struct file_t { std::string name, hash; }; void stop_download(); }
struct component_interface { virtual void pre_destroy() {} };
#define REGISTER_COMPONENT(...)
#define CreateFileW fake::create
#define WriteFile fake::write
#define ReadFile fake::read
#define CloseHandle fake::close
#define FlushFileBuffers fake::flush
#define GetFileSizeEx fake::file_size
#define MoveFileExW fake::move
