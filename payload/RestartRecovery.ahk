#Requires AutoHotkey v2.0

; No game, process or network side effects here. The host supplies verified
; operations. Exhaustion retains the old owner; only a NEW user RUN grants a
; new batch. Internal retries never re-enter RestartAutoScript accounting.
RestartRecovery_Run(hooks, maxAttempts := 3) {
    attempts := 0, lastError := "", retryId := hooks.Read.Call().retry
    loop {
        intent := hooks.Read.Call()
        if intent.state = "STOP" {
            try hooks.Publish.Call("stopped", "停止要求已取消重啟交接", attempts)
            return "stopped"
        }
        if intent.retry != retryId {
            retryId := intent.retry, attempts := 0
        }
        if intent.state = "PAUSE" {
            try hooks.Publish.Call("paused", "暫停中，不清理或啟動下一輪", attempts)
            hooks.Wait.Call(1000)
            continue
        }
        if attempts >= maxAttempts {
            try hooks.Publish.Call("held", lastError, attempts)
            hooks.Wait.Call(1000)
            continue
        }
        attempts += 1
        try {
            result := hooks.Prepare.Call()
        } catch as err {
            lastError := err.Message
            try hooks.Publish.Call("failed", lastError, attempts)
            hooks.Wait.Call(5000)
            continue
        }
        try hooks.Publish.Call("armed", "交接 worker 已備妥；接手仍待新程序驗證", attempts)
        ; Commit is a short atomic intent check in the host. A PAUSE/STOP can
        ; arrive while the worker arms or while status HTTP yields. Never let
        ; that leave an armed worker waiting behind the caller's pause gate.
        if hooks.Commit.Call()
            return result
        hooks.Cancel.Call()
        hooks.Wait.Call(1000)
    }
}
