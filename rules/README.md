Rules that are being run for components
=======================================

When adding rules to manage components please set their priority according
to this table.   At present this applies to rules in ```teardown``` and
```migration``` directories.

Rules that are active during all component processing goes into ```component_common```
and follows the same priority format

Rule priority is 50 by default, it's not a problem to have multiple rules
on the same priority - for example cluster and server teardown are both on
priority 50 but they would not both run for the same component

Priority |Description                                                 |
---------|------------------------------------------------------------|
10-29    |Configuring related hardware like switches                  |
30-40    |Data manipulation like handling asm::baseserver             |
40-49    |Pre flight preparation like preparing a cluster for teardown|
50-70    |Actual teardown steps                                       |
80-100   |Post deployment steps like running inventories              |
999      |Processing rule results and writing exception logs          |

