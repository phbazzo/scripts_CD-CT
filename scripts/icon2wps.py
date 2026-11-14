#!/usr/bin/env python3
#-----------------------------------------------------------------------------#
# !SCRIPT: icon2wps.py                                           [ICON/IFS]
#
# !DESCRIPTION:
#     Converte o ICON global do DWD (malha icosaedrica, GRIB2 do opendata) em
#     arquivos intermediarios do WPS (<PREFIX>:YYYY-MM-DD_HH), lidos direto pelo
#     init_atmosphere do MONAN (config_met_prefix = '<PREFIX>').
#
#     Faz o papel do ungrib para o ICON:
#        o bunzip2 + cdo remap (pesos do DWD) para lat-lon 0.125 + recorte
#        o renomeia os campos para os nomes do WPS (TT, UU, VV, RH, GHT, ...)
#        o atmosfera nos niveis do modelo (--vcoord model): T, U, V, QV e P do
#          ICON, com GHT do HHL e o campo 3D PRESSURE; xlvl = numero do nivel
#          (1 = topo), como nos niveis de modelo do ECMWF
#        o ou nos 18 niveis de pressao do opendata (--vcoord pressure)
#        o calcula a umidade especifica (SPECHUMD) e a UR em 2 m
#        o umidade do solo: kg m-2 por camada -> m3 m-3
#        o reagrupa o solo do ICON nas camadas do GFS (0-10/10-40/40-100/100-200 cm)
#        o LANDSEA = FR_LAND >= 0.5
#
#     As profundidades do solo e os niveis de pressao vem das chaves GRIB2 de
#     cada arquivo (os rotulos dos nomes do DWD misturam mm e cm no T_SO).
#
#     Requer: numpy, eccodes (python) e cdo.
#
# !CALLING SEQUENCE:
#     icon2wps.py --indir DIR --run YYYYMMDDHH --fcst 48 --step 3 \
#                 --grid target_grid.txt --weights weights.nc --outdir DIR
#
#-----------------------------------------------------------------------------#

import argparse
import datetime as dt
import glob
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

import eccodes
import numpy as np

G = 9.80665
RD = 287.04

# Fonte gravada no cabecalho de cada campo do intermediario (so informativo; o ifs2wps.py troca)
MAP_SOURCE = "DWD ICON"

# Niveis de pressao: variavel do ICON -> nome no WPS
PL_VARS = {"T": "TT", "U": "UU", "V": "VV", "RELHUM": "RH", "FI": "GHT"}
# Niveis do modelo (QV = umidade especifica, P = pressao)
ML_VARS = ["T", "U", "V", "QV", "P"]
# Superficie, em todos os horarios
SL_VARS = ["PS", "PMSL", "T_2M", "TD_2M", "U_10M", "V_10M", "T_G"]
# Superficie e solo, so na hora inicial (as LBCs nao usam)
SL0_VARS = ["FR_ICE", "W_SNOW", "H_SNOW"]
SOIL_VARS = ["T_SO", "W_SO"]
# Invariantes no tempo
TI_VARS = ["HSURF", "FR_LAND"]

# Camadas de solo de destino (m)
SOIL_LAYERS = [(0.0, 0.1), (0.1, 0.4), (0.4, 1.0), (1.0, 2.0)]


