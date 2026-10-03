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
    [DllImport("user32.dll")] static extern uint WaitForInputIdle(IntPtr process, uint milliseconds);
    public static int Start(string exe, string arguments, string cwd, string stdout, string stderr, string desktopName)
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
                    if (GetExitCodeProcess(process.process, out code) && code != 259)
                        throw new InvalidOperationException("Child exited with code 0x" + code.ToString("X8"));
                    return (int)process.pid;
                }
                finally { CloseHandle(process.thread); CloseHandle(process.process); }
            }
        } finally { CloseDesktop(desktop); }
    }
}
