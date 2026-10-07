using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace IW7.VoicePairDraft
{
    // File-only, in-process analysis. It cannot launch a helper, use a device,
    // transcribe words or upload PCM. Limits are checked before allocation.
    public static class WaveAnalysis
    {
        private sealed class PCM
        {
            public double[] Envelope;
            public Dictionary<string, object> Metadata;
        }
        private static ushort U16(byte[] b, int p) { return BitConverter.ToUInt16(b, p); }
        private static uint U32(byte[] b, int p) { return BitConverter.ToUInt32(b, p); }
        private static string Tag(byte[] b, int p) { return Encoding.ASCII.GetString(b,p,4); }
        private static PCM ReadPCM(string path, bool source)
        {
            byte[] blob;
            using (var file = new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read))
            {
                long bound=source ? 480102L : 44L+15L*192000L;
                if(file.Length<44 || file.Length>bound)throw new InvalidDataException("Bounded RIFF file required");
                blob=new byte[checked((int)file.Length)];
                int done=0;
                while(done<blob.Length){int n=file.Read(blob,done,blob.Length-done);if(n==0)throw new EndOfStreamException();done+=n;}
            }
            if(Tag(blob,0)!="RIFF" || Tag(blob,8)!="WAVE" || U32(blob,4)!=(uint)blob.Length-8)
                throw new InvalidDataException("Complete RIFF length required");
            int rate=source?16000:48000, channels=source?1:2, dataOffset=0, dataBytes=0;
            bool fmt=false, data=false;
            for(long offset=12;offset<blob.Length;)
            {
                if(offset+8>blob.Length)throw new InvalidDataException("Truncated RIFF chunk header");
                int chunk=checked((int)offset);long size=U32(blob,chunk+4), start=offset+8;
                if(start+size+(size%2)>blob.Length)throw new InvalidDataException("Truncated RIFF chunk");
                string tag=Tag(blob,chunk);int p=checked((int)start);
                if(tag=="fmt ")
                {
                    if(fmt || (size!=16 && size!=18) || U16(blob,p)!=1 || U16(blob,p+2)!=channels ||
                        U32(blob,p+4)!=rate || U32(blob,p+8)!=rate*channels*2 || U16(blob,p+12)!=channels*2 ||
                        U16(blob,p+14)!=16 || (size==18 && U16(blob,p+16)!=0))
                        throw new InvalidDataException("Exact PCM16 source mono16k or receiver stereo48k required");
                    fmt=true;
                }
                else if(tag=="data")
                {
                    if(!fmt || data || size<1 || size%(channels*2)!=0 || size>rate*channels*2L*15)
                        throw new InvalidDataException("Unique bounded PCM payload required");
                    data=true;dataOffset=p;dataBytes=checked((int)size);
                }
                offset=start+size+(size%2);
            }
            if(!fmt || !data)throw new InvalidDataException("PCM chunks missing");
            int frames=dataBytes/(channels*2), width=rate/100, bins=(frames+width-1)/width;
            if(bins>1500)throw new InvalidDataException("Envelope exceeds 15s bound");
            var envelope=new double[bins];
            for(int bin=0;bin<bins;bin++)
            {
                int first=bin*width,end=Math.Min(frames,first+width);double energy=0;
                for(int f=first;f<end;f++)for(int c=0;c<channels;c++)
                {double value=BitConverter.ToInt16(blob,dataOffset+(f*channels+c)*2);energy+=value*value;}
                double rms=Math.Sqrt(energy/((end-first)*channels))/32768.0;
                envelope[bin]=Math.Log(1+rms*20.0);
            }
            string hash;
            using(var sha=SHA256.Create())hash=BitConverter.ToString(sha.ComputeHash(blob)).Replace("-","").ToLowerInvariant();
            return new PCM {Envelope=envelope,Metadata=new Dictionary<string,object>{
                {"sha256",hash},{"rate",rate},{"channels",channels},{"frames",frames},{"seconds",frames/(double)rate}}};
        }
        public static Dictionary<string,object> Compare(double[] source,double[] receiver)
        {
            if(source==null || receiver==null || source.Length<1 || source.Length>1500 || receiver.Length>1500 || receiver.Length<source.Length)
                throw new InvalidDataException("Bounded source and covering receiver required");
            double mean=0;foreach(double value in source){if(!Double.IsFinite(value))throw new InvalidDataException("Nonfinite envelope");mean+=value;}
            foreach(double value in receiver)if(!Double.IsFinite(value))throw new InvalidDataException("Nonfinite envelope");
            mean/=source.Length;var centered=new double[source.Length];double variance=0;
            for(int i=0;i<source.Length;i++){centered[i]=source[i]-mean;variance+=centered[i]*centered[i];}
            if(variance<1e-8)throw new InvalidDataException("Source envelope has no recognizable variation");
            var scores=new double[receiver.Length-source.Length+1];int best=0;
            for(int lag=0;lag<scores.Length;lag++)
            {
                double avg=0;for(int i=0;i<source.Length;i++)avg+=receiver[lag+i];avg/=source.Length;
                double energy=0,dot=0;
                for(int i=0;i<source.Length;i++){double y=receiver[lag+i]-avg;energy+=y*y;dot+=centered[i]*y;}
                scores[lag]=energy>1e-8?Math.Max(-1,Math.Min(1,dot/Math.Sqrt(variance*energy))):0;
                if(scores[lag]>scores[best])best=lag;
            }
            var outside=new List<double>();for(int i=0;i<scores.Length;i++)if(Math.Abs(i-best)>50)outside.Add(scores[i]);
            outside.Sort();double median=outside.Count>0?outside[outside.Count/2]:0,score=scores[best];
            return new Dictionary<string,object>{{"bin_ms",10},{"lag_ms",best*10},{"normalized_envelope_correlation",score},
                {"other_lags_median",median},{"contrast_to_other_lags",score-median},
                {"envelope_similarity_observed",score>=0.60 && score-median>=0.15},
                {"threshold_scope","diagnostic heuristic; false matches/masking are possible, never word recognition"},
                {"decoded_words_verified",false},{"intelligibility_accepted",false},{"human_conversation_accepted",false}};
        }
        public static Dictionary<string,object> Analyze(string sourcePath,string receiverPath,string expectedSourceHash)
        {
            if(expectedSourceHash==null || expectedSourceHash.Length!=64 || expectedSourceHash.Trim("0123456789abcdefABCDEF".ToCharArray()).Length!=0)
                throw new ArgumentException("Pinned source hash required");
            PCM source=ReadPCM(sourcePath,true),receiver=ReadPCM(receiverPath,false);
            if(!String.Equals((string)source.Metadata["sha256"],expectedSourceHash,StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Pinned source hash mismatch");
            return new Dictionary<string,object>{{"source",source.Metadata},{"receiver",receiver.Metadata},{"comparison",Compare(source.Envelope,receiver.Envelope)},
                {"method","PCM energy per channel -> RMS10ms -> log compression -> bounded normalized lag correlation"},
                {"in_process",true},{"microphone_read",false},{"network_upload",false}};
        }
    }
}
