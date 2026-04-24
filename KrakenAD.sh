#!/bin/bash
# =============================================================================
#  KrakenAD.sh — Audit Active Directory
#  Pipeline officiel : bloodhound-python → bloodhound-automation → AD-Miner
#  Basé sur : https://github.com/Tanguy-Boisset/bloodhound-automation
#             https://github.com/AD-Security/AD_Miner
#  Usage : ./KrakenAD.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
BASE_DIR="${KRAKANAD_BASE:-/data}"
VENV_DIR="$BASE_DIR/krakanad-venv"
PROJECTS_DIR="$BASE_DIR/KrakenAD/projects"
BH_AUTO_DIR="$BASE_DIR/bloodhound-automation"
BH_AUTO_VENV="$BH_AUTO_DIR/venv"

# Ports BloodHound Automation (modifiables)
BH_PORT_NEO4J="${BH_PORT_NEO4J:-10001}"
BH_PORT_NEO4J_HTTP="${BH_PORT_NEO4J_HTTP:-10501}"
BH_PORT_WEB="${BH_PORT_WEB:-8001}"

# Credentials Neo4j générés par bloodhound-automation
NEO4J_USER="neo4j"
NEO4J_PASS="neo5j"

TOTAL_STEPS=5

# =============================================================================
# COULEURS & HELPERS
# =============================================================================
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"
BOLD="\e[1m"; DIM="\e[2m"; RESET="\e[0m"

step()  { echo -e "\n${CYAN}${BOLD}[$1/$TOTAL_STEPS]${RESET} ${BOLD}$2${RESET}"; }
ok()    { echo -e "    ${GREEN}v${RESET}  $1"; }
info()  { echo -e "    ${YELLOW}>${RESET}  $1"; }
warn()  { echo -e "    ${YELLOW}!${RESET}  $1"; }
fatal() { echo -e "\n${RED}${BOLD}[ERREUR]${RESET} $1\n"; exit 1; }

# =============================================================================
# NETTOYAGE AUTOMATIQUE
# =============================================================================
PROJECT_NAME=""
cleanup() {
    local code=$?
    echo ""
    if [[ -n "$PROJECT_NAME" && -d "$BH_AUTO_DIR" ]]; then
        info "Arret de BloodHound (bloodhound-automation stop)..."
        source "$BH_AUTO_VENV/bin/activate"
        cd "$BH_AUTO_DIR" && python3 bloodhound-automation.py stop "$PROJECT_NAME" \
            2>/dev/null && ok "BloodHound arrete." || warn "Arret partiel."
        deactivate
    fi
    exit $code
}
trap cleanup EXIT

# =============================================================================
# BANNIERE
# =============================================================================
clear
echo -e "${BOLD}"
echo "  +=======================================+"
echo "  |      AUDIT ACTIVE DIRECTORY           |"
echo "  |   bloodhound-python  +  AD-Miner       |"
echo "  +=======================================+"
echo -e "${RESET}"

# =============================================================================
# ETAPE 1 — DEPENDANCES
# =============================================================================
step 1 "Verification des dependances"

[[ "$(uname -s)" == "Linux" ]] || fatal "Linux requis."

if   command -v apt-get &>/dev/null; then PKG="apt"
elif command -v dnf     &>/dev/null; then PKG="dnf"
elif command -v yum     &>/dev/null; then PKG="yum"
elif command -v pacman  &>/dev/null; then PKG="pacman"
else fatal "Gestionnaire de paquets non reconnu."; fi

_updated=false
pkg_update() {
    $_updated && return
    case "$PKG" in
        apt)    sudo apt-get update -qq >/dev/null 2>&1 ;;
        dnf|yum) sudo "$PKG" makecache -q >/dev/null 2>&1 ;;
        pacman) sudo pacman -Sy --quiet >/dev/null 2>&1 ;;
    esac
    _updated=true
}

pkg_install() {
    info "Installation : $1"
    case "$PKG" in
        apt)    sudo apt-get install -y -qq "$1" >/dev/null 2>&1 ;;
        dnf|yum) sudo "$PKG" install -y -q "$1" >/dev/null 2>&1 ;;
        pacman) sudo pacman -S --noconfirm --quiet "$1" >/dev/null 2>&1 ;;
    esac
}

# Dependances systeme
for dep in python3 git zip unzip curl docker; do
    command -v "$dep" &>/dev/null || { pkg_update; pkg_install "$dep"; }
