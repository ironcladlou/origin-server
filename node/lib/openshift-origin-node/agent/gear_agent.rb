#!/usr/bin/env oo-ruby
require 'rubygems'
require 'json'
require 'stomp'
require 'fileutils'
require 'openshift-origin-node'
require 'openshift-origin-node/utils/hourglass'

module OpenShift
  module Runtime
    class GearAgent
      def initialize(client, request_queue, reply_queue)
        @client = client
        @request_queue = request_queue
        @reply_queue = reply_queue
      end

      def get_app_container_from_args(args)
        app_uuid = args['--with-app-uuid'].to_s if args['--with-app-uuid']
        app_name = args['--with-app-name'].to_s if args['--with-app-name']
        gear_uuid = args['--with-container-uuid'].to_s if args['--with-container-uuid']
        gear_name = args['--with-container-name'].to_s if args['--with-container-name']
        namespace = args['--with-namespace'].to_s if args['--with-namespace']
        quota_blocks = args['--with-quota-blocks']
        quota_files  = args['--with-quota-files']
        uid          = args['--with-uid']

        quota_blocks = nil if quota_blocks && quota_blocks.to_s.empty?
        quota_files = nil if quota_files && quota_files.to_s.empty?
        uid = nil if uid && uid.to_s.empty?

        OpenShift::Runtime::ApplicationContainer.new(app_uuid, gear_uuid, uid, app_name, gear_name, namespace, quota_blocks, quota_files, OpenShift::Runtime::Utils::Hourglass.new(235))
      end

      def with_container_from_args(args)
        output = ''
        exitcode = 0
        begin
          container = get_app_container_from_args(args)
          yield(container, output)
        rescue OpenShift::Runtime::Utils::ShellExecutionException => e
          #report_exception e
          output << "\n" unless output.empty?
          output << "Error: #{e.message}" if e.message
          output << "\n#{e.stdout}" if e.stdout.is_a?(String)
          output << "\n#{e.stderr}" if e.stderr.is_a?(String)
          exitcode = e.rc
        rescue Exception => e
          #report_exception e
          Log.instance.error e.message
          Log.instance.error e.backtrace.join("\n")
          exitcode = 1
          output = e.message
        end

        #{exitcode: exitcode, output: output}
        [exitcode, output]
      end

      def oo_update_configuration(args)
        config  = args['--with-config']
        auto_deploy = config['auto_deploy']
        deployment_branch = config['deployment_branch']
        keep_deployments = config['keep_deployments']
        deployment_type = config['deployment_type']

        with_container_from_args(args) do |container|
          container.set_auto_deploy(auto_deploy)
          container.set_deployment_branch(deployment_branch)
          container.set_keep_deployments(keep_deployments)
          container.set_deployment_type(deployment_type)
        end
      end

      def oo_deploy(args)
        hot_deploy = args['--with-hot-deploy']
        force_clean_build = args['--with-force-clean-build']
        ref = args['--with-ref']
        artifact_url = args['--with-artifact-url']
        out = StringIO.new
        err = StringIO.new
        addtl_params = nil

        rc, output = with_container_from_args(args) do |container|
          container.deploy(hot_deploy: hot_deploy, force_clean_build: force_clean_build, ref: ref, artifact_url: artifact_url, out: out, err: err)
          addtl_params = {deployments: container.calculate_deployments}
        end
        
        return rc, output, addtl_params
      end

      def oo_activate(args)
        deployment_id  = args['--with-deployment-id']
        out = StringIO.new
        err = StringIO.new
        addtl_params = nil

        rc, output = with_container_from_args(args) do |container|
          container.activate(deployment_id: deployment_id, out: out, err: err)
          addtl_params = {deployments: container.calculate_deployments}
        end

        return rc, output, addtl_params
      end

      def oo_authorized_ssh_key_add(args)
        ssh_key  = args['--with-ssh-key']
        key_type = args['--with-ssh-key-type']
        comment  = args['--with-ssh-key-comment']

        with_container_from_args(args) do |container|
          container.add_ssh_key(ssh_key, key_type, comment)
        end
      end

      def oo_authorized_ssh_key_remove(args)
        ssh_key = args['--with-ssh-key']
        key_type = args['--with-ssh-key-type']
        comment = args['--with-ssh-comment']

        with_container_from_args(args) do |container|
          container.remove_ssh_key(ssh_key, key_type, comment)
        end
      end

      def oo_authorized_ssh_keys_replace(args)
        ssh_keys  = args['--with-ssh-keys'] || []

        begin
          container = get_app_container_from_args(args)
          container.replace_ssh_keys(ssh_keys)
        rescue Exception => e
          report_exception e
          Log.instance.info e.message
          Log.instance.info e.backtrace
          return 1, e.message
        else
          return 0, ""
        end
      end

      def oo_broker_auth_key_add(args)
        iv    = args['--with-iv']
        token = args['--with-token']

        with_container_from_args(args) do |container|
          container.add_broker_auth(iv, token)
        end
      end

      def oo_broker_auth_key_remove(args)
        with_container_from_args(args) do |container|
          container.remove_broker_auth
        end
      end

      def oo_env_var_add(args)
        key   = args['--with-key']
        value = args['--with-value']

        with_container_from_args(args) do |container|
          container.add_env_var(key, value)
        end
      end

      def oo_env_var_remove(args)
        key = args['--with-key']

        with_container_from_args(args) do |container|
          container.remove_env_var(key)
        end
      end

      def oo_user_var_add(args)
        variables = {}
        if args['--with-variables']
          JSON.parse(args['--with-variables']).each {|env| variables[env['name']] = env['value']}
        end
        gears = args['--with-gears'] ? args['--with-gears'].split(';') : []

        if variables.empty? and gears.empty?
          return -1, "In #{__method__} at least user environment variables or gears must be provided for #{args['--with-app-name']}"
        end

        cmd_rc, cmd_output = 0, ''

        wrapper_rc, wrapper_output = with_container_from_args(args) do |container|
          cmd_rc, cmd_output = container.user_var_add(variables, gears)
        end

        if wrapper_rc == 0
          return cmd_rc, cmd_output
        else
          return wrapper_rc, wrapper_output
        end
      end

      def oo_user_var_remove(args)
        unless args['--with-keys']
          return -1, "In #{__method__} no user environment variable names provided for #{args['--with-app-name']}"
        end

        keys  = args['--with-keys'].split(' ')
        gears = args['--with-gears'] ? args['--with-gears'].split(';') : []

        cmd_rc, cmd_output = 0, ''

        wrapper_rc, wrapper_output = with_container_from_args(args) do |container|
          cmd_rc, cmd_output = container.user_var_remove(keys, gears)
        end
        
        if wrapper_rc == 0
          return cmd_rc, cmd_output
        else
          return wrapper_rc, wrapper_output
        end
      end

      def oo_user_var_list(args)
        keys = args['--with-keys'] ? args['--with-keys'].split(' ') : []

        output = ''
        begin
          container = get_app_container_from_args(args)
          list      = container.user_var_list(keys)
          output    = 'CLIENT_RESULT: ' + list.to_json
        rescue Exception => e
          report_exception e
          Log.instance.info "#{e.message}\n#{e.backtrace}"
          return 1, e.message
        else
          return 0, output
        end
      end

      def oo_app_state_show(args)
        container_uuid = args['--with-container-uuid'].to_s if args['--with-container-uuid']
        app_uuid = args['--with-app-uuid'].to_s if args['--with-app-uuid']

        with_container_from_args(args) do |container, output|
          output << "\nCLIENT_RESULT: #{container.state.value}\n"
        end
      end

      def oo_force_stop(args)
        container_uuid = args['--with-container-uuid'].to_s if args['--with-container-uuid']
        app_uuid = args['--with-app-uuid'].to_s if args['--with-app-uuid']

        with_container_from_args(args) do |container|
          container.force_stop
        end
      end

      def oo_tidy(args)
        with_container_from_args(args) do |container|
          container.tidy
        end
      end

      def oo_expose_port(args)
        cart_name = args['--cart-name']

        with_container_from_args(args) do |container, output|
          output << container.create_public_endpoints(cart_name)
        end
      end

      def oo_conceal_port(args)
        cart_name = args['--cart-name']

        with_container_from_args(args) do |container, output|
          output << container.delete_public_endpoints(cart_name)
        end
      end

      def oo_connector_execute(args)
        cart_name        = args['--cart-name']
        pub_cart_name    = args['--publishing-cart-name']
        hook_name        = args['--hook-name']
        connection_type  = args['--connection-type']
        input_args       = args['--input-args']

        with_container_from_args(args) do |container, output|
          output << container.connector_execute(cart_name, pub_cart_name, connection_type, hook_name, input_args)
        end
      end

      def oo_configure(args)
        cart_name        = args['--cart-name']
        template_git_url = args['--with-template-git-url']
        manifest         = args['--with-cartridge-manifest']

        with_container_from_args(args) do |container, output|
          output << container.configure(cart_name, template_git_url, manifest)
        end
      end

      def oo_post_configure(args)
        cart_name = args['--cart-name']
        template_git_url = args['--with-template-git-url']

        deployments = nil

        rc, output = with_container_from_args(args) do |container, output|
          output << container.post_configure(cart_name, template_git_url)

          if container.cartridge_model.get_cartridge(cart_name).deployable?
            deployments = {deployments: container.calculate_deployments}
          end
        end

        return rc, output, deployments
      end

      def oo_deconfigure(args)
        cart_name = args['--cart-name']

        with_container_from_args(args) do |container, output|
          output << container.deconfigure(cart_name)
        end
      end

      def oo_unsubscribe(args)
        cart_name     = args['--cart-name']
        pub_cart_name = args['--publishing-cart-name']

        with_container_from_args(args) do |container, output|
          output << container.unsubscribe(cart_name, pub_cart_name).to_s
        end
      end

      def oo_deploy_httpd_proxy(args)
        cart_name = args['--cart-name']

        with_container_from_args(args) do |container|
          container.deploy_httpd_proxy(cart_name)
        end
      end

      def oo_remove_httpd_proxy(args)
        cart_name = args['--cart-name']

        with_container_from_args(args) do |container|
          container.remove_httpd_proxy(cart_name)
        end
      end

      def oo_restart_httpd_proxy(args)
        cart_name = args['--cart-name']

        with_container_from_args(args) do |container|
          container.restart_httpd_proxy(cart_name)
        end
      end

      def oo_start(args)
        cart_name = args['--cart-name']

        with_container_from_args(args) do |container, output|
          output << container.start(cart_name)
        end
      end

      def oo_stop(args)
        cart_name = args['--cart-name']

        with_container_from_args(args) do |container, output|
          output << container.stop(cart_name)
        end
      end

      def oo_restart(args)
        cart_name = args['--cart-name']
        options = {}
        options[:all] = true if args['--all']
        options[:parallel_concurrency_ratio] = args['--parallel_concurrency_ratio'].to_f if args['--parallel_concurrency_ratio']

        with_container_from_args(args) do |container, output|
          container.restart(cart_name, options)
        end
      end

      def oo_reload(args)
        cart_name = args['--cart-name']

        with_container_from_args(args) do |container, output|
          output << container.reload(cart_name)
        end
      end

      def oo_status(args)
        cart_name = args['--cart-name']

        with_container_from_args(args) do |container, output|
          output << container.status(cart_name)
        end
      end

      def oo_threaddump(args)
        cart_name = args['--cart-name']

        output = ""
        begin
          container = get_app_container_from_args(args)
          output    = container.threaddump(cart_name)
        rescue OpenShift::Runtime::Utils::ShellExecutionException => e
          report_exception e
          Log.instance.info "#{e.message}\n#{e.backtrace}\n#{e.stderr}"
          return e.rc, "CLIENT_ERROR: action 'threaddump' failed #{e.message} #{e.stderr}"
        rescue Exception => e
          report_exception e
          Log.instance.info "#{e.message}\n#{e.backtrace}"
          return 1, e.message
        else
          return 0, output
        end
      end

      def oo_update_cluster(args)
        with_container_from_args(args) do |container|
          container.update_cluster(args['--proxy-gears'], args['--web-gears'], args['--rollback'], args['--sync-new-gears'])
        end
      end

      def oo_update_proxy_status(args)
        with_container_from_args(args) do |container|
          container.update_proxy_status(action: args['--action'],
                                        gear_uuid: args['--gear_uuid'],
                                        cartridge: args['--cart-name'],
                                        persist: args['--persist'])
        end
      end

      def execute
        puts "NodeAgent is starting to process requests from #{@request_queue}; replies => #{@reply_queue}"

        msg_count = 0
        @client.subscribe(@request_queue, { :ack => "client", "activemq.prefetchSize" => 1 }) do |msg|
          puts "Got a message: #{msg}"
          content = JSON.load(msg.body)
          puts "Got message: #{content}"

          action = "oo_#{content['action'].gsub('-', '_')}"
          args = content['args']
          exitcode, output = self.send(action, args)

          result = {
            'exitcode' => exitcode,
            'output' => output
          }
          puts "Sending reply hash: #{result}"
          @client.publish(@reply_queue, JSON.dump(result), {:persistent => true})
          @client.acknowledge(msg)

        end

        loop do
          sleep 1
        end
      end
    end
  end
end

uuid = ARGV[0]

unless uuid
  puts "usage:  gear_agent.rb <uuid>"
  exit 1
end

request_queue = "/queue/mcollective.gear.#{uuid}.request"
reply_queue = "/queue/mcollective.gear.#{uuid}.reply"

pid = $$
FileUtils.mkdir_p('/tmp/oo-hackday')
pid_file = "/tmp/oo-hackday/gearagent.#{uuid}.pid.#{pid}"

FileUtils.touch(pid_file)

Signal.trap('TERM') do
  begin
    puts "Cleaning up pidfile at #{pid_file}"
    FileUtils.rm_f(pid_file) if File.exist?(pid_file)
  rescue
  ensure
    exit 0
  end
end

opts = { hosts: [ { login: "mcollective", passcode: "marionette", host: 'localhost', port: 6163 } ] }

begin
  ::OpenShift::Runtime::GearAgent.new(Stomp::Client.new(opts), request_queue, reply_queue).execute
rescue => e
  puts e.message
  puts e.backtrace.join("\n")
ensure
  FileUtils.rm_f(pid_file) if File.exist?(pid_file)
end
