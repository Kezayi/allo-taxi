import { AlertTriangle, CheckCircle2, Clock3, FileWarning, Loader2, Paperclip, Save, ShieldCheck, Upload, X } from "lucide-react";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { supabase } from "@/integrations/supabase/client";
import { cn } from "@/lib/utils";

export const DOC_LABELS: Record<string, string> = {
  identity_document: "Pièce d’identité",
  driver_photo: "Photo du chauffeur",
  driving_license: "Permis de conduire",
  registration_card: "Carte grise",
  insurance: "Assurance",
  technical_inspection: "Visite technique",
  vehicle_photo: "Photo du véhicule",
  vehicle_plate_photo: "Photo visible de la plaque",
};

export const ACCEPTED_MIME = ["image/jpeg", "image/png", "image/webp", "application/pdf"];
export const MAX_BYTES = 8 * 1024 * 1024;

export type OnboardingDoc = {
  doc_type: string;
  scope: "driver" | "vehicle";
  required_expiry: boolean;
  present: boolean;
  document_id: string | null;
  status: string | null;
  expires_on: string | null;
  version: number | null;
  submitted_at: string | null;
  correction_reason: string | null;
};

export type OnboardingVehicle = {
  id: string;
  make: string | null;
  model: string | null;
  color: string | null;
  plate: string | null;
  has_ac: boolean;
  registered_seats: number | null;
  passenger_capacity: number | null;
  validation_status: string;
};

export type Onboarding = {
  driver: { onboarding_status: string; status: string; first_name: string; last_name: string | null };
  global_state: string;
  active_vehicle: OnboardingVehicle | null;
  documents: OnboardingDoc[];
  summary: { total_required: number; approved: number; missing: number };
};

const GLOBAL_LABELS: Record<string, { label: string; tone: "live" | "gold" | "danger" | "muted"; text: string }> = {
  approved: { label: "Dossier validé", tone: "live", text: "Toutes vos pièces et votre véhicule sont validés." },
  pending_review: { label: "En attente d’examen", tone: "gold", text: "Complétez votre dossier : l’administration examine chaque pièce déposée." },
  correction_required: { label: "Correction demandée", tone: "danger", text: "Une pièce ou votre véhicule nécessite une correction. Déposez une nouvelle version." },
  document_expired: { label: "Pièce expirée", tone: "danger", text: "Une pièce validée a dépassé sa date d’échéance. Déposez une version à jour." },
};

export function docStatusChip(status: string | null) {
  if (!status) return { label: "Manquant", tone: "muted" as const };
  if (status === "approved") return { label: "Approuvé", tone: "live" as const };
  if (status === "submitted") return { label: "En attente", tone: "gold" as const };
  if (status === "rejected") return { label: "Correction demandée", tone: "danger" as const };
  if (status === "expired") return { label: "Expiré", tone: "danger" as const };
  return { label: status, tone: "muted" as const };
}

export function Chip({ tone, children }: { tone: "live" | "gold" | "danger" | "muted"; children: React.ReactNode }) {
  const tones = {
    live: "border-live/30 bg-live/10 text-live",
    gold: "border-primary/30 bg-primary/10 text-primary",
    danger: "border-destructive/35 bg-destructive/10 text-destructive",
    muted: "border-border bg-secondary text-muted-foreground",
  };
  return <span className={cn("inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[10px] font-semibold uppercase", tones[tone])}>{children}</span>;
}

function frDate(value: string | null) {
  return value ? new Date(value).toLocaleDateString("fr-FR", { timeZone: "Africa/Libreville", day: "2-digit", month: "2-digit", year: "numeric" }) : "—";
}

