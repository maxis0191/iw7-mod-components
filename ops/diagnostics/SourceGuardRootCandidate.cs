using System;

namespace IW7.Diagnostics.Source
{
    public sealed class SourceGuardFileIdentity
    {
        private readonly byte[] fileId;
        public ulong VolumeSerial { get; }

        public SourceGuardFileIdentity(ulong volumeSerial, byte[] fileId128)
        {
            if (fileId128 == null || fileId128.Length != 16)
                throw new ArgumentException("A complete opaque 16-byte file ID is required.", nameof(fileId128));
            VolumeSerial = volumeSerial;
            fileId = (byte[])fileId128.Clone();
        }

        internal bool SameAs(SourceGuardFileIdentity other)
        {
            if (VolumeSerial != other.VolumeSerial) return false;
            for (int i = 0; i < 16; i++) if (fileId[i] != other.fileId[i]) return false;
            return true;
        }
    }

    // Data supplied by a caller, not a native query or proof of a held handle.
    public sealed class SourceGuardPathObservation
    {
        public uint CapacityWchars { get; }
        public uint ReturnedLength { get; }
        public string Buffer { get; }

        public SourceGuardPathObservation(uint returnedLength, string buffer, uint capacityWchars = 2048)
        {
            ReturnedLength = returnedLength;
            Buffer = buffer; // Strings are immutable; the terminating character must be captured.
            CapacityWchars = capacityWchars;
        }
    }

    public enum SourceRootRefusal
    {
        None, MissingIdentity, IdentityChanged, MissingPath, WrongCapacity, QueryFailed,
        InsufficientCapacity, OversizedBuffer, PartialBuffer, MissingTerminator,
        EmbeddedNul, InvalidUtf16, RelativePathGrammar, SuffixMismatch,
        DevicePrefixGrammar, PrefixTooLong
    }

    public sealed class SourceGuardRootDerivation
    {
        public SourceRootRefusal Refusal { get; }
        public bool HasCandidate { get { return Refusal == SourceRootRefusal.None; } }
        public string CandidateRoot { get; }
        public int CountedNameBytes { get { return CandidateRoot == null ? 0 : CandidateRoot.Length * 2; } }
        public int TerminatedNameBufferBytes { get { return CandidateRoot == null ? 0 : CountedNameBytes + 2; } }

        internal SourceGuardRootDerivation(SourceRootRefusal refusal, string candidate = null)
        {
            Refusal = refusal;
            CandidateRoot = candidate;
        }
    }

    public static class SourceGuardRootCandidate
    {
        public const string OperationalRoot = "NotObserved_NotConfigured";
        public const bool PendingRouteQualified = false;
        public const bool NativeEligibility = false;
        public const string Provider = "Unknown_Unqualified";
        public const string DbgHelpPdbUnmatched = "NotApplicable";
        public const string H3Outcome = "Refused";
        private const string DeviceStart = @"\Device\";

        private static SourceRootRefusal Decode(SourceGuardPathObservation observation, out string text)
        {
            text = null;
            if (observation == null) return SourceRootRefusal.MissingPath;
            if (observation.CapacityWchars != 2048) return SourceRootRefusal.WrongCapacity;
            if (observation.ReturnedLength == 0) return SourceRootRefusal.QueryFailed;
            if (observation.ReturnedLength >= 2048) return SourceRootRefusal.InsufficientCapacity;
            if (observation.Buffer == null) return SourceRootRefusal.MissingPath;
            if (observation.Buffer.Length > 2048) return SourceRootRefusal.OversizedBuffer;
            int length = (int)observation.ReturnedLength; // Cast only after the fixed bound.
            if (observation.Buffer.Length <= length) return SourceRootRefusal.PartialBuffer;
            if (observation.Buffer[length] != '\0') return SourceRootRefusal.MissingTerminator;
            for (int i = 0; i < length; i++)
            {
                char c = observation.Buffer[i];
                if (c == '\0') return SourceRootRefusal.EmbeddedNul;
                if (char.IsHighSurrogate(c))
                {
                    if (i + 1 >= length || !char.IsLowSurrogate(observation.Buffer[i + 1]))
                        return SourceRootRefusal.InvalidUtf16;
                    i++;
                }
                else if (char.IsLowSurrogate(c)) return SourceRootRefusal.InvalidUtf16;
            }
            text = observation.Buffer.Substring(0, length);
            return SourceRootRefusal.None;
        }

        private static bool RelativeGrammar(string text)
        {
            if (text.Length < 2 || text[0] != '\\' || text[1] == '\\') return false;
            int start = 1;
            for (int i = 1; i <= text.Length; i++)
            {
                if (i == text.Length || text[i] == '\\')
                {
                    int count = i - start;
                    if (count == 0 || (count == 1 && text[start] == '.') ||
                        (count == 2 && text[start] == '.' && text[start + 1] == '.') ||
                        text[i - 1] == '.' || text[i - 1] == ' ') return false;
                    start = i + 1;
                }
                else
                {
                    char c = text[i];
                    if (c < 32 || c == 127 || c == '/' || c == ':' || c == '*' || c == '?' ||
                        c == '~' || c == '\u2044' || c == '\u2215' || c == '\uff0f' || c == '\uff3c') return false;
                }
            }
            return true;
        }

        // One pass only: validate supplied Source-file observations and derive a candidate N-R.
        // This cannot prove same-handle provenance, a root ID, locality, ABI, atomicity or authority.
        public static SourceGuardRootDerivation Derive(SourceGuardPathObservation nt,
            SourceGuardPathObservation relative, SourceGuardFileIdentity before, SourceGuardFileIdentity after)
        {
            if (before == null || after == null) return new SourceGuardRootDerivation(SourceRootRefusal.MissingIdentity);
            if (!before.SameAs(after)) return new SourceGuardRootDerivation(SourceRootRefusal.IdentityChanged);
            string n, r;
            SourceRootRefusal refusal = Decode(nt, out n);
            if (refusal != SourceRootRefusal.None) return new SourceGuardRootDerivation(refusal);
            refusal = Decode(relative, out r);
            if (refusal != SourceRootRefusal.None) return new SourceGuardRootDerivation(refusal);
            if (!RelativeGrammar(r)) return new SourceGuardRootDerivation(SourceRootRefusal.RelativePathGrammar);
            if (n.Length <= r.Length || !n.EndsWith(r, StringComparison.Ordinal))
                return new SourceGuardRootDerivation(SourceRootRefusal.SuffixMismatch);
            int prefixLength = n.Length - r.Length;
            if (prefixLength > 256) return new SourceGuardRootDerivation(SourceRootRefusal.PrefixTooLong);
            if (prefixLength <= DeviceStart.Length || !n.StartsWith(DeviceStart, StringComparison.Ordinal))
                return new SourceGuardRootDerivation(SourceRootRefusal.DevicePrefixGrammar);
            // Narrow Source profile: one ASCII device component, no path or alias punctuation.
            for (int i = DeviceStart.Length; i < prefixLength; i++)
            {
                char c = n[i];
                if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                      (c >= '0' && c <= '9') || c == '_' || c == '-'))
                    return new SourceGuardRootDerivation(SourceRootRefusal.DevicePrefixGrammar);
            }
            return new SourceGuardRootDerivation(SourceRootRefusal.None, n.Substring(0, prefixLength) + r[0]);
        }
    }
}
