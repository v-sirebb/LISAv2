# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
<#
.Synopsis
    This script tests VSS backup functionality.
.Description
    This script will format and mount connected disk in the VM.
    After that it will proceed with backup/restore operation.
    It uses a second partition as target.
#>

param([String] $TestParams)
$ErrorActionPreference = "Stop"
$remoteScript = "STOR_VSS_StopNetwork.sh"

#######################################################################
#
# Main script body
#
#######################################################################
function Main {
    param (
       $TestParams
    )
    try {
        $testResult = $null
        $captureVMData = $allVMData
        $VMName = $captureVMData.RoleName
        $HvServer= $captureVMData.HyperVhost
        $VMIpv4 = $captureVMData.PublicIP
        $VMPort = $captureVMData.SSHPort
        $HypervGroupName=$captureVMData.HyperVGroupName
        $url = $TestParams.CDISO
        LogMsg "Test VM details :"
        LogMsg "  RoleName : $($captureVMData.RoleName)"
        LogMsg "  Public IP : $($captureVMData.PublicIP)"
        LogMsg "  SSH Port : $($captureVMData.SSHPort)"
        LogMsg "  HostName : $($captureVMData.HyperVhost)"
        # Change the working directory to where we need to be
        Set-Location $WorkingDirectory
        $sts = New-BackupSetup $VMName $HvServer
        if (-not $sts[-1]) {
            throw "Failed to create a backup setup"
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
        LogMsg "runSetup done"
        $driveletter = $global:driveletter
        LogMsg "Driveletter in VSS_BackupRestore_ISO_NoNetwork is $driveletter"
        if ($null -eq $driveletter) {
            throw "Driveletter was not found."
        }
        #
        # Get Hyper-V VHD path
        #
        $obj = Get-WmiObject -ComputerName $HvServer -Namespace "root\virtualization\v2" -Class "MsVM_VirtualSystemManagementServiceSettingData"
        $defaultVhdPath = $obj.DefaultVirtualHardDiskPath
        if (-not $defaultVhdPath) {
            LogErr "Unable to determine VhdDefaultPath on Hyper-V server ${hvServer}"
            $error[0].Exception
            return $False
        }
        if (-not $defaultVhdPath.EndsWith("\")) {
            $defaultVhdPath += "\"
        }
        $isoPath = $defaultVhdPath + "${vmName}_CDtest.iso"
        LogMsg "iso path: $isoPath defaultVhdPath $defaultVhdPath"
        $WebClient = New-Object System.Net.WebClient
        $WebClient.DownloadFile("$url", "$isoPath")
        try {
            Get-RemoteFileInfo -filename $isoPath  -server $HvServer
        }
        catch {
            LogErr "The .iso file $isoPath could not be found!"
            throw
        }
        Set-VMDvdDrive -VMName $VMName -ComputerName $hvServer -Path $isoPath
        if (-not $?) {
                throw "Unable to Add ISO $isoPath"
        }
        LogMsg "Attached DVD: Success"
        # Bring down the network.
        $remoteTest = "echo '${password}' | sudo -S -s eval `"export HOME=``pwd``;bash ${RemoteScript} > remotescript.log`""
        LogMsg "Run the remotescript $remoteScript"
        #Run the test on VM
        RunLinuxCmd -username $user -password $password -ip $VMIpv4 -port $VMPort $remoteTest -runAsSudo
        Start-Sleep -Seconds 3
        # Make sure network is down.
        $sts = ping $VMIpv4
        $pingresult = $False
        foreach ($line in $sts) {
           if (( $line -Like "*unreachable*" ) -or ($line -Like "*timed*")) {
               $pingresult = $True
           }
        }
        if ($pingresult) {
            LogMsg "Network Down: Success"
        }
        else {
            throw "Network Down: Failed"
        }
        $sts = New-Backup $VMName $driveLetter $HvServer $VMIpv4 $VMPort
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
        if (-not $sts) {
            throw "Backup evaluation failed"
        }
        Remove-Backup $backupLocation
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

