using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace IW7.VoiceAgent
{
    public sealed class TokenState { public bool Elevated { get; set; } public string ElevationType { get; set; } }
    public static class TokenInventory
    {
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out SafeAccessTokenHandle token);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(SafeAccessTokenHandle token,int kind,out uint value,int size,out int needed);
        public static TokenState Read()
        {
            SafeAccessTokenHandle token;
            if (!OpenProcessToken(GetCurrentProcess(),8,out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
            using (token)
            {
                uint elevated,type;int needed;
                if (!GetTokenInformation(token,20,out elevated,4,out needed) || !GetTokenInformation(token,18,out type,4,out needed)) throw new Win32Exception(Marshal.GetLastWin32Error());
                return new TokenState { Elevated=elevated!=0, ElevationType=type==1 ? "default" : type==2 ? "full" : type==3 ? "limited" : "unknown" };
            }
        }
    }
}
