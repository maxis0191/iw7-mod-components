using System;
using IW7.Diagnostics.Source;

namespace IW7.Tests.Source
{
    public static class SourceGuardRootCandidateTests
    {
        private static int assertions;
        private const string Prefix = @"\Device\Observed_Volume-7";
        private const string Relative = @"\Users\example\profile.json";
        private static void Check(bool condition, string message)
        {
            assertions++;
            if (!condition) throw new InvalidOperationException(message);
        }

        private static byte[] Id()
        {
            var bytes = new byte[16];
            for (int i = 0; i < bytes.Length; i++) bytes[i] = (byte)(i * 17);
            return bytes;
        }

        private static SourceGuardFileIdentity Identity(ulong volume = ulong.MaxValue)
        {
            return new SourceGuardFileIdentity(volume, Id());
        }

        private static SourceGuardPathObservation Path(string text)
        {
            return new SourceGuardPathObservation((uint)text.Length, text + '\0');
        }

        private static SourceGuardRootDerivation Derive(string n, string r)
        {
            return SourceGuardRootCandidate.Derive(Path(n), Path(r), Identity(), Identity());
        }

        private static void Refuses(SourceGuardRootDerivation result, SourceRootRefusal reason, string message)
        {
            Check(result.Refusal == reason && !result.HasCandidate && result.CandidateRoot == null &&
                  result.CountedNameBytes == 0 && result.TerminatedNameBufferBytes == 0, message);
        }

        private static void InvalidId(byte[] bytes, string message)
        {
            bool threw = false;
            try { new SourceGuardFileIdentity(1, bytes); } catch (ArgumentException) { threw = true; }
            Check(threw, message);
        }

        private static void PathFailures()
        {
            var goodN = Path(Prefix + Relative);
            var goodR = Path(Relative);
            var id = Identity();
            Refuses(SourceGuardRootCandidate.Derive(null, goodR, id, id), SourceRootRefusal.MissingPath, "Absent NT query.");
            Refuses(SourceGuardRootCandidate.Derive(goodN, null, id, id), SourceRootRefusal.MissingPath, "Absent NONE query.");
            Refuses(SourceGuardRootCandidate.Derive(new SourceGuardPathObservation(0, null), goodR, id, id),
                    SourceRootRefusal.QueryFailed, "Zero return is query failure, not empty success.");
            Refuses(SourceGuardRootCandidate.Derive(new SourceGuardPathObservation(10, null), goodR, id, id),
                    SourceRootRefusal.MissingPath, "Missing captured buffer.");
            Refuses(SourceGuardRootCandidate.Derive(new SourceGuardPathObservation(2048, "unused"), goodR, id, id),
                    SourceRootRefusal.InsufficientCapacity, "Required capacity is not a successful path length.");
            Refuses(SourceGuardRootCandidate.Derive(new SourceGuardPathObservation(uint.MaxValue, "unused"), goodR, id, id),
                    SourceRootRefusal.InsufficientCapacity, "Full DWORD length must not narrow/overflow.");
            Refuses(SourceGuardRootCandidate.Derive(new SourceGuardPathObservation(10, "unused", 4096), goodR, id, id),
                    SourceRootRefusal.WrongCapacity, "No larger capacity fallback.");
            Refuses(SourceGuardRootCandidate.Derive(new SourceGuardPathObservation(10, "unused", 2047), goodR, id, id),
                    SourceRootRefusal.WrongCapacity, "Exact declared WCHAR capacity.");
            Refuses(SourceGuardRootCandidate.Derive(new SourceGuardPathObservation(10, new string('x', 2049)), goodR, id, id),
                    SourceRootRefusal.OversizedBuffer, "Oversized snapshot refused before scanning.");
            Refuses(SourceGuardRootCandidate.Derive(new SourceGuardPathObservation(10, "short"), goodR, id, id),
                    SourceRootRefusal.PartialBuffer, "Partial observation lacks declared end.");
            string n = Prefix + Relative;
            Refuses(SourceGuardRootCandidate.Derive(new SourceGuardPathObservation((uint)n.Length, n), goodR, id, id),
                    SourceRootRefusal.PartialBuffer, "Terminator must be captured, not inferred.");
            Refuses(SourceGuardRootCandidate.Derive(new SourceGuardPathObservation((uint)n.Length, n + 'X'), goodR, id, id),
                    SourceRootRefusal.MissingTerminator, "Character at reported end is not NUL.");
            Refuses(Derive(Prefix + "\0" + Relative, Relative), SourceRootRefusal.EmbeddedNul, "Embedded NUL in NT path.");
            Refuses(Derive(Prefix + Relative + "\ud800", Relative), SourceRootRefusal.InvalidUtf16, "Unpaired high surrogate.");
            Refuses(Derive(Prefix + "\udc00" + Relative, Relative), SourceRootRefusal.InvalidUtf16, "Unpaired low surrogate.");
            Refuses(Derive(Prefix + "\ud800x" + Relative, Relative), SourceRootRefusal.InvalidUtf16, "High surrogate followed by non-low character.");
            Refuses(Derive(Prefix + Relative, "\\f\0ile"), SourceRootRefusal.EmbeddedNul, "Embedded NUL in relative query.");
            Refuses(Derive(Prefix + Relative, "\\f\udc00"), SourceRootRefusal.InvalidUtf16, "Relative UTF16 is validated too.");
        }

