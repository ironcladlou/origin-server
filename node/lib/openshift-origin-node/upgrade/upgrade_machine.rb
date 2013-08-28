#!/bin/env ruby
require 'state_machine'
require 'stomp'
require 'mongoid'

require cluster_scanner

module OpenShift
  module Runtime
    module Upgrade
      class UpgradeExecution
        include Mongoid::Document
        include Mongoid::Timestamps

        store_in collection: "upgrade_executions"

        field :target_version, type: String
        
        has_many :gear_machines
      end

      class GearMachine
        include Mongoid::Document
        include Mongoid::Timestamps

        store_in collection: "upgrade_gear_machines"

        field :uuid, type: String
        field :node, type: String
        field :target_version, type: String
        field :active, type: Boolean, default: true
        field :num_attempts, type: Integer, default: 0
        field :max_attempts, type: Integer
        
        embeds_many :upgrade_results, :order => :created_at.desc
        belongs_to :upgrade_execution

        state_machine :state, :initial => :new do
          before_transition any => :upgrading, :do => :queue_upgrade

          event :upgrade do
            transition :new => :upgrading
          end

          event :complete_upgrade do
            transition :upgrading => :complete, :if => lambda {|gear| gear.upgrade_results.last.successful? }
            transition :upgrading => same, :if => lambda {|gear| gear.upgrade_results.last.failed? && gear.num_attempts < gear.max_attempts }
            transition :upgrading => :failed
          end
        end

        def queue_upgrade
          self.num_attempts += 1
          puts "queueing upgrade for #{self.uuid} (attempt #{self.num_attempts} of #{self.max_attempts})"
        end

        def complete_upgrade(result = nil, *args)
          raise "Result is required" unless result

          self.upgrade_results << result
          super
        end
      end

      class UpgradeResult
        include Mongoid::Document
        include Mongoid::Timestamps

        field :upgrade_errors, type: Array, default: []
        field :remote_results, type: Hash

        embedded_in :gear_machine

        def successful?
          self.upgrade_errors.empty?
        end

        def failed?
          !successful?
        end
      end     

      class Coordinator
        #include ClusterScanner

        def initialize
        end

        def create_execution(target_version, max_attempts)
          execution = UpgradeExecution.new(target_version: target_version)

          find_gears_to_upgrade.each do |gear|
            execution << GearMachine.new(uuid: gear[:uuid], node: gear[:node], target_version: target_version, max_attempts: max_attempts, active: gear[:active])
          end
        end

        def find_gears_to_upgrade
          gears = []
          (1..5) do |node_count|
            (1..10) do |gear_count|
              gears << { uuid: "uuid#{node_count}-#{gear_count}", name: "gear#{node_count}-#{gear_count}",
                         app_name: "app#{node_count}-#{gear_count}", node: "node#{node_count}", login: "login#{node_count}-#{gear_count}", active: true }
            end
          end
          gears
        end
      end
    end
  end
end

Mongoid.load!("mongoid.yml")

include OpenShift::Runtime::Upgrade



execution.gears << OpenShift::Runtime::Upgrade::GearMachine.new(uuid: "db054b6", node: "ip-1-2-3-4", target_version: '2.0.31', max_attempts: 2)

puts "initial gear state: #{gear.state}"
puts "initial gear results: #{gear.upgrade_results.inspect}"
puts "initia gear: #{gear.max_attempts} #{gear.num_attempts}"

puts "calling upgrade"

gear.upgrade
puts "post-upgrade call state: #{gear.state}"

puts "calling complete upgrade"
gear.complete_upgrade(OpenShift::Runtime::Upgrade::UpgradeResult.new(upgrade_errors: ['error 1', 'error 2'], remote_results: { remote_key_1: 'val1', remote_key_2: 'val2'}))

puts "post-complete upgrade state: #{gear.state}"
puts "post-complete upgrade results: #{gear.upgrade_results.inspect}"

puts "calling another complete upgrade"
gear.complete_upgrade(OpenShift::Runtime::Upgrade::UpgradeResult.new(upgrade_errors: ['error 3', 'error 4'], remote_results: { remote_key_3: 'val3', remote_key_4: 'val4'}))

puts "post-complete upgrade state: #{gear.state}"
puts "post-complete upgrade results: #{gear.upgrade_results.inspect}"
