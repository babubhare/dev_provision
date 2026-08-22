# Requires -RunAsAdministrator

# 1. Find all .template files in the current directory
$templates = Get-ChildItem -Path . -Filter *.template
if ($templates.Count -eq 0) {
    Write-Host "No .template files found in the current directory." -ForegroundColor Red
    return
}

# 2. Display the numbered selection menu
Write-Host "Available Vagrant Templates:" -ForegroundColor Cyan
for ($i = 0; $i -lt $templates.Count; $i++) {
    Write-Host "[$i] $($templates[$i].Name)"
}

# 3. Prompt user for template selection
$selection = -1
while ($selection -lt 0 -or $selection -ge $templates.Count) {
    [int]$selection = Read-Host "Select a template number"
}
$selectedTemplate = $templates[$selection]

# 4. Prompt user for system role and aggressively strip out any appended bracket metadata
$rawSystemRole = Read-Host "Enter the system role (Press Enter for default 'default')"
if ([string]::IsNullOrWhiteSpace($rawSystemRole)) {
    $systemRole = "default"
} else {
    # Remove everything from the opening bracket onwards if interface artifacts get attached
    $cleanInput = $rawSystemRole.Split("[")[0].Trim()
    # Keep only safe alphanumeric characters, dashes, and underscores
    $systemRole = ($cleanInput -replace '[^a-zA-Z0-9\-_]', '')
    
    if ([string]::IsNullOrWhiteSpace($systemRole)) {
        $systemRole = "default"
    }
}

Write-Host "Using System Role: $systemRole" -ForegroundColor Green

# 5. Define parent 'vagrant' directory one level up
$parentVagrantDir = "$PSScriptRoot\..\vagrant"
if (!(Test-Path $parentVagrantDir)) {
    New-Item -ItemType Directory -Path $parentVagrantDir -Force | Out-Null
}

$tempFolderName = "temp_deploy_$([guid]::NewGuid().ToString().Substring(0,8))"
$tempFolderPath = Join-Path $parentVagrantDir $tempFolderName
$tempFolder = New-Item -ItemType Directory -Path $tempFolderPath -Force
Copy-Item -Path $selectedTemplate.FullName -Destination "$tempFolder\Vagrantfile"

# 6. Pass the sanitized role to Vagrant via Environment Variable
$env:VAGRANT_SYSTEM_ROLE = $systemRole

Push-Location -Path $tempFolder
$hostName = ""

try {
    vagrant up --provision

    # 7. Retrieve the generated hostname directly via SSH command
    Write-Host "Retrieving system hostname from the VM..." -ForegroundColor Cyan
    $rawHostName = vagrant ssh -c "hostname" 2>$null
    $hostName = ($rawHostName | Select-Object -Last 1).Trim()

    if ([string]::IsNullOrWhiteSpace($hostName)) {
        Write-Host "Failed to retrieve hostname via SSH. Keeping temporary name." -ForegroundColor Red
        $hostName = $tempFolderName
    } else {
        Write-Host "Captured Hostname: $hostName" -ForegroundColor Cyan

        $vagrantIdPath = ".\.vagrant\machines\default\hyperv\id"
        if (Test-Path $vagrantIdPath) {
            $vmId = (Get-Content $vagrantIdPath).Trim()
            
            # 8. Halt the VM and wait for Hyper-V handles to release
            Write-Host "Halting VM and waiting for Hyper-V to release handles..." -ForegroundColor Yellow
            vagrant halt
            Start-Sleep -Seconds 8
            
            # 9. Rename the Hyper-V VM
            Write-Host "Renaming Hyper-V VM to $hostName..."
            Get-VM -Id $vmId | Rename-VM -NewName $hostName

            # 10. Clean up temporary SMB share
            Write-Host "Cleaning up temporary SMB shares..."
            Get-SmbShare | Where-Object Path -eq $tempFolder.FullName | Remove-SmbShare -Force -Confirm:$false
            
            # 11. Update the Vagrantfile v.vmname
            Write-Host "Updating Vagrantfile v.vmname to $hostName..."
            $vFile = ".\Vagrantfile"
            if (Test-Path $vFile) {
                (Get-Content $vFile) -replace 'v\.vmname\s*=\s*".*"', "v.vmname = `"$hostName`"" | Set-Content $vFile
            }
        }
    }
} finally {
    Pop-Location

    if ($hostName -ne $tempFolderName -and !([string]::IsNullOrWhiteSpace($hostName))) {
        $finalFolderPath = Join-Path $parentVagrantDir $hostName
        
        if (Test-Path $finalFolderPath) {
            Write-Host "Target folder $finalFolderPath already exists. Removing old folder..." -ForegroundColor Yellow
            Remove-Item -Path $finalFolderPath -Recurse -Force
        }

        # 12. Robust Move using Robocopy to bypass Hyper-V file locks safely
        Write-Host "Moving deployment contents to final folder: $hostName..."
        if (!(Test-Path $finalFolderPath)) {
            New-Item -ItemType Directory -Path $finalFolderPath -Force | Out-Null
        }

        robocopy "$($tempFolder.FullName)" "$finalFolderPath" /E /MOVE /NFL /NDL /NJH /NJS | Out-Null

        # Give Windows a moment to release handles before attempting to remove the empty temp root
        Start-Sleep -Seconds 3
        
        $cleanupSuccess = $false
        $cleanupRetries = 0
        while (-not $cleanupSuccess -and $cleanupRetries -lt 5) {
            try {
                Remove-Item -Path $tempFolder.FullName -Recurse -Force -ErrorAction Stop
                $cleanupSuccess = $true
            } catch {
                $cleanupRetries++
                Start-Sleep -Seconds 3
            }
        }

        # 13. Fix Vagrant's Global Index tracking path
        Write-Host "Updating Vagrant Global Machine Index..."
        $vagrantIndex = "$env:USERPROFILE\.vagrant.d\data\machine-index\index"
        
        if (Test-Path $vagrantIndex) {
            $json = Get-Content $vagrantIndex -Raw | ConvertFrom-Json
            if ($null -ne $vmId -and $null -ne $json.machines.$vmId) {
                $newVagrantPath = "$(Join-Path $parentVagrantDir $hostName)\.vagrant"
                $json.machines.$vmId.local_data_path = $newVagrantPath
                $json | ConvertTo-Json -Depth 20 | Set-Content -Path $vagrantIndex
            }
        }
    }
    
    Write-Host "Deployment and reconfiguration finished successfully!" -ForegroundColor Green
}