#!/bin/bash
# =============================================================================
#  KrakenAD.sh — Audit Active Directory
#  Pipeline : bloodhound-python → Neo4j (Docker) → AD-Miner
#  Usage    : ./KrakenAD.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
BASE_DIR="${KRAKANAD_BASE:-/data}"
VENV_DIR="$BASE_DIR/krakanad-venv"
PROJECTS_DIR="$BASE_DIR/KrakenAD/projects"
COMPOSE_BASE="$BASE_DIR/KrakenAD/compose"

NEO4J_PORT="${NEO4J_PORT:-7687}"
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
CONTAINER_NEO4J=""
COMPOSE_FILE=""
COMPOSE_CMD=""
SAFE_NAME=""
PROJECT_DIR=""

cleanup() {
    local code=$?
    echo ""
    if [[ -n "$CONTAINER_NEO4J" && -n "$COMPOSE_FILE" && -n "$COMPOSE_CMD" && -n "$SAFE_NAME" ]]; then
        # Sauvegarder les logs avant extinction
        if [[ -n "$PROJECT_DIR" ]]; then
            docker logs "$CONTAINER_NEO4J" > "$PROJECT_DIR/docker-neo4j.log" 2>&1 || true
        fi
        info "Arret de Neo4j..."
        $COMPOSE_CMD -f "$COMPOSE_FILE" -p "krakanad-$SAFE_NAME" down \
            --remove-orphans --timeout 15 2>/dev/null \
            && ok "Neo4j arrete proprement." \
            || warn "Arret partiel — verifiez : docker ps"
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

# OS Linux
[[ "$(uname -s)" == "Linux" ]] || fatal "Linux requis."

# Gestionnaire de paquets
if   command -v apt-get &>/dev/null; then PKG="apt"
elif command -v dnf     &>/dev/null; then PKG="dnf"
elif command -v yum     &>/dev/null; then PKG="yum"
elif command -v pacman  &>/dev/null; then PKG="pacman"
else fatal "Gestionnaire de paquets non reconnu."; fi

pkg_install() {
    info "Installation : $1"
    case "$PKG" in
        apt)    sudo apt-get install -y -qq "$1" >/dev/null 2>&1 ;;
        dnf|yum) sudo "$PKG" install -y -q "$1" >/dev/null 2>&1 ;;
        pacman) sudo pacman -S --noconfirm --quiet "$1" >/dev/null 2>&1 ;;
    esac
}

_updated=false
pkg_update() {
    $_updated && return
    info "Mise a jour de l'index..."
    case "$PKG" in
        apt)    sudo apt-get update -qq >/dev/null 2>&1 ;;
        dnf|yum) sudo "$PKG" makecache -q >/dev/null 2>&1 ;;
        pacman) sudo pacman -Sy --quiet >/dev/null 2>&1 ;;
    esac
    _updated=true
}

# Dependances systeme
for dep in python3 pip3 zip unzip curl jq docker; do
    command -v "$dep" &>/dev/null || { pkg_update; pkg_install "${dep/pip3/python3-pip}"; }
done
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

# Venv Python + outils
mkdir -p "$BASE_DIR" "$PROJECTS_DIR" "$COMPOSE_BASE"
[[ -d "$VENV_DIR" ]] || python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip
command -v bloodhound-python &>/dev/null || pip install --quiet bloodhound
command -v AD-miner          &>/dev/null || pip install --quiet ad-miner
pip show neo4j &>/dev/null 2>&1          || pip install --quiet neo4j
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

SAFE_NAME="${PROJECT_NAME//[^a-zA-Z0-9_-]/_}"
CONTAINER_NEO4J="krakanad-${SAFE_NAME}-neo4j"
COMPOSE_DIR="$COMPOSE_BASE/$SAFE_NAME"
PROJECT_DIR="$PROJECTS_DIR/$PROJECT_NAME"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

mkdir -p "$PROJECT_DIR" "$COMPOSE_DIR/neo4j/data" \
         "$COMPOSE_DIR/neo4j/logs" "$COMPOSE_DIR/neo4j/import"

