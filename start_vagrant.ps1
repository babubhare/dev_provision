#Requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$WiredSwitchName = 'External_Wired'
$WirelessSwitchName = 'External_Wireless'
$SshUser = 'devuser'
$DirectoryTabTitle = 'Vagrant Directory'

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Write-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ''
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Stop-Script {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Error $Message
    exit 1
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$ArgumentList = @(),

        [switch]$AllowFailure
    )

    $output = @(& $FilePath @ArgumentList 2>&1)
    $exitCode = $LASTEXITCODE

    if (($exitCode -ne 0) -and (-not $AllowFailure)) {
        $text = ($output | Out-String).Trim()

        if ([string]::IsNullOrWhiteSpace($text)) {
            throw (
                'Command failed with exit code {0}: {1} {2}' -f
                $exitCode,
                $FilePath,
                ($ArgumentList -join ' ')
            )
        }

        throw (
            'Command failed with exit code {0}: {1} {2}{3}{4}' -f
            $exitCode,
            $FilePath,
            ($ArgumentList -join ' '),
            [Environment]::NewLine,
            $text
        )
    }

    return [PSCustomObject]@{
        Output = $output
        ExitCode = $exitCode
    }
}

function Get-VagrantVmName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VagrantfilePath
    )

    $content = Get-Content -LiteralPath $VagrantfilePath -Raw

    $patterns = @(
        '(?im)^\s*config\.vm\.define\s+["''](?<Name>[^"'']+)["'']',
        '(?im)^\s*[A-Za-z0-9_]+\s*\.vmname\s*=\s*["''](?<Name>[^"'']+)["'']'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($content, $pattern)

        if ($match.Success) {
            return $match.Groups['Name'].Value.Trim()
        }
    }

    return 'iris_ubuntu_server_2604'
}

function Get-ExpectedHyperVSwitch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WiredSwitch,

        [Parameter(Mandatory = $true)]
        [string]$WirelessSwitch
    )

    $routes = @(
        Get-NetRoute `
            -DestinationPrefix '0.0.0.0/0' `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $_.State -eq 'Alive' -and
            $_.NextHop -ne '0.0.0.0'
        } |
        Sort-Object RouteMetric, InterfaceMetric
    )

    foreach ($route in $routes) {
        $adapter = Get-NetAdapter `
            -InterfaceIndex $route.InterfaceIndex `
            -ErrorAction SilentlyContinue

        if (-not $adapter) {
            continue
        }

        if ($adapter.Status -ne 'Up') {
            continue
        }

        $isWireless = (
            $adapter.MediaType -eq '802.11' -or
            $adapter.Name -match '(?i)Wi-?Fi|Wireless|WLAN' -or
            $adapter.InterfaceDescription -match '(?i)Wi-?Fi|Wireless|WLAN|802\.11'
        )

        if ($isWireless) {
            Write-Host (
                'Active host network: Wireless ({0})' -f $adapter.Name
            ) -ForegroundColor Green

            return $WirelessSwitch
        }

        Write-Host (
            'Active host network: Wired ({0})' -f $adapter.Name
        ) -ForegroundColor Green

        return $WiredSwitch
    }

    Write-Warning (
        "Could not determine the active network. Using '{0}'." -f
        $WiredSwitch
    )

    return $WiredSwitch
}

function Get-HyperVVmInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $vm = Get-VM `
        -Name $VmName `
        -ErrorAction SilentlyContinue

    if (-not $vm) {
        return [PSCustomObject]@{
            Exists = $false
            State = 'NotFound'
            Switches = @()
        }
    }

    $switches = @(
        Get-VMNetworkAdapter `
            -VMName $VmName `
            -ErrorAction SilentlyContinue |
        ForEach-Object {
            $_.SwitchName
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Select-Object -Unique
    )

    return [PSCustomObject]@{
        Exists = $true
        State = [string]$vm.State
        Switches = $switches
    }
}

function Get-SshConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigText,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    $escapedPropertyName = [regex]::Escape($PropertyName)
    $pattern = '(?im)^\s*{0}\s+(?<Value>.+?)\s*$' -f $escapedPropertyName
    $match = [regex]::Match($ConfigText, $pattern)

    if ($match.Success) {
        return $match.Groups['Value'].Value.Trim().Trim('"')
    }

    return $null
}