def parse_args():
    p = argparse.ArgumentParser(description="ICON (DWD opendata) -> intermediarios do WPS")
    p.add_argument("--indir", required=True, help="pasta com os *.grib2.bz2 da rodada")
    p.add_argument("--run", required=True, help="rodada do ICON (YYYYMMDDHH)")
    p.add_argument("--fcst", type=int, default=0, help="horas de previsao (0 = so a CI)")
    p.add_argument("--step", type=int, default=3, help="intervalo entre horarios (h)")
    p.add_argument("--grid", required=True, help="grade de destino do CDO (target_grid*.txt)")
    p.add_argument("--weights", required=True, help="pesos de remapeamento do CDO (weights*.nc)")
    p.add_argument("--box", default="global",
                   help="recorte lon1,lon2,lat1,lat2 (sellonlatbox) ou 'global'")
    p.add_argument("--vcoord", choices=["model", "pressure"], default="model",
                   help="atmosfera nos niveis do modelo ou nos niveis de pressao")
    p.add_argument("--hhl-dir", help="pasta com os *_HHL.grib2.bz2 (obrigatoria com --vcoord model)")
    p.add_argument("--prefix", default="ICON", help="prefixo dos intermediarios")
    p.add_argument("--cdo", default="cdo", help="executavel do cdo")
    p.add_argument("--nproc", type=int, default=8, help="arquivos processados em paralelo")
    p.add_argument("--outdir", required=True, help="pasta de saida")
    return p.parse_args()


#
# Leitura e remapeamento
#

def fixed_surface(gid, which):
    """Valor (unidades SI) da superficie First/Second de uma mensagem GRIB2, ou None."""
    key = f"scaledValueOf{which}FixedSurface"
    if eccodes.codes_is_missing(gid, key):
        return None
    value = eccodes.codes_get(gid, key)
    fkey = f"scaleFactorOf{which}FixedSurface"
    factor = 0 if eccodes.codes_is_missing(gid, fkey) else eccodes.codes_get(gid, fkey)
    return value * 10.0 ** (-factor)


def read_level(path):
    """(topo, base) do nivel do primeiro registro: Pa nos niveis de pressao, m no solo."""
    with open(path, "rb") as f:
        gid = eccodes.codes_grib_new_from_file(f)
        try:
            return fixed_surface(gid, "First"), fixed_surface(gid, "Second")
        finally:
            eccodes.codes_release(gid)


def read_latlon(path):
    """Campo lat-lon (sul -> norte) e sua geometria (lat1, lon1, dlat, dlon, nj, ni)."""
    with open(path, "rb") as f:
        gid = eccodes.codes_grib_new_from_file(f)
        try:
            ni = eccodes.codes_get(gid, "Ni")
            nj = eccodes.codes_get(gid, "Nj")
            lat1 = eccodes.codes_get(gid, "latitudeOfFirstGridPointInDegrees")
            lon1 = eccodes.codes_get(gid, "longitudeOfFirstGridPointInDegrees")
            dlat = eccodes.codes_get(gid, "jDirectionIncrementInDegrees")
            dlon = eccodes.codes_get(gid, "iDirectionIncrementInDegrees")
            south_first = eccodes.codes_get(gid, "jScansPositively") == 1
            values = eccodes.codes_get_values(gid).reshape(nj, ni)
            if eccodes.codes_get(gid, "bitmapPresent"):
                values = np.where(values == eccodes.codes_get(gid, "missingValue"), np.nan, values)
        finally:
            eccodes.codes_release(gid)
    if not south_first:
        values = values[::-1]
        lat1 = lat1 - (nj - 1) * dlat
    if lon1 > 180.0:
        lon1 -= 360.0
    return values.astype(np.float32), (round(lat1, 6), round(lon1, 6), dlat, dlon, nj, ni)


