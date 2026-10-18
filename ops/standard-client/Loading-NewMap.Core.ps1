function Assert-IW7StandardClientLoadingHook([string]$Source) {
    # This reviewed source contract covers the one displaced five-byte CALL.
    # A wider entry patch would overwrite the stub's continuation at entry + 5.
    $stubs = [regex]::Matches($Source, '(?ms)^\s*void\s+loading_new_map_cl_stub\s*\(\s*utils::hook::assembler\s*&\s*a\s*\)\s*\{(?<body>[^{}]*)\}')
    if ($stubs.Count -ne 1) { throw 'Loading-new-map stub missing or ambiguous.' }
    $body = [regex]::Replace($stubs[0].Groups['body'].Value, '\s+', '')
    if ($body -cne 'a.pushad64();a.mov(r8,r12);a.call_aligned(set_new_map);a.popad64();a.jmp(0x1409B04D7);') {
        throw 'Unknown loading-new-map stub or continuation; review the native instruction boundary.'
    }
    $hooks = [regex]::Matches($Source, '(?m)^[ \t]*utils::hook::jump\([^;]*\bloading_new_map_cl_stub\b[^;]*\);')
    if ($hooks.Count -ne 1) { throw 'Loading-new-map entry patch missing or ambiguous.' }
    $hook = [regex]::Replace($hooks[0].Value, '\s+', '')
    if ($hook -cnotin @(
        'utils::hook::jump(0x1409B04D2,utils::hook::assemble(loading_new_map_cl_stub));',
        'utils::hook::jump(0x1409B04D2,utils::hook::assemble(loading_new_map_cl_stub),false);'
    )) {
        throw 'Loading-new-map entry must use the reviewed five-byte near jump; far or unknown patches are refused.'
    }
    [pscustomobject]@{ PatchAddress = '0x1409B04D2'; ResumeAddress = '0x1409B04D7'; PatchBytes = 5 }
}
