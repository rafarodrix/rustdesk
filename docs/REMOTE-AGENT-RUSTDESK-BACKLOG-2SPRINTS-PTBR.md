# Backlog Executavel - Agente Remoto + RustDesk (2 Sprints)

Data base: 2026-04-03  
Escopo: evoluir confiabilidade do agente, upgrade seguro do RustDesk e prontidao de rollout.

## Baseline tecnico atual (HEAD)

- Catalogo de `reasonCode` de ACK centralizado no agente (`Resolve-AckReasonCode`).
- Metricas do ciclo ampliadas com `schemaVersions`, `pendingAckQueueSize`, `ackQueueFlush`, `lastBootstrapFlow`, `lastContractErrorCode`.
- Estado persistente ampliado com `lastBootstrapFlow` e `lastContractErrorCode`.
- Contratos de erro HTTP por fase ja registrados como codigo tecnico (`DISCOVER_HTTP_*`, `BOOTSTRAP_HTTP_*`, `SYNC_HTTP_*`, `ACK_HTTP_*`).

## Objetivo de negocio

- Reduzir falhas de campo (sync/ack/upgrade) antes de ampliar rollout.
- Garantir deploy reproduzivel (CI + instalador + execucao em maquina limpa).
- Criar trilha segura para upgrade do `rustdesk.exe` via comando remoto.

## Sprint 1 (2026-04-06 a 2026-04-17)

Objetivo: estabilizar release pipeline e contrato operacional do agente.

### EPIC 1 - Release confiavel (P0)

1. Pipeline CI com gates obrigatorios
- Tarefas:
  - Adicionar etapa de parse de todos os `.ps1` em `remote-agent/`.
  - Validar build NSIS com `AGENT_DIR=remote-agent`.
  - Executar smoke test em instalacao silenciosa (VM limpa) com 1 ciclo do agente.
- Criterio de aceite:
  - Pipeline falha automaticamente se parse/build/smoke falhar.
  - Artefato NSIS gerado com `remote-agent` completo no instalador.

2. Matriz de compatibilidade `agentVersion x rustdeskVersion`
- Tarefas:
  - Criar arquivo de compatibilidade em `docs/` com versoes suportadas.
  - Incluir validacao no startup para logar incompatibilidade.
- Criterio de aceite:
  - Log de ciclo mostra versao do agente e versao do RustDesk.
  - Documento de compatibilidade publicado junto da release.

### EPIC 2 - Observabilidade operacional (P0)

3. Correlation ID e decision codes padronizados
- Tarefas:
  - Garantir `cycleId` em todos os eventos de fase.
  - Padronizar codigos: `discover_failed`, `bootstrap_failed`, `sync_failed`, `ack_failed`, `upgrade_failed`.
  - Padronizar tambem codigos de contrato (`*_HTTP_*`, `*_MISSING_*`, `PHASE_TIMEOUT_*`) e manter tabela de referencia.
- Criterio de aceite:
  - Suporte consegue filtrar um ciclo completo por `cycleId`.
  - Todos os erros de fase possuem codigo consistente.

4. Metricas minimas por fase
- Tarefas:
  - Consolidar tempos de `discover/bootstrap/sync/ack`.
  - Incluir contadores de comando (`ackCount`) e falhas consecutivas.
  - Garantir envio consistente de `schemaVersions`, `pendingAckQueueSize`, `ackQueueFlush`, `lastBootstrapFlow`, `lastContractErrorCode`.
- Criterio de aceite:
  - Payload de sync envia metrica com fases e tempos.
  - Payload de sync inclui os novos campos de contrato/fila sem quebra de compatibilidade.
  - Dashboard (ou consulta backend) identifica hosts com degradacao.

### EPIC 3 - Contrato de comandos (P0)

5. Versionamento do schema de `commandQueue/ack`
- Tarefas:
  - Definir campos obrigatorios por versao (`id`, `type`, `payload`).
  - Definir estados de retorno (`ACKNOWLEDGED`, `FAILED`) e semantica.
  - Versionar e documentar `reasonCode` de ACK (catalogo canonico backend/agente).
