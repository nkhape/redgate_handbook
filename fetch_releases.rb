#!/usr/bin/env ruby
# Fetches release notes from the RSS feed, asks Claude to turn them into a
# sales-facing "What's New" summary, and writes data/releases_data.json.
# Standard library only (net/http, rexml) — no Rails, no bundler.
#
# Usage:
#   ruby fetch_releases.rb           # all configured products
#   ruby fetch_releases.rb monitor   # a single product

require "net/http"
require "json"
require "uri"
require "rexml/document"
require "date"
require "fileutils"

RSS_FEED_URL = "https://dialgforgsu.github.io/re-check/feed.xml"
RELEASES_DIR = File.join(__dir__, "data", "releases")

PRODUCT_RSS_PREFIXES = {
  "monitor" => [ "Redgate Monitor" ],
  "flyway"  => [ "Flyway Desktop", "Flyway CLI" ]
}.freeze

def fetch_rss_items
  uri = URI(RSS_FEED_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 30
  http.open_timeout = 10

  response = http.request(Net::HTTP::Get.new(uri))
  return nil unless response.is_a?(Net::HTTPSuccess)

  doc = REXML::Document.new(response.body)
  REXML::XPath.match(doc, "//item").map do |item|
    {
      "title"       => item.elements["title"]&.text&.strip,
      "link"        => item.elements["link"]&.text&.strip,
      "pub_date"    => item.elements["pubDate"]&.text&.strip,
      "description" => item.elements["description"]&.text&.strip
    }
  end.compact
rescue => e
  warn "RSS fetch error: #{e.message}"
  nil
end

# Sends one prompt to Claude and returns the parsed JSON object it replies
# with. Retries once on a malformed-JSON reply — an occasional LLM hiccup,
# not worth failing the whole product over.
def call_claude(prompt, max_tokens:, attempts: 2)
  api_key = ENV["ANTHROPIC_API_KEY"]
  abort "ANTHROPIC_API_KEY environment variable is not set." unless api_key

  attempts.downto(1) do |remaining|
    uri = URI("https://api.anthropic.com/v1/messages")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 90
    http.open_timeout = 10

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["x-api-key"] = api_key
    request["anthropic-version"] = "2023-06-01"
    request.body = {
      model: "claude-haiku-4-5",
      max_tokens: max_tokens,
      messages: [ { role: "user", content: prompt } ]
    }.to_json

    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      warn "Claude API error #{response.code}: #{response.body}"
      next
    end

    body = JSON.parse(response.body)
    json_text = body.dig("content", 0, "text")
    json_text = json_text.gsub(/\A```(?:json)?\n?/, "").gsub(/\n?```\z/, "").strip

    begin
      return JSON.parse(json_text)
    rescue JSON::ParserError => e
      warn "Failed to parse Claude response as JSON: #{e.message}"
      warn "Retrying..." if remaining > 1
    end
  end

  nil
rescue => e
  warn "Claude API error: #{e.message}"
  nil
end

# Decides which releases matter and writes the English summary + highlights.
def summarize_in_english(items)
  items_json = JSON.pretty_generate(items.first(50))

  prompt = <<~PROMPT
    You are writing a "What's New" section for a sales-facing product handbook, in English. Your audience is non-technical salespeople and solutions engineers — not developers.

    Below is a JSON array of recent release items from an RSS feed. Each item has a title (containing product name, version, and date), a link to the full release notes, and a description containing HTML with categorised changes.

    Do two things:

    1. Write a summary paragraph (6-8 sentences) aimed at a salesperson preparing for a customer conversation. Use ONLY releases from the last 3 months — ignore anything older. Cover the most impactful changes from that window — what problems do they solve, what value do they add? Group related themes together where it makes sense (e.g. performance improvements, new integrations, usability wins). Be specific and confident, not generic. Where you mention a specific feature, wrap it in an HTML anchor tag linking to the most relevant release's link URL. Return the summary as an HTML string (just the paragraph content, no wrapping <p> tag). No version numbers in the summary.

    2. Extract all versions from the last 3 months. For each version:
       - Include ONLY new features and improvements. Skip bug fixes, security patches, internal refactors, and minor changes.
       - Rewrite each item in plain, jargon-free English focused on business value and customer benefit.
       - Keep each highlight to one clear, punchy sentence.
       - Use the item's link URL as the docs_url for that version.
       - Parse the version number and date from the title field.
       - If a version has nothing worth highlighting for a sales audience, skip it entirely.

    Return ONLY valid JSON — no explanation, no markdown, no code fences. Use this exact structure:
    {
      "summary": "A 2-3 sentence HTML string (no wrapping p tag) with inline anchor links on specific features, written for a salesperson.",
      "items": [
        {
          "version": "14.18.0",
          "date": "May 28, 2026",
          "docs_url": "https://...",
          "highlights": [
            "A plain-English description of a feature or improvement"
          ]
        }
      ]
    }

    RSS items:
    #{items_json}
  PROMPT

  call_claude(prompt, max_tokens: 8192)
end

# Translates an already-decided English result into German, keeping the exact
# same versions in the exact same order — a separate call so the two
# languages can never disagree about which releases made the cut.
def translate_to_german(english)
  english_json = JSON.pretty_generate(english)

  prompt = <<~PROMPT
    Translate the following "What's New" content for a sales-facing product handbook from English into natural business German (not a word-for-word translation).

    Rules:
    - Keep the exact same set of versions, in the exact same order. Do not add, remove, or reorder any version.
    - For each item, keep "version" and "docs_url" completely unchanged.
    - Translate each string in "highlights" into German.
    - Reformat "date" into German date format (e.g. "20. Juli 2026").
    - Translate the "summary" HTML string, keeping any <a href="..."> tags and their href values unchanged — translate only the visible link text and surrounding text.
    - Never use double quotes (" or „ ") anywhere in the translated German text, including around feature or product names — a literal double-quote character breaks the JSON string you're writing. If you'd normally set off a term, either don't, or use single quotes (') instead.

    Return ONLY valid JSON — no explanation, no markdown, no code fences. Use this exact structure:
    {
      "summary": "German summary HTML, same links, translated text",
      "items": [
        {
          "version": "14.18.0",
          "date": "28. Mai 2026",
          "docs_url": "https://...",
          "highlights": [
            "Deutsche Beschreibung"
          ]
        }
      ]
    }

    English content to translate:
    #{english_json}
  PROMPT

  # German runs longer than English for the same content, and translating an
  # already-large item list (e.g. 24+ versions) can outgrow 8192 tokens
  # mid-response — seen in practice as truncated/malformed JSON.
  call_claude(prompt, max_tokens: 16000)
