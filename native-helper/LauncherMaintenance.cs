using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Runtime.InteropServices;
using System.Threading;
using System.Net;
using System.Globalization;

namespace Wuthering.Native
{
    // Small native updater: no shell, PowerShell runtime, or policy changes.
    public static class LauncherMaintenance
    {
        static bool Same(string a,string b) {return String.Equals(a,b,StringComparison.OrdinalIgnoreCase);}
        static string Safe(string path,string root)
        {
            string full=Path.GetFullPath(path),basePath=Path.GetFullPath(root).TrimEnd('\\');
            if(!Same(full,basePath)&&!full.StartsWith(basePath+"\\",StringComparison.OrdinalIgnoreCase)) throw new IOException("Path outside installation");
            if(full.IndexOf(':',2)>=0) throw new IOException("Alternate streams forbidden");
            for(string p=full;!String.IsNullOrEmpty(p);p=Path.GetDirectoryName(p)) {
                try {if((File.GetAttributes(p)&FileAttributes.ReparsePoint)!=0) throw new IOException("Reparse paths forbidden");}
                catch(FileNotFoundException) {} catch(DirectoryNotFoundException) {}
                if(Path.GetPathRoot(p)==p) break;
            }
            return full;
        }
        static string Root(string root)
        {
            if(!Path.IsPathRooted(root)||Path.GetFullPath(root).TrimEnd('\\')==Path.GetPathRoot(root).TrimEnd('\\')) throw new IOException("Installation root required");
            string full=Safe(root,root).TrimEnd('\\');
            if(!Directory.Exists(full)) throw new IOException("Installation missing");return full;
        }
        static void TreeSafe(string directory,string root)
        {
            Safe(directory,root);
            foreach(string entry in Directory.EnumerateFileSystemEntries(directory)) {
                Safe(entry,root);if(Directory.Exists(entry)) TreeSafe(entry,root);
            }
        }
        static string Hash(string path) {using(var f=File.OpenRead(path))using(var h=SHA256.Create())return BitConverter.ToString(h.ComputeHash(f)).Replace("-","").ToLowerInvariant();}
        static string SmallText(string path) {using(var f=File.OpenRead(path)) {if(f.Length>4096)throw new IOException("Metadata too large");using(var r=new StreamReader(f,new UTF8Encoding(false,true),true))return r.ReadToEnd().Trim();}}
        static void AtomicText(string path,string text)
        {
            string temp=path+"."+Guid.NewGuid().ToString("N")+".tmp";
            try {File.WriteAllText(temp,text,new UTF8Encoding(false));if(File.Exists(path))File.Replace(temp,path,null);else File.Move(temp,path);}
            finally {if(File.Exists(temp))File.Delete(temp);}
        }
        static string EntryPath(string name)
        {
            if(String.IsNullOrEmpty(name)||name.StartsWith("/")||name.StartsWith("\\")||name.IndexOf('\\')>=0)throw new IOException("Unsafe ZIP name");
            string[] parts=name.TrimEnd('/').Split('/');
            foreach(string part in parts) if(String.IsNullOrEmpty(part)||part=="."||part==".."||part.TrimEnd(' ','.')!=part||
                part.IndexOfAny(Path.GetInvalidFileNameChars())>=0||Regex.IsMatch(part,@"\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\z)",RegexOptions.IgnoreCase))
                throw new IOException("Unsafe ZIP component");
            return String.Join("\\",parts);
        }
        static readonly uint[] CrcTable=MakeCrcTable();
        static uint[] MakeCrcTable() {
            var result=new uint[256];for(uint i=0;i<256;i++) {uint c=i;for(int bit=0;bit<8;bit++)c=(c&1)!=0?0xEDB88320^(c>>1):c>>1;result[i]=c;}return result;
        }
        // Framework 4.8 ZipArchive does not check CRC on read. Parse the bounded
        // central directory once, then verify each uncompressed entry ourselves.
        // Release packages use ordinary single-disk ZIP (under 4 GiB), not ZIP64.
        static uint[] ReadCrcs(FileStream file) {
            if(file.Length<22||file.Length>=UInt32.MaxValue)throw new IOException("ZIP32 package required");
            int size=(int)Math.Min(65557,file.Length);byte[] tail=new byte[size];file.Position=file.Length-size;
            int read=0;while(read<size) {int n=file.Read(tail,read,size-read);if(n==0)throw new IOException("Truncated ZIP");read+=n;}
            int end=-1;for(int i=size-22;i>=0;i--)if(BitConverter.ToUInt32(tail,i)==0x06054b50&&i+22+BitConverter.ToUInt16(tail,i+20)==size) {end=i;break;}
            if(end<0||BitConverter.ToUInt16(tail,end+4)!=0||BitConverter.ToUInt16(tail,end+6)!=0)throw new IOException("Invalid or multi-disk ZIP");
            int count=BitConverter.ToUInt16(tail,end+10);uint length=BitConverter.ToUInt32(tail,end+12),offset=BitConverter.ToUInt32(tail,end+16);
            long endPosition=file.Length-size+end;
            if(count==65535||count!=BitConverter.ToUInt16(tail,end+8)||(long)offset+length!=endPosition)throw new IOException("Invalid or ZIP64 central directory");
            var result=new uint[count];file.Position=offset;
            using(var reader=new BinaryReader(file,Encoding.UTF8,true)) {
                for(int i=0;i<count;i++) {
                    byte[] header=reader.ReadBytes(46);
                    if(header.Length!=46||BitConverter.ToUInt32(header,0)!=0x02014b50||(BitConverter.ToUInt16(header,8)&1)!=0)throw new IOException("Invalid ZIP entry header");
                    if(BitConverter.ToUInt32(header,20)==UInt32.MaxValue||BitConverter.ToUInt32(header,24)==UInt32.MaxValue||BitConverter.ToUInt32(header,42)>=offset||BitConverter.ToUInt16(header,34)!=0)throw new IOException("Unsupported ZIP entry layout");
                    result[i]=BitConverter.ToUInt32(header,16);
                    file.Position+=BitConverter.ToUInt16(header,28)+BitConverter.ToUInt16(header,30)+BitConverter.ToUInt16(header,32);
                    if(file.Position>endPosition)throw new IOException("ZIP directory overflow");
                }
            }
            if(file.Position!=endPosition)throw new IOException("ZIP directory length mismatch");file.Position=0;return result;
        }
        public static void Extract(string root)
        {
            root=Root(root);string zip=Safe(Path.Combine(root,"payload.zip"),root),target=Safe(Path.Combine(root,"payload"),root);
            string work=Safe(Path.Combine(root,"執行暫存","更新"),root);Directory.CreateDirectory(work);
            RecoverPayload(root,work,target);
            string stage=Path.Combine(work,"unpack_"+Guid.NewGuid().ToString("N")),backup=Safe(Path.Combine(work,"payload_previous"),root),journal=Safe(Path.Combine(work,"payload_transaction.txt"),root);
            Directory.CreateDirectory(stage);bool moved=false,published=false;var clock=Stopwatch.StartNew();
            try {
                using(var f=new FileStream(zip,FileMode.Open,FileAccess.Read,FileShare.Read)) {
                uint[] crcs=ReadCrcs(f);
                using(var archive=new ZipArchive(f,ZipArchiveMode.Read)) {
                    var names=new HashSet<string>(StringComparer.OrdinalIgnoreCase);long total=0;
                    if(archive.Entries.Count==0||archive.Entries.Count>30000||archive.Entries.Count!=crcs.Length)throw new IOException("ZIP entry count exceeded or mismatch");
                    foreach(var e in archive.Entries) {
                        string rel=EntryPath(e.FullName);Safe(Path.Combine(stage,rel),stage);
                        if(!names.Add(rel)||((e.ExternalAttributes>>16)&0xF000)==0xA000)throw new IOException("Duplicate or symbolic ZIP entry");
                        if(e.Length<0||e.Length>8L*1024*1024*1024||total>8L*1024*1024*1024-e.Length)throw new IOException("ZIP size exceeded");total+=e.Length;
                    }
                    int entryIndex=0;
                    foreach(var e in archive.Entries) {
                        if(clock.ElapsedMilliseconds>120000)throw new IOException("Extraction deadline exceeded");
                        uint expectedCrc=crcs[entryIndex++];
                        string dest=Path.Combine(stage,EntryPath(e.FullName));
                        if(e.FullName.EndsWith("/")) {if(e.Length!=0||expectedCrc!=0)throw new IOException("Directory entry has data");Directory.CreateDirectory(dest);continue;}
                        Directory.CreateDirectory(Path.GetDirectoryName(dest));
                        using(var input=e.Open())using(var output=new FileStream(dest,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
                            byte[] buffer=new byte[65536];long count=0;int n;uint crc=UInt32.MaxValue;
                            while((n=input.Read(buffer,0,buffer.Length))>0) {
                                count+=n;if(count>e.Length||clock.ElapsedMilliseconds>120000)throw new IOException("Invalid entry length or deadline");
                                for(int j=0;j<n;j++)crc=CrcTable[(crc^buffer[j])&255]^(crc>>8);
                                output.Write(buffer,0,n);
                            }
                            if(count!=e.Length||(crc^UInt32.MaxValue)!=expectedCrc)throw new IOException("Truncated or CRC-corrupt ZIP entry");output.Flush(true);
                        }
                    }
                }
                }
                // Official packages have their entry point at the payload root.
                if(!File.Exists(Path.Combine(stage,"全自動.ahk")))throw new IOException("Payload entry point missing");
                AtomicText(journal,"publishing");
                if(Directory.Exists(target)) {TreeSafe(target,root);Directory.Move(target,backup);moved=true;}
                try {Directory.Move(stage,target);published=true;AtomicText(journal,"committed");}
                catch {RecoverPayload(root,work,target);throw;}
                if(moved) {try {TreeSafe(backup,root);Directory.Delete(backup,true);}catch { /* journal preserves recoverable backup */ }}
                if(!Directory.Exists(backup))File.Delete(journal);
            } finally {if(!published&&Directory.Exists(stage)) {TreeSafe(stage,root);Directory.Delete(stage,true);}}
        }
        static void RecoverPayload(string root,string work,string target)
        {
            string backup=Safe(Path.Combine(work,"payload_previous"),root),journal=Safe(Path.Combine(work,"payload_transaction.txt"),root);
            if(!File.Exists(journal)) {if(Directory.Exists(backup))throw new IOException("Unidentified payload backup preserved");return;}
            string phase=SmallText(journal);if(phase!="publishing"&&phase!="committed")throw new IOException("Unknown payload transaction preserved");
            if(Directory.Exists(backup)) {
                TreeSafe(backup,root);
                bool committed=phase=="committed"&&File.Exists(Path.Combine(target,"全自動.ahk"));
                if(committed)Directory.Delete(backup,true);
                else {
                    // Preserve any uncommitted new directory, even after a crash
                    // following the second move. Never delete it to make room.
                    if(Directory.Exists(target)) {TreeSafe(target,root);Directory.Move(target,Path.Combine(work,"payload_uncommitted_"+Guid.NewGuid().ToString("N")));}
                    Directory.Move(backup,target);
                }
            }
            File.Delete(journal);
        }
        public static string MutexName(string root,string purpose="Startup")
        {
            uint hash=2166136261;foreach(char c in Path.GetFullPath(root).TrimEnd('\\').ToLowerInvariant())hash=unchecked((hash^(uint)c)*16777619);
            return "Local\\WutheringInstall"+purpose+"_"+hash.ToString("X8");
        }
        public static void Replace(string root,string target)
        {
            root=Root(root);target=Safe(target,root);
            if(!Same(Path.GetDirectoryName(target),root)||!Same(Path.GetExtension(target),".exe"))throw new IOException("Launcher target must be in installation root");
            using(var mutex=new Mutex(false,MutexName(root))) {
                bool owned=false;try {
                    try {owned=mutex.WaitOne(0);}catch(AbandonedMutexException) {owned=true;}
                    if(!owned)throw new IOException("Another startup owns the installation");
                    ReplaceOwned(root,target);
                }finally {if(owned)mutex.ReleaseMutex();}
            }
        }
        static void ReplaceOwned(string root,string target)
        {
            string config=Safe(Path.Combine(root,"config"),root),marker=Safe(Path.Combine(config,"launcher_pending_update.tmp"),root),
                versionFile=Safe(Path.Combine(config,"launcher_pending_version.txt"),root),shaFile=Safe(Path.Combine(config,"launcher_pending_sha256.txt"),root),
                current=Safe(Path.Combine(config,"launcher_current_version.txt"),root);
            string source=Safe(SmallText(marker),config),version=SmallText(versionFile),sha=SmallText(shaFile).ToLowerInvariant();
            if(!Same(Path.GetDirectoryName(source),config)||!Regex.IsMatch(Path.GetFileName(source),@"\Alauncher_update_[0-9A-Za-z._-]+\.exe\z")||
                !Regex.IsMatch(version,@"\A[0-9A-Za-z._-]{1,80}\z")||!Regex.IsMatch(sha,@"\A[0-9a-f]{64}\z"))throw new IOException("Invalid pending metadata");
            if(Hash(source)!=sha)throw new IOException("Pending SHA256 mismatch");
            string candidate=Safe(target+"."+Guid.NewGuid().ToString("N")+".update",root),backup=Safe(target+".pre_update.bak",root);
            bool replaced=false;
            try {
                if(!File.Exists(target))throw new IOException("Current launcher missing; preserve rollback copy");
                File.Copy(source,candidate,false);if(Hash(candidate)!=sha)throw new IOException("Candidate SHA256 mismatch");
                File.Replace(candidate,target,backup);replaced=true;
                if(Hash(target)!=sha)throw new IOException("Installed SHA256 mismatch");
                AtomicText(current,version);
            }catch {
                if(replaced&&File.Exists(backup))File.Replace(backup,target,null);
                throw;
            }finally {if(File.Exists(candidate))File.Delete(candidate);}
            // Commit marker is removed first; a partial cleanup cannot replay the update.
            File.Delete(marker);foreach(string file in new[]{versionFile,shaFile,source})try {File.Delete(file);}catch {}
        }
        [DllImport("kernel32.dll",SetLastError=true)]static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
        [DllImport("kernel32.dll")]static extern bool GetProcessTimes(IntPtr h,out long created,out long exit,out long kernel,out long user);
        [DllImport("kernel32.dll")]static extern uint WaitForSingleObject(IntPtr h,uint milliseconds);
        [DllImport("kernel32.dll")]static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode)]static extern bool QueryFullProcessImageName(IntPtr h,uint flags,StringBuilder path,ref uint length);
        static IntPtr Parent(int pid,long expected,string target)
        {
            IntPtr h=OpenProcess(0x101000,false,pid);if(h==IntPtr.Zero)throw new IOException("Cannot bind launcher parent");
            long created,exit,kernel,user;uint len=32768;var path=new StringBuilder((int)len);
            if(!GetProcessTimes(h,out created,out exit,out kernel,out user)||created!=expected||WaitForSingleObject(h,0)!=258||
                !QueryFullProcessImageName(h,0,path,ref len)||!Same(Path.GetFullPath(path.ToString()),Path.GetFullPath(target))) {
                CloseHandle(h);throw new IOException("Launcher parent identity mismatch");
            }
            return h;
        }
        // Artifact downloads use a separate, progress-aware budget from small
        // manifest requests. The partial is addressed by the REQUIRED SHA256;
        // resumed bytes are never trusted until the whole file hashes correctly.
        const long DownloadMaxBytes=256L*1024*1024;
        static Uri DownloadUri(string url) {
            Uri uri;
            if(!Uri.TryCreate(url,UriKind.Absolute,out uri)||uri.UserInfo!=""||
                (uri.Scheme!="https"&&!(uri.Scheme=="http"&&uri.IsLoopback)))
                throw new IOException("HTTPS artifact URL required");
            return uri;
        }
        public static string[] DownloadSources(string url) {
            Uri uri=DownloadUri(url);
            // Only content pinned to a complete Git commit is interchangeable.
            // GitHub API raw avoids the raw CDN path measured slow on both PCs;
            // anonymous API failures/rate limits fall back to the original URL.
            var match=Regex.Match(uri.AbsolutePath,@"\A/([^/]+)/([^/]+)/([0-9a-fA-F]{40})/(.+)\z");
            if(uri.Scheme=="https"&&uri.IsDefaultPort&&Same(uri.Host,"raw.githubusercontent.com")&&match.Success)
                return new[]{"https://api.github.com/repos/"+match.Groups[1].Value+"/"+match.Groups[2].Value+"/contents/"+match.Groups[4].Value+"?ref="+match.Groups[3].Value,url};
            return new[]{url};
        }
        static void Download(string root,string url,string destination,string sha,int totalMs,int idleMs,int attempts,IntPtr parent)
        {
            if(!Regex.IsMatch(sha,@"\A[0-9a-f]{64}\z")||totalMs<1||totalMs>1800000||idleMs<1||idleMs>120000||attempts<1||attempts>3)
                throw new IOException("Invalid download hash or budgets");
            string[] sources=DownloadSources(url);
            destination=Safe(destination,root);
            string status=Safe(destination+".download.status",root);
            string cache=Safe(Path.Combine(root,"執行暫存","更新","downloads"),root);
            Directory.CreateDirectory(cache);Directory.CreateDirectory(Path.GetDirectoryName(destination));
            string part=Safe(Path.Combine(cache,sha+".part"),root);
            using(var mutex=new Mutex(false,MutexName(root,"Download_"+sha))) {
                bool owned=false;
                try {
                    try {owned=mutex.WaitOne(0);}catch(AbandonedMutexException){owned=true;}
                    if(!owned)throw new IOException("Same artifact download is already active");
                    DownloadOwned(sources,destination,part,status,sha,totalMs,idleMs,attempts,parent);
                }catch(Exception e){AtomicText(status,"FAILED "+e.Message.Replace('\r',' ').Replace('\n',' '));throw;}
                finally {if(owned)mutex.ReleaseMutex();}
            }
        }
        static void DownloadOwned(string[] sources,string destination,string part,string status,string sha,int totalMs,int idleMs,int attempts,IntPtr parent)
        {
            var clock=Stopwatch.StartNew();long lastActivity=0;int stopped=0;
            HttpWebRequest active=null;object gate=new object();
            // The helper must stop if its exact bound launcher exits. It never
            // acquires the startup/runtime mutex held by that launcher. Idle is
            // an operation-level stop, not another 3x60s retry cycle. Disconnected
            // or corrupt transfers may retry within the same total budget.
            using(var watchdog=new Timer(delegate(object unused) {
                int reason=WaitForSingleObject(parent,0)!=258?3:clock.ElapsedMilliseconds>=totalMs?2:
                    clock.ElapsedMilliseconds-Interlocked.Read(ref lastActivity)>=idleMs?1:0;
                if(reason==0)return;
                Interlocked.CompareExchange(ref stopped,reason,0);
                lock(gate)if(active!=null)active.Abort();
            },null,0,50)) {
                Action check=delegate {
                    if(stopped==3)throw new IOException("Launcher parent exited; partial preserved");
                    if(stopped==2||clock.ElapsedMilliseconds>=totalMs)throw new IOException("Download total deadline exceeded");
                    if(stopped==1)throw new IOException("Download idle timeout");
                };
                if(File.Exists(destination)&&new FileInfo(destination).Length<=DownloadMaxBytes&&Hash(destination)==sha) {
                    check();
                    AtomicText(status,"SUCCESS already verified");return;
                }
                ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
                for(int attempt=1;attempt<=attempts;attempt++) {
                    check();
                    try {
                        if(File.Exists(part)&&new FileInfo(part).Length>DownloadMaxBytes)throw new IOException("Artifact exceeds size limit");
                        bool complete=File.Exists(part)&&Hash(part)==sha;
                        if(!complete) {
                            long offset=File.Exists(part)?new FileInfo(part).Length:0;
                            Uri uri=DownloadUri(sources[Math.Min(attempt-1,sources.Length-1)]);HttpWebResponse response=null;
                            AtomicText(status,"CONNECTING source="+uri.Host+" attempt="+attempt+" resumeBytes="+offset);
                            try {
                                for(int redirect=0;;redirect++) {
                                    check();var request=(HttpWebRequest)WebRequest.Create(uri);
                                    request.AllowAutoRedirect=false;request.UserAgent="Wuthering-Launcher/3.0";
                                    request.Accept=Same(uri.Host,"api.github.com")?"application/vnd.github.raw+json":"*/*";
                                    request.Timeout=Math.Max(1,Math.Min(idleMs,(int)(totalMs-clock.ElapsedMilliseconds)));
                                    request.ReadWriteTimeout=request.Timeout;request.KeepAlive=false;
                                    request.AutomaticDecompression=DecompressionMethods.None;
                                    if(offset>0)request.AddRange(offset);
                                    lock(gate)active=request;
                                    try {response=(HttpWebResponse)request.GetResponse();}
                                    catch(WebException e) {
                                        if(e.Response!=null)e.Response.Close();
                                        // A complete but invalid stale partial can receive 416.
                                        if(e.Response is HttpWebResponse&&((HttpWebResponse)e.Response).StatusCode==HttpStatusCode.RequestedRangeNotSatisfiable)
                                            File.Delete(part);
                                        throw;
                                    }
                                    int code=(int)response.StatusCode;
                                    if(code!=301&&code!=302&&code!=303&&code!=307&&code!=308)break;
                                    string location=response.Headers["Location"];response.Close();response=null;
                                    if(redirect>=5||String.IsNullOrEmpty(location))throw new IOException("Invalid download redirect");
                                    uri=DownloadUri(new Uri(uri,location).AbsoluteUri);
                                }
                                long expected=response.ContentLength;
                                if(response.StatusCode==HttpStatusCode.PartialContent) {
                                    var range=Regex.Match(response.Headers["Content-Range"]??"",@"\Abytes (\d+)-(\d+)/(\d+)\z");
                                    long start,end,total;
                                    if(!range.Success||!Int64.TryParse(range.Groups[1].Value,out start)||!Int64.TryParse(range.Groups[2].Value,out end)||!Int64.TryParse(range.Groups[3].Value,out total)||
                                        start!=offset||end<start||end!=total-1||total>DownloadMaxBytes||expected!=end-start+1)
                                        throw new IOException("Invalid resumed Content-Range");
                                }else if(response.StatusCode==HttpStatusCode.OK)offset=0;
                                else throw new IOException("Unexpected HTTP status "+(int)response.StatusCode);
                                if(expected>DownloadMaxBytes-offset)throw new IOException("Artifact exceeds size limit");
                                Interlocked.Exchange(ref lastActivity,clock.ElapsedMilliseconds);
                                AtomicText(status,"DOWNLOADING attempt="+attempt+" bytes="+offset+" total="+(expected<0?-1:offset+expected));
                                long written=0,nextReport=clock.ElapsedMilliseconds+1000;
                                using(var output=new FileStream(part,offset>0?FileMode.Append:FileMode.Create,FileAccess.Write,FileShare.Read))
                                using(var input=response.GetResponseStream()) {
                                    byte[] buffer=new byte[65536];int n;
                                    while((n=input.Read(buffer,0,buffer.Length))>0) {
                                        check();if(offset+written+n>DownloadMaxBytes)throw new IOException("Artifact exceeds size limit");
                                        output.Write(buffer,0,n);written+=n;
                                        Interlocked.Exchange(ref lastActivity,clock.ElapsedMilliseconds);
                                        if(clock.ElapsedMilliseconds>=nextReport) {
                                            AtomicText(status,"DOWNLOADING attempt="+attempt+" bytes="+(offset+written)+" total="+(expected<0?-1:offset+expected));nextReport=clock.ElapsedMilliseconds+1000;
                                        }
                                    }
                                    output.Flush(true);
                                }
                                if(expected>=0&&written!=expected)throw new IOException("Interrupted download; partial preserved");
                            }finally {if(response!=null)response.Close();lock(gate)active=null;}
                        }
                        check();AtomicText(status,"VERIFYING SHA256");
                        if(Hash(part)!=sha){File.Delete(part);throw new IOException("Artifact SHA256 mismatch; invalid partial discarded");}
                        check();
                        if(File.Exists(destination))File.Replace(part,destination,null);else File.Move(part,destination);
                        AtomicText(status,"SUCCESS verified SHA256="+sha);return;
                    }catch(Exception) {
                        check();if(attempt==attempts)throw;
                        AtomicText(status,"RETRY partial preserved; attempt="+(attempt+1));
                        Thread.Sleep(Math.Min(250,Math.Max(1,totalMs-(int)clock.ElapsedMilliseconds)));
                        Interlocked.Exchange(ref lastActivity,clock.ElapsedMilliseconds);
                    }
                }
            }
        }
        public static int Main(string[] args)
        {
            string root=null;IntPtr parent=IntPtr.Zero;
            try {
                if(args.Length==11&&args[0]=="download") {
                    root=Root(args[1]);parent=Parent(Int32.Parse(args[3]),Int64.Parse(args[4]),args[2]);
                    Download(root,args[5],args[6],args[7],Int32.Parse(args[8],CultureInfo.InvariantCulture),Int32.Parse(args[9],CultureInfo.InvariantCulture),Int32.Parse(args[10],CultureInfo.InvariantCulture),parent);
                    Console.WriteLine("SUCCESS download");return 0;
                }
                if(args.Length!=5||(args[0]!="extract"&&args[0]!="replace"))throw new IOException("Invalid updater arguments");
                root=Root(args[1]);string target=args[0]=="replace"?Safe(args[2],root):Path.GetFullPath(args[2]);int pid=Int32.Parse(args[3]);long created=Int64.Parse(args[4]);
                parent=Parent(pid,created,target);
                if(args[0]=="extract") {
                    using(var mutex=new Mutex(false,MutexName(root,"Runtime"))) {
                        bool owned=false;try {
                            try {owned=mutex.WaitOne(0);}catch(AbandonedMutexException) {owned=true;}
                            if(!owned)throw new IOException("Runtime owns the installation");
                            Extract(root);
                        }finally {if(owned)mutex.ReleaseMutex();}
                    }
                }
                else {
                    string ready=Safe(Path.Combine(root,"config","launcher_replace_"+pid+"_"+created+".ready"),root);
                    AtomicText(ready,"READY");
                    try {
                        if(WaitForSingleObject(parent,60000)!=0)throw new IOException("Launcher exit deadline exceeded");
                        Replace(root,target);
                    }finally {if(File.Exists(ready))File.Delete(ready);}
                }
                Outcome(root,"SUCCESS "+args[0]);Console.WriteLine("SUCCESS "+args[0]);return 0;
            }catch(Exception e) {if(root!=null&&parent!=IntPtr.Zero)Outcome(root,"FAILED "+e.Message);Console.Error.WriteLine("FAILED "+e.Message);return 1;}
            finally {if(parent!=IntPtr.Zero)CloseHandle(parent);}
        }
        static void Outcome(string root,string message) {
            try {
                string file=Safe(Path.Combine(root,"config","launcher_update_outcome.log"),root);
                Directory.CreateDirectory(Path.GetDirectoryName(file));
                File.AppendAllText(file,DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")+" "+message.Replace('\r',' ').Replace('\n',' ')+Environment.NewLine,new UTF8Encoding(false));
            }catch { /* exit status remains authoritative */ }
        }
    }
}
