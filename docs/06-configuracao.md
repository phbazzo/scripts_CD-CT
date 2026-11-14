# 06 – Configuração por objetivo

Todas as variáveis novas ficam no início do `scripts/setenv.bash`, no bloco `[ICON/IFS]`, e são definidas como
`${VAR:-padrão}`. Para mudar só numa rodada, passe na frente do comando, sem editar arquivo:

```bash
ICON_VCOORD=pressure ICON_NPROC=4 ./2.pre_processing.bash ICON 655362 2026111300 24
```

Para mudar sempre, edite o padrão no `setenv.bash`. Variáveis exportadas no `~/.bashrc` também valem.

## Referência rápida

| Variável | Padrão | Valores | Afeta |
|---|---|---|---|
| `MODERUN` | `G` (oficial) | `G` global, `R` regional | tudo (LBCs, recorte, horários baixados) |
| `LBCINT` | `10800` | segundos | horários baixados/convertidos e LBCs |
| `ICON_VCOORD` | `model` | `model`, `pressure` | download e conversão do ICON |
| `ICON_ZFULL` | `16000` | m acima do solo | níveis do ICON |
| `ICON_THIN` | `2` | inteiro ≥ 1 | níveis do ICON acima de `ICON_ZFULL` |
| `ICON_ZTOP` | vazio | m (vazio = `config_ztop`) | nível mais alto do ICON |
| `ICON_NPROC` | `8` | inteiro | paralelismo no nó de login (ICON) |
| `IFS_RESOL` | `0p1` | `0p1`, `0p25`, `0p4-beta` | download do IFS |
| `IFS_SOURCE` | `ecmwf` | `ecmwf`, `aws` | download do IFS |
| `IFS_NPROC` | `8` | inteiro | paralelismo do download do IFS |
| `ICON_BOX` / `IFS_BOX` | `auto` | `auto` ou `lon1,lon2,lat1,lat2` | recorte no regional |
| `GRIB_BOX_MARGIN` | `5` | graus | margem do recorte `auto` |
| `ICON_PYTHON` | vazio | caminho de um `python` | Python da conversão |
| `ICON_CDO` | vazio | caminho de um `cdo` | `cdo` do ICON |
| `NVERTLEV` | vazio | inteiro | níveis do MONAN (ver [05](05-niveis-verticais.md)) |
| `ZETA_LEVELS` | vazio | arquivo em `namelists/` | grade vertical do MONAN |

## Receitas

### Domínio regional em qualquer lugar do mundo

Nada a mudar: com `ICON_BOX=auto`, o recorte sai da própria malha (`x1.<RES>.static.nc`). Coloque a malha em
`datain/fixed` como no MONAN oficial (`x1.<RES>.grid.nc`, `x1.<RES>.graph.info`) e use `MODERUN=R`. Malhas que
cruzam o meridiano de 180° são tratadas (longitudes 0–360). Malhas muito grandes (>300° de longitude) ou que chegam
a um polo usam o recorte global.

### Estudar um caso que já passou

- **IFS:** `IFS_SOURCE=aws` (arquivo desde 2023). Antes de fev/2024, use também `IFS_RESOL=0p4-beta`; até
  quando houver `0p25`, ele é mais leve que `0p1`.
- **ICON:** não há arquivo público. Para um caso que você quer estudar, **rode o `2.pre_processing.bash` no dia**
  (ou só `./get_icon_dwd.bash LABELI FCST`). Os dados ficam em `datain/ICON/LABELI`, e o pré-processamento pode ser
  refeito depois, sem internet, enquanto o `download_ok` existir.

### Baixar todo dia (operação/acúmulo de casos)

Um `cron` no nó de login com o download só, por exemplo às 05 UTC para a rodada das 00 UTC:

```bash
0 5 * * * bash -lc 'cd /caminho/scripts_CD-CT/scripts && ./get_icon_dwd.bash $(date -u +\%Y\%m\%d)00 48' >> $HOME/icon_cron.log 2>&1
```

