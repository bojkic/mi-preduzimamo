"""Exercise the real identity script with synthetic Git and a small Bundler API fixture."""
import hashlib,json,os
from pathlib import Path
import shutil,subprocess,tempfile,unittest
SCRIPT=Path(__file__).resolve().parents[2]/"installation/build_identity.rb"
class BuildIdentityTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.engine=self.root/"engine";self.engine.mkdir();self.app=self.root/"app";self.app.mkdir();self.fixture=self.root/"fixture";self.fixture.mkdir()
        def git(*args):return subprocess.check_output(["git","-C",str(self.engine),*args],stderr=subprocess.DEVNULL)
        git("init","-q");git("config","user.name","Synthetic Test");git("config","user.email","test@example.invalid")
        (self.engine/"decidim-bih.gemspec").write_text("synthetic gemspec\n");(self.engine/"lib").mkdir();(self.engine/"lib/engine.rb").write_text("# synthetic source\n")
        git("add",".");git("-c","core.hooksPath=/dev/null","commit","-qm","Synthetic engine")
        self.engine_sha=git("rev-parse","HEAD").decode().strip()
        (self.app/"Gemfile").write_text("# synthetic Gemfile\n");(self.app/"Gemfile.lock").write_text("synthetic lock\n");(self.app/"config").mkdir();(self.app/"config/.hidden.rb").write_text("# tracked hidden configuration\n");(self.app/"installation").mkdir()
        (self.fixture/"bundler.rb").write_text('''module Bundler
  module Source
    class Git
      def revision = ENV.fetch("SYNTHETIC_ENGINE_SHA")
    end
  end
  Spec = Struct.new(:name, :source, :full_gem_path)
  def self.spec = Spec.new("decidim-bih", Source::Git.new, ENV.fetch("SYNTHETIC_ENGINE_PATH"))
  def self.read_file(path) = File.read(path)
  def self.settings = Struct.new(:local_overrides).new({})
  def self.load = Struct.new(:specs).new([spec])
  class LockfileParser
    def initialize(text); end
    def specs = [Bundler.spec]
  end
end
''')
        self.env=dict(os.environ,MI_APP_BUILD_REVISION="a"*40,MI_ENGINE_BUILD_REVISION=self.engine_sha,MI_LOCK_BUILD_SHA256=hashlib.sha256((self.app/"Gemfile.lock").read_bytes()).hexdigest(),SYNTHETIC_ENGINE_SHA=self.engine_sha,SYNTHETIC_ENGINE_PATH=str(self.engine))
    def tearDown(self):self.tmp.cleanup()
    def run_identity(self):return subprocess.run([shutil.which("ruby"),"-I",str(self.fixture),str(SCRIPT)],cwd=self.app,env=self.env,text=True,capture_output=True)
    def test_manifest_records_top_level_and_hidden_files(self):
        result=self.run_identity();self.assertEqual(0,result.returncode,result.stderr)
        data=json.loads((self.app/"installation/build-identity.json").read_text())
        for name in ["Gemfile","Gemfile.lock","config/.hidden.rb"]:
            self.assertEqual(hashlib.sha256((self.app/name).read_bytes()).hexdigest(),data["app_files"][name])
    def test_expected_lock_mismatch_refuses_manifest(self):
        self.env["MI_LOCK_BUILD_SHA256"]="0"*64;result=self.run_identity()
        self.assertNotEqual(0,result.returncode);self.assertIn("Expected lockfile",result.stderr);self.assertFalse((self.app/"installation/build-identity.json").exists())
    def test_expected_engine_mismatch_refuses_manifest(self):
        self.env["MI_ENGINE_BUILD_REVISION"]="0"*40;result=self.run_identity()
        self.assertNotEqual(0,result.returncode);self.assertIn("Expected engine",result.stderr)
    def test_older_upgrade_client_without_new_args_keeps_git_provenance(self):
        del self.env["MI_ENGINE_BUILD_REVISION"];del self.env["MI_LOCK_BUILD_SHA256"]
        result=self.run_identity();self.assertEqual(0,result.returncode,result.stderr)
        data=json.loads((self.app/"installation/build-identity.json").read_text());self.assertEqual(self.engine_sha,data["engine_sha"])
    def test_modified_tracked_engine_source_is_refused(self):
        (self.engine/"lib/engine.rb").write_text("# changed after commit\n");result=self.run_identity()
        self.assertNotEqual(0,result.returncode);self.assertIn("Engine source differs",result.stderr)
if __name__=="__main__":unittest.main()
