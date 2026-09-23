# Prompts vision

Utiliser ces deux passages séparément sur chaque image. Plusieurs images représentent le même plat sauf indication contraire : fusionner les observations, ne jamais multiplier les portions par le nombre d'angles.

## Passage A — décomposition visuelle

```text
Tu analyses une photo d'un repas de restaurant/livraison/cantine pour préparer une estimation nutritionnelle, pas pour reconnaître une image de manière générale.

Décompose le repas en composants distincts. Ne donne aucune kcal et aucune macro. Pour chaque composant, fournis :
- aliment probable ;
- variante ou recette plausible ;
- état et cuisson (cru/cuit, grillé, poêlé, frit, pané, vapeur, sauce) ;
- portion basse, centrale et haute en g ou ml ;
- confiance d'identification sur 10 ;
- indices visuels réellement présents : assiette/bol/emballage, couverts, verre, canette, pain, main, épaisseur, nombre de pièces ;
- alternatives plausibles qui modifieraient nettement les kcal.

Contraintes absolues :
- n'invente jamais le diamètre du contenant ;
- n'utilise comme échelle que ce qui est déjà visible ;
- sans échelle, élargis bas/haut ;
- ne demande ni pesée, ni mesure, ni carte bancaire, ni nouvel étalon ;
- si plusieurs angles montrent le même composant, ne le compte qu'une fois ;
- conserve le nom du restaurant/plat s'il est visible ou donné.

Biais restaurant obligatoires :
- poêlé/sauté/plancha/légumes brillants => huile probable, centre 8–12 g, jamais zéro par défaut ;
- frit/pané/nuggets/frites => friture certaine ;
- sauce blanche/nappage opaque => crème ou beurre par défaut, pas yaourt ;
- salade => vinaigrette probable ;
- pain, beurre, amuse-bouche => compter seulement s'ils sont visibles ou déclarés mangés ;
- boisson => eau par défaut, soda/vin/alcool seulement si visible ou déclaré.

Termine par une liste « invisibles » indiquant pour huile, beurre, crème, mayonnaise, sauce, fromage, sucre, marinade, panure, friture et vinaigrette : retenu / écarté / incertain, avec la raison visuelle.

Réponds en JSON valide :
{
  "same_meal_as_other_images": true,
  "dish_or_restaurant_name": null,
  "scale_cues": [],
  "components": [
    {
      "name": "",
      "variant": "",
      "cooking": "",
      "portion": {"unit": "g", "low": 0, "central": 0, "high": 0},
      "identification_confidence_10": 0,
      "visual_evidence": [],
      "high_impact_alternatives": []
    }
  ],
  "invisibles": []
}
```

## Passage B — critique indépendante

Ne pas commencer par recopier le Passage A. Examiner l'image à nouveau, puis confronter les points ci-dessous à la proposition A.

```text
Fais une critique nutritionnelle visuelle indépendante de cette photo. Ne calcule aucune kcal et aucune macro.

Recherche activement :
1. aliment ou variante mal identifié ;
2. portion sous-estimée ou surestimée, surtout la hauteur et la densité ;
3. huile, beurre, crème, mayonnaise, sauce, fromage, sucre, marinade, panure, friture ou vinaigrette oublié ;
4. confusion cru/cuit ou frit/grillé ;
5. type ou morceau de viande/poisson erroné ;
6. composant caché, superposé ou vu sous un second angle ;
7. double comptage entre images.

Ne suppose aucune cuisson sans matière grasse au restaurant. N'invente aucune dimension et ne demande aucune mesure.

Voici la proposition du Passage A, à évaluer seulement après ton observation indépendante :
<PASSAGE_A_JSON>

Réponds en JSON valide :
{
  "agreements": [],
  "corrections": [
    {
      "component": "",
      "issue": "",
      "recommended_change": "",
      "kcal_impact_direction": "up|down|uncertain",
      "confidence_10": 0
    }
  ],
  "missed_components": [],
  "double_count_risk": [],
  "reconciled_portion_suggestions": []
}
```

## Réconciliation

- Garder une identification commune si A et B concordent.
- En cas de désaccord sans indice décisif, conserver les deux hypothèses dans bas/haut au lieu de forcer une réponse.
- Faire apparaître l'huile et les sauces comme composants séparés lorsqu'elles ont un impact significatif.
- La confiance d'identification ne vaut pas précision calorique : une viande évidente avec huile invisible reste une estimation kcal peu confiante.
