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

namespace :fixtures do
  desc "Re-run the MediumClone example through Alloy and refresh test/fixtures/medium_clone"
  task :regenerate do
    require_relative "lib/hallmark"
    load File.expand_path("examples/medium_clone/hallmark.rb", __dir__)
    model = Hallmark::ModelBuilder.new(Hallmark.analyses.last).build
    output = File.expand_path("test/fixtures/medium_clone", __dir__)
    receipt = Hallmark::Solver::CLI.new.solve_into(model, output)
    found = receipt.commands.values.count(&:counterexample?)
    puts "Wrote #{output} (#{receipt.commands.size} checks, #{found} counterexamples)"
  end
end

task default: :test
