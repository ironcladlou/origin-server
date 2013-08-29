require 'rubygems'
require 'json'
require 'fileutils'
require 'openshift-origin-node/utils/shell_exec'

module OpenShift
  module Runtime
    class RobotMaster
      def initialize(request_queue, reply_queue, logger, path = '/tmp/oo-robo')
        @request_queue = request_queue
        @reply_queue = reply_queue
        @path = path
        @logger = logger
      end

      def logger
        @logger
      end

      def initialize_store
        FileUtils.mkdir_p('/tmp/oo-robo')
      end

      def scale_to(count)
        current_count = robot_count
        workers_to_scale = count - current_count

        if (workers_to_scale < 0)
          scale_down(workers_to_scale.abs)
        elsif (workers_to_scale > 0)
          scale_up(workers_to_scale)
        end

        "Scaled to #{count} workers"
      end

      def robot_count
        Dir.glob(File.join(@path, 'robot.pid.*')).size
      end

      def scale_up(count)
        logger.debug("Scaling up by #{count} workers")

        count.times do |i|
          spawn_worker
        end

        logger.debug("Finished scaling up by #{count} workers")
      end

      def spawn_worker()
        logger.debug("Spawning worker for request queue #{@request_queue} and reply queue: #{@reply_queue}")

        script = "/opt/rh/ruby193/root/usr/share/gems/gems/openshift-origin-node-1.14.0/lib/openshift-origin-node/upgrade/upgrade_robot.rb"
        
        fork { OpenShift::Runtime::Utils::oo_spawn("nohup #{script} #{@request_queue} #{@reply_queue} &") }

        logger.debug("Spawned worker process")
      end

      def scale_down(count)
        logger.debug("Scaling down by #{count} workers")

        Dir.glob(File.join(@path, 'robot.pid.*')).each_with_index do |pidfile, i|
          pid = File.basename(pidfile)[10..-1]

          destroy_worker(pid)

          break if (i+1) == count
        end

        logger.debug("Finished scaling down by #{count} workers")
      end

      def destroy_worker(pid)
        logger.debug("Sending TERM to worker #{pid}")
        out, err, status = OpenShift::Runtime::Utils::oo_spawn("kill -TERM #{pid}")
        logger.debug("Terminated worked #{pid} (status=#{status}); out=#{out}, err=#{err}")
      end
    end
  end
end
