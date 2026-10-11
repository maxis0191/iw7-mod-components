using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace IW7.VoicePairDraft
{
    public sealed class ProbeIdentity
    {
        public int PID { get; internal set; }
        public long CreationFileTime { get; internal set; }
        public string Image { get; internal set; }
        public string ImageSHA256 { get; internal set; }
        public bool Exited { get; internal set; }
        public long CapturedTick { get; internal set; }
        public long RegistrationDeadlineTick { get; internal set; }
        public bool OriginalHandleWaitSignaled { get; internal set; }
        public int ExitCode { get; internal set; }
        public uint ExitCodeUInt32 { get; internal set; }
        public string ImageEvidenceMode { get; internal set; }
        public bool? ImageQueryAfterExitSucceeded { get; internal set; }
        public int? ImageQueryAfterExitWin32Error { get; internal set; }
        public bool RetainedImageGuardVerified { get; internal set; }
    }
    public sealed class ProbeResult
    {
        public int PID { get; internal set; }
        public long CreationFileTime { get; internal set; }
        public int ExitCode { get; internal set; } = -1;
        public bool TimedOut { get; internal set; }
        public bool LogBoundExceeded { get; internal set; }
        public long ElapsedMs { get; internal set; }
        public string Failure { get; internal set; }
        public bool OriginalHandleWaitSignaled { get; internal set; }
        public bool ProducerOutputClosed { get; internal set; }
        public long DiscardedLogBytes { get; internal set; }
        public uint ExitCodeUInt32 { get; internal set; }
        public string ImageEvidenceMode { get; internal set; }
        public bool? ImageQueryAfterExitSucceeded { get; internal set; }
        public int? ImageQueryAfterExitWin32Error { get; internal set; }
        public bool RetainedImageGuardVerified { get; internal set; }
    }
    // Pure policy only. It opens/closes no handle and cannot bind an owner's
    // terminal state. Production observations come from its creation handle
    // and held immutable image stream under that owner's private gate.
    public static class ProbeTerminalEvidence
    {
        public static ProbeIdentity Resolve(ProbeIdentity initial,int pid,long creation,bool signaled,uint exitCode,
            string queriedImage,int imageQueryError,bool retainedImageGuardVerified,long tick)
        {
            if(initial==null || initial.PID<=0 || initial.CreationFileTime<=0 || initial.Exited || initial.OriginalHandleWaitSignaled ||
                initial.ImageEvidenceMode!="live-kernel-query" || String.IsNullOrEmpty(initial.Image) || initial.Image.Length>=32768 || tick<0 ||
                String.IsNullOrEmpty(initial.ImageSHA256) || initial.ImageSHA256.Length!=64 ||
                pid!=initial.PID || creation!=initial.CreationFileTime || !signaled || !retainedImageGuardVerified)
                throw new InvalidOperationException("Original terminal PID/creation/wait/live-image/retained-guard evidence differs; retain owner");
            foreach(char value in initial.ImageSHA256)if(!Uri.IsHexDigit(value))throw new InvalidOperationException("Original live image hash invalid; retain owner");
            bool queried=imageQueryError==0;
            if(queried)
            {
                if(String.IsNullOrEmpty(queriedImage) || !String.Equals(queriedImage,initial.Image,StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Original terminal queried image differs; retain owner");
            }
            else if(imageQueryError<0 || queriedImage!=null)
                throw new InvalidOperationException("Original terminal image query failure evidence invalid; retain owner");
            return new ProbeIdentity {PID=pid,CreationFileTime=creation,Image=initial.Image,ImageSHA256=initial.ImageSHA256,
                Exited=true,OriginalHandleWaitSignaled=true,ExitCode=unchecked((int)exitCode),ExitCodeUInt32=exitCode,
                CapturedTick=tick,RegistrationDeadlineTick=initial.RegistrationDeadlineTick,RetainedImageGuardVerified=true,
                ImageEvidenceMode=queried ? "terminal-kernel-query-and-retained-image-guard" : "original-live-kernel-and-retained-image-guard",
                ImageQueryAfterExitSucceeded=queried,ImageQueryAfterExitWin32Error=imageQueryError};
        }
    }
    // Construct/store this owner in the parent BEFORE StartSuspended. No using,
    // finalizer or faulted Task can discard an unconfirmed original handle.
    public sealed class ProbeAdmission
    {
        public const string ProviderSchema="iw7.runtime-recorder-source/1";
        [StructLayout(LayoutKind.Sequential)] struct FileInformation { public uint attributes,createdLow,createdHigh,accessedLow,accessedHigh,writtenLow,writtenHigh,volume,high,low,links,indexHigh,indexLow; }
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle handle,out FileInformation information);
        [DllImport("kernel32.dll",SetLastError=true)] static extern uint GetFileType(SafeFileHandle handle);
        public static string FileIdentity(FileStream stream)
        {
            if(stream==null || stream.SafeFileHandle.IsClosed)throw new InvalidOperationException("Original regular-file guard unavailable");
            FileInformation information;
            if(GetFileType(stream.SafeFileHandle)!=1 || !GetFileInformationByHandle(stream.SafeFileHandle,out information))throw new Win32Exception(Marshal.GetLastWin32Error(),"Original NTFS file identity unavailable");
            if((information.attributes&0x410)!=0 || information.links!=1)throw new InvalidOperationException("Original regular independent file required");
            return information.volume.ToString("X8")+":"+information.indexHigh.ToString("X8")+information.indexLow.ToString("X8");
        }
        [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int size; public IntPtr descriptor; [MarshalAs(UnmanagedType.Bool)] public bool inherit; }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StartupInfo
        {
            public int cb; public string reserved,desktop,title; public uint x,y,width,height,xChars,yChars,fill,flags;
            public ushort show,reserved2; public IntPtr reservedPointer,input,output,error;
        }
        [StructLayout(LayoutKind.Sequential)] struct StartupInfoEx { public StartupInfo startup; public IntPtr attributes; }
        [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process,thread; public uint pid,tid; }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string image,StringBuilder command,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr environment,string cwd,ref StartupInfoEx startup,out ProcessInfo process);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref SecurityAttributes attributes,uint size);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFileW(string path,uint access,uint share,ref SecurityAttributes attributes,uint disposition,uint flags,IntPtr template);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,uint flags,ref IntPtr size);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
        [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr process,uint milliseconds);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint code);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool PeekNamedPipe(IntPtr pipe,IntPtr buffer,uint size,IntPtr read,out uint available,IntPtr left);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadFile(IntPtr handle,byte[] bytes,uint count,out uint read,IntPtr overlapped);

        readonly object gate=new object();
        readonly string image,hash,stdout,stderr,pairScope,helperRoot,sourceProviderId,sourceSHA256,sourceFileId,leaseToken,launchNonce;
        readonly object sourceProvider; readonly FileStream sourceGuard; readonly string[] arguments; readonly int timeoutSeconds;
        IntPtr process,thread,outputRead,outputWrite,errorRead,errorWrite,input;
        FileStream imageGuard,outputGuard,errorGuard,admissionGuard;
        SafeFileHandle admissionFileHandle;
        string imageFileId,admissionReceiptPath,admissionReceiptSHA256,admissionReceiptFileId;
        bool startAttempted,createAttempted,createReturned,createSucceeded,creationAmbiguous,resumed,released,resumeAttempted,permitMinted,permitConsumed;
        RegistrationPermit mintedPermit;
        bool outputEnded,errorEnded; long startedTick,deadlineTick,bytes;
        ProbeIdentity original,terminal; ProbeResult result;
        uint createdPID;
        public Task<ProbeResult> Completion { get; private set; }
        public bool Accepted { get; private set; }
        public bool ResumeAttempted { get {lock(gate){return resumeAttempted;}} }
        public string AdmissionReceiptPath { get {lock(gate){return admissionReceiptPath;}} }
        public string AdmissionReceiptSHA256 { get {lock(gate){return admissionReceiptSHA256;}} }
        public string AdmissionReceiptFileId { get {lock(gate){return admissionReceiptFileId;}} }
        public bool HasProcess { get {lock(gate){return process!=IntPtr.Zero;}} }
        public bool NoProcessCreatedConfirmed { get {lock(gate){return !createSucceeded && !creationAmbiguous && process==IntPtr.Zero && (!createAttempted || createReturned);}} }
        public bool OwnershipResolved { get {lock(gate){return released;}} }
        public ProbeIdentity Original { get {lock(gate){return original;}} }
        public ProbeIdentity Terminal { get {lock(gate){return terminal;}} }
        public ProbeResult Result { get {lock(gate){return result;}} }
        public SafeFileHandle ImageFileHandle { get {lock(gate){if(imageGuard==null)throw new InvalidOperationException("Original helper file guard unavailable");return imageGuard.SafeFileHandle;}} }
        public SafeFileHandle StdoutFileHandle { get {lock(gate){if(outputGuard==null)throw new InvalidOperationException("Original stdout file guard unavailable");return outputGuard.SafeFileHandle;}} }
        private ProbeAdmission(string pairScope,string image,string hash,string[] arguments,string stdout,string stderr,int timeoutSeconds,
            object sourceProvider,string sourceProviderId,string sourceSHA256,string sourceFileId,FileStream sourceGuard,string leaseToken)
        {
            // Deliberately no process, file, pipe or thread allocation here.
            this.pairScope=Path.GetFullPath(pairScope).TrimEnd('\\','/');this.image=Path.GetFullPath(image);this.helperRoot=Path.GetDirectoryName(this.image);
            string helperName=Path.GetFileName(this.helperRoot);
            if(!Path.IsPathFullyQualified(pairScope) || !Path.IsPathFullyQualified(image) || !Path.IsPathFullyQualified(stdout) || !Path.IsPathFullyQualified(stderr) ||
                !String.Equals(Path.GetDirectoryName(this.helperRoot),Path.Combine(this.pairScope,"voice-pair-helper"),StringComparison.OrdinalIgnoreCase) ||
                !System.Text.RegularExpressions.Regex.IsMatch(helperName,"^[a-f0-9]{32}$") || Path.GetFileName(this.image)!="receiver-probe.exe" || this.helperRoot.Length>247 || this.image.Length>259 ||
                sourceProvider==null || sourceGuard==null || !System.Text.RegularExpressions.Regex.IsMatch(sourceProviderId??"","^[a-f0-9]{32}$") ||
                !System.Text.RegularExpressions.Regex.IsMatch(sourceSHA256??"","^[A-F0-9]{64}$") || !System.Text.RegularExpressions.Regex.IsMatch(sourceFileId??"","^[A-F0-9]{8}:[A-F0-9]{16}$") ||
                !System.Text.RegularExpressions.Regex.IsMatch(leaseToken??"","^[a-f0-9]{32}$") || !System.Text.RegularExpressions.Regex.IsMatch(hash??"","^[A-F0-9]{64}$"))throw new ArgumentException("Exact source-bound pair recorder construction required");
            this.hash=hash;this.arguments=arguments==null?null:(string[])arguments.Clone();this.stdout=Path.GetFullPath(stdout);this.stderr=Path.GetFullPath(stderr);this.timeoutSeconds=timeoutSeconds;
            this.sourceProvider=sourceProvider;this.sourceGuard=sourceGuard;this.sourceProviderId=sourceProviderId;this.sourceSHA256=sourceSHA256;this.sourceFileId=sourceFileId;this.leaseToken=leaseToken;this.launchNonce=Guid.NewGuid().ToString("N");
        }
        public static ProbeAdmission Prepare(string pairScope,string image,string hash,string[] arguments,string stdout,string stderr,int timeoutSeconds,
            object sourceProvider,string sourceProviderId,string sourceSHA256,string sourceFileId,FileStream sourceGuard,string leaseToken)
        {return new ProbeAdmission(pairScope,image,hash,arguments,stdout,stderr,timeoutSeconds,sourceProvider,sourceProviderId,sourceSHA256,sourceFileId,sourceGuard,leaseToken);}
        public sealed class AdmissionWitness
        {
            readonly ProbeAdmission owner; readonly IntPtr process,thread; readonly FileStream guard; readonly object provider;
            readonly uint pid; readonly long creation,bytes,captured,deadline; readonly string image,fileId,hash,scope,root,providerId,sourceHash,sourceId,token,nonce;
            private AdmissionWitness(ProbeAdmission owner,ProbeIdentity identity)
            {
                this.owner=owner;process=owner.process;thread=owner.thread;guard=owner.imageGuard;provider=owner.sourceProvider;
                pid=(uint)identity.PID;creation=identity.CreationFileTime;bytes=guard.Length;captured=identity.CapturedTick;deadline=owner.deadlineTick;
                image=owner.image;fileId=owner.imageFileId;hash=owner.hash;scope=owner.pairScope;root=owner.helperRoot;providerId=owner.sourceProviderId;sourceHash=owner.sourceSHA256;sourceId=owner.sourceFileId;token=owner.leaseToken;nonce=owner.launchNonce;
            }
            internal static AdmissionWitness Capture(ProbeAdmission owner,ProbeIdentity identity){return new AdmissionWitness(owner,identity);}
            public uint PID {get{return pid;}} public long CreationFileTime {get{return creation;}} public long ImageBytes {get{return bytes;}}
            public long CapturedTick {get{return captured;}} public long RegistrationDeadlineTick {get{return deadline;}}
            public string Image {get{return image;}} public string ImageFileId {get{return fileId;}} public string ImageSHA256 {get{return hash;}}
            public string PairScope {get{return scope;}} public string HelperRoot {get{return root;}} public string SourceProviderId {get{return providerId;}}
            public string SourceSHA256 {get{return sourceHash;}} public string SourceFileId {get{return sourceId;}} public string LeaseToken {get{return token;}}
            public string LaunchNonce {get{return nonce;}} public string SourceSchema {get{return "iw7.runtime-recorder-admission/1";}}
            public bool Suspended {get{return true;}}
            public bool MatchesSourceProvider(object value){return Object.ReferenceEquals(provider,value);}
            public bool MatchesOwner(ProbeAdmission value)
            {
                if(!Object.ReferenceEquals(owner,value))return false;
                lock(owner.gate){return !owner.resumed && !owner.resumeAttempted && !owner.released && !owner.creationAmbiguous && process!=IntPtr.Zero && thread!=IntPtr.Zero &&
                    process==owner.process && thread==owner.thread && Object.ReferenceEquals(guard,owner.imageGuard) && Object.ReferenceEquals(provider,owner.sourceProvider) && nonce==owner.launchNonce;}
            }
            public bool MatchesWitness(AdmissionWitness value)
            {return value!=null && Object.ReferenceEquals(owner,value.owner) && process==value.process && thread==value.thread && Object.ReferenceEquals(guard,value.guard) && Object.ReferenceEquals(provider,value.provider) &&
                pid==value.pid && creation==value.creation && bytes==value.bytes && deadline==value.deadline && image==value.image && fileId==value.fileId && hash==value.hash && scope==value.scope && root==value.root && providerId==value.providerId && sourceHash==value.sourceHash && sourceId==value.sourceId && token==value.token && nonce==value.nonce;}
        }
        public sealed class RegistrationPermit
        {
            readonly ProbeAdmission owner; readonly AdmissionWitness witness; readonly object provider; readonly string token;
            private RegistrationPermit(ProbeAdmission owner,AdmissionWitness witness,object provider,string token){this.owner=owner;this.witness=witness;this.provider=provider;this.token=token;}
            internal static RegistrationPermit Create(ProbeAdmission owner,AdmissionWitness witness,object provider,string token){return new RegistrationPermit(owner,witness,provider,token);}
            public bool MatchesOwnerAndProvider(ProbeAdmission value,object source,string lease)
            {return Object.ReferenceEquals(owner,value) && Object.ReferenceEquals(provider,source) && token==lease && witness.MatchesOwner(value);}
            internal bool Matches(ProbeAdmission value){return MatchesOwnerAndProvider(value,value.sourceProvider,value.leaseToken);}
        }
        public AdmissionWitness CaptureAdmissionWitness()
        {
            lock(gate)
            {
                if(!createSucceeded || creationAmbiguous || resumed || resumeAttempted || released || thread==IntPtr.Zero || original==null || Environment.TickCount64>=deadlineTick)throw new InvalidOperationException("Fresh original suspended recorder witness unavailable");
                if(sourceGuard.SafeFileHandle.IsClosed || !sourceGuard.CanRead || FileIdentity(sourceGuard)!=sourceFileId || Digest(sourceGuard)!=sourceSHA256)throw new InvalidOperationException("Original source guard bytes/identity unavailable at admission");
                if(imageGuard==null || imageGuard.SafeFileHandle.IsClosed || imageGuard.Length<1 || FileIdentity(imageGuard)!=imageFileId || Digest(imageGuard)!=hash)throw new InvalidOperationException("Original helper guard bytes/identity differ");
                var identity=CaptureIdentityLocked();if(identity.Exited || identity.CapturedTick>=deadlineTick)throw new InvalidOperationException("Original suspended recorder exited/expired");
                return AdmissionWitness.Capture(this,identity);
            }
        }
        public RegistrationPermit CreateRegistrationPermit(AdmissionWitness witness,string token,object provider)
        {
            lock(gate)
            {
                if(permitMinted || witness==null || !witness.MatchesOwner(this) || !witness.MatchesSourceProvider(provider) || token!=leaseToken || !Object.ReferenceEquals(provider,sourceProvider))throw new InvalidOperationException("Original one-use recorder permit binding refused");
                var current=CaptureAdmissionWitness();if(!witness.MatchesWitness(current))throw new InvalidOperationException("Original recorder witness changed before permit");
                permitMinted=true;mintedPermit=RegistrationPermit.Create(this,current,provider,token);return mintedPermit;
            }
        }
        static string Digest(FileStream stream)
        {
            stream.Position=0;
            using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-","");
        }
        static string Quote(string argument)
        {
            if(argument==null || argument.IndexOf('\0')>=0)throw new ArgumentException("Invalid recorder argument");
            var text=new StringBuilder("\"");int slashes=0;
            foreach(char value in argument)
            {
                if(value=='\\'){slashes++;continue;}
                if(value=='"'){text.Append('\\',slashes*2+1);text.Append(value);slashes=0;continue;}
                text.Append('\\',slashes);slashes=0;text.Append(value);
            }
            text.Append('\\',slashes*2);return text.Append('"').ToString();
        }
        static void CloseChecked(ref IntPtr handle,string description)
        {
            if(handle==IntPtr.Zero)return;
            if(!CloseHandle(handle))throw new Win32Exception(Marshal.GetLastWin32Error(),description+" closure unconfirmed; retain original owner");
            handle=IntPtr.Zero;
        }
        public ProbeIdentity StartSuspended()
        {
            lock(gate)
            {
                if(startAttempted)throw new InvalidOperationException("Original recorder launch already attempted");
                startAttempted=true;startedTick=Environment.TickCount64;
                if(timeoutSeconds<1 || timeoutSeconds>75 || !image.EndsWith(".exe",StringComparison.OrdinalIgnoreCase) || arguments==null || arguments.Length!=7 || arguments[0]!="--record")throw new ArgumentException("Bounded direct recorder required");
                imageGuard=new FileStream(image,FileMode.Open,FileAccess.Read,FileShare.Read);
                if(imageGuard.Length<1 || imageGuard.Length>16*1024*1024 || !String.Equals(Digest(imageGuard),hash,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Retained original helper image/hash differs");
                imageFileId=FileIdentity(imageGuard);
                outputGuard=new FileStream(stdout,FileMode.CreateNew,FileAccess.Write,FileShare.Read);
                errorGuard=new FileStream(stderr,FileMode.CreateNew,FileAccess.Write,FileShare.Read);
                var attributes=new SecurityAttributes {size=Marshal.SizeOf(typeof(SecurityAttributes)),inherit=true};
                if(!CreatePipe(out outputRead,out outputWrite,ref attributes,4096))throw new Win32Exception(Marshal.GetLastWin32Error(),"Original stdout pipe creation failed");
                if(!CreatePipe(out errorRead,out errorWrite,ref attributes,4096))throw new Win32Exception(Marshal.GetLastWin32Error(),"Original stderr pipe creation failed");
                if(!SetHandleInformation(outputRead,1,0) || !SetHandleInformation(errorRead,1,0))throw new Win32Exception(Marshal.GetLastWin32Error(),"Read-pipe inheritance refusal failed");
                input=CreateFileW("NUL",0x80000000,3,ref attributes,3,0,IntPtr.Zero);
                if(input==new IntPtr(-1)){input=IntPtr.Zero;throw new Win32Exception(Marshal.GetLastWin32Error(),"Owned NUL input creation failed");}
                IntPtr size=IntPtr.Zero,list=IntPtr.Zero,handles=IntPtr.Zero;bool initialized=false;
                try
                {
                    bool sized=InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);int sizingError=Marshal.GetLastWin32Error();
                    if(sized || sizingError!=122 || size==IntPtr.Zero)throw new Win32Exception(sizingError,"Exact handle-list sizing failed");
                    list=Marshal.AllocHGlobal(size);
                    if(!InitializeProcThreadAttributeList(list,1,0,ref size))throw new Win32Exception(Marshal.GetLastWin32Error(),"Exact handle-list creation failed");
                    initialized=true;handles=Marshal.AllocHGlobal(IntPtr.Size*3);
                    Marshal.WriteIntPtr(handles,0,input);Marshal.WriteIntPtr(handles,IntPtr.Size,outputWrite);Marshal.WriteIntPtr(handles,IntPtr.Size*2,errorWrite);
                    if(!UpdateProcThreadAttribute(list,0,new IntPtr(0x20002),handles,new IntPtr(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero))throw new Win32Exception(Marshal.GetLastWin32Error(),"Exact inherited handles refused");
                    var startup=new StartupInfoEx {startup=new StartupInfo {cb=Marshal.SizeOf(typeof(StartupInfoEx)),flags=0x101,show=0,input=input,output=outputWrite,error=errorWrite},attributes=list};
                    var command=new StringBuilder(Quote(image));foreach(string arg in arguments)command.Append(' ').Append(Quote(arg));
                    if(command.Length>=32767)throw new ArgumentException("Recorder command-line bound exceeded");
                    ProcessInfo created;createAttempted=true;
                    bool success=CreateProcessW(image,command,IntPtr.Zero,IntPtr.Zero,true,0x08080004,IntPtr.Zero,Path.GetDirectoryName(image),ref startup,out created);
                    int nativeError=Marshal.GetLastWin32Error();createReturned=true;
                    if(!success)
                    {
                        creationAmbiguous=created.process!=IntPtr.Zero || created.thread!=IntPtr.Zero || created.pid!=0;
                        // An unexpected nonzero failed-create response stays
                        // reachable; do not leak or guess ownership by PID.
                        process=created.process;thread=created.thread;createdPID=created.pid;
                        throw new Win32Exception(nativeError,"Suspended original recorder creation failed");
                    }
                    // Store both original handles before any identity/IO/admission
                    // check that can throw. The parent already owns this instance.
                    process=created.process;thread=created.thread;createdPID=created.pid;createSucceeded=true;
                    deadlineTick=Environment.TickCount64+1000;
                }
                finally
                {
                    if(initialized)DeleteProcThreadAttributeList(list);
                    if(list!=IntPtr.Zero)Marshal.FreeHGlobal(list);
                    if(handles!=IntPtr.Zero)Marshal.FreeHGlobal(handles);
                }
                CloseChecked(ref outputWrite,"Parent stdout writer");CloseChecked(ref errorWrite,"Parent stderr writer");CloseChecked(ref input,"Parent stdin");
                original=CaptureIdentityLocked();
                if(original.Exited || !String.Equals(original.Image,image,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Suspended original recorder image/creation differs");
                return original;
            }
        }
        ProbeIdentity CaptureIdentityLocked()
        {
            if(process==IntPtr.Zero)throw new InvalidOperationException("Original recorder kernel handle unavailable");
            var identity=OwnedProbe.CaptureIdentityRaw(process);identity.ImageSHA256=hash;identity.RegistrationDeadlineTick=deadlineTick;
            if(createdPID==0 || identity.PID!=createdPID)throw new InvalidOperationException("Kernel recorder PID differs from original creation result");
            if(original!=null && (identity.PID!=original.PID || identity.CreationFileTime!=original.CreationFileTime || !String.Equals(identity.Image,original.Image,StringComparison.OrdinalIgnoreCase)))throw new InvalidOperationException("Original recorder kernel tuple changed");
            return identity;
        }
        public ProbeIdentity CaptureIdentity() {lock(gate){return CaptureIdentityLocked();}}
        // Polling may race normal recorder exit. Admission still requires the
        // strict live identity above; observation can report a proven terminal
        // tuple through the same retained creation handle and immutable image.
        public ProbeIdentity CaptureObservation()
        {
            lock(gate)
            {
                if(released || original==null)throw new InvalidOperationException("Original recorder observation unavailable");
                if(WaitLocked(0))return ReadTerminalIdentityLocked();
                try
                {
                    var snapshot=CaptureIdentityLocked();
                    return snapshot.Exited ? ReadTerminalIdentityLocked() : snapshot;
                }
                catch(Win32Exception)
                {
                    if(!WaitLocked(0))throw;
                    return ReadTerminalIdentityLocked();
                }
            }
        }
        public void Admit(RegistrationPermit permit,string receiptPath,string receiptSHA256)
        {
            lock(gate)
            {
                if(resumed || resumeAttempted || released || original==null || permitConsumed || !permitMinted || !Object.ReferenceEquals(permit,mintedPermit) || !permit.Matches(this))throw new InvalidOperationException("Exact unused original recorder permit required");
                if(admissionGuard!=null || !Path.IsPathFullyQualified(receiptPath) || Path.GetDirectoryName(Path.GetFullPath(receiptPath))!=Path.GetDirectoryName(stdout) ||
                    !System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(receiptPath),"^recorder-[0-9]{4,}-admission[.]local[.]json$") ||
                    !System.Text.RegularExpressions.Regex.IsMatch(receiptSHA256??"","^[A-F0-9]{64}$"))throw new InvalidOperationException("Persisted local recorder registration receipt required");
                admissionGuard=new FileStream(receiptPath,FileMode.Open,FileAccess.Read,FileShare.Read);
                admissionFileHandle=admissionGuard.SafeFileHandle;
                if(admissionGuard.Length<1 || admissionGuard.Length>2*1024*1024 || Digest(admissionGuard)!=receiptSHA256)throw new InvalidOperationException("Retained recorder registration receipt differs");
                admissionReceiptPath=Path.GetFullPath(receiptPath);admissionReceiptSHA256=receiptSHA256;admissionReceiptFileId=FileIdentity(admissionGuard);
                CaptureAdmissionWitness();if(!permit.Matches(this) || Environment.TickCount64>=deadlineTick)throw new InvalidOperationException("Original recorder registration expired before execution");
                // A Win32 failure may have resumed the thread. Never permit a
                // second attempt or describe uncertain execution as suspended.
                permitConsumed=true;resumeAttempted=true;
                if(ResumeThread(thread)!=1)throw new Win32Exception(Marshal.GetLastWin32Error(),"Expected one suspended recorder primary thread");
                resumed=true;Accepted=true;
                CloseChecked(ref thread,"Original primary thread");
                Completion=Task.Run(() => RunBounded());
            }
        }
        bool WaitLocked(int milliseconds)
        {
            if(process==IntPtr.Zero)throw new InvalidOperationException("Original recorder wait handle unavailable");
            uint state=WaitForSingleObject(process,(uint)milliseconds);
            if(state==0)return true;if(state==258)return false;
            throw new Win32Exception(Marshal.GetLastWin32Error(),"Original recorder wait failed; retain owner");
        }
        public bool Wait(int milliseconds) {if(milliseconds<0 || milliseconds>5000)throw new ArgumentOutOfRangeException("milliseconds");lock(gate){return WaitLocked(milliseconds);}}
        void StopLocked(uint code)
        {
            if(!createSucceeded || process==IntPtr.Zero)throw new InvalidOperationException("Known original recorder handle required for termination");
            if(!WaitLocked(0) && !TerminateProcess(process,code) && !WaitLocked(0))throw new Win32Exception(Marshal.GetLastWin32Error(),"Exact original recorder termination failed; retain owner");
            if(!WaitLocked(5000))throw new InvalidOperationException("Exact original recorder closure unconfirmed; retain owner");
        }
        bool DrainOne(ref IntPtr pipe,FileStream output,ref bool ended,byte[] buffer)
        {
            if(ended)return false;
            uint available;
            if(!PeekNamedPipe(pipe,IntPtr.Zero,0,IntPtr.Zero,out available,IntPtr.Zero))
            {
                int error=Marshal.GetLastWin32Error();if(error==109){ended=true;return false;}
                throw new Win32Exception(error,"Original producer pipe query failed");
            }
            if(available==0)return false;
            uint count;
            if(!ReadFile(pipe,buffer,Math.Min(available,(uint)buffer.Length),out count,IntPtr.Zero))
            {
                int error=Marshal.GetLastWin32Error();if(error==109){ended=true;return false;}
                throw new Win32Exception(error,"Original producer pipe read failed");
            }
            if(count==0){ended=true;return false;}
            if(bytes+count>4*1024*1024){result.LogBoundExceeded=true;result.DiscardedLogBytes+=count;return true;}
            if(result.Failure!=null){result.DiscardedLogBytes+=count;return true;}
            output.Write(buffer,0,(int)count);output.Flush();bytes+=count;return true;
        }
        ProbeIdentity ReadTerminalIdentityLocked()
        {
            if(!WaitLocked(0))throw new InvalidOperationException("Original recorder terminal wait not signaled");
            // A normally exited or rejected suspended child may lose its kernel
            // image query after termination (actual Win32=31). A live query is
            // still mandatory for launch/admission. Terminal closure instead
            // proves fresh PID/creation/wait/exit through this same original
            // handle, attempts the image query honestly, and retains its error
            // alongside the already witnessed live image and held byte guard.
            if(original==null || original.PID!=createdPID || !String.Equals(original.Image,image,StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(original.ImageSHA256,hash,StringComparison.OrdinalIgnoreCase) || imageGuard==null || imageGuard.SafeFileHandle.IsClosed)
                throw new InvalidOperationException("Original live identity/image guard unavailable for terminal closure; retain owner");
            if(!String.Equals(Digest(imageGuard),hash,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Retained original helper hash differs at terminal");
            return OwnedProbe.CaptureTerminalIdentityRaw(process,original);
        }
        void CaptureTerminalLocked()
        {
            var end=ReadTerminalIdentityLocked();terminal=end;
            result.PID=end.PID;result.CreationFileTime=end.CreationFileTime;result.ExitCode=end.ExitCode;result.OriginalHandleWaitSignaled=true;
            result.ExitCodeUInt32=end.ExitCodeUInt32;result.ImageEvidenceMode=end.ImageEvidenceMode;
            result.ImageQueryAfterExitSucceeded=end.ImageQueryAfterExitSucceeded;result.ImageQueryAfterExitWin32Error=end.ImageQueryAfterExitWin32Error;
            result.RetainedImageGuardVerified=end.RetainedImageGuardVerified;
        }
        ProbeResult RunBounded()
        {
            lock(gate){result=new ProbeResult {PID=original.PID,CreationFileTime=original.CreationFileTime};}
            var buffer=new byte[4096];
            try
            {
                while(true)
                {
                    bool done;
                    lock(gate)
                    {
                        DrainOne(ref outputRead,outputGuard,ref outputEnded,buffer);DrainOne(ref errorRead,errorGuard,ref errorEnded,buffer);
                        done=WaitLocked(0);
                        if(result.LogBoundExceeded || Environment.TickCount64-startedTick>=Math.Min(timeoutSeconds*1000L,70000L))
                        {
                            result.TimedOut=!result.LogBoundExceeded;StopLocked(124);done=true;
                        }
                        if(done && outputEnded && errorEnded){CaptureTerminalLocked();result.ProducerOutputClosed=true;break;}
                        if(done && Environment.TickCount64-startedTick>=75000L)throw new InvalidOperationException("Original producer pipe EOF unconfirmed; retain owner");
                    }
                    Thread.Sleep(10);
                }
            }
            catch(Exception failure)
            {
                lock(gate)
                {
                    result.Failure=failure.Message;
                    try
                    {
                        // Reserve the final five seconds for one original
                        // termination wait. Do not extend the 75s watchdog by
                        // repeating a failed wait here; parent recovery retains
                        // the same original handle after this task returns.
                        if(!WaitLocked(0))
                        {
                            if(Environment.TickCount64-startedTick>=70000L)throw new InvalidOperationException("Original closure deadline exhausted; retain owner for recovery");
                            StopLocked(125);
                        }
                        CaptureTerminalLocked();
                    }
                    catch(Exception closure){result.Failure+="; closure: "+closure.Message;}
                }
            }
            lock(gate){result.ElapsedMs=Environment.TickCount64-startedTick;return result;}
        }
        // Explicit recovery/failed-admission path. Nothing disposes the original
        // handle or any immutable guard until termination and EOF are confirmed.
        public ProbeResult CloseOriginal()
        {
            lock(gate)
            {
                if(released)return result;
                if(Completion!=null && !Completion.IsCompleted)throw new InvalidOperationException("Original recorder worker still active; retain owner");
                if(NoProcessCreatedConfirmed)return result;
                // Termination, both EOFs and immutable-image terminal hashing
                // already succeeded. A later checked handle/file disposal may
                // fail partway; recovery retries the remaining disposals rather
                // than querying an original handle already confirmed closed.
                if(terminal!=null && terminal.OriginalHandleWaitSignaled && result!=null && result.ProducerOutputClosed)return result;
                if(result==null)result=new ProbeResult();
                CloseChecked(ref outputWrite,"Parent stdout writer");CloseChecked(ref errorWrite,"Parent stderr writer");CloseChecked(ref input,"Parent stdin");
                StopLocked(125);
                var buffer=new byte[4096];long until=Environment.TickCount64+1000;
                while(!outputEnded || !errorEnded)
                {
                    DrainOne(ref outputRead,outputGuard,ref outputEnded,buffer);DrainOne(ref errorRead,errorGuard,ref errorEnded,buffer);
                    if(Environment.TickCount64>=until)throw new InvalidOperationException("Original producer EOF unconfirmed after closure; retain owner");
                    if(!outputEnded || !errorEnded)Thread.Sleep(10);
                }
                CaptureTerminalLocked();result.ProducerOutputClosed=true;result.ElapsedMs=Environment.TickCount64-startedTick;return result;
            }
        }
        public void DisposeChecked()
        {
            lock(gate)
            {
                if(released)return;
                if(creationAmbiguous)throw new InvalidOperationException("Native creation response ambiguous; retain owner");
                if(!createSucceeded && !NoProcessCreatedConfirmed)throw new InvalidOperationException("Native no-child proof unavailable; retain owner");
                if(Completion!=null && !Completion.IsCompleted)throw new InvalidOperationException("Original recorder task still active; retain owner");
                if(createSucceeded && (terminal==null || !terminal.OriginalHandleWaitSignaled || result==null || !result.ProducerOutputClosed))throw new InvalidOperationException("Original terminal/producer closure not proven; retain owner");
                if(process!=IntPtr.Zero && !WaitLocked(0))throw new InvalidOperationException("Refuse disposing live original recorder handle");
                CloseChecked(ref thread,"Original recorder thread");CloseChecked(ref process,"Original recorder process");
                CloseChecked(ref outputWrite,"Original stdout writer");CloseChecked(ref errorWrite,"Original stderr writer");CloseChecked(ref input,"Original stdin");
                CloseChecked(ref outputRead,"Original stdout reader");CloseChecked(ref errorRead,"Original stderr reader");
                if(outputGuard!=null){outputGuard.Dispose();outputGuard=null;}
                if(errorGuard!=null){errorGuard.Dispose();errorGuard=null;}
                if(imageGuard!=null){imageGuard.Dispose();imageGuard=null;}
                if(admissionGuard!=null){if(!admissionFileHandle.IsClosed)admissionGuard.Dispose();if(!admissionFileHandle.IsClosed)throw new InvalidOperationException("Original registration receipt guard disposal unconfirmed");admissionGuard=null;}
                released=true;
            }
        }
    }
    public static class OwnedProbe
    {
        public const int OwnershipVersion=3;
        [DllImport("kernel32.dll",SetLastError=true)] static extern uint GetProcessId(IntPtr handle);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr handle,out long creation,out long exit,out long kernel,out long user);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageNameW(IntPtr handle,uint flags,StringBuilder image,ref uint size);
        [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr handle,out uint code);
        internal static ProbeIdentity CaptureIdentityRaw(IntPtr handle)
        {
            uint pid=GetProcessId(handle);long creation,exit,kernel,user;
            if(pid==0 || pid>Int32.MaxValue || !GetProcessTimes(handle,out creation,out exit,out kernel,out user) || creation<=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Original recorder PID/creation query failed");
            var image=new StringBuilder(32768);uint capacity=32768;
            if(!QueryFullProcessImageNameW(handle,0,image,ref capacity) || capacity==0 || capacity>=32768 || image.Length!=capacity)throw new Win32Exception(Marshal.GetLastWin32Error(),"Original recorder kernel image query failed");
            uint state=WaitForSingleObject(handle,0);if(state!=0 && state!=258)throw new Win32Exception(Marshal.GetLastWin32Error(),"Original recorder state query failed");
            return new ProbeIdentity {PID=(int)pid,CreationFileTime=creation,Image=image.ToString(),Exited=state==0,CapturedTick=Environment.TickCount64,OriginalHandleWaitSignaled=state==0,
                ImageEvidenceMode=state==0 ? "terminal-kernel-query" : "live-kernel-query"};
        }
        internal static ProbeIdentity CaptureTerminalIdentityRaw(IntPtr handle,ProbeIdentity original)
        {
            uint pid=GetProcessId(handle);long creation,exit,kernel,user;
            if(pid==0 || pid>Int32.MaxValue || !GetProcessTimes(handle,out creation,out exit,out kernel,out user) || creation<=0)
                throw new Win32Exception(Marshal.GetLastWin32Error(),"Original terminal PID/creation query failed; retain owner");
            uint state=WaitForSingleObject(handle,0);if(state!=0)throw new InvalidOperationException("Original terminal kernel wait not signaled; retain owner");
            if(exit<creation)throw new InvalidOperationException("Original terminal exit FILETIME precedes creation; retain owner");
            uint code;if(!GetExitCodeProcess(handle,out code))throw new Win32Exception(Marshal.GetLastWin32Error(),"Original terminal exit code unavailable; retain owner");
            var image=new StringBuilder(32768);uint capacity=32768;int queryError=0;string queriedImage=null;
            if(!QueryFullProcessImageNameW(handle,0,image,ref capacity))
            {
                queryError=Marshal.GetLastWin32Error();
                if(queryError<=0)throw new InvalidOperationException("Original terminal image query failed without native error; retain owner");
            }
            else
            {
                if(capacity==0 || capacity>=32768 || image.Length!=capacity)throw new InvalidOperationException("Original terminal image query bounds invalid; retain owner");
                queriedImage=image.ToString();
            }
            return ProbeTerminalEvidence.Resolve(original,(int)pid,creation,true,code,queriedImage,queryError,true,Environment.TickCount64);
        }
        // Borrowing is read-only diagnostics only, never owned termination.
        public static ProbeIdentity CaptureIdentity(SafeProcessHandle handle)
        {
            bool retained=false;try{handle.DangerousAddRef(ref retained);return CaptureIdentityRaw(handle.DangerousGetHandle());}finally{if(retained)handle.DangerousRelease();}
        }
    }
}
