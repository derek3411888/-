using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using Wuthering.Native;

public static class BootstrapAssetsTests
{
    sealed class ZipItem
    {
        public readonly string Name;
        public readonly string Content;
        public readonly int Attributes;
        public ZipItem(string name, string content) : this(name, content, 0) { }
        public ZipItem(string name, string content, int attributes)
        {
            Name = name;
            Content = content;
            Attributes = attributes;
        }
    }

    sealed class ThrowingStream : Stream
    {
        readonly Stream inner;
        readonly long failAfter;
        long read;
        public ThrowingStream(byte[] bytes, long failAfterBytes)
        {
            inner = new MemoryStream(bytes, false);
            failAfter = failAfterBytes;
        }
        public override int Read(byte[] buffer, int offset, int count)
        {
            if (read >= failAfter) throw new IOException("controlled response interruption");
            count = (int)Math.Min(count, failAfter - read);
            int value = inner.Read(buffer, offset, count);
            read += value;
            return value;
        }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
        protected override void Dispose(bool disposing) { if (disposing) inner.Dispose(); base.Dispose(disposing); }
    }

    sealed class ChunkedStream : Stream
    {
        readonly Stream inner;
        readonly int chunk;
        public ChunkedStream(byte[] bytes, int chunkSize)
        {
            inner = new MemoryStream(bytes, false);
            chunk = chunkSize;
        }
        public override int Read(byte[] buffer, int offset, int count)
        {
            return inner.Read(buffer, offset, Math.Min(count, chunk));
        }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
        protected override void Dispose(bool disposing) { if (disposing) inner.Dispose(); base.Dispose(disposing); }
    }

    static int checks;
    static string root;

