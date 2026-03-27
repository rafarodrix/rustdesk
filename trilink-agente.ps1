$ErrorActionPreference = "Stop"

Set-StrictMode -Version Latest

$PortalBaseUrl = "https://ajuda.trilinksoftware.com.br"
$DiscoveryToken = "3dacac7beba253a33e953e6b2f970ac594c06b3152ab285e7015085b4494ee44"
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

function Post-Json {
    param(
        [string]$Url,
        [hashtable]$Payload
    )
    $json = $Payload | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Method Post -Uri $Url -ContentType "application/json" -Body $json | Out-Null
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
    Post-Json -Url $url -Payload $payload
    Write-Log "Discover enviado com sucesso para $url | rustdeskId=$rustdeskId"
} catch {
    Write-Log "Falha no agente: $($_.Exception.Message)"
}

