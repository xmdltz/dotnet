param(
  [Parameter(Mandatory=$true)][string] $Operation,
  [string] $AuthToken,
  [string] $CommitSha,
  [string] $RepoName,
  [switch] $IsFeedPrivate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. $PSScriptRoot\tools.ps1

# Sets VSS_NUGET_EXTERNAL_FEED_ENDPOINTS based on the "darc-int-*" feeds defined in NuGet.config. This is needed
# in build agents by CredProvider to authenticate the restore requests to internal feeds as specified in
# https://github.com/microsoft/artifacts-credprovider/blob/0f53327cd12fd893d8627d7b08a2171bf5852a41/README.md#environment-variables. This should ONLY be called from identified
# internal builds
function SetupCredProvider {
  param(
    [string] $AuthToken
  )    

  # Install the Cred Provider NuGet plugin
  Write-Host 'Setting up Cred Provider NuGet plugin in the agent...'
  Write-Host "Getting 'installcredprovider.ps1' from 'https://github.com/microsoft/artifacts-credprovider'..."

  # Pin to a specific commit to prevent execution of arbitrary code from a mutable branch
  # Using version tag v1.0.2 which is a stable release
  # 
  # IMPORTANT: The hash below is a placeholder and MUST be replaced with the actual SHA256 hash
  # of the installcredprovider.ps1 file at the pinned version before this script will work.
  # 
  # To update to a newer version:
  # 1. Choose a version tag or commit SHA from https://github.com/microsoft/artifacts-credprovider/releases
  # 2. Download: Invoke-WebRequest "https://raw.githubusercontent.com/microsoft/artifacts-credprovider/v1.0.2/helpers/installcredprovider.ps1" -OutFile test.ps1
  # 3. Compute hash: (Get-FileHash -Path test.ps1 -Algorithm SHA256).Hash
  # 4. Update both the $commit and $expectedHash values below
  $commit = 'v1.0.2'
  $url = "https://raw.githubusercontent.com/microsoft/artifacts-credprovider/$commit/helpers/installcredprovider.ps1"
  # Expected SHA256 hash of the installcredprovider.ps1 file at v1.0.2
  # TODO: Replace this placeholder with the actual hash computed from the file at the pinned version
  $expectedHash = 'PLACEHOLDER_HASH_MUST_BE_REPLACED_WITH_ACTUAL_SHA256_HASH_OF_FILE'
  
  Write-Host "Downloading 'installcredprovider.ps1' from pinned commit $commit..."
  $installScriptPath = Join-Path $PWD 'installcredprovider.ps1'
  
  try {
    Invoke-WebRequest $url -OutFile $installScriptPath
    
    # Verify the hash of the downloaded file to ensure integrity
    Write-Host 'Verifying integrity of downloaded installer...'
    $actualHash = (Get-FileHash -Path $installScriptPath -Algorithm SHA256).Hash
    
    if ($actualHash -ne $expectedHash) {
      Write-PipelineTelemetryError -Category 'Security' -Message "Hash verification failed for installcredprovider.ps1. Expected: $expectedHash, Actual: $actualHash. The file may have been tampered with."
      Remove-Item $installScriptPath -ErrorAction SilentlyContinue
      ExitWithExitCode 1
    }
    
    Write-Host 'Hash verification successful. Installing plugin...'
    # Use & instead of dot-sourcing to isolate the script from the current scope and prevent
    # access to sensitive variables like $AuthToken
    & $installScriptPath -Force
  }
  finally {
    Write-Host "Deleting local copy of 'installcredprovider.ps1'..."
    if (Test-Path $installScriptPath) {
      Remove-Item $installScriptPath
    }
  }

  if (-Not("$env:USERPROFILE\.nuget\plugins\netcore")) {
    Write-PipelineTelemetryError -Category 'Arcade' -Message 'CredProvider plugin was not installed correctly!'
    ExitWithExitCode 1  
  } 
  else {
    Write-Host 'CredProvider plugin was installed correctly!'
  }

  # Then, we set the 'VSS_NUGET_EXTERNAL_FEED_ENDPOINTS' environment variable to restore from the stable 
  # feeds successfully

  $nugetConfigPath = Join-Path $RepoRoot "NuGet.config"

  if (-Not (Test-Path -Path $nugetConfigPath)) {
    Write-PipelineTelemetryError -Category 'Build' -Message 'NuGet.config file not found in repo root!'
    ExitWithExitCode 1
  }
  
  $endpoints = New-Object System.Collections.ArrayList
  $nugetConfigPackageSources = Select-Xml -Path $nugetConfigPath -XPath "//packageSources/add[contains(@key, 'darc-int-')]/@value" | foreach{$_.Node.Value}
  
  if (($nugetConfigPackageSources | Measure-Object).Count -gt 0 ) {
    foreach ($stableRestoreResource in $nugetConfigPackageSources) {
      $trimmedResource = ([string]$stableRestoreResource).Trim()
      [void]$endpoints.Add(@{endpoint="$trimmedResource"; password="$AuthToken"}) 
    }
  }

  if (($endpoints | Measure-Object).Count -gt 0) {
      $endpointCredentials = @{endpointCredentials=$endpoints} | ConvertTo-Json -Compress

     # Create the environment variables the AzDo way
      Write-LoggingCommand -Area 'task' -Event 'setvariable' -Data $endpointCredentials -Properties @{
        'variable' = 'VSS_NUGET_EXTERNAL_FEED_ENDPOINTS'
        'issecret' = 'false'
      } 

      # We don't want sessions cached since we will be updating the endpoints quite frequently
      Write-LoggingCommand -Area 'task' -Event 'setvariable' -Data 'False' -Properties @{
        'variable' = 'NUGET_CREDENTIALPROVIDER_SESSIONTOKENCACHE_ENABLED'
        'issecret' = 'false'
      } 
  }
  else
  {
    Write-Host 'No internal endpoints found in NuGet.config'
  }
}

#Workaround for https://github.com/microsoft/msbuild/issues/4430
function InstallDotNetSdkAndRestoreArcade {
  $dotnetTempDir = Join-Path $RepoRoot "dotnet"
  $dotnetSdkVersion="2.1.507" # After experimentation we know this version works when restoring the SDK (compared to 3.0.*)
  $dotnet = "$dotnetTempDir\dotnet.exe"
  $restoreProjPath = "$PSScriptRoot\restore.proj"
  
  Write-Host "Installing dotnet SDK version $dotnetSdkVersion to restore Arcade SDK..."
  InstallDotNetSdk "$dotnetTempDir" "$dotnetSdkVersion"
  
  '<Project Sdk="Microsoft.DotNet.Arcade.Sdk"/>' | Out-File "$restoreProjPath"

  & $dotnet restore $restoreProjPath

  Write-Host 'Arcade SDK restored!'

  if (Test-Path -Path $restoreProjPath) {
    Remove-Item $restoreProjPath
  }

  if (Test-Path -Path $dotnetTempDir) {
    Remove-Item $dotnetTempDir -Recurse
  }
}

try {
  Push-Location $PSScriptRoot

  if ($Operation -like 'setup') {
    SetupCredProvider $AuthToken
  } 
  elseif ($Operation -like 'install-restore') {
    InstallDotNetSdkAndRestoreArcade
  }
  else {
    Write-PipelineTelemetryError -Category 'Arcade' -Message "Unknown operation '$Operation'!"
    ExitWithExitCode 1  
  }
} 
catch {
  Write-Host $_.ScriptStackTrace
  Write-PipelineTelemetryError -Category 'Arcade' -Message $_
  ExitWithExitCode 1
} 
finally {
  Pop-Location
}