O `bash -lc` carrega o ambiente de login (comando `module`, conda), que o `cron` não tem. Confira se o seu centro
permite `cron` e verifique o espaço em disco (~22 GB por rodada de 48 h nos níveis do modelo).

### Economizar disco ou tempo de download

- `ICON_VCOORD=pressure`: ~4× menos dados, mas a CI fica mais pobre na vertical e para em 30 hPa (ver [03](03-icon.md)).
- `ICON_THIN=3` ou `ICON_ZFULL` menor (ex. `12000`): menos níveis acima da troposfera.
- `IFS_RESOL=0p25`: ~4× menos dados que `0p1`.
- `LBCINT` maior (ex. `21600`): metade dos horários. Com isso, as LBCs ficam menos frequentes, o que pesa em
  domínios pequenos e em eventos rápidos.
- Depois de rodar, apague `datain/ICON/<LABELI>` (os intermediários em `dataout/<LABELI>/Pre` bastam para refazer o init).

### Rodada global

`MODERUN=G` no `setenv.bash`. Só a hora inicial é baixada. Cuidados:

- ICON a 0,125° global: intermediário de vários GB e ~10 GB de RAM na conversão. Rode num nó com memória, ou
  use `ICON_VCOORD=pressure`.
- IFS a 0,1° global: ~3 GB de intermediário; `IFS_RESOL=0p25` reduz para ~0,5 GB.

### Convecção explícita (km)

- ICON em níveis do modelo (padrão) para ter a camada limite e a umidade bem resolvidas na CI.
- `LBCINT=3600` só funciona no ICON (saídas horárias até +78 h). O IFS tem no mínimo 3 h.
- Considere uma grade vertical com mais níveis na camada limite ([05](05-niveis-verticais.md)).
- Descarte as primeiras horas (*spin-up*) na avaliação: hidrometeoros não estão na CI (nem do ICON, nem do IFS,
  nem do GFS do fluxo oficial), e o modelo leva algumas horas para desenvolver a convecção.

### Comparar fontes (GFS × ICON × IFS) para a mesma data

Os scripts oficiais não separam as saídas por `EXP` (ver aviso 2 do README). Faça uma fonte de cada vez:

```bash
L=2026111300; R=655362
for EXP in ICON IFS GFS; do
   ./2.pre_processing.bash ${EXP} ${R} ${L} 48 && \
   ./3.run_model.bash      ${EXP} ${R} ${L} 48 && \
   ./4.run_post.bash       ${EXP} ${R} ${L} 48 && \
   mv ../dataout/${L} ../dataout/${L}.${EXP}
done
```

Os nomes das saídas do modelo e do pós já trazem o `EXP` (`MONAN_DIAG_R_POS_ICON_...`). O que se sobrescreve
são o `Pre/` (`init.nc`, `lbc.*.nc`) e os logs.

### Usar outro Python ou `cdo`

```bash
export ICON_PYTHON=/caminho/para/env/bin/python
export ICON_CDO=/caminho/para/cdo
```

### Mudar o critério terra/mar ou a margem do recorte

- `GRIB_BOX_MARGIN` (graus) no `setenv.bash`.
- O limiar `FR_LAND ≥ 0,5` / `lsm ≥ 0,5` está em `icon2wps.py` (`main`) e `ifs2wps.py` (`main`), procure por `>= 0.5`.

### Mudar as camadas de solo de destino

`SOIL_LAYERS` no início do `icon2wps.py` (em metros). Os nomes dos campos (`SM000010`...) são gerados a partir
delas. O `init_atmosphere` reconhece os nomes do GFS/ERA5. Para outras camadas, confira os nomes aceitos no
código do `init_atmosphere` (`mpas_init_atm_cases.F`) e ajuste `config_nfgsoillevels`.
