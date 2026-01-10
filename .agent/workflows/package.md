---
description: Package Flux module as a Magisk-compatible ZIP
---

# Package Flux Module

This workflow packages the Flux module into a Magisk/KernelSU/APatch compatible ZIP file.

## Prerequisites
- Ensure all code changes are complete and tested
- PowerShell available

## Steps

### 1. Convert all shell scripts to LF line endings
// turbo
```powershell
$files = Get-ChildItem -Path "d:\Github\Flux" -Recurse -Include *.sh,flux.config,flux.logger,flux.core,flux.tproxy,flux.mod.inotify,flux.net.inotify,settings.ini
foreach ($file in $files) {
    $content = [System.IO.File]::ReadAllText($file.FullName)
    $content = $content -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($file.FullName, $content, [System.Text.Encoding]::UTF8)
    Write-Host "Converted: $($file.Name)"
}
```

### 2. Create the ZIP package (with correct Unix paths)
// turbo
```powershell
$projectDir = "d:\Github\Flux"

# Get version from module.prop
$propContent = Get-Content "$projectDir\module.prop" -Raw
if ($propContent -match 'version=(v[\d.]+)') {
    $version = $matches[1]
} else {
    $version = "v0.0.0"
}

$outputZip = "$projectDir\Flux-$version.zip"
Write-Host "Packaging Flux $version..."

# Remove old zip if exists
if (Test-Path $outputZip) { Remove-Item $outputZip -Force }

# Items to include
$itemsToInclude = @(
    "bin",
    "conf", 
    "META-INF",
    "scripts",
    "tools",
    "webroot",
    "customize.sh",
    "module.prop",
    "service.sh"
)

# Use .NET ZipFile to create ZIP with forward slashes
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$zipStream = [System.IO.File]::Create($outputZip)
$archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)

function Add-ToZip {
    param($archive, $sourcePath, $entryName)
    
    # Convert to forward slashes for Unix compatibility
    $entryName = $entryName -replace '\\', '/'
    
    if (Test-Path $sourcePath -PathType Container) {
        # Directory - add all files recursively
        Get-ChildItem -Path $sourcePath -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring($sourcePath.Length + 1)
            $zipEntryName = "$entryName/$relativePath" -replace '\\', '/'
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $zipEntryName) | Out-Null
        }
        Write-Host "  + $entryName/"
    } else {
        # Single file
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $sourcePath, $entryName) | Out-Null
        Write-Host "  + $entryName"
    }
}

foreach ($item in $itemsToInclude) {
    $source = Join-Path $projectDir $item
    if (Test-Path $source) {
        Add-ToZip -archive $archive -sourcePath $source -entryName $item
    } else {
        Write-Host "  ! $item (not found)"
    }
}

$archive.Dispose()
$zipStream.Dispose()

Write-Host ""
Write-Host "Created: $outputZip"
$size = (Get-Item $outputZip).Length / 1MB
Write-Host ("Size: {0:N2} MB" -f $size)
```

### 3. Verify the package contents
// turbo
```powershell
$projectDir = "d:\Github\Flux"
$propContent = Get-Content "$projectDir\module.prop" -Raw
$version = if ($propContent -match 'version=(v[\d.]+)') { $matches[1] } else { "v0.0.0" }
$zipPath = "$projectDir\Flux-$version.zip"

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
Write-Host "Contents of Flux-$version.zip :"
Write-Host ""
$zip.Entries | Sort-Object FullName | ForEach-Object { 
    if ($_.FullName -match '\\') {
        Write-Host "  [ERROR] $($_.FullName)" -ForegroundColor Red
    } else {
        Write-Host "  $($_.FullName)"
    }
}
$zip.Dispose()
```

## Output
- `Flux-vX.X.X.zip` in the project root directory
- All paths use forward slashes (Unix compatible)
- Ready for flashing via Magisk/KernelSU/APatch Manager
