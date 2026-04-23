# 🐙 KrakenAD.sh

> Script d'audit Active Directory tout-en-un — collecte LDAP, import BloodHound CE, rapport AD-Miner. **Fonctionne sur n'importe quel serveur Linux dès le premier lancement.**

---

## ✨ Fonctionnalités

- **Auto-installation** : détecte et installe toutes les dépendances manquantes (`apt`, `dnf`, `yum`, `pacman`)
- **Idempotent** : si les outils sont déjà présents, le script les réutilise sans rien réinstaller
- **Pipeline complet** en une seule commande :
  1. Collecte LDAP via `bloodhound-python`
  2. Démarrage de BloodHound CE (Docker)
  3. Import automatique des données
  4. Génération du rapport HTML avec AD-Miner
- **Multi-projet** : chaque audit est isolé dans son propre répertoire

---

## ⚡ Démarrage rapide

```bash
git clone https://github.com/<vous>/KrakenAD.git
cd KrakenAD
chmod +x KrakenAD.sh
./KrakenAD.sh
```

Le script vous demandera ensuite :

```
  Nom du projet   : pentest-client-2024
  Domaine         : corp.example.com
  Utilisateur     : john.doe
  Mot de passe    : ••••••••
  IP du DC        : 192.168.1.10
```

---

## 📋 Prérequis

| Prérequis | Détail |
|-----------|--------|
| OS | Linux (Debian/Ubuntu, RHEL/Fedora, Arch) |
| Droits | `sudo` ou `root` pour l'installation initiale |
| Réseau | Accès au DC sur le port 389 (LDAP) |
| Docker | Installé automatiquement si absent |

> Tout le reste (`python3`, `git`, `bloodhound-python`, `AD-Miner`, `bloodhound-automation`) est installé automatiquement au premier lancement.

---

## 🗂️ Structure des fichiers générés

```
/data/KrakenAD/projects/
└── <nom-du-projet>/
    ├── *.zip              # Données BloodHound collectées
    ├── collect.log        # Log de la collecte LDAP
    ├── ad-miner.log       # Log AD-Miner
    └── render_<projet>/   # Rapport HTML AD-Miner
        └── index.html
```

---

## ⚙️ Configuration

Les variables suivantes peuvent être surchargées via l'environnement avant l'exécution :

```bash
# Changer le répertoire de base (défaut : /data)
export KRAKENАД_BASE=/opt/audits

# Changer les ports BloodHound CE (si conflits)
export BH_PORT_WEB=8001
export BH_PORT_NEO4J=10001
export BH_PORT_NEO4J_HTTP=10501

./KrakenAD.sh
```

Les identifiants BloodHound CE et Neo4j sont configurables directement dans le script (section `Configuration`).

---

## 🔧 Outils utilisés

| Outil | Rôle |
|-------|------|
| [bloodhound-python](https://github.com/dirkjanm/BloodHound.py) | Collecte LDAP/AD |
| [BloodHound CE](https://github.com/SpecterOps/BloodHound) | Visualisation des chemins d'attaque |
| [bloodhound-automation](https://github.com/dirkjanm/BloodHound-automation) | Gestion Docker de BloodHound CE |
| [AD-Miner](https://github.com/Mazars-Tech/AD_Miner) | Génération du rapport HTML |

---

## 🚀 Étapes du pipeline

```
[1/7] Vérification de l'environnement       ← Détection OS & package manager
[2/7] Dépendances système                   ← Installation si manquantes
[3/7] Outils AD                             ← venvs Python, bloodhound-python, AD-Miner
[4/7] Collecte LDAP — BloodHound.py         ← Dump complet de l'AD
[5/7] Démarrage BloodHound CE               ← Création ou reprise du projet Docker
[6/7] Import des données                    ← Chargement du ZIP dans BloodHound CE
[7/7] Génération du rapport AD-Miner        ← Rapport HTML interactif
```

---

## ⚠️ Avertissement légal

Ce script est destiné à des **audits de sécurité autorisés**. Toute utilisation sur des systèmes sans autorisation explicite est illégale. L'auteur décline toute responsabilité en cas d'utilisation malveillante.

---

## 📄 Licence

MIT — voir [LICENSE](LICENSE)
