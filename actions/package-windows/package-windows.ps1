# Packs one Windows x64 binary as an MSI (WiX v5) and a portable zip, signing both when a
# certificate is given. Runs in the app directory; inputs come from the environment (action.yml).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($name in 'APP_ID', 'DISPLAY_NAME', 'BUNDLE_ID', 'VERSION', 'MSI_VERSION', 'BIN', 'BINARY', 'DESCRIPTION',
                  'ICON_PNG', 'PUBLISHER', 'HOMEPAGE', 'UPGRADE_CODE', 'OUT_DIR') {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is not set" }
}

$base = "$($env:APP_ID)-$($env:VERSION)-windows-x64"
$work = Join-Path $env:RUNNER_TEMP 'craft-windows'
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force -Path $work, $env:OUT_DIR | Out-Null
$out = (Resolve-Path $env:OUT_DIR).Path
$appDir = (Get-Location).Path

function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File exited with $LASTEXITCODE" }
}

# ---- code signing (optional) ---------------------------------------------------------------------------
$pfx = $null
$signtool = $null
if ($env:WINDOWS_CERTIFICATE) {
    $pfx = Join-Path $work 'certificate.pfx'
    [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:WINDOWS_CERTIFICATE))
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $signtool = Get-ChildItem -Path $kits -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName | Select-Object -Last 1
    if (-not $signtool) { throw "signtool.exe not found under $kits" }
    $signtool = $signtool.FullName
    Write-Host "signing with $signtool"
} else {
    Write-Host '::notice::WINDOWS_CERTIFICATE is not set: the exe and MSI are unsigned'
}

function Sign-File([string]$Path) {
    if (-not $pfx) { return }
    $sigArgs = @('sign', '/fd', 'SHA256', '/td', 'SHA256', '/tr', 'http://timestamp.digicert.com', '/f', $pfx,
        '/d', $env:DISPLAY_NAME)
    if ($env:WINDOWS_CERTIFICATE_PASSWORD) { $sigArgs += @('/p', $env:WINDOWS_CERTIFICATE_PASSWORD) }
    $sigArgs += $Path
    & $signtool @sigArgs
    if ($LASTEXITCODE -ne 0) { throw "signtool failed on $Path" }
    Invoke-Native $signtool @('verify', '/pa', $Path)
}

