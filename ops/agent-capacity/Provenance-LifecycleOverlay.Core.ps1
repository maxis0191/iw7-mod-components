# Pure exact-SDK transforms. Import performs no filesystem or native action.
function Get-IW7WordProvenanceHash([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}
function Convert-IW7WordProvenanceAnchor([string]$Text,[string]$Old,[string]$New) {
    if(($Text.Split([string[]]@($Old),[StringSplitOptions]::None)).Count -ne 2){
        throw 'Exact 77e lifecycle anchor absent or duplicated; preserve source.'
    }
    $Text.Replace($Old,$New)
}
function New-IW7WordProvenanceLifecycleOverlays([byte[]]$CleanBytes) {
    $hash=Get-IW7WordProvenanceHash $CleanBytes
    # These are the two physically reviewed newline representations of the same clean SDK main.cpp.
    if($hash -cnotin @('B0C9D1E20D3169F9614178F08EDED7D9CA4A0250434F43E99C7990FF395A82E1',
                      'A91B01403B21FADCF3A4F66A3C8010327B82E03A8D866D4503DB9DC2BB5DE115')){
        throw 'Unreviewed clean main.cpp; no generic lifecycle transform.'
    }
    $encoding=[Text.UTF8Encoding]::new($false,$true)
    $clean=$encoding.GetString($CleanBytes)
    $nl=if($clean.Contains("`r")){"`r`n"}else{"`n"}
    $enabled=Convert-IW7WordProvenanceAnchor $clean '#include <std_include.hpp>' (
        '#include <std_include.hpp>'+$nl+'#define IW7_PARIS_WORD_PROVENANCE_STARTUP 1'+$nl+'#include "component/paris_word_provenance.hpp"')
    $enabled=Convert-IW7WordProvenanceAnchor $enabled ("`t`t`tgame::base_address = base_address;") (
        "`t`t`tgame::base_address = base_address;"+$nl+"`t`t`tparis_word_provenance::loaded_boundary();")
    $postload="`t`t`tif (!component_loader::post_load()) return EXIT_FAILURE;"+$nl+"`t`t`tMH_ApplyQueued();"
    $enabled=Convert-IW7WordProvenanceAnchor $enabled $postload ($postload+$nl+"`t`t`tparis_word_provenance::after_all_post_load();")
    $unpack="`tcomponent_loader::post_unpack();"+$nl+"`tMH_ApplyQueued();"
    $enabled=Convert-IW7WordProvenanceAnchor $enabled $unpack (
        "`tparis_word_provenance::before_first_post_unpack();"+$nl+$unpack+$nl+"`tparis_word_provenance::after_first_post_unpack();")
    [pscustomobject]@{SDKCommit='77e6d4d24e918ee363b3feee3735c3b889dff7d7';Clean=$CleanBytes;
        Enabled=$encoding.GetBytes($enabled);CleanSHA256=$hash;Newline=$(if($nl -ceq "`n"){'LF'}else{'CRLF'});
        Mode='STARTUP';RestartImplemented=$false;ArxanModified=$false;PrioritiesModified=$false}
}
function Get-IW7WordProvenanceLifecycleTransition([byte[]]$Current,$Overlays,[bool]$Enabled) {
    $hash=Get-IW7WordProvenanceHash $Current
    if($hash -cnotin @((Get-IW7WordProvenanceHash $Overlays.Clean),(Get-IW7WordProvenanceHash $Overlays.Enabled))){
        throw 'Unowned main.cpp bytes; preserve them.'
    }
    if($Enabled){return ,$Overlays.Enabled}
    return ,$Overlays.Clean
}
function Assert-IW7WordProvenanceBuildProfile([bool]$Enabled,[bool]$IsolatedLab,[bool]$ServerModules,[bool]$Debugger,[string]$Mode='STARTUP') {
    if($Mode -cne 'STARTUP'){throw 'Restart provenance is not implemented.'}
    if($Enabled -and (!$IsolatedLab -or !$ServerModules -or !$Debugger)){
        throw 'Provenance compilation requires the explicit isolated server debugger profile.'
    }
}
