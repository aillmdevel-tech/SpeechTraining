param([string]$OutputDirectory = "")

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-Location (Join-Path $PSScriptRoot "..")
if (!$OutputDirectory) { $OutputDirectory = Join-Path (Get-Location) "dist" }
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path
$build = Join-Path ([System.IO.Path]::GetTempPath()) ("SpeechTraining-" + [Guid]::NewGuid())
$app = Join-Path $build "SpeechTraining"

try {
    dotnet publish windows/SpeechTraining.csproj -c Release -r win-x64 --self-contained true -o $app
    $assets = Get-Content windows/obj/project.assets.json -Raw | ConvertFrom-Json -AsHashtable
    $notices = Join-Path $app "Notices"
    New-Item -ItemType Directory -Force $notices | Out-Null
    foreach ($library in $assets.libraries.Values) {
        if ($library.path -notmatch '^microsoft\.(netcore|windowsdesktop)\.app\.runtime\.win-x64/') { continue }
        foreach ($packageRoot in $assets.packageFolders.Keys) {
            $package = Join-Path $packageRoot $library.path
            if (!(Test-Path $package)) { continue }
            foreach ($name in @("LICENSE.TXT", "THIRD-PARTY-NOTICES.TXT")) {
                $notice = Join-Path $package $name
                if (Test-Path $notice) { Copy-Item $notice (Join-Path $notices "$($library.path.Split('/')[0])-$name") }
            }
            break
        }
    }
    $env:CGO_ENABLED = "0"
    $env:GOOS = "windows"
    $env:GOARCH = "amd64"
    Push-Location gateway
    try {
        go build -trimpath -ldflags "-s -w" -o (Join-Path $app "speech-gateway.exe") .
    } finally {
        Pop-Location
    }

    $test = Start-Process -FilePath (Join-Path $app "SpeechTraining.exe") -ArgumentList "--self-test" -PassThru -Wait
    if ($test.ExitCode -ne 0) { throw "Windows self-test failed with exit code $($test.ExitCode)." }

    $archive = Join-Path $OutputDirectory "SpeechTraining-windows-x64.zip"
    Compress-Archive -LiteralPath $app -DestinationPath $archive -Force
} finally {
    if (Test-Path $build) { Remove-Item $build -Recurse -Force }
}
