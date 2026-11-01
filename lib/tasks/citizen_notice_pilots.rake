# frozen_string_literal: true

namespace :mi do
  namespace :citizen_notice_pilots do
    desc "Prepare one explicitly selected public notice pilot (SOURCE=bihamk_border|pio_notices|jfdz_notices)"
    task refresh: :environment do
      key = ENV.fetch("SOURCE")
      payload = DecidimApp::Bijeljina::CitizenNoticePilots.new.refresh(key:)
      abort "pilot refresh already running" unless payload
      puts JSON.generate(source: key, status: payload["status"], records: Array(payload["records"]).size, error_code: payload["error_code"])
      abort "pilot preparation failed; inspect source health" unless %w(ok empty).include?(payload["status"])
    end
  end
end
