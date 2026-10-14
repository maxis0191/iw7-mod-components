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
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, ref SecurityAttributes security, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteFile(SafeFileHandle file, byte[] bytes, uint count, out uint written, IntPtr overlapped);
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
    public sealed class ProcessIdentity
    {
        public int PID { get; internal set; }
        public long CreationFileTime { get; internal set; }
        public string Image { get; internal set; }
    }
    public sealed class OwnedProcess : IDisposable
    {
        IntPtr handle;
        SafeFileHandle consoleInput;
        readonly bool consoleDedicated;
        readonly bool collisionProbeConsole;
        readonly System.Collections.Generic.HashSet<string> collisionSent = new System.Collections.Generic.HashSet<string>(StringComparer.Ordinal);
        string consoleNonce;
        readonly object consoleLock = new object();
        readonly System.Collections.Generic.HashSet<string> consoleSent = new System.Collections.Generic.HashSet<string>(StringComparer.Ordinal);
        public int Id { get; private set; }
        internal OwnedProcess(IntPtr value, int id) { handle=value; Id=id; }
        internal OwnedProcess(IntPtr value, int id, SafeFileHandle input, bool dedicated, bool collision=false) : this(value,id) { consoleInput=input; consoleDedicated=dedicated; collisionProbeConsole=collision; }
        public bool OriginalRigConsoleEnabled { get { CheckOpen(); return !collisionProbeConsole && consoleInput!=null && !consoleInput.IsClosed; } }
        public bool CollisionProbeConsoleEnabled { get { CheckOpen(); return collisionProbeConsole && consoleDedicated && consoleInput!=null && !consoleInput.IsClosed; } }
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
        // Observe this original kernel handle without reopening a possibly
        // reused PID or reading the loader's aliased main-module name.
        public ProcessIdentity ReadIdentity() {
            CheckOpen();
            if (HasExited) throw new InvalidOperationException("Original process exited");
            long created,exited,kernel,user;
            var image=new StringBuilder(32768); int size=image.Capacity;
            if (!GetProcessTimes(handle,out created,out exited,out kernel,out user) ||
                !QueryFullProcessImageNameW(handle,0,image,ref size))
                throw new Win32Exception(Marshal.GetLastWin32Error(),"Original process identity read failed");
            if (HasExited) throw new InvalidOperationException("Original process exited during identity read");
            return new ProcessIdentity { PID=Id, CreationFileTime=created, Image=image.ToString() };
        }
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
        // The pipe is private to the creating owner. A byte-write receipt is
        // not engine consumption, an asset lookup result or gameplay proof.
        public int WriteOriginalRigCommand(string command, string expectedImage, long expectedCreation, string nonce, long safetyPublicationTick)
        {
            lock(consoleLock) {
            CheckOpen();
            if (!IsOriginalRigCommand(command)) throw new ArgumentException("Only the eight fixed original-rig commands are allowed.");
            if (!OriginalRigConsoleEnabled) throw new InvalidOperationException("Original-rig console input was not enabled at creation.");
            if (!consoleDedicated && command.StartsWith("set ",StringComparison.Ordinal)) throw new InvalidOperationException("Rig play/stop controls belong to the dedicated process only.");
            if (!System.Text.RegularExpressions.Regex.IsMatch(nonce ?? "", "\\A[a-f0-9]{32}\\z")) throw new ArgumentException("Current native client nonce required.");
            var identity=ReadIdentity();
            if (identity.CreationFileTime!=expectedCreation || !String.Equals(identity.Image,expectedImage,StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Original console process identity differs.");
            long now=Environment.TickCount64;
            if (safetyPublicationTick<=0 || now<safetyPublicationTick || now-safetyPublicationTick>250)
                throw new InvalidOperationException("Current native safety publication expired before console write.");
            if (consoleNonce!=null && !String.Equals(consoleNonce,nonce,StringComparison.Ordinal))
                throw new InvalidOperationException("Native client nonce changed; console input refused.");
            if (consoleSent.Contains(command)) throw new InvalidOperationException("Each fixed rig command may be written once per owned process.");
            // At most eight short ASCII lines, below this pipe's 4096-byte
            // capacity even if the engine never reads. Never flush/wait here.
            byte[] bytes=Encoding.ASCII.GetBytes(command+"\n");
            uint written;
            consoleNonce=nonce; consoleSent.Add(command);
            if (!WriteFile(consoleInput,bytes,(uint)bytes.Length,out written,IntPtr.Zero) || written!=bytes.Length)
                throw new Win32Exception(Marshal.GetLastWin32Error(),"Owned rig stdin write failed or was incomplete.");
            return (int)written;
            }
        }
        // A separate dedicated-only role. Never accepts a caller PID, a rig
        // command, arbitrary console text or a fabricated client safety wire.
        public int WriteCollisionProbeCommand(string command, string expectedImage, long expectedCreation)
        {
            lock(consoleLock) {
            CheckOpen();
            if (!IsCollisionProbeCommand(command) || !CollisionProbeConsoleEnabled)
                throw new ArgumentException("Exact owned dedicated collision console required.");
            var identity=ReadIdentity();
            if (identity.CreationFileTime!=expectedCreation || !String.Equals(identity.Image,expectedImage,StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Original collision process identity differs.");
            if (collisionSent.Contains(command)) throw new InvalidOperationException("Each collision command may be written once.");
            byte[] bytes=Encoding.ASCII.GetBytes(command+"\n");
            uint written;
            collisionSent.Add(command);
            if (!WriteFile(consoleInput,bytes,(uint)bytes.Length,out written,IntPtr.Zero) || written!=bytes.Length)
                throw new Win32Exception(Marshal.GetLastWin32Error(),"Owned collision stdin write failed or incomplete.");
            return (int)written;
            }
        }
        public void Dispose() {
            lock(consoleLock) {
            if (handle!=IntPtr.Zero) {
                // Closing stdin while getline is alive would leave the official
                // wincon EOF loop spinning. Preserve both handles until exit.
                if (consoleInput!=null && !HasExited) throw new InvalidOperationException("Close the exact owned console process before disposing its input.");
                if (consoleInput!=null) { consoleInput.Dispose(); consoleInput=null; }
                CloseHandle(handle); handle=IntPtr.Zero;
            }
            }
        }
    }
    public static bool IsOriginalRigCommand(string command)
    {
        switch (command) {
            case "listassetpool 8 paris_doom_skin_two_bone_first_a":
            case "listassetpool 8 paris_doom_skin_two_bone_second_a":
            case "listassetpool 7 paris_doom_skin_two_bone_first_a_lod0":
            case "listassetpool 7 paris_doom_skin_two_bone_second_a_lod0":
            case "listassetpool 6 paris_original_probe_bend":
            case "listassetpool 10 mopw/character_park_clown_zombie_shoes":
            case "set sdk_original_rig_probe_play 1":
            case "set sdk_original_rig_probe_stop 1": return true;
            default: return false;
        }
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
        return StartOwned(exe, arguments, cwd, stdout, stderr, desktopName, true);
    }
    // Console asset tools may exit before registration. Return their original
    // kernel handle without waiting for a GUI idle state or rejecting fast exit.
    public static OwnedProcess StartOwned(string exe, string arguments, string cwd, string stdout, string stderr, string desktopName, bool waitForInputIdle)
    {
        return StartOwned(exe,arguments,cwd,stdout,stderr,desktopName,waitForInputIdle,false);
    }
    public static OwnedProcess StartOwned(string exe, string arguments, string cwd, string stdout, string stderr, string desktopName, bool waitForInputIdle, bool originalRigConsole)
    {
        return StartOwned(exe,arguments,cwd,stdout,stderr,desktopName,waitForInputIdle,originalRigConsole,false);
    }
    public static bool IsCollisionProbeCommand(string command)
    {
        return command=="set paris_collision_probe_arm 1" || command=="quit";
    }
    public static bool IsCollisionProbeLaunch(string arguments)
    {
        var flags=new System.Collections.Generic.HashSet<string>(arguments.Split(new [] {' ','\t','\r','\n'},StringSplitOptions.RemoveEmptyEntries),StringComparer.Ordinal);
        return flags.Contains("-dedicated") && flags.Contains("-wincon") && flags.Contains("-paris-isolated-lab") &&
            flags.Contains("-paris-server-test") && flags.Contains("-paris-collision-provider") &&
            !flags.Contains("-paris-server-client-test") && !flags.Contains("-noconsole") && !flags.Contains("-syscon") && !flags.Contains("-terminal");
    }
    public static OwnedProcess StartOwned(string exe, string arguments, string cwd, string stdout, string stderr, string desktopName, bool waitForInputIdle, bool originalRigConsole, bool collisionProbeConsole)
    {
        if (exe.Contains("\"") || !System.Text.RegularExpressions.Regex.IsMatch(desktopName, "^IW7ParisLab_[a-f0-9]{32}$"))
            throw new ArgumentException("Invalid executable/desktop name.");
        bool consoleDedicated=false;
        if (collisionProbeConsole) {
            if (originalRigConsole || !IsCollisionProbeLaunch(arguments)) throw new ArgumentException("Collision stdin requires its exclusive private dedicated wincon profile.");
            consoleDedicated=true;
        }
        if (originalRigConsole) {
            var tokens=arguments.Split(new [] {' ','\t','\r','\n'},StringSplitOptions.RemoveEmptyEntries);
            var flags=new System.Collections.Generic.HashSet<string>(tokens,StringComparer.Ordinal);
            bool dedicated=flags.Contains("-dedicated");
            consoleDedicated=dedicated;
            if (!flags.Contains("-wincon") || !flags.Contains("-paris-isolated-lab") ||
                flags.Contains("-noconsole") || flags.Contains("-syscon") || flags.Contains("-terminal") ||
                (dedicated ? (!flags.Contains("-paris-server-test") || flags.Contains("-paris-server-client-test")) :
                    (!flags.Contains("-paris-server-client-test") || flags.Contains("-paris-server-test"))))
                throw new ArgumentException("Rig stdin requires explicit isolated server/client test flags and wincon.");
        }
        var security = new SecurityAttributes {length=Marshal.SizeOf(typeof(SecurityAttributes)), inherit=true};
        IntPtr desktop = CreateDesktopW(desktopName, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000, ref security);
        if (desktop == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateDesktop failed");
        try {
            using (var output = new FileStream(stdout, FileMode.CreateNew, FileAccess.Write, FileShare.ReadWrite))
            using (var error = new FileStream(stderr, FileMode.CreateNew, FileAccess.Write, FileShare.ReadWrite))
            {
                SafeFileHandle input=null,writer=null;
                try {
                if (originalRigConsole || collisionProbeConsole) {
                    if (!CreatePipe(out input,out writer,ref security,4096)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Rig stdin pipe creation failed.");
                    if (!SetHandleInformation(writer.DangerousGetHandle(),1,0)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Rig stdin writer inheritance refusal failed.");
                } else input=CreateFileW("NUL",0x80000000,3,IntPtr.Zero,3,0,IntPtr.Zero);
                if (input.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Owned input failed");
                foreach (var handle in new [] {output.SafeFileHandle, error.SafeFileHandle, input})
                    if (!SetHandleInformation(handle.DangerousGetHandle(), 1, 1)) throw new Win32Exception(Marshal.GetLastWin32Error());
                var startup = new StartupInfo {cb=Marshal.SizeOf(typeof(StartupInfo)), desktop="WinSta0\\" + desktopName,
                    flags=0x101, show=0, input=input.DangerousGetHandle(),
                    output=output.SafeFileHandle.DangerousGetHandle(), error=error.SafeFileHandle.DangerousGetHandle()};
                ProcessInfo process;
                if (!CreateProcessW(exe, new StringBuilder("\"" + exe + "\" " + arguments), IntPtr.Zero, IntPtr.Zero,
                    true, 0x08000200u | (waitForInputIdle ? 0u : 0x00004000u), IntPtr.Zero, cwd, ref startup, out process))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Private desktop process launch failed");
                try {
                    if (waitForInputIdle) {
                        WaitForInputIdle(process.process, 10000);
                        uint code;
                        if (WaitForSingleObject(process.process, 0) == 0 && GetExitCodeProcess(process.process, out code))
                            throw new InvalidOperationException("Child exited with code 0x" + code.ToString("X8"));
                    }
                    var owned=new OwnedProcess(process.process,(int)process.pid,writer,consoleDedicated,collisionProbeConsole);
                    writer=null;
                    process.process=IntPtr.Zero;
                    return owned;
                }
                finally { CloseHandle(process.thread); if (process.process!=IntPtr.Zero) CloseHandle(process.process); }
                } finally { if(input!=null)input.Dispose(); if(writer!=null)writer.Dispose(); }
            }
        } finally { CloseDesktop(desktop); }
    }
}
