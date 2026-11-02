# Allo Taxi.Premium

Initialise une application web progressive (PWA) appelée "Allo Taxi..?" dédiée au transport urbain de type VTC pour le marché gabonais. L'application doit adopter un design ultra-premium, épuré, moderne et être responsive (mobile-first).

Applique une charte graphique stricte en mode sombre sur tout le projet :

- Fond principal (Background) : Bleu nuit très profond (#0B0F19)

- Cartes et Surfaces : Effet Glassmorphism (#161F30 avec une opacité à 80%, des bordures ultra-fines en #24324D et un flou d'arrière-plan backdrop-blur)

- Accents Majeurs : Or ambré (#FFB800) pour l'identité haut de gamme/taxi, et Vert émeraude vibrant (#10B981) pour les statuts WhatsApp et indicateurs en direct.

- Typographie : Inter ou SF Pro, moderne, aérée et épurée.

Crée la page d'accueil/connexion globale (Splash & Login Screen) pour "Allo Taxi..?".

En haut de cet écran, intègre obligatoirement un composant de statistiques en temps réel avec un point vert clignotant (effet direct 🟢) qui affiche des compteurs animés : 

- "200 Passagers actifs"

- "73 Taxis en ligne"

- "187 Mises en relation réussies aujourd'hui"

Sous ce bloc d'activité, ajoute une interface de connexion élégante permettant de simuler ou de basculer vers les 3 grands espaces distincts de la plateforme :

1. Espace Client (Accès exprès via Prénom et Numéro de téléphone)

2. Espace Chauffeur (Accès sécurisé via Numéro de téléphone et code PIN)

3. Back-Office Administrateur (Interface réservée au Superadmin et aux deux Associés)

Prépare l'architecture de navigation globale (routes de base ou composants placeholders vides) pour que ces trois espaces cloisonnés soient prêts à recevoir leurs fonctionnalités lors des prochaines étapes.

This project was built with [Lovable](https://lovable.dev).

**Live app**: https://allo-taxi.lovable.app

## Build with Lovable

Continue developing this project in the [Lovable editor](https://lovable.dev/projects/d10df985-e160-4d0c-90f5-7afe8afd35a7).

- **Ship faster**: describe what you want to build and Lovable handles the code.
- **Stay in sync**: every change made in Lovable is committed straight to this repository.
- **Full ownership**: this code is yours. Push to `main` on GitHub and your changes sync back into Lovable, ready for your next prompt.

## Development

Prefer working locally? You need Node.js and npm — [install with nvm](https://github.com/nvm-sh/nvm#installing-and-updating).

```sh
git clone <this-repository-url>
cd <repository-name>
npm i
npm run dev
```
