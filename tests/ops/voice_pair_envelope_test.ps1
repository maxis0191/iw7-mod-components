$ErrorActionPreference='Stop'
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
if(!('IW7.VoicePairDraft.WaveAnalysis' -as [type])){Add-Type -Path "$repo/ops/voice-agent/Analyze-WAV.cs"}
function Check($v,$message){if(!$v){throw $message}}
function Refuses($body){$failed=$false;try{&$body|Out-Null}catch{$failed=$true};Check $failed 'Invalid WAV/envelope accepted.'}
Add-Type @'
using System;
using System.Text;
public static class IW7VoiceEnvelopeFixture {
 public static byte[] WAV(double[] bins,int rate,int channels,bool invertSecond) {
  int frames=bins.Length*(rate/100),pcm=frames*channels*2;byte[] b=new byte[44+pcm];
  Encoding.ASCII.GetBytes("RIFF").CopyTo(b,0);BitConverter.GetBytes((uint)(36+pcm)).CopyTo(b,4);
  Encoding.ASCII.GetBytes("WAVEfmt ").CopyTo(b,8);BitConverter.GetBytes((uint)16).CopyTo(b,16);
  BitConverter.GetBytes((ushort)1).CopyTo(b,20);BitConverter.GetBytes((ushort)channels).CopyTo(b,22);
  BitConverter.GetBytes((uint)rate).CopyTo(b,24);BitConverter.GetBytes((uint)(rate*channels*2)).CopyTo(b,28);
  BitConverter.GetBytes((ushort)(channels*2)).CopyTo(b,32);BitConverter.GetBytes((ushort)16).CopyTo(b,34);
  Encoding.ASCII.GetBytes("data").CopyTo(b,36);BitConverter.GetBytes((uint)pcm).CopyTo(b,40);
  for(int f=0;f<frames;f++){short x=(short)(bins[f/(rate/100)]*12000*(f%2==0?1:-1));
   for(int c=0;c<channels;c++)BitConverter.GetBytes((short)(invertSecond && c==1?-x:x)).CopyTo(b,44+(f*channels+c)*2);}
  return b;
 }
}
'@
$shape=[double[]]::new(400)
for($i=0;$i -lt 300;$i++){$shape[$i+50]=if($i%67 -lt 45){0.2+0.8*[math]::Pow([math]::Sin($i*0.067),2)}else{0.015}}
$rx=[double[]]::new(837);$rng=[Random]::new(471)
for($i=0;$i -lt $rx.Length;$i++){$rx[$i]=$rng.NextDouble()*0.015}
for($i=0;$i -lt $shape.Length;$i++){$rx[137+$i]=0.5*[math]::Pow($shape[$i],0.7)+$rng.NextDouble()*0.015}
$comparison=[IW7.VoicePairDraft.WaveAnalysis]::Compare($shape,$rx)
Check ($comparison['lag_ms'] -eq 1370 -and $comparison['normalized_envelope_correlation'] -gt 0.95 -and $comparison['envelope_similarity_observed']) 'Expected delayed nonlinear gain not detected.'
Check (!$comparison['decoded_words_verified'] -and !$comparison['intelligibility_accepted']) 'Energy comparison claimed recognized words.'
Refuses{[IW7.VoicePairDraft.WaveAnalysis]::Compare([double[]]::new(400),[double[]]::new(800))}
Refuses{[IW7.VoicePairDraft.WaveAnalysis]::Compare($shape,[double[]]::new(399))}
Refuses{[IW7.VoicePairDraft.WaveAnalysis]::Compare($shape,[double[]]::new(1501))}
$noise=[double[]]::new(800);for($i=0;$i -lt $noise.Length;$i++){$noise[$i]=$rng.NextDouble()}
Check (!([IW7.VoicePairDraft.WaveAnalysis]::Compare($shape,$noise)['envelope_similarity_observed'])) 'Independent noise accepted as matching shape.'
$root=Join-Path ([IO.Path]::GetTempPath()) ('iw7-voice-inprocess-wave-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
 $source=Join-Path $root 'source.wav';$receiver=Join-Path $root 'receiver.wav'
 $bytes=[IW7VoiceEnvelopeFixture]::WAV($shape,16000,1,$false);[IO.File]::WriteAllBytes($source,$bytes)
 [IO.File]::WriteAllBytes($receiver,[IW7VoiceEnvelopeFixture]::WAV($rx,48000,2,$true));$hash=(Get-FileHash $source).Hash
 $result=[IW7.VoicePairDraft.WaveAnalysis]::Analyze($source,$receiver,$hash)
 Check ($result['in_process'] -and $result['comparison']['lag_ms'] -eq 1370 -and $result['comparison']['envelope_similarity_observed'] -and !$result['microphone_read'] -and !$result['network_upload']) 'Real WAV delay/phase-inversion comparison failed.'
 Refuses{[IW7.VoicePairDraft.WaveAnalysis]::Analyze($source,$receiver,('0'*64))}
 foreach($offset in @(0,4,8,16,20,22,24,28,32,34,36,40)){
  $bad=[byte[]]$bytes.Clone();$bad[$offset]=$bad[$offset] -bxor 1;[IO.File]::WriteAllBytes($source,$bad)
  Refuses{[IW7.VoicePairDraft.WaveAnalysis]::Analyze($source,$receiver,(Get-FileHash $source).Hash)}
 }
 [IO.File]::WriteAllBytes($source,$bytes[0..($bytes.Length-2)])
 Refuses{[IW7.VoicePairDraft.WaveAnalysis]::Analyze($source,$receiver,(Get-FileHash $source).Hash)}
 'PASS in-process WAV: real pinned PCM source + delayed stereo phase-inverted receiver, lag1370ms nonlinear gain, malformed12fields/truncation/hash/noise/silence/bounds refusal. No process launch/audio/API/network/word recognition.'
}finally{
 if(!$root.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){throw 'Test cleanup escaped temp.'}
 Remove-Item -LiteralPath $root -Recurse -Force
}
