#!/usr/bin/env bash
# Token-free live omp guard: the real task tool rebinds the tracked extensions
# to a same-process child. A local deterministic provider exercises dispatch,
# child disposal, and a subsequent primary wake without network/model access.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_OMP_SUBAGENT_LIVE omp node
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-subagent.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/.omp/extensions" "$LAB/.pi/extensions/lib" "$LAB/bin" "$LAB/state" "$LAB/profile"
cp "$ROOT/.omp/extensions/"*.ts "$LAB/.omp/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$LAB/.pi/extensions/lib/"
cp "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-supervision-engine-lib.sh" "$LAB/bin/"
cat > "$LAB/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'digest\n' >> "$FM_HOME/digests"
printf 'LIVE_PRIMARY_DIGEST\n'
SH
cat > "$LAB/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf '%s\n' "$$" >> "$FM_HOME/arms"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
while [ ! -f "$FM_HOME/fire" ]; do sleep 0.1; done
rm "$FM_HOME/fire"
printf 'signal: LIVE_PRIMARY_WAKE\n'
SH
cat > "$LAB/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$LAB/bin/"*.sh
cat > "$LAB/.omp/config.yml" <<'YAML'
modelRoles:
  default: fm-local/deterministic
  smol: fm-local/deterministic
  slow: fm-local/deterministic
  tiny: fm-local/deterministic
  task: fm-local/deterministic
async:
  enabled: false
prewalk:
  enabled: false
plan:
  defaultOnStartup: false
advisor:
  enabled: false
memory:
  enabled: false
lsp:
  enabled: false
task:
  agentIdleTtlMs: 100
  agentModelOverrides:
    scout: fm-local/deterministic
YAML
cat > "$LAB/.omp/extensions/z-live-probe.ts" <<'TS'
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { AssistantMessageEventStream } from "@oh-my-pi/pi-ai";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
const home = process.env.FM_HOME!;
const log = (row: unknown) => appendFileSync(`${home}/events.jsonl`, `${JSON.stringify(row)}\n`);
let dispatched = false;
let fired = false;
const delay = () => new Promise(resolve => setTimeout(resolve, 50));
async function until(check: () => boolean, label: string) {
  for (let i = 0; i < 400; i++) { if (check()) return; await delay(); }
  throw new Error(`live omp timeout: ${label}`);
}
function toolNames(pi: ExtensionAPI): string[] {
  const listed = pi.getAllTools?.() ?? [];
  return listed.map(tool => {
    if (typeof tool === "string") return tool;
    const named = tool as { name?: unknown };
    return typeof named.name === "string" ? named.name : "";
  });
}
function isChild(context: { messages?: { role?: string; content?: unknown }[] }): boolean {
  const text = JSON.stringify(context.messages ?? []);
  return text.includes("LIVE_CHILD_TASK") && !text.includes("LIVE_PARENT_TASK");
}
function installProvider(pi: ExtensionAPI) {
  pi.registerProvider("fm-local", {
    baseUrl: "https://fm-local.invalid/", apiKey: "offline-test-only", api: "fm-local-api",
    models: [{ id: "deterministic", name: "Local deterministic provider", reasoning: false,
      input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 131072, maxTokens: 1024 }],
    streamSimple(model, context) {
      const stream = new AssistantMessageEventStream();
      void (async () => {
        const child = isChild(context);
        log({ event: "provider", child, messages: context.messages });
        const output = {
          role: "assistant" as const, content: [] as ({ type: "text"; text: string } | { type: "toolCall"; id: string; name: string; arguments: Record<string, unknown> })[],
          api: model.api, provider: model.provider, model: model.id,
          usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
          stopReason: "stop" as "stop" | "toolUse", timestamp: Date.now(),
        };
        if (!dispatched && !child) {
          dispatched = true;
          output.stopReason = "toolUse";
          output.content.push({ type: "toolCall", id: "spawn-child", name: "task", arguments: {
            context: "Local regression only.", tasks: [{ name: "LiveProbe", agent: "scout", task: "LIVE_CHILD_TASK", solutionSpace: "Return a constant." }],
          }});
        } else if (child) {
          output.content.push({ type: "text", text: "LIVE_CHILD_DONE" });
        } else if (!fired) {
          await until(() => readFileSync(`${home}/events.jsonl`, "utf8").includes('"event":"shutdown","kind":"sub"'), "child disposal");
          fired = true;
          writeFileSync(`${home}/fire`, "");
          await until(() => readFileSync(`${home}/arms`, "utf8").trim().split("\n").length === 2, "successor after child disposal");
          await new Promise(resolve => setTimeout(resolve, 300));
          output.content.push({ type: "text", text: "LIVE_MAIN_DONE" });
        } else {
          output.content.push({ type: "text", text: "LIVE_WAKE_CONSUMED" });
        }
        stream.push({ type: "start", partial: output });
        const block = output.content[0];
        if (block?.type === "toolCall") {
          stream.push({ type: "toolcall_start", contentIndex: 0, partial: output });
          stream.push({ type: "toolcall_delta", contentIndex: 0, delta: JSON.stringify(block.arguments), partial: output });
          stream.push({ type: "toolcall_end", contentIndex: 0, toolCall: block, partial: output });
        } else if (block?.type === "text") {
          stream.push({ type: "text_start", contentIndex: 0, partial: output });
          stream.push({ type: "text_delta", contentIndex: 0, delta: block.text, partial: output });
          stream.push({ type: "text_end", contentIndex: 0, content: block.text, partial: output });
        }
        stream.push({ type: "done", reason: output.stopReason, message: output });
        stream.end();
      })().catch(error => { log({ event: "failure", message: String(error) }); stream.end(); });
      return stream;
    },
  });
}
export default function(pi: ExtensionAPI) {
  installProvider(pi);
  pi.on("session_start", (_event, ctx) => {
    log({ event: "start", kind: ctx.agent.kind, depth: ctx.agent.depth, tools: toolNames(pi) });
  });
  pi.on("before_agent_start", (event, ctx) => {
    log({ event: "prompt", kind: ctx.agent.kind, prompt: event.prompt, tools: toolNames(pi) });
  });
  pi.on("session_shutdown", (_event, ctx) => { log({ event: "shutdown", kind: ctx.agent.kind }); });
  // The lab lock belongs to this process before either primary session_start.
  // No Firstmate production startup or fleet command runs in this fixture.
  if (!existsSync(`${home}/state/.lock`)) writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
}
TS
dump_live() {
  printf '# stderr:\n' >&2
  cat "$LAB/stderr" >&2 || true
  printf '# output:\n' >&2
  cat "$LAB/output" >&2 || true
  printf '# events:\n' >&2
  cat "$LAB/events.jsonl" >&2 || true
}
VERSION=$(omp --version)
mkdir -p "$LAB/sessions"
if ! env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
  FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" PI_CODING_AGENT_DIR="$LAB/profile" OMP_SKIP_SETUP=1 \
  omp --cwd "$LAB" --no-session --no-extensions --no-skills --no-rules --no-title --no-lsp \
    --session-dir "$LAB/sessions" --auto-approve --mode json \
    --model fm-local/deterministic --thinking off \
    -e "$LAB/.omp/extensions/fm-primary-omp-watch.ts" \
    -e "$LAB/.omp/extensions/fm-primary-turnend-guard.ts" \
    -e "$LAB/.omp/extensions/z-live-probe.ts" \
    -p 'LIVE_PARENT_TASK' > "$LAB/output" 2> "$LAB/stderr"; then
  dump_live
  fail "$VERSION: live subagent scenario failed"
