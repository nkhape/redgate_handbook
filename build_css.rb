#!/usr/bin/env ruby
# Compiles assets/css/tailwind.css from assets/tailwind/input.css using the
# standalone Tailwind CLI — a single downloaded binary, no Node/npm required.
# Downloads it once into .cache/ (gitignored) and reuses it after that.

require "net/http"
require "fileutils"
require "rbconfig"

ROOT = File.expand_path(__dir__)
CACHE_DIR = File.join(ROOT, ".cache")
INPUT_CSS = File.join(ROOT, "assets", "tailwind", "input.css")
OUTPUT_CSS = File.join(ROOT, "assets", "css", "tailwind.css")
TAILWIND_VERSION = "v4.3.1"

def tailwind_asset_name
  case RbConfig::CONFIG["host_os"]
  when /mswin|mingw|cygwin/
    "tailwindcss-windows-x64.exe"
  when /darwin/
    RUBY_PLATFORM.include?("arm64") ? "tailwindcss-macos-arm64" : "tailwindcss-macos-x64"
  else
    (RUBY_PLATFORM.include?("aarch64") || RUBY_PLATFORM.include?("arm64")) ? "tailwindcss-linux-arm64" : "tailwindcss-linux-x64"
  end
end

def download(url, dest, redirects_left: 5)
  raise "Too many redirects" if redirects_left <= 0

  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    http.request(Net::HTTP::Get.new(uri)) do |response|
      case response
      when Net::HTTPRedirection
        return download(response["location"], dest, redirects_left: redirects_left - 1)
      when Net::HTTPSuccess
        File.open(dest, "wb") { |f| response.read_body { |chunk| f.write(chunk) } }
      else
        raise "Download failed: #{response.code} #{response.message}"
      end
    end
  end
end

def ensure_tailwind_binary
  asset_name = tailwind_asset_name
  binary_path = File.join(CACHE_DIR, asset_name)
  return binary_path if File.exist?(binary_path)

  FileUtils.mkdir_p(CACHE_DIR)
  url = "https://github.com/tailwindlabs/tailwindcss/releases/download/#{TAILWIND_VERSION}/#{asset_name}"
  puts "Downloading Tailwind CLI (#{asset_name})..."
  download(url, binary_path)
  File.chmod(0o755, binary_path)
  binary_path
end

binary = ensure_tailwind_binary
puts "Building CSS..."
success = system(binary, "-i", INPUT_CSS, "-o", OUTPUT_CSS, "--minify")
abort "Tailwind build failed." unless success
puts "Wrote #{OUTPUT_CSS}"
