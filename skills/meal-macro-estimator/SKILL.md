---
name: meal-macro-estimator
description: "Use when estimating meal kcal/macros from one or more photos of a restaurant, delivery, or cafeteria meal. Produces justified low/central/high ranges from vision plus Ciqual lookups and deterministic calculations; do not use for weighed home meals, menu-only requests, Fluide check-ins, or Yazio-only logging."
license: MIT
metadata:
  version: "0.1.0"
  author: "Lucas, Hermes Agent"
  platforms: [linux, macos, windows]
  hermes:
    tags: [nutrition, calories, macros, vision, ciqual, usda]
    related_skills: [yazio, systeme-fluide]
    requires_toolsets: [vision, terminal]
---

# Meal Macro Estimator

Estimer les kcal, protéines, glucides et lipides d'un repas pris au restaurant, livré ou servi en cantine à partir d'une ou plusieurs photos. Toujours donner une fourchette justifiée et un scénario central, jamais un chiffre ponctuel présenté comme une mesure.

Ce skill n'est pas un avis médical et ne remplace pas Yazio. Ne jamais utiliser LogMeal, une API payante, ni des macros rappelées de mémoire lorsqu'une base est disponible.

## Routage

Utiliser ce skill pour :

- une photo de repas resto/livraison/cantine avec une demande de kcal ou macros ;
- un recalcul après une précision telle que le nom du plat, frit/grillé, sauce ou pain mangé ;
- plusieurs angles du même plat.

Ne pas l'utiliser pour :

- repas maison pesé : répondre en une phrase « tu pèses, log Yazio » sans estimation photo ;
- check-in Fluide ou changement de palier kcal : charger `systeme-fluide` s'il est installé ;
- carte/menu de restaurant sans photo : router vers `systeme-fluide` s'il est installé ;
- ajout Yazio seul : charger `yazio`.

## Ressources et commandes

Résoudre les chemins à partir du dossier contenant ce fichier `SKILL.md` (`SKILL_DIR`).

- Vision : `vision_analyze` pour chaque image locale ou URL. Si Hermes fournit la vision nativement sous un autre nom, utiliser l'outil vision équivalent.
- Base prioritaire : `data/ciqual_macros.sqlite`, issue de la table ANSES Ciqual 2020 sous Licence Ouverte.
- Prompts vision : lire [references/vision-prompt.md](references/vision-prompt.md) avant l'analyse.
- Schéma de calcul : partir de [templates/compute-input.json](templates/compute-input.json).
- Provenance et licences : [references/data-sources.md](references/data-sources.md).

```bash
python "$SKILL_DIR/scripts/lookup.py" "riz blanc cuit" --limit 5
python "$SKILL_DIR/scripts/lookup.py" "poulet rôti" --prefer cooked
python "$SKILL_DIR/scripts/lookup.py" "nutella" --off
python "$SKILL_DIR/scripts/compute.py" meal.json
```

`lookup.py` cherche Ciqual localement par défaut. Utiliser `--off` seulement pour un produit emballé. Utiliser `--usda` seulement si `USDA_FDC_API_KEY` est définie et n'est pas `DEMO_KEY`. Si Open Food Facts répond 503, rester sur Ciqual. Recréer la base avec :

```bash
python "$SKILL_DIR/scripts/build_ciqual.py"
```

La calibration de contenants maison est désactivée. Ne jamais lire ni écrire `templates/calibration.json` pour un repas au restaurant.

## Procédure

### 0. Photos : restaurant, zéro matériel

- Une photo suffit. Demander un second angle à environ 45° seulement si la première est trop plongeante pour estimer la hauteur d'un riz, d'une purée ou d'un burger.
- Ne jamais demander une troisième photo, une carte bancaire, un mètre, un diamètre, une pesée ou un étalon ajouté à la scène.
- Plusieurs photos représentent le même plat sauf indication contraire. Ne jamais additionner deux fois le même élément.
- Utiliser seulement une échelle déjà visible : couverts, verre, canette, pain ou main. Sans échelle, élargir la fourchette ; ne pas inventer de diamètre.
- Conserver le nom du restaurant ou du plat s'il est donné ou lisible. Une carte/PDF/web est un bonus, jamais un prérequis.

### 1. Passage A : décomposition

Appeler `vision_analyze` sur chaque image avec le prompt Passage A de `references/vision-prompt.md`. Décomposer l'assiette en composants. Pour chacun, relever :

- aliment probable, variante et cuisson ;
- portion basse, centrale et haute en g ou ml ;
- confiance d'identification ;
- indices visuels réellement présents : contenant, couverts, main, verre, emballage, épaisseur.

Appliquer obligatoirement les biais restaurant suivants :

- poêlé, sauté, plancha ou légumes brillants : huile probable, centre autour de 8–12 g, jamais 0 par défaut ;
- frit, pané, nuggets ou frites : friture certaine, sélectionner une entrée frite et non grillée ;
- sauce blanche ou nappage opaque : crème ou beurre, pas yaourt par défaut ;
- salade : vinaigrette probable même si elle est peu visible ;
- pain, beurre et amuse-bouche : compter seulement s'ils sont visibles ou déclarés mangés ;
- boisson : eau par défaut ; soda, vin ou alcool seulement si visible ou déclaré.

