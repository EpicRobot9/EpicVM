"""Bounded, read-only Jev judgments for EpicVM operator workflows."""
import json
import os
import urllib.error
import urllib.request


class JevUnavailable(RuntimeError):
    pass


TASKS = {
    'ticket_triage': {
        'area': {'type': 'choice', 'instructions': 'Which EpicVM product area best matches this ticket?', 'criteria': {
            'account': 'Accounts, sign-in, approval, settings, or access grants.',
            'provisioning': 'Creating or configuring a VM.', 'console_streaming': 'Console, Moonlight, Sunshine, video, input, or audio.',
            'shared_games': 'Game catalog, assignment, import, update, or launch.', 'host': 'Hyper-V or remote host availability and capacity.',
            'portal': 'Portal UI or general machine management.', 'other': 'No listed area is a good match.'}},
        'impact': {'type': 'score', 'instructions': 'Rate user impact.', 'criteria': ['Cosmetic or suggestion', 'Degraded but usable', 'Primary task blocked', 'Broad outage or severe data/security concern']},
        'needs_information': {'type': 'noul', 'instructions': 'Is material information missing for an administrator to act?', 'criteria': {'true': 'Important reproduction, machine, timing, or desired-state information is missing.', 'false': 'The report is actionable as written.'}},
    },
    'vm_request': {
        'profile': {'type': 'choice', 'instructions': 'Which available EpicVM profile best fits the stated workload?', 'criteria': {
            'standard': 'General Linux/server/development work without dedicated GPU needs.', 'gaming': 'Windows gaming or GPU-accelerated Windows work.',
            'omarchy': 'Explicit Omarchy Linux or experimental Linux GPU-P work.', 'unclear': 'The request lacks enough evidence.'}},
        'sufficiency': {'type': 'score', 'instructions': 'How complete is the request for a human administrator?', 'criteria': ['Too vague to size', 'Some useful intent but important details missing', 'Enough information for a human recommendation', 'Specific workload and resource needs']},
        'needs_clarification': {'type': 'noul', 'instructions': 'Should an administrator ask a clarifying question before choosing resources?'},
    },
    'log_triage': {
        'category': {'type': 'choice', 'instructions': 'What is the dominant operational issue in these EpicVM logs?', 'criteria': {
            'normal_noise': 'Routine successful or non-actionable output.', 'provisioning': 'VM cloning, bootstrap, setup, or readiness failure.',
            'transport': 'WinRM, PowerShell Direct, Tailscale, SSH, or network transport.', 'streaming': 'Sunshine, Moonlight, RTSP, WebRTC, video, input, or audio.',
            'gpu': 'GPU-P, driver, encoder, WebGL, or rendered-frame validation.', 'auth': 'Authentication, authorization, CSRF, or credential rejection.',
            'storage': 'Disk, image, archive, filesystem, or capacity issue.', 'unknown': 'No category is adequately supported.'}},
        'severity': {'type': 'score', 'instructions': 'Rate operational severity.', 'criteria': ['Informational', 'Warning to monitor', 'Single workflow blocked', 'Repeated or broad service failure']},
        'operator_attention': {'type': 'noul', 'instructions': 'Does this evidence warrant operator attention now?'},
    },
    'provisioning_diagnosis': {
        'next_step': {'type': 'choice', 'instructions': 'Which investigation should be suggested next? Do not claim readiness or authorize recovery.', 'criteria': {
            'inspect_guest_transport': 'Inspect the secure guest management transport.', 'inspect_network': 'Inspect Tailscale, SSH, WinRM, listeners, or routing.',
            'inspect_streaming': 'Inspect Sunshine, Moonlight, encoder, capture, input, or audio.', 'inspect_gpu': 'Inspect GPU-P, driver, encoder, WebGL, or rendered-frame evidence.',
            'inspect_host': 'Inspect host capabilities, templates, capacity, or services.', 'review_credentials': 'Have an authorized operator review credential input without exposing it.',
            'collect_more_evidence': 'The supplied evidence is insufficient or conflicting.'}},
        'evidence_quality': {'type': 'score', 'instructions': 'How sufficient is the evidence for choosing a diagnostic direction?', 'criteria': ['Insufficient', 'Weak', 'Useful', 'Strong and mutually consistent']},
    },
    'host_ranking': {},
    'game_screening': {
        'family': {'type': 'choice', 'instructions': 'Which known deterministic importer family is the strongest candidate for this folder evidence?', 'criteria': {
            'openfl': 'OpenFL-style distribution.', 'publisher_pkg': 'Publisher package-version distribution.', 'unreal': 'Packaged Unreal Engine game.',
            'qt_cef_launcher': 'Versioned Qt or CEF launcher payload.', 'portable_archive': 'Self-contained portable distribution suitable for archive import.',
            'unsupported': 'No supported family is sufficiently evidenced.'}},
        'safe_to_inspect': {'type': 'noul', 'instructions': 'Is there enough non-secret structural evidence to try a deterministic read-only inspection?',
                            'criteria': {'true': 'A known layout is plausibly represented.', 'false': 'Evidence is unsupported, ambiguous, or appears dominated by user/account state.'}},
    },
    'notification_priority': {
        'priority': {'type': 'score', 'instructions': 'How prominently should this operator notification be shown?', 'criteria': ['Background information', 'Normal notification', 'Important warning', 'Immediate operator attention']},
        'duplicate': {'type': 'noul', 'instructions': 'Does this appear semantically duplicative of another notification in the supplied state?'},
    },
    'response_verification': {
        'addresses_request': {'type': 'noul', 'instructions': 'Does the proposed administrator response directly address the ticket?'},
        'unsupported_claim': {'type': 'noul', 'instructions': 'Does the response claim an outcome not supported by the supplied ticket and evidence?'},
    },
    'browser_verification': {
        'outcome': {'type': 'choice', 'instructions': 'Does the observed browser state satisfy the stated EpicVM journey goal?', 'criteria': {
            'pass': 'Visible state clearly satisfies the goal.', 'fail': 'Visible state contradicts or fails the goal.',
            'insufficient_evidence': 'The observation does not establish the outcome.'}},
        'clarity': {'type': 'score', 'instructions': 'How clearly does the UI communicate the current state and next action?', 'criteria': ['Confusing', 'Partly understandable', 'Clear', 'Exceptionally clear']},
    },
}


