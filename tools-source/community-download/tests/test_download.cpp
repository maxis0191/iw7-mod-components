#include "download.cpp"

namespace
{
    const std::string destination = "mods/test/mod.ff";
    const std::string old_bytes = "previous working mod";
    std::string payload(140000, 'x'); // crosses multiple write/read boundaries
    unsigned passed = 0;

    std::string read_bytes(const std::string& path)
    {
        std::ifstream file(path, std::ios::binary);
        return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
    }
    void reset()
    {
        for (auto& queue : scheduler::queues) queue.clear();
        scheduler::reject_queue = false; scheduler::executing = scheduler::main;
        scheduler::before_enqueue = {};
        fake::fault.clear(); fake::close_calls = fake::move_calls = fake::http_calls = fake::connect_calls = 0;
        fake::errors.clear(); fake::events.clear();
        fake::during_http = fake::during_write = fake::during_read = fake::before_move = {};
        fake::during_connect = {};
        download::kill_downloads = false;
        download::globals.access([](auto& state) { state = {}; });
        std::filesystem::create_directories("mods/test");
        for (const auto& entry : std::filesystem::directory_iterator("mods/test")) std::filesystem::remove(entry);
        std::ofstream(destination, std::ios::binary) << old_bytes;
        utils::http::response = utils::http::result{0, 200, payload};
    }
    void start(const std::string& hash = {}, const std::string& base = "https://invalid.test")
    {
        download::start_download({}, utils::info_string{base}, {{destination, hash.empty() ? utils::hash::get_buffer_hash(payload, destination) : hash}});
    }
    void drain()
    {
        for (unsigned i = 0; i != 100; ++i)
        {
            bool work = false;
            for (const auto p : {scheduler::async, scheduler::main, scheduler::lui}) work = scheduler::tick(p) || work;
            if (!work) return;
        }
        throw std::runtime_error("scheduler did not quiesce");
    }
    void no_temporary_files()
    {
        for (const auto& entry : std::filesystem::directory_iterator("mods/test"))
            fake::require(entry.path().extension() != ".tmp", "temporary file leaked");
    }
    void failed(bool preserved = true)
    {
        drain();
        fake::require(fake::connect_calls == 0, "reconnect after error/cancel");
        fake::require(fake::errors.size() == 1, "missing or repeated error UI");
        fake::require(fake::errors.front().find("private URL") == std::string::npos, "technical details leaked to UI");
        fake::require(std::count(fake::events.begin(), fake::events.end(), "mod_download_done") == 1, "terminal UI count");
        fake::require(!download::globals.access<bool>([](auto& s) { return s.active; }), "active flag stuck");
        if (preserved) fake::require(read_bytes(destination) == old_bytes, "previous file modified on failure");
        no_temporary_files();
    }
    void test(const std::string& name, const std::function<void()>& run)
    {
        reset(); run(); ++passed; std::cout << "PASS " << name << '\n';
    }
}

