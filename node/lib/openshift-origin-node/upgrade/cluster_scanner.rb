module OpenShift
  module Runtime
    module Upgrade
      class ClusterScanner
        def self.find_gears_to_upgrade
          require '/var/www/openshift/broker/config/environment'
          Rails.configuration.analytics[:enabled] = false
          Rails.configuration.msg_broker[:rpc_options][:disctimeout] = 20

          puts "Getting all active gears..."
          active_gears_map = OpenShift::ApplicationContainerProxy.get_all_active_gears

          puts "Getting all logins..."
          query = {"group_instances.gears.0" => {"$exists" => true}}
          options = {:fields => [ "uuid",
                      "domain_id",
                      "name",
                      "created_at",
                      "component_instances.cartridge_name",
                      "component_instances.group_instance_id",
                      "group_instances._id",
                      "group_instances.gears.uuid",
                      "group_instances.gears.server_identity",
                      "group_instances.gears.name"], 
                     :timeout => false}

          ret = []
          user_map = {}
          OpenShift::DataStore.find(:cloud_users, {}, {:fields => ["_id", "uuid", "login"], :timeout => false}) do |hash|
            metadata.logins_count += 1
            user_uuid = hash['uuid']
            user_login = hash['login']
            user_map[hash['_id'].to_s] = [user_uuid, user_login]
          end

          domain_map = {}
          OpenShift::DataStore.find(:domains, {}, {:fields => ["_id" , "owner_id"], :timeout => false}) do |hash|
            domain_map[hash['_id'].to_s] = hash['owner_id'].to_s
          end

          puts "Finding all gears..."
          all_gears = []
          OpenShift::DataStore.find(:applications, query, options) do |app|
            user_id = domain_map[app['domain_id'].to_s]
            if user_id.nil?
              relocated_domain = Domain.where(_id: Moped::BSON::ObjectId(app['domain_id'])).first
              next if relocated_domain.nil?
              user_id = relocated_domain.owner._id.to_s
              user_uuid = user_id
              user_login = relocated_domain.owner.login
            else
              if user_map.has_key? user_id
                user_uuid,user_login = user_map[user_id]
              else
                relocated_user = CloudUser.where(_id: Moped::BSON::ObjectId(user_id)).first
                next if relocated_user.nil?
                user_uuid = relocated_user._id.to_s
                user_login = relocated_user.login
              end
            end

            app['group_instances'].each do |gi|
              gi['gears'].each do |gear|
                server_identity = gear['server_identity']
                all_gears << { uuid: gear['uuid'], name: gear['name'], app_name: gear['app_name'], node: gear['server_identity'], login: user_login }
              end
            end
          end

          active_gears = []
          inactive_gears = []

          all_gears.each do |gear|
            if active_gears_map.include?(gear[:node])
              gear[:active] = true
              active_gears << gear
            else
              gear[:active] = false
              inactive_gears << gear
            end
          end

          active_gears + inactive_gears
        end
      end
    end
  end
end
