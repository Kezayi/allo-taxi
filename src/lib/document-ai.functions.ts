import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { analyzeDocumentWithAi, DocumentAiError, DOCUMENT_AI_MODEL, type DocumentAiContext } from "./document-ai.server";

type Claim = DocumentAiContext & { status: string; bucket?: string; path?: string; error_code?: string };

// Lance l'analyse IA d'une version précise. L'échec IA n'invalide jamais le dépôt :
// le document reste "submitted" et validable humainement.
export const analyzeDriverDocument = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((input: unknown) => z.object({ documentId: z.string().uuid() }).parse(input))
  .handler(async ({ data, context }) => {
    const { data: claimRaw, error } = await context.supabase.rpc("request_document_ai_analysis", { _document_id: data.documentId });
    if (error) return { status: "forbidden" as const };
    const claim = claimRaw as unknown as Claim;
    if (claim.status !== "claimed" || !claim.bucket || !claim.path) return { status: claim.status };

    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const fail = async (code: string) => {
      await supabaseAdmin.rpc("ai_fail_document_analysis", { _document_id: data.documentId, _error_code: code });
      return { status: "ai_unavailable" as const };
    };

    const apiKey = process.env["LOVABLE_API_KEY"];
    if (!apiKey) return fail("NO_API_KEY");

    const { data: blob, error: dlError } = await supabaseAdmin.storage.from(claim.bucket).download(claim.path);
    if (dlError || !blob) return fail("FILE_UNAVAILABLE");
    const mime = claim.mime_type ?? blob.type;
    if (!["image/jpeg", "image/png", "image/webp", "application/pdf"].includes(mime)) return fail("UNSUPPORTED_MIME");

    try {
      const result = await analyzeDocumentWithAi(claim, new Uint8Array(await blob.arrayBuffer()), mime, apiKey);
      const { data: outcome, error: saveError } = await supabaseAdmin.rpc("ai_complete_document_analysis", {
        _document_id: data.documentId,
        _model: DOCUMENT_AI_MODEL,
        _result: result as never,
      });
      if (saveError) { console.error("document-ai save", saveError.message); return fail("SAVE_FAILED"); }
      const o = outcome as unknown as { auto_approved: boolean };
      return { status: o.auto_approved ? ("auto_approved" as const) : ("manual_review" as const) };
    } catch (e) {
      const code = e instanceof DocumentAiError ? e.code : "UNEXPECTED";
      console.error("document-ai failure", code);
      return fail(code);
    }
  });
