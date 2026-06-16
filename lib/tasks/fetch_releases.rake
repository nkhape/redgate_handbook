require "net/http"
require "json"
require "uri"
require "nokogiri"

RSS_FEED_URL = "https://dialgforgsu.github.io/re-check/feed.xml"

# Maps product keys to their title prefixes in the RSS feed
PRODUCT_RSS_PREFIXES = {
  "monitor"           => [ "Redgate Monitor" ],
  "flyway"            => [ "Flyway Desktop", "Flyway CLI" ],
  "test_data_manager" => [ "Test Data Manager" ]
}

namespace :releases do
  desc "Fetch and AI-process release notes for all products from RSS feed"
  task fetch_all: :environment do
    puts "Fetching RSS feed..."
    all_items = fetch_rss_items
    abort "ERROR: Could not fetch RSS feed." if all_items.nil? || all_items.empty?
    puts "Got #{all_items.length} total items from feed."

    PRODUCT_RSS_PREFIXES.each_key do |product_key|
      puts "\n=== #{product_key} ==="
      fetch_releases_for(product_key, all_items)
    end
    puts "\nAll done!"
  end

  desc "Fetch release notes for one product, e.g. rake releases:fetch[monitor]"
  task :fetch, [ :product ] => :environment do |_t, args|
    product = args[:product]
    abort "Usage: rake releases:fetch[product_key]" unless product
    abort "No RSS config for '#{product}'" unless PRODUCT_RSS_PREFIXES.key?(product)

    puts "Fetching RSS feed..."
    all_items = fetch_rss_items
    abort "ERROR: Could not fetch RSS feed." if all_items.nil? || all_items.empty?

    fetch_releases_for(product, all_items)
  end
end

# ---------------------------------------------------------------------------

def fetch_rss_items
  uri = URI(RSS_FEED_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 30
  http.open_timeout = 10

  response = http.request(Net::HTTP::Get.new(uri))
  return nil unless response.is_a?(Net::HTTPSuccess)

  doc = Nokogiri::XML(response.body)
  doc.css("item").map do |item|
    {
      "title"       => item.at_xpath("title")&.text&.strip,
      "link"        => item.at_xpath("link")&.text&.strip,
      "pub_date"    => item.at_xpath("pubDate")&.text&.strip,
      "description" => item.at_xpath("description")&.text&.strip
    }
  end.compact
rescue => e
  puts "RSS fetch error: #{e.message}"
  nil
end

def fetch_releases_for(product_key, all_items)
  prefixes = PRODUCT_RSS_PREFIXES[product_key]
  product_items = all_items.select do |item|
    prefixes.any? { |prefix| item["title"]&.start_with?(prefix) }
  end

  if product_items.empty?
    puts "No RSS items found for #{product_key}. Skipping."
    return
  end
  puts "Found #{product_items.length} RSS items for #{product_key}."

  puts "Sending to Claude API..."
  releases = process_with_claude(product_key, product_items)
  if releases.nil? || releases.empty?
    puts "ERROR: Claude returned no releases. Skipping #{product_key}."
    return
  end
  puts "Got #{releases["items"]&.length} release versions."

  save_releases(product_key, releases)
  puts "Saved to config/releases_data.json."
end

def process_with_claude(product_key, items)
  api_key = ENV["ANTHROPIC_API_KEY"]
  abort "ANTHROPIC_API_KEY environment variable is not set." unless api_key

  # Build a compact JSON representation to send to Claude
  items_json = JSON.pretty_generate(items.first(50))

  prompt = <<~PROMPT
    You are writing a "What's New" section for a sales-facing product handbook. Your audience is non-technical salespeople and solutions engineers — not developers.

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
    "summary"    => releases["summary"],
    "items"      => releases["items"]
  }

  File.write(path, JSON.pretty_generate(data))
end
