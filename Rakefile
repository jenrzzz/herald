require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.pattern = "test/*_test.rb"
  t.warning = false
end

desc "Read the real Messages database on this Mac through the API (reads only; sends nothing)"
task :live do
  ruby "test/live/smoke.rb"
end

task default: :test
