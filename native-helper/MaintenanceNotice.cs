using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace Wuthering.Native
{
    public static class MaintenanceNotice
    {
        private const int MaxResponseBytes = 2097152;
        private const int MaxCacheBytes = 262144;
        private const string FeedBase = "https://hw-media-cdn-mingchao.kurogame.com/akiwebsite/website2.0/json/G152/zh-tw/";
        private const string UtcFormat = "yyyy-MM-ddTHH:mm:ssZ";
        private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;
        private static readonly TimeSpan TaipeiOffset = TimeSpan.FromHours(8);

        private static Dictionary<string, object> D(params object[] values)
        {
            var result = new Dictionary<string, object>();
            for (int i = 0; i < values.Length; i += 2) result.Add((string)values[i], values[i + 1]);
            return result;
        }
        private static object Value(Dictionary<string, object> obj, string name)
        {
            object value; return obj != null && obj.TryGetValue(name, out value) ? value : null;
        }
        private static string S(Dictionary<string, object> obj, string name) { return Convert.ToString(Value(obj, name), Invariant) ?? ""; }
        private static object[] Items(object value)
        {
            var items = value as IList;
            return items == null ? new object[0] : items.Cast<object>().ToArray();
        }
        private static string Utc(DateTimeOffset value) { return value.UtcDateTime.ToString(UtcFormat, Invariant); }
        private static string Day(DateTimeOffset value) { return value.ToOffset(TaipeiOffset).ToString("yyyy-MM-dd", Invariant); }
        private static DateTimeOffset Date(Dictionary<string, object> obj, string name) { return DateTimeOffset.ParseExact(S(obj, name), UtcFormat, Invariant, DateTimeStyles.AssumeUniversal); }
        private static JavaScriptSerializer Serializer() { return new JavaScriptSerializer { MaxJsonLength = MaxResponseBytes, RecursionLimit = 64 }; }
        private static string Hash(string value)
        {
            using (var hash = SHA256.Create()) return BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(value))).Replace("-", "").ToLowerInvariant();
        }
        private static Dictionary<string, object> Invalid(string reason) { return D("valid", false, "reason", reason, "notice", null); }

        public static bool IsAllowedUrl(string url)
        {
            Uri uri;
            if (!Uri.TryCreate(url, UriKind.Absolute, out uri) || uri.Scheme != Uri.UriSchemeHttps || uri.Port != 443 ||
                uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0) return false;
            if (uri.Host == "hw-media-cdn-mingchao.kurogame.com")
                return Regex.IsMatch(uri.AbsolutePath, @"^/akiwebsite/website2\.0/json/G152/zh-tw/(?:MainMenu\.json|article/\d+\.json)$");
            return uri.Host == "wutheringwaves.kurogames.com" && Regex.IsMatch(uri.AbsolutePath, @"^/zh-tw/(?:main/)?news/detail/\d+$");
        }

        public static Dictionary<string, object> Parse(Dictionary<string, object> article, string sourceUrl, DateTimeOffset fetchedAt)
        {
            if (!IsAllowedUrl(sourceUrl)) return Invalid("UNTRUSTED_SOURCE");
            string title = S(article, "articleTitle"), raw = S(article, "articleContent"), id = S(article, "articleId");
            string gameId = article != null && article.ContainsKey("gameId") ? S(article, "gameId") : "G152-tw";
            if (!string.Equals(gameId, "G152-tw", StringComparison.OrdinalIgnoreCase) || Regex.IsMatch(title, "國服|国服|中國大陸|中国大陆")) return Invalid("WRONG_SCOPE");
            long articleId;
            if (!Regex.IsMatch(id, @"^\d+$") || !long.TryParse(id, NumberStyles.None, Invariant, out articleId) || raw.Length == 0 || Encoding.UTF8.GetByteCount(raw) > MaxResponseBytes) return Invalid("INVALID_ARTICLE");
            Match version = Regex.Match(title, @"(?<![\d.])(?<version>\d+(?:\.\d+){1,3})\s*版本.*(?:更新|維護|维护)");
            if (Regex.IsMatch(title, "預下載|预下载|前瞻") || !version.Success) return Invalid("NOT_VERSION_MAINTENANCE");
            string plain = Regex.Replace(raw, @"(?is)<(script|style)\b[^>]*>.*?</\1\s*>", "");
            plain = Regex.Replace(plain, @"(?i)<br\s*/?>|</(?:p|div|li|h[1-6])\s*>", "\n");
            plain = WebUtility.HtmlDecode(Regex.Replace(plain, "<[^>]*>", ""));
            if (!Regex.IsMatch(plain, @"(?:維護|维护).{0,40}(?:無法|无法|不能).{0,12}(?:登入|登錄|登录)|停機|停机")) return Invalid("NO_LOGIN_OUTAGE");
            const string datePattern = @"(?<Y>\d{4})\s*(?:年|[-/])\s*(?<M>\d{1,2})\s*(?:月|[-/])\s*(?<D>\d{1,2})\s*日?\s*(?<H>\d{1,2}):(?<N>\d{2})";
            var range = Regex.Match(plain, @"(?s)(?:更新維護時間|更新维护时间|維護時間|维护时间)\s*[:：]?\s*(?<start>" + datePattern + @")\s*(?:~|～|至|—|–|-)\s*(?<end>" + datePattern + @")\s*[（(]?\s*UTC\s*(?<offset>[+\-]\d{1,2}(?::\d{2})?)(?![\d:])\s*[)）]?");
            if (!range.Success) return Invalid("INCOMPLETE_TIME_RANGE");
            DateTimeOffset start, end;
            try {
                var offsetMatch = Regex.Match(range.Groups["offset"].Value, @"^([+\-])(\d{1,2})(?::(\d{2}))?$");
                int hours = int.Parse(offsetMatch.Groups[2].Value, Invariant);
                int minutes = offsetMatch.Groups[3].Success ? int.Parse(offsetMatch.Groups[3].Value, Invariant) : 0;
                if (hours > 14 || minutes > 59 || (hours == 14 && minutes != 0)) return Invalid("INVALID_TIME_RANGE");
                TimeSpan offset = TimeSpan.FromMinutes((hours * 60 + minutes) * (offsetMatch.Groups[1].Value == "-" ? -1 : 1));
                start = ParseLocal(range.Groups["start"].Value, datePattern, offset);
                end = ParseLocal(range.Groups["end"].Value, datePattern, offset);
                if (end <= start || (end - start).TotalHours > 48) return Invalid("INVALID_TIME_RANGE");
            } catch (ArgumentException) { return Invalid("INVALID_TIME_RANGE"); }
              catch (FormatException) { return Invalid("INVALID_TIME_RANGE"); }
              catch (OverflowException) { return Invalid("INVALID_TIME_RANGE"); }
            string bodyHash = Hash(plain), openUtc = Utc(end), gameVersion = version.Groups["version"].Value;
            var notice = D("schemaVersion", 1, "eventId", "wuthering-global-" + gameVersion + "-" + start.ToUnixTimeSeconds().ToString(Invariant), "articleId", articleId,
                "gameVersion", gameVersion, "scope", "global-pc", "startsAtUtc", Utc(start), "expectedOpenAtUtc", openUtc,
                "publishedAt", S(article, "startTime"), "fetchedAtUtc", Utc(fetchedAt), "sourceUrl", sourceUrl,
                "bodySha256", bodyHash, "revisionHash", Hash(id + "|" + bodyHash + "|" + openUtc), "sourceState", "verified");
            return D("valid", true, "reason", "", "notice", notice);
        }

        private static DateTimeOffset ParseLocal(string text, string pattern, TimeSpan offset)
        {
            var parts = Regex.Match(text, pattern);
            string formatted = parts.Groups["Y"].Value + "-" + parts.Groups["M"].Value + "-" + parts.Groups["D"].Value + " " + parts.Groups["H"].Value + ":" + parts.Groups["N"].Value;
            return new DateTimeOffset(DateTime.SpecifyKind(DateTime.ParseExact(formatted, "yyyy-M-d H:mm", Invariant, DateTimeStyles.None), DateTimeKind.Unspecified), offset);
        }

        public static bool IsSavedNotice(Dictionary<string, object> notice)
        {
            try {
                if (S(notice, "schemaVersion") != "1" || S(notice, "scope") != "global-pc" || !IsAllowedUrl(S(notice, "sourceUrl"))) return false;
                var start = Date(notice, "startsAtUtc"); var end = Date(notice, "expectedOpenAtUtc");
                return end > start && (end - start).TotalHours <= 48 && Regex.IsMatch(S(notice, "gameVersion"), @"^\d+(?:\.\d+){1,3}$") &&
                    S(notice, "eventId") == "wuthering-global-" + S(notice, "gameVersion") + "-" + start.ToUnixTimeSeconds().ToString(Invariant) &&
                    Regex.IsMatch(S(notice, "revisionHash"), "^[0-9a-f]{64}$", RegexOptions.IgnoreCase) && Regex.IsMatch(S(notice, "bodySha256"), "^[0-9a-f]{64}$", RegexOptions.IgnoreCase);
            } catch (ArgumentException) { return false; }
              catch (FormatException) { return false; }
              catch (OverflowException) { return false; }
        }

        public static Dictionary<string, object> Select(object[] notices, DateTimeOffset now, Dictionary<string, object> previous)
        {
            var usable = (notices ?? new object[0]).OfType<Dictionary<string, object>>().Where(IsSavedNotice).ToArray();
            if (IsSavedNotice(previous)) {
                var previousStart = Date(previous, "startsAtUtc"); var previousEnd = Date(previous, "expectedOpenAtUtc");
                bool conflict = usable.Any(n => S(n, "eventId") != S(previous, "eventId") &&
                    (Day(Date(n, "startsAtUtc")) == Day(previousStart) || (Date(n, "startsAtUtc") <= previousEnd && Date(n, "expectedOpenAtUtc") >= previousStart) ||
                    (S(n, "gameVersion") == S(previous, "gameVersion") && Date(n, "expectedOpenAtUtc") >= now && Date(n, "startsAtUtc") <= previousStart.AddDays(2))));
                if (conflict) return D("notice", previous, "sourceState", "conflict", "requiresReview", true, "reconfirmed", false);
                var same = usable.Where(n => S(n, "eventId") == S(previous, "eventId")).ToArray();
                var chosen = same.Concat(new [] { previous }).OrderByDescending(n => Date(n, "expectedOpenAtUtc")).First();
                return D("notice", chosen, "sourceState", "known", "requiresReview", false, "reconfirmed", same.Length != 0);
            }
            var today = usable.Where(n => Day(Date(n, "startsAtUtc")) == Day(now)).ToArray();
            if (today.Select(n => S(n, "eventId")).Distinct().Count() > 1) return D("notice", null, "sourceState", "conflict", "requiresReview", true);
            return D("notice", today.OrderByDescending(n => Date(n, "expectedOpenAtUtc")).FirstOrDefault(), "sourceState", "verified", "requiresReview", false);
        }

        public static Dictionary<string, object> SelectUpcoming(object[] notices, DateTimeOffset now)
        {
            return (notices ?? new object[0]).OfType<Dictionary<string, object>>().Where(IsSavedNotice)
                .Where(n => Date(n, "startsAtUtc") <= now.AddDays(14) && string.CompareOrdinal(Day(Date(n, "startsAtUtc")), Day(now)) > 0)
                .OrderBy(n => Date(n, "startsAtUtc")).ThenByDescending(n => Date(n, "expectedOpenAtUtc")).FirstOrDefault();
        }

        private static Dictionary<string, object> ReadCache(string directory)
        {
            foreach (string name in new [] { "notice-cache.json", "notice-cache.json.bak" }) {
                try {
                    string path = Path.Combine(directory, name);
                    if (!File.Exists(path) || new FileInfo(path).Length > MaxCacheBytes) continue;
                    var cache = Serializer().DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
                    if (cache == null || S(cache, "schemaVersion") != "1" || !(Value(cache, "notices") is IList)) continue;
                    var notices = Items(Value(cache, "notices"));
                    if (notices.Length > 3 || notices.Any(n => !IsSavedNotice(n as Dictionary<string, object>))) continue;
                    DateTimeOffset.Parse(S(cache, "checkedAtUtc"), Invariant);
                    // Keep the public cache contract independent of serializer-specific array types.
                    cache["notices"] = notices;
                    return cache;
                } catch (Exception) { /* A damaged primary may recover from the validated backup. */ }
            }
            return null;
        }

        private static void WriteCache(string directory, Dictionary<string, object> cache)
        {
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "notice-cache.json");
            string temporary = Path.Combine(directory, "notice-" + Guid.NewGuid().ToString("N") + ".tmp");
            string text = Serializer().Serialize(cache);
            if (Encoding.UTF8.GetByteCount(text) > MaxCacheBytes) throw new InvalidDataException("GM_INVALID: cache too large");
            try {
                File.WriteAllText(temporary, text, new UTF8Encoding(false));
                var readback = Serializer().DeserializeObject(File.ReadAllText(temporary, Encoding.UTF8)) as Dictionary<string, object>;
                if (readback == null || S(readback, "schemaVersion") != "1" || !(Value(readback, "notices") is IList) ||
                    Items(Value(readback, "notices")).Any(n => !IsSavedNotice(n as Dictionary<string, object>))) throw new InvalidDataException("GM_INVALID: cache readback failed");
                if (File.Exists(path)) File.Replace(temporary, path, path + ".bak");
                else File.Move(temporary, path);
            } finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }

        public static Dictionary<string, object> FindCached(string cacheDirectory, string eventId)
        {
            var cache = ReadCache(cacheDirectory);
            return Items(Value(cache, "notices")).OfType<Dictionary<string, object>>().Where(n => S(n, "eventId") == eventId)
                .OrderByDescending(n => Date(n, "expectedOpenAtUtc")).FirstOrDefault();
        }

        public static Dictionary<string, object> Fetch(string cacheDirectory, DateTimeOffset now, bool force, Dictionary<string, object> previous, Func<string, string> httpGet)
        {
            return Fetch(cacheDirectory, now, force, previous, httpGet, 20000);
        }

        public static Dictionary<string, object> Fetch(string cacheDirectory, DateTimeOffset now, bool force, Dictionary<string, object> previous, Func<string, string> httpGet, int budgetMilliseconds)
        {
            return FetchBounded(cacheDirectory, now, force, previous, httpGet == null ? null : new Func<string,int,string>((url, remaining) => httpGet(url)), budgetMilliseconds);
        }

        public static Dictionary<string, object> FetchBounded(string cacheDirectory, DateTimeOffset now, bool force, Dictionary<string, object> previous, Func<string, int, string> httpGet, int budgetMilliseconds = 20000)
        {
            if (budgetMilliseconds < 1 || budgetMilliseconds > 20000) throw new ArgumentOutOfRangeException("budgetMilliseconds");
            var cache = ReadCache(cacheDirectory); object[] cachedNotices = Items(Value(cache, "notices"));
            var selected = Select(cachedNotices, now, previous);
            var known = Value(selected, "notice") as Dictionary<string, object>;
            var checkedAt = cache == null ? DateTimeOffset.MinValue : DateTimeOffset.Parse(S(cache, "checkedAtUtc"), Invariant);
            double age = (now - checkedAt).TotalSeconds; string day = Day(now);
            if (!force && cache != null && S(cache, "dateKey") == day && age >= 0 && age < (known != null ? 300 : 21600) && !(bool)selected["requiresReview"])
                return Result("ok", known, SelectUpcoming(cachedNotices, now), S(cache, "checkedAtUtc"), "", "", true);
            var watch = Stopwatch.StartNew();
            try {
                var menu = FetchJson(FeedBase + "MainMenu.json", httpGet, watch, budgetMilliseconds) as Dictionary<string, object>;
                if (menu == null || !(Value(menu, "article") is IList)) throw new InvalidDataException("GM_INVALID: menu schema changed");
                var candidates = Items(Value(menu, "article")).OfType<Dictionary<string, object>>()
                    .Where(n => Regex.IsMatch(S(n, "articleId"), @"^\d+$") && Regex.IsMatch(S(n, "articleTitle"), @"\d+(?:\.\d+)+\s*版本.*(?:維護|维护)") && !Regex.IsMatch(S(n, "articleTitle"), "預下載|预下载|前瞻"))
                    .GroupBy(n => S(n, "articleId")).Select(group => group.First()).OrderByDescending(n => S(n, "startTime"), StringComparer.Ordinal).Take(12);
                var notices = new List<Dictionary<string, object>>();
                foreach (var candidate in candidates) {
                    string id = S(candidate, "articleId");
                    var article = FetchJson(FeedBase + "article/" + id + ".json", httpGet, watch, budgetMilliseconds) as Dictionary<string, object>;
                    if (S(article, "articleId") != id) throw new InvalidDataException("GM_INVALID: article identity mismatch");
                    var parsed = Parse(article, "https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/" + id, now);
                    if (!(bool)parsed["valid"]) throw new InvalidDataException("GM_INVALID: announcement " + S(parsed, "reason"));
                    notices.Add((Dictionary<string, object>)parsed["notice"]);
                }
                var fresh = Select(notices.Cast<object>().ToArray(), now, known);
                if ((bool)fresh["requiresReview"]) throw new InvalidDataException("GM_CONFLICT: conflicting maintenance events");
                if (known != null && !object.Equals(Value(fresh, "reconfirmed"), true)) throw new IOException("GM_UNCONFIRMED: known event missing from current official notices");
                var merged = notices.GroupBy(n => S(n, "eventId")).Select(group => group.OrderByDescending(n => Date(n, "expectedOpenAtUtc")).First());
                var kept = merged.Where(n => Date(n, "startsAtUtc") <= now.AddDays(14) && Date(n, "expectedOpenAtUtc") >= now.AddDays(-2))
                    .OrderBy(n => Math.Abs((Date(n, "startsAtUtc") - now).TotalSeconds)).Take(3).ToList();
                var chosen = Value(fresh, "notice") as Dictionary<string, object>;
                if (chosen != null) kept = new [] { chosen }.Concat(kept.Where(n => S(n, "eventId") != S(chosen, "eventId")).Take(2)).ToList();
                object[] summaries = kept.Cast<object>().ToArray();
                WriteCache(cacheDirectory, D("schemaVersion", 1, "checkedAtUtc", Utc(now), "dateKey", day, "notices", summaries));
                return Result("ok", chosen, SelectUpcoming(summaries, now), Utc(now), "", "", false);
            } catch (Exception e) {
                bool conflict = e.Message.StartsWith("GM_CONFLICT:", StringComparison.Ordinal);
                bool unconfirmed = e.Message.StartsWith("GM_UNCONFIRMED:", StringComparison.Ordinal);
                bool invalid = conflict || e.Message.StartsWith("GM_INVALID:", StringComparison.Ordinal);
                string detail = Regex.Replace(e.Message, @"[\r\n\x00-\x1f]", " ");
                return Result(invalid ? "invalid" : "unavailable", known, SelectUpcoming(cachedNotices, now), cache == null ? "" : S(cache, "checkedAtUtc"),
                    conflict ? "NOTICE_CONFLICT" : unconfirmed ? "NOTICE_EVENT_NOT_RECONFIRMED" : invalid ? "NOTICE_INVALID" : "NOTICE_UNAVAILABLE", detail.Substring(0, Math.Min(500, detail.Length)), false);
            }
        }

        private static Dictionary<string, object> Result(string outcome, Dictionary<string, object> notice, Dictionary<string, object> upcoming, string checkedAt, string code, string detail, bool fromCache)
        {
            return D("outcome", outcome, "notice", notice, "upcomingNotice", upcoming, "checkedAt", checkedAt, "errorCode", code, "errorDetail", detail, "fromCache", fromCache);
        }

        private static object FetchJson(string url, Func<string, int, string> httpGet, Stopwatch watch, int budgetMilliseconds)
        {
            if (!IsAllowedUrl(url)) throw new InvalidDataException("GM_INVALID: URL not allowed");
            int remaining = budgetMilliseconds - (int)watch.ElapsedMilliseconds;
            if (remaining <= 0) throw new IOException("Official notice time budget exhausted");
            string json = httpGet == null ? HttpGet(url, Math.Min(10000, remaining)) : httpGet(url, Math.Min(10000, remaining));
            if (watch.ElapsedMilliseconds > budgetMilliseconds) throw new IOException("Official notice time budget exhausted");
            if (json == null || Encoding.UTF8.GetByteCount(json) > MaxResponseBytes) throw new InvalidDataException("GM_INVALID: oversized or invalid response");
            try { return Serializer().DeserializeObject(json); }
            catch (ArgumentException) { throw new InvalidDataException("GM_INVALID: malformed JSON"); }
            catch (InvalidOperationException) { throw new InvalidDataException("GM_INVALID: malformed JSON"); }
        }

        private static string HttpGet(string url, int timeoutMilliseconds)
        {
            if (!IsAllowedUrl(url)) throw new InvalidDataException("GM_INVALID: URL not allowed");
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.AllowAutoRedirect = false;
            request.Timeout = Math.Max(1, Math.Min(10000, timeoutMilliseconds));
            request.ReadWriteTimeout = request.Timeout;
            request.UserAgent = "WutheringMaintenance/1.0";
            var clock = Stopwatch.StartNew();
            try {
                using (var response = (HttpWebResponse)request.GetResponse()) {
                    if (response.StatusCode != HttpStatusCode.OK) throw new InvalidDataException("GM_INVALID: redirects and non-200 responses are not accepted");
                    if (response.ContentLength > MaxResponseBytes) throw new InvalidDataException("GM_INVALID: response too large");
                    using (var stream = response.GetResponseStream())
                    using (var memory = new MemoryStream()) {
                        var bytes = new byte[8192];
                        while (true) {
                            int remaining = timeoutMilliseconds - (int)clock.ElapsedMilliseconds;
                            if (remaining <= 0) throw new IOException("HTTP response time budget exhausted");
                            if (stream.CanTimeout) stream.ReadTimeout = Math.Max(1, remaining);
                            int count = stream.Read(bytes, 0, bytes.Length);
                            if (count == 0) break;
                            if (memory.Length + count > MaxResponseBytes) throw new InvalidDataException("GM_INVALID: response too large");
                            memory.Write(bytes, 0, count);
                        }
                        return new UTF8Encoding(false, true).GetString(memory.ToArray());
                    }
                }
            } finally { request.Abort(); }
        }
    }
}
