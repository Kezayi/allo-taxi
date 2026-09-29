import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { ArrowLeft, LogIn, UserPlus } from "lucide-react";
import { useState, type FormEvent } from "react";
import { z } from "zod";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";

const searchSchema = z.object({ retour: z.enum(["/chauffeur", "/administration"]).optional() });

export const Route = createFileRoute("/connexion")({
  validateSearch: searchSchema,
  head: () => ({
    meta: [
      { title: "Connexion sécurisée — Allo Taxi..?" },
      { name: "description", content: "Connexion des chauffeurs, associés et administrateurs Allo Taxi..?" },
      { property: "og:title", content: "Connexion sécurisée — Allo Taxi..?" },
      { property: "og:description", content: "Accédez à votre espace chauffeur ou administration." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: LoginPage,
});

const credentials = z.object({
  email: z.string().trim().email("Adresse e-mail invalide.").max(255),
  password: z.string().min(8, "8 caractères minimum.").max(72),
});

function LoginPage() {
  const { retour } = Route.useSearch();
  const navigate = useNavigate();
  const [mode, setMode] = useState<"signin" | "signup">("signin");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent) {
    event.preventDefault();
    const parsed = credentials.safeParse({ email, password });
    if (!parsed.success) {
      setMessage(parsed.error.issues[0]?.message ?? "Champs invalides.");
      return;
    }
    setBusy(true);
    setMessage(null);
    const target = retour ?? "/chauffeur";
    if (mode === "signin") {
      const { error } = await supabase.auth.signInWithPassword(parsed.data);
      setBusy(false);
      if (error) return setMessage("Identifiants incorrects ou e-mail non confirmé.");
      navigate({ to: target });
    } else {
      const { error } = await supabase.auth.signUp({ ...parsed.data, options: { emailRedirectTo: `${window.location.origin}${target}` } });
      setBusy(false);
      if (error) return setMessage("Inscription impossible. Vérifiez vos informations.");
      setMessage("Compte créé. Confirmez votre adresse e-mail puis connectez-vous.");
      setMode("signin");
    }
  }

  return (
    <main className="relative grid min-h-svh place-items-center bg-background px-4 py-8 text-foreground">
      <div className="taxi-grid pointer-events-none absolute inset-0" />
      <section className="glass-panel relative w-full max-w-md p-6 sm:p-8">
        <Button asChild variant="ghost" size="icon" className="border border-border bg-secondary"><Link to="/" aria-label="Retour à l’accueil"><ArrowLeft /></Link></Button>
        <p className="mt-6 text-xs font-semibold uppercase text-primary">Accès sécurisé</p>
        <h1 className="mt-2 text-2xl font-semibold">{mode === "signin" ? "Connexion" : "Créer un compte"}</h1>
        <p className="mt-2 text-sm text-muted-foreground">Chauffeurs, associés et administrateurs.</p>
        <form onSubmit={submit} className="mt-6 space-y-4" noValidate>
          <label className="block"><span className="mb-2 block text-xs font-medium">E-mail</span><Input type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} className="h-12" /></label>
          <label className="block"><span className="mb-2 block text-xs font-medium">Mot de passe</span><Input type="password" autoComplete={mode === "signin" ? "current-password" : "new-password"} value={password} onChange={(e) => setPassword(e.target.value)} className="h-12" /></label>
          {message && <p className="text-xs text-primary" role="status">{message}</p>}
          <Button type="submit" disabled={busy} className="h-12 w-full font-bold shadow-gold">{mode === "signin" ? <><LogIn />Se connecter</> : <><UserPlus />Créer mon compte</>}</Button>
        </form>
        <Button type="button" variant="ghost" onClick={() => { setMode(mode === "signin" ? "signup" : "signin"); setMessage(null); }} className="mt-3 w-full text-xs text-muted-foreground">
          {mode === "signin" ? "Pas encore de compte ? S’inscrire" : "Déjà inscrit ? Se connecter"}
        </Button>
      </section>
    </main>
  );
}
