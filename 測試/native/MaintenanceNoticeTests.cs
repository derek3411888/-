using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using Wuthering.Native;

public static class MaintenanceNoticeTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-08-20T02:00:00Z", CultureInfo.InvariantCulture);
    private const string Source = "https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/1";
    private static string runRoot;
    private static int failures;
    private static int passed;
    private static Dictionary<string, object> D(params object[] pairs)
    {
        var value = new Dictionary<string, object>();
        for (int i = 0; i < pairs.Length; i += 2) value.Add((string)pairs[i], pairs[i + 1]);
        return value;
    }
    private static Dictionary<string, object> Article(string time = "2026年8月20日04:00 ~ 2026年8月20日11:00（UTC+8）", int id = 1, string version = "9.9")
    {
        return D("articleId", id, "articleTitle", "《鳴潮》" + version + "版本更新維護預告（測試資料）", "gameId", "G152-tw",
            "startTime", "2026-08-13 11:00:01", "articleContent", "<p>維護期間無法登入遊戲。</p><p>更新維護時間：<strong>" + time + "</strong></p>");
    }
    private static Dictionary<string, object> Notice(string time = "2026年8月20日04:00 ~ 2026年8月20日11:00（UTC+8）", int id = 1, string version = "9.9")
    {
        return (Dictionary<string, object>)MaintenanceNotice.Parse(Article(time, id, version), Source, Now)["notice"];
    }
    private static string Json(object value) { return new JavaScriptSerializer().Serialize(value); }
    private static Dictionary<string, object> Child(Dictionary<string, object> value, string name = "notice") { return (Dictionary<string, object>)value[name]; }
    private static void Equal(object actual, object expected, string message)
    {
        if (!object.Equals(actual, expected)) throw new Exception(message + ": expected " + (expected ?? "null") + ", got " + (actual ?? "null"));
    }
    private static void True(bool value, string message) { Equal(value, true, message); }
    private static string Cache(string name) { return Path.Combine(runRoot, name); }
    private static Func<string, string> Feed(params Dictionary<string, object>[] articles)
    {
        return delegate(string uri) {
            if (uri.EndsWith("MainMenu.json", StringComparison.Ordinal)) return Json(D("article", articles));
            string id = Regex.Match(uri, @"/(\d+)\.json$").Groups[1].Value;
            return Json(articles.First(a => Convert.ToString(a["articleId"], CultureInfo.InvariantCulture) == id));
        };
    }
    private static void Test(string name, Action action)
    {
        try { action(); passed++; Console.WriteLine("PASS " + name); }
        catch (Exception e) { failures++; Console.WriteLine("FAIL " + name + ": " + e.Message); }
    }
    public static int Main(string[] args)
    {
        // Every write stays beneath this executable's diagnostic directory.
        runRoot = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "notice-fixtures-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(runRoot);
        Test("full UTC range and stable version event identity", delegate {
            var result = MaintenanceNotice.Parse(Article(), Source, Now);
            Equal(result["valid"], true, "full range accepted");
            var n = Child(result);
            Equal(n["startsAtUtc"], "2026-08-19T20:00:00Z", "body start not publication");
            Equal(n["expectedOpenAtUtc"], "2026-08-20T03:00:00Z", "UTC deadline");
            Equal(n["fetchedAtUtc"], "2026-08-20T02:00:00Z", "fetch timestamp is string");
            Equal(n["eventId"], "wuthering-global-9.9-1787169600", "stable event identity");
            Equal(n["articleId"], 1L, "numeric article id");
            True(Regex.IsMatch((string)n["bodySha256"], "^[0-9a-f]{64}$"), "body digest");
            True(MaintenanceNotice.IsSavedNotice(n), "saved record accepted");
        });
        Test("incomplete invalid and impossible time ranges rejected", delegate {
            foreach (string time in new [] {"2026年8月20日04:00 ~ 2026年8月20日11:00", "8月20日04:00 ~ 8月20日11:00（UTC+8）", "2026年8月20日11:00 ~ 2026年8月20日04:00（UTC+8）", "2026年8月20日04:00 ~ 2026年8月23日11:00（UTC+8）", "2026年2月30日04:00 ~ 2026年2月30日11:00（UTC+8）", "2026年8月20日04:00 ~ 2026年8月20日11:00（UTC+14:01）", "2026年8月20日04:00 ~ 2026年8月20日11:00（UTC+8:60）"})
                Equal(MaintenanceNotice.Parse(Article(time), Source, Now)["valid"], false, time);
        });
        Test("negative fractional offsets and HTML decoding", delegate {
            Equal(Notice("2026年8月19日23:00 ~ 2026年8月20日06:00（UTC-4）")["startsAtUtc"], "2026-08-20T03:00:00Z", "negative offset");
            Equal(Notice("2026-8-20 04:00 ~ 2026-8-20 11:00 (UTC+5:30)")["startsAtUtc"], "2026-08-19T22:30:00Z", "fractional offset");
            var a = Article(); a["articleContent"] = "<style>bad</style><script>bad</script>" + ((string)a["articleContent"]).Replace("：", "&#65306;");
            Equal(MaintenanceNotice.Parse(a, Source, Now)["valid"], true, "HTML decoded and executable content ignored");
        });
        Test("overlong versions and partially consumed numeric offsets fail closed", delegate {
            Equal(MaintenanceNotice.Parse(Article(version:"9.9.9.9.9"), Source, Now)["valid"], false, "five-part version cannot become suffix version");
            foreach (string offset in new [] { "UTC+8:1", "UTC+8:001", "UTC+008" })
                Equal(MaintenanceNotice.Parse(Article("2026年8月20日04:00 ~ 2026年8月20日11:00（" + offset + "）"), Source, Now)["valid"], false, "offset must not be truncated: " + offset);
        });
        Test("scope title outage and article identity validation", delegate {
            foreach (string title in new [] {"《鳴潮》9.9版本預下載公告", "《鳴潮》9.9版本前瞻", "《鳴潮》商城維護公告", "國服9.9版本更新維護"}) {
                var a = Article(); a["articleTitle"] = title; Equal(MaintenanceNotice.Parse(a, Source, Now)["valid"], false, title);
            }
            var wrong = Article(); wrong["gameId"] = "G152-cn"; Equal(MaintenanceNotice.Parse(wrong, Source, Now)["reason"], "WRONG_SCOPE", "regional feed");
            wrong = Article(); wrong["articleContent"] = "維護時間：2026年8月20日04:00 ~ 2026年8月20日11:00（UTC+8）";
            Equal(MaintenanceNotice.Parse(wrong, Source, Now)["reason"], "NO_LOGIN_OUTAGE", "login outage required");
            wrong = Article(); wrong["articleId"] = "not-a-number"; Equal(MaintenanceNotice.Parse(wrong, Source, Now)["reason"], "INVALID_ARTICLE", "numeric id required");
        });
        Test("official URL allowlist blocks external and decorated URLs", delegate {
            True(MaintenanceNotice.IsAllowedUrl(Source), "official detail accepted");
            True(MaintenanceNotice.IsAllowedUrl("https://hw-media-cdn-mingchao.kurogame.com/akiwebsite/website2.0/json/G152/zh-tw/MainMenu.json"), "official menu accepted");
            foreach (string url in new [] {"http://wutheringwaves.kurogames.com/zh-tw/main/news/detail/1", "https://user@wutheringwaves.kurogames.com/zh-tw/main/news/detail/1", "https://wutheringwaves.kurogames.com.evil.test/zh-tw/main/news/detail/1", Source + "?next=evil", Source + "#evil", "https://wutheringwaves.kurogames.com:444/zh-tw/main/news/detail/1", "https://hw-media-cdn-mingchao.kurogame.com/akiwebsite/website2.0/json/G152/en/MainMenu.json", "https://example.org/news/1"})
                Equal(MaintenanceNotice.Parse(Article(), url, Now)["reason"], "UNTRUSTED_SOURCE", url);
        });
        Test("saved notice corruption rejected", delegate {
            foreach (string key in new [] {"schemaVersion", "scope", "sourceUrl", "startsAtUtc", "expectedOpenAtUtc", "eventId", "gameVersion", "revisionHash", "bodySha256"}) {
                var n = Notice(); n[key] = "corrupt"; Equal(MaintenanceNotice.IsSavedNotice(n), false, key);
            }
        });
        Test("extensions never shorten and remain pinned across midnight", delegate {
            var original = Notice(); var late = Notice("2026年8月20日04:00 ~ 2026年8月20日13:00（UTC+8）");
            Equal(original["eventId"], late["eventId"], "extension identity");
            var selected = MaintenanceNotice.Select(new object[] { original, late, original }, Now, original);
            Equal(Child(selected)["expectedOpenAtUtc"], "2026-08-20T05:00:00Z", "maximum deadline");
            Equal(selected["reconfirmed"], true, "known event reconfirmed");
            Equal(Child(MaintenanceNotice.Select(new object[0], Now.AddDays(1), original))["eventId"], original["eventId"], "day boundary retains active event");
            Equal(MaintenanceNotice.Select(new object[] { original }, Now.AddDays(-1), null)["notice"], null, "tomorrow does not block");
            Equal(MaintenanceNotice.Select(new object[] { original }, Now.AddDays(1), null)["notice"], null, "history does not cold-start block");
        });
        Test("cleared old-version pin allows next update day selection", delegate {
            var directory = Cache("next-version");
            MaintenanceNotice.Fetch(directory, Now, true, null, Feed(Article()));
            var nextArticle = Article("2026年9月17日04:00 ~ 2026年9月17日11:00（UTC+8）", 2, "9.10");
            var later = Now.AddDays(28);
            var result = MaintenanceNotice.Fetch(directory, later, true, null, Feed(Article(), nextArticle));
            Equal(result["outcome"], "ok", "new day refetch accepted");
            Equal(Child(result)["gameVersion"], "9.10", "un-pinned production selector chooses new version rather than cached old event");
        });
        Test("deduplicated detail requests cache TTL force and FindCached", delegate {
            int requests = 0; var feed = Feed(Article(), Article());
            Func<string,string> getter = uri => { requests++; return feed(uri); };
            string cache = Cache("active");
            var initial = MaintenanceNotice.Fetch(cache, Now, false, null, getter);
            Equal(initial["outcome"], "ok", "fetch success"); Equal(requests, 2, "deduplicate before fetching");
            Equal(MaintenanceNotice.Fetch(cache, Now.AddMinutes(1), false, null, getter)["fromCache"], true, "five minute cache");
            Equal(requests, 2, "cache avoids requests");
            Equal(MaintenanceNotice.FindCached(cache, (string)Child(initial)["eventId"])["expectedOpenAtUtc"], "2026-08-20T03:00:00Z", "find event in validated cache");
            Equal(MaintenanceNotice.FindCached(cache, "missing-event"), null, "missing event null");
            MaintenanceNotice.Fetch(cache, Now.AddMinutes(2), true, null, getter); Equal(requests, 4, "force refresh");
            MaintenanceNotice.Fetch(cache, Now.AddMinutes(7), false, null, getter); Equal(requests, 6, "five minute boundary expires");
        });
        Test("network malformed oversized and changed-schema failures preserve prior evidence", delegate {
            string cache = Cache("failure"); var initial = MaintenanceNotice.Fetch(cache, Now, true, null, Feed(Article()));
            var offline = MaintenanceNotice.Fetch(cache, Now.AddHours(1), true, null, uri => { throw new IOException("HTTP 500\nremote\0failure"); });
            Equal(offline["outcome"], "unavailable", "network remains unavailable"); Equal(Child(offline)["eventId"], Child(initial)["eventId"], "known event retained");
            Equal(offline["checkedAt"], "2026-08-20T02:00:00Z", "no false fresh check timestamp");
            True(!((string)offline["errorDetail"]).Contains("\n") && !((string)offline["errorDetail"]).Contains("\0"), "error control characters stripped");
            foreach (string payload in new [] {"{broken", new string('x', 2097153), "{\"items\":[]}", "{\"article\":{}}"}) {
                var bad = MaintenanceNotice.Fetch(cache, Now.AddHours(1), true, null, uri => payload);
                Equal(bad["outcome"], "invalid", "bad payload rejected"); True(Child(bad) != null, "prior evidence retained");
            }
            var unknown = MaintenanceNotice.Fetch(Cache("unknown"), Now, false, null, uri => { throw new IOException("offline"); });
            Equal(unknown["outcome"], "unavailable", "unknown not false success"); Equal(unknown["notice"], null, "unknown remains null");
        });
        Test("negative cache six-hour TTL and Taipei midnight invalidation", delegate {
            int calls = 0; Func<string,string> empty = uri => { calls++; return "{\"article\":[]}"; }; string cache = Cache("negative");
            var initial = MaintenanceNotice.Fetch(cache, Now, false, null, empty);
            True(Json(initial).Contains("\"notice\":null"), "null serialization");
            MaintenanceNotice.Fetch(cache, Now.AddHours(5), false, null, empty); Equal(calls, 1, "six-hour TTL");
            MaintenanceNotice.Fetch(cache, Now.AddHours(6), false, null, empty); Equal(calls, 2, "six-hour boundary expired");
            MaintenanceNotice.Fetch(cache, DateTimeOffset.Parse("2026-08-20T15:59:00Z"), true, null, empty);
            MaintenanceNotice.Fetch(cache, DateTimeOffset.Parse("2026-08-20T16:01:00Z"), false, null, empty); Equal(calls, 4, "Taipei midnight invalidates cache");
        });
        Test("atomic backup restores corrupted primary", delegate {
            string cache = Cache("backup"); MaintenanceNotice.Fetch(cache, Now, true, null, Feed(Article()));
            MaintenanceNotice.Fetch(cache, Now.AddMinutes(1), true, null, Feed(Article()));
            File.WriteAllText(Path.Combine(cache, "notice-cache.json"), "{truncated", new UTF8Encoding(false));
            var recovered = MaintenanceNotice.Fetch(cache, Now.AddHours(1), true, null, uri => { throw new IOException("offline"); });
            Equal(Child(recovered)["expectedOpenAtUtc"], "2026-08-20T03:00:00Z", "valid backup retained");
            Equal(Directory.GetFiles(cache, "*.tmp").Length, 0, "no stranded temporary files");
        });
        Test("persisted extension survives stale shorter feed", delegate {
            string cache = Cache("extension"); MaintenanceNotice.Fetch(cache, Now, true, null, Feed(Article("2026年8月20日04:00 ~ 2026年8月20日13:00（UTC+8）")));
            MaintenanceNotice.Fetch(cache, Now, true, null, Feed(Article()));
            var result = MaintenanceNotice.Fetch(cache, Now.AddMinutes(1), false, null, uri => { throw new Exception("must use cache"); });
            Equal(Child(result)["expectedOpenAtUtc"], "2026-08-20T05:00:00Z", "stale response cannot shorten persisted extension");
        });
        Test("newest twelve unique candidate requests only", delegate {
            var items = Enumerable.Range(1, 20).Select(i => { var a = Article(id:i); a["startTime"] = "2026-08-" + i.ToString("00") + " 00:00:00"; return a; }).ToArray();
            var feed = Feed(items); var ids = new List<int>();
            var result = MaintenanceNotice.Fetch(Cache("cap"), Now, true, null, uri => { if (!uri.EndsWith("MainMenu.json")) ids.Add(int.Parse(Regex.Match(uri, @"/(\d+)\.json$").Groups[1].Value)); return feed(uri); });
            Equal(result["outcome"], "ok", "request cap success"); Equal(ids.Count, 12, "twelve detail cap"); Equal(ids[0], 20, "newest first"); Equal(ids[11], 9, "old items cannot displace new");
        });
        Test("future notices preview then activate on Taipei date and cache retains only three", delegate {
            var items = Enumerable.Range(1, 5).Select(i => Article("2026年8月" + (20+i) + "日04:00 ~ 2026年8月" + (20+i) + "日11:00（UTC+8）", i, "9." + i)).ToArray();
            string cache = Cache("future"); var first = MaintenanceNotice.Fetch(cache, Now, true, null, Feed(items));
            Equal(first["notice"], null, "future does not block today"); Equal(Child(first, "upcomingNotice")["gameVersion"], "9.1", "nearest future shown");
            Equal(MaintenanceNotice.Fetch(cache, Now.AddMinutes(1), false, null, uri => { throw new IOException("cached"); })["fromCache"], true, "future six-hour cache");
            var offline = MaintenanceNotice.Fetch(cache, Now.AddMinutes(2), true, null, uri => { throw new IOException("offline"); });
            Equal(offline["outcome"], "unavailable", "future cannot disguise error"); Equal(Child(offline, "upcomingNotice")["gameVersion"], "9.1", "future retained offline");
            var active = MaintenanceNotice.Fetch(cache, DateTimeOffset.Parse("2026-08-20T20:00:00Z"), false, null, uri => { throw new IOException("offline"); });
            Equal(Child(active)["gameVersion"], "9.1", "activates on maintenance day"); Equal(Child(active, "upcomingNotice")["gameVersion"], "9.2", "preview not duplicate active");
            var saved = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(cache, "notice-cache.json")));
            Equal(((System.Collections.IList)saved["notices"]).Count, 3, "only three cache summaries");
        });
        Test("conflicts and removed pinned event do not falsely reconfirm", delegate {
            var conflict = MaintenanceNotice.Fetch(Cache("conflict"), Now, true, null, Feed(Article(id:1, version:"9.1"), Article(id:2, version:"9.2")));
            Equal(conflict["errorCode"], "NOTICE_CONFLICT", "two today events conflict");
            var original = Notice(); var replaced = MaintenanceNotice.Fetch(Cache("replacement"), Now.AddHours(2), true, original, Feed(Article("2026年8月20日05:00 ~ 2026年8月20日13:00（UTC+8）")));
            Equal(replaced["errorCode"], "NOTICE_CONFLICT", "changed start conflicts pinned event"); Equal(replaced["checkedAt"], "", "no false confirmation timestamp");
            var removed = MaintenanceNotice.Fetch(Cache("removed"), Now, true, original, uri => "{\"article\":[]}");
            Equal(removed["errorCode"], "NOTICE_EVENT_NOT_RECONFIRMED", "missing known event fails reconfirmation"); Equal(Child(removed)["eventId"], original["eventId"], "retains old event");
        });
        Test("detail identity mismatch and invalid notice fail closed", delegate {
            var mismatch = MaintenanceNotice.Fetch(Cache("identity"), Now, true, null, uri => uri.EndsWith("MainMenu.json") ? Json(D("article", new object[] { Article() })) : Json(Article(id:2)));
            Equal(mismatch["errorCode"], "NOTICE_INVALID", "identity mismatch");
            var bad = Article("no time"); var invalid = MaintenanceNotice.Fetch(Cache("badnotice"), Now, true, null, Feed(bad));
            Equal(invalid["errorCode"], "NOTICE_INVALID", "invalid range in fetched detail");
        });
        Test("total fetch budget fails unavailable without saving late response", delegate {
            var late = MaintenanceNotice.Fetch(Cache("budget"), Now, false, null, uri => { System.Threading.Thread.Sleep(20); return "{\"article\":[]}"; }, 1);
            Equal(late["outcome"], "unavailable", "time budget exhausted");
            Equal(File.Exists(Path.Combine(Cache("budget"), "notice-cache.json")), false, "late response not persisted");
        });
        Test("remaining total HTTP budget reaches transport", delegate {
            int firstBudget=0,secondBudget=0,calls=0;var feed=Feed(Article());
            var result=MaintenanceNotice.FetchBounded(Cache("remaining-budget"),Now,true,null,(uri,budget)=>{
                if(++calls==1) {firstBudget=budget;System.Threading.Thread.Sleep(30);} else secondBudget=budget;
                return feed(uri);
            },1000);
            Equal(result["outcome"],"ok","budgeted fetch succeeds");
            True(calls==2 && firstBudget<=1000 && secondBudget>0 && secondBudget<firstBudget,"detail inherits remainder not reset budget");
        });
        Console.WriteLine("RESULT " + passed + " passed, " + failures + " failed; diagnostic fixtures: " + runRoot);
        return failures == 0 ? 0 : 1;
    }
}
