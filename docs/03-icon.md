# 03 – ICON (DWD) como CI/CC

## Os dados

- **Fonte:** DWD Open Data, `https://opendata.dwd.de/weather/nwp/icon/grib/<HH>/<variavel>/`.
- **Modelo:** ICON global, grade icosaédrica R03B07 (~13 km), 120 níveis na vertical (coordenada de altura
  híbrida, topo a ~75 km). Um arquivo GRIB2 comprimido com bzip2 por variável, nível e horário.
- **Rodadas:** 00, 06, 12 e 18 UTC. Horizonte de +180 h (00/12 UTC) ou +120 h (06/18 UTC). Saídas de hora
  em hora até +78 h e de 3 em 3 h depois disso.
- **Disponibilidade:** só as **últimas ~24 h**. Cada rodada aparece algumas horas depois do horário nominal. Não há
  arquivo histórico público gratuito.

## Download (`get_icon_dwd.bash`)

Baixa para `datain/ICON/<LABELI>/`:

| Grupo | Variáveis | Horários |
|---|---|---|
| Invariantes | `HSURF` (orografia), `FR_LAND` | uma vez |
| Atmosfera (níveis do modelo) | `T`, `U`, `V`, `QV`, `P` nos níveis de `model_levels.txt` | todos |
| Atmosfera (pressão, `ICON_VCOORD=pressure`) | `T`, `U`, `V`, `RELHUM`, `FI` nos 18 níveis | todos |
| Superfície | `PS`, `PMSL`, `T_2M`, `TD_2M`, `U_10M`, `V_10M`, `T_G` | todos |
| Neve, gelo | `FR_ICE`, `W_SNOW`, `H_SNOW` | só +0 h |
| Solo | `T_SO`, `W_SO` (todas as camadas) | só +0 h |

Os horários são `0, LBCINT, 2·LBCINT, ..., FCST` no modo regional e só `0` no global.

Uma vez por instalação, em `datain/fixed/`:

- `icon_cdo/`: grade de destino e pesos do DWD para o `cdo` (`ICON_GLOBAL2WORLD_0125_EASY`);
- `icon_hhl/`: `HHL`, as alturas (m acima do nível do mar) das 121 meias-camadas do ICON. Não mudam entre
  rodadas e servem para escolher os níveis e calcular o `GHT`.

O download é **retomável** (`wget -c`): se cair, rode de novo. Ao terminar, grava `download_ok` com
`FCST DT VCOORD`. Com o marcador presente e cobrindo o pedido, o script nem consulta o DWD. Assim dá para refazer a
conversão/init depois que a rodada saiu do *opendata*.

**Tamanho:** ~3,2 MB por arquivo. Com ~75 níveis × 5 variáveis, isso dá **~1,3 GB por horário** nos níveis do
modelo, ou ~22 GB para 48 h com LBC de 3 em 3 h. Em pressão, é cerca de 1/4 disso.

## Níveis do modelo × níveis de pressão (`ICON_VCOORD`)

| | `model` (padrão) | `pressure` |
|---|---|---|
| Níveis | ~75 (escolhidos, ver abaixo) | 18: 1000, 950, 925, 900, 850, 800, 700, 600, 500, 400, 300, 250, 200, 150, 100, 70, 50, 30 hPa |
| Topo dos dados | um nível acima de `config_ztop` | **30 hPa ≈ 24 km, abaixo do topo padrão do MONAN (30 km)** |
| Camada limite | todos os níveis nativos (dezenas abaixo de 2 km) | poucos níveis |
| Abaixo do relevo | não existe (níveis seguem o terreno) | pontos sem dado: extrapolados (`fill_underground`) |
| Coordenada para o init | campo 3D `PRESSURE` + `GHT` | `xlvl` = pressão |
| `config_nfglevels` | ajustado sozinho (níveis + 1) | cabe nos 35 do namelist |
| Disco | ~4× maior | menor |

Use `model` sempre que possível: preserva a estrutura vertical do ICON e evita extrapolar abaixo do relevo e
**acima de 24 km**. Com `pressure`, as camadas do MONAN entre ~24 km e o topo ficam sem dado de entrada e saem
de extrapolação do `init_atmosphere`. É aceitável para testes rápidos ou para economizar disco, mas não para estudo.

### Como os níveis são escolhidos (`icon_levels.py`)

O ICON tem 120 níveis até ~75 km, e o MONAN tem topo em `config_ztop` (30 km no padrão). Baixar todos seria
desperdício. Por outro lado, o `init_atmosphere` precisa de **pelo menos um nível de entrada acima do topo** para
interpolar, e não extrapolar, as camadas mais altas. O `icon_levels.py` lê o `HHL` e escolhe:

