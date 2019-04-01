#!/usr/bin/env ruby

require 'xcodeproj'
path_to_project = "./Carthage.xcodeproj"
project = Xcodeproj::Project.open(path_to_project)
test_target = project.targets.select{ |target| target.name == "CarthageKitTests" }.first
phase = test_target.new_shell_script_build_phase("Copy Test Resources")
phase.shell_script = "script/copy-test-resources \"$BUILT_PRODUCTS_DIR/$WRAPPER_NAME\""
project.save()