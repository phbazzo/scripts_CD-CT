#!/bin/bash
#-----------------------------------------------------------------------------#
# !SCRIPT: instalar.sh
#
# !DESCRIPTION:
#     Aplica o suporte a ICON e IFS como CI/CC numa instalacao EXISTENTE do
#     scripts_CD-CT do MONAN (versao 1.6.0), sem precisar clonar este fork.
#
#        1. confere a versao (VERSION.txt) e se o patch aplica sem conflito
#        2. guarda uma copia dos arquivos que serao alterados (scripts.antes_icon_ifs.DATA/)
#        3. aplica patches/icon_ifs_scripts_CD-CT-1.6.0.patch (git apply ou patch)
#        4. da permissao de execucao aos scripts novos
#        5. procura um Python com numpy + eccodes e o cdo (so avisa se faltar)
#
#     Nada e baixado nem compilado aqui. Rodar duas vezes nao estraga nada:
#     se o patch ja estiver aplicado, o script avisa e para.
#
# !CALLING SEQUENCE:
#     ./instalar.sh /caminho/para/scripts_CD-CT [--force]
#
#        --force : tenta aplicar mesmo se VERSION.txt nao for 1.6.0 (pode falhar)
#
# !EXAMPLE:
#     git clone https://github.com/phbazzo/scripts_CD-CT.git scripts_CD-CT_icon_ifs
#     ./scripts_CD-CT_icon_ifs/instalar.sh ${HOME}/monan/scripts_CD-CT
#-----------------------------------------------------------------------------#

set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATCH=${HERE}/patches/icon_ifs_scripts_CD-CT-1.6.0.patch
BASE_VERSION=1.6.0
GREEN='\033[1;32m'; RED='\033[1;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

