#!/usr/bin/env bash

# This script adds internal feeds required to build commits that depend on internal package sources. For instance,
# dotnet6-internal would be added automatically if dotnet6 was found in the nuget.config file. In addition also enables
# disabled internal Maestro (darc-int*) feeds.
# 
# Optionally, this script also adds a credential entry for each of the internal feeds if supplied. This credential
# is added via the standard environment variable VSS_NUGET_EXTERNAL_FEED_ENDPOINTS. See
# https://github.com/microsoft/artifacts-credprovider/tree/v1.1.1?tab=readme-ov-file#environment-variables for more details
#
# See example call for this script below.
#
#  - task: Bash@3
#    displayName: Setup Private Feeds Credentials
#    inputs:
#      filePath: $(Build.SourcesDirectory)/eng/common/SetupNugetSources.sh
#      arguments: $(Build.SourcesDirectory)/NuGet.config
#    condition: ne(variables['Agent.OS'], 'Windows_NT')
#
# This logic is also abstracted into enable-internal-sources.yml.

ConfigFile=$1
CredToken=$2
NL='\n'
TB='    '

source="${BASH_SOURCE[0]}"

# resolve $source until the file is no longer a symlink
while [[ -h "$source" ]]; do
  scriptroot="$( cd -P "$( dirname "$source" )" && pwd )"
  source="$(readlink "$source")"
  # if $source was a relative symlink, we need to resolve it relative to the path where the
  # symlink file was located
  [[ $source != /* ]] && source="$scriptroot/$source"
done
scriptroot="$( cd -P "$( dirname "$source" )" && pwd )"

. "$scriptroot/tools.sh"

if [ ! -f "$ConfigFile" ]; then
    Write-PipelineTelemetryError -Category 'Build' "Error: eng/common/SetupNugetSources.sh returned a non-zero exit code. Couldn't find the NuGet config file: $ConfigFile"
    ExitWithExitCode 1
fi

if [[ `uname -s` == "Darwin" ]]; then
    NL=$'\\\n'
    TB=''
fi

# If the credential is non-empty and the VSS_NUGET_EXTERNAL_FEED_ENDPOINTS is set, suggest that the user
# use the powershell version instead or reorder their calls to start with an empty VSS_NUGET_EXTERNAL_FEED_ENDPOINTS.
# This avoids complicated editing of JSON strings in bash.
if [ "$CredToken" && -n "${VSS_NUGET_EXTERNAL_FEED_ENDPOINTS:-}" ]; then
    Write-PipelineTelemetryError -Category 'Build' "Error: eng/common/SetupNugetSources.sh does not support setting credentials when VSS_NUGET_EXTERNAL_FEED_ENDPOINTS is set. Please use the powershell version of this script instead."
    ExitWithExitCode 1
fi

# Ensure there is a <packageSources>...</packageSources> section.
grep -i "<packageSources>" $ConfigFile
if [ "$?" != "0" ]; then
    echo "Adding <packageSources>...</packageSources> section."
    ConfigNodeHeader="<configuration>"
    PackageSourcesTemplate="${TB}<packageSources>${NL}${TB}</packageSources>"

    sed -i.bak "s|$ConfigNodeHeader|$ConfigNodeHeader${NL}$PackageSourcesTemplate|" $ConfigFile
fi

PackageEndpoints=()
EndpointCredentials="["

if 

DotNetVersions=('3.1', '5' '6' '7' '8')

for DotNetVersion in ${DotNetVersions[@]} ; do
    FeedPrefix="dotnet${DotNetVersion}";
    grep -i "<add key=\"$FeedPrefix\"" $ConfigFile
    if [ "$?" == "0" ]; then
        grep -i "<add key=\"$FeedPrefix-internal\"" $ConfigFile
        if [ "$?" != "0" ]; then
            echo "Adding $FeedPrefix-internal to the packageSources."
            PackageSourcesNodeFooter="</packageSources>"
            PackageEndpoint=""
            if [ "${DotNetVersion}" == "3.1" ]; then
                PackageEndpoint="https://pkgs.dev.azure.com/dnceng/_packaging/$FeedPrefix-internal/nuget/v3/index.json"
            else
                PackageEndpoint="https://pkgs.dev.azure.com/dnceng/internal/_packaging/$FeedPrefix-internal/nuget/v3/index.json"
            fi

            PackageSourceTemplate="${TB}<add key=\"$FeedPrefix-internal\" value=\"$PackageEndpoint\" />"

            sed -i.bak "s|$PackageSourcesNodeFooter|$PackageSourceTemplate${NL}$PackageSourcesNodeFooter|" $ConfigFile
        fi
        PackageEndpoints+=("$PackageEndpoint")

        grep -i "<add key=\"$FeedPrefix-internal-transport\">" $ConfigFile
        if [ "$?" != "0" ]; then
            echo "Adding $FeedPrefix-internal-transport to the packageSources."
            PackageSourcesNodeFooter="</packageSources>"
            PackageEndpoint=""
            if [ "${DotNetVersion}" == "3.1" ]; then
                PackageEndpoint="https://pkgs.dev.azure.com/dnceng/_packaging/$FeedPrefix-internal/nuget/v3/index.json"
            else
                PackageEndpoint="https://pkgs.dev.azure.com/dnceng/internal/_packaging/$FeedPrefix-internal/nuget/v3/index.json"
            fi
            PackageSourceTemplate="${TB}<add key=\"$FeedPrefix-internal\" value=\"$PackageEndpoint\" />"

            sed -i.bak "s|$PackageSourcesNodeFooter|$PackageSourceTemplate${NL}$PackageSourcesNodeFooter|" $ConfigFile
        fi
        PackageEndpoints+=("$PackageEndpoint")
    fi
done

# I want things split line by line
PrevIFS=$IFS
IFS=$'\n'
PackageEndpoints+="$IFS"
PackageEndpoints+=$(grep -oh '"(https://pkgs.dev.azure.com/dnceng/|https://devdiv.pkgs.visualstudio.com/)internal/_packaging/darc-int-[^"]*"' $ConfigFile | tr -d '"')
IFS=$PrevIFS

if [ "$CredToken" && ${#PackageEndpoints[@]} -gt 0 ]; then
    echo "Adding credentials for the following internal feeds: ${PackageEndpoints[@]}"
    for FeedName in ${PackageEndpoints[@]} ; do
        EndpointCredentials += "{\"endpoint\":\"$FeedName\",\"password\":\"$CredToken\"},"
    done

    EndpointCredentials += "]"
    PackageSourceCredentials="{\"endpointCredentials\":$EndpointCredentials}"
    ci=true
    Write-PipelineSetVariable -name 'VSS_NUGET_EXTERNAL_FEED_ENDPOINTS' -value "$PackageSourceCredentials"
fi

# Re-enable any entries in disabledPackageSources where the feed name contains darc-int
grep -i "<disabledPackageSources>" $ConfigFile
if [ "$?" == "0" ]; then
    DisabledDarcIntSources=()
    echo "Re-enabling any disabled \"darc-int\" package sources in $ConfigFile"
    DisabledDarcIntSources+=$(grep -oh '"darc-int-[^"]*" value="true"' $ConfigFile  | tr -d '"')
    for DisabledSourceName in ${DisabledDarcIntSources[@]} ; do
        if [[ $DisabledSourceName == darc-int* ]]
            then
                OldDisableValue="<add key=\"$DisabledSourceName\" value=\"true\" />"
                NewDisableValue="<!-- Reenabled for build : $DisabledSourceName -->"
                sed -i.bak "s|$OldDisableValue|$NewDisableValue|" $ConfigFile
                echo "Neutralized disablePackageSources entry for '$DisabledSourceName'"
        fi
    done
fi
