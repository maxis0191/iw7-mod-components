using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

// Launch into a non-input Windows desktop. Never call SwitchDesktop.
public static class IW7LabProcess
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo {
        public int cb; public string reserved, desktop, title;
        public uint x, y, xSize, ySize, xChars, yChars, fill, flags;
        public short show, reservedSize; public IntPtr reservedBytes, input, output, error;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr process, thread; public uint pid, tid; }
    [StructLayout(LayoutKind.Sequential)]
    struct SecurityAttributes { public int length; public IntPtr descriptor; [MarshalAs(UnmanagedType.Bool)] public bool inherit; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr mode, uint flags, uint access, ref SecurityAttributes security);
    [DllImport("user32.dll", SetLastError=true)] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcessW(string exe, StringBuilder cmd, IntPtr processAttributes, IntPtr threadAttributes,
        bool inherit, uint flags, IntPtr environment, string cwd, ref StartupInfo startup, out ProcessInfo info);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr handle, uint code);
    [DllImport("user32.dll")] static extern uint WaitForInputIdle(IntPtr process, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder path, ref int size);
    [DllImport("psapi.dll", SetLastError=true)] static extern bool EmptyWorkingSet(IntPtr process);
    // Keep the verified kernel object alive across exit and PID reuse. All wait,
    // exit-code and termination operations below use this same handle.
    public sealed class OwnedProcess : IDisposable
    {
        IntPtr handle;
        public int Id { get; private set; }
        internal OwnedProcess(IntPtr value, int id) { handle=value; Id=id; }
        void CheckOpen() { if (handle==IntPtr.Zero) throw new ObjectDisposedException("OwnedProcess"); }
        public bool WaitForExit(int milliseconds) {
            CheckOpen();
            if (milliseconds < 0) throw new ArgumentOutOfRangeException("milliseconds");
            uint result=WaitForSingleObject(handle,(uint)milliseconds);
            if (result==0) return true;
            if (result==258) return false;
            throw new Win32Exception(Marshal.GetLastWin32Error(),"Owned process wait failed");
        }
        public bool HasExited { get { return WaitForExit(0); } }
        public uint ExitCode { get {
            CheckOpen();
            if (!HasExited) throw new InvalidOperationException("Owned process is still running");
            uint code;
            if (!GetExitCodeProcess(handle,out code)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return code;
        } }
        public void Terminate(uint code) {
            CheckOpen();
            if (!HasExited && !TerminateProcess(handle,code)) {
                int error=Marshal.GetLastWin32Error();
                if (!HasExited) throw new Win32Exception(error,"Owned process termination failed");
            }
        }
        public void Dispose() { if (handle!=IntPtr.Zero) { CloseHandle(handle); handle=IntPtr.Zero; } }
    }
    public static OwnedProcess OpenOwned(int pid, string expectedImage, long expectedCreation)
    {
        IntPtr process=OpenProcess(0x101001,false,pid); // SYNCHRONIZE | LIMITED_QUERY | TERMINATE
        if (process==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Owned process access failed");
        try {
            long created,exited,kernel,user;
            var image=new StringBuilder(32768); int size=image.Capacity;
            if (!GetProcessTimes(process,out created,out exited,out kernel,out user) ||
                !QueryFullProcessImageNameW(process,0,image,ref size))
                throw new Win32Exception(Marshal.GetLastWin32Error(),"Owned process identity read failed");
            if (Math.Abs(created-expectedCreation)>10 || !String.Equals(image.ToString(),expectedImage,StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Owned process identity changed; operation refused");
            var owned=new OwnedProcess(process,pid); process=IntPtr.Zero; return owned;
        } finally { if (process!=IntPtr.Zero) CloseHandle(process); }
    }
    // A one-time OS paging hint after loading, not an allocation/free or a cap.
    // Validate the same opened handle; never target an unowned game by PID alone.
    public static void TrimWorkingSet(int pid, string expectedImage, long expectedCreation)
    {
        IntPtr process = OpenProcess(0x1100, false, pid); // LIMITED_QUERY | SET_QUOTA
        if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Owned process access failed");
        try {
            long created, exited, kernel, user;
            var image = new StringBuilder(32768);
            int size = image.Capacity;
            if (!GetProcessTimes(process, out created, out exited, out kernel, out user) ||
                !QueryFullProcessImageNameW(process, 0, image, ref size))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Owned process identity read failed");
            // WMI reports creation time to microsecond precision.
            if (Math.Abs(created - expectedCreation) > 10 ||
                !String.Equals(image.ToString(), expectedImage, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Owned process identity changed; memory operation refused");
            if (!EmptyWorkingSet(process))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Owned working-set trim failed");
        } finally { CloseHandle(process); }
    }
    public static int Start(string exe, string arguments, string cwd, string stdout, string stderr, string desktopName)
    {
        using (var owned=StartOwned(exe,arguments,cwd,stdout,stderr,desktopName)) return owned.Id;
    }
    public static OwnedProcess StartOwned(string exe, string arguments, string cwd, string stdout, string stderr, string desktopName)
    {
        if (exe.Contains("\"") || !System.Text.RegularExpressions.Regex.IsMatch(desktopName, "^IW7ParisLab_[a-f0-9]{32}$"))
            throw new ArgumentException("Invalid executable/desktop name.");
        var security = new SecurityAttributes {length=Marshal.SizeOf(typeof(SecurityAttributes)), inherit=true};
        IntPtr desktop = CreateDesktopW(desktopName, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000, ref security);
        if (desktop == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateDesktop failed");
        try {
            using (var output = new FileStream(stdout, FileMode.CreateNew, FileAccess.Write, FileShare.ReadWrite))
            using (var error = new FileStream(stderr, FileMode.CreateNew, FileAccess.Write, FileShare.ReadWrite))
            using (var input = CreateFileW("NUL", 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
                if (input.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "NUL input failed");
                foreach (var handle in new [] {output.SafeFileHandle, error.SafeFileHandle, input})
                    if (!SetHandleInformation(handle.DangerousGetHandle(), 1, 1)) throw new Win32Exception(Marshal.GetLastWin32Error());
                var startup = new StartupInfo {cb=Marshal.SizeOf(typeof(StartupInfo)), desktop="WinSta0\\" + desktopName,
                    flags=0x101, show=0, input=input.DangerousGetHandle(),
                    output=output.SafeFileHandle.DangerousGetHandle(), error=error.SafeFileHandle.DangerousGetHandle()};
                ProcessInfo process;
                if (!CreateProcessW(exe, new StringBuilder("\"" + exe + "\" " + arguments), IntPtr.Zero, IntPtr.Zero,
                    true, 0x08000200, IntPtr.Zero, cwd, ref startup, out process))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Private desktop process launch failed");
                try {
                    WaitForInputIdle(process.process, 10000);
                    uint code;
                    if (WaitForSingleObject(process.process, 0) == 0 && GetExitCodeProcess(process.process, out code))
                        throw new InvalidOperationException("Child exited with code 0x" + code.ToString("X8"));
                    var owned=new OwnedProcess(process.process,(int)process.pid);
                    process.process=IntPtr.Zero;
                    return owned;
                }
                finally { CloseHandle(process.thread); if (process.process!=IntPtr.Zero) CloseHandle(process.process); }
            }
        } finally { CloseDesktop(desktop); }
    }
}
