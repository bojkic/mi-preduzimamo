# frozen_string_literal: true

require "application_system_test_case"

class AdminGovernanceTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
  end

  test "admin records and reviews governance approval evidence" do
    model = Decidim::Bih::GovernanceApproval
    path = Rails.root.join("config/examples/release-approval-policy.example.yml")
    policy = YAML.safe_load_file(path)
    digest = Digest::SHA256.file(path).hexdigest
    model.stub(:local_verification_policy, policy) do
      model.stub(:local_verification_policy_sha256, digest) do
        sign_in_user! @admin

        visit "/admin/bih/governance"
        accept_data_consent!

        assert_selector "#admin-governance-readiness"
        assert_selector "[data-governance-row='release_restart']"
        within "[data-governance-row='release_restart']" do
          locale = @organization.default_locale
          assert_text I18n.t("decidim.bih.admin.governance.latest_empty", locale:)
          find("summary", text: I18n.t("decidim.bih.admin.governance.form.summary", locale:)).click
          select I18n.t("decidim.bih.admin.governance.statuses.approved", locale:),
                 from: "governance_approval_status_release_restart"
          fill_in I18n.t("decidim.bih.admin.governance.form.scope_key", locale:), with: "release-2026-07-09"
          fill_in I18n.t("decidim.bih.admin.governance.form.app_sha", locale:), with: "a" * 40
          fill_in I18n.t("decidim.bih.admin.governance.form.engine_sha", locale:), with: "b" * 40
          page.execute_script(
            "document.querySelector(arguments[0]).value = arguments[1]",
            "#governance_approval_restart_window_starts_at_release_restart",
            1.hour.ago.strftime("%Y-%m-%dT%H:%M")
          )
          page.execute_script(
            "document.querySelector(arguments[0]).value = arguments[1]",
            "#governance_approval_restart_window_ends_at_release_restart",
            1.hour.from_now.strftime("%Y-%m-%dT%H:%M")
          )
          select "fast", from: I18n.t("decidim.bih.admin.governance.form.verification_lane", locale:)
          %w(local_gate_status backup_health_status restore_smoke_status).each do |field|
            select "passed", from: I18n.t("decidim.bih.admin.governance.form.#{field}", locale:)
          end
          fill_in I18n.t("decidim.bih.admin.governance.form.verification_result_digest", locale:),
                  with: "sha256:#{"e" * 64}"
          assert_no_selector "[name='governance_approval[external_ci_status]']"
          assert_no_selector "[name='governance_approval[local_full_gate_status]']"
          fill_in I18n.t("decidim.bih.admin.governance.form.backup_manifest_digest", locale:),
                  with: "sha256:#{"d" * 64}"
          fill_in I18n.t("decidim.bih.admin.governance.form.evidence_summary", locale:),
                  with: "Required local fast checks passed; restart window approved."
          fill_in I18n.t("decidim.bih.admin.governance.form.evidence_digest", locale:), with: "sha256:#{"c" * 64}"
          click_button I18n.t("decidim.bih.admin.governance.form.submit", locale:)
        end

        assert_selector "[data-governance-latest='release_restart']"
        assert_text "Required local fast checks passed"
        assert_text "a" * 40
        assert_no_text "TOKEN"
        assert_no_text "PASSWORD"
        assert_no_horizontal_overflow!
        assert_no_browser_console_errors!
        approval = model.latest_by_kind(@organization).fetch("release_restart")
        assert_equal policy.dig("verification", "lanes", "fast", "required_scopes").sort, approval.required_scopes.sort
        assert_equal digest, approval.verification_policy_sha256
        # Manual evidence recording alone cannot substitute for a verified receipt.
        assert_not approval.local_verification_matches?(result: {}, result_digest: approval.verification_result_digest)
      end
    end
  end
  test "missing local policy keeps release approval unavailable" do
    model = Decidim::Bih::GovernanceApproval
    model.stub(:local_verification_policy, -> { raise Errno::ENOENT }) do
      sign_in_user! @admin
      visit "/admin/bih/governance"
      accept_data_consent!
      within "[data-governance-row='release_restart']" do
        assert_text I18n.t("decidim.bih.admin.governance.form.local_policy_unavailable", locale: @organization.default_locale)
        assert_no_selector "form[action*='release_restart']"
      end
      assert_empty model.where(organization: @organization, governance_kind: "release_restart")
      assert_no_browser_console_errors!
    end
  end

end
