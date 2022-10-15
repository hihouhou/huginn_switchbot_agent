module Agents
  class SwitchbotAgent < Agent
    include FormConfigurable
    can_dry_run!
    no_bulk_receive!
    default_schedule 'every_1h'

    description <<-MD
      The Switchbot Agent interacts with Switchbot API and can create events / tasks if wanted / needed.

      The `type` can be like checking the device's info.
    MD

    def default_options
      {
        'type' => '',
        'token' => '',
        'secret' => '',
        'device' => '',
        'debug' => 'false',
        'expected_receive_period_in_days' => '2',
        'changes_only' => 'true'
      }
    end

    form_configurable :debug, type: :boolean
    form_configurable :token, type: :string
    form_configurable :device, type: :string
    form_configurable :secret, type: :string
    form_configurable :expected_receive_period_in_days, type: :string
    form_configurable :changes_only, type: :boolean
    form_configurable :type, type: :array, values: ['get_device', 'soy_cs_pending_rewards']
    def validate_options
      errors.add(:base, "type has invalid value: should be 'get_device'") if interpolated['type'].present? && !%w(get_device soy_cs_pending_rewards).include?(interpolated['type'])

      unless options['token'].present?
        errors.add(:base, "token is a required field")
      end

      unless options['secret'].present?
        errors.add(:base, "secret is a required field")
      end

      if options.has_key?('changes_only') && boolify(options['changes_only']).nil?
        errors.add(:base, "if provided, changes_only must be true or false")
      end

      if options.has_key?('debug') && boolify(options['debug']).nil?
        errors.add(:base, "if provided, debug must be true or false")
      end

      unless options['expected_receive_period_in_days'].present? && options['expected_receive_period_in_days'].to_i > 0
        errors.add(:base, "Please provide 'expected_receive_period_in_days' to indicate how many days can pass before this Agent is considered to be not working")
      end
    end

    def working?
      event_created_within?(options['expected_receive_period_in_days']) && !recent_error_logs?
    end

    def receive(incoming_events)
      incoming_events.each do |event|
        interpolate_with(event) do
          log event
          trigger_action
        end
      end
    end

    def check
      trigger_action
    end

    private

    def log_curl_output(code,body)

      log "request status : #{code}"

      if interpolated['debug'] == 'true'
        log "body"
        log body
      end

    end

    def generate_nonce
      (Time.now.to_f * 1000).to_i
    end

    def get_sign(ts,nonce)
      mixed_token = interpolated['token'].dup
      mixed_token.concat("#{ts}")
      mixed_token.concat("#{nonce}")
      Base64.encode64(OpenSSL::HMAC.digest('sha256', interpolated['secret'], mixed_token)).gsub(/\n/, '')
    end

    def get_device(ts)
      nonce = generate_nonce
      sign = get_sign(ts,nonce)
      url = 'https://api.switch-bot.com/v1.1/devices/' + interpolated['device'] + '/status'
      if interpolated['debug'] == 'true'
        log "url #{url}"
        log "sign #{sign}"
        log "ts #{ts}"
        log "token #{interpolated['token']}"
      end

      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request.content_type = "application/json"
      request["Authorization"] = interpolated['token']
      request["sign"] = sign
      request["t"] = ts.to_i
      request["nonce"] = nonce
      
      req_options = {
        use_ssl: uri.scheme == "https",
      }
      
      response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
        http.request(request)
      end

      log_curl_output(response.code,response.body)

      payload = JSON.parse(response.body)

      if response.code == '200' or payload['message'] == 'success'
        if interpolated['changes_only'] == 'true'
          if payload.to_s != memory['get_device']
            memory['get_device'] = payload.to_s
            create_event payload: payload
          end
        else
          if payload.to_s != memory['get_device']
            memory['get_device'] = payload.to_s
          end
          create_event payload: payload
        end
      end
    end


    def trigger_action

      ts = Time.now.to_i * 1000
      case interpolated['type']
      when "get_device"
        get_device(ts)
      else
        log "Error: type has an invalid value (#{type})"
      end
    end
  end
end
