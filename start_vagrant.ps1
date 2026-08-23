<#
.SYNOPSIS
    Master script to manage host network detection, pass switch config via environment variables, and run Vagrant.
#>

# Ensure script is running with Administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges to manage network switches..." -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# --- STEP 1: DETECT HOST NETWORK ---
Write-Host "Checking host network connection..." -ForegroundColor Cyan
$WiredSwitch = "External_Wired"
$WirelessSwitch = "External_Wireless"

$wiredAdapter = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' }
$wirelessAdapter = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.11' }

if ($wiredAdapter) {
    $targetSwitch = $WiredSwitch
    Write-Host "Host connected via Wired. Selected switch: $targetSwitch" -ForegroundColor Green
} elseif ($wirelessAdapter) {
    $targetSwitch = $WirelessSwitch
    Write-Host "Host connected via Wireless. Selected switch: $targetSwitch" -ForegroundColor Green
} else {
    $targetSwitch = $WiredSwitch
    Write-Warning "No active connection found. Defaulting to: $targetSwitch"
}

# Export the switch as an environment variable so Vagrant can read it natively
$env:VAGRANT_HYPERV_SWITCH = $targetSwitch

# --- STEP 2: CHECK VAGRANT STATUS & MANAGE LIFECYCLE ---
Set-Location $PSScriptRoot
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
    Write-Host "VM is currently running. Reloading VM to apply network switch changes..." -ForegroundColor Yellow
    vagrant reload --no-provision
}

# --- STEP 3: SSH INTO THE VM ---
Write-Host "Connecting to the VM via SSH..." -ForegroundColor Green
vagrant ssh