# Backlog de Evolucao - Compilado Proprio RustDesk (OSS-First)

Data da analise: 2026-03-27  
Responsavel: Engenharia de Plataforma (Trilink)  
Escopo: melhorias para produto compilado proprio, instalador, operacao e manutencao continua.

## 1) Metodologia resumida

Foram cruzadas evidencias de:

- Issues abertas/fechadas recentes da comunidade RustDesk
- Topicos de GitHub Discussions da comunidade
- Sinais de falha de build e manutencao observados no pipeline atual

Objetivo: transformar dor recorrente da comunidade em backlog pragmatico para reduzir incidente em campo.

## 2) Sinais da comunidade (resumo executivo)

### A. Conectividade e handshake em self-hosted

Padrao observado:

- erro `deadline has elapsed` em varios contextos
- diferenca de comportamento entre plataformas no mesmo servidor
- casos ligados a rede, proxy, tun/vpn, DNS/rota

Sinais:

- Issue #732, #12704, #13053, #14480
- Discussion #12518, #14632

### B. Tela branca / waiting for image / black screen

Padrao observado:

- sessao conecta mas sem imagem
- regressao intermitente por plataforma/display stack

Sinais:

- Issue #5609, #6756, #11479
- Discussion #11253

### C. Input (teclado/mouse/clipboard)

Padrao observado:

- inconsistencias de teclado entre SOs/layouts
- sticky keys, ordem errada, trackpad anomalo
- comportamento de clipboard com risco de percepcao de falha de seguranca

Sinais:

- Issue #12293, #14447, #14586, #14267, #13338
- Discussion #9011, #14615, #14618, #14616

### D. Audio (sem som e latencia acumulada)

Padrao observado:

- ausencia de audio em parte dos ambientes
- latencia acumulada ao longo da sessao

Sinais:

- Issue #3762, #534, #4280

### E. Memoria/performance e estabilidade

Padrao observado:

- leak prolongado e degradação em sessoes longas

Sinais:

- Issue #14603

### F. Seguranca e confianca de distribuicao

Padrao observado:

- cobranca por tratamento de CVEs
- preocupacao de reputacao/distribuicao maliciosa no ecossistema

Sinais:

- Issue #14576
- Discussion #14167, #9679

### G. Build/Toolchain

Padrao observado:

- build quebra por drift de dependencias
- mudancas em vcpkg/toolchain afetam reproducibilidade

Sinais:

- PR #12795, #8764

## 3) Backlog recomendado para o compilado proprio

Legenda:

- Prioridade: `P0` (imediato), `P1` (proxima iteracao), `P2` (planejado)
- Tipo: `Produto`, `Plataforma`, `Operacao`, `Seguranca`

### P0 (executar primeiro)

1. Preflight de conectividade no instalador/agente
- Tipo: Produto/Operacao
- O que implementar: teste automatico de DNS, TCP 21114-21119, reachability do portal e do host RustDesk antes de finalizar setup.
- Motivo: reduz chamados de `deadline has elapsed` e falso positivo de instalacao concluida.
- Criterio de pronto: resultado visual claro (OK/ERRO + acao sugerida) e log persistido.

2. Diagnostico rapido no host (botao "Copiar diagnostico")
- Tipo: Produto/Operacao
- O que implementar: coletar versao, id, endpoints, status servico, ultimo heartbeat, ultimos erros de conexao.
- Motivo: encurta MTTR em incidentes de imagem/conexao/input.
- Criterio de pronto: suporte consegue abrir chamado com pacote padrao em < 2 min.

3. Controle forte de configuracao de build (pin de toolchain)
- Tipo: Plataforma
- O que implementar: fixar commit de vcpkg, registrar hash de artefato, bloquear `latest` em dependencia critica.
- Motivo: evitar regressao tipo NASM/AOM e quebra aleatoria de pipeline.
- Criterio de pronto: 3 releases consecutivos sem falha de toolchain nao-deterministica.

4. `patch_client.py` com CLI + relatorio JSON + dry-run
- Tipo: Plataforma
- O que implementar: `--strict`, `--best-effort`, `--dry-run`, `--report-file`.
- Motivo: melhor manutencao e observabilidade do patch.
- Criterio de pronto: pipeline usa JSON para decidir sucesso/falha.

5. Trilha minima de seguranca de release
- Tipo: Seguranca/Plataforma
- O que implementar: SBOM basico, assinatura do binario, changelog de seguranca por release.
- Motivo: endereca preocupacao de supply chain e CVEs.
- Criterio de pronto: cada release publicada com evidencias de integridade.

### P1 (proxima iteracao)

6. Fallback operacional de sessao de imagem
- Tipo: Produto
- O que implementar: detectar estado "connected waiting image" e acionar estrategia alternativa (retry perfil de codec/render, reinicializacao controlada da sessao).
- Motivo: alta recorrencia comunitaria em "conectou sem imagem".
- Criterio de pronto: queda mensuravel desse incidente no canary.

