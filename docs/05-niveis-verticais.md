# 05 – Níveis verticais do MONAN (opcional)

> Esta parte é **independente** do ICON/IFS: vale para qualquer `EXP`, inclusive GFS. Com `NVERTLEV` e
> `ZETA_LEVELS` vazios (padrão), nada muda em relação ao MONAN oficial.

## O padrão do MONAN

Nos namelists oficiais (`namelists/<versão>/namelist.init_atmosphere.TEMPLATE` e `.LBCS`):

```
config_nvertlevels = 55
config_ztop = 30000.0
config_tc_vertical_grid = true      ! distribuição "TC" do MPAS (2014), gerada a partir de nz e ztop
```

O `3.run_model.bash` e o `4.run_post.bash` oficiais usam `55` fixo **só no nome dos arquivos** (`...x<RES>L55.nc`).
O modelo lê o número de níveis do `init.nc`.

## As duas variáveis novas (`setenv.bash`)

| Variável | Vazia (padrão) | Com valor |
|---|---|---|
| `NVERTLEV` | usa `config_nvertlevels` do namelist (55) | troca `config_nvertlevels` no namelist **gerado** do init e das LBCs; nomes dos arquivos com `L${NVERTLEV}` |
| `ZETA_LEVELS` | grade TC do MPAS | nome de um arquivo em `scripts/namelists/` com as alturas das interfaces; o namelist gerado ganha `config_specified_zeta_levels = '<arquivo>'` |

As mudanças são feitas pela função `set_vertical_grid` (no `setenv.bash`) **sobre o namelist já gerado** em
`run.<LABELI>/`. Os templates oficiais, em todas as versões, ficam intactos. Antes de rodar o `init_atmosphere`,
`set_vertical_grid` confere:

- se o arquivo existe;
- se tem exatamente `config_nvertlevels + 1` valores numéricos, um por linha, sem comentários. O
  `init_atmosphere` conta as linhas e aborta se o número não bater;
- se o último valor é igual a `config_ztop`. O `init_atmosphere` usa a última altura do arquivo como topo e
  **ignora** `config_ztop`, mas a escolha dos níveis do ICON usa `config_ztop`. Se os dois forem diferentes, o
  ICON poderia não ter um nível acima do topo.

Nas LBCs (`make_lbcs.bash`), só o número de níveis é trocado: a grade vertical das LBCs vem do `init.nc`.

## Gerar uma grade (`zeta_levels.py`)

```bash
python zeta_levels.py --nlev 75 --ztop 30000 --dzbot 20 --r1 1.10 --dzmid 480 --ztrans 12000 \
       > namelists/zeta_levels.L75.txt      # a tabela e o resumo saem no terminal (stderr)
```

A distribuição tem três trechos:

1. **camada limite:** a primeira camada tem `--dzbot` m e cada camada seguinte é `--r1` vezes a anterior, até
   chegar a `--dzmid`;
2. **troposfera:** espessura constante `--dzmid` até `--ztrans`;
3. **acima:** a espessura cresce geometricamente, com a razão calculada para fechar exatamente `--nlev` camadas
   em `--ztop`.

O exemplo `namelists/zeta_levels.L75.txt` (75 camadas, topo 30 km) foi pensado para 3 km com convecção
explícita. O primeiro nível de massa fica a 10 m, há 25 camadas abaixo de 2 km (a grade TC com 75 níveis tem 19),
a espessura nunca fica menor que ~215 m acima de 2 km e há 10 níveis acima de `config_zd = 22 km`, na camada de
amortecimento.

Para usar:

```bash
# no setenv.bash (ou na linha de comando)
export NVERTLEV=75
export ZETA_LEVELS=zeta_levels.L75.txt
./2.pre_processing.bash ICON <RES_MESH> <LABELI> <FCST>     # refaz init e LBCs
```

No log do init (`dataout/<LABELI>/Pre/logs/log.init_atmosphere.0000.*.out`) deve aparecer
`Setting up vertical grid using levels from 'zeta_levels.L75.txt'`.

## ⚠️ Antes de mudar a grade vertical

1. **Refaça o pré-processamento.** `init.nc` e `lbc.*.nc` dependem do número de níveis; um `init.nc` L55 com LBCs
   L75 não roda. O `static.nc` não depende da vertical.
2. **Passo de tempo.** Camadas mais finas aumentam o número de Courant vertical. Confira o `config_dt` da sua
   malha (tabela `if/elif` no `3.run_model.bash`) e o log do modelo nas primeiras horas (`w` máximo, avisos de
   CFL). A grade L75 do exemplo não fica com camadas mais finas que a TC acima de 2 km.
3. **Camada de amortecimento.** `config_zd` (22 km) e `config_xnutr` (0,2) no `namelist.atmosphere.TEMPLATE`
   valem para qualquer grade. Mantenha vários níveis entre `config_zd` e o topo. O `zeta_levels.py` imprime
   quantos ficam.
4. **Custo.** O custo por coluna cresce com o número de níveis: 75 níveis custam ~36 % mais que 55. Ajuste o
   *walltime* do modelo (`MODEL_walltime` nos `stools/setenv_*.bash`).
5. **Nomes dos arquivos.** Saídas passam a ser `...L75.nc`. Scripts próprios de avaliação que procuram `L55`
   precisam acompanhar.
6. **Topo diferente.** Se mudar o `config_ztop` no template, gere o arquivo de alturas com o mesmo `--ztop` e, no
   ICON, apague `model_levels.txt` e `download_ok` da rodada para escolher os níveis de entrada de novo.
7. **Grade vertical × dados de entrada.** Mais níveis no MONAN não criam informação que a CI não tem. Com o IFS (14
   níveis de pressão) ou o ICON em pressão (18), a camada limite inicial continua grosseira, embora o modelo a
   desenvolva nas primeiras horas. Com o ICON em níveis do modelo, a CI já traz dezenas de níveis abaixo de 2 km.

## Relação com os níveis do ICON

O `icon_levels.py` escolhe os níveis de **entrada** (do ICON) e o `ZETA_LEVELS` define os níveis do **MONAN**.
São coisas diferentes, ligadas só pelo topo: o ICON precisa ter um nível acima de `config_ztop`. Com
`ICON_ZFULL=16000`, todos os níveis nativos do ICON até 16 km entram, mais densos que qualquer grade razoável
do MONAN nessa faixa, então a interpolação vertical do `init_atmosphere` não perde resolução.
