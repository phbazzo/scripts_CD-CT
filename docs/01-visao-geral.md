# 01 – Visão geral: como o ICON e o IFS entram no MONAN

## A cadeia original (GFS/ERA5)

```
GRIB2 do GFS ──ungrib.exe + Vtable.GFS──▶ GFS:YYYY-MM-DD_HH ──init_atmosphere──▶ x1.RES.init.nc ──▶ atmosphere_model
                                          (intermediário WPS)  (config_init_case=7)  lbc.*.nc (case 9, regional)
```

O `init_atmosphere` do MONAN (herdado do MPAS) não lê GRIB. Ele lê **arquivos intermediários do WPS**:
um arquivo binário por horário, com uma sequência de campos 2D. Cada campo tem um nome padrão (`TT`, `UU`, `VV`,
`RH`, `SPECHUMD`, `GHT`, `PSFC`, `SKINTEMP`, `SOILHGT`, `LANDSEA`, `SM000010`...), um nível (`xlvl`) e uma grade
lat-lon. Quem produz esses arquivos no fluxo oficial é o `ungrib.exe` do WPS, guiado por uma `Vtable`.

## O que muda com ICON e IFS

```
                 get_icon_dwd.bash                    make_degrib_ICON.bash → icon2wps.py
DWD opendata ──────────────────────▶ datain/ICON/LABELI ───────────────────────────────────▶ dataout/LABELI/Pre/ICON:...
(ICON icosaédrico, GRIB2.bz2)         *.grib2.bz2         bunzip2 → cdo remap 0,125° → recorte
                                      model_levels.txt    → nomes/unidades do WPS → intermediário

                 get_ifs_ecmwf.bash                   make_degrib_IFS.bash → ifs2wps.py
ECMWF open data ───────────────────▶ datain/IFS/LABELI ────────────────────────────────────▶ dataout/LABELI/Pre/IFS:...
(lat-lon 0,1°/0,25°, GRIB2)           ifs_*.grib2         recorte → nomes/unidades do WPS → intermediário

                                     daqui em diante, igual ao GFS:
dataout/LABELI/Pre/<EXP>:... ──make_initatmos.bash──▶ x1.RES.init.nc ──make_lbcs.bash──▶ lbc.*.nc ──▶ 3.run_model ──▶ 4.run_post
```

O ICON e o IFS **não passam pelo `ungrib`**. Os conversores em Python escrevem direto o intermediário do WPS,
com os mesmos nomes de campo que o `ungrib` produziria. As razões:

- **ICON:** a grade original é icosaédrica (não lat-lon), que o `ungrib` não lê. É preciso remapear antes. Além
  disso, os níveis nativos do modelo (coordenada de altura, com o `HHL`) não cabem numa `Vtable` comum.
- **IFS:** o *open data* vem em GRIB2 lat-lon e poderia passar pelo `ungrib` com uma `Vtable.ECMWF`. Mas faltam
  campos derivados (umidade específica, solo nas camadas do GFS, neve em kg m⁻²) e a conversão em Python reusa
  todo o código do ICON. Também elimina a dependência do `ungrib.exe` e da `Vtable`.

A partir do intermediário, **a cadeia é exatamente a do MONAN oficial**: mesmos `namelist.init_atmosphere.*`,
mesmo `config_init_case`, mesmo modelo. O prefixo dos arquivos é o próprio `EXP` (`config_met_prefix = '#EXP#'`
no namelist oficial).

## Componentes

