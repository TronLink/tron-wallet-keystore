#
# Be sure to run `pod lib lint TronWalletKeystore.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'TronWalletKeystore'
  s.version          = '1.0.0'
  s.summary          = 'A general-purpose Tron keystore for managing wallets.'

  s.homepage         = 'https://github.com/TronLink/TronWalletKeystore'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = 'tronlinkdev'
  s.source           = { :git => 'https://github.com/TronLink/TronWalletKeystore.git', :tag => s.version.to_s }
  s.platform = :ios, '10.0'
  s.ios.deployment_target = '10.0'
  
  s.module_name = 'TronKeystore'
  s.source_files = 'TronWalletKeystore/Classes/**/*'
  s.dependency 'BigInt'
  s.dependency 'CryptoSwift'
  s.dependency 'TrezorCrypto'
  s.dependency 'TronCore'

  s.pod_target_xcconfig = { 'SWIFT_OPTIMIZATION_LEVEL' => '-Owholemodule' }
end
