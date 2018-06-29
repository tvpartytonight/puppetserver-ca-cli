require 'optparse'
require 'puppetserver/ca/version'
require 'puppetserver/ca/puppet_config'
require 'puppetserver/ca/x509_loader'

# Option parser declares several default options that,
# unless overridden will raise a SystemExit. We delete
# version and help here as that behavior was breaking
# test driving those flags.
OptionParser::Officious.delete('version')
OptionParser::Officious.delete('help')

module Puppetserver
  module Ca
    class CAError < StandardError
      attr_reader :messages
      def initialize(*args)
        @messages = []
        super
      end

      def add_message(msg)
        @messages << msg
      end
    end

    class SetupCliParser
      def self.parse(cli_args, out, err)
        parser, inputs = parse_inputs(cli_args)
        exit_code = validate_inputs(inputs, parser.help, out, err)

        return inputs, exit_code
      end

      def self.validate_inputs(input, usage, out, err)
        exit_code = nil

        if input['help']
          out.puts usage
          exit_code = 0
        elsif input['version']
          out.puts Puppetserver::Ca::VERSION
          exit_code = 0
        elsif input['cert-bundle'].nil? || input['private-key'].nil?
          err.puts 'Error:'
          err.puts 'Missing required argument'
          err.puts '    Both --cert-bundle and --private-key are required'
          err.puts ''
          err.puts usage
          exit_code = 1
        end

        exit_code
      end

      def self.parse_inputs(inputs)
        parsed = {}

        parser = OptionParser.new do |opts|
          opts.banner = 'Usage: puppetserver ca setup [options]'
          opts.on('--help', 'This setup specific help output') do |help|
            parsed['help'] = true
          end
          opts.on('--version', 'Output the version') do |v|
            parsed['version'] = true
          end
          opts.on('--config CONF', 'Path to puppet.conf') do |conf|
            parsed['config'] = conf
          end
          opts.on('--private-key KEY', 'Path to PEM encoded key') do |key|
            parsed['private-key'] = key
          end
          opts.on('--cert-bundle BUNDLE', 'Path to PEM encoded bundle') do |bundle|
            parsed['cert-bundle'] = bundle
          end
          opts.on('--crl-chain [CHAIN]', 'Path to PEM encoded chain') do |chain|
            parsed['crl-chain'] = chain
          end
        end

        parser.parse(inputs)

        return parser, parsed
      end
    end

    class Cli
      VALID_COMMANDS = ['setup']

      def self.run!(cli_args = ARGV, out = STDOUT, err = STDERR)

        if VALID_COMMANDS.include?(cli_args.first)
          case cli_args.shift
          when 'setup'
            input, exit_code = SetupCliParser.parse(cli_args, out, err)

            return exit_code if exit_code

            files = input.values_at('cert-bundle', 'private-key')
            files << input['crl-chain'] if input['crl-chain']
            files << input['config'] if input['config']

            errors = validate_file_paths(files)
            unless errors.empty?
              err.puts "Error:"
              errors.each do |message|
                err.puts "    #{message}"
              end
              return 1
            end

            unless input['crl-chain']
              err.puts 'Warning:'
              err.puts '    No CRL chain given'
              err.puts '    Full CRL chain checking will not be possible'
              err.puts ''
            end

            loader = X509Loader.new(input['cert-bundle'],
                                    input['private-key'],
                                    input['crl-chain'])

            loader.load_and_validate!

            unless loader.errors.empty?
              err.puts "Error:"
              loader.errors.each do |message|
                err.puts "    #{message}"
              end
              return 1
            end

            puppet = PuppetConfig.new(input['config'])
            puppet.load

            unless puppet.errors.empty?
              err.puts "Error:"
              puppet.errors.each do |message|
                err.puts "    #{message}"
              end
              return 1
            end

            File.open(puppet.ca_cert_path, 'w') do |f|
              loader.certs.each do |cert|
                f.puts cert.to_pem
              end
            end

            File.open(puppet.ca_key_path, 'w') do |f|
              f.puts loader.key.to_pem
            end

            File.open(puppet.ca_crl_path, 'w') do |f|
              loader.crls.each do |crl|
                f.puts crl.to_pem
              end
            end

            return 0
          end
        else
          general_parser, input = parse_general_inputs(cli_args)

          if input['help']
            out.puts general_parser.help
          elsif input['version']
            out.puts Puppetserver::Ca::VERSION
          else
            err.puts general_parser.help
            return 1
          end
        end

        return 0
      end

      def self.validate_file_paths(one_or_more_paths)
        errors = []
        Array(one_or_more_paths).each do |path|
          if !File.exist?(path) || !File.readable?(path)
            errors << "Could not read file '#{path}'"
          end
        end

        errors
      end

      def self.parse_general_inputs(inputs)
        parsed = {}
        general_parser = OptionParser.new do |opts|
          opts.banner = 'Usage: puppetserver ca <command> [options]'
          opts.on('--help', 'This general help output') do |help|
            parsed['help'] = true
          end
          opts.on('--version', 'Output the version') do |v|
            parsed['version'] = true
          end
        end

        general_parser.parse(inputs)

        return general_parser, parsed
      end

    end
  end
end
