/*
   BoppOS Security Ruleset for Package Scriptlets (.INSTALL)
*/

rule Obfuscated_Base64_Payload {
    meta:
        description = "Detects base64 decoded payloads in shell scriptlets"
        severity = "HIGH"
    strings:
        $b64_1 = "base64 -d" ascii wide
        $b64_2 = "base64 --decode" ascii wide
        $eval_1 = "eval $" ascii wide
        $eval_2 = "eval `" ascii wide
        $enc_1 = "openssl enc" ascii wide
    condition:
        any of ($b64_*) or any of ($eval_*) or $enc_1
}

rule Suspicious_Network_Egress {
    meta:
        description = "Detects unauthorized reverse shells, webhooks, or dynamic execution drops"
        severity = "HIGH"
    strings:
        $hook_1 = "discord.com/api/webhooks" ascii wide
        $hook_2 = "api.telegram.org" ascii wide
        $nc_1 = "nc -e" ascii wide
        $nc_2 = "ncat " ascii wide
        $tcp = "/dev/tcp/" ascii wide
    condition:
        any of ($hook_*) or any of ($nc_*) or $tcp
}

rule Sensitive_Credential_Access {
    meta:
        description = "Detects access targeting system credentials or browser profile stores"
        severity = "CRITICAL"
    strings:
        $p1 = "/etc/shadow" ascii wide
        $p2 = ".ssh/id_rsa" ascii wide
        $p3 = ".ssh/id_ed25519" ascii wide
        $p4 = ".aws/credentials" ascii wide
    condition:
        any of ($p*)
}
