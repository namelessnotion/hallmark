# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = true
end

namespace :alloy do
  desc "Download the pinned Alloy jar and verify its checksum"
  task :install do
    require_relative "lib/hallmark"
    puts Hallmark::AlloyInstaller.new.install
  end
end

task default: :test
