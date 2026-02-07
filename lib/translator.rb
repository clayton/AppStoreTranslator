require 'open_router'

class TranslationError < StandardError
  attr_reader :context_type, :language, :text_length, :original_message

  def initialize(context_type, language, text_length, original_message)
    @context_type = context_type
    @language = language
    @text_length = text_length
    @original_message = original_message
    super("Failed to translate #{context_type} to #{language} (#{text_length} chars): #{original_message}")
  end

  def likely_too_long?
    text_length > 1000
  end
end

class Translator
  def initialize
    raise "Missing OPENROUTER_API_KEY environment variable" if ENV['OPENROUTER_API_KEY'].nil? || ENV['OPENROUTER_API_KEY'].empty?
    
    # Configure OpenRouter globally
    OpenRouter.configure do |config|
      config.access_token = ENV['OPENROUTER_API_KEY']
    end
    
    @client = OpenRouter::Client.new
    @model = 'google/gemini-3-flash-preview'
  end

  def translate(text, target_language, context_type)
    return nil if text.nil? || text.strip.empty?

    prompt = build_translation_prompt(text, target_language, context_type)

    max_retries = 3
    retry_count = 0

    begin
      retry_count += 1
      puts "  Attempt #{retry_count}/#{max_retries}..." if retry_count > 1

      response = @client.complete(
        [{ role: 'user', content: prompt }],
        model: @model
      )

      if ENV['DEBUG']
        puts "  DEBUG response: #{JSON.pretty_generate(response)}"
      end

      translation = response.dig('choices', 0, 'message', 'content')

      if translation.nil? || translation.strip.empty?
        raise "Translation failed - no response from API"
      end

      # Clean up the translation (remove any markdown or quotes if present)
      translation.strip.gsub(/^["']|["']$/, '').gsub(/^```.*\n/, '').gsub(/\n```$/, '').strip
    rescue => e
      puts "  Error: #{e.message}" if ENV['DEBUG']

      if retry_count < max_retries
        wait_time = retry_count * 2  # Progressive backoff: 2s, 4s, 6s
        sleep(wait_time)
        retry
      else
        raise TranslationError.new(context_type, target_language, text.length, e.message)
      end
    end
  end

  private

  def build_translation_prompt(text, target_language, context_type)
    language_instructions = case target_language
    when 'German'
      "Translate to German (de-DE). Use formal language (Sie form) for user-facing content."
    when 'French'
      "Translate to French (fr-FR). Use appropriate formal/informal tone for app store content."
    when 'Spanish'
      "Translate to Spanish (es-ES, Spain Spanish not Latin American)."
    when 'Japanese'
      "Translate to Japanese. Use appropriate polite form (です/ます) for app store content."
    when 'Chinese Simplified'
      "Translate to Simplified Chinese (zh-Hans). Use appropriate tone for mainland China market."
    when 'Italian'
      "Translate to Italian (it-IT)."
    when 'Dutch'
      "Translate to Dutch (nl-NL, Netherlands Dutch)."
    when 'Portuguese'
      "Translate to Portuguese (pt-PT, European Portuguese not Brazilian)."
    else
      "Translate to #{target_language}."
    end

    context_instructions = case context_type
    when 'app name'
      "This is an app name. Keep it concise and impactful. Maintain brand identity where appropriate."
    when 'app subtitle'
      "This is an app subtitle. Keep it brief (max 30 characters) and descriptive."
    when 'app keywords'
      "These are app store keywords. Translate each keyword, maintaining SEO value. Separate with commas."
    when 'app description'
      "This is an app description. Maintain marketing tone, features, and benefits. Keep formatting."
    when 'promotional text'
      "This is promotional text. Keep it engaging and action-oriented."
    when "what's new section"
      "This is a what's new section. Keep bullet points or formatting if present."
    when 'privacy policy'
      "This is privacy policy text. Maintain legal accuracy and formal tone."
    else
      "Maintain the original tone and intent."
    end

    <<~PROMPT
      #{language_instructions}
      
      #{context_instructions}
      
      Important rules:
      - Provide ONLY the translation, no explanations or notes
      - Maintain any special characters, line breaks, or formatting
      - Do not add quotes around the translation
      - For app names, consider if translation is appropriate or if the original should be kept
      - For technical terms, use commonly accepted translations in the target market
      
      Text to translate:
      #{text}
    PROMPT
  end
end