- Criterio de aceite:
  - Comando sem `id` nao quebra ciclo e gera log padrao.
  - Backend e agente aceitam versao atual e imediatamente anterior.
  - `reasonCode` desconhecido no backend gera alerta controlado, sem quebra de fluxo.

6. Teste de integracao de comandos criticos
- Tarefas:
  - Cenarios: `ROTATE_TOKEN_REQUIRED`, `UPGRADE_CLIENT`, comando desconhecido.
  - Validar comportamento de token apos fila de ACK.
- Criterio de aceite:
  - Testes reproduzem resposta esperada de estado/token.
  - Sem regressao no fluxo de sync normal.

## Sprint 2 (2026-04-20 a 2026-05-01)

Objetivo: upgrade seguro do RustDesk e rollout gradual com rollback.

### EPIC 4 - Upgrade seguro do RustDesk (P0)

1. Endurecimento do `UPGRADE_CLIENT`
- Tarefas:
  - Forcar HTTPS + checksum SHA256 obrigatorio.
  - Registrar resultado detalhado (versao antes/depois, exit code, restart de servico).
  - Limitar tentativas por host/versao em janela de tempo.
- Criterio de aceite:
  - Upgrade sem checksum e rejeitado.
  - Falha de upgrade nao derruba o agente nem corrompe executavel.

2. Rollback automatico de binario
- Tarefas:
  - Validar existencia de backup e restauracao em falha.
  - Marcar host com status de rollback executado.
- Criterio de aceite:
  - Em falha simulada, `rustdesk.exe` volta para versao anterior.
  - Servico RustDesk volta a `running` ou erro fica claramente sinalizado.

### EPIC 5 - Rollout em anel (P1)

3. Estrategia canary -> lote -> geral
- Tarefas:
  - Definir coortes de rollout (5%, 25%, 100%).
  - Definir kill switch operacional.
- Criterio de aceite:
  - Rollout pode ser pausado em menos de 10 minutos.
  - Promocao de fase depende de SLO minimo acordado.

4. Runbook de incidente e rollback
- Tarefas:
  - Documentar resposta a `sync_failed` alto, `ack_failed` alto e falha de upgrade.
  - Padronizar coleta de evidencias para suporte N1/N2.
- Criterio de aceite:
  - Time executa simulacao de incidente com tempo alvo (MTTR) definido.
  - Runbook referenciado no checklist de deploy.

### EPIC 6 - Seguranca de release (P1)

5. Assinatura e integridade de artefatos
- Tarefas:
  - Assinar instalador e binario final.
  - Publicar checksums de release.
- Criterio de aceite:
  - Toda release possui assinatura valida e checksum publicado.

6. Higiene de logs e segredos
- Tarefas:
  - Revisar mascaramento de token em todos os pontos.
  - Remover campos sensiveis de logs de erro.
- Criterio de aceite:
  - Nenhum token completo aparece em log local ou remoto.

## Definition of Done (global)

- Codigo revisado e mergeado.
- Parse PowerShell ok para todos os scripts do agente.
- CI verde com build + smoke em instalacao limpa.
- Checklist de validacao pos-deploy executado.
- Documentacao de release atualizada.

## Dependencias externas

- Acesso aos secrets de CI (discovery/install token e portal base URL).
- Ambiente de VM para smoke test de instalacao.
- Endpoint backend para coleta de metricas/estado de comando.

## Riscos e mitigacao

- Risco: regressao silenciosa no instalador.
  - Mitigacao: smoke test automatizado por build.
- Risco: upgrade remoto quebrar hosts em lote.
  - Mitigacao: rollout em anel + kill switch + rollback automatico.
- Risco: drift entre backend e agente no contrato de comando.
  - Mitigacao: schema versionado e teste de compatibilidade.
