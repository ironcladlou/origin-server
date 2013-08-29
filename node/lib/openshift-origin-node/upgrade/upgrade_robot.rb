#!/usr/bin/env oo-ruby
require 'rubygems'
require 'json'
require 'stomp'
require 'fileutils'

module OpenShift
  module Runtime
  	class UpgradeRobot
      def initialize(client, request_queue, reply_queue)
      	@client = client
        @request_queue = request_queue
        @reply_queue = reply_queue
      end

      def execute
      	@client.subscribe(@request_queue, {:ack => "client" }) do |msg|
          puts "Processing message; will reply on #{@reply_queue}"

          begin
            content = JSON.load(msg.body)

            uuid = content['uuid']
            namespace = content['namespace']
            target_version = content['target_version']
            node = content['node']
            attempt = content['attempt']
            ignore_cartridge_version = content['ignore_cartridge_version']

            output = ''
  	        exitcode = 0

            begin
              result = { upgrade_complete: [true, false].sample }
            rescue OpenShift::Runtime::Utils::ShellExecutionException => e
              exitcode = 127
              output += "Gear failed to upgrade: #{e.message}\n#{e.stdout}\n#{e.stderr}"
            rescue Exception => e
              exitcode = 1
              output += "Gear failed to upgrade with exception: #{e.message}\n#{e.backtrace}\n"
            end

            reply = { 'uuid' => uuid,
            	        'output' => output,
            	        'exitcode' => exitcode,
                      'attempt' => attempt,
            	        'gear_upgrader_result' => result
            	      }

            @client.publish(@reply_queue, JSON.dump(reply), {:persistent => true})
            @client.acknowledge(msg)
          rescue => e
            puts e.message
            puts e.backtrace.join("\n")
          end
        end

        loop do
          sleep 1
        end
      end

    end
  end
end

request_queue = ARGV[0]
reply_queue = ARGV[1]

if (!request_queue || !reply_queue)
  puts "upgrade_robot.rb <request_queue> <reply_queue>"
end

pid_file = "/tmp/oo-robo/robot.pid.#{$$}"

FileUtils.touch(pid_file)

Signal.trap('TERM') do
  puts "Cleaning up robot pidfile at #{pid_file}"
  FileUtils.rm_f(pid_file) if File.exist?(pid_file)
end

opts = { hosts: [ { login: "mcollective", passcode: "marionette", host: '10.147.177.27', port: 6163 } ] }

begin
  ::OpenShift::Runtime::UpgradeRobot.new(Stomp::Client.new(opts), request_queue, reply_queue).execute
ensure
  FileUtils.rm_f(pid_file) if File.exist?(pid_file)
end
