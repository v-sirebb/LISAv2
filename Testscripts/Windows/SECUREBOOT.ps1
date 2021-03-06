# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
<#
.Synopsis
    This script tests Secure Boot features.
.Description
    This script will test Secure Boot features on a Generation 2 VM.
    It also test the feature after performing a Live Migration of the VM or
    after a kernel update.
#>
param([String] $TestParams)
$ErrorActionPreference = "Stop"
function Enable-VMMigration([String] $vmName)
{
    #
    # Load the cluster commandlet module
    #
    Import-module FailoverClusters
    if (-not $?) {
        LogErr "Unable to load FailoverClusters module"
        return $False
    }
    #
    # Have migration networks been configured?
    #
    $migrationNetworks = Get-ClusterNetwork
    if (-not $migrationNetworks) {
        LogErr "$vmName - There are no Live Migration Networks configured"
        return $False
    }
    LogMsg "Get the VMs current node"
    $vmResource =  Get-ClusterResource | where-object {$_.OwnerGroup.name -eq "$vmName" -and $_.ResourceType.Name -eq "Virtual Machine"}
    if (-not $vmResource) {
        LogErr "$vmName - Unable to find cluster resource for current node"
        return $False
    }
    $currentNode = $vmResource.OwnerNode.Name
    if (-not $currentNode) {
        LogErr "$vmName - Unable to set currentNode"
        return $False
    }
    #
    # Get nodes the VM can be migrated to
    #
    $clusterNodes = Get-ClusterNode
    if (-not $clusterNodes -and $clusterNodes -isnot [array]) {
        LogErr "$vmName - There is only one cluster node in the cluster."
        return $False
    }
    #
    # For the initial implementation, just pick a node that does not
    # match the current VMs node
    #
    $destinationNode = $clusterNodes[0].Name.ToLower()
    if ($currentNode -eq $clusterNodes[0].Name.ToLower()) {
        $destinationNode = $clusterNodes[1].Name.ToLower()
    }
    if (-not $destinationNode) {
        LogErr "$vmName - Unable to set destination node"
        return $False
    }
    LogMsg "Migrating VM $vmName from $currentNode to $destinationNode"
    $sts = Move-ClusterVirtualMachineRole -name $vmName -node $destinationNode
    if (-not $sts) {
        LogErr "$vmName - Unable to move the VM"
        return $False
    }
    #
    # Check if Secure Boot is enabled
    #
    $firmwareSettings = Get-VMFirmware -VMName $vmName
    if ($firmwareSettings.SecureBoot -ne "On") {
        LogErr "Secure boot settings changed"
        return $False
    }
    $sts = Move-ClusterVirtualMachineRole -name $vmName -node $currentNode
    if (-not $sts) {
        LogErr "$vmName - Unable to move the VM"
        return $False
    }
    return $True
}
##########################################################################
#
# Main script body
#
##########################################################################
function Main {
    param (
        $TestParams
    )
    try {
        $testResult = $null
        $captureVMData = $allVMData
        $VMName = $captureVMData.RoleName
        $HvServer= $captureVMData.HyperVhost
        $Ipv4 = $captureVMData.PublicIP
        $VMPort= $captureVMData.SSHPort
        # Change the working directory to where we need to be
        Set-Location $WorkingDirectory
        #
        # Check heartbeat
        #
        $heartbeat = Get-VMIntegrationService -VMName $VMName -Name "HeartBeat"
        if ($heartbeat.Enabled) {
            LogMsg "$VMName heartbeat detected"
        }
        else {
            throw "$VMName heartbeat not detected"
        }
        #
        # Waiting for the VM to run again and respond to SSH - port 22
        #
        $timeout = 500
        while ($timeout -gt 0) {
            if ( (Test-TCP $Ipv4 $VMPort) -eq "True" ) {
                break
            }
            Start-Sleep -seconds 2
            $timeout -= 2
        }
        if ($timeout -eq 0) {
            throw "Test case timed out waiting for VM to boot"
        }
        LogMsg "SSH port opened"
        if ($TestParams.Migrate) {
            $migrateResult= Enable-VMMigration $VMName
            if (-not $migrateResult) {
                $testResult = $resultFail
                throw "Migration failed"
            }
            #
            # Check if Secure boot settings are in place after migration
            #
            $firmwareSettings = Get-VMFirmware -VMName $VMName
            if ($firmwareSettings.SecureBoot -ne "On") {
                $testResult = $resultFail
                throw "Secure boot settings changed"
            }
            #
            # Waiting for the VM to run again and respond to SSH - port 22
            #
            $timeout = 500
            while ($timeout -gt 0) {
                if ( (Test-TCP $Ipv4 $VMPort) -eq "True" ) {
                    break
                }
                Start-Sleep -seconds 2
                $timeout -= 2
            }
            if ($timeout -eq 0) {
                throw "Test case timed out waiting for VM to boot"
            }
            LogMsg "SSH port opened"

        }
        if ($TestParams.updateKernel) {
            # Getting kernel version before upgrade
            $kernel_beforeupgrade=RunLinuxCmd -username $user -password $password -ip $Ipv4 -port $VMPort -command "uname -a" -runAsSudo
            # Upgrading kernel to latest
            $Upgradecheck = "echo '${password}' | sudo -S -s eval `"export HOME=``pwd``;. utils.sh && UtilsInit && Update_Kernel`""
            RunLinuxCmd -username $user -password $password -ip $Ipv4 -port $VMPort -command $Upgradecheck -runAsSudo
            LogMsg "Shutdown VM ${VMName}"
            Stop-VM -ComputerName $HvServer -Name $VMName -Confirm:$false
            if (-not $?) {
                throw "Unable to Shut Down VM"
            }
            $timeout = 180
            $sts = Wait-ForVMToStop $VMName $HvServer $timeout
            if (-not $sts) {
                throw "WaitForVMToStop fail"
            }
            LogMsg "Starting VM ${VMName}"
            Start-VM -Name $VMName -ComputerName $HvServer -ErrorAction SilentlyContinue
            if (-not $?) {
                throw "unable to start the VM"
            }
            $sleepPeriod = 5 # seconds
            Start-Sleep -s $sleepPeriod
            #
            # Check heartbeat
            #
            $heartbeat = Get-VMIntegrationService -VMName $VMName -Name "HeartBeat"
            if ($heartbeat.Enabled) {
                LogMsg "$VMName heartbeat detected"
            }
            else {
                throw "$VMName heartbeat not detected"
            }
            #
            # Waiting for the VM to run again and respond to SSH - port 22
            #
            $timeout = 500
            $retval = Wait-ForVMToStartSSH -Ipv4addr $Ipv4 -StepTimeout $timeout
            if ($retval -eq $False) {
                throw "Error: Test case timed out waiting for VM to boot"
            }
            LogMsg "SSH port opened"
            # Getting kernel version after upgrade
            $kernel_afterupgrade=RunLinuxCmd -username $user -password $password -ip $Ipv4 -port $VMPort -command "uname -a" -runAsSudo
            # check whether kernel has upgraded to latest version
            if (-not (Compare-Object $kernel_afterupgrade $kernel_beforeupgrade)) {
                $testResult = $resultFail
                throw "Update_Kernel failed"
            }
            LogMsg "Success: Updated kerenl"
        }
        if( $testResult -ne $resultFail) {
            $testResult=$resultPass
        }
    } catch {
        $ErrorMessage =  $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        LogErr "$ErrorMessage at line: $ErrorLine"
    } finally {
        if (!$testResult) {
            $testResult = $resultAborted
        }
        $resultArr += $testResult
    }
    $currentTestResult.TestResult = GetFinalResultHeader -resultarr $resultArr
    return $currentTestResult.TestResult
}
Main -TestParams (ConvertFrom-StringData $TestParams.Replace(";","`n"))
