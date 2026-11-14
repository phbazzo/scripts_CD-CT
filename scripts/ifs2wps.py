#!/usr/bin/env python3
#-----------------------------------------------------------------------------#
# !SCRIPT: ifs2wps.py                                            [ICON/IFS]
#
# !DESCRIPTION:
#     Converte o IFS (HRES) do ECMWF open data (GRIB2 em lat-lon regular,
#     baixado pelo get_ifs_ecmwf.bash) em arquivos intermediarios do WPS
#     (<PREFIX>:YYYY-MM-DD_HH), lidos direto pelo init_atmosphere do MONAN.
#
#     Arquivos: ifs_sfc0.grib2, ifs_sol.grib2 (hora inicial) e, para cada hora
#     FFF, ifs_pl.FFF.grib2 e ifs_sfc.FFF.grib2. Funciona com 0.1, 0.25 e 0.4 deg.
#
#     Os dados ja vem em lat-lon, entao nao ha remapeamento: so recorte. As
#     conversoes e a escrita sao as mesmas do icon2wps.py (importado daqui):
#        o 14 niveis de pressao (t, u, v, r, gh) -> TT, UU, VV, RH, SPECHUMD, GHT
#        o superficie (sp, msl, 2t, 2d, 10u, 10v, skt), orografia (z) e lsm
#        o solo do IFS (sot, vsw nas camadas 0-7, 7-28, 28-100, 100-289 cm)
#          reagrupado nas camadas do GFS, como no ICON
#        o neve (sd, rsn) e gelo marinho (sithick > 0)
#
#     Requer: numpy e eccodes (python), e o icon2wps.py na mesma pasta.
#
# !CALLING SEQUENCE:
#     ifs2wps.py --indir DIR --run YYYYMMDDHH --fcst 48 --step 3 --outdir DIR
#
#-----------------------------------------------------------------------------#

import argparse
import datetime as dt
import os
import sys

import eccodes
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import icon2wps as wps  # noqa: E402  (conversoes e escrita do intermediario)

# Niveis de pressao e superficie: shortName do IFS -> nome usado no icon2wps
PL_VARS = {"t": "T", "u": "U", "v": "V", "r": "RELHUM", "gh": "FI"}
SFC_VARS = {"sp": "PS", "msl": "PMSL", "2t": "T_2M", "2d": "TD_2M",
            "10u": "U_10M", "10v": "V_10M", "skt": "T_G"}
# Camadas de solo do IFS (m): nivel n do GRIB = camada n
SOIL_LAYERS = {1: (0.0, 0.07), 2: (0.07, 0.28), 3: (0.28, 1.0), 4: (1.0, 2.89)}


def parse_args():
    p = argparse.ArgumentParser(description="IFS (ECMWF open data) -> intermediarios do WPS")
    p.add_argument("--indir", required=True, help="pasta com os ifs_*.grib2 da rodada")
    p.add_argument("--run", required=True, help="rodada do IFS (YYYYMMDDHH)")
    p.add_argument("--fcst", type=int, default=0, help="horas de previsao (0 = so a CI)")
    p.add_argument("--step", type=int, default=3, help="intervalo entre horarios (h)")
    p.add_argument("--box", default="global",
                   help="recorte lon1,lon2,lat1,lat2 ou 'global'")
    p.add_argument("--prefix", default="IFS", help="prefixo dos intermediarios")
    p.add_argument("--outdir", required=True, help="pasta de saida")
    return p.parse_args()


