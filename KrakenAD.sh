#!/bin/bash
# =============================================================================
#  KrakenAD.sh
#  Collecte Active Directory + BloodHound CE (Docker natif) + rapport AD-Miner
#  Usage : ./KrakenAD.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Configuration ------------------------------------------------------------
BASE_DIR="${KRAKANAD_BASE:-/data}"
RUSTHOUND_DIR="$BASE_DIR/RustHound-CE"
VENV_PYTHON="$RUSTHOUND_DIR/.venv"
PROJECTS_DIR="$BASE_DIR/KrakenAD/projects"

BH_PORT_WEB="${BH_PORT_WEB:-8080}"
BH_PORT_NEO4J="${BH_PORT_NEO4J:-7687}"
NEO4J_USER="neo4j"
NEO4J_PASS="bloodhoundcommunityedition"
BH_ADMIN_EMAIL="admin@krakenad.local"
BH_ADMIN_PASS="KrakenAD2024!"

TOTAL_STEPS=7

# -- Couleurs -----------------------------------------------------------------
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"
BOLD="\e[1m"; DIM="\e[2m"; RESET="\e[0m"

step()  { echo -e "\n${CYAN}${BOLD}[${1}/${TOTAL_STEPS}]${RESET} ${BOLD}${2}${RESET}"; }
ok()    { echo -e "    ${GREEN}✔${RESET}  ${1}"; }
info()  { echo -e "    ${YELLOW}→${RESET}  ${1}"; }
warn()  { echo -e "    ${YELLOW}⚠${RESET}  ${1}"; }
fatal() { echo -e "\n${RED}${BOLD}[ERREUR]${RESET} ${1}\n"; exit 1; }

# -- Nettoyage automatique (fin normale, erreur ou Ctrl+C) --------------------
cleanup() {
    local exit_code=$?
    echo ""
    if [[ -n "${COMPOSE_FILE:-}" && -n "${COMPOSE_CMD:-}" && -n "${SAFE_NAME:-}" ]]; then
        # Sauvegarde des logs Docker avant extinction
        if [[ -n "${PROJECT_DIR:-}" ]]; then
            docker logs "${CONTAINER_BH:-}"       > "${PROJECT_DIR}/docker-bloodhound.log" 2>&1 || true
            docker logs "${CONTAINER_NEO4J:-}"    > "${PROJECT_DIR}/docker-neo4j.log"     2>&1 || true
            docker logs "${CONTAINER_PG:-}"       > "${PROJECT_DIR}/docker-postgres.log"  2>&1 || true
            echo -e "  ${YELLOW}→${RESET}  Logs Docker sauvegardés dans $PROJECT_DIR/"
        fi
        echo -e "  ${YELLOW}→${RESET}  Arrêt des containers BloodHound CE..."
        $COMPOSE_CMD -f "$COMPOSE_FILE" -p "krakanad-${SAFE_NAME}" down \
            --timeout 10 2>/dev/null \
            && echo -e "  ${GREEN}✔${RESET}  Containers arrêtés proprement." \
            || echo -e "  ${YELLOW}⚠${RESET}  Arrêt partiel — vérifiez avec : docker ps"
    fi
    exit $exit_code
}
trap cleanup EXIT

# -- Bannière -----------------------------------------------------------------
clear
echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║         AUDIT ACTIVE DIRECTORY        ║"
echo "  ║   BloodHound CE  ·  AD-Miner          ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${RESET}"

# =============================================================================
# ÉTAPE 1 — Vérification de l'environnement
# =============================================================================
step 1 "Vérification de l'environnement"

[[ "$(uname -s)" == "Linux" ]] || fatal "Ce script ne fonctionne que sur Linux."

if command -v apt-get &>/dev/null; then   PKG_MANAGER="apt"
elif command -v dnf &>/dev/null; then     PKG_MANAGER="dnf"
elif command -v yum &>/dev/null; then     PKG_MANAGER="yum"
elif command -v pacman &>/dev/null; then  PKG_MANAGER="pacman"
else fatal "Aucun gestionnaire de paquets reconnu (apt/dnf/yum/pacman)."; fi

ok "OS Linux — gestionnaire : $PKG_MANAGER"

UPDATE_DONE=false
pkg_update() {
    $UPDATE_DONE && return
    info "Mise à jour de l'index des paquets..."
    case "$PKG_MANAGER" in
        apt)     sudo apt-get update -qq >/dev/null 2>&1 ;;
        dnf|yum) sudo "$PKG_MANAGER" makecache -q >/dev/null 2>&1 ;;
        pacman)  sudo pacman -Sy --quiet >/dev/null 2>&1 ;;
    esac
    UPDATE_DONE=true
}

