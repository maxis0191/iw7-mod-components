// Single-file onboarding for the managed client. No administrator rights,
// shell commands, game download, default executable replacement or DLL loading.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Net;
using System.Threading;
using System.Management;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using System.Web.Script.Serialization;
using Microsoft.Win32;

static class AutoClient {
    public sealed class DataFile { public string Path {get;set;} public long Bytes {get;set;} public string SHA1 {get;set;} public string Url {get;set;} }
    public sealed class DataManifest { public string Schema {get;set;} public string CBRevision {get;set;} public string OfficialDeltaRevision {get;set;} public string UpstreamManifestSHA256 {get;set;} public DataFile[] Files {get;set;} }
    public sealed class PreparedData {public int Downloaded;public int Reused;public string DataId {get;set;}}
    static string FileSHA1(string path) {using(var stream=File.OpenRead(path))using(var sha=SHA1.Create())return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-","");}
    static bool ValidData(string path,DataFile file) {
        try {return File.Exists(path) && new FileInfo(path).Length==file.Bytes && FileSHA1(path)==file.SHA1;}
        catch(IOException) {return false;}catch(UnauthorizedAccessException) {return false;}
    }
    static void PreserveRunningGames() {
        var options=new EnumerationOptions {Timeout=TimeSpan.FromSeconds(5),ReturnImmediately=false};
        using(var searcher=new ManagementObjectSearcher("root\\CIMV2","SELECT ProcessId,CommandLine FROM Win32_Process WHERE Name LIKE 'iw7%.exe'",options))
        using(var results=searcher.Get())foreach(ManagementObject item in results)using(item) {
            if(Convert.ToInt32(item["ProcessId"])==Process.GetCurrentProcess().Id)continue;
            var command=item["CommandLine"] as string;
            if(command==null || !Regex.IsMatch(command,@"(?:^|\s)-dedicated(?:\s|$)",RegexOptions.IgnoreCase))
                throw new IOException("Close the running IW7 game before starting another client. Dedicated servers are preserved.");
        }
    }
    static PreparedData PrepareData(string game,bool qualification,bool forceDownload) {
        var result=new PreparedData();
        DataManifest manifest;
        using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("community-data.json"))using(var reader=new StreamReader(stream)) {
            var text=reader.ReadToEnd();result.DataId=Hash(Encoding.UTF8.GetBytes(text));
            manifest=new JavaScriptSerializer().Deserialize<DataManifest>(text);
        }
        if(manifest==null || manifest.Schema!="iw7.auto-client-data/1" || manifest.Files==null || manifest.Files.Length!=47)
            throw new IOException("Invalid bundled game-data list.");
        var root=Path.Combine(game,@"iw7-mod\server-profiles\community-data",result.DataId.Substring(0,32));LiteralDirectory(root);
        var stamp=Path.Combine(root,"manifest.sha256");
        if(File.Exists(stamp)) {if(File.ReadAllText(stamp)!=result.DataId)throw new IOException("A managed data-folder identity changed; it has been preserved.");}
        else File.WriteAllText(stamp,result.DataId,new UTF8Encoding(false));
        var ordinary=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),@"auroramod\iw7-mod");
        var extensions=new HashSet<string>(new[]{".arena",".ff",".gsc",".lua",".pak",".sabl",".sabs"},StringComparer.OrdinalIgnoreCase);
        var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);long total=0,completed=0;
        foreach(var file in manifest.Files) {
            if(file==null || !file.Path.StartsWith("cdata/",StringComparison.Ordinal) || file.Path.Contains("..") || file.Path.Contains(":") || file.Path.Contains("\\") ||
                file.Bytes<0 || file.Bytes>256*1024*1024 || !extensions.Contains(Path.GetExtension(file.Path)) || !Regex.IsMatch(file.SHA1,@"\A[A-F0-9]{40}\z") || !seen.Add(file.Path))throw new IOException("Invalid bundled game-data entry.");
            var cb="https://github.com/CBServers/updater/raw/"+manifest.CBRevision+"/updater/iw7-mod/data/"+file.Path;
            var aurora="https://github.com/auroramod/iw7-mod/raw/"+manifest.OfficialDeltaRevision+"/data/"+file.Path;
            if(file.Url!=cb && file.Url!=aurora)throw new IOException("Untrusted game-data source.");total+=file.Bytes;
        }
        Form window=null;ProgressBar bar=null;bool cancelled=false;
        try {
            if(!qualification) {
                Application.EnableVisualStyles();
                window=new Form {Text="IW7 Paris",Width=440,Height=135,StartPosition=FormStartPosition.CenterScreen,FormBorderStyle=FormBorderStyle.FixedDialog,MaximizeBox=false};
                window.Controls.Add(new Label {Text="Preparing game files...",Left=20,Top=15,Width=390});
                bar=new ProgressBar {Left=20,Top=45,Width=385,Height=22};window.Controls.Add(bar);
                window.FormClosing+=(s,e)=>{cancelled=true;};window.Show();Application.DoEvents();
            }
            ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
            foreach(var file in manifest.Files) {
                if(cancelled)throw new OperationCanceledException("Preparation cancelled.");
                var target=Path.Combine(root,file.Path.Replace('/',Path.DirectorySeparatorChar));LiteralDirectory(Path.GetDirectoryName(target));
                if(!ValidData(target,file)) {
                    if(File.Exists(target))File.Move(target,target+".unverified-"+Guid.NewGuid().ToString("N"));
                    var temporary=Path.Combine(Path.GetDirectoryName(target),Guid.NewGuid().ToString("N")+".tmp");
                    try {
                        var existing=Path.Combine(ordinary,file.Path.Replace('/',Path.DirectorySeparatorChar));
                        if(!forceDownload && ValidData(existing,file)) {File.Copy(existing,temporary,false);result.Reused++;}
                        else {
                            for(int attempt=0;attempt<3;attempt++) {
                                Exception failure=null;
                                using(var client=new WebClient()) using(var done=new ManualResetEvent(false)) {
                                    client.Headers[HttpRequestHeader.UserAgent]="IW7-Paris-auto-client/1";
                                    client.DownloadFileCompleted+=(s,e)=>{failure=e.Error;if(e.Cancelled)failure=new OperationCanceledException("Preparation cancelled.");done.Set();};
                                    client.DownloadProgressChanged+=(s,e)=>{if(e.BytesReceived>file.Bytes)client.CancelAsync();if(bar!=null && !bar.IsDisposed)bar.Value=(int)Math.Max(0,Math.Min(100,(completed+e.BytesReceived)*100/total));};
                                    client.DownloadFileAsync(new Uri(file.Url),temporary);
                                    var clock=Stopwatch.StartNew();
                                    while(!done.WaitOne(20)) {Application.DoEvents();if(cancelled || clock.Elapsed.TotalMinutes>15)client.CancelAsync();}
                                }
                                if(cancelled)throw new OperationCanceledException("Preparation cancelled.");
                                if(failure==null && ValidData(temporary,file))break;
                                if(attempt==2)throw new IOException("Game-file download failed verification after three attempts. Run the launcher again to retry.",failure);
                                if(File.Exists(temporary))File.Delete(temporary);
                                var delay=Stopwatch.StartNew();while(delay.Elapsed.TotalSeconds<attempt+1) {Application.DoEvents();if(cancelled)throw new OperationCanceledException();Thread.Sleep(20);}
                            }
                            result.Downloaded++;
                        }
                        if(!ValidData(temporary,file))throw new IOException("A downloaded game file failed verification.");
                        File.Move(temporary,target);
                    }finally{if(File.Exists(temporary))File.Delete(temporary);}
                }
                completed+=file.Bytes;if(bar!=null && !bar.IsDisposed)bar.Value=(int)(completed*100/total);Application.DoEvents();
            }
        }finally{if(window!=null)window.Dispose();}
        return result;
    }
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
    static IEnumerable<string> ShortcutCandidates() {
        var desktop=Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        if(!Directory.Exists(desktop))yield break;
        var type=Type.GetTypeFromProgID("WScript.Shell");
        object shell=type==null?null:Activator.CreateInstance(type);
        if(shell==null)yield break;
        try {
            foreach(var link in Directory.GetFiles(desktop,"*.lnk")) {
                object shortcut=null;string directory=null,working=null;
                try {
                    shortcut=type.InvokeMember("CreateShortcut",BindingFlags.InvokeMethod,null,shell,new object[]{link});
                    string target=(string)shortcut.GetType().InvokeMember("TargetPath",BindingFlags.GetProperty,null,shortcut,null);
                    working=(string)shortcut.GetType().InvokeMember("WorkingDirectory",BindingFlags.GetProperty,null,shortcut,null);
                    if(!String.IsNullOrEmpty(target) && Path.IsPathRooted(target) && !target.StartsWith(@"\\",StringComparison.Ordinal))directory=Path.GetDirectoryName(target);
                }catch(System.Runtime.InteropServices.COMException) {continue;}
                finally{if(shortcut!=null)System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shortcut);}
                yield return directory;
                if(!String.IsNullOrEmpty(working) && !working.StartsWith(@"\\",StringComparison.Ordinal))yield return working;
            }
        }finally{System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell);}
    }
    static IEnumerable<string> Candidates() {
        yield return Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        yield return Environment.CurrentDirectory;
        foreach(var candidate in ShortcutCandidates())yield return candidate;
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
            string game=null,connect=null,probeCache=null,probePassword=null,probeReturn=null;bool detect=false,forceDownload=false;
            for(int i=0;i<args.Length;i++) {
                if(args[i]=="--game-root" && i+1<args.Length)game=args[++i];
                else if(args[i]=="--connect" && i+1<args.Length)connect=args[++i];
                else if(args[i]=="--detect-only")detect=true;
                else if(args[i]=="--qualification-cache" && i+1<args.Length)probeCache=args[++i];
                else if(args[i]=="--qualification-password" && i+1<args.Length)probePassword=args[++i];
                else if(args[i]=="--qualification-return" && i+1<args.Length)probeReturn=args[++i];
                else if(args[i]=="--qualification-download")forceDownload=true;
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
            PreserveRunningGames();
            if(connect!=null && (!Regex.IsMatch(connect,@"\A(?:\d{1,3}\.){3}\d{1,3}:\d{1,5}\z") ||
                !ValidEndpoint(connect)))throw new ArgumentException("A valid IPv4 server endpoint is required.");
            if(probeCache!=null && (connect==null || !connect.StartsWith("127.0.0.1:",StringComparison.Ordinal) ||
                Int32.Parse(connect.Substring(10))<27100 || Int32.Parse(connect.Substring(10))>27999))
                throw new ArgumentException("Qualification cache requires a private loopback server.");
            if((probePassword!=null || probeReturn!=null || forceDownload) && probeCache==null)throw new ArgumentException("Qualification options need their explicit private cache.");
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
            if(File.Exists(image) && (new FileInfo(image).Length!=bytes.Length || Hash(File.ReadAllBytes(image))!=expected))
                File.Move(image,image+".unverified-"+Guid.NewGuid().ToString("N"));
            if(!File.Exists(image)) {
                var temporary=Path.Combine(directory,Guid.NewGuid().ToString("N")+".tmp");
                using(var file=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {file.Write(bytes,0,bytes.Length);file.Flush(true);}
                if(Hash(File.ReadAllBytes(temporary))!=expected)throw new IOException("Installed client verification failed.");
                File.Move(temporary,image);
            }
            var arguments="-noupdate -cpMode";
            var prepared=PrepareData(game,probeCache!=null,forceDownload);
            arguments+=" -paris-auto-managed-data +set g_consoleLog iw7-mod/server-profiles/console.log";
            if(connect!=null)arguments+=" "+Quote("-paris-auto-target="+connect)+" -paris-auto-mode=3";
            if(probeCache!=null)arguments+=" -nosteam -stdout -wincon +set net_ip 127.0.0.1 +set net_port 27948 +set r_fullscreen 0 +set r_fullscreenWindow 0 +set vid_width 1280 +set vid_height 720 +set r_mode 1280x720 +set r_vsync 1 +set com_maxfps 30 +set r_picmip 2 +set r_picmip_bump 2 +set r_picmip_spec 2";
            if(probePassword!=null)arguments+=" +set password "+Quote(probePassword);
            if(probeReturn!=null)arguments+=" "+Quote("-paris-auto-return="+probeReturn);
            var start=new ProcessStartInfo(image,arguments) {WorkingDirectory=game,UseShellExecute=false};
            start.EnvironmentVariables["IW7_AUTO_DATA_ID"]=prepared.DataId;
            if(probeCache!=null)start.EnvironmentVariables["IW7_AUTO_QUALIFY"]="1";
            else start.EnvironmentVariables.Remove("IW7_AUTO_QUALIFY");
            PreserveRunningGames();
            using(var process=Process.Start(start)) {
                if(process==null)throw new IOException("The client could not be started.");
                if(probeCache!=null) {
                    var record=Path.Combine(Path.GetFullPath(probeCache),"initial-client.json");
                    var temporary=Path.Combine(Path.GetFullPath(probeCache),Guid.NewGuid().ToString("N")+".tmp");
                    File.WriteAllText(temporary,"{\"pid\":"+process.Id+",\"creation\":"+process.StartTime.ToUniversalTime().ToFileTimeUtc()+",\"sha256\":\""+expected+"\",\"downloaded_files\":"+prepared.Downloaded+",\"reused_files\":"+prepared.Reused+"}",new UTF8Encoding(false));
                    File.Move(temporary,record);
                }
                if(probeCache!=null)process.WaitForExit();
            }
            return 0;
        }catch(OperationCanceledException) {return 1;}
        catch(Exception error) {
            if(Array.IndexOf(args,"--qualification-cache")>=0 || Array.IndexOf(args,"--detect-only")>=0)Console.Error.WriteLine(error.Message);
            else MessageBox.Show(error.Message,"IW7 automatic profiles",MessageBoxButtons.OK,MessageBoxIcon.Error);
            return 1;
        }
    }
    static bool ValidEndpoint(string value) {
        var colon=value.IndexOf(':');int port;
        if(colon<0 || !Int32.TryParse(value.Substring(colon+1),out port) || port<1 || port>65535)return false;
        foreach(var octet in value.Substring(0,colon).Split('.')) {int n;if(!Int32.TryParse(octet,out n)||n<0||n>255)return false;}
        return true;
    }
}
