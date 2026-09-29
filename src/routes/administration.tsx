import { createFileRoute, Link } from "@tanstack/react-router";
import {
  Activity,
  ArrowLeft,
  BadgeDollarSign,
  BarChart3,
  CarFront,
  ChevronRight,
  CircleDollarSign,
  EyeOff,
  Landmark,
  Percent,
  Save,
  ShieldCheck,
  Sparkles,
  TrendingUp,
  UserCog,
  Users,
} from "lucide-react";
import { useEffect, useMemo, useState, type FormEvent } from "react";
import { z } from "zod";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/administration")({
  head: () => ({
    meta: [
      { title: "Pilotage financier — Allo Taxi..?" },
      { name: "description", content: "Gestion financière et droits d’accès de l’administration Allo Taxi..?" },
      { property: "og:title", content: "Pilotage financier — Allo Taxi..?" },
      { property: "og:description", content: "Tableau de bord financier réservé aux administrateurs et associés." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: AdministrationDashboard,
});

type AdminRole = "super_admin" | "associe_xfin" | "associe_promoteur";
type PartnerType = Exclude<AdminRole, "super_admin">;

type Partner = {
  type: PartnerType;
  name: string;
  phone: string;
  share: number;
  active: boolean;
};

const STORAGE_KEY = "allo-taxi-partner-config-v1";
const DAILY_REVENUE = 73000;

const partnerSchema = z.object({
  type: z.enum(["associe_xfin", "associe_promoteur"]),
  name: z.string().trim().min(2, "Indiquez au moins 2 caractères.").max(100, "Le nom est trop long."),
  phone: z.string().trim().regex(/^\+?[0-9\s-]{8,18}$/, "Saisissez un numéro valide."),
  share: z.number().min(0, "La part ne peut pas être négative.").max(100, "La part ne peut pas dépasser 100 %.")
});

const defaultPartners: Record<PartnerType, Partner> = {
  associe_xfin: { type: "associe_xfin", name: "XFin Gabon", phone: "+241 06 00 00 01", share: 20, active: true },
  associe_promoteur: { type: "associe_promoteur", name: "Partenaire Promotion", phone: "+241 07 00 00 02", share: 10, active: true },
};

const roleLabels: Record<AdminRole, string> = {
  super_admin: "Superadministrateur",
  associe_xfin: "Associé 1 · XFin",
  associe_promoteur: "Associé 2 · Promoteur",
};

const months = ["Avr", "Mai", "Juin", "Juil", "Août", "Sept"];
const consolidatedRevenue = [1420000, 1670000, 1540000, 1980000, 2210000, 2380000];

function AdministrationDashboard() {
  const [role, setRole] = useState<AdminRole>("super_admin");
  const [partners, setPartners] = useState<Record<PartnerType, Partner>>(defaultPartners);
  const [hydrated, setHydrated] = useState(false);
  const [editingType, setEditingType] = useState<PartnerType>("associe_xfin");
  const [draft, setDraft] = useState<Partner>(defaultPartners.associe_xfin);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored) {
      try {
        const parsed = JSON.parse(stored) as Record<PartnerType, Partner>;
        if (parsed.associe_xfin && parsed.associe_promoteur) setPartners(parsed);
      } catch {
        localStorage.removeItem(STORAGE_KEY);
      }
    }
    setHydrated(true);
  }, []);

  useEffect(() => {
    if (hydrated) localStorage.setItem(STORAGE_KEY, JSON.stringify(partners));
  }, [hydrated, partners]);

  useEffect(() => {
    setDraft(partners[editingType]);
    setErrors({});
  }, [editingType, partners]);

  useEffect(() => {
    if (!notice) return;
    const timeout = window.setTimeout(() => setNotice(null), 3500);
    return () => window.clearTimeout(timeout);
  }, [notice]);

  const isSuperAdmin = role === "super_admin";
  const currentPartner = role === "super_admin" ? null : partners[role];
  const currentShare = currentPartner?.active ? currentPartner.share : 0;
  const availableShare = Math.round(DAILY_REVENUE * currentShare / 100);
  const chartValues = useMemo(
    () => consolidatedRevenue.map((value) => isSuperAdmin ? value : Math.round(value * currentShare / 100)),
    [currentShare, isSuperAdmin],
  );

  function updateDraft<K extends keyof Partner>(key: K, value: Partner[K]) {
    setDraft((current) => ({ ...current, [key]: value }));
    setErrors((current) => ({ ...current, [key]: "" }));
  }

  function changePartnerType(value: PartnerType) {
    setEditingType(value);
    setDraft(partners[value]);
  }

  function savePartner(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const parsed = partnerSchema.safeParse(draft);
    if (!parsed.success) {
      const nextErrors: Record<string, string> = {};
      for (const issue of parsed.error.issues) nextErrors[String(issue.path[0])] = issue.message;
      setErrors(nextErrors);
      return;
    }
    const configured = { ...parsed.data, active: draft.active };
    setPartners((current) => ({ ...current, [configured.type]: configured }));
    setNotice("Configuration enregistrée. Les calculs ont été actualisés.");
  }

  function togglePartner(type: PartnerType) {
    setPartners((current) => ({ ...current, [type]: { ...current[type], active: !current[type].active } }));
  }

  return (
    <main className="relative min-h-svh overflow-hidden bg-background px-4 py-5 text-foreground sm:px-6 sm:py-8">
      <div className="taxi-grid pointer-events-none absolute inset-0" />
      <div className="relative mx-auto w-full max-w-6xl">
        <header className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-3">
          <Button asChild variant="ghost" size="icon" className="border border-border bg-secondary">
            <Link to="/" aria-label="Retour à l’accueil"><ArrowLeft /></Link>
          </Button>
          <div className="min-w-0 text-center">
            <p className="truncate text-sm font-semibold">Allo Taxi<span className="text-primary">..?</span></p>
            <p className="text-[10px] uppercase text-muted-foreground">Centre de pilotage</p>
          </div>
          <div className="flex items-center gap-2 text-[10px] font-semibold uppercase text-live"><ShieldCheck className="size-4" />Accès protégé</div>
        </header>

        <nav aria-label="Fil d’Ariane" className="mt-6 flex items-center gap-2 text-xs text-muted-foreground">
          <Link to="/" className="hover:text-foreground">Accueil</Link><ChevronRight className="size-3" /><span className="text-foreground">Administration</span><ChevronRight className="size-3" /><span className="text-primary">Finances</span>
        </nav>

        <section className="mt-5 grid gap-4 lg:grid-cols-[minmax(0,1fr)_320px] lg:items-end">
          <div>
            <p className="text-xs font-semibold uppercase text-primary">Pilotage financier</p>
            <h1 className="mt-2 text-3xl font-semibold sm:text-4xl">Vue des revenus et associés</h1>
            <p className="mt-2 max-w-2xl text-sm leading-6 text-muted-foreground">Les chiffres visibles s’adaptent strictement au rôle simulé.</p>
          </div>
          <label className="glass-panel block p-4">
            <span className="mb-2 flex items-center gap-2 text-[10px] font-semibold uppercase text-muted-foreground"><UserCog className="size-3.5 text-primary" />Rôle de test</span>
            <Select value={role} onValueChange={(value) => setRole(value as AdminRole)}>
              <SelectTrigger className="h-11" aria-label="Rôle connecté"><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="super_admin">Superadministrateur</SelectItem>
                <SelectItem value="associe_xfin">Associé 1 · XFin</SelectItem>
                <SelectItem value="associe_promoteur">Associé 2 · Promoteur</SelectItem>
              </SelectContent>
            </Select>
          </label>
        </section>

        {notice && <div className="mt-5 flex items-center gap-3 rounded-md border border-live/30 bg-live/10 px-4 py-3 text-sm text-live" role="status"><BadgeCheckIcon />{notice}</div>}

        <div key={role} className="animate-journey-in">
          <FinancialOverview role={role} share={currentShare} availableShare={availableShare} chartValues={chartValues} />

          {isSuperAdmin ? (
            <>
              <div className="mt-6 grid gap-6 xl:grid-cols-[minmax(0,1.05fr)_minmax(0,.95fr)]">
                <PartnerConfiguration
                  draft={draft}
                  errors={errors}
                  partners={partners}
                  onTypeChange={changePartnerType}
                  onUpdate={updateDraft}
                  onSave={savePartner}
                  onToggle={togglePartner}
                />
                <AccessMatrix partners={partners} />
              </div>
              <SuperAdminModules />
            </>
          ) : (
            <RestrictedAccess role={role} />
          )}
        </div>
      </div>
    </main>
  );
}

