#Requires AutoHotkey v2.0+
#SingleInstance Force

#Include ..\LauncherPayloadUpdatePolicy.ahk

AssertPayloadReuse(condition, message) {
    if !condition
        throw Error(message)
}

try {
    expectedSha := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    upgraded := LauncherPayloadReuse_Decide("5.09", "5.13", expectedSha, expectedSha, true, false)
    AssertPayloadReuse(upgraded.reuseLocalZip && upgraded.forceUnpack,
        "新版 EXE 內嵌 ZIP 已符合遠端 SHA 時必須直接套用，不得再下載")

    repairSameVersion := LauncherPayloadReuse_Decide("5.13", "5.13", expectedSha, expectedSha, true, true)
    AssertPayloadReuse(repairSameVersion.reuseLocalZip && repairSameVersion.forceUnpack,
        "同版本修復且內嵌 ZIP 正確時必須直接重新解壓")

    mismatch := LauncherPayloadReuse_Decide("5.09", "5.13", expectedSha,
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", true, false)
    AssertPayloadReuse(!mismatch.reuseLocalZip,
        "本機 ZIP SHA 不符時不得略過遠端下載")

    missing := LauncherPayloadReuse_Decide("5.09", "5.13", expectedSha, "", false, false)
    AssertPayloadReuse(!missing.reuseLocalZip,
        "本機 ZIP 不存在時不得宣告可直接套用")

    invalidExpected := LauncherPayloadReuse_Decide("5.09", "5.13", "", expectedSha, true, false)
    AssertPayloadReuse(!invalidExpected.reuseLocalZip,
        "manifest 沒有有效 SHA 時不得只靠版本文字信任本機 ZIP")

    FileAppend("launcher-payload-reuse-policy=ok`n", "*")
} catch as e {
    FileAppend("launcher-payload-reuse-policy=failed: " e.Message "`n", "**")
    ExitApp(1)
}

ExitApp(0)
