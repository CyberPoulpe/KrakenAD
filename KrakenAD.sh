#!/bin/bash
# =============================================================================
#  KrakenAD.sh
#  Collecte AD → Neo4j → rapport AD-Miner
#  Pas besoin de BloodHound CE UI
#  Usage : ./KrakenAD.sh
# =============================================================================

set -euo pipefail

# -- Configuration ------------------------------------------------------------
BASE_DIR="${KRAKANAD_BASE:-/data}"
RUSTHOUND_DIR="$BASE_DIR/RustHound-CE"
VENV_PYTHON="$RUSTHOUND_DIR/.venv"
PROJECTS_DIR="$BASE_DIR/KrakenAD/projects"

BH_PORT_NEO4J="${BH_PORT_NEO4J:-7687}"
NEO4J_USER="neo4j"
NEO4J_PASS="neo5j"

TOTAL_STEPS=5

# -- Couleurs -----------------------------------------------------------------
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"
BOLD="\e[1m"; DIM="\e[2m"; RESET="\e[0m"

step()  { echo -e "\n${CYAN}${BOLD}[${1}/${TOTAL_STEPS}]${RESET} ${BOLD}${2}${RESET}"; }
ok()    { echo -e "    ${GREEN}✔${RESET}  ${1}"; }
info()  { echo -e "    ${YELLOW}→${RESET}  ${1}"; }
warn()  { echo -e "    ${YELLOW}⚠${RESET}  ${1}"; }
fatal() { echo -e "\n${RED}${BOLD}[ERREUR]${RESET} ${1}\n"; exit 1; }

# -- Nettoyage automatique ----------------------------------------------------
cleanup() {
    local exit_code=$?
    echo ""
    if [[ -n "${COMPOSE_FILE:-}" && -n "${COMPOSE_CMD:-}" && -n "${SAFE_NAME:-}" ]]; then
        if [[ -n "${PROJECT_DIR:-}" ]]; then
            docker logs "${CONTAINER_NEO4J:-}" > "${PROJECT_DIR}/docker-neo4j.log" 2>&1 || true
        fi
        echo -e "  ${YELLOW}→${RESET}  Arret de Neo4j..."
        $COMPOSE_CMD -f "$COMPOSE_FILE" -p "krakanad-${SAFE_NAME}" down \
            --timeout 10 2>/dev/null \
            && echo -e "  ${GREEN}✔${RESET}  Neo4j arrete proprement." \
            || echo -e "  ${YELLOW}⚠${RESET}  Arret partiel — verifiez : docker ps"
    fi
    exit $exit_code
}
trap cleanup EXIT

# -- Banniere -----------------------------------------------------------------
clear
echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║         AUDIT ACTIVE DIRECTORY        ║"
echo "  ║      Neo4j  ·  AD-Miner               ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${RESET}"

# =============================================================================
# ETAPE 1 — Dependances
# =============================================================================
step 1 "Verification de l'environnement"

[[ "$(uname -s)" == "Linux" ]] || fatal "Ce script ne fonctionne que sur Linux."

if   command -v apt-get &>/dev/null; then PKG_MANAGER="apt"
elif command -v dnf     &>/dev/null; then PKG_MANAGER="dnf"
elif command -v yum     &>/dev/null; then PKG_MANAGER="yum"
elif command -v pacman  &>/dev/null; then PKG_MANAGER="pacman"
else fatal "Aucun gestionnaire de paquets reconnu."; fi

UPDATE_DONE=false
pkg_update() {
    $UPDATE_DONE && return
    case "$PKG_MANAGER" in
        apt)     sudo apt-get update -qq >/dev/null 2>&1 ;;
        dnf|yum) sudo "$PKG_MANAGER" makecache -q >/dev/null 2>&1 ;;
        pacman)  sudo pacman -Sy --quiet >/dev/null 2>&1 ;;
    esac
    UPDATE_DONE=true
}

pkg_install() {
    case "$PKG_MANAGER" in
        apt)     sudo apt-get install -y -qq "$1" >/dev/null 2>&1 ;;
        dnf|yum) sudo "$PKG_MANAGER" install -y -q "$1" >/dev/null 2>&1 ;;
        pacman)  sudo pacman -S --noconfirm --quiet "$1" >/dev/null 2>&1 ;;
    esac
}

