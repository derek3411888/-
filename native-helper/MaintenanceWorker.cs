using System;
using System.IO;
using System.Text;
using System.Net;
using System.Diagnostics;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using System.Collections;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace Wuthering.Native
{
    // Implements the maintenance protocol directly. No PowerShell engine or script execution.
    public static class MaintenanceWorker
    {
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer {MaxJsonLength=65536,RecursionLimit=32};
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false,true);
        static readonly DateTimeOffset Epoch = new DateTimeOffset(1970,1,1,0,0,0,TimeSpan.Zero);
        static readonly string[] Sections = {"meta","notice","install","observation"};
        static readonly string[] Fields = {
            "schemaVersion,marker,requestId,sequence,generation,observedAtUtcMs",
            "outcome,present,eventId,revision,gameVersion,startsAtUtcMs,expectedOpenAtUtcMs,checkedAtUtcMs,sourceUrl,sourceState,freshForRelease,errorCode,detail,upcomingEventId,upcomingGameVersion,upcomingStartsAtUtcMs,upcomingExpectedOpenAtUtcMs,upcomingSourceUrl",
            "provider,appId,gameRoot,launcherPath,fingerprint,updateAdapterReady,evidence,checkedAtUtcMs",
            "phase,bytesDone,bytesTotal,progressPercent,lastProgressAtUtcMs,detail,errorCode,gamePid,gamePath"};
        static object Get(Dictionary<string,object> d,string key,object fallback=null) {object v;return d!=null&&d.TryGetValue(key,out v)?v:fallback;}
        static string Text(object v) {return Convert.ToString(v,CultureInfo.InvariantCulture)??"";}
        static long Milliseconds(DateTimeOffset d) {return (d.UtcTicks-Epoch.UtcTicks)/TimeSpan.TicksPerMillisecond;}
        static DateTimeOffset Date(object value) {return DateTimeOffset.Parse(Text(value),CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind);}
        static bool EqualPath(string a,string b) {return String.Equals(a,b,StringComparison.OrdinalIgnoreCase);}

        public static string Contained(string path,string root)
        {
            if(!Path.IsPathRooted(path)||!Path.IsPathRooted(root)) throw new InvalidDataException("Absolute maintenance paths required");
            string full=Path.GetFullPath(path),basePath=Path.GetFullPath(root).TrimEnd('\\');
            if(!full.StartsWith(basePath+"\\",StringComparison.OrdinalIgnoreCase)||full.IndexOf(':',2)>=0)
                throw new InvalidDataException("Maintenance path outside allowed root");
            for(string scan=full;!String.IsNullOrEmpty(scan);scan=Path.GetDirectoryName(scan)) {
                try {if((File.GetAttributes(scan)&FileAttributes.ReparsePoint)!=0) throw new InvalidDataException("Reparse paths forbidden");}
                catch(FileNotFoundException) {} catch(DirectoryNotFoundException) {}
                if(Path.GetPathRoot(scan)==scan) break;
            }
            return full;
        }
        public static string ValidatePaths(string request,string output,string stop,string state)
        {
            state=Path.GetFullPath(state).TrimEnd('\\');
            string config=Path.GetDirectoryName(state),program=Path.GetDirectoryName(config);
            if(!EqualPath(Path.GetFileName(state),"game-maintenance")||!EqualPath(Path.GetFileName(config),"config"))
                throw new InvalidDataException("Invalid maintenance state directory");
            Contained(state,program);
            string session=Path.GetDirectoryName(Path.GetFullPath(request));
            if(!EqualPath(Path.GetDirectoryName(session),Path.Combine(program,"執行暫存","遊戲更新")))
                throw new InvalidDataException("Invalid worker session directory");
            var distinct=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach(string item in new[]{request,output,stop}) {
                string safe=Contained(item,session);
                if(!EqualPath(Path.GetDirectoryName(safe),session)||!distinct.Add(safe)) throw new InvalidDataException("Invalid worker file set");
            }
            return session;
        }
        public static Dictionary<string,object> ReadRequest(string path,string expectedId)
        {
            byte[] bytes;
            using(var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
                if(input.Length>16384) throw new InvalidDataException("Request too large");
                using(var memory=new MemoryStream()) {
                    byte[] buffer=new byte[4096]; int n;
                    while((n=input.Read(buffer,0,buffer.Length))>0) {if(memory.Length+n>16384) throw new InvalidDataException("Request too large");memory.Write(buffer,0,n);}
                    bytes=memory.ToArray();
                }
            }
            var r=Json.DeserializeObject(Utf8.GetString(bytes).TrimStart('\uFEFF')) as Dictionary<string,object>;
            if(r==null) throw new InvalidDataException("Request must be an object");
            foreach(string required in new[]{"schemaVersion","requestId","generation","mode","launchEntry","createdAtUtc"})
                if(!r.ContainsKey(required)||r[required]==null) throw new InvalidDataException("Missing request field");
            foreach(string textField in new[]{"requestId","mode","launchEntry","createdAtUtc"})
                if(!(r[textField] is string)) throw new InvalidDataException("Invalid request field type");
            string id=Text(Get(r,"requestId")),generation=Text(Get(r,"generation")),mode=Text(Get(r,"mode")),entry=Text(Get(r,"launchEntry"));
            if(Text(Get(r,"schemaVersion"))!="1"||!Regex.IsMatch(id,"\\A[A-Za-z0-9_-]{1,128}\\z")||
                (!String.IsNullOrEmpty(expectedId)&&id!=expectedId)||!Regex.IsMatch(generation,"\\A[0-9]{1,12}\\z")||
                (mode!="notice"&&mode!="install"&&mode!="observe")||entry.Length>2048||Regex.IsMatch(entry,"[\\x00-\\x1F]"))
                throw new InvalidDataException("Invalid maintenance request");
            Date(Get(r,"createdAtUtc"));
            return r;
        }
        public static void WriteSnapshot(string path,Dictionary<string,object> snapshot,string root)
        {
            string safe=Contained(path,root);var lines=new StringBuilder();
            foreach(string section in snapshot.Keys) if(Array.IndexOf(Sections,section)<0) throw new InvalidDataException("Unknown snapshot section");
            for(int i=0;i<Sections.Length;i++) {
                var values=Get(snapshot,Sections[i]) as Dictionary<string,object>;
                if(values==null) throw new InvalidDataException("Missing snapshot section");
                string[] allowed=Fields[i].Split(',');
                foreach(string key in values.Keys) if(Array.IndexOf(allowed,key)<0) throw new InvalidDataException("Unknown snapshot field");
                lines.Append('[').Append(Sections[i]).Append("]\n");
                foreach(string key in allowed) {
                    string value=Text(Get(values,key));
                    if(value.Length>2048||Regex.IsMatch(value,"[\\x00-\\x1F]")) throw new InvalidDataException("Unsafe snapshot field");
                    lines.Append(key).Append('=').Append(value).Append('\n');
                }
            }
            byte[] bytes=Utf8.GetBytes(lines.ToString());if(bytes.Length>65536) throw new InvalidDataException("Snapshot too large");
            string temporary=safe+"."+Guid.NewGuid().ToString("N")+".tmp";
            try {
                using(var stream=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {stream.Write(bytes,0,bytes.Length);stream.Flush(true);}
                if(File.Exists(safe)) File.Replace(temporary,safe,null); else File.Move(temporary,safe);
            } finally {if(File.Exists(temporary)) File.Delete(temporary);}
        }
        public sealed class ParentLease : IDisposable
        {
            IntPtr handle;
            ParentLease(IntPtr h) {handle=h;}
            public bool Alive {get {return handle!=IntPtr.Zero&&WaitForSingleObject(handle,0)==258;}}
            public static ParentLease Open(int pid,string started)
            {
                if(pid<=0) return null;
                IntPtr h=OpenProcess(0x101000,false,pid);if(h==IntPtr.Zero) return null;
                try {
                    long created,exit,kernel,user;
                    if(!GetProcessTimes(h,out created,out exit,out kernel,out user)||WaitForSingleObject(h,0)!=258) return null;
                    var actual=new DateTimeOffset(DateTime.FromFileTimeUtc(created));long expected;
                    bool matches=Regex.IsMatch(started??"","\\A[0-9]{13}\\z")&&Int64.TryParse(started,out expected)
                        ?Math.Abs(Milliseconds(actual)-expected)<=1:actual.UtcTicks==Date(started).UtcTicks;
                    if(!matches) return null;
                    var lease=new ParentLease(h);h=IntPtr.Zero;return lease;
                } catch(FormatException) {return null;}
                finally {if(h!=IntPtr.Zero) CloseHandle(h);}
            }
            public void Dispose() {if(handle!=IntPtr.Zero) {CloseHandle(handle);handle=IntPtr.Zero;}}
        }
        [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr handle,out long created,out long exit,out long kernel,out long user);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr handle,uint flags,StringBuilder path,ref uint length);

        static Dictionary<string,object> ObserveGame(Dictionary<string,object> install)
        {
            if(install==null||String.IsNullOrEmpty(Text(Get(install,"gameRoot")))) return null;
            string expected;try {expected=InstallDiscovery.RealPath(Path.Combine(Text(install["gameRoot"]),"Client","Binaries","Win64","Client-Win64-Shipping.exe"));} catch {return null;}
            int found=0,pid=0;
            foreach(var process in Process.GetProcessesByName("Client-Win64-Shipping")) using(process) {
                IntPtr h=IntPtr.Zero;
                try {
                    h=OpenProcess(0x101000,false,process.Id);if(h==IntPtr.Zero) continue;
                    uint length=32768;var path=new StringBuilder((int)length);
                    if(QueryFullProcessImageName(h,0,path,ref length)&&EqualPath(InstallDiscovery.RealPath(path.ToString()),expected)&&WaitForSingleObject(h,0)==258) {++found;pid=process.Id;}
                } catch {} finally {if(h!=IntPtr.Zero) CloseHandle(h);}
            }
            return found==1?new Dictionary<string,object>{{"phase","game_running"},{"gamePid",pid},{"gamePath",expected}}:null;
        }
        static string FetchHttp(string url,Func<bool> alive,int timeoutMilliseconds)
        {
            if(!MaintenanceNotice.IsAllowedUrl(url)) throw new InvalidDataException("Untrusted official URL");
            if(timeoutMilliseconds<1||timeoutMilliseconds>10000) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            var request=(HttpWebRequest)WebRequest.Create(url);request.AllowAutoRedirect=false;request.Timeout=timeoutMilliseconds;request.ReadWriteTimeout=timeoutMilliseconds;
            var timer=Stopwatch.StartNew();HttpWebResponse response=null;Stream stream=null;
            Action guard=delegate {if(!alive()||timer.ElapsedMilliseconds>=timeoutMilliseconds) throw new IOException("Worker HTTP cancelled or timed out");};
            try {
                guard();var task=request.GetResponseAsync();while(!task.IsCompleted) {guard();Thread.Sleep(50);}guard();response=(HttpWebResponse)task.GetAwaiter().GetResult();
                if(response.StatusCode!=HttpStatusCode.OK||response.ContentLength>2097152) throw new InvalidDataException("Invalid official response");
                stream=response.GetResponseStream();byte[] buffer=new byte[16384];
                using(var memory=new MemoryStream()) {
                    while(true) {
                        guard();var read=stream.ReadAsync(buffer,0,buffer.Length);while(!read.IsCompleted) {guard();Thread.Sleep(50);}guard();int count=read.GetAwaiter().GetResult();if(count==0) break;
                        if(memory.Length+count>2097152) throw new InvalidDataException("Official response exceeded budget");memory.Write(buffer,0,count);
                    }
                    return Utf8.GetString(memory.ToArray());
                }
            } finally {request.Abort();if(stream!=null) stream.Dispose();if(response!=null) response.Dispose();}
        }
        public static Dictionary<string,object> MakeSnapshot(Dictionary<string,object> request,long sequence,Dictionary<string,object> notice,
            Dictionary<string,object> install,Dictionary<string,object> observation,DateTimeOffset now)
        {
            var record=Get(notice,"notice") as Dictionary<string,object>;
            var n=new Dictionary<string,object>{{"outcome",Get(notice,"outcome","pending")},{"present",record==null?0:1},{"checkedAtUtcMs",""},
                {"errorCode",Get(notice,"errorCode","")},{"detail",Get(notice,"errorDetail","")}};
            string check=Text(Get(notice,"checkedAt"));if(check!="") n["checkedAtUtcMs"]=Milliseconds(Date(check));
            if(record!=null) {
                foreach(string key in new[]{"eventId","gameVersion","sourceUrl","sourceState"}) n[key]=Get(record,key);
                n["revision"]=Get(record,"revisionHash");n["startsAtUtcMs"]=Milliseconds(Date(Get(record,"startsAtUtc")));n["expectedOpenAtUtcMs"]=Milliseconds(Date(Get(record,"expectedOpenAtUtc")));
                double age=check==""?Double.PositiveInfinity:(now-Date(check)).TotalMilliseconds;
                n["freshForRelease"]=Text(Get(notice,"outcome"))=="ok"&&age>=-5000&&age<=900000?1:0;
            }
            var upcoming=Get(notice,"upcomingNotice") as Dictionary<string,object>;
            if(upcoming!=null) {
                n["upcomingEventId"]=Get(upcoming,"eventId");n["upcomingGameVersion"]=Get(upcoming,"gameVersion");n["upcomingSourceUrl"]=Get(upcoming,"sourceUrl");
                n["upcomingStartsAtUtcMs"]=Milliseconds(Date(Get(upcoming,"startsAtUtc")));n["upcomingExpectedOpenAtUtcMs"]=Milliseconds(Date(Get(upcoming,"expectedOpenAtUtc")));
            }
            var inst=new Dictionary<string,object>{{"provider","unknown"},{"updateAdapterReady",0}};
            if(install!=null) {
                foreach(string key in new[]{"provider","appId","gameRoot","launcherPath","fingerprint"}) inst[key]=Get(install,key);
                var evidence=Get(install,"evidence") as IEnumerable;var entries=new List<string>();if(evidence!=null) foreach(object item in evidence) entries.Add(Text(item));
                inst["evidence"]=String.Join(";",entries);inst["checkedAtUtcMs"]=Milliseconds(Date(Get(install,"checkedAtUtc")));
            }
            var obs=new Dictionary<string,object>{{"phase","unknown"}};
            if(observation!=null) {
                foreach(string key in new[]{"phase","bytesDone","bytesTotal","progressPercent","detail","errorCode","gamePid","gamePath"}) obs[key]=Get(observation,key);
                if(Text(Get(observation,"lastProgressAtUtc"))!="") obs["lastProgressAtUtcMs"]=Milliseconds(Date(observation["lastProgressAtUtc"]));
            }
            return new Dictionary<string,object>{{"meta",new Dictionary<string,object>{{"schemaVersion",1},{"marker","WUTHERING_GAME_MAINTENANCE_WORKER_V1"},
                {"requestId",request["requestId"]},{"sequence",sequence},{"generation",request["generation"]},{"observedAtUtcMs",Milliseconds(now)}}},
                {"notice",n},{"install",inst},{"observation",obs}};
        }
        public static bool NoticeDue(long elapsed,long lastNotice,long lastForce,string forceId,string lastForceId,bool deadlineDue)
        {return elapsed-lastNotice>=300000||((deadlineDue||forceId!=lastForceId)&&elapsed-lastForce>=60000);}

        public static int Run(string requestPath,string outputPath,string stopPath,string stateDirectory,int parentPid,string parentStarted)
        {
            string session=ValidatePaths(requestPath,outputPath,stopPath,stateDirectory);
            using(var parent=ParentLease.Open(parentPid,parentStarted)) {
                if(parent==null) return 0;
                Func<bool> alive=()=>parent.Alive&&!File.Exists(stopPath);
                if(!alive()) return 0;
                foreach(string name in new[]{"TEMP","TMP","TMPDIR"}) Environment.SetEnvironmentVariable(name,session,EnvironmentVariableTarget.Process);
                Directory.CreateDirectory(stateDirectory);FileStream ownership=null;
                string lockPath=Contained(Path.Combine(stateDirectory,"worker.lock"),stateDirectory);
                for(int attempt=0;attempt<8&&ownership==null;++attempt) {
                    if(!alive()) return 0;
                    try {ownership=new FileStream(lockPath,FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);}
                    catch(IOException) {Thread.Sleep(250);}
                }
                if(ownership==null) return 2;
                using(ownership) {
                    try {using(var self=Process.GetCurrentProcess()) self.PriorityClass=ProcessPriorityClass.BelowNormal;} catch {}
                    var request=ReadRequest(requestPath,"");string requestId=Text(request["requestId"]),entry="",lastForceId="0",previousPayload="";
                    long generation=-1,lastObserve=-5000,lastNotice=-300000,lastWrite=-30000,lastForce=-60000,sequence=0;
                    Dictionary<string,object> notice=null,install=null,observation=null,game=null;
                    var timer=Stopwatch.StartNew();
                    while(alive()) {
                        try {var next=ReadRequest(requestPath,requestId);if(Convert.ToInt64(next["generation"])>=Convert.ToInt64(request["generation"])) request=next;} catch(IOException) {} catch(InvalidDataException) {} catch(ArgumentException) {} catch(FormatException) {} catch(InvalidOperationException) {}
                        if(entry!=Text(request["launchEntry"])||generation!=Convert.ToInt64(request["generation"])) {
                            bool entryChanged=entry!=Text(request["launchEntry"]);entry=Text(request["launchEntry"]);generation=Convert.ToInt64(request["generation"]);
                            try {install=InstallDiscovery.Resolve(entry);} catch {install=null;}
                            if(entryChanged) {observation=null;game=null;lastObserve=-5000;}
                        }
                        var now=DateTimeOffset.UtcNow;var record=Get(notice,"notice") as Dictionary<string,object>;
                        long deadline=record==null?0:Milliseconds(Date(Get(record,"expectedOpenAtUtc")));
                        long checkedMs=Text(Get(notice,"checkedAt"))==""?0:Milliseconds(Date(Get(notice,"checkedAt")));
                        string forceId=Text(Get(request,"refreshRequestId","0"));bool force=(deadline>0&&Milliseconds(now)>=deadline&&checkedMs<deadline)||forceId!=lastForceId;
                        if(Text(request["mode"])!="install"&&NoticeDue(timer.ElapsedMilliseconds,lastNotice,lastForce,forceId,lastForceId,force)) {
                            lastNotice=timer.ElapsedMilliseconds;if(force) lastForce=lastNotice;lastForceId=forceId;
                            var previous=record;string pinned=Text(Get(request,"pinnedEventId"));if(previous==null&&pinned!="") previous=MaintenanceNotice.FindCached(stateDirectory,pinned);
                            notice=MaintenanceNotice.FetchBounded(stateDirectory,now,force,previous,(url,remaining)=>FetchHttp(url,alive,remaining));
                            if(!alive()) break;
                        }
                        if(timer.ElapsedMilliseconds-lastObserve>=5000) {
                            lastObserve=timer.ElapsedMilliseconds;
                            observation=Text(Get(install,"provider"))=="steam"?InstallDiscovery.ObserveSteam(install,observation,now):null;
                            game=Text(request["mode"])=="observe"?ObserveGame(install):null;
                        }
                        var snapshot=MakeSnapshot(request,sequence+1,notice,install,observation,DateTimeOffset.UtcNow);
                        if(Text(request["mode"])=="observe"&&game!=null) foreach(string key in game.Keys) ((Dictionary<string,object>)snapshot["observation"])[key]=game[key];
                        string payload=Json.Serialize(new[]{snapshot["notice"],snapshot["install"],snapshot["observation"],request["generation"]});
                        if(payload!=previousPayload||timer.ElapsedMilliseconds-lastWrite>=30000) {
                            if(!alive()) break;WriteSnapshot(outputPath,snapshot,session);++sequence;previousPayload=payload;lastWrite=timer.ElapsedMilliseconds;
                        }
                        Thread.Sleep(250);
                    }
                }
            }
            return 0;
        }
        public static int Main(string[] args)
        {
            try {
                var values=new Dictionary<string,string>(StringComparer.Ordinal);string[] allowed={"-RequestPath","-OutputPath","-StopPath","-StateDirectory","-ParentPid","-ParentStartUtc"};
                if(args.Length!=12) throw new ArgumentException("Expected six named arguments");
                for(int i=0;i<args.Length;i+=2) {if(Array.IndexOf(allowed,args[i])<0||values.ContainsKey(args[i])) throw new ArgumentException("Invalid worker arguments");values.Add(args[i],args[i+1]);}
                return Run(values["-RequestPath"],values["-OutputPath"],values["-StopPath"],values["-StateDirectory"],Int32.Parse(values["-ParentPid"],CultureInfo.InvariantCulture),values["-ParentStartUtc"]);
            } catch(Exception e) {Console.Error.WriteLine("Maintenance worker failed: "+e.GetType().Name+": "+e.Message);return 1;}
        }
    }
}