    static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
        checks++;
    }

    static void Reject(Action action, string message)
    {
        bool rejected = false;
        try { action(); }
        catch { rejected = true; }
        Check(rejected, message);
    }

    static string Fixture(string name)
    {
        string path = Path.Combine(root, name + "-" + checks);
        Directory.CreateDirectory(path);
        return path;
    }

    static void CreateZip(string path, params ZipItem[] items)
    {
        using (FileStream file = File.Create(path))
        using (ZipArchive zip = new ZipArchive(file, ZipArchiveMode.Create))
        {
            foreach (ZipItem item in items)
            {
                ZipArchiveEntry entry = zip.CreateEntry(item.Name, CompressionLevel.NoCompression);
                entry.ExternalAttributes = item.Attributes;
                if (!item.Name.EndsWith("/", StringComparison.Ordinal))
                {
                    using (StreamWriter writer = new StreamWriter(entry.Open(), new UTF8Encoding(false)))
                        writer.Write(item.Content);
                }
            }
        }
    }

    static byte[] CreateZipBytes()
    {
        using (MemoryStream memory = new MemoryStream())
        {
            using (ZipArchive zip = new ZipArchive(memory, ZipArchiveMode.Create, true))
            using (StreamWriter writer = new StreamWriter(zip.CreateEntry("ffmpeg-build/bin/ffmpeg.exe", CompressionLevel.NoCompression).Open(), new UTF8Encoding(false)))
                writer.Write("controlled ffmpeg fixture");
            return memory.ToArray();
        }
    }

    static string Hash(string path)
    {
        using (FileStream stream = File.OpenRead(path))
        using (SHA256 sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }

    static void PatchFirstCentralUInt32(string path, int fieldOffset, uint value)
    {
        byte[] bytes = File.ReadAllBytes(path);
        bool patched = false;
        for (int i = 0; i <= bytes.Length - 46; i++)
        {
            if (BitConverter.ToUInt32(bytes, i) != 0x02014b50) continue;
            byte[] replacement = BitConverter.GetBytes(value);
            Buffer.BlockCopy(replacement, 0, bytes, i + fieldOffset, 4);
            patched = true;
            break;
        }
        Check(patched, "ZIP fixture has a central directory record");
        File.WriteAllBytes(path, bytes);
    }

    static void CorruptStoredEntry(string path, string literal)
    {
        byte[] bytes = File.ReadAllBytes(path);
        byte[] match = Encoding.UTF8.GetBytes(literal);
        bool changed = false;
        for (int i = 0; i <= bytes.Length - match.Length; i++)
        {
            bool same = true;
            for (int j = 0; j < match.Length; j++) if (bytes[i + j] != match[j]) { same = false; break; }
            if (!same) continue;
            bytes[i] ^= 1;
            changed = true;
            break;
        }
        Check(changed, "ZIP fixture payload was found for same-length corruption");
        File.WriteAllBytes(path, bytes);
    }

    static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    static Process Start(string executable, string arguments)
    {
        return Process.Start(new ProcessStartInfo(executable, arguments)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        });
    }

    static int RunBounded(string executable, string arguments, int timeoutMilliseconds,
        out string stdout, out string stderr)
    {
        using (Process child = Start(executable, arguments))
        {
            Task<string> stdoutTask = child.StandardOutput.ReadToEndAsync();
            Task<string> stderrTask = child.StandardError.ReadToEndAsync();
            if (!child.WaitForExit(timeoutMilliseconds))
            {
                try { child.Kill(); }
                catch { }
                child.WaitForExit(5000);
                Task.WaitAll(new Task[] { stdoutTask, stderrTask }, 5000);
                throw new TimeoutException("Controlled helper child exceeded its test deadline");
            }
            child.WaitForExit();
            if (!Task.WaitAll(new Task[] { stdoutTask, stderrTask }, 5000))
                throw new TimeoutException("Controlled helper output did not close after exit");
            stdout = stdoutTask.Result;
            stderr = stderrTask.Result;
            return child.ExitCode;
        }
    }

    static void HashTests()
    {
        string fixture = Fixture("hash");
        string input = Path.Combine(fixture, "abc.bin");
        string result = Path.Combine(fixture, "hash.txt");
        File.WriteAllBytes(input, Encoding.ASCII.GetBytes("abc"));
        BootstrapAssets.ComputeSha256(fixture, input, result);
        Check(File.ReadAllText(result).Trim() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA256 is lowercase and byte exact");
        string outside = Path.Combine(Path.GetDirectoryName(fixture), "outside-hash-" + Guid.NewGuid().ToString("N") + ".txt");
        Reject(delegate { BootstrapAssets.ComputeSha256(fixture, input, outside); }, "Hash result cannot escape app root");
        Check(!File.Exists(outside), "Rejected hash result creates no outside file");
    }

    static void PortableExecutableInstallTests(string helper)
    {
        string fixture = Fixture("portable-executable");
        string valid = Path.Combine(fixture, "valid.exe");
        File.Copy(helper, valid);
        BootstrapAssets.ValidatePortableExecutable(fixture, valid);

        string fakeMz = Path.Combine(fixture, "fake-mz.exe");
        byte[] fakeBytes = new byte[512];
        fakeBytes[0] = (byte)'M';
        fakeBytes[1] = (byte)'Z';
        File.WriteAllBytes(fakeMz, fakeBytes);
        Reject(delegate { BootstrapAssets.ValidatePortableExecutable(fixture, fakeMz); },
            "An MZ prefix without a structurally valid PE is rejected");

        string truncated = Path.Combine(fixture, "truncated.exe");
        byte[] validBytes = File.ReadAllBytes(valid);
        int truncatedLength = Math.Max(128, Math.Min(1024, validBytes.Length - 1));
        byte[] truncatedBytes = new byte[truncatedLength];
        Buffer.BlockCopy(validBytes, 0, truncatedBytes, 0, truncatedLength);
        File.WriteAllBytes(truncated, truncatedBytes);
        Reject(delegate { BootstrapAssets.ValidatePortableExecutable(fixture, truncated); },
            "A valid PE header with truncated section data is rejected");

        fixture = Fixture("install-cancelled");
        string source = Path.Combine(fixture, "source.exe");
        string target = Path.Combine(fixture, "ffmpeg.exe");
        File.Copy(helper, source);
        using (FileStream expanded = new FileStream(source, FileMode.Open, FileAccess.Write, FileShare.None))
            expanded.SetLength(expanded.Length + 1024 * 1024);
        File.Copy(helper, target);
        string priorHash = Hash(target);
        bool sourceWriteDenied = false;
        bool sourceWriteAttempted = false;
        int cancelProbes = 0;
        Reject(delegate
        {
            BootstrapAssets.InstallPortableExecutable(fixture, source, target, delegate
            {
                if (!sourceWriteAttempted)
                {
                    sourceWriteAttempted = true;
                    try
                    {
                        using (FileStream writer = new FileStream(source, FileMode.Open, FileAccess.Write,
                            FileShare.ReadWrite | FileShare.Delete)) writer.WriteByte(0);
                    }
                    catch (IOException) { sourceWriteDenied = true; }
                }
                cancelProbes++;
                return cancelProbes >= 4;
            }, TimeSpan.FromSeconds(5));
        }, "Mid-copy cancellation rejects native PE installation");
        Check(sourceWriteAttempted && sourceWriteDenied,
            "Source remains opened read-only with write/delete sharing denied during installation");
        Check(Hash(target) == priorHash, "Mid-copy cancellation preserves the prior target byte-for-byte");
        Check(Directory.GetFiles(fixture, "ffmpeg.exe.native-bootstrap-*.partial").Length == 0,
            "Mid-copy cancellation removes only its unique partial file");

        fixture = Fixture("install-timeout");
        source = Path.Combine(fixture, "source.exe");
        target = Path.Combine(fixture, "ffmpeg.exe");
        File.Copy(helper, source);
        File.Copy(helper, target);
        priorHash = Hash(target);
        Reject(delegate
        {
            BootstrapAssets.InstallPortableExecutable(fixture, source, target,
                delegate { return false; }, TimeSpan.Zero);
        }, "Expired install deadline rejects publication");
        Check(Hash(target) == priorHash, "Install timeout preserves the prior target byte-for-byte");
        Check(Directory.GetFiles(fixture, "ffmpeg.exe.native-bootstrap-*.partial").Length == 0,
            "Install timeout leaves no owned partial file");

        fixture = Fixture("install-stale-partial");
        source = Path.Combine(fixture, "source.exe");
        target = Path.Combine(fixture, "ffmpeg.exe");
        File.Copy(helper, source);
        using (FileStream expanded = new FileStream(source, FileMode.Open, FileAccess.Write, FileShare.None))
            expanded.SetLength(expanded.Length + 4096);
        File.Copy(helper, target);
        string stalePartial = target + ".native-bootstrap-stale.partial";
        File.WriteAllText(stalePartial, "corrupted stale partial", Encoding.ASCII);
        string staleHash = Hash(stalePartial);
        BootstrapAssets.InstallPortableExecutable(fixture, source, target,
            delegate { return false; }, TimeSpan.FromSeconds(5));
        Check(Hash(target) == Hash(source), "Installed PE matches the held source SHA-256 and size");
        BootstrapAssets.ValidatePortableExecutable(fixture, target);
        Check(File.Exists(stalePartial) && Hash(stalePartial) == staleHash,
            "An unrelated stale partial is never installed or deleted by another operation");
        Check(Directory.GetFiles(fixture, "ffmpeg.exe.native-bootstrap-*.partial").Length == 1,
            "Successful install removes its exact unique partial and leaves only the stale fixture");

        string invalidSource = Path.Combine(fixture, "invalid-source.exe");
        File.WriteAllBytes(invalidSource, fakeBytes);
        string installedHash = Hash(target);
        Reject(delegate
        {
            BootstrapAssets.InstallPortableExecutable(fixture, invalidSource, target,
                delegate { return false; }, TimeSpan.FromSeconds(5));
        }, "Invalid source PE is rejected before replacement");
        Check(Hash(target) == installedHash, "Invalid source cannot replace an installed target");
    }

    static void ExtractionTests()
    {
        string fixture = Fixture("extract-valid");
        string zip = Path.Combine(fixture, "ffmpeg.zip");
        string destination = Path.Combine(fixture, "extract");
        CreateZip(zip, new ZipItem("ffmpeg-build/bin/ffmpeg.exe", "binary"), new ZipItem("ffmpeg-build/doc/中文.txt", "內容"));
        BootstrapAssets.ExtractArchive(fixture, zip, destination, delegate { return false; });
        Check(File.ReadAllText(Path.Combine(destination, "ffmpeg-build", "bin", "ffmpeg.exe")) == "binary", "Safe ZIP is synchronously published");
        Check(File.ReadAllText(Path.Combine(destination, "ffmpeg-build", "doc", "中文.txt"), Encoding.UTF8) == "內容", "Unicode ZIP entry is preserved");

        string[] unsafeNames = new string[] {
            "../escape.txt", "/rooted.txt", "sub/../../escape.txt", "C:/escape.txt",
            "x:stream", "dir\\escape.txt", "tail. ", "dir/CON.txt"
        };
        foreach (string name in unsafeNames)
        {
            fixture = Fixture("unsafe-entry");
            zip = Path.Combine(fixture, "bad.zip");
            destination = Path.Combine(fixture, "extract");
            CreateZip(zip, new ZipItem(name, "bad"));
            Reject(delegate { BootstrapAssets.ExtractArchive(fixture, zip, destination, delegate { return false; }); }, "Unsafe ZIP entry is rejected: " + name);
            Check(!Directory.Exists(destination), "Unsafe ZIP never publishes a destination: " + name);
        }

        fixture = Fixture("case-collision");
        zip = Path.Combine(fixture, "bad.zip");
        destination = Path.Combine(fixture, "extract");
        CreateZip(zip, new ZipItem("Same.txt", "one"), new ZipItem("same.txt", "two"));
        Reject(delegate { BootstrapAssets.ExtractArchive(fixture, zip, destination, delegate { return false; }); }, "Case-insensitive ZIP aliases are rejected");

        fixture = Fixture("file-directory-collision");
        zip = Path.Combine(fixture, "bad.zip");
        destination = Path.Combine(fixture, "extract");
        CreateZip(zip, new ZipItem("node", "file"), new ZipItem("node/child.txt", "child"));
        Reject(delegate { BootstrapAssets.ExtractArchive(fixture, zip, destination, delegate { return false; }); }, "File and directory prefix collisions are rejected");

        fixture = Fixture("symbolic-entry");
        zip = Path.Combine(fixture, "bad.zip");
        destination = Path.Combine(fixture, "extract");
        CreateZip(zip, new ZipItem("link", "target", unchecked((int)0xA0000000)));
        Reject(delegate { BootstrapAssets.ExtractArchive(fixture, zip, destination, delegate { return false; }); }, "Symbolic ZIP entry is rejected");

        fixture = Fixture("reparse-entry");
        zip = Path.Combine(fixture, "bad.zip");
        destination = Path.Combine(fixture, "extract");
        CreateZip(zip, new ZipItem("reparse", "target", (int)FileAttributes.ReparsePoint));
        Reject(delegate { BootstrapAssets.ExtractArchive(fixture, zip, destination, delegate { return false; }); }, "DOS reparse ZIP entry is rejected");

        fixture = Fixture("oversize-entry");
        zip = Path.Combine(fixture, "bad.zip");
        destination = Path.Combine(fixture, "extract");
        CreateZip(zip, new ZipItem("large.bin", "tiny"));
        PatchFirstCentralUInt32(zip, 24, 0x80000001);
        Reject(delegate { BootstrapAssets.ExtractArchive(fixture, zip, destination, delegate { return false; }); }, "Entry declaring more than two GiB is rejected before extraction");

        fixture = Fixture("invalid-archive");
        zip = Path.Combine(fixture, "bad.zip");
        destination = Path.Combine(fixture, "extract");
        File.WriteAllText(zip, "not a zip", Encoding.ASCII);
        Reject(delegate { BootstrapAssets.ExtractArchive(fixture, zip, destination, delegate { return false; }); }, "Invalid ZIP stream is rejected");
        Check(!Directory.Exists(destination), "Invalid ZIP stream leaves no partial destination");

        fixture = Fixture("crc-corruption");
        zip = Path.Combine(fixture, "bad.zip");
        destination = Path.Combine(fixture, "extract");
        CreateZip(zip, new ZipItem("ffmpeg.exe", "fixed length fixture"));
        CorruptStoredEntry(zip, "fixed length fixture");
        Reject(delegate { BootstrapAssets.ExtractArchive(fixture, zip, destination, delegate { return false; }); }, "Same-length CRC corruption is rejected");
        Check(!Directory.Exists(destination), "CRC-corrupt ZIP leaves no published destination");

        fixture = Fixture("existing-destination");
        zip = Path.Combine(fixture, "good.zip");
        destination = Path.Combine(fixture, "extract");
        Directory.CreateDirectory(destination);
        File.WriteAllText(Path.Combine(destination, "preserved.txt"), "old");
        CreateZip(zip, new ZipItem("new.txt", "new"));
        Reject(delegate { BootstrapAssets.ExtractArchive(fixture, zip, destination, delegate { return false; }); }, "Existing extraction destination is never overwritten");
        Check(File.ReadAllText(Path.Combine(destination, "preserved.txt")) == "old", "Existing destination survives rejected extraction");

        fixture = Fixture("outside-destination");
        zip = Path.Combine(fixture, "good.zip");
        CreateZip(zip, new ZipItem("ffmpeg.exe", "binary"));
        string outside = Path.Combine(Path.GetDirectoryName(fixture), "outside-extract-" + Guid.NewGuid().ToString("N"));
        Reject(delegate { BootstrapAssets.ExtractArchive(fixture, zip, outside, delegate { return false; }); }, "Extraction destination cannot escape app root");
        Check(!Directory.Exists(outside), "Rejected extraction creates no outside directory");

        fixture = Fixture("cancelled-extraction");
        zip = Path.Combine(fixture, "good.zip");
        destination = Path.Combine(fixture, "extract");
        CreateZip(zip, new ZipItem("ffmpeg.exe", "binary"));
        Reject(delegate { BootstrapAssets.ExtractArchive(fixture, zip, destination, delegate { return true; }); }, "Parent cancellation interrupts extraction");
        Check(!Directory.Exists(destination), "Cancelled extraction never publishes a destination");
        Check(Directory.GetDirectories(fixture, "extract.bootstrap-*.stage").Length == 0, "Cancelled extraction removes its staging directory");
    }

    static void DownloadBoundaryTests()
    {
        string valid = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip";
        Check(BootstrapAssets.ValidateDownloadUri(valid).AbsoluteUri == valid, "Official HTTPS FFmpeg URL is accepted");
        string actualPackage = "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip";
        Reject(delegate { BootstrapAssets.ValidateDownloadUri(actualPackage); }, "Package URL is redirect-only and cannot be a direct user entry");
        foreach (string invalid in new string[] {
            "http://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip",
            "https://evil.example/ffmpeg/builds/ffmpeg-release-essentials.zip",
            "https://www.gyan.dev.evil.example/ffmpeg/builds/ffmpeg-release-essentials.zip",
            "https://user@www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip",
            "https://www.gyan.dev:444/ffmpeg/builds/ffmpeg-release-essentials.zip",
            "https://www.gyan.dev/other/file.zip",
            "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip#fragment"
        }) Reject(delegate { BootstrapAssets.ValidateDownloadUri(invalid); }, "Download URL boundary rejects: " + invalid);

        byte[] package = CreateZipBytes();
        string fixture = Fixture("download-valid");
        string output = Path.Combine(fixture, "ffmpeg.zip");
        string status = Path.Combine(fixture, "progress.txt");
        using (MemoryStream stream = new MemoryStream(package, false))
            BootstrapAssets.PublishDownloadStream(fixture, BootstrapAssets.ValidateDownloadUri(valid), stream, package.Length, output, status, delegate { return false; }, TimeSpan.FromSeconds(5));
        Check(File.Exists(output) && Hash(output) == HashBytes(package), "Complete verified ZIP response is atomically published");

        fixture = Fixture("download-interrupted");
        output = Path.Combine(fixture, "ffmpeg.zip");
        status = Path.Combine(fixture, "progress.txt");
        File.WriteAllText(output, "known-good-old-file");
        string priorHash = Hash(output);
        using (ThrowingStream stream = new ThrowingStream(package, package.Length / 2))
            Reject(delegate { BootstrapAssets.PublishDownloadStream(fixture, BootstrapAssets.ValidateDownloadUri(valid), stream, package.Length, output, status, delegate { return false; }, TimeSpan.FromSeconds(5)); }, "Interrupted network stream is rejected");
        Check(Hash(output) == priorHash, "Interrupted network stream preserves prior output atomically");
        Check(Directory.GetFiles(fixture, "*.partial").Length == 0, "Interrupted network stream removes its partial file");

        fixture = Fixture("download-truncated");
        output = Path.Combine(fixture, "ffmpeg.zip");
        status = Path.Combine(fixture, "progress.txt");
        using (MemoryStream stream = new MemoryStream(package, 0, package.Length - 1, false))
            Reject(delegate { BootstrapAssets.PublishDownloadStream(fixture, BootstrapAssets.ValidateDownloadUri(valid), stream, package.Length, output, status, delegate { return false; }, TimeSpan.FromSeconds(5)); }, "Content-Length mismatch is rejected");
        Check(!File.Exists(output), "Truncated response never creates final output");

        fixture = Fixture("download-invalid-zip");
        output = Path.Combine(fixture, "ffmpeg.zip");
        status = Path.Combine(fixture, "progress.txt");
        byte[] invalidPackage = Encoding.ASCII.GetBytes("not a zip response");
        using (MemoryStream stream = new MemoryStream(invalidPackage, false))
            Reject(delegate { BootstrapAssets.PublishDownloadStream(fixture, BootstrapAssets.ValidateDownloadUri(valid), stream, invalidPackage.Length, output, status, delegate { return false; }, TimeSpan.FromSeconds(5)); }, "Complete but invalid ZIP response is rejected");
        Check(!File.Exists(output), "Invalid ZIP response never creates final output");

        fixture = Fixture("download-cancelled");
        output = Path.Combine(fixture, "ffmpeg.zip");
        status = Path.Combine(fixture, "progress.txt");
        int probes = 0;
        using (ChunkedStream stream = new ChunkedStream(package, 4))
            Reject(delegate { BootstrapAssets.PublishDownloadStream(fixture, BootstrapAssets.ValidateDownloadUri(valid), stream, package.Length, output, status, delegate { probes++; return probes > 3; }, TimeSpan.FromSeconds(5)); }, "Parent cancellation interrupts download");
        Check(!File.Exists(output), "Cancelled download never creates final output");
        Check(Directory.GetFiles(fixture, "*.partial").Length == 0, "Cancelled download removes its partial file");

        fixture = Fixture("download-outside");
        output = Path.Combine(Path.GetDirectoryName(fixture), "outside-download-" + Guid.NewGuid().ToString("N") + ".zip");
        status = Path.Combine(fixture, "progress.txt");
        using (MemoryStream stream = new MemoryStream(package, false))
            Reject(delegate { BootstrapAssets.PublishDownloadStream(fixture, BootstrapAssets.ValidateDownloadUri(valid), stream, package.Length, output, status, delegate { return false; }, TimeSpan.FromSeconds(5)); }, "Download output cannot escape app root");
        Check(!File.Exists(output), "Rejected download creates no outside file");
    }

    static void RedirectPolicyTests()
    {
        string canonical = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip";
        string actualPackage = "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip";
        BootstrapAssets.RedirectPolicy policy = new BootstrapAssets.RedirectPolicy(
            canonical, 5, Stopwatch.StartNew(), TimeSpan.FromSeconds(5));
        Uri next;
        Check(policy.Apply((HttpStatusCode)303, actualPackage, out next), "Actual gyan.dev HTTP 303 is handled as a bounded manual redirect");
        Check(next.AbsoluteUri == actualPackage, "Actual versioned essentials package redirect is accepted");
        Check(!policy.Apply(HttpStatusCode.OK, null, out next), "Validated package HTTP 200 completes redirect handling");
        Check(next.AbsoluteUri == actualPackage, "Final HTTP 200 remains bound to the validated package URL");

        foreach (string target in new string[] {
            "http://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip",
            "https://evil.example/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip",
            "https://www.gyan.dev.evil.example/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip",
            "https://user@www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip",
            "https://www.gyan.dev:444/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip",
            "https://www.gyan.dev/ffmpeg/builds/packages/not-ffmpeg.zip",
            "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-latest-essentials_build.zip",
            "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip?mirror=1",
            "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip#fragment",
            "/ffmpeg/builds/packages/../packages/ffmpeg-9.0.2-essentials_build.zip",
            "/ffmpeg/builds/%2e%2e/packages/ffmpeg-9.0.2-essentials_build.zip"
        })
        {
            string candidate = target;
            Reject(delegate
            {
                BootstrapAssets.RedirectPolicy rejected = new BootstrapAssets.RedirectPolicy(
                    canonical, 5, Stopwatch.StartNew(), TimeSpan.FromSeconds(5));
                Uri ignored;
                rejected.Apply((HttpStatusCode)303, candidate, out ignored);
            }, "Redirect target boundary rejects: " + target);
        }

        policy = new BootstrapAssets.RedirectPolicy(canonical, 5, Stopwatch.StartNew(), TimeSpan.FromSeconds(5));
        policy.Apply((HttpStatusCode)303, actualPackage, out next);
        Reject(delegate { Uri ignored; policy.Apply((HttpStatusCode)303, actualPackage, out ignored); }, "Redirect loop is rejected before another request");

        policy = new BootstrapAssets.RedirectPolicy(canonical, 2, Stopwatch.StartNew(), TimeSpan.FromSeconds(5));
        policy.Apply((HttpStatusCode)303, "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.1-essentials_build.zip", out next);
        policy.Apply((HttpStatusCode)303, "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip", out next);
        Reject(delegate
        {
            Uri ignored;
            policy.Apply((HttpStatusCode)303, "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.3-essentials_build.zip", out ignored);
        }, "Redirect count cannot exceed its explicit bound");

        policy = new BootstrapAssets.RedirectPolicy(canonical, 5, Stopwatch.StartNew(), TimeSpan.Zero);
        Reject(delegate { Uri ignored; policy.Apply((HttpStatusCode)303, actualPackage, out ignored); }, "All redirect hops share and enforce the total deadline");

        policy = new BootstrapAssets.RedirectPolicy(canonical, 5, Stopwatch.StartNew(), TimeSpan.FromMilliseconds(250));
        int requestTimeout = policy.BoundedTimeout(30000);
        Check(requestTimeout > 0 && requestTimeout <= 250, "Each network wait is capped by the shared remaining deadline");
        policy = new BootstrapAssets.RedirectPolicy(canonical, 5, Stopwatch.StartNew(), TimeSpan.Zero);
        Reject(delegate { policy.BoundedTimeout(30000); }, "No network wait starts after the shared deadline expires");
    }

    static string HashBytes(byte[] bytes)
    {
        using (SHA256 sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
    }

    static void CommandLineParentTests(string helper)
    {
        string fixture = Fixture("cli-parent");
        string input = Path.Combine(fixture, "input.bin");
        string output = Path.Combine(fixture, "result.txt");
        File.WriteAllBytes(input, Encoding.ASCII.GetBytes("abc"));
        Process current = Process.GetCurrentProcess();
        long created = current.StartTime.ToUniversalTime().ToFileTimeUtc();
        string parentImage = current.MainModule.FileName;
        string goodArguments = "hash " + Quote(fixture) + " " + Quote(input) + " " + Quote(output) + " " + current.Id + " " + created + " " + Quote(parentImage);
        string stdout;
        string stderr;
        int exitCode = RunBounded(helper, goodArguments, 5000, out stdout, out stderr);
        Check(exitCode == 0, "CLI hash accepts exact live parent identity: " + stdout + stderr);
        Check(File.ReadAllText(output).Trim() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "CLI hash writes verified result");

        File.Delete(output);
        string badArguments = "hash " + Quote(fixture) + " " + Quote(input) + " " + Quote(output) + " " + current.Id + " " + (created + 1) + " " + Quote(parentImage);
        exitCode = RunBounded(helper, badArguments, 5000, out stdout, out stderr);
        Check(exitCode != 0, "Wrong parent creation identity is rejected");
        Check(!File.Exists(output), "Wrong parent cannot write a hash result");
    }

    public static int Main(string[] args)
    {
        try
        {
            if (args.Length != 2) throw new ArgumentException("Expected fixture root and helper executable");
            root = Path.GetFullPath(args[0]);
            Directory.CreateDirectory(root);
            HashTests();
            PortableExecutableInstallTests(Path.GetFullPath(args[1]));
            ExtractionTests();
            DownloadBoundaryTests();
            RedirectPolicyTests();
            CommandLineParentTests(Path.GetFullPath(args[1]));
            Console.WriteLine("PASS native bootstrap assets: " + checks + " checks");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
    }
}
