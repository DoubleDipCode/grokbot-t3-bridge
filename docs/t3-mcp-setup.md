# Connecting T3 Code's MCP to Grok Bot

T3 Code exposes a remote MCP server over its relay. Grok Bot connects to it like any other connector, and from then on a bot can list your projects, launch threads, read them and reply to them.

## 1. Turn on remote access in T3 Code

The MCP is reached through T3 Connect, so remote access has to be on in T3 Code on the machine that runs your agents. If it is off, the connector cannot reach anything.

## 2. Add the connector in Grok Bot

Add T3's remote MCP as a connector in Grok Bot and sign in with OAuth when asked.

When you authorize, T3 asks which access level the connector should have. Pick it with care:

- If bots should launch **full-access** threads (recommended for bot work, see below), the connector needs full access.
- To change the level later, re-authorize the connector and pick a different one.

**One connector per coding bot.** If several bots write code for you, give each its own connector. Each bot then has its own authorization and access level, and you can revoke one without affecting the others.

## 3. Linked environments

T3 can link other machines as environments. A bot reaches them by passing an `environmentId` to the thread tools. Keep in mind:

- Linked environments are typically approval-required, and links expire.
- Bots cannot approve permission requests. When a thread on a linked environment asks for permission, you approve it in T3.
- A thread waiting on a permission prompt has not ended its turn, so the Stop hook does not fire. See [hooks.md](hooks.md).

## Tools bots use

These are the T3 MCP tools the setup in this repo relies on.

| Tool | What it is for |
| --- | --- |
| `t3_project_list` | Find the `projectId` for a repo. |
| `orchestrator_capabilities` | List the providers and models available, for `modelSelection`. |
| `t3_thread_launch` | Start a thread with a brief. |
| `t3_thread_read` | Read a thread. Use a small `limit` and `maxCharsPerItem` so the bot only reads the latest messages. |
| `t3_thread_send` | Reply in a thread, for example to answer a question the agent raised. |
| `t3_thread_wait` | Block until a thread changes. Fallback only; the hook replaces it. |
| `t3_thread_organize` | Settle or archive a thread once the work is merged. |
| `link_pull_request` / `watch_pull_request` | Attach a PR to a thread and follow it. |

### Launching a thread

A typical launch for bot work:

```json
{
  "title": "Add CSV export to reports",
  "message": "<the brief, ending with templates/brief-footer.md>",
  "projectId": "<from t3_project_list>",
  "runtimeMode": "full-access",
  "workspaceStrategy": { "type": "worktree", "baseRef": "main" },
  "modelSelection": {
    "provider": "<provider>",
    "instanceId": "<provider instance>",
    "model": "<model>"
  },
  "clientRequestId": "<a unique id the bot generates for this launch>"
}
```

Fields:

| Field | Notes |
| --- | --- |
| `title` | Required. Shown in T3's thread list. |
| `message` | The brief. End it with [templates/brief-footer.md](../templates/brief-footer.md). |
| `projectId` or `scratch` | Run in a project from `t3_project_list`, or use `scratch` for a throwaway thread with no project (handy for testing the hook). |
| `runtimeMode` | `approval-required`, `auto-accept-edits`, `auto` or `full-access`. Use `full-access` for bot work. |
| `interactionMode` | Optional. |
| `workspaceStrategy` | `type` is `root` (the project folder itself), `existing_worktree`, or `worktree` (a new worktree). Also takes `branch`, `baseRef` and related options. |
| `modelSelection` | `{provider, instanceId, model}`. Required when the project has no default model. `orchestrator_capabilities` lists what is available. |
| `clientRequestId` | Makes retries safe. If the launch call times out and the bot retries with the same id, T3 does not start a second thread. |

Why these choices:

- **`runtimeMode: "full-access"`** lets the agent run without stopping on permission prompts. A bot cannot answer those prompts, and a thread stuck on one never ends its turn, so it never calls back.
- **`workspaceStrategy` with `type: "worktree"`** gives each thread its own git worktree and branch, based on `baseRef`. The `.grokbot` marker lives in that worktree, which is how the hook knows which bot to call, and your own checkout is never touched.

### Reading a thread cheaply

When a bot is woken by the hook, it should read only what it needs: call `t3_thread_read` with a small `limit` (the last few messages) and a modest `maxCharsPerItem`. The payload already carries the status and, for Codex, the last assistant message, so often one short read is enough.
