---
name: systeme-fluide
description: "Use when coaching Système Fluide nutrition phases, calorie/step check-ins, or Delavier-based hypertrophy programming, exercise selection, execution, recruitment, and weak points. Do not use for unrelated training methods or medical diagnosis."
license: MIT
metadata:
  version: "0.1.6"
  author: "Lucas, Hermes Agent"
  platforms: [linux, macos, windows]
  hermes:
    tags: [musculation, nutrition, physique, Delavier, coaching]
    related_skills: [yazio, renpho, hevy]
---

# Système Fluide + Delavier

Coacher un physique athlétique et esthétique en gardant deux autorités séparées :

- **Système Fluide** décide des phases, calories, pas et volumes d'entraînement.
- **Delavier** décide du choix et de l'exécution des exercices, du recrutement, de l'adaptation morphologique et du traitement des points faibles.

Ne jamais attribuer à Delavier une règle calorique, ni au Système Fluide une fiche anatomique. Ce skill ne constitue pas un avis médical. Douleur articulaire aiguë, vertiges ou pathologie connue : interrompre le coaching concerné et orienter vers un professionnel de santé.

## Routage des sources

Après chargement de ce skill, lire seulement la fiche utile avant de répondre :

| Besoin | Référence obligatoire |
|---|---|
| Phase A–E, kcal, macros, pas, check-in | [references/phases-nutrition.md](references/phases-nutrition.md) |
| Programme, split, volume, RiR, priorités | [references/entrainement-fluide.md](references/entrainement-fluide.md) |
| Exercice, morphologie, recrutement, point faible | [references/delavier.md](references/delavier.md) |

Pour une question portant sur plusieurs domaines, charger les fiches correspondantes mais préserver la séparation des autorités.

## Quand l'utiliser

- check-in hebdomadaire, pesée, pas, calories, macros ou phase nutritionnelle ;
- déficit, reverse diet, prise de masse, reset, vacances ou journée calorique ratée ;
- création ou ajustement d'un programme, split, volume ou exercice ;
- forme d'un mouvement, sensations, recrutement, point faible, machine ou charges libres ;
- objectif de physique athlétique/esthétique, sèche ou prise de masse contrôlée.

Ne pas l'utiliser pour une autre méthode telle que PPL générique, 5/3/1 ou CrossFit si l'utilisateur ne demande pas le Fluide, pour diagnostiquer une blessure, ni pour une autre app de calories sans demande explicite.

## État utilisateur déclaré — il prime sur les valeurs d'app

- Phase actuelle : **B déficit**.
- Palier plancher déclaré : **1 954 kcal** ; ne pas le recouper ni recommander la phase C sans le critère de sortie décrit dans la fiche nutrition.
- Pas déclarés : **12 000/jour en moyenne hebdomadaire**. Ne jamais demander une synchronisation Yazio/Hermes ni écrire « non sync ».
- Priorité absolue : **pectoraux uniquement** (12+ séries/semaine).
- Développement modéré : épaules, dos, abdominaux (6–12).
- Maintenance : biceps, triceps, quadriceps, ischio-jambiers (3–5).
- Mollets : hors programme, déjà très développés. Ne jamais recommander d'en ajouter.
- Bas du corps déjà bon. Fessiers éventuellement en retard, mais pas prioritaires actuellement.

Ne jamais remplacer ces priorités par le template d'un guide ou d'un programme exemple.

## Hiérarchie de décision

1. Adhérence : si le plan n'est pas tenable, le réduire.
2. Environnement : sommeil et pas.
3. Calories.
4. Macros.
5. Entraînement.

Raisonnement hebdomadaire : total kcal, moyenne de pas et séries effectives. Une journée ratée peut être répartie sur les jours voisins. Ne jamais réagir à une pesée unique.

Le Fluide encadre phase, palier de ±200 kcal, pas, séries/semaine, 5–15 répétitions et 0–2 RiR. Delavier encadre mouvement, morphologie, sensations et correction d'un retard.

## Procédures

### Check-in ou changement de phase

1. Lire `references/phases-nutrition.md`.
2. Identifier la phase. Si elle est inconnue, demander poids actuel, tendance 7 jours, kcal actuelles, pas et objectif esthétique.
3. Récupérer les données disponibles via `yazio`, `renpho` et `hevy`, ou utiliser les chiffres déclarés. Ne jamais inventer une donnée manquante.
4. Appliquer uniquement la règle de la phase. Un palier vaut 200 kcal et modifie les glucides de 50 g ; protéines et lipides restent stables.
5. Attendre 72 h à 5 jours après un palier avant de juger.
6. Répondre : phase, tendance, action unique (`rien`, `+200`, `−200`), prochain point daté, puis une phrase d'entraînement si utile.

Terminé lorsque la phase est nommée, la règle citée, le prochain contrôle daté et aucun palier inventé.

### Construire ou modifier un programme

1. Lire `references/entrainement-fluide.md`, puis `references/delavier.md` pour les exercices.
2. Classer chaque groupe en maintenance, développement modéré ou priorité absolue.
3. Partir du bas de la fourchette et choisir une fréquence réellement tenable.
4. Choisir les mouvements selon la morphologie et le recrutement ; aucun squat, développé couché ou soulevé de terre n'est obligatoire.
5. Vérifier récupération, volume, répétitions, repos et RiR.

Terminé lorsque chaque groupe a une case et un volume de départ, chaque exercice est justifié selon Delavier et le split est récupérable.

### Point faible ou muscle non senti

Lire `references/delavier.md`. Classer vrai ou faux point faible avant d'ajouter du volume. Pour un vrai point faible, commencer par un exercice léger d'apprentissage moteur et prévoir le transfert vers un mouvement de base. Ne pas répondre automatiquement « plus lourd » ou « plus de séries ».

## Outils liés

- Nutrition quotidienne : skill `yazio`. Ne jamais exposer les identifiants.
- Poids et composition : skill `renpho` lorsqu'il est disponible ; l'impédancemétrie reste un signal secondaire faible.
- Entraînement réel : skill `hevy` pour le split et les séances enregistrées.
- Choix d'exercice et point faible : appliquer uniquement les principes disponibles dans `references/delavier.md`. Ne pas inventer une justification anatomique absente.

## Vérification finale

- Toute recommandation calorique cite la phase et sa règle.
- Tout programme affiche les trois catégories de volume et respecte leurs fourchettes.
- Tout mouvement controversé est justifié ou remplacé selon Delavier.
- Les chiffres Yazio/Renpho/Hevy viennent des outils ou de l'utilisateur.
- Réponse en français, concrète, avec un seul prochain palier ; éviter le roman.
