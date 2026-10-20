// Single-file onboarding for the managed client. No administrator rights,
// shell commands, game download, default executable replacement or DLL loading.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Win32;

static class AutoClient {
    static string Hash(byte[] bytes) {
        using(var hash=SHA256.Create()) return BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-","");
    }
    static bool Game(string path) {
        try { return !String.IsNullOrEmpty(path) && File.Exists(Path.Combine(path,"iw7_ship.exe")); }
        catch { return false; }
    }
    static string RegistryText(RegistryHive hive,RegistryView view,string key,string name) {
        using(var root=RegistryKey.OpenBaseKey(hive,view)) using(var item=root.OpenSubKey(key))
            return item==null ? null : item.GetValue(name) as string;
    }
    static IEnumerable<string> Candidates() {
        yield return Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        yield return Environment.CurrentDirectory;
        foreach(var view in new[]{RegistryView.Registry64,RegistryView.Registry32})
            yield return RegistryText(RegistryHive.LocalMachine,view,@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 292730","InstallLocation");
        var steam=RegistryText(RegistryHive.CurrentUser,RegistryView.Default,@"Software\Valve\Steam","SteamPath");
        if(!String.IsNullOrEmpty(steam)) {
            var libraries=new List<string>();libraries.Add(steam);
            var file=Path.Combine(steam,@"steamapps\libraryfolders.vdf");
            if(File.Exists(file)) foreach(Match match in Regex.Matches(File.ReadAllText(file),"\"path\"\\s+\"([^\"]+)\""))
                libraries.Add(match.Groups[1].Value.Replace(@"\\",@"\"));
            foreach(var library in libraries) {
                var manifest=Path.Combine(library,@"steamapps\appmanifest_292730.acf");
                if(!File.Exists(manifest))continue;
                var match=Regex.Match(File.ReadAllText(manifest),"\"installdir\"\\s+\"([^\"]+)\"");
                if(match.Success && Path.GetFileName(match.Groups[1].Value)==match.Groups[1].Value)
                    yield return Path.Combine(library,@"steamapps\common",match.Groups[1].Value);
            }
        }
        // Existing user shortcuts also cover legitimate moved installations.
        var desktop=Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        if(Directory.Exists(desktop)) {
            var type=Type.GetTypeFromProgID("WScript.Shell");
            object shell=type==null?null:Activator.CreateInstance(type);
            if(shell!=null) {
                foreach(var link in Directory.GetFiles(desktop,"*.lnk")) {
                    object shortcut=type.InvokeMember("CreateShortcut",BindingFlags.InvokeMethod,null,shell,new object[]{link});
                    string target=(string)shortcut.GetType().InvokeMember("TargetPath",BindingFlags.GetProperty,null,shortcut,null);
                    yield return String.IsNullOrEmpty(target)?null:Path.GetDirectoryName(target);
                    System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shortcut);
                }
                System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell);
            }
        }
    }
    static string Quote(string text) {
        var result=new StringBuilder("\"");int slashes=0;
        foreach(char c in text) {
            if(c=='\\') {slashes++;continue;}
            result.Append('\\',c=='"'?slashes*2+1:slashes);result.Append(c);slashes=0;
        }
        result.Append('\\',slashes*2);result.Append('"');return result.ToString();
    }
    static void LiteralDirectory(string directory) {
        for(var p=new DirectoryInfo(Path.GetFullPath(directory));p!=null;p=p.Parent)
            if(p.Exists && (p.Attributes&FileAttributes.ReparsePoint)!=0) throw new IOException("Redirected installation folder refused.");
        Directory.CreateDirectory(directory);
    }
    [STAThread] static int Main(string[] args) {
        try {
            string game=null,connect=null,probeCache=null,probePassword=null,probeReturn=null;bool detect=false;
            for(int i=0;i<args.Length;i++) {
                if(args[i]=="--game-root" && i+1<args.Length)game=args[++i];
                else if(args[i]=="--connect" && i+1<args.Length)connect=args[++i];
                else if(args[i]=="--detect-only")detect=true;
                else if(args[i]=="--qualification-cache" && i+1<args.Length)probeCache=args[++i];
                else if(args[i]=="--qualification-password" && i+1<args.Length)probePassword=args[++i];
                else if(args[i]=="--qualification-return" && i+1<args.Length)probeReturn=args[++i];
                else throw new ArgumentException("Unknown launcher argument.");
            }
            if(game==null)foreach(var candidate in Candidates())if(Game(candidate)) {game=candidate;break;}
            if(!Game(game)) {
                if(detect)throw new IOException("A working Infinite Warfare installation was not detected.");
                using(var dialog=new FolderBrowserDialog()) {
                    dialog.Description="Select your existing Call of Duty: Infinite Warfare folder";
                    if(dialog.ShowDialog()!=DialogResult.OK)return 1;game=dialog.SelectedPath;
                }
            }
            if(!Game(game))throw new IOException("The selected folder does not contain iw7_ship.exe.");
            game=Path.GetFullPath(game);
            if(detect) {Console.WriteLine(game);return 0;}
            if(connect!=null && (!Regex.IsMatch(connect,@"\A(?:\d{1,3}\.){3}\d{1,3}:\d{1,5}\z") ||
                !ValidEndpoint(connect)))throw new ArgumentException("A valid IPv4 server endpoint is required.");
            if(probeCache!=null && (connect==null || !connect.StartsWith("127.0.0.1:",StringComparison.Ordinal) ||
                Int32.Parse(connect.Substring(10))<27100 || Int32.Parse(connect.Substring(10))>27999))
                throw new ArgumentException("Qualification cache requires a private loopback server.");
            if((probePassword!=null || probeReturn!=null) && probeCache==null)throw new ArgumentException("Qualification options need their explicit private cache.");
            if(probePassword!=null && !Regex.IsMatch(probePassword,@"\A[a-f0-9]{32}\z"))throw new ArgumentException("Invalid private qualification password.");
            if(probeReturn!=null && (!ValidEndpoint(probeReturn) || !probeReturn.StartsWith("127.0.0.1:",StringComparison.Ordinal) ||
                Int32.Parse(probeReturn.Substring(10))<27100 || Int32.Parse(probeReturn.Substring(10))>27999))throw new ArgumentException("Invalid private qualification return server.");
            var assembly=Assembly.GetExecutingAssembly();string expected;
            using(var stream=assembly.GetManifestResourceStream("client.sha256")) using(var reader=new StreamReader(stream))expected=reader.ReadToEnd().Trim();
            if(!Regex.IsMatch(expected,@"\A[A-F0-9]{64}\z"))throw new IOException("Invalid bundled client identity.");
            byte[] bytes;
            using(var stream=assembly.GetManifestResourceStream("client.gz")) using(var zip=new GZipStream(stream,CompressionMode.Decompress)) using(var output=new MemoryStream()) {
                var buffer=new byte[65536];int read;
                while((read=zip.Read(buffer,0,buffer.Length))!=0) {if(output.Length+read>32*1024*1024)throw new IOException("Bundled client exceeds its size bound.");output.Write(buffer,0,read);}
                bytes=output.ToArray();
            }
            if(Hash(bytes)!=expected)throw new IOException("Bundled client verification failed.");
            var directory=probeCache==null ? Path.Combine(game,@"iw7-mod\server-profiles\client",expected) : Path.Combine(Path.GetFullPath(probeCache),expected);
            LiteralDirectory(directory);var image=Path.Combine(directory,"iw7-paris-auto.exe");
            if(File.Exists(image)) {if(new FileInfo(image).Length!=bytes.Length || Hash(File.ReadAllBytes(image))!=expected)throw new IOException("An existing managed client was modified; it has been preserved.");}
            else {
                var temporary=Path.Combine(directory,Guid.NewGuid().ToString("N")+".tmp");
                using(var file=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {file.Write(bytes,0,bytes.Length);file.Flush(true);}
                if(Hash(File.ReadAllBytes(temporary))!=expected)throw new IOException("Installed client verification failed.");
                File.Move(temporary,image);
            }
            var arguments="-noupdate -cpMode";
            if(connect!=null)arguments+=" "+Quote("-paris-auto-target="+connect)+" -paris-auto-mode=3";
            if(probeCache!=null)arguments+=" -nosteam -stdout -wincon +set net_ip 127.0.0.1 +set net_port 27948 +set r_fullscreen 0 +set r_fullscreenWindow 0 +set vid_width 1280 +set vid_height 720 +set r_mode 1280x720 +set r_vsync 1 +set com_maxfps 30 +set r_picmip 2 +set r_picmip_bump 2 +set r_picmip_spec 2";
            if(probePassword!=null)arguments+=" +set password "+Quote(probePassword);
            if(probeReturn!=null)arguments+=" "+Quote("-paris-auto-return="+probeReturn);
            var start=new ProcessStartInfo(image,arguments) {WorkingDirectory=game,UseShellExecute=false};
            using(var process=Process.Start(start)) {
                if(process==null)throw new IOException("The client could not be started.");
                if(probeCache!=null)File.WriteAllText(Path.Combine(Path.GetFullPath(probeCache),"initial-client.json"),
                    "{\"pid\":"+process.Id+",\"creation\":"+process.StartTime.ToUniversalTime().ToFileTimeUtc()+",\"sha256\":\""+expected+"\"}",new UTF8Encoding(false));
                if(probeCache!=null)process.WaitForExit();
            }
            return 0;
        }catch(Exception error) {MessageBox.Show(error.Message,"IW7 automatic profiles",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1;}
    }
    static bool ValidEndpoint(string value) {
        var colon=value.IndexOf(':');int port;
        if(colon<0 || !Int32.TryParse(value.Substring(colon+1),out port) || port<1 || port>65535)return false;
        foreach(var octet in value.Substring(0,colon).Split('.')) {int n;if(!Int32.TryParse(octet,out n)||n<0||n>255)return false;}
        return true;
    }
}
