require "spec_helper"
require "asm/razor"
require "asm/translatable"
require "json"

describe ASM::Razor do
  def mock_response(code, data, method=:get, *method_args)
    response = mock("response")
    response.stubs(:code).returns(code)
    json = JSON.generate(data)
    response.stubs(:to_s).returns(json)
    response.stubs(:to_str).returns(json)

    intermediary = mock("intermediary")
    expectation = intermediary.stubs(method)
    expectation.with(*method_args) if method_args
    expectation.returns(response)

    intermediary
  end

  def build_node_data(name, serial_number, facts={})
    facts["serial_number"] = serial_number
    {"name" => name,
     "hw_info" => {"serial" => serial_number.downcase},
     "facts" => facts}
  end

  let(:node_name) {"node1"}
  let(:nodes_url) {"api/collections/nodes"}
  let(:nodes) {{"items" => [{"name" => "node1"}, {"name" => "node2"}]}}
  let(:transport) {mock("transport")}
  let(:razor) {ASM::Razor.new}
  let(:node1) {build_node_data("node1", "NODE_1_SERIAL_NUMBER")}
  let(:node2) {build_node_data("node2", "NODE_2_SERIAL_NUMBER", "ipaddress" => "192.168.1.100")}

  before(:each) do
    SpecHelper.init_i18n
    config = Hashie::Mash.new
    config.http_client_options = {}
    config.url!.razor = "http://foo/bar"
    ASM.stubs(:config).returns(config)

    RestClient::Resource.stubs(:new).returns(transport)
    transport.stubs(:[]).with(nodes_url).returns(mock_response(200, nodes))
    transport.stubs(:[]).with("#{nodes_url}/node1").returns(mock_response(200, node1))
    transport.stubs(:[]).with("#{nodes_url}/node2").returns(mock_response(200, node2))
    transport.stubs(:[]).with("#{nodes_url}/bad_node").returns(mock_response(404, :msg => "No such node"))
  end

  describe "razor find_node" do
    describe "when node not found" do
      it "get should raise CommandException" do
        expect do
          razor.get("nodes", "bad_node")
        end.to raise_error(ASM::CommandException)
      end

      it "should return nil" do
        razor.find_node("NO_SUCH_SERIAL_NUMBER").should be_nil
      end

      it "should not return ip" do
        razor.find_host_ip("NO_SUCH_SERIAL_NUMBER").should be_nil
      end
    end

    describe "when node found" do
      it "get should return node" do
        razor.get("nodes", "node2").should == node2
      end

      it "should return node" do
        razor.find_node("NODE_2_SERIAL_NUMBER").should == node2
      end

      it "fail if multiple node matches found" do
        node3 = build_node_data("node3", "NODE_2_SERIAL_NUMBER", "ipaddress" => "192.168.1.101")
        transport.stubs(:[]).with("#{nodes_url}/node3").returns(mock_response(200, node3))

        nodes = {"items" => [{"name" => "node1"}, {"name" => "node2"}, {"name" => "node3"}]}
        transport.stubs(:[]).with(nodes_url).returns(mock_response(200, nodes))

        expect do
          razor.find_node("NODE_2_SERIAL_NUMBER").should == node2
        end.to raise_exception
      end

      it "should return ip" do
        razor.find_host_ip("NODE_2_SERIAL_NUMBER").should == "192.168.1.100"
      end
    end
  end

  describe "razor install_status" do
    let(:logs) { SpecHelper.json_fixture("razor_node_log.json") }
    let(:policy_name) {"policy-gsesx2-ff80808145a8f7d40145a8fc36630004"}
    let(:node_url) {"api/collections/nodes/%s/log" % node_name}

    before(:each) do
      config = Hashie::Mash.new
      config.http_client_options = {}
      config.url!.razor = "http://foo/bar"
      ASM.stubs(:config).returns(config)
    end

    describe "when no logs exist" do
      it "should return nil" do
        logs["items"] = []
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should be_nil
      end
    end

    describe "when a microkernel boot event exists" do
      it "should return :microkernel" do
        logs["items"] = logs["items"].slice(0, 1)
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should == :microkernel
      end
    end

    describe "when only bind events exist" do
      it "should return :bind" do
        logs["items"] = logs["items"].slice(0, 2)
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should == :bind
      end

      it "should return :bind even if policy_name has different case" do
        logs["items"] = logs["items"].slice(0, 2)
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name.upcase)[:status].should == :bind
      end
    end

    describe "when reboot event exists" do
      it "should return :reboot" do
        logs["items"] = logs["items"].slice(0, 3)
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should == :reboot
      end

      it "should return :reboot even if policy_name has different case" do
        logs["items"] = logs["items"].slice(0, 3)
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name.upcase)[:status].should == :reboot
      end
    end

    describe "when boot_install event exists" do
      it "should return :boot_install" do
        logs["items"] = logs["items"].slice(0, 4)
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should == :boot_install
      end
    end

    # ASM-2016 reboot event may occur after boot_install
    describe "when reboot exists after boot_install" do
      it "should return :boot_install" do
        # 3rd log is reboot and 4th is boot_install
        logs["items"] = logs["items"].slice(0, 4)
        # Add a copy of reboot onto end
        logs["items"].push(logs["items"][2].dup)

        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should == :boot_install
      end
    end

    describe "when boot_wim event exists" do
      it "should return :boot_install" do
        logs["items"] = logs["items"].slice(0, 4)

        # Doctor up boot_install entry to look like boot_wim (seen with Windows)
        logs["items"][3]["template"] = "boot_wim"

        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should == :boot_install
      end
    end

    describe "when most recent interesting event is boot_install" do
      it "should return :boot_install" do
        logs["items"] = logs["items"].slice(0, 7)
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should == :boot_install
      end
    end

    describe "when boot_local event exists" do
      it "should return :boot_local" do
        logs["items"] = logs["items"].slice(0, 10)
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should == :boot_local
      end

      it "should return the right timestamp" do
        logs["items"] = logs["items"].slice(0, 10)
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:timestamp].should == Time.parse("2014-04-28T16:00:03+00:00")
      end
    end

    describe "when boot_local event exists twice" do
      it "should return :boot_local_2" do
        logs["items"] = logs["items"].slice(0, 11)
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should == :boot_local_2
      end
    end

    describe "when boot_local event exists thrice" do
      it "should return :boot_local_2" do
        items = logs["items"].slice(0, 11)
        # Last item is the 2nd boot_local log, add another copy so there are 3
        items.push(items.last)
        logs["items"] = items
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should == :boot_local_2
      end
    end

    describe "when reinstall event exists twice" do
      it "should return nil" do
        logs["items"] = logs["items"].slice(0, 12)
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should be_nil
      end
    end

    describe "when second different install has bind event" do
      it "should still return :bind" do
        logs["items"] = logs["items"] + logs["items"].slice(0, 2)
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should == :bind
      end
    end

    describe "when different install has started afterward" do
      it "should return nil" do
        unrelated_bind = [{"event" => "bind", "policy" => "unrelated_policy", "timestamp" => "2014-04-30T15:46:33+00:00"}]
        logs["items"] = logs["items"] + unrelated_bind
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should be_nil
      end
    end

    describe "where there was a previous install" do
      it "should return :bind after a bind event" do
        previous_logs = [{"event" => "bind", "policy" => "unrelated_policy", "timestamp" => "2014-04-30T15:46:33+00:00"},
                         {"event" => "reinstall", "policy" => "unrelated_policy", "timestamp" => "2014-04-30T16:46:33+00:00"}]
        logs["items"] = previous_logs + logs["items"].slice(0, 2)
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, policy_name)[:status].should == :bind
      end

      it "should return nil if no new bind event has happened" do
        transport.stubs(:[]).with(node_url).returns(mock_response(200, logs))
        razor.task_status(node_name, "nonexistant-policy")[:status].should be_nil
      end
    end

    describe "when comparing statuses" do
      it "should get the right ordering" do
        expect(razor.cmp_status(nil, :bind)).to be < 0
        expect(razor.cmp_status(:bind, :boot_local_2)).to be < 0
        expect(razor.cmp_status(:bind, :bind)).to be == 0
        expect(razor.cmp_status(:boot_local_2, :bind)).to be > 0
      end

      it "should fail with invalid status" do
        expect do
          razor.cmp_status(:foo, :bar)
        end.to raise_error(ASM::Razor::InvalidStatusException)
      end
    end

    describe "block_until_task_complete" do
      before(:each) do
        config = Hashie::Mash.new
        config.http_client_options = {}
        config.url!.razor = "http://foo/bar"
        ASM.stubs(:config).returns(config)
        transport = mock("transport")
        RestClient::Resource.stubs(:new).returns(transport)
      end

      describe "when node not found" do
        it "should raise UserException" do
          razor.stubs(:find_node_blocking).with("fail_serial_no", 600).raises(Timeout::Error)
          expect do
            razor.block_until_task_complete("fail_serial_no", "ip_address", "policy", "task", nil)
          end.to raise_error(ASM::UserException)
        end
      end

      describe "when node found" do
        it "should fail if status does not advance" do
          ASM::Util.stubs(:block_and_retry_until_ready).returns(:status => :boot_install)
          expect do
            razor.block_until_task_complete("serial_no", "ip_address", "policy", "task", nil)
          end.to raise_error(ASM::UserException)
        end

        it "should fail if getting status times out" do
          ASM::Util.stubs(:block_and_retry_until_ready).raises(Timeout::Error)
          expect do
            razor.block_until_task_complete("serial_no", "ip_address", "policy", "task", nil)
          end.to raise_error(ASM::UserException)
        end

        it "should succeed when status is terminal" do
          ASM::Util.stubs(:block_and_retry_until_ready).returns(:status => :boot_local)
          razor.block_until_task_complete("serial_no", "ip_address", "policy", "task", nil)
               .should == {:status => :boot_local}
        end

        it "should wait for :boot_local_2 when task is vmware" do
          ASM::Util.stubs(:block_and_retry_until_ready).returns(:status => :boot_local_2)
          razor.block_until_task_complete("serial_no", "ip_address", "policy", "vmware-esxi", nil)
               .should == {:status => :boot_local_2}
        end

        it "should wait for :boot_local_2 when task is windows" do
          ASM::Util.stubs(:block_and_retry_until_ready).returns(:status => :boot_local_2)
          razor.block_until_task_complete("serial_no", "ip_address", "policy", "windows", nil)
               .should == {:status => :boot_local_2}
        end
      end
    end
  end

  def mock_post(path, args, response_code)
    response = mock_response(response_code, {}, :post, args.to_json, :content_type => :json, :accept => :json)
    transport.stubs(:[]).with(path).returns(response)
  end

  describe "#post" do
    it "should post to commands/url with JSON arguments" do
      args = {:rspec => "test"}
      mock_post("api/commands/rspec", args, 202)
      razor.post_command("rspec", args)
    end

    it "should fail if response code is not 202" do
      args = {:rspec => "test"}
      mock_post("api/commands/rspec", args, 500)
      expect {razor.post_command("rspec", args)}.to raise_error(StandardError, "Razor post failed with HTTP code 500: {}")
    end
  end

  describe "#delete_policy" do
    it "should post to commands/delete-policy" do
      args = {:name => "rspec-node"}
      mock_post("api/commands/delete-policy", args, 202)
      razor.delete_policy("rspec-node")
    end
  end

  describe "#delete_tag" do
    it "should post to commands/delete-tag" do
      args = {:name => "rspec-node"}
      mock_post("api/commands/delete-tag", args, 202)
      razor.delete_tag("rspec-node")
    end
  end

  describe "#reinstall_node" do
    it "should post to commands/reinstall-node" do
      args = {:name => "rspec-node"}
      mock_post("api/commands/reinstall-node", args, 202)
      razor.reinstall_node("rspec-node")
    end
  end

  describe "#delete_node_policy" do
    it "should do nothing if node has no policies or tags" do
      razor.expects(:get).with("nodes", "rspec-node").returns({})
      razor.expects(:delete_policy).never
      razor.expects(:reinstall_node).never
      razor.expects(:delete_tag).never
      razor.delete_node_policy("name" => "rspec-node")
    end

    it "should delete an attached policy and run reinstall-node" do
      node = {"name" => "rspec-node", "policy" => {"name" => "rspec-policy"}}
      razor.expects(:get).with("nodes", "rspec-node").returns(node)
      razor.expects(:delete_policy).with("rspec-policy")
      razor.expects(:reinstall_node).with("rspec-node")
      razor.delete_node_policy("name" => "rspec-node")
    end

    it "should delete attached tags" do
      node = {"name" => "rspec-node", "tags" => [{"name" => "rspec-tag1"}, {"name" => "rspec-tag2"}]}
      razor.expects(:get).with("nodes", "rspec-node").returns(node)
      razor.expects(:delete_tag).with("rspec-tag1")
      razor.expects(:delete_tag).with("rspec-tag2")
      razor.delete_node_policy("name" => "rspec-node")
    end
  end

  describe "#delete_stale_policy!" do
    it "should do nothing if node not found" do
      razor.expects(:find_node).with("rspec-serial").returns(nil)
      razor.expects(:delete_node_policy).never
      razor.delete_stale_policy!("rspec-serial", "desired-rspec-policy")
    end

    it "should do nothing if node does not have a policy" do
      razor.expects(:find_node).with("rspec-serial").returns("name" => "rspec-node")
      razor.expects(:delete_node_policy).never
      razor.delete_stale_policy!("rspec-serial", "desired-rspec-policy")
    end

    it "should do nothing if node has the desired policy" do
      razor.expects(:find_node).with("rspec-serial")
           .returns("name" => "rspec-node", "policy" => {"name" => "desired-rspec-policy"})
      razor.expects(:delete_node_policy).never
      razor.delete_stale_policy!("rspec-serial", "desired-rspec-policy")
    end

    it "should do nothing if node has the desired policy, case-insensitive" do
      razor.expects(:find_node).with("rspec-serial")
           .returns("name" => "rspec-node", "policy" => {"name" => "DESIRED-RSPEC-POLICY"})
      razor.expects(:delete_node_policy).never
      razor.delete_stale_policy!("rspec-serial", "desired-rspec-policy")
    end

    it "should delete the node policy if it does not match" do
      node = {"name" => "rspec-node", "policy" => {"name" => "some-other-policy"}}
      razor.expects(:find_node).with("rspec-serial")
           .returns(node)
      razor.expects(:delete_node_policy).with(node)
      razor.delete_stale_policy!("rspec-serial", "desired-rspec-policy")
    end
  end

  describe "#valid_mac_address?" do
    it "should return true for a valid mac" do
      expect(razor.valid_mac_address?("00:8c:fa:f0:6b:c4")).to be_truthy
    end

    it "should return true for valid, capitalized macs" do
      expect(razor.valid_mac_address?("00:8C:FA:F0:6B:C4")).to be_truthy
    end

    it "should return false otherwise" do
      expect(razor.valid_mac_address?("00:8C:FA:F0:6B")).to be_falsey
    end
  end

  describe "#register_node" do
    it "should fail on unknown arguments" do
      err = "Unrecognized option(s) passed to register_node: foo"
      expect {razor.register_node(:foo => "foo")}.to raise_error(err)
    end

    it "should fail on invalid mac parameter value" do
      err = "Invalid mac_addresses parameter: foo"
      expect {razor.register_node(:mac_addresses => "foo")}.to raise_error(err)
    end

    it "should fail on invalid mac addresses" do
      err = "Invalid mac addresses: badmac1, badmac2"
      expect {razor.register_node(:mac_addresses => ["badmac1", "badmac2"])}.to raise_error(err)
    end

    it "should call post_command with correct payload" do
      macs = ["00:8C:FA:F0:6B:C4", "00:8C:FA:F0:6B:cC"]
      expected_hw_info = {:net0 => macs[0].downcase,
                          :net1 => macs[1].downcase,
                          :serial => "64bqw52",
                          :asset => "asset",
                          :uuid => "uuid"}
      razor.expects(:post_command).with("register-node", :hw_info => expected_hw_info, :installed => true).returns("rspec-post-response")
      JSON.expects(:parse).with("rspec-post-response").returns("name" => "node8")
      expect(razor.register_node(:mac_addresses => macs, :serial => "64BQW52", :asset => "asset", :uuid => "uuid", :installed => true)).to eq("name" => "node8")
    end
  end

  describe "#build_hw_id" do
    it "should build remove :'s and glue macs together with _" do
      expect(razor.build_hw_id(["00:8c:fa:f0:6b:c4", "00:8c:fa:f0:6b:c6"])).to eq("008cfaf06bc4_008cfaf06bc6")
    end
  end

  describe "#node_id" do
    it "should fail if name does not end in digits" do
      expect {razor.node_id("foo")}.to raise_error("Invalid node name: foo")
    end

    it "should extract the node id" do
      expect(razor.node_id("node312")).to eq(312)
    end
  end

  describe "#build_mac_address_facts" do
    it "should generate macaddress_netX facts" do
      macs = ["FF:FF:FF:FF:FF:FF", "11:11:11:11:11:11"]
      expect(razor.build_mac_address_facts(macs)).to eq(:macaddress_net0 => "ff:ff:ff:ff:ff:ff", :macaddress_net1 => "11:11:11:11:11:11")
    end
  end

  describe "#checkin_node" do
    let(:macs) {["00:8c:fa:f0:6b:c4", "00:8c:fa:f0:6b:c6"]}
    let(:facts) {{:serialnumber => "64BQW52"}}

    it "should fail on invalid mac addresses" do
      expect {razor.checkin_node(node1["name"], "foo", facts)}.to raise_error("Invalid mac_addresses parameter: foo")
    end

    it "should fail on invalid facts" do
      expect {razor.checkin_node(node1["name"], macs, "foo")}.to raise_error("Invalid facts parameter: foo")
    end

    it "should post to the checkin service" do
      populated_facts = {:is_virtual => "false", :macaddress_net0 => macs[0], :macaddress_net1 => macs[1]}
      payload = {:hw_id => razor.build_hw_id(macs), :facts => populated_facts.merge(facts)}
      mock_post("svc/checkin/1", payload, 200)
      JSON.expects(:parse).returns("action" => "reboot")
      razor.checkin_node(node1["name"], macs, facts)
    end

    it "should fail if checkin fails" do
      populated_facts = {:is_virtual => "false", :macaddress_net0 => macs[0], :macaddress_net1 => macs[1]}
      payload = {:hw_id => razor.build_hw_id(macs), :facts => populated_facts.merge(facts)}
      mock_post("svc/checkin/1", payload, 503)
      err = "Razor node node1 checkin failed with HTTP code 503: {}"
      expect {razor.checkin_node(node1["name"], macs, facts)}.to raise_error(err)
    end

    it "should allow caller to override populated facts" do
      overridden_facts = {:is_virtual => "true", :macaddress_net0 => "bogus-mac-1", :macaddress_net1 => "bogus-mac-2"}
      new_facts = overridden_facts.merge(facts)
      payload = {:hw_id => razor.build_hw_id(macs), :facts => new_facts}
      mock_post("svc/checkin/1", payload, 200)
      JSON.expects(:parse).returns("action" => "reboot")
      razor.checkin_node(node1["name"], macs, new_facts)
    end
  end
end