export function DriverOnboarding({ userId, onNotice }: { userId: string; onNotice: (message: string) => void }) {
  const [data, setData] = useState<Onboarding | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    const { data: result, error } = await supabase.rpc("get_my_driver_onboarding");
    setLoading(false);
    if (error) return onNotice("Dossier indisponible pour le moment.");
    setData(result as unknown as Onboarding);
  }, [onNotice]);

  useEffect(() => { void load(); }, [load]);

  if (loading) {
    return <section className="glass-panel mt-5 grid place-items-center p-10 text-muted-foreground"><Loader2 className="size-6 animate-spin" /></section>;
  }
  if (!data) return null;

  const global = GLOBAL_LABELS[data.global_state] ?? GLOBAL_LABELS["pending_review"]!;
  const vehicleDocsBlocked = data.active_vehicle === null;

  return (
    <section className="mt-5 space-y-5">
      <div className="glass-panel p-5 sm:p-6">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <p className="text-xs font-semibold uppercase text-primary">Mon dossier</p>
            <h2 className="mt-1 text-xl font-semibold">{global.label}</h2>
            <p className="mt-2 max-w-xl text-sm leading-6 text-muted-foreground">{global.text}</p>
          </div>
          <Chip tone={global.tone}>{data.summary.approved}/{data.summary.total_required} pièces approuvées</Chip>
        </div>
        <div className="mt-4 h-2 overflow-hidden rounded-full bg-secondary">
          <div className="h-full rounded-full bg-primary transition-[width] duration-700" style={{ width: `${(data.summary.approved / data.summary.total_required) * 100}%` }} />
        </div>
      </div>

      <VehicleForm vehicle={data.active_vehicle} onSaved={() => { void load(); }} onNotice={onNotice} />

      <div className="glass-panel p-5 sm:p-6">
        <p className="flex items-center gap-2 text-sm font-semibold"><Paperclip className="size-4 text-primary" />Pièces obligatoires</p>
        <p className="mt-1 text-xs text-muted-foreground">Formats acceptés : JPEG, PNG, WebP ou PDF — 8 Mo maximum par fichier. Une nouvelle version ne remplace jamais l’ancienne : elle repart en attente d’examen.</p>
        {vehicleDocsBlocked && (
          <p className="mt-4 flex items-center gap-2 rounded-md border border-primary/30 bg-primary/10 px-3 py-2 text-xs text-primary" role="status">
            <AlertTriangle className="size-4 shrink-0" />Enregistrez d’abord votre véhicule pour pouvoir déposer la carte grise, l’assurance, la visite technique et les photos.
          </p>
        )}
        <div className="mt-4 space-y-3">
          {data.documents.map((doc) => (
            <DocumentRow key={doc.doc_type} doc={doc} userId={userId} vehicleId={data.active_vehicle?.id ?? null} onDone={() => { void load(); }} onNotice={onNotice} />
          ))}
        </div>
      </div>
    </section>
  );
}

