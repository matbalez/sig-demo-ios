#!/usr/bin/env ruby
# Copyright 2026 Sig Demo contributors
# SPDX-License-Identifier: AGPL-3.0-only

require 'fileutils'
require 'json'
require 'pathname'
require 'optparse'
require 'open3'
require 'time'
require 'digest'
require 'xcodeproj'

options = {}
OptionParser.new do |parser|
  parser.on('--checkout PATH') { |v| options[:checkout] = v }
  parser.on('--output PATH') { |v| options[:output] = v }
  parser.on('--version VERSION') { |v| options[:version] = v }
  parser.on('--build-number NUMBER') { |v| options[:build] = v }
  parser.on('--source-archive PATH') { |v| options[:source_archive] = v }
  parser.on('--source-sha256 SHA256') { |v| options[:source_sha256] = v }
end.parse!
raise 'All four options are required.' unless options.values_at(:checkout, :output, :version, :build).all?
raise 'Version must contain three nonnegative integer components.' unless options[:version].match?(/\A\d+\.\d+\.\d+\z/)
raise 'Build number must be a positive integer.' unless options[:build].match?(/\A[1-9]\d{0,8}\z/)
if options[:source_archive] || options[:source_sha256]
  raise 'Both corresponding-source options are required.' unless options[:source_archive] && options[:source_sha256]&.match?(/\A[a-f0-9]{64}\z/)
  source_archive = Pathname.new(options[:source_archive])
  raise 'The source archive must be an absolute regular file.' unless source_archive.absolute? && source_archive.file? && !source_archive.symlink?
  raise 'The corresponding source archive SHA256 does not match.' unless Digest::SHA256.file(source_archive).hexdigest == options[:source_sha256]
end

ios = Pathname.new(__dir__).realpath
checkout = Pathname.new(options[:checkout]).realpath
output = Pathname.new(options[:output]).realpath
raise 'Output must be an owned private temporary device build directory.' unless output.to_s.match?(%r{\A/private/tmp/sig-demo-ios-device-build-[[:alnum:]]+\z}) && output.stat.uid == Process.uid && !output.symlink?

project = Xcodeproj::Project.open(checkout.join('Signal.xcodeproj'))
# The Pods closure is built separately. Scope its source-product lookup to that
# directory while preserving the archive target's canonical embed destination.
project.targets.each do |target|
  target.shell_script_build_phases.each do |phase|
    next unless phase.name == '[CP] Embed Pods Frameworks'
    script = phase.shell_script
    raise 'Unexpected CocoaPods framework embedding command.' unless script.start_with?('"${PODS_ROOT}/Target Support Files/Pods-') && script.strip.end_with?('-frameworks.sh"')
    phase.shell_script = 'BUILT_PRODUCTS_DIR="${PODS_CONFIGURATION_BUILD_DIR}" ' + script
    phase.input_paths = phase.input_paths.map { |path| path.gsub('${BUILT_PRODUCTS_DIR}', '${PODS_CONFIGURATION_BUILD_DIR}') }
  end
end
# A generated project keeps the reviewed source checkout unchanged. Both the
# root group and PROJECT_DIR remain anchored to that checkout after relocation.
project.root_object.project_dir_path = checkout.to_s
project.main_group.source_tree = '<absolute>'
project.main_group.path = checkout.to_s
catalogs = project.files.select { |item| item.path&.end_with?('.xcassets') }
catalog_paths = catalogs.map { |item| item.real_path.relative_path_from(checkout).to_s }
asset_stage, error, status = Open3.capture3('python3', ios.join('prepare-device-assets.py').to_s, ios.to_s, checkout.to_s, output.to_s, *catalog_paths)
raise "Cannot stage pinned public asset catalogs: #{error}" unless status.success?
catalogs.zip(catalog_paths).each do |reference, relative|
  reference.path = Pathname.new(asset_stage.strip).join(relative).to_s
  reference.source_tree = '<absolute>'
end
attributes = project.root_object.attributes.fetch('TargetAttributes', {})
attributes.each_value { |item| item.delete('DevelopmentTeam') }
paid_package, error, status = Open3.capture3('python3', ios.join('prepare-device-package.py').to_s, ios.to_s, output.to_s)
raise "Cannot stage release SDK packaging: #{error}" unless status.success?
project.root_object.package_references.each do |reference|
  next unless reference.isa == 'XCLocalSwiftPackageReference'
  original = checkout.join(reference.relative_path).cleanpath
  reference.relative_path = original == ios.join('PaidMesh') ? paid_package.strip : original.to_s
end

metadata = output.join('ReleaseMetadata')
FileUtils.mkdir_p(metadata)
if source_archive
  source_resource = metadata.join('SigDemoSource.tar.gz')
  raise 'The source resource destination must be an owned regular file.' if source_resource.symlink? || (source_resource.exist? && (!source_resource.file? || source_resource.stat.uid != Process.uid))
  # Publish a complete fresh file before Xcode sees this immutable resource.
  staging = metadata.join(".SigDemoSource-#{Process.pid}.tar.gz")
  FileUtils.copy_file(source_archive, staging)
  raise 'The staged source archive SHA256 does not match.' unless Digest::SHA256.file(staging).hexdigest == options[:source_sha256]
  File.rename(staging, source_resource)
