ASM POC Rules Engine
====================

There is a light weight rules engine under ```ASM::RuleEngine``` that implements the basic ideas found in a rule engine without the commonly used RETE algorithm.

In general rules engines are used for data processing, constructing SQL queries and such, this POS is using it a bit differently to capture program flow so this rule engine has a few behaviours that people familiar with Drools and others might find surprising:

  * Typical rule engines will process rules in any order and rules should be idempotent and be very careful about their selection criteria.  The ASM rule engine has a priority and will run rules by priority.  Selection criteria though do still require great care.
  * Rule engines operate on a state object.  Should the state object be changed by a rule the entire rule set will get rerun meaning a single rule can get processed a few times in the life of a specific execution.  This just won't work for us.  You can change state but do not expect past rules to be run again without actually rerunning it.
  * Big rule engines like Drools implement the RETE algorithm for really optimised rule selection and perform very well for 10s of thousands of rules, ours does not and has ```O(n)``` performance for the selection process, we will have a relatively small rule set though.
  * It's common for rule engines to operate on ```any data of type X``` rather than giving these date items names.  I found this awkward so at the moment the state items have names.


Overview of a Rule
-------------------

A rule is in essence a big ```if..then...else``` statement, a rule file is made up of 5 parts:

  * the rule name, does not need to be unique
  * optional expressions of what items should be in the state
  * optional named conditions and an expression to inspect the state and determine if the rule want to act
  * the logic to run
  * rule modifiers like priority and if it should run on failed sets

Here's a simple example showing all the above:

```ruby
ASM::RuleEngine.new_rule(:equalogic_teardown) do
  require_state :deployment, ASM::ServiceDeployment
  require_state :component, Hash

  condition(:is_teardown) { state[:deployment].is_teardown? }

  condition(:equalogic_volume) do
    run = false

    if state[:component]["type"] == "STORAGE"
      resources = state[:component]["resources"].select {|r| r["id"] == "asm::volume::equallogic"}

      run = true unless resources.empty?
    end

    run
  end

  execute_when { is_teardown && equalogic_volume }

  set_priority 10

  execute do
    @logger.debug("Starting teardown block")
    volume = ASM::Type::to_resource(state[:component])
    volume.logger = @logger
    volume.deployment = state[:deployment]
    volume.remove_storage_from_cluster!
    volume.process!
  end
end
```

This rule is called ```equalogic_teardown```.  It requires 2 items to be in the state one called ```:deployment``` that has to be of the type ```ASM::ServiceDeployment``` and one called ```:component``` that can be a ```Hash```.

It then creates a 2 conditions - ```is_teardown``` and ```equalogic_volume```, these inspect the state and must evaluate to true/false.

It combines the 2 named conditions in the ```execute_when``` block to form a boolean expression that in turn would return ```true```/```false```.  The ```condition``` blocks are optional and this ```execute_when``` can inspect state directly but the method shown here makes things a bit more readable.

Any rule without ```condition```s, ```require_state``` and ```execute_when``` will run always.

The ```priority``` is changed from the usual ```50``` to ```10``` and finally the ```execute``` block is where the work is done to tear down the volume.

When the engine processes rules it takes a state you prepared and runs the ```execute_when``` logic for every rule on disk sorted by priority it then runs the ```execute``` block should ```execute_when``` evaluate to true.

By default if any rule in the set had a failure - exception during the execute block - further rules will not get executed but a rule can add ```run_on_fail``` to it's body and this will cause the rule to run anyway.

A logger is setup and usable anywhere, this defaults to ```ASM.logger``` or whatever is passed into the Engine when creating it.

The ```condition```, ```execute_when``` and ```execute``` sections are standard ruby ```Proc```s and so you cannot use ```return```.  It can be awkward to not use return, if you have to you can do something like:

```ruby
execute(&lambda {
 return "hello world"
})
```

Using the Engine
----------------

As you can see from the description above the ```state``` is the data the rule runs on, without state there would be little point in a rule existing, setting up state and running the rules is pretty simple:

```ruby
require 'asm/rule_engine'

engine = ASM::RuleEngine.new("/opt/asm-deployer/rules:/opt/Dell/conf/rules", @logger)
state = engine.new_state

state.add(:deployment, @service_deployment)
state.add(:component, component)
engine.process_rules(state)
```

This sets up the rule engine to read rules from 2 directories and to use the logger instance.  Rules should match the pattern ```*_rule.rb```.

Rules are read at engine start, a shared rule engine across an entire app should be possible but it's probably not thread safe and I anticipate that we'll have a situation where we store rules in different directories for different places in our code so it's best to just set up a new engine every time it's needed.

A new state is created in the context of this engine and 2 data items are added to it and finally the rules are processed as described above.

The state holds data but also tracks what rules acted on the data, stores output from the rules and offer some helpers to interact with these.

Interacting with the State
--------------------------

#### Data Items
The state is where all the data goes for a rule set execution.  Rules can manipulate the state to facilitate communications between different rules.  Imagine two rules:

```ruby
ASM::RuleEngine.new_rule(:test) do
  execute do
    state.add(:ping, true)
    "hello world"
  end
end
```

```ruby
ASM::RuleEngine.new_rule(:test) do
  require_state :ping, :boolean

  execute_when { !!state[:ping] }

  set_priority 90

  execute do
    "pong: %s" % state[:ping]
  end
end
```

Here the first rule adds some state - ```:ping``` - that the 2nd rule relies on. Had the 2nd rule set it's ```priority``` to ```10``` it would not run as it would be considered before the state got the ```:ping``` item.

#### Results
##### acted\_on\_by
The state tracks all the results and rules that elected to act on the state and can be accessed using the ```acted_on_by``` method, it returns an array of ```ASM::RuleEngine::Rule```:

```ruby
>> state = engine.new_state
>> state.add(:test, "hello world")
>> engine.process_rules(state)
>> pp state.acted_on_by
[#<ASM::RuleEngine::Rule:70208048772700 priority: 50 name: test @ rules/test_rule.rb>,
 #<ASM::RuleEngine::Rule:70208048769400 priority: 90 name: test @ rules/test_that_needs_ping_rule.rb>]
```

#### results
You can access the results as an array using ```results``` or use the ```each_result``` helper to iterate them, every result is one of ```ASM::RuleEngine::Result```:

```ruby
state.each_result do |result|
  puts "Rule: %s" % result.rule
  puts "  Rule ran successfully: %s" % !result.error
  if !result.error
    puts "  Output:"
    puts "-------------"
    puts result.out
    puts "-------------"
    puts
  else
    puts "  Error: %s: %s: %s" % [result.error.class, result.error.backtrace[0], result.error]
  end
end
```

This produces:

```
Rule: #<ASM::RuleEngine::Rule:70208048772700 priority: 50 name: test @ rules/test_rule.rb>
  Rule ran successfully: true
  Output:
-------------
Hello world
-------------

Rule: #<ASM::RuleEngine::Rule:70208048769400 priority: 90 name: test @ rules/test_that_needs_ping_rule.rb>
  Rule ran successfully: true
  Output:
-------------
pong: true
-------------
```

As you can see every rule output is tracked separately and stored in order they acted on the state.  Any exceptions are stored as their complete Exception object complete with backtraces.