pkg_install() {
    local pkg="$1"
    info "Installation de $pkg..."
    case "$PKG_MANAGER" in
        apt)     sudo apt-get install -y -qq "$pkg" >/dev/null 2>&1 ;;
        dnf|yum) sudo "$PKG_MANAGER" install -y -q "$pkg" >/dev/null 2>&1 ;;
        pacman)  sudo pacman -S --noconfirm --quiet "$pkg" >/dev/null 2>&1 ;;
    esac
}

ok "Environnement validé"

# =============================================================================
# ÉTAPE 2 — Dépendances système
# =============================================================================
step 2 "Vérification / installation des dépendances"

DEPS_TO_INSTALL=()
check_dep() { command -v "$1" &>/dev/null || DEPS_TO_INSTALL+=("${2:-$1}"); }

check_dep python3  python3
check_dep pip3     python3-pip
check_dep git      git
check_dep zip      zip
check_dep unzip    unzip
check_dep curl     curl
check_dep jq       jq
check_dep docker   docker.io

python3 -m venv --help &>/dev/null 2>&1 || DEPS_TO_INSTALL+=("python3-venv")

if [[ ${#DEPS_TO_INSTALL[@]} -gt 0 ]]; then
    pkg_update
    for dep in "${DEPS_TO_INSTALL[@]}"; do
        pkg_install "$dep" || warn "Impossible d'installer $dep"
    done
fi

# Docker Compose
COMPOSE_CMD=""
if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    info "Installation docker-compose-plugin..."
    pkg_update
    pkg_install docker-compose-plugin 2>/dev/null || pkg_install docker-compose 2>/dev/null || true
    docker compose version &>/dev/null 2>&1 && COMPOSE_CMD="docker compose"
    command -v docker-compose &>/dev/null && COMPOSE_CMD="docker-compose"
    [[ -z "$COMPOSE_CMD" ]] && fatal "docker compose introuvable après installation."
fi

# Docker daemon
if ! docker info &>/dev/null 2>&1; then
    warn "Docker daemon non démarré — tentative..."
    sudo systemctl start docker 2>/dev/null || fatal "Impossible de démarrer Docker."
    sudo systemctl enable docker 2>/dev/null || true
    sleep 3
fi
docker info &>/dev/null 2>&1 || fatal "Docker inaccessible. Ajoutez votre user au groupe docker ou lancez en root."

ok "Dépendances système OK"

# =============================================================================
# ÉTAPE 3 — Outils Python (bloodhound-python + AD-Miner)
# =============================================================================
step 3 "Vérification / installation des outils Python"

mkdir -p "$BASE_DIR" "$PROJECTS_DIR" "$RUSTHOUND_DIR"

[[ -d "$VENV_PYTHON" ]] || { info "Création du venv Python..."; python3 -m venv "$VENV_PYTHON"; }

source "$VENV_PYTHON/bin/activate"
pip install --quiet --upgrade pip

command -v bloodhound-python &>/dev/null \
    || { info "Installation bloodhound-python..."; pip install --quiet bloodhound; }

command -v AD-miner &>/dev/null \
    || { info "Installation AD-Miner..."; pip install --quiet ad-miner; }

command -v bloodhound-python &>/dev/null || fatal "bloodhound-python introuvable."
command -v AD-miner          &>/dev/null || fatal "AD-Miner introuvable."
deactivate

ok "Outils Python OK"

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

# Noms de containers uniques par projet (évite les conflits)
SAFE_NAME="${PROJECT_NAME//[^a-zA-Z0-9_-]/_}"
CONTAINER_NEO4J="krakanad-${SAFE_NAME}-neo4j"
CONTAINER_PG="krakanad-${SAFE_NAME}-postgres"
CONTAINER_BH="krakanad-${SAFE_NAME}-bloodhound"
COMPOSE_DIR="$BASE_DIR/KrakenAD/compose/${SAFE_NAME}"
PROJECT_DIR="$PROJECTS_DIR/$PROJECT_NAME"

mkdir -p "$PROJECT_DIR" "$COMPOSE_DIR" \
    "$COMPOSE_DIR/neo4j/data" "$COMPOSE_DIR/neo4j/logs" \
    "$COMPOSE_DIR/postgres/data"

# =============================================================================
# ÉTAPE 4 — Collecte LDAP
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
    2>&1 | tee "$PROJECT_DIR/collect.log" | grep -E "^\[" || true

deactivate

ZIPFILE=$(ls -t "$PROJECT_DIR"/*.zip 2>/dev/null | head -1 || true)

if [[ -z "$ZIPFILE" ]]; then
    info "Pas de ZIP — compression des JSON..."
    ZIPFILE="$PROJECT_DIR/${PROJECT_NAME}.zip"
    zip -j "$ZIPFILE" "$PROJECT_DIR"/*.json 2>/dev/null \
        || fatal "Aucune donnée collectée. Vérifiez $PROJECT_DIR/collect.log"
fi

ok "Données collectées : $(basename "$ZIPFILE")"

# =============================================================================
# ÉTAPE 5 — BloodHound CE via Docker (gestion native)
# =============================================================================
step 5 "Démarrage BloodHound CE"

# Génération / réutilisation du mot de passe Postgres
ENV_FILE="$COMPOSE_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    PG_PASS=$(grep "^PG_PASS=" "$ENV_FILE" | cut -d= -f2)
fi
PG_PASS="${PG_PASS:-$(openssl rand -hex 16 2>/dev/null || echo "krakanadpgpass")}"
echo "PG_PASS=${PG_PASS}" > "$ENV_FILE"

COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
cat > "$COMPOSE_FILE" <<COMPOSE
services:

  neo4j:
    image: neo4j:4.4
    container_name: ${CONTAINER_NEO4J}
    restart: unless-stopped
    environment:
      - NEO4J_AUTH=${NEO4J_USER}/${NEO4J_PASS}
      - NEO4J_dbms_allow__upgrade=true
    ports:
      - "127.0.0.1:${BH_PORT_NEO4J}:7687"
    volumes:
      - ${COMPOSE_DIR}/neo4j/data:/data
      - ${COMPOSE_DIR}/neo4j/logs:/logs
    healthcheck:
      test: ["CMD-SHELL", "cypher-shell -u ${NEO4J_USER} -p ${NEO4J_PASS} 'RETURN 1' || exit 1"]
      interval: 10s
      timeout: 10s
      retries: 20
      start_period: 40s

  postgres:
    image: postgres:16
    container_name: ${CONTAINER_PG}
    restart: unless-stopped
    environment:
      - POSTGRES_USER=bloodhound
      - POSTGRES_PASSWORD=${PG_PASS}
      - POSTGRES_DB=bloodhound
    volumes:
      - ${COMPOSE_DIR}/postgres/data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "bloodhound"]
      interval: 10s
      timeout: 5s
      retries: 10

  bloodhound:
    image: specterops/bloodhound:latest
    container_name: ${CONTAINER_BH}
    restart: unless-stopped
    environment:
      - bhe_database_connection=user=bloodhound password=${PG_PASS} dbname=bloodhound host=postgres
      - bhe_neo4j_connection=neo4j://neo4j:${NEO4J_PASS}@neo4j:7687/
      - bhe_default_admin_principal_name=${BH_ADMIN_EMAIL}
      - bhe_default_admin_password=${BH_ADMIN_PASS}
    ports:
      - "127.0.0.1:${BH_PORT_WEB}:8080"
    depends_on:
      postgres:
        condition: service_healthy
      neo4j:
        condition: service_healthy

COMPOSE

info "Démarrage des containers..."
$COMPOSE_CMD -f "$COMPOSE_FILE" -p "krakanad-${SAFE_NAME}" up -d 2>&1 \
    | grep -E "(Started|Running|Created|Error|error)" || true

# -- Attente Neo4j ------------------------------------------------------------
info "Attente de Neo4j (jusqu'à 2 min)..."
NEO4J_OK=false
for i in $(seq 1 24); do
    if docker exec "$CONTAINER_NEO4J" \
        cypher-shell -u "$NEO4J_USER" -p "$NEO4J_PASS" "RETURN 1" \
        &>/dev/null 2>&1; then
        NEO4J_OK=true; break
    fi
    sleep 5
done
$NEO4J_OK || fatal "Neo4j n'a pas démarré.
Logs : docker logs $CONTAINER_NEO4J"

# -- Attente BloodHound API ---------------------------------------------------
info "Attente de BloodHound CE API (jusqu'à 2 min)..."
BH_OK=false
for i in $(seq 1 24); do
    if curl -sf "http://localhost:${BH_PORT_WEB}/api/version" &>/dev/null; then
        BH_OK=true; break
    fi
    sleep 5
done
$BH_OK || fatal "BloodHound CE API inaccessible.
Logs : docker logs $CONTAINER_BH"

ok "BloodHound CE actif → http://localhost:${BH_PORT_WEB}"

# =============================================================================
# ÉTAPE 6 — Import via API BloodHound CE
# =============================================================================
step 6 "Import des données dans BloodHound CE"

# --- Authentification --------------------------------------------------------
info "Authentification sur l'API..."

LOGIN_RESP=$(curl -sf \
    -X POST "http://localhost:${BH_PORT_WEB}/api/v2/login" \
    -H "Content-Type: application/json" \
    -d "{\"login_method\":\"secret\",\"principal\":\"${BH_ADMIN_EMAIL}\",\"secret\":\"${BH_ADMIN_PASS}\"}" \
    2>/dev/null || echo "{}")

BH_TOKEN=$(echo "$LOGIN_RESP" | jq -r '.data.session_token // empty' 2>/dev/null || true)

if [[ -z "$BH_TOKEN" ]]; then
    fatal "Authentification échouée sur BloodHound CE.
  Réponse : $LOGIN_RESP
  → Vérifiez les credentials : ${BH_ADMIN_EMAIL} / ${BH_ADMIN_PASS}
  → Logs container : docker logs $CONTAINER_BH"
fi

ok "Authentification OK (token obtenu)"

# --- Upload du ZIP -----------------------------------------------------------
info "Démarrage de la session d'upload..."

START_RESP=$(curl -sf \
    -X POST "http://localhost:${BH_PORT_WEB}/api/v2/file-upload/start" \
    -H "Authorization: Bearer $BH_TOKEN" \
    -H "Content-Type: application/json" \
    2>/dev/null || echo "{}")

UPLOAD_ID=$(echo "$START_RESP" | jq -r '.data.id // empty' 2>/dev/null || true)

if [[ -z "$UPLOAD_ID" ]]; then
    fatal "Impossible de créer une session d'upload.
  Réponse : $START_RESP
  → API BH peut différer selon la version. Logs : docker logs $CONTAINER_BH"
fi

info "Upload de $(basename "$ZIPFILE") (taille : $(du -sh "$ZIPFILE" | cut -f1))..."

curl -sf \
    -X POST "http://localhost:${BH_PORT_WEB}/api/v2/file-upload/${UPLOAD_ID}" \
    -H "Authorization: Bearer $BH_TOKEN" \
    -H "Content-Type: application/zip" \
    --data-binary "@${ZIPFILE}" \
    &>/dev/null || fatal "Erreur lors du transfert du fichier ZIP."

curl -sf \
    -X POST "http://localhost:${BH_PORT_WEB}/api/v2/file-upload/${UPLOAD_ID}/end" \
    -H "Authorization: Bearer $BH_TOKEN" \
    &>/dev/null || warn "Fin de session d'upload incertaine"

ok "Fichier uploadé (session ID: $UPLOAD_ID)"

# --- Attente ingestion -------------------------------------------------------
info "Attente de l'ingestion (jusqu'à 5 min)..."
INGESTED=false
for i in $(seq 1 30); do
    sleep 10
    STATUS=$(curl -sf \
        "http://localhost:${BH_PORT_WEB}/api/v2/file-upload" \
        -H "Authorization: Bearer $BH_TOKEN" 2>/dev/null \
        | jq -r '.data[-1].status // "unknown"' 2>/dev/null || echo "unknown")

    case "$STATUS" in
        Complete|3)  ok "Ingestion terminée"; INGESTED=true; break ;;
        Failed|4)    warn "Ingestion signalée comme échouée (données peut-être partielles)"; break ;;
        *)           [[ $((i % 3)) -eq 0 ]] && info "Ingestion en cours... (${i}0s / statut: $STATUS)" ;;
    esac
done
$INGESTED || warn "Ingestion timeout — les données sont peut-être partiellement importées"

ok "Import terminé"

# =============================================================================
# ÉTAPE 7 — Rapport AD-Miner
# =============================================================================
step 7 "Génération du rapport AD-Miner"

source "$VENV_PYTHON/bin/activate"
cd "$PROJECT_DIR"

AD-miner -c \
    -cf "$PROJECT_NAME" \
    -b  "bolt://localhost:${BH_PORT_NEO4J}" \
    -u  "$NEO4J_USER" \
    -p  "$NEO4J_PASS" \
    2>&1 | tee "$PROJECT_DIR/ad-miner.log" | grep -vE "^$" || true

deactivate

REPORT_DIR=$(ls -td "$PROJECT_DIR"/render_* 2>/dev/null | head -1 || true)
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
[[ -n "${REPORT_DIR:-}" ]] && \
echo -e "  ${BOLD}Rapport AD-Miner:${RESET} $REPORT_DIR/"
echo -e "  ${BOLD}Log collecte    :${RESET} $PROJECT_DIR/collect.log"
echo -e "  ${BOLD}Log AD-Miner    :${RESET} $PROJECT_DIR/ad-miner.log"
echo ""
echo -e "  ${DIM}BloodHound CE   : http://localhost:${BH_PORT_WEB}"
echo -e "  Login           : ${BH_ADMIN_EMAIL}  /  ${BH_ADMIN_PASS}"
echo -e "  Neo4j bolt      : bolt://localhost:${BH_PORT_NEO4J}  (${NEO4J_USER} / ${NEO4J_PASS})"
echo -e "  (Les containers sont arrêtés automatiquement à la fin du script)${RESET}"
echo -e "  ${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
