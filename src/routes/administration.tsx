import { createFileRoute } from "@tanstack/react-router";

import { SpacePlaceholder } from "@/components/space-placeholder";

export const Route = createFileRoute("/administration")({
  head: () => ({
    meta: [
      { title: "Administration — Allo Taxi..?" },
      { name: "description", content: "Le centre de pilotage réservé de la plateforme Allo Taxi..?." },
      { property: "og:title", content: "Administration — Allo Taxi..?" },
      { property: "og:description", content: "Le centre de pilotage réservé de la plateforme Allo Taxi..?." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: () => (
    <SpacePlaceholder
      eyebrow="Administration"
      title="Le centre de contrôle est prêt."
      description="Cet espace réservé est prêt à accueillir la supervision des courses, des comptes et de l’activité en temps réel."
    />
  ),
});