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
  Abort "DISCOVERY_TOKEN nao informado. Recompile o instalador com /DDISCOVERY_TOKEN."
  StrCmp "${PORTAL_BASE_URL}" "" 0 +2
  Abort "PORTAL_BASE_URL nao informado. Recompile o instalador com /DPORTAL_BASE_URL."
  SetOutPath "$INSTDIR"

  ; Copy full runtime folder (exe + dlls + data)
  File /r "${APP_SOURCE_DIR}\*"
  File "${AGENT_SCRIPT}"

  ; Registry + uninstaller
  WriteRegStr HKLM "Software\${APP_NAME}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\Trilink\RemoteAgent" "DiscoveryToken" "${DISCOVERY_TOKEN}"
  WriteRegStr HKLM "Software\Trilink\RemoteAgent" "PortalBaseUrl" "${PORTAL_BASE_URL}"
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; Start menu and desktop shortcuts
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\Desinstalar.lnk" "$INSTDIR\uninstall.exe"
  CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"

  ; Silent agent registration every 5 minutes (runs as SYSTEM)
  nsExec::ExecToLog 'schtasks /create /tn "TrilinkRemoteAgent" /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $\"$INSTDIR\trilink-agente.ps1$\"" /sc minute /mo 5 /ru "SYSTEM" /f'
  ; Run once after install to accelerate first discovery
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\trilink-agente.ps1"'
  ExecShell "" "$INSTDIR\${APP_EXE}"
SectionEnd

Section "Uninstall"
  SetRegView 64

  Delete "$DESKTOP\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\Desinstalar.lnk"
  RMDir "$SMPROGRAMS\${APP_NAME}"
  nsExec::ExecToLog 'schtasks /delete /tn "TrilinkRemoteAgent" /f'

  RMDir /r "$INSTDIR"
  DeleteRegKey HKLM "Software\${APP_NAME}"
  DeleteRegKey HKLM "Software\Trilink\RemoteAgent"
SectionEnd
