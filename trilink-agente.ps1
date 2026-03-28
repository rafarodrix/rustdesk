$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$AgentVersion = "trilink-agent-v1"
$RegPath = "HKLM:\SOFTWARE\Trilink\RemoteAgent"

$StateDir = Join-Path $env:ProgramData "Trilink\RemoteAgent"
$LogsDir = "C:\Trilink\Remote\Logs"
$LogFile = Join-Path $LogsDir "agentRemote.log"
$DebugLogFile = Join-Path $LogsDir "comodebug.log"
$StateFile = Join-Path $StateDir "agent-state.json"
$script:RegistryReadTrace = @{}
$script:InstallTokenReadSource = "not_checked"
$script:RunMutex = $null
$script:HasRunMutex = $false

function Ensure-StateDir {
    if (-not (Test-Path $StateDir)) {
        New-Item -Path $StateDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $LogsDir)) {
        New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Message)
    Ensure-StateDir
    $line = "$(Get-Date -Format o) | $Message"
    Add-Content -Path $LogFile -Value $line
    Add-Content -Path $DebugLogFile -Value $line
}

function Acquire-RunLock {
    param(
        [string]$MutexName = "Global\TrilinkRemoteAgentMutex",
        [int]$TimeoutMilliseconds = 1500
    )

    try {
        $createdNew = $false
        $script:RunMutex = New-Object System.Threading.Mutex($false, $MutexName, [ref]$createdNew)
        try {
            $acquired = $script:RunMutex.WaitOne($TimeoutMilliseconds, $false)
            if ($acquired) {
                $script:HasRunMutex = $true
                return $true
            }
            return $false
        } catch [System.Threading.AbandonedMutexException] {
            $script:HasRunMutex = $true
            Write-Log "run lock abandonado detectado (mutex=$MutexName). Execucao atual assumiu o lock."
            return $true
        }
    } catch {
        Write-Log "Falha ao adquirir run lock: $($_.Exception.Message)"
        return $false
    }
}

function Release-RunLock {
    if ($script:HasRunMutex -and $null -ne $script:RunMutex) {
        try {
            $script:RunMutex.ReleaseMutex()
        } catch {
            # ignore release errors
        }
    }
    if ($null -ne $script:RunMutex) {
        try {
            $script:RunMutex.Dispose()
        } catch {
            # ignore dispose errors
        }
    }
    $script:RunMutex = $null
    $script:HasRunMutex = $false
}

function Mask-Secret {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "empty" }
    $len = $Value.Length
    if ($len -le 4) { return ("*" * $len) }
    return ("*" * ($len - 4)) + $Value.Substring($len - 4)
}

function Truncate-Text {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxLength = 256
    )
    if ($null -eq $Text) { return "" }
    if ($MaxLength -le 0) { return "" }
    if ($Text.Length -le $MaxLength) { return $Text }
    return $Text.Substring(0, $MaxLength)
}

function Get-TopLevelKeys {
    param([object]$Object)
    if ($null -eq $Object) { return "" }
    if ($Object -is [hashtable]) {
        return (($Object.Keys | Sort-Object) -join ",")
    }
    $names = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    return (($names | Sort-Object) -join ",")
}

function Remove-OldLogs {
    param([int]$DaysToKeep = 10)

    try {
        if (-not (Test-Path $LogsDir)) { return }

        $limit = (Get-Date).AddDays(-$DaysToKeep)
        Get-ChildItem -Path $LogsDir -Filter "*.log" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $limit } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        # Nao bloqueia execucao por falha de limpeza.
    }
}

function Rotate-LogIfNeeded {
    param(
        [string]$FilePath,
        [int]$MaxSizeKb = 2048
    )

    if ([string]::IsNullOrWhiteSpace($FilePath)) { return }
    if (-not (Test-Path $FilePath)) { return }

    try {
        $sizeKb = ((Get-Item -Path $FilePath -ErrorAction Stop).Length / 1KB)
        if ($sizeKb -le $MaxSizeKb) { return }

        $dir = Split-Path -Path $FilePath -Parent
        $leaf = Split-Path -Path $FilePath -Leaf
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $archiveLeaf = $leaf -replace "\.log$", "-$stamp.log"
        if ($archiveLeaf -eq $leaf) { $archiveLeaf = "$leaf-$stamp.log" }
        $archivePath = Join-Path $dir $archiveLeaf
        Move-Item -Path $FilePath -Destination $archivePath -Force -ErrorAction SilentlyContinue
    } catch {
        # Nao bloqueia execucao por falha de rotacao.
    }
}

function Get-RustDeskExePath {
    $local = Join-Path $PSScriptRoot "rustdesk.exe"
    if (Test-Path $local) { return $local }
    return "C:\Trilink\Remote\RustDesk\rustdesk.exe"
}

function Get-ScriptVersionId {
    try {
        if (-not (Test-Path $PSCommandPath)) { return $AgentVersion }
        $hash = Get-FileHash -Path $PSCommandPath -Algorithm SHA256 -ErrorAction Stop
        if ($null -eq $hash -or [string]::IsNullOrWhiteSpace($hash.Hash)) { return $AgentVersion }
        return "sha256:$([string]$hash.Hash)"
    } catch {
        return $AgentVersion
    }
}

function Get-RustDeskId {
    $exe = Get-RustDeskExePath
    if (-not (Test-Path $exe)) {
        throw "rustdesk.exe nao encontrado: $exe"
    }

    $maxAttempts = 8
    $waitSeconds = 2
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $id = (& $exe --get-id 2>$null | Out-String).Trim()
        $id = ($id -replace "\s+", "")
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            return $id
        }

        if ($attempt -lt $maxAttempts) {
            Write-Log "RustDesk ID indisponivel (tentativa $attempt/$maxAttempts). Aguardando ${waitSeconds}s."
            Start-Sleep -Seconds $waitSeconds
        }
    }

    throw "RustDesk ID nao disponivel apos $maxAttempts tentativas."
}

function Get-ServiceStatus {
    $svc = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return "not_found" }
    if ($svc.Status -eq "Running") { return "running" }
    return "stopped"
}

function Apply-StartupJitter {
    param([int]$MaxSeconds = 60)

    if ($MaxSeconds -le 0) { return }
    $delay = Get-Random -Minimum 0 -Maximum ($MaxSeconds + 1)
    if ($delay -le 0) { return }

    Write-Log "Jitter inicial aplicado: aguardando ${delay}s antes do ciclo."
    Start-Sleep -Seconds $delay
}

function Get-PersistentBackoffSeconds {
    param([int]$ConsecutiveFailures)

    if ($ConsecutiveFailures -le 0) { return 0 }

    $steps = @(0, 10, 20, 40, 60, 90)
    $idx = [Math]::Min($ConsecutiveFailures, $steps.Count - 1)
    return [int]$steps[$idx]
}

