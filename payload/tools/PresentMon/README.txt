PresentMon is used only for real game FPS and frame-time measurements.

The performance worker downloads the official standalone console binary on
first use and verifies its SHA-256 before execution:

  Version: 2.5.1
  URL: https://github.com/GameTechDev/PresentMon/releases/download/v2.5.1/PresentMon-2.5.1-x64.exe
  SHA-256: 9BEC3083069F58F911E6A512F4806DB51A27BD096103087BC1D05EF54C80A191

The binary is stored in <program folder>\tools\PresentMon\PresentMon.exe so a
payload update does not download it again.  If the download or ETW capture is
unavailable, the automation continues and the website reports FPS as missing.
