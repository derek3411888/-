using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace Wuthering.Native
{
    // Read-only installation metadata. This class never starts any process or writes files.
    public static class InstallDiscovery
    {
        private const int AppId = 3513350;
        private const int MetadataLimit = 2097152;
        private static readonly StringComparer IgnoreCase = StringComparer.OrdinalIgnoreCase;
        private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;

        public static Dictionary<string, object> Resolve(string launchEntry)
        {
            return Resolve(launchEntry, new string[0], true);
        }

        // Explicit portable inventories also permit callers to avoid machine-level discovery.
        public static Dictionary<string, object> Resolve(string launchEntry, IEnumerable<string> steamRoots, bool readRegistry)
        {
            Entry entry = ResolveEntry(launchEntry ?? "");
            var evidence = new List<string> { entry.Fingerprint };
            var roots = new SortedSet<string>(IgnoreCase);
            var installs = new List<Dictionary<string, object>>();
            if (entry.Kind != "unknown")
            {
                if (steamRoots != null) foreach (string candidate in steamRoots) AddRoot(roots, candidate);
                string ancestor = Parent(entry.Real);
                for (int depth = 0; ancestor.Length > 0 && depth < 10; depth++, ancestor = Parent(ancestor))
                    if (File.Exists(Path.Combine(ancestor, "steam.exe")) && Directory.Exists(Path.Combine(ancestor, "steamapps"))) AddRoot(roots, ancestor);
                if (readRegistry)
                {
                    AddRegistryRoot(roots, Registry.CurrentUser, @"Software\Valve\Steam", "SteamPath");
                    AddRegistryRoot(roots, Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath");
                }
                ReadSteamInventory(roots, installs, evidence);
                ReadKuroInventory(entry, installs, evidence);
            }
            string inventoryFingerprint = Hash("inventory-rules-v1|" + String.Join("|", roots) + "|" + String.Join("|", evidence));
            var result = Map("provider", "unknown", "appId", 0, "gameRoot", "", "launcherPath", "",
                "launchEntry", entry.AsMap(), "evidence", new string[] { "insufficient-install-evidence" },
                "fingerprint", Hash("install-rules-v1|" + inventoryFingerprint + "|" + entry.Fingerprint),
                "checkedAtUtc", DateTimeOffset.UtcNow.ToString("o", Invariant), "updateAdapterReady", false, "manifestPath", "", "contentLogPath", "");
            var matching = new List<Dictionary<string, object>>();
            foreach (var install in installs)
            {
                string provider = Text(install, "provider"), launcher = Text(install, "launcherPath"), gameRoot = Text(install, "gameRoot");
                bool matches = entry.Kind == "steam-uri" && provider == "steam" && IsSteamUri(entry.Target) && entry.Arguments.Length == 0;
                if (entry.Kind == "exe")
                {
                    matches = Within(entry.Real, gameRoot) && entry.Arguments.Length == 0;
                    if (entry.Real.Length > 0 && IgnoreCase.Equals(entry.Real, launcher))
                        matches = (provider == "kuro" && entry.Arguments.Length == 0) || (provider == "steam" && IsSteamArguments(entry.Arguments));
                    if (provider == "kuro" && entry.Real.Length > 0 && launcher.Length > 0 && entry.Arguments.Length == 0)
                    {
                        string prefix = Parent(launcher).TrimEnd('\\') + "\\";
                        if (entry.Real.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) && Match(entry.Real.Substring(prefix.Length), @"^\d+(?:\.\d+){1,3}\\launcher_main\.exe$")) matches = true;
                    }
                }
                if (matches) matching.Add(install);
            }
            if (matching.Count > 1) { result["provider"] = "ambiguous"; result["evidence"] = new string[] { "multiple-matching-installations" }; }
            else if (matching.Count == 1)
            {
                foreach (string key in new [] { "provider", "appId", "gameRoot", "launcherPath", "manifestPath", "contentLogPath" }) result[key] = Get(matching[0], key, "");
                result["evidence"] = new string[] { "configured-entry-matches-canonical-game-root", "installation-files-verified" };
            }
            return result;
        }

        public static string RealPath(string path)
        {
            using (SafeFileHandle handle = CreateFile(Path.GetFullPath(path), 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero))
            {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                var buffer = new StringBuilder(32768);
                uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0 || length >= buffer.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
                string full = buffer.ToString();
                if (full.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) full = @"\\" + full.Substring(8);
                else if (full.StartsWith(@"\\?\", StringComparison.Ordinal)) full = full.Substring(4);
                return full.Length > 3 ? full.TrimEnd('\\', '/') : full;
            }
        }

        public static Dictionary<string, object> ParseValve(string text)
        {
            text = text ?? "";
            if (Encoding.UTF8.GetByteCount(text) > MetadataLimit) throw new FormatException("KeyValues file too large");
            return new ValveParser(text).ReadObject(false, 0);
        }

        public static Dictionary<string, object> ObserveSteam(Dictionary<string, object> install, Dictionary<string, object> previous, DateTimeOffset now)
        {
            var result = Map("phase", "unknown", "progressPercent", null, "bytesDone", null, "bytesTotal", null,
                "lastProgressAtUtc", Get(previous, "lastProgressAtUtc", ""), "cursor", 0L, "logIdentity", "", "partial", "",
                "errorCode", "", "detail", "", "gamePid", 0, "gamePath", "");
            Dictionary<string, object> app;
            try
            {
                if (Text(install, "appId") != "3513350") throw new FormatException("Invalid manifest");
                app = Get(ParseValve(ReadMetadata(Text(install, "manifestPath"))), "AppState", null) as Dictionary<string, object>;
                if (Text(app, "appid") != "3513350") throw new FormatException("Wrong App ID");
            }
            catch { result["errorCode"] = "STEAM_MANIFEST_INVALID"; result["detail"] = "Steam manifest 不完整或不屬於鳴潮"; return result; }
            result["phase"] = Get(previous, "phase", "unknown");
            if (Text(result, "phase") == "error")
            {
                result["errorCode"] = NonBlank(Text(previous, "errorCode"), "STEAM_UPDATE_ERROR");
                result["detail"] = NonBlank(Text(previous, "detail"), "Steam 記錄到目標遊戲更新錯誤");
            }
            try
            {
                var info = new FileInfo(Text(install, "contentLogPath"));
                long length = info.Length;
                result["logIdentity"] = info.CreationTimeUtc.Ticks.ToString(Invariant);
                long cursor = Number(previous, "cursor", 0);
                if (previous == null) cursor = length;
                else if (cursor > length || Text(result, "logIdentity") != Text(previous, "logIdentity")) cursor = 0;
                long remaining = length - cursor; bool skipFirst = false;
                if (remaining > 65536) { cursor = length - 65536; remaining = 65536; skipFirst = true; }
                string partial = cursor == Number(previous, "cursor", -1) && !skipFirst ? Text(previous, "partial") : "";
                byte[] data = new byte[checked((int)remaining)]; int count;
                using (var stream = File.Open(info.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    stream.Seek(cursor, SeekOrigin.Begin); count = stream.Read(data, 0, data.Length); result["cursor"] = cursor + count;
                }
                string[] lines = (partial + Encoding.UTF8.GetString(data, 0, count)).Split('\n');
                result["partial"] = lines[lines.Length - 1].Length > 4096 ? "" : lines[lines.Length - 1];
                for (int i = 0; i < lines.Length - 1; i++)
                {
                    if (skipFirst && i == 0) continue;
                    string line = lines[i];
                    Match match = Regex.Match(line, @"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\].*\bAppID\s+3513350\b", RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1));
                    if (!match.Success) continue;
                    DateTimeOffset timestamp = new DateTimeOffset(DateTime.SpecifyKind(DateTime.ParseExact(match.Groups[1].Value, "yyyy-MM-dd HH:mm:ss", Invariant), DateTimeKind.Local));
                    if ((now - timestamp).TotalSeconds > 60 || (timestamp - now).TotalSeconds > 5) continue;
                    string errorText = Regex.Replace(line, @"\bNo Error\b", "", RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1));
                    string phase = Match(errorText, "disk write|not enough disk|disk full|failed|error") ? "error" :
                        Match(line, "Fully Installed") ? "update_ready" : Match(line, "Downloading") ? "downloading" :
                        Match(line, "Staging|Committing|Installing") ? "installing" : Match(line, "Verifying|Validating") ? "verifying" :
                        Match(line, "Paused") ? "paused_download" : Match(line, "Queued") ? "queued" : "";
                    if (phase.Length == 0) continue;
                    result["phase"] = phase; result["lastProgressAtUtc"] = now.ToString("o", Invariant);
                    result["errorCode"] = phase == "error" ? "STEAM_UPDATE_ERROR" : "";
                    result["detail"] = phase == "error" ? "Steam 記錄到目標遊戲更新錯誤" : "";
                }
            }
            catch { result["detail"] = "Steam 更新 Log 暫時不可讀；未以缺失 Log 宣告成功"; }
            string doneKey = Text(result, "phase") == "downloading" ? "BytesDownloaded" : Text(result, "phase") == "installing" ? "BytesStaged" : "";
            string totalKey = Text(result, "phase") == "downloading" ? "BytesToDownload" : "BytesToStage";
            if (doneKey.Length > 0)
            {
                string doneText = Text(app, doneKey), totalText = Text(app, totalKey); long done, total;
                if (Match(doneText, @"^\d{1,15}$") && Match(totalText, @"^\d{1,15}$") && Int64.TryParse(doneText, out done) && Int64.TryParse(totalText, out total) && total > 0 && done <= total)
                {
                    result["bytesDone"] = done; result["bytesTotal"] = total; result["progressPercent"] = Math.Round(100.0 * done / total, 2);
                    if (previous != null && (Get(previous, "bytesDone", null) == null || Number(previous, "bytesDone", -1) != done)) result["lastProgressAtUtc"] = now.ToString("o", Invariant);
                }
            }
            return result;
        }

        private static void ReadSteamInventory(IEnumerable<string> roots, List<Dictionary<string, object>> installs, List<string> evidence)
        {
            var seenLibraries = new HashSet<string>(IgnoreCase);
            foreach (string steamRoot in roots)
            {
                string launcher = Path.Combine(steamRoot, "steam.exe");
                if (!File.Exists(launcher)) continue;
                string foldersPath = Path.Combine(steamRoot, @"steamapps\libraryfolders.vdf");
                evidence.Add(FileIdentity(foldersPath, true));
                var libraries = new SortedSet<string>(IgnoreCase) { steamRoot };
                try
                {
                    var folders = Get(ParseValve(ReadMetadata(foldersPath)), "libraryfolders", null) as Dictionary<string, object>;
                    if (folders != null) foreach (var folder in folders)
                    {
                        if (!Match(folder.Key, @"^\d+$")) continue;
                        string library = folder.Value as string ?? Text(folder.Value as Dictionary<string, object>, "path");
                        if (library.Length > 0) libraries.Add(RealPath(library));
                    }
                }
                catch { evidence.Add("unreadable-library-index"); }
                foreach (string library in libraries)
                {
                    if (!seenLibraries.Add(library)) continue;
                    string manifest = Path.Combine(library, @"steamapps\appmanifest_3513350.acf");
                    evidence.Add(FileIdentity(manifest, true));
                    try
                    {
                        var app = Get(ParseValve(ReadMetadata(manifest)), "AppState", null) as Dictionary<string, object>;
                        if (Text(app, "appid") != "3513350") continue;
                        string directory = Text(app, "installdir");
                        if (directory.Length == 0 || directory == "." || directory == ".." || Match(directory, @"[\\/:]")) continue;
                        string gameRoot = Path.Combine(library, @"steamapps\common", directory);
                        string gameExe = Path.Combine(gameRoot, @"Client\Binaries\Win64\Client-Win64-Shipping.exe");
                        if (!File.Exists(gameExe)) continue;
                        string realRoot = RealPath(gameRoot);
                        if (!Within(RealPath(gameExe), realRoot)) continue;
                        evidence.Add(FileIdentity(launcher, false)); evidence.Add(FileIdentity(gameExe, false));
                        installs.Add(Map("provider", "steam", "appId", AppId, "gameRoot", realRoot, "launcherPath", RealPath(launcher),
                            "manifestPath", manifest, "contentLogPath", Path.Combine(steamRoot, @"logs\content_log.txt")));
                    }
                    catch { evidence.Add("unreadable-or-invalid-manifest"); }
                }
            }
        }

        private static void ReadKuroInventory(Entry entry, List<Dictionary<string, object>> installs, List<string> evidence)
        {
            string parent = Parent(entry.Real);
            for (int depth = 0; parent.Length > 0 && depth < 6; depth++, parent = Parent(parent))
            {
                string launcher = Path.Combine(parent, "launcher.exe"), root = Path.Combine(parent, "Wuthering Waves Game");
                string gameExe = Path.Combine(root, @"Client\Binaries\Win64\Client-Win64-Shipping.exe");
                if (!File.Exists(launcher) || !File.Exists(gameExe)) continue;
                try
                {
                    FileVersionInfo version = FileVersionInfo.GetVersionInfo(launcher);
                    if (String.IsNullOrEmpty(version.CompanyName) || !Match(version.CompanyName, "Kuro") || !IgnoreCase.Equals(version.ProductName, "Wuthering Waves")) continue;
                    string realRoot = RealPath(root);
                    if (!Within(RealPath(gameExe), realRoot)) continue;
                    installs.Add(Map("provider", "kuro", "appId", 0, "gameRoot", realRoot, "launcherPath", RealPath(launcher), "manifestPath", "", "contentLogPath", ""));
                    evidence.Add(FileIdentity(launcher, false)); evidence.Add(FileIdentity(gameExe, false));
                }
                catch { evidence.Add("unreadable-kuro-launcher-identity"); }
            }
        }

        private sealed class Entry
        {
            internal string Kind = "unknown", Target = "", Arguments = "", WorkingDirectory = "", Real = "", Fingerprint = "";
            internal string[] Evidence = new string[0];
            internal Dictionary<string, object> AsMap() { return Map("kind", Kind, "target", Target, "arguments", Arguments, "workingDirectory", WorkingDirectory, "realPath", Real, "fingerprint", Fingerprint, "evidence", Evidence); }
        }
        private static Entry ResolveEntry(string launchEntry)
        {
            var result = new Entry(); var chain = new List<string>(); var seen = new HashSet<string>(IgnoreCase);
            string target = launchEntry.Trim().Trim('"');
            try
            {
                for (int depth = 0; depth <= 4; depth++)
                {
                    if (IsSteamUri(target))
                    {
                        if (result.Arguments.Length > 0) throw new FormatException("Unexpected Steam URI arguments");
                        result.Kind = "steam-uri"; result.Target = target; break;
                    }
                    if (Match(target, @"^\w+://")) throw new FormatException("Unsupported launch URI");
                    string path = Path.GetFullPath(target);
                    if (!seen.Add(path)) throw new FormatException("Shortcut cycle");
                    chain.Add(FileIdentity(path, false));
                    if (!File.Exists(path)) throw new FileNotFoundException("Launch entry missing");
                    string extension = Path.GetExtension(path).ToLowerInvariant();
                    if (extension == ".lnk")
                    {
                        if (depth == 4) throw new FormatException("Shortcut depth exceeded");
                        var shortcut = ReadShortcut(path);
                        string arguments = Text(shortcut, "Arguments");
                        if (result.Arguments.Length > 0 && arguments.Length > 0) throw new FormatException("Nested shortcut arguments ambiguous");
                        if (arguments.Length > 0) result.Arguments = arguments;
                        result.WorkingDirectory = Text(shortcut, "WorkingDirectory"); target = Text(shortcut, "TargetPath"); continue;
                    }
                    if (extension == ".url")
                    {
                        if (depth == 4 || new FileInfo(path).Length > 16384) throw new FormatException("Invalid URL shortcut");
                        MatchCollection urls = Regex.Matches(File.ReadAllText(path, Encoding.UTF8), "^URL=(.*)$", RegexOptions.IgnoreCase | RegexOptions.Multiline, TimeSpan.FromSeconds(1));
                        if (urls.Count != 1) throw new FormatException("Ambiguous URL shortcut");
                        target = urls[0].Groups[1].Value.Trim();
                        if (!IsSteamUri(target)) throw new FormatException("Unsafe URL shortcut");
                        continue;
                    }
                    if (extension != ".exe" || Match(Path.GetFileName(path), @"^(?:cmd|powershell|pwsh|wscript|cscript|rundll32|mshta)\.exe$")) throw new FormatException("Executable wrapper not allowed");
                    result.Kind = "exe"; result.Target = path; result.Real = RealPath(path);
                    if (result.Arguments.Length > 0 && !IsSteamArguments(result.Arguments)) throw new FormatException("Unsupported launch arguments");
                    break;
                }
                if (result.Target.Length == 0) throw new FormatException("No launch target");
                result.Evidence = new string[] { "entry-resolved" };
            }
            catch (Exception ex) { result.Kind = "unknown"; result.Evidence = new string[] { ex.Message }; }
            result.Fingerprint = Hash("entry-v1|" + launchEntry + "|" + String.Join("|", chain) + "|" + result.Target + "|" + result.Arguments + "|" + result.Real);
            return result;
        }
        private static Dictionary<string, object> ReadShortcut(string path)
        {
            object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")); object link = null;
            try
            {
                link = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
                return Map("TargetPath", link.GetType().InvokeMember("TargetPath", BindingFlags.GetProperty, null, link, null),
                    "Arguments", link.GetType().InvokeMember("Arguments", BindingFlags.GetProperty, null, link, null),
                    "WorkingDirectory", link.GetType().InvokeMember("WorkingDirectory", BindingFlags.GetProperty, null, link, null));
            }
            finally { if (link != null) Marshal.FinalReleaseComObject(link); Marshal.FinalReleaseComObject(shell); }
        }

        private sealed class ValveParser
        {
            private readonly string text; private int offset;
            internal ValveParser(string text) { this.text = text; }
            private void SkipSpace()
            {
                while (offset < text.Length)
                {
                    if (Char.IsWhiteSpace(text[offset])) { offset++; continue; }
                    if (text[offset] == '/' && offset + 1 < text.Length && text[offset + 1] == '/')
                    {
                        offset += 2; while (offset < text.Length && text[offset] != '\r' && text[offset] != '\n') offset++; continue;
                    }
                    break;
                }
            }
            private string ReadString()
            {
                if (offset >= text.Length || text[offset++] != '"') throw new FormatException("Malformed KeyValues token");
                var value = new StringBuilder();
                while (offset < text.Length)
                {
                    char c = text[offset++]; if (c == '"') return value.ToString();
                    if (c == '\\')
                    {
                        if (offset >= text.Length || (text[offset] != '\\' && text[offset] != '"')) throw new FormatException("Malformed KeyValues token");
                        c = text[offset++];
                    }
                    value.Append(c);
                }
                throw new FormatException("Malformed KeyValues token");
            }
            internal Dictionary<string, object> ReadObject(bool needsClose, int depth)
            {
                if (depth > 24) throw new FormatException("KeyValues nesting limit exceeded");
                var result = new Dictionary<string, object>(IgnoreCase);
                while (true)
                {
                    SkipSpace();
                    if (offset == text.Length)
                    {
                        if (needsClose) throw new FormatException("Unterminated KeyValues object");
                        return result;
                    }
                    if (text[offset] == '}')
                    {
                        offset++; if (!needsClose) throw new FormatException("Unexpected closing brace"); return result;
                    }
                    string key = ReadString(); SkipSpace();
                    if (result.ContainsKey(key)) throw new FormatException("Duplicate KeyValues key");
                    if (offset >= text.Length) throw new FormatException("Missing KeyValues key/value");
                    object value;
                    if (text[offset] == '{') { offset++; value = ReadObject(true, depth + 1); }
                    else value = ReadString();
                    result.Add(key, value);
                }
            }
        }

        private static string ReadMetadata(string path)
        {
            using (var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                if (stream.Length > MetadataLimit) throw new IOException("Metadata too large");
                using (var bytes = new MemoryStream())
                {
                    byte[] buffer = new byte[8192]; int count;
                    while ((count = stream.Read(buffer, 0, buffer.Length)) != 0)
                    {
                        if (bytes.Length + count > MetadataLimit) throw new IOException("Metadata too large"); bytes.Write(buffer, 0, count);
                    }
                    bytes.Position = 0; using (var reader = new StreamReader(bytes, Encoding.UTF8, true)) return reader.ReadToEnd();
                }
            }
        }
        private static string FileIdentity(string path, bool content)
        {
            try
            {
                var info = new FileInfo(path); string identity = info.FullName + "|" + info.Length.ToString(Invariant) + "|" + info.LastWriteTimeUtc.Ticks.ToString(Invariant);
                return content ? identity + "|" + Hash(ReadMetadata(path)) : identity;
            }
            catch { return "unavailable:" + path; }
        }
        private static void AddRoot(ISet<string> roots, string path) { if (!String.IsNullOrWhiteSpace(path)) try { roots.Add(RealPath(path)); } catch { } }
        private static void AddRegistryRoot(ISet<string> roots, RegistryKey hive, string path, string name)
        {
            try { using (RegistryKey key = hive.OpenSubKey(path, false)) { if (key != null) AddRoot(roots, Convert.ToString(key.GetValue(name, ""), Invariant)); } } catch { }
        }
        private static string Parent(string path) { if (String.IsNullOrEmpty(path)) return ""; return Path.GetDirectoryName(path) ?? ""; }
        private static bool Within(string path, string root)
        {
            if (String.IsNullOrEmpty(path) || String.IsNullOrEmpty(root)) return false;
            try { path = Path.GetFullPath(path).TrimEnd('\\', '/'); root = Path.GetFullPath(root).TrimEnd('\\', '/'); return IgnoreCase.Equals(path, root) || path.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase); } catch { return false; }
        }
        private static bool IsSteamUri(string value) { return Match(value, @"^steam://(?:run|rungameid)/3513350/?$"); }
        private static bool IsSteamArguments(string value) { return Match(value, @"^\s*-applaunch\s+3513350\s*$"); }
        private static bool Match(string value, string pattern) { return Regex.IsMatch(value ?? "", pattern, RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1)); }
        private static object Get(Dictionary<string, object> map, string key, object fallback)
        {
            object value; if (map == null) return fallback;
            if (map.TryGetValue(key, out value)) return value;
            foreach (var item in map) if (IgnoreCase.Equals(item.Key, key)) return item.Value;
            return fallback;
        }
        private static string Text(Dictionary<string, object> map, string key) { return Convert.ToString(Get(map, key, ""), Invariant) ?? ""; }
        private static long Number(Dictionary<string, object> map, string key, long fallback) { long value; return Int64.TryParse(Text(map, key), NumberStyles.Integer, Invariant, out value) ? value : fallback; }
        private static string NonBlank(string text, string fallback) { return String.IsNullOrWhiteSpace(text) ? fallback : text; }
        private static Dictionary<string, object> Map(params object[] items)
        {
            var result = new Dictionary<string, object>(IgnoreCase); for (int i = 0; i < items.Length; i += 2) result[(string)items[i]] = items[i + 1]; return result;
        }
        private static string Hash(string text) { using (var hash = SHA256.Create()) return BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(text))).Replace("-", "").ToLowerInvariant(); }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
    }
}
