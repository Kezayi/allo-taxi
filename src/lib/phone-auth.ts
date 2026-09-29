import { supabase } from "@/integrations/supabase/client";

import { toCredentials } from "./phone-credentials";

export { phoneSchema, pinSchema } from "./phone-credentials";

export async function signInWithPhonePin(phone: string, pin: string) {
  const { email, password } = toCredentials(phone, pin);
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw new Error("Numéro ou code PIN incorrect.");
}

export async function signUpWithPhonePin(phone: string, pin: string, firstName?: string) {
  const creds = toCredentials(phone, pin);
  const { data, error } = await supabase.auth.signUp({ email: creds.email, password: creds.password, options: { data: { phone: creds.phone } } });
  if (error) throw new Error(error.message.includes("registered") ? "Ce numéro possède déjà un compte." : "Création du compte impossible.");
  if (!data.session) await signInWithPhonePin(phone, pin);
  const uid = data.user?.id;
  if (uid) await supabase.from("profiles").insert({ user_id: uid, phone: creds.phone, first_name: firstName ?? null });
}
