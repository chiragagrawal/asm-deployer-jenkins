require "hashie"

require "asm/errors"
require "asm/service_migration_deployment"

module ASM
  module Data
    class NoDeployment < StandardError
    end
    class NoExecution < StandardError
    end
    class InvalidStatus < StandardError
    end
    class InvalidLogLevel < StandardError
    end
    class UpdateFailed < StandardError
    end
    class InvalidComponentException < StandardError
    end

    class Deployment
      VALID_STATUS_LIST = %w(pending in_progress complete error cancelled).freeze
      TERMINAL_STATUS_LIST = %w(complete error).freeze
      INCOMPLETE_STATUS_LIST = %w(pending in_progress).freeze

      VALID_LOG_LEVEL_LIST = %w(debug info warn error).freeze

      attr_accessor :id
      attr_accessor :execution_id
      attr_accessor :component_ids # map of component uuids to ids
      attr_reader :db

      # Set the status of all in_progress deployments to failed. Intended to
      # be used across reboots where we know that no deployments are running.
      # That way in the event of power outage we can mark all the in_progress
      # deployments as failed so the user can go and delete them
      def self.mark_in_progress_failed(db, logger=nil)
        query = <<EOT
SELECT d.id AS deployment_id, "name", e.id AS "execution_id"
    FROM deployments AS d JOIN executions AS e ON d.id = e.deployment_id
    WHERE e.status = 'in_progress'
EOT
        db.transaction do
          db[query].each do |row|
            msg = "Marking deployment #{row[:name]} ##{row[:deployment_id]} as error"
            logger.info(msg) if logger
            db[:executions].where(:id => row[:execution_id]).update(
              :status => "error", :message => "Aborted due to reboot")
            db[:components].where(:execution_id => row[:execution_id],
                                  :status => INCOMPLETE_STATUS_LIST).update(
                                    :status => "cancelled", :message => "Aborted due to reboot")
          end
        end
      end

      def initialize(db)
        @db = db
      end

      # Creates a database entry if it doesn't exist, raises an exception otherwise
      def create(asm_guid, name)
        self.id = db[:deployments].insert(:asm_guid => asm_guid, :name => name)
      end

      # Loads a deployment from db; raises an exception if a previous deployment
      # has already been created or loaded
      def load(asm_guid)
        row = db.from(:deployments).where(:asm_guid => asm_guid).first
        raise ASM::NotFoundException unless row
        self.id = row[:id]
        row = db.from(:executions).where(:deployment_id => id).order(:id).last
        self.execution_id = row[:id] if row
      end

      def create_execution(deployment_data)
        db.transaction do
          db['UPDATE executions SET "order" = "order" + 1 WHERE deployment_id = ?', id].update
          query = <<EOT
SELECT component_uuid, c.status
       FROM deployments AS d JOIN executions AS e
       ON d.id = e.deployment_id JOIN components AS c ON e.id = c.execution_id
       WHERE e."order" = 1 AND d.id = ?
EOT
          old_statuses = db[query, id].inject({}) do |hash, element|
            hash[element[:component_uuid]] = element[:status]
            hash
          end
          row = {:deployment_id => id, :order => 0, :status => "in_progress"}
          self.execution_id = db[:executions].insert(row)
          self.component_ids = {}

          migration_component_ids = []
          migration_component = (ASM::ServiceMigrationDeployment.components_for_migration(deployment_data) || {})
          (migration_component["SERVER"] || []).each do |comp|
            migration_component_ids.push(comp["id"])
          end
          deployment_data["serviceTemplate"]["components"].each do |comp|
            status = if old_statuses[comp["id"]] && !migration_component_ids.include?(comp["id"])
                       old_statuses[comp["id"]]
                     else
                       "pending"
                     end
            row = {:execution_id => execution_id,
                   :asm_guid => comp["asmGUID"],
                   :component_uuid => comp["id"],
                   :name => comp["name"],
                   :type => comp["type"],
                   :status => status}
            component_ids[comp["id"]] = db[:components].insert(row)
          end
        end
      end

      # Returns structured data intended for direct rendering to REST call
      #
      # Pass order = 0 to get the most recent, 1 to get 2nd most, etc.
      # Pass nothing to get the last execution created on this object
      def get_execution(order=nil)
        execution_query = <<EOT
SELECT e.id AS "execution_id", asm_guid AS "id", "name", "status", "message", start_time, end_time
    FROM deployments AS d JOIN executions AS e ON d.id = e.deployment_id
EOT
        if order
          execution_query += " WHERE d.id = ? AND e.order = ?"
        else
          raise NoExecution unless execution_id
          execution_query += " WHERE d.id = ? AND e.id = ?"
        end

        components_query = <<EOT