function Try-RecoverRustDeskService {
    $before = Get-ServiceStatus
    $result = [ordered]@{
        serviceStatusBefore = $before
        selfHealAttempted = $false
        selfHealResult = "not_needed"
        serviceStatusAfter = $before
    }

    if ($before -eq "running") { return $result }

    $result.selfHealAttempted = $true
    if ($before -eq "not_found") {
        Write-Log "Self-healing: servico RustDesk nao encontrado para start."
        $result.selfHealResult = "failed"
        return $result
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Write-Log "Self-healing: tentativa ${attempt}/2 para iniciar servico RustDesk."
            Start-Service -Name "RustDesk" -ErrorAction Stop
            Start-Sleep -Seconds 2
        } catch {
            Write-Log "Self-healing: falha na tentativa ${attempt}/2: $($_.Exception.Message)"
        }

        $afterAttempt = Get-ServiceStatus
        if ($afterAttempt -eq "running") {
            $result.serviceStatusAfter = "running"
            $result.selfHealResult = "recovered"
            Write-Log "Self-healing: servico RustDesk recuperado."
            return $result
        }
    }

    $result.serviceStatusAfter = Get-ServiceStatus
    $result.selfHealResult = "failed"
    Write-Log "Self-healing: nao foi possivel recuperar o servico RustDesk."
    return $result
}

function Get-RegistryStringValue {
    param(
        [string]$SubKeyPath,
        [string]$ValueName
    )

    $traceKey = "${SubKeyPath}::${ValueName}"
    $views = @(
        [Microsoft.Win32.RegistryView]::Registry64,
        [Microsoft.Win32.RegistryView]::Registry32
    )

    foreach ($view in $views) {
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            try {
                $sub = $base.OpenSubKey($SubKeyPath)
                if ($null -eq $sub) { continue }
                try {
                    $val = $sub.GetValue($ValueName)
                    if ($null -ne $val) {
                        $str = [string]$val
                        if (-not [string]::IsNullOrWhiteSpace($str)) {
                            $script:RegistryReadTrace[$traceKey] = [string]$view
                            return $str
                        }
                    }
                } finally {
                    $sub.Close()
                }
            } finally {
                $base.Close()
            }
        } catch {
            continue
        }
    }

    $script:RegistryReadTrace[$traceKey] = "not_found"
    return $null
}

function Get-RegistryReadSource {
    param(
        [string]$SubKeyPath,
        [string]$ValueName
    )

    $traceKey = "${SubKeyPath}::${ValueName}"
    if ($script:RegistryReadTrace.ContainsKey($traceKey)) {
        return [string]$script:RegistryReadTrace[$traceKey]
    }
    return "unknown"
}

function Get-PortalBaseUrl {
    $val = Get-RegistryStringValue -SubKeyPath "SOFTWARE\Trilink\RemoteAgent" -ValueName "PortalBaseUrl"
    if (-not [string]::IsNullOrWhiteSpace($val)) { return ([string]$val).TrimEnd('/') }
    return $null
}

function Get-DiscoveryToken {
    $val = Get-RegistryStringValue -SubKeyPath "SOFTWARE\Trilink\RemoteAgent" -ValueName "DiscoveryToken"
    if (-not [string]::IsNullOrWhiteSpace($val)) { return [string]$val }
    return $null
}

function Get-InstallToken {
    $script:InstallTokenReadSource = "not_found"

    $val = Get-RegistryStringValue -SubKeyPath "SOFTWARE\Trilink\RemoteAgent" -ValueName "InstallToken"
    if (-not [string]::IsNullOrWhiteSpace($val)) {
        $script:InstallTokenReadSource = "registry_$((Get-RegistryReadSource -SubKeyPath 'SOFTWARE\Trilink\RemoteAgent' -ValueName 'InstallToken').ToLowerInvariant())"
        return [string]$val
    }

    $fallbackFiles = @(
        (Join-Path $PSScriptRoot "install-token.txt"),
        "C:\Trilink\Remote\RustDesk\install-token.txt"
    ) | Select-Object -Unique

    foreach ($tokenFile in $fallbackFiles) {
        try {
            if (-not (Test-Path $tokenFile)) { continue }
            $raw = Get-Content -Path $tokenFile -Raw -ErrorAction Stop
            $fileToken = ([string]$raw).Trim()
            if (-not [string]::IsNullOrWhiteSpace($fileToken)) {
                $script:InstallTokenReadSource = "file:$tokenFile"
                return $fileToken
            }
        } catch {
            continue
        }
    }

    return $null
}

function Get-InstallTokenReadSource {
    return [string]$script:InstallTokenReadSource
}

function New-DefaultState {
    return @{
        agentToken = ""
        hostId = ""
        rebootstrapRequired = $false
        lastSysproHash = ""
        lastSoftwareHash = ""
        lastSystemHash = ""
        lastNetworkHash = ""
        lastSoftwareScanUtc = ""
        lastSystemSnapshotUtc = ""
        lastFullSnapshotDate = ""
        consecutiveFailures = 0
    }
}

function To-Bool {
    param($Value)
    if ($Value -is [bool]) { return $Value }
    if ($null -eq $Value) { return $false }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    return ($text -match "^(?i:true|1|yes|sim)$")
}

function Load-AgentState {
    Ensure-StateDir
    if (-not (Test-Path $StateFile)) {
        return New-DefaultState
    }

    try {
        $raw = Get-Content -Raw -Path $StateFile
        $obj = $raw | ConvertFrom-Json
        $state = New-DefaultState

        if ($null -ne $obj.agentToken) { $state.agentToken = [string]$obj.agentToken }
        if ($null -ne $obj.hostId) { $state.hostId = [string]$obj.hostId }
        if ($null -ne $obj.rebootstrapRequired) { $state.rebootstrapRequired = To-Bool $obj.rebootstrapRequired }
        if ($null -ne $obj.lastSysproHash) { $state.lastSysproHash = [string]$obj.lastSysproHash }
        if ($null -ne $obj.lastSoftwareHash) { $state.lastSoftwareHash = [string]$obj.lastSoftwareHash }
        if ($null -ne $obj.lastSystemHash) { $state.lastSystemHash = [string]$obj.lastSystemHash }
        if ($null -ne $obj.lastNetworkHash) { $state.lastNetworkHash = [string]$obj.lastNetworkHash }
        if ($null -ne $obj.lastSoftwareScanUtc) { $state.lastSoftwareScanUtc = [string]$obj.lastSoftwareScanUtc }
        if ($null -ne $obj.lastSystemSnapshotUtc) { $state.lastSystemSnapshotUtc = [string]$obj.lastSystemSnapshotUtc }
        if ($null -ne $obj.lastFullSnapshotDate) { $state.lastFullSnapshotDate = [string]$obj.lastFullSnapshotDate }
        if ($null -ne $obj.consecutiveFailures) {
            $failures = 0
            [int]::TryParse([string]$obj.consecutiveFailures, [ref]$failures) | Out-Null
            $state.consecutiveFailures = [Math]::Max(0, $failures)
        }

        return $state
    } catch {
        Write-Log "Falha ao ler estado local. Estado reiniciado."
        return New-DefaultState
    }
}

