#!/usr/bin/env ruby
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../Tools/Generator/patch-generator'
check = false
swift_options = []
OptionParser.new do |options|
  options.on('--check') { check = true }
  options.on('--disable-sandbox') { swift_options << '--disable-sandbox' }
  options.on('--scratch-path PATH') { |path| swift_options.concat(['--scratch-path', path]) }
  options.on('--cache-path PATH') { |path| swift_options.concat(['--cache-path', path]) }
end.parse!
root = File.expand_path('..', __dir__)
source = File.join(root, 'Documentation/Reference/openapi.json')
reference = JSON.parse(File.read(File.join(root, 'Documentation/Reference/provenance.json')))
abort 'Pinned schema checksum mismatch' unless Digest::SHA256.file(source).hexdigest == reference.fetch('sha256')
patch_generator(File.join(root, 'Tools/Generator'), swift_options)
Dir.mktmpdir('openai-generation-') do |temporary|
  derived = File.join(temporary, 'openapi.json')
  report = File.join(temporary, 'adaptations.json')
  output = check ? File.join(temporary, 'Generated') : File.join(root, 'Sources/OpenAIAPI/Generated')
  commands = [
    ['ruby', File.join(root, 'Tools/Generator/prepare-schema.rb'), source, derived, report],
    ['swift', 'run', *swift_options, '--package-path', File.join(root, 'Tools/Generator'),
     'swift-openapi-generator', 'generate', derived,
     '--config', File.join(root, 'Tools/Generator/openapi-generator-config.yaml'), '--output-directory', output]
  ]
  diagnostics = +''
  commands.each do |command|
    stdout, stderr, status = Open3.capture3(*command)
    diagnostics << stdout << stderr
    abort diagnostics unless status.success?
  end
  abort "Generator skipped a schema or body:\n#{diagnostics}" if diagnostics.match?(/skipping/i)
  if check
    target_directory = File.join(root, 'Sources/OpenAIAPI/Generated')
    names = (Dir.glob(File.join(output, '*.swift')) + Dir.glob(File.join(target_directory, '*.swift'))).map { |file| File.basename(file) }.uniq
    differences = names.reject do |name|
      file = File.join(output, name)
      target = File.join(target_directory, name)
      File.exist?(file) && File.exist?(target) && File.binread(file) == File.binread(target)
    end
    abort "Generated source differs: #{differences.join(', ')}" unless differences.empty?
  else
    FileUtils.cp(report, File.join(root, 'Documentation/Reference/generator-adaptations.json'))
    File.write(File.join(root, 'Documentation/Reference/generator-diagnostics.log'), diagnostics)
  end
  puts check ? 'Generated API matches the pinned schema and overlay' : 'Generated API updated; no skipped schemas or request bodies'
end
