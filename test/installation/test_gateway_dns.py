"""Real isolated Nginx/DNS test: no Docker daemon or production configuration."""
import http.server,os
from pathlib import Path
import shutil,socket,socketserver,struct,subprocess,tempfile,threading,time,unittest,urllib.request
NGINX=shutil.which("nginx") or ("/usr/sbin/nginx" if Path("/usr/sbin/nginx").is_file() else None)
CONFIG=Path(__file__).resolve().parents[2]/"installation/nginx.demo.conf"
@unittest.skipUnless(NGINX,"Nginx executable required for real DNS refresh test")
class GatewayDnsTest(unittest.TestCase):
    def test_gateway_resolves_changed_service_address_and_preserves_request(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);servers=[];threads=[];process=None;current={"address":"127.0.0.2"}
            class Dns(socketserver.BaseRequestHandler):
                def handle(self):
                    data,udp=self.request;offset=12
                    while data[offset]:offset+=data[offset]+1
                    end=offset+5;question=data[12:end]
                    header=data[:2]+struct.pack("!HHHHH",0x8180,1,1,0,0)
                    answer=b"\xc0\x0c"+struct.pack("!HHIH",1,1,1,4)+socket.inet_aton(current["address"])
                    udp.sendto(header+question+answer,self.client_address)
            def backend(name,address,port):
                class Handler(http.server.BaseHTTPRequestHandler):
                    def do_GET(self):
                        body=(name+":"+self.path+":"+self.headers["Host"]+":"+self.headers.get("X-Forwarded-Proto","")).encode()
                        self.send_response(200);self.end_headers();self.wfile.write(body)
                    def log_message(self,*args):pass
                return http.server.HTTPServer((address,port),Handler)
            def free_port():
                with socket.socket() as sock:sock.bind(("127.0.0.1",0));return sock.getsockname()[1]
            try:
                dns=socketserver.UDPServer(("127.0.0.1",0),Dns);servers.append(dns)
                first=backend("first","127.0.0.2",0);servers.append(first)
                second=backend("second","127.0.0.3",first.server_port);servers.append(second)
                for server in servers:
                    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();threads.append(thread)
                port=free_port();mail_port=free_port()
                config=CONFIG.read_text().replace("listen 8080;",f"listen 127.0.0.1:{port};").replace("listen 8025;",f"listen 127.0.0.1:{mail_port};").replace("127.0.0.11",f"127.0.0.1:{dns.server_address[1]}").replace("app:3000",f"app:{first.server_port}")
                config="error_log stderr;\npid "+str(root/"nginx.pid")+";\nevents {}\nhttp { access_log off;\n"+config+"\n}\n"
                path=root/"nginx.conf";path.write_text(config)
                log=(root/"nginx.log").open("wb")
                process=subprocess.Popen([NGINX,"-p",str(root),"-c",str(path),"-g","daemon off;"],stdout=log,stderr=log)
                opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
                request=urllib.request.Request(f"http://127.0.0.1:{port}/up?probe=1",headers={"Host":"community.example.invalid"})
                def response():
                    with opener.open(request,timeout=2) as result:return result.read().decode()
                deadline=time.monotonic()+5
                while True:
                    try:initial=response();break
                    except OSError:
                        if process.poll() is not None:self.fail((root/"nginx.log").read_text())
                        if time.monotonic()>deadline:raise
                        time.sleep(.1)
                self.assertEqual("first:/up?probe=1:community.example.invalid:http",initial)
                current["address"]="127.0.0.3";deadline=time.monotonic()+10
                while True:
                    body=response()
                    if body.startswith("second:"):break
                    self.assertLess(time.monotonic(),deadline,"Gateway retained stale service IP")
                    time.sleep(.2)
                self.assertEqual("second:/up?probe=1:community.example.invalid:http",body)
            finally:
                if process is not None:
                    process.terminate()
                    try:process.wait(timeout=5)
                    except subprocess.TimeoutExpired:process.kill();process.wait()
                    log.close()
                for server in servers:server.shutdown();server.server_close()
                for thread in threads:thread.join()
if __name__=="__main__":unittest.main()
