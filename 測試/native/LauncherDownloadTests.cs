using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Diagnostics;
using System.Text;
using System.Threading;
using System.Security.Cryptography;
using System.Collections.Generic;

// Real loopback HTTP, real helper subprocess, no game or formal AHK entry point.
class LauncherDownloadTests
{
    static byte[] body=Encoding.ASCII.GetBytes(new string('a',16384)+new string('b',16384));
    static string sha;
    static int passed;
    static void Check(bool ok,string why) {if(!ok)throw new Exception(why);}
    static string Q(string x) {return "\""+x+"\"";}
    sealed class Server : IDisposable {
        TcpListener listener=new TcpListener(IPAddress.Loopback,0);
        Thread worker; volatile bool stopped;
        public string Url; public List<long> Offsets=new List<long>(); public int Requests;
        string mode;
        public Server(string mode) {
            this.mode=mode;listener.Start();Url="http://127.0.0.1:"+((IPEndPoint)listener.LocalEndpoint).Port+"/artifact";
            worker=new Thread(Serve);worker.IsBackground=true;worker.Start();
        }
        void Serve() {
            while(!stopped)try {
                using(var c=listener.AcceptTcpClient())using(var s=c.GetStream()) {
                    s.ReadTimeout=2000;var r=new StreamReader(s,Encoding.ASCII,false,1024,true);
                    string line;long offset=0;
                    while(!String.IsNullOrEmpty(line=r.ReadLine()))if(line.StartsWith("Range: bytes="))offset=Int64.Parse(line.Substring(13).TrimEnd('-'));
                    lock(Offsets)Offsets.Add(offset);int request=++Requests;
                    if(mode=="stall"){Thread.Sleep(1600);continue;}
                    if(mode=="unavailable") {
                        byte[] denied=Encoding.ASCII.GetBytes("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                        s.Write(denied,0,denied.Length);s.Flush();continue;
                    }
                    bool partial=offset>0&&mode!="ignore-range";
                    long start=partial?offset:0;
                    string header="HTTP/1.1 "+(partial?"206 Partial Content":"200 OK")+"\r\nConnection: close\r\nContent-Length: "+(body.Length-start)+"\r\n";
                    if(partial)header+="Content-Range: bytes "+(mode=="bad-range"?start+1:start)+"-"+(body.Length-1)+"/"+body.Length+"\r\n";
                    byte[] h=Encoding.ASCII.GetBytes(header+"\r\n");s.Write(h,0,h.Length);s.Flush();
                    bool disconnect=(mode=="resume"||mode=="ignore-range"||mode=="bad-range")&&request==1;
                    int end=disconnect?8192:body.Length;
                    if(mode=="truncated")end=8192;
                    for(int pos=(int)start;pos<end;pos+=1024) {
                        byte[] data=body;if(mode=="corrupt"){data=(byte[])body.Clone();data[0]=99;}
                        s.Write(data,pos,Math.Min(1024,end-pos));s.Flush();
                        if(mode=="slow"||mode=="trickle")Thread.Sleep(60);
                        if(mode=="slow-long")Thread.Sleep(3400);
                    }
                }
            }catch(Exception){if(stopped)return;}
        }
        public void Dispose(){stopped=true;listener.Stop();worker.Join(2000);}
    }
    static int Run(string helper,string root,string url,string dest,string expected,int total=8000,int idle=2000,int attempts=3) {
        var parent=Process.GetCurrentProcess();
        string args="download "+Q(root)+" "+Q(parent.MainModule.FileName)+" "+parent.Id+" "+parent.StartTime.ToFileTimeUtc()+" "+Q(url)+" "+Q(dest)+" "+expected+" "+total+" "+idle+" "+attempts;
        var info=new ProcessStartInfo(helper,args){UseShellExecute=false,CreateNoWindow=true,RedirectStandardError=true,RedirectStandardOutput=true};
        using(var p=Process.Start(info)) {
            if(!p.WaitForExit(total+6000)){p.Kill();throw new Exception("Helper exceeded bounded deadline");}
            string error=p.StandardError.ReadToEnd();
            if(p.ExitCode!=0)Console.WriteLine("EXPECTED/DIAGNOSTIC "+error.Trim());
            return p.ExitCode;
        }
    }
    static void Case(string baseRoot,string helper,string mode,bool success,int total=8000,int idle=2000) {
        string root=Path.Combine(baseRoot,mode);Directory.CreateDirectory(root);
        string dest=Path.Combine(root,"artifact.bin");File.WriteAllText(dest,"OLD VERIFIED FILE");
        using(var server=new Server(mode)) {
            var clock=Stopwatch.StartNew();int rc=Run(helper,root,server.Url,dest,sha,total,idle);
            Check((rc==0)==success,mode+": unexpected exit "+rc);
            Check(File.ReadAllText(dest)==(success?Encoding.ASCII.GetString(body):"OLD VERIFIED FILE"),mode+": destination changed incorrectly");
            if(mode=="resume"||mode=="ignore-range")Check(server.Offsets.Count>=2&&server.Offsets[1]==8192,mode+": did not request remaining bytes");
            if(mode=="slow")Check(clock.ElapsedMilliseconds>1500,"slow response fixture did not exercise progress");
            if(mode=="trickle")Check(clock.ElapsedMilliseconds<3000,"overall timeout ignored ongoing progress");
            if(mode=="stall")Check(clock.ElapsedMilliseconds<4000,"idle timeout unbounded");
            Check(File.Exists(dest+".download.status"),mode+": missing human-readable outcome");
        }
        Console.WriteLine("PASS "+mode);passed++;
    }
    static int Main(string[] args) {
        try {
            using(var h=SHA256.Create())sha=BitConverter.ToString(h.ComputeHash(body)).Replace("-","").ToLowerInvariant();
            // Reflection lets the red test report the missing behavior rather
            // than failing compilation before the routing contract exists.
            var sourceMethod=typeof(Wuthering.Native.LauncherMaintenance).GetMethod("DownloadSources");
            Check(sourceMethod!=null,"immutable GitHub artifact lacks official API primary routing");
            string raw="https://raw.githubusercontent.com/owner/repo/0123456789012345678901234567890123456789/folder/file.zip?release=test";
            string[] sources=(string[])sourceMethod.Invoke(null,new object[]{raw});
            Check(sources.Length==2&&sources[0]=="https://api.github.com/repos/owner/repo/contents/folder/file.zip?ref=0123456789012345678901234567890123456789"&&sources[1]==raw,"immutable content was not routed with exact commit and raw fallback");
            foreach(string unchanged in new[]{"https://raw.githubusercontent.com/owner/repo/main/file.zip","https://example.org/file.zip","http://127.0.0.1/file"}) {
                sources=(string[])sourceMethod.Invoke(null,new object[]{unchanged});
                Check(sources.Length==1&&sources[0]==unchanged,"unrelated or mutable URL rewritten");
            }
            if(args.Length==3&&args[2]=="long") {
                var timer=Stopwatch.StartNew();Case(args[0],args[1],"slow-long",true,130000,8000);
                Check(timer.ElapsedMilliseconds>100000,"long transfer did not cross original 100s cutoff");
                Console.WriteLine("PASS actual transfer exceeded 100 seconds without being aborted");return 0;
            }
            if(args[0]=="orphan-parent") {
                var parent=Process.GetCurrentProcess();string orphanDest=Path.Combine(args[2],"orphan.bin");
                string command="download "+Q(args[2])+" "+Q(parent.MainModule.FileName)+" "+parent.Id+" "+parent.StartTime.ToFileTimeUtc()+" "+Q(args[3])+" "+Q(orphanDest)+" "+sha+" 8000 2000 3";
                using(var child=Process.Start(new ProcessStartInfo(args[1],command){UseShellExecute=false,CreateNoWindow=true})) {
                    File.WriteAllText(Path.Combine(args[2],"child.txt"),child.Id.ToString());
                    var clock=Stopwatch.StartNew();
                    while(!File.Exists(orphanDest+".download.status")&&clock.ElapsedMilliseconds<3000)Thread.Sleep(20);
                    Check(File.Exists(orphanDest+".download.status"),"orphan fixture never started transfer");
                }
                return 0;
            }
            Case(args[0],args[1],"slow",true);
            Case(args[0],args[1],"resume",true);
            Case(args[0],args[1],"ignore-range",true);
            Case(args[0],args[1],"bad-range",false);
            Case(args[0],args[1],"corrupt",false);
            Case(args[0],args[1],"truncated",false);
            Case(args[0],args[1],"trickle",false,600,2000);
            Case(args[0],args[1],"stall",false,1800,300);
            // A subsequent invocation resumes a verified-hash-addressed partial.
            string root=Path.Combine(args[0],"across-invocations");Directory.CreateDirectory(root);
            string dest=Path.Combine(root,"file.bin");
            using(var server=new Server("resume")) {
                Check(Run(args[1],root,server.Url,dest,sha,5000,2000,1)!=0,"interrupted transfer unexpectedly succeeded");
                Check(!File.Exists(dest),"partial published as complete");
                Check(Run(args[1],root,server.Url,dest,sha)==0,"next invocation did not recover partial");
                Check(server.Offsets[1]==8192,"next invocation discarded partial progress");
                int requests=server.Requests;
                Check(Run(args[1],root,server.Url,dest,sha)==0&&server.Requests==requests,"verified destination downloaded again");
            }
            Console.WriteLine("PASS cross-invocation resume and verified destination reuse");passed++;
            root=Path.Combine(args[0],"orphan");Directory.CreateDirectory(root);
            using(var server=new Server("trickle")) {
                string command="orphan-parent "+Q(args[1])+" "+Q(root)+" "+Q(server.Url);
                using(var p=Process.Start(new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName,command){UseShellExecute=false,CreateNoWindow=true})) {
                    Check(p.WaitForExit(5000)&&p.ExitCode==0,"parent fixture failed");
                }
                string status=Path.Combine(root,"orphan.bin.download.status");var deadline=Stopwatch.StartNew();
                while(deadline.ElapsedMilliseconds<3000&&!File.ReadAllText(status).Contains("parent exited"))Thread.Sleep(50);
                Check(File.ReadAllText(status).Contains("parent exited"),"helper did not stop on exact parent exit");
                Check(!File.Exists(Path.Combine(root,"orphan.bin")),"orphan published an incomplete artifact");
            }
            Console.WriteLine("PASS exact parent exit cancels orphan without publishing");passed++;
            root=Path.Combine(args[0],"invalid");Directory.CreateDirectory(root);
            using(var server=new Server("normal")) {
                Check(Run(args[1],root,server.Url,Path.Combine(root,"invalid.bin"),"not-a-sha")!=0,"invalid SHA accepted");
                Check(Run(args[1],root,server.Url,Path.Combine(args[0],"outside.bin"),sha)!=0,"path escape accepted");
                Check(Run(args[1],root,"http://example.invalid/file",Path.Combine(root,"insecure.bin"),sha)!=0,"nonlocal HTTP accepted");
                Check(server.Requests==0,"rejected input performed network access");
            }
            Console.WriteLine("PASS invalid SHA, path escape and insecure URL rejected before network");passed++;
            // Exercise the actual core with two controlled sources: anonymous
            // API rate-limit fallback and cross-source partial continuation.
            foreach(string firstMode in new[]{"unavailable","resume"}) {
                root=Path.Combine(args[0],"fallback-"+firstMode);Directory.CreateDirectory(root);
                using(var first=new Server(firstMode))using(var second=new Server("normal")) {
                    var method=typeof(Wuthering.Native.LauncherMaintenance).GetMethod("DownloadOwned",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Static);
                    string output=Path.Combine(root,"result.bin");
                    method.Invoke(null,new object[]{new[]{first.Url,second.Url},output,Path.Combine(root,"partial.bin"),output+".status",sha,8000,2000,3,Process.GetCurrentProcess().Handle});
                    Check(File.ReadAllText(output)==Encoding.ASCII.GetString(body),"fallback did not verify and publish same artifact");
                    Check(first.Requests==1&&second.Requests==1,"source failure did not switch to fallback exactly once");
                    if(firstMode=="resume")Check(second.Offsets[0]==8192,"fallback discarded valid partial bytes");
                }
                Console.WriteLine("PASS fallback "+firstMode);passed++;
            }
            Console.WriteLine("download-regressions="+passed+" PASS");return 0;
        }catch(Exception e){Console.Error.WriteLine("FAIL "+e.Message);return 1;}
    }
}
