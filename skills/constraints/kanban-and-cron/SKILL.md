---
name: kanban-and-cron
description: Dépendances Kanban parent→enfant, crons nouveaux pausés, delegate_task temporaire.
---

# Kanban et cron

Complète `sdlc-review` (partiel). Kanban = état durable ; Cron = planificateur ; `delegate_task` = sous-problème temporaire. Ne pas recréer ces primitives.

- Les dépendances de travail sont des liens Kanban parent → enfant, pas seulement du texte.
- Ne closer une tâche qu'après vérification réelle ; sinon demander une review ou bloquer avec la cause.
- Livrables hors `scratch/` ou joints à la carte.
- Crons nouveaux : commencent **pausés**, sans notifications tant que source, filtre et destinataire ne sont pas validés.
- `delegate_task` n'est pas un profile fantôme persistant. Maximum deux enfants simultanés, pas de délégation récursive.
