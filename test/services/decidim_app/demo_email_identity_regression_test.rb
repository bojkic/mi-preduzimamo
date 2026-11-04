# frozen_string_literal: true

require_relative "demo_provisioner_test"
module DecidimApp
  class DemoProvisionerTest
    test "completed content remains idempotent after confirmed address change" do
      organization, user = prepare_organization
      @subject.call("content")
      user.update!(email: "changed-demo@example.org")
      user.confirm
      assert_equal "changed-demo@example.org", user.reload.email
      before_pages = organization.static_pages.order(:id).map(&:attributes)
      before_password = user.encrypted_password
      before_credentials = @directory.join("credentials.json").read
      @subject.call("content")
      assert_equal before_pages, organization.static_pages.order(:id).map(&:attributes)
      assert_equal before_password, user.reload.encrypted_password
      assert_equal before_credentials, @directory.join("credentials.json").read
    end
    test "geography retry preserves original areas after confirmed address change" do
      organization, user = prepare_organization
      @subject.call("content")
      @subject.call("geography")
      user.update!(email: "changed-geography@example.org")
      user.confirm
      assert_equal "changed-geography@example.org", user.reload.email
      before = Decidim::Bih::LocalArea.where(organization:).order(:id).map(&:attributes)
      credentials = @directory.join("credentials.json").read
      password = user.encrypted_password
      @subject.call("geography")
      assert_equal before, Decidim::Bih::LocalArea.where(organization:).order(:id).map(&:attributes)
      assert_equal credentials, @directory.join("credentials.json").read
      assert_equal password, user.reload.encrypted_password
    end
    test "recorded user id cannot adopt an account from another organization" do
      organization, user = prepare_organization
      @subject.call("content")
      foreign = FactoryBot.create(:user, :admin, :confirmed, organization: create_organization)
      record = JSON.parse(@directory.join("credentials.json").read)
      record["organization_user_id"] = foreign.id
      @subject.persist(record)
      password = user.reload.encrypted_password
      error = assert_raises(ActiveRecord::RecordNotFound, RuntimeError) { @subject.call("geography") }
      assert_match(/Demo belongs|Couldn't find/, error.message)
      assert_equal password, user.reload.encrypted_password
      assert_equal 0, Decidim::Bih::LocalArea.where(organization:).count
    end
    test "recorded demo account cannot continue after administrator rights are revoked" do
      organization, user = prepare_organization
      @subject.call("content")
      user.update!(admin: false)
      before_credentials = @directory.join("credentials.json").read
      error = assert_raises(RuntimeError) { @subject.call("geography") }
      assert_match(/must remain an administrator/, error.message)
      assert_equal before_credentials, @directory.join("credentials.json").read
      assert_equal 0, Decidim::Bih::LocalArea.where(organization:).count
    end
  end
end
