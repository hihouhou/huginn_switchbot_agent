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
        'type' => 'service_status',
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
    form_configurable :type, type: :array, values: ['get_devices_status', 'get_device_status', 'service_status', 'rate_limit_wometer']
    def validate_options
      errors.add(:base, "type has invalid value: should be 'get_device_status' 'get_devices_status' 'service_status' 'rate_limit_wometer'") if interpolated['type'].present? && !%w(get_device_status get_devices_status service_status rate_limit_wometer).include?(interpolated['type'])

      unless options['token'].present? || !['get_devices_status', 'get_device_status'].include?(options['type'])
        errors.add(:base, "token is a required field")
      end

      unless options['secret'].present? || !['get_devices_status', 'get_device_status'].include?(options['type'])
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
          trigger_action(event)
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

    def rate_limit_wometer(event)
      if !event.nil?
        if event.payload.to_s != memory["#{event.payload['context']['deviceMac']}"]
          if !memory["#{event.payload['context']['deviceMac']}"].nil?
            if interpolated['debug'] == 'true'
              log event.payload
            end
            last_status = memory["#{event.payload['context']['deviceMac']}"].gsub("=>", ": ")
            last_status = JSON.parse(last_status)
            if (event.payload['context']['timeOfSample'].to_i - last_status['context']['timeOfSample']) > 3600000
              if interpolated['debug'] == 'true'
                log "> 1H"
              end
              create_event payload: event.payload
              memory["#{event.payload['context']['deviceMac']}"] = event.payload.to_s
            else
              if interpolated['debug'] == 'true'
                log "< 1H"
              end
            end
          else
            if interpolated['debug'] == 'true'
              log "last_status is empty"
            end
            create_event payload: event.payload
            memory["#{event.payload['context']['deviceMac']}"] = event.payload.to_s
          end
        end
      end
    end

    def service_status()

      uri = URI.parse("https://status.switch-bot.com/api/v2/status.json")
      response = Net::HTTP.get_response(uri)

      log_curl_output(response.code,response.body)

      payload = JSON.parse(response.body)
      event = payload.dup
      event = { :status => { :name =>  "#{payload['page']['name']}", :indicator => "#{payload['status']['indicator']}", :description => "#{payload['status']['description']}" } }

      if interpolated['changes_only'] == 'true'
        if payload != memory['last_status']
          if memory['last_status'].nil?
            create_event payload: event
          elsif !memory['last_status']['status'].nil? and memory['last_status']['status'].present? and payload['status'] != memory['last_status']['status']
            create_event payload: event
          end
          memory['last_status'] = payload
        end
      else
        create_event payload: event
        if payload != memory['last_status']
          memory['last_status'] = payload
        end
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

    def get_devices_status(ts)
      nonce = generate_nonce
      sign = get_sign(ts,nonce)
#      url = 'https://api.switch-bot.com/v1.1/devices'
      if interpolated['debug'] == 'true'
#        log "url #{url}"
        log "sign #{sign}"
        log "ts #{ts}"
        log "nonce #{nonce}"
        log "token #{interpolated['token']}"
      end
#quickanddirty test start
#      command = %x{curl -s '#{url}' -H 'Authorization: #{interpolated['token']}' -H 'User-Agent: Switchbot (https://github.com/hihouhou/huginn_switchbot_agent)' -H 'sign: #{sign}' -H 'nonce: #{nonce}' -H 't: #{ts}' -H 'Content-type: application/json'}
#      if interpolated['debug'] == 'true'
#        log command
#      end
#      payload = JSON.parse(command)
#quickanddirty test stop
      headers = {
        'Authorization' => interpolated['token'],
        't' => ts,
        'sign' => sign,
        'nonce' => nonce,
      }
      
      client = NetHttp2::Client.new("https://api.switch-bot.com")
      response = client.call(:get, '/v1.1/devices', headers: headers)

#      uri = URI.parse(url)
#      request = Net::HTTP::Get.new(uri)
#      request.content_type = "application/json"
#      request["Authorization"] = interpolated['token']
#      request["sign"] = sign
#      request["t"] = ts.to_i
#      request["User-Agent"] = " Switchbot (https://github.com/hihouhou/huginn_switchbot_agent)"
#      request["nonce"] = nonce
#
#      req_options = {
#        use_ssl: uri.scheme == "https",
#      }
#
#      response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
#        http.request(request)
#      end
#
      log_curl_output(response.status,response.body)
#      log_curl_output(response.code,response.body)
      payload = response.body

      if payload['message'] == 'success'
        if interpolated['changes_only'] == 'true'
          if payload.to_s != memory['get_devices_status']
            payload['body']['deviceList'].each do |device|
              found = false
              if !memory['get_devices_status'].nil?
                last_status = memory['get_devices_status'].gsub("=>", ": ")
                last_status = JSON.parse(last_status)
                last_status['body']['deviceList'].each do |devicebis|
                  if device == devicebis
                    found = true
                  end
                  if interpolated['debug'] == 'true'
                    log "found is #{found}!"
                  end
                end
              end
              if found == false
                if interpolated['debug'] == 'true'
                  log "found is #{found}! so event created"
                  log device
                end
                create_event payload: device
              end
            end
            memory['get_devices_status'] = payload.to_s
          end
        else
          if payload.to_s != memory['get_devices_status']
            memory['get_devices_status'] = payload.to_s
          end
          create_event payload: payload
        end
      end
    end

    def get_device_status(ts)
      nonce = generate_nonce
      sign = get_sign(ts,nonce)
      url = 'https://api.switch-bot.com/v1.1/devices/' + interpolated['device'] + '/status'
      if interpolated['debug'] == 'true'
        log "url #{url}"
        log "sign #{sign}"
        log "ts #{ts}"
        log "token #{interpolated['token']}"
      end

#      uri = URI.parse(url)
#      request = Net::HTTP::Get.new(uri)
#      request.content_type = "application/json"
#      request["Authorization"] = interpolated['token']
#      request["sign"] = sign
#      request["t"] = ts.to_i
#      request["nonce"] = nonce
#
#      req_options = {
#        use_ssl: uri.scheme == "https",
#      }
#
#      response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
#        http.request(request)
#      end
#
#      log_curl_output(response.code,response.body)
#
#      payload = JSON.parse(response.body)

#quickanddirty test start
      command = %x{curl -s '#{url}' -H 'Authorization: #{interpolated['token']}' -H 'User-Agent: Switchbot (https://github.com/hihouhou/huginn_switchbot_agent)' -H 'sign: #{sign}' -H 'nonce: #{nonce}' -H 't: #{ts}' -H 'Content-type: application/json'}
      if interpolated['debug'] == 'true'
        log command
      end
#quickanddirty test stop
      payload = JSON.parse(command)
      if payload['message'] == 'success'
        if interpolated['changes_only'] == 'true'
          if payload.to_s != memory['get_device_status']
            memory['get_device_status'] = payload.to_s
            create_event payload: payload
          end
        else
          if payload.to_s != memory['get_device_status']
            memory['get_device_status'] = payload.to_s
          end
          create_event payload: payload
        end
      end
    end


    def trigger_action(event=nil)

      ts = Time.now.to_i * 1000
      case interpolated['type']
      when "get_device_status"
        get_device_status(ts)
      when "get_devices_status"
        get_devices_status(ts)
      when "service_status"
        service_status()
      when "rate_limit_wometer"
        rate_limit_wometer(event)
      else
        log "Error: type has an invalid value (#{type})"
      end
    end
  end
end
