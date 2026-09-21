#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameMaintenance.ahk

GMTest_Run(TestTransport)
TestTransport() {
    root := TestRuntime_DevelopmentRoot() "\temp\gm-transport-" DllCall("GetCurrentProcessId")
    DirCreate(root)
    state := GM_DefaultState(), state.phase := "WAIT_OPEN", state.eventId := "event-1", state.revision := "r1"
    state.expectedOpenAt := 20000, state.provider := "steam"
    state.sourceUrl := "https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5280"
    input := GMTest_Input(10000), input.observation := {phase:"downloading",progressPercent:""}
    decision := GM_Decision(state,"UPDATING","none","","正在更新 C:\private\game.exe")
    json := GM_BuildPublicJson(state,decision,input,10000)
    GMTest_Assert(InStr(json,'"progressPercent":null') && !InStr(json,"private"),"公開狀態不假報 0 或洩漏路徑")
    GMTest_Assert(InStr(json,state.sourceUrl),"保留公告來源實際產生的 zh-tw 連結")
    GMTest_Assert(StrPut(json,"UTF-8") <= 4097,"公開 JSON 不超過 4 KiB")
    fresh := GM_BuildPublicJson(state,decision,input,200000)
    GMTest_Assert(InStr(fresh,'"observedAt":200000'),"一般流程仍隨心跳回報目前控制器能力，不因停止只讀 helper 而永遠過期")
    GMTest_Assert(InStr(GM_InstallSummary(Map("provider","steam","evidence","installation-files-verified")),"Steam"),"UI 顯示實際自動來源")
    GMTest_Assert(InStr(GM_InstallSummary(Map("provider","unknown","evidence","missing-entry")),"尚未確認"),"UI 不把未知當官方版")
    cfg := root "\config.ini"
    IniWrite(0,cfg,"game_maintenance","enabled")
    prior := GM_ReadMaintenanceSettings(cfg)
    unchanged := GM_ValidateMaintenanceSettings({},prior,state,10000)
    GMTest_Assert(unchanged.maintenanceEnabled = 0,"舊表單保留關閉設定")
    updated := GM_ValidateMaintenanceSettings({maintenanceEnabled:1,maintenanceOverrideEventId:"event-1",maintenanceDelayUntilUtc:50000},prior,state,10000)
    GM_WriteMaintenanceSettings(cfg,updated)
    GMTest_Assert(GM_ReadMaintenanceSettings(cfg).maintenanceDelayUntilUtc = 50000,"設定原子暫存寫入可讀回")
    for value in [{maintenanceSkipEventId:"old"},{maintenanceOverrideEventId:"event-1",maintenanceDelayUntilUtc:9999},
        {maintenanceDelayUntilUtc:172810001,maintenanceOverrideEventId:"event-1"},{maintenanceEnabled:"bad"}] {
        failed := false
        try GM_ValidateMaintenanceSettings(value,prior,state,10000)
        catch
            failed := true
        GMTest_Assert(failed,"拒絕過期事件、過早、超長延後或非法值")
    }
    fields := GM_MaintenanceFirestoreFields(updated,"effective")
    decoded := GM_ReadMaintenanceDesired(StrReplace(fields,"effective","desired"))
    GMTest_Assert(decoded.maintenanceDelayUntilUtc = 50000 && decoded.maintenanceEnabled = 1,"Firestore 往返")
    GMTest_Assert(!GM_ReadMaintenanceDesired('{}').HasOwnProp("maintenanceEnabled"),"缺欄位不能重設預設值")
    mails := [], journal := root "\state.ini"
    notify := (stage, message) => mails.Push(stage)
    GM_NotifyStage(state,journal,GM_Decision(state,"WAIT_OPEN"),notify)
    GM_NotifyStage(state,journal,GM_Decision(state,"WAIT_OPEN"),notify)
    state := GM_LoadJournal(journal)
    GM_NotifyStage(state,journal,GM_Decision(state,"WAIT_OPEN"),notify)
    GMTest_Assert(mails.Length = 1 && mails[1] = "waiting","首次等待跨重啟只通知一次")
    state.expectedOpenAt := 30000, state.revision := "r2"
    GM_NotifyStage(state,journal,GM_Decision(state,"WAIT_OPEN"),notify)
    GMTest_Assert(mails.Length = 2 && mails[2] = "extended","維護延長通知")
    GM_NotifyStage(state,journal,GM_Decision(state,"CHECKING_LOGIN"),notify)
    GMTest_Assert(mails.Length = 2,"登入尚未完成不能宣告可開始鋤地")
    GM_NotifyStage(state,journal,GM_Decision(state,"READY"),notify)
    GMTest_Assert(mails.Length = 3 && mails[3] = "ready","只在主畫面就緒後通知可繼續")
}