function VehicleForm({ vehicle, onSaved, onNotice }: { vehicle: OnboardingVehicle | null; onSaved: () => void; onNotice: (m: string) => void }) {
  const [form, setForm] = useState({
    make: vehicle?.make ?? "",
    model: vehicle?.model ?? "",
    color: vehicle?.color ?? "",
    plate: vehicle?.plate ?? "",
    has_ac: vehicle?.has_ac ?? false,
    registered_seats: vehicle?.registered_seats ?? 5,
  });
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    setForm({
      make: vehicle?.make ?? "",
      model: vehicle?.model ?? "",
      color: vehicle?.color ?? "",
      plate: vehicle?.plate ?? "",
      has_ac: vehicle?.has_ac ?? false,
      registered_seats: vehicle?.registered_seats ?? 5,
    });
  }, [vehicle]);

  const capacity = Math.max(0, Number(form.registered_seats || 0) - 1);
  const statusChip = vehicle
    ? vehicle.validation_status === "approved"
      ? { label: "Véhicule validé", tone: "live" as const }
      : vehicle.validation_status === "rejected"
        ? { label: "Correction demandée", tone: "danger" as const }
        : { label: "En attente de validation", tone: "gold" as const }
    : { label: "Non enregistré", tone: "muted" as const };

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    const { error } = await supabase.rpc("upsert_my_vehicle", {
      ...(vehicle ? { _vehicle_id: vehicle.id } : {}),
      ...(form.make ? { _make: form.make } : {}),
      ...(form.color ? { _color: form.color } : {}),
      _model: form.model,
      _plate: form.plate,
      _has_ac: form.has_ac,
      _registered_seats: Number(form.registered_seats),
      _set_active: true,
    });
    setBusy(false);
    if (error) {
      if (error.message.includes("INVALID_REGISTERED_SEATS")) return onNotice("Le nombre de places homologuées doit être d’au moins 2.");
      if (error.message.includes("VEHICLE_MODEL_AND_PLATE_REQUIRED")) return onNotice("Le modèle et la plaque sont obligatoires.");
      return onNotice("Enregistrement du véhicule impossible.");
    }
    onNotice("Véhicule enregistré. Il sera vérifié par l’administration.");
    onSaved();
  }

  return (
    <form onSubmit={submit} className="glass-panel p-5 sm:p-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm font-semibold">Mon véhicule</p>
        <Chip tone={statusChip.tone}>{statusChip.label}</Chip>
      </div>
      <div className="mt-4 grid gap-4 sm:grid-cols-2">
        <label className="block"><span className="mb-2 block text-xs font-medium">Marque</span><Input value={form.make} onChange={(e) => setForm({ ...form, make: e.target.value })} placeholder="Toyota" maxLength={40} className="h-12" /></label>
        <label className="block"><span className="mb-2 block text-xs font-medium">Modèle</span><Input value={form.model} onChange={(e) => setForm({ ...form, model: e.target.value })} placeholder="Corolla" maxLength={60} className="h-12" required /></label>
        <label className="block"><span className="mb-2 block text-xs font-medium">Couleur</span><Input value={form.color} onChange={(e) => setForm({ ...form, color: e.target.value })} placeholder="Gris" maxLength={30} className="h-12" /></label>
        <label className="block"><span className="mb-2 block text-xs font-medium">Immatriculation</span><Input value={form.plate} onChange={(e) => setForm({ ...form, plate: e.target.value })} placeholder="AA-5790-AA" maxLength={15} className="h-12 uppercase" required /></label>
        <label className="block">
          <span className="mb-2 block text-xs font-medium">Places homologuées (carte grise)</span>
          <Input type="number" min={2} max={9} value={form.registered_seats} onChange={(e) => setForm({ ...form, registered_seats: Number(e.target.value) })} className="h-12 text-lg font-bold tabular-nums" />
        </label>
        <div className="rounded-md border border-primary/30 bg-primary/10 p-4">
          <p className="text-[10px] font-semibold uppercase text-primary">Capacité passagers</p>
          <p className="mt-1 text-2xl font-black tabular-nums text-primary">{capacity}</p>
          <p className="mt-1 text-[11px] text-muted-foreground">Calculée automatiquement : places homologuées moins le conducteur.</p>
        </div>
      </div>
      <label className="mt-4 flex items-center justify-between gap-4 rounded-md border border-border bg-secondary/60 p-4">
        <span className="text-sm">Climatisation fonctionnelle</span>
        <Switch checked={form.has_ac} onCheckedChange={(checked) => setForm({ ...form, has_ac: checked })} aria-label="Climatisation fonctionnelle" />
      </label>
      <p className="mt-3 text-[11px] text-muted-foreground">Modifier la plaque, la marque, le modèle ou le nombre de places replace le véhicule en attente de validation.</p>
      <Button type="submit" disabled={busy} className="mt-4 h-12 w-full font-bold shadow-gold">{busy ? <Loader2 className="animate-spin" /> : <Save />}Enregistrer mon véhicule</Button>
    </form>
  );
}