        private static void GrammarFailures()
        {
            string[] invalidRelative = {
                "file", "\\", "\\\\file", "\\dir\\\\file", "\\dir\\", "\\.\\file", "\\..\\file",
                "\\dir.\\file", "\\dir \\file", "\\file:stream", "\\dir/file", "\\fi*le", "\\fi?le",
                "\\short~1\\file", "\\bad\nfile", "\\bad\u007ffile", "\\dir\u2044file", "\\dir\u2215file",
                "\\dir\uff0ffile", "\\dir\uff3cfile"
            };
            foreach (string r in invalidRelative)
                Refuses(Derive(Prefix + r, r), SourceRootRefusal.RelativePathGrammar, "Relative grammar: " + r);
            Refuses(Derive(Prefix + @"\dir\file", @"\Dir\file"), SourceRootRefusal.SuffixMismatch, "Ordinal suffix, no case folding.");
            Refuses(Derive(Prefix + @"\other", @"\file"), SourceRootRefusal.SuffixMismatch, "Unrelated suffix.");
            Refuses(Derive(@"\file", @"\file"), SourceRootRefusal.SuffixMismatch, "No empty prefix.");
            Refuses(Derive("x", @"\file"), SourceRootRefusal.SuffixMismatch, "NT path shorter than suffix.");
            string[] invalidPrefix = {
                @"\device\Volume", @"\??\C:", @"\\?\Volume{fake}", @"\Device\", @"\Device\a\b",
                @"\Device\.", @"\Device\..", @"\Device\a.b", @"\Device\a:b", @"\Device\a*b",
                @"\Device\a?b", @"\Device\a~1", "\\Device\\a b", "\\Device\\a\tb", "\\Device\\a\u00e9"
            };
            foreach (string p in invalidPrefix)
                Refuses(Derive(p + Relative, Relative), SourceRootRefusal.DevicePrefixGrammar, "Device grammar: " + p);
        }

