Try
{
    $defenderOptions = Get-MpComputerStatus

    if([string]::IsNullOrEmpty($defenderOptions))
    {
        Write-host "Windows Defender was not found running on the Server:" $env:computername -foregroundcolor "Green"
    }
    else
    {
        Write-host "Windows Defender was found on the Server:" $env:computername -foregroundcolor "Cyan"
        Write-host "   Is Windows Defender Enabled?" $defenderOptions.AntivirusEnabled
        Write-host "   Is Windows Defender Service Enabled?" $defenderOptions.AMServiceEnabled
        Write-host "   Is Windows Defender Antispyware Enabled?" $defenderOptions.AntispywareEnabled
        Write-host "   Is Windows Defender OnAccessProtection Enabled?"$defenderOptions.OnAccessProtectionEnabled
        Write-host "   Is Windows Defender RealTimeProtection Enabled?"$defenderOptions.RealTimeProtectionEnabled

        if($defenderOptions.RealTimeProtectionEnabled)
        {
            $windowsShell = new-object -comobject wscript.shell
            $questionResult = $windowsShell.popup("Do you want to disable Real Time Protection?", 0,"Not at this moment.",4)
            If ($questionResult -eq 6) {
	            Set-MpPreference -DisableRealtimeMonitoring $true
                Write-host "Windows Defender Real Time Protection was successfully disabled" -foregroundcolor "Green"
                Write-host "Nevertheless Windows Defender is still running"
            }
        }
    }
}
Catch
{
    Write-host "Windows Defender was not found running on the Server:" $env:computername -foregroundcolor "Green"
}
