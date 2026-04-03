; Trilink RustDesk Installer (NSIS)
; Expected defines from CI:
;   /DAPP_NAME
;   /DAPP_EXE
;   /DAPP_SOURCE_DIR
;   /DOUTFILE
;   /DAPP_VERSION (optional, defaults to Cargo version)
;   /DAPP_BUILD_DATE (optional, defaults to build timestamp)
;   /DAGENT_DIR (optional, defaults to remote-agent in repo root)
;   /DDISCOVERY_TOKEN
;   /DPORTAL_BASE_URL
;   /DINSTALL_TOKEN (usado no bootstrap autenticado)
;   /DREQUIRE_INSTALL_TOKEN (optional, 1=obrigatorio, 0=permite vazio)
;   /DRUSTDESK_PASSWORD (senha permanente inicial)
;   /DREQUIRE_RUSTDESK_PASSWORD (optional, 1=obrigatorio, 0=permite vazio)
;   /DREQUIRE_POSTCHECK_SYNC_OK (optional, 1=obrigatorio, 0=permite instalacao sem sync OK)

!ifndef APP_NAME
  !define APP_NAME "Trilink Suporte Remoto"
!endif

!ifndef APP_EXE
  !define APP_EXE "rustdesk.exe"
!endif

!ifndef APP_SOURCE_DIR
  !define APP_SOURCE_DIR "."
!endif

!ifndef OUTFILE
  !define OUTFILE "Trilink-Suporte-Installer.exe"
!endif

!ifndef APP_VERSION
  !define APP_VERSION "1.4.6"
!endif

!ifndef APP_BUILD_DATE
  !define APP_BUILD_DATE "1970-01-01 00:00"
!endif

!ifndef AGENT_DIR
  !define AGENT_DIR "remote-agent"
!endif

!ifndef DISCOVERY_TOKEN
  !define DISCOVERY_TOKEN ""
!endif

!ifndef PORTAL_BASE_URL
  !define PORTAL_BASE_URL ""
!endif

!ifndef INSTALL_TOKEN
  !define INSTALL_TOKEN ""
!endif

!ifndef REQUIRE_INSTALL_TOKEN
  !define REQUIRE_INSTALL_TOKEN "1"
!endif

!ifndef RUSTDESK_PASSWORD
  !define RUSTDESK_PASSWORD "Trilink098"
!endif

!ifndef REQUIRE_RUSTDESK_PASSWORD
  !define REQUIRE_RUSTDESK_PASSWORD "1"
!endif

!ifndef REQUIRE_POSTCHECK_SYNC_OK
  !define REQUIRE_POSTCHECK_SYNC_OK "1"
!endif

!ifndef APP_ICON
  !define APP_ICON "..\icon.ico"
!endif

Unicode true
Name "${APP_NAME}"
OutFile "${OUTFILE}"
RequestExecutionLevel admin
InstallDir "C:\Trilink\Remote\RustDesk"
InstallDirRegKey HKLM "Software\Trilink" "InstallDir"

!include "MUI2.nsh"

!define MUI_ABORTWARNING
!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}" 

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

!insertmacro MUI_LANGUAGE "PortugueseBR"

