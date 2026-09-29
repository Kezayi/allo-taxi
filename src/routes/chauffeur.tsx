import { createFileRoute } from "@tanstack/react-router";

import { SpacePlaceholder } from "@/components/space-placeholder";

export const Route = createFileRoute("/chauffeur")({
  head: () => ({
    meta: [
      { title: "Espace Chauffeur — Allo Taxi..?" },
      { name: "description", content: "L’espace professionnel des chauffeurs Allo Taxi..? au Gabon." },
      { property: "og:title", content: "Espace Chauffeur — Allo Taxi..?" },
      { property: "og:description", content: "Votre espace chauffeur sécurisé Allo Taxi..?." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: () => (
    <SpacePlaceholder
      eyebrow="Espace Chauffeur"
      title="Prenez la route en toute confiance."
      description="Cet espace est prêt à recevoir les demandes de course, la disponibilité en ligne et le suivi des revenus."
    />
  ),
});