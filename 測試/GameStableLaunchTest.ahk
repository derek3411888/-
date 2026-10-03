#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameMaintenance.ahk
#Include ..\payload\GameStableLaunch.ahk
GMTest_Run(TestStableLaunch)
TestStableLaunch() {
    for provider in ["steam","kuro"] {
        install := {provider:provider,identityVerified:true,gameRoot:"D:\fixture"}
        calls := [], arguments := [], tick := 0, ready := false
        hooks := {Exists:(path) => path = "D:\fixture\Wuthering Waves.exe", CanAct:(*) => true,
            Ready:(*) => ready, Now:(*) => tick, Wait:(ms) => (tick += ms,ready := true),
            Launch:(path,args := "") => (calls.Push(path),arguments.Push(args),true)}
        result := GM_StableLaunch(install,hooks,5000)
        GMTest_Assert(result.ok && calls.Length = 1 && calls[1] = "D:\fixture\Wuthering Waves.exe","both installs use original wrapper exactly once, not updater or shipping binary")
        GMTest_Assert(arguments[1] = "-krqlv=hd","both providers default to the HD resource argument")
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
        Launch:(path,args := "") => (calls.Push(path),true)}
    result := GM_StableLaunch({identityVerified:true,gameRoot:"D:\fixture"},hooks,1000)
    GMTest_Assert(result.ok && calls.Length = 1,"PAUSE stays alive and resumes once without spending the startup timeout")
    ready := false, calls := [], tick := 0, intent := "PAUSE"
    hooks.BeforeLaunch := (*) => {ok:false,errorCode:"SKIPPED_UPDATE_DAY",detail:"day changed while paused"}
    result := GM_StableLaunch({identityVerified:true,gameRoot:"D:\fixture"},hooks,1000)
    GMTest_Assert(!result.ok && result.errorCode = "SKIPPED_UPDATE_DAY" && calls.Length = 0,"post-PAUSE calendar recheck can skip without launch")
    ready := true, intent := "RUN"
    result := GM_StableLaunch({identityVerified:true,gameRoot:"D:\fixture"},hooks,1000)
    GMTest_Assert(!result.ok && result.errorCode = "SKIPPED_UPDATE_DAY" && calls.Length = 0,"an externally appeared window cannot bypass the day gate into farming")
    TestResourceSelection()
    TestResourceFiles()
}

TestResourceSelection() {
    install := {provider:"kuro",identityVerified:true,gameRoot:"D:\fixture"}
    for test in [
        {states:Map("hd","present","sd","present","uhd","present"),arg:"-krqlv=hd"},
        {states:Map("hd","missing","sd","present","uhd","present"),arg:"-krqlv=sd"},
        {states:Map("hd","missing","sd","missing","uhd","present"),arg:"-krqlv=uhd"},
        {states:Map("hd","unknown","sd","present","uhd","present"),arg:"-krqlv=hd"},
        {states:Map("hd","missing","sd","unknown","uhd","present"),arg:"-krqlv=uhd"},
        {states:Map("hd","missing","sd","missing","uhd","unknown"),arg:""}] {
        calls := [], probes := [], tick := 0, ready := false, fixtureStates := test.states
        hooks := {Exists:(*) => true, Intent:(*) => "RUN", Ready:(*) => ready,
            Now:(*) => tick,Wait:(ms) => (tick += ms,ready := calls.Length > 0),
            PackageState:(tier) => (probes.Push(tier),fixtureStates[tier]),
            Launch:(path,args := "") => (calls.Push(args),true)}
        GMTest_Assert(hooks.PackageState.Call("hd") = test.states["hd"],"package fixture reports expected HD state")
        probes := []
        result := GM_StableLaunch(install,hooks,1000)
        if test.arg != ""
            GMTest_Assert(result.ok && calls.Length = 1 && calls[1] = test.arg,"select only an evidenced package: expected=" test.arg " calls=" calls.Length " actual=" (calls.Length ? calls[1] : "") " detail=" result.detail)
        else
            GMTest_Assert(!result.ok && result.errorCode = "GAME_PACKAGE_MISSING" && calls.Length = 0,"missing HD without a known installed alternative must not guess")
    }
    ; Steam 3.7 is HD-only. Shared base Paks are not evidence of an SD bundle.
    install.provider := "steam", calls := [], probes := []
    hooks.PackageState := (tier) => (probes.Push(tier),tier = "hd" ? "missing" : "present")
    result := GM_StableLaunch(install,hooks,1000)
    GMTest_Assert(!result.ok && calls.Length = 0 && probes.Length = 1,"Steam cannot fall back to unsupported resource tiers")
    install.provider := "kuro", ready := true, probes := []
    result := GM_StableLaunch(install,hooks,1000)
    GMTest_Assert(result.ok && calls.Length = 0 && probes.Length = 0,"existing verified window bypasses package probing and relaunch")
    ready := false, intent := "RUN"
    hooks.Intent := (*) => intent
    hooks.PackageState := (tier) => (intent := "STOP","missing")
    result := GM_StableLaunch(install,hooks,1000)
    GMTest_Assert(result.errorCode = "STOPPED" && calls.Length = 0,"STOP arriving during resource inventory prevents launch")
    intent := "RUN", tick := 0
    hooks.PackageState := (*) => "unknown"
    hooks.Wait := (ms) => tick += ms
    result := GM_StableLaunch(install,hooks,500)
    GMTest_Assert(result.errorCode = "GAME_ENTRY_NO_WINDOW" && calls.Length = 1 && calls[1] = "-krqlv=hd","a generic crash or timeout never causes package retries")
    calls := [], tick := 0, intent := "RUN", ready := false, probes := []
    hooks.PackageState := (tier) => (probes.Push(tier),intent := probes.Length = 1 ? "PAUSE" : "RUN","present")
    hooks.Wait := (ms) => (tick += 5000,intent := "RUN",ready := calls.Length > 0)
    result := GM_StableLaunch(install,hooks,1000)
    GMTest_Assert(result.ok && probes.Length = 2 && calls.Length = 1,"PAUSE during package inventory resumes with fresh evidence and one launch")
    calls := [], ready := false, tick := 0
    hooks.PackageState := ThrowPackageProbe
    result := GM_StableLaunch(install,hooks,1000)
    GMTest_Assert(result.ok && calls.Length = 1 && calls[1] = "-krqlv=hd","inventory error preserves HD and does not infer absence")
    calls := [], ready := false, tick := 0
    hooks.PackageState := (*) => (ready := true,"present")
    result := GM_StableLaunch(install,hooks,1000)
    GMTest_Assert(result.ok && calls.Length = 0,"window appearing during inventory must be reused without a second launch")
    ready := false
    hooks.PackageState := (*) => "present"
    hooks.ReportPackage := (*) => ready := true
    result := GM_StableLaunch(install,hooks,1000)
    GMTest_Assert(result.ok && calls.Length = 0,"window appearing during package logging must also be reused")
    hooks.DeleteProp("ReportPackage")
    ready := false, gateCalls := 0
    hooks.PackageState := (*) => "present"
    hooks.BeforeLaunch := (*) => (++gateCalls = 1 ? {ok:true} : {ok:false,errorCode:"SKIPPED_UPDATE_DAY",detail:"day changed during inventory"})
    result := GM_StableLaunch(install,hooks,1000)
    GMTest_Assert(result.errorCode = "SKIPPED_UPDATE_DAY" && calls.Length = 0,"package inventory cannot carry yesterday's launch permit into update day")
}

