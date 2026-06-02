require "net/http"
require "json"
require "yaml"
require "uri"

namespace :releases do
  desc "Fetch and AI-process release notes for all products in config/release_sources.yml"
  task fetch_all: :environment do
    sources = YAML.load_file(Rails.root.join("config/release_sources.yml"))
    sources.each_key do |product_key|
      puts "\n=== #{product_key} ==="
      fetch_releases_for(product_key, sources[product_key])
    end
    puts "\nAll done!"
  end

  desc "Fetch release notes for one product, e.g. rake releases:fetch[monitor]"
  task :fetch, [ :product ] => :environment do |_t, args|
    product = args[:product]
    abort "Usage: rake releases:fetch[product_key]" unless product

    sources = YAML.load_file(Rails.root.join("config/release_sources.yml"))
    config = sources[product]
    abort "No release source configured for '#{product}' in config/release_sources.yml" unless config

    fetch_releases_for(product, config)
  end
end

# ---------------------------------------------------------------------------

def fetch_releases_for(product_key, config)
  docs_url = config["url"]
  puts "Fetching via Jina: #{docs_url}"

  markdown = fetch_via_jina(docs_url)
  if markdown.nil? || markdown.strip.empty?
    puts "ERROR: Could not fetch content. Skipping #{product_key}."
    return
  end
  puts "Fetched #{markdown.length} characters."

  puts "Sending to Claude API..."
  releases = process_with_claude(markdown, docs_url)
  if releases.nil? || releases.empty?
    puts "ERROR: Claude returned no releases. Skipping #{product_key}."
    return
  end
  puts "Got #{releases.length} release versions."

  save_releases(product_key, releases)
  puts "Saved to config/releases_data.json."
end

def fetch_via_jina(docs_url)
  jina_url = "https://r.jina.ai/#{docs_url}"
  uri = URI(jina_url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 30
  http.open_timeout = 10

  request = Net::HTTP::Get.new(uri)
  request["Accept"] = "text/plain"
  request["X-Return-Format"] = "markdown"

  response = http.request(request)
  response.is_a?(Net::HTTPSuccess) ? response.body.encode("UTF-8", invalid: :replace, undef: :replace, replace: "") : nil
rescue => e
  puts "Jina fetch error: #{e.message}"
  nil
end

def process_with_claude(markdown, docs_url)
  api_key = ENV["ANTHROPIC_API_KEY"]
  abort "ANTHROPIC_API_KEY environment variable is not set." unless api_key

  # Sanitise encoding and truncate to avoid hitting token limits
  content = markdown.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
  content = content[0, 60_000] if content.length > 60_000

  prompt = <<~PROMPT
    You are writing a "What's New" section for a sales-facing product handbook. Your audience is non-technical salespeople and solutions engineers — not developers.

    From the release notes below do two things:

    1. Write a short summary paragraph (2-3 sentences max) aimed at a salesperson preparing for a customer conversation. Focus on the changes that matter most to the people being sold to — what problems does this solve, what value does it add? Be specific and confident, not generic. Where you mention a specific feature, wrap it in an HTML anchor tag linking to the release notes page (use the docs_url). Return the summary as an HTML string (just the paragraph content, no wrapping <p> tag). No version numbers.

    2. Extract all versions released in the last 3 months. For each version:
       - Include ONLY features and improvements. Skip bug fixes, security patches, internal refactors, and minor changes.
       - Rewrite each item in plain, jargon-free English focused on business value and customer benefit.
       - Keep each highlight to one clear, punchy sentence.
       - If a version has nothing worth highlighting for a sales audience, skip it entirely.

    Return ONLY valid JSON — no explanation, no markdown, no code fences. Use this exact structure:
    {
      "summary": "A 2-3 sentence HTML string (no wrapping p tag) with inline anchor links on specific features, written for a salesperson.",
      "items": [
        {
          "version": "14.18.0",
          "date": "May 28, 2026",
          "docs_url": "#{docs_url}",
          "highlights": [
            "A plain-English description of a feature or improvement"
          ]
        }
      ]
    }

    Release notes:
    #{content}
  PROMPT

  uri = URI("https://api.anthropic.com/v1/messages")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 60
  http.open_timeout = 10

  request = Net::HTTP::Post.new(uri)
  request["Content-Type"] = "application/json"
  request["x-api-key"] = api_key
  request["anthropic-version"] = "2023-06-01"
  request.body = {
    model: "claude-haiku-4-5",
    max_tokens: 8096,
    messages: [ { role: "user", content: prompt } ]
  }.to_json

  response = http.request(request)
  unless response.is_a?(Net::HTTPSuccess)
    puts "Claude API error #{response.code}: #{response.body}"
    return nil
  end

  body = JSON.parse(response.body)
  json_text = body.dig("content", 0, "text")
  # Strip markdown code fences if Claude wrapped the response in them
  json_text = json_text.gsub(/\A```(?:json)?\n?/, "").gsub(/\n?```\z/, "").strip
  JSON.parse(json_text)
rescue JSON::ParserError => e
  puts "Failed to parse Claude response as JSON: #{e.message}"
  nil
rescue => e
  puts "Claude API error: #{e.message}"
  nil
end

def save_releases(product_key, releases)
  path = Rails.root.join("config/releases_data.json")
  data = File.exist?(path) ? JSON.parse(File.read(path)) : {}

  data[product_key] = {
    "fetched_at" => Date.today.to_s,
    "summary" => releases["summary"],
    "items" => releases["items"]
  }

  File.write(path, JSON.pretty_generate(data))
end