function Save-AgentState {
    param([hashtable]$State)

    Ensure-StateDir
    $payload = [ordered]@{
        agentToken = [string]$State.agentToken
        hostId = [string]$State.hostId
        rebootstrapRequired = [bool]$State.rebootstrapRequired
        lastSysproHash = [string]$State.lastSysproHash
        lastSoftwareHash = [string]$State.lastSoftwareHash
        lastSystemHash = [string]$State.lastSystemHash
        lastNetworkHash = [string]$State.lastNetworkHash
        lastSoftwareScanUtc = [string]$State.lastSoftwareScanUtc
        lastSystemSnapshotUtc = [string]$State.lastSystemSnapshotUtc
        lastFullSnapshotDate = [string]$State.lastFullSnapshotDate
        consecutiveFailures = [int]$State.consecutiveFailures
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $payload | ConvertTo-Json -Depth 10 | Set-Content -Path $StateFile -Encoding utf8
}

function Is-RefreshDue {
    param(
        [string]$LastTimestampUtc,
        [int]$WindowMinutes
    )

    if ($WindowMinutes -le 0) { return $true }
    if ([string]::IsNullOrWhiteSpace($LastTimestampUtc)) { return $true }

    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$LastTimestampUtc, [ref]$parsed)) { return $true }
    $elapsed = (Get-Date).ToUniversalTime() - $parsed.ToUniversalTime()
    return ($elapsed.TotalMinutes -ge $WindowMinutes)
}

function Get-SysproUpdates {
    Write-Log "Iniciando verificacao de caminho fixo: \Syspro\Server"
    $results = @()

    $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "^[A-Za-z]$"
    })

    if (-not $drives -or $drives.Count -eq 0) {
        Write-Log "Nenhuma unidade de sistema de arquivos encontrada para verificacao."
        return $results
    }

    foreach ($drive in $drives) {
        $targetFolder = "$($drive.Name):\Syspro\Server"
        $exePath = Join-Path $targetFolder "SysproServer.exe"

        if (Test-Path $exePath) {
            try {
                $fileInfo = Get-Item $exePath
                $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)
                $clientName = "Syspro-Server-$($drive.Name)"

                $results += [ordered]@{
                    clientName = $clientName
                    installPath = $targetFolder
                    version = $versionInfo.FileVersion
                    lastUpdateUtc = $fileInfo.LastWriteTime.ToUniversalTime().ToString("o")
                    empresa = $clientName
                    caminho = $exePath
                    ultimaAtualizacao = $fileInfo.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                }
                Write-Log "Syspro detectado em: $targetFolder | versao=$($versionInfo.FileVersion)"
            } catch {
                Write-Log "Erro ao ler metadados de ${exePath}: $($_.Exception.Message)"
            }
        }
    }

    Write-Log "Verificacao concluida. Total encontrado: $($results.Count)"
    return $results
}

function Get-Sha256Hex {
    param([string]$InputText)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputText)
        $hashBytes = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-SystemSnapshot {
    param([string]$ServiceStatus)

    $snapshot = [ordered]@{
        osCaption = ""
        osVersion = ""
        osBuild = ""
        osArchitecture = ""
        totalRamMb = 0
        freeRamMb = 0
        cpuName = ""
        cpuCores = 0
        diskTotalGb = 0
        diskFreeGb = 0
        uptimeSeconds = 0
        timezone = ""
        domainOrWorkgroup = ""
        currentUser = [string]$env:USERNAME
        serviceStatus = [string]$ServiceStatus
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $snapshot.osCaption = Truncate-Text -Text ([string]$os.Caption) -MaxLength 256
        $snapshot.osVersion = Truncate-Text -Text ([string]$os.Version) -MaxLength 64
        $snapshot.osBuild = Truncate-Text -Text ([string]$os.BuildNumber) -MaxLength 32
        $snapshot.osArchitecture = Truncate-Text -Text ([string]$os.OSArchitecture) -MaxLength 64
        if ($null -ne $os.TotalVisibleMemorySize) { $snapshot.totalRamMb = [int][Math]::Round(([double]$os.TotalVisibleMemorySize / 1024.0), 0) }
        if ($null -ne $os.FreePhysicalMemory) { $snapshot.freeRamMb = [int][Math]::Round(([double]$os.FreePhysicalMemory / 1024.0), 0) }
        if ($null -ne $os.LastBootUpTime) {
            $boot = [DateTime]$os.LastBootUpTime
            $snapshot.uptimeSeconds = [int][Math]::Max(0, (New-TimeSpan -Start $boot -End (Get-Date)).TotalSeconds)
        }
    } catch {}

    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $cpu) {
            $snapshot.cpuName = Truncate-Text -Text ([string]$cpu.Name) -MaxLength 256
            if ($null -ne $cpu.NumberOfCores) { $snapshot.cpuCores = [int]$cpu.NumberOfCores }
        }
    } catch {}

    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $disk) {
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($null -ne $disk) {
            if ($null -ne $disk.Size) { $snapshot.diskTotalGb = [int][Math]::Round(([double]$disk.Size / 1GB), 0) }
            if ($null -ne $disk.FreeSpace) { $snapshot.diskFreeGb = [int][Math]::Round(([double]$disk.FreeSpace / 1GB), 0) }
        }
    } catch {}

    try {
        $tz = Get-TimeZone -ErrorAction Stop
        $snapshot.timezone = Truncate-Text -Text ([string]$tz.Id) -MaxLength 128
    } catch {}

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace([string]$cs.Domain)) {
            $snapshot.domainOrWorkgroup = Truncate-Text -Text ([string]$cs.Domain) -MaxLength 128
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$cs.Workgroup)) {
            $snapshot.domainOrWorkgroup = Truncate-Text -Text ([string]$cs.Workgroup) -MaxLength 128
        }
    } catch {}

    return $snapshot
}

