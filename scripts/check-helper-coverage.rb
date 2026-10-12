#!/usr/bin/env ruby
# Check the public hand-written Go helper inventory separately from REST/schema coverage.
require 'pathname'
require 'digest'
require 'json'

reference = Pathname.new(ARGV.fetch(0) { abort 'Usage: check-helper-coverage.rb /path/to/openai-go' }).expand_path
root = Pathname.new(__dir__).parent
pin = '2922f3e8a846d561d85e4aabb90f017c2de10851'
provenance = JSON.parse(File.read(root.join('Documentation/Reference/go-helper-sources.json')))
abort 'Unexpected Go reference pin' unless provenance.fetch('revision') == pin
provenance.fetch('files').each do |file, checksum|
  abort "Go reference source checksum mismatch: #{file}" unless Digest::SHA256.file(reference.join(file)).hexdigest == checksum
end

# Methods are checked in their original files. Public Go Error/Unwrap methods map to Swift Error descriptions/causes.
groups = {
  'polling.go' => ['Resources/Polling.swift', { 'PollStatus' => 'pollStatus' }],
  'agents_message.go' => ['Agents/AgentMessage.swift', { 'OutputText' => 'outputText' }],
  'agents_stream.go' => ['Agents/AgentSessionStream.swift', {
    'Stream' => ['Agents/AgentsService+Streaming.swift', 'stream'], 'Next' => 'next', 'Current' => 'next', 'Err' => 'next', 'Close' => 'close'
  }],
  'beta_agents_result.go' => ['Agents/AgentTurnResult.swift', {
    'SessionID' => 'sessionID', 'TurnID' => 'turnID', 'OutputText' => 'outputText', 'Error' => 'description', 'Unwrap' => 'cause',
    'BetaAgentSessionFinalResult' => ['Agents/AgentSessionStream.swift', 'finalResult'],
    'BetaAgentSessionWithResultCollection' => ['Agents/AgentSessionStream.swift', 'withResultCollection'],
    'WithResultCollection' => ['Agents/AgentSessionStream.swift', 'withResultCollection'],
    'FinalResult' => ['Agents/AgentSessionStream.swift', 'finalResult']
  }],
  'beta_agents_output.go' => ['Agents/AgentOutput.swift', {
    'NewBetaAgentOutput' => 'init', 'Format' => 'format', 'Error' => 'description', 'Unwrap' => 'cause', 'ParseResult' => 'parseResult', 'FinalResult' => 'finalResult'
  }],
  'beta_agents_files.go' => ['Agents/AgentFiles.swift', {
    'Error' => 'description', 'Unwrap' => 'cause', 'Prepare' => 'prepareFiles', 'PrepareDirectory' => 'prepareDirectory',
    'Upload' => 'uploadEnvironmentFile', 'ForResult' => 'artifacts', 'Find' => 'find', 'Download' => 'download'
  }],
  'streamaccumulator.go' => ['Chat/ChatCompletionAccumulator.swift', {
    'AddChunk' => 'add', 'JustFinishedContent' => 'justFinishedContent', 'JustFinishedContentForChoice' => 'justFinishedContent',
    'JustFinishedRefusal' => 'justFinishedRefusal', 'JustFinishedRefusalForChoice' => 'justFinishedRefusal',
    'JustFinishedToolCall' => 'justFinishedToolCall', 'JustFinishedToolCallForChoice' => 'justFinishedToolCall'
  }],
  'responses/response_accumulator.go' => ['WebSocket/ResponseWebSocketAccumulator.swift', {
    'Reset' => 'reset', 'Snapshot' => 'snapshot', 'OutputText' => ['Responses/ResponseAccumulator.swift', 'outputText'], 'AddEvent' => 'add'
  }],
  'responses/response_accumulator_details.go' => ['WebSocket/ResponseWebSocketAccumulator.swift', { 'DetailedSnapshot' => 'detailedSnapshot' }]
}
count = 0
groups.each do |file, (swift_file, mapping)|
  exported = File.read(reference.join(file)).scan(/^func (?:\(([^\n]*?)\)\s+)?([A-Z]\w*)\s*(?:\[|\()/).filter_map do |receiver, name|
    type = receiver&.split&.last&.delete_prefix('*')
    name unless type && type.match?(/\A[a-z]/)
  end
  missing = exported.uniq - mapping.keys
  stale = mapping.keys - exported.uniq
  abort "#{file}: missing #{missing.inspect}; stale #{stale.inspect}" unless missing.empty? && stale.empty?
  mapping.each_value do |destination|
    target_file, symbol = destination.is_a?(Array) ? destination : [swift_file, destination]
    source = File.read(root.join('Sources/OpenAI', target_file))
    pattern = symbol == 'init' ? /\binit\(/ : /\b(?:func|var|let)\s+#{Regexp.escape(symbol)}\b/
    abort "Missing Swift helper #{target_file}:#{symbol}" unless source.match?(pattern)
  end
  count += exported.length
end

# These public wrappers live in generated Go service files and delegate to hand-written implementations.
wrappers = {
  'vectorstorefile.go' => { 'NewAndPoll' => 'createAndPoll', 'Upload' => 'uploadFile', 'UploadAndPoll' => 'uploadFileAndPoll' },
  'vectorstorefilebatch.go' => { 'NewAndPoll' => 'createAndPoll', 'UploadAndPoll' => 'uploadFileBatchAndPoll' },
  'video.go' => { 'NewAndPoll' => 'createAndPoll' }
}
swift_polling = File.read(root.join('Sources/OpenAI/Resources/Polling.swift'))
wrappers.each do |file, mapping|
  source = File.read(reference.join(file))
  mapping.each do |name, symbol|
    abort "Missing pinned Go wrapper #{file}:#{name}" unless source.match?(/^func \([^\n]*\) #{name}\(/)
    abort "Missing Swift polling helper #{symbol}" unless swift_polling.match?(/\bfunc\s+#{symbol}\b/)
  end
  count += mapping.length
end
puts "Mapped #{count} public Go helper methods across #{groups.length + wrappers.length} source files; fixture tests verify behavior"
