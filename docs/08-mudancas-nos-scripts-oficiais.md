# 08 – Mudanças nos scripts oficiais

Base: [`monanadmin/scripts_CD-CT`](https://github.com/monanadmin/scripts_CD-CT), tag **1.6.0** (commit `80aa4e3`).
O diff completo está em [`patches/icon_ifs_scripts_CD-CT-1.6.0.patch`](../patches/icon_ifs_scripts_CD-CT-1.6.0.patch)
e no histórico do git (`git diff 1.6.0 -- scripts/`). Nos scripts, toda mudança está marcada com `[ICON/IFS]`.

Critério: **mexer o mínimo nos arquivos oficiais.** A lógica nova fica em arquivos novos e em funções do
`setenv.bash`. Nenhum namelist oficial foi alterado: os ajustes (`config_nfglevels`, grade vertical) são feitos
sobre o namelist **gerado** de cada rodada, então valem para qualquer versão de namelist (`1.4.3-rc`, `1.4.5`,
`2.0.0-rc`, `develop`).

## Arquivos oficiais alterados

### `scripts/setenv.bash` (+~160 linhas, só acréscimos)

1. Depois de `LBCINT`, um bloco de variáveis, todas no formato `${VAR:-padrão}` para poderem vir da linha de
   comando: `ICON_PYTHON`, `ICON_CDO`, `ICON_VCOORD`, `ICON_ZFULL`, `ICON_THIN`, `ICON_ZTOP`, `ICON_NPROC`,
   `IFS_RESOL`, `IFS_SOURCE`, `IFS_NPROC`, `ICON_BOX`, `IFS_BOX`, `GRIB_BOX_MARGIN`, `NVERTLEV` e `ZETA_LEVELS`.
2. Funções novas, antes de `how_many_nodes`:
   - `find_python`: primeiro Python com `numpy` + `eccodes` (`ICON_PYTHON`, ambientes conda, `python3`);
   - `nml_get ARQ VAR` e `nml_set ARQ GRUPO VAR VALOR`: leem e trocam uma variável num namelist gerado,
     acrescentando-a no grupo se não existir;
   - `set_fg_levels ARQ`: ICON em níveis do modelo → `config_nfglevels = níveis + 1`, se o valor atual for menor;
   - `set_vertical_grid ARQ DIRRUN [lbc]`: aplica `NVERTLEV`/`ZETA_LEVELS`, confere o arquivo de alturas e o topo;
   - `grib_box CAIXA PYTHON MALHA`: `global`, a caixa fixa ou a caixa da malha (`mesh_box.py`).

### `scripts/2.pre_processing.bash`

- Antes do bloco `if [ ! -d ${DATAIN}/fixed ]`: chama `./get_icon_dwd.bash` ou `./get_ifs_ecmwf.bash` quando
  `EXP` é `ICON` ou `IFS`.
- Nas fases *static*, *degrib* e *init*: `ICON` e `IFS` entram nas listas de `EXP` aceitos; o *degrib* chama
  `make_degrib_ICON.bash` / `make_degrib_IFS.bash`.
- Texto de ajuda e cabeçalho.

### `scripts/make_initatmos.bash`

Depois do `sed` que gera `${DIRRUN}/namelist.init_atmosphere`:

```bash
set_vertical_grid ${DIRRUN}/namelist.init_atmosphere ${DIRRUN} || exit 1
set_fg_levels ${DIRRUN}/namelist.init_atmosphere || exit 1
```

### `scripts/make_lbcs.bash`

Depois do `sed` que gera o namelist das LBCs:

```bash
set_vertical_grid ${DIRRUN}/namelist.init_atmosphere ${DIRRUN} lbc || exit 1
set_fg_levels ${DIRRUN}/namelist.init_atmosphere || exit 1
```

### `scripts/3.run_model.bash`

- `NLEV=55` → `NLEV=${NVERTLEV:-55}`, que só entra no nome dos arquivos.
- `files_needed`: retira `Vtable.${EXP}` quando `EXP` é `ICON`/`IFS`, que não passam pelo `ungrib`.
- `cp Vtable.${EXP}`: só para os outros `EXP`.
- `if [[ ${EXP} == "GFS" || ${EXP} == "ERA" ]]`, que gera `namelist.atmosphere`/`streams.atmosphere`, passa
  a aceitar `ICON` e `IFS`.

### `scripts/4.run_post.bash`

- `N_MODEL_LEV=55` → `N_MODEL_LEV=${NVERTLEV:-55}`, que só entra no nome dos arquivos.

### Só texto de ajuda

`0.run_all.bash`, `make_static.bash`, `make_template.bash`, `run_subset.bash`, `make_initatmos.bash`,
`make_lbcs.bash`, `3.run_model.bash`, `4.run_post.bash`: “(GFS or ERA)” → “(GFS, ERA, ICON or IFS)”.

## Arquivos novos (em `scripts/`)

| Arquivo | Função |
|---|---|
| `get_icon_dwd.bash` | download do ICON + pesos do CDO + HHL + escolha de níveis |
| `make_degrib_ICON.bash` | conversão do ICON (chama `icon2wps.py`) |
| `icon2wps.py` | conversor ICON → intermediário WPS; funções comuns usadas pelo `ifs2wps.py` |
| `icon_levels.py` | escolha dos níveis do modelo do ICON |
| `get_ifs_ecmwf.bash` | download do IFS por faixa de bytes |
| `make_degrib_IFS.bash` | conversão do IFS (chama `ifs2wps.py`) |
| `ifs2wps.py` | conversor IFS → intermediário WPS |
| `mesh_box.py` | caixa lat-lon da malha regional |
| `wps_inventory.py` | inventário de um intermediário WPS |
| `zeta_levels.py` | gerador de grade vertical |
| `namelists/zeta_levels.L75.txt` | exemplo de grade L75 |

## Aplicar à mão em outra versão

1. Copie os arquivos novos para `scripts/` e dê `chmod +x`.
2. Cole o bloco de variáveis e as funções no `setenv.bash`.
3. Faça as alterações acima nos scripts oficiais. Procure pelas mesmas âncoras (`make_degrib_ERA5.bash`,
   `namelist.init_atmosphere.TEMPLATE >`, `Vtable.${EXP}`, `NLEV=55`, `N_MODEL_LEV=55`).
4. Se a sua versão não tiver modo regional (`make_lbcs.bash`, `MODERUN`), use só o modo global: os scripts
   novos tratam `MODERUN` vazio como erro. Defina `export MODERUN=G` no `setenv.bash`.
