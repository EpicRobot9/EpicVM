import json

import pytest

from dashboard import jev_advisor


class FakeResponse:
    def __init__(self, body):
        self.body = json.dumps(body).encode()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return self.body


@pytest.mark.parametrize('task', sorted(jev_advisor.TASKS))
def test_all_advisory_tasks_have_bounded_questions(task):
    state = {'hosts': [{'id': 'eligible-a', 'online': True}]} if task == 'host_ranking' else {'text': 'fixture evidence'}
    questions = jev_advisor.task_questions(task, state)
    assert questions
    assert all(question['type'] in ('choice', 'score', 'noul') for question in questions.values())


def test_analyze_uses_server_key_and_normalizes_response(monkeypatch):
    captured = {}
    monkeypatch.setenv('TYPESAFE_API_KEY', 'fixture-secret')

    def fake_open(request, timeout):
        captured['authorization'] = request.headers['Authorization']
        captured['payload'] = json.loads(request.data)
        captured['timeout'] = timeout
        return FakeResponse({'model': 'jev-fixture', 'answers': {'category': {'type': 'choice', 'choice': 'gpu', 'confidence': .9}}, 'usage': {'input_tokens': 1, 'output_tokens': 1}})

    monkeypatch.setattr(jev_advisor.urllib.request, 'urlopen', fake_open)
    result = jev_advisor.analyze('log_triage', {'logs': 'encoder failed'})
    assert result['answers']['category']['choice'] == 'gpu'
    assert captured['authorization'] == 'Bearer fixture-secret'
    assert captured['payload']['model'] == 'jev-latest'
    assert 'fixture-secret' not in json.dumps(captured['payload'])


def test_analyze_fails_closed_when_unconfigured(monkeypatch):
    monkeypatch.delenv('TYPESAFE_API_KEY', raising=False)
    with pytest.raises(jev_advisor.JevUnavailable, match='not configured'):
        jev_advisor.analyze('ticket_triage', {'title': 'help'})


def test_host_ranking_only_accepts_explicit_unique_candidates():
    with pytest.raises(ValueError):
        jev_advisor.task_questions('host_ranking', {'hosts': []})
    with pytest.raises(ValueError):
        jev_advisor.task_questions('host_ranking', {'hosts': [{'id': 'a'}, {'id': 'a'}]})
    questions = jev_advisor.task_questions('host_ranking', {'hosts': [{'id': 'a'}, {'id': 'b'}]})
    assert set(questions['host']['criteria']) == {'a', 'b', 'no_recommendation'}


def test_state_size_is_bounded(monkeypatch):
    monkeypatch.setenv('TYPESAFE_API_KEY', 'fixture-secret')
    with pytest.raises(ValueError, match='too large'):
        jev_advisor.analyze('browser_verification', {'text': 'x' * 50000})

