// Managed data preparation only. Never call AutoClient.Main or start IW7.
using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Web.Script.Serialization;

static class AutoClientDataProbe {
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    static AutoClient.PreparedData Prepare(string root) {
        try {
            return (AutoClient.PreparedData)typeof(AutoClient).GetMethod("PrepareData",BindingFlags.NonPublic|BindingFlags.Static)
                .Invoke(null,new object[]{root,true,true});
        }catch(TargetInvocationException error) {throw error.InnerException;}
    }
    static void Check(bool passed,string message) {if(!passed)throw new InvalidOperationException(message);}
    [STAThread]
    static int Main(string[] args) {
        try {
            AutoClient.DataManifest manifest;
            using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("community-data.json"))using(var reader=new StreamReader(stream))
                manifest=Json.Deserialize<AutoClient.DataManifest>(reader.ReadToEnd());
            Check(manifest.Files.Length==47,"Closed publisher file count changed.");
            long bytes=0;foreach(var file in manifest.Files)bytes+=file.Bytes;
            Check(bytes==371063469,"Closed publisher byte count changed.");
            if(args.Length==0) {
                Console.WriteLine(Json.Serialize(new {SourceCompiled=true,Files=47,Bytes=bytes,Network=false,GameLaunched=false}));return 0;
            }
            Check(args.Length==1,"One new data-only root required.");
            var root=Path.GetFullPath(args[0]);
            Check(!Directory.Exists(root) && !File.Exists(root),"Preserve existing roots; use a new data-only root.");
            Check(!File.Exists(Path.Combine(root,"iw7_ship.exe")),"A retail game root is not a data test root.");
            Console.WriteLine("Managed data probe: starting actual cold preparation (47 publisher files).");
            var cold=Prepare(root);
            Check(cold.Downloaded==47 && cold.Reused==0,"Cold preparation did not download every publisher dependency.");
            Console.WriteLine("Managed data probe: cold PASS; starting warm-cache preparation.");
            var warm=Prepare(root);
            Check(warm.Downloaded==0 && warm.Reused==0 && warm.DataId==cold.DataId,"Warm cache downloaded or changed identity.");
            var relative=manifest.Files[0].Path.Replace('/',Path.DirectorySeparatorChar);
            var target=Path.Combine(root,@"iw7-mod\server-profiles\community-data",cold.DataId.Substring(0,32),relative);
            var before=File.ReadAllBytes(target);File.AppendAllText(target,"\nDATA_PROBE_CORRUPTION\n",new UTF8Encoding(false));
            Console.WriteLine("Managed data probe: warm PASS; starting one-file corruption recovery.");
            var repaired=Prepare(root);
            Check(repaired.Downloaded==1 && repaired.Reused==0 && repaired.DataId==cold.DataId,"Repair did not download exactly the changed dependency.");
            var after=File.ReadAllBytes(target);
            Check(Convert.ToBase64String(before)==Convert.ToBase64String(after),"Repaired dependency bytes differ.");
            var quarantined=Directory.GetFiles(Path.GetDirectoryName(target),Path.GetFileName(target)+".unverified-*");
            Check(quarantined.Length==1,"Corrupted file was not preserved in managed quarantine.");
            var result=Json.Serialize(new {Passed=true,SourceCompiled=true,Files=47,Bytes=bytes,
                ColdDownloaded=cold.Downloaded,WarmDownloaded=warm.Downloaded,RepairDownloaded=repaired.Downloaded,
                CorruptionPreserved=true,DataId=cold.DataId,Network=true,GameLaunched=false,OnboardingMainExecuted=false});
            File.WriteAllText(Path.Combine(root,"data-probe-result.json"),result+"\n",new UTF8Encoding(false));
            Console.WriteLine(result);return 0;
        }catch(Exception error) {Console.Error.WriteLine(error.ToString());return 1;}
    }
}
