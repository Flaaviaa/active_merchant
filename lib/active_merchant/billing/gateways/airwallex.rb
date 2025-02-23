module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class AirwallexGateway < Gateway
      self.test_url = 'https://api-demo.airwallex.com/api/v1'
      self.live_url = 'https://pci-api.airwallex.com/api/v1'

      # per https://www.airwallex.com/docs/online-payments__overview, cards are accepted in all EU countries
      self.supported_countries = %w[AT AU BE BG CY CZ DE DK EE GR ES FI FR GB HK HR HU IE IT LT LU LV MT NL PL PT RO SE SG SI SK]
      self.default_currency = 'AUD'
      self.supported_cardtypes = %i[visa master]

      self.homepage_url = 'https://airwallex.com/'
      self.display_name = 'Airwallex'

      ENDPOINTS = {
        login: '/authentication/login',
        setup: '/pa/payment_intents/create',
        sale: '/pa/payment_intents/%{id}/confirm',
        capture: '/pa/payment_intents/%{id}/capture',
        refund: '/pa/refunds/create',
        void: '/pa/payment_intents/%{id}/cancel'
      }

      def initialize(options = {})
        requires!(options, :client_id, :client_api_key)
        @client_id = options[:client_id]
        @client_api_key = options[:client_api_key]
        super
        @access_token = setup_access_token
      end

      def purchase(money, card, options = {})
        requires!(options, :return_url)

        payment_intent_id = create_payment_intent(money, options)
        post = {
          'request_id' => request_id(options),
          'merchant_order_id' => merchant_order_id(options),
          'return_url' => options[:return_url]
        }
        add_card(post, card, options)
        add_descriptor(post, options)
        add_stored_credential(post, options)
        post['payment_method_options'] = { 'card' => { 'auto_capture' => false } } if authorization_only?(options)

        commit(:sale, post, payment_intent_id)
      end

      def authorize(money, payment, options = {})
        # authorize is just a purchase w/o an auto capture
        purchase(money, payment, options.merge({ auto_capture: false }))
      end

      def capture(money, authorization, options = {})
        raise ArgumentError, 'An authorization value must be provided.' if authorization.blank?

        post = {
          'request_id' => request_id(options),
          'merchant_order_id' => merchant_order_id(options),
          'amount' => amount(money)
        }
        add_descriptor(post, options)

        commit(:capture, post, authorization)
      end

      def refund(money, authorization, options = {})
        raise ArgumentError, 'An authorization value must be provided.' if authorization.blank?

        post = {}
        post[:amount] = amount(money)
        post[:payment_intent_id] = authorization
        post[:request_id] = request_id(options)
        post[:merchant_order_id] = merchant_order_id(options)

        commit(:refund, post)
      end

      def void(authorization, options = {})
        raise ArgumentError, 'An authorization value must be provided.' if authorization.blank?

        post = {}
        post[:request_id] = request_id(options)
        post[:merchant_order_id] = merchant_order_id(options)
        add_descriptor(post, options)

        commit(:void, post, authorization)
      end

      def verify(credit_card, options = {})
        MultiResponse.run(:use_first_response) do |r|
          r.process { authorize(100, credit_card, options) }
          r.process(:ignore_result) { void(r.authorization, options) }
        end
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(/(\\\"number\\\":\\\")\d+/, '\1[REDACTED]').
          gsub(/(\\\"cvc\\\":\\\")\d+/, '\1[REDACTED]')
      end

      private

      def request_id(options)
        options[:request_id] || generate_timestamp
      end

      def merchant_order_id(options)
        options[:merchant_order_id] || options[:order_id] || generate_timestamp
      end

      def generate_timestamp
        (Time.now.to_f.round(2) * 100).to_i.to_s
      end

      def setup_access_token
        token_headers = {
          'Content-Type' => 'application/json',
          'x-client-id' => @client_id,
          'x-api-key' => @client_api_key
        }
        response = ssl_post(build_request_url(:login), nil, token_headers)
        JSON.parse(response)['token']
      end

      def build_request_url(action, id = nil)
        base_url = (test? ? test_url : live_url)
        base_url + ENDPOINTS[action].to_s % { id: id }
      end

      def create_payment_intent(money, options = {})
        post = {}
        add_invoice(post, money, options)
        add_order(post, options)
        post[:request_id] = "#{request_id(options)}_setup"
        post[:merchant_order_id] = "#{merchant_order_id(options)}_setup"
        add_descriptor(post, options)

        response = commit(:setup, post)
        raise ArgumentError.new(response.message) unless response.success?

        response.params['id']
      end

      def add_billing(post, card, options = {})
        return unless has_name_info?(card)

        billing = post['payment_method']['card']['billing'] || {}
        billing['email'] = options[:email] if options[:email]
        billing['phone'] = options[:phone] if options[:phone]
        billing['first_name'] = card.first_name
        billing['last_name'] = card.last_name
        billing_address = options[:billing_address]
        billing['address'] = build_address(billing_address) if has_required_address_info?(billing_address)

        post['payment_method']['card']['billing'] = billing
      end

      def has_name_info?(card)
        # These fields are required if billing data is sent.
        card.first_name && card.last_name
      end

      def has_required_address_info?(address)
        # These fields are required if address data is sent.
        return unless address

        address[:address1] && address[:country]
      end

      def build_address(address)
        return unless address

        address_data = {} # names r hard
        address_data[:country_code] = address[:country]
        address_data[:street] = address[:address1]
        address_data[:city] = address[:city] if address[:city] # required per doc, not in practice
        address_data[:postcode] = address[:zip] if address[:zip]
        address_data[:state] = address[:state] if address[:state]
        address_data
      end

      def add_invoice(post, money, options)
        post[:amount] = amount(money)
        post[:currency] = (options[:currency] || currency(money))
      end

      def add_card(post, card, options = {})
        post['payment_method'] = {
          'type' => 'card',
          'card' => {
            'expiry_month' => format(card.month, :two_digits),
            'expiry_year' => card.year.to_s,
            'number' => card.number.to_s,
            'name' => card.name,
            'cvc' => card.verification_value
          }
        }
        add_billing(post, card, options)
      end

      def add_order(post, options)
        return unless shipping_address = options[:shipping_address]

        physical_address = build_shipping_address(shipping_address)
        first_name, last_name = split_names(shipping_address[:name])
        shipping = {}
        shipping[:first_name] = first_name if first_name
        shipping[:last_name] = last_name if last_name
        shipping[:phone_number] = shipping_address[:phone_number] if shipping_address[:phone_number]
        shipping[:address] = physical_address
        post[:order] = { shipping: shipping }
      end

      def build_shipping_address(shipping_address)
        address = {}
        address[:city] = shipping_address[:city]
        address[:country_code] = shipping_address[:country]
        address[:postcode] = shipping_address[:zip]
        address[:state] = shipping_address[:state]
        address[:street] = shipping_address[:address1]
        address
      end

      def add_stored_credential(post, options)
        return unless stored_credential = options[:stored_credential]

        external_recurring_data = post[:external_recurring_data] = {}

        case stored_credential.dig(:reason_type)
        when 'recurring', 'installment'
          external_recurring_data[:merchant_trigger_reason] = 'scheduled'
        when 'unscheduled'
          external_recurring_data[:merchant_trigger_reason] = 'unscheduled'
        end

        external_recurring_data[:original_transaction_id] = stored_credential.dig(:network_transaction_id)
        external_recurring_data[:triggered_by] = stored_credential.dig(:initiator) == 'cardholder' ? 'customer' : 'merchant'
      end

      def authorization_only?(options = {})
        options.include?(:auto_capture) && options[:auto_capture] == false
      end

      def add_descriptor(post, options)
        post[:descriptor] = options[:description] if options[:description]
      end

      def parse(body)
        JSON.parse(body)
      end

      def commit(action, post, id = nil)
        url = build_request_url(action, id)
        post_headers = { 'Authorization' => "Bearer #{@access_token}", 'Content-Type' => 'application/json' }
        response = parse(ssl_post(url, post_data(post), post_headers))

        Response.new(
          success_from(response),
          message_from(response),
          response,
          authorization: authorization_from(response),
          avs_result: AVSResult.new(code: response.dig('latest_payment_attempt', 'authentication_data', 'avs_result')),
          cvv_result: CVVResult.new(response.dig('latest_payment_attempt', 'authentication_data', 'cvc_code')),
          test: test?,
          error_code: error_code_from(response)
        )
      end

      def handle_response(response)
        case response.code.to_i
        when 200...300, 400, 404
          response.body
        else
          raise ResponseError.new(response)
        end
      end

      def post_data(post)
        post.to_json
      end

      def success_from(response)
        %w(REQUIRES_PAYMENT_METHOD SUCCEEDED RECEIVED REQUIRES_CAPTURE CANCELLED).include?(response['status'])
      end

      def message_from(response)
        response.dig('latest_payment_attempt', 'status') || response['status'] || response['message']
      end

      def authorization_from(response)
        response.dig('latest_payment_attempt', 'payment_intent_id')
      end

      def error_code_from(response)
        response['provider_original_response_code'] || response['code'] unless success_from(response)
      end
    end
  end
end
