using System;

namespace IW7.Diagnostics.Source
{
    // Source model only. These constants are not runtime qualification results.
    public static class SnapshotQualification
    {
        public const bool NativeEligibility = false;
        public const string Provider = "Unknown_Unqualified";
        public const string DbgHelpPdbUnmatched = "NotApplicable";
        public const string H3Outcome = "Refused";
        public const bool RealGuardQualified = false;
        public const bool ProviderQuiescenceQualified = false;
        public const bool ChildClosureQualified = false;
    }

    public enum CursorAdmission { Admitted, Closed, CallLimit, PerReadLimit, TotalReadLimit, CloneLimit }
    public enum CursorOrigin { Set = 0, Current = 1, End = 2 }

    public sealed class SnapshotLimits
    {
        public int MaxInputBytes { get; }
        public int MaxReadBytes { get; }
        public ulong MaxTotalReadBytes { get; }
        public int MaxCalls { get; }
        public int MaxClones { get; }

        public SnapshotLimits(int maxInputBytes, int maxReadBytes, ulong maxTotalReadBytes,
                              int maxCalls, int maxClones)
        {
            if (maxInputBytes < 0 || maxReadBytes < 0 || maxCalls < 1 || maxClones < 0)
                throw new ArgumentOutOfRangeException(nameof(maxInputBytes), "Invalid finite model limits.");
            MaxInputBytes = maxInputBytes;
            MaxReadBytes = maxReadBytes;
            MaxTotalReadBytes = maxTotalReadBytes;
            MaxCalls = maxCalls;
            MaxClones = maxClones;
        }
    }

    public sealed class CursorOutcome
    {
        private readonly byte[] bytes;
        public CursorAdmission Admission { get; }
        // Null means the model refused admission, not that an operation returned EOF.
        public int? HResult { get; }
        public uint Count { get { return (uint)bytes.Length; } }
        public ulong Before { get; }
        public ulong After { get; }
        public SnapshotCursor CreatedCursor { get; }

        internal CursorOutcome(CursorAdmission admission, int? hResult, ulong before, ulong after,
                               byte[] payload = null, SnapshotCursor createdCursor = null)
        {
            Admission = admission;
            HResult = hResult;
            Before = before;
            After = after;
            bytes = payload ?? Array.Empty<byte>();
            CreatedCursor = createdCursor;
        }

        // Scalar access only: neither the snapshot nor the result's array escapes.
        public byte GetByte(int index) { return bytes[index]; }
    }

    public sealed class SnapshotObservation
    {
        public int Calls { get; }
        public int ClonesCreated { get; }
        public ulong BytesRead { get; }
        public int PayloadAllocations { get; }
        public long LiveCursors { get; }
        public int LastOwnerReleases { get; }

        internal SnapshotObservation(int calls, int clones, ulong bytesRead, int payloadAllocations,
                                     long liveCursors, int lastOwnerReleases)
        {
            Calls = calls;
            ClonesCreated = clones;
            BytesRead = bytesRead;
            PayloadAllocations = payloadAllocations;
            LiveCursors = liveCursors;
            LastOwnerReleases = lastOwnerReleases;
        }
    }

    // No stream ABI or provider binding. All cursor operations serialize on one model owner.
    public sealed class SnapshotCursor : IDisposable
    {
        public const int S_OK = 0;
        public const int S_FALSE = 1;
        public const int STG_E_INVALIDFUNCTION = unchecked((int)0x80030001);

        private sealed class Owner
        {
            internal readonly object Gate = new object();
            internal readonly SnapshotLimits Limits;
            internal readonly ulong Length;
            internal byte[] Bytes;
            internal int Calls, Clones, PayloadAllocations, LastOwnerReleases;
            internal ulong BytesRead;
            internal long LiveCursors = 1;

            internal Owner(byte[] input, SnapshotLimits limits)
            {
                Limits = limits;
                Bytes = (byte[])input.Clone();
                Length = (ulong)Bytes.Length;
            }
        }

        private readonly Owner owner;
        private ulong position;
        private bool closed;
        private SnapshotCursor(Owner owner, ulong position) { this.owner = owner; this.position = position; }

        public static SnapshotCursor CopyOf(byte[] input, SnapshotLimits limits)
        {
            if (input == null) throw new ArgumentNullException(nameof(input));
            if (limits == null) throw new ArgumentNullException(nameof(limits));
            if (input.Length > limits.MaxInputBytes)
                throw new ArgumentOutOfRangeException(nameof(input), "Snapshot exceeds input limit.");
            return new SnapshotCursor(new Owner(input, limits), 0);
        }

