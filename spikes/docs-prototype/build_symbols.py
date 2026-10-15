"""Extract symbol graphs for selected SDK modules and compact them into symbols.db."""
import json, os, glob, sqlite3, subprocess, sys, time, shutil
D = os.path.dirname(os.path.abspath(__file__))
MODULES = sys.argv[1:] or ['SwiftUI', 'UIKit', 'Foundation', 'AVFoundation', 'Observation', 'SwiftData']
SDK = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
TARGET = 'arm64-apple-ios27.0-simulator'
DB = os.path.join(D, 'symbols.db')
if os.path.exists(DB): os.remove(DB)
con = sqlite3.connect(DB)
con.execute('''CREATE TABLE symbols(module TEXT, path TEXT, kind TEXT, declaration TEXT, doc TEXT, availability TEXT,
               precise TEXT, UNIQUE(module, precise))''')
con.execute('CREATE INDEX sym_path ON symbols(module, path COLLATE NOCASE)')
report = []
for m in MODULES:
    out = os.path.join(D, 'symgraphs', m); shutil.rmtree(out, ignore_errors=True); os.makedirs(out)
    t0 = time.time()
    p = subprocess.run(['xcrun', 'swift-symbolgraph-extract', '-module-name', m, '-target', TARGET, '-sdk', SDK,
                        '-output-dir', out, '-minimum-access-level', 'public'], capture_output=True, text=True)
    dt = time.time() - t0
    files = glob.glob(os.path.join(out, '*.symbols.json'))
    raw = sum(os.path.getsize(f) for f in files)
    if p.returncode != 0 or not files:
        report.append(dict(module=m, ok=False, seconds=round(dt, 1), error=(p.stderr or '')[-300:])); continue
    n = 0
    for f in files:
        g = json.load(open(f))
        rows = []
        for s in g['symbols']:
            decl = ''.join(x['spelling'] for x in s.get('declarationFragments', []))
            doc = '\n'.join(l['text'] for l in (s.get('docComment') or {}).get('lines', []))
            rows.append((m, '.'.join(s['pathComponents']), s['kind']['displayName'], decl, doc,
                         json.dumps(s.get('availability') or []), s['identifier']['precise']))
        con.executemany('INSERT OR IGNORE INTO symbols VALUES (?,?,?,?,?,?,?)', rows); n += len(rows)
    con.commit()
    report.append(dict(module=m, ok=True, seconds=round(dt, 1), raw_mb=round(raw / 1e6, 1), files=len(files), symbols=n))
    shutil.rmtree(out)  # raw graphs are huge; keep only the compacted DB
    print(report[-1], flush=True)
con.execute('VACUUM'); con.close()
json.dump(report, open(os.path.join(D, 'symbols_report.json'), 'w'), indent=1)
print('failed:', [r for r in report if not r['ok']])
print(f'symbols.db = {os.path.getsize(DB)/1e6:.1f} MB')
