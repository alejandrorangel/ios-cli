import json, os, re, sqlite3, sys, time
D = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(D, 'docs.db')
def camel(s):
    s = re.sub(r'[^A-Za-z0-9]+', ' ', s)
    s = re.sub(r'([a-z0-9])([A-Z])', r'\1 \2', s)
    s = re.sub(r'([A-Z]+)([A-Z][a-z])', r'\1 \2', s)
    return s.lower()
t0 = time.time()
if os.path.exists(DB): os.remove(DB)
con = sqlite3.connect(DB)
con.executescript('''
CREATE TABLE docs(id INTEGER PRIMARY KEY, path TEXT UNIQUE, title TEXT, kind TEXT, framework TEXT,
                  lang TEXT, beta INT, deprecated INT, parent TEXT);
CREATE VIRTUAL TABLE fts USING fts5(title, terms, parent, framework, content='', tokenize='porter unicode61');
''')
seen = {}
for f in sorted(os.listdir(os.path.join(D, 'idx'))):
    fw = f[:-5]
    d = json.load(open(os.path.join(D, 'idx', f)))
    for lang in ('swift', 'occ'):
        def walk(nodes, parent):
            for n in nodes or []:
                p = n.get('path'); t = n.get('type')
                if p and t != 'groupMarker' and not n.get('external') and p not in seen:
                    seen[p] = (p, n['title'], t, p.split('/')[2] if p.count('/') >= 2 else fw, lang,
                               int(bool(n.get('beta'))), int(bool(n.get('deprecated'))), parent)
                walk(n.get('children'), n['title'] if p else parent)
        walk(d['interfaceLanguages'].get(lang, []), '')
rows = list(seen.values())
con.executemany('INSERT INTO docs(path,title,kind,framework,lang,beta,deprecated,parent) VALUES (?,?,?,?,?,?,?,?)', rows)
cur = con.execute('SELECT id,title,path,parent,framework FROM docs')
con.executemany('INSERT INTO fts(rowid,title,terms,parent,framework) VALUES (?,?,?,?,?)',
    [(i, t, camel(t) + ' ' + camel(p.split('/')[-1]), camel(par), camel(fw)) for i, t, p, par, fw in cur.fetchall()])
con.commit(); con.execute('VACUUM'); con.close()
print(f'rows={len(rows)} build={time.time()-t0:.1f}s size={os.path.getsize(DB)/1e6:.1f}MB')