end

def fetch_releases_for(product_key, all_items)
  prefixes = PRODUCT_RSS_PREFIXES.fetch(product_key)
  product_items = all_items.select do |item|
    prefixes.any? { |prefix| item["title"]&.start_with?(prefix) }
  end

  if product_items.empty?
    puts "No RSS items found for #{product_key}. Skipping."
    return nil
  end
  puts "Found #{product_items.length} RSS items for #{product_key}."

  puts "Sending to Claude API (en)..."
  english = summarize_in_english(product_items)
  if english.nil? || english["items"].nil? || english["items"].empty?
    puts "ERROR: Claude returned no releases. Skipping #{product_key}."
    return nil
  end

  puts "Translating to German..."
  german = translate_to_german(english)
  if german.nil? || german["items"].nil? || german["items"].empty?
    puts "ERROR: German translation failed. Skipping #{product_key}."
    return nil
  end

  puts "Got #{english["items"].length} release versions."
  { "en" => english, "de" => german }
end

def save_releases(product_key, releases)
  data = %w[en de].to_h do |locale|
    locale_data = releases.fetch(locale)
    [locale, {
      "fetched_at" => Date.today.to_s,
      "summary"    => locale_data["summary"],
      "items"      => locale_data["items"]
    }]
  end

  FileUtils.mkdir_p(RELEASES_DIR)
  path = File.join(RELEASES_DIR, "#{product_key}.json")
  File.write(path, JSON.pretty_generate(data))
  puts "Saved to #{path}."
end

requested_product = ARGV[0]

puts "Fetching RSS feed..."
all_items = fetch_rss_items
abort "ERROR: Could not fetch RSS feed." if all_items.nil? || all_items.empty?
puts "Got #{all_items.length} total items from feed."

product_keys =
  if requested_product
    abort "No RSS config for '#{requested_product}'" unless PRODUCT_RSS_PREFIXES.key?(requested_product)
    [requested_product]
  else
    PRODUCT_RSS_PREFIXES.keys
  end

product_keys.each do |product_key|
  puts "\n=== #{product_key} ==="
  releases = fetch_releases_for(product_key, all_items)
  save_releases(product_key, releases) if releases
end

puts "\nAll done!"
