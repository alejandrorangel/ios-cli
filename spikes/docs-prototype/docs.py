#!/usr/bin/env python3
"""Prototype of `ios docs` — search / fetch / api.

  docs.py search <query> [--framework swiftui] [--kind struct] [--limit 10] [--json]
  docs.py fetch  <doc-path | doc://... | https://developer.apple.com/documentation/...>
  docs.py api    <Module.Symbol[.member]> [--limit 5] [--json]

search: local SQLite FTS5 index built from developer.apple.com/tutorials/data/index/* (build_index.py)
fetch:  live DocC render JSON -> markdown
api:    offline SQLite built from swift-symbolgraph-extract output for the installed SDK (build_symbols.py)
"""
import argparse, json, os, re, sqlite3, sys, time, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DOCS_DB = os.path.join(HERE, 'docs.db')
SYM_DB = os.path.join(HERE, 'symbols.db')
UA = {'User-Agent': 'ios-cli-docs-spike/0.1 (feasibility research)'}

KIND_BOOST = {'article': 2.0, 'collection': 1.5, 'sampleCode': 1.5, 'tutorial': 1.0, 'struct': 1.5, 'class': 1.5,
              'protocol': 1.5, 'module': 2.0, 'framework': 2.0, 'enum': 0.8, 'func': 0.6, 'method': 0.5, 'init': 0.3,
              'property': 0.3, 'var': 0.2, 'case': 0.0, 'typealias': 0.1, 'op': -0.5}


def camel(s):
    s = re.sub(r'[^A-Za-z0-9]+', ' ', s)
    s = re.sub(r'([a-z0-9])([A-Z])', r'\1 \2', s)
    s = re.sub(r'([A-Z]+)([A-Z][a-z])', r'\1 \2', s)
    return s.lower()


# ---------------------------------------------------------------- search
def search(q, framework=None, kind=None, limit=10):
    con = sqlite3.connect(DOCS_DB)
    toks = [t for t in camel(q).split() if t]
    if not toks:
        return []
    # "core bluetooth" / "swift data" -> framework hint (ids are lowercase, no separators)
    fws = {r[0] for r in con.execute('SELECT DISTINCT framework FROM docs')}
    hint = None
    for n in (3, 2, 1):
        for i in range(len(toks) - n + 1):
            joined = ''.join(toks[i:i + n])
            if joined in fws and (n > 1 or len(toks) > 1) and not hint:
                hint, toks = joined, toks[:i] + toks[i + n:]
                break
    if hint and not toks:
        toks, hint = [hint], None
    if hint and not framework:
        boosted = search_inner(con, toks, hint, kind, limit)
        if boosted:
            return boosted
    return search_inner(con, toks, framework, kind, limit)


def search_inner(con, toks, framework, kind, limit):
    def run(match):
        sql = '''SELECT d.path, d.title, d.kind, d.framework, d.beta, d.deprecated, d.lang, d.parent,
                        bm25(fts, 10.0, 6.0, 1.5, 3.0) AS score
                 FROM fts JOIN docs d ON d.id = fts.rowid
                 WHERE fts MATCH ? {fw} {kd}
                 ORDER BY score LIMIT 400'''.format(
            fw='AND d.framework = ?' if framework else '', kd='AND d.kind = ?' if kind else '')
        args = [match] + ([framework.lower()] if framework else []) + ([kind] if kind else [])
        return con.execute(sql, args).fetchall()
    rows = run(' AND '.join(f'"{t}"*' for t in toks))
    if len(rows) < limit:  # relax to OR when the strict query is too narrow
        rows += [r for r in run(' OR '.join(f'"{t}"*' for t in toks)) if r not in rows]
    def rerank(r):
        path, title, kd, fw, beta, dep, lang, parent, score = r
        s = -score + KIND_BOOST.get(kd, 0.0)
        s -= 3.0 if dep else 0.0
        s -= 1.0 if lang == 'occ' else 0.0
        s += 1.0 if fw in toks or fw.replace('-', '') in ''.join(toks) else 0.0
        s -= 0.15 * path.count('/')  # prefer shallower pages
        return -s
    rows.sort(key=rerank)
    return [dict(path=r[0], title=r[1], kind=r[2], framework=r[3], beta=bool(r[4]), deprecated=bool(r[5]),
                 language=r[6], parent=r[7]) for r in rows[:limit]]


# ---------------------------------------------------------------- fetch
def doc_path(arg):
    arg = arg.strip()
    if arg.startswith('doc://'):
        arg = '/documentation/' + arg[len('doc://'):]
    arg = re.sub(r'^https?://developer\.apple\.com', '', arg)
    if not arg.startswith('/'):
        arg = '/documentation/' + arg
    return arg.rstrip('/').lower()


