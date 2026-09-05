# grc-watchdog

Vigia externo do Graces (cliente Quorum): sonda os endpoints públicos do Graces de fora da AWS e
avisa por WhatsApp quando algum deles para de responder. Existe porque todo o resto da
observabilidade do Graces mora **dentro** da AWS do cliente e cai junto com ela — este repo é o
único sinal que sobrevive a uma queda total da região.

## As duas camadas

- **Camada 1 — sondador ativo:** um workflow do GitHub Actions (`vigia.yml`) roda a cada 5 minutos,
  chama cada alvo de `alvos.conf` e, depois de 2 ciclos consecutivos em falha, manda uma mensagem
  pelo Z-API. Também avisa quando os alvos voltam a responder.
- **Camada 2 — dead man's switch:** a cada execução, com sucesso ou falha, o workflow bate ponto
  numa URL do [healthchecks.io](https://healthchecks.io). Se esse ping sumir por mais de 20 minutos,
  o healthchecks.io dispara sozinho — por webhook (Z-API) e por e-mail. É a camada que percebe a
  camada 1 tendo morrido (outage do GitHub, cron pulado, auto-disable por inatividade etc.), porque
  um sondador sozinho não sabe avisar da própria morte.

Cada camada cobre o ponto cego da outra:

| Cenário | Quem avisa |
|---|---|
| Uma superfície do Graces cai (ex.: só a Public API) | Camada 1 |
| Graces inteiro fora do ar | Camada 1 |
| Região AWS inteira fora do ar | Camada 1 (mora no GitHub; Z-API é terceiro) |
| Workflow parou de rodar (outage GH, cron pulado, auto-disable de 60 dias) | Camada 2 |
| GitHub **e** AWS caem juntos | Camada 2 (healthchecks.io é um terceiro independente) |
| Z-API fora do ar | E-mail da camada 2 |
| healthchecks.io **e** GitHub caem juntos | **Ninguém** — risco aceito, ver §12 da spec |

Detalhe completo da arquitetura e das decisões: a spec `T0.8-vigia-externo-spec.md`, na
documentação interna de observabilidade do projeto (repositório privado).

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
ZAPI_INSTANCE_ID=x ZAPI_INSTANCE_TOKEN=y ZAPI_CLIENT_TOKEN=z ZAPI_DESTINO=w \
  bash scripts/notifica-zapi.sh --dry-run "teste"
```

Imprime o destino e o payload que seriam enviados, sem chamar o Z-API de verdade.

## Secrets

O workflow `vigia.yml` precisa destes 5 *Actions secrets*, configurados em
`Codartia/grc-watchdog` → Settings → Secrets and variables → Actions. Nenhum valor mora no código.

| Secret | Conteúdo |
|---|---|
| `ZAPI_INSTANCE_ID` | id da instância Z-API |
| `ZAPI_INSTANCE_TOKEN` | token da instância |
| `ZAPI_CLIENT_TOKEN` | valor do header `Client-Token` |
| `ZAPI_DESTINO` | groupId do grupo de alertas (ou número, enquanto o grupo não existe) |
| `HEALTHCHECKS_PING_URL` | URL de ping do check no healthchecks.io |

## ⚠️ Aviso de rotação

As credenciais do Z-API aqui são uma segunda cópia das que vivem no SSM `/graces/zapi/notifier` da
AWS. A duplicação é deliberada: um vigia que precisasse ler o SSM não funcionaria durante uma queda
da AWS.

**Rotacionar o token exige atualizar os dois lugares, e nada aqui avisa se você esquecer.** O
`notifica-zapi.sh` só é chamado quando há alerta para enviar — em operação normal ele nunca roda,
então uma credencial vencida não é exercitada e não aparece em lugar nenhum. A camada 2 também não
pega: o batimento do heartbeat é enviado com `if: always()`, de propósito, então ele continua
chegando mesmo com o envio quebrado. O resultado é que um token errado fica silencioso até a
primeira queda de verdade, e aí a mensagem não sai.

Por isso, ao rotacionar: atualize o SSM e o secret deste repositório **na mesma operação**, e valide
na hora enviando uma mensagem de teste à mão com os valores novos:
```bash
ZAPI_INSTANCE_ID=... ZAPI_INSTANCE_TOKEN=... ZAPI_CLIENT_TOKEN=... ZAPI_DESTINO=... \
  bash scripts/notifica-zapi.sh "teste de credencial apos rotacao"
```
(sem `--dry-run` — o dry-run não chama a API e portanto não valida credencial nenhuma.)

## Como trocar o destino

Trocar só o secret `ZAPI_DESTINO` (número por groupId, ou um groupId por outro), em Settings →
Secrets and variables → Actions. Não mexe em nenhum código.

## Como adicionar ou remover alvo

Editar `alvos.conf` (uma linha por alvo, formato `<url> <codigo-http-esperado>`), rodar
`bash scripts/sonda.sh` para confirmar que o alvo novo responde como esperado, e commitar.
