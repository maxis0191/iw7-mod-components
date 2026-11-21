#pragma once

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// A console and log writer that never blocks the thread that prints (docs/CONSOLE-WRITER.md).
//
// The console sinks of the dedicated server (the console log file, the console host's screen buffer) are synchronous calls to another
// process: one print of the server thread took 100 to 650 ms on a busy machine (docs/PRINT-COST.md of the server repository). Here the
// printing thread copies the line into a bounded ring and returns; one writer thread drains the ring, in order, to the same sinks.
// Game independent: the sinks are functions the caller gives, so tests/native/console_writer_test.cpp runs it without the game.
namespace paris_console_writer
{
	constexpr int info_type = 7; // console::print_type_info

	struct line
	{
		int type{};
		std::string text;
		std::uint32_t gap{}; // lines dropped just before this one
	};

	// What the queue and the writer count. All values are totals since the start, except the maxima which are the largest seen.
	struct counters
	{
		std::uint64_t queued{};
		std::uint64_t written{};
		std::uint64_t dropped{};
		std::uint64_t max_enqueue_us{};
		std::uint64_t max_sink_write_us{};
		std::uint64_t slow_sink_writes{}; // sink writes of more than slow_sink_us
	};

	constexpr std::uint64_t slow_sink_us = 50000;

	enum class push_result
	{
		accepted,
		dropped, // ring full: the line is counted and gone
		closed,  // not running: the caller prints the line itself
	};

	// A bounded ring of lines: at most max_lines lines and max_bytes bytes of text. Slots keep their string capacity, so after the
	// first fill a push copies bytes and allocates nothing. The mutex is held for a copy of at most one line (push) or of one batch (pop).
	class queue
	{
	public:
		queue(const std::size_t max_lines, const std::size_t max_bytes)
			: slots_(max_lines ? max_lines : 1), max_bytes_(max_bytes)
		{
		}

		push_result push(const int type, const char* data, const std::size_t length)
		{
			bool was_empty = false;
			{
				std::lock_guard<std::mutex> lock(this->mutex_);

				if (this->closed_)
				{
					return push_result::closed;
				}

				if (this->count_ == this->slots_.size() || length > this->max_bytes_ || this->bytes_ + length > this->max_bytes_)
				{
					++this->dropped_;
					++this->pending_gap_;
					return push_result::dropped;
				}

				was_empty = this->count_ == 0;
				auto& slot = this->slots_[(this->head_ + this->count_) % this->slots_.size()];
				slot.type = type;
				slot.text.assign(data, length);
				slot.gap = this->pending_gap_;
				this->pending_gap_ = 0;
				++this->count_;
				this->bytes_ += length;
				++this->queued_;
			}

			if (was_empty)
			{
				this->cv_.notify_one();
			}

			return push_result::accepted;
		}

		// Waits up to `timeout` for a line, a drop notice or the close, then moves up to max_lines lines into out[0..n) and returns n (out only
		// grows, so its strings keep their buffers). `trailing_gap` is the number of lines dropped after the last line of the batch when the ring is empty now (0 otherwise).
		std::size_t pop_wait(std::vector<line>& out, const std::size_t max_lines, const std::chrono::milliseconds timeout, std::uint32_t& trailing_gap)
		{
			std::unique_lock<std::mutex> lock(this->mutex_);
			this->cv_.wait_for(lock, timeout, [this] { return this->count_ || this->pending_gap_ || this->closed_; });
			return this->pop_locked(out, max_lines, trailing_gap);
		}

		// For a crash or a shutdown path: takes everything that is queued, or nothing when the mutex is taken (a crash must not wait for a lock).
		bool try_pop_all(std::vector<line>& out, std::size_t& n, std::uint32_t& trailing_gap)
		{
			std::unique_lock<std::mutex> lock(this->mutex_, std::try_to_lock);
			if (!lock.owns_lock())
			{
				return false;
			}

			n = this->pop_locked(out, this->slots_.size(), trailing_gap);
			return true;
		}

		void close()
		{
			{
				std::lock_guard<std::mutex> lock(this->mutex_);
				this->closed_ = true;
			}
			this->cv_.notify_all();
		}

		bool closed()
		{
			std::lock_guard<std::mutex> lock(this->mutex_);
			return this->closed_;
		}

		std::size_t size()
		{
			std::lock_guard<std::mutex> lock(this->mutex_);
			return this->count_;
		}

		std::uint64_t queued()
		{
			std::lock_guard<std::mutex> lock(this->mutex_);
			return this->queued_;
		}

