function Test-VirtualHardDiskSize
{
    [Cmdletbinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [String]
        $VMName,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $GuestCredential,
        [Parameter(Mandatory = $true)]
        [String]
        $HostName,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $HostCredential,
        [Parameter(Mandatory = $false)]
        [int32]
        $DefaultDiskExtensionInPercent = 5,
        [Parameter(Mandatory = $false)]
        [int32]
        $VolumeUsageThresholdInPercent = 90
    )    

    function Get-VolumeUsage
    {
        param 
        (
            [Parameter(Mandatory = $true)]
            [String]
            $VMName,
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.PSCredential]
            $GuestCredential
        )

        $Output = Invoke-VMScript -VM $VMName -GuestCredential $GuestCredential -ScriptText {
            $Partitions = @()
            foreach ($Partition in (Get-Partition))
            {
                $Volume = $Partition | Get-Volume -ErrorAction SilentlyContinue
                
                if ($Volume -and $Volume.DriveLetter -ne $null)
                {
                    $PartitionObject = New-Object System.Object
                    $PartitionObject | Add-Member -Type NoteProperty -Name Letter -Value $Volume.DriveLetter
                    $PartitionObject | Add-Member -Type NoteProperty -Name SizeRemaining -Value ($Volume.SizeRemaining/1GB)
                    $PartitionObject | Add-Member -Type NoteProperty -Name Size -Value ($Volume.Size/1GB)
                    $PartitionObject | Add-Member -Type NoteProperty -Name Usage -Value ("{0:N2}" -f (($Volume.Size - $Volume.SizeRemaining) / $Volume.Size * 100))
                    $PartitionObject | Add-Member -Type NoteProperty -Name DiskUniqueId -Value (Get-Disk $Partition.DiskNumber).UniqueId.ToLower()
                    $Partitions += $PartitionObject
                }
                
            }

            $Partitions | ConvertTo-Csv -NoTypeInformation
        }

        return $Output.ScriptOutput | ConvertFrom-Csv
    }

    function Set-VirtualHardDisk
    {
        param
        (
            [Parameter(Mandatory = $true)]
            [array]
            $Volumes,
            [Parameter(Mandatory = $true)]
            [String]
            $VMName,
            [Parameter(Mandatory = $true)]
            [int32]
            $DefaultDiskExtensionInPercent,
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.PSCredential]
            $GuestCredential
        )
        
        $VMDisks = Get-HardDisk -VM $VMName

        foreach ($Volume in ($Volumes | Where-Object {$_.Usage -gt $VolumeUsageThresholdInPercent}))
        {
            $DiskToExtend = $VMDisks | Where-Object {($_.ExtensionData.Backing.Uuid -replace '-','') -eq $Volume.DiskUniqueId}
            $TargetCapacity = $DiskToExtend.CapacityGB * (1 + ($DefaultDiskExtensionInPercent / 100))
            Write-Verbose "Volume $($Volume.Letter) is at $($Volume.Usage)% usage. Extending volume $($Volume.Letter) from $($DiskToExtend.CapacityGB)GB to $($TargetCapacity)GB"
            $DiskToExtend | Set-HardDisk -CapacityGB $TargetCapacity -Confirm:$false
            Start-Sleep 10
            $ScriptText = {
                Get-Disk | Update-Disk
                $PartitionToExtend = Get-Partition -DriveLetter "#DriveLetter#"
                $PartitionToExtend | Resize-Partition -Size ($PartitionToExtend | Get-PartitionSupportedSize).SizeMax
            }
            
            $ScriptText = $ScriptText -replace '#DriveLetter#',$Volume.Letter

            Invoke-VMScript -VM $VMName -GuestCredential $GuestCredential -ScriptText $ScriptText
            
        }
    }

    # Connect to host
    Connect-VIServer -Server $HostName -Credential $HostCredential -Force

    # Get volume usage for all volumes for a VM
    $Volumes = Get-VolumeUsage -VMName $VMName -GuestCredential $GuestCredential

    # Extend disks running out of space
    Set-VirtualHardDisk -Volumes $Volumes -VMName $VMName -DefaultDiskExtensionInPercent $DefaultDiskExtensionInPercent -GuestCredential $GuestCredential

}
