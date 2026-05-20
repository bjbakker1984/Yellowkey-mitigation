
Yellowkey-mitigation.ps1 is a PowerShell script that automates the WinRE mitigation workflow described in CVE-2026-45585, adds verification after every step, and does not execute step 6 (reagentc /disable + reagentc /enable) if any earlier step fails. 
It also checks whether the required registry change was actually needed and applied. 

The script only commits the WinRE image if it actually removed 'autofstx.exe' value.
If no change was needed, it uses /discard instead of /commit to avoid touching WinRE unnecessarily.

Step 6 (re-establish BitLocker trust) runs only if:
- steps 1–5 all succeeded, and
- the BootExecute value was actually changed

The script modifies all detected ControlSet### keys in the mounted WinRE hive (not just ControlSet001) for robustness. 

NOTE!
Because WinRE is the recovery environment and is typically stored on a dedicated recovery partition, test this on a pilot ring first and ensure you have recovery procedures/keys available before broad rollout.
