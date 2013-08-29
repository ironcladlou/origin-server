#!/usr/bin/env oo-ruby
require 'rubygems'
require 'json'
require 'stomp'
require 'fileutils'

module OpenShift
  module Runtime
    class UpgradeRobot
      def initialize(client, request_queue, reply_queue, label)
        @client = client
        @request_queue = request_queue
        @reply_queue = reply_queue
        @label = label
      end

      def execute
        log "Robot is starting to process requests from #{@request_queue}; replies => #{@reply_queue}"

        msg_count = 0
        @client.subscribe(@request_queue, { :ack => "client", "activemq.prefetchSize" => 1 }) do |msg|
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
              result = upgrade
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
            log "Error processing message:"
            log e.message
            log e.backtrace.join("\n")
          end
        end

        loop do
          sleep 1
        end
      end

      # a mock implementation for now
      def upgrade
        result = { upgrade_complete: (rand(100) < 95) }
        sleep([1, 3, 5].sample)
        result
      end

      def log(msg)
        log_file = "/var/log/oo-robo-#{@label}.log"
        FileUtils.touch log_file unless File.exists?(log_file)

        file = File.open(log_file, 'a')
        begin
          file.puts msg
        ensure
          file.close
        end
      end
    end
  end
end

def log_crash(msg)
  log_file = "/var/log/oo-robo-crash.log"
  FileUtils.touch log_file unless File.exists?(log_file)

  file = File.open(log_file, 'a')
  begin
    file.puts msg
  ensure
    file.close
  end
end

request_queue = ARGV[0]
reply_queue = ARGV[1]

if (!request_queue || !reply_queue)
  puts "upgrade_robot.rb <request_queue> <reply_queue>"
end

pid = $$
pid_file = "/tmp/oo-robo/robot.pid.#{pid}"

FileUtils.touch(pid_file)

Signal.trap('TERM') do
  begin
    puts "Cleaning up robot pidfile at #{pid_file}"
    FileUtils.rm_f(pid_file) if File.exist?(pid_file)
  rescue
  ensure
    exit 0
  end
end

opts = { hosts: [ { login: "mcollective", passcode: "marionette", host: '10.147.177.27', port: 6163 } ] }

begin
  ::OpenShift::Runtime::UpgradeRobot.new(Stomp::Client.new(opts), request_queue, reply_queue, "robot-#{pid}").execute
rescue => e
  log_crash "Error processing message:"
  log_crash e.message
  log_crash e.backtrace.join("\n")
ensure
  FileUtils.rm_f(pid_file) if File.exist?(pid_file)
end
