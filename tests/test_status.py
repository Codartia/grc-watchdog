"""Testes do agregador da pagina de status (scripts/status.py).

Rodar: python3 -m unittest discover -s tests -p 'test_*.py'
"""
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(RAIZ, "scripts"))

import status  # noqa: E402

WEB = "https://exemplo.test/"
API1 = "https://exemplo.test/api1"
API2 = "https://exemplo.test/api2"
PUB = "https://pub.exemplo.test/health"

COMPONENTES = {
    "grupos": [
        {"nome": "Aplicações", "componentes": [
            {"id": "web", "nome": "Sistema web", "entrada": [WEB], "dependencias": [API1, API2]},
        ]},
        {"nome": "Integrações", "componentes": [
            {"id": "pub", "nome": "API Pública", "entrada": [PUB], "dependencias": []},
        ]},
    ]
}

T0 = datetime(2026, 11, 25, 15, 0, tzinfo=timezone.utc)  # 12:00 em Brasilia


def comp(cid):
    for g in COMPONENTES["grupos"]:
        for c in g["componentes"]:
            if c["id"] == cid:
                return c


def res(**kw):
    """res(web=True, api1=False, ms_web=4000) -> dict de resultados."""
    mapa = {"web": WEB, "api1": API1, "api2": API2, "pub": PUB}
    saida = {}
    for nome, url in mapa.items():
        ok = kw.get(nome, True)
        if ok is None:
            continue
        saida[url] = {"ok": ok, "ms": kw.get("ms_" + nome, 100)}
    return saida


class EstadoBruto(unittest.TestCase):
    def test_tudo_ok(self):
        self.assertEqual("ok", status.estado_bruto(comp("web"), res()))

    def test_entrada_fora_e_fora(self):
        self.assertEqual("fora", status.estado_bruto(comp("web"), res(web=False)))

    def test_todas_dependencias_fora_e_fora(self):
        self.assertEqual("fora", status.estado_bruto(comp("web"), res(api1=False, api2=False)))

    def test_parte_das_dependencias_e_instavel(self):
        self.assertEqual("instavel", status.estado_bruto(comp("web"), res(api2=False)))

    def test_lento_acima_do_limite(self):
        self.assertEqual("lento", status.estado_bruto(comp("web"), res(ms_api1=3001)))
        self.assertEqual("ok", status.estado_bruto(comp("web"), res(ms_api1=3000)))

    def test_tempo_desconhecido_nao_e_lento(self):
        self.assertEqual("ok", status.estado_bruto(comp("web"), res(ms_web=None)))

    def test_sem_resultado_nenhum_e_none(self):
        self.assertIsNone(status.estado_bruto(comp("web"), {}))

    def test_servico_sem_dependencias(self):
        self.assertEqual("fora", status.estado_bruto(comp("pub"), res(pub=False)))
        self.assertEqual("ok", status.estado_bruto(comp("pub"), res()))


