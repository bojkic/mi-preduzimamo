# frozen_string_literal: true

require "securerandom"
require Rails.root.join("installation/lib/recovery_fingerprint")
identity = ENV.fetch("MI_INSTALL_ID")
abort "Invalid recovery installation identity" unless identity.match?(/\Ami-[0-9a-f]{16}\z/)
redis = Redis.new(url: ENV.fetch("REDIS_URL"))
begin
  key = "mi-install:#{identity}:recovery-control"
  # A non-credential, fresh snapshot marker. DB/Rails/JWT secrets never change.
  redis.set(key, SecureRandom.hex(32)) if ARGV == ["prepare"]
  marker = redis.get(key)
  abort "Redis snapshot control is missing" unless marker&.match?(/\A[0-9a-f]{64}\z/)

  puts JSON.generate(MiRecoveryFingerprint.new.call.merge(redis_control_sha256: Digest::SHA256.hexdigest(marker)))
ensure
  redis.close
end
