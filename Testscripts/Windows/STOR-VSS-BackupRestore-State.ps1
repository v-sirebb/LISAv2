# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
<#
.Synopsis
    This script tests VSS backup functionality.
.Description
    This script will set the vm in Paused, Saved or Off state.
    After that it will perform backup/restore.

    It uses a second partition as target.

    Note: The script has to be run on the host. A second partition
          different from the Hyper-V one has to be available.

#>
param([String] $TestParams)
$ErrorActionPreference = "Stop"

#######################################################################
# Channge the VM state
#######################################################################
function ChangeVMState($vmState,$vmName,$hvServer)
{
    $vm = Get-VM -Name $vmName -ComputerName $hvServer
    if ($vmState -eq "Off") {
        Stop-VM -Name $vmName -ComputerName $hvServer -ErrorAction SilentlyContinue
        return $vm.state
    }
    elseif ($vmState -eq "Saved") {
        Save-VM -Name $vmName -ComputerName $hvServer -ErrorAction SilentlyContinue
        return $vm.state
    }
    elseif ($vmState -eq "Paused") {
        Suspend-VM -Name $vmName -ComputerName $hvServer -ErrorAction SilentlyContinue
        return $vm.state
    }
    else {
        return $false
    }
}
#######################################################################
#
# Main script body
#
#######################################################################
function Main
{
    param (
        $TestParams
    )
    try {
        $testResult = $null
        $captureVMData = $allVMData
        $VMName = $captureVMData.RoleName
        $HvServer= $captureVMData.HyperVhost
        $VMIpv4=$captureVMData.PublicIP
        $VMPort=$captureVMData.SSHPort
        $vmState=$TestParams.vmState
        $HypervGroupName=$captureVMData.HyperVGroupName
        LogMsg "Test VM details :"
        LogMsg "  RoleName : $($captureVMData.RoleName)"
        LogMsg "  Public IP : $($captureVMData.PublicIP)"
        LogMsg "  SSH Port : $($captureVMData.SSHPort)"
        LogMsg "  HostName : $($captureVMData.HyperVhost)"
        LogMsg "vmstate from params  is $vmState"
        # Change the working directory to where we need to be
        Set-Location $WorkingDirectory
        LogMsg "WorkingDirectory"
        $sts = New-BackupSetup $VMName $HvServer
        if (-not $sts[-1]) {
            throw "Failed to create a Backup Setup"
        }
        # Check VSS Demon is running
        $sts = Check-VSSDemon $VMName $HvServer $VMIpv4 $VMPort
        if (-not $sts) {
            throw "VSS Daemon is not running"
        }
        # Create a file on the VM before backup
        RunLinuxCmd -username $user -password $password -ip $VMIpv4 -port $VMPort -command "touch /home/$user/1" -runAsSudo
        if (-not $?) {
            throw "Cannot create test file"
        }
        $driveletter = $global:driveletter
        if ($null -eq $driveletter) {
            LogErr "Backup driveletter is not specified."
        }
        LogMsg "Driveletter is $driveletter"
        # Check if VM is Started
        $vm = Get-VM -Name $VMName
        $currentState=$vm.state
        LogMsg "current vm state is $currentState "
        if ( $currentState -ne "Running" ) {
            LogErr "$vmName is not started."
        }
        # Change the VM state
        $sts = ChangeVMState $vmState $VMName $HvServer
        LogMsg "VM state changed to $vmstate :  $sts"
        if (-not $sts[-1]) {
            throw "vmState param: $vmState is wrong. Available options are `'Off`', `'Saved`'' and `'Paused`'."
        }
        elseif ( $sts -ne $vmState ) {
            throw "Failed to put $vmName in $vmState state $sts."
        }
        LogMsg "State change of $vmName to $vmState : Success."
        $sts = New-Backup $VMName $driveletter $HvServer $VMIpv4 $VMPort
        if (-not $sts[-1]) {
            throw "Could not create a Backup Location"
        }
        else {
            $backupLocation = $sts[-1]
        }
        $sts = Restore-Backup $backupLocation $HypervGroupName $VMName
        if (-not $sts[-1]) {
            throw "Restore backup action failed for $backupLocation"
        }
        $sts = Check-VMStateAndFileStatus $VMName $HvServer $VMIpv4 $VMPort
        if (-not $sts[-1]) {
            throw "Backup evaluation failed"
        }
        Remove-Backup $backupLocation
        if( $testResult -ne $resultFail) {
            $testResult=$resultPass
        }
    }
    catch {
        $ErrorMessage =  $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        LogErr "$ErrorMessage at line: $ErrorLine"
    }
    finally {
        if (!$testResult) {
            $testResult = $resultAborted
        }
        $resultArr += $testResult
    }
    $currentTestResult.TestResult = GetFinalResultHeader -resultarr $resultArr
    return $currentTestResult.TestResult
}
Main -TestParams  (ConvertFrom-StringData $TestParams.Replace(";","`n"))

