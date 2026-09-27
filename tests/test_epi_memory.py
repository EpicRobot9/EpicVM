from pathlib import Path

from dashboard.epi_agent import MODEL, SlidingWindowLimiter, TOOLS
from memory_engine import JevMemoryEngine, MemoryStore


class FakeMemoryEngine(JevMemoryEngine):
    def __init__(self, store, answers):
        super().__init__(store, api_key='test')
        self.answers = answers

    def _request(self, state, questions):
        assert set(questions) == {'worth_keeping', 'exact_words', 'where_fits', 'out_of_date', 'reminds_of'}
        assert 'new_message' in state and 'existing_memories' in state
        return self.answers


def answers(*, exact='span_0', placement='root:preference', outdated='none', reminded='none', worth=.98):
    return {
        'worth_keeping': {'noul': worth},
        'exact_words': {'choice': exact, 'confidence': .97},
        'where_fits': {'choice': placement, 'confidence': .94},
        'out_of_date': {'choice': outdated, 'confidence': .96},
        'reminds_of': {'choice': reminded, 'confidence': .91},
    }


def test_memories_are_owner_and_namespace_isolated(tmp_path):
    store = MemoryStore(str(tmp_path / 'memory.sqlite3'), 'secret')
    store.remember('app-a', 'alice', 'Alice likes compact replies.', 'preference')
    store.remember('app-a', 'bob', 'Bob likes detailed replies.', 'preference')
    store.remember('app-b', 'alice', 'Other application memory.', 'project')
    assert [m['exact_text'] for m in store.list('app-a', 'alice')] == ['Alice likes compact replies.']
    assert [m['exact_text'] for m in store.list('app-a', 'bob')] == ['Bob likes detailed replies.']
    assert [m['exact_text'] for m in store.list('app-b', 'alice')] == ['Other application memory.']


def test_jev_keeps_only_an_exact_message_span(tmp_path):
    store = MemoryStore(str(tmp_path / 'memory.sqlite3'), 'secret')
    result = FakeMemoryEngine(store, answers()).process_message('app', 'alice', 'I prefer concise answers. This is temporary.')
    assert result.kept is True
    assert result.exact_text == 'I prefer concise answers.'
    assert result.exact_text in 'I prefer concise answers. This is temporary.'
    assert store.list('app', 'alice')[0]['exact_text'] == 'I prefer concise answers.'


def test_outdated_memory_can_only_target_same_owner(tmp_path):
    store = MemoryStore(str(tmp_path / 'memory.sqlite3'), 'secret')
    old = store.remember('app', 'alice', 'My preferred VM is alpha.', 'environment')
    foreign = store.remember('app', 'bob', 'My preferred VM is beta.', 'environment')
    result = FakeMemoryEngine(store, answers(placement='root:environment', outdated=foreign)).process_message('app', 'alice', 'My preferred VM is gamma.')
    assert result.outdated_id is None
    assert {m['id'] for m in store.list('app', 'alice')} == {old, result.memory_id}
    assert store.list('app', 'bob')[0]['id'] == foreign


def test_forget_and_clear_do_not_cross_owner_boundary(tmp_path):
    store = MemoryStore(str(tmp_path / 'memory.sqlite3'), 'secret')
    alice = store.remember('app', 'alice', 'Alice memory.', 'identity')
    bob = store.remember('app', 'bob', 'Bob memory.', 'identity')
    assert store.forget('app', 'alice', bob) is False
    store.clear('app', 'alice')
    assert store.list('app', 'alice') == []
    assert store.list('app', 'bob')[0]['id'] == bob


def test_memory_tree_uses_owner_scoped_parent(tmp_path):
    store = MemoryStore(str(tmp_path / 'memory.sqlite3'), 'secret')
    wedding = store.remember('app', 'alice', 'My wedding is next spring.', 'project')
    foreign = store.remember('app', 'bob', 'Bob has a wedding.', 'project')
    child = FakeMemoryEngine(store, answers(placement=wedding)).process_message('app', 'alice', 'The wedding is in Tuscany.')
    assert child.parent_id == wedding
    assert [item['id'] for item in store.path('app', 'alice', child.memory_id)] == [wedding, child.memory_id]
    rejected = store.remember('app', 'alice', 'A detail.', 'project', parent_id=foreign)
    assert store.list('app', 'alice')[0]['id'] == rejected
    assert store.list('app', 'alice')[0]['parent_id'] is None


def test_recall_happens_even_when_new_message_is_not_kept(tmp_path):
    store = MemoryStore(str(tmp_path / 'memory.sqlite3'), 'secret')
    speech = store.remember('app', 'alice', 'I need to write the wedding speech.', 'project')
    result = FakeMemoryEngine(store, answers(exact='none', placement='none', reminded=speech, worth=.05)).process_message(
        'app', 'alice', 'I still have not written it.')
    assert result.kept is False
    assert result.reminded_id == speech
    assert [item['id'] for item in result.recalled_path] == [speech]
    recalled = next(item for item in store.list('app', 'alice') if item['id'] == speech)
    assert recalled['recall_count'] == 1 and recalled['last_recalled_at'] is not None


def test_superseded_memory_stays_crossed_out_in_history(tmp_path):
    store = MemoryStore(str(tmp_path / 'memory.sqlite3'), 'secret')
    old = store.remember('app', 'alice', 'The wedding is in Tuscany.', 'project')
    result = FakeMemoryEngine(store, answers(placement=old, outdated=old)).process_message('app', 'alice', 'They moved the wedding to Lisbon.')
    assert result.parent_id is None
    assert old not in {item['id'] for item in store.list('app', 'alice')}
    history = {item['id']: item for item in store.list('app', 'alice', active_only=False)}
    assert history[old]['state'] == 'outdated'
    assert history[result.memory_id]['state'] == 'active'


def test_duplicate_exact_memory_does_not_grow_tree(tmp_path):
    store = MemoryStore(str(tmp_path / 'memory.sqlite3'), 'secret')
    existing = store.remember('app', 'alice', 'My best friend is moving to Japan.', 'relationship')
    result = FakeMemoryEngine(store, answers(placement='root:relationship')).process_message('app', 'alice', 'My best friend is moving to Japan.')
    assert result.memory_id == existing
    assert len(store.list('app', 'alice')) == 1


def test_epi_uses_requested_model_and_bounded_support_tools():
    assert MODEL == 'z-ai/glm-5.3-flash'
    names = {tool['function']['name'] for tool in TOOLS}
    assert names == {'list_machines', 'machine_status', 'power_action', 'basic_recovery', 'notify_admin'}
    assert not names.intersection({'shell', 'delete_machine', 'edit_code', 'mass_refactor'})


def test_sliding_window_limiter_rejects_excess_requests():
    limiter = SlidingWindowLimiter()
    assert limiter.claim(('chat', 'alice'), 2, 60)[0] is True
    assert limiter.claim(('chat', 'alice'), 2, 60)[0] is True
    allowed, retry = limiter.claim(('chat', 'alice'), 2, 60)
    assert allowed is False and retry > 0
    assert limiter.claim(('chat', 'bob'), 2, 60)[0] is True
