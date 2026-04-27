# 🐙 KrakenAD

> Script d'audit Active Directory tout-en-un — collecte LDAP, import BloodHound CE, rapport AD-Miner et téléchargement sécurisé.
> **Fonctionne sur n'importe quel serveur Linux, en français ou en anglais, dès le premier lancement.**

---

## ✨ Fonctionnalités

- **Auto-installation** : détecte et installe toutes les dépendances manquantes (`apt`, `dnf`, `yum`, `pacman`)
- **Auto-mise à jour** : met à jour les outils à chaque lancement (bloodhound-ce-python, AD-Miner, bloodhound-automation)
- **Multi-langue** : fonctionne quel que soit la langue de l'Active Directory (français, anglais, etc.)
- **Multi-projet** : chaque audit est isolé dans son propre répertoire, sans conflit
- **Nettoyage automatique** : BloodHound CE s'arrête proprement à la fin, même en cas d'erreur ou Ctrl+C
- **Téléchargement sécurisé** : page web temporaire auto-destructrice pour récupérer le rapport

---

## ⚡ Démarrage rapide

```bash
git clone https://github.com/CyberPoulpe/KrakenAD.git
cd KrakenAD
chmod +x KrakenAD.sh
./KrakenAD.sh
```

Le script demande ensuite les informations de la cible :

```
  Nom du projet   : pentest-client-2024
  Domaine         : corp.example.com
  Utilisateur     : john.doe
  Mot de passe    : ••••••••
  IP du DC        : 192.168.1.10
```

À la fin, une URL s'affiche pour télécharger le rapport depuis n'importe quel navigateur :

```
  ==========================================
  Rapport pret au telechargement :
  http://192.168.1.50:9999
  (Le serveur s'arrete apres le telechargement)
  ==========================================
```

---

## 📋 Prérequis

| Prérequis | Détail |
|-----------|--------|
| OS | Linux (Debian/Ubuntu, RHEL/Fedora, Arch) |
| Droits | `sudo` ou `root` pour l'installation initiale |
| Réseau | Accès au DC sur le port 389 (LDAP) |
| Docker | Installé automatiquement si absent |
| Compte AD | N'importe quel compte du domaine suffit |

> Tout le reste (`python3`, `git`, `bloodhound-ce-python`, `AD-Miner`, `bloodhound-automation`) est installé et mis à jour automatiquement.

---

## 🚀 Pipeline en 5 étapes

```
[1/5] Vérification des dépendances
      └── Détection OS, installation des outils manquants, mise à jour automatique

[2/5] Collecte LDAP via bloodhound-ce-python
      └── Dump complet de l'AD : users, groupes, computers, GPO, ACL, sessions...

[3/5] Démarrage BloodHound CE
      └── Lancement via bloodhound-automation (Docker), création ou reprise du projet

[4/5] Import et analyse des données
      └── Upload du ZIP dans BloodHound CE, attente de l'analyse Neo4j

[5/5] Génération du rapport AD-Miner
      └── Rapport HTML interactif + serveur de téléchargement temporaire
```

---

## 🗂️ Structure des fichiers générés

```
/data/
├── krakanad-venv/                  # Environnement Python partagé
├── bloodhound-automation/          # Outil de gestion BloodHound CE
└── KrakenAD/
    └── projects/
        └── <nom-du-projet>/
            ├── *.zip               # Données BloodHound collectées
            ├── collect.log         # Log de la collecte LDAP
            ├── ad-miner.log        # Log AD-Miner
            └── render_<projet>/    # Rapport HTML AD-Miner
                ├── index.html
                └── html/           # Pages de détail (162 contrôles)
```

---

## ⚙️ Configuration

Les variables suivantes peuvent être surchargées avant l'exécution :

```bash
# Changer le répertoire de base (défaut : /data)
export KRAKANAD_BASE=/opt/audits

# Changer les ports BloodHound CE (si conflits avec d'autres services)
export BH_PORT_WEB=8001
export BH_PORT_NEO4J=10001
export BH_PORT_NEO4J_HTTP=10501

./KrakenAD.sh
```

---

## 🔧 Outils utilisés

| Outil | Rôle | Lien |
|-------|------|------|
| bloodhound-ce-python | Collecte LDAP/AD (format BloodHound CE) | [dirkjanm/BloodHound.py](https://github.com/dirkjanm/BloodHound.py) |
| BloodHound CE | Analyse des chemins d'attaque | [SpecterOps/BloodHound](https://github.com/SpecterOps/BloodHound) |
| bloodhound-automation | Gestion Docker de BloodHound CE | [Tanguy-Boisset/bloodhound-automation](https://github.com/Tanguy-Boisset/bloodhound-automation) |
| AD-Miner | Génération du rapport HTML interactif | [AD-Security/AD_Miner](https://github.com/AD-Security/AD_Miner) |

---

## 📊 Rapport AD-Miner

Le rapport couvre **162 contrôles de sécurité** répartis en plusieurs catégories :

- 🔑 **Mots de passe** : comptes sans expiration, mots de passe anciens, LAPS
- 🎫 **Kerberos** : Kerberoastable, AS-REP Roasting, délégations, Shadow Credentials
- 🛡️ **Permissions** : chemins vers Domain Admins, DCSync, AdminSDHolder, ACL dangereuses
- 🖥️ **Machines** : OS obsolètes, machines fantômes, admins locaux
- ☁️ **Azure/Entra ID** : comptes synchronisés, rôles privilégiés

---

## ⚠️ Avertissement légal

Ce script est destiné exclusivement à des **audits de sécurité autorisés**. Toute utilisation sur des systèmes sans autorisation écrite préalable est illégale. L'auteur décline toute responsabilité en cas d'utilisation malveillante ou non autorisée.
