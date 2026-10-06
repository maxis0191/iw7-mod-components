using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;
namespace IW7.VoiceAgent
{
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
        public static ProbeResult Run(string image, string hash, string[] arguments, string stdout, string stderr, int timeoutSeconds)
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
                        result.CreationFileTime=process.StartTime.ToFileTimeUtc();
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
                        if (!process.HasExited) TerminateProcess(handle, 125);
                        throw;
                    }
                    result.ElapsedMs=clock.ElapsedMilliseconds;
                    result.ExitCode=process.HasExited ? process.ExitCode : 126;
                    output.Flush();error.Flush();return result;
                }
            }
        }
    }
}