try {
    # ---- the program files ------------------------------------------------------------------------------
    $stage = Join-Path $work 'stage'
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $exeName = "$($env:BIN).exe"
    $exe = Join-Path $stage $exeName
    Copy-Item -LiteralPath $env:BINARY -Destination $exe
    Sign-File $exe

    $docs = @()
    foreach ($pattern in 'LICENSE', 'LICENSE-*', 'LICENSE.*', 'COPYING', 'NOTICE', 'NOTICE.*') {
        foreach ($f in Get-ChildItem -Path $appDir -Filter $pattern -File -ErrorAction SilentlyContinue) {
            if ($docs -notcontains $f.Name) {
                Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $stage $f.Name)
                $docs += $f.Name
            }
        }
    }
    if ($docs.Count -eq 0) { Write-Host "::warning::no LICENSE/NOTICE files found in $appDir" }

    # ---- icon -----------------------------------------------------------------------------------------------
    $ico = Join-Path $work 'AppIcon.ico'
    if ($env:ICON_ICO) {
        Copy-Item -LiteralPath $env:ICON_ICO -Destination $ico
    } else {
        # An .ico of PNG-compressed images (Windows Vista and later read these), resized from icon_png.
        Add-Type -AssemblyName System.Drawing
        $src = [System.Drawing.Image]::FromFile((Resolve-Path $env:ICON_PNG).Path)
        $sizes = 16, 24, 32, 48, 64, 128, 256
        $images = foreach ($s in $sizes) {
            $bmp = New-Object System.Drawing.Bitmap $s, $s
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.DrawImage($src, 0, 0, $s, $s)
            $g.Dispose()
            $ms = New-Object IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            , $ms.ToArray()
        }
        $src.Dispose()
        $fs = [IO.File]::Create($ico)
        $w = New-Object IO.BinaryWriter $fs
        $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $s = $sizes[$i]
            $dim = if ($s -ge 256) { 0 } else { $s }
            $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
            $w.Write([uint16]1); $w.Write([uint16]32)
            $w.Write([uint32]$images[$i].Length); $w.Write([uint32]$offset)
            $offset += $images[$i].Length
        }
        foreach ($img in $images) { $w.Write($img) }
        $w.Dispose()
    }

    # ---- portable zip ------------------------------------------------------------------------------------------
    $zip = Join-Path $out "$base-portable.zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal

    # ---- MSI ------------------------------------------------------------------------------------------------------
    function X([string]$s) { [System.Security.SecurityElement]::Escape($s) }
    $files = @("        <Component Id=`"MainExe`"><File Id=`"MainExe`" Source=`"$(X $exe)`" KeyPath=`"yes`" /></Component>")
    $refs = @('      <ComponentRef Id="MainExe" />')
    $n = 0
    foreach ($d in $docs) {
        $n++
        $files += "        <Component Id=`"Doc$n`"><File Id=`"Doc$n`" Source=`"$(X (Join-Path $stage $d))`" KeyPath=`"yes`" /></Component>"
        $refs += "      <ComponentRef Id=`"Doc$n`" />"
    }
    $name = X $env:DISPLAY_NAME
    $publisher = X $env:PUBLISHER
    $wxs = @"
<?xml version="1.0" encoding="utf-8"?>
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="$name" Manufacturer="$publisher" Version="$($env:MSI_VERSION)" UpgradeCode="$($env:UPGRADE_CODE)"
           Language="1033" Scope="perMachine" InstallerVersion="500" Compressed="yes">
    <SummaryInformation Description="$(X $env:DESCRIPTION)" Manufacturer="$publisher" />
    <MajorUpgrade AllowSameVersionUpgrades="yes" DowngradeErrorMessage="A newer version of [ProductName] is already installed." />
    <MediaTemplate EmbedCab="yes" />
    <Icon Id="AppIcon.ico" SourceFile="$(X $ico)" />
    <Property Id="ARPPRODUCTICON" Value="AppIcon.ico" />
    <Property Id="ARPURLINFOABOUT" Value="$(X $env:HOMEPAGE)" />
    <Property Id="ARPCOMMENTS" Value="$(X "$($env:DESCRIPTION) ($($env:BUNDLE_ID) $($env:VERSION))")" />
    <SetProperty Id="ARPINSTALLLOCATION" Value="[INSTALLFOLDER]" After="CostFinalize" />
    <StandardDirectory Id="ProgramFiles64Folder">
      <Directory Id="INSTALLFOLDER" Name="$name">
$($files -join "`n")
      </Directory>
    </StandardDirectory>
    <StandardDirectory Id="ProgramMenuFolder">
      <Component Id="StartMenuShortcut">
        <Shortcut Id="AppShortcut" Name="$name" Description="$(X $env:DESCRIPTION)" Target="[INSTALLFOLDER]$(X $exeName)"
                  WorkingDirectory="INSTALLFOLDER" Icon="AppIcon.ico" />
        <RegistryValue Root="HKMU" Key="Software\$publisher\$name" Name="StartMenuShortcut" Type="integer" Value="1" KeyPath="yes" />
      </Component>
    </StandardDirectory>
    <Feature Id="Main" Title="$name" Level="1">
$($refs -join "`n")
      <ComponentRef Id="StartMenuShortcut" />
    </Feature>
  </Package>
</Wix>
"@
    $wxsPath = Join-Path $work 'app.wxs'
    [IO.File]::WriteAllText($wxsPath, $wxs, (New-Object Text.UTF8Encoding $false))
    Get-Content $wxsPath | Write-Host
    $msi = Join-Path $out "$base.msi"
    Invoke-Native wix @('build', '-arch', 'x64', '-o', $msi, $wxsPath)
    Sign-File $msi

    foreach ($f in $zip, $msi) {
        if (-not (Test-Path $f) -or (Get-Item $f).Length -eq 0) { throw "$f was not produced" }
    }
    # wix leaves its .wixpdb next to the MSI; it is not a release asset.
    Get-ChildItem -Path $out -Filter '*.wixpdb' | Remove-Item -Force
    Get-ChildItem $out | Format-Table Name, Length
} finally {
    if ($pfx -and (Test-Path $pfx)) { Remove-Item -Force $pfx }
}
