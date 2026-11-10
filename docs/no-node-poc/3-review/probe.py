import subprocess,json,sys,os,time,threading,select
cfg,home,cwd=sys.argv[1:4]; extra=sys.argv[4:]
env={k:v for k,v in os.environ.items() if not k.startswith('CLAUDE') and k not in('ANTHROPIC_API_KEY',)}
env.update(HOME=home,CLAUDE_CONFIG_DIR=cfg,CLAUDE_CODE_ENTRYPOINT='sdk-ts',CLAUDE_AGENT_SDK_VERSION='0.3.319',CLAUDE_AGENT_SDK_CLIENT_APP='toasty',CLAUDE_CODE_SDK_READS_SESSION_STATE='1')
args=[os.path.expanduser('~/.local/bin/claude'),'--output-format','stream-json','--verbose','--input-format','stream-json','--permission-prompt-tool=stdio','--tools=default','--setting-sources=user,project,local','--include-partial-messages','--replay-user-messages']+extra
p=subprocess.Popen(args,cwd=cwd,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
t0=time.time()
def rd():
    for line in p.stdout:
        try: m=json.loads(line)
        except Exception: print('NONJSON',line[:200]); continue
        t=m.get('type'); s=m.get('subtype') or (m.get('response') or {}).get('subtype') or (m.get('request') or {}).get('subtype')
        body=json.dumps(m)
        if t=='control_response':
            r=m['response']; rr=r.get('response')
            if isinstance(rr,dict) and 'commands' in rr: body='<initialize response keys: %s>'%sorted(rr.keys())
        if 'totalTokens' in body:
            rr=m['response']['response']; body='CTX total=%s msgs=%s'%(rr.get('totalTokens'),[c.get('tokens') for c in rr.get('categories',[]) if c.get('name')=='Messages'])
        print('%6dms <- %s/%s %s'%((time.time()-t0)*1000,t,s,body[:420]),flush=True)
threading.Thread(target=rd,daemon=True).start()
threading.Thread(target=lambda:[print('STDERR',l.rstrip()[:300]) for l in p.stderr],daemon=True).start()
def send(o,wait=1.2):
    print('%6dms -> %s'%((time.time()-t0)*1000,json.dumps(o)[:200]),flush=True)
    p.stdin.write(json.dumps(o)+'\n'); p.stdin.flush(); time.sleep(wait)
n=0
def req(r,wait=1.2):
    global n; n+=1; send({'type':'control_request','request_id':'r%d'%n,'request':r},wait)
req({'subtype':'initialize','promptSuggestions':True},2.5)
for r in json.loads(os.environ.get('PROBE','[]')): req(r,2.0)
p.stdin.close()
try: p.wait(8); print('exit',p.returncode,'%.0fms after start'%((time.time()-t0)*1000))
except subprocess.TimeoutExpired: print('STILL RUNNING 8s after stdin close'); p.kill()
time.sleep(0.3)
