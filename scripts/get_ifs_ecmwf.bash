#!/bin/bash
umask 022
#-----------------------------------------------------------------------------#
# !SCRIPT: get_ifs_ecmwf                                          [ICON/IFS]
#
# !DESCRIPTION:
#     Baixa o IFS (HRES) do ECMWF open data (GRIB2 em lat-lon regular) usado
#     com EXP=IFS. Le o .index de cada arquivo do ECMWF e baixa so os campos
#     necessarios (pedidos HTTP por faixa de bytes):
#
#        o ifs_pl.FFF.grib2  : t, u, v, r, gh em 14 niveis de pressao (1000-10 hPa)
#        o ifs_sfc.FFF.grib2 : sp, msl, 2t, 2d, 10u, 10v, skt
#        o ifs_sfc0.grib2    : z, lsm, sd, rsn, sithick (so a hora inicial)
#        o ifs_sol.grib2     : sot, vsw nas 4 camadas de solo (so a hora inicial)
#
#     em ${DATAIN}/IFS/YYYYMMDDHH/ (FFF = hora de previsao).
#
#     Variaveis (setenv.bash):
#     IFS_RESOL  = 0p1 (padrao), 0p25, ou 0p4-beta (datas antes de fev/2024)
#     IFS_SOURCE = ecmwf (padrao; o portal guarda so os ~3 ultimos dias)
#                  ou aws (arquivo do open data desde 2023)
#     IFS_NPROC  = arquivos baixados em paralelo (padrao 8)
#
#     O stream e descoberto sozinho: "oper" (00/12 UTC, e 06/18 UTC nas datas
#     recentes) ou "scda" (06/18 UTC em datas antigas). Arquivos ja baixados
#     nao sao pedidos de novo (rodar outra vez e seguro e nao usa a rede).
#
# !CALLING SEQUENCE:
#     ./get_ifs_ecmwf.bash LABELI FCST      (chamado pelo 2.pre_processing.bash)
#-----------------------------------------------------------------------------#

