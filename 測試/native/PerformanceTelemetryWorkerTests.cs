using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Wuthering.Native;

public static class PerformanceTelemetryWorkerTests
{
    static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 1048576, RecursionLimit = 32 };
    static string Root;
    static string Worker;

    static void Check(bool value, string message)
    {
        if (!value) throw new Exception(message);
    }

    static void Equal(object expected, object actual, string message)
    {
        if (!Object.Equals(expected, actual))
            throw new Exception(message + ": expected=" + expected + ", actual=" + actual);
    }

    static void Near(double expected, double actual, double tolerance, string message)
    {
        if (Math.Abs(expected - actual) > tolerance)
            throw new Exception(message + ": expected=" + expected + ", actual=" + actual);
    }

    static bool Until(Func<bool> predicate, int milliseconds)
    {
        Stopwatch watch = Stopwatch.StartNew();
        do { if (predicate()) return true; Thread.Sleep(25); }
        while (watch.ElapsedMilliseconds < milliseconds);
        return false;
    }

    static string Q(string value) { return "\"" + value + "\""; }

    static Dictionary<string, object> ReadObject(string path)
    {
        return Json.DeserializeObject(File.ReadAllText(path, Utf8)) as Dictionary<string, object>;
    }

    static string MakeDirectory(string name)
    {
        string path = Path.Combine(Root, name);
        Directory.CreateDirectory(path);
        return path;
    }

    static Dictionary<string, object> MetricSample(double fps, double cpu, double diskFree)
    {
        return new Dictionary<string, object> {
            {"fps", fps}, {"cpuTotalPct", cpu}, {"gpuPct", 33.0},
            {"gpuVramMb", 4096.0}, {"ramUsedGb", 12.0}, {"diskFreeGb", diskFree},
            {"recordingDroppedFrames", 2.0}
        };
    }

    static void MathAndParsers()
    {
        Equal(null, PerformanceTelemetryMath.Normalize("NaN", 0, 100), "NaN rejected");
        Near(100.0, PerformanceTelemetryMath.Normalize("150.1239", 0, 100).Value, 0.0001, "numbers clamp");
        Near(20.0, PerformanceTelemetryMath.Percentile(new double[] { 10, 20 }, 95).Value, 0.0001, "nearest-rank percentile");
        FpsMetrics single = PerformanceTelemetryMath.Fps(new double[] { 20.0 });
        Near(50.0, single.Fps.Value, 0.0001, "singleton FPS remains a sample");
        Near(20.0, single.FrameTimeP99Ms.Value, 0.0001, "singleton percentile");

        PresentMonCsvParser parser = new PresentMonCsvParser();
        IList<double> frames = parser.Consume(new string[] {
            "noise", "Application,ProcessID,FrameTime,CPUStartTime",
            "Client-Win64-Shipping.exe,10,16.0,1", "Client-Win64-Shipping.exe,10,bad,2",
            "Client-Win64-Shipping.exe,10,20.0,3"
        });
        Equal(2, frames.Count, "valid PresentMon frames retained");
        Near(18.0, PerformanceTelemetryMath.Fps(frames).FrameTimeMs.Value, 0.0001, "frame average");
        Check(PresentMonCsvParser.IsFatal("Access is denied"), "fatal PresentMon stderr detected");
        Check(!PresentMonCsvParser.IsFatal("warning: one frame skipped"), "warning is not fatal");

        StringBuilder lines = new StringBuilder();
        for (int i = 0; i < 150; ++i) lines.Append("line-").Append(i).Append('\n');
        using (BoundedLinePump pump = new BoundedLinePump(new StringReader(lines.ToString()), 100)) {
            Check(pump.WaitForCompletion(2000), "stdout pump completion wait is bounded");
            List<string> drained = pump.Drain(1000);
            Equal(100, drained.Count, "stdout pump remains bounded");
            Equal("line-50", drained[0], "stdout pump discards oldest lines");
            Equal("line-149", drained[99], "stdout pump retains newest line");
        }

        NvidiaMetrics nvidia = NvidiaMetrics.Parse(new string[] { "20, 1000, 70, 100.5, 3", "40, 2000, 80, 120.25, 7" });
        Near(40.0, nvidia.GpuPct.Value, 0.0001, "NVIDIA maximum utilization");
        Near(3000.0, nvidia.GpuVramMb.Value, 0.0001, "NVIDIA memory sum");
        Near(220.75, nvidia.GpuPowerW.Value, 0.0001, "NVIDIA power sum");
        NvidiaMetrics partial = NvidiaMetrics.Parse(new string[] { "20, 1000, 70, N/A, 3", "40, 2000, N/A, 120, 7" });
        Near(40.0, partial.GpuPct.Value, 0.0001, "partial NVIDIA rows retain utilization");
        Near(3000.0, partial.GpuVramMb.Value, 0.0001, "partial NVIDIA rows retain memory");
        Near(70.0, partial.GpuTempC.Value, 0.0001, "partial NVIDIA rows retain available temperature");
        Near(120.0, partial.GpuPowerW.Value, 0.0001, "partial NVIDIA rows retain available power");
    }

    static void FfmpegAndMinutes()
    {
        string directory = MakeDirectory("unit");
        string progress = Path.Combine(directory, "recording_progress.txt");
        File.WriteAllText(progress, "fps=29.97\ndrop_frames=4\ndup_frames=2\nspeed=0.99x\nprogress=continue\n", Utf8);
        DateTime now = DateTime.UtcNow;
        File.SetLastWriteTimeUtc(progress, now.AddSeconds(-2));
        FfmpegProgress active = FfmpegProgress.Read(progress, now);
        Check(active.Active, "fresh FFmpeg progress is active");
        Near(29.97, active.Fps.Value, 0.0001, "FFmpeg FPS parsed");
        Equal("0.99x", active.Speed, "FFmpeg speed parsed");
        File.SetLastWriteTimeUtc(progress, now.AddSeconds(-20));
        Check(!FfmpegProgress.Read(progress, now).Active, "stale FFmpeg progress inactive");
        Equal(null, FfmpegProgress.Read(Path.Combine(directory, "missing.txt"), now).Speed, "Missing FFmpeg speed is null, not empty text");
        File.WriteAllText(progress, "fps=30\n", Utf8);
        FfmpegProgress noSpeed = FfmpegProgress.Read(progress, now);
        Equal(null, noSpeed.Speed, "Absent speed key is null");
        using (FileStream locked = new FileStream(progress, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) {
            Equal(null, FfmpegProgress.Read(progress, now).Speed, "Unreadable FFmpeg speed is null");
        }
        string speedJson = PerformanceTelemetryProtocol.Serialize(new Dictionary<string, object> {
            {"recordingSpeed", noSpeed.Speed}, {"liveSpeed", noSpeed.Speed}
        });
        Check(speedJson.Contains("\"recordingSpeed\":null") && speedJson.Contains("\"liveSpeed\":null"), "Unknown speed preserves JSON null schema");

        MinuteAccumulator minute = new MinuteAccumulator(180000L, PerformanceTelemetryProtocol.MetricNames);
        minute.Add(MetricSample(60, 10, 500));
        minute.Add(MetricSample(30, 90, 450));
        Dictionary<string, object> complete = minute.Complete();
        Equal(2, complete["sampleCount"], "minute sample count");
        Dictionary<string, object> metrics = (Dictionary<string, object>)complete["metrics"];
        Near(45.0, Convert.ToDouble(metrics["fps"], CultureInfo.InvariantCulture), 0.0001, "minute FPS average");
        Near(30.0, Convert.ToDouble(metrics["fpsMin"], CultureInfo.InvariantCulture), 0.0001, "minute FPS minimum");
        Near(90.0, Convert.ToDouble(metrics["cpuTotalPctMax"], CultureInfo.InvariantCulture), 0.0001, "minute maximum");
        Near(450.0, Convert.ToDouble(metrics["diskFreeGbMin"], CultureInfo.InvariantCulture), 0.0001, "disk free minimum");
        Check(metrics.ContainsKey("gpuVramMbMax"), "GPU VRAM maximum uses legacy case-insensitive suffix rule");

        string minutes = Path.Combine(directory, "minutes.ndjson");
        long nowMs = PerformanceTelemetryProtocol.UnixMilliseconds(DateTimeOffset.UtcNow);
        for (int i = 0; i < 65; ++i) {
            Dictionary<string, object> row = new Dictionary<string, object> {
                {"bucketStart", nowMs - (64 - i) * 60000L}, {"sampleCount", 1},
                {"metrics", new Dictionary<string, object> {{"fps", (double)i}}}
            };
            File.AppendAllText(minutes, PerformanceTelemetryProtocol.Serialize(row) + "\n", Utf8);
        }
        List<Dictionary<string, object>> history = PerformanceTelemetryProtocol.LoadMinuteHistory(minutes, 60);
        Equal(60, history.Count, "minute history tail bounded");
        Dictionary<string, object> heartbeat = PerformanceTelemetryProtocol.BuildHeartbeat(
            PerformanceTelemetryProtocol.Collector("running", nowMs, 2, "capturing", true, true, ""),
            MetricSample(55, 22, 444), history);
        Equal(10, ((object[])heartbeat["minutes"]).Length, "heartbeat keeps ten minutes");
        Dictionary<string, object> firestore = PerformanceTelemetryProtocol.BuildFirestore(
            (Dictionary<string, object>)heartbeat["collector"], MetricSample(55, 22, 444), history);
        Equal(60, ((object[])firestore["points"]).Length, "Firestore keeps sixty points");
        string serialized = PerformanceTelemetryProtocol.Serialize(firestore);
        Check(serialized.Contains("\"schemaVersion\":1"), "Firestore schema version preserved");

        string oldRaw = Path.Combine(directory, "raw_20000101.ndjson");
        string recentRaw = Path.Combine(directory, "raw_recent.ndjson");
        File.WriteAllText(oldRaw, "{}\n", Utf8); File.WriteAllText(recentRaw, "{}\n", Utf8);
        File.SetLastWriteTimeUtc(oldRaw, now.AddHours(-27)); File.SetLastWriteTimeUtc(recentRaw, now);
        PerformanceTelemetryProtocol.PruneLocal(directory, minutes, nowMs - 24L * 60L * 60L * 1000L, now);
        Check(!File.Exists(oldRaw) && File.Exists(recentRaw), "raw retention is bounded");
        foreach (Dictionary<string, object> row in PerformanceTelemetryProtocol.LoadMinuteHistory(minutes, 100))
            Check(Convert.ToInt64(row["bucketStart"], CultureInfo.InvariantCulture) >= nowMs - 24L * 60L * 60L * 1000L,
                "minute retention removes old rows");

        string largeMinutes = Path.Combine(directory, "large-minutes.ndjson");
        Dictionary<string, object> largeRow = new Dictionary<string, object> {
            {"bucketStart", nowMs}, {"sampleCount", 1},
            {"metrics", new Dictionary<string, object> {{"fps", 60.0}}},
            {"padding", new string('x', 900)}
        };
        string largeLine = PerformanceTelemetryProtocol.Serialize(largeRow) + "\n";
        StringBuilder large = new StringBuilder(largeLine.Length * 1400);
        for (int i = 0; i < 1400; ++i) large.Append(largeLine);
        File.WriteAllText(largeMinutes, large.ToString(), Utf8);
        Check(new FileInfo(largeMinutes).Length > 1048576, "large minute fixture exceeds snapshot limit");
        PerformanceTelemetryProtocol.PruneLocal(directory, largeMinutes, nowMs - 60000, now);
        Check(new FileInfo(largeMinutes).Length > 1048576, "valid 24-hour minute history is not truncated at snapshot limit");
    }

    static string WorkerArguments(string output, int parentPid, long parentCreated, string parentExe,
        string fixture, int samples, int intervalMilliseconds, int ownershipWaitMilliseconds)
    {
        return "-OutputRoot " + Q(output) +
            " -ParentPid " + parentPid.ToString(CultureInfo.InvariantCulture) +
            " -ParentCreationFileTime " + parentCreated.ToString(CultureInfo.InvariantCulture) +
            " -ParentExe " + Q(parentExe) +
            " -SampleIntervalSeconds 2" +
            " -TestFixturePath " + Q(fixture) +
            " -TestMaxSamples " + samples.ToString(CultureInfo.InvariantCulture) +
            " -TestSampleIntervalMilliseconds " + intervalMilliseconds.ToString(CultureInfo.InvariantCulture) +
            " -OwnershipWaitMilliseconds " + ownershipWaitMilliseconds.ToString(CultureInfo.InvariantCulture);
    }

    static string WriteFixture(string directory)
    {
        string path = Path.Combine(directory, "fixture.json");
        string json = "{" +
            "\"frames\":[16,20],\"presentMonState\":\"capturing\",\"presentMonError\":\"\"," +
            "\"current\":{" +
            "\"cpuTotalPct\":25,\"cpuGamePct\":10,\"gpuPct\":40,\"gpuVramMb\":4096," +
            "\"ramUsedGb\":12.5,\"ramTotalGb\":32,\"diskReadMbps\":2,\"diskWriteMbps\":3," +
            "\"diskFreeGb\":444,\"networkDownMbps\":4,\"networkUpMbps\":5," +
            "\"recordingActive\":true,\"recordingFps\":30,\"recordingDroppedFrames\":1," +
            "\"liveActive\":false,\"gameRunning\":true,\"okwwRunning\":true," +
            "\"lrmcRunning\":true,\"ffmpegCount\":1}}";
        File.WriteAllText(path, json, Utf8);
        return path;
    }

    static Process StartWorker(string output, string fixture, int samples, int intervalMilliseconds, int ownershipWaitMilliseconds)
    {
        using (Process parent = Process.GetCurrentProcess()) {
            string args = WorkerArguments(output, parent.Id, parent.StartTime.ToUniversalTime().ToFileTimeUtc(),
                parent.MainModule.FileName, fixture, samples, intervalMilliseconds, ownershipWaitMilliseconds);
            return Process.Start(new ProcessStartInfo(Worker, args) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
                RedirectStandardError = true, WorkingDirectory = output
            });
        }
    }

    static void ParentAndLoop()
    {
        using (Process self = Process.GetCurrentProcess()) {
            long created = self.StartTime.ToUniversalTime().ToFileTimeUtc();
            string image = self.MainModule.FileName;
            using (PerformanceTelemetryWorker.ParentLease parent = PerformanceTelemetryWorker.ParentLease.Open(self.Id, created, image))
                Check(parent != null && parent.Alive, "parent exact PID, creation and image retained");
            using (PerformanceTelemetryWorker.ParentLease parent = PerformanceTelemetryWorker.ParentLease.Open(self.Id, created - 1, image))
                Check(parent == null, "wrong parent creation rejected");
            using (PerformanceTelemetryWorker.ParentLease parent = PerformanceTelemetryWorker.ParentLease.Open(self.Id, created, image + ".other"))
                Check(parent == null, "wrong parent executable rejected");
        }

        string output = MakeDirectory("loop");
        string fixture = WriteFixture(output);
        using (Process worker = StartWorker(output, fixture, 2, 75, 200)) {
            Check(worker.WaitForExit(6000), "bounded native loop exits");
            Equal(0, worker.ExitCode, "native loop exit: " + worker.StandardError.ReadToEnd());
        }
        string heartbeatPath = Path.Combine(output, "heartbeat.json");
        string firestorePath = Path.Combine(output, "firestore.json");
        Check(File.Exists(heartbeatPath) && File.Exists(firestorePath), "protocol snapshots written");
        Dictionary<string, object> heartbeat = ReadObject(heartbeatPath);
        Dictionary<string, object> collector = (Dictionary<string, object>)heartbeat["collector"];
        Dictionary<string, object> current = (Dictionary<string, object>)heartbeat["current"];
        Equal("running", collector["state"], "synthetic valid frames yield running collector");
        Equal("capturing", collector["presentMon"], "synthetic PresentMon boundary used");
        Near(55.556, Convert.ToDouble(current["fps"], CultureInfo.InvariantCulture), 0.001, "loop writes FPS");
        Near(25.0, Convert.ToDouble(current["cpuTotalPct"], CultureInfo.InvariantCulture), 0.001, "FPS does not erase other metrics");
        Check(File.ReadAllText(Path.Combine(output, "raw_" + DateTime.Now.ToString("yyyyMMdd") + ".ndjson"), Utf8).Contains("\"recordingActive\":true"),
            "raw loop includes FFmpeg metrics");

        string exclusive = MakeDirectory("exclusive");
        string exclusiveFixture = WriteFixture(exclusive);
        using (Process first = StartWorker(exclusive, exclusiveFixture, 100, 50, 200)) {
            try {
                Check(Until(delegate { return File.Exists(Path.Combine(exclusive, "heartbeat.json")); }, 3000), "first writer starts");
                using (Process second = StartWorker(exclusive, exclusiveFixture, 1, 50, 200)) {
                    Check(second.WaitForExit(3000), "second writer refusal is bounded");
                    Equal(2, second.ExitCode, "second writer cannot own same output");
                }
            } finally {
                File.WriteAllText(Path.Combine(exclusive, "stop_" + Process.GetCurrentProcess().Id + ".flag"), "stop", Utf8);
                if (!first.WaitForExit(4000)) { first.Kill(); first.WaitForExit(); throw new Exception("owned worker did not stop"); }
            }
            Equal(0, first.ExitCode, "owned writer stops cleanly: " + first.StandardError.ReadToEnd());
        }
    }

    static int TemporaryParent(string root, string workerPath)
    {
        Root = Path.GetFullPath(root); Worker = Path.GetFullPath(workerPath);
        string output = MakeDirectory("parent-death");
        string fixture = WriteFixture(output);
        Process child = StartWorker(output, fixture, 1000, 50, 200);
        if (!Until(delegate { return File.Exists(Path.Combine(output, "heartbeat.json")); }, 3000)) {
            try { child.Kill(); } catch {}
            child.Dispose();
            throw new Exception("temporary parent never observed a running child");
        }
        File.WriteAllText(Path.Combine(output, "child-pid.txt"), child.Id.ToString(CultureInfo.InvariantCulture), Utf8);
        child.Dispose();
        return 0;
    }

    static void ParentDeath()
    {
        string output = Path.Combine(Root, "parent-death");
        string helperArgs = "--temporary-parent " + Q(Root) + " " + Q(Worker);
        using (Process parent = Process.Start(new ProcessStartInfo(typeof(PerformanceTelemetryWorkerTests).Assembly.Location, helperArgs) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true
        })) {
            Check(parent.WaitForExit(3000) && parent.ExitCode == 0, "temporary parent exits: " + parent.StandardError.ReadToEnd());
        }
        string pidPath = Path.Combine(output, "child-pid.txt");
        Check(File.Exists(pidPath), "temporary parent records child PID");
        int pid = Int32.Parse(File.ReadAllText(pidPath), CultureInfo.InvariantCulture);
        Process orphan = null;
        try {
            orphan = Process.GetProcessById(pid);
            Check(Until(delegate { try { return orphan.HasExited; } catch { return true; } }, 4000),
                "worker exits promptly when retained parent handle signals");
        } catch (ArgumentException) {
            return;
        } finally {
            if (orphan != null) {
                if (!orphan.HasExited) orphan.Kill();
                orphan.Dispose();
            }
        }
    }

    public static int Main(string[] args)
    {
        try {
            if (args.Length == 3 && args[0] == "--temporary-parent")
                return TemporaryParent(args[1], args[2]);
            if (args.Length != 2) throw new ArgumentException("Expected test root and worker executable");
            Root = Path.GetFullPath(args[0]); Worker = Path.GetFullPath(args[1]);
            if (Directory.Exists(Root)) Directory.Delete(Root, true);
            Directory.CreateDirectory(Root);
            MathAndParsers();
            FfmpegAndMinutes();
            ParentAndLoop();
            ParentDeath();
            Console.WriteLine("PASS: PerformanceTelemetry native math, parsers, protocol, ownership and lifecycle");
            return 0;
        } catch (Exception error) {
            Console.Error.WriteLine("FAIL: " + error);
            return 1;
        }
    }
}
