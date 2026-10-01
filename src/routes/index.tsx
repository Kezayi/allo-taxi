import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { ArrowRight, CarFront, Check, Eye, EyeOff, LockKeyhole, ShieldCheck, UserRound } from "lucide-react";
import { useEffect, useState, type FormEvent, type ReactNode } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { phoneSchema, pinSchema, signInWithPhonePin, signUpWithPhonePin } from "@/lib/phone-auth";
import { cn } from "@/lib/utils";
import { supabase } from "@/integrations/supabase/client";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Allo Taxi..? — Votre VTC premium au Gabon" },
      { name: "description", content: "Accédez à Allo Taxi..?, la plateforme VTC premium pensée pour les déplacements urbains au Gabon." },
      { property: "og:title", content: "Allo Taxi..? — Votre VTC premium au Gabon" },
      { property: "og:description", content: "Clients, chauffeurs et administrateurs réunis sur une plateforme VTC gabonaise." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: Index,
});

type Space = "client" | "chauffeur" | "administration";

const spaces = [
  { id: "client" as const, label: "Client", icon: UserRound },
  { id: "chauffeur" as const, label: "Chauffeur", icon: CarFront },
  { id: "administration" as const, label: "Admin", icon: ShieldCheck },
];

function AnimatedNumber({ value }: { value: number }) {
  const [display, setDisplay] = useState(0);
  useEffect(() => {
    const started = performance.now();
    const duration = 900;
    let frame = 0;
    const tick = (now: number) => {
      const progress = Math.min((now - started) / duration, 1);
      setDisplay(Math.round(value * (1 - Math.pow(1 - progress, 3))));
      if (progress < 1) frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [value]);
  return <span>{display}</span>;
}

function useLiveActivity() {
  const [activity, setActivity] = useState({ active_passengers: 0, drivers_online: 0, matches_today: 0 });
  useEffect(() => {
    let alive = true;
    const load = () => supabase.rpc("get_public_activity").then(({ data }) => {
      const row = Array.isArray(data) ? data[0] : null;
      if (alive && row) setActivity({ active_passengers: Number(row.active_passengers), drivers_online: Number(row.drivers_online), matches_today: Number(row.matches_today) });
    });
    void load();
    const t = window.setInterval(load, 30000);
    return () => { alive = false; window.clearInterval(t); };
  }, []);
  return activity;
}

function Index() {
  const navigate = useNavigate();
  const activity = useLiveActivity();
  const [space, setSpace] = useState<Space>("client");
  const [showPin, setShowPin] = useState(false);
  const [activeRide, setActiveRide] = useState(false);
  useEffect(() => {
    try {
      setActiveRide(Boolean(sessionStorage.getItem("allo-taxi-ride-v1") || sessionStorage.getItem("allo-taxi-active-ride-v2")));
    } catch { /* stockage indisponible */ }
  }, []);

  const copy = {
    client: activeRide
      ? { title: "Votre course est en cours.", subtitle: "Retrouvez son suivi en un instant.", action: "Suivre ma course" }
      : { title: "Bienvenue à bord.", subtitle: "Votre chauffeur n’est jamais loin.", action: "Commander un taxi" },
    chauffeur: { title: "Prêt à rouler ?", subtitle: "Connectez-vous à votre espace professionnel.", action: "Ouvrir mon espace chauffeur" },
    administration: { title: "Pilotage sécurisé.", subtitle: "Accès strictement réservé à la direction.", action: "Accéder au Back-Office" },
  }[space];

  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [driverSignup, setDriverSignup] = useState(false);
  const isSignup = space === "chauffeur" && driverSignup;

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (space === "client") return void navigate({ to: "/client" });
    const form = new FormData(event.currentTarget);
    const phone = String(form.get("phone") ?? "");
    const pin = String(form.get("pin") ?? "");
    const p = phoneSchema.safeParse(phone);
    const c = pinSchema.safeParse(pin);
    if (!p.success) return setError(p.error.issues[0]?.message ?? "Numéro invalide.");
    if (!c.success) return setError(c.error.issues[0]?.message ?? "PIN invalide.");
    if (isSignup && pin !== String(form.get("pin2") ?? "")) return setError("Les deux codes PIN ne correspondent pas.");
    setBusy(true);
    setError(null);
    try {
      if (isSignup) await signUpWithPhonePin(phone, pin);
      else await signInWithPhonePin(phone, pin);
      void navigate({ to: space === "chauffeur" ? "/chauffeur" : "/administration" });
    } catch (e) {
      setError(e instanceof Error ? e.message : "Connexion impossible.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="relative min-h-svh overflow-hidden bg-background text-foreground">
      <div className="taxi-grid pointer-events-none absolute inset-0" />
      <div className="relative mx-auto grid min-h-svh w-full max-w-7xl gap-10 px-5 py-6 sm:px-8 lg:grid-cols-[minmax(0,1fr)_minmax(420px,500px)] lg:items-center lg:gap-16 lg:px-12 lg:py-10">
        <section className="flex min-w-0 flex-col justify-between gap-10">
          <header className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-4">
            <div className="flex min-w-0 items-center gap-3">
              <div className="grid size-10 shrink-0 place-items-center rounded-md bg-primary text-primary-foreground shadow-gold">
                <CarFront className="size-5" strokeWidth={2.4} />
              </div>
              <div className="min-w-0">
                <p className="truncate text-lg font-semibold">Allo Taxi<span className="text-primary">..?</span></p>
                <p className="text-[10px] font-medium uppercase text-muted-foreground">Libreville · Gabon</p>
              </div>
            </div>
            <span className="rounded-full border border-live/25 bg-live/10 px-3 py-1.5 text-[10px] font-semibold uppercase text-live">Service actif</span>
          </header>

          <div className="max-w-2xl">
            <p className="mb-4 text-xs font-semibold uppercase text-primary">Le mouvement, réinventé</p>
            <h1 className="text-4xl font-semibold leading-[1.08] sm:text-6xl lg:text-7xl">Libreville,<br /><span className="text-muted-foreground">à votre rythme.</span></h1>
            <p className="mt-6 max-w-lg text-sm leading-7 text-muted-foreground sm:text-base">Une mobilité urbaine exigeante, pensée ici. Choisissez votre espace et prenez la route.</p>
          </div>

          <section aria-label="Activité en direct" className="glass-panel p-4 sm:p-5">
            <div className="mb-4 flex items-center gap-2 text-[10px] font-semibold uppercase text-muted-foreground">
              <span className="relative flex size-2.5">
                <span className="absolute inline-flex size-full animate-ping rounded-full bg-live opacity-60" />
                <span className="relative inline-flex size-2.5 rounded-full bg-live" />
              </span>
              Activité en direct
            </div>
            <div className="grid grid-cols-3 divide-x divide-border">
              <Stat value={activity.active_passengers} label="Passagers en attente ou en course" />
              <Stat value={activity.drivers_online} label="Taxis en ligne" />
              <Stat value={activity.matches_today} label="Mises en relation aujourd’hui" />
            </div>
          </section>
        </section>

        <section className="glass-panel self-center p-5 sm:p-7">
          <div className="grid grid-cols-3 rounded-md border border-border bg-secondary/70 p-1" role="tablist" aria-label="Choisir un espace">
            {spaces.map((item) => {
              const Icon = item.icon;
              return (
                <Button
                  key={item.id}
                  type="button"
                  variant="ghost"
                  role="tab"
                  aria-selected={space === item.id}
                  onClick={() => setSpace(item.id)}
                  className={cn("h-11 min-w-0 px-2 text-xs text-muted-foreground hover:text-foreground", space === item.id && "bg-card text-foreground shadow-sm hover:bg-card")}
                >
                  <Icon className={cn("size-4", space === item.id && "text-primary")} />
                  <span className="truncate">{item.label}</span>
                </Button>
              );
            })}
          </div>

          <div className="mb-7 mt-8">
            <h2 className="text-2xl font-semibold sm:text-3xl">{copy.title}</h2>
            <p className="mt-2 text-sm text-muted-foreground">{copy.subtitle}</p>
          </div>

          <form onSubmit={submit} className="space-y-4">
            {space !== "client" && (
            <Field label="Numéro de téléphone" htmlFor="phone">
              <div className="grid grid-cols-[auto_minmax(0,1fr)]">
                <span className="flex h-12 items-center rounded-l-md border border-r-0 border-input bg-secondary px-3 text-sm font-semibold text-foreground">+241</span>
                <Input id="phone" name="phone" type="tel" inputMode="tel" placeholder="06 00 00 00 00" autoComplete="tel" required className="h-12 rounded-l-none" />
              </div>
            </Field>
            )}
            {space !== "client" && (
              <Field label={isSignup ? "Choisissez votre code PIN (4 ou 6 chiffres)" : "Code PIN"} htmlFor="pin">
                <div className="relative">
                  <Input id="pin" name="pin" type={showPin ? "text" : "password"} inputMode="numeric" maxLength={6} placeholder="••••" autoComplete={isSignup ? "new-password" : "current-password"} required className="h-12 pr-12" />
                  <Button type="button" variant="ghost" size="icon" aria-label={showPin ? "Masquer le code" : "Afficher le code"} onClick={() => setShowPin((value) => !value)} className="absolute right-1.5 top-1.5 text-muted-foreground">
                    {showPin ? <EyeOff /> : <Eye />}
                  </Button>
                </div>
              </Field>
            )}
            {isSignup && (
              <Field label="Confirmer le code PIN" htmlFor="pin2">
                <Input id="pin2" name="pin2" type={showPin ? "text" : "password"} inputMode="numeric" maxLength={6} placeholder="••••" autoComplete="new-password" required className="h-12" />
              </Field>
            )}
            {space === "administration" && (
              <div className="flex items-start gap-3 rounded-md border border-primary/20 bg-primary/5 p-3 text-xs leading-5 text-muted-foreground">
                <LockKeyhole className="mt-0.5 size-4 shrink-0 text-primary" />
                Réservé au Superadmin et aux deux Associés. Les comptes Associés sont créés par le Superadmin.
              </div>
            )}
            {error && <p className="text-xs text-primary" role="status">{error}</p>}
            <Button type="submit" disabled={busy} className="h-12 w-full text-sm font-semibold shadow-gold">
              {isSignup ? "Créer mon compte chauffeur" : copy.action}<ArrowRight />
            </Button>
            {space === "chauffeur" && (
              <Button type="button" variant="ghost" onClick={() => { setDriverSignup((v) => !v); setError(null); }} className="w-full text-xs text-muted-foreground">
                {driverSignup ? "Déjà inscrit ? Se connecter" : "Nouveau chauffeur ? S’inscrire"}
              </Button>
            )}
          </form>

          <div className="mt-6 flex items-center justify-center gap-2 text-[11px] text-muted-foreground">
            <Check className="size-3.5 text-live" /> {space === "client" ? "Rapide, simple et sans engagement" : "Connexion protégée et confidentielle"}
          </div>
        </section>
      </div>
    </main>
  );
}

function Stat({ value, label }: { value: number; label: string }) {
  return (
    <div className="min-w-0 px-2 first:pl-0 last:pr-0 sm:px-5">
      <p className="text-2xl font-semibold tabular-nums text-foreground sm:text-3xl"><AnimatedNumber value={value} /></p>
      <p className="mt-1 text-[10px] leading-4 text-muted-foreground sm:text-xs">{label}</p>
    </div>
  );
}

function Field({ label, htmlFor, children }: { label: string; htmlFor: string; children: ReactNode }) {
  return <div><label htmlFor={htmlFor} className="mb-2 block text-xs font-medium text-foreground">{label}</label>{children}</div>;
}