		std::uint64_t dropped()
		{
			std::lock_guard<std::mutex> lock(this->mutex_);
			return this->dropped_;
		}

	private:
		std::size_t pop_locked(std::vector<line>& out, const std::size_t max_lines, std::uint32_t& trailing_gap)
		{
			const auto n = (std::min)(this->count_, max_lines);
			if (out.size() < n)
			{
				out.resize(n);
			}

			for (std::size_t i = 0; i < n; ++i)
			{
				auto& slot = this->slots_[this->head_];
				out[i].type = slot.type;
				out[i].gap = slot.gap;
				std::swap(out[i].text, slot.text); // both keep a buffer: no allocation in steady state
				this->bytes_ -= out[i].text.size();
				this->head_ = (this->head_ + 1) % this->slots_.size();
				--this->count_;
			}

			trailing_gap = 0;
			if (this->count_ == 0)
			{
				trailing_gap = this->pending_gap_;
				this->pending_gap_ = 0;
				this->head_ = 0;
			}

			return n;
		}

		std::mutex mutex_;
		std::condition_variable cv_;
		std::vector<line> slots_;
		std::size_t max_bytes_;
		std::size_t head_{};
		std::size_t count_{};
		std::size_t bytes_{};
		std::uint32_t pending_gap_{};
		std::uint64_t queued_{};
		std::uint64_t dropped_{};
		bool closed_{};
	};

	// The writer thread. sink(type, text) writes one line to the real sinks; after_batch() runs after every batch (flush of the kept file handle).
	// Both run on the writer thread only (and the sink of a crash flush, see wait_until_drained, never runs on another thread).
	class writer
	{
	public:
		using sink_fn = std::function<void(int, const std::string&)>;
		using batch_fn = std::function<void()>;

		writer(sink_fn sink, batch_fn after_batch, const std::size_t max_lines = 4096, const std::size_t max_bytes = 1u << 20,
			const std::chrono::seconds report_every = std::chrono::seconds(60))
			: queue_(max_lines, max_bytes), sink_(std::move(sink)), after_batch_(std::move(after_batch)), report_every_(report_every)
		{
		}

		writer(const writer&) = delete;
		writer& operator=(const writer&) = delete;

		void start()
		{
			if (this->running_.exchange(true))
			{
				return;
			}

			this->finished_ = std::promise<void>();
			this->finished_future_ = this->finished_.get_future();
			this->thread_ = std::thread([this] { this->run(); });
		}

		// False: not running (not started, or stopping): the caller prints the line itself.
		bool submit(const int type, const char* data, const std::size_t length)
		{
			if (!this->running_.load(std::memory_order_acquire))
			{
				return false;
			}

			const auto begin = std::chrono::steady_clock::now();
			const auto result = this->queue_.push(type, data, length);
			update_max(this->max_enqueue_us_, micros_since(begin));
			return result != push_result::closed;
		}

		bool submit(const int type, const std::string& text)
		{
			return this->submit(type, text.data(), text.size());
		}

		// Closes the ring, lets the thread write what is queued and print the final counters, and joins it. Waits at most `limit`; a writer stuck
		// in a sink is left behind (detached) and the lines it holds are lost. Idempotent.
		void stop(const std::chrono::milliseconds limit = std::chrono::milliseconds(3000))
		{
			if (!this->running_.load())
			{
				return;
			}

			this->queue_.close();
			if (this->finished_future_.valid() && this->finished_future_.wait_for(limit) == std::future_status::ready)
			{
				if (this->thread_.joinable())
				{
					this->thread_.join();
				}
			}
			else if (this->thread_.joinable())
			{
				this->thread_.detach();
			}

			this->running_ = false;
		}

		bool running() const
		{
			return this->running_.load();
		}

		// Crash path: waits up to `limit` for the writer to empty the ring (it keeps writing while the caller waits). Returns whether it is empty.
		bool wait_until_drained(const std::chrono::milliseconds limit)
		{
			const auto end = std::chrono::steady_clock::now() + limit;
			while (this->queue_.size() != 0 && std::chrono::steady_clock::now() < end)
			{
				std::this_thread::yield();
			}

			return this->queue_.size() == 0;
		}

		counters get()
		{
			counters c{};
			c.queued = this->queue_.queued();
			c.written = this->written_.load();
			c.dropped = this->queue_.dropped();
			c.max_enqueue_us = this->max_enqueue_us_.load();
			c.max_sink_write_us = this->max_sink_write_us_.load();
			c.slow_sink_writes = this->slow_sink_writes_.load();
			return c;
		}

