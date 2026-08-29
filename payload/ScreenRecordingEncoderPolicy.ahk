#Requires AutoHotkey v2.0+

; 純編碼參數策略：正式錄影預設優先使用 GPU；只有硬體編碼器不可用時
; 才保留 libx264 作為不中斷錄影的安全後備。
ScreenRecordingNormalizeEncoderName(value) {
    encoder := StrLower(Trim(value, " `t`r`n"))
    for supported in ["h264_nvenc", "h264_qsv", "h264_amf", "libx264"] {
        if (encoder = supported)
            return supported
    }
    return "libx264"
}

ScreenRecordingIsHardwareEncoder(value) {
    encoder := ScreenRecordingNormalizeEncoderName(value)
    return encoder = "h264_nvenc" || encoder = "h264_qsv" || encoder = "h264_amf"
}

ScreenRecordingClampInt(value, fallback, minValue, maxValue) {
    number := fallback
    try number := Integer(Trim(value, " `t`r`n"))
    return Min(maxValue, Max(minValue, number))
}

ScreenRecordingEncoderQualityArgs(encoder, qualityValue) {
    encoder := ScreenRecordingNormalizeEncoderName(encoder)
    quality := ScreenRecordingClampInt(qualityValue, 23, 0, 51)
    if (encoder = "h264_nvenc")
        return " -preset p4 -tune hq -rc vbr -cq " quality " -b:v 0"
    if (encoder = "h264_qsv")
        return " -preset veryfast -global_quality " quality " -look_ahead 0"
    if (encoder = "h264_amf")
        return " -usage transcoding -quality balanced -rc cqp -qp_i " quality
            . " -qp_p " quality " -qp_b " quality
    return " -preset veryfast -crf " quality
}

ScreenRecordingBuildFfmpegArgsForEncoder(encoder, fpsValue, qualityValue) {
    encoder := ScreenRecordingNormalizeEncoderName(encoder)
    fps := ScreenRecordingClampInt(fpsValue, 30, 10, 120)
    return "-y -f gdigrab -framerate " fps " -i desktop -c:v " encoder
        . ScreenRecordingEncoderQualityArgs(encoder, qualityValue)
        . " -pix_fmt yuv420p -f matroska"
}

ScreenRecordingExtractEncoder(args) {
    if RegExMatch(" " Trim(args, " `t`r`n") " ",
        "i)\s+-(?:c:v|vcodec)\s+([a-z0-9_]+)", &match)
        return StrLower(match[1])
    return ""
}

ScreenRecordingReadQualityFromArgs(args, fallback := 23) {
    txt := " " Trim(args, " `t`r`n") " "
    if RegExMatch(txt, "i)\s+-(?:crf|cq|global_quality|qp_i)\s+(\d+)", &match)
        return ScreenRecordingClampInt(match[1], fallback, 0, 51)
    return ScreenRecordingClampInt(fallback, 23, 0, 51)
}

ScreenRecordingUpgradeSoftwareArgs(args, hardwareEncoder, &changed := false) {
    changed := false
    hardwareEncoder := ScreenRecordingNormalizeEncoderName(hardwareEncoder)
    if !ScreenRecordingIsHardwareEncoder(hardwareEncoder)
        return args

    configuredEncoder := ScreenRecordingExtractEncoder(args)
    if ScreenRecordingIsHardwareEncoder(configuredEncoder)
        return args
    if (configuredEncoder != "libx264")
        return args

    quality := ScreenRecordingReadQualityFromArgs(args, 23)
    upgraded := args
    ; 移除 libx264 專用的品質選項；擷取、縮放、音訊與其他進階參數全部保留。
    upgraded := RegExReplace(upgraded, "i)\s+-preset\s+\S+", "")
    upgraded := RegExReplace(upgraded, "i)\s+-tune\s+\S+", "")
    upgraded := RegExReplace(upgraded, "i)\s+-crf\s+\d+", "")
    replacement := " -c:v " hardwareEncoder
        . ScreenRecordingEncoderQualityArgs(hardwareEncoder, quality)
    replaceCount := 0
    upgraded := RegExReplace(upgraded,
        "i)\s+-(?:c:v|vcodec)\s+libx264\b", replacement, &replaceCount, 1)
    changed := replaceCount > 0
    return Trim(RegExReplace(upgraded, "[ `t]{2,}", " "), " `t`r`n")
}
