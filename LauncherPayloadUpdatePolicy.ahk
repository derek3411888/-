#Requires AutoHotkey v2.0+

LauncherVersion_IsOlder(remoteVersion, localVersion) {
    remoteVersion := Trim(String(remoteVersion)), localVersion := Trim(String(localVersion))
    if !RegExMatch(remoteVersion,"^\d+(\.\d+)*$") || !RegExMatch(localVersion,"^\d+(\.\d+)*$")
        return false
    remoteParts := StrSplit(remoteVersion,"."), localParts := StrSplit(localVersion,".")
    loop Max(remoteParts.Length,localParts.Length) {
        left := A_Index <= remoteParts.Length ? LTrim(remoteParts[A_Index],"0") : ""
        right := A_Index <= localParts.Length ? LTrim(localParts[A_Index],"0") : ""
        if StrLen(left) != StrLen(right)
            return StrLen(left) < StrLen(right)
        comparison := StrCompare(left,right,true)
        if comparison
            return comparison < 0
    }
    return false
}

LauncherPayloadUnpack_Decide(requested,candidateVersion,installedVersion,healthy,recoveryRequired,candidateTrusted := true) {
    older := requested && LauncherVersion_IsOlder(candidateVersion,installedVersion)
    untrusted := requested && !candidateTrusted
    return {unpack:requested && !older && !untrusted,
        blocked:untrusted || (older && (!healthy || recoveryRequired)),
        keptNewer:older && healthy && !recoveryRequired && !untrusted,untrusted:untrusted}
}

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
