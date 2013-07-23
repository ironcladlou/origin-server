module OpenShift
  module Runtime
    module UpgradeType
      COMPATIBLE   = 'compatible'
      INCOMPATIBLE = 'incompatible'
    end

  	class UpgradeItinerary
  	  def initialize(gear_home, entries = nil, has_incompatible = false)
  	  	@gear_home = gear_home
        @entries = entries
        @has_incompatible = has_incompatible
  	  end

      def create_entry(cartridge_name, upgrade_type)
      	@entries[cartridge_name] = upgrade_type

      	if upgrade_type == UpgradeType::INCOMPATIBLE
      	  @has_incompatible = true
      	end
      end

      def has_incompatible_upgrade?
      	@has_incompatible
      end

      def each_cartridge
        entries.each_pair do |name, upgrade_type|
          yield name, upgrade_type if block_given?
        end
      end

      def persist
        itinerary_file = itinerary_file(@gear_home)
      	jsonish_self = { entries: @entries, has_incompatible: @has_incompatible}
        IO.write(itinerary_file, jsonish_self)
      end

      def self.itinerary_file(gear_home)
        PathUtils.join(gear_home, %w(app-root runtime .upgrade_itinerary))
      end

      def self.for_gear(gear_home)
      	itinerary_file = itinerary_file(gear_home)
        serialized_self = IO.read(itinerary_file)
        jsonish_self = JSON.load(serialized_self)
        UpgradeItinerary.new(gear_home, jsonish_self[:entries], jsonish_self[:has_incompatible])
      end
  	end
  end
end