if [ $# -lt 1 ] || [ ! -d "${1}/scripts" ]
then
   echo ""
   echo "Uso: ${0} /caminho/para/scripts_CD-CT [--force]"
   echo ""
   echo "A pasta indicada deve conter scripts/ (ex.: .../scripts_CD-CT, clonada de"
   echo "https://github.com/monanadmin/scripts_CD-CT, versao ${BASE_VERSION})."
   echo ""
   exit 1
fi
TARGET=$(cd "${1}" && pwd)
FORCE=${2:-}

if [ ! -s "${PATCH}" ]
then
   echo -e "${RED}==>${NC} Patch nao encontrado: ${PATCH}"
   exit 1
fi

# 1. Versao e checagem do patch -------------------------------------------------
version=$(head -1 "${TARGET}/VERSION.txt" 2>/dev/null | tr -d '[:space:]')
echo -e "${GREEN}==>${NC} scripts_CD-CT em ${TARGET} (VERSION.txt: ${version:-ausente})"
if [[ "${version}" != "${BASE_VERSION}" && "${FORCE}" != "--force" ]]
then
   echo -e "${RED}==>${NC} Este patch foi feito sobre a versao ${BASE_VERSION}."
   echo -e "${RED}==>${NC} Atualize o scripts_CD-CT (git checkout ${BASE_VERSION}) ou rode com --force e confira o resultado."
   echo -e "${RED}==>${NC} As mudancas, uma a uma, estao em docs/08-mudancas-nos-scripts-oficiais.md."
   exit 1
fi

cd "${TARGET}"
if [ -d .git ] && command -v git > /dev/null
then
   APPLY_CHECK="git apply --check ${PATCH}"
   APPLY="git apply ${PATCH}"
   REVERSE_CHECK="git apply --check -R ${PATCH}"
elif command -v patch > /dev/null
then
   APPLY_CHECK="patch -p1 --dry-run --forward -s -i ${PATCH}"
   APPLY="patch -p1 --forward -i ${PATCH}"
   REVERSE_CHECK="patch -p1 --dry-run -R -s -f -i ${PATCH}"
else
   echo -e "${RED}==>${NC} Precisa do git ou do patch para aplicar as mudancas."
   exit 1
fi

if ${REVERSE_CHECK} > /dev/null 2>&1
then
   echo -e "${YELLOW}==>${NC} O suporte a ICON/IFS ja esta aplicado em ${TARGET}. Nada a fazer."
   exit 0
fi
if ! ${APPLY_CHECK}
then
   echo -e "\n${RED}==>${NC} O patch nao aplica sem conflito (scripts alterados localmente?). Nada foi mudado."
   echo -e "${RED}==>${NC} Opcoes: 'git stash' das suas mudancas e rodar de novo; 'git apply --3way ${PATCH}';"
   echo -e "${RED}==>${NC} ou aplicar a mao seguindo docs/08-mudancas-nos-scripts-oficiais.md."
   exit 1
fi

# 2. Copia de seguranca dos arquivos que existem e serao alterados ----------------
BACKUP=${TARGET}/scripts.antes_icon_ifs.$(date +%Y%m%d%H%M%S)
mkdir -p "${BACKUP}"
for f in $(grep -E '^\+\+\+ b/' "${PATCH}" | sed 's,^+++ b/,,'); do
   if [ -f "${f}" ]; then mkdir -p "${BACKUP}/$(dirname ${f})"; cp -p "${f}" "${BACKUP}/${f}"; fi
done
echo -e "${GREEN}==>${NC} Copia dos arquivos originais em ${BACKUP}"

# 3. Aplica -------------------------------------------------------------------
if ! ${APPLY}
then
   echo -e "${RED}==>${NC} Falha ao aplicar o patch. Os originais estao em ${BACKUP}."
   exit 1
fi

# 4. Permissao de execucao (o 'patch' nao grava o modo dos arquivos novos) ------
chmod +x scripts/*.bash scripts/*.py 2>/dev/null
echo -e "${GREEN}==>${NC} Patch aplicado."

# 5. Ferramentas usadas pela conversao (so avisa) -------------------------------
echo ""
for tool in wget bunzip2; do
   if ! command -v ${tool} > /dev/null; then echo -e "${YELLOW}==>${NC} Aviso: '${tool}' nao encontrado no PATH."; fi
done
found=""
for cand in $(ls -d ${HOME}/.conda/envs/*/bin/python ${HOME}/miniconda3/envs/*/bin/python \
              ${HOME}/miniforge3/envs/*/bin/python ${HOME}/anaconda3/envs/*/bin/python \
              ${HOME}/miniconda3/bin/python ${HOME}/miniforge3/bin/python ${HOME}/anaconda3/bin/python \
              2>/dev/null) $(command -v python3); do
   if "${cand}" -c "import numpy, eccodes" > /dev/null 2>&1; then found=${cand}; break; fi
done
if [ -n "${found}" ]
then
   echo -e "${GREEN}==>${NC} Python com numpy + eccodes: ${found}"
   if [ -x "$(dirname ${found})/cdo" ] || command -v cdo > /dev/null
   then
      echo -e "${GREEN}==>${NC} cdo: $( [ -x "$(dirname ${found})/cdo" ] && echo "$(dirname ${found})/cdo" || command -v cdo)"
   else
      echo -e "${YELLOW}==>${NC} cdo nao encontrado (necessario so para o ICON): conda install -n <env> -c conda-forge cdo"
   fi
else
   echo -e "${YELLOW}==>${NC} Nenhum Python com numpy + eccodes. Crie um ambiente (uma vez):"
   echo -e "      conda create -n monan_grib -c conda-forge python numpy python-eccodes cdo"
fi

echo -e "\n${GREEN}==>${NC} Pronto. Proximos passos (README.md):"
echo -e "      cd ${TARGET}/scripts"
echo -e "      ./2.pre_processing.bash ICON <RES_MESH> $(date -u +%Y%m%d)00 24"
echo -e "      ./2.pre_processing.bash IFS  <RES_MESH> $(date -u +%Y%m%d)00 24\n"
