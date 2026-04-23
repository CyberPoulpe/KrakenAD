#!/bin/bash
# =============================================================================
#  KrakenAD.sh
#  Collecte Active Directory + import BloodHound CE + rapport AD-Miner
#  Auto-installation des dépendances si nécessaire
#  Usage : ./KrakenAD.sh
# =============================================================================

set -euo pipefail

# -- Détection du répertoire du script ----------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Configuration ------------------------------------------------------------

BASE_DIR="${KRAKANAD_BASE:-/data}"
BLOODHOUND_AUTOMATION="$BASE_DIR/bloodhound-automation"
RUSTHOUND_DIR="$BASE_DIR/RustHound-CE"
VENV_PYTHON="$RUSTHOUND_DIR/.venv"
VENV_BH="$BLOODHOUND_AUTOMATION/venv"
PROJECTS_DIR="$BASE_DIR/KrakenAD/projects"

BH_PORT_WEB="${BH_PORT_WEB:-8001}"
BH_PORT_NEO4J="${BH_PORT_NEO4J:-7687}"
BH_PORT_NEO4J_HTTP="${BH_PORT_NEO4J_HTTP:-7474}"
NEO4J_USER="neo4j"
NEO4J_PASS="bloodhoundcommunityedition"
BH_ADMIN_PASS="Chien2Sang<3"

TOTAL_STEPS=7  # +2 pour setup

# -- Couleurs -----------------------------------------------------------------
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"
BOLD="\e[1m"; DIM="\e[2m"; RESET="\e[0m"

step()  { echo -e "\n${CYAN}${BOLD}[${1}/${TOTAL_STEPS}]${RESET} ${BOLD}${2}${RESET}"; }
ok()    { echo -e "    ${GREEN}✔${RESET}  ${1}"; }
info()  { echo -e "    ${YELLOW}→${RESET}  ${1}"; }
warn()  { echo -e "    ${YELLOW}⚠${RESET}  ${1}"; }
fatal() { echo -e "\n${RED}${BOLD}[ERREUR]${RESET} ${1}\n"; exit 1; }
need_root() { [[ "$EUID" -eq 0 ]]; }

# -- Bannière -----------------------------------------------------------------
clear
echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║         AUDIT ACTIVE DIRECTORY        ║"
echo "  ║   BloodHound CE  ·  AD-Miner          ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${RESET}"

# =============================================================================
# ÉTAPE 1 — Vérification OS Linux
# =============================================================================
step 1 "Vérification de l'environnement"

[[ "$(uname -s)" == "Linux" ]] || fatal "Ce script ne fonctionne que sur Linux."

# Détection du gestionnaire de paquets
if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
elif command -v pacman &>/dev/null; then
    PKG_MANAGER="pacman"
else
    fatal "Aucun gestionnaire de paquets reconnu (apt/dnf/yum/pacman)."
fi
ok "OS Linux détecté — gestionnaire de paquets : $PKG_MANAGER"

# Vérification des droits pour l'installation
if ! need_root && ! sudo -n true 2>/dev/null; then
    warn "Pas root et sudo requiert un mot de passe. L'installation peut demander votre mot de passe sudo."
fi

# Helper install package
pkg_install() {
    local pkg="$1"
    info "Installation de $pkg..."
    case "$PKG_MANAGER" in
        apt)    sudo apt-get install -y -qq "$pkg" >/dev/null 2>&1 ;;
        dnf|yum) sudo "$PKG_MANAGER" install -y -q "$pkg" >/dev/null 2>&1 ;;
        pacman) sudo pacman -S --noconfirm --quiet "$pkg" >/dev/null 2>&1 ;;
    esac
}

# Mise à jour index paquets (une seule fois, silencieuse)
UPDATE_DONE=false
pkg_update() {
    if [[ "$UPDATE_DONE" == false ]]; then
        info "Mise à jour de l'index des paquets..."
        case "$PKG_MANAGER" in
            apt)    sudo apt-get update -qq >/dev/null 2>&1 ;;
            dnf|yum) sudo "$PKG_MANAGER" makecache -q >/dev/null 2>&1 ;;
            pacman) sudo pacman -Sy --quiet >/dev/null 2>&1 ;;
        esac
        UPDATE_DONE=true
    fi
}

ok "Environnement validé"

# =============================================================================
# ÉTAPE 2 — Installation des dépendances système
# =============================================================================
step 2 "Vérification / installation des dépendances"

DEPS_TO_INSTALL=()

check_dep() {
    local cmd="$1" pkg="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        DEPS_TO_INSTALL+=("$pkg")
    fi
}

