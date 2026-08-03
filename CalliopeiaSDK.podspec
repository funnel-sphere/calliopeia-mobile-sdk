Pod::Spec.new do |spec|
  spec.name = 'CalliopeiaSDK'
  spec.version = '0.1.0'
  spec.summary = 'High-fidelity recording and Calliopeia audio-analysis API client for iOS.'
  spec.description = <<-DESC
    CalliopeiaSDK records an unprocessed audio master, submits it to Calliopeia,
    and retrieves structured extraction and audit results.
  DESC
  spec.homepage = 'https://github.com/funnel-sphere/calliopeia-mobile-sdk'
  spec.license = { type: 'Apache-2.0', file: 'LICENSE' }
  spec.author = { 'FunnelSphere' => 'https://github.com/funnel-sphere' }
  spec.source = {
    git: 'https://github.com/funnel-sphere/calliopeia-mobile-sdk.git',
    tag: spec.version.to_s
  }
  spec.ios.deployment_target = '15.0'
  spec.swift_version = '5.9'
  spec.source_files = 'ios/Sources/**/*.swift'
  spec.frameworks = 'AVFoundation', 'AudioToolbox'
end
