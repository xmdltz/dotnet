<#
.SYNOPSIS
    Verifies that Microsoft NuGet packages have proper metadata.
.DESCRIPTION
    Downloads a verification tool and runs metadata validation on the provided NuGet packages. This script writes an
    error if any of the provided packages fail validation. All arguments provided to this PowerShell script that do not
    match PowerShell parameters are passed on to the verification tool downloaded during the execution of this script.
.PARAMETER NuGetExePath
    The path to the nuget.exe binary to use. If not provided, nuget.exe will be downloaded into the -DownloadPath
    directory.
.PARAMETER PackageSource
    The package source to use to download the verification tool. If not provided, nuget.org will be used.
.PARAMETER DownloadPath
    The directory path to download the verification tool and nuget.exe to. If not provided,
    %TEMP%\NuGet.VerifyNuGetPackage will be used.
.PARAMETER PackageVersion
    The specific version of NuGet.VerifyMicrosoftPackage to download. If not provided, version 1.1.0 will be used.
    This parameter ensures a known, trusted version is used rather than allowing arbitrary prerelease versions.
.PARAMETER ExpectedPackageHash
    Optional SHA256 hash of the expected package file for additional verification.
.PARAMETER args
    Arguments that will be passed to the verification tool.
.EXAMPLE
    PS> .\verify.ps1 *.nupkg
    Verifies the metadata of all .nupkg files in the currect working directory.
.EXAMPLE
    PS> .\verify.ps1 --help
    Displays the help text of the downloaded verifiction tool.
.LINK
    https://github.com/NuGet/NuGetGallery/blob/master/src/VerifyMicrosoftPackage/README.md
#>

# This script was copied from https://github.com/NuGet/NuGetGallery/blob/3e25ad135146676bcab0050a516939d9958bfa5d/src/VerifyMicrosoftPackage/verify.ps1
# and modified to pin a specific package version and add signature verification for supply chain security.

[CmdletBinding(PositionalBinding = $false)]
param(
   [string]$NuGetExePath,
   [string]$PackageSource = "https://api.nuget.org/v3/index.json",
   [string]$DownloadPath,
   [string]$PackageVersion = "1.1.0",
   [string]$ExpectedPackageHash,
   [Parameter(ValueFromRemainingArguments = $true)]
   [string[]]$args
)

# The URL to download nuget.exe.
$nugetExeUrl = "https://dist.nuget.org/win-x86-commandline/v4.9.4/nuget.exe"

# The package ID of the verification tool.
$packageId = "NuGet.VerifyMicrosoftPackage"

# The location that nuget.exe and the verification tool will be downloaded to.
if (!$DownloadPath) {
    $DownloadPath = (Join-Path $env:TEMP "NuGet.VerifyMicrosoftPackage")
}

$fence = New-Object -TypeName string -ArgumentList '=', 80

# Create the download directory, if it doesn't already exist.
if (!(Test-Path $DownloadPath)) {
    New-Item -ItemType Directory $DownloadPath | Out-Null
}
Write-Host "Using download path: $DownloadPath"

if ($NuGetExePath) {
    $nuget = $NuGetExePath
} else {
    $downloadedNuGetExe = Join-Path $DownloadPath "nuget.exe"
    
    # Download nuget.exe, if it doesn't already exist.
    if (!(Test-Path $downloadedNuGetExe)) {
        Write-Host "Downloading nuget.exe from $nugetExeUrl..."
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest $nugetExeUrl -OutFile $downloadedNuGetExe
            $ProgressPreference = 'Continue'
        } catch {
            $ProgressPreference = 'Continue'
            Write-Error $_
            Write-Error "nuget.exe failed to download."
            exit
        }
    }

    $nuget = $downloadedNuGetExe
}

Write-Host "Using nuget.exe path: $nuget"
Write-Host " "

# Download the specified version of the verification tool.
Write-Host "Downloading version $PackageVersion of $packageId from $packageSource..."
Write-Host $fence
& $nuget install $packageId `
    -Version $PackageVersion `
    -OutputDirectory $DownloadPath `
    -Source $PackageSource
Write-Host $fence
Write-Host " "

if ($LASTEXITCODE -ne 0) {
    Write-Error "nuget.exe failed to fetch the verify tool."
    exit
}

# Verify package signature if downloading from public feed
if ($PackageSource -eq "https://api.nuget.org/v3/index.json") {
    Write-Host "Verifying package signature..."
    $packagePath = Join-Path $DownloadPath "$packageId.$PackageVersion"
    $nupkgFile = Join-Path $packagePath "$packageId.$PackageVersion.nupkg"
    
    if (Test-Path $nupkgFile) {
        & $nuget verify -Signatures $nupkgFile
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Package signature verification failed. The package may have been tampered with."
            exit 1
        }
        Write-Host "Package signature verification succeeded."
    }
}

# Optionally verify package hash if provided
if ($ExpectedPackageHash) {
    Write-Host "Verifying package hash..."
    $packagePath = Join-Path $DownloadPath "$packageId.$PackageVersion"
    $nupkgFile = Join-Path $packagePath "$packageId.$PackageVersion.nupkg"
    
    if (Test-Path $nupkgFile) {
        $actualHash = (Get-FileHash -Path $nupkgFile -Algorithm SHA256).Hash
        if ($actualHash -ne $ExpectedPackageHash) {
            Write-Error "Package hash verification failed. Expected: $ExpectedPackageHash, Actual: $actualHash"
            exit 1
        }
        Write-Host "Package hash verification succeeded."
    }
}

# Locate the downloaded tool
Write-Host "Locating the verification tool."
$verifyPath = Join-Path $DownloadPath "$packageId.$PackageVersion"
$verify = Join-Path $verifyPath "tools\NuGet.VerifyMicrosoftPackage.exe"
Write-Host "Using verification tool: $verify"
Write-Host " "

# Execute the verification tool.
Write-Host "Executing the verify tool..."
Write-Host $fence
& $verify $args
Write-Host $fence
Write-Host " "

# Respond to the exit code.
if ($LASTEXITCODE -ne 0) {
    Write-Error "The verify tool found some problems."
} else {
    Write-Output "The verify tool succeeded."
}