fi
if ! node --input-type=module - "$LAB" <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const home = process.argv[2];
const rows = readFileSync(`${home}/events.jsonl`, "utf8").trim().split("\n").map(JSON.parse);
assert(!rows.some(r => r.event === "failure"), JSON.stringify(rows.filter(r => r.event === "failure")));
const prompts = rows.filter(r => r.event === "prompt");
assert(prompts.some(r => r.kind === "main" && r.tools.includes("fm_watch_arm_omp")), "primary must see the arm tool");
assert(prompts.some(r => r.kind === "sub"), "real task child must have started");
assert(prompts.filter(r => r.kind === "sub").every(r => !r.tools.includes("fm_watch_arm_omp")), "child received the arm tool");
assert(rows.some(r => r.event === "shutdown" && r.kind === "sub"), "child must be disposed before wake");
const calls = rows.filter(r => r.event === "provider");
assert(calls.some(r => !r.child && JSON.stringify(r.messages).includes("LIVE_PRIMARY_DIGEST")));
assert(calls.some(r => !r.child && JSON.stringify(r.messages).includes("signal: LIVE_PRIMARY_WAKE")));
assert(calls.filter(r => r.child).every(r => !JSON.stringify(r.messages).includes("FIRSTMATE_OP:")), "child received supervision context");
assert.equal(readFileSync(`${home}/digests`, "utf8"), "digest\n");
assert.equal(readFileSync(`${home}/arms`, "utf8").trim().split("\n").length, 2);
JS
then
  dump_live
  fail "$VERSION: subagent supervision isolation failed"
fi
pass "$VERSION: real task child has no supervision tool/digest/wake; primary receives a successor wake after child disposal"
