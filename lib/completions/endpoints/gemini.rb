# frozen_string_literal: true

module DiscourseAi
  module Completions
    module Endpoints
      class Gemini < Base
        def self.can_contact?(model_name)
          %w[gemini-pro].include?(model_name)
        end

        def default_options
          {}
        end

        def provider_id
          AiApiAuditLog::Provider::Gemini
        end

        private

        def model_uri
          url =
            "https://generativelanguage.googleapis.com/v1beta/models/#{model}:#{@streaming_mode ? "streamGenerateContent" : "generateContent"}?key=#{SiteSetting.ai_gemini_api_key}"

          URI(url)
        end

        def prepare_payload(prompt, model_params, dialect)
          default_options
            .merge(model_params)
            .merge(contents: prompt)
            .tap { |payload| payload[:tools] = dialect.tools if dialect.tools.present? }
        end

        def prepare_request(payload)
          headers = { "Content-Type" => "application/json" }

          Net::HTTP::Post.new(model_uri, headers).tap { |r| r.body = payload }
        end

        def extract_completion_from(response_raw)
          parsed = JSON.parse(response_raw, symbolize_names: true)

          response_h = parsed.dig(:candidates, 0, :content, :parts, 0)

          @has_function_call ||= response_h.dig(:functionCall).present?
          @has_function_call ? response_h[:functionCall] : response_h.dig(:text)
        end

        def partials_from(decoded_chunk)
          decoded_chunk
            .split("\n")
            .map do |line|
              if line == ","
                nil
              elsif line.starts_with?("[")
                line[1..-1]
              elsif line.ends_with?("]")
                line[0..-1]
              else
                line
              end
            end
            .compact_blank
        end

        def extract_prompt_for_tokenizer(prompt)
          prompt.to_s
        end

        def has_tool?(_response_data)
          @has_function_call
        end

        def add_to_buffer(function_buffer, _response_data, partial)
          if partial[:name].present?
            function_buffer.at("tool_name").content = partial[:name]
            function_buffer.at("tool_id").content = partial[:name]
          end

          if partial[:args]
            argument_fragments =
              partial[:args].reduce(+"") do |memo, (arg_name, value)|
                memo << "\n<#{arg_name}>#{value}</#{arg_name}>"
              end
            argument_fragments << "\n"

            function_buffer.at("parameters").children =
              Nokogiri::HTML5::DocumentFragment.parse(argument_fragments)
          end

          function_buffer
        end
      end
    end
  end
end
