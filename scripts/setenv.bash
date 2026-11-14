#!/bin/bash
umask 022

# Choose the simulation mode:
export MODERUN=G     # R=Regional simulation and G=Global simulation.
export LBCINT=10800  # Interval (seconds) for updating lateral boundary conditions (when regional mode).

# ==== [ICON/IFS] CI/CC do ICON (DWD) e do IFS (ECMWF) ======================================================
# Usados com EXP=ICON ou EXP=IFS (ver docs/ no repositorio MONAN-ICON-IFS). Todos podem ser trocados na
# linha de comando sem editar este arquivo, ex.:  ICON_VCOORD=pressure ./2.pre_processing.bash ICON ...
#
# Python com numpy + eccodes (converte os GRIB2). Vazio = procura sozinho (find_python, abaixo) nos ambientes
# conda do usuario e no python3 do sistema. Para fixar um: export ICON_PYTHON=/caminho/env/bin/python
export ICON_PYTHON=${ICON_PYTHON:-}
# cdo (so o ICON usa). Vazio = o cdo do mesmo ambiente do ICON_PYTHON; senao o do PATH.
export ICON_CDO=${ICON_CDO:-}
# ICON: niveis verticais de entrada: model (niveis nativos do ICON, recomendado) ou pressure (18 niveis)
export ICON_VCOORD=${ICON_VCOORD:-model}
# ICON (niveis do modelo): todos os niveis nativos ate ICON_ZFULL m acima do solo; acima, 1 a cada ICON_THIN;
# so UM nivel acima do topo do MONAN (ICON_ZTOP; vazio = config_ztop do namelist.init_atmosphere.TEMPLATE)
export ICON_ZFULL=${ICON_ZFULL:-16000}
export ICON_THIN=${ICON_THIN:-2}
export ICON_ZTOP=${ICON_ZTOP:-}
export ICON_NPROC=${ICON_NPROC:-8}      # downloads/conversoes em paralelo (no de login: nao exagere)
# IFS: resolucao (0p1, 0p25 ou 0p4-beta) e fonte (ecmwf = ultimos ~3 dias; aws = arquivo desde 2023)
export IFS_RESOL=${IFS_RESOL:-0p1}
export IFS_SOURCE=${IFS_SOURCE:-ecmwf}
export IFS_NPROC=${IFS_NPROC:-8}
# Recorte lat-lon dos dados no modo regional: "lon1,lon2,lat1,lat2" (graus) ou "auto" = caixa da malha
# regional (x1.RES.static.nc) + GRIB_BOX_MARGIN graus. No modo global o recorte e sempre "global".
export ICON_BOX=${ICON_BOX:-auto}
export IFS_BOX=${IFS_BOX:-${ICON_BOX}}
export GRIB_BOX_MARGIN=${GRIB_BOX_MARGIN:-5}

# ==== [ICON/IFS] Grade vertical do MONAN (opcional, vale para qualquer EXP) ===============================
# NVERTLEV vazio = usa o config_nvertlevels dos namelists (55 no MONAN 2.0). Se mudar, o init.nc, as LBCs e
# os nomes dos arquivos do modelo/pos passam a usar NVERTLEV.
# ZETA_LEVELS vazio = grade padrao do MPAS (config_tc_vertical_grid). Com um nome de arquivo (em namelists/,
# gerado por zeta_levels.py), usa config_specified_zeta_levels: NVERTLEV+1 alturas, a ultima = config_ztop.
# ATENCAO: troque os dois juntos e rode de novo o 2.pre_processing.bash (init.nc e lbc.*.nc dependem disso).
export NVERTLEV=${NVERTLEV:-}
export ZETA_LEVELS=${ZETA_LEVELS:-}
# ==========================================================================================================

# Choose your compiler here (only on Jaci; on Egeon the compiler is fixed to ‘gnu’):
export COMPILER=intel
#export COMPILER=gnu
#export COMPILER=cray
#export COMPILER=nvidia