def fetch_json(path):
    url = 'https://developer.apple.com/tutorials/data' + urllib.parse.quote(path) + '.json'
    return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30))


def to_markdown(d):
    refs = d.get('references', {})

    def ref_title(ident):
        r = refs.get(ident, {})
        return r.get('title') or ident.rsplit('/', 1)[-1]

    def inline(xs):
        out = ''
        for x in xs or []:
            t = x.get('type')
            if t == 'text': out += x['text']
            elif t == 'codeVoice': out += f"`{x['code']}`"
            elif t == 'emphasis': out += f"*{inline(x.get('inlineContent'))}*"
            elif t == 'strong': out += f"**{inline(x.get('inlineContent'))}**"
            elif t == 'newTerm': out += f"*{inline(x.get('inlineContent'))}*"
            elif t == 'link': out += f"[{x.get('title') or x.get('destination')}]({x.get('destination')})"
            elif t == 'reference':
                r = refs.get(x['identifier'], {})
                title = inline(x.get('overridingTitleInlineContent')) or r.get('title') or ref_title(x['identifier'])
                url = r.get('url', '')
                if r.get('type') == 'link':
                    out += f'[{title}]({url})'
                elif url.startswith('/documentation/'):
                    out += f"[`{title}`](doc://{url[len('/documentation/'):]})"
                else:
                    out += f'`{title}`'
            elif t == 'image': out += f"![{x.get('identifier')}]"
            elif t in ('superscript', 'subscript', 'strikethrough'): out += inline(x.get('inlineContent'))
            elif 'inlineContent' in x: out += inline(x['inlineContent'])
        return out

    def blocks(bs, depth=0):
        out = []
        for b in bs or []:
            t = b.get('type')
            if t == 'heading':
                out.append('#' * min(b.get('level', 2) + 1, 6) + ' ' + b['text'])
            elif t == 'paragraph':
                out.append(inline(b['inlineContent']))
            elif t == 'codeListing':
                out.append(f"```{b.get('syntax') or ''}\n" + '\n'.join(b.get('code', [])) + '\n```')
            elif t == 'aside':
                body = '\n'.join(blocks(b.get('content'), depth))
                out.append('\n'.join(f'> {l}' if i else f"> **{b.get('name') or b.get('style', 'Note').title()}:** {l}"
                                     for i, l in enumerate(body.splitlines() or [''])))
            elif t in ('unorderedList', 'orderedList'):
                for i, it in enumerate(b.get('items', []), 1):
                    bullet = f'{i}.' if t == 'orderedList' else '-'
                    body = ' '.join(blocks(it.get('content'), depth + 1))
                    out.append('  ' * depth + f'{bullet} {body}')
            elif t == 'termList':
                for it in b.get('items', []):
                    out.append(f"- **{inline(it['term']['inlineContent'])}**: " + ' '.join(blocks(it['definition']['content'])))
            elif t == 'table':
                rows = b.get('rows', [])
                cells = [[' '.join(blocks(c)).replace('|', '\\|') for c in r] for r in rows]
                if cells:
                    lines = ['| ' + ' | '.join(cells[0]) + ' |', '|' + '---|' * len(cells[0])]
                    lines += ['| ' + ' | '.join(r) + ' |' for r in cells[1:]]
                    out.append('\n'.join(lines))
            elif t == 'links':
                out += [f'- {inline([{"type": "reference", "identifier": i}])}' for i in b.get('items', [])]
            elif t in ('row', 'tabNavigator'):
                for col in b.get('columns', []) or b.get('tabs', []):
                    out += blocks(col.get('content'), depth)
            elif t == 'small':
                out.append(inline(b.get('inlineContent')))
            elif 'content' in b:
                out += blocks(b['content'], depth)
        return out

    m = d.get('metadata', {})
    md = [f"# {m.get('title', '')}"]
    sub = [m.get('roleHeading'), m.get('modules', [{}])[0].get('name') if m.get('modules') else None]
    if any(sub): md.append(' · '.join(s for s in sub if s))
    plats = m.get('platforms') or []
    if plats:
        md.append('**Availability:** ' + ', '.join(
            (f"{p['name']} {p['introducedAt']}+" if p.get('introducedAt') else p['name']) + (' (beta)' if p.get('beta') else '') +
            (f" (deprecated {p['deprecatedAt']})" if p.get('deprecatedAt') else '') for p in plats))
    if d.get('abstract'): md.append(inline(d['abstract']))
    for s in d.get('primaryContentSections', []):
        k = s.get('kind')
        if k == 'declarations':
            for dec in s['declarations']:
                md.append('```swift\n' + ''.join(t['text'] for t in dec['tokens']).strip() + '\n```')
        elif k == 'parameters':
            md.append('## Parameters')
            md += [f"- `{p['name']}`: " + ' '.join(blocks(p.get('content'))) for p in s.get('parameters', [])]
        elif k == 'content':
            md += blocks(s.get('content'))
        elif k == 'properties':  # REST/JSON object docs
            md.append('## Properties')
            md += [f"- `{p['name']}`" for p in s.get('items', [])]
    for sec in d.get('topicSections', []):
        md.append(f"## {sec.get('title', 'Topics')}")
        md += [f'- {inline([{"type": "reference", "identifier": i}])}' for i in sec.get('identifiers', [])]
    for sec in d.get('relationshipsSections', []):
        md.append(f"## {sec.get('title', 'Relationships')}")
        md += [f'- {inline([{"type": "reference", "identifier": i}])}' for i in sec.get('identifiers', [])]
    for sec in d.get('seeAlsoSections', []):
        md.append(f"## See Also: {sec.get('title', '')}")
        md += [f'- {inline([{"type": "reference", "identifier": i}])}' for i in sec.get('identifiers', [])]
    return '\n\n'.join(x for x in md if x is not None).replace('\n\n- ', '\n- ')


