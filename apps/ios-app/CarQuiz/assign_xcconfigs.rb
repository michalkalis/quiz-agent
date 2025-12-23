#!/usr/bin/env ruby

# assign_xcconfigs.rb
# Assigns xcconfig files to build configurations
#
# Usage:
#   ruby assign_xcconfigs.rb

require 'xcodeproj'

PROJECT_PATH = 'CarQuiz.xcodeproj'
TARGET_NAME = 'CarQuiz'

puts "🔧 Assigning xcconfig files to configurations..."

# Open the project
project = Xcodeproj::Project.open(PROJECT_PATH)
main_target = project.targets.find { |t| t.name == TARGET_NAME }

# Find xcconfig file references
local_xcconfig = project.files.find { |f| f.path.to_s =~ /Local\.xcconfig$/ && !f.path.to_s.include?('Shared') }
prod_xcconfig = project.files.find { |f| f.path.to_s =~ /Prod\.xcconfig$/ && !f.path.to_s.include?('Shared') }

puts "Found xcconfig files:"
puts "  Local: #{local_xcconfig&.path}"
puts "  Prod: #{prod_xcconfig&.path}"
puts ""

# Assign to target configurations
assignments = {
  'Debug-Local' => local_xcconfig,
  'Release-Local' => local_xcconfig,
  'Debug-Prod' => prod_xcconfig,
  'Release-Prod' => prod_xcconfig
}

assignments.each do |config_name, xcconfig_file|
  config = main_target.build_configurations.find { |c| c.name == config_name }

  if config && xcconfig_file
    config.base_configuration_reference = xcconfig_file
    puts "✅ Assigned #{xcconfig_file.path} to #{config_name}"
  elsif !config
    puts "❌ Configuration not found: #{config_name}"
  elsif !xcconfig_file
    puts "❌ xcconfig file not found for #{config_name}"
  end
end

puts ""
puts "💾 Saving project..."
project.save
puts "✅ Done!"
