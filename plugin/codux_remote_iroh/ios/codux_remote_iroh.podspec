Pod::Spec.new do |s|
  s.name             = 'codux_remote_iroh'
  s.version          = '0.1.0'
  s.summary          = 'Iroh remote transport bridge for Codux Mobile'
  s.description      = 'Rust-backed Iroh transport bridge for Codux Mobile remote sessions.'
  s.homepage         = 'https://github.com/duxweb/codux-flutter'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Dux' => 'dev@dux.cn' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.platform         = :ios, '16.0'
  s.swift_version    = '5.0'
  s.vendored_frameworks = 'Rust/CoduxRemoteIrohBridge.xcframework'
  s.frameworks       = 'SystemConfiguration'

  s.prepare_command = <<-CMD
    set -euo pipefail
    ../../../scripts/build-ios-iroh-bridge.sh
  CMD

  s.dependency 'Flutter'
end
