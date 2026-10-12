#!/usr/bin/env ruby
# Apple's generator cannot represent standalone null alternatives or optional multipart bodies.
# Keep the pinned source intact and record every adaptation of the generation input.
require 'json'
require 'fileutils'
source, destination, report = ARGV
abort 'usage: prepare-schema.rb SOURCE DESTINATION REPORT' unless report
schema = JSON.parse(File.read(source))
changes = []
visit = lambda do |node, path|
  case node
  when Hash
    if node["not"].is_a?(Hash) && node["not"].keys == ["type"]
      excluded = Array(node.delete("not")["type"])
      allowed = %w[object array string number boolean null] - excluded
      abort "Unsupported empty type complement at #{path}" if allowed.empty?
      node["type"] = allowed.length == 1 ? allowed.first : allowed
      changes << { path: path, adaptation: "negative type list represented by its explicit JSON type complement" }
    end
    if node.key?("not")
      node["x-openai-generator-validation-not"] = node.delete("not")
      changes << { path: path, adaptation: "negative validation constraint retained as metadata; enforcement remains on the server" }
    end
    if node["properties"].is_a?(Hash)
      %w[anyOf oneOf].each do |union|
        Array(node[union]).each do |variant|
          next unless variant.is_a?(Hash) && variant.keys == ["required"]
          variant["type"] = "object"
          variant["properties"] = JSON.parse(JSON.generate(node["properties"]))
          changes << { path: "#{path}/#{union}", adaptation: "required-only branch materializes the enclosing typed object properties" }
        end
      end
    end
    %w[anyOf oneOf].each do |union|
      variants = node[union]
      next unless variants.is_a?(Array) && variants.any? { |item| item == { 'type' => 'null' } }
      remaining = variants.reject { |item| item == { 'type' => 'null' } }
      node.delete(union)
      if remaining.length == 1
        node.merge!(remaining.first)
      else
        node[union] = remaining
      end
      if node['type'].is_a?(String)
        node['type'] = [node['type'], 'null']
      else
        node['nullable'] = true
      end
      changes << { path: path, adaptation: 'null alternative represented by nullable' }
    end
    if node.key?("not")
      node["x-openai-generator-validation-not"] = node.delete("not")
      changes << { path: path, adaptation: "negative validation constraint retained as metadata; enforcement remains on the server" }
    end
    if node["properties"].is_a?(Hash) && node["required"].is_a?(Array)
      (node["required"] - node["properties"].keys).each do |name|
        node["properties"][name] = {}
        changes << { path: "#{path}/properties/#{name}", adaptation: "required upstream property missing its schema; retain as an unconstrained JSON value" }
      end
    end
    node.each { |key, value| visit.call(value, "#{path}/#{key}") }
  when Array
    node.each_with_index { |value, index| visit.call(value, "#{path}/#{index}") }
  end
end
# OpenAPI's implicit discriminator mapping uses component names. The API sends
# literal wire values (for example role=user), so materialize those mappings.
resolve = lambda do |ref|
  ref.delete_prefix('#/').split('/').reduce(schema) { |node, key| node.fetch(key.gsub('~1', '/').gsub('~0', '~')) }
end
map_discriminators = lambda do |node, path|
  case node
  when Hash
    discriminator = node['discriminator']
    if discriminator && node['oneOf']
      mapping = discriminator['mapping'] ||= {}
      node['oneOf'].each do |variant|
        next unless variant['$ref']
        definition = resolve.call(variant['$ref'])
        property = definition.dig('properties', discriminator['propertyName'])
        next unless property
        values = property.key?('const') ? [property['const']] : property['enum']
        Array(values).each do |value|
          next unless value.is_a?(String) && !mapping.key?(value)
          mapping[value] = variant['$ref']
          changes << { path: path, adaptation: "explicit discriminator mapping for wire value #{value}" }
        end
      end
    end
    node.each { |key, value| map_discriminators.call(value, "#{path}/#{key}") }
  when Array
    node.each_with_index { |value, index| map_discriminators.call(value, "#{path}/#{index}") }
  end
end
map_discriminators.call(schema, '#')
visit.call(schema, '#')
schema['paths'].each do |path, item|
  item.each do |method, operation|
    next unless operation.is_a?(Hash)
    body = operation['requestBody']
    next unless body && body.dig('content', 'multipart/form-data')
    unless body['required']
      body['required'] = true
      changes << { path: "#/paths#{path}/#{method}/requestBody", adaptation: 'caller must supply multipart body, which may be empty' }
    end
    json_shape = body.dig("content", "application/json", "schema")
    if json_shape && json_shape["$ref"]
      name = json_shape["$ref"].split("/").last
      clone = JSON.parse(JSON.generate(schema["components"]["schemas"][name]))
      remove_binary = lambda do |value|
        case value
        when Hash
          value.delete("format") if value["format"] == "binary"
          value.each_value { |child| remove_binary.call(child) }
        when Array
          value.each { |child| remove_binary.call(child) }
        end
      end
      remove_binary.call(clone)
      schema["components"]["schemas"]["JSON#{name}"] = clone
      json_shape["$ref"] = "#/components/schemas/JSON#{name}"
      changes << { path: "#/paths#{path}/#{method}/requestBody", adaptation: "independent JSON model for shared JSON/multipart schema; binary strings remain JSON strings" }
    end
    shape = body.dig('content', 'multipart/form-data', 'schema')
    reference = shape && shape['$ref']
    definition = reference && schema.dig('components', 'schemas', reference.split('/').last)
    if definition && definition['oneOf']&.length == 1
      body['content']['multipart/form-data']['schema'] = definition['oneOf'].first
      changes << { path: "#/paths#{path}/#{method}/requestBody", adaptation: 'single-variant multipart alias resolved' }
    end
  end
end
voice = schema["components"]["schemas"]["CreateVoiceRequest"]
if voice
  consent = JSON.parse(JSON.generate(schema["components"]["schemas"]["CreateVoiceFromConsentRequest"]))
  consent["properties"].each_value { |property| property.delete("format") if property["format"] == "binary" }
  schema["components"]["schemas"]["JSONCreateVoiceFromConsentRequest"] = consent
  voice["oneOf"] = [{ "$ref" => "#/components/schemas/JSONCreateVoiceFromConsentRequest" }]
  voice["discriminator"]["mapping"]["audio_sample"] = "#/components/schemas/JSONCreateVoiceFromConsentRequest"
  changes << { path: "#/components/schemas/CreateVoiceRequest", adaptation: "JSON alias of multipart-only variant uses JSON strings; multipart operation uses original variant" }
end
FileUtils.mkdir_p(File.dirname(destination))
File.write(destination, JSON.pretty_generate(schema) + "\n")
File.write(report, JSON.pretty_generate(changes) + "\n")
puts "Prepared schema with #{changes.length} documented generator adaptations"
