#!/bin/bash
umask 022
#-----------------------------------------------------------------------------#
# !SCRIPT: get_icon_dwd                                           [ICON/IFS]
#
# !DESCRIPTION:
#     Baixa do DWD opendata o ICON global (malha icosaedrica R03B07, ~13 km,
#     GRIB2 comprimido com bzip2) usado com EXP=ICON, e os pesos de
#     remapeamento do CDO (so na primeira vez):
#
#        o ${DATAIN}/ICON/YYYYMMDDHH/*.grib2.bz2
#        o ${DATAIN}/fixed/icon_cdo/{target_grid.txt,weights.nc}
#        o ${DATAIN}/fixed/icon_hhl/*_HHL.grib2.bz2  (alturas dos niveis, 1 vez)
#
#     O DWD mantem so as rodadas das ultimas ~24 h (00, 06, 12 e 18 UTC).
#     Solo, neve e gelo marinho sao baixados so na hora inicial; as LBCs
#     (modo regional, a cada LBCINT) so precisam da atmosfera e da superficie.
#
#     ICON_VCOORD=model (padrao): atmosfera nos niveis do modelo do ICON.
#        Os niveis sao escolhidos por icon_levels.py a partir do HHL e salvos
#        em model_levels.txt: todos os niveis ate ICON_ZFULL (m acima do solo),
#        acima disso um a cada ICON_THIN, e so UM nivel acima do topo do MONAN
#        (ICON_ZTOP; vazio = config_ztop do namelist.init_atmosphere.TEMPLATE).
#        Ao mudar algum deles, apague o model_levels.txt e o download_ok da rodada.
#     ICON_VCOORD=pressure: os 18 niveis de pressao do opendata (1000-50 hPa).
#
#     Rodar de novo e seguro: arquivos completos nao sao baixados outra vez
#     (wget -c) e, depois de um download completo (marcador download_ok), o
#     DWD nem e consultado: a conversao pode ser refeita depois que a rodada
#     saiu do opendata. Para forcar um novo download, apague o download_ok.
#
# !CALLING SEQUENCE:
#     ./get_icon_dwd.bash LABELI FCST      (chamado pelo 2.pre_processing.bash)
#-----------------------------------------------------------------------------#

