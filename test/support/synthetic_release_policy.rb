# frozen_string_literal: true

# A test-owned example policy, never copied to the runtime policy path. This
# wraps setup, test and teardown because approval validity is checked at more
# than one boundary. It records no real test result or deployment approval.
module SyntheticReleasePolicy
  def run
    model = Decidim::Bih::GovernanceApproval
    path = Rails.root.join("config/examples/release-approval-policy.example.yml")
    policy = YAML.safe_load_file(path)
    digest = Digest::SHA256.file(path).hexdigest
    model.stub(:local_verification_policy, policy) do
      model.stub(:local_verification_policy_sha256, digest) { super }
    end
  end
end
