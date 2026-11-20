#!/usr/bin/env ruby
# Copyright 2026 Sig Demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
require 'optparse'
require 'pathname'
require_relative 'local-device-project'

options = {}
OptionParser.new do |parser|
  parser.on('--checkout PATH') { |value| options[:checkout] = value }
  parser.on('--output PATH') { |value| options[:output] = value }
  parser.on('--version VERSION') { |value| options[:version] = value }
  parser.on('--build-number NUMBER') { |value| options[:build] = value }
  parser.on('--local-models PATH') { |value| options[:models] = value }
  parser.on('--mesh-package PATH') { |value| options[:mesh_package] = value }
  parser.on('--testflight') { options[:testflight] = true }
  parser.on('--source-archive PATH') { |value| options[:source_archive] = value }
  parser.on('--source-sha256 SHA') { |value| options[:source_sha256] = value }
  parser.on('--paid-framework PATH') { |value| options[:paid_framework] = value }
  parser.on('--local-model-package PATH') { |value| options[:package] = value }
end.parse!
raise 'Checkout, output, version, build number and local models are required.' unless options.values_at(:checkout, :output, :version, :build, :models).all?
checkout = Pathname.new(options[:checkout]).realpath
output = Pathname.new(options[:output]).realpath
package = Pathname.new(options[:package] || File.join(__dir__, 'LocalModel')).realpath
models = Pathname.new(options[:models]).realpath
base_project = [RbConfig.ruby, File.join(__dir__, 'prepare-device-project.rb'), '--checkout', checkout.to_s,
  '--output', output.to_s, '--version', options[:version], '--build-number', options[:build]]
base_project += ['--local-device-paid-framework', options[:paid_framework]] if options[:paid_framework]
base_project += ['--source-archive', options[:source_archive]] if options[:source_archive]
base_project += ['--source-sha256', options[:source_sha256]] if options[:source_sha256]
system(*base_project, exception: true)
project_path = output.join('Signal.xcodeproj')
project = Xcodeproj::Project.open(project_path)
SigDemoLocalDeviceProject.configure(project: project, output: output, package: package, models: models, testflight: !!options[:testflight], mesh_package: options[:mesh_package] && Pathname.new(options[:mesh_package]).realpath)
project.save(project_path)
puts "Prepared isolated in-process GDK Metal device project at #{project_path}"