if [ $# -ne 2 ]
then
   echo ""
   echo "Instructions: execute the command below"
   echo ""
   echo "${0} LABELI FCST"
   echo ""
   echo "LABELI      :: ICON run (YYYYMMDDHH, 00/06/12/18 UTC), one of the last ~24 h, e.g., $(date -u +%Y%m%d)00"
   echo "FCST        :: Forecast length in hours (e.g., 24, 36, 48, etc.)"
   echo ""
   exit 1
fi

# Set environment variables exports:
echo ""
echo -e "\033[1;32m==>\033[0m Moduling environment for MONAN model...\n"
. setenv.bash

# Standart directories variables:---------------------------------------
DIRHOMES=${DIR_SCRIPTS}/scripts_CD-CT;  mkdir -p ${DIRHOMES}
DIRHOMED=${DIR_DADOS}/scripts_CD-CT;    mkdir -p ${DIRHOMED}
SCRIPTS=${DIRHOMES}/scripts;            mkdir -p ${SCRIPTS}
DATAIN=${DIRHOMED}/datain;              mkdir -p ${DATAIN}
#----------------------------------------------------------------------

# Input variables:--------------------------------------
YYYYMMDDHHi=${1}; #YYYYMMDDHHi=2026110500
FCST=${2};        #FCST=24
#-------------------------------------------------------

# Local variables--------------------------------------
hhi=${YYYYMMDDHHi:8:2}
BASEURL=https://opendata.dwd.de/weather/nwp/icon/grib/${hhi}
OUT=${DATAIN}/ICON/${YYYYMMDDHHi};       mkdir -p ${OUT}
ICONCDO=${DATAIN}/fixed/icon_cdo
HHLDIR=${DATAIN}/fixed/icon_hhl
NPROC=${ICON_NPROC:-8}
VCOORD=${ICON_VCOORD:-model}
#-------------------------------------------------------

# Checagens rapidas (antes de qualquer download)--------
if [[ ! ${hhi} =~ ^(00|06|12|18)$ ]]
then
   echo -e "${RED}==>${NC} ICON: LABELI must be a 00, 06, 12 or 18 UTC run (got ${YYYYMMDDHHi})."
   exit 1
fi
if [[ ${VCOORD} != "model" && ${VCOORD} != "pressure" ]]
then
   echo -e "${RED}==>${NC} ICON_VCOORD must be model or pressure (got ${VCOORD})."
   exit 1
fi
if [[ ${MODERUN} == "R" ]]
then
   # LBCs a cada LBCINT: o ICON tem saidas de hora em hora ate +78 h e de 3 em 3 h depois disso
   if [ $((LBCINT % 3600)) -ne 0 ]
   then
      echo -e "${RED}==>${NC} ICON: LBCINT (${LBCINT} s, setenv.bash) must be a multiple of 3600 s."
      exit 1
   fi
   dt=$((LBCINT / 3600))
   # Horizonte do ICON global: 180 h nas rodadas 00/12 UTC, 120 h nas 06/18 UTC
   if [[ ${hhi} == "00" || ${hhi} == "12" ]]; then maxf=180; else maxf=120; fi
   if [ ${FCST} -gt ${maxf} ]
   then
      echo -e "${RED}==>${NC} ICON ${hhi} UTC runs go only up to +${maxf} h (FCST=${FCST})."
      exit 1
   fi
   if [ ${FCST} -gt 78 ] && [ $((dt % 3)) -ne 0 ]
   then
      echo -e "${RED}==>${NC} ICON has 3-hourly output after +78 h: use LBCINT multiple of 10800 s or FCST <= 78."
      exit 1
   fi
else
   FCST=0; dt=1   # modo global: so a condicao inicial
fi
age=$(( ( $(date -u +%s) - $(date -u -d "${YYYYMMDDHHi:0:8} ${hhi}:00" +%s) ) / 3600 ))
#-------------------------------------------------------

# Python com numpy + eccodes (ICON_PYTHON ou ambiente conda; ver setenv.bash)
PYTHON=$(find_python) || exit 1
echo -e "${GREEN}==>${NC} Python for GRIB conversion: ${PYTHON}\n"

# Pastas no DWD (minusculas) : nome da variavel nos arquivos (maiusculas)
PL="t:T u:U v:V relhum:RELHUM fi:FI"
ML="t:T u:U v:V qv:QV p:P"
SL="ps:PS pmsl:PMSL t_2m:T_2M td_2m:TD_2M u_10m:U_10M v_10m:V_10M t_g:T_G"
SL0="fr_ice:FR_ICE w_snow:W_SNOW h_snow:H_SNOW"
SOIL0="t_so:T_SO w_so:W_SO"
TI="hsurf:HSURF fr_land:FR_LAND"
#-------------------------------------------------------


# Rodada ja baixada por completo? O marcador download_ok guarda "FCST DT VCOORD". Se cobre o pedido
# (mesmo DT e VCOORD, FCST >= o pedido) e os niveis escolhidos continuam la, nao consulta o DWD.
if [ -s ${OUT}/download_ok ]
then
   read mfcst mdt mvcoord < ${OUT}/download_ok
   if [[ ${mdt} == ${dt} && ${mvcoord} == ${VCOORD} && ${mfcst} -ge ${FCST} ]] && \
      [[ ${VCOORD} != "model" || -s ${OUT}/model_levels.txt ]]
   then
      echo -e "${GREEN}==>${NC} ICON ${YYYYMMDDHHi} (+${mfcst} h, ${VCOORD} levels) already downloaded in ${OUT}. Skipping download.\n"
      exit 0
   fi
fi

if [ ${age} -gt 24 ]
then
   echo -e "${YELLOW}==>${NC} Warning: ICON ${YYYYMMDDHHi} is ${age} h old; DWD opendata keeps only the last ~24 h. Trying anyway...\n"
fi


# Pesos de remapeamento do CDO (ICON global R03B07 -> lat-lon 0.125 grau), uma vez:
if [ ! -s ${ICONCDO}/target_grid.txt ] || [ ! -s ${ICONCDO}/weights.nc ]
then
   echo -e "${GREEN}==>${NC} Downloading CDO remapping weights from DWD...\n"
   mkdir -p ${ICONCDO}
   cd ${ICONCDO}
   wget -c https://opendata.dwd.de/weather/lib/cdo/ICON_GLOBAL2WORLD_0125_EASY.tar.bz2 || exit 1
   tar -xjf ICON_GLOBAL2WORLD_0125_EASY.tar.bz2 || exit 1
   grid=$(find ${ICONCDO} -type f -name 'target_grid*.txt' | head -1)
   weights=$(find ${ICONCDO} -type f -name 'weights*.nc' | head -1)
   if [ -z "${grid}" ] || [ -z "${weights}" ]
   then
      echo -e "${RED}==>${NC} target_grid*.txt or weights*.nc not found in the tarball:"
      find ${ICONCDO} -type f
      exit 1
   fi
   ln -sf ${grid} target_grid.txt
   ln -sf ${weights} weights.nc
   rm -f ICON_GLOBAL2WORLD_0125_EASY.tar.bz2
   cd - > /dev/null
fi


# Lista de arquivos:----------------------------------------------------
# Campos com varios niveis de pressao/solo: nomes tirados da listagem da pasta no DWD
listing () {
   wget -qO- ${BASEURL}/${1}/ | grep -o "icon_global_icosahedral_${2}_${YYYYMMDDHHi}_[0-9]*_[0-9]*_${3}\.grib2\.bz2" | sort -u
}

if ! wget -qO- ${BASEURL}/ps/ | grep -q "single-level_${YYYYMMDDHHi}_000_PS"
then
   echo -e "${RED}==>${NC} ICON run ${YYYYMMDDHHi} not found at ${BASEURL}"
   echo -e "${RED}==>${NC} DWD opendata keeps only the last ~24 h of runs (and a run appears ~3-4 h after its start)."
   exit 1
fi

if [[ ${VCOORD} == "model" ]]
then
   # HHL (alturas das 121 meias-camadas), uma vez: nao muda entre rodadas
   if [ $(ls ${HHLDIR}/*_HHL.grib2.bz2 2>/dev/null | wc -l) -lt 121 ]
   then
      echo -e "${GREEN}==>${NC} Downloading ICON HHL (model level heights) to ${HHLDIR}...\n"
      mkdir -p ${HHLDIR}
      for k in $(seq 1 121); do
         echo "${BASEURL}/hhl/icon_global_icosahedral_time-invariant_${YYYYMMDDHHi}_${k}_HHL.grib2.bz2"
      done | xargs -P ${NPROC} -n 1 wget -q -c -P ${HHLDIR}
      if [ $(ls ${HHLDIR}/*_HHL.grib2.bz2 2>/dev/null | wc -l) -lt 121 ]
      then
         echo -e "${RED}==>${NC} HHL download incomplete in ${HHLDIR}. Run again to resume."
         exit 1
      fi
   fi

   # Topo do MONAN (m acima do nivel do mar): ICON_ZTOP ou config_ztop do namelist do init_atmosphere
   ZTOP=${ICON_ZTOP:-$(nml_get ${SCRIPTS}/namelists/namelist.init_atmosphere.TEMPLATE config_ztop)}
   if [ -z "${ZTOP}" ]
   then
      echo -e "${RED}==>${NC} config_ztop not found in ${SCRIPTS}/namelists/namelist.init_atmosphere.TEMPLATE (run 1.install_monan.bash or set ICON_ZTOP)."
      exit 1
   fi

   # Niveis do modelo usados nesta rodada
   if [ ! -s ${OUT}/model_levels.txt ]
   then
      echo -e "${GREEN}==>${NC} Selecting ICON model levels (icon_levels.py, ztop = ${ZTOP} m)...\n"
      ${PYTHON} ${SCRIPTS}/icon_levels.py --hhl-dir ${HHLDIR} --ztop ${ZTOP} \
         --zfull ${ICON_ZFULL:-16000} --thin ${ICON_THIN:-2} > ${OUT}/model_levels.txt
      if [ $? -ne 0 ] || [ ! -s ${OUT}/model_levels.txt ]
      then
         rm -f ${OUT}/model_levels.txt
         exit 1
      fi
   fi
   MLEVELS=$(cat ${OUT}/model_levels.txt)
   echo -e "\nICON model levels ($(echo ${MLEVELS} | wc -w)): ${MLEVELS}\n"
fi

urls=${OUT}/urls.txt; rm -f ${urls}
for item in ${TI}; do
   echo "${BASEURL}/${item%%:*}/icon_global_icosahedral_time-invariant_${YYYYMMDDHHi}_${item##*:}.grib2.bz2" >> ${urls}
done
if [[ ${VCOORD} == "model" ]]
then
   for ((hour=0; hour<=FCST; hour+=dt)); do
      fff=$(printf "%03d" ${hour})
      for item in ${ML}; do
         for k in ${MLEVELS}; do
            echo "${BASEURL}/${item%%:*}/icon_global_icosahedral_model-level_${YYYYMMDDHHi}_${fff}_${k}_${item##*:}.grib2.bz2" >> ${urls}
         done
      done
   done
else
   for item in ${PL}; do
      for f in $(listing ${item%%:*} pressure-level ${item##*:}); do
         fff=$(echo ${f} | awk -F_ '{print $6}')
         if [ $((10#${fff} % dt)) -eq 0 ] && [ $((10#${fff})) -le ${FCST} ]; then echo "${BASEURL}/${item%%:*}/${f}" >> ${urls}; fi
      done
   done
fi
for item in ${SOIL0}; do
   for f in $(listing ${item%%:*} soil-level ${item##*:} | grep "_${YYYYMMDDHHi}_000_"); do
      echo "${BASEURL}/${item%%:*}/${f}" >> ${urls}
   done
done
for ((hour=0; hour<=FCST; hour+=dt)); do
   fff=$(printf "%03d" ${hour})
   vars=${SL}; [ ${hour} -eq 0 ] && vars="${SL} ${SL0}"
   for item in ${vars}; do
      echo "${BASEURL}/${item%%:*}/icon_global_icosahedral_single-level_${YYYYMMDDHHi}_${fff}_${item##*:}.grib2.bz2" >> ${urls}
   done
done
#----------------------------------------------------------------------

echo -e "${GREEN}==>${NC} Downloading $(wc -l < ${urls}) ICON files to ${OUT} (${NPROC} in parallel)...\n"
xargs -P ${NPROC} -n 1 wget -q -c -P ${OUT} < ${urls}

# Confere se veio tudo (horarios que ainda nao sairam no DWD tambem aparecem aqui)
nmiss=0
while read url; do
   if [ ! -s ${OUT}/$(basename ${url}) ]; then echo "Missing: ${url}"; nmiss=$((nmiss + 1)); fi
done < ${urls}
nlev=$(grep -c "_000_[0-9]*_T\.grib2" ${urls})
if [ ${nmiss} -ne 0 ] || [ ${nlev} -eq 0 ]
then
   echo -e "\n${RED}==>${NC} ${nmiss} files missing (${VCOORD} levels of T at +000 h: ${nlev})."
   echo -e "${RED}==>${NC} If the run is still being published, wait and run again (downloads resume).\n"
   exit 1
fi

rm -f ${urls}
echo "${FCST} ${dt} ${VCOORD}" > ${OUT}/download_ok
echo -e "\n${GREEN}==>${NC} ICON ${YYYYMMDDHHi} (+${FCST} h) downloaded: $(du -sh ${OUT} | cut -f1) in ${OUT}\n"