end
entitlements = ios.join('release/Signal.entitlements').to_s
timestamp = Time.now.utc
%w[Signal SignalNSE SignalShareExtension].each do |name|
  target = project.targets.find { |item| item.name == name }
  raise "Missing native target #{name}" unless target
  config = target.build_configurations.find { |item| item.name == 'App Store Release' }
  raise "Missing release configuration for #{name}" unless config
  attributes[target.uuid] ||= {}
  attributes[target.uuid]['ProvisioningStyle'] = 'Automatic'
  attributes[target.uuid]['SystemCapabilities'] = {
    'com.apple.ApplicationGroups.iOS' => { 'enabled' => 1 },
    'com.apple.DataProtection' => { 'enabled' => 1 },
    'com.apple.Keychain' => { 'enabled' => 1 }
  }
  source = name == 'Signal' ? checkout.join('Signal/Signal-Info.plist') : checkout.join(name, 'Info.plist')
  # plistlib performs a normal bounded file read; plutil may coordinate a read
  # with FileProvider even when this public source file is fully hydrated.
  contents, error, status = Open3.capture3('python3', '-c', 'import json,plistlib,sys; print(json.dumps(plistlib.load(open(sys.argv[1], "rb"))))', source.to_s)
  raise "Cannot read release Info.plist: #{error}" unless status.success?
  info = JSON.parse(contents)
  # This private demo needs its own export-compliance determination. Omit the
  # inherited declaration so App Store Connect asks the owner its questions.
  info.delete('ITSAppUsesNonExemptEncryption')
  info['CFBundleShortVersionString'] = options[:version]
  info['CFBundleVersion'] = options[:build]
  if name == 'Signal'
    if source_resource
      info['SigDemoSourceArchive'] = 'SigDemoSource.tar.gz'
      info['SigDemoSourceSHA256'] = options[:source_sha256]
    else
      info.delete('SigDemoSourceArchive')
      info.delete('SigDemoSourceSHA256')
    end
    info.each do |key, value|
      info[key] = value.gsub(/\bSignal\b/, 'SigDemo') if key.match?(/\ANS[A-Za-z]+UsageDescription\z/) && value.is_a?(String)
    end
    info['BuildDetails'] = {
      'Timestamp' => timestamp.to_i,
      'DateTime' => timestamp.iso8601,
      'SignalCommit' => JSON.parse(ios.join('upstream.lock.json').read).fetch('commit'),
      'SignalVersion' => JSON.parse(ios.join('upstream.lock.json').read).fetch('tag')
    }
  end
  destination = metadata.join("#{name}-Info.plist")
  _, error, status = Open3.capture3('python3', '-c', 'import json,plistlib,sys; plistlib.dump(json.load(sys.stdin), open(sys.argv[1], "wb"))', destination.to_s, stdin_data: JSON.generate(info))
  raise "Cannot write release Info.plist: #{error}" unless status.success?
  config.build_settings['INFOPLIST_FILE'] = destination.to_s
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = entitlements
  config.build_settings['CURRENT_PROJECT_VERSION'] = options[:build]
  config.build_settings['MARKETING_VERSION'] = options[:version]
end

# Permission localizations may override the main Info.plist. Copy only those
# resource files, changing app-name mentions in permission/display-name values.
project.files.select { |item| item.path&.end_with?('InfoPlist.strings') }.each do |reference|
  source = reference.real_path
  next unless source.file?
  data = source.binread
  if data.start_with?("\xFF\xFE".b)
    encoding, prefix, text = 'UTF-16LE', "\xFF\xFE".b, data.byteslice(2..).force_encoding('UTF-16LE').encode('UTF-8')
  elsif data.start_with?("\xFE\xFF".b)
    encoding, prefix, text = 'UTF-16BE', "\xFE\xFF".b, data.byteslice(2..).force_encoding('UTF-16BE').encode('UTF-8')
  else
    encoding, prefix, text = 'UTF-8', ''.b, data.force_encoding('UTF-8')
  end
  modified = text.gsub(/((?:"?(?:NS[A-Za-z]+UsageDescription|CFBundleDisplayName)"?)\s*=\s*")((?:\\.|[^"\\])*)(")/) do
    match = Regexp.last_match
    match[1] + match[2].gsub(/\bSignal\b/, 'SigDemo') + match[3]
  end
  destination = metadata.join('LocalizedInfo', source.relative_path_from(checkout))
  FileUtils.mkdir_p(destination.dirname)
  destination.binwrite(prefix + modified.encode(encoding).b)
  reference.path = destination.to_s
  reference.source_tree = '<absolute>'
end

app = project.targets.find { |item| item.name == 'Signal' }
if source_resource
  reference = project.main_group.new_file(source_resource.to_s)
  reference.source_tree = '<absolute>'
  app.resources_build_phase.add_file_reference(reference)
end
# The upstream phase edits the source Info.plist. Metadata above already records
# this release, so the temporary project does not run that mutating phase.
app.shell_script_build_phases.select { |phase| phase.name == 'Run Script: update_plist_info' }.each(&:remove_from_project)
branding = ios.join('branding/SigDemo.xcassets')
raise 'The distinct Sig Demo release app icon is missing.' unless branding.join('SigDemoAppIcon.appiconset/Contents.json').file?
reference = project.main_group.new_file(branding.to_s)
reference.source_tree = '<absolute>'
app.resources_build_phase.add_file_reference(reference)
release = app.build_configurations.find { |item| item.name == 'App Store Release' }
release.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'SigDemoAppIcon'
release.build_settings['ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES'] = ''
release.build_settings['ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS'] = 'NO'

destination = output.join('Signal.xcodeproj')
project.save(destination)
schemes = destination.join('xcshareddata/xcschemes')
FileUtils.mkdir_p(schemes)
scheme = checkout.join('Signal.xcodeproj/xcshareddata/xcschemes/Signal.xcscheme').read
# projectDirPath keeps source/build scripts anchored to the checkout; use an
# absolute scheme container so archive resolves targets in this generated PBX.
scheme = scheme.gsub('container:Signal.xcodeproj', "container:#{destination}")
schemes.join('Signal.xcscheme').write(scheme)
puts "Prepared isolated device release project at #{destination}"
