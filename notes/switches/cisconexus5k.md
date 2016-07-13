Cisco Nexus 5k
=======

## General:

General Information | |
------------ | -------------
**Modules** | dell-cisconexus5k via asm::cisconexus5k and asm::cisconexus_zoneconfig|
**Detection** | ```certname =~ /^cisconexus/```|
**Device Type**| Set to ```dellftos``` by ```populate_rack_switch_hash``` but then ```populate_cisco_san_switch_hash``` sets to ```cisconexus5k``` for san switches|

## Misc Notes:

 * ```ASM::Util.cisco_nexus_get_vsan_activezoneset``` parses the ```nameserver_info``` fact as JSON, added it to switch base class for auto parsing

Mode Detection | |
------------ | -------------
**rack_switch?**|always true
**blade_switch?**|always false
**fxflexiom_switch?**|always false
**npiv_switch?**|true if ```features``` include ```npv``` as per ```get_all_switches```
**san_switch?**|!npiv_switch?

## Teardown Notes:
 * For every VLAN the machine was configured we'd need to make a asm::cisconexus5k resource to remove it and then one to set it, with dependencies

## Interesting methods in current code

 * Util.dell_cisconexus_get_compellent_wwpn
 * Util.cisco_nexus_get_vsan_activezoneset
 * Util.get_cisconexus_features
 * ServiceDeployment#configure_tor
 * ServiceDeployment#configure_san_fcoe_switch_cisco_nexus
 * ServiceDeployment#populate_* methods
