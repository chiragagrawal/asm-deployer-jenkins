require "asm/private_util"
require "spec_helper"

describe ASM::PrivateUtil do
  describe "#remove_from_node_data" do
    node_data = SpecHelper.load_fixture("unmanage_app_node_data.yaml")
    node_data2 = SpecHelper.load_fixture("unmanage_app_node_data2.yaml")
    context "when removing 1 of two same-type resources" do
      it "should remove the resource from the node_data file" do
        ASM::PrivateUtil.stubs(:read_node_data).returns(node_data)
        component_hash = {"file"=>{"logans_file"=>{"ensure"=>"present"}}}
        config = {"classes"=>
                           {"windows_postinstall::nic::adapter_nic_ip_settings"=>
                              {"ipaddress_info"=>
                                 {"NICIPInfo"=>
                                    [{"adapter_name"=>"Workload",
                                      "ip_address"=>"172.31.33.133",
                                      "subnet"=>"255.255.255.0",
                                      "primaryDns"=>"172.31.62.1",
                                      "mac_address"=>"00-50-56-8a-4b-82",
                                      "gateway"=>"172.31.33.254",
                                      "adapter_type"=>"vm_network"}]}},
                            "windows_postinstall"=>{"upload_file"=>"moktest.ps1", "upload_recurse"=>false, "execute_file_command"=>"powershell -executionpolicy bypass -file moktest.ps1"},
                            "mssql2012"=>
                              {"media"=>"\\\\172.31.54.209\\razor\\SQLServer2012",
                               "instancename"=>"MSSQLSERVER",
                               "features"=>"SQLENGINE,CONN,SSMS,ADV_SSMS",
                               "sapwd"=>"Dell1234",
                               "agtsvcaccount"=>"SQLAGTSVC",
                               "agtsvcpassword"=>"Dell1234",
                               "assvcaccount"=>"SQLASSVC",
                               "assvcpassword"=>"Dell1234",
                               "rssvcaccount"=>"SQLRSSVC",
                               "rssvcpassword"=>"Dell1234",
                               "sqlsvcaccount"=>"SQLSVC",
                               "sqlsvcpassword"=>"Dell1234",
                               "instancedir"=>"C:\\Program Files\\Microsoft SQL Server",
                               "ascollation"=>"Latin1_General_CI_AS",
                               "sqlcollation"=>"SQL_Latin1_General_CP1_CI_AS",
                               "admin"=>"Administrator",
                               "netfxsource"=>"\\\\172.31.54.209\\razor\\win2012R2\\resources\\sxs"}},
                         "resources"=>{"file"=>{"second_file"=>{"ensure"=>"present"}}}}

        ASM::PrivateUtil.expects(:write_node_data).with("agent-win29vml", {"agent-win29vml" => config})
        ASM::PrivateUtil.remove_from_node_data("agent-win29vml", component_hash)
      end
    end

    context "when removing a resource" do
      it "should remove the resource" do
        ASM::PrivateUtil.stubs(:read_node_data).returns(node_data2)
        component_hash = {"file"=>{"second_file"=>{"ensure"=>"present"}}}
        config = {"classes"=>
                    {"windows_postinstall::nic::adapter_nic_ip_settings"=>
                       {"ipaddress_info"=>
                          {"NICIPInfo"=>
                             [{"adapter_name"=>"Workload",
                               "ip_address"=>"172.31.33.133",
                               "subnet"=>"255.255.255.0",
                               "primaryDns"=>"172.31.62.1",
                               "mac_address"=>"00-50-56-8a-4b-82",
                               "gateway"=>"172.31.33.254",
                               "adapter_type"=>"vm_network"}]}},
                     "windows_postinstall"=>{"upload_file"=>"moktest.ps1", "upload_recurse"=>false, "execute_file_command"=>"powershell -executionpolicy bypass -file moktest.ps1"},
                     "mssql2012"=>
                       {"media"=>"\\\\172.31.54.209\\razor\\SQLServer2012",
                        "instancename"=>"MSSQLSERVER",
                        "features"=>"SQLENGINE,CONN,SSMS,ADV_SSMS",
                        "sapwd"=>"Dell1234",
                        "agtsvcaccount"=>"SQLAGTSVC",
                        "agtsvcpassword"=>"Dell1234",
                        "assvcaccount"=>"SQLASSVC",
                        "assvcpassword"=>"Dell1234",
                        "rssvcaccount"=>"SQLRSSVC",
                        "rssvcpassword"=>"Dell1234",
                        "sqlsvcaccount"=>"SQLSVC",
                        "sqlsvcpassword"=>"Dell1234",
                        "instancedir"=>"C:\\Program Files\\Microsoft SQL Server",
                        "ascollation"=>"Latin1_General_CI_AS",
                        "sqlcollation"=>"SQL_Latin1_General_CP1_CI_AS",
                        "admin"=>"Administrator",
                        "netfxsource"=>"\\\\172.31.54.209\\razor\\win2012R2\\resources\\sxs"}},
                  "resources"=>{}}
        ASM::PrivateUtil.expects(:write_node_data).with("agent-win29vml", {"agent-win29vml" => config})
        ASM::PrivateUtil.remove_from_node_data("agent-win29vml", component_hash)
      end
    end

    context "when removing class" do
      it "should remove the class from the node_data file" do
        ASM::PrivateUtil.stubs(:read_node_data).returns(node_data)
        component_hash = {"windows_postinstall"=>
                            {"8DF4EAD8-60F2-4977-AA75-F275D3E08E9E"=>
                               {"share"=>"",
                                "install_command"=>"",
                                "upload_file"=>"moktest.ps1",
                                "upload_recurse"=>false,
                                "execute_file_command"=>"powershell -executionpolicy bypass -file moktest.ps1"}}}
        config = {"classes"=>
                       {"windows_postinstall::nic::adapter_nic_ip_settings"=>
                          {"ipaddress_info"=>
                             {"NICIPInfo"=>
                                [{"adapter_name"=>"Workload",
                                  "ip_address"=>"172.31.33.133",
                                  "subnet"=>"255.255.255.0",
                                  "primaryDns"=>"172.31.62.1",
                                  "mac_address"=>"00-50-56-8a-4b-82",
                                  "gateway"=>"172.31.33.254",
                                  "adapter_type"=>"vm_network"}]}},
                        "mssql2012"=>
                          {"media"=>"\\\\172.31.54.209\\razor\\SQLServer2012",
                           "instancename"=>"MSSQLSERVER",
                           "features"=>"SQLENGINE,CONN,SSMS,ADV_SSMS",
                           "sapwd"=>"Dell1234",
                           "agtsvcaccount"=>"SQLAGTSVC",
                           "agtsvcpassword"=>"Dell1234",
                           "assvcaccount"=>"SQLASSVC",
                           "assvcpassword"=>"Dell1234",
                           "rssvcaccount"=>"SQLRSSVC",
                           "rssvcpassword"=>"Dell1234",
                           "sqlsvcaccount"=>"SQLSVC",
                           "sqlsvcpassword"=>"Dell1234",
                           "instancedir"=>"C:\\Program Files\\Microsoft SQL Server",
                           "ascollation"=>"Latin1_General_CI_AS",
                           "sqlcollation"=>"SQL_Latin1_General_CP1_CI_AS",
                           "admin"=>"Administrator",
                           "netfxsource"=>"\\\\172.31.54.209\\razor\\win2012R2\\resources\\sxs"}},
                     "resources"=>{"file"=>{"logans_file"=>{"ensure"=>"present"},
                       "second_file"=>{"ensure"=>"present","require"=>"File['logans_file']"}}}}
        ASM::PrivateUtil.expects(:write_node_data).with("agent-win29vml", {"agent-win29vml" => config})

        ASM::PrivateUtil.remove_from_node_data("agent-win29vml", component_hash)
      end
    end

    context "when removing item with no dependencies" do
      it "should not remove any require statements" do
        ASM::PrivateUtil.stubs(:read_node_data).returns(node_data)
        component_hash = {"file"=>{"second_file"=>{"ensure"=>"present"}}}
        config = {"classes"=>
                    {"windows_postinstall::nic::adapter_nic_ip_settings"=>
                       {"ipaddress_info"=>
                          {"NICIPInfo"=>
                             [{"adapter_name"=>"Workload",
                               "ip_address"=>"172.31.33.133",
                               "subnet"=>"255.255.255.0",
                               "primaryDns"=>"172.31.62.1",
                               "mac_address"=>"00-50-56-8a-4b-82",
                               "gateway"=>"172.31.33.254",
                               "adapter_type"=>"vm_network"}]}},
                     "windows_postinstall"=>{"upload_file"=>"moktest.ps1", "upload_recurse"=>false, "execute_file_command"=>"powershell -executionpolicy bypass -file moktest.ps1"},
                     "mssql2012"=>
                       {"media"=>"\\\\172.31.54.209\\razor\\SQLServer2012",
                        "instancename"=>"MSSQLSERVER",
                        "features"=>"SQLENGINE,CONN,SSMS,ADV_SSMS",
                        "sapwd"=>"Dell1234",
                        "agtsvcaccount"=>"SQLAGTSVC",
                        "agtsvcpassword"=>"Dell1234",
                        "assvcaccount"=>"SQLASSVC",
                        "assvcpassword"=>"Dell1234",
                        "rssvcaccount"=>"SQLRSSVC",
                        "rssvcpassword"=>"Dell1234",
                        "sqlsvcaccount"=>"SQLSVC",
                        "sqlsvcpassword"=>"Dell1234",
                        "instancedir"=>"C:\\Program Files\\Microsoft SQL Server",
                        "ascollation"=>"Latin1_General_CI_AS",
                        "sqlcollation"=>"SQL_Latin1_General_CP1_CI_AS",
                        "admin"=>"Administrator",
                        "netfxsource"=>"\\\\172.31.54.209\\razor\\win2012R2\\resources\\sxs"}},
                  "resources"=>{"file"=>{"logans_file"=>{"ensure"=>"present","require"=>"Class['windows_postinstall']"}}}}
        ASM::PrivateUtil.expects(:write_node_data).with("agent-win29vml", {"agent-win29vml" => config})

        ASM::PrivateUtil.remove_from_node_data("agent-win29vml", component_hash)
      end
    end

    context "VNX util functions" do
      let(:facts) { SpecHelper.json_fixture("EMC_facts.json")}
      let(:facts_find) {stub}

      it "Should return LUN id when called #get_vnx_lun_id" do
        ASM::PrivateUtil.expects(:facts_find).with("vnx-apm00132402069").returns(facts)
        expect(ASM::PrivateUtil.get_vnx_lun_id("vnx-apm00132402069", "hypervvol1", nil)).to eq("6")
      end

      it "Should return true if a host connected to the storage when called #is_host_connected_to_vnx" do
        ASM::PrivateUtil.expects(:facts_find).with("vnx-apm00132402069").returns(facts)
        expect(ASM::PrivateUtil.is_host_connected_to_vnx("vnx-apm00132402069", "esxideploy", nil)).to eq(true)
      end

      it "Should update resourse hash of no size or pool mentioned in the hash when called #update_vnx_resource_hash" do
        ASM::PrivateUtil.expects(:facts_find).with("vnx-apm00132402069").returns(facts)
        expect(ASM::PrivateUtil.update_vnx_resource_hash("vnx-apm00132402069", {"asm::volume::vnx" => {"hypervvol1" => {"name" => "hypervvol1"}}}, "hypervvol1", nil).to_s).to include("size")
      end
    end
  end
end
