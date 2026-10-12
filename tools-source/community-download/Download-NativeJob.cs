// Source-only correction after the 2026-10-12 native run. Requires a separately
// admitted compile/fault-injection witness before claiming this path tested.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace IW7.CommunityDownload
{
    // Keep this owner in the caller's list BEFORE Start. There is deliberately
    // no IDisposable: an unresolved tree must quarantine its resource lease.
    public sealed class NativeJob
    {
        const uint KillOnClose = 0x2000, LimitPriority = 0x20, BelowNormal = 0x4000;
        const uint Suspended = 4, UnicodeEnvironment = 0x400, ExtendedStartup = 0x80000, NoWindow = 0x8000000;
        const int HandleList = 0x20002, JobList = 0x2000d;
        [StructLayout(LayoutKind.Sequential)] struct Security { public int size; public IntPtr descriptor; public int inherit; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct Startup
        {
            public int cb; public string reserved, desktop, title;
            public uint x, y, width, height, xChars, yChars, fill, flags;
            public ushort show, reserved2; public IntPtr reservedPointer, input, output, error;
        }
        [StructLayout(LayoutKind.Sequential)] struct StartupEx { public Startup startup; public IntPtr attributes; }
        [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process, thread; public uint pid, tid; }
        [StructLayout(LayoutKind.Sequential)] struct BasicLimit
        {
            public long processTime, jobTime; public uint flags; public UIntPtr minWorking, maxWorking;
            public uint activeLimit; public UIntPtr affinity; public uint priority, scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimit
        {
            public BasicLimit basic;
            public ulong readOps, writeOps, otherOps, readBytes, writeBytes, otherBytes;
            public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
        }
        [StructLayout(LayoutKind.Sequential)] struct Accounting
        {
            public long user, kernel, periodUser, periodKernel;
            public uint faults, total, active, terminated;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeFileHandle CreateJobObjectW(IntPtr security, string name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(SafeFileHandle job, int kind, ref ExtendedLimit limits, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(SafeFileHandle job, int kind, out Accounting info, uint size, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(SafeFileHandle job, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsProcessInJob(SafeFileHandle process, SafeFileHandle job, out bool result);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcessW(string image, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr environment, string cwd, ref StartupEx startup, out ProcessInfo process);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeFileHandle CreateFileW(string path, uint access, uint share, ref Security security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, uint flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(SafeFileHandle thread);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(SafeFileHandle process, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(SafeFileHandle process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessTimes(SafeFileHandle process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint GetPriorityClass(SafeFileHandle process);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageNameW(SafeFileHandle process, uint flags, StringBuilder image, ref uint size);

        SafeFileHandle job, process, thread, input, output, error;
        FileStream imageGuard;
        bool attempted, createPending;
        public bool Closed { get; private set; }
        public int PID { get; private set; }
        public long CreationFileTime { get; private set; }
        public string Image { get; private set; }
        public int? ExitCode { get; private set; }
        static void Check(bool ok, string message) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error(), message); }

        // Windows CRT quoting; lpApplicationName is separately supplied exactly.
        static string Quote(string value)
        {
            if (value == null || value.IndexOf('\0') >= 0) throw new ArgumentException("NUL argument");
            var result = new StringBuilder("\""); int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes).Append(c); slashes = 0;
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }
        static SafeFileHandle OpenLog(string path, ref Security security)
        {
            var handle = CreateFileW(path, 0x40000000, 1, ref security, 1, 0x80, IntPtr.Zero); // CREATE_NEW, share read only
            if (handle.IsInvalid) { int code = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(code, "Create-only native log"); }
            return handle;
        }
        public void Start(ProcessStartInfo start, string expectedHash, string stdout, string stderr)
        {
            if (attempted || Closed) throw new InvalidOperationException("One launch per owned job");
            attempted = true;
            if (IntPtr.Size != 8 || Marshal.SizeOf<StartupEx>() != 112 || Marshal.SizeOf<ExtendedLimit>() != 144 || Marshal.SizeOf<Accounting>() != 48)
                throw new InvalidOperationException("Windows x64 job/startup ABI required");
            if (!Path.IsPathFullyQualified(start.FileName) || !Path.IsPathFullyQualified(start.WorkingDirectory)) throw new ArgumentException("Absolute native paths required");
            imageGuard = new FileStream(start.FileName, FileMode.Open, FileAccess.Read, FileShare.Read);
            using (var digest = SHA256.Create())
                if (!String.Equals(BitConverter.ToString(digest.ComputeHash(imageGuard)).Replace("-", String.Empty), expectedHash, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Retained executable hash differs");
            job = CreateJobObjectW(IntPtr.Zero, null); // unnamed, noninheritable
            Check(!job.IsInvalid, "Create owned job");
            var limits = new ExtendedLimit(); limits.basic.flags = KillOnClose | LimitPriority; limits.basic.priority = BelowNormal;
            Check(SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimit>()), "Set kill-on-close and priority; no breakaway flags");
            var security = new Security { size = Marshal.SizeOf<Security>(), inherit = 1 };
            output = OpenLog(stdout, ref security); error = OpenLog(stderr, ref security);
            input = CreateFileW("NUL", 0x80000000, 3, ref security, 3, 0, IntPtr.Zero);
            Check(!input.IsInvalid, "Open NUL stdin");
            IntPtr list = IntPtr.Zero, handles = IntPtr.Zero, jobs = IntPtr.Zero, environment = IntPtr.Zero;
            bool initialized = false;
            try
            {
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref size);
                if (size == IntPtr.Zero) throw new InvalidOperationException("Native attribute size unavailable");
                list = Marshal.AllocHGlobal(size);
                Check(InitializeProcThreadAttributeList(list, 2, 0, ref size), "Initialize native attributes"); initialized = true;
                handles = Marshal.AllocHGlobal(3 * IntPtr.Size);
                Marshal.WriteIntPtr(handles, input.DangerousGetHandle());
                Marshal.WriteIntPtr(handles, IntPtr.Size, output.DangerousGetHandle());
                Marshal.WriteIntPtr(handles, 2 * IntPtr.Size, error.DangerousGetHandle());
                Check(UpdateProcThreadAttribute(list, 0, (IntPtr)HandleList, handles, (IntPtr)(3 * IntPtr.Size), IntPtr.Zero, IntPtr.Zero), "Restrict inherited handles to logs/stdin");
                jobs = Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(jobs, job.DangerousGetHandle());
                // Windows 10+ SDK WinBase.h PROC_THREAD_ATTRIBUTE_JOB_LIST: the
                // child is born inside our job, including launcher-crash races.
                Check(UpdateProcThreadAttribute(list, 0, (IntPtr)JobList, jobs, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero), "Atomic job-at-creation attribute");
                var env = String.Join("\0", start.Environment.OrderBy(e => e.Key, StringComparer.OrdinalIgnoreCase).Select(e => e.Key + "=" + e.Value)) + "\0\0";
                environment = Marshal.StringToHGlobalUni(env);
                var si = new StartupEx { attributes = list };
                si.startup.cb = Marshal.SizeOf<StartupEx>(); si.startup.flags = 0x100;
                si.startup.input = input.DangerousGetHandle(); si.startup.output = output.DangerousGetHandle(); si.startup.error = error.DangerousGetHandle();
                var command = new StringBuilder(Quote(start.FileName));
                foreach (string arg in start.ArgumentList) command.Append(' ').Append(Quote(arg));
                createPending = true;
                ProcessInfo created;
                bool ok = CreateProcessW(start.FileName, command, IntPtr.Zero, IntPtr.Zero, true,
                    Suspended | UnicodeEnvironment | ExtendedStartup | NoWindow | BelowNormal, environment, start.WorkingDirectory, ref si, out created);
                int code = Marshal.GetLastWin32Error();
                // Retain original handles before any further operation can fail.
                if (created.process != IntPtr.Zero) process = new SafeFileHandle(created.process, true);
                if (created.thread != IntPtr.Zero) thread = new SafeFileHandle(created.thread, true);
                PID = (int)created.pid; createPending = false;
                if (!ok) throw new Win32Exception(code, "Create suspended process inside owned job");
            }
            finally
            {
                if (initialized) DeleteProcThreadAttributeList(list);
                if (list != IntPtr.Zero) Marshal.FreeHGlobal(list);
                if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
                if (jobs != IntPtr.Zero) Marshal.FreeHGlobal(jobs);
                if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
            }
            bool inside; Check(IsProcessInJob(process, job, out inside) && inside, "Original child must belong to our job");
            long creation, exit, kernel, user; Check(GetProcessTimes(process, out creation, out exit, out kernel, out user), "Original creation identity");
            CreationFileTime = creation;
            var image = new StringBuilder(32768); uint length = (uint)image.Capacity;
            Check(QueryFullProcessImageNameW(process, 0, image, ref length), "Original kernel image"); Image = image.ToString();
            if (!String.Equals(Path.GetFullPath(start.FileName), Image, StringComparison.OrdinalIgnoreCase) || GetPriorityClass(process) != BelowNormal)
                throw new InvalidOperationException("Original image/priority differs");
            if (ResumeThread(thread) != 1) throw new Win32Exception(Marshal.GetLastWin32Error(), "Resume once");
            thread.Dispose(); thread = null;
        }
        // Bounded, current membership samples from the retained ORIGINAL job.
        // Membership is checked on an opened handle, so a reused PID alone is not attribution.
        [DllImport("kernel32.dll", EntryPoint = "QueryInformationJobObject", SetLastError = true)]
        static extern bool QueryJobMembers(SafeFileHandle ownedJob, int kind, IntPtr buffer, uint length, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern SafeFileHandle OpenProcess(uint access, bool inherit, uint pid);
        public sealed class MemberIdentity
        {
            public int PID { get; set; }
            public long CreationFileTime { get; set; }
            public string Image { get; set; }
            public bool MembershipVerified { get; set; }
            public string Error { get; set; }
        }
        public MemberIdentity[] SnapshotMembers()
        {
            if (Closed || job == null || job.IsInvalid) return new MemberIdentity[0];
            const int capacity = 1024, bytes = 8 + capacity * 8;
            IntPtr buffer = Marshal.AllocHGlobal(bytes);
            try
            {
                Check(QueryJobMembers(job, 3, buffer, bytes, IntPtr.Zero), "Read bounded original job members");
                int count = Marshal.ReadInt32(buffer, 4);
                if (count < 0 || count > capacity) throw new InvalidOperationException("Original job member limit exceeded");
                var result = new MemberIdentity[count];
                for (int i = 0; i < count; i++)
                {
                    long rawPid = Marshal.ReadInt64(buffer, 8 + i * 8);
                    if (rawPid <= 0 || rawPid > Int32.MaxValue) throw new InvalidOperationException("Invalid job PID");
                    var identity = new MemberIdentity { PID = (int)rawPid };
                    result[i] = identity;
                    using (var member = OpenProcess(0x101000, false, (uint)rawPid))
                    {
                        if (member.IsInvalid) { identity.Error = "Member exited or cannot be opened: " + Marshal.GetLastWin32Error(); continue; }
                        bool belongs;
                        if (!IsProcessInJob(member, job, out belongs) || !belongs)
                        { identity.Error = "Opened process is no longer a verified member"; continue; }
                        long creation, exit, kernel, user;
                        if (!GetProcessTimes(member, out creation, out exit, out kernel, out user))
                        { identity.Error = "Member creation identity unavailable"; continue; }
                        uint size = 32768; var image = new StringBuilder((int)size);
                        if (!QueryFullProcessImageNameW(member, 0, image, ref size))
                        { identity.Error = "Member image unavailable"; continue; }
                        identity.CreationFileTime = creation; identity.Image = image.ToString(); identity.MembershipVerified = true;
                    }
                }
                return result;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        public bool RootExited()
        {
            if (process == null) return true;
            uint state = WaitForSingleObject(process, 0);
            if (state == 0) return true; if (state == 258) return false;
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Original handle wait");
        }
        uint ActiveProcesses()
        {
            if (job == null || job.IsInvalid) return 0;
            Accounting info;
            Check(QueryInformationJobObject(job, 1, out info, (uint)Marshal.SizeOf<Accounting>(), IntPtr.Zero), "Owned job accounting; retain lease if unavailable");
            return info.active;
        }
        public bool TreeExited()
        {
            if (Closed) return true;
            return !createPending && RootExited() && ActiveProcesses() == 0;
        }
        public void StopAndConfirm(int timeoutMs)
        {
            if (Closed) return;
            if (timeoutMs < 1 || timeoutMs > 10000) throw new ArgumentOutOfRangeException("timeoutMs");
            var timer = Stopwatch.StartNew();
            if (job != null && !job.IsInvalid) Check(TerminateJobObject(job, 0xe0000001), "Terminate only our job tree");
            while (true)
            {
                bool exited = TreeExited();
                if (timer.ElapsedMilliseconds >= timeoutMs) throw new TimeoutException("Owned tree closure unconfirmed; quarantine lease");
                if (exited) break;
                Thread.Sleep(20);
            }
            CloseConfirmed();
        }
        public void CloseConfirmed()
        {
            if (Closed) return;
            if (!TreeExited()) throw new InvalidOperationException("Cannot close owner before exact tree is empty");
            if (process != null) { uint code; Check(GetExitCodeProcess(process, out code), "Original exit code"); ExitCode = unchecked((int)code); }
            if (thread != null) thread.Dispose();
            if (process != null) process.Dispose();
            if (input != null) input.Dispose();
            if (output != null) output.Dispose();
            if (error != null) error.Dispose();
            if (imageGuard != null) imageGuard.Dispose();
            if (job != null) job.Dispose();
            Closed = true;
        }
    }
}
