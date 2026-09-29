import { createFileRoute, Link } from "@tanstack/react-router";
import {
  ArrowLeft,
  BadgeCheck,
  CarFront,
  ChevronDown,
  ChevronUp,
  CircleDollarSign,
  Clock3,
  Minus,
  Navigation,
  Phone,
  Plus,
  ShieldCheck,
  Snowflake,
  UserRound,
  Wind,
  X,
} from "lucide-react";
import { useEffect, useMemo, useState, type FormEvent } from "react";
import { z } from "zod";

import driverPortrait from "@/assets/chauffeur-michel.jpg";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/client")({
  head: () => ({
    meta: [
      { title: "Course express — Allo Taxi..?" },
      { name: "description", content: "Demandez une course VTC express à Libreville, sans inscription obligatoire." },
      { property: "og:title", content: "Course express — Allo Taxi..?" },
      { property: "og:description", content: "Publiez votre trajet et trouvez un chauffeur à proximité." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: ClientJourney,
});

type Step = "request" | "waiting" | "matched";
type Comfort = "standard" | "climatise";
type Payment = "especes" | "airtel" | "moov";

type RideRequest = {
  firstName: string;
  phone: string;
  pickup: string;
  destination: string;
  comfort: Comfort;
  payment: Payment;
  price: number;
};

const requestSchema = z.object({
  firstName: z.string().trim().min(2, "Saisissez au moins 2 caractères.").max(50, "Le prénom est trop long."),
  phone: z.string().trim().regex(/^[0-9\s-]{7,14}$/, "Saisissez un numéro gabonais valide."),
  pickup: z.string().trim().min(3, "Précisez votre point de départ.").max(120, "L’adresse est trop longue."),
  destination: z.string().trim().min(3, "Précisez votre destination.").max(120, "L’adresse est trop longue."),
  comfort: z.enum(["standard", "climatise"]),
  payment: z.enum(["especes", "airtel", "moov"]),
  price: z.number().int().min(500, "Le prix minimum est de 500 FCFA.").max(100000, "Le prix maximum est de 100 000 FCFA."),
});

const initialRide: RideRequest = {
  firstName: "",
  phone: "",
  pickup: "",
  destination: "",
  comfort: "standard",
  payment: "especes",
  price: 2000,
};

const paymentLabels: Record<Payment, string> = {
  especes: "Espèces",
  airtel: "AirtelMoney",
  moov: "MoovMoney",
};

function ClientJourney() {
  const [step, setStep] = useState<Step>("request");
  const [identityOpen, setIdentityOpen] = useState(true);
  const [ride, setRide] = useState<RideRequest>(initialRide);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [lockedNotice, setLockedNotice] = useState(false);

  const suggestedPrice = useMemo(() => {
    const route = `${ride.pickup} ${ride.destination}`.toLocaleLowerCase("fr");
    return route.includes("charbonnages") || route.includes("nzeng") ? 2000 : null;
  }, [ride.destination, ride.pickup]);

  useEffect(() => {
    if (sessionStorage.getItem("allo-taxi-active-discussion") === "true") setStep("matched");
  }, []);

  useEffect(() => {
    if (step !== "matched") return;
    sessionStorage.setItem("allo-taxi-active-discussion", "true");
    window.history.pushState({ alloTaxiLocked: true }, "", window.location.href);
    const holdDiscussion = () => {
      window.history.pushState({ alloTaxiLocked: true }, "", window.location.href);
      setLockedNotice(true);
    };
    window.addEventListener("popstate", holdDiscussion);
    return () => window.removeEventListener("popstate", holdDiscussion);
  }, [step]);

  function update<K extends keyof RideRequest>(key: K, value: RideRequest[K]) {
    setRide((current) => ({ ...current, [key]: value }));
    setErrors((current) => ({ ...current, [key]: "" }));
  }

  function submitRequest(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const parsed = requestSchema.safeParse(ride);
    if (!parsed.success) {
      const nextErrors: Record<string, string> = {};
      for (const issue of parsed.error.issues) nextErrors[String(issue.path[0])] = issue.message;
      setErrors(nextErrors);
      setIdentityOpen(Boolean(nextErrors["firstName"] || nextErrors["phone"]));
      return;
    }
    setErrors({});
    setRide(parsed.data);
    setStep("waiting");
  }

  function cancelRequest() {
    setRide(initialRide);
    setErrors({});
    setIdentityOpen(true);
    setStep("request");
  }

  const whatsappMessage = encodeURIComponent(
    `Bonjour Michel, je suis ${ride.firstName}. Vous avez accepté ma course Allo Taxi..?\n\nDépart : ${ride.pickup}\nDestination : ${ride.destination}\nPrix proposé : ${ride.price.toLocaleString("fr-FR")} FCFA\nConfort : ${ride.comfort === "climatise" ? "Véhicule climatisé exigé" : "Standard avec ventilation"}\nRèglement : ${paymentLabels[ride.payment]}\n\nJe suis prêt(e) pour l’embarquement.`,
  );

  return (
    <main className="relative min-h-svh overflow-hidden bg-background px-4 py-5 text-foreground sm:px-6 sm:py-8">
      <div className="taxi-grid pointer-events-none absolute inset-0" />
      <div className="relative mx-auto w-full max-w-3xl">
        <header className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-3">
          {step === "matched" ? (
            <Button type="button" variant="ghost" size="icon" aria-label="Revenir" onClick={() => setLockedNotice(true)} className="border border-border bg-secondary">
              <ArrowLeft />
            </Button>
          ) : (
            <Button asChild variant="ghost" size="icon" className="border border-border bg-secondary">
              <Link to="/" aria-label="Retour à l’accueil"><ArrowLeft /></Link>
            </Button>
          )}
          <div className="min-w-0 text-center">
            <p className="truncate text-sm font-semibold">Allo Taxi<span className="text-primary">..?</span></p>
            <p className="text-[10px] uppercase text-muted-foreground">Course express</p>
          </div>
          <span className="flex items-center gap-1.5 text-[10px] font-semibold uppercase text-live"><span className="size-2 rounded-full bg-live" />Libreville</span>
        </header>

        <StepRail step={step} />

        <div key={step} className="animate-journey-in">
          {step === "request" && (
            <RequestScreen
              ride={ride}
              errors={errors}
              identityOpen={identityOpen}
              suggestedPrice={suggestedPrice}
              onIdentityToggle={() => setIdentityOpen((value) => !value)}
              onUpdate={update}
              onSubmit={submitRequest}
            />
          )}
          {step === "waiting" && (
            <WaitingScreen ride={ride} onCancel={cancelRequest} onSimulate={() => setStep("matched")} />
          )}
          {step === "matched" && (
            <MatchedScreen ride={ride} whatsappMessage={whatsappMessage} lockedNotice={lockedNotice} onDismissLock={() => setLockedNotice(false)} />
          )}
        </div>
      </div>
    </main>
  );
}

function StepRail({ step }: { step: Step }) {
  const current = step === "request" ? 1 : step === "waiting" ? 2 : 3;
  return (
    <div className="mx-auto my-7 flex max-w-xs items-center" aria-label={`Étape ${current} sur 3`}>
      {[1, 2, 3].map((number, index) => (
        <div key={number} className={cn("flex items-center", index < 2 && "flex-1")}>
          <span className={cn("grid size-7 shrink-0 place-items-center rounded-full border text-[11px] font-bold", number <= current ? "border-primary bg-primary text-primary-foreground" : "border-border bg-secondary text-muted-foreground")}>{number < current ? "✓" : number}</span>
          {index < 2 && <span className={cn("h-px flex-1", number < current ? "bg-primary" : "bg-border")} />}
        </div>
      ))}
    </div>
  );
}

function RequestScreen({ ride, errors, identityOpen, suggestedPrice, onIdentityToggle, onUpdate, onSubmit }: {
  ride: RideRequest;
  errors: Record<string, string>;
  identityOpen: boolean;
  suggestedPrice: number | null;
  onIdentityToggle: () => void;
  onUpdate: <K extends keyof RideRequest>(key: K, value: RideRequest[K]) => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
}) {
  return (
    <section>
      <div className="mb-7 text-center">
        <p className="text-xs font-semibold uppercase text-primary">Sans inscription</p>
        <h1 className="mt-2 text-3xl font-semibold sm:text-4xl">Où allons-nous ?</h1>
        <p className="mt-2 text-sm text-muted-foreground">Publiez votre trajet en moins d’une minute.</p>
      </div>

      <form onSubmit={onSubmit} className="space-y-5" noValidate>
        <section className="glass-panel overflow-hidden">
          <Button type="button" variant="ghost" onClick={onIdentityToggle} aria-expanded={identityOpen} className="h-auto w-full justify-between rounded-none px-5 py-4 hover:bg-accent/40">
            <span className="flex min-w-0 items-center gap-3"><span className="grid size-9 shrink-0 place-items-center rounded-md bg-primary/10 text-primary"><UserRound /></span><span className="min-w-0 text-left"><span className="block text-sm font-semibold">Votre identité éphémère</span><span className="block truncate text-[11px] font-normal text-muted-foreground">Utilisée uniquement pour cette course</span></span></span>
            {identityOpen ? <ChevronUp /> : <ChevronDown />}
          </Button>
          {identityOpen && (
            <div className="grid gap-4 border-t border-border px-5 py-5 sm:grid-cols-2">
              <Field label="Prénom" error={errors["firstName"]}><Input value={ride.firstName} onChange={(event) => onUpdate("firstName", event.target.value)} maxLength={50} placeholder="Votre prénom" autoComplete="given-name" className="h-12" /></Field>
              <Field label="Numéro de téléphone" error={errors["phone"]}>
                <div className="grid grid-cols-[auto_minmax(0,1fr)]"><span className="flex h-12 items-center rounded-l-md border border-r-0 border-input bg-secondary px-3 text-sm font-semibold">+241</span><Input value={ride.phone} onChange={(event) => onUpdate("phone", event.target.value)} maxLength={14} type="tel" inputMode="tel" placeholder="06 00 00 00" autoComplete="tel" className="h-12 rounded-l-none" /></div>
              </Field>
            </div>
          )}
        </section>

        <section className="glass-panel space-y-4 p-5">
          <Field label="📍 Où êtes-vous ?" error={errors["pickup"]}><Input value={ride.pickup} onChange={(event) => onUpdate("pickup", event.target.value)} maxLength={120} placeholder="Ex: Charbonnages, Entrée SNI" className="h-12" /></Field>
          <div className="ml-5 h-5 border-l border-dashed border-primary/50" />
          <Field label="🏁 Où allez-vous ?" error={errors["destination"]}><Input value={ride.destination} onChange={(event) => onUpdate("destination", event.target.value)} maxLength={120} placeholder="Ex: Nzeng-Ayong, Rond-point" className="h-12" /></Field>
        </section>

        <section className="glass-panel p-5">
          <p className="text-sm font-semibold">Votre confort</p>
          <div className="mt-3 grid grid-cols-2 gap-3">
            <ChoiceButton active={ride.comfort === "standard"} onClick={() => onUpdate("comfort", "standard")} icon={<Wind />} title="Standard" subtitle="Ventilation" />
            <ChoiceButton active={ride.comfort === "climatise"} onClick={() => onUpdate("comfort", "climatise")} icon={<Snowflake />} title="Climatisé" subtitle="Air conditionné" />
          </div>
        </section>

        <section className="glass-panel p-5">
          <p className="text-sm font-semibold">Mode de règlement</p>
          <div className="mt-3 grid grid-cols-3 gap-2">
            {(["especes", "airtel", "moov"] as const).map((payment) => (
              <Button key={payment} type="button" variant="outline" aria-pressed={ride.payment === payment} onClick={() => onUpdate("payment", payment)} className={cn("h-11 min-w-0 px-2 text-[11px]", ride.payment === payment && "border-primary bg-primary/10 text-primary hover:bg-primary/10 hover:text-primary")}>
                <span aria-hidden="true">{payment === "especes" ? "💵" : "📲"}</span><span className="truncate">{paymentLabels[payment]}</span>
              </Button>
            ))}
          </div>
        </section>

        <section className="glass-panel p-5">
          <div className="grid gap-5 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
            <div>
              <p className="flex items-center gap-2 text-sm font-semibold"><CircleDollarSign className="size-4 text-primary" />Votre offre</p>
              <p className="mt-1 min-h-5 text-xs text-muted-foreground">{suggestedPrice ? `Prix suggéré : ${suggestedPrice.toLocaleString("fr-FR")} FCFA` : "Indiquez le tarif que vous proposez."}</p>
            </div>
            <div className="grid grid-cols-[44px_minmax(0,1fr)_44px] items-center gap-2">
              <Button type="button" variant="outline" size="icon" aria-label="Réduire le prix de 100 FCFA" onClick={() => onUpdate("price", Math.max(500, ride.price - 100))}><Minus /></Button>
              <div className="relative"><Input aria-label="Prix proposé en FCFA" value={ride.price} onChange={(event) => onUpdate("price", Number(event.target.value))} type="number" min={500} max={100000} step={100} className="h-11 min-w-0 pr-14 text-center font-bold tabular-nums" /><span className="pointer-events-none absolute right-2 top-3 text-[10px] font-semibold text-muted-foreground">FCFA</span></div>
              <Button type="button" variant="outline" size="icon" aria-label="Augmenter le prix de 100 FCFA" onClick={() => onUpdate("price", Math.min(100000, ride.price + 100))}><Plus /></Button>
            </div>
          </div>
          {errors["price"] && <p className="mt-2 text-xs text-destructive">{errors["price"]}</p>}
        </section>

        <Button type="submit" className="h-14 w-full text-base font-semibold shadow-gold">Diffuser ma demande <Navigation /></Button>
      </form>
    </section>
  );
}

function WaitingScreen({ ride, onCancel, onSimulate }: { ride: RideRequest; onCancel: () => void; onSimulate: () => void }) {
  return (
    <section className="glass-panel p-5 text-center sm:p-8">
      <div className="mx-auto grid size-52 place-items-center" aria-label="Recherche de chauffeurs en cours">
        <div className="radar relative grid size-40 place-items-center rounded-full border border-live/30">
          <span className="absolute size-28 rounded-full border border-live/20" />
          <span className="absolute size-16 rounded-full border border-live/30" />
          <span className="absolute left-8 top-10 size-2 rounded-full bg-primary shadow-gold" />
          <span className="absolute bottom-9 right-11 size-2 rounded-full bg-live" />
          <CarFront className="relative z-10 size-7 text-live" />
        </div>
      </div>
      <p className="text-xs font-semibold uppercase text-live">Demande publiée</p>
      <h1 className="mx-auto mt-3 max-w-md text-2xl font-semibold sm:text-3xl">Les taximen à proximité étudient votre offre.</h1>
      <p className="mt-3 text-sm text-muted-foreground">Gardez cet écran ouvert quelques instants.</p>

      <RideSummary ride={ride} />

      <div className="mt-6 grid gap-3 sm:grid-cols-2">
        <Button type="button" variant="outline" onClick={onCancel} className="h-12"><X />Annuler ma demande</Button>
        <Button type="button" onClick={onSimulate} className="h-12 shadow-gold">Simuler l’acceptation</Button>
      </div>
      <p className="mt-4 text-[10px] text-muted-foreground">La simulation est temporaire pour tester le parcours.</p>
    </section>
  );
}

function MatchedScreen({ ride, whatsappMessage, lockedNotice, onDismissLock }: { ride: RideRequest; whatsappMessage: string; lockedNotice: boolean; onDismissLock: () => void }) {
  return (
    <section className="glass-panel overflow-hidden">
      {lockedNotice && (
        <div className="border-b border-live/25 bg-live/10 px-5 py-4 text-center text-sm font-semibold text-live" role="status">Discussion en cours avec le chauffeur...</div>
      )}
      <div className="p-5 sm:p-8">
        <div className="text-center">
          <div className="mx-auto grid size-14 place-items-center rounded-full bg-live/15 text-live"><BadgeCheck className="size-7" /></div>
          <p className="mt-4 text-xs font-semibold uppercase text-live">Chauffeur trouvé</p>
          <h1 className="mt-2 text-3xl font-semibold">Votre course est acceptée.</h1>
        </div>

        <article className="mt-7 grid grid-cols-[88px_minmax(0,1fr)] gap-4 rounded-md border border-border bg-secondary/70 p-4">
          <img src={driverPortrait} alt="Michel, chauffeur Allo Taxi certifié" width={816} height={816} className="aspect-square size-[88px] rounded-md bg-background object-contain" />
          <div className="min-w-0">
            <div className="flex items-center gap-2"><h2 className="truncate text-xl font-semibold">Michel</h2><BadgeCheck className="size-4 shrink-0 text-live" aria-label="Profil certifié" /></div>
            <p className="mt-1 text-xs text-muted-foreground">Toyota Corolla · Gris métallisé</p>
            <p className="mt-3 text-[10px] font-semibold uppercase text-muted-foreground">Plaque validée par l’IA</p>
            <p className="mt-1 text-xl font-bold tracking-normal text-foreground">1234 G 1A</p>
          </div>
        </article>

        <RideSummary ride={ride} />

        <div className="mt-6 flex items-start gap-3 rounded-md border border-primary/20 bg-primary/5 p-4">
          <Phone className="mt-0.5 size-5 shrink-0 text-primary" />
          <p className="text-sm leading-6"><strong>Le chauffeur a accepté votre tarif.</strong> Ouvrez WhatsApp pour finaliser l’embarquement.</p>
        </div>

        <Button asChild className="mt-5 h-14 w-full bg-live text-base font-semibold text-foreground shadow-live hover:bg-live/90">
          <a href={`https://wa.me/?text=${whatsappMessage}`} target="_blank" rel="noreferrer">Ouvrir la discussion privée WhatsApp <ArrowLeft className="rotate-180" /></a>
        </Button>
        {lockedNotice && <Button type="button" variant="ghost" onClick={onDismissLock} className="mt-2 w-full text-xs text-muted-foreground">Rester sur cette course</Button>}
        <p className="mt-4 flex items-center justify-center gap-2 text-[10px] text-muted-foreground"><ShieldCheck className="size-3.5 text-live" />Votre numéro reste privé jusqu’à l’ouverture de WhatsApp.</p>
      </div>
    </section>
  );
}

function RideSummary({ ride }: { ride: RideRequest }) {
  return (
    <div className="mt-7 rounded-md border border-border bg-background/35 p-4 text-left">
      <div className="grid grid-cols-[20px_minmax(0,1fr)] gap-x-3 gap-y-3 text-sm">
        <span aria-hidden="true">📍</span><p className="min-w-0 break-words"><span className="block text-[10px] uppercase text-muted-foreground">Départ</span>{ride.pickup}</p>
        <span aria-hidden="true">🏁</span><p className="min-w-0 break-words"><span className="block text-[10px] uppercase text-muted-foreground">Destination</span>{ride.destination}</p>
      </div>
      <div className="mt-4 grid grid-cols-3 gap-2 border-t border-border pt-4 text-center">
        <SummaryFact icon={<CircleDollarSign />} value={`${ride.price.toLocaleString("fr-FR")} FCFA`} />
        <SummaryFact icon={ride.comfort === "climatise" ? <Snowflake /> : <Wind />} value={ride.comfort === "climatise" ? "Climatisé" : "Standard"} />
        <SummaryFact icon={<Clock3 />} value={paymentLabels[ride.payment]} />
      </div>
    </div>
  );
}

function SummaryFact({ icon, value }: { icon: React.ReactNode; value: string }) {
  return <div className="min-w-0 text-[10px] text-muted-foreground [&_svg]:mx-auto [&_svg]:mb-1.5 [&_svg]:size-4 [&_svg]:text-primary"><span aria-hidden="true">{icon}</span><span className="block break-words">{value}</span></div>;
}

function ChoiceButton({ active, onClick, icon, title, subtitle }: { active: boolean; onClick: () => void; icon: React.ReactNode; title: string; subtitle: string }) {
  return (
    <Button type="button" variant="outline" aria-pressed={active} onClick={onClick} className={cn("h-20 min-w-0 justify-start px-3 text-left", active && "border-primary bg-primary/10 hover:bg-primary/10")}>
      <span className={cn("grid size-9 shrink-0 place-items-center rounded-md bg-secondary text-muted-foreground [&_svg]:size-4", active && "bg-primary text-primary-foreground")}>{icon}</span>
      <span className="min-w-0"><span className="block truncate text-xs font-semibold">{title}</span><span className="block truncate text-[10px] font-normal text-muted-foreground">{subtitle}</span></span>
    </Button>
  );
}

function Field({ label, error, children }: { label: string; error: string | undefined; children: React.ReactNode }) {
  return <label className="block"><span className="mb-2 block text-xs font-medium">{label}</span>{children}{error && <span className="mt-1.5 block text-xs text-destructive" role="alert">{error}</span>}</label>;
}