using System;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Diagnostics;
using System.Threading;
using Wuthering.Native;

public static class LauncherMaintenanceTests
{
    static int checks;
    static string root;
    static Process Start(string exe,string arguments) {return Process.Start(new ProcessStartInfo(exe,arguments){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true});}
    static bool Until(Func<bool> predicate) {var t=Stopwatch.StartNew();while(t.ElapsedMilliseconds<10000) {if(predicate())return true;Thread.Sleep(50);}return false;}
    static int ParentFixture(string[] args) {
        string r=args[1],helper=args[2];string self=Process.GetCurrentProcess().MainModule.FileName;
        int pid=Process.GetCurrentProcess().Id;long created=Process.GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc();
        using(var p=Start(helper,"replace \""+r+"\" \""+self+"\" "+pid+" "+created)) {
            string ready=Path.Combine(r,"config","launcher_replace_"+pid+"_"+created+".ready");
            if(!Until(delegate {return File.Exists(ready)||p.HasExited;})||p.HasExited)return 2;
            File.WriteAllText(Path.Combine(r,"child-pid.txt"),p.Id.ToString());
            return Until(delegate {return File.Exists(Path.Combine(r,"exit-parent"));})?0:3;
        }
    }
    static void Check(bool condition,string message) { if(!condition) throw new Exception(message); ++checks; }
    static void Reject(Action action,string message) { bool failed=false;try {action();}catch {failed=true;}Check(failed,message); }
    static string Fixture(string name) {string p=Path.Combine(root,name);Directory.CreateDirectory(p);return p;}
    static string Hash(string path) {using(var s=File.OpenRead(path))using(var h=SHA256.Create())return BitConverter.ToString(h.ComputeHash(s)).Replace("-","").ToLowerInvariant();}
    static void Zip(string path,params string[] names) {
        using(var f=File.Create(path))using(var z=new ZipArchive(f,ZipArchiveMode.Create))
            foreach(string name in names) using(var w=new StreamWriter(z.CreateEntry(name).Open())) w.Write("new payload");
    }
    static void Pending(string r,string source,string version,string hash) {
        string c=Path.Combine(r,"config");Directory.CreateDirectory(c);
        File.WriteAllText(Path.Combine(c,"launcher_pending_update.tmp"),source);
        File.WriteAllText(Path.Combine(c,"launcher_pending_version.txt"),version);
        File.WriteAllText(Path.Combine(c,"launcher_pending_sha256.txt"),hash);
    }
    public static int Main(string[] args) {
        try {
            if(args[0]=="--parent")return ParentFixture(args);
            root=Path.GetFullPath(args[0]);Directory.CreateDirectory(root);
            string r=Fixture("valid-zip");Directory.CreateDirectory(Path.Combine(r,"payload"));
            File.WriteAllText(Path.Combine(r,"payload","old.txt"),"preserve on failure");
            Zip(Path.Combine(r,"payload.zip"),"全自動.ahk","sub/中文.txt");
            LauncherMaintenance.Extract(r);
            Check(File.ReadAllText(Path.Combine(r,"payload","sub","中文.txt"))=="new payload","Unicode payload extraction");
            Check(!File.Exists(Path.Combine(r,"payload","old.txt")),"Successful update replaces old files");
            foreach(string name in new[]{"../escape.txt","/rooted.txt","sub/../../escape.txt","C:/escape.txt","x:stream","dir/CON.txt","tail. ","dir\\..\\escape.txt"}) {
                r=Fixture("unsafe-"+checks);Directory.CreateDirectory(Path.Combine(r,"payload"));File.WriteAllText(Path.Combine(r,"payload","old.txt"),"old");
                Zip(Path.Combine(r,"payload.zip"),"全自動.ahk",name);
                Reject(delegate {LauncherMaintenance.Extract(r);},"Unsafe entry must fail: "+name);
                Check(File.ReadAllText(Path.Combine(r,"payload","old.txt"))=="old","Invalid ZIP preserves installation");
            }
            r=Fixture("duplicate");Zip(Path.Combine(r,"payload.zip"),"全自動.ahk","SAME.txt","same.txt");
            Reject(delegate {LauncherMaintenance.Extract(r);},"Case-insensitive aliases rejected");
            r=Fixture("missing-main");Zip(Path.Combine(r,"payload.zip"),"other.txt");
            Reject(delegate {LauncherMaintenance.Extract(r);},"Incomplete payload must not publish");
            r=Fixture("corrupt");Directory.CreateDirectory(Path.Combine(r,"payload"));File.WriteAllText(Path.Combine(r,"payload","old.txt"),"old");File.WriteAllText(Path.Combine(r,"payload.zip"),"broken");
            Reject(delegate {LauncherMaintenance.Extract(r);},"Corrupt ZIP fails");Check(File.Exists(Path.Combine(r,"payload","old.txt")),"Corrupt ZIP preserves old payload");
            r=Fixture("crc-corrupt");Directory.CreateDirectory(Path.Combine(r,"payload"));File.WriteAllText(Path.Combine(r,"payload","old.txt"),"old");
            Zip(Path.Combine(r,"payload.zip"),"全自動.ahk");
            byte[] archive=File.ReadAllBytes(Path.Combine(r,"payload.zip"));
            for(int i=0;i<archive.Length-46;i++)if(BitConverter.ToUInt32(archive,i)==0x02014b50) {archive[i+16]^=1;break;}
            File.WriteAllBytes(Path.Combine(r,"payload.zip"),archive);
            Reject(delegate {LauncherMaintenance.Extract(r);},"Same-length ZIP CRC corruption must not publish");
            Check(File.ReadAllText(Path.Combine(r,"payload","old.txt"))=="old","CRC failure preserves original payload");
            r=Fixture("content-corrupt");Directory.CreateDirectory(Path.Combine(r,"payload"));File.WriteAllText(Path.Combine(r,"payload","old.txt"),"old");
            using(var f=File.Create(Path.Combine(r,"payload.zip")))using(var z=new ZipArchive(f,ZipArchiveMode.Create))
                using(var w=new StreamWriter(z.CreateEntry("全自動.ahk",CompressionLevel.NoCompression).Open()))w.Write("fixed length payload");
            archive=File.ReadAllBytes(Path.Combine(r,"payload.zip"));byte[] find=System.Text.Encoding.UTF8.GetBytes("fixed length payload");bool changed=false;
            for(int i=0;i<=archive.Length-find.Length;i++) {bool match=true;for(int j=0;j<find.Length;j++)if(archive[i+j]!=find[j]) {match=false;break;}if(match) {archive[i]^=1;changed=true;break;}}
            Check(changed,"Fixture changes content while keeping entry length and headers intact");File.WriteAllBytes(Path.Combine(r,"payload.zip"),archive);
            Reject(delegate {LauncherMaintenance.Extract(r);},"Actual same-length content corruption rejected");
            Check(File.ReadAllText(Path.Combine(r,"payload","old.txt"))=="old","Content corruption cannot replace old payload");
            foreach(bool published in new[]{false,true}) {
                r=Fixture("crash-"+published);string work=Path.Combine(r,"執行暫存","更新"),backup=Path.Combine(work,"payload_previous");
                Directory.CreateDirectory(backup);File.WriteAllText(Path.Combine(backup,"全自動.ahk"),"known good");
                Directory.CreateDirectory(Path.Combine(r,"payload"));
                if(published)File.WriteAllText(Path.Combine(r,"payload","全自動.ahk"),"uncommitted new");
                File.WriteAllText(Path.Combine(work,"payload_transaction.txt"),"publishing");File.WriteAllText(Path.Combine(r,"payload.zip"),"invalid retry");
                Reject(delegate {LauncherMaintenance.Extract(r);},"Interrupted publication retry still reports bad candidate");
                Check(File.ReadAllText(Path.Combine(r,"payload","全自動.ahk"))=="known good","Interrupted publication restores prior runnable payload");
            }
            r=Fixture("replace");string c=Path.Combine(r,"config");Directory.CreateDirectory(c);
            string source=Path.Combine(c,"launcher_update_6.0_1.exe"),target=Path.Combine(r,"launcher.exe");
            File.WriteAllText(source,"new launcher");File.WriteAllText(target,"old launcher");Pending(r,source,"6.0",Hash(source));
            LauncherMaintenance.Replace(r,target);
            Check(File.ReadAllText(target)=="new launcher","Replacement installs verified bytes");
            Check(File.ReadAllText(Path.Combine(c,"launcher_current_version.txt"))=="6.0","Version only committed with executable");
            Check(!File.Exists(Path.Combine(c,"launcher_pending_update.tmp")),"Completed pending marker cleared");
            Check(File.ReadAllText(target+".pre_update.bak")=="old launcher","Single rollback copy retained");
            File.WriteAllText(source,"tampered");Pending(r,source,"6.1",new string('0',64));
            Reject(delegate {LauncherMaintenance.Replace(r,target);},"Bad SHA blocks replacement");Check(File.ReadAllText(target)=="new launcher","Hash failure leaves current exe intact");
            Pending(r,Path.Combine(root,"external.exe"),"6.1",new string('0',64));
            Reject(delegate {LauncherMaintenance.Replace(r,target);},"External pending source rejected");
            Pending(r,source,"6.1",Hash(source));
            using(var held=new FileStream(target,FileMode.Open,FileAccess.Read,FileShare.Read)) {
                Reject(delegate {LauncherMaintenance.Replace(r,target);},"Locked target must not be deleted");
                Check(File.ReadAllText(target)=="new launcher","Sharing failure preserves target");
                Check(File.Exists(Path.Combine(c,"launcher_pending_update.tmp")),"Failure retains pending retry state");
            }
            using(var entered=new ManualResetEvent(false))using(var release=new ManualResetEvent(false)) {
                var thread=new Thread(delegate() {using(var m=new Mutex(false,LauncherMaintenance.MutexName(r))) {m.WaitOne();entered.Set();release.WaitOne();m.ReleaseMutex();}});
                thread.Start();entered.WaitOne();
                try {Reject(delegate {LauncherMaintenance.Replace(r,target);},"Another launcher startup owns replacement lock");}
                finally {release.Set();thread.Join();}
            }
            if(args.Length>1) {
                string helper=args[1];r=Fixture("process-parent");c=Path.Combine(r,"config");Directory.CreateDirectory(c);
                target=Path.Combine(r,"fixture-parent.exe");File.Copy(Process.GetCurrentProcess().MainModule.FileName,target);
                source=Path.Combine(c,"launcher_update_6.2_1.exe");File.WriteAllText(source,"new verified executable fixture");Pending(r,source,"6.2",Hash(source));
                string oldHash=Hash(target);
                using(var parent=Start(target,"--parent \""+r+"\" \""+helper+"\"")) {
                    Check(Until(delegate {return File.Exists(Path.Combine(r,"child-pid.txt"));}),"Native child binds exact parent and ACKs");
                    using(var child=Process.GetProcessById(Int32.Parse(File.ReadAllText(Path.Combine(r,"child-pid.txt"))))) {
                        // Retain real child handle before parent exits; PID reuse cannot become success.
                        IntPtr retained=child.Handle;
                        Check(Hash(target)==oldHash,"Live parent must not be replaced");
                        File.WriteAllText(Path.Combine(r,"exit-parent"),"exit");Check(parent.WaitForExit(5000)&&parent.ExitCode==0,"Fixture parent exits cleanly");
                        Check(child.WaitForExit(5000)&&child.ExitCode==0,"Native replacement completes after exact parent exits");
                    }
                }
                Check(File.ReadAllText(target)=="new verified executable fixture","Real worker atomically publishes replacement");
                Check(File.ReadAllText(Path.Combine(c,"launcher_current_version.txt"))=="6.2","Real worker commits version");
                r=Fixture("wrong-parent");Directory.CreateDirectory(Path.Combine(r,"config"));
                using(var bad=Start(helper,"replace \""+r+"\" \""+Path.Combine(r,"wrong.exe")+"\" "+Process.GetCurrentProcess().Id+" 1")) {
                    Check(bad.WaitForExit(5000)&&bad.ExitCode!=0,"Wrong creation identity fails without any replacement");
                    Check(Directory.GetFiles(Path.Combine(r,"config")).Length==0,"Wrong parent cannot ACK or write metadata");
                }
                // Interpreted launchers have an interpreter image OUTSIDE the
                // isolated installation. Only extraction permits that shape.
                r=Fixture("external-parent-image");Zip(Path.Combine(r,"payload.zip"),"全自動.ahk");
                string image=Process.GetCurrentProcess().MainModule.FileName;
                string identity=" \""+image+"\" "+Process.GetCurrentProcess().Id+" "+Process.GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc();
                using(var extractor=Start(helper,"extract \""+r+"\""+identity)) {
                    Check(extractor.WaitForExit(5000)&&extractor.ExitCode==0,"Extract binds external interpreter image without treating it as replacement target");
                    Check(File.Exists(Path.Combine(r,"payload","全自動.ahk")),"CLI extraction actually publishes fixture");
                }
                using(var mutex=new Mutex(false,LauncherMaintenance.MutexName(r,"Runtime"))) {
                    mutex.WaitOne();try {
                        using(var extractor=Start(helper,"extract \""+r+"\""+identity))Check(extractor.WaitForExit(5000)&&extractor.ExitCode!=0,"Runtime owner prevents native child writes");
                    }finally {mutex.ReleaseMutex();}
                }
            }
            Console.WriteLine("PASS launcher native maintenance: "+checks+" checks");return 0;
        }catch(Exception e) {Console.Error.WriteLine(e);return 1;}
    }
}
