import { createServerFn } from "@tanstack/react-start";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

export type XfinChecklist = {
  credentials: "manquants" | "configurés";
  appActive: "inconnu" | "oui" | "non";
  feeOwner: "inconnu" | "compatible" | "incompatible";
  webhookSecret: "manquant" | "configuré";
  error: string | null;
};

/** Checklist Superadmin non sensible. Aucun appel réseau tant que les credentials manquent. */
export const getXfinChecklist = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }): Promise<XfinChecklist> => {
    const { data: isAdmin } = await context.supabase.rpc("has_role", { _user_id: context.userId, _role: "super_admin" });
    if (!isAdmin) throw new Error("FORBIDDEN");
    const x = await import("./xfin.server");
    const p = x.xfinSecretsPresence();
    const out: XfinChecklist = {
      credentials: p.credentials ? "configurés" : "manquants",
      appActive: "inconnu",
      feeOwner: "inconnu",
      webhookSecret: p.webhookSecret ? "configuré" : "manquant",
      error: null,
    };
    if (!p.credentials) return out;
    try {
      const me = await x.getMe();
      out.appActive = (me.status ?? "").toLowerCase() === "active" ? "oui" : "non";
      out.feeOwner = (me.paymentFeeOwner ?? "").toUpperCase() === "CUSTOMER" ? "compatible" : "incompatible";
    } catch (e) {
      out.error = e instanceof x.XfinError ? e.code : "XFIN_UNREACHABLE";
    }
    return out;
  });
