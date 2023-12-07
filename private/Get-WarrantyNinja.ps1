function  Get-WarrantyNinja {
    [CmdletBinding()]
    Param(
        [string]$NinjaURL,
        [String]$Secretkey,
        [String]$AccessKey,
        [boolean]$SyncWithSource,
        [boolean]$OverwriteWarranty,
        [string]$NinjaFieldName
    )
    $AuthBody = @{
        'grant_type'    = 'client_credentials'
        'client_id'     = $AccessKey
        'client_secret' = $Secretkey
        'scope'         = 'management monitoring' 
    }
    
    $Result = Invoke-WebRequest -uri "$($NinjaURL)/ws/oauth/token" -Method POST -Body $AuthBody -ContentType 'application/x-www-form-urlencoded'
    
    $AuthHeader = @{
        'Authorization' = "Bearer $(($Result.content | convertfrom-json).access_token)"
    }

    $OrgsRaw = Invoke-WebRequest -uri "$($NinjaURL)/v2/organizations" -Method GET -Headers $AuthHeader
    $NinjaOrgs = $OrgsRaw | ConvertFrom-Json
    
    $date1 = Get-Date -Date "01/01/1970"  

    If ($ResumeLast) {
        write-host "Found previous run results. Starting from last object." -foregroundColor green
        $Devices = get-content 'Devices.json' | convertfrom-json
    } else {
        $DevicesRaw = Invoke-WebRequest -uri "$($NinjaURL)/v2/devices-detailed" -Method GET -Headers $AuthHeader
        $Devices = $DevicesRaw.content | ConvertFrom-Json

        $After = 0
        $PageSize = 1000
        $Devices = do {
            $Result = (Invoke-WebRequest -uri "$($NinjaURL)/v2/devices-detailed?pageSize=$PageSize&after=$After" -Method GET -Headers $AuthHeader -ContentType 'application/json').content | ConvertFrom-Json -depth 100
            $Result
            $ResultCount = ($Result.id | Measure-Object -Maximum)
            $After = $ResultCount.maximum
    
        } while ($ResultCount.count -eq $PageSize)

    }
    $i = 0
    $warrantyObject = foreach ($device in $Devices) {
        $i++
        Write-Progress -Activity "Grabbing Warranty information" -status "Processing $($device.system.biosSerialNumber). Device $i of $($Devices.Count)" -percentComplete ($i / $Devices.Count * 100)
        $DeviceOrg = ($NinjaOrgs | Where-Object { $_.id -eq $Device.organizationId }).name
        try {
            $WarState = Get-Warrantyinfo -DeviceSerial $device.system.biosSerialNumber -client $DeviceOrg
        } catch {
            Write-Error "Failed to fetch warranty data for device: $($Device.systemName) $_"
        }
        $Null = set-content 'Devices.json' -force -value ($Devices | select-object -skip $i | convertto-json -depth 5)

        if ($warstate.EndDate) {
            $MilliSeconds = ([DateTimeOffset]$warstate.EndDate).ToUnixTimeMilliseconds()
            $UpdateBody = @{
                "$NinjaFieldName" = $MilliSeconds
            } | convertto-json
            
            if ($SyncWithSource -eq $true) {
                switch ($OverwriteWarranty) {
                    $true {
                        
                        try {
                            $Result = Invoke-WebRequest -uri "$($NinjaURL)/v2/device/$($Device.id)/custom-fields" -Method PATCH -Headers $AuthHeader -body $UpdateBody -contenttype 'application/json' -ea stop
                        } catch {
                            Write-Error "Failed to update device: $($Device.systemName) $_"
                        }
                    }
                    $false {
                        $DeviceFields = Invoke-WebRequest -uri "$($NinjaURL)/v2/device/$($Device.id)/custom-fields" -Method GET -Headers $AuthHeader
                        $WarrantyDate = ($DeviceFields.content | convertfrom-json)."$($NinjaFieldName)"

                        if ($null -eq $WarrantyDate -and $null -ne $warstate.EndDate) { 
                            try {
                                $Result = Invoke-WebRequest -uri "$($NinjaURL)/v2/device/$($Device.id)/custom-fields" -Method PATCH -Headers $AuthHeader -body $UpdateBody -contenttype 'application/json' -ea stop
                            } catch {
                                Write-Error "Failed to update device: $($Device.systemName) $_"
                            }        
                        } 
                    }
                }
            }
        }
        $WarState
    }
    Remove-item 'devices.json' -Force -ErrorAction SilentlyContinue
    return $warrantyObject

}