Section "Install"
  SetRegView 64
  StrCmp "${DISCOVERY_TOKEN}" "" 0 +2
  Abort "DISCOVERY_TOKEN nao informado. Recompile o instalador."
  StrCmp "${PORTAL_BASE_URL}" "" 0 +2
  Abort "PORTAL_BASE_URL nao informado. Recompile o instalador."
  !if "${REQUIRE_INSTALL_TOKEN}" == "1"
    StrCmp "${INSTALL_TOKEN}" "" 0 +2
    Abort "INSTALL_TOKEN nao informado. Recompile o instalador com INSTALL_TOKEN ou use /DREQUIRE_INSTALL_TOKEN=0."
  !endif
  !if "${REQUIRE_RUSTDESK_PASSWORD}" == "1"
    StrCmp "${RUSTDESK_PASSWORD}" "" 0 +2
    Abort "RUSTDESK_PASSWORD nao informado. Recompile o instalador com RUSTDESK_PASSWORD ou use /DREQUIRE_RUSTDESK_PASSWORD=0."
  !endif

  ; 1. PREPARACAO: estrutura de logs centralizada
  CreateDirectory "C:\Trilink\Remote\Logs"
  FileOpen $9 "C:\Trilink\Remote\Logs\installRemote.log" a
  FileWrite $9 "$\r$\n--- [${__DATE__} ${__TIME__}] Nova tentativa de instalacao Trilink ---$\r$\n"

  ; 2. LIMPEZA DE PROCESSOS
  FileWrite $9 "Finalizando processos e servicos antigos...$\r$\n"
  nsExec::ExecToLog '"$SYSDIR\sc.exe" stop RustDesk'
  Pop $0
  FileWrite $9 "sc stop RustDesk -> Codigo: $0$\r$\n"

  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM ${APP_EXE} /T'
  Pop $0
  FileWrite $9 "taskkill ${APP_EXE} -> Codigo: $0$\r$\n"

  Sleep 2000
  nsExec::ExecToLog '"$SYSDIR\sc.exe" delete RustDesk'
  Pop $0
  FileWrite $9 "sc delete RustDesk -> Codigo: $0$\r$\n"
  Sleep 2000

  ; 3. COPIA DOS ARQUIVOS
  FileWrite $9 "Copiando binarios para $INSTDIR...$\r$\n"
  SetOutPath "$INSTDIR"
  File /r "${APP_SOURCE_DIR}\*"
  SetOutPath "$INSTDIR\remote-agent"
  File /r "${AGENT_DIR}\*"

  ; 4. REGISTRO TRILINK + LOCKS DE UPDATE/PATH
  FileWrite $9 "Aplicando configuracoes de registro...$\r$\n"
  WriteRegStr HKLM "Software\Trilink" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\Trilink\RemoteAgent" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\Trilink\RemoteAgent" "DiscoveryToken" "${DISCOVERY_TOKEN}"
  WriteRegStr HKLM "Software\Trilink\RemoteAgent" "PortalBaseUrl" "${PORTAL_BASE_URL}"
  WriteRegStr HKLM "Software\Trilink\RemoteAgent" "InstallToken" "${INSTALL_TOKEN}"
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; 4.1 REGISTRO NO PAINEL DE CONTROLE (Windows Uninstall)
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "BuildDate" "${APP_BUILD_DATE}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "UninstallString" "$\"$INSTDIR\uninstall.exe$\""
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "QuietUninstallString" "$\"$INSTDIR\uninstall.exe$\" /S"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "DisplayIcon" "$\"$INSTDIR\${APP_EXE}$\",0"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "Publisher" "Trilink Software"
  ; Chave gemea para reconhecimento da engine RustDesk
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk" "DisplayName" "Trilink Suporte Remoto (Engine)"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk" "UninstallString" "$\"$INSTDIR\uninstall.exe$\""
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk" "BuildDate" "${APP_BUILD_DATE}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk" "DisplayIcon" "$\"$INSTDIR\${APP_EXE}$\",0"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\{54E86BC2-6C85-41F3-A9EB-1A94AC9B1F93}_is1" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\{54E86BC2-6C85-41F3-A9EB-1A94AC9B1F93}_is1" "BuildDate" "${APP_BUILD_DATE}"

  ; Forca o motor a reconhecer esta instalacao e desabilita update automatico
  WriteRegStr HKLM "Software\RustDesk" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\RustDesk" "Installed" "1"
  WriteRegStr HKLM "Software\RustDesk" "ServiceRunning" "1"
  WriteRegDWORD HKLM "Software\RustDesk" "StopUpdate" 1
  WriteRegDWORD HKLM "Software\RustDesk" "CheckUpdate" 0

  ; Espelha chaves no view 32-bit para compatibilidade (WOW6432Node)
  SetRegView 32
  WriteRegStr HKLM "Software\Trilink\RemoteAgent" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\Trilink\RemoteAgent" "DiscoveryToken" "${DISCOVERY_TOKEN}"
  WriteRegStr HKLM "Software\Trilink\RemoteAgent" "PortalBaseUrl" "${PORTAL_BASE_URL}"
  WriteRegStr HKLM "Software\Trilink\RemoteAgent" "InstallToken" "${INSTALL_TOKEN}"
  WriteRegStr HKLM "Software\RustDesk" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\RustDesk" "Installed" "1"
  WriteRegStr HKLM "Software\RustDesk" "ServiceRunning" "1"
  WriteRegDWORD HKLM "Software\RustDesk" "StopUpdate" 1
  WriteRegDWORD HKLM "Software\RustDesk" "CheckUpdate" 0
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk" "DisplayName" "Trilink Suporte Remoto (Engine)"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk" "UninstallString" "$\"$INSTDIR\uninstall.exe$\""
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk" "BuildDate" "${APP_BUILD_DATE}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\{54E86BC2-6C85-41F3-A9EB-1A94AC9B1F93}_is1" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\{54E86BC2-6C85-41F3-A9EB-1A94AC9B1F93}_is1" "BuildDate" "${APP_BUILD_DATE}"
  SetRegView 64

  ; 5. ATALHOS
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\Desinstalar.lnk" "$INSTDIR\uninstall.exe"
  CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"

  ; 6. SERVICO
  FileWrite $9 "Registrando servico RustDesk...$\r$\n"
  nsExec::ExecToLog '"$SYSDIR\sc.exe" create RustDesk binPath= "$\"$INSTDIR\${APP_EXE}$\" --service" start= auto DisplayName= "Trilink Remote Service"'
  Pop $0
  FileWrite $9 "sc create RustDesk -> Codigo: $0$\r$\n"
  StrCmp $0 "0" +2 0
  Abort "Falha ao criar servico RustDesk (sc create). Codigo: $0"

  nsExec::ExecToLog '"$SYSDIR\sc.exe" start RustDesk'
  Pop $0
  FileWrite $9 "sc start RustDesk -> Codigo: $0$\r$\n"
  StrCmp $0 "0" +2 0
  Abort "Falha ao iniciar servico RustDesk (sc start). Codigo: $0"

  ; 6.1 DESABILITA VERIFICACAO/AUTOMACAO DE UPDATE NA CONFIG DO CLIENTE
  nsExec::ExecToLog '"$INSTDIR\${APP_EXE}" --option enable-check-update N'
  Pop $0
  FileWrite $9 "set option enable-check-update=N -> Codigo: $0$\r$\n"
  StrCmp $0 "0" +2 0
  Abort "Falha ao aplicar enable-check-update=N. Codigo: $0"
  nsExec::ExecToLog '"$INSTDIR\${APP_EXE}" --option allow-auto-update N'
  Pop $0
  FileWrite $9 "set option allow-auto-update=N -> Codigo: $0$\r$\n"
  StrCmp $0 "0" +2 0
  Abort "Falha ao aplicar allow-auto-update=N. Codigo: $0"
  nsExec::ExecToLog '"$INSTDIR\${APP_EXE}" --option allow-remote-config-modification Y'
  Pop $0
  FileWrite $9 "set option allow-remote-config-modification=Y -> Codigo: $0$\r$\n"
  StrCmp $0 "0" +2 0
  Abort "Falha ao aplicar allow-remote-config-modification=Y. Codigo: $0"
  nsExec::ExecToLog '"$INSTDIR\${APP_EXE}" --option verification-method use-permanent-password'
  Pop $0
  FileWrite $9 "set option verification-method=use-permanent-password -> Codigo: $0$\r$\n"
  StrCmp $0 "0" +2 0
  Abort "Falha ao aplicar verification-method=use-permanent-password. Codigo: $0"
  nsExec::ExecToLog '"$INSTDIR\${APP_EXE}" --option approve-mode password'
  Pop $0
  FileWrite $9 "set option approve-mode=password -> Codigo: $0$\r$\n"
  StrCmp $0 "0" +2 0
  Abort "Falha ao aplicar approve-mode=password. Codigo: $0"
  nsExec::ExecToLog '"$INSTDIR\${APP_EXE}" --password "$\"${RUSTDESK_PASSWORD}$\""'
  Pop $0
  FileWrite $9 "set permanent password -> Codigo: $0$\r$\n"
  StrCmp $0 "0" +2 0
  Abort "Falha ao aplicar senha permanente do RustDesk. Codigo: $0"

  ; 7. TAREFA AGENDADA (PowerShell Agent)
  ; Limpa tarefas antigas/duplicadas antes de recriar a tarefa canonica em SYSTEM.
  nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /delete /tn "TrilinkRemoteAgent" /f'
  Pop $0
  FileWrite $9 "cleanup tarefas TrilinkRemoteAgent* -> Codigo: $0$\r$\n"
  nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /create /tn "TrilinkRemoteAgent" /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $\"$INSTDIR\remote-agent\trilink-agente.ps1$\"" /sc minute /mo 5 /ru "SYSTEM" /f'
  Pop $0
  FileWrite $9 "schtasks create TrilinkRemoteAgent -> Codigo: $0$\r$\n"
  StrCmp $0 "0" +2 0
  Abort "Falha ao criar tarefa agendada TrilinkRemoteAgent. Codigo: $0"
  nsExec::ExecToLog '"$SYSDIR\cmd.exe" /C "$SYSDIR\schtasks.exe /query /tn \"TrilinkRemoteAgent\" /xml > \"$TEMP\trilink_task.xml\" 2>&1"'
  Pop $0
  FileWrite $9 "consulta xml task TrilinkRemoteAgent -> Codigo: $0$\r$\n"
  StrCmp $0 "0" +3 0
  FileWrite $9 "WARN: consulta XML da task falhou; instalacao continuara porque a task foi criada com sucesso.$\r$\n"
  Goto +5
  nsExec::ExecToLog '"$SYSDIR\findstr.exe" /I /C:"S-1-5-18" /C:"SYSTEM" /C:"SISTEMA" "$TEMP\trilink_task.xml"'
  Pop $0
  FileWrite $9 "validacao task SYSTEM via XML -> Codigo: $0$\r$\n"
  StrCmp $0 "0" +2 0
  FileWrite $9 "WARN: validacao de principal SYSTEM nao confirmada por XML; instalacao continuara.$\r$\n"

  ; 8. EXECUCAO INICIAL DO AGENTE
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\remote-agent\trilink-agente.ps1"'
  Pop $0
  FileWrite $9 "execucao inicial do agente -> Codigo: $0$\r$\n"
  StrCmp $0 "0" +2 0
  Abort "Falha na execucao inicial do agente. Codigo: $0"
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "if ((Get-Service -Name ''RustDesk'' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Status -ErrorAction SilentlyContinue) -ne ''Running'') { throw ''Servico RustDesk nao esta Running apos instalacao.'' }; if (-not (Test-Path ''C:\Trilink\Remote\Logs\agentRemote.log'')) { throw ''Log do agente nao encontrado.'' }; if ((Get-Item ''C:\Trilink\Remote\Logs\agentRemote.log'' -ErrorAction Stop).LastWriteTime -lt (Get-Date).AddMinutes(-10)) { throw ''Log do agente desatualizado apos instalacao.'' }; if (-not ((Get-Content ''C:\Trilink\Remote\Logs\agentRemote.log'' -Tail 200 -ErrorAction SilentlyContinue) -match ''sync OK'')) { throw ''sync OK nao encontrado no log inicial do agente.'' }"'
  Pop $0
  FileWrite $9 "post-check servico/log/sync -> Codigo: $0$\r$\n"
  !if "${REQUIRE_POSTCHECK_SYNC_OK}" == "1"
    StrCmp $0 "0" +2 0
    Abort "Falha no post-check do agente (servico/log/sync). Codigo: $0"
  !endif
  FileWrite $9 "--- Fim do log de instalacao ---$\r$\n"
  FileClose $9

  ; 9. ABRE A TELA FINAL PARA O USUARIO (nao abre em instalacao silenciosa /S)
  IfSilent +2
  ExecShell "" "$INSTDIR\${APP_EXE}"
