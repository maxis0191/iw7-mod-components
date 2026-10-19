$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../ops/agent-capacity/Checkpoint-Overlay.Core.ps1"
$encoding=[Text.UTF8Encoding]::new($false)
$checks=0
function Assert([bool]$Condition,[string]$Message) {
    if(!$Condition){throw $Message};$script:checks++
}
function Same([byte[]]$A,[byte[]]$B){(Get-IW7CapacityCheckpointHash $A) -ceq (Get-IW7CapacityCheckpointHash $B)}
function Refuses([scriptblock]$Action,[string]$Message){$refused=$false;try{& $Action|Out-Null}catch{$refused=$true};Assert $refused $Message}
$source=@'
#include <std_include.hpp>
#include "scheduler.hpp"
void server() {
    utils::hook::invoke<void>(0x140B15E20);
    execute(pipeline::server);
}
void main() {
    execute(pipeline::main);
    return utils::hook::invoke<void*>(0x140B8E2D0);
}
'@+"`n"
$source=$source.Replace("`r`n","`n")
$clean=$encoding.GetBytes($source)
$o=New-IW7CapacityCheckpointOverlays $clean
Assert (Same $o.Clean $clean) 'Clean bytes changed.'
$enabled=$encoding.GetString($o.Enabled)
Assert ($enabled.StartsWith('#include <std_include.hpp>'+"`n"+'#define IW7_PARIS_CAPACITY_CHECKPOINT_DRAFT 1')) 'Watch macro must follow the PCH.'
Assert ($enabled.Contains('execute(pipeline::server);'+"`n"+'#ifdef IW7_PARIS_CAPACITY_CHECKPOINT_DRAFT'+"`n`t`t"+'paris_capacity_watch::checkpoint(1);')) 'Server checkpoint must follow execute.'
Assert ($enabled.Contains('execute(pipeline::main);'+"`n"+'#ifdef IW7_PARIS_CAPACITY_CHECKPOINT_DRAFT'+"`n`t`t`t`t"+'paris_capacity_watch::checkpoint(2);')) 'Main checkpoint must follow execute.'
foreach($current in @($o.Watch,$o.Enabled)) {
    Assert (Same (Get-IW7CapacityCheckpointTransition $current $o BeforeDebugger $true) $o.Profiler) 'Owned watch reversal differs.'
}
foreach($current in @($o.Clean,$o.Profiler)) {
    Assert (Same (Get-IW7CapacityCheckpointTransition $current $o BeforeDebugger $false) $current) 'Before debugger should preserve the exact baseline.'
}
Assert (Same (Get-IW7CapacityCheckpointTransition $o.Profiler $o AfterDebugger $true) $o.Enabled) 'Enabled phase differs.'
Assert (Same (Get-IW7CapacityCheckpointTransition $o.Clean $o AfterDebugger $false) $o.Clean) 'Ordinary build changed.'
foreach($text in @($source.Replace("`n","`r`n"),$source.Substring(0,$source.Length-1),$source.Replace("`n","`r`n").TrimEnd("`r","`n"))) {
    Assert (Same (Get-IW7CapacityCheckpointTransition ($encoding.GetBytes($text)) $o BeforeDebugger $true) $o.Clean) 'Exact Windows baseline newline form refused.'
}
foreach($text in @($source+"`n",$source.Replace('void main()', 'void  main()'),$source.Replace("`n","`r"))) {
    Refuses {Get-IW7CapacityCheckpointTransition ($encoding.GetBytes($text)) $o BeforeDebugger $true} 'Unknown whitespace/source/newline edit accepted.'
}
Assert (!$encoding.GetString((Get-IW7CapacityCheckpointTransition $o.Clean $o AfterDebugger $false)).Contains('IW7_PARIS_CAPACITY_CHECKPOINT_DRAFT')) 'Ordinary build kept a watch macro.'
Refuses {Get-IW7CapacityCheckpointTransition $o.Profiler $o AfterDebugger $false} 'Disabled phase accepted debugger bytes.'
Refuses {Get-IW7CapacityCheckpointTransition $o.Clean $o AfterDebugger $true} 'Enabled phase accepted clean bytes.'
$unowned=$encoding.GetBytes($source+'unowned edit')
$hash=Get-IW7CapacityCheckpointHash $unowned
foreach($phase in @('BeforeDebugger','AfterDebugger')) {
    Refuses {Get-IW7CapacityCheckpointTransition $unowned $o $phase $true} 'Unknown scheduler bytes accepted.'
    Assert ((Get-IW7CapacityCheckpointHash $unowned) -ceq $hash) 'Refusal mutated unknown bytes.'
}
Refuses {New-IW7CapacityCheckpointOverlays ($encoding.GetBytes($source.Replace('execute(pipeline::server);','other();')))} 'Missing checkpoint anchor accepted.'
Refuses {New-IW7CapacityCheckpointOverlays ($encoding.GetBytes($source.Replace('execute(pipeline::main);','execute(pipeline::main); execute(pipeline::main);')))} 'Duplicate checkpoint anchor accepted.'
Refuses {New-IW7CapacityCheckpointOverlays ($encoding.GetBytes($source.Replace("`n","`r`n")))} 'Noncanonical bytes accepted.'
# Source snapshot only: cfca/993/77e scheduler blob d235aeee97891254b1c38b7841e01700e130220d.
# It is never compiled. The real Apply script reads/writes only our temporary source.
$nativeSchedulerFixture=@'
#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "scheduler.hpp"

