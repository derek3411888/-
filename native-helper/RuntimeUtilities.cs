using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Mail;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace Wuthering.Native
{
    public sealed class RuntimeResponse
    {
        public bool ok { get; set; }
        public string code { get; set; }
        public string message { get; set; }
        public int exitCode { get; set; }
        public int matchedCount { get; set; }
        public int changedCount { get; set; }

        public static RuntimeResponse Success(string message)
        {
            return new RuntimeResponse
            {
                ok = true,
                code = "ok",
                message = message ?? "",
                exitCode = RuntimeUtilities.ExitSuccess
            };
        }

        public static RuntimeResponse Failure(string code, string message, int exitCode)
        {
            return new RuntimeResponse
            {
                ok = false,
                code = code ?? "error",
                message = message ?? "",
                exitCode = exitCode
            };
        }
    }

    public sealed class MailRequest
    {
        public string smtpHost { get; set; }
        public int smtpPort { get; set; }
        public string smtpUser { get; set; }
        public string smtpPass { get; set; }
        public string mailFrom { get; set; }
        public string mailTo { get; set; }
        public string subject { get; set; }
        public string body { get; set; }
        public bool useSsl { get; set; }
        public int timeoutMs { get; set; }
    }

    public sealed class AudioRequest
    {
        public string pidCsv { get; set; }
        public string nameCsv { get; set; }
        public bool mute { get; set; }
    }

    public static class RuntimeUtilities
    {
        public const int ExitSuccess = 0;
        public const int ExitNoTarget = 2;
        public const int ExitInvalidRequest = 64;
        public const int ExitRuntimeError = 70;
        public const int ExitTransportError = 71;
        public const int ExitTimeout = 124;
        const int MaximumRequestCharacters = 1024 * 1024;

        public static int Main(string[] args)
        {
            RuntimeResponse response;
            try
            {
                Console.InputEncoding = new UTF8Encoding(false, true);
                Console.OutputEncoding = new UTF8Encoding(false);
                if (args == null || args.Length != 1)
                {
                    response = RuntimeResponse.Failure("invalid_operation", "Expected exactly one operation: mail or audio.", ExitInvalidRequest);
                }
                else
                {
                    string json = ReadRequest();
                    if (String.Equals(args[0], "mail", StringComparison.OrdinalIgnoreCase))
                        response = MailSender.Send(Deserialize<MailRequest>(json));
                    else if (String.Equals(args[0], "audio", StringComparison.OrdinalIgnoreCase))
                        response = AudioSessionMuter.SetMute(Deserialize<AudioRequest>(json));
                    else
                        response = RuntimeResponse.Failure("invalid_operation", "Unknown operation.", ExitInvalidRequest);
                }
            }
            catch (InvalidDataException exception)
            {
                response = RuntimeResponse.Failure("invalid_request", exception.Message, ExitInvalidRequest);
            }
            catch (Exception)
            {
                response = RuntimeResponse.Failure("runtime_error", "Native runtime utility failed.", ExitRuntimeError);
            }

            try
            {
                JavaScriptSerializer serializer = NewSerializer();
                Console.Out.WriteLine(serializer.Serialize(response));
                Console.Out.Flush();
            }
            catch (Exception)
            {
                return ExitRuntimeError;
            }
            return response.exitCode;
        }

        static JavaScriptSerializer NewSerializer()
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = MaximumRequestCharacters;
            serializer.RecursionLimit = 20;
            return serializer;
        }

        static T Deserialize<T>(string json) where T : class
        {
            try
            {
                T result = NewSerializer().Deserialize<T>(json);
                if (result == null)
                    throw new InvalidDataException("Request must be one JSON object.");
                return result;
            }
            catch (InvalidDataException)
            {
                throw;
            }
            catch (Exception)
            {
                throw new InvalidDataException("Request JSON is invalid.");
            }
        }

        static string ReadRequest()
        {
            StringBuilder request = new StringBuilder();
            char[] buffer = new char[4096];
            using (StreamReader reader = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false, true), false, 4096))
            {
                int read;
                while ((read = reader.Read(buffer, 0, buffer.Length)) > 0)
                {
                    if (request.Length + read > MaximumRequestCharacters)
                        throw new InvalidDataException("Request is too large.");
                    request.Append(buffer, 0, read);
                }
            }
            if (String.IsNullOrWhiteSpace(request.ToString()))
                throw new InvalidDataException("Request JSON is required.");
            return request.ToString();
        }
    }

    public static class MailSender
    {
        const int MinimumTimeoutMilliseconds = 500;
        const int MaximumTimeoutMilliseconds = 120000;

        public static RuntimeResponse Send(MailRequest request)
        {
            string validation;
            List<MailAddress> recipients;
            MailAddress from;
            if (!TryValidate(request, out from, out recipients, out validation))
                return RuntimeResponse.Failure("invalid_request", validation, RuntimeUtilities.ExitInvalidRequest);

            if (TestModeBlocks(request.smtpHost))
                return RuntimeResponse.Failure("test_network_blocked", "Test mode permits loopback SMTP only.", RuntimeUtilities.ExitInvalidRequest);

            Stopwatch elapsed = Stopwatch.StartNew();
            try
            {
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
                using (MailMessage message = new MailMessage())
                {
                    message.From = from;
                    foreach (MailAddress recipient in recipients)
                        message.To.Add(recipient);
                    message.Subject = request.subject ?? "";
                    message.Body = request.body ?? "";
                    message.SubjectEncoding = new UTF8Encoding(false);
                    message.BodyEncoding = new UTF8Encoding(false);
                    message.IsBodyHtml = false;

                    using (SmtpClient client = new SmtpClient(request.smtpHost, request.smtpPort))
                    {
                        client.DeliveryMethod = SmtpDeliveryMethod.Network;
                        client.UseDefaultCredentials = false;
                        client.Credentials = new NetworkCredential(request.smtpUser, request.smtpPass);
                        client.EnableSsl = request.useSsl;
                        client.Timeout = request.timeoutMs;
                        client.Send(message);
                    }
                }
                return RuntimeResponse.Success("");
            }
            catch (SmtpException exception)
            {
                if (elapsed.ElapsedMilliseconds + 50 >= request.timeoutMs || IsTimeout(exception))
                    return RuntimeResponse.Failure("timeout", "SMTP send timed out.", RuntimeUtilities.ExitTimeout);
                return RuntimeResponse.Failure("smtp_error", SafeError(exception, request), RuntimeUtilities.ExitRuntimeError);
            }
            catch (Exception exception)
            {
                if (elapsed.ElapsedMilliseconds + 50 >= request.timeoutMs || IsTimeout(exception))
                    return RuntimeResponse.Failure("timeout", "SMTP send timed out.", RuntimeUtilities.ExitTimeout);
                return RuntimeResponse.Failure("smtp_error", SafeError(exception, request), RuntimeUtilities.ExitRuntimeError);
            }
        }

        static bool TryValidate(MailRequest request, out MailAddress from, out List<MailAddress> recipients, out string error)
        {
            from = null;
            recipients = new List<MailAddress>();
            error = "";
            if (request == null)
            {
                error = "Mail request is required.";
                return false;
            }
            request.smtpHost = (request.smtpHost ?? "").Trim();
            request.smtpUser = request.smtpUser ?? "";
            request.smtpPass = request.smtpPass ?? "";
            request.mailFrom = (request.mailFrom ?? "").Trim();
            request.mailTo = request.mailTo ?? "";
            if (request.smtpHost.Length == 0 || request.smtpHost.Length > 255)
            {
                error = "SMTP host is invalid.";
                return false;
            }
            if (request.smtpPort < 1 || request.smtpPort > 65535)
            {
                error = "SMTP port is invalid.";
                return false;
            }
            if (request.smtpUser.Length == 0 || request.smtpPass.Length == 0)
            {
                error = "SMTP credentials are required.";
                return false;
            }
            if (request.timeoutMs < MinimumTimeoutMilliseconds || request.timeoutMs > MaximumTimeoutMilliseconds)
            {
                error = "SMTP timeout is outside the supported range.";
                return false;
            }
            if ((request.subject ?? "").Length > 998 || (request.body ?? "").Length > 900000)
            {
                error = "Mail content is too large.";
                return false;
            }
            try
            {
                from = new MailAddress(request.mailFrom);
                foreach (string token in request.mailTo.Split(new[] { ',', ';', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    string address = token.Trim();
                    if (address.Length > 0)
                        recipients.Add(new MailAddress(address));
                }
            }
            catch (FormatException)
            {
                error = "Mail address is invalid.";
                return false;
            }
            if (recipients.Count == 0)
            {
                error = "At least one recipient is required.";
                return false;
            }
            return true;
        }

        static bool TestModeBlocks(string smtpHost)
        {
            if (!String.Equals(Environment.GetEnvironmentVariable("RUNTIME_UTILITIES_TEST_LOOPBACK_ONLY"), "1", StringComparison.Ordinal))
                return false;
            IPAddress address;
            if (IPAddress.TryParse(smtpHost, out address))
                return !IPAddress.IsLoopback(address);
            return !String.Equals(smtpHost, "localhost", StringComparison.OrdinalIgnoreCase);
        }

        static bool IsTimeout(Exception exception)
        {
            for (Exception current = exception; current != null; current = current.InnerException)
            {
                if (current is TimeoutException)
                    return true;
                if (current.Message != null && current.Message.IndexOf("timed out", StringComparison.OrdinalIgnoreCase) >= 0)
                    return true;
            }
            return false;
        }

        static string SafeError(Exception exception, MailRequest request)
        {
            // SMTP servers may echo credentials in arbitrary representations.
            // Never include remote exception text in a loggable response.
            return "SMTP send failed. Check server availability, credentials and TLS settings.";
        }
    }

    public static class AudioTargetMatcher
    {
        public static bool TryParsePidCsv(string pidCsv, out HashSet<int> pids, out string error)
        {
            pids = new HashSet<int>();
            error = "";
            if (String.IsNullOrWhiteSpace(pidCsv))
                return true;
            foreach (string raw in pidCsv.Split(','))
            {
                string token = raw.Trim();
                int pid;
                if (token.Length == 0)
                    continue;
                if (!Int32.TryParse(token, out pid) || pid <= 0)
                {
                    error = "PID list contains an invalid value.";
                    pids.Clear();
                    return false;
                }
                pids.Add(pid);
            }
            return true;
        }

        public static HashSet<string> ParseNameCsv(string nameCsv)
        {
            HashSet<string> names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (String.IsNullOrWhiteSpace(nameCsv))
                return names;
            foreach (string raw in nameCsv.Split(','))
            {
                string name = NormalizeName(raw);
                if (name.Length > 0)
                    names.Add(name);
            }
            return names;
        }

        public static bool IsTarget(int sessionPid, string processName, HashSet<int> pids, HashSet<string> names)
        {
            if (sessionPid <= 0 || pids == null || !pids.Contains(sessionPid))
                return false;
            if (names == null || names.Count == 0)
                return true;
            return names.Contains(NormalizeName(processName));
        }

        public static string NormalizeName(string name)
        {
            string normalized = (name ?? "").Trim();
            if (normalized.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                normalized = normalized.Substring(0, normalized.Length - 4);
            return normalized;
        }
    }

    enum EDataFlow
    {
        Render,
        Capture,
        All
    }

    enum ERole
    {
        Console,
        Multimedia,
        Communications
    }

    [Flags]
    enum ClsCtx : uint
    {
        InprocServer = 0x1,
        InprocHandler = 0x2,
        LocalServer = 0x4,
        RemoteServer = 0x10,
        All = InprocServer | InprocHandler | LocalServer | RemoteServer
    }

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject
    {
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr callback);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr callback);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, ClsCtx context, IntPtr activationParameters, [MarshalAs(UnmanagedType.IUnknown)] out object value);
        [PreserveSig] int OpenPropertyStore(uint access, out IntPtr properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out uint state);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F")]
    interface IAudioSessionManager2
    {
        [PreserveSig] int GetAudioSessionControl(ref Guid sessionGuid, uint streamFlags, out IAudioSessionControl sessionControl);
        [PreserveSig] int GetSimpleAudioVolume(ref Guid sessionGuid, uint streamFlags, out ISimpleAudioVolume audioVolume);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessionEnumerator);
        [PreserveSig] int RegisterSessionNotification(IntPtr notification);
        [PreserveSig] int UnregisterSessionNotification(IntPtr notification);
        [PreserveSig] int RegisterDuckNotification([MarshalAs(UnmanagedType.LPWStr)] string sessionId, IntPtr notification);
        [PreserveSig] int UnregisterDuckNotification(IntPtr notification);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8")]
    interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int sessionCount);
        [PreserveSig] int GetSession(int sessionIndex, out IAudioSessionControl session);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD")]
    interface IAudioSessionControl
    {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string displayName);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string value, ref Guid eventContext);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string iconPath);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string value, ref Guid eventContext);
        [PreserveSig] int GetGroupingParam(out Guid groupingId);
        [PreserveSig] int SetGroupingParam(ref Guid groupingId, ref Guid eventContext);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr notification);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr notification);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D")]
    interface IAudioSessionControl2
    {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string displayName);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string value, ref Guid eventContext);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string iconPath);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string value, ref Guid eventContext);
        [PreserveSig] int GetGroupingParam(out Guid groupingId);
        [PreserveSig] int SetGroupingParam(ref Guid groupingId, ref Guid eventContext);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr notification);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr notification);
        [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string identifier);
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string identifier);
        [PreserveSig] int GetProcessId(out uint processId);
        [PreserveSig] int IsSystemSoundsSession();
        [PreserveSig] int SetDuckingPreference([MarshalAs(UnmanagedType.Bool)] bool optOut);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8")]
    interface ISimpleAudioVolume
    {
        [PreserveSig] int SetMasterVolume(float level, ref Guid eventContext);
        [PreserveSig] int GetMasterVolume(out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid eventContext);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    public static class AudioSessionMuter
    {
        public static RuntimeResponse SetMute(AudioRequest request)
        {
            if (request == null)
                return RuntimeResponse.Failure("invalid_request", "Audio request is required.", RuntimeUtilities.ExitInvalidRequest);
            HashSet<int> pids;
            string error;
            if (!AudioTargetMatcher.TryParsePidCsv(request.pidCsv, out pids, out error))
                return RuntimeResponse.Failure("invalid_request", error, RuntimeUtilities.ExitInvalidRequest);
            if (pids.Count == 0)
                return NoTarget();
            HashSet<string> names = AudioTargetMatcher.ParseNameCsv(request.nameCsv);

            IMMDeviceEnumerator enumerator = null;
            try
            {
                enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
                int matched = 0;
                int changed = 0;
                int failures = 0;
                HashSet<string> visitedSessions = new HashSet<string>(StringComparer.Ordinal);
                Dictionary<int, string> processNames = new Dictionary<int, string>();
                foreach (ERole role in new[] { ERole.Multimedia, ERole.Console, ERole.Communications })
                    SetMuteOnRole(enumerator, role, pids, names, request.mute, visitedSessions, processNames, ref matched, ref changed, ref failures);
                if (changed > 0)
                {
                    RuntimeResponse success = RuntimeResponse.Success("");
                    success.matchedCount = matched;
                    success.changedCount = changed;
                    return success;
                }
                if (matched > 0 || failures > 0)
                {
                    RuntimeResponse failed = RuntimeResponse.Failure("audio_error", "A matching audio session could not be changed.", RuntimeUtilities.ExitRuntimeError);
                    failed.matchedCount = matched;
                    return failed;
                }
                return NoTarget();
            }
            catch (Exception)
            {
                return RuntimeResponse.Failure("audio_error", "Core Audio session access failed.", RuntimeUtilities.ExitRuntimeError);
            }
            finally
            {
                ReleaseCom(enumerator);
            }
        }

        static RuntimeResponse NoTarget()
        {
            RuntimeResponse result = RuntimeResponse.Failure("no_target", "No exact-PID audio session matched.", RuntimeUtilities.ExitNoTarget);
            result.matchedCount = 0;
            result.changedCount = 0;
            return result;
        }

        static void SetMuteOnRole(
            IMMDeviceEnumerator enumerator,
            ERole role,
            HashSet<int> pids,
            HashSet<string> names,
            bool mute,
            HashSet<string> visitedSessions,
            Dictionary<int, string> processNames,
            ref int matched,
            ref int changed,
            ref int failures)
        {
            IMMDevice device = null;
            IAudioSessionManager2 manager = null;
            IAudioSessionEnumerator sessions = null;
            try
            {
                if (enumerator.GetDefaultAudioEndpoint(EDataFlow.Render, role, out device) != 0 || device == null)
                    return;
                Guid managerId = typeof(IAudioSessionManager2).GUID;
                object activated;
                if (device.Activate(ref managerId, ClsCtx.All, IntPtr.Zero, out activated) != 0 || activated == null)
                    return;
                manager = activated as IAudioSessionManager2;
                if (manager == null || manager.GetSessionEnumerator(out sessions) != 0 || sessions == null)
                    return;
                int count;
                if (sessions.GetCount(out count) != 0)
                    return;
                for (int index = 0; index < count; index++)
                {
                    IAudioSessionControl control = null;
                    try
                    {
                        if (sessions.GetSession(index, out control) != 0 || control == null)
                            continue;
                        IAudioSessionControl2 control2 = control as IAudioSessionControl2;
                        ISimpleAudioVolume volume = control as ISimpleAudioVolume;
                        if (control2 == null || volume == null)
                            continue;
                        uint rawPid;
                        if (control2.GetProcessId(out rawPid) != 0 || rawPid == 0 || rawPid > Int32.MaxValue)
                            continue;
                        int pid = (int)rawPid;
                        string processName = GetProcessName(pid, processNames);
                        if (!AudioTargetMatcher.IsTarget(pid, processName, pids, names))
                            continue;
                        string sessionId;
                        if (control2.GetSessionInstanceIdentifier(out sessionId) != 0 || String.IsNullOrEmpty(sessionId))
                            sessionId = pid.ToString() + ":" + role.ToString() + ":" + index.ToString();
                        if (!visitedSessions.Add(sessionId))
                            continue;
                        matched++;
                        Guid eventContext = Guid.Empty;
                        if (volume.SetMute(mute, ref eventContext) == 0)
                            changed++;
                        else
                            failures++;
                    }
                    catch (Exception)
                    {
                        failures++;
                    }
                    finally
                    {
                        ReleaseCom(control);
                    }
                }
            }
            catch (Exception)
            {
                failures++;
            }
            finally
            {
                ReleaseCom(sessions);
                ReleaseCom(manager);
                ReleaseCom(device);
            }
        }

        static string GetProcessName(int pid, Dictionary<int, string> cache)
        {
            string name;
            if (cache.TryGetValue(pid, out name))
                return name;
            name = "";
            try
            {
                using (Process process = Process.GetProcessById(pid))
                    name = process.ProcessName;
            }
            catch (Exception)
            {
                name = "";
            }
            cache[pid] = name;
            return name;
        }

        static void ReleaseCom(object value)
        {
            if (value == null || !Marshal.IsComObject(value))
                return;
            try
            {
                Marshal.FinalReleaseComObject(value);
            }
            catch (Exception)
            {
            }
        }
    }
}
