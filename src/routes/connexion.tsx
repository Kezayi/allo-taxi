import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { ArrowLeft, Eye, EyeOff, LogIn, ShieldCheck } from "lucide-react";
import { useEffect, useState, type FormEvent } from "react";
import { z } from "zod";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { phoneSchema, pinSchema, signInWithPhonePin, signUpWithPhonePin } from "@/lib/phone-auth";

const searchSchema = z.object({ retour: z.enum(["/chauffeur", "/administration"]).optional() });

export const Route = createFileRoute("/connexion")({
  validateSearch: searchSchema,
  head: () => ({
    meta: [
      { title: "Connexion sécurisée — Allo Taxi..?" },
      { name: "description", content: "Connexion par numéro de téléphone +241 et code PIN à votre espace Allo Taxi..?." },
      { property: "og:title", content: "Connexion sécurisée — Allo Taxi..?" },
      { property: "og:description", content: "Accédez à votre espace avec votre numéro +241 et votre code PIN." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: LoginPage,
});

/**
 * Sign-in for every account. Account creation here is limited to the very first
 * Superadmin; associates are created by the Superadmin, drivers sign up from the home "Chauffeur" tab.
 */
function LoginPage() {
  const { retour } = Route.useSearch();
  const navigate = useNavigate();
  const [setupMode, setSetupMode] = useState(false);
  const [phone, setPhone] = useState("");
  const [pin, setPin] = useState("");
  const [pin2, setPin2] = useState("");
  const [show, setShow] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    void supabase.rpc("superadmin_exists").then(({ data }) => setSetupMode(data === false));
  }, []);

  async function submit(event: FormEvent) {
    event.preventDefault();
    const p = phoneSchema.safeParse(phone);
    const c = pinSchema.safeParse(pin);
    if (!p.success) return setMessage(p.error.issues[0]?.message ?? "Numéro invalide.");
    if (!c.success) return setMessage(c.error.issues[0]?.message ?? "PIN invalide.");
    if (setupMode && pin !== pin2) return setMessage("Les deux codes PIN ne correspondent pas.");
    setBusy(true);
    setMessage(null);
    try {
      if (setupMode) {
        await signUpWithPhonePin(phone, pin);
        await supabase.rpc("claim_first_superadmin");
        navigate({ to: "/administration" });
      } else {
        await signInWithPhonePin(phone, pin);
        navigate({ to: retour ?? "/administration" });
      }
    } catch (e) {
      setMessage(e instanceof Error ? e.message : "Erreur inattendue.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="relative grid min-h-svh place-items-center bg-background px-4 py-8 text-foreground">
      <div className="taxi-grid pointer-events-none absolute inset-0" />
      <section className="glass-panel relative w-full max-w-md p-6 sm:p-8">
        <Button asChild variant="ghost" size="icon" className="border border-border bg-secondary"><Link to="/" aria-label="Retour à l’accueil"><ArrowLeft /></Link></Button>
        <p className="mt-6 text-xs font-semibold uppercase text-primary">Accès sécurisé</p>
        <h1 className="mt-2 text-2xl font-semibold">{setupMode ? "Créer le compte Superadmin" : "Connexion"}</h1>
        <p className="mt-2 text-sm text-muted-foreground">
          {setupMode ? "Première mise en service : ce compte pilotera tout le Back-Office." : "Numéro de téléphone + code PIN."}
        </p>
        <form onSubmit={submit} className="mt-6 space-y-4" noValidate>
          <label className="block">
            <span className="mb-2 block text-xs font-medium">Numéro de téléphone</span>
            <div className="grid grid-cols-[auto_minmax(0,1fr)]">
              <span className="flex h-12 items-center rounded-l-md border border-r-0 border-input bg-secondary px-3 text-sm font-semibold">+241</span>
              <Input type="tel" inputMode="tel" autoComplete="tel" placeholder="074 57 54 94" value={phone} onChange={(e) => setPhone(e.target.value)} className="h-12 rounded-l-none" />
            </div>
          </label>
          <label className="block">
            <span className="mb-2 block text-xs font-medium">Code PIN (4 ou 6 chiffres)</span>
            <div className="relative">
              <Input type={show ? "text" : "password"} inputMode="numeric" maxLength={6} autoComplete={setupMode ? "new-password" : "current-password"} placeholder="••••" value={pin} onChange={(e) => setPin(e.target.value.replace(/\D/g, ""))} className="h-12 pr-12 tracking-[0.4em]" />
              <Button type="button" variant="ghost" size="icon" aria-label={show ? "Masquer le code" : "Afficher le code"} onClick={() => setShow((v) => !v)} className="absolute right-1.5 top-1.5 text-muted-foreground">{show ? <EyeOff /> : <Eye />}</Button>
            </div>
          </label>
          {setupMode && (
            <label className="block">
              <span className="mb-2 block text-xs font-medium">Confirmer le code PIN</span>
              <Input type={show ? "text" : "password"} inputMode="numeric" maxLength={6} autoComplete="new-password" placeholder="••••" value={pin2} onChange={(e) => setPin2(e.target.value.replace(/\D/g, ""))} className="h-12 tracking-[0.4em]" />
            </label>
          )}
          {message && <p className="text-xs text-primary" role="status">{message}</p>}
          <Button type="submit" disabled={busy} className="h-12 w-full font-bold shadow-gold">{setupMode ? <><ShieldCheck />Créer le compte Superadmin</> : <><LogIn />Se connecter</>}</Button>
        </form>
      </section>
    </main>
  );
}