# Permissions pour Neo4j (UID 7474 dans le container)
chmod 777 "$COMPOSE_DIR/neo4j/data" \
          "$COMPOSE_DIR/neo4j/logs" \
          "$COMPOSE_DIR/neo4j/import"

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

# Trouver le ZIP
ZIPFILE=$(ls -t "$PROJECT_DIR"/*.zip 2>/dev/null | head -1 || true)
if [[ -z "$ZIPFILE" ]]; then
    ZIPFILE="$PROJECT_DIR/${PROJECT_NAME}.zip"
    info "Compression des JSON..."
    zip -j "$ZIPFILE" "$PROJECT_DIR"/*.json 2>/dev/null \
        || fatal "Aucune donnee collectee. Voir : $PROJECT_DIR/collect.log"
fi
ok "Collecte OK : $(basename "$ZIPFILE")"

# =============================================================================
# ETAPE 3 — DEMARRAGE NEO4J
# =============================================================================
step 3 "Demarrage Neo4j"

# Regenerer le docker-compose a chaque run (evite les conflits)
cat > "$COMPOSE_FILE" << COMPOSE
services:
  neo4j:
    image: neo4j:4.4
    container_name: ${CONTAINER_NEO4J}
    environment:
      - NEO4J_AUTH=${NEO4J_USER}/${NEO4J_PASS}
      - NEO4J_dbms_allow__upgrade=true
      - NEO4J_dbms_memory_heap_initial__size=512m
      - NEO4J_dbms_memory_heap_max__size=2g
      - NEO4J_dbms_memory_pagecache_size=1g
      - NEO4J_dbms_tx__log_rotation_retention__policy=2 files
      - NEO4J_dbms_tx__log_rotation_size=256m
      - NEO4J_dbms_checkpoint_interval_time=5m
      - NEO4J_dbms_logs_query_enabled=false
    ports:
      - "127.0.0.1:${NEO4J_PORT}:7687"
    volumes:
      - ${COMPOSE_DIR}/neo4j/data:/data
      - ${COMPOSE_DIR}/neo4j/logs:/logs
      - ${COMPOSE_DIR}/neo4j/import:/import
    healthcheck:
      test: ["CMD-SHELL", "cypher-shell -u ${NEO4J_USER} -p ${NEO4J_PASS} 'RETURN 1' || exit 1"]
      interval: 10s
      timeout: 10s
      retries: 20
      start_period: 40s
COMPOSE

info "Lancement du container..."
$COMPOSE_CMD -f "$COMPOSE_FILE" -p "krakanad-$SAFE_NAME" up -d 2>&1 \
    | grep -E "(Started|Created|Error)" || true

info "Attente Neo4j (max 2 min)..."
OK=false
for i in $(seq 1 24); do
    if docker exec "$CONTAINER_NEO4J" \
        cypher-shell -u "$NEO4J_USER" -p "$NEO4J_PASS" "RETURN 1" &>/dev/null 2>&1; then
        OK=true; break
    fi
    # Si echec auth : donnees existantes avec autre mdp → reset
    if docker exec "$CONTAINER_NEO4J" \
        cypher-shell -u "$NEO4J_USER" -p "bloodhoundcommunityedition" "RETURN 1" &>/dev/null 2>&1; then
        warn "Ancien mot de passe detecte — reset des donnees Neo4j..."
        $COMPOSE_CMD -f "$COMPOSE_FILE" -p "krakanad-$SAFE_NAME" down --timeout 5 2>/dev/null || true
        rm -rf "$COMPOSE_DIR/neo4j/data"
        mkdir -p "$COMPOSE_DIR/neo4j/data"
        chmod 777 "$COMPOSE_DIR/neo4j/data"
        $COMPOSE_CMD -f "$COMPOSE_FILE" -p "krakanad-$SAFE_NAME" up -d 2>/dev/null || true
    fi
    sleep 5
done
$OK || fatal "Neo4j n'a pas demarre.\nLogs : docker logs $CONTAINER_NEO4J"
ok "Neo4j actif sur bolt://localhost:$NEO4J_PORT"

# =============================================================================
# ETAPE 4 — IMPORT DES DONNEES DANS NEO4J
# =============================================================================
step 4 "Import des donnees BloodHound dans Neo4j"

# Extraire le ZIP dans le dossier import
info "Extraction du ZIP..."
rm -f "$COMPOSE_DIR/neo4j/import/"*.json 2>/dev/null || true
cp "$ZIPFILE" "$COMPOSE_DIR/neo4j/import/"
cd "$COMPOSE_DIR/neo4j/import"
unzip -o "$(basename "$ZIPFILE")" "*.json" 2>/dev/null || true
chmod 644 "$COMPOSE_DIR/neo4j/import/"*.json 2>/dev/null || true
cd "$PROJECT_DIR"

JSON_COUNT=$(ls "$COMPOSE_DIR/neo4j/import/"*.json 2>/dev/null | wc -l)
[[ "$JSON_COUNT" -eq 0 ]] && fatal "Aucun JSON dans le ZIP."
info "$JSON_COUNT fichiers JSON a importer"

source "$VENV_DIR/bin/activate"

python3 - "$NEO4J_PORT" "$NEO4J_USER" "$NEO4J_PASS" "$COMPOSE_DIR/neo4j/import" << 'PYEOF'
import json, os, glob, sys
from neo4j import GraphDatabase, warnings as neo4j_warnings
import warnings
warnings.filterwarnings("ignore")

port, user, pwd, import_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
driver = GraphDatabase.driver(f"bolt://localhost:{port}", auth=(user, pwd))

TYPE_MAP = {
    "users":"User","user":"User",
    "computers":"Computer","computer":"Computer",
    "groups":"Group","group":"Group",
    "domains":"Domain","domain":"Domain",
    "gpos":"GPO","gpo":"GPO",
    "ous":"OU","ou":"OU",
    "containers":"Container","container":"Container",
}

LABEL_MAP = {
    "User":"User","Computer":"Computer","Group":"Group",
    "Domain":"Domain","GPO":"GPO","OU":"OU","Container":"Container","Base":"Base",
}

def oid(item):
    v = (item.get("ObjectIdentifier") or item.get("objectidentifier") or
         item.get("Properties", {}).get("objectid", ""))
    return v.upper() if v else ""

def lbl(t):
    return LABEL_MAP.get(t, "Base")

# Contraintes
with driver.session() as s:
    for q in [
        "CREATE CONSTRAINT user_oid      IF NOT EXISTS FOR (n:User)      REQUIRE n.objectid IS UNIQUE",
        "CREATE CONSTRAINT computer_oid  IF NOT EXISTS FOR (n:Computer)  REQUIRE n.objectid IS UNIQUE",
        "CREATE CONSTRAINT group_oid     IF NOT EXISTS FOR (n:Group)     REQUIRE n.objectid IS UNIQUE",
        "CREATE CONSTRAINT domain_oid    IF NOT EXISTS FOR (n:Domain)    REQUIRE n.objectid IS UNIQUE",
        "CREATE CONSTRAINT gpo_oid       IF NOT EXISTS FOR (n:GPO)       REQUIRE n.objectid IS UNIQUE",
        "CREATE CONSTRAINT ou_oid        IF NOT EXISTS FOR (n:OU)        REQUIRE n.objectid IS UNIQUE",
        "CREATE CONSTRAINT container_oid IF NOT EXISTS FOR (n:Container) REQUIRE n.objectid IS UNIQUE",
    ]:
        try: s.run(q)
        except: pass

tn, tr = 0, 0

for jf in sorted(glob.glob(os.path.join(import_dir, "*.json"))):
    fname = os.path.basename(jf)
    try:
        data = json.load(open(jf, encoding="utf-8"))
    except Exception as e:
        print(f"    ! {fname}: {e}", flush=True); continue

    dtype = data.get("meta", {}).get("type", "").lower()
    items = data.get("data", [])
    if not items:
        continue

    label = TYPE_MAP.get(dtype, dtype.capitalize() or "Base")
    nc = rc = 0

    # Batch par 500 pour eviter les timeouts
    BATCH = 500
    for i in range(0, len(items), BATCH):
        batch = items[i:i+BATCH]
        with driver.session() as s:
            with s.begin_transaction() as tx:
                for item in batch:
                    o = oid(item)
                    if not o: continue

                    # Proprietes
                    props = {k.lower(): v
                             for k, v in item.get("Properties", {}).items()
                             if not isinstance(v, (dict, list))}
                    props["objectid"] = o
                    try:
                        tx.run("MERGE (n:" + label + " {objectid:$o}) SET n+=$p",
                               o=o, p=props)
                        nc += 1
                    except: pass

                    # MemberOf
                    for m in item.get("Members", []):
                        t = oid(m) if isinstance(m, dict) else str(m).upper()
                        tl = lbl(m.get("ObjectType", "Base") if isinstance(m, dict) else "Base")
                        if t:
                            try:
                                tx.run("MERGE (a:"+tl+" {objectid:$t}) MERGE (b:"+label+" {objectid:$o}) MERGE (a)-[:MemberOf]->(b)", t=t, o=o)
                                rc += 1
                            except: pass

                    # Contains
                    for m in item.get("ChildObjects", []):
                        t = oid(m) if isinstance(m, dict) else str(m).upper()
                        tl = lbl(m.get("ObjectType", "Base") if isinstance(m, dict) else "Base")
                        if t:
                            try:
                                tx.run("MERGE (a:"+label+" {objectid:$o}) MERGE (b:"+tl+" {objectid:$t}) MERGE (a)-[:Contains]->(b)", o=o, t=t)
                                rc += 1
                            except: pass

                    # AdminTo
                    for m in item.get("LocalAdmins", {}).get("Results", []):
                        t = oid(m) if isinstance(m, dict) else str(m).upper()
                        tl = lbl(m.get("ObjectType", "Base") if isinstance(m, dict) else "Base")
                        if t:
                            try:
                                tx.run("MERGE (a:"+tl+" {objectid:$t}) MERGE (b:"+label+" {objectid:$o}) MERGE (a)-[:AdminTo]->(b)", t=t, o=o)
                                rc += 1
                            except: pass

                    # HasSession
                    for m in item.get("Sessions", {}).get("Results", []):
                        if not isinstance(m, dict): continue
                        t = m.get("UserSID", "").upper()
                        if t:
                            try:
                                tx.run("MERGE (u:User {objectid:$t}) MERGE (c:"+label+" {objectid:$o}) MERGE (c)-[:HasSession]->(u)", t=t, o=o)
                                rc += 1
                            except: pass

                    # ACL
                    for ace in item.get("Aces", []):
                        if not isinstance(ace, dict): continue
                        t = ace.get("PrincipalSID", "").upper()
                        tl = lbl(ace.get("PrincipalType", "Base"))
                        rt = ace.get("RightName", "")
                        if t and rt:
                            try:
                                tx.run("MERGE (a:"+tl+" {objectid:$t}) MERGE (b:"+label+" {objectid:$o}) MERGE (a)-[:"+rt+"]->(b)", t=t, o=o)
                                rc += 1
                            except: pass

    tn += nc; tr += rc
    print(f"    v  {fname}: {nc} noeuds, {rc} relations", flush=True)

print(f"    v  Total : {tn} noeuds, {tr} relations", flush=True)
driver.close()
PYEOF

deactivate
ok "Import Neo4j termine"

# =============================================================================
# ETAPE 5 — RAPPORT AD-MINER
# =============================================================================
step 5 "Generation du rapport AD-Miner"

source "$VENV_DIR/bin/activate"
cd "$PROJECT_DIR"

AD-miner \
    -c \
    -cf "$PROJECT_NAME" \
    -b  "bolt://localhost:$NEO4J_PORT" \
    -u  "$NEO4J_USER" \
    -p  "$NEO4J_PASS" \
    -d  "$DOMAIN" \
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
echo -e "  ${DIM}(Neo4j arrete automatiquement)${RESET}"
echo -e "  ${CYAN}${BOLD}==========================================${RESET}"
echo ""
