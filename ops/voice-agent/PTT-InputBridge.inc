// Injected only into the exact pinned CP input.cpp, after its anonymous owner
// namespace. Ordinary cl_execute_key_stub and its 118-binding dispatch remain
// byte-identical source. No key writes, device calls or capture/ARM authority.
    namespace
    {
        std::array<unsigned char, voice_ptt_guard::entry_size> voice_ptt_before_bytes{};
        voice_ptt_guard::owner voice_ptt_owner{};
        voice_ptt_guard::refusal voice_ptt_prehook_reason{voice_ptt_guard::refusal::owner_not_recorded};
        unsigned voice_ptt_capture_attempts{};
        DWORD voice_ptt_capture_tid{};

        bool voice_ptt_private_scope()
        {
            return !game::environment::is_dedi() && utils::flags::has_flag("paris-isolated-lab") &&
                utils::flags::has_flag("paris-server-client-test") && utils::flags::has_flag("paris-voice-fake-capture") &&
                utils::flags::has_flag("paris-voice-audio-lab") && utils::flags::has_flag("iw7-voice-relay");
        }
        voice_ptt_guard::bytes voice_ptt_region(std::uintptr_t address)
        {
            voice_ptt_guard::bytes view; view.address = address;
            MEMORY_BASIC_INFORMATION memory{};
            if (!address || VirtualQuery(reinterpret_cast<const void*>(address), &memory, sizeof(memory)) != sizeof(memory)) return view;
            const DWORD access = memory.Protect & 0xff;
            view.memory = {reinterpret_cast<std::uintptr_t>(memory.BaseAddress), memory.RegionSize, memory.State == MEM_COMMIT,
                access == PAGE_READONLY || access == PAGE_READWRITE || access == PAGE_WRITECOPY ||
                access == PAGE_EXECUTE_READ || access == PAGE_EXECUTE_READWRITE || access == PAGE_EXECUTE_WRITECOPY,
                access == PAGE_EXECUTE || access == PAGE_EXECUTE_READ || access == PAGE_EXECUTE_READWRITE || access == PAGE_EXECUTE_WRITECOPY,
                (memory.Protect & PAGE_GUARD) != 0, access == PAGE_NOACCESS};
            return view;
        }
        template <std::size_t N>
        voice_ptt_guard::bytes voice_ptt_copy(std::uintptr_t address, std::array<unsigned char, N>& destination, bool code)
        {
            auto view = voice_ptt_region(address);
            if (voice_ptt_guard::readable(view, address, N, code))
            {
                std::memcpy(destination.data(), reinterpret_cast<const void*>(address), N);
                view.data = destination.data(); view.size = N;
            }
            return view;
        }
        void voice_ptt_log(const char* phase, const voice_ptt_guard::result& result, unsigned long expected_main = 0,
            const voice_ptt_guard::observation* sample = nullptr)
        {
            // This runs only in the admitted private scope on the main thread.
            // Keep first/changed refusal evidence; bound unchanged output to 1 Hz.
            static voice_ptt_guard::refusal previous{voice_ptt_guard::refusal::owner_not_recorded};
            static ULONGLONG previous_tick{};
            static unsigned previous_active{}, previous_getter{};
            static bool previous_live{};
            const auto now = GetTickCount64();
            const bool live = sample != nullptr;
            if (previous_tick && result.reason == previous && result.active == previous_active && result.getter_active == previous_getter && live == previous_live && now - previous_tick < 1000) return;
            previous = result.reason; previous_tick = now; previous_active = result.active; previous_getter = result.getter_active; previous_live = live;
            std::printf("[paris-voice-ptt] Guard phase=%s pid=%lu thread_tid=%lu expected_main_tid=%lu capture_tid=%lu reason=%s code_validated=%u entry=%llx owner_place=%llx original=%llx observed_place=%llx observed_original=%llx observed_stub=%llx patch_target=%llx back_target=%llx stub=%llx relay_stub=%llx getter=%llx getter_target=%llx state=%llx active=%u getter_active=%u tick_ms=%llu\n",
                phase, GetCurrentProcessId(), GetCurrentThreadId(), expected_main, voice_ptt_capture_tid, voice_ptt_guard::name(result.reason),
                static_cast<unsigned>(result.code_validated), static_cast<unsigned long long>(voice_ptt_guard::entry_address),
                static_cast<unsigned long long>(voice_ptt_owner.place), static_cast<unsigned long long>(voice_ptt_owner.original),
                static_cast<unsigned long long>(sample ? sample->observed_place : 0), static_cast<unsigned long long>(sample ? sample->observed_original : 0),
                static_cast<unsigned long long>(sample ? sample->observed_stub : 0),
                static_cast<unsigned long long>(result.relay_target), static_cast<unsigned long long>(result.trampoline_target),
                static_cast<unsigned long long>(voice_ptt_owner.stub), static_cast<unsigned long long>(result.stub_target),
                static_cast<unsigned long long>(voice_ptt_guard::getter_address), static_cast<unsigned long long>(result.getter_target),
                static_cast<unsigned long long>(voice_ptt_guard::state_address), result.active, result.getter_active, now);
            std::fflush(stdout);
        }
        void voice_ptt_capture_before_hook()
        {
            if (!voice_ptt_private_scope()) return;
            if (++voice_ptt_capture_attempts != 1)
            {
                voice_ptt_prehook_reason = voice_ptt_guard::refusal::owner_not_recorded;
                return;
            }
            voice_ptt_capture_tid = GetCurrentThreadId();
            voice_ptt_owner.before = voice_ptt_copy(voice_ptt_guard::entry_address, voice_ptt_before_bytes, true);
            voice_ptt_prehook_reason = voice_ptt_guard::validate_before_hook(voice_ptt_owner.before);
            voice_ptt_guard::result proof; proof.reason = voice_ptt_prehook_reason;
            voice_ptt_log("prehook", proof);
        }
        void voice_ptt_capture_owned_hook()
        {
            if (!voice_ptt_private_scope() || voice_ptt_capture_attempts != 1 || voice_ptt_prehook_reason != voice_ptt_guard::refusal::none) return;
            // The actual owner, never a PID lookup or caller-provided detour.
            voice_ptt_owner.place = reinterpret_cast<std::uintptr_t>(cl_execute_key_hook.get_place());
            voice_ptt_owner.original = reinterpret_cast<std::uintptr_t>(cl_execute_key_hook.get_original());
            voice_ptt_owner.stub = reinterpret_cast<std::uintptr_t>(&cl_execute_key_stub);
        }
    }
    voice_ptt_guard::result read_voice_ptt_snapshot(unsigned char* destination, std::size_t size, unsigned long main_thread)
    {
        voice_ptt_guard::result proof;
        if (!voice_ptt_private_scope()) { proof.reason = voice_ptt_guard::refusal::scope; return proof; }
        if (!main_thread || GetCurrentThreadId() != main_thread) { proof.reason = voice_ptt_guard::refusal::main_thread; return proof; }
        if (!destination || size != voice_ptt_guard::state_size) { proof.reason = voice_ptt_guard::refusal::output_buffer; voice_ptt_log("live", proof, main_thread); return proof; }
        if (voice_ptt_capture_attempts != 1 || voice_ptt_prehook_reason != voice_ptt_guard::refusal::none)
        {
            proof.reason = voice_ptt_prehook_reason; voice_ptt_log("live", proof, main_thread); return proof;
        }
        std::array<unsigned char, voice_ptt_guard::entry_size> entry{};
        std::array<unsigned char, voice_ptt_guard::trampoline_size> trampoline{};
        std::array<unsigned char, voice_ptt_guard::relay_size> relay{};
        std::array<unsigned char, voice_ptt_guard::getter_size> getter{};
        std::array<unsigned char, voice_ptt_guard::state_size> state{};
        voice_ptt_guard::observation sample; sample.owned = voice_ptt_owner;
        sample.observed_place = reinterpret_cast<std::uintptr_t>(cl_execute_key_hook.get_place());
        sample.observed_original = reinterpret_cast<std::uintptr_t>(cl_execute_key_hook.get_original());
        sample.observed_stub = reinterpret_cast<std::uintptr_t>(&cl_execute_key_stub);
        std::uintptr_t relay_address{};
        if (!voice_ptt_guard::add(sample.owned.original, voice_ptt_guard::trampoline_size, relay_address))
        {
            proof.reason = voice_ptt_guard::refusal::address_overflow; voice_ptt_log("live", proof, main_thread); return proof;
        }
        sample.entry = voice_ptt_copy(voice_ptt_guard::entry_address, entry, true);
        sample.trampoline = voice_ptt_copy(sample.owned.original, trampoline, true);
        sample.relay = voice_ptt_copy(relay_address, relay, true);
        sample.stub = voice_ptt_region(sample.owned.stub);
        sample.getter = voice_ptt_copy(voice_ptt_guard::getter_address, getter, true);
        sample.state = voice_ptt_copy(voice_ptt_guard::state_address, state, false);
        proof = voice_ptt_guard::validate_code(sample);
        if (!proof.valid()) { voice_ptt_log("live", proof, main_thread, &sample); return proof; }
        // The verified getter is read-only and localClient 0. The main pipeline
        // serializes ordinary key updates; this grants no dispatch authority.
        sample.getter_active = utils::hook::invoke<unsigned char>(voice_ptt_guard::getter_address, 0);
        sample.getter_sampled = true;
        proof = voice_ptt_guard::validate(sample);
        if (proof.valid()) std::memcpy(destination, state.data(), state.size());
        voice_ptt_log("live", proof, main_thread, &sample);
        return proof;
    }
