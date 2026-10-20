import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('code_pages', Path(__file__).with_name('code_pages.py'))
pages = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pages)


class Reader:
    identity = {'pid': 123, 'image': 'synthetic', 'sha256': 'not-game-evidence'}

    def __init__(self, changed=False, protect=0x20):
        self.calls = 0
        self.changed = changed
        self.protect = protect

    def assert_alive(self):
        pass

    def region(self, address):
        return {'base': address, 'bytes': pages.PAGE, 'state': 0x1000,
                'protect': self.protect, 'type': 0x20000}

    def read(self, address, size):
        self.calls += 1
        return bytes([self.calls % 2 if self.changed else 42]) * size


class Tests(unittest.TestCase):
    def test_fixed_native_text_capture_and_partial_refusal(self):
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temp:
            script = Path(temp) / 'text.ps1'
            script.write_text(r'''param($Repo,$Temp)
$ErrorActionPreference='Stop'
Add-Type -Path "$Repo/ops/agent-capacity/CodePages.cs"
. "$Repo/ops/agent-capacity/CodePages.Core.ps1"
if([IW7CapacityPages]::TextSectionAddress(0) -ne 0x140001000 -or
   [IW7CapacityPages]::TextSectionAddress(1) -ne 0x14B2B4000 -or
   [IW7CapacityPages]::TextSectionLength(0) -ne 0x1427E00 -or
   [IW7CapacityPages]::TextSectionLength(1) -ne 0x104D400){throw 'Fixed PE sections differ'}
foreach($bad in @(-1,2,100)){
    $refused=$false;try{$null=[IW7CapacityPages]::TextSectionLength($bad)}catch{$refused=$true}
    if(!$refused){throw 'Arbitrary section accepted'}
}
foreach($mode in @('normal','partial','changed')){
    $reader=[pscustomobject]@{ReadCalls=0;ReadBytes=0;Mode=$mode}
    $reader|Add-Member ScriptMethod AssertAlive {}
    $reader|Add-Member ScriptMethod ReadTextSection {
        param($index)
        $this.ReadCalls++
        $size=[IW7CapacityPages]::TextSectionLength($index)
        if($this.Mode -eq 'partial' -and $index -eq 1){$size--}
        $bytes=[byte[]]::new($size)
        if($this.Mode -eq 'changed'){$bytes[0]=$this.ReadCalls}
        $this.ReadBytes+=$size
        ,$bytes
    }
    $out=Join-Path $Temp $mode
    $refused=$false;try{Save-IW7CapacityNativeText $reader $out ([pscustomobject]@{PID=123}) ([pscustomobject]@{synthetic=$true})}catch{$refused=$true}
    $record=Get-Content "$out/manifest.local.json" -Raw|ConvertFrom-Json
    if($mode -in @('normal','changed')){
        if($refused -or !$record.complete -or $record.sections.Count -ne 2 -or $record.read_calls -ne 4 -or $record.read_bytes -ne 76456960){throw 'Fixed text capture failed'}
        $extra=if($mode -eq 'changed'){8192}else{0}
        if((Get-ChildItem $out -Filter *.bin|Measure-Object Length -Sum).Sum -ne (38228480+$extra)){throw 'Wrong retained text size'}
        if($mode -eq 'changed'){
            if($record.all_pages_stable -or $record.sections[0].stable_double_read -or $record.sections[0].changed_pages.Count -ne 1 -or $record.sections[0].changed_pages[0].offset -ne 0){throw 'Changed page misclassified'}
        }elseif(!$record.all_pages_stable){throw 'Stable text falsely changed'}
        $refused=$false;try{Save-IW7CapacityNativeText $reader $out $null $null}catch{$refused=$true}
        if(!$refused){throw 'Output overwrite accepted'}
    }else{
        if(!$refused -or $record.complete -or !$record.failure){throw 'Incomplete/changed section accepted'}
        $expected=if($mode -eq 'partial'){1}else{0}
        if($record.sections.Count -ne $expected){throw 'Partial prefix not retained accurately'}
    }
    if($record.target_written -or $record.target_suspended -or $record.global_snapshot_coherent -or $record.data_sections_captured -or $record.pristine){throw 'False text capture claim'}
}
''', encoding='utf-8')
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(script), str(repo), temp],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fixed_bounds_and_no_pristine_claim(self):
        plan = pages.plan()
        self.assertEqual(len(plan), 8)
        for owner in pages.OWNERS:
            self.assertEqual(len([row for row in plan if row['owner'] == owner]), 4)
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / 'capture'
            record = pages.capture(Reader(), out)
            self.assertTrue(record['complete'])
            self.assertFalse(record['pristine'])
            self.assertFalse(record['target_suspended'])
            self.assertFalse(record['target_written'])
            self.assertFalse(record['global_snapshot_coherent'])
            self.assertEqual(record['read_calls'], 16)
            self.assertEqual(record['read_bytes'], 65536)
            self.assertEqual(sum(path.stat().st_size for path in out.glob('*.bin')), 32768)
            with self.assertRaises(ValueError):
                pages.capture(Reader(), out)

    def test_permission_and_mutation_refusals_preserve_partial_manifest(self):
        class PartialReader(Reader):
            def read(self, address, size):
                return b'partial'
        class ProtectionChangedReader(Reader):
            def region(self, address):
                row = super().region(address)
                if self.calls:
                    row['protect'] = 0x40
                return row
        for reader in (Reader(changed=True), Reader(protect=0x120), Reader(protect=0x04),
                       PartialReader(), ProtectionChangedReader()):
            with tempfile.TemporaryDirectory() as temp:
                out = Path(temp) / 'capture'
                with self.assertRaises(ValueError):
                    pages.capture(reader, out)
                record = json.loads((out / 'manifest.local.json').read_text())
                self.assertFalse(record['complete'])
                self.assertFalse(record['patch_ready'])
                self.assertIn('failure', record)
        with self.assertRaises(ValueError):
            pages.validate_region({'base': 0, 'bytes': 4095, 'state': 0x1000, 'protect': 0x20, 'type': 0x20000}, 0)

    def test_csharp_and_inprocess_partial_capture_with_mock_reader(self):
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temp:
            script = Path(temp) / 'inprocess.ps1'
            script.write_text(r"""param($Repo,$Temp)
$ErrorActionPreference='Stop'
Add-Type -Path "$Repo/ops/agent-capacity/CodePages.cs"
. "$Repo/ops/agent-capacity/CodePages.Core.ps1"
$copy=[IW7CapacityPages]::GetAllowedPages();$copy[0]=0
$refused=$false;try{[IW7CapacityPages]::ValidateAddress(0)}catch{$refused=$true}
if(!$refused){throw 'Allowlist mutable'}
$two=[IW7CapacityPages]::GetPlanPages('reset-entry-targets')
if($two.Count -ne 2 -or $two[0] -ne 0x14B8E6000 -or $two[1] -ne 0x14B4B2000){throw 'Wrong next fixed plan'}
$two[0]=0
if([IW7CapacityPages]::GetPlanPages('reset-entry-targets')[0] -ne 0x14B8E6000){throw 'Next plan mutable'}
$writer=[IW7CapacityPages]::GetPlanPages('writer-sites-20261019')
if($writer.Count -ne 3 -or $writer[0] -ne 0x1412BF000 -or $writer[1] -ne 0x14C1ED000 -or $writer[2] -ne 0x14BFE5000){throw 'Wrong observed writer plan'}
$writer[0]=0
if([IW7CapacityPages]::GetPlanPages('writer-sites-20261019')[0] -ne 0x1412BF000){throw 'Writer plan mutable'}
$refused=$false;try{[IW7CapacityPages]::ValidatePlanAddress('writer-sites-20261019',0x140488000)}catch{$refused=$true}
if(!$refused){throw 'Writer plan accepted an unrelated page'}
$path=[IW7CapacityPages]::GetPlanPages('writer-path-20261019')
if(($path -join ',') -cne (@(0x14C1ED000,0x14BFE5000,0x140406000,0x140B20000,0x1412BF000,0x141238000,0x14B538000,0x140AC6000) -join ',')){throw 'Wrong retained writer path'}
$path[0]=0
if([IW7CapacityPages]::GetPlanPages('writer-path-20261019')[0] -ne 0x14C1ED000){throw 'Writer path mutable'}
$binding=[IW7CapacityPages]::GetPlanPages('binding-continuation-20261019')
if($binding.Count -ne 1 -or $binding[0] -ne 0x14B3C5000){throw 'Wrong binding continuation'}
$binding[0]=0
if([IW7CapacityPages]::GetPlanPages('binding-continuation-20261019')[0] -ne 0x14B3C5000){throw 'Binding continuation mutable'}
foreach($bad in @('arbitrary','RESET-ENTRY-TARGETS')) {
    $refused=$false;try{$null=[IW7CapacityPages]::GetPlanPages($bad)}catch{$refused=$true}
    if(!$refused){throw 'Unknown plan accepted'}
}
$refused=$false;try{[IW7CapacityPages]::ValidatePlanAddress('reset-entry-targets',0x140488000)}catch{$refused=$true}
if(!$refused){throw 'Cross-plan address accepted'}
$p=[Diagnostics.Process]::GetCurrentProcess()
$native=[IW7CapacityPages]::new($p.Id,$p.MainModule.FileName,$p.StartTime.ToUniversalTime().ToFileTimeUtc())
try {
    try{$null=$native.QueryPage(0x140488000)}catch [InvalidOperationException] {}
    # No game/process memory was read; query only this test's own address space.
} finally {$native.Dispose();$p.Dispose()}
if(!$native.Closed){throw 'Read-only self handle not closed'}
foreach($mode in @('normal','changed','partial','protection','two','writer','writer-path')) {
    $reader=[pscustomobject]@{ReadCalls=0;ReadBytes=0;Mode=$mode;Queries=0}
    $reader|Add-Member ScriptMethod AssertAlive {}
    $reader|Add-Member ScriptMethod QueryPage {
        param($address)
        $this.Queries++
        $row=[IW7CapacityRegion]::new();$row.BaseAddress=$address;$row.AllocationBase=$address;$row.RegionSize=4096
        $row.State=0x1000;$row.Protect=0x20;$row.Type=0x20000
        if($this.Mode -eq 'protection' -and $this.Queries -eq 2){$row.Protect=0x40}
        $row
    }
    $reader|Add-Member ScriptMethod ReadPage {
        param($address)
        $this.ReadCalls++
        $size=if($this.Mode -eq 'partial'){8}else{4096}
        $this.ReadBytes+=$size
        $bytes=[byte[]]::new($size)
        if($this.Mode -eq 'changed'){$bytes[0]=$this.ReadCalls}
        ,$bytes
    }
    $out=Join-Path $Temp $mode
    $selected=if($mode -eq 'two'){'reset-entry-targets'}elseif($mode -eq 'writer'){'writer-sites-20261019'}elseif($mode -eq 'writer-path'){'writer-path-20261019'}else{'reset-callers'}
    $refused=$false;try{Save-IW7CapacityCodePages $reader $out ([pscustomobject]@{PID=123}) $selected ([pscustomobject]@{synthetic=$true})}catch{$refused=$true}
    $record=Get-Content "$out/manifest.local.json" -Raw|ConvertFrom-Json
    if($mode -eq 'writer-path') {
        if($refused -or !$record.complete -or $record.pages.Count -ne 8 -or $record.read_calls -ne 16 -or $record.read_bytes -ne 65536 -or $record.page_plan -cne 'writer-path-20261019'){throw 'Writer path bounds failed'}
        if(@($record.pages|Where-Object owner -CNE 'selected-writer-path').Count){throw 'Writer path mislabelled as known function owner'}
    } elseif($mode -eq 'writer') {
        if($refused -or !$record.complete -or $record.pages.Count -ne 3 -or $record.read_calls -ne 6 -or $record.read_bytes -ne 24576 -or $record.page_plan -cne 'writer-sites-20261019'){throw 'Writer plan bounds failed'}
        if(@($record.pages|Where-Object owner -CNE 'observed-writer-site').Count){throw 'Writer site mislabelled as known function owner'}
    } elseif($mode -eq 'two') {
        if($refused -or !$record.complete -or $record.pages.Count -ne 2 -or $record.read_calls -ne 4 -or $record.read_bytes -ne 16384 -or $record.page_plan -cne 'reset-entry-targets'){throw 'Next plan bounds failed'}
        $total=(Get-ChildItem $out -Filter *.bin|Measure-Object Length -Sum).Sum
        if($total -ne 8192 -or !$record.parent_proof.synthetic -or $record.pages[0].owner -ne '140488520' -or $record.pages[1].owner -ne '140B20760'){throw 'Next plan payload/provenance failed'}
    } elseif($mode -eq 'normal'){
        if($refused -or !$record.complete -or $record.pages.Count -ne 8 -or $record.read_calls -ne 16 -or $record.read_bytes -ne 65536){throw 'Bounded in-process capture failed'}
        $total=(Get-ChildItem $out -Filter *.bin|Measure-Object Length -Sum).Sum
        if($total -ne 32768){throw 'Wrong payload size'}
    } else {if(!$refused -or $record.complete -or !$record.failure){throw 'Mutation/partial proof accepted'}}
    if($record.pristine -or $record.target_written -or $record.target_suspended -or $record.global_snapshot_coherent -or $record.child_processes){throw 'False provenance/effect claim'}
}
""", encoding='utf-8')
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(script), str(repo), temp],
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_admission_identity_debugger_and_reserved_scope(self):
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temp:
            script = Path(temp) / 'gate.ps1'
            script.write_text(r'''param($Repo)
$ErrorActionPreference='Stop'
. "$Repo/ops/Resource-Scheduler.Core.ps1"
. "$Repo/ops/agent-capacity/CodePages.Core.ps1"
$created=[datetime]::UtcNow.ToString('o')
$image='C:\synthetic-candidate\iw7-test.exe'
$identity=[pscustomobject]@{PID=123;Image=$image;CreatedUtc=$created;SHA256=('A'*64)}
$plan=[pscustomobject]@{Schema='iw7.agent-lab/1';Debugger=$true;PhysicalBytes=14GB;CommitBytes=15GB;ServerPort=27200;MainDeployed=$false;ServerImage=$image;NativeSHA256=$identity.SHA256;CandidateRoot='C:\synthetic-candidate'}
$lease=[pscustomobject]@{Kind='Runtime';Scope='c:\synthetic-candidate';PhysicalBytes=14GB;CommitBytes=15GB;Processes=@($identity)}
$process=[pscustomobject]@{ProcessId=123;ExecutablePath=$image;CommandLine='-dedicated -paris-isolated-lab -paris-server-test -paris-debugger'}
Assert-IW7CapacityPageAdmission $plan $identity $lease $process
foreach($kind in @('debugger','scope','pid','created','port','flags')) {
    $p=$plan.PSObject.Copy();$l=$lease.PSObject.Copy();$i=$identity.PSObject.Copy();$c=$process.PSObject.Copy()
    switch($kind){debugger{$p.Debugger=$false};scope{$l.Scope='c:\foreign'};pid{$c.ProcessId=999};created{$i.CreatedUtc=[datetime]::UtcNow.AddMinutes(-1).ToString('o')};port{$p.ServerPort=27016};flags{$c.CommandLine='-dedicated'}}
    $refused=$false;try{Assert-IW7CapacityPageAdmission $p $i $l $c}catch{$refused=$true}
    if(!$refused){throw "Admission failed to reject $kind"}
}
''', encoding='utf-8')
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(script), str(repo)],
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
