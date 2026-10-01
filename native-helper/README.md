# Native maintenance worker

`GameMaintenanceWorker.exe` directly implements the existing maintenance request / INI snapshot protocol using C# 5 and Windows .NET Framework 4.8. It does not host PowerShell or launch a game. `GameMaintenanceHost.ahk` invokes this executable without a script fallback.

Build from a shell in which local development scripts are already permitted; do not change execution policy:

```powershell
& .\native-helper\Build-NativeHelpers.ps1 -OutputDirectory .\.dev-runtime\diagnostics\game-maintenance\native-build
```

Run the native-only suite from the existing permitted development shell:

```powershell
& .\測試\NativeMaintenanceTest.ps1
```

The suite requires an initial and final zero-AHK process count, compiles with warnings as errors, exercises duplicate builds, and runs synthetic notice/install/worker fixtures. `NativeMaintenanceIntegrationTest.ps1` checks the formal invocation/package source contract without executing AHK. The explicit `--official-notice-smoke` mode of the compiled `MaintenanceWorkerTests.exe` tests official HTTPS with a missing-game fixture; it is not part of the deterministic offline suite.

The release build compiles the native executable into the development payload before release tests and ZIP creation. An existing worker binary is atomically replaced; a compile failure retains the previous artifact and fails the build. The legacy PowerShell maintenance modules remain for historical/reference test comparisons, not as a runtime fallback.

Runtime boundaries:

- State must be below `config/game-maintenance`; worker files must share one direct `執行暫存/遊戲更新/<session>` directory in the same installation. Ordinary reparse points are rejected.
- One exclusive per-installation worker file lock; parent lifetime is tied to an open process handle and creation time, not PID alone. Parent death and stop files end the worker.
- Malformed, foreign-session and stale-generation request updates retain the preceding valid request.
- Official HTTPS uses the host OS TLS defaults, normal certificate validation, no redirects, bounded response size, per-request and aggregate fetch budgets, and parent/stop cancellation. Framework targeting follows [Microsoft's TLS guidance](https://learn.microsoft.com/en-us/dotnet/framework/network-programming/tls).
- A running game process is only `game_running`, not proof of login, launcher-update acceptance, or real task progress.
- Filesystem/COM discovery is synchronous, and notice regex parsing does not have a strict aggregate CPU deadline. These inherited limits and hostile concurrent local filesystem replacement are not covered by the current timing/race acceptance.

`LauncherMaintenance.exe` now implements deferred EXE replacement and staged ZIP extraction without PowerShell. It binds the parent's executable image and creation time to a retained handle. Replacement waits for that exact parent to exit and takes the shared startup mutex; extraction takes the shared runtime mutex while the launcher temporarily releases runtime ownership but keeps its startup reservation. Interpreted mode passes the actual interpreter image, not the script path.

ZIP publication validates names, size and CRC32 for every entry before swapping directories. The supported release format is ordinary single-disk ZIP32 (archive below 4 GiB; expanded total at most 8 GiB). A persisted `payload_transaction.txt` and deterministic `payload_previous` directory restore an interrupted publication before retrying. EXE replacement keeps one `.pre_update.bak` and only commits the version after the installed SHA256 matches.

The isolated AHK-host tests exercise the actual maintenance-worker invocation, source-mode extractor, runtime reservation transfer, and pre-dispatch recovery decision. They never launch the formal game or farming script. Launcher pre-update helper cleanup also revalidates creation time, image and complete command line after retaining a process handle; termination uses only that handle, not the inventory PID.

Before payload replacement, the launcher also waits (at most 45 seconds) for exact-path native helpers mapped from that payload to exit. It retains startup/runtime reservations during this wait; unknown identity or timeout preserves the old payload and stops the update. This is wait-only, not a native-process kill policy. PresentMon and the recorder live under the separate `tools` directory and are not payload-swap targets.

## Formal auxiliary runtime

The formal main-script auxiliary paths now have native implementations, built by the same release entry:

- `PerformanceTelemetryWorker.exe`: the existing local sample, heartbeat, Firestore compact snapshot and minute-history contract. The AHK adapter starts the native worker; legacy PowerShell sources remain development parity references, not a runtime fallback.
- `RuntimeUtilities.exe`: SMTP and exact-PID Core Audio. SMTP configuration and content travel over redirected in-memory pipes, never command-line arguments or generated credential files. No matching audio session is an explicit non-success, not permission to select unrelated processes by name.
- `BootstrapAssets.exe`: SHA-256, bounded HTTPS asset download, synchronous validated ZIP extraction and PE-validated atomic asset installation. Auto-managed FFmpeg paths are validated even when persisted as absolute paths; a path/identity cache is invalidated when the file changes. Size/hash validation and flush precede publication, so an incomplete candidate cannot overwrite a previously installed executable. Explicit external FFmpeg paths retain their existing user-configured policy.

`NativeRuntimeWiringTest.ps1` checks the real main-script wrappers, while the three helper suites exercise native behavior and isolated AHK adapters. The retired segmented recording uploader is not invoked by the formal local-single-MKV flow; retained historical files are not deleted by this migration.

SMTP failures return a fixed diagnostic, never remote exception/server text, so even short or encoded credentials echoed by a server cannot leak to logs. The real telemetry adapter integration requires no live game, stages no PresentMon binary, checks advancing host samples with `gameRunning=false` / `waiting_game`, and stops its exact worker; it does not certify live-game FPS. Missing recorder/live speed retains the legacy JSON `null` representation.

Runtime-utility pipe cancellation is not treated as completion: pending connect/write operations retain their pipe, event, OVERLAPPED and request buffers until `GetOverlappedResult` reaches a terminal state. Another operation fails closed while that state is pending. The synthetic delayed-completion fixture and real stalled-child fixture cover this path without contacting an external SMTP service. This follows the [Windows overlapped-I/O completion contract](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-getoverlappedresult).

The main script also retains one process-lifetime ImagePut GDI+ reference before starting logger/timers, preventing reentry into its unload-before-reference-count-update gap. `ImagePutLifetimeTest.ps1` reproduces the unpinned zero-bitmap failure with a synthetic PNG and verifies timer conversions with the pin. It does not capture the desktop or certify an already-running old remote process.

Legacy launcher markers may still reference an approved `launcher_update_*.exe` under Temp or an external config directory. The main compatibility path opens that source read-only with writes/deletion denied, rejects path redirects, stages bounded verified bytes under its application root, hashes with the ordinary contained native helper, and removes only its own staging file. Ordinary native hashing is not broadened to arbitrary outside-root paths.

These changes do not claim that every development or retired compatibility script is PowerShell-free. They remove the reachable script-host dependency from the formal launcher, maintenance, telemetry, mail, audio and asset-bootstrap paths. Acceptance still requires fresh full regression, independent review and, separately, the real new log/online heartbeat/RUN/task-progress evidence. A package or process alone is not live recovery.
