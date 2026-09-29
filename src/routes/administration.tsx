import { createFileRoute, Link } from "@tanstack/react-router";
import {
  Activity,
  ArrowLeft,
  BadgeDollarSign,
  BarChart3,
  CarFront,
  ChevronRight,
  CircleDollarSign,
  Clock3,
  Download,
  Eye,
  EyeOff,
  FileClock,
  Landmark,
  MapPin,
  Percent,
  Phone,
  Route as RouteIcon,
  Save,
  ShieldCheck,
  Sparkles,
  TrendingUp,
  UserCog,
  Users,
} from "lucide-react";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { LogOut } from "lucide-react";
import { z } from "zod";

import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
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

type AuditStatus = "boarded" | "failed" | "timeout";

type AuditRide = {
  id: string;
  dateTime: string;
  driver: { name: string; phone: string; vehicle: string; plate: string };
  client: { name: string; phone: string };
  pickup: string;
  destination: string;
  price: number;
  status: AuditStatus;
  timeline: { time: string; label: string }[];
};

type Finance = {
  todayRevenue: number;
  activeDrivers: number;
  months: { label: string; value: number }[];
  myTodayShare: number;
};

const partnerSchema = z.object({
  type: z.enum(["associe_xfin", "associe_promoteur"]),
  name: z.string().trim().min(2, "Indiquez au moins 2 caractères.").max(100, "Le nom est trop long."),
  phone: z.string().trim().regex(/^\+?[0-9\s-]{8,18}$/, "Saisissez un numéro valide."),
  share: z.number().min(0, "La part ne peut pas être négative.").max(100, "La part ne peut pas dépasser 100 %.")
});

const partnerKeys: Record<PartnerType, "xfin" | "promoteur"> = { associe_xfin: "xfin", associe_promoteur: "promoteur" };
const keyToType = (key: string): PartnerType => (key === "xfin" ? "associe_xfin" : "associe_promoteur");

const emptyPartners: Record<PartnerType, Partner> = {
  associe_xfin: { type: "associe_xfin", name: "", phone: "+241", share: 0, active: true },
  associe_promoteur: { type: "associe_promoteur", name: "", phone: "+241", share: 0, active: true },
};

const roleLabels: Record<AdminRole, string> = {
  super_admin: "Superadministrateur",
  associe_xfin: "Associé 1 · XFin",
  associe_promoteur: "Associé 2 · Promoteur",
};

function lastSixMonths() {
  const now = new Date();
  return Array.from({ length: 6 }, (_, index) => {
    const date = new Date(now.getFullYear(), now.getMonth() - 5 + index, 1);
    return { key: `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`, label: date.toLocaleDateString("fr-FR", { month: "short" }).replace(".", "") };
  });
}

