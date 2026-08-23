<#
.SYNOPSIS
    Smart start script that reads the VM name safely, checks Hyper-V network status, manages lifecycle, and runs SSH.
#>

# Ensure script is running with Administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Set-Location $PSScriptRoot

# --- STEP 1: EXTRACT VM NAME SAFELY WITHOUT REGEX ---
$vagrantfilePath = "Vagrantfile"
if (-not (Test-Path $vagrantfilePath)) {
    Write-Error "Vagrantfile not found in the current directory."
    exit
}

$vmName = "iris_ubuntu_server_2604" # Default fallback
foreach ($line in (Get-Content $vagrantfilePath)) {
    if ($line -match 'v\.vmname\s*=') {
        # Split by quotes to pull the exact string value safely
        $parts = $line.Split('"''')
        if ($parts.Count -ge 2) {
            $vmName = $parts[1]
            break
        }
    }
}
Write-Host "Target Hyper-V VM Name identified: $vmName" -ForegroundColor Cyan

# --- STEP 2: CHECK VAGRANT STATUS & HYPER-V ADAPTER STATE ---
Write-Host "Checking Vagrant VM status..." -ForegroundColor Cyan
$vagrantStatusOutput = vagrant status --machine-readable
$isRunning = $false
$isCreated = $false

foreach ($line in $vagrantStatusOutput) {
    if ($line -match ",state,running") {
        $isRunning = $true
        $isCreated = $true
    } elseif ($line -match ",state,") {
        $isCreated = $true
    }
}

if (-not $isCreated) {
    Write-Host "VM is not created. Running 'vagrant up'..." -ForegroundColor Yellow
    vagrant up
} elseif (-not $isRunning) {
    Write-Host "VM is powered off. Running 'vagrant up'..." -ForegroundColor Yellow
    vagrant up
} else {
    # VM is running; check Hyper-V adapter status directly
    Write-Host "VM is running. Checking Hyper-V network adapter binding..." -ForegroundColor Cyan
    
    $vmAdapter = Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue
    if ($vmAdapter) {
        $currentSwitch = $vmAdapter.SwitchName
        Write-Host "Current Hyper-V Switch assigned to VM: $currentSwitch" -ForegroundColor Cyan
    }

    $reloadChoice = Read-Host "Do you want to reload the VM to ensure the network switch matches your current host connection? (y/n)"
    if ($reloadChoice -match '^[Yy]') {
        Write-Host "Reloading VM to re-evaluate network binding..." -ForegroundColor Yellow
        vagrant reload --no-provision
    } else {
        Write-Host "Skipping reload. Keeping current VM state." -ForegroundColor Green
    }
}

# --- STEP 3: SSH INTO THE VM ---
Write-Host "Connecting to the VM via SSH..." -ForegroundColor Green
vagrant ssh