function FinancialOverview({ role, share, availableShare, chartValues }: { role: AdminRole; share: number; availableShare: number; chartValues: number[] }) {
  const isSuperAdmin = role === "super_admin";
  return (
    <section className="mt-7">
      <div className="grid gap-4 sm:grid-cols-3">
        {isSuperAdmin ? (
          <>
            <MetricCard icon={<CircleDollarSign />} label="CA brut aujourd’hui" value={`${DAILY_REVENUE.toLocaleString("fr-FR")} FCFA`} detail="73 taxis actifs × 1 000 FCFA" featured />
            <MetricCard icon={<CarFront />} label="Taxis actifs" value="73" detail="Accès journée validé" />
            <MetricCard icon={<TrendingUp />} label="Évolution mensuelle" value="+ 7,7 %" detail="Par rapport au mois dernier" />
          </>
        ) : (
          <div className="sm:col-span-3 rounded-md border border-primary/40 bg-primary p-6 text-primary-foreground shadow-gold sm:p-8">
            <div className="flex items-center gap-2 text-xs font-black uppercase"><Sparkles className="size-4" />{roleLabels[role]}</div>
            <p className="mt-6 text-sm opacity-75">Votre part disponible aujourd’hui</p>
            <p className="mt-2 text-4xl font-black tabular-nums sm:text-5xl">{availableShare.toLocaleString("fr-FR")} <span className="text-lg">FCFA</span></p>
            <p className="mt-4 text-xs font-semibold">Part contractuelle active : {share} %</p>
          </div>
        )}
      </div>
      <RevenueChart values={chartValues} role={role} />
    </section>
  );
}

