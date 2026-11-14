#!/usr/bin/env python3
#-----------------------------------------------------------------------------#
# !SCRIPT: icon_levels.py                                         [ICON/IFS]
#
# !DESCRIPTION:
#     Escolhe quais niveis do modelo do ICON (1 = topo ... 120 = base) usar
#     como first guess do MONAN, a partir das alturas das meias-camadas
#     (HHL, invariante no tempo, em metros acima do nivel do mar):
#
#        o todos os niveis com altura media acima do solo <= --zfull
#        o acima disso, um a cada --thin niveis
#        o exatamente UM nivel acima do topo do MONAN: o mais baixo cuja
#          altura MINIMA acima do nivel do mar (em todo o globo) passa de
#          --ztop. O init_atmosphere precisa de um nivel do first guess acima
#          de config_ztop para interpolar (e nao extrapolar) as camadas mais
#          altas; niveis mais altos que esse nao sao usados.
#
#     O ztop e comparado com a altura acima do nivel do mar (como o
#     config_ztop do MPAS/MONAN), e nao com a altura acima do solo.
#
#     Imprime os niveis escolhidos (stdout) e a tabela de alturas (stderr).
#
# !CALLING SEQUENCE:
#     icon_levels.py --hhl-dir DIR --ztop 30000 [--zfull 16000] [--thin 2]
#
#-----------------------------------------------------------------------------#

import argparse
import glob
import os
import subprocess
import sys
import tempfile

import eccodes
import numpy as np


def read_hhl(hhl_dir, k, tmpdir):
    """Alturas (m acima do nivel do mar) da meia-camada k (.grib2.bz2)."""
    files = glob.glob(os.path.join(hhl_dir, f"icon_global_icosahedral_time-invariant_*_{k}_HHL.grib2.bz2"))
    if not files:
        sys.exit(f"HHL do nivel {k} ausente em {hhl_dir}")
    native = os.path.join(tmpdir, "hhl.grib2")
    with open(native, "wb") as fo:
        subprocess.run(["bunzip2", "-c", files[0]], stdout=fo, check=True)
    with open(native, "rb") as f:
        gid = eccodes.codes_grib_new_from_file(f)
        try:
            return np.asarray(eccodes.codes_get_values(gid), dtype=np.float64)
        finally:
            eccodes.codes_release(gid)


def main():
    p = argparse.ArgumentParser(description="Selecao dos niveis do modelo do ICON")
    p.add_argument("--hhl-dir", required=True, help="pasta com os *_HHL.grib2.bz2 (1 a 121)")
    p.add_argument("--ztop", type=float, required=True,
                   help="topo do MONAN (m acima do nivel do mar, config_ztop)")
    p.add_argument("--zfull", type=float, default=16000.0, help="abaixo desta altura (m) usa todos os niveis")
    p.add_argument("--thin", type=int, default=2, help="acima de --zfull usa um a cada N niveis")
    args = p.parse_args()

    # Sobe da base (meia-camada 121 = superficie) ate o primeiro nivel cheio
    # que esta acima de --ztop em todo o globo. Guarda so duas meias-camadas
    # por vez (cada uma tem ~2,9 milhoes de pontos).
    z_agl, z_msl_min, top = {}, {}, None
    with tempfile.TemporaryDirectory() as td:
        lower = read_hhl(args.hhl_dir, 121, td)
        sfc_mean = float(lower.mean())
        for k in range(120, 0, -1):
            upper = read_hhl(args.hhl_dir, k, td)
            full = 0.5 * (upper + lower)
            z_agl[k] = float(full.mean()) - sfc_mean   # altura media acima do solo
            z_msl_min[k] = float(full.min())           # altura minima acima do mar
            lower = upper
            if z_msl_min[k] > args.ztop:
                top = k
                break
    if top is None:
        sys.exit(f"Nenhum nivel do ICON passa de --ztop = {args.ztop:.0f} m")

    chosen, above = [top], 0
    for k in range(120, top, -1):
        if z_agl[k] <= args.zfull:
            chosen.append(k)
        else:
            if above % args.thin == 0:
                chosen.append(k)
            above += 1

    print(f"  nivel   altura media AGL   altura minima MSL", file=sys.stderr)
    for k in range(top, 121):
        mark = "*" if k in chosen else " "
        print(f"{mark} nivel {k:3d}: {z_agl[k]:9.1f} m        {z_msl_min[k]:9.1f} m", file=sys.stderr)
    print(f"{len(chosen)} niveis escolhidos; topo do first guess: nivel {top} "
          f"(>= {z_msl_min[top]:.0f} m MSL, ztop = {args.ztop:.0f} m); "
          f"config_nfglevels precisa ser >= {len(chosen) + 1}", file=sys.stderr)
    print(" ".join(str(k) for k in sorted(chosen)))


if __name__ == "__main__":
    main()
