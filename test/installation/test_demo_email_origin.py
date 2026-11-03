"""Run the actual demo initializer in a small Ruby framework fixture, no DB/Docker."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROFILE = Path(__file__).resolve().parents[2] / "installation/demo/00_profile.rb"
HARNESS = r'''require "ostruct"
require "pathname"
require "json"
module Rails
  def self.root = Pathname.new(ENV.fetch("SYNTHETIC_ROOT"))
  def self.application = @application ||= OpenStruct.new(config: Config.new)
  class Config
    attr_accessor :force_ssl, :assume_ssl
    def action_mailer = @mailer ||= OpenStruct.new
    def to_prepare(&block) = block.call
  end
end
module Decidim
  module Bih
    def self.public_url(path, base_url:) = "#{base_url}/custom-mount/#{path}"
    class EmailConfirmationMailer
      private
      def confirmation_url(token, organization) = "https://#{organization.host}/#{token}"
    end
  end
end
load ARGV.fetch(0)
organization = Struct.new(:host).new(ENV.fetch("SYNTHETIC_ORG_HOST"))
puts JSON.generate(url: Decidim::Bih::EmailConfirmationMailer.new.send(:confirmation_url, "synthetic-proof", organization), ssl: Rails.application.config.force_ssl)
'''

class DemoEmailOriginTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / "installation/demo").mkdir(parents=True)
        (root / "installation/demo/drain_probe_job.rb").write_text("# Synthetic job dependency; not under test.\n")
        self.env = {"PATH": os.environ["PATH"], "SYNTHETIC_ROOT": str(root), "SYNTHETIC_ORG_HOST": "127.0.0.1", "MI_INSTALL_PROFILE": "demo", "MI_LOCAL_HTTP": "true", "RAILS_ALLOWED_HOSTS": "127.0.0.1", "MI_WEB_PORT": "4300"}

    def tearDown(self):
        self.tmp.cleanup()

    def run_profile(self, **updates):
        return subprocess.run([shutil.which("ruby"), "-e", HARNESS, str(PROFILE)], env=self.env | updates, text=True, capture_output=True)

    def test_real_override_preserves_custom_mount_and_local_port(self):
        result = self.run_profile()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual({"url": "http://127.0.0.1:4300/custom-mount/potvrdi-email/synthetic-proof", "ssl": False}, json.loads(result.stdout))

    def test_localhost_organization_uses_the_documented_numeric_loopback_origin(self):
        result = self.run_profile(SYNTHETIC_ORG_HOST="localhost", RAILS_ALLOWED_HOSTS="localhost")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(json.loads(result.stdout)["url"].startswith("http://127.0.0.1:4300/"))

    def test_production_profile_is_rejected(self):
        self.assertNotEqual(0, self.run_profile(MI_INSTALL_PROFILE="production").returncode)

    def test_missing_explicit_local_http_is_rejected(self):
        self.assertNotEqual(0, self.run_profile(MI_LOCAL_HTTP="false").returncode)

    def test_empty_allowed_hosts_is_rejected_before_disabling_ssl(self):
        result = self.run_profile(RAILS_ALLOWED_HOSTS="")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual("", result.stdout)

    def test_nonlocal_or_lookalike_host_is_rejected(self):
        for host in ["example.invalid", "127.0.0.1.example.invalid", "localhost.example.invalid"]:
            with self.subTest(host=host):
                self.assertNotEqual(0, self.run_profile(SYNTHETIC_ORG_HOST=host).returncode)
                self.assertNotEqual(0, self.run_profile(RAILS_ALLOWED_HOSTS=host).returncode)

    def test_invalid_ports_are_rejected_without_generating_a_url(self):
        for port in ["80", "65536", "not-a-port"]:
            with self.subTest(port=port):
                result = self.run_profile(MI_WEB_PORT=port)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual("", result.stdout)
