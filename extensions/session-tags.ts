// session-tags.ts — tag, list, and load pi sessions from inside pi.
//
// Commands:
//   /tag <tag...>      Add tags to the current session
//   /untag <tag...>    Remove tags from the current session
//   /tags              Show the current session's tags
//   /sessions [query]  List saved sessions ("#tag" filters by tag, rest matches text)
//   /load [query]      Switch to a saved session (picker when multiple match)
//
// Tools (LLM-callable during normal use):
//   session_list       Query the saved-session list
//   session_tag        Add/remove/list tags on the current session
//   session_load       Switch to a matching session (queues /load)
//
// Tags are stored in ~/.pi/agent/session-tags.json, keyed by session ID.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import type { AutocompleteItem } from "@earendil-works/pi-tui";
import { Box, Text } from "@earendil-works/pi-tui";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

// ---------- tag index storage ----------

const AGENT_DIR = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
const TAGS_FILE = join(AGENT_DIR, "session-tags.json");

interface TagEntry {
	path?: string;
	tags: string[];
}
interface TagIndex {
	sessions: Record<string, TagEntry>;
}

async function loadIndex(): Promise<TagIndex> {
	try {
		const parsed = JSON.parse(await readFile(TAGS_FILE, "utf8")) as Partial<TagIndex>;
		return { sessions: parsed.sessions ?? {} };
	} catch {
		return { sessions: {} };
	}
}

async function saveIndex(index: TagIndex): Promise<void> {
	await mkdir(dirname(TAGS_FILE), { recursive: true });
	const tmp = `${TAGS_FILE}.tmp`;
	await writeFile(tmp, `${JSON.stringify(index, null, 2)}\n`);
	await rename(tmp, TAGS_FILE);
}

// ---------- tag helpers ----------

