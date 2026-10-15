import json, time, urllib.request, concurrent.futures as cf, os, sys
D = os.path.dirname(os.path.abspath(__file__))
d = json.load(open(os.path.join(D, 'tech.json')))
fw = sorted({v['url'].split('/')[2] for v in d['references'].values()
             if v.get('url','').startswith('/documentation/') and v['url'].count('/') == 2})
UA = {'User-Agent': 'ios-cli-docs-spike/0.1 (feasibility research)'}
def get(name):
    out = os.path.join(D, 'idx', name + '.json')
    if os.path.exists(out): return name, 200, os.path.getsize(out)
    time.sleep(0.15)
    try:
        r = urllib.request.urlopen(urllib.request.Request(f'https://developer.apple.com/tutorials/data/index/{name}', headers=UA), timeout=60)
        b = r.read(); open(out, 'wb').write(b); return name, r.status, len(b)
    except urllib.error.HTTPError as e: return name, e.code, 0
    except Exception as e: return name, str(e)[:40], 0
t0 = time.time(); res = []
with cf.ThreadPoolExecutor(4) as ex:
    for r in ex.map(get, fw): res.append(r)
ok = [r for r in res if r[1] == 200]; bad = [r for r in res if r[1] != 200]
print(f'frameworks={len(fw)} ok={len(ok)} failed={len(bad)} bytes={sum(r[2] for r in ok)/1e6:.1f}MB time={time.time()-t0:.1f}s')
print('failures:', bad[:30])
json.dump(res, open(os.path.join(D, 'fetch_results.json'), 'w'))
