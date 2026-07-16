# Hermes Agent — OpenAI-Compatible API

**Base URL:** `https://api.operamind.one`
**API root:** `https://api.operamind.one/v1`
**Version:** `0.18.2` (probe `GET /health`)
**Auth:** `Authorization: Bearer <API_SERVER_KEY>` (all endpoints except `/health*`)

The Hermes Agent exposes an OpenAI-compatible HTTP API. Any OpenAI-compatible
frontend (Open WebUI, LobeChat, LibreChat, AnythingLLM, NextChat, ChatBox,
the OpenAI SDKs, …) can connect by pointing at the API root and authenticating
with the bearer key.

> ⚠️ **Not a raw LLM.** Every call is a **full agent turn** — Hermes runs its
> persona, toolsets (terminal, files, web, memory, skills), and executes tools
> **server-side** before answering. Expect several seconds of latency per call
> and a large system-prompt footprint; this is an autonomous agent, not a
> stateless completion model.

---

## Table of contents

- [Authentication](#authentication)
- [Special headers](#special-headers)
- [Errors](#errors)
- [Endpoint summary](#endpoint-summary)
- [Health & discovery](#health--discovery)
  - [GET /health](#get-health)
  - [GET /health/detailed](#get-healthdetailed)
  - [GET /v1/models](#get-v1models)
  - [GET /v1/capabilities](#get-v1capabilities)
  - [GET /v1/skills](#get-v1skills)
  - [GET /v1/toolsets](#get-v1toolsets)
- [Chat Completions](#chat-completions)
  - [POST /v1/chat/completions](#post-v1chatcompletions)
- [Responses API](#responses-api)
  - [POST /v1/responses](#post-v1responses)
  - [GET /v1/responses/{response_id}](#get-v1responsesresponse_id)
  - [DELETE /v1/responses/{response_id}](#delete-v1responsesresponse_id)
- [Async Runs (with tool-approval + SSE events)](#async-runs)
  - [POST /v1/runs](#post-v1runs)
  - [GET /v1/runs/{run_id}](#get-v1runsrun_id)
  - [GET /v1/runs/{run_id}/events](#get-v1runsrun_idevents)
  - [POST /v1/runs/{run_id}/approval](#post-v1runsrun_idapproval)
  - [POST /v1/runs/{run_id}/stop](#post-v1runsrun_idstop)
- [Session resources](#session-resources)
- [Cron Jobs](#cron-jobs)
- [Client examples](#client-examples)

---

## Authentication

All endpoints except the health probes require a bearer token:

```
Authorization: Bearer <API_SERVER_KEY>
```

The token is compared with `hmac.compare_digest` (constant-time). A missing or
wrong token returns `401`:

```json
{ "error": { "message": "Invalid API key", "type": "invalid_request_error", "code": "invalid_api_key" } }
```

`GET /health`, `GET /health/detailed`, and `GET /v1/health` are **unauthenticated**.

---

## Special headers

The agent adds stateful behavior on top of the stateless OpenAI schema via
request/response headers.

| Header | Direction | Purpose |
|---|---|---|
| `X-Hermes-Session-Id` | request → / ← response | Opt-in **conversation continuity**. Send an ID to continue a prior turn; the server echoes the effective ID on every response. Requires auth. |
| `X-Hermes-Session-Key` | request → / ← response | Opt-in **long-term memory scope** (stable per-channel identifier, e.g. `agent:main:webui:user-42`). Independent of session-id. Max 256 chars, no control chars. Requires auth (else `403`). |
| `X-Hermes-Completed` | ← response | `"false"` when the turn was cut short. |
| `X-Hermes-Partial` | ← response | `"true"` if the returned content is partial. |
| `X-Hermes-Error` | ← response | Redacted error string when a turn failed mid-flight. |
| `Idempotency-Key` | request → | Standard idempotency (accepted in CORS allow-list). |

CORS: `Authorization, Content-Type, Idempotency-Key` are allowed; origins are
configurable via `API_SERVER_CORS_ORIGINS` (disabled by default).

---

## Errors

Errors follow the OpenAI error envelope:

```json
{ "error": { "message": "…", "type": "invalid_request_error", "code": "…" } }
```

| Status | Meaning |
|---|---|
| `400` | Invalid JSON / missing required field / bad value |
| `401` | Missing or invalid bearer token |
| `403` | `X-Hermes-Session-Key` sent but no API key configured |
| `404` | Unknown `response_id` / `run_id` / `session_id` / `job_id` |
| `409` | Conflict (e.g. approval for a run not awaiting approval) |
| `429` | Concurrency limit reached (`max_concurrent_runs`) |
| `500` | Server-side agent/tooling error (message redacted) |

---

## Endpoint summary

| Method | Path | Auth | Description |
|---|---|:---:|---|
| GET | `/health` | ✗ | Liveness probe |
| GET | `/health/detailed` | ✗ | Rich runtime readiness |
| GET | `/v1/health` | ✗ | Alias of `/health` |
| GET | `/v1/models` | ✓ | List `hermes-agent` + model-route aliases |
| GET | `/v1/capabilities` | ✓ | Machine-readable feature/endpoint contract |
| GET | `/v1/skills` | ✓ | List installed skills |
| GET | `/v1/toolsets` | ✓ | List toolsets and resolved tool names |
| POST | `/v1/chat/completions` | ✓ | OpenAI Chat Completions (sync/stream) |
| POST | `/v1/responses` | ✓ | OpenAI Responses API (stateful) |
| GET | `/v1/responses/{id}` | ✓ | Retrieve a stored response |
| DELETE | `/v1/responses/{id}` | ✓ | Delete a stored response |
| POST | `/v1/runs` | ✓ | Start async run → `run_id` (202) |
| GET | `/v1/runs/{id}` | ✓ | Run status |
| GET | `/v1/runs/{id}/events` | ✓ | SSE lifecycle/tool/approval events |
| POST | `/v1/runs/{id}/approval` | ✓ | Resolve a pending tool approval |
| POST | `/v1/runs/{id}/stop` | ✓ | Interrupt a running agent |
| GET | `/api/sessions` | ✓ | List sessions |
| POST | `/api/sessions` | ✓ | Create empty session |
| GET | `/api/sessions/{id}` | ✓ | Read session |
| PATCH | `/api/sessions/{id}` | ✓ | Update session metadata |
| DELETE | `/api/sessions/{id}` | ✓ | Delete session |
| GET | `/api/sessions/{id}/messages` | ✓ | Session message history |
| POST | `/api/sessions/{id}/fork` | ✓ | Branch a session |
| POST | `/api/sessions/{id}/chat` | ✓ | Chat with a persisted session |
| POST | `/api/sessions/{id}/chat/stream` | ✓ | Streaming session chat |
| GET | `/api/jobs` | ✓* | List cron jobs |
| POST | `/api/jobs` | ✓* | Create a cron job |
| GET | `/api/jobs/{id}` | ✓* | Get a cron job |
| PATCH | `/api/jobs/{id}` | ✓* | Update a cron job |
| DELETE | `/api/jobs/{id}` | ✓* | Delete a cron job |
| POST | `/api/jobs/{id}/pause` | ✓* | Pause a cron job |
| POST | `/api/jobs/{id}/resume` | ✓* | Resume a cron job |
| POST | `/api/jobs/{id}/run` | ✓* | Run a cron job now |

`✓*` = jobs endpoints additionally require the cron subsystem to be enabled
server-side (otherwise they return an "unavailable" error).

---

## Health & discovery

### GET /health

Unauthenticated liveness probe.

```bash
curl https://api.operamind.one/health
```

```json
{ "status": "ok", "platform": "hermes-agent", "version": "0.18.2" }
```

### GET /health/detailed

Unauthenticated, richer readiness payload (runtime state) intended for
cross-container dashboard probing.

### GET /v1/models

Lists the base model plus any configured `model_routes` aliases.

```bash
curl https://api.operamind.one/v1/models \
  -H "Authorization: Bearer $API_SERVER_KEY"
```

```json
{
  "object": "list",
  "data": [
    { "id": "hermes-agent", "object": "model", "owned_by": "hermes", "root": "hermes-agent" }
  ]
}
```

> The canonical model name is **`hermes-agent`**. Use it as the `model` field on
> every chat/responses request unless you've configured route aliases.

### GET /v1/capabilities

Machine-readable contract so external UIs can discover features without scraping
docs. Abridged shape:

```json
{
  "object": "hermes.api_server.capabilities",
  "platform": "hermes-agent",
  "model": "hermes-agent",
  "auth": { "type": "bearer", "required": true },
  "runtime": {
    "mode": "server_agent",
    "tool_execution": "server",
    "split_runtime": false
  },
  "features": {
    "chat_completions": true,
    "chat_completions_streaming": true,
    "responses_api": true,
    "responses_streaming": true,
    "run_submission": true,
    "run_events_sse": true,
    "run_stop": true,
    "run_approval_response": true,
    "tool_progress_events": true,
    "approval_events": true,
    "session_resources": true,
    "session_chat": true,
    "session_fork": true,
    "skills_api": true,
    "admin_config_rw": false,
    "jobs_admin": false,
    "memory_write_api": false,
    "audio_api": false,
    "realtime_voice": false,
    "session_continuity_header": "X-Hermes-Session-Id",
    "session_key_header": "X-Hermes-Session-Key",
    "cors": false
  },
  "endpoints": { "...": "map of name → { method, path }" }
}
```

### GET /v1/skills

Read-only listing of installed skills (name, description, category) the agent
can load — no chat round-trip needed.

```json
{ "object": "list", "data": [ { "name": "...", "description": "...", "category": "..." } ] }
```

### GET /v1/toolsets

Lists each toolset with its enabled/configured state and the concrete tool names
it expands to.

```json
{
  "object": "list",
  "platform": "api_server",
  "data": [
    { "name": "...", "label": "...", "description": "...",
      "enabled": true, "configured": true, "tools": ["...", "..."] }
  ]
}
```

---

## Chat Completions

### POST /v1/chat/completions

OpenAI Chat Completions format. **Stateless** by default; opt into continuity
with `X-Hermes-Session-Id` and memory scope with `X-Hermes-Session-Key`.

**Request body**

| Field | Type | Notes |
|---|---|---|
| `model` | string | Use `hermes-agent` (or a configured alias). |
| `messages` | array | `{ role, content }`. `content` may be a string or an array of content parts. |
| `stream` | bool | `true` → SSE stream of `chat.completion.chunk`. String bool-ish values also accepted. |

```bash
curl https://api.operamind.one/v1/chat/completions \
  -H "Authorization: Bearer $API_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "hermes-agent",
    "messages": [{ "role": "user", "content": "Run the command: date" }]
  }'
```

**Response** (`chat.completion`)

```json
{
  "id": "chatcmpl-…",
  "object": "chat.completion",
  "created": 1752566432,
  "model": "hermes-agent",
  "choices": [
    { "index": 0,
      "message": { "role": "assistant", "content": "…agent's final answer…" },
      "finish_reason": "stop" }
  ],
  "usage": { "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0 }
}
```

Response headers include `X-Hermes-Session-Id` (and `X-Hermes-Session-Key` if
supplied) so you can continue the conversation on the next call.

**Streaming** (`"stream": true`) emits standard `data: {chat.completion.chunk}`
SSE frames terminated by `data: [DONE]`, with periodic keep-alive comments
(~30s).

---

## Responses API

Stateful OpenAI Responses API — conversation state is persisted server-side and
chained via `previous_response_id` (up to `MAX_STORED_RESPONSES = 100` kept).

### POST /v1/responses

**Request body**

| Field | Type | Notes |
|---|---|---|
| `model` | string | `hermes-agent`. |
| `input` | string \| array | The user turn (string, or messages array). |
| `instructions` | string | Optional per-request system prompt. |
| `previous_response_id` | string | Chain onto a stored response. Mutually exclusive with `conversation`. |
| `conversation` | string | Named conversation handle (server resolves last response id). |
| `conversation_history` | array | Explicit `{role, content}` history (**wins** over `previous_response_id`). |
| `stream` | bool | SSE streaming of Responses events. |
| `tools` | array | Optional tool declarations. |

```bash
curl https://api.operamind.one/v1/responses \
  -H "Authorization: Bearer $API_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -d '{ "model": "hermes-agent", "input": "Summarize disk usage of /var" }'
```

### GET /v1/responses/{response_id}

Retrieve a stored response by id. `404` if unknown/expired.

### DELETE /v1/responses/{response_id}

Delete a stored response.

---

## Async Runs

The runs API is the richest surface: submit work, get a `run_id` immediately,
then stream **lifecycle + tool-progress + approval** events over SSE and answer
host-side tool-approval prompts. Best for long-horizon / tool-heavy tasks and
for UIs that need human-in-the-loop control.

### POST /v1/runs

Starts a run and returns `202` with a `run_id` **immediately** (does not block
on completion).

**Request body**

| Field | Type | Notes |
|---|---|---|
| `input` | string \| array | **Required.** String, or a messages array (all but the last become history). |
| `instructions` | string | Optional ephemeral system prompt. |
| `previous_response_id` | string | Resume a stored response's history + instructions. |
| `conversation_history` | array | Explicit `{role, content}` list (wins over `previous_response_id`). |
| `session_id` | string | Conversation scope (defaults to the new `run_id`). |

```bash
curl https://api.operamind.one/v1/runs \
  -H "Authorization: Bearer $API_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -d '{ "input": "Check the nginx config and restart if valid" }'
```

```json
{ "run_id": "run_ab12…", "status": "queued" }
```

> Each run gets an **isolated approval queue** keyed by `run_id`. Resolving an
> approval on one run never unblocks a dangerous command on another run, even if
> they share a `session_id` or memory `session_key`.

### GET /v1/runs/{run_id}

Returns the current run status (e.g. `queued`, `running`, `awaiting_approval`,
`completed`, `error`, `stopped`).

### GET /v1/runs/{run_id}/events

**SSE** stream of structured lifecycle events. Event kinds include:

| Event | Meaning |
|---|---|
| `message.delta` | Incremental assistant text (`{ delta }`). |
| tool progress | Tool-call start / progress / result events. |
| approval request | The agent is blocked awaiting a tool approval. |
| run status | Transitions (`running`, `completed`, `error`, `stopped`). |

```bash
curl -N https://api.operamind.one/v1/runs/run_ab12…/events \
  -H "Authorization: Bearer $API_SERVER_KEY"
```

### POST /v1/runs/{run_id}/approval

Resolve a pending host-side tool-approval prompt.

**Request body**

| Field | Type | Notes |
|---|---|---|
| `choice` | string | One of `once`, `session`, `always`, `deny`. Aliases: `approve`/`approved`/`allow` → `once`. |
| `all` / `resolve_all` | bool | Resolve every pending approval for the run at once. |

`409` if the run is not awaiting approval.

### POST /v1/runs/{run_id}/stop

Interrupt a running agent turn.

---

## Session resources

A thin client/session resource API layered on Hermes' `SessionDB`. API-server
conversations show up alongside CLI/gateway ones (`hermes sessions list`).

| Method | Path | Body / Notes |
|---|---|---|
| GET | `/api/sessions` | List (supports pagination params). |
| POST | `/api/sessions` | Create an empty session row. |
| GET | `/api/sessions/{id}` | Read one session. |
| PATCH | `/api/sessions/{id}` | Update client-safe metadata (e.g. title). |
| DELETE | `/api/sessions/{id}` | Delete. |
| GET | `/api/sessions/{id}/messages` | Message history. |
| POST | `/api/sessions/{id}/fork` | Branch via SessionDB lineage → new session id. |
| POST | `/api/sessions/{id}/chat` | Chat within the persisted session. |
| POST | `/api/sessions/{id}/chat/stream` | Streaming variant (SSE). |

---

## Cron Jobs

Manage scheduled agent jobs. **Requires the cron subsystem to be enabled**
server-side; otherwise these return an "unavailable" error.

### POST /api/jobs

**Request body**

| Field | Type | Notes |
|---|---|---|
| `name` | string | **Required.** ≤ max name length. |
| `schedule` | string | **Required.** Cron expression. |
| `prompt` | string | Agent prompt (length-capped; content-scanned for safety). |
| `deliver` | string | Delivery target (default `"local"`). |
| `skills` | array | Optional skills to load for the job. |
| `repeat` | int | Optional positive repeat count. |

Other job endpoints: `GET/PATCH/DELETE /api/jobs/{id}`, and
`POST /api/jobs/{id}/{pause,resume,run}`.

---

## Client examples

### OpenAI Python SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://api.operamind.one/v1",
    api_key="<API_SERVER_KEY>",
)

resp = client.chat.completions.create(
    model="hermes-agent",
    messages=[{"role": "user", "content": "Run: uname -a"}],
)
print(resp.choices[0].message.content)
```

### Continue a conversation (session continuity)

```python
r1 = client.chat.completions.with_raw_response.create(
    model="hermes-agent",
    messages=[{"role": "user", "content": "Remember the number 42."}],
)
sid = r1.headers["X-Hermes-Session-Id"]

r2 = client.chat.completions.create(
    model="hermes-agent",
    messages=[{"role": "user", "content": "What number did I ask you to remember?"}],
    extra_headers={"X-Hermes-Session-Id": sid},
)
```

### As an A2A agent

Hermes is wrapped as an A2A agent in the CopilotKit mesh
(`examples/integrations/a2a-middleware/agents/hermes_agent.py`), which POSTs to
`{HERMES_URL}/chat/completions` with `model=hermes-agent` and a bearer key.

---

## Infrastructure notes

- **TLS:** Let's Encrypt (`letsencrypt-prod`, cert-manager) — secret
  `hermes-api-tls` in namespace `hermes`.
- **Ingress:** `ingress-nginx`, host `api.operamind.one`, upstream `hermes:8642`.
  `proxy-buffering off`, `proxy-read/-send-timeout 3600s` (long agent turns +
  SSE), `proxy-body-size 10m`.
- **Pod bind:** `API_SERVER_HOST=0.0.0.0`, `API_SERVER_PORT=8642`. The server
  auto-enables when `API_SERVER_KEY` is set.
- **NetworkPolicy:** only `ingress-nginx` may reach pod port `8642`.
- **Request cap:** `MAX_REQUEST_BYTES = 10 MB`.
- **Concurrency:** capped by `gateway.api_server.max_concurrent_runs` → `429`
  when exceeded.

See [`deploy/README.md`](./README.md) and [`deploy/CICD.md`](./CICD.md) for the
deployment/rollout details.