class Cropper:
    """Recorta um campo lat-lon global na caixa pedida, com as linhas de sul para norte."""

    def __init__(self, gid, box):
        ni = eccodes.codes_get(gid, "Ni")
        nj = eccodes.codes_get(gid, "Nj")
        lat1 = eccodes.codes_get(gid, "latitudeOfFirstGridPointInDegrees")
        lon1 = eccodes.codes_get(gid, "longitudeOfFirstGridPointInDegrees")
        dlat = eccodes.codes_get(gid, "jDirectionIncrementInDegrees")
        dlon = eccodes.codes_get(gid, "iDirectionIncrementInDegrees")
        sign = 1.0 if eccodes.codes_get(gid, "jScansPositively") == 1 else -1.0
        lats = lat1 + sign * dlat * np.arange(nj)
        lons = (lon1 + dlon * np.arange(ni) + 180.0) % 360.0 - 180.0
        if box == "global":
            ii, jj = np.arange(ni), np.arange(nj)
        else:
            w, e, s, n = (float(x) for x in box.split(","))
            if w < -180.0 or e > 360.0 or w >= e:
                sys.exit(f"Recorte {box} invalido: use lon1 < lon2, em -180..180 ou 0..360")
            # Caixa que cruza 180 graus vem em 0..360 (lon2 > 180): usa essa representacao
            if e > 180.0:
                lons = lons % 360.0
            ii = np.where((lons >= w) & (lons <= e))[0]
            ii = ii[np.argsort(lons[ii])]          # oeste -> leste, mesmo passando a borda da grade
            jj = np.where((lats >= s) & (lats <= n))[0]
            if ii.size < 2 or jj.size < 2 or not np.allclose(np.diff(lons[ii]), dlon, atol=1e-3 * dlon):
                sys.exit(f"Recorte {box} vazio ou nao contiguo na grade do IFS")
        self.jj = jj[np.argsort(lats[jj])]
        self.ii = ii
        self.shape = (nj, ni)
        self.geo = (round(float(lats[self.jj[0]]), 6), round(float(lons[ii[0]]), 6),
                    dlat, dlon, len(self.jj), len(ii))

    def __call__(self, values):
        return values.reshape(self.shape)[np.ix_(self.jj, self.ii)].astype(np.float32)


def read_grib(path, box, crop):
    """Le um GRIB do IFS -> {(shortName, nivel, passo): campo recortado}."""
    out = {}
    with open(path, "rb") as f:
        while (gid := eccodes.codes_grib_new_from_file(f)) is not None:
            try:
                if crop is None:
                    crop = Cropper(gid, box)
                values = eccodes.codes_get_values(gid)
                if eccodes.codes_get(gid, "bitmapPresent"):
                    values = np.where(values == eccodes.codes_get(gid, "missingValue"), np.nan, values)
                # Nivel so importa na pressao (hPa) e no solo (camada 1-4);
                # o resto (2t e 2d em 2 m, 10u e 10v em 10 m, sp, msl...) fica 0
                tol = eccodes.codes_get(gid, "typeOfLevel")
                level = eccodes.codes_get(gid, "level", ktype=int)
                if tol != "isobaricInhPa" and "soil" not in tol.lower():
                    level = 0
                key = (eccodes.codes_get(gid, "shortName"), level,
                       eccodes.codes_get(gid, "endStep", ktype=int))
                out[key] = crop(values)
            finally:
                eccodes.codes_release(gid)
    return out, crop


def get(data, short, level, step):
    if (short, level, step) in data:
        return data[(short, level, step)]
    # Campos de superficie: aceita o unico nivel que houver (2 m, 10 m, ...)
    if level == 0:
        same = [k for k in data if k[0] == short and k[2] == step]
        if len(same) == 1:
            return data[same[0]]
    names = sorted({f"{s}@{lev}/{st}h" for s, lev, st in data if st == step or s == short})
    sys.exit(f"Campo {short} (nivel {level}, passo {step} h) ausente nos arquivos do IFS.\n"
             f"Campos lidos (shortName@nivel/passo): {' '.join(names)}")