SELECT component_uuid AS "id", "asm_guid", "name", "type", "status", "message",
       "start_time", "end_time"
    FROM components
    WHERE execution_id = ?
    ORDER BY "type", "name"
EOT
        ret = nil
        db.transaction do
          execution_selector = order ? order : execution_id
          ret = db[execution_query, id, execution_selector].first
          unless ret
            raise(ASM::NotFoundException, "No execution #{execution_selector} for deployment #{id}")
          end
          ret["components"] = []
          db[components_query, ret[:execution_id]].each do |component|
            ret["components"].push(component)
          end
        end
        Hashie::Mash.new(ret)
      end

      def set_status(status) # rubocop:disable Style/AccessorMethodName:
        status = status.to_s if status.is_a?(Symbol)

        raise NoExecution unless execution_id
        raise InvalidStatus unless VALID_STATUS_LIST.include?(status)

        query = if TERMINAL_STATUS_LIST.include?(status)
                  "UPDATE executions SET status = ?, end_time = NOW() WHERE id = ?"
                else
                  "UPDATE executions SET status = ? WHERE id = ?"
                end

        db.transaction do
          unless db[query, status, execution_id].update == 1
            msg = "Failed to set deployment #{id} execution #{execution_id} status to #{status}"
            raise(UpdateFailed, msg)
          end
          if TERMINAL_STATUS_LIST.include?(status)
            db[:components].where(:execution_id => execution_id,
                                  :status => "pending").update(
                                    :status => "cancelled")
          end
        end
      end

      def get_component_id(component_uuid)
        component_ids[component_uuid] || raise(InvalidComponentException, "No such component id: #{component_uuid}")
      end

      def set_component_status(component_uuid, status)
        status = status.to_s if status.is_a?(Symbol)
        raise NoExecution unless execution_id
        raise(InvalidStatus, "Not a valid component status: #{status}") unless VALID_STATUS_LIST.include?(status)
        component_id = get_component_id(component_uuid)
        query = if TERMINAL_STATUS_LIST.include?(status)
                  "UPDATE components SET status = ?, end_time = NOW() WHERE id = ? AND execution_id = ?"
                else
                  "UPDATE components SET status = ? WHERE id = ? AND execution_id = ?"
                end

        unless db[query, status, component_id, execution_id].update == 1
          msg = "Failed to set component #{component_id} execution #{execution_id} status to #{status}"
          raise(UpdateFailed, msg)
        end
      end

      def update_component_asm_guid(component_id, new_asm_guid)
        db[:components]
          .where(:execution_id => execution_id,
                 :component_uuid => component_id)
          .update(:asm_guid => new_asm_guid)
      end

      def remove_component(component_id)
        db[:components].where(:execution_id => execution_id, :component_uuid => component_id).delete
        component_ids.delete(component_id)
      end

      def get_component_status(component_uuid)
        raise NoExecution unless execution_id
        component_id = get_component_id(component_uuid)
        query = <<EOT
select status from components where id = ? AND execution_id = ?
EOT

        db[query, component_id, execution_id].first
      end

      # Creates a user-facing log message. Also updates the message field
      # on either the component or execution with the latest message
      def log(level, message, options={})
        level = level.to_s if level.is_a?(Symbol)

        raise NoExecution unless execution_id
        raise(InvalidLogLevel, "Not a valid log level: #{level}") unless VALID_LOG_LEVEL_LIST.include?(level)

        component_id = if options[:component_id]
                         get_component_id(options[:component_id])
                       end

        db.transaction do
          data_set = if component_id
                       db[:components].where(:id => component_id, :execution_id => execution_id)
                     else
                       db[:executions].where(:id => execution_id)
                     end

          # NOTE: The update has to happen before the insert because the insert
          # obtains an implicit lock on the executions / components table
          # due to foreign keys. The reverse order results in deadlocks.
          unless data_set.update(:message => message) == 1
            raise(UpdateFailed, "Failed to update execution #{execution_id} status to #{status}")
          end

          row = {:execution_id => execution_id, :component_id => component_id,
                 :level => level, :message => message}
          db[:execution_log_entries].insert(row)
        end
      end

      def get_logs(options={})
        raise NoExecution unless execution_id
        component_id = if options[:component_id]
                         get_component_id(options[:component_id])
                       end
        where = {:execution_id => execution_id}
        where[:component_id] = component_id if component_id
        db[:execution_log_entries].where(where).order(:timestamp).collect do |log|
          Hashie::Mash.new(log)
        end
      end

      def delete
        raise NoDeployment unless id
        db.from(:deployments).where(:id => id).delete
      end
    end
  end
end