# Squeduler detect:
if command -v sbatch &> /dev/null
then
   export SCHEDULER_SYSTEM="SLURM"
   echo "SLURM detected." 
elif command -v qsub &> /dev/null
then
   export SCHEDULER_SYSTEM="PBS"
   echo "PBS detected."
else
   export SCHEDULER_SYSTEM="GENERIC"
   echo "No SCHEDULER detected."
fi

# Detect hostname
THOSTNAME=$(hostname -s)

# Identifying several names of the egeon:
case ${THOSTNAME} in
   egeon-login|headnode|n[0-9]|n[1-2][0-9]|n3[0-3])
      export HOSTNAME="egeon"
      export MAKE_TARG=gfortran
      export MAKE_TARG2=gfortran
      COMPILER=gnu
      ;;
   ian[0-9]*|cn-0[0-9][0-9][0-9])
      export HOSTNAME="ian"
      if [ "$COMPILER" == "intel" ]; then
         export MAKE_TARG=intel-xd2000
         export MAKE_TARG2=intel2-xd2000
      elif [ "$COMPILER" == "gnu" ]; then
         export MAKE_TARG=gfortran-xd2000
         export MAKE_TARG2=gfortran-xd2000
      elif [ "$COMPILER" == "cray" ]; then
         export MAKE_TARG=cray-xd2000
         export MAKE_TARG2=cray-xd2000
      elif [ "$COMPILER" == "nvidia" ]; then
         export MAKE_TARG=nvhpc-xd2000
         export MAKE_TARG2=nvhpc-xd2000
      fi
      ;;
esac
# Make the same for other machines/systems...
echo "Host detected: $HOSTNAME"
echo "Compiler to be used: ${COMPILER}"

# Set unique key: scheduler + host:
export SYSTEM_KEY="${SCHEDULER_SYSTEM}_${HOSTNAME}"
export SYSTEM_KEYC="${SCHEDULER_SYSTEM}_${HOSTNAME}_${COMPILER}"


# Set environment variables and importants directories-------------------------------------------------- 


# MONAN-suite install root directories:
# Put your directories:
export DIR_SCRIPTS=$(dirname $(dirname $(pwd)))
export DIR_DADOS=${DIR_SCRIPTS}
export MONANDIR=$MONANDIR

# Workaround for 'module purge' failing with 'set -e' when Conda aliases are undefined.
alias start_conda=: stop_conda=:

# Load your system setenv:
. ${DIR_SCRIPTS}/scripts_CD-CT/scripts/stools/setenv_${SYSTEM_KEYC}.bash

#-----------------------------------------------------------------------
# We discourage changing the variables below:

# Others variables:


# Colors:
#
export GREEN='\033[1;32m'  # Green
export RED='\033[1;31m'    # Red
export NC='\033[0m'        # No Color
export BLUE='\033[01;34m'  # Blue
export YELLOW='\033[1;33m' # Yellow

# Functions: ======================================================================================================

# [ICON/IFS] Python com numpy + eccodes: ICON_PYTHON se definido; senao o primeiro ambiente conda do usuario
# (ou o python3 do sistema) que importe os dois. Imprime o caminho; retorna 1 se nao achar.
find_python () {
   local cand cands
   if [ -n "${ICON_PYTHON}" ]
   then
      cands="${ICON_PYTHON}"
   else
      cands="$(ls -d ${HOME}/.conda/envs/*/bin/python ${HOME}/miniconda3/envs/*/bin/python \
               ${HOME}/miniforge3/envs/*/bin/python ${HOME}/anaconda3/envs/*/bin/python \
               ${HOME}/miniconda3/bin/python ${HOME}/miniforge3/bin/python ${HOME}/anaconda3/bin/python \
               2>/dev/null) $(command -v python3)"
   fi
   for cand in ${cands}
   do
      [ -x "${cand}" ] || continue
      if "${cand}" -c "import numpy, eccodes" > /dev/null 2>&1
      then
         echo "${cand}"
         return 0
      fi
   done
   echo -e "${RED}==>${NC} No Python with numpy + eccodes found (tried: ${cands})." >&2
   echo -e "${RED}==>${NC} Create one (once):  conda create -n monan_grib -c conda-forge python numpy python-eccodes cdo" >&2
   echo -e "${RED}==>${NC} or set ICON_PYTHON=<.../bin/python> in setenv.bash." >&2
   return 1
}