function RevenueChart({ values, role }: { values: number[]; role: AdminRole }) {
  const max = Math.max(...values, 1);
  const total = values.reduce((sum, value) => sum + value, 0);
  return (
    <section className="glass-panel mt-4 p-5 sm:p-7">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div><p className="flex items-center gap-2 text-sm font-semibold"><BarChart3 className="size-4 text-primary" />Historique consolidé</p><p className="mt-1 text-xs text-muted-foreground">{role === "super_admin" ? "Revenus globaux des six derniers mois" : "Votre quote-part sur les six derniers mois"}</p></div>
        <div className="text-right"><p className="text-[10px] uppercase text-muted-foreground">Cumul affiché</p><p className="mt-1 text-lg font-bold text-primary">{total.toLocaleString("fr-FR")} FCFA</p></div>
      </div>
      <div className="mt-7 grid h-56 grid-cols-6 items-end gap-2 sm:gap-4" aria-label="Graphique des gains des six derniers mois">
        {values.map((value, index) => (
          <div key={months[index]} className="flex h-full min-w-0 flex-col justify-end gap-2 text-center">
            <span className="text-[9px] font-semibold text-muted-foreground">{compactMoney(value)}</span>
            <div className="group relative mx-auto flex h-40 w-full max-w-14 items-end overflow-hidden rounded-sm bg-secondary">
              <div className="w-full rounded-sm bg-primary transition-[height] duration-1000 ease-out group-hover:bg-live" style={{ height: `${Math.max(8, (value / max) * 100)}%` }} />
            </div>
            <span className="text-[10px] text-muted-foreground">{months[index]}</span>
          </div>
        ))}
      </div>
    </section>
  );
}

