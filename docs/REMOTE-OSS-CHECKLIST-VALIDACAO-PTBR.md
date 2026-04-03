# Checklist de Validacao Pos-Deploy - Operacao Remota OSS-First

Data: ____/____/______  
Release/tag: ____________________  
Responsavel pela execucao: ____________________

## 1. Pre-validacao

- [ ] Release publicada e artefato conferido
- [ ] Politica de rollout definida:
  - `canary` => NSIS com `REQUIRE_POSTCHECK_SYNC_OK=1`
  - `broad` => NSIS com `REQUIRE_POSTCHECK_SYNC_OK=0` (temporario, para ambientes instaveis)
- [ ] Script oficial baixado por `GET /api/remote/agents/discovery-script`
- [ ] Ambiente com `REMOTE_DISCOVERY_TOKEN` valido
- [ ] Host RustDesk e API do portal conferidos
- [ ] Se usar MSI: tratar como **engine update only** (sem onboarding Trilink completo)

## 2. Fluxo A - Descoberta sem pre-cadastro

- [ ] Executou script em maquina limpa
- [ ] `POST /api/remote/agents/discover` respondeu sucesso
- [ ] Maquina apareceu em "Maquinas pendentes de vinculacao"
- [ ] Vinculacao via `POST /api/remote/discovered-hosts/:id/link` concluida
- [ ] Host ficou operacional no diretorio remoto

Evidencias:
- Host/maquina: ____________________
- RustDesk ID: ____________________
- Timestamp da descoberta: ____________________

## 3. Fluxo B - Host pre-cadastrado

- [ ] Instalador do host baixado por `GET /api/remote/hosts/:id/installer`
- [ ] `POST /api/remote/rustdesk/bootstrap` respondeu sucesso
- [ ] `agentToken` emitido e persistido
- [ ] `agentExternalId`, `machineName`, `agentVersion` preenchidos

Evidencias:
- HostId: ____________________
- installToken usado: ____________________
- Timestamp do bootstrap: ____________________

## 4. Heartbeat e comando

- [ ] `POST /api/remote/rustdesk/sync` recorrente ativo
- [ ] `lastHeartbeatAt` atualiza conforme intervalo configurado
- [ ] `serviceStatus` refletido no detalhe do host
- [ ] `sysproUpdates[]` atualizado sem duplicar host
- [ ] `commandQueue` recebida e processada quando aplicavel
- [ ] `POST /api/remote/rustdesk/ack` retornou sucesso

Evidencias:
- Ultimo heartbeat: ____________________
- CommandId testado: ____________________
- Status de ack: ____________________

## 5. Operacao de suporte

- [ ] Host localizavel em `/portal/plataforma-remota`
- [ ] Busca por empresa principal/secundaria funcionando
- [ ] `Acesso rapido` funcional
- [ ] Sessao manual com transicao `REQUESTED -> STARTED -> ENDED`
- [ ] Bloqueio de sessao duplicada por ticket/host funcionando
- [ ] Bloqueio de exclusao de host com sessao aberta funcionando

## 6. Erros comuns (teste guiado)

- [ ] Teste de `403` com token invalido validado e runbook conferido
- [ ] Teste de `405` (roteamento/middleware) validado
- [ ] Teste de ausencia de heartbeat e alerta operacional validado
- [ ] Teste de protocolo `rustdesk://` em estacao com bloqueio de navegador

## 7. Decisao de fase

- [ ] Aprovado para ampliar rollout
- [ ] Reprovado e retorna para ajuste

Observacoes finais:

```
____________________________________________________________
____________________________________________________________
____________________________________________________________
```
