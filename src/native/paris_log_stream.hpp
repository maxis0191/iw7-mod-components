#pragma once

#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <system_error>
#include <vector>

// Append-only game log (G_LogPrintf) with one open handle per path.
//
// The reimplemented G_LogPrintf wrote every damage event with utils::io::write_file: create the directory, open the file,
// write, close. At 200 live zombies that was about 1.7 ms of every 50 ms server frame (NtCreateFile alone 1.5 ms loaded).
// This keeps the file open in append mode and writes the same bytes in the same order; they reach the file when the
// buffer fills and at flush(), which the component calls once per server frame, at every script shutdown and at exit.
namespace paris_log_stream
{
	class append_log
	{
	public:
		// False: the caller writes the data the old way (open, append, close).
		bool append(const std::string& path, const std::string& data)
		{
			std::lock_guard<std::mutex> lock(this->mutex_);

			auto* entry = this->open(path);
			if (!entry)
			{
				return false;
			}

			entry->stream.write(data.data(), static_cast<std::streamsize>(data.size()));
			if (!entry->stream)
			{
				this->drop(path);
				return false;
			}

			entry->dirty = true;
			return true;
		}

		void flush()
		{
			std::lock_guard<std::mutex> lock(this->mutex_);

			for (auto i = this->entries_.begin(); i != this->entries_.end();)
			{
				auto& entry = **i;
				if (!entry.dirty)
				{
					++i;
					continue;
				}

				entry.stream.flush();
				entry.dirty = false;
				if (!entry.stream)
				{
					i = this->entries_.erase(i);
					continue;
				}

				++i;
			}
		}

		void close_all()
		{
			std::lock_guard<std::mutex> lock(this->mutex_);
			this->entries_.clear();
		}

		std::size_t open_count()
		{
			std::lock_guard<std::mutex> lock(this->mutex_);
			return this->entries_.size();
		}

	private:
		struct entry
		{
			std::string path;
			std::ofstream stream;
			bool dirty{};
		};

		static constexpr std::size_t max_open = 8;

		entry* open(const std::string& path)
		{
			for (const auto& e : this->entries_)
			{
				if (e->path == path)
				{
					return e.get();
				}
			}

			if (this->entries_.size() >= max_open)
			{
				this->entries_.erase(this->entries_.begin());
			}

			const auto pos = path.find_last_of("/\\");
			if (pos != std::string::npos)
			{
				std::error_code error;
				std::filesystem::create_directories(path.substr(0, pos), error);
			}

			auto created = std::make_unique<entry>();
			created->path = path;
			created->stream.open(path, std::ios::binary | std::ios::out | std::ios::app);
			if (!created->stream.is_open())
			{
				return nullptr;
			}

			this->entries_.push_back(std::move(created));
			return this->entries_.back().get();
		}

		void drop(const std::string& path)
		{
			for (auto i = this->entries_.begin(); i != this->entries_.end(); ++i)
			{
				if ((*i)->path == path)
				{
					this->entries_.erase(i);
					return;
				}
			}
		}

		std::mutex mutex_;
		std::vector<std::unique_ptr<entry>> entries_;
	};

	inline append_log& instance()
	{
		static append_log log;
		return log;
	}
}
