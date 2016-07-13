# Configure TorqueBox global settings for our application.
#
# You can override this with your deployment descriptor outside this
# application; these establish our default, supported, configuration.
TorqueBox.configure do
  ruby do
    version       '1.9'
    compile_mode  'jit'
    interactive   false
  end

  web do
    context '/asm'
    rackup  'config.ru'
  end

  queue '/queues/asm_jobs' do
    exported true
    processor ASM::Messaging::JobProcessor do
      concurrency 0
      synchronous true
      selector "version = 1"
    end
  end

  job ASM::Processor::Cleanup_jobs do
    name 'asm.processor.cleanup'
    cron '0 * */1 * * ?'
  end

end
