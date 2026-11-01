# frozen_string_literal: true

require "test_helper"

class AdminVisualContractTest < ActiveSupport::TestCase
  ENGINE_ADMIN_ROOT = Decidim::Bih::Engine.root.join("app/views/decidim/bih/admin")
  HOST_ADMIN_ROOT = Rails.root.join("app/views/decidim_app/admin")

  test "custom admin templates use the current form and action contract" do
    sources = admin_templates.index_with(&:read)
    combined = sources.values.join("\n")

    assert_no_match(/\bhollow\b/, combined)
    assert_no_match(/class(?:=|:)\s*["']button["']/, combined)
    assert_no_match(/<style(?:\s|>)/, combined)

    sources.each do |path, source|
      assert_no_match(
        %r{<label[^>]*>(?:(?!</label>).)*<%=\s*(?:form|f)\.}m,
        source,
        "#{path} manually wraps a builder-owned field label"
      )
      form_calls = source.scan(/<%=?\s*(?:form_tag|form_with|form_for)\b(?:(?!%>).)*%>/m)
      form_calls.each do |form_call|
        assert_match(/form form-defaults/, form_call, "#{path} has a custom form without form-defaults")
      end
    end
  end

  test "engine packages the shared admin visual and responsive table layers" do
    layout = Decidim::Bih::Engine.root.join("app/views/layouts/decidim/bih/admin.html.erb").read
    asset_config = Decidim::Bih::Engine.root.join("config/assets.rb").read
    table_pack = Decidim::Bih::Engine.root.join("app/packs/entrypoints/decidim_bih_admin.js").read
    stylesheet = Decidim::Bih::Engine.root.join("app/packs/stylesheets/decidim/bih/_admin.scss").read

    assert_includes layout, "data-mi-admin-surface"
    assert_includes layout, "form-defaults"
    assert_includes layout, "decidim_bih_admin"
    assert_includes asset_config, "register_entrypoints"
    assert_includes asset_config, "register_stylesheet_import"
    assert_includes table_pack, "cell.dataset.label"
    assert_includes stylesheet, "td::before"
    assert_includes stylesheet, ".mi-admin-editor-table"
    assert_includes stylesheet, ".mi-admin-record-editor"
  end

  test "every custom admin table is in the responsive table boundary" do
    admin_templates.each do |path|
      source = path.read
      next unless source.include?("<table")

      if path == HOST_ADMIN_ROOT.join("city_service_events/index.html.erb")
        assert_includes source, 'class="city-alerts-table-wrap"'
        assert_includes source, "data-label="
        stylesheet = Rails.public_path.join("mi/city-alerts-admin.css").read
        assert_includes stylesheet, "@media (max-width: 1000px)"
        assert_includes stylesheet, ".city-alerts-summary-row { display: grid;"
        assert_includes stylesheet, "content: attr(data-label)"
        next
      end

      if path.to_s.end_with?("/report_review_batches/index.html.erb")
        assert_includes source, 'class="report-batch-table"'
        stylesheet = Rails.public_path.join("mi/report-review-batch.css").read
        assert_includes stylesheet, "@media (max-width: 720px)"
        assert_includes stylesheet, ".report-batch-table tr, .report-batch-table td { display: block;"
        assert_includes stylesheet, ".report-batch-table thead { position: absolute;"
        next
      end

      assert_includes source, "table-stacked", "#{path} has a table without the responsive wrapper"
    end
  end

  private

  def admin_templates
    [ENGINE_ADMIN_ROOT, HOST_ADMIN_ROOT].flat_map { |root| root.glob("**/*.html.erb") }.sort
  end
end
