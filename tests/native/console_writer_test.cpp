#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../../src/native/paris_console_writer.hpp"

// The console writer ring and thread (docs/CONSOLE-WRITER.md), without the game: order and bytes, a full ring drops and counts and says so in place,
// several producers, a sink that stalls does not stall the producer, shutdown writes what is queued, a closed writer refuses lines.
static int failures;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++failures; } } while (0)

using namespace paris_console_writer;

namespace
{
    struct recorder
    {
        std::mutex mutex;
        std::vector<std::string> lines;
        std::atomic<int> batches{ 0 };

        void add(const int, const std::string& text)
        {
            std::lock_guard<std::mutex> lock(mutex);
            lines.push_back(text);
        }

        std::vector<std::string> get()
        {
            std::lock_guard<std::mutex> lock(mutex);
            return lines;
        }
    };

    std::vector<std::string> without_stats(const std::vector<std::string>& in)
    {
        std::vector<std::string> out;
        for (const auto& l : in)
        {
            if (l.rfind("[console writer] queued=", 0) != 0)
            {
                out.push_back(l);
            }
        }
        return out;
    }

    bool contains_line(const std::vector<std::string>& lines, const std::string& text)
    {
        for (const auto& l : lines)
        {
            if (l == text)
            {
                return true;
            }
        }
        return false;
    }
}

static void ring_order_and_bytes()
{
    queue q(8, 1024);
    std::vector<line> out;
    std::uint32_t trailing = 0;

    CHECK(q.push(7, "alpha\n", 6) == push_result::accepted);
    CHECK(q.push(1, "be\0ta\n", 6) == push_result::accepted); // embedded NUL stays
    CHECK(q.push(3, "", 0) == push_result::accepted);
    CHECK(q.size() == 3);
    const auto n = q.pop_wait(out, 16, std::chrono::milliseconds(0), trailing);
    CHECK(n == 3);
    CHECK(out[0].text == "alpha\n" && out[0].type == 7);
    CHECK(out[1].text == std::string("be\0ta\n", 6) && out[1].type == 1);
    CHECK(out[2].text.empty() && out[2].type == 3);
    CHECK(trailing == 0);
    CHECK(q.size() == 0);
    CHECK(q.queued() == 3);
}

static void ring_wraps()
{
    queue q(4, 1024);
    std::vector<line> out;
    std::uint32_t trailing = 0;
    int next = 0;
    int expect = 0;
    for (int round = 0; round < 50; ++round)
    {
        for (int i = 0; i < 3; ++i)
        {
            const auto text = std::to_string(next++);
            CHECK(q.push(7, text.data(), text.size()) == push_result::accepted);
        }
        // even rounds pop two of three (a rest stays queued across the wrap), odd rounds pop everything
        const auto n = q.pop_wait(out, round % 2 == 0 ? 2 : 4, std::chrono::milliseconds(0), trailing);
        for (std::size_t i = 0; i < n; ++i)
        {
            CHECK(out[i].text == std::to_string(expect++));
        }
    }
    const auto n = q.pop_wait(out, 100, std::chrono::milliseconds(0), trailing);
    for (std::size_t i = 0; i < n; ++i)
    {
        CHECK(out[i].text == std::to_string(expect++));
    }
    CHECK(expect == next);
    CHECK(q.dropped() == 0);
}

static void ring_full_drops_and_counts()
{
    queue q(4, 1024);
    std::vector<line> out;
    std::uint32_t trailing = 0;

    for (int i = 0; i < 4; ++i)
    {
        CHECK(q.push(7, "x", 1) == push_result::accepted);
    }
    CHECK(q.push(7, "y", 1) == push_result::dropped);
    CHECK(q.push(7, "y", 1) == push_result::dropped);
    CHECK(q.dropped() == 2);
    CHECK(q.queued() == 4);

    // the gap comes after the four lines that were accepted, with nothing after it: it is the trailing gap
    auto n = q.pop_wait(out, 3, std::chrono::milliseconds(0), trailing);
    CHECK(n == 3 && trailing == 0); // one line is still queued: the gap waits for the line that comes after it
    n = q.pop_wait(out, 3, std::chrono::milliseconds(0), trailing);
    CHECK(n == 1 && trailing == 2);

    // a gap between two accepted lines is carried by the line after it
    for (int i = 0; i < 4; ++i)
    {
        CHECK(q.push(7, "a", 1) == push_result::accepted);
    }
    CHECK(q.push(7, "z", 1) == push_result::dropped);
    n = q.pop_wait(out, 1, std::chrono::milliseconds(0), trailing);
    CHECK(n == 1);
    CHECK(q.push(7, "b", 1) == push_result::accepted);
    n = q.pop_wait(out, 16, std::chrono::milliseconds(0), trailing);
    CHECK(n == 4);
    CHECK(out[0].gap == 0 && out[1].gap == 0 && out[2].gap == 0 && out[3].gap == 1 && out[3].text == "b");
}

