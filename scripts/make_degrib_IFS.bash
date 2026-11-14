#!/bin/bash
umask 022
#-----------------------------------------------------------------------------#
# !SCRIPT: make_degrib_IFS                                        [ICON/IFS]
#
# !DESCRIPTION:
#     Faz, para o IFS, o papel do ungrib: converte os GRIB2 baixados por
#     get_ifs_ecmwf.bash em arquivos intermediarios do WPS (IFS:YYYY-MM-DD_HH)
#     em ${DATAOUT}/LABELI/Pre, lidos pelo init_atmosphere (config_met_prefix
#     = 'IFS'). Nao usa ungrib.exe nem Vtable, nem cdo (o IFS ja vem em
#     lat-lon: so recorta, com IFS_BOX; "auto" = caixa da malha regional).
#
# !CALLING SEQUENCE:
#     ./make_degrib_IFS.bash IFS RES_MESH LABELI FCST   (chamado pelo 2.pre_processing.bash)
#-----------------------------------------------------------------------------#

if [ $# -ne 4 ]
then
   echo ""
   echo "Instructions: execute the command below"
   echo ""
   echo "${0} EXP RES_MESH LABELI FCST"
   echo ""
   echo "EXP         :: IFS"
   echo "RES_MESH    :: Number of horizontal grid cells (global) or regional mesh identifier (e.g., 655362 for the ~30 km mesh)"
   echo "LABELI      :: Forecast initialization date and time (YYYYMMDDHH), e.g., 2026080100"
   echo "FCST        :: Forecast length in hours (e.g., 24, 36, 48, etc.)"
   echo ""
   echo "Example of a 24-hour forecast (download first with ./get_ifs_ecmwf.bash LABELI FCST):"
   echo "${0} IFS 655362 $(date -u +%Y%m%d)00 24"
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
EXP=${1};         #EXP=IFS
RES=${2};         #RES=1024002
YYYYMMDDHHi=${3}; #YYYYMMDDHHi=2026110500
FCST=${4};        #FCST=24
#-------------------------------------------------------

# Local variables--------------------------------------
start_date=${YYYYMMDDHHi:0:4}-${YYYYMMDDHHi:4:2}-${YYYYMMDDHHi:6:2}_${YYYYMMDDHHi:8:2}:00:00
export DIRRUN=${DIRHOMED}/run.${YYYYMMDDHHi}; rm -fr ${DIRRUN}; mkdir -p ${DIRRUN}
BNDDIR=${DATAIN}/IFS/${YYYYMMDDHHi}

# Python com numpy + eccodes (ICON_PYTHON ou ambiente conda; ver setenv.bash)
PYTHON=$(find_python) || exit 1
echo -e "${GREEN}==>${NC} Python: ${PYTHON}\n"
#-------------------------------------------------------
mkdir -p ${DATAOUT}/${YYYYMMDDHHi}/Pre/logs

# O IFS e baixado antes, com ./get_ifs_ecmwf.bash ${YYYYMMDDHHi} ${FCST}
# (o ifs2wps.py usa as conversoes e a escrita do icon2wps.py)
files_needed=("${SCRIPTS}/ifs2wps.py" "${SCRIPTS}/icon2wps.py" "${BNDDIR}/ifs_sfc0.grib2" "${BNDDIR}/ifs_sol.grib2" "${BNDDIR}/ifs_pl.000.grib2" "${BNDDIR}/ifs_sfc.000.grib2")
if [[ ${MODERUN} == "R" && ${IFS_BOX} == "auto" ]]; then files_needed+=("${SCRIPTS}/mesh_box.py" "${DATAIN}/fixed/x1.${RES}.static.nc"); fi
for file in "${files_needed[@]}"
do
  if [ ! -s "${file}" ]
  then
    echo -e  "\n${RED}==>${NC} ***** ATTENTION *****\n"
    echo -e  "${RED}==>${NC} [${0}] At least the file ${file} was not found. \n"
    echo -e  "${RED}==>${NC} Run first: ./get_ifs_ecmwf.bash ${YYYYMMDDHHi} ${FCST} \n"
    exit 1
  fi
done

if [[ $MODERUN == "R" ]]; then
   echo -e "Converting IFS data for Regional (limited-area) mode – initial and lateral boundary conditions.\n"
   fcst=${FCST}
elif [[ ${MODERUN} == "G" ]]; then
   echo -e "Converting IFS data for Global mode – only initial conditions.\n"
   fcst=0
else
   echo -e  "\n${RED}==>${NC} ***** ATTENTION *****\n"
   echo -e  "${RED}==>${NC} Make degrib phase fails during degrib! Please select MODERUN=R or G so that degrib can be done appropriately.\n"
   echo -e  "${RED}==>${NC} Exiting script. \n"
   exit 1
fi
box=$(grib_box ${IFS_BOX} ${PYTHON} ${DATAIN}/fixed/x1.${RES}.static.nc) || exit 1
echo -e "${GREEN}==>${NC} IFS lat-lon box (lon1,lon2,lat1,lat2): ${box}\n"

# Recorte + conversao para intermediarios do WPS (faz o papel do ungrib)
cd ${DIRRUN}
time ${PYTHON} ${SCRIPTS}/ifs2wps.py --indir ${BNDDIR} --run ${YYYYMMDDHHi} \
   --fcst ${fcst} --step $((LBCINT / 3600)) --box="${box}" \
   --prefix ${EXP} --outdir ${DIRRUN} \
   2>&1 | tee ${DATAOUT}/${YYYYMMDDHHi}/Pre/logs/ifs2wps.${start_date}.log

if [ ${PIPESTATUS[0]} -ne 0 ]
then
   echo -e  "\n${RED}==>${NC} ***** ATTENTION *****\n"
   echo -e  "${RED}==>${NC} ifs2wps.py failed! Check ${DATAOUT}/${YYYYMMDDHHi}/Pre/logs/ifs2wps.${start_date}.log \n"
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
    echo -e  "${RED}==>${NC} Check logs at ${DATAOUT}/${YYYYMMDDHHi}/Pre/logs/ifs2wps.* .\n"
    echo -e  "${RED}==>${NC} Exiting script. \n"
    exit 1
  fi
done

chmod -R 755 ${DATAOUT}/${YYYYMMDDHHi}/Pre/*
cd ${SCRIPTS}
rm -fr ${DIRRUN}
