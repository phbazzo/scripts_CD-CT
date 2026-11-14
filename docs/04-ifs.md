# 04 – IFS (ECMWF) como CI/CC

## Os dados

- **Fonte:** ECMWF Open Data (IFS HRES, previsão determinística), em GRIB2 numa grade lat-lon regular.
  - `IFS_SOURCE=ecmwf` (padrão): `https://data.ecmwf.int/forecasts/`. Guarda só os **~3 últimos dias**.
  - `IFS_SOURCE=aws`: `https://ecmwf-forecasts.s3.eu-central-1.amazonaws.com`, o **arquivo** do *open data*
    (desde 2023).
- **Resolução (`IFS_RESOL`):** `0p1` (0,1°, padrão; datas recentes), `0p25` (0,25°) ou `0p4-beta` (0,4°, datas
  antes de fev/2024). No `0p1`, os campos de pressão e de superfície vêm em arquivos separados (`-pl`, `-sfc`).
- **Rodadas e horizonte:** 00 e 12 UTC até +360 h; 06 e 18 UTC até +144 h. Saídas de 3 em 3 h até +144 h e de
  6 em 6 h depois disso. Em datas antigas, as rodadas 06/18 UTC vinham no *stream* `scda` e iam só até +90 h. O
  script testa `oper` e `scda` e usa o que existir.

## Download (`get_ifs_ecmwf.bash`)

Cada arquivo do ECMWF tem um `.index` (uma linha JSON por campo, com `param`, `levtype`, `levelist`, `_offset`,
`_length`). O script lê o índice e baixa **só os bytes dos campos necessários**, com pedidos HTTP `Range`. Campos
vizinhos no arquivo viram um único pedido, de até 64 MB.

| Arquivo em `datain/IFS/<LABELI>/` | Campos | Horários |
|---|---|---|
| `ifs_pl.FFF.grib2` | `t`, `u`, `v`, `r`, `gh` em 1000, 925, 850, 700, 600, 500, 400, 300, 250, 200, 150, 100, 50 e 10 hPa | todos |
| `ifs_sfc.FFF.grib2` | `sp`, `msl`, `2t`, `2d`, `10u`, `10v`, `skt` | todos |
| `ifs_sfc0.grib2` | `z` (geopotencial da superfície), `lsm`, `sd`, `rsn`, `sithick` | +0 h |
| `ifs_sol.grib2` | `sot`, `vsw` nas 4 camadas de solo | +0 h |

**Tamanho:** a 0,1°, ~0,2 GB por horário. Arquivos já existentes não são baixados de novo; se todos já estão
em disco, o script nem acessa a rede. Para forçar um novo download, apague os `ifs_*.grib2` da rodada.

O download usa só a biblioteca padrão do Python (`urllib`), então qualquer `python3` serve. A conversão é que
precisa de `numpy` + `eccodes`.

## Conversão (`make_degrib_IFS.bash` → `ifs2wps.py`)

Os dados já estão em lat-lon, então **não há remapeamento** nem `cdo`: o script só recorta (`IFS_BOX`) e põe as
linhas de sul para norte. As conversões e a escrita do intermediário são as do `icon2wps.py`, importado como
módulo:

- 14 níveis de pressão → `TT`, `UU`, `VV`, `RH`, `SPECHUMD` (de `r` e `t`), `GHT` (`gh`);
- superfície → `PSFC`, `PMSL`, `TT`/`RH`/`SPECHUMD` a 2 m (de `2t`, `2d`), `UU`/`VV` a 10 m, `SKINTEMP` (`skt`);
- `SOILHGT = z/g`; `LANDSEA = lsm ≥ 0,5`;
- solo: as camadas do IFS (0–7, 7–28, 28–100, 100–289 cm) são reagrupadas nas do GFS. A umidade `vsw` vira
  kg m⁻² por camada antes do reagrupamento, para usar exatamente o mesmo código do ICON;
- neve: `SNOW = sd·1000` (kg m⁻²), `SNOWH = sd·1000/rsn` (m; densidade 300 kg m⁻³ se faltar `rsn`);
- gelo marinho: `SEAICE = 1` onde `sithick > 0`, já que a fração de gelo (`ci`) não está no *open data*.

Saída: `dataout/<LABELI>/Pre/IFS:YYYY-MM-DD_HH`. Log: `dataout/<LABELI>/Pre/logs/ifs2wps.*.log`.

## Limitações a ter em mente

- **Só 14 níveis de pressão.** Abaixo de 700 hPa existem apenas 1000, 925 e 850 hPa. A estrutura da camada
  limite (inversões, jatos de baixos níveis) fica suavizada na CI e nas LBCs. O `init_atmosphere` extrapola
  abaixo de 1000 hPa onde a superfície está acima disso.
- **Topo em 10 hPa (~31 km).** Cobre o topo padrão do MONAN (30 km) com pouca folga. Com `config_ztop` acima de
  ~31 km, as camadas de cima saem de extrapolação.
- **Gelo marinho binário** e densidade da neve só na hora inicial.
- O `open data` não traz os níveis do modelo do IFS (137 níveis), que só existem nos produtos pagos/MARS. Com
  acesso a eles, o caminho seria um conversor nos moldes do ICON em níveis do modelo.

## Variáveis

| Variável | Padrão | Uso |
|---|---|---|
| `IFS_RESOL` | `0p1` | `0p1`, `0p25` ou `0p4-beta` |
| `IFS_SOURCE` | `ecmwf` | `ecmwf` (últimos ~3 dias) ou `aws` (arquivo desde 2023) |
| `IFS_NPROC` | `8` | arquivos baixados em paralelo |
| `IFS_BOX` | `= ICON_BOX` (`auto`) | recorte, como no ICON |
| `ICON_PYTHON` | vazio (procura) | o mesmo Python do ICON |

Exemplo, caso de 3 dias atrás a 0,25°:

```bash
IFS_SOURCE=aws IFS_RESOL=0p25 ./2.pre_processing.bash IFS <RES_MESH> 2026111000 48
```