function parseTags(input: string): string[] {
	return [
		...new Set(
			input
				.split(/[\s,]+/)
				.map((t) => t.replace(/^#/, "").trim().toLowerCase())
				.filter(Boolean),
		),
	];
}

function fmtTags(tags: string[]): string {
	return tags.map((t) => `#${t}`).join(" ");
}

/** Add or remove tags for a session; returns the session's resulting tag list. */
async function mutateTags(
	id: string,
	file: string | undefined,
	mode: "add" | "remove",
	tags: string[],
): Promise<string[]> {
	const index = await loadIndex();
	let result: string[];
	if (mode === "add") {
		if (!file) throw new Error("Cannot tag an ephemeral session (started with --no-session).");
		const entry = index.sessions[id] ?? { tags: [] };
		entry.tags = [...new Set([...entry.tags, ...tags])];
		entry.path = file;
		index.sessions[id] = entry;
		result = entry.tags;
	} else {
		const entry = index.sessions[id];
		result = entry ? entry.tags.filter((t) => !tags.includes(t)) : [];
		if (entry) {
			if (result.length) index.sessions[id] = { ...entry, tags: result };
			else delete index.sessions[id];
		}
	}
	await saveIndex(index);
	refreshTagCache(index);
	return result;
}

// In-memory cache for synchronous argument completion.
let tagCache: { tag: string; count: number }[] = [];

function refreshTagCache(index: TagIndex): void {
	const counts = new Map<string, number>();
	for (const entry of Object.values(index.sessions)) {
		for (const tag of entry.tags) counts.set(tag, (counts.get(tag) ?? 0) + 1);
	}
	tagCache = [...counts.entries()]
		.map(([tag, count]) => ({ tag, count }))
		.sort((a, b) => b.count - a.count || a.tag.localeCompare(b.tag));
}

function lastArgumentToken(args: string): string {
	const parts = args.split(/[\s,]+/);
	return parts[parts.length - 1] ?? "";
}

// The completion value replaces the ENTIRE argument text, so reconstruct it.
function rebuildArgs(args: string, replacement: string): string {
	return args.slice(0, args.lastIndexOf(lastArgumentToken(args))) + replacement;
}

function completeTags(prefix: string): AutocompleteItem[] | null {
	const raw = lastArgumentToken(prefix);
	const stem = raw.replace(/^#/, "").toLowerCase();
	const hash = raw.startsWith("#") ? "#" : "";
	const items: AutocompleteItem[] = tagCache
		.filter((t) => t.tag.startsWith(stem))
		.slice(0, 20)
		.map((t) => ({ value: rebuildArgs(prefix, `${hash}${t.tag}`), label: `#${t.tag} ×${t.count}` }));
	return items.length ? items : null;
}

function completeHashTags(prefix: string): AutocompleteItem[] | null {
	const token = lastArgumentToken(prefix);
	if (!token.startsWith("#")) return null;
	return completeTags(prefix);
}

// ---------- session listing ----------

type SessionInfo = Awaited<ReturnType<typeof SessionManager.listAll>>[number];

interface Row {
	info: SessionInfo;
	tags: string[];
}

async function buildRows(): Promise<Row[]> {
	const [index, sessions] = await Promise.all([loadIndex(), SessionManager.listAll()]);
	sessions.sort((a, b) => b.modified.getTime() - a.modified.getTime());
	return sessions.map((info) => ({ info, tags: index.sessions[info.id]?.tags ?? [] }));
}

function parseQuery(query: string): { tagTerms: string[]; textTerms: string[] } {
	const tagTerms: string[] = [];
	const textTerms: string[] = [];
	for (const raw of query.split(/\s+/)) {
		if (!raw) continue;
		if (raw.startsWith("#")) tagTerms.push(raw.slice(1).toLowerCase());
		else if (raw.toLowerCase().startsWith("tag:")) tagTerms.push(raw.slice(4).toLowerCase());
		else textTerms.push(raw.toLowerCase());
	}
	return { tagTerms, textTerms };
}

function filterRows(rows: Row[], query: string): Row[] {
	const { tagTerms, textTerms } = parseQuery(query);
	if (!tagTerms.length && !textTerms.length) return rows;
	return rows.filter((row) => {
		if (tagTerms.length && !tagTerms.every((t) => row.tags.includes(t))) return false;
		if (textTerms.length) {
			const header = [row.info.id, row.info.name ?? "", row.info.firstMessage ?? "", row.info.cwd, row.info.path]
				.join(" ")
				.toLowerCase();
			const content = (row.info.allMessagesText ?? "").toLowerCase();
			if (!textTerms.every((t) => header.includes(t) || content.includes(t))) return false;
		}
		return true;
	});
}

// ---------- formatting ----------

const pad2 = (n: number) => String(n).padStart(2, "0");

function fmtDate(d: Date): string {
	return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

function shortId(id: string): string {
	return id.slice(0, 8);
}

function oneLine(s: string, max: number): string {
	const t = s.replace(/\s+/g, " ").trim();
	return t.length > max ? `${t.slice(0, max - 1)}…` : t;
}

interface RowData {
	id: string;
	date: string;
	tags: string[];
	msgs: number;
	label: string;
	path: string;
	current: boolean;
}

function toRowData(row: Row, currentFile: string | undefined): RowData {
	const display = row.info.name?.trim() || row.info.firstMessage?.trim() || "(no messages)";
	return {
		id: shortId(row.info.id),
		date: fmtDate(row.info.modified),
		tags: row.tags,
		msgs: row.info.messageCount,
		label: oneLine(display, 80),
		path: row.info.path,
		current: currentFile === row.info.path,
	};
}

function formatRowsText(rows: RowData[]): string[] {
	const lines: string[] = [];
	for (const r of rows) {
		lines.push(
			`${r.current ? "▸" : " "} ${r.id}  ${r.date}  ${r.msgs} msgs${r.tags.length ? `  ${fmtTags(r.tags)}` : ""}`,
		);
		lines.push(`    ${r.label}`);
		lines.push(`    ${r.path}`);
	}
	return lines;
}

// ---------- extension ----------

export default function (pi: ExtensionAPI) {
	// Show this session's tags in the footer status area.
	pi.on("session_start", async (_event, ctx) => {
		try {
			const index = await loadIndex();
			refreshTagCache(index);
			const tags = index.sessions[ctx.sessionManager.getSessionId()]?.tags ?? [];
			ctx.ui.setStatus("session-tags", tags.length ? fmtTags(tags) : undefined);
		} catch {
			// Non-fatal; keep startup clean.
		}
	});

	// --- Commands ---

	pi.registerCommand("tag", {
		description: "Tag the current session (usage: /tag <tag1> [tag2 ...])",
		getArgumentCompletions: (prefix) => completeTags(prefix),
		handler: async (args, ctx) => {
			if (!args.trim()) {
				const index = await loadIndex();
				const tags = index.sessions[ctx.sessionManager.getSessionId()]?.tags ?? [];
				ctx.ui.notify(
					tags.length
						? `Current tags: ${fmtTags(tags)} — add more with /tag <tags...>`
						: "No tags yet — usage: /tag <tag1> [tag2 ...]",
					"info",
				);
				return;
			}
			try {
				const added = parseTags(args);
				const tags = await mutateTags(
					ctx.sessionManager.getSessionId(),
					ctx.sessionManager.getSessionFile(),
					"add",
					added,
				);
				ctx.ui.setStatus("session-tags", tags.length ? fmtTags(tags) : undefined);
				pi.appendEntry("session-tags", { tags });
				ctx.ui.notify(`Added ${fmtTags(added)}`, "info");
			} catch (error) {
				ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
			}
		},
	});

	pi.registerCommand("untag", {
		description: "Remove tags from the current session (usage: /untag <tag1> [tag2 ...])",
		getArgumentCompletions: (prefix) => completeTags(prefix),
		handler: async (args, ctx) => {
			if (!args.trim()) {
				ctx.ui.notify("Usage: /untag <tag1> [tag2 ...]", "info");
				return;
			}
			try {
				const removed = parseTags(args);
				const tags = await mutateTags(
					ctx.sessionManager.getSessionId(),
					ctx.sessionManager.getSessionFile(),
					"remove",
					removed,
				);
				ctx.ui.setStatus("session-tags", tags.length ? fmtTags(tags) : undefined);
				pi.appendEntry("session-tags", { tags });
				ctx.ui.notify(`Removed ${fmtTags(removed)}`, "info");
			} catch (error) {
				ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
			}
		},
	});

	pi.registerCommand("tags", {
		description: "Show the current session's tags",
		handler: async (_args, ctx) => {
			const index = await loadIndex();
			const tags = index.sessions[ctx.sessionManager.getSessionId()]?.tags ?? [];
			pi.appendEntry("session-tags", { tags });
			ctx.ui.notify(
				tags.length ? `Current tags: ${fmtTags(tags)}` : "No tags yet — usage: /tag <tag1> [tag2 ...]",
				"info",
			);
		},
	});

	pi.registerCommand("sessions", {
		description: "List saved sessions (filter with #tag or text)",
		getArgumentCompletions: (prefix) => completeHashTags(prefix),
		handler: async (args, ctx) => {
			const rows = filterRows(await buildRows(), args);
			if (!rows.length) {
				ctx.ui.notify(args.trim() ? `No sessions match: ${args}` : "No saved sessions found.", "info");
				return;
			}
			const currentFile = ctx.sessionManager.getSessionFile();
			pi.appendEntry("session-list", {
				title: `Sessions — ${rows.length} shown${args.trim() ? ` (filter: ${args.trim()})` : ""}`,
				rows: rows.map((r) => toRowData(r, currentFile)),
			});
		},
	});

	pi.registerCommand("load", {
		description: "Switch to a saved session (filter with #tag or text; single match loads directly)",
		getArgumentCompletions: (prefix) => completeHashTags(prefix),
		handler: async (args, ctx) => {
			const currentFile = ctx.sessionManager.getSessionFile();
			const all = await buildRows();
			const rows = filterRows(all, args).filter((r) => r.info.path !== currentFile);
			if (!rows.length) {
				ctx.ui.notify(
					all.length ? `No other sessions match: ${args}` : "No saved sessions found.",
					"info",
				);
				return;
			}

			let target: Row;
			if (rows.length === 1) {
				target = rows[0];
			} else {
				if (!ctx.hasUI) {
					const d = toRowData(rows[0], currentFile);
					ctx.ui.notify(`Multiple matches; closest: ${d.id} — run: pi --session ${d.id}`, "info");
					return;
				}
				const labels = rows.map((r) => {
					const d = toRowData(r, currentFile);
					return `${d.id}  ${d.date}  ${d.tags.length ? fmtTags(d.tags) : "-"}  ${d.label}`;
				});
				const picked = await ctx.ui.select("Load session:", labels);
				if (!picked) return;
				const idx = labels.indexOf(picked);
				if (idx < 0) return;
				target = rows[idx];
			}

			const d = toRowData(target, currentFile);
			const result = await ctx.switchSession(target.info.path, {
				withSession: async (newCtx) => {
					newCtx.ui.notify(
						`Loaded session ${d.id}${d.tags.length ? ` ${fmtTags(d.tags)}` : ""}`,
						"info",
					);
				},
			});
			if (result.cancelled) {
				ctx.ui.notify("Session switch cancelled.", "warning");
			}
		},
	});

	// --- TUI-only entry renderers (not sent to the LLM) ---

	pi.registerEntryRenderer<{ tags: string[] }>("session-tags", (entry, _options, theme) => {
		const tags = entry.data?.tags ?? [];
		const text = tags.length ? `Tags: ${fmtTags(tags)}` : "Tags: (none)";
		const box = new Box(1, 1, (t) => theme.bg("customMessageBg", t));
		box.addChild(new Text(theme.fg("accent", text), 0, 0));
		return box;
	});

	pi.registerEntryRenderer<{ title: string; rows: RowData[] }>("session-list", (entry, _options, theme) => {
		const data = entry.data ?? { title: "Sessions", rows: [] as RowData[] };
		const lines: string[] = [theme.fg("accent", theme.bold(data.title))];
		const maxRows = 25;
		const shown = data.rows.slice(0, maxRows);
		for (const r of shown) {
			const marker = r.current ? theme.fg("accent", "▸ ") : "  ";
			const head = `${marker}${r.id}  ${theme.fg("dim", r.date)}  ${theme.fg("dim", `${r.msgs} msgs`)}`;
			lines.push(r.tags.length ? `${head}  ${theme.fg("accent", fmtTags(r.tags))}` : head);
			lines.push(`    ${r.label}`);
			lines.push(`    ${theme.fg("dim", r.path)}`);
		}
		if (data.rows.length > shown.length) {
			lines.push(theme.fg("dim", `… ${data.rows.length - shown.length} more — narrow with e.g. /sessions #tag`));
		}
		return new Text(lines.join("\n"), 0, 0);
	});

	// --- Tools (LLM-callable) ---

	pi.registerTool({
		name: "session_list",
		label: "List Sessions",
		description:
			"List the user's saved pi sessions (past conversations) with short IDs, dates, tags, and file paths. " +
			"Query filters: terms starting with '#' match session tags; other terms match session names, first messages, and content. " +
			"Most recently modified sessions come first.",
		promptSnippet: "List saved sessions with tags, dates, and paths (filter with #tag or text query)",
		promptGuidelines: [
			"Use session_list when the user asks about past sessions, wants to find a previous conversation by topic or tag, or needs a session ID/path before switching.",
		],
		parameters: Type.Object({
			query: Type.Optional(
				Type.String({ description: "Optional filter: '#tag' terms match tags; plain words match name/content" }),
			),
			limit: Type.Optional(Type.Integer({ description: "Max sessions to return (1-50, default 20)", minimum: 1, maximum: 50 })),
		}),
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const all = filterRows(await buildRows(), params.query ?? "");
			const limit = Math.min(params.limit ?? 20, 50);
			const shown = all.slice(0, limit).map((r) => toRowData(r, ctx.sessionManager.getSessionFile()));
			const lines = [`Saved sessions: showing ${shown.length} of ${all.length}`];
			lines.push(...formatRowsText(shown));
			if (all.length > shown.length) {
				lines.push(`… ${all.length - shown.length} more — refine the query to narrow down`);
			}
			lines.push("To switch to one of these sessions, call session_load with its short ID (or a '#tag'/text query).");
			return { content: [{ type: "text", text: lines.join("\n") }], details: { total: all.length, shown: shown.length } };
		},
	});

	pi.registerTool({
		name: "session_tag",
		label: "Tag Session",
		description:
			"Add tags to, remove tags from, or list the tags of the CURRENT session. " +
			"Tags are persistent labels (e.g. 'research', 'bugfix') shown in session listings and the /load picker.",
		promptGuidelines: [
			"Use session_tag when the user asks to tag/label the current session or change its tags.",
		],
		parameters: Type.Object({
			action: StringEnum(["add", "remove", "list"] as const),
			tags: Type.Optional(
				Type.Array(Type.String(), { description: "Tag(s) to add or remove (required for add/remove; lowercase, no spaces)" }),
			),
		}),
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const id = ctx.sessionManager.getSessionId();
			if (params.action === "list" || !params.tags?.length) {
				const index = await loadIndex();
				const tags = index.sessions[id]?.tags ?? [];
				return {
					content: [{ type: "text", text: tags.length ? `Current tags: ${fmtTags(tags)}` : "This session has no tags." }],
					details: { tags },
				};
			}
			try {
				const clean = parseTags(params.tags.join(" "));
				if (!clean.length) throw new Error("No valid tags provided.");
				const tags = await mutateTags(
					id,
					ctx.sessionManager.getSessionFile(),
					params.action,
					clean,
				);
				ctx.ui.setStatus("session-tags", tags.length ? fmtTags(tags) : undefined);
				const verb = params.action === "add" ? "Added" : "Removed";
				return {
					content: [{ type: "text", text: `${verb} ${fmtTags(clean)}. Current tags: ${tags.length ? fmtTags(tags) : "(none)"}` }],
					details: { tags },
				};
			} catch (error) {
				throw new Error(error instanceof Error ? error.message : String(error));
			}
		},
	});

	pi.registerTool({
		name: "session_load",
		label: "Load Session",
		description:
			"Switch the conversation to a saved pi session. Provide a query: a short session ID from session_list, a '#tag', or search text. " +
			"If exactly one session matches, it is loaded right after the current turn finishes; if several match, the user picks from a picker. " +
			"The current session is excluded from matching.",
		promptGuidelines: [
			"Use session_load when the user explicitly asks to load, open, or switch to a previous session. If the request is ambiguous, list candidates with session_list and confirm first.",
		],
		parameters: Type.Object({
			query: Type.String({ description: "Short session ID, '#tag', or search text" }),
		}),
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const currentFile = ctx.sessionManager.getSessionFile();
			const matches = filterRows(await buildRows(), params.query).filter((r) => r.info.path !== currentFile);
			if (!matches.length) {
				return {
					content: [{ type: "text", text: `No saved sessions match "${params.query}". Offer the user /sessions to browse.` }],
					details: { matches: 0 },
				};
			}
			if (!ctx.hasUI) {
				const d = toRowData(matches[0], currentFile);
				return {
					content: [
						{
							type: "text",
							text: `Closest match: ${d.id} — ${d.label}\nPath: ${matches[0].info.path}\nInteractive session switching is unavailable in this mode; the user can run: pi --session ${d.id}`,
						},
					],
					details: { matches: matches.length, path: matches[0].info.path },
				};
			}
			const loadArg = matches.length === 1 ? shortId(matches[0].info.id) : params.query;
			pi.sendUserMessage(`/load ${loadArg}`, { deliverAs: "followUp", expandPromptTemplates: true });
			const d = toRowData(matches[0], currentFile);
			const what =
				matches.length === 1
					? `Queued switch to session ${d.id} (${d.label}). It will load after this turn finishes.`
					: `${matches.length} sessions match "${params.query}"; a picker will appear after this turn so the user can choose.`;
			return { content: [{ type: "text", text: what }], details: { matches: matches.length } };
		},
	});
}