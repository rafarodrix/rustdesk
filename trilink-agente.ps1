$ErrorActionPreference = "Stop"

Set-StrictMode -Version Latest

$PortalBaseUrl = "https://ajuda.trilinksoftware.com.br"
$DiscoveryToken = "__SET_ME_DISCOVERY_TOKEN__"
$AgentVersion = "trilink-agent-v1"

$StateDir = Join-Path $env:ProgramData "Trilink\RemoteAgent"
$LogFile = Join-Path $StateDir "agent.log"

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
    $id = (& $exe --get-id 2>$null | Out-String).Trim()
    return ($id -replace "\s+", "")
}

function Get-ServiceStatus {
    $svc = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return "not_found" }
    if ($svc.Status -eq "Running") { return "running" }
    return "stopped"
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
    $rustdeskId = Get-RustDeskId
    if ([string]::IsNullOrWhiteSpace($rustdeskId)) {
        throw "RustDesk ID vazio."
    }

    if ([string]::IsNullOrWhiteSpace($DiscoveryToken) -or $DiscoveryToken -eq "__SET_ME_DISCOVERY_TOKEN__") {
        Write-Log "Discovery token nao configurado. Ajuste trilink-agente.ps1."
        exit 0
    }

    $payload = @{
        discoveryToken = $DiscoveryToken
        rustdeskId = $rustdeskId
        machineName = $env:COMPUTERNAME
        agentVersion = $AgentVersion
        serviceStatus = (Get-ServiceStatus)
        sysproUpdates = @()
    }

    $url = "$($PortalBaseUrl.TrimEnd('/'))/api/remote/agents/discover"
    $ok = Post-JsonWithRetry -Url $url -Payload $payload
    if ($ok) {
        Write-Log "Discover enviado com sucesso para $url | rustdeskId=$rustdeskId"
    } else {
        Write-Log "Discover falhou apos retries | rustdeskId=$rustdeskId"
    }
} catch {
    Write-Log "Falha no agente: $($_.Exception.Message)"
}

