#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameMaintenance.ahk
#Include ..\payload\GameStableLaunch.ahk
GMTest_Run(TestStableLaunch)
TestStableLaunch() {
    for provider in ["steam","kuro"] {
        install := {provider:provider,identityVerified:true,gameRoot:"D:\fixture"}
        calls := [], tick := 0, ready := false
        hooks := {Exists:(path) => path = "D:\fixture\Wuthering Waves.exe", CanAct:(*) => true,
            Ready:(*) => ready, Now:(*) => tick, Wait:(ms) => (tick += ms,ready := true),
            Launch:(path) => (calls.Push(path),true)}
        result := GM_StableLaunch(install,hooks,5000)
        GMTest_Assert(result.ok && calls.Length = 1 && calls[1] = "D:\fixture\Wuthering Waves.exe","both installs use original wrapper exactly once, not updater or shipping binary")
        GMTest_Assert(!result.HasOwnProp("loginSuccess"),"window existence must not claim gameplay or login")
        result := GM_StableLaunch(install,hooks,5000)
        GMTest_Assert(result.ok && calls.Length = 1,"existing verified game never launches twice")
        ready := false, hooks.CanAct := (*) => false
        GMTest_Assert(!GM_StableLaunch(install,hooks,5000).ok && calls.Length = 1,"STOP/PAUSE prevents launch")
        hooks.CanAct := (*) => true, install.identityVerified := false
        GMTest_Assert(!GM_StableLaunch(install,hooks,5000).ok && calls.Length = 1,"unverified install cannot launch")
        install.identityVerified := true, hooks.Wait := (ms) => tick += ms
        GMTest_Assert(!GM_StableLaunch(install,hooks,500).ok && calls.Length = 2,"missing window times out without retrying or claiming success")
        allowed := true, hooks.CanAct := (*) => allowed
        hooks.Ready := (*) => (allowed := false)
        GMTest_Assert(!GM_StableLaunch(install,hooks,500).ok && calls.Length = 2,"PAUSE during window inventory cannot launch afterward")
    }
    tick := 0, intent := "PAUSE", ready := false, calls := []
    hooks := {Exists:(*) => true, Intent:(*) => intent, CanAct:(*) => intent = "RUN",
        Ready:(*) => ready, Now:(*) => tick,
        Wait:(ms) => (tick += 5000,intent := "RUN",ready := calls.Length > 0),
        Launch:(path) => (calls.Push(path),true)}
    result := GM_StableLaunch({identityVerified:true,gameRoot:"D:\fixture"},hooks,1000)
    GMTest_Assert(result.ok && calls.Length = 1,"PAUSE stays alive and resumes once without spending the startup timeout")
    ready := false, calls := [], tick := 0, intent := "PAUSE"
    hooks.BeforeLaunch := (*) => {ok:false,errorCode:"SKIPPED_UPDATE_DAY",detail:"day changed while paused"}
    result := GM_StableLaunch({identityVerified:true,gameRoot:"D:\fixture"},hooks,1000)
    GMTest_Assert(!result.ok && result.errorCode = "SKIPPED_UPDATE_DAY" && calls.Length = 0,"post-PAUSE calendar recheck can skip without launch")
    ready := true, intent := "RUN"
    result := GM_StableLaunch({identityVerified:true,gameRoot:"D:\fixture"},hooks,1000)
    GMTest_Assert(!result.ok && result.errorCode = "SKIPPED_UPDATE_DAY" && calls.Length = 0,"an externally appeared window cannot bypass the day gate into farming")
}
