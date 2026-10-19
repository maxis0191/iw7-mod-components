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
        readonly int capacityPeerPort;
        readonly System.Collections.Generic.HashSet<string> collisionSent = new System.Collections.Generic.HashSet<string>(StringComparer.Ordinal);
        string consoleNonce;
        readonly object consoleLock = new object();
        readonly System.Collections.Generic.HashSet<string> consoleSent = new System.Collections.Generic.HashSet<string>(StringComparer.Ordinal);
        public int Id { get; private set; }
        internal OwnedProcess(IntPtr value, int id) { handle=value; Id=id; }
        internal OwnedProcess(IntPtr value, int id, SafeFileHandle input, bool dedicated, bool collision=false, int capacityPort=0) : this(value,id) { consoleInput=input; consoleDedicated=dedicated; collisionProbeConsole=collision; capacityPeerPort=capacityPort; }
        public bool OriginalRigConsoleEnabled { get { CheckOpen(); return !collisionProbeConsole && capacityPeerPort==0 && consoleInput!=null && !consoleInput.IsClosed; } }
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
        public void WriteCapacityLifecycle(string action,string expectedImage,long expectedCreation) {
            lock(consoleLock) {
                CheckOpen();
                if(capacityPeerPort<27100 || capacityPeerPort>27999 || consoleInput==null || consoleInput.IsClosed ||
                   (action!="connect" && action!="stop") || consoleSent.Contains(action)) throw new InvalidOperationException("Fixed owned capacity lifecycle required");
                var identity=ReadIdentity();
                if(identity.CreationFileTime!=expectedCreation || !String.Equals(identity.Image,expectedImage,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Capacity client identity differs");
                string command=action=="connect" ? "connect 127.0.0.1:"+capacityPeerPort : "quit";
                byte[] bytes=Encoding.ASCII.GetBytes(command+"\n");uint written;
                consoleSent.Add(action);
                if(!WriteFile(consoleInput,bytes,(uint)bytes.Length,out written,IntPtr.Zero) || written!=bytes.Length) throw new Win32Exception(Marshal.GetLastWin32Error(),"Capacity lifecycle write incomplete");
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
        return StartOwned(exe,arguments,cwd,stdout,stderr,desktopName,waitForInputIdle,originalRigConsole,collisionProbeConsole,0);
    }
    public static OwnedProcess StartOwned(string exe, string arguments, string cwd, string stdout, string stderr, string desktopName, bool waitForInputIdle, bool originalRigConsole, bool collisionProbeConsole,int capacityPeerPort)
    {
        if (exe.Contains("\"") || !System.Text.RegularExpressions.Regex.IsMatch(desktopName, "^IW7ParisLab_[a-f0-9]{32}$"))
            throw new ArgumentException("Invalid executable/desktop name.");
        bool consoleDedicated=false;
        if(capacityPeerPort!=0) {
            if(originalRigConsole || collisionProbeConsole || capacityPeerPort<27100 || capacityPeerPort>27999 ||
               !System.Text.RegularExpressions.Regex.IsMatch(arguments,@"(?:^|\s)-wincon(?:\s|$)") ||
               !System.Text.RegularExpressions.Regex.IsMatch(arguments,@"(?:^|\s)-paris-capacity-client-probe(?:\s|$)") ||
               !System.Text.RegularExpressions.Regex.IsMatch(arguments,@"(?:^|\s)-paris-capacity-production(?:\s|$)") ||
               !System.Text.RegularExpressions.Regex.IsMatch(arguments,@"(?:^|\s)-paris-capacity-64(?:\s|$)") ||
               !System.Text.RegularExpressions.Regex.IsMatch(arguments,@"(?:^|\s)\+set\s+net_ip\s+127\.0\.0\.1(?:\s|$)") ||
               System.Text.RegularExpressions.Regex.IsMatch(arguments,@"(?:^|\s)-(?:dedicated|paris-isolated-lab|paris-debugger|paris-server-test|paris-server-client-test|noconsole|syscon|terminal)(?:\s|$)")) throw new ArgumentException("Normal capacity lifecycle requires its loopback-only client wincon role");
        }
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
                if (originalRigConsole || collisionProbeConsole || capacityPeerPort!=0) {
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
                    var owned=new OwnedProcess(process.process,(int)process.pid,writer,consoleDedicated,collisionProbeConsole,capacityPeerPort);
                    writer=null;
                    process.process=IntPtr.Zero;
                    return owned;
                }
                finally { CloseHandle(process.thread); if (process.process!=IntPtr.Zero) CloseHandle(process.process); }
                } finally { if(input!=null)input.Dispose(); if(writer!=null)writer.Dispose(); }
            }
        } finally { CloseDesktop(desktop); }
    }
    // Separate opt-in STARTUP owner. Legacy factories/owners above are unchanged.
    // The parent MUST store this object before Launch: Launch never returns/adopts another owner.
    public static StrictStartupOwner CreateStrictStartupOwner() { return new StrictStartupOwner(new StrictStartupNative(), true); }
    public static StrictStartupOwner CreateStrictStartupOwnerForPureTests(IStrictStartupBackend backend) {
        if (backend==null) throw new ArgumentNullException("backend");
        return new StrictStartupOwner(backend, false);
    }
    public enum StrictDisposition { NotAcquired, Open, Closed, Refused, Unknown }
    public struct StrictIdentity { public int PID; public uint ThreadID; public long CreatedFileTime; public string Image; }
    public interface IStrictStartupBackend {
        IntPtr Desktop(string name, out int error);
        IntPtr File(string path, uint access, uint sharing, uint creation, out int error);
        bool Inherit(IntPtr value, out int error);
        bool HashGuard(IntPtr value, out string hash, out long bytes, out int error);
        bool Launch(string image, string arguments, string cwd, string desktop, IntPtr input, IntPtr output, IntPtr errorOutput,
            out IntPtr process, out IntPtr thread, out int pid, out uint tid, out int error);
        bool Identity(IntPtr process, IntPtr thread, out StrictIdentity identity, out int error);
        uint Wait(IntPtr process, uint milliseconds, out int error);
        bool ExitCode(IntPtr process, out uint code, out int error);
        bool Terminate(IntPtr process, uint code, out int error);
        bool Close(IntPtr value, bool desktop, out int error);
    }
    public sealed class StrictStartupOwner : IDisposable {
        sealed class Retained {
            internal IntPtr Value; internal bool Acquired; internal StrictDisposition State=StrictDisposition.NotAcquired;
            internal void Capture(IntPtr value) { Value=value; Acquired=true; State=StrictDisposition.Open; }
            internal bool Closed { get { return Acquired ? State==StrictDisposition.Closed && Value==IntPtr.Zero : State==StrictDisposition.NotAcquired; } }
        }
        readonly IStrictStartupBackend backend;
        // Every slot exists before the first acquisition; no acquired object depends on a subsequent allocation.
        readonly Retained imageGuard=new Retained(), input=new Retained(), output=new Retained(), errorOutput=new Retained();
        readonly Retained desktop=new Retained(), process=new Retained(), thread=new Retained();
        bool launchAttempted, identityVerified, identityRecorded, originalExited;
        string expectedImage, expectedHash;
        StrictIdentity identity;
        public bool UsesNativeBackend { get; private set; }
        public int Id { get; private set; }
        public uint InitialThreadId { get; private set; }
        public long CreationFileTime { get { return identityVerified ? identity.CreatedFileTime : 0; } }
        public string OriginalImage { get { return identityVerified ? identity.Image : null; } }
        public string GuardSHA256 { get; private set; }
        public long GuardBytes { get; private set; }
        public bool IdentityVerified { get { return identityVerified; } }
        public bool OriginalExitObserved { get { return originalExited; } }
        public int LastWinError { get; private set; }
        public string LastFailure { get; private set; }
        public StrictDisposition ProcessDisposition { get { return process.State; } }
        public StrictDisposition ThreadDisposition { get { return thread.State; } }
        public StrictDisposition DesktopDisposition { get { return desktop.State; } }
        public StrictDisposition GuardDisposition { get { return imageGuard.State; } }
        public StrictDisposition InputDisposition { get { return input.State; } }
        public StrictDisposition OutputDisposition { get { return output.State; } }
        public StrictDisposition ErrorDisposition { get { return errorOutput.State; } }
        public bool Closed { get { return process.Closed && thread.Closed && desktop.Closed && imageGuard.Closed && input.Closed && output.Closed && errorOutput.Closed; } }
        internal StrictStartupOwner(IStrictStartupBackend value, bool native) { backend=value; UsesNativeBackend=native; }
        void Fail(string stage, int error) { LastFailure=stage; LastWinError=error; throw new Win32Exception(error,stage); }
        static bool Valid(IntPtr value) { return value!=IntPtr.Zero && value!=new IntPtr(-1); }
        void Capture(Retained slot, IntPtr value, string stage, int error) {
            if (!Valid(value)) Fail(stage,error);
            slot.Capture(value);
        }
        public void Launch(string image, string arguments, string cwd, string stdout, string stderr, string desktopName, string imageSHA256) {
            if (launchAttempted) throw new InvalidOperationException("Strict owner cannot rearm/relaunch or adopt a different child");
            launchAttempted=true;
            if (image==null || image.Contains("\"") || arguments==null || cwd==null || stdout==null || stderr==null ||
                !System.Text.RegularExpressions.Regex.IsMatch(desktopName ?? "", "^IW7ParisLab_[a-f0-9]{32}$") ||
                !System.Text.RegularExpressions.Regex.IsMatch(imageSHA256 ?? "", "^[A-F0-9]{64}$"))
                throw new ArgumentException("Invalid strict launch/guard binding");
            expectedImage=Path.GetFullPath(image); expectedHash=imageSHA256;
            int e;
            Capture(imageGuard,backend.File(expectedImage,0x80000000u,1,3,out e),"image guard acquisition",e);
            string hash; long bytes;
            if (!backend.HashGuard(imageGuard.Value,out hash,out bytes,out e)) Fail("original image guard hash",e);
            GuardSHA256=hash; GuardBytes=bytes;
            if (bytes<=0 || bytes>64L*1024*1024 || !String.Equals(hash,expectedHash,StringComparison.Ordinal))
                throw new InvalidOperationException("Strict original image guard bytes differ");
            Capture(desktop,backend.Desktop(desktopName,out e),"desktop acquisition",e);
            Capture(output,backend.File(stdout,0x40000000u,1,1,out e),"stdout CreateNew",e);
            Capture(errorOutput,backend.File(stderr,0x40000000u,1,1,out e),"stderr CreateNew",e);
            Capture(input,backend.File("NUL",0x80000000u,3,3,out e),"NUL acquisition",e);
            if (!backend.Inherit(input.Value,out e) || !backend.Inherit(output.Value,out e) || !backend.Inherit(errorOutput.Value,out e)) Fail("stdio inheritance",e);
            IntPtr p,t; int pid; uint tid;
            bool started=backend.Launch(expectedImage,arguments,Path.GetFullPath(cwd),desktopName,input.Value,output.Value,errorOutput.Value,out p,out t,out pid,out tid,out e);
            // Capture partial API outputs even when CreateProcess reports failure. Do not discard either handle.
            if (Valid(p)) process.Capture(p);
            if (Valid(t)) thread.Capture(t);
            Id=pid; InitialThreadId=tid;
            if (!started || !process.Acquired || !thread.Acquired || pid<=0 || tid==0) Fail("original process launch",e);
            if (!RefreshOriginalIdentity()) Fail("original process identity",LastWinError);
            // No GUI-idle check: a fast exit still leaves this original process/thread owner recoverable.
        }
        public bool RefreshOriginalIdentity() {
            if (!process.Acquired || process.Closed || !thread.Acquired || thread.Closed) throw new InvalidOperationException("Original identity handles unavailable");
            identityVerified=false;
            StrictIdentity fresh; int e;
            if (!backend.Identity(process.Value,thread.Value,out fresh,out e)) { LastFailure="original identity read"; LastWinError=e; return false; }
            if (fresh.PID!=Id || fresh.ThreadID!=InitialThreadId || fresh.CreatedFileTime<=0 ||
                !String.Equals(fresh.Image,expectedImage,StringComparison.OrdinalIgnoreCase) ||
                (identityRecorded && fresh.CreatedFileTime!=identity.CreatedFileTime)) {
                LastFailure="original identity mismatch"; LastWinError=0; return false;
            }
            identity=fresh; identityRecorded=true; identityVerified=true; return true;
        }
        public bool WaitForExit(int milliseconds) {
            if (milliseconds<0) throw new ArgumentOutOfRangeException("milliseconds");
            if (!process.Acquired || process.Closed) throw new InvalidOperationException("Original process handle unavailable");
            int e; uint result=backend.Wait(process.Value,(uint)milliseconds,out e);
            if (result==0) { originalExited=true; return true; }
            if (result==258) return false;
            Fail("original process wait",e); return false;
        }
        public bool HasExited { get { return WaitForExit(0); } }
        public uint ExitCode { get {
            if (!HasExited) throw new InvalidOperationException("Original process is running");
            uint code; int e; if (!backend.ExitCode(process.Value,out code,out e)) Fail("original exit code",e); return code;
        } }
        public void TerminateAfterVerifiedIdentity(uint code) {
            if (!identityVerified || !RefreshOriginalIdentity()) throw new InvalidOperationException("Original identity unconfirmed; termination refused");
            int e; if (!HasExited && !backend.Terminate(process.Value,code,out e)) Fail("original process termination",e);
        }
        bool CloseOne(Retained slot, bool isDesktop) {
            if (slot.Closed) return true;
            int e;
            try {
                if (!backend.Close(slot.Value,isDesktop,out e)) { slot.State=StrictDisposition.Refused; LastFailure="original close refused"; LastWinError=e; return false; }
                slot.Value=IntPtr.Zero; slot.State=StrictDisposition.Closed; return true;
            } catch { slot.State=StrictDisposition.Unknown; LastFailure="original close unknown"; return false; }
        }
        public bool TryClose() {
            // Never close a running/unknown original process owner; no automatic termination or PID reopen.
            if (process.Acquired && !process.Closed && !originalExited) {
                try { if (!WaitForExit(0)) { LastFailure="original process still running"; return false; } }
                catch { LastFailure="original process exit unknown"; return false; }
            }
            bool closed=true;
            if (!CloseOne(thread,false)) closed=false;
            if (!CloseOne(input,false)) closed=false;
            if (!CloseOne(output,false)) closed=false;
            if (!CloseOne(errorOutput,false)) closed=false;
            if (!CloseOne(desktop,true)) closed=false;
            if (!CloseOne(process,false)) closed=false;
            // Preserve the actual read-only executable guard until every original launch handle closes.
            if (closed && !CloseOne(imageGuard,false)) closed=false;
            return closed && Closed;
        }
        public void Dispose() { if (!TryClose()) throw new InvalidOperationException("Strict original closure pending; retain this same owner and host"); }
    }
    [DllImport("kernel32.dll",EntryPoint="CreateFileW",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern IntPtr StrictCreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",EntryPoint="CloseHandle",SetLastError=true)] static extern bool StrictCloseHandle(IntPtr value);
    [DllImport("kernel32.dll",EntryPoint="GetExitCodeProcess",SetLastError=true)] static extern bool StrictExitCode(IntPtr value,out uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint GetProcessId(IntPtr value);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint GetThreadId(IntPtr value);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint GetProcessIdOfThread(IntPtr value);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileSizeEx(IntPtr value,out long bytes);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFilePointerEx(IntPtr value,long distance,out long position,uint method);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadFile(IntPtr value,byte[] bytes,uint count,out uint read,IntPtr overlapped);
    sealed class StrictStartupNative : IStrictStartupBackend {
        public IntPtr Desktop(string name,out int e) {
            var s=new SecurityAttributes {length=Marshal.SizeOf(typeof(SecurityAttributes)),inherit=false};
            IntPtr value=CreateDesktopW(name,IntPtr.Zero,IntPtr.Zero,0,0x10000000,ref s); e=Marshal.GetLastWin32Error(); return value;
        }
        public IntPtr File(string path,uint access,uint share,uint creation,out int e) {
            IntPtr value=StrictCreateFile(path,access,share,IntPtr.Zero,creation,0,IntPtr.Zero); e=Marshal.GetLastWin32Error(); return value;
        }
        public bool Inherit(IntPtr value,out int e) { bool ok=SetHandleInformation(value,1,1);e=Marshal.GetLastWin32Error();return ok; }
        public bool HashGuard(IntPtr value,out string hash,out long bytes,out int e) {
            hash=null;bytes=0;e=0;long position;
            if (!GetFileSizeEx(value,out bytes) || bytes<=0 || bytes>64L*1024*1024 || !SetFilePointerEx(value,0,out position,0)) { e=Marshal.GetLastWin32Error(); return false; }
            var buffer=new byte[65536];long total=0;
            using (var sha=System.Security.Cryptography.SHA256.Create()) {
                while (total<bytes) {
                    uint count=(uint)Math.Min(buffer.Length,bytes-total),read;
                    if (!ReadFile(value,buffer,count,out read,IntPtr.Zero) || read==0 || read>count) { e=Marshal.GetLastWin32Error();return false; }
                    sha.TransformBlock(buffer,0,(int)read,buffer,0);total+=read;
                }
                sha.TransformFinalBlock(new byte[0],0,0);hash=BitConverter.ToString(sha.Hash).Replace("-","");
            }
            long after;
            if (!GetFileSizeEx(value,out after) || after!=bytes || !SetFilePointerEx(value,0,out position,0)) { e=Marshal.GetLastWin32Error(); return false; }
            return true;
        }
        public bool Launch(string image,string args,string cwd,string desk,IntPtr input,IntPtr output,IntPtr error,
            out IntPtr p,out IntPtr t,out int pid,out uint tid,out int e) {
            var s=new StartupInfo {cb=Marshal.SizeOf(typeof(StartupInfo)),desktop="WinSta0\\"+desk,flags=0x101,show=0,input=input,output=output,error=error};
            ProcessInfo info;
            bool ok=CreateProcessW(image,new StringBuilder("\""+image+"\" "+args),IntPtr.Zero,IntPtr.Zero,true,0x08004200u,IntPtr.Zero,cwd,ref s,out info);
            e=Marshal.GetLastWin32Error();p=info.process;t=info.thread;pid=(int)info.pid;tid=info.tid;return ok;
        }
        public bool Identity(IntPtr p,IntPtr t,out StrictIdentity identity,out int e) {
            identity=new StrictIdentity();e=0;uint pid=GetProcessId(p);
            if (pid==0) { e=Marshal.GetLastWin32Error();return false; }
            uint tid=GetThreadId(t);
            if (tid==0 || GetProcessIdOfThread(t)!=pid) { e=Marshal.GetLastWin32Error();return false; }
            long created,exited,kernel,user;
            if (!GetProcessTimes(p,out created,out exited,out kernel,out user)) { e=Marshal.GetLastWin32Error();return false; }
            var image=new StringBuilder(32768);int size=image.Capacity;
            if (!QueryFullProcessImageNameW(p,0,image,ref size)) { e=Marshal.GetLastWin32Error();return false; }
            identity=new StrictIdentity {PID=(int)pid,ThreadID=tid,CreatedFileTime=created,Image=image.ToString()};return true;
        }
        public uint Wait(IntPtr value,uint ms,out int e) { uint r=WaitForSingleObject(value,ms);e=Marshal.GetLastWin32Error();return r; }
        public bool ExitCode(IntPtr value,out uint code,out int e) { bool r=StrictExitCode(value,out code);e=Marshal.GetLastWin32Error();return r; }
        public bool Terminate(IntPtr value,uint code,out int e) { bool r=TerminateProcess(value,code);e=Marshal.GetLastWin32Error();return r; }
        public bool Close(IntPtr value,bool desktop,out int e) { bool r=desktop ? CloseDesktop(value) : StrictCloseHandle(value);e=Marshal.GetLastWin32Error();return r; }
    }
}
