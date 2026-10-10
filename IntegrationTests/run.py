#!/usr/bin/env python3
"""CLI contract checks using real HTTP and the release executable."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json, subprocess, threading

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        info={'space':'Test Space','state':{'open':True,'message':'<Guests welcome>'}}
        body = json.dumps([{'url':base+'/ok','data':info}]) if self.path=='/directory' else json.dumps(info)
        self.send_response(503 if self.path=='/error' else 200)
        self.end_headers(); self.wfile.write(body.encode())

server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
base=f'http://127.0.0.1:{server.server_port}'
threading.Thread(target=server.serve_forever,daemon=True).start()
root=Path(__file__).resolve().parents[1]
binary=root/'.build/release/spacestate'
def run(*args, code=0):
    result=subprocess.run([str(binary),*args],text=True,capture_output=True,timeout=20)
    assert result.returncode==code,(args,result)
    return result
try:
    status=json.loads(run('status','--space',base+'/ok','--format','json').stdout)
    assert status['status']=='open' and status['schemaVersion']==1 and status['network']=='ok'
    result=run('search','test','--directory',base+'/directory','--format','json')
    assert len(json.loads(result.stdout)['spaces'])==1
    assert not run('search','missing','--directory',base+'/directory').stdout
    assert run('status','--space',base+'/error',code=1).stdout==''
    assert run('status',code=2).stdout==''
    lines=run('watch','--space',base+'/ok','--format','ndjson','--count','2','--interval','5').stdout.splitlines()
    assert len(lines)==2 and all(json.loads(line)['status']=='open' for line in lines)
    failed=run('watch','--space',base+'/error','--format','ndjson','--count','1')
    assert json.loads(failed.stdout)['network']=='error' and failed.stderr
    waybar=json.loads(run('watch','--space',base+'/ok','--format','waybar-json','--count','1').stdout)
    assert waybar['class']=='open' and waybar['tooltip']=='&lt;Guests welcome&gt;'
    print('CLI HTTP, search, JSON, watch, Waybar and exit-code checks passed')
finally: server.shutdown(); server.server_close()
