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

function Remove-OldLogs {
    param([int]$DaysToKeep = 10)

    try {
        if (-not (Test-Path $LogsDir)) { return }

        $limit = (Get-Date).AddDays(-$DaysToKeep)
        Get-ChildItem -Path $LogsDir -Filter "*.log" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $limit } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        # Nao bloqueia a execucao do agente por falha de limpeza.
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
            Write-Log "RustDesk ID ainda indisponivel (tentativa $attempt/$maxAttempts). Aguardando ${waitSeconds}s."
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

    if ($before -eq "running") {
        return $result
    }

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

function Get-DiscoveryToken {
    $val = Get-RegistryStringValue -SubKeyPath "SOFTWARE\Trilink\RemoteAgent" -ValueName "DiscoveryToken"
    if (-not [string]::IsNullOrWhiteSpace($val)) { return [string]$val }
    return $null
}

function Get-PortalBaseUrl {
    $val = Get-RegistryStringValue -SubKeyPath "SOFTWARE\Trilink\RemoteAgent" -ValueName "PortalBaseUrl"
    if (-not [string]::IsNullOrWhiteSpace($val)) { return ([string]$val).TrimEnd('/') }
    return $null
}

function Load-AgentState {
    Ensure-StateDir
    if (-not (Test-Path $StateFile)) {
        return @{
            lastSysproHash = ""
            lastFullSnapshotDate = ""
            consecutiveFailures = 0
        }
    }

    try {
        $raw = Get-Content -Raw -Path $StateFile
        $obj = $raw | ConvertFrom-Json
        $consecutiveFailures = 0
        if ($null -ne $obj.consecutiveFailures) {
            [int]::TryParse([string]$obj.consecutiveFailures, [ref]$consecutiveFailures) | Out-Null
        }
        return @{
            lastSysproHash = [string]$obj.lastSysproHash
            lastFullSnapshotDate = [string]$obj.lastFullSnapshotDate
            consecutiveFailures = $consecutiveFailures
        }
    } catch {
        Write-Log "Falha ao ler estado local. Estado sera reiniciado."
        return @{
            lastSysproHash = ""
            lastFullSnapshotDate = ""
            consecutiveFailures = 0
        }
    }
}

function Save-AgentState {
    param(
        [string]$LastSysproHash,
        [string]$LastFullSnapshotDate,
        [int]$ConsecutiveFailures = 0
    )

    Ensure-StateDir
    $state = [ordered]@{
        lastSysproHash = $LastSysproHash
        lastFullSnapshotDate = $LastFullSnapshotDate
        consecutiveFailures = $ConsecutiveFailures
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding utf8
}

function Get-SysproUpdates {
    Write-Log "Iniciando verificacao de caminho fixo: \\Syspro\\Server"
    $results = @()

    # Nao depende de WMI/CIM (pode falhar em algumas maquinas com "Classe invalida").
    $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^[A-Za-z]$'
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
                    # Campos atuais
                    clientName = $clientName
                    installPath = $targetFolder
                    version = $versionInfo.FileVersion
                    lastUpdateUtc = $fileInfo.LastWriteTime.ToUniversalTime().ToString("o")

                    # Campos legados para compatibilidade
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

    if ($Exception.Response.PSObject.Properties.Match("StatusCode").Count -eq 0) {
        return $null
    }

    $statusCode = $Exception.Response.StatusCode
    if ($statusCode -is [int]) { return $statusCode }
    if ($statusCode.PSObject.Properties.Match("value__").Count -gt 0) {
        return [int]$statusCode.value__
    }
    return $null
}

function Post-JsonWithRetry {
    param(
        [string]$Url,
        [hashtable]$Payload,
        [int]$MaxAttempts = 4
    )

    $json = $Payload | ConvertTo-Json -Depth 10
    $backoffSeconds = @(0, 3, 10, 25)

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Method Post `
                -Uri $Url `
                -ContentType "application/json" `
                -Body $json `
                -TimeoutSec 20 `
                -UseBasicParsing

            $code = [int]$response.StatusCode
            Write-Log "Discover HTTP $code na tentativa $attempt/$MaxAttempts."
            if ($code -ge 200 -and $code -lt 300) {
                return $true
            }

            if (($code -eq 429 -or $code -ge 500) -and $attempt -lt $MaxAttempts) {
                $sleep = $backoffSeconds[[Math]::Min($attempt, $backoffSeconds.Count - 1)]
                Write-Log "Resposta transiente ($code). Aguardando ${sleep}s para retry."
                Start-Sleep -Seconds $sleep
                continue
            }

            return $false
        } catch {
            $code = Get-HttpStatusCodeFromException -Exception $_.Exception
            $message = $_.Exception.Message
            if ($code) {
                Write-Log "Erro HTTP $code na tentativa $attempt/${MaxAttempts}: $message"
            } else {
                Write-Log "Erro de rede na tentativa $attempt/${MaxAttempts}: $message"
            }

            $shouldRetry = (($code -eq $null) -or ($code -eq 429) -or ($code -ge 500))
            if ($shouldRetry -and $attempt -lt $MaxAttempts) {
                $sleep = $backoffSeconds[[Math]::Min($attempt, $backoffSeconds.Count - 1)]
                Write-Log "Falha transiente. Aguardando ${sleep}s para retry."
                Start-Sleep -Seconds $sleep
                continue
            }

            return $false
        }
    }

    return $false
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

$state = @{
    lastSysproHash = ""
    lastFullSnapshotDate = ""
    consecutiveFailures = 0
}

try {
    Remove-OldLogs -DaysToKeep 10
    $state = Load-AgentState

    Apply-StartupJitter -MaxSeconds 60

    $persistentDelay = Get-PersistentBackoffSeconds -ConsecutiveFailures $state.consecutiveFailures
    if ($persistentDelay -gt 0) {
        Write-Log "Backoff persistente aplicado (${persistentDelay}s) devido a $($state.consecutiveFailures) falhas consecutivas."
        Start-Sleep -Seconds $persistentDelay
    }

    $PortalBaseUrl = Get-PortalBaseUrl
    $portalReadSource = Get-RegistryReadSource -SubKeyPath "SOFTWARE\Trilink\RemoteAgent" -ValueName "PortalBaseUrl"
    if ([string]::IsNullOrWhiteSpace($PortalBaseUrl)) {
        Write-Log "PortalBaseUrl ausente no Registry ($RegPath). Fonte: $portalReadSource. Execute o instalador novamente."
        exit 1
    }

    $DiscoveryToken = Get-DiscoveryToken
    $tokenReadSource = Get-RegistryReadSource -SubKeyPath "SOFTWARE\Trilink\RemoteAgent" -ValueName "DiscoveryToken"
    if ([string]::IsNullOrWhiteSpace($DiscoveryToken)) {
        Write-Log "DiscoveryToken ausente no Registry ($RegPath). Fonte: $tokenReadSource. Execute o instalador novamente."
        exit 1
    }

    Write-Log "PortalBaseUrl lido via $portalReadSource."
    Write-Log "DiscoveryToken lido via $tokenReadSource."

    $selfHeal = Try-RecoverRustDeskService
    if ($selfHeal.selfHealAttempted) {
        Write-Log "Self-healing status: before=$($selfHeal.serviceStatusBefore) result=$($selfHeal.selfHealResult) after=$($selfHeal.serviceStatusAfter)"
    }

    $rustdeskId = Get-RustDeskId
    if ([string]::IsNullOrWhiteSpace($rustdeskId)) {
        throw "RustDesk ID vazio."
    }

    $sysproUpdatesFull = @(Get-SysproUpdates)
    $sysproJson = $sysproUpdatesFull | ConvertTo-Json -Depth 10 -Compress
    $sysproHash = Get-Sha256Hex -InputText $sysproJson
    $state = Load-AgentState
    $todayUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")

    $sendFullSnapshot = $false
    if ([string]::IsNullOrWhiteSpace($state.lastSysproHash)) { $sendFullSnapshot = $true }
    if ($state.lastSysproHash -ne $sysproHash) { $sendFullSnapshot = $true }
    if ($state.lastFullSnapshotDate -ne $todayUtc) { $sendFullSnapshot = $true }

    $sysproUpdatesToSend = @()
    if ($sendFullSnapshot) {
        $sysproUpdatesToSend = $sysproUpdatesFull
        Write-Log "sysproUpdates: enviando snapshot completo (hash mudou/estado novo/rotacao diaria)."
    } else {
        Write-Log "sysproUpdates: sem mudanca, enviando array vazio."
    }

    $payload = @{
        discoveryToken = $DiscoveryToken
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

    $url = "$PortalBaseUrl/api/remote/agents/discover"
    $ok = Post-JsonWithRetry -Url $url -Payload $payload
    if ($ok) {
        if ($sendFullSnapshot) {
            Save-AgentState -LastSysproHash $sysproHash -LastFullSnapshotDate $todayUtc -ConsecutiveFailures 0
        } else {
            Save-AgentState -LastSysproHash $state.lastSysproHash -LastFullSnapshotDate $state.lastFullSnapshotDate -ConsecutiveFailures 0
        }
        Write-Log "Discover enviado com sucesso para $url | rustdeskId=$rustdeskId"
    } else {
        $nextFailures = [int]$state.consecutiveFailures + 1
        Save-AgentState -LastSysproHash $state.lastSysproHash -LastFullSnapshotDate $state.lastFullSnapshotDate -ConsecutiveFailures $nextFailures
        Write-Log "Discover falhou apos retries | rustdeskId=$rustdeskId"
    }
} catch {
    $nextFailures = [int]$state.consecutiveFailures + 1
    Save-AgentState -LastSysproHash $state.lastSysproHash -LastFullSnapshotDate $state.lastFullSnapshotDate -ConsecutiveFailures $nextFailures
    Write-Log "Falha no agente: $($_.Exception.Message)"
}

