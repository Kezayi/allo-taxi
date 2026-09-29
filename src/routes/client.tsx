import { createFileRoute } from "@tanstack/react-router";

import { SpacePlaceholder } from "@/components/space-placeholder";

export const Route = createFileRoute("/client")({
  head: () => ({
    meta: [
      { title: "Espace Client — Allo Taxi..?" },
      { name: "description", content: "L’espace passager Allo Taxi..? pour vos déplacements à Libreville." },
      { property: "og:title", content: "Espace Client — Allo Taxi..?" },
      { property: "og:description", content: "Votre espace passager VTC au Gabon." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: () => (
    <SpacePlaceholder
      eyebrow="Espace Client"
      title="Votre prochain trajet commence ici."
      description="Cet espace est prêt à accueillir la réservation, le suivi du chauffeur et l’historique de vos courses."
    />
  ),
});