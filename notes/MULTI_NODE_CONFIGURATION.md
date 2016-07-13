ASM Multi-Node Configuration
============================

This page is a work-in-progress describing how to configure ASM in a multi-node configuration where various services are split off from the ASM UI node. For now, all nodes are expected to be installed with the standard ASM OVF and manually configured to turn various services on or off.

Services
--------

This is a brief summary of services that ASM currently relies on and run on the appliance:

* **asm-core** - UI and public Java REST services (tomcat)
* **razor** - PXE boot server (torquebox/jboss) 
* **puppet** - puppet master server
* **asm-deployer** - Deployment orchestration (torquebox / jboss)
* **nagios** - Hardware monitoring
* **graphite** - Historical hardware monitoring data
* **PostgreSQL** - database

These services have been made more configurable so they can run on separate nodes. Communication is done via HTTPS REST services or via queues. An example configuration might be:

### Master node

* **asm-core** - UI and public Java REST services (tomcat)
* **razor** - PXE boot server (torquebox/jboss) 
* **puppet** - puppet master server
* **asm-deployer (master)** - Deployment orchestration (torquebox / jboss)
* **PostgreSQL** - database

### Worker node(s)

* **asm-deployer (worker)** - Simple execution of inventory / config scripts.

### Monitoring node

* **nagios** - Hardware monitoring
* **graphite** - Historical hardware monitoring data

Deployment Clustering
---------------------

asm-deployer can be configured to execute puppet configuration jobs over a queue. The jobs will be picked up and executed by a listener running on either the same node or an external one. For now it is expected that at least one instance of asm-deployer is running on the ASM UI node. The notes below will refer to this as the master node and all other nodes involved in deployment clustering as worker nodes. It is currently required that the asm-deployer master instance reside on the ASM UI node because deployments depend on puppet device configuration files written by ASM UI directly to the filesystem. The master node is special because:

1. It will host the secrets REST service at /asm/secret Worker nodes will use that service to retrieve device credentials.
2. The deployment will be initiated by the ASM UI from this node, i.e. the deployment will be kicked off by calling POST /asm/deployment on this node.

The clustering of master and worker nodes uses Torquebox clustering. Torquebox uses HornetQ as the message queue. Currently the only feature of Torquebox clustering that asm-deployer uses is the message queue.

### Common Node Configuration

1. Configure the node with a unique hostname.

2. Disable SELinux and iptables: `setenforce 0 && service iptables stop`. *This restriction needs to be removed*

3. Edit `/etc/hosts` and set `dellasm` and all `asm-*-api` hosts to the external IP of the **master** node instead of 127.0.0.1

4. Edit `/etc/sysconfig/razor` and changed `BIND_ADDRESS` to the **current** node IP.

5. Edit `/etc/init.d/razor` and add `--clustered` after `torquebox run` The full line will be: 

        CMD="/opt/jruby-1.7.8/bin/torquebox run --clustered --bind-address $BIND_ADDRESS --port $RAZOR_PORT"

6. Clear out torquebox data directory and restart:

        rm -rf /opt/jruby-1.7.8/lib/ruby/gems/shared/gems/torquebox-server-3.0.1-java/jboss/standalone/data
        service razor restart

7. On older appliance builds the httpd SSL certificates must be regenerated to contain all of the required api hostnames. Starting with build #4901 this is not required. To regenerate the hostnames run:

        rm /etc/pki/tls/certs/localhost.crt
        service configureVM start
        service httpd restart

### Master Node Configuration

1. Prevent the master node from executing configuration jobs by setting concurrency to 0 on the asm_jobs queue. Edit `/opt/asm-deployer/torquebox.rb` so that the asm_jobs queue configuration section looks like:

          queue '/queues/asm_jobs' do
            exported true
            processor ASM::Messaging::PuppetApplyProcessor do
              concurrency 0
              synchronous true
              selector "version = 1 and action = 'puppet_apply'"
            end
          end

2. Set `work_method` to `:queue` in `/opt/asm-deployer/config.yaml`:

        # Method of executing puppet configuration and inventory jobs:
        #
        # :local - jobs are directly executed on this torquebox host
        # :queue - jobs are placed on a queue for later execution by local or remote
        #          members of the torquebox cluster. work_queue must be set to the name
        #          of the queue to use. Note this generally must match the queue name
        #          used to set up the work Processor in torquebox.rb
        work_method: :queue

3. Deploy these changes.

        cd /opt/asm-deployer
        torquebox deploy

### Worker Node Configuration

1. Copy these SSL certificate files from `/opt/Dell/ssl` on the master node to the same location on the worker node: `ca-cert.pem`, `dellasm_u.key`, `dellasm.cert`

2. Optionally increase the number of jobs that may execute concurrently on the node. 10 might be a good number for the default ASM OVF configuration (4 CPU / 16GB). Edit `/opt/asm-deployer/torquebox.rb`:

          queue '/queues/asm_jobs' do
            exported true
            processor ASM::Messaging::PuppetApplyProcessor do
              concurrency 10
              synchronous true
              selector "version = 1 and action = 'puppet_apply'"
            end
          end

3. Configure various services to access the master node services in `/opt/asm-deployer/config.yaml`. The key changes are setting `secrets_source` to `:rest` and setting the `asm_secrets` and `razor` urls to HTTPS on the master node, and setting the SSL client certificate values:

        # Source of "secret" information, e.g. credentials, etc.
        #
        # :local - secret information is queried directly from database(s) running on
        #          localhost and files on the local filesystem
        # :rest - secret information is obtained from a REST service. url.asm_secrets
        #         must be set to the base URL of the service to call.
        secrets_source: :rest
        
        # REST client configuration options. Generally these are passed straight through
        # as RestClient options. Exceptions are made for ssl_client_cert and
        # ssl_client_key which are expected to be file paths whereas RestClient expects
        # them to have already been run through various OpenSSL initialization methods.
        #
        # Example:
        #
        http_client_options:
          ssl_ca_file: /opt/Dell/ssl/ca-cert.pem
          ssl_client_cert: /opt/Dell/ssl/dellasm.cert
          ssl_client_key: /opt/Dell/ssl/dellasm_u.key
        
        url:
          asm: http://asm-core-api:9080
          asm_server: http://asm-core-api:9080/AsmManager/Server
          asm_network: http://asm-core-api:9080/VirtualServices/Network
          asm_chassis: http://asm-core-api:9080/AsmManager/Chassis
          asm_device: http://asm-core-api:9080/AsmManager/ManagedDevice
          asm_deployer: http://asm-deployer-api:8081/asm
          asm_secrets: https://asm-deployer-api/secret
          razor: https://asm-razor-api/razor
          puppetdb: http://asm-puppetdb-api:7080

4. Deploy these changes.

        cd /opt/asm-deployer
        torquebox deploy

5. Disable unnecessary services.

        for i in asmdb httpd nagios pe-httpd pe-mcollective pe-puppet pe-puppetdb razor tog-pegasus tomeeASM carbon-cache
        do
          chkconfig $i off
          service $i stop
        done

