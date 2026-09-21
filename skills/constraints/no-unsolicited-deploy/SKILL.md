---
name: no-unsolicited-deploy
description: Pas de publication, déploiement destructif ou achat sans demande explicite.
---

# Pas de deploy non demandé

- Aucune publication, déploiement destructif, achat, transfert de fonds ou transaction réelle sans demande explicite.
- Déploiement VPS : git distant + Orca/opérateur, jamais depuis le conteneur agent.
- Interdit dans ce conteneur : `sudo`, `apt`, daemon Docker, exposer un port.
- Ne pas pousser sur `main`/`master`, forcer un remote, ni lancer un `deploy.sh` sans demande.
- Les outils autorisés ne sont pas une sandbox OS : ne pas prétendre à une isolation de sécurité forte.
