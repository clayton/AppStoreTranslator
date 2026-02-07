require 'httparty'
require 'jwt'
require 'json'
require 'openssl'
require 'base64'

class AppStoreConnect
  include HTTParty
  base_uri 'https://api.appstoreconnect.apple.com'

  def initialize
    @key_id = ENV['APP_STORE_KEY_ID']
    @issuer_id = ENV['APP_STORE_ISSUER_ID']
    @private_key = ENV['APP_STORE_PRIVATE_KEY']
    
    raise "Missing APP_STORE_KEY_ID environment variable" if @key_id.nil? || @key_id.empty?
    raise "Missing APP_STORE_ISSUER_ID environment variable" if @issuer_id.nil? || @issuer_id.empty?
    raise "Missing APP_STORE_PRIVATE_KEY environment variable" if @private_key.nil? || @private_key.empty?
  end

  def get_app_info(app_id)
    response = make_request(:get, "/v1/apps/#{app_id}")
    app = response['data']
    
    # Get the app info
    app_info_response = make_request(:get, "/v1/apps/#{app_id}/appInfos")
    app_info_response['data'].first
  end

  def get_current_version(app_id)
    response = make_request(:get, "/v1/apps/#{app_id}/appStoreVersions", {
      'filter[platform]' => 'IOS',
      'filter[appStoreState]' => 'PREPARE_FOR_SUBMISSION',
      'limit' => 200
    })
    
    # Find the prepare for submission version
    prepare_version = response['data'].find { |v| v['attributes']['appStoreState'] == 'PREPARE_FOR_SUBMISSION' }
    
    if prepare_version.nil?
      # If no prepare for submission, try to find the latest editable version
      response = make_request(:get, "/v1/apps/#{app_id}/appStoreVersions", {
        'filter[platform]' => 'IOS',
        'limit' => 10
      })
      
      editable_states = ['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'IN_REVIEW', 'WAITING_FOR_REVIEW']
      prepare_version = response['data'].find { |v| editable_states.include?(v['attributes']['appStoreState']) }
    end
    
    prepare_version
  end

  def get_app_info_localizations(app_info_id)
    # Try to get all localizations with a higher limit
    response = make_request(:get, "/v1/appInfos/#{app_info_id}/appInfoLocalizations", {
      'limit' => 200
    })
    response['data']
  end
  
  def get_all_app_info_localizations
    # Alternative method to fetch all app info localizations
    response = make_request(:get, "/v1/appInfoLocalizations", {
      'limit' => 200
    })
    response['data']
  end

  def get_version_localizations(version_id)
    response = make_request(:get, "/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations")
    response['data']
  end

  def create_app_info_localization(app_info_id, locale, attributes)
    body = {
      data: {
        type: 'appInfoLocalizations',
        attributes: attributes.merge('locale' => locale),
        relationships: {
          appInfo: {
            data: {
              type: 'appInfos',
              id: app_info_id
            }
          }
        }
      }
    }
    
    make_request(:post, '/v1/appInfoLocalizations', nil, body)
  end

  def update_app_info_localization(localization_id, attributes)
    body = {
      data: {
        type: 'appInfoLocalizations',
        id: localization_id,
        attributes: attributes
      }
    }
    
    make_request(:patch, "/v1/appInfoLocalizations/#{localization_id}", nil, body)
  end

  def create_version_localization(version_id, locale, attributes)
    body = {
      data: {
        type: 'appStoreVersionLocalizations',
        attributes: attributes.merge('locale' => locale),
        relationships: {
          appStoreVersion: {
            data: {
              type: 'appStoreVersions',
              id: version_id
            }
          }
        }
      }
    }
    
    make_request(:post, '/v1/appStoreVersionLocalizations', nil, body)
  end

  def update_version_localization(localization_id, attributes)
    body = {
      data: {
        type: 'appStoreVersionLocalizations',
        id: localization_id,
        attributes: attributes
      }
    }
    
    make_request(:patch, "/v1/appStoreVersionLocalizations/#{localization_id}", nil, body)
  end

  private

  def make_request(method, path, query = nil, body = nil)
    token = generate_token

    options = {
      headers: {
        'Authorization' => "Bearer #{token}",
        'Content-Type' => 'application/json'
      }
    }

    options[:query] = query if query
    options[:body] = body.to_json if body

    if ENV['DEBUG']
      puts "  API #{method.upcase} #{path}"
      puts "  Query: #{query.inspect}" if query
      puts "  Body: #{body.inspect}" if body
    end

    response = self.class.send(method, path, options)

    unless response.success?
      error_message = "API Error: #{response.code} - #{response.message}"

      if ENV['DEBUG']
        puts "  API Error: #{response.code} #{response.message}"
        puts "  Headers: #{response.headers.inspect}"
        puts "  Body: #{response.body}"
      end

      if response.parsed_response && response.parsed_response['errors']
        errors = response.parsed_response['errors']
        error_details = errors.map { |e| "#{e['title']}: #{e['detail']}" }.join(", ")
        error_message += " - #{error_details}"
      end

      raise error_message
    end

    response.parsed_response
  end

  def generate_token
    # Parse the private key
    private_key = OpenSSL::PKey::EC.new(@private_key)
    
    # Create the JWT token
    header = {
      'alg' => 'ES256',
      'kid' => @key_id,
      'typ' => 'JWT'
    }
    
    payload = {
      'iss' => @issuer_id,
      'iat' => Time.now.to_i,
      'exp' => Time.now.to_i + 20 * 60, # 20 minutes
      'aud' => 'appstoreconnect-v1'
    }
    
    JWT.encode(payload, private_key, 'ES256', header)
  end
end