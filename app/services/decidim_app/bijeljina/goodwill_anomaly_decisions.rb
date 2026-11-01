# frozen_string_literal: true

require "digest"
require "etc"
require "fileutils"
require "json"
require "time"

module DecidimApp
  module Bijeljina
    # Operator decisions cover exact anomaly evidence. Changed count, day, or
    # detector detail produces a new case and reopens review automatically.
    class GoodwillAnomalyDecisions
      OUTCOMES = %w(reviewed_no_action escalated).freeze

      def initialize(path: Rails.root.join("shared/state/goodwill_anomaly_decisions.json"), runtime_reader: self.class.runtime_reader)
        @path = path.to_s
        @runtime_reader = runtime_reader
      end

      def self.runtime_reader
        Etc.getpwnam("mi-runtime").name
      rescue ArgumentError
        nil
      end

      def case_id(organization, flag)
        Digest::SHA256.hexdigest(JSON.generate([organization.id, flag.fetch(:type).to_s,
                                                 flag.fetch(:user).id, flag[:count], flag[:detail].to_s,
                                                 referral_evidence(organization, flag)]))
      end

      def open_flags(organization, flags)
        decisions = read.fetch("decisions", {})
        flags.reject { |flag| decisions.key?(case_id(organization, flag)) }
      end

      def decide(organization, flag, outcome:, reason:, actor:)
        raise ArgumentError, "invalid outcome" unless OUTCOMES.include?(outcome.to_s)
        raise ArgumentError, "reason required" if reason.to_s.strip.empty?
        raise ArgumentError, "actor required" if actor.to_s.strip.empty?

        id = case_id(organization, flag)
        FileUtils.mkdir_p(File.dirname(@path), mode: 0o750)
        File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o640) do |lock|
          lock.flock(File::LOCK_EX)
          data = read
          data["decisions"] ||= {}
          data["decisions"][id] ||= { "organization_id" => organization.id, "type" => flag.fetch(:type).to_s,
                                      "severity" => flag.fetch(:severity).to_s, "count" => flag[:count],
                                      "outcome" => outcome.to_s, "reason" => reason.to_s.strip,
                                      "actor" => actor.to_s.strip, "decided_at" => Time.now.utc.iso8601 }
          write(data)
        end
        id
      end

      private

      def referral_evidence(organization, flag)
        return unless flag.fetch(:type).to_s == "referral_cluster"
        return unless defined?(Decidim::Bih::Goodwill::Referral)

        # Include the underlying rewarded referrals, so replacing one invitee
        # with another at the same count still reopens the case.
        Decidim::Bih::Goodwill::Referral.where(organization:, referrer_id: flag.fetch(:user).id, status: "rewarded")
                                        .where("rewarded_at >= ?", 30.days.ago)
                                        .order(:id).pluck(:id, :rewarded_at)
      end

      def read
        File.exist?(@path) ? JSON.parse(File.read(@path)) : { "decisions" => {} }
      end

      def write(data)
        temporary = "#{@path}.#{Process.pid}.tmp"
        File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o640) do |file|
          file.write(JSON.generate(data))
          file.flush
          file.fsync
        end
        # Rename replaces the inode and its ACL. Grant the health-check user
        # read access before promotion, so a later decision cannot revive an
        # already-reviewed alert.
        if @runtime_reader && !system("setfacl", "-m", "u:#{@runtime_reader}:r--", temporary, out: File::NULL, err: File::NULL)
          raise IOError, "cannot grant runtime access to Goodwill decisions"
        end
        File.rename(temporary, @path)
      ensure
        File.delete(temporary) if temporary && File.exist?(temporary)
      end
    end
  end
end
