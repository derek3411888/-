using System.Runtime.Versioning;

// Opt into the installed .NET Framework's OS-selected TLS defaults. Do not
// enable legacy TLS, bypass certificate validation or change machine policy.
[assembly: TargetFramework(".NETFramework,Version=v4.8", FrameworkDisplayName=".NET Framework 4.8")]