done
command -v pip3 &>/dev/null || { pkg_update; pkg_install python3-pip; }
python3 -m venv --help &>/dev/null 2>&1 || { pkg_update; pkg_install python3-venv; }

# Docker daemon
if ! docker info &>/dev/null 2>&1; then
    info "Demarrage de Docker..."
    sudo systemctl start docker 2>/dev/null || fatal "Impossible de demarrer Docker."
    sudo systemctl enable docker 2>/dev/null || true
    sleep 3
    docker info &>/dev/null 2>&1 || fatal "Docker inaccessible."
fi

# Docker Compose
COMPOSE_CMD=""
docker compose version &>/dev/null 2>&1 && COMPOSE_CMD="docker compose"
[[ -z "$COMPOSE_CMD" ]] && command -v docker-compose &>/dev/null && COMPOSE_CMD="docker-compose"
if [[ -z "$COMPOSE_CMD" ]]; then
    pkg_update
    pkg_install docker-compose-plugin 2>/dev/null || pkg_install docker-compose 2>/dev/null || true
    docker compose version &>/dev/null 2>&1 && COMPOSE_CMD="docker compose" || fatal "docker compose introuvable."
fi

# bloodhound-automation
mkdir -p "$BASE_DIR" "$PROJECTS_DIR"
if [[ ! -d "$BH_AUTO_DIR" ]]; then
    info "Clonage de bloodhound-automation..."
    git clone --quiet https://github.com/Tanguy-Boisset/bloodhound-automation.git "$BH_AUTO_DIR" \
        || fatal "Impossible de cloner bloodhound-automation."
else
    git -C "$BH_AUTO_DIR" pull --quiet 2>/dev/null || true
fi

if [[ ! -d "$BH_AUTO_VENV" ]]; then
    info "Installation des dependances bloodhound-automation..."
    python3 -m venv "$BH_AUTO_VENV"
fi
source "$BH_AUTO_VENV/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet -r "$BH_AUTO_DIR/requirements.txt" 2>/dev/null || true
pip install --quiet colorama requests docker 2>/dev/null || true
deactivate

# Venv principal (bloodhound-python + AD-Miner)
if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip
command -v bloodhound-python &>/dev/null || pip install --quiet bloodhound
command -v AD-miner          &>/dev/null || pip install --quiet ad-miner
command -v bloodhound-python &>/dev/null || fatal "bloodhound-python introuvable."
command -v AD-miner          &>/dev/null || fatal "AD-Miner introuvable."
deactivate

ok "Dependances OK"

# =============================================================================
# SAISIE UTILISATEUR
# =============================================================================
echo ""
echo -e "${DIM}Informations de la cible :${RESET}\n"
read -rp  "  Nom du projet   : " PROJECT_NAME
read -rp  "  Domaine         : " DOMAIN
read -rp  "  Utilisateur     : " USERNAME
read -rsp "  Mot de passe    : " PASSWORD; echo
read -rp  "  IP du DC        : " DC_IP
echo ""

[[ -z "$PROJECT_NAME" ]] && fatal "Nom de projet manquant."
[[ -z "$DOMAIN"       ]] && fatal "Domaine manquant."
[[ -z "$USERNAME"     ]] && fatal "Utilisateur manquant."
[[ -z "$PASSWORD"     ]] && fatal "Mot de passe manquant."
[[ -z "$DC_IP"        ]] && fatal "IP du DC manquante."

PROJECT_DIR="$PROJECTS_DIR/$PROJECT_NAME"
mkdir -p "$PROJECT_DIR"

# =============================================================================
# ETAPE 2 — COLLECTE LDAP
# =============================================================================
step 2 "Collecte LDAP via bloodhound-python"
info "Domaine=$DOMAIN  DC=$DC_IP  User=$USERNAME"

source "$VENV_DIR/bin/activate"
cd "$PROJECT_DIR"

bloodhound-python \
    -d "$DOMAIN" \
    -u "$USERNAME" \
    -p "$PASSWORD" \
    -ns "$DC_IP" \
    -c All \
    --zip \
    2>&1 | tee "$PROJECT_DIR/collect.log" | grep -E "^\[" || true

deactivate