# [ICON/IFS] Valor de uma variavel num namelist:  nml_get ARQUIVO VARIAVEL
nml_get () {
   sed -n -E "s/^[[:space:]]*${2}[[:space:]]*=[[:space:]]*'?([^'!]*)'?.*/\1/p" ${1} | head -1 | xargs
}

# [ICON/IFS] Troca uma variavel de um namelist ja gerado ou, se ela nao existir, acrescenta no grupo &GRUPO:
#    nml_set ARQUIVO GRUPO VARIAVEL VALOR      (texto vai com aspas simples no VALOR, ex.: "'arquivo.txt'")
nml_set () {
   local file=${1} group=${2} var=${3} value=${4}
   if grep -qE "^[[:space:]]*${var}[[:space:]]*=" ${file}
   then
      sed -i -E "s|^([[:space:]]*${var}[[:space:]]*=).*|\1 ${value}|" ${file}
   elif grep -qE "^[[:space:]]*&${group}[[:space:]]*$" ${file}
   then
      awk -v g="&${group}" -v line="    ${var} = ${value}" '{print} $1 == g {print line}' ${file} > ${file}.tmp
      mv ${file}.tmp ${file}
   else
      echo -e "${RED}==>${NC} nml_set: group &${group} not found in ${file}" >&2
      return 1
   fi
}

# [ICON/IFS] config_nfglevels precisa ser >= niveis atmosfericos do first guess + 1 (a superficie; o PMSL nao
# conta). GFS (34+1), ERA5, IFS (14+1) e ICON em pressao (18+1) cabem nos 35 do namelist padrao; o ICON nos
# niveis do modelo (~75) nao. Aumenta o valor do namelist gerado so quando precisa. Usa EXP, DATAIN e
# YYYYMMDDHHi do script que chama.
#    set_fg_levels ARQUIVO_NAMELIST
set_fg_levels () {
   local mlev=${DATAIN}/ICON/${YYYYMMDDHHi}/model_levels.txt need cur
   if [[ ${EXP} == "ICON" && ${ICON_VCOORD} == "model" && -s ${mlev} ]]
   then
      need=$(( $(wc -w < ${mlev}) + 1 ))
      cur=$(nml_get ${1} config_nfglevels)
      if [ -z "${cur}" ] || [ ${cur} -lt ${need} ]
      then
         echo -e "${GREEN}==>${NC} config_nfglevels: ${cur:-unset} -> ${need} (ICON model levels + surface)"
         nml_set ${1} dimensions config_nfglevels ${need} || return 1
      fi
   fi
   return 0
}

