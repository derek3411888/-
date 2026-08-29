[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [Parameter(Mandatory = $true)][int]$ParentPid,
    [int]$SampleIntervalSeconds = 2,
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$SampleIntervalSeconds = [Math]::Max(2, [Math]::Min(10, $SampleIntervalSeconds))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$heartbeatPath = Join-Path $OutputRoot 'heartbeat.json'
$firestorePath = Join-Path $OutputRoot 'firestore.json'
$minutesPath = Join-Path $OutputRoot 'minutes.ndjson'
$stopPath = Join-Path $OutputRoot ("stop_{0}.flag" -f $ParentPid)
$presentMonVersion = '2.5.1'
$presentMonUrl = 'https://github.com/GameTechDev/PresentMon/releases/download/v2.5.1/PresentMon-2.5.1-x64.exe'
$presentMonSha256 = '9BEC3083069F58F911E6A512F4806DB51A27BD096103087BC1D05EF54C80A191'
$toolRoot = Join-Path (Split-Path -Parent $OutputRoot) 'tools\PresentMon'
$presentMonExe = Join-Path $toolRoot 'PresentMon.exe'
$metricNames = @(
    'fps', 'fps1Low', 'frameTimeMs', 'frameTimeP95Ms', 'frameTimeP99Ms',
    'cpuTotalPct', 'cpuGamePct', 'cpuOkwwPct', 'cpuLrmcPct', 'cpuFfmpegPct',
    'gpuPct', 'gpuVramMb', 'gpuTempC', 'gpuPowerW', 'gpuEncoderPct',
    'ramUsedGb', 'ramTotalGb', 'gameRamMb', 'okwwRamMb', 'lrmcRamMb', 'ffmpegRamMb',
    'diskReadMbps', 'diskWriteMbps', 'diskFreeGb', 'networkDownMbps', 'networkUpMbps',
    'recordingFps', 'recordingDroppedFrames', 'recordingDuplicatedFrames',
    'liveFps', 'liveDroppedFrames', 'liveDuplicatedFrames'
)

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue

function Get-UnixMilliseconds {
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Write-AtomicUtf8([string]$Path, [string]$Content) {
    $temporary = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($temporary, $Content, $script:utf8)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Convert-Number($Value, [double]$Minimum = -1.0e12, [double]$Maximum = 1.0e12) {
    if ($null -eq $Value) { return $null }
    $number = 0.0
    if (-not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
    return [Math]::Round([Math]::Max($Minimum, [Math]::Min($Maximum, $number)), 3)
}

function Get-Percentile([double[]]$Values, [double]$Percentile) {
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $ordered = @($Values | Sort-Object)
    $index = [Math]::Max(0, [Math]::Min($ordered.Count - 1,
        [Math]::Ceiling(($Percentile / 100.0) * $ordered.Count) - 1))
    return [double]$ordered[$index]
}

function Get-ProcessSnapshot([string]$Name) {
    $items = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    $cpu = 0.0
    $working = 0L
    foreach ($item in $items) {
        try { $cpu += $item.TotalProcessorTime.TotalSeconds } catch {}
        try { $working += $item.WorkingSet64 } catch {}
    }
    return [pscustomobject]@{ Count = $items.Count; CpuSeconds = $cpu; WorkingSet = $working }
}

function Get-ProcessCpuPercent([string]$Key, $Snapshot, [double]$ElapsedSeconds, [int]$LogicalProcessors) {
    if (-not $script:previousProcessCpu.ContainsKey($Key)) {
        $script:previousProcessCpu[$Key] = [double]$Snapshot.CpuSeconds
        return $null
    }
    $previous = [double]$script:previousProcessCpu[$Key]
    $script:previousProcessCpu[$Key] = [double]$Snapshot.CpuSeconds
    if ($ElapsedSeconds -le 0) { return $null }
    return Convert-Number (([double]$Snapshot.CpuSeconds - $previous) * 100.0 /
        ($ElapsedSeconds * [Math]::Max(1, $LogicalProcessors))) 0 100
}

function Find-NvidiaSmi {
    $candidates = @(
        "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
        "$env:WINDIR\System32\nvidia-smi.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    $command = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return ''
}

function Read-FfmpegProgress([string]$Name) {
    $path = Join-Path $OutputRoot ("{0}_progress.txt" -f $Name)
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Active = $false; Fps = $null; Dropped = $null; Duplicated = $null; Speed = $null }
    }
    try {
        $file = Get-Item -LiteralPath $path
        $active = ((Get-Date) - $file.LastWriteTime).TotalSeconds -lt 12
        $data = @{}
        foreach ($line in @(Get-Content -LiteralPath $path -Tail 40 -ErrorAction Stop)) {
            if ($line -match '^([^=]+)=(.*)$') { $data[$matches[1]] = $matches[2] }
        }
        return [pscustomobject]@{
            Active = $active
            Fps = Convert-Number $data['fps'] 0 1000
            Dropped = Convert-Number $data['drop_frames'] 0 1.0e12
            Duplicated = Convert-Number $data['dup_frames'] 0 1.0e12
            Speed = [string]$data['speed']
        }
    } catch {
        return [pscustomobject]@{ Active = $false; Fps = $null; Dropped = $null; Duplicated = $null; Speed = $null }
    }
}

function Ensure-PresentMon {
    if (Test-Path -LiteralPath $presentMonExe) {
        try {
            if ((Get-FileHash -LiteralPath $presentMonExe -Algorithm SHA256).Hash -eq $presentMonSha256) {
                return $true
            }
        } catch {}
        Remove-Item -LiteralPath $presentMonExe -Force -ErrorAction SilentlyContinue
    }
    try {
        New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
        $download = "$presentMonExe.download"
        Invoke-WebRequest -UseBasicParsing -Uri $presentMonUrl -OutFile $download
        if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $presentMonSha256) {
            throw 'PresentMon SHA-256 verification failed'
        }
        Move-Item -LiteralPath $download -Destination $presentMonExe -Force
        return $true
    } catch {
        $script:lastCollectorError = "PresentMon download: $($_.Exception.Message)"
        Remove-Item -LiteralPath "$presentMonExe.download" -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Stop-PresentMon {
    if ($script:presentMonProcess -and -not $script:presentMonProcess.HasExited) {
        try { $script:presentMonProcess.Kill() } catch {}
        try { $script:presentMonProcess.WaitForExit(3000) | Out-Null } catch {}
    }
    $script:presentMonProcess = $null
    $script:presentHeader = $null
    $script:presentOffset = 0L
}

function Start-PresentMon {
    if (-not (Ensure-PresentMon)) { return $false }
    Stop-PresentMon
    $script:presentCsv = Join-Path $OutputRoot ("presentmon_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date))
    $arguments = '--process_name Client-Win64-Shipping.exe --output_file "{0}" --v2_metrics --exclude_dropped --no_console_stats --session_name WutheringAutoPerformance --stop_existing_session' -f $script:presentCsv
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $presentMonExe
        $startInfo.Arguments = $arguments
        $startInfo.WorkingDirectory = $OutputRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $script:presentMonProcess = [Diagnostics.Process]::Start($startInfo)
        $script:presentMonStarted = Get-Date
        $script:presentOffset = 0L
        $script:presentHeader = $null
        $script:presentMonState = 'capturing'
        return $true
    } catch {
        $script:lastCollectorError = "PresentMon start: $($_.Exception.Message)"
        $script:presentMonState = 'error'
        return $false
    }
}

function Read-PresentMonFrames {
    $frames = New-Object 'System.Collections.Generic.List[double]'
    if (-not $script:presentCsv -or -not (Test-Path -LiteralPath $script:presentCsv)) { return $frames }
    try {
        $stream = New-Object IO.FileStream($script:presentCsv, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            if ($script:presentOffset -gt $stream.Length) {
                $script:presentOffset = 0L
                $script:presentHeader = $null
            }
            $stream.Position = $script:presentOffset
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 65536, $true)
            try {
                $lineCount = 0
                while (-not $reader.EndOfStream -and $lineCount -lt 20000) {
                    $line = $reader.ReadLine()
                    $lineCount++
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    if ($null -eq $script:presentHeader) {
                        $script:presentHeader = @($line.Split(','))
                        $script:presentFrameIndex = [Array]::IndexOf($script:presentHeader, 'FrameTime')
                        continue
                    }
                    if ($script:presentFrameIndex -lt 0) { continue }
                    $parts = $line.Split(',')
                    if ($parts.Count -le $script:presentFrameIndex) { continue }
                    $frameTime = Convert-Number $parts[$script:presentFrameIndex] 0.01 10000
                    if ($null -ne $frameTime) { $frames.Add([double]$frameTime) }
                }
                $script:presentOffset = $stream.Position
            } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    } catch {
        $script:lastCollectorError = "PresentMon read: $($_.Exception.Message)"
    }
    return $frames
}

function Get-FpsMetrics($Frames) {
    if ($null -eq $Frames -or $Frames.Count -eq 0) {
        return [pscustomobject]@{ Fps = $null; Fps1Low = $null; FrameTime = $null; P95 = $null; P99 = $null }
    }
    $values = [double[]]$Frames.ToArray()
    $average = ($values | Measure-Object -Average).Average
    $p95 = Get-Percentile $values 95
    $p99 = Get-Percentile $values 99
    return [pscustomobject]@{
        Fps = Convert-Number (1000.0 / [Math]::Max(0.01, $average)) 0 1000
        Fps1Low = Convert-Number (1000.0 / [Math]::Max(0.01, $p99)) 0 1000
        FrameTime = Convert-Number $average 0 10000
        P95 = Convert-Number $p95 0 10000
        P99 = Convert-Number $p99 0 10000
    }
}

function New-MinuteAccumulator([long]$BucketStart) {
    $values = @{}
    foreach ($name in $metricNames) { $values[$name] = New-Object 'System.Collections.Generic.List[double]' }
    return [pscustomobject]@{ BucketStart = $BucketStart; SampleCount = 0; Values = $values }
}

function Add-MinuteSample($Accumulator, $Sample) {
    $Accumulator.SampleCount++
    foreach ($name in $metricNames) {
        $value = $Sample[$name]
        if ($null -ne $value) { $Accumulator.Values[$name].Add([double]$value) }
    }
}

function Complete-Minute($Accumulator) {
    $metrics = [ordered]@{}
    foreach ($name in $metricNames) {
        $values = $Accumulator.Values[$name]
        if ($values.Count -eq 0) { continue }
        $measure = $values | Measure-Object -Average -Minimum -Maximum
        $metrics[$name] = [Math]::Round([double]$measure.Average, 3)
        if ($name -match 'Pct$|TempC$|PowerW$|Mbps$|RamMb$|UsedGb$') {
            $metrics["${name}Max"] = [Math]::Round([double]$measure.Maximum, 3)
        }
        if ($name -eq 'fps') { $metrics['fpsMin'] = [Math]::Round([double]$measure.Minimum, 3) }
        if ($name -eq 'diskFreeGb') { $metrics['diskFreeGbMin'] = [Math]::Round([double]$measure.Minimum, 3) }
    }
    return [ordered]@{
        bucketStart = $Accumulator.BucketStart
        sampleCount = $Accumulator.SampleCount
        metrics = $metrics
    }
}

function Append-Minute($Minute) {
    $json = $Minute | ConvertTo-Json -Depth 6 -Compress
    [IO.File]::AppendAllText($minutesPath, $json + "`n", $utf8)
    $script:minuteHistory.Add($Minute)
    while ($script:minuteHistory.Count -gt 60) { $script:minuteHistory.RemoveAt(0) }
}

function Load-MinuteHistory {
    if (-not (Test-Path -LiteralPath $minutesPath)) { return }
    try {
        foreach ($line in @(Get-Content -LiteralPath $minutesPath -Tail 60 -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $script:minuteHistory.Add(($line | ConvertFrom-Json))
        }
    } catch {}
}

function Prune-LocalTelemetry {
    $cutoff = [DateTimeOffset]::UtcNow.AddHours(-24).ToUnixTimeMilliseconds()
    try {
        $kept = New-Object 'System.Collections.Generic.List[string]'
        if (Test-Path -LiteralPath $minutesPath) {
            foreach ($line in [IO.File]::ReadLines($minutesPath)) {
                try {
                    $row = $line | ConvertFrom-Json
                    if ([long]$row.bucketStart -ge $cutoff) { $kept.Add($line) }
                } catch {}
            }
            Write-AtomicUtf8 $minutesPath (($kept -join "`n") + $(if ($kept.Count) { "`n" } else { '' }))
        }
        Get-ChildItem -LiteralPath $OutputRoot -Filter 'raw_*.ndjson' -File -ErrorAction SilentlyContinue |
            Where-Object LastWriteTime -lt (Get-Date).AddHours(-26) |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $OutputRoot -Filter 'presentmon_*.csv' -File -ErrorAction SilentlyContinue |
            Where-Object LastWriteTime -lt (Get-Date).AddHours(-2) |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        $script:lastCollectorError = "local retention: $($_.Exception.Message)"
    }
}

$rootHash = [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash(
    [Text.Encoding]::UTF8.GetBytes($OutputRoot.ToLowerInvariant()))).Replace('-', '').Substring(0, 20)
$mutex = New-Object Threading.Mutex($false, "Local\WutheringPerformanceTelemetry_$rootHash")
$hasMutex = $false
$presentMonProcess = $null
$presentMonState = 'starting'
$presentMonStarted = Get-Date
$presentCsv = ''
$presentOffset = 0L
$presentHeader = $null
$presentFrameIndex = -1
$lastCollectorError = ''
$lastPresentAttempt = [DateTime]::MinValue
$previousProcessCpu = @{}
$logicalProcessors = [Environment]::ProcessorCount
$minuteHistory = New-Object 'System.Collections.Generic.List[object]'
$minuteAccumulator = $null
$lastSampleAt = Get-Date
$extended = @{}
$lastExtendedAt = [DateTime]::MinValue
$lastNvidiaAt = [DateTime]::MinValue
$nvidia = @{}
$nvidiaSmi = Find-NvidiaSmi
$lastPruneAt = [DateTime]::MinValue

try {
    try { $hasMutex = $mutex.WaitOne([TimeSpan]::FromSeconds(20)) } catch [Threading.AbandonedMutexException] { $hasMutex = $true }
    if (-not $hasMutex) { exit 0 }
    Load-MinuteHistory

    while ($true) {
        if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
        if (Test-Path -LiteralPath $stopPath) { break }

        $sampleStarted = Get-Date
        $nowMs = Get-UnixMilliseconds
        $elapsedSeconds = [Math]::Max(0.25, ($sampleStarted - $lastSampleAt).TotalSeconds)
        $lastSampleAt = $sampleStarted
        $bucketStart = [long]([Math]::Floor($nowMs / 60000) * 60000)
        if ($null -eq $minuteAccumulator) { $minuteAccumulator = New-MinuteAccumulator $bucketStart }
        elseif ($minuteAccumulator.BucketStart -ne $bucketStart) {
            Append-Minute (Complete-Minute $minuteAccumulator)
            $minuteAccumulator = New-MinuteAccumulator $bucketStart
        }

        $game = Get-ProcessSnapshot 'Client-Win64-Shipping'
        $okww = Get-ProcessSnapshot 'OK-WW'
        $lrmc = Get-ProcessSnapshot 'LRMCAI'
        $ffmpeg = Get-ProcessSnapshot 'ffmpeg'
        if ($game.Count -gt 0) {
            if ($presentMonProcess -and $presentMonProcess.HasExited) {
                try { $lastCollectorError = "PresentMon exited: $($presentMonProcess.ExitCode)" } catch {}
                $presentMonState = 'retry_wait'
                $presentMonProcess = $null
            }
            $needsStart = $null -eq $presentMonProcess -or $presentMonProcess.HasExited
            $needsRotate = -not $needsStart -and (($sampleStarted - $presentMonStarted).TotalMinutes -ge 60)
            if (($needsStart -or $needsRotate) -and ($sampleStarted - $lastPresentAttempt).TotalMinutes -ge 1) {
                $lastPresentAttempt = $sampleStarted
                [void](Start-PresentMon)
            }
        } else {
            if ($presentMonProcess) { Stop-PresentMon }
            $presentMonState = 'waiting_game'
        }

        $fps = Get-FpsMetrics (Read-PresentMonFrames)

        if (($sampleStarted - $lastExtendedAt).TotalSeconds -ge 4) {
            $lastExtendedAt = $sampleStarted
            try {
                $cpuRow = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
                $extended.cpuTotalPct = Convert-Number $cpuRow.PercentProcessorTime 0 100
            } catch {}
            try {
                $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
                $extended.ramTotalGb = Convert-Number ([double]$os.TotalVisibleMemorySize / 1MB) 0 10000
                $extended.ramUsedGb = Convert-Number (([double]$os.TotalVisibleMemorySize - [double]$os.FreePhysicalMemory) / 1MB) 0 10000
            } catch {}
            try {
                $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop
                $extended.diskReadMbps = Convert-Number ([double]$disk.DiskReadBytesPersec * 8 / 1MB) 0 100000
                $extended.diskWriteMbps = Convert-Number ([double]$disk.DiskWriteBytesPersec * 8 / 1MB) 0 100000
            } catch {}
            try {
                $interfaces = @(Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop)
                $extended.networkDownMbps = Convert-Number ((($interfaces | Measure-Object BytesReceivedPersec -Sum).Sum) * 8 / 1MB) 0 100000
                $extended.networkUpMbps = Convert-Number ((($interfaces | Measure-Object BytesSentPersec -Sum).Sum) * 8 / 1MB) 0 100000
            } catch {}
            try {
                $gpuRows = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop)
                $extended.gpuPct = Convert-Number (($gpuRows | Measure-Object UtilizationPercentage -Maximum).Maximum) 0 100
            } catch {}
            try {
                $gpuMemory = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory -ErrorAction Stop)
                $extended.gpuVramMb = Convert-Number ((($gpuMemory | Measure-Object DedicatedUsage -Sum).Sum) / 1MB) 0 1000000
            } catch {}
        }
        if (($sampleStarted - $lastNvidiaAt).TotalSeconds -ge 10 -and $nvidiaSmi) {
            $lastNvidiaAt = $sampleStarted
            try {
                $lines = @(& $nvidiaSmi '--query-gpu=utilization.gpu,memory.used,temperature.gpu,power.draw,utilization.encoder' '--format=csv,noheader,nounits' 2>$null)
                $rows = foreach ($line in $lines) {
                    $parts = @($line.Split(',') | ForEach-Object { $_.Trim() })
                    if ($parts.Count -ge 5) { [pscustomobject]@{ gpu=$parts[0]; mem=$parts[1]; temp=$parts[2]; power=$parts[3]; encoder=$parts[4] } }
                }
                if ($rows) {
                    $nvidia.gpuPct = Convert-Number (($rows | ForEach-Object { Convert-Number $_.gpu 0 100 } | Measure-Object -Maximum).Maximum) 0 100
                    $nvidia.gpuVramMb = Convert-Number (($rows | ForEach-Object { Convert-Number $_.mem 0 1000000 } | Measure-Object -Sum).Sum) 0 1000000
                    $nvidia.gpuTempC = Convert-Number (($rows | ForEach-Object { Convert-Number $_.temp 0 200 } | Measure-Object -Maximum).Maximum) 0 200
                    $nvidia.gpuPowerW = Convert-Number (($rows | ForEach-Object { Convert-Number $_.power 0 5000 } | Measure-Object -Sum).Sum) 0 5000
                    $nvidia.gpuEncoderPct = Convert-Number (($rows | ForEach-Object { Convert-Number $_.encoder 0 100 } | Measure-Object -Maximum).Maximum) 0 100
                }
            } catch { $nvidiaSmi = '' }
        }
        if (-not $extended.diskFreeGb -or (($sampleStarted.Minute % 1) -eq 0 -and $sampleStarted.Second -lt 5)) {
            try {
                $drive = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f ([IO.Path]::GetPathRoot($OutputRoot).TrimEnd('\'))) -ErrorAction Stop
                $extended.diskFreeGb = Convert-Number ([double]$drive.FreeSpace / 1GB) 0 1000000
            } catch {}
        }

        $recordingProgress = Read-FfmpegProgress 'recording'
        $liveProgress = Read-FfmpegProgress 'live'
        $sample = [ordered]@{
            at = $nowMs
            fps = $fps.Fps; fps1Low = $fps.Fps1Low; frameTimeMs = $fps.FrameTime
            frameTimeP95Ms = $fps.P95; frameTimeP99Ms = $fps.P99
            cpuTotalPct = $extended.cpuTotalPct
            cpuGamePct = Get-ProcessCpuPercent 'game' $game $elapsedSeconds $logicalProcessors
            cpuOkwwPct = Get-ProcessCpuPercent 'okww' $okww $elapsedSeconds $logicalProcessors
            cpuLrmcPct = Get-ProcessCpuPercent 'lrmc' $lrmc $elapsedSeconds $logicalProcessors
            cpuFfmpegPct = Get-ProcessCpuPercent 'ffmpeg' $ffmpeg $elapsedSeconds $logicalProcessors
            gpuPct = $(if ($null -ne $nvidia.gpuPct) { $nvidia.gpuPct } else { $extended.gpuPct })
            gpuVramMb = $(if ($null -ne $nvidia.gpuVramMb) { $nvidia.gpuVramMb } else { $extended.gpuVramMb })
            gpuTempC = $nvidia.gpuTempC; gpuPowerW = $nvidia.gpuPowerW; gpuEncoderPct = $nvidia.gpuEncoderPct
            ramUsedGb = $extended.ramUsedGb; ramTotalGb = $extended.ramTotalGb
            gameRamMb = Convert-Number ([double]$game.WorkingSet / 1MB) 0 1000000
            okwwRamMb = Convert-Number ([double]$okww.WorkingSet / 1MB) 0 1000000
            lrmcRamMb = Convert-Number ([double]$lrmc.WorkingSet / 1MB) 0 1000000
            ffmpegRamMb = Convert-Number ([double]$ffmpeg.WorkingSet / 1MB) 0 1000000
            diskReadMbps = $extended.diskReadMbps; diskWriteMbps = $extended.diskWriteMbps; diskFreeGb = $extended.diskFreeGb
            networkDownMbps = $extended.networkDownMbps; networkUpMbps = $extended.networkUpMbps
            recordingActive = [bool]$recordingProgress.Active; recordingFps = $recordingProgress.Fps
            recordingDroppedFrames = $recordingProgress.Dropped; recordingDuplicatedFrames = $recordingProgress.Duplicated
            recordingSpeed = $recordingProgress.Speed
            liveActive = [bool]$liveProgress.Active; liveFps = $liveProgress.Fps
            liveDroppedFrames = $liveProgress.Dropped; liveDuplicatedFrames = $liveProgress.Duplicated
            liveSpeed = $liveProgress.Speed
            gameRunning = $game.Count -gt 0; okwwRunning = $okww.Count -gt 0; lrmcRunning = $lrmc.Count -gt 0
            ffmpegCount = $ffmpeg.Count
        }
        Add-MinuteSample $minuteAccumulator $sample

        $rawPath = Join-Path $OutputRoot ("raw_{0:yyyyMMdd}.ndjson" -f (Get-Date))
        [IO.File]::AppendAllText($rawPath, (($sample | ConvertTo-Json -Depth 5 -Compress) + "`n"), $utf8)
        $collector = [ordered]@{
            state = 'running'; version = 1; updatedAt = $nowMs; sampleIntervalSec = $SampleIntervalSeconds
            presentMon = $presentMonState; presentMonVersion = $presentMonVersion
            fpsAvailable = $null -ne $fps.Fps
            nvidiaTelemetry = [bool]$nvidiaSmi
            error = [string]$lastCollectorError
        }
        $historyArray = @($minuteHistory.ToArray())
        $heartbeatMinutes = if ($historyArray.Count -gt 10) {
            @($historyArray[($historyArray.Count - 10)..($historyArray.Count - 1)])
        } else {
            $historyArray
        }
        $heartbeat = [ordered]@{ collector = $collector; current = $sample; minutes = $heartbeatMinutes }
        Write-AtomicUtf8 $heartbeatPath ($heartbeat | ConvertTo-Json -Depth 8 -Compress)

        # 公司版 GitHub Pages 只能讀 Firestore。這裡另外產生一份有界的
        # 60 分鐘精簡資料，AHK 會把它併入既有 90 秒心跳；不新增 Firestore
        # 文件、寫入次數、listener 或輪詢計時器。
        $compactPoints = @(
            foreach ($minute in $historyArray) {
                $metrics = $minute.metrics
                [ordered]@{
                    at = [long]$minute.bucketStart
                    fps = $metrics.fps; fps1Low = $metrics.fps1Low
                    frameTimeMs = $metrics.frameTimeMs; frameTimeP95Ms = $metrics.frameTimeP95Ms
                    cpuTotalPct = $metrics.cpuTotalPct; gpuPct = $metrics.gpuPct
                    gpuEncoderPct = $metrics.gpuEncoderPct
                    diskWriteMbps = $metrics.diskWriteMbps; networkUpMbps = $metrics.networkUpMbps
                }
            }
        )
        $compactCurrent = [ordered]@{
            at = $sample.at
            fps = $sample.fps; fps1Low = $sample.fps1Low
            frameTimeMs = $sample.frameTimeMs; frameTimeP95Ms = $sample.frameTimeP95Ms
            cpuTotalPct = $sample.cpuTotalPct; cpuGamePct = $sample.cpuGamePct
            gpuPct = $sample.gpuPct; gpuEncoderPct = $sample.gpuEncoderPct
            ramUsedGb = $sample.ramUsedGb; ramTotalGb = $sample.ramTotalGb
            gameRamMb = $sample.gameRamMb; gpuVramMb = $sample.gpuVramMb
            gpuTempC = $sample.gpuTempC; gpuPowerW = $sample.gpuPowerW
            diskWriteMbps = $sample.diskWriteMbps; diskFreeGb = $sample.diskFreeGb
            networkUpMbps = $sample.networkUpMbps
            recordingActive = $sample.recordingActive; recordingFps = $sample.recordingFps
            liveActive = $sample.liveActive; liveFps = $sample.liveFps
        }
        $firestore = [ordered]@{
            schemaVersion = 1
            collector = $collector
            current = $compactCurrent
            points = $compactPoints
        }
        Write-AtomicUtf8 $firestorePath ($firestore | ConvertTo-Json -Depth 7 -Compress)
        $lastCollectorError = ''

        if (($sampleStarted - $lastPruneAt).TotalHours -ge 1) {
            $lastPruneAt = $sampleStarted
            Prune-LocalTelemetry
        }
        $elapsedWork = ((Get-Date) - $sampleStarted).TotalMilliseconds
        $sleepMs = [Math]::Max(250, $SampleIntervalSeconds * 1000 - [int]$elapsedWork)
        Start-Sleep -Milliseconds $sleepMs
    }
} catch {
    $lastCollectorError = $_.Exception.Message
    try {
        [IO.File]::WriteAllText((Join-Path $OutputRoot 'collector_error.log'),
            ($_ | Out-String), $utf8)
    } catch {}
    try {
        $failed = [ordered]@{
            collector = [ordered]@{ state='error'; version=1; updatedAt=(Get-UnixMilliseconds); error=$lastCollectorError }
            current = $null; minutes = $minuteHistory.ToArray()
        }
        Write-AtomicUtf8 $heartbeatPath ($failed | ConvertTo-Json -Depth 8 -Compress)
        $failedFirestore = [ordered]@{
            schemaVersion = 1
            collector = $failed.collector
            current = $null
            points = @($minuteHistory.ToArray() | ForEach-Object {
                [ordered]@{ at = [long]$_.bucketStart; fps = $_.metrics.fps; fps1Low = $_.metrics.fps1Low }
            })
        }
        Write-AtomicUtf8 $firestorePath ($failedFirestore | ConvertTo-Json -Depth 7 -Compress)
    } catch {}
} finally {
    Stop-PresentMon
    Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
    if ($hasMutex) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
}
