module ASM
  class Service
    class RuleGen
      def self.configure_lane_migration(lane, priority, threaded=true)
        ->(_rule) do
          require_state(:processor, ASM::Service::Processor)
          require_state(:service, ASM::Service)
          require_state(:component_outcomes, Array)

          set_priority(priority)
          run_on_fail

          condition(:components?) { !state[:service].components_by_type(lane).empty? }

          execute_when { state[:service].migration? && components? }

          execute do
            outcomes = state[:component_outcomes]
            components = state[:service].components_by_type(lane)

            outcomes.concat(state[:processor].process_lane(components, "migration", threaded))

            # raise the first error we got from the lane we processed
            outcomes.each do |outcome|
              outcome[:results].each do |result|
                raise(result.error) if result.error
              end
            end
          end
        end
      end

      def self.configure_lane_teardown(lane, priority, threaded=true)
        ->(_rule) do
          require_state(:processor, ASM::Service::Processor)
          require_state(:service, ASM::Service)
          require_state(:component_outcomes, Array)

          set_priority(priority)
          run_on_fail

          condition(:components?) { !state[:service].components_by_type(lane).empty? }

          execute_when { state[:service].teardown? && components? }

          execute do
            outcomes = state[:component_outcomes]
            components = state[:service].components_by_type(lane)

            outcomes.concat(state[:processor].process_lane(components, "teardown", threaded))

            # raise the first error we got from the lane we processed
            outcomes.each do |outcome|
              outcome[:results].each do |result|
                raise(result.error) if result.error
              end
            end
          end
        end
      end
    end
  end
end
