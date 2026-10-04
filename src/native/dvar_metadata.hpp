#pragma once
#include <mutex>
#include <string>
#include <unordered_map>

namespace iw7::metadata
{
    // Engine registration, console and rendering can access metadata on different
    // threads. Return copies under the lock; never call engine code while locked.
    template <typename Key>
    class cache
    {
    public:
        std::string name(const Key key)
        {
            std::lock_guard lock(mutex_);
            return lookup(names_, key);
        }
        std::string description(const Key key)
        {
            std::lock_guard lock(mutex_);
            return lookup(descriptions_, key);
        }
        void name(const Key key, const std::string& value)
        {
            std::lock_guard lock(mutex_);
            names_[key] = value;
        }
        void description(const Key key, const std::string& value)
        {
            std::lock_guard lock(mutex_);
            descriptions_[key] = value;
        }
    private:
        static std::string lookup(const std::unordered_map<Key, std::string>& values, const Key key)
        {
            const auto found = values.find(key);
            return found == values.end() ? std::string{} : found->second;
        }
        std::mutex mutex_;
        std::unordered_map<Key, std::string> names_;
        std::unordered_map<Key, std::string> descriptions_;
    };

    template <typename Key>
    cache<Key>& process_cache()
    {
        // Retail threads can still register/read dvars during CRT shutdown.
        // Keep this registry and its mutex alive until Windows reclaims the
        // process. The trivial pointer has no destructive atexit callback.
        static auto* const instance = new cache<Key>();
        return *instance;
    }
}
