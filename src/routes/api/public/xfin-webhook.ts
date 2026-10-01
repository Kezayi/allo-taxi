import { createFileRoute } from "@tanstack/react-router";
import { parseWebhook, verifyXfinSignature, webhookSecret, type XfinWebhookPayload } from "@/lib/xfin.server";

// Webhook xFin : corps brut + X-XFIN-Signature (HMAC-SHA256). Absent/mal signé → 401, aucune écriture.
export const Route = createFileRoute("/api/public/xfin-webhook")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const raw = await request.text();
        if (raw.length > 64_000) return new Response("Payload too large", { status: 413 });
        if (!verifyXfinSignature(raw, request.headers.get("x-xfin-signature"), webhookSecret())) {
          return new Response("Invalid signature", { status: 401 });
        }
        let payload: XfinWebhookPayload;
        try { payload = JSON.parse(raw) as XfinWebhookPayload; } catch { return new Response("Bad JSON", { status: 400 }); }
        const resolution = parseWebhook(payload);
        if (!resolution) return new Response("Ignored", { status: 200 });
        const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
        const { data, error } = await supabaseAdmin.rpc("apply_xfin_transaction_update", resolution as never);
        if (error) {
          console.error("[xfin-webhook] apply failed", { code: error.code });
          return new Response("Retry later", { status: 500 });
        }
        return Response.json({ ok: true, result: (data as { result?: string } | null)?.result ?? null });
      },
    },
  },
});
