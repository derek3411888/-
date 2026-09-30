#Requires AutoHotkey v2.0+

LauncherPayloadReuse_Decide(currentVersion, remoteVersion, expectedSha,
    actualSha, localFileExists, forceDownload := false) {
    currentVersion := Trim(String(currentVersion), " `t`r`n")
    remoteVersion := Trim(String(remoteVersion), " `t`r`n")
    expectedSha := StrLower(Trim(String(expectedSha), " `t`r`n"))
    actualSha := StrLower(Trim(String(actualSha), " `t`r`n"))

    validExpectedSha := expectedSha ~= "^[0-9a-f]{64}$"
    validActualSha := actualSha ~= "^[0-9a-f]{64}$"
    needsApply := !!forceDownload || remoteVersion != currentVersion
    reuseLocalZip := !!localFileExists && needsApply && validExpectedSha
        && validActualSha && expectedSha = actualSha

    return {
        reuseLocalZip: reuseLocalZip,
        forceUnpack: reuseLocalZip,
        reason: reuseLocalZip
            ? "local_payload_sha_matches_remote"
            : "remote_download_required"
    }
}