ThrowPackageProbe(*) {
    throw Error("fixture unreadable")
}

TestResourceFiles() {
    root := TestRuntime_NewCaseDir("game-resource-packages","packages")
    install := {provider:"kuro",identityVerified:true,gameRoot:root}
    GMTest_Assert(GM_StablePackageState(install,"hd") = "unknown","missing install content is not evidence of an absent HD bundle")
    DirCreate(root "\Client\Content\Paks")
    FileAppend("common",root "\Client\Content\Paks\pakchunk0-WindowsNoEditor.pak")
    GMTest_Assert(GM_StablePackageState(install,"hd") = "missing","native path-not-found in known content proves missing HD directory")
    GMTest_Assert(GM_StablePackageState(install,"sd") = "missing","shared base Paks must not be labeled as installed SD")
    for tier in ["HD","SD","UHD"] {
        directory := root "\Client\Content\" tier
        DirCreate(directory)
        GMTest_Assert(GM_StablePackageState(install,StrLower(tier)) = "unknown","an empty tier directory may be incomplete or a new layout, not a retry signal")
        pak := directory "\pakchunk1-" tier "-WindowsNoEditor.pak"
        sig := directory "\pakchunk1-" tier "-WindowsNoEditor.sig"
        FileAppend("pak-fixture",pak)
        GMTest_Assert(GM_StablePackageState(install,StrLower(tier)) = "unknown","a missing signature is not an installed alternative")
        FileAppend("signature-fixture",sig)
        GMTest_Assert(GM_StablePackageState(install,StrLower(tier)) = "present","native inventory recognizes tier-specific pak/signature pair")
    }
    GMTest_Assert(GM_StablePackageState(install,"..\Paks") = "unknown","resource tier cannot inject a filesystem path")
    install.identityVerified := false
    GMTest_Assert(GM_StablePackageState(install,"hd") = "unknown","unverified installations cannot supply package evidence")
    upperRoot := TestRuntime_NewCaseDir("game-resource-packages","upper-extension")
    DirCreate(upperRoot "\Client\Content\Paks")
    DirCreate(upperRoot "\Client\Content\SD")
    install := {provider:"kuro",identityVerified:true,gameRoot:upperRoot}
    FileAppend("uppercase pak",upperRoot "\Client\Content\SD\pakchunk1-SD-WindowsNoEditor.PAK")
    GMTest_Assert(GM_StablePackageState(install,"sd") = "unknown","uppercase PAK cannot serve as its own missing signature")
    DirCreate(upperRoot "\Client\Content\SD\pakchunk2-SD-WindowsNoEditor.sig")
    FileAppend("pak with directory signature",upperRoot "\Client\Content\SD\pakchunk2-SD-WindowsNoEditor.pak")
    GMTest_Assert(GM_StablePackageState(install,"sd") = "unknown","signature directory is not a signature file")
    FileAppend("uppercase signature",upperRoot "\Client\Content\SD\pakchunk1-SD-WindowsNoEditor.SIG")
    GMTest_Assert(GM_StablePackageState(install,"sd") = "present","native case-insensitive PAK and SIG pair is accepted")
}