function PartnerConfiguration({ draft, errors, partners, onTypeChange, onUpdate, onSave, onToggle }: {
  draft: Partner;
  errors: Record<string, string>;
  partners: Record<PartnerType, Partner>;
  onTypeChange: (type: PartnerType) => void;
  onUpdate: <K extends keyof Partner>(key: K, value: Partner[K]) => void;
  onSave: (event: FormEvent<HTMLFormElement>) => void;
  onToggle: (type: PartnerType) => void;
}) {
  return (
    <section className="glass-panel p-5 sm:p-7">
      <div className="flex items-center gap-3"><span className="grid size-10 place-items-center rounded-md bg-primary/10 text-primary"><Users className="size-5" /></span><div><p className="text-xs font-semibold uppercase text-primary">Superadmin uniquement</p><h2 className="text-xl font-semibold">✦ Configuration des Associés</h2></div></div>
      <form onSubmit={onSave} className="mt-6 grid gap-4" noValidate>
        <Field label="Type d’associé" error={errors["type"]}>
          <Select value={draft.type} onValueChange={(value) => onTypeChange(value as PartnerType)}><SelectTrigger className="h-12" aria-label="Type d’associé"><SelectValue /></SelectTrigger><SelectContent><SelectItem value="associe_xfin">Associé 1 (XFin)</SelectItem><SelectItem value="associe_promoteur">Associé 2 (Promoteur)</SelectItem></SelectContent></Select>
        </Field>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Nom / Raison Sociale" error={errors["name"]}><Input value={draft.name} onChange={(event) => onUpdate("name", event.target.value)} maxLength={100} className="h-12" /></Field>
          <Field label="N° Téléphone du compte lié" error={errors["phone"]}><Input value={draft.phone} onChange={(event) => onUpdate("phone", event.target.value)} type="tel" inputMode="tel" maxLength={18} className="h-12" /></Field>
        </div>
        <Field label="Part des revenus (%)" error={errors["share"]}>
          <div className="relative"><Input value={draft.share} onChange={(event) => onUpdate("share", Number(event.target.value))} type="number" min={0} max={100} step={0.5} className="h-12 pr-10 text-lg font-bold tabular-nums" /><Percent className="pointer-events-none absolute right-3 top-3.5 size-4 text-primary" /></div>
        </Field>
        <Button type="submit" className="h-12 w-full font-bold shadow-gold"><Save />Enregistrer la configuration</Button>
      </form>
      <div className="mt-6 grid gap-3 border-t border-border pt-5 sm:grid-cols-2">
        {(Object.keys(partners) as PartnerType[]).map((type) => (
          <div key={type} className="rounded-md border border-border bg-secondary/60 p-3">
            <p className="truncate text-xs font-semibold">{partners[type].name}</p><p className="mt-1 text-[10px] text-muted-foreground">{partners[type].share} % · {partners[type].active ? "Actif" : "Désactivé"}</p>
            <Button type="button" variant="ghost" size="sm" onClick={() => onToggle(type)} className={cn("mt-2 w-full", partners[type].active ? "text-destructive" : "text-live")}>{partners[type].active ? "Désactiver" : "Réactiver"}</Button>
          </div>
        ))}
      </div>
    </section>
  );
}

function AccessMatrix({ partners }: { partners: Record<PartnerType, Partner> }) {
  return (
    <section className="glass-panel p-5 sm:p-7">
      <p className="flex items-center gap-2 text-sm font-semibold"><ShieldCheck className="size-4 text-live" />Cloisonnement des droits</p>
      <p className="mt-2 text-xs leading-5 text-muted-foreground">Aperçu des zones autorisées pour chaque rôle.</p>
      <div className="mt-5 space-y-3">
        <AccessRow role="Superadministrateur" detail="Finances · Associés · Courses · Modération" full />
        <AccessRow role={`Associé 1 · ${partners.associe_xfin.share} %`} detail="Sa carte de gains · Son historique" />
        <AccessRow role={`Associé 2 · ${partners.associe_promoteur.share} %`} detail="Sa carte de gains · Son historique" />
      </div>
      <div className="mt-6 rounded-md border border-border bg-background/35 p-4 text-xs leading-5 text-muted-foreground"><strong className="text-foreground">Isolation active :</strong> les associés ne reçoivent aucune donnée de traçabilité, de modération ou de revenu global dans leur vue.</div>
    </section>
  );
}