| Componente | Roda onde | O que faz |
|---|---|---|
| `setenv.bash` (bloco `[ICON/IFS]`) | carregado por todos | Variáveis `ICON_*`, `IFS_*`, `NVERTLEV`, `ZETA_LEVELS` e funções: `find_python` (acha Python com numpy+eccodes), `nml_get`/`nml_set` (lê/troca variáveis em namelists gerados), `set_vertical_grid` (grade vertical opcional), `set_fg_levels` (ajusta `config_nfglevels`), `grib_box` (recorte) |
| `2.pre_processing.bash` | login | Para `EXP=ICON\|IFS`, chama o download **antes de tudo**: se a rodada não existir mais, para logo. Depois segue a ordem oficial: static → degrib → init → LBC |
| `get_icon_dwd.bash` | login (internet) | Confere horário/idade/`LBCINT`, baixa pesos do CDO e `HHL` (uma vez), escolhe os níveis (`icon_levels.py`), monta a lista de URLs e baixa em paralelo (`wget -c`, retomável). Grava `download_ok` |
| `icon_levels.py` | login | Lê o `HHL` (alturas das meias-camadas do ICON) e escolhe os níveis: todos até `ICON_ZFULL`, depois 1 a cada `ICON_THIN`, e **exatamente um** acima do topo do MONAN |
| `make_degrib_ICON.bash` | login | Acha Python/`cdo`, define o recorte, chama `icon2wps.py` e move os intermediários para `dataout/LABELI/Pre` |
| `icon2wps.py` | login | bunzip2 → `cdo remap` (pesos do DWD, para 0,125°) + recorte → conversões (umidade, solo, alturas) → intermediário WPS. Também contém as funções de escrita usadas pelo IFS |
| `get_ifs_ecmwf.bash` | login (internet) | Lê o `.index` de cada arquivo do ECMWF e baixa **só os campos necessários** (HTTP com faixa de bytes). Descobre o *stream* (`oper`/`scda`) sozinho |
| `make_degrib_IFS.bash` + `ifs2wps.py` | login | Recorte (sem remapear: já é lat-lon) → mesmas conversões → intermediário WPS |
| `mesh_box.py` | login | Caixa lat-lon da malha regional + margem (recorte `auto`) |
| `make_initatmos.bash`, `make_lbcs.bash` | fila | Iguais aos oficiais, mais duas chamadas sobre o namelist gerado: `set_vertical_grid` e `set_fg_levels` |
| `3.run_model.bash`, `4.run_post.bash` | fila | ICON/IFS não exigem `Vtable.<EXP>`; número de níveis no nome dos arquivos segue `NVERTLEV` |
| `wps_inventory.py` | qualquer | Lista campos, níveis e faixas de valores de um intermediário (diagnóstico) |
| `zeta_levels.py` | qualquer | Gera um arquivo de alturas para `config_specified_zeta_levels` |

## Campos escritos no intermediário

| Campo WPS | ICON (níveis do modelo) | ICON (pressão) | IFS |
|---|---|---|---|
| `TT`, `UU`, `VV` (3D) | `T`, `U`, `V` | `T`, `U`, `V` | `t`, `u`, `v` |
| `SPECHUMD` (3D) | `QV` | calculada de `RELHUM` | calculada de `r` |
| `RH` (3D) | calculada de `QV`, `P`, `T` | `RELHUM` | `r` |
| `GHT` (3D) | média das meias-camadas `HHL` | `FI / g` | `gh` |
| `PRESSURE` (3D) | `P` (o init usa este campo, e não o `xlvl`) | — | — |
| `PSFC`, `PMSL` | `PS`, `PMSL` | idem | `sp`, `msl` |
| `TT`, `RH`, `SPECHUMD` a 2 m | `T_2M`, `TD_2M` | idem | `2t`, `2d` |
| `UU`, `VV` a 10 m | `U_10M`, `V_10M` | idem | `10u`, `10v` |
| `SKINTEMP` | `T_G` | idem | `skt` |
| `SOILHGT` | `HSURF` | idem | `z / g` |
| `LANDSEA` | `FR_LAND ≥ 0,5` | idem | `lsm ≥ 0,5` |
| `SEAICE`, `SNOW`, `SNOWH` (só CI) | `FR_ICE`, `W_SNOW`, `H_SNOW` | idem | `sithick > 0`, `sd·1000`, `sd·1000/rsn` |
| `SM000010`...`SM100200`, `ST...` (só CI) | `W_SO`, `T_SO` reagrupados | idem | `vsw`, `sot` reagrupados |

`xlvl` (nível de cada registro): pressão em Pa nos níveis isobáricos; número do nível do ICON (1 = topo) nos
níveis do modelo, como nos dados de níveis do modelo do ECMWF; 200100 = superfície.
