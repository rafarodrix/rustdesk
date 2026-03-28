$ErrorActionPreference = "Stop"

$installedAgentPath = "C:\Trilink\Remote\RustDesk\trilink-agente.ps1"
$logPath = "C:\Trilink\Remote\Logs\agentRemote.log"

if (-not (Test-Path $installedAgentPath)) {
    throw "Arquivo nao encontrado: $installedAgentPath"
}

$backupPath = "$installedAgentPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
Copy-Item $installedAgentPath $backupPath -Force
Write-Host "Backup criado em: $backupPath"

$raw = Get-Content -Raw -Path $installedAgentPath
$start = $raw.IndexOf("function Get-SysproUpdates {")
$end = $raw.IndexOf("function Get-Sha256Hex {")

if ($start -lt 0 -or $end -lt 0 -or $end -le $start) {
    throw "Nao foi possivel localizar o bloco da funcao Get-SysproUpdates."
}

$before = $raw.Substring(0, $start)
$after = $raw.Substring($end)

$newFunction = @'
function Get-SysproUpdates {
    Write-Log "Iniciando verificacao de caminho fixo: \\Syspro\\Server"
    $results = @()

    $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^[A-Za-z]$'
    })

    if ($drives.Count -eq 0) {
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
                    clientName        = $clientName
                    installPath       = $targetFolder
                    version           = $versionInfo.FileVersion
                    lastUpdateUtc     = $fileInfo.LastWriteTime.ToUniversalTime().ToString("o")
                    empresa           = $clientName
                    caminho           = $exePath
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

Set-Content -Path $installedAgentPath -Value ($before + $newFunction + "`r`n" + $after) -Encoding UTF8
Write-Host "Funcao Get-SysproUpdates atualizada."

$tokens = $null
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile($installedAgentPath, [ref]$tokens, [ref]$errs) | Out-Null
if ($errs -and $errs.Count -gt 0) {
    Write-Host "Erros de parse encontrados:"
    $errs | ForEach-Object { Write-Host "- $($_.Message)" }
    throw "Parse do script falhou."
}

Write-Host "Parse OK."

if (Test-Path $logPath) {
    Clear-Content $logPath -ErrorAction SilentlyContinue
}

powershell -NoProfile -ExecutionPolicy Bypass -File $installedAgentPath
Write-Host "Execucao concluida. Ultimas linhas do log:"
Get-Content $logPath -Tail 60 -ErrorAction SilentlyContinue
