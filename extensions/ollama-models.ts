import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("ollama", {
    baseUrl: "http://10.0.3.1:11434/v1",
    apiKey: "ollama",
    api: "openai-completions",
    async refreshModels({ signal }) {
      const res = await fetch("http://10.0.3.1:11434/api/tags", { signal });
      if (!res.ok) throw new Error(`Ollama /api/tags returned ${res.status}`);
      const data = await res.json();
      return (data.models ?? []).map((m: any) => ({
        id: m.name,
        name: m.name,
        reasoning: (m.capabilities ?? []).includes("thinking"),
        input: (m.capabilities ?? []).includes("vision")
          ? ["text", "image"]
          : ["text"],
        contextWindow: m.details?.context_length ?? 128000,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      }));
    },
  });
}
