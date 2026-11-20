"""Folder import regressions against a real ASGI app and disposable Anki (Joplin SSOT mode).

FOLDER_IMPORT_BACKEND can select an isolated release backend checkout.
Never loads operational environment/configuration or uses a real collection.
"""
import asyncio
import os
import sys
from pathlib import Path

from native_fixture import configure, tempdir, run_closed

root = Path(__file__).resolve().parents[1]
backend_path = Path(os.environ.get('FOLDER_IMPORT_BACKEND', root / 'backend'))
os.environ['ANKI_STATE_DIR'] = tempdir('folder-import-state-')
os.environ['ANKI_NOTES_DIR'] = tempdir('folder-import-notes-')
os.environ['ANKI_PREVIEW_MODE'] = '0'
os.environ['ANKI_READING_MODE'] = '1'
configure()
sys.path.insert(0, str(backend_path))
import app as b
import httpx


async def main():
    corpus = b.NOTES_DIR
    eng = b._storage()
    checks = 0
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=b.app), base_url='http://t') as c:
        async def upload(entries, policy='error'):
            return await c.post('/api/files/upload', data={
                'rel_paths': [p for p, _ in entries], 'dir': '2026', 'on_conflict': policy,
            }, files=[('files', (p, data, 'application/octet-stream')) for p, data in entries])

        # Reproduce the user's actual book layout, not just an ordinary images/.
        (corpus / 'old').mkdir()
        (corpus / 'old' / 'a.png').write_bytes(b'existing-image')
        entries = [('金钱心理学/001-正文.md', '# 正文\n![图](_assets/a.png)'.encode()),
                   ('金钱心理学/_assets/a.png', b'new-image'),
                   ('金钱心理学/章节/_assets/b.PNG', b'unreferenced-image')]
        r = await upload(entries)
        assert r.status_code == 200, r.text
        payload = r.json()
        notes = {n['original']: n for n in payload['imported_notes']}
        resources = {x['original']: x for x in payload['imported_resources']}
        assert '金钱心理学/001-正文.md' in notes
        assert '金钱心理学/_assets/a.png' in resources
        # Unreferenced image in mixed folder must NOT pollute resources sandbox
        assert '金钱心理学/章节/_assets/b.PNG' not in resources
        assert any(s['path'] == '金钱心理学/章节/_assets/b.PNG' for s in payload['skipped']), payload['skipped']

        rid = resources['金钱心理学/_assets/a.png']['resource_id']
        note = eng.get_note(notes['金钱心理学/001-正文.md']['note_id'])
        assert note is not None
        assert f'![图](:/{rid})' in note['body'], note['body']
        # StorageEngine SSOT: NOTES_DIR was NOT written to, existing disk image untouched
        assert not (corpus / '2026' / '金钱心理学').exists()
        assert (corpus / 'old/a.png').read_bytes() == b'existing-image'
        # Resource serves cleanly and survives GC (note_resources properly linked)
        assert (await c.get('/api/resources/' + rid)).content == b'new-image'
        assert (await c.get('/api/reading/media/' + rid)).content == b'new-image'
        assert eng.gc_unreferenced_resources() == 0
        checks += 1

        # Management paths remain strictly protected (no _assets loophole in _files_resolve).
        for path in ['_assets/root.png', '2026/金钱心理学/_assets/a.png']:
            try:
                b._files_resolve(path)
            except b.HTTPException as e:
                assert e.status_code == 400
            else:
                raise AssertionError('management path protection lost: ' + path)
        checks += 1

        # Markdown conflicts still preflight atomically without writing new notes or resources.
        notes_before = len(eng.list_notes(include_deleted=False))
        res_before = eng.db.query_one('SELECT COUNT(*) AS c FROM resources')['c']
        r = await upload(entries)
        assert r.status_code == 409, r.text
        assert len(eng.list_notes(include_deleted=False)) == notes_before
        assert eng.db.query_one('SELECT COUNT(*) AS c FROM resources')['c'] == res_before
        for policy in ['skip', 'rename', 'overwrite']:
            r = await upload(entries, policy)
            assert r.status_code == 200, (policy, r.text)
        checks += 1

        # Non-blocking tolerance: system dirs / _assets/*.md / manifest.json are skipped,
        # while safe sibling notes still succeed; path traversal still hard-rejected (400).
        skipped_paths = [
            '_assets/.git/a.png', '.git/a.png', '.obsidian/a.png',
            '书/_assets/node_modules/a.png', '书/_assets/private.md',
            '书/_assets/manifest.json',
        ]
        r = await upload([('安全/容错测试.md', b'# safe')] + [(p, b'content') for p in skipped_paths])
        assert r.status_code == 200, r.text
        skipped_set = {s['path'] for s in r.json()['skipped']}
        for path in skipped_paths:
            assert path in skipped_set, (path, skipped_set)
            checks += 1

        # Path traversal hard-rejected with zero writes
        notes_before = len(eng.list_notes(include_deleted=False))
        r = await upload([('安全/未写入.md', b'# safe'), ('../../outside.png', b'bad')])
        assert r.status_code == 400, r.text
        assert len(eng.list_notes(include_deleted=False)) == notes_before
        checks += 1

        # Import does not silently opt the book into reading.
        assert not b._reading_read()['list']
        checks += 1
    print(f'{checks} folder import regression groups passed; backend={backend_path}')


asyncio.run(run_closed(b, main()))