1. **todos** os níveis cuja altura média acima do solo é ≤ `ICON_ZFULL` (padrão 16 000 m, a tropopausa tropical);
2. acima disso, **um a cada `ICON_THIN`** (padrão 2);
3. **exatamente um** nível acima do topo do MONAN: o mais baixo cuja altura **mínima** acima do nível do mar,
   em todo o globo, passa de `ICON_ZTOP` (padrão: `config_ztop` do `namelist.init_atmosphere.TEMPLATE`).

O topo é comparado com a altura acima do nível do mar porque o `config_ztop` do MPAS/MONAN também é medido assim.
A lista vai para `datain/ICON/<LABELI>/model_levels.txt`, e a tabela de alturas sai no terminal. Com os padrões
e topo de 30 km, ficam ~75 níveis, do 37 (≈30,1 km) ao 120.

> ⚠️ **Mudou `config_ztop`, `ZETA_LEVELS`, `ICON_ZFULL` ou `ICON_THIN`?** Apague `model_levels.txt` **e**
> `download_ok` da rodada para que os níveis sejam escolhidos e baixados de novo.

## Conversão (`make_degrib_ICON.bash` → `icon2wps.py`)

Para cada arquivo, em paralelo (`ICON_NPROC`):

1. `bunzip2`;
2. `cdo -f grb2 -b F32 sellonlatbox,<caixa> -remap,target_grid.txt,weights.nc`: remapeamento da malha
   icosaédrica para lat-lon 0,125° com os pesos oficiais do DWD, seguido do recorte;
3. leitura com `eccodes` e verificação de que todos os campos têm a mesma grade.

Depois, por horário:

- **Níveis do modelo:** `SPECHUMD = max(QV, 0)`. `RH` é calculada de `QV`, `P` e `T` (Bolton, 1980). `GHT` é a média
  das meias-camadas `HHL` acima e abaixo de cada nível. O campo `PRESSURE` vai junto: o `init_atmosphere` usa a
  pressão 3D para interpolar, como faz com os níveis do modelo do ECMWF.
- **Pressão:** `SPECHUMD` é calculada de `RELHUM` e `T`; `GHT = FI/g`; pontos abaixo do relevo são preenchidos a
  partir do nível de cima (T com lapse rate de 6,5 K/km, GHT hidrostático, U/V/RH copiados).
- **Superfície:** `RH` e `SPECHUMD` a 2 m vêm de `TD_2M`; `LANDSEA = FR_LAND ≥ 0,5`; `SOILHGT = HSURF`.
- **Solo (só +0 h):** `W_SO` (kg m⁻² por camada) é convertido para m³ m⁻³ e combinado nas camadas do GFS
  (0–10, 10–40, 40–100 e 100–200 cm), com média ponderada pela sobreposição. `T_SO` é interpolada linearmente para
  o meio de cada camada. As profundidades vêm das chaves GRIB de cada arquivo, e não dos nomes, porque os rótulos do
  DWD misturam mm e cm.
- **Neve e gelo (só +0 h):** `SEAICE = FR_ICE`, `SNOW = W_SNOW`, `SNOWH = H_SNOW`.

Saída: `dataout/<LABELI>/Pre/ICON:YYYY-MM-DD_HH`. Log: `dataout/<LABELI>/Pre/logs/icon2wps.*.log`.

## Recorte (`ICON_BOX`)

| Valor | Efeito |
|---|---|
| `auto` (padrão) | regional: caixa da malha (`mesh_box.py` sobre `x1.RES.static.nc`) + `GRIB_BOX_MARGIN` (5°) |
| `lon1,lon2,lat1,lat2` | caixa fixa, ex. `-95,-25,-60,15`. **Precisa cobrir a malha toda com folga** |
| — | no modo global o recorte é sempre `global` |

A margem existe porque o `init_atmosphere` interpola de pontos lat-lon vizinhos e, no regional, a zona de
relaxação das LBCs fica na borda da malha.

## Variáveis

| Variável | Padrão | Uso |
|---|---|---|
| `ICON_VCOORD` | `model` | `model` ou `pressure` |
| `ICON_ZFULL` | `16000` | altura (m AGL) até onde usa todos os níveis nativos |
| `ICON_THIN` | `2` | acima de `ICON_ZFULL`, usa 1 nível a cada N |
| `ICON_ZTOP` | vazio (= `config_ztop`) | topo usado na escolha dos níveis |
| `ICON_BOX` | `auto` | recorte (ver acima) |
| `ICON_NPROC` | `8` | downloads e processos do `cdo` em paralelo |
| `ICON_PYTHON` | vazio (procura) | Python com `numpy` + `eccodes` |
| `ICON_CDO` | vazio (do ambiente) | executável do `cdo` |

Todas ficam no `setenv.bash` e podem ser trocadas na linha de comando, por exemplo
`ICON_VCOORD=pressure ICON_NPROC=4 ./2.pre_processing.bash ICON ...`.