function Get-NetworkSnapshot {
    $snapshot = [ordered]@{
        defaultGateway = ""
        dnsServers = @()
        adapters = @()
    }

    $hasModernNetCmdlets = $null -ne (Get-Command Get-NetRoute -ErrorAction SilentlyContinue)
    if (-not $hasModernNetCmdlets) {
        try {
            if ($null -ne (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
                $nics = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction Stop
            } else {
                $nics = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction Stop
            }
            foreach ($nic in $nics) {
                if ($nic.IPAddress -and $nic.IPAddress.Count -gt 0) {
                    $snapshot.adapters += [ordered]@{
                        alias = Truncate-Text -Text ([string]$nic.Description) -MaxLength 128
                        ip = [string]$nic.IPAddress[0]
                        prefix = 0
                    }
                }
                if ($nic.DefaultIPGateway -and [string]::IsNullOrWhiteSpace($snapshot.defaultGateway)) {
                    $snapshot.defaultGateway = [string]$nic.DefaultIPGateway[0]
                }
                if ($nic.DNSServerSearchOrder) {
                    $snapshot.dnsServers += @($nic.DNSServerSearchOrder | Select-Object -First 3 | ForEach-Object { [string]$_ })
                }
            }
            if ($snapshot.dnsServers.Count -gt 0) {
                $snapshot.dnsServers = @($snapshot.dnsServers | Select-Object -Unique | Select-Object -First 6)
            }
        } catch {}
        return $snapshot
    }

    try {
        $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction Stop |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1
        if ($null -ne $route -and -not [string]::IsNullOrWhiteSpace([string]$route.NextHop)) {
            $snapshot.defaultGateway = [string]$route.NextHop
        }
    } catch {}

    try {
        $dns = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.ServerAddresses -and $_.ServerAddresses.Count -gt 0 } |
            ForEach-Object { $_.ServerAddresses } |
            Select-Object -Unique
        if ($dns) { $snapshot.dnsServers = @($dns | ForEach-Object { [string]$_ } | Select-Object -First 6) }
    } catch {}

    try {
        $adapters = @()
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -and $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" }
        foreach ($ip in $ips) {
            $adapters += [ordered]@{
                alias = Truncate-Text -Text ([string]$ip.InterfaceAlias) -MaxLength 128
                ip = [string]$ip.IPAddress
                prefix = [int]$ip.PrefixLength
            }
        }
        if ($adapters.Count -gt 0) {
            $snapshot.adapters = @($adapters | Select-Object -First 12)
        }
    } catch {}

    return $snapshot
}

function Get-InstalledSoftwareSnapshot {
    param([int]$MaxItems = 200)

    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $list = @()
    foreach ($path in $paths) {
        try {
            $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
            foreach ($it in $items) {
                $name = [string]$it.DisplayName
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $list += [ordered]@{
                    name = Truncate-Text -Text $name -MaxLength 256
                    version = Truncate-Text -Text ([string]$it.DisplayVersion) -MaxLength 64
                    publisher = Truncate-Text -Text ([string]$it.Publisher) -MaxLength 256
                    installDate = Truncate-Text -Text ([string]$it.InstallDate) -MaxLength 32
                    installLocation = Truncate-Text -Text ([string]$it.InstallLocation) -MaxLength 512
                }
            }
        } catch {}
    }

    $seen = @{}
    $deduped = @()
    foreach ($item in $list) {
        $key = "$($item.name)|$($item.version)|$($item.publisher)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $deduped += $item
        }
    }

    return @($deduped | Sort-Object { [string]$_.name } | Select-Object -First $MaxItems)
}

function New-AgentMetrics {
    param(
        [System.Diagnostics.Stopwatch]$CycleStopwatch,
        [hashtable]$PhaseTimings,
        [hashtable]$SelfHeal,
        [string]$ScriptVersion
    )

    return [ordered]@{
        cycleElapsedMs = [int]$CycleStopwatch.ElapsedMilliseconds
        phaseTimings = $PhaseTimings
        psVersion = [string]$PSVersionTable.PSVersion.ToString()
        scriptVersion = [string]$ScriptVersion
        selfHealAttempted = [bool]$SelfHeal.selfHealAttempted
        selfHealResult = [string]$SelfHeal.selfHealResult
    }
}

function Get-HttpStatusCodeFromException {
    param([System.Exception]$Exception)

    if ($null -eq $Exception) { return $null }
    if ($Exception.PSObject.Properties.Match("Response").Count -eq 0) { return $null }
    if ($null -eq $Exception.Response) { return $null }
    if ($Exception.Response.PSObject.Properties.Match("StatusCode").Count -eq 0) { return $null }

    $statusCode = $Exception.Response.StatusCode
    if ($statusCode -is [int]) { return $statusCode }
    if ($statusCode.PSObject.Properties.Match("value__").Count -gt 0) {
        return [int]$statusCode.value__
    }
    return $null
}

function ConvertFrom-JsonSafe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return $Text | ConvertFrom-Json } catch { return $null }
}

function Get-ObjectPropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $null }

    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $null
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-NestedPropertyValue {
    param(
        [object]$Object,
        [string[]]$Path
    )

    $current = $Object
    foreach ($segment in $Path) {
        $current = Get-ObjectPropertyValue -Object $current -Name $segment
        if ($null -eq $current) { return $null }
    }
    return $current
}

function Normalize-ApiData {
    param([object]$Body)
    $data = Get-ObjectPropertyValue -Object $Body -Name "data"
    if ($null -ne $data) { return $data }
    return $Body
}

function Get-DiscoverSummary {
    param([object]$DiscoverData)

    $mode = [string](Get-ObjectPropertyValue -Object $DiscoverData -Name "mode")
    $flow = [string](Get-ObjectPropertyValue -Object $DiscoverData -Name "bootstrapFlow")
    if ([string]::IsNullOrWhiteSpace($flow)) {
        $flow = [string](Get-NestedPropertyValue -Object $DiscoverData -Path @("transition", "bootstrapFlow"))
    }
    $allow = To-Bool (Get-NestedPropertyValue -Object $DiscoverData -Path @("transition", "allowDiscoveryHeartbeat"))
    $nextEndpoint = [string](Get-NestedPropertyValue -Object $DiscoverData -Path @("transition", "nextEndpoint"))
    if ([string]::IsNullOrWhiteSpace($nextEndpoint)) {
        $nextEndpoint = [string](Get-ObjectPropertyValue -Object $DiscoverData -Name "nextEndpoint")
    }

    return [ordered]@{
        mode = $mode
        bootstrapFlow = $flow
        allowDiscoveryHeartbeat = $allow
        nextEndpoint = $nextEndpoint
    }
}

