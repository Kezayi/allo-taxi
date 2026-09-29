import { Link } from "@tanstack/react-router";
import { ArrowLeft, Construction, MapPin } from "lucide-react";

import { Button } from "@/components/ui/button";

type SpacePlaceholderProps = {
  eyebrow: string;
  title: string;
  description: string;
};

export function SpacePlaceholder({ eyebrow, title, description }: SpacePlaceholderProps) {
  return (
    <main className="relative grid min-h-svh place-items-center overflow-hidden bg-background px-5 py-10 text-foreground">
      <div className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-primary/70 to-transparent" />
      <section className="glass-panel relative w-full max-w-lg p-6 sm:p-9">
        <div className="mb-10 flex items-center justify-between">
          <Link
            to="/"
            aria-label="Retour à la connexion"
            className="grid size-10 place-items-center rounded-md border border-border bg-secondary text-foreground transition-colors hover:bg-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            <ArrowLeft className="size-4" />
          </Link>
          <div className="flex items-center gap-2 text-xs font-semibold uppercase text-muted-foreground">
            <MapPin className="size-4 text-primary" />
            Libreville, Gabon
          </div>
        </div>

        <div className="grid size-12 place-items-center rounded-md border border-primary/30 bg-primary/10 text-primary">
          <Construction className="size-5" />
        </div>
        <p className="mt-7 text-xs font-semibold uppercase text-primary">{eyebrow}</p>
        <h1 className="mt-3 text-3xl font-semibold text-foreground sm:text-4xl">{title}</h1>
        <p className="mt-4 max-w-md text-sm leading-7 text-muted-foreground">{description}</p>
        <Button asChild className="mt-9 h-11 w-full font-semibold">
          <Link to="/">Retour à l’accueil</Link>
        </Button>
      </section>
    </main>
  );
}