#include "game/game.hpp"

#include <utils/hook.hpp>
#include <utils/concurrency.hpp>
#include <utils/string.hpp>
#include <utils/thread.hpp>

namespace scheduler
{
	namespace
	{
		struct task
		{
			std::function<bool()> handler{};
			std::chrono::milliseconds interval{};
			std::chrono::high_resolution_clock::time_point last_call{};
		};

		using task_list = std::vector<task>;

		class task_pipeline
		{
		public:
			void add(task&& task)
			{
				new_callbacks_.access([&task](task_list& tasks)
				{
					tasks.emplace_back(std::move(task));
				});
			}

			void execute()
			{
				callbacks_.access([&](task_list& tasks)
				{
					this->merge_callbacks();

					for (auto i = tasks.begin(); i != tasks.end();)
					{
						const auto now = std::chrono::high_resolution_clock::now();
						const auto diff = now - i->last_call;

						if (diff < i->interval)
						{
							++i;
							continue;
						}

						i->last_call = now;

						const auto res = i->handler();
						if (res == cond_end)
						{
							i = tasks.erase(i);
						}
						else
						{
							++i;
						}
					}
				});
			}

		private:
			utils::concurrency::container<task_list> new_callbacks_;
			utils::concurrency::container<task_list, std::recursive_mutex> callbacks_;

			void merge_callbacks()
			{
				callbacks_.access([&](task_list& tasks)
				{
					new_callbacks_.access([&](task_list& new_tasks)
					{
						tasks.insert(tasks.end(), std::move_iterator<task_list::iterator>(new_tasks.begin()),
							std::move_iterator<task_list::iterator>(new_tasks.end()));
						new_tasks = {};
					});
				});
			}
		};

		volatile bool kill = false;
		std::thread thread;
		task_pipeline pipelines[pipeline::count];

		void execute(const pipeline type)
		{
			assert(type >= 0 && type < pipeline::count);
			pipelines[type].execute();
		}

		void r_end_frame_stub()
		{
			execute(pipeline::renderer);
			utils::hook::invoke<void>(0x140E267B0);
		}

		void server_frame_stub()
		{
			utils::hook::invoke<void>(0x140B15E20);
			execute(pipeline::server);
		}

		void* main_frame_stub()
		{
			const auto _0 = gsl::finally([]()
			{
				execute(pipeline::main);
			});

			return utils::hook::invoke<void*>(0x140B8E2D0);
		}

		void hks_frame_stub()
		{
			const auto state = *game::hks::lua_state;
			if (state)
			{
				execute(pipeline::lui);
			}
			utils::hook::invoke<bool>(0x140613440);
		}
	}

	void schedule(const std::function<bool()>& callback, const pipeline type,
		const std::chrono::milliseconds delay)
	{
		assert(type >= 0 && type < pipeline::count);

		task task;
		task.handler = callback;
		task.interval = delay;
		task.last_call = std::chrono::high_resolution_clock::now();

		pipelines[type].add(std::move(task));
	}

	void loop(const std::function<void()>& callback, const pipeline type,
		const std::chrono::milliseconds delay)
	{
		schedule([callback]()
		{
			callback();
			return cond_continue;
		}, type, delay);
	}

	void once(const std::function<void()>& callback, const pipeline type,
		const std::chrono::milliseconds delay)
	{
		schedule([callback]()
		{
			callback();
			return cond_end;
		}, type, delay);
	}