7. Harden de input cross-platform
- Tipo: Produto
- O que implementar: matriz de testes automatizados para teclado/layout/modificadores e clipboard.
- Motivo: input quebrado impacta diretamente produtividade do suporte.
- Criterio de pronto: suite de regressao rodando no CI para cenarios criticos.

8. Observabilidade de sessao e command queue
- Tipo: Operacao
- O que implementar: metricas por host para `sync`, `ack`, fila pendente, tempo de execucao de comando.
- Motivo: detectar degradacao antes do usuario final.
- Criterio de pronto: dashboards e alertas ativos com limiares definidos.

9. Canal de rollout em anel (canary/stable)
- Tipo: Plataforma
- O que implementar: politicas de deploy em anel com kill switch.
- Motivo: regressao em build proprio precisa impacto controlado.
- Criterio de pronto: capacidade de pausar rollout em minutos.

10. UX de erro guiado no app/suporte
- Tipo: Produto
- O que implementar: mensagens de erro com causa provavel e acao concreta.
- Motivo: evita troubleshooting cego para casos rede/proxy/porta/token.
- Criterio de pronto: erros criticos mapeados para runbook.

### P2 (planejado)

11. Perfil de codec adaptativo por ambiente
- Tipo: Produto
- O que implementar: heuristica que evita combinacoes propensas a consumo elevado em ambientes conhecidos.
- Motivo: reduzir risco de leak/performance em sessoes longas.
- Criterio de pronto: telemetria mostra melhoria de estabilidade de memoria/sessao.

12. Telemetria opt-in orientada a confiabilidade
- Tipo: Produto/Seguranca
- O que implementar: coleta minima anonima para falhas de conexao/render/input.
- Motivo: priorizacao real por incidencia.
- Criterio de pronto: painel com top erros por versao e plataforma.

13. Acessibilidade e consistencia de interface
- Tipo: Produto
- O que implementar: rotulos acessiveis, navegacao por teclado, feedback visual padrao.
- Motivo: alinhamento com discussoes recentes de acessibilidade.
- Criterio de pronto: checklist de acessibilidade aprovado nas telas principais.

14. Pacote "Quick Support" endurecido
- Tipo: Produto/Seguranca
- O que implementar: binario minimo, sem persistencia desnecessaria, assinatura e expiração configuravel.
- Motivo: reduzir risco operacional em atendimento ad-hoc.
- Criterio de pronto: fluxo de suporte rapido com rastreabilidade e menor superficie.

## 4) Ordem sugerida de execucao (6 semanas)

Semana 1-2:

- itens 1, 3, 4, 5

Semana 3-4:

- itens 2, 6, 7, 8

Semana 5-6:

- itens 9, 10 e inicio de 11/12

## 5) Riscos se nao implementar

- aumento de incidentes de conexao sem diagnostico objetivo
- regressao de build por drift de dependencias
- maior tempo medio de resolucao em campo
- desgaste de confianca por eventos de seguranca/percepcao de inseguranca

## 6) Fontes da comunidade (amostra usada)

Issues:

- https://github.com/rustdesk/rustdesk/issues/732
- https://github.com/rustdesk/rustdesk/issues/12704
- https://github.com/rustdesk/rustdesk/issues/13053
- https://github.com/rustdesk/rustdesk/issues/14480
- https://github.com/rustdesk/rustdesk/issues/5609
- https://github.com/rustdesk/rustdesk/issues/6756
- https://github.com/rustdesk/rustdesk/issues/11479
- https://github.com/rustdesk/rustdesk/issues/12293
- https://github.com/rustdesk/rustdesk/issues/14447
- https://github.com/rustdesk/rustdesk/issues/14586
- https://github.com/rustdesk/rustdesk/issues/14267
- https://github.com/rustdesk/rustdesk/issues/13338
- https://github.com/rustdesk/rustdesk/issues/3762
- https://github.com/rustdesk/rustdesk/issues/534
- https://github.com/rustdesk/rustdesk/issues/4280
- https://github.com/rustdesk/rustdesk/issues/14603
- https://github.com/rustdesk/rustdesk/issues/14576

Discussions:

- https://github.com/rustdesk/rustdesk/discussions/14167
- https://github.com/rustdesk/rustdesk/discussions/12518
- https://github.com/rustdesk/rustdesk/discussions/14632
- https://github.com/rustdesk/rustdesk/discussions/11253
- https://github.com/rustdesk/rustdesk/discussions/9011
- https://github.com/rustdesk/rustdesk/discussions/14615
- https://github.com/rustdesk/rustdesk/discussions/14618
- https://github.com/rustdesk/rustdesk/discussions/14616
- https://github.com/rustdesk/rustdesk/discussions/9679

Build/toolchain:

- https://github.com/rustdesk/rustdesk/pull/12795
- https://github.com/rustdesk/rustdesk/pull/8764
