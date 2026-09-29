# Registre de Traçabilité & Audit

## Objectif
Ajouter au Back-Office un registre d’audit complet, visible uniquement lorsque le rôle de test est **Superadministrateur**, sans exposer ce contenu aux deux associés.

## Expérience prévue
- Remplacer la simple carte « Traçabilité des courses » par une section complète avec 4 courses réalistes de Libreville.
- Présenter les colonnes demandées dans une table lisible sur grand écran, avec défilement horizontal maîtrisé sur mobile.
- Afficher les téléphones du chauffeur et du client partiellement masqués par défaut.
- Ajouter un bouton œil distinct pour chaque téléphone ; son activation ne révèle que le numéro concerné sur la ligne concernée.
- Ouvrir un panneau latéral au clic sur une ligne, contenant l’identité de la course et sa chronologie horodatée complète.
- Ajouter l’export CSV en haut du registre. Le fichier exporté inclura les valeurs brutes complètes, notamment les deux numéros de téléphone, conformément au besoin d’audit légal et comptable.

## Cloisonnement et sécurité
- Monter le registre uniquement dans la branche d’affichage Superadministrateur existante.
- Conserver les vues Associé 1 et Associé 2 strictement financières, sans table, détail ou export d’audit.
- Empêcher les clics sur les boutons œil d’ouvrir accidentellement le panneau latéral.
- Le CSV sera produit localement à partir des données simulées ; aucune donnée ne sera envoyée à un service externe.

## Détails techniques
- Étendre `src/routes/administration.tsx` avec les types et données d’audit, les états locaux de révélation et de sélection, et la génération CSV avec échappement correct des champs.
- Réutiliser les composants de boutons, table et panneau latéral déjà présents dans le projet.
- Conserver la charte sombre glassmorphism, les statuts lumineux vert/rouge/or et les animations compatibles avec la réduction de mouvement.
- Vérifier le téléchargement CSV, le masquage ciblé, l’ouverture/fermeture du panneau et l’absence totale du registre dans les vues associés.
