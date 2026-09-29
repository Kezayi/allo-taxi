import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

import { pinSchema, toCredentials } from "./phone-credentials";

/** Superadmin creates (or resets the PIN of) an associate account and links it to its partner sheet. */
export const provisionAssociateAccount = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d) => z.object({ partnerKey: z.enum(["xfin", "promoteur"]), phone: z.string(), pin: pinSchema, name: z.string().trim().min(2).max(100) }).parse(d))
  .handler(async ({ data, context }) => {
    const { data: isAdmin } = await context.supabase.rpc("has_role", { _user_id: context.userId, _role: "super_admin" });
    if (!isAdmin) throw new Error("Accès refusé");
    const creds = toCredentials(data.phone, data.pin);
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");

    let userId: string | undefined;
    const created = await supabaseAdmin.auth.admin.createUser({ email: creds.email, password: creds.password, email_confirm: true, user_metadata: { phone: creds.phone } });
    if (created.data.user) userId = created.data.user.id;
    else {
      const { data: list } = await supabaseAdmin.auth.admin.listUsers({ perPage: 1000 });
      const existing = list?.users.find((u) => u.email === creds.email);
      if (!existing) throw new Error("Création du compte impossible.");
      userId = existing.id;
      await supabaseAdmin.auth.admin.updateUserById(userId, { password: creds.password });
    }

    await supabaseAdmin.from("user_roles").upsert({ user_id: userId, role: "associe", is_active: true, deleted_at: null, updated_at: new Date().toISOString() }, { onConflict: "user_id,role" });
    const { data: profile } = await supabaseAdmin.from("profiles").select("id").eq("user_id", userId).maybeSingle();
    if (!profile) await supabaseAdmin.from("profiles").insert({ user_id: userId, phone: creds.phone, first_name: data.name });
    const { error } = await supabaseAdmin.from("associates_settings").update({ user_id: userId, phone: creds.phone, updated_at: new Date().toISOString() }).eq("partner_key", data.partnerKey);
    if (error) throw new Error("Fiche associé introuvable.");
    return { ok: true };
  });