def regrid(path, args, tmpdir):
    """bunzip2 + cdo remap/recorte de um arquivo do ICON -> (arquivo nativo, arquivo lat-lon).

    Roda nas threads; a leitura com eccodes fica na thread principal."""
    td = tempfile.mkdtemp(dir=tmpdir)
    native = os.path.join(td, "native.grib2")
    latlon = os.path.join(td, "latlon.grib2")
    with open(native, "wb") as fo:
        subprocess.run(["bunzip2", "-c", path], stdout=fo, check=True)
    remap = f"remap,{args.grid},{args.weights}"
    if args.box == "global":
        ops = [remap]
    else:
        ops = [f"sellonlatbox,{args.box}", "-" + remap]
    # cdo com caminho completo (ex.: do conda) roda sem o LD_LIBRARY_PATH do
    # setenv.bash, para usar as proprias bibliotecas e nao as do compilador do modelo (em alguns sistemas
    # Cray, o cdo de modulo falha com "CCE OpenMP fatal error: omp_set_num_threads ...")
    env = None
    if os.path.isabs(args.cdo):
        env = {k: v for k, v in os.environ.items() if k != "LD_LIBRARY_PATH"}
    run = subprocess.run([args.cdo, "-s", "-f", "grb2", "-b", "F32", *ops, native, latlon],
                         env=env, stderr=subprocess.PIPE, text=True)
    # O ecCodes reclama da secao local (section2Padding) dos GRIB do DWD ao
    # regravar; e inofensivo, entao so as outras mensagens vao para o log
    msgs = [m for m in run.stderr.splitlines() if "section2Padding" not in m]
    if msgs:
        print("\n".join(msgs), file=sys.stderr, flush=True)
    if run.returncode != 0:
        raise subprocess.CalledProcessError(run.returncode, run.args)
    return native, latlon


def file_name(run, kind, var, fff=None):
    if kind == "time-invariant":
        return f"icon_global_icosahedral_time-invariant_{run}_{var}.grib2.bz2"
    if kind == "single-level":
        return f"icon_global_icosahedral_single-level_{run}_{fff}_{var}.grib2.bz2"
    return f"icon_global_icosahedral_{kind}_{run}_{fff}_*_{var}.grib2.bz2"


def level_of(path, native):
    """Nivel de um arquivo: numero do nivel (niveis do modelo e HHL) ou chaves do GRIB."""
    parts = os.path.basename(path).split("_")
    if parts[3] == "model-level":
        return int(parts[6]), None
    if parts[-1].startswith("HHL."):
        return int(parts[5]), None
    return read_level(native)


def find_jobs(args, fff):
    """Lista (variavel, arquivo) de um horario; aborta se faltar algum arquivo."""
    if args.vcoord == "model":
        groups = [("model-level", ML_VARS), ("single-level", SL_VARS)]
    else:
        groups = [("pressure-level", list(PL_VARS)), ("single-level", SL_VARS)]
    if fff == "000":
        groups += [("single-level", SL0_VARS), ("soil-level", SOIL_VARS)]
    jobs, missing = [], []
    for kind, variables in groups:
        for var in variables:
            pattern = os.path.join(args.indir, file_name(args.run, kind, var, fff))
            files = sorted(glob.glob(pattern))
            if not files:
                missing.append(pattern)
            jobs += [(var, f) for f in files]
    if missing:
        sys.exit("Arquivos do ICON ausentes:\n  " + "\n  ".join(missing))
    return jobs


def process(pool, args, jobs, tmpdir):
    """Remapeia os arquivos em paralelo -> {variavel: [(nivel, campo), ...]}, geometria."""
    out, geo0 = {}, None
    results = pool.map(lambda job: regrid(job[1], args, tmpdir), jobs)
    for (var, path), (native, latlon) in zip(jobs, results):
        level = level_of(path, native)
        field, geo = read_latlon(latlon)
        shutil.rmtree(os.path.dirname(native))
        if geo0 is None:
            geo0 = geo
        elif geo != geo0:
            sys.exit(f"Grade diferente em {path}: {geo} != {geo0}")
        out.setdefault(var, []).append((level, field))
    return out, geo0


#
# Conversoes
#

def esat(t):
    """Pressao de vapor de saturacao (Pa) sobre agua, Bolton (1980)."""
    return 611.2 * np.exp(17.67 * (t - 273.15) / (t - 29.65))


def spechum(e, p):
    return np.clip(0.622 * e / (p - 0.378 * e), 0.0, None)


