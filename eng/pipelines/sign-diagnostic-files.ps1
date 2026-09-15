[CmdletBinding()]
param(
    [string]
    [Parameter(Mandatory)]
    $certList,
    [string]
    [Parameter(Mandatory)]
    $esrpClient,
    [string]
    [Parameter(Mandatory)]
    $artifactsPath
)

# Required for the pipeline logging functions
$ci = $true
. $PSScriptRoot/../common/pipeline-logging-functions.ps1

Write-Host "Installing diagnostic certificates for signing..."

$certs = $certList -split ','
$thumbprints = @()
$certCollection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
foreach ($cert in $certs)
{
    $certBytes = [System.Convert]::FromBase64String($(Get-Item "Env:$cert").Value)
    $certCollection.Import($certBytes,$null, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet)
}

foreach ($cert in $certCollection)
{
    Write-Host "Installed certificate '$($cert.Thumbprint)' with subject: '$($cert.Subject)'"
    $thumbprints += $cert.Thumbprint
}

$store = Get-Item -Path Cert:\CurrentUser\My
$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
$store.AddRange($certCollection)
$store.Close()

Write-Host "Successfully installed diagnostic certificates"

try {
    # Find all diagnostic files that need to be signed
    $filesToSign = @()
    
    # Find mscordaccore.dll files
    $mscordacFiles = Get-ChildItem -Path $artifactsPath -Filter "mscordaccore.dll" -Recurse -ErrorAction SilentlyContinue
    foreach ($file in $mscordacFiles) {
        $filesToSign += $file.FullName
    }
    
    # Find mscordbi.dll files
    $mscordbiFiles = Get-ChildItem -Path $artifactsPath -Filter "mscordbi.dll" -Recurse -ErrorAction SilentlyContinue
    foreach ($file in $mscordbiFiles) {
        $filesToSign += $file.FullName
    }
    
    if ($filesToSign.Count -eq 0) {
        Write-Host "No diagnostic files found to sign"
    }
    else {
        Write-Host "Found $($filesToSign.Count) diagnostic files to sign:"
        foreach ($file in $filesToSign) {
            Write-Host "  $file"
        }
        
        # Sign the files
        & "$PSScriptRoot/../native/sign-with-dac-certificate.ps1" -esrpClient $esrpClient $filesToSign
        
        Write-Host "Successfully signed all diagnostic files"
    }
}
finally {
    # Always clean up certificates
    Write-Host "Removing diagnostic certificates..."
    $store = Get-Item -Path Cert:\CurrentUser\My
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    foreach ($thumbprint in $thumbprints)
    {
        $cert = $store.Certificates.Find([System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint, $thumbprint, $false)
        if ($null -eq $cert)
        {
            Write-Host "Certificate with thumbprint '$thumbprint' not found in the user store."
        }
        $store.RemoveRange($cert)
        Write-Host "Removed certificate '$thumbprint'"
    }
    $store.Close()
    Write-Host "Successfully removed diagnostic certificates"
}
