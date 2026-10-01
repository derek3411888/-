using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.Versioning;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using Wuthering.Native;

public static class RuntimeUtilitiesTests
{
    sealed class CliResult
    {
        public int ExitCode;
        public string Output;
        public string Error;
        public long ElapsedMilliseconds;
    }

    enum SmtpMode
    {
        Accept,
        RejectAuthentication,
        StallAfterEhlo
    }

    sealed class LoopbackSmtpServer : IDisposable
    {
        readonly TcpListener listener;
        readonly Thread thread;
        readonly SmtpMode mode;
        readonly string rejectionText;
        Exception failure;
        readonly ManualResetEvent completed = new ManualResetEvent(false);

        public readonly List<string> Commands = new List<string>();
        public string Data = "";
        public string SuppliedPassword = "";

        public int Port
        {
            get { return ((IPEndPoint)listener.LocalEndpoint).Port; }
        }

        public LoopbackSmtpServer(SmtpMode mode, string rejectionText)
        {
            this.mode = mode;
            this.rejectionText = rejectionText ?? "authentication rejected";
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Start();
        }

        void Run()
        {
            try
            {
                using (TcpClient client = listener.AcceptTcpClient())
                using (NetworkStream stream = client.GetStream())
                using (StreamReader reader = new StreamReader(stream, new UTF8Encoding(false), false, 4096, true))
                using (StreamWriter writer = new StreamWriter(stream, new UTF8Encoding(false), 4096, true))
                {
                    writer.NewLine = "\r\n";
                    writer.AutoFlush = true;
                    writer.WriteLine("220 loopback.test ESMTP ready");

                    string line = reader.ReadLine();
                    if (line == null || !line.StartsWith("EHLO ", StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("Expected EHLO, got: " + line);
                    Commands.Add(line);

                    if (mode == SmtpMode.StallAfterEhlo)
                    {
                        Thread.Sleep(4000);
                        return;
                    }

                    if (mode == SmtpMode.RejectAuthentication)
                    {
                        writer.WriteLine("250-loopback.test");
                        writer.WriteLine("250-AUTH LOGIN");
                        writer.WriteLine("250 SIZE 1048576");
                        HandleRejectedAuthentication(reader, writer);
                        return;
                    }

                    writer.WriteLine("250-loopback.test");
                    writer.WriteLine("250 SIZE 1048576");
                    while ((line = reader.ReadLine()) != null)
                    {
                        Commands.Add(line);
                        if (line.StartsWith("MAIL FROM:", StringComparison.OrdinalIgnoreCase)
                            || line.StartsWith("RCPT TO:", StringComparison.OrdinalIgnoreCase))
                        {
                            writer.WriteLine("250 2.1.5 accepted");
                        }
                        else if (line.Equals("DATA", StringComparison.OrdinalIgnoreCase))
                        {
                            writer.WriteLine("354 end with <CRLF>.<CRLF>");
                            StringBuilder data = new StringBuilder();
                            while ((line = reader.ReadLine()) != null && line != ".")
                            {
                                if (line.StartsWith("..", StringComparison.Ordinal))
                                    line = line.Substring(1);
                                data.Append(line).Append("\r\n");
                            }
                            Data = data.ToString();
                            writer.WriteLine("250 2.0.0 queued locally");
                        }
                        else if (line.Equals("QUIT", StringComparison.OrdinalIgnoreCase))
                        {
                            writer.WriteLine("221 2.0.0 bye");
                            return;
                        }
                        else
                        {
                            writer.WriteLine("250 2.0.0 ok");
                        }
                    }
                }
            }
            catch (Exception exception)
            {
                failure = exception;
            }
            finally
            {
                completed.Set();
            }
        }

        void HandleRejectedAuthentication(StreamReader reader, StreamWriter writer)
        {
            string line = reader.ReadLine();
            if (line == null || !line.StartsWith("AUTH LOGIN", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Expected AUTH LOGIN, got: " + line);
            Commands.Add(line);
            string[] parts = line.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 3)
            {
                writer.WriteLine("334 VXNlcm5hbWU6");
                line = reader.ReadLine();
                Commands.Add(line ?? "");
            }
            writer.WriteLine("334 UGFzc3dvcmQ6");
            string encodedPassword = reader.ReadLine();
            Commands.Add(encodedPassword ?? "");
            if (!String.IsNullOrEmpty(encodedPassword))
                SuppliedPassword = Encoding.UTF8.GetString(Convert.FromBase64String(encodedPassword));
            writer.WriteLine("535 5.7.8 " + rejectionText);
        }

        public void Wait(int timeoutMilliseconds)
        {
            if (!completed.WaitOne(timeoutMilliseconds))
                throw new TimeoutException("Loopback SMTP fixture did not complete");
            if (failure != null)
                throw new Exception("Loopback SMTP fixture failed", failure);
        }

        public void Dispose()
        {
            listener.Stop();
            completed.WaitOne(5000);
            completed.Dispose();
        }
    }

    static int checks;
    static string runRoot;
    static string helperPath;
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

    static void Check(bool condition, string message)
    {
        if (!condition)
            throw new Exception(message);
        checks++;
    }

    static Dictionary<string, object> ParseObject(string json)
    {
        object value = Json.DeserializeObject(json);
        Dictionary<string, object> result = value as Dictionary<string, object>;
        if (result == null)
            throw new Exception("Expected one JSON object, got: " + json);
        return result;
    }

    static bool JsonBool(Dictionary<string, object> value, string key)
    {
        return value.ContainsKey(key) && value[key] is bool && (bool)value[key];
    }

    static int JsonInt(Dictionary<string, object> value, string key)
    {
        return Convert.ToInt32(value[key]);
    }

    static string JsonString(Dictionary<string, object> value, string key)
    {
        return value.ContainsKey(key) && value[key] != null ? Convert.ToString(value[key]) : "";
    }

    static CliResult Invoke(string operation, string input, int timeoutMilliseconds)
    {
        ProcessStartInfo start = new ProcessStartInfo(helperPath, operation);
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardInput = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        start.EnvironmentVariables["RUNTIME_UTILITIES_TEST_LOOPBACK_ONLY"] = "1";
        Stopwatch elapsed = Stopwatch.StartNew();
        using (Process process = Process.Start(start))
        {
            byte[] bytes = new UTF8Encoding(false).GetBytes(input);
            process.StandardInput.BaseStream.Write(bytes, 0, bytes.Length);
            process.StandardInput.BaseStream.Flush();
            process.StandardInput.Close();
            string output = process.StandardOutput.ReadToEnd();
            string error = process.StandardError.ReadToEnd();
            if (!process.WaitForExit(timeoutMilliseconds))
            {
                process.Kill();
                process.WaitForExit();
                throw new TimeoutException("RuntimeUtilities CLI exceeded test timeout");
            }
            elapsed.Stop();
            return new CliResult
            {
                ExitCode = process.ExitCode,
                Output = output.Trim(),
                Error = error.Trim(),
                ElapsedMilliseconds = elapsed.ElapsedMilliseconds
            };
        }
    }

    static string HeaderValue(string rawMessage, string name)
    {
        int split = rawMessage.IndexOf("\r\n\r\n", StringComparison.Ordinal);
        string headers = split >= 0 ? rawMessage.Substring(0, split) : rawMessage;
        string unfolded = Regex.Replace(headers, "\r\n[ \t]+", " ");
        Match match = Regex.Match(unfolded, "(?:^|\\r\\n)" + Regex.Escape(name) + ":\\s*(.*?)(?:\\r\\n|$)", RegexOptions.IgnoreCase);
        return match.Success ? match.Groups[1].Value.Trim() : "";
    }

    static string DecodeMimeHeader(string value)
    {
        return Regex.Replace(value, @"=\?utf-8\?([bq])\?([^?]+)\?=", delegate(Match match)
        {
            if (match.Groups[1].Value.Equals("b", StringComparison.OrdinalIgnoreCase))
                return Encoding.UTF8.GetString(Convert.FromBase64String(match.Groups[2].Value));
            return DecodeQuotedPrintable(match.Groups[2].Value.Replace('_', ' '));
        }, RegexOptions.IgnoreCase);
    }

    static string DecodeQuotedPrintable(string value)
    {
        value = value.Replace("=\r\n", "");
        using (MemoryStream bytes = new MemoryStream())
        {
            for (int index = 0; index < value.Length; index++)
            {
                if (value[index] == '=' && index + 2 < value.Length)
                {
                    int high = Hex(value[index + 1]);
                    int low = Hex(value[index + 2]);
                    if (high >= 0 && low >= 0)
                    {
                        bytes.WriteByte((byte)((high << 4) | low));
                        index += 2;
                        continue;
                    }
                }
                byte[] literal = Encoding.UTF8.GetBytes(new[] { value[index] });
                bytes.Write(literal, 0, literal.Length);
            }
            return Encoding.UTF8.GetString(bytes.ToArray());
        }
    }

    static int Hex(char value)
    {
        if (value >= '0' && value <= '9') return value - '0';
        if (value >= 'a' && value <= 'f') return value - 'a' + 10;
        if (value >= 'A' && value <= 'F') return value - 'A' + 10;
        return -1;
    }

    static string DecodeBody(string rawMessage)
    {
        int split = rawMessage.IndexOf("\r\n\r\n", StringComparison.Ordinal);
        if (split < 0)
            return "";
        string body = rawMessage.Substring(split + 4).TrimEnd('\r', '\n');
        string transfer = HeaderValue(rawMessage, "Content-Transfer-Encoding");
        if (transfer.Equals("base64", StringComparison.OrdinalIgnoreCase))
            return Encoding.UTF8.GetString(Convert.FromBase64String(Regex.Replace(body, @"\s", "")));
        if (transfer.Equals("quoted-printable", StringComparison.OrdinalIgnoreCase))
            return DecodeQuotedPrintable(body);
        return body;
    }

    static Dictionary<string, object> MailRequest(int port, int timeoutMilliseconds, string password, string subject, string body)
    {
        return new Dictionary<string, object>
        {
            { "smtpHost", "127.0.0.1" },
            { "smtpPort", port },
            { "smtpUser", "synthetic-user" },
            { "smtpPass", password },
            { "mailFrom", "sender@example.test" },
            { "mailTo", "first@example.test, second@example.test" },
            { "subject", subject },
            { "body", body },
            { "useSsl", false },
            { "timeoutMs", timeoutMilliseconds }
        };
    }

    static void TestFrameworkAndTargeting()
    {
        TargetFrameworkAttribute framework = (TargetFrameworkAttribute)Attribute.GetCustomAttribute(
            typeof(RuntimeUtilities).Assembly, typeof(TargetFrameworkAttribute));
        Check(framework != null && framework.FrameworkName == ".NETFramework,Version=v4.8", "Helper must target .NET Framework 4.8");

        HashSet<int> pids = new HashSet<int>();
        pids.Add(4242);
        HashSet<string> names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        names.Add("client-win64-shipping");
        Check(AudioTargetMatcher.IsTarget(4242, "Client-Win64-Shipping.exe", pids, names), "Exact PID and normalized process name match");
        Check(!AudioTargetMatcher.IsTarget(4243, "Client-Win64-Shipping.exe", pids, names), "Process name alone must never target another PID");
        Check(!AudioTargetMatcher.IsTarget(4242, "unrelated.exe", pids, names), "Name allow-list rejects PID reuse by another executable");
        Check(AudioTargetMatcher.IsTarget(4242, "unrelated.exe", pids, new HashSet<string>(StringComparer.OrdinalIgnoreCase)), "Exact PID remains sufficient when no name constraint is supplied");
        string parseError;
        HashSet<int> parsed;
        Check(AudioTargetMatcher.TryParsePidCsv("4242, 4242", out parsed, out parseError) && parsed.Count == 1, "PID parser de-duplicates exact numeric targets");
        Check(!AudioTargetMatcher.TryParsePidCsv("4242,not-a-pid", out parsed, out parseError), "Malformed PID list is rejected instead of broadening selection");
    }

    static void TestMalformedJsonIsBoundedAndRedacted()
    {
        const string secret = "NeverEchoThisSecret-123";
        CliResult result = Invoke("mail", "{\"smtpPass\":\"" + secret + "\",BROKEN", 5000);
        Check(result.ExitCode == RuntimeUtilities.ExitInvalidRequest, "Malformed JSON uses invalid-request exit code");
        Dictionary<string, object> response = ParseObject(result.Output);
        Check(!JsonBool(response, "ok") && JsonString(response, "code") == "invalid_request", "Malformed JSON returns structured error JSON");
        Check(result.Output.IndexOf(secret, StringComparison.Ordinal) < 0 && result.Error.IndexOf(secret, StringComparison.Ordinal) < 0, "Malformed request content and secrets are never echoed");
    }

    static void TestUnicodeMailAndMultipleRecipients()
    {
        const string subject = "鋤地完成 ✅";
        const string body = "第一行\r\n第二行：鳴潮";
        using (LoopbackSmtpServer server = new LoopbackSmtpServer(SmtpMode.Accept, null))
        {
            string request = Json.Serialize(MailRequest(server.Port, 3000, "synthetic-password", subject, body));
            CliResult result = Invoke("mail", request, 8000);
            server.Wait(5000);
            File.WriteAllText(Path.Combine(runRoot, "smtp-capture.txt"), server.Data, new UTF8Encoding(false));
            Dictionary<string, object> response = ParseObject(result.Output);
            Check(result.ExitCode == 0 && JsonBool(response, "ok"), "Real loopback SMTP delivery succeeds through CLI JSON transport");
            Check(result.Error == "", "Successful helper does not write diagnostics or request data to stderr");
            int recipients = 0;
            foreach (string command in server.Commands)
                if (command.StartsWith("RCPT TO:", StringComparison.OrdinalIgnoreCase)) recipients++;
            Check(recipients == 2, "Both normalized recipients are sent to the loopback SMTP server");
            Check(DecodeMimeHeader(HeaderValue(server.Data, "Subject")) == subject, "UTF-8 subject survives SMTP MIME encoding");
            Check(DecodeBody(server.Data) == body, "UTF-8 multiline body survives SMTP transfer encoding");
        }
    }

    static void TestTimeoutIsBounded()
    {
        using (LoopbackSmtpServer server = new LoopbackSmtpServer(SmtpMode.StallAfterEhlo, null))
        {
            string request = Json.Serialize(MailRequest(server.Port, 600, "synthetic-password", "timeout", "timeout"));
            CliResult result = Invoke("mail", request, 7000);
            Dictionary<string, object> response = ParseObject(result.Output);
            Check(result.ExitCode == RuntimeUtilities.ExitTimeout && JsonString(response, "code") == "timeout", "Stalled SMTP exchange returns the dedicated timeout result");
            Check(result.ElapsedMilliseconds < 3500, "SMTP timeout is enforced before the fixture's four-second stall ends");
        }
    }

    static void TestAuthenticationFailureRedactsSecrets()
    {
        const string password = "DoNotLeak-123";
        using (LoopbackSmtpServer server = new LoopbackSmtpServer(
            SmtpMode.RejectAuthentication, password + " " + new string('X', 1024)))
        {
            MailRequest request = new MailRequest
            {
                smtpHost = "127.0.0.1",
                smtpPort = server.Port,
                smtpUser = "synthetic-user",
                smtpPass = password,
                mailFrom = "sender@example.test",
                mailTo = "recipient@example.test",
                subject = "redaction",
                body = "redaction",
                useSsl = false,
                timeoutMs = 2500
            };
            RuntimeResponse response = MailSender.Send(request);
            server.Wait(5000);
            string encodedPassword = Convert.ToBase64String(Encoding.UTF8.GetBytes(password));
            Check((ServicePointManager.SecurityProtocol & SecurityProtocolType.Tls12) == SecurityProtocolType.Tls12, "Mail path pins TLS 1.2 in its process");
            Check(!response.ok && response.code == "smtp_error", "SMTP authentication rejection is reported as an error");
            Check(server.SuppliedPassword == password, "Loopback stub exercised real synthetic credential transport");
            Check(response.message.IndexOf(password, StringComparison.OrdinalIgnoreCase) < 0, "Plaintext password is redacted from errors");
            Check(response.message.IndexOf(encodedPassword, StringComparison.OrdinalIgnoreCase) < 0, "Encoded password is redacted from errors");
            Check(response.message.Length <= 620, "SMTP diagnostics are capped below the stdout pipe budget");
            Check(Encoding.UTF8.GetByteCount(Json.Serialize(response)) < 4096, "Largest SMTP response remains below one anonymous-pipe page");
        }
    }

    static void TestExternalNetworkIsBlockedInTestMode()
    {
        Environment.SetEnvironmentVariable("RUNTIME_UTILITIES_TEST_LOOPBACK_ONLY", "1");
        MailRequest request = new MailRequest
        {
            smtpHost = "smtp.example.invalid",
            smtpPort = 587,
            smtpUser = "synthetic-user",
            smtpPass = "synthetic-password",
            mailFrom = "sender@example.test",
            mailTo = "recipient@example.test",
            subject = "must not leave host",
            body = "must not leave host",
            useSsl = true,
            timeoutMs = 1000
        };
        RuntimeResponse response = MailSender.Send(request);
        Check(!response.ok && response.code == "test_network_blocked", "Test mode rejects every non-loopback SMTP endpoint before connection");
    }

    static void TestShortCredentialServerEchoIsNeverReturned()
    {
        foreach (string secret in new[] { "a", "ab", "abc" })
        {
            string encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(secret));
            using (LoopbackSmtpServer server = new LoopbackSmtpServer(
                SmtpMode.RejectAuthentication, "REMOTE_ECHO " + secret + " " + encoded))
            {
                Dictionary<string, object> request = MailRequest(server.Port, 2500, secret, "test", "test");
                request["smtpUser"] = secret;
                CliResult result = Invoke("mail", Json.Serialize(request), 8000);
                server.Wait(5000);
                Dictionary<string, object> response = ParseObject(result.Output);
                Check(JsonString(response, "code") == "smtp_error", "Short credential rejection stays an SMTP failure");
                Check(JsonString(response, "message") == "SMTP send failed. Check server availability, credentials and TLS settings.",
                    "Untrusted server text must never enter diagnostics, even for one-character credentials");
                Check(result.Error == "", "Credential rejection does not leak to stderr");
            }
        }
    }

    static void TestNoTargetAudioDoesNotBroadenByName()
    {
        Dictionary<string, object> request = new Dictionary<string, object>
        {
            { "pidCsv", "2147483647" },
            { "nameCsv", "Client-Win64-Shipping.exe" },
            { "mute", true }
        };
        CliResult result = Invoke("audio", Json.Serialize(request), 5000);
        Dictionary<string, object> response = ParseObject(result.Output);
        Check(result.ExitCode == RuntimeUtilities.ExitNoTarget, "Missing exact PID returns historical no-session exit code 2");
        Check(!JsonBool(response, "ok") && JsonString(response, "code") == "no_target" && JsonInt(response, "matchedCount") == 0, "No-target audio returns structured zero-match result");

        request["pidCsv"] = "";
        result = Invoke("audio", Json.Serialize(request), 5000);
        response = ParseObject(result.Output);
        Check(result.ExitCode == RuntimeUtilities.ExitNoTarget && JsonString(response, "code") == "no_target", "Name-only audio request cannot mutate any process session");
    }

    public static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] == "mail"
                && Environment.GetEnvironmentVariable("RUNTIME_UTILITIES_STALL_STDIN") == "1")
            {
                Thread.Sleep(10000);
                return 0;
            }
            if (args.Length != 2)
                throw new ArgumentException("Expected test output root and RuntimeUtilities.exe path");
            runRoot = Path.GetFullPath(args[0]);
            helperPath = Path.GetFullPath(args[1]);
            Directory.CreateDirectory(runRoot);
            Environment.SetEnvironmentVariable("RUNTIME_UTILITIES_TEST_LOOPBACK_ONLY", "1");

            TestFrameworkAndTargeting();
            TestMalformedJsonIsBoundedAndRedacted();
            TestUnicodeMailAndMultipleRecipients();
            TestTimeoutIsBounded();
            TestAuthenticationFailureRedactsSecrets();
            TestShortCredentialServerEchoIsNeverReturned();
            TestExternalNetworkIsBlockedInTestMode();
            TestNoTargetAudioDoesNotBroadenByName();

            Console.WriteLine("PASS RuntimeUtilities native tests: " + checks + " checks");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
    }
}