		static std::string format(const counters& c)
		{
			char buffer[256]{};
			std::snprintf(buffer, sizeof(buffer),
				"[console writer] queued=%llu written=%llu dropped=%llu max_enqueue_us=%llu max_sink_write_us=%llu slow_sink_writes=%llu\n",
				static_cast<unsigned long long>(c.queued), static_cast<unsigned long long>(c.written), static_cast<unsigned long long>(c.dropped),
				static_cast<unsigned long long>(c.max_enqueue_us), static_cast<unsigned long long>(c.max_sink_write_us),
				static_cast<unsigned long long>(c.slow_sink_writes));
			return buffer;
		}

		queue& ring()
		{
			return this->queue_;
		}

	private:
		static std::uint64_t micros_since(const std::chrono::steady_clock::time_point begin)
		{
			return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - begin).count());
		}

		static void update_max(std::atomic<std::uint64_t>& target, const std::uint64_t value)
		{
			auto current = target.load(std::memory_order_relaxed);
			while (value > current && !target.compare_exchange_weak(current, value, std::memory_order_relaxed))
			{
			}
		}

		void write_line(const int type, const std::string& text)
		{
			const auto begin = std::chrono::steady_clock::now();
			try
			{
				if (this->sink_)
				{
					this->sink_(type, text);
				}
			}
			catch (...)
			{
				// a sink that throws must not end the thread: the line is lost
			}

			const auto us = micros_since(begin);
			update_max(this->max_sink_write_us_, us);
			if (us > slow_sink_us)
			{
				++this->slow_sink_writes_;
				++this->slow_in_window_;
			}

			++this->written_;
		}

		void write_notice(const std::uint32_t gap)
		{
			char buffer[96]{};
			std::snprintf(buffer, sizeof(buffer), "[console writer] dropped %u lines\n", static_cast<unsigned>(gap));
			this->write_line(info_type, buffer);
			--this->written_; // a notice is not a queued line
		}

		void report(const bool final_line)
		{
			const auto now = this->queue_.dropped();
			if (final_line || now != this->reported_dropped_ || this->slow_in_window_ != 0)
			{
				this->write_line(info_type, format(this->get()));
				--this->written_;
				this->reported_dropped_ = now;
				this->slow_in_window_ = 0;
			}
		}

		void after_batch()
		{
			try
			{
				if (this->after_batch_)
				{
					this->after_batch_();
				}
			}
			catch (...)
			{
			}
		}

		void run()
		{
			std::vector<line> batch;
			auto window = std::chrono::steady_clock::now();

			for (;;)
			{
				std::uint32_t trailing = 0;
				const auto n = this->queue_.pop_wait(batch, 256, std::chrono::milliseconds(250), trailing);

				for (std::size_t i = 0; i < n; ++i)
				{
					if (batch[i].gap)
					{
						this->write_notice(batch[i].gap);
					}

					this->write_line(batch[i].type, batch[i].text);
				}

				if (trailing)
				{
					this->write_notice(trailing);
				}

				if (n || trailing)
				{
					this->after_batch();
				}
				else if (this->queue_.closed())
				{
					break;
				}

				if (std::chrono::steady_clock::now() - window >= this->report_every_)
				{
					window = std::chrono::steady_clock::now();
					this->report(false);
					this->after_batch();
				}
			}

			this->report(true);
			this->after_batch();
			this->finished_.set_value();
		}

		queue queue_;
		sink_fn sink_;
		batch_fn after_batch_;
		std::chrono::seconds report_every_;
		std::atomic<bool> running_{ false };
		std::thread thread_;
		std::promise<void> finished_;
		std::future<void> finished_future_;
		std::atomic<std::uint64_t> written_{ 0 };
		std::atomic<std::uint64_t> max_enqueue_us_{ 0 };
		std::atomic<std::uint64_t> max_sink_write_us_{ 0 };
		std::atomic<std::uint64_t> slow_sink_writes_{ 0 };
		std::uint64_t slow_in_window_{}; // writer thread only
		std::uint64_t reported_dropped_{}; // writer thread only
	};

	// The writer of this process, set by the component once the sinks exist; null until then and for every process that is not a dedicated server.
	inline std::atomic<writer*>& active()
	{
		static std::atomic<writer*> instance{ nullptr };
		return instance;
	}

	// Called by console::dispatch_message for every line. False: print it yourself.
	inline bool submit(const int type, const std::string& text)
	{
		auto* w = active().load(std::memory_order_acquire);
		return w && w->submit(type, text);
	}
}
