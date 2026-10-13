#include "../../src/native/dvar_metadata.hpp"
#include <array>
#include <atomic>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>

namespace
{
    struct late_reader
    {
        ~late_reader()
        {
            // Constructed before the process cache; an ordinary function-static
            // map would already be destroyed when this late user runs.
            auto& store = iw7::metadata::process_cache<unsigned>();
            if (store.name(999) != "late-name" || store.description(999) != "late-description")
                std::terminate();
            store.name(999, "late-write");
            std::cout << "Late shutdown metadata access passed.\n";
        }
    };
    late_reader last;
}

int main()
{
    try
    {
        auto& store = iw7::metadata::process_cache<unsigned>();
        if (!store.name(0).empty() || !store.description(0).empty())
            throw std::runtime_error("missing metadata must be empty");
        store.name(999, "late-name");
        store.description(999, "late-description");
        std::atomic<bool> start{false}, invalid{false};
        std::atomic<unsigned> completed{0};
        std::vector<std::thread> threads;
        for (unsigned writer = 0; writer < 4; ++writer)
            threads.emplace_back([&, writer] {
                while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
                for (unsigned i = 0; i < 50000; ++i)
                {
                    const unsigned key = (i * 17 + writer) % 257;
                    const auto value = "name:" + std::to_string(writer) + ":" + std::to_string(i);
                    store.name(key, value);
                    store.description(key, "description:" + value);
                }
                ++completed;
            });
        for (unsigned reader = 0; reader < 4; ++reader)
            threads.emplace_back([&, reader] {
                while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
                for (unsigned i = 0; i < 50000 || completed.load() != 4; ++i)
                {
                    const unsigned key = (i * 31 + reader) % 257;
                    const auto name = store.name(key);
                    const auto description = store.description(key);
                    if ((!name.empty() && name.rfind("name:", 0) != 0) ||
                        (!description.empty() && description.rfind("description:name:", 0) != 0))
                        invalid = true;
                }
            });
        start.store(true, std::memory_order_release);
        for (auto& thread : threads) thread.join();
        if (invalid) throw std::runtime_error("concurrent metadata copy corrupted");
        for (unsigned key = 0; key < 257; ++key)
        {
            store.name(key, "final:" + std::to_string(key));
            if (store.name(key) != "final:" + std::to_string(key))
                throw std::runtime_error("replacement metadata mismatch");
        }
        std::cout << "Metadata concurrency test passed: 4 writers, 4 readers, 200000 name/description updates.\n";
        return 0;
    }
    catch (const std::exception& error)
    {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