static void ring_byte_limit()
{
    queue q(100, 10);
    CHECK(q.push(7, "12345678", 8) == push_result::accepted);
    CHECK(q.push(7, "123", 3) == push_result::dropped); // 11 bytes
    CHECK(q.push(7, "12", 2) == push_result::accepted);  // exactly 10
    CHECK(q.push(7, "12345678901", 11) == push_result::dropped); // larger than the whole ring
    CHECK(q.dropped() == 2);
    std::vector<line> out;
    std::uint32_t trailing = 0;
    CHECK(q.pop_wait(out, 10, std::chrono::milliseconds(0), trailing) == 2);
    CHECK(q.push(7, "12345678", 8) == push_result::accepted); // the bytes came back
}

static void ring_close_and_try_pop()
{
    queue q(4, 64);
    CHECK(q.push(7, "a", 1) == push_result::accepted);
    std::vector<line> out;
    std::size_t n = 0;
    std::uint32_t trailing = 0;
    CHECK(q.try_pop_all(out, n, trailing));
    CHECK(n == 1 && out[0].text == "a");
    q.close();
    CHECK(q.closed());
    CHECK(q.push(7, "b", 1) == push_result::closed);
    // a closed, empty ring does not wait
    const auto begin = std::chrono::steady_clock::now();
    CHECK(q.pop_wait(out, 4, std::chrono::seconds(5), trailing) == 0);
    CHECK(std::chrono::steady_clock::now() - begin < std::chrono::seconds(2));
}

static void writer_order_and_flush_on_stop()
{
    recorder rec;
    std::atomic<int> batches{ 0 };
    writer w([&rec](const int type, const std::string& text) { rec.add(type, text); }, [&batches] { ++batches; });
    CHECK(!w.submit(7, "before start\n")); // not running: the caller prints
    w.start();
    for (int i = 0; i < 1000; ++i)
    {
        CHECK(w.submit(7, "line " + std::to_string(i) + "\n"));
    }
    w.stop(); // writes what is queued, then the final counters
    const auto lines = rec.get();
    const auto plain = without_stats(lines);
    CHECK(plain.size() == 1000);
    for (std::size_t i = 0; i < plain.size() && i < 1000; ++i)
    {
        CHECK(plain[i] == "line " + std::to_string(i) + "\n");
    }
    CHECK(lines.size() == 1001 && lines.back().rfind("[console writer] queued=1000 written=1000 dropped=0", 0) == 0);
    CHECK(batches.load() >= 1);
    CHECK(!w.submit(7, "after stop\n"));
    const auto c = w.get();
    CHECK(c.queued == 1000 && c.written == 1000 && c.dropped == 0);
    w.stop(); // idempotent
}

static void writer_slow_sink_does_not_block_producer()
{
    recorder rec;
    // 20 ms a line: 100 lines would take 2 s on the producer's thread
    writer w([&rec](const int type, const std::string& text)
    {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        rec.add(type, text);
    }, nullptr, 4096, 1u << 20);
    w.start();
    const auto begin = std::chrono::steady_clock::now();
    for (int i = 0; i < 100; ++i)
    {
        CHECK(w.submit(7, "slow " + std::to_string(i) + "\n"));
    }
    const auto producer_ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - begin).count();
    CHECK(producer_ms < 500);
    w.stop(std::chrono::milliseconds(10000));
    const auto plain = without_stats(rec.get());
    CHECK(plain.size() == 100);
    for (std::size_t i = 0; i < plain.size() && i < 100; ++i)
    {
        CHECK(plain[i] == "slow " + std::to_string(i) + "\n");
    }
    const auto c = w.get();
    CHECK(c.max_enqueue_us < 200000);
    CHECK(c.max_sink_write_us >= 15000);
}

static void writer_full_ring_drops_and_says_so()
{
    recorder rec;
    std::mutex gate;
    gate.lock(); // the sink waits here: the ring fills
    std::atomic<bool> first_seen{ false };
    writer w([&](const int type, const std::string& text)
    {
        first_seen = true;
        std::lock_guard<std::mutex> hold(gate);
        rec.add(type, text);
    }, nullptr, 8, 1u << 20);
    w.start();
    CHECK(w.submit(7, "first\n"));
    for (int i = 0; i < 2000 && !first_seen; ++i)
    {
        std::this_thread::sleep_for(std::chrono::milliseconds(1)); // wait until the writer holds the first line inside the sink
    }
    CHECK(first_seen.load());
    int accepted = 0;
    for (int i = 0; i < 50; ++i)
    {
        CHECK(w.submit(7, "fill " + std::to_string(i) + "\n")); // a drop still consumes the line: submit does not fail
        ++accepted;
    }
    CHECK(accepted == 50);
    gate.unlock();
    w.stop(std::chrono::milliseconds(10000));
    const auto c = w.get();
    CHECK(c.dropped == 50 - 8);   // the ring holds 8; the first line was already out of it
    CHECK(c.queued == 1 + 8);
    const auto lines = rec.get();
    const auto plain = without_stats(lines);
    // first, 8 filled lines in order, and one notice for the 42 lines dropped after them
    CHECK(plain.size() == 1 + 8 + 1);
    CHECK(plain[0] == "first\n");
    for (int i = 0; i < 8 && 1 + i < static_cast<int>(plain.size()); ++i)
    {
        CHECK(plain[1 + i] == "fill " + std::to_string(i) + "\n");
    }
    CHECK(contains_line(plain, "[console writer] dropped 42 lines\n"));
    CHECK(plain.back() == "[console writer] dropped 42 lines\n");
    CHECK(lines.back().rfind("[console writer] queued=9 written=9 dropped=42", 0) == 0);
}