SectionEnd

Section "Uninstall"
  SetRegView 64

  ; Mata tudo antes de deletar a pasta
  nsExec::ExecToLog '"$SYSDIR\sc.exe" stop RustDesk'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM ${APP_EXE}'
  Pop $0
  Sleep 2000
  nsExec::ExecToLog '"$SYSDIR\sc.exe" delete RustDesk'
  Pop $0

  Delete "$DESKTOP\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\Desinstalar.lnk"
  RMDir "$SMPROGRAMS\${APP_NAME}"

  nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /delete /tn "TrilinkRemoteAgent" /f'
  Pop $0

  ; Guarda de seguranca antes da remocao recursiva
  StrCmp "$INSTDIR" "" 0 +2
  Abort "INSTDIR vazio. Abortando desinstalacao por seguranca."
  StrCmp "$INSTDIR" "C:\" 0 +2
  Abort "INSTDIR invalido (Raiz C:\\). Abortando por seguranca."
  StrCmp "$INSTDIR" "C:\Trilink" 0 +2
  Abort "INSTDIR invalido (Raiz Trilink). Abortando por seguranca para proteger outros apps."
  StrCmp "$INSTDIR" "C:\Trilink\Remote" 0 +2
  Abort "INSTDIR invalido (Raiz Remote). Abortando por seguranca para proteger logs e outros componentes."
  StrCmp "$INSTDIR" "C:\Trilink\Remote\RustDesk" +2 0
  Abort "INSTDIR inesperado: $INSTDIR. Abortando por seguranca."

  RMDir /r "$INSTDIR"
  DeleteRegValue HKLM "Software\Trilink" "InstallDir"
  DeleteRegKey HKLM "Software\Trilink\RemoteAgent"
  DeleteRegKey HKLM "Software\RustDesk"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\{54E86BC2-6C85-41F3-A9EB-1A94AC9B1F93}_is1"

  ; Remove espelho 32-bit
  SetRegView 32
  DeleteRegKey HKLM "Software\Trilink\RemoteAgent"
  DeleteRegKey HKLM "Software\RustDesk"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\{54E86BC2-6C85-41F3-A9EB-1A94AC9B1F93}_is1"
  SetRegView 64
SectionEnd


