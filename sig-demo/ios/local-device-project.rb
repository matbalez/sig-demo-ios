# Copyright 2026 Sig Demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'pathname'
require 'xcodeproj'

module SigDemoLocalDeviceProject
  def self.configure(project:, output:, package:, models:, mesh_package: nil, testflight: false)
    raise 'Use an owned private device build directory.' unless output.to_s.match?(%r{\A/private/tmp/sig-demo-ios-device-build-[[:alnum:]]+\z}) && output.stat.uid == Process.uid && !output.symlink?
    # LocalModel's manifest references its sibling NativeAgent. An explicitly
    # staged package must resolve to the same identity as the app's direct one.
    native_agent = package.parent.join('NativeAgent')
    canonical_agent = Pathname(__dir__).join('NativeAgent').realpath
    project.root_object.package_references.each do |reference|
      next unless reference.isa == 'XCLocalSwiftPackageReference' && Pathname(reference.relative_path).cleanpath == canonical_agent
      raise 'Missing sibling NativeAgent package.' unless native_agent.join('Package.swift').file?
      reference.relative_path = native_agent.to_s
    end
    deployment = '17.0'
    ios = Pathname.new(__dir__).realpath
    canonical_mesh = ios.join('Mesh')
    if mesh_package
      raise 'Use the qualified owned private Mesh package.' unless mesh_package.to_s.start_with?('/private/tmp/sig-demo-device-mesh-') && mesh_package.basename.to_s == 'Mesh' && mesh_package.stat.uid == Process.uid && !mesh_package.symlink?
      sdk_parent = mesh_package.parent
    else
      mesh_package = canonical_mesh
      sdk_parent = ios.parent.parent.join('.sig-demo/ios')
    end
    mesh_pin = JSON.parse(canonical_mesh.join('source.lock.json').read)
    sdk = sdk_parent.join('mesh-sdk-v' + mesh_pin.fetch('version'))
    staged, error, status = Open3.capture3('python3', canonical_mesh.join('stage-device.py').to_s,
      '--mesh', mesh_package.to_s, '--sdk', sdk.to_s, '--parent', output.join('Packages').to_s, '--deployment', deployment)
    raise "Cannot stage the device Mesh package: #{error}" unless status.success?
    mesh_package = Pathname.new(staged.strip)
    project.root_object.package_references.each do |reference|
      next unless reference.isa == 'XCLocalSwiftPackageReference'
      path = Pathname.new(reference.relative_path).cleanpath
      if path == canonical_mesh
        reference.relative_path = mesh_package.to_s
      elsif path.to_s.start_with?(output.join('Packages/PaidMesh-').to_s)
        manifest = path.join('Package.swift')
        raise 'Invalid owned staged PaidMesh manifest.' if manifest.symlink? || manifest.stat.uid != Process.uid
        contents = manifest.read
        old = '.package(path: ' + JSON.generate(canonical_mesh.to_s) + ')'
        raise 'Unexpected staged PaidMesh dependency.' unless contents.scan(old).length == 1
        manifest.write(contents.sub(old, '.package(path: ' + JSON.generate(mesh_package.to_s) + ')'))
      end
    end
    %w[Signal SignalNSE SignalShareExtension].each do |name|
      target = project.targets.find { |item| item.name == name }
      release = target&.build_configurations&.find { |item| item.name == 'App Store Release' }
      debug = target&.build_configurations&.find { |item| item.name == 'Debug' }
      raise "Missing prepared Debug/release target: #{name}" unless release && debug
      debug.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = deployment
      release.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = deployment if testflight
      # Use the exact private device namespace/metadata already prepared by the
      # release helper; never substitute simulator identities or signing groups.
      %w[INFOPLIST_FILE CODE_SIGN_ENTITLEMENTS CURRENT_PROJECT_VERSION MARKETING_VERSION].each do |key|
        debug.build_settings[key] = release.build_settings.fetch(key)
      end
    end
    app = project.targets.find { |item| item.name == 'Signal' }
    debug = app.build_configurations.find { |item| item.name == 'Debug' }
    release = app.build_configurations.find { |item| item.name == 'App Store Release' }
    %w[ASSETCATALOG_COMPILER_APPICON_NAME ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS].each do |key|
      debug.build_settings[key] = release.build_settings.fetch(key)
    end
    debug.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos*]'] = '$(inherited) SIG_DEMO_LOCAL_MODEL'

    if testflight
      release.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos*]'] = '$(inherited) SIG_DEMO_LOCAL_MODEL'
    end

    pins = JSON.parse(package.join('source.lock.json').read).fetch('models')
    raise 'Expected one pinned local model.' unless pins.one?
    resources = output.join('LocalModels')
    raise 'Invalid local resource stage.' if resources.symlink? || (resources.exist? && (!resources.directory? || resources.stat.uid != Process.uid))
    FileUtils.mkdir_p(resources)
    sources = pins.map do |pin|
      filename = pin.fetch('filename')
      raise 'Invalid pinned local filename.' unless filename.match?(/\A[A-Za-z0-9_.-]+\.gguf\z/)
      source = models.join(filename)
      raise "Missing pinned local model: #{filename}" unless source.file? && !source.symlink? && source.size == pin.fetch('bytes')
      raise "Local model checksum mismatch: #{filename}" unless Digest::SHA256.file(source).hexdigest == pin.fetch('sha256')
      destination = resources.join(filename)
      raise 'Invalid staged model path.' if destination.symlink? || (destination.exist? && (!destination.file? || destination.stat.uid != Process.uid))
      unless destination.exist? && source.stat.ino == destination.stat.ino && source.stat.dev == destination.stat.dev
        temporary = resources.join(".#{filename}.#{Process.pid}.tmp")
        raise 'A model staging operation is already present.' if temporary.exist? || temporary.symlink?
        begin
          File.link(source, temporary)
          File.rename(temporary, destination)
        ensure
          File.unlink(temporary) if temporary.exist?
        end
      end
      destination
    end
    marker = resources.join('SigDemoLocalModelDevice.json')
    raise 'Invalid device marker destination.' if marker.symlink? || (marker.exist? && (!marker.file? || marker.stat.uid != Process.uid))
    marker.write(JSON.pretty_generate(schemaVersion: 1, engine: 'goose-local-inference',
      backend: 'metal', inProcess: true, debugOnly: !testflight, gpuRequired: true) + "\n")
    sources << marker
    sources << Pathname(__dir__).join('LocalModel/Licenses/LFM-Open-License.txt')
    reference = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
    reference.relative_path = package.to_s
    project.root_object.package_references << reference
    dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dependency.package = reference
    dependency.product_name = 'SigDemoLocalModel'
    app.package_product_dependencies << dependency
    product = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    product.product_ref = dependency
    app.frameworks_build_phase.files << product
    phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
    phase.name = testflight ? 'Bundle pinned local model (TestFlight)' : 'Bundle pinned local models (device Debug experiment)'
    phase.dst_subfolder_spec = '7'
    phase.dst_path = 'LocalModels'
    sources.each do |source|
      file = project.main_group.new_file(source.to_s, '<absolute>')
      phase.add_file_reference(file)
    end
    app.build_phases << phase
  end
end
