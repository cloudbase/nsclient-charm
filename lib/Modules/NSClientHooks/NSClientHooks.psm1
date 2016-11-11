# Copyright 2016 Cloudbase Solutions Srl
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

Import-Module OpenStackCommon
Import-Module JujuHooks
Import-Module powershell-yaml
Import-Module JujuWindowsUtils
Import-Module JujuLogging
Import-Module JujuUtils
Import-Module JujuHelper


function Get-CharmServices {
    return @{
        "nsclient" = @{
            "template" = "nsclient.ini"
            "service" = "nscp"
            "config" = Join-Path $NSCLIENT_INSTALL_DIR "nsclient.ini"
            "service_bin_path" = "`"$NSCLIENT_INSTALL_DIR\nscp.exe`" service --run"
            "context_generators" = @(
                @{
                    "generator" = (Get-Item "function:Get-CharmConfigContext").ScriptBlock
                    "relation" = "config"
                }
            )
        }
    }
}

function Get-NsclientAllowedHosts {
    $nagiosHosts = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")

    $rids = Get-JujuRelationIds -Relation 'monitors'
    foreach($rid in $rids) {
        $units = Get-JujuRelatedUnits -RelationId $rid
        foreach($unit in $units) {
            $remoteHost = Get-JujuRelation -RelationId $rid -Unit $unit -Attribute 'private-address'
            $nagiosHosts.Add($remoteHost)
        }
    }

    $cfg = Get-JujuCharmConfig
    $configHosts = $cfg['allowed-hosts'].Split(',').Trim()
    foreach($configHost in $configHosts) {
        if($configHost -notin $nagiosHosts) {
            $nagiosHosts.Add($configHost)
        }
    }

    return ,$nagiosHosts
}

function Get-CharmConfigContext {
    $ctxt = Get-ConfigContext

    $ctxt['nsclient_allowed_hosts'] = (Get-NsclientAllowedHosts) -Join ','

    return $ctxt
}

function Get-NSClientInstaller {
    $installerUrl = Get-JujuCharmConfig -Scope 'installer-url'
    if(!$installerUrl) {
        # Use default installer
        $installerType = 'msi'
        if(Get-IsNanoServer) {
            $installerType = 'zip'
        }
        try {
            Write-JujuWarning "Trying to get installer Juju resource"
            $installerPath = Get-JujuResource -Resource "nsclient-${installerType}-installer"
            return $installerPath
        } catch {
            Write-JujuWarning "Failed downloading nsclient installer resource: $_"
            Write-JujuWarning "Falling back to file download"
        }
        $installerUrl = $NSCLIENT_DEFAULT_INSTALLER_URLS[$installerType]
    }

    $uri = [Uri]$installerUrl
    $outFile = $uri.PathAndQuery.Substring($uri.PathAndQuery.LastIndexOf("/") + 1)

    Write-JujuLog "Downloading NSClient installer"

    $installerPath = Join-Path $env:TEMP $outFile
    Start-ExecuteWithRetry {
        Invoke-FastWebRequest -Uri $installerUrl -OutFile $installerPath | Out-Null
    } -RetryMessage "Downloading installer failed. Retrying..."

    return $installerPath
}

function Set-RelationMonitors {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Relation
    )

    $defaultMonitors = @{
        'version' = '0.3'
        'monitors' = @{
            'remote' = @{
                'nrpe' = @{
                    'check_cpu' = @{
                        'command' = 'alias_cpu'
                    }
                    'check_mem' = @{
                        'command' = 'alias_mem'
                    }
                    'check_disk' = @{
                        'command' = 'alias_disk'
                    }
                }
            }
        }
    }

    $rids = Get-JujuRelationIds -Relation $Relation
    foreach($rid in $rids) {
        $units = Get-JujuRelatedUnits -RelationId $rid
        foreach ($unit in $units) {
            $monitors = $defaultMonitors
            $relMonitorsYaml = Get-JujuRelation -Attribute 'monitors' -RelationId $rid -Unit $unit
            if ($relMonitorsYaml) {
                # Get extra monitors from the relation
                $relMonitors = Get-UnmarshaledObject $relMonitorsYaml
                try {
                    $relationMonitors = $relMonitors['monitors']['remote']['nrpe']
                    foreach($key in $relationMonitors.Keys) {
                        $monitors['monitors']['remote']['nrpe'][$key] = $relationMonitors[$key]
                    }
                } catch {
                    Write-JujuWarning "No nrpe monitors has been set in 'local-monitors' relation"
                }
            }

            $configMonitorsYaml = Get-JujuCharmConfig -Scope 'monitors'
            if($configMonitorsYaml) {
                # Get extra monitors declared in config for this target machine
                $cfgMons = ConvertFrom-Yaml -Yaml "$configMonitorsYaml" -AllDocuments
                try {
                    $configMonitors = $cfgMons['monitors']['remote']['nrpe']
                    foreach($key in $configMonitors.Keys) {
                        $monitors['monitors']['remote']['nrpe'][$key] = $configMonitors[$key]
                    }
                } catch {
                    Write-JujuWarning "No monitors has been set in config.yaml or the yaml format is incorrect"
                }
            }

            $monitorsYaml = ConvertTo-Yaml $monitors
            $address = Get-JujuUnitPrivateIP
            $unitSplit = $unit.split('/')
            $targetId = "{0}-{1}" -f @($unitSplit[0], $unitSplit[1])
            $settings = @{
                'charm_platform' = 'windows'
                'monitors' = $monitorsYaml
                'target-address'= $address
                'target-id' = $targetId
            }

            $rids = Get-JujuRelationIds -Relation 'monitors'
            foreach ($rid in $rids) {
                Set-JujuRelation -RelationId $rid -Settings $settings
            }
        }
    }
}

function Install-NSClient {
    $installerPath = Get-NSClientInstaller

    if($installerPath.EndsWith(".msi")) {
        $extraArgs = @("CONF_CAN_CHANGE=`"TRUE`"",
                       "ALLOWED_HOSTS=`"127.0.0.1`"",
                       "CONF_CHECKS=`"TRUE`"")
        $logFile = Join-Path $env:APPDATA "nsclient-log.txt"
        Write-JujuLog "Installing NSClient++"
        Install-Msi -Installer $installerPath -LogFilePath $logFile -ExtraArgs $extraArgs

    } elseif($installerPath.EndsWith(".zip")) {
        if(Test-Path $NSCLIENT_INSTALL_DIR) {
            Remove-Item -Recurse -Force $NSCLIENT_INSTALL_DIR
        }
        Expand-ZipArchive -ZipFile $installerPath -Destination $NSCLIENT_INSTALL_DIR

    } else {
        Throw "Unsupported installer format"
    }

    Remove-Item $installerPath
}

function Start-InstallHook {
    Install-NSClient

    $services = Get-CharmServices
    $nscpAgent = Get-Service $services["nsclient"]["service"] -ErrorAction SilentlyContinue
    if(!$nscpAgent) {
        New-Service -Name $services["nsclient"]["service"] `
                    -BinaryPathName $services["nsclient"]["service_bin_path"] `
                    -DisplayName "NSClient++" -Description "NSClient++" -Confirm:$false
    }
    Get-Service -Name $services["nsclient"]["service"]
    Set-Service -Name $services["nsclient"]["service"] -StartupType Automatic
}

function Start-ConfigChangedHook {
    $charmServices = Get-CharmServices
    $incompleteRelations = New-ConfigFile -ContextGenerators $charmServices['nsclient']['context_generators'] `
                                          -Template $charmServices['nsclient']['template'] `
                                          -OutFile $charmServices['nsclient']['config']

    if(!$incompleteRelations.Count) {
        Write-JujuLog "Restarting NSClient++ service"

        Restart-Service $charmServices['nsclient']['service']

        $firewallRuleName = "NSClient++ NRPE"
        $rule = Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue
        if($rule) {
            Remove-NetFirewallRule -Name $firewallRuleName
        }

        $nrpePort = Get-JujuCharmConfig -Scope 'nrpe-port'
        New-NetFirewallRule -Name $firewallRuleName -DisplayName $firewallRuleName `
                            -Enabled True -Profile Any -Direction Inbound `
                            -Action Allow -Protocol TCP -LocalPort $nrpePort -Confirm:$false

        Set-JujuStatus -Status active -Message "Unit is ready"
    } else {
        $msg = "Incomplete relations: {0}" -f @($incompleteRelations -join ', ')
        Set-JujuStatus -Status blocked -Message $msg
    }
}

function Start-StartHook {
    $charmServices = Get-CharmServices
    Start-Service $charmServices['nsclient']['service']
}

function Start-StopHook {
    $charmServices = Get-CharmServices
    Stop-Service $charmServices['nsclient']['service']
}