function AdministrationDashboard() {
  const { user, roles, loading, refreshRoles } = useSession();
  const [partners, setPartners] = useState<Record<PartnerType, Partner>>(emptyPartners);
  const [myPartnerType, setMyPartnerType] = useState<PartnerType | null>(null);
  const [editingType, setEditingType] = useState<PartnerType>("associe_xfin");
  const [draft, setDraft] = useState<Partner>(emptyPartners.associe_xfin);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [notice, setNotice] = useState<string | null>(null);
  const [finance, setFinance] = useState<Finance>({ todayRevenue: 0, activeDrivers: 0, months: lastSixMonths().map((m) => ({ label: m.label, value: 0 })), myTodayShare: 0 });

  const isSuperAdmin = roles.includes("super_admin");
  const isAssociate = roles.includes("associe");
  const role: AdminRole | null = isSuperAdmin ? "super_admin" : isAssociate && myPartnerType ? myPartnerType : null;

  const loadData = useCallback(async () => {
    if (!isSuperAdmin && !isAssociate) return;
    const [{ data: settings }, { data: split }, { data: today }] = await Promise.all([
      supabase.from("associates_settings").select("*").is("deleted_at", null),
      supabase.rpc("financial_dashboard_split"),
      supabase.rpc("financial_today_split"),
    ]);
    const nextPartners = { ...emptyPartners };
    for (const row of settings ?? []) {
      const type = keyToType(row.partner_key);
      nextPartners[type] = { type, name: row.display_name, phone: row.phone, share: Number(row.share_percent), active: row.is_active };
    }
    setPartners(nextPartners);
    const mine = (settings ?? []).find((row) => row.user_id === user?.id);
    setMyPartnerType(mine ? keyToType(mine.partner_key) : null);

    const rows = split ?? [];
    const months = lastSixMonths().map((month) => {
      const monthRows = rows.filter((row) => row.month?.startsWith(month.key));
      const value = isSuperAdmin
        ? Number(monthRows[0]?.gross_revenue ?? 0)
        : monthRows.reduce((sum, row) => sum + Number(row.partner_amount ?? 0), 0);
      return { label: month.label, value };
    });
    setFinance({
      todayRevenue: Number(rows[0]?.today_revenue ?? 0),
      activeDrivers: Number(rows[0]?.active_drivers_today ?? 0),
      months,
      myTodayShare: (today ?? []).filter((row) => !isSuperAdmin || row.partner_key === mine?.partner_key).reduce((sum, row) => sum + Number(row.today_amount), 0),
    });
  }, [isAssociate, isSuperAdmin, user?.id]);

  useEffect(() => { void loadData(); }, [loadData]);

  useEffect(() => {
    setDraft(partners[editingType]);
    setErrors({});
  }, [editingType, partners]);

  useEffect(() => {
    if (!notice) return;
    const timeout = window.setTimeout(() => setNotice(null), 3500);
    return () => window.clearTimeout(timeout);
  }, [notice]);

  const currentShare = role && role !== "super_admin" && partners[role].active ? partners[role].share : 0;

  function updateDraft<K extends keyof Partner>(key: K, value: Partner[K]) {
    setDraft((current) => ({ ...current, [key]: value }));
    setErrors((current) => ({ ...current, [key]: "" }));
  }

  function changePartnerType(value: PartnerType) {
    setEditingType(value);
    setDraft(partners[value]);
  }

  async function savePartner(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const parsed = partnerSchema.safeParse(draft);
    if (!parsed.success) {
      const nextErrors: Record<string, string> = {};
      for (const issue of parsed.error.issues) nextErrors[String(issue.path[0])] = issue.message;
      setErrors(nextErrors);
      return;
    }
    const { error } = await supabase.from("associates_settings").upsert(
      { partner_key: partnerKeys[parsed.data.type], display_name: parsed.data.name, phone: parsed.data.phone, share_percent: parsed.data.share, is_active: draft.active, updated_at: new Date().toISOString() },
      { onConflict: "partner_key" },
    );
    if (error) return setNotice("Enregistrement impossible. Réessayez.");
    setNotice("Configuration enregistrée. Les calculs ont été actualisés.");
    void loadData();
  }

  async function togglePartner(type: PartnerType) {
    const { error } = await supabase.from("associates_settings").update({ is_active: !partners[type].active, updated_at: new Date().toISOString() }).eq("partner_key", partnerKeys[type]);
    if (error) return setNotice("Associé non configuré : enregistrez d’abord sa fiche.");
    void loadData();
  }

  async function claimSuperAdmin() {
    const { data } = await supabase.rpc("claim_first_superadmin");
    if (data) {
      await refreshRoles();
      setNotice("Compte Superadministrateur activé.");
    } else setNotice("Un Superadministrateur existe déjà. Demandez-lui vos droits.");
  }

  const shell = (children: React.ReactNode) => (
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
          {user ? (
            <Button type="button" variant="ghost" size="sm" onClick={() => void supabase.auth.signOut()} className="text-[10px] uppercase text-muted-foreground"><LogOut className="size-3.5" />Quitter</Button>
          ) : (
            <div className="flex items-center gap-2 text-[10px] font-semibold uppercase text-live"><ShieldCheck className="size-4" />Accès protégé</div>
          )}
        </header>
        <nav aria-label="Fil d’Ariane" className="mt-6 flex items-center gap-2 text-xs text-muted-foreground">
          <Link to="/" className="hover:text-foreground">Accueil</Link><ChevronRight className="size-3" /><span className="text-foreground">Administration</span><ChevronRight className="size-3" /><span className="text-primary">Finances</span>
        </nav>
        {notice && <div className="mt-5 flex items-center gap-3 rounded-md border border-live/30 bg-live/10 px-4 py-3 text-sm text-live" role="status"><BadgeCheckIcon />{notice}</div>}
        {children}
      </div>
    </main>
  );

  if (loading) return shell(<p className="mt-10 text-center text-sm text-muted-foreground">Chargement…</p>);
  if (!user) {
    return shell(
      <section className="glass-panel mx-auto mt-10 max-w-md p-8 text-center">
        <ShieldCheck className="mx-auto size-8 text-primary" />
        <h1 className="mt-4 text-2xl font-semibold">Espace réservé</h1>
        <p className="mt-2 text-sm text-muted-foreground">Superadministrateur et associés uniquement.</p>
        <Button asChild className="mt-6 h-12 w-full font-bold shadow-gold"><Link to="/connexion" search={{ retour: "/administration" }}>Se connecter</Link></Button>
      </section>,
    );
  }
  if (!role) {
    return shell(
      <section className="glass-panel mx-auto mt-10 max-w-md p-8 text-center">
        <EyeOff className="mx-auto size-8 text-muted-foreground" />
        <h1 className="mt-4 text-2xl font-semibold">Aucun droit d’administration</h1>
        <p className="mt-2 text-sm text-muted-foreground">{isAssociate ? "Votre compte associé n’est pas encore relié à une fiche associé." : "Ce compte n’a pas encore de rôle d’administration."}</p>
        {!isAssociate && <Button type="button" variant="outline" onClick={() => void claimSuperAdmin()} className="mt-6 h-11 w-full text-xs">Premier lancement : devenir Superadministrateur</Button>}
      </section>,
    );
  }

  return shell(
    <>
      <section className="mt-5">
        <p className="text-xs font-semibold uppercase text-primary">Pilotage financier</p>
        <h1 className="mt-2 text-3xl font-semibold sm:text-4xl">Vue des revenus et associés</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-muted-foreground">Connecté en tant que <strong className="text-foreground">{roleLabels[role]}</strong>. Les chiffres proviennent des abonnements réellement validés.</p>
      </section>

      <div className="animate-journey-in">
        <FinancialOverview role={role} share={currentShare} finance={finance} />

        {isSuperAdmin ? (
          <>
            <div className="mt-6 grid gap-6 xl:grid-cols-[minmax(0,1.05fr)_minmax(0,.95fr)]">
              <PartnerConfiguration
                draft={draft}
                errors={errors}
                partners={partners}
                onTypeChange={changePartnerType}
                onUpdate={updateDraft}
                onSave={(event) => void savePartner(event)}
                onToggle={(type) => void togglePartner(type)}
              />
              <AccessMatrix partners={partners} />
            </div>
            <SuperAdminModules onNotice={setNotice} />
          </>
        ) : (
          <RestrictedAccess role={role as PartnerType} />
        )}
      </div>
    </>,
  );
}

