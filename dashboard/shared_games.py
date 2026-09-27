"""Shared game management uses the host agent and existing account guards."""
import hashlib
import re
from urllib.parse import quote, urlparse
from flask import jsonify, request, g
try:
    from .remote_agent_client import RemoteAgentError
except ImportError:
    from remote_agent_client import RemoteAgentError


def register_shared_games(app, core, guard, data):
    def stream_name(actor, host_id):
        identity = f"{actor['realm']}:{actor['username']}:{host_id}".lower()
        return 'seat-' + hashlib.sha256(identity.encode()).hexdigest()[:24]

    def streams_db():
        core['_init_users_db']()
        with core['_users_conn']() as conn:
            conn.execute('''CREATE TABLE IF NOT EXISTS host_game_streams (
                name TEXT PRIMARY KEY, realm TEXT NOT NULL, username TEXT NOT NULL,
                host_id TEXT NOT NULL, seat_id TEXT NOT NULL, port_base INTEGER NOT NULL)''')

    def stream_record(name):
        streams_db()
        with core['_users_conn']() as conn:
            row = conn.execute('SELECT * FROM host_game_streams WHERE name=?', (name,)).fetchone()
        return dict(row) if row else None

    core['_host_game_stream_record'] = stream_record

    def stream_orchestrator():
        return core['_console_orchestrator']()

    def launch_url(name):
        return f'/EpicVM/stream-launch/{name}'

    def host_stream_ip(host_id):
        address = urlparse(host_client(host_id).base_url).hostname or ''
        # The Moonlight server only accepts Tailscale IPv4 addresses.
        from ipaddress import ip_address, ip_network
        if ip_address(address) not in ip_network('100.64.0.0/10'):
            raise ValueError('The game host has no private stream address.')
        return address

    def host_gaming(host_id, method='GET', suffix='', payload=None):
        try:
            return host_client(host_id)._request(method, '/v1/host-gaming' + suffix, payload, timeout=120)
        except RemoteAgentError as exc:
            raise ValueError('Native gaming host is unavailable: ' + str(exc)) from exc

    def native_grants():
        core['_init_users_db']()
        with core['_users_conn']() as conn:
            conn.execute('''CREATE TABLE IF NOT EXISTS host_game_grants (
                realm TEXT NOT NULL, username TEXT NOT NULL, host_id TEXT NOT NULL,
                game_id TEXT NOT NULL, PRIMARY KEY (realm, username, host_id, game_id))''')

    def allowed_host_games(actor, host_id):
        native_grants()
        with core['_users_conn']() as conn:
            rows = conn.execute('SELECT game_id FROM host_game_grants WHERE realm=? AND username=? AND host_id=?',
                                (actor['realm'], actor['username'], host_id)).fetchall()
        return {row['game_id'] for row in rows}

    def desktop_grants():
        core['_init_users_db']()
        with core['_users_conn']() as conn:
            conn.execute('''CREATE TABLE IF NOT EXISTS host_desktop_grants (
                realm TEXT NOT NULL, username TEXT NOT NULL, host_id TEXT NOT NULL,
                PRIMARY KEY (realm, username, host_id))''')

    def desktop_hosts():
        hosts = []
        for record in core['VM_HOST_REGISTRY'].public_records():
            if str(record.get('platform', '')).lower() != 'windows':
                continue
            host_id = str(record.get('id') or '')
            if not host_id:
                continue
            try:
                catalog = host_gaming(host_id)
            except (KeyError, RuntimeError, ValueError):
                continue
            if int(catalog.get('apiVersion') or 0) < 3 or not catalog.get('ready'):
                continue
            hosts.append({'hostId': host_id, 'displayName': record.get('display_name') or host_id})
        return hosts

    def has_desktop_access(actor, host_id):
        if actor['isAdmin']:
            return True
        desktop_grants()
        with core['_users_conn']() as conn:
            row = conn.execute('SELECT 1 FROM host_desktop_grants WHERE realm=? AND username=? AND host_id=?',
                               (actor['realm'], actor['username'], host_id)).fetchone()
        return row is not None

    def seat_account(actor):
        owner = actor['realm'] + ':' + actor['username']
        digest = hashlib.sha256(owner.lower().encode('utf-8')).hexdigest()
        label = actor['username'].lower()
        if actor['realm'] == 'portal' and re.fullmatch(r'[a-z0-9_]{1,13}', label) and not label.startswith('cfg_'):
            return 'EpicVM_' + label
        if actor['realm'] == 'dashboard-config':
            return 'EpicVM_cfg_' + digest[:9]
        safe = re.sub(r'[^a-z0-9_]', '_', label).strip('_') or 'user'
        return 'EpicVM_' + safe[:8] + '_' + digest[:4]

    def legacy_seat_account(actor):
        owner = actor['realm'] + ':' + actor['username']
        return 'evseat_' + hashlib.sha256(owner.lower().encode('utf-8')).hexdigest()[:13]

    @app.get('/EpicVM/api/management/host-gaming')
    @guard(admin=True)
    def host_gaming_admin():
        host_id = request.args.get('hostId', 'epic-pc')
        result = host_gaming(host_id)
        result['supportsRecovery'] = int(result.get('apiVersion') or 0) >= 2
        streams_db()
        with core['_users_conn']() as conn:
            result['streams'] = [dict(row) for row in conn.execute('SELECT * FROM host_game_streams WHERE host_id=?', (host_id,))]
        desktop_grants()
        with core['_users_conn']() as conn:
            result['desktopGrants'] = [dict(row) for row in conn.execute(
                'SELECT realm, username, host_id FROM host_desktop_grants WHERE host_id=?', (host_id,))]
        result['supportsCredentialReveal'] = int(result.get('apiVersion') or 0) >= 3
        return jsonify(result)

    @app.post('/EpicVM/api/management/host-gaming/desktop-grants')
    @guard(admin=True)
    def host_desktop_grant():
        payload = data()
        host_id, username = str(payload.get('hostId', 'epic-pc')), str(payload.get('username', ''))
        if not username or not core['_get_user_by_username'](username):
            raise ValueError('Choose an existing portal account.')
        user = core['_get_user_by_username'](username)
        if user.get('accountStatus') != 'approved':
            raise ValueError('Choose an approved account.')
        if payload.get('enabled', True) and host_id not in {item['hostId'] for item in desktop_hosts()}:
            raise ValueError('Choose an available MultiSeat Windows desktop.')
        desktop_grants()
        with core['_users_conn']() as conn:
            if payload.get('enabled', True):
                existing = conn.execute('SELECT 1 FROM host_desktop_grants WHERE realm=? AND username=? AND host_id=?',
                                        ('portal', username, host_id)).fetchone()
                if existing:
                    return jsonify(ok=False, error='This desktop is already assigned to that account.'), 409
                conn.execute('INSERT INTO host_desktop_grants VALUES (?,?,?)', ('portal', username, host_id))
            else:
                conn.execute('DELETE FROM host_desktop_grants WHERE realm=? AND username=? AND host_id=?',
                             ('portal', username, host_id))
        if not payload.get('enabled', True):
            owner = {'realm': 'portal', 'username': username}
            name = stream_name(owner, host_id)
            try:
                stream_orchestrator().quarantine_staged(name)
            finally:
                streams_db()
                with core['_users_conn']() as conn:
                    conn.execute('DELETE FROM host_game_streams WHERE name=?', (name,))
                host_gaming(host_id, 'POST', '/stop', {'owner': 'portal:' + username})
        return jsonify(ok=True)

    @app.get('/EpicVM/api/management/host-gaming/desktops')
    @guard(admin=True)
    def host_gaming_desktop_hosts():
        return jsonify(ok=True, desktops=desktop_hosts())

    @app.post('/EpicVM/api/management/host-gaming/account-credential/reveal')
    @guard(admin=True)
    def host_account_credential_reveal():
        payload = data()
        host_id, username = str(payload.get('hostId', 'epic-pc')), str(payload.get('username', ''))
        if not username or not core['_get_user_by_username'](username):
            raise ValueError('Choose an existing portal account.')
        if int(host_gaming(host_id).get('apiVersion') or 0) < 3:
            raise ValueError('The game host needs its credential service update.')
        result = host_gaming(host_id, 'POST', '/account-credential/reveal', {'owner': 'portal:' + username})
        core['_init_users_db']()
        with core['_users_conn']() as conn:
            conn.execute('''CREATE TABLE IF NOT EXISTS host_credential_reveals (
                id INTEGER PRIMARY KEY, actor_realm TEXT NOT NULL, actor_username TEXT NOT NULL,
                target_username TEXT NOT NULL, host_id TEXT NOT NULL,
                revealed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)''')
            conn.execute('''INSERT INTO host_credential_reveals
                (actor_realm, actor_username, target_username, host_id) VALUES (?,?,?,?)''',
                (g.account_actor['realm'], g.account_actor['username'], username, host_id))
        response = jsonify(result)
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Pragma'] = 'no-cache'
        return response

    @app.post('/EpicVM/api/management/host-gaming/recover')
    @guard(admin=True)
    def host_gaming_recover():
        payload = data()
        host_id, owner = str(payload.get('hostId', 'epic-pc')), str(payload.get('owner', ''))
        if int(host_gaming(host_id).get('apiVersion') or 0) < 2:
            raise ValueError('The game host is waiting for its agent update.')
        seat_id = str(payload.get('seatId', ''))
        if seat_id:
            catalog = host_gaming(host_id)
            if seat_id not in {seat.get('id') for seat in catalog.get('seats', [])}:
                raise ValueError('Choose an existing managed seat.')
            streams_db()
            with core['_users_conn']() as conn:
                row = conn.execute('SELECT name FROM host_game_streams WHERE host_id=? AND seat_id=?', (host_id, seat_id)).fetchone()
            if row:
                try:
                    stream_orchestrator().quarantine_staged(row['name'])
                finally:
                    with core['_users_conn']() as conn:
                        conn.execute('DELETE FROM host_game_streams WHERE name=?', (row['name'],))
            return jsonify(host_gaming(host_id, 'POST', '/recover', {'seatId': seat_id}))
        if not owner.startswith(('portal:', 'dashboard-config:')):
            raise ValueError('Choose a valid seat owner.')
        realm, username = owner.split(':', 1)
        actor = {'realm': realm, 'username': username}
        name = stream_name(actor, host_id)
        try:
            stream_orchestrator().quarantine_staged(name)
        finally:
            streams_db()
            with core['_users_conn']() as conn:
                conn.execute('DELETE FROM host_game_streams WHERE name=?', (name,))
            host_gaming(host_id, 'POST', '/stop', {'owner': owner})
        return jsonify(ok=True)

    @app.post('/EpicVM/api/management/host-gaming/games')
    @guard(admin=True)
    def host_gaming_register():
        payload = data()
        return jsonify(host_gaming(str(payload.get('hostId', 'epic-pc')), 'POST', '/games', payload))

    @app.post('/EpicVM/api/management/host-gaming/games/remove')
    @guard(admin=True)
    def host_gaming_unregister():
        payload = data()
        host_id, game_id = str(payload.get('hostId', 'epic-pc')), str(payload.get('gameId', ''))
        if int(host_gaming(host_id).get('apiVersion') or 0) < 2:
            raise ValueError('The game host is waiting for its agent update.')
        result = host_gaming(host_id, 'POST', '/games/remove', {'id': game_id})
        native_grants()
        with core['_users_conn']() as conn:
            conn.execute('DELETE FROM host_game_grants WHERE host_id=? AND game_id=?', (host_id, game_id))
        return jsonify(result)

    @app.post('/EpicVM/api/management/host-gaming/grants')
    @guard(admin=True)
    def host_gaming_grant():
        payload = data()
        realm, username = str(payload.get('realm', 'portal')), str(payload.get('username', ''))
        host_id, game_id = str(payload.get('hostId', 'epic-pc')), str(payload.get('gameId', ''))
        if realm != 'portal' or not username or not game_id:
            raise ValueError('Choose a portal account and host game.')
        user = core['_get_user_by_username'](username)
        if not user or user.get('accountStatus') != 'approved':
            raise ValueError('Choose an approved account.')
        catalog = host_gaming(host_id)
        if game_id not in {game['id'] for game in catalog.get('games', [])}:
            raise ValueError('Choose a registered host game.')
        native_grants()
        with core['_users_conn']() as conn:
            if payload.get('enabled', True):
                conn.execute('INSERT OR IGNORE INTO host_game_grants VALUES (?,?,?,?)', (realm, username, host_id, game_id))
            else:
                conn.execute('DELETE FROM host_game_grants WHERE realm=? AND username=? AND host_id=? AND game_id=?',
                             (realm, username, host_id, game_id))
        return jsonify(ok=True)

    @app.get('/EpicVM/api/account/host-gaming')
    @guard()
    def host_gaming_account():
        actor = g.account_actor
        if actor['accountStatus'] != 'approved':
            return jsonify(ok=False, error='Account approval required.'), 403
        host_id = request.args.get('hostId', 'epic-pc')
        catalog = host_gaming(host_id)
        allowed = allowed_host_games(actor, host_id)
        games = [game for game in catalog.get('games', []) if actor['isAdmin'] or game['id'] in allowed]
        account_names = {seat_account(actor).lower(), legacy_seat_account(actor).lower()}
        owned = [seat for seat in catalog.get('seats', []) if seat.get('accountName', '').lower() in account_names]
        if len(owned) > 1:
            raise ValueError('This game session needs administrator recovery.')
        seat = ({key: owned[0].get(key) for key in ('id', 'status', 'portBase', 'errorMessage')}
                if owned else None)
        record = stream_record(stream_name(actor, host_id))
        if seat and record and record['seat_id'] == seat['id']:
            seat['launchUrl'] = launch_url(record['name'])
        # Only the owner's session status reaches the browser.
        return jsonify(ok=True, available=catalog.get('ready', False), games=games,
                       desktopAccess=has_desktop_access(actor, host_id), hostId=host_id, seat=seat)

    @app.get('/EpicVM/api/account/host-gaming/desktops')
    @guard()
    def host_gaming_account_desktops():
        actor = g.account_actor
        if actor['accountStatus'] != 'approved':
            return jsonify(ok=False, error='Account approval required.'), 403
        desktop_grants()
        with core['_users_conn']() as conn:
            rows = conn.execute('''SELECT host_id FROM host_desktop_grants
                                   WHERE realm=? AND username=? ORDER BY host_id COLLATE NOCASE''',
                                (actor['realm'], actor['username'])).fetchall()

        account_names = {seat_account(actor).lower(), legacy_seat_account(actor).lower()}
        desktops = []
        for row in rows:
            host_id = str(row['host_id'])
            try:
                host = core['_vm_host'](host_id)
                display_name = str(getattr(host, 'host_name', host_id) or host_id)
            except (KeyError, RuntimeError, ValueError):
                display_name = host_id
            try:
                catalog = host_gaming(host_id)
            except (RuntimeError, ValueError):
                desktops.append({'hostId': host_id, 'displayName': display_name,
                                 'available': False, 'seat': None,
                                 'errorMessage': 'This desktop host is currently unavailable.'})
                continue

            owned = [seat for seat in (catalog.get('seats') or [])
                     if str(seat.get('accountName') or '').lower() in account_names]
            desktop = {'hostId': host_id, 'displayName': display_name,
                       'available': bool(catalog.get('ready', False)), 'seat': None}
            if len(owned) > 1:
                desktop['errorMessage'] = 'This desktop needs administrator recovery.'
            elif owned:
                seat = {key: owned[0].get(key) for key in ('id', 'status', 'portBase', 'errorMessage')}
                record = stream_record(stream_name(actor, host_id))
                if record and record['seat_id'] == seat['id']:
                    seat['launchUrl'] = launch_url(record['name'])
                desktop['seat'] = seat
            desktops.append(desktop)
        return jsonify(ok=True, desktops=desktops)

    def launch_host_session(actor, host_id, agent_path, agent_payload):
        owner = actor['realm'] + ':' + actor['username']
        launched = host_gaming(host_id, 'POST', agent_path, {'owner': owner, **agent_payload})
        name = stream_name(actor, host_id)
        prior = stream_record(name)
        orch = stream_orchestrator()
        if prior and prior['seat_id'] == launched.get('seatId') and prior['port_base'] == launched.get('portBase'):
            try:
                if not orch._runtime_isolated(name):
                    orch.start_staged(name)
                orch.verify_staged(name, guest_ip=host_stream_ip(host_id), route_name=name)
                launched['launchUrl'] = launch_url(name)
                return jsonify(launched)
            except Exception:
                # The seat is still valid, but its browser stream needs a
                # fresh client key and route. Rebuild it below.
                pass
        try:
            orch.quarantine_staged(name)
            host_ip = host_stream_ip(host_id)
            port = int(launched['portBase'])
            plan = orch.build_plan(name=name, guest_ip=host_ip, sunshine_port=port)
            orch.stage_plan(plan)
            streams_db()
            with core['_users_conn']() as conn:
                conn.execute('INSERT OR REPLACE INTO host_game_streams VALUES (?,?,?,?,?,?)',
                             (name, actor['realm'], actor['username'], host_id, launched['seatId'], port))
            orch.start_staged(name)
            orch.pair_staged(name, pin_submitter=lambda pin: host_gaming(host_id, 'POST', '/pair', {'owner': owner, 'pin': pin}))
            launched['launchUrl'] = launch_url(name)
            return jsonify(launched)
        except Exception:
            try:
                orch.quarantine_staged(name)
            finally:
                streams_db()
                with core['_users_conn']() as conn:
                    conn.execute('DELETE FROM host_game_streams WHERE name=?', (name,))
                host_gaming(host_id, 'POST', '/stop', {'owner': owner})
            raise

    @app.post('/EpicVM/api/account/host-gaming/launch')
    @guard()
    def host_gaming_launch():
        actor, payload = g.account_actor, data()
        if actor['accountStatus'] != 'approved':
            return jsonify(ok=False, error='Account approval required.'), 403
        host_id, game_id = str(payload.get('hostId', 'epic-pc')), str(payload.get('gameId', ''))
        if not game_id or (not actor['isAdmin'] and game_id not in allowed_host_games(actor, host_id)):
            raise ValueError('This game is not assigned to your account.')
        return launch_host_session(actor, host_id, '/launch', {'gameId': game_id})

    @app.post('/EpicVM/api/account/host-gaming/desktop')
    @guard()
    def host_desktop_launch():
        actor, payload = g.account_actor, data()
        if actor['accountStatus'] != 'approved':
            return jsonify(ok=False, error='Account approval required.'), 403
        host_id = str(payload.get('hostId', 'epic-pc'))
        if not has_desktop_access(actor, host_id):
            raise ValueError('A personal desktop is not assigned to your account.')
        return launch_host_session(actor, host_id, '/desktop', {})

    @app.post('/EpicVM/api/account/host-gaming/stop')
    @guard()
    def host_gaming_stop():
        actor, payload = g.account_actor, data()
        host_id = str(payload.get('hostId', 'epic-pc'))
        name = stream_name(actor, host_id)
        try:
            stream_orchestrator().quarantine_staged(name)
        finally:
            streams_db()
            with core['_users_conn']() as conn:
                conn.execute('DELETE FROM host_game_streams WHERE name=?', (name,))
            result = host_gaming(host_id, 'POST', '/stop',
                                 {'owner': actor['realm'] + ':' + actor['username']})
        return jsonify(result)
    def host_client(host_id):
        host = core['_vm_host'](host_id)
        if not host or not hasattr(host, 'client'):
            raise ValueError('Choose an available Windows game host.')
        return host.client

    def proxy(host_id, method, path, payload=None):
        try:
            return host_client(host_id)._request(method, '/v1/game-library' + path, payload, timeout=30)
        except RemoteAgentError as exc:
            raise ValueError('The game host could not complete the request. ' + str(exc)) from exc

    @app.get('/EpicVM/api/management/games')
    @guard(admin=True)
    def games_library():
        return jsonify(proxy(request.args.get('hostId', 'epic-pc'), 'GET', ''))

    @app.post('/EpicVM/api/management/games/jobs')
    @guard(admin=True)
    def games_job():
        payload = data()
        host_id = str(payload.get('hostId', 'epic-pc'))
        action = payload.get('action')
        if action not in ('inspect', 'import', 'update', 'assign', 'download', 'archive', 'codex'):
            raise ValueError('Choose an available shared-game operation.')
        if action == 'assign':
            resources, _ = core['_resource_inventory'](include_cloudpcs=False)
            candidates = [r for r in resources if r['hostId'] == host_id and r['name'] == payload.get('vmName')]
            if len(candidates) != 1:
                raise ValueError('Choose a VM belonging to this host.')
            ids = payload.get('gameIds')
            if not isinstance(ids, list) or len(ids) > 100 or any(not isinstance(x, str) for x in ids):
                raise ValueError('Supply a list of game IDs.')
            username, password = core['_default_guest_credentials']() or ('', '')
            if not username or not password:
                raise ValueError('Configure the gaming guest operator credentials before applying games.')
            payload = {**payload, 'guestCredential': {'username': username, 'password': password}}
        return jsonify(proxy(host_id, 'POST', '/jobs', payload)), 202

    @app.post('/EpicVM/api/management/games/upload')
    @guard(admin=True)
    def games_upload():
        payload = data()
        if len(str(payload.get('chunk', ''))) > 524288:
            raise ValueError('Upload chunk exceeds the limit.')
        return jsonify(proxy(str(payload.get('hostId', 'epic-pc')), 'POST', '/upload', payload))

    @app.get('/EpicVM/api/management/games/jobs/<job_id>')
    @guard(admin=True)
    def games_job_status(job_id):
        return jsonify(proxy(request.args.get('hostId', 'epic-pc'), 'GET', '/jobs/' + quote(job_id, safe='')))

    @app.get('/EpicVM/api/account/games')
    @guard()
    def account_games():
        who = g.account_actor
        if who['accountStatus'] != 'approved':
            return jsonify(ok=False, error='Account approval required.'), 403
        user = core['_get_user_by_username'](who['username']) if who['realm'] == 'portal' else None
        grants = user.get('assignedResources', []) if user else []
        resources, _ = core['_resource_inventory'](include_cloudpcs=False)
        allowed = {r['resourceKey'] for r in grants if r.get('resourceType') == 'vm'}
        cache, machines = {}, []
        for vm in resources:
            if vm['resourceKey'] not in allowed and not who['isAdmin']:
                continue
            if vm['hostId'] == 'local':
                continue
            host_id = vm['hostId']
            if host_id not in cache:
                try:
                    cache[host_id] = proxy(host_id, 'GET', '')
                except ValueError:
                    cache[host_id] = None
            library = cache[host_id]
            ids = (library or {}).get('assignments', {}).get(vm['name'], {}).get('gameIds', [])
            games = [{k: game.get(k) for k in ('id', 'title', 'available', 'updatedAt')}
                     for game in (library or {}).get('games', []) if game['id'] in ids]
            machines.append({'resourceKey': vm['resourceKey'], 'name': vm['name'], 'hostId': host_id,
                             'games': games, 'available': library is not None})
        return jsonify(ok=True, machines=machines)