def fill_underground(cube, plev):
    """Preenche pontos sem dado (abaixo do relevo) a partir do nivel de cima."""
    t, fi = cube["T"], cube["FI"]
    for k in range(1, len(plev)):
        ratio = plev[k] / plev[k - 1]
        miss = np.isnan(t[k])
        t[k][miss] = t[k - 1][miss] * ratio ** (RD * 0.0065 / G)
        miss = np.isnan(fi[k])
        tm = 0.5 * (t[k] + t[k - 1])
        fi[k][miss] = fi[k - 1][miss] - RD * tm[miss] * np.log(ratio)
        for var in ("U", "V", "RELHUM"):
            miss = np.isnan(cube[var][k])
            cube[var][k][miss] = cube[var][k - 1][miss]


def pressure_fields(res):
    """Campos 3D (niveis do topo para a base) -> lista de (nome, unidade, descricao, nivel, campo)."""
    plev = sorted(level[0] for level, _ in res["T"])
    cube = {}
    for var in PL_VARS:
        by_p = {level[0]: field for level, field in res[var]}
        if sorted(by_p) != plev:
            sys.exit(f"{var}: niveis de pressao diferentes dos de T")
        cube[var] = np.stack([by_p[p] for p in plev])
    fill_underground(cube, plev)
    for var, data in cube.items():
        if np.isnan(data).any():
            sys.exit(f"{var}: pontos sem dado mesmo depois do preenchimento")

    fields = []
    for k, p in enumerate(plev):
        e = np.clip(cube["RELHUM"][k], 0.0, 100.0) / 100.0 * esat(cube["T"][k])
        fields += [
            ("TT", "K", "Temperature", p, cube["T"][k]),
            ("UU", "m s-1", "U", p, cube["U"][k]),
            ("VV", "m s-1", "V", p, cube["V"][k]),
            ("RH", "%", "Relative Humidity", p, cube["RELHUM"][k]),
            ("SPECHUMD", "kg kg-1", "Specific Humidity", p, spechum(e, p)),
            ("GHT", "m", "Height", p, cube["FI"][k] / G),
        ]
    return fields, len(plev)


def model_fields(res, hhl):
    """Campos 3D nos niveis do modelo (xlvl = numero do nivel do ICON, 1 = topo).

    O init_atmosphere usa o campo 3D PRESSURE (em vez do xlvl) e o GHT, que vem
    da media das meias-camadas HHL acima e abaixo de cada nivel."""
    levels = sorted(level[0] for level, _ in res["T"])
    cube = {}
    for var in ML_VARS:
        by_k = {level[0]: field for level, field in res[var]}
        if sorted(by_k) != levels:
            sys.exit(f"{var}: niveis do modelo diferentes dos de T")
        cube[var] = by_k

    fields = []
    for k in levels:
        t, p = cube["T"][k], cube["P"][k]
        q = np.clip(cube["QV"][k], 0.0, None)
        e = q * p / (0.622 + 0.378 * q)
        xlvl = float(k)
        fields += [
            ("TT", "K", "Temperature", xlvl, t),
            ("UU", "m s-1", "U", xlvl, cube["U"][k]),
            ("VV", "m s-1", "V", xlvl, cube["V"][k]),
            ("SPECHUMD", "kg kg-1", "Specific Humidity", xlvl, q),
            ("RH", "%", "Relative Humidity", xlvl, np.clip(100.0 * e / esat(t), 0.0, 100.0)),
            ("PRESSURE", "Pa", "Pressure", xlvl, p),
            ("GHT", "m", "Height", xlvl, 0.5 * (hhl[k] + hhl[k + 1])),
        ]
    for name, _, _, xlvl, data in fields:
        if np.isnan(data).any():
            sys.exit(f"{name} no nivel {xlvl:.0f}: campo com pontos sem dado")
    return fields, len(levels)


