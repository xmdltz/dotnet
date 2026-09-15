<#
.PARAMETER ArchiveRunName
Name of the run for vs logs

.NOTES
Returns 0 if succeeds, 1 otherwise
#>
[CmdletBinding(PositionalBinding=$false)]
Param (
  [Parameter(Mandatory=$True)]
  [string] $ArchiveRunName
)

. $PSScriptRoot/common/tools.ps1

$ProgressPreference = "SilentlyContinue"
$LogDir = Join-Path $LogDir $ArchiveRunName
mkdir $LogDir

$vscollect_uri="https://aka.ms/vscollect.exe"
$vscollect="$env:TEMP\vscollect.exe"

if (-not (Test-Path $vscollect)) {
    Retry({
        Write-Host "GET $vscollect_uri"
        Invoke-WebRequest $vscollect_uri -OutFile $vscollect -UseBasicParsing
    })

    if (-not (Test-Path $vscollect)) {
        Write-PipelineTelemetryError -Category 'InitializeToolset' -Message "Unable to download vscollect."
        exit 1
    }

    # Verify Authenticode signature to ensure the executable is from Microsoft
    $signature = Get-AuthenticodeSignature $vscollect
    if ($signature.Status -ne 'Valid') {
        Write-PipelineTelemetryError -Category 'InitializeToolset' -Message "Downloaded vscollect.exe has invalid signature. Status: $($signature.Status)"
        Remove-Item $vscollect -Force -ErrorAction SilentlyContinue
        exit 1
    }

    # Verify the signer is Microsoft
    $signerCert = $signature.SignerCertificate
    if ($null -eq $signerCert) {
        Write-PipelineTelemetryError -Category 'InitializeToolset' -Message "Downloaded vscollect.exe does not contain a valid signature certificate."
        Remove-Item $vscollect -Force -ErrorAction SilentlyContinue
        exit 1
    }

    # Check that the certificate subject contains Microsoft Corporation
    if ($signerCert.Subject -notmatch 'O=Microsoft Corporation') {
        Write-PipelineTelemetryError -Category 'InitializeToolset' -Message "Downloaded vscollect.exe is not signed by Microsoft Corporation. Subject: $($signerCert.Subject)"
        Remove-Item $vscollect -Force -ErrorAction SilentlyContinue
        exit 1
    }

    Write-Host "vscollect.exe signature verified successfully. Signer: $($signerCert.Subject)"
}

&"$vscollect"
Move-Item $env:TEMP\vslogs.zip "$LogDir"

$vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -Path "$vswhere" -PathType Leaf))
{
    Write-Error "Couldn't locate vswhere at $vswhere"
    exit 1
}

&"$vswhere" -all -prerelease -products * |  Tee-Object -FilePath "$LogDir\vs_where.log"

$vsdir = &"$vswhere" -latest -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath

if (-not (Test-Path $vsdir))
{
    $procDumpDir = Join-Path $ToolsDir "procdump"
    $procDumpToolPath = Join-Path $procDumpDir "procdump.exe"
    $procdump_uri = "https://download.sysinternals.com/files/Procdump.zip"

    if (-not (Test-Path $procDumpToolPath)) {
        Retry({
            Write-Host "GET $procdump_uri"
            Invoke-WebRequest $procdump_uri -OutFile "$TempDir\Procdump.zip" -UseBasicParsing
        })

        Expand-Archive -Path "$TempDir\Procdump.zip" $procDumpDir

        # Verify Authenticode signature to ensure the executable is from Microsoft
        $signature = Get-AuthenticodeSignature $procDumpToolPath
        if ($signature.Status -ne 'Valid') {
            Write-PipelineTelemetryError -Category 'InitializeToolset' -Message "Downloaded procdump.exe has invalid signature. Status: $($signature.Status)"
            Remove-Item $procDumpDir -Recurse -Force -ErrorAction SilentlyContinue
            exit 1
        }

        # Verify the signer is Microsoft
        $signerCert = $signature.SignerCertificate
        if ($null -eq $signerCert) {
            Write-PipelineTelemetryError -Category 'InitializeToolset' -Message "Downloaded procdump.exe does not contain a valid signature certificate."
            Remove-Item $procDumpDir -Recurse -Force -ErrorAction SilentlyContinue
            exit 1
        }

        # Check that the certificate subject contains Microsoft Corporation
        if ($signerCert.Subject -notmatch 'O=Microsoft Corporation') {
            Write-PipelineTelemetryError -Category 'InitializeToolset' -Message "Downloaded procdump.exe is not signed by Microsoft Corporation. Subject: $($signerCert.Subject)"
            Remove-Item $procDumpDir -Recurse -Force -ErrorAction SilentlyContinue
            exit 1
        }

        Write-Host "procdump.exe signature verified successfully. Signer: $($signerCert.Subject)"
    }

    &"$procDumpToolPath" -ma -accepteula VSIXAutoUpdate.exe "$LogDir"
}
