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

# 5. Define 'vagrant' directory as a direct subfolder where Deploy-VM.ps1 resides
$parentVagrantDir = "$PSScriptRoot\vagrant"
if (!(Test-Path $parentVagrantDir)) {
    New-Item -ItemType Directory -Path $parentVagrantDir -Force | Out-Null
}

# 6. Pass the sanitized role to Vagrant via Environment Variable
$env:VAGRANT_SYSTEM_ROLE = $systemRole

$tempFolderName = "temp_deploy_$([guid]::NewGuid().ToString().Substring(0,8))"
$tempFolderPath = Join-Path $parentVagrantDir $tempFolderName
$tempFolder = New-Item -ItemType Directory -Path $tempFolderPath -Force

# Copy ONLY the Vagrantfile template
Copy-Item -Path $selectedTemplate.FullName -Destination "$tempFolder\Vagrantfile"

Push-Location -Path $tempFolder
$hostName = ""
$finalFolderPath = ""

try {
    vagrant up --provision

    # 7. Retrieve the generated hostname via SSH command with a brief retry buffer
    Write-Host "Retrieving system hostname from the VM..." -ForegroundColor Cyan
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

        $vagrantIdPath = ".\.vagrant\machines\default\hyperv\id"
        if (Test-Path $vagrantIdPath) {
            $vmId = (Get-Content $vagrantIdPath).Trim()
            
            # 8. Halt the VM and wait for handles to release
            Write-Host "Halting VM and waiting for Hyper-V to release handles..." -ForegroundColor Yellow
            vagrant halt
            Start-Sleep -Seconds 8
            
            # 9. Safely remove the virtual machine from Hyper-V management using its ID
            Write-Host "Removing temporary Hyper-V VM tracking..."
            Get-VM -Id $vmId -ErrorAction SilentlyContinue | Remove-VM -Force -Confirm:$false

            # 10. Clean up temporary SMB share
            Write-Host "Cleaning up temporary SMB shares..."
            Get-SmbShare | Where-Object Path -eq $tempFolder.FullName | Remove-SmbShare -Force -Confirm:$false
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

        # 11. Move deployment contents to final folder named after the captured hostname
        Write-Host "Moving deployment contents to final folder: $hostName..."
        New-Item -ItemType Directory -Path $finalFolderPath -Force | Out-Null
        
        robocopy "$($tempFolder.FullName)" "$finalFolderPath" /E /MOVE /NFL /NDL /NJH /NJS | Out-Null
        Start-Sleep -Seconds 3
        Remove-Item -Path $tempFolder.FullName -Recurse -Force -ErrorAction SilentlyContinue

        # 12. Update vmname configuration in the final Vagrantfile
        $finalVFile = Join-Path $finalFolderPath "Vagrantfile"
        if (Test-Path $finalVFile) {
            Write-Host "Updating final Vagrantfile configurations..."
            $vContents = Get-Content $finalVFile
            $vContents = $vContents -replace 'v\.vmname\s*=\s*".*"', "v.vmname = `"$hostName`""
            $vContents | Set-Content $finalVFile
        }

        # 13. Clean up the old entry from Vagrant global machine index safely
        Write-Host "Clearing old machine tracking from Vagrant Index..."
        $vagrantIndex = "$env:USERPROFILE\.vagrant.d\data\machine-index\index"
        
        if (-not [string]::IsNullOrEmpty($vagrantIndex)) {
            if (Test-Path $vagrantIndex) {
                if ($null -ne $vmId) {
                    $json = Get-Content $vagrantIndex -Raw | ConvertFrom-Json
                    if ($null -ne $json.machines.$vmId) {
                        $json.machines.PSObject.Properties.Remove($vmId)
                        $json | ConvertTo-Json -Depth 20 | Set-Content -Path $vagrantIndex
                    }
                }
            }
        }

        # 14. Automatically boot up the VM in its final folder location
        Write-Host "Starting VM in its final destination folder..." -ForegroundColor Cyan
        Push-Location -Path $finalFolderPath
        vagrant up
        Pop-Location
    }
    
    Write-Host "Deployment, relocation, and startup finished successfully!" -ForegroundColor Green

    # 15. Prompt user to open terminal and folder
    if (-not [string]::IsNullOrEmpty($finalFolderPath) -and (Test-Path $finalFolderPath)) {
        $openTerminal = Read-Host "Would you like to open a new terminal window/tab for the newly created VM folder? (y/n)"
        if ($openTerminal -match '^[Yy]') {
            # Check if Windows Terminal (wt.exe) is available to open a new tab, otherwise fallback to standard PowerShell window
            if (Get-Command "wt.exe" -ErrorAction SilentlyContinue) {
                Start-Process wt.exe -ArgumentList "new-tab -d `"$finalFolderPath`""
            } else {
                Start-Process powershell.exe -ArgumentList "-NoExit -Command `"Set-Location '$finalFolderPath'`""
            }
        }

        $openFolder = Read-Host "Would you like to open the newly created VM folder in Explorer? (y/n)"
        if ($openFolder -match '^[Yy]') {
            Start-Process explorer.exe $finalFolderPath
        }
    }
}