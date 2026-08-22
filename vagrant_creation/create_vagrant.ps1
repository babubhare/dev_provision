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

# 4. Prompt user for system role and sanitize input
$rawSystemRole = Read-Host "Enter the system role (Press Enter for default 'default')"
if ([string]::IsNullOrWhiteSpace($rawSystemRole)) {
    $systemRole = "default"
} else {
    $cleanInput = $rawSystemRole.Split("[")[0].Trim()
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

# 6. Pass the sanitized role to Vagrant via Environment Variable
$env:VAGRANT_SYSTEM_ROLE = $systemRole

# Create a temporary working folder name to boot up and capture hostname
$tempFolderName = "temp_deploy_$([guid]::NewGuid().ToString().Substring(0,8))"
$tempFolderPath = Join-Path $parentVagrantDir $tempFolderName
$tempFolder = New-Item -ItemType Directory -Path $tempFolderPath -Force
Copy-Item -Path $selectedTemplate.FullName -Destination "$tempFolder\Vagrantfile"

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
            
            # 8. Halt the VM completely so Hyper-V releases file handles
            Write-Host "Halting VM and waiting for Hyper-V to release handles..." -ForegroundColor Yellow
            vagrant halt
            Start-Sleep -Seconds 10
            
            # 9. Unregister the VM from Hyper-V temporarily so we can move its files safely without security locks
            Write-Host "Unregistering VM from Hyper-V to safely relocate files..."
            Unregister-VM -Id $vmId -Confirm:$false
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

        # 10. Move deployment contents cleanly to final destination folder named after the hostname
        Write-Host "Moving deployment contents to final folder: $hostName..."
        New-Item -ItemType Directory -Path $finalFolderPath -Force | Out-Null
        
        robocopy "$($tempFolder.FullName)" "$finalFolderPath" /E /MOVE /NFL /NDL /NJH /NJS | Out-Null
        Start-Sleep -Seconds 3
        Remove-Item -Path $tempFolder.FullName -Recurse -Force -ErrorAction SilentlyContinue

        # 11. Re-register the VM under Hyper-V from its new permanent home path
        $newVmxFile = Get-ChildItem -Path $finalFolderPath -Filter "*.vmcx" -Recurse | Select-Object -First 1
        if ($newVmxFile) {
            Write-Host "Registering VM under Hyper-V from final location..."
            $registeredVM = Register-VM -Path $newVmxFile.FullName -Passthru
            
            if ($registeredVM) {
                # Rename Hyper-V VM to match hostname
                Rename-VM -VM $registeredVM -NewName $hostName -ErrorAction SilentlyContinue

                # 12. Update the Vagrantfile v.vmname and config.ssh.username
                Write-Host "Updating Vagrantfile configurations..."
                $vFile = Join-Path $finalFolderPath "Vagrantfile"
                if (Test-Path $vFile) {
                    $vContents = Get-Content $vFile
                    $vContents = $vContents -replace 'v\.vmname\s*=\s*".*"', "v.vmname = `"$hostName`""
                    $vContents = $vContents -replace 'config\.ssh\.username\s*=\s*".*"', 'config.ssh.username = "devuser"'
                    $vContents | Set-Content $vFile
                }

                # 13. Fix Vagrant's Global Index tracking path to point to the final folder
                Write-Host "Updating Vagrant Global Machine Index..."
                $vagrantIndex = "$env:USERPROFILE\.vagrant.d\data\machine-index\index"
                if (Test-Path $vagrantIndex) {
                    $json = Get-Content $vagrantIndex -Raw | ConvertFrom-Json
                    $targetId = $registeredVM.Id.Guid
                    if ($null -ne $json.machines.$targetId) {
                        $json.machines.$targetId.local_data_path = "$(Join-Path $finalFolderPath ".vagrant")"
                        $json | ConvertTo-Json -Depth 20 | Set-Content -Path $vagrantIndex
                    }
                }
            }
        }
    }
    
    Write-Host "Deployment, relocation, and reconfiguration finished successfully!" -ForegroundColor Green
}