# Phases et nutrition — Système Fluide

Lire cette fiche pour tout check-in, ajustement calorique, macro, pas ou changement de phase. Le Système Fluide est l'autorité de cette fiche ; Delavier n'est pas une source nutritionnelle.

## Invariants

- Adhérence avant perfection.
- Évaluer les totaux/moyennes à la semaine, jamais une pesée isolée.
- Ordre : sommeil et pas → calories → macros → entraînement.
- Un palier = **±200 kcal**, appliqué par **±50 g de glucides**. Protéines et lipides restent stables.
- Après un palier, attendre **72 heures à 5 jours** avant de juger.
- Une journée ratée se rattrape raisonnablement sur les jours voisins.
- Vacances : un diet break est acceptable ; préserver les principes sans exiger une application rigide.
- Ne pas maximiser les pas au détriment du sommeil, de la digestion ou de l'adhérence.

## Carte des phases

| Phase | Nom | Règle disponible dans ce paquet |
|---|---|---|
| A | Pré-préparation | Identifier la phase. Aucun palier automatique n'est défini ici ; demander la règle déclarée avant d'ajuster. |
| B | Déficit | Appliquer les paliers de 200 kcal, respecter le plancher déclaré et le critère de sortie ci-dessous. |
| C | Reverse diet | Phase critique : approximation interdite. Ne pas exiger un « écart zéro » dans les autres phases. Demander le plan calorique déclaré avant un palier. |
| D | Masse | Ne pas fabriquer un surplus ou un rythme de prise de poids ; demander la cible déclarée si elle manque. |
| E | Reset | Ne pas inventer déclenchement, durée ou sortie et ne pas assimiler automatiquement reset et vacances. |

Ce skill ne définit pas les seuils complets A/C/D/E. Si une décision en dépend, demander la règle déclarée plutôt que généraliser depuis une autre méthode.

## État déclaré actuel

- Phase : **B — déficit**.
- Palier plancher : **1 954 kcal**.
- Pas : **12 000/jour en moyenne hebdomadaire**.

Ces déclarations priment sur les valeurs de bruit suivantes : `steps=0`, `goals.activity.step=10000`, `user.goal=build_muscle`. Ne jamais demander de synchroniser Yazio/Hermes et ne jamais écrire « non sync ».

## Décision en phase B

1. Calculer la tendance sur des données suffisantes, pas sur une pesée.
2. Si le dernier palier date de moins de 72 h, maintenir.
3. Au plancher déclaré de 1 954 kcal, l'action par défaut est **HOLD 1954**.
4. Ne jamais déclencher ni recommander la phase C depuis le seul body-fat Renpho. L'impédancemétrie est un signal secondaire faible.
5. La sortie de B exige soit :
   - une déclaration explicite de l'utilisateur que sa composition est satisfaisante ;
   - des signaux de déficit suffisamment forts pour appliquer la remontée prévue à l'intérieur de B.
6. Sans cette validation, maintenir le plancher déclaré.

Ne pas inventer la liste ou le seuil des « signaux suffisamment forts ». Demander la confirmation de l'utilisateur si le critère n'est pas déjà déclaré.

## Données incomplètes

- Si un jour Yazio manque ou vaut zéro faute de journalisation, marquer la moyenne hebdomadaire **incomplète**.
- Ne pas interpréter zéro comme un apport réel.
- Ne tirer d'une semaine incomplète aucun changement de phase automatique.
- Les données d'outil doivent être citées comme telles ; sinon indiquer qu'elles viennent de l'utilisateur.

## Format live

Réponse normale :

1. phase ;
2. tendance ;
3. action unique : `rien`, `+200` ou `−200` ;
4. prochain point de contrôle daté ;
5. une phrase d'entraînement si pertinente.
