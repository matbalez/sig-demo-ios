#!/usr/bin/env ruby
# Copyright 2026 sig demo contributors
# SPDX-License-Identifier: AGPL-3.0-only

require 'fileutils'
require 'pathname'
require 'xcodeproj'

ios = Pathname.new(__dir__).realpath
root = ios.join('../..').realpath
update_overlays = ARGV.delete('--update-overlays')
checkout = Pathname.new(ARGV[0] || root.join('.sig-demo/ios/chatgpt/Signal-iOS')).realpath
project = Xcodeproj::Project.open(checkout.join('Signal.xcodeproj'))

# New source is maintained alongside our patches, independently of the upstream
# checkout. Preserve local edits unless the maintainer explicitly requests an
# overlay refresh; inference credentials are never written by this script.
ios.join('overlays').glob('**/*.swift').each do |source|
  destination = checkout.join(source.relative_path_from(ios.join('overlays')))
  if destination.exist? && destination.binread != source.binread && !update_overlays
    raise "Local overlay edits were preserved at #{destination}; review them before using --update-overlays."
  end
  FileUtils.mkdir_p(destination.dirname)
  FileUtils.cp(source, destination)
end

def add_package(project, checkout, package_path, product_name, target_name)
  relative = package_path.relative_path_from(checkout).to_s
  reference = project.root_object.package_references.find do |item|
    item.isa == 'XCLocalSwiftPackageReference' && item.relative_path == relative
  end
  unless reference
    reference = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
    reference.relative_path = relative
    project.root_object.package_references << reference
  end
  target = project.targets.find { |item| item.name == target_name }
  raise "Missing upstream target #{target_name}" unless target
  dependency = target.package_product_dependencies.find { |item| item.product_name == product_name }
  unless dependency
    dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dependency.package = reference
    dependency.product_name = product_name
    target.package_product_dependencies << dependency
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = dependency
    target.frameworks_build_phase.files << build_file
  end
end

add_package(project, checkout, ios.join('SigDemoKit'), 'SigDemoKit', 'Signal')
add_package(project, checkout, ios.join('NativeAgent'), 'SigDemoAgent', 'Signal')
add_package(project, checkout, ios.join('Mesh'), 'SigDemoMesh', 'Signal')
add_package(project, checkout, ios.join('PaidMesh'), 'SigDemoPaidMesh', 'Signal')

group = project.main_group.find_subpath('SigDemo', true)
group.source_tree = '<group>'
%w[Signal SignalServiceKit].each do |name|
  target = project.targets.find { |item| item.name == name }
  checkout.join(name).glob('**/SigDemo*.swift').each do |source|
    relative = source.relative_path_from(checkout).to_s
    reference = project.files.find { |item| item.path == relative }
    reference ||= group.new_file(relative)
    unless target.source_build_phase.files_references.include?(reference)
      target.add_file_references([reference])
    end
  end
end

project.save
puts "Integrated native Sig demo packages and sources into #{checkout}"