if [ $# -ne 2 ]
then
   echo ""
   echo "Instructions: execute the command below"
   echo ""
   echo "${0} LABELI FCST"
   echo ""
   echo "LABELI      :: IFS run (YYYYMMDDHH), 00, 06, 12 or 18 UTC, e.g., $(date -u +%Y%m%d)00"
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
DATAIN=${DIRHOMED}/datain;              mkdir -p ${DATAIN}
#----------------------------------------------------------------------

# Input variables:--------------------------------------
YYYYMMDDHHi=${1}; #YYYYMMDDHHi=2026110500
FCST=${2};        #FCST=24
#-------------------------------------------------------

# Local variables--------------------------------------
hhi=${YYYYMMDDHHi:8:2}
OUT=${DATAIN}/IFS/${YYYYMMDDHHi};       mkdir -p ${OUT}
# O download so usa a biblioteca padrao do Python: qualquer python3 serve
PYTHON=${ICON_PYTHON:-$(command -v python3)}
#-------------------------------------------------------

# Checagens rapidas (antes de qualquer download)--------
if [[ ! ${hhi} =~ ^(00|06|12|18)$ ]]
then
   echo -e "${RED}==>${NC} IFS: LABELI must be a 00, 06, 12 or 18 UTC run (got ${YYYYMMDDHHi})."
   exit 1
fi
if [[ ${MODERUN} == "R" ]]
then
   # Passos do IFS open data: de 3 em 3 h ate +144 h; depois de 6 em 6 h (so 00/12 UTC, ate +360 h)
   if [ $((LBCINT % 10800)) -ne 0 ]
   then
      echo -e "${RED}==>${NC} IFS: LBCINT (${LBCINT} s, setenv.bash) must be a multiple of 10800 s (3 h)."
      exit 1
   fi
   dt=$((LBCINT / 3600))
   if [ ${FCST} -gt 144 ] && [ $((dt % 6)) -ne 0 ]
   then
      echo -e "${RED}==>${NC} IFS has 6-hourly output after +144 h: use LBCINT multiple of 21600 s or FCST <= 144."
      exit 1
   fi
   if [[ ${hhi} == "06" || ${hhi} == "18" ]] && [ ${FCST} -gt 144 ]
   then
      echo -e "${RED}==>${NC} IFS 06/18 UTC runs go only up to +144 h (+90 h in older dates)."
      exit 1
   fi
else
   FCST=0; dt=3   # modo global: so a condicao inicial
fi
age=$(( ( $(date -u +%s) - $(date -u -d "${YYYYMMDDHHi:0:8} ${hhi}:00" +%s) ) / 3600 ))
if [ ${age} -gt 72 ] && [[ ${IFS_SOURCE:-ecmwf} == "ecmwf" ]]
then
   echo -e "${YELLOW}==>${NC} Warning: IFS ${YYYYMMDDHHi} is ${age} h old; data.ecmwf.int keeps only ~3 days."
   echo -e "${YELLOW}==>${NC} If it fails, use: export IFS_SOURCE=aws\n"
fi
#-------------------------------------------------------

echo -e "${GREEN}==>${NC} Downloading IFS ${YYYYMMDDHHi} (+${FCST} h, every ${dt} h, ${IFS_RESOL:-0p1}, ${IFS_SOURCE:-ecmwf}, ${IFS_NPROC:-8} workers) to ${OUT} ...\n"

${PYTHON} - ${YYYYMMDDHHi} ${FCST} ${dt} ${OUT} ${IFS_SOURCE:-ecmwf} ${IFS_RESOL:-0p1} ${IFS_NPROC:-8} << 'EOF' || exit 1
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

run, fcst, dt, out, source, resol = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
nproc = max(1, int(sys.argv[7]))
roots = {"ecmwf": "https://data.ecmwf.int/forecasts",
         "aws": "https://ecmwf-forecasts.s3.eu-central-1.amazonaws.com"}
if source not in roots:
    sys.exit(f"IFS_SOURCE must be one of {list(roots)}")
if resol not in ("0p1", "0p25", "0p4-beta"):
    sys.exit("IFS_RESOL must be 0p1, 0p25 or 0p4-beta")
hh = run[8:10]

PL = {"t", "u", "v", "r", "gh"}
PLEVS = {"1000", "925", "850", "700", "600", "500", "400", "300", "250", "200", "150", "100", "50", "10"}
SFC = {"sp", "msl", "2t", "2d", "10u", "10v", "skt"}
SFC0 = {"z", "lsm", "sd", "rsn", "sithick"}
SFC0_REQUIRED = {"z", "lsm", "sd"}
SOL = {"sot", "vsw"}
MAXCHUNK = 64 * 1024 * 1024


class NotFound(Exception):
    pass


def url(step, kind, stream):
    # 0p1: arquivos -pl e -sfc separados; 0p25 e 0p4-beta: um arquivo so
    suffix = f"-{kind}" if kind else ""
    return f"{roots[source]}/{run[:8]}/{hh}z/ifs/{resol}/{stream}/{run}0000-{step}h-{stream}-fc{suffix}"


def get(u, headers=None):
    for attempt in range(5):
        try:
            with urllib.request.urlopen(urllib.request.Request(u, headers=headers or {}), timeout=120) as r:
                return r.read()
        except urllib.error.HTTPError as err:
            if err.code in (403, 404):
                raise NotFound(u) from err
            if attempt == 4:
                sys.exit(f"Failed to download {u}: {err}")
        except Exception as err:  # noqa: BLE001 (rede instavel: tenta de novo)
            if attempt == 4:
                sys.exit(f"Failed to download {u}: {err}")
        time.sleep(10 * (attempt + 1))


pl_kind = "pl" if resol == "0p1" else ""
sfc_kind = "sfc" if resol == "0p1" else ""

# Stream: "oper" (00/12 UTC e, nas datas recentes, 06/18 UTC) ou "scda" (06/18 UTC em datas antigas).
# Descoberto so quando algum arquivo precisa ser baixado (se ja estiver tudo em disco, nao usa a rede).
_stream = []
_lock = threading.Lock()
def stream_name():
    with _lock:
        if not _stream:
            for cand in ("oper", "scda") if hh in ("06", "18") else ("oper",):
                try:
                    get(url(0, sfc_kind, cand) + ".index")
                    _stream.append(cand)
                    break
                except NotFound:
                    pass
            if not _stream:
                sys.exit(f"IFS run {run} ({resol}) not found at {roots[source]}.\n"
                         f"data.ecmwf.int keeps only ~3 days (older runs: IFS_SOURCE=aws); 0p1 exists only "
                         f"for recent dates (try IFS_RESOL=0p25); before Feb/2024 use IFS_RESOL=0p4-beta.")
            print(f"IFS stream: {_stream[0]}", flush=True)
        return _stream[0]


index_cache = {}
def records(step, kind):
    key = (step, kind)
    if key not in index_cache:
        u = url(step, kind, stream_name())
        try:
            lines = get(u + ".index").decode().splitlines()
        except NotFound:
            sys.exit(f"Step +{step} h not found ({u}.index): not published yet, "
                     f"or beyond the forecast range of this run.")
        index_cache[key] = [json.loads(line) for line in lines if line.strip()]
    return index_cache[key]


def download(name, parts, check):
    """Junta em out/name os campos escolhidos de cada (passo, arquivo)."""
    target = os.path.join(out, name)
    if os.path.exists(target):
        print(f"{name} already exists")
        return
    got = []
    with open(target + ".part", "wb") as f:
        for step, kind, select in parts:
            # Campos vizinhos no arquivo do ECMWF viram um pedido so (ate MAXCHUNK bytes)
            ranges = []
            for rec in sorted((r for r in records(step, kind) if select(r)), key=lambda r: r["_offset"]):
                off, length = rec["_offset"], rec["_length"]
                if ranges and ranges[-1][1] == off and off + length - ranges[-1][0] <= MAXCHUNK:
                    ranges[-1][1] = off + length
                else:
                    ranges.append([off, off + length])
                got.append((rec["param"], rec.get("levelist")))
            for start, end in ranges:
                f.write(get(url(step, kind, stream_name()) + ".grib2", {"Range": f"bytes={start}-{end - 1}"}))
    check(name, got)
    os.rename(target + ".part", target)
    print(f"{name}: {len(got)} fields", flush=True)


def need(expected):
    def check(name, got):
        missing = sorted(expected - set(got))
        if missing:
            sys.exit(f"{name}: fields missing in the ECMWF files: {missing}")
    return check


jobs = [
    ("ifs_sfc0.grib2", [(0, sfc_kind, lambda r: r["levtype"] == "sfc" and r["param"] in SFC0)],
     need({(p, None) for p in SFC0_REQUIRED})),
    ("ifs_sol.grib2", [(0, sfc_kind, lambda r: r["levtype"] == "sol" and r["param"] in SOL)],
     need({(p, str(k)) for p in SOL for k in range(1, 5)})),
]
for step in range(0, fcst + 1, dt):
    jobs.append((f"ifs_pl.{step:03d}.grib2",
                 [(step, pl_kind, lambda r: r["levtype"] == "pl" and r["param"] in PL and r.get("levelist") in PLEVS)],
                 need({(p, lev) for p in PL for lev in PLEVS})))
    jobs.append((f"ifs_sfc.{step:03d}.grib2",
                 [(step, sfc_kind, lambda r: r["levtype"] == "sfc" and r["param"] in SFC)],
                 need({(p, None) for p in SFC})))

# Um arquivo de saida por worker (IFS_NPROC); o primeiro erro interrompe tudo
print(f"{len(jobs)} files with {nproc} workers", flush=True)
with ThreadPoolExecutor(nproc) as pool:
    futures = [pool.submit(download, *job) for job in jobs]
    try:
        for fut in as_completed(futures):
            fut.result()
    except BaseException:
        for fut in futures:
            fut.cancel()
        raise
EOF

echo -e "\n${GREEN}==>${NC} IFS ${YYYYMMDDHHi} (+${FCST} h) downloaded: $(du -sh ${OUT} | cut -f1) in ${OUT}\n"