static void writer_drained_means_written_and_flushed()
{
    recorder rec;
    std::mutex gate;
    gate.lock();
    std::atomic<bool> in_sink{ false };
    std::atomic<int> flushes{ 0 };
    writer w([&](const int type, const std::string& text)
    {
        in_sink = true;
        std::lock_guard<std::mutex> hold(gate);
        rec.add(type, text);
    }, [&flushes] { ++flushes; });
    CHECK(w.wait_until_drained(std::chrono::milliseconds(10))); // not running: nothing to wait for
    w.start();
    CHECK(w.wait_until_drained(std::chrono::milliseconds(10))); // nothing accepted yet
    CHECK(w.submit(7, "crash line\n"));
    for (int i = 0; i < 2000 && !in_sink; ++i)
    {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    CHECK(in_sink.load()); // the ring is empty now, the line is inside the sink: it is not drained
    CHECK(w.ring().size() == 0);
    CHECK(!w.wait_until_drained(std::chrono::milliseconds(30)));
    gate.unlock();
    CHECK(w.wait_until_drained(std::chrono::seconds(5)));
    CHECK(flushes.load() >= 1); // done is counted after the flush of the batch
    CHECK(rec.get().size() == 1);
    w.stop();
}

static void writer_several_producers()
{
    recorder rec;
    writer w([&rec](const int type, const std::string& text) { rec.add(type, text); }, nullptr, 1u << 16, 1u << 24);
    w.start();
    constexpr int producers = 6;
    constexpr int each = 5000;
    std::vector<std::thread> threads;
    for (int p = 0; p < producers; ++p)
    {
        threads.emplace_back([&w, p]
        {
            for (int i = 0; i < each; ++i)
            {
                w.submit(7, "p" + std::to_string(p) + " " + std::to_string(i) + "\n");
            }
        });
    }
    for (auto& t : threads)
    {
        t.join();
    }
    w.stop(std::chrono::milliseconds(10000));
    const auto c = w.get();
    CHECK(c.dropped == 0);
    CHECK(c.queued == static_cast<std::uint64_t>(producers) * each);
    const auto plain = without_stats(rec.get());
    CHECK(plain.size() == static_cast<std::size_t>(producers) * each);
    // each producer's own lines arrive in the order it printed them
    std::vector<int> next(producers, 0);
    for (const auto& l : plain)
    {
        const int p = l[1] - '0';
        const int i = std::stoi(l.substr(3));
        if (p < 0 || p >= producers || i != next[p])
        {
            std::printf("FAIL line %d: producer order\n", __LINE__);
            ++failures;
            break;
        }
        ++next[p];
    }
    for (int p = 0; p < producers; ++p)
    {
        CHECK(next[p] == each);
    }
}

static void writer_sink_exception_keeps_thread()
{
    recorder rec;
    std::atomic<int> calls{ 0 };
    writer w([&](const int type, const std::string& text)
    {
        if (++calls == 2)
        {
            throw 1;
        }
        rec.add(type, text);
    }, nullptr);
    w.start();
    for (int i = 0; i < 5; ++i)
    {
        w.submit(7, "e" + std::to_string(i) + "\n");
    }
    w.stop();
    const auto plain = without_stats(rec.get());
    CHECK(plain.size() >= 4); // the line whose write threw is lost, the rest arrive
}

static void format_line()
{
    counters c;
    c.queued = 5;
    c.written = 4;
    c.dropped = 1;
    c.max_enqueue_us = 12;
    c.max_sink_write_us = 345;
    c.slow_sink_writes = 2;
    CHECK(writer::format(c) == "[console writer] queued=5 written=4 dropped=1 max_enqueue_us=12 max_sink_write_us=345 slow_sink_writes=2\n");
}

int main()
{
    ring_order_and_bytes();
    ring_wraps();
    ring_full_drops_and_counts();
    ring_byte_limit();
    ring_close_and_try_pop();
    writer_order_and_flush_on_stop();
    writer_slow_sink_does_not_block_producer();
    writer_full_ring_drops_and_says_so();
    writer_drained_means_written_and_flushed();
    writer_several_producers();
    writer_sink_exception_keeps_thread();
    format_line();
    CHECK(!submit(7, "nothing active\n")); // no writer set: the caller prints
    if (failures)
    {
        std::printf("console writer test: %d failure(s)\n", failures);
        return 1;
    }
    std::printf("console writer test: ok\n");
    return 0;
}