function Normalize-SshPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $result = [Environment]::ExpandEnvironmentVariables($Path)

    if ($result.StartsWith('~')) {
        $result = Join-Path `
            $env:USERPROFILE `
            $result.Substring(1).TrimStart('\', '/')
    }

    return $result
}

function Update-SshConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [string]$VmIp,

        [Parameter(Mandatory = $true)]
        [string]$IdentityFile,

        [Parameter(Mandatory = $true)]
        [string]$UserName
    )

    $sshDirectory = Join-Path $env:USERPROFILE '.ssh'
    $sshConfigPath = Join-Path $sshDirectory 'config'

    New-Item `
        -Path $sshDirectory `
        -ItemType Directory `
        -Force |
        Out-Null

    if (Test-Path -LiteralPath $sshConfigPath) {
        $config = Get-Content `
            -LiteralPath $sshConfigPath `
            -Raw
    }
    else {
        $config = ''
    }

    $escapedHostName = [regex]::Escape($HostName)

    # This pattern uses \r?
 as text inside a single-quoted PowerShell
    # string, so the regular expression receives the intended characters.
    $hostPattern = (
        '(?ims)^[ \t]*Host[ \t]+{0}[ \t]*\r?
' +
        '.*?(?=^[ \t]*Host[ \t]+|\z)'
    ) -f $escapedHostName

    $newBlock = @(
        'Host {0}' -f $HostName
        '    HostName {0}' -f $VmIp
        '    User {0}' -f $UserName
        '    IdentityFile "{0}"' -f $IdentityFile
        ''
    ) -join [Environment]::NewLine

    if ([regex]::IsMatch($config, $hostPattern)) {
        $config = [regex]::Replace(
            $config,
            $hostPattern,
            $newBlock
        )
    }
    else {
        $config = $config.TrimEnd()

        if ($config.Length -gt 0) {
            $config += [Environment]::NewLine
        }

        $config += [Environment]::NewLine + $newBlock
    }

    [System.IO.File]::WriteAllText(
        $sshConfigPath,
        $config.TrimEnd() + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Host (
        'SSH configuration updated: {0}' -f $sshConfigPath
    ) -ForegroundColor Green
}

function Test-VagrantSsh {
    Write-Host 'Testing Vagrant SSH connection...' -ForegroundColor Cyan

    $result = Invoke-CheckedCommand `
        -FilePath 'vagrant' `
        -ArgumentList @(
            'ssh'
            '--'
            'echo'
            'VAGRANT_SSH_OK'
        ) `
        -AllowFailure

    if ($result.ExitCode -ne 0) {
        $text = ($result.Output | Out-String).Trim()

        throw (
            'Vagrant SSH test failed with exit code {0}.{1}{2}' -f
            $result.ExitCode,
            [Environment]::NewLine,
            $text
        )
    }

    if ($result.Output -notmatch 'VAGRANT_SSH_OK') {
        throw 'The expected Vagrant SSH response was not received.'
    }

    Write-Host 'Vagrant SSH test succeeded.' -ForegroundColor Green
}

