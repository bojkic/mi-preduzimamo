# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "rqrcode"

namespace :decidim_app do
  namespace :komsiluk_naming_campaign do
    desc <<~DESC
      Create/update the UNPUBLISHED Decidim Komšiluk naming campaign draft.
      Usage: bin/rails "decidim_app:komsiluk_naming_campaign:setup[org.host]"
      Optional: NOMINATION_START=YYYY-MM-DD NOMINATION_END=YYYY-MM-DD VOTING_END=YYYY-MM-DD
    DESC
    task :setup, [:org_host] => :environment do |_task, args|
      organization = find_komsiluk_campaign_organization!(args[:org_host])
      dates = komsiluk_campaign_dates
      result = DecidimApp::Bijeljina::KomsilukNamingCampaignSetup.call(
        organization:,
        **dates
      )

      puts JSON.pretty_generate(
        process_id: result[:process].id,
        process_slug: result[:process].slug,
        published: result[:process].published?,
        component_id: result[:component].id,
        component_published: result[:component].published?,
        areas: result[:areas],
        initial_proposals: result[:initial_proposals],
        dates:
      )
    end

    desc "Print a PII-free aggregate campaign KPI/results report as JSON"
    task :report, [:org_host] => :environment do |_task, args|
      organization = find_komsiluk_campaign_organization!(args[:org_host])
      puts JSON.pretty_generate(
        DecidimApp::Bijeljina::KomsilukNamingCampaignMetrics.call(organization:)
      )
    end

    desc <<~DESC
      Generate one printable PNG QR code and an index CSV per Komšiluk.
      Usage: bin/rails "decidim_app:komsiluk_naming_campaign:qr[org.host,tmp/komsiluk-qr,https://org.host]"
    DESC
    task :qr, [:org_host, :output_dir, :base_url] => :environment do |_task, args|
      organization = find_komsiluk_campaign_organization!(args[:org_host])
      output_dir = Pathname(args[:output_dir].presence || Rails.root.join("tmp/komsiluk-naming-qr"))
      base_url = (args[:base_url].presence || "https://#{organization.host}").to_s.chomp("/")
      mapping = DecidimApp::Bijeljina::KomsilukNamingCampaign.taxonomy_mapping(organization)
      abort "Campaign mapping is missing; run the setup task first." if mapping.empty?

      FileUtils.mkdir_p(output_dir)
      rows = Decidim::Bih::LocalArea.komsiluci
                                    .where(decidim_organization_id: organization.id, slug: mapping.keys)
                                    .to_a
                                    .sort_by { |area| area.slug.delete_prefix("komsiluk-").to_i }
                                    .map do |area|
        number = area.slug.delete_prefix("komsiluk-")
        filename = "komsiluk-#{number}.png"
        url = "#{base_url}/k/#{number}"
        png = RQRCode::QRCode.new(url).as_png(size: 600)
        File.binwrite(output_dir.join(filename), png.to_s)
        [area.slug, area.name["sr"] || area.slug, url, filename]
      end

      CSV.open(output_dir.join("index.csv"), "wb") do |csv|
        csv << %w(area_slug area_name url filename)
        rows.each { |row| csv << row }
      end

      puts "Generated #{rows.size} QR codes in #{output_dir}"
      puts "Index: #{output_dir.join("index.csv")}"
    end

    desc <<~DESC
      Activate one campaign phase (nominations|voting|results). Write is blocked unless APPLY=1.
      Usage: APPLY=1 bin/rails "decidim_app:komsiluk_naming_campaign:activate_phase[org.host,voting]"
    DESC
    task :activate_phase, [:org_host, :phase] => :environment do |_task, args|
      abort "Set APPLY=1 to activate a campaign phase." unless ENV["APPLY"] == "1"

      organization = find_komsiluk_campaign_organization!(args[:org_host])
      process = DecidimApp::Bijeljina::KomsilukNamingCampaign.process_for(organization)
      abort "Campaign process is missing; run setup first." unless process

      titles = {
        "nominations" => DecidimApp::Bijeljina::KomsilukNamingCampaignSetup::NOMINATION_STEP,
        "voting" => DecidimApp::Bijeljina::KomsilukNamingCampaignSetup::VOTING_STEP,
        "results" => DecidimApp::Bijeljina::KomsilukNamingCampaignSetup::RESULTS_STEP
      }
      target_title = titles[args[:phase].to_s]
      abort "Phase must be one of: #{titles.keys.join(", ")}" unless target_title

      target = process.steps.find { |step| step.title["sr"] == target_title }
      abort "Campaign step not found: #{target_title}" unless target

      Decidim::ParticipatoryProcessStep.transaction do
        process.steps.where.not(id: target.id).update_all(active: false, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        target.update!(active: true)
      end
      puts "Activated #{args[:phase]} for #{organization.host}."
    end
  end
end

def find_komsiluk_campaign_organization!(host)
  abort "Organization host is required." if host.blank?

  Decidim::Organization.find_by(host:) || abort("Organization not found for host: #{host}")
end

def komsiluk_campaign_dates
  {
    nomination_start: Date.iso8601(ENV.fetch("NOMINATION_START", Date.current.iso8601)),
    nomination_end: Date.iso8601(ENV.fetch("NOMINATION_END", 27.days.from_now.to_date.iso8601)),
    voting_end: Date.iso8601(ENV.fetch("VOTING_END", 41.days.from_now.to_date.iso8601))
  }
rescue Date::Error => e
  abort "Invalid campaign date: #{e.message}"
end
