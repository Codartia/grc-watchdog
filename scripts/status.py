#!/usr/bin/env python3
"""Agrega as rodadas do vigia na situacao e no historico da pagina de status.

Uso:
  status.py --resultados res.tsv --componentes site/componentes.json \
            --alvos alvos.conf --dados DIR [--agora 2026-11-25T15:00:00Z]

Le DIR/estado.json (memoria interna, pode nao existir), soma a rodada atual e
reescreve DIR/estado.json e DIR/status.json (o que a pagina le).

Regras (as mesmas do alerta, para a pagina nao contradizer o WhatsApp):
  * Estado bruto de um servico numa rodada:
      - fora      a entrada falhou, ou todas as dependencias falharam;
      - instavel  parte das dependencias falhou;
      - lento     tudo respondeu, mas algum alvo passou de LIMITE_LENTO_MS;
      - ok        o resto.
  * Problema so conta depois de 2 rodadas seguidas ruins. A primeira rodada ruim
    entra como "ok pendente"; se a seguinte tambem for ruim, a primeira e
    reclassificada. Assim o minuto de troca de um deploy nao vira barra laranja.
  * Rodada sem resultado (a sonda quebrou) nao conta nem como ok nem como queda:
    a pagina mostra "dados desatualizados" pelo horario da ultima amostra.
  * O dia e o de Brasilia (UTC-3 fixo: o Brasil nao tem horario de verao desde
    2019; usar offset fixo evita depender do tzdata, que falta no Python do
    Windows onde a suite tambem roda).

So biblioteca padrao, de proposito: roda no runner Ubuntu e no Git Bash local.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

BRASILIA = timezone(timedelta(hours=-3))
LIMITE_LENTO_MS = 3000
DIAS_GUARDADOS = 90
# Duas rodadas so se confirmam se a distancia entre elas for de no maximo isto.
# O disparo e a cada 5 min, mas atrasa e pula (ver README); 15 min aceita uma
# rodada perdida sem ligar duas falhas separadas por uma hora.
JANELA_CONFIRMACAO = timedelta(minutes=15)

ESTADOS_RUINS = ("lento", "instavel", "fora")
SEVERIDADE = {"ok": 0, "lento": 1, "instavel": 2, "fora": 3}


# ---------------------------------------------------------------- leitura

def ler_alvos(caminho: str) -> set[str]:
    urls = set()
    with open(caminho, encoding="utf-8") as f:
        for linha in f:
            partes = linha.split()
            if len(partes) >= 2 and not partes[0].startswith("#"):
                urls.add(partes[0])
    return urls


def ler_componentes(caminho: str) -> list[dict]:
    with open(caminho, encoding="utf-8") as f:
        dados = json.load(f)
    lista = []
    for grupo in dados["grupos"]:
        for c in grupo["componentes"]:
            lista.append({**c, "grupo": grupo["nome"]})
    return lista


def ler_resultados(caminho: str) -> dict[str, dict]:
    """url -> {"ok": bool, "ms": int|None}. Linha malformada e ignorada."""
    res: dict[str, dict] = {}
    if not os.path.exists(caminho):
        return res
    with open(caminho, encoding="utf-8") as f:
        for linha in f:
            partes = linha.rstrip("\n").split("\t")
            if len(partes) < 4 or partes[0] not in ("OK", "FALHA"):
                continue
            ms = partes[4] if len(partes) > 4 else ""
            res[partes[1]] = {"ok": partes[0] == "OK", "ms": int(ms) if ms.isdigit() else None}
    return res


def validar(componentes: list[dict], alvos: set[str]) -> list[str]:
    erros = []
    ids = set()
    for c in componentes:
        if c["id"] in ids:
            erros.append(f"id repetido: {c['id']}")
        ids.add(c["id"])
        if not c.get("entrada"):
            erros.append(f"{c['id']}: sem entrada")
        for u in list(c.get("entrada", [])) + list(c.get("dependencias", [])):
            if u not in alvos:
                erros.append(f"{c['id']}: {u} nao esta no alvos.conf")
    return erros


# ---------------------------------------------------------------- regras

def estado_bruto(comp: dict, res: dict[str, dict]) -> str | None:
    entrada = [res[u] for u in comp["entrada"] if u in res]
    deps = [res[u] for u in comp.get("dependencias", []) if u in res]
    if not entrada and not deps:
        return None
    if any(not r["ok"] for r in entrada):
        return "fora"
    falhas = sum(1 for r in deps if not r["ok"])
    if deps and falhas == len(deps):
        return "fora"
    if falhas:
        return "instavel"
    tempos = [r["ms"] for r in entrada + deps if r["ms"] is not None]
    if tempos and max(tempos) > LIMITE_LENTO_MS:
        return "lento"
    return "ok"


def dia_local(momento: datetime) -> str:
    return momento.astimezone(BRASILIA).strftime("%Y-%m-%d")


def iso(momento: datetime) -> str:
    return momento.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ler_iso(texto: str) -> datetime:
    return datetime.strptime(texto, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def dia_vazio() -> dict:
    return {"amostras": 0, "ok": 0, "lento": 0, "instavel": 0, "fora": 0}


def registrar(estado: dict, comp_id: str, bruto: str | None, agora: datetime) -> None:
    """Soma uma rodada de um servico na memoria (estado), aplicando a regra dos 2."""
    mem = estado["componentes"].setdefault(
        comp_id, {"confirmado": "ok", "desde": iso(agora), "anterior": None, "dias": {}})
    if bruto is None:
        return

    anterior = mem.get("anterior")
    if anterior and agora - ler_iso(anterior["em"]) > JANELA_CONFIRMACAO:
        anterior = None

    dia = dia_local(agora)
    dias = mem["dias"]
    registro = dias.setdefault(dia, dia_vazio())
    registro["amostras"] += 1

    pendente = False
    if bruto == "ok":
        registro["ok"] += 1
        novo = "ok"
    elif anterior and anterior["estado"] in ESTADOS_RUINS:
        # Segunda rodada ruim seguida: confirma esta e a anterior.
        registro[bruto] += 1
        if anterior.get("pendente") and anterior["dia"] in dias:
            dia_ant = dias[anterior["dia"]]
            if dia_ant["ok"] > 0:
                dia_ant["ok"] -= 1
                dia_ant[anterior["estado"]] += 1
        novo = bruto
    else:
        # Primeira rodada ruim: conta como ok ate a proxima confirmar.
        registro["ok"] += 1
        pendente = True
        novo = mem["confirmado"]

    if novo != mem["confirmado"]:
        mem["confirmado"] = novo
        mem["desde"] = iso(agora)
    mem["anterior"] = {"estado": bruto, "em": iso(agora), "dia": dia, "pendente": pendente}


def podar(estado: dict, agora: datetime) -> None:
    limite = (agora.astimezone(BRASILIA) - timedelta(days=DIAS_GUARDADOS - 1)).strftime("%Y-%m-%d")
    for mem in estado["componentes"].values():
        mem["dias"] = {d: v for d, v in mem["dias"].items() if d >= limite}


def publico(estado: dict, componentes: list[dict], agora: datetime, res: dict[str, dict]) -> dict:
    saida = []
    for c in componentes:
        mem = estado["componentes"].get(c["id"], {"confirmado": "ok", "desde": None, "dias": {}})
        dias = [{"dia": d, **v} for d, v in sorted(mem["dias"].items())]
        tempos = [res[u]["ms"] for u in c["entrada"] if u in res and res[u]["ms"] is not None]
        saida.append({
            "id": c["id"],
            "nome": c["nome"],
            "descricao": c.get("descricao", ""),
            "grupo": c["grupo"],
            "estado": mem["confirmado"],
            "desde": mem.get("desde"),
            "tempo_ms": max(tempos) if tempos else None,
            "dias": dias,
        })
    return {
        "versao": 1,
        "gerado_em": iso(agora),
        "ultima_amostra": estado.get("ultima_amostra"),
        "intervalo_min": 5,
        "dias_guardados": DIAS_GUARDADOS,
        "componentes": saida,
    }


# ---------------------------------------------------------------- principal

def processar(resultados: str, componentes_path: str, alvos_path: str, dados: str, agora: datetime) -> dict:
    componentes = ler_componentes(componentes_path)
    erros = validar(componentes, ler_alvos(alvos_path))
    if erros:
        raise ValueError("componentes.json invalido: " + "; ".join(erros))

    caminho_estado = os.path.join(dados, "estado.json")
    if os.path.exists(caminho_estado):
        with open(caminho_estado, encoding="utf-8") as f:
            estado = json.load(f)
    else:
        estado = {"versao": 1, "ultima_amostra": None, "componentes": {}}

    res = ler_resultados(resultados)
    if res:
        for c in componentes:
            registrar(estado, c["id"], estado_bruto(c, res), agora)
        estado["ultima_amostra"] = iso(agora)
    podar(estado, agora)

    os.makedirs(dados, exist_ok=True)
    gravar(caminho_estado, estado)
    pub = publico(estado, componentes, agora, res)
    gravar(os.path.join(dados, "status.json"), pub)
    return pub


def gravar(caminho: str, conteudo: dict) -> None:
    tmp = caminho + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(conteudo, f, ensure_ascii=False, indent=1, sort_keys=False)
        f.write("\n")
    os.replace(tmp, caminho)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--resultados", required=True)
    p.add_argument("--componentes", required=True)
    p.add_argument("--alvos", required=True)
    p.add_argument("--dados", required=True)
    p.add_argument("--agora", help="ISO UTC (so para teste); padrao = agora")
    a = p.parse_args(argv)
    agora = ler_iso(a.agora) if a.agora else datetime.now(timezone.utc).replace(microsecond=0)
    pub = processar(a.resultados, a.componentes, a.alvos, a.dados, agora)
    for c in pub["componentes"]:
        print(f"{c['id']}: {c['estado']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
