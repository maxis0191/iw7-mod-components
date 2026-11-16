#pragma once

#include <cstdint>
#include <cstring>

// Filter in front of the per-opcode replacefunc check of the script VM (gsc/script_extension.cpp, vm_execute_stub).
//
// The stub runs before every script opcode. It used to save every register, call a std::unordered_map lookup and restore
// the registers each time, although only a few dozen code positions are ever replaced. This table keeps one byte per value
// of the low 16 bits of a replaced code position: the stub tests that byte with five instructions and no call, and takes
// the slow path (the exact map lookup) only when it is set. A set byte for a position that is not replaced (two positions
// with the same low 16 bits, or a position of an earlier map) is harmless: the slow path decides.
namespace paris_vm_filter
{
	constexpr std::size_t table_size = 0x10000;

	inline std::uint8_t table[table_size]{};

	inline std::size_t index_of(const void* position)
	{
		return static_cast<std::size_t>(reinterpret_cast<std::uintptr_t>(position) & (table_size - 1));
	}

	inline void mark(const void* position)
	{
		table[index_of(position)] = 1;
	}

	inline bool maybe_replaced(const void* position)
	{
		return table[index_of(position)] != 0;
	}

	inline void clear()
	{
		std::memset(table, 0, sizeof(table));
	}
}
