#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\ScriptRestartHandoff.ahk
GMTest_Run(TestCancelledWorker)
TestCancelledWorker() {
    global RestartHandoff_ActiveRequest, RestartHandoff_WorkerHandle
    root := TestRuntime_NewCaseDir("cancelled-worker-retry")
    target := root "\inert-successor.ahk"
    FileAppend("#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`nExitApp(77)`n",target,"UTF-8")
    GMTest_Assert(RestartHandoff_ResetCancelled(),"empty ownership needs no cancellation")
    try {
        first := RestartHandoff_Prepare(A_AhkPath,target,"restart",root,"",10000,1000)
        GMTest_Assert(RestartHandoff_WorkerHandle && RestartHandoff_ActiveRequest = first.request,"native worker owns exact parent before retry")
        deadline := A_TickCount + 5000
        reset := false
        loop {
            reset := RestartHandoff_ResetCancelled()
            if reset || A_TickCount >= deadline
                break
            ; Before exit is observed, a live native handle/request must remain.
            GMTest_Assert(RestartHandoff_WorkerHandle && RestartHandoff_ActiveRequest = first.request,"pending cancellation retains ownership")
            Sleep(20)
        }
        GMTest_Assert(reset && !RestartHandoff_WorkerHandle && RestartHandoff_ActiveRequest = "","clear only after native worker exit")
        SplitPath(first.request,,&firstDir)
        GMTest_Assert(IniRead(firstDir "\result.ini","result","state","") = "cancelled","actual worker confirmed cancellation")
        second := RestartHandoff_Prepare(A_AhkPath,target,"restart resume",root,"",10000,1000)
        GMTest_Assert(second.request != first.request,"next attempt gets new request only after previous exit")
    } finally {
        deadline := A_TickCount + 5000
        loop {
            if RestartHandoff_ResetCancelled() || A_TickCount >= deadline
                break
            Sleep(20)
        }
    }
    GMTest_Assert(RestartHandoff_ActiveRequest = "","fixture leaves no armed successor")
}