	void on_game_initialized(const std::function<void()>& callback, const pipeline type,
		const std::chrono::milliseconds delay)
	{
		schedule([=]()
		{
			const auto dw_init = game::Live_SyncOnlineDataFlags(0) == 0;
			if (dw_init)
			{
				once(callback, type, delay);
				return cond_end;
			}

			return cond_continue;
		}, pipeline::main);
	}

	class component final : public component_interface
	{
	public:
		void post_start() override
		{
			thread = utils::thread::create_named_thread("Async Scheduler", []()
			{
				while (!kill)
				{
					execute(pipeline::async);
					std::this_thread::sleep_for(10ms);
				}
			});
		}

		void post_unpack() override
		{
			utils::hook::call(0x14034728C, scheduler::r_end_frame_stub);
			utils::hook::call(0x14048A7B9, scheduler::server_frame_stub); // sp call
			utils::hook::call(0x140B21941, scheduler::server_frame_stub); // mp call
			utils::hook::call(0x140B8E272, scheduler::main_frame_stub);
			utils::hook::call(0x1406173C2, scheduler::hks_frame_stub);
		}

		void pre_destroy() override
		{
			kill = true;
			if (thread.joinable())
			{
				thread.join();
			}
		}
	};
}

REGISTER_COMPONENT(scheduler::component)
'@
$nativeSchedulerFixture=$nativeSchedulerFixture.Replace("`r`n","`n")
$nativeSnapshot=$encoding.GetBytes($nativeSchedulerFixture)
$blobPrefix=[Text.Encoding]::ASCII.GetBytes("blob $($nativeSnapshot.Length)`0")
$blobIdentity=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($blobPrefix+$nativeSnapshot))).ToLowerInvariant()
Assert ($nativeSnapshot.Length -eq 4393 -and $blobIdentity -ceq 'd235aeee97891254b1c38b7841e01700e130220d') 'Native scheduler Source fixture drifted.'
$nativeClean=$encoding.GetBytes($nativeSchedulerFixture+"`n")
$nativeOverlays=New-IW7CapacityCheckpointOverlays $nativeClean
Assert ((Get-IW7CapacityCheckpointHash $nativeOverlays.Profiler) -ceq '263CC05D132DA8D7A01E2D12A2942ED3F137CC8E7B89DDF38B24D3BA3AE23ED7') 'Native profiler Source pin drifted.'
Assert ((Get-IW7CapacityCheckpointHash $nativeOverlays.Watch) -ceq 'BCB3E7488E94AA62E9F0352C5C967C881DE1B1022FC43C5ADC797559240C5486') 'Native watch Source pin drifted.'
$applyScript=Join-Path $PSScriptRoot '../../ops/agent-capacity/Apply-WatchCheckpointOverlay.ps1'
$fixtureParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$fixtureRoot=Join-Path $fixtureParent ('iw7-watch-disabled-source-'+[guid]::NewGuid().ToString('N'))
$fixturePath=Join-Path $fixtureRoot 'src/client/component/scheduler.cpp'
$knownSuccessor='cfca45b11ee14641945b9a264a95638387f48a4a'
$legacyPins=@('77e6d4d24e918ee363b3feee3735c3b889dff7d7','993737428781c4357fe21ecd375300e39a29a654')
$enabledPins=@($legacyPins)+@($knownSuccessor)
$unknownPin='1111111111111111111111111111111111111111'
$applySourceFixtureState=@{GitReads=0}
function Invoke-ApplySourceFixture([string]$Commit,[string]$Phase,[bool]$Enabled) {
    # This one Source-only Git read is authored; no native checkout/tool/process is used.
    function git {
        if($args.Count -ne 4 -or $args[0] -cne '-C' -or $args[1] -cne $fixtureRoot -or $args[2] -cne 'show' -or
           $args[3] -cne ($Commit+':src/client/component/scheduler.cpp')) {throw 'Unexpected Source fixture Git request.'}
        $applySourceFixtureState.GitReads++
        $global:LASTEXITCODE=0
        $nativeSchedulerFixture -split "`n"
    }
    & $applyScript -NativeRoot $fixtureRoot -Commit $Commit -Phase $Phase -Enabled:$Enabled
}
function Assert-ApplySourceRefuses([byte[]]$Current,[string]$Commit,[string]$Phase,[bool]$Enabled) {
    [IO.File]::WriteAllBytes($fixturePath,$Current)
    $before=Get-IW7CapacityCheckpointHash $Current
    Refuses {Invoke-ApplySourceFixture $Commit $Phase $Enabled} 'Apply accepted an unknown/enabled successor Source state.'
    Assert ((Get-IW7CapacityCheckpointHash ([IO.File]::ReadAllBytes($fixturePath))) -ceq $before) 'Apply refusal mutated Source fixture bytes.'
}
try {
    $null=[IO.Directory]::CreateDirectory((Split-Path $fixturePath -Parent))
    foreach($pin in @($legacyPins)+@($knownSuccessor)) {
        foreach($current in @($nativeOverlays.Clean,$nativeOverlays.Profiler,$nativeOverlays.Watch,$nativeOverlays.Enabled)) {
            [IO.File]::WriteAllBytes($fixturePath,$current)
            $result=Invoke-ApplySourceFixture $pin BeforeDebugger $false
            $expected=if((Get-IW7CapacityCheckpointHash $current) -cin @(
                (Get-IW7CapacityCheckpointHash $nativeOverlays.Watch),(Get-IW7CapacityCheckpointHash $nativeOverlays.Enabled))) {
                $nativeOverlays.Profiler
            }else{$current}
            Assert (!$result.Enabled -and !$result.Ready -and $result.Commit -ceq $pin -and
                (Same ([IO.File]::ReadAllBytes($fixturePath)) $expected)) 'Disabled BeforeDebugger did not preserve the exact known Source transition.'
        }
        # The existing disabled debugger helper removes its owned profiler between phases.
        [IO.File]::WriteAllBytes($fixturePath,$nativeOverlays.Clean)
        $result=Invoke-ApplySourceFixture $pin AfterDebugger $false
        Assert (!$result.Enabled -and !$result.Ready -and (Same ([IO.File]::ReadAllBytes($fixturePath)) $nativeOverlays.Clean)) 'Disabled AfterDebugger changed the clean Source.'
        Assert-ApplySourceRefuses $nativeOverlays.Profiler $pin AfterDebugger $false
    }
    foreach($pin in $enabledPins) {
        [IO.File]::WriteAllBytes($fixturePath,$nativeOverlays.Profiler)
        $result=Invoke-ApplySourceFixture $pin BeforeDebugger $true
        Assert ($result.Enabled -and (Same ([IO.File]::ReadAllBytes($fixturePath)) $nativeOverlays.Profiler)) 'Legacy enabled BeforeDebugger changed.'
        $result=Invoke-ApplySourceFixture $pin AfterDebugger $true
        Assert ($result.Enabled -and (Same ([IO.File]::ReadAllBytes($fixturePath)) $nativeOverlays.Enabled)) 'Legacy enabled AfterDebugger changed.'
    }
    foreach($phase in @('BeforeDebugger','AfterDebugger')) {
        Assert-ApplySourceRefuses ($encoding.GetBytes($nativeSchedulerFixture+"`n// unowned mutation`n")) $knownSuccessor $phase $true
        Assert-ApplySourceRefuses ($encoding.GetBytes($nativeSchedulerFixture+"`n// unowned mutation`n")) $knownSuccessor $phase $false
        Assert-ApplySourceRefuses $nativeOverlays.Profiler $unknownPin $phase $false
        Assert-ApplySourceRefuses $nativeOverlays.Clean $unknownPin $phase $true
    }
    # Unknown ordinary pins retain the pre-existing clean-only behavior.
    [IO.File]::WriteAllBytes($fixturePath,$nativeClean)
    $result=Invoke-ApplySourceFixture $unknownPin BeforeDebugger $false
    Assert (!$result.Enabled -and !$result.Ready -and (Same ([IO.File]::ReadAllBytes($fixturePath)) $nativeClean)) 'Unknown clean-only legacy behavior changed.'
    Assert ($applySourceFixtureState.GitReads -eq 31) 'The real Apply Source entry was skipped or performed an unexpected Git read.'
} finally {
    $resolvedFixture=[IO.Path]::GetFullPath($fixtureRoot)
    if([IO.Path]::GetDirectoryName($resolvedFixture) -cne $fixtureParent -or
       [IO.Path]::GetFileName($resolvedFixture) -cnotmatch '^iw7-watch-disabled-source-[a-f0-9]{32}$') {
        throw 'Refuse cleanup outside the owned Source fixture.'
    }
    if(Test-Path -LiteralPath $resolvedFixture){Remove-Item -LiteralPath $resolvedFixture -Recurse -Force}
}
Write-Output "PASS $checks capacity checkpoint overlay checks; real Apply Source entry with temporary authored inputs, no native checkout/compiler/lease."
