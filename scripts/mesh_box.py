#!/usr/bin/env python3
#-----------------------------------------------------------------------------#
# !SCRIPT: mesh_box.py                                            [ICON/IFS]
#
# !DESCRIPTION:
#     Caixa lat-lon que cobre uma malha MPAS/MONAN regional, com margem, no
#     formato "lon1,lon2,lat1,lat2" usado pelo icon2wps.py/ifs2wps.py (e pelo
#     sellonlatbox do CDO). E o recorte "auto" (ICON_BOX/IFS_BOX=auto).
#
#     A margem existe porque o init_atmosphere interpola dos pontos lat-lon
#     vizinhos de cada celula: a caixa precisa ir um pouco alem da malha.
#
#     Le latCell/lonCell (radianos) de qualquer arquivo da malha
#     (x1.RES.static.nc, grid.nc, init.nc), tentando nesta ordem: netCDF4,
#     xarray, scipy (so netCDF classico/64-bit) e, por ultimo, o ncdump.
#
#     Longitudes saem em -180..180 ou, se a malha cruza o meridiano de 180
#     graus, em 0..360. Se a malha ocupar mais de 300 graus de longitude ou
#     chegar a um polo, imprime "global".
#
# !CALLING SEQUENCE:
#     mesh_box.py [--margin 5] x1.RES.static.nc
#
#-----------------------------------------------------------------------------#

import argparse
import re
import shutil
import subprocess
import sys

import numpy as np


def read_latlon(path):
    """latCell, lonCell em graus."""
    errors = []
    try:
        import netCDF4
        with netCDF4.Dataset(path) as nc:
            return (np.degrees(np.asarray(nc.variables["latCell"][:], dtype=np.float64)),
                    np.degrees(np.asarray(nc.variables["lonCell"][:], dtype=np.float64)))
    except Exception as err:  # noqa: BLE001 (tenta o proximo leitor)
        errors.append(f"netCDF4: {err}")
    try:
        import xarray
        with xarray.open_dataset(path, decode_times=False) as ds:
            return np.degrees(ds["latCell"].values), np.degrees(ds["lonCell"].values)
    except Exception as err:  # noqa: BLE001
        errors.append(f"xarray: {err}")
    try:
        from scipy.io import netcdf_file
        with netcdf_file(path, "r", mmap=False) as nc:
            return (np.degrees(nc.variables["latCell"][:].astype(np.float64)),
                    np.degrees(nc.variables["lonCell"][:].astype(np.float64)))
    except Exception as err:  # noqa: BLE001
        errors.append(f"scipy: {err}")
    if shutil.which("ncdump"):
        out = {}
        for var in ("latCell", "lonCell"):
            text = subprocess.run(["ncdump", "-v", var, path], capture_output=True, text=True, check=True).stdout
            body = text.split(f"{var} =", 1)[1].split(";", 1)[0]
            out[var] = np.degrees(np.array(re.findall(r"[-+0-9.eE]+", body), dtype=np.float64))
        return out["latCell"], out["lonCell"]
    errors.append("ncdump: not found in PATH")
    sys.exit(f"mesh_box.py: could not read latCell/lonCell from {path}:\n  " + "\n  ".join(errors))


def main():
    p = argparse.ArgumentParser(description="Caixa lat-lon de uma malha MPAS regional")
    p.add_argument("mesh", help="arquivo da malha com latCell/lonCell (ex.: x1.RES.static.nc)")
    p.add_argument("--margin", type=float, default=5.0, help="margem em graus (padrao 5)")
    a = p.parse_args()

    lat, lon = read_latlon(a.mesh)
    s, n = lat.min() - a.margin, lat.max() + a.margin
    # Escolhe a representacao de longitude (-180..180 ou 0..360) em que a malha fica mais estreita e a
    # caixa, com a margem, nao sai dos limites dessa representacao
    best = None
    for lons, lo, hi in (((lon + 180.0) % 360.0 - 180.0, -180.0, 180.0), (lon % 360.0, 0.0, 360.0)):
        w, e = lons.min() - a.margin, lons.max() + a.margin
        if w >= lo and e <= hi and (best is None or e - w < best[1] - best[0]):
            best = (w, e)
    if best is None or best[1] - best[0] >= 300.0 or s <= -89.0 or n >= 89.0:
        print("global")
        return
    w, e = best
    width = e - w - 2 * a.margin
    print(f"{np.floor(w):.0f},{np.ceil(e):.0f},{np.floor(max(s, -90.0)):.0f},{np.ceil(min(n, 90.0)):.0f}")
    print(f"mesh_box.py: {lat.size} cells; lat {lat.min():.2f}..{lat.max():.2f}, "
          f"lon width {width:.2f} deg; margin {a.margin} deg", file=sys.stderr)


if __name__ == "__main__":
    main()
