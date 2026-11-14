#!/usr/bin/env python3
#-----------------------------------------------------------------------------#
# !SCRIPT: wps_inventory.py                                       [ICON/IFS]
#
# !DESCRIPTION:
#     Lista o conteudo de um arquivo intermediario do WPS (formato WPS = 5),
#     como os gerados pelo ungrib (GFS:..., ERA:...) ou pelo icon2wps.py /
#     ifs2wps.py (ICON:..., IFS:...): campo, nivel, unidade, grade e
#     minimo/media/maximo. Serve para conferir a conversao antes de rodar o
#     init_atmosphere e para comparar fontes (ex.: GFS x ICON).
#
#     So precisa de numpy.
#
# !CALLING SEQUENCE:
#     wps_inventory.py ICON:2026-11-05_00 [--field TT] [--levels]
#
#        --field NOME : so esse campo
#        --levels     : resumo dos niveis por campo, em vez de uma linha por registro
#
#     xlvl = pressao em Pa nos niveis isobaricos (GFS, ERA5, IFS, ICON_VCOORD=pressure)
#            ou numero do nivel nos niveis do modelo do ICON (1 = topo); 200100 = superficie.
#
#-----------------------------------------------------------------------------#

import argparse
import struct
import sys
from collections import defaultdict

import numpy as np


def records(path):
    """Registros Fortran sequenciais big-endian (marcador de 4 bytes antes e depois)."""
    with open(path, "rb") as f:
        while True:
            head = f.read(4)
            if not head:
                return
            (n,) = struct.unpack(">i", head)
            payload = f.read(n)
            tail = f.read(4)
            if len(payload) != n or tail != head:
                sys.exit(f"{path}: arquivo truncado ou fora do formato intermediario do WPS")
            yield payload


def fields(path):
    rec = records(path)
    for version in rec:
        if struct.unpack(">i", version)[0] != 5:
            sys.exit(f"{path}: versao do intermediario diferente de 5 (formato WPS)")
        hdate, xfcst, source, field, units, desc, xlvl, nx, ny, iproj = struct.unpack(
            ">24sf32s9s25s46sf3i", next(rec))
        proj = next(rec)                       # projecao (lat-lon: SWCORNER, lat1, lon1, dlat, dlon, raio)
        next(rec)                              # is_wind_grid_rel
        slab = np.frombuffer(next(rec), dtype=">f4").reshape(ny, nx)
        geo = ""
        if iproj == 0:
            _, lat1, lon1, dlat, dlon, _ = struct.unpack(">8s5f", proj[:28])
            geo = f"lat {lat1:.3f}..{lat1 + (ny - 1) * dlat:.3f} lon {lon1:.3f}..{lon1 + (nx - 1) * dlon:.3f} d {dlat:.4f}"
        yield {"date": hdate.decode().strip(), "source": source.decode().strip(),
               "field": field.decode().strip(), "units": units.decode().strip(),
               "xlvl": xlvl, "nx": nx, "ny": ny, "geo": geo, "data": slab}


def level_name(xlvl):
    """xlvl: pressao em Pa (niveis isobaricos) ou numero do nivel (niveis do modelo do ICON, 1 = topo)."""
    if xlvl == 200100.0:
        return "superficie"
    if xlvl == 201300.0:
        return "nivel do mar"
    return f"xlvl {xlvl:.0f}"


def main():
    p = argparse.ArgumentParser(description="Inventario de um intermediario do WPS")
    p.add_argument("file")
    p.add_argument("--field", help="so este campo (ex.: TT, GHT, SM000010)")
    p.add_argument("--levels", action="store_true", help="resumo por campo")
    a = p.parse_args()

    summary = defaultdict(list)
    first = True
    for rec in fields(a.file):
        if first:
            print(f"{a.file}: {rec['date']}  fonte '{rec['source']}'  grade {rec['nx']}x{rec['ny']}  {rec['geo']}")
            first = False
        if a.field and rec["field"] != a.field:
            continue
        d = rec["data"]
        if a.levels:
            summary[(rec["field"], rec["units"])].append(rec["xlvl"])
            continue
        nan = int(np.isnan(d).sum())
        print(f"{rec['field']:9s} {level_name(rec['xlvl']):>14s} {rec['units']:10s} "
              f"min {np.nanmin(d):12.4g} media {np.nanmean(d):12.4g} max {np.nanmax(d):12.4g}"
              + (f"  NaN: {nan}" if nan else ""))
    if a.levels:
        for (name, units), lev in summary.items():
            lev = sorted(lev)
            print(f"{name:9s} {units:10s} {len(lev):3d} nivel(is): {level_name(lev[0])} ... {level_name(lev[-1])}")
    if first:
        sys.exit(f"{a.file}: nenhum campo encontrado")


if __name__ == "__main__":
    main()