DEPS_TO_INSTALL=()
check_dep() { command -v "$1" &>/dev/null || DEPS_TO_INSTALL+=("${2:-$1}"); }
check_dep python3  python3
check_dep pip3     python3-pip
check_dep zip      zip
check_dep unzip    unzip
check_dep curl     curl
check_dep docker   docker.io
python3 -m venv --help &>/dev/null 2>&1 || DEPS_TO_INSTALL+=("python3-venv")

if [[ ${#DEPS_TO_INSTALL[@]} -gt 0 ]]; then
    pkg_update
    for dep in "${DEPS_TO_INSTALL[@]}"; do
        info "Installation de $dep..."
        pkg_install "$dep" || warn "Impossible d'installer $dep"
    done
fi

# Docker Compose
COMPOSE_CMD=""
docker compose version &>/dev/null 2>&1 && COMPOSE_CMD="docker compose"
command -v docker-compose &>/dev/null  && COMPOSE_CMD="docker-compose"
if [[ -z "$COMPOSE_CMD" ]]; then
    pkg_update
    pkg_install docker-compose-plugin 2>/dev/null || pkg_install docker-compose 2>/dev/null || true
    docker compose version &>/dev/null 2>&1 && COMPOSE_CMD="docker compose"
    [[ -z "$COMPOSE_CMD" ]] && fatal "docker compose introuvable."
fi

if ! docker info &>/dev/null 2>&1; then
    sudo systemctl start docker 2>/dev/null || fatal "Impossible de demarrer Docker."
    sleep 3
fi
docker info &>/dev/null 2>&1 || fatal "Docker inaccessible."

# Python venv
mkdir -p "$BASE_DIR" "$PROJECTS_DIR" "$RUSTHOUND_DIR"
[[ -d "$VENV_PYTHON" ]] || python3 -m venv "$VENV_PYTHON"
source "$VENV_PYTHON/bin/activate"
pip install --quiet --upgrade pip
command -v bloodhound-python &>/dev/null || pip install --quiet bloodhound
command -v AD-miner          &>/dev/null || pip install --quiet ad-miner
command -v bloodhound-python &>/dev/null || fatal "bloodhound-python introuvable."
command -v AD-miner          &>/dev/null || fatal "AD-Miner introuvable."
deactivate

ok "Environnement OK"

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

SAFE_NAME="${PROJECT_NAME//[^a-zA-Z0-9_-]/_}"
CONTAINER_NEO4J="krakanad-${SAFE_NAME}-neo4j"
COMPOSE_DIR="$BASE_DIR/KrakenAD/compose/${SAFE_NAME}"
PROJECT_DIR="$PROJECTS_DIR/$PROJECT_NAME"

mkdir -p "$PROJECT_DIR" "$COMPOSE_DIR" \
    "$COMPOSE_DIR/neo4j/data" "$COMPOSE_DIR/neo4j/logs" \
    "$COMPOSE_DIR/neo4j/import"

# =============================================================================
# ETAPE 2 — Collecte LDAP
# =============================================================================
step 2 "Collecte LDAP — BloodHound.py"
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
        || fatal "Aucune donnee collectee. Verifiez $PROJECT_DIR/collect.log"
fi

ok "Donnees collectees : $(basename "$ZIPFILE")"

# =============================================================================
# ETAPE 3 — Demarrage Neo4j
# =============================================================================
step 3 "Demarrage Neo4j"

COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
cat > "$COMPOSE_FILE" << COMPOSE
services:
  neo4j:
    image: neo4j:4.4
    container_name: ${CONTAINER_NEO4J}
    restart: unless-stopped
    environment:
      - NEO4J_AUTH=${NEO4J_USER}/${NEO4J_PASS}
      - NEO4J_dbms_allow__upgrade=true
      - NEO4J_dbms_memory_heap_initial__size=512m
      - NEO4J_dbms_memory_heap_max__size=2g
    ports:
      - "127.0.0.1:${BH_PORT_NEO4J}:7687"
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

info "Lancement de Neo4j..."
$COMPOSE_CMD -f "$COMPOSE_FILE" -p "krakanad-${SAFE_NAME}" up -d 2>&1 \
    | grep -E "(Started|Running|Created|Error)" || true

info "Attente de Neo4j (jusqu'a 2 min)..."
NEO4J_OK=false
for i in $(seq 1 24); do
    if docker exec "$CONTAINER_NEO4J" \
        cypher-shell -u "$NEO4J_USER" -p "$NEO4J_PASS" "RETURN 1" &>/dev/null 2>&1; then
        NEO4J_OK=true; break
    fi
    sleep 5
done
$NEO4J_OK || fatal "Neo4j n'a pas demarre. Logs : docker logs $CONTAINER_NEO4J"

ok "Neo4j actif sur bolt://localhost:${BH_PORT_NEO4J}"

# =============================================================================
# ETAPE 4 — Import des donnees dans Neo4j
# =============================================================================
step 4 "Import des donnees dans Neo4j"

# Copier le ZIP dans le dossier import Neo4j et dezipper
info "Preparation des fichiers JSON..."
rm -f "$COMPOSE_DIR/neo4j/import/"*.json 2>/dev/null || true
cp "$ZIPFILE" "$COMPOSE_DIR/neo4j/import/"
cd "$COMPOSE_DIR/neo4j/import"
unzip -o "$(basename "$ZIPFILE")" "*.json" 2>/dev/null || true

JSON_FILES=("$COMPOSE_DIR/neo4j/import/"*.json)
[[ ${#JSON_FILES[@]} -eq 0 ]] && fatal "Aucun fichier JSON trouve dans le ZIP."
info "Fichiers a importer : ${#JSON_FILES[@]} JSON"

# Utiliser bloodhound-python pour importer directement dans Neo4j
# via le module neo4j de bloodhound
source "$VENV_PYTHON/bin/activate"

# Installer neo4j python driver si besoin
pip install --quiet neo4j 2>/dev/null || true

python3 - "${BH_PORT_NEO4J}" "${NEO4J_USER}" "${NEO4J_PASS}" "${COMPOSE_DIR}/neo4j/import" << 'PYEOF'
import json, os, glob, sys
from neo4j import GraphDatabase

port, user, password, import_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
uri = f"bolt://localhost:{port}"
driver = GraphDatabase.driver(uri, auth=(user, password))
json_files = glob.glob(os.path.join(import_dir, "*.json"))

print(f"    → Import de {len(json_files)} fichiers JSON dans Neo4j...")

# Contraintes Neo4j 4.4 (syntaxe correcte)
constraints = [
    ("User",      "CREATE CONSTRAINT user_oid      IF NOT EXISTS FOR (n:User)      REQUIRE n.objectid IS UNIQUE"),
    ("Computer",  "CREATE CONSTRAINT computer_oid  IF NOT EXISTS FOR (n:Computer)  REQUIRE n.objectid IS UNIQUE"),
    ("Group",     "CREATE CONSTRAINT group_oid     IF NOT EXISTS FOR (n:Group)     REQUIRE n.objectid IS UNIQUE"),
    ("Domain",    "CREATE CONSTRAINT domain_oid    IF NOT EXISTS FOR (n:Domain)    REQUIRE n.objectid IS UNIQUE"),
    ("GPO",       "CREATE CONSTRAINT gpo_oid       IF NOT EXISTS FOR (n:GPO)       REQUIRE n.objectid IS UNIQUE"),
    ("OU",        "CREATE CONSTRAINT ou_oid        IF NOT EXISTS FOR (n:OU)        REQUIRE n.objectid IS UNIQUE"),
    ("Container", "CREATE CONSTRAINT container_oid IF NOT EXISTS FOR (n:Container) REQUIRE n.objectid IS UNIQUE"),
]

with driver.session() as session:
    for _, c in constraints:
        try:
            session.run(c)
        except Exception:
            pass

# Mapping type → label BloodHound
TYPE_MAP = {
    "users": "User", "user": "User",
    "computers": "Computer", "computer": "Computer",
    "groups": "Group", "group": "Group",
    "domains": "Domain", "domain": "Domain",
    "gpos": "GPO", "gpo": "GPO",
    "ous": "OU", "ou": "OU",
    "containers": "Container", "container": "Container",
}

# Mapping type → clés de relations BloodHound
REL_MAP = {
    "groups":    [("Members",    "MemberOf",  True)],
    "domains":   [("ChildObjects","Contains", False)],
    "ous":       [("ChildObjects","Contains", False)],
    "computers": [("LocalAdmins","AdminTo",   True), ("Sessions","HasSession",False)],
}

total_nodes = 0
total_rels  = 0

for jf in sorted(json_files):
    fname = os.path.basename(jf)
    try:
        with open(jf, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"    ⚠  Erreur lecture {fname}: {e}", flush=True)
        continue

    meta  = data.get("meta", {})
    dtype = meta.get("type", "").lower()
    items = data.get("data", [])
    if not items:
        print(f"    →  {fname}: vide", flush=True)
        continue

    label = TYPE_MAP.get(dtype, dtype.capitalize() if dtype else "Unknown")
    node_count = 0
    rel_count  = 0

    with driver.session() as session:
        for item in items:
            # ObjectIdentifier est à la racine dans les JSON BH
            oid = (item.get("ObjectIdentifier") or
                   item.get("objectidentifier") or
                   item.get("Properties", {}).get("objectid", ""))
            if not oid:
                continue
            oid = oid.upper()

            # Propriétés : fusionner Properties + champs plats utiles
            props = dict(item.get("Properties", {}))
            props["objectid"] = oid
            # Normaliser les clés en minuscules
            props = {k.lower(): v for k, v in props.items()
                     if not isinstance(v, (dict, list))}

            try:
                session.run(
                    "MERGE (n:" + label + " {objectid: $oid}) SET n += $props",
                    oid=oid, props=props
                )
                node_count += 1
            except Exception as e:
                pass

            # Relations
            for rel_key, rel_type, target_is_source in REL_MAP.get(dtype, []):
                members = item.get(rel_key, [])
                if not isinstance(members, list):
                    continue
                for m in members:
                    if isinstance(m, dict):
                        tid = (m.get("ObjectIdentifier") or m.get("MemberId", ""))
                        tlabel = m.get("ObjectType", "Base")
                    else:
                        tid = str(m)
                        tlabel = "Base"
                    if not tid:
                        continue
                    tid = tid.upper()
                    try:
                        if target_is_source:
                            session.run(
                                "MERGE (a:" + tlabel + " {objectid:$tid}) "
                                "MERGE (b:" + label + " {objectid:$oid}) "
                                "MERGE (a)-[:" + rel_type + "]->(b)",
                                tid=tid, oid=oid
                            )
                        else:
                            session.run(
                                "MERGE (a:" + label + " {objectid:$oid}) "
                                "MERGE (b:" + tlabel + " {objectid:$tid}) "
                                "MERGE (a)-[:" + rel_type + "]->(b)",
                                oid=oid, tid=tid
                            )
                        rel_count += 1
                    except Exception:
                        pass

    total_nodes += node_count
    total_rels  += rel_count
    print(f"    ✔  {fname}: {node_count} noeuds, {rel_count} relations", flush=True)

print(f"    ✔  Total : {total_nodes} noeuds, {total_rels} relations", flush=True)
driver.close()
PYEOF

deactivate
ok "Import Neo4j termine"

# =============================================================================
# ETAPE 5 — Rapport AD-Miner
# =============================================================================
step 5 "Generation du rapport AD-Miner"

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
    && ok "Rapport genere dans $(basename "$REPORT_DIR")/" \
    || ok "Rapport genere (voir ad-miner.log)"

# =============================================================================
# Resume
# =============================================================================
echo ""
echo -e "  ${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${BOLD}Projet          :${RESET} $PROJECT_NAME"
echo -e "  ${BOLD}Donnees         :${RESET} $PROJECT_DIR"
[[ -n "${REPORT_DIR:-}" ]] && \
echo -e "  ${BOLD}Rapport AD-Miner:${RESET} $REPORT_DIR/"
echo -e "  ${BOLD}Log collecte    :${RESET} $PROJECT_DIR/collect.log"
echo -e "  ${BOLD}Log AD-Miner    :${RESET} $PROJECT_DIR/ad-miner.log"
echo -e "  ${DIM}(Neo4j arrete automatiquement a la fin)${RESET}"
echo -e "  ${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
