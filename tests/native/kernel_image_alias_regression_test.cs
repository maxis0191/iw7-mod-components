using System;
using System.Text;
using System.Runtime.InteropServices;
namespace IW7.BootProof {
    public static class KernelImageAliasRegression {
        [StructLayout(LayoutKind.Sequential)]
        struct ProcessBasicInformation {
            public IntPtr Reserved1,Peb,Reserved2a,Reserved2b,UniquePID,Reserved3;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct UnicodeString { public ushort Length,MaximumLength; public IntPtr Buffer; }
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] static extern uint GetCurrentProcessId();
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string name);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetModuleFileNameW(IntPtr module,StringBuilder buffer,uint capacity);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageNameW(IntPtr process,uint flags,StringBuilder buffer,ref uint capacity);
        [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process,int informationClass,out ProcessBasicInformation info,int size,out int returned);
        static string KernelImage(uint capacity) {
            var text=new StringBuilder((int)capacity); uint length=capacity;
            if(!QueryFullProcessImageNameW(GetCurrentProcess(),0,text,ref length) || length==0 || length>=capacity)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Strict original kernel image unavailable");
            return text.ToString();
        }
        static string ModuleImage() {
            var text=new StringBuilder(32768); uint length=GetModuleFileNameW(IntPtr.Zero,text,(uint)text.Capacity);
            if(length==0 || length>=text.Capacity) throw new InvalidOperationException("Main module name unavailable"); return text.ToString();
        }
        public sealed class Result {
            public uint PID { get; set; }
            public string KernelBefore { get; set; }
            public string KernelWhileAliased { get; set; }
            public string ModuleWhileAliased { get; set; }
            public string ModuleAfterRestore { get; set; }
            public bool KernelStayedOriginal { get; set; }
            public bool ModuleAliasObserved { get; set; }
            public bool Restored { get; set; }
            public bool InsufficientCapacityRefused { get; set; }
            public int InsufficientCapacityError { get; set; }
            public bool GameLaunched { get { return false; } }
            public bool OtherProcessWritten { get { return false; } }
            public bool ImageFileWritten { get { return false; } }
        }
        public static Result Run() {
            if(IntPtr.Size!=8) throw new InvalidOperationException("This pinned x64 loader layout test requires x64");
            string kernel=KernelImage(260),module=ModuleImage();
            if(!String.Equals(kernel,module,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Fresh own process already has a remapped module name");
            ProcessBasicInformation info; int returned;
            if(NtQueryInformationProcess(GetCurrentProcess(),0,out info,Marshal.SizeOf(typeof(ProcessBasicInformation)),out returned)!=0 ||
                info.Peb==IntPtr.Zero || info.UniquePID.ToInt64()!=GetCurrentProcessId()) throw new InvalidOperationException("Own PEB tuple/layout unavailable");
            IntPtr ldr=Marshal.ReadIntPtr(info.Peb,0x18); if(ldr==IntPtr.Zero) throw new InvalidOperationException("Own loader absent");
            IntPtr links=Marshal.ReadIntPtr(ldr,0x20); if(links==IntPtr.Zero) throw new InvalidOperationException("Own module list absent");
            IntPtr entry=IntPtr.Subtract(links,0x10);
            if(Marshal.ReadIntPtr(entry,0x30)!=GetModuleHandleW(null)) throw new InvalidOperationException("Pinned main module layout differs");
            IntPtr fullName=IntPtr.Add(entry,0x48);
            var original=Marshal.PtrToStructure<UnicodeString>(fullName);
            if(original.Buffer==IntPtr.Zero || original.Length%2!=0 || original.Length>original.MaximumLength ||
                !String.Equals(Marshal.PtrToStringUni(original.Buffer,original.Length/2),module,StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Pinned module descriptor differs before any write");
            const string alias="C:\\IW7KernelAliasTest\\iw7_ship.exe";
            byte[] bytes=Encoding.Unicode.GetBytes(alias+"\0");
            int size=Math.Max(original.MaximumLength,bytes.Length); IntPtr buffer=Marshal.AllocHGlobal(size);
            string aliasedModule=null,aliasedKernel=null;
            try {
                Marshal.Copy(new byte[size],0,buffer,size); Marshal.Copy(bytes,0,buffer,bytes.Length);
                var replacement=new UnicodeString { Length=(ushort)(bytes.Length-2),MaximumLength=(ushort)bytes.Length,Buffer=buffer };
                // Exact upstream loader operation, restricted to this very process.
                Marshal.StructureToPtr(replacement,fullName,false);
                aliasedModule=ModuleImage(); aliasedKernel=KernelImage(260);
            } finally {
                Marshal.StructureToPtr(original,fullName,false); Marshal.FreeHGlobal(buffer);
            }
            string restored=ModuleImage(); var tiny=new StringBuilder(1); uint tinyCapacity=1;
            bool tinyResult=QueryFullProcessImageNameW(GetCurrentProcess(),0,tiny,ref tinyCapacity);
            int tinyError=Marshal.GetLastWin32Error();
            var result=new Result { PID=GetCurrentProcessId(),KernelBefore=kernel,KernelWhileAliased=aliasedKernel,ModuleWhileAliased=aliasedModule,ModuleAfterRestore=restored,
                KernelStayedOriginal=String.Equals(kernel,aliasedKernel,StringComparison.OrdinalIgnoreCase),ModuleAliasObserved=String.Equals(alias,aliasedModule,StringComparison.Ordinal),
                Restored=String.Equals(module,restored,StringComparison.Ordinal),InsufficientCapacityRefused=!tinyResult,InsufficientCapacityError=tinyError };
            if(!result.KernelStayedOriginal || !result.ModuleAliasObserved || !result.Restored || !result.InsufficientCapacityRefused)
                throw new InvalidOperationException("Actual Win32 module-alias/kernel-original regression failed");
            return result;
        }
    }
}
