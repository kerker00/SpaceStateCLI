#!/usr/bin/env python3
"""CLI contract checks using real HTTP and the release executable."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json, os, subprocess, tempfile, threading, time

requests = []
request_lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        with request_lock: requests.append(self.path)
        info={'space':'Test Space','state':{'open':True,'message':'<Guests welcome>'},'location':{'address':'Street 1','country_code':'DE','hint':'Ring twice'},'contact':{'email':'hi@example.org'}}
        lab={'space':'Test Lab','state':{'open':False}}
        body = json.dumps([{'url':base+'/ok','lastSeen':time.time(),'data':info},{'url':base+'/error','lastSeen':time.time(),'data':lab}]) if self.path=='/directory' else json.dumps(info)
        if self.path == '/mixed-directory':
            body = json.dumps([{'url':base+'/ok','data':info}] + [
                {'url':url,'data':{'space':'Test Invalid'}} for url in [
                    'file:///tmp/spacestate-invalid',
                    base.replace('http://', 'http://user:secret@')+'/unexpected',
                    base+'/%0A', base+'/unexpected\n', base.rsplit(':',1)[0]+':65536/unexpected',
                ]
            ])
        if self.path == '/freshness-directory':
            observed = time.time()
            body = json.dumps([
                {'url':base+'/ok','lastSeen':observed-5,'data':{'space':'Case Fresh','state':{'open':True}}},
                {'url':base+'/stale','lastSeen':observed-901,'data':{'space':'Case Stale','state':{'open':True}}},
                {'url':base+'/missing','data':{'space':'Case Missing','state':{'open':False}}},
                {'url':base+'/future','lastSeen':observed+10,'data':{'space':'Case Future','state':{'open':True}}},
                {'url':base+'/unreachable','lastSeen':observed-1,'validationResult':{'reachable':False},'data':{'space':'Case Unreachable','state':{'open':True}}},
                {'url':base+'/huge','lastSeen':1e300,'data':{'space':'Case Huge','state':{'open':True}}},
            ])
        if self.path == '/short-policy':
            body = json.dumps([{'url':base+'/ok','lastSeen':time.time()-10,'data':info}])
        if self.path == '/bad-time':
            info['state']['lastchange'] = 1e300
            body = json.dumps(info)
        self.send_response(503 if self.path=='/error' else 200)
        if self.path == '/short-policy': self.send_header('X-SpacePush-Max-Data-Age','2')
        self.end_headers(); self.wfile.write(body.encode())

server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
base=f'http://127.0.0.1:{server.server_port}'
threading.Thread(target=server.serve_forever,daemon=True).start()
root=Path(__file__).resolve().parents[1]
binary=root/'.build/release/spacestate'
home=tempfile.TemporaryDirectory()
env={**os.environ,'XDG_CONFIG_HOME':home.name+'/config','XDG_CACHE_HOME':home.name+'/cache','NO_COLOR':'1'}
directory=['--directory',base+'/directory']
def run(*args, code=0):
    result=subprocess.run([str(binary),*args],text=True,capture_output=True,timeout=20,env=env)
    assert result.returncode==code,(args,result)
    return result
try:
    assert 'usage: spacestate' in run('--help').stdout.lower()
    assert run('--version').stdout.strip() == '0.3.0'
    completion = run('--generate-completion-script','zsh').stdout
    assert '#compdef' in completion and 'spacestate' in completion
    invalid_urls = ['file:///tmp/spacestate-invalid',
                    base.replace('http://', 'http://user:secret@')+'/unexpected',
                    base+'/%0A', base+'/unexpected\n']
    with request_lock: before = len(requests)
    for url in invalid_urls:
        error = run('show',url,code=64).stderr
        assert 'secret' not in error and 'without credentials or control characters' in error
        run('search','test','--directory',url,code=64)
    with request_lock: assert len(requests) == before, requests
    filtered = json.loads(run('search','test','--json','--directory',base+'/mixed-directory').stdout)
    assert [entry['endpoint'] for entry in filtered] == [base+'/ok'], filtered
    with request_lock: assert requests == ['/mixed-directory'], requests
    [status]=json.loads(run('show',base+'/ok','--json').stdout)
    assert status['status']=='open' and status['name']=='Test Space' and 'error' not in status and status['checkedAt']
    assert status['freshness']=='current' and status['reportedStatus']=='open'
    assert status['receivedAt'] and status['attemptedAt'] and status['expiresAt']
    assert 'since' not in json.loads(run('show',base+'/bad-time','--json').stdout)[0]
    cases = json.loads(run('search','case','--json','--directory',base+'/freshness-directory').stdout)
    by_name = {entry['name']:entry for entry in cases}
    assert by_name['Case Fresh']['status']=='open', cases
    for name in ['Case Stale','Case Missing','Case Future','Case Unreachable','Case Huge']:
        assert by_name[name]['status']=='unknown' and 'error' not in by_name[name], cases
    assert by_name['Case Stale']['freshness']=='stale' and by_name['Case Stale']['reportedStatus']=='open'
    for name in ['Case Missing','Case Future','Case Huge']: assert 'checkedAt' not in by_name[name], cases
    [current] = json.loads(run('search','case','--open','--json','--directory',base+'/freshness-directory').stdout)
    assert current['name']=='Case Fresh'
    [short] = json.loads(run('search','test','--json','--directory',base+'/short-policy').stdout)
    assert short['status']=='unknown' and short['freshness']=='stale', short
    cache = Path(env['XDG_CACHE_HOME'])/'spacestate/directory.json'
    cache.parent.mkdir(parents=True,exist_ok=True)
    cache.write_text(json.dumps([{'url':base+'/ok','lastSeen':time.time()-2000,'data':{'space':'Cached Only','state':{'open':True}}}]))
    [resolved] = json.loads(run('show','cached only','--json').stdout)
    assert resolved['endpoint']==base+'/ok' and resolved['status']=='open' and resolved['source']=='direct'
    assert run(base+'/ok').stdout.startswith('Test Space  ● open')
    assert json.loads(run('test space','--json',*directory).stdout)[0]['endpoint']==base+'/ok'
    assert 'matches 2 spaces' in run('test',*directory,code=64).stderr
    assert 'No space is called' in run('nothing',*directory,code=64).stderr
    result=run('search','test','--json',*directory)
    assert [s['name'] for s in json.loads(result.stdout)]==['Test Space','Test Lab']
    assert len(json.loads(run('search','test','--open','--json',*directory).stdout))==1
    assert not run('search','missing',*directory).stdout
    assert 'unreachable' in run(base+'/error',code=1).stdout
    [failed_status]=json.loads(run('show',base+'/error','--json',code=1).stdout)
    assert failed_status['attemptedAt'] and failed_status['freshness']=='unknown' and 'checkedAt' not in failed_status
    assert run('-q',base+'/ok').stdout==''
    run('-q',base+'/error',code=2)
    assert 'No saved spaces' in run().stderr
    run('add','test space','lab',*directory)
    assert len(json.loads(run('--json',code=1).stdout))==2
    run('remove','lab')
    saved_file = Path(env['XDG_CONFIG_HOME'])/'spacestate/spaces'
    saved_file.write_bytes(saved_file.read_bytes().replace(b'\n',b'\r\n'))
    assert [s['name'] for s in json.loads(run('--json').stdout)]==['Test Space']
    info=run('info').stdout
    assert 'Street 1 (DE)' in info and 'Ring twice' in info and 'hi@example.org' in info
    [profile]=json.loads(run('info','--json').stdout)
    assert profile['location']['hint']=='Ring twice' and profile['contact']['email']=='hi@example.org'
    assert 'unreachable' in run('info',base+'/error',code=1).stdout
    run('remove','lab',code=64)
    lines=run('watch','--json','-n','2','-i','5s').stdout.splitlines()
    assert len(lines)==2 and all(json.loads(line)['status']=='open' for line in lines)
    failed=run('watch',base+'/error','--json','-n1')
    assert json.loads(failed.stdout)['error']
    waybar=json.loads(run('watch','--waybar','-n1').stdout)
    assert waybar['class']=='open' and waybar['tooltip']=='&lt;Guests welcome&gt;'
    run('watch','--waybar','-n1',base+'/ok',base+'/error',code=64)
    run('watch','-i','2s',code=64)
    print('CLI observation freshness, source times, directory policy/cache names, endpoint validation, HTTP, saved spaces, JSON, watch, Waybar and exit-code checks passed')
finally: server.shutdown(); server.server_close(); home.cleanup()