function DocumentRow({ doc, userId, vehicleId, onDone, onNotice }: { doc: OnboardingDoc; userId: string; vehicleId: string | null; onDone: () => void; onNotice: (m: string) => void }) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [expiry, setExpiry] = useState("");
  const [busy, setBusy] = useState(false);
  const chip = docStatusChip(doc.status);
  const needsVehicle = doc.scope === "vehicle" && !vehicleId;

  async function upload(file: File) {
    if (!ACCEPTED_MIME.includes(file.type)) return onNotice("Format refusé : utilisez une image JPEG, PNG, WebP ou un PDF.");
    if (file.size > MAX_BYTES) return onNotice("Fichier trop lourd : 8 Mo maximum.");
    if (doc.required_expiry && !expiry) return onNotice("Indiquez la date d’échéance avant de déposer cette pièce.");

    setBusy(true);
    const extension = file.name.split(".").pop()?.toLowerCase() ?? "bin";
    const path = `${userId}/${doc.doc_type}/${crypto.randomUUID()}.${extension}`;
    const { error: uploadError } = await supabase.storage.from("driver-documents").upload(path, file, { upsert: false, contentType: file.type });
    if (uploadError) {
      setBusy(false);
      return onNotice("Envoi du fichier impossible. Vérifiez votre connexion.");
    }
    const { error } = await supabase.rpc("register_my_document", {
      _doc_type: doc.doc_type,
      _storage_path: path,
      _mime_type: file.type,
      _size_bytes: file.size,
      ...(doc.scope === "vehicle" && vehicleId ? { _vehicle_id: vehicleId } : {}),
      ...(expiry ? { _expires_on: expiry } : {}),
    });
    setBusy(false);
    if (error) {
      if (error.message.includes("EXPIRY_DATE_REQUIRED")) return onNotice("Cette pièce exige une date d’échéance.");
      if (error.message.includes("VEHICLE_REQUIRED")) return onNotice("Enregistrez d’abord votre véhicule.");
      return onNotice("Pièce non enregistrée. Réessayez.");
    }
    setExpiry("");
    onNotice(`${DOC_LABELS[doc.doc_type] ?? "Pièce"} déposée. En attente d’examen.`);
    onDone();
  }

  return (
    <div className={cn("rounded-md border border-border bg-secondary/60 p-4", doc.status === "rejected" && "border-destructive/40", doc.status === "expired" && "border-destructive/40")}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm font-semibold">{DOC_LABELS[doc.doc_type] ?? doc.doc_type}</p>
        <Chip tone={chip.tone}>{chip.label}</Chip>
      </div>
      <p className="mt-1 text-[11px] text-muted-foreground">
        {doc.present ? `Version ${doc.version} déposée le ${frDate(doc.submitted_at)}` : "Aucune pièce déposée"}
        {doc.expires_on ? ` · Échéance ${frDate(doc.expires_on)}` : ""}
      </p>
      {doc.correction_reason && (
        <p className="mt-2 flex items-start gap-2 rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-xs text-destructive">
          <FileWarning className="mt-0.5 size-4 shrink-0" />Motif : {doc.correction_reason}
        </p>
      )}
      <div className="mt-3 flex flex-wrap items-end gap-3">
        {doc.required_expiry && (
          <label className="block">
            <span className="mb-1 block text-[10px] font-medium uppercase text-muted-foreground">Date d’échéance</span>
            <Input type="date" value={expiry} onChange={(e) => setExpiry(e.target.value)} className="h-10 w-44" />
          </label>
        )}
        <input ref={inputRef} type="file" accept=".jpg,.jpeg,.png,.webp,.pdf" className="sr-only" aria-label={`Déposer ${DOC_LABELS[doc.doc_type] ?? doc.doc_type}`}
          onChange={(e) => { const file = e.target.files?.[0]; e.target.value = ""; if (file) void upload(file); }} />
        <Button type="button" size="sm" variant={doc.present ? "outline" : "default"} disabled={busy || needsVehicle} onClick={() => inputRef.current?.click()} className="h-10">
          {busy ? <Loader2 className="animate-spin" /> : <Upload className="size-4" />}
          {doc.present ? "Déposer une nouvelle version" : "Déposer le document"}
        </Button>
      </div>
    </div>
  );
}

export const onboardingIcons = { CheckCircle2, Clock3, ShieldCheck, X };
