import type { ExtensionAPI, ProviderModelConfig } from "@earendil-works/pi-coding-agent";

const OLLAMA_HOST = "http://10.0.3.1:11434";
/** Bound each catalog fetch; pi's startup refresh passes no timeout of its own. */
const FETCH_TIMEOUT_MS = 5_000;

export default function (pi: ExtensionAPI) {
  pi.registerProvider("ollama", {
    baseUrl: `${OLLAMA_HOST}/v1`,
    apiKey: "ollama",
    api: "openai-completions",
    async refreshModels({ signal, stored, publish }) {
      // Always hit the live catalog, even during offline/cache-only startup
      // refreshes: this provider has no static model list, and pi resolves the
      // initial model from the catalog before its post-TUI background refresh.
      try {
        const res = await fetch(`${OLLAMA_HOST}/api/tags`, {
          signal: AbortSignal.any([signal, AbortSignal.timeout(FETCH_TIMEOUT_MS)]),
        });
        if (!res.ok) throw new Error(`Ollama /api/tags returned ${res.status}`);
        const data = await res.json();
        const models: ProviderModelConfig[] = (data.models ?? []).map((m: any) => ({
          id: m.name,
          name: m.name,
          reasoning: (m.capabilities ?? []).includes("thinking"),
          input: (m.capabilities ?? []).includes("vision")
            ? ["text", "image"]
            : ["text"],
          contextWindow: m.details?.context_length ?? 128000,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        }));
        // Persist the catalog so future startups can fall back to it when the
        // Ollama server is unreachable (this is what models-store.json holds).
        await publish({ persist: { models, checkedAt: Date.now() } });
        return models;
      } catch (err) {
        // A superseded refresh must propagate its abort instead of falling back.
        if (signal.aborted) throw err;
        // Server unreachable or transient failure: serve the last known catalog
        // so startup model resolution doesn't come up empty (and warn "No models
        // available"). Only fails outright if we have never fetched a catalog.
        if (stored?.models?.length) return stored.models as ProviderModelConfig[];
        throw err;
      }
    },
  });
}