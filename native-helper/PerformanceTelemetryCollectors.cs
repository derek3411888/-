using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Management;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace Wuthering.Native
{
    public sealed class TelemetryCycle
    {
        public Dictionary<string, object> Current { get; set; }
        public string PresentMonState { get; set; }
        public string PresentMonError { get; set; }
        public bool NvidiaTelemetry { get; set; }
        public FpsMetrics Fps { get; set; }
    }

    public interface IPerformanceTelemetryCollector : IDisposable
    {
        bool NvidiaTelemetryAvailable { get; }
        TelemetryCycle Collect(DateTimeOffset now, double elapsedSeconds);
    }

    public sealed class FixturePerformanceTelemetryCollector : IPerformanceTelemetryCollector
    {
        readonly Dictionary<string, object> current;
        readonly List<double> frames;
        readonly string state;
        readonly string error;
        readonly bool nvidia;

        public FixturePerformanceTelemetryCollector(string path)
        {
            if (String.IsNullOrEmpty(path) || !File.Exists(path)) throw new FileNotFoundException("Telemetry fixture missing", path);
            FileInfo info = new FileInfo(path);
            if (info.Length > 65536) throw new InvalidDataException("Telemetry fixture too large");
            Dictionary<string, object> fixture = PerformanceTelemetryProtocol.DeserializeObject(File.ReadAllText(path, Encoding.UTF8));
            if (fixture == null) throw new InvalidDataException("Telemetry fixture must be an object");
            object value;
            current = fixture.TryGetValue("current", out value) ? value as Dictionary<string, object> : null;
            if (current == null) throw new InvalidDataException("Telemetry fixture current missing");
            frames = new List<double>();
            object[] array = fixture.TryGetValue("frames", out value) ? value as object[] : null;
            if (array != null) foreach (object item in array) {
                double? number = PerformanceTelemetryMath.Normalize(item, 0.01, 10000);
                if (number.HasValue) frames.Add(number.Value);
            }
            state = fixture.TryGetValue("presentMonState", out value) ? Convert.ToString(value, CultureInfo.InvariantCulture) : "capturing";
            error = fixture.TryGetValue("presentMonError", out value) ? Convert.ToString(value, CultureInfo.InvariantCulture) : String.Empty;
            nvidia = fixture.TryGetValue("nvidiaTelemetry", out value) && Convert.ToBoolean(value, CultureInfo.InvariantCulture);
        }

        public TelemetryCycle Collect(DateTimeOffset now, double elapsedSeconds)
        {
            Dictionary<string, object> copy = new Dictionary<string, object>(current, StringComparer.Ordinal);
            return new TelemetryCycle {
                Current = copy, PresentMonState = state, PresentMonError = error,
                NvidiaTelemetry = nvidia, Fps = PerformanceTelemetryMath.Fps(frames)
            };
        }

        public bool NvidiaTelemetryAvailable { get { return nvidia; } }

        public void Dispose() {}
    }

    public sealed class ProcessTelemetrySnapshot
    {
        public int Count { get; set; }
        public double CpuSeconds { get; set; }
        public long WorkingSet { get; set; }

        public static ProcessTelemetrySnapshot Capture(string processName)
        {
            ProcessTelemetrySnapshot snapshot = new ProcessTelemetrySnapshot();
            Process[] processes;
            try { processes = Process.GetProcessesByName(processName); }
            catch { return snapshot; }
            foreach (Process process in processes) using (process) {
                try { snapshot.CpuSeconds += process.TotalProcessorTime.TotalSeconds; } catch {}
                try { snapshot.WorkingSet += process.WorkingSet64; } catch {}
                ++snapshot.Count;
            }
            return snapshot;
        }
    }

    public sealed class NativePerformanceTelemetryCollector : IPerformanceTelemetryCollector
    {
        readonly string outputRoot;
        readonly Func<bool> alive;
        readonly PresentMonSession presentMon;
        readonly Dictionary<string, double> previousProcessCpu = new Dictionary<string, double>(StringComparer.Ordinal);
        readonly Dictionary<string, object> extended = new Dictionary<string, object>(StringComparer.Ordinal);
        DateTimeOffset lastExtendedAt = DateTimeOffset.MinValue;
        DateTimeOffset lastNvidiaAt = DateTimeOffset.MinValue;
        DateTimeOffset lastPresentAttempt = DateTimeOffset.MinValue;
        DateTimeOffset lastPresentFrameAt = DateTimeOffset.MinValue;
        NvidiaMetrics nvidia = new NvidiaMetrics();
        string nvidiaSmi;
        string presentMonState = "starting";
        string lastCollectorError = String.Empty;

        public NativePerformanceTelemetryCollector(string root, Func<bool> parentAlive)
        {
            outputRoot = root;
            alive = parentAlive ?? delegate { return true; };
            presentMon = new PresentMonSession(root, alive);
            nvidiaSmi = NvidiaSmi.Find();
        }

        public bool NvidiaTelemetryAvailable { get { return !String.IsNullOrEmpty(nvidiaSmi); } }

        public TelemetryCycle Collect(DateTimeOffset now, double elapsedSeconds)
        {
            ProcessTelemetrySnapshot game = ProcessTelemetrySnapshot.Capture("Client-Win64-Shipping");
            ProcessTelemetrySnapshot okww = ProcessTelemetrySnapshot.Capture("OK-WW");
            ProcessTelemetrySnapshot lrmc = ProcessTelemetrySnapshot.Capture("LRMCAI");
            ProcessTelemetrySnapshot ffmpeg = ProcessTelemetrySnapshot.Capture("ffmpeg");

            if (game.Count > 0) {
                if (presentMon.HasProcess && presentMon.HasExited) {
                    string exitedError = presentMon.ReadStderr();
                    lastCollectorError = "PresentMon exited: " + presentMon.ExitCode.ToString(CultureInfo.InvariantCulture);
                    if (!String.IsNullOrEmpty(exitedError)) lastCollectorError += " (" + exitedError + ")";
                    presentMon.Stop(); presentMonState = "retry_wait";
                }
                bool needsStart = !presentMon.Running;
                bool needsRotate = presentMon.Running && (now - presentMon.StartedAt).TotalMinutes >= 60;
                if ((needsStart || needsRotate) && (now - lastPresentAttempt).TotalMinutes >= 1) {
                    lastPresentAttempt = now;
                    string error;
                    if (presentMon.Start(now, out error)) presentMonState = "starting";
                    else { presentMonState = "error"; lastCollectorError = error; }
                }
            } else {
                presentMon.Stop(); presentMonState = "waiting_game";
                lastPresentFrameAt = DateTimeOffset.MinValue; lastCollectorError = String.Empty;
            }

            FpsMetrics fps;
            try { fps = PerformanceTelemetryMath.Fps(presentMon.ReadFrames()); }
            catch (Exception exception) {
                lastCollectorError = "PresentMon FPS: " + exception.Message;
                presentMon.Stop(); presentMonState = "retry_wait"; fps = new FpsMetrics();
            }
            string presentError = presentMon.ReadStderr();
            if (fps.Fps.HasValue) {
                lastPresentFrameAt = now; lastCollectorError = String.Empty; presentMonState = "capturing";
            } else if (presentMonState == "error" || PresentMonCsvParser.IsFatal(presentError)) {
                if (presentMonState != "error") lastCollectorError = "PresentMon: " + presentError;
                presentMon.Stop(); presentMonState = "retry_wait";
            } else if (presentMon.Running) {
                DateTimeOffset reference = lastPresentFrameAt > DateTimeOffset.MinValue ? lastPresentFrameAt : presentMon.StartedAt;
                if ((now - reference).TotalSeconds >= 30) {
                    lastCollectorError = "PresentMon: 30 seconds without valid FrameTime; collector restarted";
                    presentMon.Stop(); presentMonState = "retry_wait";
                }
            }

            if ((now - lastExtendedAt).TotalSeconds >= 4) {
                lastExtendedAt = now;
                foreach (KeyValuePair<string, object> item in NativeSystemMetrics.Read(outputRoot)) extended[item.Key] = item.Value;
            }
            if (!String.IsNullOrEmpty(nvidiaSmi) && (now - lastNvidiaAt).TotalSeconds >= 10) {
                lastNvidiaAt = now;
                try { nvidia = NvidiaSmi.Query(nvidiaSmi, alive, 3000); }
                catch { nvidiaSmi = String.Empty; nvidia = new NvidiaMetrics(); }
            }

            FfmpegProgress recording = FfmpegProgress.Read(Path.Combine(outputRoot, "recording_progress.txt"), now.UtcDateTime);
            FfmpegProgress live = FfmpegProgress.Read(Path.Combine(outputRoot, "live_progress.txt"), now.UtcDateTime);
            Dictionary<string, object> current = new Dictionary<string, object>(StringComparer.Ordinal) {
                {"fps", fps.Fps}, {"fps1Low", fps.Fps1Low}, {"frameTimeMs", fps.FrameTimeMs},
                {"frameTimeP95Ms", fps.FrameTimeP95Ms}, {"frameTimeP99Ms", fps.FrameTimeP99Ms},
                {"cpuTotalPct", Value(extended, "cpuTotalPct")},
                {"cpuGamePct", ProcessCpu("game", game, elapsedSeconds)},
                {"cpuOkwwPct", ProcessCpu("okww", okww, elapsedSeconds)},
                {"cpuLrmcPct", ProcessCpu("lrmc", lrmc, elapsedSeconds)},
                {"cpuFfmpegPct", ProcessCpu("ffmpeg", ffmpeg, elapsedSeconds)},
                {"gpuPct", nvidia.GpuPct.HasValue ? (object)nvidia.GpuPct : Value(extended, "gpuPct")},
                {"gpuVramMb", nvidia.GpuVramMb.HasValue ? (object)nvidia.GpuVramMb : Value(extended, "gpuVramMb")},
                {"gpuTempC", nvidia.GpuTempC}, {"gpuPowerW", nvidia.GpuPowerW}, {"gpuEncoderPct", nvidia.GpuEncoderPct},
                {"ramUsedGb", Value(extended, "ramUsedGb")}, {"ramTotalGb", Value(extended, "ramTotalGb")},
                {"gameRamMb", PerformanceTelemetryMath.Normalize((double)game.WorkingSet / 1048576.0, 0, 1000000)},
                {"okwwRamMb", PerformanceTelemetryMath.Normalize((double)okww.WorkingSet / 1048576.0, 0, 1000000)},
                {"lrmcRamMb", PerformanceTelemetryMath.Normalize((double)lrmc.WorkingSet / 1048576.0, 0, 1000000)},
                {"ffmpegRamMb", PerformanceTelemetryMath.Normalize((double)ffmpeg.WorkingSet / 1048576.0, 0, 1000000)},
                {"diskReadMbps", Value(extended, "diskReadMbps")}, {"diskWriteMbps", Value(extended, "diskWriteMbps")},
                {"diskFreeGb", Value(extended, "diskFreeGb")}, {"networkDownMbps", Value(extended, "networkDownMbps")},
                {"networkUpMbps", Value(extended, "networkUpMbps")},
                {"recordingActive", recording.Active}, {"recordingFps", recording.Fps},
                {"recordingDroppedFrames", recording.Dropped}, {"recordingDuplicatedFrames", recording.Duplicated},
                {"recordingSpeed", recording.Speed}, {"liveActive", live.Active}, {"liveFps", live.Fps},
                {"liveDroppedFrames", live.Dropped}, {"liveDuplicatedFrames", live.Duplicated}, {"liveSpeed", live.Speed},
                {"gameRunning", game.Count > 0}, {"okwwRunning", okww.Count > 0}, {"lrmcRunning", lrmc.Count > 0},
                {"ffmpegCount", ffmpeg.Count}
            };
            return new TelemetryCycle {
                Current = current, PresentMonState = presentMonState, PresentMonError = lastCollectorError,
                NvidiaTelemetry = !String.IsNullOrEmpty(nvidiaSmi), Fps = fps
            };
        }

        object Value(Dictionary<string, object> values, string key)
        {
            object result;
            return values.TryGetValue(key, out result) ? result : null;
        }

        double? ProcessCpu(string key, ProcessTelemetrySnapshot snapshot, double elapsedSeconds)
        {
            double previous;
            if (!previousProcessCpu.TryGetValue(key, out previous)) {
                previousProcessCpu[key] = snapshot.CpuSeconds; return null;
            }
            previousProcessCpu[key] = snapshot.CpuSeconds;
            if (elapsedSeconds <= 0) return null;
            return PerformanceTelemetryMath.Normalize((snapshot.CpuSeconds - previous) * 100.0 /
                (elapsedSeconds * Math.Max(1, Environment.ProcessorCount)), 0, 100);
        }

        public void Dispose() { presentMon.Dispose(); }
    }

    static class NativeSystemMetrics
    {
        public static Dictionary<string, object> Read(string outputRoot)
        {
            Dictionary<string, object> values = new Dictionary<string, object>(StringComparer.Ordinal);
            try {
                foreach (ManagementBaseObject row in Query("SELECT PercentProcessorTime FROM Win32_PerfFormattedData_PerfOS_Processor WHERE Name='_Total'")) using (row) {
                    values["cpuTotalPct"] = PerformanceTelemetryMath.Normalize(row["PercentProcessorTime"], 0, 100); break;
                }
            } catch {}
            try {
                foreach (ManagementBaseObject row in Query("SELECT TotalVisibleMemorySize,FreePhysicalMemory FROM Win32_OperatingSystem")) using (row) {
                    double total = Convert.ToDouble(row["TotalVisibleMemorySize"], CultureInfo.InvariantCulture);
                    double free = Convert.ToDouble(row["FreePhysicalMemory"], CultureInfo.InvariantCulture);
                    values["ramTotalGb"] = PerformanceTelemetryMath.Normalize(total / 1048576.0, 0, 10000);
                    values["ramUsedGb"] = PerformanceTelemetryMath.Normalize((total - free) / 1048576.0, 0, 10000); break;
                }
            } catch {}
            try {
                foreach (ManagementBaseObject row in Query("SELECT DiskReadBytesPersec,DiskWriteBytesPersec FROM Win32_PerfFormattedData_PerfDisk_PhysicalDisk WHERE Name='_Total'")) using (row) {
                    values["diskReadMbps"] = PerformanceTelemetryMath.Normalize(
                        Convert.ToDouble(row["DiskReadBytesPersec"], CultureInfo.InvariantCulture) * 8.0 / 1048576.0, 0, 100000);
                    values["diskWriteMbps"] = PerformanceTelemetryMath.Normalize(
                        Convert.ToDouble(row["DiskWriteBytesPersec"], CultureInfo.InvariantCulture) * 8.0 / 1048576.0, 0, 100000); break;
                }
            } catch {}
            try {
                double down = 0, up = 0;
                foreach (ManagementBaseObject row in Query("SELECT BytesReceivedPersec,BytesSentPersec FROM Win32_PerfFormattedData_Tcpip_NetworkInterface")) using (row) {
                    down += Convert.ToDouble(row["BytesReceivedPersec"], CultureInfo.InvariantCulture);
                    up += Convert.ToDouble(row["BytesSentPersec"], CultureInfo.InvariantCulture);
                }
                values["networkDownMbps"] = PerformanceTelemetryMath.Normalize(down * 8.0 / 1048576.0, 0, 100000);
                values["networkUpMbps"] = PerformanceTelemetryMath.Normalize(up * 8.0 / 1048576.0, 0, 100000);
            } catch {}
            try {
                double maximum = 0; bool found = false;
                foreach (ManagementBaseObject row in Query("SELECT UtilizationPercentage FROM Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine")) using (row) {
                    maximum = Math.Max(maximum, Convert.ToDouble(row["UtilizationPercentage"], CultureInfo.InvariantCulture)); found = true;
                }
                if (found) values["gpuPct"] = PerformanceTelemetryMath.Normalize(maximum, 0, 100);
            } catch {}
            try {
                double total = 0; bool found = false;
                foreach (ManagementBaseObject row in Query("SELECT DedicatedUsage FROM Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory")) using (row) {
                    total += Convert.ToDouble(row["DedicatedUsage"], CultureInfo.InvariantCulture); found = true;
                }
                if (found) values["gpuVramMb"] = PerformanceTelemetryMath.Normalize(total / 1048576.0, 0, 1000000);
            } catch {}
            try {
                string root = Path.GetPathRoot(outputRoot);
                DriveInfo drive = new DriveInfo(root);
                values["diskFreeGb"] = PerformanceTelemetryMath.Normalize((double)drive.AvailableFreeSpace / 1073741824.0, 0, 1000000);
            } catch {}
            return values;
        }

        static IEnumerable<ManagementBaseObject> Query(string query)
        {
            List<ManagementBaseObject> rows = new List<ManagementBaseObject>();
            using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(query)) {
                searcher.Options.Timeout = TimeSpan.FromSeconds(2);
                searcher.Options.ReturnImmediately = false;
                searcher.Options.Rewindable = false;
                using (ManagementObjectCollection result = searcher.Get()) {
                    foreach (ManagementBaseObject row in result) rows.Add((ManagementBaseObject)row.Clone());
                }
            }
            return rows;
        }
    }

    static class NvidiaSmi
    {
        public static string Find()
        {
            List<string> candidates = new List<string>();
            string programFiles = Environment.GetEnvironmentVariable("ProgramFiles");
            string windows = Environment.GetEnvironmentVariable("WINDIR");
            if (!String.IsNullOrEmpty(programFiles)) candidates.Add(Path.Combine(programFiles, @"NVIDIA Corporation\NVSMI\nvidia-smi.exe"));
            if (!String.IsNullOrEmpty(windows)) candidates.Add(Path.Combine(windows, @"System32\nvidia-smi.exe"));
            string path = Environment.GetEnvironmentVariable("PATH") ?? String.Empty;
            foreach (string part in path.Split(Path.PathSeparator))
                if (!String.IsNullOrWhiteSpace(part)) candidates.Add(Path.Combine(part.Trim().Trim('"'), "nvidia-smi.exe"));
            foreach (string candidate in candidates) try { if (File.Exists(candidate)) return Path.GetFullPath(candidate); } catch {}
            return String.Empty;
        }

        public static NvidiaMetrics Query(string executable, Func<bool> alive, int timeoutMilliseconds)
        {
            Process process = new Process(); BoundedLinePump output = null, error = null;
            try {
                process.StartInfo = new ProcessStartInfo {
                    FileName = executable,
                    Arguments = "--query-gpu=utilization.gpu,memory.used,temperature.gpu,power.draw,utilization.encoder --format=csv,noheader,nounits",
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
                };
                if (!process.Start()) throw new IOException("nvidia-smi did not start");
                output = new BoundedLinePump(process.StandardOutput, 100); error = new BoundedLinePump(process.StandardError, 100);
                Stopwatch watch = Stopwatch.StartNew();
                while (!process.WaitForExit(50)) {
                    if (!alive() || watch.ElapsedMilliseconds >= timeoutMilliseconds) {
                        try { process.Kill(); } catch {} process.WaitForExit(1000);
                        throw new IOException("nvidia-smi cancelled or timed out");
                    }
                }
                output.WaitForCompletion(500); error.WaitForCompletion(500);
                if (process.ExitCode != 0) throw new IOException("nvidia-smi exit " + process.ExitCode + ": " + String.Join(" | ", error.Drain(20).ToArray()));
                return NvidiaMetrics.Parse(output.Drain(100));
            } finally {
                if (output != null) output.Dispose(); if (error != null) error.Dispose(); process.Dispose();
            }
        }
    }

    sealed class PresentMonSession : IDisposable
    {
        const string Version = "2.5.1";
        const string Url = "https://github.com/GameTechDev/PresentMon/releases/download/v2.5.1/PresentMon-2.5.1-x64.exe";
        const string Sha256 = "9BEC3083069F58F911E6A512F4806DB51A27BD096103087BC1D05EF54C80A191";
        readonly string outputRoot;
        readonly string executable;
        readonly Func<bool> alive;
        Process process;
        BoundedLinePump stdout;
        BoundedLinePump stderr;
        PresentMonCsvParser parser;

        public PresentMonSession(string root, Func<bool> parentAlive)
        {
            outputRoot = root; alive = parentAlive;
            string programRoot = Path.GetDirectoryName(root.TrimEnd(Path.DirectorySeparatorChar));
            executable = Path.Combine(programRoot, "tools", "PresentMon", "PresentMon.exe");
            StartedAt = DateTimeOffset.MinValue;
        }

        public DateTimeOffset StartedAt { get; private set; }
        public bool HasProcess { get { return process != null; } }
        public bool HasExited { get { try { return process == null || process.HasExited; } catch { return true; } } }
        public bool Running { get { return process != null && !HasExited; } }
        public int ExitCode { get { try { return process == null ? -1 : process.ExitCode; } catch { return -1; } } }

        public bool Start(DateTimeOffset now, out string failure)
        {
            failure = String.Empty; Stop();
            try {
                EnsureExecutable();
                Process next = new Process();
                next.StartInfo = new ProcessStartInfo {
                    FileName = executable,
                    Arguments = "--process_name Client-Win64-Shipping.exe --output_stdout --v2_metrics --exclude_dropped --no_console_stats --session_name WutheringAutoPerformance --stop_existing_session",
                    WorkingDirectory = outputRoot, UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true, WindowStyle = ProcessWindowStyle.Hidden
                };
                if (!next.Start()) throw new IOException("PresentMon process did not start");
                process = next; stdout = new BoundedLinePump(next.StandardOutput, 20000);
                stderr = new BoundedLinePump(next.StandardError, 500); parser = new PresentMonCsvParser(); StartedAt = now;
                return true;
            } catch (Exception exception) {
                Stop(); failure = "PresentMon start: " + exception.Message; return false;
            }
        }

        public IList<double> ReadFrames()
        {
            if (stdout == null) return new List<double>();
            if (HasExited) stdout.WaitForCompletion(500);
            IList<double> frames = parser.Consume(stdout.Drain(20000));
            if (!String.IsNullOrEmpty(stdout.Error)) throw new IOException("stdout pump: " + stdout.Error);
            return frames;
        }

        public string ReadStderr()
        {
            if (stderr == null) return String.Empty;
            if (HasExited) stderr.WaitForCompletion(500);
            List<string> messages = stderr.Drain(20);
            if (!String.IsNullOrEmpty(stderr.Error)) messages.Add("stderr pump: " + stderr.Error);
            return String.Join(" | ", messages.ToArray());
        }

        void EnsureExecutable()
        {
            if (File.Exists(executable) && Hash(executable) == Sha256) return;
            if (File.Exists(executable)) File.Delete(executable);
            Directory.CreateDirectory(Path.GetDirectoryName(executable));
            string download = executable + ".download." + Guid.NewGuid().ToString("N");
            try {
                Download(download);
                if (Hash(download) != Sha256) throw new InvalidDataException("PresentMon SHA-256 verification failed");
                File.Move(download, executable);
            } catch (Exception exception) {
                throw new IOException("PresentMon download: " + exception.Message, exception);
            } finally { if (File.Exists(download)) File.Delete(download); }
        }

        void Download(string destination)
        {
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(Url);
            request.AllowAutoRedirect = true; request.Timeout = 15000; request.ReadWriteTimeout = 15000;
            request.UserAgent = "WutheringPerformanceTelemetry/" + Version;
            HttpWebResponse response = null; Stream input = null;
            try {
                Stopwatch watch = Stopwatch.StartNew();
                IAsyncResult pending = request.BeginGetResponse(null, null);
                while (!pending.AsyncWaitHandle.WaitOne(100)) {
                    if (!alive() || watch.ElapsedMilliseconds >= 20000) { request.Abort(); throw new IOException("PresentMon download cancelled or timed out"); }
                }
                response = (HttpWebResponse)request.EndGetResponse(pending);
                if (response.StatusCode != HttpStatusCode.OK || response.ContentLength > 134217728)
                    throw new InvalidDataException("Unexpected PresentMon download response");
                input = response.GetResponseStream();
                using (FileStream output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                    byte[] buffer = new byte[65536]; long total = 0;
                    while (true) {
                        if (!alive() || watch.ElapsedMilliseconds >= 60000) { request.Abort(); throw new IOException("PresentMon download cancelled or timed out"); }
                        IAsyncResult read = input.BeginRead(buffer, 0, buffer.Length, null, null);
                        while (!read.AsyncWaitHandle.WaitOne(100)) {
                            if (!alive() || watch.ElapsedMilliseconds >= 60000) { request.Abort(); throw new IOException("PresentMon download cancelled or timed out"); }
                        }
                        int count = input.EndRead(read); if (count == 0) break;
                        total += count; if (total > 134217728) throw new InvalidDataException("PresentMon download exceeds budget");
                        output.Write(buffer, 0, count);
                    }
                    output.Flush(true);
                }
            } finally { request.Abort(); if (input != null) input.Dispose(); if (response != null) response.Dispose(); }
        }

        static string Hash(string path)
        {
            using (SHA256 algorithm = SHA256.Create())
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                byte[] bytes = algorithm.ComputeHash(stream); StringBuilder text = new StringBuilder(bytes.Length * 2);
                for (int i = 0; i < bytes.Length; ++i) text.Append(bytes[i].ToString("X2", CultureInfo.InvariantCulture));
                return text.ToString();
            }
        }

        public void Stop()
        {
            if (process != null) {
                try { if (!process.HasExited) { process.Kill(); process.WaitForExit(3000); } } catch {}
            }
            if (stdout != null) stdout.Dispose(); if (stderr != null) stderr.Dispose();
            if (process != null) process.Dispose();
            process = null; stdout = null; stderr = null; parser = null; StartedAt = DateTimeOffset.MinValue;
        }

        public void Dispose() { Stop(); }
    }
}
