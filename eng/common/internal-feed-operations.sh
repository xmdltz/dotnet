#!/usr/bin/env bash

set -e

# Sets VSS_NUGET_EXTERNAL_FEED_ENDPOINTS based on the "darc-int-*" feeds defined in NuGet.config. This is needed
# in build agents by CredProvider to authenticate the restore requests to internal feeds as specified in
# https://github.com/microsoft/artifacts-credprovider/blob/0f53327cd12fd893d8627d7b08a2171bf5852a41/README.md#environment-variables. 
# This should ONLY be called from identified internal builds
function SetupCredProvider {
  local authToken=$1
  
  # Install the Cred Provider NuGet plugin
  echo "Setting up Cred Provider NuGet plugin in the agent..."
  echo "Getting 'installcredprovider.sh' from 'https://github.com/microsoft/artifacts-credprovider'..."

  # Pin to a specific commit to prevent execution of arbitrary code from a mutable branch
  # Using version tag v1.0.2 which is a stable release
  #
  # IMPORTANT: The hash below is a placeholder and MUST be replaced with the actual SHA256 hash
  # of the installcredprovider.sh file at the pinned version before this script will work.
  #
  # To update to a newer version:
  # 1. Choose a version tag or commit SHA from https://github.com/microsoft/artifacts-credprovider/releases
  # 2. Download: curl -sSL "https://raw.githubusercontent.com/microsoft/artifacts-credprovider/v1.0.2/helpers/installcredprovider.sh" > test.sh
  # 3. Compute hash: sha256sum test.sh | awk '{print $1}'
  # 4. Update both the commit and expectedHash values below
  local commit="v1.0.2"
  local url="https://raw.githubusercontent.com/microsoft/artifacts-credprovider/$commit/helpers/installcredprovider.sh"
  # Expected SHA256 hash of the installcredprovider.sh file at v1.0.2
  # TODO: Replace this placeholder with the actual hash computed from the file at the pinned version
  local expectedHash="placeholder_hash_must_be_replaced_with_actual_sha256_hash_of_file"
  
  echo "Downloading 'installcredprovider.sh' from pinned commit $commit..."
  local installcredproviderPath="installcredprovider.sh"
  
  if command -v curl > /dev/null; then
    curl -sSL "$url" > "$installcredproviderPath"
  else   
    wget -q -O "$installcredproviderPath" "$url"
  fi
  
  # Verify the hash of the downloaded file to ensure integrity
  echo "Verifying integrity of downloaded installer..."
  if command -v sha256sum > /dev/null; then
    local actualHash=$(sha256sum "$installcredproviderPath" | awk '{print $1}')
  elif command -v shasum > /dev/null; then
    local actualHash=$(shasum -a 256 "$installcredproviderPath" | awk '{print $1}')
  else
    echo "Error: Neither sha256sum nor shasum found. Cannot verify file integrity."
    rm -f "$installcredproviderPath"
    exit 1
  fi
  
  if [ "$actualHash" != "$expectedHash" ]; then
    Write-PipelineTelemetryError -category 'Security' "Hash verification failed for installcredprovider.sh. Expected: $expectedHash, Actual: $actualHash. The file may have been tampered with."
    rm -f "$installcredproviderPath"
    ExitWithExitCode 1
  fi
  
  echo "Hash verification successful. Installing plugin..."
  # Source the script to install the credential provider
  . "$installcredproviderPath"
  
  echo "Deleting local copy of 'installcredprovider.sh'..."
  rm -f "$installcredproviderPath"

  if [ ! -d "$HOME/.nuget/plugins" ]; then
    Write-PipelineTelemetryError -category 'Build' 'CredProvider plugin was not installed correctly!'
    ExitWithExitCode 1  
  else 
    echo "CredProvider plugin was installed correctly!"
  fi

  # Then, we set the 'VSS_NUGET_EXTERNAL_FEED_ENDPOINTS' environment variable to restore from the stable 
  # feeds successfully

  local nugetConfigPath="{$repo_root}NuGet.config"

  if [ ! "$nugetConfigPath" ]; then
    Write-PipelineTelemetryError -category 'Build' "NuGet.config file not found in repo's root!"
    ExitWithExitCode 1  
  fi
  
  local endpoints='['
  local nugetConfigPackageValues=`cat "$nugetConfigPath" | grep "key=\"darc-int-"`
  local pattern="value=\"(.*)\""

  for value in $nugetConfigPackageValues 
  do
    if [[ $value =~ $pattern ]]; then
      local endpoint="${BASH_REMATCH[1]}"  
      endpoints+="{\"endpoint\": \"$endpoint\", \"password\": \"$authToken\"},"
    fi
  done
  
  endpoints=${endpoints%?}
  endpoints+=']'

  if [ ${#endpoints} -gt 2 ]; then 
      local endpointCredentials="{\"endpointCredentials\": "$endpoints"}"

      echo "##vso[task.setvariable variable=VSS_NUGET_EXTERNAL_FEED_ENDPOINTS]$endpointCredentials"
      echo "##vso[task.setvariable variable=NUGET_CREDENTIALPROVIDER_SESSIONTOKENCACHE_ENABLED]False"
  else
    echo "No internal endpoints found in NuGet.config"
  fi
} 

# Workaround for https://github.com/microsoft/msbuild/issues/4430
function InstallDotNetSdkAndRestoreArcade {
  local dotnetTempDir="$repo_root/dotnet"
  local dotnetSdkVersion="2.1.507" # After experimentation we know this version works when restoring the SDK (compared to 3.0.*)
  local restoreProjPath="$repo_root/eng/common/restore.proj"
  
  echo "Installing dotnet SDK version $dotnetSdkVersion to restore Arcade SDK..."
  echo "<Project Sdk=\"Microsoft.DotNet.Arcade.Sdk\"/>" > "$restoreProjPath"
  
  InstallDotNetSdk "$dotnetTempDir" "$dotnetSdkVersion"

  local res=`$dotnetTempDir/dotnet restore $restoreProjPath`
  echo "Arcade SDK restored!"

  # Cleanup
  if [ "$restoreProjPath" ]; then
    rm "$restoreProjPath"
  fi

  if [ "$dotnetTempDir" ]; then
    rm -r $dotnetTempDir
  fi
}

source="${BASH_SOURCE[0]}"
operation=''
authToken=''
repoName=''

while [[ $# > 0 ]]; do
  opt="$(echo "$1" | tr "[:upper:]" "[:lower:]")"
  case "$opt" in
    --operation)
      operation=$2
      shift
      ;;
    --authtoken)
      authToken=$2
      shift
      ;;
    *)
      echo "Invalid argument: $1"
      usage
      exit 1
      ;;
  esac

  shift
done

while [[ -h "$source" ]]; do
  scriptroot="$( cd -P "$( dirname "$source" )" && pwd )"
  source="$(readlink "$source")"
  # if $source was a relative symlink, we need to resolve it relative to the path where the
  # symlink file was located
  [[ $source != /* ]] && source="$scriptroot/$source"
done
scriptroot="$( cd -P "$( dirname "$source" )" && pwd )"

. "$scriptroot/tools.sh"

if [ "$operation" = "setup" ]; then
  SetupCredProvider $authToken
elif [ "$operation" = "install-restore" ]; then
  InstallDotNetSdkAndRestoreArcade
else
  echo "Unknown operation '$operation'!"
fi