def soil_fields(res, skintemp):
    """Solo do ICON -> SM/ST nas camadas do GFS."""
    # Umidade: kg m-2 por camada -> m3 m-3, media ponderada pela sobreposicao
    layers = [(level, field) for level, field in res["W_SO"]]
    if any(bot is None for (_, bot), _ in layers):
        sys.exit("W_SO sem a base da camada (Second fixed surface) no GRIB")
    fields = []
    for top, bot in SOIL_LAYERS:
        acc = np.zeros_like(skintemp)
        covered = 0.0
        for (ltop, lbot), w in layers:
            overlap = min(bot, lbot) - max(top, ltop)
            if overlap > 0:
                acc += np.nan_to_num(w) / (1000.0 * (lbot - ltop)) * overlap
                covered += overlap
        if abs(covered - (bot - top)) > 1e-6:
            sys.exit(f"Camadas do W_SO nao cobrem {top}-{bot} m")
        name = f"SM{round(top * 100):03d}{round(bot * 100):03d}"
        fields.append((name, "m3 m-3", "Soil moisture", 200100.0, acc / (bot - top)))

    # Temperatura: interpolacao linear no meio de cada camada
    levels = sorted((level[0], field) for level, field in res["T_SO"])
    depths = np.array([d for d, _ in levels])
    tso = np.stack([f for _, f in levels])
    for top, bot in SOIL_LAYERS:
        z = 0.5 * (top + bot)
        k = int(np.searchsorted(depths, z)) - 1
        if k < 0 or k + 1 >= len(depths):
            sys.exit(f"T_SO nao cobre a profundidade {z} m (niveis: {depths})")
        w = (z - depths[k]) / (depths[k + 1] - depths[k])
        layer = (1.0 - w) * tso[k] + w * tso[k + 1]
        name = f"ST{round(top * 100):03d}{round(bot * 100):03d}"
        fields.append((name, "K", "Soil temperature", 200100.0,
                       np.where(np.isnan(layer), skintemp, layer)))
    return fields


def surface_fields(res, ti, initial):
    one = {var: res[var][0][1] for var in SL_VARS + (SL0_VARS if initial else [])}
    ps, t2, td2 = one["PS"], one["T_2M"], one["TD_2M"]
    e = esat(td2)
    fields = [
        ("PSFC", "Pa", "Surface Pressure", 200100.0, ps),
        ("PMSL", "Pa", "Sea-level Pressure", 201300.0, one["PMSL"]),
        ("TT", "K", "Temperature", 200100.0, t2),
        ("RH", "%", "Relative Humidity", 200100.0, np.clip(100.0 * e / esat(t2), 0.0, 100.0)),
        ("SPECHUMD", "kg kg-1", "Specific Humidity", 200100.0, spechum(e, ps)),
        ("UU", "m s-1", "U", 200100.0, one["U_10M"]),
        ("VV", "m s-1", "V", 200100.0, one["V_10M"]),
        ("SKINTEMP", "K", "Skin temperature", 200100.0, one["T_G"]),
        ("SOILHGT", "m", "Terrain field of source analysis", 200100.0, ti["HSURF"]),
        ("LANDSEA", "proprtn", "Land/Sea flag (1=land, 0=sea)", 200100.0, ti["LANDSEA"]),
    ]
    if initial:
        fields += [
            ("SEAICE", "proprtn", "Ice flag", 200100.0, np.nan_to_num(one["FR_ICE"])),
            ("SNOW", "kg m-2", "Water equivalent snow depth", 200100.0, np.nan_to_num(one["W_SNOW"])),
            ("SNOWH", "m", "Physical Snow Depth", 200100.0, np.nan_to_num(one["H_SNOW"])),
        ]
        fields += soil_fields(res, one["T_G"])
    for name, _, _, _, data in fields:
        if np.isnan(data).any():
            sys.exit(f"{name}: campo com pontos sem dado")
    return fields


#
# Escrita do intermediario do WPS
#

def write_record(f, payload):
    marker = struct.pack(">i", len(payload))
    f.write(marker + payload + marker)


