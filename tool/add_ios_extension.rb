#!/usr/bin/env ruby
# Adds the FlClashService NetworkExtension app-extension target to a Flutter
# Runner.xcodeproj and links the gomobile FlClashCore.xcframework. Also wires
# the Runner host app's bundle id and entitlements.
# Usage: ruby add_ios_extension.rb <Runner.xcodeproj> <bundle_id> <app_group> <xcframework>

require 'xcodeproj'
require 'fileutils'

abort "usage: #{$PROGRAM_NAME} <xcodeproj> <bundle_id> <app_group> <xcframework>" if ARGV.length < 4

proj_path = ARGV[0]
bundle_id = ARGV[1]
app_group = ARGV[2]
xcfw_path = ARGV[3]

abort "missing project: #{proj_path}" unless File.directory?(proj_path)
abort "missing xcframework: #{xcfw_path}" unless File.directory?(xcfw_path)

project = Xcodeproj::Project.open(proj_path)
ios_dir = File.dirname(proj_path)

runner_target = project.targets.find { |t| t.name == 'Runner' }
abort "Runner target not found" unless runner_target

# --- Configure Runner host app: bundle id + entitlements ---
runner_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = bundle_id
  # Unsigned CI build: the IPA is sideloaded (e.g. AltStore/TrollStore) and
  # signed by the user, so disable code signing for every target.
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
  config.build_settings['CODE_SIGN_IDENTITY'] = ''
  # Use our entitlements (App Group + Personal VPN) for the host app.
  runner_ent = File.join(ios_dir, 'Runner', 'Runner.entitlements')
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements' if File.exist?(runner_ent)
end

# --- Build the FlClashService extension target (if not already present) ---
ext_name = 'FlClashService'
if project.targets.any? { |t| t.name == ext_name }
  puts "target #{ext_name} already exists, skipping creation"
  project.save
  exit 0
end

ext_target = project.new_target(:app_extension, ext_name, :ios, '13.0')

ext_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{bundle_id}.FlClashService"
  config.build_settings['PRODUCT_NAME'] = ext_name
  config.build_settings['INFOPLIST_FILE'] = 'FlClashService/Info.plist'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'FlClashService/FlClashService.entitlements'
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
  config.build_settings['CODE_SIGN_IDENTITY'] = ''
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['ENABLE_BITCODE'] = 'NO'
  config.build_settings['SKIP_INSTALL'] = 'YES'
  config.build_settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  config.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = '$(PROJECT_DIR)'
end

# --- Add source files to the extension target ---
src_group = project.main_group.find_subpath('FlClashService', true)
%w[PacketTunnelProvider.swift VpnCore.swift].each do |name|
  path = File.join(ios_dir, 'FlClashService', name)
  abort "missing source: #{path}" unless File.exist?(path)
  ref = src_group.new_file(name)
  ext_target.source_build_phase.add_file_reference(ref)
end

# --- Link + embed FlClashCore.xcframework ---
framework_ref = src_group.new_file('FlClashCore.xcframework')
framework_ref.source_tree = 'SOURCE_ROOT'
framework_ref.path = 'FlClashCore.xcframework'

ext_target.frameworks_build_phase.add_file_reference(framework_ref)

embed_phase = ext_target.new_copy_files_build_phase('Embed Frameworks')
embed_phase.symbol_dst_subfolder_spec = :frameworks
embed_phase.dst_path = ''
embed_phase.add_file_reference(framework_ref)

# --- Embed the extension into the Runner app (PlugIns) ---
runner_embed = runner_target.copy_files_build_phases.find { |p| p.dst_subfolder_spec == '13' } ||
               runner_target.new_copy_files_build_phase('Embed App Extensions')
runner_embed.symbol_dst_subfolder_spec = :plug_ins
runner_embed.dst_path = ''

ext_product = ext_target.product_reference
ext_product.path = 'FlClashService.appex'
runner_embed.add_file_reference(ext_product)

runner_target.add_dependency(ext_target)

project.save

puts "Configured Runner (#{bundle_id}) and added #{ext_name} extension (#{bundle_id}.FlClashService)"
