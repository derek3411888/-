#Requires AutoHotkey v2.0+
#Include ..\payload\ScreenRecordingEncoderPolicy.ahk

AssertTrue(value, description) {
    if !value
        throw Error(description)
}

try {
    nvenc := ScreenRecordingBuildFfmpegArgsForEncoder("h264_nvenc", 60, 23)
    AssertTrue(InStr(nvenc, "-framerate 60"), "NVENC 必須保留 60fps")
    AssertTrue(InStr(nvenc, "-c:v h264_nvenc"), "NVENC 編碼器未套用")
    AssertTrue(InStr(nvenc, "-cq 23"), "NVENC 品質參數未套用")
    AssertTrue(!InStr(nvenc, "libx264"), "NVENC 不可殘留 libx264")

    legacy := '-y -f gdigrab -framerate 60 -i desktop -vf "scale=1920:-2" '
        . '-c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -f matroska'
    upgraded := ScreenRecordingUpgradeSoftwareArgs(legacy, "h264_nvenc", &changed)
    AssertTrue(changed, "既有 libx264 設定必須遷移")
    AssertTrue(InStr(upgraded, '-vf "scale=1920:-2"'), "遷移不可刪除自訂濾鏡")
    AssertTrue(InStr(upgraded, "-framerate 60"), "遷移不可改變 FPS")
    AssertTrue(InStr(upgraded, "-c:v h264_nvenc"), "遷移未改用 NVENC")
    AssertTrue(!InStr(upgraded, "-crf 23"), "遷移後不可保留 libx264 CRF")

    qsv := ScreenRecordingBuildFfmpegArgsForEncoder("h264_qsv", 30, 20)
    AssertTrue(InStr(qsv, "-c:v h264_qsv"), "QSV 編碼器未套用")
    amf := ScreenRecordingBuildFfmpegArgsForEncoder("h264_amf", 30, 20)
    AssertTrue(InStr(amf, "-c:v h264_amf"), "AMF 編碼器未套用")

    alreadyHardware := ScreenRecordingUpgradeSoftwareArgs(nvenc, "h264_qsv", &changedAgain)
    AssertTrue(!changedAgain && alreadyHardware = nvenc, "既有硬體編碼設定不可被覆蓋")
    FileAppend("screen-recording-encoder-policy=ok`n", "*")
} catch as e {
    FileAppend("screen-recording-encoder-policy=failed: " e.Message "`n", "**")
    ExitApp(1)
}
ExitApp(0)
