#!/usr/bin/env ruby

# setup_environments.rb
# Automated setup for multi-environment Xcode configuration
#
# This script configures the Xcode project with multiple environments:
# - Adds xcconfig files to the project
# - Creates build configurations (Debug-Local, Release-Local, Debug-Prod, Release-Prod)
# - Assigns xcconfig files to configurations
# - Creates schemes (CarQuiz-Local, CarQuiz-Prod)
#
# Requirements:
#   gem install xcodeproj
#
# Usage:
#   ruby setup_environments.rb

require 'xcodeproj'

PROJECT_PATH = 'CarQuiz.xcodeproj'
TARGET_NAME = 'CarQuiz'
CONFIG_DIR = 'Configuration'

# xcconfig file mappings
XCCONFIG_FILES = {
  'Shared.xcconfig' => nil,  # Shared config, not assigned to any specific configuration
  'Local.xcconfig' => ['Debug-Local', 'Release-Local'],
  'Prod.xcconfig' => ['Debug-Prod', 'Release-Prod']
}

# Scheme configurations
SCHEMES = {
  'CarQuiz-Local' => {
    debug_config: 'Debug-Local',
    release_config: 'Release-Local'
  },
  'CarQuiz-Prod' => {
    debug_config: 'Debug-Prod',
    release_config: 'Release-Prod'
  }
}

puts "🚀 Starting environment setup for CarQuiz..."
puts ""

# Open the project
project = Xcodeproj::Project.open(PROJECT_PATH)
main_target = project.targets.find { |t| t.name == TARGET_NAME }

unless main_target
  puts "❌ Error: Could not find target '#{TARGET_NAME}'"
  exit 1
end

puts "✅ Opened project: #{PROJECT_PATH}"
puts "✅ Found target: #{main_target.name}"
puts ""

# Step 1: Add xcconfig files to the project
puts "📁 Step 1: Adding xcconfig files to project..."

config_group = project.main_group.find_subpath(CONFIG_DIR, true)
config_group.set_source_tree('SOURCE_ROOT')

XCCONFIG_FILES.keys.each do |filename|
  file_path = "#{CONFIG_DIR}/#{filename}"

  # Check if file reference already exists
  existing_file = config_group.files.find { |f| f.path == filename }

  if existing_file
    puts "  ⚠️  File reference already exists: #{filename}"
  else
    file_ref = config_group.new_reference(file_path)
    file_ref.source_tree = '<group>'
    puts "  ✅ Added: #{filename}"
  end
end

puts ""

# Step 2: Create build configurations
puts "⚙️  Step 2: Creating build configurations..."

project.build_configurations.each do |config|
  puts "  Existing: #{config.name}"
end

# Create new configurations by duplicating existing ones
configurations_to_create = {
  'Debug-Local' => 'Debug',
  'Release-Local' => 'Release',
  'Debug-Prod' => 'Debug',
  'Release-Prod' => 'Release'
}

configurations_to_create.each do |new_config_name, base_config_name|
  existing = project.build_configurations.find { |c| c.name == new_config_name }

  if existing
    puts "  ⚠️  Configuration already exists: #{new_config_name}"
  else
    base_config = project.build_configurations.find { |c| c.name == base_config_name }
    new_config = project.add_build_configuration(new_config_name, base_config.type)

    # Copy build settings from base configuration
    new_config.build_settings = base_config.build_settings.dup

    puts "  ✅ Created: #{new_config_name} (based on #{base_config_name})"
  end
end

puts ""

# Step 3: Assign xcconfig files to configurations
puts "🔗 Step 3: Assigning xcconfig files to configurations..."

# First, let's find all xcconfig file references in the project
all_file_refs = project.files.select { |f| f.path.to_s.end_with?('.xcconfig') }

XCCONFIG_FILES.each do |filename, config_names|
  next unless config_names  # Skip Shared.xcconfig

  # Find the file reference by path
  file_ref = all_file_refs.find { |f| f.path.to_s.include?(filename) }

  unless file_ref
    puts "  ❌ Error: Could not find file reference for #{filename}"
    puts "     Available files: #{all_file_refs.map(&:path).join(', ')}"
    next
  end

  config_names.each do |config_name|
    config = main_target.build_configurations.find { |c| c.name == config_name }

    if config
      config.base_configuration_reference = file_ref
      puts "  ✅ Assigned #{filename} to #{config_name}"
    else
      puts "  ❌ Configuration not found: #{config_name}"
    end
  end
end

puts ""

# Step 4: Create schemes
puts "📋 Step 4: Creating schemes..."

SCHEMES.each do |scheme_name, configs|
  scheme_path = Xcodeproj::XCScheme.shared_data_dir(project.path) + "#{scheme_name}.xcscheme"

  if File.exist?(scheme_path)
    puts "  ⚠️  Scheme already exists: #{scheme_name}"
  else
    scheme = Xcodeproj::XCScheme.new
    scheme.add_build_target(main_target)

    # Set build configuration for each action
    scheme.launch_action.build_configuration = configs[:debug_config]
    scheme.test_action.build_configuration = configs[:debug_config]
    scheme.profile_action.build_configuration = configs[:debug_config]
    scheme.analyze_action.build_configuration = configs[:debug_config]
    scheme.archive_action.build_configuration = configs[:release_config]

    # Save as shared scheme
    scheme.save_as(project.path, scheme_name, true)
    puts "  ✅ Created shared scheme: #{scheme_name}"
    puts "     - Debug/Run/Test: #{configs[:debug_config]}"
    puts "     - Archive: #{configs[:release_config]}"
  end
end

puts ""

# Step 5: Save the project
puts "💾 Saving project..."
project.save
puts "✅ Project saved successfully!"
puts ""

# Summary
puts "=" * 60
puts "🎉 Environment setup complete!"
puts "=" * 60
puts ""
puts "Next steps:"
puts "  1. Open CarQuiz.xcodeproj in Xcode"
puts "  2. Select scheme: 'CarQuiz-Local' or 'CarQuiz-Prod'"
puts "  3. Build and run (Cmd+R)"
puts ""
puts "Schemes available:"
puts "  • CarQuiz-Local  → http://localhost:8002"
puts "  • CarQuiz-Prod   → https://quiz-agent-api.fly.dev"
puts ""
puts "For CI/CD:"
puts "  xcodebuild -scheme CarQuiz-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build"
puts "  xcodebuild -scheme CarQuiz-Prod -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build"
puts ""
puts "See SETUP_ENVIRONMENTS.md for detailed documentation."
puts ""
