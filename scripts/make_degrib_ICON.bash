#!/bin/bash
umask 022
#-----------------------------------------------------------------------------#
# !SCRIPT: make_degrib_ICON                                       [ICON/IFS]
#
# !DESCRIPTION:
#     Faz, para o ICON, o papel do ungrib: converte os GRIB2 baixados por
#     get_icon_dwd.bash em arquivos intermediarios do WPS (ICON:YYYY-MM-DD_HH)
#     em ${DATAOUT}/LABELI/Pre, lidos pelo init_atmosphere (config_met_prefix
#     = 'ICON'). Nao usa ungrib.exe nem Vtable.
#
#     icon2wps.py: bunzip2 + remap CDO (pesos do DWD) para lat-lon 0.125 grau,
#     recorte (ICON_BOX; "auto" = caixa da malha regional), troca de nomes e
#     unidades e escrita do intermediario. Roda no no de login (como o ungrib
#     do GFS no upstream), com ICON_NPROC processos do cdo em paralelo.
#
# !CALLING SEQUENCE:
#     ./make_degrib_ICON.bash ICON RES_MESH LABELI FCST   (chamado pelo 2.pre_processing.bash)
#-----------------------------------------------------------------------------#

if [ $# -ne 4 ]
then
   echo ""
   echo "Instructions: execute the command below"
   echo ""
   echo "${0} EXP RES_MESH LABELI FCST"
   echo ""
   echo "EXP         :: ICON"
   echo "RES_MESH    :: Number of horizontal grid cells (global) or regional mesh identifier (e.g., 655362 for the ~30 km mesh)"
   echo "LABELI      :: Forecast initialization date and time (YYYYMMDDHH), e.g., 2026080100"
   echo "FCST        :: Forecast length in hours (e.g., 24, 36, 48, etc.)"
   echo ""
   echo "Example of a 24-hour forecast (download first with ./get_icon_dwd.bash LABELI FCST):"
   echo "${0} ICON 655362 $(date -u +%Y%m%d)00 24"
   echo ""
   exit 1
fi

# Set environment variables exports:
echo ""
echo -e "\033[1;32m==>\033[0m Moduling environment for MONAN model...\n"
. setenv.bash

echo ""
echo "---- Make Degrib ${1} ----"
echo ""

# Standart directories variables:---------------------------------------
DIRHOMES=${DIR_SCRIPTS}/scripts_CD-CT;  mkdir -p ${DIRHOMES}
DIRHOMED=${DIR_DADOS}/scripts_CD-CT;    mkdir -p ${DIRHOMED}
SCRIPTS=${DIRHOMES}/scripts;            mkdir -p ${SCRIPTS}
DATAIN=${DIRHOMED}/datain;              mkdir -p ${DATAIN}
DATAOUT=${DIRHOMED}/dataout;            mkdir -p ${DATAOUT}
SOURCES=${DIRHOMES}/sources;            mkdir -p ${SOURCES}
EXECS=${DIRHOMED}/execs;                mkdir -p ${EXECS}
#----------------------------------------------------------------------


# Input variables:--------------------------------------
EXP=${1};         #EXP=ICON
RES=${2};         #RES=1024002
YYYYMMDDHHi=${3}; #YYYYMMDDHHi=2026110500
FCST=${4};        #FCST=24
#-------------------------------------------------------

# Local variables--------------------------------------
start_date=${YYYYMMDDHHi:0:4}-${YYYYMMDDHHi:4:2}-${YYYYMMDDHHi:6:2}_${YYYYMMDDHHi:8:2}:00:00
export DIRRUN=${DIRHOMED}/run.${YYYYMMDDHHi}; rm -fr ${DIRRUN}; mkdir -p ${DIRRUN}
BNDDIR=${DATAIN}/ICON/${YYYYMMDDHHi}
ICONCDO=${DATAIN}/fixed/icon_cdo
HHLDIR=${DATAIN}/fixed/icon_hhl
VCOORD=${ICON_VCOORD:-model}
NPROC=${ICON_NPROC:-8}

# Python com numpy + eccodes (ICON_PYTHON ou ambiente conda; ver setenv.bash)
PYTHON=$(find_python) || exit 1
# cdo: ICON_CDO; senao o do mesmo ambiente do Python (conda); senao o do PATH. Com caminho completo, o
# icon2wps.py roda o cdo sem o LD_LIBRARY_PATH do modelo (evita conflito com as bibliotecas do compilador).
if [ -n "${ICON_CDO}" ]
then
   CDO=${ICON_CDO}
elif [ -x "$(dirname ${PYTHON})/cdo" ]
then
   CDO=$(dirname ${PYTHON})/cdo
else
   CDO=$(command -v cdo)
fi
if [ -z "${CDO}" ]
then
   echo -e "${RED}==>${NC} cdo not found: install it in the Python env (conda install -c conda-forge cdo) or set ICON_CDO."
   exit 1
fi
echo -e "${GREEN}==>${NC} Python: ${PYTHON}\n${GREEN}==>${NC} cdo:    ${CDO}\n"
#-------------------------------------------------------
mkdir -p ${DATAOUT}/${YYYYMMDDHHi}/Pre/logs

# O ICON e baixado antes, com ./get_icon_dwd.bash ${YYYYMMDDHHi} ${FCST}
files_needed=("${SCRIPTS}/icon2wps.py" "${ICONCDO}/target_grid.txt" "${ICONCDO}/weights.nc" "${BNDDIR}/icon_global_icosahedral_time-invariant_${YYYYMMDDHHi}_HSURF.grib2.bz2")
if [[ ${VCOORD} == "model" ]]; then files_needed+=("${BNDDIR}/model_levels.txt"); fi
if [[ ${MODERUN} == "R" && ${ICON_BOX} == "auto" ]]; then files_needed+=("${SCRIPTS}/mesh_box.py" "${DATAIN}/fixed/x1.${RES}.static.nc"); fi
for file in "${files_needed[@]}"
do
  if [ ! -s "${file}" ]
  then
    echo -e  "\n${RED}==>${NC} ***** ATTENTION *****\n"
    echo -e  "${RED}==>${NC} [${0}] At least the file ${file} was not found. \n"
    echo -e  "${RED}==>${NC} Run first: ./get_icon_dwd.bash ${YYYYMMDDHHi} ${FCST} \n"
    exit 1
  fi
done

if [[ $MODERUN == "R" ]]; then
   echo -e "Converting ICON data for Regional (limited-area) mode – initial and lateral boundary conditions.\n"
   fcst=${FCST}
elif [[ ${MODERUN} == "G" ]]; then
   echo -e "Converting ICON data for Global mode – only initial conditions.\n"
   echo -e "${YELLOW}==>${NC} Global ICON at 0.125 deg: the intermediate file has several GB and the conversion needs ~10+ GB of RAM.\n"
   fcst=0
else
   echo -e  "\n${RED}==>${NC} ***** ATTENTION *****\n"
   echo -e  "${RED}==>${NC} Make degrib phase fails during degrib! Please select MODERUN=R or G so that degrib can be done appropriately.\n"
   echo -e  "${RED}==>${NC} Exiting script. \n"
   exit 1
fi
box=$(grib_box ${ICON_BOX} ${PYTHON} ${DATAIN}/fixed/x1.${RES}.static.nc) || exit 1
echo -e "${GREEN}==>${NC} ICON lat-lon box (lon1,lon2,lat1,lat2): ${box}\n"

# CDO remap + conversao para intermediarios do WPS (faz o papel do ungrib)
cd ${DIRRUN}
time ${PYTHON} ${SCRIPTS}/icon2wps.py --indir ${BNDDIR} --run ${YYYYMMDDHHi} \
   --fcst ${fcst} --step $((LBCINT / 3600)) \
   --grid ${ICONCDO}/target_grid.txt --weights ${ICONCDO}/weights.nc --box="${box}" \
   --vcoord ${VCOORD} --hhl-dir ${HHLDIR} \
   --prefix ${EXP} --cdo ${CDO} --nproc ${NPROC} --outdir ${DIRRUN} \
   2>&1 | tee ${DATAOUT}/${YYYYMMDDHHi}/Pre/logs/icon2wps.${start_date}.log

if [ ${PIPESTATUS[0]} -ne 0 ]
then
   echo -e  "\n${RED}==>${NC} ***** ATTENTION *****\n"
   echo -e  "${RED}==>${NC} icon2wps.py failed! Check ${DATAOUT}/${YYYYMMDDHHi}/Pre/logs/icon2wps.${start_date}.log \n"
   exit 1
fi

mv ${DIRRUN}/${EXP}\:* ${DATAOUT}/${YYYYMMDDHHi}/Pre

files_ungrib=("${EXP}:${start_date:0:13}")
for file in "${files_ungrib[@]}"
do
  if [ ! -s ${DATAOUT}/${YYYYMMDDHHi}/Pre/${file} ]
  then
    echo -e  "\n${RED}==>${NC} ***** ATTENTION *****\n"
    echo -e  "${RED}==>${NC} Degrib fails! At least the file ${file} was not generated at ${DATAOUT}/${YYYYMMDDHHi}/Pre. \n"
    echo -e  "${RED}==>${NC} Check logs at ${DATAOUT}/${YYYYMMDDHHi}/Pre/logs/icon2wps.* .\n"
    echo -e  "${RED}==>${NC} Exiting script. \n"
    exit 1
  fi
done

chmod -R 755 ${DATAOUT}/${YYYYMMDDHHi}/Pre/*
cd ${SCRIPTS}
rm -fr ${DIRRUN}
