"""Account self-service and a deliberately bounded admin workspace."""
import base64
import hashlib
import hmac
import json
import secrets
import time
from functools import wraps

from flask import jsonify, request, redirect, g
from werkzeug.security import generate_password_hash

try:
    from .jev_advisor import JevUnavailable, analyze as jev_analyze, configured as jev_configured
except ImportError:
    from jev_advisor import JevUnavailable, analyze as jev_analyze, configured as jev_configured


def register_account_workspace(app, core):
    def init():
        core['_init_users_db']()
        with core['_users_conn']() as conn:
            conn.executescript('''
                CREATE TABLE IF NOT EXISTS account_admin_passwords (
                    username TEXT PRIMARY KEY, password_hash TEXT NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE IF NOT EXISTS account_tickets (
                    id TEXT PRIMARY KEY, realm TEXT NOT NULL, username TEXT NOT NULL,
                    kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending', response TEXT NOT NULL DEFAULT '',
                    resource_key TEXT, reviewer TEXT, created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL, request_key TEXT NOT NULL,
                    UNIQUE(realm, username, request_key)
                );
            ''')

    def admin_record(username):
        init()
        with core['_users_conn']() as conn:
            row = conn.execute('SELECT * FROM account_admin_passwords WHERE username=?', (username,)).fetchone()
            return dict(row) if row else None

    def admin_password(username, fallback):
        row = admin_record(username)
        return row['password_hash'] if row else fallback

    def dashboard_payload(username, lifetime=86400):
        revision = (admin_record(username) or {}).get('revision', 0)
        identity = base64.urlsafe_b64encode(username.encode()).decode()
        return f'{int(time.time()) + lifetime}:{secrets.token_hex(8)}:{identity}:{revision}'

    def dashboard_identity(payload):
        parts = payload.split(':')
        if len(parts) == 4:
            username = base64.urlsafe_b64decode(parts[2]).decode()
            if username not in (core['_admin_credentials']()[0], core['_extra_admin_credentials']()[0]):
                return None
            if int(parts[3]) != (admin_record(username) or {}).get('revision', 0):
                return None
            return username
        return None

    def dashboard_revision_valid(payload):
        if len(payload.split(':')) == 4:
            return bool(dashboard_identity(payload))
        # Old cookies contain no identity. Permit existing dashboard navigation
        # until a password is rotated, but never guess their self-service owner.
        init()
        with core['_users_conn']() as conn:
            return conn.execute('SELECT COUNT(*) FROM account_admin_passwords').fetchone()[0] == 0

    core['_account_admin_password'] = admin_password
    core['_account_dashboard_payload'] = dashboard_payload
    core['_account_dashboard_revision_valid'] = dashboard_revision_valid

    def actor():
        token = request.cookies.get('Dashboard-Auth', '')
        if token and core['_verify_v2_token'](token):
            payload = base64.urlsafe_b64decode(token).decode().rsplit(':', 1)[0]
            name = dashboard_identity(payload)
            return {'username': name, 'realm': 'dashboard-config', 'isAdmin': True,
                    'accountStatus': 'approved', 'reauthenticate': not bool(name)}
        user = core['_current_portal_user'](require_approved=False)
        if user:
            return {'username': user['username'], 'realm': 'portal',
                    'isAdmin': bool(user.get('isAdmin') and user.get('accountStatus') == 'approved'),
                    'accountStatus': user.get('accountStatus'), 'reauthenticate': False}
        return None

    def csrf(identity):
        cookie_name = 'Dashboard-Auth' if identity['realm'] == 'dashboard-config' else 'Portal-Auth'
        secret = core['_dashboard_secret']() if identity['realm'] == 'dashboard-config' else core['_portal_secret']()
        return hmac.new(secret.encode(), ('account-workspace:' + request.cookies.get(cookie_name, '')).encode(), hashlib.sha256).hexdigest()

    def guard(admin=False):
        def decorate(fn):
            @wraps(fn)
            def wrapped(*args, **kwargs):
                identity = actor()
                if not identity:
                    return jsonify(ok=False, error='Sign in to continue.'), 401
                if identity['reauthenticate']:
                    return jsonify(ok=False, error='Sign in again to identify your admin account.', reauthenticate=True), 401
                if admin and not identity['isAdmin']:
                    return jsonify(ok=False, error='Administrator access required.'), 403
                if request.method != 'GET':
                    if not request.is_json or not core['_same_origin_request']():
                        return jsonify(ok=False, error='Same-origin JSON request required.'), 403
                    if not hmac.compare_digest(request.headers.get('X-CSRF-Token', ''), csrf(identity)):
                        return jsonify(ok=False, error='Session verification failed. Refresh and retry.'), 403
                g.account_actor = identity
                init()
                try:
                    return fn(*args, **kwargs)
                except ValueError as exc:
                    return jsonify(ok=False, error=str(exc)), 400
            return wrapped
        return decorate

    def data():
        value = request.get_json(silent=True)
        if not isinstance(value, dict):
            raise ValueError('A JSON object is required.')
        return value

    try:
        from .shared_games import register_shared_games
    except ImportError:
        from shared_games import register_shared_games
    register_shared_games(app, core, guard, data)

    try:
        from .epi_agent import register_epi_agent
    except ImportError:
        from epi_agent import register_epi_agent
    register_epi_agent(app, core, guard, data)

    def jev_response():
        payload = data()
        try:
            return jsonify(ok=True, advisory=jev_analyze(str(payload.get('task') or ''), payload.get('state')))
        except JevUnavailable as exc:
            return jsonify(ok=False, available=False, error=str(exc)), 503

    @app.get('/EpicVM/api/management/jev/status')
    @guard(admin=True)
    def management_jev_status():
        return jsonify(ok=True, available=jev_configured(), tasks=sorted(TASK for TASK in (
            'ticket_triage', 'vm_request', 'log_triage', 'provisioning_diagnosis', 'host_ranking',
            'game_screening', 'notification_priority', 'response_verification', 'browser_verification')))

    @app.post('/EpicVM/api/management/jev/analyze')
    @guard(admin=True)
    def management_jev_analyze():
        return jev_response()

    @app.post('/dashboard/api/jev/analyze')
    @core['auth_required']
    def dashboard_jev_analyze():
        if not request.is_json or not core['_same_origin_request']():
            return jsonify(ok=False, error='Same-origin JSON request required.'), 403
        return jev_response()

    def text_field(payload, name, maximum, minimum=1):
        value = payload.get(name, '')
        if not isinstance(value, str) or not minimum <= len(value.strip()) <= maximum:
            raise ValueError(f'{name.replace("_", " ").capitalize()} must be {minimum} to {maximum} characters.')
        return value.strip()

    def password_field(payload):
        value = payload.get('newPassword')
        if not isinstance(value, str) or not 8 <= len(value) <= 256:
            raise ValueError('Use a password between 8 and 256 characters.')
        return value

    def refresh_cookie(response, identity):
        if identity['realm'] == 'dashboard-config':
            token = core['_sign_v2_token'](dashboard_payload(identity['username']))
            cookie, lifetime = 'Dashboard-Auth', 86400
        else:
            token = core['_create_portal_token'](identity['username'], identity['isAdmin'])
            cookie, lifetime = 'Portal-Auth', 30 * 86400
        response.set_cookie(cookie, token, httponly=True, secure=core['_request_is_https'](), samesite='Strict', max_age=lifetime, path='/')
        return response

    @app.after_request
    def workspace_cache(response):
        if request.path.startswith('/EpicVM/api/account') or request.path.startswith('/EpicVM/api/management'):
            response.headers['Cache-Control'] = 'no-store'
        return response

    @app.get('/settings')
    @app.get('/settings/')
    def account_settings_shortcut():
        return redirect('/EpicVM/settings')

    @app.get('/EpicVM/api/account/session')
    def account_session():
        identity = actor()
        if not identity:
            return jsonify(ok=False, authenticated=False), 401
        return jsonify(ok=True, authenticated=True, user=identity, csrfToken=csrf(identity))

    @app.post('/EpicVM/api/account/password')
    @guard()
    def account_password():
        identity, payload = g.account_actor, data()
        new_password = password_field(payload)
        current = payload.get('currentPassword', '')
        if not isinstance(current, str) or len(current) > 256:
            raise ValueError('Current password is required.')
        key = ('account-password', identity['realm'], identity['username'])
        now = time.time()
        with core['_LOGIN_LOCK']:
            attempt = core['_LOGIN_ATTEMPTS'].get(key, {'count': 0, 'until': 0})
            if attempt['until'] > now:
                return jsonify(ok=False, error='Too many attempts. Try again shortly.'), 429
        if identity['realm'] == 'dashboard-config':
            valid = core['_valid_dashboard_admin'](identity['username'], current)
        else:
            user = core['_get_user_by_username'](identity['username'])
            valid = core['_verify_user_password'](current, user['password_hash'])
        if not valid:
            with core['_LOGIN_LOCK']:
                count = attempt['count'] + 1
                core['_LOGIN_ATTEMPTS'][key] = {'count': count, 'until': now + min(60, 2 ** min(count, 6))}
            return jsonify(ok=False, error='Current password is incorrect.'), 400
        if identity['realm'] == 'dashboard-config':
            with core['_users_conn']() as conn:
                conn.execute('''INSERT INTO account_admin_passwords(username,password_hash,revision) VALUES(?,?,1)
                    ON CONFLICT(username) DO UPDATE SET password_hash=excluded.password_hash, revision=revision+1''',
                    (identity['username'], generate_password_hash(new_password)))
        else:
            core['_update_user'](identity['username'], password=new_password)
        with core['_LOGIN_LOCK']:
            core['_LOGIN_ATTEMPTS'].pop(key, None)
        return refresh_cookie(jsonify(ok=True, message='Password updated. Other sessions have been signed out.'), identity)

    @app.get('/EpicVM/api/account/tickets')
    @guard()
    def account_tickets():
        who = g.account_actor
        with core['_users_conn']() as conn:
            rows = conn.execute('SELECT * FROM account_tickets WHERE realm=? AND username=? ORDER BY created_at DESC',
                                (who['realm'], who['username'])).fetchall()
        return jsonify(ok=True, tickets=[dict(row) for row in rows])

    @app.post('/EpicVM/api/account/tickets')
    @guard()
    def account_ticket_create():
        who, payload = g.account_actor, data()
        kind = payload.get('kind')
        if kind not in ('vm', 'feedback', 'bug'):
            raise ValueError('Choose VM request, feedback, or bug report.')
        title = text_field(payload, 'title', 120)
        body = text_field(payload, 'body', 6000, 5)
        request_key = text_field(payload, 'requestKey', 100)
        with core['_users_conn']() as conn:
            conn.execute('BEGIN IMMEDIATE')
            existing = conn.execute('SELECT id FROM account_tickets WHERE realm=? AND username=? AND request_key=?',
                                    (who['realm'], who['username'], request_key)).fetchone()
            if existing:
                return jsonify(ok=True, id=existing['id'])
            recent = conn.execute('SELECT COUNT(*) FROM account_tickets WHERE realm=? AND username=? AND created_at>?',
                                  (who['realm'], who['username'], int(time.time()) - 3600)).fetchone()[0]
            if recent >= 10:
                return jsonify(ok=False, error='You can submit up to 10 requests or reports per hour.'), 429
            ticket_id, now = secrets.token_hex(12), int(time.time())
            conn.execute('''INSERT INTO account_tickets(id,realm,username,kind,title,body,created_at,updated_at,request_key)
                            VALUES(?,?,?,?,?,?,?,?,?)''', (ticket_id, who['realm'], who['username'], kind, title, body, now, now, request_key))
        return jsonify(ok=True, id=ticket_id), 201

    @app.get('/EpicVM/api/management/overview')
    @guard(admin=True)
    def management_overview():
        # Reuse the parity inventory/grant contract, behind this narrower gate.
        result = core['dashboard_users_list'].__wrapped__().get_json()
        with core['_users_conn']() as conn:
            result['tickets'] = [dict(row) for row in conn.execute('SELECT * FROM account_tickets ORDER BY created_at DESC')]
            # The focused workspace must not hide pending access requests behind
            # the full dashboard's paginated history.
            result['requests'] = [dict(row) for row in conn.execute('SELECT * FROM access_requests ORDER BY created_at DESC')]
        return jsonify(result)

    @app.get('/EpicVM/api/management/provisioning')
    @guard(admin=True)
    def management_provisioning():
        """Expose safe placement data plus a bounded recent-job history."""
        try:
            registry = core['VM_HOST_REGISTRY']
            registry.refresh()
            hosts = [core['redact_host_record'](record) for record in registry.public_records()]
            pending_response = core['api_provisioning_jobs_pending'].__wrapped__()
            pending_payload = pending_response.get_json() if hasattr(pending_response, 'get_json') else {}
            enriched = {
                (str(entry.get('host_id') or ''), str((entry.get('job') or {}).get('id') or '')): entry
                for entry in pending_payload.get('jobs', []) if isinstance(entry, dict)
            }
            recent = []
            providers = getattr(registry, 'providers', {}) or {}
            for provider_id, host in providers.items():
                if str(provider_id) == 'local' or not hasattr(host, 'provisioning_jobs'):
                    continue
                try:
                    raw_jobs = host.provisioning_jobs()
                except Exception:
                    continue
                for raw_job in raw_jobs if isinstance(raw_jobs, list) else []:
                    safe_job = core['_safe_provisioning_job'](raw_job)
                    key = (str(provider_id), str(safe_job.get('id') or ''))
                    if key in enriched:
                        safe_job.update(enriched[key].get('job') or {})
                    recent.append({'host_id': str(provider_id),
                                   'host_name': str(getattr(host, 'host_name', provider_id) or provider_id),
                                   'job': safe_job})
            recent.sort(key=lambda entry: str((entry.get('job') or {}).get('updatedAt') or ''), reverse=True)
            return jsonify(ok=True, hosts=hosts, jobs=pending_payload.get('jobs', []),
                           recentJobs=recent[:12],
                           sunshineDefaultConfigured=bool(pending_payload.get('sunshineDefaultConfigured')))
        except core['RemoteHostConfigError'] as exc:
            return jsonify(ok=False, error=str(exc)), 500

    @app.post('/EpicVM/api/management/provisioning')
    @guard(admin=True)
    def management_provisioning_create():
        """Start a VM through the established, capability-gated pipeline."""
        payload = data()
        payload['name'] = str(payload.get('name') or '').strip().lower()
        payload['mode'] = 'automatic'
        request._cached_json = (payload, payload)
        return core['api_provisioning_job_create'].__wrapped__()

    @app.post('/EpicVM/api/management/vms')
    @guard(admin=True)
    def management_vm_create():
        """Create a normal server VM through the established local manager."""
        payload = data()
        payload['name'] = str(payload.get('name') or '').strip().lower()
        payload['placement'] = 'local'
        payload['host_id'] = 'local'
        request._cached_json = (payload, payload)
        return core['api_create'].__wrapped__()

    @app.get('/EpicVM/api/management/provisioning/<job_id>')
    @guard(admin=True)
    def management_provisioning_status(job_id):
        return core['api_provisioning_job_status'].__wrapped__(job_id)

    @app.post('/EpicVM/api/management/provisioning/<job_id>/retry-console')
    @guard(admin=True)
    def management_provisioning_retry_console(job_id):
        """Retry a retained console without sending protected defaults to the browser."""
        payload = data()
        credentials = core['_default_guest_credentials']()
        if not credentials:
            return jsonify(ok=False, error='Protected guest defaults are not configured.'), 503
        request._cached_json = ({'host_id': str(payload.get('host_id') or '').strip(),
                                 'username': credentials[0], 'password': credentials[1]},) * 2
        try:
            return core['api_provisioning_job_retry_console'].__wrapped__(job_id)
        finally:
            credentials = None

    @app.post('/EpicVM/api/management/provisioning/<job_id>/continue')
    @guard(admin=True)
    def management_provisioning_continue(job_id):
        """Continue an abandoned claim with protected automatic-mode defaults."""
        payload = data()
        host_id = str(payload.get('host_id') or '').strip()
        credentials = core['_default_guest_credentials']()
        if not host_id or not credentials:
            return jsonify(ok=False, error='The host and protected guest defaults are required.'), 503
        request._cached_json = ({'host_id': host_id, 'job_id': job_id},) * 2
        recovered = core['api_provisioning_job_recover'].__wrapped__()
        recovered_response = recovered[0] if isinstance(recovered, tuple) else recovered
        recovered_status = recovered[1] if isinstance(recovered, tuple) else getattr(recovered_response, 'status_code', 200)
        recovered_body = recovered_response.get_json() if hasattr(recovered_response, 'get_json') else {}
        if int(recovered_status) >= 400 or not recovered_body.get('claimToken'):
            return recovered
        request._cached_json = ({'host_id': host_id, 'username': credentials[0], 'password': credentials[1],
                                 'claimToken': recovered_body['claimToken']},) * 2
        try:
            return core['api_provisioning_job_claim'].__wrapped__(job_id)
        finally:
            credentials = None
            recovered_body.pop('claimToken', None)

    @app.post('/EpicVM/api/management/machines/<name>')
    @guard(admin=True)
    def management_machine_action(name):
        """Expose only the everyday, reversible VM lifecycle actions."""
        payload = data()
        action = str(payload.get('action') or '').strip().lower()
        host_id = str(payload.get('host_id') or 'local').strip() or 'local'
        if action not in ('start', 'stop', 'restart'):
            raise ValueError('Choose start, stop, or restart.')
        resources, _ = core['_resource_inventory']()
        resource = next((item for item in resources
                         if item.get('resourceType') == 'vm'
                         and item.get('classification') == 'managed'
                         and str(item.get('name') or '') == name
                         and str(item.get('hostId') or 'local') == host_id), None)
        if not resource:
            return jsonify(ok=False, error='Managed VM not found.'), 404
        capability = {'start': 'powerStart', 'stop': 'powerStop', 'restart': 'restart'}[action]
        if (resource.get('capabilities') or {}).get(capability) is False:
            return jsonify(ok=False, error=f'{action.capitalize()} is unavailable for this VM.'), 409
        request._cached_json = ({'host_id': host_id},) * 2
        handler = {'start': core['api_start'], 'stop': core['api_stop'], 'restart': core['api_restart']}[action]
        return handler.__wrapped__(name)

    @app.post('/EpicVM/api/management/users/<username>')
    @guard(admin=True)
    def management_user(username):
        payload, who = data(), g.account_actor
        target = core['_get_user_by_username'](username)
        if not target:
            return jsonify(ok=False, error='Account not found.'), 404
        if who['realm'] == 'portal' and who['username'] == username:
            raise ValueError('Use Settings for your password. Another administrator must manage your account access.')
        action = payload.get('action')
        if action in ('approve', 'reject'):
            core['_update_user'](username, account_status='approved' if action == 'approve' else 'rejected')
        elif action == 'password':
            core['_update_user'](username, password=password_field(payload))
        elif action == 'access':
            grants = payload.get('assignedResources')
            if not isinstance(grants, list) or len(grants) > 200 or not all(isinstance(x, str) for x in grants):
                raise ValueError('Choose valid VM assignments.')
            core['_update_user'](username, assigned_resources=grants)
        elif action in ('disable', 'enable'):
            core['_update_user'](username, disabled=action == 'disable')
        else:
            raise ValueError('Unknown account action.')
        return jsonify(ok=True)

    @app.post('/EpicVM/api/management/access-requests/<int:req_id>')
    @guard(admin=True)
    def management_access_request(req_id):
        # Existing portal machine-access requests use the same atomic grant path.
        return core['dashboard_access_request_action'].__wrapped__(req_id)

    @app.post('/EpicVM/api/management/tickets/<ticket_id>')
    @guard(admin=True)
    def management_ticket(ticket_id):
        payload, who = data(), g.account_actor
        status = payload.get('status')
        if status not in ('in_review', 'fulfilled', 'declined', 'resolved'):
            raise ValueError('Choose a valid request status.')
        response = text_field(payload, 'response', 3000)
        with core['_users_conn']() as conn:
            ticket = conn.execute('SELECT * FROM account_tickets WHERE id=?', (ticket_id,)).fetchone()
        if not ticket:
            return jsonify(ok=False, error='Request not found.'), 404
        if ticket['kind'] == 'vm' and status == 'resolved' or ticket['kind'] != 'vm' and status == 'fulfilled':
            raise ValueError('Choose a status appropriate for this request type.')
        resource = None
        if ticket['kind'] == 'vm' and status == 'fulfilled':
            key = text_field(payload, 'resourceKey', 512)
            resources, _ = core['_resource_inventory']()
            resource = next((r for r in resources if r['resourceKey'] == key and r['resourceType'] == 'vm'
                             and r.get('classification') == 'managed' and r.get('available', True)), None)
            if not resource:
                raise ValueError('Select an available, managed VM to fulfill this request.')
        with core['_users_conn']() as conn:
            conn.execute('BEGIN IMMEDIATE')
            current = conn.execute('SELECT * FROM account_tickets WHERE id=?', (ticket_id,)).fetchone()
            if current['status'] in ('fulfilled', 'declined', 'resolved'):
                return jsonify(ok=False, error='This request is already closed.'), 409
            if resource and ticket['realm'] == 'portal':
                user = conn.execute('SELECT * FROM users WHERE username=?', (ticket['username'],)).fetchone()
                if not user or user['disabled'] or user['account_status'] != 'approved':
                    raise ValueError('Approve and enable the account before assigning a VM.')
                conn.execute('''INSERT OR IGNORE INTO user_resource_access
                    (user_id,resource_key,resource_type,host_id,display_name) VALUES(?,?,?,?,?)''',
                    (user['id'], resource['resourceKey'], 'vm', resource['hostId'], resource['name']))
            conn.execute('''UPDATE account_tickets SET status=?,response=?,resource_key=?,reviewer=?,updated_at=? WHERE id=?''',
                         (status, response, resource['resourceKey'] if resource else None,
                          who['realm'] + ':' + who['username'], int(time.time()), ticket_id))
        return jsonify(ok=True)

    return dashboard_identity