function Post-JsonWithRetry {
    param(
        [string]$Url,
        [hashtable]$Payload,
        [int]$MaxAttempts = 4,
        [string]$Operation = "http"
    )

    $json = $Payload | ConvertTo-Json -Depth 20
    $jsonBytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
    $backoffSeconds = @(0, 3, 10, 25)
    $headers = @{
        "Accept" = "application/json"
        "Accept-Encoding" = "gzip, deflate"
        "Cache-Control" = "no-cache"
    }
    Write-Log "http request op=$Operation url=$Url payloadBytes=$jsonBytes maxAttempts=$MaxAttempts"

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Method Post `
                -Uri $Url `
                -Headers $headers `
                -ContentType "application/json; charset=utf-8" `
                -Body $json `
                -TimeoutSec 25 `
                -UseBasicParsing

            $statusCode = [int]$response.StatusCode
            $body = ConvertFrom-JsonSafe -Text ([string]$response.Content)
            $statusClass = [math]::Floor($statusCode / 100)
            $bodyKeys = Get-TopLevelKeys -Object $body
            Write-Log "http response op=$Operation status=$statusCode attempt=$attempt/$MaxAttempts bodyKeys=$bodyKeys"

            if ($statusClass -eq 2) {
                if ($null -eq $body) {
                    $raw = [string]$response.Content
                    $preview = if ($raw.Length -gt 220) { $raw.Substring(0, 220) } else { $raw }
                    $preview = $preview -replace "(\r|\n)+", " "
                    $contentType = [string]$response.Headers["Content-Type"]
                    Write-Log "http response op=$Operation body_parse_failed contentType=$contentType preview=$preview"
                    if ($attempt -lt $MaxAttempts) {
                        $sleep = 2
                        Write-Log "http retry op=$Operation reason=body_parse_failed delay=${sleep}s"
                        Start-Sleep -Seconds $sleep
                        continue
                    }
                    return [ordered]@{
                        ok = $false
                        statusCode = $statusCode
                        body = $null
                        error = "BODY_PARSE_FAILED"
                        attempts = $attempt
                    }
                }
                return [ordered]@{
                    ok = $true
                    statusCode = $statusCode
                    body = $body
                    error = ""
                    attempts = $attempt
                }
            }

            $shouldRetry = (($statusCode -eq 429) -or ($statusCode -ge 500))
            if ($shouldRetry -and $attempt -lt $MaxAttempts) {
                $sleep = $backoffSeconds[[Math]::Min($attempt, $backoffSeconds.Count - 1)]
                Write-Log "http retry op=$Operation reason=status_$statusCode delay=${sleep}s"
                Start-Sleep -Seconds $sleep
                continue
            }

            return [ordered]@{
                ok = $false
                statusCode = $statusCode
                body = $body
                error = "HTTP $statusCode"
                attempts = $attempt
            }
        } catch {
            $statusCode = Get-HttpStatusCodeFromException -Exception $_.Exception
            $errorMessage = $_.Exception.Message
            $errBody = $null
            if ($null -ne $_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
                $errBody = ConvertFrom-JsonSafe -Text $_.ErrorDetails.Message
            }

            if ($statusCode) {
                Write-Log "http error op=$Operation status=$statusCode attempt=$attempt/$MaxAttempts message=$errorMessage"
            } else {
                Write-Log "http error op=$Operation status=network attempt=$attempt/$MaxAttempts message=$errorMessage"
            }

            $shouldRetry = (($statusCode -eq $null) -or ($statusCode -eq 429) -or ($statusCode -ge 500))
            if ($shouldRetry -and $attempt -lt $MaxAttempts) {
                $sleep = $backoffSeconds[[Math]::Min($attempt, $backoffSeconds.Count - 1)]
                Write-Log "http retry op=$Operation reason=transient delay=${sleep}s"
                Start-Sleep -Seconds $sleep
                continue
            }

            return [ordered]@{
                ok = $false
                statusCode = $statusCode
                body = $errBody
                error = $errorMessage
                attempts = $attempt
            }
        }
    }

    return [ordered]@{
        ok = $false
        statusCode = $null
        body = $null
        error = "max_attempts_exceeded"
        attempts = $MaxAttempts
    }
}

function Extract-CommandQueue {
    param([object]$SyncData)

    $raw = Get-ObjectPropertyValue -Object $SyncData -Name "commandQueue"
    if ($null -eq $raw) { return @() }

    $queue = @()
    if (($raw -is [System.Collections.IEnumerable]) -and (-not ($raw -is [string]))) {
        foreach ($cmd in $raw) {
            $queue += ,$cmd
        }
        return $queue
    }

    $queue += ,$raw
    return $queue
}

function Execute-RemoteCommand {
    param(
        [object]$Command,
        [hashtable]$State
    )

    $cmdType = [string](Get-ObjectPropertyValue -Object $Command -Name "type")
    if ([string]::IsNullOrWhiteSpace($cmdType)) {
        $cmdType = [string](Get-ObjectPropertyValue -Object $Command -Name "commandType")
    }

    $result = [ordered]@{
        status = "ACKNOWLEDGED"
        message = "Comando processado."
        details = [ordered]@{
            commandType = $cmdType
            executedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            executed = $false
            invalidateTokenAfterAck = $false
        }
    }

    switch ($cmdType.ToUpperInvariant()) {
        "REAPPLY_ALIAS" {
            $result.message = "REAPPLY_ALIAS recebido; sem acao local no agente."
            break
        }
        "REAPPLY_CONFIG" {
            $result.message = "REAPPLY_CONFIG recebido; sem acao local no agente."
            break
        }
        "UPGRADE_CLIENT" {
            $result.message = "UPGRADE_CLIENT recebido; execucao remota nao implementada neste agente."
            break
        }
        "ROTATE_TOKEN_REQUIRED" {
            $result.message = "ROTATE_TOKEN_REQUIRED recebido; token local invalidado para rebootstrap."
            $result.details.executed = $true
            $result.details.invalidateTokenAfterAck = $true
            break
        }
        default {
            $result.message = "Comando desconhecido tratado sem execucao local."
            break
        }
    }

    return $result
}

function Mark-FailureAndSave {
    param([hashtable]$State)
    $State.consecutiveFailures = [int]$State.consecutiveFailures + 1
    Save-AgentState -State $State
}

try {
    $tls13 = [Net.SecurityProtocolType]::Tls13
    [Net.ServicePointManager]::SecurityProtocol = $tls13 -bor [Net.SecurityProtocolType]::Tls12
} catch {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {}
}

$state = New-DefaultState