check_dep python3   python3
check_dep pip3      python3-pip
check_dep git       git
check_dep zip       zip
check_dep unzip     unzip
check_dep curl      curl
check_dep docker    docker.io

# python3-venv (apt spécifique)
if ! python3 -m venv --help &>/dev/null 2>&1; then
    DEPS_TO_INSTALL+=("python3-venv")
fi

if [[ ${#DEPS_TO_INSTALL[@]} -gt 0 ]]; then
    pkg_update
    for dep in "${DEPS_TO_INSTALL[@]}"; do
        pkg_install "$dep" || warn "Impossible d'installer $dep — continuons..."
    done
fi

# Docker daemon check
if command -v docker &>/dev/null && ! docker info &>/dev/null 2>&1; then
    warn "Docker installé mais daemon non démarré. Tentative de démarrage..."
    sudo systemctl start docker 2>/dev/null || warn "Impossible de démarrer Docker automatiquement."
    sudo systemctl enable docker 2>/dev/null || true
fi

ok "Dépendances système OK"

# =============================================================================
# ÉTAPE 3 — Installation BloodHound-Automation + BloodHound.py + AD-Miner
# =============================================================================
step 3 "Vérification / installation des outils AD"

mkdir -p "$BASE_DIR" "$PROJECTS_DIR"

# --- bloodhound-automation ---
if [[ ! -d "$BLOODHOUND_AUTOMATION" ]]; then
    info "Clonage de bloodhound-automation..."
    git clone --quiet https://github.com/dirkjanm/BloodHound-automation.git "$BLOODHOUND_AUTOMATION" \
        || fatal "Impossible de cloner bloodhound-automation."
else
    info "bloodhound-automation déjà présent — mise à jour..."
    git -C "$BLOODHOUND_AUTOMATION" pull --quiet 2>/dev/null || true
fi

if [[ ! -d "$VENV_BH" ]]; then
    info "Création du venv bloodhound-automation..."
    python3 -m venv "$VENV_BH"
    source "$VENV_BH/bin/activate"
    pip install --quiet --upgrade pip
    pip install --quiet -r "$BLOODHOUND_AUTOMATION/requirements.txt" 2>/dev/null \
        || pip install --quiet requests docker 2>/dev/null || true
    deactivate
fi
ok "bloodhound-automation OK"

# --- RustHound-CE / bloodhound-python venv ---
mkdir -p "$RUSTHOUND_DIR"

if [[ ! -d "$VENV_PYTHON" ]]; then
    info "Création du venv Python principal..."
    python3 -m venv "$VENV_PYTHON"
    source "$VENV_PYTHON/bin/activate"
    pip install --quiet --upgrade pip

    # bloodhound-python
    if ! command -v bloodhound-python &>/dev/null; then
        info "Installation de bloodhound-python..."
        pip install --quiet bloodhound 2>/dev/null || true
    fi

    # AD-Miner
    if ! command -v AD-miner &>/dev/null && ! pip show ad-miner &>/dev/null 2>&1; then
        info "Installation d'AD-Miner..."
        pip install --quiet ad-miner 2>/dev/null || true
    fi

    deactivate
else
    # Venv existant — vérif que bloodhound-python et AD-Miner sont là
    source "$VENV_PYTHON/bin/activate"
    if ! command -v bloodhound-python &>/dev/null; then
        info "bloodhound-python manquant — installation..."
        pip install --quiet bloodhound 2>/dev/null || true
    fi
    if ! command -v AD-miner &>/dev/null && ! pip show ad-miner &>/dev/null 2>&1; then
        info "AD-Miner manquant — installation..."
        pip install --quiet ad-miner 2>/dev/null || true
    fi
    deactivate
fi

ok "Outils Python OK"

# Vérifications finales
source "$VENV_PYTHON/bin/activate"
command -v bloodhound-python &>/dev/null || fatal "bloodhound-python introuvable après installation."
command -v AD-miner         &>/dev/null || fatal "AD-Miner introuvable après installation."
deactivate

# =============================================================================
# Saisie utilisateur
# =============================================================================
echo ""
echo -e "${DIM}Renseignez les informations de la cible :${RESET}\n"

read -rp  "  Nom du projet   : " PROJECT_NAME
read -rp  "  Domaine         : " DOMAIN
read -rp  "  Utilisateur     : " USERNAME
read -rsp "  Mot de passe    : " PASSWORD ; echo
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
# ÉTAPE 4 — Collecte LDAP via BloodHound.py
# =============================================================================
step 4 "Collecte LDAP — BloodHound.py"
info "Domaine : $DOMAIN  |  DC : $DC_IP  |  Utilisateur : $USERNAME"

source "$VENV_PYTHON/bin/activate"
cd "$PROJECT_DIR"

bloodhound-python \
    -d "$DOMAIN" \
    -u "$USERNAME" \
    -p "$PASSWORD" \
    -ns "$DC_IP" \
    -c All \
    --zip \
    2>&1 | tee "$PROJECT_DIR/collect.log" \
    | grep -E "^\[" || true

deactivate

ZIPFILE=$(ls -t "$PROJECT_DIR"/*.zip 2>/dev/null | head -1)

if [[ -z "$ZIPFILE" ]]; then
    info "Pas de ZIP direct, compression des JSON..."
    ZIPFILE="$PROJECT_DIR/${PROJECT_NAME}.zip"
    zip -j "$ZIPFILE" "$PROJECT_DIR"/*.json \
        && ok "ZIP créé : $(basename "$ZIPFILE")" \
        || fatal "Aucune donnée collectée. Vérifiez collect.log."
else
    ok "Données collectées : $(basename "$ZIPFILE")"
fi

# =============================================================================
# ÉTAPE 5 — Démarrage BloodHound CE
# =============================================================================
step 5 "Démarrage BloodHound CE"

source "$VENV_BH/bin/activate"

EXISTING=$(python3 "$BLOODHOUND_AUTOMATION/bloodhound-automation.py" list 2>/dev/null || true)

if echo "$EXISTING" | grep -q "$PROJECT_NAME"; then
    info "Projet '$PROJECT_NAME' existant — démarrage..."
    python3 "$BLOODHOUND_AUTOMATION/bloodhound-automation.py" start "$PROJECT_NAME" 2>&1 | tail -3 || true
else
    info "Création du projet '$PROJECT_NAME'..."
    python3 "$BLOODHOUND_AUTOMATION/bloodhound-automation.py" start \
        -bp "$BH_PORT_NEO4J" \
        -np "$BH_PORT_NEO4J_HTTP" \
        -wp "$BH_PORT_WEB" \
        "$PROJECT_NAME" 2>&1 | grep -E "^\[" || true
fi

ok "BloodHound CE actif sur http://localhost:${BH_PORT_WEB}"

# =============================================================================
# ÉTAPE 6 — Import des données
# =============================================================================
step 6 "Import des données dans BloodHound CE"

python3 "$BLOODHOUND_AUTOMATION/bloodhound-automation.py" data -z "$ZIPFILE" "$PROJECT_NAME" \
    2>&1 | grep -E "^\[|\[[\+\*\-]" || true

deactivate
ok "Import terminé"

# =============================================================================
# ÉTAPE 7 — Génération du rapport AD-Miner
# =============================================================================
step 7 "Génération du rapport AD-Miner"

source "$VENV_PYTHON/bin/activate"
cd "$PROJECT_DIR"

AD-miner -c \
    -cf "$PROJECT_NAME" \
    -b  "bolt://localhost:${BH_PORT_NEO4J}" \
    -u  "$NEO4J_USER" \
    -p  "$NEO4J_PASS" \
    2>&1 | tee "$PROJECT_DIR/ad-miner.log" \
    | grep -vE "^$" || true

deactivate

REPORT_DIR=$(ls -td "$PROJECT_DIR"/render_* 2>/dev/null | head -1)
[[ -n "$REPORT_DIR" ]] \
    && ok "Rapport généré dans $(basename "$REPORT_DIR")/" \
    || ok "Rapport généré (voir ad-miner.log)"

# =============================================================================
# Résumé
# =============================================================================
echo ""
echo -e "  ${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${BOLD}Projet          :${RESET} $PROJECT_NAME"
echo -e "  ${BOLD}Données         :${RESET} $PROJECT_DIR"
[[ -n "${REPORT_DIR:-}" ]] && echo -e "  ${BOLD}Rapport AD-Miner:${RESET} $REPORT_DIR/"
echo -e "  ${BOLD}Log collecte    :${RESET} $PROJECT_DIR/collect.log"
echo -e "  ${BOLD}Log AD-Miner    :${RESET} $PROJECT_DIR/ad-miner.log"
echo ""
echo -e "  ${DIM}BloodHound CE   : http://localhost:${BH_PORT_WEB}  (admin / ${BH_ADMIN_PASS})${RESET}"
echo -e "  ${DIM}Neo4j           : bolt://localhost:${BH_PORT_NEO4J}  (${NEO4J_USER} / ${NEO4J_PASS})${RESET}"
echo -e "  ${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
