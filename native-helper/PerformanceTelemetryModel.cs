using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace Wuthering.Native
{
    public sealed class FpsMetrics
    {
        public double? Fps { get; set; }
        public double? Fps1Low { get; set; }
        public double? FrameTimeMs { get; set; }
        public double? FrameTimeP95Ms { get; set; }
        public double? FrameTimeP99Ms { get; set; }
    }

    public static class PerformanceTelemetryMath
    {
        public static double? Normalize(object value, double minimum, double maximum)
        {
            if (value == null) return null;
            double number;
            if (!Double.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture),
                NumberStyles.Float, CultureInfo.InvariantCulture, out number)) return null;
            if (Double.IsNaN(number) || Double.IsInfinity(number)) return null;
            return Math.Round(Math.Max(minimum, Math.Min(maximum, number)), 3);
        }

        public static double? Percentile(IEnumerable<double> values, double percentile)
        {
            if (values == null) return null;
            List<double> ordered = new List<double>();
            foreach (double value in values)
                if (!Double.IsNaN(value) && !Double.IsInfinity(value)) ordered.Add(value);
            if (ordered.Count == 0) return null;
            ordered.Sort();
            int index = (int)Math.Ceiling((percentile / 100.0) * ordered.Count) - 1;
            index = Math.Max(0, Math.Min(ordered.Count - 1, index));
            return ordered[index];
        }

        public static FpsMetrics Fps(IEnumerable<double> frameTimes)
        {
            List<double> values = new List<double>();
            if (frameTimes != null) {
                foreach (double value in frameTimes) {
                    double? normalized = Normalize(value, 0.01, 10000);
                    if (normalized.HasValue) values.Add(normalized.Value);
                }
            }
            if (values.Count == 0) return new FpsMetrics();
            double total = 0;
            for (int i = 0; i < values.Count; ++i) total += values[i];
            double average = total / values.Count;
            double p95 = Percentile(values, 95).Value;
            double p99 = Percentile(values, 99).Value;
            return new FpsMetrics {
                Fps = Normalize(1000.0 / Math.Max(0.01, average), 0, 1000),
                Fps1Low = Normalize(1000.0 / Math.Max(0.01, p99), 0, 1000),
                FrameTimeMs = Normalize(average, 0, 10000),
                FrameTimeP95Ms = Normalize(p95, 0, 10000),
                FrameTimeP99Ms = Normalize(p99, 0, 10000)
            };
        }
    }

    public sealed class BoundedLinePump : IDisposable
    {
        readonly TextReader reader;
        readonly Queue<string> queue = new Queue<string>();
        readonly object gate = new object();
        readonly Thread thread;
        readonly int maximumLines;
        volatile bool stopping;
        volatile bool completed;
        string error = String.Empty;

        public BoundedLinePump(TextReader source, int maximum)
        {
            if (source == null) throw new ArgumentNullException("source");
            reader = source;
            maximumLines = Math.Max(100, maximum);
            thread = new Thread(ReadLoop) { IsBackground = true, Name = "Wuthering telemetry line pump" };
            thread.Start();
        }

        public bool Completed { get { return completed; } }
        public string Error { get { lock (gate) return error; } }

        void ReadLoop()
        {
            try {
                while (!stopping) {
                    string line = reader.ReadLine();
                    if (line == null) break;
                    lock (gate) {
                        queue.Enqueue(line);
                        while (queue.Count > maximumLines) queue.Dequeue();
                    }
                }
            } catch (ObjectDisposedException exception) {
                if (!stopping) lock (gate) error = exception.Message ?? exception.GetType().Name;
            } catch (IOException exception) {
                if (!stopping) lock (gate) error = exception.Message ?? exception.GetType().Name;
            } catch (Exception exception) {
                lock (gate) error = exception.Message ?? exception.GetType().Name;
            } finally {
                completed = true;
            }
        }

        public List<string> Drain(int maximum)
        {
            List<string> lines = new List<string>();
            int limit = Math.Max(0, maximum);
            lock (gate) while (lines.Count < limit && queue.Count > 0) lines.Add(queue.Dequeue());
            return lines;
        }

        public bool WaitForCompletion(int milliseconds)
        {
            if (completed) return true;
            return thread.Join(Math.Max(0, milliseconds));
        }

        public void Dispose()
        {
            stopping = true;
            try { reader.Dispose(); } catch {}
            if (Thread.CurrentThread != thread) WaitForCompletion(1000);
        }
    }

    public sealed class PresentMonCsvParser
    {
        int frameTimeIndex = -1;
        bool hasHeader;

        public IList<double> Consume(IEnumerable<string> lines)
        {
            List<double> frames = new List<double>();
            if (lines == null) return frames;
            foreach (string source in lines) {
                if (String.IsNullOrWhiteSpace(source)) continue;
                string line = source.TrimStart('\uFEFF');
                if (!hasHeader) {
                    if (!line.StartsWith("Application,", StringComparison.Ordinal)) continue;
                    List<string> header = SplitCsv(line);
                    frameTimeIndex = header.IndexOf("FrameTime");
                    if (frameTimeIndex < 0) throw new InvalidDataException("PresentMon stdout header does not contain FrameTime");
                    hasHeader = true;
                    continue;
                }
                List<string> fields = SplitCsv(line);
                if (fields.Count <= frameTimeIndex) continue;
                double? value = PerformanceTelemetryMath.Normalize(fields[frameTimeIndex], 0.01, 10000);
                if (value.HasValue) frames.Add(value.Value);
            }
            return frames;
        }

        static List<string> SplitCsv(string line)
        {
            List<string> fields = new List<string>();
            StringBuilder field = new StringBuilder();
            bool quoted = false;
            for (int i = 0; i < line.Length; ++i) {
                char character = line[i];
                if (character == '"') {
                    if (quoted && i + 1 < line.Length && line[i + 1] == '"') { field.Append('"'); ++i; }
                    else quoted = !quoted;
                } else if (character == ',' && !quoted) {
                    fields.Add(field.ToString()); field.Length = 0;
                } else field.Append(character);
            }
            fields.Add(field.ToString());
            return fields;
        }

        public static bool IsFatal(string message)
        {
            if (String.IsNullOrWhiteSpace(message)) return false;
            return Regex.IsMatch(message,
                @"\b(error|failed|failure|fatal|denied|exception|invalid|unable)\b|access is denied|拒絕存取",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        }
    }

    public sealed class NvidiaMetrics
    {
        public double? GpuPct { get; set; }
        public double? GpuVramMb { get; set; }
        public double? GpuTempC { get; set; }
        public double? GpuPowerW { get; set; }
        public double? GpuEncoderPct { get; set; }

        public static NvidiaMetrics Parse(IEnumerable<string> lines)
        {
            NvidiaMetrics result = new NvidiaMetrics();
            if (lines == null) return result;
            bool gpuFound = false, memoryFound = false, temperatureFound = false;
            bool powerFound = false, encoderFound = false;
            double utilization = 0, memory = 0, temperature = 0, power = 0, encoder = 0;
            foreach (string line in lines) {
                if (String.IsNullOrWhiteSpace(line)) continue;
                string[] fields = line.Split(',');
                if (fields.Length < 5) continue;
                double? rowGpu = PerformanceTelemetryMath.Normalize(fields[0].Trim(), 0, 100);
                double? rowMemory = PerformanceTelemetryMath.Normalize(fields[1].Trim(), 0, 1000000);
                double? rowTemperature = PerformanceTelemetryMath.Normalize(fields[2].Trim(), 0, 200);
                double? rowPower = PerformanceTelemetryMath.Normalize(fields[3].Trim(), 0, 5000);
                double? rowEncoder = PerformanceTelemetryMath.Normalize(fields[4].Trim(), 0, 100);
                if (rowGpu.HasValue) { gpuFound = true; utilization = Math.Max(utilization, rowGpu.Value); }
                if (rowMemory.HasValue) { memoryFound = true; memory += rowMemory.Value; }
                if (rowTemperature.HasValue) { temperatureFound = true; temperature = Math.Max(temperature, rowTemperature.Value); }
                if (rowPower.HasValue) { powerFound = true; power += rowPower.Value; }
                if (rowEncoder.HasValue) { encoderFound = true; encoder = Math.Max(encoder, rowEncoder.Value); }
            }
            if (gpuFound) result.GpuPct = PerformanceTelemetryMath.Normalize(utilization, 0, 100);
            if (memoryFound) result.GpuVramMb = PerformanceTelemetryMath.Normalize(memory, 0, 1000000);
            if (temperatureFound) result.GpuTempC = PerformanceTelemetryMath.Normalize(temperature, 0, 200);
            if (powerFound) result.GpuPowerW = PerformanceTelemetryMath.Normalize(power, 0, 5000);
            if (encoderFound) result.GpuEncoderPct = PerformanceTelemetryMath.Normalize(encoder, 0, 100);
            return result;
        }
    }

    public sealed class FfmpegProgress
    {
        public bool Active { get; set; }
        public double? Fps { get; set; }
        public double? Dropped { get; set; }
        public double? Duplicated { get; set; }
        public string Speed { get; set; }

        public static FfmpegProgress Read(string path, DateTime utcNow)
        {
            FfmpegProgress empty = new FfmpegProgress();
            if (String.IsNullOrEmpty(path) || !File.Exists(path)) return empty;
            try {
                empty.Active = (utcNow - File.GetLastWriteTimeUtc(path)).TotalSeconds < 12;
                Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (string line in ReadTail(path, 40, 65536)) {
                    int equals = line.IndexOf('=');
                    if (equals > 0) values[line.Substring(0, equals)] = line.Substring(equals + 1);
                }
                string value;
                empty.Fps = values.TryGetValue("fps", out value) ? PerformanceTelemetryMath.Normalize(value, 0, 1000) : null;
                empty.Dropped = values.TryGetValue("drop_frames", out value) ? PerformanceTelemetryMath.Normalize(value, 0, 1.0e12) : null;
                empty.Duplicated = values.TryGetValue("dup_frames", out value) ? PerformanceTelemetryMath.Normalize(value, 0, 1.0e12) : null;
                empty.Speed = values.TryGetValue("speed", out value) ? value : null;
                return empty;
            } catch { return new FfmpegProgress(); }
        }

        static IList<string> ReadTail(string path, int maximumLines, int maximumBytes)
        {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete)) {
                long start = Math.Max(0, stream.Length - maximumBytes);
                stream.Position = start;
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true, 4096)) {
                    if (start > 0) reader.ReadLine();
                    Queue<string> tail = new Queue<string>();
                    string line;
                    while ((line = reader.ReadLine()) != null) {
                        tail.Enqueue(line);
                        while (tail.Count > maximumLines) tail.Dequeue();
                    }
                    return new List<string>(tail);
                }
            }
        }
    }

    public sealed class MinuteAccumulator
    {
        readonly Dictionary<string, List<double>> values = new Dictionary<string, List<double>>(StringComparer.Ordinal);
        int sampleCount;

        public MinuteAccumulator(long bucketStart, IEnumerable<string> metricNames)
        {
            BucketStart = bucketStart;
            foreach (string name in metricNames) values[name] = new List<double>();
        }

        public long BucketStart { get; private set; }

        public void Add(IDictionary<string, object> sample)
        {
            ++sampleCount;
            if (sample == null) return;
            foreach (KeyValuePair<string, List<double>> metric in values) {
                object raw;
                if (!sample.TryGetValue(metric.Key, out raw) || raw == null) continue;
                double number;
                try { number = Convert.ToDouble(raw, CultureInfo.InvariantCulture); }
                catch (Exception) { continue; }
                if (!Double.IsNaN(number) && !Double.IsInfinity(number)) metric.Value.Add(number);
            }
        }

        public Dictionary<string, object> Complete()
        {
            Dictionary<string, object> metrics = new Dictionary<string, object>(StringComparer.Ordinal);
            foreach (KeyValuePair<string, List<double>> metric in values) {
                if (metric.Value.Count == 0) continue;
                double total = 0, minimum = metric.Value[0], maximum = metric.Value[0];
                foreach (double value in metric.Value) {
                    total += value; minimum = Math.Min(minimum, value); maximum = Math.Max(maximum, value);
                }
                metrics[metric.Key] = Math.Round(total / metric.Value.Count, 3);
                if (Regex.IsMatch(metric.Key, "(Pct|TempC|PowerW|Mbps|RamMb|UsedGb)$",
                    RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                    metrics[metric.Key + "Max"] = Math.Round(maximum, 3);
                if (metric.Key == "fps") metrics["fpsMin"] = Math.Round(minimum, 3);
                if (metric.Key == "diskFreeGb") metrics["diskFreeGbMin"] = Math.Round(minimum, 3);
            }
            return new Dictionary<string, object> {
                {"bucketStart", BucketStart}, {"sampleCount", sampleCount}, {"metrics", metrics}
            };
        }
    }

    public static class PerformanceTelemetryProtocol
    {
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        static readonly object JsonGate = new object();
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 1048576, RecursionLimit = 32 };
        static readonly DateTimeOffset Epoch = new DateTimeOffset(1970, 1, 1, 0, 0, 0, TimeSpan.Zero);

        public static readonly string[] MetricNames = {
            "fps", "fps1Low", "frameTimeMs", "frameTimeP95Ms", "frameTimeP99Ms",
            "cpuTotalPct", "cpuGamePct", "cpuOkwwPct", "cpuLrmcPct", "cpuFfmpegPct",
            "gpuPct", "gpuVramMb", "gpuTempC", "gpuPowerW", "gpuEncoderPct",
            "ramUsedGb", "ramTotalGb", "gameRamMb", "okwwRamMb", "lrmcRamMb", "ffmpegRamMb",
            "diskReadMbps", "diskWriteMbps", "diskFreeGb", "networkDownMbps", "networkUpMbps",
            "recordingFps", "recordingDroppedFrames", "recordingDuplicatedFrames",
            "liveFps", "liveDroppedFrames", "liveDuplicatedFrames"
        };

        public static long UnixMilliseconds(DateTimeOffset value)
        {
            return (value.UtcTicks - Epoch.UtcTicks) / TimeSpan.TicksPerMillisecond;
        }

        public static string Serialize(object value)
        {
            lock (JsonGate) return Json.Serialize(value);
        }

        public static Dictionary<string, object> DeserializeObject(string value)
        {
            lock (JsonGate) return Json.DeserializeObject(value) as Dictionary<string, object>;
        }

        public static Dictionary<string, object> Collector(string state, long updatedAt, int interval,
            string presentMon, bool fpsAvailable, bool nvidiaTelemetry, string error)
        {
            return new Dictionary<string, object> {
                {"state", state}, {"version", 1}, {"updatedAt", updatedAt},
                {"sampleIntervalSec", interval}, {"presentMon", presentMon},
                {"presentMonVersion", "2.5.1"}, {"fpsAvailable", fpsAvailable},
                {"nvidiaTelemetry", nvidiaTelemetry}, {"error", error ?? String.Empty}
            };
        }

        public static Dictionary<string, object> BuildHeartbeat(Dictionary<string, object> collector,
            Dictionary<string, object> current, IList<Dictionary<string, object>> history)
        {
            int count = history == null ? 0 : Math.Min(10, history.Count);
            object[] minutes = new object[count];
            for (int i = 0; i < count; ++i) minutes[i] = history[history.Count - count + i];
            return new Dictionary<string, object> {
                {"collector", collector}, {"current", current}, {"minutes", minutes}
            };
        }

        public static Dictionary<string, object> BuildFirestore(Dictionary<string, object> collector,
            Dictionary<string, object> current, IList<Dictionary<string, object>> history)
        {
            int count = history == null ? 0 : Math.Min(60, history.Count);
            object[] points = new object[count];
            string[] pointFields = { "fps", "fps1Low", "frameTimeMs", "frameTimeP95Ms", "cpuTotalPct",
                "gpuPct", "gpuEncoderPct", "diskWriteMbps", "networkUpMbps" };
            for (int i = 0; i < count; ++i) {
                Dictionary<string, object> minute = history[history.Count - count + i];
                Dictionary<string, object> metrics = GetDictionary(minute, "metrics");
                Dictionary<string, object> point = new Dictionary<string, object> {
                    {"at", GetValue(minute, "bucketStart")}
                };
                Copy(point, metrics, pointFields);
                points[i] = point;
            }
            Dictionary<string, object> compact = null;
            if (current != null) {
                compact = new Dictionary<string, object>();
                Copy(compact, current, new string[] {
                    "at", "fps", "fps1Low", "frameTimeMs", "frameTimeP95Ms", "cpuTotalPct", "cpuGamePct",
                    "gpuPct", "gpuEncoderPct", "ramUsedGb", "ramTotalGb", "gameRamMb", "gpuVramMb",
                    "gpuTempC", "gpuPowerW", "diskWriteMbps", "diskFreeGb", "networkUpMbps",
                    "recordingActive", "recordingFps", "liveActive", "liveFps"
                });
            }
            return new Dictionary<string, object> {
                {"schemaVersion", 1}, {"collector", collector}, {"current", compact}, {"points", points}
            };
        }

        static object GetValue(IDictionary<string, object> source, string key)
        {
            object value;
            return source != null && source.TryGetValue(key, out value) ? value : null;
        }

        static Dictionary<string, object> GetDictionary(IDictionary<string, object> source, string key)
        {
            return GetValue(source, key) as Dictionary<string, object>;
        }

        static void Copy(IDictionary<string, object> destination, IDictionary<string, object> source, IEnumerable<string> keys)
        {
            foreach (string key in keys) destination[key] = GetValue(source, key);
        }

        public static void AtomicWrite(string path, string content)
        {
            AtomicWrite(path, content, 1048576);
        }

        static void AtomicWrite(string path, string content, int maximumBytes)
        {
            byte[] bytes = Utf8.GetBytes(content);
            if (bytes.Length > maximumBytes) throw new InvalidDataException("Telemetry atomic write exceeds budget");
            string temporary = path + "." + ProcessId() + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                using (FileStream stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                    stream.Write(bytes, 0, bytes.Length); stream.Flush(true);
                }
                if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
            } finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }

        static int ProcessId()
        {
            using (System.Diagnostics.Process process = System.Diagnostics.Process.GetCurrentProcess()) return process.Id;
        }

        public static void AppendLine(string path, object value)
        {
            string line = Serialize(value) + "\n";
            if (Utf8.GetByteCount(line) > 262144) throw new InvalidDataException("Telemetry row too large");
            File.AppendAllText(path, line, Utf8);
        }

        public static List<Dictionary<string, object>> LoadMinuteHistory(string path, int maximum)
        {
            List<Dictionary<string, object>> result = new List<Dictionary<string, object>>();
            if (!File.Exists(path) || maximum <= 0) return result;
            foreach (string line in ReadLastLines(path, maximum, 4 * 1024 * 1024)) {
                if (String.IsNullOrWhiteSpace(line) || line.Length > 262144) continue;
                try {
                    Dictionary<string, object> row = DeserializeObject(line);
                    if (row != null && row.ContainsKey("bucketStart") && row["metrics"] is Dictionary<string, object>) result.Add(row);
                } catch (ArgumentException) {}
                catch (InvalidOperationException) {}
            }
            return result;
        }

        static IList<string> ReadLastLines(string path, int maximumLines, int maximumBytes)
        {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete)) {
                long start = Math.Max(0, stream.Length - maximumBytes);
                stream.Position = start;
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true, 4096)) {
                    if (start > 0) reader.ReadLine();
                    Queue<string> lines = new Queue<string>();
                    string line;
                    while ((line = reader.ReadLine()) != null) {
                        lines.Enqueue(line);
                        while (lines.Count > maximumLines) lines.Dequeue();
                    }
                    return new List<string>(lines);
                }
            }
        }

        public static void PruneLocal(string outputRoot, string minutesPath, long cutoffMilliseconds, DateTime utcNow)
        {
            if (File.Exists(minutesPath)) {
                List<string> kept = new List<string>();
                using (FileStream stream = new FileStream(minutesPath, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete))
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true, 4096)) {
                    string line;
                    while ((line = reader.ReadLine()) != null) {
                        if (line.Length == 0 || line.Length > 262144) continue;
                        try {
                            Dictionary<string, object> row = DeserializeObject(line);
                            if (row != null && Convert.ToInt64(GetValue(row, "bucketStart"), CultureInfo.InvariantCulture) >= cutoffMilliseconds)
                                kept.Add(line);
                        } catch (Exception exception) {
                            if (!(exception is ArgumentException) && !(exception is InvalidOperationException) &&
                                !(exception is FormatException) && !(exception is OverflowException)) throw;
                        }
                    }
                }
                AtomicWrite(minutesPath, kept.Count == 0 ? String.Empty : String.Join("\n", kept.ToArray()) + "\n",
                    16 * 1024 * 1024);
            }
            DeleteOld(outputRoot, "raw_*.ndjson", utcNow.AddHours(-26));
            DeleteOld(outputRoot, "presentmon_*.csv", utcNow.AddHours(-2));
        }

        static void DeleteOld(string root, string pattern, DateTime cutoff)
        {
            foreach (string path in Directory.GetFiles(root, pattern, SearchOption.TopDirectoryOnly)) {
                try { if (File.GetLastWriteTimeUtc(path) < cutoff) File.Delete(path); }
                catch (IOException) {} catch (UnauthorizedAccessException) {}
            }
        }
    }
}
