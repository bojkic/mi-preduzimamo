"""Real loopback HTTP probes: no Docker or external network."""
import contextlib
import http.server
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/"script/lib"))
from mi_installer import Installation,InstallError
class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.subject=Installation(Path(self.temp.name))
        self.responses=[200];self.requests=[]
        owner=self
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests.append((self.path,dict(self.headers)))
                code=owner.responses.pop(0) if owner.responses else 200
                self.send_response(code)
                if code==302:self.send_header("Location","http://127.0.0.1:"+str(self.server.server_port)+"/must-not-follow")
                self.end_headers()
            def log_message(self,*args):pass
        self.server=http.server.HTTPServer(("127.0.0.1",0),Handler)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.subject.config={"profile":"demo","ports":{"web":self.server.server_port},"domain":"127.0.0.1"}
    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.thread.join();self.temp.cleanup()
    def test_demo_probes_gateway_up_and_never_uses_ambient_proxy(self):
        with patch.dict("os.environ",{"HTTP_PROXY":"http://127.0.0.1:1","http_proxy":"http://127.0.0.1:1"}):self.subject.verify_http()
        self.assertEqual("/up",self.requests[0][0]);self.assertEqual("127.0.0.1",self.requests[0][1]["Host"])
        self.assertNotIn("X-Forwarded-Proto",self.requests[0][1])
    def test_production_backend_probe_uses_its_configured_host_and_https(self):
        self.subject.config.update(profile="production",domain="community.example.org")
        self.subject.verify_http()
        self.assertEqual("community.example.org",self.requests[0][1]["Host"])
        self.assertEqual("https",self.requests[0][1]["X-Forwarded-Proto"])
    def test_gateway_failure_is_not_a_successful_runtime_probe(self):
        self.responses=[502]
        with self.assertRaises(InstallError):self.subject.verify_http(timeout=0)
        self.assertEqual(1,len(self.requests))
    def test_transient_stale_upstream_retries_then_succeeds(self):
        self.responses=[502,200]
        self.subject.verify_http(timeout=3)
        self.assertEqual(2,len(self.requests))
    def test_redirect_is_rejected_without_following_it(self):
        self.responses=[302]
        with self.assertRaises(InstallError):self.subject.verify_http(timeout=0)
        self.assertEqual(["/up"],[path for path,_ in self.requests])
if __name__=="__main__":unittest.main()
