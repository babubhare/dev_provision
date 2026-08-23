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

# 5. Define 'vagrant' directory as a direct subfolder where create_vagrant.ps1 resides
$parentVagrantDir = "$PSScriptRoot\vagrant"
if (!(Test-Path $parentVagrantDir)) {
    New-Item -ItemType Directory -Path $parentVagrantDir -Force | Out-Null
}

# 6. Pass the sanitized role to Vagrant via Environment Variable
$env:VAGRANT_SYSTEM_ROLE = $systemRole

$tempFolderName = "temp_deploy_$([guid]::NewGuid().ToString().Substring(0,8))"
$tempFolderPath = Join-Path $parentVagrantDir $tempFolderName
$tempFolder = New-Item -ItemType Directory -Path $tempFolderPath -Force

# Copy ONLY the Vagrantfile template to temp folder
Copy-Item -Path $selectedTemplate.FullName -Destination "$tempFolder\Vagrantfile"

Push-Location -Path $tempFolder
$hostName = ""
$vmId = $null

try {
    # 7. Run vagrant up with provision in the temp folder
    vagrant up --provision

    # 8. Get the hostname via SSH *after* system is fully provisioned
    Write-Host "Retrieving system hostname from the provisioned VM..." -ForegroundColor Cyan
    Start-Sleep -Seconds 3
    $rawHostName = vagrant ssh -c "hostname" 2>$null
    
    if ($null -ne $rawHostName) {
        $hostName = ($rawHostName | Select-Object -Last 1).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($hostName)) {
        Write-Host "Failed to retrieve hostname via SSH. Falling back to template name..." -ForegroundColor Yellow
        $hostName = $selectedTemplate.BaseName
    } else {
        Write-Host "Captured Hostname: $hostName" -ForegroundColor Cyan
    }

    # Grab Hyper-V ID for cleanup tracking
    $vagrantIdPath = ".\.vagrant\machines\default\hyperv\id"
    if (Test-Path $vagrantIdPath) {
        $vmId = (Get-Content $vagrantIdPath).Trim()
    }
} finally {
    Pop-Location
}

if (!([string]::IsNullOrWhiteSpace($hostName))) {
    $finalFolderPath = Join-Path $parentVagrantDir $hostName

    # 9. Delete/Destroy the temp VM and the temp folder
    Write-Host "Cleaning up temporary VM instance and folder..." -ForegroundColor Yellow
    Push-Location -Path $tempFolderPath
    vagrant destroy -f
    Pop-Location
    Start-Sleep -Seconds 3

    if ($null -ne $vmId) {
        Get-VM -Id $vmId -ErrorAction SilentlyContinue | Remove-VM -Force -Confirm:$false
    }
    Get-SmbShare | Where-Object Path -eq $tempFolder.FullName | Remove-SmbShare -Force -Confirm:$false
    Remove-Item -Path $tempFolder.FullName -Recurse -Force -ErrorAction SilentlyContinue

    # Clean up global Vagrant machine index for the temp VM ID
    $vagrantIndex = "$env:USERPROFILE\.vagrant.d\data\machine-index\index"
    if (Test-Path $vagrantIndex) {
        $json = Get-Content $vagrantIndex -Raw | ConvertFrom-Json
        if ($null -ne $vmId -and $null -ne $json.machines.$vmId) {
            $json.machines.PSObject.Properties.Remove($vmId)
            $json | ConvertTo-Json -Depth 20 | Set-Content -Path $vagrantIndex
        }
    }

    # 10. Create new permanent folder with the exact hostname
    if (Test-Path $finalFolderPath) {
        Remove-Item -Path $finalFolderPath -Recurse -Force
    }
    Write-Host "Creating permanent folder: $hostName..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $finalFolderPath -Force | Out-Null

    # Copy template into the new permanent folder
    Copy-Item -Path $selectedTemplate.FullName -Destination "$finalFolderPath\Vagrantfile"

    # Update vmname configuration inside the final Vagrantfile
    $finalVFile = Join-Path $finalFolderPath "Vagrantfile"
    if (Test-Path $finalVFile) {
        $vContents = Get-Content $finalVFile
        $vContents = $vContents -replace 'v\.vmname\s*=\s*".*"', "v.vmname = `"$hostName`""
        $vContents | Set-Content $finalVFile
    }

    # Copy start_vagrant.ps1 from root to the new VM folder
    $sourceStartScript = Join-Path $PSScriptRoot "start_vagrant.ps1"
    if (Test-Path $sourceStartScript) {
        Write-Host "Copying start_vagrant.ps1 to the VM folder..." -ForegroundColor Cyan
        Copy-Item -Path $sourceStartScript -Destination (Join-Path $finalFolderPath "start_vagrant.ps1") -Force
    } else {
        Write-Warning "Could not find start_vagrant.ps1 in '$PSScriptRoot'. Make sure it exists so it can be copied."
    }

    # 11. Run vagrant up with provision in the permanent folder
    Write-Host "Starting and provisioning VM in its permanent folder location..." -ForegroundColor Cyan
    Push-Location -Path $finalFolderPath
    vagrant up --provision

    # 12. Change username config to devuser in the Vagrantfile
    Write-Host "Updating Vagrantfile SSH username to 'devuser'..." -ForegroundColor Cyan
    if (Test-Path $finalVFile) {
        $vContents = Get-Content $finalVFile
        $vContents = $vContents -replace 'config\.ssh\.username\s*=\s*"vagrant"', 'config.ssh.username = "devuser"'
        $vContents | Set-Content $finalVFile
    }

    # 13. Run vagrant reload to apply username configuration update safely
    Write-Host "Reloading VM to apply username changes..." -ForegroundColor Cyan
    vagrant reload
    Pop-Location

    Write-Host "Deployment, provisioning, and final configuration completed successfully!" -ForegroundColor Green

    # 14. Prompt user to open a separate terminal window/tab and automatically run vagrant ssh
    $openTerminal = Read-Host "Would you like to open a new terminal window/tab and connect to the VM via SSH? (y/n)"
    if ($openTerminal -match '^[Yy]') {
        if (Get-Command "wt.exe" -ErrorAction SilentlyContinue) {
            # Windows Terminal: open tab at folder path and execute vagrant ssh
            Start-Process wt.exe -ArgumentList "new-tab -d `"$finalFolderPath`" ; powershell -NoExit -Command `"vagrant ssh`""
        } else {
            # Standard PowerShell: open window, set path, and run vagrant ssh
            Start-Process powershell.exe -ArgumentList "-NoExit -Command `"Set-Location '$finalFolderPath'; vagrant ssh`""
        }
    }
}