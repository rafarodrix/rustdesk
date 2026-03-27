$ErrorActionPreference = "Stop"

Set-StrictMode -Version Latest

$AgentVersion = "trilink-agent-v1"
$RegPath = "HKLM:\SOFTWARE\Trilink\RemoteAgent"

$StateDir = Join-Path $env:ProgramData "Trilink\RemoteAgent"
$LogFile = Join-Path $StateDir "agent.log"
$StateFile = Join-Path $StateDir "agent-state.json"

function Ensure-StateDir {
    if (-not (Test-Path $StateDir)) {
        New-Item -Path $StateDir -ItemType Directory -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Message)
    Ensure-StateDir
    $line = "$(Get-Date -Format o) | $Message"
    Add-Content -Path $LogFile -Value $line
}

function Get-RustDeskExePath {
    $local = Join-Path $PSScriptRoot "rustdesk.exe"
    if (Test-Path $local) { return $local }
    return "$env:ProgramFiles\Trilink Suporte Remoto\rustdesk.exe"
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

function Get-DiscoveryToken {
    try {
        $val = (Get-ItemProperty -Path $RegPath -Name "DiscoveryToken" -ErrorAction Stop).DiscoveryToken
        if (-not [string]::IsNullOrWhiteSpace($val)) { return [string]$val }
    } catch {}
    return $null
}

function Get-PortalBaseUrl {
    try {
        $val = (Get-ItemProperty -Path $RegPath -Name "PortalBaseUrl" -ErrorAction Stop).PortalBaseUrl
        if (-not [string]::IsNullOrWhiteSpace($val)) { return ([string]$val).TrimEnd('/') }
    } catch {}
    return $null
}

function Load-AgentState {
    Ensure-StateDir
    if (-not (Test-Path $StateFile)) {
        return @{
            lastSysproHash = ""
            lastFullSnapshotDate = ""
        }
    }

    try {
        $raw = Get-Content -Raw -Path $StateFile
        $obj = $raw | ConvertFrom-Json
        return @{
            lastSysproHash = [string]$obj.lastSysproHash
            lastFullSnapshotDate = [string]$obj.lastFullSnapshotDate
        }
    } catch {
        Write-Log "Falha ao ler estado local. Estado sera reiniciado."
        return @{
            lastSysproHash = ""
            lastFullSnapshotDate = ""
        }
    }
}

function Save-AgentState {
    param(
        [string]$LastSysproHash,
        [string]$LastFullSnapshotDate
    )

    Ensure-StateDir
    $state = [ordered]@{
        lastSysproHash = $LastSysproHash
        lastFullSnapshotDate = $LastFullSnapshotDate
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding utf8
}

function Get-SysproUpdates {
    # Placeholder: manter vazio ate integrar varredura real do inventario local.
    return @()
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

try {
    $PortalBaseUrl = Get-PortalBaseUrl
    if ([string]::IsNullOrWhiteSpace($PortalBaseUrl)) {
        Write-Log "PortalBaseUrl ausente no Registry ($RegPath). Execute o instalador novamente."
        exit 1
    }

    $DiscoveryToken = Get-DiscoveryToken
    if ([string]::IsNullOrWhiteSpace($DiscoveryToken)) {
        Write-Log "DiscoveryToken ausente no Registry ($RegPath). Execute o instalador novamente."
        exit 1
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
        serviceStatus = (Get-ServiceStatus)
        sysproUpdates = $sysproUpdatesToSend
    }

    $url = "$PortalBaseUrl/api/remote/agents/discover"
    $ok = Post-JsonWithRetry -Url $url -Payload $payload
    if ($ok) {
        if ($sendFullSnapshot) {
            Save-AgentState -LastSysproHash $sysproHash -LastFullSnapshotDate $todayUtc
        } else {
            Save-AgentState -LastSysproHash $state.lastSysproHash -LastFullSnapshotDate $state.lastFullSnapshotDate
        }
        Write-Log "Discover enviado com sucesso para $url | rustdeskId=$rustdeskId"
    } else {
        Write-Log "Discover falhou apos retries | rustdeskId=$rustdeskId"
    }
} catch {
    Write-Log "Falha no agente: $($_.Exception.Message)"
}

