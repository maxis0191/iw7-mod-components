using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public sealed class IW7CapacityRegion {
    public ulong BaseAddress, AllocationBase, RegionSize;
    public uint State, Protect, AllocationProtect, Type;
    public string MappedDevicePath;
}

// Retained read-only process handle. No attach, suspension, writes or children.
public sealed class IW7CapacityPages : IDisposable {
    static readonly long[] allowedPages = {
        0x140488000, 0x14B378000, 0x14BCE8000, 0x14BF22000,
        0x140B20000, 0x14BA00000, 0x14B7E7000, 0x14BA8E000
    };
    static readonly long[] resetEntryPages = { 0x14B8E6000, 0x14B4B2000 };
    // Exact pages selected from the 2026-10-19 hardware writer journal.
    static readonly long[] writerPages = { 0x1412BF000, 0x14C1ED000, 0x14BFE5000 };
    // Two observed writers and the exact continuation/fill/initialization
    // targets retained in the historical 9F follow-up report. No address input.
    static readonly long[] writerPathPages = {
        0x14C1ED000, 0x14BFE5000, 0x140406000, 0x140B20000,
        0x1412BF000, 0x141238000, 0x14B538000, 0x140AC6000
    };
    // Exact continuation of the qualified 140B20B29 jump, after pool setup.
    static readonly long[] bindingContinuationPages = { 0x14B3C5000 };
    readonly long[] instancePages;
    readonly string instancePlan;
    static readonly long[] textStarts = { 0x140001000, 0x14B2B4000 };
    static readonly int[] textLengths = { 0x1427E00, 0x104D400 };
    readonly int[] textReads = new int[2];
    [StructLayout(LayoutKind.Sequential)] struct MBI {
        public IntPtr BaseAddress, AllocationBase;
        public uint AllocationProtect; public ushort PartitionId;
        public UIntPtr RegionSize; public uint State, Protect, Type;
    }
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr handle, IntPtr address, byte[] buffer, UIntPtr size, out UIntPtr got);
    [DllImport("kernel32.dll", SetLastError=true)] static extern UIntPtr VirtualQueryEx(IntPtr handle, IntPtr address, out MBI info, UIntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr handle, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageNameW(IntPtr handle, uint flags, StringBuilder path, ref int length);
    [DllImport("psapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetMappedFileNameW(IntPtr handle, IntPtr address, StringBuilder name, uint size);
    IntPtr handle;
    readonly Dictionary<long,int> reads = new Dictionary<long,int>();
    readonly Dictionary<long,int> queries = new Dictionary<long,int>();
    public int ReadCalls { get; private set; }
    public int ReadBytes { get; private set; }
    public bool Closed { get { return handle == IntPtr.Zero; } }

    public IW7CapacityPages(int pid, string expectedImage, long expectedCreation) : this(pid, expectedImage, expectedCreation, "reset-callers") {}
    public IW7CapacityPages(int pid, string expectedImage, long expectedCreation, string pagePlan) {
        instancePages = GetPlanPages(pagePlan);
        instancePlan = pagePlan;
        if (pid <= 0 || Marshal.SizeOf(typeof(MBI)) != 48) throw new ArgumentException("Win64 exact identity required.");
        // QUERY_INFORMATION, VM_READ and SYNCHRONIZE only. VirtualQueryEx needs
        // QUERY_INFORMATION; QUERY_LIMITED_INFORMATION is insufficient.
        handle = OpenProcess(0x100410, false, pid);
        if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            long created, exited, kernel, user; var path = new StringBuilder(32768); int length = path.Capacity;
            if (!GetProcessTimes(handle, out created, out exited, out kernel, out user) ||
                !QueryFullProcessImageNameW(handle, 0, path, ref length)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (created != expectedCreation || !String.Equals(Path.GetFullPath(path.ToString()), Path.GetFullPath(expectedImage), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Retained process identity differs.");
            AssertAlive();
        } catch { Dispose(); throw; }
    }

    public static long[] GetAllowedPages() { return GetPlanPages("reset-callers"); }
    public static long[] GetPlanPages(string plan) {
        if (plan == "reset-callers") return (long[])allowedPages.Clone();
        if (plan == "reset-entry-targets") return (long[])resetEntryPages.Clone();
        if (plan == "writer-sites-20261019") return (long[])writerPages.Clone();
        if (plan == "writer-path-20261019") return (long[])writerPathPages.Clone();
        if (plan == "binding-continuation-20261019") return (long[])bindingContinuationPages.Clone();
        throw new ArgumentException("Unknown fixed page plan.");
    }
    public static void ValidatePlanAddress(string plan, long address) {
        if (Array.IndexOf(GetPlanPages(plan), address) < 0) throw new ArgumentException("Outside selected fixed page plan.");
    }
    public static bool SamePage(byte[] a, byte[] b) {
        if (a == null || b == null || a.Length != 4096 || b.Length != 4096) return false;
        for (int i=0; i<4096; i++) if (a[i] != b[i]) return false;
        return true;
    }
    public static void ValidateAddress(long address) {
        if (Array.IndexOf(allowedPages, address) < 0) throw new ArgumentException("Outside fixed eight-page plan.");
    }
    public static void ValidateRegion(IW7CapacityRegion r, long address) {
        ValidateRegionForPlan(r, address, "reset-callers");
    }
    public static void ValidateRegionForPlan(IW7CapacityRegion r, long address, string plan) {
        ValidatePlanAddress(plan, address);
        uint basic = r.Protect & 0xff;
        if (r.State != 0x1000 || (r.Protect & 0x100) != 0 || (basic != 0x20 && basic != 0x40 && basic != 0x80) ||
            (r.Type != 0x1000000 && r.Type != 0x20000 && r.Type != 0x40000) ||
            r.BaseAddress > (ulong)address || r.RegionSize < 4096 ||
            (ulong)address - r.BaseAddress > r.RegionSize - 4096)
            throw new InvalidOperationException("Not a committed readable executable complete page.");
    }
    void Count(Dictionary<long,int> counts, long address) {
        if (Array.IndexOf(instancePages, address) < 0) throw new ArgumentException("Outside retained handle fixed plan."); int n; counts.TryGetValue(address, out n);
        if (n >= 2) throw new InvalidOperationException("Fixed double-read/query bound exceeded.");
        counts[address] = n + 1;
    }
    public void AssertAlive() {
        if (handle == IntPtr.Zero || WaitForSingleObject(handle, 0) != 258) throw new InvalidOperationException("Original retained handle is no longer live.");
    }
    public IW7CapacityRegion QueryPage(long address) {
        AssertAlive(); Count(queries, address);
        MBI info;
        if (VirtualQueryEx(handle, new IntPtr(address), out info, (UIntPtr)48).ToUInt64() != 48) throw new Win32Exception(Marshal.GetLastWin32Error());
        var path = new StringBuilder(32768);
        uint n = GetMappedFileNameW(handle, new IntPtr(address), path, (uint)path.Capacity);
        var result = new IW7CapacityRegion { BaseAddress=(ulong)info.BaseAddress.ToInt64(), AllocationBase=(ulong)info.AllocationBase.ToInt64(), RegionSize=info.RegionSize.ToUInt64(), State=info.State, Protect=info.Protect, AllocationProtect=info.AllocationProtect, Type=info.Type, MappedDevicePath=n == 0 ? null : path.ToString() };
        ValidateRegionForPlan(result, address, instancePlan);
        if (n == 0 && result.Type != 0x20000) throw new InvalidOperationException("Image/mapped page lacks mapping provenance.");
        return result;
    }
    public byte[] ReadPage(long address) {
        AssertAlive(); int checkedCount;
        if (!queries.TryGetValue(address, out checkedCount) || checkedCount != 1) throw new InvalidOperationException("Page must be permission-checked before its fixed reads.");
        Count(reads, address);
        var bytes = new byte[4096]; UIntPtr got;
        if (!ReadProcessMemory(handle, new IntPtr(address), bytes, (UIntPtr)4096, out got) || got.ToUInt64() != 4096) throw new Win32Exception(Marshal.GetLastWin32Error());
        ReadCalls++; ReadBytes += 4096;
        return bytes;
    }
    // Fixed executable sections from the current retail PE. No writable data,
    // arbitrary addresses, full process dump or suspension is accepted here.
    public static long TextSectionAddress(int index) {
        if (index < 0 || index >= 2) throw new ArgumentException("Outside two fixed executable sections.");
        return textStarts[index];
    }
    public static int TextSectionLength(int index) {
        TextSectionAddress(index); return textLengths[index];
    }
    public static bool SameTextSection(int index, byte[] first, byte[] second) {
        int length = TextSectionLength(index);
        if (first == null || second == null || first.Length != length || second.Length != length) return false;
        for (int i=0; i<length; ++i) if (first[i] != second[i]) return false;
        return true;
    }
    public static int[] ChangedTextPages(int index, byte[] first, byte[] second) {
        int length = TextSectionLength(index);
        if (first == null || second == null || first.Length != length || second.Length != length)
            throw new ArgumentException("Complete fixed executable section pair required.");
        var result = new List<int>();
        for (int start=0; start<length; start+=4096) {
            int end = Math.Min(length,start+4096);
            for (int i=start; i<end; ++i) if (first[i] != second[i]) {result.Add(start);break;}
        }
        return result.ToArray();
    }
    public byte[] ReadTextSection(int index) {
        long address = TextSectionAddress(index); int length = TextSectionLength(index);
        AssertAlive();
        if (textReads[index] >= 2) throw new InvalidOperationException("Fixed text double-read bound exceeded.");
        ++textReads[index];
        long cursor = address, end = checked(address + length); int regions = 0;
        while (cursor < end) {
            if (++regions > 512) throw new InvalidOperationException("Executable section region bound exceeded.");
            MBI info;
            if (VirtualQueryEx(handle, new IntPtr(cursor), out info, (UIntPtr)48).ToUInt64() != 48)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            uint basic = info.Protect & 0xff;
            long start = info.BaseAddress.ToInt64(); ulong size = info.RegionSize.ToUInt64();
            if (info.State != 0x1000 || (info.Protect & 0x100) != 0 ||
                (basic != 0x20 && basic != 0x40 && basic != 0x80) ||
                start > cursor || size == 0 || size > long.MaxValue ||
                start > long.MaxValue - (long)size || start + (long)size <= cursor)
                throw new InvalidOperationException("Fixed text range is not readable committed executable memory.");
            cursor = Math.Min(end, start + (long)size);
        }
        var bytes = new byte[length]; UIntPtr got;
        if (!ReadProcessMemory(handle, new IntPtr(address), bytes, (UIntPtr)length, out got) || got.ToUInt64() != (ulong)length)
            throw new Win32Exception(Marshal.GetLastWin32Error());
        ReadCalls++; ReadBytes += length;
        AssertAlive();
        return bytes;
    }
    public void Dispose() {
        if (handle != IntPtr.Zero) {
            if (!CloseHandle(handle)) throw new Win32Exception(Marshal.GetLastWin32Error());
            handle = IntPtr.Zero;
        }
    }
}
