require 'openshift-origin-common/utils/path_utils'

require_relative 'selinux'

module OpenShift
  module Runtime
    module Utils
      class UpgradeProgress
        attr_reader :gear_home, :gear_base_dir, :uuid, :steps

        def initialize(gear_base_dir, gear_home, uuid)
          @gear_base_dir = gear_base_dir
          @gear_home = gear_home
          @uuid = uuid
          @buffer = []
          @steps = {}
        end

        def init_store
          runtime_dir = File.join(gear_home, %w(app-root runtime))

          if !File.exists?(runtime_dir)
            log "Creating data directory #{runtime_dir} for #{@gear_home} because it does not exist"
            FileUtils.mkpath(runtime_dir)
            FileUtils.chmod_R(0o750, runtime_dir)
            PathUtils.oo_chown_R(@uuid, @uuid, runtime_dir)
            mcs_label = OpenShift::Runtime::Utils::SELinux::get_mcs_label(uuid)
            OpenShift::Runtime::Utils::SELinux.set_mcs_label_R(mcs_label, runtime_dir)
          end
        end

        def step(name)
          unless @steps.has_key?(name)
            @steps[name] = {
              :status => complete?(name) ? :complete : :incomplete,
              :errors => [],
              :context => {}
            }
          end

          step = @steps[name]

          if incomplete?(name)
            begin
              yield(step[:context], step[:errors])
            rescue OpenShift::Runtime::Utils::ShellExecutionException => e
              steps[:errors] << "Unhandled shell exception performing step: #{e.message}\nreturn code: #{e.rc}\nstdout: #{e.stdout}\nstderr: #{e.stderr}"
              raise e
            rescue => e
              step[:errors] << "Unhandled exception performing step: #{e.message}\n#{e.backtrace.join("\n")}"
              raise e
            end

            mark_complete(name) if step[:errors].empty?
          end
        end

        def incomplete?(marker)
          not complete?(marker)
        end

        def complete?(marker)
          File.exists?(marker_path(marker))
        end

        def mark_complete(marker)
          IO.write(marker_path(marker), '')
          log "Marking step #{marker} complete"
          @steps[marker][:status] = :complete
        end

        def has_instruction?(instruction)
          File.exists?(instruction_path(instruction))
        end

        def set_instruction(instruction)
          FileUtils.touch(instruction_path(instruction))
          log "Creating migration instruction #{instruction}"
        end

        def done
          globs = %w(.upgrade_complete* .upgrade_instruction*)

          globs.each do |glob|
            Dir.glob(File.join(gear_home, 'app-root', 'runtime', glob)).each do |entry|
              FileUtils.rm_f(entry)
            end
          end
        end

        def marker_path(marker)
          File.join(gear_home, 'app-root', 'runtime', ".upgrade_complete_#{marker}")
        end

        def instruction_path(instruction)
          File.join(gear_home, 'app-root', 'runtime', ".upgrade_instruction_#{instruction}")
        end

        def log(string, event_args = {})
          if event_args.has_key?(:rc) || event_args.has_key?(:stdout) || event_args.has_key?(:stderr)
            string = "#{string}\nrc: #{event_args[:rc]}\nstdout: #{event_args[:stdout]}\nstderr: #{event_args[:stderr]}"
          end

          @buffer << string
          string
        end

        def report
          @buffer.join("\n")
        end
      end
    end
  end
end