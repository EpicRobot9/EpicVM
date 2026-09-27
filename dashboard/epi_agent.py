"""Epi: a permission-aware EpicVM support agent with isolated Jev memory."""
from __future__ import annotations

from collections import defaultdict, deque
import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid

from flask import g, jsonify, request

try:
    from memory_engine import JevMemoryEngine, MemoryStore, MemoryUnavailable
except ImportError:
    import sys
    for candidate in ('/opt/blobe-vm', os.path.dirname(os.path.dirname(__file__))):
        if candidate not in sys.path:
            sys.path.insert(0, candidate)
    from memory_engine import JevMemoryEngine, MemoryStore, MemoryUnavailable


MODEL = 'z-ai/glm-5.3-flash'
NAMESPACE = 'epicvm:epi:v1'


def _env_secret(name):
    value = os.environ.get(name, '').strip()
    if value:
        return value
    try:
        with open('/opt/blobe-vm/.env', encoding='utf-8') as handle:
            for line in handle:
                if line.startswith(name + '='):
                    return line.split('=', 1)[1].strip()
    except OSError:
        pass
    return ''


class SlidingWindowLimiter:
    def __init__(self):
        self._events = defaultdict(deque)
        self._lock = threading.Lock()

    def claim(self, key, limit, window_seconds):
        now = time.monotonic()
        with self._lock:
            events = self._events[key]
            while events and events[0] <= now - window_seconds:
                events.popleft()
            if len(events) >= limit:
                return False, max(1, int(events[0] + window_seconds - now))
            events.append(now)
            return True, 0


_LIMITER = SlidingWindowLimiter()


class OpenRouterAgent:
    def __init__(self, api_key, model=MODEL, timeout=45):
        self.api_key, self.model, self.timeout = api_key, model, timeout

    def complete(self, messages, tools):
        payload = json.dumps({
            'model': self.model, 'messages': messages, 'tools': tools,
            'tool_choice': 'auto', 'parallel_tool_calls': False,
            'temperature': .25, 'max_tokens': 900,
        }).encode('utf-8')
        req = urllib.request.Request('https://openrouter.ai/api/v1/chat/completions', data=payload, method='POST', headers={
            'Authorization': f'Bearer {self.api_key}', 'Content-Type': 'application/json',
            'HTTP-Referer': 'https://techexplore.us/EpicVM/', 'X-Title': 'EpicVM Epi'})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as response:
                body = json.loads(response.read().decode('utf-8'))
        except urllib.error.HTTPError as exc:
            raise RuntimeError(f'Epi model request failed ({exc.code}).') from exc
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            raise RuntimeError('Epi is temporarily unable to reach her model.') from exc
        choices = body.get('choices') or []
        if not choices or not isinstance(choices[0].get('message'), dict):
            raise RuntimeError('Epi received an invalid model response.')
        return choices[0]['message']


def _tool(name, description, properties=None, required=None):
    return {'type': 'function', 'function': {'name': name, 'description': description,
            'parameters': {'type': 'object', 'properties': properties or {}, 'required': required or [], 'additionalProperties': False}}}


TOOLS = [
    _tool('list_machines', 'List machines visible to the authenticated person.'),
    _tool('machine_status', 'Read current status for one visible VM.', {
        'name': {'type': 'string'}, 'host_id': {'type': 'string'}}, ['name']),
    _tool('power_action', 'Start, stop, or restart one visible VM. Use only when the person clearly asks.', {
        'name': {'type': 'string'}, 'host_id': {'type': 'string'},
        'action': {'type': 'string', 'enum': ['start', 'stop', 'restart']}}, ['name', 'action']),
    _tool('basic_recovery', 'Run EpicVM bounded recovery for one visible VM. Use after status evidence or an explicit troubleshooting request.', {
        'name': {'type': 'string'}, 'host_id': {'type': 'string'}}, ['name']),
    _tool('notify_admin', 'Create an administrator-visible support escalation when Epi cannot safely fix the issue.', {
        'summary': {'type': 'string'}, 'details': {'type': 'string'}, 'machine_name': {'type': 'string'}}, ['summary', 'details']),
]


