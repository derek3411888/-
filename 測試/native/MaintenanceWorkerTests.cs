using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Web.Script.Serialization;
using Wuthering.Native;

public static class MaintenanceWorkerTests
{
    static int count;
    static string root, worker;
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static void Check(bool ok, string name) { if (!ok) throw new Exception(name); ++count; Console.WriteLine("PASS " + name); }
    static void Reject(Action action, string name) { bool rejected = false; try { action(); } catch { rejected = true; } Check(rejected, name); }
    static string Session(string id) { string s = Path.Combine(root, "執行暫存", "遊戲更新", id); Directory.CreateDirectory(s); return s; }
    static string State { get { return Path.Combine(root, "config", "game-maintenance"); } }
    static Dictionary<string,object> Request(string id, long generation)
    {
        return new Dictionary<string,object> { {"schemaVersion",1}, {"requestId",id}, {"generation",generation},
            {"mode","install"}, {"launchEntry",Path.Combine(root,"missing.exe")}, {"createdAtUtc",DateTimeOffset.UtcNow.ToString("o")} };
    }
    static void Save(string session, Dictionary<string,object> request)
    {
        string target=Path.Combine(session,"request.json"), temp=target+".new";
        File.WriteAllText(temp,Json.Serialize(request),new UTF8Encoding(false));
        if(File.Exists(target)) File.Replace(temp,target,null); else File.Move(temp,target);
    }
    static bool Until(Func<bool> predicate, int milliseconds)
    {
        var watch=Stopwatch.StartNew(); do { if(predicate()) return true; Thread.Sleep(40); } while(watch.ElapsedMilliseconds<milliseconds); return false;
    }
    static string Q(string path) { return "\""+path+"\""; }
    static Process Start(string session, string parentStart)
    {
        string args="-RequestPath "+Q(Path.Combine(session,"request.json"))+" -OutputPath "+Q(Path.Combine(session,"snapshot.ini"))+
            " -StopPath "+Q(Path.Combine(session,"stop"))+" -StateDirectory "+Q(State)+" -ParentPid "+Process.GetCurrentProcess().Id+" -ParentStartUtc "+Q(parentStart);
        return Process.Start(new ProcessStartInfo(worker,args) {UseShellExecute=false,CreateNoWindow=true,RedirectStandardError=true,RedirectStandardOutput=true,WorkingDirectory=session});
    }
    static string Snapshot(string session) { try { return File.ReadAllText(Path.Combine(session,"snapshot.ini")); } catch(IOException) { return ""; } }
    static void Stop(Process process, string session)
    {
        File.WriteAllText(Path.Combine(session,"stop"),"stop");
        if(!process.WaitForExit(5000)) { process.Kill(); process.WaitForExit(); throw new Exception("native fixture failed to stop"); }
    }
    public static int Main(string[] args)
    {
        try {
            if(args.Length==3 && args[0]=="--official-notice-smoke") {
                root=Path.GetFullPath(args[1]);worker=Path.GetFullPath(args[2]);string liveSession=Session("official-notice");
                var liveRequest=Request("official-notice",1);liveRequest["mode"]="notice";Save(liveSession,liveRequest);
                using(var live=Start(liveSession,Process.GetCurrentProcess().StartTime.ToUniversalTime().ToString("o"))) {
                    try {
                        Check(Until(()=>Snapshot(liveSession).Contains("outcome="),30000),"live official HTTPS snapshot returned");
                        string data=Snapshot(liveSession);
                        foreach(string line in data.Split('\n')) if(line.StartsWith("outcome=")||line.StartsWith("checkedAtUtcMs=")||line.StartsWith("errorCode=")||line.StartsWith("detail=")||line.StartsWith("sourceUrl=")) Console.WriteLine(line);
                        Check(data.Contains("outcome=ok\n") && data.Contains("provider=unknown\n"),"official HTTPS succeeds without game discovery/startup");
                    } finally {Stop(live,liveSession);}
                    Check(live.ExitCode==0,"live notice worker clean stop");
                }
                return 0;
            }
            if(args.Length==3 && args[0]=="--parent") {
                root=Path.GetFullPath(args[1]);worker=Path.GetFullPath(args[2]);string parentSession=Session("parentexit");
                Save(parentSession,Request("parentexit",1));
                using(var child=Start(parentSession,Process.GetCurrentProcess().StartTime.ToUniversalTime().ToString("o"))) {
                    File.WriteAllText(Path.Combine(parentSession,"child-pid.txt"),child.Id.ToString());
                    if(!Until(()=>File.Exists(Path.Combine(parentSession,"exit-parent")),10000)) return 1;
                }
                return 0;
            }
            root=Path.GetFullPath(args[0]); worker=Path.GetFullPath(args[1]); Directory.CreateDirectory(root);
            var target=Attribute.GetCustomAttribute(System.Reflection.Assembly.LoadFile(worker),typeof(System.Runtime.Versioning.TargetFrameworkAttribute)) as System.Runtime.Versioning.TargetFrameworkAttribute;
            Check(target!=null && target.FrameworkName==".NETFramework,Version=v4.8","worker declares modern framework target for TLS defaults");
            string s=Session("protocol"), requestPath=Path.Combine(s,"request.json");
            Check(MaintenanceWorker.ValidatePaths(requestPath,Path.Combine(s,"snapshot.ini"),Path.Combine(s,"stop"),State)==s,"paths accepted");
            Reject(()=>MaintenanceWorker.ValidatePaths(requestPath,requestPath.ToUpperInvariant(),Path.Combine(s,"stop"),State),"aliases not distinct");
            Reject(()=>MaintenanceWorker.ValidatePaths(requestPath,Path.Combine(root,"escape.ini"),Path.Combine(s,"stop"),State),"output outside session rejected");
            Reject(()=>MaintenanceWorker.ValidatePaths(requestPath,Path.Combine(s,"snapshot.ini"),Path.Combine(s,"stop"),Path.Combine(root,"other","game-maintenance")),"state shape rejected");
            Reject(()=>MaintenanceWorker.Contained(Path.Combine(root+"-sibling","file"),root),"sibling prefix rejected");
            Save(s,Request("alpha",1)); var r=MaintenanceWorker.ReadRequest(requestPath,"");
            Check((string)r["requestId"]=="alpha","request read");
            Reject(()=>MaintenanceWorker.ReadRequest(requestPath,"foreign"),"foreign request rejected");
            var bad=Request("alpha",1); bad["mode"]="Observe"; Save(s,bad);
            Reject(()=>MaintenanceWorker.ReadRequest(requestPath,""),"mode casing rejected");
            bad=Request("alpha",1); bad["launchEntry"]="bad\npath"; Save(s,bad);
            Reject(()=>MaintenanceWorker.ReadRequest(requestPath,""),"request controls rejected");
            File.WriteAllText(requestPath,new string(' ',16385)); Reject(()=>MaintenanceWorker.ReadRequest(requestPath,""),"oversize request rejected");
            var snapshot=MaintenanceWorker.MakeSnapshot(Request("alpha",1),1,null,null,null,DateTimeOffset.UtcNow);
            ((Dictionary<string,object>)snapshot["notice"])["detail"]="繁體中文測試";
            string output=Path.Combine(s,"snapshot.ini"); MaintenanceWorker.WriteSnapshot(output,snapshot,s);
            string original=File.ReadAllText(output); Check(original.Contains("detail=繁體中文測試") && original.Contains("[observation]"),"unicode snapshot protocol");
            ((Dictionary<string,object>)snapshot["notice"])["detail"]="bad\n[meta]";
            Reject(()=>MaintenanceWorker.WriteSnapshot(output,snapshot,s),"snapshot injection rejected");
            Check(File.ReadAllText(output)==original && Directory.GetFiles(s,"*.tmp").Length==0,"invalid snapshot preserves old file");
            ((Dictionary<string,object>)snapshot["notice"])["detail"]="changed"; MaintenanceWorker.WriteSnapshot(output,snapshot,s);
            Check(File.ReadAllText(output).Contains("detail=changed"),"atomic snapshot replacement");
            string started=Process.GetCurrentProcess().StartTime.ToUniversalTime().ToString("o");
            using(var parent=MaintenanceWorker.ParentLease.Open(Process.GetCurrentProcess().Id,started)) Check(parent!=null && parent.Alive,"retained parent identity");
            using(var parent=MaintenanceWorker.ParentLease.Open(Process.GetCurrentProcess().Id,DateTime.UtcNow.AddDays(-1).ToString("o"))) Check(parent==null,"wrong parent creation rejected");
            Check(MaintenanceWorker.NoticeDue(300000,0,299999,"0","0",false),"notice periodic refresh");
            Check(!MaintenanceWorker.NoticeDue(59000,0,0,"2","1",true),"force refresh rate limit");
            string a=Session("first"),b=Session("second"); Save(a,Request("first",1)); Save(b,Request("second",1));
            using(var first=Start(a,started)) {
                try {
                    Check(Until(()=>Snapshot(a).Contains("generation=1"),5000),"native process writes first snapshot");
                    Check(!first.HasExited && Snapshot(a).Contains("provider=unknown"),"missing game is not success");
                    using(var duplicate=Start(b,started)) {
                        Check(duplicate.WaitForExit(5000) && duplicate.ExitCode==2,"duplicate worker fails closed");
                    }
                    Check(!first.HasExited && !File.Exists(Path.Combine(b,"snapshot.ini")),"duplicate did not replace owner");
                    string originalRoot=root;
                    try {
                        root=Path.Combine(originalRoot,"second-installation");string unrelated=Session("unrelated");Save(unrelated,Request("unrelated",1));
                        using(var other=Start(unrelated,started)) { try {Check(Until(()=>Snapshot(unrelated).Contains("requestId=unrelated"),4000) && !first.HasExited,"different installation is unrelated");} finally {Stop(other,unrelated);} }
                    } finally {root=originalRoot;}
                    Save(a,Request("first",2)); Check(Until(()=>Snapshot(a).Contains("generation=2"),4000),"new generation accepted");
                    Save(a,Request("other",3)); Thread.Sleep(400); Check(!first.HasExited && Snapshot(a).Contains("generation=2"),"foreign session ignored by live worker");
                    Save(a,Request("first",1)); Thread.Sleep(400); Check(!first.HasExited && Snapshot(a).Contains("generation=2"),"stale generation ignored by live worker");
                    File.WriteAllText(Path.Combine(a,"request.json"),"{");Thread.Sleep(400);Check(!first.HasExited,"half-written request does not terminate owner");
                    var incomplete=Request("first",3);incomplete.Remove("launchEntry");Save(a,incomplete);Thread.Sleep(400);
                    Check(!first.HasExited && Snapshot(a).Contains("generation=2"),"missing required request field cannot terminate owner");
                } finally { Stop(first,a); }
                Check(first.ExitCode==0,"stop signal exits cleanly: "+first.StandardError.ReadToEnd());
            }
            using(var next=Start(b,started)) { try { Check(Until(()=>Snapshot(b).Contains("requestId=second"),4000),"lock reusable after stop"); } finally {Stop(next,b);} }
            string c=Session("invalidparent");Save(c,Request("invalidparent",1));
            using(var dead=Start(c,DateTime.UtcNow.AddDays(-1).ToString("o"))) { Check(dead.WaitForExit(3000) && dead.ExitCode==0 && !File.Exists(Path.Combine(c,"snapshot.ini")),"invalid parent exits without snapshot"); }
            using(var invalid=Process.Start(new ProcessStartInfo(worker,"-ParentPid 1 -ParentPid 2") {UseShellExecute=false,CreateNoWindow=true,RedirectStandardError=true})) {
                Check(invalid.WaitForExit(3000)&&invalid.ExitCode==1,"malformed CLI rejected");
            }
            string parentCase=Session("parentexit");
            using(var parentFixture=Process.Start(new ProcessStartInfo(typeof(MaintenanceWorkerTests).Assembly.Location,"--parent "+Q(root)+" "+Q(worker)) {UseShellExecute=false,CreateNoWindow=true,RedirectStandardError=true})) {
                Process orphan=null;
                try {
                    Check(Until(()=>File.Exists(Path.Combine(parentCase,"child-pid.txt")) && Snapshot(parentCase).Contains("requestId=parentexit"),5000),"temporary parent owns real native worker");
                    orphan=Process.GetProcessById(Int32.Parse(File.ReadAllText(Path.Combine(parentCase,"child-pid.txt"))));
                    IntPtr retained=orphan.Handle;
                    File.WriteAllText(Path.Combine(parentCase,"exit-parent"),"exit");
                    Check(parentFixture.WaitForExit(3000)&&parentFixture.ExitCode==0,"temporary parent exits normally");
                    Check(orphan.WaitForExit(3000)&&orphan.ExitCode==0,"worker stops when exact retained parent exits");
                } finally {
                    if(!parentFixture.HasExited) {parentFixture.Kill();parentFixture.WaitForExit();}
                    if(orphan!=null) {if(!orphan.HasExited) {orphan.Kill();orphan.WaitForExit();}orphan.Dispose();}
                }
            }
            Console.WriteLine("PASS TOTAL="+count); return 0;
        } catch(Exception e) {Console.Error.WriteLine(e); return 1;}
    }
}
