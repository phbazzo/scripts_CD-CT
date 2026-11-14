# 07 – Avisos e solução de problemas

## Avisos (o que pode acontecer ao aplicar as mudanças)

### Sobre os dados

| # | Aviso | Consequência | O que fazer |
|---|---|---|---|
| D1 | ICON fica online só ~24 h; IFS ~3 dias no portal | o download falha para datas antigas | IFS: `IFS_SOURCE=aws`. ICON: baixe no dia (ver [06](06-configuracao.md)) |
| D2 | A rodada aparece algumas horas depois do horário nominal e é publicada aos poucos | download incompleto (`files missing`) | espere e rode de novo: o download é retomado de onde parou |
| D3 | Horizonte limitado: ICON 180/120 h; IFS 360/144 h (00-12/06-18 UTC) | erro antes do download | reduza `FCST` ou use outra rodada |
| D4 | Passos disponíveis: ICON horário até +78 h e 3 h depois; IFS 3 h até +144 h e 6 h depois | erro de `LBCINT` antes do download | ajuste `LBCINT` |
| D5 | Grandes volumes: ICON ~1,3 GB/horário (níveis do modelo); IFS 0,1° ~0,2 GB/horário | disco cheio no meio do download | estime antes: `(FCST/LBCINT_h + 1) × tamanho`; apague `datain/ICON/<LABELI>` depois |
| D6 | Licença dos dados | publicações precisam citar a fonte | cite DWD (ICON) e ECMWF (IFS) |

### Sobre o fluxo

| # | Aviso | Consequência | O que fazer |
|---|---|---|---|
| F1 | `dataout/<LABELI>/` não é separado por `EXP` (fluxo oficial) | rodar GFS depois de ICON troca o `init.nc`; o modelo do ICON rodaria com CI do GFS | uma fonte por vez; renomeie `dataout/<LABELI>` entre fontes ([06](06-configuracao.md)) |
| F2 | Também `run.<LABELI>/` é compartilhado | duas fontes da mesma data **ao mesmo tempo** se atropelam | nunca em paralelo para o mesmo `LABELI` |
| F3 | Download e conversão rodam no **nó de login** | uso de CPU/RAM pode ser limitado ou o processo pode ser morto | reduza `ICON_NPROC`; no global com ICON, prefira um nó com memória |
| F4 | Os nós de cálculo geralmente não têm internet | submeter o `2.pre_processing.bash` como job falha no download | rode-o no login (ele mesmo submete o init/LBC para a fila) |
| F5 | O recorte `auto` precisa do `x1.<RES>.static.nc` | sem ele, o degrib para | o `2.pre_processing.bash` cria o static antes do degrib (igual ao oficial) |
| F6 | Caixa fixa (`ICON_BOX=...`) menor que a malha | `init_atmosphere` com pontos sem dado/extrapolados na borda | use `auto` ou uma caixa com folga de alguns graus |
| F7 | Mudou `config_ztop`, `ZETA_LEVELS`, `ICON_ZFULL` ou `ICON_THIN` | `model_levels.txt` antigo continua valendo | apague `model_levels.txt` e `download_ok` da rodada |
| F8 | `NVERTLEV`/`ZETA_LEVELS` mudam `init.nc`, LBCs e nomes dos arquivos | init e LBC incompatíveis se não refizer; scripts próprios procurando `L55` | refaça o pré-processamento; ver [05](05-niveis-verticais.md) |
| F9 | Patch feito sobre o `scripts_CD-CT` 1.6.0 | em outras versões pode não aplicar | `--force`, `git apply --3way` ou aplicar à mão ([08](08-mudancas-nos-scripts-oficiais.md)) |
| F10 | `1.install_monan.bash` copia os namelists da versão do modelo para `namelists/` | nenhuma: as mudanças de grade vertical e `nfglevels` são feitas no namelist gerado, não nos templates | — |

### Sobre a física da CI

| # | Aviso | Consequência |
|---|---|---|
| C1 | IFS (*open data*) tem só 14 níveis de pressão; ICON em pressão, 18 (até 30 hPa) | camada limite inicial suavizada; com ICON em pressão, topo extrapolado acima de ~24 km |
| C2 | Solo de outro modelo, reagrupado em 4 camadas | Noah-MP com outra textura de solo: ajuste de umidade e fluxos nas primeiras horas/dias |
| C3 | `LANDSEA` por limiar de 0,5 e orografia (`SOILHGT`) da fonte | diferenças em costa e montanha na interpolação perto da superfície |
| C4 | IFS: gelo marinho binário; neve com densidade padrão se faltar `rsn` | só importa em altas latitudes |
| C5 | Sem hidrometeoros na CI (como no GFS do fluxo oficial) | *spin-up* de nuvens e precipitação nas primeiras horas |
| C6 | `SKINTEMP` é usada como TSM sobre o oceano (como no GFS sem arquivo `SST`) | igual ao fluxo oficial |