# ---------------------------------------------------------------- api
def api(q, limit=5):
    con = sqlite3.connect(SYM_DB)
    parts = q.split('.')
    module, rest = (parts[0], parts[1:]) if len(parts) > 1 else (None, parts)
    path = '.'.join(rest)
    sql = 'SELECT module, path, kind, declaration, doc, availability FROM symbols WHERE '
    args = []
    if module:
        sql += 'lower(module) = lower(?) AND '; args.append(module)
    # exact path, then path prefix match on the last component (overloads / labelled functions)
    rows = con.execute(sql + 'lower(path) = lower(?) LIMIT ?', args + [path, limit]).fetchall()
    if not rows:
        rows = con.execute(sql + 'lower(path) LIKE lower(?) ORDER BY length(path) LIMIT ?',
                           args + [path + '%', limit]).fetchall()
    if not rows:
        rows = con.execute(sql + 'lower(path) LIKE lower(?) ORDER BY length(path) LIMIT ?',
                           args + ['%' + path + '%', limit]).fetchall()
    return [dict(module=r[0], path=r[1], kind=r[2], declaration=r[3], doc=r[4], availability=json.loads(r[5] or '[]'))
            for r in rows]


def fmt_avail(av):
    out = []
    for a in av:
        s = a.get('domain', '')
        if a.get('introduced'): s += ' ' + '.'.join(str(a['introduced'].get(k, 0)) for k in ('major', 'minor'))+'+'
        if a.get('deprecated'): s += ' (deprecated ' + '.'.join(str(a['deprecated'].get(k, 0)) for k in ('major', 'minor')) + ')'
        if a.get('isUnconditionallyDeprecated'): s += ' (deprecated)'
        if a.get('isUnconditionallyUnavailable'): s += ' (unavailable)'
        out.append(s)
    return ', '.join(out)


def main():
    ap = argparse.ArgumentParser(prog='ios docs')
    sp = ap.add_subparsers(dest='cmd', required=True)
    s = sp.add_parser('search'); s.add_argument('query'); s.add_argument('--framework'); s.add_argument('--kind')
    s.add_argument('--limit', type=int, default=10); s.add_argument('--json', action='store_true')
    f = sp.add_parser('fetch'); f.add_argument('path'); f.add_argument('--json', action='store_true')
    a = sp.add_parser('api'); a.add_argument('symbol'); a.add_argument('--limit', type=int, default=5)
    a.add_argument('--json', action='store_true')
    o = ap.parse_args()
    if o.cmd == 'search':
        t0 = time.time(); res = search(o.query, o.framework, o.kind, o.limit); dt = time.time() - t0
        if o.json: print(json.dumps(res, indent=1)); return
        for i, r in enumerate(res, 1):
            flags = ' [beta]' * r['beta'] + ' [deprecated]' * r['deprecated'] + ' [objc]' * (r['language'] == 'occ')
            print(f"{i:2}. {r['title']}  ({r['kind']}, {r['framework']}){flags}\n    doc://{r['path'][len('/documentation/'):]}")
        print(f'({len(res)} results in {dt*1000:.0f} ms)', file=sys.stderr)
    elif o.cmd == 'fetch':
        d = fetch_json(doc_path(o.path))
        print(json.dumps(d) if o.json else to_markdown(d))
    elif o.cmd == 'api':
        res = api(o.symbol, o.limit)
        if o.json: print(json.dumps(res, indent=1)); return
        if not res: print('no match', file=sys.stderr); sys.exit(1)
        for r in res:
            print(f"## {r['module']}.{r['path']}  ({r['kind']})\n```swift\n{r['declaration']}\n```")
            if r['availability']: print('**Availability:** ' + fmt_avail(r['availability']))
            if r['doc']: print('\n' + r['doc'])
            print()


if __name__ == '__main__':
    main()