def task_questions(task, state):
    if task == 'host_ranking':
        hosts = state.get('hosts') if isinstance(state, dict) else None
        if not isinstance(hosts, list) or not hosts or len(hosts) > 32:
            raise ValueError('Host ranking requires 1 to 32 deterministic eligible hosts.')
        criteria = {}
        for host in hosts:
            host_id = str(host.get('id') or '').strip()
            if not host_id or host_id in criteria:
                raise ValueError('Each eligible host needs a unique id.')
            criteria[host_id] = f"Choose this host when its fresh resources and capabilities best fit the workload. Evidence: {json.dumps(host, separators=(',', ':'))[:1200]}"
        criteria['no_recommendation'] = 'The supplied evidence is insufficient to prefer one eligible host.'
        return {'host': {'type': 'choice', 'instructions': 'Rank only the already eligible hosts for the described workload. Never decide eligibility.', 'criteria': criteria}}
    return TASKS[task]


def configured():
    return bool(_api_key())


def _api_key():
    key = os.environ.get('TYPESAFE_API_KEY', '').strip()
    if key:
        return key
    # The production container bind-mounts this root. Reading the protected
    # env file lets a normal container restart pick up this optional service
    # without recreating the dashboard or exposing the credential client-side.
    try:
        with open('/opt/blobe-vm/.env', encoding='utf-8') as handle:
            for line in handle:
                if line.startswith('TYPESAFE_API_KEY='):
                    return line.split('=', 1)[1].strip()
    except OSError:
        pass
    return ''


def analyze(task, state):
    if task not in TASKS:
        raise ValueError('Unknown Jev advisory task.')
    encoded_state = json.dumps(state, ensure_ascii=False, separators=(',', ':'))
    if len(encoded_state.encode('utf-8')) > 48000:
        raise ValueError('Jev advisory state is too large.')
    key = _api_key()
    if not key:
        raise JevUnavailable('Jev is not configured on this server.')
    payload = json.dumps({'state': state, 'model': os.environ.get('TYPESAFE_MODEL', 'jev-latest'),
                          'questions': task_questions(task, state)}).encode()
    req = urllib.request.Request(os.environ.get('TYPESAFE_API_URL', 'https://api.typesafe.ai/v1/systemone'), data=payload,
                                 headers={'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'}, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=float(os.environ.get('TYPESAFE_TIMEOUT_SECONDS', '10'))) as response:
            result = json.loads(response.read().decode())
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        raise JevUnavailable('Jev advisory service is temporarily unavailable.') from exc
    answers = result.get('answers')
    if not isinstance(answers, dict):
        raise JevUnavailable('Jev returned an invalid advisory response.')
    return {'task': task, 'model': result.get('model', ''), 'answers': answers, 'usage': result.get('usage', {})}
