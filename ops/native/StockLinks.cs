// Metadata-only NTFS stock links. No process control or file-content/attribute writes.
// The handle-bound POSIX unlink follows the reviewed Agent-Pair NTFS primitive.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace IW7StockLinksV1
{
    public sealed class CreationRefusedException : Win32Exception
    {
        public CreationRefusedException(int error, string operation) : base(error, operation) { }
    }
    public sealed class Metadata
    {
        public string Identity, Volume, FileIdLow, FileId128, FileSystem;
        public long Bytes, AllocatedBytes, CreationFileTime, LastWriteFileTime, LastAccessFileTime, ChangeFileTime;
        public uint Links, Attributes;
        public bool Directory, DeletePending;
        public string CreatedNs { get { return checked((CreationFileTime - 116444736000000000L) * 100).ToString(System.Globalization.CultureInfo.InvariantCulture); } }
        public string ModifiedNs { get { return checked((LastWriteFileTime - 116444736000000000L) * 100).ToString(System.Globalization.CultureInfo.InvariantCulture); } }
    }
    public static class Ntfs
    {
        [StructLayout(LayoutKind.Sequential)] struct Basic { public long Creation, Access, Write, Change; public uint Attributes; }
        [StructLayout(LayoutKind.Sequential)] struct Standard { public long Allocation, Size; public uint Links; [MarshalAs(UnmanagedType.U1)] public bool Pending; [MarshalAs(UnmanagedType.U1)] public bool Directory; }
        [StructLayout(LayoutKind.Sequential)] struct Id { public ulong Volume; [MarshalAs(UnmanagedType.ByValArray, SizeConst=16)] public byte[] Bytes; }
        [StructLayout(LayoutKind.Sequential)] struct Disposition { public uint Flags; }
        [StructLayout(LayoutKind.Sequential)] struct UnicodeString { public ushort Length, MaximumLength; public IntPtr Buffer; }
        [StructLayout(LayoutKind.Sequential)] struct ObjectAttributes { public uint Length; public IntPtr Root, Name; public uint Attributes; public IntPtr Security, Quality; }
        [StructLayout(LayoutKind.Sequential)] struct IoStatus { public IntPtr Status; public UIntPtr Information; }
        [DllImport("kernel32.dll", EntryPoint="CreateFileW", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", EntryPoint="GetFileInformationByHandleEx", SetLastError=true)] static extern bool GetBasic(SafeFileHandle handle, int kind, out Basic value, uint bytes);
        [DllImport("kernel32.dll", EntryPoint="GetFileInformationByHandleEx", SetLastError=true)] static extern bool GetStandard(SafeFileHandle handle, int kind, out Standard value, uint bytes);
        [DllImport("kernel32.dll", EntryPoint="GetFileInformationByHandleEx", SetLastError=true)] static extern bool GetId(SafeFileHandle handle, int kind, out Id value, uint bytes);
        [DllImport("kernel32.dll", EntryPoint="GetVolumeInformationByHandleW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetVolume(SafeFileHandle handle, StringBuilder name, uint nameSize, out uint serial, out uint maxComponent, out uint flags, StringBuilder fileSystem, uint fileSystemSize);
        [DllImport("kernel32.dll", EntryPoint="CreateHardLinkW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool Link(string path, string existing, IntPtr security);
        [DllImport("ntdll.dll")] static extern int NtCreateFile(out SafeFileHandle handle, uint access, ref ObjectAttributes attributes, out IoStatus status, IntPtr allocation, uint fileAttributes, uint share, uint disposition, uint options, IntPtr ea, uint eaLength);
        [DllImport("ntdll.dll")] static extern uint RtlNtStatusToDosError(int status);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind, ref Disposition value, uint bytes);
        static void Require(bool good, string operation) { if(!good) throw new Win32Exception(Marshal.GetLastWin32Error(), operation); }
        static SafeFileHandle Open(string path, uint access, uint share)
        {
            if(!Path.IsPathFullyQualified(path)) throw new ArgumentException("Absolute stock path required");
            // OPEN_REPARSE_POINT + BACKUP_SEMANTICS: inspect the named object,
            // never silently follow a file or directory junction/symlink.
            var handle=CreateFile(path,access,share,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
            if(handle.IsInvalid) { int error=Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error,"Open stock metadata/identity handle"); }
            try { var info=Inspect(handle); if((info.Attributes & 0x400)!=0 || info.DeletePending) throw new InvalidOperationException("Reparse/delete-pending stock object refused"); return handle; }
            catch { handle.Dispose(); throw; }
        }
        // Request read access solely to enforce sharing; never call ReadFile.
        public static SafeFileHandle OpenStock(string path) { return Open(path,0x81,5); }
        public static SafeFileHandle OpenDirectory(string path)
        {
            var handle=Open(path,0x81,3);
            if(!Inspect(handle).Directory) { handle.Dispose(); throw new InvalidOperationException("Actual stock directory required"); }
            return handle;
        }
        public static SafeFileHandle OpenOwnedDelete(string path) { return Open(path,0x10080,1); }
        public static Metadata Inspect(SafeFileHandle handle)
        {
            if(handle==null || handle.IsClosed || handle.IsInvalid) throw new InvalidOperationException("Original stock handle unavailable");
            Basic basic; Standard standard; Id id;
            Require(GetBasic(handle,0,out basic,(uint)Marshal.SizeOf<Basic>()),"Read FILE_BASIC_INFO");
            Require(GetStandard(handle,1,out standard,(uint)Marshal.SizeOf<Standard>()),"Read FILE_STANDARD_INFO");
            Require(GetId(handle,18,out id,(uint)Marshal.SizeOf<Id>()),"Read FILE_ID_INFO");
            var fs=new StringBuilder(32); uint serial,max,flags;
            Require(GetVolume(handle,null,0,out serial,out max,out flags,fs,(uint)fs.Capacity),"Read stock volume filesystem");
            if(fs.ToString()!="NTFS") throw new InvalidOperationException("Same-volume NTFS stock links required");
            string hex=BitConverter.ToString(id.Bytes).Replace("-","");
            return new Metadata { Identity=id.Volume.ToString("X16")+":"+hex, Volume=id.Volume.ToString(System.Globalization.CultureInfo.InvariantCulture),
                FileIdLow=BitConverter.ToUInt64(id.Bytes,0).ToString(System.Globalization.CultureInfo.InvariantCulture), FileId128=hex, FileSystem=fs.ToString(),
                Bytes=standard.Size, AllocatedBytes=standard.Allocation, Links=standard.Links, Attributes=basic.Attributes, Directory=standard.Directory,
                DeletePending=standard.Pending, CreationFileTime=basic.Creation, LastAccessFileTime=basic.Access, LastWriteFileTime=basic.Write, ChangeFileTime=basic.Change };
        }
        public static void CreateLinkNew(string path, string existing)
        {
            if(!Link(path,existing,IntPtr.Zero)) throw new CreationRefusedException(Marshal.GetLastWin32Error(),"Create new stock hardlink; no copy fallback");
        }
        public static SafeFileHandle CreateDirectoryOwned(string path)
        {
            if(!Path.IsPathFullyQualified(path) || path.StartsWith(@"\\")) throw new ArgumentException("Local absolute owned directory required");
            string name=@"\??\"+path;
            int bytes=checked(name.Length*2);
            if(bytes>65532) throw new ArgumentException("Owned directory name too long");
            IntPtr buffer=Marshal.StringToHGlobalUni(name), unicode=IntPtr.Zero;
            try {
                var text=new UnicodeString { Length=(ushort)bytes, MaximumLength=(ushort)(bytes+2), Buffer=buffer };
                unicode=Marshal.AllocHGlobal(Marshal.SizeOf<UnicodeString>()); Marshal.StructureToPtr(text,unicode,false);
                var attributes=new ObjectAttributes { Length=(uint)Marshal.SizeOf<ObjectAttributes>(), Name=unicode, Attributes=0x40 };
                SafeFileHandle handle; IoStatus result;
                // FILE_CREATE returns the new directory's original handle in
                // the same operation. No reopen/adoption race; no DELETE share.
                int status=NtCreateFile(out handle,0x81,ref attributes,out result,IntPtr.Zero,0x10,3,2,1,IntPtr.Zero,0);
                if(status<0) { if(handle!=null) handle.Dispose(); throw new CreationRefusedException((int)RtlNtStatusToDosError(status),"Create original owned directory handle"); }
                return handle;
            } finally { if(unicode!=IntPtr.Zero) Marshal.FreeHGlobal(unicode); Marshal.FreeHGlobal(buffer); }
        }
        public static void UnlinkByHandle(SafeFileHandle handle)
        {
            Inspect(handle);
            // Delete only this opened name. IGNORE_READONLY_ATTRIBUTE does not
            // clear the shared file's attributes. No path/recursive fallback.
            var value=new Disposition { Flags=0x1|0x2|0x10 };
            Require(SetFileInformationByHandle(handle,21,ref value,4),"Unlink exact owned NTFS name by handle");
        }
    }
}
