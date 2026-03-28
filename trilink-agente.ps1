$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$AgentVersion = "trilink-agent-v1"
$RegPath = "HKLM:\SOFTWARE\Trilink\RemoteAgent"

$StateDir = Join-Path $env:ProgramData "Trilink\RemoteAgent"
$LogsDir = "C:\Trilink\Remote\Logs"
$LogFile = Join-Path $LogsDir "agentRemote.log"
$StateFile = Join-Path $StateDir "agent-state.json"
$script:RegistryReadTrace = @{}

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
}

function Mask-Secret {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "empty" }
    $len = $Value.Length
    if ($len -le 4) { return ("*" * $len) }
    return ("*" * ($len - 4)) + $Value.Substring($len - 4)
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

function Get-RustDeskExePath {
    $local = Join-Path $PSScriptRoot "rustdesk.exe"
    if (Test-Path $local) { return $local }
    return "C:\Trilink\Remote\RustDesk\rustdesk.exe"
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
    $val = Get-RegistryStringValue -SubKeyPath "SOFTWARE\Trilink\RemoteAgent" -ValueName "InstallToken"
    if (-not [string]::IsNullOrWhiteSpace($val)) { return [string]$val }
    return $null
}

function New-DefaultState {
    return @{
        agentToken = ""
        hostId = ""
        rebootstrapRequired = $false
        lastSysproHash = ""
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
        lastFullSnapshotDate = [string]$State.lastFullSnapshotDate
        consecutiveFailures = [int]$State.consecutiveFailures
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $payload | ConvertTo-Json -Depth 10 | Set-Content -Path $StateFile -Encoding utf8
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
    try { return $Text | ConvertFrom-Json -Depth 30 } catch { return $null }
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
    Write-Log "http request op=$Operation url=$Url payloadBytes=$jsonBytes maxAttempts=$MaxAttempts"

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Method Post `
                -Uri $Url `
                -ContentType "application/json" `
                -Body $json `
                -TimeoutSec 25 `
                -UseBasicParsing

            $statusCode = [int]$response.StatusCode
            $body = ConvertFrom-JsonSafe -Text ([string]$response.Content)
            $statusClass = [math]::Floor($statusCode / 100)
            $bodyKeys = Get-TopLevelKeys -Object $body
            Write-Log "http response op=$Operation status=$statusCode attempt=$attempt/$MaxAttempts bodyKeys=$bodyKeys"

            if ($statusClass -eq 2) {
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
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

$state = New-DefaultState

try {
    $cycleId = ([Guid]::NewGuid().ToString("N")).Substring(0, 10)
    Write-Log "cycle start id=$cycleId computer=$env:COMPUTERNAME user=$env:USERNAME ps=$($PSVersionTable.PSVersion.ToString()) script=$PSCommandPath"
    Remove-OldLogs -DaysToKeep 10
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
    $installReadSource = Get-RegistryReadSource -SubKeyPath "SOFTWARE\Trilink\RemoteAgent" -ValueName "InstallToken"

    Write-Log "PortalBaseUrl lido via $portalReadSource."
    Write-Log "DiscoveryToken lido via $tokenReadSource."
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
    $discover = Post-JsonWithRetry -Url $discoverUrl -Payload $discoverPayload -Operation "discover"
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
            Write-Log "Decision=bootstrap_blocked (InstallToken ausente)."
            Mark-FailureAndSave -State $state
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
        $bootstrap = Post-JsonWithRetry -Url $bootstrapUrl -Payload $bootstrapPayload -Operation "bootstrap"
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

    $syncPayload = @{
        agentToken = $agentToken
        rustdeskId = $rustdeskId
        machineName = $env:COMPUTERNAME
        agentVersion = $AgentVersion
        serviceStatus = [string]$selfHeal.serviceStatusAfter
        sysproUpdates = $sysproUpdatesToSend
    }

    $syncUrl = "$portalBaseUrl/api/remote/rustdesk/sync"
    Write-Log "sync request: rustdeskId=$rustdeskId machine=$env:COMPUTERNAME tokenMask=$(Mask-Secret -Value $agentToken) updatesCount=$($sysproUpdatesToSend.Count)"
    $sync = Post-JsonWithRetry -Url $syncUrl -Payload $syncPayload -Operation "sync"
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
        $ack = Post-JsonWithRetry -Url $ackUrl -Payload $ackPayload -Operation "ack"
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

    if ($sendFullSnapshot) {
        $state.lastSysproHash = $sysproHash
        $state.lastFullSnapshotDate = $todayUtc
    }
    $state.consecutiveFailures = 0
    Save-AgentState -State $state
    Write-Log "cycle success id=$cycleId hostId=$($state.hostId) hasAgentToken=$(-not [string]::IsNullOrWhiteSpace($state.agentToken)) snapshotDate=$($state.lastFullSnapshotDate)"
} catch {
    Mark-FailureAndSave -State $state
    Write-Log "cycle failure message=$($_.Exception.Message)"
}
