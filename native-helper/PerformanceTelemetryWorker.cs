using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Wuthering.Native
{
    public sealed class PerformanceTelemetryOptions
    {
        public string OutputRoot { get; private set; }
        public int ParentPid { get; private set; }
        public long ParentCreationFileTime { get; private set; }
        public string ParentExe { get; private set; }
        public int SampleIntervalSeconds { get; private set; }
        public string ConfigPath { get; private set; }
        public string TestFixturePath { get; private set; }
        public int TestMaxSamples { get; private set; }
        public int TestSampleIntervalMilliseconds { get; private set; }
        public int OwnershipWaitMilliseconds { get; private set; }

        public bool TestMode { get { return !String.IsNullOrEmpty(TestFixturePath); } }

        public static PerformanceTelemetryOptions Parse(string[] args)
        {
            if (args == null || args.Length == 0 || (args.Length % 2) != 0)
                throw new ArgumentException("Expected named argument pairs");
            string[] allowed = {
                "-OutputRoot", "-ParentPid", "-ParentCreationFileTime", "-ParentExe",
                "-SampleIntervalSeconds", "-ConfigPath", "-TestFixturePath", "-TestMaxSamples",
                "-TestSampleIntervalMilliseconds", "-OwnershipWaitMilliseconds"
            };
            Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.Ordinal);
            for (int i = 0; i < args.Length; i += 2) {
                if (Array.IndexOf(allowed, args[i]) < 0 || values.ContainsKey(args[i]))
                    throw new ArgumentException("Invalid or duplicate telemetry argument: " + args[i]);
                values.Add(args[i], args[i + 1]);
            }
            foreach (string required in new string[] { "-OutputRoot", "-ParentPid", "-ParentCreationFileTime", "-ParentExe", "-SampleIntervalSeconds" })
                if (!values.ContainsKey(required)) throw new ArgumentException("Missing telemetry argument: " + required);
            PerformanceTelemetryOptions options = new PerformanceTelemetryOptions();
            options.OutputRoot = FullPath(values["-OutputRoot"], "OutputRoot").TrimEnd(Path.DirectorySeparatorChar);
            if (String.Equals(options.OutputRoot, Path.GetPathRoot(options.OutputRoot), StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("OutputRoot cannot be a volume root");
            options.ParentPid = ParseInt(values["-ParentPid"], "ParentPid", 1, Int32.MaxValue);
            options.ParentCreationFileTime = ParseLong(values["-ParentCreationFileTime"], "ParentCreationFileTime", 1, Int64.MaxValue);
            options.ParentExe = FullPath(values["-ParentExe"], "ParentExe");
            options.SampleIntervalSeconds = ParseInt(values["-SampleIntervalSeconds"], "SampleIntervalSeconds", Int32.MinValue, Int32.MaxValue);
            options.SampleIntervalSeconds = Math.Max(2, Math.Min(10, options.SampleIntervalSeconds));
            options.ConfigPath = values.ContainsKey("-ConfigPath") ? values["-ConfigPath"] : String.Empty;
            options.OwnershipWaitMilliseconds = values.ContainsKey("-OwnershipWaitMilliseconds")
                ? ParseInt(values["-OwnershipWaitMilliseconds"], "OwnershipWaitMilliseconds", 0, 20000) : 20000;

            bool fixture = values.ContainsKey("-TestFixturePath");
            bool samples = values.ContainsKey("-TestMaxSamples");
            bool interval = values.ContainsKey("-TestSampleIntervalMilliseconds");
            if (fixture || samples || interval) {
                if (!(fixture && samples && interval)) throw new ArgumentException("All test fixture arguments are required together");
                options.TestFixturePath = FullPath(values["-TestFixturePath"], "TestFixturePath");
                string prefix = options.OutputRoot + Path.DirectorySeparatorChar;
                if (!options.TestFixturePath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                    throw new ArgumentException("TestFixturePath must be inside OutputRoot");
                options.TestMaxSamples = ParseInt(values["-TestMaxSamples"], "TestMaxSamples", 1, 10000);
                options.TestSampleIntervalMilliseconds = ParseInt(values["-TestSampleIntervalMilliseconds"],
                    "TestSampleIntervalMilliseconds", 25, 1000);
            } else {
                options.TestFixturePath = String.Empty; options.TestMaxSamples = 0; options.TestSampleIntervalMilliseconds = 0;
            }
            return options;
        }

        static string FullPath(string value, string name)
        {
            if (String.IsNullOrWhiteSpace(value) || !Path.IsPathRooted(value)) throw new ArgumentException(name + " must be absolute");
            return Path.GetFullPath(value);
        }

        static int ParseInt(string value, string name, int minimum, int maximum)
        {
            int parsed;
            if (!Int32.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out parsed) || parsed < minimum || parsed > maximum)
                throw new ArgumentException("Invalid " + name);
            return parsed;
        }

        static long ParseLong(string value, string name, long minimum, long maximum)
        {
            long parsed;
            if (!Int64.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out parsed) || parsed < minimum || parsed > maximum)
                throw new ArgumentException("Invalid " + name);
            return parsed;
        }
    }

    public static class PerformanceTelemetryWorker
    {
        const uint WaitObject0 = 0;
        const uint WaitTimeout = 258;

        public sealed class ParentLease : IDisposable
        {
            IntPtr handle;
            ParentLease(IntPtr value) { handle = value; }

            public bool Alive { get { return handle != IntPtr.Zero && WaitForSingleObject(handle, 0) == WaitTimeout; } }

            public static ParentLease Open(int pid, long creationFileTime, string executable)
            {
                if (pid <= 0 || creationFileTime <= 0 || String.IsNullOrWhiteSpace(executable)) return null;
                IntPtr process = OpenProcess(0x101000, false, pid);
                if (process == IntPtr.Zero) return null;
                try {
                    long created, exited, kernel, user;
                    if (!GetProcessTimes(process, out created, out exited, out kernel, out user) ||
                        created != creationFileTime || WaitForSingleObject(process, 0) != WaitTimeout) return null;
                    uint length = 32768; StringBuilder path = new StringBuilder((int)length);
                    if (!QueryFullProcessImageName(process, 0, path, ref length) ||
                        !EqualPath(path.ToString(), executable)) return null;
                    ParentLease lease = new ParentLease(process); process = IntPtr.Zero; return lease;
                } finally { if (process != IntPtr.Zero) CloseHandle(process); }
            }

            public bool WaitWhileAlive(string stopPath, int milliseconds)
            {
                Stopwatch timer = Stopwatch.StartNew();
                while (timer.ElapsedMilliseconds < milliseconds) {
                    if (handle == IntPtr.Zero || WaitForSingleObject(handle, 0) == WaitObject0 || File.Exists(stopPath)) return false;
                    int remaining = milliseconds - (int)timer.ElapsedMilliseconds;
                    uint wait = (uint)Math.Max(1, Math.Min(50, remaining));
                    if (WaitForSingleObject(handle, wait) == WaitObject0 || File.Exists(stopPath)) return false;
                }
                return Alive && !File.Exists(stopPath);
            }

            public void Dispose()
            {
                if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; }
            }
        }

        static bool EqualPath(string first, string second)
        {
            try {
                return String.Equals(NormalizePath(first), NormalizePath(second), StringComparison.OrdinalIgnoreCase);
            } catch { return false; }
        }

        static string NormalizePath(string value)
        {
            string path = value;
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) path = path.Substring(4);
            return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
        }

        static FileStream AcquireOwnership(string lockPath, ParentLease parent, string stopPath,
            int waitMilliseconds, out bool cancelled)
        {
            cancelled = false; Stopwatch timer = Stopwatch.StartNew();
            while (true) {
                if (!parent.Alive) { cancelled = true; return null; }
                try {
                    FileStream ownership = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                    try { if (File.Exists(stopPath)) File.Delete(stopPath); }
                    catch { ownership.Dispose(); throw; }
                    return ownership;
                } catch (IOException) {
                    if (File.Exists(stopPath)) { cancelled = true; return null; }
                    if (timer.ElapsedMilliseconds >= waitMilliseconds) return null;
                    Thread.Sleep(50);
                }
            }
        }

        public static int Run(PerformanceTelemetryOptions options)
        {
            using (ParentLease parent = ParentLease.Open(options.ParentPid, options.ParentCreationFileTime, options.ParentExe)) {
                if (parent == null || !parent.Alive) return 0;
                Directory.CreateDirectory(options.OutputRoot);
                string heartbeatPath = Path.Combine(options.OutputRoot, "heartbeat.json");
                string firestorePath = Path.Combine(options.OutputRoot, "firestore.json");
                string minutesPath = Path.Combine(options.OutputRoot, "minutes.ndjson");
                string stopPath = Path.Combine(options.OutputRoot, "stop_" + options.ParentPid.ToString(CultureInfo.InvariantCulture) + ".flag");
                string lockPath = Path.Combine(options.OutputRoot, "worker.lock");
                bool cancelled;
                FileStream ownership = AcquireOwnership(lockPath, parent, stopPath, options.OwnershipWaitMilliseconds, out cancelled);
                if (ownership == null) return cancelled ? 0 : 2;
                using (ownership) {
                    IPerformanceTelemetryCollector collector = null;
                    List<Dictionary<string, object>> history = new List<Dictionary<string, object>>();
                    string workerError = String.Empty;
                    try {
                        try { using (Process self = Process.GetCurrentProcess()) self.PriorityClass = ProcessPriorityClass.BelowNormal; } catch {}
                        history = PerformanceTelemetryProtocol.LoadMinuteHistory(minutesPath, 60);
                        collector = options.TestMode
                            ? (IPerformanceTelemetryCollector)new FixturePerformanceTelemetryCollector(options.TestFixturePath)
                            : new NativePerformanceTelemetryCollector(options.OutputRoot, delegate { return parent.Alive && !File.Exists(stopPath); });
                        long startupAt = PerformanceTelemetryProtocol.UnixMilliseconds(DateTimeOffset.UtcNow);
                        Dictionary<string, object> startupCollector = PerformanceTelemetryProtocol.Collector(
                            "starting", startupAt, options.SampleIntervalSeconds, "starting", false,
                            collector.NvidiaTelemetryAvailable, String.Empty);
                        PerformanceTelemetryProtocol.AtomicWrite(heartbeatPath, PerformanceTelemetryProtocol.Serialize(
                            PerformanceTelemetryProtocol.BuildHeartbeat(startupCollector, null, history)));
                        PerformanceTelemetryProtocol.AtomicWrite(firestorePath, PerformanceTelemetryProtocol.Serialize(
                            PerformanceTelemetryProtocol.BuildFirestore(startupCollector, null, history)));
                        string errorLog = Path.Combine(options.OutputRoot, "collector_error.log");
                        if (File.Exists(errorLog)) File.Delete(errorLog);

                        MinuteAccumulator minute = null;
                        DateTimeOffset lastSampleAt = DateTimeOffset.UtcNow;
                        DateTimeOffset lastPruneAt = DateTimeOffset.MinValue;
                        int sampleCount = 0;
                        while (parent.Alive && !File.Exists(stopPath)) {
                            Stopwatch work = Stopwatch.StartNew();
                            DateTimeOffset now = DateTimeOffset.UtcNow;
                            long nowMs = PerformanceTelemetryProtocol.UnixMilliseconds(now);
                            double elapsedSeconds = Math.Max(0.25, (now - lastSampleAt).TotalSeconds);
                            lastSampleAt = now;
                            long bucketStart = (nowMs / 60000L) * 60000L;
                            if (minute == null) minute = new MinuteAccumulator(bucketStart, PerformanceTelemetryProtocol.MetricNames);
                            else if (minute.BucketStart != bucketStart) {
                                Dictionary<string, object> completed = minute.Complete();
                                PerformanceTelemetryProtocol.AppendLine(minutesPath, completed);
                                history.Add(completed); while (history.Count > 60) history.RemoveAt(0);
                                minute = new MinuteAccumulator(bucketStart, PerformanceTelemetryProtocol.MetricNames);
                            }

                            TelemetryCycle cycle = collector.Collect(now, elapsedSeconds);
                            Dictionary<string, object> current = cycle.Current ?? new Dictionary<string, object>(StringComparer.Ordinal);
                            current["at"] = nowMs;
                            current["fps"] = cycle.Fps == null ? null : cycle.Fps.Fps;
                            current["fps1Low"] = cycle.Fps == null ? null : cycle.Fps.Fps1Low;
                            current["frameTimeMs"] = cycle.Fps == null ? null : cycle.Fps.FrameTimeMs;
                            current["frameTimeP95Ms"] = cycle.Fps == null ? null : cycle.Fps.FrameTimeP95Ms;
                            current["frameTimeP99Ms"] = cycle.Fps == null ? null : cycle.Fps.FrameTimeP99Ms;
                            minute.Add(current);
                            string rawPath = Path.Combine(options.OutputRoot, "raw_" + DateTime.Now.ToString("yyyyMMdd", CultureInfo.InvariantCulture) + ".ndjson");
                            PerformanceTelemetryProtocol.AppendLine(rawPath, current);

                            string activeError = !String.IsNullOrEmpty(workerError) ? workerError : (cycle.PresentMonError ?? String.Empty);
                            string state = !String.IsNullOrEmpty(activeError) || cycle.PresentMonState == "error" || cycle.PresentMonState == "retry_wait"
                                ? "degraded" : "running";
                            Dictionary<string, object> collectorState = PerformanceTelemetryProtocol.Collector(
                                state, nowMs, options.SampleIntervalSeconds, cycle.PresentMonState,
                                cycle.Fps != null && cycle.Fps.Fps.HasValue, cycle.NvidiaTelemetry, activeError);
                            PerformanceTelemetryProtocol.AtomicWrite(heartbeatPath, PerformanceTelemetryProtocol.Serialize(
                                PerformanceTelemetryProtocol.BuildHeartbeat(collectorState, current, history)));
                            PerformanceTelemetryProtocol.AtomicWrite(firestorePath, PerformanceTelemetryProtocol.Serialize(
                                PerformanceTelemetryProtocol.BuildFirestore(collectorState, current, history)));

                            if ((now - lastPruneAt).TotalHours >= 1) {
                                lastPruneAt = now;
                                try {
                                    PerformanceTelemetryProtocol.PruneLocal(options.OutputRoot, minutesPath,
                                        nowMs - 24L * 60L * 60L * 1000L, now.UtcDateTime);
                                    if (workerError.StartsWith("local retention: ", StringComparison.Ordinal)) workerError = String.Empty;
                                } catch (Exception exception) { workerError = "local retention: " + exception.Message; }
                            }

                            ++sampleCount;
                            if (options.TestMode && sampleCount >= options.TestMaxSamples) break;
                            int intervalMilliseconds = options.TestMode ? options.TestSampleIntervalMilliseconds : options.SampleIntervalSeconds * 1000;
                            int wait = Math.Max(25, intervalMilliseconds - (int)Math.Min(Int32.MaxValue, work.ElapsedMilliseconds));
                            if (!parent.WaitWhileAlive(stopPath, wait)) break;
                        }
                        return 0;
                    } catch (Exception exception) {
                        try { File.WriteAllText(Path.Combine(options.OutputRoot, "collector_error.log"), exception.ToString(), new UTF8Encoding(false)); } catch {}
                        try {
                            Dictionary<string, object> failedCollector = new Dictionary<string, object> {
                                {"state", "error"}, {"version", 1},
                                {"updatedAt", PerformanceTelemetryProtocol.UnixMilliseconds(DateTimeOffset.UtcNow)},
                                {"error", exception.Message}
                            };
                            PerformanceTelemetryProtocol.AtomicWrite(heartbeatPath, PerformanceTelemetryProtocol.Serialize(
                                PerformanceTelemetryProtocol.BuildHeartbeat(failedCollector, null, history)));
                            PerformanceTelemetryProtocol.AtomicWrite(firestorePath, PerformanceTelemetryProtocol.Serialize(
                                PerformanceTelemetryProtocol.BuildFirestore(failedCollector, null, history)));
                        } catch {}
                        return 1;
                    } finally {
                        if (collector != null) collector.Dispose();
                        try { if (File.Exists(stopPath)) File.Delete(stopPath); } catch {}
                    }
                }
            }
        }

        public static int Main(string[] args)
        {
            try { return Run(PerformanceTelemetryOptions.Parse(args)); }
            catch (Exception exception) {
                Console.Error.WriteLine("Performance telemetry worker failed: " + exception.GetType().Name + ": " + exception.Message);
                return 1;
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessTimes(IntPtr handle,
            out long created, out long exited, out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageName(
            IntPtr handle, uint flags, StringBuilder path, ref uint length);
    }
}
