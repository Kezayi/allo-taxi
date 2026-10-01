import { useState } from "react";
import { Check, Copy, Facebook, MessageCircle, Share2 } from "lucide-react";
import { Button } from "@/components/ui/button";

/**
 * Pied de page commun Client / Chauffeur.
 * Numéro WhatsApp Administrateur : celui enregistré sur le compte Superadmin (+241 074 69 80 31),
 * au format canonique du projet (+241 + 8 chiffres). Surchargeable via VITE_ADMIN_WHATSAPP_PHONE (non secret).
 */
const ADMIN_WHATSAPP = (import.meta.env.VITE_ADMIN_WHATSAPP_PHONE as string | undefined) ?? "+24174698031";
const PUBLIC_URL = "https://allo-taxi.lovable.app";
const SHARE_TEXT = "Allo Taxi..? — commandez un taxi à Libreville en un clic.";

export function CommonFooter() {
  const [fallback, setFallback] = useState(false);
  const [copied, setCopied] = useState(false);
  const wa = ADMIN_WHATSAPP.replace(/\D/g, "");
  const contactUrl = `https://wa.me/${wa}?text=${encodeURIComponent("Bonjour, je vous contacte depuis Allo Taxi..?")}`;

  async function share() {
    if (typeof navigator !== "undefined" && navigator.share) {
      try { await navigator.share({ title: "Allo Taxi..?", text: SHARE_TEXT, url: PUBLIC_URL }); return; }
      catch (e) { if ((e as Error).name === "AbortError") return; }
    }
    setFallback((v) => !v);
  }
  async function copy() {
    try { await navigator.clipboard.writeText(PUBLIC_URL); setCopied(true); window.setTimeout(() => setCopied(false), 2000); } catch { /* presse-papiers indisponible */ }
  }

  return (
    <footer className="relative mt-10 flex flex-col items-center gap-3 pb-4 text-center">
      <div className="flex flex-wrap items-center justify-center gap-2">
        <Button asChild variant="outline" size="sm" className="h-9 rounded-full border-border/60 bg-secondary/40 px-4 text-xs">
          <a href={contactUrl} target="_blank" rel="noreferrer"><MessageCircle />Contactez-nous</a>
        </Button>
        <Button type="button" variant="outline" size="sm" onClick={() => void share()} aria-expanded={fallback} className="h-9 rounded-full border-border/60 bg-secondary/40 px-4 text-xs">
          <Share2 />Partager
        </Button>
      </div>
      {fallback && (
        <div className="flex flex-wrap items-center justify-center gap-2">
          <Button asChild variant="ghost" size="sm" className="h-8 rounded-full text-[11px]">
            <a href={`https://wa.me/?text=${encodeURIComponent(`${SHARE_TEXT} ${PUBLIC_URL}`)}`} target="_blank" rel="noreferrer"><MessageCircle />WhatsApp</a>
          </Button>
          <Button asChild variant="ghost" size="sm" className="h-8 rounded-full text-[11px]">
            <a href={`https://www.facebook.com/sharer/sharer.php?u=${encodeURIComponent(PUBLIC_URL)}`} target="_blank" rel="noreferrer"><Facebook />Facebook</a>
          </Button>
          <Button type="button" variant="ghost" size="sm" onClick={() => void copy()} className="h-8 rounded-full text-[11px]">
            {copied ? <><Check />Lien copié</> : <><Copy />Copier le lien</>}
          </Button>
        </div>
      )}
      <p className="text-[10px] text-muted-foreground">(c) copyrigt MNAV34CM-AKD-LBV-GN</p>
    </footer>
  );
}
