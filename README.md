# grc-watchdog

Vigia externo do Graces (cliente Quorum): sonda os endpoints públicos do Graces de fora da AWS e
avisa por WhatsApp quando algum deles para de responder. Existe porque todo o resto da
observabilidade do Graces mora **dentro** da AWS do cliente e cai junto com ela — este repo é o
único sinal que sobrevive a uma queda total da região.

## As duas camadas

- **Camada 1 — sondador ativo:** um workflow do GitHub Actions (`vigia.yml`) roda a cada 5 minutos,
  chama cada alvo de `alvos.conf` e, depois de 2 ciclos consecutivos em falha, manda uma mensagem
  pela Levazap. Também avisa quando os alvos voltam a responder. Quem garante os 5 minutos é um cron
  externo que dispara o workflow pela API — ver [Disparo externo](#disparo-externo).
- **Camada 2 — dead man's switch:** a cada execução, com sucesso ou falha, o workflow bate ponto
  numa URL do [healthchecks.io](https://healthchecks.io). Se esse ping sumir por mais de 20 minutos,
  o healthchecks.io dispara sozinho — por webhook (Levazap) e por e-mail. É a camada que percebe a
  camada 1 tendo morrido (outage do GitHub, cron pulado, auto-disable por inatividade etc.), porque
  um sondador sozinho não sabe avisar da própria morte.
  Uma queda do Graces **não** muda esse batimento: o que ele prova é *"o vigia rodou"*, não *"o
  Graces está bem"*. O que muda é o vigia não ter conseguido fazer o próprio trabalho — envio
  quebrado ou memória indisponível —, e aí o ping vai para `<ping-url>/fail`, que derruba o check
  na hora em vez de esperar o grace.

Cada camada cobre o ponto cego da outra:

| Cenário | Quem avisa |
|---|---|
| Uma superfície do Graces cai (ex.: só a Public API) | Camada 1 |
| Graces inteiro fora do ar | Camada 1 |
| Região AWS inteira fora do ar | Camada 1 (mora no GitHub; Levazap é terceiro) |
| Workflow parou de rodar (outage GH, cron pulado **por mais de 20 min**, auto-disable de 60 dias) | Camada 2 |
| Disparo externo parou (token vencido ou revogado, cron-job.org fora) | Camada 2 (o ping rareia para o ritmo do `schedule`) e o e-mail de falha do próprio cron-job.org |
| GitHub **e** AWS caem juntos | Camada 2 (healthchecks.io é um terceiro independente) |
| Camada 2 precisa alertar e a Levazap está fora | E-mail da camada 2 (redundância de canal) |
| Envio do alerta falha no instante da queda (chave revogada, Levazap fora) | Camada 2 — o batimento daquela execução vai para `/fail` e o healthchecks.io dispara na hora |
| Memória do vigia indisponível (`gh run list` falhando) | Camada 2 pelo `/fail`; e, se o ciclo atual estiver em falha, a camada 1 alerta mesmo assim |
| Caminho de envio quebrado (token vencido) durante operação normal, sem queda nenhuma | **Ninguém** — o envio só é exercitado quando há alerta; ver o aviso de rotação |
| healthchecks.io **e** GitHub caem juntos | **Ninguém** — risco aceito: dois terceiros independentes caindo no mesmo instante |

Detalhe completo da arquitetura e das decisões: a spec `T0.8-vigia-externo-spec.md`, na
documentação interna de observabilidade do projeto (repositório privado).

## Disparo externo

O `schedule` do GitHub não entrega os 5 minutos. Em repositório público ele é "melhor esforço" e,
medido entre 09/09 e 27/09/2026, rodou de 5 a 8 vezes **por dia** em vez de 288. Por isso o gatilho
principal é um job no [cron-job.org](https://cron-job.org) que chama, a cada 5 minutos:

```
POST https://api.github.com/repos/Codartia/grc-watchdog/actions/workflows/vigia.yml/dispatches
Authorization: Bearer <token>
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28

{"ref":"main"}
```

A resposta esperada é **204**. O job está configurado para avisar por e-mail quando a chamada falha.

O `<token>` é um *fine-grained personal access token* com acesso **só a este repositório** e uma
única permissão: **Actions: Read and write**. O pior que ele permite é disparar, cancelar ou apagar
execuções deste workflow — não lê segredo, não escreve código.

⚠️ **O token vence.** Quando vencer, o disparo passa a receber 401, o cron-job.org avisa por e-mail
e o vigia cai para o ritmo do `schedule` — o que faz a camada 2 acusar batimento atrasado. Para
rotacionar: gerar um token novo com o mesmo escopo, trocar o header no job do cron-job.org, usar o
botão de execução de teste do job e conferir que apareceu uma execução `workflow_dispatch` nova em
Actions. Só então revogar o token antigo.

## Como rodar a suite

```bash
bash tests/run.sh
```

## Como sondar à mão

```bash
bash scripts/sonda.sh
```

Imprime uma linha por alvo de `alvos.conf`, no formato `OK|FALHA <url> <obtido> <esperado>` — o
código HTTP obtido (ou `000` se nem conectou) contra o esperado. Sai com código 0 se todos os alvos
passaram, 1 se algum falhou.

## Como testar o envio sem enviar

```bash
LEVAZAP_API_KEY=x LEVAZAP_INSTANCE_ID=y LEVAZAP_DESTINO=120360000000000000@g.us   bash scripts/notifica-levazap.sh --dry-run "teste"
```

Imprime o destino, a URL e o payload que seriam enviados, sem chamar a Levazap e sem imprimir a chave.

## Secrets

O workflow `vigia.yml` precisa destes 4 *Actions secrets*, configurados em
`Codartia/grc-watchdog` → Settings → Secrets and variables → Actions. Nenhum valor mora no código.
Eles são gravados por `code/infra/observabilidade/armar-vigia.ps1` (no repositório do Graces), que
lê o SSM `/graces/levazap/notifier` e não imprime valor nenhum.

| Secret | Conteúdo |
|---|---|
| `LEVAZAP_API_KEY` | chave da API da Levazap (`wag_live_…`) |
| `LEVAZAP_INSTANCE_ID` | id da instância que envia os alertas |
| `LEVAZAP_DESTINO` | JID do grupo de alertas (`…@g.us`) |
| `HEALTHCHECKS_PING_URL` | URL de ping do check no healthchecks.io |

Os `ZAPI_*` antigos saem no desligamento da Z-API (troca Z-API → Levazap, 05/11/2026).

## Canário do canal

Todo ciclo roda `scripts/canario-canal.sh`: a instância da Levazap precisa responder `CONNECTED`.
Qualquer outra coisa (desconectada, chave revogada, Levazap fora) manda o batimento daquela execução
para `<ping-url>/fail`, e o healthchecks.io avisa **por e-mail**, fora do WhatsApp. Foi a falta disto
que deixou a Z-API muda 36 dias (assinatura vencida em 03/08/2026, descoberta em 08/09) sem ninguém
notar: o envio só é exercitado quando há alerta, e a credencial vencida ficava silenciosa até a
primeira queda de verdade.

## ⚠️ Aviso de rotação

A chave da Levazap aqui é uma cópia da que vive no SSM `/graces/levazap/notifier` da AWS. A
duplicação é deliberada: um vigia que precisasse ler o SSM não funcionaria durante uma queda da AWS.
Ela também mora no webhook do healthchecks.io (configurado à mão) e no segredo do Painel de Controle.
A chave vale para a **conta inteira** da Levazap: rotacionar é trocar em todos esses lugares.

Ao rotacionar: atualize o SSM, rode o `armar-vigia.ps1` e o webhook do healthchecks.io **na mesma
operação**. O canário acusa a chave revogada no ciclo seguinte (até 5 min), então um lugar esquecido
aparece como e-mail do healthchecks.io, e não como silêncio.

## Como trocar o destino

Trocar só o secret `LEVAZAP_DESTINO` (o JID de outro grupo, `…@g.us`), em Settings → Secrets and
variables → Actions. O número da instância precisa ser membro do grupo. Não mexe em nenhum código.

## Como adicionar ou remover alvo

Editar `alvos.conf` (uma linha por alvo, formato `<url> <codigo-http-esperado>`), rodar
`bash scripts/sonda.sh` para confirmar que o alvo novo responde como esperado, e commitar.
