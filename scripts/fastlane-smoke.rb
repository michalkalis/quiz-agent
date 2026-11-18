# Offline smoke of the gems the TestFlight lanes lean on, so a fastlane bundle
# bump (Dependabot) is proven without secrets or an upload (#207 task 207.25).
# Run from apps/ios-app/Hangs: bundle exec ruby ../../../scripts/fastlane-smoke.rb
require "fastlane"
require "spaceship"
require "openssl"
require "tmpdir"
require "zip"

# 1. App Store Connect API token: ES256 JWT signed with a throwaway key (jwt).
key = OpenSSL::PKey::EC.generate("prime256v1").to_pem
token = Spaceship::ConnectAPI::Token.create(key_id: "SMOKE12345", issuer_id: "00000000-0000-0000-0000-000000000000", key: key)
header = JWT.decode(token.text, nil, false).last
raise "unexpected JWT header #{header}" unless header["alg"] == "ES256" && header["kid"] == "SMOKE12345"

# 2. IPA metadata read, as pilot/deliver do before an upload (rubyzip).
Dir.mktmpdir do |dir|
  ipa = File.join(dir, "Smoke.ipa")
  plist = { "CFBundleIdentifier" => "com.example.smoke", "CFBundleShortVersionString" => "1.2", "CFBundleVersion" => "34" }
  Zip::File.open(ipa, create: true) { |z| z.get_output_stream("Payload/Smoke.app/Info.plist") { |f| f.write(Plist::Emit.dump(plist)) } }
  got = [FastlaneCore::IpaFileAnalyser.fetch_app_identifier(ipa), FastlaneCore::IpaFileAnalyser.fetch_app_version(ipa), FastlaneCore::IpaFileAnalyser.fetch_app_build(ipa)]
  raise "IPA analyser read #{got}" unless got == ["com.example.smoke", "1.2", "34"]
end

versions = %w[fastlane jwt faraday rubyzip excon].map { |g| "#{g} #{Gem.loaded_specs.fetch(g).version}" }
puts "fastlane smoke OK: #{versions.join(', ')}"