function FinancialOverview({ role, share, finance }: { role: AdminRole; share: number; finance: Finance }) {
  const isSuperAdmin = role === "super_admin";
  const values = finance.months.map((m) => m.value);
  const last = values[5] ?? 0;
  const previous = values[4] ?? 0;
  const trend = previous > 0 ? `${last >= previous ? "+" : "−"} ${Math.abs(((last - previous) / previous) * 100).toLocaleString("fr-FR", { maximumFractionDigits: 1 })} %` : "—";
  return (
    <section className="mt-7">
      <div className="grid gap-4 sm:grid-cols-3">
        {isSuperAdmin ? (
          <>
            <MetricCard icon={<CircleDollarSign />} label="CA brut aujourd’hui" value={`${finance.todayRevenue.toLocaleString("fr-FR")} FCFA`} detail={`${finance.activeDrivers} taxis actifs × 1 000 FCFA`} featured />
            <MetricCard icon={<CarFront />} label="Taxis actifs" value={String(finance.activeDrivers)} detail="Accès journée validé" />
            <MetricCard icon={<TrendingUp />} label="Évolution mensuelle" value={trend} detail="Mois en cours vs mois dernier" />
          </>
        ) : (
          <div className="sm:col-span-3 rounded-md border border-primary/40 bg-primary p-6 text-primary-foreground shadow-gold sm:p-8">
            <div className="flex items-center gap-2 text-xs font-black uppercase"><Sparkles className="size-4" />{roleLabels[role]}</div>
            <p className="mt-6 text-sm opacity-75">Votre part disponible ({share} % définis) aujourd’hui</p>
            <p className="mt-2 text-4xl font-black tabular-nums sm:text-5xl">{finance.myTodayShare.toLocaleString("fr-FR")} <span className="text-lg">FCFA</span></p>
            <p className="mt-4 text-xs font-semibold">Part contractuelle active : {share} %</p>
          </div>
        )}
      </div>
      <RevenueChart months={finance.months} role={role} />
    </section>
  );
}