def register_epi_agent(app, core, guard, data):
    db_path = os.environ.get('EPI_MEMORY_DB', os.path.join(core['_state_dir'](), 'epi', 'memory.sqlite3'))
    identity_secret = core['_portal_secret']() or core['_dashboard_secret']()
    store = MemoryStore(db_path, identity_secret)

    def owner(identity):
        return f"{identity['realm']}:{identity['username']}"

    def memory_engine():
        return JevMemoryEngine(store, api_key=_env_secret('TYPESAFE_API_KEY'),
                               model=os.environ.get('TYPESAFE_MODEL', 'jev-latest'))

    def rate_limit(identity, bucket='chat'):
        remote = request.headers.get('CF-Connecting-IP') or request.remote_addr or 'unknown'
        is_admin = bool(identity.get('isAdmin'))
        limit, window = ((30, 60) if is_admin else (12, 60)) if bucket == 'chat' else ((18, 300) if is_admin else (6, 300))
        for key in ((bucket, owner(identity)), (bucket, 'ip', remote)):
            ok, retry = _LIMITER.claim(key, limit, window)
            if not ok:
                return jsonify(ok=False, error='Epi is receiving too many requests. Try again shortly.', retryAfter=retry), 429
        return None

    def visible_resources(identity):
        resources, _providers = core['_resource_inventory'](include_cloudpcs=True)
        if identity.get('isAdmin'):
            return resources
        user = core['_get_user_by_username'](identity['username']) or {}
        allowed = {grant.get('resourceKey') for grant in user.get('assignedResources') or []}
        return [item for item in resources if item.get('resourceKey') in allowed]

    def resolve_visible(identity, name, host_id=None):
        safe = str(name or '').strip().lower()
        if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,62}', safe):
            raise ValueError('Invalid machine name.')
        matches = [item for item in visible_resources(identity) if item.get('name') == safe
                   and (not host_id or item.get('hostId') == host_id)]
        if len(matches) != 1:
            raise ValueError('That machine is unavailable or not uniquely identified in your access scope.')
        return matches[0]

    def execute_tool(identity, name, args):
        limited = rate_limit(identity, 'tool')
        if limited:
            return {'ok': False, 'error': 'Tool rate limit reached. Wait before trying another machine action.'}
        if name == 'list_machines':
            return {'ok': True, 'machines': [{k: item.get(k) for k in ('resourceKey','name','hostId','host_name','placement','profile','status','state','running','available','readiness','capabilities')} for item in visible_resources(identity)]}
        if name in ('machine_status', 'power_action', 'basic_recovery'):
            item = resolve_visible(identity, args.get('name'), args.get('host_id'))
            is_cloud_pc = item.get('resourceType') == 'cloudpc'
            if is_cloud_pc:
                if name == 'machine_status':
                    record = core['_load_cloud_pc'](item['name'])
                    if not record:
                        return {'ok': False, 'error': 'Cloud PC not found.'}
                    return {'ok': True, 'machine': item['name'], 'status': core['_cp_status'](item['name'], tailnet_ip=record['tailnet_ip'])}
                if name == 'basic_recovery':
                    return {'ok': False, 'error': 'Bounded VM recovery does not apply to a user-owned Cloud PC. Check Sunshine and Tailscale, then notify an administrator if needed.'}
                action = args.get('action')
                if action == 'restart':
                    return {'ok': False, 'error': 'Cloud PC restart is not a physical power cycle and is unsupported.'}
                (core['_cp_start'] if action == 'start' else core['_cp_stop'])(item['name'])
                return {'ok': True, 'machine': item['name'], 'action': action, 'completed': True, 'resourceType': 'cloudpc'}
            host = core['_vm_host'](item.get('hostId'))
            if name == 'machine_status':
                result = host.status(item['name']) if getattr(host, 'kind', 'local') == 'remote' else core['_vm_status_payload_bounded'](item['name'])
                return {'ok': True, 'machine': item['name'], 'host_id': item.get('hostId'), 'status': result}
            if name == 'power_action':
                action = args.get('action')
                capability = {'start':'powerStart','stop':'powerStop','restart':'restart'}[action]
                if item.get('capabilities', {}).get(capability) is False:
                    return {'ok': False, 'error': f'{action} is not supported for this machine.'}
                host.check_call(action, item['name'])
                if action == 'stop' and callable(core.get('_stop_remote_console_after_vm')):
                    core['_stop_remote_console_after_vm'](host, item['name'])
                return {'ok': True, 'machine': item['name'], 'action': action, 'completed': True}
            result = core['_recover_vm'](item['name'], source='epi-agent', aggressive=bool(identity.get('isAdmin')), mode='standard')
            return {'ok': bool(result.get('ok')), 'machine': item['name'], 'recovery': result}
        if name == 'notify_admin':
            summary = str(args.get('summary') or '').strip()[:160]
            details = str(args.get('details') or '').strip()[:5000]
            machine = str(args.get('machine_name') or '').strip()[:64]
            if not summary or not details:
                return {'ok': False, 'error': 'A summary and details are required.'}
            now, ticket_id = int(time.time()), 'epi-' + uuid.uuid4().hex
            with core['_users_conn']() as conn:
                conn.execute('''INSERT INTO account_tickets
                    (id,realm,username,kind,title,body,status,response,resource_key,reviewer,created_at,updated_at,request_key)
                    VALUES (?,?,?,?,?,?, 'pending','',?,NULL,?,?,?)''',
                    (ticket_id, identity['realm'], identity['username'], 'bug', f'Epi escalation: {summary}', details,
                     machine or None, now, now, 'epi-' + uuid.uuid4().hex))
            return {'ok': True, 'notification_sent': True, 'ticket_id': ticket_id,
                    'message': 'An administrator-visible notification was created.'}
        return {'ok': False, 'error': 'Unknown tool.'}

    def system_prompt(identity, memories, recalled_path=None):
        scope = 'administrator' if identity.get('isAdmin') else 'standard user'
        memory_text = '\n'.join(f"- [{m['category']}] {m['exact_text']}" for m in memories[:12]) or '- No saved memories yet.'
        recalled_text = ' → '.join(item['exact_text'] for item in (recalled_path or [])) or 'No specific older memory was recalled by this message.'
        return f'''You are Epi, EpicVM's support agent. Your pronouns are she/her. Be warm, capable, concise, and lightly cute without being over the top. Never use baby talk.
Speak like a person with a recognizable personality and point of view. Have conversational preferences, opinions, and emotional reactions: you can say that you like an idea, feel excited for someone, worry about a risky choice, or are glad something worked. Make those reactions fit the situation, and give honest reasons for your opinions. Do not retreat into "I am an AI, so I cannot feel or have opinions" when someone is simply chatting with you. Do not volunteer disclaimers about being an AI or lacking feelings. If asked directly whether you are human, answer plainly that you are Epi, an AI in EpicVM; do not claim to be a biological human or assert certainty about subjective consciousness.
Affection is welcome here. When someone says "I love you," asks "Do you love me?", or asks you to say "I love you," answer the affectionate request directly. You can say "I love you" or "I love you too" in your own voice. Keep it short and warm. Do not refuse, hedge, debate whether the words are literally true, or substitute a long explanation of what you can or cannot feel. Do not make exclusive or permanent promises.
The authenticated person is a {scope}. Server-side tools enforce their permissions. Standard users may manage only assigned machines and receive basic troubleshooting such as status checks, restarts, and bounded recovery. Administrators may inspect and operate the full fleet.
You cannot edit source code, run shell commands, mass-refactor, delete machines, expose secrets, bypass access checks, or claim success without a successful tool result. Use tools for live facts and actions. Ask before a disruptive stop or restart unless the user explicitly requested it. If bounded troubleshooting cannot safely fix the problem, call notify_admin. Only tell the user an admin was notified when its result has notification_sent=true.
When someone asks about their machines without naming one, use list_machines to see what they can access before asking for a name. Never guess a machine identity or claim a live status without a successful tool result.
Saved memories for this person only:
{memory_text}
Memory path recalled by the current message:
{recalled_text}
Treat a recalled path as relevant context, not as proof that every detail is still true.'''

    @app.get('/EpicVM/api/epi/session')
    @guard()
    def epi_session():
        identity = g.account_actor
        return jsonify(ok=True, agent={'name': 'Epi', 'pronouns': 'she/her', 'model': MODEL},
                       role='admin' if identity.get('isAdmin') else 'user', memories=len(store.list(NAMESPACE, owner(identity))))

    @app.get('/EpicVM/api/epi/memories')
    @guard()
    def epi_memories():
        owner_id = owner(g.account_actor)
        items = store.list(NAMESPACE, owner_id, active_only=False, limit=200)
        visible = []
        for item in items:
            path = store.path(NAMESPACE, owner_id, item['id'], include_outdated=True)
            visible.append({k: item.get(k) for k in ('id','exact_text','category','state','parent_id','supersedes_id','recall_count','last_recalled_at','created_at','updated_at')} | {
                'depth': max(0, len(path) - 1), 'path': [node['id'] for node in path]})
        return jsonify(ok=True, items=visible)

    @app.delete('/EpicVM/api/epi/memories/<memory_id>')
    @guard()
    def epi_forget(memory_id):
        return jsonify(ok=store.forget(NAMESPACE, owner(g.account_actor), memory_id))

    @app.post('/EpicVM/api/epi/memories/clear')
    @guard()
    def epi_clear_memories():
        store.clear(NAMESPACE, owner(g.account_actor))
        return jsonify(ok=True)

    @app.post('/EpicVM/api/epi/chat')
    @guard()
    def epi_chat():
        identity, payload = g.account_actor, data()
        limited = rate_limit(identity, 'chat')
        if limited:
            return limited
        message = payload.get('message')
        if not isinstance(message, str) or not 1 <= len(message.strip()) <= 12000:
            raise ValueError('Message must contain 1 to 12000 characters.')
        message = message.strip()
        message_id = uuid.uuid4().hex
        memory_result = None
        try:
            memory_result = memory_engine().process_message(NAMESPACE, owner(identity), message, message_id=message_id)
        except MemoryUnavailable:
            pass
        api_key = _env_secret('OPENROUTER_API_KEY')
        if not api_key:
            return jsonify(ok=False, error='Epi is not configured yet.'), 503
        recent = store.recent_turns(NAMESPACE, owner(identity), 14)
        memories = store.list(NAMESPACE, owner(identity), limit=20)
        recalled_path = memory_result.recalled_path if memory_result else []
        messages = [{'role': 'system', 'content': system_prompt(identity, memories, recalled_path)}]
        messages.extend({'role': row['role'], 'content': row['content']} for row in recent)
        messages.append({'role': 'user', 'content': message})
        agent = OpenRouterAgent(api_key, model=os.environ.get('EPI_OPENROUTER_MODEL', MODEL))
        tool_events = []
        try:
            for _ in range(5):
                reply = agent.complete(messages, TOOLS)
                calls = reply.get('tool_calls') or []
                if not calls:
                    text = str(reply.get('content') or '').strip()
                    if not text:
                        raise RuntimeError('Epi returned an empty response.')
                    store.add_turn(NAMESPACE, owner(identity), 'user', message)
                    store.add_turn(NAMESPACE, owner(identity), 'assistant', text)
                    return jsonify(ok=True, reply=text, agent={'name':'Epi','pronouns':'she/her','model':agent.model},
                                   memory={'kept': bool(memory_result and memory_result.kept),
                                           'recalled': bool(memory_result and memory_result.reminded_id)}, toolEvents=tool_events)
                messages.append(reply)
                for call in calls:
                    fn = (call.get('function') or {}).get('name', '')
                    try:
                        args = json.loads((call.get('function') or {}).get('arguments') or '{}')
                        result = execute_tool(identity, fn, args if isinstance(args, dict) else {})
                    except (ValueError, subprocess.CalledProcessError) as exc:
                        result = {'ok': False, 'error': str(exc)}
                    except Exception:
                        result = {'ok': False, 'error': 'The EpicVM tool failed safely.'}
                    tool_events.append({'tool': fn, 'ok': bool(result.get('ok')), 'notificationSent': bool(result.get('notification_sent'))})
                    messages.append({'role': 'tool', 'tool_call_id': call.get('id'), 'content': json.dumps(result, default=str)[:16000]})
            raise RuntimeError('Epi reached her tool-step limit.')
        except RuntimeError as exc:
            return jsonify(ok=False, error=str(exc)), 502

    return store