int main()
{
    try
    {
        std::string vector = "123456789";
        fake::require(utils::hash::get_buffer_hash(vector, "mod.ff") == "2639F4CB", "CRC fixture differs from native protocol");
        test("successful replacement and correct scheduler threads", []
        {
            start(); drain();
            fake::require(read_bytes(destination) == payload, "replacement differs");
            fake::require(fake::connect_calls == 1 && fake::errors.empty() && fake::move_calls == 1, "success terminal state");
            no_temporary_files();
        });
        test("successful first install", []
        { std::filesystem::remove(destination); start(); drain(); fake::require(read_bytes(destination) == payload && fake::connect_calls == 1, "first install failed"); no_temporary_files(); });
        test("missing URL", [] { start({}, ""); failed(); fake::require(fake::http_calls == 0, "HTTP without base"); });
        test("HTTP absent", [] { utils::http::response.reset(); start(); failed(); });
        for (const auto status : {0u, 199u, 302u, 404u, 500u})
            test("HTTP status " + std::to_string(status), [=] { utils::http::response->response_code = status; start(); failed(); });
        test("curl connection refused", [] { utils::http::response->code = 7; start(); failed(); });
        test("CRC mismatch", [] { start("FFFFFFFF"); failed(); fake::require(fake::close_calls == 0, "opened temp before CRC verification"); });
        for (const auto fault : {"http_throw", "http_nonstd", "create", "write", "short_write", "flush", "close_write", "reopen", "size", "wrong_size", "read", "short_read", "corrupt_read", "close_read", "replace"})
            test(fault, [=] { fake::fault = fault; start(); failed(); });
        test("actual locked destination refuses replacement", []
        {
            const auto held = ::CreateFileA(destination.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
            fake::require(held != INVALID_HANDLE_VALUE, "lock setup failed");
            start(); failed();
            fake::require(fake::close(held) != 0, "lock cleanup failed");
        });
        test("cancel queued worker", [] { start(); download::stop_download(); failed(); fake::require(fake::http_calls == 0, "cancelled worker used HTTP"); });
        test("cancel HTTP", [] { fake::during_http = [] { download::stop_download(); }; start(); failed(); });
        test("cancel while writing", [] { fake::during_write = [] { download::stop_download(); }; start(); failed(); });
        test("cancel while verifying disk", [] { fake::during_read = [] { download::stop_download(); }; start(); failed(); });
        test("cancel after publication before main reconnect", []
        {
            start(); scheduler::tick(scheduler::async); download::stop_download(); failed(false);
            fake::require(read_bytes(destination) == payload, "published verified file lost");
        });
        test("cancel at rename commit point", []
        { fake::before_move = [] { download::stop_download(); }; start(); failed(false); fake::require(read_bytes(destination) == payload, "rename result corrupted"); });
        test("repeat stop emits one terminal notification", [] { start(); download::stop_download(); download::stop_download(); failed(); });
        test("deferred duplicate does not reconnect after error", [] { utils::http::response.reset(); start(); start(); failed(); fake::require(fake::http_calls == 1, "failed operation retried automatically"); });
        test("deferred duplicate does not restart after cancel", [] { start(); start(); download::stop_download(); failed(); fake::require(fake::http_calls == 0, "cancelled operation restarted"); });
        test("party stop-start replaces a pending download", []
        {
            start(); download::stop_download(); start(); drain();
            fake::require(fake::connect_calls == 1 && fake::http_calls == 1 && read_bytes(destination) == payload, "explicit party replacement lost");
        });
        test("later stop cancels the queued party replacement", []
        { start(); download::stop_download(); start(); download::stop_download(); failed(); fake::require(fake::http_calls == 0, "replacement survived later cancellation"); });
        test("one later file failing prevents connection for the set", []
        {
            const std::string other = "mods/test/mod.sabl";
            std::ofstream(other, std::ios::binary) << old_bytes;
            fake::during_http = [] { if (fake::http_calls == 2) utils::http::response.reset(); };
            const auto hash = utils::hash::get_buffer_hash(payload, destination);
            download::start_download({}, {}, {{destination, hash}, {other, hash}});
            failed(false);
            fake::require(read_bytes(destination) == payload && read_bytes(other) == old_bytes, "per-file commit boundary violated");
        });
        test("explicit retry succeeds after failure", []
        { utils::http::response.reset(); start(); failed(); fake::errors.clear(); utils::http::response = utils::http::result{0, 200, payload}; start(); drain(); fake::require(fake::connect_calls == 1 && fake::errors.empty(), "explicit retry failed"); });
        test("shutdown suppresses reconnect and UI", []
        { start(); scheduler::tick(scheduler::async); download::component{}.pre_destroy(); drain(); fake::require(fake::connect_calls == 0 && fake::errors.empty() && fake::events.empty(), "callback after shutdown"); });
        test("scheduler queue failure cannot escape worker", []
        { start(); scheduler::reject_queue = true; scheduler::tick(scheduler::async); scheduler::reject_queue = false; drain(); fake::require(fake::connect_calls == 0 && !download::globals.access<bool>([](auto& s) { return s.active; }), "queue failure left connect/active"); fake::require(read_bytes(destination) == old_bytes, "queue failure changed file"); });
        test("main terminal LUI enqueue refusal cannot escape or reconnect", []
        {
            start(); scheduler::tick(scheduler::async);
            scheduler::reject_queue = true; scheduler::tick(scheduler::main); scheduler::reject_queue = false;
            drain();
            fake::require(fake::connect_calls == 0 && fake::errors.size() == 1, "main enqueue refusal did not fail closed");
            fake::require(download::globals.access<bool>([](auto& s) { return s.abort && !s.active; }), "main enqueue failure left operation active");
            fake::require(read_bytes(destination) == payload, "verified file lost after terminal enqueue refusal");
            fake::require(std::count(fake::events.begin(), fake::events.end(), "mod_download_done") == 0, "refused enqueue was delivered");
            no_temporary_files();
        });
        test("concurrent cancel during main LUI enqueue wins before terminal commit", []
        {
            start(); scheduler::tick(scheduler::async);
            scheduler::before_enqueue = [](scheduler::pipeline target_pipeline)
            {
                if (scheduler::executing == scheduler::main && target_pipeline == scheduler::lui)
                {
                    // Run the actual stop on a second thread while main is in its
                    // enqueue, then join before allowing the final decision.
                    std::thread cancel([] { download::stop_download(); }); cancel.join();
                }
            };
            scheduler::tick(scheduler::main); scheduler::before_enqueue = {};
            failed(false);
            fake::require(read_bytes(destination) == payload, "committed file changed on late cancellation");
        });
        test("stop after terminal commit does not retract connect or deadlock", []
        {
            fake::during_connect = []
            {
                fake::require(!download::globals.access<bool>([](auto& s) { return s.active; }), "connect before terminal commit");
                // This would deadlock if the production path held globals across connect.
                std::thread cancel([] { download::stop_download(); }); cancel.join();
            };
            start(); drain();
            fake::require(fake::connect_calls == 1 && fake::errors.empty(), "post-commit stop incorrectly rewound completion");
        });
        test("stale LUI completion cannot dismiss a newer download", []
        {
            start(); scheduler::tick(scheduler::async); scheduler::tick(scheduler::main);
            start(); while (scheduler::tick(scheduler::lui)) {}
            fake::require(std::count(fake::events.begin(), fake::events.end(), "mod_download_done") == 0, "stale completion reached UI");
            drain(); fake::require(fake::connect_calls == 2, "new download did not finish");
        });
        std::cout << "RESULT " << passed << " passed\n";
        return 0;
    }
    catch (const std::exception& e) { std::cerr << "FAIL " << e.what() << '\n'; return 1; }
    catch (...) { std::cerr << "FAIL non-standard exception escaped\n"; return 2; }
}
