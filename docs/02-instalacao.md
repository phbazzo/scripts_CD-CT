# 02 – Instalação

## Pré-requisitos

| Item | Para quê | Observação |
|---|---|---|
| MONAN instalado pelo `scripts_CD-CT` (1.6.0) | modelo, `init_atmosphere`, `convert_mpas`, `datain/fixed`, `WPS_GEOG` | igual ao fluxo oficial (`1.install_monan.bash`) |
| `wget`, `bunzip2`, `tar` | download e descompressão | normalmente já existem |
| Python 3 com `numpy` e `eccodes` | leitura dos GRIB2 e conversão | o `python3` do sistema costuma **não** ter `eccodes` |
| `cdo` | remapeamento do ICON | só para `EXP=ICON`. Prefira o do conda (ver abaixo) |
| internet no nó onde roda o `2.pre_processing.bash` | download | os nós de cálculo geralmente não têm internet |
| `ncdump` (opcional) | recorte `auto` se o Python não tiver `netCDF4`/`xarray`/`scipy` | o `3.run_model.bash` oficial já usa `ncdump` |

### Ambiente Python + cdo

```bash
conda create -n monan_grib -c conda-forge python numpy python-eccodes cdo
# opcional, deixa o recorte automático mais rápido em malhas grandes:
conda install -n monan_grib -c conda-forge netcdf4
```

Os scripts procuram, nesta ordem: `ICON_PYTHON` (se definido) → `~/.conda/envs/*`, `~/miniconda3/envs/*`,
`~/miniforge3/envs/*`, `~/anaconda3/envs/*` → as bases do miniconda/miniforge/anaconda → `python3` do PATH.
Usam o primeiro que importar `numpy` e `eccodes`. O `cdo` usado é o do mesmo ambiente; se não houver, o do PATH;
para fixar um, use `ICON_CDO`.

> **Por que não usar o `cdo` do sistema de módulos?** Em alguns supercomputadores Cray, o `cdo` de módulo foi
> compilado com o OpenMP do compilador da Cray e falha com
> `CCE OpenMP fatal error: omp_set_num_threads attempted from non-OpenMP thread` quando chamado pelo Python.
> Com o caminho completo do `cdo` do conda, o `icon2wps.py` o executa sem o `LD_LIBRARY_PATH` do modelo e
> evita o conflito.

Para conferir:

```bash
cd scripts_CD-CT/scripts
bash -c '. setenv.bash > /dev/null; find_python'      # deve imprimir o caminho do Python
```

## Opção A — usar o fork

```bash
cd /sua/area/de/trabalho                  # Lustre/scratch: o MONAN gera muitos dados
git clone https://github.com/phbazzo/scripts_CD-CT.git
cd scripts_CD-CT/scripts
./1.install_monan.bash https://github.com/monanadmin/MONAN-Model.git 2.0.0-rc 1.2.0
```

> **A pasta precisa se chamar `scripts_CD-CT`.** Os scripts calculam a raiz a partir da pasta atual
> (`DIR_SCRIPTS=$(dirname $(dirname $(pwd)))`) e usam `${DIR_SCRIPTS}/scripts_CD-CT/...`. Rode-os sempre de dentro
> de `scripts_CD-CT/scripts`.

Para receber atualizações do MONAN oficial no futuro:

```bash
git remote add upstream https://github.com/monanadmin/scripts_CD-CT.git
git fetch upstream
git merge upstream/main          # resolva conflitos nos trechos marcados [ICON/IFS], se houver
```

## Opção B — aplicar numa instalação existente

```bash
git clone https://github.com/phbazzo/scripts_CD-CT.git scripts_CD-CT_icon_ifs
./scripts_CD-CT_icon_ifs/instalar.sh /caminho/para/scripts_CD-CT
```

O `instalar.sh`:

1. lê `VERSION.txt` (precisa ser `1.6.0`; com `--force` tenta mesmo assim);
2. testa o patch (`git apply --check`, ou `patch --dry-run` se a pasta não for um clone git). Se houver conflito,
   **não muda nada** e explica as opções;
3. copia os arquivos que serão alterados para `scripts.antes_icon_ifs.<data>/`;
4. aplica `patches/icon_ifs_scripts_CD-CT-1.6.0.patch` e dá permissão de execução aos scripts novos;
5. procura o Python com `numpy` + `eccodes` e o `cdo`, e só avisa se faltar.

Rodar duas vezes é seguro: se o patch já estiver aplicado, ele avisa e sai.

Para **desfazer**: `git apply -R patches/icon_ifs_scripts_CD-CT-1.6.0.patch` dentro do `scripts_CD-CT`, ou copie
de volta os arquivos de `scripts.antes_icon_ifs.<data>/` e apague os scripts novos.

### Instalação com versões diferentes da 1.6.0 ou scripts modificados

O patch altera poucas linhas e todas ficam em blocos fáceis de achar. Se ele não aplicar:

- `git apply --3way patches/icon_ifs_scripts_CD-CT-1.6.0.patch` tenta mesclar e marca os conflitos;
- ou aplique à mão seguindo [08 – Mudanças nos scripts oficiais](08-mudancas-nos-scripts-oficiais.md). Os
  arquivos novos (`get_*`, `make_degrib_ICON/IFS.bash`, `*.py`) podem ser copiados sem mudança.

A opção `config_specified_zeta_levels` (grade vertical própria) existe no `init_atmosphere` do MONAN
1.4.3-rc, 1.4.5 e 2.0.0-rc. O ICON/IFS em si não depende da versão do modelo.

## Primeiro teste recomendado

Use uma malha pequena e uma previsão curta, com a rodada de hoje:

```bash
cd scripts_CD-CT/scripts
LABELI=$(date -u +%Y%m%d)00
./2.pre_processing.bash IFS <RES_MESH> ${LABELI} 6 2>&1 | tee ~/pre_IFS_${LABELI}.log
```

E confira:

```bash
ls ../dataout/${LABELI}/Pre/                       # IFS:..., x1.<RES>.init.nc (e lbc.*.nc no regional)
grep -i "error\|crit" ../dataout/${LABELI}/Pre/logs/log.init_atmosphere.0000.*.out
python ./wps_inventory.py ../dataout/${LABELI}/Pre/IFS:${LABELI:0:4}-${LABELI:4:2}-${LABELI:6:2}_${LABELI:8:2} --levels
```

Use o Python do ambiente conda nesse último comando (o que o `find_python` imprimir).