def write_field(f, hdate, geo, field, units, desc, xlvl, slab):
    lat1, lon1, dlat, dlon, nj, ni = geo
    write_record(f, struct.pack(">i", 5))
    write_record(f, struct.pack(">24sf32s9s25s46sf3i",
                                hdate.ljust(24).encode(), 0.0, MAP_SOURCE.ljust(32).encode(),
                                field.ljust(9).encode(), units.ljust(25).encode(),
                                desc.ljust(46).encode(), xlvl, ni, nj, 0))
    write_record(f, struct.pack(">8s5f", b"SWCORNER", lat1, lon1, dlat, dlon, 6371.229))
    write_record(f, struct.pack(">i", 0))   # is_wind_grid_rel = .false.
    write_record(f, np.ascontiguousarray(slab, dtype=">f4").tobytes())


def main():
    args = parse_args()
    run = dt.datetime.strptime(args.run, "%Y%m%d%H")
    os.makedirs(args.outdir, exist_ok=True)
    tmpdir = tempfile.mkdtemp(prefix="icon2wps_", dir=args.outdir)
    try:
        with ThreadPoolExecutor(args.nproc) as pool:
            jobs = [(v, os.path.join(args.indir, file_name(args.run, "time-invariant", v)))
                    for v in TI_VARS]
            missing = [path for _, path in jobs if not os.path.isfile(path)]

            # Niveis do modelo: os mesmos baixados para a hora inicial, mais as
            # meias-camadas HHL acima (k) e abaixo (k+1) de cada um
            if args.vcoord == "model":
                if not args.hhl_dir:
                    sys.exit("--hhl-dir e obrigatorio com --vcoord model")
                t0 = glob.glob(os.path.join(args.indir, file_name(args.run, "model-level", "T", "000")))
                levels = sorted(int(os.path.basename(f).split("_")[6]) for f in t0)
                if not levels:
                    sys.exit(f"Nenhum arquivo de T nos niveis do modelo em {args.indir}")
                for k in sorted({h for lev in levels for h in (lev, lev + 1)}):
                    pattern = os.path.join(args.hhl_dir,
                                           f"icon_global_icosahedral_time-invariant_*_{k}_HHL.grib2.bz2")
                    files = glob.glob(pattern)
                    if files:
                        jobs.append(("HHL", files[0]))
                    else:
                        missing.append(pattern)

            if missing:
                sys.exit("Arquivos do ICON ausentes:\n  " + "\n  ".join(missing))
            res, geo_ti = process(pool, args, jobs, tmpdir)
            ti = {"HSURF": np.nan_to_num(res["HSURF"][0][1]),
                  "LANDSEA": (np.nan_to_num(res["FR_LAND"][0][1]) >= 0.5).astype(np.float32)}
            hhl = {level[0]: field for level, field in res.get("HHL", [])}

            for hour in range(0, args.fcst + 1, args.step):
                fff = f"{hour:03d}"
                valid = run + dt.timedelta(hours=hour)
                hdate = f"{valid:%Y-%m-%d_%H}:00:00"
                jobs = find_jobs(args, fff)
                print(f"{hdate}: remapeando {len(jobs)} arquivos ...", flush=True)
                res, geo = process(pool, args, jobs, tmpdir)
                if geo != geo_ti:
                    sys.exit(f"Grade dos invariantes {geo_ti} != grade de {fff} {geo}")

                if args.vcoord == "model":
                    fields, nlev = model_fields(res, hhl)
                else:
                    fields, nlev = pressure_fields(res)
                fields += surface_fields(res, ti, initial=(hour == 0))

                out = os.path.join(args.outdir, f"{args.prefix}:{valid:%Y-%m-%d_%H}")
                with open(out, "wb") as f:
                    for name, units, desc, xlvl, data in fields:
                        write_field(f, hdate, geo, name, units, desc, xlvl, data)
                kind = "do modelo" if args.vcoord == "model" else "de pressao"
                print(f"   -> {out} ({len(fields)} campos, {nlev} niveis {kind}, "
                      f"grade {geo[5]}x{geo[4]})", flush=True)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