function Start-DirectoryTabAndSshTab {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string]$SshTitle
    )

    $wt = Get-Command 'wt.exe' -ErrorAction SilentlyContinue

    if (-not $wt) {
        Write-Warning 'Windows Terminal was not found.'
        Write-Host 'Starting Vagrant SSH in the current window.'

        $Host.UI.RawUI.WindowTitle = $SshTitle
        & vagrant ssh
        return
    }

    $safeDirectory = $WorkingDirectory.Replace("'", "''")
    $safeDirectoryTitle = $DirectoryTabTitle.Replace("'", "''")
    $safeSshTitle = $SshTitle.Replace("'", "''")

    # The directory tab only changes to the Vagrant directory.
    # It does not start another Windows Terminal process.
    $directoryCommand = (
        "Set-Location -LiteralPath '{0}'; " +
        "`$Host.UI.RawUI.WindowTitle = '{1}'"
    ) -f $safeDirectory, $safeDirectoryTitle

    # The SSH tab sets the title before vagrant starts and leaves the title
    # unchanged while the SSH session is active.
    $sshCommand = (
        "Set-Location -LiteralPath '{0}'; " +
        "`$Host.UI.RawUI.WindowTitle = '{1}'; " +
        "vagrant ssh"
    ) -f $safeDirectory, $safeSshTitle

    if ($env:WT_SESSION) {
        # The script is already running in a Windows Terminal tab.
        # That current tab becomes the directory tab.
        $Host.UI.RawUI.WindowTitle = $DirectoryTabTitle

        # Open exactly one additional tab for SSH.
        & $wt.Source `
            new-tab `
            --title $SshTitle `
            --suppressApplicationTitle `
            --startingDirectory $WorkingDirectory `
            powershell.exe `
            -NoExit `
            -Command $sshCommand

        return
    }

    # The script is not running in Windows Terminal.
    # Start Windows Terminal with exactly two commands:
    #   command 1: directory tab
    #   command 2: SSH tab
    & $wt.Source `
        new-tab `
        --title $DirectoryTabTitle `
        --suppressApplicationTitle `
        --startingDirectory $WorkingDirectory `
        powershell.exe `
        -NoExit `
        -Command $directoryCommand `
        ';' `
        new-tab `
        --title $SshTitle `
        --suppressApplicationTitle `
        --startingDirectory $WorkingDirectory `
        powershell.exe `
        -NoExit `
        -Command $sshCommand
}

# ---------------------------------------------------------------------------
# Administrator check
# ---------------------------------------------------------------------------

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

$currentPrincipal = New-Object `
    Security.Principal.WindowsPrincipal($currentIdentity)

$isAdministrator = $currentPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdministrator) {
    Write-Host `
        'Requesting Administrator privileges...' `
        -ForegroundColor Yellow

    $scriptPath = $MyInvocation.MyCommand.Path

    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        Stop-Script `
            'Save this script as a .ps1 file before running it.'
    }

    Start-Process `
        -FilePath 'powershell.exe' `
        -Verb RunAs `
        -ArgumentList @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            $scriptPath
        )

    exit
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Set-Location -LiteralPath $PSScriptRoot

if (-not (Get-Command 'vagrant.exe' -ErrorAction SilentlyContinue)) {
    Stop-Script 'Vagrant was not found in PATH.'
}

if (-not (Get-Command 'Get-VM' -ErrorAction SilentlyContinue)) {
    Stop-Script 'The Hyper-V PowerShell module is not available.'
}

$vagrantfilePath = Join-Path $PSScriptRoot 'Vagrantfile'

if (-not (Test-Path -LiteralPath $vagrantfilePath)) {
    Stop-Script (
        'Vagrantfile was not found at: {0}' -f $vagrantfilePath
    )
}

Write-Step 'Identifying the Hyper-V VM'

$vmName = Get-VagrantVmName `
    -VagrantfilePath $vagrantfilePath

$sshTabTitle = '{0}@{1}' -f $SshUser, $vmName

Write-Host (
    'Hyper-V VM: {0}' -f $vmName
) -ForegroundColor Green

Write-Host (
    'SSH tab title: {0}' -f $sshTabTitle
) -ForegroundColor Green

Write-Step 'Determining the expected Hyper-V switch'

$expectedSwitch = Get-ExpectedHyperVSwitch `
    -WiredSwitch $WiredSwitchName `
    -WirelessSwitch $WirelessSwitchName

Write-Host (
    'Expected switch: {0}' -f $expectedSwitch
) -ForegroundColor Green

Write-Step 'Checking Hyper-V VM state'

# This is the only VM status check. vagrant status is not used.
$vmInfo = Get-HyperVVmInfo -VmName $vmName

