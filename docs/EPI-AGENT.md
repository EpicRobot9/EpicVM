# Epi, the EpicVM support agent

Epi is available inside the signed-in EpicVM portal, Settings, and Management. Her identity is fixed to **Epi** with **she/her** pronouns. She speaks with a warm personality, conversational opinions, and emotional reactions while operational answers stay concise. She does not volunteer AI disclaimers, and answers plainly if asked whether she is human.
When someone asks for affection, including "say I love you," she answers directly and briefly instead of turning it into a debate about AI feelings.

## Permission model

The model never supplies or chooses an identity. Every request is bound to the authenticated EpicVM or dashboard session.

- Standard users can list and inspect only assigned machines, start/stop/restart supported machines, run bounded recovery, and notify an administrator.
- Administrators can list and operate the complete fleet and use the administrator recovery mode.
- Epi has no shell, source-edit, mass-refactor, secret, deletion, or permission-bypass tool.
- Existing EpicVM host eligibility, resource ACLs, capabilities, CSRF, and authentication checks remain authoritative.

Epi runs `z-ai/glm-5.3-flash` through OpenRouter. The key remains server-side and is loaded from the protected runtime environment. `EPI_OPENROUTER_MODEL` can override the default.

## Escalation

When bounded troubleshooting cannot resolve an issue, Epi can create an `Epi escalation` ticket in the existing Management request queue. She may tell a user that an administrator was notified only after the database insert returns `notification_sent=true`.

## Rate limits

Chat and tool execution have separate sliding-window limits keyed by both authenticated owner and source IP:

- Standard chat: 12 requests/minute
- Administrator chat: 30 requests/minute
- Standard tools: 6 executions/5 minutes
- Administrator tools: 18 executions/5 minutes

The server returns HTTP 429 with a bounded retry time when a limit is reached.

## Memory privacy

Epi uses the reusable package in `memory_engine/`. Every message is evaluated by Jev with five independent questions:

1. Is this worth keeping?
2. Which exact words should be retained?
3. Where does it fit?
4. Which existing memory is now out of date?
5. What existing memory does it recall?

Candidate text is split deterministically from the original message. Jev selects a candidate ID, and code copies that exact span. Jev cannot generate or silently paraphrase stored memory.

The `where_fits` answer chooses either a root category or an existing owner-scoped memory, so memories grow into a tree instead of a flat tag list. A related old memory is recalled and its full parent path is supplied to Epi even when the current message is not saved. Recall events are counted independently. When a new memory supersedes an old one, the old row remains in the tree as `outdated`, is excluded from future recall candidates, and appears crossed out in the memory panel.

Every storage query requires both an application namespace and an owner key derived from the authenticated identity. A user-supplied owner ID is never accepted by the HTTP API. Memory, chat history, deletion, stale updates, and associations all use the same owner boundary. Users can inspect, forget, or clear their own memories in Epi's memory panel.

## Reusing the memory engine

The package has no EpicVM dependency:

```python
from memory_engine import JevMemoryEngine, MemoryStore

store = MemoryStore('/secure/path/memory.sqlite3', identity_secret='application-secret')
engine = JevMemoryEngine(store, api_key='server-side-typesafe-key')
decision = engine.process_message('your-app:v1', authenticated_user_id, user_message)
```

The embedding application must supply an authenticated owner ID, a unique namespace, a protected identity secret, and a server-side TypeSafe key. Never take the owner ID from request JSON.
