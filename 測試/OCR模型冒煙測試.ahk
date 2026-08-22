#Requires AutoHotkey v2.0+
#SingleInstance Off

#Include ..\payload\plugin\RapidOcr\RapidOcr.ahk

if (A_Args.Length < 3)
    ExitApp(2)

modelDir := A_Args[1]
imagePath := A_Args[2]
outputPath := A_Args[3]

try {
    ocr := RapidOcr({models: modelDir})
    started := A_TickCount
    blocks := ocr.ocr_from_file(imagePath, , true)
    elapsed := A_TickCount - started
    lines := [
        "status=ok",
        "model_dir=" modelDir,
        "image=" imagePath,
        "elapsed_ms=" elapsed,
        "block_count=" blocks.Length,
        ""
    ]
    for idx, block in blocks {
        text := StrReplace(StrReplace(block.text, "`r", " "), "`n", " ")
        lines.Push(idx "|" Trim(text, " `t"))
    }
    WriteOcrSmokeResult(outputPath, JoinOcrSmokeLines(lines))
    ExitApp(0)
} catch as e {
    WriteOcrSmokeResult(outputPath,
        "status=error`r`nmessage=" e.Message "`r`nline=" e.Line "`r`nwhat=" e.What)
    ExitApp(1)
}

JoinOcrSmokeLines(lines) {
    output := ""
    for idx, line in lines
        output .= (idx > 1 ? "`r`n" : "") line
    return output
}

WriteOcrSmokeResult(path, content) {
    try FileDelete(path)
    FileAppend(content, path, "UTF-8")
}