function SuperAdminModules() {
  return (
    <section className="mt-6 grid gap-4 sm:grid-cols-2">
      <ModuleCard icon={<Activity />} title="Traçabilité des courses" description="187 mises en relation suivies aujourd’hui" />
      <ModuleCard icon={<ShieldCheck />} title="Modération" description="3 vérifications de profils en attente" />
    </section>
  );
}

function RestrictedAccess({ role }: { role: PartnerType }) {
  return (
    <section className="mt-6 flex items-start gap-4 rounded-md border border-border bg-secondary/55 p-5">
      <span className="grid size-10 shrink-0 place-items-center rounded-md bg-muted text-muted-foreground"><EyeOff className="size-5" /></span>
      <div><p className="text-sm font-semibold">Vue financière privée</p><p className="mt-1 text-xs leading-5 text-muted-foreground">{roleLabels[role]} ne voit que sa part disponible et son historique. La configuration, les courses et la modération restent masquées.</p></div>
    </section>
  );
}

function MetricCard({ icon, label, value, detail, featured = false }: { icon: React.ReactNode; label: string; value: string; detail: string; featured?: boolean }) {
  return <article className={cn("glass-panel p-5", featured && "border-primary/40")}><span className={cn("grid size-9 place-items-center rounded-md bg-secondary text-muted-foreground [&_svg]:size-4", featured && "bg-primary text-primary-foreground")}>{icon}</span><p className="mt-5 text-[10px] font-semibold uppercase text-muted-foreground">{label}</p><p className={cn("mt-2 break-words text-2xl font-black tabular-nums", featured && "text-primary")}>{value}</p><p className="mt-2 text-[10px] text-muted-foreground">{detail}</p></article>;
}

function AccessRow({ role, detail, full = false }: { role: string; detail: string; full?: boolean }) {
  return <div className="flex items-start gap-3 rounded-md border border-border bg-secondary/60 p-4"><span className={cn("mt-0.5 grid size-7 shrink-0 place-items-center rounded-full", full ? "bg-live/15 text-live" : "bg-primary/15 text-primary")}>{full ? <ShieldCheck className="size-3.5" /> : <Landmark className="size-3.5" />}</span><div><p className="text-xs font-semibold">{role}</p><p className="mt-1 text-[10px] leading-4 text-muted-foreground">{detail}</p></div></div>;
}

function ModuleCard({ icon, title, description }: { icon: React.ReactNode; title: string; description: string }) {
  return <article className="glass-panel flex items-center gap-4 p-5"><span className="grid size-11 shrink-0 place-items-center rounded-md bg-live/10 text-live [&_svg]:size-5">{icon}</span><div><p className="text-sm font-semibold">{title}</p><p className="mt-1 text-xs text-muted-foreground">{description}</p></div></article>;
}

function BadgeCheckIcon() {
  return <span className="grid size-5 shrink-0 place-items-center rounded-full bg-live text-background"><span className="text-xs font-black">✓</span></span>;
}

function Field({ label, error, children }: { label: string; error: string | undefined; children: React.ReactNode }) {
  return <label className="block"><span className="mb-2 block text-xs font-medium">{label}</span>{children}{error && <span className="mt-1.5 block text-xs text-destructive" role="alert">{error}</span>}</label>;
}

function compactMoney(value: number) {
  if (value >= 1000000) return `${(value / 1000000).toLocaleString("fr-FR", { maximumFractionDigits: 1 })} M`;
  if (value >= 1000) return `${Math.round(value / 1000)} k`;
  return value.toLocaleString("fr-FR");
}