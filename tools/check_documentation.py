"""Check repository Markdown file targets and selected immutable report hashes."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]


def main():
    files = subprocess.check_output(
        ['git', '-c', f'safe.directory={ROOT.as_posix()}', 'ls-files',
         '--cached', '--others', '--exclude-standard'], cwd=ROOT, text=True).splitlines()
    failures = []
    checked = 0
    for name in sorted(set(files)):
        path = ROOT / name
        if path.suffix != '.md' or not path.is_file():
            continue
        checked += 1
        for line_no, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            for target in re.findall(r'\]\(([^)]+)\)', line):
                target = target.strip('<>').split('#')[0]
                if not target or re.match(r'[a-zA-Z]+:', target):
                    continue
                destination = (path.parent / unquote(target)).resolve()
                if not destination.exists():
                    failures.append(f'{name}:{line_no}: missing target {target}')
    archive = ROOT/'docs/reports/current_build_20261104'
    manifest = json.loads((archive/'archive_manifest.json').read_text(encoding='utf-8'))
    for name, expected in manifest.items():
        path = archive/name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            failures.append(f'Archived evidence changed: {path.relative_to(ROOT)}')
    if failures:
        print('\n'.join(failures),file=sys.stderr)
        return 1
    print(f'PASS: file targets in {checked} Markdown documents; {len(manifest)} archived evidence hashes')
    print('Scope: file targets only; heading anchors, external URLs and prose accuracy require review.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
