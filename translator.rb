#!/usr/bin/env ruby

require 'dotenv/load'
require 'optparse'
require 'json'
require 'digest'
require_relative 'lib/app_store_connect'
require_relative 'lib/translator'

class AppStoreTranslator
  # Apple uses different locale codes for different contexts
  # These are the standard App Store Connect locale codes
  DEFAULT_LOCALES = {
    'de-DE' => 'German',
    'fr-FR' => 'French', 
    'es-ES' => 'Spanish',
    'ja' => 'Japanese',
    'zh-Hans' => 'Chinese Simplified',
    'it' => 'Italian',  # Note: API returns 'it' not 'it-IT'
    'nl-NL' => 'Dutch',
    'pt-PT' => 'Portuguese',
    'ko' => 'Korean'
  }
  
  # Map of all possible locale codes to language names
  ALL_LOCALES = {
    'de-DE' => 'German',
    'fr-FR' => 'French',
    'es-ES' => 'Spanish',
    'es-MX' => 'Spanish (Mexico)',
    'ja' => 'Japanese',
    'zh-Hans' => 'Chinese Simplified',
    'zh-Hant' => 'Chinese Traditional',
    'it' => 'Italian',
    'nl-NL' => 'Dutch',
    'pt-PT' => 'Portuguese',
    'pt-BR' => 'Portuguese (Brazil)',
    'ko' => 'Korean',
    'ru' => 'Russian',
    'sv' => 'Swedish',
    'da' => 'Danish',
    'fi' => 'Finnish',
    'no' => 'Norwegian',
    'pl' => 'Polish',
    'tr' => 'Turkish',
    'ar-SA' => 'Arabic',
    'th' => 'Thai',
    'id' => 'Indonesian',
    'vi' => 'Vietnamese',
    'ms' => 'Malay',
    'hi' => 'Hindi',
    'he' => 'Hebrew',
    'el' => 'Greek',
    'ro' => 'Romanian',
    'hu' => 'Hungarian',
    'cs' => 'Czech',
    'sk' => 'Slovak',
    'uk' => 'Ukrainian',
    'hr' => 'Croatian',
    'ca' => 'Catalan'
  }

  CACHE_FILE = '.translation_cache.json'

  def initialize(app_id, force_update = false, whats_new_only = false, options = {})
    @app_id = app_id
    @force_update = force_update
    @whats_new_only = whats_new_only
    @auto_detect = options[:auto_detect]
    @specified_languages = options[:languages]
    @app_store = AppStoreConnect.new
    @translator = Translator.new
    @cache = load_cache
    @manual_translations = {}
    @target_locales = nil
  end

  def run
    if @whats_new_only
      run_whats_new_update
    else
      run_full_translation
    end
  end

  def determine_target_locales(version_id)
    if @specified_languages
      # Use specified languages
      puts "\nUsing specified languages: #{@specified_languages.join(', ')}"
      locales = {}
      @specified_languages.each do |lang|
        # Find the locale code for this language
        locale_entry = ALL_LOCALES.find { |code, name| name.downcase == lang.downcase || code.downcase == lang.downcase }
        if locale_entry
          locales[locale_entry[0]] = locale_entry[1]
        else
          puts "Warning: Unknown language '#{lang}' - skipping"
        end
      end
      return locales
    elsif @auto_detect
      # Auto-detect from existing localizations
      puts "\nAuto-detecting available localizations..."
      version_localizations = @app_store.get_version_localizations(version_id)
      detected_locales = {}
      
      version_localizations.each do |loc|
        locale_code = loc['attributes']['locale']
        next if locale_code == 'en-US'  # Skip English as it's the source
        
        if ALL_LOCALES[locale_code]
          detected_locales[locale_code] = ALL_LOCALES[locale_code]
        else
          puts "Found unknown locale: #{locale_code}"
        end
      end
      
      if detected_locales.empty?
        puts "No localizations detected. Using default set."
        return DEFAULT_LOCALES.select { |k, v| k != 'pt-PT' }  # Default without Portuguese
      else
        puts "Detected languages: #{detected_locales.values.join(', ')}"
        return detected_locales
      end
    else
      # Use default locales (backwards compatibility)
      DEFAULT_LOCALES.select { |k, v| k != 'pt-PT' && k != 'ko' }  # Original default set
    end
  end

  def run_whats_new_update
    puts "Starting What's New update for App ID: #{@app_id}"

    # Get app info
    app_info = @app_store.get_app_info(@app_id)
    puts "App: #{app_info['attributes']['bundleId']}"

    # Get current app store version (pending release)
    version = @app_store.get_current_version(@app_id)

    if version.nil?
      puts "Error: No editable version found. Please create a new version in App Store Connect first."
      exit 1
    end

    puts "Version: #{version['attributes']['versionString']} (#{version['attributes']['appStoreState']})"

    # Fetch English version localization for What's New
    version_localizations = @app_store.get_version_localizations(version['id'])
    english_version = version_localizations.find { |loc| loc['attributes']['locale'] == 'en-US' }

    if english_version.nil? || english_version['attributes']['whatsNew'].nil?
      puts "Error: Could not find English What's New content"
      exit 1
    end

    whats_new_english = english_version['attributes']['whatsNew']

    # Determine which locales to process
    target_locales = determine_target_locales(version['id'])

    # Process each target locale
    target_locales.each do |locale_code, language_name|
      print "Working on #{language_name} (#{locale_code}) What's New... "

      begin
        # Refresh localizations data before processing each locale
        version_localizations = @app_store.get_version_localizations(version['id'])
        @existing_version_localizations = version_localizations.group_by { |loc| loc['attributes']['locale'] }

        existing_version = @existing_version_localizations[locale_code]&.first

        if existing_version
          translated_whats_new = @translator.translate(whats_new_english, language_name, "what's new section")
          @app_store.update_version_localization(existing_version['id'], {
            'whatsNew' => translated_whats_new
          })
          puts "done"
        else
          puts "skipped (no existing localization - add language in App Store Connect first)"
        end
      rescue TranslationError => e
        if e.likely_too_long?
          puts "failed (content too long at #{e.text_length} chars)"
        else
          puts "failed (#{e.original_message})"
        end
      rescue => e
        puts "failed (#{e.message})"
        puts e.backtrace.first(3).join("\n") if ENV['DEBUG']
      end
    end

    puts "\nWhat's New update completed!"
  end

  def run_full_translation
    puts "Starting translation for App ID: #{@app_id}"
    puts "(Force update enabled)" if @force_update

    # Get app info
    app_info = @app_store.get_app_info(@app_id)
    puts "App: #{app_info['attributes']['bundleId']}"

    # Get current app store version
    version = @app_store.get_current_version(@app_id)

    if version.nil?
      puts "Error: No editable version found. Please create a new version in App Store Connect first."
      exit 1
    end

    puts "Version: #{version['attributes']['versionString']} (#{version['attributes']['appStoreState']})"

    # Fetch English localizations
    app_info_localizations = @app_store.get_app_info_localizations(app_info['id'])
    english_app_info = app_info_localizations.find { |loc| loc['attributes']['locale'] == 'en-US' }

    version_localizations = @app_store.get_version_localizations(version['id'])
    english_version = version_localizations.find { |loc| loc['attributes']['locale'] == 'en-US' }

    if english_app_info.nil? || english_version.nil?
      puts "Error: Could not find English localization"
      exit 1
    end

    # Store all existing localizations for reference
    @existing_app_localizations = app_info_localizations.group_by { |loc| loc['attributes']['locale'] }
    @existing_version_localizations = version_localizations.group_by { |loc| loc['attributes']['locale'] }

    if ENV['DEBUG']
      puts "\nExisting localizations:"
      @existing_app_localizations.each { |locale, _| puts "  App Info: #{locale}" }
      @existing_version_localizations.each { |locale, _| puts "  Version: #{locale}" }
    end

    # Determine which locales to process
    target_locales = determine_target_locales(version['id'])
    puts "\nTranslating to: #{target_locales.values.join(', ')}\n\n"

    # Process each target locale
    target_locales.each do |locale_code, language_name|
      begin
        # Refresh localizations data before processing each locale
        app_info_localizations = @app_store.get_app_info_localizations(app_info['id'])
        version_localizations = @app_store.get_version_localizations(version['id'])

        @existing_app_localizations = app_info_localizations.group_by { |loc| loc['attributes']['locale'] }
        @existing_version_localizations = version_localizations.group_by { |loc| loc['attributes']['locale'] }

        process_locale(locale_code, language_name, english_app_info, english_version, app_info['id'], version['id'])
      rescue => e
        puts "  Error: #{e.message}"
        puts e.backtrace.first(3).join("\n") if ENV['DEBUG']
      end
    end

    # Save cache after successful run
    save_cache

    # Output manual translations if any
    output_manual_translations

    puts "\nTranslation process completed!"
  end

  private

  def process_locale(locale_code, language_name, english_app_info, english_version, app_info_id, version_id)
    puts "Working on #{language_name} (#{locale_code})..."

    # Check if we should skip this locale
    if should_skip_locale?(locale_code, english_app_info, english_version)
      puts "  Skipped (no changes detected)"
      return
    end

    # Translate app-level metadata (name, subtitle, privacy policy)
    app_level_translations = translate_app_info(english_app_info['attributes'], language_name)

    # Translate version-level metadata (description, keywords, promotional text, what's new)
    version_level_translations = translate_version_info(english_version['attributes'], language_name)

    # Check if localizations already exist
    existing_app_info = @existing_app_localizations[locale_code]&.first
    existing_version = @existing_version_localizations[locale_code]&.first

    # Update or create app info localization
    app_info_success = false

    begin
      if existing_app_info
        @app_store.update_app_info_localization(existing_app_info['id'], app_level_translations)
        app_info_success = true
      else
        # Store translations for manual copy/paste
        @manual_translations[locale_code] = {
          language: language_name,
          name: app_level_translations['name'],
          subtitle: app_level_translations['subtitle']
        }
      end
    rescue => e
      if e.message.include?("409")
        puts "  Note: App name/subtitle must be updated manually in App Store Connect"
      else
        raise e
      end
    end

    # Update or create version localization
    begin
      if existing_version
        @app_store.update_version_localization(existing_version['id'], version_level_translations)
      else
        @app_store.create_version_localization(version_id, locale_code, version_level_translations)
      end
    rescue => e
      if e.message.include?("409")
        puts "  Note: Add '#{language_name}' in App Store Connect first (Version Info > Add Language)"
      else
        raise e
      end
    end

    # Update cache with English content hashes
    update_cache_for_locale(locale_code, english_app_info, english_version)

    if app_info_success
      puts "  Done"
    else
      puts "  Done (app info requires manual setup)"
    end
  end

  def translate_app_info(english_attrs, target_language)
    translations = {}

    if english_attrs['name']
      print "  Translating app name... "
      translations['name'] = @translator.translate(english_attrs['name'], target_language, 'app name')
      puts "done"
    end

    if english_attrs['subtitle']
      print "  Translating subtitle... "
      translations['subtitle'] = @translator.translate(english_attrs['subtitle'], target_language, 'app subtitle')
      puts "done"
    end

    if english_attrs['privacyPolicyText']
      print "  Translating privacy policy... "
      begin
        translations['privacyPolicyText'] = @translator.translate(english_attrs['privacyPolicyText'], target_language, 'privacy policy')
        puts "done"
      rescue TranslationError => e
        if e.likely_too_long?
          puts "skipped (text too long at #{e.text_length} chars)"
        else
          puts "failed (#{e.original_message})"
        end
      end
    end

    # Copy over non-translatable fields
    ['privacyPolicyUrl', 'privacyChoicesUrl'].each do |field|
      translations[field] = english_attrs[field] if english_attrs[field]
    end

    translations
  end

  def translate_version_info(english_attrs, target_language)
    translations = {}

    if english_attrs['description']
      print "  Translating description... "
      begin
        translations['description'] = @translator.translate(english_attrs['description'], target_language, 'app description')
        puts "done"
      rescue TranslationError => e
        if e.likely_too_long?
          puts "skipped (text too long at #{e.text_length} chars)"
        else
          puts "failed (#{e.original_message})"
        end
      end
    end

    if english_attrs['keywords']
      print "  Translating keywords... "
      translations['keywords'] = @translator.translate(english_attrs['keywords'], target_language, 'app keywords')
      puts "done"
    end

    if english_attrs['promotionalText']
      print "  Translating promotional text... "
      translations['promotionalText'] = @translator.translate(english_attrs['promotionalText'], target_language, 'promotional text')
      puts "done"
    end

    if english_attrs['whatsNew']
      print "  Translating what's new... "
      translations['whatsNew'] = @translator.translate(english_attrs['whatsNew'], target_language, "what's new section")
      puts "done"
    end

    # Copy over non-translatable fields
    ['supportUrl', 'marketingUrl'].each do |field|
      translations[field] = english_attrs[field] if english_attrs[field]
    end

    translations
  end

  def should_skip_locale?(locale_code, english_app_info, english_version)
    # Always process if force flag is set
    return false if @force_update
    
    # Check if locale exists in current localizations
    locale_exists = @existing_app_localizations[locale_code] || @existing_version_localizations[locale_code]
    return false unless locale_exists
    
    # Check if English content has changed
    app_hash = calculate_content_hash(english_app_info['attributes'])
    version_hash = calculate_content_hash(english_version['attributes'])
    
    cached_app_hash = @cache.dig(@app_id, locale_code, 'app_info_hash')
    cached_version_hash = @cache.dig(@app_id, locale_code, 'version_hash')
    
    # Skip if hashes match (content hasn't changed)
    app_hash == cached_app_hash && version_hash == cached_version_hash
  end
  
  def calculate_content_hash(attributes)
    # Create hash of translatable content only
    content = {
      'name' => attributes['name'],
      'subtitle' => attributes['subtitle'],
      'description' => attributes['description'],
      'keywords' => attributes['keywords'],
      'promotionalText' => attributes['promotionalText'],
      'whatsNew' => attributes['whatsNew'],
      'privacyPolicyText' => attributes['privacyPolicyText']
    }.compact
    
    Digest::SHA256.hexdigest(content.to_json)
  end
  
  def update_cache_for_locale(locale_code, english_app_info, english_version)
    @cache[@app_id] ||= {}
    @cache[@app_id][locale_code] = {
      'app_info_hash' => calculate_content_hash(english_app_info['attributes']),
      'version_hash' => calculate_content_hash(english_version['attributes']),
      'updated_at' => Time.now.to_s
    }
  end
  
  def load_cache
    return {} unless File.exist?(CACHE_FILE)
    
    begin
      JSON.parse(File.read(CACHE_FILE))
    rescue JSON::ParserError
      puts "Warning: Cache file corrupted, starting fresh"
      {}
    end
  end
  
  def save_cache
    File.write(CACHE_FILE, JSON.pretty_generate(@cache))
  end
  
  def output_manual_translations
    return if @manual_translations.empty?
    
    filename = "manual_translations_#{@app_id}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.txt"
    
    File.open(filename, 'w') do |file|
      file.puts "App Store Connect Manual Translations"
      file.puts "===================================="
      file.puts "App ID: #{@app_id}"
      file.puts "Generated: #{Time.now}"
      file.puts "\nInstructions:"
      file.puts "1. Go to App Store Connect > Your App > App Information"
      file.puts "2. Select each language from the dropdown"
      file.puts "3. Copy and paste the translations below"
      file.puts "\n" + "="*50 + "\n"
      
      @manual_translations.each do |locale_code, translations|
        file.puts "\n#{translations[:language]} (#{locale_code})"
        file.puts "-" * 30
        file.puts "App Name: #{translations[:name]}"
        file.puts "Subtitle: #{translations[:subtitle]}"
      end
      
      file.puts "\n" + "="*50
      file.puts "\nNote: Version-specific translations (description, keywords, etc.)"
      file.puts "have been automatically updated via the API."
    end
    
    puts "\nManual translations saved to: #{filename}"

    # Also output to console for immediate reference
    puts "\nManual translations required:"
    @manual_translations.each do |locale_code, translations|
      puts "  #{translations[:language]}: Name: #{translations[:name]} | Subtitle: #{translations[:subtitle]}"
    end
  end
