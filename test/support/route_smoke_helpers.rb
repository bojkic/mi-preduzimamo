# frozen_string_literal: true

require "capybara"
require "decidim/participatory_processes/test/factories"

module RouteSmokeShakapackerManifestStub
  def lookup(name, **_opts) = "/packs-test/#{name}"

  def lookup!(name, **) = lookup(name, **)

  def lookup_pack_with_chunks(name, **_opts) = ["/packs-test/#{name}"]

  def lookup_pack_with_chunks!(name, **) = lookup_pack_with_chunks(name, **)
end

Shakapacker.manifest.singleton_class.prepend(RouteSmokeShakapackerManifestStub) unless Shakapacker.manifest.singleton_class < RouteSmokeShakapackerManifestStub

module RouteSmokeHelpers
  WEB_CHAT_HEADERS = {
    "Content-Type" => "application/json",
    "X-Requested-With" => "XMLHttpRequest"
  }.freeze

  def self.included(base)
    base.include ::Devise::Test::IntegrationHelpers
  end

  def setup_smoke_organization!
    @organization = create_organization
    create(:participatory_process, :published, organization: @organization)
    host! @organization.host
  end

  def sign_in_smoke_admin!
    sign_in FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
  end

  def sign_in_smoke_user!
    sign_in FactoryBot.create(:user, :confirmed, organization: @organization)
  end

  def assert_smoke_success(path, require_body: true)
    assert_response :success, smoke_failure_message(path)
    assert response.body.present?, "Expected #{path} to render a non-empty response body" if require_body
  end

  def assert_smoke_reachable(path, require_body: true)
    assert_includes 200...400, response.status, smoke_failure_message(path)
    assert response.body.present?, "Expected #{path} to render a non-empty response body" if require_body && response.status < 300
  end

  def assert_no_server_error(path)
    assert_operator response.status, :<, 500, smoke_failure_message(path)
    assert_not_equal 404, response.status, "Expected #{path} to be routed"
  end

  def reset_smoke_concierge!
    DecidimApp::Bijeljina::WebConcierge.reset! if defined?(DecidimApp::Bijeljina::WebConcierge)
    DecidimApp::Bijeljina::Concierge.reset! if defined?(DecidimApp::Bijeljina::Concierge)
  end

  private

  def smoke_failure_message(path)
    "Expected #{path} smoke request to avoid server errors; got #{response.status}\n#{response.body.to_s.first(500)}"
  end
end
