#!/usr/bin/env python3
#-----------------------------------------------------------------------------#
# !SCRIPT: zeta_levels.py                                        [ICON/IFS]
#
# !DESCRIPTION:
#     Gera o arquivo de alturas das interfaces das camadas (zeta, em metros)
#     lido pelo init_atmosphere em config_specified_zeta_levels. O arquivo tem
#     NLEV+1 linhas, um valor por linha, de 0 ate ZTOP (sem comentarios: o
#     init_atmosphere conta as linhas).
#
#     Distribuicao em tres trechos:
#        1. camada limite: dz cresce de --dzbot com razao --r1 ate --dzmid
#        2. troposfera: dz constante = --dzmid ate --ztrans
#        3. acima: dz cresce geometricamente com a razao r2 que fecha
#           exatamente NLEV camadas em ZTOP (r2 calculada aqui)
#
#     Padrao (L75, ztop 30 km, 3 km convectivo, dt 12 s): dzbot 20 m
#     (1o nivel de massa a 10 m), r1 1.10, dzmid 480 m, ztrans 12 km.
#     Comparada com a grade TC do MPAS com 75 niveis: 25 camadas abaixo de
#     2 km (TC: 19), dz nunca menor que ~215 m acima de 2 km (TC: 190 m;
#     Courant vertical nao piora) e 10 niveis na camada de amortecimento
#     acima de config_zd = 22 km.
#
#     Imprime a tabela de alturas e um resumo em stderr.
#
# !CALLING SEQUENCE:
#     zeta_levels.py [--nlev 75] [--ztop 30000] [--dzbot 20] [--r1 1.10]
#                    [--dzmid 480] [--ztrans 12000] > zeta_levels.L75.txt
#
#-----------------------------------------------------------------------------#

import argparse
import sys

import numpy as np


def upper_ratio(dzmid, nleft, height):
    """Razao r2 tal que dzmid*(r2 + r2**2 + ... + r2**nleft) = height (bissecao)."""
    def total(r):
        return dzmid * nleft if abs(r - 1.0) < 1e-12 else dzmid * r * (r ** nleft - 1.0) / (r - 1.0)
    lo, hi = 0.5, 2.0
    if not total(lo) < height < total(hi):
        return None
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if total(mid) < height:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def build(nlev, ztop, dzbot, r1, dzmid, ztrans):
    z, dz = [0.0], dzbot
    while dz < dzmid:                      # 1. camada limite
        z.append(z[-1] + dz)
        dz *= r1
    while z[-1] + dzmid <= ztrans:         # 2. troposfera
        z.append(z[-1] + dzmid)
    nleft = nlev - (len(z) - 1)            # 3. ate o topo
    if nleft < 1:
        sys.exit(f"Camadas demais abaixo de {ztrans:.0f} m: diminua --ztrans ou aumente --dzmid/--r1")
    r2 = upper_ratio(dzmid, nleft, ztop - z[-1])
    if r2 is None:
        sys.exit("Nao ha razao de estiramento que feche o topo: ajuste --dzmid/--ztrans")
    for i in range(1, nleft + 1):
        z.append(z[-1] + dzmid * r2 ** i)
    z = np.array(z)
    z[-1] = ztop
    return z, r2


def main():
    p = argparse.ArgumentParser(description="Alturas das interfaces para config_specified_zeta_levels")
    p.add_argument("--nlev", type=int, default=75, help="numero de camadas (config_nvertlevels)")
    p.add_argument("--ztop", type=float, default=30000.0, help="topo do modelo (m)")
    p.add_argument("--dzbot", type=float, default=20.0, help="espessura da 1a camada (m)")
    p.add_argument("--r1", type=float, default=1.10, help="razao de estiramento na camada limite")
    p.add_argument("--dzmid", type=float, default=480.0, help="espessura constante na troposfera (m)")
    p.add_argument("--ztrans", type=float, default=12000.0, help="altura onde comeca o estiramento superior (m)")
    a = p.parse_args()

    zw, r2 = build(a.nlev, a.ztop, a.dzbot, a.r1, a.dzmid, a.ztrans)
    dz = np.diff(zw)
    zm = 0.5 * (zw[1:] + zw[:-1])

    print("  k   z_interface(m)   z_massa(m)   dz(m)   razao", file=sys.stderr)
    for k in range(a.nlev):
        rat = dz[k] / dz[k - 1] if k > 0 else float("nan")
        print(f"{k + 1:3d} {zw[k]:12.1f} {zm[k]:13.1f} {dz[k]:8.1f} {rat:7.3f}", file=sys.stderr)
    print(f"{a.nlev + 1:3d} {zw[-1]:12.1f}", file=sys.stderr)
    print(f"Resumo: {a.nlev} camadas; 1o nivel de massa {zm[0]:.1f} m; "
          f"camadas abaixo de 1/2/3 km: {np.sum(zw[1:] <= 1000)}/{np.sum(zw[1:] <= 2000)}/{np.sum(zw[1:] <= 3000)}; "
          f"razao maxima {np.max(dz[1:] / dz[:-1]):.3f}; r2 = {r2:.4f}; dz no topo {dz[-1]:.0f} m",
          file=sys.stderr)

    for v in zw:
        print(f"{v:.2f}")


if __name__ == "__main__":
    main()
