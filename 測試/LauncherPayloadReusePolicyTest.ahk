#Requires AutoHotkey v2.0+
#SingleInstance Force

#Include ..\LauncherPayloadUpdatePolicy.ahk

AssertPayloadReuse(condition, message) {
    if !condition
        throw Error(message)
}

try {
    untrustedUnpack := LauncherPayloadUnpack_Decide(true,"5.29","5.29",true,false,false)
    AssertPayloadReuse(untrustedUnpack.blocked && !untrustedUnpack.unpack, "內嵌釋出失敗不能把磁碟舊 ZIP 當新版解壓")
    blockedUnpack := LauncherPayloadUnpack_Decide(true,"5.29","5.30",false,false)
    AssertPayloadReuse(blockedUnpack.blocked && !blockedUnpack.unpack, "較舊內嵌包不可修復較新且缺檔安裝")
    keptUnpack := LauncherPayloadUnpack_Decide(true,"5.29","5.30",true,false)
    AssertPayloadReuse(!keptUnpack.blocked && !keptUnpack.unpack && keptUnpack.keptNewer, "強制解壓也不可降級完整新版安裝")
    journalUnpack := LauncherPayloadUnpack_Decide(true,"5.29","5.30",true,true)
    AssertPayloadReuse(journalUnpack.blocked && !journalUnpack.unpack, "未完成更新交易不能當作可直接啟動")
    newerUnpack := LauncherPayloadUnpack_Decide(true,"5.31","5.30",true,false)
    AssertPayloadReuse(newerUnpack.unpack && !newerUnpack.blocked, "較新修正保留正常解壓路徑")
    AssertPayloadReuse(LauncherVersion_IsOlder("5.28","5.29"), "必須辨識較舊遠端版本")
    AssertPayloadReuse(!LauncherVersion_IsOlder("5.29","5.28"), "較新遠端版本不可被擋住")
    AssertPayloadReuse(!LauncherVersion_IsOlder("5.29","5.29.0"), "尾端零視為相同版本")
    AssertPayloadReuse(!LauncherVersion_IsOlder("5.100","5.99"), "版本元件按數值長度比較")
    AssertPayloadReuse(LauncherVersion_IsOlder("5.09","5.10"), "版本前導零不可改變比較結果")
    AssertPayloadReuse(!LauncherVersion_IsOlder("fixture-2","5.29"), "既有非數字標記維持原有更新流程")
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
