#!/usr/bin/env ruby
require 'digest'
require 'json'
require 'open3'

# SwiftPM checkouts are read-only by default. Change only the pinned patch's files.
def patch_generator(package, swift_options)
  output, errors, status = Open3.capture3('swift', 'package', *swift_options, '--package-path', package,
                                        'show-dependencies', '--format', 'json')
  abort errors unless status.success?
  dependencies = JSON.parse(output).fetch('dependencies')
  generator = dependencies.find { |entry| entry.fetch('identity') == 'swift-openapi-generator' }
  abort 'Pinned Apple generator checkout not found' unless generator
  abort 'Unexpected Apple generator version' unless generator.fetch('version') == '1.14.0'
  checkout = generator.fetch('path')
  directory = File.join(package, 'Patches')
  checksums = JSON.parse(File.read(File.join(directory, 'checksums.json')))
  states = checksums.map do |path, hashes|
    digest = Digest::SHA256.file(File.join(checkout, path)).hexdigest
    hashes.key(digest) || abort("Unexpected generator source: #{path}")
  end
  return if states.all? { |state| state == 'patched' }
  abort 'Generator is partially patched' unless states.all? { |state| state == 'original' }
  checksums.each_key { |path| File.chmod(0644, File.join(checkout, path)) }
  patch = File.join(directory, 'forward-compatible-models.patch')
  output, errors, status = Open3.capture3('git', 'apply', '--check', patch, chdir: checkout)
  abort output + errors unless status.success?
  output, errors, status = Open3.capture3('git', 'apply', patch, chdir: checkout)
  abort output + errors unless status.success?
  checksums.each do |path, hashes|
    abort "Patch checksum mismatch: #{path}" unless Digest::SHA256.file(File.join(checkout, path)).hexdigest == hashes.fetch('patched')
  end
end