ZIPFILE=$(ls -t "$PROJECT_DIR"/*.zip 2>/dev/null | head -1 || true)
if [[ -z "$ZIPFILE" ]]; then
    ZIPFILE="$PROJECT_DIR/${PROJECT_NAME}.zip"
    info "Compression des JSON..."
    zip -j "$ZIPFILE" "$PROJECT_DIR"/*.json 2>/dev/null \
        || fatal "Aucune donnee collectee. Voir : $PROJECT_DIR/collect.log"
fi
ok "Collecte OK : $(basename "$ZIPFILE")"

# =============================================================================
# ETAPE 3 — DEMARRAGE BLOODHOUND CE via bloodhound-automation
# =============================================================================
step 3 "Demarrage BloodHound CE (bloodhound-automation)"

source "$BH_AUTO_VENV/bin/activate"
cd "$BH_AUTO_DIR"

# Si le projet existe déjà, le démarrer ; sinon le créer
EXISTING=$(python3 bloodhound-automation.py list 2>/dev/null || true)

if echo "$EXISTING" | grep -q "^$PROJECT_NAME$"; then
    info "Projet existant — demarrage..."
    python3 bloodhound-automation.py start "$PROJECT_NAME" 2>&1 | tail -5
else
    info "Creation du projet '$PROJECT_NAME'..."
    python3 bloodhound-automation.py start \
        -bp "$BH_PORT_NEO4J" \
        -np "$BH_PORT_NEO4J_HTTP" \
        -wp "$BH_PORT_WEB" \
        "$PROJECT_NAME" 2>&1 | grep -E "^\[|neo4j|BloodHound|password" || true
fi

cd "$PROJECT_DIR"
deactivate

# Vérifier que Neo4j répond
info "Verification Neo4j..."
OK=false
for i in $(seq 1 24); do
    if docker exec "${PROJECT_NAME}-graph-db-1" \
        cypher-shell -u "$NEO4J_USER" -p "$NEO4J_PASS" "RETURN 1" &>/dev/null 2>&1; then
        OK=true; break
    fi
    sleep 5
done
$OK || fatal "Neo4j inaccessible apres 2 min.\nVerifiez : docker logs ${PROJECT_NAME}-graph-db-1"

ok "BloodHound CE actif"

# =============================================================================
# ETAPE 4 — IMPORT DES DONNEES via bloodhound-automation data
# =============================================================================
step 4 "Import des donnees BloodHound"

source "$BH_AUTO_VENV/bin/activate"
cd "$BH_AUTO_DIR"

info "Upload de $(basename "$ZIPFILE")..."
python3 bloodhound-automation.py data \
    -z "$ZIPFILE" \
    "$PROJECT_NAME" \
    2>&1 | grep -E "^\[|\[\+\]|\[\*\]" || true

cd "$PROJECT_DIR"
deactivate
ok "Import termine"

# =============================================================================
# ETAPE 5 — RAPPORT AD-MINER
# =============================================================================
step 5 "Generation du rapport AD-Miner"

source "$VENV_DIR/bin/activate"
cd "$PROJECT_DIR"

AD-miner \
    -c \
    -cf "$PROJECT_NAME" \
    -b  "bolt://localhost:$BH_PORT_NEO4J" \
    -u  "$NEO4J_USER" \
    -p  "$NEO4J_PASS" \
    2>&1 | tee "$PROJECT_DIR/ad-miner.log" | grep -vE "^$" || true

deactivate

REPORT_DIR=$(ls -td "$PROJECT_DIR"/render_* 2>/dev/null | head -1 || true)
[[ -n "$REPORT_DIR" ]] \
    && ok "Rapport : $REPORT_DIR/" \
    || ok "Rapport genere (voir ad-miner.log)"

# =============================================================================
# RESUME
# =============================================================================
echo ""
echo -e "  ${CYAN}${BOLD}==========================================${RESET}"
echo -e "  ${BOLD}Projet       :${RESET} $PROJECT_NAME"
echo -e "  ${BOLD}Donnees      :${RESET} $PROJECT_DIR"
[[ -n "${REPORT_DIR:-}" ]] && \
echo -e "  ${BOLD}Rapport      :${RESET} $REPORT_DIR/"
echo -e "  ${BOLD}Log collecte :${RESET} $PROJECT_DIR/collect.log"
echo -e "  ${BOLD}Log AD-Miner :${RESET} $PROJECT_DIR/ad-miner.log"
echo -e "  ${DIM}(BloodHound arrete automatiquement)${RESET}"
echo -e "  ${CYAN}${BOLD}==========================================${RESET}"
echo ""