**Antes de usar em trabalho científico:** rode o mesmo caso com GFS e compare as primeiras horas (pressão ao
nível do mar, T2m, umidade do solo, precipitação), confira os logs do `init_atmosphere` e, com o
`wps_inventory.py`, se os campos e níveis têm valores plausíveis.

## Checagens rápidas

```bash
L=2026111300; P=../dataout/${L}/Pre
PY=$(bash -c '. setenv.bash > /dev/null 2>&1; find_python')

# 1. Intermediário: campos, níveis e faixas de valores
${PY} wps_inventory.py ${P}/ICON:${L:0:4}-${L:4:2}-${L:6:2}_${L:8:2} --levels
${PY} wps_inventory.py ${P}/ICON:${L:0:4}-${L:4:2}-${L:6:2}_${L:8:2} --field TT | head

# 2. init_atmosphere: níveis encontrados, grade vertical, erros
grep -iE "levels|vertical grid|error|crit" ${P}/logs/log.init_atmosphere.0000.*.out | head -40
grep -E "nvertlevels|nfglevels|zeta|met_prefix" ${P}/logs/namelist.init_atmosphere

# 3. init.nc: dimensões
ncdump -h ${P}/x1.*.init.nc | grep -E "nVertLevels =|nCells ="
```

## Mensagens de erro e o que fazer

| Mensagem | Causa | Solução |
|---|---|---|
| `No Python with numpy + eccodes found` | nenhum ambiente com `eccodes` | `conda create -n monan_grib -c conda-forge python numpy python-eccodes cdo`, ou `ICON_PYTHON=...` |
| `cdo not found` | sem `cdo` no ambiente nem no PATH | `conda install -n monan_grib -c conda-forge cdo`, ou `ICON_CDO=...` |
| `CCE OpenMP fatal error: omp_set_num_threads attempted from non-OpenMP thread` | `cdo` de módulo compilado com OpenMP da Cray | use o `cdo` do conda (padrão quando existe no ambiente do Python) |
| `ICON run ... not found at https://opendata.dwd.de/...` | rodada antiga (>24 h) ou ainda não publicada | outra rodada; espere algumas horas se for a do dia |
| `N files missing ... Run again to resume` | publicação incompleta ou falha de rede | rode de novo |
| `LABELI must be a 00, 06, 12 or 18 UTC run` | horário inválido | — |
| `LBCINT ... must be a multiple of ...` / `output after +78 h` / `+144 h` | `LBCINT` incompatível com os passos da fonte | ajuste `LBCINT` ou `FCST` |
| `IFS run ... not found at ...` | data fora do portal, `0p1` inexistente para a data | `IFS_SOURCE=aws`; `IFS_RESOL=0p25` ou `0p4-beta` |
| `Step +N h not found` | passo ainda não publicado ou além do horizonte | espere / reduza `FCST` |
| `fields missing in the ECMWF files: [...]` | o ECMWF mudou o conteúdo do *open data* | abra uma *issue*; confira o `.index` do arquivo |
| `mesh_box.py: could not read latCell/lonCell` | sem `netCDF4`/`xarray`/`scipy` e sem `ncdump` | `conda install -c conda-forge netcdf4`, ou módulo com `ncdump`, ou `ICON_BOX=lon1,lon2,lat1,lat2` |
| `Recorte ... vazio ou nao contiguo na grade do IFS` | caixa fixa inválida | confira a ordem `lon1,lon2,lat1,lat2` e use `auto` |
| `Arquivos do ICON ausentes` (icon2wps.py) | download incompleto ou `ICON_VCOORD` diferente do usado no download | rode o `get_icon_dwd.bash` de novo com o mesmo `ICON_VCOORD` |
| `... has N lines / N values; expected config_nvertlevels+1` | `NVERTLEV` não bate com o arquivo de alturas | `NVERTLEV` = número de linhas − 1 |
| `Top of ... differs from config_ztop` | última altura ≠ `config_ztop` | gere o arquivo com `--ztop` igual ao namelist |
| `Please increase config_nfglevels to at least N` (log do init) | mais níveis no intermediário que no namelist | não deveria ocorrer com ICON (ajuste automático); para outra fonte, aumente `config_nfglevels` no template |
| `At least the file .../Vtable.ICON was not generated` | `3.run_model.bash` sem o patch | aplique o patch (`instalar.sh`) |
| `ECCODES ERROR : pack_bytes: Wrong size (20) for section2Padding` | seção local dos GRIB do DWD ao regravar | **inofensiva** (já filtrada no `icon2wps.py`) |
| `bunzip2: ... trailing garbage after EOF ignored` | arquivos do DWD com bytes extras no fim | **inofensiva** |