# [ICON/IFS] Grade vertical opcional (NVERTLEV/ZETA_LEVELS do inicio deste arquivo) num namelist.init_atmosphere
# ja gerado. Com ZETA_LEVELS, confere o arquivo e copia para DIRRUN.
#    set_vertical_grid ARQUIVO_NAMELIST DIRRUN [lbc]   (lbc: so o numero de niveis; a grade vem do init.nc)
set_vertical_grid () {
   local nml=${1} dirrun=${2} mode=${3:-init} zfile nlev nlines nvalues ztop_file ztop_nml
   if [ -n "${NVERTLEV}" ]
   then
      nml_set ${nml} dimensions config_nvertlevels ${NVERTLEV} || return 1
   fi
   nlev=$(nml_get ${nml} config_nvertlevels)
   if [ -z "${ZETA_LEVELS}" ] || [ "${mode}" == "lbc" ]
   then
      echo -e "${GREEN}==>${NC} Vertical grid: ${nlev} levels${ZETA_LEVELS:+ (from x1.*.init.nc)}"
      return 0
   fi
   zfile=${SCRIPTS}/namelists/${ZETA_LEVELS}
   if [ ! -s ${zfile} ]
   then
      echo -e "${RED}==>${NC} Vertical levels file ${zfile} not found (ZETA_LEVELS in setenv.bash)." >&2
      return 1
   fi
   # o init_atmosphere le NVERTLEV+1 valores (um por linha, crescentes, em metros); a ultima altura vira o topo
   nlines=$(grep -cvE '^[[:space:]]*$' ${zfile})
   nvalues=$(grep -cE '^[[:space:]]*[0-9]+(\.[0-9]*)?[[:space:]]*$' ${zfile})
   if [ ${nlines} -ne $((nlev + 1)) ] || [ ${nvalues} -ne $((nlev + 1)) ]
   then
      echo -e "${RED}==>${NC} ${zfile} has ${nlines} lines / ${nvalues} values; expected config_nvertlevels+1 = $((nlev + 1))." >&2
      echo -e "${RED}==>${NC} Set NVERTLEV in setenv.bash to the number of layers of ${ZETA_LEVELS}." >&2
      return 1
   fi
   # A ultima altura do arquivo substitui o config_ztop no init_atmosphere. Os dois precisam ser iguais, porque
   # os scripts do ICON escolhem os niveis de entrada a partir do config_ztop.
   ztop_file=$(grep -vE '^[[:space:]]*$' ${zfile} | tail -1)
   ztop_nml=$(nml_get ${nml} config_ztop)
   if ! awk -v a=${ztop_file} -v b=${ztop_nml} 'BEGIN{exit (a+0 == b+0) ? 0 : 1}'
   then
      echo -e "${RED}==>${NC} Top of ${zfile} (${ztop_file} m) differs from config_ztop (${ztop_nml} m)." >&2
      return 1
   fi
   cp -f ${zfile} ${dirrun}
   nml_set ${nml} vertical_grid config_specified_zeta_levels "'${ZETA_LEVELS}'" || return 1
   echo -e "${GREEN}==>${NC} Vertical grid: ${nlev} levels from ${ZETA_LEVELS} (top ${ztop_file} m)"
}

# [ICON/IFS] Recorte lat-lon dos dados (ICON_BOX/IFS_BOX): "global" no modo global; no regional, a caixa
# pedida ou, com "auto", a da malha (x1.RES.static.nc) + GRIB_BOX_MARGIN graus (mesh_box.py).
#    grib_box CAIXA PYTHON ARQUIVO_DA_MALHA
grib_box () {
   if [[ ${MODERUN} == "G" ]]
   then
      echo "global"
   elif [[ ${1} == "auto" ]]
   then
      ${2} ${SCRIPTS:-.}/mesh_box.py --margin ${GRIB_BOX_MARGIN} ${3}
   else
      echo "${1}"
   fi
}

how_many_nodes () { 
   nume=${1}   
   deno=${2}
   num=$(echo "${nume}/${deno}" | bc -l)  
   how_many_nodes_int=$(echo "${num}/1" | bc)
   dif=$(echo "scale=0; (${num}-${how_many_nodes_int})*100/1" | bc)
   rest=$(echo "scale=0; (((${num}-${how_many_nodes_int})*${deno})+0.5)/1" | bc -l)
   if [ ${dif} -eq 0 ]; then how_many_nodes_left=0; else how_many_nodes_left=1; fi
   if [ ${how_many_nodes_int} -eq 0 ]; then how_many_nodes_int=1; how_many_nodes_left=0; rest=0; fi
   how_many_nodes=$(echo "${how_many_nodes_int}+${how_many_nodes_left}" | bc )
   #echo "INT number of nodes needed: \${how_many_nodes_int}  = ${how_many_nodes_int}"
   #echo "number of nodes left:       \${how_many_nodes_left} = ${how_many_nodes_left}"
   echo "The number of nodes needed: \${how_many_nodes}  = ${how_many_nodes}"
   echo ""
}
#----------------------------------------------------------------------------------------------

