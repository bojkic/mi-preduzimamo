# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require Rails.root.join("installation/demo/provision")

module DecidimApp
  class DemoProvisionerTest < ActiveSupport::TestCase
    setup do
      @directory = Pathname.new(Dir.mktmpdir("mi-demo-provision-"))
      @directory.chmod(0o700)
      @identity = "mi-#{SecureRandom.hex(8)}"
      @old_env = %w(MI_INSTALL_ID MI_INSTALL_PROFILE MI_LOCAL_HTTP).index_with { |key| ENV.fetch(key, nil) }
      ENV["MI_INSTALL_ID"] = @identity
      ENV["MI_INSTALL_PROFILE"] = "demo"
      ENV["MI_LOCAL_HTTP"] = "true"
      @metadata = ActiveRecord::Base.connection_pool.internal_metadata
      @previous_identity = @metadata["mi_installation_id"]
      @metadata["mi_installation_id"] = @identity
      @subject = MiDemoProvisioner.new(private_dir: @directory)
    end

    teardown do
      @metadata["mi_installation_id"] = @previous_identity
      @old_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      FileUtils.remove_entry(@directory)
    end

    test "first system setup refuses an existing community before credential or account writes" do
      organization = create_organization
      before_pages = organization.static_pages.order(:id).pluck(:id, :content)
      assert_no_difference -> { Decidim::System::Admin.count } do
        error = assert_raises(RuntimeError) { @subject.call("system") }
        assert_match "existing community", error.message
      end
      assert_not @directory.join("credentials.json").exist?
      assert_equal before_pages, organization.static_pages.order(:id).pluck(:id, :content)
    end

    test "failed credential write cannot create a system administrator" do
      assert_no_difference -> { Decidim::System::Admin.count } do
        @subject.stub(:persist, ->(_) { raise IOError, "Synthetic private file failure" }) do
          assert_raises(IOError) { @subject.call("system") }
        end
      end
      assert_not @directory.join("credentials.json").exist?
    end

    test "write failure after account creation resumes the exact account without password reset" do
      original = @subject.method(:persist)
      writes = 0
      @subject.stub(:persist, lambda { |record|
        writes += 1
        raise IOError, "Synthetic completion write failure" if writes == 2

        original.call(record)
      }) do
        assert_raises(IOError) { @subject.call("system") }
      end
      pending = JSON.parse(@directory.join("credentials.json").read)
      assert_equal "planned", pending.fetch("system_state")
      admin = Decidim::System::Admin.find_by!(email: MiDemoProvisioner::SYSTEM_EMAIL)
      password_hash = admin.encrypted_password
      assert_no_difference -> { Decidim::System::Admin.count } do
        @subject.call("system")
      end
      assert_equal password_hash, admin.reload.encrypted_password
      assert admin.valid_password?(pending.fetch("system_password"))
      assert_equal "done", JSON.parse(@directory.join("credentials.json").read).fetch("system_state")
      assert_equal 0o600, @directory.join("credentials.json").stat.mode & 0o777
    end

    test "foreign database identity is refused before any credential write" do
      @metadata["mi_installation_id"] = "mi-#{SecureRandom.hex(8)}"
      assert_raises(RuntimeError) { @subject.call("system") }
      assert_not @directory.join("credentials.json").exist?
    end

    test "concurrent setup is rejected by the private provisioning lock" do
      File.open(@directory.join(".provision.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        assert lock.flock(File::LOCK_EX | File::LOCK_NB)
        assert_raises(RuntimeError) { @subject.call("system") }
      end
      assert_not @directory.join("credentials.json").exist?
    end

    test "content guard rejects existing citizens before changing pages or credentials" do
      organization, = prepare_organization
      FactoryBot.create(:user, :confirmed, organization:)
      before_pages = organization.static_pages.order(:id).pluck(:id, :content)
      before_credentials = @directory.join("credentials.json").read
      assert_raises(RuntimeError) { @subject.call("content") }
      assert_equal before_pages, organization.static_pages.order(:id).pluck(:id, :content)
      assert_equal before_credentials, @directory.join("credentials.json").read
    end

    test "a second organization is refused before demo content writes" do
      organization, = prepare_organization
      create_organization
      before_pages = organization.static_pages.order(:id).pluck(:id, :content)
      before_credentials = @directory.join("credentials.json").read
      assert_raises(RuntimeError) { @subject.call("content") }
      assert_equal before_pages, organization.static_pages.order(:id).pluck(:id, :content)
      assert_equal before_credentials, @directory.join("credentials.json").read
    end

    test "a custom community page is refused before demo content writes" do
      organization, = prepare_organization
      FactoryBot.create(:static_page, organization:, slug: "community-about")
      before_pages = organization.static_pages.order(:id).pluck(:id, :content)
      before_credentials = @directory.join("credentials.json").read
      assert_raises(RuntimeError) { @subject.call("content") }
      assert_equal before_pages, organization.static_pages.order(:id).pluck(:id, :content)
      assert_equal before_credentials, @directory.join("credentials.json").read
    end

    test "edited terms are refused before content setup" do
      organization, = prepare_organization
      terms = organization.static_pages.find_by!(slug: "terms-of-service")
      terms.update!(content: organization.available_locales.index_with { "Operator content that must stay" })
      before_credentials = @directory.join("credentials.json").read
      assert_raises(RuntimeError) { @subject.call("content") }
      assert_equal "Operator content that must stay", terms.reload.content.fetch("sr")
      assert_equal before_credentials, @directory.join("credentials.json").read
    end

    test "content completion can be retried without rewriting pages or password" do
      organization, user = prepare_organization
      @subject.call("content")
      assert user.reload.invitation_accepted_at
      before_pages = organization.static_pages.order(:id).pluck(:id, :content)
      before_credentials = @directory.join("credentials.json").read
      before_password = user.encrypted_password
      FactoryBot.create(:user, :confirmed, organization:)
      @subject.call("content")
      assert_equal before_pages, organization.static_pages.order(:id).pluck(:id, :content)
      assert_equal before_credentials, @directory.join("credentials.json").read
      assert_equal before_password, user.reload.encrypted_password
    end

    test "content journal write failure after commit is reconciled without reapplying content" do
      organization, user = prepare_organization
      original = @subject.method(:persist)
      writes = 0
      @subject.stub(:persist, lambda { |record|
        writes += 1
        raise IOError, "Synthetic content completion failure" if writes == 2

        original.call(record)
      }) do
        assert_raises(IOError) { @subject.call("content") }
      end
      assert user.reload.invitation_accepted_at
      before_pages = organization.static_pages.order(:id).pluck(:id, :content)
      @subject.call("content")
      assert_equal before_pages, organization.static_pages.order(:id).pluck(:id, :content)
      assert_equal "done", JSON.parse(@directory.join("credentials.json").read).fetch("content_state")
    end

    test "real system informational defaults are preserved during demo setup" do
      organization, user = prepare_organization
      Decidim::System::CreateDefaultHelpPages.call(organization)
      Decidim::ParticipatoryProcesses::CreateDemocraticQualityIndicatorsPage.call(organization.id)
      pages = organization.static_pages.where.not(slug: "terms-of-service").order(:id)
      before = pages.pluck(:id, :title, :content, :updated_at)
      original_ids = before.map(&:first)
      @subject.call("content")
      assert user.reload.invitation_accepted_at
      assert_equal before, organization.static_pages.where(id: original_ids).order(:id).pluck(:id, :title, :content, :updated_at)
    end

    %w(help democratic-quality-indicators).each do |slug|
      test "edited #{slug} defaults are refused before any provisioning write" do
        organization, = prepare_organization
        Decidim::System::CreateDefaultHelpPages.call(organization)
        Decidim::ParticipatoryProcesses::CreateDemocraticQualityIndicatorsPage.call(organization.id)
        organization.static_pages.find_by!(slug:).update!(content: organization.available_locales.index_with { "Reviewed operator content" })
        before = organization.static_pages.order(:id).pluck(:id, :title, :content, :updated_at)
        credential_before = @directory.join("credentials.json").read
        assert_raises(RuntimeError) { @subject.call("content") }
        assert_equal before, organization.static_pages.order(:id).pluck(:id, :title, :content, :updated_at)
        assert_equal credential_before, @directory.join("credentials.json").read
      end
    end

    test "explicit synthetic geography is imported once without changing credentials" do
      organization, = prepare_organization
      @subject.call("content")
      credentials = @directory.join("credentials.json").read
      assert_difference -> { Decidim::Bih::LocalArea.where(organization:).count }, 5 do
        @subject.call("geography")
      end
      before = Decidim::Bih::LocalArea.where(organization:).order(:id).map(&:attributes)
      @subject.call("geography")
      assert_equal before, Decidim::Bih::LocalArea.where(organization:).order(:id).map(&:attributes)
      assert_equal credentials, @directory.join("credentials.json").read
    end

    test "explicit demo geography refuses preexisting community areas" do
      organization, = prepare_organization
      @subject.call("content")
      area = Decidim::Bih::LocalArea.create!(organization:, kind: "komsiluk", slug: "existing", name: { sr: "Existing synthetic area" })
      before = area.attributes
      assert_raises(RuntimeError) { @subject.call("geography") }
      assert_equal before, area.reload.attributes
      assert_equal 1, Decidim::Bih::LocalArea.where(organization:).count
    end

    private

    def prepare_organization
      @subject.call("system")
      organization = create_organization(host: "127.0.0.1", create_static_pages: false)
      Decidim::System::CreateDefaultPages.call(organization)
      user = FactoryBot.create(:user, :admin, :confirmed, organization:, email: MiDemoProvisioner::ADMIN_EMAIL,
                                                          invitation_created_at: Time.current, invitation_sent_at: Time.current, invitation_token: SecureRandom.hex(16))
      [organization, user]
    end
  end
end
