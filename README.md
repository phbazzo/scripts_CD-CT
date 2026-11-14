# MONAN com ICON e IFS como condição inicial e de contorno

> **English summary.** Fork of the official MONAN workflow scripts
> ([`monanadmin/scripts_CD-CT`](https://github.com/monanadmin/scripts_CD-CT), release **1.6.0**) that adds
> the **DWD ICON** and **ECMWF IFS** open-data forecasts as initial and lateral boundary conditions
> (`EXP=ICON` / `EXP=IFS`), next to the existing GFS and ERA5. Data are downloaded automatically, converted
> straight to WPS intermediate files (no `ungrib`/Vtable) and fed to `init_atmosphere`. Global and regional
> modes, optional custom vertical grid (`config_specified_zeta_levels`). Tested end to end (regional 3 km mesh,
> 75 levels) with GFS, ICON and IFS. Documentation is in Portuguese.

Este repositório é um *fork* dos scripts oficiais do MONAN (`scripts_CD-CT` 1.6.0). Ele acrescenta duas
novas fontes de condição inicial (CI) e de contorno lateral (CC):

| `EXP` | Fonte | Grade original | Níveis verticais | Disponível online | Passa pelo `ungrib`? |
|---|---|---|---|---|---|
| `GFS` | NCEP (já existia) | 0,25° | 34 de pressão | — | sim |
| `ERA` | ERA5 (já existia) | 0,25° | pressão | arquivo | sim |
| **`ICON`** | DWD, ICON global | icosaédrica ~13 km → 0,125° | **~75 níveis nativos do modelo** (ou 18 de pressão) | **últimas ~24 h** | não |
| **`IFS`** | ECMWF, IFS HRES | 0,1° (ou 0,25°) | 14 de pressão | **últimos ~3 dias** (ou arquivo na AWS desde 2023) | não |

O resto da cadeia (`init_atmosphere`, modelo, pós) é o do MONAN, sem alteração de física ou de dinâmica.
As mudanças nos scripts oficiais são pequenas e ficam marcadas com `[ICON/IFS]`
([lista completa](docs/08-mudancas-nos-scripts-oficiais.md)).

---

## Estado de validação

| O quê | Situação |
|---|---|
| Cadeia completa (pré-processamento → modelo → pós) com L75 (`ZETA_LEVELS=zeta_levels.L75.txt`), regional | **testada** com `EXP=GFS`, `ICON` e `IFS` em supercomputador PBS/Cray, malha regional de 3 km no Sul do Brasil (novembro de 2026, versão de desenvolvimento destes scripts) |
| ICON regional, níveis do modelo (CI e LBC) | **testado** (ver linha acima) |
| IFS regional, rodadas 00/12 UTC | **testado** (ver linha acima). Rodadas 06/18 UTC (stream `oper`, detectado automaticamente) ainda não testadas |
| Modo global com ICON/IFS | implementado, **não testado** (exige muita memória no ICON, ver avisos) |
| Qualidade das previsões | **não avaliada.** Compare com uma rodada GFS antes de usar em trabalho científico |

Relate problemas e resultados nas *issues* do repositório.

---

## Início rápido

### Opção A — usar este fork como seu `scripts_CD-CT`

```bash
git clone https://github.com/phbazzo/scripts_CD-CT.git          # a pasta TEM de se chamar scripts_CD-CT
cd scripts_CD-CT/scripts
./1.install_monan.bash https://github.com/monanadmin/MONAN-Model.git 2.0.0-rc 1.2.0   # como no MONAN oficial
```

### Opção B — aplicar numa instalação existente (`scripts_CD-CT` 1.6.0)

```bash
git clone https://github.com/phbazzo/scripts_CD-CT.git scripts_CD-CT_icon_ifs
./scripts_CD-CT_icon_ifs/instalar.sh /caminho/para/scripts_CD-CT
```

O `instalar.sh` confere a versão, testa se o patch aplica sem conflito, guarda cópia dos arquivos originais,
aplica e verifica se o Python e o `cdo` necessários existem. Detalhes em [docs/02-instalacao.md](docs/02-instalacao.md).

### Ambiente Python (uma vez)

A conversão dos GRIB2 precisa de **Python com `numpy` e `eccodes`** e, para o ICON, do **`cdo`**:

```bash
conda create -n monan_grib -c conda-forge python numpy python-eccodes cdo
```

Não é preciso ativar o ambiente: os scripts procuram sozinhos um Python com `numpy` + `eccodes` nos ambientes
conda do usuário (função `find_python` do `setenv.bash`) e usam o `cdo` do mesmo ambiente.

### Rodar

Os comandos e argumentos são os mesmos do MONAN oficial; só muda o `EXP`. **Rode no nó de login**, porque o
pré-processamento baixa os dados e precisa de internet:

```bash
cd scripts_CD-CT/scripts
./2.pre_processing.bash ICON 655362 $(date -u +%Y%m%d)00 24    # baixa, converte, init (e LBC se regional)
./3.run_model.bash      ICON 655362 $(date -u +%Y%m%d)00 24
./4.run_post.bash       ICON 655362 $(date -u +%Y%m%d)00 24
```

Para o IFS, troque `ICON` por `IFS`. Para rodadas de dias anteriores do IFS: `export IFS_SOURCE=aws`.

---

## ⚠️ Avisos importantes (leia antes de rodar)

1. **Só rodadas recentes estão online.** O DWD mantém o ICON por ~24 h e o ECMWF mantém o IFS por ~3 dias
   (o IFS fica também no arquivo da AWS desde 2023). Não existe arquivo público gratuito do ICON: **para estudar um
   caso passado com ICON, baixe os dados no dia.** Os arquivos baixados ficam em `datain/ICON|IFS/LABELI` e são
   reaproveitados.
2. **A mesma data com duas fontes se sobrescreve.** Os scripts oficiais gravam em `dataout/LABELI/{Pre,Model,Post}`
   sem separar por `EXP`. Rodar o `2.pre_processing.bash` do GFS depois do ICON troca o `x1.RES.init.nc` e as
   `lbc.*.nc`, e o `3.run_model.bash ICON` passaria a rodar com CI do GFS. Para comparar fontes, termine a cadeia
   de uma fonte (2 → 3 → 4) e renomeie a pasta antes da próxima (`mv dataout/LABELI dataout/LABELI.ICON`).
   Nunca rode duas fontes da mesma data ao mesmo tempo.
3. **Download e conversão rodam no nó de login.** Eles usam CPU, memória e disco: ICON regional com 48 h e LBC de
   3 em 3 h baixa **~22 GB** (~1,3 GB por horário) e usa até `ICON_NPROC` processos. O IFS a 0,1° baixa ~0,2 GB
   por horário. O ICON **global** gera um intermediário de vários GB e precisa de **~10 GB de RAM** na conversão.
   Confira as regras de uso do nó de login do seu centro.
4. **Intervalo das LBCs (`LBCINT`).** ICON: múltiplo de 1 h (de 3 h depois de +78 h), até +180 h (00/12 UTC) ou
   +120 h (06/18 UTC). IFS: múltiplo de 3 h (de 6 h depois de +144 h); as rodadas 06/18 UTC vão só até +144 h. Os
   scripts conferem isso antes de baixar.
5. **Resolução vertical da CI.** O ICON nos níveis do modelo (padrão) traz ~75 níveis, com todos os níveis nativos
   até 16 km. O IFS do *open data* tem **só 14 níveis de pressão**, com 1000, 925 e 850 hPa na camada limite, e o
   ICON em pressão tem 18. A estrutura da camada limite na CI fica bem mais grosseira nesses dois casos. O ICON
   em pressão também vai só até **30 hPa (~24 km)**, abaixo do topo padrão do MONAN (30 km), e o IFS chega a
   10 hPa (~31 km).
6. **Solo, neve e gelo vêm de outro modelo.** A umidade e a temperatura do solo do ICON (8 camadas de umidade, 9 níveis de
   temperatura) e do IFS (4 camadas) são reagrupadas nas 4 camadas do GFS (0–10, 10–40, 40–100 e 100–200 cm). O Noah-MP do MONAN usa
   outra textura de solo, então espere um ajuste nas primeiras horas. No IFS, o gelo marinho é binário
   (`sithick > 0`), porque a fração de gelo não está no *open data*.
7. **Recorte automático no modo regional.** Com `ICON_BOX=auto` (padrão), a caixa lat-lon dos dados é a da sua malha
   (`x1.RES.static.nc`) mais 5° de margem (`GRIB_BOX_MARGIN`). Se trocar de malha, nada precisa mudar. Para usar
   uma caixa fixa, defina `ICON_BOX=lon1,lon2,lat1,lat2`, que precisa cobrir toda a malha.
8. **Grade vertical própria é opcional e afeta tudo.** `NVERTLEV`/`ZETA_LEVELS` (no `setenv.bash`) mudam o
   `init.nc`, as LBCs e o nome dos arquivos (`...L75.nc`). Também mudam o custo (+~36 % com 75 níveis em vez de 55)
   e podem exigir outro `config_dt` (CFL vertical). Rode de novo o pré-processamento depois de mudar.
   Veja [docs/05-niveis-verticais.md](docs/05-niveis-verticais.md).
9. **Mensagens inofensivas no log:** `ECCODES ERROR : pack_bytes: Wrong size (20) for section2Padding` (filtrada)
   e `bunzip2: ... trailing garbage after EOF ignored`. Ambas vêm dos arquivos do DWD e não afetam os dados.
10. **Dados de terceiros.** ICON (DWD Open Data) e IFS (ECMWF Open Data) exigem citação da fonte. Confira os termos
    de uso de cada provedor ([DWD](https://www.dwd.de/EN/service/copyright/copyright_node.html),
    [ECMWF](https://www.ecmwf.int/en/forecasts/datasets/open-data)).

Lista completa e soluções: [docs/07-avisos-e-solucao-de-problemas.md](docs/07-avisos-e-solucao-de-problemas.md).

---

## Documentação

| Documento | Conteúdo |
|---|---|
| [01 – Visão geral](docs/01-visao-geral.md) | Como funciona: do GRIB2 ao `init.nc`, por que não usar o `ungrib` e o papel de cada componente |
| [02 – Instalação](docs/02-instalacao.md) | Fork × patch, ambiente Python/`cdo`, como conferir |
| [03 – ICON](docs/03-icon.md) | Dados do DWD, níveis do modelo × pressão, escolha dos níveis, remapeamento, solo |
| [04 – IFS](docs/04-ifs.md) | *Open data* do ECMWF, resoluções, fontes (portal/AWS), streams, campos |
| [05 – Níveis verticais](docs/05-niveis-verticais.md) | `NVERTLEV`, `ZETA_LEVELS`, `zeta_levels.py`, relação com os níveis do ICON |
| [06 – Configuração por objetivo](docs/06-configuracao.md) | Todas as variáveis e receitas (outra região, casos passados, menos disco, global...) |
| [07 – Avisos e solução de problemas](docs/07-avisos-e-solucao-de-problemas.md) | O que pode dar errado, mensagens de erro e o que fazer |
| [08 – Mudanças nos scripts oficiais](docs/08-mudancas-nos-scripts-oficiais.md) | Cada alteração, arquivo por arquivo, para aplicar à mão em outras versões |
| [README do scripts_CD-CT](README_scripts_CD-CT.md) | README original do MONAN (instalação, modo regional, malhas) |

## Estrutura (o que é novo)

```
scripts_CD-CT/
├── instalar.sh                     novo: aplica o patch numa instalação existente
├── patches/icon_ifs_scripts_CD-CT-1.6.0.patch
├── docs/                           novo: documentação
└── scripts/
    ├── setenv.bash                 alterado: variáveis ICON_*/IFS_*, NVERTLEV/ZETA_LEVELS e funções auxiliares
    ├── 2.pre_processing.bash       alterado: baixa e converte ICON/IFS
    ├── make_initatmos.bash         alterado: grade vertical opcional, config_nfglevels do ICON
    ├── make_lbcs.bash              alterado: idem
    ├── 3.run_model.bash            alterado: ICON/IFS sem Vtable; L${NVERTLEV} no nome
    ├── 4.run_post.bash             alterado: L${NVERTLEV} no nome
    ├── get_icon_dwd.bash           novo: download do ICON (DWD opendata)
    ├── make_degrib_ICON.bash       novo: ICON → intermediário WPS (chama icon2wps.py)
    ├── icon2wps.py                 novo: conversor do ICON (e funções comuns de escrita do intermediário)
    ├── icon_levels.py              novo: escolhe os níveis do modelo do ICON a partir do config_ztop
    ├── get_ifs_ecmwf.bash          novo: download do IFS (ECMWF open data / AWS)
    ├── make_degrib_IFS.bash        novo: IFS → intermediário WPS (chama ifs2wps.py)
    ├── ifs2wps.py                  novo: conversor do IFS
    ├── mesh_box.py                 novo: caixa lat-lon da malha regional (recorte automático)
    ├── wps_inventory.py            novo: lista campos/níveis de um intermediário (diagnóstico)
    ├── zeta_levels.py              novo: gera arquivos de alturas para config_specified_zeta_levels
    └── namelists/zeta_levels.L75.txt   novo: exemplo de grade L75 (topo 30 km)
```

## Créditos

- Scripts originais: equipe do MONAN / INPE, [`monanadmin/scripts_CD-CT`](https://github.com/monanadmin/scripts_CD-CT)
  (o histórico do repositório original foi mantido neste fork).
- Suporte a ICON e IFS: [@phbazzo](https://github.com/phbazzo).
- Dados: Deutscher Wetterdienst (ICON, DWD Open Data) e ECMWF (IFS, ECMWF Open Data).
