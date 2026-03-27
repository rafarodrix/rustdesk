; Trilink RustDesk Installer (NSIS)
; Expected defines from CI:
;   /DAPP_NAME
;   /DAPP_EXE
;   /DAPP_SOURCE_DIR
;   /DOUTFILE
;   /DAGENT_SCRIPT (optional, defaults to trilink-agente.ps1 in repo root)
;   /DDISCOVERY_TOKEN
;   /DPORTAL_BASE_URL

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

!ifndef AGENT_SCRIPT
  !define AGENT_SCRIPT "trilink-agente.ps1"
!endif

!ifndef DISCOVERY_TOKEN
  !define DISCOVERY_TOKEN ""
!endif

!ifndef PORTAL_BASE_URL
  !define PORTAL_BASE_URL ""
!endif

Unicode true
Name "${APP_NAME}"
OutFile "${OUTFILE}"
RequestExecutionLevel admin
InstallDir "$ProgramFiles64\${APP_NAME}"
InstallDirRegKey HKLM "Software\${APP_NAME}" "InstallDir"

!include "MUI2.nsh"

!define MUI_ABORTWARNING
!define MUI_ICON "${NSISDIR}\Contrib\Graphics\Icons\modern-install.ico"
!define MUI_UNICON "${NSISDIR}\Contrib\Graphics\Icons\modern-uninstall.ico"

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

  ; 1. PREPARACAO: para o servico e mata processo antes de copiar
  nsExec::ExecToStack '"$SYSDIR\sc.exe" stop RustDesk'
  Pop $0
  nsExec::ExecToStack '"$SYSDIR\taskkill.exe" /F /IM ${APP_EXE}'
  Pop $0
  Sleep 2000
  nsExec::ExecToStack '"$SYSDIR\sc.exe" delete RustDesk'
  Pop $0
  Sleep 2000

  ; 2. COPIA DOS ARQUIVOS
  SetOutPath "$INSTDIR"
  File /r "${APP_SOURCE_DIR}\*"
  File "${AGENT_SCRIPT}"

  ; 3. REGISTRO TRILINK
  WriteRegStr HKLM "Software\${APP_NAME}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\Trilink\RemoteAgent" "DiscoveryToken" "${DISCOVERY_TOKEN}"
  WriteRegStr HKLM "Software\Trilink\RemoteAgent" "PortalBaseUrl" "${PORTAL_BASE_URL}"
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; 4. REGISTRO RUSTDESK (esconde botao de instalar da engine)
  WriteRegStr HKLM "Software\RustDesk" "InstallDir" "$INSTDIR"

  ; 5. ATALHOS
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\Desinstalar.lnk" "$INSTDIR\uninstall.exe"
  CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"

  ; 6. SERVICO: cria e inicia com validacao de retorno
  nsExec::ExecToStack '"$SYSDIR\sc.exe" create RustDesk binPath= "$\"$INSTDIR\${APP_EXE}$\" --service" start= auto DisplayName= "Trilink Remote Service"'
  Pop $0
  StrCmp $0 "0" +2 0
  Abort "Falha ao criar servico RustDesk (sc create)."

  nsExec::ExecToStack '"$SYSDIR\sc.exe" start RustDesk'
  Pop $0
  StrCmp $0 "0" +2 0
  Abort "Falha ao iniciar servico RustDesk (sc start)."

  ; 7. TAREFA AGENDADA (PowerShell Agent)
  nsExec::ExecToStack '"$SYSDIR\schtasks.exe" /create /tn "TrilinkRemoteAgent" /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $\"$INSTDIR\trilink-agente.ps1$\"" /sc minute /mo 5 /ru "SYSTEM" /f'
  Pop $0
  StrCmp $0 "0" +2 0
  Abort "Falha ao criar tarefa agendada TrilinkRemoteAgent."

  ; 8. EXECUTA O AGENTE AGORA
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\trilink-agente.ps1"'

  ; 9. ABRE A TELA FINAL PARA O USUARIO
  ExecShell "" "$INSTDIR\${APP_EXE}"
SectionEnd

Section "Uninstall"
  SetRegView 64

  ; Mata tudo antes de deletar a pasta
  nsExec::ExecToStack '"$SYSDIR\sc.exe" stop RustDesk'
  Pop $0
  nsExec::ExecToStack '"$SYSDIR\taskkill.exe" /F /IM ${APP_EXE}'
  Pop $0
  Sleep 2000
  nsExec::ExecToStack '"$SYSDIR\sc.exe" delete RustDesk'
  Pop $0

  Delete "$DESKTOP\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\Desinstalar.lnk"
  RMDir "$SMPROGRAMS\${APP_NAME}"

  nsExec::ExecToStack '"$SYSDIR\schtasks.exe" /delete /tn "TrilinkRemoteAgent" /f'
  Pop $0

  ; Guarda de seguranca antes da remocao recursiva
  StrCmp "$INSTDIR" "" 0 +2
  Abort "INSTDIR vazio. Abortando desinstalacao por seguranca."
  StrCmp "$INSTDIR" "$ProgramFiles64" 0 +2
  Abort "INSTDIR invalido ($ProgramFiles64). Abortando por seguranca."
  StrCmp "$INSTDIR" "$ProgramFiles64\${APP_NAME}" +2 0
  Abort "INSTDIR inesperado: $INSTDIR. Abortando por seguranca."

  RMDir /r "$INSTDIR"
  DeleteRegKey HKLM "Software\${APP_NAME}"
  DeleteRegKey HKLM "Software\Trilink\RemoteAgent"
  DeleteRegKey HKLM "Software\RustDesk"
SectionEnd