end

# Main execution
options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby translator.rb [options] <APP_ID>"
  
  opts.on("-f", "--force", "Force retranslation of all languages") do
    options[:force] = true
  end
  
  opts.on("-w", "--whats-new", "Update only What's New field from pending release") do
    options[:whats_new] = true
  end
  
  opts.on("-a", "--auto-detect", "Auto-detect available localizations from App Store") do
    options[:auto_detect] = true
  end
  
  opts.on("-l", "--languages LANGS", "Comma-separated list of languages (e.g., 'German,French,Korean' or 'de-DE,fr-FR,ko')") do |langs|
    options[:languages] = langs.split(',').map(&:strip)
  end
  
  opts.on("-h", "--help", "Show this help message") do
    puts opts
    puts "\nAvailable languages:"
    puts "  Default set: German, French, Spanish, Japanese, Chinese Simplified, Italian, Dutch"
    puts "  Additional: Korean, Portuguese, Russian, Swedish, Arabic, and more"
    puts "\nExamples:"
    puts "  ruby translator.rb 6747396799 --auto-detect"
    puts "  ruby translator.rb 6747396799 --languages German,French,Korean"
    puts "  ruby translator.rb 6747396799 --whats-new --auto-detect"
    exit
  end
end

begin
  parser.parse!
  
  if ARGV.length != 1
    puts parser
    exit 1
  end
  
  app_id = ARGV[0]
  
  # Validate options
  if options[:auto_detect] && options[:languages]
    puts "Error: Cannot use both --auto-detect and --languages options"
    puts parser
    exit 1
  end
  
  translator = AppStoreTranslator.new(
    app_id, 
    options[:force] || false, 
    options[:whats_new] || false,
    auto_detect: options[:auto_detect],
    languages: options[:languages]
  )
  translator.run
rescue OptionParser::InvalidOption => e
  puts "Error: #{e.message}"
  puts parser
  exit 1
end