if (-not $vmInfo.Exists) {
    Write-Host `
        "VM not found in Hyper-V. Running 'vagrant up'..." `
        -ForegroundColor Yellow

    Invoke-CheckedCommand `
        -FilePath 'vagrant' `
        -ArgumentList @('up') |
        ForEach-Object {
            $_.Output | Write-Host
        }

    $vmInfo = Get-HyperVVmInfo -VmName $vmName
}
elseif ($vmInfo.State -ne 'Running') {
    Write-Host (
        "VM state is '{0}'. Running 'vagrant up'..." -f
        $vmInfo.State
    ) -ForegroundColor Yellow

    Invoke-CheckedCommand `
        -FilePath 'vagrant' `
        -ArgumentList @('up') |
        ForEach-Object {
            $_.Output | Write-Host
        }

    $vmInfo = Get-HyperVVmInfo -VmName $vmName
}
else {
    Write-Host `
        'The Hyper-V VM is already running.' `
        -ForegroundColor Green
}

if (-not $vmInfo.Exists) {
    Stop-Script `
        'The VM was not found after running vagrant up.'
}

if ($vmInfo.State -ne 'Running') {
    Stop-Script (
        "The VM is not running. Current state: '{0}'" -f
        $vmInfo.State
    )
}

Write-Step 'Checking the Hyper-V network switch'

$currentSwitch = $vmInfo.Switches | Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($currentSwitch)) {
    Write-Warning `
        'No Hyper-V network switch was found on the VM.'
}
elseif ($currentSwitch -ne $expectedSwitch) {
    Write-Warning (
        "Switch mismatch. Expected '{0}', current '{1}'." -f
        $expectedSwitch,
        $currentSwitch
    )

    $reloadChoice = Read-Host `
        'Reload the VM to re-evaluate the switch? (y/n)'

    if ($reloadChoice -match '^[Yy]') {
        Write-Host `
            'Reloading the VM without provisioning...' `
            -ForegroundColor Yellow

        Invoke-CheckedCommand `
            -FilePath 'vagrant' `
            -ArgumentList @(
                'reload'
                '--no-provision'
            ) |
            ForEach-Object {
                $_.Output | Write-Host
            }

        $vmInfo = Get-HyperVVmInfo -VmName $vmName

        if ($vmInfo.State -ne 'Running') {
            Stop-Script (
                "The VM is not running after reload. Current state: '{0}'" -f
                $vmInfo.State
            )
        }

        $currentSwitch = $vmInfo.Switches | Select-Object -First 1

        if ($currentSwitch -eq $expectedSwitch) {
            Write-Host `
                'The switch now matches the expected switch.' `
                -ForegroundColor Green
        }
        else {
            Write-Warning (
                "The VM is still connected to '{0}' after reload." -f
                $currentSwitch
            )
        }
    }
    else {
        Write-Host `
            'Reload skipped. Keeping the current switch.' `
            -ForegroundColor Yellow
    }
}
else {
    Write-Host `
        'The Hyper-V switch matches the expected switch.' `
        -ForegroundColor Green
}

Write-Step 'Reading SSH configuration'

$sshConfigResult = Invoke-CheckedCommand `
    -FilePath 'vagrant' `
    -ArgumentList @('ssh-config')

$sshConfig = $sshConfigResult.Output -join [Environment]::NewLine

$vmIp = Get-SshConfigValue `
    -ConfigText $sshConfig `
    -PropertyName 'HostName'

$identityFile = Get-SshConfigValue `
    -ConfigText $sshConfig `
    -PropertyName 'IdentityFile'

if ([string]::IsNullOrWhiteSpace($vmIp)) {
    Stop-Script `
        "HostName was not found in 'vagrant ssh-config'."
}

if ([string]::IsNullOrWhiteSpace($identityFile)) {
    $identityFile = Join-Path `
        $env:USERPROFILE `
        '.vagrant.d\insecure_private_keys\vagrant.key.rsa'
}

$identityFile = Normalize-SshPath -Path $identityFile

Write-Host (
    'VM SSH address: {0}' -f $vmIp
) -ForegroundColor Green

Write-Host (
    'SSH key: {0}' -f $identityFile
) -ForegroundColor Green

Write-Step 'Updating SSH configuration'

Update-SshConfig `
    -HostName $vmName `
    -VmIp $vmIp `
    -IdentityFile $identityFile `
    -UserName $SshUser

Write-Step 'Testing SSH'

Test-VagrantSsh

Write-Step 'Opening exactly two terminal tabs'

Start-DirectoryTabAndSshTab `
    -WorkingDirectory $PSScriptRoot `
    -SshTitle $sshTabTitle