Lister explicitement les invisibles retenus ou écartés : huile, beurre, crème, mayonnaise, sauce, fromage, sucre, marinade, panure, friture et vinaigrette. Ne jamais supposer une cuisson sans matière grasse au restaurant.

### 2. Passage B : critique indépendante

Faire un second appel vision avec le prompt Passage B. Chercher indépendamment : aliment mal identifié, portion sous/surestimée, huile ou sauce oubliée, cru/cuit, type de viande, densité et composant manquant. Réconcilier les passages A et B avant tout lookup. Ne pas résumer la photo de mémoire.

### 3. Lookup nutritionnel

Pour chaque composant visible et invisible retenu, appeler `scripts/lookup.py`. Sélectionner une entrée correspondant à l'aliment, son état cru/cuit et sa cuisson. Riz cuit n'est pas riz cru. Pour chaque sélection, copier dans `meal.json` l'identifiant, le nom source et les kcal/protéines/glucides/lipides pour 100 g. Si le premier résultat a `kcal: null`, choisir le suivant renseigné.

Pour un plat nommé, faire aussi un lookup Ciqual du plat composé. Si le total démonté et le plat composé diffèrent de moins de 20 %, prendre une moyenne raisonnable pour le scénario central. Sinon conserver le démontage et élargir la fourchette ; ne jamais remplacer les composants restaurant par une entrée « maison, 0 MG ».

### 4. Calcul déterministe

Créer `meal.json` selon `templates/compute-input.json`, puis exécuter :

```bash
python "$SKILL_DIR/scripts/compute.py" meal.json
```

Reprendre les totaux et le classement des incertitudes produits par le script, sans calcul mental. Le script contrôle Atwater 4/4/9. Si l'écart dépasse 15 %, revérifier l'entrée et expliquer l'écart pertinent ; ne pas modifier les valeurs à la main.

### 5. Questions : zéro à trois

Poser au maximum trois questions et seulement si la réponse peut déplacer le total d'environ 5–10 % ou plus. Questions admissibles : nom du plat, frit ou grillé, sauce crème ou tomate, pain/frites réellement mangés, alcool. Ne jamais demander diamètre, grammes, pesée, carte bancaire ou nouvelle photo avec étalon.

### 6. Sortie obligatoire

Répondre en français. Arrondir les résultats à une précision honnête : fourchettes de kcal lisibles et macros en g, jamais « 713 kcal ». Distinguer confiance d'identification et précision calorique.

```text
REPAS IDENTIFIÉ
1. <aliment>
Portion estimée : <bas>–<haut> g (central <milieu> g)
Valeur centrale : <résumé>
Kcal / Protéines / Glucides / Lipides : <valeurs>
Confiance : <X>/10
Source : <Ciqual|OFF|USDA> <id> — <nom>

TOTAL ESTIMÉ
Calories : <bas>–<haut> kcal — central ~<milieu>
Protéines : <bas>–<haut> g — central ~<milieu>
Glucides : <bas>–<haut> g — central ~<milieu>
Lipides : <bas>–<haut> g — central ~<milieu>

Je logue midi/soir Yazio ?

PRINCIPALES INCERTITUDES
1. <cause> : ±<N> kcal
2. ...
3. ...

QUESTIONS QUI AMÉLIORERAIENT LE PLUS L'ESTIMATION
1. ...

CONFIANCE GLOBALE
<X>/10 — <une phrase sur visibilité et précision kcal>
```

Pour un repas restaurant, placer exactement une ligne de proposition Yazio immédiatement après le total. Ne rien journaliser pendant l'estimation.

### 7. Recalcul interactif

Si l'utilisateur répond à une question, ne pas relancer la vision. Modifier seulement les portions ou indicateurs concernés dans `meal.json`, relancer `compute.py`, resserrer la fourchette et augmenter la confiance uniquement si l'incertitude principale est effectivement levée.

Si l'utilisateur accepte le log Yazio ou dit « pas logué », charger le skill `yazio`. Demander confirmation avant toute écriture ambiguë. Après l'écriture, vérifier l'entrée et son heure ; pour ce flux, ne pas annoncer « logué » tant que l'heure est `00:00`. Utiliser Europe/Paris : déjeuner 13:00, dîner 20:00, puis revérifier selon la procédure Yazio.

## Pièges bloquants

- Inventer des macros sans `lookup.py` ou des totaux sans `compute.py`.
- Matcher du riz cru à une portion cuite.
- Oublier huile de poêle, vinaigrette, crème, panure ou fromage râpé.
- Compter deux fois un aliment vu sous deux angles.
- Produire une fourchette cosmétique de ±10 % alors que l'huile peut valoir ±80–150 kcal.
- Logger Yazio pendant l'estimation ou annoncer le succès sans vérification.
- Utiliser `DEMO_KEY` pour USDA ou contourner Ciqual sans raison.

## Vérification avant réponse

- Chaque composant a une source et un identifiant Ciqual, OFF ou USDA.
- Les totaux proviennent de `compute.py`.
- Les alertes Atwater sont résolues ou expliquées.
- La sortie contient bas, central, haut, incertitudes classées et confiance sur 10.
- Il y a zéro à trois questions, toutes à impact élevé.