class Agregacao(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.dados = os.path.join(self.dir, "dados")
        self.comp_path = os.path.join(self.dir, "componentes.json")
        with open(self.comp_path, "w", encoding="utf-8") as f:
            json.dump(COMPONENTES, f)
        self.alvos_path = os.path.join(self.dir, "alvos.conf")
        with open(self.alvos_path, "w", encoding="utf-8") as f:
            f.write("# comentario\n")
            for u in (WEB, API1, API2, PUB, "https://painel.exemplo.test/"):
                f.write(f"{u} 200\n")

    def rodada(self, quando, **kw):
        caminho = os.path.join(self.dir, "res.tsv")
        with open(caminho, "w", encoding="utf-8") as f:
            for url, r in res(**kw).items():
                f.write(f"{'OK' if r['ok'] else 'FALHA'}\t{url}\t200\t200\t{r['ms'] if r['ms'] is not None else ''}\n")
        return status.processar(caminho, self.comp_path, self.alvos_path, self.dados, quando)

    def rodada_vazia(self, quando):
        caminho = os.path.join(self.dir, "vazio.tsv")
        open(caminho, "w").close()
        return status.processar(caminho, self.comp_path, self.alvos_path, self.dados, quando)

    @staticmethod
    def c(pub, cid):
        return next(x for x in pub["componentes"] if x["id"] == cid)

    def test_uma_falha_isolada_nao_conta(self):
        self.rodada(T0)
        pub = self.rodada(T0 + timedelta(minutes=5), web=False)
        self.assertEqual("ok", self.c(pub, "web")["estado"])
        pub = self.rodada(T0 + timedelta(minutes=10))
        dia = self.c(pub, "web")["dias"][0]
        self.assertEqual({"amostras": 3, "ok": 3, "fora": 0}, {k: dia[k] for k in ("amostras", "ok", "fora")})

    def test_duas_falhas_seguidas_confirmam_e_reclassificam_a_primeira(self):
        self.rodada(T0)
        self.rodada(T0 + timedelta(minutes=5), web=False)
        pub = self.rodada(T0 + timedelta(minutes=10), web=False)
        web = self.c(pub, "web")
        self.assertEqual("fora", web["estado"])
        self.assertEqual("2026-11-25T15:10:00Z", web["desde"])
        dia = web["dias"][0]
        self.assertEqual((3, 1, 2), (dia["amostras"], dia["ok"], dia["fora"]))
        # Volta: estado ok de novo, contagem preservada.
        pub = self.rodada(T0 + timedelta(minutes=15))
        self.assertEqual("ok", self.c(pub, "web")["estado"])
        self.assertEqual(2, self.c(pub, "web")["dias"][0]["fora"])

    def test_falhas_separadas_por_mais_de_15_min_nao_se_confirmam(self):
        self.rodada(T0, web=False)
        pub = self.rodada(T0 + timedelta(minutes=20), web=False)
        self.assertEqual("ok", self.c(pub, "web")["estado"])
        self.assertEqual(0, self.c(pub, "web")["dias"][0]["fora"])

    def test_estados_ruins_diferentes_tambem_confirmam(self):
        self.rodada(T0, ms_web=5000)  # lento
        pub = self.rodada(T0 + timedelta(minutes=5), web=False)  # fora
        web = self.c(pub, "web")
        self.assertEqual("fora", web["estado"])
        dia = web["dias"][0]
        self.assertEqual((1, 1, 0), (dia["lento"], dia["fora"], dia["ok"]))

    def test_rodada_sem_resultado_nao_conta(self):
        self.rodada(T0)
        pub = self.rodada_vazia(T0 + timedelta(minutes=5))
        self.assertEqual(1, self.c(pub, "web")["dias"][0]["amostras"])
        self.assertEqual("2026-11-25T15:00:00Z", pub["ultima_amostra"])
        self.assertEqual("2026-11-25T15:05:00Z", pub["gerado_em"])

    def test_dia_de_brasilia(self):
        # 02:30 UTC de 26/11 ainda e 25/11 em Brasilia.
        pub = self.rodada(datetime(2026, 11, 26, 2, 30, tzinfo=timezone.utc))
        self.assertEqual("2026-11-25", self.c(pub, "web")["dias"][0]["dia"])

    def test_reclassifica_no_dia_da_primeira_falha(self):
        # 23:55 e 00:00 de Brasilia: a primeira falha e do dia anterior.
        self.rodada(datetime(2026, 11, 26, 2, 55, tzinfo=timezone.utc), web=False)
        pub = self.rodada(datetime(2026, 11, 26, 3, 0, tzinfo=timezone.utc), web=False)
        dias = {d["dia"]: d for d in self.c(pub, "web")["dias"]}
        self.assertEqual(1, dias["2026-11-25"]["fora"])
        self.assertEqual(0, dias["2026-11-25"]["ok"])
        self.assertEqual(1, dias["2026-11-26"]["fora"])

    def test_poda_90_dias(self):
        self.rodada(T0 - timedelta(days=95))
        self.rodada(T0 - timedelta(days=89))
        pub = self.rodada(T0)
        dias = [d["dia"] for d in self.c(pub, "web")["dias"]]
        self.assertEqual(["2026-08-28", "2026-11-25"], dias)

    def test_instavel_por_api(self):
        self.rodada(T0, api1=False)
        pub = self.rodada(T0 + timedelta(minutes=5), api1=False)
        self.assertEqual("instavel", self.c(pub, "web")["estado"])
        self.assertEqual("ok", self.c(pub, "pub")["estado"])

    def test_publico_traz_grupo_nome_e_tempo(self):
        pub = self.rodada(T0, ms_web=321)
        web = self.c(pub, "web")
        self.assertEqual(("Aplicações", "Sistema web", 321), (web["grupo"], web["nome"], web["tempo_ms"]))
        with open(os.path.join(self.dados, "status.json"), encoding="utf-8") as f:
            self.assertEqual(pub, json.load(f))

    def test_componente_com_url_fora_do_alvos_conf_e_recusado(self):
        with open(self.alvos_path, "w", encoding="utf-8") as f:
            f.write(f"{WEB} 302\n")
        with self.assertRaises(ValueError):
            self.rodada(T0)


class ConfiguracaoReal(unittest.TestCase):
    """O componentes.json do site precisa bater com o alvos.conf do vigia."""

    def test_componentes_reais_validos(self):
        comps = status.ler_componentes(os.path.join(RAIZ, "site", "componentes.json"))
        erros = status.validar(comps, status.ler_alvos(os.path.join(RAIZ, "alvos.conf")))
        self.assertEqual([], erros)

    def test_incidentes_exemplo_valido(self):
        caminho = os.path.join(RAIZ, "site", "incidentes.json")
        with open(caminho, encoding="utf-8") as f:
            dados = json.load(f)
        ids = {c["id"] for c in status.ler_componentes(os.path.join(RAIZ, "site", "componentes.json"))}
        for inc in dados["incidentes"]:
            self.assertIn(inc["tipo"], ("incidente", "manutencao"))
            for cid in inc["componentes"]:
                self.assertIn(cid, ids, inc["id"])


if __name__ == "__main__":
    unittest.main()
