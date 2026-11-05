#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn VarUnset, Off
#Include __ROOT__\測試\GameMaintenanceFixtures.ahk
#Warn VarUnset, Off
__MODULES__
global testRequests := [], testTimers := Map(), testCallbacks := [], testHeartbeatCount := 0
global testNestedHeartbeat := false, testFailAck := false, testResponse := ""
global testNestedHttp := false, testHttpNestedResult := "", testTimeout := false, testAborts := 0
global testSettingsCalls := 0, testFailSettingsAck := false
global __RESTART_IN_PROGRESS := false, __NEXTSERVER_RESTART := false, __RESTART_RECOVERY_WAITING := false
GMTest_Run(TestSelfHostOnly)

TestSelfHostOnly() {
    global RC_CFG_PATH, RC_COMMAND_PROCESSING_READY, RCSH_MODE, RCSH_SERVER_URL
    global RCSH_FIRESTORE_FALLBACK_UNTIL, RCSH_HTTP_RETRY_AFTER, testResponse, testFailAck
    global testNestedHeartbeat, testHeartbeatCount, testNestedHttp, testTimeout, testAborts, testFailSettingsAck
    dir := TestRuntime_NewCaseDir("selfhost-only", "transport")
    cfg := dir "\config.ini"
    IniWrite("selfhost_only", cfg, "self_hosted", "transport")
    IniWrite("https://control.example.test", cfg, "self_hosted", "server_url")
    IniWrite("shadow", cfg, "self_hosted", "mode")
    IniWrite("fixture_only_" A_TickCount, cfg, "remote_control", "uid")
    IniWrite("fixture", cfg, "remote_control", "display_name")
    IniWrite(41, cfg, "remote_control", "last_nonce")
    IniWrite("20261106060000", cfg, "server_completed", "Asia")
    RC_CFG_PATH := cfg
    GMTest_Assert(RC_SavePersistedDesiredState("PAUSE",41,"fixture"), "fixture persisted intent")
    testResponse := TestControl("PAUSE",41)
    GMTest_Assert(RC_Init(cfg,"TestStateCallback","TestSettingsCallback"), "selfhost-only starts without Firebase settings")
    GMTest_Assert(TestFirebaseRequests() = 0, "selfhost-only init must issue ZERO Firebase requests, even with old shadow mode")
    GMTest_Assert(IniRead(cfg,"remote_control","project_id","absent") = "absent", "selfhost-only must not recreate Firebase configuration")
    GMTest_Assert(RC_LAST_NONCE = 41 && RC_REMOTE_DESIRED_STATE = "PAUSE", "startup retains nonce and durable PAUSE")
    GMTest_Assert(testTimers["RC_HeartbeatTick"] = 10000 && testTimers["RC_PollCommandTick"] = 2000, "selfhost-only starts 10 second heartbeat and 2 second command timer")
    GMTest_Assert(IniRead(cfg,"server_completed","Asia") = "20261106060000", "transport init retains completed tasks")
    GMTest_Assert(TestCountPath("/api/v1/device/enroll") = 1, "fresh device enrolls once on selfhost")
    beforeEnroll := TestCountPath("/api/v1/device/enroll")
    RC_Init(cfg,"TestStateCallback","TestSettingsCallback")
    GMTest_Assert(TestCountPath("/api/v1/device/enroll") = beforeEnroll, "same DPAPI credential reused without duplicate enrollment")
    RC_COMMAND_PROCESSING_READY := true
    testResponse := TestControl("RUN",42)
    testFailAck := true
    RC_PollCommandTick()
    GMTest_Assert(testCallbacks.Length = 1 && RC_LAST_NONCE = 42, "RUN applies once before uncertain ACK")
    GMTest_Assert(IsObject(RC_PENDING_COMMAND_ACK), "lost ACK response remains durable for retry")
    testFailAck := false
    RCSH_HTTP_RETRY_AFTER := 0
    RCSH_SERVER_URL := "https://direct.example.test"
    RC_PollCommandTick()
    GMTest_Assert(testCallbacks.Length = 1 && !IsObject(RC_PENDING_COMMAND_ACK), "route change retries ACK, not RUN callback")
    testResponse := TestControl("PAUSE",43)
    RC_PollCommandTick()
    RC_PollCommandTick()
    GMTest_Assert(testCallbacks.Length = 2 && RC_REMOTE_PAUSED, "duplicate PAUSE not applied twice")
    testResponse := TestControl("STOP",44)
    RC_PollCommandTick()
    GMTest_Assert(testCallbacks.Length = 3 && testCallbacks[3] = "STOP", "STOP reaches existing host handler")
    GMTest_Assert(TestCountPath("/api/v1/device/commands/ack") >= 3, "command ACKs use selfhost transport")
    RC_PatchSettingsAck(4,"APPLIED","fixture",true)
    GMTest_Assert(TestCountPath("/api/v1/device/settings/ack") = 1, "settings ACK uses selfhost")
    settingsResp := '{"fields":{"desiredSettingsRevision":{"integerValue":"5"},"desiredSettingsSchemaVersion":{"integerValue":"1"},"desiredServerScheduleEnabled":{"booleanValue":true},"desiredServerScheduleList":{"stringValue":"Asia"}}}'
    testFailSettingsAck := true
    RC_ProcessRemoteSettings(settingsResp)
    GMTest_Assert(testSettingsCalls = 1 && RC_LAST_SETTINGS_APPLIED_REVISION = 5, "settings apply and persist before lost ACK")
    testFailSettingsAck := false, RCSH_HTTP_RETRY_AFTER := 0
    RC_Init(cfg,"TestStateCallback","TestSettingsCallback")
    GMTest_Assert(RC_LAST_SETTINGS_SEEN_REVISION = 5, "settings revision survives transport reinitialization")
    before := TestCountPath("/api/v1/device/settings/ack")
    RC_ProcessRemoteSettings(settingsResp)
    GMTest_Assert(testSettingsCalls = 1 && TestCountPath("/api/v1/device/settings/ack") = before+1, "lost settings ACK retried without reapplying settings")
    RC_ProcessRemoteSettings(settingsResp)
    GMTest_Assert(TestCountPath("/api/v1/device/settings/ack") = before+1, "confirmed settings ACK not resent on every fast poll")
    RCSH_MODE := "fallback"
    RCSH_FIRESTORE_FALLBACK_UNTIL := RC_UnixMs()+86400000
    GMTest_Assert(!RCSH_ShouldReadFirestore(true) && !RCSH_ShouldWriteFirestore(), "discovery fallback cannot reenable retired cloud")
    RCSH_SERVER_URL := ""
    GMTest_Assert(RCSH_SelectControlResponse(TestControl("RUN",99)) = "", "invalid endpoint cannot consume a stale Firebase command")
    denied := RC_HttpRequest("GET","https://firestore.googleapis.com/fixture")
    GMTest_Assert(!denied.ok && TestFirebaseRequests() = 0, "raw Firebase boundary fails closed even when selfhost is unavailable")
    RCSH_SERVER_URL := "https://control.example.test"
    testHeartbeatCount := 0, testNestedHeartbeat := true
    RC_HeartbeatTick()
    GMTest_Assert(testHeartbeatCount = 1, "heartbeat cannot reenter while its HTTP request yields")
    testNestedHeartbeat := false
    RC_HeartbeatTick()
    GMTest_Assert(testHeartbeatCount = 2, "heartbeat ownership released after completion")
    before := testRequests.Length
    testNestedHttp := true
    GMTest_Assert(RCSH_HttpRequest("GET","/fixture").ok, "outer HTTP request succeeds")
    testNestedHttp := false
    GMTest_Assert(!testHttpNestedResult.ok && testRequests.Length = before+1, "nested HTTP does not overlap the owning request")
    testTimeout := true, testAborts := 0
    timed := RCSH_HttpRequest("GET","/fixture")
    GMTest_Assert(!timed.ok && testAborts = 1 && RCSH_HTTP_RETRY_AFTER > RC_UnixMs(), "overall timeout aborts request and enters backoff")
    before := testRequests.Length
    RCSH_HttpRequest("GET","/fixture")
    GMTest_Assert(testRequests.Length = before, "backoff issues no network request")
    testTimeout := false, RCSH_HTTP_RETRY_AFTER := 0
    GMTest_Assert(RCSH_HttpRequest("GET","/fixture").ok, "HTTP ownership released after timeout")
    testResponse := StrReplace(TestControl("RUN",99),'"primary"','"shadow"')
    GMTest_Assert(RCSH_SelectControlResponse() = "", "shadow server cannot execute a stale copied command before cutover")
    RC_ConfigureCadence(cfg)
    IniWrite("migration",cfg,"self_hosted","transport")
    IniWrite(2000,cfg,"remote_control","heartbeat_interval_ms")
    IniWrite(2000,cfg,"remote_control","poll_interval_ms")
    RC_ConfigureCadence(cfg)
    GMTest_Assert(RC_HEARTBEAT_INTERVAL_MS = 60000 && RC_POLL_INTERVAL_MS = 10000, "legacy cloud cadence still enforces free-tier floors")
    secondCfg := dir "\second.ini"
    IniWrite("selfhost_only", secondCfg, "self_hosted", "transport")
    IniWrite("https://control.example.test", secondCfg, "self_hosted", "server_url")
    IniWrite("second_fixture_uid", secondCfg, "remote_control", "uid")
    IniWrite(7, secondCfg, "remote_control", "last_nonce")
    IniWrite("second fixture", secondCfg, "remote_control", "display_name")
    testResponse := TestControl("PAUSE",7)
    beforeEnroll := TestCountPath("/api/v1/device/enroll")
    RC_Init(secondCfg,"TestStateCallback","TestSettingsCallback")
    GMTest_Assert(RC_UID = "second_fixture_uid" && RC_LAST_NONCE = 7, "second device retains its own identity and command cursor")
    GMTest_Assert(TestCountPath("/api/v1/device/enroll") = beforeEnroll+1, "second config cannot inherit first device credential")
    GMTest_Assert(RC_LAST_SETTINGS_SEEN_REVISION = 0 && IniRead(secondCfg,"self_hosted","settings_ack_delivered_revision","absent") = "absent", "second device cannot inherit first device settings ACK")
    GMTest_Assert(IniRead(cfg,"remote_control","last_nonce") = 44 && IniRead(cfg,"server_completed","Asia") = "20261106060000", "switching config leaves first device progress intact")
    GMTest_Assert(TestFirebaseRequests() = 0, "both independent devices stay off Firebase")
    FileAppend("selfhost-only: init, credential, timers, durable state, ACK retry, no cloud, reentry PASS`n","*")
}
TestControl(state,nonce) {
    return '{"fields":{"desiredState":{"stringValue":"' state '"},"nonce":{"integerValue":"' nonce '"},"selfHostedMode":{"stringValue":"primary"},"selfHostedServerUrl":{"stringValue":"https://control.example.test"}}}'
}
TestStateCallback(state,args*) {
    testCallbacks.Push(state)
    if (state = "STOP") {
        RC_MarkActiveStopSideEffectsComplete("fixture")
        RC_FinalizeActiveStopAck("fixture",true)
    }
    return {code:"ACCEPTED"}
}
TestHeartbeat(state) {
    global testHeartbeatCount
    testHeartbeatCount += 1
    if testNestedHeartbeat && testHeartbeatCount = 1
        RC_HeartbeatTick()
    return RCSH_HttpRequest("PUT","/api/v1/device/heartbeat",'{"state":"' state '"}').ok
}
TestFirebaseRequests() {
    count := 0
    for r in testRequests
        if InStr(r.url,"firestore.googleapis.com")
            count += 1
    return count
}
TestCountPath(path) {
    count := 0
    for r in testRequests
        if InStr(r.url,path)
            count += 1
    return count
}
SetTimer(callback,period,priority:=0) {
    testTimers[callback.Name] := period
}
GM_MaintenanceFirestoreMask(args*) => ""
GM_ReadMaintenanceDesired(args*) => {}
TestSettingsCallback(settings) {
    global testSettingsCalls
    testSettingsCalls += 1
    GMTest_Assert(settings.serverScheduleEnabled && settings.serverScheduleList = "Asia", "settings payload decoded without Firebase")
    return {code:"APPLIED",applied:true,detail:"fixture only"}
}
class TestHttp {
    Status := 200
    ResponseText := "{}"
    SetTimeouts(args*) {
    }
    SetRequestHeader(args*) {
    }
    Open(method,url,async) {
        this.method := method, this.url := url, this.async := async
    }
    Send(body:="") {
        global testHttpNestedResult
        testRequests.Push({method:this.method,url:this.url,body:body})
        if testNestedHttp && !InStr(this.url,"/nested")
            testHttpNestedResult := RCSH_HttpRequest("GET","/nested")
        if InStr(this.url,"/api/v1/device/control")
            this.ResponseText := testResponse
        if InStr(this.url,"/commands/ack") && testFailAck
            throw Error("fixture: ACK accepted but response lost")
        if InStr(this.url,"/settings/ack") && testFailSettingsAck
            throw Error("fixture: settings ACK response lost")
    }
    WaitForResponse(seconds) {
        GMTest_Assert(this.async && seconds > 0 && seconds <= 5, "network operation has a finite whole-response deadline")
        return !testTimeout
    }
    Abort() {
        global testAborts
        testAborts += 1
    }
}