try {
    $cycleId = ([Guid]::NewGuid().ToString("N")).Substring(0, 10)
    $cycleWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $phaseTimings = @{}
    $scriptVersion = Get-ScriptVersionId
    Write-Log "cycle start id=$cycleId computer=$env:COMPUTERNAME user=$env:USERNAME ps=$($PSVersionTable.PSVersion.ToString()) script=$PSCommandPath"
    $lockAcquired = Acquire-RunLock
    if (-not $lockAcquired) {
        Write-Log "Decision=cycle_skipped_lock_busy id=$cycleId user=$env:USERNAME"
        return
    }
    Write-Log "run lock acquired id=$cycleId mutex=Global\TrilinkRemoteAgentMutex"
    Remove-OldLogs -DaysToKeep 10
    Rotate-LogIfNeeded -FilePath $LogFile -MaxSizeKb 2048
    Rotate-LogIfNeeded -FilePath $DebugLogFile -MaxSizeKb 4096
    $state = Load-AgentState
    Write-Log "state loaded id=$cycleId failures=$($state.consecutiveFailures) hasAgentToken=$(-not [string]::IsNullOrWhiteSpace($state.agentToken)) hostId=$($state.hostId) rebootstrapRequired=$($state.rebootstrapRequired) lastSnapshotDate=$($state.lastFullSnapshotDate)"

    Apply-StartupJitter -MaxSeconds 60

    $persistentDelay = Get-PersistentBackoffSeconds -ConsecutiveFailures $state.consecutiveFailures
    if ($persistentDelay -gt 0) {
        Write-Log "Backoff persistente aplicado (${persistentDelay}s) por $($state.consecutiveFailures) falhas consecutivas."
        Start-Sleep -Seconds $persistentDelay
    }

    $portalBaseUrl = Get-PortalBaseUrl
    $portalReadSource = Get-RegistryReadSource -SubKeyPath "SOFTWARE\Trilink\RemoteAgent" -ValueName "PortalBaseUrl"
    if ([string]::IsNullOrWhiteSpace($portalBaseUrl)) {
        Write-Log "PortalBaseUrl ausente no Registry ($RegPath). Fonte: $portalReadSource."
        exit 1
    }

    $discoveryToken = Get-DiscoveryToken
    $tokenReadSource = Get-RegistryReadSource -SubKeyPath "SOFTWARE\Trilink\RemoteAgent" -ValueName "DiscoveryToken"
    if ([string]::IsNullOrWhiteSpace($discoveryToken)) {
        Write-Log "DiscoveryToken ausente no Registry ($RegPath). Fonte: $tokenReadSource."
        exit 1
    }

    $installToken = Get-InstallToken
    $installReadSource = Get-InstallTokenReadSource

    Write-Log "PortalBaseUrl lido via $portalReadSource."
    Write-Log "DiscoveryToken lido via $tokenReadSource."
    if ($discoveryToken -like "rhost_*") {
        throw "DiscoveryToken invalido (parece InstallToken)."
    }
    if (-not [string]::IsNullOrWhiteSpace($installToken) -and ($installToken -notlike "rhost_*")) {
        throw "InstallToken invalido (esperado prefixo rhost_)."
    }
    if ([string]::IsNullOrWhiteSpace($installToken)) {
        Write-Log "InstallToken ausente (fonte $installReadSource). Bootstrap automatico pode ser bloqueado."
    } else {
        Write-Log "InstallToken lido via $installReadSource mask=$(Mask-Secret -Value $installToken)"
    }

    $selfHeal = Try-RecoverRustDeskService
    if ($selfHeal.selfHealAttempted) {
        Write-Log "Self-healing: before=$($selfHeal.serviceStatusBefore) result=$($selfHeal.selfHealResult) after=$($selfHeal.serviceStatusAfter)"
    }

    $rustdeskId = Get-RustDeskId
    if ([string]::IsNullOrWhiteSpace($rustdeskId)) {
        throw "RustDesk ID vazio."
    }
    if ($rustdeskId -notmatch "^\d{7,12}$") {
        throw "RustDesk ID invalido: $rustdeskId"
    }

    $sysproUpdatesFull = @(Get-SysproUpdates)
    $sysproJson = $sysproUpdatesFull | ConvertTo-Json -Depth 10 -Compress
    $sysproHash = Get-Sha256Hex -InputText $sysproJson
    $todayUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")

    $sendFullSnapshot = $false
    if ([string]::IsNullOrWhiteSpace($state.lastSysproHash)) { $sendFullSnapshot = $true }
    if ($state.lastSysproHash -ne $sysproHash) { $sendFullSnapshot = $true }
    if ($state.lastFullSnapshotDate -ne $todayUtc) { $sendFullSnapshot = $true }

    $sysproUpdatesToSend = @()
    if ($sendFullSnapshot) {
        $sysproUpdatesToSend = $sysproUpdatesFull
        Write-Log "sysproUpdates: enviando snapshot completo. count=$($sysproUpdatesToSend.Count) hash=$sysproHash today=$todayUtc"
    } else {
        Write-Log "sysproUpdates: sem mudanca, enviando array vazio. hash=$sysproHash previous=$($state.lastSysproHash)"
    }

    $discoverPayload = @{
        discoveryToken = $discoveryToken
        rustdeskId = $rustdeskId
        machineName = $env:COMPUTERNAME
        agentVersion = $AgentVersion
        serviceStatus = [string]$selfHeal.serviceStatusAfter
        serviceStatusBefore = [string]$selfHeal.serviceStatusBefore
        selfHealAttempted = [bool]$selfHeal.selfHealAttempted
        selfHealResult = [string]$selfHeal.selfHealResult
        serviceStatusAfter = [string]$selfHeal.serviceStatusAfter
        sysproUpdates = $sysproUpdatesToSend
    }

    $discoverUrl = "$portalBaseUrl/api/remote/agents/discover"
    Write-Log "discover request: rustdeskId=$rustdeskId machine=$env:COMPUTERNAME serviceAfter=$($selfHeal.serviceStatusAfter) updatesCount=$($sysproUpdatesToSend.Count)"
    $phaseDiscoverSw = [System.Diagnostics.Stopwatch]::StartNew()
    $discover = Post-JsonWithRetry -Url $discoverUrl -Payload $discoverPayload -Operation "discover"
    $phaseTimings.discover = [int]$phaseDiscoverSw.ElapsedMilliseconds
    if (-not $discover.ok) {
        Write-Log "Decision=discover_failed status=$($discover.statusCode) error=$($discover.error)"
        Mark-FailureAndSave -State $state
        return
    }

    $discoverData = Normalize-ApiData -Body $discover.body
    $summary = Get-DiscoverSummary -DiscoverData $discoverData
    Write-Log "discover response: mode=$($summary.mode) bootstrapFlow=$($summary.bootstrapFlow) allowDiscoveryHeartbeat=$($summary.allowDiscoveryHeartbeat) nextEndpoint=$($summary.nextEndpoint)"

    if ($summary.bootstrapFlow -eq "pending_link") {
        Write-Log "Decision=triagem (pending_link). Sem bootstrap/sync neste ciclo."
        if ($sendFullSnapshot) {
            $state.lastSysproHash = $sysproHash
            $state.lastFullSnapshotDate = $todayUtc
        }
        $state.consecutiveFailures = 0
        Save-AgentState -State $state
        return
    }

    $agentToken = [string]$state.agentToken
    if ($state.rebootstrapRequired) {
        Write-Log "Estado local exige rebootstrap; token atual sera ignorado."
        $agentToken = ""
    }

    $needsBootstrap = $false
    if ([string]::IsNullOrWhiteSpace($agentToken)) { $needsBootstrap = $true }
    if ($summary.bootstrapFlow -eq "host_bootstrap_required") { $needsBootstrap = $true }

    if ($needsBootstrap) {
        if ([string]::IsNullOrWhiteSpace($installToken)) {
            Write-Log "Decision=triagem_await_install_token (bootstrap bloqueado; aguardando InstallToken para continuar)."
            if ($sendFullSnapshot) {
                $state.lastSysproHash = $sysproHash
                $state.lastFullSnapshotDate = $todayUtc
            }
            $state.consecutiveFailures = 0
            Save-AgentState -State $state
            return
        }

        Write-Log "Decision=bootstrap (flow=$($summary.bootstrapFlow))."
        $bootstrapPayload = @{
            installToken = $installToken
            rustdeskId = $rustdeskId
            machineName = $env:COMPUTERNAME
            agentVersion = $AgentVersion
            environment = "Producao"
        }

        $bootstrapUrl = "$portalBaseUrl/api/remote/rustdesk/bootstrap"
        Write-Log "bootstrap request: rustdeskId=$rustdeskId machine=$env:COMPUTERNAME installTokenMask=$(Mask-Secret -Value $installToken)"
        $phaseBootstrapSw = [System.Diagnostics.Stopwatch]::StartNew()
        $bootstrap = Post-JsonWithRetry -Url $bootstrapUrl -Payload $bootstrapPayload -Operation "bootstrap"
        $phaseTimings.bootstrap = [int]$phaseBootstrapSw.ElapsedMilliseconds
        if (-not $bootstrap.ok) {
            if ($bootstrap.statusCode -eq 401 -or $bootstrap.statusCode -eq 403) {
                $state.agentToken = ""
                $state.rebootstrapRequired = $true
                Write-Log "bootstrap retornou $($bootstrap.statusCode). Estado marcado como rebootstrapRequired."
            }
            Write-Log "Decision=bootstrap_failed status=$($bootstrap.statusCode) error=$($bootstrap.error)"
            Mark-FailureAndSave -State $state
            return
        }

        $bootstrapData = Normalize-ApiData -Body $bootstrap.body
        $agentTokenFromApi = [string](Get-ObjectPropertyValue -Object $bootstrapData -Name "agentToken")
        if ([string]::IsNullOrWhiteSpace($agentTokenFromApi)) {
            $agentTokenFromApi = [string](Get-ObjectPropertyValue -Object $bootstrapData -Name "token")
        }
        if ([string]::IsNullOrWhiteSpace($agentTokenFromApi)) {
            $agentTokenFromApi = [string](Get-NestedPropertyValue -Object $bootstrap.body -Path @("data", "agentToken"))
        }
        if ([string]::IsNullOrWhiteSpace($agentTokenFromApi)) {
            Write-Log "Decision=bootstrap_failed_missing_token"
            Mark-FailureAndSave -State $state
            return
        }

        $state.agentToken = $agentTokenFromApi
        $state.rebootstrapRequired = $false
        $hostIdFromBootstrap = [string](Get-ObjectPropertyValue -Object $bootstrapData -Name "hostId")
        if (-not [string]::IsNullOrWhiteSpace($hostIdFromBootstrap)) {
            $state.hostId = $hostIdFromBootstrap
        }
        $agentToken = $agentTokenFromApi
        Write-Log "bootstrap concluido com sucesso. agentTokenMask=$(Mask-Secret -Value $agentToken) hostId=$($state.hostId)"
    } else {
        Write-Log "Decision=sync_direto (token local reutilizado mask=$(Mask-Secret -Value $agentToken))."
    }

    $softwareSnapshotHash = [string]$state.lastSoftwareHash
    $softwareSnapshotChanged = $false
    $softwareSnapshotToSend = @()
    $softwareScanPerformed = $false
    $softwareScanDue = ([string]::IsNullOrWhiteSpace($state.lastSoftwareHash) -or (Is-RefreshDue -LastTimestampUtc $state.lastSoftwareScanUtc -WindowMinutes 360))
    if ($softwareScanDue) {
        $softwareSnapshotFull = Get-InstalledSoftwareSnapshot -MaxItems 200
        $softwareSnapshotJson = $softwareSnapshotFull | ConvertTo-Json -Depth 6 -Compress
        $softwareSnapshotHash = Get-Sha256Hex -InputText $softwareSnapshotJson
        $softwareSnapshotChanged = ($state.lastSoftwareHash -ne $softwareSnapshotHash)
        $softwareSnapshotToSend = if ($softwareSnapshotChanged) { $softwareSnapshotFull } else { @() }
        $softwareScanPerformed = $true
        Write-Log "softwareSnapshot: scan_due=true changed=$softwareSnapshotChanged count=$($softwareSnapshotToSend.Count)"
    } else {
        Write-Log "softwareSnapshot: scan_due=false changed=false count=0"
    }

    $systemSnapshotFull = Get-SystemSnapshot -ServiceStatus ([string]$selfHeal.serviceStatusAfter)
    $systemStaticFields = [ordered]@{
        osCaption = [string]$systemSnapshotFull.osCaption
        osVersion = [string]$systemSnapshotFull.osVersion
        osBuild = [string]$systemSnapshotFull.osBuild
        osArchitecture = [string]$systemSnapshotFull.osArchitecture
        totalRamMb = [int]$systemSnapshotFull.totalRamMb
        cpuName = [string]$systemSnapshotFull.cpuName
        cpuCores = [int]$systemSnapshotFull.cpuCores
        diskTotalGb = [int]$systemSnapshotFull.diskTotalGb
        timezone = [string]$systemSnapshotFull.timezone
        domainOrWorkgroup = [string]$systemSnapshotFull.domainOrWorkgroup
    }
    $systemSnapshotJson = $systemStaticFields | ConvertTo-Json -Depth 3 -Compress
    $systemSnapshotHash = Get-Sha256Hex -InputText $systemSnapshotJson
    $systemRefreshDue = Is-RefreshDue -LastTimestampUtc $state.lastSystemSnapshotUtc -WindowMinutes 30
    $systemSnapshotChanged = (($state.lastSystemHash -ne $systemSnapshotHash) -or $systemRefreshDue)
    $systemSnapshotToSend = if ($systemSnapshotChanged) { $systemSnapshotFull } else { $null }
    Write-Log "systemSnapshot: changed=$systemSnapshotChanged refreshDue=$systemRefreshDue osBuild=$($systemSnapshotFull.osBuild) diskFreeGb=$($systemSnapshotFull.diskFreeGb)"

    $networkSnapshotFull = Get-NetworkSnapshot
    $networkSnapshotJson = $networkSnapshotFull | ConvertTo-Json -Depth 4 -Compress
    $networkSnapshotHash = Get-Sha256Hex -InputText $networkSnapshotJson
    $networkSnapshotChanged = ($state.lastNetworkHash -ne $networkSnapshotHash)
    $networkSnapshotToSend = if ($networkSnapshotChanged) { $networkSnapshotFull } else { $null }
    Write-Log "networkSnapshot: changed=$networkSnapshotChanged adapters=$($networkSnapshotFull.adapters.Count)"

    $metricsPreSync = New-AgentMetrics -CycleStopwatch $cycleWatch -PhaseTimings $phaseTimings -SelfHeal $selfHeal -ScriptVersion $scriptVersion

    $syncPayload = @{
        agentToken = $agentToken
        rustdeskId = $rustdeskId
        machineName = $env:COMPUTERNAME
        agentVersion = $AgentVersion
        serviceStatus = [string]$selfHeal.serviceStatusAfter
        sysproUpdates = $sysproUpdatesToSend
        systemSnapshot = $systemSnapshotToSend
        networkSnapshot = $networkSnapshotToSend
        softwareSnapshot = $softwareSnapshotToSend
        agentMetrics = $metricsPreSync
    }

    $syncUrl = "$portalBaseUrl/api/remote/rustdesk/sync"
    Write-Log "sync request: rustdeskId=$rustdeskId machine=$env:COMPUTERNAME tokenMask=$(Mask-Secret -Value $agentToken) updatesCount=$($sysproUpdatesToSend.Count)"
    $phaseSyncSw = [System.Diagnostics.Stopwatch]::StartNew()
    $sync = Post-JsonWithRetry -Url $syncUrl -Payload $syncPayload -Operation "sync"
    $phaseTimings.sync = [int]$phaseSyncSw.ElapsedMilliseconds
    if (-not $sync.ok) {
        if ($sync.statusCode -eq 401 -or $sync.statusCode -eq 403) {
            $state.agentToken = ""
            $state.rebootstrapRequired = $true
            Write-Log "sync retornou $($sync.statusCode). Token limpo e rebootstrap marcado."
        }
        Write-Log "Decision=sync_failed status=$($sync.statusCode) error=$($sync.error)"
        Mark-FailureAndSave -State $state
        return
    }

    $syncData = Normalize-ApiData -Body $sync.body
    $hostIdFromSync = [string](Get-ObjectPropertyValue -Object $syncData -Name "hostId")
    if (-not [string]::IsNullOrWhiteSpace($hostIdFromSync)) {
        $state.hostId = $hostIdFromSync
    }

    $queue = Extract-CommandQueue -SyncData $syncData
    Write-Log "sync OK. commandQueue=$($queue.Count)"

    $phaseAckTotal = 0
    foreach ($cmd in $queue) {
        $commandId = [string](Get-ObjectPropertyValue -Object $cmd -Name "id")
        if ([string]::IsNullOrWhiteSpace($commandId)) {
            $commandId = [string](Get-ObjectPropertyValue -Object $cmd -Name "commandId")
        }
        if ([string]::IsNullOrWhiteSpace($commandId)) {
            Write-Log "Comando sem id ignorado no ack."
            continue
        }

        $exec = Execute-RemoteCommand -Command $cmd -State $state
        $ackPayload = @{
            agentToken = [string]$state.agentToken
            commandId = $commandId
            status = [string]$exec.status
            message = [string]$exec.message
            details = $exec.details
        }

        $ackUrl = "$portalBaseUrl/api/remote/rustdesk/ack"
        Write-Log "ack request: commandId=$commandId status=$($exec.status) tokenMask=$(Mask-Secret -Value $state.agentToken)"
        $phaseAckSw = [System.Diagnostics.Stopwatch]::StartNew()
        $ack = Post-JsonWithRetry -Url $ackUrl -Payload $ackPayload -Operation "ack"
        $phaseAckTotal += [int]$phaseAckSw.ElapsedMilliseconds
        if (-not $ack.ok) {
            if ($ack.statusCode -eq 401 -or $ack.statusCode -eq 403) {
                $state.agentToken = ""
                $state.rebootstrapRequired = $true
                Write-Log "ack $commandId retornou $($ack.statusCode). Token limpo para rebootstrap."
            }
            Write-Log "Decision=ack_failed commandId=$commandId status=$($ack.statusCode) error=$($ack.error)"
        } else {
            Write-Log "Decision=ack_sent commandId=$commandId status=$($exec.status)"
        }

        if (To-Bool $exec.details.invalidateTokenAfterAck) {
            $state.agentToken = ""
            $state.rebootstrapRequired = $true
            Write-Log "Decision=rebootstrap_required_after_ack commandId=$commandId"
        }
    }
    $phaseTimings.ack = [int]$phaseAckTotal
    $phaseTimings.ackCount = [int]$queue.Count
    Write-Log "ack loop: commands=$($queue.Count) totalMs=$phaseAckTotal"

    if ($sendFullSnapshot) {
        $state.lastSysproHash = $sysproHash
        $state.lastFullSnapshotDate = $todayUtc
    }
    if ($softwareSnapshotChanged) { $state.lastSoftwareHash = $softwareSnapshotHash }
    if ($systemSnapshotChanged) { $state.lastSystemHash = $systemSnapshotHash }
    if ($networkSnapshotChanged) { $state.lastNetworkHash = $networkSnapshotHash }
    if ($softwareScanPerformed) { $state.lastSoftwareScanUtc = (Get-Date).ToUniversalTime().ToString("o") }
    if ($systemSnapshotChanged) { $state.lastSystemSnapshotUtc = (Get-Date).ToUniversalTime().ToString("o") }
    Write-Log "cycle timings: discover=$($phaseTimings['discover'])ms bootstrap=$($phaseTimings['bootstrap'])ms sync=$($phaseTimings['sync'])ms ack=$($phaseTimings['ack'])ms total=$($cycleWatch.ElapsedMilliseconds)ms"
    $state.consecutiveFailures = 0
    Save-AgentState -State $state
    Write-Log "cycle success id=$cycleId hostId=$($state.hostId) hasAgentToken=$(-not [string]::IsNullOrWhiteSpace($state.agentToken)) snapshotDate=$($state.lastFullSnapshotDate)"
} catch {
    Mark-FailureAndSave -State $state
    Write-Log "cycle failure message=$($_.Exception.Message)"
} finally {
    Release-RunLock
}