def step_res(data, step):
    """Monta, para um horario, o dicionario no formato que o icon2wps usa."""
    res = {}
    for short, var in PL_VARS.items():
        scale = wps.G if short == "gh" else 1.0
        recs = [((lev * 100.0, None), field * scale)
                for (s, lev, st), field in data.items() if s == short and st == step]
        if not recs:
            sys.exit(f"Campo {short} nos niveis de pressao ausente no passo {step} h")
        res[var] = recs
    for short, var in SFC_VARS.items():
        res[var] = [((None, None), get(data, short, 0, step))]

    if step == 0:
        sd = get(data, "sd", 0, 0)                  # m de equivalente em agua
        rsn = data.get(("rsn", 0, 0))               # densidade da neve (kg m-3)
        if rsn is None:
            rsn = np.full_like(sd, 300.0)
        sit = data.get(("sithick", 0, 0))           # espessura do gelo marinho (m)
        res["W_SNOW"] = [((None, None), sd * 1000.0)]
        res["H_SNOW"] = [((None, None), np.where(rsn > 0, sd * 1000.0 / rsn, 0.0))]
        res["FR_ICE"] = [((None, None), (np.nan_to_num(sit) > 0).astype(np.float32)
                          if sit is not None else np.zeros_like(sd))]
        # vsw (m3 m-3) -> kg m-2 por camada, que e o que o icon2wps espera do W_SO
        res["W_SO"] = [((top, bot), get(data, "vsw", k, 0) * 1000.0 * (bot - top))
                       for k, (top, bot) in SOIL_LAYERS.items()]
        res["T_SO"] = [((0.5 * (top + bot), None), get(data, "sot", k, 0))
                       for k, (top, bot) in SOIL_LAYERS.items()]
    return res


def main():
    args = parse_args()
    wps.MAP_SOURCE = "ECMWF IFS"
    run = dt.datetime.strptime(args.run, "%Y%m%d%H")
    os.makedirs(args.outdir, exist_ok=True)

    # Os arquivos de cada horario sao lidos so na vez dele (no 0.1 deg cada
    # campo recortado ocupa alguns MB)
    hours = range(0, args.fcst + 1, args.step)
    paths = [os.path.join(args.indir, f"ifs_{k}.grib2") for k in ("sfc0", "sol")]
    paths += [os.path.join(args.indir, f"ifs_{k}.{h:03d}.grib2") for h in hours for k in ("pl", "sfc")]
    missing = [p for p in paths if not os.path.isfile(p)]
    if missing:
        sys.exit("Arquivos do IFS ausentes:\n  " + "\n  ".join(missing))

    fixed, crop = {}, None
    for name in ("sfc0", "sol"):
        part, crop = read_grib(os.path.join(args.indir, f"ifs_{name}.grib2"), args.box, crop)
        fixed.update(part)
    geo = crop.geo
    ti = {"HSURF": get(fixed, "z", 0, 0) / wps.G,
          "LANDSEA": (np.nan_to_num(get(fixed, "lsm", 0, 0)) >= 0.5).astype(np.float32)}

    for hour in hours:
        valid = run + dt.timedelta(hours=hour)
        hdate = f"{valid:%Y-%m-%d_%H}:00:00"
        data = dict(fixed)
        for name in ("pl", "sfc"):
            part, crop = read_grib(os.path.join(args.indir, f"ifs_{name}.{hour:03d}.grib2"), args.box, crop)
            data.update(part)
        res = step_res(data, hour)
        fields, nlev = wps.pressure_fields(res)
        fields += wps.surface_fields(res, ti, initial=(hour == 0))

        out = os.path.join(args.outdir, f"{args.prefix}:{valid:%Y-%m-%d_%H}")
        with open(out, "wb") as f:
            for name, units, desc, xlvl, field in fields:
                wps.write_field(f, hdate, geo, name, units, desc, xlvl, field)
        print(f"   -> {out} ({len(fields)} campos, {nlev} niveis de pressao, "
              f"grade {geo[5]}x{geo[4]})", flush=True)


if __name__ == "__main__":
    main()