function RevenueChart({ months, role }: { months: Finance["months"]; role: AdminRole }) {
  const values = months.map((m) => m.value);
  const max = Math.max(...values, 1);
  const total = values.reduce((sum, value) => sum + value, 0);
  return (
    <section className="glass-panel mt-4 p-5 sm:p-7">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div><p className="flex items-center gap-2 text-sm font-semibold"><BarChart3 className="size-4 text-primary" />Historique consolidé</p><p className="mt-1 text-xs text-muted-foreground">{role === "super_admin" ? "Revenus globaux des six derniers mois" : "Votre quote-part sur les six derniers mois"}</p></div>
        <div className="text-right"><p className="text-[10px] uppercase text-muted-foreground">Cumul affiché</p><p className="mt-1 text-lg font-bold text-primary">{total.toLocaleString("fr-FR")} FCFA</p></div>
      </div>
      <div className="mt-7 grid h-56 grid-cols-6 items-end gap-2 sm:gap-4" aria-label="Graphique des gains des six derniers mois">
        {months.map((month) => (
          <div key={month.label} className="flex h-full min-w-0 flex-col justify-end gap-2 text-center">
            <span className="text-[9px] font-semibold text-muted-foreground">{compactMoney(month.value)}</span>
            <div className="group relative mx-auto flex h-40 w-full max-w-14 items-end overflow-hidden rounded-sm bg-secondary">
              <div className="w-full rounded-sm bg-primary transition-[height] duration-1000 ease-out group-hover:bg-live" style={{ height: `${Math.max(4, (month.value / max) * 100)}%` }} />
            </div>
            <span className="text-[10px] capitalize text-muted-foreground">{month.label}</span>
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

function SuperAdminModules({ onNotice }: { onNotice: (message: string) => void }) {
  return (
    <>
      <AuditRegistry />
      <DriverModeration onNotice={onNotice} />
    </>
  );
}

type PendingDriver = { user_id: string; first_name: string; phone: string; vehicle_model: string; vehicle_plate: string; has_ac: boolean; created_at: string };

function DriverModeration({ onNotice }: { onNotice: (message: string) => void }) {
  const [drivers, setDrivers] = useState<PendingDriver[]>([]);
  const load = useCallback(async () => {
    const { data } = await supabase.from("drivers").select("user_id, first_name, phone, vehicle_model, vehicle_plate, has_ac, created_at").eq("status", "pending").order("created_at");
    setDrivers(data ?? []);
  }, []);
  useEffect(() => { void load(); }, [load]);

  async function decide(userId: string, approve: boolean) {
    const { error } = await supabase.rpc("approve_driver", { _user_id: userId, _approve: approve });
    if (error) return onNotice("Décision non enregistrée. Réessayez.");
    onNotice(approve ? "Chauffeur validé : il peut activer sa journée." : "Dossier refusé et compte suspendu.");
    void load();
  }

  return (
    <section className="glass-panel mt-4 p-5 sm:p-7">
      <p className="flex items-center gap-2 text-sm font-semibold"><ShieldCheck className="size-4 text-live" />Modération des chauffeurs</p>
      <p className="mt-1 text-xs text-muted-foreground">{drivers.length} dossier{drivers.length > 1 ? "s" : ""} en attente de validation</p>
      <div className="mt-4 space-y-3">
        {drivers.map((driver) => (
          <div key={driver.user_id} className="flex flex-col gap-3 rounded-md border border-border bg-secondary/60 p-4 sm:flex-row sm:items-center sm:justify-between">
            <div className="min-w-0">
              <p className="text-sm font-semibold">{driver.first_name} · {driver.vehicle_model}</p>
              <p className="mt-1 text-xs font-bold uppercase text-primary">{driver.vehicle_plate}</p>
              <p className="mt-1 text-[10px] text-muted-foreground">{maskPhone(driver.phone)} · {driver.has_ac ? "Climatisé" : "Standard"}</p>
            </div>
            <div className="grid shrink-0 grid-cols-2 gap-2">
              <Button type="button" variant="outline" size="sm" onClick={() => void decide(driver.user_id, false)} className="text-destructive">Refuser</Button>
              <Button type="button" size="sm" onClick={() => void decide(driver.user_id, true)} className="bg-live text-foreground hover:bg-live/90">Valider</Button>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

const auditStatusMap: Record<string, AuditStatus> = { completed: "boarded", canceled: "failed", timeout: "timeout" };

function timeOf(value: string | null) {
  return value ? new Date(value).toLocaleTimeString("fr-FR", { timeZone: "Africa/Libreville" }) : "";
}

function AuditRegistry() {
  const [auditRides, setAuditRides] = useState<AuditRide[]>([]);
  const [revealed, setRevealed] = useState<Record<string, boolean>>({});
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [activeRide, setActiveRide] = useState<AuditRide | null>(null);

  useEffect(() => {
    supabase.rpc("export_full_ride_logs").then(({ data }) => {
      const rows: AuditRide[] = (data ?? []).map((log) => {
        const status = auditStatusMap[log.resolution_status] ?? "failed";
        const timeline = [
          log.published_at && { time: timeOf(log.published_at), label: "Course publiée par le client" },
          log.matched_at && { time: timeOf(log.matched_at), label: "Course acceptée par le taxi · redirection WhatsApp" },
          { time: timeOf(log.resolved_at), label: status === "boarded" ? "Chauffeur valide l’embarquement" : status === "timeout" ? "Délai de négociation expiré" : "Échec de la discussion déclaré" },
        ].filter(Boolean) as { time: string; label: string }[];
        return {
          id: log.id,
          dateTime: new Date(log.resolved_at).toLocaleString("fr-FR", { timeZone: "Africa/Libreville", dateStyle: "short", timeStyle: "short" }).replace(" ", " · "),
          driver: { name: log.chauffeur_name ?? "—", phone: log.chauffeur_phone ?? "", vehicle: "", plate: log.vehicle_plate ?? "" },
          client: { name: log.client_name, phone: log.client_phone },
          pickup: log.pickup_location,
          destination: log.dropoff_location,
          price: log.proposed_price,
          status,
          timeline,
        };
      });
      setAuditRides(rows);
      setSelectedIds(rows.map((ride) => ride.id));
    });
  }, []);

  function togglePhone(key: string) {
    setRevealed((current) => ({ ...current, [key]: !current[key] }));
  }

  function toggleSelection(id: string) {
    setSelectedIds((current) => current.includes(id) ? current.filter((value) => value !== id) : [...current, id]);
  }

  function exportCsv() {
    const selected = auditRides.filter((ride) => selectedIds.includes(ride.id));
    if (selected.length === 0) return;
    const headers = ["Référence", "Date/Heure", "Chauffeur", "Téléphone chauffeur", "Véhicule", "Plaque", "Client", "Téléphone client", "Départ", "Destination", "Prix (FCFA)", "Statut"];
    const rows = selected.map((ride) => [
      ride.id,
      ride.dateTime,
      ride.driver.name,
      ride.driver.phone,
      ride.driver.vehicle,
      ride.driver.plate,
      ride.client.name,
      ride.client.phone,
      ride.pickup,
      ride.destination,
      String(ride.price),
      statusLabels[ride.status],
    ]);
    const csv = `\uFEFF${[headers, ...rows].map((row) => row.map(csvCell).join(";")).join("\r\n")}`;
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `allo-taxi-audit-${new Date().toISOString().slice(0, 10)}.csv`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  }

  return (
    <section className="glass-panel mt-6 overflow-hidden" aria-labelledby="audit-title">
      <div className="flex flex-col gap-4 border-b border-border p-5 sm:flex-row sm:items-center sm:justify-between sm:p-7">
        <div>
          <p className="flex items-center gap-2 text-[10px] font-semibold uppercase text-primary"><FileClock className="size-4" />Superadmin uniquement</p>
          <h2 id="audit-title" className="mt-2 text-xl font-semibold">📁 Registre de Traçabilité &amp; Audit</h2>
          <p className="mt-1 text-xs text-muted-foreground">{auditRides.length} mises en relation enregistrées aujourd’hui · {selectedIds.length} sélectionnée{selectedIds.length > 1 ? "s" : ""}</p>
        </div>
        <Button type="button" onClick={exportCsv} disabled={selectedIds.length === 0} className="h-11 shrink-0 font-bold shadow-gold">
          <Download />Exporter la sélection en CSV
        </Button>
      </div>

      <Table>
        <TableHeader>
          <TableRow className="bg-secondary/60 hover:bg-secondary/60">
            <TableHead className="w-10 pl-5"><span className="sr-only">Sélection</span></TableHead>
            <TableHead className="min-w-32">Date/Heure</TableHead>
            <TableHead className="min-w-56">Chauffeur (Véhicule &amp; Plaque)</TableHead>
            <TableHead className="min-w-44">Client</TableHead>
            <TableHead className="min-w-60">Trajet (Départ/Destination)</TableHead>
            <TableHead className="min-w-28">Prix (FCFA)</TableHead>
            <TableHead className="min-w-28 pr-5">Statut</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {auditRides.map((ride) => {
            const driverKey = `${ride.id}-driver`;
            const clientKey = `${ride.id}-client`;
            return (
              <TableRow key={ride.id} tabIndex={0} role="button" aria-label={`Voir les détails de la course ${ride.id}`} onClick={() => setActiveRide(ride)} onKeyDown={(event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); setActiveRide(ride); } }} className="cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring">
                <TableCell className="pl-5" onClick={(event) => event.stopPropagation()}>
                  <input type="checkbox" checked={selectedIds.includes(ride.id)} onChange={() => toggleSelection(ride.id)} aria-label={`Sélectionner la course ${ride.id}`} className="size-4 accent-primary" />
                </TableCell>
                <TableCell><p className="text-xs font-semibold">{ride.dateTime}</p><p className="mt-1 text-[10px] text-muted-foreground">{ride.id}</p></TableCell>
                <TableCell>
                  <p className="text-xs font-semibold">{ride.driver.name} · {ride.driver.vehicle}</p>
                  <p className="mt-1 text-[10px] font-bold uppercase text-primary">{ride.driver.plate}</p>
                  <PhoneValue phone={ride.driver.phone} revealed={Boolean(revealed[driverKey])} label={`numéro du chauffeur ${ride.driver.name}`} onToggle={() => togglePhone(driverKey)} />
                </TableCell>
                <TableCell><p className="text-xs font-semibold">{ride.client.name}</p><PhoneValue phone={ride.client.phone} revealed={Boolean(revealed[clientKey])} label={`numéro du client ${ride.client.name}`} onToggle={() => togglePhone(clientKey)} /></TableCell>
                <TableCell><p className="text-xs"><span className="text-muted-foreground">Départ :</span> {ride.pickup}</p><p className="mt-1 text-xs"><span className="text-muted-foreground">Destination :</span> {ride.destination}</p></TableCell>
                <TableCell className="font-black tabular-nums text-primary">{ride.price.toLocaleString("fr-FR")}</TableCell>
                <TableCell className="pr-5"><StatusBadge status={ride.status} /></TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>

      <Sheet open={Boolean(activeRide)} onOpenChange={(open) => { if (!open) setActiveRide(null); }}>
        <SheetContent side="right" className="w-[92vw] overflow-y-auto border-border bg-card/95 p-0 backdrop-blur-xl sm:max-w-lg">
          {activeRide && <AuditDrawer ride={activeRide} />}
        </SheetContent>
      </Sheet>
    </section>
  );
}

function PhoneValue({ phone, revealed, label, onToggle }: { phone: string; revealed: boolean; label: string; onToggle: () => void }) {
  return (
    <div className="mt-1 flex items-center gap-1.5 text-[10px] text-muted-foreground">
      <Phone className="size-3" /><span className="font-mono tabular-nums">{revealed ? formatPhone(phone) : maskPhone(phone)}</span>
      <Button type="button" variant="ghost" size="icon" onClick={(event) => { event.stopPropagation(); onToggle(); }} className="size-6 text-muted-foreground hover:text-primary" aria-label={`${revealed ? "Masquer" : "Révéler"} le ${label}`} title={`${revealed ? "Masquer" : "Révéler"} le numéro`}>
        {revealed ? <EyeOff className="size-3.5" /> : <Eye className="size-3.5 animate-pulse" />}
      </Button>
    </div>
  );
}

const statusLabels: Record<AuditStatus, string> = { boarded: "Embarqué", failed: "Échec Négo", timeout: "Time-out" };

function StatusBadge({ status }: { status: AuditStatus }) {
  const styles: Record<AuditStatus, string> = { boarded: "border-live/30 bg-live/10 text-live", failed: "border-destructive/30 bg-destructive/10 text-destructive", timeout: "border-primary/30 bg-primary/10 text-primary" };
  const dots: Record<AuditStatus, string> = { boarded: "bg-live", failed: "bg-destructive", timeout: "bg-primary" };
  return <span className={cn("inline-flex items-center gap-1.5 whitespace-nowrap rounded-full border px-2.5 py-1 text-[10px] font-bold", styles[status])}><span className={cn("size-1.5 rounded-full shadow-current", dots[status])} />{statusLabels[status]}</span>;
}

function AuditDrawer({ ride }: { ride: AuditRide }) {
  return (
    <div className="min-h-full">
      <SheetHeader className="border-b border-border p-6 pr-14 text-left">
        <p className="text-[10px] font-semibold uppercase text-primary">Audit Trail · {ride.id}</p>
        <SheetTitle className="text-2xl">Chronologie de la course</SheetTitle>
        <SheetDescription>{ride.dateTime} · <StatusBadge status={ride.status} /></SheetDescription>
      </SheetHeader>
      <div className="p-6">
        <div className="grid gap-3 rounded-md border border-border bg-secondary/60 p-4 text-xs">
          <p className="flex gap-2"><MapPin className="mt-0.5 size-4 shrink-0 text-primary" /><span><strong>Départ</strong><br /><span className="text-muted-foreground">{ride.pickup}</span></span></p>
          <p className="flex gap-2"><RouteIcon className="mt-0.5 size-4 shrink-0 text-live" /><span><strong>Destination</strong><br /><span className="text-muted-foreground">{ride.destination}</span></span></p>
          <div className="border-t border-border pt-3"><p><strong>{ride.client.name}</strong> avec {ride.driver.name}</p><p className="mt-1 text-muted-foreground">{ride.driver.vehicle} · <span className="font-bold text-primary">{ride.driver.plate}</span></p><p className="mt-2 text-lg font-black text-primary">{ride.price.toLocaleString("fr-FR")} FCFA</p></div>
        </div>
        <div className="mt-7">
          <p className="flex items-center gap-2 text-sm font-semibold"><Clock3 className="size-4 text-primary" />Historique millimétré</p>
          <ol className="relative mt-5 ml-2 border-l border-border">
            {ride.timeline.map((entry, index) => (
              <li key={`${entry.time}-${entry.label}`} className="relative ml-6 pb-7 last:pb-0">
                <span className={cn("absolute -left-[31px] top-0.5 size-3 rounded-full border-2 border-card", index === ride.timeline.length - 1 ? "bg-live shadow-live" : "bg-primary")} />
                <time className="font-mono text-xs font-bold tabular-nums text-primary">{entry.time}</time>
                <p className="mt-1 text-sm leading-5 text-foreground">{entry.label}</p>
              </li>
            ))}
          </ol>
        </div>
      </div>
    </div>
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

function formatPhone(phone: string) {
  const digits = phone.replace(/\D/g, "");
  if (digits.length !== 12 || !digits.startsWith("241")) return phone;
  return `+241 ${digits.slice(3, 6)} ${digits.slice(6, 8)} ${digits.slice(8, 10)} ${digits.slice(10, 12)}`;
}

function maskPhone(phone: string) {
  const formatted = formatPhone(phone);
  const parts = formatted.split(" ");
  if (parts.length !== 5) return phone.replace(/\d(?=\d{4})/g, "*");
  return `${parts[0]} ${parts[1]} ${parts[2]} ** **`;
}

function csvCell(value: string) {
  return `"${value.replaceAll('"', '""')}"`;
}