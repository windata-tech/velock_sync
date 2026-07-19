#!/usr/bin/env ruby

require "fileutils"
require "xcodeproj"

root = File.expand_path("../..", __dir__)
harness = File.join(root, "ui_test_harness")
project_path = File.join(harness, "CrossAppUITests.xcodeproj")

FileUtils.rm_rf(project_path) if File.exist?(project_path)

project = Xcodeproj::Project.new(project_path)
project.root_object.attributes["LastUpgradeCheck"] = "2660"
project.root_object.attributes["ORGANIZATIONNAME"] = "Velock"

main_group = project.main_group
host_group = main_group.new_group("HostApp", "HostApp")
tests_group = main_group.new_group("CrossAppUITests", "CrossAppUITests")

host_target = project.new_target(
  :application,
  "CrossAppUITestHost",
  :ios,
  "16.4"
)
host_target.product_name = "CrossAppUITestHost"

tests_target = project.new_target(
  :ui_test_bundle,
  "CrossAppUITests",
  :ios,
  "16.4"
)
tests_target.product_name = "CrossAppUITests"

host_source = host_group.new_file("AppDelegate.swift")
host_info = host_group.new_file("Info.plist")
tests_source = tests_group.new_file("CrossAppUITests.swift")

host_target.add_file_references([host_source])
tests_target.add_file_references([tests_source])

host_target.build_configurations.each do |config|
  config.build_settings.update(
    "PRODUCT_BUNDLE_IDENTIFIER" => "tech.windata.velock.crossapp.uitest.host",
    "INFOPLIST_FILE" => "HostApp/Info.plist",
    "SWIFT_VERSION" => "5.0",
    "TARGETED_DEVICE_FAMILY" => "1,2",
    "IPHONEOS_DEPLOYMENT_TARGET" => "16.4",
    "SDKROOT" => "iphoneos",
    "CODE_SIGNING_ALLOWED" => "NO",
    "CODE_SIGNING_REQUIRED" => "NO",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "",
    "SUPPORTED_PLATFORMS" => "iphoneos iphonesimulator"
  )
end

tests_target.build_configurations.each do |config|
  config.build_settings.update(
    "PRODUCT_BUNDLE_IDENTIFIER" => "tech.windata.velock.crossapp.uitests",
    "INFOPLIST_FILE" => "",
    "SWIFT_VERSION" => "5.0",
    "TARGETED_DEVICE_FAMILY" => "1,2",
    "IPHONEOS_DEPLOYMENT_TARGET" => "16.4",
    "SDKROOT" => "iphoneos",
    "CODE_SIGNING_ALLOWED" => "NO",
    "CODE_SIGNING_REQUIRED" => "NO",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "SUPPORTED_PLATFORMS" => "iphoneos iphonesimulator"
  )
end

frameworks = tests_target.frameworks_build_phase
xctest = project.frameworks_group.new_file("System/Library/Frameworks/XCTest.framework")
frameworks.add_file_reference(xctest)

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(host_target, tests_target, launch_target: true)
scheme.save_as(project_path, "CrossAppUITests", true)

project.save
puts project_path
