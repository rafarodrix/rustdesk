$ErrorActionPreference = "Stop"

$installedRoot = "C:\Trilink\Remote\RustDesk"
$legacyAgentPath = Join-Path $installedRoot "trilink-agente.ps1"
$modularAgentPath = Join-Path $installedRoot "remote-agent\trilink-agente.ps1"
$modularSysproPath = Join-Path $installedRoot "remote-agent\providers\syspro.ps1"
$logPath = "C:\Trilink\Remote\Logs\agentRemote.log"

function Backup-File {
    param([Parameter(Mandatory = $true)][string]$Path)
    $backupPath = "$Path.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item -Path $Path -Destination $backupPath -Force
    Write-Host "Backup criado em: $backupPath"
}

function Assert-ParseOk {
    param([Parameter(Mandatory = $true)][string]$Path)
    $tokens = $null
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs) | Out-Null
    if ($errs -and $errs.Count -gt 0) {
        Write-Host "Erros de parse encontrados em ${Path}:"
        $errs | ForEach-Object { Write-Host "- $($_.Message)" }
        throw "Parse do script falhou: $Path"
    }
}

function Update-ModularSyspro {
    param([Parameter(Mandatory = $true)][string]$Path)
    $newModule = @'
function Get-SysproChangelogVersion {
    param([string]$InstallPath)
    try {
        $changelogPath = Join-Path $InstallPath "Update\change-log.txt"
        if (-not (Test-Path $changelogPath)) {
            Write-Log "changelog nao encontrado: $changelogPath"
            return ""
        }

        $content = $null
        try {
            $content = Get-Content -Path $changelogPath -Raw -Encoding UTF8 -ErrorAction Stop
        } catch {
            try {
                $content = Get-Content -Path $changelogPath -Raw -Encoding Default -ErrorAction Stop
            } catch {}
        }

        if ([string]::IsNullOrWhiteSpace($content)) { return "" }

        $regexMatch = [regex]::Match(
            $content,
            'Revis\w*\s+Atual\s*[:\s]\s*(\d+)',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($regexMatch.Success) { return $regexMatch.Groups[1].Value.Trim() }
        return ""
    } catch {
        Write-Log "changelog erro leitura: $InstallPath | $($_.Exception.Message)"
        return ""
    }
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
                $changelogVersion = Get-SysproChangelogVersion -InstallPath $targetFolder

                $results += [ordered]@{
                    clientName = $clientName
                    installPath = $targetFolder
                    version = $versionInfo.FileVersion
                    revisaoAtual = $changelogVersion
                    lastUpdateUtc = $fileInfo.LastWriteTime.ToUniversalTime().ToString("o")
                    empresa = $clientName
                    caminho = $exePath
                    ultimaAtualizacao = $fileInfo.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                }

                Write-Log "Syspro detectado em: $targetFolder | versao=$($versionInfo.FileVersion) | revisao=$changelogVersion"
            } catch {
                Write-Log "Erro ao ler metadados de ${exePath}: $($_.Exception.Message)"
            }
        }
    }

    Write-Log "Verificacao concluida. Total encontrado: $($results.Count)"
    return $results
}
'@

    Set-Content -Path $Path -Value $newModule -Encoding UTF8
}

function Update-LegacyAgent {
    param([Parameter(Mandatory = $true)][string]$Path)
    $raw = Get-Content -Raw -Path $Path
    $start = $raw.IndexOf("function Get-SysproUpdates {")
    $end = $raw.IndexOf("function Get-Sha256Hex {")
    if ($start -lt 0 -or $end -lt 0 -or $end -le $start) {
        throw "Nao foi possivel localizar o bloco da funcao Get-SysproUpdates no legado."
    }

    $before = $raw.Substring(0, $start)
    $after = $raw.Substring($end)
    $newFunction = @'
function Get-SysproUpdates {
    Write-Log "Iniciando verificacao de caminho fixo: \\Syspro\\Server"
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
'@

    Set-Content -Path $Path -Value ($before + $newFunction + "`r`n" + $after) -Encoding UTF8
}

if (Test-Path $modularSysproPath) {
    Write-Host "Detectado agente modular. Aplicando patch em: $modularSysproPath"
    Backup-File -Path $modularSysproPath
    Update-ModularSyspro -Path $modularSysproPath
    Assert-ParseOk -Path $modularSysproPath
    $runTarget = if (Test-Path $modularAgentPath) { $modularAgentPath } else { $null }
} elseif (Test-Path $legacyAgentPath) {
    Write-Host "Detectado agente legado. Aplicando patch em: $legacyAgentPath"
    Backup-File -Path $legacyAgentPath
    Update-LegacyAgent -Path $legacyAgentPath
    Assert-ParseOk -Path $legacyAgentPath
    $runTarget = $legacyAgentPath
} else {
    throw "Nenhum agente encontrado em $installedRoot"
}

Write-Host "Parse OK."

if (Test-Path $logPath) {
    Clear-Content $logPath -ErrorAction SilentlyContinue
}

if (-not [string]::IsNullOrWhiteSpace($runTarget)) {
    powershell -NoProfile -ExecutionPolicy Bypass -File $runTarget
    Write-Host "Execucao concluida. Ultimas linhas do log:"
    Get-Content $logPath -Tail 60 -ErrorAction SilentlyContinue
} else {
    Write-Host "Patch aplicado. Execucao do agente ignorada (entrypoint nao encontrado)."
}
