#!/usr/bin/env python3
"""CLI contract checks using real HTTP and the release executable."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json, os, subprocess, tempfile, threading

requests = []
request_lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        with request_lock: requests.append(self.path)
        info={'space':'Test Space','state':{'open':True,'message':'<Guests welcome>'},'location':{'address':'Street 1','country_code':'DE','hint':'Ring twice'},'contact':{'email':'hi@example.org'}}
        lab={'space':'Test Lab','state':{'open':False}}
        body = json.dumps([{'url':base+'/ok','data':info},{'url':base+'/error','data':lab}]) if self.path=='/directory' else json.dumps(info)
        if self.path == '/mixed-directory':
            body = json.dumps([{'url':base+'/ok','data':info}] + [
                {'url':url,'data':{'space':'Test Invalid'}} for url in [
                    'file:///tmp/spacestate-invalid',
                    base.replace('http://', 'http://user:secret@')+'/unexpected',
                    base+'/%0A', base+'/unexpected\n', base.rsplit(':',1)[0]+':65536/unexpected',
                ]
            ])
        self.send_response(503 if self.path=='/error' else 200)
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
    assert run(base+'/ok').stdout.startswith('Test Space  ● open')
    assert json.loads(run('test space','--json',*directory).stdout)[0]['endpoint']==base+'/ok'
    assert 'matches 2 spaces' in run('test',*directory,code=64).stderr
    assert 'No space is called' in run('nothing',*directory,code=64).stderr
    result=run('search','test','--json',*directory)
    assert [s['name'] for s in json.loads(result.stdout)]==['Test Space','Test Lab']
    assert len(json.loads(run('search','test','--open','--json',*directory).stdout))==1
    assert not run('search','missing',*directory).stdout
    assert 'unreachable' in run(base+'/error',code=1).stdout
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
    print('CLI endpoint validation, directory filtering, HTTP, names, saved spaces, search, info, JSON, watch, Waybar and exit-code checks passed')
finally: server.shutdown(); server.server_close(); home.cleanup()
