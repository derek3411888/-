using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Wuthering.Native
{
    // Native-only bootstrap operations used by the payload. Every write is
    // contained by an explicit installation root, and the CLI holds the exact
    // parent process handle until the bounded operation completes.
    public static class BootstrapAssets
    {
        const long MaxDownloadBytes = 1024L * 1024L * 1024L;
        const long MaxEntryBytes = 2L * 1024L * 1024L * 1024L;
        const long MaxExpandedBytes = 4L * 1024L * 1024L * 1024L;
        const int MaxArchiveEntries = 20000;
        const int DownloadDeadlineMilliseconds = 20 * 60 * 1000;
        const int ExtractDeadlineMilliseconds = 5 * 60 * 1000;
        const int HashDeadlineMilliseconds = 2 * 60 * 1000;
        const int InstallDeadlineMilliseconds = 2 * 60 * 1000;
        const uint WaitObject0 = 0;
        const uint WaitTimeout = 258;

        sealed class CentralRecord
        {
            public uint Crc;
            public uint CompressedLength;
            public uint Length;
        }

        sealed class EntryPlan
        {
            public ZipArchiveEntry Entry;
            public string RelativePath;
            public bool IsDirectory;
            public uint Crc;
        }

        sealed class ParentLease : IDisposable
        {
            IntPtr handle;

            [DllImport("kernel32.dll", SetLastError = true)]
            static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, int processId);
            [DllImport("kernel32.dll", SetLastError = true)]
            static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
            [DllImport("kernel32.dll", SetLastError = true)]
            static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref uint length);
            [DllImport("kernel32.dll")]
            static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
            [DllImport("kernel32.dll")]
            static extern bool CloseHandle(IntPtr handle);

            public ParentLease(int processId, long expectedCreation, string expectedImage)
            {
                if (processId <= 0 || expectedCreation <= 0 || String.IsNullOrWhiteSpace(expectedImage))
                    throw new IOException("Invalid parent identity");
                string expected = Path.GetFullPath(expectedImage);
                handle = OpenProcess(0x00100000 | 0x1000, false, processId);
                if (handle == IntPtr.Zero) throw new IOException("Cannot bind bootstrap parent");
                try
                {
                    long creation;
                    long exit;
                    long kernel;
                    long user;
                    uint length = 32768;
                    StringBuilder actual = new StringBuilder((int)length);
                    if (!GetProcessTimes(handle, out creation, out exit, out kernel, out user) ||
                        creation != expectedCreation || WaitForSingleObject(handle, 0) != WaitTimeout ||
                        !QueryFullProcessImageName(handle, 0, actual, ref length) ||
                        !Same(Path.GetFullPath(actual.ToString()), expected))
                        throw new IOException("Bootstrap parent identity mismatch");
                }
                catch
                {
                    CloseHandle(handle);
                    handle = IntPtr.Zero;
                    throw;
                }
            }

            public bool IsCancelled()
            {
                return handle == IntPtr.Zero || WaitForSingleObject(handle, 0) != WaitTimeout;
            }

            public void Dispose()
            {
                if (handle == IntPtr.Zero) return;
                CloseHandle(handle);
                handle = IntPtr.Zero;
            }
        }

        static readonly uint[] CrcTable = CreateCrcTable();

        static bool Same(string first, string second)
        {
            return String.Equals(first, second, StringComparison.OrdinalIgnoreCase);
        }

        static string NormalizeRoot(string root)
        {
            if (String.IsNullOrWhiteSpace(root) || !Path.IsPathRooted(root))
                throw new IOException("Application root must be absolute");
            string full = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string volume = Path.GetPathRoot(full).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (Same(full, volume)) throw new IOException("Application root cannot be a volume root");
            if (!Directory.Exists(full)) throw new IOException("Application root is missing");
            EnsureNoReparse(full, full);
            return full;
        }

        static string SafePath(string root, string path)
        {
            if (String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path))
                throw new IOException("Bootstrap path must be absolute");
            string full = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string basePath = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (!Same(full, basePath) && !full.StartsWith(basePath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Path outside application root");
            if (full.IndexOf(':', 2) >= 0) throw new IOException("Alternate data streams are forbidden");
            EnsureNoReparse(full, basePath);
            return full;
        }

        static void EnsureNoReparse(string path, string stopAt)
        {
            string current = path;
            string stop = Path.GetFullPath(stopAt).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            while (!String.IsNullOrEmpty(current))
            {
                try
                {
                    if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                        throw new IOException("Reparse paths are forbidden");
                }
                catch (FileNotFoundException) { }
                catch (DirectoryNotFoundException) { }
                if (Same(current.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), stop)) break;
                string parent = Path.GetDirectoryName(current);
                if (String.IsNullOrEmpty(parent) || Same(parent, current)) break;
                current = parent;
            }
        }

        static void EnsureParentDirectory(string root, string path)
        {
            string parent = SafePath(root, Path.GetDirectoryName(path));
            Directory.CreateDirectory(parent);
            SafePath(root, parent);
        }

        static void CheckOperation(Func<bool> cancelled, Stopwatch clock, TimeSpan deadline, string operation)
        {
            if (cancelled != null && cancelled()) throw new OperationCanceledException(operation + " parent exited or cancelled");
            if (clock.Elapsed >= deadline) throw new TimeoutException(operation + " deadline exceeded");
        }

        static int RemainingTimeout(Stopwatch clock, TimeSpan deadline, int maximumMilliseconds)
        {
            if (clock == null) throw new ArgumentNullException("clock");
            if (maximumMilliseconds <= 0) throw new ArgumentOutOfRangeException("maximumMilliseconds");
            TimeSpan remaining = deadline - clock.Elapsed;
            if (remaining <= TimeSpan.Zero) throw new TimeoutException("FFmpeg download deadline exceeded");
            double milliseconds = Math.Ceiling(remaining.TotalMilliseconds);
            if (milliseconds > maximumMilliseconds) return maximumMilliseconds;
            return Math.Max(1, (int)milliseconds);
        }

        static void AtomicText(string root, string path, string text, Encoding encoding)
        {
            path = SafePath(root, path);
            EnsureParentDirectory(root, path);
            string temporary = SafePath(root, path + "." + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                using (FileStream stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                using (StreamWriter writer = new StreamWriter(stream, encoding))
                {
                    writer.Write(text);
                    writer.Flush();
                    stream.Flush(true);
                }
                AtomicPublish(root, temporary, path);
            }
            finally
            {
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }

        static void AtomicPublish(string root, string temporary, string destination)
        {
            temporary = SafePath(root, temporary);
            destination = SafePath(root, destination);
            if (!File.Exists(temporary)) throw new IOException("Atomic source is missing");
            if (Directory.Exists(destination)) throw new IOException("Atomic destination is a directory");
            if (File.Exists(destination))
            {
                File.Replace(temporary, destination, null);
                return;
            }
            try { File.Move(temporary, destination); }
            catch (IOException)
            {
                if (!File.Exists(destination)) throw;
                File.Replace(temporary, destination, null);
            }
        }

        internal static void ComputeSha256(string root, string inputPath, string resultPath)
        {
            ComputeSha256(root, inputPath, resultPath, delegate { return false; }, TimeSpan.FromMilliseconds(HashDeadlineMilliseconds));
        }

        static void ComputeSha256(string root, string inputPath, string resultPath, Func<bool> cancelled, TimeSpan deadline)
        {
            root = NormalizeRoot(root);
            inputPath = SafePath(root, inputPath);
            resultPath = SafePath(root, resultPath);
            if (!File.Exists(inputPath)) throw new FileNotFoundException("Hash input is missing", inputPath);
            Stopwatch clock = Stopwatch.StartNew();
            byte[] buffer = new byte[65536];
            string result;
            using (FileStream input = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (SHA256 sha = SHA256.Create())
            {
                int count;
                while ((count = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    CheckOperation(cancelled, clock, deadline, "Hash");
                    sha.TransformBlock(buffer, 0, count, buffer, 0);
                }
                sha.TransformFinalBlock(new byte[0], 0, 0);
                result = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
            }
            CheckOperation(cancelled, clock, deadline, "Hash");
            AtomicText(root, resultPath, result, Encoding.ASCII);
        }

        static void ReadExactly(Stream stream, byte[] buffer, int count, string error)
        {
            int offset = 0;
            while (offset < count)
            {
                int read = stream.Read(buffer, offset, count - offset);
                if (read <= 0) throw new IOException(error);
                offset += read;
            }
        }

        static void ValidatePortableExecutableStream(FileStream stream, Func<bool> cancelled,
            Stopwatch clock, TimeSpan deadline)
        {
            if (stream == null || !stream.CanRead || !stream.CanSeek)
                throw new IOException("Portable executable stream is unreadable");
            CheckOperation(cancelled, clock, deadline, "PE validation");
            long fileLength = stream.Length;
            if (fileLength < 512 || fileLength > MaxDownloadBytes)
                throw new IOException("Portable executable length is invalid");

            stream.Position = 0;
            byte[] dos = new byte[64];
            ReadExactly(stream, dos, dos.Length, "Truncated DOS header");
            if (dos[0] != (byte)'M' || dos[1] != (byte)'Z')
                throw new IOException("Portable executable DOS signature is invalid");
            int peOffset = BitConverter.ToInt32(dos, 0x3c);
            if (peOffset < dos.Length || peOffset > fileLength - 24)
                throw new IOException("Portable executable header offset is invalid");

            stream.Position = peOffset;
            byte[] coff = new byte[24];
            ReadExactly(stream, coff, coff.Length, "Truncated PE signature or COFF header");
            if (BitConverter.ToUInt32(coff, 0) != 0x00004550)
                throw new IOException("Portable executable signature is invalid");
            ushort machine = BitConverter.ToUInt16(coff, 4);
            ushort sections = BitConverter.ToUInt16(coff, 6);
            ushort optionalLength = BitConverter.ToUInt16(coff, 20);
            ushort characteristics = BitConverter.ToUInt16(coff, 22);
            if (sections == 0 || sections > 96 || optionalLength < 96 || optionalLength > 4096 ||
                (characteristics & 0x0002) == 0)
                throw new IOException("Portable executable COFF header is invalid");
            long optionalOffset = peOffset + 24L;
            long sectionOffset = optionalOffset + optionalLength;
            long sectionEnd = sectionOffset + sections * 40L;
            if (sectionEnd > fileLength)
                throw new IOException("Portable executable section table is truncated");

            byte[] optional = new byte[optionalLength];
            ReadExactly(stream, optional, optional.Length, "Truncated PE optional header");
            ushort magic = BitConverter.ToUInt16(optional, 0);
            bool pe32 = magic == 0x010b && machine == 0x014c;
            bool pe32Plus = magic == 0x020b && machine == 0x8664;
            if ((!pe32 && !pe32Plus) || (pe32Plus && optionalLength < 112))
                throw new IOException("Portable executable machine or optional header is unsupported");
            uint entryPoint = BitConverter.ToUInt32(optional, 16);
            uint sectionAlignment = BitConverter.ToUInt32(optional, 32);
            uint fileAlignment = BitConverter.ToUInt32(optional, 36);
            uint imageSize = BitConverter.ToUInt32(optional, 56);
            uint headersSize = BitConverter.ToUInt32(optional, 60);
            if (entryPoint == 0 || sectionAlignment == 0 || fileAlignment == 0 || imageSize == 0 ||
                entryPoint >= imageSize || headersSize < sectionEnd || headersSize > fileLength ||
                headersSize > imageSize)
                throw new IOException("Portable executable optional header bounds are invalid");

            bool executableSection = false;
            bool executableEntryPoint = false;
            stream.Position = sectionOffset;
            byte[] section = new byte[40];
            for (int index = 0; index < sections; index++)
            {
                CheckOperation(cancelled, clock, deadline, "PE validation");
                ReadExactly(stream, section, section.Length, "Truncated PE section header");
                uint virtualSize = BitConverter.ToUInt32(section, 8);
                uint virtualAddress = BitConverter.ToUInt32(section, 12);
                uint rawSize = BitConverter.ToUInt32(section, 16);
                uint rawOffset = BitConverter.ToUInt32(section, 20);
                uint sectionFlags = BitConverter.ToUInt32(section, 36);
                ulong mappedLength = Math.Max((ulong)virtualSize, (ulong)rawSize);
                ulong virtualEnd = (ulong)virtualAddress + mappedLength;
                if (mappedLength == 0 || virtualAddress >= imageSize || virtualEnd > imageSize)
                    throw new IOException("Portable executable virtual section bounds are invalid");
                if (rawSize > 0)
                {
                    ulong rawEnd = (ulong)rawOffset + rawSize;
                    if (rawOffset < headersSize || rawEnd > (ulong)fileLength)
                        throw new IOException("Portable executable raw section bounds are invalid");
                }
                if ((sectionFlags & 0x20000000) != 0)
                {
                    executableSection = true;
                    if ((ulong)entryPoint >= virtualAddress && (ulong)entryPoint < virtualEnd)
                        executableEntryPoint = true;
                }
            }
            if (!executableSection || !executableEntryPoint)
                throw new IOException("Portable executable entry point is not in executable section data");
            CheckOperation(cancelled, clock, deadline, "PE validation");
        }

        internal static void ValidatePortableExecutable(string root, string path)
        {
            ValidatePortableExecutable(root, path, delegate { return false; },
                TimeSpan.FromMilliseconds(HashDeadlineMilliseconds));
        }

        static void ValidatePortableExecutable(string root, string path, Func<bool> cancelled, TimeSpan deadline)
        {
            root = NormalizeRoot(root);
            path = SafePath(root, path);
            if (!File.Exists(path)) throw new FileNotFoundException("Portable executable is missing", path);
            Stopwatch clock = Stopwatch.StartNew();
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                ValidatePortableExecutableStream(stream, cancelled, clock, deadline);
        }

        static bool EqualBytes(byte[] first, byte[] second)
        {
            if (first == null || second == null || first.Length != second.Length) return false;
            int difference = 0;
            for (int index = 0; index < first.Length; index++) difference |= first[index] ^ second[index];
            return difference == 0;
        }

        static byte[] HashStream(FileStream stream, Func<bool> cancelled, Stopwatch clock,
            TimeSpan deadline, string operation)
        {
            stream.Position = 0;
            byte[] buffer = new byte[65536];
            using (SHA256 sha = SHA256.Create())
            {
                int count;
                while ((count = stream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    CheckOperation(cancelled, clock, deadline, operation);
                    sha.TransformBlock(buffer, 0, count, buffer, 0);
                }
                sha.TransformFinalBlock(new byte[0], 0, 0);
                CheckOperation(cancelled, clock, deadline, operation);
                return sha.Hash;
            }
        }

        internal static void InstallPortableExecutable(string root, string sourcePath, string targetPath,
            Func<bool> cancelled, TimeSpan deadline)
        {
            root = NormalizeRoot(root);
            sourcePath = SafePath(root, sourcePath);
            targetPath = SafePath(root, targetPath);
            if (Same(sourcePath, targetPath)) throw new IOException("Portable executable source and target must differ");
            if (!File.Exists(sourcePath)) throw new FileNotFoundException("Portable executable source is missing", sourcePath);
            if (deadline < TimeSpan.Zero) throw new ArgumentOutOfRangeException("deadline");
            EnsureParentDirectory(root, targetPath);
            string partial = SafePath(root, targetPath + ".native-bootstrap-" +
                Guid.NewGuid().ToString("N") + ".partial");
            Stopwatch clock = Stopwatch.StartNew();
            try
            {
                // Keep this handle open without write/delete sharing through publication so
                // a path swap cannot invalidate the source bytes that were validated/hashed.
                using (FileStream source = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    ValidatePortableExecutableStream(source, cancelled, clock, deadline);
                    long sourceLength = source.Length;
                    source.Position = 0;
                    byte[] sourceHash;
                    using (SHA256 sha = SHA256.Create())
                    using (FileStream output = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        byte[] buffer = new byte[65536];
                        long copied = 0;
                        int count;
                        while ((count = source.Read(buffer, 0, buffer.Length)) > 0)
                        {
                            CheckOperation(cancelled, clock, deadline, "PE install");
                            copied += count;
                            if (copied > sourceLength) throw new IOException("Portable executable source changed length");
                            output.Write(buffer, 0, count);
                            sha.TransformBlock(buffer, 0, count, buffer, 0);
                        }
                        sha.TransformFinalBlock(new byte[0], 0, 0);
                        sourceHash = sha.Hash;
                        if (copied != sourceLength || source.Position != sourceLength)
                            throw new IOException("Portable executable source was truncated during copy");
                        CheckOperation(cancelled, clock, deadline, "PE install");
                        output.Flush(true);
                    }

                    FileInfo candidate = new FileInfo(partial);
                    if (candidate.Length != sourceLength)
                        throw new IOException("Portable executable candidate size mismatch");
                    byte[] candidateHash;
                    using (FileStream candidateStream = new FileStream(partial, FileMode.Open, FileAccess.Read, FileShare.Read))
                    {
                        ValidatePortableExecutableStream(candidateStream, cancelled, clock, deadline);
                        candidateHash = HashStream(candidateStream, cancelled, clock, deadline, "PE install verification");
                    }
                    if (!EqualBytes(sourceHash, candidateHash))
                        throw new IOException("Portable executable candidate SHA-256 mismatch");
                    CheckOperation(cancelled, clock, deadline, "PE install");
                    AtomicPublish(root, partial, targetPath);
                }
            }
            finally
            {
                if (File.Exists(partial)) File.Delete(partial);
            }
        }

        internal static Uri ValidateDownloadUri(string value)
        {
            Uri uri;
            if (!Uri.TryCreate(value, UriKind.Absolute, out uri) ||
                !String.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(uri.IdnHost, "www.gyan.dev", StringComparison.OrdinalIgnoreCase) ||
                !uri.IsDefaultPort || !String.IsNullOrEmpty(uri.UserInfo) ||
                !String.IsNullOrEmpty(uri.Fragment) || !String.IsNullOrEmpty(uri.Query) ||
                !String.Equals(uri.AbsolutePath, "/ffmpeg/builds/ffmpeg-release-essentials.zip", StringComparison.Ordinal))
                throw new IOException("Only the official HTTPS FFmpeg package URL is allowed");
            return uri;
        }

        static Uri ValidateRedirectTarget(Uri current, string location)
        {
            if (current == null || String.IsNullOrWhiteSpace(location) ||
                location.IndexOf('\\') >= 0 ||
                Regex.IsMatch(location, @"(?i)(?:^|/)\.{1,2}(?:/|$)|%2e|%2f|%5c"))
                throw new IOException("Unsafe FFmpeg redirect location");
            Uri target;
            try { target = new Uri(current, location); }
            catch (UriFormatException error) { throw new IOException("Invalid FFmpeg redirect location", error); }
            if (!String.Equals(target.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(target.IdnHost, "www.gyan.dev", StringComparison.OrdinalIgnoreCase) ||
                !target.IsDefaultPort || !String.IsNullOrEmpty(target.UserInfo) ||
                !String.IsNullOrEmpty(target.Fragment) || !String.IsNullOrEmpty(target.Query) ||
                !Regex.IsMatch(target.AbsolutePath,
                    @"\A/ffmpeg/builds/packages/ffmpeg-[0-9]+(?:\.[0-9]+){1,3}-essentials_build\.zip\z",
                    RegexOptions.CultureInvariant))
                throw new IOException("FFmpeg redirect target is outside the official package route");
            return target;
        }

        static bool IsRedirect(HttpStatusCode status)
        {
            int code = (int)status;
            return code == 301 || code == 302 || code == 303 || code == 307 || code == 308;
        }

        internal sealed class RedirectPolicy
        {
            readonly int maximumRedirects;
            readonly Stopwatch clock;
            readonly TimeSpan deadline;
            readonly HashSet<string> visited;
            int redirects;
            Uri current;

            public RedirectPolicy(string initialUrl, int maximumRedirects, Stopwatch clock, TimeSpan deadline)
            {
                if (maximumRedirects < 0 || maximumRedirects > 10) throw new ArgumentOutOfRangeException("maximumRedirects");
                if (clock == null) throw new ArgumentNullException("clock");
                if (deadline < TimeSpan.Zero) throw new ArgumentOutOfRangeException("deadline");
                this.maximumRedirects = maximumRedirects;
                this.clock = clock;
                this.deadline = deadline;
                current = ValidateDownloadUri(initialUrl);
                visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                visited.Add(current.AbsoluteUri);
            }

            public Uri Current { get { return current; } }

            public int BoundedTimeout(int maximumMilliseconds)
            {
                return RemainingTimeout(clock, deadline, maximumMilliseconds);
            }

            public bool Apply(HttpStatusCode status, string location, out Uri next)
            {
                BoundedTimeout(Int32.MaxValue);
                if (IsRedirect(status))
                {
                    if (redirects >= maximumRedirects) throw new IOException("FFmpeg redirect limit exceeded");
                    Uri candidate = ValidateRedirectTarget(current, location);
                    if (!visited.Add(candidate.AbsoluteUri)) throw new IOException("FFmpeg redirect loop detected");
                    redirects++;
                    current = candidate;
                    next = current;
                    return true;
                }
                if (status != HttpStatusCode.OK)
                    throw new IOException("Unexpected FFmpeg download status: " + (int)status);
                next = current;
                return false;
            }
        }

        static HttpWebResponse OpenDownloadResponse(Uri initial, Func<bool> cancelled, Stopwatch clock, TimeSpan deadline)
        {
            RedirectPolicy policy = new RedirectPolicy(initial.AbsoluteUri, 5, clock, deadline);
            while (true)
            {
                CheckOperation(cancelled, clock, deadline, "Download");
                Uri current = policy.Current;
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(current);
                request.Method = "GET";
                request.AllowAutoRedirect = false;
                request.AutomaticDecompression = DecompressionMethods.None;
                request.Timeout = policy.BoundedTimeout(30000);
                request.ReadWriteTimeout = policy.BoundedTimeout(15000);
                request.KeepAlive = false;
                request.UserAgent = "WutheringNativeBootstrap/1.0";
                HttpWebResponse response = (HttpWebResponse)request.GetResponse();
                Uri next;
                bool redirected;
                try
                {
                    if (!String.Equals(response.ResponseUri.AbsoluteUri, current.AbsoluteUri, StringComparison.OrdinalIgnoreCase))
                        throw new IOException("HTTP stack changed the FFmpeg request URL unexpectedly");
                    redirected = policy.Apply(response.StatusCode,
                        response.Headers[HttpResponseHeader.Location], out next);
                }
                catch
                {
                    response.Dispose();
                    throw;
                }
                if (redirected)
                {
                    response.Dispose();
                    continue;
                }
                if (response.ContentLength <= 0 || response.ContentLength > MaxDownloadBytes)
                {
                    response.Dispose();
                    throw new IOException("FFmpeg download length is missing or excessive");
                }
                return response;
            }
        }

        static void TryWriteStatus(string root, string statusPath, string state, long received, long total)
        {
            try
            {
                AtomicText(root, statusPath, "state=" + state + "\r\nreceived=" + received.ToString(CultureInfo.InvariantCulture) +
                    "\r\ntotal=" + total.ToString(CultureInfo.InvariantCulture) + "\r\n", Encoding.ASCII);
            }
            catch
            {
                // Progress is advisory. Exit status and the atomic final path are authoritative.
            }
        }

        static void Download(string root, string url, string outputPath, string statusPath, Func<bool> cancelled)
        {
            root = NormalizeRoot(root);
            outputPath = SafePath(root, outputPath);
            statusPath = SafePath(root, statusPath);
            Uri uri = ValidateDownloadUri(url);
            Stopwatch clock = Stopwatch.StartNew();
            TimeSpan deadline = TimeSpan.FromMilliseconds(DownloadDeadlineMilliseconds);
            using (HttpWebResponse response = OpenDownloadResponse(uri, cancelled, clock, deadline))
            using (Stream stream = response.GetResponseStream())
                PublishDownloadStream(root, uri, stream, response.ContentLength, outputPath, statusPath, cancelled, deadline, clock);
        }

        internal static void PublishDownloadStream(string root, Uri uri, Stream input, long contentLength,
            string outputPath, string statusPath, Func<bool> cancelled, TimeSpan deadline)
        {
            PublishDownloadStream(root, uri, input, contentLength, outputPath, statusPath, cancelled, deadline, Stopwatch.StartNew());
        }

        static void PublishDownloadStream(string root, Uri uri, Stream input, long contentLength,
            string outputPath, string statusPath, Func<bool> cancelled, TimeSpan deadline, Stopwatch clock)
        {
            root = NormalizeRoot(root);
            if (uri == null) throw new ArgumentNullException("uri");
            ValidateDownloadUri(uri.AbsoluteUri);
            if (input == null || !input.CanRead) throw new IOException("Download response is unreadable");
            if (contentLength <= 0 || contentLength > MaxDownloadBytes) throw new IOException("Download response length is invalid");
            outputPath = SafePath(root, outputPath);
            statusPath = SafePath(root, statusPath);
            EnsureParentDirectory(root, outputPath);
            EnsureParentDirectory(root, statusPath);
            string temporary = SafePath(root, outputPath + ".native-bootstrap.partial");
            if (Directory.Exists(temporary)) throw new IOException("Download partial path is a directory");
            if (File.Exists(temporary)) File.Delete(temporary);
            long received = 0;
            long lastStatusAt = -1000;
            TryWriteStatus(root, statusPath, "downloading", 0, contentLength);
            try
            {
                using (FileStream output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
                {
                    byte[] buffer = new byte[65536];
                    while (true)
                    {
                        CheckOperation(cancelled, clock, deadline, "Download");
                        if (input.CanTimeout) input.ReadTimeout = RemainingTimeout(clock, deadline, 15000);
                        int count = input.Read(buffer, 0, buffer.Length);
                        if (count == 0) break;
                        received += count;
                        if (received > contentLength || received > MaxDownloadBytes)
                            throw new IOException("Download response exceeded its declared length");
                        output.Write(buffer, 0, count);
                        if (clock.ElapsedMilliseconds - lastStatusAt >= 250)
                        {
                            TryWriteStatus(root, statusPath, "downloading", received, contentLength);
                            lastStatusAt = clock.ElapsedMilliseconds;
                        }
                    }
                    if (received != contentLength) throw new IOException("Download response was truncated");
                    output.Flush(true);
                }
                CheckOperation(cancelled, clock, deadline, "Download");
                ValidateDownloadedArchive(temporary);
                CheckOperation(cancelled, clock, deadline, "Download");
                AtomicPublish(root, temporary, outputPath);
                TryWriteStatus(root, statusPath, "complete", received, contentLength);
            }
            catch
            {
                TryWriteStatus(root, statusPath, "failed", received, contentLength);
                throw;
            }
            finally
            {
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }

        static uint[] CreateCrcTable()
        {
            uint[] result = new uint[256];
            for (uint i = 0; i < result.Length; i++)
            {
                uint value = i;
                for (int bit = 0; bit < 8; bit++) value = (value & 1) != 0 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
                result[i] = value;
            }
            return result;
        }

        // Framework 4.8 ZipArchive does not validate CRC while reading. Parse
        // the bounded ZIP32 central directory, then verify every extracted byte.
        static CentralRecord[] ReadCentralDirectory(FileStream file)
        {
            if (file.Length < 22 || file.Length >= UInt32.MaxValue) throw new IOException("A bounded ZIP32 archive is required");
            int tailLength = (int)Math.Min(65557, file.Length);
            byte[] tail = new byte[tailLength];
            file.Position = file.Length - tailLength;
            int read = 0;
            while (read < tailLength)
            {
                int count = file.Read(tail, read, tailLength - read);
                if (count == 0) throw new IOException("Truncated ZIP end record");
                read += count;
            }
            int end = -1;
            for (int i = tailLength - 22; i >= 0; i--)
            {
                if (BitConverter.ToUInt32(tail, i) == 0x06054b50 && i + 22 + BitConverter.ToUInt16(tail, i + 20) == tailLength)
                {
                    end = i;
                    break;
                }
            }
            if (end < 0 || BitConverter.ToUInt16(tail, end + 4) != 0 || BitConverter.ToUInt16(tail, end + 6) != 0)
                throw new IOException("Invalid or multi-disk ZIP archive");
            int countEntries = BitConverter.ToUInt16(tail, end + 10);
            uint centralLength = BitConverter.ToUInt32(tail, end + 12);
            uint centralOffset = BitConverter.ToUInt32(tail, end + 16);
            long centralEnd = file.Length - tailLength + end;
            if (countEntries == 0 || countEntries == UInt16.MaxValue || countEntries > MaxArchiveEntries ||
                countEntries != BitConverter.ToUInt16(tail, end + 8) || (long)centralOffset + centralLength != centralEnd)
                throw new IOException("Invalid, empty, ZIP64, or excessive central directory");
            CentralRecord[] records = new CentralRecord[countEntries];
            long expanded = 0;
            file.Position = centralOffset;
            using (BinaryReader reader = new BinaryReader(file, Encoding.UTF8, true))
            {
                for (int i = 0; i < countEntries; i++)
                {
                    byte[] header = reader.ReadBytes(46);
                    if (header.Length != 46 || BitConverter.ToUInt32(header, 0) != 0x02014b50)
                        throw new IOException("Invalid ZIP entry header");
                    ushort flags = BitConverter.ToUInt16(header, 8);
                    ushort method = BitConverter.ToUInt16(header, 10);
                    uint compressed = BitConverter.ToUInt32(header, 20);
                    uint length = BitConverter.ToUInt32(header, 24);
                    uint localOffset = BitConverter.ToUInt32(header, 42);
                    if ((flags & 1) != 0 || (method != 0 && method != 8) || compressed == UInt32.MaxValue ||
                        length == UInt32.MaxValue || localOffset >= centralOffset || BitConverter.ToUInt16(header, 34) != 0)
                        throw new IOException("Encrypted, ZIP64, or unsupported ZIP entry");
                    if (length > MaxEntryBytes || expanded > MaxExpandedBytes - length)
                        throw new IOException("ZIP expanded size limit exceeded");
                    expanded += length;
                    records[i] = new CentralRecord
                    {
                        Crc = BitConverter.ToUInt32(header, 16),
                        CompressedLength = compressed,
                        Length = length
                    };
                    file.Position += BitConverter.ToUInt16(header, 28) + BitConverter.ToUInt16(header, 30) + BitConverter.ToUInt16(header, 32);
                    if (file.Position > centralEnd) throw new IOException("ZIP central directory overflow");
                }
            }
            if (file.Position != centralEnd) throw new IOException("ZIP central directory length mismatch");
            file.Position = 0;
            return records;
        }

        static string EntryPath(string name)
        {
            if (String.IsNullOrEmpty(name) || name.StartsWith("/", StringComparison.Ordinal) ||
                name.StartsWith("\\", StringComparison.Ordinal) || name.IndexOf('\\') >= 0)
                throw new IOException("Unsafe ZIP path");
            string trimmed = name.TrimEnd('/');
            if (trimmed.Length == 0) throw new IOException("Unsafe ZIP path");
            string[] parts = trimmed.Split(new char[] { '/' }, StringSplitOptions.None);
            foreach (string part in parts)
            {
                if (String.IsNullOrEmpty(part) || part == "." || part == ".." ||
                    part.TrimEnd(' ', '.') != part || part.IndexOf(':') >= 0 ||
                    part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                    Regex.IsMatch(part, @"\A(CON|PRN|AUX|NUL|CLOCK\$|COM[1-9]|LPT[1-9])(?:\.|\z)", RegexOptions.IgnoreCase))
                    throw new IOException("Unsafe ZIP path component");
            }
            return String.Join("\\", parts);
        }

        static IEnumerable<string> Ancestors(string relative)
        {
            int offset = relative.IndexOf('\\');
            while (offset > 0)
            {
                yield return relative.Substring(0, offset);
                offset = relative.IndexOf('\\', offset + 1);
            }
        }

        static List<EntryPlan> ValidateEntries(ZipArchive archive, CentralRecord[] records, bool requireFfmpeg)
        {
            if (archive.Entries.Count != records.Length) throw new IOException("ZIP entry count mismatch");
            HashSet<string> actualNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> files = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> directories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            List<EntryPlan> plan = new List<EntryPlan>(records.Length);
            bool foundFfmpeg = false;
            for (int index = 0; index < archive.Entries.Count; index++)
            {
                ZipArchiveEntry entry = archive.Entries[index];
                CentralRecord record = records[index];
                string relative = EntryPath(entry.FullName);
                bool directory = entry.FullName.EndsWith("/", StringComparison.Ordinal);
                if (!actualNames.Add(relative)) throw new IOException("Case-insensitive ZIP path collision");
                if (((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000 ||
                    (entry.ExternalAttributes & (int)FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Symbolic or reparse ZIP entry is forbidden");
                if (entry.Length != record.Length || entry.CompressedLength != record.CompressedLength)
                    throw new IOException("ZIP entry metadata mismatch");
                foreach (string ancestor in Ancestors(relative))
                {
                    if (files.Contains(ancestor)) throw new IOException("ZIP file-directory prefix collision");
                    directories.Add(ancestor);
                }
                if (directory)
                {
                    if (entry.Length != 0 || record.Crc != 0 || files.Contains(relative))
                        throw new IOException("Invalid ZIP directory entry");
                    directories.Add(relative);
                }
                else
                {
                    if (directories.Contains(relative) || !files.Add(relative))
                        throw new IOException("ZIP file-directory collision");
                    if (String.Equals(Path.GetFileName(relative), "ffmpeg.exe", StringComparison.OrdinalIgnoreCase)) foundFfmpeg = true;
                }
                plan.Add(new EntryPlan { Entry = entry, RelativePath = relative, IsDirectory = directory, Crc = record.Crc });
            }
            if (requireFfmpeg && !foundFfmpeg) throw new IOException("Downloaded archive does not contain ffmpeg.exe");
            return plan;
        }

        static void ValidateDownloadedArchive(string path)
        {
            using (FileStream file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                CentralRecord[] records = ReadCentralDirectory(file);
                using (ZipArchive archive = new ZipArchive(file, ZipArchiveMode.Read))
                    ValidateEntries(archive, records, true);
            }
        }

        static void CheckTreeForReparse(string directory, string root)
        {
            SafePath(root, directory);
            foreach (string entry in Directory.EnumerateFileSystemEntries(directory))
            {
                SafePath(root, entry);
                if (Directory.Exists(entry)) CheckTreeForReparse(entry, root);
            }
        }

        static void CleanupStage(string stage, string root)
        {
            if (!Directory.Exists(stage)) return;
            CheckTreeForReparse(stage, root);
            Directory.Delete(stage, true);
        }

        internal static void ExtractArchive(string root, string zipPath, string destination, Func<bool> cancelled)
        {
            root = NormalizeRoot(root);
            zipPath = SafePath(root, zipPath);
            destination = SafePath(root, destination);
            if (!File.Exists(zipPath)) throw new FileNotFoundException("Bootstrap ZIP is missing", zipPath);
            if (File.Exists(destination) || Directory.Exists(destination)) throw new IOException("Extraction destination already exists");
            EnsureParentDirectory(root, destination);
            string stage = SafePath(root, destination + ".bootstrap-" + Guid.NewGuid().ToString("N") + ".stage");
            Directory.CreateDirectory(stage);
            SafePath(root, stage);
            bool published = false;
            Stopwatch clock = Stopwatch.StartNew();
            TimeSpan deadline = TimeSpan.FromMilliseconds(ExtractDeadlineMilliseconds);
            try
            {
                using (FileStream file = new FileStream(zipPath, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    CentralRecord[] records = ReadCentralDirectory(file);
                    using (ZipArchive archive = new ZipArchive(file, ZipArchiveMode.Read))
                    {
                        List<EntryPlan> plan = ValidateEntries(archive, records, false);
                        foreach (EntryPlan item in plan)
                        {
                            CheckOperation(cancelled, clock, deadline, "Extraction");
                            string outputPath = SafePath(stage, Path.Combine(stage, item.RelativePath));
                            if (item.IsDirectory)
                            {
                                Directory.CreateDirectory(outputPath);
                                SafePath(stage, outputPath);
                                continue;
                            }
                            string outputParent = SafePath(stage, Path.GetDirectoryName(outputPath));
                            Directory.CreateDirectory(outputParent);
                            SafePath(stage, outputParent);
                            using (Stream input = item.Entry.Open())
                            using (FileStream output = new FileStream(outputPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                            {
                                byte[] buffer = new byte[65536];
                                long copied = 0;
                                uint crc = UInt32.MaxValue;
                                int count;
                                while ((count = input.Read(buffer, 0, buffer.Length)) > 0)
                                {
                                    CheckOperation(cancelled, clock, deadline, "Extraction");
                                    copied += count;
                                    if (copied > item.Entry.Length) throw new IOException("ZIP entry exceeded declared length");
                                    for (int i = 0; i < count; i++) crc = CrcTable[(crc ^ buffer[i]) & 255] ^ (crc >> 8);
                                    output.Write(buffer, 0, count);
                                }
                                if (copied != item.Entry.Length || (crc ^ UInt32.MaxValue) != item.Crc)
                                    throw new IOException("Truncated or CRC-corrupt ZIP entry");
                                output.Flush(true);
                            }
                        }
                    }
                }
                CheckOperation(cancelled, clock, deadline, "Extraction");
                CheckTreeForReparse(stage, root);
                if (File.Exists(destination) || Directory.Exists(destination)) throw new IOException("Extraction destination appeared during publication");
                Directory.Move(stage, destination);
                published = true;
                CheckTreeForReparse(destination, root);
            }
            finally
            {
                if (!published && Directory.Exists(stage)) CleanupStage(stage, root);
            }
        }

        static int ParseProcessId(string value)
        {
            int result;
            if (!Int32.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out result) || result <= 0)
                throw new IOException("Invalid parent process id");
            return result;
        }

        static long ParseCreation(string value)
        {
            long result;
            if (!Int64.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out result) || result <= 0)
                throw new IOException("Invalid parent creation identity");
            return result;
        }

        public static int Main(string[] args)
        {
            ParentLease parent = null;
            try
            {
                if (args == null || args.Length == 0) throw new IOException("Missing bootstrap command");
                string mode = args[0];
                if (mode == "hash")
                {
                    if (args.Length != 7) throw new IOException("Invalid hash arguments");
                    parent = new ParentLease(ParseProcessId(args[4]), ParseCreation(args[5]), args[6]);
                    ComputeSha256(args[1], args[2], args[3], parent.IsCancelled, TimeSpan.FromMilliseconds(HashDeadlineMilliseconds));
                }
                else if (mode == "download")
                {
                    if (args.Length != 8) throw new IOException("Invalid download arguments");
                    parent = new ParentLease(ParseProcessId(args[5]), ParseCreation(args[6]), args[7]);
                    Download(args[1], args[2], args[3], args[4], parent.IsCancelled);
                }
                else if (mode == "extract")
                {
                    if (args.Length != 7) throw new IOException("Invalid extract arguments");
                    parent = new ParentLease(ParseProcessId(args[4]), ParseCreation(args[5]), args[6]);
                    ExtractArchive(args[1], args[2], args[3], parent.IsCancelled);
                }
                else if (mode == "validate-pe")
                {
                    if (args.Length != 6) throw new IOException("Invalid validate-pe arguments");
                    parent = new ParentLease(ParseProcessId(args[3]), ParseCreation(args[4]), args[5]);
                    ValidatePortableExecutable(args[1], args[2], parent.IsCancelled,
                        TimeSpan.FromMilliseconds(HashDeadlineMilliseconds));
                }
                else if (mode == "install-pe")
                {
                    if (args.Length != 7) throw new IOException("Invalid install-pe arguments");
                    parent = new ParentLease(ParseProcessId(args[4]), ParseCreation(args[5]), args[6]);
                    InstallPortableExecutable(args[1], args[2], args[3], parent.IsCancelled,
                        TimeSpan.FromMilliseconds(InstallDeadlineMilliseconds));
                }
                else throw new IOException("Unknown bootstrap command");
                Console.WriteLine("SUCCESS " + mode);
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine("FAILED " + error.Message.Replace('\r', ' ').Replace('\n', ' '));
                return 1;
            }
            finally
            {
                if (parent != null) parent.Dispose();
            }
        }
    }
}
