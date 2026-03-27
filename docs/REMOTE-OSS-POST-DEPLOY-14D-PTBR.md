# Plano de Execucao 14 Dias - Operacao Remota OSS-First

Data base: 2026-03-27  
Escopo: pos-deploy do agente remoto com portal Trilink como fonte de verdade e RustDesk self-hosted para conectividade.

## Objetivo

Executar rollout controlado, validar confiabilidade dos fluxos oficiais e endurecer operacao, observabilidade e governanca sem regressao de suporte.

## Responsaveis

- Plataforma: CI/CD, release, observabilidade, automacao
- Backend: contratos de API, regras de negocio, fila de comandos
- Suporte: validacao em campo, usabilidade operacional, evidencias

## Criticos do fluxo oficial

1. `POST /api/remote/agents/discover`
2. `POST /api/remote/rustdesk/bootstrap`
3. `POST /api/remote/rustdesk/sync`
4. `POST /api/remote/rustdesk/ack`

## Plano por fase

### Fase 1 - Go-live controlado (Dias 1 a 3)

1. Publicar release e registrar versoes
- Dono: Plataforma
- Entrega: release publicada, tag registrada, hash de artefato salvo
- Criterio de aceite: instalador baixa e executa sem erro em maquina de teste limpa

2. Smoke test ponta a ponta (2 fluxos oficiais)
- Dono: Backend + Suporte
- Entrega: validacao de `discover/link` e `bootstrap/sync/ack`
- Criterio de aceite: todos os endpoints com resposta esperada e `lastHeartbeatAt` atualizando

3. Canary com grupo reduzido
- Dono: Suporte
- Entrega: rollout para 5-10 hosts reais
- Criterio de aceite: zero bloqueio critico e taxa de erro HTTP 4xx/5xx dentro do limite interno

### Fase 2 - Estabilizacao operacional (Dias 4 a 7)

1. Alertas de degradacao
- Dono: Plataforma
- Entrega: alertas para host sem heartbeat, falha de ack, comando pendente
- Criterio de aceite: alerta dispara em simulacao e gera acao operacional

2. Revisao de status operacional
- Dono: Backend
- Entrega: validacao de transicoes `ONLINE`, `RECENT`, `OFFLINE`, `MISCONFIGURED`, `SESSION_BUSY`
- Criterio de aceite: sem inconsistencias de status em auditoria de amostra

3. Runbook de incidentes recorrentes
- Dono: Suporte + Plataforma
- Entrega: procedimento para `403`, `405`, sem heartbeat, `about:blank#blocked`
- Criterio de aceite: tecnico consegue resolver sem escalonamento em caso padrao

### Fase 3 - Endurecimento tecnico (Dias 8 a 11)

1. Testes de contrato de API
- Dono: Backend
- Entrega: testes automatizados para payload minimo dos 4 endpoints
- Criterio de aceite: pipeline quebra em mudanca incompatível de contrato

2. Idempotencia e deduplicacao
- Dono: Backend
- Entrega: verificacoes para evitar host duplicado e ack duplicado
- Criterio de aceite: repeticao de request nao cria efeito colateral indevido

3. Qualidade de dados operacionais
- Dono: Plataforma
- Entrega: validacao de `RustDesk ID` sem espacos e consistencia de `agentVersion`
- Criterio de aceite: regra aplicada em 100% dos novos registros

### Fase 4 - Governanca e escala (Dias 12 a 14)

1. Politica de token
- Dono: Backend + Seguranca
- Entrega: decisao formal sobre ciclo de vida `installToken` e `agentToken`
- Criterio de aceite: regra publicada e aplicada em novas instalacoes

2. Auditoria operacional
- Dono: Plataforma
- Entrega: trilha para vinculacao de host, abertura de sessao e execucao de comando
- Criterio de aceite: rastreabilidade completa por `hostId` e `agentToken`

3. Gate de ampliacao de rollout
- Dono: Engenharia de Plataforma
- Entrega: decisao de expandir canary para base ampla
- Criterio de aceite: metas minimas de estabilidade atingidas por 72h consecutivas

## Metricas de sucesso

- Heartbeat ativo: >= 95% dos hosts com sync no intervalo esperado
- Ack de comando: >= 99% dos comandos com retorno em janela operacional
- Disponibilidade operacional do modulo remoto: meta interna acordada
- Erro de descoberta/bootstrap por token invalido: tendencia de queda apos runbook e script dinamico

## Gate de rollback

Acionar rollback do release quando houver qualquer condicao:

- quebra sistemica no `bootstrap` em ambiente real
- aumento persistente de `OFFLINE` sem causa de rede
- regressao funcional em sessao (`REQUESTED -> STARTED -> ENDED`)
- falha de rastreabilidade em incidentes criticos

## Evidencias minimas por fase

- IDs de host testados
- timestamps de `lastHeartbeatAt`
- amostras de payload/resposta por endpoint
- print da operacao no diretorio remoto
- status final da fase: aprovado/reprovado + acao corretiva
