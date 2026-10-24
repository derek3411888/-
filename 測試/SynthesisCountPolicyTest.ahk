#Requires AutoHotkey v2.0
#Include *i ..\payload\SynthesisCountPolicy.ahk
#Include fixtures\SynthesisCountMytuf20261024.ahk
#Warn VarUnset, Off
try {
    Assert(IsSet(SC_ParseCount),"missing semantic merge-count parser")
    actual := MytufFusionCountBlocks()
    Assert(SC_ParseCount([actual[2]],1280,720) = 20,"actual MYTUF complete data-fusion label is a count")
    Assert(SC_ParseCount(actual,1280,720) = 20,"actual material row overlapping the count ROI does not hide the count")
    Assert(SC_ParseCount([Block("數據融合次數：0")],1280,720) = 0,"traditional complete data-fusion label accepted")
    Assert(SC_ParseCount([actual[1]],1280,720) = -1,"material selection fraction is never a fusion count")
    Assert(SC_ParseCount([Block("数据融合次数：0/20")],1280,720) = -1,"partial data-fusion value is unknown")
    zeroActual := MytufFusionCountBlocks()
    zeroActual[2].text := "数据融合次数：0"
    Assert(SC_ParseCount(zeroActual,1280,720) = 0,"explicit zero remains grounded by the full label despite the adjacent material row")
    for delta in [1,4] {
        shifted := MytufFusionCountBlocks()
        for p in shifted[1].boxPoint
            p.y += delta
        Assert(SC_ParseCount(shifted,1280,720) = 20,"synthetic material OCR padding jitter cannot mask the real positive count")
        shifted[2].text := "数据融合次数：0"
        Assert(SC_ParseCount(shifted,1280,720) = 0,"synthetic material jitter with explicit zero remains semantic")
    }
    Assert(SC_ParseCount([Block("次数0"),Block("次数20",840,100)],1280,720) = -1,"center outside ROI cannot hide a clipped conflicting count beside zero")
    Assert(SC_ParseCount([Block("数据融合次数",940,80),Block("20",1030,25)],1280,720) = 20,"split full label and number remain uniquely aligned")
    Assert(SC_ParseCount([Block("数据融合次数：20",900)],1280,720) = -1,"clipped actual count candidates are still rejected")
    for b in actual
        for p in b.boxPoint
            p.x *= 1.5, p.y *= 1.5
    Assert(SC_ParseCount(actual,1920,1080) = 20,"actual neighboring rows scale consistently with the client capture")
    Assert(SC_ParseCount([Block("次数：0")],1280,720) = 0,"explicit contextual zero is accepted")
    Assert(SC_ParseCount([Block("融合次數12")],1280,720) = 12,"traditional count label accepted")
    for text in ["0","12abc","0/12","剩余0","次数0x","次数-1","次数00","次数1.5","0次"]
        Assert(SC_ParseCount([Block(text)],1280,720) = -1,"reject partial or ungrounded digits: " text)
    Assert(SC_ParseCount([Block("次数0"),Block("次数12",1000)],1280,720) = -1,"conflicting zero and nonzero cannot exhaust")
    Assert(SC_ParseCount([Block("次数0"),Block("次数0",1000)],1280,720) = -1,"duplicate detections are not a unique count")
    Assert(SC_ParseCount([Block("次数0",900)],1280,720) = -1,"count outside strict ROI is not evidence")
    Assert(SC_ParseCount([],1280,720) = -1,"empty OCR is unknown")
    Assert(SC_ParseCount(false,1280,720) = -1,"failed OCR is unknown")
    Assert(SC_ParseCount([Block("次数",940,40),Block("12",990,25)],1280,720) = 12,"unique aligned label plus number can be read")
    Assert(SC_ParseCount([Block("次数",940,40),Block("0",990,25),Block("12",1020,25)],1280,720) = -1,"split contradictory count is rejected")
    Assert(SC_ReadStableCount(CountIo([0,0])) = 0,"two fresh contextual zero observations permit exhaustion")
    Assert(SC_ReadStableCount(CountIo([0,12])) = -1,"contradictory stable samples cannot exhaust")
    Assert(SC_ReadStableCount(CountIo([-1,0])) = -1,"one valid zero after missing OCR is insufficient")
    Assert(SC_ReadStableCount(CountIo([0,0],true)) = -1,"reused frame cannot establish stability")
    Assert(SC_ReadStableCount(CountPausedIo([0,0,0])) = 0,"PAUSE discards old stability evidence and requires two resumed fresh zeros")
    Assert(SC_ReadStableCount(CountStaleIo([0,0])) = -1,"slow OCR wall-clock age is never extended by active budget")
    scaled := [Block("次数0")]
    for b in scaled
        for p in b.boxPoint
            p.x *= 1.5, p.y *= 1.5
    Assert(SC_ParseCount(scaled,1920,1080) = 0,"strict count ROI scales with actual capture dimensions")
    FileAppend("PASS: real synthesis count parser and stable-sample controller`n","*")
    ExitApp(0)
} catch as err {
    FileAppend("FAIL: " err.Message " | " err.Line "`n","**")
    ExitApp(1)
}
Assert(ok,message) {
    if !ok
        throw Error(message)
}
Block(text,x := 940,w := 90) => {text:text,boxPoint:[{x:x,y:608},{x:x+w,y:608},{x:x+w,y:628},{x:x,y:628}]}
class CountIo {
    __New(counts,reuse := false) {
        this.counts := counts, this.index := 0, this.tick := 0, this.reuse := reuse
    }
    Now() => this.tick
    Wait(ms) => this.tick += ms
    Sample() {
        this.index += 1, n := this.counts[Min(this.index,this.counts.Length)]
        return {blocks:n < 0 ? [] : [Block("次数" n)],width:1280,height:720,key:"held-game",frame:this.reuse ? 1 : this.index,capturedAt:this.tick,pausedMs:0}
    }
}
class CountPausedIo extends CountIo {
    Sample() {
        obs := super.Sample()
        obs.pausedMs := this.index > 1 ? 120000 : 0
        return obs
    }
}
class CountStaleIo extends CountIo {
    Sample() {
        obs := super.Sample()
        this.tick += 6000
        return obs
    }
}
