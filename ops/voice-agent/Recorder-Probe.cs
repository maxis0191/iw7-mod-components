using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;
namespace IW7.VoicePairDraft
{
    public sealed class ProbeAdmission
    {
        public readonly TaskCompletionSource<ProbeIdentity> Started = new TaskCompletionSource<ProbeIdentity>(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly System.Threading.ManualResetEventSlim Decision = new System.Threading.ManualResetEventSlim(false);
        private readonly object handleGate = new object();
        private SafeProcessHandle ownedHandle;
        public Task<ProbeResult> Completion { get; internal set; }
        public bool Accepted { get; private set; }
        public void Admit() { Accepted=true; Decision.Set(); }
        public void Refuse() { Decision.Set(); }
        internal void AttachHandle(SafeProcessHandle handle) { lock(handleGate) { ownedHandle=handle; } }
        internal void DetachHandle() { lock(handleGate) { ownedHandle=null; } }
        public ProbeIdentity CaptureIdentity()
        {
            lock(handleGate)
            {
                if(ownedHandle == null) throw new InvalidOperationException("Original recorder handle unavailable");
                return OwnedProbe.CaptureIdentity(ownedHandle);
            }
        }
    }
    public sealed class ProbeIdentity
    {
        public int PID { get; set; }
        public long CreationFileTime { get; set; }
        public string Image { get; set; }
        public bool Exited { get; set; }
        public long CapturedTick { get; set; }
        public long RegistrationDeadlineTick { get; set; }
    }
    public sealed class ProbeResult
    {
        public int PID { get; set; }
        public long CreationFileTime { get; set; }
        public int ExitCode { get; set; }
        public bool TimedOut { get; set; }
        public bool LogBoundExceeded { get; set; }
        public long ElapsedMs { get; set; }
    }
    public static class OwnedProbe
    {
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool TerminateProcess(SafeProcessHandle handle, uint code);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern uint GetProcessId(SafeProcessHandle handle);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetProcessTimes(SafeProcessHandle handle, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool QueryFullProcessImageName(SafeProcessHandle handle, uint flags, StringBuilder image, ref int size);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern uint WaitForSingleObject(SafeProcessHandle handle, uint milliseconds);
        public static ProbeIdentity CaptureIdentity(SafeProcessHandle handle)
        {
            // Image is queried from the kernel handle; Process.Path enumerates
            // startup modules and can briefly return null for a live child.
            // Every field is captured once, with no PID reopen/path fallback.
            bool retained=false;
            try
            {
                handle.DangerousAddRef(ref retained);
                uint pid=GetProcessId(handle);
                if(pid == 0 || pid > Int32.MaxValue) throw new InvalidOperationException("Original recorder PID query failed: "+Marshal.GetLastWin32Error());
                long creation,exit,kernel,user;
                if(!GetProcessTimes(handle,out creation,out exit,out kernel,out user) || creation <= 0)
                    throw new InvalidOperationException("Original recorder creation query failed: "+Marshal.GetLastWin32Error());
                var image=new StringBuilder(32768);int length=image.Capacity;
                if(!QueryFullProcessImageName(handle,0,image,ref length) || length < 1)
                    throw new InvalidOperationException("Original recorder image query failed: "+Marshal.GetLastWin32Error());
                uint state=WaitForSingleObject(handle,0);
                if(state != 0 && state != 258) throw new InvalidOperationException("Original recorder live query failed: "+Marshal.GetLastWin32Error());
                return new ProbeIdentity {PID=(int)pid,CreationFileTime=creation,Image=image.ToString(),Exited=state == 0,CapturedTick=Environment.TickCount64};
            }
            finally { if(retained) handle.DangerousRelease(); }
        }
        public static Task<ProbeResult> Start(string image,string hash,string[] arguments,string stdout,string stderr,int timeoutSeconds)
        { return Task.Run(() => Run(image,hash,arguments,stdout,stderr,timeoutSeconds)); }
        public static ProbeAdmission StartOwned(string image,string hash,string[] arguments,string stdout,string stderr,int timeoutSeconds)
        {
            var admission=new ProbeAdmission();
            admission.Completion=Task.Run(() => {try{return RunCore(image,hash,arguments,stdout,stderr,timeoutSeconds,admission);}catch(Exception error){admission.Started.TrySetException(error);throw;}});
            return admission;
        }
        public static ProbeResult Run(string image, string hash, string[] arguments, string stdout, string stderr, int timeoutSeconds)
        { return RunCore(image,hash,arguments,stdout,stderr,timeoutSeconds,null); }
        private static ProbeResult RunCore(string image, string hash, string[] arguments, string stdout, string stderr, int timeoutSeconds, ProbeAdmission admission)
        {
            if (timeoutSeconds < 1 || timeoutSeconds > 75 || !image.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Bounded executable probe required");
            // Keep the expected image immutable through launch and teardown.
            using (var imageFile = new FileStream(image, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var sha = SHA256.Create())
            {
                if (!String.Equals(BitConverter.ToString(sha.ComputeHash(imageFile)).Replace("-", ""), hash, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Probe image hash changed");
                var start = new ProcessStartInfo(image) { UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true };
                foreach (var argument in arguments) start.ArgumentList.Add(argument);
                using (var output = new FileStream(stdout, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
                using (var error = new FileStream(stderr, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
                using (var process = Process.Start(start))
                {
                    if (process == null) throw new InvalidOperationException("Probe did not start");
                    // This is the original kernel handle, never terminate by a newly
                    // resolved PID, and never use Kill(entireProcessTree:true).
                    var handle = process.SafeHandle;
                    var result = new ProbeResult { PID=process.Id };
                    var clock = Stopwatch.StartNew();
                    var streams = new Stream[] { process.StandardOutput.BaseStream, process.StandardError.BaseStream };
                    var destinations = new Stream[] { output, error };
                    var buffers = new byte[][] { new byte[4096], new byte[4096] };
                    var reads = new Task<int>[2];
                    long bytes=0;
                    try
                    {
                        var identity=CaptureIdentity(handle);
                        if(identity.PID != process.Id || identity.Exited || !String.Equals(identity.Image,Path.GetFullPath(image),StringComparison.OrdinalIgnoreCase))
                            throw new InvalidOperationException("Original recorder launch identity differs");
                        result.CreationFileTime=identity.CreationFileTime;
                        if(admission != null)
                        {
                            identity.RegistrationDeadlineTick=identity.CapturedTick+1000;
                            admission.AttachHandle(handle);
                            admission.Started.TrySetResult(identity);
                            if(!admission.Decision.Wait(1000) || !admission.Accepted) throw new InvalidOperationException("Recorder lease admission refused or timed out");
                            if(process.HasExited) throw new InvalidOperationException("Recorder exited before lease admission");
                        }
                        for (int i=0;i<2;i++) reads[i]=streams[i].ReadAsync(buffers[i],0,4096);
                        while (!process.HasExited || reads[0] != null || reads[1] != null)
                        {
                            for (int i=0;i<2;i++) if (reads[i] != null && reads[i].IsCompleted)
                            {
                                int count=reads[i].GetAwaiter().GetResult();
                                if (bytes + count > 4*1024*1024) { result.LogBoundExceeded=true; break; }
                                destinations[i].Write(buffers[i],0,count); bytes+=count;
                                reads[i]=count==0 ? null : streams[i].ReadAsync(buffers[i],0,4096);
                            }
                            if (result.LogBoundExceeded || clock.Elapsed.TotalSeconds >= timeoutSeconds)
                            {
                                result.TimedOut=!result.LogBoundExceeded;
                                // Handle remains exact even if PID is subsequently reused.
                                if (!process.HasExited && !TerminateProcess(handle, 124)) throw new InvalidOperationException("Exact probe termination failed: "+Marshal.GetLastWin32Error());
                                process.WaitForExit(1000); break;
                            }
                            System.Threading.Thread.Sleep(10);
                        }
                    }
                    catch
                    {
                        if (!process.HasExited)
                        {
                            if(!TerminateProcess(handle,125))throw new InvalidOperationException("Exact failed-admission probe closure failed: "+Marshal.GetLastWin32Error());
                            if(!process.WaitForExit(1000))throw new InvalidOperationException("Exact failed-admission probe closure unconfirmed");
                        }
                        throw;
                    }
                    finally { if(admission != null) admission.DetachHandle(); }
                    result.ElapsedMs=clock.ElapsedMilliseconds;
                    result.ExitCode=process.HasExited ? process.ExitCode : 126;
                    output.Flush();error.Flush();return result;
                }
            }
        }
    }
}
