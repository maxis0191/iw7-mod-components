#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "../../src/native/paris_log_stream.hpp"

// The kept game log handle (a51): the bytes on disk are those of opening the file in append mode, writing and closing for every line (the old
// utils::io::write_file), in the same order, once flushed; nothing is lost at close; a directory that does not exist is created.
static int failures;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++failures; } } while (0)

static std::string slurp(const std::filesystem::path& p) {
    std::ifstream in(p, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

// the way G_LogPrintf wrote before
static void legacy_append(const std::string& file, const std::string& data) {
    const auto pos = file.find_last_of("/\\");
    if (pos != std::string::npos) std::filesystem::create_directories(file.substr(0, pos));
    std::ofstream s(file, std::ios::binary | std::ofstream::out | std::ofstream::app);
    s.write(data.data(), static_cast<std::streamsize>(data.size()));
}

int main() {
    const auto root = std::filesystem::temp_directory_path() / "iw7-log-stream-test";
    std::filesystem::remove_all(root);
    const std::string a = (root / "new dir" / "a.log").generic_string();
    const std::string b = (root / "b.log").generic_string();
    const std::string ra = (root / "ref" / "a.log").generic_string();
    const std::string rb = (root / "ref" / "b.log").generic_string();

    paris_log_stream::append_log log;
    std::vector<std::string> lines;
    for (int i = 0; i < 5000; ++i) {
        std::ostringstream o;
        o << ' ' << i / 60 << ':' << i % 60 / 10 << i % 60 % 10 << " D;guid" << i << ";" << i % 200 << ";axis;zombie;guid;0;allies;player;weapon_" << i << ";" << i % 150 << ";MOD;torso\n";
        lines.push_back(o.str());
    }
    for (int i = 0; i < 5000; ++i) {
        const bool first = (i % 3) != 0;
        CHECK(log.append(first ? a : b, lines[i]));
        legacy_append(first ? ra : rb, lines[i]);
        if (i % 250 == 0) log.flush();
    }
    log.flush();
    CHECK(log.open_count() == 2);
    CHECK(slurp(a) == slurp(ra) && !slurp(a).empty());
    CHECK(slurp(b) == slurp(rb) && !slurp(b).empty());

    // data in the buffer reaches the file at close, an existing file is appended to (never truncated), bytes with CR, LF and NUL are kept
    const std::string extra = std::string("x\r\ny\0z\n", 7);
    CHECK(log.append(a, extra));
    log.close_all();
    CHECK(log.open_count() == 0);
    legacy_append(ra, extra);
    CHECK(slurp(a) == slurp(ra));
    CHECK(log.append(a, "after reopen\n"));
    log.flush();
    legacy_append(ra, "after reopen\n");
    CHECK(slurp(a) == slurp(ra));

    // a second writer of the same file (another process, a tool) appends at the end, both orders are kept
    legacy_append(a, "foreign\n");
    CHECK(log.append(a, "mine\n"));
    log.flush();
    const auto text = slurp(a);
    CHECK(text.size() > 20 && text.substr(text.size() - 13) == "foreign\nmine\n");

    // a path that cannot be opened is refused, the caller falls back
    CHECK(!log.append((root / "b.log" / "inside-a-file.log").generic_string(), "x\n"));

    // more paths than handles: the oldest is closed after its data went out
    for (int i = 0; i < 12; ++i) {
        const auto p = (root / ("many" + std::to_string(i) + ".log")).generic_string();
        CHECK(log.append(p, "line\n"));
    }
    CHECK(log.open_count() <= 8);
    log.flush();
    for (int i = 0; i < 12; ++i) CHECK(slurp(root / ("many" + std::to_string(i) + ".log")) == "line\n");

    // two threads writing: every line arrives whole
    const std::string t = (root / "threads.log").generic_string();
    auto work = [&](char c) { for (int i = 0; i < 2000; ++i) log.append(t, std::string(1, c) + std::string(30, c) + "\n"); };
    std::thread t1(work, 'p'), t2(work, 'q');
    for (int i = 0; i < 20; ++i) { log.flush(); std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
    t1.join(); t2.join();
    log.close_all();
    {
        std::ifstream in(t, std::ios::binary);
        std::string line;
        int n = 0;
        while (std::getline(in, line)) {
            ++n;
            CHECK(line.size() == 31 && line.find_first_not_of(line[0]) == std::string::npos);
        }
        CHECK(n == 4000);
    }

    std::filesystem::remove_all(root);
    if (failures) { std::printf("%d failure(s)\n", failures); return 1; }
    std::printf("log stream test: ok\n");
    return 0;
}
