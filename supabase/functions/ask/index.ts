// Supabase Edge Function "ask": answers vaccinators' questions from the hub's documents.
// Needs one secret: ANTHROPIC_API_KEY (Supabase → Edge Functions → Secrets).
import Anthropic from "npm:@anthropic-ai/sdk";
import { betaTool } from "npm:@anthropic-ai/sdk/helpers/beta/json-schema";
import { createClient } from "jsr:@supabase/supabase-js@2";

const MODEL = "claude-opus-5-5";
const DAILY_LIMIT = 40; // questions per person per 24 hours
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const anthropic = new Anthropic(); // reads ANTHROPIC_API_KEY

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    // Act as the signed-in person so the database's security rules apply.
    const db = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await db.auth.getUser();
    if (!user) return reply({ error: "Your sign-in expired. Sign out and sign in again." }, 401);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const since = new Date(Date.now() - 24 * 3600e3).toISOString();
    const { count } = await admin.from("chat_log").select("id", { count: "exact", head: true })
      .eq("user_id", user.id).gte("created_at", since);
    if ((count ?? 0) >= DAILY_LIMIT) {
      return reply({ error: `You've asked ${DAILY_LIMIT} questions in the last 24 hours, which is the daily limit. Try again tomorrow.` });
    }

    const body = await req.json().catch(() => ({}));
    const history: Anthropic.Beta.BetaMessageParam[] = (Array.isArray(body.messages) ? body.messages : [])
      .filter((m: { role?: string; content?: unknown }) =>
        (m?.role === "user" || m?.role === "assistant") && typeof m.content === "string" && m.content.trim())
      .slice(-12)
      .map((m: { role: "user" | "assistant"; content: string }) => ({ role: m.role, content: m.content.slice(0, 6000) }));
    while (history.length && history[0].role !== "user") history.shift();
    if (!history.length || history[history.length - 1].role !== "user") return reply({ error: "Type a question first." }, 400);
    const scope = typeof body.scope === "string" && UUID.test(body.scope) ? body.scope : null;

    const { data: docs } = await db.from("resources").select("id,title,category,page_count")
      .eq("has_text", true).order("title");
    const catalog = (docs ?? []).map((r) =>
      `- resource_id: ${r.id} | "${r.title}" | ${r.category ?? "Uncategorized"}${r.page_count ? ` | ${r.page_count} pages` : ""}`,
    ).join("\n") || "(no readable documents yet)";
    const scoped = scope && (docs ?? []).find((r) => r.id === scope);

    const system = `You are the reference assistant inside a resource hub for vaccinators (immunization staff working in clinics and outreach sessions).
Answer only from the documents in this hub, which you reach with the tools search_documents and read_pages. Search before answering any factual question, and read the pages around a good hit when you need detail. If the first search is thin, try other phrasings, synonyms and abbreviations (AEFI, OPV, BCG, VVM, EPI).
Cite every fact with a marker of the form [[doc:RESOURCE_ID|pPAGE]] right after the sentence, for example [[doc:0b6c1e2a-1111-4c3d-9e8f-123456789abc|p4]]. Use only resource_ids and pages you saw in tool results.
If the documents don't cover the question, say so plainly and suggest checking with a supervisor. Never fill gaps from general knowledge for doses, schedules, intervals, temperatures or contraindications.
Write for a busy health worker: lead with the direct answer, then short steps or bullets, in plain language. Reply in the language the question was asked in. Don't describe your searching; write only the answer.
${scoped ? `The user has limited this conversation to "${scoped.title}" (resource_id ${scoped.id}). Search within it.\n` : ""}
Documents in the hub:
${catalog}`;

    const searchDocuments = betaTool({
      name: "search_documents",
      description: "Keyword search across the hub's documents. Returns up to 8 matching pages, each with resource_id, title, page number and a text snippet. Use specific terms.",
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string", description: "Keywords to search for" },
          resource_id: { type: "string", description: "Optional: search only this document" },
        },
        required: ["query"],
      } as const,
      run: async (input) => {
        const rid = typeof input.resource_id === "string" && UUID.test(input.resource_id) ? input.resource_id : scope;
        const { data, error } = await db.rpc("search_pages", { q: String(input.query ?? ""), rid, n: 8 });
        if (error) throw new Error("Search failed: " + error.message);
        return JSON.stringify(data?.length ? data : "No matching pages. Try other words.");
      },
    });

    const readPages = betaTool({
      name: "read_pages",
      description: "Read the full text of pages from_page to to_page (at most 5 pages) of one document. Returns each page's number and text.",
      inputSchema: {
        type: "object",
        properties: {
          resource_id: { type: "string" },
          from_page: { type: "integer" },
          to_page: { type: "integer" },
        },
        required: ["resource_id", "from_page"],
      } as const,
      run: async (input) => {
        const id = String(input.resource_id ?? "");
        if (!UUID.test(id)) throw new Error("Unknown resource_id.");
        const from = Math.max(1, Number(input.from_page) || 1);
        const to = Math.min(Math.max(from, Number(input.to_page) || from), from + 4);
        const { data, error } = await db.from("resource_pages").select("page,content")
          .eq("resource_id", id).gte("page", from).lte("page", to).order("page");
        if (error) throw new Error("Reading failed: " + error.message);
        if (!data?.length) return "No text on those pages.";
        return JSON.stringify(data.map((p) => ({ page: p.page, text: p.content.slice(0, 6000) })));
      },
    });

    await admin.from("chat_log").insert({ user_id: user.id });

    const final = await anthropic.beta.messages.toolRunner({
      model: MODEL,
      max_tokens: 16000,
      max_iterations: 8,
      output_config: { effort: "medium" },
      // If Claude declines a question, the API retries it on a fallback model.
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      system,
      tools: [searchDocuments, readPages],
      messages: history,
    });

    if (final.stop_reason === "refusal") {
      return reply({ text: "I can't answer that one. Try asking it a different way, or check with your supervisor." });
    }
    const text = final.content
      .filter((b): b is Anthropic.Beta.BetaTextBlock => b.type === "text")
      .map((b) => b.text).join("\n").trim();
    return reply({ text: text || "I couldn't find an answer in the documents. Try rephrasing, or check with your supervisor." });
  } catch (err) {
    if (err instanceof Anthropic.AuthenticationError) {
      return reply({ error: "The assistant isn't set up correctly (its API key was rejected). Tell the hub administrator." });
    }
    if (err instanceof Anthropic.RateLimitError) {
      return reply({ error: "The assistant is busy right now. Wait a minute and try again." });
    }
    if (err instanceof Anthropic.APIError) {
      console.error("Claude API error", err.status, err.message);
      return reply({ error: "The assistant had a problem answering. Try again in a moment." });
    }
    console.error(err);
    return reply({ error: "Something went wrong. Try again in a moment." }, 500);
  }
});
