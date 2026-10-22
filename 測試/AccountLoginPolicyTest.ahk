#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameAccountLogin.ahk
GMTest_Run(TestAccountLogin)
LoginBlock(text,x,y) => {text:text,boxPoint:[{x:x-40,y:y-12},{x:x+40,y:y-12},{x:x+40,y:y+12}]}
LoginBlocks(label := "登录") => [LoginBlock("MKURO GAMES",640,180),LoginBlock(label,640,430),LoginBlock("其他登录方式",640,550)]
class LoginFixture {
    tick := 10000
    attempts := 0
    lastAttempt := 0
    clicks := 0
    state := "RUN"
    aliveFlag := true
    confirms := true
    Now() => this.tick
    Intent() => this.state
    Alive() => this.aliveFlag
    Confirm(obs) {
        this.clicks++
        return this.confirms
    }
}
TestAccountLogin() {
    GMTest_Assert(!GL_IsAccountDialog([LoginBlock("KURO GAMES",640,680),LoginBlock("點擊連接",640,450),LoginBlock("伺服器 Asia 帳號",640,550)]),"branding on normal server login screen must not trap server selection")
    for label in ["登录","登入","登 錄"] {
        c := GL_Classify(LoginBlocks(label),1280,720)
        GMTest_Assert(IsObject(c) && c.x = 640 && c.y = 430,"exact login label in KURO account dialog is actionable")
    }
    GMTest_Assert(!GL_Classify([LoginBlock("登录",640,430)],1280,720),"unrelated login text cannot authorize game input")
    GMTest_Assert(!GL_Classify(LoginBlocks("點擊連接"),1280,720),"normal server connection still follows server-selection and F11 flow")
    for word in ["重新登入說明","取消登入","登录失败","登录中"]
        GMTest_Assert(!GL_Classify(LoginBlocks(word),1280,720),"substring matches are not login buttons")
    blocks := LoginBlocks(), blocks.Push(LoginBlock("登入",680,500))
    GMTest_Assert(!GL_Classify(blocks,1280,720),"ambiguous login candidates do not click")
    blocks := LoginBlocks(), blocks[2] := LoginBlock("登录",1400,430)
    GMTest_Assert(!GL_Classify(blocks,1280,720),"out-of-client coordinates rejected")
    for word in ["验证码","驗證碼","请输入密码","輸入密碼","伺服器維護中","服务器正在维护","Server under maintenance"] {
        blocks := LoginBlocks(), blocks.Push(LoginBlock(word,640,300))
        GMTest_Assert(!GL_Classify(blocks,1280,720),"credentials, human verification or maintenance never auto-click")
    }
    obs := {candidate:GL_Classify(LoginBlocks(),1280,720),capturedAt:10000,width:1280,height:720}
    io := LoginFixture()
    GMTest_Assert(GL_Attempt(io,obs) = "clicked" && io.clicks = 1,"detected login requests one guarded physical click, not login success")
    GMTest_Assert(GL_Attempt(io,obs) = "waiting" && io.clicks = 1,"same frame cannot spam login")
    loop 2 {
        io.tick += 15000, obs.capturedAt := io.tick
        GMTest_Assert(GL_Attempt(io,obs) = "clicked","persistent confirmed button gets bounded retry")
    }
    io.tick += 15000, obs.capturedAt := io.tick
    GMTest_Assert(GL_Attempt(io,obs) = "limit" && io.clicks = 3,"three attempts then wait without restart-budget reset")
    for state in ["PAUSE","STOP"] {
        io := LoginFixture(), io.state := state, obs.capturedAt := io.tick
        GMTest_Assert(GL_Attempt(io,obs) != "clicked" && io.clicks = 0,"latest control intent forbids input")
    }
    io := LoginFixture(), io.aliveFlag := false
    GMTest_Assert(GL_Attempt(io,obs) != "clicked" && io.clicks = 0,"exited held process forbids click")
    for time in [4999,11000] {
        io := LoginFixture(), obs.capturedAt := time
        GMTest_Assert(GL_Attempt(io,obs) != "clicked" && io.clicks = 0,"stale or future capture cannot click")
    }
    io := LoginFixture(), io.confirms := false, obs.capturedAt := io.tick
    GMTest_Assert(GL_Attempt(io,obs) = "waiting" && io.attempts = 1,"failed foreground guard is not success and is throttled")
}
