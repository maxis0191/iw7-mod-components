using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class IW7ResourceMemoryV1
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PerformanceInformation
    {
        public uint cb;
        public UIntPtr CommitTotal, CommitLimit, CommitPeak;
        public UIntPtr PhysicalTotal, PhysicalAvailable, SystemCache;
        public UIntPtr KernelTotal, KernelPaged, KernelNonpaged, PageSize;
        public uint HandleCount, ProcessCount, ThreadCount;
    }

    public sealed class Snapshot
    {
        public long PhysicalTotal, PhysicalAvailable, Committed, CommitLimit;
    }

    [DllImport("psapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetPerformanceInfo(ref PerformanceInformation info, uint size);

    public static Snapshot Read()
    {
        var info = new PerformanceInformation();
        info.cb = checked((uint)Marshal.SizeOf(typeof(PerformanceInformation)));
        if (!GetPerformanceInfo(ref info, info.cb))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Fresh memory telemetry unavailable; admission refused.");
        ulong page = info.PageSize.ToUInt64();
        if (page == 0) throw new InvalidOperationException("Invalid native page size.");
        var value = new Snapshot {
            PhysicalTotal = checked((long)checked(info.PhysicalTotal.ToUInt64() * page)),
            PhysicalAvailable = checked((long)checked(info.PhysicalAvailable.ToUInt64() * page)),
            Committed = checked((long)checked(info.CommitTotal.ToUInt64() * page)),
            CommitLimit = checked((long)checked(info.CommitLimit.ToUInt64() * page))
        };
        if (value.PhysicalTotal <= 0 || value.CommitLimit <= 0 ||
            value.PhysicalAvailable > value.PhysicalTotal || value.Committed > value.CommitLimit)
            throw new InvalidOperationException("Invalid native memory telemetry; admission refused.");
        return value;
    }
}
