"""Jev-powered five-question memory reflection with verbatim span storage."""
from __future__ import annotations

from dataclasses import asdict, dataclass
import json
import os
import re
import urllib.error
import urllib.request


class MemoryUnavailable(RuntimeError):
    pass


@dataclass
class MemoryDecision:
    kept: bool = False
    memory_id: str | None = None
    exact_text: str | None = None
    category: str | None = None
    outdated_id: str | None = None
    reminded_id: str | None = None
    parent_id: str | None = None
    recalled_path: list | None = None
    raw_answers: dict | None = None

    def to_dict(self):
        return asdict(self)


def _chunks(message: str, limit=16):
    candidates = []
    for match in re.finditer(r'[^\n.!?;]+(?:[.!?;]+|$)', message):
        value = match.group(0).strip()
        if 2 <= len(value) <= 800 and value not in candidates:
            candidates.append(value)
    whole = message.strip()
    if whole and whole not in candidates and len(whole) <= 1200:
        candidates.append(whole)
    return candidates[:limit]


class JevMemoryEngine:
    CATEGORIES = {
        'identity': 'Stable facts about who the user is.',
        'preference': 'How the user likes things done, presented, or communicated.',
        'project': 'A durable project goal, decision, constraint, or responsibility.',
        'environment': 'A durable fact about the user’s machines, services, or setup.',
        'relationship': 'A durable fact about people, teams, or ownership relationships.',
        'temporary': 'Useful only for the current conversation or immediate task.',
        'none': 'No durable memory category fits.',
    }

    def __init__(self, store, *, api_key=None, model='jev-latest', api_url='https://api.typesafe.ai/v1/systemone', timeout=10):
        self.store = store
        self.api_key = (api_key or os.environ.get('TYPESAFE_API_KEY', '')).strip()
        self.model, self.api_url, self.timeout = model, api_url, timeout

    def _request(self, state, questions):
        if not self.api_key:
            raise MemoryUnavailable('Jev memory reflection is not configured.')
        payload = json.dumps({'state': state, 'model': self.model, 'questions': questions}).encode('utf-8')
        request = urllib.request.Request(self.api_url, data=payload, method='POST', headers={
            'Authorization': f'Bearer {self.api_key}', 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                body = json.loads(response.read().decode('utf-8'))
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            raise MemoryUnavailable('Jev memory reflection is temporarily unavailable.') from exc
        if not isinstance(body.get('answers'), dict):
            raise MemoryUnavailable('Jev returned an invalid memory reflection.')
        return body['answers']

    def process_message(self, namespace: str, owner_id: str, message: str, *, message_id=None):
        if not isinstance(message, str) or not message.strip() or len(message) > 12000:
            raise ValueError('Message must contain 1 to 12000 characters.')
        memories = self.store.list(namespace, owner_id, limit=120)
        spans = _chunks(message)
        span_options = {f'span_{i}': f'Verbatim candidate: {span}' for i, span in enumerate(spans)}
        span_options['none'] = 'No candidate is worth storing verbatim.'
        memory_options = {item['id']: f"{item['category']}: {item['exact_text'][:300]}" for item in memories}
        memory_options.update({'none': 'No existing memory matches.', 'unclear': 'There is not enough evidence to decide.'})
        placement_options = {f'root:{key}': value for key, value in self.CATEGORIES.items() if key not in ('temporary', 'none')}
        placement_options.update({item['id']: f"Place beneath this existing memory: {item['exact_text'][:300]}" for item in memories})
        placement_options.update({'root:temporary': 'Useful only for the current conversation.', 'none': 'No durable location fits.'})
        state = {'new_message': message, 'verbatim_candidates': {f'span_{i}': value for i, value in enumerate(spans)},
                 'existing_memories': [{'id': item['id'], 'category': item['category'], 'text': item['exact_text']} for item in memories]}
        questions = {
            'worth_keeping': {'type': 'noul', 'instructions': 'Is the new message worth retaining as durable knowledge about the user beyond this conversation?',
                              'criteria': {'true': 'It is about the user and contains a stable fact, preference, project constraint, relationship, future expectation, or environment detail she would reasonably expect to be known later.', 'false': 'It is merely about the outside world, transient context such as weather, procedural chatter, a secret, or useful only now.'}},
            'exact_words': {'type': 'choice', 'instructions': 'Which candidate contains the exact words that best preserve the durable memory without paraphrasing?', 'criteria': span_options},
            'where_fits': {'type': 'choice', 'instructions': 'Where in the user memory tree should this message hang? Choose the most specific existing parent when one clearly fits; otherwise choose a root.', 'criteria': placement_options},
            'out_of_date': {'type': 'choice', 'instructions': 'Does the new message make exactly one existing memory out of date?', 'criteria': memory_options},
            'reminds_of': {'type': 'choice', 'instructions': 'Which existing memory is most meaningfully related to the new message?', 'criteria': memory_options},
        }
        answers = self._request(state, questions)
        keep_probability = float((answers.get('worth_keeping') or {}).get('noul') or 0)
        exact = (answers.get('exact_words') or {}).get('choice', 'none')
        placement_answer = answers.get('where_fits') or {}
        placement = placement_answer.get('choice', 'none') if float(placement_answer.get('confidence') or 0) >= .45 else 'none'
        outdated_answer = answers.get('out_of_date') or {}
        reminded_answer = answers.get('reminds_of') or {}
        outdated = outdated_answer.get('choice') if float(outdated_answer.get('confidence') or 0) >= .7 else None
        reminded = reminded_answer.get('choice') if float(reminded_answer.get('confidence') or 0) >= .55 else None
        valid_ids = {item['id'] for item in memories}
        outdated = outdated if outdated in valid_ids else None
        reminded = reminded if reminded in valid_ids else None
        recalled_path = self.store.path(namespace, owner_id, reminded) if reminded else []
        if reminded:
            self.store.record_recall(namespace, owner_id, reminded, source_message_id=message_id)
        by_id = {item['id']: item for item in memories}
        parent_id = placement if placement in valid_ids else None
        category = by_id[parent_id]['category'] if parent_id else (placement.split(':', 1)[1] if placement.startswith('root:') else 'none')
        if outdated and parent_id == outdated:
            parent_id = by_id[outdated].get('parent_id')
        explicit = bool(re.search(r'\b(remember|keep in mind|don[’\']?t forget)\b', message, re.I))
        kept = (keep_probability >= .62 or explicit) and exact in span_options and exact != 'none' and category not in ('none', 'temporary')
        exact_text = spans[int(exact.split('_')[1])] if kept and exact.startswith('span_') else None
        duplicate = next((item for item in memories if exact_text and item['exact_text'].casefold() == exact_text.casefold()), None)
        memory_id = duplicate['id'] if duplicate else (self.store.remember(
            namespace, owner_id, exact_text, category, source_message_id=message_id,
            supersedes_id=outdated, reminded_by_id=reminded, parent_id=parent_id) if exact_text else None)
        return MemoryDecision(kept=bool(memory_id), memory_id=memory_id, exact_text=exact_text,
                              category=category if memory_id else None, outdated_id=outdated if memory_id else None,
                              reminded_id=reminded, parent_id=parent_id if memory_id else None,
                              recalled_path=recalled_path, raw_answers=answers)