        public static int Run()
        {
            assertions = 0;
            var result = Derive(Prefix + Relative, Relative);
            Check(result.HasCandidate && result.Refusal == SourceRootRefusal.None && result.CandidateRoot == Prefix + "\\",
                  "Exact observed N-R candidate, no guessed C:/GUID/volume number.");
            Check(result.CountedNameBytes == result.CandidateRoot.Length * 2 &&
                  result.TerminatedNameBufferBytes == result.CountedNameBytes + 2, "WCHAR versus byte bounds.");
            Check(!SourceGuardRootCandidate.NativeEligibility && !SourceGuardRootCandidate.PendingRouteQualified &&
                  SourceGuardRootCandidate.OperationalRoot == "NotObserved_NotConfigured" &&
                  SourceGuardRootCandidate.Provider == "Unknown_Unqualified" &&
                  SourceGuardRootCandidate.DbgHelpPdbUnmatched == "NotApplicable" &&
                  SourceGuardRootCandidate.H3Outcome == "Refused", "Candidate promoted operational state.");
            InvalidId(null, "Absent ID cannot become zero.");
            InvalidId(new byte[15], "Partial 128-bit ID refused.");
            InvalidId(new byte[17], "Extra ID bytes not silently truncated.");
            Refuses(SourceGuardRootCandidate.Derive(Path(Prefix + Relative), Path(Relative), null, Identity()),
                    SourceRootRefusal.MissingIdentity, "Before identity unavailable.");
            Refuses(SourceGuardRootCandidate.Derive(Path(Prefix + Relative), Path(Relative), Identity(), null),
                    SourceRootRefusal.MissingIdentity, "After identity unavailable.");
            var bytes = Id();
            var before = new SourceGuardFileIdentity(0x8000000000000001UL, bytes);
            var after = new SourceGuardFileIdentity(0x8000000000000001UL, bytes);
            bytes[15] ^= 1;
            Check(SourceGuardRootCandidate.Derive(Path(Prefix + Relative), Path(Relative), before, after).HasCandidate,
                  "Caller array mutation changed copied identity observations.");
            Refuses(SourceGuardRootCandidate.Derive(Path(Prefix + Relative), Path(Relative), before,
                    new SourceGuardFileIdentity(0x8000000000000001UL, bytes)), SourceRootRefusal.IdentityChanged,
                    "High 64 bits of the opaque file ID must be compared.");
            Refuses(SourceGuardRootCandidate.Derive(Path(Prefix + Relative), Path(Relative), Identity(0x100000001UL), Identity(1)),
                    SourceRootRefusal.IdentityChanged, "Volume must not truncate to a DWORD.");
            Refuses(SourceGuardRootCandidate.Derive(Path(Prefix + Relative), Path(Relative), Identity(ulong.MaxValue), Identity(long.MaxValue)),
                    SourceRootRefusal.IdentityChanged, "Unsigned volume high bit retained.");
            var zero = new SourceGuardFileIdentity(0, new byte[16]);
            Check(SourceGuardRootCandidate.Derive(Path(Prefix + Relative), Path(Relative), zero, zero).HasCandidate,
                  "Known zero data is not an unavailable identity; this is not native identity qualification.");
            string maxPrefix = @"\Device\" + new string('v', 248);
            var edge = Derive(maxPrefix + @"\f", @"\f");
            Check(edge.HasCandidate && edge.CandidateRoot.Length == 257 && edge.CountedNameBytes == 514 &&
                  edge.TerminatedNameBufferBytes == 516, "Exact prefix/root counted-name boundary.");
            Refuses(Derive(maxPrefix + "x" + Relative, Relative), SourceRootRefusal.PrefixTooLong, "Prefix cap before result construction.");
            string maxR = "\\" + new string('u', 2047 - Prefix.Length - 1);
            Check(Derive(Prefix + maxR, maxR).HasCandidate, "Maximum successful DWORD path length2047.");
            var tail = new SourceGuardPathObservation((uint)(Prefix + Relative).Length, Prefix + Relative + "\0\ud800ignored");
            Check(SourceGuardRootCandidate.Derive(tail, Path(Relative), Identity(), Identity()).HasCandidate,
                  "Unwritten tail beyond reported terminator must not be interpreted.");
            string unicode = "\\Users\\\u00e9\ud83d\ude42\\profile.json";
            Check(Derive(Prefix + unicode, unicode).HasCandidate, "Well-formed Unicode suffix is compared without normalization.");
            PathFailures();
            GrammarFailures();
            Check(!SourceGuardRootCandidate.NativeEligibility && !SourceGuardRootCandidate.PendingRouteQualified &&
                  result.CandidateRoot == Prefix + "\\", "Derived results cannot mutate candidate/configuration state.");
            return assertions;
        }
    }
}
