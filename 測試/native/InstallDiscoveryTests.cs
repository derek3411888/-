using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Wuthering.Native;

[assembly: AssemblyCompany("Kuro Games")]
[assembly: AssemblyProduct("Wuthering Waves")]

public static class InstallDiscoveryTests
{
    private static int assertions;
    private static string root;
    private static readonly Encoding Utf8 = new UTF8Encoding(false);

    public static int Main()
    {
        root = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "fixtures-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            Parser(); Discovery(); Kuro(); Observation();
            Console.WriteLine("PASS: InstallDiscovery native assertions=" + assertions);
            Console.WriteLine("Fixtures retained: " + root);
            return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
    }

    private static void Eq(object expected, object actual, string message)
    {
        assertions++;
        if (!Object.Equals(expected, actual)) throw new Exception(message + ": expected=" + expected + " actual=" + actual);
    }
    private static void True(bool value, string message) { Eq(true, value, message); }
    private static void Throws(Action action, string message)
    {
        bool thrown = false;
        try { action(); } catch { thrown = true; }
        True(thrown, message);
    }
    private static Dictionary<string, object> Map(params object[] values)
    {
        var result = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < values.Length; i += 2) result[(string)values[i]] = values[i + 1];
        return result;
    }
    private static void Write(string path, string value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)); File.WriteAllText(path, value, Utf8);
    }
    private static void Parser()
    {
        var parsed = InstallDiscovery.ParseValve("// c\n\"libraryfolders\" { \"0\" { \"path\" \"D:\\\\Steam Library\" } \"1\" \"E:\\\\遊戲\" }");
        var libraries = (Dictionary<string, object>)parsed["libraryfolders"];
        Eq(@"D:\Steam Library", ((Dictionary<string, object>)libraries["0"])["path"], "escaped path");
        Eq(@"E:\遊戲", libraries["1"], "legacy path");
        foreach (string bad in new [] { "\"AppState\" { \"appid\" \"3513350\"", "\"AppState\" { \"appid\" }", "\"x\" \"a\" \"X\" \"b\"", "\"a\" { } }", "unquoted value", "\"x\" \"bad\\q\"" })
            Throws(delegate { InstallDiscovery.ParseValve(bad); }, "reject malformed or duplicate KeyValues");
        string nested = "\"k\" \"v\"";
        for (int i = 0; i < 24; i++) nested = "\"n\" {" + nested + "}";
        True(InstallDiscovery.ParseValve(nested) != null, "depth 24 allowed");
        Throws(delegate { InstallDiscovery.ParseValve("\"n\" {" + nested + "}"); }, "depth 25 denied");
        Throws(delegate { InstallDiscovery.ParseValve(new string('中', 699051)); }, "UTF8 byte size bound");
    }
    private static string FakeSteam(string name)
    {
        string steam = Path.Combine(root, name);
        Write(Path.Combine(steam, "steam.exe"), "not an executable");
        Write(GameExe(steam), "not an executable");
        Write(Manifest(steam), "\"AppState\" { \"appid\" \"3513350\" \"installdir\" \"Wuthering Waves\" }");
        Write(Path.Combine(steam, "steamapps", "libraryfolders.vdf"), "\"libraryfolders\" { \"0\" { \"path\" \"" + steam.Replace("\\", "\\\\") + "\" } }");
        return steam;
    }
    private static string GameExe(string steam) { return Path.Combine(steam, @"steamapps\common\Wuthering Waves\Client\Binaries\Win64\Client-Win64-Shipping.exe"); }
    private static string Manifest(string steam) { return Path.Combine(steam, @"steamapps\appmanifest_3513350.acf"); }
    private static Dictionary<string, object> Resolve(string entry, params string[] roots) { return InstallDiscovery.Resolve(entry, roots, false); }
    private static void Discovery()
    {
        string steam = FakeSteam("Steam 中文 Library"), game = GameExe(steam), manifest = Manifest(steam);
        var result = Resolve(game);
        Eq("steam", result["provider"], "ancestor discovers portable Steam");
        Eq(3513350, result["appId"], "target app id");
        Eq(Path.Combine(steam, "steam.exe"), result["launcherPath"], "canonical launcher");
        Eq(false, result["updateAdapterReady"], "discovery is not live adapter acceptance");
        Eq(result["fingerprint"], Resolve(game)["fingerprint"], "unchanged identity stable");
        var stamp = File.GetLastWriteTimeUtc(manifest);
        string original = File.ReadAllText(manifest);
        Write(manifest, original.Replace("3513350", "9999999")); File.SetLastWriteTimeUtc(manifest, stamp);
        Eq("unknown", Resolve(game)["provider"], "wrong app id rejected");
        True(!Object.Equals(result["fingerprint"], Resolve(game)["fingerprint"]), "same-size same-time bytes invalidate fingerprint");
        Write(manifest, original);
        True(!Object.Equals(result["fingerprint"], Resolve(game)["fingerprint"]), "metadata replacement invalidates fingerprint");
        Eq("steam", Resolve("steam://run/3513350", steam)["provider"], "precise URI");
        Eq("steam", Resolve("steam://rungameid/3513350/", steam)["provider"], "desktop URI");
        foreach (string bad in new [] { "steam://run/999999", "steam://run/3513350?args=x", "steam://run/3513350/extra", "https://example.invalid/" })
            Eq("unknown", Resolve(bad, steam)["provider"], "reject decorated URI");
        string url = Path.Combine(root, "鳴潮.url");
        Write(url, "[InternetShortcut]\r\nURL=steam://rungameid/3513350\r\n");
        Eq("steam", Resolve(url, steam)["provider"], "read URL without launching");
        Write(url, "URL=steam://run/3513350\nURL=steam://run/3513350\n");
        Eq("unknown", Resolve(url, steam)["provider"], "duplicate URL rejected");
        Write(url, "URL=https://example.invalid/\n");
        Eq("unknown", Resolve(url, steam)["provider"], "unsafe URL rejected");
        string sibling = Path.Combine(steam, @"steamapps\common\Wuthering Waves-other\Client.exe"); Write(sibling, "fixture");
        Eq("unknown", Resolve(sibling, steam)["provider"], "sibling prefix rejected");
        string wrapper = Path.Combine(Path.GetDirectoryName(game), "powershell.exe"); Write(wrapper, "fixture");
        Eq("unknown", Resolve(wrapper, steam)["provider"], "script wrapper rejected");
        Eq("unknown", Resolve(Path.Combine(root, "missing.exe"), steam)["provider"], "missing entry rejected");
        Eq(game, InstallDiscovery.RealPath(Path.Combine(Path.GetDirectoryName(game), ".", Path.GetFileName(game))), "canonical existing file");
        Throws(delegate { InstallDiscovery.RealPath(Path.Combine(root, "missing")); }, "missing canonical path rejected");
        string alias = Path.Combine(root, "game-alias");
        CreateJunction(alias, Path.Combine(steam, @"steamapps\common\Wuthering Waves"));
        string aliasedGame = Path.Combine(alias, @"Client\Binaries\Win64\Client-Win64-Shipping.exe");
        Eq(game, InstallDiscovery.RealPath(aliasedGame), "junction resolves to physical file");
        Eq("steam", Resolve(aliasedGame)["provider"], "canonical junction finds physical ancestor");
        string link = Path.Combine(root, "game.lnk"); SaveLink(link, game, "");
        Eq("steam", Resolve(link, steam)["provider"], "shortcut metadata resolved");
        SaveLink(link, Path.Combine(steam, "steam.exe"), "-applaunch 3513350");
        Eq("steam", Resolve(link, steam)["provider"], "exact Steam applaunch accepted");
        SaveLink(link, Path.Combine(steam, "steam.exe"), "-applaunch 999999");
        Eq("unknown", Resolve(link, steam)["provider"], "wrong shortcut arguments rejected");
        string steam2 = FakeSteam("Second Steam");
        Eq("ambiguous", Resolve("steam://run/3513350", steam, steam2)["provider"], "conflicting installations not guessed");
        Eq("steam", Resolve(game, steam, steam2)["provider"], "selected root wins over unrelated install");
        string primary = Path.Combine(root, "Primary Steam"), external = FakeSteam("External Library");
        Write(Path.Combine(primary, "steam.exe"), "fixture");
        File.Delete(Path.Combine(external, "steam.exe"));
        Write(Path.Combine(primary, @"steamapps\libraryfolders.vdf"), "\"libraryfolders\" { \"7\" { \"path\" \"" + external.Replace("\\", "\\\\") + "\" } }");
        var externalInstall = Resolve(GameExe(external), primary);
        Eq("steam", externalInstall["provider"], "external library from index");
        Eq(Path.Combine(primary, "steam.exe"), externalInstall["launcherPath"], "external library belongs to indexed launcher");
        Eq(Path.Combine(primary, @"logs\content_log.txt"), externalInstall["contentLogPath"], "log belongs to owning Steam root");
        Write(manifest, "\"AppState\" { \"appid\" \"3513350\"");
        Eq("unknown", Resolve(game, steam)["provider"], "partial manifest rejected");
        Write(manifest, original.Replace("Wuthering Waves", ".."));
        Eq("unknown", Resolve(game, steam)["provider"], "manifest traversal rejected");
        Write(manifest, original); File.Delete(game);
        Eq("unknown", Resolve("steam://run/3513350", steam)["provider"], "removed installation not accepted");
    }
    private static void CreateJunction(string junction, string target)
    {
        // Both paths are newly created children of this test run's diagnostic fixture root.
        string prefix = Path.GetFullPath(root).TrimEnd('\\') + "\\";
        if (!Path.GetFullPath(junction).StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFullPath(target).StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new Exception("Fixture junction escapes root");
        Directory.CreateDirectory(junction);
        byte[] substitute = Encoding.Unicode.GetBytes(@"\??\" + Path.GetFullPath(target));
        byte[] print = Encoding.Unicode.GetBytes(Path.GetFullPath(target));
        byte[] reparse = new byte[16 + substitute.Length + 2 + print.Length + 2];
        using (var buffer = new MemoryStream(reparse)) using (var writer = new BinaryWriter(buffer))
        {
            writer.Write(0xA0000003U); writer.Write((ushort)(reparse.Length - 8)); writer.Write((ushort)0);
            writer.Write((ushort)0); writer.Write((ushort)substitute.Length); writer.Write((ushort)(substitute.Length + 2)); writer.Write((ushort)print.Length);
            writer.Write(substitute); writer.Write((ushort)0); writer.Write(print); writer.Write((ushort)0);
        }
        using (SafeFileHandle handle = OpenFixtureDirectory(junction, 0x40000000, 0, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero))
        {
            if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            int returned;
            if (!SetFixtureReparsePoint(handle, 0x000900A4, reparse, reparse.Length, IntPtr.Zero, 0, out returned, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    }
    [DllImport("kernel32.dll", EntryPoint="CreateFileW", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern SafeFileHandle OpenFixtureDirectory(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", EntryPoint="DeviceIoControl", SetLastError=true)]
    private static extern bool SetFixtureReparsePoint(SafeFileHandle handle, uint code, byte[] input, int inputLength, IntPtr output, int outputLength, out int returned, IntPtr overlapped);
    private static void SaveLink(string path, string target, string arguments)
    {
        object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")); object link = null;
        try
        {
            link = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
            link.GetType().InvokeMember("TargetPath", BindingFlags.SetProperty, null, link, new object[] { target });
            link.GetType().InvokeMember("Arguments", BindingFlags.SetProperty, null, link, new object[] { arguments });
            link.GetType().InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
        }
        finally { if (link != null) Marshal.FinalReleaseComObject(link); Marshal.FinalReleaseComObject(shell); }
    }
    private static void Kuro()
    {
        string launcher = Path.Combine(root, @"Kuro\launcher.exe"); Directory.CreateDirectory(Path.GetDirectoryName(launcher));
        File.Copy(Assembly.GetExecutingAssembly().Location, launcher);
        string game = Path.Combine(root, @"Kuro\Wuthering Waves Game\Client\Binaries\Win64\Client-Win64-Shipping.exe"); Write(game, "fixture");
        Eq("kuro", Resolve(game)["provider"], "Kuro product metadata verified");
        Eq("kuro", Resolve(launcher)["provider"], "Kuro bootstrap entry verified");
        string ui = Path.Combine(root, @"Kuro\2.6.5.0\launcher_main.exe"); Write(ui, "fixture");
        Eq("kuro", Resolve(ui)["provider"], "versioned Kuro UI verified");
        Write(launcher, "fake file with no company or product");
        Eq("unknown", Resolve(game)["provider"], "unverified Kuro identity rejected");
    }
    private static void Observation()
    {
        string dir = Path.Combine(root, "observe"), manifest = Path.Combine(dir, "appmanifest_3513350.acf"), log = Path.Combine(dir, "content_log.txt");
        var install = Map("provider", "steam", "appId", 3513350, "manifestPath", manifest, "contentLogPath", log, "gameRoot", dir);
        var now = new DateTimeOffset(2026, 8, 20, 3, 10, 0, TimeSpan.Zero);
        Write(manifest, "\"AppState\" { \"appid\" \"3513350\" \"BytesDownloaded\" \"100\" \"BytesToDownload\" \"100\" }");
        Write(log, Line(now.AddSeconds(-1), 3513350, "Fully Installed"));
        var first = InstallDiscovery.ObserveSteam(install, null, now);
        Eq("unknown", first["phase"], "historical ready not accepted"); Eq(null, first["progressPercent"], "old bytes not progress");
        File.AppendAllText(log, Line(now, 123456, "Downloading"), Utf8);
        var other = InstallDiscovery.ObserveSteam(install, first, now.AddSeconds(1));
        Eq(first["lastProgressAtUtc"], other["lastProgressAtUtc"], "another app is not progress");
        Write(manifest, "\"AppState\" { \"appid\" \"3513350\" \"BytesDownloaded\" \"50\" \"BytesToDownload\" \"200\" }");
        File.AppendAllText(log, Line(now.AddSeconds(1), 3513350, "Running,Downloading"), Utf8);
        var down = InstallDiscovery.ObserveSteam(install, other, now.AddSeconds(2));
        Eq("downloading", down["phase"], "fresh target activity"); Eq(25.0, down["progressPercent"], "download denominator");
        Write(manifest, "\"AppState\" { \"appid\" \"3513350\" \"BytesStaged\" \"20\" \"BytesToStage\" \"100\" }");
        File.AppendAllText(log, Line(now.AddSeconds(3), 3513350, "Staging"), Utf8);
        var stage = InstallDiscovery.ObserveSteam(install, down, now.AddSeconds(4));
        Eq("installing", stage["phase"], "stage distinct"); Eq(20.0, stage["progressPercent"], "stage denominator");
        File.AppendAllText(log, Line(now.AddSeconds(4), 3513350, "Fully Installed"), Utf8);
        var ready = InstallDiscovery.ObserveSteam(install, stage, now.AddSeconds(5)); Eq("update_ready", ready["phase"], "updater ready only");
        File.AppendAllText(log, Line(now.AddSeconds(5), 3513350, "scheduler finished : result No Error"), Utf8);
        var success = InstallDiscovery.ObserveSteam(install, ready, now.AddSeconds(6)); Eq("update_ready", success["phase"], "No Error is success"); Eq("", success["errorCode"], "success error empty");
        File.AppendAllText(log, Line(now.AddSeconds(6), 3513350, "failed disk write failure No Error"), Utf8);
        var failed = InstallDiscovery.ObserveSteam(install, success, now.AddSeconds(7)); Eq("error", failed["phase"], "No Error does not mask failure");
        var idle = InstallDiscovery.ObserveSteam(install, failed, now.AddSeconds(8)); Eq("STEAM_UPDATE_ERROR", idle["errorCode"], "error persists idle"); True(!String.IsNullOrWhiteSpace((string)idle["detail"]), "error detail persists");
        File.AppendAllText(log, Line(now.AddSeconds(8), 3513350, "Fully Installed"), Utf8);
        var recovered = InstallDiscovery.ObserveSteam(install, idle, now.AddSeconds(9)); Eq("update_ready", recovered["phase"], "recovery"); Eq("", recovered["errorCode"], "recovery clears error"); Eq("", recovered["detail"], "recovery clears detail");
        string partial = Line(now.AddSeconds(9), 3513350, "Paused").TrimEnd('\n'); File.AppendAllText(log, partial, Utf8);
        var pending = InstallDiscovery.ObserveSteam(install, recovered, now.AddSeconds(10)); Eq("update_ready", pending["phase"], "incomplete line deferred"); Eq(partial, pending["partial"], "partial retained");
        File.AppendAllText(log, "\n", Utf8); var paused = InstallDiscovery.ObserveSteam(install, pending, now.AddSeconds(11)); Eq("paused_download", paused["phase"], "partial completed");
        File.AppendAllText(log, Line(now.AddHours(1), 3513350, "Downloading"), Utf8); var future = InstallDiscovery.ObserveSteam(install, paused, now.AddSeconds(12)); Eq("paused_download", future["phase"], "future log ignored");
        Write(log, Line(now.AddHours(-1), 3513350, "Downloading")); var rotated = InstallDiscovery.ObserveSteam(install, future, now.AddSeconds(13)); Eq(paused["lastProgressAtUtc"], rotated["lastProgressAtUtc"], "old rotation not progress");
        Write(log, new string('x', 70000) + "\n" + Line(now.AddSeconds(13), 3513350, "Verifying")); var tail = InstallDiscovery.ObserveSteam(install, rotated, now.AddSeconds(14)); Eq("verifying", tail["phase"], "bounded tail finds fresh complete line");
        File.AppendAllText(log, new string('x', 4097), Utf8); var longPartial = InstallDiscovery.ObserveSteam(install, tail, now.AddSeconds(15)); Eq("", longPartial["partial"], "unbounded partial discarded");
        File.Delete(log); var unavailable = InstallDiscovery.ObserveSteam(install, longPartial, now.AddSeconds(16)); Eq("verifying", unavailable["phase"], "missing log never success"); True(((string)unavailable["detail"]).Length > 0, "missing log explains");
        Write(manifest, "\"AppState\" { \"appid\" \"123\" }"); var invalid = InstallDiscovery.ObserveSteam(install, unavailable, now.AddSeconds(17)); Eq("STEAM_MANIFEST_INVALID", invalid["errorCode"], "wrong manifest fails closed"); Eq("unknown", invalid["phase"], "invalid manifest clears trusted phase");
        Write(manifest, "\"AppState\" { \"appid\" \"3513350\" \"BytesDownloaded\" \"201\" \"BytesToDownload\" \"200\" }");
        Write(log, ""); var sample = InstallDiscovery.ObserveSteam(install, null, now);
        File.AppendAllText(log, Line(now, 3513350, "Downloading"), Utf8); sample = InstallDiscovery.ObserveSteam(install, sample, now.AddSeconds(1));
        Eq(null, sample["progressPercent"], "done exceeding total rejected");
        Write(manifest, "\"AppState\" { \"appid\" \"3513350\" \"BytesDownloaded\" \"0\" \"BytesToDownload\" \"0\" }");
        sample = InstallDiscovery.ObserveSteam(install, sample, now.AddSeconds(2)); Eq(null, sample["progressPercent"], "zero denominator rejected");
        Write(manifest, "\"AppState\" { \"appid\" \"3513350\" \"BytesDownloaded\" \"60\" \"BytesToDownload\" \"200\" }");
        sample = InstallDiscovery.ObserveSteam(install, sample, now.AddSeconds(3)); Eq(30.0, sample["progressPercent"], "active-stage manifest progress"); Eq(now.AddSeconds(3).ToString("o", CultureInfo.InvariantCulture), sample["lastProgressAtUtc"], "changed bytes refresh progress");
        File.AppendAllText(log, Line(now.AddSeconds(3), 3513350, "Queued"), Utf8); sample = InstallDiscovery.ObserveSteam(install, sample, now.AddSeconds(4)); Eq("queued", sample["phase"], "queue distinct"); Eq(null, sample["progressPercent"], "queue not download percentage");
        Write(manifest, "\"AppState\" { \"appid\" \"3513350\""); sample = InstallDiscovery.ObserveSteam(install, sample, now.AddSeconds(5)); Eq("STEAM_MANIFEST_INVALID", sample["errorCode"], "half-written manifest rejected");
    }
    private static string Line(DateTimeOffset stamp, int appId, string phase) { return "[" + stamp.LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + "] AppID " + appId + " update changed : " + phase + ",\n"; }
}