        public ulong Length { get { return owner.Length; } }
        public ulong Position { get { lock (owner.Gate) return position; } }

        private CursorAdmission Admit()
        {
            if (closed) return CursorAdmission.Closed;
            if (owner.Calls == owner.Limits.MaxCalls) return CursorAdmission.CallLimit;
            owner.Calls++;
            return CursorAdmission.Admitted;
        }

        private CursorOutcome Refuse(CursorAdmission reason)
        {
            return new CursorOutcome(reason, null, position, position);
        }

        public CursorOutcome Read(uint count)
        {
            lock (owner.Gate)
            {
                CursorAdmission admission = Admit();
                if (admission != CursorAdmission.Admitted) return Refuse(admission);
                if (count > (uint)owner.Limits.MaxReadBytes) return Refuse(CursorAdmission.PerReadLimit);
                ulong remaining = position < owner.Length ? owner.Length - position : 0;
                int actual = (int)Math.Min((ulong)count, remaining);
                if ((ulong)actual > owner.Limits.MaxTotalReadBytes - owner.BytesRead)
                    return Refuse(CursorAdmission.TotalReadLimit);
                ulong before = position;
                byte[] result = Array.Empty<byte>();
                if (actual != 0)
                {
                    result = new byte[actual];
                    Array.Copy(owner.Bytes, (int)position, result, 0, actual);
                }
                ulong next = position + (ulong)actual;
                var outcome = new CursorOutcome(CursorAdmission.Admitted,
                    (uint)actual == count ? S_OK : S_FALSE, before, next, result);
                if (actual != 0)
                {
                    owner.PayloadAllocations++;
                    owner.BytesRead += (ulong)actual;
                    position = next;
                }
                return outcome;
            }
        }

        private static bool AddSigned(ulong basis, long offset, out ulong result)
        {
            result = basis;
            if (offset >= 0)
            {
                ulong addition = (ulong)offset;
                if (addition > ulong.MaxValue - basis) return false;
                result = basis + addition;
            }
            else
            {
                ulong subtraction = (ulong)(-(offset + 1)) + 1;
                if (subtraction > basis) return false;
                result = basis - subtraction;
            }
            return true;
        }

        // Set interprets the 64 raw offset bits as unsigned; other origins use signed displacement.
        public CursorOutcome Seek(long offset, CursorOrigin origin)
        {
            lock (owner.Gate)
            {
                CursorAdmission admission = Admit();
                if (admission != CursorAdmission.Admitted) return Refuse(admission);
                ulong next = position;
                bool valid;
                if (origin == CursorOrigin.Set) { next = unchecked((ulong)offset); valid = true; }
                else if (origin == CursorOrigin.Current) valid = AddSigned(position, offset, out next);
                else if (origin == CursorOrigin.End) valid = AddSigned(owner.Length, offset, out next);
                else valid = false;
                ulong before = position;
                var outcome = new CursorOutcome(CursorAdmission.Admitted,
                    valid ? S_OK : STG_E_INVALIDFUNCTION, before, valid ? next : before);
                if (valid) position = next;
                return outcome;
            }
        }

        public CursorOutcome Clone()
        {
            lock (owner.Gate)
            {
                CursorAdmission admission = Admit();
                if (admission != CursorAdmission.Admitted) return Refuse(admission);
                if (owner.Clones == owner.Limits.MaxClones) return Refuse(CursorAdmission.CloneLimit);
                var clone = new SnapshotCursor(owner, position);
                var outcome = new CursorOutcome(CursorAdmission.Admitted, S_OK, position, position,
                                                createdCursor: clone);
                owner.Clones++;
                owner.LiveCursors++;
                return outcome;
            }
        }

        public SnapshotObservation Observe()
        {
            lock (owner.Gate)
                return new SnapshotObservation(owner.Calls, owner.Clones, owner.BytesRead,
                    owner.PayloadAllocations, owner.LiveCursors, owner.LastOwnerReleases);
        }

        // Cleanup stays available after all operation budgets are exhausted.
        public void Dispose()
        {
            lock (owner.Gate)
            {
                if (closed) return;
                closed = true;
                owner.LiveCursors--;
                if (owner.LiveCursors == 0)
                {
                    owner.Bytes = null;
                    owner.LastOwnerReleases++;
                }
            }
        }
    }
}
